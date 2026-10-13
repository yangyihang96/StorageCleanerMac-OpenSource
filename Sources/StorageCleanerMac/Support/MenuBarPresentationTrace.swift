import AppKit
import SwiftUI

/// Opt-in local audit. Draw acknowledgements are deliberately not labelled as
/// compositor presentation or physical display latency.
///
/// Records are data-only: keys, interaction labels (page and range names),
/// timings and load. Never readings, process names, paths or network identity.
/// Without `--menu-bar-performance-audit=` nothing here runs: probes are not
/// inserted, the run-loop monitor is not installed and every entry point
/// returns before doing work.
@MainActor
enum MenuBarPresentationTrace {
    nonisolated static let outputPath: String? = {
#if DEBUG || STORAGE_CLEANER_BETA
        let prefix = "--menu-bar-performance-audit="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }.flatMap { $0.hasPrefix("/") ? $0 : nil }
#else
        return nil
#endif
    }()
    static var enabled: Bool { outputPath != nil }

    /// Exact worker wall time, including waits inside a source. Data-only and
    /// opt-in; no sampling or main-actor hop when auditing is disabled.
    nonisolated static func measureSample<Value>(
        _ source: String, operation: () throws -> Value
    ) rethrows -> Value {
        guard outputPath != nil else { return try operation() }
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let end = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in recordSample(source, start: start, end: end) }
        }
        return try operation()
    }

    nonisolated static func measureAsyncSample<Value: Sendable>(
        _ source: String, operation: @Sendable () async -> Value
    ) async -> Value {
        guard outputPath != nil else { return await operation() }
        let start = ProcessInfo.processInfo.systemUptime
        let value = await operation()
        let end = ProcessInfo.processInfo.systemUptime
        await recordSample(source, start: start, end: end)
        return value
    }

    private static func recordSample(_ source: String, start: Double, end: Double) {
        write(["kind": "sample", "source": source, "startedUptime": start,
               "endUptime": end, "elapsedMs": (end - start) * 1000])
    }

    private struct Pending {
        let time: Double
        let event: Double?
        let publishedAt: Double?
        let label: String?
        let busyAtStart: Double
    }
    private static var pending: [String: Pending] = [:]
    private static var count = 0
    private static let recordLimit = 60_000
    private static var acceptingEvents = false
    private static let writer = DispatchQueue(label: "MenuBarPerformanceEvidence", qos: .utility)
    /// The interaction the run-loop monitor attributes main-thread time to.
    private(set) static var phase = "idle"
    private(set) static var phaseStartedUptime = ProcessInfo.processInfo.systemUptime
    /// Wall-clock time of the latest open. Cards that draw a sample taken
    /// after it acknowledge `fresh.<domain>`.
    private(set) static var freshnessThreshold: Date?
    static let freshnessDomains = ["cpu", "memory", "network", "capacity", "sensors", "battery"]
    private static let inputEventTypes: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .mouseMoved, .leftMouseDragged, .mouseEntered, .mouseExited, .scrollWheel, .keyDown, .keyUp
    ]

    static func startPresentation(event: NSEvent?, label: String = "open") {
        acceptingEvents = true
        guard enabled else { return }
        MenuBarMainThreadMonitor.installIfNeeded()
        freshnessThreshold = Date()
        begin("presentation", event: event, label: label)
        for domain in freshnessDomains {
            begin("fresh.\(domain)", event: event, label: label)
        }
        // First overview chart drawn from samples, and whether an empty
        // frame was drawn on the way.
        begin("chart.overview", event: event, label: label)
        begin("chart.empty.overview", event: event, label: label)
        // Whether a sampling placeholder or the CPU total's "—" was drawn
        // after the open, and when.
        begin("chart.placeholder.overview", event: event, label: label)
        begin("cpu.placeholder", event: event, label: label)
    }

    static func begin(_ key: String, event: NSEvent? = nil, publishedAt: Double? = nil, label: String? = nil) {
        guard enabled, acceptingEvents else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Only a person's input starts an input-to-draw interval; the event
        // AppKit last dispatched may be unrelated (a timer, a system event).
        let timestamp = event.flatMap { inputEventTypes.contains($0.type) ? $0.timestamp : nil }
        pending[key] = Pending(
            time: now,
            event: timestamp.flatMap { $0 <= now && now - $0 < 1 ? $0 : nil },
            publishedAt: publishedAt.flatMap { $0.isFinite && $0 <= now ? $0 : nil },
            label: label,
            busyAtStart: MenuBarMainThreadMonitor.cumulativeBusyMs(at: now)
        )
        if let label { setPhase(label) }
    }

    /// `begin` timed from the event being handled, if any.
    static func beginInput(_ key: String, label: String) {
        guard enabled, acceptingEvents else { return }
        begin(key, event: NSApp?.currentEvent, label: label)
    }

    /// Route changes of the attached panel. Each level has its own probe, so
    /// opening a page is not acknowledged by a redraw of another one.
    static func routeChanged(from old: GeekPanelRoute, to new: GeekPanelRoute, event: NSEvent?) {
        guard enabled, acceptingEvents else { return }
        switch new {
        case .summary:
            begin("summary", event: event, label: "summary.from.\(routeName(old))")
        case let .module(section):
            begin("secondary", event: event, label: "module.\(section.rawValue).from.\(routeName(old))")
        case let .history(section, selection):
            let label = "history.\(section.rawValue).\(selectionName(selection))"
            begin("tertiary", event: event, label: label)
            begin("chart.tertiary", event: event, label: label)
        }
    }

    /// A history range was selected: the previous window dims at once
    /// (`range.dimmed`), the selected one is drawn when prepared
    /// (`chart.tertiary`).
    static func rangeSelected(_ rawValue: Int, key: String) {
        guard enabled, acceptingEvents else { return }
        let label = "range.\(key).\(rawValue)"
        let event = NSApp?.currentEvent
        begin("range.dimmed", event: event, label: label)
        begin("chart.tertiary", event: event, label: label)
    }

    private static func routeName(_ route: GeekPanelRoute) -> String {
        switch route {
        case .summary: "summary"
        case let .module(section): "module.\(section.rawValue)"
        case let .history(section, selection): "history.\(section.rawValue).\(selectionName(selection))"
        }
    }

    private static func selectionName(_ selection: GeekPanelHistorySelection) -> String {
        switch selection {
        case let .builtIn(rawValue): rawValue
        case .inline: "inline"
        }
    }

    static func cancel(_ key: String) { pending.removeValue(forKey: key) }

    static func isPending(_ key: String) -> Bool { pending[key] != nil }

    static func discardPendingDraws() {
        acceptingEvents = false
        pending.removeAll(keepingCapacity: true)
        setPhase("hidden")
    }

    static func setPhase(_ label: String) {
        guard enabled else { return }
        phase = label
        phaseStartedUptime = ProcessInfo.processInfo.systemUptime
        mark("trace.phase", ["phase": label])
    }

    static func drew(_ key: String, window: NSWindow?) {
        guard outputPath != nil, let window, window.isVisible,
              let start = pending.removeValue(forKey: key) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var record: [String: Any] = ["kind": "appkit_draw_ack", "target": key,
            "startedUptime": start.time, "drawUptime": now,
            "elapsedMs": (now - start.time) * 1000,
            "window": window.windowNumber,
            "occlusionVisible": window.occlusionState.contains(.visible),
            "backingScale": window.backingScaleFactor]
        if let label = start.label { record["label"] = label }
        if let event = start.event { record["inputUptime"] = event; record["inputToDrawMs"] = (now - event) * 1000 }
        if let publishedAt = start.publishedAt {
            record["snapshotPublishedUptime"] = publishedAt
            record["publicationToDrawMs"] = (now - publishedAt) * 1000
        }
        record["mainBusyMs"] = MenuBarMainThreadMonitor.cumulativeBusyMs(at: now) - start.busyAtStart
        let iterations = MenuBarMainThreadMonitor.iterations(since: start.time, now: now)
        record["mainMaxIterationMs"] = iterations.maximumMs
        record["mainIterationsOver16Ms"] = iterations.over16
        record["mainIterationsOver50Ms"] = iterations.over50
        write(record)
        // AppKit drew it; Core Animation commits it when this run-loop
        // iteration ends, which is the earliest it can reach the screen.
        // (Card publications are frequent and keep only the draw record.)
        if !key.hasPrefix("card:") {
            MenuBarMainThreadMonitor.awaitCommit(target: key, label: start.label, startedUptime: start.time,
                                                 inputUptime: start.event, drawUptime: now)
        }
    }

    /// An instantaneous, data-only event (script steps, open context).
    static func mark(_ name: String, _ fields: @autoclosure () -> [String: Any] = [:]) {
        guard enabled else { return }
        var record = fields()
        record["kind"] = "mark"
        record["name"] = name
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        write(record)
    }

    /// Synchronous main-thread work measured in place.
    static func span(_ name: String, from start: Double, _ fields: @autoclosure () -> [String: Any] = [:]) {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var record = fields()
        record["kind"] = "span"
        record["name"] = name
        record["startedUptime"] = start
        record["endUptime"] = now
        record["elapsedMs"] = (now - start) * 1000
        record["phase"] = phase
        write(record)
    }

    /// Main-thread work of a named segment in the current run-loop iteration
    /// (monitor delivery, card reconciliation, sampling demand, …). A
    /// `main_stall` lists the segments of its iteration and `main_busy` their
    /// totals, so a long iteration says where its time went; a segment over
    /// 16 ms is also written as a span. Segments may nest.
    @discardableResult
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            MenuBarMainThreadMonitor.addSegment(name, ms: ms)
            if ms > 16 { span(name, from: start) }
        }
        return try body()
    }

    static var uptime: Double { ProcessInfo.processInfo.systemUptime }

    /// One-minute load average; -1 when unavailable.
    static var loadAverage: Double {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) > 0 ? values[0] : -1
    }

    fileprivate static func write(_ record: [String: Any]) {
        guard let path = outputPath, count < recordLimit else { return }
        count += 1
        var record = record
        record["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let payload = data
        writer.async {
            if !FileManager.default.fileExists(atPath: path) { _ = FileManager.default.createFile(atPath: path, contents: nil) }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: payload) } catch { }
        }
    }
}

