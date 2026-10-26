import SwiftUI

// Value-only presentation components shared by live sampling and settings previews.
// No service, coordinator, singleton, task or external effect is allowed here.
//
// D118: every card follows the iStat Menus 7.30 combined menu
// (`GeekIStatCardGeometry`, spec `2.0.1-小窗重写-20261018/01-iStat小窗规格.md` §4):
// a fixed height, no padding, each layer at its measured offset. Only the CPU
// and battery cards have a title row; the others name their module through
// the overview button's accessibility label, as iStat draws no title there.

private typealias IStat = GeekIStatCardGeometry

struct GeekProcessorPresentation: View {
    let cpuChartHistory: [MenuBarTelemetryPoint]
    let cpuChartRange: GeekChartRange
    let samplingInterval: TimeInterval
    let processorTint: Color
    let geekCPUUserBarColor: Color
    let geekCPUSystemBarColor: Color
    /// The reading shown as "now" (`MenuBarDisplayedHistory.currentReading`);
    /// the history's last point when not given (settings previews).
    var currentPoint: MenuBarTelemetryPoint? = nil
    /// The history is a window kept from before the panel was hidden (D39) or
    /// the previously selected window: the chart is dimmed as history plots
    /// are (D32) until the prepared window replaces it. The card has no axis
    /// row, so there is no "更新中…" label.
    var isUpdating = false
    /// D43: the title's trailing readout, the frequency and the temperature
    /// (iStat), only what was read. D118: in the value color, as on iStat;
    /// the temperature's color stays on the sensors ring.
    var headerFrequencyText: String? = nil
    var headerTemperatureText: String? = nil
    private var currentReading: MenuBarTelemetryPoint? { currentPoint ?? cpuChartHistory.last }

