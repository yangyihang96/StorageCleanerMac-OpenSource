import SwiftUI

extension MenuBarAdvancedStatusView {
    var geekProcessorPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.cpu) { geekProcessorActivityHoverTarget }
            liveCard(.cpu) { geekProcessorCoreCard }
            liveCard(.energyProcesses) { geekProcessorProcessCard }
            if showsExtendedGeekDetails {
                liveCard(.sensors) { geekProcessorGPUHoverTarget }
                liveCard(.cpu) { geekProcessorUsageHoverTarget }
                liveCard(.cpu) { geekProcessorUptimeHoverTarget }
            }
        }

    }

    private var geekProcessorActivityHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("CPU 活动三级详情", "CPU Activity Deep Detail"),
            chartRangeMetric: .cpu,
            popoverSize: GeekHoverDetailMetrics.cpuHistorySize
        ) {
            geekProcessorCard
        } detail: {
            GeekProcessorActivityHoverDetail(
                points: cpuChartHistory,
                duration: cpuChartRange.duration,
                userValue: percentText(geekCurrentCPUUserPercent),
                systemValue: percentText(geekCurrentCPUSystemPercent),
                samplingInterval: store.menuBarRefreshInterval.seconds
            )
        }
    }

    private var geekProcessorCoreCard: some View {
        GeekCombinedCard(
            height: GeekProcessorCoreLayout.cardHeight(
                for: geekProcessorCoreReadings.count
            )
        ) {
            VStack(spacing: 3) {
                LazyVGrid(
                    columns: geekProcessorCoreColumns,
                    spacing: GeekProcessorCoreLayout.spacing
                ) {
                    ForEach(geekProcessorCoreReadings) { core in
                        GeekCombinedRing(
                            title: core.title,
                            value: core.usagePercent.map { "\(Int($0.rounded()))" } ?? "—",
                            progress: core.usagePercent.map { $0 / 100 },
                            tint: core.tint,
                            size: GeekProcessorCoreLayout.ringSize,
                            fixedValueFontSize: GeekProcessorCoreLayout.valueFontSize
                        )
                    }
                }

                VStack(spacing: 0) {
                    ForEach(geekProcessorCoreGroups.prefix(2)) { group in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(group.tint)
                                .frame(width: 7, height: 7)
                            Text(group.title)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(group.averageUsagePercent.map { "\(Int($0.rounded()))%" } ?? "--")
                                .monospacedDigit()
                        }
                    }
                }
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var geekProcessorProcessCard: some View {
        GeekCombinedCard(
            height: showsExtendedGeekDetails ? 111 : 75
        ) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.text("进程", "PROCESSES"))
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(processorTint)
                        .lineLimit(1)
                        .help(L10n.text(
                            "按需快照 · \(geekOnDemandSnapshotStatusText)",
                            "On-demand snapshot · \(geekOnDemandSnapshotStatusText)"
                        ))
                        .accessibilityValue(geekOnDemandSnapshotStatusText)

                    Spacer(minLength: 0)
                    Text(geekOnDemandSnapshotStatusText)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if geekCPUAppsByUsage.isEmpty {
                    Spacer(minLength: 0)
                    Group {
                        if store.isLoadingEnergyImpact {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("—")
                                .font(AdvancedPanelTypography.body)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                } else {
                    VStack(spacing: 1) {
                        ForEach(geekCPUAppsByUsage) { app in
                            GeekCPUProcessRow(app: app)
                        }
                    }
                }
            }
        }
    }

    private var geekProcessorGPUCard: some View {
        GeekCombinedCard(height: 86) {
            VStack(spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("GPU")
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(resolvedGPUTint)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 5) {
                    GeekCombinedRing(
                        title: "GPU",
                        value: metricValue(.gpuUsage),
                        progress: metricPercent(.gpuUsage),
                        tint: resolvedGPUTint,
                        size: 56
                    )

                    GeekCombinedRing(
                        title: L10n.text("显存", "MEM"),
                        value: geekProcessorGPUMemoryPercent.map { "\(Int($0.rounded()))%" } ?? "--",
                        progress: geekProcessorGPUMemoryPercent.map { $0 / 100 },
                        tint: memoryTint,
                        size: 56
                    )

                    GeekCombinedRing(
                        title: L10n.text("温度", "TMP"),
                        value: geekProcessorGPUTemperature.map(geekProcessorTemperatureText) ?? "--",
                        progress: geekProcessorGPUTemperature.map { min(1, max(0, $0 / 100)) },
                        tint: geekProcessorGPUTemperature.map(geekProcessorTemperatureTint) ?? .secondary,
                        size: 56
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var geekProcessorGPUHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("GPU 活动三级详情", "GPU Activity Deep Detail"),
            chartRangeMetric: .gpu,
            popoverSize: GeekHoverDetailMetrics.historySize
        ) {
            geekProcessorGPUCard
        } detail: {
            GeekGPUHoverDetail(
                points: geekChartHistory,
                duration: geekChartDuration,
                isAvailable: metricAvailable(.gpuUsage),
                currentValue: metricValue(.gpuUsage),
                memoryValue: geekProcessorGPUMemoryPercent.map { "\(Int($0.rounded()))%" },
                temperatureValue: geekProcessorGPUTemperature.map(geekProcessorTemperatureText)
            )
        }
    }

    private var geekProcessorGPUTemperature: Double? {
        monitorSnapshot?.temperatureReadings?.first { $0.zone == .gpu }?.celsius
    }

    private var geekProcessorGPUMemoryPercent: Double? {
        guard let bytes = monitorSnapshot?.gpuMemoryUsedBytes,
              ProcessInfo.processInfo.physicalMemory > 0 else { return nil }
        return min(
            100,
            max(0, Double(bytes) / Double(ProcessInfo.processInfo.physicalMemory) * 100)
        )
    }

    private func geekProcessorTemperatureText(_ value: Double) -> String {
        "\(Int(value.rounded()))°C"
    }

    private func geekProcessorTemperatureTint(_ value: Double) -> Color {
        switch value {
        case 90...: AppDesignTokens.Palette.destructive
        case 80...: AppDesignTokens.Palette.caution
        default: resolvedThermalTint
        }
    }

    private var geekProcessorUsageCard: some View {
        GeekCombinedCard(height: 25) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("CPU 占用", "CPU USAGE"))
                    .foregroundStyle(processorTint)
                Spacer(minLength: 6)
                Text(geekProcessorUsageSummaryText)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            .font(AdvancedPanelTypography.body)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    private var geekProcessorUsageHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("CPU 占用三级详情", "CPU Usage Deep Detail"),
            chartRangeMetric: .cpu,
            popoverSize: GeekHoverDetailMetrics.cpuUsageSize
        ) {
            geekProcessorUsageCard
        } detail: {
            GeekProcessorUsageHoverDetail(
                total: cpuChartHistory.last?.cpuTotal,
                applications: geekCurrentCPUUserPercent,
                system: geekCurrentCPUSystemPercent,
                points: cpuChartHistory,
                duration: cpuChartRange.duration,
                samplingInterval: store.menuBarRefreshInterval.seconds
            )
        }
    }

    private var geekProcessorUsageSummaryText: String {
        let total = percentText(cpuChartHistory.last?.cpuTotal)
        let applications = percentText(geekCurrentCPUUserPercent)
        let system = percentText(geekCurrentCPUSystemPercent)
        return L10n.text(
            "\(total) · 应用 \(applications) · 系统 \(system)",
            "\(total) · Apps \(applications) · System \(system)"
        )
    }

    private var geekProcessorUptimeCard: some View {
        GeekCombinedCard(height: 25) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("运行时间", "UPTIME"))
                    .foregroundStyle(processorTint)
                Spacer(minLength: 6)
                Text(uptimeText)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            .font(AdvancedPanelTypography.body)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    private var geekProcessorUptimeHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("运行时间三级详情", "Uptime Deep Detail"),
            popoverSize: GeekHoverDetailMetrics.uptimeSize
        ) {
            geekProcessorUptimeCard
        } detail: {
            GeekProcessorUptimeHoverDetail(
                uptime: uptimeText,
                poweredOnAt: geekProcessorPoweredOnAtText
            )
        }
    }

    private var geekProcessorPoweredOnAtText: String {
        guard let seconds = monitorSnapshot?.systemUptimeSeconds, seconds > 0 else { return "--" }
        return PanelTimestampFormat.monthDayAndTime(Date().addingTimeInterval(-seconds))
    }

    private var geekProcessorCoreColumns: [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(GeekProcessorCoreLayout.ringSize),
                spacing: GeekProcessorCoreLayout.spacing
            ),
            count: GeekProcessorCoreLayout.columnCount
        )
    }

    private var geekProcessorCoreGroups: [GeekProcessorCoreGroup] {
        let sourceLevels = processorTelemetry?.performanceLevels ?? []
        let levels = GeekProcessorCoreLevelOrdering.ordered(sourceLevels)
        let sourceOffsets = GeekProcessorCoreLevelOrdering.sourceOffsets(sourceLevels)
        let usageValues = monitorSnapshot?.cpuCoreUsagePercent ?? []
        if !levels.isEmpty {
            return levels.enumerated().map { colorOffset, level in
                let count = max(0, level.coreCount)
                let sourceOffset = sourceOffsets[level.index] ?? 0
                let samples = usageValues
                    .dropFirst(sourceOffset)
                    .prefix(count)
                    .filter(\.isFinite)
                let average = samples.isEmpty
                    ? nil
                    : samples.reduce(0, +) / Double(samples.count)
                let levelTitle = processorLevelTitle(level.name)
                return GeekProcessorCoreGroup(
                    id: "level-\(level.index)",
                    title: L10n.text(levelTitle, "\(levelTitle) Cores"),
                    count: count,
                    sourceOffset: sourceOffset,
                    averageUsagePercent: average,
                    tint: geekProcessorCoreTint(at: colorOffset)
                )
            }
        }

        return [
            GeekProcessorCoreGroup(
                id: "logical",
                title: L10n.text("逻辑核心", "Logical Cores"),
                count: max(1, ProcessInfo.processInfo.processorCount),
                sourceOffset: 0,
                averageUsagePercent: usageValues.isEmpty
                    ? nil
                    : usageValues.reduce(0, +) / Double(usageValues.count),
                tint: processorTint
            )
        ]
    }

    private var geekProcessorCoreReadings: [GeekProcessorCoreReading] {
        let values = monitorSnapshot?.cpuCoreUsagePercent ?? []
        return geekProcessorCoreGroups.flatMap { group in
            (0..<group.count).map { index in
                let valueIndex = group.sourceOffset + index
                return GeekProcessorCoreReading(
                    id: "\(group.id)-\(index)",
                    title: "\(group.title) \(index + 1)",
                    usagePercent: values.indices.contains(valueIndex) ? values[valueIndex] : nil,
                    tint: group.tint
                )
            }
        }
    }

    private var geekCPUAppsByUsage: [EnergyImpactApp] {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return Array(geekEnergyApps.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(showsExtendedGeekDetails ? 5 : 3))
        }
