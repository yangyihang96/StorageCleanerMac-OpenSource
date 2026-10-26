import AppKit
import XCTest
@testable import StorageCleanerMac

@MainActor
final class HoverIntentControllerTests: XCTestCase {
    private let first = SmallWindowAnchorID(rawValue: "test.first")
    private let second = SmallWindowAnchorID(rawValue: "test.second")
    private let third = SmallWindowAnchorID(rawValue: "test.third")

    func testFastSweepDoesNotOpen() async {
        let controller = HoverIntentController()
        var opened = false
        let request = controller.scheduleOpen(
            anchorID: first,
            panelRole: .secondary,
            delay: .milliseconds(30)
        ) { opened = true }

        try? await Task.sleep(for: .milliseconds(5))
        controller.cancel(request)
        try? await Task.sleep(for: .milliseconds(35))

        XCTAssertFalse(opened)
        XCTAssertEqual(controller.state, .closed)
    }

    func testDwellOpensAfterDelay() async {
        let controller = HoverIntentController()
        var opened = false
        controller.scheduleOpen(
            anchorID: first,
            panelRole: .secondary,
            delay: .milliseconds(5)
        ) { opened = true }

        try? await Task.sleep(for: .milliseconds(15))

        XCTAssertTrue(opened)
        XCTAssertEqual(controller.state, .open(anchorID: first, panelRole: .secondary))
    }

    func testImmediateOpenRemainsCancellableBeforeTheNextMainActorTurn() async {
        let controller = HoverIntentController()
        var opened = false
        let request = controller.scheduleOpen(anchorID: first, panelRole: .secondary) {
            opened = true
        }
        XCTAssertFalse(opened, "A reveal must not reenter the SwiftUI hover callback.")
        controller.cancel(request)

        try? await Task.sleep(for: .milliseconds(15))

        XCTAssertFalse(opened)
        XCTAssertEqual(controller.state, .closed)
    }

    func testImmediateOpenChecksTheLatestHoverCondition() async {
        let controller = HoverIntentController()
        let hovering = R2TestValue(true)
        var opened = false
        controller.scheduleOpen(
            anchorID: first,
            panelRole: .secondary,
            condition: { hovering.value }
        ) { opened = true }
        hovering.value = false

        try? await Task.sleep(for: .milliseconds(15))

        XCTAssertFalse(opened)
        XCTAssertEqual(controller.state, .closed)
    }

    func testStraightMovementCrossesAnchorToPanelCorridor() {
        let source = NSRect(x: 0, y: 100, width: 40, height: 40)
        let panel = NSRect(x: 60, y: 80, width: 120, height: 80)
        let corridor = HoverCorridor(source: source, destination: panel, padding: 8)

        XCTAssertTrue(corridor.contains(NSPoint(x: 50, y: 120)))
    }

    func testDiagonalMovementCrossesSafeCorridor() {
        let source = NSRect(x: 100, y: 300, width: 30, height: 30)
        let panel = NSRect(x: 200, y: 150, width: 100, height: 100)
        let corridor = HoverCorridor(source: source, destination: panel, padding: 8)

        XCTAssertTrue(corridor.contains(NSPoint(x: 165, y: 245)))
        XCTAssertFalse(corridor.contains(NSPoint(x: 165, y: 360)))
    }

    func testBriefLeaveThenPanelEntryCancelsClose() async {
        let policy = HoverIntentPolicy(
            ordinaryCloseDelay: .milliseconds(20),
            corridorGraceDuration: .milliseconds(40)
        )
        let controller = HoverIntentController(policy: policy)
        let source = NSRect(x: 0, y: 100, width: 40, height: 40)
        let panel = NSRect(x: 60, y: 80, width: 120, height: 80)
        controller.markOpen(anchorID: first, panelRole: .secondary)
        controller.updateWindowGroupFrames([source, panel])
        controller.recordPointer(NSPoint(x: 50, y: 120), at: 1)
        var closed = false
        let close = controller.scheduleClose { closed = true }

        try? await Task.sleep(for: .milliseconds(5))
        controller.recordPointer(NSPoint(x: 70, y: 120), at: 1.01)
        controller.cancel(close)
        try? await Task.sleep(for: .milliseconds(45))

        XCTAssertFalse(closed)
        XCTAssertEqual(controller.state, .open(anchorID: first, panelRole: .secondary))
    }

    func testReverseMovementUsesShortCloseDelay() {
        let policy = HoverIntentPolicy(
            ordinaryCloseDelay: .milliseconds(30),
            reverseDirectionCloseDelay: .milliseconds(7)
        )
        let controller = HoverIntentController(policy: policy)
        let destination = NSRect(x: 100, y: 100, width: 80, height: 80)
        controller.updateWindowGroupFrames([destination])
        controller.recordPointer(NSPoint(x: 80, y: 140), at: 1)
        controller.recordPointer(NSPoint(x: 45, y: 140), at: 1.1)

        XCTAssertEqual(controller.pointerDirection(toward: destination), .away)
        XCTAssertEqual(controller.recommendedCloseDelay(), .milliseconds(7))
    }

