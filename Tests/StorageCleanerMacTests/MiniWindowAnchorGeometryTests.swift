import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Batch 4b, N9 and item 4: the level-one anchors and the session's cascade
/// must not fall behind the view.
///
/// - An anchor view reports its screen rect again after its window or one of
///   its ancestors moved, not only after its own layout.
/// - A request that reaches the session while it applies a frame (a
///   registered anchor, a measured size, a selected page delivered by the
///   view update that the frame runs) is replayed afterwards, not dropped.
///   Dropping a page change left the session on the previous page's 264 pt
///   power column while the view showed a 312 pt page: the group drew 48 pt
///   off until the next unrelated request.
/// - The secondary top offset comes from the card's layout offset inside the
///   overview when the anchor carries one, so it no longer depends on when
///   the window frame and the SwiftUI layout were last in agreement.
@MainActor
final class MiniWindowAnchorGeometryTests: XCTestCase {
    // MARK: - Anchor view reporting

    func testAnchorViewReportsAfterItsWindowOrAnAncestorMoves() async throws {
        let panel = MenuBarStatusPanel(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200))
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let container = NSView(frame: NSRect(x: 10, y: 10, width: 200, height: 100))
        try XCTUnwrap(panel.contentView).addSubview(container)
        let anchor = SmallWindowAnchorNSView(frame: NSRect(x: 5, y: 5, width: 40, height: 20))
        var reported: [NSRect] = []
        anchor.onSnapshotChanged = { rect, _ in reported.append(rect) }
        container.addSubview(anchor)
        panel.orderFrontRegardless()
        func onScreen() -> NSRect { panel.convertToScreen(anchor.convert(anchor.bounds, to: nil)) }

        await settle()
        XCTAssertEqual(reported, [onScreen()], "the first report follows the attachment")

        panel.setFrameOrigin(NSPoint(x: 160, y: 130))
        await settle()
        XCTAssertEqual(reported.count, 2, "a moved window changes every anchor's screen rect")
        XCTAssertEqual(reported.last, onScreen())

        container.setFrameOrigin(NSPoint(x: 40, y: 30))
        await settle()
        XCTAssertEqual(reported.count, 3, "a moved ancestor changes the anchor's screen rect")
        XCTAssertEqual(reported.last, onScreen())

        anchor.setFrameOrigin(NSPoint(x: 12, y: 8))
        await settle()
        XCTAssertEqual(reported.count, 4, "the view's own origin")
        XCTAssertEqual(reported.last, onScreen())

        // Unchanged geometry is not reported again.
        panel.setFrameOrigin(panel.frame.origin)
        container.setFrameOrigin(container.frame.origin)
        await settle()
        XCTAssertEqual(reported.count, 4)

