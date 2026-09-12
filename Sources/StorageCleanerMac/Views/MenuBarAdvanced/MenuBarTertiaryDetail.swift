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

    func tertiaryDetailButton(
        _ detail: MenuBarTertiaryDetail,
        compact: Bool = false
    ) -> some View {
        Button {
            guard panelSettingsState.tertiaryPresentationMode == .column else { return }
            presentTertiaryDetail(detail, pinned: true)
        } label: {
            if compact {
                Image(systemName: AppSymbols.Action.info)
                    .frame(width: 28, height: 28)
            } else {
                Label(L10n.text("查看三级详情", "More Details"), systemImage: AppSymbols.Action.info)
            }
        }
        .controlSize(compact ? .mini : .small)
        .disabled(panelSettingsState.tertiaryPresentationMode == .unavailable)
        .help(
            panelSettingsState.tertiaryPresentationMode == .unavailable
                ? L10n.text("当前屏幕空间不足，无法并排显示三级详情", "Not enough screen space for a third column")
                : L10n.text("打开只读的模块深层信息", "Open read-only deep module details")
        )
        .accessibilityLabel(L10n.text("查看三级详情", "More Details"))
        .onContinuousHover { phase in
            switch phase {
            case .active:
                tertiaryButtonHoverChanged(detail, hovering: true)
            case .ended:
                tertiaryButtonHoverChanged(detail, hovering: false)
            }
        }
    }

    private func tertiaryDetailSurface(
        _ detail: MenuBarTertiaryDetail
    ) -> some View {
        tertiaryDetailChrome(detail: detail, density: presentation) {
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
              hoveredTertiaryButton != detail,
              !isTertiaryDetailSurfaceHovered else { return }
        cancelTertiaryHoverIntent()
        tertiaryHoverIntent = panelCoordinator.scheduleHoverDismissal(
            condition: {
                !geekPanelHoverActivityState.keepsPanelExpanded
                    && hoveredTertiaryButton != detail
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

    private func tertiaryButtonHoverChanged(
        _ detail: MenuBarTertiaryDetail,
        hovering: Bool
    ) {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isCapturingMenuBarPanelSnapshots else { return }
#endif
        let nextButton = hovering ? detail : nil
        guard hoveredTertiaryButton != nextButton else { return }
        hoveredTertiaryButton = nextButton
        cancelTertiaryHoverIntent()

        guard hovering else {
            panelCoordinator.tertiaryHoverExited()
            if activeTertiaryDetail == detail {
                scheduleTertiaryDetailDismissal(detail)
            }
            return
        }
        guard panelSettingsState.tertiaryPresentationMode == .column else { return }
        tertiaryHoverIntent = panelCoordinator.scheduleTertiaryPreview(
            identifier: detail.rawValue,
            condition: {
                hoveredTertiaryButton == detail
                    && panelSettingsState.tertiaryPresentationMode == .column
            },
            action: {
                presentTertiaryDetail(detail, pinned: false)
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

    private func presentTertiaryDetail(
        _ detail: MenuBarTertiaryDetail,
        pinned: Bool
    ) {
        guard panelCoordinator.presentHistory(
            .builtIn(detail.rawValue),
            pinned: pinned
        ) else { return }
        activeInlineTertiaryRequest = nil
        isTertiaryDetailSurfaceHovered = false
        activeTertiaryDetail = detail
    }

    func presentFanCurveEditor() {
        guard panelSettingsState.tertiaryPresentationMode == .column else { return }
        presentTertiaryDetail(.fanCurve, pinned: true)
    }

    private func tertiaryRequestSurface(
        _ request: GeekInlineTertiaryRequest
    ) -> some View {
        tertiaryDetailChrome(
            requestID: request.id,
            density: presentation,
            contentPadding: 0
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
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
        .scrollIndicators(.hidden)
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
        VStack(spacing: 6) {
            AdvancedPanelCard(
                title: L10n.text("处理器活动 · 最近 \(geekChartRangeTitle)", "Processor Activity · Last \(geekChartRangeTitle)"),
                systemImage: AppSymbols.Panel.activity,
                tint: processorTint
            ) {
                GeekPrecisionLineChart(
                    points: history,
                    series: Array(processorChartSeries.prefix(2)),
                    valueRange: 0...100,
                    unit: .percent,
                    accessibilityLabel: L10n.text("可悬停的最近 \(geekChartRangeTitle) 处理器用户与系统活动", "Hoverable processor user and system activity over the last \(geekChartRangeTitle)"),
                    style: .stackedBars,
                    duration: geekChartDuration,
                    showsTimelineLabels: false,
                    showsTooltip: true
                )
                .frame(height: PanelLayoutMetrics.primaryChartHeight)

                AdvancedValueRow(
                    title: L10n.text("有效样本", "Valid Samples"),
                    value: "\(history.filter { $0.cpuUser?.isFinite == true || $0.cpuSystem?.isFinite == true }.count) / \(history.count)",
                    tint: .secondary
                )
                if let first = history.first?.date, let last = history.last?.date {
                    AdvancedValueRow(
                        title: L10n.text("采样范围", "Sample Range"),
                        value: "\(timestampText(first)) – \(timestampText(last))",
                        tint: .secondary
                    )
                }
                if let statistics = GeekSeriesStatistics(values: history.compactMap(\.cpuTotal)) {
                    AdvancedValueRow(
                        title: L10n.text("总占用 平均 / 峰值", "Total Average / Peak"),
                        value: String(format: "%.1f%% / %.1f%%", statistics.average, statistics.maximum),
                        tint: processorTint
                    )
                }
            }

            if let telemetry = processorTelemetry {
                AdvancedPanelCard(
                    title: L10n.text("性能层级拓扑", "Performance-Level Topology"),
                    systemImage: AppSymbols.Monitor.processor,
                    tint: processorTint
                ) {
                    AdvancedValueRow(title: L10n.text("处理器", "Processor"), value: telemetry.processorModel, tint: processorTint)
                    AdvancedValueRow(
                        title: L10n.text("性能层级", "Performance Levels"),
                        value: "\(telemetry.performanceLevels.count)",
                        tint: .secondary
                    )
                    AdvancedValueRow(
                        title: L10n.text("活动核心簇", "Active Clusters"),
                        value: "\(telemetry.clusters.count)",
                        tint: .secondary
                    )
                    ForEach(telemetry.performanceLevels, id: \.index) { level in
                        let l2Text = level.coresPerL2.map {
                            L10n.text("每组 L2 \($0) 核", "\($0) cores per L2")
                        } ?? L10n.text("L2 分组未公开", "L2 grouping unavailable")
                        TertiaryMultilineValueRow(
                            title: level.name,
                            values: [L10n.text("\(level.coreCount) 核 · \(l2Text)", "\(level.coreCount) cores · \(l2Text)")],
                            tint: processorTint
                        )
                    }
                }
            }

            if let measurement = store.energyImpactSnapshot, !geekEnergyApps.isEmpty {
                AdvancedPanelCard(
                    title: L10n.text("最近一次按需应用测量", "Latest On-Demand App Measurement"),
                    systemImage: AppSymbols.Panel.powerLimit,
                    tint: AppDesignTokens.Palette.warning
                ) {
                    AdvancedValueRow(title: L10n.text("测量时间", "Measured At"), value: timestampText(measurement.generatedAt), tint: .secondary)
                    ForEach(geekEnergyApps.prefix(5)) { app in
                        AdvancedValueRow(
                            title: app.name,
                            value: "CPU \(app.cpuPercentText) · \(app.currentPowerWattsText) · \(app.measurementTitle)",
                            tint: AppDesignTokens.Palette.warning
                        )
                    }
                    Text(L10n.text("这是最近一次按需测量，不是实时进程排行。", "This is the latest on-demand measurement, not a live process ranking."))
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tertiaryMemoryDetail: some View {
        VStack(spacing: 6) {
            AdvancedPanelCard(
                title: L10n.text("内存与压力 · 最近 \(geekChartRangeTitle)", "Memory & Pressure · Last \(geekChartRangeTitle)"),
                systemImage: AppSymbols.Panel.activity,
                tint: memoryTint
            ) {
                GeekPrecisionLineChart(
                    points: memoryHistory,
                    series: [
                        MenuBarTelemetrySeries(
                            id: "memory-tertiary",
                            title: L10n.text("内存占用", "Memory Usage"),
                            channel: .memory,
                            color: memoryTint
                        ),
                        MenuBarTelemetrySeries(
                            id: "memory-pressure-tertiary",
                            title: L10n.text("压力趋势估算", "Pressure Trend Estimate"),
                            channel: .memoryPressure,
                            color: AppDesignTokens.Palette.caution
                        )
                    ],
                    valueRange: 0...100,
                    unit: .percent,
                    accessibilityLabel: L10n.text("可悬停的最近 \(geekChartRangeTitle) 内存占用与压力趋势估算", "Hoverable memory usage and pressure trend estimate over the last \(geekChartRangeTitle)"),
                    duration: geekChartDuration,
                    showsTimelineLabels: false,
                    showsTooltip: true
                )
                .frame(height: PanelLayoutMetrics.primaryChartHeight)

                AdvancedValueRow(
                    title: L10n.text("当前内存压力", "Current Memory Pressure"),
                    value: "\(memoryPressureDisplayText) · \(memoryPressureHeadroomText)",
                    tint: memoryTint
                )

                if let statistics = GeekSeriesStatistics(values: memoryHistory.compactMap(\.memory)) {
                    AdvancedValueRow(
                        title: L10n.text("占用平均 / 峰值", "Usage Average / Peak"),
                        value: String(format: "%.1f%% / %.1f%%", statistics.average, statistics.maximum),
                        tint: memoryTint
                    )
                }
                if let statistics = GeekSeriesStatistics(values: memoryHistory.compactMap(\.memoryPressure)) {
                    AdvancedValueRow(
                        title: L10n.text("趋势估算平均 / 峰值", "Trend Estimate Average / Peak"),
                        value: String(format: "%.1f%% / %.1f%%", statistics.average, statistics.maximum),
                        tint: AppDesignTokens.Palette.caution
                    )
                }
            }

            AdvancedPanelCard(
                title: L10n.text("压缩内存与交换内存 · 最近 \(geekChartRangeTitle)", "Compressed & Swap Memory · Last \(geekChartRangeTitle)"),
                systemImage: AppSymbols.Monitor.memory,
                tint: AppDesignTokens.Palette.storage
            ) {
                GeekPrecisionLineChart(
                    points: memoryHistory,
                    series: [
                        MenuBarTelemetrySeries(
                            id: "compressed-memory-tertiary",
                            title: L10n.text("压缩内存", "Compressed"),
                            channel: .compressedMemoryBytes,
                            color: AppDesignTokens.Palette.storage
                        ),
                        MenuBarTelemetrySeries(
                            id: "swap-memory-tertiary",
                            title: L10n.text("交换内存", "Swap Memory"),
                            channel: .swapUsedBytes,
                            color: AppDesignTokens.Palette.diagnostic
                        )
                    ],
                    valueRange: 0...memoryByteTrendMaximum,
                    unit: .bytes,
                    accessibilityLabel: L10n.text("可悬停的最近 \(geekChartRangeTitle) 压缩内存与交换内存", "Hoverable compressed and swap memory over the last \(geekChartRangeTitle)"),
                    duration: geekChartDuration,
                    showsTimelineLabels: false,
                    showsTooltip: true
                )
                .frame(height: PanelLayoutMetrics.primaryChartHeight)
            }

            if let snapshot = memorySnapshot {
                AdvancedPanelCard(
                    title: L10n.text("原始 VM 计数", "Raw VM Counters"),
                    systemImage: AppSymbols.Monitor.memory,
                    tint: memoryTint
                ) {
                    Text(L10n.text("以下计数可能互相重叠，不可直接相加。", "These counters may overlap and must not be added together."))
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                    AdvancedValueRow(title: L10n.text("读取时间", "Read At"), value: timestampText(snapshot.generatedAt), tint: .secondary)
                    AdvancedValueRow(
                        title: L10n.text("物理内存", "Physical Memory"),
                        value: snapshot.measurements.physicalBytes.value.map {
                            ByteFormat.string(Int64(clamping: $0))
                        } ?? "—",
                        tint: memoryTint
                    )
                    AdvancedValueRow(title: L10n.text("压力状态", "Pressure"), value: snapshot.pressureSummary, tint: memoryTint)
                    AdvancedValueRow(title: L10n.text("文件映射", "File Backed"), value: ByteFormat.string(snapshot.fileBackedBytes), tint: AppDesignTokens.Palette.tertiary)
                    AdvancedValueRow(title: L10n.text("非活动", "Inactive"), value: ByteFormat.string(snapshot.inactiveBytes), tint: AppDesignTokens.Palette.secondary)
                    AdvancedValueRow(title: L10n.text("可清除（估算）", "Purgeable (Est.)"), value: ByteFormat.string(snapshot.purgeableBytes), tint: AppDesignTokens.Palette.success)
                    AdvancedValueRow(title: L10n.text("推测内存", "Speculative"), value: ByteFormat.string(snapshot.speculativeBytes), tint: AppDesignTokens.Palette.freshness)
                    Divider()
                    AdvancedValueRow(
                        title: L10n.text("交换内存", "Swap Memory"),
                        value: snapshot.measurements.swapUsedBytes.value.map {
                            ByteFormat.string(Int64(clamping: $0))
                        } ?? "—",
                        tint: AppDesignTokens.Palette.diagnostic
                    )
                    AdvancedValueRow(
                        title: L10n.text("缓存（属于可用内存）", "Cache (available memory)"),
                        value: snapshot.measurements.cachedBytes.value.map {
                            ByteFormat.string(Int64(clamping: $0))
                        } ?? "—",
                        tint: AppDesignTokens.Palette.information
                    )
                }
            }
        }
    }

    private var memoryByteTrendMaximum: Double {
        MenuBarChartGeometry.niceCeiling(
            for: memoryHistory.flatMap { point in
                [
                    point.compressedMemoryBytes.map { Double($0) },
                    point.swapUsedBytes.map { Double($0) }
                ].compactMap { $0 }
            }
        )
    }

    private var tertiaryDiskDetail: some View {
        VStack(spacing: 6) {
            AdvancedPanelCard(
                title: L10n.text("原生磁盘 I/O · 最近 \(geekChartRangeTitle)", "Native Disk I/O · Last \(geekChartRangeTitle)"),
                systemImage: AppSymbols.Panel.activity,
                tint: AppDesignTokens.Palette.information
            ) {
                GeekDiskIOChart(
                    points: nativeDiskIOHistory,
                    accessibilityLabel: L10n.text("可悬停的最近 \(geekChartRangeTitle) 原生磁盘读写", "Hoverable native disk reads and writes over the last \(geekChartRangeTitle)"),
                    duration: geekChartDuration,
                    showsTimelineLabels: false,
                    showsTooltip: true
                )
                .frame(height: PanelLayoutMetrics.primaryChartHeight)

                AdvancedValueRow(title: L10n.text("窗口样本", "Window Samples"), value: "\(nativeDiskIOHistory.count)", tint: .secondary)
                AdvancedValueRow(title: L10n.text("当前读取", "Read Now"), value: geekDiskReadRateText, tint: AppDesignTokens.Palette.sensitive)
                AdvancedValueRow(title: L10n.text("当前写入", "Write Now"), value: geekDiskWriteRateText, tint: AppDesignTokens.Palette.information)
            }

            AdvancedPanelCard(
                title: L10n.text("容量与累计计数", "Capacity & Cumulative Counters"),
                systemImage: AppSymbols.Monitor.storage,
                tint: storageTint
            ) {
                if let storage = storageSnapshot {
                    AdvancedValueRow(title: L10n.text("卷", "Volume"), value: volumeName, tint: storageTint)
                    AdvancedValueRow(title: L10n.text("总容量", "Total"), value: ByteFormat.storageString(storage.totalBytes), tint: AppDesignTokens.Palette.information)
                    AdvancedValueRow(title: L10n.text("已使用", "Used"), value: ByteFormat.storageString(storage.userUsedBytes), tint: storageTint)
                    AdvancedValueRow(title: L10n.text("系统可用", "System Available"), value: ByteFormat.storageString(storage.userAvailableBytes), tint: AppDesignTokens.Palette.success)
                    AdvancedValueRow(title: L10n.text("当前严格空闲", "Current Strict Free"), value: ByteFormat.storageString(storage.availableBytes), tint: AppDesignTokens.Palette.tertiary)
                    AdvancedValueRow(title: L10n.text("可回收估算", "Reclaimable Estimate"), value: ByteFormat.storageString(storage.reclaimableEstimateBytes), tint: resolvedSecondaryTint)
                    AdvancedValueRow(title: L10n.text("空间状态", "Space Status"), value: storagePressureTitle, tint: storageTint)
                }
                if let counters = nativeDiskIOCounters {
                    if storageSnapshot != nil { Divider() }
                    AdvancedValueRow(title: L10n.text("计数时间", "Counter Time"), value: timestampText(counters.date), tint: .secondary)
                    AdvancedValueRow(title: L10n.text("累计读取", "Data Read"), value: ByteFormat.string(Int64(clamping: counters.readBytes)), tint: AppDesignTokens.Palette.sensitive)
                    AdvancedValueRow(title: L10n.text("累计写入", "Data Written"), value: ByteFormat.string(Int64(clamping: counters.writtenBytes)), tint: AppDesignTokens.Palette.information)
                    AdvancedValueRow(title: L10n.text("读取操作", "Read Operations"), value: "\(counters.readOperations)", tint: AppDesignTokens.Palette.sensitive)
                    AdvancedValueRow(title: L10n.text("写入操作", "Write Operations"), value: "\(counters.writeOperations)", tint: AppDesignTokens.Palette.information)
                    AdvancedValueRow(title: L10n.text("原生驱动", "Native Drivers"), value: "\(counters.driverCount)", tint: .secondary)
                }
                if storageSnapshot == nil, nativeDiskIOCounters == nil {
                    AdvancedUnavailableRow(title: L10n.text("正在读取容量和原生 I/O 计数", "Reading capacity and native I/O counters"))
                }
            }
        }
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
        let temperatureSeries = tertiaryTemperatureSeries
        let hasGPUTemperatureHistory = temperatureSeries.contains {
            $0.channel == .gpuTemperature
        }
        let hasChipTemperature = metricAvailable(.chipTemperature)
            || temperatureSeries.contains { $0.channel == .chipTemperature }
        let fanSeries = [
            MenuBarTelemetrySeries(
                id: "fan-tertiary",
                title: L10n.text("实际转速", "Actual RPM"),
                channel: .fanRPM,
                color: AppDesignTokens.Palette.tertiary
            ),
        ] + (history.contains { $0.fanTargetRPM?.isFinite == true } ? [
            MenuBarTelemetrySeries(
                id: "fan-target-tertiary",
                title: L10n.text("目标转速", "Target RPM"),
                channel: .fanTargetRPM,
                color: AppDesignTokens.Palette.information,
                dash: [4, 3]
            ),
        ] : [])

        return VStack(spacing: 6) {
            if hasChipTemperature || hasGPUTemperatureHistory {
                AdvancedPanelCard(
                    title: hasChipTemperature && hasGPUTemperatureHistory
                        ? L10n.text("芯片与 GPU 温度 · 最近 \(geekChartRangeTitle)", "Chip & GPU Temperature · Last \(geekChartRangeTitle)")
                        : hasGPUTemperatureHistory
                            ? L10n.text("GPU 温度 · 最近 \(geekChartRangeTitle)", "GPU Temperature · Last \(geekChartRangeTitle)")
                            : L10n.text("芯片温度 · 最近 \(geekChartRangeTitle)", "Chip Temperature · Last \(geekChartRangeTitle)"),
                    systemImage: AppSymbols.Panel.temperature,
                    tint: hasChipTemperature ? temperatureTint : resolvedGPUTint
                ) {
                    GeekPrecisionLineChart(
                        points: history,
                        series: temperatureSeries,
                        valueRange: 20...110,
                        unit: .temperature,
                        accessibilityLabel: hasChipTemperature && hasGPUTemperatureHistory
                            ? L10n.text("可悬停的最近 \(geekChartRangeTitle) 芯片与 GPU 温度", "Hoverable chip and GPU temperatures over the last \(geekChartRangeTitle)")
                            : hasGPUTemperatureHistory
                                ? L10n.text("可悬停的最近 \(geekChartRangeTitle) GPU 温度", "Hoverable GPU temperature over the last \(geekChartRangeTitle)")
                                : L10n.text("可悬停的最近 \(geekChartRangeTitle) 芯片温度", "Hoverable chip temperature over the last \(geekChartRangeTitle)"),
                        duration: geekChartDuration,
                        showsTimelineLabels: false,
                        showsTooltip: true,
                        horizontalInset: 8
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)

                    if let statistics = GeekSeriesStatistics(values: history.compactMap(\.chipTemperature)) {
                        AdvancedValueRow(
                            title: L10n.text("最低 / 平均 / 最高", "Minimum / Average / Maximum"),
                            value: String(format: "%.1f / %.1f / %.1f°C", statistics.minimum, statistics.average, statistics.maximum),
                            tint: temperatureTint
                        )
                    }
                    if hasGPUTemperatureHistory,
                       let statistics = GeekSeriesStatistics(values: history.compactMap(\.gpuTemperature)) {
                        AdvancedValueRow(
                            title: L10n.text("GPU 最低 / 平均 / 最高", "GPU Minimum / Average / Maximum"),
                            value: String(format: "%.1f / %.1f / %.1f°C", statistics.minimum, statistics.average, statistics.maximum),
                            tint: resolvedGPUTint
                        )
                    }
                }
            }

            if metricAvailable(.fanSpeed) {
                AdvancedPanelCard(
                    title: L10n.text("风扇转速 · 最近 \(geekChartRangeTitle)", "Fan Speed · Last \(geekChartRangeTitle)"),
                    systemImage: AppSymbols.Monitor.sensors,
                    tint: AppDesignTokens.Palette.tertiary
                ) {
                    GeekPrecisionLineChart(
                        points: history,
                        series: fanSeries,
                        valueRange: 0...fanTrendMaximum,
                        unit: .fanRPM,
                        accessibilityLabel: L10n.text("可悬停的最近 \(geekChartRangeTitle) 风扇转速", "Hoverable fan speed over the last \(geekChartRangeTitle)"),
                        duration: geekChartDuration,
                        showsTimelineLabels: false,
                        showsTooltip: true,
                        horizontalInset: 8
                    )
                    .frame(height: PanelLayoutMetrics.primaryChartHeight)
                    if let statistics = GeekSeriesStatistics(values: history.compactMap(\.fanRPM)) {
                        AdvancedValueRow(
                            title: L10n.text("最低 / 平均 / 最高", "Minimum / Average / Maximum"),
                            value: [statistics.minimum, statistics.average, statistics.maximum]
                                .map { SystemFanSpeedFormat.string(Int($0.rounded())) }
                                .joined(separator: " / "),
                            tint: AppDesignTokens.Palette.tertiary
                        )
                    }
                    ForEach(fanTelemetryRows) { row in
                        AdvancedValueRow(title: row.title, value: row.value, tint: AppDesignTokens.Palette.tertiary)
                    }
                }
            }

            if let gpuTemperature = geekGPUTemperature,
               !hasGPUTemperatureHistory {
                AdvancedPanelCard(
                    title: L10n.text("GPU 温度", "GPU Temperature"),
                    systemImage: AppSymbols.Panel.temperature,
                    tint: resolvedThermalTint
                ) {
                    AdvancedValueRow(
                        title: L10n.text("当前", "Current"),
                        value: String(format: "%.1f°C", gpuTemperature),
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

    private var tertiaryTemperatureSeries: [MenuBarTelemetrySeries] {
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
        ].filter { item in
            PanelChartSampling.hasRenderableTrend(
                history.map {
                    MenuBarChartSample(
                        date: $0.date,
                        value: item.channel.value(in: $0)
                    )
                }
            )
        }
    }

    private var tertiaryPowerDetail: some View {
        VStack(spacing: 6) {
            AdvancedPanelCard(
                title: L10n.text("当前电气读数", "Current Electrical Readings"),
                systemImage: AppSymbols.Monitor.power,
                tint: batteryTint
            ) {
                if let electrical = batteryElectricalSnapshot {
                    AdvancedValueRow(title: L10n.text("读取时间", "Read At"), value: timestampText(electrical.generatedAt), tint: .secondary)
                    if batterySnapshot?.powerSource != .batteryPower {
                        if let adapterName = electrical.adapterName {
                            AdvancedValueRow(title: L10n.text("电源适配器", "Power Adapter"), value: adapterName, tint: AppDesignTokens.Palette.success)
                        }
                        if let adapterPower = electrical.adapterPowerWatts {
                            AdvancedValueRow(title: L10n.text("输入功率", "Input Power"), value: String(format: "%.0f W", adapterPower), tint: AppDesignTokens.Palette.success)
                        }
                        if let adapterVoltage = electrical.adapterVoltageVolts {
                            AdvancedValueRow(title: L10n.text("输入电压", "Input Voltage"), value: String(format: "%.1f V", adapterVoltage), tint: AppDesignTokens.Palette.information)
                        }
                        if let adapterAmperage = electrical.adapterAmperageAmps {
                            AdvancedValueRow(title: L10n.text("输入电流", "Input Current"), value: String(format: "%.2f A", adapterAmperage), tint: AppDesignTokens.Palette.warning)
                        }
                    }
                    if hasInternalBattery {
                        if let voltage = electrical.voltageVolts {
                            AdvancedValueRow(title: L10n.text("电池电压", "Battery Voltage"), value: String(format: "%.3f V", voltage), tint: AppDesignTokens.Palette.information)
                        }
                        if let current = electrical.amperageAmps {
                            AdvancedValueRow(title: L10n.text("电池电流", "Battery Current"), value: String(format: "%+.3f A", current), tint: batteryTint)
                        }
                        if let power = electrical.powerWatts {
                            AdvancedValueRow(title: L10n.text("电池功率", "Battery Power"), value: String(format: "%+.2f W", power), tint: AppDesignTokens.Palette.warning)
                        }
                        if let temperature = electrical.temperatureCelsius {
                            AdvancedValueRow(title: L10n.text("电池温度", "Battery Temperature"), value: String(format: "%.1f°C", temperature), tint: temperature >= 40 ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.success)
                        }
                    }
                } else {
                    AdvancedUnavailableRow(title: L10n.text("此 Mac 未公开电源电气读数", "This Mac does not expose power electrical readings"))
                }
            }

            if hasInternalBattery {
                AdvancedPanelCard(
                    title: L10n.text("电池功率 · 最近 \(geekChartRangeTitle)", "Battery Power · Last \(geekChartRangeTitle)"),
                    systemImage: AppSymbols.Monitor.power,
                    tint: resolvedEnergyTint
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
                        title: L10n.text("电池会话状态", "Battery Session State"),
                        systemImage: batterySystemImage,
                        tint: batteryTint
                    ) {
                        if let refreshedAt = batteryRefreshedAt {
                            AdvancedValueRow(title: L10n.text("刷新时间", "Refreshed At"), value: timestampText(refreshedAt), tint: .secondary)
                        }
                        AdvancedValueRow(title: L10n.text("供电来源", "Power Source"), value: batteryPowerSourceTitle, tint: batteryTint)
                        if let charge = batterySnapshot.chargePercent {
                            AdvancedValueRow(title: L10n.text("电量", "Charge"), value: "\(charge)%", tint: batteryTint)
                        }
                        if let estimate = batteryRuntimeEstimate {
                            AdvancedValueRow(title: L10n.text("耗电预计可用", "Power-based Runtime"), value: durationMinutesText(estimate.minutes), tint: batteryTint)
                            AdvancedValueRow(title: L10n.text("近期耗电", "Recent Draw"), value: String(format: "%.1f W", estimate.powerWatts), tint: resolvedEnergyTint)
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

                Text(L10n.text("仅展示本面板实际采集的最近 \(geekChartRangeTitle) 电池功率；不使用 CPU 数据替代。", "Only battery power actually collected by this panel over the last \(geekChartRangeTitle) is shown; CPU data is never substituted."))
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AdvancedPanelCard(
                title: L10n.text("最近一次按需能耗测量", "Latest On-Demand Energy Measurement"),
                systemImage: AppSymbols.Panel.powerLimit,
                tint: AppDesignTokens.Palette.warning
            ) {
                if let energy = store.energyImpactSnapshot {
                    AdvancedValueRow(title: L10n.text("测量时间", "Measured At"), value: timestampText(energy.generatedAt), tint: .secondary)
                    AdvancedValueRow(title: L10n.text("当前应用功率", "Current App Power"), value: energy.currentPowerWattsText, tint: AppDesignTokens.Palette.warning)
                    AdvancedValueRow(title: L10n.text("测量来源", "Measurement Source"), value: energy.source, tint: .secondary)
                    AdvancedValueRow(title: L10n.text("样本时长", "Sample Duration"), value: energy.sampleDurationText, tint: AppDesignTokens.Palette.tertiary)
                    TertiaryMultilineValueRow(
                        title: L10n.text("覆盖范围", "Coverage"),
                        values: ["\(energy.energyCoveragePercentText) · \(energy.energyCoverageText)"],
                        tint: .secondary
                    )
                    AdvancedValueRow(title: L10n.text("估算能量", "Estimated Energy"), value: energy.estimatedTotalEnergyText, tint: AppDesignTokens.Palette.caution)
                    TertiaryMultilineValueRow(
                        title: L10n.text("校准说明", "Calibration"),
                        values: [energy.calibrationText],
                        tint: .secondary
                    )
                    AdvancedValueRow(title: L10n.text("活跃应用", "Active Apps"), value: "\(energy.activeAppCount)", tint: AppDesignTokens.Palette.warning)
                    AdvancedValueRow(title: L10n.text("累计 CPU 时间", "Cumulative CPU Time"), value: energy.cumulativeCPUText, tint: .secondary)
                    ForEach(Array(energy.apps.filter(\.isApplication).prefix(5))) { app in
                        AdvancedValueRow(
                            title: app.name,
                            value: "\(app.currentPowerWattsText) · \(app.measurementTitle)",
                            tint: AppDesignTokens.Palette.warning
                        )
                    }
                } else {
                    AdvancedUnavailableRow(title: L10n.text("尚未执行按需能耗测量", "No on-demand energy measurement yet"))
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
