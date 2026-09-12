import AppKit
import SwiftUI

#if DEBUG || STORAGE_CLEANER_BETA
@MainActor
private func logControlPaletteEvent(_ event: String) {
    PerformanceTelemetry.logger.notice("ControlPaletteTrace \(event, privacy: .public)")
}
#endif

enum ControlPaletteKind: Equatable, Sendable {
    case fan
    case power
    case networkConnection
    case none
}

enum ConnectionInspectorPresentationState: Equatable, Sendable {
    case closed
    case pendingOpen
    case open
    case pendingClose
}

enum FanControlPalettePage: Equatable, Sendable {
    case controls
    case curveEditor
}

@MainActor
final class ControlPalettePresentationState: ObservableObject {
    @Published private(set) var kind = ControlPaletteKind.none
    @Published private(set) var fanPage = FanControlPalettePage.controls
    @Published private(set) var fanControlsExpanded: Bool?
    @Published private(set) var selectedFanIndex: Int?
    var interactionDidBegin: (() -> Void)?

    func focusFan(_ index: Int?) { selectedFanIndex = index }
    func beginInteraction() { interactionDidBegin?() }
    private(set) var measuredContentWidth: CGFloat?
    private(set) var measuredContentHeight: CGFloat?

    fileprivate var presentationDidChange: (() -> Void)?

    func present(_ kind: ControlPaletteKind) {
        if self.kind != kind {
            measuredContentWidth = nil
            measuredContentHeight = nil
        }
        self.kind = kind
        if kind != .fan {
            fanPage = .controls
        }
        presentationDidChange?()
    }

    func showFanControls() {
        guard kind == .fan else { return }
        guard fanPage != .controls else { return }
        fanPage = .controls
        measuredContentWidth = nil
        measuredContentHeight = nil
        presentationDidChange?()
    }

    func showFanCurveEditor() {
        guard kind == .fan else { return }
        guard fanPage != .curveEditor else { return }
        fanPage = .curveEditor
        measuredContentWidth = nil
        measuredContentHeight = nil
        presentationDidChange?()
    }

    func setFanControlsExpanded(_ expanded: Bool) {
        guard kind == .fan, fanControlsExpanded != expanded else { return }
        fanControlsExpanded = expanded
    }

    func reportMeasuredContentSize(_ size: CGSize) {
        guard size.width.isFinite, size.width > 0,
              size.height.isFinite, size.height > 0 else { return }
        guard (measuredContentHeight.map({ abs($0 - size.height) > 0.5 }) ?? true)
            || (measuredContentWidth.map({ abs($0 - size.width) > 0.5 }) ?? true) else {
            return
        }
        measuredContentWidth = size.width
        measuredContentHeight = size.height
#if DEBUG || STORAGE_CLEANER_BETA
        logControlPaletteEvent("content-size kind=\(kind) page=\(fanPage) width=\(size.width) height=\(size.height)")
#endif
        presentationDidChange?()
    }

    fileprivate func dismiss() {
        kind = .none
        fanPage = .controls
        fanControlsExpanded = nil
        measuredContentWidth = nil
        measuredContentHeight = nil
    }
}

enum ControlPaletteMetrics {
    static let gap: CGFloat = 4
    static let connectionGap: CGFloat = MiniWindowStyleTokens.cascadeGap
    static let fanSize = CGSize(width: 280, height: 340)
    static let fanCurveSize = CGSize(width: 354, height: 410)
    static let powerSize = CGSize(width: 280, height: 240)
    static let networkConnectionSize = CGSize(width: 271, height: 435)

    static func size(
        kind: ControlPaletteKind,
        fanPage: FanControlPalettePage
    ) -> CGSize {
        switch kind {
        case .fan:
            fanPage == .curveEditor ? fanCurveSize : fanSize
        case .power:
            powerSize
        case .networkConnection:
            networkConnectionSize
        case .none:
            .zero
        }
    }
}

enum ControlPalettePlacementPreference {
    case automatic
    case leftThenRight
}

