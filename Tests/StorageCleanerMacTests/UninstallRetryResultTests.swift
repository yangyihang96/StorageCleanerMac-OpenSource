import Foundation
import XCTest
@testable import StorageCleanerMac

/// Batch 3a: "Retry unfinished" no longer replaces the original result. It is
/// offered only after the application moved or was refused in place, the
/// review merges every receipt by path (latest row wins), and restore covers
/// the original receipt and every retry receipt.
final class UninstallRetryResultTests: XCTestCase {
    private let app = "/Applications/Fixture.app"
    private let data = "/Users/fixture/Library/Application Support/org.fixture.app"
    private let cache = "/Users/fixture/Library/Caches/org.fixture.app"

    private let refused = CleanItemOutcome.failed(CleanFailure(code: .trashMoveRejected, detailCode: "NSCocoaErrorDomain:513"))
    private let unknown = CleanItemOutcome.failed(CleanFailure(code: .moveOutcomeUnknown, detailCode: "move-in-flight"))

    private func moved(_ path: String, verified: Bool = true) -> CleanItemOutcome {
        .moved(CleanupMoveReceipt(originalPath: path,
            resultingItemURL: URL(fileURLWithPath: "/Users/fixture/.Trash/" + UUID().uuidString),
            disposition: .trash,
            movedIdentity: FileIdentity(deviceID: 1, inode: UInt64.random(in: 1...UInt64(Int64.max)),
                                        entryKind: .directory, creationTimeNanoseconds: 1),
            verification: verified ? .identityVerified : .identityMismatch, movedAt: Date()))
    }

