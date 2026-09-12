import SwiftUI

struct MenuBarDiskPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}

extension MenuBarAdvancedStatusView {
    var diskPage: some View {
        MenuBarDiskPanel {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    AdvancedCompactGauge(
                        title: volumeName,
                        value: storagePercentText,
                        progress: storageSnapshot?.userUsedRatio,
                        tint: storageTint
                    )

                    VStack(spacing: 0) {
                        AdvancedValueRow(
                            title: L10n.text("总容量", "Total"),
                            value: storageSnapshot.map { ByteFormat.storageString($0.totalBytes) } ?? "--",
                            tint: AppDesignTokens.Palette.information
                        )
                        AdvancedValueRow(
                            title: L10n.text("已使用", "Used"),
                            value: storageSnapshot.map { ByteFormat.storageString($0.userUsedBytes) } ?? "--",
                            tint: storageTint
                        )
                        AdvancedValueRow(
                            title: L10n.text("系统可用", "System Available"),
                            value: storageSnapshot.map { ByteFormat.storageString($0.userAvailableBytes) } ?? "--",
                            tint: AppDesignTokens.Palette.success
                        )
                        AdvancedValueRow(
                            title: L10n.text("当前严格空闲", "Current Strict Free"),
                            value: storageSnapshot.map { ByteFormat.storageString($0.availableBytes) } ?? "--",
                            tint: AppDesignTokens.Palette.tertiary
                        )
                        AdvancedValueRow(
                            title: L10n.text("可回收估算", "Reclaimable Estimate"),
                            value: storageSnapshot.map { ByteFormat.storageString($0.reclaimableEstimateBytes) } ?? "--",
                            tint: AppChartPalette.cpuSystem
                        )
                        AdvancedValueRow(
                            title: L10n.text("空间状态", "Space Status"),
                            value: storagePressureTitle,
                            tint: storageTint
                        )
                    }
                }
                .padding(10)
                .background(.primary.opacity(colorScheme == .dark ? 0.045 : 0.028), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                AdvancedPanelCard(
                    title: L10n.text("原生磁盘 I/O · 仅当前页面采样", "Native Disk I/O · Sampled Only on This Page"),
                    systemImage: AppSymbols.Navigation.overview,
                    tint: AppDesignTokens.Palette.information
                ) {
                    GeekDiskIOChart(
                        points: nativeDiskIOHistory,
                        accessibilityLabel: L10n.text("原生磁盘读写逐点采样图", "Per-sample native disk read and write activity")
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)

                    AdvancedValueRow(title: L10n.text("当前读取", "Read Now"), value: geekDiskReadRateText, tint: AppDesignTokens.Palette.sensitive)
                    AdvancedValueRow(title: L10n.text("当前写入", "Write Now"), value: geekDiskWriteRateText, tint: AppDesignTokens.Palette.information)
                    AdvancedValueRow(title: L10n.text("读取 IOPS", "Read IOPS"), value: geekDiskReadIOPSText, tint: AppDesignTokens.Palette.sensitive)
                    AdvancedValueRow(title: L10n.text("写入 IOPS", "Write IOPS"), value: geekDiskWriteIOPSText, tint: AppDesignTokens.Palette.information)
                    AdvancedValueRow(title: L10n.text("样本数", "Samples"), value: "\(nativeDiskIOHistory.count)", tint: AppDesignTokens.Palette.secondary)

                    if let counters = nativeDiskIOCounters {
                        Divider()
                        AdvancedValueRow(title: L10n.text("累计读取", "Data Read"), value: ByteFormat.string(Int64(clamping: counters.readBytes)), tint: AppDesignTokens.Palette.sensitive)
                        AdvancedValueRow(title: L10n.text("累计写入", "Data Written"), value: ByteFormat.string(Int64(clamping: counters.writtenBytes)), tint: AppDesignTokens.Palette.information)
                        AdvancedValueRow(title: L10n.text("原生驱动", "Native Drivers"), value: "\(counters.driverCount)", tint: AppDesignTokens.Palette.secondary)
                    }
                }

                if hasCachedDiskHealth {
                    AdvancedPanelCard(
                        title: L10n.text("上次健康检查", "Last Health Check"),
                        systemImage: AppSymbols.Status.protected,
                        tint: AppDesignTokens.Palette.secondary
                    ) {
                        if let smartStatus = healthSummary?.diskSMARTStatus {
                            AdvancedValueRow(
                                title: "SMART",
                                value: diskSMARTStatusText(smartStatus),
                                tint: diskSMARTStatusTint(smartStatus)
                            )
                        }
                        if let diskStatus = healthSummary?.diskStatusText {
                            AdvancedValueRow(
                                title: L10n.text("磁盘状态", "Disk Status"),
                                value: diskStatus,
                                tint: AppDesignTokens.Palette.information
                            )
                        }
                        if let delta = healthSummary?.capacitySevenDayDeltaBytes {
                            AdvancedValueRow(
                                title: L10n.text("7 日可用容量", "7-day Available Space"),
                                value: capacitySevenDayDeltaText(delta),
                                tint: capacityDeltaTint(delta)
                            )
                        }
                        if let backupStatus = healthSummary?.backupStatusText {
                            AdvancedValueRow(
                                title: L10n.text("备份", "Backup"),
                                value: backupStatus,
                                tint: AppDesignTokens.Palette.secondary
                            )
                        }
                    }
                }

                AdvancedPanelCard(
                    title: L10n.text("可处理空间", "Actionable Storage"),
                    systemImage: AppSymbols.Monitor.cleanup,
                    tint: AppDesignTokens.Palette.success
                ) {
                    AdvancedValueRow(title: L10n.text("上次扫描可清理", "Last Scan Cleanable"), value: safeCleanupBytesText, tint: AppDesignTokens.Palette.success)
                    AdvancedValueRow(title: L10n.text("上次扫描项目", "Last Scan Items"), value: safeCleanupCountText, tint: AppDesignTokens.Palette.success)
                }

                HStack(spacing: 8) {
                    AppButton(
                        title: L10n.text("查看清理项", "Review Cleanup"),
                        systemImage: AppSymbols.Panel.nonDestructiveCleanup,
                        controlSize: .small,
                        fillsWidth: true
                    ) {
                        openApp(filter: .green)
                    }
                    AppButton(
                        title: L10n.text("查看大型文件", "Review Large Files"),
                        systemImage: AppSymbols.Navigation.fileAnalysis,
                        controlSize: .small,
                        fillsWidth: true
                    ) {
                        openApp(filter: .largeFiles)
                    }
                }

                AdvancedPanelCard(
                    title: L10n.text("可操作项目", "Actionable Items"),
                    systemImage: AppSymbols.Panel.details,
                    tint: AppDesignTokens.Palette.success
                ) {
                    if actionableCleanupItems.isEmpty {
                        AdvancedUnavailableRow(title: staleCleanupSummaryNotice)
                    } else {
                        ForEach(actionableCleanupItems.prefix(3)) { item in
                            AdvancedCleanupItemRow(item: item)
                        }
                    }
                }
            }
        }
        }

}
