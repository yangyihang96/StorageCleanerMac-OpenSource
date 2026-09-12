import Foundation

struct CleanupHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let title: String
    let itemCount: Int
    let totalBytes: Int64
    let paths: [String]
    let moveRecords: [TrashMoveRecord]

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case title
        case itemCount
        case totalBytes
        case paths
        case moveRecords
    }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        title: String,
        itemCount: Int,
        totalBytes: Int64,
        paths: [String],
        moveRecords: [TrashMoveRecord] = []
    ) {
        self.id = id
        self.date = date
        self.title = title
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.paths = paths
        self.moveRecords = moveRecords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        title = try container.decode(String.self, forKey: .title)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        paths = try container.decode([String].self, forKey: .paths)
        moveRecords = try container.decodeIfPresent([TrashMoveRecord].self, forKey: .moveRecords) ?? []
    }

    var restorableMoveRecords: [TrashMoveRecord] {
        moveRecords.filter { $0.itemIdentity != nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(title, forKey: .title)
        try container.encode(itemCount, forKey: .itemCount)
        try container.encode(totalBytes, forKey: .totalBytes)
        try container.encode(paths, forKey: .paths)
        if !moveRecords.isEmpty {
            try container.encode(moveRecords, forKey: .moveRecords)
        }
    }
}

struct CleanupHistorySummary: Equatable, Sendable {
    let entries: [CleanupHistoryEntry]

    var totalCount: Int {
        entries.reduce(0) { $0 + $1.itemCount }
    }

    var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.totalBytes }
    }

    var latest: CleanupHistoryEntry? {
        entries.sorted { $0.date > $1.date }.first
    }

    var latestRestorable: CleanupHistoryEntry? {
        entries
            .sorted { $0.date > $1.date }
            .first { !$0.restorableMoveRecords.isEmpty }
    }
}

enum CleanupHistoryService {
    static let defaultsKey = "cleanup.history"
    private static let maxEntries = 80

    static func recordMovedItems(
        _ items: [StorageItem],
        moveRecords: [TrashMoveRecord] = [],
        date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let movedItems = items.filter { $0.sizeBytes > 0 }
        guard !movedItems.isEmpty else { return }

        let movedPaths = movedItems.flatMap { item in
            item.trashPaths.isEmpty ? [item.path] : item.trashPaths
        }
        let lexicalMovedPaths = Set(movedPaths.map(PathSafety.lexicalPath))
        var seenRecordIDs = Set<UUID>()
        let matchingMoveRecords = moveRecords.filter { record in
            guard seenRecordIDs.insert(record.id).inserted,
                  record.resultingItemURL.isFileURL,
                  record.itemIdentity != nil else {
                return false
            }
            return lexicalMovedPaths.contains(PathSafety.lexicalPath(record.originalPath))
        }

        let entry = CleanupHistoryEntry(
            date: date,
            title: historyTitle(for: movedItems),
            itemCount: movedItems.count,
            totalBytes: movedItems.reduce(0) { $0 + $1.sizeBytes },
            paths: movedPaths,
            moveRecords: matchingMoveRecords
        )

        var entries = load(defaults: defaults)
        entries.insert(entry, at: 0)
        save(Array(entries.prefix(maxEntries)), defaults: defaults)
    }

    static func load(defaults: UserDefaults = .standard) -> [CleanupHistoryEntry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([CleanupHistoryEntry].self, from: data) else {
            return []
        }

        return Array(entries
            .sorted { $0.date > $1.date }
            .prefix(maxEntries))
    }

    static func summary(defaults: UserDefaults = .standard) -> CleanupHistorySummary {
        CleanupHistorySummary(entries: load(defaults: defaults))
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    static func removeMoveRecords(
        entryID: UUID,
        recordIDs: Set<UUID>,
        defaults: UserDefaults = .standard
    ) {
        guard !recordIDs.isEmpty else { return }
        let updatedEntries = load(defaults: defaults).map { entry in
            guard entry.id == entryID else { return entry }
            return CleanupHistoryEntry(
                id: entry.id,
                date: entry.date,
                title: entry.title,
                itemCount: entry.itemCount,
                totalBytes: entry.totalBytes,
                paths: entry.paths,
                moveRecords: entry.moveRecords.filter { !recordIDs.contains($0.id) }
            )
        }
        save(updatedEntries, defaults: defaults)
    }

    static func markdown(for entry: CleanupHistoryEntry) -> String {
        var lines = [
            "# \(L10n.text("清理记录", "Cleanup Record"))",
            "",
            "- \(L10n.text("批次", "Batch")): \(entry.title)",
            "- \(L10n.text("时间", "Time")): \(entry.date.formatted(date: .abbreviated, time: .shortened))",
            "- \(L10n.text("项目", "Items")): \(L10n.items(entry.itemCount))",
            "- \(L10n.text("移入体积", "Moved Size")): \(ByteFormat.string(entry.totalBytes))",
            "- \(L10n.text("安全边界", "Safety Boundary")): \(L10n.text("这些项目只是移到废纸篓，清空废纸篓前仍可恢复。", "These items were only moved to Trash and remain recoverable until Trash is emptied."))",
            "",
            "## \(L10n.text("路径", "Paths"))"
        ]

        if entry.paths.isEmpty {
            lines.append("- \(L10n.text("没有记录路径", "No paths recorded"))")
        } else {
            lines.append(contentsOf: entry.paths.map { "- `\($0)`" })
        }

        return lines.joined(separator: "\n")
    }

    private static func save(_ entries: [CleanupHistoryEntry], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func historyTitle(for items: [StorageItem]) -> String {
        if items.count == 1 {
            return items[0].title
        }
        return L10n.text("绿色缓存批量清理", "Green cache cleanup")
    }
}