    func testRapidMovementAcrossTwoAnchorsOnlyOpensLatest() async {
        let controller = HoverIntentController()
        var opened: [SmallWindowAnchorID] = []
        controller.scheduleOpen(
            anchorID: first,
            panelRole: .secondary,
            delay: .milliseconds(30)
        ) { opened.append(self.first) }
        try? await Task.sleep(for: .milliseconds(5))
        controller.scheduleOpen(
            anchorID: second,
            panelRole: .secondary,
            delay: .milliseconds(5)
        ) { opened.append(self.second) }

        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(opened, [second])
    }

    func testDiagonalTransitTowardOpenChildDoesNotSwitchOverviewModule() async {
        let policy = HoverIntentPolicy(
            initialOpenDelay: .milliseconds(5),
            switchDelay: .milliseconds(5),
            corridorGraceDuration: .milliseconds(40)
        )
        let controller = HoverIntentController(policy: policy)
        let overview = NSRect(x: 100, y: 100, width: 100, height: 300)
        let detail = NSRect(x: 0, y: 100, width: 96, height: 300)
        controller.markOpen(anchorID: first, panelRole: .secondary)
        controller.updateWindowGroupFrames([overview, detail])
        controller.recordPointer(NSPoint(x: 160, y: 180), at: 1)
        controller.recordPointer(NSPoint(x: 120, y: 220), at: 1.1)

        var opened = false
        let request = controller.scheduleOpen(
            anchorID: second,
            panelRole: .secondary
        ) { opened = true }

        try? await Task.sleep(for: .milliseconds(12))
        XCTAssertFalse(opened)
        controller.cancel(request)
        try? await Task.sleep(for: .milliseconds(45))
        XCTAssertFalse(opened)
        XCTAssertEqual(controller.state, .open(anchorID: first, panelRole: .secondary))
    }

    func testVerticalTransitBetweenOverviewRowsDoesNotWaitForChildCorridor() async {
        let controller = HoverIntentController(policy: HoverIntentPolicy(
            switchDelay: .milliseconds(5),
            corridorGraceDuration: .seconds(1)
        ))
        controller.markOpen(anchorID: first, panelRole: .secondary)
        controller.updateWindowGroupFrames([
            NSRect(x: 100, y: 100, width: 100, height: 300),
            NSRect(x: 0, y: 100, width: 96, height: 300)
        ])
        controller.recordPointer(NSPoint(x: 160, y: 380), at: 1)
        controller.recordPointer(NSPoint(x: 160, y: 300), at: 1.1)
        var opened = false
        let request = controller.scheduleOpen(anchorID: second, panelRole: .secondary) {
            opened = true
        }
        defer { controller.cancel(request) }

        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(opened, "Moving vertically between rows must not wait for the adjacent child.")
    }

    // D123 (2026-10-19): iStat Menus 7.30 holds for any step toward the open
    // child's side, whether or not its line would reach the child. Renamed
    // from testDiagonalMovementMissingOpenChildDoesNotWaitForCorridor, which
    // asserted that the D117 trajectory test let such a drift switch at once.
    func testSidewaysDriftTowardTheChildSideHoldsEvenWhenItMissesTheChild() async {
        let controller = HoverIntentController(policy: HoverIntentPolicy(
            switchDelay: .milliseconds(5),
            corridorGraceDuration: .seconds(1)
        ))
        controller.markOpen(anchorID: first, panelRole: .secondary)
        controller.updateWindowGroupFrames([
            NSRect(x: 100, y: 100, width: 100, height: 300),
            NSRect(x: 0, y: 100, width: 96, height: 70)
        ])
        controller.recordPointer(NSPoint(x: 160, y: 370), at: 1)
        controller.recordPointer(NSPoint(x: 152, y: 310), at: 1.1)
        var opened = false
        let request = controller.scheduleOpen(anchorID: second, panelRole: .secondary) {
            opened = true
        }
        defer { controller.cancel(request) }

        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertFalse(opened, "A step toward the child's side holds the switch.")
        XCTAssertEqual(controller.state, .pendingSwitch(from: first, to: second))
        XCTAssertTrue(controller.isHoldingForOpenChild)

        controller.recordPointer(NSPoint(x: 153, y: 300), at: 1.2)
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(opened, "A step back switches at once.")
    }

