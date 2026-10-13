import Foundation
import XCTest
@testable import StorageCleanerMac

/// N18 (live test 2026-10-07): File Move put the original in the Trash with
/// a bare `trashItem`, so Operation History had nothing to restore; the only
/// record was the copy's staging receipt, shown as "Migration Temporary
/// Resources · No files moved · Moved 0 · Kept 1"; and the banner of an
/// earlier restore stayed on top of the list.
///
/// 文件、回执和废纸篓都在临时家目录中；显式注入根，保留迁移边界校验。
final class ExternalMigrationReceiptTests: XCTestCase {
    // MARK: - Moving the original writes a receipt that restores

    func testMovingTheOriginalWritesARestorableReceiptAndRestoreBringsItBackKeepingTheCopy() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let (item, destination) = try fixture.migratedFile(named: "Holiday Clip.mov", contents: "verified movie bytes")

        let result = try ExternalDriveMigrationService.moveOriginalToTrash(
            item,
            verifiedCopyAt: destination,
            on: fixture.volume,
            trustedVolumes: [fixture.volume],
            trashOperation: fixture.moveToFixtureTrash,
            journal: fixture.journal,
            homeDirectory: fixture.root
        )

        XCTAssertTrue(result.didMoveSourceToTrash)
        XCTAssertTrue(result.canRestoreFromHistory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.sourceURL.path))
        let reports = try fixture.journal.load()
        XCTAssertEqual(reports.count, 1, "One durable receipt for the move")
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.rulesVersion, ExternalDriveMigrationService.originalRuleID)
        XCTAssertEqual(report.disposition, .trash)
        XCTAssertEqual(report.summary.movedItemCount, 1)
        let receipt = try XCTUnwrap(report.restorableReceipts.first)
        XCTAssertEqual(receipt.originalPath, item.sourceURL.path)
        XCTAssertEqual(
            receipt.resultingItemURL.standardizedFileURL,
            fixture.trash.appendingPathComponent("Holiday Clip.mov").standardizedFileURL
        )

        // Restore through the same receipt-journal path Operation History uses.
        let coordinator = HeavyWorkCoordinator()
        let service = CleanupRecoveryService()
        let journal = fixture.journal
        let home = fixture.root
        let trash = fixture.trash
        let restored = try await coordinator.withLease(owner: .restore) { lease in
            await service.restore(
                report: report, coordinator: coordinator, lease: lease,
                journal: journal, userHomeURL: home, trashURL: trash
            )
        }
        XCTAssertEqual(restored.recovery.restoredCount, 1)
        XCTAssertEqual(try String(contentsOf: item.sourceURL, encoding: .utf8), "verified movie bytes")
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "verified movie bytes",
            "The copy on the external drive stays"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("Holiday Clip.mov").path))
        XCTAssertEqual(try fixture.journal.load().first?.restorableReceipts.count, 0)
    }

    func testRestoreKeepsBothFilesWhenTheOriginalPlaceIsTakenAgain() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let (item, destination) = try fixture.migratedFile(named: "Scan.pdf", contents: "original scan")
        _ = try ExternalDriveMigrationService.moveOriginalToTrash(
            item, verifiedCopyAt: destination, on: fixture.volume,
            trustedVolumes: [fixture.volume], trashOperation: fixture.moveToFixtureTrash, journal: fixture.journal,
            homeDirectory: fixture.root
        )
        try Data("a newer file with the same name".utf8).write(to: item.sourceURL)

        let report = try XCTUnwrap(fixture.journal.load().first)
        let coordinator = HeavyWorkCoordinator()
        let service = CleanupRecoveryService()
        let journal = fixture.journal
        let home = fixture.root
        let trash = fixture.trash
        let restored = try await coordinator.withLease(owner: .restore) { lease in
            await service.restore(
                report: report, coordinator: coordinator, lease: lease,
                journal: journal, userHomeURL: home, trashURL: trash
            )
        }

        XCTAssertEqual(restored.recovery.items.map(\.outcome), [.conflict])
        XCTAssertEqual(try String(contentsOf: item.sourceURL, encoding: .utf8), "a newer file with the same name")
        XCTAssertEqual(
            try String(contentsOf: fixture.trash.appendingPathComponent("Scan.pdf"), encoding: .utf8),
            "original scan"
        )
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original scan")
    }

    func testWithoutADurableReceiptTheOriginalStaysWhereItIs() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let (item, destination) = try fixture.migratedFile(named: "Archive.zip", contents: "zip bytes")

        XCTAssertThrowsError(
            try ExternalDriveMigrationService.moveOriginalToTrash(
                item, verifiedCopyAt: destination, on: fixture.volume,
                trustedVolumes: [fixture.volume], trashOperation: fixture.moveToFixtureTrash,
                persist: { _, _ in throw CocoaError(.fileWriteOutOfSpace) },
                homeDirectory: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ExternalDriveMigrationError, .receiptUnavailable)
        }
        XCTAssertEqual(try String(contentsOf: item.sourceURL, encoding: .utf8), "zip bytes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
    }

    func testARefusedMoveKeepsTheOriginalAndLeavesNothingToRestore() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let (item, destination) = try fixture.migratedFile(named: "Notes.key", contents: "keynote bytes")

        XCTAssertThrowsError(
            try ExternalDriveMigrationService.moveOriginalToTrash(
                item, verifiedCopyAt: destination, on: fixture.volume,
                trustedVolumes: [fixture.volume],
                trashOperation: { _ in throw CocoaError(.fileWriteNoPermission) },
                journal: fixture.journal,
                homeDirectory: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ExternalDriveMigrationError, .originalRemovalFailed)
        }
        XCTAssertEqual(try String(contentsOf: item.sourceURL, encoding: .utf8), "keynote bytes")
        let report = try XCTUnwrap(fixture.journal.load().first, "The refused attempt is recorded too")
        XCTAssertEqual(report.summary.movedItemCount, 0)
        XCTAssertTrue(report.restorableReceipts.isEmpty)
    }

    // MARK: - Operation History wording

    // MARK: - Review P2-2: where the receipt goes

    /// Without an explicit persistence the move writes the journal it is
    /// given; production gives none and gets the live journal.
    func testTheDefaultReceiptPathWritesTheJournalItIsGiven() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let (item, destination) = try fixture.migratedFile(named: "Default Path.mov", contents: "default path bytes")

        let result = try ExternalDriveMigrationService.moveOriginalToTrash(
            item,
            verifiedCopyAt: destination,
            on: fixture.volume,
            trustedVolumes: [fixture.volume],
            trashOperation: fixture.moveToFixtureTrash,
            journal: fixture.journal,
            homeDirectory: fixture.root
        )

        XCTAssertTrue(result.canRestoreFromHistory)
        let report = try XCTUnwrap(try fixture.journal.load().first)
        XCTAssertEqual(report.rulesVersion, ExternalDriveMigrationService.originalRuleID)
        XCTAssertEqual(report.restorableReceipts.first?.originalPath, item.sourceURL.path)
    }

    /// Injected volumes are fixture-only; such a call must say where its
    /// receipt goes, so a test can never write the live journal by leaving
    /// the journal out, and never moves an original without a receipt.
    func testAFixtureMoveMustSayWhereItsReceiptGoes() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let (item, destination) = try fixture.migratedFile(named: "No Journal.mov", contents: "no journal bytes")

        XCTAssertThrowsError(
            try ExternalDriveMigrationService.moveOriginalToTrash(
                item,
                verifiedCopyAt: destination,
                on: fixture.volume,
                trustedVolumes: [fixture.volume],
                trashOperation: fixture.moveToFixtureTrash,
                homeDirectory: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ExternalDriveMigrationError, .receiptUnavailable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.sourceURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
    }

    /// Review P2-2 follow-up (source contract): the one production call that
    /// moves an original names no journal, persistence, volumes or Trash
    /// stand-in, so it gets the default, and the default is the live journal.
    /// Only fixture calls name a journal (the tests above), never the app.
    func testTheProductionMoveWritesTheLiveJournal() throws {
        let callSites = try sourceFiles().filter { path, text in
            path != "Sources/StorageCleanerMac/Services/ExternalDriveMigrationService.swift"
                && text.contains("ExternalDriveMigrationService.moveOriginalToTrash(")
        }
        XCTAssertEqual(callSites.map(\.path), ["Sources/StorageCleanerMac/Views/LargeFilesView.swift"])
        let view = try source("Sources/StorageCleanerMac/Views/LargeFilesView.swift")
        let calls = Self.argumentLists(of: "ExternalDriveMigrationService.moveOriginalToTrash(", in: view)
        XCTAssertEqual(calls.count, 1)
        let arguments = try XCTUnwrap(calls.first)
        XCTAssertTrue(arguments.contains("verifiedCopyAt:"), arguments)
        for fixtureOnly in ["journal:", "persist:", "trustedVolumes:", "trashOperation:", "homeDirectory:"] {
            XCTAssertFalse(arguments.contains(fixtureOnly), "Production passes \(fixtureOnly): \(arguments)")
        }

        let service = try source("Sources/StorageCleanerMac/Services/ExternalDriveMigrationService.swift")
        XCTAssertTrue(service.contains("journal: CleanupReportJournal? = nil"))
        XCTAssertTrue(service.contains("let receiptJournal = journal ?? .live"))
        XCTAssertTrue(service.contains("persist ?? { report, identities in\n            try receiptJournal.checkpoint("))
        XCTAssertEqual(
            CleanupReportJournal.live.directory.standardizedFileURL,
            AppDataDirectories.applicationSupportRoot
                .appendingPathComponent("CleanupReports", isDirectory: true).standardizedFileURL,
            "The default is the app's one receipt journal"
        )
    }

    // MARK: - Review P2-7: a restored original leaves its "moved" row

    @MainActor
    func testAnOriginalPutBackOrReplacedNoLongerShowsAsMoved() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let coordinator = HeavyWorkCoordinator()
        let store = LargeFilesStore(
            coordinator: coordinator,
            activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self),
            storageMapTargets: []
        )
        func move(_ name: String) throws -> (ExternalMigrationItem, ExternalMigrationResult) {
            let (item, destination) = try fixture.migratedFile(named: name, contents: "\(name) bytes")
            let result = try ExternalDriveMigrationService.moveOriginalToTrash(
                item,
                verifiedCopyAt: destination,
                on: fixture.volume,
                trustedVolumes: [fixture.volume],
                trashOperation: fixture.moveToFixtureTrash,
                journal: fixture.journal,
                homeDirectory: fixture.root
            )
            XCTAssertNotNil(result.originalIdentity)
            store.recordMigrationCompletion(ExternalMigrationCompletion(
                destinationURL: result.destinationURL,
                volume: fixture.volume,
                didMoveSourceToTrash: result.didMoveSourceToTrash,
                originalPath: item.sourceURL.path,
                originalIdentity: result.originalIdentity
            ), for: item.id)
            return (item, result)
        }
        let (restoredItem, restoredMove) = try move("Put Back.mov")
        let (replacedItem, _) = try move("Replaced.mov")

        store.refreshMigrationCompletions()
        XCTAssertEqual(store.migrationCompletions[restoredItem.id]?.isMovedAway, true, "Nothing came back yet")
        XCTAssertEqual(store.migrationCompletions[replacedItem.id]?.isMovedAway, true)

        // Put one original back the way Operation History does, and put a
        // different file where the other one was.
        let report = try XCTUnwrap(try fixture.journal.load().first {
            $0.restorableReceipts.first?.originalPath == restoredItem.sourceURL.path
        })
        let service = CleanupRecoveryService()
        let journal = fixture.journal
        let home = fixture.root
        let trash = fixture.trash
        let restored = try await coordinator.withLease(owner: .restore) { lease in
            await service.restore(
                report: report, coordinator: coordinator, lease: lease,
                journal: journal, userHomeURL: home, trashURL: trash
            )
        }
        XCTAssertEqual(restored.recovery.restoredCount, 1)
        try Data("someone else's file".utf8).write(to: replacedItem.sourceURL)

        store.refreshMigrationCompletions()

        let back = try XCTUnwrap(store.migrationCompletions[restoredItem.id])
        XCTAssertEqual(back.returnedOriginal, .restored)
        XCTAssertFalse(back.isMovedAway)
        XCTAssertEqual(back.displayPath(original: restoredItem.sourceURL.path), restoredItem.sourceURL.path)
        XCTAssertEqual(back.destinationURL, restoredMove.destinationURL, "The copy on the drive is still known")
        XCTAssertEqual(store.migrationCompletions[replacedItem.id]?.returnedOriginal, .replaced)

        let view = try source("Sources/StorageCleanerMac/Views/LargeFilesView.swift")
        XCTAssertTrue(view.contains("workspace.refreshMigrationCompletions()"))
        XCTAssertTrue(view.contains("originalIdentity: result.originalIdentity"))
        let row = try source("Sources/StorageCleanerMac/Views/FilesLightfield/FileMigrationLightfieldView.swift")
        XCTAssertTrue(row.contains("case .restored?:"))
        XCTAssertTrue(row.contains("case .replaced?:"))
    }

    /// Review P2-7 follow-up: Operation History is a sheet over the page, so
    /// the page does not appear again after a restore. The store hears about
    /// the restore itself: the moved row updates at once, no page switch and
    /// no explicit refresh by the page.
    @MainActor
    func testARestoreFromOperationHistoryUpdatesTheMovedRowWithoutAPageSwitch() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let coordinator = HeavyWorkCoordinator()
        let store = LargeFilesStore(
            coordinator: coordinator,
            activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self),
            storageMapTargets: []
        )
        let (item, destination) = try fixture.migratedFile(named: "Sheet Restore.mov", contents: "sheet restore bytes")
        let moved = try ExternalDriveMigrationService.moveOriginalToTrash(
            item, verifiedCopyAt: destination, on: fixture.volume, trustedVolumes: [fixture.volume],
            trashOperation: fixture.moveToFixtureTrash, journal: fixture.journal,
            homeDirectory: fixture.root
        )
        store.recordMigrationCompletion(ExternalMigrationCompletion(
            destinationURL: moved.destinationURL, volume: fixture.volume,
            didMoveSourceToTrash: moved.didMoveSourceToTrash, originalPath: item.sourceURL.path,
            originalIdentity: moved.originalIdentity
        ), for: item.id)
        XCTAssertEqual(store.migrationCompletions[item.id]?.isMovedAway, true)

        // The restore Operation History runs (ScanStore.restoreRecordedOperations).
        let report = try XCTUnwrap(try fixture.journal.load().first)
        let service = CleanupRecoveryService()
        let journal = fixture.journal
        let home = fixture.root
        let trash = fixture.trash
        let restored = try await coordinator.withLease(owner: .restore) { lease in
            await service.restore(
                report: report, coordinator: coordinator, lease: lease,
                journal: journal, userHomeURL: home, trashURL: trash
            )
        }
        XCTAssertEqual(restored.recovery.restoredCount, 1)
        store.operationHistoryDidRestore(restored.report.items.compactMap {
            if case .moved(let receipt) = $0.outcome { return receipt }
            return nil
        })

        XCTAssertEqual(store.migrationCompletions[item.id]?.returnedOriginal, .restored,
                       "The row stops pointing at the copy right after the restore")
        XCTAssertFalse(try XCTUnwrap(store.migrationCompletions[item.id]).isMovedAway)
    }

    /// The wiring of the test above: ScanStore tells the file pages' store
    /// after every restore it runs for Operation History (and for the
    /// uninstall review, which shares the path), after the restore itself.
    /// ScanStore's restore is not run here: afterwards it reloads the
    /// Operation History list from the live journal (BOARD N8).
    func testScanStoreTellsTheFilePagesAfterARestore() throws {
        let scanStore = try source("Sources/StorageCleanerMac/Stores/ScanStore.swift")
        let start = try XCTUnwrap(scanStore.range(of: "private func restoreRecordedOperations("))
        let end = try XCTUnwrap(scanStore.range(of: "private static func combinedRecovery(", range: start.upperBound..<scanStore.endIndex))
        let body = String(scanStore[start.upperBound..<end.lowerBound])
        let restore = try XCTUnwrap(body.range(of: "await service.restore(reports: reports"))
        let notify = try XCTUnwrap(body.range(of: "largeFilesWorkspace.operationHistoryDidRestore(restoredReceipts)"),
                                   "ScanStore does not tell the file pages about the restore")
        XCTAssertLessThan(restore.lowerBound, notify.lowerBound)

        let view = try source("Sources/StorageCleanerMac/Views/LargeFilesView.swift")
        XCTAssertTrue(view.contains("workspace.refreshMigrationCompletions()"),
                      "A page that appears later still looks again")
    }

    func testHistoryNamesFileMoveRecordsAndDescribesTemporaryFilesPlainly() {
        let language = MigrationLanguageScope(.zhHans)
        defer { language.restore() }
        typealias P = OperationRecordPresentation
        XCTAssertEqual(P.title(rulesVersion: ExternalDriveMigrationService.originalRuleID, subject: "Holiday Clip.mov"),
                       "文件搬家 · Holiday Clip.mov")
        XCTAssertEqual(P.title(rulesVersion: ExternalDriveMigrationService.originalRuleID, subject: nil),
                       "文件搬家 · 原件移到废纸篓")
        XCTAssertEqual(P.title(rulesVersion: "migration.staging.v1", subject: nil), "文件搬家 · 复制用的临时文件")
        XCTAssertEqual(P.title(rulesVersion: "uninstall.application.v1", subject: "Fixture App"), "Fixture App")
        XCTAssertEqual(P.title(rulesVersion: "cleanup.v2.rules", subject: nil), "文件清理")

        XCTAssertTrue(P.isTemporaryResource("migration.staging.v1"))
        XCTAssertTrue(P.isTemporaryResource("benchmark.fixture.v1"))
        XCTAssertFalse(P.isTemporaryResource(ExternalDriveMigrationService.originalRuleID))
        XCTAssertEqual(P.temporaryResourceStatus(rulesVersion: "migration.staging.v1", outcome: .completed),
                       "已自动清理，无需处理")
        XCTAssertEqual(P.temporaryResourceStatus(rulesVersion: "migration.staging.v1", outcome: .partiallyCompleted),
                       "未能自动清理，需要核实")
        XCTAssertNil(P.temporaryResourceStatus(rulesVersion: ExternalDriveMigrationService.originalRuleID, outcome: .completed))
        XCTAssertFalse(P.offersRestore(rulesVersion: "migration.staging.v1"))
        XCTAssertTrue(P.offersRestore(rulesVersion: ExternalDriveMigrationService.originalRuleID))
        XCTAssertEqual(P.temporaryItemLabel(.skipped(.itemMissing)), "临时文件已清理")
        XCTAssertEqual(
            P.temporaryItemLabel(.failed(CleanFailure(code: .moveOutcomeUnknown, detailCode: "staging-cleanup-pending"))),
            "临时文件未能清理，需要核实"
        )
    }

    func testTheCopysStagingReceiptReadsAsCleanedUpTemporaryFiles() throws {
        let language = MigrationLanguageScope(.zhHans)
        defer { language.restore() }
        // The receipt journal refuses any path with a symbolic-link
        // component (the temporary folder sits under /var), so this uses the
        // home-folder fixture like the other journal tests.
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let journal = fixture.journal
        let staging = try MigrationStagingDirectory(parentURL: fixture.volume.url)
        let receipt = try MigrationStagingReceipt(url: staging.url, journal: journal)
        receipt.cleanup(staging)

        let index = try XCTUnwrap(journal.summaryPage().reports.first)
        let title = OperationRecordPresentation.title(rulesVersion: index.rulesVersion, subject: index.subject)
        let status = try XCTUnwrap(OperationRecordPresentation.temporaryResourceStatus(
            rulesVersion: index.rulesVersion, outcome: index.outcome
        ))
        XCTAssertEqual(title, "文件搬家 · 复制用的临时文件")
        XCTAssertEqual(status, "已自动清理，无需处理")
        for text in [title, status] {
            XCTAssertFalse(text.contains("未移走"))
            XCTAssertFalse(text.contains("已移走 0"))
        }
        XCTAssertFalse(OperationRecordPresentation.offersRestore(rulesVersion: index.rulesVersion))
    }

    func testTheRestoreBannerOnlyShowsAResultFromThisVisit() throws {
        let earlier = CleanupRecoveryReport(completedAt: Date(timeIntervalSince1970: 1),
                                            items: [], attemptID: UUID())
        let now = CleanupRecoveryReport(completedAt: Date(timeIntervalSince1970: 2),
                                        items: [], attemptID: UUID())
        typealias P = OperationRecordPresentation
        XCTAssertNil(P.visibleRecovery(current: earlier, baseline: .notCaptured))
        XCTAssertNil(P.visibleRecovery(current: earlier, baseline: .captured(earlier)), "Left over from before")
        XCTAssertEqual(P.visibleRecovery(current: now, baseline: .captured(earlier)), now)
        XCTAssertEqual(P.visibleRecovery(current: now, baseline: .captured(nil)), now)
        XCTAssertNil(P.visibleRecovery(current: nil, baseline: .captured(earlier)))

        let history = try source("Sources/StorageCleanerMac/Views/ReversibleOperationsView.swift")
        XCTAssertTrue(history.contains("OperationRecordPresentation.visibleRecovery("))
        XCTAssertTrue(history.contains("recoveryBaseline = .captured(store.operationRecoveryResult)"))
        XCTAssertFalse(history.contains("if let recovery = store.operationRecoveryResult {"))
        XCTAssertTrue(history.contains("OperationRecordPresentation.title(rulesVersion:"))
        XCTAssertTrue(history.contains("OperationRecordPresentation.temporaryResourceStatus("))
        XCTAssertTrue(history.contains("OperationRecordPresentation.offersRestore(rulesVersion:"))
    }

    // MARK: - The moved row shows where the file is now

    @MainActor
    func testAMovedRowShowsItsNewLocationAcrossPageSwitchesUntilTheNextScan() throws {
        let volume = ExternalStorageVolume(
            url: URL(fileURLWithPath: "/Volumes/Storage", isDirectory: true), name: "Storage",
            availableBytes: 1, totalBytes: 2, fileSystem: "APFS", supportsApplications: true
        )
        let destination = URL(fileURLWithPath: "/Volumes/Storage/StorageCleaner Migration/Large Files/Clip.mov")
        let moved = ExternalMigrationCompletion(destinationURL: destination, volume: volume, didMoveSourceToTrash: true)
        let copied = ExternalMigrationCompletion(destinationURL: destination, volume: volume, didMoveSourceToTrash: false)
        XCTAssertEqual(moved.displayPath(original: "/Users/test/Movies/Clip.mov"), destination.path)
        XCTAssertEqual(copied.displayPath(original: "/Users/test/Movies/Clip.mov"), "/Users/test/Movies/Clip.mov")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LargeFilesMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { TestFileSystem.remove(folder) }
        let coordinator = HeavyWorkCoordinator()
        let store = LargeFilesStore(
            coordinator: coordinator,
            activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: try XCTUnwrap(TestPreferenceDomain.open(suiteName: folder.appendingPathComponent("suite").path)),
            storageMapTargets: []
        )
        store.recordMigrationCompletion(moved, for: "file:clip")
        XCTAssertEqual(store.migrationCompletions["file:clip"], moved, "Kept by the store, not the page")
        store.replaceItemsForTesting([])
        XCTAssertTrue(store.migrationCompletions.isEmpty, "A new list starts without old completions")

        let view = try source("Sources/StorageCleanerMac/Views/LargeFilesView.swift")
        let row = try source("Sources/StorageCleanerMac/Views/FilesLightfield/FileMigrationLightfieldView.swift")
        XCTAssertTrue(row.contains("displayPath(original: entry.item.sourceURL.path)"))
        XCTAssertTrue(view.contains("workspace.recordMigrationCompletion("))
        XCTAssertTrue(view.contains("workspace.migrationCompletions["))
        XCTAssertFalse(view.contains("@State private var completedMigrations"))
    }

    // MARK: - Helpers

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every Swift file under Sources, as (path relative to the package, text).
    private func sourceFiles() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return [] }
        var result: [(path: String, text: String)] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            result.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return result.sorted { $0.path < $1.path }
    }

    /// The text between each `call` (which ends with its opening parenthesis)
    /// and the parenthesis that closes it.
    static func argumentLists(of call: String, in text: String) -> [String] {
        var lists: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: call, range: searchStart..<text.endIndex) {
            var depth = 1
            var index = range.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1 }
                if depth > 0 { index = text.index(after: index) }
            }
            lists.append(String(text[range.upperBound..<index]))
            searchStart = range.upperBound
        }
        return lists
    }
}