    /// "4.43 GHz, 80°"; only the parts that were read; nil for none. D128:
    /// iStat's CPU section joins them with ", " (was " · ").
    static func headerReadout(frequency: String?, temperature: String?) -> String? {
        let parts = [frequency, temperature].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var geekCurrentCPUUserPercent: Double? { currentReading?.cpuUser }
    private var geekCurrentCPUSystemPercent: Double? { currentReading?.cpuSystem }
    private func percentText(_ value: Double?) -> String { value.map(IStatNumberFormat.graphPercent) ?? "—" }

    /// The CPU total beside the history (D39: the live reading while the
    /// history is not prepared, not "—").
    static func totalText(history: [MenuBarTelemetryPoint], current: MenuBarTelemetryPoint?) -> String {
        (current ?? history.last)?.cpuTotal.map(IStatNumberFormat.graphPercent) ?? "—"
    }

    var body: some View {
        // D43: the title's trailing readout is the frequency and the
        // temperature (iStat); the legend expresses the usage. The total
        // stays the header's help and spoken value: the header is one
        // accessibility element ("CPU", the readout) whose value is the
        // total (review P2-2).
        let total = Self.totalText(history: cpuChartHistory, current: currentPoint)
        GeekIStatCard(height: GeekPanelLayout.overviewProcessorCardHeight) {
            GeekModuleHeader(title: "CPU") {
                if let readout = Self.headerReadout(frequency: headerFrequencyText, temperature: headerTemperatureText) {
                    Text(readout).geekIStatValueText()
                }
            }
            .accessibilityElement(children: .combine)
            .help(L10n.text("CPU 总占用 \(total)", "CPU total \(total)"))
            .accessibilityValue(L10n.text("总占用 \(total)", "Total \(total)"))
            // Audit only: the total is "—".
            .menuBarPresentationProbe("cpu.placeholder", when: currentReading?.cpuTotal == nil)
            .overviewLabelLayoutProbe("overview.cpu.header")
            .geekIStatLayer(top: IStat.titleTop, height: IStat.titleHeight)

            // iStat `cpu-cpu`: the graph at x 8, W − 14 wide, from 25 to
            // H − 24, user stacked under system on a fixed 0–100 % scale.
            GeekPrecisionLineChart(
                points: cpuChartHistory,
                series: [
                    MenuBarTelemetrySeries(
                        id: "user",
                        title: L10n.text("用户", "User"),
                        channel: .cpuUser,
                        color: geekCPUUserBarColor
                    ),
                    MenuBarTelemetrySeries(
                        id: "system",
                        title: L10n.text("系统", "System"),
                        channel: .cpuSystem,
                        color: geekCPUSystemBarColor
                    )
                ],
                valueRange: 0...100,
                unit: .percent,
                accessibilityLabel: L10n.text(
                    "CPU 时间历史：用户与系统显示固定时段内按测量时长加权的平均；峰值可在悬停提示中查看。短缺口估算可在悬停提示中查看，长缺口未记录，量程0至100%，左旧右新",
                    "CPU time history: user and system use time-weighted interval means; hover for observed peaks. Hover for short-gap estimates; long gaps are unrecorded. Scale 0 to 100 percent, oldest on the left"
                ),
                style: .stackedBars,
                duration: cpuChartRange.duration,
                showsLegend: false,
                showsTimelineLabels: false,
                horizontalInset: 0,
                verticalInset: 0,
                cpuSamplingInterval: samplingInterval,
                // D131: iStat's menu graph, one bar per sample.
                bucketing: .samples
            )
            .frame(height: GeekPanelLayout.overviewProcessorChartHeight)
            .opacity(isUpdating ? GeekHistoryPlotBlock<EmptyView>.updatingOpacity : 1)
            .menuBarTraceChartIsStale(isUpdating)
            .help(L10n.text("固定利用率量程 0–100%；悬停可查看估算信息与实测峰值", "Fixed utilization scale 0–100%; hover for estimates and observed peaks"))
            .overviewLabelLayoutProbe("overview.cpu.chart")
            .geekIStatLayer(top: IStat.processorGraphTop, trailing: IStat.processorGraphTrailingInset)

            // The legend row 21 pt above the bottom: two columns 8 pt apart,
            // each with its value at the column's end.
            HStack(spacing: IStat.legendColumnSpacing) {
                GeekIStatLegendColumn(
                    title: L10n.text("用户", "User"),
                    value: percentText(geekCurrentCPUUserPercent),
                    color: geekCPUUserBarColor
                )
                .overviewLabelLayoutProbe("overview.cpu.legend.user")
                GeekIStatLegendColumn(
                    title: L10n.text("系统", "System"),
                    value: percentText(geekCurrentCPUSystemPercent),
                    color: geekCPUSystemBarColor
                )
                .overviewLabelLayoutProbe("overview.cpu.legend.system")
            }
            .geekIStatLayer(top: IStat.processorHeight - IStat.legendBottomInset, height: IStat.titleHeight)
        }
        .overviewLabelLayoutProbe("overview.cpu.card")
    }
}

struct GeekMemoryPresentation: View {
    @Environment(\.panelMetricColors) private var metricColors
    let memoryRingUsedPercentText: String
    let memoryRingUsedProgress: Double?
    let memoryRingSegments: [GeekCombinedRingSegment]
    let pressure: Int?
    let memoryTint: Color

