import XCTest
@testable import StorageCleanerMac

/// The monitor prepares at most four history windows for display. Asking for
/// more used to keep the four shortest ones, whatever was on screen, and to
/// rebuild everything on every request because the unchanged request was
/// compared with its own truncated copy. The demand is now ordered by what is
/// most visible, truncated in that order, and compared after truncation.
@MainActor
final class MiniWindowHistoryDemandTests: XCTestCase {
    func testAnOversizedDemandIsNotRebuiltWhenItIsRequestedAgain() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(Self.points())
        monitor.setDisplayHistoryDemand([30, 60, 300, 600, 900, 3_600])
        try await waitForPreparation(monitor)
        let version = monitor.displayTelemetryVersion
        XCTAssertGreaterThan(version, 0)

        for _ in 0..<5 {
            monitor.setDisplayHistoryDemand([30, 60, 300, 600, 900, 3_600])
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(monitor.displayTelemetryVersion, version,
                       "the same request must not cancel and prepare every window again")

        // The same through the consumer registration the panel uses.
        let consumer = UUID()
        monitor.updateDisplayHistoryConsumer(consumer, durations: [30, 60, 300, 600, 900, 3_600])
        try await Task.sleep(for: .milliseconds(40))
        let registered = monitor.displayTelemetryVersion
        for _ in 0..<5 {
            monitor.updateDisplayHistoryConsumer(consumer, durations: [30, 60, 300, 600, 900, 3_600])
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(monitor.displayTelemetryVersion, registered)
    }

    func testAnOversizedDemandKeepsTheMostVisibleWindows() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(Self.points())
        // Visible priority: the open one-day history, the CPU and network
        // cards, then three more windows.
        monitor.setDisplayHistoryDemand([86_400, 3_600, 60, 300, 900, 600])
        try await waitForPreparation(monitor)

        XCTAssertFalse(monitor.displayHistory(within: 86_400).isEmpty,
                       "the open history is the first to be prepared, not the first to be dropped for being long")
        for duration: TimeInterval in [3_600, 60, 300] {
            XCTAssertFalse(monitor.displayHistory(within: duration).isEmpty, "\(duration)")
        }
        for duration: TimeInterval in [900, 600] {
            XCTAssertTrue(monitor.displayHistory(within: duration).isEmpty, "\(duration) is beyond the limit")
        }
        XCTAssertEqual(monitor.droppedDisplayDurations, [900, 600], "the dropped windows are recorded, not silent")
        XCTAssertEqual(MenuBarMonitorState.maximumDisplayDurationCount, 4)

        // A request that fits clears the record.
        monitor.setDisplayHistoryDemand([86_400, 3_600])
        XCTAssertEqual(monitor.droppedDisplayDurations, [])
    }

    func testWindowsAreChosenByRankAcrossConsumersWithoutDuplicates() {
        typealias Monitor = MenuBarMonitorState
        var selection = Monitor.selectDisplayDurations([[3_600, 60, 300], [86_400, 900, 600]])
        XCTAssertEqual(selection.kept, [3_600, 86_400, 60, 900], "every consumer's most visible window comes first")
        XCTAssertEqual(selection.dropped, [300, 600])

        selection = Monitor.selectDisplayDurations([[3_600, 3_600, 60], [3_600, 60, 300]])
        XCTAssertEqual(selection.kept, [3_600, 60, 300])
        XCTAssertEqual(selection.dropped, [])

        selection = Monitor.selectDisplayDurations([[.nan, -5, 0, .infinity, 120]])
        XCTAssertEqual(selection.kept, [120], "only finite positive windows are requests")
        XCTAssertEqual(Monitor.selectDisplayDurations([]).kept, [])
        XCTAssertEqual(Monitor.selectDisplayDurations([[1, 2, 3]], limit: 2).dropped, [3])
    }

