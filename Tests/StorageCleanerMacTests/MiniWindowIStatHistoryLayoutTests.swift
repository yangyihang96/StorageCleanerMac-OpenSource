#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D121: the history pages (level three) follow iStat Menus 7.30's history
/// submenus (`BBRMenuHistorySubmenu…`): a 375 × 200 graph card in a 391 pt
/// window, the plot from 25 to 8 pt above the bottom, 120 bars of 2 + 1 pt,
/// the tooltip beside the indicator. Renders the production pages offscreen
/// with the demo history: no sampling, window or user data.
@MainActor
final class MiniWindowIStatHistoryLayoutTests: XCTestCase {
    private static let card = MiniWindowStyleTokens.historyWidth - 2 * MiniWindowStyleTokens.contentInset

    func testTheGraphCardHasIStatsGeometry() throws {
        XCTAssertEqual(MiniWindowStyleTokens.historyWidth, 391, "setWidth: 0x187")
        XCTAssertEqual(Self.card, 375)
        XCTAssertEqual(MiniWindowStyleTokens.historyCardHeight, 200)
        XCTAssertEqual(MiniWindowStyleTokens.historyHeight, 216, "8 + 200 + 8")
        XCTAssertEqual(MiniWindowStyleTokens.historyPlotTop, 25)
        XCTAssertEqual(MiniWindowStyleTokens.historyPlotHeight, 167, "H − 33")
        XCTAssertEqual(MiniWindowStyleTokens.historyChartHeight + GeekHistoryAxisFooter.height,
                       MiniWindowStyleTokens.historyPlotHeight, "Our axis row stays inside the plot block")

        // 8 + 359 + 8: exactly 120 bars of 3 pt, the oldest from the plot's
        // leading edge, the newest ending at its trailing edge.
        let plot = CGRect(x: MiniWindowStyleTokens.historyChartInset, y: 0,
                          width: Self.card - 2 * MiniWindowStyleTokens.historyChartInset,
                          height: MiniWindowStyleTokens.historyChartHeight)
        XCTAssertEqual(plot.width, 359)
        let end = Date(timeIntervalSince1970: 1_000_000)
        let range = (start: end.addingTimeInterval(-3_600), end: end, dataStart: end.addingTimeInterval(-3_600))
        for scale in [CGFloat(1), 2] {
            XCTAssertEqual(GeekChartWindow.barSlotCount(in: plot, displayScale: scale), 120, "\(scale)x")
            let buckets = GeekChartWindow.barBucketSnapshots(for: [end.addingTimeInterval(-10)], in: plot,
                                                             range: range, displayScale: scale)
            XCTAssertEqual(buckets.count, 120)
            let first = try XCTUnwrap(buckets.first), last = try XCTUnwrap(buckets.last)
            XCTAssertEqual(first.x - GeekChartWindow.barMarkWidth / 2, plot.minX, accuracy: 0.001, "\(scale)x")
            XCTAssertEqual(last.x + GeekChartWindow.barMarkWidth / 2, plot.maxX, accuracy: 0.001, "\(scale)x")
            XCTAssertEqual(buckets[1].x - buckets[0].x, 3, accuracy: 0.001)
            XCTAssertEqual(last.end.timeIntervalSince(last.start), 30, accuracy: 0.001, "1 hour / 120: iStat's 30 s bar")
        }
    }

