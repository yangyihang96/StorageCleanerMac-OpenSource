import Darwin
import Foundation

/// This key is cache invalidation evidence, never persistent installation identity.
public struct MacMiniSignatureStamp: Equatable, Sendable {
    public let path: String
    public let modificationToken: String
    public init(path: String, modificationToken: String) {
        self.path = path
        self.modificationToken = modificationToken
    }
}

public enum MacMiniSignatureMetadata: Equatable, Sendable {
    case present(MacMiniSignatureStamp)
    case absentOrUnsafe
    case unknown
}

/// Queue-confined. Cache verified/definitely mismatched results only, bound to
/// path + modification metadata + expected code identity. Never cache unknown.
public final class MacMiniApplicationValidation {
    private struct Entry {
        let stamp: MacMiniSignatureStamp
        let identifier: String
        let result: Bool
    }
    private var entries: [MacMiniApplicationIdentity: Entry] = [:]
    private let metadata: (String) -> MacMiniSignatureMetadata
    private let verify: (MacMiniApplicationIdentity, String) -> Bool?

    public init(metadata: @escaping (String) -> MacMiniSignatureMetadata,
                verify: @escaping (MacMiniApplicationIdentity, String) -> Bool?) {
        self.metadata = metadata
        self.verify = verify
    }

    public func validate(_ application: MacMiniApplicationIdentity, identifier: String) -> Bool? {
        switch metadata(application.installationPath) {
        case .absentOrUnsafe:
            entries[application] = nil
            return false
        case .unknown:
            entries[application] = nil
            return nil
        case .present(let stamp):
            if let entry = entries[application], entry.stamp == stamp, entry.identifier == identifier {
                return entry.result
            }
            guard let result = verify(application, identifier) else {
                entries[application] = nil
                return nil
            }
            // A replacement during full verification is uncertain; never bind
            // a result observed across two different bundle versions.
            guard metadata(application.installationPath) == .present(stamp) else {
                entries[application] = nil
                return nil
            }
            entries[application] = Entry(stamp: stamp, identifier: identifier, result: result)
            return result
        }
    }

    public func invalidate() { entries.removeAll() }

    /// Cheap lstat metadata includes the bundle vnode and modification times of
    /// its identity/seal/executable. Changes invalidate even if root mtime was
    /// preserved by an updater. No code validation or file contents are read.
    public static func readMetadata(path: String) -> MacMiniSignatureMetadata {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "app" else { return .absentOrUnsafe }
        var root = stat()
        if lstat(url.path, &root) != 0 { return errno == ENOENT ? .absentOrUnsafe : .unknown }
        guard root.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return .absentOrUnsafe }
        func token(_ value: stat) -> String {
            "\(value.st_dev):\(value.st_ino):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec):\(value.st_size)"
        }
        var values = [token(root)]
        for relative in ["Contents", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources", "Contents/MacOS"] {
            let child = url.appendingPathComponent(relative)
            var info = stat()
            if lstat(child.path, &info) == 0 { values.append(token(info)) }
            else if errno == ENOENT { values.append("missing") }
            else { return .unknown }
        }
        // Executable mtimes catch in-place changes below an unchanged MacOS folder.
        let executables = url.appendingPathComponent("Contents/MacOS")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: executables.path) {
            for file in files.sorted() {
                var info = stat()
                guard lstat(executables.appendingPathComponent(file).path, &info) == 0 else { return .unknown }
                values.append(file + ":" + token(info))
            }
        }
        return .present(.init(path: url.path, modificationToken: values.joined(separator: "|")))
    }
}
