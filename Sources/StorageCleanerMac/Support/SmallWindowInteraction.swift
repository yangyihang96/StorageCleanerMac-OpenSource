import AppKit
import SwiftUI

struct SmallWindowAnchorID: Hashable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func module(_ section: PanelSection) -> Self {
        Self(rawValue: "module.\(section.rawValue)")
    }

    static func tertiary(_ identifier: String) -> Self {
        Self(rawValue: "tertiary.\(identifier)")
    }

    static let networkConnection = Self(rawValue: "control.network.connection")
    static let fanControl = Self(rawValue: "control.fan")
    static let powerMode = Self(rawValue: "control.power")
}

enum SmallWindowPanelRole: String, Equatable, Sendable {
    case primary
    case secondary
    case tertiary
    case controlPalette
    case hoverInspector
}

enum HoverPresentationState: Equatable, Sendable {
    case closed
    case pendingOpen(anchorID: SmallWindowAnchorID)
    case open(anchorID: SmallWindowAnchorID, panelRole: SmallWindowPanelRole)
    case pendingSwitch(from: SmallWindowAnchorID, to: SmallWindowAnchorID)
    case pendingClose
}

struct HoverIntentPolicy: Equatable, Sendable {
    var initialOpenDelay: Duration = .zero
    var switchDelay: Duration = .zero
    /// D123: a submenu closes as soon as the pointer leaves its menu without
    /// entering it, as in iStat Menus 7.30 (was 260 ms). The control palettes
    /// keep 260 ms (`controlPalette`).
    var ordinaryCloseDelay: Duration = .zero
    /// The control palettes' close delay inside the corridor to the palette
    /// (`recommendedCloseDelay`).
    var corridorGraceDuration: Duration = .milliseconds(320)
    /// D123: the horizontal step toward the open child's side, per pointer
    /// event, that holds a switch or a close (iStat Menus 7.30 `updateMouse:`,
    /// ΔX ≥ 1). The hold lasts while every step keeps going that way; any
    /// other step ends it. It replaces the trajectory test, the 320 ms grace,
    /// the 50 ms progress checks and the 1 s cap: iStat's 1 s check holds
    /// again at once while the pointer still heads for the child, so the
    /// hold has no time limit.
    var headingStep: CGFloat = 1
    var reverseDirectionCloseDelay: Duration = .milliseconds(90)
    var pointerHistoryDuration: TimeInterval = 0.16
    var maximumPointerSamples = 6
    var corridorPadding: CGFloat = 8

    static let menuBar = Self()
    /// The control palettes and their hover inspectors are ours, not iStat's.
    /// A gap separates a palette from its anchor row, so they keep the 260 ms
    /// close and the corridor to the palette.
    static let controlPalette = Self(ordinaryCloseDelay: .milliseconds(260))
}

struct SmallWindowAnchorSnapshot: Equatable, Sendable {
    let id: SmallWindowAnchorID
    let screenRect: NSRect
    let parentPanelRole: SmallWindowPanelRole
    let preferredPlacementEdge: MenuBarCascadeDirection
    let contentKind: String
    let lastUpdatedLayoutGeneration: UInt
    /// For a level-one card: the card's top offset inside the overview's
    /// layout (`GeekOverviewAnchorSpace`), which does not depend on where the
    /// window is or on which frame the view last drew.
    var layoutOffset: CGFloat? = nil
}

@MainActor
final class SmallWindowAnchorRegistry {
    private var snapshots: [SmallWindowAnchorID: SmallWindowAnchorSnapshot] = [:]
    private var layoutGeneration: UInt = 0
    var didChange: ((SmallWindowAnchorID) -> Void)?

