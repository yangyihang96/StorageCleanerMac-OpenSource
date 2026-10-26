import Foundation
import XCTest
@testable import StorageCleanerMac

/// D179: only what really kept the scan from reading everything shows the
/// results notice, marks history as limited and costs scan-completeness
/// score. 10-23 every scan on the user's Mac was "partial" (14–42 s, nothing
/// denied) because rows held back on purpose count as partial (D19, D104 G5).
final class ScanCoverageLimitsTests: XCTestCase {
    private let sessionID = ScanSessionID(rawValue: UUID())

    private func session(
        _ outcome: ScanOutcome,
        issues: [ScanIssue] = [],
        permissions: [CleanupPermissionReport] = [],
        measurement: MeasurementCompleteness = .complete,
        timedOutRules: Int = 0,
        truncated: Int = 0
    ) -> ScanSession {
        RescanFixtureRows.session(
            id: sessionID,
            outcome: outcome,
            groups: [("system", [("system.user-caches", [RescanFixtureRows.candidate(
                "system.user-caches", "/H/Library/Caches/com.example.app",
                sessionID: sessionID, inode: 179, bytes: 4_000_000, measurement: measurement)])])],
            permissions: permissions,
            issues: issues,
            metrics: ScanMetrics(visitedEntryCount: 1, candidateCount: 1, deduplicatedIdentityCount: 0,
                                 estimatedCandidateBytes: 4_000_000, timedOutRuleCount: timedOutRules,
                                 truncatedCandidateCount: truncated, duration: 18),
            rulesVersion: "d179",
            provenance: nil
        )
    }

    private func issue(_ kind: ScanIssueKind, _ path: String = "/H/Library/Caches/x") -> ScanIssue {
        ScanIssue(ruleID: "system.user-caches", path: path, kind: kind)
    }

    func testD192ClassicHeadingUsesRealCoverageLimitsInsteadOfPartialOutcome() {
        for partial in [session(.partial, issues: [issue(.symbolicLinkSkipped)]),
                        session(.partial, issues: [issue(.vanished)], permissions: [
                            CleanupPermissionReport(ruleID: "optional", path: "/H/Absent", status: .missing)])] {
            XCTAssertEqual(CleanupScanResultsView.resultHeaderSubtitle(for: partial),
                           L10n.text("扫描完成 · 请审阅结果", "Scan complete · Review results"),
                           "D192＋旧值：partial 原一律显示‘扫描结束 · 部分结果可供审阅’")
        }
        for limited in [session(.partial, issues: [issue(.timedOut)], timedOutRules: 1),
                        session(.partial, issues: [issue(.permissionDenied)], permissions: [
                            CleanupPermissionReport(ruleID: "x", path: "/H/Denied", status: .permissionDenied)]),
                        session(.partial, measurement: .failed(reason: .unknown)), session(.partial)] {
            XCTAssertEqual(CleanupScanResultsView.resultHeaderSubtitle(for: limited),
                           L10n.text("扫描结束 · 部分结果可供审阅", "Scan finished · Partial results available"))
        }
        XCTAssertEqual(CleanupScanResultsView.resultHeaderSubtitle(for: session(.cancelled)),
                       L10n.text("扫描已取消 · 保留已完成结果", "Scan cancelled · Completed results kept"))
    }

    func testRowsHeldBackOnPurposeAndVanishedFilesAreNotALimit() {
        for kind in [ScanIssueKind.candidateNotActionable, .candidateContainsExcludedPath,
                     .candidateContainsProtectedData, .vanished, .symbolicLinkSkipped] {
            let partial = session(.partial, issues: [issue(kind)])
            XCTAssertEqual(partial.outcome, .partial, "the outcome itself is unchanged (D104 G5)")
            XCTAssertFalse(partial.coverageLimits.isLimited, "\(kind)")
            XCTAssertNil(CareStudioJunkResultsPage.coverageNotice(partial.coverageLimits), "\(kind)")
            XCTAssertEqual(ScanHistoryService.entry(from: partial).scanWasLimited, false, "\(kind)")
        }
        for reason in [CleanupMeasurementIssue.symbolicLinkSkipped, .excludedDescendant] {
            let linksOnly = session(.partial, measurement: .lowerBound(reason: reason))
            XCTAssertFalse(linksOnly.coverageLimits.isLimited, "\(reason)")
        }
    }

