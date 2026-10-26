import AppKit
import XCTest
@testable import StorageCleanerMac

/// D123 (2026-10-19): the attached menus follow iStat Menus 7.30's
/// `BBRMenu` rules (`mouseExited:`, `mouseMoved:`, `isPrimaryMenu`): leaving
/// the module column closes its history page, leaving the overview for empty
/// space closes the module column, leaving the history page closes nothing,
/// and a gap is a change of target to no item.
@MainActor
final class GeekPanelMenuRuleTests: XCTestCase {
    private let networkCard = NSRect(x: 100, y: 300, width: 80, height: 40)
    private let memoryCard = NSRect(x: 100, y: 240, width: 80, height: 40)
    private let overviewGap = NSPoint(x: 140, y: 290)
    private let modulePoint = NSPoint(x: 40, y: 300)
    private let historyPoint = NSPoint(x: -60, y: 300)
    private let outside = NSPoint(x: 600, y: 600)

    private func makeCoordinator(registersCards: Bool = true) -> GeekPanelCoordinator {
        let registry = SmallWindowAnchorRegistry()
        if registersCards {
            for (section, rect) in [(PanelSection.network, networkCard), (.memory, memoryCard)] {
                registry.update(id: .module(section), screenRect: rect, parentPanelRole: .primary,
                                preferredPlacementEdge: .left, contentKind: section.rawValue)
            }
        }
        return GeekPanelCoordinator(anchorRegistry: registry, pointerLocationProvider: { .zero })
    }

    private func move(_ coordinator: GeekPanelCoordinator, to column: GeekPanelColumn?, at point: NSPoint,
                      overPalette: Bool = false, isPointerEvent: Bool = true) {
        coordinator.pointerMoved(to: column, at: point, isOverPalette: overPalette, isPointerEvent: isPointerEvent)
    }

    private func openHistory(_ coordinator: GeekPanelCoordinator, pinned: Bool = false) {
        coordinator.previewModule(.network)
        move(coordinator, to: .overview, at: NSPoint(x: networkCard.midX, y: networkCard.midY))
        move(coordinator, to: .module, at: modulePoint)
        XCTAssertTrue(coordinator.presentHistory(.builtIn("network"), pinned: pinned))
    }

    private func nextTurns() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testLeavingTheModuleColumnClosesItsHistoryPageAtOnce() {
        for destination: (GeekPanelColumn?, NSPoint) in [(nil, outside), (.overview, overviewGap)] {
            let coordinator = makeCoordinator()
            openHistory(coordinator)
            move(coordinator, to: destination.0, at: destination.1)
            XCTAssertEqual(coordinator.route, .module(.network), "\(String(describing: destination.0))")
        }
    }

    func testLeavingTheModuleColumnForItsHistoryPageKeepsIt() {
        let coordinator = makeCoordinator()
        openHistory(coordinator)
        move(coordinator, to: .history, at: historyPoint)
        XCTAssertEqual(coordinator.route, .history(module: .network, selection: .builtIn("network")))
        XCTAssertEqual(coordinator.pointerColumn, .history)
    }

