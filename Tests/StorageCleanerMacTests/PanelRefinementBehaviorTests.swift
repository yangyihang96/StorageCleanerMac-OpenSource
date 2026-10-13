import Combine
import XCTest
@testable import StorageCleanerMac

@MainActor
final class PanelRefinementBehaviorTests: XCTestCase {
    func testSiblingCardsHaveDistinctStableOwnershipAndTraceKeys() {
        let first = MenuBarCardIdentity.key(page: "processor", domain: .cpu, file: "processor", line: 16, column: 1)
        let second = MenuBarCardIdentity.key(page: "processor", domain: .cpu, file: "processor", line: 17, column: 1)
        XCTAssertNotEqual(first, second, "CPU usage and uptime cannot share ownership or consume each other's draw receipt")
        XCTAssertEqual(first, MenuBarCardIdentity.key(page: "processor", domain: .cpu, file: "processor", line: 16, column: 1))
        XCTAssertNotEqual(first, MenuBarCardIdentity.key(page: "memory", domain: .cpu, file: "processor", line: 16, column: 1))
        XCTAssertNotEqual(first, MenuBarCardIdentity.key(page: "processor", domain: .memory, file: "processor", line: 16, column: 1))
    }

    func testHiddenCardDoesNotReadOrPublishAndReappearingUsesLatestInput() async {
        let source = PassthroughSubject<Void, Never>()
        var value = 0.0, reads = 0
        let model = MenuBarCardModel(sources: [source.eraseToAnyPublisher()]) {
            reads += 1
            return MenuBarCardFingerprint(values: [value])
        }
        model.setVisible(false)
        value = 42
        for _ in 0..<100 { source.send() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(reads, 1, "Hidden pages must not prepare their cards")
        XCTAssertEqual(model.revision.version, 0)
        model.setVisible(true)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.revision.version, 1, "Reopening reconciles the latest real input once")
    }
    func testRangeInteractionBlocksOnlyAutomaticDismissalAndStaleRelease() throws {
        let coordinator = GeekPanelCoordinator(initialSection: .processor)
        XCTAssertTrue(coordinator.presentHistory(.builtIn("cpu"), pinned: false))
        let first = try XCTUnwrap(coordinator.beginHistoryInteraction())
        coordinator.dismissUnpinnedHierarchy()
        XCTAssertEqual(coordinator.route, .history(module: .processor, selection: .builtIn("cpu")))
        let second = try XCTUnwrap(coordinator.beginHistoryInteraction())
        coordinator.endHistoryInteraction(first)
        XCTAssertTrue(coordinator.isInteractingWithHistory)
        coordinator.endHistoryInteraction(second)
        XCTAssertFalse(coordinator.isInteractingWithHistory)
        _ = coordinator.beginHistoryInteraction()
        XCTAssertTrue(coordinator.handleEscape())
        XCTAssertEqual(coordinator.route, .module(.processor))
        XCTAssertFalse(coordinator.isInteractingWithHistory)
        coordinator.reset()
        XCTAssertNil(coordinator.historyInteractionToken)
    }
    func testRingNumericUnitsAndUnknownRemainDistinct() {
        for (value, number, unit) in [("100%", "100", "%"), ("12000 rpm", "12000", "rpm"),
                                      ("3.25 GHz", "3.25", "GHz"), ("51°C", "51", "°C"),
                                      ("−4 W", "−4", "W")] {
            let parsed = GeekCombinedRing.splitReadout(value)
            XCTAssertEqual(parsed?.number, number); XCTAssertEqual(parsed?.unit, unit)
        }
        XCTAssertNil(GeekCombinedRing.splitReadout("—"))
        XCTAssertNil(GeekCombinedRing.splitReadout("OFF"))
    }
    func testMetricSourceNeverTurnsUnknownSamplingIntoSystemData() {
        XCTAssertEqual(EnergyMetricSource.from(measured: 2, total: 2), .systemData)
        XCTAssertEqual(EnergyMetricSource.from(measured: 1, total: 2), .mixed)
        XCTAssertEqual(EnergyMetricSource.from(measured: 0, total: 2), .estimated)
        XCTAssertEqual(EnergyMetricSource.from(measured: 0, total: 0), .unknown)
        let evidence = EnergyMetricEvidence(source: .unknown, sampledAt: nil, intervalSeconds: nil)
        XCTAssertFalse(evidence.detail.contains("实测"))
    }
}
