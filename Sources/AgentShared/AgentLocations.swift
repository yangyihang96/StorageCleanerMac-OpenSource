import Darwin
import Foundation

/// Where the App keeps its data, decided the way `AppDataDirectories` decides
/// it; the bridge needs it to find the socket. A test in the App target
/// compares the two so they cannot drift apart.
public enum AgentDataLocation {
    public static let releaseBundleIdentifier = "com.local.StorageCleanerMac"
    public static let betaBundleIdentifier = "com.local.StorageCleanerMac.beta"
    public static let integrationBundleIdentifier = "com.local.StorageCleanerMac.integration"
    public static let integrationRootVariable = "STORAGE_CLEANER_INTEGRATION_ROOT"

    public static var compiledAsBeta: Bool {
        #if STORAGE_CLEANER_BETA
        true
        #else
        false
        #endif
    }

    public static func dataDirectory(bundleIdentifier: String, environment: [String: String], home: URL,
                                     compiledAsBeta: Bool) -> URL? {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        switch bundleIdentifier {
        case releaseBundleIdentifier:
            return support.appendingPathComponent("StorageCleanerMac", isDirectory: true)
        case betaBundleIdentifier:
            return support.appendingPathComponent("StorageCleanerMac-Beta", isDirectory: true)
        case integrationBundleIdentifier:
            // QA copies isolate only under ~/Library/Caches/StorageCleanerIntegration-*;
            // otherwise the App writes its compiled-in folder, and so must we.
            if let root = integrationRoot(environment[integrationRootVariable], home: home) { return root }
            return support.appendingPathComponent(compiledAsBeta ? "StorageCleanerMac-Beta" : "StorageCleanerMac", isDirectory: true)
        default:
            return nil
        }
    }

    static func integrationRoot(_ raw: String?, home: URL) -> URL? {
        guard let raw else { return nil }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        let cacheRoot = home.appendingPathComponent("Library/Caches").path
        guard raw == url.standardizedFileURL.path, url.deletingLastPathComponent().path == cacheRoot,
              url.lastPathComponent.hasPrefix("StorageCleanerIntegration-") else { return nil }
        return url
    }

    /// One stable MCP server name per build channel, so client configs for the
    /// release and the Beta can sit side by side.
    public static func serverName(bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case releaseBundleIdentifier: "storage-cleaner"
        case betaBundleIdentifier: "storage-cleaner-beta"
        default: "storage-cleaner-qa"
        }
    }

    /// From the user database, not `HOME`: a client may start the bridge with
    /// any environment it likes.
    public static func currentUserHome() -> URL? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }
}

public enum AgentPaths {
    /// The path as the kernel reports a running program (`proc_pidpath`).
    /// `URL.resolvingSymlinksInPath()` drops `/private` from some paths, which
    /// would then never match a process. Unresolvable paths come back as given.
    public static func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public enum AgentSocketLocationError: Error, Equatable, Sendable {
    case pathTooLong(Int)
    case missing
    case notADirectory
    case isSymbolicLink
    case wrongOwner
    case wrongPermissions(mode_t)
    case notASocket
}

/// D263: `<data directory>/Agent/s`. The name is one letter on purpose: the QA
/// copy's data directory is 88 bytes, and `sun_path` holds 103 plus the NUL.
public enum AgentSocketLocation {
    public static let directoryName = "Agent"
    public static let socketName = "s"
    public static let maximumPathBytes = 103

    public static func directory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func socketPath(dataDirectory: URL) -> String {
        directory(dataDirectory: dataDirectory).appendingPathComponent(socketName, isDirectory: false).path
    }

    /// Too long means the gateway stays off and Settings says why; the socket
    /// never moves somewhere else quietly.
    public static func validateLength(_ path: String) throws(AgentSocketLocationError) {
        let count = path.utf8.count
        guard count <= maximumPathBytes else { throw .pathTooLong(count) }
    }

    /// The `Agent` directory must be a real directory of this user with no
    /// group or other access. Checked by the App before listening and by the
    /// bridge before connecting.
    public static func checkDirectory(dataDirectory: URL, uid: uid_t = getuid()) throws(AgentSocketLocationError) {
        var status = stat()
        guard lstat(directory(dataDirectory: dataDirectory).path, &status) == 0 else { throw .missing }
        switch status.st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFLNK: throw .isSymbolicLink
        default: throw .notADirectory
        }
        guard status.st_uid == uid else { throw .wrongOwner }
        let permissions = status.st_mode & 0o7777
        guard permissions == 0o700 else { throw .wrongPermissions(permissions) }
    }

    public static func checkSocket(path: String, uid: uid_t = getuid()) throws(AgentSocketLocationError) {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw .missing }
        switch status.st_mode & S_IFMT {
        case S_IFSOCK: break
        case S_IFLNK: throw .isSymbolicLink
        default: throw .notASocket
        }
        guard status.st_uid == uid else { throw .wrongOwner }
    }
}
