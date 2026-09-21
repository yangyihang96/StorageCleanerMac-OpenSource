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

    @discardableResult
    static func record(
        _ report: CleanReport,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if defaults === UserDefaults.standard {
            do { try CleanupReportJournal.live.checkpoint(report, expectedIdentities: [:]) }
            catch { return false }
        }
        var reports = load(defaults: defaults)
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

    static func load(defaults: UserDefaults = .standard) -> [CleanReport] {
        let cached: [CleanReport]
        if let data = defaults.data(forKey: defaultsKey), data.count <= maximumEncodedBytes,
           let decoded = try? JSONDecoder().decode([CleanReport].self, from: data) {
            cached = decoded
        } else { cached = [] }
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
