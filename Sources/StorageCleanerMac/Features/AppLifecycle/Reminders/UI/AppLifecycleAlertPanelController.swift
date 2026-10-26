import AppKit
import Combine
import SwiftUI

/// The window a reminder appears in: a borderless, non-activating panel
/// hanging under this app's menu-bar item, as CleanMyMac's `AlertsWindow`
/// hangs under its Menu icon. It slides down while fading in, and fades out
/// while lifting away (`FadeOutAnimation`).
@MainActor
final class AppLifecycleAlertPanelController {
    private unowned let center: AppLifecycleReminderCenter
    private var panel: AlertPanel?
    private var hostingView: CardHostingView?
    private var cancellables: Set<AnyCancellable> = []
    private var isShown = false
    private var fitScheduled = false

    static let width: CGFloat = 368
    static let topGap: CGFloat = 6
    static let slideDistance: CGFloat = 10

    init(center: AppLifecycleReminderCenter) {
        self.center = center
    }

    func show(animated: Bool) {
        let panel = makePanelIfNeeded()
        fitSize(animated: false)
        let target = targetFrame(for: panel.frame.size)
        guard !isShown else {
            panel.setFrame(target, display: true, animate: false)
            return
        }
        isShown = true
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
            return
        }
        var start = target
        start.origin.y += Self.slideDistance
        panel.alphaValue = 0
        panel.setFrame(start, display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide(animated: Bool) {
        guard isShown, let panel else { return }
        isShown = false
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            return
        }
        var end = panel.frame
        end.origin.y += Self.slideDistance * 0.6
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: true)
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, !self.isShown else { return }
                panel?.orderOut(nil)
            }
        })
    }

    private func makePanelIfNeeded() -> AlertPanel {
        if let panel { return panel }
        let card = AppLifecycleAlertCard(center: center)
        let hosting = CardHostingView(rootView: card)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onSizeInvalidated = { [weak self] in self?.scheduleFit() }
        let panel = AlertPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = hosting
        self.panel = panel
        hostingView = hosting
        // Content changes (another app trashed, the Empty Trash steps) resize
        // the card in place.
        center.$presentedAlert.combineLatest(center.$emptyTrashPhase)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.scheduleFit() }
            .store(in: &cancellables)
        // The menu-bar panel opening, or this app becoming active, sends the
        // card away for later (CleanMyMac's `menuAppOpen` / `mainAppOpen`).
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, self.isShown,
                      notification.object as? NSWindow !== self.panel else { return }
                self.center.environmentChanged()
            }
            .store(in: &cancellables)
        return panel
    }

    /// Resizes after the pass that changed the card. SwiftUI resizes the card
    /// inside AppKit's layout; forcing `layoutSubtreeIfNeeded` from there is
    /// what AppKit logged as "already being laid out" (2.0.1 beta, D154).
    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            self.fitSize(animated: true)
        }
    }

    private func fitSize(animated: Bool) {
        guard let panel, let hostingView else { return }
        // The card has a fixed width, so its intrinsic height is the height
        // it wants; reading it does not start a layout pass.
        let intrinsic = hostingView.intrinsicContentSize.height
        let height = intrinsic > 0 ? intrinsic : hostingView.fittingSize.height
        let size = NSSize(width: Self.width, height: max(120, height))
        guard abs(panel.frame.height - size.height) > 0.5 else { return }
        let frame = targetFrame(for: size)
        if animated && isShown && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Under this app's status item, kept on its screen; the top-right corner
    /// of the main screen when the item is hidden.
    private func targetFrame(for size: NSSize) -> NSRect {
        let statusWindow = NSApp.windows.first { window in
            window.className.contains("NSStatusBarWindow") && window.isVisible
        }
        let screen = statusWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchorMidX = statusWindow.map { $0.frame.midX } ?? (visible.maxX - size.width / 2 - 12)
        var x = anchorMidX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - Self.topGap - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// A borderless panel that still takes clicks on its buttons and
    /// checkboxes without making this app active.
    private final class AlertPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// Tells the controller when the card asks for a new size.
    private final class CardHostingView: NSHostingView<AppLifecycleAlertCard> {
        var onSizeInvalidated: (@MainActor () -> Void)?

        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            onSizeInvalidated?()
        }
    }
}
