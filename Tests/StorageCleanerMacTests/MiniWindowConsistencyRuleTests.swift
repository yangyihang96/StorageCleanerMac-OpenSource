import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Batch 2b (2.0.0): one rule per mini-window concept - headings, process
/// tables, ring/history colors. Source checks name the production files.
@MainActor
final class MiniWindowConsistencyRuleTests: XCTestCase {
    private let base = "Sources/StorageCleanerMac/Views/MenuBarAdvanced/"

    func testMemoryPressureRingAndHistoryShareOneLevelAwareColor() throws {
        let colors = PanelMetricColors()
        try assertColor(colors.memoryPressure(for: .normal), equals: colors.memoryPressure)
        try assertColor(colors.memoryPressure(for: .elevated), equals: AppDesignTokens.Palette.warning)
        try assertColor(colors.memoryPressure(for: .critical), equals: AppDesignTokens.Palette.destructive)
        try assertColor(colors.memoryPressure(for: nil), equals: .secondary)

        let components = try source("MenuBarAdvancedComponents.swift")
        XCTAssertTrue(components.contains("panelMetricColors.memoryPressure(for: memorySnapshot?.reportablePressureLevel)"))
        let detail = try source("GeekHoverDetailTarget.swift")
        let history = try XCTUnwrap(detail.components(separatedBy: "struct GeekMemoryHistoryHoverDetail: View {").last?
            .components(separatedBy: "struct GeekSwapDetailData").first)
        XCTAssertTrue(history.contains("color: metricColors.memoryPressure(for: snapshot?.reportablePressureLevel)"))
    }

    func testFanAndGPUHistoriesUseTheirRingColors() throws {
        // One exit per metric, also under a chart theme or a custom color:
        // the rings and the histories read the same PanelMetricColors rule,
        // and the histories switch off the chart's single-accent repaint.
        let sensors = try source("GeekSensorsPowerHoverDetails.swift")
        let fan = try XCTUnwrap(sensors.components(separatedBy: "struct GeekFanHoverDetail: View {").last?
            .components(separatedBy: "struct GeekBatteryElectricalHoverDetail").first)
        XCTAssertTrue(fan.contains("color: resolvedTint"))
        XCTAssertTrue(fan.contains("metricColors.sensorGraph(chartAccent: panelChartAccentColor)"))
        XCTAssertTrue(fan.contains(".environment(\\.panelChartAccentColor, nil)"))
        XCTAssertFalse(fan.contains("Palette.tertiary"))
        let sensorMetric = try XCTUnwrap(sensors.components(separatedBy: "struct GeekSensorMetricHoverDetail: View {").last?
            .components(separatedBy: "enum GeekPowerHistoryMetric").first)
        XCTAssertTrue(sensorMetric.contains("color: tint"))
        XCTAssertTrue(sensorMetric.contains(".environment(\\.panelChartAccentColor, nil)"))
        let sensorPage = try source("GeekSensorsView.swift")
        XCTAssertTrue(sensorPage.contains("tint: panelMetricColors.sensorGraph(chartAccent: panelChartAccentColor)"))
        XCTAssertFalse(sensorPage.contains("GeekSensorFanRing(telemetry: geekFanTelemetry, tint: panelMetricColors.sensorGraph)"))
        let overview = try source("GeekOverviewPresentation.swift")
        XCTAssertTrue(overview.contains("tint: metricColors.sensorGraph(chartAccent: panelChartAccentColor)"),
                      "The overview fan ring uses the fan history's exit")

        let detail = try source("GeekHoverDetailTarget.swift")
        let gpu = try XCTUnwrap(detail.components(separatedBy: "struct GeekGPUHoverDetail: View {").last?
            .components(separatedBy: "struct GeekProcessorUsageHoverDetail").first)
        XCTAssertTrue(gpu.contains("color: metricColors.gpu(chartAccent: panelChartAccentColor)"))
        XCTAssertTrue(gpu.contains(".environment(\\.panelChartAccentColor, nil)"))
        XCTAssertFalse(gpu.contains("AppChartPalette."))
        let processor = try source("GeekProcessorView.swift")
        XCTAssertTrue(processor.contains("tint: geekProcessorGPUMemoryTint"))
        XCTAssertTrue(processor.contains("memoryTint: geekProcessorGPUMemoryTint"))
        XCTAssertFalse(processor.contains("Palette.caution"),
                       "GPU temperature uses the sensors page's temperature color rule")

        // The GPU ring's resolvedGPUTint and the sensor rings' resolvedThermalTint
        // call the same exits (batch 4b); the rule itself is asserted on the
        // exits in testColorExitsFollowCustomColorsThenTheChartTheme.
        let root = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"), encoding: .utf8)
        XCTAssertTrue(root.contains("var resolvedGPUTint: Color {\n        panelMetricColors.gpu(chartAccent: panelChartAccentColor)\n    }"))
        XCTAssertTrue(root.contains("var resolvedThermalTint: Color {\n        panelMetricColors.sensorGraph(chartAccent: panelChartAccentColor)\n    }"))
        for source in [root, try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Support/PanelPaletteCatalog.swift"), encoding: .utf8)] {
            XCTAssertFalse(source.contains("gpuIsCustomized"), "the customized-color rule lives in PanelMetricColors only")
            XCTAssertFalse(source.contains("sensorGraphIsCustomized"), "the customized-color rule lives in PanelMetricColors only")
        }
    }