    var body: some View {
        // iStat `memory-overview`: two 96 pt rings (line 6) centered in the
        // halves, 56 pt below the top; pressure left, usage right (D43).
        GeekIStatCard(height: GeekPanelLayout.overviewMemoryCardHeight) {
            HStack(spacing: 0) {
                // D118: one-line label as on iStat; that the number is an
                // estimate stays in the card's help (D28).
                GeekCombinedRing(
                    title: L10n.text("压力", "Pressure"),
                    value: pressure.map { "\($0)%" } ?? "—",
                    progress: pressure.map { Double($0) / 100 },
                    tint: memoryTint,
                    size: IStat.memoryRingSize,
                    fixedValueFontSize: IStat.memoryValueFontSize,
                    strokeWidth: IStat.memoryRingLineWidth,
                    fixedLabelFontSize: IStat.ringLabelFontSize
                )
                .overviewLabelLayoutProbe("overview.memory.pressure")
                .frame(maxWidth: .infinity)
                // D138: iStat's 'Memory.Memory' (was 占用 / Used).
                GeekCombinedRing(
                    title: L10n.text("内存", "Memory"),
                    value: memoryRingUsedPercentText,
                    progress: memoryRingUsedProgress,
                    tint: metricColors.memoryApp,
                    size: IStat.memoryRingSize,
                    segments: memoryRingSegments,
                    fixedValueFontSize: IStat.memoryValueFontSize,
                    strokeWidth: IStat.memoryRingLineWidth,
                    fixedLabelFontSize: IStat.ringLabelFontSize
                )
                .overviewLabelLayoutProbe("overview.memory.used")
                .frame(maxWidth: .infinity)
            }
            .geekIStatLayer(top: IStat.memoryRingCenterY - IStat.memoryRingSize / 2, height: IStat.memoryRingSize)
        }
        .overviewLabelLayoutProbe("overview.memory.card")
    }
}

struct GeekNetworkPresentation: View {
    let networkUpText: String
    let networkDownText: String
    let networkChartHistory: [MenuBarTelemetryPoint]
    let networkChartRange: GeekChartRange
    let resolvedUploadTint: Color
    let resolvedDownloadTint: Color
    /// As `GeekProcessorPresentation.isUpdating`: a kept or previous window
    /// is dimmed until the prepared one replaces it (D39, D32).
    var isUpdating = false

    var body: some View {
        // iStat `network-bandwidth` (compact): an 18 pt readout centered in
        // each half with its legend below, the mirrored graph from 47 to
        // H − 10 across the card.
        GeekIStatCard(height: GeekPanelLayout.overviewNetworkCardHeight) {
            HStack(spacing: 0) {
                readout(networkUpText, title: L10n.text("上传", "Upload"), tint: resolvedUploadTint)
                    .overviewLabelLayoutProbe("overview.network.upload")
                readout(networkDownText, title: L10n.text("下载", "Download"), tint: resolvedDownloadTint)
                    .overviewLabelLayoutProbe("overview.network.download")
            }
            .overviewLabelLayoutProbe("overview.network.row")
            .geekIStatLayer(top: IStat.networkValueTop, height: IStat.networkReadoutHeight)

            GeekPrecisionNetworkChart(
                points: networkChartHistory,
                accessibilityLabel: L10n.text(
                    "网络柱状图：每根柱代表一次采样，上方是上传，下方是下载，左旧右新",
                    "Network bars: each bar is one sample; upload is above and download is below, oldest on the left"
                ),
                duration: networkChartRange.duration,
                showsLegend: false,
                showsTimelineLabels: false,
                horizontalInset: 0,
                verticalInset: 0,
                mirroredHalfInset: 0,
                // D131: iStat's menu graph, one bar per sample.
                bucketing: .samples
            )
            .frame(height: GeekPanelLayout.overviewNetworkChartHeight)
            .opacity(isUpdating ? GeekHistoryPlotBlock<EmptyView>.updatingOpacity : 1)
            .menuBarTraceChartIsStale(isUpdating)
            .overviewLabelLayoutProbe("overview.network.chart")
            .geekIStatLayer(top: IStat.networkGraphTop, trailing: IStat.processorGraphTrailingInset)
        }
    }

    private func readout(_ value: String, title: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .geekIStatValueText(size: IStat.bigValueFontSize)
                .minimumScaleFactor(0.75)
                .frame(height: IStat.networkLegendTop - IStat.networkValueTop)
            GeekIStatCenteredLegend(title: title, color: tint)
                .frame(height: IStat.titleHeight)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct GeekDiskPresentation: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.miniWindowVisualMode) private var visualMode
    let storageSnapshot: StorageCapacitySnapshot?
    let volumeName: String
    let geekPrimaryDiskHealthText: String?
    let geekPrimaryDiskHealthTint: Color
    let healthHelp: String
    /// The newest disk throughput sample; it lights iStat's read and write
    /// lights. Nil before the first sample: both lights stay at the track.
    var latestDiskIO: NativeDiskIOPoint? = nil

