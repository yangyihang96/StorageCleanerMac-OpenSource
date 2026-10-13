import SwiftUI

enum GeekPowerLayout {
    static let gaugeHeight: CGFloat = 112
    static let adapterHeight: CGFloat = 94
    static let historyHeight: CGFloat = 79
    static let modeHeight: CGFloat = 25
    static let significantEnergyHeight: CGFloat = 79
    static let electricalHeight = GeekSensorReadoutLayout.cardHeight(rowCount: 2)
    /// D57: computer, power input, battery, display backlight, chip total.
    static let powerHeight = GeekSensorReadoutLayout.cardHeight(rowCount: 5)
    /// A desktop: computer, power input, chip total.
    static let desktopPowerHeight = GeekSensorReadoutLayout.cardHeight(rowCount: 3)
    static let displayedEnergyAppCount = 3
    static let detailPreviewDuration: TimeInterval = 60 * 60
    static let historyTertiaryOffset = GeekPanelLayout.contentPadding
        + gaugeHeight
        + GeekPanelLayout.detailSpacing
    static let energyModeTertiaryOffset = GeekPanelLayout.contentPadding
        + gaugeHeight
        + GeekPanelLayout.detailSpacing
        + historyHeight
        + GeekPanelLayout.detailSpacing
        + electricalHeight
        + GeekPanelLayout.detailSpacing
        + powerHeight
        + GeekPanelLayout.detailSpacing

    static func energyModeSourceOffset(hasInternalBattery: Bool) -> CGFloat {
        hasInternalBattery
            ? energyModeTertiaryOffset
            : GeekPanelLayout.contentPadding + adapterHeight
                + GeekPanelLayout.detailSpacing + desktopPowerHeight
                + GeekPanelLayout.detailSpacing
    }

    static func significantEnergyHeight(for appCount: Int) -> CGFloat {
        switch min(max(0, appCount), displayedEnergyAppCount) {
        case 0...1: return 39
        case 2: return 59
        default: return significantEnergyHeight
        }
    }

    static let secondaryCardHeights = [
        gaugeHeight,
        historyHeight,
        electricalHeight,
        powerHeight,
        modeHeight,
        significantEnergyHeight,
    ]

    static var secondaryContentHeight: CGFloat {
        secondaryCardHeights.reduce(0, +)
            + CGFloat(secondaryCardHeights.count - 1) * GeekPanelLayout.detailSpacing
    }
}

enum GeekPowerEnergyCardState: Equatable {
    case apps
    case loading
    case empty

    static func resolve(
        hasCachedSnapshot: Bool,
        isLoading: Bool,
        appCount: Int
    ) -> Self {
        if appCount > 0 { return .apps }
        if !hasCachedSnapshot, isLoading { return .loading }
        return .empty
    }
}

enum GeekBatteryRingState: Equatable {
    case sampling
    case charging
    case charged
    case connected
    case discharging
    case unknown
    case notCharging

    static func resolve(chargePercent: Int?, isCharging: Bool?) -> Self {
        guard chargePercent != nil else { return .sampling }
        return isCharging == true ? .charging : .notCharging
    }

    static func resolve(snapshot: BatteryPowerSnapshot?) -> Self {
        guard let snapshot else { return .sampling }
        switch snapshot.presentationState {
        case .charging, .finishingCharge:
            return .charging
        case .charged:
            return .charged
        case .connectedNotCharging, .optimizedChargingPaused:
            return .connected
        case .discharging:
            return .discharging
        case .unknown, .unavailable:
            return .unknown
        }
    }

    var statusSymbol: String? {
        switch self {
        case .charging:
            "bolt.fill"
        case .charged, .connected:
            "powerplug.fill"
        case .sampling, .discharging, .unknown, .notCharging:
            nil
        }
    }
}

