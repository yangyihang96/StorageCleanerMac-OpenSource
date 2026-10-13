import Combine
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Switching a history's time range emptied the chart until the new window
/// was prepared: the monitor dropped the previous window at once, the chart
/// frame was cleared when its configuration changed, and the card hosting the
/// fan history did not redraw when the new window arrived (1-4 s in the fan
/// history). The previous window now stays on screen, marked as updating,
/// until the new one is ready.
@MainActor
final class MiniWindowRangeSwitchTests: XCTestCase {
    // MARK: - The monitor keeps the previous window

    func testTheNewWindowIsServedFromThePreviousOneUntilItIsPrepared() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.setDisplayHistoryDemand([3_600])
        try await wait { monitor.displayTelemetryVersion > 0 }

        let hour = monitor.displayHistorySlice(slot: "metric.fan", within: 3_600)
        XCTAssertFalse(hour.isUpdating)
        XCTAssertEqual(hour.duration, 3_600)
        XCTAssertFalse(hour.points.isEmpty)

        // The view body reads the newly selected window before its task has
        // changed the demand ...
        var day = monitor.displayHistorySlice(slot: "metric.fan", within: 86_400)
        XCTAssertTrue(day.isUpdating)
        XCTAssertEqual(day.duration, 3_600, "the chart keeps drawing the window its points belong to")
        XCTAssertEqual(day.points, hour.points)

        // ... and again after the demand changed, while the new window is prepared.
        let version = monitor.displayTelemetryVersion
        monitor.setDisplayHistoryDemand([86_400])
        day = monitor.displayHistorySlice(slot: "metric.fan", within: 86_400)
        XCTAssertTrue(day.isUpdating, "the previous window must not be dropped before the new one exists")
        XCTAssertEqual(day.duration, 3_600)
        XCTAssertEqual(day.points, hour.points)

