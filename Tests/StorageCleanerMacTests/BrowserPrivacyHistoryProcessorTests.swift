import CSQLite
import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class BrowserPrivacyHistoryProcessorTests: XCTestCase {
    func testChromiumDeletesOnlySelectedVisitAndScannerReadsRemainingRow() async throws {
        try await assertSuccessfulSelectedVisitDeletion(engine: .chromium)
    }

    func testSafariDeletesOnlySelectedVisitAndScannerReadsRemainingRow() async throws {
        try await assertSuccessfulSelectedVisitDeletion(engine: .safari)
    }

    func testFirefoxDeletesOnlySelectedVisitAndScannerReadsRemainingRow() async throws {
        try await assertSuccessfulSelectedVisitDeletion(engine: .firefox)
    }

    func testFirefoxVisitDeletionPreservesEveryBookmarkPrimaryKey() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .firefox)
        try fixture.createFirefoxBookmarks()
        let before = try fixture.firefoxBookmarkIDs()
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first)

        let report = await fixture.processor().process(records: [selected])

        XCTAssertEqual(report.entries.first?.outcome, .deleted)
        XCTAssertEqual(try fixture.firefoxBookmarkIDs(), before)
    }

    func testMissingLocatorRollsBackEarlierDeletionInSameProfileTransaction() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let records = try await fixture.scannedRecords().sorted {
            ($0.locator?.visitRowID ?? .min) < ($1.locator?.visitRowID ?? .min)
        }
        let vanishedRowID = try XCTUnwrap(records.last?.locator).visitRowID
        try fixture.deleteVisitRow(rowID: vanishedRowID)

        let report = await fixture.processor().process(records: records)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertEqual(entry.capability, .verifiedVisitDeletion)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(entry.reason, .recordMissing)
        XCTAssertEqual(
            try fixture.remainingVisitRowIDs(),
            [try XCTUnwrap(records.first?.locator).visitRowID],
            "the first row deletion must be undone when a later locator is missing"
        )
    }

    func testReusedRowIDWithDifferentVisitIdentityIsNeverDeleted() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let scannedRecords = try await fixture.scannedRecords()
        let record = try XCTUnwrap(scannedRecords.first)
        let locator = try XCTUnwrap(record.locator)
        try fixture.replaceChromiumVisitRow(
            rowID: locator.visitRowID,
            url: "https://new-after-scan.example/",
            rawTimestamp: 13_324_473_699_000_000
        )

        let report = await fixture.processor().process(records: [record])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(entry.reason, .recordChanged)
        XCTAssertTrue(try fixture.remainingVisitRowIDs().contains(locator.visitRowID))
    }

    func testRunningBrowserRefusesWriteAndLeavesDatabaseUntouched() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let records = try await fixture.scannedRecords()
        let record = try XCTUnwrap(records.first)
        let processor = fixture.processor(
            runningBundleIdentifiers: [try XCTUnwrap(record.browser.bundleIdentifier)]
        )

        let report = await processor.process(records: [record])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertEqual(entry.capability, .verifiedVisitDeletion)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(entry.reason, .browserRunning)
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
    }

    func testFailureDetailFollowsTheAppLanguageAndNamesTheRealCause() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let records = try await fixture.scannedRecords()
        let record = try XCTUnwrap(records.first)
        let processor = fixture.processor(
            runningBundleIdentifiers: [try XCTUnwrap(record.browser.bundleIdentifier)]
        )
        let defaults = TestVolatilePreferences()
        defer { defaults.restore() }

        defaults.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        let chineseReport = await processor.process(records: [record])
        let chinese = try XCTUnwrap(chineseReport.entries.first)
        XCTAssertTrue(chinese.detail.contains("正在运行"), chinese.detail)
        XCTAssertTrue(chinese.detail.contains(record.browser.displayName), chinese.detail)
        XCTAssertFalse(chinese.detail.localizedCaseInsensitiveContains("still running"), chinese.detail)

        defaults.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        let englishReport = await processor.process(records: [record])
        let english = try XCTUnwrap(englishReport.entries.first)
        XCTAssertTrue(english.detail.localizedCaseInsensitiveContains("still running"), english.detail)
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
    }

    func testEveryProcessingReasonIsWrittenInBothLanguagesWithoutJargon() throws {
        let jargon = [
            "schema", "sidecar", "sqlite", "wal", "locator", "rollback", "adapter",
            "visit id", "frecency", "parent counter", "derived index",
        ]
        func containsHan(_ text: String) -> Bool {
            text.unicodeScalars.contains { (0x4E00 ... 0x9FFF).contains($0.value) }
        }
        var texts: [(String, String, String)] = BrowserPrivacyProcessingReason.allCases.map {
            let pair = $0.localizedTexts(browserName: "Chrome")
            return ("\($0)", pair.chinese, pair.english)
        }
        for blocker in BrowserPrivacyDirectDeletionBlocker.allCases {
            for engine in [BrowserPrivacyEngine.safari, .chromium, .firefox] {
                let pair = blocker.localizedTexts(browserName: "Chrome", engine: engine)
                texts.append(("\(blocker)/\(engine)", pair.chinese, pair.english))
            }
        }
        for (name, chinese, english) in texts {
            XCTAssertTrue(containsHan(chinese), name)
            XCTAssertFalse(containsHan(english), name)
            XCTAssertFalse(english.isEmpty, name)
            for word in jargon {
                XCTAssertFalse(
                    chinese.localizedCaseInsensitiveContains(word),
                    "\(name): Chinese text must not fall back to the term \(word)"
                )
            }
        }
        XCTAssertEqual(
            Set(BrowserPrivacyProcessingReason.allCases.map {
                $0.localizedTexts(browserName: "Chrome").chinese
            }).count,
            BrowserPrivacyProcessingReason.allCases.count,
            "every reason says something different"
        )

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/BrowserPrivacy/Processing/BrowserPrivacyHistoryProcessor.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains("detail: \""),
            "processing details come from BrowserPrivacyProcessingReason, not literals"
        )
    }

    func testReportEntryIDsStayUniqueWhenBothPartsOfAProfileEndInTheBrowser() async throws {
        // Review probe: visit 12 is synced (manual at scan time); the other
        // visits are refused because of unmerged writes. Both entries end as
        // manual handling for the same profile and feed one ForEach.
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute("UPDATE visits SET is_known_to_sync = 1 WHERE id = 12")
        let outcome = try await fixture.scanOutcome()
        XCTAssertEqual(outcome.records.filter { $0.locator == nil }.count, 1)
        try fixture.createSidecar("-wal")
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: outcome.records)

        let ids = report.entries.map(\.id)
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate report entry ids: \(ids)")
        XCTAssertEqual(
            Set(report.entries.map(\.deletionPath)),
            [.direct, .inBrowser]
        )
        XCTAssertEqual(try fixture.tableState(), before, "nothing may be written")
    }

    func testTimeoutInsideTheTransactionRollsBackWithoutRestoringTheBackup() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(visitIDs: [12, 21])
        let before = try fixture.tableState()
        let hook = ProcessorTestFlag()
        // The deadline passes while the write transaction is open.
        let processor = fixture.processor(inTransactionHook: { control in
            hook.set()
            control.timeout()
        })

        let report = await processor.process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertTrue(hook.value, "the hook must run inside the transaction")
        XCTAssertEqual(entry.outcome, .failed, entry.detail)
        XCTAssertEqual(entry.reason, .timedOut, "the transaction is rolled back, not restored from the backup")
        XCTAssertNil(entry.recoveryBackupID, "a rolled-back change keeps no backup")
        XCTAssertTrue(fixture.recoveryService.entries().isEmpty)
        XCTAssertEqual(try fixture.tableState(), before)
        XCTAssertEqual(try fixture.rows("PRAGMA quick_check"), ["ok"])
    }

    func testUnexpectedErrorKeepsTheBackupWithASummaryAndSaysTheResultIsUnknown() async throws {
        struct UnplannedError: Error {}
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(visitIDs: [12, 21])
        let before = try fixture.tableState()
        let processor = fixture.processor(inTransactionHook: { _ in throw UnplannedError() })

        let report = await processor.process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed, entry.detail)
        XCTAssertEqual(entry.reason, .unexpectedError)
        let texts = BrowserPrivacyProcessingReason.unexpectedError.localizedTexts(browserName: "Google Chrome")
        XCTAssertTrue(texts.chinese.contains("未预期"), texts.chinese)
        XCTAssertFalse(texts.chinese.contains("没有删除任何记录"), "the result is not known")
        XCTAssertFalse(texts.english.localizedCaseInsensitiveContains("nothing was deleted"))
        let backupID = try XCTUnwrap(entry.recoveryBackupID, "the backup is kept while the result is unknown")
        let kept = try XCTUnwrap(fixture.recoveryService.entries().first { $0.id == backupID })
        XCTAssertEqual(kept.summary?.outcome, .unexpectedError)
        XCTAssertEqual(kept.summary?.visitCount, 2)
        XCTAssertEqual(try fixture.tableState(), before, "the transaction itself was rolled back")
    }

    func testRecordsWithoutLocatorDoNotHoldBackTheRestOfTheProfile() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let records = try await fixture.scannedRecords().sorted {
            ($0.locator?.visitRowID ?? .min) < ($1.locator?.visitRowID ?? .min)
        }
        let deletable = try XCTUnwrap(records.first)
        let unlocated = try XCTUnwrap(records.last).withLocator(nil)

        let report = await fixture.processor().process(records: [deletable, unlocated])

        XCTAssertEqual(report.selectedRecordCount, 2)
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(Set(report.entries.map(\.id)).count, 2, "entries stay distinguishable in a list")
        let deleted = try XCTUnwrap(report.entries.first { $0.outcome == .deleted })
        let manual = try XCTUnwrap(report.entries.first { $0.outcome == .manual })
        XCTAssertEqual(deleted.verifiedDeletedRecordIDs, [deletable.id])
        XCTAssertEqual(deleted.recordCount, 1)
        XCTAssertEqual(manual.recordCount, 1)
        XCTAssertEqual(manual.reason, .manualOnly)
        XCTAssertEqual(report.manualRecordCount, 1)
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [12])
    }

    func testBackupFailurePreventsAnyHistoryMutation() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let records = try await fixture.scannedRecords()
        let record = try XCTUnwrap(records.first)

        let report = await fixture.processor(
            backupService: FailingBrowserPrivacyBackupService()
        ).process(records: [record])

        XCTAssertEqual(report.entries.first?.outcome, .failed)
        XCTAssertTrue(report.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
    }

    func testUnexpectedErrorBeforeAnyWriteSaysNothingWasChanged() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let records = try await fixture.scannedRecords()
        let record = try XCTUnwrap(records.first)

        let report = await fixture.processor(
            backupService: FailingBrowserPrivacyBackupService(error: UnplannedBackupError())
        ).process(records: [record])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertEqual(entry.reason, .unexpectedErrorBeforeChanges)
        XCTAssertNil(entry.recoveryBackupID)
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
    }

    func testUnwritableRecoveryFolderSaysTheBackupFailed() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(visitIDs: [21])
        let before = try fixture.tableState()
        // A file where the recovery folder should be.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: fixture.recoveryRoot.path,
            contents: Data("not a folder".utf8)
        ))

        let report = await fixture.processor().process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed, entry.detail)
        XCTAssertEqual(entry.reason, .backupFailed, "the backup failed, not the browser's database")
        XCTAssertNil(entry.recoveryBackupID)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testDatabasePathMismatchFailsClosedWithoutChangingHistory() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let scannedRecords = try await fixture.scannedRecords()
        let original = try XCTUnwrap(scannedRecords.first)
        let originalLocator = try XCTUnwrap(original.locator)
        let mismatchedLocator = BrowserPrivacyRecordLocator(
            providerID: originalLocator.providerID,
            profileID: originalLocator.profileID,
            engine: originalLocator.engine,
            visitRowID: originalLocator.visitRowID,
            parentRowID: originalLocator.parentRowID,
            visitTimestampIdentity: originalLocator.visitTimestampIdentity,
            rawURL: originalLocator.rawURL,
            databaseURL: fixture.root.appendingPathComponent("wrong/History"),
            trustedParentURL: originalLocator.trustedParentURL,
            identityChain: originalLocator.identityChain
        )

        let report = await fixture.processor().process(
            records: [original.withLocator(mismatchedLocator)]
        )
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertTrue(
            [.databaseUnavailable, .databaseChanged].contains(entry.reason),
            "\(String(describing: entry.reason))"
        )
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
    }

    func testSymlinkSwapBeforeWriteFailsClosedWithoutChangingTarget() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let scannedRecords = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(scannedRecords.first)

        try fixture.replaceHistoryWithSymlink()

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertTrue(
            [.databaseUnavailable, .databaseChanged].contains(entry.reason),
            "\(String(describing: entry.reason))"
        )
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
    }

    func testSchemaMismatchFailsClosedWithoutChangingHistory() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let scannedRecords = try await fixture.scannedRecords()
        let record = try XCTUnwrap(scannedRecords.first)
        try fixture.renameVisitTableForSchemaMismatch()

        let report = await fixture.processor().process(records: [record])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(entry.reason, .schemaUnsupported)
        XCTAssertEqual(try fixture.remainingVisitRowIDs(table: "visits_backup"), [11, 12])
    }

    func testCommittedReadBackFailureIsIndeterminateAndKeepsOtherDataUntouched() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let scannedRecords = try await fixture.scannedRecords()
        let record = try XCTUnwrap(scannedRecords.first)
        let rowID = try XCTUnwrap(record.locator).visitRowID
        let processor = fixture.processor(
            beforeReadBackHook: { [fixture] in
                try? fixture.reinsertChromiumVisit(rowID: rowID)
            }
        )

        let report = await processor.process(records: [record])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .indeterminate)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(entry.reason, .committedButUnverified)
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
    }

    func testOnlyHistoryVisitRowsChangeAndProtectedDataRemainsUntouched() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        try fixture.createProtectedDataTables()
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first)
        let untouchedProtectedData = try fixture.protectedDataRows()

        let report = await fixture.processor().process(records: [selected])

        XCTAssertEqual(report.entries.first?.outcome, .deleted)
        XCTAssertEqual(try fixture.protectedDataRows(), untouchedProtectedData)
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11])
    }

    func testProviderWithoutWriteAdapterStaysManualAndLeavesDatabaseUntouched() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(
            engine: .firefox,
            hasWriteCapability: false
        )
        let records = try await fixture.scannedRecords(expectsLocator: false)
        let record = try XCTUnwrap(records.first)

        let report = await fixture.processor().process(records: [record])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .manual)
        XCTAssertEqual(entry.capability, .manualBrowserGuidance)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(entry.reason, .manualOnly)
        XCTAssertEqual(
            entry.detail,
            BrowserPrivacyDirectDeletionBlocker.browserNotSupported.detail(
                browserName: record.browser.displayName,
                engine: .firefox
            )
        )
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
    }

    func testWALProfileUsesTransactionAndStillVerifiesSelectedVisitDeletion() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let walDatabase = try fixture.openWALConnection()
        defer { sqlite3_close_v2(walDatabase) }
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first)
        let selectedRowID = try XCTUnwrap(selected.locator).visitRowID

        let report = await fixture.processor().process(records: [selected])

        XCTAssertEqual(report.entries.first?.outcome, .deleted)
        XCTAssertFalse(try fixture.remainingVisitRowIDs().contains(selectedRowID))
    }

    func testBusyWriterRefusesCommitAndLeavesAllVisitRows() async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: .chromium)
        let lockingDatabase = try fixture.openImmediateWriteTransaction()
        defer {
            sqlite3_exec(lockingDatabase, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(lockingDatabase)
        }
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first)

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(entry.reason, .databaseBusy)
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
    }

    func testCommittedButUnverifiedRecordsStaySeparateFromFailedAndDeletedCounts() {
        let browser = BrowserPrivacyBrowser(
            id: "fixture",
            displayName: "Fixture",
            engine: .chromium,
            bundleIdentifier: "com.storagecleaner.fixture",
            version: "1"
        )
        let report = BrowserPrivacyProcessingReport(
            selectedRecordCount: 2,
            entries: [
                BrowserPrivacyProcessingEntry(
                    browser: browser,
                    profileID: "Default",
                    recordCount: 2,
                    capability: .verifiedVisitDeletion,
                    outcome: .indeterminate,
                    detail: "Re-scan required"
                ),
            ]
        )

        XCTAssertEqual(report.indeterminateRecordCount, 2)
        XCTAssertEqual(report.failedRecordCount, 0)
        XCTAssertEqual(report.verifiedDeletedRecordCount, 0)
    }

    func testChromiumV70FixtureMutationUpdatesDependentTablesAtomically() async throws {
        let fixture = try ChromiumV70HistoryFixture()
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first {
            $0.locator?.visitRowID == ChromiumV70HistoryFixture.selectedVisitID
        })
        let segmentsBefore = try fixture.rows(
            "SELECT id, url_id FROM segments ORDER BY id"
        )
        let segmentUsageBefore = try fixture.rows(
            "SELECT id, segment_id, time_slot, visit_count FROM segment_usage ORDER BY id"
        )

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .deleted, entry.detail)
        XCTAssertEqual(entry.capability, .verifiedVisitDeletion)
        XCTAssertEqual(entry.verifiedDeletedRecordIDs, Set([selected.id]))
        XCTAssertNotNil(entry.recoveryBackupID)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 12"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visit_source WHERE id = 12"), 0)
        XCTAssertEqual(
            try fixture.scalar("SELECT COUNT(*) FROM context_annotations WHERE visit_id = 12"),
            0
        )
        XCTAssertEqual(
            try fixture.scalar("SELECT COUNT(*) FROM content_annotations WHERE visit_id = 12"),
            0
        )
        XCTAssertEqual(try fixture.scalar("SELECT from_visit FROM visits WHERE id = 13"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT visit_count FROM urls WHERE id = 1"), 2)
        XCTAssertEqual(try fixture.scalar("SELECT typed_count FROM urls WHERE id = 1"), 0)
        XCTAssertEqual(
            try fixture.scalar("SELECT last_visit_time FROM urls WHERE id = 1"),
            ChromiumV70HistoryFixture.latestRemainingVisitTime
        )
        XCTAssertEqual(try fixture.rows("SELECT id, url_id FROM segments ORDER BY id"), segmentsBefore)
        XCTAssertEqual(
            try fixture.rows(
                "SELECT id, segment_id, time_slot, visit_count FROM segment_usage ORDER BY id"
            ),
            segmentUsageBefore
        )
    }

    func testChromiumV70FixtureDeletesLastVisitTogetherWithItsURLRow() async throws {
        let fixture = try ChromiumV70HistoryFixture()
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first {
            $0.locator?.visitRowID == ChromiumV70HistoryFixture.onlyVisitID
        })
        var expected = try fixture.tableState()
        expected["urls"] = expected["urls"]?.filter { !$0.hasPrefix("2\u{1f}") }
        expected["visits"] = expected["visits"]?.filter { !$0.hasPrefix("21\u{1f}") }

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .deleted, entry.detail)
        XCTAssertEqual(entry.capability, .verifiedVisitDeletion)
        XCTAssertEqual(entry.verifiedDeletedRecordIDs, Set([selected.id]))
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 21"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM urls WHERE id = 2"), 0)
        XCTAssertEqual(
            try fixture.tableState(),
            expected,
            "only the page's own visit and URL row may disappear"
        )
    }

    func testChromiumV70FixtureRollsBackEveryTableWhenURLUpdateFails() async throws {
        let fixture = try ChromiumV70HistoryFixture(failURLUpdate: true)
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first {
            $0.locator?.visitRowID == ChromiumV70HistoryFixture.selectedVisitID
        })
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertNotEqual(entry.outcome, .deleted)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testChromiumV70FixtureRequiresMarkerWithoutChangingAnyTable() async throws {
        let fixture = try ChromiumV70HistoryFixture()
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first {
            $0.locator?.visitRowID == ChromiumV70HistoryFixture.selectedVisitID
        })
        let before = try fixture.tableState()
        try fixture.removeMarker()

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .unsupported)
        XCTAssertEqual(entry.capability, .unsupported)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testRegisteredProvidersExposeOnlyVersionedChromiumProductionAdapter() {
        let providers = BrowserPrivacyProviderRegistry.defaultProviders
        XCTAssertEqual(providers.count, 14)
        XCTAssertTrue(providers.filter { $0.descriptor.engine == .chromium }
            .allSatisfy { $0.historyWriteAdapter == .chromiumProduction })
        XCTAssertTrue(providers.filter { $0.descriptor.engine != .chromium }
            .allSatisfy { $0.historyWriteAdapter == nil })
    }

    func testChromeV70ProductionDeletesSafeSubsetWithoutMarkerAndKeepsUnrelatedRows() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        XCTAssertFalse(fixture.hasMarker)
        try fixture.execute(
            """
            INSERT INTO clusters_and_visits
                (cluster_id, visit_id, score, engagement_score, url_for_deduping,
                 normalized_url, url_for_display, interaction_state)
                VALUES (1, 11, 0, 0, 'a', 'a', 'a', 0);
            INSERT INTO cluster_visit_duplicates VALUES (11, 21);
            INSERT INTO visited_links
                (id, link_url_id, top_level_url, frame_url, visit_count)
                VALUES (1, 1, 'a', 'a', 1);
            INSERT INTO keyword_search_terms VALUES (1, 1, 'a', 'a');
            """
        )
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first {
            $0.locator?.visitRowID == ChromiumV70HistoryFixture.selectedVisitID
        })

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .deleted, entry.detail)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 12"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visit_source WHERE id = 12"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM context_annotations WHERE visit_id = 12"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM content_annotations WHERE visit_id = 12"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT from_visit FROM visits WHERE id = 13"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM clusters_and_visits"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM cluster_visit_duplicates"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visited_links"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM keyword_search_terms"), 1)
    }

    func testRegisteredChromiumProviderRejectsUnauditedSchemaVersion80WithoutWriting() async throws {
        let fixture = try ChromiumV70HistoryFixture(
            mode: .production,
            providerID: "edge",
            browserVersion: "stable-123",
            schemaVersion: "80"
        )
        let outcome = try await fixture.scanOutcome()
        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil })
        let selected = try XCTUnwrap(outcome.records.first)
        let before = try fixture.tableState()
        let report = await fixture.processor().process(records: [selected])

        XCTAssertNotEqual(report.entries.first?.outcome, .deleted)
        XCTAssertTrue(report.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testProductionUnknownSchemaVersionStaysReadableWithoutLocatorOrWrite() async throws {
        let fixture = try ChromiumV70HistoryFixture(
            mode: .production,
            schemaVersion: "unknown"
        )
        let outcome = try await fixture.scanOutcome()
        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil })
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: [try XCTUnwrap(outcome.records.first)])

        XCTAssertNotEqual(report.entries.first?.outcome, .deleted)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testProductionRejectsWrongLastCompatibleVersionWithoutLocatorOrWrite() async throws {
        let fixture = try ChromiumV70HistoryFixture(
            mode: .production,
            lastCompatibleVersion: "17"
        )
        let outcome = try await fixture.scanOutcome()
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil })
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: [try XCTUnwrap(outcome.records.first)])

        XCTAssertNotEqual(report.entries.first?.outcome, .deleted)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testProductionRequiresInstalledApplicationAndCompleteSigningEvidence() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let valid = try XCTUnwrap(fixture.installedApplication)
        let invalidApplications: [[BrowserPrivacyInstalledApplication]] = [
            [],
            [BrowserPrivacyInstalledApplication(
                bundleIdentifier: valid.bundleIdentifier,
                version: valid.version,
                url: valid.url,
                isDefaultBrowser: false,
                canOpenWebURLs: true,
                signingIdentity: nil
            )],
            [BrowserPrivacyInstalledApplication(
                bundleIdentifier: valid.bundleIdentifier,
                version: valid.version,
                url: valid.url,
                isDefaultBrowser: false,
                canOpenWebURLs: true,
                signingIdentity: StartupApplicationSigningIdentity(
                    teamIdentifier: nil,
                    codeSigningIdentifier: valid.bundleIdentifier,
                    designatedRequirement: "identifier \"\(valid.bundleIdentifier)\""
                )
            )],
            [BrowserPrivacyInstalledApplication(
                bundleIdentifier: valid.bundleIdentifier,
                version: valid.version,
                url: valid.url,
                isDefaultBrowser: false,
                canOpenWebURLs: true,
                signingIdentity: StartupApplicationSigningIdentity(
                    teamIdentifier: "FIXTURETEAM",
                    codeSigningIdentifier: "com.example.mismatch",
                    designatedRequirement: "identifier \"com.example.mismatch\""
                )
            )],
            [BrowserPrivacyInstalledApplication(
                bundleIdentifier: valid.bundleIdentifier,
                version: valid.version,
                url: valid.url,
                isDefaultBrowser: false,
                canOpenWebURLs: true,
                signingIdentity: StartupApplicationSigningIdentity(
                    teamIdentifier: "FIXTURETEAM",
                    codeSigningIdentifier: valid.bundleIdentifier,
                    designatedRequirement: nil
                )
            )],
            [BrowserPrivacyInstalledApplication(
                bundleIdentifier: valid.bundleIdentifier,
                version: valid.version,
                url: fixture.root,
                isDefaultBrowser: false,
                canOpenWebURLs: true,
                signingIdentity: valid.signingIdentity
            )],
        ]
        let before = try fixture.tableState()

        for applications in invalidApplications {
            let outcome = try await fixture.scanOutcome(installedApplications: applications)
            XCTAssertEqual(outcome.records.count, 4)
            XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil })
            let report = await fixture.processor().process(
                records: [try XCTUnwrap(outcome.records.first)]
            )
            XCTAssertNotEqual(report.entries.first?.outcome, .deleted)
        }
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testProductionRejectsLocatorOutsideRegisteredRootWithoutWriting() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first)
        let locator = try XCTUnwrap(selected.locator)
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        let mismatched = BrowserPrivacyRecordLocator(
            providerID: locator.providerID,
            profileID: locator.profileID,
            engine: locator.engine,
            visitRowID: locator.visitRowID,
            parentRowID: locator.parentRowID,
            visitTimestampIdentity: locator.visitTimestampIdentity,
            rawURL: locator.rawURL,
            databaseURL: outside.appendingPathComponent("History"),
            trustedParentURL: outside,
            identityChain: locator.identityChain
        )
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: [selected.withLocator(mismatched)])

        XCTAssertNotEqual(report.entries.first?.outcome, .deleted)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testProductionSidecarRequiresManualHandlingWithoutWriting() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first)
        let before = try fixture.tableState()
        try fixture.createSidecar("-wal")

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .manual, entry.detail)
        XCTAssertEqual(entry.capability, .manualBrowserGuidance)
        XCTAssertEqual(entry.reason, .pendingWrites)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testProductionDeletesNextToTheEmptyJournalAChromiumBrowserLeavesBehind() async throws {
        // Chromium uses journal_mode=TRUNCATE: after a normal quit an empty
        // "History-journal" stays beside "History". It holds no transaction.
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.createSidecar("-journal", contents: Data())
        let selected = try await fixture.selectedRecords(
            visitIDs: [ChromiumV70HistoryFixture.onlyVisitID]
        )

        let report = await fixture.processor().process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .deleted, entry.detail)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM urls WHERE id = 2"), 0)
        XCTAssertEqual(try fixture.rows("PRAGMA quick_check"), ["ok"])
        let reread = try await fixture.scanOutcome()
        XCTAssertEqual(reread.records.count, 3)
    }

    func testProductionRefusesEveryOtherSidecarWithoutWriting() async throws {
        // A journal with content, and any WAL or shared-memory file (even an
        // empty one), mean writes that have not been merged.
        let sidecars: [(suffix: String, contents: Data)] = [
            ("-journal", Data("active".utf8)),
            ("-journal", Data(repeating: 0, count: 1)),
            ("-wal", Data()),
            ("-wal", Data("active".utf8)),
            ("-shm", Data()),
        ]
        for sidecar in sidecars {
            let fixture = try ChromiumV70HistoryFixture(mode: .production)
            let selected = try await fixture.selectedRecords(visitIDs: [12])
            let before = try fixture.tableState()
            try fixture.createSidecar(sidecar.suffix, contents: sidecar.contents)

            let report = await fixture.processor().process(records: selected)
            let entry = try XCTUnwrap(report.entries.first)

            let name = "\(sidecar.suffix) (\(sidecar.contents.count) bytes)"
            XCTAssertEqual(entry.outcome, .manual, name)
            XCTAssertEqual(entry.reason, .pendingWrites, name)
            XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty, name)
            XCTAssertTrue(fixture.sidecarExists(sidecar.suffix), "the sidecar itself is left alone")
            try FileManager.default.removeItem(
                atPath: fixture.profile.historyDatabaseURL.path + sidecar.suffix
            )
            XCTAssertEqual(try fixture.tableState(), before, name)
        }

        // A journal that is not a regular file is never accepted as empty.
        let linked = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await linked.selectedRecords(visitIDs: [12])
        let before = try linked.tableState()
        let target = linked.root.appendingPathComponent("empty-target")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        try FileManager.default.createSymbolicLink(
            atPath: linked.profile.historyDatabaseURL.path + "-journal",
            withDestinationPath: target.path
        )
        let report = await linked.processor().process(records: selected)
        XCTAssertEqual(report.entries.first?.reason, .pendingWrites)
        try FileManager.default.removeItem(atPath: linked.profile.historyDatabaseURL.path + "-journal")
        XCTAssertEqual(try linked.tableState(), before)
    }

    func testChromeV70ProductionRemovesClusterReferencesAndEmptiedClusters() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute(ChromiumV70HistoryFixture.clusterRowsSQL)
        let selected = try await fixture.selectedRecords(visitIDs: [12])

        let report = await fixture.processor().process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .deleted, entry.detail)
        XCTAssertEqual(
            try fixture.rows(
                "SELECT cluster_id, visit_id FROM clusters_and_visits ORDER BY cluster_id, visit_id"
            ),
            ["1\u{1f}11"],
            "the deleted visit leaves every cluster; other members stay"
        )
        XCTAssertEqual(
            try fixture.rows(
                "SELECT visit_id, duplicate_visit_id FROM cluster_visit_duplicates ORDER BY visit_id, duplicate_visit_id"
            ),
            ["11\u{1f}21"],
            "duplicate links are removed on either side of the deleted visit"
        )
        XCTAssertEqual(
            try fixture.rows("SELECT cluster_id, label FROM clusters ORDER BY cluster_id"),
            ["1\u{1f}kept"],
            "a cluster left without visits is deleted like Chromium does"
        )
        XCTAssertEqual(
            try fixture.rows("SELECT cluster_id, keyword FROM cluster_keywords ORDER BY cluster_id"),
            ["1\u{1f}kept-keyword"],
            "keywords of an emptied cluster must not outlive its visits"
        )
    }

    func testChromeV70ProductionCleansClustersWithoutOptionalClusterTables() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute(ChromiumV70HistoryFixture.clusterRowsSQL)
        try fixture.execute("DROP TABLE clusters; DROP TABLE cluster_keywords;")
        let selected = try await fixture.selectedRecords(visitIDs: [12])

        let report = await fixture.processor().process(records: selected)

        XCTAssertEqual(report.entries.first?.outcome, .deleted, report.entries.first?.detail ?? "")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM clusters_and_visits WHERE visit_id = 12"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM clusters_and_visits"), 1)
    }

    func testChromeV70ProductionUnknownClusterTableShapeMintsNoLocatorAndIsNeverWritten() async throws {
        let reshapeKeywords = """
        DROP TABLE cluster_keywords;
        CREATE TABLE cluster_keywords (id INTEGER PRIMARY KEY, word TEXT);
        """
        let triggerOnClusters = """
        CREATE TABLE cluster_audit (cluster_id INTEGER);
        CREATE TRIGGER clusters_audit AFTER DELETE ON clusters
            BEGIN INSERT INTO cluster_audit VALUES (old.cluster_id); END;
        """

        // Known at scan time: the profile is readable but offers no direct deletion.
        for alteration in [reshapeKeywords, triggerOnClusters] {
            let fixture = try ChromiumV70HistoryFixture(mode: .production)
            try fixture.execute(ChromiumV70HistoryFixture.clusterRowsSQL)
            try fixture.execute(alteration)
            let outcome = try await fixture.scanOutcome()
            XCTAssertEqual(outcome.records.count, 4)
            XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil }, alteration)
            let before = try fixture.tableState()

            let report = await fixture.processor().process(
                records: [try XCTUnwrap(outcome.records.first)]
            )

            XCTAssertNotEqual(report.entries.first?.outcome, .deleted)
            XCTAssertEqual(try fixture.tableState(), before)
        }

        // Changed between scan and confirmation: the write is refused.
        for alteration in [reshapeKeywords, triggerOnClusters] {
            let fixture = try ChromiumV70HistoryFixture(mode: .production)
            try fixture.execute(ChromiumV70HistoryFixture.clusterRowsSQL)
            let selected = try await fixture.selectedRecords(visitIDs: [12])
            try fixture.execute(alteration)
            let before = try fixture.tableState()

            let report = await fixture.processor().process(records: selected)

            XCTAssertNotEqual(report.entries.first?.outcome, .deleted, alteration)
            XCTAssertTrue(report.verifiedDeletedRecordIDs.isEmpty)
            XCTAssertEqual(try fixture.tableState(), before, alteration)
        }
    }

    func testChromeV70ProductionAdjustsVisitedLinkCountsLikeChromium() async throws {
        let partial = try ChromiumV70HistoryFixture(mode: .production)
        try partial.execute(ChromiumV70HistoryFixture.visitedLinkRowsSQL)
        let one = try await partial.selectedRecords(visitIDs: [12])
        let partialReport = await partial.processor().process(records: one)
        XCTAssertEqual(partialReport.entries.first?.outcome, .deleted, partialReport.entries.first?.detail ?? "")
        XCTAssertEqual(
            try partial.rows("SELECT id, link_url_id, visit_count FROM visited_links ORDER BY id"),
            ["1\u{1f}1\u{1f}1", "2\u{1f}2\u{1f}5"],
            "one of two visits through the link is gone; the unrelated link is untouched"
        )

        let whole = try ChromiumV70HistoryFixture(mode: .production)
        try whole.execute(ChromiumV70HistoryFixture.visitedLinkRowsSQL)
        let both = try await whole.selectedRecords(visitIDs: [12, 13])
        let wholeReport = await whole.processor().process(records: both)
        XCTAssertEqual(wholeReport.entries.first?.outcome, .deleted, wholeReport.entries.first?.detail ?? "")
        XCTAssertEqual(
            try whole.rows("SELECT id, link_url_id, visit_count FROM visited_links ORDER BY id"),
            ["2\u{1f}2\u{1f}5"],
            "a visited link without remaining visits is deleted"
        )

        let dangling = try ChromiumV70HistoryFixture(mode: .production)
        try dangling.execute("UPDATE visits SET visited_link_id = 99 WHERE id = 12")
        let orphan = try await dangling.selectedRecords(visitIDs: [12])
        let danglingReport = await dangling.processor().process(records: orphan)
        XCTAssertEqual(
            danglingReport.entries.first?.outcome,
            .deleted,
            "a visited-link id without a row is ignored, as Chromium does"
        )
    }

    func testChromeV70ProductionRejectsVisitedLinkOwnedByAnotherURLWithoutWriting() async throws {
        try await assertChromeV70ProductionRejectsWithoutMutation(
            reason: .inconsistentData
        ) { fixture in
            try fixture.execute(ChromiumV70HistoryFixture.visitedLinkRowsSQL)
            // Link 2 belongs to URL 2 while visit 12 belongs to URL 1.
            try fixture.execute("UPDATE visits SET visited_link_id = 2 WHERE id = 12")
        }
    }

    func testChromeV70ProductionLeavesSyncedVisitsToTheBrowserWithoutWriting() async throws {
        // Deleting a synced visit only on this Mac would leave its copies in
        // the account and on other devices. The scan already withholds the
        // locator for such a visit; this is the write path's own check, for
        // a visit that the browser synced between the scan and the deletion.
        for marker in [
            "is_known_to_sync = 1",
            "originator_cache_guid = 'sync'",
            "originator_visit_id = 9",
            "originator_from_visit = 8",
            "originator_opener_visit = 7",
        ] {
            let fixture = try ChromiumV70HistoryFixture(mode: .production)
            let selected = try await fixture.selectedRecords(visitIDs: [12, 21])
            try fixture.execute("UPDATE visits SET \(marker) WHERE id = 12")
            let before = try fixture.tableState()

            let report = await fixture.processor().process(records: selected)
            let entry = try XCTUnwrap(report.entries.first)

            XCTAssertEqual(entry.outcome, .manual, marker)
            XCTAssertEqual(entry.capability, .manualBrowserGuidance, marker)
            XCTAssertEqual(entry.reason, .syncedRecords, marker)
            XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
            XCTAssertEqual(try fixture.tableState(), before, marker)
        }
    }

    func testChromeV70ProductionKeepsOpenerColumnOfOtherVisitsUntouched() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute("UPDATE visits SET opener_visit = 12 WHERE id = 13")
        let selected = try await fixture.selectedRecords(visitIDs: [12])

        let report = await fixture.processor().process(records: selected)

        XCTAssertEqual(report.entries.first?.outcome, .deleted, report.entries.first?.detail ?? "")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 12"), 0)
        XCTAssertEqual(
            try fixture.scalar("SELECT opener_visit FROM visits WHERE id = 13"),
            12,
            "Chromium's own visit deletion repairs from_visit only; opener_visit is left as it is"
        )
        XCTAssertEqual(try fixture.scalar("SELECT from_visit FROM visits WHERE id = 13"), 0)
    }

    func testChromeV70ProductionDeletesTheOnlyVisitOfAPageAndItsURLRow() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute(
            """
            INSERT INTO keyword_search_terms VALUES (5, 2, 'only term', 'only term');
            INSERT INTO keyword_search_terms VALUES (5, 1, 'kept term', 'kept term');
            INSERT INTO segments VALUES (9, 'http://fixture.invalid/', 2);
            INSERT INTO segment_usage VALUES (90, 9, 13324473600000000, 1);
            """
        )
        let selected = try await fixture.selectedRecords(
            visitIDs: [ChromiumV70HistoryFixture.onlyVisitID]
        )
        var expected = try fixture.tableState()
        expected["urls"] = expected["urls"]?.filter { !$0.hasPrefix("2\u{1f}") }
        expected["visits"] = expected["visits"]?.filter { !$0.hasPrefix("21\u{1f}") }
        expected["production_visit_metadata"] = expected["production_visit_metadata"]?
            .filter { !$0.hasPrefix("21\u{1f}") }
        expected["segments"] = expected["segments"]?.filter { !$0.hasPrefix("9\u{1f}") }
        expected["segment_usage"] = expected["segment_usage"]?.filter { !$0.hasPrefix("90\u{1f}") }
        expected["keyword_search_terms"] = ["5\u{1f}1"]

        let report = await fixture.processor().process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .deleted, entry.detail)
        XCTAssertEqual(entry.capability, .verifiedVisitDeletion)
        XCTAssertEqual(entry.verifiedDeletedRecordIDs, Set(selected.map(\.id)))
        XCTAssertNotNil(entry.recoveryBackupID)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE url = 2"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM urls WHERE id = 2"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM keyword_search_terms WHERE url_id = 2"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM segments WHERE url_id = 2"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM segment_usage WHERE segment_id = 9"), 0)
        XCTAssertEqual(
            try fixture.tableState(),
            expected,
            "rows that do not belong to the deleted page must stay byte-for-byte the same"
        )

        let reread = try await fixture.scanOutcome()
        XCTAssertEqual(reread.records.count, 3)
        XCTAssertFalse(reread.records.contains { $0.url == "https://fixture.invalid/2" })
    }

    func testChromeV70ProductionDeletesEveryVisitOfAMultiVisitPage() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(visitIDs: [11, 12, 13])
        let urlTwoBefore = try fixture.rows(
            "SELECT id, url, title, visit_count, typed_count, last_visit_time, hidden FROM urls WHERE id = 2"
        )
        let visitTwentyOneBefore = try fixture.rows("SELECT * FROM visits WHERE id = 21")

        let report = await fixture.processor().process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .deleted, entry.detail)
        XCTAssertEqual(entry.verifiedDeletedRecordIDs, Set(selected.map(\.id)))
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE url = 1"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM urls WHERE id = 1"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visit_source"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM context_annotations"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM content_annotations"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM segments"), 0)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM segment_usage"), 0)
        XCTAssertEqual(
            try fixture.rows(
                "SELECT id, url, title, visit_count, typed_count, last_visit_time, hidden FROM urls WHERE id = 2"
            ),
            urlTwoBefore
        )
        XCTAssertEqual(try fixture.rows("SELECT * FROM visits WHERE id = 21"), visitTwentyOneBefore)
    }

    func testChromeV70ProductionPartialDeleteKeepsURLRowWithChromiumCounters() async throws {
        // Two of three visits, one of them typed: both counters follow Chromium.
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(visitIDs: [12, 13])
        let report = await fixture.processor().process(records: selected)
        XCTAssertEqual(report.entries.first?.outcome, .deleted, report.entries.first?.detail ?? "")
        XCTAssertEqual(
            try fixture.rows("SELECT visit_count, typed_count, last_visit_time FROM urls WHERE id = 1"),
            ["1\u{1f}0\u{1f}13324473601000000"],
            "the URL row survives with the remaining visit's time"
        )
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE url = 1"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM segments WHERE url_id = 1"), 1)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM segment_usage"), 1)

        // A reload never incremented visit_count, so removing it must not decrement it.
        let reload = try ChromiumV70HistoryFixture(mode: .production)
        try reload.execute("UPDATE visits SET transition = 805306376 WHERE id = 13")
        let reloadVisit = try await reload.selectedRecords(visitIDs: [13])
        let reloadReport = await reload.processor().process(records: reloadVisit)
        XCTAssertEqual(reloadReport.entries.first?.outcome, .deleted, reloadReport.entries.first?.detail ?? "")
        XCTAssertEqual(
            try reload.rows("SELECT visit_count, typed_count, last_visit_time FROM urls WHERE id = 1"),
            ["3\u{1f}1\u{1f}13324473602000000"]
        )

        // Chromium clamps at zero when the stored counter is already lower than
        // the visits being removed; the page must stay deletable.
        let clamped = try ChromiumV70HistoryFixture(mode: .production)
        try clamped.execute("UPDATE urls SET visit_count = 1, typed_count = 0 WHERE id = 1")
        let clampedVisits = try await clamped.selectedRecords(visitIDs: [11, 12])
        let clampedReport = await clamped.processor().process(records: clampedVisits)
        XCTAssertEqual(clampedReport.entries.first?.outcome, .deleted, clampedReport.entries.first?.detail ?? "")
        XCTAssertEqual(
            try clamped.rows("SELECT visit_count, typed_count, last_visit_time FROM urls WHERE id = 1"),
            ["0\u{1f}0\u{1f}13324473603000000"]
        )
    }

    func testChromeV70ProductionRepairsReferrerChainsLikeChromium() async throws {
        // 11 <- 12 <- 13 (URL 1) and 13 <- 21 (URL 2).
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute(
            """
            UPDATE visits SET from_visit = 11 WHERE id = 12;
            UPDATE visits SET from_visit = 12 WHERE id = 13;
            UPDATE visits SET from_visit = 13 WHERE id = 21;
            """
        )
        let middle = try await fixture.selectedRecords(visitIDs: [12, 13])
        let report = await fixture.processor().process(records: middle)
        XCTAssertEqual(report.entries.first?.outcome, .deleted, report.entries.first?.detail ?? "")
        XCTAssertEqual(
            try fixture.scalar("SELECT from_visit FROM visits WHERE id = 21"),
            11,
            "a visit reached through two deleted visits inherits their referrer"
        )

        // A referrer that no longer exists is passed on unchanged, and a
        // segment id without a segment row does not block the deletion.
        let dangling = try ChromiumV70HistoryFixture(mode: .production)
        try dangling.execute(
            """
            UPDATE visits SET from_visit = 999, segment_id = 55 WHERE id = 12;
            """
        )
        let one = try await dangling.selectedRecords(visitIDs: [12])
        let danglingReport = await dangling.processor().process(records: one)
        XCTAssertEqual(danglingReport.entries.first?.outcome, .deleted, danglingReport.entries.first?.detail ?? "")
        XCTAssertEqual(try dangling.scalar("SELECT from_visit FROM visits WHERE id = 13"), 999)
    }

    func testChromeV70ProductionRejectsReferrerCycleWithoutWriting() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute(
            """
            UPDATE visits SET from_visit = 13 WHERE id = 12;
            UPDATE visits SET from_visit = 12 WHERE id = 13;
            """
        )
        let selected = try await fixture.selectedRecords(visitIDs: [12, 13])
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .unsupported, entry.detail)
        XCTAssertEqual(entry.reason, .inconsistentData)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testChromeV70ProductionReadBackCoversTheRemovedURLRow() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(
            visitIDs: [ChromiumV70HistoryFixture.onlyVisitID]
        )
        // Something recreates the URL row after COMMIT and before the
        // read-only check: the page must not be reported as deleted.
        let processor = fixture.processor(beforeReadBackHook: { [fixture] in
            try? fixture.execute(
                """
                INSERT INTO urls (id, url, title, visit_count, typed_count, last_visit_time, hidden)
                    VALUES (2, 'https://fixture.invalid/2', NULL, 1, 0, 13324473604000000, 0)
                """
            )
        })

        let report = await processor.process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .indeterminate, entry.detail)
        XCTAssertEqual(entry.reason, .committedButUnverified)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertNotNil(entry.recoveryBackupID)
    }

    func testChromeV70ProductionDeletesALargeSelectionAcrossManyPages() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        // 900 extra pages with two visits each (ids 1000...).
        var sql = "BEGIN;"
        for index in 0 ..< 900 {
            let urlID = 1_000 + index
            let firstVisit = 10_000 + index * 2
            let time = 13_324_480_000_000_000 + Int64(index) * 10
            sql += """
            INSERT INTO urls (id, url, title, visit_count, typed_count, last_visit_time, hidden)
                VALUES (\(urlID), 'https://bulk.invalid/page/\(index)', 'Page \(index)', 2, 0, \(time + 1), 0);
            INSERT INTO visits (id, url, visit_time, from_visit, transition, segment_id,
                                incremented_omnibox_typed_score, visited_link_id)
                VALUES (\(firstVisit), \(urlID), \(time), 0, 0, 0, 0, 0);
            INSERT INTO visits (id, url, visit_time, from_visit, transition, segment_id,
                                incremented_omnibox_typed_score, visited_link_id)
                VALUES (\(firstVisit + 1), \(urlID), \(time + 1), \(firstVisit), 0, 0, 0, 0);
            INSERT INTO keyword_search_terms VALUES (1, \(urlID), 'term \(index)', 'term \(index)');
            """
        }
        sql += "COMMIT;"
        try fixture.execute(sql)

        let outcome = try await fixture.scanOutcome()
        XCTAssertEqual(outcome.records.count, 4 + 1_800)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator != nil })
        // Whole pages 0..<500 (1000 visits) and the newer visit of pages 500..<800.
        let selected = outcome.records.filter { record in
            guard let locator = record.locator, locator.parentRowID >= 1_000 else { return false }
            let page = Int(locator.parentRowID) - 1_000
            if page < 500 { return true }
            return page < 800 && locator.visitRowID % 2 == 1
        }
        XCTAssertEqual(selected.count, 1_300)

        let report = await fixture.processor().process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .deleted, entry.detail)
        XCTAssertEqual(entry.verifiedDeletedRecordIDs.count, 1_300)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM urls"), 2 + 400)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits"), 4 + 300 + 200)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM keyword_search_terms"), 400)
        XCTAssertEqual(
            try fixture.scalar("SELECT COUNT(*) FROM visits WHERE url NOT IN (SELECT id FROM urls)"),
            0,
            "no visit may point at a removed URL"
        )
        XCTAssertEqual(
            try fixture.scalar(
                "SELECT COUNT(*) FROM urls WHERE id >= 1500 AND id < 1800 AND visit_count = 1 AND last_visit_time % 10 = 0"
            ),
            300,
            "partially deleted pages keep the older visit's time and one count"
        )
        XCTAssertEqual(
            try fixture.scalar("SELECT COUNT(*) FROM urls WHERE id >= 1800 AND visit_count = 2"),
            100,
            "untouched pages are unchanged"
        )
        XCTAssertEqual(
            try fixture.rows("SELECT visit_count, typed_count, last_visit_time FROM urls WHERE id = 1"),
            ["3\u{1f}1\u{1f}13324473603000000"]
        )
    }

    func testChromeV70ProductionRollsBackPageDeletionWhenALaterURLUpdateFails() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production, failURLUpdate: true)
        try fixture.execute(
            """
            INSERT INTO keyword_search_terms VALUES (5, 2, 'only term', 'only term');
            INSERT INTO segments VALUES (9, 'http://fixture.invalid/', 2);
            INSERT INTO segment_usage VALUES (90, 9, 13324473600000000, 1);
            """
        )
        // Visit 21 removes URL 2 completely; visit 12 needs a counter update on
        // URL 1, which the fixture's CHECK constraint refuses.
        let selected = try await fixture.selectedRecords(visitIDs: [21, 12])
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: selected)
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertNotEqual(entry.outcome, .deleted)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(try fixture.tableState(), before, "every table must be rolled back together")
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM urls"), 2)
    }

    func testChromeV70ProductionRejectsNonAliasedVisitIDWithoutWriting() async throws {
        try await assertChromeV70ProductionSchemaRejectedWithoutMutation(
            .nonAliasedVisitID
        )
    }

    func testChromeV70ProductionRejectsDeclaredForeignKeyWithoutWriting() async throws {
        try await assertChromeV70ProductionSchemaRejectedWithoutMutation(
            .declaredForeignKey
        )
    }

    func testChromiumV70FixtureAuthorizerRejectsUnrelatedWrites() {
        XCTAssertEqual(
            authorizationResult(action: SQLITE_DELETE, table: "cookies"),
            SQLITE_DENY
        )
        XCTAssertEqual(
            authorizationResult(action: SQLITE_UPDATE, table: "urls", column: "title"),
            SQLITE_DENY
        )
        XCTAssertEqual(
            authorizationResult(action: SQLITE_INSERT, table: "visits"),
            SQLITE_DENY
        )
        XCTAssertEqual(
            authorizationResult(action: SQLITE_CREATE_TABLE, table: "unexpected"),
            SQLITE_DENY
        )
        XCTAssertEqual(
            authorizationResult(action: SQLITE_ATTACH, table: "other.sqlite"),
            SQLITE_DENY
        )
    }

    func testChromeV70ProductionAuthorizerAllowsOnlyThePageDeletionWriteSet() {
        func result(_ action: Int32, _ table: String, _ column: String? = nil) -> Int32 {
            authorizationResult(
                adapter: .chromeV70Production,
                action: action,
                table: table,
                column: column
            )
        }

        // Rows that belong to a deleted visit or to a URL without visits.
        for table in [
            "visits", "visit_source", "context_annotations", "content_annotations",
            "clusters_and_visits", "cluster_visit_duplicates", "clusters", "cluster_keywords",
            "visited_links", "urls", "keyword_search_terms", "segments", "segment_usage",
        ] {
            XCTAssertEqual(result(SQLITE_DELETE, table), SQLITE_OK, table)
        }
        XCTAssertEqual(result(SQLITE_UPDATE, "visits", "from_visit"), SQLITE_OK)
        XCTAssertEqual(result(SQLITE_UPDATE, "urls", "visit_count"), SQLITE_OK)
        XCTAssertEqual(result(SQLITE_UPDATE, "urls", "typed_count"), SQLITE_OK)
        XCTAssertEqual(result(SQLITE_UPDATE, "urls", "last_visit_time"), SQLITE_OK)
        XCTAssertEqual(result(SQLITE_UPDATE, "visited_links", "visit_count"), SQLITE_OK)

        // Everything else stays denied.
        for table in ["meta", "downloads", "downloads_url_chains", "cookies", "sqlite_sequence"] {
            XCTAssertEqual(result(SQLITE_DELETE, table), SQLITE_DENY, table)
        }
        XCTAssertEqual(result(SQLITE_UPDATE, "urls", "title"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_UPDATE, "urls", "url"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_UPDATE, "visits", "opener_visit"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_UPDATE, "visits", "visit_time"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_UPDATE, "visited_links", "link_url_id"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_UPDATE, "meta", "value"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_INSERT, "visits"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_INSERT, "urls"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_CREATE_TABLE, "unexpected"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_DROP_TABLE, "urls"), SQLITE_DENY)
        XCTAssertEqual(result(SQLITE_ATTACH, "other.sqlite"), SQLITE_DENY)
    }

    private func assertSuccessfulSelectedVisitDeletion(
        engine: BrowserPrivacyEngine
    ) async throws {
        let fixture = try BrowserPrivacyHistoryFixture(engine: engine)
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first)
        let selectedRowID = try XCTUnwrap(selected.locator).visitRowID
        let untouchedRowID = try XCTUnwrap(records.first { $0.id != selected.id }?.locator).visitRowID

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(report.selectedRecordCount, 1)
        XCTAssertEqual(entry.outcome, .deleted, entry.detail)
        XCTAssertEqual(entry.capability, .verifiedVisitDeletion)
        XCTAssertEqual(entry.verifiedDeletedRecordIDs, Set([selected.id]))
        XCTAssertEqual(report.verifiedDeletedRecordIDs, Set([selected.id]))
        XCTAssertNotNil(entry.recoveryBackupID)
        XCTAssertFalse(try fixture.remainingVisitRowIDs().contains(selectedRowID))
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [untouchedRowID])

        let reread = try await fixture.scannedRecords(expectedCount: 1)
        XCTAssertEqual(try XCTUnwrap(reread.first?.locator).visitRowID, untouchedRowID)
    }

    private func assertChromeV70ProductionRejectsWithoutMutation(
        selectedVisitID: Int64 = ChromiumV70HistoryFixture.selectedVisitID,
        reason: BrowserPrivacyProcessingReason,
        prepare: (ChromiumV70HistoryFixture) throws -> Void
    ) async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try prepare(fixture)
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first {
            $0.locator?.visitRowID == selectedVisitID
        })
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .unsupported, entry.detail)
        XCTAssertEqual(entry.capability, .unsupported)
        XCTAssertEqual(entry.reason, reason)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    private func assertChromeV70ProductionSchemaRejectedWithoutMutation(
        _ schemaMutation: ChromiumV70HistoryFixture.ProductionSchemaMutation
    ) async throws {
        let fixture = try ChromiumV70HistoryFixture(
            mode: .production,
            productionSchemaMutation: schemaMutation
        )
        let outcome = try await fixture.scanOutcome(
            adapter: .verified(for: .chromium)
        )
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator != nil })
        let selected = try XCTUnwrap(outcome.records.first)
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .unsupported, entry.detail)
        XCTAssertEqual(entry.capability, .unsupported)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(try fixture.tableState(), before)
    }

    private func authorizationResult(
        adapter: BrowserPrivacySQLiteWriteAdapter = .chromiumV70Fixture,
        action: Int32,
        table: String,
        column: String? = nil
    ) -> Int32 {
        let authorizer = BrowserPrivacySQLiteWriteAuthorizer(adapter: adapter)
        let context = Unmanaged.passUnretained(authorizer).toOpaque()
        return table.withCString { tablePointer in
            guard let column else {
                return browserPrivacySQLiteAuthorizer(
                    context, action, tablePointer, nil, nil, nil
                )
            }
            return column.withCString { columnPointer in
                browserPrivacySQLiteAuthorizer(
                    context, action, tablePointer, columnPointer, nil, nil
                )
            }
        }
    }
}