    /// The level-two volume row's sentence: "44% 已用 · 560 GB 可用". It is
    /// also what VoiceOver reads for the card.
    static func capacitySummary(_ storageSnapshot: StorageCapacitySnapshot) -> String {
        GeekDiskCapacityWording.volumeSummary(
            usedPercent: storageSnapshot.userUsedPercent,
            available: IStatNumberFormat.space(storageSnapshot.userAvailableBytes)
        )
    }

    /// The second row, iStat's "170.9 GB available": "560 GB 可用". D128:
    /// iStat's disk space format (was ByteCountFormatStyle's file style).
    static func availableText(_ storageSnapshot: StorageCapacitySnapshot) -> String {
        let available = IStatNumberFormat.space(storageSnapshot.userAvailableBytes)
        return L10n.text("\(available) 可用", "\(available) available")
    }

    /// D14 → D118: the ring shows the used share, as the level-two ring and
    /// the level-three chart do; the number inside it is that share.
    static func ringProgress(_ storageSnapshot: StorageCapacitySnapshot) -> Double {
        storageSnapshot.userUsedRatio
    }

    static func ringText(_ storageSnapshot: StorageCapacitySnapshot) -> String {
        "\(storageSnapshot.userUsedPercent)"
    }

    var body: some View {
        // iStat `disks-physical`: a 26 pt ring at (8, 8), the name and the
        // available space on two 15 pt rows from x 41, the read and write
        // lights at the trailing inset.
        GeekIStatCard(height: GeekPanelLayout.overviewDiskCardHeight) {
            if let storageSnapshot {
                ZStack(alignment: .top) {
                    GeekCombinedRing(
                        title: "",
                        value: Self.ringText(storageSnapshot),
                        progress: Self.ringProgress(storageSnapshot),
                        tint: GeekDiskVolumeColors.capacityTint(capacity: storageSnapshot, metricColors: metricColors),
                        size: IStat.diskRingSize,
                        strokeWidth: IStat.diskRingLineWidth
                    )
                    .overviewLabelLayoutProbe("overview.disk.ring")
                    .geekIStatLayer(top: IStat.inset, height: IStat.diskRingSize, alignment: .leading)

                    Text(volumeName)
                        .geekIStatLabelText()
                        .truncationMode(.middle)
                        .overviewLabelLayoutProbe("overview.disk.name")
                        .geekIStatLayer(top: IStat.titleTop, height: IStat.titleHeight,
                                        leading: IStat.diskTextLeading, trailing: IStat.diskTextTrailingInset,
                                        alignment: .leading)
                    Text(Self.availableText(storageSnapshot))
                        .geekIStatValueText()
                        .help(GeekDiskCapacityWording.availableHelp)
                        .overviewLabelLayoutProbe("overview.disk.available")
                        .geekIStatLayer(top: IStat.diskSecondRowTop, height: IStat.titleHeight,
                                        leading: IStat.diskTextLeading, trailing: IStat.diskTextTrailingInset,
                                        alignment: .leading)

                    VStack(spacing: IStat.diskLightSpacing) {
                        light(active: (latestDiskIO?.readBytesPerSecond ?? 0) > 0, tint: metricColors.diskRead)
                        light(active: (latestDiskIO?.writeBytesPerSecond ?? 0) > 0, tint: metricColors.diskWrite)
                    }
                    .accessibilityHidden(true)
                    .overviewLabelLayoutProbe("overview.disk.lights")
                    .geekIStatLayer(top: IStat.diskLightTop, height: IStat.diskLightColumnHeight, alignment: .trailing)
                }
                // D14: VoiceOver reads the level-two volume row's sentence.
                .accessibilityElement(children: .combine)
                .accessibilityValue(Self.capacitySummary(storageSnapshot))
                .accessibilityHint(GeekDiskCapacityWording.availableHelp)
                .help(cardHelp(storageSnapshot))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L10n.text("正在采样", "Sampling"))
            }
        }
    }

