import CSQLite
import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class BrowserPrivacyRecordScannerTests: XCTestCase {
#if DEBUG || STORAGE_CLEANER_BETA
    func testBetaBrowserPrivacyPreviewUsesAnonymousInMemoryRecords() async {
        let store = BrowserPrivacyPreviewFixture.makeStore()

        store.startScan()
        await store.waitUntilIdle()

        XCTAssertEqual(store.records.count, 4)
        XCTAssertEqual(store.filteredDisplayItems.count, 3)
        XCTAssertTrue(store.selectedRecordIDs.isEmpty)
        XCTAssertTrue(store.records.allSatisfy {
            $0.url?.contains(".example") == true || $0.url?.hasPrefix("chrome://") == true
        })
    }
#endif

    func testOptInProductionBrowserCoverage() async throws {
        guard ProcessInfo.processInfo.environment[
            "STORAGE_CLEANER_RUN_LIVE_BROWSER_SCAN"
        ] == "1" else {
            throw XCTSkip(
                "Set STORAGE_CLEANER_RUN_LIVE_BROWSER_SCAN=1 for a read-only local coverage audit."
            )
        }

        let outcome = try await BrowserPrivacyRecordScanner(
            limits: BrowserPrivacyRecordScanLimits(
                maximumProfiles: 64,
                maximumConcurrentProfiles: 2,
                maximumRecordsPerProfile: 5_000,
                maximumRecordsTotal: 20_000,
                busyRetrySeconds: 2,
                totalTimeoutSeconds: 15
            )
        ).scan()

        XCTAssertTrue(outcome.coverage.allSatisfy {
            $0.browser.bundleIdentifier != nil
        })
        XCTAssertTrue(outcome.records.allSatisfy {
            $0.locator == nil || $0.browser.engine == .chromium
        })
        if FileManager.default.fileExists(
            atPath: "/System/Applications/Safari.app"
        ) {
            let safari = try XCTUnwrap(outcome.coverage.first {
                $0.browser.id == "safari"
            })
            XCTAssertEqual(safari.browser.bundleIdentifier, "com.apple.Safari")
            XCTAssertFalse(safari.browser.version?.isEmpty ?? true)
        }
        print(
            "LIVE_BROWSER state=\(outcome.state) "
                + "providers=\(outcome.coverage.count) "
                + "records=\(outcome.records.count)"
        )
        for coverage in outcome.coverage {
            print(
                "LIVE_BROWSER provider=\(coverage.browser.id) "
                    + "availability=\(coverage.availability) "
                    + "profiles=\(coverage.profileCount) "
                    + "records=\(coverage.recordCount) "
                    + "fullDiskAccess=\(coverage.requiresFullDiskAccess)"
            )
        }
    }

    func testChromiumSnapshotReturnsRecordLevelFieldsAndLeavesUnknownSizeNil() async throws {
        let fixture = try BrowserPrivacyFixtureDatabase()
        let visitDate = Date(timeIntervalSince1970: 1_750_000_000)
        try fixture.insert(
            url: "https://search.example/find?q=green+tea",
            title: "Search result title",
            visitCount: 3,
            visitedAt: visitDate
        )
        try fixture.insert(
            url: "https://account.example/overview",
            title: nil,
            visitCount: 1,
            visitedAt: visitDate.addingTimeInterval(-60)
        )

        let outcome = try await fixture.scanner().scan()
        let searchRecord = try XCTUnwrap(outcome.records.first {
            $0.domain == "search.example"
        })
        let missingTitleRecord = try XCTUnwrap(outcome.records.first {
            $0.domain == "account.example"
        })

        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(
            outcome.coverage.first?.fullyScannedProfileIDs,
            [fixture.profile.id]
        )
        XCTAssertEqual(searchRecord.url, "https://search.example/find?q=green+tea")
        XCTAssertEqual(searchRecord.title, "Search result title")
        XCTAssertEqual(searchRecord.searchKeyword, "green tea")
        XCTAssertEqual(searchRecord.source, .history)
        XCTAssertEqual(searchRecord.visitCount, 3)
        XCTAssertEqual(searchRecord.category, .search)
        XCTAssertEqual(searchRecord.selectionConfidence, .medium)
        XCTAssertNil(searchRecord.sizeBytes)
        let locator = try XCTUnwrap(searchRecord.locator)
        XCTAssertEqual(locator.providerID, fixture.profile.browser.id)
        XCTAssertEqual(locator.profileID, fixture.profile.id)
        XCTAssertEqual(locator.engine, .chromium)
        XCTAssertGreaterThan(locator.visitRowID, 0)
        XCTAssertGreaterThan(locator.parentRowID, 0)
        XCTAssertEqual(locator.visitTimestampIdentity, .integer(13_394_473_600_000_000))
        XCTAssertEqual(locator.rawURL, searchRecord.url)
        XCTAssertEqual(locator.databaseURL, fixture.profile.historyDatabaseURL)
        XCTAssertEqual(locator.trustedParentURL, fixture.profile.sourceTrustedParentURL)
        XCTAssertFalse(locator.identityChain.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(searchRecord.visitedAt).timeIntervalSince1970,
            visitDate.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertNil(missingTitleRecord.title)
        XCTAssertNil(missingTitleRecord.sizeBytes)
        XCTAssertEqual(try fixture.historyRowCount(), 2, "read-only snapshots must not modify source history")
        XCTAssertTrue(try fixture.snapshotResidues().isEmpty)
    }

    func testImmutableFallbackRejectsWALAndHotJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrowserPrivacySidecarSafety-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("History")
        XCTAssertTrue(FileManager.default.createFile(atPath: database.path, contents: Data()))
        XCTAssertTrue(try SecureSourceFile.allowsImmutableSQLiteRead(at: database))

        let wal = URL(fileURLWithPath: database.path + "-wal")
        try Data([1]).write(to: wal)
        XCTAssertFalse(try SecureSourceFile.allowsImmutableSQLiteRead(at: database))
        try FileManager.default.removeItem(at: wal)

        let journal = URL(fileURLWithPath: database.path + "-journal")
        try Data(repeating: 1, count: 513).write(to: journal)
        XCTAssertFalse(try SecureSourceFile.allowsImmutableSQLiteRead(at: database))
        var nonHotJournal = Data(repeating: 1, count: 513)
        nonHotJournal.replaceSubrange(0..<8, with: repeatElement(UInt8(0), count: 8))
        try nonHotJournal.write(to: journal)
        XCTAssertTrue(try SecureSourceFile.allowsImmutableSQLiteRead(at: database))
    }

    func testMedicalAndResearchContextIsNotDefaultSelectedAsAdultContent() {
        let classifier = BrowserPrivacyLocalClassifier()

        let classification = classifier.classify(
            url: "https://clinic.example/sexual-health-research",
            title: "Reproductive health research",
            domain: "clinic.example"
        )

        XCTAssertNotEqual(classification.category, .adult)
        XCTAssertNotEqual(classification.confidence, .high)
    }

    func testLocalClassifierCoversKnownCategoriesAndKeepsAdultConfidenceTiered() {
        let classifier = BrowserPrivacyLocalClassifier()
        let fixtures: [(String, String, BrowserPrivacyCategory)] = [
            ("https://bank.example/account", "Account overview", .finance),
            ("https://social.example/community", "Social community", .social),
            ("https://shop.example/cart", "Shopping cart", .shopping),
            ("https://media.example/video", "Streaming video", .entertainment),
            ("https://search.example/?q=local", "Search", .search),
            ("https://work.example/project", "Project workspace", .productivity),
            ("https://press.example/article", "News article", .news),
            ("https://misc.example/path", "Unclassified page", .other),
        ]

        for (url, title, expectedCategory) in fixtures {
            let domain = URLComponents(string: url)?.host
            XCTAssertEqual(
                classifier.classify(url: url, title: title, domain: domain).category,
                expectedCategory
            )
        }

        let low = classifier.classify(
            url: "https://review.example/nsfw",
            title: "Review",
            domain: "review.example"
        )
        let medium = classifier.classify(
            url: "https://review.example/nsfw",
            title: "Adult content and explicit video",
            domain: "review.example"
        )
        let high = classifier.classify(
            url: "https://review.example.xxx/",
            title: "Review",
            domain: "review.example.xxx"
        )

        XCTAssertEqual(low, .init(category: .adult, confidence: .low))
        XCTAssertEqual(medium, .init(category: .adult, confidence: .medium))
        XCTAssertEqual(high, .init(category: .adult, confidence: .high))
        let other = classifier.classify(
            url: "https://misc.example/path",
            title: "Unclassified page",
            domain: "misc.example"
        )
        XCTAssertEqual(other, .init(category: .other, confidence: .low))
        XCTAssertFalse(BrowserPrivacyTestFactory.record(
            domain: "misc.example",
            searchKeyword: nil,
            category: other.category,
            confidence: other.confidence,
            date: .now
        ).isDefaultSelected)
        XCTAssertFalse(BrowserPrivacyTestFactory.record(
            domain: "review.example",
            searchKeyword: nil,
            category: medium.category,
            confidence: medium.confidence,
            date: .now
        ).isDefaultSelected)
    }

    func testHistoryRequiresExplicitSelectionAndFiltersArePrecise() async {
        let adult = BrowserPrivacyTestFactory.record(
            domain: "review.example.xxx",
            searchKeyword: "private phrase",
            category: .adult,
            confidence: .high,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let finance = BrowserPrivacyTestFactory.record(
            domain: "bank.example",
            title: "Quarterly Budget Review",
            searchKeyword: "account balance",
            category: .finance,
            confidence: .medium,
            date: Date(timeIntervalSince1970: 1_740_000_000)
        )
        let store = BrowserPrivacyStore(
            scanner: BrowserPrivacyStaticScanner(
                outcome: BrowserPrivacyScanOutcome(
                    state: .completed,
                    records: [adult, finance],
                    coverage: []
                )
            )
        )

        store.startScan()
        await store.waitUntilIdle()

        XCTAssertTrue(store.selectedRecordIDs.isEmpty)
        XCTAssertEqual(adult.risk, .review)
        XCTAssertEqual(adult.selectionEligibility, .browserActionOnly)
        store.setSelected(true, recordID: adult.id)
        XCTAssertEqual(store.selectedRecordIDs, [adult.id])
        store.filters.domain = "bank"
        XCTAssertEqual(store.filteredRecords.map(\.id), [finance.id])
        store.filters.domain = ""
        store.filters.keyword = "account balance"
        XCTAssertEqual(store.filteredRecords.map(\.id), [finance.id])
        store.filters.keyword = "private phrase"
        XCTAssertEqual(store.filteredRecords.map(\.id), [adult.id])
        store.filters.keyword = ""
        store.filters.query = "Quarterly Budget Review"
        XCTAssertEqual(store.filteredRecords.map(\.id), [finance.id])
        store.filters.query = ""
        store.filters.startDate = Date(timeIntervalSince1970: 1_745_000_000)
        XCTAssertEqual(store.filteredRecords.map(\.id), [adult.id])
    }

    func testMixedSelectionSeparatesVerifiedCandidatesFromManualGuidance() async {
        let candidate = BrowserPrivacyTestFactory.record(
            profileID: "chrome:Default",
            domain: "candidate.example",
            searchKeyword: nil,
            category: .finance,
            confidence: .medium,
            date: .now,
            locator: BrowserPrivacyTestFactory.locator(profileID: "chrome:Default")
        )
        let manual = BrowserPrivacyTestFactory.record(
            profileID: "safari:Safari",
            domain: "manual.example",
            searchKeyword: nil,
            category: .finance,
            confidence: .medium,
            date: .now
        )
        let store = BrowserPrivacyStore(
            scanner: BrowserPrivacyStaticScanner(
                outcome: BrowserPrivacyScanOutcome(
                    state: .completed,
                    records: [candidate, manual],
                    coverage: []
                )
            )
        )

        store.startScan()
        await store.waitUntilIdle()
        store.toggleSelection(candidate)
        store.toggleSelection(manual)

        XCTAssertEqual(store.selectedVerifiedDeletionCandidateCount, 1)
        XCTAssertEqual(store.selectedManualGuidanceCount, 1)
        XCTAssertTrue(store.selectedRecordsContainVerifiedDeletionCandidate)
    }

    func testBrowserPrivacySelectionStateUsesOnlyVisibleSelectableRecords() async {
        let adult = BrowserPrivacyTestFactory.record(
            domain: "adult.example",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: .now
        )
        let finance = BrowserPrivacyTestFactory.record(
            domain: "bank.example",
            searchKeyword: nil,
            category: .finance,
            confidence: .medium,
            date: .now.addingTimeInterval(-60)
        )
        let store = BrowserPrivacyStore(scanner: BrowserPrivacyStaticScanner(
            outcome: .init(state: .completed, records: [adult, finance], coverage: [])
        ))

        store.startScan()
        await store.waitUntilIdle()
        XCTAssertEqual(store.filteredSelectionState, .unchecked)

        store.setFilteredSelection(true)
        XCTAssertEqual(store.filteredSelectionState, .checked)
        XCTAssertEqual(store.selectedRecordIDs, [adult.id, finance.id])

        store.filters.category = .adult
        store.setFilteredSelection(false)
        XCTAssertEqual(store.filteredSelectionState, .unchecked)
        XCTAssertEqual(store.selectedRecordIDs, [finance.id])

        store.filters.category = nil
        XCTAssertEqual(store.filteredSelectionState, .mixed)
    }

    func testBulkSelectionScopesMatchLocalDatesAndExactWebsiteDomains() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 29,
            hour: 12
        ))!
        let today = BrowserPrivacyTestFactory.record(
            domain: "Example.COM",
            searchKeyword: nil,
            category: .other,
            confidence: .medium,
            date: now.addingTimeInterval(-3_600)
        )
        let sixDaysAgo = BrowserPrivacyTestFactory.record(
            domain: "example.com",
            searchKeyword: nil,
            category: .other,
            confidence: .medium,
            date: calendar.date(byAdding: .day, value: -6, to: now)!
        )
        let tenDaysAgo = BrowserPrivacyTestFactory.record(
            domain: "sub.example.com",
            searchKeyword: nil,
            category: .other,
            confidence: .medium,
            date: calendar.date(byAdding: .day, value: -10, to: now)!
        )
        let fortyDaysAgo = BrowserPrivacyTestFactory.record(
            domain: "example.com",
            searchKeyword: nil,
            category: .other,
            confidence: .medium,
            date: calendar.date(byAdding: .day, value: -40, to: now)!
        )
        let records = [today, sixDaysAgo, tenDaysAgo, fortyDaysAgo]

        XCTAssertEqual(
            BrowserPrivacyBulkSelectionScope.today.matchingRecordIDs(
                in: records,
                now: now,
                calendar: calendar
            ),
            [today.id]
        )
        XCTAssertEqual(
            BrowserPrivacyBulkSelectionScope.last7Days.matchingRecordIDs(
                in: records,
                now: now,
                calendar: calendar
            ),
            [today.id, sixDaysAgo.id]
        )
        XCTAssertEqual(
            BrowserPrivacyBulkSelectionScope.last30Days.matchingRecordIDs(
                in: records,
                now: now,
                calendar: calendar
            ),
            [today.id, sixDaysAgo.id, tenDaysAgo.id]
        )
        XCTAssertEqual(
            BrowserPrivacyBulkSelectionScope.olderThan30Days.matchingRecordIDs(
                in: records,
                now: now,
                calendar: calendar
            ),
            [fortyDaysAgo.id]
        )
        XCTAssertEqual(
            BrowserPrivacyBulkSelectionScope.website("EXAMPLE.com").matchingRecordIDs(
                in: records,
                now: now,
                calendar: calendar
            ),
            [today.id, sixDaysAgo.id, fortyDaysAgo.id]
        )
        XCTAssertEqual(
            BrowserPrivacyBulkSelectionScope.websiteOptions(from: records),
            [
                BrowserPrivacyWebsiteSelectionOption(domain: "example.com", count: 3),
                BrowserPrivacyWebsiteSelectionOption(domain: "sub.example.com", count: 1),
            ]
        )
    }

    func testBulkSelectionRequiresReviewConfirmationAndUsesOnlyCurrentRecordIDs() async {
        let record = BrowserPrivacyTestFactory.record(
            domain: "example.com",
            searchKeyword: nil,
            category: .other,
            confidence: .medium,
            date: .now
        )
        let store = BrowserPrivacyStore(scanner: BrowserPrivacyStaticScanner(
            outcome: .init(state: .completed, records: [record], coverage: [])
        ))

        store.startScan()
        await store.waitUntilIdle()
        store.setSelection(
            true,
            recordIDs: [record.id, UUID()],
            confirmingReview: false
        )
        XCTAssertTrue(store.selectedRecordIDs.isEmpty)

        store.setSelection(
            true,
            recordIDs: [record.id, UUID()],
            confirmingReview: true
        )
        XCTAssertEqual(store.selectedRecordIDs, [record.id])
    }

    func testBrowserPrivacySelectionSummaryUsesOnlyRealKnownSizes() async {
        let known = BrowserPrivacyTestFactory.record(
            domain: "known.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: .now,
            sizeBytes: 4_096
        )
        let unknown = BrowserPrivacyTestFactory.record(
            domain: "unknown.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: .now,
            sizeBytes: nil
        )
        let store = BrowserPrivacyStore(scanner: BrowserPrivacyStaticScanner(
            outcome: .init(state: .completed, records: [known, unknown], coverage: [])
        ))

        store.startScan()
        await store.waitUntilIdle()
        store.setFilteredSelection(true)

        XCTAssertEqual(store.selectedKnownSizeBytes, 4_096)
        XCTAssertEqual(store.selectedUnknownSizeCount, 1)
    }

    func testSelectionSurvivesRescanByVisitIdentityInsteadOfDisplayUUID() async {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let locator = BrowserPrivacyTestFactory.locator(profileID: "chrome:Default")
        let first = BrowserPrivacyTestFactory.record(
            browserID: "chrome",
            browserName: "Chrome",
            profileID: "chrome:Default",
            domain: "candidate.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: date,
            locator: locator
        )
        let rescanned = BrowserPrivacyTestFactory.record(
            browserID: "chrome",
            browserName: "Chrome",
            profileID: "chrome:Default",
            domain: "candidate.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: date,
            locator: locator
        )
        let scanner = BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [first], coverage: [])),
            .outcome(.init(state: .completed, records: [rescanned], coverage: [])),
        ])
        let store = BrowserPrivacyStore(scanner: scanner)

        store.startScan()
        await store.waitUntilIdle()
        store.toggleSelection(first)
        store.startScan()
        await store.waitUntilIdle()

        XCTAssertNotEqual(first.id, rescanned.id)
        XCTAssertEqual(store.selectedRecordIDs, [rescanned.id])
    }

    func testDisplayAggregationExpandsToExactUnderlyingVisits() throws {
        let first = BrowserPrivacyTestFactory.record(
            domain: "same.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: .now
        )
        let second = BrowserPrivacyTestFactory.record(
            domain: "same.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: .now.addingTimeInterval(-60)
        )

        let item = try XCTUnwrap(BrowserPrivacyDisplayItem.aggregate([first, second]).first)

        XCTAssertEqual(item.visitCount, 2)
        XCTAssertEqual(item.underlyingSelectionIDs, Set([first.selectionID, second.selectionID]))
        XCTAssertNil(item.exactSizeBytes)
    }

    func testCleanPlanRejectsForgedOrDuplicateSelection() throws {
        let record = BrowserPrivacyTestFactory.record(
            domain: "plan.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: .now
        )
        let snapshot = BrowserPrivacyScanSnapshot(records: [record], coverage: [])
        let forged = BrowserPrivacySelectionID(
            browserID: "forged",
            profileID: record.profileID,
            source: .history,
            visitRowID: nil,
            visitTimestampIdentity: nil,
            rawURL: nil,
            visitedAt: nil
        )

        XCTAssertThrowsError(try BrowserPrivacyCleanPlan(
            snapshot: snapshot,
            selectedIDs: [forged]
        )) { error in
            XCTAssertEqual(error as? BrowserPrivacyCleanPlanError, .selectionNotInSnapshot)
        }
    }

    func testBrowserPrivacyStorePublishesBrowserRunningStateSeparatelyFromRisk() async {
        let record = BrowserPrivacyTestFactory.record(
            browserID: "chrome",
            browserName: "Chrome",
            domain: "running.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: .now,
            bundleIdentifier: "com.google.Chrome"
        )
        let store = BrowserPrivacyStore(
            scanner: BrowserPrivacyStaticScanner(
                outcome: .init(state: .completed, records: [record], coverage: [])
            ),
            runningApplicationChecker: BrowserPrivacyStaticRunningChecker(
                values: ["com.google.Chrome"]
            )
        )

        store.startScan()
        await store.waitUntilIdle()
        await store.waitUntilRunningStatusRefreshCompletes()

        XCTAssertEqual(store.runningBrowserIDs, ["chrome"])
        XCTAssertEqual(record.risk, .review)
        XCTAssertEqual(record.selectionEligibility, .browserActionOnly)
    }

    func testStoreRemovesOnlyRecordsTheReadBackReportVerifiedDeleted() async {
        let deleted = BrowserPrivacyTestFactory.record(
            domain: "deleted.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let retained = BrowserPrivacyTestFactory.record(
            domain: "retained.example",
            searchKeyword: nil,
            category: .finance,
            confidence: .medium,
            date: Date(timeIntervalSince1970: 1_749_999_000)
        )
        let report = BrowserPrivacyProcessingReport(
            selectedRecordCount: 2,
            entries: [
                BrowserPrivacyProcessingEntry(
                    browser: deleted.browser,
                    profileID: deleted.profileID,
                    recordCount: 1,
                    capability: .verifiedVisitDeletion,
                    outcome: .deleted,
                    verifiedDeletedRecordIDs: [deleted.id],
                    detail: "verified"
                ),
                BrowserPrivacyProcessingEntry(
                    browser: retained.browser,
                    profileID: retained.profileID,
                    recordCount: 1,
                    capability: .verifiedVisitDeletion,
                    outcome: .failed,
                    detail: "failed"
                ),
            ]
        )
        let store = BrowserPrivacyStore(
            scanner: BrowserPrivacyStaticScanner(
                outcome: BrowserPrivacyScanOutcome(
                    state: .completed,
                    records: [deleted, retained],
                    coverage: []
                )
            ),
            processor: BrowserPrivacyStaticProcessor(report: report)
        )

        store.startScan()
        await store.waitUntilIdle()
        store.setSelected(true, recordID: retained.id)
        store.processSelectedRecords()
        await store.waitUntilProcessingCompletes()

        XCTAssertEqual(store.records.map(\.id), [retained.id])
        XCTAssertEqual(store.selectedRecordIDs, [retained.id])
        XCTAssertEqual(store.processingReport, report)
        XCTAssertFalse(store.isProcessing)
    }

    func testRegistryCoversRequiredBrowserFamiliesAndDerivatives() {
        let identifiers = Set(BrowserPrivacyProviderRegistry.defaultProviders.map(\.descriptor.id))
        let required: Set<String> = [
            "safari", "chrome", "chromium", "edge", "firefox", "brave", "arc",
            "opera", "opera-gx", "vivaldi", "orion", "zen", "librewolf", "waterfox",
        ]

        XCTAssertTrue(required.isSubset(of: identifiers))
    }

    func testChromiumDiscoveryFindsRootLayoutAndMultipleNamedProfiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrowserPrivacyDiscovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let operaRoot = home.appendingPathComponent(
            "Library/Application Support/com.operasoftware.Opera",
            isDirectory: true
        )
        let chromeDefault = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Default",
            isDirectory: true
        )
        let chromeProfile = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Profile 2",
            isDirectory: true
        )
        for directory in [operaRoot, chromeDefault, chromeProfile] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            XCTAssertTrue(FileManager.default.createFile(
                atPath: directory.appendingPathComponent("History").path,
                contents: Data()
            ))
        }

        let registry = BrowserPrivacyProviderRegistry()
        let discoveries = registry.discover(
            homeDirectory: home,
            installedApplications: [installedApplication(
                bundleIdentifier: "com.operasoftware.Opera"
            ), installedApplication(bundleIdentifier: "com.google.Chrome")]
        )
        let opera = try XCTUnwrap(discoveries.first { $0.coverage.browser.id == "opera" })
        let chrome = try XCTUnwrap(discoveries.first { $0.coverage.browser.id == "chrome" })

        XCTAssertEqual(opera.profiles.map(\.id), ["opera:Root"])
        XCTAssertEqual(
            chrome.profiles.map(\.id),
            ["chrome:Default", "chrome:Profile 2"]
        )
        XCTAssertEqual(chrome.coverage.profileCount, 2)
    }

    func testChromiumDiscoveryUsesLocalStateAndExcludesGuestAndSystemProfiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrowserPrivacyLocalState-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome",
            isDirectory: true
        )
        for name in ["Default", "Profile 3", "Guest Profile", "System Profile", "Profile 9"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: directory.appendingPathComponent("History").path,
                contents: Data()
            ))
        }
        let localState: [String: Any] = [
            "profile": [
                "info_cache": [
                    "Default": ["name": "Main"],
                    "Profile 3": ["name": "Work"],
                    "Guest Profile": ["name": "Guest"],
                    "System Profile": ["name": "System"],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: localState).write(
            to: root.appendingPathComponent("Local State")
        )

        let chrome = try XCTUnwrap(BrowserPrivacyProviderRegistry().discover(
            homeDirectory: home,
            installedApplications: [installedApplication(bundleIdentifier: "com.google.Chrome")]
        ).first { $0.coverage.browser.id == "chrome" })

        XCTAssertEqual(chrome.profiles.map(\.id), ["chrome:Default", "chrome:Profile 3"])
        XCTAssertEqual(chrome.profiles.map(\.displayName), ["Main", "Work"])
    }

    func testFirefoxDiscoveryUsesProfilesINIAndIgnoresUnlistedDirectories() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrowserPrivacyFirefoxProfiles-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(
            "Library/Application Support/Firefox",
            isDirectory: true
        )
        let listed = root.appendingPathComponent("Profiles/abc.default-release", isDirectory: true)
        let unlisted = root.appendingPathComponent("Profiles/ignored.profile", isDirectory: true)
        for directory in [listed, unlisted] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: directory.appendingPathComponent("places.sqlite").path,
                contents: Data()
            ))
        }
        try Data("""
        [Profile0]
        Name=Primary
        IsRelative=1
        Path=Profiles/abc.default-release
        Default=1
        """.utf8).write(to: root.appendingPathComponent("profiles.ini"))

        let firefox = try XCTUnwrap(BrowserPrivacyProviderRegistry().discover(
            homeDirectory: home,
            installedApplications: [installedApplication(bundleIdentifier: "org.mozilla.firefox")]
        ).first { $0.coverage.browser.id == "firefox" })

        XCTAssertEqual(firefox.profiles.map(\.id), ["firefox:abc.default-release"])
        XCTAssertEqual(firefox.profiles.map(\.displayName), ["Primary"])
    }

    func testRegisteredProvidersExposeOnlyAuditedChromiumProductionAdapter() {
        let providers = BrowserPrivacyProviderRegistry.defaultProviders
        XCTAssertEqual(providers.count, 14)
        XCTAssertTrue(providers.filter { $0.descriptor.engine == .chromium }
            .allSatisfy { $0.historyWriteAdapter == .chromiumProduction })
        XCTAssertTrue(providers.filter { $0.descriptor.engine != .chromium }
            .allSatisfy { $0.historyWriteAdapter == nil })

        let reasons = Set(
            BrowserPrivacyProviderRegistry.defaultProviders.map {
                BrowserPrivacySQLiteWriteAdapter.manualGuidanceReason(
                    for: $0.descriptor.engine
                )
            }
        )
        XCTAssertTrue(reasons.contains { $0.localizedCaseInsensitiveContains("Safari") })
        XCTAssertTrue(reasons.contains { $0.localizedCaseInsensitiveContains("Chromium") })
        XCTAssertTrue(reasons.contains { $0.localizedCaseInsensitiveContains("Firefox") })
        XCTAssertTrue(reasons.allSatisfy {
            $0.localizedCaseInsensitiveContains("parent")
                || $0.localizedCaseInsensitiveContains("derived")
                || $0.localizedCaseInsensitiveContains("frecency")
                || $0.localizedCaseInsensitiveContains("sidecar")
        })
    }

    func testRegistryReturnsOnlyInstalledSupportedBrowsers() {
        let discoveries = BrowserPrivacyProviderRegistry().discover(
            homeDirectory: FileManager.default.temporaryDirectory,
            installedApplications: [installedApplication(bundleIdentifier: "com.google.Chrome")]
        )

        XCTAssertEqual(discoveries.map(\.coverage.browser.id), ["chrome"])
        XCTAssertEqual(discoveries.first?.coverage.browser.bundleIdentifier, "com.google.Chrome")
    }

    private func installedApplication(
        bundleIdentifier: String
    ) -> BrowserPrivacyInstalledApplication {
        BrowserPrivacyInstalledApplication(
            bundleIdentifier: bundleIdentifier,
            version: "1.0",
            url: URL(fileURLWithPath: "/Applications/Fixture.app"),
            isDefaultBrowser: false
        )
    }

    func testChromeV70ProductionSnapshotMintsLocatorsForExactSchema() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)

        let outcome = try await fixture.scanOutcome()

        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator != nil })
    }

    func testChromeV70ProductionSnapshotWithExtraColumnStaysReadableButManual() async throws {
        let fixture = try ChromiumV70HistoryFixture(
            mode: .production,
            productionSchemaMutation: .extraVisitColumn
        )

        let outcome = try await fixture.scanOutcome()

        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil })
    }

    func testChromeV70ProductionSnapshotWithMissingColumnStaysReadableButManual() async throws {
        let fixture = try ChromiumV70HistoryFixture(
            mode: .production,
            productionSchemaMutation: .missingAppID
        )

        let outcome = try await fixture.scanOutcome()

        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil })
    }

    func testChromeV70ProductionSnapshotWithNonAliasedVisitIDMintsNoLocator() async throws {
        let fixture = try ChromiumV70HistoryFixture(
            mode: .production,
            productionSchemaMutation: .nonAliasedVisitID
        )

        let outcome = try await fixture.scanOutcome()

        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil })
    }

    func testChromiumProductionRejectsUnexpectedPragmaSignature() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try fixture.execute("PRAGMA user_version = 1")

        let outcome = try await fixture.scanOutcome()

        XCTAssertFalse(outcome.records.isEmpty)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil })
    }

    func testChromeV70ProductionSnapshotWithForeignKeyMintsNoLocator() async throws {
        let fixture = try ChromiumV70HistoryFixture(
            mode: .production,
            productionSchemaMutation: .declaredForeignKey
        )

        let outcome = try await fixture.scanOutcome()

        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(outcome.records.count, 4)
        XCTAssertTrue(outcome.records.allSatisfy { $0.locator == nil })
    }

    func testMismatchedVerifiedAdapterDoesNotMintAWriteLocator() async throws {
        let fixture = try BrowserPrivacyFixtureDatabase()
        try fixture.insert(
            url: "https://fixture.example/",
            title: "Fixture",
            visitCount: 1,
            visitedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        let outcome = try await fixture.scanner(
            adapter: .verified(for: .firefox)
        ).scan()

        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertNil(outcome.records.first?.locator)
    }

    func testPartialCoveragePreservesExplicitFullDiskAccessRequirement() async throws {
        let browser = BrowserPrivacyBrowser(
            id: "permission-fixture",
            displayName: "Permission Fixture",
            engine: .chromium,
            bundleIdentifier: "com.storagecleaner.permission-fixture",
            version: "1.0"
        )
        let provider = BrowserPrivacyPermissionCoverageProvider(browser: browser)
        let scanner = BrowserPrivacyRecordScanner(
            registry: BrowserPrivacyProviderRegistry(providers: [provider]),
            homeDirectory: FileManager.default.temporaryDirectory,
            installedApplications: [installedApplication(
                bundleIdentifier: "com.storagecleaner.permission-fixture"
            )]
        )

        let outcome = try await scanner.scan()
        let coverage = try XCTUnwrap(outcome.coverage.first)

        XCTAssertEqual(outcome.state, .partial)
        XCTAssertEqual(coverage.availability, .partial)
        XCTAssertTrue(coverage.requiresFullDiskAccess)
        XCTAssertTrue(coverage.detail?.localizedCaseInsensitiveContains("Full Disk Access") == true)
        XCTAssertTrue(outcome.records.isEmpty)
    }

    func testBrowserPrivacySourcesStayLocalAndNeverOpenHistoryURLs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURLs = [
            root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/BrowserPrivacy/Scanning/BrowserPrivacyRecordScanner.swift"
            ),
            root.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/BrowserPrivacy/Classification/BrowserPrivacyLocalClassifier.swift"
            ),
        ]

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(source.contains("URLSession"))
            XCTAssertFalse(source.contains("NSWorkspace.shared.open"))
        }
        let scanner = try String(contentsOf: sourceURLs[0], encoding: .utf8)
        XCTAssertTrue(scanner.contains("searchKeyword(from: url)"))
        XCTAssertFalse(scanner.contains("searchKeyword(from: title)"))
    }

    func testRefreshKeepsCachedRowsVisibleAndCancellationRestoresTerminalState() async {
        let cached = BrowserPrivacyTestFactory.record(
            domain: "cached.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let coverage = BrowserPrivacyTestFactory.coverage(
            browser: cached.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1
        )
        let scanner = BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [cached], coverage: [coverage])),
            .suspend,
        ])
        let store = BrowserPrivacyStore(scanner: scanner)

        store.startScan()
        await store.waitUntilIdle()
        XCTAssertEqual(store.records.map(\.id), [cached.id])
        XCTAssertTrue(store.selectedRecordIDs.isEmpty)
        store.setSelected(true, recordID: cached.id)
        XCTAssertEqual(store.selectedRecordIDs, [cached.id])

        store.startScan()
        XCTAssertEqual(store.state, .scanning)
        XCTAssertTrue(store.hasCachedResults)
        XCTAssertTrue(store.isRefreshingCachedResults)
        XCTAssertEqual(store.records.map(\.id), [cached.id])
        XCTAssertEqual(store.coverage, [coverage])
        XCTAssertEqual(store.selectedRecordIDs, [cached.id])

        store.setSelected(false, recordID: cached.id)
        store.clearSelection()
        XCTAssertEqual(
            store.selectedRecordIDs,
            [cached.id],
            "cached selection must stay read-only while a replacement snapshot is in flight"
        )

        store.prepareManualGuidance()
        XCTAssertNil(store.processingReport, "cached rows must not be processed during refresh")

        store.cancel()
        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(store.error, .cancelled)
        XCTAssertEqual(store.records.map(\.id), [cached.id])
        XCTAssertEqual(store.coverage, [coverage])
        XCTAssertEqual(store.selectedRecordIDs, [cached.id])
    }

    func testFailedRefreshPreservesPartialCacheAndPublishesTheFailure() async {
        let cached = BrowserPrivacyTestFactory.record(
            domain: "cached.example",
            searchKeyword: nil,
            category: .finance,
            confidence: .medium,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let coverage = BrowserPrivacyTestFactory.coverage(
            browser: cached.browser,
            availability: .partial,
            profileCount: 1,
            recordCount: 1
        )
        let scanner = BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .partial, records: [cached], coverage: [coverage])),
            .failure(.readFailed),
        ])
        let store = BrowserPrivacyStore(scanner: scanner)

        store.startScan()
        await store.waitUntilIdle()
        store.startScan()
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .partial)
        XCTAssertEqual(store.error, .readFailed)
        XCTAssertEqual(store.records.map(\.id), [cached.id])
        XCTAssertEqual(store.coverage, [coverage])
    }

    func testSuccessfulRefreshReplacesCacheAndClearsUnavailableIdentityFilters() async {
        let chrome = BrowserPrivacyTestFactory.record(
            browserID: "chrome",
            browserName: "Chrome",
            profileID: "chrome:Profile 2",
            domain: "old.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let safari = BrowserPrivacyTestFactory.record(
            browserID: "safari",
            browserName: "Safari",
            profileID: "safari:Safari",
            domain: "new.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: Date(timeIntervalSince1970: 1_750_000_100)
        )
        let scanner = BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [chrome], coverage: [])),
            .outcome(.init(state: .completed, records: [safari], coverage: [])),
        ])
        let store = BrowserPrivacyStore(scanner: scanner)

        store.startScan()
        await store.waitUntilIdle()
        store.filters.browserID = chrome.browser.id
        store.filters.profileID = chrome.profileID

        store.startScan()
        await store.waitUntilIdle()

        XCTAssertEqual(store.records.map(\.id), [safari.id])
        XCTAssertNil(store.filters.browserID)
        XCTAssertNil(store.filters.profileID)
        XCTAssertNil(store.error)
    }

    func testManualReverificationUsesStableFingerprintInsteadOfFreshRecordUUID() async {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let before = BrowserPrivacyTestFactory.record(
            domain: "stable.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: date
        )
        let after = BrowserPrivacyTestFactory.record(
            domain: "stable.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: date
        )
        XCTAssertNotEqual(before.id, after.id)
        XCTAssertEqual(before.reverificationFingerprint, after.reverificationFingerprint)
        let coverage = BrowserPrivacyTestFactory.coverage(
            browser: before.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1,
            fullyScannedProfileIDs: [before.profileID]
        )
        let store = BrowserPrivacyStore(scanner: BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [before], coverage: [coverage])),
            .outcome(.init(state: .completed, records: [after], coverage: [coverage])),
        ]))

        store.startScan()
        await store.waitUntilIdle()
        store.setFilteredSelection(true)
        store.prepareManualGuidance()
        let report = store.processingReport
        store.startScan()
        await store.waitUntilIdle()

        XCTAssertEqual(
            store.reverificationStatus,
            .stillPresent(remainingCount: 1, totalCount: 1)
        )
        XCTAssertEqual(store.processingReport, report)
        XCTAssertEqual(store.manualGuidanceRecords.map(\.id), [before.id])
    }

    func testManualReverificationReportsNoLongerFoundOnlyAfterCompleteCoverage() async {
        let record = BrowserPrivacyTestFactory.record(
            domain: "removed.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let coverage = BrowserPrivacyTestFactory.coverage(
            browser: record.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1,
            fullyScannedProfileIDs: [record.profileID]
        )
        let emptyCoverage = BrowserPrivacyTestFactory.coverage(
            browser: record.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 0,
            fullyScannedProfileIDs: [record.profileID]
        )
        let store = BrowserPrivacyStore(scanner: BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [record], coverage: [coverage])),
            .outcome(.init(state: .completed, records: [], coverage: [emptyCoverage])),
        ]))

        store.startScan()
        await store.waitUntilIdle()
        store.setFilteredSelection(true)
        store.prepareManualGuidance()
        store.startScan()
        await store.waitUntilIdle()

        XCTAssertEqual(store.reverificationStatus, .noLongerFound(totalCount: 1))
        XCTAssertNotNil(store.processingReport)
    }

    func testPartialAndPermissionLimitedReverificationRemainUnconfirmed() async {
        let record = BrowserPrivacyTestFactory.record(
            domain: "unconfirmed.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let available = BrowserPrivacyTestFactory.coverage(
            browser: record.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1,
            fullyScannedProfileIDs: [record.profileID]
        )
        let partial = BrowserPrivacyTestFactory.coverage(
            browser: record.browser,
            availability: .partial,
            profileCount: 1,
            recordCount: 0
        )
        let permission = BrowserPrivacyTestFactory.coverage(
            browser: record.browser,
            availability: .permissionDenied,
            profileCount: 1,
            recordCount: 0,
            requiresFullDiskAccess: true
        )

        for outcome in [
            BrowserPrivacyScanOutcome(state: .partial, records: [], coverage: [partial]),
            BrowserPrivacyScanOutcome(state: .permissionDenied, records: [], coverage: [permission]),
        ] {
            let store = BrowserPrivacyStore(scanner: BrowserPrivacySequenceScanner(steps: [
                .outcome(.init(state: .completed, records: [record], coverage: [available])),
                .outcome(outcome),
            ]))
            store.startScan()
            await store.waitUntilIdle()
            store.setFilteredSelection(true)
            store.prepareManualGuidance()
            store.startScan()
            await store.waitUntilIdle()

            XCTAssertEqual(
                store.reverificationStatus,
                .coverageIncomplete(totalCount: 1)
            )
            XCTAssertNotNil(store.processingReport)
        }
    }

    func testReverificationKeepsReportWhileCheckingAndCancellationCannotClaimSuccess() async {
        let record = BrowserPrivacyTestFactory.record(
            domain: "cancelled.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let coverage = BrowserPrivacyTestFactory.coverage(
            browser: record.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1,
            fullyScannedProfileIDs: [record.profileID]
        )
        let store = BrowserPrivacyStore(scanner: BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [record], coverage: [coverage])),
            .suspend,
        ]))
        store.startScan()
        await store.waitUntilIdle()
        store.setFilteredSelection(true)
        store.prepareManualGuidance()
        let report = store.processingReport

        store.startScan()
        XCTAssertEqual(store.reverificationStatus, .checking(totalCount: 1))
        XCTAssertEqual(store.processingReport, report)
        store.cancel()

        XCTAssertEqual(store.reverificationStatus, .coverageIncomplete(totalCount: 1))
        XCTAssertEqual(store.processingReport, report)
        XCTAssertNotEqual(store.reverificationStatus, .noLongerFound(totalCount: 1))
    }

    func testFailedReverificationCannotClaimSuccess() async {
        let record = BrowserPrivacyTestFactory.record(
            domain: "failed.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let coverage = BrowserPrivacyTestFactory.coverage(
            browser: record.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1,
            fullyScannedProfileIDs: [record.profileID]
        )
        let store = BrowserPrivacyStore(scanner: BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [record], coverage: [coverage])),
            .failure(.readFailed),
        ]))
        store.startScan()
        await store.waitUntilIdle()
        store.setFilteredSelection(true)
        store.prepareManualGuidance()
        let report = store.processingReport
        store.startScan()
        await store.waitUntilIdle()

        XCTAssertEqual(store.reverificationStatus, .coverageIncomplete(totalCount: 1))
        XCTAssertEqual(store.processingReport, report)
        XCTAssertEqual(store.error, .readFailed)
    }

    func testReverificationRejectsAReplacementProfileFromTheSameBrowser() async {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let original = BrowserPrivacyTestFactory.record(
            profileID: "fixture:Default",
            domain: "removed.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: date
        )
        let replacement = BrowserPrivacyTestFactory.record(
            profileID: "fixture:Profile 2",
            domain: "other.example",
            searchKeyword: nil,
            category: .other,
            confidence: .low,
            date: date
        )
        let originalCoverage = BrowserPrivacyTestFactory.coverage(
            browser: original.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1,
            fullyScannedProfileIDs: [original.profileID]
        )
        let replacementCoverage = BrowserPrivacyTestFactory.coverage(
            browser: replacement.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1,
            fullyScannedProfileIDs: [replacement.profileID]
        )
        let store = BrowserPrivacyStore(scanner: BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [original], coverage: [originalCoverage])),
            .outcome(.init(state: .completed, records: [replacement], coverage: [replacementCoverage])),
        ]))

        store.startScan()
        await store.waitUntilIdle()
        store.setFilteredSelection(true)
        store.prepareManualGuidance()
        store.startScan()
        await store.waitUntilIdle()

        XCTAssertEqual(store.reverificationStatus, .coverageIncomplete(totalCount: 1))
    }

    func testReverificationCountsDuplicateFingerprintsAsAMultiset() async {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let first = BrowserPrivacyTestFactory.record(
            domain: "duplicate.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: date
        )
        let second = BrowserPrivacyTestFactory.record(
            domain: "duplicate.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: date
        )
        let remaining = BrowserPrivacyTestFactory.record(
            domain: "duplicate.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: date
        )
        XCTAssertEqual(first.reverificationFingerprint, second.reverificationFingerprint)
        let beforeCoverage = BrowserPrivacyTestFactory.coverage(
            browser: first.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 2,
            fullyScannedProfileIDs: [first.profileID]
        )
        let afterCoverage = BrowserPrivacyTestFactory.coverage(
            browser: remaining.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1,
            fullyScannedProfileIDs: [remaining.profileID]
        )
        let store = BrowserPrivacyStore(scanner: BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [first, second], coverage: [beforeCoverage])),
            .outcome(.init(state: .completed, records: [remaining], coverage: [afterCoverage])),
        ]))

        store.startScan()
        await store.waitUntilIdle()
        store.setFilteredSelection(true)
        store.prepareManualGuidance()
        store.startScan()
        await store.waitUntilIdle()

        XCTAssertEqual(
            store.reverificationStatus,
            .stillPresent(remainingCount: 1, totalCount: 2)
        )
    }

    func testInjectedBrowserPrivacySessionSurvivesWorkspaceReconstruction() async {
        let record = BrowserPrivacyTestFactory.record(
            domain: "retained.example.xxx",
            searchKeyword: nil,
            category: .adult,
            confidence: .high,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let coverage = BrowserPrivacyTestFactory.coverage(
            browser: record.browser,
            availability: .available,
            profileCount: 1,
            recordCount: 1,
            fullyScannedProfileIDs: [record.profileID]
        )
        let sessionStore = BrowserPrivacyStore(scanner: BrowserPrivacySequenceScanner(steps: [
            .outcome(.init(state: .completed, records: [record], coverage: [coverage])),
        ]))

        sessionStore.startScan()
        await sessionStore.waitUntilIdle()
        let firstWorkspace = BrowserPrivacyWorkspaceView(
            browserPrivacyStore: sessionStore
        )
        let reconstructedWorkspace = BrowserPrivacyWorkspaceView(
            browserPrivacyStore: sessionStore
        )

        XCTAssertTrue(firstWorkspace.browserPrivacyStore === sessionStore)
        XCTAssertTrue(reconstructedWorkspace.browserPrivacyStore === sessionStore)
        XCTAssertEqual(reconstructedWorkspace.browserPrivacyStore.records.map(\.id), [record.id])
    }
}

