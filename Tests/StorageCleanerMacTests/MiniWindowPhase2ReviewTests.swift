import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Batch r2-mini-speed, review of phase 2: the sensors pages read the summary
/// prepared with their window and only that window is summarized; the
/// windows kept while hidden (D39) are released by memory pressure only while
/// nothing is shown and survive the panel's reclamation; the level-one cards
/// dim a kept window.
@MainActor
final class MiniWindowPhase2ReviewTests: XCTestCase {
    // MARK: - Review P2-1: the summary prepared with the window

    /// The page reads the summary prepared with its window off the main
    /// thread. A prepared summary that differs from one computed from the
    /// points tells the two apart (review: the page was changed to always
    /// compute it from the points and every related test still passed).
    func testTheSensorsPageReadsTheSummaryPreparedWithItsWindow() async throws {
        let page = try Page(for: self, section: .sensors)
        defer { page.tearDown() }
        let monitor = page.store.menuBarMonitorState
        let prepared = MenuBarTelemetryWindowSummary(points: Self.fanPoints(rpm: 9_876))
        monitor.windowSummary = { _ in prepared }
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.setDisplayHistoryDemand(page.view.historyDemandPlan.durations)
        try await wait { monitor.displayTelemetryVersion > 0 }

        let displayed = page.view.selectedDisplayedHistory
        XCTAssertFalse(displayed.points.isEmpty)
        XCTAssertNotEqual(MenuBarTelemetryWindowSummary(points: displayed.points), prepared,
                          "the summary computed from the points differs from the prepared one")
        XCTAssertEqual(page.view.historySummary, prepared, "the page reads the summary prepared with the window")
        XCTAssertEqual(page.view.fanTrendMaximum, prepared.fanTrendMaximum, "and so does the fan scale")
    }

    /// Only the window whose summary is read (each consumer's most visible
    /// window: the open history's or the page's range) is summarized; the
    /// CPU and network cards' windows are only drawn.
    func testOnlyEachConsumersMostVisibleWindowIsSummarized() async throws {
        let monitor = MenuBarMonitorState()
        let page = UUID()
        let other = UUID()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.updateDisplayHistoryConsumer(page, durations: [86_400, 3_600])
        monitor.updateDisplayHistoryConsumer(other, durations: [604_800])
        try await wait { monitor.displayTelemetryVersion > 0 }

        let pageWindow = monitor.displayHistorySlice(slot: "page", within: 86_400)
        XCTAssertFalse(pageWindow.points.isEmpty)
        XCTAssertEqual(pageWindow.summary, MenuBarTelemetryWindowSummary(points: pageWindow.points))
        XCTAssertNil(monitor.displayHistorySlice(slot: "card", within: 3_600).summary, "a card's window is only drawn")
        let otherWindow = monitor.displayHistorySlice(slot: "other", within: 604_800)
        XCTAssertEqual(otherWindow.summary, MenuBarTelemetryWindowSummary(points: otherWindow.points))

        // The same windows in another order: the window that became the most
        // visible is summarized with the next preparation.
        let version = monitor.displayTelemetryVersion
        monitor.updateDisplayHistoryConsumer(page, durations: [3_600, 86_400])
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        try await wait { monitor.displayTelemetryVersion > version }
        let reordered = monitor.displayHistorySlice(slot: "card", within: 3_600)
        XCTAssertEqual(reordered.summary, MenuBarTelemetryWindowSummary(points: reordered.points))
        XCTAssertNil(monitor.displayHistorySlice(slot: "page", within: 86_400).summary)
    }

    // MARK: - D39: release under memory pressure, survival across reclamation

    /// Memory pressure releases the kept windows only while nothing is
    /// shown; the next opening prepares its windows as before D39.
    func testMemoryPressureReleasesTheKeptWindowsOnlyWhileNothingIsShown() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.setDisplayHistoryDemand([3_600, 86_400])
        try await wait { monitor.displayTelemetryVersion > 0 }
        let shown = monitor.displayHistory(within: 3_600)
        XCTAssertFalse(shown.isEmpty)

        monitor.releaseKeptDisplayHistory()
        XCTAssertEqual(monitor.displayHistory(within: 3_600), shown, "the windows on screen are not released")
        XCTAssertFalse(monitor.displayHistorySlice(slot: "page", within: 3_600).isUpdating)

        monitor.setDisplayHistoryDemand([])
        XCTAssertTrue(monitor.displayHistorySlice(slot: "page", within: 3_600).isUpdating, "hidden: kept (D39)")
        XCTAssertGreaterThan(monitor.retainedDisplayHistoryBytes().arrayBytes, 0)

