import Foundation

struct CleanupMigrationResult: Equatable, Sendable {
    let fromVersion: Int
    let toVersion: Int
    let migratedExclusionCount: Int
    let rejectedExclusionCount: Int
    let didComplete: Bool
}

enum CleanupMigration {
    static let currentVersion = 1
    static let versionKey = "cleanup.migration.version"
    static let excludedPathsKey = "cleanup.v2.excludedPaths.v1"

    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        activeRules: CleanupRuleSet,
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CleanupMigrationResult {
        let fromVersion = defaults.integer(forKey: versionKey)
        guard fromVersion < currentVersion else {
            return CleanupMigrationResult(
                fromVersion: fromVersion,
                toVersion: currentVersion,
                migratedExclusionCount: defaults.stringArray(forKey: excludedPathsKey)?.count ?? 0,
                rejectedExclusionCount: 0,
                didComplete: true
            )
        }
        guard (try? CleanupRuleValidator.validate(activeRules)) != nil else {
            return CleanupMigrationResult(
                fromVersion: fromVersion,
                toVersion: currentVersion,
                migratedExclusionCount: 0,
                rejectedExclusionCount: 0,
                didComplete: false
            )
        }

        let homePath = PathSafety.lexicalPath(userHomeURL.path)
        let legacyPaths = defaults.stringArray(forKey: ScanExclusionService.defaultsKey) ?? []
        let existingV2Paths = defaults.stringArray(forKey: excludedPathsKey) ?? []
        var migrated = Set<String>()
        var rejected = 0
        for rawPath in existingV2Paths + legacyPaths {
            let path = PathSafety.lexicalPath(rawPath)
            guard rawPath.hasPrefix("/"),
                  path != homePath,
                  PathSafety.isContained(path, in: homePath, resolvingSymlinks: false) else {
                rejected += 1
                continue
            }
            migrated.insert(path)
        }

        let sorted = migrated.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        defaults.set(sorted, forKey: excludedPathsKey)
        guard defaults.stringArray(forKey: excludedPathsKey) == sorted else {
            return CleanupMigrationResult(
                fromVersion: fromVersion,
                toVersion: currentVersion,
                migratedExclusionCount: sorted.count,
                rejectedExclusionCount: rejected,
                didComplete: false
            )
        }
        defaults.set(currentVersion, forKey: versionKey)
        return CleanupMigrationResult(
            fromVersion: fromVersion,
            toVersion: currentVersion,
            migratedExclusionCount: sorted.count,
            rejectedExclusionCount: rejected,
            didComplete: defaults.integer(forKey: versionKey) == currentVersion
        )
    }

    static func v2ExcludedURLs(
        defaults: UserDefaults = .standard,
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let homePath = PathSafety.lexicalPath(userHomeURL.path)
        let rawPaths = (defaults.stringArray(forKey: excludedPathsKey) ?? [])
            + (defaults.stringArray(forKey: ScanExclusionService.defaultsKey) ?? [])
        let paths = rawPaths.compactMap { rawPath -> String? in
            let path = PathSafety.lexicalPath(rawPath)
            guard rawPath.hasPrefix("/"),
                  path != homePath,
                  PathSafety.isContained(path, in: homePath, resolvingSymlinks: false) else {
                return nil
            }
            return path
        }
        return Set(paths).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map {
            URL(fileURLWithPath: $0)
        }
    }
}

enum CleanReportStore {
    static let defaultsKey = "cleanup.v2.reports.v1"
    private static let maximumReportCount = 40
    private static let maximumEncodedBytes = 4 * 1_024 * 1_024

    /// Store callers run on the main actor. There the journal lock is only
    /// tried, never awaited, so a lock held by a worker read as a failed save,
    /// and the fsync blocked the UI. Off the main thread the lock is awaited.
    static func recordDetached(_ report: CleanReport, journal: CleanupReportJournal = .live) async -> Bool {
        await Task.detached(priority: .utility) { record(report, journal: journal) }.value
    }