private struct BrowserPrivacyFixtureProvider: BrowserHistoryProvider {
    let descriptor: BrowserPrivacyProviderDescriptor
    let profile: BrowserPrivacyProfile
    let historyWriteAdapter: BrowserPrivacySQLiteWriteAdapter?

    func discoverProfiles(
        homeDirectory: URL,
        installedApplications: [BrowserPrivacyInstalledApplication]
    ) -> BrowserPrivacyProviderDiscovery {
        BrowserPrivacyProviderDiscovery(
            coverage: BrowserPrivacyProviderCoverage(
                browser: profile.browser,
                availability: .available,
                profileCount: 1,
                recordCount: 0,
                detail: nil
            ),
            profiles: [profile]
        )
    }
}

private struct BrowserPrivacyPermissionCoverageProvider: BrowserHistoryProvider {
    let descriptor: BrowserPrivacyProviderDescriptor
    let browser: BrowserPrivacyBrowser

    init(browser: BrowserPrivacyBrowser) {
        self.browser = browser
        descriptor = BrowserPrivacyProviderDescriptor(
            id: browser.id,
            displayName: browser.displayName,
            engine: browser.engine,
            bundleIdentifiers: [browser.bundleIdentifier ?? "com.storagecleaner.permission-fixture"],
            profileRootRelativePaths: []
        )
    }

