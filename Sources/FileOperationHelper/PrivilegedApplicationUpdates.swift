import Darwin
import CryptoKit
import FileOperationShared
import Foundation
import Security

final class PrivilegedApplicationUpdateSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "application-update.privileged.serial")
    var batch: AuthorizedApplicationReplacementBatch?
    var deadline = Date.distantPast
    var usedTargets = Set<String>()
    private let cancellationLock = NSLock()
    private var cancelledSessions = Set<String>()
    func cancel(sessionID: String) { cancellationLock.withLock { _ = cancelledSessions.insert(sessionID) } }
    private func isCancelled(_ id: String) -> Bool { cancellationLock.withLock { cancelledSessions.contains(id) } }

    func clear() {
        batch = nil; deadline = .distantPast; usedTargets.removeAll()
        cancellationLock.withLock { cancelledSessions.removeAll() }

    }

    func prepare(_ data: Data, authorization: Data, uid: uid_t) throws {
        clear()
        guard uid >= 501, data.count < 262_144, authorization.count == MemoryLayout<AuthorizationExternalForm>.size else { throw POSIXError(.EINVAL) }
        let request = try JSONDecoder().decode(AuthorizedApplicationReplacementBatch.self, from: data)
        guard request.isValid, abs(request.createdAt.timeIntervalSinceNow) < 120 else { throw POSIXError(.EPERM) }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { authorization.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        let imported = AuthorizationCreateFromExternalForm(&form, &reference)
        guard imported == errAuthorizationSuccess, let reference else { throw POSIXError(.EPERM) }
        defer { AuthorizationFree(reference, []) }
        // The client already authenticated using the batch's in-memory secret.
        // The worker cannot request another dialog.
        let status = AuthorizedApplicationReplacementBatch.right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, [], nil)
            }
        }
        guard status == errAuthorizationSuccess else { throw POSIXError(.EPERM) }
        batch = request; deadline = Date().addingTimeInterval(2 * 60 * 60)
    }

    func replace(candidate: String, destination: String, sessionID: String, digest: String, uid: uid_t) throws {
        guard let batch, batch.sessionID.uuidString == sessionID, Date() < deadline,
              let target = batch.targets.first(where: { $0.path == destination }), usedTargets.insert(destination).inserted else { throw POSIXError(.EPERM) }
        guard !isCancelled(sessionID) else { throw POSIXError(.ECANCELED) }
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw POSIXError(.EPERM) }
        let requestedSource = URL(fileURLWithPath: candidate).standardizedFileURL
        let source = requestedSource.resolvingSymlinksInPath()
        let roots = ["/private/var/folders", "/private/tmp"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path + "/" }
        let requestedAttributes = try FileManager.default.attributesOfItem(atPath: requestedSource.path)
        guard source.pathExtension == "app", requestedAttributes[.type] as? FileAttributeType != .typeSymbolicLink,
              roots.contains(where: { source.path.hasPrefix($0) }) else { throw POSIXError(.EPERM) }
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == uid else { throw POSIXError(.EPERM) }
        let dest = URL(fileURLWithPath: destination)
        guard dest.resolvingSymlinksInPath() == dest else { throw POSIXError(.EPERM) }
        let oldVersion = try verify(dest, target: target)
        guard oldVersion.0 == target.version, oldVersion.1 == target.build else { throw POSIXError(.ESTALE) }
        let newVersion = try verify(source, target: target)
        guard newer(newVersion, than: oldVersion) else { throw POSIXError(.EINVAL) }
        let parent = dest.deletingLastPathComponent()
        let rootStaging = parent.appendingPathComponent(".StorageCleanerMac-Update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: rootStaging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let journal = rootStaging.appendingPathComponent("replacement.json")
        defer { AuthenticatedBundleSwap.cleanupStaging(rootStaging, journal: journal) }
        let staged = rootStaging.appendingPathComponent(dest.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: staged)
        try AuthenticatedApplicationDigest.authenticateCopy(staged, expectedSHA256: digest)
        _ = try verify(staged, target: target)
        guard !isCancelled(sessionID) else { throw POSIXError(.ECANCELED) }
        guard try verify(dest, target: target) == oldVersion else { throw POSIXError(.ESTALE) }
        try AuthenticatedBundleSwap.replace(destination: dest, staged: staged, digest: digest, journal: journal, event: { event in
            if event != .beforeRollback, self.isCancelled(sessionID) { throw POSIXError(.ECANCELED) }
        }, verify: { installed in
            guard try self.verify(installed, target: target) == newVersion else { throw POSIXError(.ESTALE) }
        })
    }

    private func verify(_ url: URL, target: AuthorizedUpdateTarget) throws -> (String, String) {
        var code: SecStaticCode?
        let expression = "anchor apple generic and identifier \"\(target.bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(target.teamIdentifier)\""
        var requirement: SecRequirement?
        guard !target.bundleIdentifier.contains("\""), !target.teamIdentifier.contains("\""),
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess,
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == target.bundleIdentifier else { throw POSIXError(.EPERM) }
        return (info["CFBundleShortVersionString"] as? String ?? "", info["CFBundleVersion"] as? String ?? "")
    }
    private func newer(_ lhs: (String, String), than rhs: (String, String)) -> Bool {
        ApplicationUpdateVersionOrder.isNewer(marketing: lhs.0, build: lhs.1,
            installedMarketing: rhs.0, installedBuild: rhs.1)
    }
}

