import Foundation
import XCTest
@testable import StorageCleanerMac

#if DEBUG
@MainActor
final class BrowserPrivacyLightfieldTests: XCTestCase {
    func testGroupsKeepBrowsersProfilesAndPagesSeparate() {
        let rows = BrowserPrivacyPreviewFixture.outcome.records
        let groups = BrowserPrivacyLightfieldPresentation.groups(BrowserPrivacyDisplayItem.aggregate(rows))
        XCTAssertEqual(groups.map(\.browser.id), ["safari", "chrome", "chrome"])
        XCTAssertEqual(Set(groups.map(\.id)).count, 3)
        XCTAssertEqual(groups.flatMap(\.records).count, rows.count)
        let chrome = groups.first { $0.id.profileID == "chrome:Default" }!
        let news = chrome.sites.first { $0.title == "news.example" }!
        XCTAssertEqual(news.records.count, 5)
        XCTAssertEqual(news.pages.count, 3)
        XCTAssertEqual(news.pages.first?.visitCount, 3)
        XCTAssertEqual(news.latestVisit, news.records.compactMap(\.visitedAt).max())
        XCTAssertTrue(chrome.sites.contains { $0.id.domain.isEmpty })
        XCTAssertFalse(chrome.sites.contains { $0.title.contains("chrome://") })
    }

    func testSensitiveBucketCoversEveryExistingSensitiveCategoryAndMasksSite() {
        let groups = BrowserPrivacyLightfieldPresentation.groups(BrowserPrivacyDisplayItem.aggregate(BrowserPrivacyPreviewFixture.outcome.records))
        let group = groups.first { $0.id.profileID == "chrome:Default" }!
        XCTAssertEqual(group.sensitiveSites.count, 2)
        XCTAssertEqual(group.sensitiveSites.flatMap(\.records).count, 2)
        XCTAssertTrue(group.sensitiveSites.allSatisfy { !$0.concealedTitle.contains($0.title) })
        XCTAssertTrue(group.regularSites.allSatisfy { !$0.isSensitive })
        for category in BrowserPrivacyCategory.allCases {
            XCTAssertEqual(BrowserPrivacyLightfieldPresentation.isSensitive(category), category == .adult || category == .finance)
        }
    }

    func testSearchAndDateCannotDeclassifyMixedSensitiveDomain() {
        let row = BrowserPrivacyPreviewFixture.outcome.records.first { $0.category == .adult }!
        let nonSensitive = BrowserPrivacyRecord(id: UUID(), browser: row.browser, profileID: row.profileID,
            profileDisplayName: row.profileDisplayName, source: .history,
            url: "https://private.example/public/guide", domain: "private.example", title: "Public guide",
            searchKeyword: nil, visitedAt: Date(), visitCount: 1, category: .productivity,
            selectionConfidence: .medium, sizeBytes: nil, locator: nil)
        let all = BrowserPrivacyDisplayItem.aggregate([row, nonSensitive])
        let filtered = BrowserPrivacyDisplayItem.aggregate([nonSensitive])
        let group = BrowserPrivacyLightfieldPresentation.groups(filtered, sensitivityItems: all)[0]
        XCTAssertEqual(group.sensitiveSites.count, 1)
        XCTAssertEqual(group.regularSites.count, 0)
        XCTAssertEqual(group.records.count, 1, "Classification must not add filtered-out records to selection")
    }

    func testGroupAndInvertOnlyUseCurrentDeletableIDsAndPreserveOtherSelections() async {
        let store = await BrowserPrivacyPreviewFixture.makeResultStore(outcome: BrowserPrivacyLightfieldTestFixture.outcome)
        let all = store.records
        XCTAssertTrue(store.selectedRecordIDs.isEmpty, "No classifier auto-selection")
        let manual = all.first { $0.browser.id == "safari" && $0.locator == nil }!
        let inGroupManual = all.filter { $0.browser.id == "chrome" && $0.locator == nil }
        XCTAssertEqual(inGroupManual.count, 2, "Exercise manual records inside the selected browser/profile")
        XCTAssertTrue(inGroupManual.allSatisfy { $0.selectionEligibility.canSelect },
            "Manual records can be individually reviewed but must stay out of group deletion")
        let direct = all.first { $0.locator != nil }!
        store.setSelected(true, recordID: manual.id)
        store.filters.browserID = "chrome"
        await store.waitForFilteredResults()
        let ids = BrowserPrivacyLightfieldPresentation.deletableIDs(store.filteredRecords)
        let expected = Set(all.filter { $0.browser.id == "chrome" && $0.locator != nil }.map(\.id))
        XCTAssertEqual(ids, expected)
        XCTAssertTrue(Set(inGroupManual.map(\.id)).isDisjoint(with: ids))
        XCTAssertFalse(ids.contains(manual.id))
        store.setSelection(true, recordIDs: ids)
        XCTAssertEqual(store.selectedRecordIDs, expected.union([manual.id]))
        XCTAssertTrue(Set(inGroupManual.map(\.id)).isDisjoint(with: store.selectedRecordIDs))
        let remaining = BrowserPrivacyLightfieldPresentation.invertedIDs(records: store.filteredRecords, selected: store.selectedRecordIDs)
        XCTAssertTrue(remaining.isEmpty)
        store.setSelection(false, recordIDs: ids)
        XCTAssertEqual(store.selectedRecordIDs, [manual.id])
        store.setSelected(true, recordID: direct.id)
        let invert = BrowserPrivacyLightfieldPresentation.invertedIDs(records: store.filteredRecords, selected: store.selectedRecordIDs)
        XCTAssertEqual(invert, ids.subtracting([direct.id]))
        XCTAssertEqual(BrowserPrivacyLightfieldPresentation.selectionState(ids: ids, selected: [direct.id]), .mixed)
        XCTAssertEqual(BrowserPrivacyLightfieldPresentation.selectionState(ids: [], selected: []), .unchecked)
    }

