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
        var pointer = NSPoint(x: 120, y: 220)
        let registry = SmallWindowAnchorRegistry()
        let coordinator = GeekPanelCoordinator(
            hoverIntentController: HoverIntentController(policy: policy),
            anchorRegistry: registry,
            pointerLocationProvider: { pointer }
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
        pointer = NSPoint(x: 125, y: 222)
        coordinator.moduleHoverExited(.network)
        // The replacement host may register its trigger at a new screen rect.
        registry.update(id: anchorID, screenRect: NSRect(x: 200, y: 200, width: 80, height: 44),
                        parentPanelRole: .primary, preferredPlacementEdge: .left, contentKind: "network")
        pointer = NSPoint(x: 220, y: 222)
        coordinator.moduleHoverExited(.network)
        coordinator.scheduleModulePreview(.network, condition: { true }) {
            openCount += 1
            coordinator.previewModule(.network)
        }
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(coordinator.route, .summary)
        XCTAssertEqual(openCount, 0)

        pointer = NSPoint(x: 320, y: 300)
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
        var pointer = NSPoint(x: 120, y: 220)
        let coordinator = GeekPanelCoordinator(
            hoverIntentController: HoverIntentController(policy: policy),
            pointerLocationProvider: { pointer }
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
        coordinator.recordPointer(pointer)
        enterDisk()
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(openCount, 0)
        XCTAssertEqual(coordinator.route, .summary)

        // Moving within the new, larger trigger is still not a departure.
        pointer = NSPoint(x: 125, y: 255)
        coordinator.recordPointer(pointer)
        coordinator.moduleHoverExited(.sensors)
        enterDisk()
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(openCount, 0)

        pointer = NSPoint(x: 320, y: 300)
        coordinator.recordPointer(pointer)
        pointer = NSPoint(x: 120, y: 220)
        coordinator.recordPointer(pointer)
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
        var pointer = NSPoint(x: 10, y: 10)
        let coordinator = GeekPanelCoordinator(
            hoverIntentController: HoverIntentController(policy: policy),
            pointerLocationProvider: { pointer }
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

        pointer = NSPoint(x: 200, y: 200)
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
        var pointer = NSPoint(x: 120, y: 220)
        let registry = SmallWindowAnchorRegistry()
        let coordinator = GeekPanelCoordinator(
            hoverIntentController: HoverIntentController(policy: policy),
            anchorRegistry: registry,
            pointerLocationProvider: { pointer }
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
        pointer = NSPoint(x: 125, y: 222)
        coordinator.tertiaryHoverExited()
        schedule("network-history")
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(opened, 0)

        // Retain both frames across layout changes: neither an old hitbox nor
        // the moved live hitbox may turn an in-row pointer into a fresh entry.
        registry.update(id: anchorID, screenRect: NSRect(x: 200, y: 200, width: 80, height: 44),
                        parentPanelRole: .primary, preferredPlacementEdge: .left, contentKind: "network")
        pointer = NSPoint(x: 220, y: 222)
        coordinator.tertiaryHoverExited()
        schedule("network-history")
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(opened, 0)

        pointer = NSPoint(x: 320, y: 300)
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
