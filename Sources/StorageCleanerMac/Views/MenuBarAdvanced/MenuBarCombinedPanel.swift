import SwiftUI

struct MenuBarCombinedPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}

extension MenuBarAdvancedStatusView {
    var overviewPage: some View {
        MenuBarCombinedPanel {
            VStack(spacing: 6) {
                AdvancedPanelCard(
                    title: L10n.text("处理器活动", "Processor Activity"),
                    systemImage: AppSymbols.Monitor.processor,
                    tint: processorTint
                ) {
                    AdvancedValueRow(
                        title: L10n.text("当前总占用", "Current Total"),
                        value: metricValue(.cpuUsage),
                        tint: processorTint
                    )
                    if let frequency = overviewProcessorFrequencyText {
                        AdvancedValueRow(
                            title: L10n.text("最高集群频率", "Highest Cluster Frequency"),
                            value: frequency,
                            tint: AppDesignTokens.Palette.secondary
                        )
                    }

                    GeekPrecisionLineChart(
                        points: history,
                        series: [
                            MenuBarTelemetrySeries(id: "user", title: L10n.text("用户", "User"), channel: .cpuUser, color: resolvedPrimaryTint),
                            MenuBarTelemetrySeries(id: "system", title: L10n.text("系统", "System"), channel: .cpuSystem, color: resolvedSecondaryTint)
                        ],
                        valueRange: 0...100,
                        unit: .percent,
                        accessibilityLabel: L10n.text("最近两分钟处理器用户与系统占用堆叠图", "Stacked user and system processor activity over the last two minutes"),
                        style: .stackedBars
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)

                    AdvancedValueRow(
                        title: L10n.text("系统已运行", "System Uptime"),
                        value: uptimeText,
                        tint: AppDesignTokens.Palette.secondary
                    )
                    overviewSectionLink(.processor)
                }

                AdvancedPanelCard(
                    title: L10n.text("内存与压力", "Memory & Pressure"),
                    systemImage: AppSymbols.Monitor.memory,
                    tint: memoryTint
                ) {
                    HStack(alignment: .top, spacing: 16) {
                        PanelCircularGauge(
                            title: L10n.text("内存压力", "Memory Pressure"),
                            value: memoryPressureDisplayText,
                            progress: memoryPressureStateProgress,
                            tint: memoryTint,
                            detail: memoryPressureHeadroomText,
                            size: 72
                        )

                        GeekCombinedRing(
                            title: L10n.text("内存占用", "Memory Used"),
                            value: memoryRingUsedPercentText,
                            detail: L10n.text("三段已用", "Three used segments"),
                            progress: memoryRingUsedProgress,
                            tint: memoryTint,
                            size: 72,
                            segments: memoryRingSegments
                        )
                        .accessibilityHint(memoryRingExplanation)
                    }
                    .frame(maxWidth: .infinity)

                    overviewSectionLink(.memory)
                }

                AdvancedPanelCard(
                    title: L10n.text("磁盘空间", "Disk Capacity"),
                    systemImage: AppSymbols.Monitor.storage,
                    tint: storageTint
                ) {
                    if let storageSnapshot {
                        HStack(alignment: .center, spacing: 14) {
                            PanelCircularGauge(
                                title: L10n.text("已用", "Used"),
                                value: storagePercentText,
                                progress: storageSnapshot.userUsedRatio,
                                tint: storageTint,
                                detail: overviewVolumeName,
                                size: 68
                            )

                            VStack(spacing: 5) {
                                AdvancedValueRow(
                                    title: L10n.text("可用空间", "Available"),
                                    value: ByteFormat.storageString(storageSnapshot.userAvailableBytes),
                                    tint: storageTint
                                )
                                AdvancedValueRow(
                                    title: L10n.text("总容量", "Total"),
                                    value: ByteFormat.storageString(storageSnapshot.totalBytes),
                                    tint: AppDesignTokens.Palette.secondary
                                )
                                AdvancedValueRow(
                                    title: L10n.text("空间状态", "Capacity Status"),
                                    value: storagePressureTitle,
                                    tint: storageTint
                                )
                            }
                        }
                    } else {
                        AdvancedUnavailableRow(title: L10n.text("正在读取磁盘容量", "Reading disk capacity"))
                    }

                    if nativeDiskIOHistory.last != nil {
                        AdvancedValueRow(
                            title: L10n.text("当前磁盘 I/O", "Current Disk I/O"),
                            value: L10n.text(
                                "读 \(geekDiskReadRateText) · 写 \(geekDiskWriteRateText)",
                                "Read \(geekDiskReadRateText) · Write \(geekDiskWriteRateText)"
                            ),
                            tint: AppDesignTokens.Palette.information
                        )
                    }

                    overviewSectionLink(.disk)
                }

                AdvancedPanelCard(
                    title: L10n.text("网络活动", "Network Activity"),
                    systemImage: AppSymbols.Monitor.network,
                    tint: resolvedDownloadTint
                ) {
                    AdvancedValueRow(
                        title: L10n.text("当前上下行", "Current Transfers"),
                        value: "↓ \(networkDownText)  ↑ \(networkUpText)",
                        tint: resolvedDownloadTint
                    )
                    if let interface = overviewNetworkInterfaceText {
                        AdvancedValueRow(
                            title: L10n.text("当前接口", "Current Interface"),
                            value: interface,
                            tint: AppDesignTokens.Palette.secondary
                        )
                    }

                    GeekPrecisionNetworkChart(
                        points: history,
                        accessibilityLabel: L10n.text("最近两分钟网络上下行镜像图", "Mirrored network transfers over the last two minutes")
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)

                    overviewSectionLink(.network)
                }

                AdvancedPanelCard(
                    title: L10n.text("温度、GPU 与风扇", "Temperature, GPU & Fans"),
                    systemImage: AppSymbols.Monitor.sensors,
                    tint: temperatureTint
                ) {
                    if metricAvailable(.chipTemperature) || metricAvailable(.gpuUsage) {
                        LazyVGrid(columns: metricColumns, spacing: 8) {
                            if metricAvailable(.chipTemperature) {
                                PanelCircularGauge(
                                    title: L10n.text("芯片温度", "Chip Temp"),
                                    value: metricValue(.chipTemperature),
                                    progress: temperatureProgress,
                                    tint: temperatureTint,
                                    detail: thermalStateTitle,
                                    size: 68
                                )
                            }

                            if metricAvailable(.gpuUsage) {
                                PanelCircularGauge(
                                    title: L10n.text("GPU 占用", "GPU Usage"),
                                    value: metricValue(.gpuUsage),
                                    progress: metricPercent(.gpuUsage),
                                    tint: resolvedGPUTint,
                                    detail: L10n.text("驱动统计", "Driver Reported"),
                                    size: 68
                                )
                            }
                        }
                    }

                    ForEach(fanTelemetryRows) { fan in
                        AdvancedValueRow(
                            title: fan.title,
                            value: fan.value,
                            tint: AppDesignTokens.Palette.tertiary
                        )
                    }

                    if !metricAvailable(.chipTemperature),
                       !metricAvailable(.gpuUsage),
                       fanTelemetryRows.isEmpty {
                        AdvancedUnavailableRow(title: L10n.text("当前没有可用的传感器数据", "No sensor data is currently available"))
                    }

                    overviewSectionLink(.sensors)
                }

                AdvancedPanelCard(
                    title: L10n.text("电池状态", "Battery Status"),
                    systemImage: batterySystemImage,
                    tint: batteryTint
                ) {
                    if let batterySnapshot, hasUsableBatteryData(batterySnapshot) {
                        HStack(alignment: .center, spacing: 14) {
                            PanelCircularGauge(
                                title: L10n.text("电量", "Charge"),
                                value: batterySnapshot.chargePercent.map { "\($0)%" } ?? "--",
                                progress: batterySnapshot.chargePercent.map { Double($0) / 100 },
                                tint: batteryTint,
                                detail: batteryStatusTitle,
                                size: 68
                            )

                            if let capacity = healthSummary?.batteryCapacityPercent {
                                PanelCircularGauge(
                                    title: L10n.text("最大容量", "Max Capacity"),
                                    value: "\(capacity)%",
                                    progress: min(1, max(0, Double(capacity) / 100)),
                                    tint: batteryCapacityTint(capacity),
                                    detail: L10n.text("上次健康检查", "Last Health Check"),
                                    size: 68
                                )
                            }

                            VStack(spacing: 5) {
                                AdvancedValueRow(
                                    title: L10n.text("供电来源", "Power Source"),
                                    value: batteryPowerSourceTitle,
                                    tint: batteryTint
                                )
                                if let minutes = batterySnapshot.remainingTimeMinutes {
                                    AdvancedValueRow(
                                        title: batterySnapshot.isCharging == true
                                            ? L10n.text("充满还需", "Until Full")
                                            : L10n.text("预计剩余", "Time Remaining"),
                                        value: durationMinutesText(minutes),
                                        tint: AppDesignTokens.Palette.secondary
                                    )
                                }
                            }
                        }
                    } else {
                        AdvancedUnavailableRow(title: L10n.text("未检测到可用的内置电池数据", "No internal battery data is available"))
                    }

                    overviewSectionLink(.power)
                }
            }
        }
    }