/// Main run-loop busy time while the audit is enabled: every wake-up to the
/// next sleep is one iteration (event handling, SwiftUI updates, layout and
/// the Core Animation commit). Iterations longer than the 50 ms budget are
/// written as `main_stall` with the interaction that was active; a summary of
/// all iterations is written every ten seconds as `main_busy`.
@MainActor
enum MenuBarMainThreadMonitor {
    private static var observers: [CFRunLoopObserver] = []
    private static var iterationStart: Double?
    private struct AwaitingCommit {
        let target: String
        let label: String?
        let startedUptime: Double
        let inputUptime: Double?
        let drawUptime: Double
    }
    private static var awaitingCommit: [AwaitingCommit] = []
    private static var completedBusyMs: Double = 0
    private static let ringCapacity = 4_096
    private static var ringEnds = [Double](repeating: 0, count: 4_096)
    private static var ringDurations = [Double](repeating: 0, count: 4_096)
    private static var ringNext = 0
    private static var ringCount = 0
    private static var windowStart: Double = 0
    private static var windowBusyMs: Double = 0
    private static var windowIterations = 0
    private static var windowMaximumMs: Double = 0
    private static var windowOver16 = 0
    private static var windowOver50 = 0
    private static var segmentMs: [String: Double] = [:]
    private static var windowSegmentMs: [String: Double] = [:]
    static let summaryInterval: Double = 10
    /// A `main_stall` at least this long carries the main thread's stacks
    /// sampled while it ran (`MenuBarStallSampler`).
    static let stackThresholdMs: Double = 150

