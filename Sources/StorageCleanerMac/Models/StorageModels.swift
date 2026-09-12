import Foundation

enum StorageTier: String, CaseIterable, Codable, Identifiable, Sendable {
    case green
    case yellow
    case red
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .green: L10n.text("可安全清理", "Safe to Clean")
        case .yellow: L10n.text("需确认", "Needs Review")
        case .red: L10n.text("谨慎处理", "Handle Carefully")
        case .other: L10n.text("系统及其他", "System & Other")
        }
    }

    var detail: String {
        switch self {
        case .green: L10n.text("缓存、临时文件、构建产物", "Caches, temporary files, build output")
        case .yellow: L10n.text("用户数据、离线内容、应用资料", "User data, offline content, app data")
        case .red: L10n.text("应用文件或不建议手工删除的内容", "Apps or data not safe to remove directly")
        case .other: L10n.text("没有直接清理决策的占用", "Storage without a direct cleanup action")
        }
    }

    var systemImage: String {
        switch self {
        case .green: "checkmark.circle"
        case .yellow: "questionmark.circle"
        case .red: "exclamationmark.triangle.fill"
        case .other: "externaldrive"
        }
    }

    var sortRank: Int {
        switch self {
        case .green: 0
        case .yellow: 1
        case .red: 2
        case .other: 3
        }
    }
}

enum ItemStatus: String, Codable, Sendable {
    case available
    case movedToTrash
}

struct CleanupOperationSnapshot: Equatable, Sendable {
    let requestedCount: Int
    let requestedBytes: Int64
    let movedCount: Int
    let movedBytes: Int64
    let failedCount: Int
    let duration: TimeInterval?

    var isComplete: Bool {
        duration != nil
    }
}

