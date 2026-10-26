import AppKit
import SwiftUI

/// D138: iStat's energy-mode section (`-[BBRBatteryMenuEnergyModeSection
/// drawRect:]`) titles itself 'Power.Energy Mode', or 'Power.Mode' when the
/// title (upper case, the label font), the value (the value font), 16 and 20
/// are wider than the section; both texts unrounded. Our value carries the
/// charge limit after the mode, so in English the title is often MODE.
enum GeekEnergyModeTitle {
    static let padding: CGFloat = 16 + 20
    static var sectionWidth: CGFloat {
        MiniWindowStyleTokens.powerDetailWidth - 2 * MiniWindowStyleTokens.contentInset
    }

    static func title(value: String, sectionWidth: CGFloat = sectionWidth) -> String {
        let full = L10n.text("能耗模式", "Energy Mode")
        let titleFont = NSFont.systemFont(ofSize: GeekIStatCardGeometry.textFontSize)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: GeekIStatCardGeometry.textFontSize, weight: .regular)
        let needed = width(full.uppercased(), titleFont) + width(value, valueFont) + padding
        return needed > sectionWidth ? L10n.text("模式", "Mode") : full
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

enum GeekPowerLayout {
    /// D119: iStat's battery card is the memory card's: two 96 pt rings
    /// (line 6) centered in the halves, 56 pt below the top.
    static let gaugeHeight: CGFloat = GeekIStatCardGeometry.memoryHeight
    /// D119: the adapter's title row and its three negotiated readings,
    /// 24 + 17 × 3 (was 94).
    static let adapterHeight = GeekIStatSectionGeometry.rowsHeight(3, titled: true)
    /// D119: iStat's 80 pt charge chart (was 79).
    static let historyHeight = GeekIStatSectionGeometry.chargeChartHeight
    static var historyChartHeight: CGFloat {
        historyHeight - GeekIStatSectionGeometry.chargeChartTop - GeekIStatSectionGeometry.chargeChartBottomInset
    }
    static let modeHeight = GeekIStatSectionGeometry.singleRowHeight
    static let displayedEnergyAppCount = 3
    /// D119: iStat's process section for three apps, 25 + 17 × 3 (was 79).
    static let significantEnergyHeight = GeekIStatSectionGeometry.processesHeight(displayedEnergyAppCount)
    /// D132: the charge chart is iStat's battery menu graph, 69 buckets of
    /// 15 minutes (`GeekIStatBatteryGraph.menu`); it showed the last hour
    /// (`detailPreviewDuration`, 3600 s).
    static let menuGraphDuration = Double(GeekIStatBatteryGraph.menuBarCount) * GeekIStatBatteryGraph.menuInterval
    static let historyTertiaryOffset = GeekPanelLayout.contentPadding
        + gaugeHeight
        + GeekPanelLayout.detailSpacing
    /// D119: the energy mode follows the charge chart (the electrical and
    /// power cards moved to the sensors page).
    static let energyModeTertiaryOffset = GeekPanelLayout.contentPadding
        + gaugeHeight
        + GeekPanelLayout.detailSpacing
        + historyHeight
        + GeekPanelLayout.detailSpacing

    static func energyModeSourceOffset(hasInternalBattery: Bool) -> CGFloat {
        hasInternalBattery
            ? energyModeTertiaryOffset
            : GeekPanelLayout.contentPadding + adapterHeight + GeekPanelLayout.detailSpacing
    }

    /// The process section lists up to three apps and shrinks with fewer:
    /// 42, 59 or 76 (one row for the scanning and empty states).
    static func significantEnergyHeight(for appCount: Int) -> CGFloat {
        GeekIStatSectionGeometry.processesHeight(min(max(1, appCount), displayedEnergyAppCount))
    }

