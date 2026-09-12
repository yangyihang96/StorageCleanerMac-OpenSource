import SwiftUI

struct MenuBarProcessorPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}

extension MenuBarAdvancedStatusView {
    var processorPage: some View {
        MenuBarProcessorPanel {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    AdvancedCompactGauge(
                        title: L10n.text("总占用", "Total"),
                        value: percentText(cpuBreakdown?.totalPercent),
                        progress: percentProgress(cpuBreakdown?.totalPercent),
                        tint: processorTint
                    )
                    AdvancedCompactGauge(
                        title: L10n.text("用户", "User"),
                        value: percentText(cpuBreakdown?.userPercent),
                        progress: percentProgress(cpuBreakdown?.userPercent),
                        tint: resolvedPrimaryTint
                    )
                    AdvancedCompactGauge(
                        title: L10n.text("系统", "System"),
                        value: percentText(cpuBreakdown?.systemPercent),
                        progress: percentProgress(cpuBreakdown?.systemPercent),
                        tint: resolvedSecondaryTint
                    )
                    if metricAvailable(.gpuUsage) {
                        AdvancedCompactGauge(
                            title: "GPU",
                            value: metricValue(.gpuUsage),
                            progress: metricPercent(.gpuUsage),
                            tint: resolvedGPUTint
                        )
                    }
                }

                if let processorTelemetry {
                    AdvancedPanelCard(
                        title: L10n.text("处理器信息", "Processor Details"),
                        systemImage: AppSymbols.Monitor.processor,
                        tint: processorTint
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(processorTelemetry.processorModel)
                                .font(AdvancedPanelTypography.section)
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                            Text(processorTopologyText)
                                .font(AdvancedPanelTypography.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !processorTelemetry.clusters.isEmpty {
                            Divider()

                            ForEach(processorTelemetry.clusters, id: \.identifier) { cluster in
                                AdvancedProcessorClusterRow(
                                    title: processorClusterTitle(cluster),
                                    detail: L10n.text("\(cluster.coreCount) 核", "\(cluster.coreCount) cores"),
                                    frequency: cluster.frequencyMHz.map(processorFrequencyText),
                                    voltage: cluster.voltageVolts.map(processorVoltageText),
                                    tint: processorClusterTint(cluster)
                                )
                            }
                        }
                    }
                }

                AdvancedPanelCard(
                    title: L10n.text("实时活动", "Live Activity"),
                    systemImage: AppSymbols.Navigation.overview,
                    tint: processorTint
                ) {
                    GeekPrecisionLineChart(
                        points: history,
                        series: Array(processorChartSeries.prefix(2)),
                        valueRange: 0...100,
                        unit: .percent,
                        accessibilityLabel: L10n.text("最近两分钟处理器用户与系统逐点采样图", "Per-sample processor user and system activity over the last two minutes"),
                        style: .stackedBars
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)
                }

                AdvancedPanelCard(
                    title: L10n.text("CPU 使用情况", "CPU Usage"),
                    systemImage: AppSymbols.Panel.utilization,
                    tint: AppDesignTokens.Palette.secondary
                ) {
                    HStack(spacing: 0) {
                        AdvancedPlainMetric(title: L10n.text("总占用", "Total"), value: percentText(cpuBreakdown?.totalPercent))
                        AdvancedPlainMetric(title: L10n.text("应用", "Apps"), value: percentText(cpuBreakdown?.userPercent))
                        AdvancedPlainMetric(title: L10n.text("系统", "System"), value: percentText(cpuBreakdown?.systemPercent))
                    }

                    Divider()

                    AdvancedValueRow(title: L10n.text("运行时间", "Uptime"), value: uptimeText, tint: AppDesignTokens.Palette.secondary)
                    AdvancedValueRow(title: L10n.text("系统热状态", "Thermal State"), value: thermalStateTitle, tint: thermalStateTint)
                    if metricAvailable(.chipTemperature) {
                        AdvancedValueRow(title: L10n.text("芯片最高温", "Peak Chip Temp"), value: metricValue(.chipTemperature), tint: temperatureTint)
                    }
                }

                if let measurement = store.energyImpactSnapshot, !geekEnergyApps.isEmpty {
                    AdvancedPanelCard(
                        title: L10n.text("最近一次按需应用测量", "Latest On-Demand App Measurement"),
                        systemImage: AppSymbols.Panel.powerLimit,
                        tint: AppDesignTokens.Palette.warning
                    ) {
                        AdvancedValueRow(
                            title: L10n.text("测量时间", "Measured At"),
                            value: timestampText(measurement.generatedAt),
                            tint: .secondary
                        )
                        ForEach(geekEnergyApps.prefix(3)) { app in
                            AdvancedValueRow(
                                title: app.name,
                                value: "CPU \(app.cpuPercentText) · \(app.currentPowerWattsText)",
                                tint: AppDesignTokens.Palette.warning
                            )
                        }
                        Text(L10n.text("这是最近一次按需测量，不是实时进程排行。", "This is the latest on-demand measurement, not a live process ranking."))
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        }

}
