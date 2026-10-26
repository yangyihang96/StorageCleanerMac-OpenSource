import Foundation
import XCTest
@testable import StorageCleanerMac

/// D214: cleanup and the clutter manager say “Could Not Start” and why when a
/// run is refused before its first item, record the items as not run, and
/// keep the selection. The executor and the cleanup flow are covered in
/// `CleanupExecutionSafetyTests` and `CleanupStoreFollowUpTests`.
@MainActor
final class CleanupNotStartedD214Tests: XCTestCase {
    func testEachRefusalSaysWhyAndThatNothingMoved() {
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        for owner in HeavyWorkCoordinator.Owner.allCases {
            let refusal = CleanStartRefusalPresentation.leaseRefusal(HeavyWorkCoordinator.Error.busy(activeOwner: owner))
            XCTAssertEqual(refusal.code, .coordinatorBusy)
            XCTAssertEqual(CleanStartRefusalPresentation.reason(refusal),
                           HeavyWorkActivityStore.conflictMessage(activeOwner: owner), "\(owner)")
        }
        let instance = CleanStartRefusalPresentation.leaseRefusal(OperationFileLock.Failure.busy)
        XCTAssertEqual(instance.detailCode, "instance-busy")
        XCTAssertEqual(CleanStartRefusalPresentation.reason(instance), "另一个软件实例正在处理任务，请等待它结束。")
        let unsafe = CleanStartRefusalPresentation.leaseRefusal(OperationFileLock.Failure.unsafePath)
        XCTAssertEqual(CleanStartRefusalPresentation.reason(unsafe), OperationFileLock.Failure.unsafePath.localizedDescription)
        let unknown = CleanStartRefusalPresentation.leaseRefusal(CocoaError(.fileReadUnknown))
        XCTAssertEqual(unknown, CleanFailure(code: .coordinatorBusy, detailCode: nil))
        XCTAssertEqual(CleanStartRefusalPresentation.reason(unknown), "另一项任务正在进行，请等待它结束后再试。")

        let refusals: [CleanFailure] = [
            instance, unknown,
            CleanFailure(code: .featureDisabled, detailCode: nil),
            CleanFailure(code: .planIntegrityFailed, detailCode: nil),
            CleanFailure(code: .persistenceFailed, detailCode: "intent-write-failed"),
        ]
        for refusal in refusals {
            let message = CleanStartRefusalPresentation.message(refusal)
            XCTAssertTrue(message.hasSuffix("没有移动任何文件，选中的项目都还在。"), message)
            for word in ["失败", "废纸篓", "HeavyWorkCoordinator", "错误"] {
                XCTAssertFalse(message.contains(word), "\(word) in \(message)")
            }
        }
        XCTAssertEqual(CleanStartRefusalPresentation.title, "没能开始")
        XCTAssertEqual(CleanStartRefusalPresentation.nothingMoved, "没有移动任何文件")
    }

    /// The clutter manager after a refused Move to Trash: the report is kept
    /// for its note, nothing is marked moved, the selection stays. After a run
    /// that started (here every copy was gone), as before, the selection goes.
    func testTheClutterSelectionStaysWhenTheRunCouldNotStart() throws {
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "d214-clutter")
        let store = try ScanStore.makeForTests(for: self, cleanupUserHomeURL: home)
        let workspace = store.duplicateFilesWorkspace
        let copies = (0..<3).map { index in
            StorageItem(id: "copy-\(index)", title: "clip.mov", path: home.appendingPathComponent("copy-\(index)/clip.mov").path,
                        groupTitle: "clip.mov", sizeBytes: 10, tier: .yellow, kind: "file", reason: "", recommendation: "", risk: "",
                        requiresClose: "", trashPaths: [], openPath: "", isDirectory: false, duplicateGroupID: "group-clip",
                        duplicateMatchKind: DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue, status: .available)
        }
        workspace.replaceItemsForTesting(copies)
        workspace.setSelected(true, item: copies[1], allItems: workspace.items)
        workspace.setSelected(true, item: copies[2], allItems: workspace.items)
        XCTAssertEqual(workspace.selectedItemIDs, ["copy-1", "copy-2"])

        let refused = Self.report(paths: [copies[1].path, copies[2].path], outcome: .notProcessed,
                                  refusal: CleanFailure(code: .coordinatorBusy, detailCode: "lease-busy:duplicateScan"))
        store.finishVerifiedDuplicateCleanup(with: refused)
        XCTAssertEqual(store.duplicateCleanupReport, refused, "kept for the manager's note")
        XCTAssertEqual(workspace.selectedItemIDs, ["copy-1", "copy-2"], "kept for a retry")
        XCTAssertTrue(workspace.items.allSatisfy { $0.status == .available })
        let message = try XCTUnwrap(store.actionMessage)
        XCTAssertTrue(message.hasPrefix("没能开始："), message)
        XCTAssertTrue(message.contains("正在进行重复文件扫描"), message)
        XCTAssertFalse(message.contains("已处理"), message)

        let ran = Self.report(paths: [copies[1].path], outcome: .skipped(.itemMissing), refusal: nil)
        store.finishVerifiedDuplicateCleanup(with: ran)
        XCTAssertEqual(store.duplicateCleanupReport, ran)
        XCTAssertTrue(workspace.selectedItemIDs.isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.actionMessage).hasPrefix("已处理 0 个重复副本"))
    }

    /// A report whose items all ended with `outcome`, with or without a refusal.
    private static func report(paths: [String], outcome: CleanItemOutcome, refusal: CleanFailure?) -> CleanReport {
        let planID = CleanPlanID()
        let now = Date()
        let items = paths.map { path in
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "duplicate-files.verified-copy", sourcePath: path,
                            estimatedBytes: 10, outcome: outcome)
        }
        let notRun = outcome == .notProcessed ? paths.count : 0
        var report = CleanReport(
            id: planID.rawValue, planID: planID, sessionID: ScanSessionID(), rulesVersion: "duplicate-files",
            disposition: .trash, scanWasPartial: false, startedAt: now, completedAt: now,
            outcome: notRun > 0 ? .failed : .partiallyCompleted, items: items,
            summary: CleanReportSummary(requestedItemCount: paths.count, movedItemCount: 0,
                                        skippedItemCount: paths.count - notRun, failedItemCount: 0,
                                        notProcessedItemCount: notRun, unverifiedMoveCount: 0,
                                        plannedBytes: Int64(10 * paths.count), movedToRecoverableLocationBytes: 0,
                                        reclaimableAfterEmptyingTrashBytes: 0, permanentlyFreedBytes: 0,
                                        availableSpaceDeltaBytes: nil))
        report.startRefusal = refusal
        return report
    }
}