/// 隐藏家目录隔离区中的源文件、模拟卷、模拟废纸篓和回执日志。
private struct MigrationFixture {
    let root: URL
    let source: URL
    let volume: ExternalStorageVolume
    let trash: URL
    let journal: CleanupReportJournal

    init() throws {
        let fileManager = FileManager.default
        root = TestFileSystem.uniqueOperationRoot("MigrationReceipt")
        source = root.appendingPathComponent("Source", isDirectory: true)
        trash = root.appendingPathComponent("Trash", isDirectory: true)
        let volumeURL = root.appendingPathComponent("External", isDirectory: true)
        do {
            for folder in [source, trash, volumeURL] {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            volume = ExternalStorageVolume(
                url: volumeURL, name: "External", availableBytes: 1_000_000, totalBytes: 2_000_000,
                fileSystem: "APFS", supportsApplications: true
            )
            journal = CleanupReportJournal(directory: root.appendingPathComponent("Receipts", isDirectory: true))
        } catch {
            TestFileSystem.remove(root)
            throw error
        }
    }

    func remove() {
        TestFileSystem.remove(root)
    }

    var persist: RecordedTrashOperation.Persistence {
        { [journal] report, identities in try journal.checkpoint(report, expectedIdentities: identities) }
    }

    var moveToFixtureTrash: (URL) throws -> URL? {
        { [trash] url in
            let target = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    /// Copies one file to the fake volume through the real migration step.
    func migratedFile(named name: String, contents: String) throws -> (ExternalMigrationItem, URL) {
        let url = source.appendingPathComponent(name)
        let data = Data(contents.utf8)
        try data.write(to: url)
        let item = ExternalMigrationItem(
            id: "file:\(name)", title: name, sourceURL: url,
            sizeBytes: Int64(data.count), kind: .file, bundleIdentifier: ""
        )
        let copy = try ExternalDriveMigrationService.migrate(item, to: volume, trustedVolumes: [volume], homeDirectory: root)
        return (item, copy.destinationURL)
    }
}

/// Switches the interface language through the volatile argument domain,
/// so nothing is written to a preferences file.
private final class MigrationLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        // L10n caches the language until defaults announce a change.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}
