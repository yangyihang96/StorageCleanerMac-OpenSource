import SwiftUI

extension MenuBarAdvancedStatusView {
    var geekProcessorPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.cpu) { geekProcessorActivityHoverTarget }
            liveCard(.cpu) { geekProcessorCoreCard }
            liveCard(.cpu) { geekProcessorFrequencyCard }
            liveCard(.energyProcesses) { geekProcessorProcessCard }
            if showsExtendedGeekDetails {
                liveCard(.sensors) { geekProcessorGPUHoverTarget }
                liveCard(.cpu) { geekProcessorUsageHoverTarget }
                liveCard(.cpu) { geekProcessorUptimeHoverTarget }
            }
        }

    }

    @ViewBuilder
    private var geekProcessorFrequencyCard: some View {
        let rows = geekFrequencyReadouts
        if rows.isEmpty {
            // Preserve real IOReport readings when available; otherwise use the
            // same passive helper leaf and missing-state card as sensors/power.
            GeekHelperPowerMetricsCards(monitor: store.helperPowerMetricsMonitor) { presentation in
                geekHelperReadoutCard(L10n.text("频率", "FREQUENCY"), rows: presentation.frequencyRows,
                    unavailableText: presentation.unavailableText)
                    .help(presentation.helpText)
            }
        } else {
            geekSensorReadoutCard(L10n.text("频率", "FREQUENCY"), rows: rows)
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
                samplingInterval: store.menuBarRefreshInterval.seconds,
                isUpdating: cpuDisplayedHistory.isUpdating
            )
        }
    }

    private var geekProcessorCoreCard: some View {
        GeekCombinedCard(
            height: GeekProcessorCoreLayout.cardHeight(
                for: geekProcessorCoreReadings.count,
                groupCount: geekProcessorCoreGroups.count
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
                    ForEach(geekProcessorCoreGroups) { group in
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
                        .frame(minHeight: GeekProcessorCoreLayout.legendRowHeight)
                    }
                }
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.secondary)
            }
            .padding(.top, MiniWindowStyleTokens.rowSpacing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var geekProcessorProcessCard: some View {
        GeekProcessorProcessList(
            apps: geekCPUAppsByUsage,
            geekOnDemandSnapshotStatusText: geekOnDemandSnapshotStatusText,
            isLoading: store.isLoadingEnergyImpact || store.isMenuBarProcessSamplePending,
            showsExtendedDetails: showsExtendedGeekDetails,
            nothingMeasured: geekOnDemandSnapshotNothingMeasured
        )
    }

    private var geekProcessorGPUCard: some View {
        GeekCombinedCard(height: 86) {
            VStack(spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    GeekSectionTitle(title: "GPU")

                    Spacer(minLength: 0)
                }

                HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                    GeekCombinedRing(
                        title: "GPU",
                        value: metricValue(.gpuUsage),
                        progress: metricPercent(.gpuUsage),
                        tint: resolvedGPUTint,
                        size: 56
                    )

                    GeekCombinedRing(
                        title: GeekGPUVocabulary.memoryRingTitle,
                        value: geekProcessorGPUMemoryPercent.map { "\(Int($0.rounded()))%" } ?? "--",
                        progress: geekProcessorGPUMemoryPercent.map { $0 / 100 },
                        tint: geekProcessorGPUMemoryTint,
                        size: 56,
                        accessibilityTitle: GeekGPUVocabulary.memory
                    )

                    GeekCombinedRing(
                        title: L10n.text("温度", "TMP"),
                        value: geekProcessorGPUTemperature.map(geekProcessorTemperatureText) ?? "--",
                        progress: geekProcessorGPUTemperature.map { min(1, max(0, $0 / 100)) },
                        tint: geekProcessorGPUTemperature.map(geekProcessorTemperatureTint) ?? .secondary,
                        size: 56,
                        accessibilityTitle: L10n.text("温度", "Temperature")
                    )

                    geekProcessorGPUFrequencyRing
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// BOARD N16-1: the GPU's frequency ring (iStat shows usage, memory,
    /// temperature and frequency); the arc is the share of the highest
    /// operating point.
    private var geekProcessorGPUFrequencyRing: some View {
        let reading = processorTelemetry?.gpu
        let ring = GeekGPUFrequencyPresentation.ringValue(reading)
        return GeekCombinedRing(
            title: L10n.text("频率", "FREQ"),
            value: ring.value,
            detail: ring.unit,
            progress: GeekGPUFrequencyPresentation.ringProgress(reading),
            tint: resolvedGPUTint,
            size: 56,
            accessibilityTitle: L10n.text("GPU 频率", "GPU Frequency")
        )
        .help(GeekGPUFrequencyPresentation.readout(reading, sampledAt: auxiliaryState.processorTelemetryRefreshedAt).note)
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
                points: geekMetricHistory(.gpu),
                duration: geekMetricRange(.gpu).duration,
                isAvailable: metricAvailable(.gpuUsage),
                currentValue: metricValue(.gpuUsage),
                memoryValue: geekProcessorGPUMemoryPercent.map { "\(Int($0.rounded()))%" },
                temperatureValue: geekProcessorGPUTemperature.map(geekProcessorTemperatureText),
                memoryTint: geekProcessorGPUMemoryTint,
                temperatureTint: geekProcessorGPUTemperature.map(geekProcessorTemperatureTint) ?? .secondary,
                isUpdating: geekMetricIsUpdating(.gpu),
                sampledAt: monitorSnapshot?.gpuReadingDate
            )
        }
    }

    /// GPU memory is a share of physical memory, not the system memory
    /// pressure level; it uses the memory data color in the ring and legend.
    private var geekProcessorGPUMemoryTint: Color {
        panelMetricColors.memoryApp
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

    // The sensors page draws the same GPU temperature; share its color rule
    // (the CPU page used caution yellow at 80 °C where sensors used warning).
    private func geekProcessorTemperatureTint(_ value: Double) -> Color {
        geekTemperatureTint(value)
    }

    private var geekProcessorUsageCard: some View {
        GeekCombinedCard(height: 25) {
            HStack(alignment: .firstTextBaseline, spacing: MiniWindowStyleTokens.inlineSpacing) {
                GeekSectionTitle(title: L10n.text("CPU 占用", "CPU USAGE"))
                Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)
                // The load color is on the total (the data); the title keeps
                // the section-header color. (D43: the overview CPU card's
                // title shows the frequency and temperature instead.)
                HStack(alignment: .firstTextBaseline, spacing: MiniWindowStyleTokens.rowSpacing) {
                    Text(percentText(cpuCurrentReading?.cpuTotal))
                        .foregroundStyle(processorTint)
                    Text(geekProcessorUsageBreakdownText)
                        .foregroundStyle(.primary)
                }
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
                total: cpuCurrentReading?.cpuTotal,
                applications: geekCurrentCPUUserPercent,
                system: geekCurrentCPUSystemPercent,
                points: cpuChartHistory,
                duration: cpuChartRange.duration,
                samplingInterval: store.menuBarRefreshInterval.seconds
            )
        }
    }

    /// Follows the total: "· 用户 22% · 系统 12%". One CPU vocabulary across
    /// the mini window (用户 / 系统), as in the chart legend and inspector.
    private var geekProcessorUsageBreakdownText: String {
        let applications = percentText(geekCurrentCPUUserPercent)
        let system = percentText(geekCurrentCPUSystemPercent)
        return L10n.text(
            "· 用户 \(applications) · 系统 \(system)",
            "· User \(applications) · System \(system)"
        )
    }

    private var geekProcessorUptimeCard: some View {
        GeekCombinedCard(height: 25) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                GeekSectionTitle(title: L10n.text("运行时间", "UPTIME"))
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
        guard let bootAt = monitorSnapshot?.systemBootAt else { return "—" }
        return PanelTimestampFormat.monthDayAndTime(bootAt)
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
        GeekProcessorCorePresentation.groups(
            levels: processorTelemetry?.performanceLevels ?? [],
            usageValues: monitorSnapshot?.cpuCoreUsagePercent ?? [],
            logicalCoreCount: ProcessInfo.processInfo.processorCount
        ).map { group in
            let levelTitle = group.levelName.map(processorLevelTitle)
            return GeekProcessorCoreGroup(
                id: group.id,
                title: levelTitle.map { L10n.text($0, "\($0) Cores") }
                    ?? L10n.text("逻辑核心", "Logical Cores"),
                count: group.count,
                sourceOffset: group.sourceOffset,
                averageUsagePercent: group.averageUsagePercent,
                tint: group.colorRole.map(geekProcessorCoreTint) ?? processorTint
            )
        }
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
            return Array(MiniWindowDemoData.preparedProcesses.cpu.prefix(
                GeekProcessorProcessList.maximumRows(extended: showsExtendedGeekDetails)))
        }
#endif
        return Array((store.menuBarPreparedProcesses?.cpu ?? []).prefix(
            GeekProcessorProcessList.maximumRows(extended: showsExtendedGeekDetails)))
    }

    private func geekProcessorCoreTint(for role: GeekProcessorCoreColorRole) -> Color {
        switch role {
        case .secondary: resolvedSecondaryTint
        case .primary: resolvedPrimaryTint
        case .yellow: colorScheme == .light ? MonitorPalette.lightYellow : MonitorPalette.yellow
        case .green: colorScheme == .light ? MonitorPalette.color(0x398520) : MonitorPalette.green
        }
    }
}