enum ControlPalettePlacement {
    static func decision(
        anchor: NSRect,
        size: CGSize,
        visibleFrame: NSRect,
        gap: CGFloat = ControlPaletteMetrics.gap,
        preference: ControlPalettePlacementPreference = .automatic,
        previousEdge: SmallWindowPlacementEdge? = nil,
        avoidFrames: [NSRect] = [],
        pointerLocation: NSPoint? = nil,
        backingScaleFactor: CGFloat = 1
    ) -> SmallWindowPlacementDecision {
        let edges: [SmallWindowPlacementEdge] = preference == .leftThenRight
            ? [.left, .right]
            : [.below, .left, .right, .above]
        return MenuBarPanelPlacement.detachedPanel(
            anchor: anchor,
            size: size,
            visibleFrame: visibleFrame,
            preferredEdges: edges,
            previousEdge: previousEdge.flatMap { edges.contains($0) ? $0 : nil },
            gap: gap,
            avoidFrames: avoidFrames,
            pointerLocation: pointerLocation,
            backingScaleFactor: backingScaleFactor
        )
    }

    static func frame(
        anchor: NSRect,
        size: CGSize,
        visibleFrame: NSRect,
        gap: CGFloat = ControlPaletteMetrics.gap,
        preference: ControlPalettePlacementPreference = .automatic
    ) -> NSRect {
        decision(
            anchor: anchor,
            size: size,
            visibleFrame: visibleFrame,
            gap: gap,
            preference: preference
        ).frame
    }
}

final class ControlPalettePanel: NSPanel {
    var onPointerPresenceChanged: ((Bool) -> Void)?
    var onPointerLocationChanged: ((NSPoint) -> Void)?
    private let pointerTrackingView = MenuBarPanelPointerTrackingView()

    init(contentRect: NSRect = .zero) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [
            .moveToActiveSpace,
            .ignoresCycle,
            .fullScreenAuxiliary,
            .canJoinAllApplications,
        ]
        title = L10n.text("硬件控制浮层", "Hardware Control Palette")
        setAccessibilityLabel(title)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isMovable = false
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func installPointerTracking() {
        guard let contentView,
              let container = contentView.superview,
              pointerTrackingView.superview !== container else { return }
        pointerTrackingView.removeFromSuperview()
        pointerTrackingView.frame = contentView.frame
        pointerTrackingView.autoresizingMask = [.width, .height]
        pointerTrackingView.onPointerPresenceChanged = { [weak self] inside in
            self?.onPointerPresenceChanged?(inside)
        }
        pointerTrackingView.onPointerLocationChanged = { [weak self] point in
            self?.onPointerLocationChanged?(point)
        }
        container.addSubview(pointerTrackingView, positioned: .above, relativeTo: contentView)
    }
}

@MainActor
final class ControlPaletteCoordinator: NSObject, NSWindowDelegate {
    let panel: ControlPalettePanel
    let state: ControlPalettePresentationState

    private var hostingView: NSHostingView<AnyView>?
    private weak var parentWindow: NSWindow?
    private var anchorInParent = NSRect.zero
    private let fixedVisibleFrame: NSRect?
    private let presentsPanelOnShow: Bool
    private let inspectorOpenDelay: Duration
    private let inspectorCloseDelay: Duration
    private let hoverIntentController: HoverIntentController
    private let pointerLocationProvider: @MainActor () -> NSPoint
    private var pendingOpenRequest: HoverIntentController.Request?
    private var pendingCloseRequest: HoverIntentController.Request?
    private var isPinned = false
    private var lastPlacementEdge: SmallWindowPlacementEdge?
    private(set) var presentationCount = 0
    private(set) var connectionInspectorState = ConnectionInspectorPresentationState.closed
    private(set) var isPointerInsideAnchor = false
    private(set) var isPointerInsideInspector = false
    private var hoveredKind: ControlPaletteKind?
    private var placementAnchorScreenRect: NSRect?
    private var parentFrameAtPlacementUpdate: NSRect?
    private var isApplyingProgrammaticFrame = false
    private var needsRepositionAfterFrameUpdate = false
    var willPresent: ((ControlPaletteKind) -> Void)?
    var didDismiss: (() -> Void)?
    /// Forwards pointer motion inside the palette to the owning session so
    /// the session's hover envelope stays alive while the palette is in use.
    var pointerLocationObserver: ((NSPoint) -> Void)?