private extension BrowserPrivacyRecord {
    func withLocator(_ locator: BrowserPrivacyRecordLocator?) -> Self {
        Self(
            id: id,
            browser: browser,
            profileID: profileID,
            source: source,
            url: url,
            domain: domain,
            title: title,
            searchKeyword: searchKeyword,
            visitedAt: visitedAt,
            visitCount: visitCount,
            category: category,
            selectionConfidence: selectionConfidence,
            sizeBytes: sizeBytes,
            locator: locator
        )
    }
}

/// Set from a hook that runs on another thread.
final class ProcessorTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}

private struct FixedBrowserPrivacyRunningApplicationChecker:
    BrowserPrivacyRunningApplicationChecking {
    let runningBundleIdentifiers: Set<String>

    func runningBundleIdentifiers(
        matching bundleIdentifiers: Set<String>
    ) async -> Set<String> {
        runningBundleIdentifiers.intersection(bundleIdentifiers)
    }
}

private struct UnplannedBackupError: Error {}

private struct FailingBrowserPrivacyBackupService: BrowserPrivacyDatabaseBackingUp {
    var error: any Error = SQLiteSnapshotFailure.unavailable

    func backup(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        browserID: String,
        profileID: String,
        deadlineNanoseconds: UInt64
    ) async throws -> BrowserPrivacyRecoveryBackup {
        throw error
    }
}

