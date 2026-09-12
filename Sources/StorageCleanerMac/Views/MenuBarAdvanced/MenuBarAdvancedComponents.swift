import AppKit
import SwiftUI

typealias AdvancedPanelTypography = MenuBarPanelTypography

enum MemorySampleStatusPresentation {
    static let refreshInterval: TimeInterval = 15

    static func evidence(snapshot: MemorySnapshot?) -> String {
        guard let snapshot else { return L10n.text("尚无内存样本", "No memory sample yet") }
        let time = snapshot.generatedAt.formatted(.dateTime.year().month().day().hour().minute().second())
        return L10n.text(
            "快照生成于 \(time)。压力为本应用根据系统数据评估的等级，不是压力百分比。",
            "Snapshot generated at \(time). Pressure is an app-assessed grade based on system data, not a pressure percentage."
        )
    }

    static func text(snapshot: MemorySnapshot?, isPaused: Bool, referenceDate: Date) -> String {
        guard let snapshot else {
            return isPaused
                ? L10n.text("已暂停 · 尚未采样", "Paused · Not sampled")
                : L10n.text("首次采样中", "Sampling")
        }
        let time = PanelTimestampFormat.display(snapshot.generatedAt)
        if isPaused { return L10n.text("已暂停 · ", "Paused · ") + time }
        if referenceDate.timeIntervalSince(snapshot.generatedAt) >= 60 {
            return L10n.text("已过期 · ", "Stale · ") + time
        }
        let requiredAvailability = [
            snapshot.measurements.physicalBytes.availability,
            snapshot.measurements.availableBytes.availability,
        ]
        if let unavailable = requiredAvailability.first(where: { $0 != .available }) {
            return unavailable.title
        }
        guard snapshot.measuredUsedRatio != nil else {
            return MeasurementAvailability.invalidSample.title
        }
        return time
    }
}

/// Compact status chip shared by mini-window monitoring cards and attached
/// control palettes so helper / mode labels use one silhouette.
struct MiniWindowStatusCapsule: View {
    let title: String
    let tint: Color
    var isBusy = false

    var body: some View {
        HStack(spacing: 4) {
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(title)
                .font(AdvancedPanelTypography.captionStrong)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.14))
        )
    }
}


extension MenuBarAdvancedStatusView {
    var overviewContextMenu: some View {
        let actions = PanelToolbarActions(
            store: store,
            state: panelSettingsState,
            isRefreshing: isRefreshingLocalData,
            hostsEditorPopover: false,
            showMainWindow: { openApp(filter: .overview) },
            togglePause: { store.toggleMenuBarRefreshPaused() },
            refresh: refreshPanelData
        )
        return actions.contextMenuContents
    }

    var header: some View {
        PanelHeader(
            store: store,
            state: panelSettingsState,
            title: selectedSection.title,
            updatedAt: selectedSectionUpdatedAt,
            unavailableText: updatedUnavailableText,
            systemImage: selectedSection.systemImage,
            isConnected: monitorSnapshot != nil,
            isRefreshing: isRefreshingLocalData,
            simpleSectionSelection: nil,
            showMainWindow: { openApp(filter: .overview) },
            togglePause: { store.toggleMenuBarRefreshPaused() },
            refresh: refreshPanelData
        )
    }

