import Foundation

enum SpaceMapViewStyle: String, CaseIterable, Sendable {
    case bubbles, blocks
}

enum SpaceMapColorMode: String, CaseIterable, Sendable {
    case type, purpose
}

// View transforms, transition mapping and directional scoring adapted from
// disktree/app/state.rs (MIT, © 2026 Tobi Lütke). The full permission and
// warranty notice is in SpaceMapTreemapLayout.swift.
struct SpaceMapTreemapViewState: Equatable, Sendable {
    typealias Tile = SpaceMapTreemapLayout.Tile

    struct Viewport: Equatable, Sendable {
        var scale: CGFloat = 1
        var origin: CGPoint = .zero

        func project(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }

        func unproject(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / scale + origin.x, y: point.y / scale + origin.y)
        }

        func zoomed(at point: CGPoint, factor: CGFloat, ceiling: CGFloat) -> Self {
            guard factor.isFinite, factor > 0 else { return self }
            let next = min(max(1, ceiling), max(1, scale * factor))
            let base = unproject(point)
            return Self(scale: next, origin: CGPoint(x: base.x - point.x / next, y: base.y - point.y / next))
        }

        func clamped(to size: CGSize) -> Self {
            Self(scale: scale, origin: CGPoint(
                x: min(max(0, origin.x), max(0, size.width - size.width / scale)),
                y: min(max(0, origin.y), max(0, size.height - size.height / scale))))
        }