    static func installIfNeeded() {
        guard MenuBarPresentationTrace.enabled, observers.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        windowStart = now
        iterationStart = now
#if DEBUG || STORAGE_CLEANER_BETA
        MenuBarStallSampler.shared.start()
        MenuBarStallSampler.shared.iterationBegan(at: now)
#endif
        // Wake-up first, sleep last: the Core Animation commit and AppKit's
        // display observers run before this one at `beforeWaiting`.
        let wake = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { _, _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                iterationStart = now
#if DEBUG || STORAGE_CLEANER_BETA
                MenuBarStallSampler.shared.iterationBegan(at: now)
#endif
            }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated { iterationEnded(at: ProcessInfo.processInfo.systemUptime) }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    static func awaitCommit(target: String, label: String?, startedUptime: Double, inputUptime: Double?, drawUptime: Double) {
        guard !observers.isEmpty, awaitingCommit.count < 256 else { return }
        awaitingCommit.append(AwaitingCommit(target: target, label: label, startedUptime: startedUptime,
                                             inputUptime: inputUptime, drawUptime: drawUptime))
    }

    static func addSegment(_ name: String, ms: Double) {
        guard !observers.isEmpty else { return }
        segmentMs[name, default: 0] += ms
        windowSegmentMs[name, default: 0] += ms
    }

    private static func rounded(_ segments: [String: Double]) -> [String: Double] {
        segments.mapValues { ($0 * 10).rounded() / 10 }
    }

    static func cumulativeBusyMs(at now: Double) -> Double {
        completedBusyMs + (iterationStart.map { max(0, now - $0) * 1000 } ?? 0)
    }

    static func iterations(since start: Double, now: Double) -> (maximumMs: Double, over16: Int, over50: Int) {
        var maximum = iterationStart.map { max(0, now - max($0, start)) * 1000 } ?? 0
        var over16 = 0
        var over50 = 0
        var index = ringNext
        for _ in 0..<ringCount {
            index = (index - 1 + ringCapacity) % ringCapacity
            guard ringEnds[index] >= start else { break }
            let duration = ringDurations[index]
            maximum = max(maximum, duration)
            if duration > 16 { over16 += 1 }
            if duration > 50 { over50 += 1 }
        }
        return (maximum, over16, over50)
    }

    private static func iterationEnded(at now: Double) {
        if !awaitingCommit.isEmpty {
            for pending in awaitingCommit {
                var record: [String: Any] = [
                    "kind": "commit_ack", "target": pending.target,
                    "startedUptime": pending.startedUptime, "drawUptime": pending.drawUptime,
                    "commitUptime": now, "elapsedMs": (now - pending.startedUptime) * 1000,
                    "drawToCommitMs": (now - pending.drawUptime) * 1000
                ]
                if let label = pending.label { record["label"] = label }
                if let input = pending.inputUptime { record["inputToCommitMs"] = (now - input) * 1000 }
                MenuBarPresentationTrace.write(record)
            }
            awaitingCommit.removeAll(keepingCapacity: true)
        }
#if DEBUG || STORAGE_CLEANER_BETA
        let samples = MenuBarStallSampler.shared.iterationEnded()
#endif
        let segments = segmentMs
        segmentMs.removeAll(keepingCapacity: true)
        guard let start = iterationStart else { return }
        iterationStart = nil
        let duration = max(0, now - start) * 1000
        completedBusyMs += duration
        ringEnds[ringNext] = now
        ringDurations[ringNext] = duration
        ringNext = (ringNext + 1) % ringCapacity
        ringCount = min(ringCapacity, ringCount + 1)
        windowBusyMs += duration
        windowIterations += 1
        windowMaximumMs = max(windowMaximumMs, duration)
        if duration > 16 { windowOver16 += 1 }
        if duration > MenuBarPerformancePolicy.mainThreadBlockBudget * 1000 {
            windowOver50 += 1
            var record: [String: Any] = [
                "kind": "main_stall", "ms": duration, "endUptime": now,
                "phase": MenuBarPresentationTrace.phase,
                "sincePhaseMs": (now - MenuBarPresentationTrace.phaseStartedUptime) * 1000
            ]
            if !segments.isEmpty { record["segments"] = rounded(segments) }
#if DEBUG || STORAGE_CLEANER_BETA
            if duration >= stackThresholdMs, !samples.isEmpty {
                record["stackSamples"] = samples.count
                record["stacks"] = MenuBarStallSampler.describe(samples)
            }
#endif
            MenuBarPresentationTrace.write(record)
        }
        if now - windowStart >= summaryInterval {
            var record: [String: Any] = [
                "kind": "main_busy", "windowStartUptime": windowStart, "windowEndUptime": now,
                "busyMs": windowBusyMs, "iterations": windowIterations,
                "maximumMs": windowMaximumMs, "over16": windowOver16, "over50": windowOver50,
                "phase": MenuBarPresentationTrace.phase
            ]
            if !windowSegmentMs.isEmpty { record["segments"] = rounded(windowSegmentMs) }
            MenuBarPresentationTrace.write(record)
            windowStart = now
            windowBusyMs = 0
            windowIterations = 0
            windowMaximumMs = 0
            windowOver16 = 0
            windowOver50 = 0
            windowSegmentMs.removeAll(keepingCapacity: true)
        }
    }
}

struct MenuBarPresentationProbe: NSViewRepresentable {
    let key: String
    var revision: UInt64 = 0
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.key = key
        view.needsDisplay = true
    }
    final class Probe: NSView {
        var key = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { MenuBarPresentationTrace.drew(key, window: window) }
    }