    /// The card's tooltip: the total capacity and, when it was read, the
    /// health; the former third row and title readout (D118).
    private func cardHelp(_ storageSnapshot: StorageCapacitySnapshot) -> String {
        let total = IStatNumberFormat.space(storageSnapshot.totalBytes)
        var lines = [L10n.text("总容量 \(total)", "Total \(total)")]
        if let health = geekPrimaryDiskHealthText {
            lines.append(L10n.text("健康度 \(health)", "Health \(health)") + " · " + healthHelp)
        }
        return lines.joined(separator: "\n")
    }

    private func light(active: Bool, tint: Color) -> some View {
        Circle()
            .fill(active ? tint : GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode, palette: panelChromePalette))
            .frame(width: IStat.diskLightSize, height: IStat.diskLightSize)
    }
}

struct GeekBatteryPresentation: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.miniWindowVisualMode) private var visualMode
    let percent: Int?
    let geekOverviewPowerSourceAndModeTitle: String
    let geekOverviewBatteryHelpText: String

    /// The title's trailing readout: "62% · 电源适配器 · 充电中".
    static func trailingText(percent: Int?, sourceAndMode: String) -> String {
        [percent.map { "\($0)%" }, sourceAndMode.isEmpty ? nil : sourceAndMode]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        let charge = percent.map { min(1, max(0, Double($0) / 100)) }
        // iStat `battery-combined`: the title row, then an 8 pt bar at 24.
        return GeekIStatCard(height: GeekPanelLayout.overviewPowerCardHeight) {
            GeekModuleHeader(title: L10n.text("电池", "Battery")) {
                Text(Self.trailingText(percent: percent, sourceAndMode: geekOverviewPowerSourceAndModeTitle))
                    .geekIStatValueText()
                    .truncationMode(.middle)
            }
            .overviewLabelLayoutProbe("overview.battery.header")
            .geekIStatLayer(top: IStat.titleTop, height: IStat.titleHeight)

            GeekIStatBar(progress: charge, tint: metricColors.battery,
                         track: GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode, palette: panelChromePalette))
                .overviewLabelLayoutProbe("overview.battery.bar")
                .geekIStatLayer(top: IStat.batteryBarTop, height: IStat.batteryBarHeight)
        }
        .accessibilityElement(children: .combine)
        .help(geekOverviewBatteryHelpText)
        .accessibilityLabel(L10n.text("电池状态", "Battery Status"))
        .accessibilityValue(geekOverviewBatteryHelpText)
    }
}

/// iStat's 8 pt bar (battery, swap, keyboard light): a rounded track with the
/// filled share from the leading edge. A nil progress keeps the track only.
struct GeekIStatBar: View {
    let progress: Double?
    let tint: Color
    let track: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if let progress, progress.isFinite {
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * min(1, max(0, progress)))
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityHidden(true)
    }
}

