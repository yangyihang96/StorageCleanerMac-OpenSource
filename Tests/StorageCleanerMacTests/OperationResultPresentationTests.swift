import XCTest
@testable import StorageCleanerMac

final class OperationResultPresentationTests: XCTestCase {
    func testSummaryDoesNotClaimNoUnselectedFilesWereKept() throws {
        let f = try RecordedCleanupRecoveryTests.Fixture(); defer { f.remove() }
        let result = OperationResultPresentation(report: f.report)
        XCTAssertEqual(result.summary, L10n.text("已移走 2", "Moved 2"))
    }

    func testRecoveryChangesCurrentStatusWithoutErasingOriginalMoves() throws {
        let f = try RecordedCleanupRecoveryTests.Fixture(); defer { f.remove() }
        var report = f.report
        XCTAssertEqual(OperationResultPresentation(report: report).state, .completed)
        report.recoveryAttempts = [.init(completedAt: Date(), items: [.init(id: UUID(),
            originalPath: report.items[0].sourcePath, outcome: .restored)])]
        let partial = OperationResultPresentation(report: report)
        XCTAssertEqual(partial.state, .partiallyRestored)
        XCTAssertEqual(partial.movedCount, 2)
        XCTAssertEqual(partial.restoredCount, 1)
        XCTAssertEqual(partial.remainingMovedBytes, 1)
        let secondPath = report.items[1].sourcePath
        report.recoveryAttempts?.append(.init(completedAt: Date(), items: [.init(id: UUID(),
            originalPath: secondPath, outcome: .restored)]))
        let restored = OperationResultPresentation(report: report)
        XCTAssertEqual(restored.state, .restored)
        XCTAssertEqual(restored.remainingMovedBytes, 0)
        XCTAssertEqual(report.summary.movedItemCount, 2)
        XCTAssertEqual(CleanupReportIndex(report: report, orderingDate: Date()).presentation, restored)
    }

    func testDuplicateRecoveryRowsNeverDoubleCountAndUnknownDoesNotClaimSuccess() throws {
        let f = try RecordedCleanupRecoveryTests.Fixture(); defer { f.remove() }
        var report = f.report
        let row = CleanupRecoveryItem(id: UUID(), originalPath: report.items[0].sourcePath, outcome: .restored)
        report.recoveryAttempts = [.init(completedAt: Date(), items: [row, row])]
        XCTAssertEqual(OperationResultPresentation(report: report).restoredCount, 1)
        let secondPath = report.items[1].sourcePath
        report.recoveryAttempts?.append(.init(completedAt: Date(), items: [.init(id: UUID(),
            originalPath: secondPath, outcome: .outcomeUnknown)]))
        XCTAssertEqual(OperationResultPresentation(report: report).state, .needsVerification)
        XCTAssertEqual(OperationResultPresentation(report: report, processing: true).state, .processing)
        XCTAssertEqual(OperationResultPresentation(report: report, processing: true, draining: true).state, .draining)
        report.persistenceFailure = "disk-full"
        XCTAssertEqual(OperationResultPresentation(report: report).state, .needsVerification)
    }

    func testFailedOrNotStartedRecoveryDoesNotClaimRestored() throws {
        let f = try RecordedCleanupRecoveryTests.Fixture(); defer { f.remove() }
        for outcome in [CleanupRecoveryItemOutcome.failed, .notProcessed, .conflict] {
            var report = f.report
            report.recoveryAttempts = [.init(completedAt: Date(), items: [.init(id: UUID(),
                originalPath: report.items[0].sourcePath, outcome: outcome)])]
            XCTAssertEqual(OperationResultPresentation(report: report).restoredCount, 0)
            XCTAssertNotEqual(OperationResultPresentation(report: report).state, .restored)
        }
    }
}