enum ReviewFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case healthHub
    case performance
    case green
    case privacy
    case devCaches
    case largeFiles
    case migration
    case duplicates
    case utilityHub
    case startup
    case memory
    case energy
    case uninstall
    case updater

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L10n.text("智能扫描", "Smart Scan")
        case .healthHub: L10n.text("系统健康", "System Health")
        case .performance: L10n.text("性能测试", "Performance Test")
        case .green: L10n.text("安全清理", "Safe Cleanup")
        case .privacy: L10n.text("浏览器隐私", "Browser Privacy")
        case .devCaches: L10n.text("开发工具与产物", "Dev Tools & Artifacts")
        case .largeFiles: L10n.text("大型文件", "Large Files")
        case .migration: L10n.text("文件搬家", "File Migration")
        case .duplicates: L10n.text("重复文件", "Duplicates")
        case .utilityHub: L10n.text("系统工具", "System Tools")
        case .startup: L10n.text("登录项与后台任务", "Login Items & Background Tasks")
        case .memory: L10n.text("内存管理", "Memory Management")
        case .energy: L10n.text("能耗", "Energy")
        case .uninstall: L10n.text("卸载", "Uninstall")
        case .updater: L10n.text("应用更新", "App Updates")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: AppSymbols.Navigation.overview
        case .healthHub: AppSymbols.Navigation.health
        case .performance: AppSymbols.Benchmark.performance
        case .green: AppSymbols.Navigation.safeCleanup
        case .privacy: AppSymbols.Navigation.browserPrivacy
        case .devCaches: AppSymbols.Navigation.developerArtifacts
        case .largeFiles: AppSymbols.Navigation.fileAnalysis
        case .migration: "externaldrive.badge.plus"
        case .duplicates: AppSymbols.Navigation.duplicates
        case .utilityHub: AppSymbols.Navigation.systemTools
        case .startup: AppSymbols.Navigation.loginItems
        case .memory: AppSymbols.Navigation.memory
        case .energy: AppSymbols.Navigation.energy
        case .uninstall: AppSymbols.Navigation.uninstall
        case .updater: AppSymbols.Navigation.appUpdates
        }
    }

    var tier: StorageTier? {
        switch self {
        case .overview, .healthHub, .performance, .privacy, .devCaches, .largeFiles, .migration, .duplicates, .utilityHub, .startup, .memory, .energy, .uninstall, .updater:
            nil
        case .green: .green
        }
    }

    var isStorageFilter: Bool {
        switch self {
        case .overview, .green, .privacy, .devCaches, .largeFiles, .migration, .duplicates:
            true
        case .healthHub, .performance, .utilityHub, .startup, .memory, .energy, .uninstall, .updater:
            false
        }
    }

    static var careCases: [ReviewFilter] {
        [.overview, .healthHub, .performance]
    }

    static var cleanupCases: [ReviewFilter] {
        [.green, .privacy, .devCaches, .largeFiles, .duplicates]
    }

    static var sidebarCleanupCases: [ReviewFilter] {
        [.green, .devCaches, .privacy, .largeFiles]
    }

    static var cleanupWorkspaceCases: [ReviewFilter] {
        [.green, .devCaches]
    }

    static var fileWorkspaceCases: [ReviewFilter] {
        [.largeFiles, .migration, .duplicates]
    }

    static var utilityCases: [ReviewFilter] {
        [.utilityHub]
    }

    static var utilityToolCases: [ReviewFilter] {
        [.startup, .memory, .energy, .uninstall, .updater]
    }

    var sidebarDestination: ReviewFilter {
        switch self {
        case .startup, .memory, .energy, .uninstall, .updater:
            .utilityHub
        case .overview, .healthHub, .performance, .green, .privacy, .devCaches, .largeFiles, .migration, .duplicates, .utilityHub:
            self
        }
    }

    var sidebarGroupAnchor: ReviewFilter {
        switch self {
        case .startup, .memory, .energy, .uninstall, .updater:
            .utilityHub
        case .overview, .healthHub, .performance, .green, .privacy, .devCaches, .largeFiles, .migration, .duplicates, .utilityHub:
            self
        }
    }

    var sidebarTitle: String {
        switch self {
        case .green:
            L10n.text("安全清理", "Safe Cleanup")
        case .largeFiles:
            L10n.text("文件分析", "File Analysis")
        case .migration:
            L10n.text("文件搬家", "File Migration")
        case .privacy:
            L10n.text("浏览器隐私", "Browser Privacy")
        default:
            title
        }
    }

    var utilityToolDestination: ReviewFilter? {
        ReviewFilter.utilityToolCases.contains(self) ? self : nil
    }

    static func resolvedDestination(rawValue: String) -> ReviewFilter? {
        let normalizedRawValue = rawValue.trimmed
        if let filter = ReviewFilter(rawValue: normalizedRawValue) {
            return filter.sidebarDestination
        }

        switch normalizedRawValue {
        case "privacy":
            return .privacy
        case "cleanupHistory", "trashBins", "yellow", "red", "all":
            return .green
        default:
            return nil
        }
    }
}

struct DirectoryEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let sizeBytes: Int64
    let denied: Bool
    let isDirectory: Bool

    init(name: String, path: String, sizeBytes: Int64, denied: Bool = false, isDirectory: Bool = false) {
        self.id = PathSafety.normalizedPath(path)
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.denied = denied
        self.isDirectory = isDirectory
    }
}

struct StorageGroup: Identifiable, Sendable {
    let id: String
    let title: String
    var entries: [DirectoryEntry]
}

struct SystemSnapshot: Sendable {
    let osName: String
    let build: String
    let arch: String
    let user: String
    let home: String
    let filesystem: String
    let purgeable: String
    let diskName: String
    let diskTotalBytes: Int64
    let diskUsedBytes: Int64
    let diskFreeBytes: Int64
}

