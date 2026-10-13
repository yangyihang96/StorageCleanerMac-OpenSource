import AppKit
import SwiftUI

typealias AdvancedPanelTypography = MenuBarPanelTypography

enum MemorySampleStatusPresentation {
    static let refreshInterval: TimeInterval = 15

    /// Help and VoiceOver text of the memory card and page (D28): the level
    /// is the system's, as in Activity Monitor; only the percentage is an
    /// estimate. When this sample lacks the level or the headroom, it says so.
    /// The headroom has one name everywhere: 系统压力余量 (review P2-4).
    static func evidence(snapshot: MemorySnapshot?) -> String {
        guard let snapshot else { return L10n.text("尚无内存样本", "No memory sample yet") }
        let time = snapshot.generatedAt.formatted(.dateTime.year().month().day().hour().minute().second())
        let explanation = L10n.text(
            "快照生成于 \(time)。压力等级（正常／升高／高）取自 macOS 系统，与活动监视器一致；压力百分比为 100% 减去系统压力余量，是估算，仅用于趋势。",
            "Snapshot generated at \(time). The pressure level (Normal / Elevated / High) comes from macOS, the same source as Activity Monitor; the pressure percentage is an estimate, 100% minus system pressure headroom, for trends only."
        )
        let hasSystemLevel = snapshot.measurements.pressure.value != nil
        let hasPercent = snapshot.pressureEstimatePercent != nil
        let gap: String? = switch (hasSystemLevel, hasPercent) {
        case (true, true):
            nil
        case (false, true):
            L10n.text(
                "本次未读到系统的压力等级，等级按百分比估算（85% 起为升高、95% 起为高）。",
                "macOS did not report a level for this sample, so it is estimated from the percentage (Elevated from 85%, High from 95%)."
            )
        case (true, false):
            L10n.text(
                "本次未读到系统压力余量，没有压力百分比。",
                "macOS did not report pressure headroom for this sample, so there is no percentage."
            )
        case (false, false):
            L10n.text(
                "本次未读到系统的压力等级和压力余量，等级不可用。",
                "macOS reported neither a level nor pressure headroom for this sample, so the level is unavailable."
            )
        }
        guard let gap else { return explanation }
        return explanation + L10n.text("", " ") + gap
    }

    static func text(snapshot: MemorySnapshot?, isPaused: Bool, referenceDate: Date) -> String {
        guard let snapshot else {
            return isPaused
                ? L10n.text("已暂停 · 尚未采样", "Paused · Not sampled")
                : L10n.text("首次采样中", "Sampling")
        }
        let time = PanelTimestampFormat.age(snapshot.generatedAt, now: referenceDate)
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

    /// The memory page header shows a bare sample time as "采样 16:13" so it
    /// is not read as the current clock. Stale, paused and unavailable
    /// states already name themselves and are returned unchanged.
    static func headerText(snapshot: MemorySnapshot?, isPaused: Bool, referenceDate: Date) -> String {
        let status = text(snapshot: snapshot, isPaused: isPaused, referenceDate: referenceDate)
        guard let snapshot, status == PanelTimestampFormat.age(snapshot.generatedAt, now: referenceDate) else { return status }
        return L10n.text("采样 ", "Sampled ") + status
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
        .padding(.horizontal, MiniWindowStyleTokens.inlineSpacing)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.14))
        )
    }
}