private struct BrowserPrivacyHistoryFixtureProvider: BrowserHistoryProvider {
    let descriptor: BrowserPrivacyProviderDescriptor
    let profile: BrowserPrivacyProfile
    let historyWriteAdapter: BrowserPrivacySQLiteWriteAdapter?

    func discoverProfiles(
        homeDirectory: URL,
        installedApplications: [BrowserPrivacyInstalledApplication]
    ) -> BrowserPrivacyProviderDiscovery {
        let application = installedApplications.first {
            descriptor.bundleIdentifiers.contains($0.bundleIdentifier)
        }
        let requiresProductionEvidence = historyWriteAdapter == .chromiumProduction
        let browser = BrowserPrivacyBrowser(
            id: profile.browser.id,
            displayName: profile.browser.displayName,
            engine: profile.browser.engine,
            bundleIdentifier: application?.bundleIdentifier
                ?? (requiresProductionEvidence ? nil : profile.browser.bundleIdentifier),
            version: application?.version
                ?? (requiresProductionEvidence ? nil : profile.browser.version),
            applicationURL: application?.url,
            signingIdentity: application?.signingIdentity
        )
        let discoveredProfile = BrowserPrivacyProfile(
            id: profile.id,
            browser: browser,
            displayName: profile.displayName,
            historyDatabaseURL: profile.historyDatabaseURL,
            sourceTrustedParentURL: profile.sourceTrustedParentURL
        )
        return BrowserPrivacyProviderDiscovery(
            coverage: BrowserPrivacyProviderCoverage(
                browser: browser,
                availability: .available,
                profileCount: 1,
                recordCount: 0,
                detail: nil
            ),
            profiles: [discoveredProfile]
        )
    }
}

