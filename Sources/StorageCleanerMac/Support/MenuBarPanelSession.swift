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

/// An attached menu of the cascade, parents first (D123).
enum GeekPanelColumn: Int, Equatable, Sendable {
    case overview
    case module
    case history
}

@MainActor
final class GeekPanelCoordinator: ObservableObject {
    struct HoverIntent: Equatable {
        fileprivate let request: HoverIntentController.Request
    }

    @Published private(set) var route: GeekPanelRoute {
        didSet {
            guard oldValue != route else { return }
            MenuBarPresentationTrace.routeChanged(from: oldValue, to: route, event: NSApp?.currentEvent)
            PerformanceTelemetry.panelInput("route", target: String(describing: route))
        }
    }
    @Published private(set) var isPointerWithinHoverEnvelope = false
    @Published private(set) var hardwareDetailFocus = GeekHardwareDetailFocus.monitoring
    private(set) var pinnedModule: PanelSection?
    private(set) var isHistoryPinned = false
    private(set) var isControlPalettePresented = false
    private(set) var historyInteractionToken: UUID?
    var isInteractingWithHistory: Bool { historyInteractionToken != nil }
    /// D123: the attached menu under the pointer at its last reading, nil
    /// outside them. Over the overview it is nil while a history page is
    /// open: iStat Menus 7.30 lets only the deepest menu and its parent react
    /// to the pointer (`isPrimaryMenu`).
    private(set) var pointerColumn: GeekPanelColumn?
    /// D123: the last attached menu the pointer was in, and whether the last
    /// reading was over a menu or a presented palette.
    private var lastPointerMenu: GeekPanelColumn?
    private var wasPointerOverHoverSurface = false
    /// D123: the overview card under the pointer at its last reading, found
    /// from the cards' screen anchors.
    private var pointerOverviewCard: PanelSection?
    /// D123: the level-two rows with a level-three page that are under the
    /// pointer, as their hover callbacks report them.
    private(set) var hoveredTertiaryTargets: Set<String> = []

    private var isHistoryOpen: Bool {
        if case .history = route { true } else { false }
    }

    /// D123: the item the arrow keys highlight in the deepest menu (iStat
    /// Menus 7.30 `BBRMenu keyDown:`): an overview card, or a module-column
    /// row with a history page. Pointer movement takes the highlight back.
    enum KeyboardHighlight: Equatable, Sendable {
        case card(PanelSection)
        case row(String)
    }

    enum ArrowKey: Equatable, Sendable {
        case left
        case right
        case up
        case down
    }

    /// D123: → on a highlighted row asks that row to open its page.
    struct RowOpenRequest: Equatable, Sendable {
        let identifier: String
        let serial: Int
    }

    @Published private(set) var keyboardHighlight: KeyboardHighlight?
    @Published private(set) var rowOpenRequest: RowOpenRequest?
    /// D123: each module-column row with a history page and its top in the
    /// module column, for the arrow keys' order.
    private var tertiaryTargetOffsets: [String: CGFloat] = [:]

    func beginHistoryInteraction() -> UUID? {
        guard case .history = route else { return nil }
        invalidateHoverIntent()
        let token = UUID()
        historyInteractionToken = token
        return token
    }
    func endHistoryInteraction(_ token: UUID?) {
        guard token == historyInteractionToken else { return }
        historyInteractionToken = nil
    }

    private var suppressesModuleAfterEscape = false
    private var moduleEscapePointerLocation: NSPoint?
    private var moduleEscapeAnchors: [SmallWindowAnchorSnapshot] = []
    private var suppressesTertiaryAfterEscape = false
    private var tertiaryEscapePointerLocation: NSPoint?
    private var tertiaryEscapeAnchor: SmallWindowAnchorSnapshot?
    private let pointerLocationProvider: @MainActor () -> NSPoint
    let hoverIntentController: HoverIntentController
    let anchorRegistry: SmallWindowAnchorRegistry
    private var stationaryReflow = CascadeStationaryPointerGuard()

    func preservePointerAfterReflow(previous: [NSRect], next: [NSRect], pointer: NSPoint) {
        guard previous != next else { return }
        stationaryReflow.begin(previous: previous, next: next, pointer: pointer)
        if stationaryReflow.retains(pointer) {
            invalidateHoverIntent()
            setPointerWithinHoverEnvelope(true)
        }
    }