        monitor.releaseKeptDisplayHistory()
        XCTAssertTrue(monitor.displayHistory(within: 3_600).isEmpty)
        XCTAssertTrue(monitor.displayHistory(within: 86_400).isEmpty)
        XCTAssertTrue(monitor.displayHistory(within: 3_600, memory: true).isEmpty)
        let released = monitor.displayHistorySlice(slot: "page", within: 3_600)
        XCTAssertTrue(released.points.isEmpty)
        XCTAssertFalse(released.isUpdating, "nothing is drawn as updating once released")
        XCTAssertNil(released.summary)
        XCTAssertEqual(monitor.retainedDisplayHistoryBytes(), MenuBarDisplayHistoryFootprint())

        let version = monitor.displayTelemetryVersion
        monitor.setDisplayHistoryDemand([3_600])
        try await wait { monitor.displayTelemetryVersion > version }
        let reopened = monitor.displayHistorySlice(slot: "page", within: 3_600)
        XCTAssertFalse(reopened.points.isEmpty)
        XCTAssertFalse(reopened.isUpdating)
    }

    /// D39 supplement (2026-10-05): reclaiming the hidden panel after five
    /// minutes tears it down but keeps the windows, so that the opening after
    /// it still shows them at once. Only memory pressure releases them.
    func testReclaimingTheHiddenPanelKeepsTheWindows() async throws {
        let monitor = MenuBarMonitorState()
        let root = UUID()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.updateDisplayHistoryConsumer(root, durations: [3_600, 86_400])
        try await wait { monitor.displayTelemetryVersion > 0 }
        let shown = monitor.displayHistory(within: 3_600)
        let version = monitor.displayTelemetryVersion

        // Hidden: the root view withdraws its demand. Torn down five minutes
        // later: the view is gone and withdraws again.
        monitor.updateDisplayHistoryConsumer(root, durations: [])
        monitor.updateDisplayHistoryConsumer(root, durations: [])
        XCTAssertEqual(monitor.displayHistory(within: 3_600), shown)
        XCTAssertFalse(monitor.displayHistory(within: 86_400).isEmpty)
        XCTAssertTrue(monitor.displayHistorySlice(slot: "page", within: 3_600).isUpdating)

        // A new root view after reclamation draws the kept window at once.
        let rebuilt = UUID()
        monitor.updateDisplayHistoryConsumer(rebuilt, durations: [3_600])
        let first = monitor.displayHistorySlice(slot: "page", within: 3_600)
        XCTAssertEqual(first.points, shown)
        XCTAssertTrue(first.isUpdating)
        try await wait { monitor.displayTelemetryVersion > version }
        XCTAssertFalse(monitor.displayHistorySlice(slot: "page", within: 3_600).isUpdating)

        // The memory-pressure handler is the only caller of the release;
        // neither the reclamation nor the session's teardown calls it.
        let controller = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Support/MenuBarStatusController.swift")
        let pressure = try MiniWindowLogicFixtures.section(
            controller, from: "DispatchSource.makeMemoryPressureSource", to: "panelMemoryPressureSource = pressure")
        XCTAssertTrue(pressure.contains("menuBarMonitorState.releaseKeptDisplayHistory()"))
        let callers = try Self.sourceFiles().filter { _, text in
            text.replacingOccurrences(of: "func releaseKeptDisplayHistory()", with: "")
                .contains("releaseKeptDisplayHistory()")
        }
        XCTAssertEqual(callers.map(\.path), ["Sources/StorageCleanerMac/Support/MenuBarStatusController.swift"])
        XCTAssertEqual(controller.components(separatedBy: "releaseKeptDisplayHistory()").count - 1, 1)
    }

    // MARK: - D39: the level-one cards dim a kept window

    /// After the panel is hidden the CPU and network cards would draw the
    /// kept window as it was, including the unrecorded time since: they are
    /// dimmed as history plots are (D32) until it is replaced.
    func testTheLevelOneCardsDimAKeptWindow() async throws {
        let page = try Page(for: self, section: .overview)
        defer { page.tearDown() }
        let monitor = page.store.menuBarMonitorState
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.setDisplayHistoryDemand(page.view.historyDemandPlan.durations)
        try await wait { monitor.displayTelemetryVersion > 0 }
        XCTAssertEqual(Self.isUpdating(page.view.geekProcessorCard), false)
        XCTAssertEqual(Self.isUpdating(page.view.geekNetworkCard), false)

        monitor.setDisplayHistoryDemand([])
        XCTAssertTrue(page.view.cpuDisplayedHistory.isUpdating)
        XCTAssertFalse(page.view.cpuDisplayedHistory.points.isEmpty)
        XCTAssertEqual(Self.isUpdating(page.view.geekProcessorCard), true, "the CPU card dims a kept window")
        XCTAssertEqual(Self.isUpdating(page.view.geekNetworkCard), true, "so does the network card")

        let version = monitor.displayTelemetryVersion
        monitor.setDisplayHistoryDemand(page.view.historyDemandPlan.durations)
        try await wait { monitor.displayTelemetryVersion > version }
        XCTAssertEqual(Self.isUpdating(page.view.geekProcessorCard), false, "replaced: drawn as usual")
    }

    /// Only the chart is dimmed: the header with the total and the legend
    /// below the chart are drawn the same.
    func testOnlyTheChartOfTheCPUCardIsDimmed() throws {
        let width = MiniWindowStyleTokens.overviewSize.width - 2 * MiniWindowStyleTokens.contentInset
        let scale: CGFloat = 2
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clock = PanelChartClock(anchor: .init(wallDate: now, instant: ContinuousClock().now))
        let history = (0..<60).map { index in
            MenuBarTelemetryPoint(
                date: now.addingTimeInterval(-Double(59 - index) * 60), cpuTotal: 90, cpuUser: 60, cpuSystem: 30,
                gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil)
        }
        func render(_ isUpdating: Bool) throws -> NSBitmapImageRep {
            let card = GeekProcessorPresentation(
                cpuChartHistory: history, cpuChartRange: .oneHour, samplingInterval: 60,
                processorTint: .green, geekCPUUserBarColor: .blue, geekCPUSystemBarColor: .pink,
                isUpdating: isUpdating)
                .frame(width: width)
                .environment(\.colorScheme, .light)
                .environment(\.panelChartClock, clock)
                .environment(\.displayScale, scale)
            let renderer = ImageRenderer(content: card)
            renderer.scale = scale
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        let current = try render(false)
        let dimmed = try render(true)
        XCTAssertEqual(current.pixelsWide, dimmed.pixelsWide)
        XCTAssertEqual(current.pixelsHigh, dimmed.pixelsHigh)
        let changedRows = (0..<current.pixelsHigh).filter { y in
            (0..<current.pixelsWide).contains { x in
                guard let a = current.colorAt(x: x, y: y), let b = dimmed.colorAt(x: x, y: y) else { return false }
                return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) > 0.03
            }
        }
        let first = try XCTUnwrap(changedRows.first, "the chart is drawn differently when dimmed")
        let last = try XCTUnwrap(changedRows.last)
        XCTAssertLessThanOrEqual(CGFloat(last - first + 1), (GeekPanelLayout.overviewProcessorChartHeight + 1) * scale,
                                 "only rows of the chart change (rows \(first)–\(last))")
        // The chart sits below the header (title and total).
        XCTAssertGreaterThan(CGFloat(first), 12 * scale, "the header is not dimmed")
    }

    // MARK: - Helpers

    private struct Page {
        let view: MenuBarAdvancedStatusView
        let store: ScanStore
        let defaults: UserDefaults
        let suiteName: String

        @MainActor
        init(for testCase: XCTestCase, section: PanelSection) throws {
            suiteName = TestPreferenceDomain.makeSuite()
            defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
            store = try ScanStore.makeForTests(for: testCase, cleanupPreferences: defaults, cleanReportLoader: { [] })
            view = MenuBarAdvancedStatusView(
                store: store,
                computerHealthStore: ComputerHealthStore(probe: UnusedHealthProbe(), batteryPowerModeController: TestOperationFactory(for: testCase).batteryPowerModeController()),
                panelSettingsState: MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults),
                initialSection: section,
                fanControl: FanControlCoordinator(
                    defaults: defaults,
                    helperStatusOverride: .unavailable,
                    requestSender: { _ in throw CancellationError() }
                )
            )
        }

        func tearDown() {
            TestPreferenceDomain.cleanup(suiteName: suiteName)
        }
    }

    private static func isUpdating<V: View>(_ view: V) -> Bool? {
        Mirror(reflecting: view).children.first { $0.label == "isUpdating" }?.value as? Bool
    }

    private static func fanPoints(rpm: Double) -> [MenuBarTelemetryPoint] {
        let now = Date()
        return (0..<4).map { index in
            MenuBarTelemetryPoint(
                date: now.addingTimeInterval(Double(index - 4) * 60), cpuTotal: 10, cpuUser: 7, cpuSystem: 3,
                gpu: nil, memory: 40, chipTemperature: nil, gpuTemperature: nil,
                fanRPM: rpm, fanTargetRPM: rpm, downBytesPerSecond: 1, upBytesPerSecond: 1)
        }
    }

    private static func sourceFiles(file: StaticString = #filePath) throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [(path: String, text: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return files.sorted { $0.path < $1.path }
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not met")
    }
}

private struct UnusedHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        throw CancellationError()
    }
}
