import Foundation
import XCTest
@testable import StorageCleanerMac

/// "Recent Deletions": the backup taken before a direct deletion, what is
/// kept of it, and restoring from it. Every database lives in a temporary
/// directory.
@MainActor
final class BrowserPrivacyRecoveryTests: XCTestCase {
    func testSuccessfulDeletionKeepsOneBackupDescribedWithoutAddressesOrTitles() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute("UPDATE urls SET title = 'Private Page Title' WHERE id = 2")
        let selected = try await fixture.selectedRecords(visitIDs: [21, 12])

        let report = await fixture.processor().process(records: selected)
        let processed = try XCTUnwrap(report.entries.first)
        XCTAssertEqual(processed.outcome, .deleted, processed.detail)

        let entries = fixture.recoveryService.entries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, processed.recoveryBackupID)
        XCTAssertEqual(entry.browserID, "chrome")
        XCTAssertEqual(
            entry.summary,
            BrowserPrivacyRecoverySummary(
                browserDisplayName: "Google Chrome",
                profileDisplayName: "Default",
                visitCount: 2,
                pageCount: 2,
                outcome: .deleted
            )
        )
        XCTAssertNil(entry.restoredAt)
        XCTAssertEqual(
            entry.profileFingerprint,
            BrowserPrivacyRecoveryBackupService.profileFingerprint(for: fixture.profile.id)
        )

        // The description next to the backup names no page.
        let metadata = try String(
            contentsOf: fixture.recoveryRoot
                .appendingPathComponent(entry.id.uuidString)
                .appendingPathComponent("metadata.json"),
            encoding: .utf8
        )
        for leak in ["fixture.invalid", "https:", "Private Page Title", fixture.profile.id] {
            XCTAssertFalse(metadata.contains(leak), leak)
        }
    }

    func testDeletionThatChangedNothingLeavesNoBackupBehind() async throws {
        // Refused before the first write.
        let synced = try ChromiumV70HistoryFixture(mode: .production)
        let syncedSelection = try await synced.selectedRecords(visitIDs: [12])
        try synced.execute("UPDATE visits SET is_known_to_sync = 1 WHERE id = 12")
        let syncedReport = await synced.processor().process(records: syncedSelection)
        XCTAssertEqual(syncedReport.entries.first?.reason, .syncedRecords)
        XCTAssertNil(syncedReport.entries.first?.recoveryBackupID)
        XCTAssertTrue(synced.recoveryService.entries().isEmpty)
        XCTAssertTrue(try Self.backupDirectories(in: synced.recoveryRoot).isEmpty)

        // Started and rolled back.
        let failing = try ChromiumV70HistoryFixture(mode: .production, failURLUpdate: true)
        let failingReport = await failing.processor().process(
            records: try await failing.selectedRecords(visitIDs: [12])
        )
        XCTAssertNotEqual(failingReport.entries.first?.outcome, .deleted)
        XCTAssertNil(failingReport.entries.first?.recoveryBackupID)
        XCTAssertTrue(try Self.backupDirectories(in: failing.recoveryRoot).isEmpty)

        // The browser is running: no backup is taken at all.
        let running = try ChromiumV70HistoryFixture(mode: .production)
        let runningReport = await running.processor(
            runningBundleIdentifiers: ["com.google.Chrome"]
        ).process(records: try await running.selectedRecords(visitIDs: [12]))
        XCTAssertEqual(runningReport.entries.first?.reason, .browserRunning)
        XCTAssertTrue(try Self.backupDirectories(in: running.recoveryRoot).isEmpty)
    }

    func testCommittedButUnverifiedDeletionKeepsItsBackupMarkedUnverified() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(visitIDs: [21])
        let processor = fixture.processor(beforeReadBackHook: { [fixture] in
            try? fixture.execute(
                """
                INSERT INTO urls (id, url, title, visit_count, typed_count, last_visit_time, hidden)
                    VALUES (2, 'https://fixture.invalid/2', NULL, 1, 0, 13324473604000000, 0)
                """
            )
        })

        let report = await processor.process(records: selected)

        XCTAssertEqual(report.entries.first?.outcome, .indeterminate)
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)
        XCTAssertEqual(entry.id, report.entries.first?.recoveryBackupID)
        XCTAssertEqual(entry.summary?.outcome, .unverified)
        XCTAssertEqual(entry.summary?.visitCount, 1)
    }

    func testRestoreBringsBackExactlyTheStateBeforeTheDeletion() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute(ChromiumV70HistoryFixture.clusterRowsSQL)
        try fixture.execute(ChromiumV70HistoryFixture.visitedLinkRowsSQL)
        try fixture.execute("INSERT INTO keyword_search_terms VALUES (5, 1, 'term', 'term')")
        let before = try fixture.tableState()
        let selected = try await fixture.selectedRecords(visitIDs: [11, 12, 13])
        let report = await fixture.processor().process(records: selected)
        XCTAssertEqual(report.entries.first?.outcome, .deleted, report.entries.first?.detail ?? "")
        XCTAssertNotEqual(try fixture.tableState(), before)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM urls WHERE id = 1"), 0)
        // History added after the deletion is what a restore gives up.
        try fixture.execute(
            """
            INSERT INTO urls (id, url, title, visit_count, typed_count, last_visit_time, hidden)
                VALUES (50, 'https://fixture.invalid/later', NULL, 1, 0, 13324473700000000, 0);
            INSERT INTO visits (id, url, visit_time, from_visit, transition, segment_id,
                                incremented_omnibox_typed_score, visited_link_id)
                VALUES (60, 50, 13324473700000000, 0, 0, 0, 0, 0);
            """
        )
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)

        let result = await fixture.processor().restore(
            entry,
            installedApplications: [try XCTUnwrap(fixture.installedApplication)]
        )

        XCTAssertTrue(result.succeeded, result.detail)
        XCTAssertEqual(result.reason, .restored)
        XCTAssertEqual(try fixture.tableState(), before, "every table is back to its earlier content")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM urls WHERE id = 50"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 60"), 0)
        let reread = try await fixture.scanOutcome()
        XCTAssertEqual(reread.records.count, 4)
        XCTAssertTrue(reread.records.allSatisfy { $0.locator != nil })
        let entries = fixture.recoveryService.entries()
        XCTAssertTrue(entries.contains { $0.id == entry.id }, "the backup stays until it is removed")
        XCTAssertEqual(
            entries.filter { $0.summary?.outcome == .savedBeforeRestore }.map(\.id),
            [try XCTUnwrap(result.undoBackupID)],
            "the state before the restore was saved as well"
        )
    }

    func testRestoreIsRefusedWhileTheBrowserRunsOrTheDatabaseHasUnmergedWrites() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(visitIDs: [21])
        _ = await fixture.processor().process(records: selected)
        let afterDeletion = try fixture.tableState()
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)
        let application = try XCTUnwrap(fixture.installedApplication)

        let running = await fixture.processor(
            runningBundleIdentifiers: [application.bundleIdentifier]
        ).restore(entry, installedApplications: [application])
        XCTAssertFalse(running.succeeded)
        XCTAssertEqual(running.reason, .browserRunning)
        XCTAssertEqual(try fixture.tableState(), afterDeletion)

        try fixture.createSidecar("-wal")
        let pending = await fixture.processor().restore(entry, installedApplications: [application])
        XCTAssertFalse(pending.succeeded)
        XCTAssertEqual(pending.reason, .pendingWrites)
        XCTAssertEqual(try fixture.tableState(), afterDeletion)
    }

    func testRestoreRefusesADamagedBackupAnUnknownProfileAndAnUnverifiedApplication() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(visitIDs: [21])
        _ = await fixture.processor().process(records: selected)
        let afterDeletion = try fixture.tableState()
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)
        let application = try XCTUnwrap(fixture.installedApplication)

        // The backup belongs to another profile than any that exists now.
        let foreign = BrowserPrivacyRecoveryEntry(
            backup: entry.backup,
            browserID: entry.browserID,
            profileFingerprint: BrowserPrivacyRecoveryBackupService.profileFingerprint(for: "chrome:Gone"),
            summary: entry.summary,
            restoredAt: nil
        )
        let unknownProfile = await fixture.processor().restore(foreign, installedApplications: [application])
        XCTAssertEqual(unknownProfile.reason, .profileUnavailable)

        // Without a verified installed browser the database cannot be tied to it.
        let unverified = await fixture.processor().restore(entry, installedApplications: [])
        XCTAssertEqual(unverified.reason, .profileUnavailable)

        // A backup whose bytes changed is never copied over a database.
        let handle = try FileHandle(forWritingTo: entry.backup.databaseURL)
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 64))
        try handle.close()
        let damaged = await fixture.processor().restore(entry, installedApplications: [application])
        XCTAssertEqual(damaged.reason, .backupUnavailable)

        XCTAssertEqual(try fixture.tableState(), afterDeletion, "a refused restore changes nothing")
    }

    func testRecoveryStoreListsRestoresAndRemovesBackups() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let before = try fixture.tableState()
        let selected = try await fixture.selectedRecords(visitIDs: [21])
        _ = await fixture.processor().process(records: selected)
        let store = BrowserPrivacyRecoveryStore(
            service: fixture.recoveryService,
            processor: fixture.processor(),
            installedApplications: [try XCTUnwrap(fixture.installedApplication)]
        )

        XCTAssertTrue(store.entries.isEmpty, "nothing is read before the list is opened")
        await store.refresh()
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertNil(entry.restoredAt)

        await store.restore(entry)
        XCTAssertEqual(store.lastResult?.reason, .restored)
        XCTAssertFalse(store.isWorking)
        XCTAssertEqual(try fixture.tableState(), before)
        XCTAssertNotNil(
            store.entries.first { $0.id == entry.id }?.restoredAt,
            "the list shows that it was restored"
        )
        let savedState = try XCTUnwrap(store.entries.first { $0.id == store.lastResult?.undoBackupID })
        XCTAssertEqual(savedState.summary?.outcome, .savedBeforeRestore)

        for listed in store.entries {
            await store.remove(listed)
        }
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(try Self.backupDirectories(in: fixture.recoveryRoot).isEmpty)
    }

    func testRecentDeletionTextsSayWhatWasDeletedAndWhatARestoreDiscards() throws {
        let backup = BrowserPrivacyRecoveryBackup(
            id: UUID(),
            databaseURL: URL(fileURLWithPath: "/tmp/unused/History.backup.sqlite"),
            sha256: Data(repeating: 0, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        func entry(
            _ outcome: BrowserPrivacyRecoveryOutcome?,
            restoredAt: Date? = nil
        ) -> BrowserPrivacyRecoveryEntry {
            BrowserPrivacyRecoveryEntry(
                backup: backup,
                browserID: "chrome",
                profileFingerprint: "",
                summary: outcome.map {
                    BrowserPrivacyRecoverySummary(
                        browserDisplayName: "Google Chrome",
                        profileDisplayName: "工作",
                        visitCount: 7,
                        pageCount: 3,
                        outcome: $0
                    )
                },
                restoredAt: restoredAt
            )
        }
        let defaults = TestVolatilePreferences()
        defer { defaults.restore() }

        defaults.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(BrowserPrivacyRecoveryText.title(for: entry(.deleted)), "Google Chrome · 工作")
        XCTAssertEqual(BrowserPrivacyRecoveryText.summary(for: entry(.deleted)), "删除了 7 次访问（3 个页面）")
        XCTAssertTrue(BrowserPrivacyRecoveryText.summary(for: entry(.unverified)).contains("复核未通过"))
        XCTAssertEqual(
            BrowserPrivacyRecoveryText.title(for: entry(nil)),
            "Google Chrome",
            "an older backup still names its browser"
        )
        XCTAssertTrue(
            BrowserPrivacyRecoveryText.summary(for: entry(nil)).contains("未记录"),
            "an unknown count is not shown as zero"
        )
        XCTAssertNil(BrowserPrivacyRecoveryText.restoredNote(for: entry(.deleted)))
        XCTAssertNotNil(BrowserPrivacyRecoveryText.restoredNote(for: entry(.deleted, restoredAt: Date())))
        let warning = BrowserPrivacyRecoveryText.restoreWarning(for: entry(.deleted))
        XCTAssertTrue(warning.contains("会丢弃这次删除之后新增的浏览记录"))
        XCTAssertTrue(warning.contains("请先退出 Google Chrome"))
        XCTAssertTrue(BrowserPrivacyRecoveryText.removalWarning(for: entry(.deleted)).contains("无法再撤销"))

        defaults.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(BrowserPrivacyRecoveryText.summary(for: entry(.deleted)), "Deleted 7 visits (3 pages)")
        XCTAssertTrue(BrowserPrivacyRecoveryText.restoreWarning(for: entry(.deleted)).contains("will be lost"))
    }

    // MARK: - Retention (D26) and pruning

    func testBackupCountIsPrunedOnlyAfterADeletionSucceeds() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let records = try await fixture.scannedRecords()
        func visit(_ id: Int64) throws -> BrowserPrivacyRecord {
            try XCTUnwrap(records.first { $0.locator?.visitRowID == id })
        }
        let service = fixture.recoveryService(maximumBackups: 2)
        let processor = fixture.processor(backupService: service)

        let first = await processor.process(records: [try visit(21)])
        let second = await processor.process(records: [try visit(11)])
        let firstID = try XCTUnwrap(first.entries.first?.recoveryBackupID)
        let secondID = try XCTUnwrap(second.entries.first?.recoveryBackupID)
        XCTAssertEqual(Set(service.entries().map(\.id)), [firstID, secondID])

        // Refused inside the transaction: its backup is discarded, and the
        // oldest backup must not have been pruned to make room for it.
        try fixture.execute("UPDATE visits SET is_known_to_sync = 1 WHERE id = 12")
        let refused = await processor.process(records: [try visit(12)])
        XCTAssertEqual(refused.entries.first?.reason, .syncedRecords)
        XCTAssertEqual(
            Set(service.entries().map(\.id)),
            [firstID, secondID],
            "a deletion that changed nothing must not cost an older backup"
        )

        // A successful deletion prunes to the limit, keeping the newest.
        let third = await processor.process(records: [try visit(13)])
        let thirdID = try XCTUnwrap(third.entries.first?.recoveryBackupID)
        XCTAssertEqual(service.entries().map(\.id), [thirdID, secondID])
    }

    func testBackupsStillBeingWrittenNeitherCountNorShow() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let records = try await fixture.scannedRecords()
        let service = fixture.recoveryService(maximumBackups: 1)
        let report = await fixture.processor(backupService: service)
            .process(records: records.filter { $0.locator?.visitRowID == 21 })
        let keptID = try XCTUnwrap(report.entries.first?.recoveryBackupID)
        // Another deletion has taken its backup and is still running.
        let inFlight = try await service.backup(
            source: SQLiteSnapshotSource(
                databaseURL: fixture.profile.historyDatabaseURL,
                trustedParentURL: fixture.profile.sourceTrustedParentURL
            ),
            schema: BrowserPrivacySQLiteWriteAdapter.chromiumProduction.schema,
            browserID: fixture.profile.browser.id,
            profileID: fixture.profile.id,
            deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
        )

        XCTAssertEqual(service.purgeExpired(), 0, "only kept backups count towards the limit")
        XCTAssertEqual(
            try Set(Self.backupDirectories(in: fixture.recoveryRoot)),
            [keptID.uuidString, inFlight.id.uuidString]
        )
        XCTAssertEqual(
            service.entries().map(\.id),
            [keptID],
            "a backup whose deletion is still running is not offered yet"
        )
    }

    func testExpiredBackupsAreRemovedAfterTheRetentionPeriod() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let records = try await fixture.scannedRecords()
        let service = fixture.recoveryService
        _ = await fixture.processor().process(records: records.filter { $0.locator?.visitRowID == 21 })
        _ = await fixture.processor().process(records: records.filter { $0.locator?.visitRowID == 11 })
        XCTAssertEqual(service.entries().count, 2)
        let created = try XCTUnwrap(service.entries().last?.createdAt)
        XCTAssertEqual(
            try XCTUnwrap(service.entries().last).expiresAt.timeIntervalSince(created),
            TimeInterval(BrowserPrivacyBackupRetention.days) * 86_400,
            accuracy: 0.001
        )

        // A directory left behind without its description (for example after
        // a crash) still holds a copy of the history and expires the same way.
        let orphan = fixture.recoveryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: orphan.appendingPathComponent("History.backup.sqlite").path,
            contents: Data("partial".utf8)
        ))
        // One that is being written right now is left alone.
        let inProgress = fixture.recoveryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: inProgress, withIntermediateDirectories: true)
        let longAgo = Date().addingTimeInterval(-TimeInterval(BrowserPrivacyBackupRetention.days + 1) * 86_400)
        try FileManager.default.setAttributes([.creationDate: longAgo], ofItemAtPath: orphan.path)

        XCTAssertEqual(service.purgeExpired(now: Date()), 1, "only the stale orphan is past its period")
        XCTAssertEqual(service.entries().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inProgress.path))
        XCTAssertEqual(
            service.purgeExpired(now: created.addingTimeInterval(TimeInterval(BrowserPrivacyBackupRetention.days - 1) * 86_400)),
            0,
            "nothing expires before the period ends"
        )

        // Once the period has passed, both backups go, and so does the folder
        // that was fresh above: by then it has been abandoned for a week.
        let afterPeriod = created.addingTimeInterval(TimeInterval(BrowserPrivacyBackupRetention.days) * 86_400 + 60)
        XCTAssertTrue(service.entries(now: afterPeriod).isEmpty, "an expired backup is never listed")
        XCTAssertEqual(service.purgeExpired(now: afterPeriod), 3)
        XCTAssertTrue(service.entries().isEmpty)
        XCTAssertEqual(try Self.backupDirectories(in: fixture.recoveryRoot), [])
    }

    func testExpiredBackupsArePurgedAtLaunchAndWhenThePageOpens() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"),
            encoding: .utf8
        )
        let workspace = try String(
            contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/BrowserPrivacyWorkspaceView.swift"),
            encoding: .utf8
        )
        let launch = try XCTUnwrap(app.range(of: "func applicationDidFinishLaunching"))
        XCTAssertTrue(app[launch.lowerBound...].prefix(1_200).contains("BrowserPrivacyRecoveryMaintenance.enableAndPurge()"))
        XCTAssertTrue(workspace.contains("BrowserPrivacyRecoveryMaintenance.purgeIfEnabled()"))
        // Unit tests never launch the app delegate, so a view shown by a test
        // cannot remove anything from the user's Application Support folder.
        XCTAssertFalse(BrowserPrivacyRecoveryMaintenance.isEnabled)
    }

    // MARK: - Restore (P1-2, P2-11)

    func testRestoreFirstSavesTheCurrentStateSoTheRestoreCanBeUndone() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let application = try XCTUnwrap(fixture.installedApplication)
        let selected = try await fixture.selectedRecords(visitIDs: [21])
        _ = await fixture.processor().process(records: selected)
        try fixture.execute(
            """
            INSERT INTO urls (id, url, title, visit_count, typed_count, last_visit_time, hidden)
                VALUES (50, 'https://fixture.invalid/later', NULL, 1, 0, 13324473700000000, 0);
            INSERT INTO visits (id, url, visit_time, from_visit, transition, segment_id,
                                incremented_omnibox_typed_score, visited_link_id)
                VALUES (60, 50, 13324473700000000, 0, 0, 0, 0, 0);
            """
        )
        let beforeRestore = try fixture.tableState()
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)

        let result = await fixture.processor().restore(entry, installedApplications: [application])

        XCTAssertTrue(result.succeeded, result.detail)
        let undoID = try XCTUnwrap(result.undoBackupID, "the state before the restore is saved first")
        let undo = try XCTUnwrap(fixture.recoveryService.entries().first { $0.id == undoID })
        XCTAssertEqual(undo.summary?.outcome, .savedBeforeRestore)
        XCTAssertNil(undo.summary?.visitCount, "a saved state deleted nothing, so it has no count")
        XCTAssertNotEqual(try fixture.tableState(), beforeRestore)

        let undone = await fixture.processor().restore(undo, installedApplications: [application])

        XCTAssertTrue(undone.succeeded, undone.detail)
        XCTAssertEqual(try fixture.tableState(), beforeRestore, "the restore was undone exactly")
    }

    func testRestoreFailureTextsTalkAboutRestoringNotDeleting() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let application = try XCTUnwrap(fixture.installedApplication)
        _ = await fixture.processor().process(records: try await fixture.selectedRecords(visitIDs: [21]))
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)
        try fixture.createSidecar("-wal")

        for language in [AppLanguage.zhHans, .english] {
            await withAppLanguage(language) {
                let pending = await fixture.processor().restore(entry, installedApplications: [application])
                let running = await fixture.processor(
                    runningBundleIdentifiers: [application.bundleIdentifier]
                ).restore(entry, installedApplications: [application])
                for result in [pending, running] {
                    XCTAssertFalse(result.succeeded)
                    let text = result.detail
                    for deletionWording in [
                        "在浏览器内删除", "没有删除任何记录", "删除前",
                        "delete these", "Nothing was deleted", "deleted",
                    ] {
                        XCTAssertFalse(
                            text.localizedCaseInsensitiveContains(deletionWording),
                            "\(text) borrows deletion wording: \(deletionWording)"
                        )
                    }
                    XCTAssertTrue(
                        text.contains("恢复") || text.localizedCaseInsensitiveContains("restor"),
                        text
                    )
                }
            }
        }
    }

    func testEveryRestoreReasonIsWrittenInBothLanguagesAboutRestoring() {
        func containsHan(_ text: String) -> Bool {
            text.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) }
        }
        for reason in BrowserPrivacyRestoreReason.allCases {
            let texts = reason.localizedTexts(browserName: "Google Chrome")
            XCTAssertTrue(containsHan(texts.chinese), "\(reason)")
            XCTAssertFalse(containsHan(texts.english), "\(reason)")
            for deletionWording in ["删除任何记录", "在浏览器内删除", "删除前"] {
                XCTAssertFalse(texts.chinese.contains(deletionWording), "\(reason): \(deletionWording)")
            }
            for deletionWording in ["nothing was deleted", "delete these", "deleted"] {
                XCTAssertFalse(
                    texts.english.localizedCaseInsensitiveContains(deletionWording),
                    "\(reason): \(deletionWording)"
                )
            }
        }
        XCTAssertEqual(
            Set(BrowserPrivacyRestoreReason.allCases.map {
                $0.localizedTexts(browserName: "Google Chrome").chinese
            }).count,
            BrowserPrivacyRestoreReason.allCases.count
        )
    }

    func testFailedRestoreThatTouchedNothingDropsItsSavedState() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let application = try XCTUnwrap(fixture.installedApplication)
        _ = await fixture.processor().process(records: try await fixture.selectedRecords(visitIDs: [21]))
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)
        let afterDeletion = try fixture.tableState()
        // The backup's bytes no longer match its digest: refused before writing.
        let handle = try FileHandle(forWritingTo: entry.backup.databaseURL)
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 64))
        try handle.close()

        let result = await fixture.processor().restore(entry, installedApplications: [application])

        XCTAssertEqual(result.reason, .backupUnavailable)
        XCTAssertFalse(result.historyMayHaveChanged)
        XCTAssertNil(result.undoBackupID)
        XCTAssertEqual(fixture.recoveryService.entries().map(\.id), [entry.id], "no saved state is left behind")
        XCTAssertEqual(try fixture.tableState(), afterDeletion)
    }

    func testRestoreThatCannotSaveTheCurrentStateFirstDoesNotStart() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let application = try XCTUnwrap(fixture.installedApplication)
        _ = await fixture.processor().process(records: try await fixture.selectedRecords(visitIDs: [21]))
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)
        let afterDeletion = try fixture.tableState()
        // New backups cannot be written: a file stands where their folder should be.
        let blocked = fixture.root.appendingPathComponent("BlockedRecovery")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocked.path, contents: Data("file".utf8)))
        let processor = fixture.processor(backupService: BrowserPrivacyRecoveryBackupService(
            rootURL: blocked,
            snapshotService: SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot)
        ))

        let result = await processor.restore(entry, installedApplications: [application])

        XCTAssertEqual(result.reason, .currentStateNotSaved, result.detail)
        XCTAssertFalse(result.historyMayHaveChanged)
        XCTAssertNil(result.undoBackupID)
        XCTAssertEqual(try fixture.tableState(), afterDeletion, "a restore that could not be undone is not started")
    }

    func testRestoreNamesWhyTheCurrentStateCouldNotBeSaved() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let application = try XCTUnwrap(fixture.installedApplication)
        _ = await fixture.processor().process(records: try await fixture.selectedRecords(visitIDs: [21]))
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)
        let afterDeletion = try fixture.tableState()
        // Saving the current state reads the current database, so these
        // failures are about that database, not about the backup to restore.
        let expectations: [(SQLiteSnapshotFailure, BrowserPrivacyRestoreReason)] = [
            (.permissionDenied, .permissionDenied),
            (.unavailable, .databaseChanged),
            (.busy, .databaseBusy),
            (.timedOut, .timedOut),
            (.cancelled, .cancelled),
            (.corrupt, .currentStateNotSaved),
        ]

        for (failure, expected) in expectations {
            let processor = fixture.processor(
                backupService: CurrentStateBackupFailingService(failure: failure)
            )
            let result = await processor.restore(entry, installedApplications: [application])

            XCTAssertEqual(result.reason, expected, "\(failure)")
            XCTAssertFalse(result.historyMayHaveChanged, "\(failure)")
            XCTAssertNil(result.undoBackupID, "\(failure)")
        }
        XCTAssertEqual(try fixture.tableState(), afterDeletion, "no restore was started")
    }

    func testRecoverySummaryCountsPagesTheWayTheListDoes() async throws {
        // Review probe: one address with two #fragments is two URL rows but
        // one listed page.
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute(
            """
            UPDATE urls SET url = 'https://fixture.invalid/1#a' WHERE id = 1;
            UPDATE urls SET url = 'https://fixture.invalid/1#b' WHERE id = 2;
            """
        )
        let outcome = try await fixture.scanOutcome()
        let pages = BrowserPrivacyDisplayItem.aggregate(outcome.records)
        XCTAssertEqual(pages.count, 1)

        let report = await fixture.processor().process(records: outcome.records)

        XCTAssertEqual(report.entries.first?.outcome, .deleted, report.entries.first?.detail ?? "")
        let entry = try XCTUnwrap(fixture.recoveryService.entries().first)
        XCTAssertEqual(entry.summary?.pageCount, pages.count)
        XCTAssertEqual(entry.summary?.visitCount, outcome.records.count)
    }

    func testRestoreWarningsSayWhatComesBackAndFlagOlderBackups() {
        func entry(_ profile: String, minutesAgo: Double) -> BrowserPrivacyRecoveryEntry {
            BrowserPrivacyRecoveryEntry(
                backup: BrowserPrivacyRecoveryBackup(
                    id: UUID(),
                    databaseURL: URL(fileURLWithPath: "/tmp/unused/History.backup.sqlite"),
                    sha256: Data(repeating: 0, count: 32),
                    createdAt: Date(timeIntervalSince1970: 1_750_000_000 - minutesAgo * 60)
                ),
                browserID: "chrome",
                profileFingerprint: profile,
                summary: BrowserPrivacyRecoverySummary(
                    browserDisplayName: "Google Chrome",
                    profileDisplayName: profile,
                    visitCount: 3,
                    pageCount: 2,
                    outcome: .deleted
                ),
                restoredAt: nil
            )
        }
        let oldest = entry("work", minutesAgo: 30)
        let newer = entry("work", minutesAgo: 10)
        let otherProfile = entry("home", minutesAgo: 5)
        let all = [otherProfile, newer, oldest]

        XCTAssertEqual(BrowserPrivacyRecoveryText.laterBackups(than: oldest, in: all).map(\.id), [newer.id])
        XCTAssertTrue(BrowserPrivacyRecoveryText.laterBackups(than: newer, in: all).isEmpty)
        XCTAssertNil(BrowserPrivacyRecoveryText.olderBackupWarning(for: newer, laterBackups: []))

        withAppLanguage(.zhHans) {
            let warning = BrowserPrivacyRecoveryText.restoreWarning(for: oldest)
            XCTAssertTrue(warning.contains("会丢弃这次删除之后新增的浏览记录"), warning)
            XCTAssertTrue(warning.contains("之后删除的记录也会重新出现"), warning)
            XCTAssertTrue(warning.contains("恢复前会先自动备份当前状态"), warning)
            let older = BrowserPrivacyRecoveryText.olderBackupWarning(for: oldest, laterBackups: [newer])
            XCTAssertNotNil(older)
            XCTAssertTrue(older?.contains("不是这个配置文件最近的一份备份") == true, older ?? "")
            XCTAssertTrue(older?.contains("1 份") == true, older ?? "")
            XCTAssertEqual(
                BrowserPrivacyRecoveryText.retentionNotice,
                "被删除的页面仍保存在删除前的备份里，\(BrowserPrivacyBackupRetention.days) 天后自动删除；确认无误后可在“最近的删除”里立即删除备份。"
            )
        }
        withAppLanguage(.english) {
            XCTAssertTrue(
                BrowserPrivacyRecoveryText.restoreWarning(for: oldest)
                    .contains("Records deleted after it will reappear")
            )
            XCTAssertTrue(BrowserPrivacyRecoveryText.retentionNotice.contains(
                "removed automatically after \(BrowserPrivacyBackupRetention.days) days"
            ))
        }
    }

    func testRecoveryStoreRemovesABackupByIdentifier() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let report = await fixture.processor().process(
            records: try await fixture.selectedRecords(visitIDs: [21])
        )
        let backupID = try XCTUnwrap(report.entries.first?.recoveryBackupID)
        let store = BrowserPrivacyRecoveryStore(
            service: fixture.recoveryService,
            processor: fixture.processor()
        )

        let removed = await store.remove(backupID: backupID)

        XCTAssertTrue(removed)
        XCTAssertTrue(fixture.recoveryService.entries().isEmpty)
        XCTAssertTrue(try Self.backupDirectories(in: fixture.recoveryRoot).isEmpty)
    }

    // MARK: - Third review round

    func testExpiredBackupsAreRemovedOnTimeWhileTheAppKeepsRunning() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let records = try await fixture.scannedRecords()
        let service = fixture.recoveryService
        let first = await fixture.processor().process(records: records.filter { $0.locator?.visitRowID == 21 })
        let second = await fixture.processor().process(records: records.filter { $0.locator?.visitRowID == 11 })
        let firstID = try XCTUnwrap(first.entries.first?.recoveryBackupID)
        let secondID = try XCTUnwrap(second.entries.first?.recoveryBackupID)
        let firstEntry = try XCTUnwrap(service.entries().first { $0.id == firstID })
        // The second deletion happened three days after the first.
        try Self.setCreationTime(
            firstEntry.createdAt.addingTimeInterval(3 * 86_400),
            ofBackup: secondID,
            in: fixture.recoveryRoot
        )
        let firstExpiry = firstEntry.expiresAt

        // The app has been running for days; the clock stands 90 s before the
        // first backup expires. A long longest wait keeps the test short; the
        // app itself never waits more than an hour (next test).
        let root = fixture.recoveryRoot
        let clock = ManualPurgeClock(start: firstExpiry.addingTimeInterval(-90), sleeps: 4) {
            recoveryFolderNames(in: root)
        }
        let loop = BrowserPrivacyRecoveryPurgeLoop(
            service: service,
            now: { clock.now },
            sleep: { try clock.sleep($0) },
            maximumWait: 2 * 86_400
        )

        await loop.run()

        // 90 s to the first expiry plus one; then the longest wait; then up to
        // one second after the second expiry; then the longest wait again.
        let expectedWaits: [TimeInterval] = [91, 2 * 86_400, 86_400, 2 * 86_400]
        XCTAssertEqual(clock.waits.count, expectedWaits.count)
        for (wait, expected) in zip(clock.waits, expectedWaits) {
            XCTAssertEqual(wait, expected, accuracy: 0.01)
        }
        XCTAssertEqual(clock.foldersAtEachWait, [
            [firstID.uuidString, secondID.uuidString],
            [secondID.uuidString],
            [secondID.uuidString],
            [],
        ])
        // "Removed automatically on T" in Recent Deletions is when it happens:
        // the first backup went at the check one second after its expiry.
        let removedAt = try XCTUnwrap(clock.timesOfEachWait.dropFirst().first)
        XCTAssertEqual(removedAt.timeIntervalSince(firstExpiry), 1, accuracy: 0.01)
    }

    func testScheduledChecksWaitForTheNextExpiryButNeverMoreThanAnHour() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertEqual(BrowserPrivacyRecoveryPurgeSchedule.maximumWait, 3_600)
        XCTAssertEqual(
            BrowserPrivacyRecoveryPurgeSchedule.wait(untilEarliestExpiry: now.addingTimeInterval(30), now: now),
            31,
            accuracy: 0.001,
            "wakes just after the expiry"
        )
        XCTAssertEqual(
            BrowserPrivacyRecoveryPurgeSchedule.wait(untilEarliestExpiry: now.addingTimeInterval(5 * 86_400), now: now),
            3_600,
            "a backup taken meanwhile or a changed clock is noticed within the hour"
        )
        XCTAssertEqual(BrowserPrivacyRecoveryPurgeSchedule.wait(untilEarliestExpiry: nil, now: now), 3_600)
        XCTAssertEqual(
            BrowserPrivacyRecoveryPurgeSchedule.wait(untilEarliestExpiry: now.addingTimeInterval(-10), now: now),
            3_600,
            "an expired backup that could not be removed is tried again later, not in a tight loop"
        )

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let maintenance = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/BrowserPrivacy/Support/BrowserPrivacyRecoveryMaintenance.swift"
            ),
            encoding: .utf8
        )
        let enable = try XCTUnwrap(maintenance.range(of: "static func enableAndPurge()"))
        XCTAssertTrue(
            maintenance[enable.lowerBound...].prefix(1_500).contains("BrowserPrivacyRecoveryPurgeLoop("),
            "the launch starts the scheduled checks"
        )
        XCTAssertTrue(
            maintenance.contains("ContinuousClock()"),
            "the wait keeps counting while the Mac sleeps"
        )
    }

    func testRestoringTheOldestBackupAtTheLimitKeepsThatBackup() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let application = try XCTUnwrap(fixture.installedApplication)
        let records = try await fixture.scannedRecords()
        let service = fixture.recoveryService(maximumBackups: 2)
        let processor = fixture.processor(backupService: service)
        let first = await processor.process(records: records.filter { $0.locator?.visitRowID == 21 })
        _ = await processor.process(records: records.filter { $0.locator?.visitRowID == 11 })
        let oldestID = try XCTUnwrap(first.entries.first?.recoveryBackupID)
        let oldest = try XCTUnwrap(service.entries().first { $0.id == oldestID })
        let store = BrowserPrivacyRecoveryStore(
            service: service,
            processor: processor,
            installedApplications: [application]
        )

        await store.restore(oldest)

        let result = try XCTUnwrap(store.lastResult)
        XCTAssertTrue(result.succeeded, result.detail)
        let restored = try XCTUnwrap(
            store.entries.first { $0.id == oldestID },
            "saving the state before the restore must not prune the backup being restored"
        )
        XCTAssertNotNil(restored.restoredAt)
        XCTAssertTrue(store.entries.contains { $0.id == result.undoBackupID })
        // Nor does a later check of the limit: the history now matches it,
        // so it stays until it expires.
        service.purgeExpired()
        XCTAssertTrue(service.entries().contains { $0.id == oldestID })
    }

    func testTheListRefreshAfterARestoreSparesItsSourceWhateverTheResult() async throws {
        // A restore that failed after touching the database keeps its saved
        // state and is not marked restored; the list refresh that follows
        // must not prune the backup the user may want to try again.
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = fixture.recoveryService(maximumBackups: 2)
        func backup(
            _ outcome: BrowserPrivacyRecoveryOutcome,
            sparing: Set<UUID> = []
        ) async throws -> UUID {
            let backup = try await service.backup(
                source: SQLiteSnapshotSource(
                    databaseURL: fixture.profile.historyDatabaseURL,
                    trustedParentURL: fixture.profile.sourceTrustedParentURL
                ),
                schema: BrowserPrivacySQLiteWriteAdapter.chromiumProduction.schema,
                browserID: fixture.profile.browser.id,
                profileID: fixture.profile.id,
                deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
            )
            await service.annotate(backup, summary: BrowserPrivacyRecoverySummary(
                browserDisplayName: "Google Chrome",
                profileDisplayName: "Default",
                visitCount: outcome == .savedBeforeRestore ? nil : 1,
                pageCount: outcome == .savedBeforeRestore ? nil : 1,
                outcome: outcome
            ), sparing: sparing)
            return backup.id
        }
        let source = try await backup(.deleted)
        _ = try await backup(.deleted)
        _ = try await backup(.savedBeforeRestore, sparing: [source])
        XCTAssertTrue(service.entries().contains { $0.id == source })

        service.purgeExpired(sparing: [source])

        XCTAssertTrue(service.entries().contains { $0.id == source }, "the refresh spares it too")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let store = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/BrowserPrivacy/Store/BrowserPrivacyRecoveryStore.swift"
            ),
            encoding: .utf8
        )
        let restore = try XCTUnwrap(store.range(of: "func restore(_ entry: BrowserPrivacyRecoveryEntry) async"))
        XCTAssertTrue(
            store[restore.lowerBound...].prefix(700).contains("await refresh(sparing: [entry.id])"),
            "every restore, successful or not, refreshes the list sparing its source"
        )
    }

    func testBackupsWithAnUnknownResultAreNeverPrunedButStillExpire() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = fixture.recoveryService(maximumBackups: 1)
        func backup(_ outcome: BrowserPrivacyRecoveryOutcome) async throws -> UUID {
            let backup = try await service.backup(
                source: SQLiteSnapshotSource(
                    databaseURL: fixture.profile.historyDatabaseURL,
                    trustedParentURL: fixture.profile.sourceTrustedParentURL
                ),
                schema: BrowserPrivacySQLiteWriteAdapter.chromiumProduction.schema,
                browserID: fixture.profile.browser.id,
                profileID: fixture.profile.id,
                deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
            )
            await service.annotate(backup, summary: BrowserPrivacyRecoverySummary(
                browserDisplayName: "Google Chrome",
                profileDisplayName: "Default",
                visitCount: 1,
                pageCount: 1,
                outcome: outcome
            ))
            return backup.id
        }

        let unexpected = try await backup(.unexpectedError)
        let unconfirmed = try await backup(.restoreUnconfirmed)
        _ = try await backup(.deleted)
        let newest = try await backup(.deleted)

        XCTAssertEqual(
            Set(service.entries().map(\.id)),
            [unexpected, unconfirmed, newest],
            "only backups whose result is known count towards the limit"
        )
        let afterPeriod = Date().addingTimeInterval(TimeInterval(BrowserPrivacyBackupRetention.days + 1) * 86_400)
        XCTAssertEqual(service.purgeExpired(now: afterPeriod), 3, "they still expire after the period")
        XCTAssertTrue(try Self.backupDirectories(in: fixture.recoveryRoot).isEmpty)
    }

    func testBackupsWithAnUnknownResultAskForACheckBeforeTheyExpire() {
        func entry(_ outcome: BrowserPrivacyRecoveryOutcome) -> BrowserPrivacyRecoveryEntry {
            BrowserPrivacyRecoveryEntry(
                backup: BrowserPrivacyRecoveryBackup(
                    id: UUID(),
                    databaseURL: URL(fileURLWithPath: "/tmp/unused/History.backup.sqlite"),
                    sha256: Data(repeating: 0, count: 32),
                    createdAt: Date(timeIntervalSince1970: 1_750_000_000)
                ),
                browserID: "chrome",
                profileFingerprint: "",
                summary: BrowserPrivacyRecoverySummary(
                    browserDisplayName: "Google Chrome",
                    profileDisplayName: "Default",
                    visitCount: 4,
                    pageCount: 2,
                    outcome: outcome
                ),
                restoredAt: nil
            )
        }
        let unknown: [BrowserPrivacyRecoveryOutcome] = [.restoreUnconfirmed, .unexpectedError]

        withAppLanguage(.zhHans) {
            for outcome in unknown {
                let text = BrowserPrivacyRecoveryText.summary(for: entry(outcome))
                XCTAssertFalse(text.contains("保留"), text)
                XCTAssertTrue(text.contains("到期前"), text)
            }
            let reason = BrowserPrivacyProcessingReason.restoreUnconfirmed.detail(browserName: "Google Chrome")
            XCTAssertFalse(reason.contains("保留恢复备份"), reason)
            XCTAssertTrue(reason.contains("到期前"), reason)
        }
        withAppLanguage(.english) {
            for outcome in unknown {
                let text = BrowserPrivacyRecoveryText.summary(for: entry(outcome))
                XCTAssertFalse(text.lowercased().contains("keep this backup"), text)
                XCTAssertTrue(text.contains("before"), text)
            }
            let reason = BrowserPrivacyProcessingReason.restoreUnconfirmed.detail(browserName: "Google Chrome")
            XCTAssertFalse(reason.contains("keep the recovery backup"), reason)
        }
    }

    func testRecentDeletionsSaysWhenABackupCouldNotBeDeleted() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let store = BrowserPrivacyRecoveryStore(
            service: fixture.recoveryService,
            processor: fixture.processor()
        )
        // A file, not a backup folder, stands where the backup would be.
        let blockedID = UUID()
        try FileManager.default.createDirectory(at: fixture.recoveryRoot, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: fixture.recoveryRoot.appendingPathComponent(blockedID.uuidString).path,
            contents: Data("not a backup".utf8)
        ))

        let removed = await store.remove(backupID: blockedID)

        XCTAssertFalse(removed)
        XCTAssertEqual(store.failedRemovalID, blockedID, "the failure is shown, not dropped")
        store.clearResult()
        XCTAssertNil(store.failedRemovalID)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Views/BrowserPrivacyRecentDeletionsView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(view.contains("recoveryStore.failedRemovalID == entry.id"))
        XCTAssertTrue(view.contains("BrowserPrivacyRecoveryText.removalFailure"))
        XCTAssertFalse(
            view.contains(".disabled(recoveryStore.isWorking)"),
            "deleting a backup is disabled whenever restoring is: while the page scans or deletes, too"
        )
    }

    func testRecoveryFolderIsExcludedFromTimeMachine() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        _ = await fixture.processor().process(records: try await fixture.selectedRecords(visitIDs: [21]))
        XCTAssertTrue(try Self.isExcludedFromBackup(fixture.recoveryRoot))

        // A folder an earlier version left behind is excluded the next time
        // expired backups are looked for.
        let earlier = fixture.root.appendingPathComponent("EarlierRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        XCTAssertFalse(try Self.isExcludedFromBackup(earlier))
        BrowserPrivacyRecoveryBackupService(
            rootURL: earlier,
            snapshotService: SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot)
        ).purgeExpired()
        XCTAssertTrue(try Self.isExcludedFromBackup(earlier))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let privacy = try String(contentsOf: root.appendingPathComponent("PRIVACY.md"), encoding: .utf8)
        XCTAssertFalse(privacy.contains("never leave this Mac"))
        XCTAssertFalse(privacy.contains("备份不会离开这台 Mac"))
        XCTAssertTrue(privacy.contains("excluded from Time Machine"))
        XCTAssertTrue(privacy.contains("时间机器"))
    }

    func testOnlyRealBackupFoldersAreEverExpiredOrRemoved() throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = fixture.recoveryService
        let root = fixture.recoveryRoot
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // Something outside the recovery folder that a link inside points to.
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let precious = outside.appendingPathComponent("keep.txt")
        XCTAssertTrue(manager.createFile(atPath: precious.path, contents: Data("keep".utf8)))
        let linkID = UUID()
        let link = root.appendingPathComponent(linkID.uuidString)
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        // A folder whose name is not a backup identifier, and a plain file
        // named like one.
        let foreign = root.appendingPathComponent("not-a-backup", isDirectory: true)
        try manager.createDirectory(at: foreign, withIntermediateDirectories: true)
        let fileID = UUID()
        let file = root.appendingPathComponent(fileID.uuidString)
        XCTAssertTrue(manager.createFile(atPath: file.path, contents: Data("file".utf8)))
        // A real backup folder abandoned long ago is the only thing that goes.
        let abandoned = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: abandoned, withIntermediateDirectories: true)
        let longAgo = Date().addingTimeInterval(-30 * 86_400)
        for url in [outside, foreign, abandoned] {
            try manager.setAttributes([.creationDate: longAgo], ofItemAtPath: url.path)
        }

        XCTAssertEqual(service.purgeExpired(now: Date().addingTimeInterval(30 * 86_400)), 1)
        XCTAssertFalse(manager.fileExists(atPath: abandoned.path))
        XCTAssertNotNil(try? manager.destinationOfSymbolicLink(atPath: link.path), "the link itself stays")
        XCTAssertTrue(manager.fileExists(atPath: precious.path), "nothing behind a link is touched")
        XCTAssertTrue(manager.fileExists(atPath: foreign.path))
        XCTAssertTrue(manager.fileExists(atPath: file.path))

        XCTAssertFalse(service.remove(backupID: linkID))
        XCTAssertFalse(service.remove(backupID: fileID))
        XCTAssertNotNil(try? manager.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(manager.fileExists(atPath: precious.path))
        XCTAssertTrue(manager.fileExists(atPath: file.path))
    }

    func testTheSavedStateIsDescribedTheSameWhicheverBackupWasRestored() {
        let entry = BrowserPrivacyRecoveryEntry(
            backup: BrowserPrivacyRecoveryBackup(
                id: UUID(),
                databaseURL: URL(fileURLWithPath: "/tmp/unused/History.backup.sqlite"),
                sha256: Data(repeating: 0, count: 32),
                createdAt: Date(timeIntervalSince1970: 1_750_000_000)
            ),
            browserID: "chrome",
            profileFingerprint: "",
            summary: BrowserPrivacyRecoverySummary(
                browserDisplayName: "Google Chrome",
                profileDisplayName: "Default",
                visitCount: nil,
                pageCount: nil,
                outcome: .savedBeforeRestore
            ),
            restoredAt: nil
        )
        withAppLanguage(.zhHans) {
            // Restoring the newest backup saves the state just the same.
            XCTAssertEqual(
                BrowserPrivacyRecoveryText.summary(for: entry),
                "恢复备份之前自动保存的状态，用它可以撤销那次恢复"
            )
        }
    }

    private static func setCreationTime(_ date: Date, ofBackup id: UUID, in root: URL) throws {
        let url = root.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        metadata["createdAt"] = date.timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: metadata).write(to: url, options: .atomic)
    }

    private static func isExcludedFromBackup(_ url: URL) throws -> Bool {
        // A new URL, so no cached resource value is read.
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    private func withAppLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestVolatilePreferences()
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        defer { defaults.restore() }
        try body()
    }

    private func withAppLanguage(
        _ language: AppLanguage,
        _ body: () async throws -> Void
    ) async rethrows {
        let defaults = TestVolatilePreferences()
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        defer { defaults.restore() }
        try await body()
    }

    private static func backupDirectories(in root: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { UUID(uuidString: $0) != nil }
    }
}