    func retainsPointerAfterReflow(_ point: NSPoint) -> Bool {
        stationaryReflow.retains(point)
    }
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
        guard !isInteractingWithHistory else { return expiredHoverIntent() }
        // D123: with a history page open the overview is not a primary menu
        // (iStat Menus 7.30 `isPrimaryMenu`) and ignores the pointer.
        guard !isHistoryOpen else { return expiredHoverIntent() }
        guard !suppressesModuleAfterEscape else {
            return cancelledHoverIntent()
        }
        guard !stationaryReflow.retains(pointerLocationProvider()) else {
            return expiredHoverIntent()
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
        guard !isInteractingWithHistory else { return expiredHoverIntent() }
        guard !suppressesTertiaryAfterEscape else {
            return cancelledHoverIntent()
        }
        guard !stationaryReflow.retains(pointerLocationProvider()) else {
            return expiredHoverIntent()
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

    /// D123: a level-two row with a level-three page reports the pointer
    /// entering or leaving it. An exit also ends Escape's suppression.
    func tertiaryTargetHoverChanged(_ identifier: String, hovering: Bool) {
        if hovering {
            hoveredTertiaryTargets.insert(identifier)
        } else {
            hoveredTertiaryTargets.remove(identifier)
            tertiaryHoverExited()
        }
    }

    /// D123: whether leaving a row may close the open level-three page: no
    /// row with a page is under the pointer, and the pointer is not on the
    /// page. A row the pointer reached reports its own change of target.
    var allowsTertiaryGapClose: Bool {
        hoveredTertiaryTargets.isEmpty && pointerColumn != .history
    }

    /// D123: a click or VoiceOver press on a row with a level-three page
    /// opens it as hover does, unpinned, even after Escape, during a reflow
    /// or over a pinned page (iStat Menus 7.30's click opens nothing; its
    /// hover already has).
    func prepareExplicitTertiaryOpen() {
        suppressesTertiaryAfterEscape = false
        tertiaryEscapePointerLocation = nil
        tertiaryEscapeAnchor = nil
        stationaryReflow.reset()
        isHistoryPinned = false
    }

    /// D123: applies iStat Menus 7.30's menu rules (`mouseExited:`,
    /// `mouseMoved:`) to a pointer reading. `column` is the attached menu
    /// containing the pointer and `isOverPalette` whether it is over a
    /// presented control palette or the corridor to it. Only a pointer
    /// movement (`isPointerEvent`) closes anything; a reading after a layout
    /// change only updates the state.
    func pointerMoved(
        to column: GeekPanelColumn?,
        at point: NSPoint,
        isOverPalette: Bool,
        isPointerEvent: Bool
    ) {
        let previous = pointerColumn
        // Pointer movement takes the highlight back from the arrow keys.
        if isPointerEvent, point != lastPointerPoint, keyboardHighlight != nil {
            keyboardHighlight = nil
        }
        // `mouseExited:` of the module column: leaving it for anywhere but its
        // history page closes the page at once, without a hold.
        if isPointerEvent, previous == .module, column != .module, column != .history {
            dismissUnpinnedHistory()
        }
        let current: GeekPanelColumn? = column == .overview && isHistoryOpen ? nil : column
        let card = current == .overview ? overviewCard(at: point) : nil
        let previousCard = pointerOverviewCard
        pointerColumn = current
        pointerOverviewCard = card
        lastPointerPoint = point
        if isPointerEvent {
            switch current {
            case .overview where card == nil && (previous != .overview || previousCard != nil):
                // `mouseMoved:` of the overview: reaching a gap is a change of
                // target to no item, which closes the open module.
                scheduleModuleGapClose()
            case .module where previous != .module && hoveredTertiaryTargets.isEmpty:
                // Back in the module column over a gap or a row without a
                // page; a row with one reports its own change of target.
                scheduleHistoryGapClose()
            default:
                break
            }
        }
        let isOverHoverSurface = current != nil || isOverPalette
        if isOverHoverSurface {
            setPointerWithinHoverEnvelope(true)
        } else if wasPointerOverHoverSurface, lastPointerMenu == .overview {
            // `mouseExited:` of the overview: leaving it for empty space closes
            // the module column. Leaving the module column or the history page
            // keeps them, as iStat keeps a submenu the pointer leaves.
            setPointerWithinHoverEnvelope(false)
        }
        wasPointerOverHoverSurface = isOverHoverSurface
        if let current {
            lastPointerMenu = current
        }
    }

    /// D123: a module-column row with a history page reports its top in the
    /// module column (nil when it goes away), for the arrow keys' order.
    func registerTertiaryTarget(_ identifier: String, offset: CGFloat?) {
        tertiaryTargetOffsets[identifier] = offset
        if offset == nil, keyboardHighlight == .row(identifier) {
            keyboardHighlight = nil
        }
    }

    /// D123 (iStat Menus 7.30 `BBRMenu keyDown:`): ← closes the deepest
    /// menu and leaves its item highlighted in the parent; → opens the
    /// highlighted item's menu; ↓ and ↑ move the highlight in the deepest
    /// menu, starting from the first or last item, without wrapping or
    /// opening. Only rows that open a history page take the highlight in the
    /// module column. Returns whether the key was used.
    @discardableResult
    func handleArrowKey(_ key: ArrowKey) -> Bool {
        switch key {
        case .left:
            let owner: KeyboardHighlight?
            switch route {
            case .summary:
                return false
            case let .module(section):
                owner = .card(section)
            case let .history(_, .inline(identifier)):
                owner = .row(identifier.uuidString)
            case .history:
                owner = nil
            }
            // The same step back as Escape had, with its hover suppression,
            // so the item under a resting pointer does not open again.
            guard handleEscape() else { return false }
            keyboardHighlight = owner
            return true
        case .right:
            switch (route, keyboardHighlight) {
            case let (.summary, .card(section)?):
                openModule(section)
                keyboardHighlight = .card(section)
            case let (.module, .row(identifier)?):
                rowOpenSerial &+= 1
                rowOpenRequest = RowOpenRequest(identifier: identifier, serial: rowOpenSerial)
            default:
                return false
            }
            return true
        case .down, .up:
            let items: [KeyboardHighlight]
            switch route {
            case .summary:
                items = overviewCardOrder.map(KeyboardHighlight.card)
            case .module:
                items = tertiaryTargetOffsets
                    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
                    .map { .row($0.key) }
            case .history:
                items = []
            }
            guard !items.isEmpty else { return false }
            let next: Int
            if let current = keyboardHighlight.flatMap(items.firstIndex(of:)) {
                next = key == .down ? min(current + 1, items.count - 1) : max(current - 1, 0)
            } else {
                next = key == .down ? 0 : items.count - 1
            }
            keyboardHighlight = items[next]
            return true
        }
    }

    private var rowOpenSerial = 0

    /// The overview cards top to bottom, then leading to trailing.
    private var overviewCardOrder: [PanelSection] {
        var cards: [(section: PanelSection, frame: NSRect)] = []
        for section in PanelSection.allCases {
            guard let anchor = anchorRegistry.snapshot(for: .module(section)) else { continue }
            cards.append((section, anchor.screenRect))
        }
        cards.sort { first, second in
            let sameRow = abs(first.frame.maxY - second.frame.maxY) <= 0.5
            return sameRow ? first.frame.minX < second.frame.minX : first.frame.maxY > second.frame.maxY
        }
        return cards.map(\.section)
    }

    /// D123: forgets where the pointer was, for a newly shown panel.
    func resetPointerTracking() {
        pointerColumn = nil
        lastPointerMenu = nil
        wasPointerOverHoverSurface = false
        pointerOverviewCard = nil
        lastPointerPoint = nil
    }

    private var lastPointerPoint: NSPoint?

    private func overviewCard(at point: NSPoint) -> PanelSection? {
        PanelSection.allCases.first { section in
            anchorRegistry.snapshot(for: .module(section))?.screenRect.contains(point) == true
        }
    }

    private func scheduleModuleGapClose() {
        // A card rebuilt in the attached shell registers its anchor a turn
        // later. Until the open module's card is back, a reading over the
        // cards cannot tell a gap from a card.
        guard route != .summary, pinnedModule == nil, !isInteractingWithHistory,
              anchorRegistry.snapshot(for: .module(selectedSection)) != nil else { return }
        scheduleHoverDismissal(
            condition: { [weak self] in
                guard let self, let point = lastPointerPoint else { return false }
                return pointerColumn == .overview && overviewCard(at: point) == nil
                    && pinnedModule == nil && !isHistoryOpen
            },
            action: { [weak self] in
                self?.dismissUnpinnedModule()
            }
        )
    }

    private func scheduleHistoryGapClose() {
        guard isHistoryOpen, !isHistoryPinned, !isInteractingWithHistory else { return }
        scheduleHoverDismissal(
            condition: { [weak self] in
                guard let self else { return false }
                return isHistoryOpen && !isHistoryPinned && allowsTertiaryGapClose
            },
            action: { [weak self] in
                self?.dismissUnpinnedHistory()
            }
        )
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

    func updateWindowGroupFrames(_ frames: [NSRect], palette: NSRect? = nil) {
        hoverIntentController.updateWindowGroupFrames(frames, palette: palette)
    }

    func registerAnchor(
        id: SmallWindowAnchorID,
        screenRect: NSRect,
        parentPanelRole: SmallWindowPanelRole = .primary,
        preferredPlacementEdge: MenuBarCascadeDirection = .left,
        contentKind: String,
        layoutOffset: CGFloat? = nil
    ) {
        anchorRegistry.update(
            id: id,
            screenRect: screenRect,
            parentPanelRole: parentPanelRole,
            preferredPlacementEdge: preferredPlacementEdge,
            contentKind: contentKind,
            layoutOffset: layoutOffset
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
        guard section != .overview, pinnedModule == nil, !suppressesModuleAfterEscape,
              !stationaryReflow.retains(pointerLocationProvider()) else { return }
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
        guard pinnedModule == nil, !suppressesModuleAfterEscape,
              !stationaryReflow.retains(pointerLocationProvider()) else { return }
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

    /// D123: a click or VoiceOver press on an overview card. iStat Menus
    /// 7.30's click opens nothing (its hover already has), so this opens the
    /// module as hover does, unpinned, and changes nothing when it is open.
    /// Unlike hover it also opens after Escape or ←, and it keeps the module
    /// until the pointer leaves the overview for empty space. `selectModule`
    /// still pins, for the debug and latency routes.
    func openModule(_ section: PanelSection) {
        PerformanceTelemetry.panelInput("action", target: "module.\(section.rawValue)")
        guard section != .overview else {
            reset()
            return
        }
        endModuleEscapeSuppression()
        stationaryReflow.reset()
        setPointerWithinHoverEnvelope(true)
        guard selectedSection != section else { return }
        openUnpinned(section, focus: .monitoring)
    }

    /// D123: `openModule` for the sensors card, which opens the hardware
    /// page at `focus` (was `selectHardwareDetail`, which pinned and closed
    /// on a second click).
    func openHardwareDetail(_ focus: GeekHardwareDetailFocus) {
        PerformanceTelemetry.panelInput("action", target: "hardware.\(focus.rawValue)")
        endModuleEscapeSuppression()
        stationaryReflow.reset()
        setPointerWithinHoverEnvelope(true)
        guard selectedSection != .sensors || hardwareDetailFocus != focus else { return }
        openUnpinned(.sensors, focus: focus)
    }

    private func openUnpinned(_ section: PanelSection, focus: GeekHardwareDetailFocus) {
        historyInteractionToken = nil
        pinnedModule = nil
        isHistoryPinned = false
        hardwareDetailFocus = focus
        route = .module(section)
        hoverIntentController.markOpen(anchorID: .module(section), panelRole: .secondary)
    }

    private func endModuleEscapeSuppression() {
        suppressesModuleAfterEscape = false
        moduleEscapePointerLocation = nil
        moduleEscapeAnchors = []
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
        guard pinned || !stationaryReflow.retains(pointerLocationProvider()) else { return false }
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
        historyInteractionToken = nil
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
        historyInteractionToken = nil
        guard case let .history(section, _) = route else { return }
        isHistoryPinned = false
        route = .module(section)
        hoverIntentController.markOpen(anchorID: .module(section), panelRole: .secondary)
    }

    /// D123: closes an unpinned history page, for the pointer leaving the
    /// module column or reaching a gap in it.
    func dismissUnpinnedHistory() {
        guard isHistoryOpen, !isHistoryPinned, !isInteractingWithHistory else { return }
        dismissHistory()
    }

    func dismissUnpinnedModule() {
        guard !isInteractingWithHistory, pinnedModule == nil else { return }
        reset()
    }

    func dismissUnpinnedHierarchy() {
        guard !isInteractingWithHistory, !isHistoryPinned else { return }
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
        historyInteractionToken = nil
        stationaryReflow.reset()
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
        keyboardHighlight = nil
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
    // D123: iStat opens a submenu on the right when it fits (was left).
    private(set) var cascadeDirection = MenuBarCascadeDirection.right
    private(set) var secondaryPresentationMode = MenuBarSecondaryPresentationMode.adjacent
    private(set) var tertiaryPresentationMode = MenuBarTertiaryPresentationMode.column
    private(set) var detailColumnSize: CGSize?
    private(set) var isTertiaryPresented = false
    private(set) var tertiaryColumnSize = GeekPanelPresentationMetrics.tertiarySize
    private(set) var tertiarySourceOffset: CGFloat?
    private var attachedOverviewFrame: NSRect?
    private var attachedCascadeLayout: MenuBarCascadeLayout?
    /// The level-one card offset of each page's last placement that had a
    /// registered anchor. A card that is rebuilt (the overview moves into the
    /// attached shell when a level-two page opens) removes its anchor and
    /// registers it again a turn later; placements in between keep this
    /// offset instead of the default one, which drew the page misplaced and
    /// cost two extra frames. Cleared when the overview layout can change.
    private var anchoredDetailTopOffsets: [PanelSection: CGFloat] = [:]
    /// The dashboard layout the remembered offsets were measured in: cards
    /// reordered or hidden at the same overview size move (review of phase
    /// 1, P2-2).
    private var anchoredDetailTopOffsetsLayout: GeekDashboardConfiguration?
    private var persistsGeometry = false
    private var isApplyingProgrammaticFrame = false
    private var isResolvingCascade = false
    /// Tests only: runs inside every programmatic frame, as the view update
    /// that `setFrame(display: true)` performs does in the live panel.
    var programmaticFrameDidApplyForTesting: (() -> Void)?
    /// Geometry calls that reach the session while it resolves the cascade
    /// or applies a frame: `panel.setFrame(display: true)` runs the SwiftUI
    /// update synchronously, and that update forwards the selected page,
    /// measured sizes and presented levels (`MenuBarStatusController`). They
    /// were dropped, which left the session's geometry behind the view's
    /// until an unrelated request came. They are now replayed in the order
    /// they were made once the current placement is done; each call checks
    /// the session's state again when it runs.
    private var deferredGeometryCalls: [DeferredGeometryCall] = []
    private struct DeferredGeometryCall {
        /// A page selection (`setGeekSection`): the call the replay bound
        /// keeps, with every call made after it (BOARD N11-2).
        let selectsSection: Bool
        let run: @MainActor () -> Void
    }
    private var isReplayingDeferredGeometryCalls = false
    /// Audit only: the outermost entry point that placed the panel, reported
    /// with every `setFrame` span.
    private var traceGeometryCause: String?
    private var isAnchorRefreshDeferred = false
    private var isGeometryReplayScheduled = false
    /// Calls replayed since the queue was last empty: one operation of the
    /// user and the calls it produced.
    private var geometryReplayBurstCount = 0
    /// Set while the newest call of a stopped burst runs: the calls it
    /// produces are dropped instead of queued.
    private var dropsDeferredGeometryCalls = false
    /// Calls replayed before the rest continue on the next main-queue turn.
    static let maximumSynchronousGeometryReplays = 8
    /// Calls replayed for one operation before replaying stops. Placing the
    /// cascade settles in a few calls; more means calls that keep undoing
    /// each other.
    static let maximumGeometryReplaysPerBurst = 32

    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var defaultObservers: [NSObjectProtocol] = []
    private let menuTrackingObservers = MenuBarMenuTrackingObservers()
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var menuWasApplicationActiveAtBegin = false
    private var deactivatedDuringMenuTracking = false
    private var applicationDeactivationTask: Task<Void, Never>?
    private var lastNativeMenuEndedAt: Date?
    private var menuTrackingHoverReleaseTask: Task<Void, Never>?

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
        panel.onArrowKey = { [weak self] event in
            guard let self else { return false }
            return self.handleArrowKey(event, sourceWindow: self.panel)
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
        let showStartedAt = MenuBarPresentationTrace.uptime
        let ownsTraceCause = beginTraceGeometryCause("show")
        defer { endTraceGeometryCause(ownsTraceCause) }

        if panel.contentViewController !== hostingController {
            panel.contentViewController = hostingController
            panel.installPointerTracking()
            MenuBarPresentationTrace.span("show.attach", from: showStartedAt)
        }

        self.anchor = anchor
        self.screen = screen
        self.density = density
        isPresented = true
        deferredGeometryCalls.removeAll()
        isAnchorRefreshDeferred = false
        anchoredDetailTopOffsets.removeAll()
        geometryReplayBurstCount = 0
        lastNativeMenuEndedAt = nil
        applicationDeactivationTask?.cancel()
        applicationDeactivationTask = nil
        controlPaletteCoordinator?.dismiss()
        panelCoordinator?.reset()
        panelCoordinator?.resetPointerTracking()
        cascadeDirection = .right
        secondaryPresentationMode = .adjacent
        tertiaryPresentationMode = .column
        detailColumnSize = nil
        isTertiaryPresented = false
        tertiaryColumnSize = GeekPanelPresentationMetrics.tertiarySize
        tertiarySourceOffset = nil
        attachedCascadeLayout = nil
        panelSettingsState?.setCascadeDirection(.right)
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
        let frameStartedAt = MenuBarPresentationTrace.uptime
        applyProgrammaticFrame(frame)
        MenuBarPresentationTrace.span("show.frame", from: frameStartedAt)
        installEventMonitors()
        installObservers()
        // A non-activating panel can become key without activating the app.
        // This keeps Escape and keyboard controls inside the visible window
        // group while preserving the foreground application's activation.
        if presentsPanelOnShow {
            let orderStartedAt = MenuBarPresentationTrace.uptime
#if DEBUG || STORAGE_CLEANER_BETA
            // The latency script measures without taking key focus from the
            // application the person at this Mac is using.
            if MenuBarLatencyScript.isRequested {
                panel.orderFrontRegardless()
            } else {
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
            }
#else
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
#endif
            MenuBarPresentationTrace.span("show.order", from: orderStartedAt)
        }
        MenuBarPresentationTrace.span("show.total", from: showStartedAt)
        PerformanceTelemetry.panelInput("presented", target: "overview.visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) frame=\(NSStringFromRect(panel.frame)) content=\(NSStringFromRect(hostingController.view.frame)) appHidden=\(NSApp.isHidden) minimized=\(panel.isMiniaturized) level=\(panel.level.rawValue) anchor=\(NSStringFromRect(anchor)) screen=\(NSStringFromRect(visibleFrame)) occlusion=\(panel.occlusionState.rawValue)", window: panel)
#if DEBUG || STORAGE_CLEANER_BETA
        scheduleDebugSnapshotsIfRequested()
#endif
    }

    func selectDensity(_ density: PanelDensity) {
        guard !isTornDown, let anchor, let screen else { return }
        controlPaletteCoordinator?.dismiss()
        anchoredDetailTopOffsets.removeAll()
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
        cascadeDirection = .right
        secondaryPresentationMode = .adjacent
        tertiaryPresentationMode = .column
        detailColumnSize = nil
        isTertiaryPresented = false
        tertiaryColumnSize = GeekPanelPresentationMetrics.tertiarySize
        tertiarySourceOffset = nil
        attachedCascadeLayout = nil
        panelSettingsState?.setCascadeDirection(.right)
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
        visibleFrameOverride: NSRect? = nil,
        preferredDetailSize: CGSize? = nil
    ) {
        guard !isTornDown else { return }
        let ownsTraceCause = beginTraceGeometryCause("section")
        defer { endTraceGeometryCause(ownsTraceCause) }
        guard !deferGeometryCallIfNeeded(selectsSection: true, { [weak self] in
            self?.setGeekSection(
                section,
                visibleFrameOverride: visibleFrameOverride,
                preferredDetailSize: preferredDetailSize
            )
        }) else {
            replayDeferredGeometryCalls()
            return
        }
        guard density.usesAttachedDetailPresentation else { return }
        resolveCascade(
            section,
            visibleFrameOverride: visibleFrameOverride,
            preferredDetailSize: preferredDetailSize
        )
        replayDeferredGeometryCalls()
    }

    /// Defers `call` while the cascade is resolved or a frame is applied,
    /// and while older deferred calls still wait for their turn (after a
    /// spill to the next main-queue turn): a later call never runs before an
    /// earlier one. Calls made by a replayed call run directly, in place.
    /// Returns whether the call was deferred (or dropped, see
    /// `dropsDeferredGeometryCalls`).
    private func deferGeometryCallIfNeeded(
        selectsSection: Bool = false,
        _ call: @escaping @MainActor () -> Void
    ) -> Bool {
        let mustWait = isResolvingCascade || isApplyingProgrammaticFrame
            || (!deferredGeometryCalls.isEmpty && !isReplayingDeferredGeometryCalls)
        guard mustWait else { return false }
        guard !dropsDeferredGeometryCalls else { return true }
        deferredGeometryCalls.append(DeferredGeometryCall(selectsSection: selectsSection, run: call))
        return true
    }

    /// Runs the deferred calls in the order they were made. A call that
    /// places the cascade can defer further calls (from the view update of
    /// its own frame); they run in the same loop. After
    /// `maximumSynchronousGeometryReplays` the rest continue on the next
    /// main-queue turn. After `maximumGeometryReplaysPerBurst` for one
    /// operation the calls keep producing each other: the newest page
    /// selection and the calls queued after it run, once (only the newest
    /// call when no page selection is queued), the calls they produce are
    /// dropped, and replaying stops until the next call from outside. Running
    /// only the newest call could leave the session on an older page with
    /// the newest page's measurements (BOARD N11-2).
    private func replayDeferredGeometryCalls() {
        guard !isResolvingCascade, !isApplyingProgrammaticFrame,
              !isReplayingDeferredGeometryCalls else { return }
        isReplayingDeferredGeometryCalls = true
        defer {
            isReplayingDeferredGeometryCalls = false
            if deferredGeometryCalls.isEmpty { geometryReplayBurstCount = 0 }
        }
        var replayedThisTurn = 0
        while !isTornDown, !deferredGeometryCalls.isEmpty {
            guard geometryReplayBurstCount < Self.maximumGeometryReplaysPerBurst else {
                let lastSelection = deferredGeometryCalls.lastIndex { $0.selectsSection }
                let kept = Array(deferredGeometryCalls[(lastSelection ?? deferredGeometryCalls.count - 1)...])
                PerformanceTelemetry.logger.notice(
                    "MenuBar cascade: geometry calls did not settle after \(self.geometryReplayBurstCount, privacy: .public) replays; dropped \(self.deferredGeometryCalls.count - kept.count, privacy: .public) queued calls and applied the newest page selection and the \(kept.count, privacy: .public) calls from it once"
                )
                deferredGeometryCalls.removeAll()
                isAnchorRefreshDeferred = false
                dropsDeferredGeometryCalls = true
                for call in kept where !isTornDown { call.run() }
                dropsDeferredGeometryCalls = false
                deferredGeometryCalls.removeAll()
                isAnchorRefreshDeferred = false
                return
            }
            guard replayedThisTurn < Self.maximumSynchronousGeometryReplays else {
                scheduleDeferredGeometryReplay()
                return
            }
            replayedThisTurn += 1
            geometryReplayBurstCount += 1
            let call = deferredGeometryCalls.removeFirst()
            let outerTraceCause = traceGeometryCause
            if MenuBarPresentationTrace.enabled { traceGeometryCause = "deferred" }
            call.run()
            if MenuBarPresentationTrace.enabled { traceGeometryCause = outerTraceCause }
        }
    }

    private func scheduleDeferredGeometryReplay() {
        guard !isGeometryReplayScheduled else { return }
        isGeometryReplayScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isGeometryReplayScheduled = false
            replayDeferredGeometryCalls()
        }
    }

    private func resolveCascade(
        _ section: PanelSection,
        visibleFrameOverride: NSRect?,
        preferredDetailSize: CGSize?
    ) {
        isResolvingCascade = true
        defer { isResolvingCascade = false }
        let previousHoverFrames = attachedHoverFrames

        if geekSection != section {
            controlPaletteCoordinator?.dismiss()
        }

        let overviewFrame = attachedOverviewFrame ?? collapsedAttachedFrame(from: panel.frame)
        attachedOverviewFrame = overviewFrame
        if geekSection != section {
            detailColumnSize = preferredDetailSize.map {
                GeekPanelPresentationMetrics.normalizedDetailSize(
                    $0, for: section, density: density
                )
            }
        } else if let preferredDetailSize, section != .overview {
            detailColumnSize = GeekPanelPresentationMetrics.normalizedDetailSize(
                preferredDetailSize, for: section, density: density
            )
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
        guard visibleFrame.width.isFinite, visibleFrame.height.isFinite,
              visibleFrame.width >= 1, visibleFrame.height >= 1,
              visibleFrame.minX.isFinite, visibleFrame.minY.isFinite else { return }
        let layout = panelSettingsState?.geekDashboardConfiguration
        if layout != anchoredDetailTopOffsetsLayout {
            anchoredDetailTopOffsets.removeAll()
            anchoredDetailTopOffsetsLayout = layout
        }
        let registeredTopOffset = registeredDetailTopOffset(
            for: section,
            overviewFrame: overviewFrame,
            detailSize: detailSize
        )
        if let registeredTopOffset {
            anchoredDetailTopOffsets[section] = registeredTopOffset
        }
        let detailTopOffset = registeredTopOffset
            ?? anchoredDetailTopOffsets[section].flatMap {
                Self.clampedDetailTopOffset($0, overviewFrame.height, detailSize.height)
            }
            ?? GeekPanelPresentationMetrics.detailVerticalOffset(
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
        // D76, D119: the power and sensors pages may exceed the screen; they
        // scroll inside the clamped viewport.
        let secondaryCascade = MenuBarPanelPlacement.reflowingCascade(
            parentFrame: overviewFrame,
            childSizes: [detailSize],
            visibleFrame: visibleFrame,
            preferredDirection: cascadeDirection,
            preferredAlignment: .anchor,
            childTopOffsets: [detailTopOffset],
            pointerLocation: pointerLocationProvider(),
            backingScaleFactor: resolvedScreen?.backingScaleFactor ?? 1,
            scrollsTallDetails: section == .power || section == .sensors
        )
        let completeCascade = MenuBarPanelPlacement.reflowingCascade(
            parentFrame: overviewFrame,
            childSizes: [detailSize, tertiaryColumnSize],
            visibleFrame: visibleFrame,
            preferredDirection: secondaryCascade.direction,
            preferredAlignment: .anchor,
            childTopOffsets: [detailTopOffset, tertiaryTopOffset],
            pointerLocation: pointerLocationProvider(),
            backingScaleFactor: resolvedScreen?.backingScaleFactor ?? 1,
            scrollsTallDetails: section == .power || section == .sensors
        )
        // Reserve all three levels even while only level 2 is visible. Opening
        // level 3 must not discover a new fixed-anchor constraint and erase it.
        guard completeCascade.childFrames.count == 2,
              completeCascade.tertiaryPresentationMode == .column else { return }
        let reservedSecondary = MenuBarCascadeLayout(
            direction: completeCascade.direction, alignment: completeCascade.alignment,
            parentFrame: completeCascade.parentFrame,
            childFrames: Array(completeCascade.childFrames.prefix(1)),
            secondaryPresentationMode: .adjacent, tertiaryPresentationMode: .column,
            isCompact: completeCascade.isCompact
        )
        let cascade = isTertiaryPresented ? completeCascade : reservedSecondary
        panelCoordinator?.preservePointerAfterReflow(
            previous: previousHoverFrames, next: cascade.visibleFrames,
            pointer: pointerLocationProvider()
        )
        if !cascade.isCompact { attachedOverviewFrame = cascade.parentFrame }
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
        // D124 (R2h, D172): a control palette docks beside the open menus,
        // left first, so it gets the overview and the module page together
        // (was the module page alone: since D123 opens that page on the
        // overview's right, its left side is the overview and the palette
        // went to the right although the left had room).
        controlPaletteCoordinator?.updatePlacementAnchor(
            cascade.childFrames.first.map { $0.union(cascade.parentFrame) }
        )
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
        guard !isTornDown else { return }
        let ownsTraceCause = beginTraceGeometryCause("overviewSize")
        defer { endTraceGeometryCause(ownsTraceCause) }
        guard !deferGeometryCallIfNeeded({ [weak self] in
            self?.setOverviewSize(preferredSize)
        }) else {
            replayDeferredGeometryCalls()
            return
        }
        guard density.usesAttachedDetailPresentation else { return }
        let normalizedSize = GeekPanelPresentationMetrics.normalizedOverviewSize(
            preferredSize
        )
        guard overviewSize != normalizedSize else { return }
        // Another overview size is another card layout.
        anchoredDetailTopOffsets.removeAll()

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
        guard !isTornDown else { return }
        let ownsTraceCause = beginTraceGeometryCause("detailSize")
        defer { endTraceGeometryCause(ownsTraceCause) }
        // Deferred whole: the size is normalized for the page the session
        // holds when the call runs, after a page change made before it.
        guard !deferGeometryCallIfNeeded({ [weak self] in
            self?.setDetailSize(preferredSize)
        }) else {
            replayDeferredGeometryCalls()
            return
        }
        guard density.usesAttachedDetailPresentation,
              geekSection != .overview else { return }
        let normalizedSize = GeekPanelPresentationMetrics.normalizedDetailSize(
            preferredSize,
            for: geekSection,
            density: density
        )
        // The first selection may have used the same normalized default size.
        // A later content measurement must not solve and redraw the entire
        // cascade again when its visible geometry is already correct.
        let currentSize = GeekPanelPresentationMetrics.normalizedDetailSize(
            detailColumnSize, for: geekSection, density: density
        )
        guard currentSize != normalizedSize else {
            detailColumnSize = normalizedSize
            return
        }
        detailColumnSize = normalizedSize
        setGeekSection(geekSection)
    }

    func setTertiaryPresented(
        _ presented: Bool,
        preferredSize: CGSize? = nil,
        sourceOffset: CGFloat? = nil
    ) {
        guard !isTornDown else { return }
        let ownsTraceCause = beginTraceGeometryCause("tertiary")
        defer { endTraceGeometryCause(ownsTraceCause) }
        guard !deferGeometryCallIfNeeded({ [weak self] in
            self?.setTertiaryPresented(presented, preferredSize: preferredSize, sourceOffset: sourceOffset)
        }) else {
            replayDeferredGeometryCalls()
            return
        }
        guard density.usesAttachedDetailPresentation,
              geekSection != .overview else { return }
        if presented, let panelCoordinator {
            guard case .history = panelCoordinator.route else { return }
        }
        if presented {
            controlPaletteCoordinator?.dismiss()
        }
        let normalizedSize = presented
            ? GeekPanelPresentationMetrics.normalizedTertiarySize(preferredSize)
            : tertiaryColumnSize
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
        MenuBarPresentationTrace.measure("session.windowDidMove") { handleWindowMove() }
    }

    private func handleWindowMove() {
        let ownsTraceCause = beginTraceGeometryCause("windowMove")
        defer { endTraceGeometryCause(ownsTraceCause) }
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
        let eventWindow = sourceWindow ?? event.window
        switch event.keyCode {
        case 53:
            return handleEscape(sourceWindow: eventWindow) ? nil : event
        case 123...126:
            return handleArrowKey(event, sourceWindow: eventWindow) ? nil : event
        default:
            return event
        }
    }

    /// D123 (iStat Menus 7.30 `BBRMenu keyDown:`): the arrow keys move
    /// through the attached menus (`GeekPanelCoordinator.handleArrowKey`).
    /// They stay with a text field, other windows and modified presses.
    private func handleArrowKey(_ event: NSEvent, sourceWindow: NSWindow?) -> Bool {
        guard trackingMenus.isEmpty, isPresented, sourceWindow === panel,
              density.usesAttachedDetailPresentation,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
              !(panel.firstResponder is NSText),
              let panelCoordinator else { return false }
        let key: GeekPanelCoordinator.ArrowKey
        switch event.keyCode {
        case 123: key = .left
        case 124: key = .right
        case 125: key = .down
        default: key = .up
        }
        // A presented control palette is the deepest surface.
        if key == .left, let controlPaletteCoordinator, controlPaletteCoordinator.isPresented {
            controlPaletteCoordinator.dismiss()
            return true
        }
        return panelCoordinator.handleArrowKey(key)
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
        // D123: Escape closes the whole menu, as in iStat Menus 7.30
        // (`onShouldClose`); ← steps back one level (was one level per
        // Escape, then the panel). A presented control palette still closes
        // first.
        hide(reason: "escape")
        // The panel's own Escape while it is not shown still closes its menus.
        if let panelCoordinator, panelCoordinator.route != .summary {
            panelCoordinator.reset()
        }
#if DEBUG || STORAGE_CLEANER_BETA
        PerformanceTelemetry.logger.notice("MenuBar Escape: hidden")
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
#if DEBUG || STORAGE_CLEANER_BETA
        // The script's panel is off every display; clicks of the person
        // using this Mac are never meant for it.
        guard !MenuBarLatencyScript.ignoresOutsideInput else { return false }
#endif
        let sourceWindow = sourceWindow ?? eventWindowNumber.flatMap {
            NSApp.window(withWindowNumber: $0)
        }
        let triggerFrame = triggerFrameProvider?() ?? anchor
        guard triggerFrame?.contains(screenLocation) != true else { return false }
        guard sourceWindow?.level != .popUpMenu else { return false }
        // A native menu item belongs to a separate window, sometimes one
        // AppKit resolves as an application window. Never interpret its click
        // as outside-panel dismissal before SwiftUI handles the selection.
        guard trackingMenus.isEmpty else { return false }

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
        let hideStartedAt = MenuBarPresentationTrace.uptime
        let inputUptime = NSApp?.currentEvent?.timestamp

        removeEventMonitors()
        removeObservers()
        controlPaletteCoordinator?.dismiss()
        panel.orderOut(nil)
        MenuBarPresentationTrace.span("hide.orderOut", from: hideStartedAt, ["reason": reason])
        MenuBarPresentationTrace.discardPendingDraws()
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
        if MenuBarPresentationTrace.enabled {
            var fields: [String: Any] = ["reason": reason]
            if let inputUptime, inputUptime <= hideStartedAt, hideStartedAt - inputUptime < 1 {
                fields["inputToHideStartMs"] = (hideStartedAt - inputUptime) * 1000
            }
            MenuBarPresentationTrace.span("hide.total", from: hideStartedAt, fields)
        }
    }

    func teardown() {
        guard !isTornDown else { return }
        let teardownStartedAt = MenuBarPresentationTrace.uptime
        defer { MenuBarPresentationTrace.span("teardown", from: teardownStartedAt) }

        isTornDown = true
        isPresented = false
        deferredGeometryCalls.removeAll()
        removeEventMonitors()
        removeObservers()
        controlPaletteCoordinator?.teardown()

        panel.orderOut(nil)
        MenuBarPresentationTrace.discardPendingDraws()
        if persistsGeometry {
            geometryStore.save(frame: persistableFrame, for: density)
        }
        panel.delegate = nil
        panel.onPointerLocationChanged = nil
        panel.onArrowKey = nil
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

    private func beginTraceGeometryCause(_ cause: @autoclosure () -> String) -> Bool {
        guard MenuBarPresentationTrace.enabled, traceGeometryCause == nil else { return false }
        traceGeometryCause = cause()
        return true
    }

    private func endTraceGeometryCause(_ owned: Bool) {
        if owned { traceGeometryCause = nil }
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
        ) else { return nil }
        // The card's offset inside the overview is the same wherever the
        // window is; a screen rect is only as current as the frame it was
        // measured in.
        // D123: the page opens 8 pt above the card
        // (`GeekPanelPresentationMetrics.submenuTopOffset`; was at its top).
        let cardTop: CGFloat
        if let layoutOffset = snapshot.layoutOffset, layoutOffset.isFinite {
            cardTop = layoutOffset
        } else {
            guard snapshot.screenRect.intersects(overviewFrame) else { return nil }
            cardTop = overviewFrame.maxY - snapshot.screenRect.maxY
        }
        return Self.clampedDetailTopOffset(GeekPanelPresentationMetrics.submenuTopOffset(forItemTop: cardTop),
                                           overviewFrame.height, detailSize.height)
    }

    /// The level-two page's top below the overview's top, kept inside the
    /// overview: at least 0 and at most the overview height less the smaller
    /// of 44 pt and the page height.
    static func clampedDetailTopOffset(_ offset: CGFloat, _ overviewHeight: CGFloat,
                                       _ detailHeight: CGFloat) -> CGFloat? {
        guard offset.isFinite else { return nil }
        let limit = max(0, overviewHeight - min(44, detailHeight))
        return min(max(0, offset), limit)
    }

    private func registeredAnchorDidChange(_ anchorID: SmallWindowAnchorID) {
        let ownsTraceCause = beginTraceGeometryCause(
            panelCoordinator?.anchorRegistry.snapshot(for: anchorID) == nil ? "anchorRemoved" : "anchor"
        )
        defer { endTraceGeometryCause(ownsTraceCause) }
        // An anchor of another page needs nothing here: a page change that is
        // still deferred reads the registry when it runs.
        guard isPresented,
              !isTornDown,
              geekSection != .overview,
              anchorID == .module(geekSection) else { return }
        if isResolvingCascade || isApplyingProgrammaticFrame {
            // Registered from the view update inside the frame being applied:
            // place the cascade again once that frame is done (once, however
            // many times the anchor reported).
            guard !isAnchorRefreshDeferred else { return }
            isAnchorRefreshDeferred = true
            _ = deferGeometryCallIfNeeded { [weak self] in
                guard let self else { return }
                isAnchorRefreshDeferred = false
                registeredAnchorDidChange(anchorID)
            }
            return
        }
        setGeekSection(geekSection)
    }

    private func configureSizeLimits(for density: PanelDensity, visibleFrame: NSRect?) {
        guard let visibleFrame else { return }
        // D123: the bounds `MenuBarPanelPlacement.frame` places the panel in,
        // up to the menu bar (was 8 pt below it as well).
        let visible = MenuBarPanelPlacement.menuBounds(visibleFrame, margin: 8)
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
        let setFrameStartedAt = MenuBarPresentationTrace.uptime
        isApplyingProgrammaticFrame = true
        panel.setFrame(alignedFrame, display: true)
        programmaticFrameDidApplyForTesting?()
        isApplyingProgrammaticFrame = false
        MenuBarPresentationTrace.span("setFrame", from: setFrameStartedAt, [
            "x": alignedFrame.minX, "y": alignedFrame.minY,
            "width": alignedFrame.width, "height": alignedFrame.height,
            "visible": panel.isVisible, "cause": self.traceGeometryCause ?? "other"
        ])
        PerformanceTelemetry.signposter.emitEvent("PanelRepositioned")
        refreshPointerWithinHoverEnvelope()
        // A frame applied outside a cascade resolution (show) replays here;
        // a resolution replays after it has finished.
        replayDeferredGeometryCalls()
    }

#if DEBUG || STORAGE_CLEANER_BETA
    private func scheduleDebugSnapshotsIfRequested() {
        guard MiniWindowDemoData.isCapturingMenuBarPanelSnapshots else { return }
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

            defer {
                MiniWindowDemoData.finishMenuBarPanelSnapshots()
                panelCoordinator?.reset()
            }

            if let requestedScenario {
                await captureDebugSnapshotScenario(requestedScenario, in: directory)
                return
            }

            if ProcessInfo.processInfo.arguments.contains("--capture-menu-bar-live-audit"),
               !MiniWindowDemoData.isEnabled {
                // Only select and render live monitoring pages. Control actions,
                // process termination and demo fixtures are never entered here.
                for section in MiniWindowDemoData.liveAuditSections(arguments: ProcessInfo.processInfo.arguments) {
                    panelCoordinator?.reset()
                    panelCoordinator?.selectModule(section)
                    guard await waitForDebugAttachedLayout(childCount: 1, section: section) else { continue }
                    // D57: the power page reads SMC and the Energy Model every
                    // 2 s; its first counter window needs one more sample.
                    if section == .power { try? await Task.sleep(for: .seconds(5)) }
                    await captureDebugSnapshot(named: "live-\(section.rawValue)-secondary.png", in: directory)
                    if let detail = section.tertiaryDetail {
                        panelCoordinator?.presentHistory(.builtIn(detail.rawValue), pinned: true)
                        if await waitForDebugAttachedLayout(childCount: 2, section: section) {
                            await captureDebugSnapshot(named: "live-\(section.rawValue)-history.png", in: directory)
                        }
                    }
                }
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
                    writeDebugPageLayout(named: name, in: directory, rootView: view)
                    return
                }
            }
            guard attempt < 9 else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func writeDebugPageLayout(named name: String, in directory: URL, rootView: NSView) {
        func scrollViewCount(_ view: NSView) -> Int {
            (view is NSScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + scrollViewCount($1) }
        }
        func sizeRecord(_ size: CGSize) -> [String: CGFloat] {
            ["width": size.width, "height": size.height]
        }
        let naturalDetail = GeekPanelPresentationMetrics.normalizedDetailSize(
            detailColumnSize, for: geekSection, density: density)
        let naturalSizes = [naturalDetail, tertiaryColumnSize]
        let pages: [[String: Any]] = (attachedCascadeLayout?.childFrames ?? []).enumerated().map { index, frame in
            let natural = naturalSizes[min(index, naturalSizes.count - 1)]
            return ["level": index + 2, "naturalSize": sizeRecord(natural),
                    "visibleSize": sizeRecord(frame.size),
                    "scale": MiniWindowPageFit.scale(content: natural, available: frame.size)]
        }
        let record: [String: Any] = [
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "mode": MiniWindowDemoData.isEnabled ? "FIXTURE" : "LIVE",
            "section": geekSection.rawValue,
            "scrollViewCount": scrollViewCount(rootView),
            "pages": pages,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent(name).deletingPathExtension().appendingPathExtension("json"), options: .atomic)
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
        let visible = MenuBarPanelPlacement.menuBounds(visibleFrame, margin: 8)
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

    /// `isPointerEvent` is false for a reading after a layout change, which
    /// updates the hover state but closes nothing (D123).
    private func pointerLocationChanged(_ location: NSPoint, isPointerEvent: Bool = true) {
        guard !isTornDown, density.usesAttachedDetailPresentation else { return }
        // A native range menu occupies its own AppKit window. Treat the menu
        // as part of the hover session until its selection has been delivered.
        if !trackingMenus.isEmpty {
            panelCoordinator?.setPointerWithinHoverEnvelope(true)
            return
        }
        let menus = attachedMenuChainFrames
        let paletteFrame = presentedControlPaletteFrame
        panelCoordinator?.recordPointer(location)
        panelCoordinator?.updateWindowGroupFrames(menus, palette: paletteFrame)
        if panelCoordinator?.retainsPointerAfterReflow(location) == true {
            panelCoordinator?.setPointerWithinHoverEnvelope(true)
            return
        }
        var isOverPalette = false
        if let paletteFrame {
            isOverPalette = paletteFrame.contains(location)
            // D123: the corridor to a presented control palette keeps the
            // session (the palettes are ours); iStat's flush menus need none,
            // so the corridors between columns and the hover triangle are gone.
            if !isOverPalette, let source = menus.last,
               HoverCorridor(
                   source: source,
                   destination: paletteFrame,
                   padding: HoverIntentPolicy.menuBar.corridorPadding
               ).contains(location) {
                isOverPalette = true
                PerformanceTelemetry.signposter.emitEvent("CorridorEntered")
            }
        }
        panelCoordinator?.pointerMoved(
            to: attachedMenuColumn(at: location, in: menus),
            at: location,
            isOverPalette: isOverPalette,
            isPointerEvent: isPointerEvent
        )
    }

    /// D123: the attached menu under the pointer. A compact cascade shows
    /// one page at a time, the deepest open one.
    private func attachedMenuColumn(at location: NSPoint, in menus: [NSRect]) -> GeekPanelColumn? {
        if attachedCascadeLayout?.isCompact == true {
            guard menus.first?.contains(location) == true else { return nil }
            return GeekPanelColumn(rawValue: menus.count - 1)
        }
        return menus.firstIndex { $0.contains(location) }.flatMap(GeekPanelColumn.init(rawValue:))
    }

    /// Frame changes can move the attached cascade around a stationary cursor.
    /// Tracking-area callbacks only arrive on later pointer events, so sample
    /// the current screen location immediately before a delayed hover-dismiss
    /// task can observe a stale envelope value.
    private func refreshPointerWithinHoverEnvelope() {
        pointerLocationChanged(pointerLocationProvider(), isPointerEvent: false)
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

    /// D123: the attached menus from the overview to the deepest page,
    /// parents first (`visibleAttachedContentFrames` lists the module column
    /// first).
    private var attachedMenuChainFrames: [NSRect] {
        if let attachedCascadeLayout {
            return attachedCascadeLayout.visibleFrames
        }
        let frames = visibleAttachedContentFrames
        guard frames.count >= 2 else { return frames }
        return [frames[1], frames[0]] + frames.dropFirst(2)
    }

    private var presentedControlPaletteFrame: NSRect? {
        guard let controlPaletteCoordinator,
              controlPaletteCoordinator.isPresented else { return nil }
        let frame = controlPaletteCoordinator.panel.frame
        return frame.isUsableWindowAnchor ? frame : nil
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
            tertiaryPresentationMode: layout.tertiaryPresentationMode,
            isCompact: layout.isCompact
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
                    self.applicationDeactivationTask?.cancel()
                    self.applicationDeactivationTask = nil
                    self.lastNativeMenuEndedAt = nil
                    self.menuTrackingHoverReleaseTask?.cancel()
                    self.menuTrackingHoverReleaseTask = nil
                    if self.trackingMenus.isEmpty {
                        self.menuWasApplicationActiveAtBegin = self.applicationIsActiveProvider()
                        self.deactivatedDuringMenuTracking = false
                    }
                    self.trackingMenus.insert(menuID)
                    self.panelCoordinator?.invalidateHoverIntent()
                    self.panelCoordinator?.setPointerWithinHoverEnvelope(true)
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
        // Explicit screenshot sessions must finish even if the inspection
        // tool takes focus. The capture flag never substitutes fixture data;
        // ordinary live launches retain their dismissal behavior.
        if MiniWindowDemoData.isCapturingMenuBarPanelSnapshots { return }
        PerformanceTelemetry.logger.notice("MenuBar lifecycle: application-deactivated menuTracking=\(!self.trackingMenus.isEmpty)")
#endif
        guard trackingMenus.isEmpty else {
            deactivatedDuringMenuTracking = true
            return
        }
        // NSPanel is intentionally nonactivating. Native menus can briefly
        // resign application focus before didBeginTracking arrives, or just
        // after didEndTracking. Defer the decision so neither transition
        // closes the source control before its action is committed.
        applicationDeactivationTask?.cancel()
        applicationDeactivationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.applicationDeactivationTask = nil
            guard self.isPresented, self.trackingMenus.isEmpty,
                  !self.applicationIsActiveProvider() else { return }
            if let menuEnd = self.lastNativeMenuEndedAt,
               Date().timeIntervalSince(menuEnd) < 0.5 { return }
            self.hide(reason: "application-deactivated")
        }
    }

    private func menuDidEndTracking(_ menuID: ObjectIdentifier) {
        guard trackingMenus.remove(menuID) != nil else { return }
#if DEBUG || STORAGE_CLEANER_BETA
        PerformanceTelemetry.logger.notice("MenuBar lifecycle: native-menu-end remainingTracking=\(!self.trackingMenus.isEmpty)")
#endif
        guard trackingMenus.isEmpty else { return }
        lastNativeMenuEndedAt = Date()
        let shouldReconcileApplicationSwitch = menuWasApplicationActiveAtBegin
            && deactivatedDuringMenuTracking
        menuWasApplicationActiveAtBegin = false
        deactivatedDuringMenuTracking = false
        // SwiftUI may run the selected item's action just after tracking ends.
        // Keep the tertiary surface alive briefly, then restore normal hover.
        menuTrackingHoverReleaseTask?.cancel()
        menuTrackingHoverReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.trackingMenus.isEmpty,
                  self.isPresented else { return }
            self.menuTrackingHoverReleaseTask = nil
            self.refreshPointerWithinHoverEnvelope()
        }
        if shouldReconcileApplicationSwitch {
            applicationDeactivationTask?.cancel()
            applicationDeactivationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                self.applicationDeactivationTask = nil
                guard self.isPresented, self.trackingMenus.isEmpty,
                      !self.applicationIsActiveProvider() else { return }
                self.hide(reason: "application-inactive-after-menu")
            }
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
        applicationDeactivationTask?.cancel()
        applicationDeactivationTask = nil
        menuTrackingHoverReleaseTask?.cancel()
        menuTrackingHoverReleaseTask = nil
        trackingMenus.removeAll()
        menuWasApplicationActiveAtBegin = false
        deactivatedDuringMenuTracking = false
        lastNativeMenuEndedAt = nil
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

#if DEBUG || STORAGE_CLEANER_BETA
/// Read-only access for `MenuBarLatencyScript`, which drives the same
/// coordinator and settings entry points a click uses.
extension MenuBarPanelSession {
    var latencyScriptCoordinator: GeekPanelCoordinator? { panelCoordinator }
    var latencyScriptSettings: MenuBarPanelSettingsState? { panelSettingsState }
    var latencyScriptChildFrames: [NSRect] { attachedCascadeLayout?.childFrames ?? [] }
}
#endif
