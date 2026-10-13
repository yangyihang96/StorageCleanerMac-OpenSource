import Foundation
import XCTest
@testable import StorageCleanerMac

/// Interrupted moves and restores must be resolved in normal runs, not only in
/// tests, and a restore that provably moved nothing must stay retryable.
final class InterruptedOperationReconcileTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let trash: URL
        let journal: CleanupReportJournal
        let reader = FoundationReadOnlyFileSystem()

        init() throws {
            root = TestFileSystem.uniqueOperationRoot("StorageCleanerReconcileFixture")
            trash = root.appendingPathComponent("trash")
            journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
            do {
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            } catch {
                TestFileSystem.remove(root)
                throw error
            }
        }

        func item(_ name: String) throws -> RecordedTrashOperation.Item {
            let url = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return RecordedTrashOperation.Item(path: url.path, bytes: 1, identity: try reader.snapshot(at: url).identity)
        }

        /// Moves into the fixture Trash. `ambiguous` throws after the move,
        /// which records the row as moveOutcomeUnknown.
        func record(_ items: [RecordedTrashOperation.Item], ambiguous: Set<String> = []) -> CleanReport {
            let target = trash, writer = journal
            return RecordedTrashOperation.run(items: items, ruleID: "fixture.v1", validate: { _ in }, move: { source in
                let destination = target.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                if ambiguous.contains(source.lastPathComponent) { throw CocoaError(.fileWriteUnknown) }
                return destination
            }, persist: { try writer.checkpoint($0, expectedIdentities: $1) })
        }

        func saved(_ report: CleanReport) throws -> CleanReport {
            try journal.read(journal.directory.appendingPathComponent(report.planID.rawValue.uuidString + ".json")).report
        }

        func remove() {
            chmod(root.path, 0o755)
            TestFileSystem.remove(root)
        }
    }

    private func isUnknown(_ item: CleanReportItem) -> Bool {
        if case .failed(let failure) = item.outcome { return failure.code == .moveOutcomeUnknown }
        return false
    }

    func testUnreadableTrashStillLetsInterruptedRestoresResolve() async throws {
        try XCTSkipIf(geteuid() == 0, "chmod cannot deny the superuser")
        let f = try Fixture(); defer { f.remove() }
        let interruptedMove = f.record([try f.item("X")], ambiguous: ["X"])
        XCTAssertTrue(isUnknown(try XCTUnwrap(interruptedMove.items.first)))
        // A restore whose result write failed after the file was put back.
        let restoredFile = f.record([try f.item("A")])
        let coordinator = HeavyWorkCoordinator()
        _ = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: restoredFile, coordinator: coordinator, lease: lease,
                journal: f.journal, userHomeURL: f.root, trashURL: f.trash, checkpoint: { report in
                    if report.recoveryAttempts?.last?.restoredCount == 1 { throw CocoaError(.fileWriteOutOfSpace) }
                    try f.journal.checkpoint(report, expectedIdentities: [:])
                })
        }
        XCTAssertEqual(try f.saved(restoredFile).recoveryAttempts?.last?.items.map(\.outcome), [.outcomeUnknown])

        let lockedTrash = f.root.appendingPathComponent("locked-trash")
        try FileManager.default.createDirectory(at: lockedTrash, withIntermediateDirectories: true)
        chmod(lockedTrash.path, 0o000)
        defer { chmod(lockedTrash.path, 0o755) }
        let issues = f.journal.reconcileInterruptedOperations(trashRoot: lockedTrash)

        XCTAssertEqual(issues, [.trashNotReadable])
        XCTAssertEqual(try f.saved(restoredFile).recoveryAttempts?.last?.items.map(\.outcome), [.restored])
        XCTAssertTrue(isUnknown(try XCTUnwrap(f.saved(interruptedMove).items.first)))

        chmod(lockedTrash.path, 0o755)
        XCTAssertEqual(f.journal.reconcileInterruptedOperations(trashRoot: f.trash), [])
        XCTAssertEqual(try f.saved(interruptedMove).restorableReceipts.count, 1)
    }

    func testOneUnwritableReceiptDoesNotHoldBackTheOthers() throws {
        try XCTSkipIf(geteuid() == 0, "chmod cannot deny the superuser")
        let f = try Fixture(); defer { f.remove() }
        let blocked = f.record([try f.item("X")], ambiguous: ["X"])
        let open = f.record([try f.item("Y")], ambiguous: ["Y"])
        // The blocked receipt's event log refuses the update.
        let target = CleanupJournalEvents.eventURL(
            for: f.journal.directory.appendingPathComponent(blocked.planID.rawValue.uuidString + ".json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        chmod(target.path, 0o400)
        defer { chmod(target.path, 0o600) }

        let issues = f.journal.reconcileInterruptedOperations(trashRoot: f.trash)

        XCTAssertEqual(issues, [.trashMovesFailed])
        XCTAssertEqual(try f.saved(open).restorableReceipts.count, 1, "The writable receipt is still resolved")
        XCTAssertTrue(isUnknown(try XCTUnwrap(f.saved(blocked).items.first)))
    }

    func testReconcileKeepsAUserCancellation() throws {
        let f = try Fixture(); defer { f.remove() }
        var report = f.record([try f.item("A"), try f.item("B")], ambiguous: ["B"])
        report.outcome = .cancelled
        try f.journal.checkpoint(report, expectedIdentities: [:])

        XCTAssertEqual(f.journal.reconcileInterruptedOperations(trashRoot: f.trash), [])

        let saved = try f.saved(report)
        XCTAssertEqual(saved.outcome, .cancelled)
        XCTAssertEqual(saved.summary.movedItemCount, 2)
        XCTAssertEqual(saved.restorableReceipts.count, 2)
    }

    func testRestoreThatMovedNothingStaysRetryable() async throws {
        try XCTSkipIf(geteuid() == 0, "chmod cannot deny the superuser")
        let f = try Fixture(); defer { f.remove() }
        let report = f.record([try f.item("A")])
        let coordinator = HeavyWorkCoordinator()
        // The original folder refuses new entries, so the rename fails atomically.
        chmod(f.root.path, 0o555)
        let denied = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: report, coordinator: coordinator, lease: lease,
                journal: f.journal, userHomeURL: f.root, trashURL: f.trash)
        }
        chmod(f.root.path, 0o755)

        XCTAssertEqual(denied.recovery.items.map(\.outcome), [.failed])
        XCTAssertEqual(denied.report.restorableReceipts.count, 1, "A definite failure must not lock the receipt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.trash.appendingPathComponent("A").path))

        let retried = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: denied.report, coordinator: coordinator, lease: lease,
                journal: f.journal, userHomeURL: f.root, trashURL: f.trash)
        }
        XCTAssertEqual(retried.recovery.items.map(\.outcome), [.restored])
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("A"), encoding: .utf8), "A")
    }

    func testUnmovedRestoreErrorsMapToRetryableOutcomes() {
        XCTAssertEqual(CleanupRecoveryService.unmovedRestoreOutcome(POSIXError(.EEXIST)), .conflict)
        XCTAssertEqual(CleanupRecoveryService.unmovedRestoreOutcome(POSIXError(.ENOTEMPTY)), .conflict)
        XCTAssertEqual(CleanupRecoveryService.unmovedRestoreOutcome(CleanupReportJournal.Failure.invalidEntry), .identityChanged)
        XCTAssertEqual(CleanupRecoveryService.unmovedRestoreOutcome(AppUninstallError.identityChanged("/x")), .identityChanged)
        XCTAssertEqual(CleanupRecoveryService.unmovedRestoreOutcome(POSIXError(.EACCES)), .failed)
        XCTAssertEqual(CleanupRecoveryService.unmovedRestoreOutcome(POSIXError(.EXDEV)), .failed)
    }

    @MainActor
    func testStoreReportsBusyLeaseAndUnreadableTrashInsteadOfSwallowingThem() async throws {
        let coordinator = HeavyWorkCoordinator()
        let store = try ScanStore.makeForTests(for: self, heavyWorkCoordinator: coordinator, cleanReportLoader: { [] },
                              interruptedOperationReconciler: { [.trashNotReadable] })
        await store.reconcileInterruptedOperations()
        XCTAssertEqual(store.operationReconcileNotice, .trashNotReadable)

        // Busy with nothing known to need verification: say nothing, try again on refresh.
        let lease = try await coordinator.acquire(owner: .cleanup)
        await store.reconcileInterruptedOperations()
        XCTAssertNil(store.operationReconcileNotice)
        await coordinator.release(lease)

        let clean = try ScanStore.makeForTests(for: self, heavyWorkCoordinator: coordinator, cleanReportLoader: { [] },
                              interruptedOperationReconciler: { [] })
        await clean.reconcileInterruptedOperations()
        XCTAssertNil(clean.operationReconcileNotice)
        XCTAssertEqual(OperationReconcileNotice([.recoveriesFailed]), .incomplete)
    }
}