#endif
        return Array((store.menuBarPreparedProcesses?.cpu ?? []).prefix(showsExtendedGeekDetails ? 5 : 3))
    }

    private func geekProcessorCoreTint(at index: Int) -> Color {
        let colors = [
            resolvedSecondaryTint,
            resolvedPrimaryTint,
            AppDesignTokens.Palette.diagnostic,
        ]
        return colors[index % colors.count]
    }
}

enum GeekProcessorCoreLayout {
    static let columnCount = 9
    static let ringSize: CGFloat = 28
    static let valueFontSize: CGFloat = 8
    static let spacing: CGFloat = 3
    static let minimumCardHeight: CGFloat = 102
    private static let nonGridHeight: CGFloat = 40

    static func rowCount(for coreCount: Int) -> Int {
        max(1, (max(1, coreCount) + columnCount - 1) / columnCount)
    }

    static func cardHeight(for coreCount: Int) -> CGFloat {
        max(
            minimumCardHeight,
            nonGridHeight + CGFloat(rowCount(for: coreCount)) * (ringSize + spacing)
        )
    }
}

enum GeekProcessorCoreLevelOrdering {
    static func ordered(
        _ levels: [CPUPerformanceStateService.PerformanceLevel]
    ) -> [CPUPerformanceStateService.PerformanceLevel] {
        levels.sorted { lhs, rhs in
            let lhsPriority = displayPriority(for: lhs.name)
            let rhsPriority = displayPriority(for: rhs.name)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.index < rhs.index
        }
    }

