import Foundation
import XCTest
@testable import StorageCleanerMac

final class CleanupJournalEventTests: XCTestCase {
    func testTornTailRetainsSuccessfulReceiptsAndRefusesFurtherWrites() throws {
        let fixture = try RecordedCleanupRecoveryTests.Fixture()
        defer { fixture.remove() }
        let base = fixture.journal.reportURL(for: fixture.report.planID)
        let initial = try Data(contentsOf: base)
        let eventURL = CleanupJournalEvents.eventURL(for: base)
        let events = try Data(contentsOf: eventURL)
        let writer = try FileHandle(forWritingTo: eventURL)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data([0, 0, 1, 0, 0x7b]))
        try writer.close()
        let replay = try fixture.journal.readWithEvents(base)
        XCTAssertTrue(replay.damagedSuffix)
        XCTAssertEqual(replay.entry.report.restorableReceipts.count, 2)
        XCTAssertThrowsError(try fixture.journal.checkpoint(fixture.report, expectedIdentities: [:]))
        XCTAssertEqual(try Data(contentsOf: base), initial)
        XCTAssertEqual(try Data(contentsOf: eventURL).prefix(events.count), events)
        XCTAssertFalse(try fixture.journal.loadAvailable().unreadableEntries.isEmpty)
    }

    func testAppendDoesNotRewriteBaseAndConfirmedResultsCannotBeErased() throws {
        let fixture = try RecordedCleanupRecoveryTests.Fixture()
        defer { fixture.remove() }
        let base = fixture.journal.reportURL(for: fixture.report.planID)
        let initial = try Data(contentsOf: base)
        var updated = fixture.report
        updated.recoveryAttempts = [.init(completedAt: Date(), items: [.init(id: UUID(),
            originalPath: fixture.report.items[0].sourcePath, outcome: .restored)], attemptID: UUID())]
        try fixture.journal.checkpoint(updated, expectedIdentities: [:])
        XCTAssertEqual(try Data(contentsOf: base), initial)
        XCTAssertEqual(try fixture.journal.read(base).report.recoveryAttempts?.last?.restoredCount, 1)
        XCTAssertThrowsError(try fixture.journal.checkpoint(fixture.report, expectedIdentities: [:]))
        XCTAssertEqual(try fixture.journal.read(base).report.restorableReceipts.count, 1)
    }

    func testApplicationRestoreRequiresOriginalScopeAndIdentityNotVersionString() throws {
        let fixture = try RecordedCleanupRecoveryTests.Fixture()
        defer { fixture.remove() }
        let identity = FileIdentity(deviceID: 1, inode: 42, entryKind: .directory, creationTimeNanoseconds: 1)
        let path = "/Applications/Fixture.app", itemID = UUID()
        let receipt = CleanupMoveReceipt(originalPath: path, resultingItemURL: fixture.trash.appendingPathComponent("Fixture.app"),
            disposition: .trash, movedIdentity: identity, verification: .identityVerified, movedAt: Date())
        let item = CleanReportItem(id: UUID(), planItemID: itemID, ruleID: "approved.app", sourcePath: path,
            estimatedBytes: 1, outcome: .moved(receipt))
        let grant = CleanupRestoreAuthorization(sourcePath: path, allowedRootPath: "/Applications",
            sourceIdentity: identity, ruleID: item.ruleID, planItemID: itemID)
        XCTAssertTrue(grant.permitsApplication(item, receipt: receipt))
        for root in ["/", "/Applications/Other.app", "/Applications/../Applications"] {
            XCTAssertFalse(CleanupRestoreAuthorization(sourcePath: path, allowedRootPath: root,
                sourceIdentity: identity, ruleID: item.ruleID, planItemID: itemID).permitsApplication(item, receipt: receipt))
        }
        XCTAssertFalse(CleanupRestoreAuthorization(sourcePath: path, allowedRootPath: "/Applications",
            sourceIdentity: .init(deviceID: 1, inode: 99, entryKind: .directory, creationTimeNanoseconds: 1),
            ruleID: item.ruleID, planItemID: itemID).permitsApplication(item, receipt: receipt))
        XCTAssertTrue(fixture.report.authorizedApplicationRestorePaths.isEmpty)
    }

    func testSummaryPaginationRetainsEveryReportAndBoundsEachPage() throws {
        let fixture = try RecordedCleanupRecoveryTests.Fixture()
        defer { fixture.remove() }
        let original = fixture.report
        for _ in 0..<44 {
            let id = CleanPlanID()
            let report = CleanReport(id: id.rawValue, planID: id, sessionID: original.sessionID,
                rulesVersion: original.rulesVersion, disposition: original.disposition, scanWasPartial: false,
                startedAt: original.startedAt, completedAt: original.completedAt, outcome: original.outcome,
                items: original.items, summary: original.summary)
            try fixture.journal.checkpoint(report, expectedIdentities: [:])
        }
        var cursor: CleanupReportIndex.Cursor?
        var seen = Set<UUID>()
        repeat {
            let page = try fixture.journal.summaryPage(after: cursor, limit: 7)
            XCTAssertLessThanOrEqual(page.reports.count, 7)
            for row in page.reports { XCTAssertTrue(seen.insert(row.id).inserted) }
            cursor = page.next
        } while cursor != nil
        XCTAssertEqual(seen.count, 45)
    }

    func testZeroSuccessNeverUsesCompletedRecoveryMessage() {
        for outcome in [CleanupRecoveryItemOutcome.notProcessed, .failed, .conflict, .outcomeUnknown] {
            let report = CleanupRecoveryReport(completedAt: Date(), items: [.init(id: UUID(), originalPath: "/fixture", outcome: outcome)])
            XCTAssertEqual(report.restoredCount, 0)
            XCTAssertFalse(report.resultMessage.hasPrefix("已恢复"))
            XCTAssertFalse(report.resultMessage.hasPrefix("Restored"))
        }
    }
}
