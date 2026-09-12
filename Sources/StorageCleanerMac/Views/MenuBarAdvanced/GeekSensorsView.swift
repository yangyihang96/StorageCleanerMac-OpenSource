import SwiftUI

enum GeekSensorTemperatureLayout {
    static let chromeHeight: CGFloat = 26
    static let rowHeight: CGFloat = 16
    static let gridRowHeight: CGFloat = 18
    static let gridColumnSpacing: CGFloat = 10
    static let gaugeSpacing: CGFloat = 24
    static let miniRingSize: CGFloat = 14
    static let fontSize: CGFloat = 12

    static func cardHeight(rowCount: Int) -> CGFloat {
        chromeHeight + CGFloat(max(0, rowCount)) * rowHeight
    }

    static func temperatureGridRowCount(itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return (itemCount + 1) / 2
    }

    static func temperatureCardHeight(itemCount: Int) -> CGFloat {
        chromeHeight
            + CGFloat(temperatureGridRowCount(itemCount: itemCount)) * gridRowHeight
    }
}

enum GeekSensorPageAvailability: Equatable {
    case sampling
    case available
    case unavailable

    static func resolve(
        reportedAvailability: SystemSensorAvailability,
        hasSensorData: Bool
    ) -> Self {
        if hasSensorData { return .available }
        switch reportedAvailability {
        case .sampling: return .sampling
        case .available: return .available
        case .unavailable: return .unavailable
        }
    }
}

extension MenuBarAdvancedStatusView {
    var geekSensorsPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            switch geekSensorPageAvailability {
            case .sampling:
                geekSensorStatusCard(PanelChartSampling.statusText)
                    .id(GeekHardwareDetailFocus.monitoring)
            case .unavailable:
                geekSensorStatusCard(
                    L10n.text(
                        "此 Mac 没有可用的传感器读数",
                        "No sensor readings are available for this Mac"
                    )
                )
                .id(GeekHardwareDetailFocus.monitoring)
            case .available:
                if geekHasSensorGaugeData {
                    geekSensorsGaugeCard
                        .id(GeekHardwareDetailFocus.monitoring)
                }
                if !geekDisplayedTemperatures.isEmpty {
                    geekTemperatureCard
                }
            }

            geekHardwareControlSummaryCard
                .id(GeekHardwareDetailFocus.power)

