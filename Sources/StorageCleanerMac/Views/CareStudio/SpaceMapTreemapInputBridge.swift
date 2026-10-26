import AppKit
import SwiftUI

@MainActor
struct SpaceMapTreemapInputBridge: NSViewRepresentable {
    enum Key: Equatable, Sendable {
        case activate, toggle, escape, back, forward, focusFilter, depth(Int)
        case direction(SpaceMapTreemapViewState.Direction)
    }

    enum Input: Sendable {
        case pointer(CGPoint?)
        case click(CGPoint, count: Int)
        case zoom(factor: CGFloat, point: CGPoint, phase: SpaceMapTreemapViewState.Phase, momentum: Bool, time: TimeInterval)
        case pan(CGSize)
        case key(Key)
    }

    enum MenuAction: Int { case quickLook, reveal, copy, toggle }
    struct MenuItem {
        let title: String
        let action: MenuAction
        var enabled = true
    }

    let tiles: [SpaceMapTreemapLayout.Tile]
    let viewport: SpaceMapTreemapViewState.Viewport
    let path: String
    let layoutSize: CGSize
    let highlightedID: String?
    let onInput: (Input) -> Void
    let menu: (CGPoint) -> [MenuItem]
    let onMenuAction: (MenuAction, CGPoint) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }

    func updateNSView(_ view: InputView, context: Context) {
        view.tiles = tiles
        view.viewport = viewport
        view.path = path
        view.layoutSize = layoutSize
        view.highlightedID = highlightedID
        view.onInput = onInput
        view.menuItems = menu
        view.onMenuAction = onMenuAction
    }

    final class InputView: NSView {
        var tiles: [SpaceMapTreemapLayout.Tile] = []
        var viewport = SpaceMapTreemapViewState.Viewport()
        var path = ""
        var layoutSize = CGSize.zero
        var highlightedID: String?
        var onInput: (Input) -> Void = { _ in }
        var menuItems: (CGPoint) -> [MenuItem] = { _ in [] }
        var onMenuAction: (MenuAction, CGPoint) -> Void = { _, _ in }
        private var tracking: NSTrackingArea?
        private var menuPoint = CGPoint.zero

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // The Canvas is the single accessibility element; the bridge and its
        // individual rectangles must not duplicate the equivalent list.
        override func isAccessibilityElement() -> Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        func send(_ input: Input) { onInput(input) }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
        override func mouseMoved(with event: NSEvent) { send(.pointer(point(event))) }
        override func mouseEntered(with event: NSEvent) { send(.pointer(point(event))) }
        override func mouseExited(with event: NSEvent) { send(.pointer(nil)) }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            send(.click(point(event), count: event.clickCount))
        }

        override func otherMouseDown(with event: NSEvent) {
            switch event.buttonNumber {
            case 3: send(.key(.back))
            case 4: send(.key(.forward))
            default: super.otherMouseDown(with: event)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            let precise = event.hasPreciseScrollingDeltas
            let inverted = event.isDirectionInvertedFromDevice
            let lines = SpaceMapTreemapViewState.scrollLines(
                deltaY: precise ? event.scrollingDeltaY : event.deltaY, precise: precise, inverted: inverted)
            if event.modifierFlags.contains(.shift) {
                let horizontal = SpaceMapTreemapViewState.scrollLines(
                    deltaY: precise ? event.scrollingDeltaX : event.deltaX, precise: precise, inverted: inverted)
                send(.pan(CGSize(width: horizontal * 40, height: lines * 40)))
            } else {
                send(.zoom(factor: pow(1.15, lines), point: point(event), phase: Self.phase(event.phase),
                           momentum: !event.momentumPhase.isEmpty, time: event.timestamp))
            }
        }

        override func magnify(with event: NSEvent) {
            send(.zoom(factor: max(0.01, 1 + event.magnification), point: point(event), phase: Self.phase(event.phase),
                       momentum: !event.momentumPhase.isEmpty, time: event.timestamp))
        }

        private static func phase(_ phase: NSEvent.Phase) -> SpaceMapTreemapViewState.Phase {
            if phase.contains(.began) { return .began }
            if phase.contains(.cancelled) { return .cancelled }
            if phase.contains(.ended) { return .ended }
            return phase.isEmpty ? .none : .changed
        }

        override func keyDown(with event: NSEvent) {
            if let key = Self.key(event) { send(.key(key)) }
            else { super.keyDown(with: event) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, event.modifierFlags.contains(.command), let key = Self.key(event) {
                send(.key(key))
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        private static func key(_ event: NSEvent) -> Key? {
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            let characters = event.charactersIgnoringModifiers ?? ""
            if flags.contains(.command) {
                guard flags == .command else { return nil }
                if characters == "[" { return .back }
                if characters == "]" { return .forward }
                return nil
            }
            guard flags.isEmpty else { return nil }
            switch event.keyCode {
            case 36, 76: return .activate
            case 49: return .toggle
            case 53, 51, 117: return .escape
            case 123: return .direction(.left)
            case 124: return .direction(.right)
            case 125: return .direction(.down)
            case 126: return .direction(.up)
            default:
                if characters == "[" { return .depth(-1) }
                if characters == "]" { return .depth(1) }
                if characters == "/" { return .focusFilter }
                return nil
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            window?.makeFirstResponder(self)
            menuPoint = point(event)
            let items = menuItems(menuPoint)
            guard !items.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                let native = NSMenuItem(title: item.title, action: #selector(performMenu(_:)), keyEquivalent: "")
                native.target = self
                native.tag = item.action.rawValue
                native.isEnabled = item.enabled
                menu.addItem(native)
            }
            return menu
        }

        @objc private func performMenu(_ sender: NSMenuItem) {
            if let action = MenuAction(rawValue: sender.tag) { onMenuAction(action, menuPoint) }
        }
    }
}
