import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D133 (R8c): iStat Menus 7.30's swap history
/// (`BBRMenuSwapHistoryGraphSection drawRect:`) draws bars of the swap
/// files' used share, mean of used / total per bucket
/// (`-[BBRStatisticsMemory swapHistoryAverage:end:interval:]`), from 0 to the
/// plot's height; it and the pressure history draw no bar for a zero bucket.
/// The sensor histories scale temperatures 0–100° (`historyMaximum`), rounded
/// up to 10° above it. Fixtures only: no sampling, window or user data.
@MainActor
final class MiniWindowIStatPressureSwapTests: XCTestCase {
    private static let gibibyte: Int64 = 1_024 * 1_024 * 1_024
    /// A multiple of 5 s, so the 10-minute window's buckets end on it.
    private static let t0: TimeInterval = 2_000_000_000

    func testASampleRecordsTheSwapFilesUsedShare() {
        let point = MenuBarTelemetryPoint(memorySnapshot: Self.memory(used: Self.gibibyte, total: 4 * Self.gibibyte))
        XCTAssertEqual(point.swapUsedPercent, 25)
        XCTAssertEqual(MenuBarTelemetryChannel.swapUsedPercent.value(in: point), 25)
        XCTAssertEqual(point.swapUsedBytes, UInt64(Self.gibibyte), "The bytes stay recorded")
        XCTAssertEqual(MenuBarTelemetryPoint(memorySnapshot: Self.memory(used: 0, total: 0)).swapUsedPercent, 0,
                       "No swap files: 0, as iStat's 0 / 0")
        XCTAssertNil(MenuBarTelemetryPoint(memorySnapshot: Self.memory(used: 0, total: 0, read: false)).swapUsedPercent,
                     "An unread size is no reading")
        XCTAssertEqual(MenuBarTelemetryPoint.swapUsedPercent(used: 5, total: 4), 100)
        XCTAssertNil(MenuBarTelemetryPoint(date: Date(timeIntervalSince1970: Self.t0), cpuTotal: 10, cpuUser: nil,
                                           cpuSystem: nil, gpu: nil, memory: nil, chipTemperature: nil, fanRPM: nil,
                                           downBytesPerSecond: nil, upBytesPerSecond: nil).swapUsedPercent)
        // A system snapshot's point reads no swap: the memory sample brings it.
        // D147: the fixture is only compiled with DEBUG or STORAGE_CLEANER_BETA.
        #if DEBUG || STORAGE_CLEANER_BETA
        let system = MenuBarTelemetryPoint(snapshot: MiniWindowDemoData.makeFixture(arguments: []).snapshot)
        XCTAssertNil(system.swapUsedBytes)
        XCTAssertNil(system.swapUsedPercent, "A system point has no swap share")
        #endif
    }

