import SwiftUI

// Value-only presentation components shared by live sampling and settings previews.
// No service, coordinator, singleton, task or external effect is allowed here.

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
    /// (iStat), only what was read.
    var headerFrequencyText: String? = nil
    var headerTemperatureText: String? = nil
    var headerReadoutTint: Color = .primary
    private var currentReading: MenuBarTelemetryPoint? { currentPoint ?? cpuChartHistory.last }

    /// "4.43 GHz · 80°C"; only the parts that were read; nil for none.
    static func headerReadout(frequency: String?, temperature: String?) -> String? {
        let parts = [frequency, temperature].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var geekCurrentCPUUserPercent: Double? { currentReading?.cpuUser }
    private var geekCurrentCPUSystemPercent: Double? { currentReading?.cpuSystem }
    private func percentText(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }

    /// The CPU total beside the history (D39: the live reading while the
    /// history is not prepared, not "—").
    static func totalText(history: [MenuBarTelemetryPoint], current: MenuBarTelemetryPoint?) -> String {
        (current ?? history.last)?.cpuTotal.map { String(format: "%.0f%%", $0) } ?? "—"
    }

    var body: some View {
        GeekCombinedCard(height: GeekPanelLayout.overviewProcessorCardHeight) {
            VStack(spacing: 1) {
                // D43: the title's trailing readout is the frequency and the
                // temperature (iStat); the legend expresses the usage. The
                // total stays the header's help and spoken value: the header
                // is one accessibility element ("CPU", the readout) whose
                // value is the total (review P2-2; on a plain HStack the
                // value need not be read).
                let total = Self.totalText(history: cpuChartHistory, current: currentPoint)
                GeekModuleHeader(systemImage: AppSymbols.Monitor.processor, title: "CPU") {
                    if let readout = Self.headerReadout(frequency: headerFrequencyText, temperature: headerTemperatureText) {
                        Text(readout)
                            .font(AdvancedPanelTypography.body)
                            .foregroundStyle(headerReadoutTint)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .help(L10n.text("CPU 总占用 \(total)", "CPU total \(total)"))
                .accessibilityValue(L10n.text("总占用 \(total)", "Total \(total)"))
                // Audit only: the total is "—".
                .menuBarPresentationProbe("cpu.placeholder", when: currentReading?.cpuTotal == nil)

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
                    cpuSamplingInterval: samplingInterval
                )
                .frame(height: GeekPanelLayout.overviewProcessorChartHeight)
                .opacity(isUpdating ? GeekHistoryPlotBlock<EmptyView>.updatingOpacity : 1)
                .menuBarTraceChartIsStale(isUpdating)

                HStack(spacing: 8) {
                    GeekCombinedLegendMetric(
                        title: L10n.text("用户", "User"),
                        value: percentText(geekCurrentCPUUserPercent),
                        color: geekCPUUserBarColor
                    )
                    GeekCombinedLegendMetric(
                        title: L10n.text("系统", "System"),
                        value: percentText(geekCurrentCPUSystemPercent),
                        color: geekCPUSystemBarColor
                    )
                    Spacer(minLength: 0)
                    Text("0–100%")
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help(L10n.text("固定利用率量程；悬停可查看估算信息与实测峰值", "Fixed utilization scale; hover for estimates and observed peaks"))
                }
            }
        }
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
        GeekCombinedCard(height: GeekPanelLayout.overviewMemoryCardHeight) {
            VStack(alignment: .leading, spacing: 3) {
                GeekModuleHeader(systemImage: AppSymbols.Monitor.memory, title: L10n.text("内存", "Memory"))
                // D43: pressure on the left, usage on the right (iStat).
                HStack(spacing: 36) {
                    GeekCombinedRing(title: L10n.text("压力评估", "Pressure estimate"),
                        value: pressure.map { "\($0)%" } ?? "—", progress: pressure.map { Double($0) / 100 },
                        tint: memoryTint, size: GeekVisualTokens.overviewMemoryGaugeSize,
                        fixedValueFontSize: 28, strokeWidth: GeekVisualTokens.gaugeStrokeWidth(size: GeekVisualTokens.overviewMemoryGaugeSize))
                    GeekCombinedRing(
                        title: L10n.text("占用", "Used"),
                        value: memoryRingUsedPercentText,
                        progress: memoryRingUsedProgress,
                        tint: metricColors.memoryApp,
                        size: GeekVisualTokens.overviewMemoryGaugeSize,
                        segments: memoryRingSegments,
                        fixedValueFontSize: 24
                    )
                }
                .frame(maxWidth: .infinity)
            }

        }
        }
}

struct GeekNetworkPresentation: View {
    // Download at the existing 11 pt font, its 9 pt dot and 4 pt gap
    // require 64.84 pt. Equal 72 pt columns leave a 116 pt plot at the
    // production overview width, without shrinking either label.
    static let valueColumnWidth: CGFloat = 72

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
        GeekCombinedCard(height: GeekPanelLayout.overviewNetworkCardHeight) {
            VStack(spacing: 2) {
                GeekModuleHeader(systemImage: AppSymbols.Monitor.network, title: L10n.text("网络", "Network"))

                HStack(spacing: 6) {
                    GeekLiveNetworkValue(
                        title: L10n.text("上传", "Upload"),
                        value: networkUpText,
                        tint: resolvedUploadTint
                    )
                    .frame(width: Self.valueColumnWidth)
                    .overviewLabelLayoutProbe("overview.network.upload")

                    GeekPrecisionNetworkChart(
                        points: networkChartHistory,
                        accessibilityLabel: L10n.text(
                            "网络柱状图：每根柱代表一次采样，上方是上传，下方是下载，左旧右新",
                            "Network bars: each bar is one sample; upload is above and download is below, oldest on the left"
                        ),
                        duration: networkChartRange.duration,
                        showsLegend: false,
                        showsTimelineLabels: false,
                        horizontalInset: 0
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: GeekPanelLayout.overviewNetworkChartHeight)
                    .opacity(isUpdating ? GeekHistoryPlotBlock<EmptyView>.updatingOpacity : 1)
                    .menuBarTraceChartIsStale(isUpdating)
                    .overviewLabelLayoutProbe("overview.network.chart")

                    GeekLiveNetworkValue(
                        title: L10n.text("下载", "Download"),
                        value: networkDownText,
                        tint: resolvedDownloadTint
                    )
                    .frame(width: Self.valueColumnWidth)
                    .overviewLabelLayoutProbe("overview.network.download")
                }
                .overviewLabelLayoutProbe("overview.network.row")
            }
        }
        }
}