    private func report(_ rows: [(String, CleanItemOutcome)], persistenceFailure: String? = nil,
                        recovered: [String] = []) -> CleanReport {
        let items = rows.map { CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "uninstall.selection.v1",
                                               sourcePath: $0.0, estimatedBytes: 10, outcome: $0.1) }
        let attempts = recovered.isEmpty ? nil : [CleanupRecoveryReport(completedAt: Date(), items: recovered.map {
            CleanupRecoveryItem(id: UUID(), originalPath: $0, outcome: .restored)
        })]
        return CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: ScanSessionID(),
            rulesVersion: "uninstall.selection.v1", disposition: .trash, scanWasPartial: false,
            startedAt: Date(), completedAt: Date(), outcome: .partiallyCompleted, items: items,
            summary: CleanReportSummary(requestedItemCount: items.count, movedItemCount: 0, skippedItemCount: 0,
                failedItemCount: 0, notProcessedItemCount: 0, unverifiedMoveCount: 0, plannedBytes: 0,
                movedToRecoverableLocationBytes: 0, reclaimableAfterEmptyingTrashBytes: 0,
                permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil),
            persistenceFailure: persistenceFailure, recoveryAttempts: attempts)
    }

    private func canRetry(_ report: CleanReport, alreadyMoved: Bool = false) -> Bool {
        AppUninstallService.canRetryUninstall(report, applicationPath: app, applicationAlreadyMoved: alreadyMoved)
    }

    func testRetryIsOfferedOnlyAfterTheApplicationMovedOrWasRefusedInPlace() {
        XCTAssertTrue(canRetry(report([(app, moved(app)), (data, refused)])))
        XCTAssertTrue(canRetry(report([(app, moved(app)), (data, .notProcessed)])))
        XCTAssertTrue(canRetry(report([(app, refused), (data, .notProcessed)])))
        XCTAssertTrue(canRetry(report([(app, refused)])))
        // An unknown or unrun application move is never retried around.
        XCTAssertFalse(canRetry(report([(app, unknown), (data, .notProcessed)])))
        XCTAssertFalse(canRetry(report([(app, .notProcessed), (data, .notProcessed)])))
        // Moved but not verifiable, already restored, or receipt not saved.
        XCTAssertFalse(canRetry(report([(app, moved(app, verified: false)), (data, refused)])))
        XCTAssertFalse(canRetry(report([(app, moved(app)), (data, refused)], recovered: [app])))
        XCTAssertFalse(canRetry(report([(app, moved(app)), (data, refused)], persistenceFailure: "result-write-failed")))
        // Nothing left that provably did not move.
        XCTAssertFalse(canRetry(report([(app, moved(app)), (data, moved(data))])))
        XCTAssertFalse(canRetry(report([(app, moved(app)), (data, unknown)])))
        // Leftover cleanup: the application moved in an earlier receipt.
        XCTAssertTrue(canRetry(report([(data, refused)]), alreadyMoved: true))
        XCTAssertFalse(canRetry(report([(data, refused)]), alreadyMoved: false))
    }

    func testRetryResultIsMergedByPathAndNeverShowsEarlierMovesAsKept() throws {
        let original = report([(app, moved(app)), (data, refused), (cache, .notProcessed)])
        let retry = report([(data, moved(data)), (cache, refused)])
        let review = try XCTUnwrap(UninstallReviewResult(receipts: [original, retry]))
        let merged = review.display

        XCTAssertEqual(merged.items.map(\.sourcePath), [app, data, cache])
        XCTAssertEqual(merged.items.map(\.outcome), [original.items[0].outcome, retry.items[0].outcome, refused])
        XCTAssertEqual(merged.summary.movedItemCount, 2)
        XCTAssertEqual(merged.summary.failedItemCount, 1)
        XCTAssertEqual(merged.summary.notProcessedItemCount, 0)
        XCTAssertEqual(merged.summary.movedToRecoverableLocationBytes, 20)
        XCTAssertEqual(merged.outcome, .partiallyCompleted)
        // The display is not a receipt: its own identity and a rules marker.
        XCTAssertEqual(review.receipts, [original, retry])
        XCTAssertEqual(merged.rulesVersion, UninstallReviewResult.displayRulesVersion)
        XCTAssertFalse([original.id, retry.id].contains(merged.id))
        XCTAssertFalse([original.planID, retry.planID].contains(merged.planID))
        XCTAssertFalse(AppUninstallService.canInspectResiduals(merged), "Leftover checks need a real receipt")
        XCTAssertEqual(Set(merged.restorableReceipts.map(\.originalPath)), [app, data])
        let presentation = OperationResultPresentation(report: merged)
        XCTAssertEqual(presentation.movedCount, 2)
        XCTAssertEqual(presentation.failedCount, 1)
        XCTAssertEqual(presentation.state, .partial)
        XCTAssertTrue(canRetry(merged), "The application moved and the cache was refused in place")

        // Showing only the retry receipt (the old behavior) made the first run's
        // moved data look "not selected, kept"; the merged review does not.
        let preferences = "/Users/fixture/Library/Preferences/org.fixture.app.plist"
        let related = [data, cache, preferences].map { InstalledAppRelatedItem(path: $0, sizeBytes: 1) }
        let item = InstalledAppItem(id: app, name: "Fixture", bundleIdentifier: "org.fixture.app", path: app,
            version: "1", build: "1", category: "", appDescription: "", sizeBytes: 10, source: "fixture",
            modifiedAt: nil, relatedPaths: related.map(\.path), relatedItems: related, status: .installed)
        let firstRun = report([(app, moved(app)), (data, moved(data)), (cache, refused)])
        let cacheRetry = report([(cache, moved(cache))])
        XCTAssertEqual(UninstallPresentation.retainedItems(item, report: cacheRetry).map(\.path), [data, preferences])
        let mergedRun = try XCTUnwrap(UninstallReviewResult(receipts: [firstRun, cacheRetry])?.display)
        XCTAssertEqual(UninstallPresentation.retainedItems(item, report: mergedRun).map(\.path), [preferences])
        XCTAssertEqual(UninstallPresentation.retainedItems(item, report: merged).map(\.path), [preferences])

        let finished = try XCTUnwrap(UninstallReviewResult(
            receipts: [original, retry, report([(cache, moved(cache))])])?.display)
        XCTAssertEqual(finished.outcome, .completed)
        XCTAssertEqual(finished.summary.movedItemCount, 3)
        XCTAssertFalse(canRetry(finished))
    }

    func testRunningRetryIsDisplayedButOnlySavedReceiptsAreRestorable() throws {
        let original = report([(app, moved(app)), (data, refused)])
        let running = report([(data, unknown)])
        let review = try XCTUnwrap(UninstallReviewResult(receipts: [original], inFlight: running))
        XCTAssertEqual(review.receipts, [original], "The running receipt is not saved yet")
        XCTAssertEqual(review.display.items.map(\.outcome), [original.items[0].outcome, unknown])
        XCTAssertEqual(review.residualReceipt, original)
        XCTAssertNil(UninstallReviewResult(receipts: [], inFlight: nil))
        XCTAssertEqual(UninstallReviewResult(receipts: [], inFlight: running)?.receipts, [])
        XCTAssertEqual(UninstallReviewResult(receipts: [], inFlight: running)?.canRestore, false)
    }

    func testSingleReportIsShownAsIsAndRestoreEvidenceIsMerged() throws {
        let original = report([(app, moved(app)), (data, refused)])
        XCTAssertNil(UninstallReviewResult(receipts: []))
        let single = try XCTUnwrap(UninstallReviewResult(receipts: [original]))
        XCTAssertEqual(single.receipts, [original])
        XCTAssertEqual(single.display.items, original.items)
        XCTAssertTrue(single.canRestore)

        let retry = report([(data, moved(data))], recovered: [data])
        let merged = try XCTUnwrap(UninstallReviewResult(receipts: [original, retry])?.display)
        XCTAssertEqual(merged.recoveryAttempts?.count, 1)
        XCTAssertEqual(merged.restorableReceipts.map(\.originalPath), [app], "A restored row is no longer restorable")
        let presentation = OperationResultPresentation(report: merged)
        XCTAssertEqual(presentation.restoredCount, 1)
        XCTAssertEqual(presentation.state, .partiallyRestored)

        let unsaved = try XCTUnwrap(UninstallReviewResult(
            receipts: [original, report([(data, moved(data))], persistenceFailure: "final-write-failed")])?.display)
        XCTAssertEqual(unsaved.persistenceFailure, "final-write-failed")
        XCTAssertFalse(canRetry(unsaved))
    }
}