    var isPresented: Bool {
        state.kind != .none && (panel.isVisible || !presentsPanelOnShow)
    }

    init(
        panel: ControlPalettePanel = ControlPalettePanel(),
        fixedVisibleFrame: NSRect? = nil,
        presentsPanelOnShow: Bool = true,
        inspectorOpenDelay: Duration = HoverIntentPolicy.menuBar.initialOpenDelay,
        inspectorCloseDelay: Duration = HoverIntentPolicy.menuBar.ordinaryCloseDelay,
        hoverIntentController: HoverIntentController = HoverIntentController(),
        pointerLocationProvider: @escaping @MainActor () -> NSPoint = {
            NSEvent.mouseLocation
        },
        content: (ControlPalettePresentationState) -> AnyView
    ) {
        self.panel = panel
        self.fixedVisibleFrame = fixedVisibleFrame
        self.presentsPanelOnShow = presentsPanelOnShow
        self.inspectorOpenDelay = inspectorOpenDelay
        self.inspectorCloseDelay = inspectorCloseDelay
        self.hoverIntentController = hoverIntentController
        self.pointerLocationProvider = pointerLocationProvider
        let state = ControlPalettePresentationState()
        self.state = state
        super.init()
        state.interactionDidBegin = { [weak self] in
            self?.isPinned = true
            self?.cancelPendingClose()
        }

        // Own the actual hosting view: NSHostingController may wrap its root
        // in a different generic hosting view, making the old conditional cast
        // silently skip this setting. Only the coordinator may resize a palette.
        let hostingView = NSHostingView(rootView: content(state))
        hostingView.sizingOptions = []
        self.hostingView = hostingView
        panel.contentView = hostingView
        panel.delegate = self
        panel.installPointerTracking()
        panel.onPointerPresenceChanged = { [weak self] inside in
            Task { @MainActor [weak self] in
                self?.inspectorPointerChanged(inside)
            }
        }
        panel.onPointerLocationChanged = { [weak self] point in
            self?.hoverIntentController.recordPointer(point)
            self?.pointerLocationObserver?(point)
        }
        state.presentationDidChange = { [weak self] in
            self?.presentationDidChange()
        }
    }

    convenience init(
        fixedVisibleFrame: NSRect? = nil,
        presentsPanelOnShow: Bool = true,
        inspectorOpenDelay: Duration = HoverIntentPolicy.menuBar.initialOpenDelay,
        inspectorCloseDelay: Duration = HoverIntentPolicy.menuBar.ordinaryCloseDelay,
        hoverIntentController: HoverIntentController = HoverIntentController(),
        pointerLocationProvider: @escaping @MainActor () -> NSPoint = {
            NSEvent.mouseLocation
        }
    ) {
        self.init(
            fixedVisibleFrame: fixedVisibleFrame,
            presentsPanelOnShow: presentsPanelOnShow,
            inspectorOpenDelay: inspectorOpenDelay,
            inspectorCloseDelay: inspectorCloseDelay,
            hoverIntentController: hoverIntentController,
            pointerLocationProvider: pointerLocationProvider,
            content: { _ in AnyView(EmptyView()) }
        )
    }

    func toggle(
        _ kind: ControlPaletteKind,
        anchorScreenRect: NSRect,
        parentWindow: NSWindow
    ) {
#if DEBUG || STORAGE_CLEANER_BETA
        logControlPaletteEvent("toggle kind=\(kind) presented=\(isPresented) pinned=\(isPinned) anchor=\(NSStringFromRect(anchorScreenRect)) parent=\(parentWindow.windowNumber)")
#endif
        guard kind != .none else {
            dismiss(reason: "toggle-none")
            return
        }
        if isPresented, state.kind == kind {
            if supportsHoverPresentation(kind), !isPinned {
                isPinned = true
                cancelPendingClose()
                if kind == .networkConnection {
                    connectionInspectorState = .open
                }
                return
            }
            dismiss(reason: "toggle-existing-pinned")
            return
        }

        present(
            kind,
            anchorScreenRect: anchorScreenRect,
            parentWindow: parentWindow,
            pinned: true
        )
    }