    static func revision(_ point: CGPoint?) -> UInt64 {
        guard let point, point.x.isFinite, point.y.isFinite else { return 0 }
        return UInt64(truncatingIfNeeded: Int(point.x * 16)) &* 1_000_003 &+ UInt64(truncatingIfNeeded: Int(point.y * 16))
    }

    static func revision(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return hash
    }
}

private struct MenuBarTraceRegionKey: EnvironmentKey {
    static let defaultValue = "overview"
}

private struct MenuBarTraceChartIsStaleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Which level a prepared chart belongs to (`chart.<region>` probes).
    var menuBarTraceRegion: String {
        get { self[MenuBarTraceRegionKey.self] }
        set { self[MenuBarTraceRegionKey.self] = newValue }
    }

    /// The chart still draws the previously selected window.
    var menuBarTraceChartIsStale: Bool {
        get { self[MenuBarTraceChartIsStaleKey.self] }
        set { self[MenuBarTraceChartIsStaleKey.self] = newValue }
    }
}

extension View {
    /// Names the level for chart probes; nothing is applied unless the audit
    /// is enabled.
    @MainActor
    @ViewBuilder
    func menuBarTraceRegion(_ region: String) -> some View {
        if MenuBarPresentationTrace.enabled {
            environment(\.menuBarTraceRegion, region)
        } else {
            self
        }
    }

