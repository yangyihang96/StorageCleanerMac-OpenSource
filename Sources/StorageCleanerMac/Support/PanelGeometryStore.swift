import AppKit

struct PanelGeometryStore {
    private static let keyPrefix = "menuBar.panelFrame"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func storedFrame(for density: PanelDensity) -> NSRect? {
        guard let value = defaults.string(forKey: key(for: density)) else { return nil }
        let frame = NSRectFromString(value)
        return isValid(frame) ? frame : nil
    }

    func save(frame: NSRect, for density: PanelDensity) {
        guard isValid(frame) else { return }
        defaults.set(NSStringFromRect(frame), forKey: key(for: density))
    }

    func resolvedFrame(
        for density: PanelDensity,
        anchor: NSRect,
        preferredVisibleFrame: NSRect,
        availableVisibleFrames _: [NSRect]
    ) -> NSRect {
        // A menu-bar panel is transient: its opening position belongs to the
        // status item that was clicked, never to a stale frame from another
        // display or a previous session. Stored geometry remains readable for
        // migration, but it must not override the live anchor.
        MenuBarPanelPlacement.frame(
            anchor: anchor,
            contentSize: density.idealSize,
            visibleFrame: preferredVisibleFrame
        )
    }

    func clamped(frame: NSRect, density: PanelDensity, visibleFrame: NSRect) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(density.idealSize.width, bounds.width)
        let height = min(density.idealSize.height, bounds.height)
        let originX = min(max(frame.minX, bounds.minX), bounds.maxX - width)
        let originY = min(max(frame.minY, bounds.minY), bounds.maxY - height)
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    private func key(for density: PanelDensity) -> String {
        "\(Self.keyPrefix).\(density.rawValue)"
    }

    private func isValid(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.size.width.isFinite
            && frame.size.height.isFinite
            && frame.size.width > 0
            && frame.size.height > 0
    }

}

extension PanelDensity {
    var idealSize: NSSize {
        switch self {
        case .simple: NSSize(width: 420, height: 280)
        case .complex, .geek: MiniWindowStyleTokens.overviewSize
        }
    }

    var minimumSize: NSSize {
        idealSize
    }
}