    func beginHover(
        _ kind: ControlPaletteKind,
        anchorScreenRect: NSRect,
        parentWindow: NSWindow
    ) {
        guard supportsHoverPresentation(kind) else { return }
        hoveredKind = kind
        isPointerInsideAnchor = true
        cancelPendingClose()
        self.parentWindow = parentWindow
        anchorInParent = parentWindow.convertFromScreen(anchorScreenRect)
        if placementAnchorScreenRect == nil {
            placementAnchorScreenRect = parentWindow.frame
        }

        if isPresented, state.kind == kind {
            if kind == .networkConnection {
                connectionInspectorState = .open
            }
            reposition()
            return
        }

        cancelPendingOpen()
        if kind == .networkConnection {
            connectionInspectorState = .pendingOpen
        }
        PerformanceTelemetry.signposter.emitEvent("InspectorPendingOpen")
        pendingOpenRequest = hoverIntentController.scheduleOpen(
            anchorID: anchorID(for: kind),
            panelRole: hoverPanelRole(for: kind),
            delay: inspectorOpenDelay,
            condition: { [weak self] in
                self?.isPointerInsideAnchor == true
                    && self?.parentWindow != nil
            },
            action: { [weak self] in
                guard let self, let parentWindow = self.parentWindow else { return }
                pendingOpenRequest = nil
                present(
                    kind,
                    anchorScreenRect: currentAnchorScreenRect,
                    parentWindow: parentWindow,
                    pinned: false
                )
            }
        )
    }

    func endHover(_ kind: ControlPaletteKind) {
        guard supportsHoverPresentation(kind), hoveredKind == kind else { return }
        hoveredKind = nil
        isPointerInsideAnchor = false
        cancelPendingOpen()
        if !isPresented {
            parentWindow = nil
            anchorInParent = .zero
            placementAnchorScreenRect = nil
        }
        scheduleInspectorDismissIfNeeded()
    }

    private func present(
        _ kind: ControlPaletteKind,
        anchorScreenRect: NSRect,
        parentWindow: NSWindow,
        pinned: Bool
    ) {
#if DEBUG || STORAGE_CLEANER_BETA
        logControlPaletteEvent("present-begin kind=\(kind) pinned=\(pinned) anchorValid=\(anchorScreenRect.isUsableWindowAnchor) anchor=\(NSStringFromRect(anchorScreenRect)) parent=\(parentWindow.windowNumber)")
#endif
        cancelPendingOpen()
        cancelPendingClose()
        willPresent?(kind)

        let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
        let interval = PerformanceTelemetry.signposter.beginInterval(
            "ControlPaletteOpen",
            id: signpostID
        )
        defer {
            PerformanceTelemetry.signposter.endInterval(
                "ControlPaletteOpen",
                interval
            )
        }

        bind(to: parentWindow)
        anchorInParent = parentWindow.convertFromScreen(anchorScreenRect)
        if placementAnchorScreenRect == nil {
            placementAnchorScreenRect = parentWindow.frame
        }
        if state.kind != kind {
            lastPlacementEdge = nil
        }
        isPinned = pinned
        panel.title = kind == .networkConnection
            ? L10n.text("连接详情面板", "Connection Details Inspector")
            : L10n.text("硬件控制浮层", "Hardware Control Palette")
        panel.setAccessibilityLabel(panel.title)
        state.present(kind)
        hoverIntentController.markOpen(
            anchorID: anchorID(for: kind),
            panelRole: kind == .networkConnection ? .hoverInspector : .controlPalette
        )
        connectionInspectorState = kind == .networkConnection ? .open : .closed
        presentationCount += 1
        reposition()
        if presentsPanelOnShow {
            panel.installPointerTracking()
#if DEBUG || STORAGE_CLEANER_BETA
            logControlPaletteEvent("orderFront-before kind=\(kind) frame=\(NSStringFromRect(panel.frame)) visible=\(panel.isVisible) window=\(panel.windowNumber)")
#endif
            panel.orderFront(nil)
#if DEBUG || STORAGE_CLEANER_BETA
            logControlPaletteEvent("orderFront-after kind=\(kind) frame=\(NSStringFromRect(panel.frame)) visible=\(panel.isVisible) window=\(panel.windowNumber)")
#endif
        }
        if kind == .networkConnection {
            PerformanceTelemetry.signposter.emitEvent("InspectorOpened")
        }
    }

