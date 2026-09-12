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
    var initialOpenDelay: Duration = .milliseconds(8)
    var switchDelay: Duration = .zero
    var ordinaryCloseDelay: Duration = .milliseconds(260)
    var corridorGraceDuration: Duration = .milliseconds(320)
    var reverseDirectionCloseDelay: Duration = .milliseconds(90)
    var pointerHistoryDuration: TimeInterval = 0.16
    var maximumPointerSamples = 6
    var corridorPadding: CGFloat = 8

    static let menuBar = Self()
}

struct SmallWindowAnchorSnapshot: Equatable, Sendable {
    let id: SmallWindowAnchorID
    let screenRect: NSRect
    let parentPanelRole: SmallWindowPanelRole
    let preferredPlacementEdge: MenuBarCascadeDirection
    let contentKind: String
    let lastUpdatedLayoutGeneration: UInt
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
        contentKind: String
    ) -> Bool {
        guard screenRect.isUsableWindowAnchor else { return false }
        if let current = snapshots[id], current.screenRect.isApproximatelyEqual(to: screenRect) {
            return false
        }
        layoutGeneration &+= 1
        snapshots[id] = SmallWindowAnchorSnapshot(
            id: id,
            screenRect: screenRect,
            parentPanelRole: parentPanelRole,
            preferredPlacementEdge: preferredPlacementEdge,
            contentKind: contentKind,
            lastUpdatedLayoutGeneration: layoutGeneration
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportSnapshotIfNeeded()
    }

    override func layout() {
        super.layout()
        reportSnapshotIfNeeded()
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
        guard let window else { return }
        let rectInWindow = convert(bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        guard screenRect.isUsableWindowAnchor,
              lastReportedRect?.isApproximatelyEqual(to: screenRect) != true else { return }
        lastReportedRect = screenRect
        onSnapshotChanged?(screenRect, window)
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
    private var activeAnchorID: SmallWindowAnchorID?
    private var activePanelRole: SmallWindowPanelRole?
    private var windowGroupFrames: [NSRect] = []

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
        let isCrossingTowardOpenChild = isSwitch
            && pointerSamples.last.map { sample in
                windowGroupFrames.first?.contains(sample.point) == true
                    && windowGroupFrames.dropFirst().contains {
                        pointerDirection(toward: $0) == .toward
                    }
            } == true
        let resolvedDelay = delay
            ?? (isCrossingTowardOpenChild
                ? policy.corridorGraceDuration
                : isSwitch ? policy.switchDelay : policy.initialOpenDelay)
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: resolvedDelay)
            } catch {
                return
            }
            guard let self, isCurrent(request) else { return }
            pendingTask = nil
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
        let resolvedDelay = delay ?? recommendedCloseDelay()
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: resolvedDelay)
            } catch {
                return
            }
            guard let self, isCurrent(request) else { return }
            pendingTask = nil
            guard condition() else {
                restoreOpenState()
                return
            }
            markClosed()
            PerformanceTelemetry.signposter.emitEvent("HoverClosed")
            action()
        }
        return request
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
        pointerSamples.append(PointerSample(point: point, timestamp: timestamp))
        let cutoff = timestamp - policy.pointerHistoryDuration
        pointerSamples.removeAll { $0.timestamp < cutoff }
        if pointerSamples.count > policy.maximumPointerSamples {
            pointerSamples.removeFirst(pointerSamples.count - policy.maximumPointerSamples)
        }
    }

    func updateWindowGroupFrames(_ frames: [NSRect]) {
        windowGroupFrames = frames.filter(\.isUsableWindowAnchor)
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
        let corridors = zip(windowGroupFrames, windowGroupFrames.dropFirst()).map {
            HoverCorridor(
                source: $0.0,
                destination: $0.1,
                padding: policy.corridorPadding
            )
        }
        if windowGroupFrames.contains(where: { $0.contains(pointer) })
            || corridors.contains(where: { $0.contains(pointer) }) {
            PerformanceTelemetry.signposter.emitEvent("CorridorEntered")
            return policy.corridorGraceDuration
        }
        let nearest = windowGroupFrames.min {
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