struct GeekDiskPresentation: View {
    @Environment(\.panelMetricColors) private var metricColors
    let storageSnapshot: StorageCapacitySnapshot?
    let volumeName: String
    let geekPrimaryDiskHealthText: String?
    let geekPrimaryDiskHealthTint: Color
    let healthHelp: String

    /// The level-two volume row's sentence: "44% 已用 · 560 GB 可用".
    static func capacitySummary(_ storageSnapshot: StorageCapacitySnapshot) -> String {
        GeekDiskCapacityWording.volumeSummary(
            usedPercent: storageSnapshot.userUsedPercent,
            available: ByteFormat.storageString(storageSnapshot.userAvailableBytes)
        )
    }

    var body: some View {
        GeekCombinedCard(height: GeekPanelLayout.overviewDiskCardHeight) {
            if let storageSnapshot {
                VStack(alignment: .leading, spacing: 2) {
                    // D14: the card shows the used share, like the level-two
                    // ring and the level-three chart: "44% 已用 · 560 GB 可用"
                    // above a bar filled to the used share.
                    GeekModuleHeader(systemImage: AppSymbols.Monitor.storage, title: volumeName) {
                        if let health = geekPrimaryDiskHealthText {
                            HStack(spacing: 3) {
                                Circle().fill(geekPrimaryDiskHealthTint).frame(width: 5, height: 5)
                                Text(L10n.text("健康度 \(health)", "Health \(health)"))
                            }
                            .font(AdvancedPanelTypography.caption)
                            .monospacedDigit()
                            .help(healthHelp)
                        }
                    }

                    Text(Self.capacitySummary(storageSnapshot))
                        .font(AdvancedPanelTypography.body)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(GeekDiskCapacityWording.availableHelp)

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.22))
                            // The used share, in the color of the
                            // level-two volume ring (orange / red when the
                            // volume runs low).
                            Capsule()
                                .fill(GeekDiskVolumeColors.capacityTint(
                                    capacity: storageSnapshot, metricColors: metricColors
                                ))
                                .frame(width: proxy.size.width * storageSnapshot.userUsedRatio)
                        }
                    }
                    .frame(height: 6)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    Text(L10n.text("总容量 \(ByteFormat.storageString(storageSnapshot.totalBytes))", "Total \(ByteFormat.storageString(storageSnapshot.totalBytes))"))
                        .font(AdvancedPanelTypography.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)

                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Self.capacitySummary(storageSnapshot))
                .accessibilityHint(GeekDiskCapacityWording.availableHelp)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L10n.text("正在采样", "Sampling"))
            }
        }
        }
}

struct GeekBatteryPresentation: View {
    @Environment(\.panelMetricColors) private var metricColors
    let percent: Int?
    let geekOverviewPowerSourceAndModeTitle: String
    let geekOverviewBatteryHelpText: String

