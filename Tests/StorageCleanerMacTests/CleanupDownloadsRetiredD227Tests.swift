import Foundation
import XCTest
@testable import StorageCleanerMac

/// D227: the junk scan no longer reads Downloads — installers are under
/// Applications → Installers, the rest under My Clutter → Downloads. The
/// receipts the two retired rules wrote still list and restore, and their
/// items keep the group they had.
final class CleanupDownloadsRetiredD227Tests: XCTestCase {
    func testTheBundledRulesAndTheirBaselineNoLongerReadDownloads() throws {
        let rules = try CleanupRuleSetLoader.loadBundled()
        XCTAssertFalse(rules.rules.contains { $0.id.hasPrefix("downloads.") })
        XCTAssertFalse(rules.rules.contains { $0.categoryID == "downloads" || $0.root.path == "Downloads" })
        let baseline = try CleanupRuleTestFixtures.baseline()
        XCTAssertFalse(baseline.entries.contains { $0.ruleID.hasPrefix("downloads.") })
        XCTAssertFalse(baseline.legacyRules.contains { $0.id.hasPrefix("downloads.") })
        XCTAssertNoThrow(try CleanupRuleMaintenanceValidator.validate(rules, baseline: baseline))
    }

    func testReceiptsOfTheRetiredRulesStillListAndRestore() async throws {
        let root = TestFileSystem.uniqueOperationRoot("StorageCleanerD227Receipts")
        defer { TestFileSystem.remove(root) }
        let trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
        let reader = FoundationReadOnlyFileSystem()
        var reports: [CleanReport] = []
        for (ruleID, name) in [("downloads.installers", "Setup.dmg"), ("downloads.large-items", "Movie.mov")] {
            let url = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            let item = RecordedTrashOperation.Item(path: url.path, bytes: 1, identity: try reader.snapshot(at: url).identity)
            let target = trash, writer = journal
            reports.append(RecordedTrashOperation.run(items: [item], ruleID: ruleID, validate: { _ in }, move: { source in
                let destination = target.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            }, persist: { try writer.checkpoint($0, expectedIdentities: $1) }))
        }

        let listed = try journal.load()
        XCTAssertEqual(Set(listed.flatMap(\.items).map(\.ruleID)), ["downloads.installers", "downloads.large-items"])
        XCTAssertTrue(listed.allSatisfy { $0.restorableReceipts.count == 1 }, "Operation History still offers to restore them")
        for report in listed {
            XCTAssertFalse(OperationRecordPresentation.title(rulesVersion: report.rulesVersion, subject: nil).isEmpty)
        }
        XCTAssertEqual(CareJunkGroup.group(ruleID: "downloads.installers"), .filesToReview, "Old report items keep their group")
        XCTAssertEqual(CareJunkGroup.group(ruleID: "downloads.large-items"), .filesToReview)

        let coordinator = HeavyWorkCoordinator()
        for report in reports {
            let result = try await coordinator.withLease(owner: .restore) { lease in
                await CleanupRecoveryService().restore(report: report, coordinator: coordinator, lease: lease,
                                                       journal: journal, userHomeURL: root, trashURL: trash)
            }
            XCTAssertEqual(result.recovery.items.map(\.outcome), [.restored], report.items.first?.ruleID ?? "")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Setup.dmg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Movie.mov").path))
    }
}
