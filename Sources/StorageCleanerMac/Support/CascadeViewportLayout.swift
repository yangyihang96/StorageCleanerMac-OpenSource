import Foundation

/// Geometry only: use one display's visibleFrame in logical points. No windows,
/// screen lookup, timers, hardware queries or publication happen in this solver.
enum CascadeViewportLayout {
    enum Arrangement: Equatable { case columns, stackedDetails, stackedAll, compact }
    struct Result: Equatable {
        let parent: CGRect
        let children: [CGRect]
        let expandsLeft: Bool
        let arrangement: Arrangement
        var frames: [CGRect] { [parent] + children }
    }

    static func solve(parent: CGRect, children: [CGSize], visible: CGRect,
                      prefersLeft: Bool, offsets: [CGFloat] = [],
                      margin: CGFloat = 8, gap: CGFloat = 0,
                      scale: CGFloat = 1) -> Result? {
        guard valid(visible), valid(parent), children.count <= 2,
              children.allSatisfy({ valid($0) }) else { return nil }
        let scale = scale.isFinite && scale >= 1 && scale <= 8 ? scale : 1
        let margin = margin.isFinite ? max(0, margin) : 8
        let logicalGap = gap.isFinite ? max(0, gap) : 0
        // Align INWARD. Rounding a 99.75pt viewport to a 100pt window overflows.
        let inset = min(margin, max(0, (min(visible.width, visible.height) - 1 / scale) / 2))
        let raw = visible.insetBy(dx: inset, dy: inset)
        let x0 = ceil(raw.minX * scale) / scale, y0 = ceil(raw.minY * scale) / scale
        let x1 = floor(raw.maxX * scale) / scale, y1 = floor(raw.maxY * scale) / scale
        guard x1 > x0, y1 > y0 else { return nil }
        let bounds = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        func up(_ value: CGFloat) -> CGFloat { ceil(value * scale) / scale }
        func position(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            min(max((value * scale).rounded() / scale, low), high)
        }
        let p = CGSize(width: up(parent.width), height: up(parent.height))
        let sizes = children.map { CGSize(width: up($0.width), height: up($0.height)) }
        let gap = up(logicalGap)
        func offset(_ i: Int) -> CGFloat {
            guard offsets.indices.contains(i), offsets[i].isFinite else { return 0 }
            return max(0, offsets[i])
        }
        func y(_ height: CGFloat, offset: CGFloat = 0) -> CGFloat {
            position(parent.maxY - offset - height, low: bounds.minY, high: bounds.maxY - height)
        }
        struct Candidate { let result: Result; let displacement: CGFloat; let preferred: Bool }
        func best(_ candidates: [Candidate]) -> Result? {
            // A previously valid side never flips merely because another scores
            // fractionally better. Minimize primary movement before tie-breaking.
            candidates.min {
                let a = $0.displacement + ($0.preferred ? 0 : 24)
                let b = $1.displacement + ($1.preferred ? 0 : 24)
                return a < b
            }?.result
        }
        func validFrames(_ frames: [CGRect]) -> Bool {
            guard frames.allSatisfy({ bounds.contains($0) }) else { return false }
            for i in frames.indices {
                for j in frames.indices where j > i {
                    let overlap = frames[i].intersection(frames[j])
                    if !overlap.isNull && overlap.width > 0.000001 && overlap.height > 0.000001 { return false }
                }
            }
            return true
        }
        let totalWidth = p.width + sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(sizes.count)
        if totalWidth <= bounds.width, ([p] + sizes).allSatisfy({ $0.height <= bounds.height }) {
            let extra = totalWidth - p.width
            let candidates = [prefersLeft, !prefersLeft].compactMap { left -> Candidate? in
                let px = position(parent.minX, low: bounds.minX + (left ? extra : 0),
                                  high: bounds.maxX - p.width - (left ? 0 : extra))
                let primary = CGRect(origin: CGPoint(x: px, y: y(p.height)), size: p)
                var cursor = left ? primary.minX : primary.maxX
                let frames = sizes.enumerated().map { index, size -> CGRect in
                    let x = left ? cursor - gap - size.width : cursor + gap
                    let frame = CGRect(origin: CGPoint(x: x, y: y(size.height, offset: offset(index))), size: size)
                    cursor = left ? frame.minX : frame.maxX
                    return frame
                }
                guard validFrames([primary] + frames) else { return nil }
                return Candidate(result: Result(parent: primary, children: frames, expandsLeft: left,
                                                  arrangement: .columns),
                                 displacement: abs(px - parent.minX), preferred: left == prefersLeft)
            }
            if let result = best(candidates) { return result }
        }
        // Portrait displays can fit two readable columns with level 3 BELOW
        // level 2, even when the sum of all three widths cannot fit horizontally.
        if !sizes.isEmpty {
            let columnWidth = sizes.map(\.width).max() ?? 0
            let columnHeight = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(sizes.count - 1)
            if p.width + gap + columnWidth <= bounds.width,
               max(p.height, columnHeight) <= bounds.height {
                let candidates = [prefersLeft, !prefersLeft].compactMap { left -> Candidate? in
                    let px = position(parent.minX, low: bounds.minX + (left ? gap + columnWidth : 0),
                                      high: bounds.maxX - p.width - (left ? 0 : gap + columnWidth))
                    let primary = CGRect(origin: CGPoint(x: px, y: y(p.height)), size: p)
                    var top = y(columnHeight, offset: offset(0)) + columnHeight
                    let frames = sizes.map { size -> CGRect in
                        let x = left ? px - gap - size.width : px + p.width + gap
                        let f = CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
                        top = f.minY - gap
                        return f
                    }
                    guard validFrames([primary] + frames) else { return nil }
                    return Candidate(result: Result(parent: primary, children: frames, expandsLeft: left,
                                                      arrangement: .stackedDetails),
                                     displacement: abs(px - parent.minX), preferred: left == prefersLeft)
                }
                if let result = best(candidates) { return result }
            }
        }
        let all = [p] + sizes
        let height = all.reduce(0) { $0 + $1.height } + gap * CGFloat(sizes.count)
        let width = all.map(\.width).max() ?? p.width
        if width <= bounds.width, height <= bounds.height {
            let x = position(parent.minX, low: bounds.minX, high: bounds.maxX - width)
            var top = y(height) + height
            let frames = all.map { size -> CGRect in
                let frame = CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
                top = frame.minY - gap
                return frame
            }
            if validFrames(frames) {
                return Result(parent: frames[0], children: Array(frames.dropFirst()),
                              expandsLeft: prefersLeft, arrangement: .stackedAll)
            }
        }
        // Only one page is visible in this mode. The shell supplies Back/Home
        // and scrolling; do not shrink text or erase the user's selected route.
        let viewportSize = CGSize(width: min(width, bounds.width),
                                  height: min(max(all.map(\.height).max() ?? p.height, 320) + 44, bounds.height))
        let viewport = CGRect(x: position(parent.minX, low: bounds.minX, high: bounds.maxX - viewportSize.width),
                              y: y(viewportSize.height), width: viewportSize.width, height: viewportSize.height)
        return Result(parent: viewport, children: sizes.map { _ in viewport },
                      expandsLeft: prefersLeft, arrangement: .compact)
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width < 1_000_000 && size.height < 1_000_000
    }
    private static func valid(_ rect: CGRect) -> Bool {
        valid(rect.size) && rect.origin.x.isFinite && rect.origin.y.isFinite
            && abs(rect.origin.x) < 1_000_000 && abs(rect.origin.y) < 1_000_000
    }
}

/// Layout changes are not mouse gestures. Keep a newly opened hierarchy alive
/// while the pointer is stationary, but never suppress Escape or outside clicks.
struct CascadeStationaryPointerGuard {
    private(set) var origin: CGPoint?
    private var expiresAt: TimeInterval = 0
    mutating func begin(previous: [CGRect], next: [CGRect], pointer: CGPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard pointer.x.isFinite, pointer.y.isFinite, previous != next,
              previous.contains(where: { $0.contains(pointer) }) else { return }
        // Repeated layout callbacks cannot indefinitely renew this protection.
        guard origin == nil else { return }
        origin = pointer
        expiresAt = now + 0.45
    }
    mutating func retains(_ pointer: CGPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let origin else { return false }
        guard now < expiresAt, pointer.x.isFinite, pointer.y.isFinite,
              hypot(pointer.x - origin.x, pointer.y - origin.y) <= 2 else {
            self.origin = nil
            return false
        }
        return true
    }
    mutating func reset() { origin = nil; expiresAt = 0 }
}