    func dismiss(reason: String = #function) {
#if DEBUG || STORAGE_CLEANER_BETA
        logControlPaletteEvent("dismiss reason=\(reason) kind=\(state.kind) visible=\(panel.isVisible) pinned=\(isPinned) frame=\(NSStringFromRect(panel.frame))")
#endif
        let wasConnectionInspector = state.kind == .networkConnection
            || connectionInspectorState != .closed
        let dismissedKind = state.kind
        cancelPendingOpen()
        cancelPendingClose()
        guard state.kind != .none || panel.isVisible || wasConnectionInspector else { return }
        panel.orderOut(nil)
        if let parentWindow, panel.parent === parentWindow {
            parentWindow.removeChildWindow(panel)
        }
        parentWindow = nil
        anchorInParent = .zero
        placementAnchorScreenRect = nil
        parentFrameAtPlacementUpdate = nil
        lastPlacementEdge = nil
        isPinned = false
        hoveredKind = nil
        isPointerInsideAnchor = false
        isPointerInsideInspector = false
        connectionInspectorState = .closed
        state.dismiss()
        if dismissedKind != .none {
            hoverIntentController.markClosed(
                ifOwnedBy: anchorID(for: dismissedKind),
                panelRole: hoverPanelRole(for: dismissedKind)
            )
        }
        if wasConnectionInspector {
            PerformanceTelemetry.signposter.emitEvent("InspectorClosed")
        }
        didDismiss?()
    }

    @discardableResult
    func handleEscape(sourceWindow: NSWindow?) -> Bool {
        guard isPresented,
              sourceWindow === panel || sourceWindow === parentWindow else {
            return false
        }
        dismiss(reason: "escape")
        return true
    }

    /// Returns true when this click dismissed only the palette and the parent
    /// session should remain open.
    @discardableResult
    func handleMouseDown(
        sourceWindow: NSWindow?,
        screenLocation: NSPoint
    ) -> Bool {
        guard isPresented else { return false }
        if sourceWindow === panel || panel.frame.contains(screenLocation) {
            return false
        }
        if currentAnchorScreenRect.contains(screenLocation) {
            return false
        }
        dismiss(reason: "mouse-down-outside")
        return true
    }

    func parentWindowDidMove() {
        guard isPresented else { return }
        if let parentWindow {
            let referenceFrame = parentFrameAtPlacementUpdate ?? placementAnchorScreenRect
            guard let placementAnchorScreenRect,
                  let referenceFrame else {
                reposition()
                return
            }
            self.placementAnchorScreenRect = placementAnchorScreenRect.offsetBy(
                dx: parentWindow.frame.minX - referenceFrame.minX,
                dy: parentWindow.frame.minY - referenceFrame.minY
            )
            self.parentFrameAtPlacementUpdate = parentWindow.frame
        }
        reposition()
    }

    private func inspectorPointerChanged(_ inside: Bool) {
        guard supportsHoverPresentation(state.kind) else { return }
        isPointerInsideInspector = inside
        if inside {
            cancelPendingClose()
            if state.kind == .networkConnection {
                connectionInspectorState = .open
            }
        } else {
            scheduleInspectorDismissIfNeeded()
        }
    }

