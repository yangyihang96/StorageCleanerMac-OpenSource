import AppKit
import SwiftUI

enum GeekPanelHistorySelection: Equatable {
    case builtIn(String)
    case inline(UUID)
}

enum GeekPanelRoute: Equatable {
    case summary
    case module(PanelSection)
    case history(module: PanelSection, selection: GeekPanelHistorySelection)
}

enum GeekHardwareDetailFocus: String, Equatable, Sendable {
    case monitoring
    case power
}

@MainActor
final class GeekPanelCoordinator: ObservableObject {
    struct HoverIntent: Equatable {
        fileprivate let request: HoverIntentController.Request
    }

    @Published private(set) var route: GeekPanelRoute {
        didSet {
            guard oldValue != route else { return }
            PerformanceTelemetry.panelInput("route", target: String(describing: route))
        }
    }
    @Published private(set) var isPointerWithinHoverEnvelope = false
    @Published private(set) var hardwareDetailFocus = GeekHardwareDetailFocus.monitoring
    private(set) var pinnedModule: PanelSection?
    private(set) var isHistoryPinned = false
    private(set) var isControlPalettePresented = false
    private var suppressesModuleAfterEscape = false
    private var moduleEscapePointerLocation: NSPoint?
    private var moduleEscapeAnchors: [SmallWindowAnchorSnapshot] = []
    private var suppressesTertiaryAfterEscape = false
    private var tertiaryEscapePointerLocation: NSPoint?
    private var tertiaryEscapeAnchor: SmallWindowAnchorSnapshot?
    private let pointerLocationProvider: @MainActor () -> NSPoint
    let hoverIntentController: HoverIntentController
    let anchorRegistry: SmallWindowAnchorRegistry
    /// Answers whether a presented control palette still owns the pointer
    /// (anchor, palette, or the corridor between them). Wired by the panel
    /// session; nil means no palette surface exists.
    var controlPaletteClaimsPointer: (@MainActor () -> Bool)?

    init(
        initialSection: PanelSection = .overview,
        hoverIntentController: HoverIntentController = HoverIntentController(),
        anchorRegistry: SmallWindowAnchorRegistry = SmallWindowAnchorRegistry(),
        pointerLocationProvider: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation }
    ) {
        self.hoverIntentController = hoverIntentController
        self.anchorRegistry = anchorRegistry
        self.pointerLocationProvider = pointerLocationProvider
        route = initialSection == .overview ? .summary : .module(initialSection)
        if initialSection != .overview {
            hoverIntentController.markOpen(
                anchorID: .module(initialSection),
                panelRole: .secondary
            )
        }
    }

    var selectedSection: PanelSection {
        switch route {
        case .summary:
            .overview
        case let .module(section), let .history(section, _):
            section
        }
    }

    var isModulePinned: Bool { pinnedModule != nil }

    /// Returns a lease for delayed hover work. A newer hover or any route
    /// transition invalidates older leases, so a cancelled Task cannot reopen
    /// a section after the pointer moved elsewhere.
    func beginHoverIntent() -> HoverIntent {
        HoverIntent(request: hoverIntentController.beginRequest())
    }

    func isCurrentHoverIntent(_ intent: HoverIntent) -> Bool {
        hoverIntentController.isCurrent(intent.request)
    }

    func invalidateHoverIntent(_ intent: HoverIntent? = nil) {
        hoverIntentController.cancel(intent?.request)
    }

    @discardableResult
    func scheduleModulePreview(
        _ section: PanelSection,
        condition: @escaping @MainActor () -> Bool,
        action: @escaping @MainActor () -> Void
    ) -> HoverIntent {
        guard !suppressesModuleAfterEscape else {
            return cancelledHoverIntent()
        }
        // A pointer traveling from a palette's anchor to the palette crosses
        // neighboring hover targets (the anchor rows are much shorter than
        // the palette, and placement prefers the far side of the window).
        // Those crossings must not hijack the hover and tear the palette
        // down before the pointer arrives.
        guard controlPaletteClaimsPointer?() != true else {
            return expiredHoverIntent()
        }
        let request = hoverIntentController.scheduleOpen(
            anchorID: .module(section),
            panelRole: .secondary,
            condition: condition,
            action: action
        )
        return HoverIntent(request: request)
    }

    @discardableResult
    func scheduleTertiaryPreview(
        identifier: String,
        condition: @escaping @MainActor () -> Bool,
        action: @escaping @MainActor () -> Void
    ) -> HoverIntent {
        guard !suppressesTertiaryAfterEscape else {
            return cancelledHoverIntent()
        }
        guard controlPaletteClaimsPointer?() != true else {
            return expiredHoverIntent()
        }
        let request = hoverIntentController.scheduleOpen(
            anchorID: .tertiary(identifier),
            panelRole: .tertiary,
            condition: condition,
            action: action
        )
        return HoverIntent(request: request)
    }

    func moduleHoverExited(_ section: PanelSection) {
        releaseModuleHoverSuppression(afterMovingTo: pointerLocationProvider())
    }

    private func releaseModuleHoverSuppression(afterMovingTo pointer: NSPoint) {
        // Closing a secondary can place a different overview card under a
        // stationary pointer. Only a real departure from the old and rebuilt
        // trigger rectangles permits another hover; explicit clicks stay usable.
        guard suppressesModuleAfterEscape,
              let suppressedPointer = moduleEscapePointerLocation,
              pointer.x.isFinite, pointer.y.isFinite,
              pointer != suppressedPointer else { return }
        for anchor in moduleEscapeAnchors {
            guard !anchor.screenRect.contains(pointer),
                  anchorRegistry.snapshot(for: anchor.id)?.screenRect.contains(pointer) != true else { return }
        }
        suppressesModuleAfterEscape = false
        moduleEscapePointerLocation = nil
        moduleEscapeAnchors = []
    }

    func tertiaryHoverExited() {
        guard suppressesTertiaryAfterEscape else { return }
        // Closing a column or raising its window can recreate tracking areas
        // around a stationary cursor. Their exit/enter pair is not a new hover
        // gesture and must not undo Escape. Module anchors are already measured
        // in screen space; preserve their pre-close hitbox as well as the latest
        // one so a layout move or movement within the same row cannot unlock it.
        // Inline targets without a registered hitbox still reject stationary
        // exit/enter pairs, independent of their SwiftUI UUID.
        let pointer = pointerLocationProvider()
        guard let suppressedPointer = tertiaryEscapePointerLocation,
              pointer.x.isFinite, pointer.y.isFinite,
              pointer != suppressedPointer else { return }
        if let anchor = tertiaryEscapeAnchor {
            guard !anchor.screenRect.contains(pointer),
                  anchorRegistry.snapshot(for: anchor.id)?.screenRect.contains(pointer) != true else { return }
        }
        suppressesTertiaryAfterEscape = false
        tertiaryEscapePointerLocation = nil
        tertiaryEscapeAnchor = nil
    }

    @discardableResult
    func scheduleHoverDismissal(
        condition: @escaping @MainActor () -> Bool,
        action: @escaping @MainActor () -> Void
    ) -> HoverIntent {
        let request = hoverIntentController.scheduleClose(
            condition: condition,
            action: action
        )
        return HoverIntent(request: request)
    }

    func recordPointer(_ point: NSPoint) {
        hoverIntentController.recordPointer(point)
        releaseModuleHoverSuppression(afterMovingTo: point)
    }

    func updateWindowGroupFrames(_ frames: [NSRect]) {
        hoverIntentController.updateWindowGroupFrames(frames)
    }

    func registerAnchor(
        id: SmallWindowAnchorID,
        screenRect: NSRect,
        parentPanelRole: SmallWindowPanelRole = .primary,
        preferredPlacementEdge: MenuBarCascadeDirection = .left,
        contentKind: String
    ) {
        anchorRegistry.update(
            id: id,
            screenRect: screenRect,
            parentPanelRole: parentPanelRole,
            preferredPlacementEdge: preferredPlacementEdge,
            contentKind: contentKind
        )
        if suppressesModuleAfterEscape,
           parentPanelRole == .primary,
           let pointer = moduleEscapePointerLocation,
           screenRect.contains(pointer),
           let snapshot = anchorRegistry.snapshot(for: id),
           !moduleEscapeAnchors.contains(where: {
               $0.id == id && $0.screenRect.isApproximatelyEqual(to: snapshot.screenRect)
           }) {
            moduleEscapeAnchors.append(snapshot)
        }
    }

    func removeAnchor(_ id: SmallWindowAnchorID) {
        anchorRegistry.remove(id)
    }

    func previewModule(_ section: PanelSection) {
        guard section != .overview, pinnedModule == nil, !suppressesModuleAfterEscape else { return }
        route = .module(section)
        hoverIntentController.markOpen(anchorID: .module(section), panelRole: .secondary)
    }

    func selectModule(_ section: PanelSection) {
        PerformanceTelemetry.panelInput("action", target: "module.\(section.rawValue)")
        guard section != .overview else {
            reset()
            return
        }
        pinnedModule = section
        hardwareDetailFocus = .monitoring
        isHistoryPinned = false
        route = .module(section)
        hoverIntentController.markOpen(anchorID: .module(section), panelRole: .secondary)
    }

    func previewHardwareDetail(_ focus: GeekHardwareDetailFocus) {
        guard pinnedModule == nil, !suppressesModuleAfterEscape else { return }
        hardwareDetailFocus = focus
        route = .module(.sensors)
        hoverIntentController.markOpen(anchorID: .module(.sensors), panelRole: .secondary)
    }

    func selectHardwareDetail(_ focus: GeekHardwareDetailFocus) {
        PerformanceTelemetry.panelInput("action", target: "hardware.\(focus.rawValue)")
        if pinnedModule == .sensors,
           selectedSection == .sensors,
           hardwareDetailFocus == focus {
            reset()
            return
        }
        hardwareDetailFocus = focus
        pinnedModule = .sensors
        isHistoryPinned = false
        route = .module(.sensors)
        hoverIntentController.markOpen(anchorID: .module(.sensors), panelRole: .secondary)
    }

    @discardableResult
    func presentHistory(
        _ selection: GeekPanelHistorySelection,
        pinned: Bool
    ) -> Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        guard MiniWindowDemoData.allowsTertiaryPresentation(
            arguments: ProcessInfo.processInfo.arguments
        ) else { return false }