    var moduleRail: some View {
        VStack(spacing: 2) {
            ForEach(PanelSection.allCases) { section in
                AppSelectionButton(
                    title: section.title,
                    systemImage: section.systemImage,
                    isSelected: selectedRailSection == section,
                    showsTitle: false
                ) {
                    selectedSection = section
                    if reduceMotion {
                        selectedRailSection = section
                    } else if railSelectionDistance(to: section) > 1 {
                        withAnimation(AppMotionTokens.stateChange) {
                            selectedRailSection = section
                        }
                    } else {
                        withAnimation(AppMotionTokens.navigation) {
                            selectedRailSection = section
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(width: PanelLayoutMetrics.navigationWidth)
    }

    func railSelectionDistance(to section: PanelSection) -> Int {
        guard let currentIndex = PanelSection.allCases.firstIndex(of: selectedRailSection),
              let nextIndex = PanelSection.allCases.firstIndex(of: section) else {
            return .max
        }
        return abs(currentIndex - nextIndex)
    }


    func refreshPanelData() {
        store.refreshMenuBarNow()
        auxiliaryState.requestManualRefresh()
        if presentation.usesGeekLayout, selectedSection == .power {
            Task {
                await computerHealthStore.refresh(force: true)
            }
        }
    }

    var metricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 90), spacing: 6)]
    }

    var monitorSnapshot: SystemMonitorSnapshot? {
        monitorState.snapshot
    }

    var memorySnapshot: MemorySnapshot? {
        store.menuBarDisplayMemorySnapshot
    }

    var processMemorySnapshot: MemorySnapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return store.menuBarDisplayMemorySnapshot
        }
#endif
        return store.memorySnapshot
    }

    var hasCachedDiskHealth: Bool {
        guard let healthSummary else { return false }
        return healthSummary.diskSMARTStatus != nil
            || healthSummary.diskStatusText != nil
            || healthSummary.capacitySevenDayDeltaBytes != nil
            || healthSummary.backupStatusText != nil
    }

    var hasCachedNetworkSpeedTest: Bool {
        guard let healthSummary else { return false }
        return healthSummary.lastDownloadMbps != nil
            || healthSummary.lastUploadMbps != nil
            || healthSummary.lastSpeedTestAt != nil
    }

    var hasCachedBatteryHealth: Bool {
        guard let healthSummary else { return false }
        return healthSummary.batteryCapacityPercent != nil
            || healthSummary.batteryCycleCount != nil
            || healthSummary.batteryCondition != nil
            || healthSummary.batteryPowerMode != nil
    }

    func capacitySevenDayDeltaText(_ value: Int64) -> String {
        guard value != 0 else {
            return L10n.text("无明显变化", "No material change")
        }
        let amount = ByteFormat.storageString(abs(value))
        return value > 0
            ? L10n.text("可用增加 \(amount)", "Available increased by \(amount)")
            : L10n.text("可用减少 \(amount)", "Available decreased by \(amount)")
    }

    func diskSMARTStatusText(_ status: DiskSMARTStatus) -> String {
        switch status {
        case .verified:
            L10n.text("已验证", "Verified")
        case .failing:
            L10n.text("报告故障", "Failing")
        case .unsupported:
            L10n.text("硬件不支持", "Unsupported")
        case .unavailable:
            L10n.text("未知", "Unknown")
        }
    }

    func diskSMARTStatusTint(_ status: DiskSMARTStatus) -> Color {
        switch status {
        case .verified:
            AppDesignTokens.Palette.success
        case .failing:
            AppDesignTokens.Palette.destructive
        case .unsupported, .unavailable:
            .secondary
        }
    }

    func capacityDeltaTint(_ value: Int64) -> Color {
        if value > 0 { return AppDesignTokens.Palette.success
        }
        if value < 0 { return AppDesignTokens.Palette.warning
        }
        return AppDesignTokens.Palette.information
    }

    func speedMbpsText(_ value: Double) -> String {
        String(format: "%.1f Mbps", value)
    }

    func batteryCapacityTint(_ capacity: Int) -> Color {
        if capacity < 80 { return AppDesignTokens.Palette.warning
        }
        return AppDesignTokens.Palette.success
    }

    func batteryConditionText(_ condition: BatteryCondition) -> String {
        switch condition {
        case .normal:
            L10n.text("正常", "Normal")
        case .serviceRecommended:
            L10n.text("建议检修", "Service Recommended")
        case .unknown:
            L10n.text("未知", "Unknown")
        }
    }

    func batteryConditionTint(_ condition: BatteryCondition) -> Color {
        switch condition {
        case .normal:
            AppDesignTokens.Palette.success
        case .serviceRecommended:
            AppDesignTokens.Palette.warning
        case .unknown:
            .secondary
        }
    }

    func batteryPowerModeText(_ mode: BatteryPowerMode) -> String {
        switch mode {
        case .lowPower:
            L10n.text("低功耗", "Low Power")
        case .automatic:
            L10n.text("自动", "Automatic")
        case .highPower:
            L10n.text("高功率", "High Power")
        }
    }

    var cpuBreakdown: CPUUsageBreakdown? {
        monitorSnapshot?.cpuUsageBreakdown
    }

    var loadAverage: SystemLoadAverage? {
        monitorSnapshot?.loadAverage
    }

    var updatedUnavailableText: String {
        switch selectedSection {
        case .disk:
            return L10n.text("正在读取磁盘数据", "Reading disk data")
        case .power:
            return L10n.text("等待电源或按需耗电测量", "Waiting for power or on-demand energy data")
        case .cleanup:
            return L10n.text("等待扫描", "Waiting for a scan")
        case .overview, .processor, .memory, .network, .sensors:
            return L10n.text("正在采样…", "Sampling…")
        }
    }

    var selectedSectionUpdatedAt: Date? {
        switch selectedSection {
        case .disk:
            storageRefreshedAt
        case .power:
            [batterySnapshot == nil ? nil : batteryRefreshedAt, store.energyImpactSnapshot?.generatedAt]
                .compactMap { $0 }
                .max()
        case .cleanup:
            store.scanHistorySummary.latest?.date
        case .overview, .processor, .memory, .network, .sensors:
            monitorSnapshot?.generatedAt
        }
    }

    func timestampText(_ date: Date) -> String {
        PanelTimestampFormat.detail(date)
    }

    func metric(_ kind: MenuBarMetricKind) -> SystemMonitorMetric? {
        monitorSnapshot?.metric(for: kind)
    }

    func metricAvailable(_ kind: MenuBarMetricKind) -> Bool {
        metric(kind)?.isAvailable == true
    }

    func metricValue(_ kind: MenuBarMetricKind) -> String {
        guard let metric = metric(kind), metric.isAvailable else { return "--" }
        return metric.value
    }

    func metricDetail(_ kind: MenuBarMetricKind) -> String {
        guard let metric = metric(kind), metric.isAvailable else { return "--" }
        return metric.detail
    }

    func metricPercent(_ kind: MenuBarMetricKind) -> Double? {
        guard let value = numericValue(metricValue(kind)) else { return nil }
        return min(1, max(0, value / 100))
    }

    func numericValue(_ value: String) -> Double? {
        Double(value.filter { $0.isNumber || $0 == "." })
    }

    func percentProgress(_ value: Double?) -> Double? {
        value.map { min(1, max(0, $0 / 100)) }
    }

    func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f%%", value)
    }

    func decimalText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", value)
    }

    var processorTopologyText: String {
        guard let processorTelemetry else { return "" }
        return processorTelemetry.performanceLevels
            .filter { $0.coreCount > 0 }
            .map { level in
                let title = processorLevelTitle(level.name)
                return L10n.text(
                    "\(level.coreCount) \(title)",
                    "\(level.coreCount) \(title) cores"
                )
            }
            .joined(separator: " + ")
    }

    func processorLevelTitle(_ rawName: String) -> String {
        let normalized = rawName.lowercased()
        if normalized.contains("super") {
            return L10n.text("超级核心", "Super")
        }
        if normalized.contains("performance") || normalized == "p" {
            return L10n.text("性能核心", "Performance")
        }
        if normalized.contains("efficiency") || normalized == "e" {
            return L10n.text("能效核心", "Efficiency")
        }
        return rawName
    }

    func processorClusterTitle(_ cluster: CPUPerformanceStateService.ClusterReading) -> String {
        let baseTitle = processorLevelTitle(cluster.performanceLevelName)
        let siblingClusters = processorTelemetry?.clusters.filter {
            $0.performanceLevelIndex == cluster.performanceLevelIndex
        } ?? []
        guard siblingClusters.count > 1,
              let index = siblingClusters.firstIndex(where: { $0.identifier == cluster.identifier }) else {
            return L10n.text("\(baseTitle)簇", "\(baseTitle) Cluster")
        }
        return L10n.text("\(baseTitle)簇 \(index + 1)", "\(baseTitle) Cluster \(index + 1)")
    }

    func processorFrequencyText(_ megahertz: Double) -> String {
        String(format: "%.2f GHz", megahertz / 1_000)
    }

    func processorVoltageText(_ volts: Double) -> String {
        String(format: "%.2f V", volts)
    }

    func processorClusterTint(_ cluster: CPUPerformanceStateService.ClusterReading) -> Color {
        let normalized = cluster.performanceLevelName.lowercased()
        if normalized.contains("efficiency") || normalized == "e" {
            return AppDesignTokens.Palette.success
        }
        if normalized.contains("super") {
            return AppDesignTokens.Palette.tertiary
        }
        return AppDesignTokens.Palette.information
    }

    var processorChartSeries: [MenuBarTelemetrySeries] {
        var series = [
            MenuBarTelemetrySeries(id: "user", title: L10n.text("用户", "User"), channel: .cpuUser, color: resolvedPrimaryTint),
            MenuBarTelemetrySeries(id: "system", title: L10n.text("系统", "System"), channel: .cpuSystem, color: resolvedSecondaryTint)
        ]
        if metricAvailable(.gpuUsage) {
            series.append(
                MenuBarTelemetrySeries(id: "gpu", title: "GPU", channel: .gpu, color: resolvedGPUTint)
            )
        }
        return series
    }

    var fanTrendMaximum: Double {
        MenuBarChartGeometry.niceCeiling(
            for: history.flatMap { [$0.fanRPM, $0.fanTargetRPM].compactMap { $0 } },
            minimum: 1_000
        )
    }

    var hasOverviewCompactGauges: Bool {
        storageSnapshot != nil
            || metricAvailable(.chipTemperature)
            || batterySnapshot?.chargePercent != nil
    }

    var processorTint: Color {
        guard let value = cpuBreakdown?.totalPercent ?? numericValue(metricValue(.cpuUsage)) else { return AppDesignTokens.Palette.information
        }
        if value >= 90 { return AppDesignTokens.Palette.destructive
        }
        if value >= 75 { return AppDesignTokens.Palette.warning
        }
        return AppDesignTokens.Palette.information
    }

    var memoryTint: Color {
        return switch memorySnapshot?.reportablePressureLevel {
        case .critical:
            AppDesignTokens.Palette.destructive
        case .elevated:
            AppDesignTokens.Palette.warning
        case .normal:
            AppDesignTokens.Palette.information
        case .none:
            .secondary
        }
    }

    var memoryPressureTitle: String {
        guard memorySnapshot != nil else {
            return L10n.text("读取中", "Reading")
        }
        return switch memorySnapshot?.reportablePressureLevel {
        case .critical:
            L10n.text("压力高", "High Pressure")
        case .elevated:
            L10n.text("压力升高", "Elevated")
        case .normal:
            L10n.text("压力正常", "Normal")
        case .none:
            L10n.text("不可用", "Unavailable")
        }
    }

    var memoryPressureDisplayText: String {
        guard memorySnapshot != nil else {
            return L10n.text("读取中", "Reading")
        }
        return switch memorySnapshot?.reportablePressureLevel {
        case .critical:
            L10n.text("高", "High")
        case .elevated:
            L10n.text("升高", "Elevated")
        case .normal:
            L10n.text("正常", "Normal")
        case .none:
            memoryPressureUnavailableText
        }
    }

    private var memoryPressureUnavailableText: String {
        switch memorySnapshot?.measurements.pressure.availability {
        case .permissionDenied: L10n.text("权限不足", "No access")
        case .unsupported: L10n.text("不支持", "Unsupported")
        case .temporarilyInvalid: L10n.text("未就绪", "Not ready")
        case .invalidSample: L10n.text("读取失败", "Read failed")
        default: L10n.text("不可用", "Unavailable")
        }
    }

    var memoryPressureStateProgress: Double? {
        switch memorySnapshot?.reportablePressureLevel {
        case .critical:
            1
        case .elevated:
            2 / 3
        case .normal:
            1 / 3
        case .none:
            nil
        }
    }

    var memoryPressureHeadroomText: String {
        guard let memorySnapshot else {
            return L10n.text("系统压力余量读取中", "Reading system pressure headroom")
        }
        return memorySnapshot.pressureHeadroomPercent.map { headroom in
            L10n.text("系统压力余量 \(headroom)%", "System pressure headroom \(headroom)%")
        } ?? L10n.text("系统压力余量不可用", "System pressure headroom unavailable")
    }

    var memoryRingSegments: [GeekCombinedRingSegment] {
        guard let composition = memorySnapshot?.ringComposition else { return [] }
        return [
            GeekCombinedRingSegment(
                id: "app-or-other",
                progress: composition.appOrOtherRatio,
                color: AppChartPalette.memoryAppOrOther
            ),
            GeekCombinedRingSegment(
                id: "wired",
                progress: composition.wiredRatio,
                color: AppChartPalette.memoryWired
            ),
            GeekCombinedRingSegment(
                id: "compressed",
                progress: composition.compressedRatio,
                color: AppChartPalette.memoryCompressed
            ),
        ]
    }

    var memoryRingUsedPercentText: String {
        memorySnapshot?.measuredUsedRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    var memoryRingUsedProgress: Double? {
        memorySnapshot?.measuredUsedRatio
    }

    var memoryUsedAmountText: String {
        memorySnapshot?.measuredUsedBytes.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—"
    }

    var memoryTotalAmountText: String {
        memorySnapshot?.measurements.physicalBytes.value.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—"
    }

    func memorySampleStatusText(at date: Date) -> String {
#if DEBUG || STORAGE_CLEANER_BETA
        let referenceDate = MiniWindowDemoData.chartDate(liveDate: date)
#else
        let referenceDate = date
#endif
        return MemorySampleStatusPresentation.text(
            snapshot: memorySnapshot,
            isPaused: store.isMenuBarRefreshPaused,
            referenceDate: referenceDate
        )
    }

    var memorySampleEvidenceText: String {
        MemorySampleStatusPresentation.evidence(snapshot: memorySnapshot)
    }

    var memoryUsageAmountText: String {
        guard let snapshot = memorySnapshot,
              let used = snapshot.measuredUsedBytes,
              let total = snapshot.measurements.physicalBytes.value else { return "—" }
        return "\(ByteFormat.string(Int64(clamping: used))) / \(ByteFormat.string(Int64(clamping: total)))"
    }

    var memoryRingExplanation: String {
        guard let composition = memorySnapshot?.ringComposition else {
            return L10n.text("内存组成读取中。", "Memory composition is being read.")
        }
        return L10n.text(
            "应用及其他 \(ByteFormat.string(Int64(clamping: composition.appOrOtherBytes)))，有线 \(ByteFormat.string(Int64(clamping: composition.wiredBytes)))，压缩 \(ByteFormat.string(Int64(clamping: composition.compressedBytes)))，可用 \(ByteFormat.string(Int64(clamping: composition.availableBytes)))。",
            "Apps and other \(ByteFormat.string(Int64(clamping: composition.appOrOtherBytes))), wired \(ByteFormat.string(Int64(clamping: composition.wiredBytes))), compressed \(ByteFormat.string(Int64(clamping: composition.compressedBytes))), available \(ByteFormat.string(Int64(clamping: composition.availableBytes)))."
        )
    }

    var storageTint: Color {
        switch storageSnapshot?.pressure {
        case .critical:
            AppDesignTokens.Palette.destructive
        case .attention:
            AppDesignTokens.Palette.warning
        case .normal, .none:
            AppDesignTokens.Palette.information
        }
    }

    var storagePressureTitle: String {
        switch storageSnapshot?.pressure {
        case .critical:
            L10n.text("空间紧张", "Critical")
        case .attention:
            L10n.text("建议关注", "Attention")
        case .normal:
            L10n.text("正常", "Normal")
        case .none:
            L10n.text("读取中", "Reading")
        }
    }

    var storagePercentText: String {
        guard let storageSnapshot else { return "--" }
        return "\(storageSnapshot.userUsedPercent)%"
    }

    var temperatureValue: Double? {
        guard metricAvailable(.chipTemperature) else { return nil }
        return numericValue(metricValue(.chipTemperature))
    }

    var temperatureProgress: Double? {
        temperatureValue.map { min(1, max(0, $0 / 100)) }
    }

    var temperatureTint: Color {
        guard let temperatureValue else { return AppDesignTokens.Palette.information
        }
        if temperatureValue >= 90 { return AppDesignTokens.Palette.destructive
        }
        if temperatureValue >= 80 { return AppDesignTokens.Palette.warning
        }
        return AppDesignTokens.Palette.information
    }

    var thermalStateTitle: String {
        switch monitorSnapshot?.thermalState ?? .unknown {
        case .unknown:
            L10n.text("读取中", "Reading")
        case .nominal:
            L10n.text("正常", "Nominal")
        case .fair:
            L10n.text("温热", "Fair")
        case .serious:
            L10n.text("较热", "Serious")
        case .critical:
            L10n.text("过热", "Critical")
        }
    }

    var thermalStateTint: Color {
        switch monitorSnapshot?.thermalState ?? .unknown {
        case .unknown:
            .secondary
        case .nominal:
            AppDesignTokens.Palette.success
        case .fair:
            AppDesignTokens.Palette.caution
        case .serious:
            AppDesignTokens.Palette.warning
        case .critical:
            AppDesignTokens.Palette.destructive
        }
    }

    var uptimeText: String {
        let seconds = monitorSnapshot?.systemUptimeSeconds ?? 0
        guard seconds > 0 else { return "--" }
        let minutes = Int(seconds) / 60
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let remainingMinutes = minutes % 60
        if days > 0 {
            return L10n.text("\(days) 天 \(hours) 小时", "\(days)d \(hours)h")
        }
        if hours > 0 {
            return L10n.text("\(hours) 小时 \(remainingMinutes) 分", "\(hours)h \(remainingMinutes)m")
        }
        return L10n.text("\(remainingMinutes) 分钟", "\(remainingMinutes)m")
    }

    var networkDownText: String {
        if let latest = geekChartHistory.last {
            return rateText(latest.downBytesPerSecond)
        }
        return rateText(monitorSnapshot?.networkThroughput?.downBytesPerSecond)
    }

    var networkUpText: String {
        if let latest = geekChartHistory.last {
            return rateText(latest.upBytesPerSecond)
        }
        return rateText(monitorSnapshot?.networkThroughput?.upBytesPerSecond)
    }

    func rateText(_ bytes: Int64?) -> String {
        guard let bytes else { return "--" }
        return "\(ByteFormat.string(bytes))/s"
    }

    var networkDownPeak: Int64? {
        history.compactMap(\.downBytesPerSecond).max()
    }

    var networkUpPeak: Int64? {
        history.compactMap(\.upBytesPerSecond).max()
    }

    func networkRelativeProgress(direction: AdvancedNetworkDirection) -> Double? {
        guard let throughput = monitorSnapshot?.networkThroughput else { return nil }
        let current = direction == .download ? throughput.downBytesPerSecond : throughput.upBytesPerSecond
        let peak = direction == .download ? networkDownPeak : networkUpPeak
        guard let peak, peak > 0 else { return 0 }
        return min(1, max(0, Double(current) / Double(peak)))
    }

    var sessionDownloadedBytes: Int64 {
        monitorState.sessionDownloadedBytes
    }

    var sessionUploadedBytes: Int64 {
        monitorState.sessionUploadedBytes
    }

    var sensorTiles: [AdvancedMetricTileModel] {
        var tiles: [AdvancedMetricTileModel] = []
        if metricAvailable(.chipTemperature) {
            tiles.append(
                AdvancedMetricTileModel(
                    id: "temperature",
                    title: L10n.text("芯片温度", "Chip Temp"),
                    value: metricValue(.chipTemperature),
                    detail: L10n.text("实时最高", "Live Peak"),
                    tint: temperatureTint,
                    progress: temperatureProgress
                )
            )
        }
        if metricAvailable(.fanSpeed) {
            tiles.append(
                AdvancedMetricTileModel(
                    id: "fan",
                    title: L10n.text("风扇转速", "Fan Speed"),
                    value: metricValue(.fanSpeed),
                    detail: metricDetail(.fanSpeed),
                    tint: AppDesignTokens.Palette.tertiary,
                    progress: nil
                )
            )
        }
        if metricAvailable(.gpuUsage) {
            tiles.append(
                AdvancedMetricTileModel(
                    id: "gpu",
                    title: "GPU",
                    value: metricValue(.gpuUsage),
                    detail: L10n.text("驱动统计", "Driver"),
                    tint: AppDesignTokens.Palette.diagnostic,
                    progress: metricPercent(.gpuUsage)
                )
            )
        }
        return tiles
    }

    var fanTelemetryRows: [AdvancedTelemetryRow] {
        AdvancedTelemetryRows.make(
            cpuFrequencyGHz: nil,
            nominalVoltageMillivolts: nil,
            cpuPowerWatts: nil,
            fanRPM: monitorSnapshot?.fanSpeedsRPM,
            fanReadings: monitorSnapshot?.fanReadings
        )
    }

    var batteryTint: Color {
        switch batterySnapshot?.powerSource ?? .unknown {
        case .acPower:
            return AppDesignTokens.Palette.information
        case .batteryPower:
            return AppDesignTokens.Palette.sensitive
        case .unknown:
            return .secondary
        }
    }

    func hasUsableBatteryData(_ snapshot: BatteryPowerSnapshot) -> Bool {
        snapshot.chargePercent != nil
            || snapshot.isCharging != nil
            || snapshot.powerSource != .unknown
            || snapshot.remainingTimeMinutes != nil
    }

    var hasInternalBattery: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.hasInternalBattery
        }