        anchor.removeFromSuperview()
        panel.setFrameOrigin(NSPoint(x: 200, y: 150))
        await settle()
        XCTAssertEqual(reported.count, 4, "a detached anchor stops reporting")
    }

    /// Review P2-9: the observed ancestor chain follows a re-parented
    /// ancestor. AppKit sends `viewWillMove(toWindow:)` and
    /// `viewDidMoveToWindow()` to the whole subtree even when the ancestor
    /// moves to another superview in the same window, and the anchor view
    /// rebuilds its observers there.
    func testAnchorFollowsANewAncestorAfterItsAncestorIsReparented() async throws {
        let panel = MenuBarStatusPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 240))
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let content = try XCTUnwrap(panel.contentView)
        let oldParent = NSView(frame: NSRect(x: 10, y: 10, width: 150, height: 150))
        let newParent = NSView(frame: NSRect(x: 200, y: 20, width: 180, height: 180))
        let container = NSView(frame: NSRect(x: 5, y: 5, width: 120, height: 100))
        content.addSubview(oldParent)
        content.addSubview(newParent)
        oldParent.addSubview(container)
        let anchor = SmallWindowAnchorNSView(frame: NSRect(x: 4, y: 4, width: 40, height: 20))
        var reported: [NSRect] = []
        anchor.onSnapshotChanged = { rect, _ in reported.append(rect) }
        container.addSubview(anchor)
        panel.orderFrontRegardless()
        func onScreen() -> NSRect { panel.convertToScreen(anchor.convert(anchor.bounds, to: nil)) }
        await settle()
        XCTAssertEqual(reported.last, onScreen())

        // The container moves to another parent in the same window.
        newParent.addSubview(container)
        await settle()
        XCTAssertEqual(reported.last, onScreen(), "re-parenting moves the anchor on screen")
        let count = reported.count

        // Moving the new parent is observed; the old one is not any more.
        newParent.setFrameOrigin(NSPoint(x: 210, y: 30))
        await settle()
        XCTAssertEqual(reported.count, count + 1, "the new ancestor is observed")
        XCTAssertEqual(reported.last, onScreen())
        oldParent.setFrameOrigin(NSPoint(x: 0, y: 0))
        await settle()
        XCTAssertEqual(reported.count, count + 1, "the old ancestor no longer moves the anchor")
    }

    func testLevelOneCardsRegisterTheirLayoutOffsetInsideTheOverview() async throws {
        let coordinator = GeekPanelCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 304, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: OverviewCards().environment(\.geekPanelHoverCoordinator, coordinator))
        window.orderFrontRegardless()
        let registered = await eventually {
            coordinator.anchorRegistry.snapshot(for: .module(.sensors)) != nil
        }
        XCTAssertTrue(registered)
        XCTAssertEqual(coordinator.anchorRegistry.snapshot(for: .module(.processor))?.layoutOffset, 8)
        XCTAssertEqual(coordinator.anchorRegistry.snapshot(for: .module(.sensors))?.layoutOffset, 8 + 106 + 6)
    }

    // MARK: - Session: deferred requests

    /// The card registers its anchor from the view update that the session's
    /// own `setFrame(display: true)` runs. The cascade must end up on the
    /// registered top (120 pt), not on the default memory offset.
    func testAnchorRegisteredDuringTheProgrammaticFrameIsAppliedAfterwards() throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.session.show(anchor: harness.anchor, screen: harness.screen, density: .geek)

        harness.hook.action = { [weak panel = harness.session.panel, weak coordinator = harness.coordinator] in
            guard let panel, let coordinator else { return }
            // The memory card, 120 pt below the overview's top edge, with the
            // overview being the right column of a left cascade.
            coordinator.registerAnchor(
                id: .module(.memory),
                screenRect: NSRect(x: panel.frame.maxX - 304 + 8, y: panel.frame.maxY - 120 - 106, width: 288, height: 106),
                contentKind: "memory"
            )
        }
        harness.session.setGeekSection(.memory)
        harness.hook.action = nil

        XCTAssertNotNil(harness.coordinator.anchorRegistry.snapshot(for: .module(.memory)),
                        "the anchor was registered while the frame was applied")
        let frames = harness.session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1].maxY - frames[0].maxY, 120, accuracy: 0.5,
                       "the registered card top, not the default memory offset "
                       + "\(GeekPanelPresentationMetrics.detailVerticalOffset(for: .memory, density: .geek))")
    }

    /// The view selects another page from the update that the session's
    /// frame runs (the way `MenuBarAdvancedStatusView` forwards its section).
    /// The session must not stay on the previous page's column.
    func testPageChangeRequestedDuringTheProgrammaticFrameIsAppliedAfterwards() throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.session.show(anchor: harness.anchor, screen: harness.screen, density: .geek)
        harness.session.setGeekSection(.power)
        XCTAssertEqual(harness.session.visibleAttachedContentFramesForTesting[0].width,
                       MiniWindowStyleTokens.powerDetailWidth)

        harness.hook.action = { [weak session = harness.session, hook = harness.hook] in
            hook.action = nil
            session?.setGeekSection(.processor)
        }
        // Any request that re-solves the cascade and applies a new frame.
        harness.session.setDetailSize(CGSize(width: MiniWindowStyleTokens.powerDetailWidth, height: 500))

        XCTAssertNil(harness.hook.action, "the nested request was made during the frame")
        XCTAssertEqual(harness.session.geekSection, .processor)
        let frames = harness.session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(frames[0].width, MiniWindowStyleTokens.detailWidth,
                       "the 312 pt page, not the 264 pt power column the view no longer shows")
        XCTAssertEqual(harness.session.panel.frame.width, frames[0].width + frames[1].width, accuracy: 0.5)
    }

    /// Two calls made in one frame keep their order: the page the view
    /// selected, then the size it measured for that page. Replaying only the
    /// last call would re-apply the previous page, because the measurement
    /// re-resolves the page the session still holds.
    func testCallsDeliveredDuringOneFrameAreReplayedInOrder() throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.session.show(anchor: harness.anchor, screen: harness.screen, density: .geek)
        harness.session.setGeekSection(.power)

        harness.hook.action = { [weak session = harness.session, hook = harness.hook] in
            hook.action = nil
            session?.setGeekSection(.processor)
            session?.setDetailSize(CGSize(width: MiniWindowStyleTokens.detailWidth, height: 630))
        }
        harness.session.setDetailSize(CGSize(width: MiniWindowStyleTokens.powerDetailWidth, height: 500))

        XCTAssertNil(harness.hook.action, "both calls were made during the frame")
        XCTAssertEqual(harness.session.geekSection, .processor,
                       "the page change is not replaced by the measurement that followed it")
        let frames = harness.session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(frames[0].size, CGSize(width: MiniWindowStyleTokens.detailWidth, height: 630))
    }

    /// A measured secondary size that arrives during the frame updates the
    /// session's size, so the frames must follow it as well.
    func testMeasuredDetailSizeDeliveredDuringTheProgrammaticFrameIsAppliedAfterwards() throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.session.show(anchor: harness.anchor, screen: harness.screen, density: .geek)
        harness.session.setGeekSection(.processor)
        let initialHeight = harness.session.visibleAttachedContentFramesForTesting[0].height

        harness.hook.action = { [weak session = harness.session, hook = harness.hook] in
            hook.action = nil
            session?.setDetailSize(CGSize(width: MiniWindowStyleTokens.detailWidth, height: 600))
        }
        // A first measurement changes the frame; the view update inside that
        // frame delivers a second one.
        harness.session.setDetailSize(CGSize(width: MiniWindowStyleTokens.detailWidth, height: 650))

        XCTAssertNil(harness.hook.action, "the nested measurement was delivered during the frame")
        XCTAssertNotEqual(initialHeight, 600)
        XCTAssertEqual(harness.session.detailColumnSize?.height, 600)
        XCTAssertEqual(harness.session.visibleAttachedContentFramesForTesting[0].height, 600,
                       "the frames follow the size the session already holds")
    }

    // MARK: - Session: replay order and bound (review of batch 4b, P2-1, P2-2)

    /// More deferred calls than one synchronous replay runs continue on the
    /// next main-queue turn. A call that reaches the session before that turn
    /// must run after them, not before (the reviewer's reproduction: the
    /// user's later page ended up replaced by an older queued page).
    func testACallMadeWhileSpilledCallsWaitRunsAfterThem() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.session.show(anchor: harness.anchor, screen: harness.screen, density: .geek)
        harness.session.setGeekSection(.processor)

        // Every frame runs the hook, which selects the other page: each call
        // changes the frame and so produces the next one.
        var issued = 0
        harness.hook.action = { [weak session = harness.session] in
            guard let session, issued < 14 else { return }
            issued += 1
            session.setGeekSection(issued.isMultiple(of: 2) ? .power : .processor)
        }
        harness.session.setDetailSize(CGSize(width: MiniWindowStyleTokens.detailWidth, height: 380))
        harness.hook.action = nil
        XCTAssertGreaterThan(issued, 8, "the chain went past the synchronous replay limit (8)")

        // The user selects another page before the next main-queue turn.
        harness.session.setGeekSection(.memory)
        await settle(turns: 6)
        XCTAssertEqual(harness.session.geekSection, .memory,
                       "older queued calls must not be replayed after a later call")
    }

    /// Two calls that keep undoing each other must not replay on every
    /// main-queue turn forever. The session's frame hook stands in for the
    /// view update inside `setFrame(display: true)`: each applied frame asks
    /// for the other page, which changes the frame again (264 pt power
    /// column, 312 pt processor page), without end.
    func testCallsThatKeepUndoingEachOtherStopAfterABoundedNumber() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.session.show(anchor: harness.anchor, screen: harness.screen, density: .geek)
        harness.session.setGeekSection(.processor)

        var issued = 0
        harness.session.programmaticFrameDidApplyForTesting = { [weak session = harness.session] in
            guard let session else { return }
            issued += 1
            session.setGeekSection(session.geekSection == .power ? .processor : .power)
        }
        harness.session.setDetailSize(CGSize(width: MiniWindowStyleTokens.detailWidth, height: 380))
        await settle(turns: 30)
        let afterSettling = issued
        await settle(turns: 20)
        harness.session.programmaticFrameDidApplyForTesting = nil

        XCTAssertEqual(issued, afterSettling, "replaying stopped instead of running on every turn")
        XCTAssertLessThanOrEqual(afterSettling, 40, "a bounded number of replays for one operation")
        // A later call from outside is still applied.
        harness.session.setGeekSection(.memory)
        await settle(turns: 3)
        XCTAssertEqual(harness.session.geekSection, .memory)
    }

    /// BOARD N11-2: when one operation's calls reach the replay bound, the
    /// newest page selection and the calls made after it are applied, not
    /// only the newest call. Each frame here (the view update inside it)
    /// selects the other page and then reports a height for that page; the
    /// pairs stop after 21, so the bound is reached while the last pairs
    /// still wait. Running only the newest call left the session on an older
    /// page with the newest page's height.
    func testTheBoundedReplayKeepsTheNewestPageAndTheCallsAfterIt() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.session.show(anchor: harness.anchor, screen: harness.screen, density: .geek)
        harness.session.setGeekSection(.processor)

        var pairs = 0
        var lastSection = PanelSection.processor
        var lastHeight: CGFloat = 0
        harness.session.programmaticFrameDidApplyForTesting = { [weak session = harness.session] in
            guard let session, pairs < 21 else { return }
            pairs += 1
            lastSection = pairs.isMultiple(of: 2) ? .processor : .power
            lastHeight = CGFloat(400 + pairs)
            session.setGeekSection(lastSection)
            session.setDetailSize(CGSize(width: lastSection == .power ? MiniWindowStyleTokens.powerDetailWidth
                                                                      : MiniWindowStyleTokens.detailWidth,
                                         height: lastHeight))
        }
        harness.session.setDetailSize(CGSize(width: MiniWindowStyleTokens.detailWidth, height: 380))
        await settle(turns: 30)
        harness.session.programmaticFrameDidApplyForTesting = nil

        XCTAssertEqual(pairs, 21)
        XCTAssertEqual(harness.session.geekSection, lastSection, "the newest page")
        XCTAssertEqual(harness.session.detailColumnSize?.height, lastHeight, "with the height reported for it")
        // A later call from outside is still applied.
        harness.session.setGeekSection(.power)
        await settle(turns: 3)
        XCTAssertEqual(harness.session.geekSection, .power)
    }

    // MARK: - Session: layout offset

    func testSecondaryTopUsesTheCardLayoutOffsetWhenTheAnchorCarriesOne() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "Tests require an attached screen")
        let suiteName = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        defer { TestPreferenceDomain.cleanup(suiteName: suiteName) }
        let coordinator = GeekPanelCoordinator()
        let panel = MenuBarStatusPanel(contentRect: .zero)
        panel.isReleasedWhenClosed = false
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let session = MenuBarPanelSession(
            panel: panel, rootView: AnyView(EmptyView()), initialDensity: .geek,
            geometryStore: PanelGeometryStore(defaults: defaults),
            panelSettingsState: MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults),
            panelCoordinator: coordinator,
            pointerLocationProvider: { NSPoint(x: -10_000, y: -10_000) },
            applicationIsActiveProvider: { true },
            fixedVisibleFrame: visible, presentsPanelOnShow: false, onClose: {}
        )
        defer { session.teardown() }
        session.show(anchor: NSRect(x: visible.midX - 12, y: visible.maxY - 24, width: 24, height: 20),
                     screen: screen, density: .geek)

        // A screen rect from a window position the panel no longer has, with
        // the card's offset inside the overview.
        coordinator.registerAnchor(
            id: .module(.memory),
            screenRect: NSRect(x: -5_000, y: -5_000, width: 288, height: 106),
            contentKind: "memory",
            layoutOffset: 120
        )
        session.setGeekSection(.memory)
        let frames = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(frames[1].maxY - frames[0].maxY, 120, accuracy: 0.5,
                       "the layout offset places the page; the stale screen rect is not needed")

        // A changed offset moves the page; a native report without layout
        // information keeps the registered offset.
        coordinator.registerAnchor(
            id: .module(.memory),
            screenRect: NSRect(x: -5_000, y: -5_100, width: 288, height: 106),
            contentKind: "memory",
            layoutOffset: 300
        )
        var moved = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(moved[1].maxY - moved[0].maxY, 300, accuracy: 0.5)
        coordinator.registerAnchor(
            id: .module(.memory),
            screenRect: NSRect(x: -5_000, y: -5_200, width: 288, height: 106),
            contentKind: "memory"
        )
        XCTAssertEqual(coordinator.anchorRegistry.snapshot(for: .module(.memory))?.layoutOffset, 300)
        moved = session.visibleAttachedContentFramesForTesting
        XCTAssertEqual(moved[1].maxY - moved[0].maxY, 300, accuracy: 0.5)
    }

    // MARK: - Helpers

    @MainActor
    private struct Harness {
        let session: MenuBarPanelSession
        let coordinator: GeekPanelCoordinator
        let hook: LayoutHookModel
        let screen: NSScreen
        let anchor: NSRect
        let defaults: UserDefaults
        let suiteName: String

        func tearDown() {
            hook.action = nil
            session.teardown()
            TestPreferenceDomain.cleanup(suiteName: suiteName)
        }
    }

    private func makeHarness() throws -> Harness {
        let screen = try XCTUnwrap(NSScreen.screens.first, "Tests require an attached screen")
        let suiteName = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        let coordinator = GeekPanelCoordinator()
        let hook = LayoutHookModel()
        let panel = MenuBarStatusPanel(contentRect: .zero)
        panel.isReleasedWhenClosed = false
        let session = MenuBarPanelSession(
            panel: panel,
            rootView: AnyView(LayoutHook(model: hook).frame(maxWidth: .infinity, maxHeight: .infinity)),
            initialDensity: .geek,
            geometryStore: PanelGeometryStore(defaults: defaults),
            panelSettingsState: MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults),
            panelCoordinator: coordinator,
            pointerLocationProvider: { NSPoint(x: -10_000, y: -10_000) },
            applicationIsActiveProvider: { true },
            onClose: {}
        )
        let visible = screen.visibleFrame
        return Harness(
            session: session, coordinator: coordinator, hook: hook, screen: screen,
            anchor: NSRect(x: visible.midX - 12, y: visible.maxY - 24, width: 24, height: 20),
            defaults: defaults, suiteName: suiteName
        )
    }

    private func settle(turns: Int = 3) async {
        for _ in 0..<turns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func eventually(attempts: Int = 150, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Runs an action from the geometry passes AppKit performs inside the
/// session's `setFrame(display: true)`: the view update that measures and
/// forwards geometry in the live panel.
@MainActor
private final class LayoutHookModel {
    var action: (() -> Void)?
}

@MainActor
private final class LayoutHookView: NSView {
    weak var model: LayoutHookModel?

    override func layout() {
        super.layout()
        model?.action?()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        model?.action?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        model?.action?()
    }
}

private struct LayoutHook: NSViewRepresentable {
    let model: LayoutHookModel

    func makeNSView(context: Context) -> LayoutHookView {
        let view = LayoutHookView(frame: .zero)
        view.model = model
        return view
    }

    func updateNSView(_ nsView: LayoutHookView, context: Context) {}
}

/// Two production level-one wrappers in the overview's anchor space.
private struct OverviewCards: View {
    var body: some View {
        VStack(spacing: 6) {
            GeekOverviewModuleButton(destination: .processor, action: { _ in }) {
                GeekCombinedCard(height: 106) { Color.clear.frame(width: 1, height: 1) }
            }
            GeekOverviewHoverRegion(destination: .sensors, preview: { _ in }) {
                GeekCombinedCard(height: 108) { Color.clear.frame(width: 1, height: 1) }
            }
        }
        .padding(8)
        .frame(width: 304, height: 700, alignment: .top)
        .coordinateSpace(name: GeekOverviewAnchorSpace.name)
    }
}