// MARK: - Fixture receipts: restore covers the original run and the retry

extension UninstallRetryResultTests {
    func testRestoreCoversTheOriginalAndTheRetryReceipts() async throws {
        let fm = FileManager.default
        let root = TestFileSystem.uniqueOperationRoot("SCM-UninstallRetry")
        defer { TestFileSystem.remove(root) }
        let trash = root.appendingPathComponent("fixture-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
        let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let dataURL = root.appendingPathComponent("Fixture-data")
        try Data("data".utf8).write(to: dataURL)
        let reader = FoundationReadOnlyFileSystem()
        func item(_ url: URL) throws -> RecordedTrashOperation.Item {
            .init(path: url.path, bytes: 4, identity: try reader.snapshot(at: url).identity,
                  allowedRestoreRoot: url.deletingLastPathComponent())
        }
        let appItem = try item(appURL), dataItem = try item(dataURL)
        func intoTrash(_ source: URL) throws -> URL {
            let target = trash.appendingPathComponent(source.lastPathComponent)
            try fm.moveItem(at: source, to: target)
            return target
        }

        // First run: the application moves; its data is refused in place.
        let original = RecordedTrashOperation.run(items: [appItem, dataItem], ruleID: "uninstall.selection.v1",
            validate: { _ in }, move: { source in
                if source.path == dataURL.path { throw CocoaError(.fileWriteNoPermission) }
                return try intoTrash(source)
            }, persist: { try journal.checkpoint($0, expectedIdentities: $1) })
        XCTAssertTrue(AppUninstallService.canRetryUninstall(original, applicationPath: appURL.path,
                                                           applicationAlreadyMoved: false))
        // Retry: only the refused row runs and gets its own receipt.
        let retry = RecordedTrashOperation.run(items: [dataItem], ruleID: "uninstall.selection.v1",
            validate: { _ in }, move: intoTrash, persist: { try journal.checkpoint($0, expectedIdentities: $1) })
        let merged = try XCTUnwrap(UninstallReviewResult(receipts: [original, retry])?.display)
        XCTAssertEqual(Set(merged.restorableReceipts.map(\.originalPath)), [appURL.path, dataURL.path])
        XCTAssertNotEqual(original.planID, retry.planID, "The retry never overwrites the original receipt")

        let coordinator = HeavyWorkCoordinator()
        let results = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(reports: [original, retry], coordinator: coordinator,
                                                   lease: lease, journal: journal, userHomeURL: root, trashURL: trash)
        }
        XCTAssertEqual(results.map(\.report.id), [original.id, retry.id])
        XCTAssertEqual(results.map(\.recovery.restoredCount), [1, 1])
        XCTAssertTrue(fm.fileExists(atPath: appURL.path))
        XCTAssertEqual(try String(contentsOf: dataURL, encoding: .utf8), "data")
        let restored = try XCTUnwrap(UninstallReviewResult(receipts: results.map(\.report))?.display)
        let presentation = OperationResultPresentation(report: restored)
        XCTAssertEqual(presentation.state, .restored)
        XCTAssertEqual(presentation.restoredCount, 2)
        for report in [original, retry] {
            XCTAssertEqual(try journal.read(planID: report.planID).recoveryAttempts?.last?.restoredCount, 1)
        }
    }
}

// MARK: - Failure reasons decide the wording and whether a retry can help

extension UninstallRetryResultTests {
    private func rejected(_ error: Error) -> CleanFailure {
        CleanFailure(code: .trashMoveRejected, detailCode: UninstallErrorEvidence.codes(error))
    }