/// One name for the GPU's share of memory on the CPU page ring and in the
/// GPU history legend: 显存 / GPU Memory. The 56-pt ring abbreviates the
/// English to MEM (like TMP beside it) and keeps the full name for VoiceOver.
enum GeekGPUVocabulary {
    static var memory: String { L10n.text("显存", "GPU Memory") }
    static var memoryRingTitle: String { L10n.text("显存", "MEM") }
}

enum GeekProcessorCoreLayout {
    static let columnCount = 9
    static let ringSize: CGFloat = 28
    static let valueFontSize: CGFloat = 8
    static let spacing: CGFloat = 3
    static let minimumCardHeight: CGFloat = 102
    static let legendRowHeight: CGFloat = 14
    private static let nonLegendHeight: CGFloat = 12

    static func rowCount(for coreCount: Int) -> Int {
        max(1, (max(1, coreCount) + columnCount - 1) / columnCount)
    }

    static func cardHeight(for coreCount: Int, groupCount: Int = 2) -> CGFloat {
        max(
            minimumCardHeight,
            nonLegendHeight + CGFloat(max(1, groupCount)) * legendRowHeight
                + CGFloat(rowCount(for: coreCount)) * (ringSize + spacing)
        )
    }
}

enum GeekProcessorCoreColorRole: Int, CaseIterable {
    case secondary, primary, yellow, green