    @MainActor
    @ViewBuilder
    func menuBarTraceChartIsStale(_ stale: Bool) -> some View {
        if MenuBarPresentationTrace.enabled {
            environment(\.menuBarTraceChartIsStale, stale)
        } else {
            self
        }
    }

    /// Lets the latency script drive a chart's hover state (Debug/Beta,
    /// script runs only); otherwise the view is returned unchanged.
    @MainActor
    @ViewBuilder
    func menuBarScriptHover(_ label: String, enabled: Bool, apply: @escaping (CGPoint?) -> Void) -> some View {
#if DEBUG || STORAGE_CLEANER_BETA
        if enabled, MenuBarLatencyScript.isRequested {
            modifier(MenuBarScriptHoverModifier(label: label, apply: apply))
        } else {
            self
        }
#else
        self
#endif
    }

    /// Audit-only content behind the view; not built unless the audit is
    /// enabled.
    @MainActor
    @ViewBuilder
    func menuBarTraceProbe<Probe: View>(@ViewBuilder _ probe: () -> Probe) -> some View {
        if MenuBarPresentationTrace.enabled {
            background(alignment: .topLeading) {
                probe()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            self
        }
    }

    /// A one-point probe: drawing it acknowledges `key` when that key is
    /// pending. Nothing is inserted, and the arguments are not evaluated,
    /// unless the audit is enabled.
    @MainActor
    @ViewBuilder
    func menuBarPresentationProbe(
        _ key: @autoclosure () -> String,
        revision: @autoclosure () -> UInt64 = 0,
        when condition: @autoclosure () -> Bool = true
    ) -> some View {
        if MenuBarPresentationTrace.enabled {
            background(alignment: .topLeading) {
                if condition() {
                    MenuBarPresentationProbe(key: key(), revision: revision())
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        } else {
            self
        }
    }
}