    @discardableResult
    static func record(
        _ report: CleanReport,
        defaults: UserDefaults = .standard,
        journal: CleanupReportJournal = .live
    ) -> Bool {
        if defaults === UserDefaults.standard {
            do { try journal.checkpoint(report, expectedIdentities: [:]) }
            catch { return false }
            // The legacy cache only mirrors the live journal for old listings;
            // an injected (isolated) journal never feeds it.
            guard journal.directory == CleanupReportJournal.live.directory else { return true }
        }
        // P2-2: an older app version decodes this cache as a whole, fails on
        // outcomes it does not know and then overwrites it, losing every
        // older receipt. Receipts with a permanent deletion stay in the
        // journal only; they are saved when the journal took them.
        guard report.isReadableByOlderVersions else {
            return defaults === UserDefaults.standard
        }
        // The durable journal is authoritative. Updating this bounded legacy
        // cache must not decode every historical operation on each new receipt.
        var reports = cachedReports(defaults: defaults)
        reports.removeAll { $0.id == report.id || $0.planID == report.planID }
        reports.insert(report, at: 0)
        reports = Array(reports.prefix(maximumReportCount))

        let encoder = JSONEncoder()
        while !reports.isEmpty {
            guard let data = try? encoder.encode(reports) else { return false }
            if data.count <= maximumEncodedBytes {
                defaults.set(data, forKey: defaultsKey)
                return defaults.data(forKey: defaultsKey) == data
            }
            reports.removeLast()
        }
        return false
    }

    private static func cachedReports(defaults: UserDefaults = .standard) -> [CleanReport] {
        if let data = defaults.data(forKey: defaultsKey), data.count <= maximumEncodedBytes,
           let decoded = try? JSONDecoder().decode([CleanReport].self, from: data) {
            return decoded
        }
        return []
    }

    static func summaryPage(after cursor: CleanupReportIndex.Cursor? = nil, limit: Int = 40,
                            journal: CleanupReportJournal = .live) throws -> CleanupReportJournal.SummaryPage {
        let page = try journal.summaryPage(after: cursor, limit: limit)
        let legacy = (journal.directory == CleanupReportJournal.live.directory ? cachedReports() : []).filter {
            !FileManager.default.fileExists(atPath: journal.reportURL(for: $0.planID).path)
        }.map { CleanupReportIndex(report: $0, orderingDate: $0.completedAt) }.filter { $0.follows(cursor) }
        var byPlan = Dictionary(legacy.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in page.reports { byPlan[item.id] = item }
        let merged = byPlan.values.sorted(by: CleanupReportIndex.newestFirst)
        let selected = Array(merged.prefix(limit))
        return .init(reports: selected,
            next: merged.count > limit ? selected.last?.cursor : page.next,
            unreadableEntries: page.unreadableEntries)
    }

    static func report(planID: CleanPlanID, journal: CleanupReportJournal = .live) throws -> CleanReport {
        if FileManager.default.fileExists(atPath: journal.reportURL(for: planID).path) {
            return try journal.read(planID: planID)
        }
        guard journal.directory == CleanupReportJournal.live.directory,
              let report = cachedReports().first(where: { $0.planID == planID }) else {
            throw CleanupReportJournal.Failure.invalidEntry
        }
        return report
    }

    static func load(defaults: UserDefaults = .standard) -> [CleanReport] {
        let cached = cachedReports(defaults: defaults)
        guard defaults === UserDefaults.standard else {
            return Array(cached.sorted { $0.completedAt > $1.completedAt }.prefix(maximumReportCount))
        }
        let durable = (try? CleanupReportJournal.live.load()) ?? []
        var byPlan = Dictionary(cached.map { ($0.planID, $0) }, uniquingKeysWith: { a, b in
            a.completedAt > b.completedAt ? a : b
        })
        // Disk evidence is authoritative, including restore updates.
        for report in durable { byPlan[report.planID] = report }
        return byPlan.values.sorted { $0.completedAt > $1.completedAt }
    }

    static func removingRestoredReceipts(
        from report: CleanReport,
        originalPaths: Set<String>
    ) -> CleanReport {
        guard !originalPaths.isEmpty else { return report }
        let restored = report.restorableReceipts.filter {
            originalPaths.contains(PathSafety.lexicalPath($0.originalPath))
        }.map { CleanupRecoveryItem(id: UUID(), originalPath: $0.originalPath, outcome: .restored) }
        guard !restored.isEmpty else { return report }
        var updated = report
        updated.recoveryAttempts = (report.recoveryAttempts ?? []) + [
            CleanupRecoveryReport(completedAt: Date(), items: restored, attemptID: UUID())
        ]
        return updated
    }
}

extension CleanReport {
    /// P2-2: whether an app version before permanent deletion (D23) can
    /// decode this receipt. It cannot read a deleted outcome or the
    /// deletion-outcome-unknown failure.
    var isReadableByOlderVersions: Bool {
        !items.contains { item in
            switch item.outcome {
            case .deleted:
                true
            case let .failed(failure):
                failure.code == .deletionOutcomeUnknown
            case .moved, .skipped, .notProcessed:
                false
            }
        }
    }
}