#endif
        let section = selectedSection
        guard section != .overview else { return false }
        guard pinned || !isHistoryPinned else { return false }
        guard pinned || !suppressesTertiaryAfterEscape else { return false }
        let ownsCurrentHover: Bool
        if case .open(_, .tertiary) = hoverIntentController.state {
            ownsCurrentHover = true
        } else {
            ownsCurrentHover = false
        }
        // `ownsCurrentHover` is always true for scheduler-driven opens, since
        // the intent controller marks the tertiary open before running the
        // action. The palette therefore keeps explicit pointer ownership: as
        // long as the pointer is inside its anchor, its panel, or the
        // corridor between them, hover-driven history must stand down.
        if !pinned, isControlPalettePresented, controlPaletteClaimsPointer?() == true {
            return false
        }
        guard pinned || !isControlPalettePresented || ownsCurrentHover else { return false }
        isControlPalettePresented = false
        isHistoryPinned = pinned
        route = .history(module: section, selection: selection)
        hoverIntentController.markOpen(
            anchorID: .tertiary(String(describing: selection)),
            panelRole: .tertiary
        )
        return true
    }

    func controlPaletteWillPresent() {
        invalidateHoverIntent()
        dismissHistory()
        isControlPalettePresented = true
    }

    func controlPaletteDidDismiss() {
        isControlPalettePresented = false
    }

    func dismissHistory() {
        guard case let .history(section, _) = route else { return }
        isHistoryPinned = false
        route = .module(section)
        hoverIntentController.markOpen(anchorID: .module(section), panelRole: .secondary)
    }

    func dismissUnpinnedModule() {
        guard pinnedModule == nil else { return }
        reset()
    }

    func dismissUnpinnedHierarchy() {
        guard !isHistoryPinned else { return }
        if pinnedModule == nil {
            reset()
        } else {
            dismissHistory()
        }
    }

    func setPointerWithinHoverEnvelope(_ contained: Bool) {
        guard isPointerWithinHoverEnvelope != contained else { return }
        isPointerWithinHoverEnvelope = contained
    }

    @discardableResult
    func handleEscape() -> Bool {
        switch route {
        case .history:
#if DEBUG || STORAGE_CLEANER_BETA
            PerformanceTelemetry.logger.notice("MenuBar Escape: history -> module")
#endif
            let pointer = pointerLocationProvider()
            tertiaryEscapePointerLocation = pointer
            let anchor = anchorRegistry.snapshot(for: .module(selectedSection))
            tertiaryEscapeAnchor = anchor?.screenRect.contains(pointer) == true ? anchor : nil
            suppressesTertiaryAfterEscape = true
            dismissHistory()
            return true
        case .module:
            let pointer = pointerLocationProvider()
            let anchors = PanelSection.allCases.compactMap {
                anchorRegistry.snapshot(for: .module($0))
            }.filter { $0.screenRect.contains(pointer) }
            reset()
            suppressesModuleAfterEscape = true
            moduleEscapePointerLocation = pointer
            moduleEscapeAnchors = anchors
#if DEBUG || STORAGE_CLEANER_BETA
            PerformanceTelemetry.logger.notice("MenuBar Escape: module -> summary")
#endif
            return true
        case .summary:
            return false
        }
    }

    func reset() {
        invalidateHoverIntent()
        pinnedModule = nil
        isHistoryPinned = false
        isControlPalettePresented = false
        suppressesModuleAfterEscape = false
        moduleEscapePointerLocation = nil
        moduleEscapeAnchors = []
        suppressesTertiaryAfterEscape = false
        tertiaryEscapePointerLocation = nil
        tertiaryEscapeAnchor = nil
        isPointerWithinHoverEnvelope = false
        hardwareDetailFocus = .monitoring
        route = .summary
        hoverIntentController.markClosed()
    }

    private func cancelledHoverIntent() -> HoverIntent {
        let request = hoverIntentController.beginRequest()
        hoverIntentController.cancel(request)
        return HoverIntent(request: request)
    }

    /// A refused hover that must not disturb pending work, e.g. the close
    /// countdown a presented palette keeps while the pointer travels to it.
    private func expiredHoverIntent() -> HoverIntent {
        HoverIntent(request: hoverIntentController.expiredRequest())
    }
}

@MainActor
final class MenuBarPanelSession: NSObject, NSWindowDelegate {
    let panel: MenuBarStatusPanel
    private(set) var isTornDown = false
    private(set) var isPresented = false

    private var hostingController: NSHostingController<AnyView>?
    private var onClose: (@MainActor () -> Void)?
    private var onDismiss: (@MainActor () -> Void)?
    private let triggerFrameProvider: (@MainActor () -> NSRect?)?
    private let pointerLocationProvider: @MainActor () -> NSPoint
    private let applicationIsActiveProvider: @MainActor () -> Bool
    // Pure geometry tests can pin a virtual display and keep the panel out of
    // WindowServer. Production uses the defaults and remains screen-driven.
    private let fixedVisibleFrame: NSRect?
    private let presentsPanelOnShow: Bool
    private weak var panelSettingsState: MenuBarPanelSettingsState?
    private let panelCoordinator: GeekPanelCoordinator?
    private let controlPaletteCoordinator: ControlPaletteCoordinator?

    private var anchor: NSRect?
    private var screen: NSScreen?
    private let geometryStore: PanelGeometryStore
    private(set) var density: PanelDensity
    private(set) var overviewSize = GeekPanelPresentationMetrics.overviewSize
    private(set) var geekSection: PanelSection = .overview
    private(set) var cascadeDirection = MenuBarCascadeDirection.left
    private(set) var secondaryPresentationMode = MenuBarSecondaryPresentationMode.adjacent
    private(set) var tertiaryPresentationMode = MenuBarTertiaryPresentationMode.column
    private(set) var detailColumnSize: CGSize?
    private(set) var isTertiaryPresented = false
    private(set) var tertiaryColumnSize = GeekPanelPresentationMetrics.tertiarySize
    private(set) var tertiarySourceOffset: CGFloat?
    private var attachedOverviewFrame: NSRect?
    private var attachedCascadeLayout: MenuBarCascadeLayout?
    private var hoverIntentAnchor: NSPoint?
    private var persistsGeometry = false
    private var isApplyingProgrammaticFrame = false

    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var defaultObservers: [NSObjectProtocol] = []
    private let menuTrackingObservers = MenuBarMenuTrackingObservers()
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var deactivatedDuringMenuTracking = false
    private var menuTrackingDismissalTask: Task<Void, Never>?

