#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class BenchmarkMonitorLayoutTests: XCTestCase {
    /// U1 029: the load curve no longer sits inside the temperature dial. The
    /// dial is a complete circle; the chart has its own full-width area below
    /// it, and the monitor never grows taller than the height it is given.
    func testLoadChartSitsOutsideACompleteTemperatureDial() async throws {
        let cases: [(width: CGFloat, height: CGFloat)] = [
            (300, 315), (304, 300), (360, 330), (520, 430), (220, 430),
        ]
        for (width, height) in cases {
            let recorder = BenchmarkLayoutRecorder()
            let root = BenchmarkSystemMonitor(telemetryPoints: [], accent: MonitorPalette.pink,
                                              availableHeight: height)
                .frame(width: width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                    Task { @MainActor in recorder.frames = frames }
                }
            let host = BenchmarkLayoutHost(root: root, size: CGSize(width: width, height: 620))
            defer { host.close() }
            let frames = try await host.frames(from: recorder,
                                               required: ["benchmark.monitor", "benchmark.monitor.dial",
                                                          "benchmark.monitor.chart"])
            let tag = "\(Int(width))x\(Int(height))"
            let monitor = try XCTUnwrap(frames["benchmark.monitor"])
            let dial = try XCTUnwrap(frames["benchmark.monitor.dial"])
            let chart = try XCTUnwrap(frames["benchmark.monitor.chart"])
            let metrics = BenchmarkMonitorLayout(width: width - 2 * AppDesignTokens.Spacing.small,
                                                 height: height - 2 * AppDesignTokens.Spacing.small)

            XCTAssertEqual(dial.width, dial.height, accuracy: 1, "A complete circle: \(tag)")
            XCTAssertEqual(dial.width, metrics.diameter, accuracy: 1, tag)
            XCTAssertGreaterThanOrEqual(dial.width, 110, tag)
            XCTAssertGreaterThanOrEqual(chart.minY, dial.maxY - 0.5, "The chart is below the dial: \(tag)")
            XCTAssertFalse(dial.insetBy(dx: 1, dy: 1).intersects(chart), tag)
            XCTAssertTrue(monitor.insetBy(dx: -1, dy: -1).contains(dial), tag)
            XCTAssertTrue(monitor.insetBy(dx: -1, dy: -1).contains(chart), tag)
            XCTAssertLessThanOrEqual(monitor.height, height + 0.5, tag)
            XCTAssertGreaterThanOrEqual(chart.width, width - 2 * AppDesignTokens.Spacing.small - 1,
                                        "The chart uses the monitor's full width: \(tag)")
            XCTAssertGreaterThanOrEqual(chart.height, BenchmarkMonitorLayout.minimumChartHeight - 0.5, tag)
        }
    }

    /// U1 029: in the real page container at the default window (1280 x 763.7)
    /// and at 900 x 640, the whole monitor — the dial included — stays above
    /// the fixed status bar before any scrolling, in both languages.
    func testTemperatureDialIsCompleteAboveTheStatusBarAtDefaultAndCompactWindows() async throws {
        let leaderboard = BenchmarkV7LeaderboardStore(
            service: UnavailableBenchmarkV7LeaderboardService(),
            identityProvider: BenchmarkLayoutIdentity()
        )
        // The detail column (AdaptivePageViewport) of each window: the sidebar
        // takes 196 pt and the integrated title bar 52 pt.
        let windows: [(window: String, detail: CGSize)] = [
            ("1280x763.7", CGSize(width: 1_084, height: 711.7)),
            ("900x640", CGSize(width: 704, height: 588)),
            ("1000x700", CGSize(width: 804, height: 648)),
        ]
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = BenchmarkLayoutLanguageScope(language)
            defer { languageScope.restore() }
            for (window, detail) in windows {
                let recorder = BenchmarkLayoutRecorder()
                let root = AdaptivePageViewport(resetID: .performance) {
                    PerformanceBenchmarkPageChrome {
                        BenchmarkV7DashboardView(
                            state: .idle, latestResult: nil, history: [], localBestResult: nil,
                            localBestResultsByCategory: [:], currentScoringVersion: "layout-fixture",
                            historyStatus: .missing, leaderboardStore: leaderboard,
                            preflight: nil, isPreflighting: false, canStart: false,
                            explanation: nil,
                            onStart: { XCTFail("Layout inspection must never start a benchmark") },
                            onCancel: { XCTFail("Layout inspection must not issue a control command") },
                            onDeleteHistoryRecord: { _ in XCTFail("Layout inspection must not edit history") },
                            onExportHistoryRecord: { _ in nil }, liveTelemetry: []
                        )
                    }
                }
                .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: FeatureGroup.performance))
                .environment(\.locale, L10n.locale)
                .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                    Task { @MainActor in recorder.frames = frames }
                }
                let host = BenchmarkLayoutHost(root: root, size: detail)
                defer { host.close() }
                let frames = try await host.frames(from: recorder, required: [
                    LayoutProbeID.pageViewport, "benchmark.monitor", "benchmark.monitor.dial",
                    "benchmark.monitor.chart", "benchmark.persistentActions",
                ])
                let tag = "\(window) \(language)"
                let viewport = try XCTUnwrap(frames[LayoutProbeID.pageViewport])
                let monitor = try XCTUnwrap(frames["benchmark.monitor"])
                let dial = try XCTUnwrap(frames["benchmark.monitor.dial"])
                let chart = try XCTUnwrap(frames["benchmark.monitor.chart"])
                let statusBar = try XCTUnwrap(frames["benchmark.persistentActions"])

                XCTAssertEqual(viewport.width, detail.width, accuracy: 1, tag)
                XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(dial), "Dial inside the page: \(tag)")
                XCTAssertLessThanOrEqual(dial.maxY, statusBar.minY, "The status bar must not cover the dial: \(tag)")
                XCTAssertLessThanOrEqual(monitor.maxY, statusBar.minY, "The whole monitor stays visible: \(tag)")
                XCTAssertGreaterThanOrEqual(chart.minY, dial.maxY - 0.5, tag)
                XCTAssertGreaterThanOrEqual(dial.width, 140, "The dial stays legible: \(tag)")
                // Side by side with the test card: the monitor starts in the
                // first row, not below the card.
                XCTAssertLessThan(monitor.minY, viewport.midY, tag)
            }
        }
    }

    /// Review P2-4: where the dial cannot be on the first screen (a narrow
    /// window stacks the monitor below the test card; a short one has no
    /// room for it), the status bar keeps a compact chip-temperature reading.
    /// Where the whole monitor is visible the reading is not repeated.
    func testNarrowAndShortWindowsKeepACompactTemperatureReading() async throws {
        let windows: [(window: String, detail: CGSize, showsCompact: Bool)] = [
            ("677x764", CGSize(width: 481, height: 712), true),
            ("1280x390", CGSize(width: 1_084, height: 338), true),
            ("1280x763.7", CGSize(width: 1_084, height: 711.7), false),
            ("900x640", CGSize(width: 704, height: 588), false),
        ]
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = BenchmarkLayoutLanguageScope(language)
            defer { languageScope.restore() }
            for (window, detail, showsCompact) in windows {
                for dark in [true, false] {
                    let frames = try await performancePageFrames(
                        state: .idle, detail: detail,
                        required: [LayoutProbeID.pageViewport, "benchmark.persistentActions", "benchmark.monitor"],
                        optional: ["benchmark.compactTemperature"],
                        dark: dark, evidenceName: "idle-\(window)-\(language.rawValue)-\(dark ? "dark" : "light")"
                    )
                    let tag = "\(window) \(language) dark=\(dark)"
                    let viewport = try XCTUnwrap(frames[LayoutProbeID.pageViewport])
                    let statusBar = try XCTUnwrap(frames["benchmark.persistentActions"])
                    if showsCompact {
                        // Not XCTUnwrap: every size is checked (and saved) in one run.
                        XCTAssertNotNil(frames["benchmark.compactTemperature"], "A compact reading: \(tag)")
                        if let reading = frames["benchmark.compactTemperature"] {
                            XCTAssertTrue(statusBar.insetBy(dx: -1, dy: -1).contains(reading), "In the status bar: \(tag)")
                            XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(reading), "On the first screen: \(tag)")
                        }
                    } else {
                        XCTAssertNil(frames["benchmark.compactTemperature"], "The dial is visible: \(tag)")
                    }
                }
            }
        }
    }

    /// Review P2-3: a running test keeps the landing page's arrangement — the
    /// progress takes the test card's place and the monitor keeps its place
    /// and size — so the dial no longer shrinks to about 162 pt below the
    /// progress (the monitor was fixed at 330 pt) when a test starts.
    func testRunningTestKeepsTheLandingMonitorAndDialSize() async throws {
        let running = BenchmarkV7State.phase(.running, sessionID: UUID(), category: .cpu, progress: 0.5)
        let windows: [(window: String, detail: CGSize, minimumDial: CGFloat?)] = [
            ("1280x763.7", CGSize(width: 1_084, height: 711.7), 230),
            ("900x640", CGSize(width: 704, height: 588), 140),
            // Stacked: the monitor is below the progress, the status bar
            // keeps the compact reading.
            ("677x764", CGSize(width: 481, height: 712), nil),
        ]
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = BenchmarkLayoutLanguageScope(language)
            defer { languageScope.restore() }
            for (window, detail, minimumDial) in windows {
                for dark in [true, false] {
                    let frames = try await performancePageFrames(
                        state: running, detail: detail,
                        required: [LayoutProbeID.pageViewport, "benchmark.persistentActions",
                                   "benchmark.monitor", "benchmark.monitor.dial"],
                        optional: ["benchmark.compactTemperature"],
                        dark: dark, evidenceName: "running-\(window)-\(language.rawValue)-\(dark ? "dark" : "light")"
                    )
                    let tag = "\(window) \(language) dark=\(dark)"
                    let viewport = try XCTUnwrap(frames[LayoutProbeID.pageViewport])
                    let statusBar = try XCTUnwrap(frames["benchmark.persistentActions"])
                    let monitor = try XCTUnwrap(frames["benchmark.monitor"])
                    let dial = try XCTUnwrap(frames["benchmark.monitor.dial"])
                    XCTAssertEqual(dial.width, dial.height, accuracy: 1, tag)
                    if let minimumDial {
                        XCTAssertGreaterThanOrEqual(dial.width, minimumDial, "A legible dial: \(tag)")
                        XCTAssertLessThanOrEqual(monitor.maxY, statusBar.minY,
                                                 "The whole monitor stays above the status bar: \(tag)")
                        XCTAssertLessThan(monitor.minY, viewport.midY, "Beside the progress: \(tag)")
                        XCTAssertNil(frames["benchmark.compactTemperature"], "The dial is visible: \(tag)")
                    } else {
                        XCTAssertNotNil(frames["benchmark.compactTemperature"], "A compact reading: \(tag)")
                        if let reading = frames["benchmark.compactTemperature"] {
                            XCTAssertTrue(statusBar.insetBy(dx: -1, dy: -1).contains(reading), tag)
                        }
                    }
                }
            }
        }
    }

    /// Hosts the real performance page container (as MainContentHost does)
    /// at a detail-column size and returns the probed frames.
    private func performancePageFrames(
        state: BenchmarkV7State,
        detail: CGSize,
        required: Set<String>,
        optional: Set<String> = [],
        dark: Bool = true,
        evidenceName: String? = nil
    ) async throws -> [String: CGRect] {
        let leaderboard = BenchmarkV7LeaderboardStore(
            service: UnavailableBenchmarkV7LeaderboardService(),
            identityProvider: BenchmarkLayoutIdentity()
        )
        let recorder = BenchmarkLayoutRecorder()
        let root = MainContentHost(route: .performance, showsIntegratedTitlebar: false) {
            PerformanceBenchmarkPageChrome {
                BenchmarkV7DashboardView(
                    state: state, latestResult: nil, history: [], localBestResult: nil,
                    localBestResultsByCategory: [:], currentScoringVersion: "layout-fixture",
                    historyStatus: .missing, leaderboardStore: leaderboard,
                    preflight: nil, isPreflighting: false, canStart: false,
                    explanation: nil,
                    onStart: { XCTFail("Layout inspection must never start a benchmark") },
                    onCancel: { XCTFail("Layout inspection must not issue a control command") },
                    onDeleteHistoryRecord: { _ in XCTFail("Layout inspection must not edit history") },
                    onExportHistoryRecord: { _ in nil }, liveTelemetry: BenchmarkLayoutTelemetry.points
                )
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, L10n.locale)
        .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
            Task { @MainActor in recorder.frames = frames }
        }
        let host = BenchmarkLayoutHost(root: root, size: detail, dark: dark)
        defer { host.close() }
        let frames = try await host.frames(from: recorder, required: required)
        // Review evidence only: set STORAGE_CLEANER_LAYOUT_EVIDENCE to a
        // scratch directory to save what was measured as PNG files.
        if let evidenceName,
           let directory = ProcessInfo.processInfo.environment["STORAGE_CLEANER_LAYOUT_EVIDENCE"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try host.writePNG(to: folder.appendingPathComponent(evidenceName + ".png"))
        }
        // Optional probes are read from the settled frames as well.
        return recorder.frames.filter { required.contains($0.key) || optional.contains($0.key) }
            .merging(frames) { _, settled in settled }
    }

    func testRealDashboardKeepsIdleAndCancellingActionsInsideShortViewports() async throws {
        let leaderboard = BenchmarkV7LeaderboardStore(
            service: UnavailableBenchmarkV7LeaderboardService(),
            identityProvider: BenchmarkLayoutIdentity()
        )
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = BenchmarkLayoutLanguageScope(language)
            defer { languageScope.restore() }
            for width: CGFloat in [360, 480] {
                for height: CGFloat in [180, 230, 300, 390] {
                    for state in [BenchmarkV7State.idle, .phase(.cancelling, sessionID: UUID())] {
                        let recorder = BenchmarkLayoutRecorder()
                        let root = GeometryReader { proxy in
                            BenchmarkV7DashboardView(
                                state: state, latestResult: nil, history: [], localBestResult: nil,
                                localBestResultsByCategory: [:], currentScoringVersion: "layout-fixture",
                                historyStatus: .missing, leaderboardStore: leaderboard,
                                preflight: nil, isPreflighting: false, canStart: false,
                                explanation: nil,
                                onStart: { XCTFail("Layout inspection must never start a benchmark") },
                                onCancel: { XCTFail("Layout inspection must not issue a control command") },
                                onDeleteHistoryRecord: { _ in XCTFail("Layout inspection must not edit history") },
                                onExportHistoryRecord: { _ in nil }, liveTelemetry: []
                            )
                            .environment(\.windowLayoutMetrics, WindowLayoutMetrics(contentSize: proxy.size))
                            .environment(\.moduleTheme, ModuleThemeCatalog.theme(for: FeatureGroup.performance))
                            .environment(\.locale, L10n.locale)
                            .layoutProbe("benchmark.test.viewport")
                        }
                        .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                            Task { @MainActor in recorder.frames = frames }
                        }
                        let host = BenchmarkLayoutHost(root: root, size: CGSize(width: width, height: height))
                        defer { host.close() }
                        let frames = try await host.frames(from: recorder,
                            required: ["benchmark.persistentActions", "benchmark.persistentStatus",
                                       "benchmark.persistentActionButton", "benchmark.test.viewport"])
                        let actions = try XCTUnwrap(frames["benchmark.persistentActions"])
                        let viewport = try XCTUnwrap(frames["benchmark.test.viewport"])
                        let button = try XCTUnwrap(frames["benchmark.persistentActionButton"])
                        let status = try XCTUnwrap(frames["benchmark.persistentStatus"])
                        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(actions),
                                      "The sole action must stay reachable at \(width)×\(height) pt in \(language)")
                        XCTAssertTrue(actions.insetBy(dx: -1, dy: -1).contains(button))
                        XCTAssertTrue(actions.insetBy(dx: -1, dy: -1).contains(status))
                        XCTAssertGreaterThan(actions.height, 40)
                        if language == .english, state.phase == .idle {
                            XCTAssertGreaterThanOrEqual(button.minY, status.maxY,
                                                        "Long status text must move above the sole action")
                        }
                    }
                }
            }
        }
    }

    func testNativeStagesWrapWithoutClippingOrChangingTheirOrder() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = BenchmarkLayoutLanguageScope(language)
            defer { languageScope.restore() }
            for width: CGFloat in [360, 480] {
                for height: CGFloat in [180, 230] {
                    for phase in [BenchmarkV7Phase.running, .persisting, .cancelling] {
                        let recorder = BenchmarkLayoutRecorder()
                        let view = BenchmarkV7RunProgressView(
                            state: .phase(phase, sessionID: UUID(), category: .cpu, progress: 0.5),
                            isPreflighting: false, accent: MonitorPalette.pink, canCancel: false,
                            onCancel: { XCTFail("Layout inspection must not cancel a workload") }
                        )
                        // Mount the production grid using the same page and card
                        // insets. This checks every stage, independent of scrolling.
                        let root = view.stageGrid
                            .padding(.horizontal, AppDesignTokens.Layout.pagePadding
                                + AppDesignTokens.Layout.sectionPadding)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .environment(\.locale, L10n.locale)
                            .layoutProbe("benchmark.test.stage.viewport")
                            .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                                Task { @MainActor in recorder.frames = frames }
                            }
                        let host = BenchmarkLayoutHost(root: root, size: CGSize(width: width, height: height))
                        defer { host.close() }
                        let stageIDs = (0..<6).map { "benchmark.stage.\($0)" }
                        let frames = try await host.frames(from: recorder,
                            required: Set(stageIDs + ["benchmark.stages", "benchmark.test.stage.viewport"]))
                        let viewport = try XCTUnwrap(frames["benchmark.test.stage.viewport"])
                        let stages = try XCTUnwrap(frames["benchmark.stages"])
                        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(stages))
                        let cells = try stageIDs.map { try XCTUnwrap(frames[$0]) }
                        for cell in cells {
                            XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(cell))
                            XCTAssertTrue(stages.insetBy(dx: -1, dy: -1).contains(cell))
                            XCTAssertGreaterThanOrEqual(cell.width, 58 - 1)
                        }
                        for pair in zip(cells, cells.dropFirst()) {
                            let sameRow = abs(pair.0.midY - pair.1.midY) < 10
                            XCTAssertTrue(sameRow ? pair.1.minX > pair.0.minX
                                                  : pair.1.midY > pair.0.midY,
                                          "Stages must retain their original reading order")
                        }
                        if width == 360 {
                            XCTAssertGreaterThan(cells[5].midY, cells[0].midY + 10)
                        } else {
                            XCTAssertEqual(cells[5].midY, cells[0].midY, accuracy: 10)
                        }
                    }
                }
            }
        }
    }

    func testTemperatureLabelsPreserveRealZeroAndRejectNonFiniteValues() {
        XCTAssertEqual(BenchmarkSystemMonitor.temperatureText(0), "0°C")
        XCTAssertEqual(BenchmarkSystemMonitor.temperatureText(72.6), "73°C")
        XCTAssertEqual(BenchmarkSystemMonitor.temperatureText(122), "122°C")
        for invalid in [nil, Double.nan, Double.infinity, -Double.infinity] as [Double?] {
            XCTAssertEqual(BenchmarkSystemMonitor.temperatureText(invalid), "—")
        }
    }
}