    static func forDisplayIndex(_ index: Int) -> Self {
        allCases[max(0, index) % allCases.count]
    }
}

/// Presentation-only grouping; source offsets stay native even when display order changes.
enum GeekProcessorCorePresentation {
    struct Group: Equatable {
        let id: String
        let levelName: String?
        let count: Int
        let sourceOffset: Int
        let averageUsagePercent: Double?
        let colorRole: GeekProcessorCoreColorRole?
    }

    static func groups(
        levels: [CPUPerformanceStateService.PerformanceLevel],
        usageValues: [Double],
        logicalCoreCount: Int
    ) -> [Group] {
        func average(_ samples: some Sequence<Double>) -> Double? {
            let finiteSamples = samples.filter(\.isFinite)
            return finiteSamples.isEmpty ? nil
                : finiteSamples.reduce(0, +) / Double(finiteSamples.count)
        }
        guard !levels.isEmpty else {
            return [Group(
                id: "logical", levelName: nil, count: max(1, logicalCoreCount),
                sourceOffset: 0, averageUsagePercent: average(usageValues), colorRole: nil
            )]
        }
        let sourceOffsets = GeekProcessorCoreLevelOrdering.sourceOffsets(levels)
        return GeekProcessorCoreLevelOrdering.ordered(levels).enumerated().map { offset, level in
            let count = max(0, level.coreCount)
            let sourceOffset = sourceOffsets[level.index] ?? 0
            return Group(
                id: "level-\(level.index)", levelName: level.name, count: count,
                sourceOffset: sourceOffset,
                averageUsagePercent: average(usageValues.dropFirst(sourceOffset).prefix(count)),
                colorRole: .forDisplayIndex(offset)
            )
        }
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

/// The processor page's process card: the processes with the most CPU in
/// the latest on-demand snapshot.
struct GeekProcessorProcessList: View {
    let apps: [EnergyImpactApp]
    let geekOnDemandSnapshotStatusText: String
    let isLoading: Bool
    let showsExtendedDetails: Bool
    /// Review P2-8: the first measurement did not come in time; the header's
    /// help and the empty list say so.
    var nothingMeasured = false

    var body: some View {
        GeekCombinedCard(
            height: showsExtendedDetails ? 111 : 75
        ) {
            VStack(alignment: .leading, spacing: 3) {
                GeekProcessListHeader(
                    title: L10n.text("进程", "PROCESSES"),
                    status: geekOnDemandSnapshotStatusText,
                    help: L10n.text(
                        "按需快照 · \(geekOnDemandSnapshotStatusText)\(GeekOnDemandSnapshotFreshness.nothingMeasuredReason(nothingMeasured))",
                        "On-demand snapshot · \(geekOnDemandSnapshotStatusText)\(GeekOnDemandSnapshotFreshness.nothingMeasuredReason(nothingMeasured))"
                    ),
                    columns: [GeekProcessListColumn(id: "cpu", title: L10n.text("占用", "CPU"),
                                                    accessibilityLabel: L10n.text("CPU 占用", "CPU usage"))]
                )

                Group {
                    if apps.isEmpty {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Group {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text(nothingMeasured ? GeekOnDemandSnapshotFreshness.nothingMeasuredText : "—")
                                        .font(AdvancedPanelTypography.body)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            Spacer(minLength: 0)
                        }
                    } else {
                        VStack(spacing: Self.rowSpacing) {
                            ForEach(apps) { app in
                                GeekCPUProcessRow(app: app)
                            }
                        }
                    }
                }
                // Room for every row the card can list, however many the
                // latest snapshot has: the 111 / 75 pt minimum held one row
                // less, so the card (and the page, and the whole cascade)
                // grew and shrank as the number of busy processes crossed it.
                .frame(minHeight: Self.rowsHeight(extended: showsExtendedDetails), alignment: .top)
            }
        }
    }

    /// The most processes the card lists (`geekCPUAppsByUsage`).
    static func maximumRows(extended: Bool) -> Int { extended ? 5 : 3 }

    static func rowsHeight(extended: Bool) -> CGFloat {
        let rows = CGFloat(maximumRows(extended: extended))
        return rows * MiniWindowStyleTokens.dataRowHeight + (rows - 1) * Self.rowSpacing
    }

    private static let rowSpacing: CGFloat = 1
}

private struct GeekCPUProcessRow: View {
    let app: EnergyImpactApp

    var body: some View {
        HStack(spacing: 6) {
            GeekSecondaryProcessIcon(path: app.iconPath)

            Text(app.name)
                .font(AdvancedPanelTypography.body)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(app.cpuPercentText)
                .font(AdvancedPanelTypography.body)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(minHeight: MiniWindowStyleTokens.dataRowHeight)
        .help(L10n.text("最近一次按需 CPU 测量", "Latest on-demand CPU measurement"))
        .accessibilityElement(children: .combine)
    }
}