    private func scheduleInspectorDismissIfNeeded() {
        guard supportsHoverPresentation(state.kind),
              isPresented,
              !isPinned,
              !isPointerInsideAnchor,
              !isPointerInsideInspector else { return }
        cancelPendingClose()
        if state.kind == .networkConnection {
            connectionInspectorState = .pendingClose
        }
        let pointer = pointerLocationProvider()
        hoverIntentController.recordPointer(pointer)
        hoverIntentController.updateWindowGroupFrames([currentAnchorScreenRect, panel.frame])
        pendingCloseRequest = hoverIntentController.scheduleClose(
            delay: hoverIntentController.recommendedCloseDelay(
                ordinaryDelay: inspectorCloseDelay
            ),
            condition: { [weak self] in
                guard let self,
                      !isPinned,
                      !isPointerInsideAnchor,
                      !isPointerInsideInspector else { return false }
                return true
            },
            action: { [weak self] in
                guard let self else { return }
                pendingCloseRequest = nil
                if hoverEnvelopeContains(pointerLocationProvider()) {
                    if state.kind == .networkConnection {
                        connectionInspectorState = .open
                    }
                    hoverIntentController.markOpen(
                        anchorID: anchorID(for: state.kind),
                        panelRole: hoverPanelRole(for: state.kind)
                    )
                    scheduleInspectorDismissIfNeeded()
                } else {
                    dismiss(reason: "hover-envelope-exit")
                }
            }
        )
    }

    private func cancelPendingOpen() {
        if let pendingOpenRequest {
            hoverIntentController.cancel(pendingOpenRequest)
            self.pendingOpenRequest = nil
        }
        if connectionInspectorState == .pendingOpen {
            connectionInspectorState = .closed
        }
    }

    private func cancelPendingClose() {
        if let pendingCloseRequest {
            hoverIntentController.cancel(pendingCloseRequest)
            self.pendingCloseRequest = nil
        }
        if connectionInspectorState == .pendingClose {
            connectionInspectorState = state.kind == .networkConnection ? .open : .closed
        }
    }

    private func hoverEnvelopeContains(_ point: NSPoint) -> Bool {
        let anchor = currentAnchorScreenRect
        if anchor.contains(point) || panel.frame.contains(point) { return true }
        return HoverCorridor(
            source: anchor,
            destination: panel.frame,
            padding: hoverIntentController.policy.corridorPadding
        ).contains(point)
    }

    /// True while a presented palette should keep the pointer's hover
    /// ownership: inside its anchor, inside the palette itself, or traveling
    /// through the corridor between them. Neighboring hover targets crossed
    /// mid-transit must not replace the palette in that envelope.
    func claimsHoverPointer() -> Bool {
        guard isPresented, state.kind != .none else { return false }
        return hoverEnvelopeContains(pointerLocationProvider())
    }

    private func anchorID(for kind: ControlPaletteKind) -> SmallWindowAnchorID {
        switch kind {
        case .fan: .fanControl
        case .power: .powerMode
        case .networkConnection: .networkConnection
        case .none: SmallWindowAnchorID(rawValue: "control.none")
        }
    }

    private func supportsHoverPresentation(_ kind: ControlPaletteKind) -> Bool {
        kind == .networkConnection || kind == .power || kind == .fan
    }

    private func hoverPanelRole(for kind: ControlPaletteKind) -> SmallWindowPanelRole {
        kind == .networkConnection ? .hoverInspector : .controlPalette
    }

    func teardown() {
        dismiss()
        willPresent = nil
        didDismiss = nil
        pointerLocationObserver = nil
        state.presentationDidChange = nil
        panel.onPointerPresenceChanged = nil
        panel.onPointerLocationChanged = nil
        panel.delegate = nil
        panel.contentViewController = nil
        panel.contentView = nil
        panel.close()
        hostingView = nil
    }

    private func bind(to parentWindow: NSWindow) {
        if let existingParent = self.parentWindow,
           existingParent !== parentWindow,
           panel.parent === existingParent {
            existingParent.removeChildWindow(panel)
        }
        self.parentWindow = parentWindow
        parentFrameAtPlacementUpdate = placementAnchorScreenRect == nil
            ? nil
            : parentWindow.frame
        panel.level = parentWindow.level
        if presentsPanelOnShow, panel.parent !== parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
    }

    private func presentationDidChange() {
        guard isPresented else { return }
        reposition()
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel,
              !isApplyingProgrammaticFrame,
              state.kind != .none else { return }
        // SwiftUI's native hosting layout can resize a visible panel without
        // delivering its PreferenceKey measurement. Reconcile the actual window
        // size, including expansion near the lower screen edge, before placement.
        let size = panel.contentRect(forFrameRect: panel.frame).size
#if DEBUG || STORAGE_CLEANER_BETA
        logControlPaletteEvent("native-resize kind=\(state.kind) size=\(NSStringFromSize(size)) frame=\(NSStringFromRect(panel.frame))")
#endif
        state.reportMeasuredContentSize(size)
        reposition()
    }

