import SwiftUI

extension MenuBarAdvancedStatusView {
    /// D119: iStat's CPU menu (272 pt): the CPU graph, the cores and the
    /// processes, then (Geek) the GPU, the load and the uptime. The cluster
    /// frequencies are a group on the sensors page, as on iStat.
    var geekProcessorPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.cpu) { geekProcessorActivityHoverTarget }
            liveCard(.cpu) { geekProcessorCoreCard }
            liveCard(.energyProcesses) { geekProcessorProcessCard }
            if showsExtendedGeekDetails {
                liveCard(.sensors) { geekProcessorGPUHoverTarget }
                liveCard(.cpu) { geekProcessorLoadHoverTarget }
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
                samplingInterval: store.menuBarRefreshInterval.seconds,
                isUpdating: cpuDisplayedHistory.isUpdating
            )
        }
    }

    /// D119 (iStat cores section): one 18 pt ring per core, spread over the
    /// content width, rows 24 pt apart; one legend row per core type with
    /// its average.
    private var geekProcessorCoreCard: some View {
        let groups = geekProcessorCoreGroups
        let readings = geekProcessorCoreReadings
        let rows = GeekProcessorCoreLayout.rowCount(for: readings.count)
        return GeekIStatCard(height: GeekProcessorCoreLayout.cardHeight(for: readings.count, groupCount: groups.count)) {
            GeekIStatSpreadLayout(
                itemSize: GeekProcessorCoreLayout.ringSize,
                minimumSpacing: GeekProcessorCoreLayout.minimumSpacing,
                rowPitch: GeekProcessorCoreLayout.rowPitch
            ) {
                ForEach(readings) { core in
                    GeekIStatPlainRing(
                        progress: core.usagePercent.map { $0 / 100 },
                        tint: core.tint,
                        lineWidth: GeekProcessorCoreLayout.lineWidth
                    )
                    .help("\(core.title): \(core.usagePercent.map { "\(Int($0.rounded()))%" } ?? "—")")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(core.title)
                    .accessibilityValue(core.usagePercent.map { "\(Int($0.rounded()))%" } ?? "—")
                }
            }
            .geekIStatLayer(top: GeekProcessorCoreLayout.ringTop, alignment: .top)

            VStack(spacing: 0) {
                ForEach(groups) { group in
                    GeekIStatRow(
                        title: group.title,
                        value: group.averageUsagePercent.map { "\(Int($0.rounded()))%" } ?? "--",
                        dotColor: group.tint
                    )
                    .help(L10n.text("这一类核心的平均占用", "Average usage of these cores"))
                }
            }
            .geekIStatLayer(top: GeekProcessorCoreLayout.legendTop(rows: rows), alignment: .top)
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

    /// D119 (iStat GPU section, 87 pt): the title row, then the usage,
    /// memory, temperature and frequency rings (54 pt, line 4) spread over
    /// the content width.
    private var geekProcessorGPUCard: some View {
        GeekIStatCard(height: GeekIStatSectionGeometry.gpuHeight) {
            GeekModuleHeader(title: "GPU")
                .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, height: GeekIStatCardGeometry.titleHeight)

            GeekIStatSpreadLayout(itemSize: GeekIStatSectionGeometry.gpuRingSize) {
                geekProcessorGPURing(
                    title: "GPU",
                    value: metricValue(.gpuUsage),
                    progress: metricPercent(.gpuUsage),
                    tint: resolvedGPUTint
                )

                geekProcessorGPURing(
                    title: GeekGPUVocabulary.memoryRingTitle,
                    value: geekProcessorGPUMemoryPercent.map { "\(Int($0.rounded()))%" } ?? "--",
                    progress: geekProcessorGPUMemoryPercent.map { $0 / 100 },
                    tint: geekProcessorGPUMemoryTint,
                    accessibilityTitle: GeekGPUVocabulary.memory
                )

                geekProcessorGPURing(
                    title: L10n.text("温度", "TMP"),
                    value: geekProcessorGPUTemperature.map(geekProcessorTemperatureText) ?? "--",
                    progress: geekProcessorGPUTemperature.map { min(1, max(0, $0 / 100)) },
                    tint: geekProcessorGPUTemperature.map(geekProcessorTemperatureTint) ?? .secondary,
                    accessibilityTitle: L10n.text("温度", "Temperature")
                )

                geekProcessorGPUFrequencyRing
            }
            .geekIStatLayer(top: GeekIStatSectionGeometry.gpuRingTop, height: GeekIStatSectionGeometry.gpuRingSize)
        }
    }

    private func geekProcessorGPURing(
        title: String,
        value: String,
        progress: Double?,
        tint: Color,
        accessibilityTitle: String? = nil
    ) -> some View {
        GeekCombinedRing(
            title: title,
            value: value,
            progress: progress,
            tint: tint,
            size: GeekIStatSectionGeometry.gpuRingSize,
            fixedValueFontSize: GeekIStatSectionGeometry.gpuValueFontSize,
            strokeWidth: GeekIStatSectionGeometry.gpuRingLineWidth,
            accessibilityTitle: accessibilityTitle,
            fixedLabelFontSize: GeekIStatSectionGeometry.gpuLabelFontSize
        )
    }

    /// BOARD N16-1: the GPU's frequency ring (iStat shows usage, memory,
    /// temperature and frequency); the arc is the share of the highest
    /// operating point. D119: the unit is the ring's label ("0.34" over
    /// "GHZ"), as on iStat.
    private var geekProcessorGPUFrequencyRing: some View {
        let reading = processorTelemetry?.gpu
        let ring = GeekGPUFrequencyPresentation.ringValue(reading)
        return geekProcessorGPURing(
            // D138: always iStat's 'Units.GHz' (was 频率 / FREQ without a
            // frequency).
            title: "GHz",
            value: ring.value,
            progress: GeekGPUFrequencyPresentation.ringProgress(reading),
            tint: resolvedGPUTint,
            accessibilityTitle: L10n.text("GPU 频率", "GPU Frequency")
        )
        .help(GeekGPUFrequencyPresentation.readout(reading, sampledAt: auxiliaryState.processorTelemetryRefreshedAt).note)
    }

    private var geekProcessorGPUHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("GPU 活动三级详情", "GPU Activity Deep Detail"),
            chartRangeMetric: .gpu,
            popoverSize: GeekGPUHoverDetail.popoverSize
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

    /// D128: iStat's whole degrees, "45°" (was "45°C").
    private func geekProcessorTemperatureText(_ value: Double) -> String {
        IStatNumberFormat.temperature(value)
    }

    // The sensors page draws the same GPU temperature; share its color rule
    // (the CPU page used caution yellow at 80 °C where sensors used warning).
    private func geekProcessorTemperatureTint(_ value: Double) -> Color {
        geekTemperatureTint(value)
    }

    /// D119 (iStat load section, 25 pt): the 1, 5 and 15 minute load
    /// averages. It replaces the CPU usage row; the total and its user and
    /// system shares stay in the CPU graph's legend and in this row's
    /// third level.
    private var geekProcessorLoadCard: some View {
        // D138: iStat's 'CPU.Load' (was 负载).
        GeekIStatSingleRowCard(title: L10n.text("平均负载量", "LOAD"), value: geekProcessorLoadText)
            // In words, not as the bare term (1.9.10: no raw load jargon).
            .help(L10n.text(
                "过去 1、5、15 分钟里，平均有多少个线程正在运行或等待运行；超过核心数时 CPU 已忙不过来",
                "How many threads were running or waiting to run, on average, over the last 1, 5 and 15 minutes; above the core count the CPU is saturated"
            ))
    }

    private var geekProcessorLoadHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("CPU 负载三级详情", "CPU Load Deep Detail"),
            chartRangeMetric: .cpu,
            popoverSize: GeekHoverDetailMetrics.cpuLoadSize
        ) {
            geekProcessorLoadCard
        } detail: {
            GeekProcessorUsageHoverDetail(
                total: cpuCurrentReading?.cpuTotal,
                applications: geekCurrentCPUUserPercent,
                system: geekCurrentCPUSystemPercent,
                points: cpuChartHistory,
                duration: cpuChartRange.duration,
                samplingInterval: store.menuBarRefreshInterval.seconds,
                loadAverage: geekProcessorLoadText
            )
        }
    }

    /// "1.23 1.45 1.67", or a dash before the first sample.
    var geekProcessorLoadText: String {
        GeekProcessorLoadPresentation.text(monitorSnapshot?.loadAverage)
    }

    private var geekProcessorUptimeCard: some View {
        // D138: iStat's 'CPU.Uptime' (was 运行时间).
        GeekIStatSingleRowCard(title: L10n.text("电脑开启时间", "UPTIME"), value: uptimeText)
    }

    private var geekProcessorUptimeHoverTarget: some View {
        let detail = geekProcessorUptimeDetail
        return GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("运行时间三级详情", "Uptime Deep Detail"),
            popoverSize: detail.popoverSize
        ) {
            geekProcessorUptimeCard
        } detail: {
            detail
        }
    }

    /// D137: the page sizes itself by its text (iStat's uptime submenu).
    private var geekProcessorUptimeDetail: GeekProcessorUptimeHoverDetail {
        let durations = uptimeBreakdownTexts
        return GeekProcessorUptimeHoverDetail(
            poweredOnAt: geekProcessorPoweredOnAtText,
            awake: durations.awake,
            asleep: durations.asleep
        )
    }

    private var geekProcessorPoweredOnAtText: String {
        guard let bootAt = monitorSnapshot?.systemBootAt else { return "—" }
        return PanelTimestampFormat.monthDayAndTime(bootAt)
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

/// The load row's readout: the three averages to two decimals. D128:
/// iStat's `FormatNumber` (at most two, trailing zeros dropped: "1.5";
/// was "%.2f").
enum GeekProcessorLoadPresentation {
    static func text(_ load: SystemLoadAverage?) -> String {
        guard let load else { return "—" }
        return [load.oneMinute, load.fiveMinutes, load.fifteenMinutes]
            .map { $0.isFinite ? IStatNumberFormat.number($0, decimals: 2) : "—" }
            .joined(separator: " ")
    }
}

/// The GPU's share of memory, one name: iStat's 'GPU.Memory' in the GPU
/// history and for VoiceOver, its short label 'GPU.MEMShort' on the 54 pt
/// ring (like TMP beside it). D138: 内存 / Memory and 内存 / MEM (were
/// 显存 / GPU Memory and 显存 / MEM).
enum GeekGPUVocabulary {
    static var memory: String { L10n.text("内存", "Memory") }
    static var memoryRingTitle: String { L10n.text("内存", "MEM") }
}

/// D119 (iStat `CPUMenu` cores section, measured 66 pt for twelve cores of
/// two types): an 18 pt ring (line 3) per core, as many per row as fit at
/// 2 pt apart and spread over the content width; rows 24 pt apart from 10;
/// one 15 pt legend row per core type below them.
enum GeekProcessorCoreLayout {
    static let ringSize: CGFloat = 18
    static let lineWidth: CGFloat = 3
    static let minimumSpacing: CGFloat = 2
    static let ringTop: CGFloat = 10
    static let rowPitch: CGFloat = 24
    static let legendRowHeight = GeekIStatSectionGeometry.rowHeight

    /// The card's content width on the CPU page: the page width less the
    /// shell's and the card's 8 pt insets.
    static var contentWidth: CGFloat {
        MiniWindowStyleTokens.processorDetailWidth
            - 2 * MiniWindowStyleTokens.contentInset - 2 * GeekIStatCardGeometry.inset
    }

    static func columnCount(for coreCount: Int, width: CGFloat = contentWidth) -> Int {
        GeekIStatSpreadLayout.columns(count: coreCount, itemSize: ringSize, minimumSpacing: minimumSpacing, width: width)
    }

    static func rowCount(for coreCount: Int, width: CGFloat = contentWidth) -> Int {
        GeekIStatSpreadLayout.rows(count: coreCount, columns: columnCount(for: coreCount, width: width))
    }

    /// The legend starts 2 pt above the next ring row would.
    static func legendTop(rows: Int) -> CGFloat {
        ringTop + rowPitch * CGFloat(max(1, rows)) - 2
    }

    static func cardHeight(for coreCount: Int, groupCount: Int = 2, width: CGFloat = contentWidth) -> CGFloat {
        legendTop(rows: rowCount(for: coreCount, width: width))
            + legendRowHeight * CGFloat(max(1, groupCount)) + 4
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
/// the latest on-demand snapshot. D119: iStat's process section, the title
/// row with the snapshot's status, then one 15 pt row per process on the
/// 17 pt pitch (25 + 17n).
struct GeekProcessorProcessList: View {
    let apps: [EnergyImpactApp]
    let geekOnDemandSnapshotStatusText: String
    let isLoading: Bool
    let showsExtendedDetails: Bool
    /// Review P2-8: the first measurement did not come in time; the header's
    /// help and the empty list say so.
    var nothingMeasured = false

    var body: some View {
        // Room for every row the card can list, however many the latest
        // snapshot has, so the card (and the page, and the whole cascade)
        // does not grow and shrink as the number of busy processes changes.
        GeekIStatProcessCard(
            title: L10n.text("进程", "PROCESSES"),
            status: geekOnDemandSnapshotStatusText,
            help: L10n.text(
                "按需快照 · \(geekOnDemandSnapshotStatusText)\(GeekOnDemandSnapshotFreshness.nothingMeasuredReason(nothingMeasured))",
                "On-demand snapshot · \(geekOnDemandSnapshotStatusText)\(GeekOnDemandSnapshotFreshness.nothingMeasuredReason(nothingMeasured))"
            ),
            rowCapacity: Self.maximumRows(extended: showsExtendedDetails)
        ) {
            if apps.isEmpty {
                GeekIStatProcessPlaceholder(
                    isLoading: isLoading,
                    text: nothingMeasured ? GeekOnDemandSnapshotFreshness.nothingMeasuredText : "—"
                )
            } else {
                ForEach(apps) { app in
                    GeekCPUProcessRow(app: app)
                }
            }
        }
    }

    /// The most processes the card lists (`geekCPUAppsByUsage`).
    static func maximumRows(extended: Bool) -> Int { extended ? 5 : 3 }

    static func rowsHeight(extended: Bool) -> CGFloat {
        CGFloat(maximumRows(extended: extended)) * GeekIStatSectionGeometry.rowPitch
            - GeekIStatSectionGeometry.rowGap
    }
}

private struct GeekCPUProcessRow: View {
    let app: EnergyImpactApp

    var body: some View {
        // D128: iStat's process percentage, at most one decimal ("32%",
        // "4.4%"; was "%.1f%%").
        GeekIStatProcessRow(iconPath: app.iconPath, name: app.name) {
            Text(IStatNumberFormat.percent(app.cpuPercent, decimals: 1)).geekIStatValueText()
        }
        .help(L10n.text("最近一次按需 CPU 测量", "Latest on-demand CPU measurement"))
    }
}