private final class BrowserPrivacyHistoryFixture {
    let engine: BrowserPrivacyEngine
    let root: URL
    let snapshotRoot: URL
    let profile: BrowserPrivacyProfile
    let provider: BrowserPrivacyHistoryFixtureProvider

    init(
        engine: BrowserPrivacyEngine,
        hasWriteCapability: Bool = true
    ) throws {
        self.engine = engine
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrowserPrivacyHistoryProcessorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let profileRoot = root.appendingPathComponent("Profile", isDirectory: true)
        snapshotRoot = root.appendingPathComponent("Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        let databaseURL = profileRoot.appendingPathComponent(Self.databaseName(for: engine))
        let browser = BrowserPrivacyBrowser(
            id: "fixture-\(engine.rawValue)",
            displayName: "Fixture \(engine.rawValue.capitalized)",
            engine: engine,
            bundleIdentifier: "com.storagecleaner.fixture.\(engine.rawValue)",
            version: "1.0"
        )
        profile = BrowserPrivacyProfile(
            id: "\(browser.id):Default",
            browser: browser,
            displayName: "Default",
            historyDatabaseURL: databaseURL,
            sourceTrustedParentURL: profileRoot
        )
        provider = BrowserPrivacyHistoryFixtureProvider(
            descriptor: BrowserPrivacyProviderDescriptor(
                id: browser.id,
                displayName: browser.displayName,
                engine: engine,
                bundleIdentifiers: [browser.bundleIdentifier!],
                profileRootRelativePaths: []
            ),
            profile: profile,
            historyWriteAdapter: hasWriteCapability
                ? BrowserPrivacySQLiteWriteAdapter.verified(for: engine)
                : nil
        )

        let database = try Self.open(at: databaseURL)
        defer { sqlite3_close_v2(database) }
        try Self.execute(Self.fixtureSQL(for: engine), database: database)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func scannedRecords(
        expectedCount: Int = 2,
        expectsLocator: Bool = true
    ) async throws -> [BrowserPrivacyRecord] {
        let outcome = try await BrowserPrivacyRecordScanner(
            registry: registry,
            snapshotService: SQLiteSnapshotService(temporaryRoot: snapshotRoot),
            homeDirectory: root,
            installedApplications: [],
            limits: BrowserPrivacyRecordScanLimits(totalTimeoutSeconds: 2)
        ).scan()
        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.records.count, expectedCount)
        XCTAssertEqual(outcome.records.allSatisfy { $0.locator != nil }, expectsLocator)
        return outcome.records
    }

    var registry: BrowserPrivacyProviderRegistry {
        BrowserPrivacyProviderRegistry(providers: [provider])
    }

    func processor(
        runningBundleIdentifiers: Set<String> = [],
        backupService: (any BrowserPrivacyDatabaseBackingUp)? = nil,
        beforeReadBackHook: (@Sendable () -> Void)? = nil
    ) -> BrowserPrivacyHistoryProcessor {
        let resolvedBackupService: any BrowserPrivacyDatabaseBackingUp = backupService
            ?? BrowserPrivacyRecoveryBackupService(
                rootURL: root.appendingPathComponent("Recovery", isDirectory: true),
                snapshotService: SQLiteSnapshotService(temporaryRoot: snapshotRoot)
            )
        return BrowserPrivacyHistoryProcessor(
            registry: registry,
            runningApplicationChecker: FixedBrowserPrivacyRunningApplicationChecker(
                runningBundleIdentifiers: runningBundleIdentifiers
            ),
            backupService: resolvedBackupService,
            homeDirectory: root,
            busyRetrySeconds: 0.2,
            operationTimeoutSeconds: 2,
            beforeReadBackHook: beforeReadBackHook
        )
    }

    func deleteVisitRow(rowID: Int64) throws {
        let table = BrowserPrivacySQLiteWriteAdapter.verified(for: engine).visitTable
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        let statement = try Self.prepare(
            "DELETE FROM \(table) WHERE rowid = ?1",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, rowID) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(database) == 1 else {
            throw BrowserPrivacyHistoryFixtureError.sqlite
        }
    }

    func replaceChromiumVisitRow(
        rowID: Int64,
        url: String,
        rawTimestamp: Int64
    ) throws {
        guard engine == .chromium else { throw BrowserPrivacyHistoryFixtureError.sqlite }
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        try Self.execute("BEGIN IMMEDIATE", database: database)
        do {
            let delete = try Self.prepare(
                "DELETE FROM visits WHERE rowid = ?1",
                database: database
            )
            defer { sqlite3_finalize(delete) }
            guard sqlite3_bind_int64(delete, 1, rowID) == SQLITE_OK,
                  sqlite3_step(delete) == SQLITE_DONE else {
                throw BrowserPrivacyHistoryFixtureError.sqlite
            }
            try Self.execute(
                "INSERT INTO urls VALUES (99, '\(url)', 'New', 1)",
                database: database
            )
            let insert = try Self.prepare(
                "INSERT INTO visits (id, url, visit_time) VALUES (?1, 99, ?2)",
                database: database
            )
            defer { sqlite3_finalize(insert) }
            guard sqlite3_bind_int64(insert, 1, rowID) == SQLITE_OK,
                  sqlite3_bind_int64(insert, 2, rawTimestamp) == SQLITE_OK,
                  sqlite3_step(insert) == SQLITE_DONE else {
                throw BrowserPrivacyHistoryFixtureError.sqlite
            }
            try Self.execute("COMMIT", database: database)
        } catch {
            try? Self.execute("ROLLBACK", database: database)
            throw error
        }
    }

    func remainingVisitRowIDs(table: String? = nil) throws -> [Int64] {
        let table = table ?? BrowserPrivacySQLiteWriteAdapter.verified(for: engine).visitTable
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        let statement = try Self.prepare(
            "SELECT rowid FROM \(table) ORDER BY rowid",
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var identifiers: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            identifiers.append(sqlite3_column_int64(statement, 0))
        }
        return identifiers
    }

    func renameVisitTableForSchemaMismatch() throws {
        guard engine == .chromium else { throw BrowserPrivacyHistoryFixtureError.sqlite }
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        try Self.execute("ALTER TABLE visits RENAME TO visits_backup", database: database)
    }

    func replaceHistoryWithSymlink() throws {
        let targetURL = root.appendingPathComponent("History-target.sqlite")
        try FileManager.default.copyItem(at: profile.historyDatabaseURL, to: targetURL)
        try FileManager.default.removeItem(at: profile.historyDatabaseURL)
        try FileManager.default.createSymbolicLink(
            at: profile.historyDatabaseURL,
            withDestinationURL: targetURL
        )
    }

    func reinsertChromiumVisit(rowID: Int64) throws {
        guard engine == .chromium else { throw BrowserPrivacyHistoryFixtureError.sqlite }
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        let statement = try Self.prepare(
            "INSERT INTO visits (id, url, visit_time) VALUES (?1, 1, ?2)",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, rowID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, 13_324_473_600_000_000) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw BrowserPrivacyHistoryFixtureError.sqlite
        }
    }

