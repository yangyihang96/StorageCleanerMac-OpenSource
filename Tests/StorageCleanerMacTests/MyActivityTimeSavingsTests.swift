import XCTest
@testable import StorageCleanerMac

final class MyActivityTimeSavingsTests: XCTestCase {
    private let now = MyActivityD187Fixtures.now

    func testEachOperationCategoryAndCombinedTotal() {
        let counts: [MyActivityTimeSavings.Category: Int] = [.uninstall: 2, .update: 3, .cleanup: 4, .maintenance: 5, .privacy: 6]
        let value = MyActivityTimeSavings(records: counts.map { .init(id: $0.key.rawValue, category: $0.key, count: $0.value) })
        XCTAssertEqual(value.counts, counts)
        XCTAssertEqual(value.minutes(for: .uninstall), 20)
        XCTAssertEqual(value.minutes(for: .update), 18)
        XCTAssertEqual(value.minutes(for: .cleanup), 20)
        XCTAssertEqual(value.minutes(for: .maintenance), 15)
        XCTAssertEqual(value.minutes(for: .privacy), 24)
        XCTAssertEqual(value.totalMinutes, 97)
    }

    func testZeroNegativeAndDuplicateEvidence() {
        XCTAssertEqual(MyActivityTimeSavings().totalMinutes, 0)
        let value = MyActivityTimeSavings(records: [
            .init(id: "app", category: .uninstall), .init(id: "app", category: .uninstall),
            .init(id: "app", category: .update), .init(id: "zero", category: .cleanup, count: 0),
            .init(id: "negative", category: .privacy, count: -1)
        ])
        XCTAssertEqual(value.counts, [.uninstall: 1, .update: 1])
        XCTAssertEqual(value.totalMinutes, 16)
    }

    func testExtremeCountsSaturateInsteadOfOverflowing() {
        let value = MyActivityTimeSavings(records: [.init(id: "many", category: .uninstall, count: Int.max),
                                                   .init(id: "more", category: .uninstall)])
        XCTAssertEqual(value.totalMinutes, Int.max)
        XCTAssertEqual(value.minutes(for: .uninstall), Int.max)
    }

    func testUninstallCountsApplicationsOnceAndNotTheirLeftovers() throws {
        let item = MyActivityD187Fixtures.movedItem()
        let report = MyActivityD187Fixtures.report(rules: "uninstall.selection.v1",
            items: [item, item, MyActivityD187Fixtures.movedItem("/Fixture/Library/Caches/app")])
        let index = CleanupReportIndex(report: report, orderingDate: now)
        let record = try XCTUnwrap(MyActivityTimeSavings.receiptRecord(index, detail: report))
        XCTAssertEqual(record.category, .uninstall)
        XCTAssertEqual(record.count, 1)
        XCTAssertEqual(MyActivityTimeSavings(records: [record]).totalMinutes, 10)
    }

    func testResetLeftoversAndUnreadableUninstallAreNotUninstalls() {
        let reset = MyActivityD187Fixtures.report(rules: "uninstall.selection.v1")
        let index = CleanupReportIndex(report: reset, orderingDate: now)
        XCTAssertNil(MyActivityTimeSavings.receiptRecord(index, detail: reset))
        XCTAssertNil(MyActivityTimeSavings.receiptRecord(index, detail: nil))
    }

    func testOnlySuccessfulCleanupReceiptsCount() {
        for outcome in [CleanReportOutcome.completed, .partiallyCompleted, .failed, .cancelled] {
            let report = MyActivityD187Fixtures.report(outcome: outcome)
            let record = MyActivityTimeSavings.receiptRecord(CleanupReportIndex(report: report, orderingDate: now), detail: report)
            XCTAssertEqual(record?.category, [.completed, .partiallyCompleted].contains(outcome) ? .cleanup : nil)
        }
        let empty = MyActivityD187Fixtures.report(items: [])
        XCTAssertNil(MyActivityTimeSavings.receiptRecord(CleanupReportIndex(report: empty, orderingDate: now), detail: empty))
        var unverified = MyActivityD187Fixtures.report()
        unverified.persistenceFailure = "fixture"
        XCTAssertNil(MyActivityTimeSavings.receiptRecord(CleanupReportIndex(report: unverified, orderingDate: now), detail: unverified))
    }

    func testTemporaryFilesAndFileManagementAreExcluded() {
        for rules in ["benchmark.fixture.v1", "migration.staging.v1", FileAnalysisTrashService.ruleID,
                      ExternalDriveMigrationService.originalRuleID, ExtensionRemovalService.ruleID] {
            let report = MyActivityD187Fixtures.report(rules: rules)
            XCTAssertNil(MyActivityTimeSavings.receiptRecord(CleanupReportIndex(report: report, orderingDate: now), detail: report), rules)
        }
    }

