import Foundation
import XCTest
@testable import StorageCleanerMac

/// The old "Restore latest cleanup" history and the receipt journal describe
/// the same moves. Restores must go through the journal and keep both in step.
final class LegacyCleanupRestoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let trash: URL
        let journal: CleanupReportJournal

        init() throws {
            root = TestFileSystem.uniqueOperationRoot("StorageCleanerLegacyRestoreFixture")
            trash = root.appendingPathComponent("trash")
            journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
            do {
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            } catch {
                TestFileSystem.remove(root)
                throw error
            }
        }

        func moveToTrash(_ name: String, contents: String? = nil) throws -> CleanReport {
            let url = root.appendingPathComponent(name)
            try Data((contents ?? name).utf8).write(to: url)
            let identity = try FoundationReadOnlyFileSystem().snapshot(at: url).identity
            let target = trash, writer = journal
            return RecordedTrashOperation.run(
                items: [.init(path: url.path, bytes: Int64((contents ?? name).utf8.count), identity: identity)],
                ruleID: "cleanup.legacy-paths.v1", validate: { _ in }, move: { source in
                    let destination = target.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.moveItem(at: source, to: destination)
                    return destination
                }, persist: { try writer.checkpoint($0, expectedIdentities: $1) })
        }

        /// One legacy batch covering several names, with fresh contents each time.
        func clean(_ names: [String]) throws -> CleanReport {
            let reader = FoundationReadOnlyFileSystem()
            let items = try names.map { name -> RecordedTrashOperation.Item in
                let url = root.appendingPathComponent(name)
                try Data((name + UUID().uuidString).utf8).write(to: url)
                return .init(path: url.path, bytes: 1, identity: try reader.snapshot(at: url).identity)
            }
            let target = trash, writer = journal
            return RecordedTrashOperation.run(items: items, ruleID: LegacyCleanupRestore.legacyRulesVersion,
                validate: { _ in }, move: { source in
                    let destination = target.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.moveItem(at: source, to: destination)
                    return destination
                }, persist: { try writer.checkpoint($0, expectedIdentities: $1) })
        }

        func remove() { TestFileSystem.remove(root) }
    }

    // Review finding (P0): the Trash reuses a name once the earlier entry is
    // gone, so a newer cleanup can share an old record's path and Trash name.
    func testOldRecordNeverBindsToANewerCleanupOfTheSamePath() async throws {
        let f = try Fixture(); defer { f.remove() }
        let old = try f.clean(["A"])
        let oldRecords = old.legacyTrashRecords
        try FileManager.default.removeItem(at: f.trash.appendingPathComponent("A")) // Trash emptied
        let newer = try f.clean(["A", "B"])

        let plan = LegacyCleanupRestore.plan(for: oldRecords, reports: [newer])
        XCTAssertTrue(plan.matches.isEmpty, "A different file must not select the newer receipt")
        XCTAssertEqual(plan.unmatched.map(\.id), oldRecords.map(\.id), "It falls back to the identity-checked legacy path")
        XCTAssertEqual(newer.restorableReceipts.count, 2)
    }

    func testLatestRecordBindsToItsOwnReceiptWhateverTheReportOrder() throws {
        let f = try Fixture(); defer { f.remove() }
        let old = try f.clean(["A"])
        try FileManager.default.removeItem(at: f.trash.appendingPathComponent("A"))
        let newer = try f.clean(["A"])
        let latest = newer.legacyTrashRecords
        XCTAssertEqual(LegacyCleanupRestore.plan(for: latest, reports: [old, newer]).matches.map(\.report.planID),
                       [newer.planID])
        XCTAssertEqual(LegacyCleanupRestore.plan(for: latest, reports: [newer, old]).matches.map(\.report.planID),
                       [newer.planID])
    }

    func testRestoringOneRecordLeavesTheRestOfItsBatchInTrash() async throws {
        let f = try Fixture(); defer { f.remove() }
        let batch = try f.clean(["A", "B"])
        let onlyA = batch.legacyTrashRecords.filter { $0.originalPath.hasSuffix("/A") }
        let record = try XCTUnwrap(onlyA.first)
        let plan = LegacyCleanupRestore.plan(for: onlyA, reports: try f.journal.load())
        XCTAssertEqual(plan.matches.first?.originalPaths, [PathSafety.lexicalPath(record.originalPath)])
        let match = try XCTUnwrap(plan.matches.first)

        let coordinator = HeavyWorkCoordinator()
        let recovery = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: match.report, coordinator: coordinator,
                lease: lease, journal: f.journal, userHomeURL: f.root, trashURL: f.trash,
                onlyOriginalPaths: match.originalPaths).recovery
        }
        XCTAssertEqual(recovery.items.map { URL(fileURLWithPath: $0.originalPath).lastPathComponent }, ["A"])
        XCTAssertEqual(LegacyCleanupRestore.summary(records: onlyA, plan: plan, recoveries: [recovery],
                                                    legacy: nil).restoredCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.trash.appendingPathComponent("B").path))
        XCTAssertEqual(try f.journal.load().first?.restorableReceipts.map {
            URL(fileURLWithPath: $0.originalPath).lastPathComponent }, ["B"])
    }

    func testRecordsWithJournalReceiptsRestoreThroughTheJournalOnlyOnce() async throws {
        let f = try Fixture(); defer { f.remove() }
        let report = try f.moveToTrash("A")
        let records = report.legacyTrashRecords
        XCTAssertEqual(records.count, 1)

        let plan = LegacyCleanupRestore.plan(for: records, reports: try f.journal.load())
        XCTAssertEqual(plan.matches.map(\.report.planID), [report.planID])
        XCTAssertTrue(plan.unmatched.isEmpty)
        let match = try XCTUnwrap(plan.matches.first)

        let coordinator = HeavyWorkCoordinator()
        let recovery = try await coordinator.withLease(owner: .restore) { lease in
            await CleanupRecoveryService().restore(report: match.report, coordinator: coordinator,
                lease: lease, journal: f.journal, userHomeURL: f.root, trashURL: f.trash,
                onlyOriginalPaths: match.originalPaths).recovery
        }
        let summary = LegacyCleanupRestore.summary(records: records, plan: plan, recoveries: [recovery], legacy: nil)
        XCTAssertEqual(summary.restored.map(\.id), records.map(\.id))
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("A"), encoding: .utf8), "A")
        // The journal now owns the result, so Operation History shows the restore.
        XCTAssertEqual(try f.journal.load().first?.recoveryAttempts?.last?.items.map(\.outcome), [.restored])

        // A second request finds the receipt settled and never moves it again.
        let again = LegacyCleanupRestore.plan(for: records, reports: try f.journal.load())
        XCTAssertTrue(again.matches.isEmpty)
        XCTAssertEqual(again.settled.map(\.outcome), [.restored])
        let second = LegacyCleanupRestore.summary(records: records, plan: again, recoveries: [], legacy: nil)
        XCTAssertEqual(second.missing.map(\.id), records.map(\.id))
        XCTAssertTrue(second.restored.isEmpty)
    }

    func testRecordsWithoutJournalReceiptsKeepTheLegacyPath() throws {
        let f = try Fixture(); defer { f.remove() }
        let report = try f.moveToTrash("A")
        // legacyTrashRecords mints new record IDs on each read; keep one copy.
        let journaled = report.legacyTrashRecords
        let record = try XCTUnwrap(journaled.first)
        let preJournal = TrashMoveRecord(originalPath: f.root.appendingPathComponent("old").path,
                                         resultingItemURL: f.trash.appendingPathComponent("old"), itemIdentity: nil)
        let plan = LegacyCleanupRestore.plan(for: journaled + [preJournal], reports: try f.journal.load())
        XCTAssertEqual(plan.unmatched.map(\.id), [preJournal.id])
        let legacy = TrashRestoreSummary(restored: [], conflicts: [], missing: [preJournal], failed: [])
        let summary = LegacyCleanupRestore.summary(records: journaled + [preJournal], plan: plan,
            recoveries: [CleanupRecoveryReport(completedAt: Date(), items: [
                CleanupRecoveryItem(id: UUID(), originalPath: record.originalPath, outcome: .conflict)
            ])], legacy: legacy)
        XCTAssertEqual(summary.missing.map(\.id), [preJournal.id])
        XCTAssertEqual(summary.conflicts.map(\.id), journaled.map(\.id))
    }

    func testRestoreFromOperationHistoryPrunesTheLegacyHistory() throws {
        let f = try Fixture(); defer { f.remove() }
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let a = try f.moveToTrash("A"), b = try f.moveToTrash("B")
        let item = { (report: CleanReport, name: String) throws -> StorageItem in
            let path = try XCTUnwrap(report.items.first).sourcePath
            return StorageItem(id: name, title: name, path: path, groupTitle: "Fixture", sizeBytes: 1,
                tier: .green, kind: "cache", reason: "fixture", recommendation: "fixture", risk: "low",
                requiresClose: "", trashPaths: [path], openPath: path,
                status: .available)
        }
        CleanupHistoryService.recordMovedItems([try item(a, "A"), try item(b, "B")],
            moveRecords: a.legacyTrashRecords + b.legacyTrashRecords, defaults: defaults)
        XCTAssertEqual(CleanupHistoryService.summary(defaults: defaults).latestRestorable?.restorableMoveRecords.count, 2)

        CleanupHistoryService.removeMoveRecords(restoredBy: a.restorableReceipts, defaults: defaults)

        let remaining = CleanupHistoryService.summary(defaults: defaults).latestRestorable?.restorableMoveRecords
        XCTAssertEqual(remaining?.map(\.originalPath), [try XCTUnwrap(b.items.first).sourcePath])
    }

    func testEmptyFileMoveIsStillRecordedForRestore() throws {
        let f = try Fixture(); defer { f.remove() }
        let suite = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suite))
        defer { TestPreferenceDomain.cleanup(suiteName: suite) }
        let report = try f.moveToTrash("empty", contents: "")
        let path = try XCTUnwrap(report.items.first).sourcePath
        let item = StorageItem(id: "empty", title: "empty", path: path, groupTitle: "Fixture", sizeBytes: 0,
            tier: .green, kind: "cache", reason: "fixture", recommendation: "fixture", risk: "low",
            requiresClose: "", trashPaths: [path], openPath: path, status: .available)
        CleanupHistoryService.recordMovedItems([item], moveRecords: report.legacyTrashRecords, defaults: defaults)
        XCTAssertEqual(CleanupHistoryService.summary(defaults: defaults).latestRestorable?.restorableMoveRecords.count, 1)
    }
}
