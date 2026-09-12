import Foundation

struct ScanHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case scanSeconds
        case score
        case diskUsedBytes
        case diskFreeBytes
        case greenBytes
        case yellowBytes
        case redBytes
        case itemCount
        case greenCount
        case yellowCount
        case redCount
        case deniedCount
        case scanMode
        case permissionPenalty
        case scoreModelVersion
        case actionableGreenBytes
        case actionableGreenCount
        case scanWasLimited
    }

    let id: UUID
    let date: Date
    let scanSeconds: TimeInterval
    let score: Int
    let diskUsedBytes: Int64
    let diskFreeBytes: Int64
    let greenBytes: Int64
    let yellowBytes: Int64
    let redBytes: Int64
    let itemCount: Int
    let greenCount: Int
    let yellowCount: Int
    let redCount: Int
    let deniedCount: Int
    let scanMode: ScanMode?
    let permissionPenalty: Int?
    let scoreModelVersion: Int?
    let actionableGreenBytes: Int64?
    let actionableGreenCount: Int?
    let scanWasLimited: Bool?

    init(
        id: UUID = UUID(),
        date: Date,
        scanSeconds: TimeInterval,
        score: Int,
        diskUsedBytes: Int64,
        diskFreeBytes: Int64,
        greenBytes: Int64,
        yellowBytes: Int64,
        redBytes: Int64,
        itemCount: Int,
        greenCount: Int,
        yellowCount: Int,
        redCount: Int,
        deniedCount: Int,
        scanMode: ScanMode? = nil,
        permissionPenalty: Int? = nil,
        scoreModelVersion: Int? = nil,
        actionableGreenBytes: Int64? = nil,
        actionableGreenCount: Int? = nil,
        scanWasLimited: Bool? = nil
    ) {
        self.id = id
        self.date = date
        self.scanSeconds = scanSeconds
        self.score = score
        self.diskUsedBytes = diskUsedBytes
        self.diskFreeBytes = diskFreeBytes
        self.greenBytes = greenBytes
        self.yellowBytes = yellowBytes
        self.redBytes = redBytes
        self.itemCount = itemCount
        self.greenCount = greenCount
        self.yellowCount = yellowCount
        self.redCount = redCount
        self.deniedCount = deniedCount
        self.scanMode = scanMode
        self.permissionPenalty = permissionPenalty
        self.scoreModelVersion = scoreModelVersion
        self.actionableGreenBytes = actionableGreenBytes
        self.actionableGreenCount = actionableGreenCount
        self.scanWasLimited = scanWasLimited
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        scanSeconds = try container.decode(TimeInterval.self, forKey: .scanSeconds)
        score = try container.decode(Int.self, forKey: .score)
        diskUsedBytes = try container.decode(Int64.self, forKey: .diskUsedBytes)
        diskFreeBytes = try container.decode(Int64.self, forKey: .diskFreeBytes)
        greenBytes = try container.decode(Int64.self, forKey: .greenBytes)
        yellowBytes = try container.decode(Int64.self, forKey: .yellowBytes)
        redBytes = try container.decode(Int64.self, forKey: .redBytes)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        greenCount = try container.decode(Int.self, forKey: .greenCount)
        yellowCount = try container.decode(Int.self, forKey: .yellowCount)
        redCount = try container.decode(Int.self, forKey: .redCount)
        deniedCount = try container.decode(Int.self, forKey: .deniedCount)
        if let rawMode = try container.decodeIfPresent(String.self, forKey: .scanMode) {
            scanMode = ScanMode(rawValue: rawMode)
        } else {
            scanMode = nil
        }
        permissionPenalty = try container.decodeIfPresent(Int.self, forKey: .permissionPenalty)
        scoreModelVersion = try container.decodeIfPresent(Int.self, forKey: .scoreModelVersion)
        actionableGreenBytes = try container.decodeIfPresent(Int64.self, forKey: .actionableGreenBytes)
        actionableGreenCount = try container.decodeIfPresent(Int.self, forKey: .actionableGreenCount)
        scanWasLimited = try container.decodeIfPresent(Bool.self, forKey: .scanWasLimited)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(scanSeconds, forKey: .scanSeconds)
        try container.encode(score, forKey: .score)
        try container.encode(diskUsedBytes, forKey: .diskUsedBytes)
        try container.encode(diskFreeBytes, forKey: .diskFreeBytes)
        try container.encode(greenBytes, forKey: .greenBytes)
        try container.encode(yellowBytes, forKey: .yellowBytes)
        try container.encode(redBytes, forKey: .redBytes)
        try container.encode(itemCount, forKey: .itemCount)
        try container.encode(greenCount, forKey: .greenCount)
        try container.encode(yellowCount, forKey: .yellowCount)
        try container.encode(redCount, forKey: .redCount)
        try container.encode(deniedCount, forKey: .deniedCount)
        try container.encodeIfPresent(scanMode?.rawValue, forKey: .scanMode)
        try container.encodeIfPresent(permissionPenalty, forKey: .permissionPenalty)
        try container.encodeIfPresent(scoreModelVersion, forKey: .scoreModelVersion)
        try container.encodeIfPresent(actionableGreenBytes, forKey: .actionableGreenBytes)
        try container.encodeIfPresent(actionableGreenCount, forKey: .actionableGreenCount)
        try container.encodeIfPresent(scanWasLimited, forKey: .scanWasLimited)
    }

    var usesCurrentScoreModel: Bool {
        scoreModelVersion == ScanHistoryService.currentScoreModelVersion
    }
}