    func testDiagonalTransitTowardRightHandChildKeepsProtection() async {
        let controller = HoverIntentController(policy: HoverIntentPolicy(
            switchDelay: .milliseconds(5),
            corridorGraceDuration: .milliseconds(100)
        ))
        controller.markOpen(anchorID: first, panelRole: .secondary)
        controller.updateWindowGroupFrames([
            NSRect(x: 100, y: 100, width: 100, height: 300),
            NSRect(x: 204, y: 100, width: 96, height: 300)
        ])
        controller.recordPointer(NSPoint(x: 140, y: 180), at: 1)
        controller.recordPointer(NSPoint(x: 180, y: 220), at: 1.1)
        var opened = false
        let request = controller.scheduleOpen(anchorID: second, panelRole: .secondary) {
            opened = true
        }
        defer { controller.cancel(request) }

        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(opened)
        XCTAssertEqual(controller.state, .pendingSwitch(from: first, to: second))
    }

    // D117: iStat Menus 7.30 keeps an open submenu while the pointer heads for
    // it and lets go as soon as the pointer turns back. D123 (2026-10-19):
    // with no time limit (was up to 1 s).

    func testSwitchKeepsWaitingWhileThePointerAdvancesTowardTheOpenChild() async {
        let controller = diagonalController(HoverIntentPolicy(
            switchDelay: .milliseconds(5),
            corridorGraceDuration: .milliseconds(40)
        ))
        var opened = false
        let request = controller.scheduleOpen(anchorID: second, panelRole: .secondary) { opened = true }
        defer { controller.cancel(request) }

        // 2 pt toward the child every 10 ms, well past the 40 ms grace, which
        // no longer bounds the hold (D123).
        for step in 1...25 {
            try? await Task.sleep(for: .milliseconds(10))
            recordDiagonalStep(step, on: controller)
        }
        XCTAssertFalse(opened, "Still advancing toward the open child: the switch keeps waiting")
        XCTAssertEqual(controller.state, .pendingSwitch(from: first, to: second))

        // D123 (2026-10-19): stopping keeps the hold, as in iStat Menus 7.30,
        // and the first step that does not head for the child ends it, here a
        // vertical one (was: stopping ended the wait at the next 50 ms check,
        // and a 3 s cap at the latest).
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(opened, "A stopped pointer keeps the hold")
        XCTAssertTrue(controller.isHoldingForOpenChild)
        controller.recordPointer(NSPoint(x: 136, y: 240), at: 1.6)
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(opened, "A vertical step ends the hold")
        XCTAssertFalse(controller.isHoldingForOpenChild)
    }

    // D123 (2026-10-19): renamed from
    // testSwitchStopsWaitingAtTheMaximumHoldEvenWhileAdvancing, which asserted
    // that a 120 ms cap opened the switch while the pointer kept advancing.
    // iStat Menus 7.30's 1 s check holds again at once while the pointer still
    // heads for the child, so the hold outlasts 1 s.
    func testSwitchKeepsHoldingPastOneSecondWhileThePointerAdvances() async {
        let controller = diagonalController(HoverIntentPolicy(
            switchDelay: .milliseconds(5),
            corridorGraceDuration: .milliseconds(20)
        ))
        var opened = false
        let request = controller.scheduleOpen(anchorID: second, panelRole: .secondary) { opened = true }
        defer { controller.cancel(request) }

        // 1 pt toward the child every 20 ms for more than 1 s, staying in the
        // overview.
        let start = ContinuousClock.now
        var step = 0
        while ContinuousClock.now - start < .milliseconds(1_100) {
            try? await Task.sleep(for: .milliseconds(20))
            step += 1
            controller.recordPointer(
                NSPoint(x: 186 - CGFloat(step), y: 184 + CGFloat(step)),
                at: 1.02 + Double(step) * 0.02
            )
        }
        XCTAssertFalse(opened, "The hold has no time limit while the pointer advances")
        XCTAssertTrue(controller.isHoldingForOpenChild)
        XCTAssertEqual(controller.state, .pendingSwitch(from: first, to: second))
    }

    func testTurningBackFromTheOpenChildSwitchesWithoutWaitingOutTheGrace() async {
        // D123 (2026-10-19): no grace or cap remains to beat; the turn back
        // itself ends the hold (was a 2 s grace with a 20 ms progress check).
        let controller = diagonalController(HoverIntentPolicy(
            switchDelay: .milliseconds(5)
        ))
        var opened = false
        let request = controller.scheduleOpen(anchorID: second, panelRole: .secondary) { opened = true }
        defer { controller.cancel(request) }

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(opened)
        controller.recordPointer(NSPoint(x: 192, y: 190), at: 1.2)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(opened, "Turning back is a row switch, not a crossing toward the child")
    }

    func testModuleColumnTowardTheOpenHistoryColumnKeepsProtection() async {
        let controller = HoverIntentController(policy: HoverIntentPolicy(
            switchDelay: .milliseconds(5),
            corridorGraceDuration: .milliseconds(100)
        ))
        controller.markOpen(anchorID: third, panelRole: .tertiary)
        controller.updateWindowGroupFrames([
            NSRect(x: 300, y: 100, width: 100, height: 300),
            NSRect(x: 200, y: 100, width: 96, height: 300),
            NSRect(x: 100, y: 100, width: 96, height: 300)
        ])
        controller.recordPointer(NSPoint(x: 260, y: 180), at: 1)
        controller.recordPointer(NSPoint(x: 220, y: 220), at: 1.1)
        var opened = false
        let request = controller.scheduleOpen(anchorID: second, panelRole: .tertiary) { opened = true }
        defer { controller.cancel(request) }

        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(opened, "Crossing a module row toward the open history column is not a row switch")
        XCTAssertEqual(controller.state, .pendingSwitch(from: third, to: second))
    }

