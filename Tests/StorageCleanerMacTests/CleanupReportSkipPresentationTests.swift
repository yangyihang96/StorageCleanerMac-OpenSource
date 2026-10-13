import Foundation
import XCTest
@testable import StorageCleanerMac

/// D52 要求仍在使用的项目跳过并说明原因；保留既有回执中的真实失败和取消状态。
@MainActor
final class CleanupReportSkipPresentationTests: XCTestCase {
    func testStillInUseSkipsHaveTheirOwnNeutralGroup() {
        for reason in [CleanSkipReason.candidateBecameActive, .relatedAppStillRunning] {
            XCTAssertEqual(CleanupReportIssueGroup.group(for: .skipped(reason)), .stillInUse)
        }
        XCTAssertEqual(CleanupReportIssueGroup.group(for: .skipped(.identityChanged)), .notCompleted)
        XCTAssertEqual(CleanupReportIssueGroup.group(for: .failed(CleanFailure(code: .metadataReadFailed,
            detailCode: "permission-denied"))), .notCompleted)
        XCTAssertEqual(CleanupReportIssueGroup.group(for: .notProcessed), .notCompleted)
        let moved = CleanupMoveReceipt(originalPath: "/Fixture/item",
            resultingItemURL: URL(fileURLWithPath: "/Fixture/trash/item"), disposition: .trash,
            movedIdentity: nil, verification: .destinationMetadataUnavailable, movedAt: Date())
        XCTAssertNil(CleanupReportIssueGroup.group(for: .moved(moved)))
        XCTAssertEqual(CleanupReportIssueGroup.stillInUse.systemImage, "minus.circle")
        XCTAssertEqual(CleanupReportIssueGroup.notCompleted.systemImage, "exclamationmark.circle")
    }

    func testCompletionAndOperationHistoryUseTheSameWordingAndKeepTheReason() {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        }
        for language in [AppLanguage.zhHans, .english] {
            var domain = original
            domain[L10n.languageDefaultsKey] = language.rawValue
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            XCTAssertEqual(L10n.usesChinese, language == .zhHans)
            XCTAssertEqual(CleanupReportIssueGroup.stillInUse.title,
                language == .zhHans ? "仍在使用，已跳过" : "Skipped: still in use")
            let reason = CleanSkipReasonPresentation.title(.candidateBecameActive)
            XCTAssertEqual(reason,
                language == .zhHans ? "扫描后仍有新写入或变化，可能正在使用；已跳过，如需清理请重新扫描"
                    : "Written or changed after the scan and may be in use; skipped. Scan again to clean it")
            XCTAssertEqual(CleanSkipReasonPresentation.recordLabel(.candidateBecameActive),
                language == .zhHans ? "仍在使用，已跳过 · 扫描后有新写入或变化"
                    : "Skipped: still in use · Written or changed after the scan")
            XCTAssertEqual(CleanSkipReasonPresentation.recordLabel(.relatedAppStillRunning),
                language == .zhHans ? "仍在使用，已跳过 · 相关应用仍在运行"
                    : "Skipped: still in use · Related app is still running")
            // Review r3 P2-5: under the “still in use” group title the row gives
            // the cause and the advice, without saying “skipped” again.
            let rowDetail = CleanupReportIssueList.detail(.skipped(.candidateBecameActive))
            XCTAssertEqual(rowDetail,
                language == .zhHans ? "扫描后有新写入或变化，如需清理请重新扫描"
                    : "Written or changed after the scan; scan again to clean it")
            XCTAssertFalse(rowDetail.contains("已跳过"))
            XCTAssertFalse(rowDetail.lowercased().contains("skipped"))
            XCTAssertEqual(CleanupReportIssueList.detail(.skipped(.relatedAppStillRunning)),
                CleanSkipReasonPresentation.title(.relatedAppStillRunning))
            XCTAssertEqual(CleanupReportIssueList.detail(.skipped(.identityChanged)),
                CleanSkipReasonPresentation.title(.identityChanged))
            XCTAssertEqual(CleanSkipReasonPresentation.recordLabel(.identityChanged),
                L10n.text("已跳过：", "Skipped: ") + CleanSkipReasonPresentation.title(.identityChanged))
        }
    }

    func testStillInUseSkipsAreKeptAndNeverCountedAsFailures() throws {
        let outcomes: [CleanItemOutcome] = [.skipped(.candidateBecameActive), .skipped(.relatedAppStillRunning)]
        let items = outcomes.enumerated().map { index, outcome in
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "system.user-caches",
                sourcePath: "/Fixture/\(index)", estimatedBytes: 1, outcome: outcome)
        }
        let report = CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(),
            rulesVersion: "fixture", disposition: .trash, scanWasPartial: false,
            startedAt: Date(), completedAt: Date(), outcome: .partiallyCompleted, items: items,
            summary: CleanReportSummary(requestedItemCount: 2, movedItemCount: 0, skippedItemCount: 2,
                failedItemCount: 0, notProcessedItemCount: 0, unverifiedMoveCount: 0, plannedBytes: 2,
                movedToRecoverableLocationBytes: 0, reclaimableAfterEmptyingTrashBytes: nil,
                permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil))
        let result = OperationResultPresentation(report: report)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.keptCount, 2)
        XCTAssertEqual(result.state, .retained)
        // 不新造持久化原因枚举；旧回执语义保持可往返读取。
        XCTAssertEqual(try JSONDecoder().decode(CleanReport.self, from: JSONEncoder().encode(report)), report)
    }

    func testCompletionAndOperationHistoryUseTheSharedPolicy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift"), encoding: .utf8)
        let record = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/ReversibleOperationsView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("ForEach(CleanupReportIssueGroup.allCases"))
        XCTAssertTrue(view.contains("CleanupReportIssueGroup.group(for: $0.outcome) == group"))
        XCTAssertTrue(view.contains("Image(systemName: group.systemImage)"))
        XCTAssertTrue(view.contains(".foregroundStyle(group.tint)"))
        XCTAssertTrue(record.contains("CleanSkipReasonPresentation.recordLabel(reason)"))
    }
}
