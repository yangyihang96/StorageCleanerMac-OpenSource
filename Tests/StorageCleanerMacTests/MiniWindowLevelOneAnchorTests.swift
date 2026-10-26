import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Review P1 of batch 2b: a secondary page opens with its top edge on the top
/// edge of the level-one card it belongs to, so the registered anchor of each
/// level-one card must be that card's frame, also after the card moved.
@MainActor
final class MiniWindowLevelOneAnchorTests: XCTestCase {
    // D118 (old values: 8, 120, 248, 332, 419, 533): the 8 pt inset, then
    // iStat's cards of 120, 112, 42, 100 and 88 pt, 7 pt apart.
    private static let cardTops: [(PanelSection, CGFloat)] = [
        (.processor, 8), (.memory, 135), (.disk, 254), (.network, 303), (.sensors, 410), (.power, 505),
    ]

    func testCardAnchorsFollowAMoveInsideTheWindow() async throws {
        let coordinator = GeekPanelCoordinator()
        let model = MoveModel()
        let window = makeWindow(
            content: MovableCards(model: model).environment(\.geekPanelHoverCoordinator, coordinator),
            frame: NSRect(x: 120, y: 120, width: 304, height: 700)
        )
        defer { window.close() }

        // The attached shell can first lay a recreated overview out lower in
        // the window and then move it; the card's size never changes.
        for top: CGFloat in [38.5, 0] {
            model.top = top
            let processorTop = window.frame.maxY - top - 8
            let sensorsTop = window.frame.maxY - top - 8 - 106 - 6
            // Layout lands on whole device pixels: the 38.5 pt move is exact
            // on a 2x screen and half a point off on a 1x screen. Allow less
            // than one pixel, which is the original 0.5 pt on 2x.
            let settled = await eventually {
                let pixel = self.devicePixel(of: window)
                return self.top(of: .processor, in: coordinator).map { abs($0 - processorTop) < pixel } == true
                    && self.top(of: .sensors, in: coordinator).map { abs($0 - sensorsTop) < pixel } == true
            }
            XCTAssertTrue(settled, "Anchors must follow the cards to top \(top): "
                + "CPU \(String(describing: self.top(of: .processor, in: coordinator))) expected \(processorTop), "
                + "sensors \(String(describing: self.top(of: .sensors, in: coordinator))) expected \(sensorsTop), "
                + "pixel \(devicePixel(of: window)) pt")
        }
    }

    func testAttachedAnchorIsTheCardLayoutFrameOnTheCascadeOverviewFrame() async throws {
        XCTAssertEqual(
            GeekModuleAnchorGeometry.screenRect(
                layoutFrame: CGRect(x: 8, y: 8, width: 288, height: 106),
                overviewScreenFrame: NSRect(x: 700, y: 220, width: 304, height: 605)
            ),
            NSRect(x: 708, y: 711, width: 288, height: 106)
        )

        let coordinator = GeekPanelCoordinator()
        let model = MoveModel()
        // The window is deliberately elsewhere: an attached card is placed on
        // the session's overview frame, wherever a transient layout draws it.
        var overviewFrame = NSRect(x: 700, y: 220, width: 304, height: 605)
        model.placement = .attached(overviewScreenFrame: overviewFrame)
        let window = makeWindow(
            content: MovableCards(model: model).environment(\.geekPanelHoverCoordinator, coordinator),
            frame: NSRect(x: 60, y: 90, width: 304, height: 700)
        )
        defer { window.close() }

        for (top, overviewShift): (CGFloat, CGFloat) in [(0, 0), (38.5, 0), (0, 50)] {
            overviewFrame.origin.y += overviewShift
            model.placement = .attached(overviewScreenFrame: overviewFrame)
            model.top = top
            let expected = NSRect(x: overviewFrame.minX + 8, y: overviewFrame.maxY - 8 - 106, width: 288, height: 106)
            let placed = await eventually {
                self.rect(of: .processor, in: coordinator)?.isApproximatelyEqual(to: expected) == true
            }
            XCTAssertTrue(placed, "drawn \(top) pt lower, overview frame \(overviewFrame): CPU anchor "
                + "\(String(describing: self.rect(of: .processor, in: coordinator))) expected \(expected)")
            let sensors = NSRect(x: overviewFrame.minX + 8, y: overviewFrame.maxY - 8 - 106 - 6 - 108, width: 288, height: 108)
            XCTAssertTrue(self.rect(of: .sensors, in: coordinator)?.isApproximatelyEqual(to: sensors) == true,
                          "sensors anchor \(String(describing: self.rect(of: .sensors, in: coordinator))) expected \(sensors)")
        }

        // Before the cascade layout reaches the view, the previous anchor stays.
        let before = coordinator.anchorRegistry.snapshot(for: .module(.processor))?.screenRect
        model.placement = .attached(overviewScreenFrame: nil)
        model.top = 77
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(coordinator.anchorRegistry.snapshot(for: .module(.processor))?.screenRect, before)
    }