    func testLeavingTheCardDuringTheHoldNeverSwitches() async {
        // D123 (2026-10-19): the hold has no cap to set (was 3 s).
        let controller = diagonalController(HoverIntentPolicy(
            switchDelay: .milliseconds(5),
            corridorGraceDuration: .milliseconds(40)
        ))
        var opened = false
        let request = controller.scheduleOpen(anchorID: second, panelRole: .secondary) { opened = true }

        // Past the grace and still advancing: the switch is being held.
        for step in 1...10 {
            try? await Task.sleep(for: .milliseconds(10))
            recordDiagonalStep(step, on: controller)
        }
        XCTAssertFalse(opened)
        XCTAssertEqual(controller.state, .pendingSwitch(from: first, to: second))

        // Hover end on the card cancels its request (MenuBarPanelSession.invalidateHoverIntent).
        controller.cancel(request)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(opened, "A switch abandoned during the hold never opens")
        XCTAssertEqual(controller.state, .open(anchorID: first, panelRole: .secondary))
    }

    // D123 (2026-10-19): a close is a change of target too. iStat Menus 7.30
    // holds it while the pointer heads for the open child and otherwise
    // closes at once; an explicit delay (the control palettes) is not held.

    func testCloseIsHeldWhileThePointerHeadsForTheOpenChild() async {
        let controller = diagonalController(HoverIntentPolicy())
        var closed = false
        let request = controller.scheduleClose { closed = true }
        defer { controller.cancel(request) }

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(closed)
        XCTAssertEqual(controller.state, .pendingClose)
        XCTAssertTrue(controller.isHoldingForOpenChild)

        controller.recordPointer(NSPoint(x: 190, y: 186), at: 1.05)
        XCTAssertFalse(closed, "A release must not reenter pointer handling")
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(closed, "A step back closes at once")
        XCTAssertEqual(controller.state, .closed)
    }

    func testCloseRunsOnTheNextTurnUnlessThePointerHeadsForTheChild() async {
        let controller = HoverIntentController()
        controller.markOpen(anchorID: first, panelRole: .secondary)
        controller.updateWindowGroupFrames([
            NSRect(x: 100, y: 100, width: 100, height: 300),
            NSRect(x: 0, y: 100, width: 96, height: 300)
        ])
        // Straight down the overview: no step toward the child's side.
        controller.recordPointer(NSPoint(x: 160, y: 380), at: 1)
        controller.recordPointer(NSPoint(x: 160, y: 300), at: 1.1)
        var closed = false
        controller.scheduleClose { closed = true }
        XCTAssertFalse(closed, "A close must not reenter the hover callback")
        XCTAssertFalse(controller.isHoldingForOpenChild)

        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(closed)
        XCTAssertEqual(controller.state, .closed)
    }

    func testStepsAwayFromOrShortOfTheChildSideDoNotHold() async {
        for (from, to) in [
            // Rightward while the child is on the left.
            (NSPoint(x: 150, y: 200), NSPoint(x: 151, y: 230)),
            // Less than one point toward it.
            (NSPoint(x: 150, y: 200), NSPoint(x: 149.5, y: 230)),
        ] {
            let controller = HoverIntentController()
            controller.markOpen(anchorID: first, panelRole: .secondary)
            controller.updateWindowGroupFrames([
                NSRect(x: 100, y: 100, width: 100, height: 300),
                NSRect(x: 0, y: 100, width: 96, height: 300)
            ])
            controller.recordPointer(from, at: 1)
            controller.recordPointer(to, at: 1.1)
            var opened = false
            controller.scheduleOpen(anchorID: second, panelRole: .secondary) { opened = true }
            XCTAssertFalse(controller.isHoldingForOpenChild, "\(from) → \(to)")

            try? await Task.sleep(for: .milliseconds(15))
            XCTAssertTrue(opened, "\(from) → \(to)")
        }
    }

    func testExplicitDelayIsNotHeldForTheOpenChild() async {
        let controller = diagonalController(HoverIntentPolicy())
        var closed = false
        controller.scheduleClose(delay: .milliseconds(20)) { closed = true }
        XCTAssertFalse(controller.isHoldingForOpenChild)

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(closed, "The control palettes keep their own close timing")
    }