        static func fitScale(_ rect: CGRect, in size: CGSize) -> CGFloat {
            guard rect.width > 0, rect.height > 0 else { return 1 }
            return min(max(1, size.width) / rect.width, max(1, size.height) / rect.height)
        }
    }

    enum Phase: Equatable, Sendable { case none, began, changed, ended, cancelled }

    /// Every event advances the gate, including events that only scale. The
    /// consumed bit survives the gesture's end so momentum cannot reopen it.
    struct GestureGate: Equatable, Sendable {
        private(set) var consumed = false
        private(set) var lastNavigationTime: TimeInterval?

        mutating func allowsNavigation(phase: Phase, momentum: Bool, time: TimeInterval, requested: Bool) -> Bool {
            if phase == .began && !momentum { consumed = false }
            guard requested, !momentum, phase != .cancelled else { return false }
            if phase == .none {
                guard lastNavigationTime.map({ time - $0 >= 0.3 }) ?? true else { return false }
            } else if consumed {
                return false
            }
            consumed = true
            lastNavigationTime = time
            return true
        }
    }

    enum Action: Equatable, Sendable {
        case none
        case enter(StorageTreemapEntry, from: CGRect)
        case back
        case reset(from: Viewport)
    }

    struct Transition: Equatable, Sendable {
        let source: CGRect
        let destination: CGRect
        let started: TimeInterval
        let duration: TimeInterval

        init(source: CGRect, destination: CGRect, started: TimeInterval, reduceMotion: Bool = false) {
            self.source = source
            self.destination = destination
            self.started = started
            let ratio = max(source.width / max(1, destination.width), destination.width / max(1, source.width),
                            source.height / max(1, destination.height), destination.height / max(1, source.height), 1)
            duration = reduceMotion ? 0 : (130 + 45 * min(4, max(0, log2(ratio)))) / 1_000
        }

        func isRunning(at time: TimeInterval) -> Bool { duration > 0 && time - started < duration }

        func sample(_ rect: CGRect, at time: TimeInterval) -> CGRect {
            let progress = duration > 0 ? min(1, max(0, (time - started) / duration)) : 1
            let eased = 1 - pow(1 - progress, 3)
            let sx = source.width / max(0.001, destination.width)
            let sy = source.height / max(0.001, destination.height)
            let from = CGRect(x: source.minX + (rect.minX - destination.minX) * sx,
                              y: source.minY + (rect.minY - destination.minY) * sy,
                              width: rect.width * sx, height: rect.height * sy)
            func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
            return CGRect(x: lerp(from.minX, rect.minX), y: lerp(from.minY, rect.minY),
                          width: lerp(from.width, rect.width), height: lerp(from.height, rect.height))
        }
    }

    enum Direction: Equatable, Sendable {
        case left, right, up, down

        func score(from: CGRect, to rect: CGRect) -> CGFloat? {
            let gap: CGFloat
            let overlap: CGFloat
            let side: CGFloat
            switch self {
            case .right, .left:
                gap = self == .right ? rect.minX - from.maxX : from.minX - rect.maxX
                overlap = max(0, min(from.maxY, rect.maxY) - max(from.minY, rect.minY))
                side = min(from.height, rect.height)
            case .down, .up:
                gap = self == .down ? rect.minY - from.maxY : from.minY - rect.maxY
                overlap = max(0, min(from.maxX, rect.maxX) - max(from.minX, rect.minX))
                side = min(from.width, rect.width)
            }
            guard gap >= -0.5 else { return nil }
            return max(0, gap) + max(0, side - overlap) * 2.5
        }
    }

    var viewport = Viewport()
    var selectedID: String?
    var gesture = GestureGate()

    static func id(_ tile: Tile) -> String {
        switch tile.kind {
        case let .entry(entry): entry.id
        case let .others(parent, _, _): "others:" + parent
        }
    }

    static func body(_ tile: Tile) -> CGRect {
        guard let header = tile.header else { return tile.frame }
        return CGRect(x: tile.frame.minX, y: header.maxY, width: tile.frame.width,
                      height: max(0, tile.frame.maxY - header.maxY))
    }

    static func parentPath(_ tile: Tile) -> String {
        switch tile.kind {
        case let .entry(entry): DiskScanner.storageMapParentPath(entry.path)
        case let .others(parent, _, _): parent
        }
    }

    static func highlightedID(for tile: Tile?, roots: [StorageTreemapEntry]) -> String? {
        guard let tile, case let .entry(entry) = tile.kind, entry.role == .content else { return nil }
        return roots.first { $0.role == .content && (entry.path == $0.path || entry.path.hasPrefix($0.path + "/")) }?.id
    }

    func zoomTarget(at point: CGPoint, tiles: [Tile]) -> Tile? {
        let base = viewport.unproject(point)
        return tiles.reversed().first {
            guard $0.frame.contains(base), case let .entry(entry) = $0.kind else { return false }
            return entry.role == .content && entry.isDirectory && entry.canDescend && !entry.isCloudOnly
                && entry.kind != "package" && (entry.childCount ?? 0) > 0
        }
    }

    func zoomCeiling(at point: CGPoint, tiles: [Tile], size: CGSize) -> CGFloat {
        zoomTarget(at: point, tiles: tiles).map { min(5, max(1, Viewport.fitScale(Self.body($0), in: size))) } ?? 1
    }

    /// AppKit's inverted deltas are converted to device direction before
    /// applying the same exponent to wheels and precision trackpads.
    static func scrollLines(deltaY: CGFloat, precise: Bool, inverted: Bool) -> CGFloat {
        let lines = (inverted ? -deltaY : deltaY) / (precise ? 24 : 1)
        return min(3, max(-3, lines))
    }

    mutating func zoom(factor: CGFloat, at point: CGPoint, tiles: [Tile], size: CGSize,
                       phase: Phase, momentum: Bool, time: TimeInterval, canNavigate: Bool) -> Action {
        let target = zoomTarget(at: point, tiles: tiles)
        let ceiling = zoomCeiling(at: point, tiles: tiles, size: size)
        let goesBack = factor < 1 && viewport.scale <= 1.000_001
        let enters = factor > 1 && target != nil && viewport.scale >= ceiling - 0.000_001
        let allowed = gesture.allowsNavigation(phase: phase, momentum: momentum, time: time,
                                               requested: canNavigate && (goesBack || enters))
        if allowed && goesBack { return .back }
        if allowed, enters, let target, case let .entry(entry) = target.kind {
            return .enter(entry, from: viewport.project(Self.body(target)))
        }
        guard factor.isFinite, factor > 0, !goesBack else { return .none }
        if factor > 1 && target == nil { return .none }
        viewport = viewport.zoomed(at: point, factor: factor,
                                   ceiling: factor < 1 ? max(viewport.scale, ceiling) : ceiling).clamped(to: size)
        return .none
    }

    mutating func pan(by delta: CGSize, size: CGSize) {
        guard viewport.scale > 1 else { return }
        viewport.origin.x -= delta.width / viewport.scale
        viewport.origin.y -= delta.height / viewport.scale
        viewport = viewport.clamped(to: size)
    }

    mutating func escape(canNavigate: Bool) -> Action {
        if viewport.scale > 1 {
            let previous = viewport
            viewport = Viewport()
            return .reset(from: previous)
        }
        return canNavigate ? .back : .none
    }

    mutating func move(_ direction: Direction, tiles: [Tile]) {
        guard let current = tiles.first(where: { Self.id($0) == selectedID }) else {
            selectedID = tiles.filter { $0.depth == 0 }.max {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }.map(Self.id)
            return
        }
        let candidates = tiles.compactMap { tile -> (Tile, CGFloat)? in
            guard tile.depth == current.depth, Self.id(tile) != Self.id(current),
                  tile.depth == 0 || Self.parentPath(tile) == Self.parentPath(current),
                  let score = direction.score(from: current.frame, to: tile.frame) else { return nil }
            return (tile, score)
        }
        if let next = candidates.min(by: { $0.1 < $1.1 }) { selectedID = Self.id(next.0) }
    }
}