    static func sourceOffsets(
        _ levels: [CPUPerformanceStateService.PerformanceLevel]
    ) -> [Int: Int] {
        var nextOffset = 0
        var offsets: [Int: Int] = [:]
        for level in levels.sorted(by: { $0.index < $1.index }) {
            offsets[level.index] = nextOffset
            nextOffset += max(0, level.coreCount)
        }
        return offsets
    }

    private static func displayPriority(for name: String) -> Int {
        let normalized = name.lowercased()
        if normalized.contains("performance") { return 0 }
        if normalized.contains("efficiency") { return 1 }
        if normalized.contains("super") { return 2 }
        return 1
    }
}

private struct GeekProcessorCoreGroup: Identifiable {
    let id: String
    let title: String
    let count: Int
    let sourceOffset: Int
    let averageUsagePercent: Double?
    let tint: Color
}

private struct GeekProcessorCoreReading: Identifiable {
    let id: String
    let title: String
    let usagePercent: Double?
    let tint: Color
}

private struct GeekCPUProcessRow: View {
    let app: EnergyImpactApp

    var body: some View {
        HStack(spacing: 6) {
            AdvancedAppIcon(path: app.iconPath, fallback: "app.fill")
                .scaleEffect(0.62)
                .frame(width: 14, height: 14)

            Text(app.name)
                .font(AdvancedPanelTypography.body)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(app.cpuPercentText)
                .font(AdvancedPanelTypography.body)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(minHeight: 14)
        .help(L10n.text("最近一次按需 CPU 测量", "Latest on-demand CPU measurement"))
        .accessibilityElement(children: .combine)
    }
}
