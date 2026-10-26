#if DEBUG || STORAGE_CLEANER_BETA
import AppKit
import Combine
import SwiftUI

/// Opt-in latency driver for the menu-bar panel (Debug/Beta only).
///
/// `--menu-bar-latency-script=<plan>` together with
/// `--menu-bar-performance-audit=<absolute JSONL path>` drives the panel on
/// live monitoring data through the entry points a click uses: the status
/// controller's open path, `GeekPanelCoordinator` routes, the settings range
/// funnel, the session's Escape and outside-click handlers. Every step is
/// written to the audit log, so the same probes also time real clicks.
///
/// The panel is placed on a virtual display outside every screen. The script
/// never activates the application, never makes the panel key, keeps the main
/// window hidden, and does not post system input events; outside clicks of
/// the person using this Mac are ignored so they cannot interrupt it. Hover
/// is driven with mouse-moved events delivered only to the off-screen panel.
///
/// Plan: `key=value` pairs separated by `;`, e.g.
/// `phases=first,openclose,modules,tertiary,ranges,hover,select,steady;iterations=20`.
@MainActor
enum MenuBarLatencyScript {
    static let argumentPrefix = "--menu-bar-latency-script="

    static let plan: String? = ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix(argumentPrefix) }
        .map { String($0.dropFirst(argumentPrefix.count)) }

    static var isRequested: Bool {
        plan != nil && MenuBarPresentationTrace.enabled && !MiniWindowDemoData.isEnabled
    }

    private static var allowsScriptedOutsideClick = false
    static var ignoresOutsideInput: Bool { isRequested && !allowsScriptedOutsideClick }

    private static var task: Task<Void, Never>?

    private struct Configuration {
        var phases = ["first", "openclose", "modules", "tertiary", "ranges", "hover", "select", "steady"]
        var iterations = 20
        var rangeIterations = 20
        var rangeSections: [PanelSection] = [.processor, .memory]
        // D130: 60 s is no longer a window (read as 10 minutes).
        var ranges: [GeekChartRange] = [.tenMinutes, .oneHour, .oneDay, .sevenDays, .twentyEightDays]
        var settleSeconds = 20.0
        var maximumLoad = 4.0
        var steadySeconds = 60.0
        var hoverMoves = 240
        /// The level-3 history the hover sweep runs on, and its range (the
        /// current one when not given).
        var hoverSection: PanelSection = .processor
        var hoverRange: GeekChartRange?
        /// `hold`: a level-3 history kept open and idle for `holdSeconds`.
        var holdSection: PanelSection = .memory
        var holdRange: GeekChartRange?
        var holdSeconds = 120.0
        /// When above 0, the held history is then hidden directly (outside
        /// click, the level-3 page still open) for this many seconds and the
        /// panel opened again: the windows kept while hidden (D39,
        /// `history.kept`) include the held range.
        var holdHideSeconds = 0.0
        /// The run asks the system not to throttle it (App Nap, timer
        /// coalescing); `activity=0` runs without, to calibrate against.
        var latencyCriticalActivity = true

        init(_ plan: String) {
            for pair in plan.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let value = parts[1]
                switch parts[0] {
                case "phases": phases = value.split(separator: ",").map(String.init)
                case "iterations": iterations = Int(value) ?? iterations
                case "rangeIterations": rangeIterations = Int(value) ?? rangeIterations
                case "rangeSections":
                    rangeSections = value.split(separator: ",").compactMap { PanelSection(rawValue: String($0)) }
                case "ranges":
                    ranges = value.split(separator: ",").compactMap { Int($0).flatMap(GeekChartRange.init(rawValue:)) }
                case "settle": settleSeconds = Double(value) ?? settleSeconds
                case "maxLoad": maximumLoad = Double(value) ?? maximumLoad
                case "steady": steadySeconds = Double(value) ?? steadySeconds
                case "hoverMoves": hoverMoves = Int(value) ?? hoverMoves
                case "hoverSection": hoverSection = PanelSection(rawValue: value) ?? hoverSection
                case "hoverRange": hoverRange = Int(value).flatMap(GeekChartRange.init(rawValue:))
                case "holdSection": holdSection = PanelSection(rawValue: value) ?? holdSection
                case "holdRange": holdRange = Int(value).flatMap(GeekChartRange.init(rawValue:))
                case "hold": holdSeconds = Double(value) ?? holdSeconds
                case "holdHide": holdHideSeconds = Double(value) ?? holdHideSeconds
                case "activity": latencyCriticalActivity = value != "0"
                default: break
                }
            }
        }
    }

    // MARK: Launch

    private static var activity: NSObjectProtocol?

    /// Keeps the isolated measurement build out of the way: no Dock icon,
    /// no activation. The run is marked latency-critical, so App Nap and
    /// timer coalescing of an accessory app without windows on screen do not
    /// stretch what is measured.
    static func prepareApplicationIfRequested() {
        guard isRequested else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        if Configuration(plan ?? "").latencyCriticalActivity, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Menu-bar latency script"
            )
        }
    }

    static func start(store: ScanStore) {
        guard isRequested, task == nil else { return }
        task = Task { @MainActor in
            await run(store: store, configuration: Configuration(plan ?? ""))
        }
    }

    // MARK: Driver

    private static var controller: MenuBarStatusController { .shared }
    private static var session: MenuBarPanelSession? { controller.latencyScriptSession }
    private static var coordinator: GeekPanelCoordinator? { session?.latencyScriptCoordinator }

    private static func run(store: ScanStore, configuration: Configuration) async {
        setPhase("launch")
        MenuBarPresentationTrace.mark("script.start", [
            "plan": plan ?? "", "load1": MenuBarPresentationTrace.loadAverage,
            "screens": NSScreen.screens.count,
            "mainBackingScale": NSScreen.main?.backingScaleFactor ?? 0,
            "battery": String(describing: store.menuBarAuxiliaryMonitorState.internalBatteryAvailability),
            "latencyCriticalActivity": activity != nil
        ])
        _ = await waitUntil(seconds: 90) { store.menuBarMonitorState.snapshot != nil }
        await pause(configuration.settleSeconds)
        MenuBarPresentationTrace.mark("script.ready", [
            "load1": MenuBarPresentationTrace.loadAverage,
            "historyPoints": store.menuBarMonitorState.history.count,
            "battery": String(describing: store.menuBarAuxiliaryMonitorState.internalBatteryAvailability)
        ])
        for phase in configuration.phases {
            setPhase("script.\(phase)")
            MenuBarPresentationTrace.mark("script.phase", ["phase": phase, "load1": MenuBarPresentationTrace.loadAverage])
            switch phase {
            case "first": await firstOpen()
            case "openclose": await openClose(configuration)
            case "modules": await modules(configuration, store: store)
            case "tertiary": await tertiary(configuration, store: store)
            case "ranges": await ranges(configuration)
            case "hover": await hover(configuration)
            case "hold": await hold(configuration)
            case "select": await selection(configuration, store: store)
            case "steady": await steady(configuration)
            default: MenuBarPresentationTrace.mark("script.unknownPhase", ["phase": phase])
            }
        }
        if session?.panel.isVisible == true { session?.hide(reason: "script-end") }
        setPhase("done")
        MenuBarPresentationTrace.mark("script.end", ["load1": MenuBarPresentationTrace.loadAverage])
    }

    private static func firstOpen() async {
        await waitForQuiet(Configuration(plan ?? ""))
        open()
        await acknowledge("presentation", seconds: 5)
        await acknowledgeFreshness()
        await pause(1)
        hideByEscape()
        await pause(1.5)
    }

    private static func openClose(_ configuration: Configuration) async {
        for iteration in 0..<configuration.iterations {
            await waitForQuiet(configuration)
            MenuBarPresentationTrace.mark("script.iteration", ["phase": "openclose", "i": iteration,
                                                               "load1": MenuBarPresentationTrace.loadAverage])
            controller.latencyScriptReclaimPanel()
            await pause(1)
            open()
            await acknowledge("presentation", seconds: 5)
            await acknowledgeFreshness()
            await pause(0.5)
            hideByEscape()
            await pause(1)
            open()
            await acknowledge("presentation", seconds: 5)
            await acknowledgeFreshness()
            await pause(0.5)
            hideByOutsideClick()
            await pause(1)
        }
    }

    private static func sections(_ store: ScanStore) -> [PanelSection] {
        var sections: [PanelSection] = [.processor, .memory, .disk, .network, .sensors]
        if store.menuBarAuxiliaryMonitorState.internalBatteryAvailability == .present {
            sections.append(.power)
        }
        return sections
    }

    private static func modules(_ configuration: Configuration, store: ScanStore) async {
        ensureOpen()
        await acknowledge("presentation", seconds: 5)
        await pause(1)
        let sections = sections(store)
        for iteration in 0..<configuration.iterations {
            await waitForQuiet(configuration)
            MenuBarPresentationTrace.mark("script.iteration", ["phase": "modules", "i": iteration,
                                                               "load1": MenuBarPresentationTrace.loadAverage])
            // Level 1 -> level 2 for every module.
            for section in sections {
                coordinator?.selectModule(section)
                await acknowledge("secondary", seconds: 4)
                await pause(0.8)
                coordinator?.reset()
                await acknowledge("summary", seconds: 3)
                await pause(0.5)
            }
            // Switching modules while level 2 is open.
            coordinator?.selectModule(sections[0])
            await acknowledge("secondary", seconds: 4)
            await pause(0.8)
            for section in sections.dropFirst() + [sections[0]] {
                coordinator?.selectModule(section)
                await acknowledge("secondary", seconds: 4)
                await pause(0.8)
            }
            coordinator?.reset()
            await acknowledge("summary", seconds: 3)
            await pause(0.5)
        }
    }

    private static func tertiary(_ configuration: Configuration, store: ScanStore) async {
        ensureOpen()
        await acknowledge("presentation", seconds: 5)
        await pause(1)
        for iteration in 0..<configuration.iterations {
            await waitForQuiet(configuration)
            MenuBarPresentationTrace.mark("script.iteration", ["phase": "tertiary", "i": iteration,
                                                               "load1": MenuBarPresentationTrace.loadAverage])
            for section in sections(store) {
                guard let detail = section.tertiaryDetail else { continue }
                coordinator?.selectModule(section)
                await acknowledge("secondary", seconds: 4)
                await pause(0.8)
                coordinator?.presentHistory(.builtIn(detail.rawValue), pinned: true)
                await acknowledge("tertiary", seconds: 4)
                if detail != .network {
                    // The network level 3 lists interfaces; it has no chart.
                    await acknowledge("chart.tertiary", seconds: 6)
                } else {
                    MenuBarPresentationTrace.cancel("chart.tertiary")
                }
                await pause(0.5)
                coordinator?.dismissHistory()
                await pause(0.5)
                coordinator?.reset()
                await acknowledge("summary", seconds: 3)
                await pause(0.5)
            }
        }
    }

    private static func ranges(_ configuration: Configuration) async {
        ensureOpen()
        await acknowledge("presentation", seconds: 5)
        await pause(1)
        for section in configuration.rangeSections {
            guard let detail = section.tertiaryDetail,
                  let settings = session?.latencyScriptSettings else { continue }
            let original = settings.geekChartRange(for: section)
            coordinator?.selectModule(section)
            await acknowledge("secondary", seconds: 4)
            await pause(0.8)
            coordinator?.presentHistory(.builtIn(detail.rawValue), pinned: true)
            await acknowledge("tertiary", seconds: 4)
            await acknowledge("chart.tertiary", seconds: 6)
            await pause(1)
            for iteration in 0..<configuration.rangeIterations {
                await waitForQuiet(configuration)
                MenuBarPresentationTrace.mark("script.iteration", ["phase": "ranges", "section": section.rawValue,
                                                                   "i": iteration, "load1": MenuBarPresentationTrace.loadAverage])
                for range in configuration.ranges where range != settings.geekChartRange(for: section) {
                    session?.latencyScriptSettings?.setGeekChartRange(range, for: section)
                    await acknowledge("range.dimmed", seconds: 2)
                    await acknowledge("chart.tertiary", seconds: 10)
                    await pause(0.4)
                }
            }
            session?.latencyScriptSettings?.setGeekChartRange(original, for: section)
            await pause(1)
            coordinator?.dismissHistory()
            await pause(0.5)
            coordinator?.reset()
            await acknowledge("summary", seconds: 3)
            await pause(0.5)
        }
    }

    /// SwiftUI resolves hover from the real pointer, which never enters the
    /// off-screen panel. While the script runs, the level-3 charts also take
    /// a hover location from this subject (`menuBarScriptHover`) and do what
    /// a pointer move does: store it and redraw crosshair and tooltip.
    static let hoverLocations = PassthroughSubject<CGPoint?, Never>()

    private static func hover(_ configuration: Configuration) async {
        guard let restore = await openHistory(configuration.hoverSection, range: configuration.hoverRange,
                                              configuration: configuration, phase: "hover") else { return }
        guard let session, session.latencyScriptChildFrames.count == 2 else {
            MenuBarPresentationTrace.mark("script.skipped", ["phase": "hover", "reason": "no level 3"])
            await closeHistory(restore)
            return
        }
        let width = session.latencyScriptChildFrames[1].width
        setPhase("hover.sweep.\(configuration.hoverSection.rawValue).\(restore.range.rawValue)")
        var moves = 0
        while moves < configuration.hoverMoves {
            // Across the plot and back, 60 moves per second.
            let step = moves % 240
            let fraction = CGFloat(step < 120 ? step : 239 - step) / 119
            hoverLocations.send(CGPoint(x: 6 + (width - 40) * fraction, y: 60))
            moves += 1
            await pause(0.016)
        }
        hoverLocations.send(nil)
        MenuBarPresentationTrace.mark("script.hover", ["moves": moves, "section": configuration.hoverSection.rawValue,
                                                       "range": restore.range.rawValue])
        await pause(0.5)
        await closeHistory(restore)
    }

    /// A level-3 history kept open and idle: its own cost while it follows
    /// the samples (`hold.<page>.<range>` in the run's phase file).
    private static func hold(_ configuration: Configuration) async {
        guard let restore = await openHistory(configuration.holdSection, range: configuration.holdRange,
                                              configuration: configuration, phase: "hold") else { return }
        setPhase("hold.\(configuration.holdSection.rawValue).\(restore.range.rawValue)")
        MenuBarPresentationTrace.mark("script.hold", ["section": configuration.holdSection.rawValue,
                                                      "range": restore.range.rawValue,
                                                      "seconds": configuration.holdSeconds])
        await pause(configuration.holdSeconds)
        if configuration.holdHideSeconds > 0 {
            setPhase("hold.hidden")
            hideByOutsideClick()
            await pause(configuration.holdHideSeconds)
            setPhase("hold.reopened")
            open()
            await acknowledge("presentation", seconds: 5)
            await pause(2)
        }
        await closeHistory(restore)
    }

    private struct HistoryRestore {
        let section: PanelSection
        let range: GeekChartRange
        let original: GeekChartRange
    }

    /// Opens `section`'s level-3 history on `range` (its current range when
    /// nil) and waits for its chart.
    private static func openHistory(_ section: PanelSection, range: GeekChartRange?,
                                    configuration: Configuration, phase: String) async -> HistoryRestore? {
        ensureOpen()
        await acknowledge("presentation", seconds: 5)
        await pause(1)
        await waitForQuiet(configuration)
        guard let detail = section.tertiaryDetail, let settings = session?.latencyScriptSettings else {
            MenuBarPresentationTrace.mark("script.skipped", ["phase": phase, "reason": "no level 3 for \(section.rawValue)"])
            return nil
        }
        let original = settings.geekChartRange(for: section)
        coordinator?.selectModule(section)
        await acknowledge("secondary", seconds: 4)
        await pause(0.8)
        coordinator?.presentHistory(.builtIn(detail.rawValue), pinned: true)
        await acknowledge("tertiary", seconds: 4)
        await acknowledge("chart.tertiary", seconds: 6)
        await pause(1)
        if let range, range != original {
            session?.latencyScriptSettings?.setGeekChartRange(range, for: section)
            await acknowledge("range.dimmed", seconds: 2)
            await acknowledge("chart.tertiary", seconds: 10)
            await pause(1)
        }
        return HistoryRestore(section: section, range: range ?? original, original: original)
    }

    private static func closeHistory(_ restore: HistoryRestore) async {
        if restore.range != restore.original {
            session?.latencyScriptSettings?.setGeekChartRange(restore.original, for: restore.section)
            await pause(1)
        }
        coordinator?.dismissHistory()
        await pause(0.5)
        coordinator?.reset()
        await pause(0.5)
    }

    private static func selection(_ configuration: Configuration, store: ScanStore) async {
        ensureOpen()
        await acknowledge("presentation", seconds: 5)
        await pause(1)
        coordinator?.selectModule(.memory)
        await acknowledge("secondary", seconds: 4)
        // The page asks for its process groups when it appears.
        _ = await waitUntil(seconds: 10) { !store.menuBarPreparedMemoryApps.isEmpty }
        await pause(1)
        guard let app = store.menuBarPreparedMemoryApps.first(where: { !$0.selectableProcessIDs.isEmpty }),
              store.canEditMemorySelection else {
            MenuBarPresentationTrace.mark("script.skipped", ["phase": "select", "reason": "no selectable group"])
            coordinator?.reset()
            return
        }
        let wasSelected = store.isMemoryAppUsageSelected(app)
        for iteration in 0..<configuration.iterations {
            await waitForQuiet(configuration)
            MenuBarPresentationTrace.mark("script.iteration", ["phase": "select", "i": iteration,
                                                               "load1": MenuBarPresentationTrace.loadAverage])
            for _ in 0..<2 {
                // Selection is locked while the page reloads its groups.
                _ = await waitUntil(seconds: 5) { store.canEditMemorySelection }
                let before = store.isMemoryAppUsageSelected(app)
                MenuBarPresentationTrace.begin("process.select", label: "process.select")
                store.toggleMemoryAppUsageSelection(app)
                guard store.isMemoryAppUsageSelected(app) != before else {
                    MenuBarPresentationTrace.cancel("process.select")
                    MenuBarPresentationTrace.mark("script.selectIgnored", [:])
                    await pause(0.4)
                    continue
                }
                await acknowledge("process.select", seconds: 2)
                await pause(0.4)
            }
        }
        store.setMemoryAppUsageSelection(app, isSelected: wasSelected)
        await pause(0.5)
        coordinator?.reset()
        await pause(0.5)
    }

    /// Idle cost: overview visible, level 2 visible, hidden, reclaimed. The
    /// run's shell samples CPU and memory against `<audit>.phase`.
    private static func steady(_ configuration: Configuration) async {
        await waitForQuiet(configuration)
        ensureOpen()
        await acknowledge("presentation", seconds: 5)
        setPhase("steady.visible.overview")
        await pause(configuration.steadySeconds)
        coordinator?.selectModule(.processor)
        await acknowledge("secondary", seconds: 4)
        setPhase("steady.visible.processor")
        await pause(configuration.steadySeconds)
        coordinator?.reset()
        await pause(0.5)
        hideByEscape()
        setPhase("steady.hidden.warm")
        await pause(configuration.steadySeconds)
        controller.latencyScriptReclaimPanel()
        setPhase("steady.reclaimed")
        await pause(configuration.steadySeconds)
    }

    // MARK: Steps

    /// A virtual display left of every screen, the size of the main one.
    private static var virtualVisibleFrame: NSRect {
        let main = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 944)
        let leftmost = NSScreen.screens.map(\.frame.minX).min() ?? 0
        return NSRect(x: leftmost - main.width - 20_000, y: main.minY, width: main.width, height: main.height)
    }

    private static func open() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = virtualVisibleFrame
        let anchor = NSRect(x: visible.maxX - 260, y: visible.maxY + 2, width: 30, height: 22)
        controller.latencyScriptPresent(anchor: anchor, screen: screen, visibleFrame: visible)
    }

    private static func ensureOpen() {
        if session?.panel.isVisible != true { open() }
    }

    private static func hideByEscape() {
        guard let session, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: session.panel.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) else { return }
        // Escape steps back one level per press, as on the keyboard.
        for _ in 0..<3 where session.panel.isVisible {
            _ = session.handleKeyEvent(event, sourceWindow: session.panel)
        }
    }

    private static func hideByOutsideClick() {
        guard let session else { return }
        allowsScriptedOutsideClick = true
        defer { allowsScriptedOutsideClick = false }
        let outside = NSPoint(x: virtualVisibleFrame.minX + 10, y: virtualVisibleFrame.minY + 10)
        session.handleMouseDown(sourceWindow: nil, screenLocation: outside, eventWindowNumber: nil)
    }

    private static func acknowledge(_ key: String, seconds: Double) async {
        let acknowledged = await waitUntil(seconds: seconds) { !MenuBarPresentationTrace.isPending(key) }
        if !acknowledged {
            MenuBarPresentationTrace.mark("script.timeout", ["key": key, "phase": MenuBarPresentationTrace.phase])
        }
    }

    private static func acknowledgeFreshness() async {
        for domain in ["cpu", "memory"] {
            await acknowledge("fresh.\(domain)", seconds: 6)
        }
    }

    private static func waitForQuiet(_ configuration: Configuration) async {
        let started = Date()
        while MenuBarPresentationTrace.loadAverage >= configuration.maximumLoad,
              Date().timeIntervalSince(started) < 900 {
            await pause(5)
        }
        let waited = Date().timeIntervalSince(started)
        if waited > 1 {
            MenuBarPresentationTrace.mark("script.waitedForLoad", [
                "seconds": waited, "load1": MenuBarPresentationTrace.loadAverage
            ])
        }
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            await pause(0.02)
        }
        return true
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static func setPhase(_ phase: String) {
        MenuBarPresentationTrace.setPhase(phase)
        guard let path = MenuBarPresentationTrace.outputPath else { return }
        try? Data((phase + "\n").utf8).write(to: URL(fileURLWithPath: path + ".phase"), options: .atomic)
    }
}

/// Keeps the main window of a latency-script launch off screen and closes it:
/// the measurement build must not appear over the person's work.
struct MenuBarLatencyScriptWindowSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SuppressorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class SuppressorView: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            hide(newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            hide(window)
            DispatchQueue.main.async { [weak window] in
                window?.orderOut(nil)
                window?.close()
            }
        }

        private func hide(_ window: NSWindow?) {
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: -60_000, y: -60_000))
        }
    }
}
/// Feeds the script's hover locations to a level-3 chart (see
/// `MenuBarLatencyScript.hoverLocations`).
struct MenuBarScriptHoverModifier: ViewModifier {
    @Environment(\.menuBarTraceRegion) private var region
    let label: String
    let apply: (CGPoint?) -> Void

    func body(content: Content) -> some View {
        content.onReceive(MenuBarLatencyScript.hoverLocations) { location in
            guard region == "tertiary" else { return }
            if location != nil {
                MenuBarPresentationTrace.begin("hover", label: label)
            }
            apply(location)
        }
    }
}
#endif