    func updatePlacementAnchor(_ rect: NSRect?) {
        placementAnchorScreenRect = rect
        parentFrameAtPlacementUpdate = rect == nil ? nil : parentWindow?.frame
        guard state.kind != .none else { return }
        reposition()
    }

    private func reposition() {
        guard !isApplyingProgrammaticFrame else {
            needsRepositionAfterFrameUpdate = true
            return
        }
        guard let parentWindow, state.kind != .none else {
#if DEBUG || STORAGE_CLEANER_BETA
            logControlPaletteEvent("reposition-skipped parentPresent=\(parentWindow != nil) kind=\(state.kind)")
#endif
            return
        }
        let fallbackSize = ControlPaletteMetrics.size(
            kind: state.kind,
            fanPage: state.fanPage
        )
        let size = CGSize(
            width: state.measuredContentWidth ?? fallbackSize.width,
            height: state.measuredContentHeight ?? fallbackSize.height
        )
        let sourceAnchor = currentAnchorScreenRect
        guard let screen = ScreenContextResolver.resolve(
            anchorWindowScreen: parentWindow.screen,
            anchorRect: sourceAnchor,
            pointerLocation: pointerLocationProvider()
        ) else {
#if DEBUG || STORAGE_CLEANER_BETA
            logControlPaletteEvent("reposition-no-screen anchor=\(NSStringFromRect(sourceAnchor))")
#endif
            return
        }
        let visibleFrame = fixedVisibleFrame ?? screen.visibleFrame
        let columnAnchor = placementAnchorScreenRect ?? parentWindow.frame
        let placementAnchor = NSRect(
            x: columnAnchor.minX,
            y: sourceAnchor.minY,
            width: columnAnchor.width,
            height: sourceAnchor.height
        )
        let decision = ControlPalettePlacement.decision(
            anchor: placementAnchor,
            size: size,
            visibleFrame: visibleFrame.insetBy(dx: 6, dy: 6),
            gap: state.kind == .networkConnection
                ? ControlPaletteMetrics.connectionGap
                : ControlPaletteMetrics.gap,
            preference: .leftThenRight,
            previousEdge: lastPlacementEdge,
            avoidFrames: [parentWindow.frame],
            pointerLocation: pointerLocationProvider(),
            backingScaleFactor: screen.backingScaleFactor
        )
        let frame = decision.frame
        if decision.flipped {
            PerformanceTelemetry.signposter.emitEvent("PlacementFlipped")
        }
        PerformanceTelemetry.signposter.emitEvent("PlacementCalculated")
        lastPlacementEdge = decision.edge
        isApplyingProgrammaticFrame = true
        defer {
            isApplyingProgrammaticFrame = false
            if needsRepositionAfterFrameUpdate {
                needsRepositionAfterFrameUpdate = false
                reposition()
            }
        }
        panel.contentMinSize = frame.size
        panel.contentMaxSize = frame.size
        guard !panel.frame.isApproximatelyEqual(to: frame) else { return }
#if DEBUG || STORAGE_CLEANER_BETA
        logControlPaletteEvent("reposition kind=\(state.kind) anchor=\(NSStringFromRect(sourceAnchor)) frame=\(NSStringFromRect(frame))")
#endif
        panel.setFrame(frame, display: true)
        PerformanceTelemetry.signposter.emitEvent("PanelRepositioned")
    }

    private var currentAnchorScreenRect: NSRect {
        guard let parentWindow else { return .zero }
        return parentWindow.convertToScreen(anchorInParent)
    }
}

private struct ControlPaletteCoordinatorKey: EnvironmentKey {
    static let defaultValue: ControlPaletteCoordinator? = nil
}

extension EnvironmentValues {
    var controlPaletteCoordinator: ControlPaletteCoordinator? {
        get { self[ControlPaletteCoordinatorKey.self] }
        set { self[ControlPaletteCoordinatorKey.self] = newValue }
    }
}