    /// End to end with the real session and attached shell. The cascade
    /// layout reaches the view after the session has placed the window (late
    /// delivery stands in for the slower Debug build the P1 was captured
    /// with); the CPU secondary must still line up with its card.
    /// D123 (2026-10-19): renamed from
    /// `testProcessorSecondaryOpensAtItsCardTopWhenTheCascadeArrivesLate`;
    /// the page now opens 8 pt above the card so their first cards line up.
    func testProcessorSecondaryLinesUpWithItsCardWhenTheCascadeArrivesLate() async throws {
        for delay: Duration in [.zero, .milliseconds(150)] {
            try await assertProcessorSecondaryAlignment(cascadeDelay: delay)
        }
    }

    private func assertProcessorSecondaryAlignment(cascadeDelay: Duration) async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "Tests require an attached screen")
        let suiteName = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        defer { TestPreferenceDomain.cleanup(suiteName: suiteName) }
        let settings = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        let coordinator = GeekPanelCoordinator()
        let host = AttachedHarnessModel()
        let panel = MenuBarStatusPanel(contentRect: .zero)
        panel.isReleasedWhenClosed = false
        let session = MenuBarPanelSession(
            panel: panel,
            rootView: AnyView(AttachedHarnessRoot(
                settings: settings, coordinator: coordinator, host: host, cascadeDelay: cascadeDelay
            )),
            initialDensity: .geek,
            initialOverviewSize: GeekPanelLayout.overviewSize(showsPowerModule: true),
            geometryStore: PanelGeometryStore(defaults: defaults),
            panelSettingsState: settings,
            panelCoordinator: coordinator,
            pointerLocationProvider: { NSPoint(x: -10_000, y: -10_000) },
            applicationIsActiveProvider: { true },
            onClose: {}
        )
        host.session = session
        defer { session.teardown() }
        let visible = screen.visibleFrame
        session.show(
            anchor: NSRect(x: visible.midX - 12, y: visible.maxY - 24, width: 24, height: 20),
            screen: screen,
            density: .geek
        )
        let overviewReady = await eventually {
            self.top(of: .processor, in: coordinator).map { abs(panel.frame.maxY - $0 - 8) < 0.5 } == true
        }
        XCTAssertTrue(overviewReady, "delay \(cascadeDelay): overview anchors did not settle")

        coordinator.selectModule(.processor)
        // A wrong anchor shows up only after the recreated cards reported,
        // so judge the settled cascade rather than the first placement.
        try await Task.sleep(for: .milliseconds(1_200))
        var lastFrames: [NSRect] = []
        let aligned = await eventually(attempts: 300) {
            let frames = session.visibleAttachedContentFramesForTesting
            lastFrames = frames
            guard frames.count >= 2 else { return false }
            // D123 (2026-10-19): 8 pt above the CPU card's top, level with
            // the overview top (was the card's top, 8 pt below it).
            return abs(frames[1].maxY - frames[0].maxY) < 0.5
        }
        XCTAssertTrue(aligned, "delay \(cascadeDelay): CPU secondary top must be 8 pt above the CPU card's top "
            + "(level with the overview top); frames \(lastFrames)")
        try await Task.sleep(for: .milliseconds(300))
        let frames = session.visibleAttachedContentFramesForTesting
        guard frames.count >= 2 else { return }
        XCTAssertEqual(frames[1].maxY - frames[0].maxY, 0, accuracy: 0.5,
                       "delay \(cascadeDelay): the aligned cascade must stay aligned (D123: was 8)")
        let overview = frames[1]
        for (section, cardTop) in Self.cardTops {
            let registered = try XCTUnwrap(
                coordinator.anchorRegistry.snapshot(for: .module(section))?.screenRect,
                "delay \(cascadeDelay): \(section) has no anchor"
            )
            XCTAssertEqual(overview.maxY - registered.maxY, cardTop, accuracy: 0.5,
                           "delay \(cascadeDelay): \(section) anchor top")
        }
    }

    // MARK: - Helpers

    private func devicePixel(of window: NSWindow) -> CGFloat {
        1 / max(1, window.backingScaleFactor)
    }

    private func top(of section: PanelSection, in coordinator: GeekPanelCoordinator) -> CGFloat? {
        rect(of: section, in: coordinator)?.maxY
    }

    private func rect(of section: PanelSection, in coordinator: GeekPanelCoordinator) -> NSRect? {
        coordinator.anchorRegistry.snapshot(for: .module(section))?.screenRect
    }

    private func makeWindow<Content: View>(content: Content, frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        return window
    }

    private func eventually(attempts: Int = 150, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class MoveModel: ObservableObject {
    @Published var top: CGFloat = 0
    @Published var placement = GeekOverviewAnchorPlacement.overviewOnly
}

/// Two production level-one wrappers, moved by an offset as the attached
/// shell moves its overview column.
private struct MovableCards: View {
    @ObservedObject var model: MoveModel

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
        .environment(\.geekOverviewAnchorPlacement, model.placement)
        .offset(y: model.top)
        .frame(width: 304, height: 700, alignment: .topLeading)
    }
}