    func createProtectedDataTables() throws {
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        try Self.execute(
            """
            CREATE TABLE cookies (id INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE passwords (id INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE bookmarks (id INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE autofill (id INTEGER PRIMARY KEY, value TEXT);
            INSERT INTO cookies VALUES (1, 'cookie');
            INSERT INTO passwords VALUES (1, 'password');
            INSERT INTO bookmarks VALUES (1, 'bookmark');
            INSERT INTO autofill VALUES (1, 'autofill');
            """,
            database: database
        )
    }

    func createFirefoxBookmarks() throws {
        guard engine == .firefox else { throw BrowserPrivacyHistoryFixtureError.sqlite }
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        try Self.execute(
            """
            CREATE TABLE moz_bookmarks (
                id INTEGER PRIMARY KEY,
                fk INTEGER NOT NULL,
                title TEXT
            );
            INSERT INTO moz_bookmarks VALUES (41, 1, 'Saved one');
            INSERT INTO moz_bookmarks VALUES (42, 2, 'Saved two');
            """,
            database: database
        )
    }

    func firefoxBookmarkIDs() throws -> [Int64] {
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        let statement = try Self.prepare(
            "SELECT id FROM moz_bookmarks ORDER BY id",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        var result: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(sqlite3_column_int64(statement, 0))
        }
        return result
    }