    func discoverProfiles(
        homeDirectory: URL,
        installedApplications: [BrowserPrivacyInstalledApplication]
    ) -> BrowserPrivacyProviderDiscovery {
        BrowserPrivacyProviderDiscovery(
            coverage: BrowserPrivacyProviderCoverage(
                browser: browser,
                availability: .partial,
                profileCount: 1,
                recordCount: 0,
                detail: "Some profiles need Full Disk Access.",
                requiresFullDiskAccess: true
            ),
            profiles: []
        )
    }
}

private struct BrowserPrivacyStaticScanner: BrowserPrivacyScanning {
    let outcome: BrowserPrivacyScanOutcome

    func scan() async throws -> BrowserPrivacyScanOutcome {
        outcome
    }
}

private enum BrowserPrivacySequenceStep: Sendable {
    case outcome(BrowserPrivacyScanOutcome)
    case failure(BrowserPrivacyScanError)
    case suspend
}

private actor BrowserPrivacySequenceScanner: BrowserPrivacyScanning {
    private var steps: [BrowserPrivacySequenceStep]

    init(steps: [BrowserPrivacySequenceStep]) {
        self.steps = steps
    }

    func scan() async throws -> BrowserPrivacyScanOutcome {
        guard !steps.isEmpty else { throw BrowserPrivacyScanError.readFailed }
        let step = steps.removeFirst()
        switch step {
        case let .outcome(outcome):
            return outcome
        case let .failure(error):
            throw error
        case .suspend:
            try await Task.sleep(for: .seconds(30))
            throw BrowserPrivacyScanError.readFailed
        }
    }
}