    @discardableResult
    func update(
        id: SmallWindowAnchorID,
        screenRect: NSRect,
        parentPanelRole: SmallWindowPanelRole,
        preferredPlacementEdge: MenuBarCascadeDirection,
        contentKind: String,
        layoutOffset: CGFloat? = nil
    ) -> Bool {
        guard screenRect.isUsableWindowAnchor else { return false }
        // A native screen-rect report carries no layout information; it keeps
        // the offset the card's layout registered for the same anchor.
        let layoutOffset = layoutOffset.flatMap { $0.isFinite ? max(0, $0) : nil }
            ?? snapshots[id]?.layoutOffset
        if let current = snapshots[id], current.screenRect.isApproximatelyEqual(to: screenRect),
           current.layoutOffset == layoutOffset {
            return false
        }
        layoutGeneration &+= 1
        snapshots[id] = SmallWindowAnchorSnapshot(
            id: id,
            screenRect: screenRect,
            parentPanelRole: parentPanelRole,
            preferredPlacementEdge: preferredPlacementEdge,
            contentKind: contentKind,
            lastUpdatedLayoutGeneration: layoutGeneration,
            layoutOffset: layoutOffset
        )
        didChange?(id)
        return true
    }

    func snapshot(for id: SmallWindowAnchorID) -> SmallWindowAnchorSnapshot? {
        snapshots[id]
    }

    func remove(_ id: SmallWindowAnchorID) {
        guard snapshots.removeValue(forKey: id) != nil else { return }
        layoutGeneration &+= 1
        didChange?(id)
    }

    func removeAll() {
        guard !snapshots.isEmpty else { return }
        snapshots.removeAll()
        layoutGeneration &+= 1
    }
}

@MainActor
final class SmallWindowAnchorHandle {
    weak var view: NSView?

    func snapshot() -> (rect: NSRect, window: NSWindow)? {
        guard let view, let window = view.window else { return nil }
        let rectInWindow = view.convert(view.bounds, to: nil)
        return (window.convertToScreen(rectInWindow), window)
    }
}

@MainActor
final class SmallWindowAnchorNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onSnapshotChanged: ((NSRect, NSWindow) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var lastReportedRect: NSRect?
    private weak var lastReportedWindow: NSWindow?
    private var isSnapshotReportScheduled = false
    private let geometryObservers = SmallWindowAnchorGeometryObservers()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        removeGeometryObservers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installGeometryObservers()
        reportSnapshotIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // The ancestor chain changed; observe the new one.
        installGeometryObservers()
        reportSnapshotIfNeeded()
    }

    override func layout() {
        super.layout()
        reportSnapshotIfNeeded()
    }

    // The screen rect changes without a layout pass of this view when only
    // its origin moves (SwiftUI offsets and reflows), when an ancestor moves
    // or when the window moves or resizes. Each of these reports again; the
    // registry drops unchanged rects.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        reportSnapshotIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportSnapshotIfNeeded()
    }

    func stopObservingGeometry() {
        removeGeometryObservers()
    }

    private func installGeometryObservers() {
        removeGeometryObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, of object: AnyObject) -> NSObjectProtocol {
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportSnapshotIfNeeded()
                }
            }
        }
        geometryObservers.tokens = [
            observe(NSWindow.didMoveNotification, of: window),
            observe(NSWindow.didResizeNotification, of: window),
        ]
        var ancestor = superview
        while let view = ancestor {
            geometryObservers.tokens.append(observe(NSView.frameDidChangeNotification, of: view))
            ancestor = view.superview
        }
    }

    private func removeGeometryObservers() {
        geometryObservers.removeAll()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        reportSnapshotIfNeeded()
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func reportSnapshotIfNeeded() {
        guard window != nil else {
            lastReportedRect = nil
            lastReportedWindow = nil
            return
        }
        guard !isSnapshotReportScheduled else { return }
        isSnapshotReportScheduled = true
        // AppKit invokes these callbacks inside SwiftUI layout. Publishing the
        // resulting cascade geometry there reenters the current view update.
        // Coalesce that pass and read the latest attached frame on delivery.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isSnapshotReportScheduled = false
            publishSnapshotIfNeeded()
        }
    }

    private func publishSnapshotIfNeeded() {
        guard let window else { return }
        let rectInWindow = convert(bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        guard screenRect.isUsableWindowAnchor,
              lastReportedWindow !== window
                || lastReportedRect?.isApproximatelyEqual(to: screenRect) != true else { return }
        lastReportedRect = screenRect
        lastReportedWindow = window
        onSnapshotChanged?(screenRect, window)
    }
}