    func testOnlyAMenuWithASideChildHolds() async {
        // A child stacked under its menu has no side to head for.
        let stacked = HoverIntentController()
        stacked.markOpen(anchorID: first, panelRole: .secondary)
        stacked.updateWindowGroupFrames([
            NSRect(x: 100, y: 300, width: 100, height: 100),
            NSRect(x: 100, y: 100, width: 100, height: 196)
        ])
        stacked.recordPointer(NSPoint(x: 120, y: 350), at: 1)
        stacked.recordPointer(NSPoint(x: 160, y: 340), at: 1.1)
        var opened = false
        stacked.scheduleOpen(anchorID: second, panelRole: .secondary) { opened = true }
        XCTAssertFalse(stacked.isHoldingForOpenChild)

        // The deepest menu has no open child.
        let deepest = diagonalController(HoverIntentPolicy())
        deepest.recordPointer(NSPoint(x: 60, y: 200), at: 1.05)
        deepest.recordPointer(NSPoint(x: 50, y: 205), at: 1.06)
        var closed = false
        deepest.scheduleClose { closed = true }
        XCTAssertFalse(deepest.isHoldingForOpenChild)

        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(opened)
        XCTAssertTrue(closed)
    }

    func testOnlyAStepThatKeepsHeadingForTheChildKeepsTheHold() async {
        for (point, keeps) in [
            (NSPoint(x: 184, y: 186), true), // 2 pt toward the child
            (NSPoint(x: 185, y: 186), true), // exactly 1 pt
            (NSPoint(x: 186, y: 190), false), // vertical
            (NSPoint(x: 185.5, y: 190), false), // short of 1 pt
            (NSPoint(x: 188, y: 186), false), // back
        ] {
            let controller = diagonalController(HoverIntentPolicy())
            var closed = false
            let request = controller.scheduleClose { closed = true }
            defer { controller.cancel(request) }
            XCTAssertTrue(controller.isHoldingForOpenChild, "\(point)")

            controller.recordPointer(point, at: 1.04)
            try? await Task.sleep(for: .milliseconds(15))
            XCTAssertEqual(controller.isHoldingForOpenChild, keeps, "\(point)")
            XCTAssertEqual(closed, !keeps, "\(point)")
        }
    }

    func testAReadingAtTheSamePlaceIsNotAPointerStep() async {
        let controller = diagonalController(HoverIntentPolicy())
        // A refresh after a layout change reads the pointer where it was: it
        // neither erases the step a later change is held for ...
        controller.recordPointer(NSPoint(x: 186, y: 184), at: 1.5)
        var closed = false
        let request = controller.scheduleClose { closed = true }
        defer { controller.cancel(request) }
        XCTAssertTrue(controller.isHoldingForOpenChild)

        // ... nor ends a hold.
        controller.recordPointer(NSPoint(x: 186, y: 184), at: 1.6)
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertFalse(closed)
        XCTAssertTrue(controller.isHoldingForOpenChild)
    }

    func testAStepAfterAPauseIsMeasuredFromTheLastReading() async {
        // iStat Menus 7.30 compares each event with the previous one however
        // long ago it came, while the sample history keeps only 160 ms.
        let controller = diagonalController(HoverIntentPolicy())
        controller.recordPointer(NSPoint(x: 184, y: 186), at: 2)
        var opened = false
        let request = controller.scheduleOpen(anchorID: second, panelRole: .secondary) { opened = true }
        defer { controller.cancel(request) }
        XCTAssertTrue(controller.isHoldingForOpenChild)

        controller.recordPointer(NSPoint(x: 184, y: 190), at: 3)
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(opened, "A vertical step after a pause ends the hold")
    }

    func testAPresentedPaletteIsNotAChildMenu() async {
        let controller = HoverIntentController()
        controller.markOpen(anchorID: first, panelRole: .secondary)
        let detail = NSRect(x: 0, y: 100, width: 96, height: 300)
        let palette = NSRect(x: -150, y: 200, width: 140, height: 80)
        controller.updateWindowGroupFrames([NSRect(x: 100, y: 100, width: 100, height: 300), detail], palette: palette)
        XCTAssertEqual(controller.menuFrames.count, 2)

        // Heading from the deepest menu toward the palette's side holds nothing.
        controller.recordPointer(NSPoint(x: 40, y: 240), at: 1)
        controller.recordPointer(NSPoint(x: 36, y: 240), at: 1.02)
        var closed = false
        controller.scheduleClose { closed = true }
        XCTAssertFalse(controller.isHoldingForOpenChild)
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(closed)

        // The palette still extends the control palettes' close corridor.
        controller.recordPointer(NSPoint(x: -5, y: 240), at: 1.04)
        XCTAssertEqual(
            controller.recommendedCloseDelay(ordinaryDelay: .milliseconds(260)),
            HoverIntentPolicy.menuBar.corridorGraceDuration
        )
    }

