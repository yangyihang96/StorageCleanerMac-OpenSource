import AppKit

final class MenuBarStatusPanel: NSPanel {
    var onPointerLocationChanged: ((NSPoint) -> Void)?
    var onEscape: (() -> Bool)?
    private let pointerTrackingView = MenuBarPanelPointerTrackingView()

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        collectionBehavior = [
            .moveToActiveSpace,
            .ignoresCycle,
            .fullScreenAuxiliary,
            .canJoinAllApplications
        ]
        isMovableByWindowBackground = false
        preservesContentDuringLiveResize = false
        let panelTitle = L10n.text(
            "存储清理助手菜单栏面板",
            "Storage Cleaner Menu Bar Panel"
        )
        title = panelTitle
        setAccessibilityLabel(panelTitle)
        isOpaque = false
        backgroundColor = .clear
        // The content hosts multiple visually independent mini-window shells.
        // A panel-level shadow would join their transparent bounds into one
        // large rectangle, so each shell renders its own shadow in SwiftUI.
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // This reusable menu-bar surface must appear immediately. Avoiding
        // whole-window animation also prevents hover-opened detail surfaces
        // from feeling like a new window and inherently respects Reduce Motion.
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        setAlwaysOnTop(
            UserDefaults.standard.object(
                forKey: MenuBarPanelSettingsState.alwaysOnTopDefaultsKey
            ) == nil
                ? true
                : UserDefaults.standard.bool(
                    forKey: MenuBarPanelSettingsState.alwaysOnTopDefaultsKey
                )
        )
    }

    func installPointerTracking() {
        guard let contentView,
              let trackingContainer = contentView.superview,
              pointerTrackingView.superview !== trackingContainer else { return }
        pointerTrackingView.removeFromSuperview()
        pointerTrackingView.frame = contentView.frame
        pointerTrackingView.autoresizingMask = [.width, .height]
        pointerTrackingView.onPointerLocationChanged = { [weak self] point in
            self?.onPointerLocationChanged?(point)
        }
        trackingContainer.addSubview(
            pointerTrackingView,
            positioned: .above,
            relativeTo: contentView
        )
    }

    func setAlwaysOnTop(_ value: Bool) {
        isFloatingPanel = value
        // Menu-bar panels must remain above ordinary app windows and the Dock
        // while visible. `.statusBar` is the native level for that behavior;
        // `.popUpMenu` is intentionally avoided so menus and outside-click
        // dismissal keep their normal AppKit semantics.
        // Unpinned still means a transient menu, not an ordinary app window.
        // Keep it above the foreground app without activating that app's peer.
        level = value ? .statusBar : .floating
    }

    override func sendEvent(_ event: NSEvent) {
#if DEBUG || STORAGE_CLEANER_BETA
        if event.type == .leftMouseDown || event.type == .leftMouseUp || event.type == .keyDown {
            let hit = contentView.flatMap { view in
                view.hitTest(view.convert(event.locationInWindow, from: nil))
            }
            PerformanceTelemetry.panelInput("dispatch", target: hit.map { NSStringFromClass(type(of: $0)) } ?? "no-content-hit", window: self, event: event)
        }
#endif
        if event.type == .keyDown,
           event.keyCode == 53,
           onEscape?() == true {
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }
}

final class MenuBarPanelPointerTrackingView: NSView {
    var onPointerLocationChanged: ((NSPoint) -> Void)?
    var onPointerPresenceChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeAlways,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        self.tracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerPresenceChanged?(true)
        report(event)
    }

    override func mouseMoved(with event: NSEvent) {
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerPresenceChanged?(false)
        report(event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func report(_ event: NSEvent) {
        guard let window else { return }
        onPointerLocationChanged?(window.convertPoint(toScreen: event.locationInWindow))
    }
}
