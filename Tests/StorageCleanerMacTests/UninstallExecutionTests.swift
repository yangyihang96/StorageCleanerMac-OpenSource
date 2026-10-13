import Foundation
import XCTest
@testable import StorageCleanerMac

final class UninstallExecutionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let trash: URL
        let items: [RecordedTrashOperation.Item]
        let journal: CleanupReportJournal
        init() throws {
            root = TestFileSystem.uniqueOperationRoot("SCM-Uninstall")
            trash = root.appendingPathComponent("trash")
            do {
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                let base = root
                items = try ["A", "B"].map { name in
                    let url = base.appendingPathComponent(name)
                    try Data(name.utf8).write(to: url)
                    return .init(path: url.path, bytes: 0, identity: try FoundationReadOnlyFileSystem().snapshot(at: url).identity)
                }
                journal = CleanupReportJournal(directory: root.appendingPathComponent("journal"))
            } catch {
                TestFileSystem.remove(root)
                throw error
            }
        }
        func move(_ source: URL) throws -> URL {
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        func remove() { TestFileSystem.remove(root) }
    }
    actor Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        var released = false
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    func testCancellationDrainsNativeMoveAndSavesReceiptBeforeReleasingLease() async throws {
        let f = try Fixture(); defer { f.remove() }
        let gate = Gate(); let coordinator = HeavyWorkCoordinator()
        let worker = Task {
            try await coordinator.withLease(owner: .cleanup) { lease in
                await RecordedTrashOperation.runAsync(items: f.items, ruleID: "fixture",
                    validate: { _ in try await coordinator.requireValid(lease, owner: .cleanup) },
                    move: { source in await gate.wait(); return try f.move(source) },
                    persist: { try f.journal.checkpoint($0, expectedIdentities: $1) })
            }
        }
        for _ in 0..<500 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await gate.entered else {
            worker.cancel()
            await gate.release()
            _ = try? await worker.value
            return XCTFail("Move callback was not reached within five seconds")
        }
        worker.cancel()
        let held = await coordinator.activeOwner
        XCTAssertEqual(held, .cleanup)
        await gate.release()
        let report = try await worker.value
        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertEqual(report.summary.notProcessedItemCount, 1)
        XCTAssertEqual(report.outcome, .cancelled)
        XCTAssertEqual(try f.journal.load().first?.restorableReceipts.count, 1)
        let released = await coordinator.activeOwner
        XCTAssertNil(released)
    }
    func testFirstFailurePreventsRelatedMove() async throws {
        let f = try Fixture(); defer { f.remove() }
        var calls = 0
        let report = await RecordedTrashOperation.runAsync(items: f.items, ruleID: "fixture", validate: { _ in },
            move: { _ in calls += 1; throw CocoaError(.fileWriteNoPermission) }, requiresFirstSuccess: true,
            persist: { try f.journal.checkpoint($0, expectedIdentities: $1) })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(report.summary.notProcessedItemCount, 1)
        XCTAssertEqual(report.summary.movedItemCount, 0)
    }
    func testZeroByteCountUsesReceiptAndPartialSuccessSurvivesReload() async throws {
        let f = try Fixture(); defer { f.remove() }
        let report = await RecordedTrashOperation.runAsync(items: f.items, ruleID: "fixture", validate: { _ in },
            move: { source in if source.lastPathComponent == "B" { throw POSIXError(.ENOSPC) }; return try f.move(source) },
            persist: { try f.journal.checkpoint($0, expectedIdentities: $1) })
        let result = AppUninstallTrashResult(movedAppBytes: 0, movedRelatedItems: [], skippedRelatedPaths: [], failedRelatedPaths: [], report: report)
        XCTAssertEqual(result.movedItemCount, 1)
        XCTAssertEqual(report.outcome, .partiallyCompleted)
        XCTAssertEqual(try f.journal.load().first?.restorableReceipts.count, 1)
    }
    struct UnreadableSourceAfterMove: ReadOnlyFileSystem {
        let source: String
        let reader = FoundationReadOnlyFileSystem()
        func snapshot(at url: URL) throws -> FileSnapshot {
            do { return try reader.snapshot(at: url) }
            catch CleanupFileSystemError.vanished where url.path == source { throw CleanupFileSystemError.permissionDenied }
        }
        func children(of url: URL) throws -> [URL] { try reader.children(of: url) }
    }
    func testUnreadableSourceIsNotPositiveAbsence() async throws {
        let f = try Fixture(); defer { f.remove() }
        let item = try XCTUnwrap(f.items.first)
        let report = await RecordedTrashOperation.runAsync(items: [item], ruleID: "fixture", validate: { _ in },
            move: { try f.move($0) }, metadata: UnreadableSourceAfterMove(source: item.path), persist: { _, _ in })
        XCTAssertEqual(report.summary.movedItemCount, 0)
        guard case .failed(let failure) = try XCTUnwrap(report.items.first).outcome else { return XCTFail("Expected unknown result") }
        XCTAssertEqual(failure.code, .moveOutcomeUnknown)
    }
    /// Batch 3a rule change: this test used to accept any permission-type chain
    /// as grounds for the administrator prompt. A refusal still records "not
    /// moved"; authorization now also needs the bundle or its folder to be
    /// really unwritable (plus the helper's policy and no lock flag). A lone
    /// Cocoa 513 counts like POSIX EACCES/EPERM: the field receipt for an
    /// installer-owned app held only that (docs/2.0.0/UNINSTALL-513-20260925.md).
    func testNestedPermissionErrorRetainsCodesAndOffersAuthorizationOnlyForUnwritableFolders() {
        let app = "/Applications/Fixture.app"
        func decide(_ error: Error, writable: @escaping (String) -> Bool) -> UninstallAuthorizationDecision {
            UninstallAuthorizationDecision.evaluate(error, applicationPath: app, isWritable: writable,
                                                    protection: { _ in .none }, helperVerdict: { .accepts })
        }
        let error = NSError(domain: NSCocoaErrorDomain, code: 513,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13)])
        XCTAssertTrue(UninstallErrorEvidence.isPermissionDenied(error))
        XCTAssertTrue(UninstallErrorEvidence.hasPOSIXPermissionDenial(error))
        XCTAssertEqual(UninstallErrorEvidence.codes(error), "NSCocoaErrorDomain:513 > NSPOSIXErrorDomain:13")
        XCTAssertEqual(decide(error, writable: { _ in true }), .systemRefused)
        XCTAssertEqual(decide(error, writable: { $0 != "/Applications" }), .offer)

        let lone = NSError(domain: NSCocoaErrorDomain, code: 513)
        XCTAssertTrue(UninstallErrorEvidence.isPermissionDenied(lone), "Still a refusal, never an unknown move")
        XCTAssertFalse(UninstallErrorEvidence.hasPOSIXPermissionDenial(lone))
        XCTAssertEqual(decide(lone, writable: { _ in true }), .systemRefused)
        XCTAssertEqual(decide(lone, writable: { $0 != app }), .offer)
    }
    func testResultWriteFailureStopsNextItemAndKeepsRecoverableInMemoryResult() async throws {
        let f = try Fixture(); defer { f.remove() }
        var moved = 0
        let report = await RecordedTrashOperation.runAsync(items: f.items, ruleID: "fixture", validate: { _ in },
            move: { moved += 1; return try f.move($0) }, persist: { report, identities in
                if report.summary.movedItemCount > 0 { throw POSIXError(.ENOSPC) }
                try f.journal.checkpoint(report, expectedIdentities: identities)
            })
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(report.restorableReceipts.count, 1)
        XCTAssertEqual(report.persistenceFailure, "result-write-failed")
        try f.journal.reconcileInterruptedTrashMoves(trashRoot: f.trash)
        XCTAssertEqual(try f.journal.load().first?.restorableReceipts.count, 1)
    }
    func testReplacementAfterIntentStopsBeforeMove() async throws {
        let f = try Fixture(); defer { f.remove() }
        let item = try XCTUnwrap(f.items.first)
        var changed = false; var moves = 0
        let report = await RecordedTrashOperation.runAsync(items: [item], ruleID: "fixture", validate: { _ in },
            move: { moves += 1; return try f.move($0) }, persist: { report, _ in
                if !changed, case .failed = try XCTUnwrap(report.items.first).outcome {
                    changed = true
                    try FileManager.default.moveItem(atPath: item.path, toPath: item.path + "-old")
                    try Data("replacement".utf8).write(to: URL(fileURLWithPath: item.path))
                }
            })
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(report.summary.failedItemCount, 1)
        XCTAssertEqual(try String(contentsOfFile: item.path, encoding: .utf8), "replacement")
    }
}
