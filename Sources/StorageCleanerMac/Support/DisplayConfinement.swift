import AppKit
import MachO
import ObjectiveC
import Photos
import ServiceManagement
import UserNotifications

/// D106: one display as the confinement policy sees it, in AppKit's global
/// coordinates (origin at the bottom left of the menu-bar display).
struct DisplayConfinementScreen: Equatable, Sendable {
    let displayID: UInt32
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    /// The display that carries the menu bar and the coordinate origin.
    let isMain: Bool

    @MainActor
    static func current() -> [DisplayConfinementScreen] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else { return nil }
            return DisplayConfinementScreen(
                displayID: number.uint32Value,
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isMain: number.uint32Value == mainID
            )
        }
    }
}

enum DisplayConfinementTargetError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyName
    case missing(name: String)
    case ambiguous(name: String, count: Int)
    /// The menu-bar display is never a confinement target: keeping windows
    /// off it is the point of confining them.
    case mainDisplay(name: String)

    var description: String {
        switch self {
        case .emptyName: "no display name was given"
        case .missing(let name): "no display is named \"\(name)\""
        case .ambiguous(let name, let count): "\(count) displays are named \"\(name)\""
        case .mainDisplay(let name): "\"\(name)\" is the menu-bar display"
        }
    }
}

enum DisplayConfinementPlacement: Equatable, Sendable {
    case unchanged(CGRect)
    case moved(CGRect)
    case refused(String)
}

/// The pure part of D106: which display is the target, whether a frame lies
/// on it, and where a window that does not goes before it is shown.
enum DisplayConfinementPolicy {
    /// Window frames can carry fractional points.
    static let tolerance: CGFloat = 0.5

    static func resolveTarget(
        named name: String,
        in screens: [DisplayConfinementScreen]
    ) -> Result<DisplayConfinementScreen, DisplayConfinementTargetError> {
        guard !name.isEmpty else { return .failure(.emptyName) }
        let matches = screens.filter { $0.name == name }
        guard let target = matches.first else { return .failure(.missing(name: name)) }
        guard matches.count == 1 else { return .failure(.ambiguous(name: name, count: matches.count)) }
        guard !target.isMain else { return .failure(.mainDisplay(name: name)) }
        return .success(target)
    }

    /// A window with no area counts by its origin.
    static func contains(_ frame: CGRect, in screen: DisplayConfinementScreen) -> Bool {
        guard isFinite(frame) else { return false }
        let bounds = screen.frame.insetBy(dx: -tolerance, dy: -tolerance)
        let frame = frame.standardized
        if frame.width <= 0 || frame.height <= 0 {
            return bounds.contains(frame.origin)
        }
        return bounds.contains(frame)
    }

    /// Keeps a frame already on the target. A frame partly on it moves the
    /// shortest way into its visible area; any other frame is centred there.
    /// A frame larger than that area shrinks to it unless the window's
    /// minimum size forbids that, in which case it is refused.
    static func place(
        _ frame: CGRect,
        minimumSize: CGSize,
        in target: DisplayConfinementScreen
    ) -> DisplayConfinementPlacement {
        guard isFinite(frame) else { return .refused("the window frame is not finite") }
        if contains(frame, in: target) { return .unchanged(frame) }
        let frame = frame.standardized
        let area = target.visibleFrame.isEmpty ? target.frame : target.visibleFrame
        var size = CGSize(width: max(frame.width, 0), height: max(frame.height, 0))
        if size.width > area.width || size.height > area.height {
            guard minimumSize.width <= area.width, minimumSize.height <= area.height else {
                return .refused("the window's minimum size does not fit the target display")
            }
            size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        }
        let origin: CGPoint
        if frame.width > 0, frame.height > 0, frame.intersects(target.frame) {
            origin = CGPoint(x: min(max(frame.minX, area.minX), area.maxX - size.width),
                             y: min(max(frame.minY, area.minY), area.maxY - size.height))
        } else {
            origin = CGPoint(x: (area.midX - size.width / 2).rounded(.down),
                             y: (area.midY - size.height / 2).rounded(.down))
        }
        let placed = CGRect(origin: origin, size: size)
        guard contains(placed, in: target) else {
            return .refused("the window could not be placed on the target display")
        }
        return .moved(placed)
    }

    private static func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
    }
}

/// D106: keeps every window of this process on one named display, decided
/// before the window reaches the screen, and refuses the UI another process
/// would show (opening a URL or an app, a Finder reveal, System Settings,
/// a notification or a permission prompt), because nothing here can place it.
/// Installed only by the Beta acceptance launch (`AcceptanceLaunch`) and the
/// test bundle; a normal launch never installs it.
///
/// Each public NSWindow ordering entry point is intercepted: the frame is
/// moved onto the target while the window is still hidden, and a window is
/// refused (left hidden) when the display is missing or the window cannot
/// fit. Frame changes of visible windows are kept on the display. Windows
/// that appear or move through any other path are checked again from
/// AppKit's window notifications and hidden at once: that check comes after
/// the fact and is reported as a violation, never as a pass.
final class DisplayConfinementGate: @unchecked Sendable {
    enum Mode: Equatable, Sendable {
        case inactive
        /// Windows may appear only on the display with this exact name.
        case confine(displayName: String)
        /// No window may appear at all.
        case denyAll(reason: String)
    }