@MainActor
private final class AttachedHarnessModel {
    weak var session: MenuBarPanelSession?
}

/// The live panel's structure around the level-one anchors: the overview
/// alone in a PanelShell, then the overview recreated (cards are keyed by the
/// selected page) beside a CPU page in the real GeekAttachedPanelShell.
private struct AttachedHarnessRoot: View {
    @ObservedObject var settings: MenuBarPanelSettingsState
    @ObservedObject var coordinator: GeekPanelCoordinator
    let host: AttachedHarnessModel
    let cascadeDelay: Duration
    @State private var overviewSize = GeekPanelPresentationMetrics.overviewSize
    @State private var measuredDetail: CGSize?
    @State private var deliveredCascade: MenuBarCascadeLayout?

    private var cascade: MenuBarCascadeLayout? {
        cascadeDelay == .zero ? settings.cascadeLayout : deliveredCascade
    }

    private var placement: GeekOverviewAnchorPlacement {
        guard coordinator.selectedSection != .overview else { return .overviewOnly }
        guard let cascade, !cascade.isCompact else { return .attached(overviewScreenFrame: nil) }
        return .attached(overviewScreenFrame: cascade.parentFrame)
    }

    private var overview: some View {
        VStack(spacing: GeekPanelLayout.sectionSpacing) {
            card(.processor, height: GeekPanelLayout.overviewProcessorCardHeight)
            card(.memory, height: GeekPanelLayout.overviewMemoryCardHeight)
            card(.disk, height: GeekPanelLayout.overviewDiskCardHeight)
            card(.network, height: GeekPanelLayout.overviewNetworkCardHeight)
            GeekOverviewHoverRegion(destination: .sensors, preview: { _ in }) {
                GeekCombinedCard(height: GeekPanelLayout.overviewSensorsCardHeight) { Color.clear.frame(width: 1, height: 1) }
            }
            card(.power, height: GeekPanelLayout.overviewPowerCardHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(GeekPanelLayout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: GeekOverviewAnchorSpace.name)
        .environment(\.geekOverviewAnchorPlacement, placement)
        .id(coordinator.selectedSection)
        .onAppear {
            overviewSize = GeekPanelLayout.overviewSize(showsPowerModule: true)
            host.session?.setOverviewSize(overviewSize)
        }
    }

    private func card(_ section: PanelSection, height: CGFloat) -> some View {
        GeekOverviewModuleButton(destination: section, action: { coordinator.selectModule($0) }) {
            GeekCombinedCard(height: height) { Color.clear.frame(width: 1, height: 1) }
        }
    }

    private var detail: some View {
        // The CPU page is taller than the overview (630 pt in the capture),
        // which is what bottom-aligns the overview in the default frames.
        GeekCombinedCard(height: 630 - 2 * GeekPanelLayout.contentPadding) { Color.clear.frame(width: 1, height: 1) }
            .padding(GeekPanelLayout.contentPadding)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size, initial: true) {
                        let size = proxy.size
                        Task { @MainActor in
                            measuredDetail = size
                            host.session?.setDetailSize(size)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var body: some View {
        Group {
            if coordinator.selectedSection == .overview {
                PanelShell(density: .geek, preferredSize: overviewSize, showsHeader: false, showsNavigation: false) {
                    EmptyView()
                } navigation: {
                    EmptyView()
                } content: {
                    overview
                }
            } else {
                GeekAttachedPanelShell(
                    section: coordinator.selectedSection,
                    density: .geek,
                    overviewSize: overviewSize,
                    direction: settings.cascadeDirection,
                    presentationMode: settings.secondaryPresentationMode,
                    tertiaryPresentationMode: settings.tertiaryPresentationMode,
                    cascadeLayout: cascade,
                    detailPreferredSize: GeekPanelPresentationMetrics.normalizedDetailSize(
                        measuredDetail, for: coordinator.selectedSection, density: .geek),
                    showsTertiary: false,
                    tertiaryPreferredSize: GeekPanelPresentationMetrics.tertiarySize,
                    tertiarySourceOffset: nil,
                    onHoverChange: { _, _ in }
                ) {
                    detail
                } overview: {
                    overview
                } tertiary: {
                    EmptyView()
                }
            }
        }
        .environment(\.geekPanelHoverCoordinator, coordinator)
        .onChange(of: settings.cascadeLayout) {
            let layout = settings.cascadeLayout
            let delay = cascadeDelay
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                deliveredCascade = layout
            }
        }
        .onChange(of: coordinator.selectedSection) {
            // MenuBarAdvancedStatusView forwards the section to the session
            // from the same update (through MenuBarStatusController).
            host.session?.setGeekSection(
                coordinator.selectedSection,
                preferredDetailSize: coordinator.selectedSection == .overview ? nil
                    : GeekPanelPresentationMetrics.normalizedDetailSize(
                        measuredDetail, for: coordinator.selectedSection, density: .geek)
            )
        }
    }
}