#endif
        return InternalBatteryPresence.resolve(
            hasExplicitNoBatteryEvidence: hasConfirmedNoInternalBattery,
            hasPowerSnapshot: batterySnapshot != nil,
            hasElectricalBatteryData: batteryElectricalSnapshot?.hasBatteryData == true,
            hasHealthSnapshot: computerHealthStore.snapshot?.battery != nil
        )
    }

    var hasConfirmedNoInternalBattery: Bool {
        if case .notPresent? = computerHealthStore.snapshot?.batteryEvidence {
            return true
        }
        return false
    }

    var batterySystemImage: String {
        guard let batterySnapshot else { return "battery.0" }
        switch batterySnapshot.presentationState {
        case .charging:
            return "battery.100percent.bolt"
        case .charged, .connectedNotCharging, .optimizedChargingPaused:
            return "powerplug.fill"
        case .calculating, .unknown, .unavailable, .discharging:
            break
        }
        let charge = batterySnapshot.chargePercent ?? 0
        if charge >= 75 { return "battery.100percent" }
        if charge >= 40 { return "battery.50percent" }
        if charge >= 15 { return "battery.25percent" }
        return "battery.0percent"
    }

    var batteryPowerSourceTitle: String {
        switch batterySnapshot?.powerSource ?? .unknown {
        case .acPower:
            L10n.text("电源适配器", "Power Adapter")
        case .batteryPower:
            L10n.text("电池", "Battery")
        case .unknown:
            L10n.text("未知", "Unknown")
        }
    }

    var batteryStatusTitle: String {
        batteryPresentationStateTitle
    }

    var batteryPresentationState: BatteryPresentationState {
        batterySnapshot?.presentationState ?? .unavailable
    }

    var batteryPresentationStateTitle: String {
        switch batteryPresentationState {
        case let .charging(minutes):
            guard let minutes, minutes > 0 else {
                return L10n.text("正在计算", "Calculating")
            }
            return L10n.text(
                "预计 \(batteryDurationText(minutes))后充满",
                "Estimated full in \(batteryDurationText(minutes))"
            )
        case .charged:
            return L10n.text("已充满", "Fully Charged")
        case .connectedNotCharging:
            return L10n.text("已接通电源", "Connected to Power")
        case .optimizedChargingPaused:
            return L10n.text("已暂停充电", "Charging Paused")
        case let .discharging(minutes):
            guard let minutes, minutes > 0 else {
                return L10n.text("正在计算", "Calculating")
            }
            return L10n.text(
                "剩余 \(batteryDurationText(minutes))",
                "\(batteryDurationText(minutes)) remaining"
            )
        case .calculating:
            return L10n.text("正在计算", "Calculating")
        case .unknown:
            return L10n.text("状态未知", "Status Unknown")
        case .unavailable:
            return L10n.text("不可用", "Unavailable")
        }
    }

    var batteryPresentationStateCompactTitle: String {
        switch batteryPresentationState {
        case let .charging(minutes):
            guard let minutes, minutes > 0 else {
                return L10n.text("正在计算", "Calculating")
            }
            return L10n.text(
                "约 \(batteryCompactDurationText(minutes))后充满",
                "Est. full in \(batteryCompactDurationText(minutes))"
            )
        case .charged:
            return L10n.text("已充满", "Fully Charged")
        case .connectedNotCharging:
            return L10n.text("已接通电源", "Connected to Power")
        case .optimizedChargingPaused:
            return L10n.text("已暂停充电", "Charging Paused")
        case let .discharging(minutes):
            guard let minutes, minutes > 0 else {
                return L10n.text("正在计算", "Calculating")
            }
            return L10n.text(
                "剩余约 \(batteryCompactDurationText(minutes))",
                "About \(batteryCompactDurationText(minutes)) remaining"
            )
        case .calculating:
            return L10n.text("正在计算", "Calculating")
        case .unknown, .unavailable:
            return L10n.text("状态未知", "Status Unknown")
        }
    }

    private func batteryDurationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            if remainder > 0 {
                return L10n.text(
                    "\(hours) 小时 \(remainder) 分钟",
                    "\(hours)h \(remainder)m"
                )
            }
            return L10n.text("\(hours) 小时", "\(hours)h")
        }
        return L10n.text("\(remainder) 分钟", "\(remainder)m")
    }

    private func batteryCompactDurationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0, remainder > 0 {
            return L10n.text("\(hours) 小时 \(remainder) 分", "\(hours)h \(remainder)m")
        }
        if hours > 0 {
            return L10n.text("\(hours) 小时", "\(hours)h")
        }
        return L10n.text("\(remainder) 分", "\(remainder)m")
    }

    func durationMinutesText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            return L10n.text("\(hours) 小时 \(remainder) 分", "\(hours)h \(remainder)m")
        }
        return L10n.text("\(remainder) 分钟", "\(remainder)m")
    }

    var safeCleanupBytesText: String {
        guard let status = store.scanHistorySummary.latestStatus() else { return "--" }
        return ByteFormat.string(status.entry.greenBytes)
    }

    var safeCleanupCountText: String {
        guard let status = store.scanHistorySummary.latestStatus() else {
            return L10n.text("等待扫描", "Waiting for Scan")
        }
        return L10n.text("\(status.entry.greenCount) 项", "\(status.entry.greenCount) items")
    }

    var cleanupSummaryTitle: String {
        actionableCleanupItems.isEmpty
            ? L10n.text("上次扫描摘要", "Last Scan Summary")
            : L10n.text("可安全清理", "Safe Cleanup")
    }

    var staleCleanupSummaryNotice: String {
        if store.scanHistorySummary.latestStatus()?.entry.greenCount ?? 0 > 0 {
            return L10n.text(
                "上方是上次扫描摘要；当前没有已加载的可操作明细，请重新扫描后再确认清理。",
                "The summary above is from the last scan; no actionable details are loaded now. Rescan before confirming cleanup."
            )
        }
        return L10n.text(
            "当前没有已加载的可操作清理项。",
            "No actionable cleanup items are currently loaded."
        )
    }

    var actionableCleanupItems: [StorageItem] {
        Array(store.items(for: .green).filter(\.canMoveToTrash).prefix(4))
    }

    var actionableMemoryApps: [MemoryAppUsage] {
        Array(
            (processMemorySnapshot?.appsByResidentUsage ?? [])
                .filter { $0.canQuit && $0.bundlePath?.hasSuffix(".app") == true }
                .prefix(4)
        )
    }

}