struct ScanHistorySummary: Equatable, Sendable {
    let entries: [ScanHistoryEntry]

    var latest: ScanHistoryEntry? {
        entries.first
    }

    var previous: ScanHistoryEntry? {
        entries.dropFirst().first
    }

    var averageScore: Int {
        guard !entries.isEmpty else { return 0 }
        return entries.reduce(0) { $0 + $1.score } / entries.count
    }

    var totalGreenBytesSeen: Int64 {
        entries.reduce(0) { max($0, $1.greenBytes) }
    }

    var usedDeltaBytes: Int64? {
        guard let latest, let previous else { return nil }
        return latest.diskUsedBytes - previous.diskUsedBytes
    }

    var trend: ScanHistoryTrend? {
        guard let latest, let previous else { return nil }
        return ScanHistoryTrend(latest: latest, previous: previous)
    }

    func latestStatus(referenceDate: Date = Date()) -> LastScanStatusSummary? {
        guard let latest else { return nil }
        return LastScanStatusSummary(
            entry: latest,
            freshness: ScanFreshnessService.summary(
                generatedAt: latest.date,
                referenceDate: referenceDate
            )
        )
    }
}

struct ScanHistoryTrend: Equatable, Sendable {
    let latest: ScanHistoryEntry
    let previous: ScanHistoryEntry

    var scoreDelta: Int {
        latest.score - previous.score
    }

    var usedDeltaBytes: Int64 {
        latest.diskUsedBytes - previous.diskUsedBytes
    }

    var greenDeltaBytes: Int64 {
        latest.greenBytes - previous.greenBytes
    }

    var reviewDeltaBytes: Int64 {
        (latest.yellowBytes + latest.redBytes) - (previous.yellowBytes + previous.redBytes)
    }

    var deniedDelta: Int {
        latest.deniedCount - previous.deniedCount
    }
}

enum LastScanAttentionLevel: Equatable, Sendable {
    case current
    case rescanRecommended
    case permissionLimited
}

enum LastScanRecommendedAction: Equatable, Sendable {
    case repairAccess
    case rescan
    case reviewResult
}

struct LastScanStatusSummary: Equatable, Sendable {
    let entry: ScanHistoryEntry
    let freshness: ScanFreshnessSummary

    var attentionLevel: LastScanAttentionLevel {
        if entry.deniedCount > 0 {
            return .permissionLimited
        }
        if entry.scanWasLimited == true || freshness.shouldRescan {
            return .rescanRecommended
        }
        return .current
    }

    var shouldRescan: Bool {
        attentionLevel != .current
    }

    var recommendedAction: LastScanRecommendedAction {
        switch attentionLevel {
        case .permissionLimited:
            .repairAccess
        case .rescanRecommended:
            .rescan
        case .current:
            .reviewResult
        }
    }