    func testColorExitsFollowCustomColorsThenTheChartTheme() throws {
        let accent = Color(red: 0.6, green: 0.2, blue: 0.9)
        let plain = PanelMetricColors()
        try assertColor(plain.gpu(chartAccent: nil), equals: plain.gpu)
        try assertColor(plain.gpu(chartAccent: accent), equals: accent)
        try assertColor(plain.sensorGraph(chartAccent: nil), equals: plain.sensorGraph)
        try assertColor(plain.sensorGraph(chartAccent: accent), equals: accent)
        let custom = PanelMetricColors(gpu: "#FF8800", sensorGraph: "#00AA44")
        try assertColor(custom.gpu(chartAccent: accent), equals: custom.gpu)
        try assertColor(custom.sensorGraph(chartAccent: accent), equals: custom.sensorGraph)

        // One temperature rule (the chip ring, sensor rings and histories):
        // the normal color is the sensor exit, so it follows the theme too.
        for (celsius, expected) in [(nil, accent), (79.9, accent), (80, AppDesignTokens.Palette.warning),
                                    (89.9, AppDesignTokens.Palette.warning), (90, AppDesignTokens.Palette.destructive)] as [(Double?, Color)] {
            try assertColor(plain.temperature(celsius, chartAccent: accent), equals: expected)
        }
        let components = try source("MenuBarAdvancedComponents.swift")
        XCTAssertTrue(components.contains("panelMetricColors.temperature(temperatureValue, chartAccent: panelChartAccentColor)"))
        let sensorPage = try source("GeekSensorsView.swift")
        XCTAssertTrue(sensorPage.contains("panelMetricColors.temperature(value, chartAccent: panelChartAccentColor)"))
        for file in ["MenuBarAdvancedComponents.swift", "GeekSensorsView.swift"] {
            XCTAssertFalse(try source(file).contains("Palette.warning\n        }\n        return panelMetricColors.sensorGraph"),
                           "\(file): no second temperature rule")
        }
    }

