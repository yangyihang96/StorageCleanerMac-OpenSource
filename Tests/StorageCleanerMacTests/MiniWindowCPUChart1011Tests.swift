import AppKit
import FanControlShared
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MiniWindowCPUChart1011Tests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 864_000)

    private func recentPoints(endingAt reference: Date) -> [MenuBarTelemetryPoint] {
        (-89...0).map { second in
            .init(date: reference.addingTimeInterval(Double(second)),
                  cpuTotal: 40, cpuUser: 30, cpuSystem: 10, gpu: 20, memory: 50,
                  chipTemperature: 60, fanRPM: 2_000,
                  downBytesPerSecond: 1_000, upBytesPerSecond: 100)
        }
    }

    func testOnlyNinetySecondsOfCPUOccupyTheRightEdgeOfAnHour() throws {
        for clockOffset in [0.0, 0.2, 2.0] {
            let reference = end.addingTimeInterval(clockOffset)
            let points = recentPoints(endingAt: end)
            let original = points
            for scale: CGFloat in [1, 2] {
                let plot = CGRect(x: 2, y: 0, width: 360, height: 140)
                let range = GeekChartWindow.barRange(for: points.map(\.date),
                    duration: 3_600, referenceDate: reference)
                XCTAssertEqual(range.start, reference.addingTimeInterval(-3_600))
                XCTAssertEqual(range.end, reference)
                XCTAssertEqual(range.dataStart, points.first?.date)
                let raw = GeekChartWindow.barBucketSnapshots(for: points.map(\.date),
                    in: plot, range: range, referenceDate: reference, displayScale: scale)
                let display = GeekChartWindow.displayBuckets(for: points.map(\.date),
                    in: plot, range: range, referenceDate: reference, displayScale: scale,
                    unrecordedIntervals: [], holdLatestWhileFresh: true)
                let cpu = GeekCPUHistoryFrame.prepare(points: points, plotRect: plot,
                    duration: 3_600, referenceDate: reference, samplingInterval: 1, displayScale: scale)
                let prepared = GeekPreparedLineFrame(points: points, channels: [.cpuUser, .cpuSystem],
                    plot: plot, duration: 3_600, reference: reference, samplingInterval: 1,
                    scale: scale, stacked: true, valueRange: 0...100)
                let cutoff = plot.maxX - plot.width * 90 / 3_600 - GeekChartWindow.barPitch
                for buckets in [raw, display, prepared.buckets] {
                    XCTAssertEqual(buckets.count, 120)
                    XCTAssertTrue(buckets.prefix(116).allSatisfy { $0.indices.isEmpty },
                        "The first 58.5 minutes were never recorded")
                    XCTAssertFalse(buckets.contains(where: \.isEstimated))
                    XCTAssertTrue(buckets.filter { !$0.indices.isEmpty }.allSatisfy { $0.x >= cutoff })
                }
                XCTAssertFalse(cpu.marks.isEmpty)
                XCTAssertLessThanOrEqual(cpu.marks.count, 4)
                XCTAssertTrue(cpu.marks.allSatisfy { $0.bucket.x >= cutoff && !$0.isEstimated })
                XCTAssertEqual(try XCTUnwrap(prepared.cpu).marks.count, cpu.marks.count)
            }
            XCTAssertEqual(points, original, "Display preparation cannot rewrite raw timestamps")
        }
    }

    func testSharedHourProjectionDoesNotExpandRecentMemoryGPUOrSensorSamples() {
        let points = recentPoints(endingAt: end)
        let plot = CGRect(x: 2, y: 0, width: 360, height: 140)
        for channel in [MenuBarTelemetryChannel.memory, .gpu, .chipTemperature, .fanRPM] {
            let frame = GeekPreparedLineFrame(points: points, channels: [channel], plot: plot,
                duration: 3_600, reference: end, samplingInterval: 1, scale: 2,
                stacked: true, valueRange: 0...100)
            XCTAssertTrue(frame.values.prefix(116).allSatisfy { $0.allSatisfy { $0 == nil } },
                "\(channel) cannot draw readings before monitoring began")
            XCTAssertLessThanOrEqual(frame.values.filter { $0.contains { $0 != nil } }.count, 4)
        }
        let network = GeekPreparedNetworkFrame(history: .init(points: points), plotRect: plot,
            duration: 3_600, referenceDate: end, displayScale: 2)
        XCTAssertLessThanOrEqual(network.uploadMarks.count, 4)
        XCTAssertLessThanOrEqual(network.downloadMarks.count, 4)
        XCTAssertTrue(network.buckets.prefix(116).allSatisfy { $0.upload == nil && $0.download == nil })
    }

    func testShortRangeEstimatesCannotFillBeforeRecordingOrAcrossAPause() {
        let pause = DateInterval(start: end.addingTimeInterval(-45), end: end.addingTimeInterval(-30))
        let dates = recentPoints(endingAt: end).map(\.date).filter { !pause.contains($0) }
        let plot = CGRect(x: 0, y: 0, width: 360, height: 140)
        let range = GeekChartWindow.barRange(for: dates, duration: 120, referenceDate: end)
        let buckets = GeekChartWindow.displayBuckets(for: dates, in: plot, range: range,
            referenceDate: end, displayScale: 2, unrecordedIntervals: [pause], holdLatestWhileFresh: true)
        XCTAssertEqual(buckets.count, 120)
        XCTAssertTrue(buckets.prefix(30).allSatisfy { $0.indices.isEmpty && !$0.isEstimated },
            "Interpolation must not backfill time before the first observation")
        let paused = buckets.filter { $0.start >= pause.start.addingTimeInterval(1)
            && $0.end <= pause.end.addingTimeInterval(-1) }
        XCTAssertFalse(paused.isEmpty)
        XCTAssertTrue(paused.allSatisfy { $0.indices.isEmpty && !$0.isEstimated })
    }

    func testRecentPowerSamplesUseTheSameUnrecordedHourSlots() {
        let plot = CGRect(x: 2, y: 0, width: 360, height: 140)
        let points = recentPoints(endingAt: end).map {
            MenuBarPowerHistoryPoint(date: $0.date, chargePercent: 80,
                batteryPowerWatts: -8, isCharging: false, powerSource: .batteryPower)
        }
        for metric in [GeekPowerHistoryMetric.charge, .batteryPower] {
            let kernel = GeekPowerPreparationKernel(points: points, metric: metric,
                duration: 3_600, displayScale: 2)
            let buckets = kernel.batteryBuckets(kernel.usablePoints(endingAt: end),
                plot: plot, referenceDate: end)
            XCTAssertEqual(buckets.count, 120)
            XCTAssertTrue(buckets.prefix(116).allSatisfy { $0.indices.isEmpty })
            XCTAssertLessThanOrEqual(buckets.filter { !$0.indices.isEmpty }.count, 4)
            XCTAssertFalse(buckets.contains(where: \.isEstimated))
        }
    }

    func testAFreshDestinationCanRestoreHistoryFromTheExplicitLegacySource() async throws {
        let root = TestFileSystem.uniqueRoot("CPUHistoryLegacy")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyURL = root.appendingPathComponent("legacy.json")
        let destinationURL = root.appendingPathComponent("new/MetricHistory-v1.json")
        let oldPoint = MenuBarTelemetryPoint(date: end.addingTimeInterval(-3_000),
            cpuTotal: 40, cpuUser: 30, cpuSystem: 10, gpu: nil, memory: nil,
            chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil)
        let legacy = MetricHistorySnapshot(telemetry: [oldPoint] + recentPoints(endingAt: end))
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        let store = MetricHistoryStore(url: destinationURL, legacyMetricURL: legacyURL)
        let restored = await store.load(now: end)
        XCTAssertTrue(restored.telemetry.contains { $0.date == oldPoint.date },
            "A new QA destination does not imply a new recording when legacy migration is configured")
        XCTAssertEqual(restored.telemetry.count, 91)
        try await store.flush()
        XCTAssertEqual(try JSONDecoder().decode(MetricHistorySnapshot.self,
            from: Data(contentsOf: legacyURL)), legacy, "Migration leaves its source intact")
    }

    func testCPUCardExpandsThePlotDirectlyUnderItsHeaderWithinTheSameShell() throws {
        let points = (-60...0).map { second in
            MenuBarTelemetryPoint(date: end.addingTimeInterval(Double(second)),
                cpuTotal: 100, cpuUser: 60, cpuSystem: 40, gpu: nil, memory: nil,
                chipTemperature: nil, fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil)
        }
        let width: CGFloat = 288
        let user = Color(red: 0, green: 1, blue: 0)
        let system = Color(red: 1, green: 0, blue: 0)
        for scale: CGFloat in [1, 2] {
            let view = GeekProcessorPresentation(cpuChartHistory: points, cpuChartRange: .oneMinute,
                samplingInterval: 1, processorTint: user,
                geekCPUUserBarColor: user, geekCPUSystemBarColor: system).frame(width: width)
            let bitmap = try render(view, scale: scale)
            XCTAssertLessThanOrEqual(CGFloat(bitmap.pixelsHigh) / scale,
                GeekPanelLayout.overviewProcessorCardHeight + 0.5,
                "The extra chart area comes from unused space, not from a taller overview")
            let plot = CGRect(x: 0, y: 0, width: width - 2 * GeekVisualTokens.cardHorizontalPadding,
                height: GeekPanelLayout.overviewProcessorChartHeight)
            let frame = GeekCPUHistoryFrame.prepare(points: points, plotRect: plot, duration: 60,
                referenceDate: end, samplingInterval: 1, displayScale: scale)
            let mark = try XCTUnwrap(frame.marks.dropFirst(frame.marks.count / 2).first)
            let x = Int((GeekVisualTokens.cardHorizontalPadding + mark.rect.midX) * scale)
            let colors = (0..<bitmap.pixelsHigh).compactMap { y -> (y: Int, color: NSColor)? in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      isFixtureBarColor(color) else { return nil }
                return (y, color)
            }
            XCTAssertGreaterThanOrEqual(CGFloat(colors.count) / scale, 58,
                "A 100% stack should use at least 58 pt; the old compact plot only used 47 pt")
            let first = try XCTUnwrap(colors.first)
            let last = try XCTUnwrap(colors.last)
            XCTAssertLessThanOrEqual(CGFloat(first.y) / scale,
                GeekVisualTokens.cardVerticalPadding + MiniWindowStyleTokens.dataRowHeight + 2,
                "The plot starts immediately after the header")
            XCTAssertGreaterThan(first.color.redComponent, first.color.greenComponent,
                "System is above user in a stack")
            XCTAssertGreaterThan(last.color.greenComponent, last.color.redComponent,
                "User is the lower part of the stack")
            XCTAssertEqual(Set(frame.marks.map { $0.rect.width }).count, 1)
            XCTAssertEqual(GeekChartWindow.barMetrics(displayScale: scale).spacing, 1 / scale)
        }
    }

    func testAnHourWithNinetySecondsRendersUnrecordedBlocksOnTheLeft() throws {
        let points = recentPoints(endingAt: end)
        let chart = GeekPrecisionLineChart(points: points,
            series: [.init(id: "user", title: "User", channel: .cpuUser,
                           color: Color(red: 0, green: 1, blue: 0)),
                     .init(id: "system", title: "System", channel: .cpuSystem,
                           color: Color(red: 1, green: 0, blue: 0))],
            valueRange: 0...100, unit: .percent, accessibilityLabel: "CPU",
            style: .stackedBars, duration: 3_600, showsLegend: false,
            showsTimelineLabels: false, horizontalInset: 0).frame(width: 360, height: 140)
        let bitmap = try render(chart, scale: 2)
        let missing = try XCTUnwrap(bitmap.colorAt(x: 20, y: 100)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(missing.alphaComponent, 0, "Unrecorded is drawn, not silently collapsed")
        XCTAssertEqual(missing.redComponent, missing.greenComponent, accuracy: 0.05)
        XCTAssertEqual(missing.redComponent, missing.blueComponent, accuracy: 0.05)
        let pointsOnLeft = (0..<bitmap.pixelsHigh).compactMap { bitmap.colorAt(x: 20, y: $0)?.usingColorSpace(.sRGB) }
        XCTAssertFalse(pointsOnLeft.contains(where: isFixtureBarColor))
    }

    func testMissingAndInvalidNativeFrequencyChannelsDoNotCreateDashRows() {
        XCTAssertTrue(GeekProcessorFrequencyPresentation.rows(telemetry: nil, sampledAt: nil).isEmpty)
        let clusters = [cluster("missing", frequency: nil), cluster("invalid", frequency: .nan),
                        cluster("negative", frequency: -1)]
        let telemetry = CPUPerformanceStateService.Snapshot(processorModel: "Fixture",
            performanceLevels: [], clusters: clusters,
            gpu: .init(frequencyMHz: .infinity, activeRatio: 1, maximumFrequencyMHz: 1_000))
        XCTAssertTrue(GeekProcessorFrequencyPresentation.rows(telemetry: telemetry, sampledAt: end).isEmpty)
    }

    func testNativeFrequencyKeepsPartialReadingsZeroAndObservedGPUIdle() {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let telemetry = CPUPerformanceStateService.Snapshot(processorModel: "Fixture", performanceLevels: [],
            clusters: [cluster("missing", frequency: nil), cluster("zero", frequency: 0),
                       cluster("active", frequency: 3_400)],
            gpu: .init(frequencyMHz: nil, activeRatio: 0, maximumFrequencyMHz: 1_000))
        let rows = GeekProcessorFrequencyPresentation.rows(telemetry: telemetry, sampledAt: end)
        XCTAssertEqual(rows.map(\.id), ["cpu-frequency", "cpu-cluster-zero", "cpu-cluster-active", "gpu-frequency"])
        XCTAssertEqual(rows.map(\.value), ["3.40 GHz", "0.00 GHz", "3.40 GHz", "空闲"])
        XCTAssertTrue(rows.allSatisfy { $0.source == "IOReport" && $0.sampledAt == end })
        XCTAssertFalse(rows.contains { $0.value == "—" })
    }

    func testFrequencyMissingStateUsesTheExistingPassiveHelperCardsAndEnableEntry() throws {
        let page = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekProcessorView.swift")
        let card = try MiniWindowLogicFixtures.section(page, from: "private var geekProcessorFrequencyCard: some View {",
            to: "private var geekProcessorActivityHoverTarget")
        XCTAssertTrue(card.contains("if rows.isEmpty"))
        XCTAssertTrue(card.contains("GeekHelperPowerMetricsCards(monitor: store.helperPowerMetricsMonitor)"))
        XCTAssertTrue(card.contains("rows: presentation.frequencyRows"))
        XCTAssertTrue(card.contains("unavailableText: presentation.unavailableText"))
        XCTAssertTrue(card.contains("geekSensorReadoutCard"), "Real native readings keep their normal card")
        XCTAssertFalse(card.contains("updateConsumer"))
        XCTAssertFalse(card.contains("requestAuthorization"))
        let sensors = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsView.swift")
        let accessor = try MiniWindowLogicFixtures.section(sensors, from: "var geekFrequencyReadouts: [GeekSensorReadout] {",
            to: "/// The overview's and the sensors page's GPU ring detail")
        XCTAssertTrue(accessor.contains("GeekProcessorFrequencyPresentation.rows("))
        XCTAssertFalse(accessor.contains("—"))
        XCTAssertTrue(GeekHelperPowerMetricsPresentation(state: .needsHelper, now: end).frequencyRows.isEmpty)
    }

#if DEBUG
    func testDemoIncludesBothShortRecordingAndMissingProcessorFrequency() throws {
        let short = MiniWindowDemoData.MenuBarSnapshotScenario.cpuHistoryShortRecording
        let missing = MiniWindowDemoData.MenuBarSnapshotScenario.processorSecondaryNoFrequency
        let arguments = [MiniWindowDemoData.launchArgument,
                         MiniWindowDemoData.menuBarPanelSnapshotCaptureArgumentPrefix + "/private/tmp/unused",
                         MiniWindowDemoData.menuBarPanelSnapshotScenarioArgumentPrefix + short.rawValue]
        let fixture = MiniWindowDemoData.makeFixture(arguments: arguments)
        XCTAssertEqual(fixture.telemetry.count, 90)
        XCTAssertEqual(try XCTUnwrap(fixture.telemetry.last).date.timeIntervalSince(
            try XCTUnwrap(fixture.telemetry.first).date), 89)
        XCTAssertEqual(short.expectedPanelCount, 3)
        XCTAssertEqual(missing.expectedPanelCount, 2)
        XCTAssertNil(MiniWindowDemoData.processorTelemetry(for: missing))
        XCTAssertTrue(GeekHelperPowerMetricsPresentation(state: MiniWindowDemoData.helperPowerMetricsState(for: missing),
            now: MiniWindowDemoData.referenceDate).frequencyRows.isEmpty)
        XCTAssertNotNil(MiniWindowDemoData.processorTelemetry(for: .processorSecondary))
    }
#endif

    private func cluster(_ id: String, frequency: Double?) -> CPUPerformanceStateService.ClusterReading {
        .init(identifier: id, performanceLevelIndex: 0, performanceLevelName: "Fixture",
            coreCount: 4, frequencyMHz: frequency, voltageVolts: nil)
    }

    private func render<Content: View>(_ view: Content, scale: CGFloat) throws -> NSBitmapImageRep {
        let clock = PanelChartClock(anchor: .init(wallDate: end, instant: ContinuousClock().now))
        let renderer = ImageRenderer(content: view.environment(\.panelChartClock, clock)
            .environment(\.panelChartAccentColor, nil).environment(\.colorScheme, .dark)
            .environment(\.miniWindowVisualMode, .black).environment(\.displayScale, scale))
        renderer.scale = scale
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// SwiftUI's rendered gamut conversion can add a small green component to
    /// red. Distinguish the fixture's hues by dominance, not exact RGB zeroes.
    private func isFixtureBarColor(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.8
            && (color.redComponent > max(color.greenComponent, color.blueComponent) + 0.5
                || color.greenComponent > max(color.redComponent, color.blueComponent) + 0.5)
    }
}
