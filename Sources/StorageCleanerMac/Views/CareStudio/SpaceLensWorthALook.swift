import Foundation

/// Resolve findings through the same snapshot as ordinary rows, rather than
/// inventing entries that might bypass a package or protection boundary.
enum SpaceLensWorthALook {
    struct Row: Equatable, Sendable, Identifiable {
        let entry: StorageTreemapEntry
        let finding: SpaceMapInsight.Finding
        let location: String
        var id: String { entry.id }

        var subtitle: String {
            switch finding {
            case let .reclaimable(reason): reason.title + " · " + location
            case let .worktrees(count):
                SpaceMapPurpose.agentWorkspace.title + " · "
                    + L10n.text("\(ByteFormat.count(count)) 个工作树",
                                count == 1 ? "1 worktree" : "\(ByteFormat.count(count)) worktrees")
            }
        }
    }

    static func rows(_ findings: [SpaceMapInsight], index: StorageMapAnalysisIndex, homePath: String,
                     isCancelled: () -> Bool = { false }) -> [Row]? {
        let scanner = DiskScanner(excludedPaths: [])
        var snapshots: [String: StorageMapDirectorySnapshot] = [:]
        var rows: [Row] = []
        for finding in findings {
            guard !isCancelled() else { return nil }
            let parent = DiskScanner.storageMapParentPath(finding.path)
            if snapshots[parent] == nil {
                snapshots[parent] = try? scanner.storageMapSnapshot(at: parent, using: index)
            }
            guard let entry = snapshots[parent]?.entries.first(where: { $0.path == finding.path }) else { continue }
            rows.append(Row(entry: entry, finding: finding.finding,
                            location: location(parent: parent, root: index.rootPath, home: homePath)))
        }
        return isCancelled() ? nil : rows
    }

    static func location(parent: String, root: String, home: String) -> String {
        if parent == home { return "~" }
        if parent == root { return "." }
        let prefix = root == "/" ? "/" : root + "/"
        return parent.hasPrefix(prefix) ? String(parent.dropFirst(prefix.count)) : parent
    }

    static var emptyTitle: String { L10n.text("没有发现值得一看的项目", "Nothing to Look At") }
    static var emptyDescription: String {
        L10n.text("这里只列出 64 MB 以上、可再生或可重装的目录，以及 AI 工作区里的工作树。",
                  "Only regenerable or reinstallable folders of at least 64 MB, and worktrees in AI workspaces, are listed here.")
    }
    static var findingTitle: String { L10n.text("正在查找…", "Finding…") }

    static func emptyFilterTitle(_ keyword: String) -> String {
        L10n.text("没有名称包含“\(keyword)”的项目", "No items with names containing “\(keyword)”")
    }

    static func matchesTitle(_ result: SpaceMapTreemapFilter.Result) -> String {
        let bytes = ByteFormat.storageString(result.matchedBytes)
        let matched = ByteFormat.count(result.matchedItems)
        return L10n.text("\(matched) 项匹配 · \(bytes)", "\(matched) matches · \(bytes)")
    }

    static func filteredEntries(_ entries: [StorageTreemapEntry], filter: SpaceMapTreemapFilter.Result?) -> [StorageTreemapEntry] {
        guard let filter else { return entries }
        return entries.filter { $0.role == .content && filter.keep(forPath: $0.path) != nil }
    }
}

/// D193② (the user chose "add a row"): as CleanMyMac, the Space Map lists the
/// space macOS frees by itself when it needs it (purgeable) apart from the
/// folders, with what it is; unlike CleanMyMac it offers no clean button, as
/// macOS manages it.
enum SpaceLensPurgeable {
    static var title: String { L10n.text("可清除空间", "Purgeable Space") }
    static var detail: String {
        L10n.text("由 macOS 管理，需要时自动腾出，不用手动清理",
                  "Managed by macOS and freed when needed; nothing to clean by hand")
    }

    /// The bytes to list, or nil: only on the Folders list at the top of a
    /// whole disk, unfiltered, when the scan measured some. The top is the
    /// folder on screen being the scan's root: the store keeps the root in
    /// its navigation (`storageMapNavigation == [rootSnapshot]`), so the
    /// first version's `navigation.isEmpty` never held and the row never
    /// showed (r35 window run, 10-24).
    static func bytes(result: StorageMapAnalysisResult, surface: Int, snapshot: StorageMapDirectorySnapshot,
                      filtered: Bool) -> Int64? {
        guard surface == 0, snapshot.path == result.rootSnapshot.path, !filtered,
              result.target.kind != .homeDirectory, result.volumePurgeableBytes > 0 else { return nil }
        return result.volumePurgeableBytes
    }
}