    var reviewBytes: Int64 {
        entry.yellowBytes + entry.redBytes
    }
}

enum SmartScoreBand: String, CaseIterable, Equatable, Sendable {
    case excellent
    case good
    case fair
    case attention
    case critical

    init(score: Int) {
        switch score {
        case 96...:
            self = .excellent
        case 88...:
            self = .good
        case 75...:
            self = .fair
        case 60...:
            self = .attention
        default:
            self = .critical
        }
    }

    var title: String {
        switch self {
        case .excellent:
            L10n.text("状态极佳", "Excellent")
        case .good:
            L10n.text("状态良好", "Good")
        case .fair:
            L10n.text("建议维护", "Maintenance Suggested")
        case .attention:
            L10n.text("需要处理", "Needs Attention")
        case .critical:
            L10n.text("需要优先处理", "Priority Action Needed")
        }
    }

    var summary: String {
        switch self {
        case .excellent:
            L10n.text("空间余量充足，安全清理积压很少，扫描结果可信。", "Storage headroom is ample, safe-cleanup backlog is low, and the scan is reliable.")
        case .good:
            L10n.text("整体状态良好，按建议处理少量可改善项即可。", "Overall health is good; only a few suggested improvements remain.")
        case .fair:
            L10n.text("已有可改善项，建议优先处理安全清理和空间余量。", "Some improvements are available; prioritize safe cleanup and storage headroom.")
        case .attention:
            L10n.text("状态或扫描可信度需要关注，请先处理主要扣分项。", "Health or scan confidence needs attention; address the largest deductions first.")
        case .critical:
            L10n.text("空间压力或扫描缺口明显，请优先处理关键扣分项。", "Storage pressure or scan gaps are significant; address critical deductions first.")
        }
    }
}

enum SmartScoreFactorKind: String, Hashable, Sendable {
    case diskPressure
    case cleanupBacklog
    case permissions
    case scanCompleteness
    case freshness
}

enum SmartScoreSeverity: Equatable, Sendable {
    case good
    case notice
    case warning
    case critical
}

struct SmartScoreFactor: Identifiable, Equatable, Sendable {
    let id: SmartScoreFactorKind
    let title: String
    let detail: String
    let systemImage: String
    let penalty: Int
    let severity: SmartScoreSeverity
}

struct SmartScoreBreakdown: Equatable, Sendable {
    let score: Int
    let diskTotalBytes: Int64
    let diskUsedBytes: Int64
    let greenBytes: Int64
    let actionableGreenBytes: Int64
    let yellowBytes: Int64
    let redBytes: Int64
    let greenCount: Int
    let actionableGreenCount: Int
    let yellowCount: Int
    let redCount: Int
    let deniedCount: Int
    let scanMode: ScanMode
    let scanWasLimited: Bool
    let freshnessLevel: ScanFreshnessLevel?
    let diskPressurePenalty: Int
    let cleanupBacklogPenalty: Int
    let permissionPenalty: Int
    let scanScopePenalty: Int
    let freshnessPenalty: Int

    var totalPenalty: Int {
        diskPressurePenalty
            + cleanupBacklogPenalty
            + permissionPenalty
            + scanScopePenalty
            + freshnessPenalty
    }

    var healthPenalty: Int {
        diskPressurePenalty + cleanupBacklogPenalty
    }

    var confidencePenalty: Int {
        permissionPenalty + scanScopePenalty + freshnessPenalty
    }

    var band: SmartScoreBand {
        SmartScoreBand(score: score)
    }

    var confidenceDetail: String {
        var reasons = [String]()
        if permissionPenalty > 0 {
            reasons.append(L10n.text("权限缺口", "access gaps"))
        }
        if scanScopePenalty > 0 {
            reasons.append(L10n.text("扫描未完成", "incomplete scan"))
        }
        if freshnessPenalty > 0 {
            reasons.append(L10n.text("结果时效", "freshness"))
        }

        if reasons.isEmpty {
            return L10n.text("权限、口径和时效都完整", "Access, scope, and freshness are complete")
        }

        return reasons.joined(separator: L10n.text("、", ", "))
    }