    func protectedDataRows() throws -> [String: String] {
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        var values: [String: String] = [:]
        for table in ["cookies", "passwords", "bookmarks", "autofill"] {
            let statement = try Self.prepare(
                "SELECT value FROM \(table) WHERE id = 1",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0) else {
                throw BrowserPrivacyHistoryFixtureError.sqlite
            }
            values[table] = String(cString: value)
        }
        return values
    }

    func openWALConnection() throws -> OpaquePointer {
        let database = try Self.open(at: profile.historyDatabaseURL)
        do {
            try Self.execute("PRAGMA journal_mode=WAL; PRAGMA user_version=1;", database: database)
            return database
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
    }

    func openImmediateWriteTransaction() throws -> OpaquePointer {
        let database = try Self.open(at: profile.historyDatabaseURL)
        do {
            try Self.execute("BEGIN IMMEDIATE", database: database)
            return database
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
    }

    private static func databaseName(for engine: BrowserPrivacyEngine) -> String {
        switch engine {
        case .chromium: "History"
        case .safari: "History.db"
        case .firefox: "places.sqlite"
        }
    }

    private static func fixtureSQL(for engine: BrowserPrivacyEngine) -> String {
        switch engine {
        case .chromium:
            return """
            CREATE TABLE urls (
                id INTEGER PRIMARY KEY,
                url TEXT NOT NULL,
                title TEXT,
                visit_count INTEGER
            );
            CREATE TABLE visits (
                id INTEGER PRIMARY KEY,
                url INTEGER NOT NULL,
                visit_time INTEGER
            );
            INSERT INTO urls VALUES (1, 'https://one.example/', 'One', 1);
            INSERT INTO urls VALUES (2, 'https://two.example/', 'Two', 1);
            INSERT INTO visits VALUES (11, 1, 13324473600000000);
            INSERT INTO visits VALUES (12, 2, 13324473601000000);
            """
        case .safari:
            return """
            CREATE TABLE history_items (
                id INTEGER PRIMARY KEY,
                url TEXT NOT NULL,
                title TEXT
            );
            CREATE TABLE history_visits (
                id INTEGER PRIMARY KEY,
                history_item INTEGER NOT NULL,
                visit_time REAL
            );
            INSERT INTO history_items VALUES (1, 'https://one.example/', 'One');
            INSERT INTO history_items VALUES (2, 'https://two.example/', 'Two');
            INSERT INTO history_visits VALUES (11, 1, 771692800);
            INSERT INTO history_visits VALUES (12, 2, 771692801);
            """
        case .firefox:
            return """
            CREATE TABLE moz_places (
                id INTEGER PRIMARY KEY,
                url TEXT NOT NULL,
                title TEXT,
                visit_count INTEGER
            );
            CREATE TABLE moz_historyvisits (
                id INTEGER PRIMARY KEY,
                place_id INTEGER NOT NULL,
                visit_date INTEGER
            );
            INSERT INTO moz_places VALUES (1, 'https://one.example/', 'One', 1);
            INSERT INTO moz_places VALUES (2, 'https://two.example/', 'Two', 1);
            INSERT INTO moz_historyvisits VALUES (11, 1, 1750000000000000);
            INSERT INTO moz_historyvisits VALUES (12, 2, 1750000001000000);
            """
        }
    }

    fileprivate static func open(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw BrowserPrivacyHistoryFixtureError.sqlite
        }
        return database
    }

    fileprivate static func execute(_ sql: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw BrowserPrivacyHistoryFixtureError.sqlite
        }
    }

    fileprivate static func prepare(
        _ sql: String,
        database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw BrowserPrivacyHistoryFixtureError.sqlite
        }
        return statement
    }
}

final class ChromiumV70HistoryFixture {
    enum Mode: Equatable {
        case fixture
        case production
    }

    enum ProductionSchemaMutation: Equatable {
        case exact
        case extraVisitColumn
        case missingAppID
        case nonAliasedVisitID
        case declaredForeignKey
    }

    static let selectedVisitID: Int64 = 12
    static let onlyVisitID: Int64 = 21
    static let latestRemainingVisitTime: Int64 = 13_324_473_603_000_000

    let root: URL
    let snapshotRoot: URL
    let profile: BrowserPrivacyProfile
    let descriptor: BrowserPrivacyProviderDescriptor
    let installedApplication: BrowserPrivacyInstalledApplication?
    private let mode: Mode

    init(
        mode: Mode = .fixture,
        productionSchemaMutation: ProductionSchemaMutation = .exact,
        failURLUpdate: Bool = false,
        providerID: String? = nil,
        browserVersion: String? = nil,
        schemaVersion: String = "70",
        lastCompatibleVersion: String = "16"
    ) throws {
        self.mode = mode
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChromiumV70HistoryFixture-\(UUID().uuidString)",
            isDirectory: true
        )
        let isProduction = mode == .production
        let browserID = providerID ?? (isProduction ? "chrome" : "fixture-chromium-v70")
        let bundleIdentifier = isProduction
            ? Self.bundleIdentifier(for: browserID)
            : "com.storagecleaner.fixture.\(browserID)"
        let dataRootRelativePath = isProduction
            ? "Library/Application Support/\(browserID)-fixture"
            : "Profile"
        let dataRoot = root.appendingPathComponent(dataRootRelativePath, isDirectory: true)
        let profileRoot = isProduction
            ? dataRoot.appendingPathComponent("Default", isDirectory: true)
            : dataRoot
        snapshotRoot = root.appendingPathComponent("Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        if isProduction {
            let applicationURL = try Self.makeApplication(
                under: root,
                bundleIdentifier: bundleIdentifier,
                displayName: browserID.capitalized
            )
            installedApplication = BrowserPrivacyInstalledApplication(
                bundleIdentifier: bundleIdentifier,
                version: browserVersion ?? "150.0.7871.187",
                url: applicationURL,
                isDefaultBrowser: false,
                displayName: browserID.capitalized,
                canOpenWebURLs: true,
                signingIdentity: StartupApplicationSigningIdentity(
                    teamIdentifier: "FIXTURETEAM",
                    codeSigningIdentifier: bundleIdentifier,
                    designatedRequirement: "identifier \"\(bundleIdentifier)\""
                )
            )
        } else {
            installedApplication = nil
        }
        let browser = BrowserPrivacyBrowser(
            id: browserID,
            displayName: isProduction
                ? (browserID == "chrome" ? "Google Chrome" : browserID.capitalized)
                : "Fixture Chromium v70",
            engine: .chromium,
            bundleIdentifier: bundleIdentifier,
            version: browserVersion ?? (isProduction ? "150.0.7871.187" : "70"),
            applicationURL: installedApplication?.url,
            signingIdentity: installedApplication?.signingIdentity
        )
        descriptor = BrowserPrivacyProviderDescriptor(
            id: browser.id,
            displayName: browser.displayName,
            engine: .chromium,
            bundleIdentifiers: [browser.bundleIdentifier!],
            profileRootRelativePaths: [dataRootRelativePath]
        )
        profile = BrowserPrivacyProfile(
            id: "\(browser.id):Default",
            browser: browser,
            displayName: "Default",
            historyDatabaseURL: profileRoot.appendingPathComponent("History"),
            sourceTrustedParentURL: profileRoot
        )