    /// iStat's battery menu: the battery card, the charge chart, the energy
    /// mode and the apps using significant energy.
    static let secondaryCardHeights = [
        gaugeHeight,
        historyHeight,
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
        // D119: iStat's battery menu at 240 pt: the battery card (charge and
        // health), the charge chart, the energy mode and the apps using
        // significant energy.
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.battery) {
                VStack(spacing: GeekPanelLayout.detailSpacing) {
                    if hasInternalBattery {
                        geekPowerGaugeCard
                        geekPowerHistoryCard
                    } else {
                        geekPowerAdapterCard
                    }
                }
            }
            // D119: the battery current and voltage, the power rows (D57,
            // BOARD N16-6) and the helper's chip power are groups of the
            // sensors page, as in iStat's sensor menu.
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

    /// D119: a titled group of iStat rows with the adapter's name in the
    /// title row (was a combined card's 18 pt header over telemetry rows).
    private var geekPowerAdapterCard: some View {
        GeekIStatRowsCard(title: L10n.text("电源适配器", "POWER ADAPTER"), rowCount: 3) {
            Text(geekAdapterNameText)
                .geekIStatValueText(.secondary)
        } rows: {
            GeekIStatRow(title: L10n.text("协商功率", "Negotiated Power"), value: geekAdapterPowerText)
            GeekIStatRow(title: L10n.text("协商电压", "Negotiated Voltage"), value: geekAdapterVoltageText)
            GeekIStatRow(title: L10n.text("协商电流", "Negotiated Current"), value: geekAdapterAmperageText)
        }
        .accessibilityHint(L10n.text(
            "由 macOS 电源适配器接口报告；这是协商输入规格，不是墙插功率计读数。",
            "Reported by the macOS power-adapter interface; this is the negotiated input specification, not a wall-meter reading."
        ))
    }