    var factors: [SmartScoreFactor] {
        var items = [
            SmartScoreFactor(
                id: .diskPressure,
                title: L10n.text("磁盘压力", "Disk Pressure"),
                detail: L10n.text(
                    "可用 \(ByteFormat.string(max(0, diskTotalBytes - diskUsedBytes)))（\(ByteFormat.percent(max(0, diskTotalBytes - diskUsedBytes), of: diskTotalBytes))）",
                    "\(ByteFormat.string(max(0, diskTotalBytes - diskUsedBytes))) available (\(ByteFormat.percent(max(0, diskTotalBytes - diskUsedBytes), of: diskTotalBytes)))"
                ),
                systemImage: "chart.pie.fill",
                penalty: diskPressurePenalty,
                severity: severity(for: diskPressurePenalty, notice: 1, warning: 11, critical: 31)
            ),
            SmartScoreFactor(
                id: .cleanupBacklog,
                title: L10n.text("可清理积压", "Cleanup Backlog"),
                detail: L10n.text(
                    "\(actionableGreenCount) 项可安全清理 · \(ByteFormat.string(actionableGreenBytes))",
                    "\(L10n.items(actionableGreenCount)) safe to clean · \(ByteFormat.string(actionableGreenBytes))"
                ),
                systemImage: "sparkles",
                penalty: cleanupBacklogPenalty,
                severity: severity(for: cleanupBacklogPenalty, notice: 1, warning: 8, critical: 16)
            ),
            SmartScoreFactor(
                id: .permissions,
                title: L10n.text("权限缺口", "Access Gaps"),
                detail: deniedCount == 0
                    ? L10n.text("扫描口径完整", "Full scan scope")
                    : L10n.text("\(deniedCount) 个位置未读取", "\(deniedCount) locations unreadable"),
                systemImage: deniedCount == 0 ? "checkmark.seal.fill" : "lock.fill",
                penalty: permissionPenalty,
                severity: permissionPenalty == 0 ? .good : severity(for: permissionPenalty, notice: 2, warning: 6, critical: 10)
            ),
            SmartScoreFactor(
                id: .scanCompleteness,
                title: L10n.text("扫描完整度", "Scan Completeness"),
                detail: scanWasLimited
                    ? L10n.text("达到扫描预算或安全数量上限，部分位置未完成", "A scan budget or safety cap was reached; some locations were not completed")
                    : L10n.text("本次扫描按计划完成", "This scan completed as planned"),
                systemImage: scanWasLimited ? "clock.badge.exclamationmark" : scanMode.systemImage,
                penalty: scanScopePenalty,
                severity: scanWasLimited ? .warning : .good
            )
        ]

        if let freshnessLevel {
            items.append(
                SmartScoreFactor(
                    id: .freshness,
                    title: L10n.text("结果时效", "Freshness"),
                    detail: freshnessDetail(for: freshnessLevel),
                    systemImage: freshnessLevel == .fresh ? "clock.fill" : "clock.badge.exclamationmark",
                    penalty: freshnessPenalty,
                    severity: freshnessLevel == .fresh ? .good : (freshnessLevel == .aging ? .notice : .warning)
                )
            )
        }

        return items
    }

    private func severity(for penalty: Int, notice: Int, warning: Int, critical: Int) -> SmartScoreSeverity {
        if penalty >= critical { return .critical }
        if penalty >= warning { return .warning }
        if penalty >= notice { return .notice }
        return .good
    }

    private func freshnessDetail(for level: ScanFreshnessLevel) -> String {
        switch level {
        case .fresh:
            L10n.text("2 小时内", "Under 2h")
        case .aging:
            L10n.text("超过 2 小时，建议重新扫描", "Over 2h, rescan recommended")
        case .stale:
            L10n.text("超过 24 小时，请先重新扫描", "Over 24h, rescan first")
        }
    }
}

struct CleanupScoreProjection: Equatable, Sendable {
    let current: SmartScoreBreakdown
    let projected: SmartScoreBreakdown
    let cleanableBytes: Int64
    let cleanableCount: Int

    var scoreDelta: Int {
        projected.score - current.score
    }