extension MenuBarAdvancedStatusView {
    var geekPowerPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.battery) {
                VStack(spacing: GeekPanelLayout.detailSpacing) {
            if hasInternalBattery {
                geekPowerGaugeCard
                geekPowerHistoryCard
                // D57: rows whose SMC key does not exist are hidden.
                let electricalReadouts = geekBatteryElectricalReadouts
                if !electricalReadouts.isEmpty {
                    geekSensorReadoutCard(
                        L10n.text("电池电气", "BATTERY ELECTRICAL"),
                        rows: electricalReadouts
                    )
                }
            } else {
                geekPowerAdapterCard
            }
            // BOARD N16-6, D57: only rows with a reading; no card without any.
            let powerReadouts = geekPowerReadouts
            if !powerReadouts.isEmpty {
                geekSensorReadoutCard(L10n.text("功耗", "POWER"), rows: powerReadouts)
            }
                }
            }
            geekHelperPowerMetricsCards
            if showsExtendedGeekDetails {
                if hasAvailableEnergyMode || MacMiniHardwareCapabilities.shouldOffer(
                    hasInternalBattery: hasInternalBattery, isDataOnlyFixture: fanControl.isDataOnlyFixture
                ) {
                    liveCard(.controls) {
                        if hasAvailableEnergyMode { geekPowerModeCard }
                        else { geekMacMiniModeCard }
                    }
                }
                liveCard(.energyProcesses) { geekSignificantEnergyCard }
            }
        }
        .task {
#if DEBUG || STORAGE_CLEANER_BETA
            guard !MiniWindowDemoData.isEnabled else { return }
#endif
            guard BatteryChargeLimitAccess.allowsLiveAccess else { return }
            auxiliaryState.refreshBatteryChargeLimitState(reason: .panelOpened)
            await computerHealthStore.refreshBatteryPowerModes()
            await computerHealthStore.refresh()
        }

    }

    var batteryRuntimeEstimate: GeekBatteryRemainingTime.Estimate? {
        GeekBatteryRemainingTime.estimate(
            snapshot: batterySnapshot,
            electrical: batteryElectricalSnapshot,
            history: batteryPowerHistory,
            referenceDate: historyReferenceDate
        )
    }

    var batteryPredictedRuntimeText: String? {
        guard batterySnapshot?.isDischarging == true else { return nil }
        return GeekBatteryRemainingTime.text(
            for: batteryRuntimeEstimate?.minutes ?? batterySnapshot?.timeToEmptyMinutes
        )
    }

    private var geekPowerAdapterCard: some View {
        GeekCombinedCard(height: GeekPowerLayout.adapterHeight) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    GeekSectionTitle(title: L10n.text("电源适配器", "Power Adapter").uppercased())
                    Spacer(minLength: 4)
                    Text(geekAdapterNameText)
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(height: 18)

                GeekTelemetryRow(
                    title: L10n.text("协商功率", "Negotiated Power"),
                    value: geekAdapterPowerText,
                    tint: panelMetricColors.battery
                )
                GeekTelemetryRow(
                    title: L10n.text("协商电压", "Negotiated Voltage"),
                    value: geekAdapterVoltageText,
                    tint: panelMetricColors.battery
                )
                GeekTelemetryRow(
                    title: L10n.text("协商电流", "Negotiated Current"),
                    value: geekAdapterAmperageText,
                    tint: panelMetricColors.battery
                )
            }
        }
        .accessibilityHint(L10n.text(
            "由 macOS 电源适配器接口报告；这是协商输入规格，不是墙插功率计读数。",
            "Reported by the macOS power-adapter interface; this is the negotiated input specification, not a wall-meter reading."
        ))
    }

    private var geekPowerGaugeCard: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("电池与充电三级详情", "Battery and Charging Deep Detail"),
            popoverSize: GeekSensorPowerHoverDetailMetrics.batterySize,
            usesCardActiveBorder: true
        ) {
            GeekCombinedCard(height: GeekPowerLayout.gaugeHeight) {
                HStack(spacing: 12) {
                    GeekCombinedRing(
                        title: L10n.text("电池", "BATTERY"),
                        value: batterySnapshot?.chargePercent.map { "\($0)%" } ?? "--",
                        detail: batteryPredictedRuntimeText.map {
                            L10n.text("约 \($0)", "About \($0)")
                        },
                        statusSymbol: geekBatteryRingSymbol,
                        statusSymbolTint: panelMetricColors.batteryCharging,
                        progress: batterySnapshot?.chargePercent.map { Double($0) / 100 },
                        tint: panelMetricColors.battery,
                        size: 96
                    )

                    GeekCombinedRing(
                        title: L10n.text("电池健康", "HEALTH"),
                        value: geekBatteryHealthPercent.map { "\($0)%" } ?? "--",
                        detail: geekBatteryHealthPercent == nil
                            ? geekBatteryHealthDetail
                            : nil,
                        progress: geekBatteryHealthPercent.map { min(1, Double($0) / 100) },
                        tint: panelMetricColors.batteryHealth,
                        size: 96
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } detail: {
            GeekBatteryElectricalHoverDetail(
                electrical: batteryElectricalSnapshot,
                cycleCount: healthSummary?.batteryCycleCount
                    ?? batteryElectricalSnapshot?.cycleCount,
                condition: healthSummary?.batteryCondition.map(batteryConditionText)
                    ?? batteryElectricalSnapshot?.condition.map(batteryConditionText),
                chargePercent: batterySnapshot?.chargePercent,
                healthPercent: geekBatteryHealthPercent,
                statusText: batteryStatusTitle,
                isCharging: batterySnapshot?.isCharging,
                chargeTargetPercent: batteryChargeLimitState?.effectiveLimit,
                remainingTimeMinutes: batterySnapshot?.remainingTimeMinutes,
                runtimeEstimate: batteryRuntimeEstimate
            )
        }
    }

    private var geekPowerHistoryCard: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("电池电量历史三级详情", "Battery History Deep Detail"),
            chartRangeMetric: .battery,
            popoverSize: GeekSensorPowerHoverDetailMetrics.popoverSize(
                sampleCount: powerHistory.compactMap(\.chargePercent).filter(\.isFinite).count,
                expandedSize: GeekSensorPowerHoverDetailMetrics.batteryHistorySize
            ),
            sourceOffset: GeekPowerLayout.historyTertiaryOffset,
            usesCardActiveBorder: true
        ) {
            GeekCombinedCard(height: GeekPowerLayout.historyHeight) {
                GeekPowerHistoryChart(
                    points: batteryPowerHistory,
                    metric: .charge,
                    duration: GeekPowerLayout.detailPreviewDuration,
                    tint: panelMetricColors.batteryCharging,
                    chargingTint: panelMetricColors.batteryDraining,
                    accessibilityLabel: L10n.text(
                        "最近一小时的电池电量历史",
                        "Battery-level history over the last hour"
                    )
                )
                .frame(height: 67)
            }
        } detail: {
            GeekBatteryHistoryHoverDetail(
                points: batteryPowerHistory,
                tint: panelMetricColors.batteryCharging,
                chargingTint: panelMetricColors.batteryDraining
            )
        }
    }

    private var geekPowerModeCard: some View {
        ControlPaletteHoverAnchor(
            kind: .power,
            accessibilityLabel: L10n.text("打开电源模式控制", "Open Power Mode Controls")
        ) {
            GeekCombinedCard(height: GeekPowerLayout.modeHeight) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    GeekSectionTitle(title: L10n.text("能源模式", "Energy Mode").uppercased())

                    Spacer(minLength: 8)

                    Text(geekPowerModeTitle
                        ?? geekHealthSamplingText)
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .help(geekPowerModeHelpText)
            }
        }
    }

    func changeEnergyMode(
        source: BatteryPowerSource,
        mode: BatteryPowerMode
    ) {
        Task { @MainActor in
            await computerHealthStore.changeBatteryPowerMode(
                source: source,
                mode: mode
            )
        }
    }

    // Offer the fallback only on battery-equipped Macs with clamshell capability.
    private var geekMacMiniModeCard: some View {
        ControlPaletteHoverAnchor(
            kind: .power,
            accessibilityLabel: L10n.text("打开电源管理", "Open Power Management")
        ) {
            GeekCombinedCard(height: GeekPowerLayout.modeHeight) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    GeekSectionTitle(title: L10n.text("Mac mini 模式", "Mac mini Mode"))
                    Spacer(minLength: 8)
                    Text(L10n.text("管理", "Manage")).font(AdvancedPanelTypography.captionStrong)
                }
            }
        }
    }

    private var geekSignificantEnergyCard: some View {
        let apps = geekDisplayedEnergyApps
        let state = GeekPowerEnergyCardState.resolve(
            hasCachedSnapshot: geekHasEnergyImpactSnapshot,
            isLoading: store.isLoadingEnergyImpact || store.isMenuBarProcessSamplePending,
            appCount: apps.count
        )
        return GeekCombinedCard(
            height: GeekPowerLayout.significantEnergyHeight(for: apps.count)
        ) {
            VStack(alignment: .leading, spacing: 1) {
                GeekProcessListHeader(
                    title: L10n.text("使用显著能耗", "Using Significant Energy").uppercased(),
                    columns: [GeekProcessListColumn(id: "power", title: L10n.text("功率", "Power"),
                                                    accessibilityLabel: L10n.text("当前功率", "Current power"))]
                ) {
                    if store.isLoadingEnergyImpact || store.isMenuBarProcessSamplePending {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 10, height: 10)
                    }
                }

                switch state {
                case .apps:
                    ForEach(apps) { app in
                        GeekPowerEnergyAppRow(app: app)
                    }
                case .loading:
                    geekPowerSamplingRow(L10n.text("正在扫描应用…", "Scanning apps…"))
                case .empty:
                    geekPowerSamplingRow(
                        L10n.text(
                            "当前没有显著能耗应用",
                            "No significant-energy apps"
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var geekDisplayedEnergyApps: [EnergyImpactApp] {
        Array(geekEnergyApps.prefix(GeekPowerLayout.displayedEnergyAppCount))
    }

    private var geekHasEnergyImpactSnapshot: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return true
        }
#endif
        return store.menuBarPreparedProcesses != nil
    }

    private var geekShouldRefreshEnergyImpact: Bool {
        geekShouldRefreshOnDemandSnapshot
    }

    private var geekPowerModeTitle: String? {
        BatteryChargeLimitPresentation.energyModeCardTitle(
            mode: geekCurrentPowerMode, state: hasInternalBattery ? batteryChargeLimitState : nil
        )
    }

    var geekBatteryPowerMode: BatteryPowerMode? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.powerModes.battery
        }
#endif
        return computerHealthStore.batteryPowerModes.battery
            ?? computerHealthStore.snapshot?.battery?.batteryPowerMode
            ?? healthSummary?.batteryPowerMode
    }

    private var geekBatteryRingSymbol: String? {
        GeekBatteryRingState.resolve(snapshot: batterySnapshot).statusSymbol
    }

    var geekAdapterPowerMode: BatteryPowerMode? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.powerModes.adapter
        }