    func testEachHistoryPageIsTheCardAndItsSections() {
        // The graph card, then the untitled rows (8 + 17n) 7 pt below it.
        func height(rows: Int) -> CGFloat { rows == 0 ? 216 : 216 + 7 + 8 + 17 * CGFloat(rows) }
        let sizes: [(String, CGSize, CGFloat)] = [
            ("cpu", GeekProcessorActivityHoverDetail.popoverSize, height(rows: 0)),
            // D122 (2026-10-18): the CPU usage page is a history page: user,
            // system and total, and the load row when opened from it.
            ("cpu usage", GeekProcessorUsageHoverDetail.popoverSize(showsLoad: false), height(rows: 3)),
            ("cpu usage, load", GeekProcessorUsageHoverDetail.popoverSize(showsLoad: true), height(rows: 4)),
            ("network", GeekNetworkHistoryHoverDetail.popoverSize, height(rows: 2)),
            ("gpu", GeekGPUHoverDetail.popoverSize, height(rows: 3)),
            ("memory pressure", GeekMemoryHistoryHoverDetail.popoverSize, height(rows: 1)),
            ("swap", GeekSwapHoverDetail.popoverSize, 216 + 7 + 40),
            ("disk i/o", GeekDiskIOHoverDetail.popoverSize, height(rows: 2)),
            ("disk read/write", GeekDiskThroughputHoverDetail.popoverSize, height(rows: 1)),
            ("memory composition", GeekMemoryCompositionHistoryDetail.preferredSize, height(rows: 4)),
            ("fan", GeekFanHoverDetail.popoverSize(selectedFanIndex: 0, readingCount: 2), height(rows: 3)),
            ("fans, one", GeekFanHoverDetail.popoverSize(selectedFanIndex: nil, readingCount: 1), height(rows: 1)),
            ("fans, five", GeekFanHoverDetail.popoverSize(selectedFanIndex: nil, readingCount: 5), height(rows: 2)),
            ("sensor", GeekSensorMetricHoverDetail.popoverSize(extraRowCount: 0, hasNote: false), height(rows: 0)),
            ("sensor, rows", GeekSensorMetricHoverDetail.popoverSize(extraRowCount: 2, hasNote: true), height(rows: 3)),
        ]
        for (name, size, expected) in sizes {
            XCTAssertEqual(size.width, 391, name)
            XCTAssertEqual(size.height, expected, name)
        }
        // D132 (2026-10-19): iStat's battery history submenu is its own 319
        // wide, the 180 pt graph card in the 8 pt inset; was
        // ("battery", GeekBatteryHistoryHoverDetail.popoverSize, height(rows: 0)) at 391.
        XCTAssertEqual(GeekBatteryHistoryHoverDetail.popoverSize, CGSize(width: 319, height: 196))
        XCTAssertEqual(GeekHoverDetailMetrics.historySize, CGSize(width: 391, height: 216))
        XCTAssertEqual(GeekSensorPowerHoverDetailMetrics.sensorHistorySize, GeekHoverDetailMetrics.historySize)
        XCTAssertEqual(GeekHoverDetailMetrics.diskIOSize, GeekDiskIOHoverDetail.popoverSize)
    }