    var cleanupPenaltyDelta: Int {
        current.cleanupBacklogPenalty - projected.cleanupBacklogPenalty
    }

    var hasCleanableItems: Bool {
        cleanableCount > 0 && cleanableBytes > 0
    }
}

enum CleanupFollowUpStage: Equatable, Sendable {
    case readyToClean
    case needsTrashReview
    case noCleanableItems
}

struct CleanupFollowUpSummary: Equatable, Sendable {
    let projection: CleanupScoreProjection
    let movedToTrashCount: Int
    let movedToTrashBytes: Int64

    var stage: CleanupFollowUpStage {
        if movedToTrashCount > 0 {
            return .needsTrashReview
        }
        if projection.hasCleanableItems {
            return .readyToClean
        }
        return .noCleanableItems
    }

    var primaryCount: Int {
        movedToTrashCount > 0 ? movedToTrashCount : projection.cleanableCount
    }

    var primaryBytes: Int64 {
        movedToTrashCount > 0 ? movedToTrashBytes : projection.cleanableBytes
    }
}

enum ScanHistoryService {
    static let defaultsKey = "scan.history"
    static let currentScoreModelVersion = 2
    private static let maxEntries = 60

    static func record(
        _ result: ScanResult,
        date: Date? = nil,
        defaults: UserDefaults = .standard
    ) {
        let entry = entry(from: result, date: date ?? result.generatedAt)
        var entries = load(defaults: defaults)
        entries.insert(entry, at: 0)
        save(Array(entries.prefix(maxEntries)), defaults: defaults)
    }

    static func entry(from result: ScanResult, date: Date? = nil) -> ScanHistoryEntry {
        let breakdown = scoreBreakdown(for: result)
        let actionableItems = result.items.filter(\.canMoveToTrash)
        return ScanHistoryEntry(
            date: date ?? result.generatedAt,
            scanSeconds: result.scanSeconds,
            score: breakdown.score,
            diskUsedBytes: result.system.diskUsedBytes,
            diskFreeBytes: result.system.diskFreeBytes,
            greenBytes: result.greenBytes,
            yellowBytes: result.yellowBytes,
            redBytes: result.redBytes,
            itemCount: result.items.count,
            greenCount: result.items(forTier: .green).count,
            yellowCount: result.items(forTier: .yellow).count,
            redCount: result.items(forTier: .red).count,
            deniedCount: breakdown.deniedCount,
            scanMode: result.scanMode,
            permissionPenalty: breakdown.permissionPenalty,
            scoreModelVersion: currentScoreModelVersion,
            actionableGreenBytes: actionableItems.reduce(0) { $0 + max(0, $1.sizeBytes) },
            actionableGreenCount: actionableItems.count,
            scanWasLimited: result.scanWasLimited
        )
    }

    static func load(defaults: UserDefaults = .standard) -> [ScanHistoryEntry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([ScanHistoryEntry].self, from: data) else {
            return []
        }
        return Array(entries
            .map(rebalancedScore)
            .sorted { $0.date > $1.date }
            .prefix(maxEntries))
    }

