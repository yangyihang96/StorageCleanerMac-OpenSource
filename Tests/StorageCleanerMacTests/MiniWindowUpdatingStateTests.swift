import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Review of batch 4b, P2-3, P2-4, P2-5: a history shows "更新中…" (dimmed
/// chart, axis row label) exactly while it draws something other than the
/// selected window:
/// - the window it reads is still the previous one (`MenuBarDisplayedHistory
///   .isUpdating`, passed explicitly, not inferred from the environment), or
/// - its prepared frame is still the previous window's frame while the new
///   one is built (`MenuBarPreparedChartModel.isShowingPreviousValue`).
/// Routed disk and power histories read their own stores with the selected
/// range and never follow the telemetry window.
@MainActor
final class MiniWindowUpdatingStateTests: XCTestCase {
    // MARK: - P2-3: the prepared frame

    func testThePreparedModelSaysWhenItShowsThePreviousWindowsFrame() async throws {
        func key(_ configuration: String, revision: Int = 0) -> MenuBarDerivedKey {
            .init(page: "memory", kind: "line-frame", revision: String(revision), configuration: configuration)
        }
        let model = MenuBarPreparedChartModel<Int>(cache: MenuBarDerivedCache())
        model.request(key: key("pressure:360x140:3600"), shape: "pressure:360x140", cost: 8) { 1 }
        try await wait { model.value == 1 }
        XCTAssertFalse(model.isShowingPreviousValue)

        // Another window of the same chart: the previous frame stays, marked.
        model.request(key: key("pressure:360x140:86400"), shape: "pressure:360x140", cost: 8) {
            Thread.sleep(forTimeInterval: 0.05)
            return 24
        }
        XCTAssertEqual(model.value, 1)
        XCTAssertTrue(model.isShowingPreviousValue, "the frame on screen belongs to the previous window")
        try await wait { model.value == 24 }
        XCTAssertFalse(model.isShowingPreviousValue, "cleared when the new window's frame is delivered")

        // A new sample of the same window is not an update of the range.
        model.request(key: key("pressure:360x140:86400", revision: 1), shape: "pressure:360x140", cost: 8) {
            Thread.sleep(forTimeInterval: 0.05)
            return 25
        }
        XCTAssertFalse(model.isShowingPreviousValue)
        try await wait { model.value == 25 }

        // A frame of another shape is cleared at once: nothing old is shown.
        model.request(key: key("pressure:300x140:3600"), shape: "pressure:300x140", cost: 8) {
            Thread.sleep(forTimeInterval: 0.05)
            return 3
        }
        XCTAssertNil(model.value)
        XCTAssertFalse(model.isShowingPreviousValue)
        try await wait { model.value == 3 }
        model.stop()
    }

    func testThePlotBlockJoinsBothSourcesOfTheUpdatingState() throws {
        XCTAssertFalse(GeekHistoryPlotBlock<EmptyView>.showsUpdating(historyIsUpdating: false, isShowingPreviousFrame: false))
        XCTAssertTrue(GeekHistoryPlotBlock<EmptyView>.showsUpdating(historyIsUpdating: true, isShowingPreviousFrame: false))
        XCTAssertTrue(GeekHistoryPlotBlock<EmptyView>.showsUpdating(historyIsUpdating: false, isShowingPreviousFrame: true))

        // The frame's state reaches the block from inside the chart.
        let charts = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        let block = try MiniWindowLogicFixtures.section(
            charts, from: "struct GeekHistoryPlotBlock<Chart: View>: View {", to: "/// Legend swatch for an unrecorded period")
        XCTAssertTrue(block.contains(".onPreferenceChange(GeekHistoryPreviousFrameKey.self)"))
        let prepared = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarPreparedChart.swift")
        XCTAssertTrue(prepared.contains(".preference(key: GeekHistoryPreviousFrameKey.self, value: model.isShowingPreviousValue)"))
    }

    /// End to end in a window: a chart that reports a previous frame dims and
    /// the axis row says so after the preference reached the block.
    func testAChartThatShowsAPreviousFrameIsDimmed() async throws {
        let shown = try await renderedChartAlpha(
            GeekHistoryPlotBlock(
                chart: Color.red.preference(key: GeekHistoryPreviousFrameKey.self, value: true),
                footer: GeekHistoryAxisFooter(duration: 3_600)
            )
        )
        XCTAssertEqual(shown, GeekHistoryPlotBlock<EmptyView>.updatingOpacity, accuracy: 0.08)
        let current = try await renderedChartAlpha(
            GeekHistoryPlotBlock(
                chart: Color.red.preference(key: GeekHistoryPreviousFrameKey.self, value: false),
                footer: GeekHistoryAxisFooter(duration: 3_600)
            )
        )
        XCTAssertEqual(current, 1, accuracy: 0.05)
    }

    // MARK: - P2-4: explicit, not inferred

    /// The environment's selected range no longer decides: a window unlike
    /// it is not "updating" unless the history says so.
    func testOnlyTheExplicitStateDimsTheChart() async throws {
        // Before: the block compared the footer's window with the
        // environment's selected range (default one hour).
        let differentWindow = try await renderedChartAlpha(
            GeekHistoryPlotBlock(chart: Color.red, footer: GeekHistoryAxisFooter(duration: 86_400))
        )
        XCTAssertEqual(differentWindow, 1, accuracy: 0.05, "a one-day history is not dimmed for not being one hour")
        let explicit = try await renderedChartAlpha(
            GeekHistoryPlotBlock(chart: Color.red, footer: GeekHistoryAxisFooter(duration: 3_600, isUpdating: true))
        )
        XCTAssertEqual(explicit, GeekHistoryPlotBlock<EmptyView>.updatingOpacity, accuracy: 0.08)

        let charts = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        let block = try MiniWindowLogicFixtures.section(
            charts, from: "struct GeekHistoryPlotBlock<Chart: View>: View {", to: "/// Legend swatch for an unrecorded period")
        XCTAssertFalse(block.contains("geekChartRangeSelection"), "no inference from the environment")
    }

    /// Every live history passes the state of the slice it draws.
    func testLiveHistoriesPassTheirSlicesUpdatingState() throws {
        let processor = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift")
        XCTAssertTrue(processor.contains("isUpdating: cpuDisplayedHistory.isUpdating"))
        XCTAssertTrue(processor.contains("isUpdating: geekMetricIsUpdating(.gpu)"))
        let network = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekNetworkView.swift")
        XCTAssertTrue(network.contains("isUpdating: networkDisplayedHistory.isUpdating"))
        let memory = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        XCTAssertEqual(memory.components(separatedBy: "isUpdating: geekMetricIsUpdating(.memory)").count - 1, 3,
                       "memory history, composition and swap")
        let sensors = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        XCTAssertTrue(sensors.contains("isUpdating: geekMetricIsUpdating(.temperature)"))
        XCTAssertTrue(sensors.contains("isUpdating: geekMetricIsUpdating(.fan)"))
        let tertiary = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        XCTAssertTrue(tertiary.contains("isUpdating: memoryHistory.isUpdating"))
        XCTAssertTrue(tertiary.contains("isUpdating: geekTelemetryChartIsUpdating"))
    }

    // MARK: - P2-5: routed disk and power

    func testRoutedDiskAndPowerHistoriesUseTheSelectedRange() throws {
        let panel = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        XCTAssertTrue(panel.contains("var geekChartDuration: TimeInterval {\n        selectedChartRange.duration"),
                      "disk and power histories read their own stores with the selected range")
        XCTAssertTrue(panel.contains("var geekChartRangeTitle: String {\n        selectedChartRange.title"))
        XCTAssertTrue(panel.contains("var geekTelemetryChartDuration: TimeInterval {\n        selectedDisplayedHistory.range.duration"))
        XCTAssertTrue(panel.contains("var geekTelemetryChartIsUpdating: Bool {\n        selectedDisplayedHistory.isUpdating"))

        let tertiary = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let disk = try MiniWindowLogicFixtures.section(
            tertiary, from: "private var tertiaryDiskDetail: some View {", to: "private var tertiaryNetworkDetail")
        XCTAssertTrue(disk.contains("duration: geekChartDuration"))
        XCTAssertFalse(disk.contains("isUpdating"), "the disk store is not a telemetry window")
        let processor = try MiniWindowLogicFixtures.section(
            tertiary, from: "private var tertiaryProcessorDetail: some View {", to: "private var tertiaryMemoryDetail")
        XCTAssertTrue(processor.contains("duration: geekTelemetryChartDuration"),
                      "telemetry points and their window come from the same slice")
    }

    // MARK: - Helpers

    /// Hosts `view` in a window, lets SwiftUI deliver preferences, and
    /// returns the alpha of the chart's center.
    private func renderedChartAlpha<V: View>(_ view: V) async throws -> CGFloat {
        let size = CGSize(width: 120, height: MiniWindowStyleTokens.historyPlotHeight)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // The chart area is the top 140 pt; sample its middle.
        let x = rep.pixelsWide / 2
        let y = Int(CGFloat(rep.pixelsHigh) * (MiniWindowStyleTokens.historyChartHeight / 2) / size.height)
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y))
        return color.alphaComponent
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "the condition was not reached in time")
    }
}
