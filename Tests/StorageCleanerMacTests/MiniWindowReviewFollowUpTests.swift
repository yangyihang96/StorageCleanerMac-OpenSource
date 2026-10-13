import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Batch r2-mini-speed, phase 2: follow-ups of the batch 4b review (BOARD
/// N11) and of the phase 1 review (P2-2, P2-3).
@MainActor
final class MiniWindowReviewFollowUpTests: XCTestCase {
    // MARK: - N11-1: only another time window is "updating"

    /// A history shows "更新中…" while it draws a frame of another time window.
    /// The frame's key also holds the value range and the sampling interval:
    /// when only those change (a fan scale grows with its readings, the
    /// refresh interval is changed), the frame on screen still shows the
    /// selected window and is not marked.
    func testOnlyAnotherTimeWindowMarksThePreviousFrame() async throws {
        func key(_ configuration: String) -> MenuBarDerivedKey {
            .init(page: "sensors", kind: "line-frame", revision: "0", configuration: configuration)
        }
        let model = MenuBarPreparedChartModel<Int>(cache: MenuBarDerivedCache())
        model.request(key: key("fan:360x140:3600:0...2000:1"), shape: "fan:360x140", window: 3_600, cost: 8) { 1 }
        try await wait { model.value == 1 }

        model.request(key: key("fan:360x140:3600:0...2500:1"), shape: "fan:360x140", window: 3_600, cost: 8) {
            Thread.sleep(forTimeInterval: 0.05)
            return 2
        }
        XCTAssertEqual(model.value, 1, "the frame stays while the new scale is prepared")
        XCTAssertFalse(model.isShowingPreviousValue, "a new value range is not another time window")
        try await wait { model.value == 2 }

        model.request(key: key("fan:360x140:3600:0...2500:2"), shape: "fan:360x140", window: 3_600, cost: 8) {
            Thread.sleep(forTimeInterval: 0.05)
            return 3
        }
        XCTAssertFalse(model.isShowingPreviousValue, "a new sampling interval is not another time window")
        try await wait { model.value == 3 }

        model.request(key: key("fan:360x140:86400:0...2500:2"), shape: "fan:360x140", window: 86_400, cost: 8) {
            Thread.sleep(forTimeInterval: 0.05)
            return 4
        }
        XCTAssertTrue(model.isShowingPreviousValue, "another time window is still marked")
        try await wait { model.value == 4 }
        XCTAssertFalse(model.isShowingPreviousValue)
        model.stop()
    }

    // MARK: - N11-4: swap counters include swapfile maintenance

    /// `man vm_stat` (line 107 on macOS 27.2): "Both swap counters also include
    /// I/O used for swapfile maintenance." The help says so again.
    func testSwapHelpSaysTheCountersIncludeSwapFileMaintenance() {
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        for row in GeekMemorySwapActivity.rows(swappedInBytes: 1_024, swappedOutBytes: nil) {
            XCTAssertTrue(row.help.contains("也包含交换文件维护产生的读写"), row.help)
        }
        chinese.restore()
        let english = MiniWindowLogicLanguageScope(.english)
        defer { english.restore() }
        for row in GeekMemorySwapActivity.rows(swappedInBytes: 1_024, swappedOutBytes: 2_048) {
            XCTAssertTrue(row.help.contains("swap file maintenance"), row.help)
        }
    }

    // MARK: - Review P2-1: long sensors and power histories

    /// The sensors level-3 page and the fan scale walked the whole window on
    /// the main thread on every redraw (several times a second on a 7- or
    /// 28-day window), and the power history recomputed whether its window has
    /// a drawable trend on every redraw, including every hover move. These
    /// facts are now prepared with the window, off the main thread.
    func testSensorsAndPowerHistoriesAreNotWalkedWhenDrawn() throws {
        let tertiary = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        let sensors = try MiniWindowLogicFixtures.section(
            tertiary, from: "private var tertiarySensorsDetail: some View {", to: "private var tertiaryPowerDetail")
        for walk in ["history.contains", "history.compactMap", "history.map", "PanelChartSampling.hasRenderableTrend"] {
            XCTAssertFalse(sensors.contains(walk), "the sensors level-3 page reads the prepared summary, not \(walk)")
        }
        let components = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift")
        let fan = try MiniWindowLogicFixtures.section(
            components, from: "var fanTrendMaximum: Double {", to: "var hasOverviewCompactGauges")
        XCTAssertFalse(fan.contains("history.flatMap"), "the fan scale reads the prepared maximum")
        let power = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        let render = try MiniWindowLogicFixtures.section(
            power, from: "private func renderChartContent(referenceDate: Date) -> some View {", to: "GeometryReader { proxy in")
        XCTAssertTrue(render.contains("activeFrame?.hasRenderableTrend"),
                      "a prepared power frame says whether it has a drawable trend")
    }

    /// The prepared summary is what the pages computed before, for windows
    /// with gaps, missing channels and fan targets.
    func testTheWindowSummaryEqualsWhatThePagesComputed() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func window(_ count: Int, gapEvery: Int?, gpu: Bool, target: Bool) -> [MenuBarTelemetryPoint] {
            (0..<count).compactMap { index -> MenuBarTelemetryPoint? in
                if let gapEvery, index % gapEvery == 0 { return nil }
                return MenuBarTelemetryPoint(
                    date: now.addingTimeInterval(Double(index - count) * 60),
                    cpuTotal: 10, cpuUser: 7, cpuSystem: 3, gpu: nil, memory: 40,
                    chipTemperature: index % 9 == 0 ? nil : 40 + Double(index % 7),
                    gpuTemperature: gpu ? 35 + Double(index % 5) : nil,
                    fanRPM: index % 4 == 0 ? nil : 1_400 + Double(index % 50),
                    fanTargetRPM: target && index % 3 == 0 ? 1_900 : nil,
                    downBytesPerSecond: 1, upBytesPerSecond: 1)
            }
        }
        for points in [window(3_000, gapEvery: nil, gpu: true, target: true),
                       window(800, gapEvery: 5, gpu: false, target: false),
                       window(3, gapEvery: nil, gpu: true, target: false), []] {
            let summary = MenuBarTelemetryWindowSummary(points: points)
            for channel in MenuBarTelemetryWindowSummary.temperatureChannels {
                XCTAssertEqual(summary.renderableTemperatureChannels.contains(channel),
                               PanelChartSampling.hasRenderableTrend(points.map {
                                   MenuBarChartSample(date: $0.date, value: channel.value(in: $0))
                               }))
            }
            XCTAssertEqual(summary.hasFanTarget, points.contains { $0.fanTargetRPM?.isFinite == true })
            XCTAssertEqual(summary.fanTrendMaximum, MenuBarChartGeometry.niceCeiling(
                for: points.flatMap { [$0.fanRPM, $0.fanTargetRPM].compactMap { $0 } }, minimum: 1_000))
            XCTAssertEqual(summary.gpuTemperatureStatistics, GeekSeriesStatistics(values: points.compactMap(\.gpuTemperature)))
        }
    }

    /// The monitor prepares the summary together with the window whose
    /// summary is read: the most visible one (review of phase 2: the other
    /// windows are only drawn; see `MiniWindowPhase2ReviewTests`).
    func testTheMonitorPreparesTheSummaryWithTheWindow() async throws {
        let monitor = MenuBarMonitorState()
        monitor.restoreHistory(MiniWindowHistoryDemandTests.points())
        monitor.setDisplayHistoryDemand([3_600, 86_400])
        try await wait { monitor.displayTelemetryVersion > 0 }
        let slice = monitor.displayHistorySlice(slot: "page.sensors", within: 3_600)
        XCTAssertFalse(slice.points.isEmpty)
        XCTAssertEqual(slice.summary, MenuBarTelemetryWindowSummary(points: slice.points))
        let second = monitor.displayHistorySlice(slot: "card", within: 86_400)
        XCTAssertFalse(second.points.isEmpty)
        XCTAssertNil(second.summary, "the second window is only drawn")
        XCTAssertNil(monitor.displayHistorySlice(slot: "page.memory", within: 3_600, memory: true).summary)
    }

    // MARK: - T5: the processor page keeps its height

    /// The processor page's height went 662 ↔ 666 pt every few seconds and
    /// each change re-placed the whole cascade (audit: `setFrame` with cause
    /// `detailSize` right after the process card redrew). The process card's
    /// height must not depend on how many processes the latest snapshot
    /// lists, up to the number it can list.
    func testTheProcessCardHeightDoesNotFollowTheNumberOfProcesses() {
        func app(_ index: Int) -> EnergyImpactApp {
            EnergyImpactApp(
                id: "app-\(index)", name: "App \(index)", path: "/Applications/App\(index).app",
                iconPath: "/Applications/App\(index).app", bundlePath: "/Applications/App\(index).app",
                bundleIdentifier: "com.example.app\(index)", measuredEnergyWh: 1, estimatedSupplementEnergyWh: 0,
                estimatedEnergyWh: 1, currentPowerWatts: 0.4, averagePowerWatts: 0.3, cpuPercent: Double(30 - index),
                diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, residentBytes: 1_024,
                cumulativeCPUSeconds: 120, longestRunningSeconds: 3_600, processCount: 1, measuredProcessCount: 1,
                processIDs: [Int32(100 + index)], isApplication: true)
        }
        func height(rows: Int, extended: Bool) -> CGFloat {
            let view = GeekProcessorProcessList(apps: (0..<rows).map(app), geekOnDemandSnapshotStatusText: "1 s",
                                                isLoading: false, showsExtendedDetails: extended)
                .frame(width: 288)
            let host = NSHostingView(rootView: view)
            return host.fittingSize.height
        }
        let extended = (0...5).map { height(rows: $0, extended: true) }
        XCTAssertEqual(Set(extended).count, 1, "extended card heights for 0–5 processes: \(extended)")
        let compact = (0...3).map { height(rows: $0, extended: false) }
        XCTAssertEqual(Set(compact).count, 1, "compact card heights for 0–3 processes: \(compact)")
    }

    // MARK: - Helpers

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not met")
    }
}