struct GeekSensorsPresentation: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.panelChartAccentColor) private var panelChartAccentColor
    let geekCompactTemperatureText: String
    let geekCompactFrequencyText: String?
    let temperatureProgress: Double?
    let temperatureTint: Color
    let geekOverviewGPUTemperature: Double?
    let gpuUsageText: String
    let gpuUsageProgress: Double?
    let resolvedGPUTint: Color
    let geekFanTelemetry: FanTelemetryState
    let openDetail: () -> Void
    /// BOARD N16-1: the GPU frequency, when it was read.
    var geekCompactGPUFrequencyText: String? = nil
    var fanControlEntry: FanControlEntryPresentation? = nil

    var gpuDetailTitle: String {
        geekOverviewGPUTemperature != nil ? L10n.text("温度", "Temp") : L10n.text("占用", "Usage")
    }

    /// Below a GPU temperature, its frequency like the CPU ring's (iStat
    /// shows both); without a reading, or below the usage, what the value is.
    var gpuRingDetail: String {
        guard geekOverviewGPUTemperature != nil, let geekCompactGPUFrequencyText else { return gpuDetailTitle }
        return geekCompactGPUFrequencyText
    }

    var body: some View {
        // iStat `sensors-overview`: three 72 pt rings (line 2) in 87 pt cells
        // at x 8, W/2 − 43.5 and W − 95, centered 44 pt below the top; the
        // card's menu ("⋮") in its top-left 24 pt corner.
        GeekIStatCard(height: GeekPanelLayout.overviewSensorsCardHeight) {
            GeekIStatSensorCells {
                cell {
                    Button { openDetail() } label: {
                        ring(title: "CPU", value: geekCompactTemperatureText, detail: geekCompactFrequencyText,
                             progress: temperatureProgress, tint: temperatureTint)
                            .overviewLabelLayoutProbe("overview.sensor.cpu")
                    }
                    .help(L10n.text("芯片汇总温度；圆环量程0–100°C，不是使用率。点击查看温度详情。", "Aggregated chip temperature; ring scale 0–100°C, not utilization. Open temperature details."))
                }
                cell {
                    Button { openDetail() } label: {
                        ring(title: "GPU",
                             value: geekOverviewGPUTemperature.map { IStatNumberFormat.temperature($0) } ?? gpuUsageText,
                             detail: gpuRingDetail,
                             progress: geekOverviewGPUTemperature.map { $0 / 100 } ?? gpuUsageProgress,
                             tint: resolvedGPUTint)
                            .overviewLabelLayoutProbe("overview.sensor.gpu")
                    }
                    .help(L10n.text("有温度时量程0–100°C；缺少温度时明确显示GPU占用，量程0–100%。", "Temperature scale 0–100°C when available; otherwise explicitly displays GPU utilization, 0–100%."))
                }
                cell {
                    Button { openDetail() } label: {
                        ring(title: geekFanTelemetry.fanCount > 1 ? L10n.text("风扇均值", "Fans") : L10n.text("风扇", "Fan"),
                             value: geekFanTelemetry.actualRPM.map(SystemFanSpeedFormat.number) ?? (geekFanTelemetry.isFanless ? L10n.text("无风扇", "Fanless") : "—"),
                             detail: geekFanTelemetry.actualRPM != nil ? "rpm" : (geekFanTelemetry.isSampling ? L10n.text("采样中", "Sampling") : L10n.text("不可用", "Unavailable")),
                             progress: geekFanTelemetry.percentage.map { $0 / 100 },
                             // Same exit as the fan speed history.
                             tint: metricColors.sensorGraph(chartAccent: panelChartAccentColor),
                             accessibilityTitle: geekFanTelemetry.fanCount > 1 ? L10n.text("风扇均值", "Fans average") : nil)
                            .overviewLabelLayoutProbe("overview.sensor.fan")
                    }
                    .help(L10n.text("实际RPM；多风扇显示算术平均，详情保留每个风扇。仅有可靠最低/最高转速时绘制归一化圆弧，否则保留中性环。", "Actual RPM, arithmetic mean for multiple fans; individual readings remain in details. A normalized arc requires reliable minimum/maximum RPM; otherwise the track stays neutral."))
                }
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .geekIStatLayer(top: (IStat.sensorsHeight - IStat.sensorRingSize) / 2, height: IStat.sensorRingSize,
                            leading: 0, trailing: 0)

            if let fanControlEntry, fanControlEntry.showsControl {
                GeekIStatCardMenuButton(state: fanControlEntry)
                    .overviewLabelLayoutProbe("overview.sensor.entry")
                    .geekIStatLayer(top: 0, height: GeekIStatCardMenuButton.side, leading: 0, alignment: .topLeading)
            }
        }
        // The card draws no title (iStat); VoiceOver still names the group
        // of three ring buttons and the fan control entry.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("传感器", "Sensors"))
        .overviewLabelLayoutProbe("overview.sensor.card")
    }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: IStat.sensorRingSize, height: IStat.sensorRingSize)
    }

    private func ring(
        title: String, value: String, detail: String?, progress: Double?, tint: Color,
        accessibilityTitle: String? = nil
    ) -> some View {
        GeekIStatSensorRing(title: title, value: value, detail: detail, progress: progress, tint: tint,
                            accessibilityTitle: accessibilityTitle)
    }
}