#endif
        return computerHealthStore.batteryPowerModes.adapter
            ?? computerHealthStore.snapshot?.battery?.adapterPowerMode
    }

    var geekSupportedBatteryPowerModes: [BatteryPowerMode] {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.powerModes.supportedBatteryModes
        }
#endif
        return computerHealthStore.batteryPowerModes.supportedBatteryModes
    }

    var geekSupportedAdapterPowerModes: [BatteryPowerMode] {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.powerModes.supportedAdapterModes
        }
#endif
        return computerHealthStore.batteryPowerModes.supportedAdapterModes
    }

    private var geekEnergyModeGroupCount: Int {
        (hasInternalBattery && !geekSupportedBatteryPowerModes.isEmpty ? 1 : 0)
            + (!geekSupportedAdapterPowerModes.isEmpty ? 1 : 0)
    }

    private var geekEnergyModeRowCounts: [Int] {
        var counts = [Int]()
        if hasInternalBattery, !geekSupportedBatteryPowerModes.isEmpty {
            counts.append(geekSupportedBatteryPowerModes.count)
        }
        if !geekSupportedAdapterPowerModes.isEmpty {
            counts.append(geekSupportedAdapterPowerModes.count)
        }
        return counts
    }

    private var geekPowerModeHelpText: String {
        "\(L10n.text("能源模式", "Energy Mode")): \(geekPowerModeTitle ?? geekHealthSamplingText)"
    }

    var geekCurrentPowerMode: BatteryPowerMode? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            let modes = MiniWindowDemoData.hardwareControlProfile.powerModes
            return switch batterySnapshot?.powerSource {
            case .batteryPower: modes.battery ?? modes.adapter
            case .acPower: modes.adapter ?? modes.battery
            case .unknown, nil: modes.adapter ?? modes.battery
            }
        }