/// One concise runtime cue for the whole secondary page. It is included in
/// natural-height measurement so even a short display never hides the last row.
struct MiniWindowPausedSamplingRow: View {
    var body: some View {
        Text(L10n.text("自动刷新已暂停", "Automatic Refresh Paused"))
            .font(AdvancedPanelTypography.captionStrong)
            .foregroundStyle(AppDesignTokens.Palette.warning)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, GeekVisualTokens.cardHorizontalPadding)
            .background(AppDesignTokens.Palette.warning.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: GeekVisualTokens.cardRadius))
            .accessibilityElement(children: .combine)
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

    func refreshPanelData() {
        store.refreshMenuBarNow()
        auxiliaryState.requestManualRefresh()
        if presentation.usesGeekLayout, selectedSection == .power {
            Task {
                await computerHealthStore.refresh(force: true)
            }
        }
    }

    var monitorSnapshot: SystemMonitorSnapshot? {
        let live = MenuBarSamplingContext.shared.presentationSnapshot(live: monitorState.snapshot)
#if DEBUG || STORAGE_CLEANER_BETA
        return MiniWindowDemoData.presentationSnapshot(live: live)
#else
        return live
#endif
    }

    var memorySnapshot: MemorySnapshot? {
        store.menuBarDisplayMemorySnapshot
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

    func metricPercent(_ kind: MenuBarMetricKind) -> Double? {
        guard let value = numericValue(metricValue(kind)) else { return nil }
        return min(1, max(0, value / 100))
    }

    func numericValue(_ value: String) -> Double? {
        Double(value.filter { $0.isNumber || $0 == "." })
    }

    func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f%%", value)
    }

    func decimalText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", value)
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

    func processorFrequencyText(_ megahertz: Double) -> String {
        String(format: "%.2f GHz", megahertz / 1_000)
    }

    /// The fan charts' scale from the window's largest fan reading, prepared
    /// with the window (P2-1).
    var fanTrendMaximum: Double {
        historySummary.fanTrendMaximum
    }

    var hasOverviewCompactGauges: Bool {
        storageSnapshot != nil
            || metricAvailable(.chipTemperature)
            || batterySnapshot?.chargePercent != nil
    }

    /// The CPU load color exit (PanelMetricColors.cpuLoad): used for the
    /// total CPU readouts, never for headings.
    var processorTint: Color {
        panelMetricColors.cpuLoad(cpuBreakdown?.totalPercent ?? numericValue(metricValue(.cpuUsage)))
    }

    var memoryTint: Color {
        panelMetricColors.memoryPressure(for: memorySnapshot?.reportablePressureLevel)
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

    var memoryRingSegments: [GeekCombinedRingSegment] {
        guard let composition = memorySnapshot?.ringComposition else { return [] }
        return [
            GeekCombinedRingSegment(
                id: "app-or-other",
                progress: composition.appOrOtherRatio,
                color: panelMetricColors.memoryApp
            ),
            GeekCombinedRingSegment(
                id: "wired",
                progress: composition.wiredRatio,
                color: panelMetricColors.memoryWired
            ),
            GeekCombinedRingSegment(
                id: "compressed",
                progress: composition.compressedRatio,
                color: panelMetricColors.memoryCompressed
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
        return MemorySampleStatusPresentation.headerText(
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
            "应用及其他 \(ByteFormat.string(Int64(clamping: composition.appOrOtherBytes)))，联动 \(ByteFormat.string(Int64(clamping: composition.wiredBytes)))，压缩 \(ByteFormat.string(Int64(clamping: composition.compressedBytes)))，可用 \(ByteFormat.string(Int64(clamping: composition.availableBytes)))。",
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
            panelMetricColors.diskWrite
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

    var temperatureValue: Double? {
        guard metricAvailable(.chipTemperature) else { return nil }
        return numericValue(metricValue(.chipTemperature))
    }

    var temperatureProgress: Double? {
        temperatureValue.map { min(1, max(0, $0 / 100)) }
    }

    /// Chip temperature color: the one temperature rule, whose normal color
    /// follows the chart theme like the other sensor rings and histories.
    var temperatureTint: Color {
        panelMetricColors.temperature(temperatureValue, chartAccent: panelChartAccentColor)
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
        rateText(networkCurrentRates.down)
    }

    var networkUpText: String {
        rateText(networkCurrentRates.up)
    }

    /// BOARD N16-3: the network history's current reading (D39), keeping the
    /// last rates through a sample without them (`MenuBarNetworkReadout`).
    /// The open page's window was read before, so opening another page
    /// could show "--" until the next sample.
    var networkCurrentRates: (down: Int64?, up: Int64?) {
        MenuBarNetworkReadout.rates(
            current: currentReading(of: networkDisplayedHistory),
            lastReading: monitorState.lastNetworkReading,
            now: historyReferenceDate,
            retainsStoredReading: MenuBarSamplingContext.shared.plan != nil
        )
    }

    func rateText(_ bytes: Int64?) -> String {
        guard let bytes else { return "--" }
        return "\(ByteFormat.string(bytes))/s"
    }

    var sessionDownloadedBytes: Int64 {
        monitorState.sessionDownloadedBytes
    }

    var sessionUploadedBytes: Int64 {
        monitorState.sessionUploadedBytes
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
            return batterySnapshot?.isCharging == true
                ? panelMetricColors.batteryCharging : panelMetricColors.battery
        case .batteryPower:
            return panelMetricColors.batteryDraining
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
        return resolvedMiniWindowBatteryAvailability == .present
    }

    var hasConfirmedNoInternalBattery: Bool {
        resolvedMiniWindowBatteryAvailability == .absent
    }

    private var resolvedMiniWindowBatteryAvailability: InternalBatteryAvailability {
        let healthSaysAbsent: Bool
        if case .notPresent? = computerHealthStore.snapshot?.batteryEvidence {
            healthSaysAbsent = true
        } else { healthSaysAbsent = false }
        return MiniWindowBatteryPolicy.resolve(
            live: reportedInternalBatteryAvailability, healthSaysAbsent: healthSaysAbsent,
            hasPowerSnapshot: batterySnapshot != nil,
            hasElectricalBatteryData: batteryElectricalSnapshot?.hasBatteryData == true,
            hasHealthSnapshot: computerHealthStore.snapshot?.battery != nil
        )
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
        BatteryPresentationText.title(batteryPresentationState)
    }

    var batteryPresentationStateCompactTitle: String {
        BatteryPresentationText.compactTitle(batteryPresentationState)
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
        guard let entry = store.latestSafeCleanupEntry else {
            return L10n.text("尚未扫描", "Not Scanned Yet")
        }
        return ByteFormat.string(entry.greenBytes)
    }

    var safeCleanupCountText: String {
        guard let entry = store.latestSafeCleanupEntry else {
            return L10n.text("等待扫描", "Waiting for Scan")
        }
        return L10n.text("\(entry.greenCount) 项", "\(entry.greenCount) items")
    }

    var cleanupSummaryTitle: String {
        if store.latestSafeCleanupEntry == nil && actionableCleanupItems.isEmpty {
            return L10n.text("尚未扫描", "Not Scanned Yet")
        }
        return actionableCleanupItems.isEmpty
            ? L10n.text("上次扫描摘要", "Last Scan Summary")
            : L10n.text("可安全清理", "Safe Cleanup")
    }

    var staleCleanupSummaryNotice: String {
        if store.latestSafeCleanupEntry?.greenCount ?? 0 > 0 {
            return L10n.text(
                "需重新扫描后才能清理",
                "Rescan before cleanup"
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

    // Legacy adapters also serve the dormant simple-panel pages.
    var cleanupPageBytesText: String { safeCleanupBytesText }
    var cleanupPageCountText: String { safeCleanupCountText }

}

/// Status wording of the battery card, the power page and their help text.
///
/// "正在计算" appears only while macOS is calculating a time (`isEstimating`,
/// IOPowerSources' -1). A charged, connected, paused or finishing battery and
/// a state for which the system offers no time each say what they are.
enum BatteryPresentationText {
    static func title(_ state: BatteryPresentationState) -> String {
        switch state {
        case let .charging(minutes, isEstimating):
            guard let minutes, minutes > 0 else {
                return untimedChargingTitle(isEstimating: isEstimating)
            }
            return L10n.text(
                "预计 \(batteryDurationText(minutes))后充满",
                "Estimated full in \(batteryDurationText(minutes))"
            )
        case let .discharging(minutes, isEstimating):
            guard let minutes, minutes > 0 else {
                return untimedDischargingTitle(isEstimating: isEstimating)
            }
            return L10n.text(
                "剩余 \(batteryDurationText(minutes))",
                "\(batteryDurationText(minutes)) remaining"
            )
        case .unavailable:
            return L10n.text("不可用", "Unavailable")
        case .finishingCharge, .charged, .connectedNotCharging, .optimizedChargingPaused, .unknown:
            return stateTitle(state)
        }
    }

    static func compactTitle(_ state: BatteryPresentationState) -> String {
        switch state {
        case let .charging(minutes, isEstimating):
            guard let minutes, minutes > 0 else {
                return untimedChargingTitle(isEstimating: isEstimating)
            }
            return L10n.text(
                "约 \(batteryCompactDurationText(minutes))后充满",
                "Est. full in \(batteryCompactDurationText(minutes))"
            )
        case let .discharging(minutes, isEstimating):
            guard let minutes, minutes > 0 else {
                return untimedDischargingTitle(isEstimating: isEstimating)
            }
            return L10n.text(
                "剩余约 \(batteryCompactDurationText(minutes))",
                "About \(batteryCompactDurationText(minutes)) remaining"
            )
        case .finishingCharge, .charged, .connectedNotCharging, .optimizedChargingPaused,
             .unknown, .unavailable:
            return stateTitle(state)
        }
    }

    /// States without a time. Unknown and unavailable share the compact text.
    private static func stateTitle(_ state: BatteryPresentationState) -> String {
        switch state {
        case .finishingCharge:
            return L10n.text("即将充满", "Finishing Charge")
        case .charged:
            return L10n.text("已充满", "Fully Charged")
        case .connectedNotCharging:
            return L10n.text("已接通电源", "Connected to Power")
        case .optimizedChargingPaused:
            return L10n.text("已暂停充电", "Charging Paused")
        case .charging, .discharging, .unknown, .unavailable:
            return L10n.text("状态未知", "Status Unknown")
        }
    }

    private static func untimedChargingTitle(isEstimating: Bool) -> String {
        isEstimating ? calculatingTitle : L10n.text("正在充电", "Charging")
    }

    private static func untimedDischargingTitle(isEstimating: Bool) -> String {
        isEstimating ? calculatingTitle : L10n.text("使用电池", "On Battery")
    }

    private static var calculatingTitle: String {
        L10n.text("正在计算", "Calculating")
    }

    private static func batteryDurationText(_ minutes: Int) -> String {
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

    private static func batteryCompactDurationText(_ minutes: Int) -> String {
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
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.primary)
                .font(AdvancedPanelTypography.section)
                .accessibilityAddTraits(.isHeader)

            content
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct AdvancedUnavailableRow: View {
    let title: String

    var body: some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
            Text(title)
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct AdvancedCleanupItemRow: View {
    let item: StorageItem

    var body: some View {
        HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
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