    private var overviewProcessorFrequencyText: String? {
        guard let frequencyMHz = processorTelemetry?.clusters.compactMap(\.frequencyMHz).max() else {
            return nil
        }
        return processorFrequencyText(frequencyMHz)
    }

    private var overviewVolumeName: String {
        volumeName.isEmpty ? L10n.text("系统磁盘", "System Disk") : volumeName
    }

    private var overviewNetworkInterfaceText: String? {
        guard let interface = networkInterfaceSnapshot else { return nil }

        var components = [String]()
        if let ssid = interface.ssid, !ssid.isEmpty {
            components.append(ssid)
        }
        if let interfaceName = interface.interfaceName, !interfaceName.isEmpty {
            components.append(interfaceName)
        }
        if let rate = interface.transmitRateMbps {
            components.append(String(format: "%.0f Mbps", rate))
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private func overviewSectionLink(_ section: PanelSection) -> some View {
        HStack {
            Spacer(minLength: 0)

            Button {
                selectedSection = section
                selectedRailSection = section
            } label: {
                Label(
                    L10n.text("查看\(section.title)详情", "\(section.title) Details"),
                    systemImage: AppSymbols.Panel.disclosure
                )
                .font(AdvancedPanelTypography.captionStrong)
            }
            .appButtonChrome(.disclosure)
            .foregroundStyle(.secondary)
            .help(
                L10n.text(
                    "打开\(section.title)的二级界面，查看实时指标和可用的深层信息。",
                    "Open the \(section.title) secondary view for live metrics and available deeper details."
                )
            )
            .accessibilityHint(
                L10n.text("切换到对应的二级界面", "Switches to the matching secondary view")
            )
        }
    }

    var cleanupPage: some View {
        MenuBarCombinedPanel {
            VStack(spacing: 6) {
                AdvancedPanelCard(
                    title: cleanupSummaryTitle,
                    systemImage: AppSymbols.Status.protected,
                    tint: AppDesignTokens.Palette.success
                ) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(safeCleanupBytesText)
                            .font(AdvancedPanelTypography.metricValue)
                            .foregroundStyle(AppDesignTokens.Palette.success)
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        Text(safeCleanupCountText)
                            .font(AdvancedPanelTypography.compactValue)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    if actionableCleanupItems.isEmpty {
                        AdvancedUnavailableRow(title: staleCleanupSummaryNotice)
                    } else {
                        ForEach(actionableCleanupItems) { item in
                            AdvancedCleanupItemRow(item: item)
                        }
                    }
                }

                if let memorySnapshot = processMemorySnapshot,
                   memorySnapshot.cleanupPlan.primaryAction != .observe {
                    AdvancedPanelCard(
                        title: L10n.text("内存建议", "Memory Recommendation"),
                        systemImage: AppSymbols.Monitor.memory,
                        tint: memoryTint
                    ) {
                        Text(memorySnapshot.cleanupPlan.title)
                            .font(AdvancedPanelTypography.section)
                        Text(memorySnapshot.cleanupPlan.detail)
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        AdvancedValueRow(
                            title: L10n.text("预计可回收", "Estimated Recoverable"),
                            value: ByteFormat.string(memorySnapshot.cleanupPlan.estimatedRecoverableBytes),
                            tint: memoryTint
                        )
                    }
                }

                AppButton(
                    title: L10n.text("查看并确认清理项", "Review and Confirm Cleanup"),
                    systemImage: AppSymbols.Panel.nonDestructiveCleanup,
                    controlSize: .small,
                    fillsWidth: true
                ) {
                    openApp(filter: .green)
                }

            }
        }
        }

}
