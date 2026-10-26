import XCTest
@testable import StorageCleanerMac

@MainActor
final class MyActivityPageTests: XCTestCase {
    private let now = MyActivityD187Fixtures.now

    func testCardTitlesNumbersAndNoSnapshotCopyInBothLanguages() {
        let mac = MyActivityMacInfo(modelName: "Mac14,12", startupDiskName: "Fixture Disk",
                                  capacity: StorageCapacitySnapshot(totalBytes: 500_000_000_000, availableBytes: 100_000_000_000))
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let chinese = language == .zhHans
            XCTAssertEqual(MyActivityHealth.title, chinese ? "Mac 健康度" : "Mac Health")
            XCTAssertEqual(MyActivityHealth.evaluate(nil, now: now).statusText, chinese ? "还没检查过" : "Not Checked Yet")
            XCTAssertEqual(MyActivityTimeSavings.title, chinese ? "节省的时间（估算）" : "Time Saved (Estimated)")
            XCTAssertEqual(MyActivityRecommendations.title(count: 1_200), chinese ? "1,200 条推荐" : "1,200 Recommendations")
            XCTAssertEqual(mac.capacityText, chinese ? "已用 400 GB / 共 500 GB" : "400 GB used / 500 GB total")
            let states: [(MyActivityHealth.Grade, String)] = [(.good, chinese ? "良好" : "Good"),
                (.attention, chinese ? "需要注意" : "Needs Attention"), (.problem, chinese ? "有问题" : "Problems Found")]
            for (grade, title) in states { XCTAssertEqual(grade.title, title) }
        }
    }

    func testRecommendationStringsUseGroupedCountsAndStorageUnitsInBothLanguages() throws {
        var state = MyActivityD187Fixtures.noRecommendations()
        state.recoverableTrashBytes = 1_000_000_000
        state.availableUpdateCount = 1_200
        state.loginItemCount = 1_200
        state.recommendedMaintenanceCount = 1_200
        state.hasProtectionScan = false
        state.thirdPartyCloudFolderCount = 1
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            let values = MyActivityRecommendations.make(state, now: now)
            for kind in [MyActivityRecommendation.Kind.updates, .loginItems, .maintenance] {
                XCTAssertTrue(try XCTUnwrap(values.first { $0.kind == kind }).detail.contains("1,200"))
            }
            XCTAssertTrue(try XCTUnwrap(values.first { $0.kind == .trash }).detail.contains("1 GB"))
            let guide = try XCTUnwrap(values.first { $0.kind == .cloud })
            XCTAssertEqual(guide.buttonTitle, language == .zhHans ? "去云盘清理" : "Open Cloud Cleanup")
            XCTAssertFalse(guide.detail.isEmpty)
        }
    }

    func testInjectedNavigationHandlesHealthRecommendationsAndGuidesWithoutSideEffects() throws {
        let store = try MyActivityD187Fixtures.readOnlyStore(for: self)
        let root = try TestFileSystem.makeHome(for: self)
        let cloud = CloudCleanupModel(home: root)
        var destinations: [ReviewFilter] = []
        let page = CareStudioMyActivityPage(store: store, healthStore: ComputerHealthStore(probe: TestUnavailableComputerHealthProbe(),
                batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController()),
            privacy: BrowserPrivacyStore(), cloud: cloud, summary: MyActivitySummary(), mac: MyActivityMacInfo(),
            now: { self.now }, onNavigate: { destinations.append($0) })
        let selection = store.navigationState.selectedFilter
        let healthCard = CareStudioActivityHealthCard(health: page.health, mac: MyActivityMacInfo()) { page.open(.healthHub) }
        healthCard.onOpen()
        var state = MyActivityRecommendations.State()
        // D195＋旧值：successful login-item coverage was implicit in this fixture.
        state.managedItemCoverageAvailable = true
        state.recoverableTrashBytes = 1
        state.availableUpdateCount = 1
        state.loginItemCount = 5
        state.recommendedMaintenanceCount = 1
        state.thirdPartyCloudFolderCount = 1
        let recommendations = MyActivityRecommendations.make(state, now: now)
        let allRoutes = recommendations.map(\.destination)
        for recommendation in recommendations {
            let card = CareStudioActivityRecommendationCard(recommendation: recommendation) { page.open(recommendation.destination) }
            card.onOpen()
        }
        XCTAssertEqual(destinations, [.healthHub] + allRoutes)
        let list = CareStudioActivityRecommendationsList(recommendations: recommendations, onOpen: page.open, onClose: {})
        list.onOpen(.cloudCleanup)
        XCTAssertEqual(destinations.last, .cloudCleanup)
        XCTAssertEqual(store.navigationState.selectedFilter, selection)
        XCTAssertNil(store.pendingEmptyTrash)
        XCTAssertFalse(store.isEmptyingTrash)
        XCTAssertFalse(store.isLoadingAppUpdates)
        XCTAssertFalse(ToolboxStores.of(store).maintenance.isRunning)
        XCTAssertEqual(cloud.phase, .idle)
    }

    func testProductionCallbackUsesExistingModuleNavigation() throws {
        let store = try MyActivityD187Fixtures.readOnlyStore(for: self)
        let root = try TestFileSystem.makeHome(for: self)
        let page = CareStudioMyActivityPage(store: store, cloud: CloudCleanupModel(home: root),
            summary: MyActivitySummary(), mac: MyActivityMacInfo())
        for route in [ReviewFilter.healthHub, .green, .privacy, .cloudCleanup, .startup, .updater, .overview] {
            page.open(route)
            if route == .startup || route == .updater {
                // D187: the existing navigation stores these as a utility
                // hub plus its tool; the initial new test expected the tool
                // directly in selectedFilter. Assert both parts explicitly.
                XCTAssertEqual(store.navigationState.selectedFilter, .utilityHub)
                XCTAssertEqual(store.navigationState.selectedUtilityFilter, route)
            } else {
                XCTAssertEqual(store.navigationState.selectedFilter, route)
            }
        }
    }

    func testPageReadsCurrentUpdatesAndRetainedTimeResults() throws {
        let store = try MyActivityD187Fixtures.readOnlyStore(for: self)
        let root = try TestFileSystem.makeHome(for: self)
        store.appUpdates = [MyActivityD187Fixtures.application()]
        var summary = MyActivitySummary()
        summary.recoverableTrashBytes = 1_000_000_000
        summary.timeSavingsRecords = [.init(id: "uninstall", category: .uninstall), .init(id: "update", category: .update)]
        let page = CareStudioMyActivityPage(store: store, cloud: CloudCleanupModel(home: root),
            summary: summary, mac: MyActivityMacInfo(), now: { self.now })
        XCTAssertEqual(page.savings.totalMinutes, 16)
        XCTAssertEqual(page.recommendationState.recoverableTrashBytes, 1_000_000_000)
        XCTAssertEqual(page.recommendationState.availableUpdateCount, 1)
        XCTAssertTrue(page.recommendations.contains { $0.kind == .updates && $0.destination == .updater })
    }

#if DEBUG
    // Integration: the health fixture hook exists only in Debug builds, so
    // the Release test target compiles this test out (it failed to compile).
    func testPageReusesExistingHealthEvidenceWithoutRefreshing() throws {
        let store = try MyActivityD187Fixtures.readOnlyStore(for: self)
        let root = try TestFileSystem.makeHome(for: self)
        let healthStore = ComputerHealthStore(probe: TestUnavailableComputerHealthProbe(),
                batteryPowerModeController: TestOperationFactory(for: self).batteryPowerModeController())
        let snapshot = ComputerHealthSecurityFixture.snapshot(smart: .failing)
        healthStore.installDebugPresentationFixture(snapshot: snapshot,
            evaluation: ComputerHealthScoring.evaluate(snapshot: snapshot, referenceDate: now))
        let page = CareStudioMyActivityPage(store: store, healthStore: healthStore, cloud: CloudCleanupModel(home: root),
            summary: MyActivitySummary(), mac: MyActivityMacInfo(), now: { self.now })
        XCTAssertEqual(page.health.grade, .problem)
        XCTAssertEqual(page.health.reasons, [.diskFailure])
        XCTAssertFalse(healthStore.isRefreshing)
    }
#endif
}