        let database = try BrowserPrivacyHistoryFixture.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        try BrowserPrivacyHistoryFixture.execute(
            Self.fixtureSQL(
                mode: mode,
                productionSchemaMutation: productionSchemaMutation,
                failURLUpdate: failURLUpdate,
                schemaVersion: schemaVersion,
                lastCompatibleVersion: lastCompatibleVersion
            ),
            database: database
        )
        if mode == .fixture {
            try BrowserPrivacySQLiteWriteAdapter.chromiumFixtureMarkerContents.write(
                to: markerURL,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func scannedRecords() async throws -> [BrowserPrivacyRecord] {
        let outcome = try await scanOutcome()
        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator != nil })
        return outcome.records
    }

    /// Scans the fixture and returns exactly the records for the given Visit IDs.
    func selectedRecords(visitIDs: [Int64]) async throws -> [BrowserPrivacyRecord] {
        let records = try await scannedRecords()
        let selected = records.filter {
            guard let rowID = $0.locator?.visitRowID else { return false }
            return visitIDs.contains(rowID)
        }
        XCTAssertEqual(selected.count, visitIDs.count)
        return selected
    }

    /// Visit 12 is the only member of cluster 2 and one of two members of
    /// cluster 1; duplicate links touch it from both sides.
    static let clusterRowsSQL = """
    INSERT INTO clusters
        (cluster_id, should_show_on_prominent_ui_surfaces, label, raw_label,
         triggerability_calculated, originator_cache_guid, originator_cluster_id)
        VALUES (1, 0, 'kept', 'kept', 0, '', 0);
    INSERT INTO clusters
        (cluster_id, should_show_on_prominent_ui_surfaces, label, raw_label,
         triggerability_calculated, originator_cache_guid, originator_cluster_id)
        VALUES (2, 0, 'private', 'private', 0, '', 0);
    INSERT INTO cluster_keywords VALUES (1, 'kept-keyword', 0, 1, '');
    INSERT INTO cluster_keywords VALUES (2, 'private-keyword', 0, 1, '');
    INSERT INTO clusters_and_visits
        (cluster_id, visit_id, score, engagement_score, url_for_deduping,
         normalized_url, url_for_display, interaction_state)
        VALUES (1, 11, 0, 0, 'a', 'a', 'a', 0);
    INSERT INTO clusters_and_visits
        (cluster_id, visit_id, score, engagement_score, url_for_deduping,
         normalized_url, url_for_display, interaction_state)
        VALUES (1, 12, 0, 0, 'a', 'a', 'a', 0);
    INSERT INTO clusters_and_visits
        (cluster_id, visit_id, score, engagement_score, url_for_deduping,
         normalized_url, url_for_display, interaction_state)
        VALUES (2, 12, 0, 0, 'a', 'a', 'a', 0);
    INSERT INTO cluster_visit_duplicates VALUES (11, 12);
    INSERT INTO cluster_visit_duplicates VALUES (12, 13);
    INSERT INTO cluster_visit_duplicates VALUES (11, 21);
    """

    /// Visits 12 and 13 (URL 1) arrived through visited link 1; link 2 belongs to URL 2.
    static let visitedLinkRowsSQL = """
    INSERT INTO visited_links (id, link_url_id, top_level_url, frame_url, visit_count)
        VALUES (1, 1, 'https://top.invalid/', 'https://frame.invalid/', 2);
    INSERT INTO visited_links (id, link_url_id, top_level_url, frame_url, visit_count)
        VALUES (2, 2, 'https://top.invalid/', 'https://frame.invalid/', 5);
    UPDATE visits SET visited_link_id = 1 WHERE id IN (12, 13);
    """

    func scanOutcome(
        adapter overrideAdapter: BrowserPrivacySQLiteWriteAdapter? = nil,
        installedApplications overrideApplications: [BrowserPrivacyInstalledApplication]? = nil
    ) async throws -> BrowserPrivacyScanOutcome {
        let adapter = overrideAdapter ?? (mode == .production
            ? .chromeV70Production
            : .verified(for: .chromium))
        return try await BrowserPrivacyRecordScanner(
            registry: registry(adapter: adapter),
            snapshotService: SQLiteSnapshotService(temporaryRoot: snapshotRoot),
            homeDirectory: root,
            installedApplications: overrideApplications
                ?? installedApplication.map { [$0] }
                ?? [],
            limits: BrowserPrivacyRecordScanLimits(totalTimeoutSeconds: 2)
        ).scan()
    }

    func processor(
        runningBundleIdentifiers: Set<String> = [],
        backupService: (any BrowserPrivacyDatabaseBackingUp)? = nil,
        beforeReadBackHook: (@Sendable () -> Void)? = nil,
        inTransactionHook: (@Sendable (SQLiteExecutionControl) throws -> Void)? = nil
    ) -> BrowserPrivacyHistoryProcessor {
        BrowserPrivacyHistoryProcessor(
            registry: registry(
                adapter: mode == .production
                    ? .chromeV70Production
                    : .chromiumV70Fixture
            ),
            runningApplicationChecker: FixedBrowserPrivacyRunningApplicationChecker(
                runningBundleIdentifiers: runningBundleIdentifiers
            ),
            backupService: backupService ?? recoveryService,
            homeDirectory: root,
            busyRetrySeconds: 0.2,
            operationTimeoutSeconds: 2,
            beforeReadBackHook: beforeReadBackHook,
            inTransactionHook: inTransactionHook
        )
    }

    /// The recovery backups of this fixture, in its own temporary directory.
    var recoveryService: BrowserPrivacyRecoveryBackupService {
        BrowserPrivacyRecoveryBackupService(
            rootURL: recoveryRoot,
            snapshotService: SQLiteSnapshotService(temporaryRoot: snapshotRoot)
        )
    }

    func recoveryService(maximumBackups: Int) -> BrowserPrivacyRecoveryBackupService {
        BrowserPrivacyRecoveryBackupService(
            rootURL: recoveryRoot,
            snapshotService: SQLiteSnapshotService(temporaryRoot: snapshotRoot),
            maximumBackups: maximumBackups
        )
    }

    var recoveryRoot: URL {
        root.appendingPathComponent("Recovery", isDirectory: true)
    }

    private static func bundleIdentifier(for providerID: String) -> String {
        switch providerID {
        case "chrome": "com.google.Chrome"
        case "edge": "com.microsoft.edgemac"
        case "brave": "com.brave.Browser"
        case "arc": "company.thebrowser.Browser"
        case "opera": "com.operasoftware.Opera"
        case "vivaldi": "com.vivaldi.Vivaldi"
        default: "com.storagecleaner.fixture.\(providerID)"
        }
    }