#endif
        switch batterySnapshot?.powerSource {
        case .acPower:
            return geekAdapterPowerMode ?? geekBatteryPowerMode
        case .batteryPower:
            return geekBatteryPowerMode ?? geekAdapterPowerMode
        case .unknown, nil:
            return geekBatteryPowerMode ?? geekAdapterPowerMode
        }
    }

    private var hasAvailableEnergyMode: Bool {
        geekEnergyModeGroupCount > 0 || batteryChargeLimitState != nil
    }

    private var geekHealthSamplingText: String {
        computerHealthStore.isRefreshing
            ? L10n.text("正在采样", "Sampling")
            : L10n.text("未采集", "Not sampled")
    }

    private var geekBatteryHealthPercent: Int? {
        if let percent = healthSummary?.batteryCapacityPercent {
            return percent
        }
        guard let electrical = batteryElectricalSnapshot,
              let design = electrical.designCapacityMAh,
              let maximum = electrical.maximumCapacityMAh,
              design > 0 else { return nil }
        let percentage = Double(maximum) / Double(design) * 100
        guard percentage.isFinite, percentage >= 0 else { return nil }
        return Int(min(100, percentage).rounded())
    }

    private var geekBatteryHealthDetail: String {
        if let condition = healthSummary?.batteryCondition {
            return batteryConditionText(condition)
        }
        if let condition = batteryElectricalSnapshot?.condition {
            return batteryConditionText(condition)
        }
        return geekHealthSamplingText
    }

    private var geekBatteryTint: Color {
        switch batterySnapshot?.powerSource ?? .unknown {
        case .acPower: return panelMetricColors.batteryCharging
        case .batteryPower: return panelMetricColors.batteryDraining
        case .unknown: return GeekBatteryChartPalette.unknown
        }
    }

    private var geekAdapterNameText: String {
        batteryElectricalSnapshot?.adapterName
            ?? L10n.text("未公开型号", "Model unavailable")
    }

    private var geekAdapterPowerText: String {
        batteryElectricalSnapshot?.adapterPowerWatts
            .map { String(format: "%.0f W", $0) } ?? "--"
    }

    private var geekAdapterVoltageText: String {
        batteryElectricalSnapshot?.adapterVoltageVolts
            .map { String(format: "%.1f V", $0) } ?? "--"
    }

    private var geekAdapterAmperageText: String {
        batteryElectricalSnapshot?.adapterAmperageAmps
            .map { String(format: "%.2f A", $0) } ?? "--"
    }

    private func geekPowerSamplingRow(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 19)
        .accessibilityElement(children: .combine)
    }
}

private struct GeekPowerEnergyAppRow: View {
    let app: EnergyImpactApp

    private var powerText: String {
        app.currentEvidence.source == .unknown ? "—" : app.currentPowerWattsText
    }

    var body: some View {
        HStack(spacing: 6) {
            GeekSecondaryProcessIcon(path: app.iconPath, fallback: AppSymbols.Monitor.power)

            Text(app.name)
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(powerText)
                .font(AdvancedPanelTypography.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: MiniWindowStyleTokens.dataRowHeight)
        .help("\(app.name) · \(powerText) · \(app.currentEvidence.detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue("\(powerText), \(app.currentEvidence.detail)")
    }
}
