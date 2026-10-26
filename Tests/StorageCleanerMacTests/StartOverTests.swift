import XCTest
@testable import StorageCleanerMac

/// Report §4 item 12 (CleanMyMac's Start Over, `cmm/14`, `20`, `24`): a
/// results page's Start Over goes back to the module's landing page. These
/// are the two modules that had no way back before; the title bar itself is
/// `CareStudioNavigationTests`' window check.
@MainActor
final class StartOverTests: XCTestCase {
    /// Performance goes back to its landing page; the items read stay, for
    /// the landing page's "read N items last time". Not while they are read
    /// or a change runs.
    func testPerformanceStartsOverToItsLandingPageKeepingTheItemsRead() throws {
        let store = try ScanStore.makeForTests(for: self)
        store.hasScannedStartupItems = true
        let itemCount = store.startupDomainItems.count

        store.isLoadingStartupItems = true
        store.startOverStartupItems()
        XCTAssertTrue(store.hasScannedStartupItems, "not while the items are read")
        store.isLoadingStartupItems = false

        store.isPerformingStartupOperation = true
        store.startOverStartupItems()
        XCTAssertTrue(store.hasScannedStartupItems, "not while a change runs")
        store.isPerformingStartupOperation = false

        store.startOverStartupItems()
        XCTAssertFalse(store.hasScannedStartupItems)
        XCTAssertEqual(store.startupDomainItems.count, itemCount, "the items read stay")
    }

    /// Applications goes back to its landing page with nothing ticked or
    /// filtered. Not while an uninstall runs.
    func testApplicationsStartOverToItsLandingPageWithNothingTicked() throws {
        let store = try ScanStore.makeForTests(for: self)
        let model = ApplicationsManagerModel.of(store)
        store.hasScannedInstalledApps = true
        model.selection = ["/Applications/Fixture.app": ["/Applications/Fixture.app"]]
        model.leftoverSelection = ["leftover"]
        model.installerSelection = ["installer"]
        model.pluginSelection = ["plugin"]
        model.category = .unused
        model.searchText = "fixture"
        model.showsOverview = true

        store.isUninstallingApp = true
        store.startOverInstalledApps()
        XCTAssertTrue(store.hasScannedInstalledApps, "not while an uninstall runs")
        store.isUninstallingApp = false

        model.startOver()
        store.startOverInstalledApps()
        XCTAssertFalse(store.hasScannedInstalledApps)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.leftoverSelection.isEmpty)
        XCTAssertTrue(model.installerSelection.isEmpty)
        XCTAssertTrue(model.pluginSelection.isEmpty)
        XCTAssertEqual(model.category, .all)
        XCTAssertEqual(model.searchText, "")
        XCTAssertFalse(model.showsOverview)
    }

    /// Start Over waits for work that changes something, not for reads: the
    /// Cleanup results start D184's App Thinning check (the main-scan lease)
    /// as they appear, and the window run of 10-23 found Start Over greyed
    /// out by it.
    func testOnlyWorkThatChangesSomethingHoldsStartOver() {
        XCTAssertEqual(Set(HeavyWorkCoordinator.Owner.allCases.filter(\.holdsStartOver)),
                       [.cleanup, .restore, .emptyTrash, .memoryOptimization, .appUpdates, .cloudLocalCopy])
        XCTAssertFalse(HeavyWorkCoordinator.Owner.mainScan.holdsStartOver)
    }

    /// Protection forgets its malware result (D186) with the rest of the
    /// page; its landing page's scan reads it again.
    func testMalwareStartOverForgetsTheResult() async {
        let store = MalwareScanStore(scanner: StartOverMalwareScanner())
        store.startScan()
        await store.waitUntilIdle()
        XCTAssertEqual(store.outcome?.checkedFiles, 7)

        store.startOver()
        XCTAssertNil(store.outcome)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.progress.checkedFiles, 0)
    }

    /// And its recent-item lists (D188), without moving any of them; the
    /// results page reads them again when it next appears.
    func testRecentItemsStartOverForgetsTheListsWithoutMovingThem() throws {
        let fixture = try RecentItemsTestFixture(self)
        try fixture.write(count: 3)
        let store = RecentItemsStore(environment: fixture.environment, snapshot: fixture.scanner.scan())
        store.setSelected(true, listID: try XCTUnwrap(store.snapshot?.lists.first?.id))
        XCTAssertFalse(store.selectedIDs.isEmpty)

        store.startOver()
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertNil(store.confirmation)
        XCTAssertTrue(fixture.events.values.isEmpty, "nothing was moved")
    }
}

/// A malware scan that checks seven files and finds nothing.
private struct StartOverMalwareScanner: MalwareScanning {
    func scan(progress: @escaping @Sendable (MalwareScanProgress) -> Void) async -> MalwareScanOutcome {
        MalwareScanOutcome(checkedFiles: 7)
    }
}