        try await wait { monitor.displayTelemetryVersion > version }
        day = monitor.displayHistorySlice(slot: "metric.fan", within: 86_400)
        XCTAssertFalse(day.isUpdating)
        XCTAssertEqual(day.duration, 86_400)
        XCTAssertGreaterThan(day.points.count, hour.points.count)
        XCTAssertTrue(monitor.displayHistory(within: 3_600).isEmpty,
                      "the previous window is released once the new one is ready")
    }

    func testSlotsKeepTheirOwnPreviousWindowAndMemoryIsSeparate() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points(), memoryPoints: MiniWindowHistoryDemandTests.points())
        monitor.setDisplayHistoryDemand([3_600, 300])
        try await wait { monitor.displayTelemetryVersion > 0 && monitor.displayMemoryVersion > 0 }
        XCTAssertEqual(monitor.displayHistorySlice(slot: "metric.cpu", within: 300).duration, 300)
        XCTAssertEqual(monitor.displayHistorySlice(slot: "metric.temperature", within: 3_600).duration, 3_600)
        XCTAssertEqual(monitor.displayHistorySlice(slot: "metric.memory", within: 3_600, memory: true).duration, 3_600)

        // Temperature switches to one day; CPU and memory keep their windows.
        monitor.setDisplayHistoryDemand([86_400, 300, 3_600])
        let temperature = monitor.displayHistorySlice(slot: "metric.temperature", within: 86_400)
        XCTAssertTrue(temperature.isUpdating)
        XCTAssertEqual(temperature.duration, 3_600)
        let cpu = monitor.displayHistorySlice(slot: "metric.cpu", within: 300)
        XCTAssertFalse(cpu.isUpdating)
        XCTAssertEqual(cpu.duration, 300)
        let memory = monitor.displayHistorySlice(slot: "metric.memory", within: 3_600, memory: true)
        XCTAssertFalse(memory.isUpdating)
        // A memory chart asking for a window it never drew starts empty; it
        // does not borrow another slot's window.
        let firstOpen = monitor.displayHistorySlice(slot: "metric.gpu", within: 43_200)
        XCTAssertTrue(firstOpen.points.isEmpty)
        XCTAssertFalse(firstOpen.isUpdating, "nothing is on screen to keep")
        XCTAssertEqual(firstOpen.duration, 43_200)
    }

    func testAQuickSecondSwitchStillShowsTheLastWindowThatWasDrawn() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.setDisplayHistoryDemand([3_600])
        try await wait { monitor.displayTelemetryVersion > 0 }
        let hour = monitor.displayHistorySlice(slot: "metric.fan", within: 3_600)
        // Two switches without waiting for either preparation.
        monitor.setDisplayHistoryDemand([86_400])
        _ = monitor.displayHistorySlice(slot: "metric.fan", within: 86_400)
        monitor.setDisplayHistoryDemand([300])
        let fiveMinutes = monitor.displayHistorySlice(slot: "metric.fan", within: 300)
        XCTAssertTrue(fiveMinutes.isUpdating)
        XCTAssertEqual(fiveMinutes.duration, 3_600)
        XCTAssertEqual(fiveMinutes.points, hour.points)
        try await wait { !monitor.displayHistorySlice(slot: "metric.fan", within: 300).isUpdating }
        XCTAssertEqual(monitor.displayHistorySlice(slot: "metric.fan", within: 300).duration, 300)
    }

    /// D39 (user-approved, replaces "a hidden panel releases every window"):
    /// the windows of the last visible demand are kept while the panel is
    /// hidden, without being prepared again; the next opening draws them at
    /// once, marked as updating, until the new demand's windows replace them.
    func testAHiddenPanelKeepsTheLastVisibleWindowsUntilTheNextOpeningReplacesThem() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.setDisplayHistoryDemand([3_600])
        try await wait { monitor.displayTelemetryVersion > 0 }
        let visible = monitor.displayHistorySlice(slot: "metric.fan", within: 3_600)
        XCTAssertFalse(visible.points.isEmpty)
        let preparedVersion = monitor.displayTelemetryVersion

        monitor.setDisplayHistoryDemand([])
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(monitor.displayTelemetryVersion, preparedVersion, "nothing is prepared while hidden")
        XCTAssertEqual(monitor.displayHistory(within: 3_600), visible.points, "the last visible window is kept")
        let kept = monitor.displayHistorySlice(slot: "metric.fan", within: 3_600)
        XCTAssertEqual(kept.points, visible.points)
        XCTAssertEqual(kept.duration, 3_600)
        XCTAssertTrue(kept.isUpdating, "a kept window is drawn as updating")
        let otherRange = monitor.displayHistorySlice(slot: "metric.fan", within: 86_400)
        XCTAssertEqual(otherRange.points, visible.points, "another range draws the kept window meanwhile")
        XCTAssertTrue(otherRange.isUpdating)

        // Opening again: the kept window at once, then the prepared one.
        monitor.setDisplayHistoryDemand([3_600])
        let reopened = monitor.displayHistorySlice(slot: "metric.fan", within: 3_600)
        XCTAssertEqual(reopened.points, visible.points)
        XCTAssertTrue(reopened.isUpdating)
        try await wait { monitor.displayTelemetryVersion > preparedVersion }
        let refreshed = monitor.displayHistorySlice(slot: "metric.fan", within: 3_600)
        XCTAssertFalse(refreshed.isUpdating, "replaced by the window prepared for this opening")
        XCTAssertFalse(refreshed.points.isEmpty)
    }

    /// D39: the kept windows are at most the last demand's four windows.
    func testOnlyTheLastVisibleDemandsWindowsAreKept() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.setDisplayHistoryDemand([60, 900, 3_600, 86_400, 604_800])
        try await wait { monitor.displayTelemetryVersion > 0 }
        monitor.setDisplayHistoryDemand([])
        let kept = [60, 900, 3_600, 86_400, 604_800].filter { !monitor.displayHistory(within: TimeInterval($0)).isEmpty }
        XCTAssertEqual(kept, [60, 900, 3_600, 86_400], "the windows that were prepared, at most four")
        XCTAssertGreaterThan(monitor.retainedDisplayHistoryBytes().arrayBytes, 0)
    }

    // MARK: - The chart frame keeps the previous frame

    func testAPreparedFrameStaysWhileAFrameForAnotherWindowIsPrepared() async throws {
        func key(_ configuration: String, revision: Int = 0) -> MenuBarDerivedKey {
            .init(page: "sensors", kind: "line-frame", revision: String(revision), configuration: configuration)
        }
        let model = MenuBarPreparedChartModel<Int>(cache: MenuBarDerivedCache())
        model.request(key: key("fan:360x140:3600"), shape: "fan:360x140", cost: 8) { 1 }
        try await wait { model.value == 1 }

        // Only the time window changed: same series and plot.
        model.request(key: key("fan:360x140:86400"), shape: "fan:360x140", cost: 8) {
            Thread.sleep(forTimeInterval: 0.05)
            return 24
        }
        XCTAssertEqual(model.value, 1, "the previous frame stays until the new window's frame is ready")
        try await wait { model.value == 24 }

        // Another plot size or series: an old frame would be drawn in the wrong place.
        model.request(key: key("fan:300x140:86400"), shape: "fan:300x140", cost: 8) {
            Thread.sleep(forTimeInterval: 0.05)
            return 30
        }
        XCTAssertNil(model.value, "a frame of another shape is cleared at once")
        try await wait { model.value == 30 }

        // Requests without a shape keep the earlier behavior.
        model.request(key: key("fan:300x140:3600"), cost: 8) {
            Thread.sleep(forTimeInterval: 0.05)
            return 3
        }
        XCTAssertNil(model.value)
        try await wait { model.value == 3 }
        model.stop()
    }

    func testEveryHistoryFrameDeclaresItsShapeWithoutTheTimeWindow() throws {
        let charts = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        let power = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        let disk = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekDiskView.swift")
        for (source, kind) in [(charts, "\"line-frame\""), (charts, "\"network-frame\""), (charts, "\"disk-frame\""),
                               (power, "\"power-frame\""), (power, "\"power-summary\"")] {
            let call = try XCTUnwrap(source.components(separatedBy: "MenuBarChartPreparation(kind: \(kind)").dropFirst().first?
                .components(separatedBy: "build:").first, kind)
            let shape = try XCTUnwrap(call.components(separatedBy: "shape: ").dropFirst().first?
                .components(separatedBy: "\n").first, "\(kind) declares no shape")
            XCTAssertFalse(shape.contains("duration"), "\(kind): the shape must not include the time window")
            XCTAssertTrue(call.contains("configuration:") && call.contains("duration"),
                          "\(kind): the window stays part of the cache key")
        }
        // The disk summary feeds the chart, its legend and the peak row.
        XCTAssertEqual(charts.components(separatedBy: "shape: GeekPreparedDiskSummary.preparationShape").count - 1, 1)
        XCTAssertEqual(disk.components(separatedBy: "shape: GeekPreparedDiskSummary.preparationShape").count - 1, 1)
    }

    // MARK: - The hosting card redraws when the window arrives

    func testTheCardHostingAFanHistoryFollowsThePreparedTelemetry() async throws {
        typealias Revision = MenuBarCardHistoryRevision
        // The fan rows live in the hardware-control card. Its fingerprint had
        // no history revision, so a delivered window did not redraw the fan
        // history until an unrelated value changed.
        XCTAssertEqual(Revision.label(domain: .controls, activeHistoryMetric: .fan, telemetryVersion: 7, memoryVersion: 3), "7")
        XCTAssertNil(Revision.label(domain: .controls, activeHistoryMetric: nil, telemetryVersion: 7, memoryVersion: 3),
                     "the control card is not redrawn by every sample while no history is open")
        XCTAssertNil(Revision.label(domain: .controls, activeHistoryMetric: .battery, telemetryVersion: 7, memoryVersion: 3))
        for domain in [MenuBarCardDomain.cpu, .network, .sensors] {
            XCTAssertEqual(Revision.label(domain: domain, activeHistoryMetric: nil, telemetryVersion: 7, memoryVersion: 3), "7")
        }
        XCTAssertEqual(Revision.label(domain: .memory, activeHistoryMetric: nil, telemetryVersion: 7, memoryVersion: 3), "3")
        XCTAssertNil(Revision.label(domain: .capacity, activeHistoryMetric: .fan, telemetryVersion: 7, memoryVersion: 3))

        // With the real monitor and card model: delivering the new window
        // advances the card's revision only while the fan history is open.
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        var activeMetric: GeekChartRangeMetric? = .fan
        let card = MenuBarCardModel(sources: [monitor.objectWillChange.eraseToAnyPublisher()]) {
            var fingerprint = MenuBarCardFingerprint()
            if let label = Revision.label(domain: .controls, activeHistoryMetric: activeMetric,
                                          telemetryVersion: monitor.displayTelemetryVersion,
                                          memoryVersion: monitor.displayMemoryVersion) {
                fingerprint.labels.append(label)
            }
            return fingerprint
        }
        monitor.setDisplayHistoryDemand([43_200])
        try await wait { monitor.displayTelemetryVersion > 0 }
        try await wait { card.revision.version > 0 }
        XCTAssertGreaterThan(card.revision.version, 0, "the fan history is redrawn when its window is delivered")

        activeMetric = nil
        card.reconcile()
        let idle = card.revision.version
        monitor.setDisplayHistoryDemand([3_600])
        try await wait { !monitor.displayHistory(within: 3_600).isEmpty }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(card.revision.version, idle)

        let liveCard = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarLiveCard.swift")
        XCTAssertTrue(liveCard.contains("activeHistoryMetric: activeInlineTertiaryRequest?.chartRangeMetric"))
    }

    // MARK: - The plot says that it is updating

    func testThePlotBlockMarksAWindowThatIsNotTheSelectedOne() throws {
        // Since the review of batch 4b (P2-4) the state is passed explicitly
        // (`MenuBarDisplayedHistory.isUpdating`) or reported by the chart's
        // prepared frame, not inferred from the environment; see
        // MiniWindowUpdatingStateTests.
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(GeekHistoryAxisFooter.centerLabel(valueRange: "0–100%", isUpdating: false), "纵轴 0–100%")
        XCTAssertEqual(GeekHistoryAxisFooter.centerLabel(valueRange: "0–100%", isUpdating: true), "更新中…")
        XCTAssertTrue(GeekHistoryAxisFooter.accessibilitySummary(
            duration: 3_600, valueRange: "0–100%", showsGapLegend: true, isUpdating: true
        ).contains("正在更新为所选时间范围"))
        chinese.restore()
        let english = MiniWindowLogicLanguageScope(.english)
        XCTAssertEqual(GeekHistoryAxisFooter.centerLabel(valueRange: nil, isUpdating: true), "Updating…")
        english.restore()

        let charts = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        let block = try MiniWindowLogicFixtures.section(
            charts, from: "struct GeekHistoryPlotBlock<Chart: View>: View {", to: "/// Legend swatch for an unrecorded period")
        XCTAssertTrue(block.contains("historyIsUpdating: footer.isUpdating"))
        XCTAssertTrue(block.contains(".opacity(isUpdating ? GeekHistoryPlotBlock.updatingOpacity : 1)"))
        // Still one 154 pt block: the 140 pt chart and the 14 pt axis row.
        XCTAssertTrue(block.contains(".frame(height: MiniWindowStyleTokens.historyChartHeight)"))
        XCTAssertTrue(block.contains("VStack(spacing: 0)"))
    }

    // MARK: - The view reads slices

    func testChartsReadTheirPointsAndTheirWindowFromTheSameSlice() throws {
        let root = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(root.contains("monitorState.displayHistorySlice(slot: slot, within: range.duration, memory: memory)"))
        XCTAssertFalse(root.contains("monitorState.displayHistory(within:"),
                       "an exact read drops the chart to empty while a window is prepared")
        // The displayed range is what the charts draw; the selection stays the
        // picker's and the demand's.
        XCTAssertTrue(root.contains("func geekMetricRange(_ metric: GeekChartRangeMetric) -> GeekChartRange {\n        metricDisplayedHistory(metric).range"))
        XCTAssertTrue(root.contains("func geekMetricHistory(_ metric: GeekChartRangeMetric) -> [MenuBarTelemetryPoint] {\n        metricDisplayedHistory(metric).points"))
        XCTAssertTrue(root.contains("var cpuChartRange: GeekChartRange {\n        cpuDisplayedHistory.range"))
        XCTAssertTrue(root.contains("var networkChartRange: GeekChartRange {\n        networkDisplayedHistory.range"))
        XCTAssertTrue(root.contains("range: selectedChartRange,\n                select: selectGeekChartRange"))
        XCTAssertTrue(root.contains("historyDemandPlan.durations"))
        let panel = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekPanel.swift")
        XCTAssertTrue(panel.contains("var geekTelemetryChartDuration: TimeInterval {\n        selectedDisplayedHistory.range.duration"))
    }

    // MARK: - Helpers

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "the condition was not reached in time")
    }
}