struct StorageItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let path: String
    let sourceID: String
    let groupTitle: String
    let sizeBytes: Int64
    let tier: StorageTier
    let kind: String
    let reason: String
    let recommendation: String
    let risk: String
    let requiresClose: String
    let trashPaths: [String]
    let openPath: String
    let isDirectory: Bool
    let duplicateGroupID: String?
    let duplicateMatchKind: String?
    let duplicateRelationship: String?
    let duplicatePhysicalReclaimableBytes: Int64?
    var status: ItemStatus

    var canMoveToTrash: Bool {
        tier == .green && !trashPaths.isEmpty && status == .available
    }

    init(
        id: String,
        title: String,
        path: String,
        sourceID: String = "",
        groupTitle: String,
        sizeBytes: Int64,
        tier: StorageTier,
        kind: String,
        reason: String,
        recommendation: String,
        risk: String,
        requiresClose: String,
        trashPaths: [String],
        openPath: String,
        isDirectory: Bool = false,
        duplicateGroupID: String? = nil,
        duplicateMatchKind: String? = nil,
        duplicateRelationship: String? = nil,
        duplicatePhysicalReclaimableBytes: Int64? = nil,
        status: ItemStatus
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.sourceID = sourceID
        self.groupTitle = groupTitle
        self.sizeBytes = sizeBytes
        self.tier = tier
        self.kind = kind
        self.reason = reason
        self.recommendation = recommendation
        self.risk = risk
        self.requiresClose = requiresClose
        self.trashPaths = trashPaths
        self.openPath = openPath
        self.isDirectory = isDirectory
        self.duplicateGroupID = duplicateGroupID
        self.duplicateMatchKind = duplicateMatchKind
        self.duplicateRelationship = duplicateRelationship
        self.duplicatePhysicalReclaimableBytes = duplicatePhysicalReclaimableBytes
        self.status = status
    }
}

struct ScanResult: Sendable {
    private struct DecisionByteTotals: Sendable {
        let green: Int64
        let yellow: Int64
        let red: Int64
        let other: Int64

        func value(for tier: StorageTier) -> Int64 {
            switch tier {
            case .green: green
            case .yellow: yellow
            case .red: red
            case .other: other
            }
        }
    }

    private struct IndexedDecisionItem: Sendable {
        let item: StorageItem
        let normalizedPath: String
    }

    private struct DecisionCache: Sendable {
        let normalizedPaths: [String: String]
        let totals: DecisionByteTotals
    }

    let generatedAt: Date
    let scanSeconds: TimeInterval
    let scanMode: ScanMode
    let scanWasLimited: Bool
    let system: SystemSnapshot
    let groups: [StorageGroup]
    var items: [StorageItem] {
        didSet {
            let cache = Self.makeDecisionCache(
                items: items,
                cachedNormalizedPaths: decisionNormalizedPaths
            )
            decisionNormalizedPaths = cache.normalizedPaths
            decisionByteTotals = cache.totals
        }
    }
    let deniedPaths: [String]
    private var decisionNormalizedPaths: [String: String]
    private var decisionByteTotals: DecisionByteTotals

    init(
        generatedAt: Date,
        scanSeconds: TimeInterval,
        scanMode: ScanMode = .fallback,
        scanWasLimited: Bool = false,
        system: SystemSnapshot,
        groups: [StorageGroup],
        items: [StorageItem],
        deniedPaths: [String],
        decisionPathNormalizer: (String) -> String = PathSafety.normalizedPath
    ) {
        self.generatedAt = generatedAt
        self.scanSeconds = scanSeconds
        self.scanMode = scanMode
        self.scanWasLimited = scanWasLimited
        self.system = system
        self.groups = groups
        self.items = items
        self.deniedPaths = deniedPaths
        let decisionCache = Self.makeDecisionCache(
            items: items,
            pathNormalizer: decisionPathNormalizer
        )
        self.decisionNormalizedPaths = decisionCache.normalizedPaths
        self.decisionByteTotals = decisionCache.totals
    }

    var topItems: [StorageItem] {
        Array(items.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(5))
    }