    func testTheShareIsSavedAndAnOlderHistoryReadsWithoutIt() throws {
        let point = MenuBarTelemetryPoint(memorySnapshot: Self.memory(used: 3 * Self.gibibyte, total: 4 * Self.gibibyte))
        let data = try JSONEncoder().encode(point)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarTelemetryPoint.self, from: data).swapUsedPercent, 75)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["swapUsedPercent"] as? Double, 75)
        object["swapUsedPercent"] = nil
        let older = try JSONDecoder().decode(MenuBarTelemetryPoint.self,
                                             from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.swapUsedPercent)
        XCTAssertEqual(older.swapUsedBytes, point.swapUsedBytes)
        // A folded minute keeps the share's mean, as every channel's.
        XCTAssertEqual(point.statistics(gaps: []).metrics["swapUsedPercent"]?.mean, 75)
        // The copies keep it.
        XCTAssertEqual(point.replacingMemory(with: 12).swapUsedPercent, 75)
        XCTAssertEqual(point.replacingFanRPM(with: 1_200).swapUsedPercent, 75)
    }

    func testTheSwapHistoryDrawsIStatsUsedShareBars() throws {
        let source = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let swap = try MiniWindowLogicFixtures.section(source, from: "struct GeekSwapHoverDetail: View {",
                                                       to: "private var usedShareSection")
        for fragment in ["channel: .swapUsedPercent", "valueRange: 0...100,", "unit: .percent,",
                         "style: .stackedBars,", "verticalInset: 0,", "bucketing: .history,", "drawsZero: false",
                         "valueRange: \"0–100%\""] {
            XCTAssertTrue(swap.contains(fragment), fragment)
        }
        XCTAssertFalse(swap.contains(".swapUsedBytes"))
        XCTAssertFalse(swap.contains("fillOpacity"))
        XCTAssertFalse(swap.contains("chartMaximum"))
        let pressure = try MiniWindowLogicFixtures.section(source, from: "struct GeekMemoryHistoryHoverDetail: View {",
                                                           to: "struct GeekSwapDetailData")
        XCTAssertTrue(pressure.contains("drawsZero: false"))
        // Only those two: iStat draws a zero as a 1 pt bar everywhere else.
        XCTAssertEqual(source.components(separatedBy: "drawsZero: false").count - 1, 2)
        for path in ["Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift",
                     "Views/MenuBarAdvanced/GeekMemoryCompositionView.swift",
                     "Views/MenuBarAdvanced/GeekOverviewPresentation.swift",
                     "Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift"] {
            XCTAssertFalse(try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/" + path)
                .contains("drawsZero: false"), path)
        }
        let charts = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift")
        XCTAssertTrue(charts.contains("guard value > 0 || (drawsZero && total == 0 && index == firstValidIndex)"))
        XCTAssertTrue(charts.contains(".compressedMemoryBytes, .swapUsedBytes, .swapUsedPercent].contains(item.channel)"),
                      "The swap color stays the swap color under a chart theme")
    }

    // D147: rendered with the offscreen hook, compiled with DEBUG only.
    #if DEBUG
    func testAZeroBucketHasNoBarWhereIStatDrawsNone() throws {
        // 10 minutes, 5 s a bucket: 50 % in every other bucket, 0 between.
        let points = (0..<120).reversed().map { k in
            MenuBarTelemetryPoint(date: Date(timeIntervalSince1970: Self.t0 - 5 * Double(k) - 2.5), cpuTotal: nil,
                                  cpuUser: nil, cpuSystem: nil, gpu: nil, memory: nil,
                                  swapUsedPercent: k % 2 == 0 ? 50 : 0, chipTemperature: nil, fanRPM: nil,
                                  downBytesPerSecond: nil, upBytesPerSecond: nil)
        }
        func chart(drawsZero: Bool) -> GeekPrecisionLineChart {
            GeekPrecisionLineChart(
                points: points,
                series: [MenuBarTelemetrySeries(id: "swap-used", title: "Used", channel: .swapUsedPercent,
                                                color: Color(red: 0, green: 1, blue: 0))],
                valueRange: 0...100, unit: .percent, accessibilityLabel: "swap", style: .stackedBars,
                duration: 600, showsLegend: false, showsTimelineLabels: false, showsTooltip: false,
                horizontalInset: 8, verticalInset: 0, showsSamplingDetails: false,
                bucketing: .history, drawsZero: drawsZero)
        }
        let drawn = try Self.render(chart(drawsZero: true)), skipped = try Self.render(chart(drawsZero: false))
        func isBar(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return color.greenComponent > 0.5 && color.redComponent < 0.3 && color.blueComponent < 0.3
        }
        let bottom = try XCTUnwrap((0..<drawn.pixelsHigh).reversed().first { y in
            (0..<drawn.pixelsWide).contains { isBar(drawn, $0, y) }
        }, "The bars reach the baseline")
        func runs(_ bitmap: NSBitmapImageRep) -> Int {
            var count = 0, inside = false
            for x in 0..<bitmap.pixelsWide {
                let bar = isBar(bitmap, x, bottom)
                if bar && !inside { count += 1 }
                inside = bar
            }
            return count
        }
        XCTAssertEqual(runs(drawn), 120, "A zero is a 1 pt bar by default")
        XCTAssertEqual(runs(skipped), 60, "Only the 50 % buckets")
        // The 50 % bars are the same in both.
        let middle = bottom - Int(Self.size.height) / 2 + 4
        XCTAssertEqual((0..<drawn.pixelsWide).filter { isBar(drawn, $0, middle) },
                       (0..<skipped.pixelsWide).filter { isBar(skipped, $0, middle) })
    }
    #endif

    func testTheOlderSensorPageUsesIStatsTemperatureScale() throws {
        let points = [80.0, 104.0].enumerated().map { index, celsius in
            MenuBarTelemetryPoint(date: Date(timeIntervalSince1970: Self.t0 + Double(index)), cpuTotal: nil,
                                  cpuUser: nil, cpuSystem: nil, gpu: nil, memory: nil, chipTemperature: celsius,
                                  fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil)
        }
        let summary = MenuBarTelemetryWindowSummary(points: points)
        XCTAssertEqual(summary.temperaturePeak, 104)
        XCTAssertNil(MenuBarTelemetryWindowSummary(points: []).temperaturePeak)
        XCTAssertEqual(GeekSensorMetricHoverDetail.displayedValueRange(0...100, unit: .temperature,
                                                                       peak: summary.temperaturePeak), 0...110)
        XCTAssertEqual(GeekSensorMetricHoverDetail.displayedValueRange(0...100, unit: .temperature, peak: 80), 0...100)
        // A folded minute counts with its peak, not its representative sample.
        func sample(_ offset: TimeInterval, _ celsius: Double) -> MenuBarTelemetryPoint {
            MenuBarTelemetryPoint(date: Date(timeIntervalSince1970: Self.t0 + offset), cpuTotal: nil, cpuUser: nil,
                                  cpuSystem: nil, gpu: nil, memory: nil, chipTemperature: celsius, fanRPM: nil,
                                  downBytesPerSecond: nil, upBytesPerSecond: nil)
        }
        let minute = sample(0, 80).standingForBucket(replacing: sample(-30, 104), gaps: [])
        XCTAssertEqual(minute.chipTemperature, 80)
        XCTAssertEqual(MenuBarTelemetryWindowSummary(points: [minute]).temperaturePeak, 104)
        let source = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarTertiaryDetail.swift")
        XCTAssertFalse(source.contains("valueRange: 20...110"))
        XCTAssertTrue(source.contains("0...100, unit: .temperature, peak: summary.temperaturePeak)"))
    }

    #if DEBUG || STORAGE_CLEANER_BETA
    func testTheDemoHistoryRecordsTheSwapShare() {
        // The default fixture: 3.6 of 4 GiB of swap files in use.
        let telemetry = MiniWindowDemoData.makeFixture(arguments: []).telemetry
        let shares = telemetry.compactMap(\.swapUsedPercent)
        XCTAssertFalse(shares.isEmpty)
        XCTAssertEqual(shares.count, telemetry.filter { $0.swapUsedBytes != nil }.count)
        XCTAssertTrue(shares.allSatisfy { abs($0 - 90) < 0.001 }, "\(shares.prefix(3))")
        // The short recording keeps it.
        XCTAssertEqual(MiniWindowDemoData.shortRecordingPoints(from: telemetry).map(\.swapUsedPercent),
                       telemetry.suffix(90).map(\.swapUsedPercent))
    }
    #endif

    // MARK: - Fixtures

    private static let size = CGSize(width: 375, height: 100)

    private static func memory(used: Int64, total: Int64, read: Bool = true) -> MemorySnapshot {
        let measurements: MemoryMeasurements? = read ? nil : {
            let base = MemoryMeasurements.legacyAvailable(physicalBytes: 16 * gibibyte, appBytes: 0, wiredBytes: 0,
                                                          compressedBytes: 0, cachedBytes: 0, swapUsedBytes: 0)
            return MemoryMeasurements(pressure: base.pressure, physicalBytes: base.physicalBytes,
                                      availableBytes: base.availableBytes, appBytes: base.appBytes,
                                      wiredBytes: base.wiredBytes, compressedBytes: base.compressedBytes,
                                      cachedBytes: base.cachedBytes,
                                      swapUsedBytes: .unavailable(.unavailable, reason: "fixture"),
                                      swapInRate: base.swapInRate, swapOutRate: base.swapOutRate)
        }()
        return MemorySnapshot(generatedAt: Date(timeIntervalSince1970: t0), physicalBytes: 16 * gibibyte,
                              freeBytes: 0, inactiveBytes: 0, speculativeBytes: 0, fileBackedBytes: 0,
                              purgeableBytes: 0, wiredBytes: 0, compressedBytes: 0, swapUsedBytes: used,
                              pressureFreePercentage: nil, pressureSummary: "", topProcesses: [],
                              swapTotalBytes: total, measurements: measurements)
    }

    #if DEBUG
    private static func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .environment(\.menuBarChartsPreparedInline, true)
            .environment(\.miniWindowPreviewDate, Date(timeIntervalSince1970: t0))
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 2))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
    #endif
}