    struct Event: Equatable, Sendable {
        enum Kind: String, Sendable {
            case installed, placed, moved, refused, violation, externalRefused
        }

        let kind: Kind
        let entry: String
        let window: String
        let before: CGRect?
        let after: CGRect?
        let detail: String
    }

    struct RefusalError: LocalizedError {
        let entry: String
        var errorDescription: String? {
            "\(entry) was refused: this session shows windows on one display only (D106)."
        }
    }

    static let shared = DisplayConfinementGate()

    private let lock = NSLock()
    private var mode: Mode = .inactive
    private var sink: (@Sendable (Event) -> Void)?
    private var onViolation: (@Sendable (Event) -> Void)?
    private var screens: @MainActor @Sendable () -> [DisplayConfinementScreen] = { DisplayConfinementScreen.current() }
    /// Tests only: called instead of the intercepted original, so a test can
    /// route a call through the gate without anything reaching the screen.
    private var originalCallOverride: (@Sendable (String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    var currentMode: Mode { locked { mode } }

    /// Replaces the ordering, frame and external-UI entry points once per
    /// process, then switches to `mode`. Safe to call before NSApplication
    /// exists and from the test bundle's load-time constructor.
    func activate(
        mode: Mode,
        sink: (@Sendable (Event) -> Void)? = nil,
        onViolation: (@Sendable (Event) -> Void)? = nil
    ) {
        _ = DisplayConfinementInterception.installed
        locked {
            self.mode = mode
            self.sink = sink
            self.onViolation = onViolation
            if observers.isEmpty { observers = installObservers() }
        }
    }

    /// The target display while confining, nil otherwise or when it is gone.
    @MainActor
    func targetScreen() -> NSScreen? {
        guard case .confine(let name) = currentMode,
              case .success(let target) = resolve(name) else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == target.displayID
        }
    }

    // MARK: Test seams

    func replaceScreensProvider(_ provider: @escaping @MainActor @Sendable () -> [DisplayConfinementScreen]) {
        locked { screens = provider }
    }

    func setOriginalCallOverride(_ override: (@Sendable (String) -> Void)?) {
        locked { originalCallOverride = override }
    }

    /// Restores everything a test may have replaced.
    func restore(
        mode: Mode,
        sink: (@Sendable (Event) -> Void)?,
        onViolation: (@Sendable (Event) -> Void)?
    ) {
        locked {
            self.mode = mode
            self.sink = sink
            self.onViolation = onViolation
            screens = { DisplayConfinementScreen.current() }
            originalCallOverride = nil
        }
    }

    var eventSink: (@Sendable (Event) -> Void)? { locked { sink } }
    var violationHandler: (@Sendable (Event) -> Void)? { locked { onViolation } }

    /// The replacement each intercepted selector got, for verification.
    static var interceptedImplementations: [String: IMP] {
        DisplayConfinementInterception.installed.mapValues(\.implementation)
    }

    /// Loaded window classes whose own implementation of an intercepted
    /// window selector is not wrapped, as "Class.selector": a class loaded
    /// after activation. Empty means every loaded window class orders and
    /// moves through the gate.
    static func uncoveredWindowOverrides() -> [String] {
        DisplayConfinementInterception.uncoveredWindowOverrides()
    }

    // MARK: Decisions (called from the intercepted entry points)

    /// Before a window is ordered onto the screen. False keeps it hidden.
    func allowsOrderingIn(_ window: NSWindow, entry: String) -> Bool {
        guard Thread.isMainThread else {
            report(.refused, entry: entry, window: "off-main-thread", detail: "window ordering off the main thread")
            return false
        }
        return MainActor.assumeIsolated { decideOrderingIn(window, entry: entry) }
    }

    /// Runs `original` for a window entry point once the window may appear,
    /// then checks where it went. A nested primitive of the same ordering
    /// (orderFront: calls orderWindow:relativeTo:) is checked again and
    /// finds the frame already placed; keeping no per-call state means an
    /// exception inside AppKit cannot leave a window unchecked later.
    func performOrdering(_ window: NSWindow, entry: String, original: () -> Void) {
        guard allowsOrderingIn(window, entry: entry) else { return }
        invokeOriginal(entry, original)
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { checkVisible(window, entry: entry) }
    }

    /// Before a sheet is attached to `parent`. A sheet appears on its parent,
    /// so the parent must already be shown on the target. False keeps it out.
    func allowsSheet(_ sheet: NSWindow, on parent: NSWindow, entry: String) -> Bool {
        guard Thread.isMainThread else {
            report(.refused, entry: entry, window: "off-main-thread", detail: "sheet off the main thread")
            return false
        }
        return MainActor.assumeIsolated { decideSheet(sheet, on: parent, entry: entry) }
    }

    /// The frame a frame change may apply, nil to keep the current frame.
    func confinedFrame(for window: NSWindow, requested: CGRect, entry: String) -> CGRect? {
        guard Thread.isMainThread else { return requested }
        return MainActor.assumeIsolated { decideFrame(for: window, requested: requested, entry: entry) }
    }

    /// As `confinedFrame`, for a new bottom-left origin at the current size.
    func confinedOrigin(for window: NSWindow, requested origin: CGPoint, entry: String) -> CGPoint? {
        guard Thread.isMainThread else { return origin }
        return MainActor.assumeIsolated {
            let requested = CGRect(origin: origin, size: window.frame.size)
            return decideFrame(for: window, requested: requested, entry: entry)?.origin
        }
    }

    /// As `confinedFrame`, for a new top-left point at the current size.
    func confinedTopLeft(for window: NSWindow, requested point: CGPoint, entry: String) -> CGPoint? {
        guard Thread.isMainThread else { return point }
        return MainActor.assumeIsolated {
            let size = window.frame.size
            let requested = CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
            return decideFrame(for: window, requested: requested, entry: entry).map { CGPoint(x: $0.minX, y: $0.maxY) }
        }
    }

    /// Before UI that another process shows. False refuses it.
    func permitsExternal(_ entry: String, detail: String = "") -> Bool {
        guard currentMode != .inactive else { return true }
        report(.externalRefused, entry: entry, window: "-", detail: detail)
        return false
    }

    func invokeOriginal(_ entry: String, _ original: () -> Void) {
        if let override = locked({ originalCallOverride }) {
            override(entry)
        } else {
            original()
        }
    }

    // MARK: Private

    @MainActor
    private func decideOrderingIn(_ window: NSWindow, entry: String) -> Bool {
        let before = window.frame
        switch currentMode {
        case .inactive:
            return true
        case .denyAll(let reason):
            report(.refused, entry: entry, window: describe(window), before: before, detail: reason)
            return false
        case .confine(let name):
            let target: DisplayConfinementScreen
            switch resolve(name) {
            case .success(let resolved): target = resolved
            case .failure(let error):
                report(.refused, entry: entry, window: describe(window), before: before, detail: error.description)
                return false
            }
            switch DisplayConfinementPolicy.place(before, minimumSize: window.minSize, in: target) {
            case .unchanged:
                report(.placed, entry: entry, window: describe(window), before: before, after: before)
                return true
            case .moved(let placed):
                window.setFrame(placed, display: false)
                let after = window.frame
                guard DisplayConfinementPolicy.contains(after, in: target) else {
                    report(.refused, entry: entry, window: describe(window), before: before, after: after,
                           detail: "AppKit kept the frame off the target display")
                    return false
                }
                report(.moved, entry: entry, window: describe(window), before: before, after: after)
                return true
            case .refused(let reason):
                report(.refused, entry: entry, window: describe(window), before: before, detail: reason)
                return false
            }
        }
    }

    @MainActor
    private func decideSheet(_ sheet: NSWindow, on parent: NSWindow, entry: String) -> Bool {
        switch currentMode {
        case .inactive:
            return true
        case .denyAll(let reason):
            report(.refused, entry: entry, window: describe(sheet), detail: reason)
            return false
        case .confine(let name):
            switch resolve(name) {
            case .failure(let error):
                report(.refused, entry: entry, window: describe(sheet), detail: error.description)
                return false
            case .success(let target):
                let host = parent.frame
                guard parent.isVisible, DisplayConfinementPolicy.contains(host, in: target) else {
                    report(.refused, entry: entry, window: describe(sheet), before: host,
                           detail: "its parent \(describe(parent)) is not shown on the target display")
                    return false
                }
                report(.placed, entry: entry, window: describe(sheet), before: host, after: host,
                       detail: "attached to \(describe(parent))")
                return true
            }
        }
    }

    @MainActor
    private func decideFrame(for window: NSWindow, requested: CGRect, entry: String) -> CGRect? {
        // A hidden window is placed when it is ordered in.
        guard window.isVisible, case .confine(let name) = currentMode else { return requested }
        switch resolve(name) {
        case .failure(let error):
            report(.refused, entry: entry, window: describe(window), before: window.frame, after: requested,
                   detail: error.description)
            return nil
        case .success(let target):
            switch DisplayConfinementPolicy.place(requested, minimumSize: window.minSize, in: target) {
            case .unchanged: return requested
            case .moved(let placed):
                report(.moved, entry: entry, window: describe(window), before: requested, after: placed)
                return placed
            case .refused(let reason):
                report(.refused, entry: entry, window: describe(window), before: window.frame, after: requested,
                       detail: reason)
                return nil
            }
        }
    }

    /// The after-the-fact tripwire: a visible window off the target is hidden.
    @MainActor
    private func checkVisible(_ window: NSWindow, entry: String) {
        guard window.isVisible else { return }
        let frame = window.frame
        switch currentMode {
        case .inactive:
            return
        case .denyAll(let reason):
            violation(window, entry: entry, frame: frame, detail: "a window became visible: \(reason)")
        case .confine(let name):
            switch resolve(name) {
            case .failure(let error):
                violation(window, entry: entry, frame: frame, detail: error.description)
            case .success(let target):
                if !DisplayConfinementPolicy.contains(frame, in: target) {
                    violation(window, entry: entry, frame: frame, detail: "a visible window left the target display")
                }
            }
        }
    }

    @MainActor
    private func violation(_ window: NSWindow, entry: String, frame: CGRect, detail: String) {
        window.orderOut(nil)
        report(.violation, entry: entry, window: describe(window), before: frame, detail: detail)
    }

    @MainActor
    private func resolve(_ name: String) -> Result<DisplayConfinementScreen, DisplayConfinementTargetError> {
        let provider = locked { screens }
        return DisplayConfinementPolicy.resolveTarget(named: name, in: provider())
    }

    private func installObservers() -> [NSObjectProtocol] {
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeKeyNotification
        ]
        return names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self, Thread.isMainThread, let window = note.object as? NSWindow else { return }
                let entry = "tripwire:" + name.rawValue
                MainActor.assumeIsolated { self.checkVisible(window, entry: entry) }
            }
        }
    }

    @MainActor
    private func describe(_ window: NSWindow) -> String {
        var text = "\(type(of: window))#\(window.windowNumber)"
        if let identifier = window.identifier?.rawValue, !identifier.isEmpty { text += "(\(identifier))" }
        return text
    }

    private func report(
        _ kind: Event.Kind,
        entry: String,
        window: String,
        before: CGRect? = nil,
        after: CGRect? = nil,
        detail: String = ""
    ) {
        let event = Event(kind: kind, entry: entry, window: window, before: before, after: after, detail: detail)
        let (sink, onViolation) = locked { (self.sink, self.onViolation) }
        sink?(event)
        if [.refused, .violation, .externalRefused].contains(kind) { onViolation?(event) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The intercepted entry points. Every selector is public AppKit, Photos,
/// ServiceManagement or UserNotifications API; replacements are installed
/// once per process and only when the gate is activated.
private enum DisplayConfinementInterception {
    struct Replacement: @unchecked Sendable {
        let implementation: IMP
    }

    /// One intercepted NSWindow selector and how to wrap an implementation
    /// of it, so a window class's own implementation gets the same wrapper.
    struct WindowEntry: @unchecked Sendable {
        let selector: Selector
        let name: String
        let wrap: (IMP) -> Any
    }

    static let windowEntries: [WindowEntry] = makeWindowEntries()
    static let installed: [String: Replacement] = install()

    private typealias WindowSender = @convention(c) (NSWindow, Selector, AnyObject?) -> Void
    private typealias WindowPlain = @convention(c) (NSWindow, Selector) -> Void
    private typealias WindowOrder = @convention(c) (NSWindow, Selector, Int, Int) -> Void
    private typealias WindowFlag = @convention(c) (NSWindow, Selector, ObjCBool) -> Void
    private typealias WindowFrame = @convention(c) (NSWindow, Selector, NSRect, ObjCBool) -> Void
    private typealias WindowFrameAnimate = @convention(c) (NSWindow, Selector, NSRect, ObjCBool, ObjCBool) -> Void
    private typealias WindowPoint = @convention(c) (NSWindow, Selector, NSPoint) -> Void
    private typealias SheetCompletion = @convention(block) (Int) -> Void
    private typealias WindowSheet = @convention(c) (NSWindow, Selector, NSWindow, SheetCompletion?) -> Void
    private typealias ModalRun = @convention(c) (NSApplication, Selector, NSWindow) -> Int
    private typealias ModalBegin = @convention(c) (NSApplication, Selector, NSWindow) -> OpaquePointer?
    private typealias OpenCompletion = @convention(block) (NSRunningApplication?, NSError?) -> Void
    private typealias OpenURL = @convention(c) (NSWorkspace, Selector, NSURL) -> ObjCBool
    private typealias OpenURLConfiguration = @convention(c) (
        NSWorkspace, Selector, NSURL, NSWorkspace.OpenConfiguration, OpenCompletion?
    ) -> Void
    private typealias OpenURLsWithApplication = @convention(c) (
        NSWorkspace, Selector, NSArray, NSURL, NSWorkspace.OpenConfiguration, OpenCompletion?
    ) -> Void
    private typealias OpenApplication = @convention(c) (
        NSWorkspace, Selector, NSURL, NSWorkspace.OpenConfiguration, OpenCompletion?
    ) -> Void
    private typealias ActivateFileViewer = @convention(c) (NSWorkspace, Selector, NSArray) -> Void
    private typealias SelectFile = @convention(c) (NSWorkspace, Selector, NSString?, NSString) -> ObjCBool
    private typealias ClassPlain = @convention(c) (AnyObject, Selector) -> Void
    private typealias NotificationAuthorizationCompletion = @convention(block) (ObjCBool, NSError?) -> Void
    private typealias NotificationAuthorization = @convention(c) (
        UNUserNotificationCenter, Selector, UNAuthorizationOptions, NotificationAuthorizationCompletion?
    ) -> Void
    private typealias NotificationAddCompletion = @convention(block) (NSError?) -> Void
    private typealias NotificationAdd = @convention(c) (
        UNUserNotificationCenter, Selector, UNNotificationRequest, NotificationAddCompletion?
    ) -> Void
    private typealias PhotosHandler = @convention(block) (PHAuthorizationStatus) -> Void
    private typealias PhotosAuthorization = @convention(c) (AnyObject, Selector, PHAccessLevel, PhotosHandler?) -> Void

    private static var gate: DisplayConfinementGate { .shared }

    private static func refusal(_ entry: String) -> NSError {
        DisplayConfinementGate.RefusalError(entry: entry) as NSError
    }

    static func uncoveredWindowOverrides() -> [String] {
        let wrapped = Set(installed.values.map(\.implementation))
        var uncovered: [String] = []
        for cls in loadedWindowSubclasses() {
            for entry in windowEntries {
                guard let method = ownInstanceMethod(cls, entry.selector),
                      !wrapped.contains(method_getImplementation(method)) else { continue }
                uncovered.append(NSStringFromClass(cls) + "." + entry.name)
            }
        }
        return uncovered.sorted()
    }

    // swiftlint:disable:next function_body_length
    private static func makeWindowEntries() -> [WindowEntry] {
        var entries: [WindowEntry] = []

        for (selector, name) in [
            (#selector(NSWindow.orderFront(_:)), "orderFront:"),
            (#selector(NSWindow.makeKeyAndOrderFront(_:)), "makeKeyAndOrderFront:"),
            (#selector(NSWindow.orderBack(_:)), "orderBack:")
        ] {
            entries.append(WindowEntry(selector: selector, name: name) { original in
                let call = unsafeBitCast(original, to: WindowSender.self)
                let block: @convention(block) (NSWindow, AnyObject?) -> Void = { window, sender in
                    gate.performOrdering(window, entry: name) { call(window, selector, sender) }
                }
                return block
            })
        }

        let regardless = #selector(NSWindow.orderFrontRegardless)
        entries.append(WindowEntry(selector: regardless, name: "orderFrontRegardless") { original in
            let call = unsafeBitCast(original, to: WindowPlain.self)
            let block: @convention(block) (NSWindow) -> Void = { window in
                gate.performOrdering(window, entry: "orderFrontRegardless") { call(window, regardless) }
            }
            return block
        })

        let order = #selector(NSWindow.order(_:relativeTo:))
        entries.append(WindowEntry(selector: order, name: "orderWindow:relativeTo:") { original in
            let call = unsafeBitCast(original, to: WindowOrder.self)
            let block: @convention(block) (NSWindow, Int, Int) -> Void = { window, place, other in
                // Ordering out is always allowed.
                guard place != NSWindow.OrderingMode.out.rawValue else {
                    call(window, order, place, other)
                    return
                }
                gate.performOrdering(window, entry: "orderWindow:relativeTo:") { call(window, order, place, other) }
            }
            return block
        })

        let visible = #selector(NSWindow.setIsVisible(_:))
        entries.append(WindowEntry(selector: visible, name: "setIsVisible:") { original in
            let call = unsafeBitCast(original, to: WindowFlag.self)
            let block: @convention(block) (NSWindow, ObjCBool) -> Void = { window, flag in
                guard flag.boolValue else {
                    call(window, visible, flag)
                    return
                }
                gate.performOrdering(window, entry: "setIsVisible:") { call(window, visible, flag) }
            }
            return block
        })

        let frame = #selector(NSWindow.setFrame(_:display:))
        entries.append(WindowEntry(selector: frame, name: "setFrame:display:") { original in
            let call = unsafeBitCast(original, to: WindowFrame.self)
            let block: @convention(block) (NSWindow, NSRect, ObjCBool) -> Void = { window, rect, display in
                guard let rect = gate.confinedFrame(for: window, requested: rect, entry: "setFrame:display:") else { return }
                call(window, frame, rect, display)
            }
            return block
        })

        let animated = #selector(NSWindow.setFrame(_:display:animate:))
        entries.append(WindowEntry(selector: animated, name: "setFrame:display:animate:") { original in
            let call = unsafeBitCast(original, to: WindowFrameAnimate.self)
            let block: @convention(block) (NSWindow, NSRect, ObjCBool, ObjCBool) -> Void = { window, rect, display, animate in
                guard let rect = gate.confinedFrame(for: window, requested: rect, entry: "setFrame:display:animate:")
                else { return }
                call(window, animated, rect, display, animate)
            }
            return block
        })

        let origin = #selector(NSWindow.setFrameOrigin(_:))
        entries.append(WindowEntry(selector: origin, name: "setFrameOrigin:") { original in
            let call = unsafeBitCast(original, to: WindowPoint.self)
            let block: @convention(block) (NSWindow, NSPoint) -> Void = { window, point in
                guard let point = gate.confinedOrigin(for: window, requested: point, entry: "setFrameOrigin:")
                else { return }
                call(window, origin, point)
            }
            return block
        })

        let topLeft = #selector(NSWindow.setFrameTopLeftPoint(_:))
        entries.append(WindowEntry(selector: topLeft, name: "setFrameTopLeftPoint:") { original in
            let call = unsafeBitCast(original, to: WindowPoint.self)
            let block: @convention(block) (NSWindow, NSPoint) -> Void = { window, point in
                guard let point = gate.confinedTopLeft(for: window, requested: point, entry: "setFrameTopLeftPoint:")
                else { return }
                call(window, topLeft, point)
            }
            return block
        })

        for (selector, name) in [
            (#selector(NSWindow.beginSheet(_:completionHandler:)), "beginSheet:completionHandler:"),
            (#selector(NSWindow.beginCriticalSheet(_:completionHandler:)), "beginCriticalSheet:completionHandler:")
        ] {
            entries.append(WindowEntry(selector: selector, name: name) { original in
                let call = unsafeBitCast(original, to: WindowSheet.self)
                let block: @convention(block) (NSWindow, NSWindow, SheetCompletion?) -> Void = { parent, sheet, completion in
                    guard gate.allowsSheet(sheet, on: parent, entry: name) else {
                        // A refused sheet ends as aborted, never as confirmed,
                        // and later, as a shown sheet's handler would.
                        nonisolated(unsafe) let completion = completion
                        DispatchQueue.main.async { completion?(NSApplication.ModalResponse.abort.rawValue) }
                        return
                    }
                    gate.invokeOriginal(name) { call(parent, selector, sheet, completion) }
                }
                return block
            })
        }

        return entries
    }

    // swiftlint:disable:next function_body_length
    private static func install() -> [String: Replacement] {
        var installed: [String: Replacement] = [:]
        func record(_ key: String, _ implementation: IMP?) {
            if let implementation { installed[key] = Replacement(implementation: implementation) }
        }

        for entry in windowEntries {
            record("NSWindow." + entry.name, replaceInstanceMethod(NSWindow.self, entry.selector, entry.wrap))
        }
        // A window class that implements one of these itself, instead of
        // inheriting NSWindow's, gets the same wrapper around its own. A
        // subclass that calls super passes the gate twice; that is harmless.
        for cls in loadedWindowSubclasses() {
            for entry in windowEntries {
                guard let method = ownInstanceMethod(cls, entry.selector) else { continue }
                let replacement = imp_implementationWithBlock(entry.wrap(method_getImplementation(method)))
                method_setImplementation(method, replacement)
                record(NSStringFromClass(cls) + "." + entry.name, replacement)
            }
        }

        let runModal = #selector(NSApplication.runModal(for:))
        record("NSApplication.runModalForWindow:", replaceInstanceMethod(NSApplication.self, runModal) { original in
            let call = unsafeBitCast(original, to: ModalRun.self)
            let block: @convention(block) (NSApplication, NSWindow) -> Int = { application, window in
                // A refused alert answers as aborted, never as confirmed.
                guard gate.allowsOrderingIn(window, entry: "runModalForWindow:") else {
                    return NSApplication.ModalResponse.abort.rawValue
                }
                var response = NSApplication.ModalResponse.abort.rawValue
                gate.invokeOriginal("runModalForWindow:") { response = call(application, runModal, window) }
                return response
            }
            return block
        })

        let beginModal = #selector(NSApplication.beginModalSession(for:))
        record("NSApplication.beginModalSessionForWindow:", replaceInstanceMethod(NSApplication.self, beginModal) { original in
            let call = unsafeBitCast(original, to: ModalBegin.self)
            let block: @convention(block) (NSApplication, NSWindow) -> OpaquePointer? = { application, window in
                // Places the window; the session's own ordering is checked
                // again. No session can be refused without one to return.
                _ = gate.allowsOrderingIn(window, entry: "beginModalSessionForWindow:")
                var session: OpaquePointer?
                gate.invokeOriginal("beginModalSessionForWindow:") { session = call(application, beginModal, window) }
                return session
            }
            return block
        })

        let openURL = #selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool)
        record("NSWorkspace.openURL:", replaceInstanceMethod(NSWorkspace.self, openURL) { original in
            let call = unsafeBitCast(original, to: OpenURL.self)
            let block: @convention(block) (NSWorkspace, NSURL) -> ObjCBool = { workspace, url in
                let entry = "NSWorkspace.openURL:"
                guard gate.permitsExternal(entry, detail: url.scheme ?? "") else { return false }
                var opened: ObjCBool = false
                gate.invokeOriginal(entry) { opened = call(workspace, openURL, url) }
                return opened
            }
            return block
        })

        let openConfigured = #selector(NSWorkspace.open(_:configuration:completionHandler:)
            as (NSWorkspace) -> (URL, NSWorkspace.OpenConfiguration,
                                 (@Sendable (NSRunningApplication?, (any Error)?) -> Void)?) -> Void)
        record("NSWorkspace.openURL:configuration:completionHandler:",
               replaceInstanceMethod(NSWorkspace.self, openConfigured) { original in
            let call = unsafeBitCast(original, to: OpenURLConfiguration.self)
            let block: @convention(block) (NSWorkspace, NSURL, NSWorkspace.OpenConfiguration, OpenCompletion?) -> Void = {
                workspace, url, configuration, completion in
                let entry = "NSWorkspace.openURL:configuration:completionHandler:"
                guard gate.permitsExternal(entry, detail: url.scheme ?? "") else {
                    completion?(nil, refusal(entry))
                    return
                }
                gate.invokeOriginal(entry) { call(workspace, openConfigured, url, configuration, completion) }
            }
            return block
        })

        let openWithApplication = #selector(NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)
            as (NSWorkspace) -> ([URL], URL, NSWorkspace.OpenConfiguration,
                                 (@Sendable (NSRunningApplication?, (any Error)?) -> Void)?) -> Void)
        record("NSWorkspace.openURLs:withApplicationAtURL:configuration:completionHandler:",
               replaceInstanceMethod(NSWorkspace.self, openWithApplication) { original in
            let call = unsafeBitCast(original, to: OpenURLsWithApplication.self)
            let block: @convention(block) (
                NSWorkspace, NSArray, NSURL, NSWorkspace.OpenConfiguration, OpenCompletion?
            ) -> Void = { workspace, urls, application, configuration, completion in
                let entry = "NSWorkspace.openURLs:withApplicationAtURL:configuration:completionHandler:"
                guard gate.permitsExternal(entry) else {
                    completion?(nil, refusal(entry))
                    return
                }
                gate.invokeOriginal(entry) {
                    call(workspace, openWithApplication, urls, application, configuration, completion)
                }
            }
            return block
        })

        let openApplication = #selector(NSWorkspace.openApplication(at:configuration:completionHandler:)
            as (NSWorkspace) -> (URL, NSWorkspace.OpenConfiguration,
                                 (@Sendable (NSRunningApplication?, (any Error)?) -> Void)?) -> Void)
        record("NSWorkspace.openApplicationAtURL:configuration:completionHandler:",
               replaceInstanceMethod(NSWorkspace.self, openApplication) { original in
            let call = unsafeBitCast(original, to: OpenApplication.self)
            let block: @convention(block) (NSWorkspace, NSURL, NSWorkspace.OpenConfiguration, OpenCompletion?) -> Void = {
                workspace, url, configuration, completion in
                let entry = "NSWorkspace.openApplicationAtURL:configuration:completionHandler:"
                guard gate.permitsExternal(entry) else {
                    completion?(nil, refusal(entry))
                    return
                }
                gate.invokeOriginal(entry) { call(workspace, openApplication, url, configuration, completion) }
            }
            return block
        })

        let activateViewer = #selector(NSWorkspace.activateFileViewerSelecting(_:))
        record("NSWorkspace.activateFileViewerSelectingURLs:",
               replaceInstanceMethod(NSWorkspace.self, activateViewer) { original in
            let call = unsafeBitCast(original, to: ActivateFileViewer.self)
            let block: @convention(block) (NSWorkspace, NSArray) -> Void = { workspace, urls in
                let entry = "NSWorkspace.activateFileViewerSelectingURLs:"
                guard gate.permitsExternal(entry) else { return }
                gate.invokeOriginal(entry) { call(workspace, activateViewer, urls) }
            }
            return block
        })

        let selectFile = #selector(NSWorkspace.selectFile(_:inFileViewerRootedAtPath:))
        record("NSWorkspace.selectFile:inFileViewerRootedAtPath:",
               replaceInstanceMethod(NSWorkspace.self, selectFile) { original in
            let call = unsafeBitCast(original, to: SelectFile.self)
            let block: @convention(block) (NSWorkspace, NSString?, NSString) -> ObjCBool = { workspace, path, root in
                let entry = "NSWorkspace.selectFile:inFileViewerRootedAtPath:"
                guard gate.permitsExternal(entry) else { return false }
                var selected: ObjCBool = false
                gate.invokeOriginal(entry) { selected = call(workspace, selectFile, path, root) }
                return selected
            }
            return block
        })

        let loginItems = #selector(SMAppService.openSystemSettingsLoginItems)
        record("SMAppService.openSystemSettingsLoginItems",
               replaceClassMethod(SMAppService.self, loginItems) { original in
            let call = unsafeBitCast(original, to: ClassPlain.self)
            let block: @convention(block) (AnyObject) -> Void = { serviceClass in
                let entry = "SMAppService.openSystemSettingsLoginItems"
                guard gate.permitsExternal(entry) else { return }
                gate.invokeOriginal(entry) { call(serviceClass, loginItems) }
            }
            return block
        })

        let notificationAuthorization = #selector(UNUserNotificationCenter.requestAuthorization(options:completionHandler:))
        record("UNUserNotificationCenter.requestAuthorizationWithOptions:completionHandler:",
               replaceInstanceMethod(UNUserNotificationCenter.self, notificationAuthorization) { original in
            let call = unsafeBitCast(original, to: NotificationAuthorization.self)
            let block: @convention(block) (
                UNUserNotificationCenter, UNAuthorizationOptions, NotificationAuthorizationCompletion?
            ) -> Void = { center, options, completion in
                let entry = "UNUserNotificationCenter.requestAuthorizationWithOptions:completionHandler:"
                guard gate.permitsExternal(entry) else {
                    completion?(false, refusal(entry))
                    return
                }
                gate.invokeOriginal(entry) { call(center, notificationAuthorization, options, completion) }
            }
            return block
        })

        let notificationAdd = #selector(UNUserNotificationCenter.add(_:withCompletionHandler:))
        record("UNUserNotificationCenter.addNotificationRequest:withCompletionHandler:",
               replaceInstanceMethod(UNUserNotificationCenter.self, notificationAdd) { original in
            let call = unsafeBitCast(original, to: NotificationAdd.self)
            let block: @convention(block) (UNUserNotificationCenter, UNNotificationRequest, NotificationAddCompletion?) -> Void = {
                center, request, completion in
                let entry = "UNUserNotificationCenter.addNotificationRequest:withCompletionHandler:"
                guard gate.permitsExternal(entry) else {
                    completion?(refusal(entry))
                    return
                }
                gate.invokeOriginal(entry) { call(center, notificationAdd, request, completion) }
            }
            return block
        })

        let photos = #selector(PHPhotoLibrary.requestAuthorization(for:handler:)
            as (PHAccessLevel, @escaping @Sendable (PHAuthorizationStatus) -> Void) -> Void)
        record("PHPhotoLibrary.requestAuthorizationForAccessLevel:handler:",
               replaceClassMethod(PHPhotoLibrary.self, photos) { original in
            let call = unsafeBitCast(original, to: PhotosAuthorization.self)
            let block: @convention(block) (AnyObject, PHAccessLevel, PhotosHandler?) -> Void = { library, level, handler in
                let entry = "PHPhotoLibrary.requestAuthorizationForAccessLevel:handler:"
                // A decided status answers without a prompt; only a first
                // request shows the system's permission window.
                if PHPhotoLibrary.authorizationStatus(for: level) == .notDetermined,
                   !gate.permitsExternal(entry) {
                    handler?(.notDetermined)
                    return
                }
                gate.invokeOriginal(entry) { call(library, photos, level, handler) }
            }
            return block
        })

        return installed
    }

    /// Every loaded class that descends from NSWindow (NSWindow excluded).
    /// `objc_enumerateClasses` filters each image's classes by superclass
    /// before realizing any, so only window classes are touched. The walk
    /// used `objc_copyClassList`, which realizes every class in the process;
    /// realizing a Swift class runs its metadata initialization, and in a
    /// test process ContactsUICore's (loaded with SwiftUI) initialized
    /// `CNContactStore`, which opened the user's address book and tried to
    /// write its preferences (live check 2026-10-20).
    private static func loadedWindowSubclasses() -> [AnyClass] {
        let window = ObjectIdentifier(NSWindow.self)
        var seen: Set<ObjectIdentifier> = [window]
        var subclasses: [AnyClass] = []
        func collect(_ image: ObjCEnumerationImage) {
            for cls in objc_enumerateClasses(fromImage: image, subclassing: NSWindow.self)
            where seen.insert(ObjectIdentifier(cls)).inserted {
                subclasses.append(cls)
            }
        }
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index) else { continue }
            collect(.machHeader(UnsafeRawPointer(header)))
        }
        collect(.dynamicClasses)
        return subclasses
    }

    /// The method `cls` itself implements for `selector`, nil when inherited.
    private static func ownInstanceMethod(_ cls: AnyClass, _ selector: Selector) -> Method? {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return nil }
        defer { free(methods) }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
            return methods[index]
        }
        return nil
    }

    /// Replaces `selector` on `cls` itself. An inherited method gets an
    /// override on `cls` that calls the inherited implementation.
    private static func replaceInstanceMethod(_ cls: AnyClass, _ selector: Selector, _ make: (IMP) -> Any) -> IMP? {
        guard let method = class_getInstanceMethod(cls, selector) else { return nil }
        let replacement = imp_implementationWithBlock(make(method_getImplementation(method)))
        if !class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
        return replacement
    }

    private static func replaceClassMethod(_ cls: AnyClass, _ selector: Selector, _ make: (IMP) -> Any) -> IMP? {
        guard let method = class_getClassMethod(cls, selector), let metaclass = object_getClass(cls) else { return nil }
        let replacement = imp_implementationWithBlock(make(method_getImplementation(method)))
        if !class_addMethod(metaclass, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
        return replacement
    }
}