            if showsExtendedGeekDetails, !geekFrequencyClusters.isEmpty {
                geekFrequencyCard
            }
        }
    }

    private func geekSensorStatusCard(_ text: String) -> some View {
        GeekCombinedCard(height: 43) {
            Text(text)
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .accessibilityLabel(text)
        }
    }

    private var geekSensorsGaugeCard: some View {
        GeekCombinedCard(height: GeekHardwareControlLayout.summaryHeight) {
            HStack(spacing: 18) {
                if let temperatureValue {
                    GeekHoverDetailTarget(
                        accessibilityLabel: L10n.text("CPU 温度三级详情", "CPU Temperature Deep Detail"),
                        chartRangeMetric: .temperature,
                        popoverSize: geekSensorHistoryPopoverSize(channel: .chipTemperature)
                    ) {
                        GeekCombinedRing(
                            title: "CPU",
                            value: geekCompactTemperature(temperatureValue),
                            detail: geekProcessorFrequencyTextCompact,
                            progress: min(1, max(0, temperatureValue / 100)),
                            tint: temperatureTint,
                            size: GeekHardwareControlLayout.summaryRingSize,
                            labelPlacement: .aboveValue
                        )
                        .help(L10n.text(
                            "芯片温度汇总；温度弧范围为 0–100°C，并非 CPU 占用率。",
                            "Aggregated chip temperature; the arc spans 0–100°C, not CPU utilization."
                        ))
                    } detail: {
                        GeekSensorMetricHoverDetail(
                            title: L10n.text("CPU 温度", "CPU Temperature"),
                            currentValue: metricValue(.chipTemperature),
                            points: geekChartHistory,
                            channel: .chipTemperature,
                            unit: .temperature,
                            valueRange: 0...100,
                            tint: temperatureTint,
                            duration: geekChartDuration,
                            secondaryTitle: L10n.text("频率", "Frequency"),
                            secondaryValue: geekProcessorFrequencyTextCompact
                        )
                    }
                }

                if geekGPUTemperature != nil || metricAvailable(.gpuUsage) {
                    let gpuTemperatureChannel = geekGPUTemperature.map { _ in
                        MenuBarTelemetryChannel.gpuTemperature
                    }
                    GeekHoverDetailTarget(
                        accessibilityLabel: L10n.text(
                            "GPU 温度三级详情",
                            "GPU Temperature Deep Detail"
                        ),
                        chartRangeMetric: .temperature,
                        popoverSize: geekSensorHistoryPopoverSize(channel: gpuTemperatureChannel)
                    ) {
                        GeekCombinedRing(
                            title: "GPU",
                            value: geekGPUTemperature.map(geekCompactTemperature) ?? metricValue(.gpuUsage),
                            detail: geekGPURingDetail,
                            progress: geekGPUTemperature.map { min(1, max(0, $0 / 100)) }
                                ?? metricPercent(.gpuUsage),
                            tint: geekGPUTemperature.map(geekTemperatureTint) ?? resolvedGPUTint,
                            size: GeekHardwareControlLayout.summaryRingSize,
                            labelPlacement: .aboveValue
                        )
                        .help(geekGPUTemperature != nil
                            ? L10n.text("GPU 温度；温度弧范围为 0–100°C。", "GPU temperature; the arc spans 0–100°C.")
                            : L10n.text("GPU 温度不可用；当前显示负载，范围为 0–100%。", "GPU temperature is unavailable; showing utilization on a 0–100% scale."))
                    } detail: {
                        GeekSensorMetricHoverDetail(
                            title: L10n.text("GPU 温度", "GPU Temperature"),
                            currentValue: geekGPUTemperature.map { String(format: "%.1f°C", $0) }
                                ?? PanelChartSampling.statusText,
                            points: geekChartHistory,
                            channel: gpuTemperatureChannel,
                            unit: .temperature,
                            valueRange: 0...100,
                            tint: geekGPUTemperature.map(geekTemperatureTint) ?? resolvedGPUTint,
                            duration: geekChartDuration,
                            secondaryTitle: metricAvailable(.gpuUsage)
                                ? L10n.text("负载", "Load")
                                : nil,
                            secondaryValue: metricAvailable(.gpuUsage) ? metricValue(.gpuUsage) : nil
                        )
                    }
                }

                ControlPaletteHoverAnchor(
                    kind: .fan,
                    accessibilityLabel: L10n.text("打开风扇控制", "Open Fan Controls")
                ) {
                    GeekCombinedRing(
                        title: L10n.text("风扇", "FANS"),
                        value: geekSensorFanRingValue,
                        detail: geekSensorFanRingDetail,
                        progress: geekFanTelemetry.percentage.map { $0 / 100 },
                        tint: AppDesignTokens.Palette.tertiary,
                        size: GeekHardwareControlLayout.summaryRingSize,
                        labelPlacement: .aboveValue,
                        fixedDetailFontSize: 8.5
                    )
                    .help(L10n.text(
                        "中心为实际转速；多风扇显示平均 RPM。仅完整读取每只风扇的最低和最高转速时显示量程弧，0% 表示最低转速，不代表停转。",
                        "The center shows actual RPM, averaged for multiple fans. The arc uses each fan’s complete minimum–maximum range; 0% means its minimum speed, not a stopped fan."
                    ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var geekTemperatureCard: some View {
        GeekCombinedCard(
            height: GeekSensorTemperatureLayout.temperatureCardHeight(
                itemCount: geekDisplayedTemperatures.count
            )
        ) {
            VStack(alignment: .leading, spacing: 0) {
                geekSensorHeader(L10n.text("温度", "TEMPERATURE"))

                LazyVGrid(
                    columns: [
                        GridItem(
                            .flexible(),
                            spacing: GeekSensorTemperatureLayout.gridColumnSpacing,
                            alignment: .leading
                        ),
                        GridItem(.flexible(), alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(geekDisplayedTemperatures) { reading in
                        geekTemperatureRow(reading)
                    }
                }
            }
        }
    }

    /// Monitoring and control are deliberately separate surfaces (the iStat
    /// model). This card only *reads*: per-fan speeds with hover history and
    /// the current mode. All mode switches and sliders live exclusively in
    /// the attached control palette, so interacting with monitoring UI can
    /// never change the hardware state.
    private var geekHardwareControlSummaryCard: some View {
        GeekCombinedCard(height: geekFanControlCardHeight, verticalPadding: 5) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L10n.text("风扇", "FANS"))
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(AppDesignTokens.Palette.tertiary)
                    Spacer(minLength: 4)
                    if geekHelperState != .enabled {
                        Button(action: compactHelperAction) {
                        MiniWindowStatusCapsule(
                            title: compactHelperActionTitle,
                            tint: helperSummaryTint,
                            isBusy: fanControl.isPreparingHelper
                                || fanControl.isRefreshingConnection
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .help(compactHelperHelp)
                    .accessibilityLabel(L10n.text("高级控制状态", "Advanced Control Status"))
                    .accessibilityValue(FanStatusPresentation.controlTitle(geekFanControlCapabilityState))
                    }
                }
                .frame(height: 18)

                if geekFanTelemetry.readings.isEmpty {
                    HStack(spacing: 6) {
                        Text(geekFanTelemetry.isFanless
                            ? L10n.text("无风扇 · 被动散热", "No Fans · Passive Cooling")
                            : geekFanTelemetry.isSampling
                                ? L10n.text("正在检测风扇…", "Checking Fans…")
                                : L10n.text("风扇读数不可用", "Fan readings unavailable"))
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 24)
                } else {
                    ForEach(geekFanTelemetry.readings.prefix(2)) { reading in
                        compactFanHistoryRow(reading)
                    }
                }

                Divider().opacity(0.34)

                // The single entry into fan control: a pinned palette with
                // the mode toggles, sliders and the curve editor.
                ControlPaletteHoverAnchor(
                    kind: .fan,
                    accessibilityLabel: L10n.text("打开风扇控制", "Open Fan Controls")
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(L10n.text("风扇控制", "Fan Control"))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        Text(geekFanModeOrCapabilityTitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: AppSymbols.Panel.disclosure)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .font(AdvancedPanelTypography.caption)
                    .frame(height: 22)
                }

                if geekFanThermallyProtected {
                    Text(L10n.text("热保护中", "Thermal protection"))
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                }

            }
        }
    }

    private var geekFanThermallyProtected: Bool {
        let state = monitorSnapshot?.thermalState
        return state == .serious || state == .critical
    }

    private var geekFanControlCardHeight: CGFloat {
        // Vertical padding + header + monitoring rows + divider + control
        // entry + status line + stack spacing.
        let monitoringRows = CGFloat(max(1, min(2, geekFanTelemetry.readings.count))) * 24
        return 10 + 18 + monitoringRows + 1 + 22 + 18 + (geekFanThermallyProtected ? 17 : 0)
    }

    private func compactFanHistoryRow(_ reading: SystemFanReading) -> some View {
        ControlPaletteHoverAnchor(
            kind: .fan,
            accessibilityLabel: L10n.text("\(reading.displayName)转速与控制", "\(reading.displayName) History and Controls"),
            selectedFanIndex: reading.index
        ) {
            HStack(spacing: 6) {
                Text(reading.displayName).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(reading.displayRPM).foregroundStyle(.primary).monospacedDigit().lineLimit(1)
                Image(systemName: AppSymbols.Panel.disclosure)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(AdvancedPanelTypography.caption)
            .frame(height: 24)
        }
    }

    private var helperSummaryTint: Color {
        switch geekFanControlCapabilityState {
        case .controllable:
            AppDesignTokens.Palette.tertiary
        case .checking, .authorizationRequired, .requiresSystemApproval, .readOnly:
            AppDesignTokens.Palette.information
        case .unsupported, .connectionFailed:
            AppDesignTokens.Palette.warning
        }
    }

    private var compactHelperHelp: String {
        geekHardwareControlMessage ?? L10n.text(
            "设置高级风扇控制",
            "Set up advanced fan controls"
        )
    }

    private var compactHelperActionTitle: String {
        switch geekHelperState {
        case .notRegistered, .unavailable: L10n.text("启用控制", "Enable Controls")
        case .requiresApproval: L10n.text("完成授权", "Finish Setup")
        case .enabled, .connectionInterrupted, .signatureRejected: L10n.text("重新连接", "Reconnect")
        }
    }

    private func compactHelperAction() {
        switch geekHelperState {
        // `unavailable` includes launchd's pre-submission state, so it must
        // attempt registration rather than only retrying a connection that
        // cannot exist yet.
        case .notRegistered, .unavailable:
            Task { await fanControl.registerHelper() }
        case .requiresApproval:
            fanControl.openApprovalSettings()
        case .enabled, .connectionInterrupted, .signatureRejected:
            Task { await fanControl.refreshConnection() }
        }
    }

    private var geekFrequencyCard: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("CPU 频率三级详情", "CPU Frequency Deep Detail"),
            popoverSize: GeekSensorPowerHoverDetailMetrics.compactSamplingSize
        ) {
            GeekCombinedCard(
                height: GeekSensorTemperatureLayout.cardHeight(
                    rowCount: geekFrequencyClusters.count
                )
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    geekSensorHeader(
                        L10n.text("CPU 频率", "CPU FREQUENCY"),
                        emphasized: false
                    )

                    ForEach(geekFrequencyClusters, id: \.identifier) { cluster in
                        GeekTelemetryRow(
                            title: processorClusterTitle(cluster),
                            value: cluster.frequencyMHz.map(processorFrequencyText) ?? "--",
                            tint: processorClusterTint(cluster)
                        )
                    }
                }
            }
        } detail: {
            GeekFrequencyHoverDetail(clusters: geekFrequencyClusters)
        }
    }

    private var geekRegionalTemperatureByZone: [SystemTemperatureZone: SystemTemperatureReading] {
        var byZone = Dictionary(
            uniqueKeysWithValues: (monitorSnapshot?.temperatureReadings ?? [])
                .filter { $0.celsius.isFinite }
                .map { ($0.zone, $0) }
        )
        if hasInternalBattery,
           let batteryTemperature = batteryElectricalSnapshot?.temperatureCelsius,
           batteryTemperature.isFinite {
            byZone[.battery] = SystemTemperatureReading(
                zone: .battery,
                celsius: batteryTemperature
            )
        }
        let hasChipRegion = [.chip, .soc, .performanceCores, .superCores, .efficiencyCores]
            .contains { byZone[$0] != nil }
        if !hasChipRegion, let temperatureValue {
            byZone[.chip] = SystemTemperatureReading(zone: .chip, celsius: temperatureValue)
        }
        return byZone
    }

    private var geekDisplayedTemperatures: [SystemTemperatureReading] {
        let byZone = geekRegionalTemperatureByZone
        return GeekTemperatureZoneLayout
            .displayZones(available: Set(byZone.keys))
            .compactMap { byZone[$0] }
    }

    var geekGPUTemperature: Double? {
        geekDisplayedTemperatures.first { $0.zone == .gpu }?.celsius
    }

    private var geekGPURingDetail: String? {
        guard metricAvailable(.gpuUsage) else { return nil }
        return geekGPUTemperature == nil
            ? L10n.text("负载", "Load")
            : metricValue(.gpuUsage)
    }

    private var geekHasSensorGaugeData: Bool {
        temperatureValue != nil
            || geekGPUTemperature != nil
            || metricAvailable(.gpuUsage)
            || !geekFanReadings.isEmpty
    }

    private var geekSensorPageAvailability: GeekSensorPageAvailability {
        GeekSensorPageAvailability.resolve(
            reportedAvailability: monitorSnapshot?.sensorAvailability ?? .sampling,
            hasSensorData: geekHasSensorGaugeData
                || !geekDisplayedTemperatures.isEmpty
                || !geekFanReadings.isEmpty
                || !geekFrequencyClusters.isEmpty
        )
    }

    private var geekFrequencyClusters: [CPUPerformanceStateService.ClusterReading] {
        processorTelemetry?.clusters.filter { $0.frequencyMHz != nil } ?? []
    }

    var geekFanTelemetry: FanTelemetryState {
        FanTelemetryState.resolve(snapshot: monitorSnapshot)
    }

    private var geekFanReadings: [SystemFanReading] {
        geekFanTelemetry.readings
    }

    private var geekFanAverageRPM: Int? {
        geekFanTelemetry.actualRPM
    }

    var geekHelperState: HelperState {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.helperState
        }
#endif
        return fanControl.helperState
    }

    var geekObservedFanMode: GeekFanControlMode? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.observedMode
        }
#endif
        return fanControl.observedMode
    }

    var geekFanControlModeState: FanControlMode {
        FanControlMode.resolve(observedMode: geekObservedFanMode)
    }

    var geekFanControlCapabilityState: FanControlCapability {
        FanControlCapability.resolve(
            telemetry: geekFanTelemetry,
            helperState: geekHelperState
        )
    }

    private var geekHardwareThermalState: SystemThermalState {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.thermalState
        }
#endif
        return monitorSnapshot?.thermalState ?? .nominal
    }

    private var geekHardwareControlMessage: String? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.message
        }
