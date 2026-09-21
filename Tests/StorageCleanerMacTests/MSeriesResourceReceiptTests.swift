import Foundation
import XCTest
@testable import StorageCleanerMac

final class MSeriesResourceReceiptTests: XCTestCase {
    func testCancelledInitializationClosesReceiptWithoutLeavingFixture() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Caches/StorageCleanerResourceFixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
        let cancellation = MSeriesCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try MSeriesStorageKernel(root: root, sessionID: UUID(),
            budget: 512 * 1024 * 1024, cancellation: cancellation, resourceJournal: journal))
        let report = try XCTUnwrap(journal.load().first)
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(report.items.first).sourcePath))
        XCTAssertTrue(report.restorableReceipts.isEmpty)
    }

    func testUnexpectedResourcePreventsRecursiveCleanupAndKeepsPendingReceipt() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Caches/StorageCleanerResourceFixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
        let session = UUID()
        var disk: MSeriesStorageKernel? = try MSeriesStorageKernel(root: root, sessionID: session,
            budget: 512 * 1024 * 1024, cancellation: MSeriesCancellation(), resourceJournal: journal)
        XCTAssertNotNil(disk)
        let foreign = root.appendingPathComponent("mseries-" + session.uuidString).appendingPathComponent("unexpected")
        try Data("keep".utf8).write(to: foreign)
        disk = nil
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "keep")
        XCTAssertEqual(try journal.load().first?.outcome, .partiallyCompleted)
        XCTAssertTrue(try XCTUnwrap(journal.load().first).restorableReceipts.isEmpty)
    }
}
