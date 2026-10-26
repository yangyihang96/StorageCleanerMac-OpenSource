import SwiftUI

struct GeekTertiaryContentMeasurement: Equatable {
    let detail: MenuBarTertiaryDetail?
    let requestID: UUID?
    let density: PanelDensity
    let size: CGSize
}

private struct GeekTertiaryContentSizeKey: PreferenceKey {
    static let defaultValue: GeekTertiaryContentMeasurement? = nil

    static func reduce(
        value: inout GeekTertiaryContentMeasurement?,
        nextValue: () -> GeekTertiaryContentMeasurement?
    ) {
        if let next = nextValue() {
            value = next
        }
    }
}

enum MenuBarTertiaryDetail: String, CaseIterable, Identifiable {
    case processor
    case memory
    case disk
    case network
    case sensors
    case power
    case fanCurve

    var id: Self { self }

    var title: String {
        switch self {
        case .processor: L10n.text("处理器三级详情", "Processor Detail")
        case .memory: L10n.text("内存三级详情", "Memory Detail")
        case .disk: L10n.text("磁盘三级详情", "Disk Detail")
        case .network: L10n.text("网络三级详情", "Network Detail")
        case .sensors: L10n.text("传感器三级详情", "Sensor Detail")
        case .power: L10n.text("电源三级详情", "Power Detail")
        case .fanCurve: L10n.text("风扇曲线", "Fan Curve")
        }
    }

    var systemImage: String {
        switch self {
        case .processor: AppSymbols.Monitor.processor
        case .memory: AppSymbols.Monitor.memory
        case .disk: AppSymbols.Monitor.storage
        case .network: AppSymbols.Monitor.network
        case .sensors: AppSymbols.Monitor.sensors
        case .power: AppSymbols.Monitor.power
        case .fanCurve: "point.3.connected.trianglepath.dotted"
        }
    }
}

extension PanelSection {
    var tertiaryDetail: MenuBarTertiaryDetail? {
        switch self {
        case .processor: .processor
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .sensors: .sensors
        case .power: .power
        case .overview, .cleanup: nil
        }
    }
}