    func testRecordedRefusalsAreToldApartByTheirDiagnosticCodes() {
        let native = CocoaError(.fileWriteNoPermission)
        let cases: [(Error, UninstallFailureReason)] = [
            (AppUninstallError.identityChanged("/x"), .changedSinceScan),
            (AppUninstallError.moveNotVerified("/x"), .applicationNotConfirmed),
            (AppUninstallError.missingApp("/x"), .missing),
            (CleanupFileSystemError.vanished, .missing),
            (HeavyWorkCoordinator.Error.invalidLease(expectedOwner: .cleanup), .interrupted),
            (native, .refused),
            (POSIXError(.EACCES), .refused),
            (UninstallAuthorizationFailure.wrap(AuthorizedMoveError.approvalRequired, nativeError: native), .authorizationIncomplete),
            (UninstallAuthorizationFailure.wrap(CancellationError(), nativeError: native), .authorizationIncomplete),
            (UninstallAuthorizationFailure.wrap(AuthorizedMoveError.unavailable, nativeError: native), .helperUnavailable),
            (NSError(domain: "Fixture.Unknown", code: 5), .other)
        ]
        for (error, reason) in cases {
            XCTAssertEqual(UninstallFailureReason(rejected(error)), reason, UninstallErrorEvidence.codes(error))
        }
        // Only refusals in place carry a reason; unknown outcomes never do.
        XCTAssertNil(UninstallFailureReason(CleanFailure(code: .moveOutcomeUnknown, detailCode: "NSCocoaErrorDomain:513")))
        XCTAssertEqual(UninstallFailureReason(CleanFailure(code: .trashMoveRejected, detailCode: nil)), .other)
    }

    func testRetryIsHiddenWhenEveryUnfinishedRowWouldFailTheSameWay() {
        let changed = CleanItemOutcome.failed(rejected(AppUninstallError.identityChanged("/x")))
        let location = CleanItemOutcome.failed(rejected(UninstallAuthorizationDecision.unsupportedLocation
            .notOfferedError(wrapping: CocoaError(.fileWriteNoPermission))!))
        let systemRefused = CleanItemOutcome.failed(rejected(UninstallAuthorizationDecision.systemRefused
            .notOfferedError(wrapping: CocoaError(.fileWriteNoPermission))!))
        let locked = CleanItemOutcome.failed(rejected(UninstallAuthorizationDecision.locked
            .notOfferedError(wrapping: CocoaError(.fileWriteNoPermission))!))
        // The application itself: a retry can help after allowing it or unlocking it, not for a nested path.
        XCTAssertTrue(canRetry(report([(app, systemRefused)])))
        XCTAssertTrue(canRetry(report([(app, locked)])))
        XCTAssertFalse(canRetry(report([(app, location)])))
        XCTAssertFalse(canRetry(report([(app, changed), (data, .notProcessed)])))
        // Related rows: only a change since the scan is left, so nothing to retry.
        XCTAssertFalse(canRetry(report([(app, moved(app)), (data, changed)])))
        XCTAssertTrue(canRetry(report([(app, moved(app)), (data, changed), (cache, refused)])))
    }

    func testPreMoveCheckFailureIsRecordedUnchangedButReportedForWhatItIs() throws {
        let fm = FileManager.default
        let root = TestFileSystem.uniqueOperationRoot("SCM-UninstallReason")
        defer { TestFileSystem.remove(root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("A")
        try Data("a".utf8).write(to: file)
        let item = RecordedTrashOperation.Item(path: file.path, bytes: 1,
            identity: try FoundationReadOnlyFileSystem().snapshot(at: file).identity)
        let report = RecordedTrashOperation.run(items: [item], ruleID: "uninstall.selection.v1",
            validate: { _ in throw AppUninstallError.identityChanged(file.path) },
            move: { _ in XCTFail("A failed check never reaches the move"); throw CocoaError(.fileWriteUnknown) },
            persist: { _, _ in })
        guard case .failed(let failure) = try XCTUnwrap(report.items.first).outcome else {
            return XCTFail("Expected a recorded refusal")
        }
        // The log still records it as before; only the wording and retry offer differ.
        XCTAssertEqual(failure.code, .trashMoveRejected)
        XCTAssertEqual(UninstallFailureReason(failure), .changedSinceScan)
        XCTAssertFalse(UninstallFailureReason(failure)?.retryMayHelp ?? true)
        XCTAssertNotEqual(UninstallPresentation.recordLabel(.changedSinceScan),
                          CleanFailurePresentation.title(failure))
    }
}