    /// An open module column on the left of the overview, with the pointer
    /// in the overview heading down-left into it.
    private func diagonalController(_ policy: HoverIntentPolicy) -> HoverIntentController {
        let controller = HoverIntentController(policy: policy)
        controller.markOpen(anchorID: first, panelRole: .secondary)
        controller.updateWindowGroupFrames([
            NSRect(x: 100, y: 100, width: 100, height: 300),
            NSRect(x: 0, y: 100, width: 96, height: 300)
        ])
        controller.recordPointer(NSPoint(x: 190, y: 180), at: 1)
        controller.recordPointer(NSPoint(x: 186, y: 184), at: 1.02)
        return controller
    }

    private func recordDiagonalStep(_ step: Int, on controller: HoverIntentController) {
        controller.recordPointer(
            NSPoint(x: 186 - CGFloat(step) * 2, y: 184 + CGFloat(step) * 2),
            at: 1.02 + Double(step) * 0.01
        )
    }

    func testOldCloseCannotCloseNewPanel() async {
        let controller = HoverIntentController()
        controller.markOpen(anchorID: first, panelRole: .secondary)
        var closed = false
        controller.scheduleClose(delay: .milliseconds(30)) { closed = true }
        try? await Task.sleep(for: .milliseconds(5))
        controller.markOpen(anchorID: second, panelRole: .secondary)

        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertFalse(closed)
        XCTAssertEqual(controller.state, .open(anchorID: second, panelRole: .secondary))
    }

    func testOwnerScopedCloseCannotCloseNewerSurface() {
        let controller = HoverIntentController()
        controller.markOpen(anchorID: .powerMode, panelRole: .controlPalette)
        controller.markOpen(anchorID: third, panelRole: .tertiary)

        controller.markClosed(
            ifOwnedBy: .powerMode,
            panelRole: .controlPalette
        )

        XCTAssertEqual(
            controller.state,
            .open(anchorID: third, panelRole: .tertiary)
        )
    }

    func testOldSwitchCannotReplaceLatestAnchor() async {
        let controller = HoverIntentController()
        controller.markOpen(anchorID: first, panelRole: .secondary)
        var opened: [SmallWindowAnchorID] = []
        controller.scheduleOpen(
            anchorID: second,
            panelRole: .secondary,
            delay: .milliseconds(30)
        ) { opened.append(self.second) }
        try? await Task.sleep(for: .milliseconds(5))
        controller.scheduleOpen(
            anchorID: third,
            panelRole: .tertiary,
            delay: .milliseconds(5)
        ) { opened.append(self.third) }

        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(opened, [third])
        XCTAssertEqual(controller.state, .open(anchorID: third, panelRole: .tertiary))
    }

    func testEscapeClosesDeepestRouteFirst() {
        let coordinator = GeekPanelCoordinator()
        coordinator.selectModule(.network)
        coordinator.presentHistory(.builtIn("network"), pinned: true)

        XCTAssertTrue(coordinator.handleEscape())
        XCTAssertEqual(coordinator.route, .module(.network))
        XCTAssertTrue(coordinator.handleEscape())
        XCTAssertEqual(coordinator.route, .summary)
        XCTAssertFalse(coordinator.handleEscape())
    }

    func testHoverDismissalCollapsesTheUnpinnedHierarchyInOneTransition() {
        let coordinator = GeekPanelCoordinator()
        let selection = GeekPanelHistorySelection.builtIn("network")

        coordinator.previewModule(.network)
        coordinator.presentHistory(selection, pinned: false)
        coordinator.dismissUnpinnedHierarchy()
        XCTAssertEqual(coordinator.route, .summary)

        coordinator.selectModule(.network)
        coordinator.presentHistory(selection, pinned: false)
        coordinator.dismissUnpinnedHierarchy()
        XCTAssertEqual(coordinator.route, .module(.network))
        XCTAssertTrue(coordinator.isModulePinned)
    }