    init(
        panel: MenuBarStatusPanel = MenuBarStatusPanel(contentRect: .zero),
        rootView: AnyView,
        initialDensity: PanelDensity = .defaultValue,
        initialOverviewSize: CGSize? = nil,
        geometryStore: PanelGeometryStore = PanelGeometryStore(),
        panelSettingsState: MenuBarPanelSettingsState? = nil,
        panelCoordinator: GeekPanelCoordinator? = nil,
        controlPaletteCoordinator: ControlPaletteCoordinator? = nil,
        triggerFrameProvider: (@MainActor () -> NSRect?)? = nil,
        pointerLocationProvider: @escaping @MainActor () -> NSPoint = {
            NSEvent.mouseLocation
        },
        applicationIsActiveProvider: @escaping @MainActor () -> Bool = {
            NSApp.isActive
        },
        fixedVisibleFrame: NSRect? = nil,
        presentsPanelOnShow: Bool = true,
        onClose: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        self.panel = panel
        self.onClose = onClose
        self.onDismiss = onDismiss
        self.triggerFrameProvider = triggerFrameProvider
        self.pointerLocationProvider = pointerLocationProvider
        self.applicationIsActiveProvider = applicationIsActiveProvider
        self.fixedVisibleFrame = fixedVisibleFrame
        self.presentsPanelOnShow = presentsPanelOnShow
        self.panelSettingsState = panelSettingsState
        self.panelCoordinator = panelCoordinator
        self.controlPaletteCoordinator = controlPaletteCoordinator
        density = initialDensity
        overviewSize = GeekPanelPresentationMetrics.normalizedOverviewSize(initialOverviewSize)
        self.geometryStore = geometryStore
        super.init()

        let hostingController = NSHostingController(rootView: rootView)
        // This panel owns its geometry. SwiftUI's automatic hosting-window
        // sizing can recursively resize an NSPanel while a segmented control
        // is committing a new root view on macOS 26/27.
        hostingController.sizingOptions = []
        if let hostingView = hostingController.view as? NSHostingView<AnyView> {
            hostingView.sizingOptions = []
        }
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            hostingController.view.prefersCompactControlSizeMetrics = true
        }
#endif
        self.hostingController = hostingController
        panel.contentViewController = hostingController
        panel.onEscape = { [weak self] in
            guard let self else { return false }
            return self.handleEscape(sourceWindow: self.panel)
        }
        panel.onPointerLocationChanged = { [weak self] point in
            self?.pointerLocationChanged(point)
        }
        panelCoordinator?.anchorRegistry.didChange = { [weak self] anchorID in
            self?.registeredAnchorDidChange(anchorID)
        }
        controlPaletteCoordinator?.willPresent = { [weak self] _ in
            self?.replaceAttachedTertiaryWithControlPalette()
        }
        controlPaletteCoordinator?.didDismiss = { [weak panelCoordinator, weak self] in
            panelCoordinator?.controlPaletteDidDismiss()
            // The palette frame just left the hover envelope; delayed
            // dismissal tasks must not act on the stale contained value.
            self?.refreshPointerWithinHoverEnvelope()
        }
        panelCoordinator?.controlPaletteClaimsPointer = { [weak controlPaletteCoordinator] in
            controlPaletteCoordinator?.claimsHoverPointer() == true
        }
        controlPaletteCoordinator?.pointerLocationObserver = { [weak self] point in
            self?.pointerLocationChanged(point)
        }
        panel.installPointerTracking()
        panel.delegate = self
    }

    func show(anchor: NSRect, screen: NSScreen, density: PanelDensity) {
        guard !isTornDown, let hostingController else { return }
#if DEBUG || STORAGE_CLEANER_BETA
        PerformanceTelemetry.logger.notice("MenuBar lifecycle: show")
#endif

        if panel.contentViewController !== hostingController {
            panel.contentViewController = hostingController
            panel.installPointerTracking()
        }

        self.anchor = anchor
        self.screen = screen
        self.density = density
        isPresented = true
        controlPaletteCoordinator?.dismiss()
        panelCoordinator?.reset()
        cascadeDirection = .left
        secondaryPresentationMode = .adjacent
        tertiaryPresentationMode = .column
        detailColumnSize = nil
        isTertiaryPresented = false
        tertiaryColumnSize = GeekPanelPresentationMetrics.tertiarySize
        tertiarySourceOffset = nil
        attachedCascadeLayout = nil
        panelSettingsState?.setCascadeDirection(.left)
        panelSettingsState?.setSecondaryPresentationMode(.adjacent)
        panelSettingsState?.setTertiaryPresentationMode(.column)
        panelSettingsState?.setCascadeLayout(nil)
        persistsGeometry = true
        geekSection = .overview
        let visibleFrame = resolvedVisibleFrame(for: screen) ?? screen.visibleFrame
        configureSizeLimits(for: density, visibleFrame: visibleFrame)
        let frame = MenuBarPanelPlacement.frame(
            anchor: anchor,
            contentSize: density.usesAttachedDetailPresentation
                ? overviewSize
                : density.idealSize,
            visibleFrame: visibleFrame,
            backingScaleFactor: screen.backingScaleFactor
        )
        attachedOverviewFrame = density.usesAttachedDetailPresentation ? frame : nil
        applyProgrammaticFrame(frame)
        installEventMonitors()
        installObservers()
        // A non-activating panel can become key without activating the app.
        // This keeps Escape and keyboard controls inside the visible window
        // group while preserving the foreground application's activation.
        if presentsPanelOnShow {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
        PerformanceTelemetry.panelInput("presented", target: "overview.visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) frame=\(NSStringFromRect(panel.frame)) content=\(NSStringFromRect(hostingController.view.frame)) appHidden=\(NSApp.isHidden) minimized=\(panel.isMiniaturized) level=\(panel.level.rawValue) anchor=\(NSStringFromRect(anchor)) screen=\(NSStringFromRect(visibleFrame)) occlusion=\(panel.occlusionState.rawValue)", window: panel)
#if DEBUG || STORAGE_CLEANER_BETA
        scheduleDebugSnapshotsIfRequested()
#endif
    }

    func selectDensity(_ density: PanelDensity) {
        guard !isTornDown, let anchor, let screen else { return }
        controlPaletteCoordinator?.dismiss()
        let previousDensity = self.density
        let sectionToRestore = previousDensity.usesAttachedDetailPresentation
            && density.usesAttachedDetailPresentation
            ? geekSection
            : .overview
        if persistsGeometry {
            geometryStore.save(frame: persistableFrame, for: self.density)
        }
        self.density = density
        geekSection = .overview
        cascadeDirection = .left
        secondaryPresentationMode = .adjacent
        tertiaryPresentationMode = .column
        detailColumnSize = nil
        isTertiaryPresented = false
        tertiaryColumnSize = GeekPanelPresentationMetrics.tertiarySize
        tertiarySourceOffset = nil
        attachedCascadeLayout = nil
        panelSettingsState?.setCascadeDirection(.left)
        panelSettingsState?.setSecondaryPresentationMode(.adjacent)
        panelSettingsState?.setTertiaryPresentationMode(.column)
        panelSettingsState?.setCascadeLayout(nil)
        attachedOverviewFrame = nil
        persistsGeometry = true
        let resolvedScreen = panel.screen ?? screen
        let visibleFrame = resolvedVisibleFrame(for: resolvedScreen) ?? resolvedScreen.visibleFrame
        configureSizeLimits(for: density, visibleFrame: visibleFrame)
        let frame = MenuBarPanelPlacement.frame(
            anchor: anchor,
            contentSize: density.usesAttachedDetailPresentation
                ? overviewSize
                : density.idealSize,
            visibleFrame: visibleFrame,
            backingScaleFactor: resolvedScreen.backingScaleFactor
        )
        if density.usesAttachedDetailPresentation {
            attachedOverviewFrame = frame
        }
        applyProgrammaticFrame(frame)
        if sectionToRestore != .overview {
            setGeekSection(sectionToRestore)
        }
    }

    func setGeekSection(
        _ section: PanelSection,
        visibleFrameOverride: NSRect? = nil
    ) {
        guard !isTornDown, density.usesAttachedDetailPresentation else { return }

        if geekSection != section {
            controlPaletteCoordinator?.dismiss()
        }

        let overviewFrame = attachedOverviewFrame ?? collapsedAttachedFrame(from: panel.frame)
        attachedOverviewFrame = overviewFrame
        if geekSection != section {
            detailColumnSize = nil
        }
        geekSection = section
        let resolvedScreen = ScreenContextResolver.resolve(
            anchorWindowScreen: panel.screen,
            anchorRect: overviewFrame,
            pointerLocation: pointerLocationProvider(),
            fallbackScreen: screen
        )
        if let resolvedScreen {
            screen = resolvedScreen
        }

        guard section != .overview else {
            detailColumnSize = nil
            secondaryPresentationMode = .adjacent
            tertiaryPresentationMode = .column
            isTertiaryPresented = false
            tertiaryColumnSize = GeekPanelPresentationMetrics.tertiarySize
            tertiarySourceOffset = nil
            attachedCascadeLayout = nil
            panelSettingsState?.setSecondaryPresentationMode(.adjacent)
            panelSettingsState?.setTertiaryPresentationMode(.column)
            panelSettingsState?.setCascadeLayout(nil)
            configureSizeLimits(
                for: density,
                visibleFrame: resolvedVisibleFrame(for: resolvedScreen)
            )
            panelCoordinator?.updateWindowGroupFrames([overviewFrame])
            applyProgrammaticFrame(overviewFrame)
            return
        }

        let detailSize = GeekPanelPresentationMetrics.normalizedDetailSize(
            detailColumnSize,
            for: section,
            density: density
        )
        let visibleFrame = visibleFrameOverride
            ?? resolvedVisibleFrame(for: resolvedScreen)
            ?? overviewFrame
        let detailTopOffset = registeredDetailTopOffset(
            for: section,
            overviewFrame: overviewFrame,
            detailSize: detailSize
        ) ?? GeekPanelPresentationMetrics.detailVerticalOffset(
            for: section,
            density: density,
            detailSize: detailSize,
            overviewSize: overviewSize
        )
        let tertiaryTopOffset = GeekPanelPresentationMetrics.tertiaryVerticalOffset(
            for: section,
            density: density,
            detailSize: detailSize,
            detailTopOffset: detailTopOffset,
            tertiarySize: tertiaryColumnSize,
            sourceOffset: tertiarySourceOffset,
            overviewSize: overviewSize
        )
        let secondaryCascade = MenuBarPanelPlacement.cascade(
            parentFrame: overviewFrame,
            childSizes: [detailSize],
            visibleFrame: visibleFrame,
            preferredDirection: cascadeDirection,
            preferredAlignment: .anchor,
            childTopOffsets: [detailTopOffset],
            pointerLocation: pointerLocationProvider(),
            backingScaleFactor: resolvedScreen?.backingScaleFactor ?? 1
        )
        let completeCascade = MenuBarPanelPlacement.cascade(
            parentFrame: overviewFrame,
            childSizes: [detailSize, tertiaryColumnSize],
            visibleFrame: visibleFrame,
            preferredDirection: secondaryCascade.direction,
            preferredAlignment: .anchor,
            childTopOffsets: [detailTopOffset, tertiaryTopOffset],
            pointerLocation: pointerLocationProvider(),
            backingScaleFactor: resolvedScreen?.backingScaleFactor ?? 1
        )
        let requestedTertiaryColumn = isTertiaryPresented
            && completeCascade.tertiaryPresentationMode == .column
        if isTertiaryPresented && !requestedTertiaryColumn {
            isTertiaryPresented = false
        }
        let cascade = requestedTertiaryColumn ? completeCascade : secondaryCascade
        let previousDirection = cascadeDirection
        cascadeDirection = cascade.direction
        secondaryPresentationMode = cascade.secondaryPresentationMode
        tertiaryPresentationMode = completeCascade.tertiaryPresentationMode
        panelSettingsState?.setCascadeDirection(cascade.direction)
        panelSettingsState?.setSecondaryPresentationMode(cascade.secondaryPresentationMode)
        panelSettingsState?.setTertiaryPresentationMode(completeCascade.tertiaryPresentationMode)
        attachedCascadeLayout = cascade.secondaryPresentationMode == .adjacent ? cascade : nil
        panelSettingsState?.setCascadeLayout(attachedCascadeLayout)
        panelCoordinator?.updateWindowGroupFrames(cascade.visibleFrames)
        controlPaletteCoordinator?.updatePlacementAnchor(cascade.childFrames.first)
        PerformanceTelemetry.signposter.emitEvent("PlacementCalculated")
        if previousDirection != cascade.direction {
            PerformanceTelemetry.signposter.emitEvent("PlacementFlipped")
        }
        configureSizeLimits(
            for: density,
            visibleFrame: resolvedVisibleFrame(for: resolvedScreen)
        )

        guard cascade.secondaryPresentationMode == .adjacent else {
            applyProgrammaticFrame(overviewFrame)
            return
        }
        applyProgrammaticFrame(cascade.containerFrame)
    }

    func setOverviewSize(_ preferredSize: CGSize) {
        guard !isTornDown, density.usesAttachedDetailPresentation else { return }
        let normalizedSize = GeekPanelPresentationMetrics.normalizedOverviewSize(
            preferredSize
        )
        guard overviewSize != normalizedSize else { return }

        let currentOverviewFrame = attachedOverviewFrame
            ?? collapsedAttachedFrame(from: panel.frame)
        overviewSize = normalizedSize
        attachedOverviewFrame = clampedExpandedAttachedFrame(
            NSRect(
                x: currentOverviewFrame.minX,
                y: currentOverviewFrame.maxY - normalizedSize.height,
                width: normalizedSize.width,
                height: normalizedSize.height
            ),
            screen: panel.screen ?? screen
        )
        attachedCascadeLayout = nil
        panelSettingsState?.setCascadeLayout(nil)
        setGeekSection(geekSection)
    }

    func setDetailSize(_ preferredSize: CGSize?) {
        guard !isTornDown,
              density.usesAttachedDetailPresentation,
              geekSection != .overview else { return }
        let normalizedSize = GeekPanelPresentationMetrics.normalizedDetailSize(
            preferredSize,
            for: geekSection,
            density: density
        )
        guard detailColumnSize != normalizedSize else { return }
        detailColumnSize = normalizedSize
        setGeekSection(geekSection)
    }

    func setTertiaryPresented(
        _ presented: Bool,
        preferredSize: CGSize? = nil,
        sourceOffset: CGFloat? = nil
    ) {
        guard !isTornDown,
              density.usesAttachedDetailPresentation,
              geekSection != .overview else { return }
        if presented, let panelCoordinator {
            guard case .history = panelCoordinator.route else { return }
        }
        if presented {
            controlPaletteCoordinator?.dismiss()
        }
        let normalizedSize = presented
            ? GeekPanelPresentationMetrics.normalizedTertiarySize(preferredSize)
            : GeekPanelPresentationMetrics.tertiarySize
        let normalizedSourceOffset = presented
            ? GeekPanelPresentationMetrics.normalizedTertiarySourceOffset(sourceOffset)
            : nil
        let presentationChanged = isTertiaryPresented != presented
        let geometryChanged = tertiaryColumnSize != normalizedSize
            || tertiarySourceOffset != normalizedSourceOffset
        guard presentationChanged || geometryChanged else { return }

        isTertiaryPresented = presented
        tertiaryColumnSize = normalizedSize
        tertiarySourceOffset = normalizedSourceOffset
        setGeekSection(geekSection)
    }

    private func replaceAttachedTertiaryWithControlPalette() {
        panelCoordinator?.controlPaletteWillPresent()
        guard isTertiaryPresented else { return }
        setTertiaryPresented(false)
    }

    func setAlwaysOnTop(_ value: Bool) {
        panel.setAlwaysOnTop(value)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingProgrammaticFrame, !isTornDown else { return }
        let previousScreen = screen
        persistCurrentFrameIfNeeded()
        let resolvedScreen = ScreenContextResolver.resolve(
            anchorWindowScreen: panel.screen,
            anchorRect: attachedOverviewFrame ?? panel.frame,
            pointerLocation: pointerLocationProvider(),
            fallbackScreen: screen
        )
        if let resolvedScreen {
            screen = resolvedScreen
            if previousScreen !== resolvedScreen {
                PerformanceTelemetry.signposter.emitEvent("ScreenChanged")
            }
        }
        if density.usesAttachedDetailPresentation, geekSection != .overview {
            setGeekSection(geekSection)
        }
        controlPaletteCoordinator?.parentWindowDidMove()
    }

    func handleKeyEvent(_ event: NSEvent, sourceWindow: NSWindow? = nil) -> NSEvent? {
        guard event.keyCode == 53 else { return event }
        let eventWindow = sourceWindow ?? event.window
        return handleEscape(sourceWindow: eventWindow) ? nil : event
    }

    @discardableResult
    private func handleEscape(sourceWindow: NSWindow?) -> Bool {
        // AppKit must cancel its currently tracked menu before this session
        // handles a later Escape for the history, module, or overview.
        guard trackingMenus.isEmpty else { return false }
#if DEBUG || STORAGE_CLEANER_BETA
        PerformanceTelemetry.logger.notice("MenuBar Escape: received by panel session")
#endif
        let panelFamilyWindow = isPresented ? panel : sourceWindow
        if controlPaletteCoordinator?.handleEscape(sourceWindow: panelFamilyWindow) == true {
            return true
        }
        guard isPresented || sourceWindow === panel else { return false }
        if panelCoordinator?.handleEscape() == true {
            return true
        }
        hide(reason: "escape-summary")
#if DEBUG || STORAGE_CLEANER_BETA
        PerformanceTelemetry.logger.notice("MenuBar Escape: summary -> hidden")
#endif
        return true
    }

    @discardableResult
    func handleMouseDown(
        sourceWindow: NSWindow?,
        screenLocation: NSPoint,
        eventWindowNumber: Int? = nil
    ) -> Bool {
        guard !isTornDown else { return false }
        guard eventWindowNumber != 0 else { return false }
        let sourceWindow = sourceWindow ?? eventWindowNumber.flatMap {
            NSApp.window(withWindowNumber: $0)
        }
        let triggerFrame = triggerFrameProvider?() ?? anchor
        guard triggerFrame?.contains(screenLocation) != true else { return false }
        guard sourceWindow?.level != .popUpMenu else { return false }
        // A system-owned menu can report no application window. While AppKit
        // is tracking it, that unknown source is not proof of an outside click.
        // A real app switch is reconciled after the menu finishes tracking.
        guard trackingMenus.isEmpty || sourceWindow != nil else { return false }

        if controlPaletteCoordinator?.handleMouseDown(
            sourceWindow: sourceWindow,
            screenLocation: screenLocation
        ) == true {
            return true
        }

        // Non-activating panels can receive a global event without a source
        // window. Missing identity is not evidence of an outside click. Keep
        // only visible family surfaces; transparent union corners stay outside.
        if sourceWindow == nil, eventWindowNumber == nil,
           attachedHoverFrames.contains(where: { $0.contains(screenLocation) })
            || NSApp.windows.contains(where: {
                $0 !== panel && $0.isVisible && isPanelFamilyWindow($0)
                    && $0.frame.contains(screenLocation)
            }) {
            PerformanceTelemetry.panelInput("keep", target: "unknown-source-inside-family", window: panel)
            return false
        }

        // Attached Detailed/Geek surfaces share one rectangular NSPanel with
        // the overview, but only the two visible surfaces should behave as part
        // of the panel.
        // Treat the transparent union-frame corners like any other outside click.
        if sourceWindow === panel,
           density.usesAttachedDetailPresentation,
           geekSection != .overview,
           !visibleAttachedContentFrames.contains(where: { $0.contains(screenLocation) }) {
            hide(reason: "outside-transparent-panel-corner")
            return true
        }

        guard !isPanelFamilyWindow(sourceWindow) else { return false }

        hide(reason: sourceWindow == nil ? "outside-unknown-window" : "outside-application-window")
        return true
    }

    func hide(reason: String = "explicit") {
        guard !isTornDown, isPresented || panel.isVisible else { return }
        PerformanceTelemetry.panelInput("close", target: reason, window: panel)
#if DEBUG || STORAGE_CLEANER_BETA
        PerformanceTelemetry.logger.notice("MenuBar lifecycle: hide reason=\(reason, privacy: .public)")
#endif

        let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
        let state = PerformanceTelemetry.signposter.beginInterval(
            "WindowClose",
            id: signpostID
        )
        defer { PerformanceTelemetry.signposter.endInterval("WindowClose", state) }

        removeEventMonitors()
        removeObservers()
        controlPaletteCoordinator?.dismiss()
        panel.orderOut(nil)
        if persistsGeometry {
            geometryStore.save(frame: persistableFrame, for: density)
        }

        // Detaching preserves the hosting controller and its SwiftUI state,
        // while still delivering onDisappear so hidden chart/probe consumers stop.
        panel.contentViewController = nil
        isPresented = false
        anchor = nil
        screen = nil
        panelCoordinator?.reset()
        onDismiss?()
    }

    func teardown() {
        guard !isTornDown else { return }

        isTornDown = true
        isPresented = false
        removeEventMonitors()
        removeObservers()
        controlPaletteCoordinator?.teardown()

        panel.orderOut(nil)
        if persistsGeometry {
            geometryStore.save(frame: persistableFrame, for: density)
        }
        panel.delegate = nil
        panel.onPointerLocationChanged = nil
        panelCoordinator?.anchorRegistry.didChange = nil
        panel.contentViewController = nil
        panel.contentView = nil
        panel.close()

        anchor = nil
        screen = nil
        hostingController = nil
        panelCoordinator?.reset()

        let closeHandler = onClose
        onClose = nil
        onDismiss = nil
        closeHandler?()
    }

    private func resolvedVisibleFrame(for screen: NSScreen?) -> NSRect? {
        fixedVisibleFrame ?? screen?.visibleFrame
    }

    private func registeredDetailTopOffset(
        for section: PanelSection,
        overviewFrame: NSRect,
        detailSize: NSSize
    ) -> CGFloat? {
        guard let snapshot = panelCoordinator?.anchorRegistry.snapshot(
            for: .module(section)
        ), snapshot.screenRect.intersects(overviewFrame) else { return nil }
        let offset = overviewFrame.maxY - snapshot.screenRect.maxY
        guard offset.isFinite else { return nil }
        return min(max(0, offset), max(0, overviewFrame.height - min(44, detailSize.height)))
    }

    private func registeredAnchorDidChange(_ anchorID: SmallWindowAnchorID) {
        guard isPresented,
              !isTornDown,
              !isApplyingProgrammaticFrame,
              geekSection != .overview,
              anchorID == .module(geekSection) else { return }
        setGeekSection(geekSection)
    }

    private func configureSizeLimits(for density: PanelDensity, visibleFrame: NSRect?) {
        guard let visibleFrame else { return }
        let visible = visibleFrame.insetBy(dx: 8, dy: 8)
        let requestedSize = activeContentSize(for: density)
        let fixedSize = NSSize(
            width: min(requestedSize.width, visible.width),
            height: min(requestedSize.height, visible.height)
        )
        panel.contentMinSize = fixedSize
        panel.contentMaxSize = fixedSize
    }

    private func applyProgrammaticFrame(_ frame: NSRect) {
        let resolvedScreen = ScreenContextResolver.resolve(
            anchorWindowScreen: panel.screen,
            anchorRect: attachedOverviewFrame ?? frame,
            pointerLocation: pointerLocationProvider(),
            fallbackScreen: screen
        )
        let alignedFrame = MenuBarPanelPlacement.pixelAligned(
            frame,
            scale: resolvedScreen?.backingScaleFactor ?? 1
        )
        guard !panel.frame.isApproximatelyEqual(to: alignedFrame) else {
            refreshPointerWithinHoverEnvelope()
            return
        }
        let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
        let state = PerformanceTelemetry.signposter.beginInterval(
            "WindowReposition",
            id: signpostID
        )
        defer { PerformanceTelemetry.signposter.endInterval("WindowReposition", state) }
        isApplyingProgrammaticFrame = true
        panel.setFrame(alignedFrame, display: true)
        isApplyingProgrammaticFrame = false
        PerformanceTelemetry.signposter.emitEvent("PanelRepositioned")
        refreshPointerWithinHoverEnvelope()
    }

#if DEBUG || STORAGE_CLEANER_BETA
    private func scheduleDebugSnapshotsIfRequested() {
        let prefix = MiniWindowDemoData.menuBarPanelSnapshotCaptureArgumentPrefix
        let capturesPower = MiniWindowDemoData.isCapturingPowerMenuBarPanelSnapshots
        let requestedScenario = MiniWindowDemoData.capturedMenuBarPanelScenario(
            arguments: ProcessInfo.processInfo.arguments
        )
        let requestedSection = MiniWindowDemoData.capturedMenuBarPanelSection(
            arguments: ProcessInfo.processInfo.arguments
        )
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix(prefix)
        }) else { return }
        let directory = URL(
            fileURLWithPath: String(argument.dropFirst(prefix.count)),
            isDirectory: true
        )
        guard directory.path.hasPrefix("/") else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !isTornDown else { return }

            if let requestedScenario {
                await captureDebugSnapshotScenario(requestedScenario, in: directory)
                return
            }

            await captureDebugSnapshot(named: "01-level1.png", in: directory)

            if capturesPower, requestedSection == nil {
                panelCoordinator?.selectHardwareDetail(.power)
                guard await waitForDebugAttachedLayout(
                    childCount: 1,
                    section: .sensors
                ) else { return }
                await captureDebugSnapshot(named: "02-level2-power.png", in: directory)
                return
            }

            let section = requestedSection ?? .processor
            let captureName = requestedSection?.rawValue ?? "cpu"
            panelCoordinator?.selectModule(section)
            guard await waitForDebugAttachedLayout(
                childCount: 1,
                section: section
            ) else { return }
            await captureDebugSnapshot(
                named: "02-level2-\(captureName).png",
                in: directory
            )

            if section == .power,
               MiniWindowDemoData.isCapturingPowerModeMenuBarPanelSnapshot,
               let detailFrame = attachedCascadeLayout?.childFrames.first {
                let rowTopOffset = GeekPowerLayout.energyModeSourceOffset(
                    hasInternalBattery: true
                )
                let rowAnchor = NSRect(
                    x: detailFrame.minX,
                    y: detailFrame.maxY - rowTopOffset - GeekPowerLayout.modeHeight,
                    width: detailFrame.width,
                    height: GeekPowerLayout.modeHeight
                )
                controlPaletteCoordinator?.toggle(
                    .power,
                    anchorScreenRect: rowAnchor,
                    parentWindow: panel
                )
                try? await Task.sleep(for: .milliseconds(250))
                await captureDebugSnapshot(
                    named: "03-level3-power-mode.png",
                    in: directory
                )
                return
            }

            panelCoordinator?.presentHistory(
                .builtIn(
                    (section == .sensors && MiniWindowDemoData.capturesFanCurveEditor)
                        ? MenuBarTertiaryDetail.fanCurve.rawValue
                        : requestedSection?.tertiaryDetail?.rawValue
                        ?? "debug.processor.activity"
                ),
                pinned: true
            )
            guard await waitForDebugAttachedLayout(
                childCount: 2,
                section: section
            ) else { return }
            await captureDebugSnapshot(
                named: "03-level3-\(captureName).png",
                in: directory
            )
        }
    }

    private func captureDebugSnapshotScenario(
        _ scenario: MiniWindowDemoData.MenuBarSnapshotScenario,
        in directory: URL
    ) async {
        let capture: () async -> Void = {
            await self.captureDebugSnapshot(named: scenario.captureFileName, in: directory)
        }

        switch scenario.route {
        case .overview:
            panelCoordinator?.reset()
            guard await waitForDebugAttachedLayout(childCount: 0, section: .overview) else {
                return
            }
            await capture()
        case let .secondary(section):
            panelCoordinator?.selectModule(section)
            guard await waitForDebugAttachedLayout(childCount: 1, section: section) else {
                return
            }
            await capture()
        case let .tertiary(section, detail):
            panelCoordinator?.selectModule(section)
            guard await waitForDebugAttachedLayout(childCount: 1, section: section) else {
                return
            }
            panelCoordinator?.presentHistory(.builtIn(detail.rawValue), pinned: true)
            guard await waitForDebugAttachedLayout(childCount: 2, section: section) else {
                return
            }
            await capture()
        case let .inline(section, routeIdentifier):
            panelCoordinator?.selectModule(section)
            guard await waitForDebugAttachedLayout(childCount: 1, section: section) else {
                return
            }
            panelCoordinator?.presentHistory(.builtIn(routeIdentifier), pinned: true)
            guard await waitForDebugAttachedLayout(childCount: 2, section: section) else {
                return
            }
            await capture()
        }
    }

    private func waitForDebugAttachedLayout(
        childCount: Int,
        section: PanelSection = .processor
    ) async -> Bool {
        for _ in 0..<40 {
            guard !isTornDown else { return false }
            let layoutIsReady = (attachedCascadeLayout?.childFrames.count ?? 0) == childCount
                && geekSection == section
                && isTertiaryPresented == (childCount == 2)
            if layoutIsReady {
                await Task.yield()
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return false
                }
                return !isTornDown
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return false
    }

    private func captureDebugSnapshot(named name: String, in directory: URL) async {
        for attempt in 0..<10 {
            guard let view = panel.contentView else { return }
            panel.displayIfNeeded()
            view.displayIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if Self.debugSnapshotHasVisiblePixels(bitmap),
                   let data = bitmap.representation(using: .png, properties: [:]) {
                    try? FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    try? data.write(
                        to: directory.appendingPathComponent(name),
                        options: .atomic
                    )
                    return
                }
            }
            guard attempt < 9 else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func debugSnapshotHasVisiblePixels(_ bitmap: NSBitmapImageRep) -> Bool {
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
        guard bitmap.hasAlpha else { return true }
        guard bitmap.bitsPerSample == 8,
              !bitmap.isPlanar,
              let pixels = bitmap.bitmapData else { return false }
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        guard bytesPerPixel > 0 else { return false }
        let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst)
            ? 0
            : bytesPerPixel - 1
        let horizontalStride = max(1, bitmap.pixelsWide / 32)
        let verticalStride = max(1, bitmap.pixelsHigh / 32)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: verticalStride) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: horizontalStride) {
                let offset = y * bitmap.bytesPerRow + x * bytesPerPixel + alphaOffset
                if pixels[offset] > 2 {
                    return true
                }
            }
        }
        return false
    }
