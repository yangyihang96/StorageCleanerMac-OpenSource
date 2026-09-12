import Foundation

enum ItemScopeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case cleanable
    case needsReview
    case careful
    case removed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .cleanable: L10n.text("可安全清理", "Safe to Clean")
        case .needsReview: L10n.text("需确认", "Needs Review")
        case .careful: L10n.text("谨慎处理", "Handle Carefully")
        case .removed: L10n.text("已移到废纸篓", "Moved to Trash")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "line.3.horizontal.decrease.circle"
        case .cleanable: "checkmark.circle"
        case .needsReview: "questionmark.circle"
        case .careful: "exclamationmark.triangle"
        case .removed: "trash.circle"
        }
    }

    func includes(_ item: StorageItem) -> Bool {
        switch self {
        case .all:
            true
        case .cleanable:
            item.canMoveToTrash
        case .needsReview:
            item.tier == .yellow && item.status == .available
        case .careful:
            item.tier == .red && item.status == .available
        case .removed:
            item.status == .movedToTrash
        }
    }
}

enum ItemSortMode: String, CaseIterable, Identifiable, Sendable {
    case sizeDescending
    case sizeAscending
    case name
    case safety
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sizeDescending: L10n.text("按大小", "Size")
        case .sizeAscending: L10n.text("小到大", "Small First")
        case .name: L10n.text("按名称", "Name")
        case .safety: L10n.text("按风险", "Safety")
        case .kind: L10n.text("按类型", "Kind")
        }
    }

    var systemImage: String {
        switch self {
        case .sizeDescending: "arrow.down.circle"
        case .sizeAscending: "arrow.up.circle"
        case .name: "textformat.abc"
        case .safety: "shield.lefthalf.filled"
        case .kind: "tag"
        }
    }
}

struct ItemListMetrics: Sendable {
    let rawCount: Int
    let visibleCount: Int
    let visibleBytes: Int64
    let cleanableCount: Int
    let reviewCount: Int
    let carefulCount: Int
}

enum ItemListPresenter {
    static func availableScopes(for items: [StorageItem]) -> [ItemScopeFilter] {
        ItemScopeFilter.allCases.filter { scope in
            scope == .all || items.contains { scope.includes($0) }
        }
    }

    static func visibleItems(
        from rawItems: [StorageItem],
        query: String,
        scopeFilter: ItemScopeFilter,
        sortMode: ItemSortMode
    ) -> [StorageItem] {
        let scopedItems = rawItems.filter { scopeFilter.includes($0) }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchedItems: [StorageItem]

        if trimmedQuery.isEmpty {
            searchedItems = scopedItems
        } else {
            searchedItems = scopedItems.filter { item in
                item.title.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.path.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.kind.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.groupTitle.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.reason.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.recommendation.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.risk.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }

        return sort(searchedItems, by: sortMode)
    }

    static func metrics(rawItems: [StorageItem], visibleItems: [StorageItem]) -> ItemListMetrics {
        ItemListMetrics(
            rawCount: rawItems.count,
            visibleCount: visibleItems.count,
            visibleBytes: visibleItems.reduce(0) { $0 + $1.sizeBytes },
            cleanableCount: rawItems.filter(\.canMoveToTrash).count,
            reviewCount: rawItems.filter { $0.tier == .yellow && $0.status == .available }.count,
            carefulCount: rawItems.filter { $0.tier == .red && $0.status == .available }.count
        )
    }

    static func sort(_ items: [StorageItem], by sortMode: ItemSortMode) -> [StorageItem] {
        items.sorted { lhs, rhs in
            switch sortMode {
            case .sizeDescending:
                if lhs.sizeBytes == rhs.sizeBytes { return compareTitle(lhs, rhs) }
                return lhs.sizeBytes > rhs.sizeBytes
            case .sizeAscending:
                if lhs.sizeBytes == rhs.sizeBytes { return compareTitle(lhs, rhs) }
                return lhs.sizeBytes < rhs.sizeBytes
            case .name:
                return compareTitle(lhs, rhs)
            case .safety:
                if lhs.tier.sortRank == rhs.tier.sortRank {
                    if lhs.sizeBytes == rhs.sizeBytes { return compareTitle(lhs, rhs) }
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                return lhs.tier.sortRank < rhs.tier.sortRank
            case .kind:
                let kindOrder = lhs.kind.localizedStandardCompare(rhs.kind)
                if kindOrder == .orderedSame {
                    if lhs.sizeBytes == rhs.sizeBytes { return compareTitle(lhs, rhs) }
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                return kindOrder == .orderedAscending
            }
        }
    }

    private static func compareTitle(_ lhs: StorageItem, _ rhs: StorageItem) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
