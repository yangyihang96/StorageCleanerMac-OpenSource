import SwiftUI

struct MenuBarMemoryPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}

extension MenuBarAdvancedStatusView {
    var memoryPage: some View {
        MenuBarMemoryPanel {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    AdvancedCompactGauge(
                        title: L10n.text("已用", "Used"),
                        value: memorySnapshot.flatMap(\.measuredUsedRatio).map {
                            String(format: "%.0f%%", $0 * 100)
                        } ?? "—",
                        progress: memorySnapshot?.measuredUsedRatio,
                        tint: memoryTint
                    )
                    AdvancedCompactGauge(
                        title: L10n.text("可用", "Available"),
                        value: memorySnapshot.flatMap(\.measuredAvailableRatio).map {
                            String(format: "%.0f%%", $0 * 100)
                        } ?? "—",
                        progress: memorySnapshot?.measuredAvailableRatio,
                        tint: AppDesignTokens.Palette.success
                    )
                }

                AdvancedPanelCard(
                    title: L10n.text("内存占用 · 最近 120 秒", "Memory Usage · Last 120 Seconds"),
                    systemImage: AppSymbols.Panel.activity,
                    tint: memoryTint
                ) {
                    GeekPrecisionLineChart(
                        points: memoryHistory,
                        series: [
                            MenuBarTelemetrySeries(
                                id: "memory",
                                title: L10n.text("内存", "Memory"),
                                channel: .memory,
                                color: memoryTint
                            )
                        ],
                        valueRange: 0...100,
                        unit: .percent,
                        accessibilityLabel: L10n.text("最近两分钟内存占用逐点采样图", "Per-sample memory usage over the last two minutes"),
                        style: .stackedBars
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)
                }

                if let snapshot = memorySnapshot {
                    AdvancedPanelCard(
                        title: L10n.text("原始 VM 计数（可能重叠）", "Raw VM Counters (May Overlap)"),
                        systemImage: AppSymbols.Panel.processList,
                        tint: AppDesignTokens.Palette.secondary
                    ) {
                        Text(L10n.text("以下计数不可直接相加。", "These counters must not be added together."))
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                        AdvancedValueRow(title: "File Backed", value: ByteFormat.string(snapshot.fileBackedBytes), tint: AppDesignTokens.Palette.tertiary)
                        AdvancedValueRow(title: L10n.text("非活动", "Inactive"), value: ByteFormat.string(snapshot.inactiveBytes), tint: AppDesignTokens.Palette.secondary)
                        AdvancedValueRow(title: L10n.text("可清除（估算）", "Purgeable (Est.)"), value: ByteFormat.string(snapshot.purgeableBytes), tint: AppDesignTokens.Palette.success)
                        AdvancedValueRow(title: "Speculative", value: ByteFormat.string(snapshot.speculativeBytes), tint: AppDesignTokens.Palette.freshness)
                    }
                }

                if !actionableMemoryApps.isEmpty {
                    AdvancedPanelCard(
                        title: L10n.text("可退出的高占用应用", "High-Usage Apps You Can Quit"),
                        systemImage: AppSymbols.Panel.powerState,
                        tint: AppDesignTokens.Palette.warning
                    ) {
                        ForEach(actionableMemoryApps) { app in
                            AdvancedAppUsageRow(app: app)
                        }
                    }
                }

                if !geekTopProcesses.isEmpty {
                    AdvancedPanelCard(
                        title: L10n.text("高占用进程", "Top Resident Processes"),
                        systemImage: AppSymbols.Panel.processList,
                        tint: AppDesignTokens.Palette.warning
                    ) {
                        ForEach(geekTopProcesses.prefix(6)) { process in
                            AdvancedValueRow(
                                title: "\(process.name) · PID \(process.id)",
                                value: ByteFormat.string(process.residentBytes),
                                tint: AppDesignTokens.Palette.warning
                            )
                        }
                    }
                }

                AppButton(
                    title: L10n.text("打开内存管理", "Open Memory Management"),
                    systemImage: AppSymbols.Panel.openProcesses
                ) {
                    openApp(filter: .memory)
                }
            }
        }
        }

}
