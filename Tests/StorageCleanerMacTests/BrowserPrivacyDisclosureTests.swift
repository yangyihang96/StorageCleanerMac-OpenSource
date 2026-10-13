#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor final class BrowserPrivacyDisclosureTests: XCTestCase {
    func testEverySensitiveTextOutletConcealsUntilExplicitDisclosure() throws {
        let mixed = BrowserPrivacyLightfieldTestFixture.outcome.records
        let hidden = mixed.filter { BrowserPrivacyLightfieldPresentation.isSensitive($0.category) }
        XCTAssertEqual(BrowserPrivacyBulkSelectionScope.sensitive.matchingRecordIDs(in: mixed),
            Set(hidden.filter { $0.locator != nil }.map(\.id)), "The new masked group keeps browser-only records manually excluded")
        let manualOnly = hidden.filter { $0.locator == nil }
        XCTAssertFalse(manualOnly.isEmpty)
        XCTAssertEqual(BrowserPrivacyBulkSelectionScope.websiteOptions(from: manualOnly).first?.hasDeletableRecord, false)
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let records = BrowserPrivacyPreviewFixture.outcome.records.filter { $0.category == .adult || $0.category == .finance }
            var policy = BrowserPrivacyDisclosurePolicy.protecting(records)
            let items = BrowserPrivacyDisplayItem.aggregate(records)
            func outlets(_ policy: BrowserPrivacyDisclosurePolicy) -> [String] {
                let bulk = BrowserPrivacyBulkSelectionPresentation(records: records, disclosure: policy)
                let entry = self.entry(records[0], detail: "\(records[0].title!) — \(records[0].url!)")
                return bulk.websiteOptions.map(\.title) + Array(bulk.dateSummaries.values) + [
                    BrowserPrivacyConfirmationText.deletionMessage(records: records, includesIncompletelyReadProfiles: false, disclosure: policy),
                    BrowserPrivacyConfirmationText.preflightMessage(records: records, runningBrowserIDs: ["chrome"], includesIncompletelyReadProfiles: false, disclosure: policy),
                    BrowserPrivacyConfirmationText.manualMessage(records: records, disclosure: policy),
                    BrowserPrivacyPageListText.lines(for: items, disclosure: policy).joined(),
                    BrowserPrivacyReportDisclosurePresentation.detail(entry, records: records, disclosure: policy),
                    BrowserPrivacyReportDisclosurePresentation.count(entry, records: records, disclosure: policy),
                    policy.summary(records)
                ] + items.flatMap { item in
                    let row = BrowserPrivacyRecordPresentation(item: item, disclosure: policy)
                    return [row.title, row.address.collapsed, row.address.full ?? "", row.accessibilityLabel,
                            BrowserPrivacyRecordPresentation.searchHint(for: item, query: item.domain!, disclosure: policy) ?? ""]
                }
            }
            let hidden = outlets(policy).joined(separator: "\n")
            for record in records {
                for secret in [record.domain, record.url, record.title].compactMap({ $0 }) {
                    XCTAssertFalse(hidden.contains(secret), "Concealed outlet leaked \(secret)")
                }
            }
            XCTAssertTrue(hidden.contains(BrowserPrivacyDisclosurePolicy.sensitiveSummary(records.count)))
            XCTAssertTrue(BrowserPrivacyBulkSelectionScope.website(records[0].domain!).matchingRecordIDs(in: records, disclosure: policy).isEmpty)
            XCTAssertEqual(BrowserPrivacyBulkSelectionScope.sensitive.matchingRecordIDs(in: records, disclosure: policy), Set(records.map(\.id)))
            XCTAssertTrue(BrowserPrivacyManualWorkflow.groups(from: policy.visibleRecords(records)).isEmpty,
                "Neither report domains nor clipboard domains receive concealed records")
            policy.revealedSites = Set(records.map(BrowserPrivacyDisclosurePolicy.siteID))
            let visible = outlets(policy).joined(separator: "\n")
            for record in records { XCTAssertTrue(visible.contains(record.domain!)) }
            XCTAssertTrue(visible.contains(records[0].title!))
            XCTAssertFalse(BrowserPrivacyManualWorkflow.groups(from: policy.visibleRecords(records)).isEmpty)
        }
    }

    func testSearchCountsAndBulkSuggestionsDoNotRevealSensitiveMatches() async throws {
        let store = await BrowserPrivacyPreviewFixture.makeResultStore()
        let secret = store.records.first { $0.category == .adult }!
        let hiddenCount = store.resultPresentation!.concealedCount
        for query in [secret.domain!, secret.title!, "/review/page", "not-in-any-history"] {
            store.filters.query = query
            await store.waitForFilteredResults()
            let snapshot = try XCTUnwrap(store.resultPresentation)
            XCTAssertEqual(snapshot.concealedCount, hiddenCount)
            XCTAssertEqual(snapshot.visibleCount, 0)
            XCTAssertTrue(snapshot.records.isEmpty, "Hidden matches cannot enter query all/invert selection")
            XCTAssertEqual(snapshot.bulk.websiteOptions(matching: query).filter(\.isSensitive).map(\.title),
                [BrowserPrivacyDisclosurePolicy.sensitiveSummary(hiddenCount)])
        }
        for keyPath in [\BrowserPrivacyFilters.domain, \.keyword] {
            store.filters.query = ""
            store.filters[keyPath: keyPath] = secret.domain!
            await store.waitForFilteredResults()
            XCTAssertEqual(store.resultPresentation?.concealedCount, hiddenCount)
            XCTAssertTrue(store.filteredRecords.isEmpty)
            store.filters[keyPath: keyPath] = ""
        }
        store.setSensitiveSiteRevealed(true, siteID: BrowserPrivacyDisclosurePolicy.siteID(secret))
        store.filters.query = secret.domain!
        await store.waitForFilteredResults()
        XCTAssertEqual(store.filteredRecords.map(\.id), [secret.id])
        XCTAssertFalse(store.disclosurePolicy.isConcealed(secret))
        store.concealSensitiveSites(browserID: secret.browser.id)
        await store.waitForFilteredResults()
        XCTAssertTrue(store.filteredRecords.isEmpty)
        XCTAssertEqual(store.resultPresentation?.concealedCount, hiddenCount)
    }

    func testSensitiveBucketAggregatesProfilesOncePerBrowser() async throws {
        let store = await BrowserPrivacyPreviewFixture.makeResultStore()
        let group = try XCTUnwrap(store.resultPresentation?.browserGroups.first { $0.id == "chrome" })
        XCTAssertEqual(group.profiles.count, 2)
        XCTAssertEqual(group.sensitiveGroup.sites.count, 3)
        XCTAssertEqual(group.sensitiveGroup.records.count, 4)
        XCTAssertEqual(Set(group.sensitiveGroup.sites.map(\.id.profile.profileID)).count, 2)
        let host = CalibrationAppKitLayoutHost(root: BrowserPrivacyLightfieldBrowser(store: store, group: group,
            pageRow: { AnyView(Text($0.title ?? $0.address ?? "")) }, requestSelection: { _, _, _ in })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
            size: .init(width: 878, height: 1100), dark: true)
        defer { host.close() }
        let label = L10n.text("敏感网站", "Sensitive websites") + " · " + group.sensitiveGroup.title
        try await host.waitForAccessibility(labels: [label], expectedValues: [label: L10n.text("已折叠", "Collapsed")])
        for profile in group.profiles {
            XCTAssertNil(host.element(label: L10n.text("敏感网站", "Sensitive websites") + " · " + profile.title))
        }
        for site in group.sensitiveGroup.sites {
            XCTAssertNil(host.element(label: site.title)); XCTAssertNil(host.element(label: site.concealedTitle))
        }
    }

    func testBulkPopoverAndReceiptAXDoNotExposeConcealedDetails() async throws {
        let records = BrowserPrivacyPreviewFixture.outcome.records.filter { $0.category == .adult }
        let policy = BrowserPrivacyDisclosurePolicy.protecting(records)
        let secret = records[0]
        let size = CGSize(width: 700, height: 650)
        let bulk = CalibrationAppKitLayoutHost(root: BrowserPrivacyBulkSelectionView(records: records,
            isDisabled: false, disclosure: policy, onSelect: { _ in }), size: size, dark: false)
        defer { bulk.close() }
        let aggregate = BrowserPrivacyDisclosurePolicy.sensitiveSummary(records.count)
        try await bulk.waitForAccessibility(labels: [aggregate], pressLabels: [aggregate])
        XCTAssertNil(bulk.element(label: secret.domain!))
        XCTAssertNil(bulk.element(label: L10n.text("选择网站 \(secret.domain!) 的 1 次访问", "Select 1 visit for \(secret.domain!)")))
        let raw = "\(secret.title!) — \(secret.url!)"
        let entry = entry(secret, detail: raw)
        let receipt = CalibrationAppKitLayoutHost(root: BrowserPrivacyProcessingReportView(
            report: .init(selectedRecordCount: 1, entries: [entry]), selectedRecords: records,
            reverificationStatus: nil, onRescan: {}, removeBackup: { _ in false }, disclosure: policy), size: size, dark: false)
        defer { receipt.close() }
        let safeDetail = BrowserPrivacyReportDisclosurePresentation.detail(entry, records: records, disclosure: policy)
        try await receipt.waitForAccessibility(labels: [safeDetail])
        XCTAssertNil(receipt.element(label: raw))
        XCTAssertNil(receipt.element(label: secret.title!)); XCTAssertNil(receipt.element(label: secret.url!))
        XCTAssertEqual(safeDetail, BrowserPrivacyProcessingReason.browserRunning.detail(browserName: secret.browser.displayName),
            "Retain the Chinese structured failure reason")
    }

    func testMixedSensitiveSiteAndReceiptArchiveRemainConcealed() async throws {
        let secret = BrowserPrivacyPreviewFixture.outcome.records.first { $0.category == .adult }!
        let ordinary = BrowserPrivacyRecord(id: UUID(), browser: secret.browser, profileID: secret.profileID,
            source: .history, url: "https://private.example/public", domain: secret.domain, title: "Public page on sensitive site",
            searchKeyword: nil, visitedAt: Date(), visitCount: 1, category: .news,
            selectionConfidence: .medium, sizeBytes: nil)
        let policy = BrowserPrivacyDisclosurePolicy.protecting([secret, ordinary])
        XCTAssertTrue(policy.isConcealed(ordinary))
        XCTAssertNil(BrowserPrivacyRecordPresentation(record: ordinary, disclosure: policy).address.full)
        let store = await BrowserPrivacyPreviewFixture.makeResultStore()
        let selected = store.records.first { $0.category == .adult }!
        store.setSelected(true, recordID: selected.id)
        store.processSelectedRecords()
        await store.waitUntilProcessingCompletes()
        XCTAssertTrue(store.reportPresentationRecords.contains { $0.id == selected.id })
        XCTAssertTrue(store.disclosurePolicy.isConcealed(selected), "Deletion must not erase receipt sensitivity")
    }

    func testConcealedPageRowAXNeverPublishesAddressOrVisitDetails() async throws {
        let secret = BrowserPrivacyPreviewFixture.outcome.records.first { $0.category == .adult }!
        let item = BrowserPrivacyDisplayItem.aggregate([secret])[0]
        let host = CalibrationAppKitLayoutHost(root: BrowserPrivacyLightfieldPageRow(item: item, selectedIDs: [],
            expanded: true, disabled: false, select: {}, disclose: {}, visit: { _ in },
            disclosure: .protecting([secret])).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
            size: .init(width: 700, height: 400), dark: true)
        defer { host.close() }
        let label = BrowserPrivacyDisclosurePolicy.sensitiveSummary(1)
        try await host.waitForAccessibility(labels: [label])
        XCTAssertNil(host.element(label: secret.title!)); XCTAssertNil(host.element(label: secret.url!))
        XCTAssertNil(host.element(label: BrowserPrivacyVisitPresentation.visits(of: item)[0].time))
        let frames = try await host.frames(required: ["lightfield.privacy.page", "fixture.viewport"], size: .init(width: 700, height: 400))
        XCTAssertEqual(frames["lightfield.privacy.page"]?.height ?? 0, 32, accuracy: 0.5,
            "Even a stale expanded page state cannot mount concealed address/visit rows")
    }

    func testVerifiedRemovalCannotDeclassifyRemainingPagesOrBulkOptions() async throws {
        let fixture = BrowserPrivacyPreviewFixture.outcome
        let secret = fixture.records.first { $0.category == .adult }!
        let publicPage = BrowserPrivacyRecord(id: UUID(), browser: secret.browser, profileID: secret.profileID,
            source: .history, url: "https://private.example/public", domain: secret.domain, title: "Remaining public page",
            searchKeyword: nil, visitedAt: Date(), visitCount: 1, category: .news,
            selectionConfidence: .medium, sizeBytes: nil)
        let store = BrowserPrivacyStore(scanner: DisclosureScanner(outcome: .init(state: .completed,
            records: [secret, publicPage], coverage: fixture.coverage)), processor: DisclosureDeletionReceipt(),
            runningApplicationChecker: DisclosureRunningApplications())
        store.startScan(); await store.waitUntilIdle()
        store.setSelected(true, recordID: secret.id)
        store.processSelectedRecords(); await store.waitUntilProcessingCompletes()
        XCTAssertEqual(store.records.map(\.id), [publicPage.id])
        let snapshot = try XCTUnwrap(store.resultPresentation)
        XCTAssertTrue(snapshot.policy.isConcealed(publicPage))
        XCTAssertEqual(snapshot.groups.flatMap(\.sensitiveSites).count, 1)
        XCTAssertTrue(snapshot.groups.flatMap(\.regularSites).isEmpty)
        XCTAssertFalse(snapshot.bulk.websiteOptions.map(\.title).joined().contains(secret.domain!))
        XCTAssertEqual(snapshot.bulk.websiteOptions.map(\.title), [BrowserPrivacyDisclosurePolicy.sensitiveSummary(1)])
        store.filters.query = publicPage.title!
        await store.waitForFilteredResults()
        XCTAssertTrue(store.filteredRecords.isEmpty)
        XCTAssertEqual(store.resultPresentation?.concealedCount, 1)
        store.setSensitiveSiteRevealed(true, siteID: BrowserPrivacyDisclosurePolicy.siteID(publicPage))
        await store.waitForFilteredResults()
        XCTAssertEqual(store.filteredRecords.map(\.id), [publicPage.id])
    }

    private func entry(_ record: BrowserPrivacyRecord, detail: String) -> BrowserPrivacyProcessingEntry {
        .init(browser: record.browser, profileID: record.profileID, recordCount: 1,
              capability: .verifiedVisitDeletion, outcome: .failed, reason: .browserRunning, detail: detail)
    }
}

private struct DisclosureScanner: BrowserPrivacyScanning {
    let outcome: BrowserPrivacyScanOutcome
    func scan() async throws -> BrowserPrivacyScanOutcome { outcome }
}
private struct DisclosureRunningApplications: BrowserPrivacyRunningApplicationChecking {
    func runningBundleIdentifiers(matching bundleIdentifiers: Set<String>) async -> Set<String> { [] }
}
private struct DisclosureDeletionReceipt: BrowserPrivacyHistoryProcessing {
    func process(records: [BrowserPrivacyRecord]) async -> BrowserPrivacyProcessingReport {
        .init(selectedRecordCount: records.count, entries: records.map { record in
            .init(browser: record.browser, profileID: record.profileID, recordCount: 1,
                capability: .verifiedVisitDeletion, outcome: .deleted, verifiedDeletedRecordIDs: [record.id],
                reason: .deletedAndVerified, deletionPath: .direct)
        })
    }
}
#endif