private struct BrowserPrivacyStaticProcessor: BrowserPrivacyHistoryProcessing {
    let report: BrowserPrivacyProcessingReport

    func process(records: [BrowserPrivacyRecord]) async -> BrowserPrivacyProcessingReport {
        report
    }
}

private struct BrowserPrivacyStaticRunningChecker: BrowserPrivacyRunningApplicationChecking {
    let values: Set<String>

    func runningBundleIdentifiers(matching bundleIdentifiers: Set<String>) async -> Set<String> {
        values.intersection(bundleIdentifiers)
    }
}

private enum BrowserPrivacyTestFactory {
    static func record(
        browserID: String = "fixture",
        browserName: String = "Fixture Browser",
        profileID: String = "fixture:Default",
        domain: String,
        title: String? = nil,
        searchKeyword: String?,
        category: BrowserPrivacyCategory,
        confidence: BrowserPrivacySelectionConfidence,
        date: Date,
        bundleIdentifier: String? = nil,
        sizeBytes: Int64? = nil,
        locator: BrowserPrivacyRecordLocator? = nil
    ) -> BrowserPrivacyRecord {
        let browser = BrowserPrivacyBrowser(
            id: browserID,
            displayName: browserName,
            engine: .chromium,
            bundleIdentifier: bundleIdentifier,
            version: nil
        )
        return BrowserPrivacyRecord(
            id: UUID(),
            browser: browser,
            profileID: profileID,
            source: .history,
            url: "https://\(domain)/",
            domain: domain,
            title: title,
            searchKeyword: searchKeyword,
            visitedAt: date,
            visitCount: 1,
            category: category,
            selectionConfidence: confidence,
            sizeBytes: sizeBytes,
            locator: locator
        )
    }

