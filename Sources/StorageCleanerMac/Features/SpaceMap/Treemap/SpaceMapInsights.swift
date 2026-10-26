import Foundation

// Adapted from disktree/core/insights.rs (MIT, © 2026 Tobi Lütke).
// The permission and warranty notice is in SpaceMapTreemapLayout.swift.
struct SpaceMapInsight: Equatable, Sendable {
    enum Finding: Equatable, Sendable {
        case reclaimable(SpaceMapReclaimReason)
        case worktrees(count: Int)
    }

    let path: String
    let bytes: Int64
    let finding: Finding
}

enum SpaceMapInsights {
    static func worthALook(
        index: StorageMapAnalysisIndex,
        purposes: SpaceMapPurposeMap,
        limit: Int = 6,
        minimumBytes: Int64 = 64 * 1_024 * 1_024,
        isCancelled: () -> Bool = { false }
    ) -> [SpaceMapInsight]? {
        guard !isCancelled() else { return nil }
        guard limit > 0 else { return [] }
        let scanner = DiskScanner(excludedPaths: [])
        let rootEntries = (try? scanner.storageMapSnapshot(at: index.rootPath, using: index))?.entries ?? []
        var stack = rootEntries.filter {
            $0.isDirectory && $0.canDescend && !$0.isCloudOnly
                && $0.kind != "package" && $0.sizeBytes >= minimumBytes
        }.map(\.path)
        var found: [SpaceMapInsight] = []
        var visited = 0
        while let path = stack.popLast() {
            visited += 1
            if visited.isMultiple(of: 1_024), isCancelled() { return nil }
            guard let bytes = index.directories[path]?.sizeBytes, bytes >= minimumBytes else { continue }
            if let reason = purposes.reclaimReason(atPath: path) {
                found.append(SpaceMapInsight(path: path, bytes: bytes, finding: .reclaimable(reason)))
                continue
            }
            guard let snapshot = try? scanner.storageMapSnapshot(at: path, using: index) else { continue }
            let name = (path as NSString).lastPathComponent.lowercased()
            if (name == "worktrees" || name == "sc-worktrees"),
               purposes.purpose(atPath: path) == .agentWorkspace {
                let count = snapshot.entries.lazy.filter(\.isDirectory).count
                if count > 0 {
                    found.append(SpaceMapInsight(path: path, bytes: bytes, finding: .worktrees(count: count)))
                    continue
                }
            }
            for entry in snapshot.entries where entry.isDirectory && entry.canDescend
                && !entry.isCloudOnly && entry.kind != "package" && entry.sizeBytes >= minimumBytes {
                stack.append(entry.path)
            }
        }
        guard !isCancelled() else { return nil }
        found.sort { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
        return Array(found.prefix(limit))
    }
}
