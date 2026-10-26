import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D132 (R8c): iStat Menus 7.30's battery graphs. The battery menu's graph
/// (`BBRBatteryMenuBatteryGraphSection drawRect:`) draws the newest 69
/// buckets of 15 minutes, the battery history
/// (`BBRMenuBatteryHistoryGraphSection`) 96 buckets of its window's tier.
/// Both end at floor(now / iv) · iv, take a bucket's mean charge, draw it in
/// the charging color when at least half of it was on AC, fill an empty
/// bucket with its newer neighbor's value (at most eight beyond 900 s) and
/// run an 8 pt rail under the charging bars, with the charging icon on a rail
/// of at least 11 pt. Fixtures only: no sampling, window or user data.
@MainActor
final class MiniWindowIStatBatteryGraphTests: XCTestCase {
    /// A multiple of every battery tier (their least common multiple is
    /// 2 797 200 s), so the newest closed bucket at `t0` ends at `t0`.
    private static let t0: TimeInterval = 650 * 2_797_200
    private static let historySize = CGSize(width: 303, height: 142)

    private static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: t0 + offset)
    }

    func testTheBatteryHistoryOffersIStatsSevenWindowsAndTiers() {
        XCTAssertEqual(GeekIStatBatteryGraph.historyRanges,
                       [.oneHour, .threeHours, .sixHours, .twelveHours, .oneDay, .threeDays, .sevenDays],
                       "loadTimePopup")
        XCTAssertEqual(GeekIStatBatteryGraph.defaultHistoryRange, .oneDay, "setInterval: 900")
        XCTAssertEqual(GeekIStatBatteryGraph.historyRanges.map { GeekIStatBatteryGraph.history.interval(for: $0.duration) },
                       [37, 112, 225, 450, 900, 2_700, 6_300])
        XCTAssertEqual(GeekIStatBatteryGraph.history.barCount, 96, "sampleCount 0x60")
        XCTAssertEqual(GeekIStatBatteryGraph.menu.barCount, 69)
        for range in GeekChartRange.allCases {
            XCTAssertEqual(GeekIStatBatteryGraph.menu.interval(for: range.duration), 900, "\(range)")
        }
        // One bucket more than drawn: the one closing at the reference.
        XCTAssertEqual(GeekIStatBatteryGraph.history.span(for: GeekChartRange.oneDay.duration), 97 * 900)
        XCTAssertEqual(GeekIStatBatteryGraph.menu.span(for: 0), 70 * 900)
        // A window the submenu does not offer reads as the nearest it does.
        for range in GeekIStatBatteryGraph.historyRanges {
            XCTAssertEqual(GeekIStatBatteryGraph.historyRange(range), range)
        }
        XCTAssertEqual(GeekIStatBatteryGraph.historyRange(.tenMinutes), .oneHour)
        XCTAssertEqual(GeekIStatBatteryGraph.historyRange(.fourteenDays), .sevenDays)
        XCTAssertEqual(GeekIStatBatteryGraph.historyRange(.twentyEightDays), .sevenDays)
    }

    func testAnEmptyBucketTakesItsNewerNeighborsValue() {
        func flat(_ filled: [(value: Int, isFill: Bool)?]) -> [String] {
            filled.map { $0.map { "\($0.value)\($0.isFill ? "*" : "")" } ?? "-" }
        }
        // Oldest first; the newest bucket has nothing newer to take.
        XCTAssertEqual(flat(GeekIStatBatteryGraph.filled([1, nil, nil, 4, nil], interval: 900)),
                       ["1", "4*", "4*", "4", "-"])
        // Buckets of 900 s and less without limit.
        let long: [Int?] = Array(repeating: nil, count: 30) + [5]
        XCTAssertNil(GeekIStatBatteryGraph.fillLimit(interval: 37))
        XCTAssertNil(GeekIStatBatteryGraph.fillLimit(interval: 900))
        XCTAssertEqual(flat(GeekIStatBatteryGraph.filled(long, interval: 900)),
                       Array(repeating: "5*", count: 30) + ["5"])
        // Longer ones at most eight (`interval > 900 && count > 7`).
        XCTAssertEqual(GeekIStatBatteryGraph.fillLimit(interval: 2_700), 8)
        XCTAssertEqual(flat(GeekIStatBatteryGraph.filled(long, interval: 2_700)),
                       Array(repeating: "-", count: 22) + Array(repeating: "5*", count: 8) + ["5"])
        // The count restarts at an empty bar only, not at a recorded one.
        let split: [Int?] = [nil, nil, nil, nil, 7, nil, nil, nil, nil, nil, 9]
        XCTAssertEqual(flat(GeekIStatBatteryGraph.filled(split, interval: 6_300)),
                       ["-", "7*", "7*", "7*", "7", "9*", "9*", "9*", "9*", "9*", "9"])
        // Nothing before our first record (iStat reads the powerlog there).
        XCTAssertEqual(flat(GeekIStatBatteryGraph.filled([nil, nil, 3], interval: 900, oldestFillable: 1)),
                       ["-", "3*", "3"])
    }

    func testABucketIsTheMeanChargeOnACWhenAtLeastHalfOfItWas() throws {
        // 1 hour, 37 s a bucket; `k` counts buckets from the newest.
        var points = [
            power(-30, 50, .acPower, charging: true), power(-20, 60, .acPower, charging: true),
            power(-10, 70, .batteryPower),                                   // k = 0: 60 %, 2/3 on AC
            power(-60, 40, .acPower), power(-50, 42, .batteryPower),         // k = 1: 41 %, 1/2
            power(-100, 30, .acPower), power(-95, 32, .batteryPower), power(-90, 34, .batteryPower), // k = 2: 1/3
            power(-120, 20, .unknown),                                       // k = 3: source unknown
            power(-170, 80, .batteryPower), power(-160, 80, .batteryPower),  // k = 4, with a folded minute:
        ]
        var minute = power(-150, 41, .acPower)                               // its last charge; its mean is 40
        minute.bucketStatistics = MenuBarHistoryStatistics(metrics: ["charge": Self.folded(40, count: 30, end: Self.date(-150))])
        points.append(minute)
        let frame = try preparedFrame(points.sorted { $0.date < $1.date }, graph: .history, duration: 3_600)
        func bucket(_ k: Double) throws -> GeekPreparedPowerBucket {
            try XCTUnwrap(frame.buckets.first { $0.bucket.end == Self.date(-37 * k) }, "k = \(k)")
        }
        XCTAssertEqual(try bucket(0).payload.value, 60, accuracy: 1e-9)
        XCTAssertEqual(try bucket(0).payload.powerSource, .acPower)
        XCTAssertEqual(try bucket(0).payload.isCharging, true, "The latest sample on the bucket's source")
        XCTAssertEqual(try bucket(1).payload.value, 41, accuracy: 1e-9)
        XCTAssertEqual(try bucket(1).payload.powerSource, .acPower, "≥ 0.5 is the charging color")
        XCTAssertEqual(try bucket(2).payload.value, 32, accuracy: 1e-9)
        XCTAssertEqual(try bucket(2).payload.powerSource, .batteryPower)
        XCTAssertEqual(try bucket(3).payload.value, 20, accuracy: 1e-9)
        XCTAssertNil(try bucket(3).payload.powerSource)
        // The folded minute counts as its 30 samples of mean 40, for the
        // charge and the source (30 of 32 on AC; one point each would be 1
        // of 3, and its last charge, 41, would give 43.4375).
        XCTAssertEqual(try bucket(4).payload.value, (40 * 30 + 80 + 80) / 32, accuracy: 1e-9)
        XCTAssertEqual(try bucket(4).payload.powerSource, .acPower)
        XCTAssertFalse(frame.buckets.contains(where: \.isEstimated))
        // The bucket collecting samples at the reference is not drawn.
        XCTAssertEqual(frame.buckets.map(\.bucket.end).max(), Self.date(0))
    }

    func testAFilledBucketKeepsTheNewerValueAndNothingPrecedesTheFirstRecord() throws {
        // 1 day, 900 s a bucket: records in k = 6 and k = 2. The newest two
        // stay empty, k = 3…5 take k = 2's charge and source, and nothing
        // older than the first record (k = 6) is filled, without a limit.
        let day = try preparedFrame([power(-900 * 6 - 100, 70, .batteryPower), power(-900 * 2 - 100, 50, .acPower)],
                                    graph: .history, duration: 86_400)
        XCTAssertEqual(day.buckets.map { $0.bucket.end.timeIntervalSince(Self.date(0)) },
                       [-5_400, -4_500, -3_600, -2_700, -1_800])
        XCTAssertEqual(day.buckets.map(\.payload.value), [70, 50, 50, 50, 50])
        XCTAssertEqual(day.buckets.map(\.payload.powerSource), [.batteryPower, .acPower, .acPower, .acPower, .acPower])
        XCTAssertEqual(day.buckets.map(\.isEstimated), [false, true, true, true, false])

        // 3 days, 2700 s a bucket: ten empty between k = 12 and k = 1, the
        // newest eight filled.
        let threeDays = try preparedFrame([power(-2_700 * 12 - 100, 30, .batteryPower),
                                           power(-2_700 - 100, 80, .acPower)],
                                          graph: .history, duration: 3 * 86_400)
        XCTAssertEqual(threeDays.buckets.map { Int(-$0.bucket.end.timeIntervalSince(Self.date(0)) / 2_700) },
                       [12, 9, 8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(threeDays.buckets.filter(\.isEstimated).count, 8)

        // The battery menu: 69 buckets of 900 s, filled without limit.
        let menu = try preparedFrame([power(-900 * 60 - 100, 90, .batteryPower), power(-900 * 3 - 100, 40, .acPower)],
                                     graph: .menu, duration: GeekPowerLayout.menuGraphDuration)
        XCTAssertEqual(menu.buckets.count, 58, "k = 60 … 3")
        XCTAssertEqual(menu.buckets.filter(\.isEstimated).count, 56)
        XCTAssertEqual(menu.rawBuckets.count, 69)
        XCTAssertEqual(menu.rawBuckets.last?.end, Self.date(0))
        XCTAssertEqual(menu.rawBuckets.first?.end, Self.date(-900 * 68))
    }

    func testTheOldestBarKeepsItsSamplesHalfwayIntoABucket() throws {
        // Halfway into a bucket the graphs still end at t0 and select one
        // bucket more than they draw, so the oldest bar keeps the samples
        // before now − 69 · 900.
        let menu = try preparedFrame([power(-900 * 69 + 100, 60, .batteryPower)], graph: .menu,
                                     duration: GeekPowerLayout.menuGraphDuration, reference: 450)
        XCTAssertEqual(menu.rawBuckets.last?.end, Self.date(0))
        XCTAssertEqual(menu.buckets.map(\.bucket.end), [Self.date(-900 * 68)])
        XCTAssertEqual(menu.buckets.map(\.payload.value), [60])
        XCTAssertEqual(GeekIStatBatteryGraph.menu.span(for: GeekPowerLayout.menuGraphDuration), 70 * 900)
        XCTAssertEqual(GeekIStatBatteryGraph.history.span(for: 3_600), 97 * 37)
        XCTAssertEqual(GeekIStatBatteryGraph.history.span(for: 7 * 86_400), 97 * 6_300)
    }

    func testTheGraphsPlaceIStatsBarsInTheCard() throws {
        for scale in [CGFloat(1), 2] {
            // The battery menu: the 240 pt menu's 224 pt card, the chart 64
            // tall from 8, so bars 8…60 and the rail 64…72 in the card.
            let menu = GeekPowerHistoryChart.batteryGraphGeometry(.menu, size: CGSize(width: 224, height: 64),
                                                                  displayScale: scale)
            XCTAssertEqual(menu.plot, CGRect(x: 10, y: 0, width: 206, height: 52), "\(scale)x")
            XCTAssertEqual(menu.rail, CGRect(x: 10, y: 56, width: 206, height: 8), "\(scale)x")
            // The battery history: the 303 pt card, the plot block 142 tall
            // from 30, so bars 30…160 and the rail 164…172.
            let history = GeekPowerHistoryChart.batteryGraphGeometry(.history, size: Self.historySize,
                                                                     displayScale: scale)
            XCTAssertEqual(history.plot, CGRect(x: 8, y: 0, width: 287, height: 130), "\(scale)x")
            XCTAssertEqual(history.rail, CGRect(x: 8, y: 134, width: 287, height: 8), "\(scale)x")
            // Bars [x − 2, x], 3 pt apart, the newest ending at W − 8.
            for (graph, plot, left, right) in [(GeekIStatBatteryGraph.menu, menu.plot, CGFloat(10), CGFloat(216)),
                                               (.history, history.plot, 8, 295)] {
                let buckets = GeekIStatHistoryBuckets.buckets(
                    dates: [], interval: graph.interval(for: 86_400), count: graph.barCount,
                    plotRect: plot, referenceDate: Self.date(0), displayScale: scale)
                XCTAssertEqual(buckets.count, graph.barCount, "\(graph) \(scale)x")
                XCTAssertEqual(try XCTUnwrap(buckets.first).x - 1, left, "\(graph) \(scale)x")
                XCTAssertEqual(try XCTUnwrap(buckets.last).x + 1, right, "\(graph) \(scale)x")
                XCTAssertEqual(buckets[1].x - buckets[0].x, 3, "\(graph) \(scale)x")
                XCTAssertEqual(buckets.last?.end, Self.date(0))
            }
        }
        XCTAssertEqual(GeekIStatSectionGeometry.chargeChartTop, 8)
        XCTAssertEqual(GeekIStatSectionGeometry.chargeChartHeight - GeekIStatSectionGeometry.chargeChartBottomInset, 72)
        XCTAssertEqual(GeekPanelPresentationMetrics.powerDetailWidth - 2 * MiniWindowStyleTokens.contentInset, 224)
        XCTAssertEqual(GeekIStatHistoryGeometry.batteryPageSize, CGSize(width: 319, height: 196), "setWidth: 0x13f")
        XCTAssertEqual(GeekIStatHistoryGeometry.batteryCardHeight, 180, "setHeight: 0xb4")
        XCTAssertEqual(GeekIStatHistoryGeometry.batteryPlotTop, 30)
        XCTAssertEqual(GeekIStatHistoryGeometry.batteryCardHeight - GeekIStatHistoryGeometry.batteryPlotTop
                       - MiniWindowStyleTokens.contentInset, Self.historySize.height)
        XCTAssertEqual(GeekPowerHistoryScale.iStatIconMinimumRailWidth, 11)
    }

    // D147: rendered with the offscreen hook, compiled with DEBUG only.
    #if DEBUG
    func testTheRailRunsUnderTheChargingBarsWithTheIconFromElevenPoints() throws {
        // 1 hour, one sample in each bucket: the newest four on AC (a rail of
        // 4 × 3 − 1 = 11 pt, with the icon), k = 10…12 on AC (8 pt, none).
        let onAC: Set<Int> = [0, 1, 2, 3, 10, 11, 12]
        let points = (0..<96).reversed().map { k in
            power(-37 * Double(k) - 18, 50 + Double(k % 10), onAC.contains(k) ? .acPower : .batteryPower)
        }
        let chart = GeekPowerHistoryChart(points: points, metric: .charge, duration: 3_600,
                                          tint: Color(red: 0, green: 1, blue: 0),
                                          chargingTint: Color(red: 0, green: 0, blue: 1),
                                          accessibilityLabel: "battery", showsTimelineLabels: false,
                                          batteryGraph: .history)
        let bitmap = try Self.render(chart, size: Self.historySize)
        XCTAssertEqual(bitmap.pixelsWide, 606)
        func color(_ x: CGFloat, _ y: CGFloat) throws -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        func isRail(_ x: CGFloat) throws -> Bool {
            let pixel = try color(x, 138)
            return pixel.g > 0.8 && pixel.r < 0.2 && pixel.b < 0.2
        }
        // k = 10…12: slots 83…85, [257, 265].
        XCTAssertTrue(try isRail(257.2))
        XCTAssertTrue(try isRail(261))
        XCTAssertTrue(try isRail(264.6))
        XCTAssertFalse(try isRail(256.6))
        XCTAssertFalse(try isRail(265.6))
        XCTAssertFalse(try isRail(200), "No rail under bars on battery")
        // k = 0…3: slots 92…95, [284, 295]; the icon covers its center.
        XCTAssertTrue(try isRail(284.2))
        XCTAssertTrue(try isRail(294.6))
        XCTAssertFalse(try isRail(289.5), "The charging icon")
        // The bars: on AC the charging color, on battery the draining one,
        // from the top (100 %) to the baseline at 130.
        let charging = try color(294, 129.6), draining = try color(158 + 1, 129.6)
        XCTAssertTrue(charging.g > 0.8 && charging.b < 0.2, "\(charging)")
        XCTAssertTrue(draining.b > 0.8 && draining.g < 0.2, "\(draining)")
        XCTAssertTrue(try color(294, 131).g < 0.2, "Nothing between the bars and the rail")
        // The icon's mask cuts the rail around the bolt (destination-out), so
        // the card shows through beside it, 0.75 pt left of the bolt's
        // leftmost corner (286.5, 138.5): the gray between the bars and the
        // rail, not the rail and not black.
        let card = try Self.render(chart, size: Self.historySize,
                                   background: Color(red: 0.5, green: 0.5, blue: 0.5))
        func cardColor(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try XCTUnwrap(card.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
        }
        let cut = try cardColor(285.75, 138.75), backdrop = try cardColor(294, 132)
        XCTAssertGreaterThan(backdrop.greenComponent, 0.4, "\(backdrop)")
        XCTAssertEqual(cut.alphaComponent, 1, accuracy: 0.01, "\(cut)")
        XCTAssertEqual(cut.redComponent, backdrop.redComponent, accuracy: 0.03, "\(cut) \(backdrop)")
        XCTAssertEqual(cut.greenComponent, backdrop.greenComponent, accuracy: 0.03, "\(cut) \(backdrop)")
        XCTAssertEqual(cut.blueComponent, backdrop.blueComponent, accuracy: 0.03, "\(cut) \(backdrop)")
    }
    #endif

    func testFilledBucketsLookMeasuredAndTheTooltipIsIStats() throws {
        let source = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        let chart = try XCTUnwrap(source.components(separatedBy: "struct GeekPowerHistoryChart: View {").last?
            .components(separatedBy: "struct GeekFanHoverDetail: View {").first)
        XCTAssertTrue(chart.contains("estimated: showsEstimate(prepared)"))
        XCTAssertTrue(chart.contains("batteryGraph == nil && prepared.isEstimated"))
        XCTAssertTrue(chart.contains("title: batteryGraph != nil ? L10n.text(\"数值\", \"Value\")"))
        XCTAssertTrue(chart.contains("isEstimated: batteryGraph == nil && hoveredPoint.isEstimated"))
        XCTAssertTrue(chart.contains("detail: batteryGraph != nil ? nil : metric.tooltipDetail("))
        XCTAssertTrue(chart.contains("if batteryGraph == nil {\n                GeekChartDrawing.gaps("), "No gap block")
        // A frame is prepared again when a bucket closes, not every second.
        let history = GeekPowerHistoryChart(points: [], metric: .charge, duration: 3_600, tint: .green,
                                            accessibilityLabel: "", batteryGraph: .history)
        XCTAssertEqual(history.clockRevision(at: Self.date(36)), history.clockRevision(at: Self.date(1)))
        XCTAssertEqual(history.clockRevision(at: Self.date(37)), history.clockRevision(at: Self.date(1)) + 1)
        let projection = GeekPowerHistoryChart(points: [], metric: .charge, duration: 3_600, tint: .green,
                                               accessibilityLabel: "")
        XCTAssertEqual(projection.clockRevision(at: Self.date(1)), Self.t0 + 1)
    }

    func testTheBatteryWindowIsOneDayAtFirstAndOneIStatOffers() throws {
        let suiteName = TestPreferenceDomain.makeSuite()
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        defer { TestPreferenceDomain.cleanup(suiteName: suiteName) }
        let settings = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        XCTAssertEqual(settings.geekChartRange(for: .battery, fallbackTo: .power), .oneDay)
        settings.setGeekChartRange(.sixHours, for: PanelSection.power)
        XCTAssertEqual(settings.geekChartRange(for: .battery, fallbackTo: .power), .oneDay, "Not the page's range")
        XCTAssertEqual(settings.geekChartRange(for: .energy, fallbackTo: .power), .sixHours, "Other metrics keep it")
        settings.setGeekChartRange(.fourteenDays, for: .battery)
        XCTAssertEqual(settings.geekChartRange(for: .battery, fallbackTo: .power), .sevenDays)
        settings.setGeekChartRange(.tenMinutes, for: .battery)
        XCTAssertEqual(settings.geekChartRange(for: .battery, fallbackTo: .power), .oneHour)
        settings.setGeekChartRange(.threeHours, for: .battery)
        XCTAssertEqual(settings.geekChartRange(for: .battery, fallbackTo: .power), .threeHours)
    }

    // MARK: - Fixtures

    private func power(_ offset: TimeInterval, _ charge: Double, _ source: BatteryPowerSource,
                       charging: Bool = false) -> MenuBarPowerHistoryPoint {
        MenuBarPowerHistoryPoint(date: Self.date(offset), chargePercent: charge, batteryPowerWatts: nil,
                                 isCharging: charging, powerSource: source)
    }

    private func preparedFrame(_ points: [MenuBarPowerHistoryPoint], graph: GeekIStatBatteryGraph,
                               duration: TimeInterval, reference: TimeInterval = 0) throws -> GeekPreparedPowerFrame {
        let size = graph == .menu ? CGSize(width: 224, height: 64) : Self.historySize
        let plot = GeekPowerHistoryChart.batteryGraphGeometry(graph, size: size, displayScale: 2).plot
        let kernel = GeekPowerPreparationKernel(points: points, metric: .charge, duration: duration,
                                                displayScale: 2, batteryGraph: graph)
        return GeekPreparedPowerFrame(kernel: kernel, plot: plot, reference: Self.date(reference))
    }

    /// `count` samples of `value`, one a second, the last at `end`.
    private static func folded(_ value: Double, count: Int, end: Date) -> MenuBarHistoryStatistic {
        func sample(_ index: Int) -> MenuBarHistoryStatistic {
            let date = end.addingTimeInterval(Double(index - count + 1))
            return MenuBarHistoryStatistic(value: value, date: date,
                                           coverage: [DateInterval(start: date.addingTimeInterval(-1), end: date)])
        }
        return (1..<count).reduce(sample(0)) { $0.merging(sample($1)) }
    }

    #if DEBUG
    private static func render<V: View>(_ view: V, size: CGSize,
                                        background: Color = .black) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view
            .frame(width: size.width, height: size.height)
            .background(background)
            .environment(\.menuBarChartsPreparedInline, true)
            .environment(\.miniWindowPreviewDate, date(0))
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 2))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }
    #endif
}
