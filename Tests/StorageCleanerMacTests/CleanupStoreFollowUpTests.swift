import Foundation
import XCTest
@testable import StorageCleanerMac

/// A2: the cleanup flow in ScanStore after a cleanup and around running
/// owner apps. Files live in a temporary fixture home, receipts go to an
/// isolated journal, and no real app is asked to quit: the running apps,
/// the quit service and the cleanup's running check are fakes.
@MainActor
final class CleanupStoreFollowUpTests: XCTestCase {
    /// Rows moved to Trash leave the results; a row skipped because its app
    /// is running stays listed.
    func testCleanedRowsLeaveTheResultsAndSkippedRowsStay() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"]
        )
        let store = try await fixture.scannedStore(for: self)
        let idle = try fixture.candidate("com.example.idle", in: store)
        let busy = try fixture.candidate("com.example.busy", in: store)
        store.setCleanupCandidates([idle.id, busy.id], selected: true)

        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        XCTAssertEqual(store.pendingCleanPreflight?.readyCount, 1)
        store.confirmV2Cleanup()
        try await waitUntil { store.lastCleanReport != nil && store.pendingCleanPlan == nil }

        XCTAssertEqual(
            store.cleanupScanSession?.candidates.map(\.sourceURL.lastPathComponent),
            ["com.example.busy"]
        )
        XCTAssertEqual(store.cleanupScanSession?.metrics.candidateCount, 1)
        XCTAssertTrue(store.cleanupSelection.selectedCandidateIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL("com.example.idle").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cacheURL("com.example.busy").path))
    }

    /// Live test 2026-10-06 (r2-live-fixes-1, item 1): "完成" on the cleanup
    /// result page returns to the refreshed results while rows remain. The
    /// cleaned row is gone, the skipped row stays, nothing is selected, the
    /// counts follow, and the remaining row can be cleaned from there without
    /// scanning again.
    func testDoneAfterACleanupReturnsToTheRemainingResults() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"]
        )
        let store = try await fixture.scannedStore(for: self)
        let scanSessionID = try XCTUnwrap(store.cleanupScanSession?.id)
        let presentationID = try XCTUnwrap(store.scanPresentationSessionID)
        let idle = try fixture.candidate("com.example.idle", in: store)
        let busy = try fixture.candidate("com.example.busy", in: store)
        store.setCleanupCandidates([idle.id, busy.id], selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        store.confirmV2Cleanup()
        try await waitUntil { store.scanPresentationState == .completed }
        XCTAssertNotNil(store.lastCleanReport)

        store.dismissV2CleanupReport()

        XCTAssertEqual(store.scanPresentationState, .results)
        XCTAssertEqual(store.scanPresentationSessionID, presentationID)
        XCTAssertEqual(store.cleanupWorkflowState, .results(sessionID: scanSessionID))
        XCTAssertNil(store.lastCleanReport)
        XCTAssertNil(store.cleanupRecoveryReport)
        XCTAssertEqual(store.cleanupScanSession?.id, scanSessionID, "The same scan, not a new one")
        XCTAssertEqual(
            store.cleanupScanSession?.candidates.map(\.sourceURL.lastPathComponent),
            ["com.example.busy"]
        )
        XCTAssertEqual(store.cleanupScanSession?.metrics.candidateCount, 1)
        XCTAssertTrue(store.cleanupSelection.selectedCandidateIDs.isEmpty)

        // The row left behind can be cleaned from the same results.
        fixture.apps.quitByItself("com.example.busy")
        store.setCleanupCandidate(busy.id, selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil(timeout: 5) { store.isV2CleanupConfirmationPresented }
        XCTAssertEqual(store.pendingCleanPreflight?.readyCount, 1)
    }

    /// Only when nothing is left to list does "完成" go back to the start page.
    func testDoneAfterCleaningEverythingReturnsToTheStartPage() async throws {
        let fixture = try makeFixture(caches: ["com.example.idle"])
        let store = try await fixture.scannedStore(for: self)
        let idle = try fixture.candidate("com.example.idle", in: store)
        store.setCleanupCandidates([idle.id], selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        store.confirmV2Cleanup()
        try await waitUntil { store.scanPresentationState == .completed }
        XCTAssertEqual(store.cleanupScanSession?.candidates.count, 0)

        store.dismissV2CleanupReport()

        XCTAssertEqual(store.scanPresentationState, .idle)
        XCTAssertNil(store.scanPresentationSessionID)
        XCTAssertEqual(store.cleanupWorkflowState, .idle)
        XCTAssertNil(store.lastCleanReport)
    }

    /// The Safe Cleanup and Developer Files pages show the same result page
    /// and share "完成". Before the fix they listed the remaining rows again,
    /// but the scan's presentation token was gone, so "清理" on those rows
    /// silently did nothing until a new scan.
    func testDoneOnTheSafeCleanupPageKeepsTheRemainingRowsCleanable() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"]
        )
        let store = try await fixture.scannedStore(for: self, route: .green)
        XCTAssertNotNil(store.cleanupScanSession?.includedRuleIDs, "A Safe Cleanup scan")
        let idle = try fixture.candidate("com.example.idle", in: store)
        let busy = try fixture.candidate("com.example.busy", in: store)
        store.setCleanupCandidates([idle.id], selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        store.confirmV2Cleanup()
        try await waitUntil { store.scanPresentationState == .completed }

        store.dismissV2CleanupReport()

        XCTAssertEqual(store.scanPresentationState, .results)
        XCTAssertNotNil(store.scanPresentationSessionID)
        fixture.apps.quitByItself("com.example.busy")
        store.setCleanupCandidate(busy.id, selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil(timeout: 5) { store.isV2CleanupConfirmationPresented }
        store.confirmV2Cleanup()
        try await waitUntil { store.scanPresentationState == .completed }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL("com.example.busy").path))
    }

    /// "重新扫描" is a separate action on the cleanup result page: it scans
    /// the same scope again on that scope's page, even when another page was
    /// selected while the result was showing.
    func testScanAgainFromTheCleanupResultScansTheSameScope() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"]
        )
        let store = try await fixture.scannedStore(for: self, laterScans: 1, route: .green)
        let firstSessionID = try XCTUnwrap(store.cleanupScanSession?.id)
        let idle = try fixture.candidate("com.example.idle", in: store)
        store.setCleanupCandidates([idle.id], selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        store.confirmV2Cleanup()
        try await waitUntil { store.scanPresentationState == .completed }
        store.selectedFilter = .privacy

        store.rescanAfterV2Cleanup()

        try await waitUntil {
            store.scanPresentationState == .results && store.cleanupScanSession?.id != firstSessionID
        }
        XCTAssertEqual(store.selectedFilter, .green)
        XCTAssertNil(store.lastCleanReport)
        XCTAssertEqual(fixture.scanRequests.all.count, 2)
        XCTAssertEqual(
            fixture.scanRequests.all.last?.includedRuleIDs,
            fixture.scanRequests.all.first?.includedRuleIDs,
            "The second scan covers the same Safe Cleanup rules"
        )
        XCTAssertNotNil(fixture.scanRequests.all.last?.includedRuleIDs)
    }

    func testTheCleanupResultPageOffersScanAgainBesideDone() throws {
        let page = try source("Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift")
        XCTAssertTrue(page.contains("store.rescanAfterV2Cleanup()"))
        XCTAssertTrue(page.contains("(onDone ?? store.dismissV2CleanupReport)()"))
        XCTAssertEqual(ScanStore.scanRoute(of: try sessionStub()), .overview)
        XCTAssertEqual(ScanStore.scanRoute(of: try sessionStub(categories: ["developer"])), .devCaches)
        XCTAssertEqual(
            ScanStore.scanRoute(of: try sessionStub(categories: ["system"], rules: ["system.user-caches"])),
            .green
        )
    }

    // MARK: Review follow-up (r2-live-fixes-1, P2-1 and P2-2)

    /// P2-1: "重新扫描" on the result page when the rules cannot be loaded.
    /// Before, the old result came back over the failure, "完成" then opened
    /// the results under the failed scan's token without a rule set, and
    /// "清理" there did nothing.
    func testScanAgainThatCannotLoadTheRulesDoesNotBringTheOldResultBack() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"]
        )
        let store = try await fixture.scannedStore(for: self)
        try await cleanUp(["com.example.idle"], in: store, fixture: fixture)
        fixture.ruleLoader.failNextLoad()

        store.rescanAfterV2Cleanup()

        XCTAssertEqual(store.scanPresentationState, .failed)
        XCTAssertNil(store.lastCleanReport, "The failure shows, not the earlier cleanup result")
        XCTAssertFalse(store.canRequestV2Cleanup)
        store.dismissV2CleanupReport()
        XCTAssertEqual(store.scanPresentationState, .idle)
        XCTAssertFalse(store.canRequestV2Cleanup)
    }

    /// P2-1: ⌘R on a file page while the result page shows starts the old
    /// full-disk scan with a new token (here it fails, and that scan does not
    /// clear the cleanup receipt). "完成" on the receipt that shows again must
    /// not open the results under the other scan's token.
    func testDoneAfterAnotherScanStartedDoesNotReturnToTheResults() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"]
        )
        let store = try await fixture.scannedStore(for: self)
        try await cleanUp(["com.example.idle"], in: store, fixture: fixture)
        let cleanupToken = store.scanPresentationSessionID

        store.selectedFilter = .largeFiles
        store.startScan()
        try await waitUntil { store.scanPresentationState == .failed }

        XCTAssertNotEqual(store.scanPresentationSessionID, cleanupToken)
        XCTAssertNotNil(store.lastCleanReport)
        store.dismissV2CleanupReport()
        XCTAssertEqual(store.scanPresentationState, .idle)
        XCTAssertFalse(store.canRequestV2Cleanup)
    }

    /// The explicit main-scan API owns a new presentation even when a file
    /// route is selected. This is distinct from the page's Cmd-R command.
    func testExplicitMainScanFromFileRoutesReplacesTheTokenButRetainsTheReceipt() async throws {
        for route in [ReviewFilter.largeFiles, .migration, .duplicates] {
            let fixture = try makeFixture(
                caches: ["com.example.idle", "com.example.busy"],
                running: ["com.example.busy"])
            let store = try await fixture.scannedStore(for: self)
            try await cleanUp(["com.example.idle"], in: store, fixture: fixture)
            let receipt = try XCTUnwrap(store.lastCleanReport)
            let cleanupToken = try XCTUnwrap(store.scanPresentationSessionID)
            let history = store.scanHistorySummary

            store.selectedFilter = route
            store.startScan()

            // Assert the synchronous handoff before waiting: a dispatcher
            // regression must fail here, not just time out ten seconds later.
            XCTAssertTrue(store.isScanning, "Explicit main scan: \(route)")
            XCTAssertEqual(store.scanPresentationState, .preparing)
            XCTAssertNotEqual(store.scanPresentationSessionID, cleanupToken)
            XCTAssertEqual(store.scanPresentationRoute, route)
            XCTAssertNil(store.cleanupScanSession)
            XCTAssertTrue(store.cleanupSelection.selectedCandidateIDs.isEmpty)
            XCTAssertNil(store.cleanupDryRunSummary)
            XCTAssertNil(store.pendingCleanPlan)
            XCTAssertNil(store.pendingCleanPreflight)
            XCTAssertEqual(store.cleanupWorkflowState, .idle)
            XCTAssertEqual(store.lastCleanReport?.id, receipt.id)
            XCTAssertFalse(store.largeFilesWorkspace.isScanning)
            XCTAssertFalse(store.largeFilesWorkspace.isAnalyzingStorage)
            XCTAssertFalse(store.duplicateFilesWorkspace.isScanning)

            try await waitUntil { !store.isPreparingScan }
            XCTAssertEqual(fixture.scanCalls.all, ["main"])
            XCTAssertEqual(fixture.scanRequests.all.count, 1, "No second cleanup-rules scan")
            XCTAssertEqual(store.scanPresentationState, .failed)
            XCTAssertEqual(store.scanHistorySummary, history, "A failed new scan adds no history")
            XCTAssertEqual(store.lastCleanReport?.id, receipt.id)

            store.dismissV2CleanupReport()
            XCTAssertEqual(store.scanPresentationState, .idle)
            XCTAssertNil(store.scanPresentationSessionID)
            XCTAssertNil(store.lastCleanReport)
            XCTAssertEqual(store.cleanupWorkflowState, .idle)
            XCTAssertFalse(store.canRequestV2Cleanup)
        }
    }

    /// Cmd-R belongs to the current file feature, even after cleanup. A
    /// failed file refresh must not invalidate that cleanup's receipt/token.
    func testFilePageRefreshAfterCleanupKeepsTheReceiptBoundToItsOriginalResults() async throws {
        for route in [ReviewFilter.largeFiles, .migration, .duplicates] {
            let fixture = try makeFixture(
                caches: ["com.example.idle", "com.example.busy"],
                running: ["com.example.busy"])
            let store = try await fixture.scannedStore(for: self)
            try await cleanUp(["com.example.idle"], in: store, fixture: fixture)
            let receipt = try XCTUnwrap(store.lastCleanReport)
            let session = try XCTUnwrap(store.cleanupScanSession)
            let cleanupToken = try XCTUnwrap(store.scanPresentationSessionID)
            let history = store.scanHistorySummary

            store.selectedFilter = route
            store.startScanRespectingAccessGuide()

            XCTAssertFalse(store.isScanning)
            XCTAssertEqual(store.scanPresentationSessionID, cleanupToken)
            XCTAssertEqual(store.scanPresentationState, .completed)
            try await waitUntil { !store.isPreparingScan }
            let expectedCall = route == .largeFiles ? "analysis" : route == .migration ? "migration" : "duplicates"
            XCTAssertEqual(fixture.scanCalls.all, [expectedCall])
            XCTAssertEqual(fixture.scanRequests.all.count, 1)
            XCTAssertEqual(store.lastCleanReport?.id, receipt.id)
            XCTAssertEqual(store.cleanupScanSession?.id, session.id)
            XCTAssertEqual(store.cleanupWorkflowState, .completed(reportID: receipt.id))
            XCTAssertEqual(store.scanPresentationSessionID, cleanupToken)
            XCTAssertEqual(store.scanPresentationState, .completed)
            XCTAssertEqual(store.scanHistorySummary, history)

            store.dismissV2CleanupReport()
            XCTAssertEqual(store.scanPresentationState, .results)
            XCTAssertEqual(store.scanPresentationSessionID, cleanupToken)
            XCTAssertEqual(store.cleanupScanSession?.id, session.id)
            XCTAssertEqual(store.cleanupWorkflowState, .results(sessionID: session.id))
            XCTAssertTrue(store.cleanupSelection.selectedCandidateIDs.isEmpty)
            XCTAssertNil(store.lastCleanReport)
            XCTAssertTrue(store.canRequestV2Cleanup)
            XCTAssertEqual(store.selectedFilter, route)
        }
    }

    /// P2-2: a receipt written by another feature does not reopen the scan's
    /// results. Uninstall writes `lastCleanReport` in the product's cleanup
    /// mode, so it is run here for real against an isolated fixture app.
    func testAnUninstallReceiptDoesNotReopenTheResults() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"]
        )
        let uninstall = try UninstallFixture(home: fixture.home)
        addTeardownBlock { uninstall.remove() }
        let store = try await fixture.scannedStore(for: self, uninstall: uninstall)
        try await cleanUp(["com.example.idle"], in: store, fixture: fixture)
        let cleanupReportID = try XCTUnwrap(store.lastCleanReport?.id)

        store.installedApps = [uninstall.app]
        store.requestUninstall(uninstall.app)
        try await waitUntil { !store.isPreparingUninstall && store.pendingUninstallApp != nil }
        store.confirmUninstall(selectedPaths: [])
        try await waitUntil(timeout: 15) { !store.isUninstallingApp && store.uninstallResult != nil }
        let uninstallReport = try XCTUnwrap(store.lastCleanReport)
        XCTAssertNotEqual(uninstallReport.id, cleanupReportID, "The uninstall wrote its own receipt")
        XCTAssertEqual(uninstallReport.summary.movedItemCount, 1)

        store.dismissV2CleanupReport()

        XCTAssertEqual(store.scanPresentationState, .idle)
        XCTAssertFalse(store.canRequestV2Cleanup)
    }

    /// P2-2: the old move-to-Trash actions also write `lastCleanReport`, but
    /// they are offered only in the legacy cleanup mode. Beside the product's
    /// Smart Scan cleanup they cannot run, so their receipt cannot reach the
    /// result page either.
    func testTheOldMoveToTrashCannotRunBesideTheSmartScanCleanup() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"]
        )
        let store = try await fixture.scannedStore(for: self)
        try await cleanUp(["com.example.idle"], in: store, fixture: fixture)
        let cleanupReportID = store.lastCleanReport?.id
        let path = fixture.cacheURL("com.example.busy").path
        let item = StorageItem(
            id: "legacy-green", title: "Legacy", path: path, groupTitle: "Caches", sizeBytes: 8_192,
            tier: .green, kind: "cache", reason: "", recommendation: "", risk: "", requiresClose: "",
            trashPaths: [path], openPath: path, status: .available
        )
        store.result = ScanResult(
            generatedAt: Date(), scanSeconds: 1,
            system: SystemSnapshot(
                osName: "macOS", build: "Test", arch: "arm64", user: "fixture", home: fixture.home.path,
                filesystem: "apfs", purgeable: "", diskName: "Fixture", diskTotalBytes: 1_000,
                diskUsedBytes: 500, diskFreeBytes: 500
            ),
            groups: [], items: [item], deniedPaths: []
        )
        XCTAssertTrue(item.canMoveToTrash)

        XCTAssertFalse(store.canRequestTrash(item))
        XCTAssertFalse(store.canRequestGreenTrash)
        store.requestTrashAllGreen()
        XCTAssertTrue(store.pendingBulkTrashItems.isEmpty)
        XCTAssertEqual(store.lastCleanReport?.id, cleanupReportID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// P2-2: a cleanup stopped part way ("已取消"): "完成" returns to the rows
    /// that were not processed; a moved row is gone.
    func testDoneAfterAStoppedCleanupReturnsToTheUnprocessedRows() async throws {
        let fixture = try makeFixture(caches: ["com.example.one", "com.example.two"])
        let mover = GatedTrashMover(trashURL: fixture.home.appendingPathComponent(".Trash"))
        let store = try await fixture.scannedStore(for: self, mover: mover)
        addTeardownBlock { @MainActor [weak store] in
            mover.open()
            await store?.waitForOperationReportTasksForTesting(cancelPending: true)
        }
        let rows = try ["com.example.one", "com.example.two"].map { try fixture.candidate($0, in: store).id }
        store.setCleanupCandidates(rows, selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        store.confirmV2Cleanup()
        try await waitUntil { mover.hasEntered }

        store.cancelV2CleanupExecution()
        mover.open()
        try await waitUntil { store.scanPresentationState == .cancelled }

        let report = try XCTUnwrap(store.lastCleanReport)
        XCTAssertEqual(report.outcome, .cancelled)
        let notProcessed = Set(report.items.compactMap { item -> String? in
            guard case .notProcessed = item.outcome else { return nil }
            return URL(fileURLWithPath: item.sourcePath).lastPathComponent
        })
        let moved = Set(report.items.compactMap { item -> String? in
            guard case .moved = item.outcome else { return nil }
            return URL(fileURLWithPath: item.sourcePath).lastPathComponent
        })
        XCTAssertFalse(notProcessed.isEmpty)

        store.dismissV2CleanupReport()

        XCTAssertEqual(store.scanPresentationState, .results)
        let listed = Set(store.cleanupScanSession?.candidates.map(\.sourceURL.lastPathComponent) ?? [])
        XCTAssertTrue(notProcessed.isSubset(of: listed), "\(notProcessed) not in \(listed)")
        XCTAssertTrue(moved.isDisjoint(with: listed))
        XCTAssertTrue(store.cleanupSelection.selectedCandidateIDs.isEmpty)
        XCTAssertTrue(store.canRequestV2Cleanup)
    }

    /// P2-2: a cleanup in which every move failed ("失败"): "完成" returns to
    /// the same rows, which can be tried again.
    func testDoneAfterAFailedCleanupReturnsToTheFailedRows() async throws {
        let fixture = try makeFixture(caches: ["com.example.one", "com.example.two"])
        let store = try await fixture.scannedStore(for: self, mover: FailingTrashMover())
        let rows = try ["com.example.one", "com.example.two"].map { try fixture.candidate($0, in: store).id }
        store.setCleanupCandidates(rows, selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        store.confirmV2Cleanup()
        try await waitUntil { store.scanPresentationState == .failed }
        XCTAssertEqual(store.lastCleanReport?.outcome, .failed)

        store.dismissV2CleanupReport()

        XCTAssertEqual(store.scanPresentationState, .results)
        XCTAssertEqual(
            Set(store.cleanupScanSession?.candidates.map(\.sourceURL.lastPathComponent) ?? []),
            ["com.example.one", "com.example.two"]
        )
        XCTAssertTrue(store.canRequestV2Cleanup)
    }

    /// P2-2: the Developer Files page shares the result page and "完成";
    /// the rows left there can be cleaned right away, without a new scan.
    func testDoneOnTheDeveloperFilesPageKeepsTheRemainingRowsCleanable() async throws {
        let fixture = try makeFixture(caches: [], developerFolders: ["Library/Caches/Homebrew", ".cache/uv"])
        let store = try await fixture.scannedStore(for: self, route: .devCaches)
        XCTAssertEqual(store.cleanupScanSession?.includedCategoryIDs, ["developer"])
        XCTAssertEqual(
            Set(store.cleanupScanSession?.candidates.map(\.sourceURL.lastPathComponent) ?? []),
            ["Homebrew", "uv"]
        )
        try await cleanUp(["Homebrew"], in: store, fixture: fixture, acknowledgingRisks: true)

        store.dismissV2CleanupReport()

        XCTAssertEqual(store.scanPresentationState, .results)
        XCTAssertEqual(store.selectedFilter, .devCaches)
        XCTAssertEqual(store.cleanupScanSession?.candidates.map(\.sourceURL.lastPathComponent), ["uv"])
        try await cleanUp(["uv"], in: store, fixture: fixture, acknowledgingRisks: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".cache/uv").path))
        XCTAssertEqual(fixture.scanRequests.all.count, 1, "No second scan")
    }

    /// Selects the named rows (on top of the default selection), confirms
    /// and waits for the result page.
    private func cleanUp(
        _ names: [String],
        in store: ScanStore,
        fixture: Fixture,
        acknowledgingRisks: Bool = false
    ) async throws {
        let ids = try names.map { try fixture.candidate($0, in: store).id }
        store.setCleanupCandidates(ids, selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil(timeout: 5) { store.isV2CleanupConfirmationPresented }
        store.confirmV2Cleanup(
            reviewRiskAcknowledged: acknowledgingRisks,
            protectedRiskAcknowledged: acknowledgingRisks,
            protectedTrashMoveAcknowledged: acknowledgingRisks
        )
        try await waitUntil { store.scanPresentationState == .completed }
    }

    private func sessionStub(categories: Set<String>? = nil, rules: Set<String>? = nil) throws -> ScanSession {
        ScanSession(
            id: ScanSessionID(), rulesVersion: "test", startedAt: Date(), completedAt: Date(),
            outcome: .complete, categories: [], issues: [], permissions: [],
            metrics: ScanMetrics(
                visitedEntryCount: 0, candidateCount: 0, deduplicatedIdentityCount: 0,
                estimatedCandidateBytes: 0, duration: 0
            ),
            includedCategoryIDs: categories, includedRuleIDs: rules
        )
    }

    /// Emptying the Trash has its own confirmation, separate from the red
    /// confirmations for items that move to Trash. The old empty-Trash entry
    /// point stays disabled.
    func testEmptyingTheTrashNeedsItsOwnConfirmation() async throws {
        let fixture = try makeFixture(caches: ["com.example.idle"], trash: ["old.bin"])
        let store = try await fixture.scannedStore(for: self)
        XCTAssertFalse(store.canRequestEmptyTrash)
        let trash = try XCTUnwrap(store.cleanupScanSession?.candidates.first { $0.action == .emptyTrash })
        let idle = try fixture.candidate("com.example.idle", in: store)
        store.setCleanupCandidates([trash.id, idle.id], selected: true)

        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        store.confirmV2Cleanup(protectedRiskAcknowledged: true, protectedTrashMoveAcknowledged: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(store.pendingCleanPlan, "The red confirmations alone do not empty the Trash")
        XCTAssertNil(store.lastCleanReport)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.trashURL("old.bin").path))

        store.confirmV2Cleanup(permanentDeletionAcknowledged: true)
        try await waitUntil { store.lastCleanReport != nil && store.pendingCleanPlan == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.trashURL("old.bin").path))
        XCTAssertEqual(store.lastCleanReport?.summary.deletedItemCount, 1)
        XCTAssertEqual(store.lastCleanReport?.summary.movedItemCount, 1)
    }

    /// When an owner app quits after the scan, refreshing the running state
    /// updates the row; the user's selection is left alone.
    func testRunningStateRefreshesWithoutChangingTheSelection() async throws {
        let fixture = try makeFixture(caches: ["com.example.busy"], running: ["com.example.busy"])
        let store = try await fixture.scannedStore(for: self)
        XCTAssertEqual(try fixture.candidate("com.example.busy", in: store).isOwnerRunning, true)
        let selectionBefore = store.cleanupSelection

        fixture.apps.quitByItself("com.example.busy")
        await store.refreshCleanupOwnerRunningState()

        XCTAssertEqual(try fixture.candidate("com.example.busy", in: store).isOwnerRunning, false)
        XCTAssertEqual(store.cleanupSelection.selectedCandidateIDs, selectionBefore.selectedCandidateIDs)
        XCTAssertEqual(
            store.cleanupSelection.explicitlySelectedCandidateIDs,
            selectionBefore.explicitlySelectedCandidateIDs
        )
    }

    /// "正常退出并清理" on a running row: the app names are listed first, the
    /// apps are asked to quit normally, then the cleanup is checked again.
    func testQuittingOwnersFromARunningRowThenCleans() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"]
        )
        let store = try await fixture.scannedStore(for: self)
        let idle = try fixture.candidate("com.example.idle", in: store)
        let busy = try fixture.candidate("com.example.busy", in: store)
        store.setCleanupCandidates([idle.id, busy.id], selected: true)

        store.requestQuitCleanupOwners(for: [busy.id])
        XCTAssertEqual(store.cleanupOwnerQuitRequest?.owners.map(\.displayName), ["Busy App"])
        XCTAssertEqual(fixture.apps.quitRequests(), [], "Nothing quits before the user confirms")

        store.quitOwnersAndRecheckCleanup()
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        XCTAssertEqual(fixture.apps.quitRequests(), ["com.example.busy"])
        XCTAssertEqual(store.pendingCleanPreflight?.readyCount, 2)
        XCTAssertNil(store.cleanupOwnerQuitRequest)
    }

    /// When nothing passes the check, the confirmation still opens with each
    /// item's reason and cannot be confirmed. Quitting the running owner from
    /// there checks the same plan again.
    func testNothingReadyShowsReasonsAndQuittingRechecksThePlan() async throws {
        let fixture = try makeFixture(caches: ["com.example.busy"], running: ["com.example.busy"])
        let store = try await fixture.scannedStore(for: self)
        let busy = try fixture.candidate("com.example.busy", in: store)
        store.setCleanupCandidate(busy.id, selected: true)

        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.pendingCleanPreflight != nil || store.pendingCleanPlan == nil }
        try await waitUntil { store.isV2CleanupConfirmationPresented }
        let plan = try XCTUnwrap(store.pendingCleanPlan)
        XCTAssertEqual(store.pendingCleanPreflight?.isConfirmable, false)
        XCTAssertEqual(store.pendingCleanPreflight?.items.map(\.status), [.skipped(.relatedAppStillRunning)])
        store.confirmV2Cleanup()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.lastCleanReport)
        XCTAssertEqual(store.pendingCleanPlan?.id, plan.id)

        store.requestQuitCleanupOwnersForPendingPlan()
        XCTAssertEqual(store.cleanupOwnerQuitRequest?.owners.map(\.displayName), ["Busy App"])
        store.quitOwnersAndRecheckCleanup()
        try await waitUntil { store.pendingCleanPreflight?.isConfirmable == true }
        XCTAssertEqual(store.pendingCleanPlan?.id, plan.id, "The same frozen plan is checked again")
        XCTAssertEqual(fixture.apps.quitRequests(), ["com.example.busy"])

        store.confirmV2Cleanup()
        try await waitUntil { store.lastCleanReport != nil && store.pendingCleanPlan == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL("com.example.busy").path))
    }

    /// P1-1 (round 3): the binding ContentView presents the sheet with opens
    /// it when nothing passed, listing reasons; closing it returns to results
    /// that can be edited and cleaned again.
    func testSheetBindingOpensWhenNothingPassesAndClosingUnlocksTheResults() async throws {
        let fixture = try makeFixture(caches: ["com.example.busy"], running: ["com.example.busy"])
        let store = try await fixture.scannedStore(for: self)
        try await waitUntil { store.scanPresentationState == .results }
        let busy = try fixture.candidate("com.example.busy", in: store)
        store.setCleanupCandidate(busy.id, selected: true)
        let binding = CleanupPlanConfirmationPresentation.binding(for: store)
        XCTAssertFalse(binding.wrappedValue)

        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.pendingCleanPreflight != nil || store.pendingCleanPlan == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.pendingCleanPreflight?.isConfirmable, false)
        XCTAssertTrue(binding.wrappedValue, "The sheet opens although nothing passed the check")
        XCTAssertEqual(binding.wrappedValue, store.isV2CleanupConfirmationPresented)

        binding.wrappedValue = false
        XCTAssertFalse(binding.wrappedValue)
        XCTAssertNil(store.pendingCleanPlan)
        XCTAssertTrue(store.canEditV2CleanupSelection, "Closing the sheet unlocks the selection")
        XCTAssertTrue(store.canRequestV2Cleanup)
        try await waitUntil { store.scanPresentationState == .results }
    }

    /// P2-1 (round 3): an owner that runs but cannot be asked to quit (a
    /// menu-bar or background app, Finder) is named for a manual quit; the
    /// store never claims it already quit.
    func testOwnersThatCannotBeAskedToQuitAreNamedForAManualQuit() async throws {
        let fixture = try makeFixture(
            caches: ["com.example.agent", "com.apple.finder"],
            running: ["com.example.agent", "com.apple.finder"],
            agents: ["com.example.agent"]
        )
        let store = try await fixture.scannedStore(for: self)
        for (name, displayName) in [("com.example.agent", "Agent"), ("com.apple.finder", "Finder")] {
            let row = try fixture.candidate(name, in: store)
            XCTAssertTrue(row.isOwnerRunning)
            store.setCleanupCandidates([row.id], selected: true)
            store.requestQuitCleanupOwners(for: [row.id])
            XCTAssertNil(store.cleanupOwnerQuitRequest, "\(name) cannot be asked to quit")
            let message = (store.actionMessage ?? "") + (store.errorMessage ?? "")
            XCTAssertTrue(message.contains("需手动退出") || message.contains("Quit manually"), "\(name): \(message)")
            XCTAssertTrue(message.contains(displayName), "\(name): \(message)")
            XCTAssertFalse(message.contains("已经退出") || message.contains("already quit"), "\(name): \(message)")
            store.setCleanupCandidates([row.id], selected: false)
        }
        XCTAssertEqual(fixture.apps.quitRequests(), [])

        // From the sheet as well.
        let agent = try fixture.candidate("com.example.agent", in: store)
        store.setCleanupCandidates([agent.id], selected: true)
        store.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store.pendingCleanPreflight != nil || store.pendingCleanPlan == nil }
        store.requestQuitCleanupOwnersForPendingPlan()
        XCTAssertNil(store.cleanupOwnerQuitRequest)
        let sheetMessage = (store.actionMessage ?? "") + (store.errorMessage ?? "")
        XCTAssertTrue(sheetMessage.contains("Agent"), sheetMessage)
        XCTAssertFalse(sheetMessage.contains("已经退出") || sheetMessage.contains("already quit"), sheetMessage)
        XCTAssertEqual(store.pendingCleanPreflight?.items.map(\.status), [.skipped(.relatedAppStillRunning)])
    }

    /// P2-2 (round 3): when one identifier runs as several instances, the
    /// confirmation names every instance that will be asked to quit.
    func testTheConfirmationNamesEveryInstanceThatWillBeAskedToQuit() async {
        let instances = InstanceApplications(instances: [
            ("com.example.dup", "Dup"),
            ("com.example.dup", "Dup Nightly"),
        ])
        let service = instances.quitService()
        let owners = service.options(among: ["com.example.dup"]).quittable
        let message = CleanupOwnerQuitPresentation.message(for: CleanupOwnerQuitRequest(
            source: .confirmation,
            owners: owners
        ))
        _ = await service.quitNormally(owners)

        XCTAssertTrue(message.contains("Dup Nightly"), message)
        XCTAssertEqual(Set(instances.asked()), ["Dup", "Dup Nightly"])
        XCTAssertEqual(owners.count, instances.asked().count, "Listed instances are the ones asked")
        let twice = CleanupOwnerQuitPresentation.names([
            .init(bundleIdentifier: "com.example.same", displayName: "Same"),
            .init(bundleIdentifier: "com.example.same", displayName: "Same"),
        ])
        XCTAssertTrue(twice.contains("2"), twice)
    }

    /// P2-6 (round 3): the quit and the wait reuse the existing
    /// `requestNormalTermination`, which checks a clock deadline (not a
    /// count of polls) and is capped at 5 seconds, so a slow machine cannot
    /// stretch it past 10 seconds. The red version of this test showed the
    /// old own loop running three times past its timeout with slow pauses.
    func testTheQuitWaitUsesTheReusedDeadlineBasedImplementation() async throws {
        let apps = FakeApplications(
            installed: ["com.example.stubborn"],
            running: ["com.example.stubborn"],
            names: ["com.example.stubborn": "Stubborn"],
            stubborn: ["com.example.stubborn"]
        )
        let service = apps.quitService(ownBundleIdentifier: nil)
        let stillRunning = await service.quitNormally(service.options(among: ["com.example.stubborn"]).quittable)

        XCTAssertEqual(stillRunning, ["com.example.stubborn"])
        XCTAssertEqual(apps.requestedTimeouts(), [CleanupOwnerQuitService.waitSeconds])
        XCTAssertLessThanOrEqual(CleanupOwnerQuitService.waitSeconds, 10)
        let reused = try source("Sources/StorageCleanerMac/Features/BrowserPrivacy/Processing/BrowserPrivacyHistoryProcessor.swift")
        XCTAssertTrue(reused.contains("let timeout = min(max(timeoutSeconds, 0), 5)"))
        XCTAssertTrue(reused.contains("let deadline = Date().addingTimeInterval(timeout)"))
        XCTAssertTrue(reused.contains("while Date() < deadline"))
        let workspace = BrowserPrivacyWorkspaceRunningApplicationChecker()
        let started = ContinuousClock.now
        let none = await workspace.requestNormalTermination(
            bundleIdentifiers: ["com.example.storagecleaner.not-installed-\(UUID().uuidString)"],
            timeoutSeconds: CleanupOwnerQuitService.waitSeconds
        )
        XCTAssertEqual(none, [])
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    /// P2-3 (round 3): if the scan changed while apps were quitting, the
    /// results are only refreshed; no cleanup check starts on its own.
    func testANewScanWhileAppsQuitStopsTheAutomaticFollowUp() async throws {
        // The app takes its time (it stays open), so the new scan finishes
        // while the store waits for it.
        let fixture = try makeFixture(
            caches: ["com.example.idle", "com.example.busy"],
            running: ["com.example.busy"],
            stubborn: ["com.example.busy"]
        )
        fixture.apps.quitWait = .milliseconds(300)
        let store = try await fixture.scannedStore(for: self, laterScans: 1)
        try await waitUntil { store.scanPresentationState == .results }
        let firstSession = try XCTUnwrap(store.cleanupScanSession?.id)
        let busy = try fixture.candidate("com.example.busy", in: store)
        store.setCleanupCandidate(busy.id, selected: true)
        store.requestQuitCleanupOwners(for: [busy.id])
        XCTAssertNotNil(store.cleanupOwnerQuitRequest)
        fixture.apps.onQuitRequest = { store.startScan() }

        store.quitOwnersAndRecheckCleanup()
        try await waitUntil { !store.isQuittingCleanupOwners && !store.isScanning }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNotEqual(store.cleanupScanSession?.id, firstSession)
        XCTAssertNil(store.pendingCleanPlan, "No cleanup check starts for the new scan")
        XCTAssertNil(store.pendingCleanPreflight)
    }

    /// The quit service only asks regular apps to quit normally, never this
    /// app or Finder, and reports the ones still running after the timeout.
    func testQuitServiceAsksNormallyAndReportsAppsThatStayOpen() async {
        let apps = FakeApplications(
            installed: ["com.example.a", "com.example.stubborn", "com.apple.finder", "com.example.agent", "com.local.self"],
            running: ["com.example.a", "com.example.stubborn", "com.apple.finder", "com.example.agent", "com.local.self"],
            names: ["com.example.a": "A", "com.example.stubborn": "Stubborn"],
            stubborn: ["com.example.stubborn"],
            agents: ["com.example.agent"]
        )
        let service = apps.quitService(ownBundleIdentifier: "com.local.self")
        let all: Set<String> = ["com.example.a", "com.example.stubborn", "com.apple.finder", "com.example.agent", "com.local.self"]

        let options = service.options(among: all)
        XCTAssertEqual(options.quittable.map(\.displayName), ["A", "Stubborn"])
        XCTAssertEqual(
            Set(options.manual.map(\.bundleIdentifier)),
            ["com.apple.finder", "com.example.agent", "com.local.self"]
        )
        let stillRunning = await service.quitNormally(options.quittable)

        XCTAssertEqual(stillRunning, ["com.example.stubborn"])
        XCTAssertEqual(Set(apps.quitRequests()), ["com.example.a", "com.example.stubborn"])
        XCTAssertTrue(apps.isRunning("com.apple.finder"))
        XCTAssertTrue(apps.isRunning("com.local.self"))
        XCTAssertTrue(apps.isRunning("com.example.agent"))
    }

    /// The real workspace path maps running apps without asking any to quit
    /// when no listed identifier is running (read only).
    func testWorkspaceQuitServiceQuitsNothingForIdentifiersThatAreNotRunning() async {
        let service = CleanupOwnerQuitService()
        let unknown: Set<String> = ["com.example.storagecleaner.not-installed-\(UUID().uuidString)"]
        XCTAssertTrue(service.options(among: unknown).isEmpty)
        let stillRunning = await service.quitNormally([])
        XCTAssertEqual(stillRunning, [])
        if let own = Bundle.main.bundleIdentifier {
            XCTAssertEqual(service.options(among: [own]).quittable, [], "This process is never offered")
        }
    }

    /// The views wire the A2 flow: the results page refreshes running owners
    /// and offers "正常退出并清理" on running rows; the sheet passes the
    /// empty-Trash confirmation on its own and lists skipped items.
    func testViewsWireTheFollowUpFlow() throws {
        let results = try source("Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        XCTAssertTrue(results.contains("await store.refreshCleanupOwnerRunningState()"))
        XCTAssertTrue(results.contains("NSWorkspace.didTerminateApplicationNotification"))
        XCTAssertTrue(results.contains("store.requestQuitCleanupOwners(for: [candidate.id], cleanupScope: cleanupScopeIDs)"))
        XCTAssertTrue(results.contains("store.quitOwnersAndRecheckCleanup()"))
        // The plan sheet is presented with the shared, tested binding.
        let content = try source("Sources/StorageCleanerMac/Views/ContentView.swift")
        XCTAssertTrue(content.contains(".sheet(isPresented: v2CleanupConfirmationBinding)"))
        XCTAssertTrue(content.contains("CleanupPlanConfirmationPresentation.binding(for: store)"))
        XCTAssertFalse(content.contains("pendingCleanPreflight?.isConfirmable"))
        let confirmation = try source("Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift")
        XCTAssertTrue(confirmation.contains("permanentDeletionAcknowledged: permanentDeletionAcknowledged"))
        XCTAssertTrue(confirmation.contains("skippedItemsSection"))
        XCTAssertTrue(confirmation.contains("store.requestQuitCleanupOwnersForPendingPlan()"))
        XCTAssertTrue(confirmation.contains("CleanSkipReasonPresentation.title(entry.reason)"))
        let service = try source("Sources/StorageCleanerMac/Services/CleanupOwnerQuitService.swift")
        XCTAssertFalse(service.contains("forceTerminate"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testFactoryTeardownWaitsWhenTestExitsDuringCleanupExecution() async throws {
        let fixture = try makeFixture(caches: ["com.example.one", "com.example.two"])
        let mover = InFlightCleanupMover(trashURL: fixture.home.appendingPathComponent(".Trash"))
        let observation = CleanupExitObservation()
        let fixtureOwner = ObjectIdentifier(self)
        addTeardownBlock { @MainActor in
            let inFlightAfterFactory = mover.inFlight
            let startedAfterFactory = mover.started
            let completedAfterFactory = mover.completed
            let cancellationObservedAfterFactory = mover.wasCancelled
            let sourceExistedAtCancellationAfterFactory = mover.sourceExistedAtCancellation
            // Safety net for a deliberately broken factory: wait on handles, not
            // on a weak store, before the earlier fixture-removal teardown runs.
            mover.open()
            let pending = await TestOperationReportJoin.wait(
                observation.tasks, cancelPending: true,
                deadline: ContinuousClock().now.advanced(by: .seconds(10)))
            if !pending.isEmpty {
                TestFileSystem.preventCleanup(ownedBy: fixtureOwner, unfinishedTasks: pending)
                XCTFail("回归探针自身收尾超时：\(pending)")
            }
            XCTAssertFalse(inFlightAfterFactory, "工厂收尾返回时清理移动必须已结束")
            XCTAssertEqual(startedAfterFactory, 1, "工厂取消后不能继续移动第二项")
            XCTAssertEqual(completedAfterFactory, 1, "工厂必须实际等待第一项移动结束")
            XCTAssertTrue(cancellationObservedAfterFactory, "工厂必须先取消正在进行的任务，再等待它结束")
            XCTAssertTrue(sourceExistedAtCancellationAfterFactory, "取消事件发生时源文件必须尚未移动或被夹具收尾删除")
        }
        var store: ScanStore? = try await fixture.scannedStore(for: self, mover: mover)
        addTeardownBlock { mover.open() }
        let ids = try ["com.example.one", "com.example.two"].map { try fixture.candidate($0, in: store!).id }
        store!.setCleanupCandidates(ids, selected: true)
        store!.requestV2Cleanup(disposition: .trash)
        try await waitUntil { store!.isV2CleanupConfirmationPresented }
        store!.confirmV2Cleanup()
        observation.tasks = store!.operationReportProducersForTesting
        try await waitUntil { mover.hasEntered }
        mover.open()
        XCTAssertEqual(mover.releasedWaiterCount, 0, "只开门闸不能放行；必须等到工厂取消任务")
        // A test failure/throw exits with no local owner. Only factory teardown
        // may keep the store alive and cancel/join the weak-self producer.
        store = nil
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let home: URL
        let journalRoot: URL
        let apps: FakeApplications
        let rules: CleanupRuleSet
        /// Where the store records completed scans: a suite private to the
        /// test, never UserDefaults.standard (r2-live-fixes-2 review P2-1).
        let scanHistoryDefaults: UserDefaults
        /// Every request the store sent to the scan operation, in order.
        let scanRequests = ScanRequestLog()
        /// Main and feature-owned reads are all fake and distinguishable.
        let scanCalls = FixtureScanCallLog()
        /// Lets a test make the next rule load fail, as a damaged rule file would.
        let ruleLoader = FixtureRuleLoader()

        func cacheURL(_ name: String) -> URL {
            home.appendingPathComponent("Library/Caches/\(name)")
        }

        func trashURL(_ name: String) -> URL {
            home.appendingPathComponent(".Trash/\(name)")
        }

        @MainActor
        /// Scans now; `laterScans` more sessions (new identifiers) are kept
        /// for later "scan again" calls. `route` is the page the scan starts
        /// from: Smart Scan by default, `.green` for a Safe Cleanup scan
        /// limited to the rules of its default scopes, `.devCaches` for
        /// Developer Files. `mover` replaces the fixture Trash mover;
        /// `uninstall` gives the store an isolated Trash and uninstall mover.
        /// The old full-disk scan is always a fake that fails.
        func scannedStore(
            for testCase: XCTestCase,
            laterScans: Int = 0,
            route: ReviewFilter = .overview,
            mover: (any CleanupMoving)? = nil,
            uninstall: UninstallFixture? = nil
        ) async throws -> ScanStore {
            let fileSystem = FoundationReadOnlyFileSystem()
            let safeCleanupRules = rules.rules.filter { rule in
                SafeCleanupScanScope.allCases.contains { $0.includes(rule) }
            }
            let request = switch route {
            case .green:
                CleanupScanRequest(
                    userHomeURL: home,
                    includedCategoryIDs: Set(safeCleanupRules.map(\.categoryID)),
                    includedRuleIDs: Set(safeCleanupRules.map(\.id))
                )
            case .devCaches:
                CleanupScanRequest(userHomeURL: home, includedCategoryIDs: ["developer"])
            default:
                CleanupScanRequest(userHomeURL: home)
            }
            var sessions = [ScanSession]()
            for _ in 0...laterScans {
                sessions.append(try await ReadOnlyCleanupScanner(
                    fileSystem: fileSystem,
                    ruleSet: rules,
                    applicationsURL: root.appendingPathComponent("Applications"),
                    applicationEnvironment: FakeApplicationEnvironment(apps: apps)
                ).scan(request: request) { _ in })
            }
            let queue = SessionQueue(sessions: sessions)
            let rules = self.rules
            let scanRequests = self.scanRequests
            let scanCalls = self.scanCalls
            let ruleLoader = self.ruleLoader
            let store = try ScanStore.makeForTests(for: testCase,
                scanHeavyWorkOperations: TestOperationFactory(for: testCase).scanOperations(scan: { _, _ in
                    scanCalls.append("main")
                    throw FixtureLegacyScanFailure()
                }),
                largeFilesScanOperation: { _ in
                    scanCalls.append("migration")
                    throw FixtureFileScanFailure()
                },
                largeFilesStorageMapTargets: [StorageMapScanTarget(path: home.path, title: "Fixture", kind: .homeDirectory)],
                largeFilesStorageAnalysisOperation: { _, _ in
                    scanCalls.append("analysis")
                    throw FixtureFileScanFailure()
                },
                duplicateFilesScanOperation: { _, _, _, _, _ in
                    scanCalls.append("duplicates")
                    throw FixtureFileScanFailure()
                },
                scanHistoryDefaults: scanHistoryDefaults,
                cleanupFeatureConfiguration: .productDefault,
                cleanupScanOperation: { request, _ in
                    scanRequests.append(request)
                    return queue.next()
                },
                cleanupRuleSetLoader: { try ruleLoader.load(rules) },
                cleanupExecutor: SafeCleanupExecutor(
                    metadataReader: fileSystem,
                    mover: mover ?? FixtureTrashMover(trashURL: home.appendingPathComponent(".Trash")),
                    runningApplicationChecker: FakeRunningChecker(apps: apps),
                    deleter: FixtureTrashDeleter(trashURL: home.appendingPathComponent(".Trash")),
                    coordinator: HeavyWorkCoordinator()
                ),
                cleanupUserHomeURL: home,
                cleanupApplicationEnvironment: FakeApplicationEnvironment(apps: apps),
                cleanupOwnerQuitService: apps.quitService(ownBundleIdentifier: nil),
                cleanupRecoveryService: CleanupRecoveryService(),
                cleanReportLoader: { [] },
                interruptedOperationReconciler: { [] },
                operationJournal: CleanupReportJournal(directory: journalRoot),
                operationTrashURL: uninstall?.trash ?? home.appendingPathComponent(".Trash"),
                uninstallMoves: uninstall?.moves
            )
            store.selectedFilter = route
            store.startScan()
            let deadline = Date().addingTimeInterval(10)
            while store.isScanning || store.cleanupScanSession == nil {
                guard Date() < deadline else { throw FixtureTimeout() }
                try await Task.sleep(for: .milliseconds(5))
            }
            return store
        }

        @MainActor
        func candidate(_ name: String, in store: ScanStore) throws -> ScanCandidate {
            guard let candidate = store.cleanupScanSession?.candidates.first(where: {
                $0.sourceURL.lastPathComponent == name
            }) else { throw FixtureMissing(name: name) }
            return candidate
        }
    }

    private struct FixtureTimeout: Error {}
    private struct FixtureMissing: Error { let name: String }

    /// `developerFolders` (home-relative) are filled for the Homebrew and uv
    /// developer cache rules, which are then added to the rule set.
    private func makeFixture(
        caches: [String],
        trash: [String] = [],
        running: Set<String> = [],
        agents: Set<String> = [],
        stubborn: Set<String> = [],
        developerFolders: [String] = []
    ) throws -> Fixture {
        let root = TestFileSystem.uniqueOperationRoot("store-follow-up")
        TestFileSystem.registerCleanup(of: root, for: self)
        let home = root.appendingPathComponent("home")
        let journalRoot = root.appendingPathComponent("Journal", isDirectory: true)
        for name in caches {
            try write(bytes: 8_192, to: home.appendingPathComponent("Library/Caches/\(name)/cache.bin"))
        }
        for name in trash {
            try write(bytes: 8_192, to: home.appendingPathComponent(".Trash/\(name)"))
        }
        for folder in developerFolders {
            try write(bytes: 8_192, to: home.appendingPathComponent(folder).appendingPathComponent("cache.bin"))
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Applications"),
            withIntermediateDirectories: true
        )
        let bundled = try CleanupRuleSetLoader.loadBundled()
        let rules = CleanupRuleSet(
            schemaVersion: bundled.schemaVersion,
            rulesVersion: bundled.rulesVersion,
            rules: bundled.rules
                .filter { rule in
                    ["system.user-caches", "trash.user-trash"].contains(rule.id)
                        || (!developerFolders.isEmpty
                            && ["developer.homebrew-cache", "developer.uv-cache"].contains(rule.id))
                }
                .map { $0.id == "trash.user-trash" ? $0 : withoutSizeThreshold($0) }
        )
        let apps = FakeApplications(
            installed: Set(caches),
            running: running,
            names: [
                "com.example.busy": "Busy App",
                "com.example.idle": "Idle App",
                "com.example.agent": "Agent",
                "com.apple.finder": "Finder",
            ],
            stubborn: stubborn,
            agents: agents
        )
        return Fixture(
            root: root, home: home, journalRoot: journalRoot, apps: apps, rules: rules,
            scanHistoryDefaults: ScanHistoryTestDefaults.make(for: self)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw FixtureTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func write(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private func withoutSizeThreshold(_ rule: CleanupRule) -> CleanupRule {
        CleanupRule(
            id: rule.id,
            selectionPolicyVersion: rule.selectionPolicyVersion,
            categoryID: rule.categoryID,
            categoryTitleKey: rule.categoryTitleKey,
            titleKey: rule.titleKey,
            root: rule.root,
            candidateScope: rule.candidateScope,
            maximumDepth: rule.maximumDepth,
            minimumAgeDays: rule.minimumAgeDays,
            minimumBytes: 0,
            include: rule.include,
            exclude: rule.exclude,
            cloudPolicy: rule.cloudPolicy,
            risk: rule.risk,
            recommendation: rule.recommendation,
            defaultSelection: rule.defaultSelection,
            executionEligibility: rule.executionEligibility,
            measurementRequirement: rule.measurementRequirement,
            allowsManualSelection: rule.allowsManualSelection,
            action: rule.action,
            requiredClosedBundleIDs: rule.requiredClosedBundleIDs,
            reasonKey: rule.reasonKey,
            ownerDisplayName: rule.ownerDisplayName,
            developerTool: rule.developerTool,
            developerArtifactKind: rule.developerArtifactKind,
            includedBundleIdentifiers: rule.includedBundleIdentifiers,
            requiresDuplicateBundleIdentifier: rule.requiresDuplicateBundleIdentifier,
            ownerInference: rule.ownerInference
        )
    }
}

/// Running and installed apps shared by the fakes. Nothing here touches a
/// real process.
private final class FakeApplications: @unchecked Sendable {
    private let lock = NSLock()
    private let installed: Set<String>
    private var running: Set<String>
    private let names: [String: String]
    private let stubborn: Set<String>
    private let agents: Set<String>
    private var requests = [String]()
    private var timeouts = [TimeInterval]()
    /// Runs when apps are asked to quit (on the main actor).
    @MainActor var onQuitRequest: (() -> Void)?
    /// How long a quit request takes before it reports what still runs.
    var quitWait: Duration = .zero

    init(
        installed: Set<String>,
        running: Set<String>,
        names: [String: String] = [:],
        stubborn: Set<String> = [],
        agents: Set<String> = []
    ) {
        self.installed = installed
        self.running = running
        self.names = names
        self.stubborn = stubborn
        self.agents = agents
    }

    func isRunning(_ identifier: String) -> Bool { lock.withLock { running.contains(identifier) } }
    func runningIdentifiers() -> Set<String> { lock.withLock { running } }
    func installedIdentifiers() -> Set<String> { installed }
    func quitRequests() -> [String] { lock.withLock { requests } }
    func requestedTimeouts() -> [TimeInterval] { lock.withLock { timeouts } }

    func quitByItself(_ identifier: String) {
        _ = lock.withLock { running.remove(identifier) }
    }

    private func requestQuit(_ identifier: String) -> Bool {
        lock.withLock {
            requests.append(identifier)
            if !stubborn.contains(identifier) { running.remove(identifier) }
        }
        return true
    }

    @MainActor
    func quitService(ownBundleIdentifier: String?) -> CleanupOwnerQuitService {
        CleanupOwnerQuitService(
            runningApplications: { [self] in
                runningIdentifiers().sorted().map { identifier in
                    CleanupOwnerQuitService.RunningApplication(
                        bundleIdentifier: identifier,
                        localizedName: names[identifier],
                        isRegularApplication: !agents.contains(identifier)
                    )
                }
            },
            terminator: self,
            ownBundleIdentifier: ownBundleIdentifier
        )
    }
}

/// The reused normal-quit request, faked: it records which apps were asked
/// and what timeout was requested; stubborn apps keep running.
extension FakeApplications: BrowserPrivacyRunningApplicationChecking {
    func runningBundleIdentifiers(matching bundleIdentifiers: Set<String>) async -> Set<String> {
        runningIdentifiers().intersection(bundleIdentifiers)
    }

    func requestNormalTermination(
        bundleIdentifiers: Set<String>,
        timeoutSeconds: TimeInterval
    ) async -> Set<String> {
        await MainActor.run { onQuitRequest?() }
        lock.withLock { timeouts.append(timeoutSeconds) }
        for identifier in bundleIdentifiers.sorted() where isRunning(identifier) {
            _ = requestQuit(identifier)
        }
        if quitWait > .zero { try? await Task.sleep(for: quitWait) }
        return runningIdentifiers().intersection(bundleIdentifiers)
    }
}

/// Several running instances, possibly sharing one identifier. A quit
/// request for an identifier reaches every running instance of it, as the
/// reused `requestNormalTermination` does.
private final class InstanceApplications: BrowserPrivacyRunningApplicationChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let instances: [(identifier: String, name: String)]
    private var running: Set<Int>
    private var requested = [String]()

    init(instances: [(String, String)]) {
        self.instances = instances.map { (identifier: $0.0, name: $0.1) }
        running = Set(instances.indices)
    }

    func asked() -> [String] { lock.withLock { requested } }

    func runningBundleIdentifiers(matching bundleIdentifiers: Set<String>) async -> Set<String> {
        lock.withLock {
            Set(running.map { instances[$0].identifier }).intersection(bundleIdentifiers)
        }
    }

    func requestNormalTermination(
        bundleIdentifiers: Set<String>,
        timeoutSeconds _: TimeInterval
    ) async -> Set<String> {
        lock.withLock {
            for index in running.sorted() where bundleIdentifiers.contains(instances[index].identifier) {
                requested.append(instances[index].name)
                running.remove(index)
            }
        }
        return await runningBundleIdentifiers(matching: bundleIdentifiers)
    }

    @MainActor
    func quitService() -> CleanupOwnerQuitService {
        CleanupOwnerQuitService(
            runningApplications: { [self] in
                lock.withLock {
                    running.sorted().map { index in
                        CleanupOwnerQuitService.RunningApplication(
                            bundleIdentifier: instances[index].identifier,
                            localizedName: instances[index].name,
                            isRegularApplication: true
                        )
                    }
                }
            },
            terminator: self,
            ownBundleIdentifier: nil
        )
    }
}

private struct FakeApplicationEnvironment: CleanupApplicationEnvironment {
    let apps: FakeApplications

    func snapshot(checkingInstalled bundleIdentifiers: Set<String>) async -> CleanupApplicationSnapshot {
        CleanupApplicationSnapshot(
            runningBundleIdentifiers: apps.runningIdentifiers(),
            installedBundleIdentifiers: apps.installedIdentifiers().intersection(bundleIdentifiers)
        )
    }
}

private struct FakeRunningChecker: CleanupRunningApplicationChecking {
    let apps: FakeApplications

    func isRunning(bundleIdentifier: String) async -> Bool {
        apps.isRunning(bundleIdentifier)
    }
}

/// Moves into the fixture's own `.Trash`, never the real one.
private struct FixtureTrashMover: CleanupMoving {
    let trashURL: URL

    func moveToTrash(_ url: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let destination = trashURL.appendingPathComponent(UUID().uuidString + " " + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func moveToQuarantine(_ url: URL, planID _: CleanPlanID, itemID _: UUID) async throws -> URL {
        throw CleanupMoveError.invalidResult
    }
}

/// 显式隔离的成功删除实现，只接受本 Fixture 的 .Trash。
private struct FixtureTrashDeleter: CleanupPermanentDeleting {
    let trashURL: URL
    func removeTrashEntry(_ deletion: CleanupTrashEntryDeletion) async throws {
        guard deletion.trashURL.standardizedFileURL == trashURL.standardizedFileURL else {
            throw CleanupTrashDeletionRefusal.trashChanged
        }
        try await FoundationCleanupPermanentDeleter().removeTrashEntry(deletion)
    }
}

/// Returns the prepared sessions in order; the last one repeats.
private final class SessionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ScanSession]

    init(sessions: [ScanSession]) { self.sessions = sessions }

    func next() -> ScanSession {
        lock.withLock {
            sessions.count > 1 ? sessions.removeFirst() : sessions[0]
        }
    }
}

/// The scan requests the store sent, so a test can check which scope a later
/// scan covered.
private final class ScanRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = [CleanupScanRequest]()

    func append(_ request: CleanupScanRequest) { lock.withLock { requests.append(request) } }
    var all: [CleanupScanRequest] { lock.withLock { requests } }
}

private final class FixtureScanCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = [String]()

    func append(_ call: String) { lock.withLock { calls.append(call) } }
    var all: [String] { lock.withLock { calls } }
}

/// The rule loader the store calls at each scan; a test can make the next
/// load fail, as a damaged or missing rule file would.
private final class FixtureRuleLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var failsNext = false

    func failNextLoad() { lock.withLock { failsNext = true } }

    func load(_ rules: CleanupRuleSet) throws -> CleanupRuleSet {
        try lock.withLock {
            guard !failsNext else {
                failsNext = false
                throw FixtureRuleLoadFailure()
            }
            return rules
        }
    }
}

private struct FixtureRuleLoadFailure: Error {}

/// Stands in for the old full-disk scan of the file pages; it never reads
/// the disk.
private struct FixtureLegacyScanFailure: Error {}
private struct FixtureFileScanFailure: Error {}

/// Moves into the fixture Trash only after the test opens the gate, so a
/// cleanup can be stopped while its first move is in progress.
private final class GatedTrashMover: CleanupMoving, @unchecked Sendable {
    private let lock = NSLock()
    private let trashURL: URL
    private var entered = false
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    init(trashURL: URL) { self.trashURL = trashURL }

    var hasEntered: Bool { lock.withLock { entered } }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }

    func moveToTrash(_ url: URL) async throws -> URL {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                entered = true
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return try await FixtureTrashMover(trashURL: trashURL).moveToTrash(url)
    }

    func moveToQuarantine(_ url: URL, planID _: CleanPlanID, itemID _: UUID) async throws -> URL {
        throw CleanupMoveError.invalidResult
    }
}

/// Every move fails, as when the Trash refuses the items.
private struct FailingTrashMover: CleanupMoving {
    func moveToTrash(_ url: URL) async throws -> URL {
        throw CocoaError(.fileWriteNoPermission)
    }

    func moveToQuarantine(_ url: URL, planID _: CleanPlanID, itemID _: UUID) async throws -> URL {
        throw CleanupMoveError.invalidResult
    }
}

/// An unsigned app for the uninstall flow, which writes its own receipt to
/// `lastCleanReport`。应用位于同一个注入 home 的 Applications 子目录，移到夹具 Trash。
/// 测试结束仅删除这个临时副本。
private struct UninstallFixture {
    let root: URL
    let trash: URL
    let app: InstalledAppItem
    let moves: UninstallMoveEnvironment

    init(home: URL) throws {
        let fm = FileManager.default
        root = home.appendingPathComponent("Applications/UninstallFixture-\(UUID().uuidString)", isDirectory: true)
        trash = root.appendingPathComponent("fixture-trash", isDirectory: true)
        do {
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("Fixture.app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let bundleID = "org.storagecleaner.fixture." + UUID().uuidString.lowercased()
            let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "Fixture",
                                       "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            app = InstalledAppItem(id: url.path, name: "Fixture", bundleIdentifier: bundleID, path: url.path,
                version: "1.0", build: "1", category: "", appDescription: "", sizeBytes: 0, source: "fixture",
                modifiedAt: nil, scanIdentity: AppUninstallService.uninstallFileIdentity(at: url.path),
                relatedPaths: [], relatedItems: [], status: .installed)
            let trash = self.trash
            moves = UninstallMoveEnvironment(
                recycle: { source in
                    let destination = trash.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.moveItem(at: source, to: destination)
                    return destination
                },
                authorization: UninstallAuthorizationEnvironment(
                    helperVerdict: { _, _, _ in .accepts },
                    isWritable: { _ in true },
                    protection: { _ in .none },
                    move: { _, _, _, _ in
                        XCTFail("Store tests never reach the privileged helper")
                        throw POSIXError(.EPERM)
                    }
                )
            )
        } catch {
            TestFileSystem.remove(root)
            throw error
        }
    }

    func remove() { TestFileSystem.remove(root) }
}

@MainActor
private final class CleanupExitObservation {
    var tasks: [(name: String, task: Task<Void, Never>)] = []
}

/// Review-1's non-cancellable physical move, confined to the fixture Trash.
/// Cancellation and opening the gate are separate events. Both must happen
/// before the physical fixture move finishes; no scheduler/time margin is needed.
private final class InFlightCleanupMover: CleanupMoving, @unchecked Sendable {
    private let lock = NSLock()
    private let trashURL: URL
    private var isOpen = false
    private var active = 0
    private var begun = 0
    private var done = 0
    private var cancellationObserved = false
    private var sourcePresentAtCancellation = false
    private var released = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(trashURL: URL) { self.trashURL = trashURL }
    var hasEntered: Bool { lock.withLock { !waiters.isEmpty } }
    var inFlight: Bool { lock.withLock { active > 0 } }
    var started: Int { lock.withLock { begun } }
    var completed: Int { lock.withLock { done } }
    var wasCancelled: Bool { lock.withLock { cancellationObserved } }
    var sourceExistedAtCancellation: Bool { lock.withLock { sourcePresentAtCancellation } }
    var releasedWaiterCount: Int { lock.withLock { released } }
    func open() {
        let waiting = lock.withLock {
            isOpen = true
            guard cancellationObserved else { return [CheckedContinuation<Void, Never>]() }
            released += waiters.count
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
    func moveToTrash(_ url: URL) async throws -> URL {
        lock.withLock { active += 1; begun += 1 }
        defer { lock.withLock { active -= 1; done += 1 } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if isOpen && cancellationObserved { released += 1; return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            self.recordCancellation(of: url)
        }
        return try await FixtureTrashMover(trashURL: trashURL).moveToTrash(url)
    }
    private func recordCancellation(of url: URL) {
        let waiting = lock.withLock {
            cancellationObserved = true
            sourcePresentAtCancellation = FileManager.default.fileExists(atPath: url.path)
            guard isOpen else { return [CheckedContinuation<Void, Never>]() }
            released += waiters.count
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
    func moveToQuarantine(_ url: URL, planID _: CleanPlanID, itemID _: UUID) async throws -> URL {
        throw CleanupMoveError.invalidResult
    }
}