    /// The rendered pages, hosted as the level-three column hosts them (the
    /// page's 8 pt inset around content that provides none), are exactly
    /// their popover sizes, in both languages.
    func testRenderedHistoryPagesMatchTheirPopoverSizes() throws {
        // The demo's hour at its own reference date (`render` pins the
        // charts' clock there): one sample in each of the 120 bars.
        let points = MiniWindowDemoData.fixture.telemetry
        let diskPoints = MiniWindowDemoData.nativeDiskIOHistory
        let powerPoints = (0..<121).map { index in
            MenuBarPowerHistoryPoint(date: MiniWindowDemoData.referenceDate.addingTimeInterval(-3_600 + Double(index) * 30),
                                     chargePercent: 85 - Double(index) * 5 / 120, batteryPowerWatts: -8,
                                     isCharging: false, powerSource: .batteryPower)
        }
        let colors = EnvironmentValues().panelMetricColors
        let pressure = MiniWindowDemoData.memorySnapshot.reportablePressureLevel
        // D122: the demo's points carry each fan's reading, as live ones do.
        let fans = try XCTUnwrap(points.last?.fanReadings)
        XCTAssertFalse(fans.isEmpty)
        for language in [AppLanguage.zhHans, .english] {
            let scope = HistoryLayoutLanguageScope(language)
            defer { scope.restore() }
            let pages: [(String, AnyView, CGSize)] = [
                ("cpu", AnyView(GeekProcessorActivityHoverDetail(points: points, duration: 3_600,
                                                                  userValue: "22%", systemValue: "12%")),
                 GeekProcessorActivityHoverDetail.popoverSize),
                // D122 (2026-10-18): the CPU usage page, opened from the load row.
                ("cpu usage", AnyView(GeekProcessorUsageHoverDetail(total: 34, applications: 22, system: 12,
                                                                    points: points, duration: 3_600,
                                                                    loadAverage: "1.92 1.78 1.66")),
                 GeekProcessorUsageHoverDetail.popoverSize(showsLoad: true)),
                ("network", AnyView(GeekNetworkHistoryHoverDetail(points: points, duration: 3_600,
                                                                  uploadValue: "410 KB/s", downloadValue: "3.6 MB/s")),
                 GeekNetworkHistoryHoverDetail.popoverSize),
                ("gpu", AnyView(GeekGPUHoverDetail(points: points, duration: 3_600, isAvailable: true,
                                                   currentValue: "18%", memoryValue: "9%", temperatureValue: nil)),
                 GeekGPUHoverDetail.popoverSize),
                ("swap", AnyView(GeekSwapHoverDetail(snapshot: MiniWindowDemoData.memorySnapshot, points: points,
                                                     duration: 3_600)),
                 GeekSwapHoverDetail.popoverSize),
                ("memory pressure", AnyView(GeekMemoryHistoryHoverDetail(
                    points: points, duration: 3_600, currentValue: "62%",
                    pressure: pressure == .critical ? L10n.text("高", "High")
                        : pressure == .elevated ? L10n.text("升高", "Elevated") : L10n.text("正常", "Normal"),
                    snapshot: MiniWindowDemoData.memorySnapshot)),
                 GeekMemoryHistoryHoverDetail.popoverSize),
                ("composition", AnyView(GeekMemoryCompositionHistoryDetail(
                    points: points, duration: 3_600, composition: MiniWindowDemoData.memorySnapshot.ringComposition)),
                 GeekMemoryCompositionHistoryDetail.preferredSize),
                ("disk io", AnyView(GeekDiskIOHoverDetail(points: diskPoints,
                                                          counters: MiniWindowDemoData.nativeDiskIOCounters,
                                                          duration: 3_600)),
                 GeekDiskIOHoverDetail.popoverSize),
                ("disk read", AnyView(GeekDiskThroughputHoverDetail(points: diskPoints,
                                                                    counters: MiniWindowDemoData.nativeDiskIOCounters,
                                                                    duration: 3_600, mode: .read)),
                 GeekDiskThroughputHoverDetail.popoverSize),
                // As the power page passes them (GeekPowerView).
                ("battery", AnyView(GeekBatteryHistoryHoverDetail(points: powerPoints, tint: colors.batteryCharging,
                                                                  chargingTint: colors.batteryDraining)),
                 GeekBatteryHistoryHoverDetail.popoverSize),
                ("sensor", AnyView(GeekSensorMetricHoverDetail(
                    title: "CPU", currentValue: "53°C", points: points, channel: .chipTemperature,
                    unit: .temperature, valueRange: 0...100, tint: .orange, duration: 3_600,
                    secondaryTitle: "Load", secondaryValue: "18%", note: "Named from its key"
                 )),
                 GeekSensorMetricHoverDetail.popoverSize(extraRowCount: 1, hasNote: true)),
                ("sensor, unavailable", AnyView(GeekSensorMetricHoverDetail(
                    title: "GPU", currentValue: "—", points: [], channel: nil,
                    unit: .temperature, valueRange: 0...100, tint: .orange, duration: 3_600
                 )),
                 GeekSensorMetricHoverDetail.popoverSize(extraRowCount: 0, hasNote: false)),
                // D122 (2026-10-18): a selected fan's history and the average,
                // from the demo's per-fan readings (were not rendered).
                ("fan", AnyView(GeekFanHoverDetail(points: points, duration: 3_600, currentValue: fans[0].displayRPM,
                                                   readings: fans, valueRange: 0...2_500, selectedFanIndex: fans[0].index)),
                 GeekFanHoverDetail.popoverSize(selectedFanIndex: fans[0].index, readingCount: fans.count)),
                ("fans", AnyView(GeekFanHoverDetail(points: points, duration: 3_600, currentValue: fans[0].displayRPM,
                                                    readings: fans, valueRange: 0...2_500, selectedFanIndex: nil)),
                 GeekFanHoverDetail.popoverSize(selectedFanIndex: nil, readingCount: fans.count)),
            ]
            // The bar histories' last pixel row above the axis row: the page
            // inset, the plot top and the 153 pt chart, at 2x.
            let barRow = Int((GeekPanelLayout.contentPadding + MiniWindowStyleTokens.historyPlotTop
                              + MiniWindowStyleTokens.historyChartHeight) * 2) - 1
            let barPages: Set<String> = ["cpu", "gpu", "memory pressure", "composition", "disk read",
                                         "cpu usage", "fan", "fans"]
            for (name, page, size) in pages {
                // D132: each page in its own width (the battery history's 319).
                let width = size.width - 2 * MiniWindowStyleTokens.contentInset
                let bitmap = try Self.render(page, mode: .black, width: width)
                XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, size.width, accuracy: 0.5, "\(language) \(name)")
                XCTAssertEqual(CGFloat(bitmap.pixelsHigh) / 2, size.height, accuracy: 0.5, "\(language) \(name)")
                if name == "battery" {
                    // D132: iStat's 96 battery bars, 2 pt every 3 pt, the
                    // oldest from 8 pt in the card (8 + 8), the newest ending
                    // at 295 (8 + 295); one sample every 30 s fills each 37 s
                    // bucket of the hour. Their last pixel row is above the
                    // baseline at 160 in the card.
                    let runs = Self.barRuns(in: bitmap, row: Int((GeekPanelLayout.contentPadding + 160) * 2) - 1)
                    XCTAssertEqual(runs.count, 96, "\(language) \(name)")
                    XCTAssertEqual(Set(runs.map(\.length)), [4], "\(language) \(name)")
                    XCTAssertEqual(Set(zip(runs.dropFirst(), runs).map { $0.start - $1.start }), [6], "\(language) \(name)")
                    XCTAssertEqual(runs.first?.start, 32, "\(language) \(name)")
                    XCTAssertEqual(runs.last.map { $0.start + $0.length }, 606, "\(language) \(name)")
                }
                if barPages.contains(name) {
                    // As drawn: one 2 pt bar per 30 s of the hour, 3 pt apart,
                    // from the plot's leading edge (8 + 8 pt) to its trailing
                    // edge (8 + 8 + 359 pt).
                    let runs = Self.barRuns(in: bitmap, row: barRow)
                    XCTAssertEqual(runs.count, 120, "\(language) \(name)")
                    XCTAssertEqual(Set(runs.map(\.length)), [4], "\(language) \(name)")
                    XCTAssertEqual(Set(zip(runs.dropFirst(), runs).map { $0.start - $1.start }), [6], "\(language) \(name)")
                    XCTAssertEqual(runs.first?.start, 32, "\(language) \(name)")
                    XCTAssertEqual(runs.last.map { $0.start + $0.length }, 750, "\(language) \(name)")
                }
                if language == .zhHans {
                    try Self.export(name: "l3-\(name.replacingOccurrences(of: ", ", with: "-").replacingOccurrences(of: " ", with: "-"))",
                                    night: bitmap, page: page, width: width)
                }
            }
        }
    }

    func testTheTooltipSitsBesideTheIndicatorAndFlipsAtTheEdge() throws {
        // 8 pt right of the indicator while it fits, else 6 pt left of it.
        XCTAssertEqual(GeekHistoryTooltipLayout.originX(indicatorMinX: 100, indicatorMaxX: 102, width: 150,
                                                         containerWidth: 375), 110)
        XCTAssertEqual(GeekHistoryTooltipLayout.originX(indicatorMinX: 300, indicatorMaxX: 302, width: 150,
                                                         containerWidth: 375), 144)
        XCTAssertEqual(GeekHistoryTooltipLayout.originX(indicatorMinX: 215, indicatorMaxX: 217, width: 150,
                                                         containerWidth: 375), 225, "Exactly fits: stays right")
        XCTAssertEqual(GeekHistoryTooltipLayout.originX(indicatorMinX: 40, indicatorMaxX: 42, width: 360,
                                                         containerWidth: 375), 0, "Never past the leading edge")

        // At most 200 wide; 8 + 15 + 8 + 15 × rows + 8 tall; its top at the plot's top.
        let plot = CGRect(x: 8, y: 0, width: 359, height: MiniWindowStyleTokens.historyChartHeight)
        for (values, x) in [(1, CGFloat(60)), (2, CGFloat(330))] {
            let tooltip = GeekHoverTooltip(
                date: Date(timeIntervalSince1970: 1_000_000),
                values: (0..<values).map {
                    GeekHoverValue(title: "Series \($0) with a long name", value: "1,234.5 KB/s", color: .orange)
                },
                visibleDuration: 3_600
            )
            let tooltipSize = NSHostingView(rootView: tooltip.fixedSize()).fittingSize
            XCTAssertEqual(tooltipSize.height, 39 + 15 * CGFloat(values), accuracy: 0.5)
            let renderer = ImageRenderer(content: GeekHistoryHoverIndicator(barCenterX: x, plotRect: plot, tooltip: tooltip)
                .frame(width: Self.card, height: MiniWindowStyleTokens.historyChartHeight)
                .background(Color.gray.opacity(0.3))
                .environment(\.displayScale, 2))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            XCTAssertEqual(CGFloat(bitmap.pixelsWide) / 2, Self.card, accuracy: 0.5)
            try Self.export(name: values == 2 ? "l3-tooltip-flipped" : "l3-tooltip-right", bitmap: bitmap)
        }
        let wide = GeekHoverTooltip(date: Date(timeIntervalSince1970: 1_000_000),
                                    values: [GeekHoverValue(title: String(repeating: "Wide ", count: 30),
                                                            value: "1", color: .orange)],
                                    visibleDuration: 3_600)
        let width = min(GeekIStatHistoryGeometry.tooltipMaximumWidth, NSHostingView(rootView: wide.fixedSize()).fittingSize.width)
        XCTAssertEqual(width, 200)

        // From 3 days up (2160 s a bar) the date takes a row of its own.
        XCTAssertNil(PanelChartDateFormatting.tooltipLines(for: Date(), visibleDuration: 86_400).date, "1 day: 720 s a bar")
        XCTAssertNotNil(PanelChartDateFormatting.tooltipLines(for: Date(), visibleDuration: 3 * 86_400).date)
        let dated = GeekHoverTooltip(date: Date(timeIntervalSince1970: 1_000_000),
                                     values: [GeekHoverValue(title: "CPU", value: "12%", color: .orange)],
                                     visibleDuration: 3 * 86_400)
        XCTAssertEqual(NSHostingView(rootView: dated.fixedSize()).fittingSize.height, 39 + 15 + 15, accuracy: 0.5)
        let datedRenderer = ImageRenderer(content: GeekHistoryHoverIndicator(barCenterX: 120, plotRect: plot, tooltip: dated)
            .frame(width: Self.card, height: MiniWindowStyleTokens.historyChartHeight)
            .background(Color.gray.opacity(0.3))
            .environment(\.displayScale, 2))
        datedRenderer.scale = 2
        try Self.export(name: "l3-tooltip-dated", bitmap: NSBitmapImageRep(cgImage: try XCTUnwrap(datedRenderer.cgImage)))

        // Nothing to say about a bucket without data: neither is drawn.
        XCTAssertTrue(GeekHoverTooltip(date: Date(), values: [], visibleDuration: 3_600).isEmpty)
        XCTAssertFalse(GeekHoverTooltip(date: Date(), values: [], visibleDuration: 3_600, detail: "Charging").isEmpty)
    }

    func testRangesAreIStatsTenAfterOurShortOnes() throws {
        // D130 (2026-10-19): iStat's ten only; a menu graph has no window
        // (D131), so our three short ones left the list (was .thirtySeconds,
        // .oneMinute, .fiveMinutes before .tenMinutes).
        XCTAssertEqual(GeekChartRange.allCases, [
            .tenMinutes, .oneHour, .threeHours, .sixHours, .twelveHours,
            .oneDay, .threeDays, .sevenDays, .fourteenDays, .twentyEightDays,
        ])
        XCTAssertEqual(GeekChartRange.allCases.map(\.rawValue).suffix(10),
                       [5, 30, 90, 180, 360, 720, 2_160, 5_040, 10_080, 20_160].map { $0 * 120 },
                       "iStat's seconds per bar × 120 (its 28 days spans 30; ours is 28)")
        XCTAssertFalse(GeekChartRange.allCases.contains(.fifteenMinutes))
        XCTAssertEqual(GeekChartRange.fifteenMinutes.normalized, .tenMinutes)
        XCTAssertEqual(GeekChartRange.twoMinutes.normalized, .oneHour)
        for range: GeekChartRange in [.thirtySeconds, .oneMinute, .fiveMinutes] {
            XCTAssertFalse(GeekChartRange.allCases.contains(range), "\(range)")
            XCTAssertEqual(range.normalized, .tenMinutes, "an older \(range) preference reads as 10 minutes")
        }
        XCTAssertEqual(Set(GeekChartRange.allCases.map(\.normalized)), Set(GeekChartRange.allCases),
                       "every offered range is its own normalized range")
        XCTAssertEqual(GeekChartRangeSelection(range: .oneHour, select: { _ in }).range, .oneHour)

        // An older preference of 15 minutes reads and writes as 10 minutes.
        let suiteName = TestPreferenceDomain.makeSuite()
        defer { TestPreferenceDomain.cleanup(suiteName: suiteName) }
        let defaults = try XCTUnwrap(TestPreferenceDomain.open(suiteName: suiteName))
        let state = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        state.setGeekChartRange(.fifteenMinutes, for: .cpu)
        XCTAssertEqual(state.geekChartRange(for: .cpu, fallbackTo: .processor), .tenMinutes)
        defaults.set(try JSONEncoder().encode(["metric.memory": GeekChartRange.fifteenMinutes]),
                     forKey: MenuBarPanelSettingsState.chartRangesDefaultsKey)
        let restored = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        XCTAssertEqual(restored.geekChartRange(for: .memory, fallbackTo: .memory), .tenMinutes)

        // D130: so does an older preference of 30 s, 60 s or 5 minutes.
        defaults.set(try JSONEncoder().encode([
            "metric.cpu": GeekChartRange.thirtySeconds, "metric.network": GeekChartRange.oneMinute,
            "metric.memory": GeekChartRange.fiveMinutes,
        ]), forKey: MenuBarPanelSettingsState.chartRangesDefaultsKey)
        let older = MenuBarPanelSettingsState(initialDensity: .geek, defaults: defaults)
        XCTAssertEqual(older.geekChartRange(for: .cpu, fallbackTo: .processor), .tenMinutes)
        XCTAssertEqual(older.geekChartRange(for: .network, fallbackTo: .network), .tenMinutes)
        XCTAssertEqual(older.geekChartRange(for: .memory, fallbackTo: .memory), .tenMinutes)
    }

    func testTemperatureHistoriesRoundTheirScaleUpToTenDegrees() {
        let range: ClosedRange<Double> = 0...100
        XCTAssertEqual(GeekSensorMetricHoverDetail.displayedValueRange(range, unit: .temperature, peak: 87), 0...100)
        XCTAssertEqual(GeekSensorMetricHoverDetail.displayedValueRange(range, unit: .temperature, peak: 104.2), 0...110)
        XCTAssertEqual(GeekSensorMetricHoverDetail.displayedValueRange(range, unit: .temperature, peak: 110), 0...110)
        XCTAssertEqual(GeekSensorMetricHoverDetail.displayedValueRange(range, unit: .temperature, peak: nil), 0...100)
        XCTAssertEqual(GeekSensorMetricHoverDetail.displayedValueRange(range, unit: .temperature, peak: .infinity), 0...100)
        XCTAssertEqual(GeekSensorMetricHoverDetail.displayedValueRange(range, unit: .percent, peak: 120), 0...100,
                       "CPU, GPU and memory pressure stay 0–100")
    }

    func testABarWithAValueIsAtLeastOnePointTall() {
        let plot = CGRect(x: 0, y: 0, width: 359, height: 153)
        for scale in [CGFloat(1), 2] {
            let small = GeekChartWindow.stackedBarRect(x: 0, width: 2, lower: 0, upper: 0.2, in: plot,
                                                       range: 0...100, displayScale: scale)
            XCTAssertEqual(small.height, 1, accuracy: 0.000_001, "\(scale)x")
            XCTAssertEqual(small.maxY, plot.maxY, accuracy: 0.000_001)
            let zero = GeekChartWindow.stackedBarRect(x: 0, width: 2, lower: 0, upper: 0, in: plot,
                                                      range: 0...100, displayScale: scale)
            XCTAssertEqual(zero.height, 1 / scale, accuracy: 0.000_001, "A recorded zero stays one pixel")
            XCTAssertEqual(GeekChartWindow.minimumBarHeight(hasValue: true, displayScale: scale), 1)
        }
    }

    func testHistoryPagesUseTheCardAndRecomputeTheirScale() throws {
        let target = try Self.source("Views/MenuBarAdvanced/GeekHoverDetailTarget.swift")
        let sensors = try Self.source("Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift")
        let composition = try Self.source("Views/MenuBarAdvanced/GeekMemoryCompositionView.swift")
        // Every history chart spans the card with the 8 pt inset; none keeps 2.
        // D122 (2026-10-18): the CPU usage page is a history page (target was 7).
        for (name, text, count) in [("target", target, 8), ("sensors", sensors, 3), ("composition", composition, 1)] {
            XCTAssertEqual(text.components(separatedBy: "horizontalInset: MiniWindowStyleTokens.historyChartInset").count - 1,
                           count, name)
            XCTAssertFalse(text.contains("horizontalInset: 2,"), name)
        }
        // The throughput histories recompute each half's scale (no easing).
        XCTAssertEqual(target.components(separatedBy: "easesScale: false").count - 1, 3)
        XCTAssertFalse(target.contains("stacksRangePicker"))
        XCTAssertFalse(sensors.contains("stacksRangePicker"))
        let canvas = try XCTUnwrap(target.components(separatedBy: "private var historyBody: some View {").last?
            .components(separatedBy: "private var historyHeader: some View {").first)
        // D132 (2026-10-19): the battery page passes iStat's 180 pt card and
        // its plot top; every other page keeps the defaults (was
        // `GeekIStatCard(height: MiniWindowStyleTokens.historyCardHeight)`,
        // `top: MiniWindowStyleTokens.historyPlotTop`,
        // `height: MiniWindowStyleTokens.historyPlotHeight`).
        XCTAssertTrue(canvas.contains("GeekIStatCard(height: cardHeight)"))
        XCTAssertTrue(canvas.contains("top: plotTop"))
        XCTAssertTrue(canvas.contains("height: max(0, cardHeight - plotTop - MiniWindowStyleTokens.contentInset)"))
        XCTAssertEqual(target.components(separatedBy: "cardHeight: CGFloat = MiniWindowStyleTokens.historyCardHeight").count - 1, 2)
        XCTAssertEqual(target.components(separatedBy: "plotTop: CGFloat = MiniWindowStyleTokens.historyPlotTop").count - 1, 2)
        XCTAssertEqual(MiniWindowStyleTokens.historyCardHeight - MiniWindowStyleTokens.historyPlotTop
                           - MiniWindowStyleTokens.contentInset, MiniWindowStyleTokens.historyPlotHeight)
        XCTAssertEqual(target.components(separatedBy: "cardHeight: GeekIStatHistoryGeometry.").count - 1, 0)
        XCTAssertEqual(sensors.components(separatedBy: "cardHeight: GeekIStatHistoryGeometry.batteryCardHeight").count - 1, 1)

        // The title row (and the rows below the card) name the series: no
        // history chart spends the plot block on a legend row.
        let pages = [
            (target, ["GeekProcessorActivityHoverDetail", "GeekNetworkHistoryHoverDetail", "GeekGPUHoverDetail",
                      "GeekMemoryHistoryHoverDetail", "GeekSwapHoverDetail", "GeekDiskIOHoverDetail",
                      "GeekDiskThroughputHoverDetail", "GeekProcessorUsageHoverDetail"]),
            (sensors, ["GeekSensorMetricHoverDetail", "GeekFanHoverDetail"]),
            (composition, ["GeekMemoryCompositionHistoryDetail"]),
        ]
        for (text, names) in pages {
            for name in names {
                let page = try XCTUnwrap(text.components(separatedBy: "struct \(name): View {").dropFirst().first?
                    .components(separatedBy: "\n}\n").first, name)
                XCTAssertTrue(page.contains("showsLegend: false"), name)
            }
        }
    }

    // MARK: - Helpers

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/\(path)"), encoding: .utf8)
    }

    /// As `tertiaryDetailChrome` hosts a page: content without its own
    /// inset, padded by the column's 8 pt.
    private static func render(_ page: AnyView, mode: MiniWindowVisualMode, width: CGFloat = card) throws -> NSBitmapImageRep {
        let content = page
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.miniWindowPageProvidesInset, true)
            .padding(GeekPanelLayout.contentPadding)
            .metricPanelShell()
            .environment(\.menuBarChartsPreparedInline, true)
            .environment(\.miniWindowPreviewDate, MiniWindowDemoData.referenceDate)
            .modifier(PanelAppearanceEnvironment(forcedVisualMode: mode))
            .environment(\.displayScale, 2)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    /// Runs of colored (bar) pixels along one pixel row of a night render,
    /// whose card and plot are neutral grays.
    private static func barRuns(in bitmap: NSBitmapImageRep, row: Int) -> [(start: Int, length: Int)] {
        var runs: [(start: Int, length: Int)] = []
        var start: Int?
        for x in 0...bitmap.pixelsWide {
            var isBar = false
            if x < bitmap.pixelsWide, let color = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) {
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                isBar = (channels.max() ?? 0) - (channels.min() ?? 0) > 0.25
            }
            if isBar, start == nil { start = x }
            if !isBar, let first = start {
                runs.append((first, x - first))
                start = nil
            }
        }
        return runs
    }

    private static var evidenceDirectory: URL? {
        ProcessInfo.processInfo.environment["STORAGE_CLEANER_ISTAT_LAYOUT_EVIDENCE"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Night is black, day is graphite (D44, D56).
    private static func export(name: String, night: NSBitmapImageRep, page: AnyView, width: CGFloat = card) throws {
        guard let directory = evidenceDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (bitmap, suffix) in [(night, "night"), (try render(page, mode: .graphite, width: width), "day")] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    private static func export(name: String, bitmap: NSBitmapImageRep) throws {
        guard let directory = evidenceDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}

/// Switches L10n for one block through the volatile argument domain, as
/// `MiniWindowConsistencyRuleTests` does.
@MainActor
private final class HistoryLayoutLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(L10n.appLanguage, language)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}
#endif
