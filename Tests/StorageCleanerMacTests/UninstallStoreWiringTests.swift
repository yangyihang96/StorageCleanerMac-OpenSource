import Foundation
import XCTest
@testable import StorageCleanerMac

/// Batch 3a review follow-up: the ScanStore side of uninstall, retry and
/// restore, run through the injected receipt journal, Trash and movers.
/// Fixtures only: nothing touches the real journal, the user's Trash or the
/// privileged helper.
@MainActor
final class UninstallStoreWiringTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let trash: URL
        let journal: CleanupReportJournal
        let app: InstalledAppItem

        init() throws {
            let fm = FileManager.default
            root = TestFileSystem.uniqueOperationRoot("SCM-UninstallStore")
            trash = root.appendingPathComponent("fixture-trash")
            journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
            do {
                try fm.createDirectory(at: trash, withIntermediateDirectories: true)
                let url = root.appendingPathComponent("Fixture.app", isDirectory: true)
                let contents = url.appendingPathComponent("Contents", isDirectory: true)
                try fm.createDirectory(at: contents, withIntermediateDirectories: true)
                let bundleID = "org.storagecleaner.fixture." + UUID().uuidString.lowercased()
                let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "Fixture",
                                           "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                app = InstalledAppItem(id: url.path, name: "Fixture", bundleIdentifier: bundleID, path: url.path,
                    version: "1.0", build: "1", category: "", appDescription: "", sizeBytes: 0, source: "fixture",
                    modifiedAt: nil, scanIdentity: AppUninstallService.uninstallFileIdentity(at: url.path),
                    relatedPaths: [], relatedItems: [], status: .installed)
            } catch {
                TestFileSystem.remove(root)
                throw error
            }
        }

        func remove() { TestFileSystem.remove(root) }
    }

    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = false
        func pass() async {
            entered = true
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    /// The first move is refused with a lone Cocoa 513 on writable folders
    /// (no password: the decision is "system refused"); later moves go into
    /// the fixture Trash, optionally after passing a gate.
    final class Recycler: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let trash: URL
        let gate: Gate?
        init(trash: URL, gate: Gate? = nil) { self.trash = trash; self.gate = gate }
        func recycle(_ source: URL) async throws -> URL {
            let call = lock.withLock { calls += 1; return calls }
            if call == 1 { throw CocoaError(.fileWriteNoPermission) }
            if let gate { await gate.pass() }
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
    }

    private func makeStore(_ fixture: Fixture, recycler: Recycler) throws -> ScanStore {
        let moves = UninstallMoveEnvironment(recycle: { try await recycler.recycle($0) },
            authorization: UninstallAuthorizationEnvironment(helperVerdict: { _, _, _ in .accepts },
                isWritable: { _ in true }, protection: { _ in .none },
                move: { _, _, _, _ in
                    XCTFail("Store tests never reach the privileged helper")
                    throw POSIXError(.EPERM)
                }))
        TestFileSystem.registerOwnership(of: fixture.root, for: self)
        let store = try ScanStore.makeForTests(for: self, cleanupUserHomeURL: fixture.root, cleanupRecoveryService: CleanupRecoveryService(), cleanReportLoader: { [] }, interruptedOperationReconciler: { [] },
                              operationJournal: fixture.journal, operationTrashURL: fixture.trash,
                              uninstallMoves: moves)
        store.installedApps = [fixture.app]
        return store
    }

    private struct Timeout: Error {}

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting until \(what)")
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Selects the fixture and runs the first, refused uninstall.
    private func refusedFirstRun(_ store: ScanStore, _ fixture: Fixture) async throws {
        store.requestUninstall(fixture.app)
        try await waitUntil("the review is prepared") { !store.isPreparingUninstall && store.pendingUninstallApp != nil }
        XCTAssertTrue(store.uninstallSelectedPaths.isEmpty, "D1: only the application itself")
        store.confirmUninstall(selectedPaths: [])
        try await waitUntil("the first run ends") { !store.isUninstallingApp && store.uninstallResult != nil }
        let result = try XCTUnwrap(store.uninstallResult)
        XCTAssertEqual(result.receipts.count, 1)
        guard case .failed(let failure) = try XCTUnwrap(result.display.items.first).outcome else {
            return XCTFail("The first run must leave the application refused in place")
        }
        XCTAssertEqual(UninstallFailureReason(failure), .systemRefused)
        XCTAssertTrue(store.canRetryUninstall)
        XCTAssertNil(store.completedUninstallApplication)
        XCTAssertEqual(try fixture.journal.load().count, 1, "Receipts go to the injected journal")
    }

    func testRetryShowsProgressThenAppendsItsReceiptAndRestoreCoversTheReview() async throws {
        let fixture = try Fixture()
        addTeardownBlock { fixture.remove() }
        let gate = Gate()
        let store = try makeStore(fixture, recycler: Recycler(trash: fixture.trash, gate: gate))
        addTeardownBlock { @MainActor [weak store] in
            await gate.open()
            await store?.waitForOperationReportTasksForTesting(cancelPending: true)
        }
        try await refusedFirstRun(store, fixture)

        store.confirmUninstall(retrying: true)
        var polls = 0
        while !(await gate.entered), polls < 1500 { try await Task.sleep(for: .milliseconds(10)); polls += 1 }
        let entered = await gate.entered
        XCTAssertTrue(entered, "The retry reached the move")
        // While it runs: progress only, never a result.
        XCTAssertTrue(store.isUninstallingApp)
        XCTAssertNil(store.uninstallResult)
        XCTAssertEqual(store.uninstallProgress?.receipts.count, 1)
        XCTAssertFalse(store.canRetryUninstall)
        await gate.open()
        try await waitUntil("the retry ends") { !store.isUninstallingApp && store.uninstallResult != nil }

        let review = try XCTUnwrap(store.uninstallResult)
        XCTAssertEqual(review.receipts.count, 2)
        XCTAssertEqual(review.display.restorableReceipts.map(\.originalPath), [fixture.app.path])
        XCTAssertFalse(store.canRetryUninstall, "Nothing unfinished is left")
        XCTAssertEqual(store.completedUninstallApplication?.originalPath, fixture.app.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.path))
        XCTAssertFalse(store.installedApps.contains { $0.id == fixture.app.id })
        XCTAssertEqual(try fixture.journal.load().count, 2)

        store.restoreUninstallResult()
        try await waitUntil("the restore ends") {
            !store.isRestoringRecordedOperation && store.operationRecoveryResult != nil
        }
        await store.waitForOperationReportTasksForTesting()
        XCTAssertFalse(store.isLoadingOperationReports)
        XCTAssertEqual(store.operationRecoveryResult?.restoredCount, 1)
        XCTAssertEqual(try FoundationReadOnlyFileSystem().snapshot(at: URL(fileURLWithPath: fixture.app.path)).identity,
                       fixture.app.scanIdentity)
        let restored = try XCTUnwrap(store.uninstallResult)
        XCTAssertEqual(OperationResultPresentation(report: restored.display).state, .restored)
        XCTAssertNil(store.completedUninstallApplication, "A restored app no longer counts as moved")
        XCTAssertFalse(store.canRetryUninstall)
    }

    func testRestoreFromOperationHistoryUpdatesTheReviewButNeverDuringARun() async throws {
        let fixture = try Fixture()
        addTeardownBlock { fixture.remove() }
        let store = try makeStore(fixture, recycler: Recycler(trash: fixture.trash))
        try await refusedFirstRun(store, fixture)
        store.confirmUninstall(retrying: true)
        try await waitUntil("the retry ends") { !store.isUninstallingApp && store.uninstallResult?.receipts.count == 2 }
        let before = try XCTUnwrap(store.uninstallResult)
        let retryReceipt = try XCTUnwrap(store.uninstallResultReports.dropFirst().first)

        // As if an uninstall run were still in progress when the restore lands:
        // only the progress may change; the result waits for the run to end.
        store.isUninstallingApp = true
        store.restoreRecordedOperation(retryReceipt)
        try await waitUntil("the restore ends") {
            !store.isRestoringRecordedOperation && store.operationRecoveryResult != nil
        }
        await store.waitForOperationReportTasksForTesting()
        XCTAssertFalse(store.isLoadingOperationReports)
        let restoredReceipt = try XCTUnwrap(store.uninstallResultReports.dropFirst().first)
        XCTAssertEqual(restoredReceipt.recoveryAttempts?.last?.restoredCount, 1)
        XCTAssertEqual(store.uninstallResult, before, "No result is published during a run")
        XCTAssertEqual(store.uninstallProgress.map { OperationResultPresentation(report: $0.display).state }, .restored)
        store.isUninstallingApp = false

        // A second restore from the records page is a no-op on the same evidence.
        store.restoreRecordedOperation(restoredReceipt)
        XCTAssertFalse(store.isRestoringRecordedOperation, "Nothing left to restore")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
        XCTAssertNil(store.completedUninstallApplication)
    }
}