    var body: some View {
        let charge = percent.map { Double($0) / 100 }
        return GeekCombinedCard(
            height: GeekPanelLayout.overviewPowerCardHeight
        ) {
            VStack(alignment: .leading, spacing: MiniWindowStyleTokens.rowSpacing) {
                HStack(alignment: .center, spacing: MiniWindowStyleTokens.inlineSpacing) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The shared 12 pt module header; the 16 pt icon slot
                        // keeps the row height the 11 pt label had.
                        GeekModuleHeader(systemImage: AppSymbols.Monitor.battery, title: L10n.text("电池", "Battery"))
                        Text(percent.map { "\($0)%" } ?? "--")
                            .font(.system(size: 18, weight: .regular))
                            .monospacedDigit()
                    }
                    // Its natural width, so the power source text beside it
                    // can never truncate the title.
                    .fixedSize()

                    Spacer(minLength: MiniWindowStyleTokens.rowSpacing)

                    Text(geekOverviewPowerSourceAndModeTitle)
                        .font(AdvancedPanelTypography.body)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .layoutPriority(1)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.14))
                        if let charge {
                            Capsule()
                                .fill(metricColors.battery)
                                .frame(width: proxy.size.width * min(1, max(0, charge)))
                        }
                    }
                }
                .frame(height: 7)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
            .help(geekOverviewBatteryHelpText)
            .accessibilityLabel(L10n.text("电池状态", "Battery Status"))
            .accessibilityValue(geekOverviewBatteryHelpText)
        }
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
        GeekCombinedCard(height: GeekPanelLayout.overviewSensorsCardHeight) {
                VStack(alignment: .leading, spacing: 4) {
                    GeekModuleHeader(systemImage: AppSymbols.Monitor.sensors, title: L10n.text("传感器", "Sensors")) {
                        if let fanControlEntry, fanControlEntry.showsControl {
                            FanControlEntryRow(state: fanControlEntry, isHeader: true)
                                .overviewLabelLayoutProbe("overview.sensor.entry")
                        }
                    }
                    .overviewLabelLayoutProbe("overview.sensor.header")
                    // Keep the original 72 pt readouts, including at the narrowest
                    // card width. Only the gaps flex; an entry never shrinks a ring.
                    HStack(spacing: 0) {
                        Button { openDetail() } label: {
                            GeekCombinedRing(
                                title: "CPU",
                                value: geekCompactTemperatureText,
                                detail: geekCompactFrequencyText,
                                progress: temperatureProgress,
                                tint: temperatureTint,
                                size: 72,
                                labelPlacement: .aboveValue,
                                strokeWidth: 4
                            )
                            .overviewLabelLayoutProbe("overview.sensor.cpu")
                        }
                        .help(L10n.text("芯片汇总温度；圆环量程0–100°C，不是使用率。点击查看温度详情。", "Aggregated chip temperature; ring scale 0–100°C, not utilization. Open temperature details."))
                        Spacer(minLength: 0).frame(maxWidth: 16)
                        Button { openDetail() } label: {
                            GeekCombinedRing(
                                title: "GPU",
                                value: geekOverviewGPUTemperature.map { String(format: "%.0f°C", $0) } ?? gpuUsageText,
                                detail: gpuRingDetail,
                                progress: geekOverviewGPUTemperature.map { $0 / 100 } ?? gpuUsageProgress,
                                tint: resolvedGPUTint,
                                size: 72,
                                labelPlacement: .aboveValue,
                                strokeWidth: 4
                            )
                            .overviewLabelLayoutProbe("overview.sensor.gpu")
                        }
                        .help(L10n.text("有温度时量程0–100°C；缺少温度时明确显示GPU占用，量程0–100%。", "Temperature scale 0–100°C when available; otherwise explicitly displays GPU utilization, 0–100%."))
                        Spacer(minLength: 0).frame(maxWidth: 16)
                        Button { openDetail() } label: {
                            GeekCombinedRing(
                                title: geekFanTelemetry.fanCount > 1 ? L10n.text("风扇均值", "Fans") : L10n.text("风扇", "Fan"),
                                value: geekFanTelemetry.actualRPM.map(SystemFanSpeedFormat.number) ?? (geekFanTelemetry.isFanless ? L10n.text("无风扇", "Fanless") : "—"),
                                detail: geekFanTelemetry.actualRPM != nil ? "rpm" : (geekFanTelemetry.isSampling ? L10n.text("采样中", "Sampling") : L10n.text("不可用", "Unavailable")),
                                progress: geekFanTelemetry.percentage.map { $0 / 100 },
                                // Same exit as the fan speed history.
                                tint: metricColors.sensorGraph(chartAccent: panelChartAccentColor),
                                size: 72,
                                labelPlacement: .aboveValue,
                                strokeWidth: 4,
                                accessibilityTitle: geekFanTelemetry.fanCount > 1 ? L10n.text("风扇均值", "Fans average") : nil
                            )
                            .overviewLabelLayoutProbe("overview.sensor.fan")
                        }
                        .help(L10n.text("实际RPM；多风扇显示算术平均，详情保留每个风扇。仅有可靠最低/最高转速时绘制归一化圆弧，否则保留中性环。", "Actual RPM, arithmetic mean for multiple fans; individual readings remain in details. A normalized arc requires reliable minimum/maximum RPM; otherwise the track stays neutral."))
                    }
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .frame(maxWidth: .infinity)
                }
            
        }
        .overviewLabelLayoutProbe("overview.sensor.card")
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
