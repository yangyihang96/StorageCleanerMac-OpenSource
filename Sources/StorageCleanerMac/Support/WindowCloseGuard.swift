import AppKit
import SwiftUI

/// Adds a close veto without discarding SwiftUI's existing window delegate.
/// The view owns the draft and the confirmation UI; this bridge never saves it.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: @MainActor (NSWindow) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.shouldClose = shouldClose
        return PassthroughWindowConfigurationView { coordinator.attach(to: $0) }
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        if let window = view.window { context.coordinator.attach(to: window) }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        weak var previous: (any NSWindowDelegate)?
        var shouldClose: (@MainActor (NSWindow) -> Bool)?
        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            detach()
            self.window = window
            previous = window.delegate
            window.delegate = self
        }
        func detach() {
            if let window, window.delegate === self { window.delegate = previous }
            window = nil
            previous = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose?(sender) != false else { return false }
            return previous?.windowShouldClose?(sender) ?? true
        }
        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { previous?.responds(to: selector) == true }
        }
        // A synchronous ObjC forwarding result, only transported on the already
        // verified main thread; no task or actor hop retains this object.
        private struct ForwardTarget: @unchecked Sendable { let object: Any? }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            guard Thread.isMainThread else { return super.forwardingTarget(for: selector) }
            let target = MainActor.assumeIsolated {
                ForwardTarget(object: previous?.responds(to: selector) == true ? previous : nil)
            }
            return target.object ?? super.forwardingTarget(for: selector)
        }
    }
}
