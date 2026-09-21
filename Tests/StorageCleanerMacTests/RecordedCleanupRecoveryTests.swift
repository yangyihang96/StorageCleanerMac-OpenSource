import Foundation
import XCTest
@testable import StorageCleanerMac

final class RecordedCleanupRecoveryTests: XCTestCase {
    struct Fixture {
        let root: URL
        let trash: URL
        let journal: CleanupReportJournal
        let report: CleanReport
        init() throws {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/StorageCleanerRecoveryFixture-" + UUID().uuidString)
            trash = root.appendingPathComponent("trash")
            journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let reader = FoundationReadOnlyFileSystem()
            let fixtureRoot = root
            let items = try ["A", "B"].map { name -> RecordedTrashOperation.Item in
                let url = fixtureRoot.appendingPathComponent(name)
                try Data(name.utf8).write(to: url)
                return RecordedTrashOperation.Item(path: url.path, bytes: 1, identity: try reader.snapshot(at: url).identity)
            }
            let target = trash, writer = journal
            report = RecordedTrashOperation.run(items: items, ruleID: "fixture.v1", validate: { _ in }, move: { source in
                let destination = target.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            }, persist: { try writer.checkpoint($0, expectedIdentities: $1) })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testRestorePersistsPartialSuccessAndConflictWithoutErasingOriginalReceipts() async throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("new-B".utf8).write(to: f.root.appendingPathComponent("B"))
        let coordinator = HeavyWorkCoordinator()
        let result = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: f.report, coordinator: coordinator, lease: lease,
                journal: f.journal, userHomeURL: f.root, trashURL: f.trash)
        }
        XCTAssertEqual(result.recovery.items.map(\.outcome), [.restored, .conflict])
        let saved = try XCTUnwrap(f.journal.load().first)
        XCTAssertEqual(saved.items.count, 2)
        XCTAssertEqual(saved.recoveryAttempts?.last?.items.map(\.outcome), [.restored, .conflict])
        XCTAssertEqual(saved.restorableReceipts.count, 1)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("B"), encoding: .utf8), "new-B")
    }

    func testResultWriteFailureStopsNextMoveAndReconcilesFirstAfterRelaunch() async throws {
        let f = try Fixture(); defer { f.remove() }
        let coordinator = HeavyWorkCoordinator()
        let result = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: f.report, coordinator: coordinator, lease: lease,
                journal: f.journal, userHomeURL: f.root, trashURL: f.trash, checkpoint: { report in
                    if report.recoveryAttempts?.last?.restoredCount == 1 { throw CocoaError(.fileWriteOutOfSpace) }
                    try f.journal.checkpoint(report, expectedIdentities: [:])
                })
        }
        XCTAssertNotNil(result.recovery.persistenceFailure)
        XCTAssertEqual(result.recovery.items.map(\.outcome), [.restored, .notProcessed])
        XCTAssertEqual(try f.journal.load().first?.recoveryAttempts?.last?.items.map(\.outcome), [.outcomeUnknown, .notProcessed])
        try await coordinator.withLease(owner: .restore) { _ in try f.journal.reconcileInterruptedRecoveries() }
        let saved = try XCTUnwrap(f.journal.load().first)
        XCTAssertEqual(saved.recoveryAttempts?.last?.items.map(\.outcome), [.restored, .notProcessed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.trash.appendingPathComponent("B").path))
        // Pass the stale pre-restore UI report: the durable first result wins.
        let second = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: f.report, coordinator: coordinator, lease: lease,
                journal: f.journal, userHomeURL: f.root, trashURL: f.trash)
        }
        XCTAssertEqual(second.recovery.items.map(\.originalPath), [f.root.appendingPathComponent("B").path])
        XCTAssertEqual(second.recovery.restoredCount, 1)
        XCTAssertTrue(second.report.restorableReceipts.isEmpty)
        XCTAssertEqual(second.report.items.count, 2)
        XCTAssertEqual(second.report.recoveryAttempts?.count, 2)
    }

    func testIntentFailureMovesNothingAndCancellationRetainsEveryUnexecutedPath() async throws {
        let f = try Fixture(); defer { f.remove() }
        let coordinator = HeavyWorkCoordinator()
        let denied = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: f.report, coordinator: coordinator, lease: lease,
                journal: f.journal, userHomeURL: f.root, trashURL: f.trash,
                checkpoint: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        XCTAssertEqual(denied.recovery.items.map(\.outcome), [.notProcessed, .notProcessed])
        XCTAssertNotNil(denied.recovery.persistenceFailure)
        let task = Task {
            try await coordinator.withLease(owner: .restore) { lease in
                await CleanupRecoveryService().restore(report: f.report, coordinator: coordinator, lease: lease,
                    journal: f.journal, userHomeURL: f.root, trashURL: f.trash, checkpoint: { report in
                        try f.journal.checkpoint(report, expectedIdentities: [:])
                        if report.recoveryAttempts?.last?.restoredCount == 1 {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
            }
        }
        let cancelled = try await task.value
        XCTAssertEqual(cancelled.recovery.items.map(\.outcome), [.restored, .notProcessed])
        XCTAssertEqual(try f.journal.load().first?.recoveryAttempts?.last?.items.map(\.outcome), [.restored, .notProcessed])
        let owner = await coordinator.activeOwner
        XCTAssertNil(owner)
    }

    func testExpiredLeaseDoesNotMoveAndNoReplaceRenamePreservesBothFiles() async throws {
        let f = try Fixture(); defer { f.remove() }
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .restore)
        await coordinator.release(lease)
        let result = await CleanupRecoveryService().restore(report: f.report, coordinator: coordinator, lease: lease,
            journal: f.journal, userHomeURL: f.root, trashURL: f.trash)
        XCTAssertEqual(result.recovery.restoredCount, 0)
        let receipt = try XCTUnwrap(f.report.restorableReceipts.first)
        let destination = URL(fileURLWithPath: receipt.originalPath)
        try Data("new-A".utf8).write(to: destination)
        XCTAssertThrowsError(try ExclusiveRecoveryMove.perform(source: receipt.resultingItemURL,
            destination: destination, expectedIdentity: XCTUnwrap(receipt.movedIdentity)))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new-A")
        XCTAssertEqual(try String(contentsOf: receipt.resultingItemURL, encoding: .utf8), "A")
    }

    func testCancellationAfterWriteAheadBeforeMoveLeavesBothSources() async throws {
        let f = try Fixture(); defer { f.remove() }
        let coordinator = HeavyWorkCoordinator()
        let task = Task {
            try await coordinator.withLease(owner: .restore) { lease in
                await CleanupRecoveryService().restore(report: f.report, coordinator: coordinator, lease: lease,
                    journal: f.journal, userHomeURL: f.root, trashURL: f.trash, checkpoint: { report in
                        try f.journal.checkpoint(report, expectedIdentities: [:])
                        if report.recoveryAttempts?.last?.items.contains(where: { $0.outcome == .outcomeUnknown }) == true {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
            }
        }
        let result = try await task.value
        XCTAssertEqual(result.recovery.items.map(\.outcome), [.notProcessed, .notProcessed])
        for name in ["A", "B"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.trash.appendingPathComponent(name).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(name).path))
        }
    }

    func testUnknownIntentWithoutMoveCanBeReconciledWithoutTouchingFiles() async throws {
        let f = try Fixture(); defer { f.remove() }
        var report = f.report
        report.recoveryAttempts = [CleanupRecoveryReport(completedAt: Date(), items: report.restorableReceipts.map {
            CleanupRecoveryItem(id: UUID(), originalPath: $0.originalPath, outcome: .outcomeUnknown)
        }, attemptID: UUID())]
        try f.journal.checkpoint(report, expectedIdentities: [:])
        XCTAssertTrue(try XCTUnwrap(f.journal.load().first).restorableReceipts.isEmpty)
        try f.journal.reconcileInterruptedRecoveries()
        XCTAssertEqual(try f.journal.load().first?.restorableReceipts.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("A").path))
    }
}