    func testLeavingTheHistoryPageClosesNothing() async {
        let coordinator = makeCoordinator()
        openHistory(coordinator)
        move(coordinator, to: .history, at: historyPoint)
        move(coordinator, to: nil, at: outside)
        await nextTurns()
        XCTAssertEqual(coordinator.route, .history(module: .network, selection: .builtIn("network")))
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope, "The module column stays too")
    }

    func testAPinnedHistoryPageStaysWhenThePointerLeavesTheModuleColumn() {
        let coordinator = makeCoordinator()
        openHistory(coordinator, pinned: true)
        move(coordinator, to: nil, at: outside)
        XCTAssertEqual(coordinator.route, .history(module: .network, selection: .builtIn("network")))
    }

    func testOnlyLeavingTheOverviewForEmptySpaceDropsTheEnvelope() {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        move(coordinator, to: .overview, at: NSPoint(x: networkCard.midX, y: networkCard.midY))
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope)
        move(coordinator, to: nil, at: outside)
        XCTAssertFalse(coordinator.isPointerWithinHoverEnvelope, "iStat closes the submenu on the overview's exit")

        // From the module column the submenu stays, however the pointer leaves.
        move(coordinator, to: .module, at: modulePoint)
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope)
        move(coordinator, to: nil, at: outside)
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope)
        move(coordinator, to: nil, at: NSPoint(x: outside.x + 30, y: outside.y))
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope, "Movement in empty space is no exit")

        // A presented palette is part of the session; leaving it for empty
        // space counts as leaving the menu the pointer came from.
        move(coordinator, to: .overview, at: NSPoint(x: networkCard.midX, y: networkCard.midY))
        move(coordinator, to: nil, at: NSPoint(x: 300, y: 320), overPalette: true)
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope)
        move(coordinator, to: nil, at: outside)
        XCTAssertFalse(coordinator.isPointerWithinHoverEnvelope)
    }

    func testAReadingAfterALayoutChangeClosesNothing() async {
        let coordinator = makeCoordinator()
        openHistory(coordinator)
        move(coordinator, to: nil, at: outside, isPointerEvent: false)
        move(coordinator, to: .module, at: modulePoint, isPointerEvent: false)
        move(coordinator, to: .overview, at: overviewGap, isPointerEvent: false)
        await nextTurns()
        XCTAssertEqual(coordinator.route, .history(module: .network, selection: .builtIn("network")))
    }

    func testTheOverviewIgnoresThePointerWhileAHistoryPageIsOpen() async {
        let coordinator = makeCoordinator()
        openHistory(coordinator, pinned: true)
        move(coordinator, to: .overview, at: NSPoint(x: memoryCard.midX, y: memoryCard.midY))
        XCTAssertNil(coordinator.pointerColumn, "Not a primary menu while the history page is open")
        var opened = false
        coordinator.scheduleModulePreview(.memory, condition: { true }) {
            opened = true
            coordinator.previewModule(.memory)
        }
        move(coordinator, to: .overview, at: overviewGap)
        move(coordinator, to: nil, at: outside)
        await nextTurns()
        XCTAssertFalse(opened)
        XCTAssertEqual(coordinator.route, .history(module: .network, selection: .builtIn("network")))
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope, "Its exit closes nothing either")
    }

    func testReachingAGapInTheOverviewClosesTheModule() async {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        move(coordinator, to: .overview, at: NSPoint(x: networkCard.midX, y: networkCard.midY))
        move(coordinator, to: .overview, at: overviewGap)
        XCTAssertEqual(coordinator.route, .module(.network), "Closes on the next turn, not inside the event")
        await nextTurns()
        XCTAssertEqual(coordinator.route, .summary)
    }

    func testAGapCloseDoesNotRunOnceThePointerIsBackOnTheOpenCard() async {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        move(coordinator, to: .overview, at: NSPoint(x: networkCard.midX, y: networkCard.midY))
        move(coordinator, to: .overview, at: overviewGap)
        move(coordinator, to: .overview, at: NSPoint(x: networkCard.midX, y: networkCard.minY + 2))
        await nextTurns()
        XCTAssertEqual(coordinator.route, .module(.network))
    }

    func testComingBackFromTheModuleColumnOverAGapClosesTheModule() async {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        move(coordinator, to: .module, at: modulePoint)
        move(coordinator, to: .overview, at: overviewGap)
        await nextTurns()
        XCTAssertEqual(coordinator.route, .summary)
    }

    func testAGapCloseWaitsForTheOpenCardsAnchor() async {
        // A card rebuilt in the attached shell registers its anchor a turn later.
        let coordinator = makeCoordinator(registersCards: false)
        coordinator.previewModule(.network)
        move(coordinator, to: .overview, at: NSPoint(x: networkCard.midX, y: networkCard.midY))
        move(coordinator, to: .overview, at: overviewGap)
        await nextTurns()
        XCTAssertEqual(coordinator.route, .module(.network))
    }

    func testAPinnedModuleHasNoGapClose() async {
        let coordinator = makeCoordinator()
        coordinator.selectModule(.network)
        move(coordinator, to: .overview, at: NSPoint(x: networkCard.midX, y: networkCard.midY))
        move(coordinator, to: .overview, at: overviewGap)
        await nextTurns()
        XCTAssertEqual(coordinator.route, .module(.network))
    }

    func testComingBackIntoTheModuleColumnOverAGapClosesTheHistoryPage() async {
        for path: [(GeekPanelColumn?, NSPoint)] in [
            [(.history, historyPoint), (.module, modulePoint)],
            [(.history, historyPoint), (nil, outside), (.module, modulePoint)],
        ] {
            let coordinator = makeCoordinator()
            openHistory(coordinator)
            for (column, point) in path {
                move(coordinator, to: column, at: point)
            }
            XCTAssertNotEqual(coordinator.route, .module(.network), "Closes on the next turn")
            await nextTurns()
            XCTAssertEqual(coordinator.route, .module(.network))
        }
    }

    func testComingBackOntoARowWithAPageKeepsTheHistoryPage() async {
        for reportsBeforeTheReading in [true, false] {
            let coordinator = makeCoordinator()
            openHistory(coordinator)
            move(coordinator, to: .history, at: historyPoint)
            if reportsBeforeTheReading {
                coordinator.tertiaryTargetHoverChanged("row", hovering: true)
                move(coordinator, to: .module, at: modulePoint)
            } else {
                move(coordinator, to: .module, at: modulePoint)
                coordinator.tertiaryTargetHoverChanged("row", hovering: true)
            }
            await nextTurns()
            XCTAssertEqual(
                coordinator.route,
                .history(module: .network, selection: .builtIn("network")),
                "row reported \(reportsBeforeTheReading ? "before" : "after") the reading"
            )
        }
    }

    func testARowExitMayCloseOnlyOverAGap() {
        let coordinator = makeCoordinator()
        openHistory(coordinator)
        XCTAssertTrue(coordinator.allowsTertiaryGapClose)
        coordinator.tertiaryTargetHoverChanged("row", hovering: true)
        XCTAssertFalse(coordinator.allowsTertiaryGapClose, "Another row made the change of target")
        coordinator.tertiaryTargetHoverChanged("row", hovering: false)
        XCTAssertTrue(coordinator.allowsTertiaryGapClose)
        move(coordinator, to: .history, at: historyPoint)
        XCTAssertFalse(coordinator.allowsTertiaryGapClose, "The pointer is on the page")
    }

    func testACardClickOpensItsModuleUnpinnedAndAgainChangesNothing() {
        let coordinator = makeCoordinator()
        coordinator.openModule(.network)
        XCTAssertEqual(coordinator.route, .module(.network))
        XCTAssertFalse(coordinator.isModulePinned)
        XCTAssertTrue(coordinator.isPointerWithinHoverEnvelope, "Keyboard or VoiceOver opens must not close at once")

        coordinator.openModule(.network)
        XCTAssertEqual(coordinator.route, .module(.network), "No toggle")
        XCTAssertTrue(coordinator.presentHistory(.builtIn("network"), pinned: false))
        coordinator.openModule(.network)
        XCTAssertEqual(coordinator.route, .history(module: .network, selection: .builtIn("network")))

        coordinator.openModule(.memory)
        XCTAssertEqual(coordinator.route, .module(.memory))
        XCTAssertFalse(coordinator.isModulePinned)
        coordinator.openModule(.overview)
        XCTAssertEqual(coordinator.route, .summary)
    }

    func testACardClickOpensAfterEscape() {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        XCTAssertTrue(coordinator.handleEscape())
        coordinator.previewModule(.network)
        XCTAssertEqual(coordinator.route, .summary, "Hover stays suppressed after Escape")
        coordinator.openModule(.network)
        XCTAssertEqual(coordinator.route, .module(.network))
    }

    func testTheSensorsCardClickOpensTheHardwarePageUnpinned() {
        let coordinator = makeCoordinator()
        coordinator.openHardwareDetail(.monitoring)
        XCTAssertEqual(coordinator.route, .module(.sensors))
        XCTAssertEqual(coordinator.hardwareDetailFocus, .monitoring)
        XCTAssertFalse(coordinator.isModulePinned)
        coordinator.openHardwareDetail(.monitoring)
        XCTAssertEqual(coordinator.route, .module(.sensors), "No toggle (was `selectHardwareDetail`)")
        coordinator.openHardwareDetail(.power)
        XCTAssertEqual(coordinator.hardwareDetailFocus, .power)
    }

    func testAnExplicitRowOpenEndsEscapeSuppressionAndAPin() {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        XCTAssertTrue(coordinator.presentHistory(.builtIn("network"), pinned: true))
        XCTAssertFalse(coordinator.presentHistory(.builtIn("other"), pinned: false), "Hover does not replace a pin")
        coordinator.prepareExplicitTertiaryOpen()
        XCTAssertTrue(coordinator.presentHistory(.builtIn("other"), pinned: false))
        XCTAssertFalse(coordinator.isHistoryPinned)

        XCTAssertTrue(coordinator.handleEscape())
        XCTAssertFalse(coordinator.presentHistory(.builtIn("network"), pinned: false), "Escape suppresses hover")
        coordinator.prepareExplicitTertiaryOpen()
        XCTAssertTrue(coordinator.presentHistory(.builtIn("network"), pinned: false))
    }

    // MARK: Arrow keys (iStat Menus 7.30 `BBRMenu keyDown:`)

    func testDownAndUpMoveThroughTheOverviewCardsWithoutWrappingOrOpening() {
        let coordinator = makeCoordinator()
        XCTAssertTrue(coordinator.handleArrowKey(.down))
        XCTAssertEqual(coordinator.keyboardHighlight, .card(.network), "The top card first")
        XCTAssertTrue(coordinator.handleArrowKey(.down))
        XCTAssertEqual(coordinator.keyboardHighlight, .card(.memory))
        XCTAssertTrue(coordinator.handleArrowKey(.down))
        XCTAssertEqual(coordinator.keyboardHighlight, .card(.memory), "No wrap at the end")
        XCTAssertTrue(coordinator.handleArrowKey(.up))
        XCTAssertEqual(coordinator.keyboardHighlight, .card(.network))
        XCTAssertTrue(coordinator.handleArrowKey(.up))
        XCTAssertEqual(coordinator.keyboardHighlight, .card(.network), "No wrap at the start")
        XCTAssertEqual(coordinator.route, .summary, "Moving the highlight opens nothing")

        let fromNothing = makeCoordinator()
        XCTAssertTrue(fromNothing.handleArrowKey(.up))
        XCTAssertEqual(fromNothing.keyboardHighlight, .card(.memory), "↑ starts from the last card")
        XCTAssertFalse(makeCoordinator(registersCards: false).handleArrowKey(.down), "No cards, no use")
    }

    func testRightOpensTheHighlightedCardsModuleAndKeepsItsHighlight() {
        let coordinator = makeCoordinator()
        XCTAssertFalse(coordinator.handleArrowKey(.right), "Nothing is highlighted")
        XCTAssertEqual(coordinator.route, .summary)
        coordinator.handleArrowKey(.down)
        XCTAssertTrue(coordinator.handleArrowKey(.right))
        XCTAssertEqual(coordinator.route, .module(.network))
        XCTAssertFalse(coordinator.isModulePinned, "The same unpinned open as a click")
        XCTAssertEqual(coordinator.keyboardHighlight, .card(.network))
    }

    func testLeftClosesTheDeepestMenuAndLeavesItsItemHighlighted() {
        let coordinator = makeCoordinator()
        XCTAssertFalse(coordinator.handleArrowKey(.left), "The overview has no parent")
        coordinator.previewModule(.network)
        XCTAssertTrue(coordinator.handleArrowKey(.left))
        XCTAssertEqual(coordinator.route, .summary)
        XCTAssertEqual(coordinator.keyboardHighlight, .card(.network))
        coordinator.previewModule(.network)
        XCTAssertEqual(coordinator.route, .summary, "A resting pointer does not reopen it")
        XCTAssertTrue(coordinator.handleArrowKey(.right))
        XCTAssertEqual(coordinator.route, .module(.network), "→ reopens it")
    }

    func testLeftFromARowsHistoryPageLeavesTheRowHighlighted() {
        let coordinator = makeCoordinator()
        let row = UUID()
        coordinator.previewModule(.network)
        XCTAssertTrue(coordinator.presentHistory(.inline(row), pinned: true))
        XCTAssertTrue(coordinator.handleArrowKey(.left))
        XCTAssertEqual(coordinator.route, .module(.network))
        XCTAssertEqual(coordinator.keyboardHighlight, .row(row.uuidString))

        XCTAssertTrue(coordinator.presentHistory(.builtIn("network"), pinned: true))
        XCTAssertTrue(coordinator.handleArrowKey(.left))
        XCTAssertNil(coordinator.keyboardHighlight, "A page without a row leaves nothing highlighted")
    }

    func testDownAndUpMoveThroughTheModuleRowsInTheirOrder() {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        coordinator.registerTertiaryTarget("b", offset: 40)
        coordinator.registerTertiaryTarget("c", offset: 40)
        coordinator.registerTertiaryTarget("a", offset: 10)
        let expected = ["a", "b", "c", "c"]
        for identifier in expected {
            XCTAssertTrue(coordinator.handleArrowKey(.down))
            XCTAssertEqual(coordinator.keyboardHighlight, .row(identifier))
        }
        XCTAssertEqual(coordinator.route, .module(.network), "Moving the highlight opens nothing")

        coordinator.registerTertiaryTarget("c", offset: nil)
        XCTAssertNil(coordinator.keyboardHighlight, "A row that goes away loses the highlight")
        XCTAssertTrue(coordinator.handleArrowKey(.up))
        XCTAssertEqual(coordinator.keyboardHighlight, .row("b"), "↑ starts from the last row")
    }

    func testRightOnAHighlightedRowAsksThatRowToOpenEachTime() {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        XCTAssertFalse(coordinator.handleArrowKey(.down), "No rows with a page")
        coordinator.registerTertiaryTarget("a", offset: 10)
        XCTAssertFalse(coordinator.handleArrowKey(.right), "Nothing is highlighted")
        XCTAssertNil(coordinator.rowOpenRequest)
        coordinator.handleArrowKey(.down)
        XCTAssertTrue(coordinator.handleArrowKey(.right))
        let first = coordinator.rowOpenRequest
        XCTAssertEqual(first?.identifier, "a")
        XCTAssertTrue(coordinator.handleArrowKey(.right))
        XCTAssertEqual(coordinator.rowOpenRequest?.identifier, "a")
        XCTAssertNotEqual(coordinator.rowOpenRequest, first, "A new request each time")
    }

    func testTheHistoryPageTakesNoVerticalHighlight() {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        coordinator.registerTertiaryTarget("a", offset: 10)
        XCTAssertTrue(coordinator.presentHistory(.builtIn("network"), pinned: true))
        XCTAssertFalse(coordinator.handleArrowKey(.down))
        XCTAssertFalse(coordinator.handleArrowKey(.up))
        XCTAssertFalse(coordinator.handleArrowKey(.right))
    }

    func testOnlyARealPointerMoveClearsTheKeyboardHighlight() {
        let coordinator = makeCoordinator()
        let resting = NSPoint(x: networkCard.midX, y: networkCard.midY)
        move(coordinator, to: .overview, at: resting)
        coordinator.handleArrowKey(.down)
        move(coordinator, to: .overview, at: resting)
        XCTAssertEqual(coordinator.keyboardHighlight, .card(.network), "The same place is not a move")
        move(coordinator, to: .overview, at: NSPoint(x: resting.x + 4, y: resting.y), isPointerEvent: false)
        XCTAssertEqual(coordinator.keyboardHighlight, .card(.network), "A layout refresh is not a move")
        move(coordinator, to: .overview, at: NSPoint(x: resting.x + 8, y: resting.y))
        XCTAssertNil(coordinator.keyboardHighlight)

        coordinator.handleArrowKey(.down)
        coordinator.reset()
        XCTAssertNil(coordinator.keyboardHighlight, "A reset clears it")
    }

    func testANewlyShownPanelForgetsWhereThePointerWas() async {
        let coordinator = makeCoordinator()
        coordinator.previewModule(.network)
        move(coordinator, to: .module, at: modulePoint)
        coordinator.reset()
        coordinator.resetPointerTracking()
        XCTAssertNil(coordinator.pointerColumn)
        coordinator.previewModule(.network)
        move(coordinator, to: nil, at: outside)
        await nextTurns()
        XCTAssertEqual(coordinator.route, .module(.network), "No exit without a reading inside")
        XCTAssertFalse(coordinator.isPointerWithinHoverEnvelope)
    }
}