enum InternalBatteryPresence {
    static func resolve(
        hasExplicitNoBatteryEvidence: Bool = false,
        hasPowerSnapshot: Bool,
        hasElectricalBatteryData: Bool,
        hasHealthSnapshot: Bool
    ) -> Bool {
        guard !hasExplicitNoBatteryEvidence else { return false }
        return hasPowerSnapshot || hasElectricalBatteryData || hasHealthSnapshot
    }
}

enum AdvancedNetworkDirection {
    case download
    case upload
}

struct AdvancedMetricTileModel: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let progress: Double?
}

struct AdvancedPanelCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let content: Content

    init(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .font(AdvancedPanelTypography.section)
            .accessibilityAddTraits(.isHeader)

            content
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AdvancedMetricTile: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let progress: Double?

    var body: some View {
        Group {
            if isPercentageMetric {
                PanelCircularGauge(
                    title: title,
                    value: value,
                    progress: progress,
                    tint: tint,
                    detail: detail,
                    size: 52
                )
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.uppercased())
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(value)
                        .font(AdvancedPanelTypography.value)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)

                    Text(detail)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
    }

    private var isPercentageMetric: Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.hasSuffix("%") || trimmedValue.hasSuffix("％")
    }
}

struct AdvancedCompactGauge: View {
    let title: String
    let value: String
    let progress: Double?
    let tint: Color