/// The names of the backup-like folders under a recovery root.
private func recoveryFolderNames(in root: URL) -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return Set(names.filter { UUID(uuidString: $0) != nil })
}

/// A clock the scheduled purge reads and sleeps on. Every sleep is recorded
/// with the time it started and the backup folders present then, and moves
/// the clock forward; after `sleeps` sleeps it ends the loop.
private final class ManualPurgeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private let allowedSleeps: Int
    private let observe: @Sendable () -> Set<String>
    private var recordedWaits: [TimeInterval] = []
    private var recordedTimes: [Date] = []
    private var recordedFolders: [Set<String>] = []

    init(start: Date, sleeps: Int, observe: @escaping @Sendable () -> Set<String>) {
        current = start
        allowedSleeps = sleeps
        self.observe = observe
    }

    var now: Date { lock.withLock { current } }
    var waits: [TimeInterval] { lock.withLock { recordedWaits } }
    var timesOfEachWait: [Date] { lock.withLock { recordedTimes } }
    var foldersAtEachWait: [Set<String>] { lock.withLock { recordedFolders } }

    func sleep(_ seconds: TimeInterval) throws {
        let folders = observe()
        try lock.withLock {
            guard recordedWaits.count < allowedSleeps else { throw CancellationError() }
            recordedWaits.append(seconds)
            recordedTimes.append(current)
            recordedFolders.append(folders)
            current = current.addingTimeInterval(seconds)
        }
    }
}

/// Fails the backup a restore takes of the current state first; nothing else
/// is reached.
private struct CurrentStateBackupFailingService: BrowserPrivacyDatabaseBackingUp {
    let failure: SQLiteSnapshotFailure

    func backup(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        browserID: String,
        profileID: String,
        deadlineNanoseconds: UInt64
    ) async throws -> BrowserPrivacyRecoveryBackup {
        throw failure
    }
}
