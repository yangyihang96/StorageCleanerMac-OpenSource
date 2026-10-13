import AppKit
import SwiftUI

struct GeneratedArtLoadRequest: Hashable {
    let name: String?
    let visible: Bool
}

private struct GeneratedArtWindowVisibleKey: EnvironmentKey {
    static let defaultValue = true // Standalone previews have an explicit lifecycle.
}

extension EnvironmentValues {
    var generatedArtWindowVisible: Bool {
        get { self[GeneratedArtWindowVisibleKey.self] }
        set { self[GeneratedArtWindowVisibleKey.self] = newValue }
    }
}

/// The actual attached main window, rather than SwiftUI's constructed view tree.
struct GeneratedArtWindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = { visible = $0 }
        return view
    }
    func updateNSView(_ view: VisibilityView, context: Context) {
        view.changed = { visible = $0 }
        view.publishVisibility()
    }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.detach()
    }

    @MainActor
    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?
        private var lastVisible: Bool?
        deinit { NotificationCenter.default.removeObserver(self) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { publishVisibility(); return }
            observation = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.publishVisibility() }
            }
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: nil)
            }
            publishVisibility()
        }
        func detach() {
            observation = nil
            NotificationCenter.default.removeObserver(self)
        }
        @objc private func windowChanged(_ notification: Notification) { publishVisibility() }
        func publishVisibility() {
            let value = window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true
                && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
            guard lastVisible != value else { return }
            lastVisible = value
            Task { @MainActor [weak self] in self?.changed?(value) }
        }
    }
}