    func testEscapeSuppressesHoveredModuleUntilPointerExits() async {
        var policy = HoverIntentPolicy()
        policy.initialOpenDelay = .milliseconds(5)
        policy.switchDelay = .milliseconds(5)
        let pointer = R2TestValue(NSPoint(x: 120, y: 220))
        let registry = SmallWindowAnchorRegistry()
        let coordinator = GeekPanelCoordinator(
            hoverIntentController: HoverIntentController(policy: policy),
            anchorRegistry: registry,
            pointerLocationProvider: { pointer.value }
        )
        let anchorID = SmallWindowAnchorID.module(.network)
        registry.update(id: anchorID, screenRect: NSRect(x: 100, y: 200, width: 80, height: 44),
                        parentPanelRole: .primary, preferredPlacementEdge: .left, contentKind: "network")
        coordinator.selectModule(.network)
        XCTAssertTrue(coordinator.handleEscape())

        var openCount = 0
        coordinator.scheduleModulePreview(
            .network,
            condition: { true },
            action: {
                openCount += 1
                coordinator.previewModule(.network)
            }
        )
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(coordinator.route, .summary)
        XCTAssertEqual(openCount, 0)

        // onDisappear / rebuilt tracking areas emit exit without a mouse move.
        coordinator.moduleHoverExited(.network)
        coordinator.removeAnchor(anchorID)
        coordinator.moduleHoverExited(.network)
        // Movement within the old trigger is not an exit even after removal.
        pointer.value = NSPoint(x: 125, y: 222)
        coordinator.moduleHoverExited(.network)
        // The replacement host may register its trigger at a new screen rect.
        registry.update(id: anchorID, screenRect: NSRect(x: 200, y: 200, width: 80, height: 44),
                        parentPanelRole: .primary, preferredPlacementEdge: .left, contentKind: "network")
        pointer.value = NSPoint(x: 220, y: 222)
        coordinator.moduleHoverExited(.network)
        coordinator.scheduleModulePreview(.network, condition: { true }) {
            openCount += 1
            coordinator.previewModule(.network)
        }
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(coordinator.route, .summary)
        XCTAssertEqual(openCount, 0)

        pointer.value = NSPoint(x: 320, y: 300)
        coordinator.moduleHoverExited(.network)
        coordinator.scheduleModulePreview(
            .network,
            condition: { true },
            action: {
                openCount += 1
                coordinator.previewModule(.network)
            }
        )
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(coordinator.route, .module(.network))
        XCTAssertEqual(openCount, 1)
    }

    func testEscapeFromSensorsSuppressesDiskUnderStationaryPointerUntilRealDeparture() async {
        var policy = HoverIntentPolicy()
        policy.initialOpenDelay = .milliseconds(5)
        policy.switchDelay = .milliseconds(5)
        let pointer = R2TestValue(NSPoint(x: 120, y: 220))
        let coordinator = GeekPanelCoordinator(
            hoverIntentController: HoverIntentController(policy: policy),
            pointerLocationProvider: { pointer.value }
        )
        func register(_ section: PanelSection, _ rect: NSRect) {
            coordinator.registerAnchor(id: .module(section), screenRect: rect, contentKind: section.rawValue)
        }
        register(.sensors, NSRect(x: 100, y: 400, width: 80, height: 44))
        register(.disk, NSRect(x: 100, y: 200, width: 80, height: 44))
        coordinator.selectModule(.sensors)
        XCTAssertTrue(coordinator.handleEscape())
        coordinator.previewModule(.disk)
        coordinator.previewHardwareDetail(.monitoring)
        XCTAssertEqual(coordinator.route, .summary)

        var openCount = 0
        func enterDisk() {
            coordinator.scheduleModulePreview(.disk, condition: { true }) {
                openCount += 1
                coordinator.previewModule(.disk)
            }
        }
        // Both the old module and the card now under the pointer may emit
        // synthetic exits when the attached overview is replaced.
        coordinator.moduleHoverExited(.sensors)
        coordinator.moduleHoverExited(.disk)
        coordinator.removeAnchor(.module(.disk))
        register(.disk, NSRect(x: 100, y: 180, width: 80, height: 90))
        coordinator.recordPointer(pointer.value)
        enterDisk()
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(openCount, 0)
        XCTAssertEqual(coordinator.route, .summary)

        // Moving within the new, larger trigger is still not a departure.
        pointer.value = NSPoint(x: 125, y: 255)
        coordinator.recordPointer(pointer.value)
        coordinator.moduleHoverExited(.sensors)
        enterDisk()
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(openCount, 0)

        pointer.value = NSPoint(x: 320, y: 300)
        coordinator.recordPointer(pointer.value)
        pointer.value = NSPoint(x: 120, y: 220)
        coordinator.recordPointer(pointer.value)
        enterDisk()
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(coordinator.route, .module(.disk))

        XCTAssertTrue(coordinator.handleEscape())
        coordinator.selectModule(.memory)
        XCTAssertEqual(coordinator.route, .module(.memory), "Explicit clicks bypass hover suppression")
    }

    func testEscapeSuppressesHoveredTertiaryUntilPointerExits() async {
        var policy = HoverIntentPolicy()
        policy.initialOpenDelay = .milliseconds(5)
        policy.switchDelay = .milliseconds(5)
        let pointer = R2TestValue(NSPoint(x: 10, y: 10))
        let coordinator = GeekPanelCoordinator(
            hoverIntentController: HoverIntentController(policy: policy),
            pointerLocationProvider: { pointer.value }
        )
        let selection = GeekPanelHistorySelection.builtIn("power")
        coordinator.selectModule(.power)
        coordinator.presentHistory(selection, pinned: false)
        XCTAssertTrue(coordinator.handleEscape())

        var openCount = 0
        coordinator.scheduleTertiaryPreview(
            identifier: "power",
            condition: { true },
            action: {
                openCount += 1
                coordinator.presentHistory(selection, pinned: false)
            }
        )
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(coordinator.route, .module(.power))
        XCTAssertEqual(openCount, 0)

        pointer.value = NSPoint(x: 200, y: 200)
        coordinator.tertiaryHoverExited()
        coordinator.scheduleTertiaryPreview(
            identifier: "power",
            condition: { true },
            action: {
                openCount += 1
                coordinator.presentHistory(selection, pinned: false)
            }
        )
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(coordinator.route, .history(module: .power, selection: selection))
        XCTAssertEqual(openCount, 1)
    }

