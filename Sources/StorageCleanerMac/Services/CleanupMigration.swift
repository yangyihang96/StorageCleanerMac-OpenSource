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
        guard let data = defaults.data(forKey: defaultsKey),
              data.count <= maximumEncodedBytes,
              let reports = try? JSONDecoder().decode([CleanReport].self, from: data) else {
            return []
        }
        return Array(
            reports
                .sorted { $0.completedAt > $1.completedAt }
                .prefix(maximumReportCount)
        )
    }

    static func removingRestoredReceipts(
        from report: CleanReport,
        originalPaths: Set<String>
    ) -> CleanReport {
        guard !originalPaths.isEmpty else { return report }
        let remainingItems = report.items.filter { item in
            guard case let .moved(receipt) = item.outcome else { return true }
            return !originalPaths.contains(PathSafety.lexicalPath(receipt.originalPath))
        }
        guard remainingItems.count != report.items.count else { return report }
        return CleanReport(
            id: report.id,
            planID: report.planID,
            sessionID: report.sessionID,
            rulesVersion: report.rulesVersion,
            disposition: report.disposition,
            scanWasPartial: report.scanWasPartial,
            startedAt: report.startedAt,
            completedAt: report.completedAt,
            outcome: report.outcome,
            items: remainingItems,
            summary: report.summary
        )
    }
}