/// Override only this test process's volatile argument domain. The real App's
/// saved preferences and its persistent defaults domain are never changed.
@MainActor
private final class BenchmarkLayoutLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(L10n.appLanguage, language)
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification,
                                        object: UserDefaults.standard)
    }
}

@MainActor
private final class BenchmarkLayoutRecorder {
    var frames: [String: CGRect] = [:]
}

@MainActor
private final class BenchmarkLayoutHost<Root: View> {
    private let host: NSHostingView<Root>
    private let window: NSWindow

    init(root: Root, size: CGSize, dark: Bool = false) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: root)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
    }

    /// Off-screen evidence only (STORAGE_CLEANER_LAYOUT_EVIDENCE); never the
    /// app's own window.
    func writePNG(to url: URL) throws {
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    func frames(from recorder: BenchmarkLayoutRecorder,
                required: Set<String>) async throws -> [String: CGRect] {
        var lastFrames: [String: CGRect]?
        var stable = 0
        for _ in 0..<100 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            if required.isSubset(of: Set(recorder.frames.keys)) {
                let current = recorder.frames.filter { required.contains($0.key) }
                if current == lastFrames { stable += 1 } else { stable = 0 }
                lastFrames = current
                if stable >= 2 { return current }
            }
        }
        throw NSError(domain: "BenchmarkMonitorLayoutTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Native layout frames did not stabilize"])
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class BenchmarkLayoutIdentity: BenchmarkV7LeaderboardIdentityProviding {
    func installationID() -> UUID { UUID(uuidString: "A067E670-44B1-4D8F-8F56-76B2C939038A")! }
    func anonymousDisplayName() -> String { "LAYOUT FIXTURE" }
    func remember(_ identity: BenchmarkV7LeaderboardSubmittedIdentity) { XCTFail("No identity writes in layout tests") }
    func forgetSubmittedEntry() { XCTFail("No identity writes in layout tests") }
    func lastSubmittedIdentity() -> BenchmarkV7LeaderboardSubmittedIdentity? { nil }
}

/// Two minutes of fixed samples, ending when first read, so the dial, gauges,
/// chart and the compact reading show values in layout tests and evidence.
private enum BenchmarkLayoutTelemetry {
    static let points: [MenuBarTelemetryPoint] = {
        let end = Date()
        return (0..<24).map { point(at: $0, end: end) }
    }()

    private static func point(at index: Int, end: Date) -> MenuBarTelemetryPoint {
        let step = Double(index)
        let cpu: Double = 20 + Double(index % 6) * 9
        let gpu: Double = 8 + Double(index % 4) * 6
        let temperature: Double = 58 + Double(index % 5)
        return MenuBarTelemetryPoint(
            date: end.addingTimeInterval((step - 23) * 5),
            cpuTotal: cpu, cpuUser: nil, cpuSystem: nil,
            gpu: gpu, memory: 52,
            chipTemperature: temperature,
            fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil
        )
    }
}
#endif