    func testEscapeRejectsStaleExitAndSameRowReentryUntilPointerLeavesMeasuredAnchor() async {
        var policy = HoverIntentPolicy()
        policy.initialOpenDelay = .milliseconds(5)
        policy.switchDelay = .milliseconds(5)
        let pointer = R2TestValue(NSPoint(x: 120, y: 220))
        let registry = SmallWindowAnchorRegistry()
        let coordinator = GeekPanelCoordinator(
            hoverIntentController: HoverIntentController(policy: policy),
            anchorRegistry: registry,
            pointerLocationProvider: { pointer.value }
        )
        let anchorID = SmallWindowAnchorID.module(.network)
        registry.update(id: anchorID, screenRect: NSRect(x: 100, y: 200, width: 80, height: 44),
                        parentPanelRole: .primary, preferredPlacementEdge: .left, contentKind: "network")
        coordinator.selectModule(.network)
        coordinator.presentHistory(.inline(UUID()), pinned: false)
        XCTAssertTrue(coordinator.handleEscape())

        var opened = 0
        func schedule(_ identifier: String) {
            coordinator.scheduleTertiaryPreview(identifier: identifier, condition: { true }) {
                opened += 1
                coordinator.presentHistory(.inline(UUID()), pinned: false)
            }
        }

        // An exit/enter caused by closing/rebuilding the column has no pointer
        // movement. Changing the SwiftUI target identity must not bypass Escape.
        coordinator.tertiaryHoverExited()
        schedule("network-history")
        schedule(UUID().uuidString)
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(coordinator.route, .module(.network))
        XCTAssertFalse(coordinator.presentHistory(.inline(UUID()), pinned: false))

        // A late exit while moving inside the same measured overview row is
        // still not a genuine departure from that trigger.
        pointer.value = NSPoint(x: 125, y: 222)
        coordinator.tertiaryHoverExited()
        schedule("network-history")
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(opened, 0)

        // Retain both frames across layout changes: neither an old hitbox nor
        // the moved live hitbox may turn an in-row pointer into a fresh entry.
        registry.update(id: anchorID, screenRect: NSRect(x: 200, y: 200, width: 80, height: 44),
                        parentPanelRole: .primary, preferredPlacementEdge: .left, contentKind: "network")
        pointer.value = NSPoint(x: 220, y: 222)
        coordinator.tertiaryHoverExited()
        schedule("network-history")
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(opened, 0)

        pointer.value = NSPoint(x: 320, y: 300)
        coordinator.tertiaryHoverExited()
        schedule("new-history-entry")
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(opened, 1)
        guard case .history(module: .network, selection: _) = coordinator.route else {
            return XCTFail("A new entry should open after an actual departure from the trigger")
        }
    }

    func testEscapeSuppressionWithoutAnchorRejectsStationaryExitButAllowsExplicitOpen() {
        let pointer = NSPoint(x: 120, y: 220)
        let coordinator = GeekPanelCoordinator(pointerLocationProvider: { pointer })
        coordinator.selectModule(.network)
        coordinator.presentHistory(.inline(UUID()), pinned: false)
        XCTAssertTrue(coordinator.handleEscape())
        coordinator.tertiaryHoverExited()

        XCTAssertFalse(coordinator.presentHistory(.inline(UUID()), pinned: false))
        XCTAssertTrue(coordinator.presentHistory(.inline(UUID()), pinned: true))
        XCTAssertTrue(coordinator.isHistoryPinned)
        XCTAssertTrue(coordinator.handleEscape())
        XCTAssertEqual(coordinator.route, .module(.network))
        XCTAssertTrue(coordinator.handleEscape())
        XCTAssertEqual(coordinator.route, .summary)
    }

    func testAnchorRegistrySuppressesTelemetryOnlyFrameNoise() {
        let registry = SmallWindowAnchorRegistry()
        let frame = NSRect(x: 100, y: 200, width: 80, height: 44)

        XCTAssertTrue(registry.update(
            id: first,
            screenRect: frame,
            parentPanelRole: .primary,
            preferredPlacementEdge: .left,
            contentKind: "processor"
        ))
        let generation = registry.snapshot(for: first)?.lastUpdatedLayoutGeneration
        XCTAssertFalse(registry.update(
            id: first,
            screenRect: frame.offsetBy(dx: 0.2, dy: 0.2),
            parentPanelRole: .primary,
            preferredPlacementEdge: .left,
            contentKind: "processor"
        ))
        XCTAssertEqual(registry.snapshot(for: first)?.lastUpdatedLayoutGeneration, generation)
    }
}
