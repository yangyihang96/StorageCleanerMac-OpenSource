import AppKit

enum MenuBarCascadeDirection: Equatable, Sendable {
    case left
    case right

    var opposite: Self {
        self == .left ? .right : .left
    }
}

enum MenuBarTertiaryPresentationMode: Equatable, Sendable {
    case column
    case unavailable
}

enum MenuBarSecondaryPresentationMode: Equatable, Sendable {
    case adjacent
    case unavailable
}

enum MenuBarCascadeAlignment: Equatable, Sendable {
    case anchor
    case center
    case bottom
}

enum SmallWindowPlacementEdge: String, Equatable, Sendable {
    case left
    case right
    case below
    case above
}

struct SmallWindowPlacementDecision: Equatable, Sendable {
    let frame: NSRect
    let edge: SmallWindowPlacementEdge
    let score: CGFloat
    let flipped: Bool
}

struct MenuBarCascadeLayout: Equatable, Sendable {
    let direction: MenuBarCascadeDirection
    let alignment: MenuBarCascadeAlignment
    let parentFrame: NSRect
    let childFrames: [NSRect]
    let secondaryPresentationMode: MenuBarSecondaryPresentationMode
    let tertiaryPresentationMode: MenuBarTertiaryPresentationMode

    var visibleFrames: [NSRect] {
        [parentFrame] + childFrames
    }

    var containerFrame: NSRect {
        visibleFrames.dropFirst().reduce(parentFrame) { frame, child in
            frame.union(child)
        }
    }

