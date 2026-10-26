import Darwin
import Foundation

/// D181: where the current user's Trash folders on other mounted volumes are.
protocol VolumeTrashLocating: Sendable {
    /// Every qualifying `/Volumes/<name>/.Trashes/<uid>` now mounted.
    func trashURLs(uid: uid_t) -> [URL]
    /// Checked again right before a frozen entry is deleted.
    func isValidTrash(_ trash: URL, uid: uid_t) -> Bool
}

/// D181: the Trash folder Finder uses on each other mounted volume,
/// `/Volumes/<name>/.Trashes/<uid>`. Only a local, writable volume mounted
/// directly under `/Volumes` counts (not the startup volume, not a network
/// share), and every level is read without following links: the volume
/// folder is a mount point, `.Trashes` is a real folder on that volume, and
/// the user's folder inside it is a real folder the user owns.
struct VolumeTrashLocator: VolumeTrashLocating {
    static let volumesPath = "/Volumes"

    func trashURLs(uid: uid_t) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.volumesPath)) ?? []
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            guard Self.volumeName(ofVolumePath: Self.volumesPath + "/" + name) != nil else { return nil }
            let trash = Self.trashURL(volumeName: name, uid: uid)
            return isValidTrash(trash, uid: uid) ? trash : nil
        }
    }

    func isValidTrash(_ trash: URL, uid: uid_t) -> Bool {
        let trashPath = PathSafety.lexicalPath(trash.path)
        guard Self.isTrashPath(trashPath, uid: uid) else { return false }
        let trashesPath = (trashPath as NSString).deletingLastPathComponent
        let volumePath = (trashesPath as NSString).deletingLastPathComponent
        var volumes = stat(), volume = stat(), trashes = stat(), own = stat()
        guard lstat(Self.volumesPath, &volumes) == 0, lstat(volumePath, &volume) == 0,
              lstat(trashesPath, &trashes) == 0, lstat(trashPath, &own) == 0 else { return false }
        func isDirectory(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFDIR }
        guard isDirectory(volumes), isDirectory(volume), isDirectory(trashes), isDirectory(own),
              volume.st_dev != volumes.st_dev,
              trashes.st_dev == volume.st_dev,
              own.st_dev == volume.st_dev,
              own.st_uid == uid else { return false }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey]
        guard let values = try? URL(fileURLWithPath: volumePath, isDirectory: true).resourceValues(forKeys: keys),
              values.volumeIsLocal == true,
              values.volumeIsReadOnly == false,
              values.volumeIsRootFileSystem != true else { return false }
        return true
    }

    static func trashURL(volumeName: String, uid: uid_t) -> URL {
        URL(fileURLWithPath: volumesPath, isDirectory: true)
            .appendingPathComponent(volumeName, isDirectory: true)
            .appendingPathComponent(".Trashes", isDirectory: true)
            .appendingPathComponent(String(uid), isDirectory: true)
    }

    /// Exactly `/Volumes/<name>/.Trashes/<uid>`, already in lexical form.
    static func isTrashPath(_ path: String, uid: uid_t) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "Volumes",
              volumeName(ofVolumePath: volumesPath + "/" + parts[2]) != nil,
              parts[3] == ".Trashes", parts[4] == String(uid) else { return false }
        return PathSafety.lexicalPath(path) == path
    }

    /// The name when `path` is exactly `/Volumes/<name>`.
    static func volumeName(ofVolumePath path: String) -> String? {
        let prefix = volumesPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\0") else { return nil }
        return name
    }

    /// The volume's name for a Trash path, for row titles.
    static func volumeName(ofTrashPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[1] == "Volumes", parts[3] == ".Trashes" else { return nil }
        return volumeName(ofVolumePath: volumesPath + "/" + parts[2])
    }
}
