import AppKit
import XCTest
@testable import StorageCleanerMac

final class MacMiniPortraitRegressionTests: XCTestCase {
    private let parent = CGRect(x: 450, y: 900, width: 288, height: 620)
    private let children = [CGSize(width: 272, height: 600), CGSize(width: 288, height: 600)]
    private let portrait = CGRect(x: 0, y: 0, width: 900, height: 1600)

    func testPrimaryReflowsBeforeTertiaryIsOpened() throws {
        let layout = try XCTUnwrap(CascadeViewportLayout.solve(parent: parent, children: children,
            visible: portrait, prefersLeft: true))
        XCTAssertEqual(layout.arrangement, .columns)
        XCTAssertNotEqual(layout.parent.minX, parent.minX)
        XCTAssertEqual(layout.children.count, 2)
        let reopened = CascadeViewportLayout.solve(parent: layout.parent, children: children,
            visible: portrait, prefersLeft: layout.expandsLeft)
        XCTAssertEqual(reopened, layout)
    }

    func testWideDetailsFoldVerticallyOnPortraitScreen() throws {
        let layout = try XCTUnwrap(CascadeViewportLayout.solve(parent: parent,
            children: [.init(width: 400, height: 600), .init(width: 400, height: 600)],
            visible: portrait, prefersLeft: true))
        XCTAssertEqual(layout.arrangement, .stackedDetails)
        XCTAssertEqual(layout.children.count, 2)
        XCTAssertTrue(layout.frames.allSatisfy(portrait.contains))
        XCTAssertLessThanOrEqual(layout.children[1].maxY, layout.children[0].minY)
    }

    func testCompactAdapterRetainsTwoRoutesOnNarrowNegativeCoordinateDisplay() {
        let visible = CGRect(x: -600, y: 25, width: 360, height: 580)
        let layout = MenuBarPanelPlacement.reflowingCascade(parentFrame: parent,
            childSizes: children, visibleFrame: visible)
        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.secondaryPresentationMode, .adjacent)
        XCTAssertEqual(layout.tertiaryPresentationMode, .column)
        XCTAssertEqual(layout.childFrames.count, 2)
        XCTAssertTrue(visible.contains(layout.containerFrame))
    }

    func testInvalidDisplayGeometryDoesNotProduceAPlan() {
        XCTAssertNil(CascadeViewportLayout.solve(parent: parent, children: children,
            visible: .zero, prefersLeft: true))
        XCTAssertNil(CascadeViewportLayout.solve(parent: parent,
            children: [.init(width: CGFloat.nan, height: 50)], visible: portrait, prefersLeft: true))
    }

    func testLayoutMovementIsNotAPointerExit() {
        var guardState = CascadeStationaryPointerGuard()
        guardState.begin(previous: [.init(x: 0, y: 0, width: 100, height: 100)],
            next: [.init(x: 200, y: 0, width: 100, height: 100)], pointer: .init(x: 50, y: 50))
        XCTAssertTrue(guardState.retains(.init(x: 50, y: 50)))
        XCTAssertFalse(guardState.retains(.init(x: 70, y: 50)))
        XCTAssertFalse(guardState.retains(.init(x: 50, y: 50)))
        guardState.reset()
        XCTAssertNil(guardState.origin)
    }

    func testStationaryGuardExpiresAndCannotBeRenewedByRecursiveLayouts() {
        var state = CascadeStationaryPointerGuard()
        let old = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        let next = [CGRect(x: 200, y: 0, width: 100, height: 100)]
        let pointer = CGPoint(x: 50, y: 50)
        state.begin(previous: old, next: next, pointer: pointer, now: 10)
        state.begin(previous: old, next: next, pointer: pointer, now: 10.4)
        XCTAssertTrue(state.retains(pointer, now: 10.44))
        XCTAssertFalse(state.retains(pointer, now: 10.46))
    }

    func testLiveDesktopEvidenceOverridesStaleBatterySamples() {
        XCTAssertEqual(MiniWindowBatteryPolicy.resolve(live: .absent, healthSaysAbsent: false,
            hasPowerSnapshot: true, hasElectricalBatteryData: true, hasHealthSnapshot: true), .absent)
    }

    func testUnknownDoesNotCreateABatteryOrDeclareDesktopHardware() {
        XCTAssertEqual(MiniWindowBatteryPolicy.resolve(live: .unknown, healthSaysAbsent: false,
            hasPowerSnapshot: false, hasElectricalBatteryData: false, hasHealthSnapshot: false), .unknown)
    }

    func testPortableCanShowBatteryBeforeHealthScanFinishes() {
        XCTAssertEqual(MiniWindowBatteryPolicy.resolve(live: .present, healthSaysAbsent: false,
            hasPowerSnapshot: false, hasElectricalBatteryData: false, hasHealthSnapshot: false), .present)
    }

    func testHistoryRemainsFallbackWhenLiveCapabilityIsUnknown() {
        XCTAssertEqual(MiniWindowBatteryPolicy.resolve(live: .unknown, healthSaysAbsent: true,
            hasPowerSnapshot: false, hasElectricalBatteryData: false, hasHealthSnapshot: false), .absent)
        XCTAssertEqual(MiniWindowBatteryPolicy.resolve(live: .unknown, healthSaysAbsent: false,
            hasPowerSnapshot: true, hasElectricalBatteryData: false, hasHealthSnapshot: false), .present)
    }
}