/// NotificationCenter keeps block observers until they are removed. An anchor
/// view can be released inside its window (the window's hierarchy goes away
/// without a move), so its observers are removed with this holder as well.
private final class SmallWindowAnchorGeometryObservers {
    var tokens: [NSObjectProtocol] = []

    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }

    deinit {
        removeAll()
    }
}

struct SmallWindowAnchorReader: NSViewRepresentable {
    let handle: SmallWindowAnchorHandle
    var onHoverChanged: ((Bool) -> Void)? = nil
    var onSnapshotChanged: ((NSRect, NSWindow) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = SmallWindowAnchorNSView(frame: .zero)
        handle.view = view
        view.onHoverChanged = onHoverChanged
        view.onSnapshotChanged = onSnapshotChanged
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? SmallWindowAnchorNSView else { return }
        if handle.view !== view {
            handle.view = view
        }
        view.onHoverChanged = onHoverChanged
        view.onSnapshotChanged = onSnapshotChanged
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let view = nsView as? SmallWindowAnchorNSView else { return }
        view.onHoverChanged?(false)
        view.onHoverChanged = nil
        view.onSnapshotChanged = nil
        view.stopObservingGeometry()
    }
}

struct HoverCorridor: Equatable, Sendable {
    let points: [NSPoint]

    init(source: NSRect, destination: NSRect, padding: CGFloat) {
        let padding = max(0, padding)
        if destination.maxX <= source.minX {
            points = [
                NSPoint(x: source.minX, y: source.minY - padding),
                NSPoint(x: source.minX, y: source.maxY + padding),
                NSPoint(x: destination.maxX, y: destination.maxY + padding),
                NSPoint(x: destination.maxX, y: destination.minY - padding),
            ]
        } else if source.maxX <= destination.minX {
            points = [
                NSPoint(x: source.maxX, y: source.minY - padding),
                NSPoint(x: destination.minX, y: destination.minY - padding),
                NSPoint(x: destination.minX, y: destination.maxY + padding),
                NSPoint(x: source.maxX, y: source.maxY + padding),
            ]
        } else if destination.maxY <= source.minY {
            points = [
                NSPoint(x: source.minX - padding, y: source.minY),
                NSPoint(x: source.maxX + padding, y: source.minY),
                NSPoint(x: destination.maxX + padding, y: destination.maxY),
                NSPoint(x: destination.minX - padding, y: destination.maxY),
            ]
        } else if source.maxY <= destination.minY {
            points = [
                NSPoint(x: source.minX - padding, y: source.maxY),
                NSPoint(x: destination.minX - padding, y: destination.minY),
                NSPoint(x: destination.maxX + padding, y: destination.minY),
                NSPoint(x: source.maxX + padding, y: source.maxY),
            ]
        } else {
            let union = source.union(destination).insetBy(dx: -padding, dy: -padding)
            points = [
                NSPoint(x: union.minX, y: union.minY),
                NSPoint(x: union.maxX, y: union.minY),
                NSPoint(x: union.maxX, y: union.maxY),
                NSPoint(x: union.minX, y: union.maxY),
            ]
        }
    }

    func contains(_ point: NSPoint) -> Bool {
        guard points.count >= 3 else { return false }
        var isInside = false
        var previous = points[points.count - 1]
        for current in points {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            if crosses {
                let denominator = previous.y - current.y
                if denominator != 0 {
                    let intersectionX = (previous.x - current.x)
                        * (point.y - current.y) / denominator + current.x
                    if point.x < intersectionX {
                        isInside.toggle()
                    }
                }
            }
            previous = current
        }
        return isInside
    }
}

@MainActor
final class HoverIntentController {
    struct Request: Equatable, Sendable {
        fileprivate let generation: UInt
    }

    enum PointerDirection: Equatable, Sendable {
        case toward
        case away
        case neutral
    }

    private struct PointerSample {
        let point: NSPoint
        let timestamp: TimeInterval
    }