    static func locator(profileID: String) -> BrowserPrivacyRecordLocator {
        let trustedParent = URL(fileURLWithPath: "/tmp/browser-privacy-fixture", isDirectory: true)
        return BrowserPrivacyRecordLocator(
            providerID: "chrome",
            profileID: profileID,
            engine: .chromium,
            visitRowID: 1,
            parentRowID: 1,
            visitTimestampIdentity: .integer(1),
            rawURL: "https://candidate.example/",
            databaseURL: trustedParent.appendingPathComponent("History"),
            trustedParentURL: trustedParent,
            identityChain: [.init(device: 1, inode: 1, kind: 1)]
        )
    }

    static func coverage(
        browser: BrowserPrivacyBrowser,
        availability: BrowserPrivacyProviderAvailability,
        profileCount: Int,
        recordCount: Int,
        requiresFullDiskAccess: Bool = false,
        fullyScannedProfileIDs: Set<String> = []
    ) -> BrowserPrivacyProviderCoverage {
        BrowserPrivacyProviderCoverage(
            browser: browser,
            availability: availability,
            profileCount: profileCount,
            recordCount: recordCount,
            detail: nil,
            requiresFullDiskAccess: requiresFullDiskAccess,
            fullyScannedProfileIDs: fullyScannedProfileIDs
        )
    }
}

