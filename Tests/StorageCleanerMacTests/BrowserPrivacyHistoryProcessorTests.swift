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
        XCTAssertTrue(entry.detail.localizedCaseInsensitiveContains("rolled back"))
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
        XCTAssertTrue(entry.detail.localizedCaseInsensitiveContains("reused"))
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
        XCTAssertTrue(entry.detail.localizedCaseInsensitiveContains("still running"))
        XCTAssertEqual(try fixture.remainingVisitRowIDs(), [11, 12])
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
        XCTAssertTrue(entry.detail.localizedCaseInsensitiveContains("identity"))
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
        XCTAssertTrue(entry.detail.localizedCaseInsensitiveContains("identity"))
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
        XCTAssertTrue(entry.detail.localizedCaseInsensitiveContains("schema"))
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
        XCTAssertTrue(entry.detail.localizedCaseInsensitiveContains("committed"))
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
        XCTAssertTrue(entry.detail.localizedCaseInsensitiveContains("manually"))
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
        XCTAssertTrue(entry.detail.localizedCaseInsensitiveContains("busy"))
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

    func testChromiumV70FixtureRejectsLastVisitWithoutChangingAnyTable() async throws {
        let fixture = try ChromiumV70HistoryFixture()
        let records = try await fixture.scannedRecords()
        let selected = try XCTUnwrap(records.first {
            $0.locator?.visitRowID == ChromiumV70HistoryFixture.onlyVisitID
        })
        let before = try fixture.tableState()

        let report = await fixture.processor().process(records: [selected])
        let entry = try XCTUnwrap(report.entries.first)

        XCTAssertEqual(entry.outcome, .unsupported, entry.detail)
        XCTAssertEqual(entry.capability, .unsupported)
        XCTAssertTrue(entry.verifiedDeletedRecordIDs.isEmpty)
        XCTAssertEqual(try fixture.tableState(), before)
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
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testChromeV70ProductionRejectsSelectedClusterReferencesWithoutWriting() async throws {
        try await assertChromeV70ProductionRejectsWithoutMutation { fixture in
            try fixture.execute(
                """
                INSERT INTO clusters_and_visits
                    (cluster_id, visit_id, score, engagement_score, url_for_deduping,
                     normalized_url, url_for_display, interaction_state)
                    VALUES (1, 12, 0, 0, 'a', 'a', 'a', 0)
                """
            )
        }
        try await assertChromeV70ProductionRejectsWithoutMutation { fixture in
            try fixture.execute("INSERT INTO cluster_visit_duplicates VALUES (11, 12)")
        }
    }

    func testChromeV70ProductionRejectsSelectedVisitedLinkWithoutWriting() async throws {
        try await assertChromeV70ProductionRejectsWithoutMutation { fixture in
            try fixture.execute("UPDATE visits SET visited_link_id = 1 WHERE id = 12")
        }
    }

    func testChromeV70ProductionRejectsSelectedSyncMetadataWithoutWriting() async throws {
        try await assertChromeV70ProductionRejectsWithoutMutation { fixture in
            try fixture.execute(
                """
                UPDATE visits
                SET is_known_to_sync = 1, originator_cache_guid = 'sync',
                    originator_visit_id = 9, originator_from_visit = 8,
                    originator_opener_visit = 7
                WHERE id = 12
                """
            )
        }
    }

    func testChromeV70ProductionRejectsOtherRowOpenerReferenceWithoutWriting() async throws {
        try await assertChromeV70ProductionRejectsWithoutMutation { fixture in
            try fixture.execute("UPDATE visits SET opener_visit = 12 WHERE id = 13")
        }
    }

    func testChromeV70ProductionRejectsLastURLVisitWithoutWriting() async throws {
        try await assertChromeV70ProductionRejectsWithoutMutation(
            selectedVisitID: ChromiumV70HistoryFixture.onlyVisitID
        ) { _ in }
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

    func testChromeV70ProductionAuthorizerKeepsTheSameFiniteWriteSet() {
        XCTAssertEqual(
            authorizationResult(
                adapter: .chromeV70Production,
                action: SQLITE_DELETE,
                table: "visits"
            ),
            SQLITE_OK
        )
        XCTAssertEqual(
            authorizationResult(
                adapter: .chromeV70Production,
                action: SQLITE_UPDATE,
                table: "visits",
                column: "from_visit"
            ),
            SQLITE_OK
        )
        XCTAssertEqual(
            authorizationResult(
                adapter: .chromeV70Production,
                action: SQLITE_DELETE,
                table: "visited_links"
            ),
            SQLITE_DENY
        )
        XCTAssertEqual(
            authorizationResult(
                adapter: .chromeV70Production,
                action: SQLITE_UPDATE,
                table: "urls",
                column: "title"
            ),
            SQLITE_DENY
        )
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

private struct FixedBrowserPrivacyRunningApplicationChecker:
    BrowserPrivacyRunningApplicationChecking {
    let runningBundleIdentifiers: Set<String>

    func runningBundleIdentifiers(
        matching bundleIdentifiers: Set<String>
    ) async -> Set<String> {
        runningBundleIdentifiers.intersection(bundleIdentifiers)
    }
}

private struct FailingBrowserPrivacyBackupService: BrowserPrivacyDatabaseBackingUp {
    func backup(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        browserID: String,
        profileID: String,
        deadlineNanoseconds: UInt64
    ) async throws -> BrowserPrivacyRecoveryBackup {
        throw SQLiteSnapshotFailure.unavailable
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

    func processor() -> BrowserPrivacyHistoryProcessor {
        BrowserPrivacyHistoryProcessor(
            registry: registry(
                adapter: mode == .production
                    ? .chromeV70Production
                    : .chromiumV70Fixture
            ),
            runningApplicationChecker: FixedBrowserPrivacyRunningApplicationChecker(
                runningBundleIdentifiers: []
            ),
            backupService: BrowserPrivacyRecoveryBackupService(
                rootURL: root.appendingPathComponent("Recovery", isDirectory: true),
                snapshotService: SQLiteSnapshotService(temporaryRoot: snapshotRoot)
            ),
            homeDirectory: root,
            busyRetrySeconds: 0.2,
            operationTimeoutSeconds: 2
        )
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

    func createSidecar(_ suffix: String) throws {
        guard ["-wal", "-shm", "-journal"].contains(suffix),
              FileManager.default.createFile(
                  atPath: profile.historyDatabaseURL.path + suffix,
                  contents: Data("active".utf8)
              ) else {
            throw BrowserPrivacyHistoryFixtureError.sqlite
        }
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