    func testDiskTextNamesWhatEachCapacityGraphicShows() throws {
        let chinese = RuleTestLanguageScope(.zhHans)
        XCTAssertEqual(GeekDiskCapacityWording.volumeSummary(usedPercent: 44, available: "560 GB"),
                       "44% 已用 · 560 GB 可用")
        XCTAssertTrue(GeekDiskCapacityWording.availableHelp.contains("含可清除空间"))
        XCTAssertTrue(GeekDiskCapacityWording.availableHelp.contains("df"))
        chinese.restore()
        let english = RuleTestLanguageScope(.english)
        XCTAssertEqual(GeekDiskCapacityWording.volumeSummary(usedPercent: 44, available: "560 GB"),
                       "44% used · 560 GB available")
        english.restore()

        // Decision D14 (2026-10-04): the overview bar shows the used share
        // and the card's text is the volume row's sentence. (Batch 2b kept the
        // bar's earlier free-space meaning here:
        // `max(0, 1 - storageSnapshot.userUsedRatio)`.)
        let overview = try source("GeekOverviewPresentation.swift")
        let disk = try XCTUnwrap(overview.components(separatedBy: "struct GeekDiskPresentation: View {").last?
            .components(separatedBy: "struct GeekBatteryPresentation").first)
        // D118 (2026-10-18): the bar became iStat's 26 pt ring, still filled
        // to the used share; the card's rows are the volume name and
        // "560 GB 可用", and VoiceOver reads the summary sentence. Were
        // `.frame(width: proxy.size.width * storageSnapshot.userUsedRatio)` and
        // `Text(Self.capacitySummary(storageSnapshot))`.
        XCTAssertTrue(disk.contains("progress: Self.ringProgress(storageSnapshot)"))
        let gigabyte: Int64 = 1_000_000_000
        let fixture = StorageCapacitySnapshot(totalBytes: 1_000 * gigabyte, availableBytes: 560 * gigabyte)
        XCTAssertEqual(GeekDiskPresentation.ringProgress(fixture), fixture.userUsedRatio, accuracy: 0.000_001)
        XCTAssertFalse(disk.contains("1 - storageSnapshot.userUsedRatio"))
        XCTAssertTrue(disk.contains("Text(Self.availableText(storageSnapshot))"))
        XCTAssertTrue(disk.contains(".accessibilityValue(Self.capacitySummary(storageSnapshot))"))
        XCTAssertFalse(disk.contains("Text(L10n.text(\"已用 \\(storagePercentText)\""))
        XCTAssertTrue(disk.contains(".help(GeekDiskCapacityWording.availableHelp)"))
        XCTAssertTrue(try source("GeekDiskView.swift").contains("GeekDiskCapacityWording.volumeSummary("))
        let detail = try source("GeekHoverDetailTarget.swift")
        XCTAssertTrue(detail.contains(".help(GeekDiskCapacityWording.availableHelp)"))
        // Disk byte totals share the decimal file style of the capacities.
        XCTAssertFalse(detail.contains("ByteFormat.string(Int64(clamping: counters."))
        XCTAssertFalse(detail.contains("ByteFormat.string(Int64(clamping: mode == .read"))
        // D121 (2026-10-18): the totals are rows below the graph card, "—"
        // until read (was `ByteFormat.storageString(Int64(clamping: counters.readBytes))`).
        // D128 (2026-10-19): iStat's transferred totals (was
        // `counters.map { ByteFormat.storageString(Int64(clamping: $0.readBytes)) }`).
        XCTAssertTrue(detail.contains("counters.map { IStatNumberFormat.space($0.readBytes, style: .totals) }"))
    }

