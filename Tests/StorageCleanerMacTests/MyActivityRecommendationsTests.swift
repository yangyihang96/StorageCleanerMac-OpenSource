import XCTest
@testable import StorageCleanerMac

final class MyActivityRecommendationsTests: XCTestCase {
    private let now = MyActivityD187Fixtures.now
    private func make(_ state: MyActivityRecommendations.State) -> [MyActivityRecommendation] {
        MyActivityRecommendations.make(state, now: now)
    }

    func testNoAdviceWhenAllAvailableStateIsCurrent() {
        XCTAssertTrue(make(MyActivityD187Fixtures.noRecommendations()).isEmpty)
    }

    func testSmartScanMissingSevenDayBoundaryAndClockChange() {
        var state = MyActivityD187Fixtures.noRecommendations()
        let cases: [(Date?, Bool)] = [(nil, true), (now.addingTimeInterval(-7 * 86_400), false),
                                     (now.addingTimeInterval(-7 * 86_400 - 1), true), (now.addingTimeInterval(1), true)]
        for (date, expected) in cases {
            state.latestSmartScanAt = date
            XCTAssertEqual(make(state).contains { $0.kind == .smartScan }, expected)
        }
    }

    func testRecoverableTrashRequiresPositiveEvidence() {
        var state = MyActivityD187Fixtures.noRecommendations()
        for bytes in [Int64(-1), 0, 1_000_000_000] {
            state.recoverableTrashBytes = bytes
            let items = make(state)
            XCTAssertEqual(items.count, bytes > 0 ? 1 : 0)
            if bytes > 0 { XCTAssertEqual(items.first?.destination, .green) }
        }
    }

    func testUpdatesRequireAPositiveCurrentListCount() {
        var state = MyActivityD187Fixtures.noRecommendations()
        state.availableUpdateCount = 2
        XCTAssertEqual(make(state).map(\.kind), [.updates])
        XCTAssertEqual(make(state).first?.destination, .updater)
        state.availableUpdateCount = 0
        XCTAssertTrue(make(state).isEmpty)
    }

    func testLoginItemsTriggerAtFive() {
        var state = MyActivityD187Fixtures.noRecommendations()
        for count in [0, 4, 5, 6] {
            state.loginItemCount = count
            XCTAssertEqual(make(state).map(\.kind), count >= 5 ? [.loginItems] : [])
        }
    }

    func testMaintenanceAndLoginAdviceRemainDistinctAtTheSameDestination() {
        var state = MyActivityD187Fixtures.noRecommendations()
        state.recommendedMaintenanceCount = 1
        XCTAssertEqual(make(state).map(\.kind), [.maintenance])
        state.loginItemCount = 5
        XCTAssertEqual(make(state).map(\.kind), [.loginItems, .maintenance])
        XCTAssertEqual(make(state).map(\.destination), [.startup, .startup])
        state.recommendedMaintenanceCount = 0
        state.loginItemCount = 0
        XCTAssertTrue(make(state).isEmpty)
    }

    func testUnmeasuredAndNonGoodHealthBothOfferACheck() {
        var state = MyActivityD187Fixtures.noRecommendations()
        for grade in [nil, MyActivityHealth.Grade.attention, .problem] {
            state.health = MyActivityHealth(grade: grade, reasons: [], checkedAt: now)
            XCTAssertEqual(make(state).map(\.kind), [.health])
            XCTAssertEqual(make(state).first?.destination, .healthHub)
        }
    }

    func testProtectionGuideRequiresNoExistingResult() {
        var state = MyActivityD187Fixtures.noRecommendations()
        state.hasProtectionScan = false
        XCTAssertEqual(make(state).map(\.kind), [.protection])
        XCTAssertEqual(make(state).first?.destination, .privacy)
        XCTAssertEqual(make(state).first?.isGuide, true)
        state.hasProtectionScan = true
        XCTAssertTrue(make(state).isEmpty)
    }

    func testCloudThresholdAndFolderDiscovery() {
        var state = MyActivityD187Fixtures.noRecommendations()
        state.hasCloudStatistics = true
        state.iCloudLocalBytes = MyActivityRecommendations.largeCloudBytes - 1
        XCTAssertTrue(make(state).isEmpty)
        state.iCloudLocalBytes += 1
        XCTAssertEqual(make(state).map(\.kind), [.cloud])
        state.iCloudLocalBytes = 0
        state.thirdPartyCloudFolderCount = 1
        XCTAssertEqual(make(state).first?.destination, .cloudCleanup)
        state.thirdPartyCloudFolderCount = 0
        XCTAssertTrue(make(state).isEmpty)
    }

    func testICloudGuideOnlyAppearsBeforeStatisticsExist() {
        var state = MyActivityD187Fixtures.noRecommendations()
        state.iCloudAvailable = true
        XCTAssertEqual(make(state).map(\.kind), [.cloud])
        state.hasCloudStatistics = true
        XCTAssertTrue(make(state).isEmpty)
    }

    func testPriorityOrderingLimitsAndDeduplication() {
        var state = MyActivityRecommendations.State()
        // D195＋旧值：this fixture's successful login read was previously implicit.
        state.managedItemCoverageAvailable = true
        state.health = MyActivityHealth(grade: .problem, reasons: [.diskFailure], checkedAt: now)
        state.recoverableTrashBytes = 1_000
        state.availableUpdateCount = 1
        state.loginItemCount = 5
        state.recommendedMaintenanceCount = 1
        state.thirdPartyCloudFolderCount = 6
        state.iCloudLocalBytes = 5_000_000_000
        let items = make(state)
        XCTAssertEqual(items.map(\.kind), [.health, .trash, .updates, .smartScan, .loginItems, .maintenance, .protection, .cloud])
        XCTAssertEqual(Set(items.map(\.id)).count, 8)
        XCTAssertEqual(MyActivityRecommendations.make(state, now: now, limit: 3).map(\.kind), [.health, .trash, .updates])
        XCTAssertTrue(MyActivityRecommendations.make(state, now: now, limit: 0).isEmpty)
        XCTAssertTrue(MyActivityRecommendations.make(state, now: now, limit: -1).isEmpty)
        XCTAssertEqual(MyActivityRecommendations.make(state, now: now, limit: Int.max).count, 8)
        state.health = MyActivityHealth(grade: .attention, reasons: [.lowSpace], checkedAt: now)
        XCTAssertEqual(make(state).map(\.kind), [.trash, .updates, .smartScan, .loginItems, .maintenance, .health, .protection, .cloud])
    }
}