    let policy: HoverIntentPolicy
    private(set) var state = HoverPresentationState.closed
    private var generation: UInt = 0
    private var pendingTask: Task<Void, Never>?
    private var pointerSamples: [PointerSample] = []
    /// The pointer's latest movement, from the reading before it however long
    /// ago that was: iStat Menus 7.30 compares each event with the previous
    /// one, while `pointerSamples` drops readings older than
    /// `pointerHistoryDuration` (D123).
    private var lastPointerStep: CGVector?
    private var activeAnchorID: SmallWindowAnchorID?
    private var activePanelRole: SmallWindowPanelRole?
    /// The menus from the overview to the deepest child, parents first.
    private var windowGroupFrames: [NSRect] = []
    /// A presented control palette: part of the close-delay corridors, not a
    /// child menu for the hold.
    private var paletteFrame: NSRect?
    /// A switch or close held while the pointer heads for the open child
    /// (D123). `recordPointer` releases it on the first step that does not.
    private var diagonalHold: DiagonalHold?

    private struct DiagonalHold {
        let request: Request
        /// −1 when the open child is on the left of the pointer's menu, +1
        /// when it is on the right.
        let side: CGFloat
        let complete: @MainActor () -> Void
    }

    init(policy: HoverIntentPolicy = .menuBar) {
        self.policy = policy
    }

    func beginRequest() -> Request {
        invalidatePendingRequest(preservingPresentation: true)
        return Request(generation: generation)
    }

    /// A request that is never current. Unlike `beginRequest` + `cancel`, it
    /// does not disturb pending work, so a refused hover cannot silently
    /// cancel another surface's scheduled open or close.
    func expiredRequest() -> Request {
        Request(generation: generation &- 1)
    }

    func isCurrent(_ request: Request) -> Bool {
        request.generation == generation
    }

    func cancel(_ request: Request? = nil) {
        guard request.map(isCurrent) ?? true else { return }
        invalidatePendingRequest(preservingPresentation: true)
    }

    /// Whether a switch or close is being held for a pointer heading to the
    /// open child.
    var isHoldingForOpenChild: Bool {
        diagonalHold != nil
    }

    @discardableResult
    func scheduleOpen(
        anchorID: SmallWindowAnchorID,
        panelRole: SmallWindowPanelRole,
        delay: Duration? = nil,
        condition: @escaping @MainActor () -> Bool = { true },
        action: @escaping @MainActor () -> Void
    ) -> Request {
        let previousAnchor = activeAnchorID
        let isSwitch = previousAnchor != nil && previousAnchor != anchorID
        let request = beginRequest()
        state = isSwitch
            ? .pendingSwitch(from: previousAnchor!, to: anchorID)
            : .pendingOpen(anchorID: anchorID)
        if isSwitch {
            PerformanceTelemetry.signposter.emitEvent("HoverSwitchScheduled")
        } else {
            PerformanceTelemetry.signposter.emitEvent("HoverOpenScheduled")
        }
        let complete: @MainActor () -> Void = { [weak self] in
            guard let self, isCurrent(request) else { return }
            pendingTask = nil
            diagonalHold = nil
            guard condition() else {
                restoreOpenState()
                return
            }
            activeAnchorID = anchorID
            activePanelRole = panelRole
            state = .open(anchorID: anchorID, panelRole: panelRole)
            if isSwitch {
                PerformanceTelemetry.signposter.emitEvent("HoverSwitched")
            } else {
                PerformanceTelemetry.signposter.emitEvent("HoverOpened")
            }
            action()
        }
        // iStat Menus 7.30 opens at once and switches at once, except while
        // the pointer heads for the open child (D123).
        if delay == nil, isSwitch, let side = headingSideOfOpenChild() {
            hold(request, side: side, complete: complete)
        } else {
            run(request, after: delay ?? (isSwitch ? policy.switchDelay : policy.initialOpenDelay), complete)
        }
        return request
    }

    @discardableResult
    func scheduleClose(
        delay: Duration? = nil,
        condition: @escaping @MainActor () -> Bool = { true },
        action: @escaping @MainActor () -> Void
    ) -> Request {
        let request = beginRequest()
        state = .pendingClose
        PerformanceTelemetry.signposter.emitEvent("HoverCloseScheduled")
        let complete: @MainActor () -> Void = { [weak self] in
            guard let self, isCurrent(request) else { return }
            pendingTask = nil
            diagonalHold = nil
            guard condition() else {
                restoreOpenState()
                return
            }
            markClosed()
            PerformanceTelemetry.signposter.emitEvent("HoverClosed")
            action()
        }
        // D123: a close is a change of target too; iStat holds it while the
        // pointer heads for the open child and otherwise closes at once.
        // An explicit delay (the control palettes) keeps its own timing.
        if delay == nil, let side = headingSideOfOpenChild() {
            hold(request, side: side, complete: complete)
        } else {
            run(request, after: delay ?? policy.ordinaryCloseDelay, complete)
        }
        return request
    }