    private var geekPowerGaugeCard: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("电池与充电三级详情", "Battery and Charging Deep Detail"),
            popoverSize: geekBatteryElectricalDetail.popoverSize,
            usesCardActiveBorder: true
        ) {
            // D119: the memory card's rings (iStat's battery card), each
            // centered in its half (were 96 pt rings 12 pt apart).
            GeekIStatCard(height: GeekPowerLayout.gaugeHeight) {
                HStack(spacing: 0) {
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
                        size: GeekIStatCardGeometry.memoryRingSize,
                        fixedValueFontSize: GeekIStatCardGeometry.memoryValueFontSize,
                        strokeWidth: GeekIStatCardGeometry.memoryRingLineWidth,
                        fixedLabelFontSize: GeekIStatCardGeometry.ringLabelFontSize
                    )
                    .frame(maxWidth: .infinity)

                    GeekCombinedRing(
                        // D138: iStat's 'Power.HealthShort' (was 电池健康).
                        title: L10n.text("健康", "HEALTH"),
                        value: geekBatteryHealthPercent.map { "\($0)%" } ?? "--",
                        detail: geekBatteryHealthPercent == nil
                            ? geekBatteryHealthDetail
                            : nil,
                        progress: geekBatteryHealthPercent.map { min(1, Double($0) / 100) },
                        tint: panelMetricColors.batteryHealth,
                        size: GeekIStatCardGeometry.memoryRingSize,
                        fixedValueFontSize: GeekIStatCardGeometry.memoryValueFontSize,
                        strokeWidth: GeekIStatCardGeometry.memoryRingLineWidth,
                        fixedLabelFontSize: GeekIStatCardGeometry.ringLabelFontSize
                    )
                    .frame(maxWidth: .infinity)
                }
                .geekIStatLayer(
                    top: GeekIStatCardGeometry.memoryRingCenterY - GeekIStatCardGeometry.memoryRingSize / 2,
                    height: GeekIStatCardGeometry.memoryRingSize
                )
            }
        } detail: {
            geekBatteryElectricalDetail
        }
    }

    /// D122: the battery page; its size counts the same readings' rows (and,
    /// D137, their widths).
    private var geekBatteryElectricalDetail: GeekBatteryElectricalHoverDetail {
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
            // D119: iStat's 80 pt charge chart (was a 67 pt chart on a 79 pt
            // combined card). D132: its battery menu graph, 69 buckets of
            // 15 minutes, the newest bar's right edge 8 pt in from the card's
            // right, the bars from 8 to 60 and the rail from 64 to 72; the
            // chart takes the card's width (was the last hour across the card
            // inside its 8 pt insets, the bars from 6).
            GeekIStatCard(height: GeekPowerLayout.historyHeight) {
                GeekPowerHistoryChart(
                    points: batteryPowerHistory,
                    metric: .charge,
                    duration: GeekPowerLayout.menuGraphDuration,
                    tint: panelMetricColors.batteryCharging,
                    chargingTint: panelMetricColors.batteryDraining,
                    accessibilityLabel: L10n.text(
                        "电池电量历史，每柱 15 分钟",
                        "Battery-level history, 15 minutes per bar"
                    ),
                    batteryGraph: .menu
                )
                .geekIStatLayer(top: GeekIStatSectionGeometry.chargeChartTop, height: GeekPowerLayout.historyChartHeight,
                                leading: 0, trailing: 0)
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
            // D119: iStat's energy-mode row, the title and the mode on one
            // 25 pt row (was the combined card's caption).
            let value = geekPowerModeTitle ?? geekHealthSamplingText
            GeekIStatSingleRowCard(title: GeekEnergyModeTitle.title(value: value)) {
                Text(value)
                    .geekIStatValueText()
            }
            .help(geekPowerModeHelpText)
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
            // D119: the energy-mode row's place on a Mac without a battery.
            GeekIStatSingleRowCard(title: L10n.text("Mac mini 模式", "Mac mini Mode")) {
                Text(L10n.text("管理", "Manage"))
                    .geekIStatValueText()
            }
        }
    }

    /// D119: iStat's process section, 25 + 17n for up to three apps, the
    /// apps under the title alone; the current power stays as each row's
    /// value (a "Power" column label truncated the title at 240 pt).
    private var geekSignificantEnergyCard: some View {
        let apps = geekDisplayedEnergyApps
        let isLoading = store.isLoadingEnergyImpact || store.isMenuBarProcessSamplePending
        let state = GeekPowerEnergyCardState.resolve(
            hasCachedSnapshot: geekHasEnergyImpactSnapshot,
            isLoading: isLoading,
            appCount: apps.count
        )
        return GeekIStatProcessCard(
            // D138: iStat's 'Power.Using Significant Energy' (was 使用显著能耗).
            title: L10n.text("使用大量能耗", "Using Significant Energy"),
            rowCapacity: max(1, apps.count)
        ) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
            }
        } rows: {
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
        "\(L10n.text("能耗模式", "Energy Mode")): \(geekPowerModeTitle ?? geekHealthSamplingText)"
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
            .map { IStatNumberFormat.power($0) } ?? "--"
    }

    private var geekAdapterVoltageText: String {
        batteryElectricalSnapshot?.adapterVoltageVolts
            .map { IStatNumberFormat.voltage($0) } ?? "--"
    }

    private var geekAdapterAmperageText: String {
        batteryElectricalSnapshot?.adapterAmperageAmps
            .map { IStatNumberFormat.current($0) } ?? "--"
    }

    /// D119: a 15 pt row of the process section.
    private func geekPowerSamplingRow(_ title: String) -> some View {
        Text(title)
            .geekIStatValueText(.secondary)
            .frame(
                maxWidth: .infinity,
                minHeight: GeekIStatSectionGeometry.rowHeight,
                maxHeight: GeekIStatSectionGeometry.rowHeight,
                alignment: .leading
            )
            .accessibilityElement(children: .combine)
    }
}

private struct GeekPowerEnergyAppRow: View {
    let app: EnergyImpactApp

    private var powerText: String {
        app.currentEvidence.source == .unknown ? "—" : app.currentPowerWattsText
    }

    var body: some View {
        // D119: iStat's process row, the 16 pt icon, the name from 28 and
        // the value at the trailing inset (was a 6 pt-spaced data row).
        GeekIStatProcessRow(iconPath: app.iconPath, fallbackSymbol: AppSymbols.Monitor.power, name: app.name) {
            Text(powerText)
                .geekIStatValueText(.secondary)
        }
        .help("\(app.name) · \(powerText) · \(app.currentEvidence.detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue("\(powerText), \(app.currentEvidence.detail)")
    }
}