    var body: some View {
        PanelCircularGauge(
            title: title,
            value: value,
            progress: progress,
            tint: tint,
            size: 52
        )
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}

struct AdvancedPlainMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(AdvancedPanelTypography.value)
                .monospacedDigit()
            Text(title)
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct AdvancedValueRow: View {
    let title: String
    let value: String
    let tint: Color
    @Environment(\.advancedValueRowUsesUniformTextSize) private var usesUniformTextSize

    var body: some View {
        LabeledContent {
            Text(value)
                .font(usesUniformTextSize
                    ? AdvancedPanelTypography.body.weight(.semibold)
                    : AdvancedPanelTypography.compactValue)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.84)
        } label: {
            Text(title)
                .font(usesUniformTextSize
                    ? AdvancedPanelTypography.body
                    : AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minHeight: 20)
        .accessibilityElement(children: .combine)
    }
}

private struct AdvancedValueRowUniformTextSizeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var advancedValueRowUsesUniformTextSize: Bool {
        get { self[AdvancedValueRowUniformTextSizeKey.self] }
        set { self[AdvancedValueRowUniformTextSizeKey.self] = newValue }
    }
}

struct AdvancedProcessorClusterRow: View {
    let title: String
    let detail: String
    let frequency: String?
    let voltage: String?
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AdvancedPanelTypography.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            if let frequency, let voltage {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(frequency)
                        .font(AdvancedPanelTypography.compactValue)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(L10n.text("平均有效频率", "Avg. Frequency"))
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 72, alignment: .trailing)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(voltage)
                        .font(AdvancedPanelTypography.compactValue)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(L10n.text("状态电压", "State Voltage"))
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 58, alignment: .trailing)
            } else {
                Text(L10n.text("休眠", "Sleeping"))
                    .font(AdvancedPanelTypography.compactValue)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 138, alignment: .trailing)
            }
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }
}