    /// Runs `complete` after `delay`. A zero delay still waits one
    /// cancellable main-actor turn, so a hover callback never reenters the
    /// view update that reported it.
    private func run(
        _ request: Request,
        after delay: Duration,
        _ complete: @escaping @MainActor () -> Void
    ) {
        pendingTask = Task { @MainActor in
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            complete()
        }
    }

    /// Holds `complete` while the pointer heads for the open child. The
    /// first pointer step that does not keep heading there releases it
    /// (`recordPointer`); a pointer that stops keeps it (iStat Menus 7.30,
    /// D123).
    private func hold(
        _ request: Request,
        side: CGFloat,
        complete: @escaping @MainActor () -> Void
    ) {
        diagonalHold = DiagonalHold(request: request, side: side, complete: complete)
        PerformanceTelemetry.signposter.emitEvent("DiagonalHoldBegan")
    }

    private func releaseDiagonalHold(_ request: Request) {
        guard let hold = diagonalHold, hold.request == request, isCurrent(request) else { return }
        diagonalHold = nil
        PerformanceTelemetry.signposter.emitEvent("DiagonalHoldReleased")
        // The release arrives in the middle of pointer handling, so the
        // switch or close runs on the next turn, as `run` does for any change.
        run(request, after: .zero, hold.complete)
    }

    func markOpen(anchorID: SmallWindowAnchorID, panelRole: SmallWindowPanelRole) {
        invalidatePendingRequest(preservingPresentation: true)
        activeAnchorID = anchorID
        activePanelRole = panelRole
        state = .open(anchorID: anchorID, panelRole: panelRole)
    }

    func markClosed() {
        invalidatePendingRequest(preservingPresentation: false)
        activeAnchorID = nil
        activePanelRole = nil
        state = .closed
    }

    func markClosed(
        ifOwnedBy anchorID: SmallWindowAnchorID,
        panelRole: SmallWindowPanelRole
    ) {
        guard activeAnchorID == anchorID, activePanelRole == panelRole else { return }
        markClosed()
    }

    func recordPointer(
        _ point: NSPoint,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard point.x.isFinite, point.y.isFinite, timestamp.isFinite else { return }
        let previous = pointerSamples.last?.point
        // A reading at the same place (a refresh after a layout change) is
        // not a pointer movement.
        guard point != previous else { return }
        lastPointerStep = previous.map { CGVector(dx: point.x - $0.x, dy: point.y - $0.y) }
        pointerSamples.append(PointerSample(point: point, timestamp: timestamp))
        let cutoff = timestamp - policy.pointerHistoryDuration
        pointerSamples.removeAll { $0.timestamp < cutoff }
        if pointerSamples.count > policy.maximumPointerSamples {
            pointerSamples.removeFirst(pointerSamples.count - policy.maximumPointerSamples)
        }
        // D123 (iStat Menus 7.30 `updateMouse:`): the hold lasts while every
        // step keeps going toward the open child's side by `headingStep`; a
        // sideways, shorter or backward step ends it at once.
        if let hold = diagonalHold, let step = lastPointerStep,
           step.dx * hold.side < policy.headingStep {
            releaseDiagonalHold(hold.request)
        }
    }

    func updateWindowGroupFrames(_ frames: [NSRect], palette: NSRect? = nil) {
        windowGroupFrames = frames.filter(\.isUsableWindowAnchor)
        paletteFrame = palette.flatMap { $0.isUsableWindowAnchor ? $0 : nil }
    }

    /// The menus from the overview to the deepest child, parents first.
    var menuFrames: [NSRect] {
        windowGroupFrames
    }

