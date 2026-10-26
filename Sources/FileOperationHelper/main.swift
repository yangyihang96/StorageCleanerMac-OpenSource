import AppKit
import Darwin
import Foundation
import Security
import FileOperationShared

/// No shell, recursive deletion, chown or cross-volume copy. All moves are
/// atomic, exclusive renames between preopened, non-symlink directories.
/// The one command it runs is the read-only `sfltool dumpbtm` (D177).
private enum RestrictedMove {
    static func directory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path,
              !path.split(separator: "/").contains("..") else { throw POSIXError(.EINVAL) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        for component in path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            fd = next
        }
        return fd
    }
    static func perform(_ request: AuthorizedFileMove, uid: uid_t, authorizedUntil: Date) throws -> String {
        guard uid >= 501, Date() < authorizedUntil,
              authorizedUntil.timeIntervalSinceNow <= 16,
              let user = getpwuid(uid) else { throw POSIXError(.EPERM) }
        let home = String(cString: user.pointee.pw_dir)
        let app = URL(fileURLWithPath: request.applicationPath)
        let trash = URL(fileURLWithPath: request.trashPath)
        guard FileOperationPathPolicy.permits(request, home: home, uid: uid) else { throw POSIXError(.EPERM) }
        let appParent = try directory(app.deletingLastPathComponent().path)
        defer { close(appParent) }
        let trashParent = try directory(trash.deletingLastPathComponent().path)
        defer { close(trashParent) }
        var trashInfo = stat(); var appInfo = stat()
        guard fstat(trashParent, &trashInfo) == 0, fstat(appParent, &appInfo) == 0,
              trashInfo.st_uid == uid, trashInfo.st_mode & 0o077 == 0,
              trashInfo.st_dev == appInfo.st_dev else { throw POSIXError(.EPERM) }
        let restoring = request.direction == .restore
        let sourceFD = restoring ? trashParent : appParent
        let destinationFD = restoring ? appParent : trashParent
        let source = restoring ? trash : app
        let destination = restoring ? app : trash
        var info = stat()
        guard fstatat(sourceFD, source.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let birth: Int64? = info.st_birthtimespec.tv_sec > 0
            ? Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec) : nil
        guard info.st_mode & S_IFMT == S_IFDIR, UInt64(info.st_dev) == request.device,
              UInt64(info.st_ino) == request.inode, birth == request.birthNanoseconds,
              FileProtectionFlags.lock(info.st_flags) == .none else { throw POSIXError(.EPERM) }
        // Read Info.plist through the pinned source directory, never a following URL.
        let appFD = openat(sourceFD, source.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard appFD >= 0 else { throw POSIXError(.EIO) }; defer { close(appFD) }
        let contents = openat(appFD, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard contents >= 0 else { throw POSIXError(.EINVAL) }; defer { close(contents) }
        let plistFD = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard plistFD >= 0 else { throw POSIXError(.EINVAL) }
        var plistInfo = stat()
        guard fstat(plistFD, &plistInfo) == 0, plistInfo.st_mode & S_IFMT == S_IFREG,
              plistInfo.st_size >= 0, plistInfo.st_size <= 1_048_576 else {
            close(plistFD); throw POSIXError(.EINVAL)
        }
        let handle = FileHandle(fileDescriptor: plistFD, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == request.bundleIdentifier,
              (plist["CFBundleShortVersionString"] as? String ?? "") == request.version,
              (plist["CFBundleVersion"] as? String ?? "") == request.build else { throw POSIXError(.EINVAL) }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: request.bundleIdentifier).isEmpty else {
            throw POSIXError(.EBUSY)
        }
        var final = stat()
        guard fstatat(sourceFD, source.lastPathComponent, &final, AT_SYMLINK_NOFOLLOW) == 0,
              final.st_dev == info.st_dev, final.st_ino == info.st_ino,
              final.st_birthtimespec.tv_sec == info.st_birthtimespec.tv_sec,
              final.st_birthtimespec.tv_nsec == info.st_birthtimespec.tv_nsec,
              Date() < authorizedUntil else { throw POSIXError(.ESTALE) }
        guard renameatx_np(sourceFD, source.lastPathComponent, destinationFD,
                           destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Rename succeeded even if fsync fails: return destination, never retry a move.
        _ = fsync(sourceFD); _ = fsync(destinationFD)
        return destination.path
    }
}

final class ConnectionService: NSObject, FileOperationHelperProtocol, @unchecked Sendable {
    let uid: uid_t
    let lifecycle: FileOperationHelperLifecycle
    let connectionID: UUID
    private let queue = DispatchQueue(label: "file-operation.serial")
    private var requests = Set<UUID>()
    private var commitGate = AuthorizedFileCommitGate()
    let updates = PrivilegedApplicationUpdateSession()
    let systemCaches = PrivilegedSystemCacheSession()
    init(uid: uid_t, lifecycle: FileOperationHelperLifecycle, connectionID: UUID) {
        self.uid = uid; self.lifecycle = lifecycle; self.connectionID = connectionID
    }
    /// Counts queued work as well as executing work. ReplyCallback releases
    /// the request only after the reply has been handed back to XPC.
    func trackedReply(_ reply: @escaping (Data) -> Void) -> ReplyCallback {
        lifecycle.beginRequest()
        return ReplyCallback(reply) { [lifecycle] in lifecycle.finishRequest() }
    }
    func prepare(_ data: Data, authorization: Data, reply: @escaping (Data) -> Void) {
        // Authentication can present SecurityAgent in the imported user's
        // session. No filesystem mutation occurs until a separate commit.
        let callback = trackedReply(reply)
        queue.async {
            var requestID = UUID()
            var stage: AuthorizedFileFailureStage = .request
            let response: AuthorizedFileReply
            do {
                self.commitGate.invalidate()
                guard data.count < 16_384, authorization.count == MemoryLayout<AuthorizationExternalForm>.size else {
                    throw POSIXError(.EINVAL)
                }
                let request = try JSONDecoder().decode(AuthorizedFileMove.self, from: data)
                requestID = request.requestID
                let receivedAt = Date()
                guard let user = getpwuid(self.uid),
                      FileOperationPathPolicy.permits(request, home: String(cString: user.pointee.pw_dir), uid: self.uid),
                      receivedAt < request.expiresAt,
                      request.expiresAt.timeIntervalSince(receivedAt) <= 65 else { throw POSIXError(.EPERM) }
                guard self.requests.count < 128, self.requests.insert(requestID).inserted else { throw POSIXError(.EALREADY) }
                var form = AuthorizationExternalForm()
                _ = withUnsafeMutableBytes(of: &form) { authorization.copyBytes(to: $0) }
                stage = .importAuthorization
                var ref: AuthorizationRef?
                let imported = AuthorizationCreateFromExternalForm(&form, &ref)
                guard imported == errAuthorizationSuccess, let ref else {
                    throw NSError(domain: NSOSStatusErrorDomain,
                                  code: Int(imported == errAuthorizationSuccess ? errAuthorizationInvalidRef : imported))
                }
                defer { AuthorizationFree(ref, []) }
                stage = .checkAuthorization
                try FileOperationAuthorization.checkImportedRights { flags in
                    FileOperationIdentity.authorizationRight.withCString { name in
                        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                        return withUnsafeMutablePointer(to: &item) { pointer in
                            var rights = AuthorizationRights(count: 1, items: pointer)
                            return AuthorizationCopyRights(ref, &rights, nil, flags, nil)
                        }
                    }
                }
                try self.commitGate.approve(request, receivedAt: receivedAt)
                response = AuthorizedFileReply(requestID: requestID, prepared: true)
            } catch {
                let error = error as NSError
                response = AuthorizedFileReply(requestID: requestID, errorDomain: error.domain, errorCode: error.code, failureStage: stage)
            }
            self.lifecycle.setApproval(until: self.commitGate.approvalExpiration, connection: self.connectionID, kind: .move)
            callback.call((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
    func commit(_ data: Data, reply: @escaping (Data) -> Void) {
        let callback = trackedReply(reply)
        queue.async {
            var requestID = UUID()
            var stage: AuthorizedFileFailureStage = .commit
            let response: AuthorizedFileReply
            do {
                guard data.count < 16_384 else { throw POSIXError(.EINVAL) }
                let request = try JSONDecoder().decode(AuthorizedFileMove.self, from: data)
                requestID = request.requestID
                let deadline = try self.commitGate.consume(request)
                stage = .fileMove
                response = AuthorizedFileReply(requestID: requestID,
                    destination: try FileOperationUpdateActivity.perform { try RestrictedMove.perform(request, uid: self.uid, authorizedUntil: deadline) })
            } catch {
                self.commitGate.invalidate()
                let error = error as NSError
                response = AuthorizedFileReply(requestID: requestID, errorDomain: error.domain,
                                               errorCode: error.code, failureStage: stage)
            }
            self.lifecycle.setApproval(until: self.commitGate.approvalExpiration, connection: self.connectionID, kind: .move)
            callback.call((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
final class ReplyCallback: @unchecked Sendable {
    let callback: (Data) -> Void
    let didReply: @Sendable () -> Void
    init(_ callback: @escaping (Data) -> Void, didReply: @escaping @Sendable () -> Void) {
        self.callback = callback; self.didReply = didReply
    }
    func call(_ value: Data) { callback(value); didReply() }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    let lifecycle = FileOperationHelperLifecycle(
        signer: { FileOperationPeerRequirement.currentSigner(peerIdentifier: FileOperationIdentity.application) },
        updateIsBusy: { FileOperationUpdateActivity.isBusy })
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let admission = lifecycle.admit(uid: connection.effectiveUserIdentifier) else { return false }
        connection.setCodeSigningRequirement(admission.requirement)
        connection.exportedInterface = NSXPCInterface(with: FileOperationHelperProtocol.self)
        connection.exportedObject = ConnectionService(uid: connection.effectiveUserIdentifier,
                                                     lifecycle: lifecycle, connectionID: admission.id)
        connection.invalidationHandler = { @Sendable [lifecycle] in lifecycle.invalidate(admission.id) }
        connection.resume()
        return true
    }
}

private let delegate = Listener()
let listener = NSXPCListener(machServiceName: FileOperationIdentity.helper)
listener.delegate = delegate
delegate.lifecycle.start()
listener.resume()
RunLoop.current.run()
