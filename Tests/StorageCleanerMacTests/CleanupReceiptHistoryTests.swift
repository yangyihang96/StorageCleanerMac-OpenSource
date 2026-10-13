import Foundation
import XCTest
@testable import StorageCleanerMac

/// Receipts after emptying the Trash. Fixtures live in temporary folders and
/// an isolated defaults suite only.
final class CleanupReceiptHistoryTests: XCTestCase {
    /// P2-2: an older app version decodes the legacy receipt cache as a whole
    /// and fails on outcomes it does not know (permanently deleted, deletion
    /// outcome unknown), then overwrites the cache. Such receipts stay in the
    /// journal only, so the cache keeps decoding for an older version.
    func testReceiptsWithPermanentDeletionsStayOutOfTheLegacyCache() throws {
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        addTeardownBlock { TestPreferenceDomain.cleanup(suiteName: suite) }
        let identity = FileIdentity(deviceID: 1, inode: 2, entryKind: .regularFile, creationTimeNanoseconds: 3)
        let moved = report(.moved(CleanupMoveReceipt(
            originalPath: "/Users/fixture/Library/Caches/a",
            resultingItemURL: URL(fileURLWithPath: "/Users/fixture/.Trash/a"),
            disposition: .trash,
            movedIdentity: identity,
            verification: .identityVerified,
            movedAt: Date()
        )))
        let deleted = report(.deleted(CleanupDeletionReceipt(
            originalPath: "/Users/fixture/.Trash/b",
            deletedIdentity: identity,
            deletedAt: Date()
        )))
        let unknown = report(.failed(CleanFailure(
            code: .deletionOutcomeUnknown,
            detailCode: "move-threw-needs-verification"
        )))

        XCTAssertTrue(CleanReportStore.record(moved, defaults: defaults))
        CleanReportStore.record(deleted, defaults: defaults)
        CleanReportStore.record(unknown, defaults: defaults)

        XCTAssertEqual(CleanReportStore.load(defaults: defaults).map(\.planID), [moved.planID])
        let cached = try XCTUnwrap(defaults.data(forKey: CleanReportStore.defaultsKey))
        let decoded = try JSONDecoder().decode([CleanReport].self, from: cached)
        XCTAssertEqual(decoded.map(\.planID), [moved.planID])
    }

    /// P2-6: once the Trash is emptied (here or in Finder), a receipt whose
    /// moved item is gone, or replaced by another item of the same name, no
    /// longer counts as restorable on the history page.
    func testReceiptsForItemsGoneFromTheTrashAreReportedAsDeparted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerReceiptHistory-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let reader = FoundationReadOnlyFileSystem()
        var items = [CleanItemOutcome]()
        for name in ["a.bin", "b.bin", "c.bin"] {
            let moved = trash.appendingPathComponent(name)
            try Data(repeating: 0x5A, count: 1_024).write(to: moved)
            items.append(.moved(CleanupMoveReceipt(
                originalPath: "/Users/fixture/Library/Caches/\(name)",
                resultingItemURL: moved,
                disposition: .trash,
                movedIdentity: try reader.snapshot(at: moved).identity,
                verification: .identityVerified,
                movedAt: Date()
            )))
        }
        let history = report(items)
        XCTAssertEqual(CleanupReceiptAvailability.departedOriginalPaths(in: history), [])

        try FileManager.default.removeItem(at: trash.appendingPathComponent("a.bin"))
        try FileManager.default.removeItem(at: trash.appendingPathComponent("b.bin"))
        try Data(repeating: 0x00, count: 16).write(to: trash.appendingPathComponent("b.bin"))

        XCTAssertEqual(
            CleanupReceiptAvailability.departedOriginalPaths(in: history),
            ["/Users/fixture/Library/Caches/a.bin", "/Users/fixture/Library/Caches/b.bin"]
        )
    }

    /// P2-6: the history page labels such receipts and stops offering a
    /// restore for them; the empty-Trash confirmation says so up front.
    func testHistoryAndConfirmationSayWhenItemsCanNoLongerBeRestored() throws {
        let history = try source("Sources/StorageCleanerMac/Views/ReversibleOperationsView.swift")
        XCTAssertTrue(history.contains("CleanupReceiptAvailability.departedOriginalPaths(in: report)"))
        XCTAssertTrue(history.contains("已不在废纸篓 · 无法在此恢复"))
        XCTAssertTrue(history.contains("allSatisfy { departed.contains($0.originalPath) }"))
        let confirmation = try source("Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift")
        XCTAssertTrue(confirmation.contains("无法再从“操作记录”恢复"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func report(_ outcome: CleanItemOutcome) -> CleanReport {
        report([outcome])
    }

    private func report(_ outcomes: [CleanItemOutcome]) -> CleanReport {
        let items = outcomes.map { outcome -> CleanReportItem in
            let path: String
            switch outcome {
            case let .moved(receipt): path = receipt.originalPath
            case let .deleted(receipt): path = receipt.originalPath
            default: path = "/Users/fixture/.Trash/item"
            }
            return CleanReportItem(
                id: UUID(),
                planItemID: UUID(),
                ruleID: "fixture.rule",
                sourcePath: path,
                estimatedBytes: 1_024,
                outcome: outcome
            )
        }
        return CleanReport(
            id: UUID(),
            planID: CleanPlanID(),
            sessionID: ScanSessionID(),
            rulesVersion: "fixture-rules",
            disposition: .trash,
            scanWasPartial: false,
            startedAt: Date(),
            completedAt: Date(),
            outcome: .completed,
            items: items,
            summary: CleanReportSummary(
                requestedItemCount: items.count,
                movedItemCount: 0,
                skippedItemCount: 0,
                failedItemCount: 0,
                notProcessedItemCount: 0,
                unverifiedMoveCount: 0,
                plannedBytes: 0,
                movedToRecoverableLocationBytes: 0,
                reclaimableAfterEmptyingTrashBytes: nil,
                permanentlyFreedBytes: 0,
                availableSpaceDeltaBytes: nil
            )
        )
    }
}