    func testTertiaryHistoriesShowAxisFooterWithScaleAndUnrecordedLegend() throws {
        let chinese = RuleTestLanguageScope(.zhHans)
        XCTAssertEqual(GeekHistoryAxisFooter.startLabel(for: 3_600), "−1 小时")
        XCTAssertEqual(GeekHistoryAxisFooter.startLabel(for: 259_200), "−3 天")
        XCTAssertEqual(GeekHistoryAxisFooter.startLabel(for: 7_200), "−2 小时")
        XCTAssertEqual(GeekHistoryAxisFooter.scaleLabel("0–100%"), "纵轴 0–100%")
        XCTAssertEqual(GeekHistoryAxisFooter.scaleLabel(nil), "纵轴自动")
        XCTAssertTrue(GeekHistoryAxisFooter.gapHelp.contains("不代表数值为 0"))
        chinese.restore()
        let english = RuleTestLanguageScope(.english)
        XCTAssertEqual(GeekHistoryAxisFooter.startLabel(for: 3_600), "−1 Hour")
        XCTAssertEqual(GeekHistoryAxisFooter.scaleLabel(nil), "Auto scale")
        english.restore()

        XCTAssertEqual(GeekHistoryAxisFooter.rangeText(0...100, unit: .percent), "0–100%")
        // D128 (2026-10-19): iStat's whole degrees without the scale (was "0–100°C").
        XCTAssertEqual(GeekHistoryAxisFooter.rangeText(0...100, unit: .temperature), "0–100°")
        XCTAssertEqual(GeekHistoryAxisFooter.rangeText(0...4_000, unit: .fanRPM), "0–4,000 rpm")
        XCTAssertNil(GeekHistoryAxisFooter.rangeText(0...1, unit: .bytesPerSecond))

        // Every range-picker history shows the footer under its chart, always
        // through the plot block (no footer placed with a page's own row
        // spacing); the charts keep their built-in labels off (contract in
        // PanelChartNormalizationTests), so the footer is the only axis row.
        // D122 (2026-10-18): the CPU usage page is a history page (target was 7).
        // D132 (2026-10-19): iStat's battery history page has no axis row
        // (sensors was 3).
        for (file, count) in [("GeekHoverDetailTarget.swift", 8), ("GeekMemoryCompositionView.swift", 1),
                              ("GeekSensorsPowerHoverDetails.swift", 2)] {
            let text = try source(file)
            XCTAssertEqual(text.components(separatedBy: ".geekHistoryAxis(GeekHistoryAxisFooter(").count - 1, count, file)
            XCTAssertEqual(text.components(separatedBy: "GeekHistoryAxisFooter(").count - 1, count,
                           "\(file): every axis row sits in a plot block")
            XCTAssertFalse(text.contains(".frame(height: MiniWindowStyleTokens.historyChartHeight)"),
                           "\(file): the plot block owns the chart height")
        }
        let charts = try source("MenuBarGeekCharts.swift")
        XCTAssertTrue(charts.contains("context.fill(Path(rect), with: .color(gapFill))"),
                      "Gap blocks and the 未记录 swatch share one fill")

        // The block (chart + axis row, no gap) keeps the plot's former height,
        // so no history shell changes height for the axis row: the pure-plot
        // pages stay 216 pt and the pages with rows below the chart keep
        // their former heights. testHistoryPlotBlockKeepsTheFormerPlotHeight
        // measures the rendered block.
        XCTAssertEqual(MiniWindowStyleTokens.historyChartHeight + GeekHistoryAxisFooter.height,
                       MiniWindowStyleTokens.historyPlotHeight)
        // D121 (2026-10-18): iStat's plot, H − 33 in the 200 pt card, from 25
        // to 8 pt above its bottom. Was 154 (the plot height before the axis
        // row existed), below a 24 pt range row and two 7 pt gaps.
        XCTAssertEqual(MiniWindowStyleTokens.historyPlotHeight, 167)
        XCTAssertEqual(MiniWindowStyleTokens.historyPlotTop + MiniWindowStyleTokens.historyPlotHeight
                           + MiniWindowStyleTokens.contentInset,
                       MiniWindowStyleTokens.historyCardHeight)
        XCTAssertEqual(MiniWindowStyleTokens.historyCardHeight, MiniWindowStyleTokens.historyContentHeight)

        // VoiceOver reads the gap legend's meaning, not only the tooltip.
        let chinese2 = RuleTestLanguageScope(.zhHans)
        XCTAssertTrue(GeekHistoryAxisFooter.accessibilitySummary(duration: 3_600, valueRange: "0–100%", showsGapLegend: true)
            .contains("未记录"))
        XCTAssertFalse(GeekHistoryAxisFooter.accessibilitySummary(duration: 3_600, valueRange: nil, showsGapLegend: false)
            .contains("未记录"))
        chinese2.restore()
    }