struct ControlPaletteAnchorButton<Label: View>: View {
    @Environment(\.controlPaletteCoordinator) private var coordinator

    let kind: ControlPaletteKind
    let accessibilityLabel: String
    @ViewBuilder let label: Label

    @State private var anchorHandle = SmallWindowAnchorHandle()

    init(
        kind: ControlPaletteKind,
        accessibilityLabel: String,
        @ViewBuilder label: () -> Label
    ) {
        self.kind = kind
        self.accessibilityLabel = accessibilityLabel
        self.label = label()
    }

    var body: some View {
        Button {
            let snapshot = anchorHandle.snapshot()
#if DEBUG || STORAGE_CLEANER_BETA
            logControlPaletteEvent("button-entry kind=\(kind) coordinator=\(coordinator != nil) anchorPresent=\(snapshot != nil) anchorValid=\(snapshot?.rect.isUsableWindowAnchor == true) frame=\(snapshot.map { NSStringFromRect($0.rect) } ?? "nil")")
#endif
            guard let snapshot else { return }
            coordinator?.toggle(
                kind,
                anchorScreenRect: snapshot.rect,
                parentWindow: snapshot.window
            )
        } label: {
            label
                .contentShape(Rectangle())
                .background(SmallWindowAnchorReader(handle: anchorHandle))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier(accessibilityLabel)
        .accessibilityHint(L10n.text(
            "打开附着式控制浮层",
            "Open the attached control palette"
        ))
    }
}

struct ControlPaletteHoverAnchor<Label: View>: View {
    @Environment(\.controlPaletteCoordinator) private var coordinator

    let kind: ControlPaletteKind
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let selectedFanIndex: Int?
    @ViewBuilder let label: Label

    @State private var anchorHandle = SmallWindowAnchorHandle()
    @State private var isHovered = false

    init(
        kind: ControlPaletteKind,
        accessibilityLabel: String,
        accessibilityIdentifier: String? = nil,
        selectedFanIndex: Int? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.selectedFanIndex = selectedFanIndex
        self.kind = kind
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier ?? accessibilityLabel
        self.label = label()
    }

    var body: some View {
        Button {
            let snapshot = anchorHandle.snapshot()
#if DEBUG || STORAGE_CLEANER_BETA
            logControlPaletteEvent("hover-button-entry kind=\(kind) coordinator=\(coordinator != nil) anchorPresent=\(snapshot != nil) anchorValid=\(snapshot?.rect.isUsableWindowAnchor == true) frame=\(snapshot.map { NSStringFromRect($0.rect) } ?? "nil")")
#endif
            guard let snapshot else { return }
            coordinator?.state.focusFan(selectedFanIndex)
            coordinator?.toggle(
                kind,
                anchorScreenRect: snapshot.rect,
                parentWindow: snapshot.window
            )
        } label: {
            label
                .contentShape(Rectangle())
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(isHovered ? 0.055 : 0))
                        .allowsHitTesting(false)
                }
                .background(SmallWindowAnchorReader(handle: anchorHandle))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hoverChanged(true)
            case .ended:
                hoverChanged(false)
            }
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityHint(L10n.text(
            "悬停或点按以显示附着式控制浮层",
            "Hover or press to show the attached control palette"
        ))
        .onDisappear {
            isHovered = false
            coordinator?.endHover(kind)
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        guard isHovered != hovering else { return }
        isHovered = hovering
        let snapshot = hovering ? anchorHandle.snapshot() : nil
#if DEBUG || STORAGE_CLEANER_BETA
        logControlPaletteEvent("hover-entry active=\(hovering) kind=\(kind) coordinator=\(coordinator != nil) anchorPresent=\(snapshot != nil) frame=\(snapshot.map { NSStringFromRect($0.rect) } ?? "nil")")
#endif
        if hovering, let snapshot {
            coordinator?.state.focusFan(selectedFanIndex)
            coordinator?.beginHover(
                kind,
                anchorScreenRect: snapshot.rect,
                parentWindow: snapshot.window
            )
        } else {
            coordinator?.endHover(kind)
        }
    }
}