private final class BrowserPrivacyFixtureDatabase {
    let root: URL
    let snapshotRoot: URL
    let profile: BrowserPrivacyProfile

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserPrivacyRecordTests-\(UUID().uuidString)", isDirectory: true)
        snapshotRoot = root.appendingPathComponent("snapshots", isDirectory: true)
        let profileRoot = root
            .appendingPathComponent("Library/Application Support/Fixture/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        let databaseURL = profileRoot.appendingPathComponent("History")
        let browser = BrowserPrivacyBrowser(
            id: "fixture",
            displayName: "Fixture Browser",
            engine: .chromium,
            bundleIdentifier: "com.storagecleaner.fixture",
            version: "1.0"
        )
        profile = BrowserPrivacyProfile(
            id: "fixture:Default",
            browser: browser,
            displayName: "Default",
            historyDatabaseURL: databaseURL,
            sourceTrustedParentURL: profileRoot
        )
        let database = try Self.open(at: databaseURL)
        defer { sqlite3_close_v2(database) }
        try Self.execute(
            """
            CREATE TABLE urls (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL,
                title TEXT,
                visit_count INTEGER
            );
            CREATE TABLE visits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url INTEGER NOT NULL,
                visit_time INTEGER
            );
            """,
            database: database
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func insert(
        url: String,
        title: String?,
        visitCount: Int64,
        visitedAt: Date
    ) throws {
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        let urlStatement = try Self.prepare(
            "INSERT INTO urls (url, title, visit_count) VALUES (?1, ?2, ?3)",
            database: database
        )
        defer { sqlite3_finalize(urlStatement) }
        guard sqlite3_bind_text(urlStatement, 1, url, -1, browserPrivacySQLiteTransient) == SQLITE_OK,
              sqlite3_bind_int64(urlStatement, 3, visitCount) == SQLITE_OK else {
            throw BrowserPrivacyFixtureError.sqlite
        }
        if let title {
            guard sqlite3_bind_text(urlStatement, 2, title, -1, browserPrivacySQLiteTransient) == SQLITE_OK else {
                throw BrowserPrivacyFixtureError.sqlite
            }
        } else if sqlite3_bind_null(urlStatement, 2) != SQLITE_OK {
            throw BrowserPrivacyFixtureError.sqlite
        }
        guard sqlite3_step(urlStatement) == SQLITE_DONE else { throw BrowserPrivacyFixtureError.sqlite }

        let visitStatement = try Self.prepare(
            "INSERT INTO visits (url, visit_time) VALUES (?1, ?2)",
            database: database
        )
        defer { sqlite3_finalize(visitStatement) }
        let chromiumMicroseconds = Int64(
            (visitedAt.timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        )
        guard sqlite3_bind_int64(visitStatement, 1, sqlite3_last_insert_rowid(database)) == SQLITE_OK,
              sqlite3_bind_int64(visitStatement, 2, chromiumMicroseconds) == SQLITE_OK,
              sqlite3_step(visitStatement) == SQLITE_DONE else {
            throw BrowserPrivacyFixtureError.sqlite
        }
    }

    func scanner(
        adapter: BrowserPrivacySQLiteWriteAdapter? = .verified(for: .chromium),
        limits: BrowserPrivacyRecordScanLimits = BrowserPrivacyRecordScanLimits(
            totalTimeoutSeconds: 2
        )
    ) -> BrowserPrivacyRecordScanner {
        let provider = BrowserPrivacyFixtureProvider(
            descriptor: BrowserPrivacyProviderDescriptor(
                id: profile.browser.id,
                displayName: profile.browser.displayName,
                engine: .chromium,
                bundleIdentifiers: [],
                profileRootRelativePaths: []
            ),
            profile: profile,
            historyWriteAdapter: adapter
        )
        return BrowserPrivacyRecordScanner(
            registry: BrowserPrivacyProviderRegistry(providers: [provider]),
            snapshotService: SQLiteSnapshotService(temporaryRoot: snapshotRoot),
            homeDirectory: root,
            installedApplications: [],
            limits: limits
        )
    }

    func historyRowCount() throws -> Int {
        let database = try Self.open(at: profile.historyDatabaseURL)
        defer { sqlite3_close_v2(database) }
        let statement = try Self.prepare("SELECT count(*) FROM visits", database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw BrowserPrivacyFixtureError.sqlite }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func snapshotResidues() throws -> [URL] {
        let container = snapshotRoot.appendingPathComponent(
            SQLiteSnapshotService.temporaryContainerName,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: container.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    private static func open(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw BrowserPrivacyFixtureError.sqlite
        }
        return database
    }

    private static func execute(_ sql: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw BrowserPrivacyFixtureError.sqlite
        }
    }

    private static func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw BrowserPrivacyFixtureError.sqlite
        }
        return statement
    }
}

private enum BrowserPrivacyFixtureError: Error {
    case sqlite
}

private let browserPrivacySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
