import Foundation

// Adapted from disktree/core/filter.rs (MIT, © 2026 Tobi Lütke).
// The permission and warranty notice is in SpaceMapTreemapLayout.swift.
enum SpaceMapTreemapFilter {
    enum Keep: Equatable, Sendable {
        case whole
        case partial(bytes: Int64, items: Int)
    }

    struct Result: Equatable, Sendable {
        let keyword: String
        let basePath: String
        /// Matches and their partial ancestors; descendants of a whole match
        /// and the search base are implicit.
        let keepByPath: [String: Keep]
        let topLevelMatchCount: Int
        let matchedBytes: Int64
        /// A whole directory counts itself and all indexed descendants.
        /// A file counts once, including a duplicate hard link with zero bytes.
        let matchedItems: Int

        func keep(forPath rawPath: String) -> Keep? {
            let path = DiskScanner.storageMapLogicalPath(rawPath)
            guard DiskScanner.storageMapPath(path, isWithinRoot: basePath) else { return .whole }
            let own = keepByPath[path]
            var ancestor = path
            while ancestor != basePath {
                if keepByPath[ancestor] == .whole { return .whole }
                ancestor = DiskScanner.storageMapParentPath(ancestor)
            }
            if path == basePath { return .partial(bytes: matchedBytes, items: matchedItems) }
            return own
        }
    }

    static func filter(
        index: StorageMapAnalysisIndex,
        basePath rawBasePath: String,
        keyword: String,
        isCancelled: () -> Bool = { false }
    ) -> Result? {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !isCancelled() else { return nil }
        let basePath = DiskScanner.storageMapLogicalPath(rawBasePath)
        let scanner = DiskScanner(excludedPaths: [])
        let locale = Locale(identifier: "en_US_POSIX")
        let entries = (try? scanner.storageMapSnapshot(at: basePath, using: index))?.entries ?? []
        var stack = [Frame(path: basePath, entries: entries)]
        var kept: [String: Keep] = [:]
        var count = 0
        var visited = 0
        var matchedBytes: Int64 = 0
        var matchedItems = 0
        while !stack.isEmpty {
            let top = stack.count - 1
            if stack[top].next == stack[top].entries.count {
                let finished = stack.removeLast()
                if stack.isEmpty {
                    matchedBytes = finished.bytes
                    matchedItems = finished.items
                } else if finished.items > 0 {
                    kept[finished.path] = .partial(bytes: finished.bytes, items: finished.items)
                    let parent = stack.count - 1
                    stack[parent].bytes = saturatingAdd(stack[parent].bytes, finished.bytes)
                    stack[parent].items = saturatingAdd(stack[parent].items, finished.items)
                }
                continue
            }
            let entry = stack[top].entries[stack[top].next]
            stack[top].next += 1
            visited = saturatingAdd(visited, 1)
            if visited.isMultiple(of: 1_024), isCancelled() { return nil }
            if entry.title.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil {
                kept[entry.path] = .whole
                count = saturatingAdd(count, 1)
                stack[top].bytes = saturatingAdd(stack[top].bytes, max(0, entry.sizeBytes))
                let items = entry.isDirectory
                    ? saturatingAdd(1, max(0, index.directories[entry.path]?.descendantItemCount ?? 0)) : 1
                stack[top].items = saturatingAdd(stack[top].items, items)
            } else if entry.isDirectory, entry.canDescend, !entry.isCloudOnly, entry.kind != "package",
                      let snapshot = try? scanner.storageMapSnapshot(at: entry.path, using: index) {
                stack.append(Frame(path: entry.path, entries: snapshot.entries))
            }
        }
        guard !isCancelled() else { return nil }
        return Result(keyword: keyword, basePath: basePath, keepByPath: kept,
                      topLevelMatchCount: count, matchedBytes: matchedBytes, matchedItems: matchedItems)
    }

    private struct Frame: Sendable {
        let path: String
        let entries: [StorageTreemapEntry]
        var next = 0
        var bytes: Int64 = 0
        var items = 0
    }

    private static func saturatingAdd<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