struct AdvancedUnavailableRow: View {
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: AppSymbols.Action.info)
                .foregroundStyle(.secondary)
            Text(title)
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct AdvancedAppUsageRow: View {
    let app: MemoryAppUsage

    var body: some View {
        HStack(spacing: 7) {
            AdvancedAppIcon(path: app.iconPath, fallback: "app.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(AdvancedPanelTypography.body.weight(.semibold))
                    .lineLimit(1)
                Text(L10n.text("\(app.processCount) 个进程", "\(app.processCount) processes"))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(app.bytes))
                .font(AdvancedPanelTypography.compactValue)
                .monospacedDigit()
            Text(String(format: "%.1f%%", app.percent))
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }
}

struct AdvancedEnergyAppRow: View {
    let app: EnergyImpactApp

    var body: some View {
        HStack(spacing: 7) {
            AdvancedAppIcon(path: app.iconPath, fallback: "bolt.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(AdvancedPanelTypography.body.weight(.semibold))
                    .lineLimit(1)
                Text(app.measurementTitle)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(app.currentPowerWattsText)
                .font(AdvancedPanelTypography.compactValue)
                .monospacedDigit()
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }
}

struct AdvancedCleanupItemRow: View {
    let item: StorageItem

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: AppSymbols.Panel.archive)
                .font(AdvancedPanelTypography.symbol)
                .foregroundStyle(AppDesignTokens.Palette.success)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(AdvancedPanelTypography.body.weight(.semibold))
                    .lineLimit(1)
                Text(item.groupTitle.isEmpty ? item.kind : item.groupTitle)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(item.sizeBytes))
                .font(AdvancedPanelTypography.compactValue)
                .monospacedDigit()
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }
}

struct AdvancedAppIcon: View {
    let path: String
    let fallback: String

    var body: some View {
        CachedAppIconView(
            path: path,
            size: 24
        ) {
            Image(systemName: fallback)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
            .frame(width: 24, height: 24)
    }
}
