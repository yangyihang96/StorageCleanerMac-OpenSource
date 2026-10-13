#if DEBUG
import Foundation
import XCTest
@testable import StorageCleanerMac

/// BOARD N20 (live 2026-10-06/07): in the product the Smart Scan runs
/// `startCleanupV2Scan`, which never wrote the scan history; only the old
/// full-disk scan did (`ScanHistoryService.record(scanResult)`). The
/// settings' "扫描提醒" and the menu bar's "可安全清理" summary therefore
/// stayed "等待首次扫描" after real scans. A completed Smart Scan now writes
/// an equivalent entry, counted the way the results page counts (D19, D23).
@MainActor
final class SmartScanHistoryTests: XCTestCase {
    // Each test takes its own suite from `ScanHistoryTestDefaults` (removed
    // at teardown). Review P2-3: stored suite properties set in the
    // nonisolated setUp/tearDown of this main-actor class were Swift 6
    // isolation warnings.

    func testACompletedSmartScanWritesTheEntryTheResultsPageCounts() async throws {
        let defaults = ScanHistoryTestDefaults.make(for: self)
        let session = session(outcome: .complete)
        let store = try await scannedStore(returning: session, defaults: defaults)

        let entry = try XCTUnwrap(store.scanHistorySummary.latest, "the Smart Scan is recorded")
        let totals = CleanupScanTierTotals(categories: session.categories)
        XCTAssertEqual(entry.greenBytes, totals.safeBytes)
        XCTAssertEqual(entry.greenCount, totals.safe.count)
        XCTAssertEqual(entry.yellowBytes, totals.reviewBytes)
        XCTAssertEqual(entry.yellowCount, totals.review.count)
        XCTAssertEqual(entry.redBytes, totals.protectedBytes)
        XCTAssertEqual(entry.redCount, totals.protected.count)
        XCTAssertEqual(entry.itemCount, totals.safe.count + totals.review.count + totals.protected.count)
        XCTAssertEqual(entry.actionableGreenBytes, totals.safeBytes)
        XCTAssertEqual(entry.actionableGreenCount, totals.safe.count)
        XCTAssertEqual(entry.date, session.completedAt)
        XCTAssertEqual(entry.diskUsedBytes, 600_000_000_000)
        XCTAssertEqual(entry.diskFreeBytes, 400_000_000_000)
        XCTAssertEqual(entry.deniedCount, 0)
        XCTAssertEqual(entry.scanWasLimited, false)
        XCTAssertEqual(entry.scoreModelVersion, ScanHistoryService.currentScoreModelVersion)
        // The fixture's tiers, as the page shows them.
        XCTAssertEqual(entry.greenBytes, 2_164_000_000)
        XCTAssertEqual(entry.greenCount, 2)

        XCTAssertNotNil(store.scanHistorySummary.latestStatus(), "the reminders and summaries have a last scan")
        XCTAssertEqual(ScanHistoryService.summary(defaults: defaults).latest, entry, "it is persisted")
        XCTAssertEqual(store.scanHistorySummary.latestStatus()?.attentionLevel, .current)
    }

    func testAPartialScanAsksForARescanAndDeniedFoldersAskForAccess() async throws {
        let partial = try await scannedStore(returning: session(outcome: .partial),
                                             defaults: ScanHistoryTestDefaults.make(for: self))
        XCTAssertEqual(partial.scanHistorySummary.latest?.scanWasLimited, true)
        XCTAssertEqual(partial.scanHistorySummary.latestStatus()?.attentionLevel, .rescanRecommended)

        let denied = try await scannedStore(returning: session(outcome: .complete, deniedRule: true),
                                            defaults: ScanHistoryTestDefaults.make(for: self))
        XCTAssertEqual(denied.scanHistorySummary.latest?.deniedCount, 1)
        XCTAssertEqual(denied.scanHistorySummary.latestStatus()?.attentionLevel, .permissionLimited)
    }