/// iStat's sensor ring (spec §3.4–3.5): 72 pt with a 2 pt line; the name at
/// 10 pt over a 15 pt value (19 pt without a detail) and an 11 pt thin
/// detail. The overview card and the sensors page (D119) draw the same ring.
struct GeekIStatSensorRing: View {
    let title: String
    let value: String
    var detail: String?
    let progress: Double?
    let tint: Color
    var accessibilityTitle: String? = nil

    var body: some View {
        let hasDetail = detail?.isEmpty == false
        GeekCombinedRing(
            title: title,
            value: value,
            detail: detail,
            progress: progress,
            tint: tint,
            size: IStat.sensorRingSize,
            labelPlacement: .aboveValue,
            fixedValueFontSize: hasDetail ? IStat.sensorValueFontSize : IStat.sensorValueOnlyFontSize,
            fixedDetailFontSize: IStat.sensorDetailFontSize,
            strokeWidth: IStat.sensorRingLineWidth,
            accessibilityTitle: accessibilityTitle,
            fixedLabelFontSize: IStat.ringLabelFontSize,
            detailFontWeight: .thin
        )
    }
}

/// iStat's three sensor cells: 87 pt wide at x 8, centered, and at W − 95,
/// each ring centered in its cell. A card narrower than iStat's (Settings
/// previews, test fixtures) shrinks the cells to a third of the content
/// width, never below the ring; the rings never shrink.
struct GeekIStatSensorCells: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? GeekIStatCardGeometry.cardWidth,
               height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let inset = GeekIStatCardGeometry.inset
        let cell = Self.cellWidth(cardWidth: bounds.width)
        let leadings = [bounds.minX + inset, bounds.midX - cell / 2, bounds.maxX - inset - cell]
        for (subview, leading) in zip(subviews, leadings) {
            subview.place(at: CGPoint(x: leading + cell / 2, y: bounds.minY), anchor: .top,
                          proposal: ProposedViewSize(width: cell, height: bounds.height))
        }
    }

    static func cellWidth(cardWidth: CGFloat) -> CGFloat {
        max(GeekIStatCardGeometry.sensorRingSize,
            min(GeekIStatCardGeometry.sensorCellWidth, (cardWidth - 2 * GeekIStatCardGeometry.inset) / 3))
    }
}

/// iStat's card menu: a 24 pt hit area in the card's top-left corner with
/// three dots at (8, 8), (8, 12) and (8, 16). On the sensors card it opens
/// the fan control palette (the former "风扇控制 · 状态" header entry).
struct GeekIStatCardMenuButton: View {
    static let side: CGFloat = 24
    static let dotSize: CGFloat = 2
    @Environment(\.panelChromePalette) private var panelChromePalette
    let state: FanControlEntryPresentation

    var body: some View {
        ControlPaletteAnchorButton(kind: .fan, accessibilityLabel: L10n.text("风扇控制", "Fan Control")) {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(GeekIStatCardGeometry.labelColor(panelChromePalette))
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .offset(x: 8 - Self.dotSize / 2, y: 8 + CGFloat(index) * 4 - Self.dotSize / 2)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .contentShape(Rectangle())
        }
        .help(L10n.text("风扇控制 · \(state.headerStatus)", "Fan Control · \(state.headerStatus)"))
        .accessibilityIdentifier("fan-control-entry")
        .accessibilityValue(state.status)
    }
}

private extension View {
    @ViewBuilder
    func overviewLabelLayoutProbe(_ id: String) -> some View {
        #if DEBUG
        layoutProbe(id)
        #else
        self
        #endif
    }
}