    private static func makeApplication(
        under root: URL,
        bundleIdentifier: String,
        displayName: String
    ) throws -> URL {
        let applicationURL = root.appendingPathComponent(
            "Applications/\(displayName).app",
            isDirectory: true
        )
        let executableURL = applicationURL.appendingPathComponent("Contents/MacOS/Browser")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleName": displayName,
                "CFBundleExecutable": "Browser",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        )
        guard FileManager.default.createFile(
            atPath: applicationURL.appendingPathComponent("Contents/Info.plist").path,
            contents: infoData
        ), FileManager.default.createFile(
            atPath: executableURL.path,
            contents: Data("fixture".utf8)
        ) else {
            throw BrowserPrivacyHistoryFixtureError.sqlite
        }
        return applicationURL.standardizedFileURL
    }

    func removeMarker() throws {
        try FileManager.default.removeItem(at: markerURL)
    }

    var hasMarker: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    func createSidecar(_ suffix: String, contents: Data = Data("active".utf8)) throws {
        guard ["-wal", "-shm", "-journal"].contains(suffix),
              FileManager.default.createFile(
                  atPath: profile.historyDatabaseURL.path + suffix,
                  contents: contents
              ) else {
            throw BrowserPrivacyHistoryFixtureError.sqlite
        }
    }

    func sidecarExists(_ suffix: String) -> Bool {
        FileManager.default.fileExists(atPath: profile.historyDatabaseURL.path + suffix)
    }

    func execute(_ sql: String) throws {
        let database = try BrowserPrivacyHistoryFixture.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        try BrowserPrivacyHistoryFixture.execute(sql, database: database)
    }

    func scalar(_ sql: String) throws -> Int64 {
        let database = try BrowserPrivacyHistoryFixture.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        let statement = try BrowserPrivacyHistoryFixture.prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw BrowserPrivacyHistoryFixtureError.sqlite
        }
        return sqlite3_column_int64(statement, 0)
    }

    func rows(_ sql: String) throws -> [String] {
        let database = try BrowserPrivacyHistoryFixture.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        let statement = try BrowserPrivacyHistoryFixture.prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0 ..< sqlite3_column_count(statement)).map { column in
                guard let value = sqlite3_column_text(statement, column) else { return "<null>" }
                return String(cString: value)
            }.joined(separator: "\u{1f}"))
        }
        return result
    }

    func tableState() throws -> [String: [String]] {
        var state = [
            "meta": try rows("SELECT key, value FROM meta ORDER BY key"),
            "urls": try rows(
                "SELECT id, visit_count, typed_count, last_visit_time FROM urls ORDER BY id"
            ),
            "visits": try rows(
                """
                SELECT id, url, visit_time, from_visit, transition, segment_id,
                       incremented_omnibox_typed_score, visited_link_id
                FROM visits ORDER BY id
                """
            ),
            "visit_source": try rows("SELECT id, source FROM visit_source ORDER BY id"),
            "context_annotations": try rows(
                "SELECT visit_id FROM context_annotations ORDER BY visit_id"
            ),
            "content_annotations": try rows(
                "SELECT visit_id FROM content_annotations ORDER BY visit_id"
            ),
            "segments": try rows("SELECT id, url_id FROM segments ORDER BY id"),
            "segment_usage": try rows(
                "SELECT id, segment_id, time_slot, visit_count FROM segment_usage ORDER BY id"
            ),
        ]
        if mode == .production {
            state["production_visit_metadata"] = try rows(
                """
                SELECT id, COALESCE(opener_visit, 0),
                       CASE WHEN COALESCE(originator_cache_guid, '') = '' THEN 0 ELSE 1 END,
                       COALESCE(originator_visit_id, 0), COALESCE(originator_from_visit, 0),
                       COALESCE(originator_opener_visit, 0), is_known_to_sync
                FROM visits ORDER BY id
                """
            )
            state["clusters_and_visits"] = try rows(
                "SELECT cluster_id, visit_id FROM clusters_and_visits ORDER BY cluster_id, visit_id"
            )
            state["cluster_visit_duplicates"] = try rows(
                "SELECT visit_id, duplicate_visit_id FROM cluster_visit_duplicates ORDER BY visit_id, duplicate_visit_id"
            )
            state["visited_links"] = try rows(
                "SELECT id, link_url_id, visit_count FROM visited_links ORDER BY id"
            )
            state["keyword_search_terms"] = try rows(
                "SELECT keyword_id, url_id FROM keyword_search_terms ORDER BY keyword_id, url_id"
            )
            for table in ["clusters", "cluster_keywords"]
                where try scalar(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'"
                ) == 1 {
                state[table] = try rows("SELECT * FROM \(table) ORDER BY 1, 2")
            }
        }
        return state
    }

    private var markerURL: URL {
        profile.historyDatabaseURL.deletingLastPathComponent().appendingPathComponent(
            BrowserPrivacySQLiteWriteAdapter.chromiumFixtureMarkerName
        )
    }

    private func registry(
        adapter: BrowserPrivacySQLiteWriteAdapter
    ) -> BrowserPrivacyProviderRegistry {
        BrowserPrivacyProviderRegistry(providers: [
            BrowserPrivacyHistoryFixtureProvider(
                descriptor: descriptor,
                profile: profile,
                historyWriteAdapter: adapter
            ),
        ])
    }

    private static func fixtureSQL(
        mode: Mode,
        productionSchemaMutation: ProductionSchemaMutation,
        failURLUpdate: Bool,
        schemaVersion: String,
        lastCompatibleVersion: String
    ) -> String {
        guard mode == .production else {
            return markedFixtureSQL(failURLUpdate: failURLUpdate)
        }
        return productionSQL(
            schemaMutation: productionSchemaMutation,
            failURLUpdate: failURLUpdate,
            schemaVersion: schemaVersion,
            lastCompatibleVersion: lastCompatibleVersion
        )
    }

    private static func markedFixtureSQL(failURLUpdate: Bool) -> String {
        let visitCountConstraint = failURLUpdate
            ? " CHECK (id != 1 OR visit_count = 3)"
            : ""
        return """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE urls (
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL,
            visit_count INTEGER NOT NULL\(visitCountConstraint),
            typed_count INTEGER NOT NULL,
            last_visit_time INTEGER NOT NULL
        );
        CREATE TABLE visits (
            id INTEGER PRIMARY KEY,
            url INTEGER NOT NULL,
            visit_time INTEGER NOT NULL,
            from_visit INTEGER NOT NULL,
            transition INTEGER NOT NULL,
            segment_id INTEGER NOT NULL,
            incremented_omnibox_typed_score INTEGER NOT NULL,
            visited_link_id INTEGER NOT NULL
        );
        CREATE TABLE visit_source (id INTEGER PRIMARY KEY, source INTEGER NOT NULL);
        CREATE TABLE context_annotations (visit_id INTEGER PRIMARY KEY);
        CREATE TABLE content_annotations (visit_id INTEGER PRIMARY KEY);
        CREATE TABLE segments (id INTEGER PRIMARY KEY, url_id INTEGER NOT NULL);
        CREATE TABLE segment_usage (
            id INTEGER PRIMARY KEY,
            segment_id INTEGER NOT NULL,
            time_slot INTEGER NOT NULL,
            visit_count INTEGER NOT NULL
        );

        INSERT INTO meta VALUES ('version', '70');
        INSERT INTO urls VALUES (1, 'https://same.example/', 3, 1, 13324473603000000);
        INSERT INTO urls VALUES (2, 'https://only.example/', 1, 0, 13324473604000000);
        INSERT INTO visits VALUES (11, 1, 13324473601000000, 0, 0, 7, 0, 0);
        INSERT INTO visits VALUES (12, 1, 13324473602000000, 0, 1, 7, 1, 0);
        INSERT INTO visits VALUES (13, 1, 13324473603000000, 12, 0, 7, 0, 0);
        INSERT INTO visits VALUES (21, 2, 13324473604000000, 0, 0, 0, 0, 0);
        INSERT INTO visit_source VALUES (12, 1);
        INSERT INTO context_annotations VALUES (12);
        INSERT INTO content_annotations VALUES (12);
        INSERT INTO segments VALUES (7, 1);
        INSERT INTO segment_usage VALUES (70, 7, 13324473600000000, 3);
        """
    }

    private static func productionSQL(
        schemaMutation: ProductionSchemaMutation,
        failURLUpdate: Bool,
        schemaVersion: String,
        lastCompatibleVersion: String
    ) -> String {
        let visitCountConstraint = failURLUpdate
            ? " CHECK (id != 1 OR visit_count = 3)"
            : ""
        let appIDColumn = schemaMutation == .missingAppID ? "" : ", app_id TEXT"
        let extraColumn = schemaMutation == .extraVisitColumn ? ", unexpected INTEGER" : ""
        let visitIDColumn = schemaMutation == .nonAliasedVisitID
            ? "id INTEGER UNIQUE"
            : "id INTEGER PRIMARY KEY AUTOINCREMENT"
        let foreignKey = schemaMutation == .declaredForeignKey
            ? ", FOREIGN KEY(url) REFERENCES urls(id) ON DELETE CASCADE"
            : ""
        return """
        CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        CREATE TABLE urls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url LONGVARCHAR,
            title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0 NOT NULL\(visitCountConstraint),
            typed_count INTEGER DEFAULT 0 NOT NULL,
            last_visit_time INTEGER NOT NULL,
            hidden INTEGER DEFAULT 0 NOT NULL
        );
        CREATE TABLE visits (
            \(visitIDColumn),
            url INTEGER NOT NULL,
            visit_time INTEGER NOT NULL,
            from_visit INTEGER,
            external_referrer_url TEXT,
            transition INTEGER DEFAULT 0 NOT NULL,
            segment_id INTEGER,
            visit_duration INTEGER DEFAULT 0 NOT NULL,
            incremented_omnibox_typed_score BOOLEAN DEFAULT FALSE NOT NULL,
            opener_visit INTEGER,
            originator_cache_guid TEXT,
            originator_visit_id INTEGER,
            originator_from_visit INTEGER,
            originator_opener_visit INTEGER,
            is_known_to_sync BOOLEAN DEFAULT FALSE NOT NULL,
            consider_for_ntp_most_visited BOOLEAN DEFAULT FALSE NOT NULL,
            visited_link_id INTEGER DEFAULT 0 NOT NULL\(appIDColumn)\(extraColumn)\(foreignKey)
        );
        CREATE TABLE visit_source (id INTEGER PRIMARY KEY, source INTEGER NOT NULL);
        CREATE TABLE context_annotations (
            visit_id INTEGER PRIMARY KEY,
            context_annotation_flags INTEGER NOT NULL,
            duration_since_last_visit INTEGER,
            page_end_reason INTEGER,
            total_foreground_duration INTEGER,
            browser_type INTEGER DEFAULT 0 NOT NULL,
            window_id INTEGER DEFAULT -1 NOT NULL,
            tab_id INTEGER DEFAULT -1 NOT NULL,
            task_id INTEGER DEFAULT -1 NOT NULL,
            root_task_id INTEGER DEFAULT -1 NOT NULL,
            parent_task_id INTEGER DEFAULT -1 NOT NULL,
            response_code INTEGER DEFAULT 0 NOT NULL
        );
        CREATE TABLE content_annotations (
            visit_id INTEGER PRIMARY KEY,
            visibility_score NUMERIC,
            floc_protected_score NUMERIC,
            categories VARCHAR,
            page_topics_model_version INTEGER,
            annotation_flags INTEGER NOT NULL,
            entities VARCHAR,
            related_searches VARCHAR,
            search_normalized_url VARCHAR,
            search_terms LONGVARCHAR,
            alternative_title VARCHAR,
            page_language VARCHAR,
            password_state INTEGER DEFAULT 0 NOT NULL,
            has_url_keyed_image BOOLEAN NOT NULL
        );
        CREATE TABLE segments (id INTEGER PRIMARY KEY, name VARCHAR, url_id INTEGER NON NULL);
        CREATE TABLE segment_usage (
            id INTEGER PRIMARY KEY,
            segment_id INTEGER NOT NULL,
            time_slot INTEGER NOT NULL,
            visit_count INTEGER DEFAULT 0 NOT NULL
        );
        CREATE TABLE clusters_and_visits (
            cluster_id INTEGER NOT NULL,
            visit_id INTEGER NOT NULL,
            score NUMERIC DEFAULT 0 NOT NULL,
            engagement_score NUMERIC DEFAULT 0 NOT NULL,
            url_for_deduping LONGVARCHAR NOT NULL,
            normalized_url LONGVARCHAR NOT NULL,
            url_for_display LONGVARCHAR NOT NULL,
            interaction_state INTEGER DEFAULT 0 NOT NULL,
            PRIMARY KEY(cluster_id, visit_id)
        ) WITHOUT ROWID;
        CREATE TABLE cluster_visit_duplicates (
            visit_id INTEGER NOT NULL,
            duplicate_visit_id INTEGER NOT NULL,
            PRIMARY KEY(visit_id, duplicate_visit_id)
        ) WITHOUT ROWID;
        CREATE TABLE clusters (
            cluster_id INTEGER PRIMARY KEY AUTOINCREMENT,
            should_show_on_prominent_ui_surfaces BOOLEAN NOT NULL,
            label VARCHAR NOT NULL,
            raw_label VARCHAR NOT NULL,
            triggerability_calculated BOOLEAN NOT NULL,
            originator_cache_guid TEXT NOT NULL,
            originator_cluster_id INTEGER NOT NULL
        );
        CREATE TABLE cluster_keywords (
            cluster_id INTEGER NOT NULL,
            keyword VARCHAR NOT NULL,
            type INTEGER NOT NULL,
            score NUMERIC NOT NULL,
            collections VARCHAR NOT NULL
        );
        CREATE TABLE visited_links (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            link_url_id INTEGER NOT NULL,
            top_level_url LONGVARCHAR NOT NULL,
            frame_url LONGVARCHAR NOT NULL,
            visit_count INTEGER DEFAULT 0 NOT NULL
        );
        CREATE TABLE keyword_search_terms (
            keyword_id INTEGER NOT NULL,
            url_id INTEGER NOT NULL,
            term LONGVARCHAR NOT NULL,
            normalized_term LONGVARCHAR NOT NULL
        );

        INSERT INTO meta VALUES ('version', '\(schemaVersion)');
        INSERT INTO meta VALUES ('last_compatible_version', '\(lastCompatibleVersion)');
        INSERT INTO urls (id, url, title, visit_count, typed_count, last_visit_time, hidden)
            VALUES (1, 'https://fixture.invalid/1', NULL, 3, 1, 13324473603000000, 0);
        INSERT INTO urls (id, url, title, visit_count, typed_count, last_visit_time, hidden)
            VALUES (2, 'https://fixture.invalid/2', NULL, 1, 0, 13324473604000000, 0);
        INSERT INTO visits (id, url, visit_time, from_visit, transition, segment_id,
                            incremented_omnibox_typed_score, visited_link_id)
            VALUES (11, 1, 13324473601000000, 0, 0, 7, 0, 0);
        INSERT INTO visits (id, url, visit_time, from_visit, transition, segment_id,
                            incremented_omnibox_typed_score, visited_link_id)
            VALUES (12, 1, 13324473602000000, 0, 1, 7, 1, 0);
        INSERT INTO visits (id, url, visit_time, from_visit, transition, segment_id,
                            incremented_omnibox_typed_score, visited_link_id)
            VALUES (13, 1, 13324473603000000, 12, 0, 7, 0, 0);
        INSERT INTO visits (id, url, visit_time, from_visit, transition, segment_id,
                            incremented_omnibox_typed_score, visited_link_id)
            VALUES (21, 2, 13324473604000000, 0, 0, 0, 0, 0);
        INSERT INTO visit_source VALUES (12, 1);
        INSERT INTO context_annotations (
            visit_id, context_annotation_flags, browser_type, window_id, tab_id,
            task_id, root_task_id, parent_task_id, response_code
        ) VALUES (12, 0, 0, -1, -1, -1, -1, -1, 0);
        INSERT INTO content_annotations (visit_id, annotation_flags, has_url_keyed_image)
            VALUES (12, 0, 0);
        INSERT INTO segments VALUES (7, NULL, 1);
        INSERT INTO segment_usage VALUES (70, 7, 13324473600000000, 3);
        """
    }
}

extension ChromiumV70HistoryFixture: @unchecked Sendable {}

extension BrowserPrivacyHistoryFixture: @unchecked Sendable {}

private enum BrowserPrivacyHistoryFixtureError: Error {
    case sqlite
}