private final class UpdateReplyCallback: @unchecked Sendable {
    let callback: (Data) -> Void
    init(_ callback: @escaping (Data) -> Void) { self.callback = callback }
    func complete(_ work: () throws -> Void) {
        let response: AuthorizedUpdateReply
        do { try work(); response = .init() }
        catch let failure as AuthenticatedBundleSwap.Failure {
            response = .init(error: failure.localizedDescription, errorCode: Int(EINPROGRESS), finished: false)
        } catch { response = .init(error: error.localizedDescription, errorCode: (error as NSError).code) }
        callback((try? JSONEncoder().encode(response)) ?? Data())
    }
}

extension ConnectionService {
    func applicationReplacementCapabilities(reply: @escaping (Data) -> Void) {
        let value = ApplicationReplacementCapabilities(build: FileOperationHelperBuild.current, busy: FileOperationUpdateActivity.isBusy)
        reply((try? JSONEncoder().encode(value)) ?? Data())
    }
    func prepareApplicationReplacements(_ request: Data, authorization: Data, reply: @escaping (Data) -> Void) {
        let callback = UpdateReplyCallback(reply)
        updates.queue.async { callback.complete { try self.updates.prepare(request, authorization: authorization, uid: self.uid) } }
    }
    func replaceAuthenticatedApplication(_ request: Data, reply: @escaping (Data) -> Void) {
        let callback = UpdateReplyCallback(reply)
        updates.queue.async { callback.complete {
            guard request.count < 262_144 else { throw POSIXError(.EINVAL) }
            let request = try JSONDecoder().decode(AuthenticatedApplicationReplacement.self, from: request)
            try FileOperationUpdateActivity.perform {
                try self.updates.replace(candidate: request.candidatePath, destination: request.destinationPath,
                    sessionID: request.sessionID.uuidString, digest: request.candidateSHA256, uid: self.uid)
            }
        } }
    }
    func finishApplicationReplacements(_ sessionID: String, reply: @escaping (Data) -> Void) {
        updates.cancel(sessionID: sessionID)
        let callback = UpdateReplyCallback(reply)
        updates.queue.async { callback.complete { if self.updates.batch?.sessionID.uuidString == sessionID { self.updates.clear() } } }
    }
}

private enum FileOperationHelperBuild {
    static var current: String {
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let values = info as? [String: Any],
            let plist = values[kSecCodeInfoPList as String] as? [String: Any],
            plist["CFBundleIdentifier"] as? String == FileOperationIdentity.helper else { return "" }
        // The resident executable's signed __TEXT,__info_plist is authority;
        // an enclosing App/sidecar plist may already belong to a newer build.
        return plist["CFBundleVersion"] as? String ?? ""
    }
}
/// Shared across connections, including old prepare/commit callers.
enum FileOperationUpdateActivity {
    private static let state = State()
    private final class State: @unchecked Sendable { let lock = NSLock(); var active = 0 }
    static var isBusy: Bool { state.lock.withLock { state.active > 0 } }
    static func perform<T>(_ body: () throws -> T) rethrows -> T {
        state.lock.withLock { state.active += 1 }
        defer { state.lock.withLock { state.active -= 1 } }
        return try body()
    }
}
