import AppKit
import CryptoKit
import Darwin
import Foundation

/// A display-cache identity, never an installation trust credential. All
/// descendants participate, including Info.plist, MacOS executables, receipts,
/// nested code and _CodeSignature. No file contents are read by this walk.
struct ApplicationBundleFingerprint: Codable, Equatable, Sendable {
    let root: ApplicationBundleStatIdentity
    let mountIdentity: String
    let descendantDigest: String
    let descendantCount: Int
}

struct ApplicationBundleStatIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let file: UInt64
    let mode: UInt16
    let size: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let flags: UInt32

    init(_ status: stat) {
        device = status.st_dev
        file = status.st_ino
        mode = status.st_mode
        size = status.st_size
        changeSeconds = Int64(status.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        birthSeconds = Int64(status.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
        flags = status.st_flags
    }
}

protocol ApplicationBundleFingerprintReading: Sendable {
    func fingerprint(at applicationURL: URL) async throws -> ApplicationBundleFingerprint
}

enum ApplicationBundleFingerprintError: Error {
    case unreadable
    case tooManyEntries
    case unsafeSymbolicLink
}

struct FileSystemApplicationBundleFingerprintReader: ApplicationBundleFingerprintReading {
    typealias MountIdentityReader = @Sendable (URL) async throws -> String
    private let mountIdentityReader: MountIdentityReader
    private let maximumDescendants: Int

    init(
        maximumDescendants: Int = 100_000,
        mountIdentityReader: @escaping MountIdentityReader = Self.mountIdentity(at:)
    ) {
        self.maximumDescendants = max(1, maximumDescendants)
        self.mountIdentityReader = mountIdentityReader
    }

    func fingerprint(at applicationURL: URL) async throws -> ApplicationBundleFingerprint {
        let url = applicationURL.standardizedFileURL
        let mount = try await mountIdentityReader(url)
        let walkTask = Task.detached(priority: .utility) {
            try Self.walk(url, mountIdentity: mount, maximumDescendants: maximumDescendants)
        }
        let fingerprint = try await withTaskCancellationHandler {
            try await walkTask.value
        } onCancel: {
            walkTask.cancel()
        }
        try Task.checkCancellation()
        // A remount during traversal must not yield a reusable fingerprint.
        guard try await mountIdentityReader(url) == mount else {
            throw ApplicationBundleFingerprintError.unreadable
        }
        return fingerprint
    }

    private static func walk(
        _ url: URL,
        mountIdentity: String,
        maximumDescendants: Int
    ) throws -> ApplicationBundleFingerprint {
        var rootStatus = stat()
        guard lstat(url.path, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw ApplicationBundleFingerprintError.unreadable
        }
        let root = ApplicationBundleStatIdentity(rootStatus)
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { throw ApplicationBundleFingerprintError.unreadable }
        var descendants = [(String, ApplicationBundleStatIdentity)]()
        for case let child as URL in enumerator {
            try Task.checkCancellation()
            guard descendants.count < maximumDescendants else {
                throw ApplicationBundleFingerprintError.tooManyEntries
            }
            var status = stat()
            guard lstat(child.path, &status) == 0 else {
                throw ApplicationBundleFingerprintError.unreadable
            }
            // Framework symlinks within the bundle are covered by their own
            // lstat plus the separately traversed target. Never cache a link
            // whose target is outside this bundle (or cannot be read).
            if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                let target = child.resolvingSymlinksInPath().standardizedFileURL
                guard target.path.hasPrefix(url.path + "/"),
                      FileManager.default.fileExists(atPath: target.path) else {
                    throw ApplicationBundleFingerprintError.unsafeSymbolicLink
                }
            }
            let relative = String(child.path.dropFirst(url.path.count + 1))
            descendants.append((relative, ApplicationBundleStatIdentity(status)))
        }
        guard !enumerationFailed else { throw ApplicationBundleFingerprintError.unreadable }
        // Sorting makes directory enumeration order irrelevant, without
        // persisting a potentially enormous list of child paths in the cache.
        var digest = SHA256()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (path, identity) in descendants.sorted(by: { $0.0 < $1.0 }) {
            let pathData = Data(path.utf8)
            digest.update(data: Data("\(pathData.count):".utf8))
            digest.update(data: pathData)
            digest.update(data: try encoder.encode(identity))
        }
        var finalRootStatus = stat()
        guard lstat(url.path, &finalRootStatus) == 0,
              ApplicationBundleStatIdentity(finalRootStatus) == root else {
            throw ApplicationBundleFingerprintError.unreadable
        }
        return ApplicationBundleFingerprint(
            root: root,
            mountIdentity: mountIdentity,
            descendantDigest: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            descendantCount: descendants.count
        )
    }

    static func mountIdentity(at url: URL) async throws -> String {
        var status = statfs()
        guard statfs(url.path, &status) == 0 else {
            throw ApplicationBundleFingerprintError.unreadable
        }
        let mountPath = withUnsafeBytes(of: status.f_mntonname) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let source = withUnsafeBytes(of: status.f_mntfromname) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsInternalKey])
        let fsid = withUnsafeBytes(of: status.f_fsid) { Data($0).base64EncodedString() }
        var identity = "\(fsid)|\(mountPath)|\(source)|\(status.f_flags)|\(values.volumeUUIDString ?? "unknown")"
        if values.volumeIsInternal != true {
            // A stable volume UUID/fsid cannot prove no remount happened while
            // the app was stopped. External/unknown volumes therefore reuse
            // only within an observed process session. Internal volumes retain
            // the useful cross-launch cache, external ones fail closed.
            let session = await ApplicationExternalMountSession.shared
            identity += "|\(session.token)"
        }
        return identity
    }
}

@MainActor
private final class ApplicationExternalMountSession {
    static let shared = ApplicationExternalMountSession()
    private let state = ApplicationMountGeneration()
    private var observers = [NSObjectProtocol]()
    nonisolated var token: String { state.token }

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let state = self.state
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                state.invalidate()
            })
        }
    }
}

private final class ApplicationMountGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private let session = UUID().uuidString
    private var generation: UInt64 = 0
    var token: String { lock.withLock { "\(session)|\(generation)" } }
    func invalidate() { lock.withLock { generation &+= 1 } }
}