    func testRemovingAConsumerRestoresTheWindowsItCrowdedOut() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(Self.points())
        let first = UUID(), second = UUID()
        monitor.updateDisplayHistoryConsumer(first, durations: [3_600, 60, 300])
        monitor.updateDisplayHistoryConsumer(second, durations: [86_400, 900, 600])
        XCTAssertEqual(monitor.droppedDisplayDurations, [300, 600])
        monitor.updateDisplayHistoryConsumer(second, durations: [])
        XCTAssertEqual(monitor.droppedDisplayDurations, [])
        try await waitForPreparation(monitor, until: { !$0.displayHistory(within: 300).isEmpty })
        XCTAssertFalse(monitor.displayHistory(within: 300).isEmpty)
        // Updating keeps a consumer's place: the first one still outranks a
        // consumer registered later.
        monitor.updateDisplayHistoryConsumer(second, durations: [86_400, 900, 600])
        monitor.updateDisplayHistoryConsumer(first, durations: [1_800, 60, 300])
        XCTAssertEqual(monitor.droppedDisplayDurations, [300, 600])
        try await waitForPreparation(monitor, until: { !$0.displayHistory(within: 1_800).isEmpty })
        XCTAssertFalse(monitor.displayHistory(within: 1_800).isEmpty)
    }

    // MARK: - First review, P2-1

    /// A memory history opened by route (`.history(.builtIn("memory"))`, the
    /// live-audit capture and the legacy button) has no inline request, so its
    /// label and picker use the page's range. Its points were read with the
    /// memory metric's range instead, which was not part of the demand once an
    /// inline history had set a different range: the chart stayed empty.
    func testARoutedMemoryHistoryReadsAWindowThatIsPrepared() async throws {
        let suiteName = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        defer { TestPreferenceDomain.cleanup(suiteName: suiteName) }
        let settings = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        // An inline memory history was switched to one day earlier.
        settings.setGeekChartRange(.oneDay, for: GeekChartRangeMetric.memory)
        XCTAssertEqual(settings.geekChartRange(for: PanelSection.memory), .oneHour, "the page's own range is unchanged")

        let routed = MenuBarHistoryDemandPlan(settings: settings, section: .memory, inlineMetric: nil)
        XCTAssertEqual(routed.selectedRange, .oneHour)
        XCTAssertEqual(routed.routedMemoryRange, routed.selectedRange,
                       "the points use the range the label and the picker show")
        XCTAssertTrue(routed.durations.contains(routed.routedMemoryRange.duration),
                      "the window the routed memory history reads is prepared")

        // An inline memory history reads the memory metric's own range
        // (`metricDisplayedHistory(.memory)`), which is the selected one, and
        // so part of the demand, while it is open.
        let inline = MenuBarHistoryDemandPlan(settings: settings, section: .memory, inlineMetric: .memory)
        XCTAssertEqual(inline.selectedRange, .oneDay)
        XCTAssertEqual(settings.geekChartRange(for: GeekChartRangeMetric.memory, fallbackTo: .memory), inline.selectedRange)
        XCTAssertTrue(inline.durations.contains(inline.selectedRange.duration))

        // End to end with the monitor: the routed history has data.
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory([], memoryPoints: Self.points())
        monitor.setDisplayHistoryDemand(routed.durations)
        try await waitForPreparation(monitor, until: { $0.displayMemoryVersion > 0 })
        XCTAssertFalse(monitor.displayHistory(within: routed.routedMemoryRange.duration, memory: true).isEmpty)

        // The view reads the routed history's points and window from that range.
        let root = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(root.contains(
            "displayedHistory(slot: \"route.memory\", range: historyDemandPlan.routedMemoryRange, memory: true)"))
        let view = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let detail = try MiniWindowLogicFixtures.section(
            view, from: "private var tertiaryMemoryDetail: some View {", to: "private var tertiaryDiskDetail")
        XCTAssertTrue(detail.contains("let memoryHistory = routedMemoryDisplayedHistory"))
        XCTAssertTrue(detail.contains("points: memoryHistory.points"))
        XCTAssertTrue(detail.contains("duration: memoryHistory.range.duration"))
    }

    func testDemandIsOrderedByWhatIsVisible() throws {
        let suiteName = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        defer { TestPreferenceDomain.cleanup(suiteName: suiteName) }
        let settings = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        settings.setGeekChartRange(.sevenDays, for: GeekChartRangeMetric.fan)
        settings.setGeekChartRange(.fiveMinutes, for: GeekChartRangeMetric.cpu)
        settings.setGeekChartRange(.oneMinute, for: GeekChartRangeMetric.network)

        let fanHistory = MenuBarHistoryDemandPlan(settings: settings, section: .sensors, inlineMetric: .fan)
        XCTAssertEqual(fanHistory.durations, [604_800, 300, 60], "open history, CPU card, network card")
        let overview = MenuBarHistoryDemandPlan(settings: settings, section: .overview, inlineMetric: nil)
        XCTAssertEqual(overview.durations, [3_600, 300, 60])
        // Equal ranges are one window.
        settings.setGeekChartRange(.oneHour, for: GeekChartRangeMetric.cpu)
        settings.setGeekChartRange(.oneHour, for: GeekChartRangeMetric.network)
        XCTAssertEqual(MenuBarHistoryDemandPlan(settings: settings, section: .overview, inlineMetric: nil).durations, [3_600])
    }

    // MARK: - Helpers

    private func waitForPreparation(
        _ monitor: MenuBarMonitorState,
        until ready: (MenuBarMonitorState) -> Bool = { $0.displayTelemetryVersion > 0 }
    ) async throws {
        for _ in 0..<400 where !ready(monitor) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(ready(monitor), "the display history was not prepared in time")
        // Let a preparation that was already scheduled finish.
        try await Task.sleep(for: .milliseconds(30))
    }

    /// One sample every 30 s for 26 hours, ending now.
    static func points(now: Date = Date()) -> [MenuBarTelemetryPoint] {
        (0..<3_120).map { index in
            MenuBarTelemetryPoint(
                date: now.addingTimeInterval(-Double(3_119 - index) * 30),
                cpuTotal: 40, cpuUser: 30, cpuSystem: 10, gpu: 20, memory: 50,
                memoryPressure: 30,
                chipTemperature: 45, fanRPM: 1_500, downBytesPerSecond: 100, upBytesPerSecond: 50
            )
        }
    }
}