    static func summary(defaults: UserDefaults = .standard) -> ScanHistorySummary {
        ScanHistorySummary(entries: load(defaults: defaults))
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    private static func save(_ entries: [ScanHistoryEntry], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func smartScore(for result: ScanResult, referenceDate: Date? = nil) -> Int {
        scoreBreakdown(for: result, referenceDate: referenceDate).score
    }

    static func scoreBreakdown(for result: ScanResult, referenceDate: Date? = nil) -> SmartScoreBreakdown {
        let coverage = ScanCoverageService.summary(deniedPaths: result.deniedPaths)
        let actionableItems = result.items.filter(\.canMoveToTrash)
        let freshness = referenceDate.map {
            ScanFreshnessService.summary(generatedAt: result.generatedAt, referenceDate: $0)
        }
        return scoreBreakdown(
            diskTotalBytes: result.system.diskTotalBytes,
            diskUsedBytes: result.system.diskUsedBytes,
            greenBytes: result.greenBytes,
            yellowBytes: result.yellowBytes,
            redBytes: result.redBytes,
            greenCount: result.items(forTier: .green).count,
            actionableGreenBytes: actionableItems.reduce(0) { $0 + max(0, $1.sizeBytes) },
            actionableGreenCount: actionableItems.count,
            yellowCount: result.items(forTier: .yellow).count,
            redCount: result.items(forTier: .red).count,
            deniedCount: coverage.deniedCount,
            scanMode: result.scanMode,
            scanWasLimited: result.scanWasLimited,
            permissionPenalty: coverage.scorePenalty,
            freshnessLevel: freshness?.level,
            freshnessPenalty: freshness.map { freshnessPenalty(for: $0.level) } ?? 0
        )
    }

    static func cleanupProjection(for result: ScanResult) -> CleanupScoreProjection {
        let candidates = result.items.filter(\.canMoveToTrash)
        var projectedResult = result
        projectedResult.markMovedToTrash(itemIDs: Set(candidates.map(\.id)))

        return CleanupScoreProjection(
            current: scoreBreakdown(for: result),
            projected: scoreBreakdown(for: projectedResult),
            cleanableBytes: candidates.reduce(0) { $0 + $1.sizeBytes },
            cleanableCount: candidates.count
        )
    }

    static func cleanupFollowUp(for result: ScanResult) -> CleanupFollowUpSummary {
        CleanupFollowUpSummary(
            projection: cleanupProjection(for: result),
            movedToTrashCount: result.movedToTrashItems.count,
            movedToTrashBytes: result.movedToTrashBytes
        )
    }

    private static func scoreBreakdown(
        diskTotalBytes: Int64,
        diskUsedBytes: Int64,
        greenBytes: Int64,
        yellowBytes: Int64,
        redBytes: Int64,
        greenCount: Int,
        actionableGreenBytes: Int64,
        actionableGreenCount: Int,
        yellowCount: Int,
        redCount: Int,
        deniedCount: Int,
        scanMode: ScanMode = .standard,
        scanWasLimited: Bool = false,
        permissionPenalty: Int? = nil,
        freshnessLevel: ScanFreshnessLevel? = nil,
        freshnessPenalty: Int = 0
    ) -> SmartScoreBreakdown {
        let total = max(1, diskTotalBytes)
        let storagePenalty = diskPressurePenalty(
            totalBytes: total,
            usedBytes: max(0, diskUsedBytes)
        )
        let cleanupBacklogPenalty = cleanupBacklogPenalty(
            totalBytes: total,
            actionableBytes: max(0, actionableGreenBytes)
        )
        let permissionPenalty = min(
            10,
            max(0, permissionPenalty ?? ScanCoverageService.scorePenalty(deniedCount: deniedCount))
        )
        let scanScopePenalty = scanWasLimited ? 5 : 0
        let freshnessPenalty = min(5, max(0, freshnessPenalty))
        let totalPenalty = storagePenalty
            + cleanupBacklogPenalty
            + permissionPenalty
            + scanScopePenalty
            + freshnessPenalty
        let score = max(0, 100 - totalPenalty)

        return SmartScoreBreakdown(
            score: score,
            diskTotalBytes: diskTotalBytes,
            diskUsedBytes: diskUsedBytes,
            greenBytes: greenBytes,
            actionableGreenBytes: actionableGreenBytes,
            yellowBytes: yellowBytes,
            redBytes: redBytes,
            greenCount: greenCount,
            actionableGreenCount: actionableGreenCount,
            yellowCount: yellowCount,
            redCount: redCount,
            deniedCount: deniedCount,
            scanMode: scanMode,
            scanWasLimited: scanWasLimited,
            freshnessLevel: freshnessLevel,
            diskPressurePenalty: storagePenalty,
            cleanupBacklogPenalty: cleanupBacklogPenalty,
            permissionPenalty: permissionPenalty,
            scanScopePenalty: scanScopePenalty,
            freshnessPenalty: freshnessPenalty
        )
    }

    private static func freshnessPenalty(for level: ScanFreshnessLevel) -> Int {
        switch level {
        case .fresh:
            0
        case .aging:
            2
        case .stale:
            5
        }
    }

    private static func diskPressurePenalty(totalBytes: Int64, usedBytes: Int64) -> Int {
        let total = Double(max(1, totalBytes))
        let freeBytes = Double(max(0, totalBytes - usedBytes))
        let freeRatio = freeBytes / total
        let freeGiB = freeBytes / 1_073_741_824
        let headroom = min(1, max(0, max(freeRatio / 0.15, freeGiB / 64)))

        if headroom >= 1 {
            return 0
        }
        if headroom >= 2.0 / 3.0 {
            return min(10, max(1, Int((30 * (1 - headroom)).rounded(.up))))
        }
        if headroom >= 1.0 / 3.0 {
            return min(30, 10 + Int((60 * ((2.0 / 3.0) - headroom)).rounded(.up)))
        }
        if headroom >= 1.0 / 8.0 {
            let range = (1.0 / 3.0) - (1.0 / 8.0)
            let progress = ((1.0 / 3.0) - headroom) / range
            return min(48, 30 + Int((18 * progress).rounded(.up)))
        }

        let progress = ((1.0 / 8.0) - headroom) / (1.0 / 8.0)
        return min(60, 48 + Int((12 * progress).rounded(.up)))
    }

    private static func cleanupBacklogPenalty(totalBytes: Int64, actionableBytes: Int64) -> Int {
        let bytesPerGiB = 1_073_741_824.0
        let totalGiB = Double(max(1, totalBytes)) / bytesPerGiB
        let actionableGiB = Double(max(0, actionableBytes)) / bytesPerGiB
        let allowanceGiB = min(4, max(1, totalGiB * 0.0025))

        guard actionableGiB > allowanceGiB else { return 0 }

        let fullPenaltyAtGiB = max(allowanceGiB * 8, min(totalGiB * 0.03, 32))
        guard fullPenaltyAtGiB > allowanceGiB else { return 20 }

        let burden = min(
            1,
            max(0, (actionableGiB - allowanceGiB) / (fullPenaltyAtGiB - allowanceGiB))
        )
        return min(20, max(1, Int((20 * burden).rounded(.up))))
    }

    private static func rebalancedScore(_ entry: ScanHistoryEntry) -> ScanHistoryEntry {
        guard entry.scoreModelVersion == currentScoreModelVersion,
              let scanMode = entry.scanMode,
              let permissionPenalty = entry.permissionPenalty,
              let actionableGreenBytes = entry.actionableGreenBytes,
              let actionableGreenCount = entry.actionableGreenCount else {
            return entry
        }

        let recalculatedScore = scoreBreakdown(
            diskTotalBytes: entry.diskUsedBytes + entry.diskFreeBytes,
            diskUsedBytes: entry.diskUsedBytes,
            greenBytes: entry.greenBytes,
            yellowBytes: entry.yellowBytes,
            redBytes: entry.redBytes,
            greenCount: entry.greenCount,
            actionableGreenBytes: actionableGreenBytes,
            actionableGreenCount: actionableGreenCount,
            yellowCount: entry.yellowCount,
            redCount: entry.redCount,
            deniedCount: entry.deniedCount,
            scanMode: scanMode,
            scanWasLimited: entry.scanWasLimited ?? false,
            permissionPenalty: permissionPenalty
        ).score

        guard recalculatedScore != entry.score else { return entry }

        return ScanHistoryEntry(
            id: entry.id,
            date: entry.date,
            scanSeconds: entry.scanSeconds,
            score: recalculatedScore,
            diskUsedBytes: entry.diskUsedBytes,
            diskFreeBytes: entry.diskFreeBytes,
            greenBytes: entry.greenBytes,
            yellowBytes: entry.yellowBytes,
            redBytes: entry.redBytes,
            itemCount: entry.itemCount,
            greenCount: entry.greenCount,
            yellowCount: entry.yellowCount,
            redCount: entry.redCount,
            deniedCount: entry.deniedCount,
            scanMode: entry.scanMode,
            permissionPenalty: entry.permissionPenalty,
            scoreModelVersion: entry.scoreModelVersion,
            actionableGreenBytes: entry.actionableGreenBytes,
            actionableGreenCount: entry.actionableGreenCount,
            scanWasLimited: entry.scanWasLimited
        )
    }
}
