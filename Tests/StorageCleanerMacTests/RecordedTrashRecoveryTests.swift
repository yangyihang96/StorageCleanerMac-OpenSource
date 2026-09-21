import Foundation
import XCTest
@testable import StorageCleanerMac

final class RecordedTrashRecoveryTests: XCTestCase {
    func testAmbiguousSecondMoveKeepsFirstReceiptAndRecoversByIdentityWithoutOverwriting() async throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/StorageCleanerFixture-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let trash = root.appendingPathComponent("fixture-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        try Data("first".utf8).write(to: a)
        try Data("second".utf8).write(to: b)
        let reader = FoundationReadOnlyFileSystem()
        XCTAssertEqual(AppUninstallService.uninstallFileIdentity(at: a.path), try reader.snapshot(at: a).identity)
        let items = try [a, b].map { url in
            RecordedTrashOperation.Item(path: url.path, bytes: 6, identity: try reader.snapshot(at: url).identity)
        }
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
        let report = RecordedTrashOperation.run(items: items, ruleID: "fixture.v1", validate: { _ in },
            move: { source in
                let target = trash.appendingPathComponent(source.lastPathComponent)
                try fm.moveItem(at: source, to: target)
                if source == b { throw CocoaError(.fileWriteUnknown) }
                return target
            }, persist: { try journal.checkpoint($0, expectedIdentities: $1) })
        XCTAssertEqual(report.restorableReceipts.count, 1)
        XCTAssertEqual(try journal.load().first?.restorableReceipts.count, 1)
        // New content at B must remain, even though its old version is in Trash.
        try Data("new B".utf8).write(to: b)
        try journal.reconcileInterruptedTrashMoves(trashRoot: trash)
        let recovered = try XCTUnwrap(journal.load().first)
        XCTAssertEqual(recovered.restorableReceipts.count, 2)
        let result = await CleanupRecoveryService().restore(receipts: recovered.restorableReceipts,
            userHomeURL: root, trashURL: trash)
        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(result.items.filter { $0.outcome == .conflict }.count, 1)
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "new B")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "first")
        XCTAssertTrue(fm.fileExists(atPath: trash.appendingPathComponent("B").path))
    }

    func testLegacyMultiPathFailureKeepsSuccessfulPathInDurableReport() throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/StorageCleanerFixture-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let item = StorageItem(id: "multiple", title: "Fixture", path: root.path, groupTitle: "Fixture",
            sizeBytes: 2, tier: .green, kind: "cache", reason: "fixture", recommendation: "fixture",
            risk: "low", requiresClose: "", trashPaths: [a.path, b.path], openPath: root.path, status: .available)
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
        let report = CleanupService.moveToTrashRecorded(item, allowedPaths: [a.path, b.path], excludedPaths: [],
            trashItemOperation: { url in
                if url == b { throw CocoaError(.fileWriteNoPermission) }
                let target = root.appendingPathComponent("moved-a")
                try fm.moveItem(at: url, to: target)
                return target
            }, persist: { try journal.checkpoint($0, expectedIdentities: $1) })
        XCTAssertEqual(report.outcome, .partiallyCompleted)
        XCTAssertEqual(report.restorableReceipts.count, 1)
        XCTAssertEqual(report.legacyTrashRecords.count, 1)
        XCTAssertEqual(try journal.load().first?.restorableReceipts.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: b.path))
        XCTAssertEqual(report.summary.permanentlyFreedBytes, 0)
    }

    func testStagingCleanupCannotDeleteReplacedDirectoryAndLeavesDurableResidual() throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/StorageCleanerFixture-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = try MigrationStagingDirectory(parentURL: root)
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
        let receipt = try MigrationStagingReceipt(url: staging.url, journal: journal)
        let original = root.appendingPathComponent("original-staging")
        try fm.moveItem(at: staging.url, to: original)
        try fm.createDirectory(at: staging.url, withIntermediateDirectories: false)
        let marker = staging.url.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: marker)
        receipt.cleanup(staging)
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
        XCTAssertEqual(try journal.load().first?.outcome, .partiallyCompleted)
    }
}
