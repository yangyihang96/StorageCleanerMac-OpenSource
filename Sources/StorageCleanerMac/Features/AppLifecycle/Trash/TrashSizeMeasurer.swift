import Darwin
import Foundation

/// The Trash folders that count toward the Trash size (CleanMyMac
/// `TrashLocations`): the user's `~/.Trash` and, on every mounted local
/// volume other than the startup disk, `.Trashes/<uid>`.
enum TrashLocations {
    static func userTrash(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
    }

    static func all(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        userID: uid_t = getuid()
    ) -> [URL] {
        var locations = [userTrash(homeDirectory: homeDirectory)]
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey]
        for volume in fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true,
                  values.volumeIsReadOnly != true,
                  values.volumeIsLocal == true else { continue }
            let trash = volume.appendingPathComponent(".Trashes", isDirectory: true)
                .appendingPathComponent(String(userID), isDirectory: true)
            if fileManager.fileExists(atPath: trash.path) { locations.append(trash) }
        }
        return locations
    }
}

/// Measures what the Trash occupies on disk. Each top-level entry is measured
/// once and reused while its identity and modification date stay the same
/// (CleanMyMac `TrashSizeMonitor.sizeCache`). Hard links inside one entry are
/// counted once; links are never followed.
final class TrashSizeMeasurer: @unchecked Sendable {
    struct Measurement: Equatable, Sendable {
        var totalBytes: Int64
        var itemCount: Int
        /// False when a Trash folder could not be listed (typically missing
        /// Full Disk Access): the total then covers only what was readable.
        var isReadable: Bool
    }

    private struct EntryKey: Hashable {
        let path: String
        let device: UInt64
        let inode: UInt64
        let modified: TimeInterval
    }

    private let lock = NSLock()
    private var cache: [EntryKey: Int64] = [:]
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func measure(locations: [URL]) -> Measurement {
        var total: Int64 = 0
        var count = 0
        var readable = true
        var seen = Set<EntryKey>()
        for location in locations {
            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: location,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: []
                )
            } catch {
                // A missing per-volume Trash is not an access problem.
                if location == locations.first || fileManager.fileExists(atPath: location.path) { readable = false }
                continue
            }
            for entry in entries where entry.lastPathComponent != ".DS_Store" {
                guard let key = Self.key(for: entry) else { continue }
                seen.insert(key)
                count += 1
                let cached = lock.withLock { cache[key] }
                let bytes = cached ?? Self.allocatedSize(of: entry, fileManager: fileManager)
                if cached == nil { lock.withLock { cache[key] = bytes } }
                total = total.addingReportingOverflow(bytes).overflow ? .max : total + bytes
            }
        }
        lock.withLock { cache = cache.filter { seen.contains($0.key) } }
        return Measurement(totalBytes: total, itemCount: count, isReadable: readable)
    }

    private static func key(for url: URL) -> EntryKey? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return EntryKey(path: url.path, device: UInt64(bitPattern: Int64(info.st_dev)),
                        inode: UInt64(info.st_ino), modified: modified)
    }

    /// Allocated bytes of a file or a folder tree (`totalFileAllocatedSize`),
    /// without following links and counting each hard-linked inode once.
    static func allocatedSize(of url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                         .fileAllocatedSizeKey, .linkCountKey, .fileResourceIdentifierKey]
        func size(_ values: URLResourceValues) -> Int64 {
            Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let rootValues = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return size(rootValues) }
        var total = size(rootValues)
        var linked = Set<NSObject>()
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                       options: [], errorHandler: { _, _ in true }) else { return total }
        while let next = enumerator.nextObject() {
            guard let child = next as? URL, let values = try? child.resourceValues(forKeys: keys) else { continue }
            if (values.linkCount ?? 1) > 1, values.isDirectory != true,
               let identifier = values.fileResourceIdentifier as? NSObject {
                guard linked.insert(identifier).inserted else { continue }
            }
            let bytes = size(values)
            total = total.addingReportingOverflow(bytes).overflow ? .max : total + bytes
        }
        return total
    }
}