    func testUpdateQueueCountsOnlyCompletedAndReconciledTasks() {
        let app = MyActivityD187Fixtures.application()
        let plan = ApplicationUpdatePlan(automaticApplicationIDs: [app.id], requiresQuitApplicationIDs: [],
            requiresAuthorizationApplicationIDs: [], appStoreApplicationIDs: [], websiteApplicationIDs: [],
            manualApplicationIDs: [], skippedApplicationIDs: [])
        var tasks = ApplicationUpdateTaskState.allCases.map {
            ApplicationUpdateTask(sessionID: plan.id, application: app, state: $0, createdAt: now)
        }
        var isolated = ApplicationUpdateTask(sessionID: plan.id, application: app, state: .completed, createdAt: now)
        isolated.installationIsolated = true
        tasks.append(isolated)
        let queue = ApplicationUpdateQueueSnapshot(schemaVersion: 2, plan: plan, tasks: tasks, isPaused: false, updatedAt: now)
        let records = MyActivityTimeSavings.retainedRecords(updates: queue, website: nil, maintenance: [], privacy: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(MyActivityTimeSavings(records: records).totalMinutes, 6)
    }

    func testMaintenanceCountsOnlyRetainedSuccessfulTasks() {
        let results = [SystemMaintenanceRunResult(task: .flushDNS, outcome: .succeeded, message: "", finishedAt: now),
                       .init(task: .speedUpMail, outcome: .refused, message: "", finishedAt: now),
                       .init(task: .maintenanceScripts, outcome: .failed, message: "", finishedAt: now)]
        let records = MyActivityTimeSavings.retainedRecords(updates: nil, website: nil, maintenance: results, privacy: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(MyActivityTimeSavings(records: records + records).totalMinutes, 3)
    }

    func testPrivacyCountsOneConfirmedBatchNotEachDeletedRow() {
        let browser = BrowserPrivacyBrowser(id: "fixture", displayName: "Fixture", engine: .chromium,
                                            bundleIdentifier: "fixture", version: "1")
        let entry = BrowserPrivacyProcessingEntry(browser: browser, profileID: "fixture", recordCount: 500,
            capability: .verifiedVisitDeletion, outcome: .deleted, verifiedDeletedRecordIDs: [UUID(), UUID()])
        let report = BrowserPrivacyProcessingReport(selectedRecordCount: 500, entries: [entry])
        let records = MyActivityTimeSavings.retainedRecords(updates: nil, website: nil, maintenance: [], privacy: report)
        XCTAssertEqual(MyActivityTimeSavings(records: records).totalMinutes, 4)
        let manual = BrowserPrivacyProcessingReport(selectedRecordCount: 500, entries: [])
        XCTAssertTrue(MyActivityTimeSavings.retainedRecords(updates: nil, website: nil, maintenance: [], privacy: manual).isEmpty)
    }

    @MainActor
    func testDurationsFollowTheAppLanguageAndD178Grouping() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let chinese = language == .zhHans
            XCTAssertEqual(MyActivityTimeSavings.duration(0), chinese ? "0 分钟" : "0 minutes")
            XCTAssertEqual(MyActivityTimeSavings.duration(1), chinese ? "1 分钟" : "1 minute")
            XCTAssertEqual(MyActivityTimeSavings.duration(16), chinese ? "16 分钟" : "16 minutes")
            XCTAssertEqual(MyActivityTimeSavings.duration(60), chinese ? "1 小时" : "1 hour")
            XCTAssertEqual(MyActivityTimeSavings.duration(65), chinese ? "1 小时 5 分钟" : "1 hour 5 minutes")
            XCTAssertEqual(MyActivityTimeSavings.duration(61), chinese ? "1 小时 1 分钟" : "1 hour 1 minute")
            XCTAssertEqual(MyActivityTimeSavings.duration(72_000), chinese ? "1,200 小时" : "1,200 hours")
            XCTAssertEqual(MyActivityTimeSavings.duration(-1), chinese ? "0 分钟" : "0 minutes")
        }
    }

    func testTimeEstimateDoesNotChangeD93RecordedByteTotals() {
        let report = MyActivityD187Fixtures.report()
        var summary = MyActivitySummary()
        summary.add(CleanupReportIndex(report: report, orderingDate: now), now: now, calendar: .current)
        XCTAssertEqual(summary.movedBytes, 1_000_000)
        XCTAssertEqual(summary.freedBytes, 0)
        XCTAssertEqual(summary.operationCount, 1)
        XCTAssertEqual(summary.recoverableCount, 1)
    }
}