#endif

    private func persistCurrentFrameIfNeeded() {
        guard persistsGeometry, !isApplyingProgrammaticFrame, !isTornDown else { return }
        if density.usesAttachedDetailPresentation,
           secondaryPresentationMode == .adjacent {
            if let attachedCascadeLayout {
                let translatedLayout = translatedCascadeLayout(
                    attachedCascadeLayout,
                    to: panel.frame
                )
                self.attachedCascadeLayout = translatedLayout
                attachedOverviewFrame = translatedLayout.parentFrame
                panelSettingsState?.setCascadeLayout(translatedLayout)
            } else {
                attachedOverviewFrame = collapsedAttachedFrame(from: panel.frame)
            }
        }
        geometryStore.save(frame: persistableFrame, for: density)
        if let resolvedScreen = panel.screen {
            screen = resolvedScreen
            configureSizeLimits(
                for: density,
                visibleFrame: resolvedVisibleFrame(for: resolvedScreen)
            )
        }
    }

    private func activeContentSize(for density: PanelDensity) -> NSSize {
        guard density.usesAttachedDetailPresentation else { return density.idealSize }
        if geekSection != .overview,
           secondaryPresentationMode == .unavailable {
            return overviewSize
        }
        if let attachedCascadeLayout {
            return attachedCascadeLayout.containerFrame.size
        }
        let size = GeekPanelPresentationMetrics.expandedSize(
            for: geekSection,
            density: density,
            includesTertiaryColumn: isTertiaryPresented
                && tertiaryPresentationMode == .column,
            detailSize: detailColumnSize,
            tertiarySize: tertiaryColumnSize,
            overviewSize: overviewSize
        )
        return NSSize(width: size.width, height: size.height)
    }

    private func clampedExpandedAttachedFrame(_ frame: NSRect, screen: NSScreen?) -> NSRect {
        guard let visibleFrame = resolvedVisibleFrame(for: screen) else { return frame }
        let visible = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return NSRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
    }

    private var persistableFrame: NSRect {
        guard density.usesAttachedDetailPresentation else { return panel.frame }
        return attachedOverviewFrame ?? collapsedAttachedFrame(from: panel.frame)
    }

    private var visibleAttachedContentFrames: [NSRect] {
        guard geekSection != .overview else { return [panel.frame] }
        guard secondaryPresentationMode == .adjacent else { return [panel.frame] }
        if let attachedCascadeLayout {
            return [attachedCascadeLayout.childFrames[0], attachedCascadeLayout.parentFrame]
                + attachedCascadeLayout.childFrames.dropFirst()
        }

        let detailSize = GeekPanelPresentationMetrics.normalizedDetailSize(
            detailColumnSize,
            for: geekSection,
            density: density
        )
        let showsTertiaryColumn = isTertiaryPresented
            && tertiaryPresentationMode == .column
        let tertiarySize = tertiaryColumnSize
        let gap = MiniWindowStyleTokens.cascadeGap
        var frames = [
            NSRect(
                x: cascadeDirection == .left
                    ? panel.frame.minX + (showsTertiaryColumn ? tertiarySize.width + gap : 0)
                    : panel.frame.minX + overviewSize.width + gap,
                y: panel.frame.minY,
                width: detailSize.width,
                height: detailSize.height
            ),
            NSRect(
                x: cascadeDirection == .left
                    ? panel.frame.maxX - overviewSize.width
                    : panel.frame.minX,
                y: panel.frame.minY,
                width: overviewSize.width,
                height: overviewSize.height
            )
        ]
        if showsTertiaryColumn {
            frames.append(NSRect(
                x: cascadeDirection == .left
                    ? panel.frame.minX
                    : panel.frame.minX + overviewSize.width + gap + detailSize.width + gap,
                y: panel.frame.minY,
                width: tertiarySize.width,
                height: tertiarySize.height
            ))
        }
        return frames
    }

    private func pointerLocationChanged(_ location: NSPoint) {
        guard !isTornDown, density.usesAttachedDetailPresentation else { return }
        let frames = attachedHoverFrames
        panelCoordinator?.recordPointer(location)
        panelCoordinator?.updateWindowGroupFrames(frames)
        if frames.contains(where: { $0.contains(location) }) {
            hoverIntentAnchor = location
            panelCoordinator?.setPointerWithinHoverEnvelope(true)
            return
        }

        let isInsideCorridor = attachedHoverCorridors.contains { $0.contains(location) }
        let isContained = isInsideCorridor
            || isInsideHoverIntentTriangle(location, frames: frames)
        if isInsideCorridor {
            PerformanceTelemetry.signposter.emitEvent("CorridorEntered")
        }
        if !isContained {
            hoverIntentAnchor = nil
        }
        panelCoordinator?.setPointerWithinHoverEnvelope(isContained)
    }

    private func isInsideHoverIntentTriangle(_ location: NSPoint, frames: [NSRect]) -> Bool {
        guard
            let origin = hoverIntentAnchor,
            let source = frames.first(where: { $0.contains(origin) })
        else { return false }

        let destination: NSRect?
        if location.x < origin.x {
            destination = frames
                .filter { $0.maxX <= source.minX }
                .max(by: { $0.maxX < $1.maxX })
        } else if location.x > origin.x {
            destination = frames
                .filter { $0.minX >= source.maxX }
                .min(by: { $0.minX < $1.minX })
        } else {
            destination = nil
        }
        guard let destination else { return false }
        let corridor = HoverCorridor(
            source: source,
            destination: destination,
            padding: HoverIntentPolicy.menuBar.corridorPadding
        )
        guard corridor.contains(location) else { return false }
        return panelCoordinator?.hoverIntentController.pointerDirection(toward: destination)
            != .away
    }

    /// Frame changes can move the attached cascade around a stationary cursor.
    /// Tracking-area callbacks only arrive on later pointer events, so sample
    /// the current screen location immediately before a delayed hover-dismiss
    /// task can observe a stale envelope value.
    private func refreshPointerWithinHoverEnvelope() {
        pointerLocationChanged(pointerLocationProvider())
    }

    /// The frames that keep the hover session alive. A presented control
    /// palette is part of the session even though it lives outside the panel
    /// window; excluding it would make the pointer's trip to the palette look
    /// like leaving the panel, collapsing the unpinned hierarchy underneath
    /// the palette mid-flight.
    private var attachedHoverFrames: [NSRect] {
        var frames = attachedCascadeLayout?.visibleFrames ?? visibleAttachedContentFrames
        if let paletteFrame = presentedControlPaletteFrame {
            frames.append(paletteFrame)
        }
        return frames
    }

    private var presentedControlPaletteFrame: NSRect? {
        guard let controlPaletteCoordinator,
              controlPaletteCoordinator.isPresented else { return nil }
        let frame = controlPaletteCoordinator.panel.frame
        return frame.isUsableWindowAnchor ? frame : nil
    }

    private var attachedHoverCorridors: [HoverCorridor] {
        let frames = attachedHoverFrames
        return zip(frames, frames.dropFirst()).map { first, second in
            HoverCorridor(
                source: first,
                destination: second,
                padding: HoverIntentPolicy.menuBar.corridorPadding
            )
        }
    }

    private func collapsedAttachedFrame(from frame: NSRect) -> NSRect {
        guard geekSection != .overview else {
            return NSRect(origin: frame.origin, size: overviewSize)
        }
        guard secondaryPresentationMode == .adjacent else {
            return attachedOverviewFrame
                ?? NSRect(origin: frame.origin, size: overviewSize)
        }
        if let attachedCascadeLayout {
            return translatedCascadeLayout(attachedCascadeLayout, to: frame).parentFrame
        }
        let detailWidth = GeekPanelPresentationMetrics.normalizedDetailSize(
            detailColumnSize,
            for: geekSection,
            density: density
        ).width
        let tertiaryWidth = isTertiaryPresented && tertiaryPresentationMode == .column
            ? tertiaryColumnSize.width
            : 0
        let visibleChildCount = tertiaryWidth > 0 ? 2 : 1
        return NSRect(
            x: cascadeDirection == .left
                ? frame.minX
                    + detailWidth
                    + tertiaryWidth
                    + MiniWindowStyleTokens.cascadeGap * CGFloat(visibleChildCount)
                : frame.minX,
            y: frame.minY,
            width: overviewSize.width,
            height: overviewSize.height
        )
    }

    private func translatedCascadeLayout(
        _ layout: MenuBarCascadeLayout,
        to containerFrame: NSRect
    ) -> MenuBarCascadeLayout {
        let sourceFrame = layout.containerFrame
        let offset = NSPoint(
            x: containerFrame.minX - sourceFrame.minX,
            y: containerFrame.minY - sourceFrame.minY
        )
        return MenuBarCascadeLayout(
            direction: layout.direction,
            alignment: layout.alignment,
            parentFrame: layout.parentFrame.offsetBy(dx: offset.x, dy: offset.y),
            childFrames: layout.childFrames.map { $0.offsetBy(dx: offset.x, dy: offset.y) },
            secondaryPresentationMode: layout.secondaryPresentationMode,
            tertiaryPresentationMode: layout.tertiaryPresentationMode
        )
    }

    private func installEventMonitors() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                @MainActor [weak self] event in
                guard let self else { return event }
                return self.handleKeyEvent(event)
            }
        }

        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) {
                @MainActor [weak self] event in
                guard let self else { return event }
                PerformanceTelemetry.panelInput("local-input", target: "panel-session", window: event.window, event: event)
                self.handleMouseDown(
                    sourceWindow: event.window,
                    screenLocation: self.screenLocation(for: event),
                    eventWindowNumber: event.windowNumber
                )
                return event
            }
        }

        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) {
                @MainActor [weak self] event in
                guard let self else { return }
                let location = self.screenLocation(for: event)
                PerformanceTelemetry.panelInput("global-input", target: "source=\(event.windowNumber) relative=\(location.x - self.panel.frame.minX),\(location.y - self.panel.frame.minY)", window: self.panel, event: event)
                self.handleMouseDown(
                    sourceWindow: nil,
                    screenLocation: location,
                    // A global event may have no window number even for a
                    // genuine outside click. Preserve that dismissal once no
                    // native menu is tracking; resolve positive menu IDs only.
                    eventWindowNumber: event.windowNumber > 0 ? event.windowNumber : nil
                )
            }
        }
    }

    private func installObservers() {
        guard defaultObservers.isEmpty else { return }
        let center = NotificationCenter.default
        defaultObservers = [
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.screenParametersDidChange()
                }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applicationDidDeactivate()
                }
            }
        ]
        menuTrackingObservers.tokens = [
            center.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let menuID = ObjectIdentifier(menu)
                MainActor.assumeIsolated {
                    guard let self, self.isPresented else { return }
                    self.menuTrackingDismissalTask?.cancel()
                    self.menuTrackingDismissalTask = nil
                    self.trackingMenus.insert(menuID)
#if DEBUG || STORAGE_CLEANER_BETA
                    PerformanceTelemetry.logger.notice("MenuBar lifecycle: native-menu-begin")
#endif
                }
            },
            center.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let menuID = ObjectIdentifier(menu)
                MainActor.assumeIsolated {
                    self?.menuDidEndTracking(menuID)
                }
            }
        ]
    }

    private func applicationDidDeactivate() {
#if DEBUG || STORAGE_CLEANER_BETA
        PerformanceTelemetry.logger.notice("MenuBar lifecycle: application-deactivated menuTracking=\(!self.trackingMenus.isEmpty)")
#endif
        guard trackingMenus.isEmpty else {
            deactivatedDuringMenuTracking = true
            return
        }
        hide(reason: "application-deactivated")
    }

    private func menuDidEndTracking(_ menuID: ObjectIdentifier) {
        guard trackingMenus.remove(menuID) != nil else { return }
#if DEBUG || STORAGE_CLEANER_BETA
        PerformanceTelemetry.logger.notice("MenuBar lifecycle: native-menu-end remainingTracking=\(!self.trackingMenus.isEmpty)")
#endif
        guard trackingMenus.isEmpty, deactivatedDuringMenuTracking else { return }
        menuTrackingDismissalTask = Task { @MainActor [weak self] in
            // Let AppKit finish restoring menu focus before interpreting the
            // transient resign-active notification as a real application switch.
            await Task.yield()
            guard !Task.isCancelled, let self, self.trackingMenus.isEmpty else { return }
            self.menuTrackingDismissalTask = nil
            self.deactivatedDuringMenuTracking = false
            guard self.isPresented, !self.applicationIsActiveProvider() else { return }
            self.hide(reason: "application-inactive-after-menu")
        }
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func isPanelFamilyWindow(_ window: NSWindow?) -> Bool {
        var candidate = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.parent ?? current.sheetParent
        }
        return false
    }

    private func screenParametersDidChange() {
        guard !isTornDown, persistsGeometry, let previousAnchor = anchor else { return }
        let currentScreens = NSScreen.screens
        let liveAnchor = triggerFrameProvider?() ?? previousAnchor
        let anchorScreen = currentScreens.first { candidate in
            candidate.frame.contains(NSPoint(x: liveAnchor.midX, y: liveAnchor.midY))
        }
        let currentPanelScreen = panel.screen.flatMap { candidate in
            currentScreens.first(where: { $0 === candidate })
        }
        let intersectingScreen = currentScreens
            .map { candidate in
                (screen: candidate, area: intersectionArea(panel.frame, candidate.frame))
            }
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }?
            .screen
        guard let resolvedScreen = ScreenContextResolver.resolve(
            statusItemScreen: anchorScreen,
            anchorRect: liveAnchor,
            pointerLocation: pointerLocationProvider(),
            fallbackScreen: currentPanelScreen ?? intersectingScreen,
            screens: currentScreens
        ) else { return }
        if screen !== resolvedScreen {
            PerformanceTelemetry.signposter.emitEvent("ScreenChanged")
        }
        anchor = liveAnchor
        screen = resolvedScreen
        let visibleFrame = resolvedVisibleFrame(for: resolvedScreen) ?? resolvedScreen.visibleFrame
        configureSizeLimits(for: density, visibleFrame: visibleFrame)

        let overviewFrame = MenuBarPanelPlacement.frame(
            anchor: liveAnchor,
            contentSize: density.usesAttachedDetailPresentation
                ? overviewSize
                : density.idealSize,
            visibleFrame: visibleFrame,
            backingScaleFactor: resolvedScreen.backingScaleFactor
        )
        if density.usesAttachedDetailPresentation {
            let sectionToRestore = geekSection
            attachedOverviewFrame = overviewFrame
            if sectionToRestore != .overview {
                setGeekSection(sectionToRestore)
            } else {
                secondaryPresentationMode = .adjacent
                tertiaryPresentationMode = .column
                detailColumnSize = nil
                isTertiaryPresented = false
                tertiaryColumnSize = GeekPanelPresentationMetrics.tertiarySize
                tertiarySourceOffset = nil
                attachedCascadeLayout = nil
                panelSettingsState?.setSecondaryPresentationMode(.adjacent)
                panelSettingsState?.setTertiaryPresentationMode(.column)
                panelSettingsState?.setCascadeLayout(nil)
                applyProgrammaticFrame(overviewFrame)
            }
            geometryStore.save(frame: persistableFrame, for: density)
            controlPaletteCoordinator?.parentWindowDidMove()
            return
        }

        applyProgrammaticFrame(overviewFrame)
        geometryStore.save(frame: overviewFrame, for: density)
        controlPaletteCoordinator?.parentWindowDidMove()
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private func removeEventMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in defaultObservers {
            center.removeObserver(observer)
        }
        defaultObservers.removeAll()
        menuTrackingObservers.removeAll()
        menuTrackingDismissalTask?.cancel()
        menuTrackingDismissalTask = nil
        trackingMenus.removeAll()
        deactivatedDuringMenuTracking = false
    }
}