#endif
        return fanControl.lastMessage
    }

    private var geekPreviewManualPercentage: Double? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.manualPercentage
        }
#endif
        return nil
    }

    private var geekPowerModes: BatteryPowerModes {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.powerModes
        }
#endif
        return computerHealthStore.batteryPowerModes
    }

    private var geekPowerModeCapability: PowerModeCapability {
        PowerModeCapability.resolve(
            modes: geekPowerModes,
            hasCompletedRead: geekHasCompletedPowerModeRead,
            helperState: geekHelperState
        )
    }

    private var geekHasCompletedPowerModeRead: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return true }
#endif
        return computerHealthStore.hasCompletedBatteryPowerModeRead
    }

    private var geekSensorFanRingValue: String {
        if geekFanTelemetry.isSampling { return "—" }
        if geekFanTelemetry.isFanless { return L10n.text("无", "None") }
        return geekFanTelemetry.actualRPM.map(SystemFanSpeedFormat.number) ?? "—"
    }

    private var geekSensorFanRingDetail: String {
        if geekFanTelemetry.isSampling { return L10n.text("检测中…", "Checking…") }
        if geekFanTelemetry.isFanless { return L10n.text("被动散热", "Passive Cooling") }
        guard geekFanTelemetry.actualRPM != nil else {
            return L10n.text("不可用", "Unavailable")
        }
        return geekFanTelemetry.fanCount > 1 ? L10n.text("平均 rpm", "Average rpm") : "rpm"
    }

    private var geekFanModeOrCapabilityTitle: String {
        FanStatusPresentation.confirmedModeTitle(fanControl.observedMode)
    }

    private var geekFanHoverDetail: some View {
        GeekFanHoverDetail(
            points: geekChartHistory,
            duration: geekChartDuration,
            currentValue: geekFanAverageRPM.map(SystemFanSpeedFormat.string)
                ?? L10n.text("未采集", "Not Collected"),
            readings: geekFanReadings,
            valueRange: 0...fanTrendMaximum,
            selectedFanIndex: nil
        )
    }

    private func geekSensorHistoryPopoverSize(
        points: [MenuBarTelemetryPoint]? = nil,
        channel: MenuBarTelemetryChannel?
    ) -> CGSize {
        let points = points ?? geekChartHistory
        let sampleCount = channel.map { channel in
            points.compactMap { channel.value(in: $0) }.filter(\.isFinite).count
        } ?? 0
        return GeekSensorPowerHoverDetailMetrics.popoverSize(
            sampleCount: sampleCount,
            expandedSize: GeekSensorPowerHoverDetailMetrics.sensorHistorySize
        )
    }

    private func geekSensorHeader(
        _ title: String,
        emphasized: Bool = true
    ) -> some View {
        Text(title)
            .font(AdvancedPanelTypography.captionStrong)
            .foregroundStyle(emphasized ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private func geekTemperatureRow(_ reading: SystemTemperatureReading) -> some View {
        let zone = reading.zone
        let channel = MenuBarTelemetryChannel.temperature(zone)
        return GeekHoverDetailTarget(
            accessibilityLabel: L10n.text(
                "\(geekTemperatureZoneTitle(zone))温度三级详情",
                "\(geekTemperatureZoneTitle(zone)) Temperature Deep Detail"
            ),
            chartRangeMetric: .temperature,
            popoverSize: geekSensorHistoryPopoverSize(channel: channel)
        ) {
            geekTemperatureRowContent(zone: zone, reading: reading)
        } detail: {
            GeekSensorMetricHoverDetail(
                title: geekTemperatureZoneTitle(zone),
                currentValue: String(format: "%.1f°C", reading.celsius),
                points: geekChartHistory,
                channel: channel,
                unit: .temperature,
                valueRange: 0...100,
                tint: geekTemperatureTint(reading.celsius),
                duration: geekChartDuration
            )
        }
    }

    private func geekTemperatureRowContent(
        zone: SystemTemperatureZone,
        reading: SystemTemperatureReading
    ) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(geekCompactTemperatureZoneTitle(zone))
                .font(.system(size: GeekSensorTemperatureLayout.fontSize, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 2)

            Text(geekCompactTemperature(reading.celsius))
                .font(.system(size: GeekSensorTemperatureLayout.fontSize, weight: .regular))
                .foregroundStyle(geekTemperatureValueForeground(reading.celsius))
                .monospacedDigit()
                .lineLimit(1)

            Image(systemName: AppSymbols.Panel.disclosure)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: GeekSensorTemperatureLayout.miniRingSize)
                .accessibilityHidden(true)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: GeekSensorTemperatureLayout.gridRowHeight,
            maxHeight: GeekSensorTemperatureLayout.gridRowHeight,
            alignment: .leading
        )
        .help(L10n.text("查看历史趋势", "View History Trend"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(geekTemperatureZoneTitle(zone))
        .accessibilityValue(String(format: "%.1f°C", reading.celsius))
    }

    private func geekTemperatureZoneTitle(_ zone: SystemTemperatureZone) -> String {
        switch zone {
        case .chip: "CPU"
        case .soc: "SoC"
        case .performanceCores: L10n.text("CPU 性能核心", "CPU P-Cores")
        case .superCores: L10n.text("CPU 超级核心", "CPU Super Cores")
        case .efficiencyCores: L10n.text("CPU 能效核心", "CPU E-Cores")
        case .gpu: "GPU"
        case .storage: "SSD"
        case .battery: L10n.text("电池", "Battery")
        case .ambient: L10n.text("散热气流", "Airflow")
        case .palmRest: L10n.text("掌托", "Palm Rest")
        case .thunderboltLeft: L10n.text("左侧雷雳", "Thunderbolt Left")
        case .thunderboltRight: L10n.text("右侧雷雳", "Thunderbolt Right")
        case .wifi: "Wi-Fi"
        }
    }

    private func geekCompactTemperatureZoneTitle(_ zone: SystemTemperatureZone) -> String {
        switch zone {
        case .performanceCores: L10n.text("性能核心", "P-Cores")
        case .superCores: L10n.text("超级核心", "Super Cores")
        case .efficiencyCores: L10n.text("能效核心", "E-Cores")
        case .thunderboltLeft: L10n.text("雷雳左", "TB Left")
        case .thunderboltRight: L10n.text("雷雳右", "TB Right")
        default: geekTemperatureZoneTitle(zone)
        }
    }

    private func geekCompactTemperature(_ value: Double) -> String {
        String(format: "%.0f°C", value)
    }

    private func geekTemperatureTint(_ value: Double) -> Color {
        if value >= 90 { return AppDesignTokens.Palette.destructive }
        if value >= 80 { return AppDesignTokens.Palette.warning }
        return resolvedThermalTint
    }

    private func geekTemperatureValueForeground(_ value: Double) -> Color {
        value >= 80 ? geekTemperatureTint(value) : .primary
    }
}

enum GeekTemperatureZoneLayout {
    static func displayZones(
        available: Set<SystemTemperatureZone>
    ) -> [SystemTemperatureZone] {
        let orderedZones: [SystemTemperatureZone] = [
            .chip,
            .soc,
            .performanceCores,
            .efficiencyCores,
            .superCores,
            .gpu,
            .storage,
            .battery,
            .ambient,
            .palmRest,
            .thunderboltLeft,
            .thunderboltRight,
            .wifi
        ]
        return orderedZones.filter(available.contains)
    }
}