extension MenuBarAdvancedStatusView {
    func tertiaryDetailRootHost<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
    }

    @ViewBuilder
    var tertiaryDetailColumnSurface: some View {
        Group {
            if let request = activeInlineTertiaryRequest {
                tertiaryRequestSurface(request)
            } else if let detail = activeTertiaryDetail {
                tertiaryDetailSurface(detail)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .menuBarTraceRegion("tertiary")
        .menuBarPresentationProbe(
            "tertiary",
            revision: MenuBarPresentationProbe.revision(
                activeInlineTertiaryRequest.map { $0.id.uuidString } ?? activeTertiaryDetail?.rawValue ?? ""
            ),
            when: activeInlineTertiaryRequest != nil || activeTertiaryDetail != nil
        )
        .onPreferenceChange(GeekTertiaryContentSizeKey.self) { measurement in
            Task { @MainActor in
                guard let measurement else { return }
                updateMeasuredTertiaryContentSize(
                    measurement.size,
                    for: measurement.detail,
                    requestID: measurement.requestID,
                    density: measurement.density
                )
            }
        }
    }

    private func tertiaryDetailSurface(
        _ detail: MenuBarTertiaryDetail
    ) -> some View {
        tertiaryDetailChrome(detail: detail, density: presentation) {
            // The page reads the monitor's prepared windows and live readings,
            // which do not redraw this root view. Without its own card it was
            // redrawn only by an unrelated root update (often a level-two
            // height change), so a newly selected range stayed dimmed for
            // seconds and the history did not advance with new samples.
            liveCard(.levelThree) {
                Group {
                    if detail == .network {
                        GeekNetworkTertiaryView(
                            snapshot: networkInterfaceSnapshot,
                            topology: networkTopologySnapshot,
                            refresh: refreshPanelData,
                            contentPadding: 0
                        )
                    } else {
                        tertiaryDetailBody(detail)
                    }
                }
                // The card redraws the page for any reading it follows; a
                // history frame is prepared again only for a new window, as
                // before the page had a card. With the card's revision in the
                // key, every reading restarted the preparation and could drop
                // a frame that was about to be delivered.
                .environment(\.menuBarChartContext, rootChartContext)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                tertiaryDetailSurfaceHoverChanged(detail, hovering: true)
            case .ended:
                tertiaryDetailSurfaceHoverChanged(detail, hovering: false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail.title)
    }

    func scheduleTertiaryDetailDismissal(_ detail: MenuBarTertiaryDetail) {
        guard !panelCoordinator.isHistoryPinned,
              !geekPanelHoverActivityState.keepsPanelExpanded,
              !isTertiaryDetailSurfaceHovered else { return }
        cancelTertiaryHoverIntent()
        tertiaryHoverIntent = panelCoordinator.scheduleHoverDismissal(
            condition: {
                !geekPanelHoverActivityState.keepsPanelExpanded
                    && !isTertiaryDetailSurfaceHovered
                    && !panelCoordinator.isPointerWithinHoverEnvelope
                    && activeTertiaryDetail == detail
            },
            action: {
                activeTertiaryDetail = nil
                panelCoordinator.dismissUnpinnedHierarchy()
                tertiaryHoverIntent = nil
            }
        )
    }

    private func tertiaryDetailSurfaceHoverChanged(
        _ detail: MenuBarTertiaryDetail,
        hovering: Bool
    ) {
        guard isTertiaryDetailSurfaceHovered != hovering else { return }
        isTertiaryDetailSurfaceHovered = hovering
        cancelTertiaryHoverIntent()
        if !hovering {
            scheduleTertiaryDetailDismissal(detail)
        }
    }

    private func tertiaryRequestSurface(
        _ request: GeekInlineTertiaryRequest
    ) -> some View {
        tertiaryDetailChrome(
            requestID: request.id,
            density: presentation
        ) {
            GeekInlineTertiaryLiveContent(store: request.contentStore)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                request.hoverChanged(true)
            case .ended:
                request.hoverChanged(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.accessibilityLabel)
    }

    private func tertiaryDetailChrome<Content: View>(
        detail: MenuBarTertiaryDetail? = nil,
        requestID: UUID? = nil,
        density: PanelDensity,
        contentPadding: CGFloat = GeekPanelLayout.contentPadding,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.miniWindowPageProvidesInset, true)
                .padding(contentPadding)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: GeekTertiaryContentSizeKey.self,
                            value: GeekTertiaryContentMeasurement(
                                detail: detail,
                                requestID: requestID,
                                density: density,
                                size: proxy.size
                            )
                        )
                    }
                }
        }
        .environment(\.advancedValueRowUsesUniformTextSize, true)
    }

    @ViewBuilder
    private func tertiaryDetailBody(_ detail: MenuBarTertiaryDetail) -> some View {
        switch detail {
        case .processor:
            tertiaryProcessorDetail
        case .memory:
            tertiaryMemoryDetail
        case .disk:
            tertiaryDiskDetail
        case .network:
            tertiaryNetworkDetail
        case .sensors:
            tertiarySensorsDetail
        case .power:
            tertiaryPowerDetail
        case .fanCurve:
            FanCurveEditor(
                fanControl: fanControl,
                fanReadings: fanControl.latestFanReadings
            )
        }
    }

    private var tertiaryProcessorDetail: some View {
        GeekProcessorActivityHoverDetail(
            points: history,
            duration: geekTelemetryChartDuration,
            userValue: "",
            systemValue: "",
            samplingInterval: store.menuBarRefreshInterval.seconds,
            isUpdating: geekTelemetryChartIsUpdating
        )
    }

    private var tertiaryMemoryDetail: some View {
        // Opened by route, not inline: no memory-metric request is active,
        // so the picker shows and changes the page's range. The points and
        // their window come from that same range.
        let memoryHistory = routedMemoryDisplayedHistory
        return GeekMemoryHistoryHoverDetail(
            points: memoryHistory.points,
            duration: memoryHistory.range.duration,
            currentValue: memoryRingUsedPercentText,
            pressure: memoryPressureDisplayText,
            snapshot: memorySnapshot,
            isUpdating: memoryHistory.isUpdating
        )
    }

    private var tertiaryDiskDetail: some View {
        GeekDiskIOHoverDetail(
            points: nativeDiskIOHistory,
            counters: nativeDiskIOCounters,
            duration: geekChartDuration
        )
    }

    private var tertiaryNetworkDetail: some View {
        GeekNetworkTertiaryView(
            snapshot: networkInterfaceSnapshot,
            topology: networkTopologySnapshot,
            refresh: refreshPanelData,
            contentPadding: 0
        )
    }

    private var tertiarySensorsDetail: some View {
        // Prepared with the window, off the main thread (P2-1): this page
        // used to walk the whole window on every redraw.
        let summary = historySummary
        let temperatureSeries = tertiaryTemperatureSeries(summary)
        let hasGPUTemperatureHistory = temperatureSeries.contains {
            $0.channel == .gpuTemperature
        }
        let hasChipTemperature = metricAvailable(.chipTemperature)
            || temperatureSeries.contains { $0.channel == .chipTemperature }
        // The fan rings' color exit, also under a chart theme.
        let fanTint = panelMetricColors.sensorGraph(chartAccent: panelChartAccentColor)
        let fanSeries = [
            MenuBarTelemetrySeries(
                id: "fan-tertiary",
                title: L10n.text("实际转速", "Actual RPM"),
                channel: .fanRPM,
                color: fanTint
            ),
        ] + (summary.hasFanTarget ? [
            MenuBarTelemetrySeries(
                id: "fan-target-tertiary",
                title: L10n.text("目标转速", "Target RPM"),
                channel: .fanTargetRPM,
                color: AppDesignTokens.Palette.information,
                dash: [4, 3]
            ),
        ] : [])

        return VStack(spacing: MiniWindowStyleTokens.cardSpacing) {
            if hasChipTemperature || hasGPUTemperatureHistory {
                AdvancedPanelCard(
                    title: hasChipTemperature && hasGPUTemperatureHistory
                        ? L10n.text("芯片与 GPU 温度 · 最近 \(geekTelemetryChartRangeTitle)", "Chip & GPU Temperature · Last \(geekTelemetryChartRangeTitle)")
                        : hasGPUTemperatureHistory
                            ? L10n.text("GPU 温度 · 最近 \(geekTelemetryChartRangeTitle)", "GPU Temperature · Last \(geekTelemetryChartRangeTitle)")
                            : L10n.text("芯片温度 · 最近 \(geekTelemetryChartRangeTitle)", "Chip Temperature · Last \(geekTelemetryChartRangeTitle)")
                ) {
                    GeekPrecisionLineChart(
                        points: history,
                        series: temperatureSeries,
                        // D133: iStat's temperature scale, 0–100° and
                        // rounded up to 10° above it (was 20...110).
                        valueRange: GeekSensorMetricHoverDetail.displayedValueRange(
                            0...100, unit: .temperature, peak: summary.temperaturePeak),
                        unit: .temperature,
                        accessibilityLabel: hasChipTemperature && hasGPUTemperatureHistory
                            ? L10n.text("可悬停的最近 \(geekTelemetryChartRangeTitle) 芯片与 GPU 温度", "Hoverable chip and GPU temperatures over the last \(geekTelemetryChartRangeTitle)")
                            : hasGPUTemperatureHistory
                                ? L10n.text("可悬停的最近 \(geekTelemetryChartRangeTitle) GPU 温度", "Hoverable GPU temperature over the last \(geekTelemetryChartRangeTitle)")
                                : L10n.text("可悬停的最近 \(geekTelemetryChartRangeTitle) 芯片温度", "Hoverable chip temperature over the last \(geekTelemetryChartRangeTitle)"),
                        duration: geekTelemetryChartDuration,
                        showsTimelineLabels: false,
                        showsTooltip: true,
                        horizontalInset: 8,
                        showsSamplingDetails: false,
                        // D130: iStat's history buckets.
                        bucketing: .history
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)

                    if hasGPUTemperatureHistory,
                       let statistics = summary.gpuTemperatureStatistics {
                        AdvancedValueRow(
                            title: L10n.text("GPU 最低 / 平均 / 最高", "GPU Minimum / Average / Maximum"),
                            value: [statistics.minimum, statistics.average, statistics.maximum]
                                .map { IStatNumberFormat.temperature($0) }.joined(separator: " / "),
                            tint: resolvedGPUTint
                        )
                    }
                }
            }

            if metricAvailable(.fanSpeed) {
                AdvancedPanelCard(
                    title: L10n.text("风扇转速 · 最近 \(geekTelemetryChartRangeTitle)", "Fan Speed · Last \(geekTelemetryChartRangeTitle)")
                ) {
                    GeekPrecisionLineChart(
                        points: history,
                        series: fanSeries,
                        valueRange: 0...summary.fanTrendMaximum,
                        unit: .fanRPM,
                        accessibilityLabel: L10n.text("可悬停的最近 \(geekTelemetryChartRangeTitle) 风扇转速", "Hoverable fan speed over the last \(geekTelemetryChartRangeTitle)"),
                        duration: geekTelemetryChartDuration,
                        showsTimelineLabels: false,
                        showsTooltip: true,
                        horizontalInset: 8,
                        showsSamplingDetails: false,
                        // D130: iStat's history buckets.
                        bucketing: .history
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)
                    ForEach(fanTelemetryRows) { row in
                        AdvancedValueRow(title: row.title, value: row.value, tint: fanTint)
                    }
                }
            }

            if let gpuTemperature = geekGPUTemperature,
               !hasGPUTemperatureHistory {
                AdvancedPanelCard(
                    title: L10n.text("GPU 温度", "GPU Temperature")
                ) {
                    AdvancedValueRow(
                        title: L10n.text("当前", "Current"),
                        value: IStatNumberFormat.temperature(gpuTemperature),
                        tint: resolvedThermalTint
                    )
                }
            }

            if !metricAvailable(.chipTemperature),
               geekGPUTemperature == nil,
               temperatureSeries.isEmpty,
               !metricAvailable(.fanSpeed) {
                AdvancedUnavailableRow(title: L10n.text("macOS 未向此硬件公开温度或风扇读数", "macOS does not expose temperature or fan readings for this hardware"))
            }

        }
    }

    private func tertiaryTemperatureSeries(_ summary: MenuBarTelemetryWindowSummary) -> [MenuBarTelemetrySeries] {
        [
            MenuBarTelemetrySeries(
                id: "chip-temperature-tertiary",
                title: L10n.text("芯片温度", "Chip Temperature"),
                channel: .chipTemperature,
                color: temperatureTint
            ),
            MenuBarTelemetrySeries(
                id: "gpu-temperature-tertiary",
                title: L10n.text("GPU 温度", "GPU Temperature"),
                channel: .gpuTemperature,
                color: resolvedGPUTint
            )
        ].filter { summary.renderableTemperatureChannels.contains($0.channel) }
    }

    private var tertiaryPowerDetail: some View {
        VStack(spacing: MiniWindowStyleTokens.cardSpacing) {
            AdvancedPanelCard(
                title: L10n.text("当前电气读数", "Current Electrical Readings")
            ) {
                if let electrical = batteryElectricalSnapshot {
                    if batterySnapshot?.powerSource != .batteryPower {
                        if let adapterName = electrical.adapterName {
                            AdvancedValueRow(title: L10n.text("电源适配器", "Power Adapter"), value: adapterName, tint: AppDesignTokens.Palette.success)
                        }
                        // D57: the measured input (SMC PDTR/VD0R/ID0R) when read;
                        // the adapter's negotiated rating is labelled as such.
                        let input = powerTelemetry?.smc
                        if let watts = input?.inputPowerWatts.value {
                            AdvancedValueRow(title: L10n.text("输入功率", "Input Power"), value: HardwareReadingText.watts(watts), tint: AppDesignTokens.Palette.success)
                        }
                        if let volts = input?.inputVoltageVolts.value {
                            AdvancedValueRow(title: L10n.text("输入电压", "Input Voltage"), value: HardwareReadingText.volts(volts), tint: AppDesignTokens.Palette.information)
                        }
                        if let amps = input?.inputCurrentAmps.value {
                            AdvancedValueRow(title: L10n.text("输入电流", "Input Current"), value: HardwareReadingText.amps(amps), tint: AppDesignTokens.Palette.warning)
                        }
                        if let adapterPower = electrical.adapterPowerWatts {
                            AdvancedValueRow(title: L10n.text("协商功率", "Negotiated Power"), value: IStatNumberFormat.power(adapterPower), tint: AppDesignTokens.Palette.success)
                        }
                        if input?.inputPowerWatts.value == nil {
                            if let adapterVoltage = electrical.adapterVoltageVolts {
                                AdvancedValueRow(title: L10n.text("协商电压", "Negotiated Voltage"), value: IStatNumberFormat.voltage(adapterVoltage), tint: AppDesignTokens.Palette.information)
                            }
                            if let adapterAmperage = electrical.adapterAmperageAmps {
                                AdvancedValueRow(title: L10n.text("协商电流", "Negotiated Current"), value: IStatNumberFormat.current(adapterAmperage), tint: AppDesignTokens.Palette.warning)
                            }
                        }
                    }
                    if hasInternalBattery {
                        if let voltage = electrical.voltageVolts {
                            AdvancedValueRow(title: L10n.text("电池电压", "Battery Voltage"), value: IStatNumberFormat.voltage(voltage), tint: AppDesignTokens.Palette.information)
                        }
                        if let current = electrical.amperageAmps {
                            AdvancedValueRow(title: L10n.text("电池电流", "Battery Current"), value: HardwareReadingText.signed(current, decimals: 3, unit: "A"), tint: batteryTint)
                        }
                        if let power = electrical.powerWatts {
                            AdvancedValueRow(title: L10n.text("电池功率", "Battery Power"), value: HardwareReadingText.signedWatts(power), tint: AppDesignTokens.Palette.warning)
                        }
                        if let temperature = electrical.temperatureCelsius {
                            AdvancedValueRow(title: L10n.text("电池温度", "Battery Temperature"), value: IStatNumberFormat.temperature(temperature), tint: temperature >= 40 ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.success)
                        }
                    }
                } else {
                    AdvancedUnavailableRow(title: L10n.text("此 Mac 未公开电源电气读数", "This Mac does not expose power electrical readings"))
                }
            }

            if hasInternalBattery {
                AdvancedPanelCard(
                    title: L10n.text("电池功率 · 最近 \(geekChartRangeTitle)", "Battery Power · Last \(geekChartRangeTitle)")
                ) {
                    GeekPowerHistoryChart(
                        points: powerHistory,
                        metric: .batteryPower,
                        duration: geekChartDuration,
                        tint: resolvedEnergyTint,
                        accessibilityLabel: L10n.text("最近 \(geekChartRangeTitle) 电池功率历史", "Battery-power history over the last \(geekChartRangeTitle)"),
                        showsTimelineLabels: false,
                        showsTooltip: true
                    )
                    .frame(height: 110)
                }

                if let batterySnapshot, hasUsableBatteryData(batterySnapshot) {
                    AdvancedPanelCard(
                        title: L10n.text("电池会话状态", "Battery Session State")
                    ) {
                        AdvancedValueRow(title: L10n.text("供电来源", "Power Source"), value: batteryPowerSourceTitle, tint: batteryTint)
                        if let charge = batterySnapshot.chargePercent {
                            AdvancedValueRow(title: L10n.text("电量", "Charge"), value: "\(charge)%", tint: batteryTint)
                        }
                        if let estimate = batteryRuntimeEstimate {
                            AdvancedValueRow(title: L10n.text("耗电预计可用", "Power-based Runtime"), value: durationMinutesText(estimate.minutes), tint: batteryTint)
                            AdvancedValueRow(title: L10n.text("近期耗电", "Recent Draw"), value: IStatNumberFormat.power(estimate.powerWatts), tint: resolvedEnergyTint)
                        }
                        if let remaining = batterySnapshot.remainingTimeMinutes {
                            AdvancedValueRow(
                                title: batterySnapshot.isCharging == true
                                    ? L10n.text("预计充满", "Full Charge In")
                                    : L10n.text("macOS 预计可用", "macOS Runtime"),
                                value: durationMinutesText(remaining),
                                tint: batteryTint
                            )
                        }
                        if let optimized = batterySnapshot.isOptimizedChargingEngaged {
                            AdvancedValueRow(
                                title: L10n.text("优化充电", "Optimized Charging"),
                                value: optimized ? L10n.text("已启用", "Engaged") : L10n.text("未启用", "Not Engaged"),
                                tint: optimized ? AppDesignTokens.Palette.success : .secondary
                            )
                        }
                    }
                }


            }


        }
    }
}

private struct TertiaryMultilineValueRow: View {
    let title: String
    let values: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AdvancedPanelTypography.body)
                .foregroundStyle(tint)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(AdvancedPanelTypography.compactValue)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
