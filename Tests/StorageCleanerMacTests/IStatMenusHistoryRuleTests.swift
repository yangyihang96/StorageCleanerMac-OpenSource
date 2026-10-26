import Foundation
import XCTest
@testable import StorageCleanerMac

/// D101 G7: iStat Menus (Setapp) keeps its chart history in one folder. It is
/// listed yellow, never preselected, and moves to the Trash only while none of
/// the processes that write it runs. Only the path checked on this Mac is
/// listed.
final class IStatMenusHistoryRuleTests: XCTestCase {
    private static let ruleID = "user-data.istat-menus-setapp-history"
    private static let folder = "Library/Application Support/iStat Menus 7 (Setapp)"
    /// Read from the installed bundles on 2026-10-15: the app, its helper,
    /// the history service inside the menu bar app (the process that writes
    /// `history.db`) and the menu bar app.
    private static let writers = [
        "com.bjango.istatmenus-setapp",
        "com.bjango.istatmenus-setapp.agent",
        "com.bjango.istatmenus-setapp.history",
        "com.bjango.istatmenus-setapp.status",
    ]

    func testTheBundledRuleIsAReviewedItemForTheCheckedPathOnly() throws {
        let bundled = try CleanupRuleSetLoader.loadBundled()
        XCTAssertNoThrow(try CleanupRuleValidator.validate(bundled))
        let rule = try XCTUnwrap(bundled.rules.first { $0.id == Self.ruleID })
        XCTAssertEqual(rule.root.kind, .homeRelative)
        XCTAssertEqual(rule.root.path, Self.folder)
        XCTAssertEqual(rule.effectiveCandidateScope, .immediateChildren)
        XCTAssertEqual(rule.include.entryKinds, [.directory])
        XCTAssertEqual(rule.include.nameMatcher.mode, .exact)
        XCTAssertEqual(rule.include.nameMatcher.values, ["history"])
        XCTAssertEqual(rule.risk, .reviewOnly)
        XCTAssertEqual(rule.recommendation, .optional)
        XCTAssertEqual(rule.defaultSelection, .unselected)
        XCTAssertEqual(rule.executionEligibility, .eligibleAfterReview)
        XCTAssertEqual(rule.action, .moveToTrashAfterReview)
        XCTAssertTrue(rule.allowsManualSelection)
        XCTAssertEqual(rule.requiredClosedBundleIDs, Self.writers)
        XCTAssertFalse(DeveloperCleanupAgePolicy.applies(to: rule))
        XCTAssertNil(ProtectedLocations.kind(ofHomeRelative: rule.root.path + "/history"))

        let maintenance = try XCTUnwrap(rule.maintenance)
        XCTAssertEqual(maintenance.source, .json)
        XCTAssertEqual(maintenance.checkedAt, "2026-10-15")
        XCTAssertEqual(maintenance.applicability,
                       [CleanupRuleApplicability(field: "applicationBundleIdentifier", value: "com.bjango.istatmenus-setapp")])
        XCTAssertNotNil(CleanupImpactText.englishByChinese[maintenance.impact])
        XCTAssertTrue(maintenance.impact.contains("历史图表"))
        // D117: iStat Menus 7.30 never prunes the swap history in this folder.
        let reason = CleanupRuleCopy.text(for: rule.reasonKey)
        XCTAssertTrue(reason.contains("iStat Menus 7.30 不会清理其中交换空间的历史")
                      || reason.contains("iStat Menus 7.30 never prunes the swap history"), reason)
        let baseline = try CleanupRuleTestFixtures.baseline()
        let entry = try XCTUnwrap(baseline.entries.first { $0.ruleID == rule.id })
        XCTAssertEqual(entry.revision, 1)
        XCTAssertEqual(maintenance.revision, 1)
        XCTAssertEqual(entry.contentHash, try CleanupRuleFingerprint.contentHash(for: rule))
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(bundled, baseline: baseline))
    }

    /// With every bundled rule, only the history folder is listed: not the
    /// iStat apps beside it, not the database files one by one, and not the
    /// unchecked non-Setapp folder.
    func testOnlyTheHistoryFolderIsListedAndNotPreselected() async throws {
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let setapp = home.appendingPathComponent(Self.folder)
        try CleanupRuleTestFixtures.write(setapp.appendingPathComponent("history/history.db"), bytes: 2 * 1_048_576)
        try CleanupRuleTestFixtures.write(setapp.appendingPathComponent("history/history.db-wal"))
        try CleanupRuleTestFixtures.write(setapp.appendingPathComponent("history/history.db-shm"))
        for app in ["iStat Menus Menubar.app", "iStat Menus Helper.app", ".iStat Menus.app"] {
            try CleanupRuleTestFixtures.write(setapp.appendingPathComponent(app + "/Contents/MacOS/binary"),
                                              bytes: 2 * 1_048_576)
        }
        let other = home.appendingPathComponent("Library/Application Support/iStat Menus 7")
        try CleanupRuleTestFixtures.write(other.appendingPathComponent("history/history.db"), bytes: 2 * 1_048_576)
        try CleanupRuleTestFixtures.ageTree(home)

        let bundled = try CleanupRuleSetLoader.loadBundled()
        let session = try await CleanupRuleTestFixtures.scan(
            CleanupRuleTestFixtures.set(try bundled.rules.map(lowered)), home: home)
        let istat = session.candidates.filter {
            lexicalPath($0).hasPrefix(setapp.path + "/") || lexicalPath($0).hasPrefix(other.path + "/")
        }
        XCTAssertEqual(istat.map(lexicalPath), [setapp.appendingPathComponent("history").path],
                       "Scan issues: \(session.issues)")
        let history = try XCTUnwrap(istat.first)
        XCTAssertEqual(history.ruleID, Self.ruleID)
        XCTAssertEqual(history.risk, .reviewOnly)
        XCTAssertTrue(history.isSelectable)
        XCTAssertFalse(history.isPreselectedByDefault)
        XCTAssertFalse(CleanupSelection.defaults(in: session).selectedCandidateIDs.contains(history.id))
        XCTAssertEqual(history.requiredClosedBundleIDs, Self.writers)
    }

    /// The menu bar app and the helper keep running after the app quits;
    /// any one of the writers running holds the history back.
    func testAnyRunningWriterHoldsTheHistoryBack() async throws {
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        try CleanupRuleTestFixtures.write(home.appendingPathComponent(Self.folder + "/history/history.db"))
        try CleanupRuleTestFixtures.ageTree(home)
        let rule = try lowered(try XCTUnwrap(try CleanupRuleSetLoader.loadBundled().rules.first { $0.id == Self.ruleID }))
        let rules = CleanupRuleTestFixtures.set([rule])
        let session = try await CleanupRuleTestFixtures.scan(rules, home: home)
        let history = try XCTUnwrap(session.candidates.first, "Scan issues: \(session.issues)")
        var selection = CleanupSelection()
        selection.setCandidate(history.id, selected: true, in: session)
        let plan = try CleanPlanBuilder.makePlan(session: session, selection: selection, activeRules: rules,
                                                 disposition: .trash)
        XCTAssertEqual(plan.items.map(\.requiredClosedBundleIDs), [Self.writers])
        let context = CleanupExecutionContext(featureConfiguration: .productDefault, activeSessionID: session.id,
            activeRules: rules, userHomeURL: home, excludedURLs: [], approvedPlanItemIDs: nil)

        for running in Self.writers.map({ [$0] }) + [[]] {
            let report = await SafeCleanupExecutor(
                metadataReader: RuleTestReadOnlyFileSystem(root: home),
                runningApplicationChecker: RunningSet(running: Set(running)),
                coordinator: HeavyWorkCoordinator()
            ).preflight(plan: plan, context: context)
            XCTAssertNil(report.failure, "\(running)")
            XCTAssertEqual(report.items.map(\.status),
                           [running.isEmpty ? .ready : .skipped(.relatedAppStillRunning)], "\(running)")
        }
    }

    // MARK: Helpers

    /// Rule roots keep the home's spelling (/var/...), but items found by
    /// listing a folder are spelled /private/var/...; compare lexically.
    private func lexicalPath(_ candidate: ScanCandidate) -> String {
        PathSafety.lexicalPath(candidate.sourceURL.path)
    }

    /// Lower the size floor so small fixtures are listed; catalog coverage
    /// rules validate their sizes exactly and stay as they are.
    private func lowered(_ rule: CleanupRule) throws -> CleanupRule {
        guard !CleanupCoverageCatalog.cleanupRules.contains(where: { $0.id == rule.id }) else { return rule }
        return try CleanupRuleTestFixtures.replacing(rule, fields: ["minimumBytes": 1])
    }
}

private struct RunningSet: CleanupRunningApplicationChecking {
    let running: Set<String>

    func isRunning(bundleIdentifier: String) async -> Bool {
        running.contains(bundleIdentifier)
    }
}