    /// D123 (iStat Menus 7.30 `updateMouse:`): the side of the open child of
    /// the menu the pointer is in, −1 left or +1 right, when the pointer's
    /// latest horizontal step goes that way by `headingStep`; otherwise nil.
    /// Children come after their parent in `windowGroupFrames`, so this
    /// covers the overview toward the module column and the module column
    /// toward the history column alike. Only a step toward the child's side
    /// counts, whether or not its line would reach the child (the D117
    /// trajectory test is gone).
    private func headingSideOfOpenChild() -> CGFloat? {
        guard activeAnchorID != nil,
              let step = lastPointerStep,
              let last = pointerSamples.last,
              let sourceIndex = windowGroupFrames.firstIndex(where: { $0.contains(last.point) }),
              windowGroupFrames.indices.contains(sourceIndex + 1)
        else { return nil }
        let source = windowGroupFrames[sourceIndex]
        let child = windowGroupFrames[sourceIndex + 1]
        let side: CGFloat
        if child.minX >= source.maxX - 0.5 {
            side = 1
        } else if child.maxX <= source.minX + 0.5 {
            side = -1
        } else {
            // A child stacked above or below its menu has no side.
            return nil
        }
        return step.dx * side >= policy.headingStep ? side : nil
    }

    func pointerDirection(toward destination: NSRect) -> PointerDirection {
        guard destination.isUsableWindowAnchor,
              let first = pointerSamples.first,
              let last = pointerSamples.last,
              first.timestamp < last.timestamp else { return .neutral }
        let movement = CGVector(dx: last.point.x - first.point.x, dy: last.point.y - first.point.y)
        let movementLength = hypot(movement.dx, movement.dy)
        guard movementLength >= 2 else { return .neutral }
        let target = CGVector(
            dx: destination.midX - last.point.x,
            dy: destination.midY - last.point.y
        )
        let targetLength = hypot(target.dx, target.dy)
        guard targetLength > 0 else { return .toward }
        let cosine = (movement.dx * target.dx + movement.dy * target.dy)
            / (movementLength * targetLength)
        let oldDistance = hypot(destination.midX - first.point.x, destination.midY - first.point.y)
        let newDistance = targetLength
        if cosine >= 0.25, newDistance + 1 < oldDistance {
            return .toward
        }
        if cosine <= -0.25, newDistance > oldDistance + 3 {
            return .away
        }
        return .neutral
    }

    func recommendedCloseDelay(ordinaryDelay: Duration? = nil) -> Duration {
        guard let pointer = pointerSamples.last?.point else {
            return ordinaryDelay ?? policy.ordinaryCloseDelay
        }
        let frames = windowGroupFrames + (paletteFrame.map { [$0] } ?? [])
        let corridors = zip(frames, frames.dropFirst()).map {
            HoverCorridor(
                source: $0.0,
                destination: $0.1,
                padding: policy.corridorPadding
            )
        }
        if frames.contains(where: { $0.contains(pointer) })
            || corridors.contains(where: { $0.contains(pointer) }) {
            PerformanceTelemetry.signposter.emitEvent("CorridorEntered")
            return policy.corridorGraceDuration
        }
        let nearest = frames.min {
            $0.distanceSquared(to: pointer) < $1.distanceSquared(to: pointer)
        }
        if let nearest, pointerDirection(toward: nearest) == .away {
            return policy.reverseDirectionCloseDelay
        }
        return ordinaryDelay ?? policy.ordinaryCloseDelay
    }

    private func invalidatePendingRequest(preservingPresentation: Bool) {
        pendingTask?.cancel()
        pendingTask = nil
        diagonalHold = nil
        generation &+= 1
        if preservingPresentation {
            restoreOpenState()
        }
    }

    private func restoreOpenState() {
        if let activeAnchorID, let activePanelRole {
            state = .open(anchorID: activeAnchorID, panelRole: activePanelRole)
        } else {
            state = .closed
        }
    }
}

extension NSRect {
    var isUsableWindowAnchor: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }

    func isApproximatelyEqual(to other: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) < tolerance
            && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance
            && abs(height - other.height) < tolerance
    }

    func distanceSquared(to point: NSPoint) -> CGFloat {
        let dx = max(max(minX - point.x, 0), point.x - maxX)
        let dy = max(max(minY - point.y, 0), point.y - maxY)
        return dx * dx + dy * dy
    }
}
