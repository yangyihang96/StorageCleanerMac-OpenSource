import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class RecentItemsCleanupTests: XCTestCase {
    func testNoConfirmationOrNoSelectionCausesNoMoveJournalProcessOrWait() async throws {
        let fixture = try RecentItemsTestFixture(self)
        try fixture.write()
        let unconfirmed = try await fixture.clean(confirmed: false)
        let unselected = try await fixture.clean([])
        XCTAssertNil(unconfirmed)
        XCTAssertNil(unselected)
        XCTAssertTrue(fixture.events.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.directory.path))
    }

    func testOnlySelectedWhitelistedFilesMoveAndKeepRestorableDurableReceipts() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let chosen = try fixture.write()
        let untouched = try fixture.write("com.apple.LSSharedFileList.RecentApplications.sfl3")
        let favorite = try fixture.write("com.apple.LSSharedFileList.FavoriteItems.sfl4")
        let snapshot = fixture.scanner.scan()
        let item = try XCTUnwrap(snapshot.lists.first { $0.url == chosen })
        let forbidden = RecentItemsList(url: favorite, category: .documents, bundleIdentifier: nil, entryCount: 2,
                                       file: try FoundationReadOnlyFileSystem().snapshot(at: favorite))
        let result = try await fixture.clean([item, forbidden, item])
        let outcome = try XCTUnwrap(result)
        XCTAssertEqual(outcome.report.items.map(\.sourcePath), [chosen.path])
        XCTAssertEqual(outcome.report.restorableReceipts.count, 1)
        XCTAssertNil(outcome.report.persistenceFailure)
        _ = try fixture.journal.readWithEvents(fixture.journal.directory.appendingPathComponent(outcome.report.planID.rawValue.uuidString + ".json"))
        XCTAssertEqual(try fixture.journal.load().first?.restorableReceipts, outcome.report.restorableReceipts)
        XCTAssertEqual(outcome.report.restoreAuthorizations?[chosen.path]?.allowedRootPath, fixture.scanner.rootURL.path)
        XCTAssertEqual(outcome.report.summary.permanentlyFreedBytes, 0)
        XCTAssertEqual(outcome.verification[chosen.path], .cleared)
        XCTAssertEqual(outcome.restart, .notRunning)
        XCTAssertEqual(fixture.events.values, ["move:\(chosen.lastPathComponent)", "processes", "wait"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: favorite.path))
    }

    func testOnlyIneligibleSelectionDoesNotEvenCreateAJournal() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let favorite = try fixture.write("com.apple.LSSharedFileList.FavoriteVolumes.sfl4")
        let forbidden = RecentItemsList(url: favorite, category: .documents, bundleIdentifier: nil, entryCount: nil,
                                       file: try FoundationReadOnlyFileSystem().snapshot(at: favorite))
        let result = try await fixture.clean([forbidden])
        XCTAssertNil(result)
        XCTAssertTrue(fixture.events.values.isEmpty)
    }

    func testChangedFileAndReplacedLinkAreNeverMovedOrSignaled() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let changed = try fixture.write()
        let replaced = try fixture.write("com.apple.LSSharedFileList.RecentApplications.sfl4")
        let selected = fixture.scanner.scan().lists
        try Data("changed after review".utf8).write(to: changed)
        try FileManager.default.moveItem(at: replaced, to: fixture.root.appendingPathComponent("old-file"))
        try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: changed)
        let result = try await fixture.clean(selected)
        let outcome = try XCTUnwrap(result)
        XCTAssertEqual(outcome.report.summary.movedItemCount, 0)
        XCTAssertTrue(outcome.verification.values.allSatisfy { $0 == .notMoved })
        XCTAssertNil(outcome.restart)
        XCTAssertTrue(fixture.events.values.isEmpty)
    }

    func testWritebackIsReadExactlyOnceAfterAllMovesAndIsNotRetried() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let rewritten = try fixture.write()
        let empty = try fixture.write("com.example.Editor.sfl3", app: true)
        let unknown = try fixture.write("com.apple.LSSharedFileList.RecentServers.sfl2")
        let emptyData = try RecentItemsTestFixture.archive(count: 0)
        let rewrittenData = try RecentItemsTestFixture.archive(count: 1)
        var environment = fixture.environment
        environment.waitForWriteback = {
            XCTAssertEqual(fixture.events.values.filter { $0.hasPrefix("move:") }.count, 3)
            fixture.events.append("wait")
            do {
                try emptyData.write(to: empty)
                try rewrittenData.write(to: rewritten)
                try Data("unknown-format".utf8).write(to: unknown)
            } catch { XCTFail("Fixture writeback: \(error)") }
        }
        let result = try await fixture.clean(environment: environment)
        let outcome = try XCTUnwrap(result)
        XCTAssertEqual(outcome.verification[rewritten.path], .writtenBack)
        XCTAssertEqual(outcome.verification[empty.path], .cleared)
        XCTAssertEqual(outcome.verification[unknown.path], .unknown)
        XCTAssertEqual(fixture.events.values.filter { $0 == "wait" }.count, 1)
        XCTAssertEqual(fixture.events.values.filter { $0 == "processes" }.count, 1)
        XCTAssertEqual(outcome.report.restorableReceipts.count, 3)
        XCTAssertEqual(outcome.snapshot.knownEntryCount, 1)
        XCTAssertEqual(outcome.snapshot.unknownListCount, 1)
    }

    func testMoveFailureHasNoRestartAndKeepsOriginal() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let original = try fixture.write()
        var environment = fixture.environment
        environment.moveToTrash = { _ in throw CocoaError(.fileWriteNoPermission) }
        let result = try await fixture.clean(environment: environment)
        let outcome = try XCTUnwrap(result)
        XCTAssertEqual(outcome.report.summary.failedItemCount, 1)
        XCTAssertEqual(outcome.verification[original.path], .notMoved)
        XCTAssertNil(outcome.restart)
        XCTAssertTrue(fixture.events.values.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testOperationHistoryRestoresReceiptsAndPreservesRecreatedLists() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let restorable = try fixture.write()
        let recreated = try fixture.write("com.apple.LSSharedFileList.RecentApplications.sfl3")
        let cleanup = try await fixture.clean()
        let outcome = try XCTUnwrap(cleanup)
        let newData = try RecentItemsTestFixture.archive(count: 1)
        try newData.write(to: recreated)
        let coordinator = HeavyWorkCoordinator()
        let restored = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: outcome.report, coordinator: coordinator, lease: lease,
                journal: fixture.journal, userHomeURL: fixture.root.appendingPathComponent("home"), trashURL: fixture.trash)
        }
        XCTAssertEqual(restored.recovery.restoredCount, 1)
        XCTAssertEqual(restored.recovery.items.filter { $0.outcome == .conflict }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restorable.path))
        XCTAssertEqual(try Data(contentsOf: recreated), newData)
        XCTAssertEqual(try fixture.journal.load().first?.recoveryAttempts?.count, 1)
    }

    func testDanglingParentLinkAfterMovesIsNotReportedAsVerifiedAbsence() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let original = try fixture.write()
        var environment = fixture.environment
        environment.waitForWriteback = {
            do {
                try FileManager.default.moveItem(at: fixture.scanner.rootURL, to: fixture.root.appendingPathComponent("old-lists"))
                try FileManager.default.createSymbolicLink(at: fixture.scanner.rootURL,
                    withDestinationURL: fixture.root.appendingPathComponent("missing-target"))
            } catch { XCTFail("Fixture parent replacement: \(error)") }
        }
        let result = try await fixture.clean(environment: environment)
        XCTAssertEqual(try XCTUnwrap(result).verification[original.path], .unknown)
    }

    func testJournalFailurePreventsMovesAndSignals() async throws {
        let fixture = try RecentItemsTestFixture(self)
        try fixture.write()
        let invalidDirectory = fixture.root.appendingPathComponent("journal-is-a-file")
        try Data("fixture".utf8).write(to: invalidDirectory)
        var environment = fixture.environment
        environment.journal = CleanupReportJournal(directory: invalidDirectory)
        let result = try await fixture.clean(environment: environment)
        let outcome = try XCTUnwrap(result)
        XCTAssertNotNil(outcome.report.persistenceFailure)
        XCTAssertEqual(outcome.report.summary.movedItemCount, 0)
        XCTAssertTrue(fixture.events.values.isEmpty)
    }

    func testCleanupSharesTheExistingExclusiveLease() async throws {
        let fixture = try RecentItemsTestFixture(self)
        try fixture.write()
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .restore)
        do {
            _ = try await RecentItemsCleanupService.clean(selected: fixture.scanner.scan().lists, confirmed: true,
                                                         environment: fixture.environment, coordinator: coordinator)
            XCTFail("Concurrent cleanup must be refused")
        } catch HeavyWorkCoordinator.Error.busy(activeOwner: .restore) {
            XCTAssertTrue(fixture.events.values.isEmpty)
        } catch { XCTFail("Unexpected error: \(error)") }
        await coordinator.release(lease)
    }

    func testProcessFilterAndPidRecheckOnlySignalCurrentUsersSharedfilelistd() {
        let events = RecentItemsTestEvents()
        let valid = RecentItemsProcessController.ProcessIdentity(pid: 42, userID: 501, name: "sharedfilelistd")
        let changed = RecentItemsProcessController.ProcessIdentity(pid: 43, userID: 501, name: "sharedfilelistd")
        let candidates: [RecentItemsProcessController.ProcessIdentity] = [valid, changed,
            .init(pid: 44, userID: 502, name: "sharedfilelistd"),
            .init(pid: 45, userID: 501, name: "Finder"),
            .init(pid: 46, userID: 501, name: "sharedfilelistd-helper"),
            .init(pid: 0, userID: 501, name: "sharedfilelistd"),
            .init(pid: -1, userID: 501, name: "sharedfilelistd")]
        let controller = RecentItemsProcessController(currentUserID: 501, processes: { candidates }, lookup: { pid in
            events.append("lookup:\(pid)")
            return pid == 42 ? valid : .init(pid: pid, userID: 501, name: "other")
        }, signal: { pid, signal in
            XCTAssertEqual(pid, 42); XCTAssertEqual(signal, SIGTERM)
            events.append("signal:\(pid)"); return 0
        })
        XCTAssertEqual(controller.restart(), .terminated(1))
        XCTAssertEqual(events.values, ["lookup:42", "signal:42", "lookup:43"])
    }

    func testNoMatchingProcessAndFailedSignalAreReportedWithoutRetry() {
        let valid = RecentItemsProcessController.ProcessIdentity(pid: 42, userID: 501, name: "sharedfilelistd")
        let none = RecentItemsProcessController(currentUserID: 501, processes: { [] }, lookup: { _ in valid },
                                               signal: { _, _ in XCTFail("No signal expected"); return 0 })
        XCTAssertEqual(none.restart(), .notRunning)
        let events = RecentItemsTestEvents()
        let failed = RecentItemsProcessController(currentUserID: 501, processes: { [valid] }, lookup: { _ in valid },
                                                 signal: { _, _ in events.append("signal"); return -1 })
        XCTAssertEqual(failed.restart(), .failed)
        XCTAssertEqual(events.values, ["signal"])
    }

    func testSignalHappensAfterTrashMovesAndBeforeSingleWaitAndReadback() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let original = try fixture.write()
        let process = RecentItemsProcessController.ProcessIdentity(pid: 42, userID: 501, name: "sharedfilelistd")
        var environment = fixture.environment
        environment.processController = .init(currentUserID: 501, processes: { [process] }, lookup: { _ in process },
            signal: { _, signal in
                XCTAssertEqual(signal, SIGTERM)
                XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
                fixture.events.append("signal"); return 0
            })
        let result = try await fixture.clean(environment: environment)
        XCTAssertEqual(try XCTUnwrap(result).restart, .terminated(1))
        XCTAssertEqual(fixture.events.values, ["move:\(original.lastPathComponent)", "signal", "wait"])
    }
}