    /// Converts a screen-coordinate child frame into the top-leading
    /// coordinate space used by the single hosting panel.
    func localFrame(for frame: NSRect) -> CGRect {
        let containerFrame = containerFrame
        return CGRect(
            x: frame.minX - containerFrame.minX,
            y: containerFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

enum MenuBarPanelPlacement {
    static let tertiaryColumnSize: NSSize = GeekPanelPresentationMetrics.tertiarySize
    static let tertiaryMaximumSize = GeekPanelPresentationMetrics.tertiaryMaximumSize

    static func anchor(statusItemFrame: NSRect?, fallbackPoint: NSPoint) -> NSRect {
        guard let statusItemFrame,
              statusItemFrame.minX.isFinite,
              statusItemFrame.minY.isFinite,
              statusItemFrame.width.isFinite,
              statusItemFrame.height.isFinite,
              statusItemFrame.width > 0,
              statusItemFrame.height > 0 else {
            return NSRect(x: fallbackPoint.x, y: fallbackPoint.y, width: 1, height: 1)
        }
        return statusItemFrame
    }

    static func frame(
        anchor: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect,
        margin: CGFloat = 8,
        gap: CGFloat = MiniWindowStyleTokens.anchorGap,
        backingScaleFactor: CGFloat = 1
    ) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let width = min(contentSize.width, bounds.width)
        let height = min(contentSize.height, bounds.height)
        let preferredX = anchor.midX - width / 2
        let maximumX = bounds.maxX - width
        let x = min(max(preferredX, bounds.minX), maximumX)
        let preferredY = anchor.minY - gap - height
        let y = min(max(preferredY, bounds.minY), bounds.maxY - height)

        return pixelAligned(
            NSRect(x: x, y: y, width: width, height: height),
            scale: backingScaleFactor,
            within: bounds
        )
    }

    /// Resolves one direction for the entire visible hierarchy without moving
    /// the status-item-anchored parent. A child is only returned when it fits
    /// wholly outside its parent. Level 3 may flip the complete child chain to
    /// the opposite side, but it never replaces or covers either parent level.
    static func cascade(
        parentFrame: NSRect,
        childSizes: [NSSize],
        visibleFrame: NSRect,
        preferredDirection: MenuBarCascadeDirection = .left,
        preferredAlignment: MenuBarCascadeAlignment = .anchor,
        margin: CGFloat = 8,
        gap: CGFloat = MiniWindowStyleTokens.cascadeGap,
        childTopOffsets: [CGFloat] = [],
        pointerLocation: NSPoint? = nil,
        backingScaleFactor: CGFloat = 1
    ) -> MenuBarCascadeLayout {
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let normalizedChildSizes = childSizes.map { size in
            NSSize(
                width: max(0, size.width),
                height: min(max(0, size.height), max(0, bounds.height))
            )
        }
        let normalizedTopOffsets = normalizedChildSizes.indices.map { index in
            guard childTopOffsets.indices.contains(index),
                  childTopOffsets[index].isFinite else { return CGFloat.zero }
            return max(0, childTopOffsets[index])
        }
        let leftSpace = max(0, parentFrame.minX - bounds.minX)
        let rightSpace = max(0, bounds.maxX - parentFrame.maxX)
        let space: (MenuBarCascadeDirection) -> CGFloat = { direction in
            direction == .left ? leftSpace : rightSpace
        }

        guard let secondarySize = normalizedChildSizes.first else {
            return MenuBarCascadeLayout(
                direction: preferredDirection,
                alignment: preferredAlignment,
                parentFrame: parentFrame,
                childFrames: [],
                secondaryPresentationMode: .adjacent,
                tertiaryPresentationMode: .column
            )
        }

        struct Candidate {
            let direction: MenuBarCascadeDirection
            let alignment: MenuBarCascadeAlignment
            let frames: [NSRect]
            let score: CGFloat
        }

        func preferredY(
            size: NSSize,
            offset: CGFloat,
            alignment: MenuBarCascadeAlignment
        ) -> CGFloat {
            switch alignment {
            case .anchor:
                return parentFrame.maxY - offset - size.height
            case .center:
                return parentFrame.midY - size.height / 2
            case .bottom:
                return parentFrame.minY
            }
        }

        func verticallyResolvedY(
            size: NSSize,
            offset: CGFloat,
            alignment: MenuBarCascadeAlignment
        ) -> CGFloat {
            let preferredY = preferredY(size: size, offset: offset, alignment: alignment)
            return min(max(preferredY, bounds.minY), bounds.maxY - size.height)
        }

        func horizontallyCascadedCandidate(
            _ sizes: [NSSize],
            offsets: [CGFloat],
            direction: MenuBarCascadeDirection,
            alignment: MenuBarCascadeAlignment
        ) -> Candidate? {
            let requiredSpace = sizes.reduce(0) { $0 + $1.width }
                + gap * CGFloat(sizes.count)
            guard requiredSpace <= space(direction) else { return nil }

            var cursor = direction == .left
                ? parentFrame.minX
                : parentFrame.maxX
            let frames = sizes.enumerated().map { index, size -> NSRect in
                let y = verticallyResolvedY(
                    size: size,
                    offset: offsets[index],
                    alignment: alignment
                )
                let x: CGFloat
                switch direction {
                case .left:
                    x = cursor - gap - size.width
                    cursor = x
                case .right:
                    x = cursor + gap
                    cursor = x + size.width
                }
                return pixelAligned(
                    NSRect(x: x, y: y, width: size.width, height: size.height),
                    scale: backingScaleFactor,
                    within: bounds
                )
            }
            guard frames.allSatisfy(bounds.contains), frames.arePairwiseDisjoint else {
                return nil
            }
            let directionPenalty: CGFloat = direction == preferredDirection ? 0 : 30
            let alignmentPenalty: CGFloat
            if alignment == preferredAlignment {
                alignmentPenalty = 0
            } else if alignment == .center {
                alignmentPenalty = 12
            } else {
                alignmentPenalty = 18
            }
            let verticalDisplacement = zip(frames, offsets).reduce(CGFloat.zero) {
                partial, pair in
                let preferredY = verticallyResolvedY(
                    size: pair.0.size,
                    offset: pair.1,
                    alignment: preferredAlignment
                )
                return partial + abs(pair.0.minY - preferredY)
            }
            let pointerPenalty: CGFloat
            if let pointerLocation, let first = frames.first {
                pointerPenalty = sqrt(first.distanceSquared(to: pointerLocation)) * 0.01
            } else {
                pointerPenalty = 0
            }
            return Candidate(
                direction: direction,
                alignment: alignment,
                frames: frames,
                score: directionPenalty + alignmentPenalty + verticalDisplacement * 0.08
                    + pointerPenalty
            )
        }

        func verticallyStackedFrames(
            _ sizes: [NSSize],
            aboveParent: Bool
        ) -> [NSRect]? {
            var cursor = aboveParent ? parentFrame.maxY : parentFrame.minY
            let frames = sizes.map { size -> NSRect in
                let x = min(
                    max(parentFrame.maxX - size.width, bounds.minX),
                    bounds.maxX - size.width
                )
                let y: CGFloat
                if aboveParent {
                    y = cursor + gap
                    cursor = y + size.height
                } else {
                    y = cursor - gap - size.height
                    cursor = y
                }
                return NSRect(x: x, y: y, width: size.width, height: size.height)
            }
            let aligned = frames.map {
                pixelAligned($0, scale: backingScaleFactor, within: bounds)
            }
            return aligned.allSatisfy(bounds.contains)
                && aligned.arePairwiseDisjoint
                && !aligned.contains(where: { $0.intersects(parentFrame) })
                ? aligned
                : nil
        }

        func resolvedCandidate(
            _ sizes: [NSSize],
            offsets: [CGFloat]
        ) -> Candidate? {
            let alignments = [preferredAlignment]
            let currentDirectionCandidates = alignments.compactMap {
                horizontallyCascadedCandidate(
                    sizes,
                    offsets: offsets,
                    direction: preferredDirection,
                    alignment: $0
                )
            }
            // Placement hysteresis: a fully visible candidate on the current
            // side wins even when the opposite side has a few more points.
            if let current = currentDirectionCandidates.min(by: { $0.score < $1.score }) {
                return current
            }
            let flippedCandidates = alignments.compactMap {
                horizontallyCascadedCandidate(
                    sizes,
                    offsets: offsets,
                    direction: preferredDirection.opposite,
                    alignment: $0
                )
            }
            if let flipped = flippedCandidates.min(by: { $0.score < $1.score }) {
                return flipped
            }

            // When neither horizontal side fits, keep every shell fully
            // visible by stacking below the summary first, then above it.
            for aboveParent in [false, true] {
                if let frames = verticallyStackedFrames(sizes, aboveParent: aboveParent) {
                    return Candidate(
                        direction: preferredDirection,
                        alignment: aboveParent ? .bottom : .anchor,
                        frames: frames,
                        score: 100
                    )
                }
            }

            return nil
        }

        let hasTertiaryLevel = normalizedChildSizes.count > 1
        if let complete = resolvedCandidate(normalizedChildSizes, offsets: normalizedTopOffsets) {
            return MenuBarCascadeLayout(
                direction: complete.direction,
                alignment: complete.alignment,
                parentFrame: parentFrame,
                childFrames: complete.frames,
                secondaryPresentationMode: .adjacent,
                tertiaryPresentationMode: .column
            )
        }

        if let secondary = resolvedCandidate([secondarySize], offsets: [normalizedTopOffsets[0]]) {
            return MenuBarCascadeLayout(
                direction: secondary.direction,
                alignment: secondary.alignment,
                parentFrame: parentFrame,
                childFrames: secondary.frames,
                secondaryPresentationMode: .adjacent,
                tertiaryPresentationMode: hasTertiaryLevel ? .unavailable : .column
            )
        }

        return MenuBarCascadeLayout(
            direction: preferredDirection,
            alignment: preferredAlignment,
            parentFrame: parentFrame,
            childFrames: [],
            secondaryPresentationMode: .unavailable,
            tertiaryPresentationMode: hasTertiaryLevel ? .unavailable : .column
        )
    }

    static func pixelAligned(
        _ frame: NSRect,
        scale: CGFloat,
        within bounds: NSRect? = nil
    ) -> NSRect {
        let scale = max(1, scale.isFinite ? scale : 1)
        var aligned = NSRect(
            x: (frame.minX * scale).rounded() / scale,
            y: (frame.minY * scale).rounded() / scale,
            width: (frame.width * scale).rounded() / scale,
            height: (frame.height * scale).rounded() / scale
        )
        if let bounds {
            aligned.origin.x = min(max(aligned.minX, bounds.minX), bounds.maxX - aligned.width)
            aligned.origin.y = min(max(aligned.minY, bounds.minY), bounds.maxY - aligned.height)
        }
        return aligned
    }

    static func detachedPanel(
        anchor: NSRect,
        size: NSSize,
        visibleFrame: NSRect,
        preferredEdges: [SmallWindowPlacementEdge],
        previousEdge: SmallWindowPlacementEdge? = nil,
        gap: CGFloat,
        margin: CGFloat = 0,
        avoidFrames: [NSRect] = [],
        pointerLocation: NSPoint? = nil,
        backingScaleFactor: CGFloat = 1
    ) -> SmallWindowPlacementDecision {
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let normalizedSize = NSSize(
            width: min(max(0, size.width), bounds.width),
            height: min(max(0, size.height), bounds.height)
        )
        let orderedEdges = ([previousEdge].compactMap { $0 } + preferredEdges)
            .reduce(into: [SmallWindowPlacementEdge]()) { edges, edge in
                if !edges.contains(edge) { edges.append(edge) }
            }

        func candidateFrame(for edge: SmallWindowPlacementEdge) -> NSRect {
            let raw: NSRect
            switch edge {
            case .left:
                raw = NSRect(
                    x: anchor.minX - gap - normalizedSize.width,
                    y: anchor.maxY - normalizedSize.height,
                    width: normalizedSize.width,
                    height: normalizedSize.height
                )
            case .right:
                raw = NSRect(
                    x: anchor.maxX + gap,
                    y: anchor.maxY - normalizedSize.height,
                    width: normalizedSize.width,
                    height: normalizedSize.height
                )
            case .below:
                raw = NSRect(
                    x: anchor.midX - normalizedSize.width / 2,
                    y: anchor.minY - gap - normalizedSize.height,
                    width: normalizedSize.width,
                    height: normalizedSize.height
                )
            case .above:
                raw = NSRect(
                    x: anchor.midX - normalizedSize.width / 2,
                    y: anchor.maxY + gap,
                    width: normalizedSize.width,
                    height: normalizedSize.height
                )
            }
            var clamped = raw
            if edge == .left || edge == .right {
                clamped.origin.y = min(
                    max(raw.minY, bounds.minY),
                    bounds.maxY - raw.height
                )
            } else {
                clamped.origin.x = min(
                    max(raw.minX, bounds.minX),
                    bounds.maxX - raw.width
                )
            }
            return pixelAligned(
                clamped,
                scale: backingScaleFactor,
                within: bounds
            )
        }

        let candidates = orderedEdges.enumerated().map { index, edge in
            let frame = candidateFrame(for: edge)
            let rawFrame = rawDetachedFrame(
                anchor: anchor,
                size: normalizedSize,
                edge: edge,
                gap: gap
            )
            // Perpendicular clamping is expected (for example a tall palette
            // beside a row near the menu bar). Only penalize lack of space on
            // the attachment axis; otherwise a clamped side candidate can
            // incorrectly lose to a panel that overlaps its parent.
            let overflow: CGFloat
            switch edge {
            case .left, .right:
                let visibleWidth = max(
                    0,
                    min(rawFrame.maxX, bounds.maxX) - max(rawFrame.minX, bounds.minX)
                )
                overflow = (rawFrame.width - visibleWidth) * rawFrame.height
            case .below, .above:
                let visibleHeight = max(
                    0,
                    min(rawFrame.maxY, bounds.maxY) - max(rawFrame.minY, bounds.minY)
                )
                overflow = (rawFrame.height - visibleHeight) * rawFrame.width
            }
            let overlap = avoidFrames.reduce(CGFloat.zero) {
                $0 + frame.intersection($1).area
            }
            let clampingDistance = hypot(
                frame.midX - rawFrame.midX,
                frame.midY - rawFrame.midY
            )
            let previousPenalty: CGFloat = previousEdge == nil || previousEdge == edge ? 0 : 24
            let pointerPenalty: CGFloat
            if let pointerLocation {
                pointerPenalty = sqrt(frame.distanceSquared(to: pointerLocation)) * 0.01
            } else {
                pointerPenalty = 0
            }
            return SmallWindowPlacementDecision(
                frame: frame,
                edge: edge,
                score: overflow * 10_000 + overlap * 1_000
                    + CGFloat(index) * 8 + previousPenalty + pointerPenalty
                    + clampingDistance * 0.1,
                flipped: previousEdge.map { $0 != edge } ?? false
            )
        }
        return candidates.min(by: { $0.score < $1.score })
            ?? SmallWindowPlacementDecision(
                frame: pixelAligned(
                    NSRect(origin: bounds.origin, size: normalizedSize),
                    scale: backingScaleFactor,
                    within: bounds
                ),
                edge: preferredEdges.first ?? .below,
                score: .greatestFiniteMagnitude,
                flipped: false
            )
    }

    private static func rawDetachedFrame(
        anchor: NSRect,
        size: NSSize,
        edge: SmallWindowPlacementEdge,
        gap: CGFloat
    ) -> NSRect {
        switch edge {
        case .left:
            NSRect(
                x: anchor.minX - gap - size.width,
                y: anchor.maxY - size.height,
                width: size.width,
                height: size.height
            )
        case .right:
            NSRect(
                x: anchor.maxX + gap,
                y: anchor.maxY - size.height,
                width: size.width,
                height: size.height
            )
        case .below:
            NSRect(
                x: anchor.midX - size.width / 2,
                y: anchor.minY - gap - size.height,
                width: size.width,
                height: size.height
            )
        case .above:
            NSRect(
                x: anchor.midX - size.width / 2,
                y: anchor.maxY + gap,
                width: size.width,
                height: size.height
            )
        }
    }
}

private extension NSRect {
    var area: CGFloat {
        isNull ? 0 : max(0, width) * max(0, height)
    }
}

private extension Array where Element == NSRect {
    var arePairwiseDisjoint: Bool {
        for index in indices {
            for otherIndex in indices where otherIndex > index {
                if self[index].intersects(self[otherIndex]) { return false }
            }
        }
        return true
    }
}

@MainActor
enum ScreenContextResolver {
    static func resolve(
        anchorWindowScreen: NSScreen? = nil,
        statusItemScreen: NSScreen? = nil,
        anchorRect: NSRect? = nil,
        pointerLocation: NSPoint = NSEvent.mouseLocation,
        fallbackScreen: NSScreen? = nil,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSScreen? {
        if let screen = live(anchorWindowScreen, in: screens) { return screen }
        if let screen = live(statusItemScreen, in: screens) { return screen }
        if let anchorRect {
            let center = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
            if let screen = screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        if let screen = screens.first(where: { $0.frame.contains(pointerLocation) }) {
            return screen
        }
        if let screen = live(fallbackScreen, in: screens) { return screen }
        return live(NSScreen.main, in: screens) ?? screens.first
    }

    static func identifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber {
            return number.stringValue
        }
        return "\(Int(screen.frame.minX)),\(Int(screen.frame.minY))-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    private static func live(_ candidate: NSScreen?, in screens: [NSScreen]) -> NSScreen? {
        guard let candidate else { return nil }
        return screens.first(where: { $0 === candidate })
    }
}