    var cleanupReviewItems: [StorageItem] {
        items.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status == .available
            }
            if lhs.tier.sortRank != rhs.tier.sortRank {
                return lhs.tier.sortRank < rhs.tier.sortRank
            }
            if lhs.sizeBytes == rhs.sizeBytes {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }
    }

    var greenBytes: Int64 { bytes(for: .green) }
    var yellowBytes: Int64 { bytes(for: .yellow) }
    var redBytes: Int64 { bytes(for: .red) }

    var movedToTrashItems: [StorageItem] {
        items.filter { $0.status == .movedToTrash }
    }

    var movedToTrashBytes: Int64 {
        movedToTrashItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var identifiedDecisionBytes: Int64 {
        greenBytes + yellowBytes + redBytes
    }

    var otherUsedBytes: Int64 {
        max(0, system.diskUsedBytes - identifiedDecisionBytes)
    }

    var allowedTrashPaths: Set<String> {
        Set(items.flatMap { item -> [String] in
            guard item.tier == .green else { return [] }
            return item.trashPaths.map(PathSafety.lexicalPath)
        })
    }

    func items(for filter: ReviewFilter) -> [StorageItem] {
        switch filter {
        case .overview, .healthHub, .performance, .utilityHub, .startup, .memory, .energy, .uninstall, .updater:
            return topItems
        case .privacy:
            return []
        case .devCaches:
            return sourceItems([
                "dev_caches",
                "codex_intermediates",
                "codex_runtime_records",
                "codex_installers"
            ])
        case .largeFiles, .migration:
            return sourceItems(["large_files", "mail_attachments", "downloads"])
        case .duplicates:
            return sourceItems(["duplicate_files"])
        case .green:
            guard let tier = filter.tier else { return [] }
            return items(forTier: tier)
        }
    }

    func items(forTier tier: StorageTier) -> [StorageItem] {
        items
            .filter { $0.tier == tier }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func sourceItems(_ sourceIDs: Set<String>) -> [StorageItem] {
        items
            .filter { sourceIDs.contains($0.sourceID) }
            .sorted { lhs, rhs in
                if lhs.sizeBytes == rhs.sizeBytes {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.sizeBytes > rhs.sizeBytes
            }
    }

    func bytes(for tier: StorageTier) -> Int64 {
        decisionByteTotals.value(for: tier)
    }

    private static func makeDecisionCache(
        items: [StorageItem],
        cachedNormalizedPaths: [String: String] = [:],
        pathNormalizer: (String) -> String = PathSafety.normalizedPath
    ) -> DecisionCache {
        let currentPaths = Set(items.map(\.path))
        var normalizedPaths = cachedNormalizedPaths.filter { currentPaths.contains($0.key) }

        for item in items where item.status == .available && normalizedPaths[item.path] == nil {
            normalizedPaths[item.path] = pathNormalizer(item.path)
        }

        let indexedItems = items.compactMap { item -> IndexedDecisionItem? in
            guard item.status == .available else { return nil }
            guard let normalizedPath = normalizedPaths[item.path] else { return nil }
            return IndexedDecisionItem(item: item, normalizedPath: normalizedPath)
        }
        let broadLargeFileDirectories = outermostBroadLargeFileDirectories(in: indexedItems)

        return DecisionCache(
            normalizedPaths: normalizedPaths,
            totals: DecisionByteTotals(
                green: byteTotal(for: .green, items: indexedItems, broadLargeFileDirectories: broadLargeFileDirectories),
                yellow: byteTotal(for: .yellow, items: indexedItems, broadLargeFileDirectories: broadLargeFileDirectories),
                red: byteTotal(for: .red, items: indexedItems, broadLargeFileDirectories: broadLargeFileDirectories),
                other: byteTotal(for: .other, items: indexedItems, broadLargeFileDirectories: broadLargeFileDirectories)
            )
        )
    }

    private static func byteTotal(
        for tier: StorageTier,
        items: [IndexedDecisionItem],
        broadLargeFileDirectories: [IndexedDecisionItem]
    ) -> Int64 {
        items.reduce(Int64(0)) { total, indexedItem in
            let item = indexedItem.item
            guard item.tier == tier else { return total }

            if item.sourceID == "large_files", item.isDirectory {
                guard broadLargeFileDirectories.contains(where: { $0.item.id == item.id }) else {
                    return total
                }
                let coveredBytes = coveredNonYellowBytes(inside: indexedItem, items: items)
                return total + max(0, item.sizeBytes - coveredBytes)
            }

            if tier == .yellow,
               broadLargeFileDirectories.contains(where: {
                   isDescendant(indexedItem.normalizedPath, of: $0.normalizedPath)
               }) {
                return total
            }
            return total + item.sizeBytes
        }
    }

    private static func outermostBroadLargeFileDirectories(
        in items: [IndexedDecisionItem]
    ) -> [IndexedDecisionItem] {
        let candidates = items
            .filter { $0.item.sourceID == "large_files" && $0.item.isDirectory }
            .sorted { $0.normalizedPath.count < $1.normalizedPath.count }

        return candidates.reduce(into: [IndexedDecisionItem]()) { selected, candidate in
            guard !selected.contains(where: {
                isDescendant(candidate.normalizedPath, of: $0.normalizedPath)
            }) else {
                return
            }
            selected.append(candidate)
        }
    }

    private static func coveredNonYellowBytes(
        inside parent: IndexedDecisionItem,
        items: [IndexedDecisionItem]
    ) -> Int64 {
        let descendants = items
            .filter {
                ($0.item.tier == .green || $0.item.tier == .red)
                    && isDescendant($0.normalizedPath, of: parent.normalizedPath)
            }
            .sorted { $0.normalizedPath.count < $1.normalizedPath.count }

        var selected = [IndexedDecisionItem]()
        for candidate in descendants {
            if selected.contains(where: {
                $0.item.isDirectory && isDescendant(candidate.normalizedPath, of: $0.normalizedPath)
            }) {
                continue
            }
            selected.append(candidate)
        }
        return min(parent.item.sizeBytes, selected.reduce(Int64(0)) { $0 + $1.item.sizeBytes })
    }

    private static func isDescendant(_ childPath: String, of parentPath: String) -> Bool {
        childPath.hasPrefix(parentPath + "/")
    }

    mutating func markMovedToTrash(itemID: String) {
        markMovedToTrash(itemIDs: [itemID])
    }

    mutating func markMovedToTrash(itemIDs: Set<String>) {
        guard !itemIDs.isEmpty else { return }

        var updatedItems = items
        var didChange = false
        for index in updatedItems.indices where itemIDs.contains(updatedItems[index].id) {
            guard updatedItems[index].status != .movedToTrash else { continue }
            updatedItems[index].status = .movedToTrash
            didChange = true
        }

        if didChange {
            items = updatedItems
        }
    }

    mutating func markRestoredFromTrash(paths: Set<String>) {
        guard !paths.isEmpty else { return }

        let restoredPaths = Set(paths.map(PathSafety.lexicalPath))
        var updatedItems = items
        var didChange = false
        for index in updatedItems.indices where updatedItems[index].status == .movedToTrash {
            let itemPaths = Set(updatedItems[index].trashPaths.map(PathSafety.lexicalPath))
            guard !itemPaths.isEmpty, itemPaths.isSubset(of: restoredPaths) else { continue }
            updatedItems[index].status = .available
            didChange = true
        }

        if didChange {
            items = updatedItems
        }
    }

    mutating func replaceItems(sourceID: String, with replacementItems: [StorageItem]) {
        var updatedItems = items.filter { $0.sourceID != sourceID }
        updatedItems.append(contentsOf: replacementItems)
        updatedItems.sort {
            if $0.tier.sortRank == $1.tier.sortRank {
                return $0.sizeBytes > $1.sizeBytes
            }
            return $0.tier.sortRank < $1.tier.sortRank
        }
        items = updatedItems
    }
}