    func testRealLimitsAreNamedInTheNotice() throws {
        let timedOut = session(.partial, issues: [issue(.timedOut)], timedOutRules: 1)
        XCTAssertTrue(timedOut.coverageLimits.reachedTimeLimit)
        XCTAssertTrue(try XCTUnwrap(CareStudioJunkResultsPage.coverageNotice(timedOut.coverageLimits))
            .contains(L10n.text("时间上限", "time limit")))
        XCTAssertEqual(ScanHistoryService.entry(from: timedOut).scanWasLimited, true)

        let partlyMeasured = session(.partial, measurement: .lowerBound(reason: .permissionDenied))
        XCTAssertEqual(partlyMeasured.coverageLimits.partlyMeasuredCount, 1)
        XCTAssertTrue(try XCTUnwrap(CareStudioJunkResultsPage.coverageNotice(partlyMeasured.coverageLimits))
            .contains(L10n.text("1 项只量出了部分大小", "1 item(s) only partly measured")))
        XCTAssertEqual(ScanHistoryService.entry(from: partlyMeasured).scanWasLimited, true)

        let unreadable = session(.partial, issues: [issue(.symbolicLinkSkipped, "/H/Library/Caches")],
            permissions: [CleanupPermissionReport(ruleID: "system.user-caches", path: "/H/Library/Caches", status: .unreadable)])
        XCTAssertEqual(unreadable.coverageLimits.unreadableLocationCount, 1)
        XCTAssertEqual(ScanHistoryService.entry(from: unreadable).scanWasLimited, true)

        let both = session(.partial, issues: [issue(.timedOut), issue(.metadataUnavailable)],
                           measurement: .failed(reason: .unknown), timedOutRules: 1, truncated: 3)
        let notice = try XCTUnwrap(CareStudioJunkResultsPage.coverageNotice(both.coverageLimits))
        XCTAssertTrue(notice.hasPrefix(L10n.text("结果可能不完整：", "Results may be incomplete: ")))
        for part in [L10n.text("时间上限", "time limit"), L10n.text("另有 3 个较小的项目没有列出", "3 smaller item(s) not listed"),
                     L10n.text("1 个项目因信息不全", "1 item(s) skipped for missing details")] {
            XCTAssertTrue(notice.contains(part), part)
        }
    }

    /// Denied folders are named in the notice but counted on their own in
    /// history (`deniedCount`, `permissionLimited`), as before.
    func testDeniedFoldersShowInTheNoticeButNotAsAScanLimit() throws {
        let denied = session(.partial, issues: [issue(.permissionDenied, "/H/Library/Caches")],
            permissions: [CleanupPermissionReport(ruleID: "system.user-caches", path: "/H/Library/Caches", status: .permissionDenied)])
        XCTAssertEqual(denied.coverageLimits.deniedLocationCount, 1, "the report and the issue are one place")
        XCTAssertTrue(try XCTUnwrap(CareStudioJunkResultsPage.coverageNotice(denied.coverageLimits))
            .contains(L10n.text("1 个位置没有读取权限", "1 place(s) without read permission")))
        let entry = ScanHistoryService.entry(from: denied)
        XCTAssertEqual(entry.scanWasLimited, false)
        XCTAssertEqual(entry.deniedCount, 1)
    }

    /// A complete outcome never reports more than the old rule did; a partial
    /// or cancelled one with nothing to explain it still counts as limited.
    func testOldRuleStillHoldsWhereNothingExplainsTheOutcome() {
        let complete = session(.complete, measurement: .lowerBound(reason: .permissionDenied))
        XCTAssertFalse(complete.coverageLimits.isLimited)
        XCTAssertTrue(session(.complete, truncated: 2).coverageLimits.isLimited)
        XCTAssertTrue(session(.complete, timedOutRules: 1).coverageLimits.reachedTimeLimit)

        let unexplained = session(.partial)
        XCTAssertTrue(unexplained.coverageLimits.unexplained)
        XCTAssertEqual(CareStudioJunkResultsPage.coverageNotice(unexplained.coverageLimits),
                       L10n.text("结果可能不完整：扫描没有全部完成。", "Results may be incomplete: the scan did not finish everywhere."))
        XCTAssertTrue(session(.cancelled, issues: [issue(.candidateNotActionable)]).coverageLimits.unexplained)
    }

    func testTheResultsPageAndConfirmationUseTheRealReasons() throws {
        let page = SwiftSourceScanning.compact(SwiftSourceScanning.code(try String(
            contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkResults.swift"), encoding: .utf8)))
        XCTAssertTrue(page.contains("ifletcoverage=Self.coverageNotice(session.coverageLimits){"))
        XCTAssertFalse(page.contains("ifsession.outcome==.partial{"))
        let confirmation = SwiftSourceScanning.compact(SwiftSourceScanning.code(try String(
            contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift"), encoding: .utf8)))
        XCTAssertTrue(confirmation.contains("ifpreflight.skippedCount>0{"))
        XCTAssertFalse(confirmation.contains("plan.scanWasPartial||preflight.skippedCount>0"))
    }
}
