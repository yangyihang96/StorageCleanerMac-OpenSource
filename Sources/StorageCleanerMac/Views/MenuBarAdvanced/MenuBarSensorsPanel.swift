import SwiftUI

struct MenuBarSensorsPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}

extension MenuBarAdvancedStatusView {
    var sensorsPage: some View {
        MenuBarSensorsPanel {
            VStack(spacing: 6) {
                LazyVGrid(columns: metricColumns, spacing: 8) {
                    ForEach(sensorTiles) { tile in
                        AdvancedMetricTile(
                            title: tile.title,
                            value: tile.value,
                            detail: tile.detail,
                            tint: tile.tint,
                            progress: tile.progress
                        )
                    }
                }

                AdvancedPanelCard(
                    title: L10n.text("传感器详情", "Sensor Details"),
                    systemImage: AppSymbols.Panel.sensorData,
                    tint: temperatureTint
                ) {
                    AdvancedValueRow(title: L10n.text("系统热状态", "Thermal State"), value: thermalStateTitle, tint: thermalStateTint)

                    if metricAvailable(.chipTemperature) {
                        AdvancedValueRow(title: L10n.text("芯片最高温度", "Chip Peak Temperature"), value: metricValue(.chipTemperature), tint: temperatureTint)
                    }
                    if !fanTelemetryRows.isEmpty {
                        ForEach(fanTelemetryRows) { row in
                            AdvancedValueRow(title: row.title, value: row.value, tint: AppDesignTokens.Palette.tertiary)
                        }
                    } else if metricAvailable(.fanSpeed) {
                        AdvancedValueRow(title: L10n.text("风扇平均转速", "Average Fan Speed"), value: metricValue(.fanSpeed), tint: AppDesignTokens.Palette.tertiary)
                    }
                    if let fanStatistics = GeekSeriesStatistics(values: history.compactMap(\.fanRPM)) {
                        AdvancedValueRow(title: L10n.text("最近两分钟风扇平均", "2-minute Fan Average"), value: GeekChartUnit.fanRPM.formatted(fanStatistics.average), tint: AppDesignTokens.Palette.tertiary)
                        AdvancedValueRow(title: L10n.text("最近两分钟风扇峰值", "2-minute Fan Peak"), value: GeekChartUnit.fanRPM.formatted(fanStatistics.maximum), tint: AppDesignTokens.Palette.tertiary)
                    }
                    if metricAvailable(.gpuUsage) {
                        AdvancedValueRow(title: L10n.text("GPU 驱动负载", "GPU Driver Load"), value: metricValue(.gpuUsage), tint: AppDesignTokens.Palette.diagnostic)
                    }
                }

                if metricAvailable(.chipTemperature) {
                    AdvancedPanelCard(
                        title: L10n.text("温度趋势", "Temperature Trend"),
                        systemImage: AppSymbols.Monitor.advanced,
                        tint: AppDesignTokens.Palette.warning
                    ) {
                        GeekPrecisionLineChart(
                            points: history,
                            series: [
                                MenuBarTelemetrySeries(
                                    id: "temperature",
                                    title: L10n.text("芯片温度", "Chip Temp"),
                                    channel: .chipTemperature,
                                    color: AppDesignTokens.Palette.warning
                                )
                            ],
                            valueRange: 20...110,
                            unit: .temperature,
                            accessibilityLabel: L10n.text("最近两分钟芯片温度逐点采样图", "Per-sample chip temperature over the last two minutes")
                        )
                        .frame(height: PanelLayoutMetrics.primaryChartHeight)
                    }
                }

                Text(L10n.text("小窗打开时，GPU、温度和风扇约每 2 秒更新；硬件未公开的项目会自动隐藏。", "While the mini window is open, GPU, temperature, and fans update about every 2 seconds. Hardware values not exposed by macOS stay hidden."))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
            }
        }
        }

}
