import Foundation
import XCTest
@testable import StorageCleanerMac

enum MyActivityD187Fixtures {
    static let now = ComputerHealthSecurityFixture.date

    /// These views never perform file operations. Retain the factory's
    /// ownership and refusal checks with an owned, uncreated operation root;
    /// only the normal data/defaults fixtures are created in the temp folder.
    @MainActor
    static func readOnlyStore(for testCase: XCTestCase) throws -> ScanStore {
        let root = TestFileSystem.uniqueOperationRoot("activity-readonly")
        TestFileSystem.registerOwnership(of: root, for: testCase)
        return try ScanStore.makeForTests(for: testCase, cleanupUserHomeURL: root.appendingPathComponent("home"))
    }

    /// As in D185's cloud fixtures, use a worktree scratch path: Foundation
    /// can canonicalize a temp URL back through /var, which the provider
    /// scanner correctly refuses. Keep its ancestor checks unchanged.
    static func cloudHome(for testCase: XCTestCase) throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent(".build/d187-fixtures")
            .appendingPathComponent(TestFileSystem.uniqueRoot("activity-cloud").lastPathComponent)
        testCase.addTeardownBlock { TestFileSystem.remove(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func health(base: ComputerHealthSnapshot = ComputerHealthSecurityFixture.snapshot(),
                       disk: DiskHealthSnapshot? = nil, capacity: CapacityTrendSnapshot? = nil,
                       backup: TimeMachineSnapshot? = nil, stability: StabilitySummary? = nil,
                       battery: BatteryHealthEvidence? = nil, security: SystemProtectionSnapshot? = nil) -> ComputerHealthSnapshot {
        ComputerHealthSnapshot(generatedAt: base.generatedAt, disk: disk ?? base.disk,
            capacity: capacity ?? base.capacity, backup: backup ?? base.backup,
            stability: stability ?? base.stability, batteryEvidence: battery ?? base.batteryEvidence,
            security: security ?? base.security)
    }

    static func stability(crashes: Int = 0, hangs: Int = 0, panics: Int = 0, restarts: Int = 0) -> StabilitySummary {
        StabilitySummary(availability: .available, status: .healthy, crashCount: crashes, hangCount: hangs,
                         panicCount: panics, unexpectedRestartCount: restarts, filesExamined: 20,
                         windowStart: now.addingTimeInterval(-7 * 86_400), generatedAt: now)
    }

    static func battery(condition: BatteryCondition = .normal, status: HealthStatus = .healthy) -> BatteryHealthEvidence {
        .present(BatteryHealthSnapshot(availability: .available, status: status,
            currentChargePercent: 70, isCharging: false, maximumCapacityPercent: 85, cycleCount: 100,
            condition: condition, batteryPowerMode: .automatic, adapterPowerMode: .automatic,
            guidance: BatteryGuidance(kind: .none), sampledAt: now))
    }

    static func application(_ id: String = "fixture.app") -> InstalledApplication {
        AppUpdateTestFixtures.application(id: id, availableVersion: "2.0", provider: .sparkle, status: .updateAvailable,
            sourceEvidence: ["sparkle-framework", "sparkle-feed"])
    }

    static func movedItem(_ path: String = "/Fixture/Example.app", bytes: Int64 = 1_000_000) -> CleanReportItem {
        CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "fixture", sourcePath: path,
            estimatedBytes: bytes, outcome: .moved(CleanupMoveReceipt(originalPath: path,
                resultingItemURL: URL(fileURLWithPath: "/Fixture/.Trash/" + URL(fileURLWithPath: path).lastPathComponent),
                disposition: .trash, movedIdentity: FileIdentity(deviceID: 1, inode: 2, entryKind: .directory,
                                                                creationTimeNanoseconds: 3),
                verification: .identityVerified, movedAt: now)))
    }

    static func report(rules: String = "cleanup.v2", items: [CleanReportItem] = [movedItem("/Fixture/cache")],
                       outcome: CleanReportOutcome = .completed) -> CleanReport {
        let moved = items.filter { if case .moved = $0.outcome { return true }; return false }
        let bytes = moved.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        return CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(), rulesVersion: rules,
            disposition: .trash, scanWasPartial: false, startedAt: now, completedAt: now,
            outcome: outcome, items: items,
            summary: CleanReportSummary(requestedItemCount: items.count, movedItemCount: moved.count,
                skippedItemCount: 0, failedItemCount: 0, notProcessedItemCount: 0, unverifiedMoveCount: 0,
                plannedBytes: bytes, movedToRecoverableLocationBytes: bytes,
                reclaimableAfterEmptyingTrashBytes: bytes, permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil))
    }

    static func noRecommendations() -> MyActivityRecommendations.State {
        var value = MyActivityRecommendations.State()
        // D195＋旧值：this fixture's successful login read was implicit.
        value.managedItemCoverageAvailable = true
        value.health = MyActivityHealth.evaluate(ComputerHealthSecurityFixture.snapshot(), now: now)
        value.latestSmartScanAt = now
        value.hasProtectionScan = true
        return value
    }
}