    func testACancelledOrNarrowedScanIsNotRecorded() async throws {
        let defaults = ScanHistoryTestDefaults.make(for: self)
        let cancelled = try await scannedStore(returning: session(outcome: .cancelled), defaults: defaults)
        XCTAssertNil(cancelled.scanHistorySummary.latest, "a cancelled scan says nothing about the disk")

        let developer = try await scannedStore(returning: session(outcome: .complete), route: .devCaches,
                                               defaults: defaults)
        XCTAssertNil(developer.scanHistorySummary.latest,
                     "a Developer Files scan covers one category; its totals are not the Smart Scan's")
        let safeCleanup = try await scannedStore(returning: session(outcome: .complete), route: .green,
                                                 defaults: defaults)
        XCTAssertNil(safeCleanup.scanHistorySummary.latest, "neither are a Safe Cleanup scan's")
        XCTAssertTrue(ScanHistoryService.load(defaults: defaults).isEmpty)
    }

    /// r2-live-fixes-2 review P2-1: a completed Smart Scan under test records
    /// into the test's own suite; the test process's standard defaults keep
    /// their scan history (every store fixture that can complete a scan
    /// checks this at teardown through `ScanHistoryTestDefaults`).
    func testACompletedSmartScanLeavesTheStandardDefaultsAlone() async throws {
        let defaults = ScanHistoryTestDefaults.make(for: self)
        let standardBefore = ScanHistoryTestDefaults.standardHistory()
        let store = try await scannedStore(returning: session(outcome: .complete), defaults: defaults)

        XCTAssertNotNil(store.scanHistorySummary.latest, "the scan is recorded")
        XCTAssertFalse(ScanHistoryService.load(defaults: defaults).isEmpty, "in the test's suite")
        XCTAssertEqual(ScanHistoryTestDefaults.standardHistory(), standardBefore,
                       "UserDefaults.standard keeps its scan history")
    }

    /// The results page and the history count with the same definition.
    func testTheResultsPageCountsWithTheSharedTotals() throws {
        let view = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        XCTAssertTrue(view.contains("CleanupScanTierTotals(categories: categories)"))
        let history = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/ScanHistoryService.swift")
        XCTAssertTrue(history.contains("CleanupScanTierTotals(categories: session.categories)"))
    }

    // MARK: - Support

    private struct EmptyHistoryLoader: ScanStoreHistoryLoading {
        func load() async -> ScanStoreHistorySnapshot {
            ScanStoreHistorySnapshot(scanHistory: ScanHistorySummary(entries: []),
                                     cleanupHistory: CleanupHistorySummary(entries: []))
        }
    }

    private struct LegacyScanUnused: Error {}

    private func scannedStore(
        returning session: ScanSession,
        route: ReviewFilter = .overview,
        defaults: UserDefaults
    ) async throws -> ScanStore {
        let store = try ScanStore.makeForTests(for: self,
            scanHeavyWorkOperations: TestOperationFactory(for: self).scanOperations(scan: { _, _ in throw LegacyScanUnused() }),
            historyLoader: EmptyHistoryLoader(),
            scanHistoryDefaults: defaults,
            cleanupFeatureConfiguration: .productDefault,
            cleanupScanOperation: { _, _ in session },
            cleanReportLoader: { [] },
            interruptedOperationReconciler: { [] }
        )
        store.selectedFilter = route
        store.startScan()
        let deadline = Date().addingTimeInterval(10)
        while store.isScanning || store.cleanupScanSession == nil {
            guard Date() < deadline else {
                XCTFail("the scan did not finish")
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(20))
        return store
    }

    /// The fixture's items, scanned now (an old scan asks for a rescan).
    private func session(outcome: ScanOutcome, deniedRule: Bool = false) -> ScanSession {
        let fixture = DebugSmartScanSessionFixture.session
        let now = Date()
        return ScanSession(
            id: ScanSessionID(rawValue: UUID()),
            rulesVersion: fixture.rulesVersion,
            startedAt: now.addingTimeInterval(-0.84),
            completedAt: now,
            outcome: outcome,
            categories: fixture.categories,
            issues: [],
            permissions: deniedRule
                ? [CleanupPermissionReport(ruleID: "trash.user-trash", path: "/DebugFixture/.Trash", status: .permissionDenied)]
                : fixture.permissions,
            metrics: fixture.metrics,
            system: SystemSnapshot(
                osName: "macOS", build: "test", arch: "arm64", user: "tester", home: "/DebugFixture",
                filesystem: "APFS", purgeable: "", diskName: "Fixture",
                diskTotalBytes: 1_000_000_000_000, diskUsedBytes: 600_000_000_000, diskFreeBytes: 400_000_000_000
            )
        )
    }
}
#endif