    func testProductionSearchMatchesTitleURLDecodedParametersAndTimePresets() async {
        let store = await BrowserPrivacyPreviewFixture.makeResultStore()
        store.filters.query = "AI 芯片"
        await store.waitForFilteredResults()
        XCTAssertEqual(store.filteredRecords.count, 1)
        store.filters.query = "step-2"
        await store.waitForFilteredResults()
        XCTAssertEqual(store.filteredRecords.count, 1)
        XCTAssertFalse(BrowserPrivacyRecordPresentation(item: store.filteredDisplayItems[0]).hasRecordedTitle)
        XCTAssertTrue(BrowserPrivacyRecordPresentation(item: store.filteredDisplayItems[0]).title.contains("step-2"))
        store.filters.query = "绿茶"
        await store.waitForFilteredResults()
        XCTAssertEqual(store.filteredRecords.count, 1)
        store.filters.query = ""
        await store.waitForFilteredResults()
        let total = store.filteredRecords.count
        var filters = store.filters
        BrowserPrivacyDatePreset.today.apply(to: &filters, now: Date())
        store.filters = filters
        await store.waitForFilteredResults()
        XCTAssertLessThan(store.filteredRecords.count, total)
        BrowserPrivacyDatePreset.all.apply(to: &filters, now: Date())
        store.filters = filters
        await store.waitForFilteredResults()
        XCTAssertEqual(store.filteredRecords.count, total)
        XCTAssertEqual(BrowserPrivacyLightfieldPresentation.datePresets, [.today, .week, .all])
    }

    func testProductionSourcesUseB2PrimitivesAndKeepProcessingConfirmation() throws {
        let result = try source("Views/BrowserPrivacyRecordResultsView.swift")
        let hierarchy = try source("Views/BrowserPrivacyLightfieldResults.swift")
        for token in ["FeatureLightfieldPage(module: .privacy", "BrowserPrivacyLightfieldResults(",
            "store.processSelectedRecords()", "store.prepareManualGuidance()", "store.requestNormalBrowserExitAndProcess()",
            "BrowserPrivacyRecentDeletionsView(", "BrowserPrivacyProcessingReportView(", "BrowserPrivacyRecoveryText.retentionNotice"] {
            XCTAssertTrue(result.contains(token), token)
        }
        for token in ["LightfieldSummary(", "LightfieldTextSegments(", "LightfieldAppIcon(", "LightfieldStatusGlyph(",
            "FeatureLightfieldCheck(", "FeatureLightfieldDisclosureChevron(", "FeatureLightfieldRowButtonStyle()", "LazyVStack"] {
            XCTAssertTrue(hierarchy.contains(token), token)
        }
        for token in [".glassPanel(", ".ultraThinMaterial", ".thinMaterial", "RoundedRectangle(", "Image(systemName:"] {
            XCTAssertFalse(hierarchy.contains(token), token)
        }
        XCTAssertTrue(result.contains("删除所选记录 ·"))
        XCTAssertTrue(result.contains("只删除所选浏览记录 · 保留书签和密码"))
        XCTAssertTrue(hierarchy.contains("if openSensitive.contains(group.id)"))
        XCTAssertTrue(hierarchy.contains("if expanded {"))
        XCTAssertFalse(hierarchy.contains(".help(site.title)"))
        XCTAssertFalse(hierarchy.contains(".accessibilityLabel(site.title)"))
        let glyph = try source("Views/DesignSystem/FeatureLightfield.swift")
        XCTAssertTrue(glyph.contains("LightfieldStatusGlyph(featureStatus: status)"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + path), encoding: .utf8)
    }
}

/// A profile containing both direct deletion and browser-only records. The
/// manual records deliberately share the direct records' profile and sites.
enum BrowserPrivacyLightfieldTestFixture {
    static var outcome: BrowserPrivacyScanOutcome {
        let fixture = BrowserPrivacyPreviewFixture.outcome
        let page = fixture.records.first { $0.profileID == "chrome:Default" }!
        let manualSites: [(String, BrowserPrivacyCategory)] = [("news.example", .news), ("private.example", .adult)]
        let manual = manualSites.map { domain, category in
            BrowserPrivacyRecord(id: UUID(), browser: page.browser, profileID: page.profileID,
                profileDisplayName: page.profileDisplayName, source: .history,
                url: "https://\(domain)/manual-review", domain: domain, title: "Manual review: \(domain)",
                searchKeyword: nil, visitedAt: Date(), visitCount: 1, category: category,
                selectionConfidence: .medium, sizeBytes: nil, locator: nil,
                directDeletionBlocker: .schemaNotSupported)
        }
        return BrowserPrivacyScanOutcome(state: fixture.state, records: fixture.records + manual, coverage: fixture.coverage)
    }
}
#endif
