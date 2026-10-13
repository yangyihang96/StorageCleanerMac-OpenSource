import AppKit

extension MenuBarPanelPlacement {
    /// Unlike the legacy fixed-anchor cascade, reserve room for the entire
    /// hierarchy and allow the primary surface to translate on its own display.
    static func reflowingCascade(
        parentFrame: NSRect, childSizes: [NSSize], visibleFrame: NSRect,
        preferredDirection: MenuBarCascadeDirection = .left,
        preferredAlignment: MenuBarCascadeAlignment = .anchor,
        margin: CGFloat = 8, gap: CGFloat = MiniWindowStyleTokens.cascadeGap,
        childTopOffsets: [CGFloat] = [], pointerLocation: NSPoint? = nil,
        backingScaleFactor: CGFloat = 1, scrollsTallDetails: Bool = false
    ) -> MenuBarCascadeLayout {
        // D76: power is an adjacent secondary page even when its many cards
        // exceed the screen height. The existing fitted page scrolls inside
        // this viewport, preserving natural content size and the overview.
        let viewportChildren = scrollsTallDetails
            ? scrollingDetailSizes(childSizes, visibleFrame: visibleFrame, margin: margin,
                                   backingScaleFactor: backingScaleFactor)
            : childSizes
        guard let result = CascadeViewportLayout.solve(
            parent: parentFrame, children: viewportChildren, visible: visibleFrame,
            prefersLeft: preferredDirection == .left, offsets: childTopOffsets,
            margin: margin, gap: gap, scale: backingScaleFactor
        ) else {
            // Invalid/stale geometry is not a reason to mutate the route. The
            // session retains its last valid layout until a fresh display event.
            return cascade(parentFrame: parentFrame, childSizes: childSizes,
                visibleFrame: visibleFrame, preferredDirection: preferredDirection,
                preferredAlignment: preferredAlignment, margin: margin, gap: gap,
                childTopOffsets: childTopOffsets, pointerLocation: pointerLocation,
                backingScaleFactor: backingScaleFactor)
        }
        return MenuBarCascadeLayout(
            direction: result.expandsLeft ? .left : .right,
            alignment: preferredAlignment, parentFrame: result.parent,
            childFrames: result.children, secondaryPresentationMode: .adjacent,
            tertiaryPresentationMode: .column, isCompact: result.arrangement == .compact
        )
    }

    private static func scrollingDetailSizes(_ sizes: [NSSize], visibleFrame: NSRect,
                                            margin: CGFloat, backingScaleFactor: CGFloat) -> [NSSize] {
        guard visibleFrame.height.isFinite, visibleFrame.height > 0,
              visibleFrame.minY.isFinite, visibleFrame.maxY.isFinite else { return sizes }
        let scale = backingScaleFactor.isFinite && (1...8).contains(backingScaleFactor) ? backingScaleFactor : 1
        let inset = margin.isFinite ? max(0, margin) : 8
        let height = floor((visibleFrame.maxY - inset) * scale) / scale
            - ceil((visibleFrame.minY + inset) * scale) / scale
        guard height > 0 else { return sizes }
        return sizes.map { size in
            guard size.height.isFinite, size.height > 0 else { return size }
            return NSSize(width: size.width, height: min(size.height, height))
        }
    }
}