extension MenuBarPanelSession {
    /// Internal fixture surface used only through `@testable import`.
    ///
    /// Keeping this available in optimized test builds lets Release-only
    /// workflows compile without exposing a public production debug hook.
    static func testing(
        panel: MenuBarStatusPanel = MenuBarStatusPanel(contentRect: .zero),
        triggerFrameProvider: (@MainActor () -> NSRect?)? = nil,
        onClose: @escaping @MainActor () -> Void = {}
    ) -> MenuBarPanelSession {
        MenuBarPanelSession(
            panel: panel,
            rootView: AnyView(EmptyView()),
            triggerFrameProvider: triggerFrameProvider,
            onClose: onClose
        )
    }

    var activeMonitorCount: Int {
        [localKeyMonitor, localMouseMonitor, globalMouseMonitor]
            .compactMap { $0 }
            .count
    }

    var activeObserverCount: Int {
        defaultObservers.count + menuTrackingObservers.tokens.count
    }

    var visibleAttachedContentFramesForTesting: [NSRect] {
        visibleAttachedContentFrames
    }

    func installLifecycleObserversForTesting() {
        installObservers()
    }

}

/// NotificationCenter retains observer blocks. This session-owned bag also
/// removes the new native-menu observers if the session is released directly.
private final class MenuBarMenuTrackingObservers {
    var tokens: [NSObjectProtocol] = []

    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }

    deinit {
        removeAll()
    }
}