    func testHistoryPlotBlockKeepsTheFormerPlotHeight() throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = RuleTestLanguageScope(language)
            defer { scope.restore() }
            for footer in [GeekHistoryAxisFooter(duration: 259_200, valueRange: "0–2,500 rpm"),
                           GeekHistoryAxisFooter(duration: 3_600, showsGapLegend: false)] {
                let host = NSHostingView(rootView: Color.clear.geekHistoryAxis(footer)
                    .frame(width: MiniWindowStyleTokens.historyWidth - 2 * MiniWindowStyleTokens.contentInset))
                XCTAssertEqual(host.fittingSize.height, MiniWindowStyleTokens.historyPlotHeight, accuracy: 0.01,
                               "\(language): the axis row must not add height to a history shell")
            }
        }
    }

    func testMirroredThroughputHistoriesSayTheirHalvesScaleSeparately() throws {
        // D117: network upload/download and disk read/write halves each fit
        // their own peak, so their axis row says so instead of "纵轴自动".
        let chinese = RuleTestLanguageScope(.zhHans)
        XCTAssertEqual(GeekHistoryAxisFooter.scaleLabel(nil, halvesScaleSeparately: true), "上下各自缩放")
        XCTAssertEqual(GeekHistoryAxisFooter.scaleLabel(nil), "纵轴自动")
        XCTAssertEqual(GeekHistoryAxisFooter.scaleLabel("0–100%", halvesScaleSeparately: true), "纵轴 0–100%")
        XCTAssertEqual(GeekHistoryAxisFooter.centerLabel(valueRange: nil, isUpdating: true, halvesScaleSeparately: true),
                       "更新中…")
        XCTAssertTrue(GeekHistoryAxisFooter.accessibilitySummary(
            duration: 3_600, valueRange: nil, showsGapLegend: true, halvesScaleSeparately: true
        ).contains("上下各自缩放，两半的柱高不能直接比较"))
        XCTAssertFalse(GeekHistoryAxisFooter.accessibilitySummary(duration: 3_600, valueRange: nil, showsGapLegend: true)
            .contains("两半"))
        XCTAssertTrue(GeekHistoryAxisFooter.halvesHelp.contains("悬停提示"))
        chinese.restore()
        let english = RuleTestLanguageScope(.english)
        XCTAssertEqual(GeekHistoryAxisFooter.scaleLabel(nil, halvesScaleSeparately: true), "Each half auto-scaled")
        english.restore()

        let target = try source("GeekHoverDetailTarget.swift")
        XCTAssertEqual(target.components(separatedBy: "halvesScaleSeparately: true").count - 1, 2,
                       "The network history and the combined disk I/O history")
        let network = try XCTUnwrap(target.components(separatedBy: "struct GeekNetworkHistoryHoverDetail: View {").last?
            .components(separatedBy: "\n}\n").first)
        XCTAssertTrue(network.contains("halvesScaleSeparately: true"))
        let combinedDisk = try XCTUnwrap(target.components(separatedBy: "struct GeekDiskIOHoverDetail: View {").last?
            .components(separatedBy: "\n}\n").first)
        XCTAssertTrue(combinedDisk.contains("halvesScaleSeparately: true"))
        let singleDisk = try XCTUnwrap(target.components(separatedBy: "struct GeekDiskThroughputHoverDetail: View {").last?
            .components(separatedBy: "\n}\n").first)
        XCTAssertFalse(singleDisk.contains("halvesScaleSeparately"), "A single-direction chart has one scale")

        // The longer label keeps the axis row on one line and one row high.
        for language in [AppLanguage.zhHans, .english] {
            let scope = RuleTestLanguageScope(language)
            defer { scope.restore() }
            let footer = GeekHistoryAxisFooter(duration: 2_419_200, halvesScaleSeparately: true)
            XCTAssertLessThanOrEqual(NSHostingView(rootView: footer).fittingSize.width,
                                     MiniWindowStyleTokens.historyWidth - 2 * MiniWindowStyleTokens.contentInset,
                                     "\(language)")
            let host = NSHostingView(rootView: Color.clear.geekHistoryAxis(footer)
                .frame(width: MiniWindowStyleTokens.historyWidth - 2 * MiniWindowStyleTokens.contentInset))
            XCTAssertEqual(host.fittingSize.height, MiniWindowStyleTokens.historyPlotHeight, accuracy: 0.01, "\(language)")
        }
    }

    func testHeadingsKeepTheHeaderColorAndCPULoadColorsTheTotals() throws {
        // Review of batch 2b: state colors live on data and buttons only.
        let components = try source("GeekPanelComponents.swift")
        let header = try XCTUnwrap(components.components(separatedBy: "struct GeekModuleHeader<Trailing: View>: View {").last?
            .components(separatedBy: "struct GeekSectionTitle").first)
        XCTAssertFalse(header.contains("iconTint"), "The module icon always takes the section-header color")
        // D118 (2026-10-18): iStat titles are text only; the title takes the
        // section-header color. Was
        // `GeekModuleLabel(systemImage: systemImage, tint: metricColors.sectionHeader)`.
        XCTAssertTrue(header.contains(".foregroundStyle(metricColors.sectionHeader)"))
        XCTAssertFalse(header.contains("systemImage"))
        let overview = try source("GeekOverviewPresentation.swift")
        XCTAssertFalse(overview.contains("iconTint:"))
        XCTAssertFalse(overview.contains("GeekModuleLabel("), "Every overview card uses GeekModuleHeader")
        let battery = try XCTUnwrap(overview.components(separatedBy: "struct GeekBatteryPresentation: View {").last?
            .components(separatedBy: "struct GeekSensorsPresentation").first)
        XCTAssertTrue(battery.contains("GeekModuleHeader(title: L10n.text(\"电池\", \"Battery\"))"))
        XCTAssertFalse(battery.contains("captionStrong"), "The battery title uses the 12 pt panel-title font")
        let cpuCard = try XCTUnwrap(overview.components(separatedBy: "struct GeekProcessorPresentation: View {").last?
            .components(separatedBy: "struct GeekMemoryPresentation").first)
        // D43 (2026-10-06, supersedes the overview total of D13): the CPU card's
        // title shows the frequency and the temperature, not the total; the
        // secondary "CPU 占用" total below keeps the load color.
        XCTAssertFalse(cpuCard.contains(".foregroundStyle(processorTint)"), "D43: no load-colored total in the title")
        XCTAssertTrue(cpuCard.contains("Self.headerReadout(frequency: headerFrequencyText, temperature: headerTemperatureText)"))
        let processor = try source("GeekProcessorView.swift")
        // D119: iStat's CPU menu has no total row; its LOAD row takes the
        // place of the "CPU 占用" card, whose total carried the load color
        // (was `GeekSectionTitle(title: L10n.text("CPU 占用", "CPU USAGE"))`
        // and `Text(percentText(cpuCurrentReading?.cpuTotal)).foregroundStyle(processorTint)`).
        // The title of the load row is a heading like any other.
        XCTAssertFalse(processor.contains("private var geekProcessorUsageCard"))
        let load = try XCTUnwrap(processor.components(separatedBy: "private var geekProcessorLoadCard: some View {").last?
            .components(separatedBy: "private var geekProcessorLoadHoverTarget").first)
        // D138: iStat's 'CPU.Load' (was "负载").
        XCTAssertTrue(load.contains("GeekIStatSingleRowCard(title: L10n.text(\"平均负载量\", \"LOAD\"), value: geekProcessorLoadText)"))
        XCTAssertFalse(load.contains("processorTint"))
        let advanced = try source("MenuBarAdvancedComponents.swift")
        XCTAssertTrue(advanced.contains("panelMetricColors.cpuLoad(cpuBreakdown?.totalPercent ?? numericValue(metricValue(.cpuUsage)))"))

        let colors = PanelMetricColors()
        for (percent, expected) in [(nil, colors.cpuUser), (74.9, colors.cpuUser), (75, AppDesignTokens.Palette.warning),
                                    (89.9, AppDesignTokens.Palette.warning), (90, AppDesignTokens.Palette.destructive)] as [(Double?, Color)] {
            try assertColor(colors.cpuLoad(percent), equals: expected)
        }
    }

    func testFreeLegendDotStaysTheTrackButIsOutlined() throws {
        XCTAssertEqual(GeekMemoryComponent.allCases.filter(\.legendHasOutline), [.free])
        let composition = try source("GeekMemoryCompositionView.swift")
        XCTAssertTrue(composition.contains("if component.legendHasOutline {\n                                Circle().strokeBorder(\n                                    .tertiary,"))
        // The outline (tertiary text) must reach the 3:1 non-text contrast on
        // every card surface; the track fill alone is about 1.5:1.
        let dark = MiniWindowColorPalette.tertiaryText
        for card in [MonitorPalette.blackCard, MonitorPalette.graphiteCard] {
            XCTAssertGreaterThanOrEqual(try contrast(dark, card), 3)
        }
        XCTAssertLessThan(try contrast(MonitorPalette.blackRingTrack, MonitorPalette.blackCard), 2)
        for preset in PanelSurfacePreset.allCases {
            for mode in [MiniWindowVisualMode.black, .graphite] {
                guard let palette = preset.palette(for: mode) else { continue }
                XCTAssertGreaterThanOrEqual(try contrast(palette.tertiaryText, palette.card), 3, "\(preset) \(mode)")
            }
        }
    }

    func testGPUMemoryHasOneName() throws {
        // D138: iStat's 'GPU.Memory' and 'GPU.MEMShort' (were 显存, 显存 and
        // GPU Memory).
        let chinese = RuleTestLanguageScope(.zhHans)
        XCTAssertEqual(GeekGPUVocabulary.memory, "内存")
        XCTAssertEqual(GeekGPUVocabulary.memoryRingTitle, "内存")
        chinese.restore()
        let english = RuleTestLanguageScope(.english)
        XCTAssertEqual(GeekGPUVocabulary.memory, "Memory")
        XCTAssertEqual(GeekGPUVocabulary.memoryRingTitle, "MEM")
        english.restore()
        let processor = try source("GeekProcessorView.swift")
        XCTAssertTrue(processor.contains("title: GeekGPUVocabulary.memoryRingTitle"))
        XCTAssertTrue(processor.contains("accessibilityTitle: GeekGPUVocabulary.memory"))
        let detail = try source("GeekHoverDetailTarget.swift")
        XCTAssertTrue(detail.contains("title: GeekGPUVocabulary.memory"))
        for file in ["GeekProcessorView.swift", "GeekHoverDetailTarget.swift"] {
            XCTAssertFalse(try source(file).contains("GPU 内存"), file)
        }
    }

    func testFanRangeColumnsNameTheHardwareRange() throws {
        // The axis row's scale is rounded from the readings (fanTrendMaximum),
        // so the columns below it say which range they are.
        let sensors = try source("GeekSensorsPowerHoverDetails.swift")
        // D121 (2026-10-18): rows below the graph card (were `rangeColumn(…)`).
        XCTAssertTrue(sensors.contains("GeekIStatRow(title: L10n.text(\"硬件最低\", \"Hardware Min\"), value: rangeValues[0])"))
        XCTAssertTrue(sensors.contains("GeekIStatRow(title: L10n.text(\"硬件最高\", \"Hardware Max\"), value: rangeValues[1])"))
    }

    func testSelectedRowStrokeClearsRowTextAndStaysInsideTheCard() throws {
        // The inline-selection stroke of a row target is drawn outside the
        // row's text horizontally, within the card's content inset.
        XCTAssertGreaterThan(GeekHoverDetailMetrics.rowSelectionOutset, 0)
        XCTAssertLessThan(GeekHoverDetailMetrics.rowSelectionOutset, GeekVisualTokens.cardHorizontalPadding)
        let detail = try source("GeekHoverDetailTarget.swift")
        XCTAssertTrue(detail.contains(".padding(.horizontal, -selectionOutset)"))
        let sensors = try source("GeekSensorsView.swift")
        let fanRow = try XCTUnwrap(sensors.components(separatedBy: "private func compactFanHistoryRow").last?
            .components(separatedBy: "private var helperSummaryTint").first)
        XCTAssertTrue(fanRow.contains("selectionOutset: GeekHoverDetailMetrics.rowSelectionOutset"))
        // D119 (2026-10-18): the hardware probes list became the temperature
        // group's last row (was a card of its own), so it takes the row outset.
        let probeRow = try XCTUnwrap(sensors.components(separatedBy: "private var geekDetailedTemperatureRow").last?
            .components(separatedBy: "private var geekDetailedTemperaturesPopoverSize").first)
        XCTAssertTrue(probeRow.contains("selectionOutset: GeekHoverDetailMetrics.rowSelectionOutset"))
        XCTAssertEqual(sensors.components(separatedBy: "selectionOutset: GeekHoverDetailMetrics.rowSelectionOutset").count - 1, 4,
                       "Fan, temperature, probe and readout rows share the row outset")
    }

    func testMiniWindowUsesSpacingTokensAndGlyphSlots() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(base)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        // Spacing and padding literals of 5, 7, 9 or 10 pt are retired in every
        // form (stack, grid, padding); calibrated geometry uses named
        // constants (e.g. GeekSensorTemperatureLayout.gridColumnSpacing).
        let retired = try NSRegularExpression(pattern:
            #"spacing: (5|7|9|10)(\.0)?\b|\.padding\((\.[a-zA-Z]+, )?(5|7|9|10)(\.0)?\)"#)
        for file in files {
            let text = try source(file)
            let matches = retired.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
            XCTAssertTrue(matches.isEmpty, "\(file): \(matches)")
        }
        // Standalone icon slots draw through AppSymbolGlyph; glyphs set inline
        // with text keep following the text's font.
        let disk = try source("GeekDiskView.swift")
        XCTAssertFalse(disk.contains(".font(.system(size: 15, weight: .medium))"))
        // D119 (2026-10-18): the network drive's globe sits in a 15 pt row
        // (was the 16 pt module icon slot of the volume card).
        XCTAssertTrue(disk.contains("size: GeekDiskVolumeLayout.rowGlyphSize"))
        let memory = try source("GeekMemoryView.swift")
        XCTAssertTrue(memory.contains("AppSymbolGlyph(systemImage: isSelected ? \"checkmark.circle.fill\" : \"circle\""))
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(base + name), encoding: .utf8)
    }

    private func contrast(_ first: Color, _ second: Color) throws -> Double {
        func luminance(_ color: Color) throws -> Double {
            let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent)
                + 0.0722 * channel(rgb.blueComponent)
        }
        let a = try luminance(first)
        let b = try luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func assertColor(_ actual: Color, equals expected: Color,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let actualRGB = try XCTUnwrap(NSColor(actual).usingColorSpace(.sRGB), file: file, line: line)
        let expectedRGB = try XCTUnwrap(NSColor(expected).usingColorSpace(.sRGB), file: file, line: line)
        XCTAssertEqual(actualRGB.redComponent, expectedRGB.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.greenComponent, expectedRGB.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualRGB.blueComponent, expectedRGB.blueComponent, accuracy: 0.001, file: file, line: line)
    }
}

/// Switches L10n for one assertion block through the volatile argument
/// domain, as the secondary-menu language tests do.
@MainActor
private final class RuleTestLanguageScope {
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
