import SwiftUI

struct GeekDetailContentMeasurement: Equatable {
    let section: PanelSection
    let density: PanelDensity
    let size: CGSize
}

private struct GeekDetailContentSizeKey: PreferenceKey {
    static let defaultValue: GeekDetailContentMeasurement? = nil

    static func reduce(
        value: inout GeekDetailContentMeasurement?,
        nextValue: () -> GeekDetailContentMeasurement?
    ) {
        if let next = nextValue() {
            value = next
        }
    }
}

enum GeekOnDemandSnapshotFreshnessState: Equatable {
    case notMeasured
    case current
    case stale
}

enum GeekOnDemandSnapshotFreshness {
    static let staleAfter: TimeInterval = 5 * 60

    static func state(
        generatedAt: Date?,
        now: Date = Date()
    ) -> GeekOnDemandSnapshotFreshnessState {
        guard let generatedAt else { return .notMeasured }
        return now.timeIntervalSince(generatedAt) >= staleAfter ? .stale : .current
    }

    static func statusText(
        generatedAt: Date?,
        now: Date = Date()
    ) -> String {
        guard let generatedAt else {
            return L10n.text("未测量", "Not Measured")
        }

        let timestamp = PanelTimestampFormat.display(generatedAt)
        switch state(generatedAt: generatedAt, now: now) {
        case .notMeasured:
            return L10n.text("未测量", "Not Measured")
        case .current:
            return L10n.text("更新 \(timestamp)", "Updated \(timestamp)")
        case .stale:
            return L10n.text("过期 \(timestamp)", "Stale \(timestamp)")
        }
    }
}

extension MenuBarAdvancedStatusView {
    @ViewBuilder
    var geekDetailPage: some View {
        if selectedSection == .overview {
            geekOverviewPage
        } else {
            geekSelectedDetailPage
        }
    }

    var geekOverviewPage: some View {
        geekCanvas
        .padding(GeekPanelLayout.contentPadding)
        .contextMenu { overviewContextMenu }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .popover(isPresented: Binding(
            get: { panelSettingsState.isGeekEditorPresented },
            set: { if !$0 { panelSettingsState.cancelGeekEditor() } }
        ), attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
            GeekDashboardEditor(state: panelSettingsState)
        }
        .task {
            guard !hasPrefetchedGeekDetails else { return }
            hasPrefetchedGeekDetails = true
            prefetchGeekDetailSnapshots()
        }
        .onAppear {
            synchronizeGeekOverviewPresentation()
        }
        .onChange(of: geekVisibleOverviewModules) {
            synchronizeGeekOverviewPresentation()
        }
    }

    private var showsOverviewPowerModule: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.hasInternalBattery
        }
#endif
        return !hasConfirmedNoInternalBattery
    }

    private var geekOverviewPreferredSize: CGSize {
        GeekPanelLayout.overviewSize(modules: geekVisibleOverviewModules)
    }

    private func synchronizeGeekOverviewPresentation() {
        let size = geekOverviewPreferredSize
        if overviewPanelSize != size {
            overviewPanelSize = size
        }
        if !showsOverviewPowerModule, selectedSection == .power {
            panelCoordinator.reset()
        }
        MenuBarStatusController.shared.setGeekPanelOverviewSize(size)
    }

    /// Prime the two existing on-demand snapshots while the pointer is still
    /// on the overview. This keeps CPU and memory process rows ready when the
    /// attached detail opens without introducing another sampler or timer.
    private func prefetchGeekDetailSnapshots() {
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        guard !store.isMenuBarRefreshPaused else { return }

        if processMemorySnapshot?.topProcesses.isEmpty != false,
           store.canRefreshMemory {
            store.refreshMemory(priority: .utility)
        }

        if showsExtendedGeekDetails, geekShouldRefreshOnDemandSnapshot {
            store.refreshEnergyImpact(priority: .utility)
        }
    }

    var geekSelectedDetailPage: some View {
        let measuredSection = selectedSection
        let measuredDensity = presentation
        return Group {
            switch selectedSection {
            case .overview:
                EmptyView()
            case .processor:
                geekProcessorPage
            case .memory:
                geekMemoryPage
            case .disk:
                geekDiskPage
            case .network:
                geekNetworkPage
            case .sensors:
                geekSensorsPage
            case .power:
                geekPowerPage
            case .cleanup:
                geekCleanupPage
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, GeekPanelLayout.contentPadding)
        .padding(.horizontal, GeekPanelLayout.contentPadding)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: GeekDetailContentSizeKey.self,
                    value: GeekDetailContentMeasurement(
                        section: measuredSection,
                        density: measuredDensity,
                        size: proxy.size
                    )
                )
            }
        }
        .coordinateSpace(name: GeekTertiarySourceCoordinateSpace.name)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(GeekDetailContentSizeKey.self) { measurement in
            Task { @MainActor in
                guard let measurement else { return }
                updateMeasuredDetailContentSize(
                    measurement.size,
                    for: measurement.section,
                    density: measurement.density
                )
            }
        }
    }

    var geekCanvas: some View {
        VStack(spacing: GeekPanelLayout.sectionSpacing) {
            ForEach(geekVisibleOverviewModules) { module in
                geekOverviewModule(module)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var geekVisibleOverviewModules: [GeekDashboardModule] {
        let modules = presentation.geekContentProfile?.overviewModules(
            configuredModules: panelSettingsState.geekDashboardConfiguration.modules
        ) ?? []
        return modules.filter { module in
            guard module.isAvailableInOverview else { return false }
            switch module {
            case .sensors:
                // Keep unavailable readings visible and the shell stable between samples.
                return true
            case .coreMetrics, .processorGraphics, .network, .disk:
                return true
            case .power:
                return showsOverviewPowerModule
            case .memoryBreakdown, .fans, .systemLoad, .cleanupSummary:
                return false
            }
        }
    }

    @ViewBuilder
    func geekOverviewModule(_ module: GeekDashboardModule) -> some View {
        switch module {
        case .coreMetrics:
            GeekOverviewModuleButton(destination: .memory, isSelected: selectedSection == .memory, preview: previewGeekSection, action: selectGeekSection) {
                geekMemoryPressureCard
            }
            .accessibilityValue("\(memoryRingUsedPercentText)、\(memoryUsageAmountText)、\(memoryPressureDisplayText)。\(memorySampleEvidenceText)")
        case .processorGraphics:
            GeekOverviewModuleButton(destination: .processor, isSelected: selectedSection == .processor, preview: previewGeekSection, action: selectGeekSection) {
                geekProcessorCard
            }
            .overlay(alignment: .topTrailing) {
                // A sibling control must not be nested inside the module's Button.
                TimeRangeSelector(
                    selectedRange: cpuChartRange,
                    availableRanges: GeekChartRange.allCases,
                    onChange: { panelSettingsState.setGeekChartRange($0, for: GeekChartRangeMetric.cpu) },
                    appearance: colorScheme,
                    isEnabled: true,
                    accessibilityLabel: L10n.text("CPU历史范围", "CPU history range")
                )
                .padding(.trailing, GeekVisualTokens.cardHorizontalPadding)
                .padding(.top, GeekVisualTokens.cardVerticalPadding)
            }
        case .network:
            GeekOverviewModuleButton(destination: .network, isSelected: selectedSection == .network, preview: previewGeekSection, action: selectGeekSection) {
                geekNetworkCard
            }
        case .disk:
            GeekOverviewModuleButton(destination: .disk, isSelected: selectedSection == .disk, preview: previewGeekSection, action: selectGeekSection) {
                geekDiskCard
            }
        case .sensors:
            geekSensorsCard
                .environment(
                    \.geekCombinedCardIsSelected,
                    selectedSection == .sensors
                        && panelCoordinator.hardwareDetailFocus == .monitoring
                )
        case .power:
            GeekOverviewModuleButton(destination: .power, isSelected: selectedSection == .power, preview: previewGeekSection, action: selectGeekSection) {
                geekPowerSummaryCard
            }
        case .memoryBreakdown, .fans, .systemLoad, .cleanupSummary:
            EmptyView()
        }
    }

    var geekProcessorCard: some View {
        GeekCombinedCard(height: GeekPanelLayout.overviewProcessorCardHeight) {
            VStack(spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AppSymbolIcon(
                        systemImage: AppSymbols.Monitor.processor,
                        role: .inline,
                        tint: processorTint,
                        isDecorative: true
                    )

                    Text("CPU")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(processorTint)

                    Text(percentText(cpuChartHistory.last?.cpuTotal))
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)

                    Spacer(minLength: 6)
                    // Reserve the independent time menu's hit area above the card.
                    Color.clear.frame(width: 88, height: 22)
                        .accessibilityHidden(true)
                }

                GeekPrecisionLineChart(
                    points: cpuChartHistory,
                    series: [
                        MenuBarTelemetrySeries(
                            id: "user",
                            title: L10n.text("用户", "User"),
                            channel: .cpuUser,
                            color: geekCPUUserBarColor
                        ),
                        MenuBarTelemetrySeries(
                            id: "system",
                            title: L10n.text("系统", "System"),
                            channel: .cpuSystem,
                            color: geekCPUSystemBarColor
                        )
                    ],
                    valueRange: 0...100,
                    unit: .percent,
                    accessibilityLabel: L10n.text(
                        "CPU 时间历史：用户与系统显示固定时段内按测量时长加权的平均；峰值可在悬停提示中查看。短缺口估算可在悬停提示中查看，长缺口未记录，量程0至100%，左旧右新",
                        "CPU time history: user and system use time-weighted interval means; hover for observed peaks. Hover for short-gap estimates; long gaps are unrecorded. Scale 0 to 100 percent, oldest on the left"
                    ),
                    style: .stackedBars,
                    duration: cpuChartRange.duration,
                    showsLegend: false,
                    showsTimelineLabels: false,
                    horizontalInset: 0,
                    cpuSamplingInterval: store.menuBarRefreshInterval.seconds
                )
                .frame(height: GeekPanelLayout.overviewProcessorChartHeight)

                HStack(spacing: 8) {
                    GeekCombinedLegendMetric(
                        title: L10n.text("用户", "User"),
                        value: percentText(geekCurrentCPUUserPercent),
                        color: geekCPUUserBarColor
                    )
                    GeekCombinedLegendMetric(
                        title: L10n.text("系统", "System"),
                        value: percentText(geekCurrentCPUSystemPercent),
                        color: geekCPUSystemBarColor
                    )
                    Spacer(minLength: 0)
                    Text("0–100%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help(L10n.text("固定利用率量程；悬停可查看估算信息与实测峰值", "Fixed utilization scale; hover for estimates and observed peaks"))
                }
            }
        }
    }

    private var geekCPUUserBarColor: Color {
        resolvedPrimaryTint
    }

    var geekCurrentCPUUserPercent: Double? {
        cpuChartHistory.last?.cpuUser
    }

    var geekCurrentCPUSystemPercent: Double? {
        cpuChartHistory.last?.cpuSystem
    }

    private var geekCPUSystemBarColor: Color {
        resolvedSecondaryTint
    }

    var geekProcessorFrequencyTextCompact: String? {
        processorTelemetry?.clusters
            .compactMap(\.frequencyMHz)
            .max()
            .map(processorFrequencyText)
    }

    var geekCompactTemperatureText: String {
        metricValue(.chipTemperature)
            .replacingOccurrences(of: " °C", with: "°C")
    }

    var geekCompactFrequencyText: String? {
        geekProcessorFrequencyTextCompact
    }

    var geekMemoryPressureCard: some View {
        GeekCombinedCard(height: GeekPanelLayout.overviewMemoryCardHeight) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Label(L10n.text("内存", "Memory"), systemImage: AppSymbols.Monitor.memory)
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: MemorySampleStatusPresentation.refreshInterval)) { timeline in
                        Text(memorySampleStatusText(at: timeline.date))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .help(memorySampleEvidenceText)
                            .accessibilityHint(memorySampleEvidenceText)
                    }
                }
                HStack(spacing: 8) {
                    GeekCombinedRing(
                        title: L10n.text("占用", "Used"),
                        value: memoryRingUsedPercentText,
                        progress: memoryRingUsedProgress,
                        tint: AppChartPalette.memory,
                        size: GeekVisualTokens.overviewMemoryGaugeSize,
                        segments: memoryRingSegments,
                        fixedValueFontSize: 19
                    )
                    VStack(spacing: 2) {
                        Text(L10n.text("已用 / 总量", "Used / Total"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(memoryUsedAmountText)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .lineLimit(1)
                        Text("/ " + memoryTotalAmountText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("已用内存 / 物理总量", "Used memory / physical total"))
                    .accessibilityValue(memoryUsageAmountText)
                    geekMemoryPressureRing(size: GeekVisualTokens.overviewMemoryGaugeSize)
                }
            }
            .help(memoryRingExplanation + L10n.text(
                " 占用弧长为已用/物理总量；压力为本应用评估的等级状态环，不代表压力百分比。完整历史见内存详情。",
                " Usage arc is used/physical total. Pressure is an app-assessed grade shown as a status ring, not a pressure percentage. Full history is in memory details."
            ) + " · " + (memorySnapshot.map { PanelTimestampFormat.display($0.generatedAt) } ?? "—"))
        }
    }

    var geekMemoryRingSegments: [GeekCombinedRingSegment] {
        memoryRingSegments
    }

    func geekMemoryPressureRing(size: CGFloat) -> some View {
        GeekCombinedRing(
            title: L10n.text("压力评估", "Pressure grade"),
            value: memoryPressureDisplayText,
            progress: nil,
            tint: memoryTint,
            size: size,
            fixedValueFontSize: size >= 90 ? 20 : 13,
            strokeWidth: GeekVisualTokens.gaugeStrokeWidth(size: size),
            isStatusOnly: memorySnapshot?.reportablePressureLevel != nil
        )
        .help(memoryPressureTitle + " · " + memoryPressureHeadroomText + L10n.text(
            "。根据系统压力余量、可用内存、压缩及交换评估等级；环不表示百分比。",
            ". Grade assessed from system pressure headroom, available memory, compression and swap; the ring is not a percentage."
        ))
    }

    var geekNetworkCard: some View {
        GeekCombinedCard(height: GeekPanelLayout.overviewNetworkCardHeight) {
            VStack(spacing: 2) {
                Label {
                        Text(L10n.text("网络", "Network")).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: AppSymbols.Monitor.network).foregroundStyle(resolvedDownloadTint)
                    }
                .font(.system(size: 12, weight: .medium))

                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    GeekLiveNetworkValue(
                        title: L10n.text("上传", "Upload"),
                        value: networkUpText,
                        tint: resolvedUploadTint
                    )
                    .frame(width: 62)

                    GeekPrecisionNetworkChart(
                        points: networkChartHistory,
                        accessibilityLabel: L10n.text(
                            "网络柱状图：每根柱代表一次采样，上方是上传，下方是下载，左旧右新",
                            "Network bars: each bar is one sample; upload is above and download is below, oldest on the left"
                        ),
                        duration: networkChartRange.duration,
                        showsLegend: false,
                        showsTimelineLabels: false,
                        horizontalInset: 0
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: GeekPanelLayout.overviewNetworkChartHeight)

                    GeekLiveNetworkValue(
                        title: L10n.text("下载", "Download"),
                        value: networkDownText,
                        tint: resolvedDownloadTint
                    )
                    .frame(width: 62)
                }
            }
        }
    }

    var geekDiskCard: some View {
        GeekCombinedCard(height: GeekPanelLayout.overviewDiskCardHeight) {
            if let storageSnapshot {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 6) {
                        AppSymbolIcon(
                            systemImage: AppSymbols.Monitor.storage,
                            role: .inline,
                            tint: AppDesignTokens.Palette.success,
                            isDecorative: true
                        )

                        Text(volumeName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if let health = geekPrimaryDiskHealthText {
                            HStack(spacing: 3) {
                                Circle().fill(geekPrimaryDiskHealthTint).frame(width: 5, height: 5)
                                Text(L10n.text("健康 \(health)", "Health \(health)"))
                            }
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .help(GeekDiskHealthTimestamp.detailText(GeekDiskHealthTimestamp.checkedAt(
                                snapshot: computerHealthStore.snapshot?.disk,
                                fallbackRemainingLifePercent: healthSummary?.diskRemainingLifePercent
                            )))
                        } else {
                            Text(L10n.text("已用 \(storagePercentText)", "\(storagePercentText) used"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Text(L10n.text(
                        "\(ByteFormat.storageString(storageSnapshot.userAvailableBytes)) 可用",
                        "\(ByteFormat.storageString(storageSnapshot.userAvailableBytes)) free"
                    ))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.22))
                            Capsule()
                                .fill(AppDesignTokens.Palette.success)
                                .frame(width: proxy.size.width * min(
                                    1,
                                    max(0, 1 - storageSnapshot.userUsedRatio)
                                ))
                        }
                    }
                    .frame(height: 6)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    Text(L10n.text("总容量 \(ByteFormat.storageString(storageSnapshot.totalBytes))", "Total \(ByteFormat.storageString(storageSnapshot.totalBytes))"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)

                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(L10n.text(
                    "已用 \(storagePercentText) · \(ByteFormat.storageString(storageSnapshot.userAvailableBytes)) 可用",
                    "\(storagePercentText) used · \(ByteFormat.storageString(storageSnapshot.userAvailableBytes)) available"
                ))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L10n.text("正在采样", "Sampling"))
            }
        }
    }

    var geekSensorsCard: some View {
        GeekOverviewHoverRegion(destination: .sensors, isSelected: selectedSection == .sensors, preview: previewGeekSection) {
            GeekCombinedCard(height: GeekPanelLayout.overviewSensorsCardHeight) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.text("传感器", "Sensors"), systemImage: AppSymbols.Monitor.sensors)
                        .font(.system(size: 13, weight: .medium))
                    HStack(spacing: 16) {
                        Button { selectGeekHardwareDetail(.monitoring) } label: {
                            GeekCombinedRing(
                                title: "CPU",
                                value: geekCompactTemperatureText,
                                detail: geekCompactFrequencyText,
                                progress: temperatureProgress,
                                tint: temperatureTint,
                                size: 72,
                                labelPlacement: .aboveValue,
                                strokeWidth: 4
                            )
                        }
                        .help(L10n.text("芯片汇总温度；圆环量程0–100°C，不是使用率。点击查看温度和频率详情。", "Aggregated chip temperature; ring scale 0–100°C, not utilization. Open temperature and frequency details."))
                        Button { selectGeekHardwareDetail(.monitoring) } label: {
                            GeekCombinedRing(
                                title: "GPU",
                                value: geekOverviewGPUTemperature.map { String(format: "%.0f°C", $0) } ?? metricValue(.gpuUsage),
                                detail: geekOverviewGPUTemperature != nil ? L10n.text("温度", "Temperature") : L10n.text("占用", "Utilization"),
                                progress: geekOverviewGPUTemperature.map { $0 / 100 } ?? metricPercent(.gpuUsage),
                                tint: resolvedGPUTint,
                                size: 72,
                                labelPlacement: .aboveValue,
                                strokeWidth: 4
                            )
                        }
                        .help(L10n.text("有温度时量程0–100°C；缺少温度时明确显示GPU占用，量程0–100%。", "Temperature scale 0–100°C when available; otherwise explicitly displays GPU utilization, 0–100%."))
                        Button { selectGeekHardwareDetail(.monitoring) } label: {
                            GeekCombinedRing(
                                title: geekFanTelemetry.fanCount > 1 ? L10n.text("风扇均值", "Fans avg") : L10n.text("风扇", "Fan"),
                                value: geekFanTelemetry.actualRPM.map(String.init) ?? (geekFanTelemetry.isFanless ? L10n.text("无风扇", "Fanless") : "—"),
                                detail: geekFanTelemetry.actualRPM != nil ? "RPM" : (geekFanTelemetry.isSampling ? L10n.text("采样中", "Sampling") : L10n.text("不可用", "Unavailable")),
                                progress: geekFanTelemetry.percentage.map { $0 / 100 },
                                tint: AppDesignTokens.Palette.tertiary,
                                size: 72,
                                labelPlacement: .aboveValue,
                                strokeWidth: 4
                            )
                        }
                        .help(L10n.text("实际RPM；多风扇显示算术平均，详情保留每个风扇。仅有可靠最低/最高转速时绘制归一化圆弧，否则保留中性环。", "Actual RPM, arithmetic mean for multiple fans; individual readings remain in details. A normalized arc requires reliable minimum/maximum RPM; otherwise the track stays neutral."))
                    }
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var geekOverviewGPUTemperature: Double? {
        monitorSnapshot?.temperatureReadings?
            .first(where: { $0.zone == .gpu })?
            .celsius
    }

    private var geekOverviewFanValue: String {
        if geekFanTelemetry.isSampling { return L10n.text("检测中…", "Checking…") }
        if geekFanTelemetry.isFanless { return L10n.text("无风扇 · 被动散热", "Fanless · Passive cooling") }
        return L10n.text("读数不可用", "Reading unavailable")
    }

    private var geekHasSensorSummaryData: Bool {
        metricAvailable(.chipTemperature)
            || geekOverviewGPUTemperature != nil
            || metricAvailable(.gpuUsage)
            || geekFanTelemetry.telemetryAvailable
            || geekFanTelemetry.isFanless
            || geekFanTelemetry.isSampling
    }

    var geekFansCard: some View {
        GeekSection(
            title: L10n.text("风扇", "Fans"),
            systemImage: AppSymbols.Monitor.sensors,
            tint: AppDesignTokens.Palette.tertiary
        ) {
            if !geekOverviewFanReadings.isEmpty {
                ForEach(Array(geekOverviewFanReadings.prefix(2))) { reading in
                    GeekTelemetryRow(
                        title: reading.displayName,
                        value: reading.displayRPM,
                        tint: AppDesignTokens.Palette.tertiary
                    )
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .accessibilityLabel(L10n.text("正在采样", "Sampling"))
            }
        }
    }

    private var geekOverviewFanReadings: [SystemFanReading] {
        geekFanTelemetry.readings
    }

    @ViewBuilder
    var geekPowerSummaryCard: some View {
        if hasInternalBattery {
            geekBatterySummaryCard
        } else if hasConfirmedNoInternalBattery
                    || batteryElectricalSnapshot?.hasAdapterData == true {
            geekAdapterSummaryCard
        } else {
            geekAppPowerSummaryCard
        }
    }

    private var geekBatterySummaryCard: some View {
        let charge = batterySnapshot?.chargePercent.map { Double($0) / 100 }
        return GeekCombinedCard(
            height: GeekPanelLayout.overviewPowerCardHeight,
            verticalPadding: 4
        ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 5) {
                    VStack(alignment: .leading, spacing: 0) {
                        Label {
                            Text(L10n.text("电池", "Battery")).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: AppSymbols.Monitor.battery)
                                .foregroundStyle(AppDesignTokens.Palette.caution)
                        }
                        .font(.system(size: 11, weight: .medium))
                        Text(batterySnapshot?.chargePercent.map { "\($0)%" } ?? "--")
                            .font(.system(size: 18, weight: .regular))
                            .monospacedDigit()
                    }

                    Spacer(minLength: 4)

                    Text(geekOverviewPowerSourceAndModeTitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .layoutPriority(1)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.14))
                        if let charge {
                            Capsule()
                                .fill(AppDesignTokens.Palette.caution)
                                .frame(width: proxy.size.width * min(1, max(0, charge)))
                        }
                    }
                }
                .frame(height: 7)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
            .help(geekOverviewBatteryHelpText)
            .accessibilityLabel(L10n.text("电池状态", "Battery Status"))
            .accessibilityValue(geekOverviewBatteryHelpText)
        }
    }

    private var geekAppPowerSummaryCard: some View {
        let snapshot = store.energyImpactSnapshot
        return GeekCombinedCard(
            height: GeekPanelLayout.overviewPowerCardHeight,
            verticalPadding: 2
        ) {
            HStack(spacing: 8) {
                GeekCombinedRing(
                    title: L10n.text("功率", "POWER"),
                    value: snapshot?.currentPowerWattsText ?? "--",
                    progress: nil,
                    tint: resolvedEnergyTint,
                    size: 35
                )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L10n.text("App 功耗", "APP POWER"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 4)

                        Text(snapshot?.source ?? L10n.text("采样中", "Sampling"))
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(snapshot.map {
                        L10n.text("\($0.activeAppCount) 个活跃 App", "\($0.activeAppCount) active apps")
                    } ?? L10n.text("正在测量 App 能耗", "Measuring app energy"))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
            .help(snapshot.map {
                "\($0.currentPowerWattsText) · \($0.energyCoverageText)"
            } ?? L10n.text("正在测量 App 能耗", "Measuring app energy"))
        }
    }

    private var geekAdapterSummaryCard: some View {
        GeekCombinedCard(
            height: GeekPanelLayout.overviewPowerCardHeight,
            verticalPadding: 2
        ) {
            HStack(spacing: 8) {
                GeekCombinedRing(
                    title: "AC",
                    value: batteryElectricalSnapshot?.adapterPowerWatts
                        .map { String(format: "%.0fW", $0) } ?? "--",
                    progress: nil,
                    tint: AppDesignTokens.Palette.success,
                    size: 35,
                    fixedValueFontSize: 9
                )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L10n.text("电源适配器", "Power Adapter").uppercased())
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(geekOverviewPowerModeText
                            ?? batteryElectricalSnapshot?.adapterName
                            ?? L10n.text("已连接", "Connected"))
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(geekOverviewAdapterElectricalText)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
        }
    }

    private var geekOverviewPowerModeText: String? {
        guard geekHelperState == .enabled else { return nil }
        return geekCurrentPowerMode.map(batteryPowerModeText)
    }

    private var geekOverviewPowerSourceAndModeTitle: String {
        [batteryPowerSourceTitle, batteryStatusTitle].joined(separator: " · ")
    }

    private var geekOverviewAdapterElectricalText: String {
        let voltage = batteryElectricalSnapshot?.adapterVoltageVolts
            .map { String(format: "%.1f V", $0) } ?? "-- V"
        let current = batteryElectricalSnapshot?.adapterAmperageAmps
            .map { String(format: "%.2f A", $0) } ?? "-- A"
        return "\(voltage) · \(current)"
    }

    private var geekOverviewBatteryStatusText: String {
        guard batterySnapshot != nil else {
            return L10n.text("正在采样", "Sampling")
        }
        return batteryPresentationStateCompactTitle
    }

    private var geekOverviewBatteryTitle: String {
        batterySnapshot?.chargePercent.map {
            L10n.text("电池 \($0)%", "Battery \($0)%")
        } ?? L10n.text("电池 —", "Battery —")
    }

    private var geekOverviewBatteryHelpText: String {
        let level = batterySnapshot?.chargePercent.map { "\($0)%" }
            ?? L10n.text("正在采样", "Sampling")
        let status = batterySnapshot == nil ? geekOverviewBatteryStatusText : batteryStatusTitle
        var values = [level, status, batteryPowerSourceTitle]
        if let estimate = batteryRuntimeEstimate,
           let time = GeekBatteryRemainingTime.text(for: estimate.minutes) {
            values.append(L10n.text(
                "耗电预测 \(time)（\(String(format: "%.1f W", estimate.powerWatts))）",
                "Power-based \(time) at \(String(format: "%.1f W", estimate.powerWatts))"
            ))
        }
        return values.joined(separator: " · ")
    }

    var geekSystemLoadCard: some View {
        GeekSection(
            title: L10n.text("CPU 使用情况", "CPU Usage"),
            systemImage: AppSymbols.Panel.utilization,
            tint: AppDesignTokens.Palette.secondary
        ) {
            GeekTelemetryRow(title: L10n.text("总占用", "Total"), value: percentText(cpuBreakdown?.totalPercent), tint: processorTint)
            GeekTelemetryRow(title: L10n.text("应用", "Apps"), value: percentText(cpuBreakdown?.userPercent), tint: resolvedPrimaryTint)
            GeekTelemetryRow(title: L10n.text("系统", "System"), value: percentText(cpuBreakdown?.systemPercent), tint: resolvedSecondaryTint)
            GeekTelemetryRow(title: L10n.text("运行时间", "Uptime"), value: uptimeText, tint: AppDesignTokens.Palette.information)
            GeekTelemetryRow(title: L10n.text("散热状态", "Thermal"), value: thermalStateTitle, tint: thermalStateTint)
        }
    }

    var geekCleanupSummaryCard: some View {
        GeekSection(
            title: L10n.text("清理摘要", "Cleanup Summary"),
            systemImage: AppSymbols.Monitor.cleanup,
            tint: AppDesignTokens.Palette.success
        ) {
            GeekTelemetryRow(title: L10n.text("可安全清理", "Safe Cleanup"), value: safeCleanupBytesText, tint: AppDesignTokens.Palette.success)
            GeekTelemetryRow(title: L10n.text("建议项目", "Suggested Items"), value: safeCleanupCountText, tint: AppDesignTokens.Palette.success)
            if let latestScan = store.scanHistorySummary.latest {
                GeekTelemetryRow(
                    title: L10n.text("上次扫描", "Last Scan"),
                    value: timestampText(latestScan.date),
                    tint: AppDesignTokens.Palette.secondary
                )
            }
        }
    }

    var geekDashboardRows: [GeekDashboardLayoutRow] {
        GeekDashboardLayoutPlanner.rows(
            for: panelSettingsState.geekDashboardConfiguration.modules
        )
    }

    var geekDashboardBlocks: [GeekDashboardCanvasBlock] {
        GeekDashboardCanvasPlanner.blocks(
            for: panelSettingsState.geekDashboardConfiguration.modules
        )
    }

    var geekSummaryCells: [GeekMetricCellModel] {
        let configuration = panelSettingsState.geekDashboardConfiguration
        return configuration.summaryMetrics.map { metric in
            GeekMetricCellModel(
                id: metric.rawValue,
                tile: geekSummaryTile(for: metric),
                destination: geekDestination(for: metric)
            )
        }
    }

    var geekChartHistory: [MenuBarTelemetryPoint] {
        history
    }

    var geekChartDuration: TimeInterval {
        selectedChartRange.duration
    }

    var geekChartRangeTitle: String {
        selectedChartRange.title
    }

    var geekChartDiskHistory: [NativeDiskIOPoint] {
        nativeDiskIOHistory
    }

    func selectGeekSection(_ section: PanelSection) {
        panelCoordinator.selectModule(section)
        selectedRailSection = section
    }

    func previewGeekSection(_ section: PanelSection) {
        panelCoordinator.previewModule(section)
        selectedRailSection = section
    }

    func selectGeekHardwareDetail(_ focus: GeekHardwareDetailFocus) {
        panelCoordinator.selectHardwareDetail(focus)
        selectedRailSection = panelCoordinator.selectedSection
    }

    func previewGeekHardwareDetail(_ focus: GeekHardwareDetailFocus) {
        panelCoordinator.previewHardwareDetail(focus)
        selectedRailSection = .sensors
    }

    func geekDestination(for metric: GeekSummaryMetric) -> PanelSection {
        switch metric {
        case .cpu, .gpu: .processor
        case .memory: .memory
        case .temperature, .fans: .sensors
        case .battery: .power
        case .disk: .disk
        case .network: .network
        }
    }

    func geekSummaryTile(for metric: GeekSummaryMetric) -> AdvancedMetricTileModel {
        switch metric {
        case .cpu:
            return geekHeroTile(id: "cpu", title: metric.title)
        case .gpu:
            return geekHeroTile(id: "gpu", title: metric.title)
        case .memory:
            return geekHeroTile(id: "memory", title: metric.title)
        case .temperature:
            return geekHeroTile(id: "temperature", title: metric.title)
        case .fans:
            return geekHeroTile(id: "fan", title: metric.title)
        case .battery:
            return geekHeroTile(id: "battery", title: metric.title)
        case .disk:
            return AdvancedMetricTileModel(
                id: metric.rawValue,
                title: metric.title,
                value: storageSnapshot.map { ByteFormat.storageString($0.userAvailableBytes) } ?? "--",
                detail: L10n.text("可用 · \(storagePressureTitle)", "Available · \(storagePressureTitle)"),
                tint: storageTint,
                progress: storageSnapshot?.userAvailableRatio
            )
        case .network:
            return AdvancedMetricTileModel(
                id: metric.rawValue,
                title: metric.title,
                value: "↓ \(networkDownText)",
                detail: "↑ \(networkUpText)",
                tint: resolvedDownloadTint,
                progress: nil
            )
        }
    }

    func geekHeroTile(id: String, title: String) -> AdvancedMetricTileModel {
        geekHeroTiles.first(where: { $0.id == id })
            ?? AdvancedMetricTileModel(
                id: id,
                title: title,
                value: "--",
                detail: L10n.text("正在采样…", "Sampling…"),
                tint: AppDesignTokens.Palette.secondary,
                progress: nil
            )
    }


    var geekHeroTiles: [AdvancedMetricTileModel] {
        let batteryCharge = batterySnapshot?.chargePercent
        return [
            AdvancedMetricTileModel(
                id: "cpu",
                title: "CPU",
                value: metricValue(.cpuUsage),
                detail: L10n.text(
                    "用户 \(percentText(cpuBreakdown?.userPercent)) · 系统 \(percentText(cpuBreakdown?.systemPercent))",
                    "User \(percentText(cpuBreakdown?.userPercent)) · System \(percentText(cpuBreakdown?.systemPercent))"
                ),
                tint: processorTint,
                progress: metricPercent(.cpuUsage)
            ),
            AdvancedMetricTileModel(
                id: "gpu",
                title: "GPU",
                value: metricValue(.gpuUsage),
                detail: L10n.text("GPU 负载", "GPU Load"),
                tint: AppDesignTokens.Palette.diagnostic,
                progress: metricPercent(.gpuUsage)
            ),
            AdvancedMetricTileModel(
                id: "memory",
                title: L10n.text("内存压力", "Memory Pressure"),
                value: memoryPressureDisplayText,
                detail: memoryPressureHeadroomText,
                tint: memoryTint,
                progress: memoryPressureStateProgress
            ),
            AdvancedMetricTileModel(
                id: "temperature",
                title: L10n.text("温度", "Temp"),
                value: metricValue(.chipTemperature),
                detail: thermalStateTitle,
                tint: temperatureTint,
                progress: temperatureProgress
            ),
            AdvancedMetricTileModel(
                id: "fan",
                title: L10n.text("风扇", "Fans"),
                value: metricValue(.fanSpeed),
                detail: metricDetail(.fanSpeed),
                tint: AppDesignTokens.Palette.tertiary,
                progress: nil
            ),
            AdvancedMetricTileModel(
                id: "battery",
                title: L10n.text("电池", "Battery"),
                value: batteryCharge.map { "\($0)%" } ?? "--",
                detail: batterySnapshot == nil ? L10n.text("读取中", "Reading") : batteryPowerSourceTitle,
                tint: batteryTint,
                progress: batteryCharge.map { Double($0) / 100 }
            )
        ]
    }

    var geekProcessorTiles: [AdvancedMetricTileModel] {
        [
            AdvancedMetricTileModel(
                id: "cpu-total",
                title: L10n.text("CPU 总占用", "CPU Total"),
                value: percentText(cpuBreakdown?.totalPercent),
                detail: L10n.text("实时调度", "Live Scheduler"),
                tint: processorTint,
                progress: percentProgress(cpuBreakdown?.totalPercent)
            ),
            AdvancedMetricTileModel(
                id: "cpu-user",
                title: L10n.text("用户", "User"),
                value: percentText(cpuBreakdown?.userPercent),
                detail: L10n.text("应用与用户任务", "Apps & User Tasks"),
                tint: AppDesignTokens.Palette.information,
                progress: percentProgress(cpuBreakdown?.userPercent)
            ),
            AdvancedMetricTileModel(
                id: "cpu-system",
                title: L10n.text("系统", "System"),
                value: percentText(cpuBreakdown?.systemPercent),
                detail: L10n.text("内核与驱动", "Kernel & Drivers"),
                tint: resolvedSecondaryTint,
                progress: percentProgress(cpuBreakdown?.systemPercent)
            ),
            AdvancedMetricTileModel(
                id: "gpu",
                title: "GPU",
                value: metricValue(.gpuUsage),
                detail: L10n.text("驱动利用率", "Driver Utilization"),
                tint: AppDesignTokens.Palette.diagnostic,
                progress: metricPercent(.gpuUsage)
            ),
            AdvancedMetricTileModel(
                id: "cpu-temperature",
                title: L10n.text("温度", "Temperature"),
                value: metricValue(.chipTemperature),
                detail: thermalStateTitle,
                tint: temperatureTint,
                progress: temperatureProgress
            ),
            AdvancedMetricTileModel(
                id: "system-uptime",
                title: L10n.text("运行时间", "Uptime"),
                value: uptimeText,
                detail: L10n.text("本次开机", "Since Startup"),
                tint: AppDesignTokens.Palette.secondary,
                progress: nil
            )
        ]
    }

    var geekMemoryTiles: [AdvancedMetricTileModel] {
        guard let snapshot = memorySnapshot else {
            return [
                AdvancedMetricTileModel(id: "physical", title: L10n.text("物理内存", "Physical"), value: "--", detail: L10n.text("读取中", "Reading"), tint: AppDesignTokens.Palette.information, progress: nil),
                AdvancedMetricTileModel(id: "used", title: L10n.text("已用", "Used"), value: "--", detail: L10n.text("读取中", "Reading"), tint: memoryTint, progress: nil),
                AdvancedMetricTileModel(id: "available", title: L10n.text("可用", "Available"), value: "--", detail: L10n.text("读取中", "Reading"), tint: AppDesignTokens.Palette.success, progress: nil),
                AdvancedMetricTileModel(id: "swap", title: L10n.text("交换内存", "Swap Memory"), value: "--", detail: L10n.text("读取中", "Reading"), tint: AppDesignTokens.Palette.diagnostic, progress: nil)
            ]
        }
        let physical = snapshot.measurements.physicalBytes.value
        let available = snapshot.measurements.availableBytes.value
        let compressed = snapshot.measurements.compressedBytes.value
        let swap = snapshot.measurements.swapUsedBytes.value
        let usedPercent = snapshot.measuredUsedRatio.map {
            String(format: "%.0f%%", $0 * 100)
        } ?? snapshot.measurements.availableBytes.availability.title
        let compressedRatio: Double? = physical.flatMap { total in
            guard total > 0, let compressed else { return nil }
            return min(1, max(0, Double(compressed) / Double(total)))
        }
        return [
            AdvancedMetricTileModel(
                id: "physical",
                title: L10n.text("物理内存", "Physical"),
                value: physical.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—",
                detail: snapshot.measurements.physicalBytes.unavailableDetail ?? snapshot.pressureSummary,
                tint: AppDesignTokens.Palette.information,
                progress: nil
            ),
            AdvancedMetricTileModel(
                id: "used",
                title: L10n.text("已用", "Used"),
                value: snapshot.measuredUsedBytes.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—",
                detail: usedPercent,
                tint: memoryTint,
                progress: snapshot.measuredUsedRatio
            ),
            AdvancedMetricTileModel(
                id: "available",
                title: L10n.text("可用", "Available"),
                value: available.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—",
                detail: snapshot.measurements.availableBytes.unavailableDetail
                    ?? snapshot.measuredAvailableRatio.map { String(format: "%.0f%%", $0 * 100) }
                    ?? "—",
                tint: AppDesignTokens.Palette.success,
                progress: snapshot.measuredAvailableRatio
            ),
            AdvancedMetricTileModel(
                id: "swap",
                title: L10n.text("交换内存", "Swap Memory"),
                value: swap.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—",
                detail: snapshot.measurements.swapUsedBytes.unavailableDetail
                    ?? snapshot.pressureSummary,
                tint: AppDesignTokens.Palette.diagnostic,
                progress: nil
            ),
            AdvancedMetricTileModel(
                id: "compressed",
                title: L10n.text("压缩", "Compressed"),
                value: compressed.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—",
                detail: snapshot.measurements.compressedBytes.unavailableDetail
                    ?? L10n.text("物理内存占比", "Share of physical memory"),
                tint: AppDesignTokens.Palette.storage,
                progress: compressedRatio
            ),
            AdvancedMetricTileModel(
                id: "memory-pressure",
                title: L10n.text("内存压力", "Memory Pressure"),
                value: memoryPressureDisplayText,
                detail: memoryPressureHeadroomText,
                tint: memoryTint,
                progress: memoryPressureStateProgress
            )
        ]
    }

    var geekDiskTiles: [AdvancedMetricTileModel] {
        [
            AdvancedMetricTileModel(
                id: "disk-total",
                title: L10n.text("总容量", "Total"),
                value: storageSnapshot.map { ByteFormat.storageString($0.totalBytes) } ?? "--",
                detail: volumeName,
                tint: AppDesignTokens.Palette.information,
                progress: nil
            ),
            AdvancedMetricTileModel(
                id: "disk-available",
                title: L10n.text("可用", "Available"),
                value: storageSnapshot.map { ByteFormat.storageString($0.userAvailableBytes) } ?? "--",
                detail: storagePressureTitle,
                tint: AppDesignTokens.Palette.success,
                progress: storageSnapshot?.userAvailableRatio
            ),
            AdvancedMetricTileModel(
                id: "disk-used",
                title: L10n.text("已用", "Used"),
                value: storageSnapshot.map { ByteFormat.storageString($0.userUsedBytes) } ?? "--",
                detail: storageSnapshot.map { "\($0.userUsedPercent)%" } ?? L10n.text("采样中", "Sampling"),
                tint: storageTint,
                progress: storageSnapshot?.userUsedRatio
            ),
            AdvancedMetricTileModel(
                id: "disk-read",
                title: L10n.text("实时读取", "Read Now"),
                value: geekDiskReadRateText,
                detail: L10n.text("IOKit 块存储计数器", "IOKit Block Counter"),
                tint: AppDesignTokens.Palette.information,
                progress: nil
            ),
            AdvancedMetricTileModel(
                id: "disk-write",
                title: L10n.text("实时写入", "Write Now"),
                value: geekDiskWriteRateText,
                detail: L10n.text("IOKit 块存储计数器", "IOKit Block Counter"),
                tint: AppDesignTokens.Palette.sensitive,
                progress: nil
            ),
            AdvancedMetricTileModel(
                id: "disk-status",
                title: L10n.text("空间状态", "Space Status"),
                value: storagePressureTitle,
                detail: volumeName,
                tint: storageTint,
                progress: nil
            )
        ]
    }

    var geekNetworkTiles: [AdvancedMetricTileModel] {
        [
            AdvancedMetricTileModel(id: "down-current", title: L10n.text("下载当前", "Download Now"), value: networkDownText, detail: L10n.text("实时", "Live"), tint: resolvedDownloadTint, progress: nil),
            AdvancedMetricTileModel(id: "up-current", title: L10n.text("上传当前", "Upload Now"), value: networkUpText, detail: L10n.text("实时", "Live"), tint: resolvedUploadTint, progress: nil),
            AdvancedMetricTileModel(id: "down-peak", title: L10n.text("下载峰值", "Download Peak"), value: rateText(geekNetworkDownPeak), detail: L10n.text("最近 \(geekChartRangeTitle)", "Last \(geekChartRangeTitle)"), tint: resolvedDownloadTint, progress: nil),
            AdvancedMetricTileModel(id: "up-peak", title: L10n.text("上传峰值", "Upload Peak"), value: rateText(geekNetworkUpPeak), detail: L10n.text("最近 \(geekChartRangeTitle)", "Last \(geekChartRangeTitle)"), tint: resolvedUploadTint, progress: nil),
            AdvancedMetricTileModel(id: "session-download", title: L10n.text("估算下载", "Est. Download"), value: ByteFormat.string(sessionDownloadedBytes), detail: L10n.text("速率积分", "Rate integral"), tint: resolvedDownloadTint, progress: nil),
            AdvancedMetricTileModel(id: "session-upload", title: L10n.text("估算上传", "Est. Upload"), value: ByteFormat.string(sessionUploadedBytes), detail: L10n.text("速率积分", "Rate integral"), tint: resolvedUploadTint, progress: nil)
        ]
    }

    var geekSensorTiles: [AdvancedMetricTileModel] {
        [
            AdvancedMetricTileModel(id: "temp", title: L10n.text("芯片温度", "Chip Temp"), value: metricValue(.chipTemperature), detail: thermalStateTitle, tint: temperatureTint, progress: temperatureProgress),
            AdvancedMetricTileModel(id: "fan", title: L10n.text("平均转速", "Fan Average"), value: metricValue(.fanSpeed), detail: metricDetail(.fanSpeed), tint: AppDesignTokens.Palette.tertiary, progress: nil),
            AdvancedMetricTileModel(id: "fan-count", title: L10n.text("风扇数量", "Fan Count"), value: monitorSnapshot?.fanSpeedsRPM.map { "\($0.count)" } ?? "--", detail: L10n.text("原生 SMC 读数", "Native SMC Readings"), tint: AppDesignTokens.Palette.freshness, progress: nil),
            AdvancedMetricTileModel(id: "gpu-sensor", title: "GPU", value: metricValue(.gpuUsage), detail: L10n.text("驱动利用率", "Driver Utilization"), tint: AppDesignTokens.Palette.diagnostic, progress: metricPercent(.gpuUsage)),
            AdvancedMetricTileModel(id: "peak-temperature", title: L10n.text("最高温度", "Peak Temperature"), value: geekPeakTemperature.map { GeekChartUnit.temperature.formatted($0) } ?? "--", detail: L10n.text("所选时间范围", "Selected time range"), tint: temperatureTint, progress: geekPeakTemperature.map { min(1, max(0, $0 / 100)) }),
            AdvancedMetricTileModel(id: "thermal-state", title: L10n.text("热状态", "Thermal State"), value: thermalStateTitle, detail: L10n.text("系统判定", "System assessment"), tint: thermalStateTint, progress: nil)
        ]
    }

    var geekPowerTiles: [AdvancedMetricTileModel] {
        let charge = batterySnapshot?.chargePercent
        return [
            AdvancedMetricTileModel(id: "charge", title: L10n.text("电量", "Charge"), value: charge.map { "\($0)%" } ?? "--", detail: batteryStatusTitle, tint: batteryTint, progress: charge.map { Double($0) / 100 }),
            AdvancedMetricTileModel(id: "power-source", title: L10n.text("供电来源", "Power Source"), value: batteryPowerSourceTitle, detail: batteryStatusTitle, tint: batteryTint, progress: nil),
            AdvancedMetricTileModel(id: "battery-power", title: L10n.text("当前功率", "Current Power"), value: batteryElectricalSnapshot?.powerWatts.map { String(format: "%+.2f W", $0) } ?? "--", detail: L10n.text("原生电池电压 × 电流", "Native battery voltage × current"), tint: resolvedEnergyTint, progress: nil),
            AdvancedMetricTileModel(id: "health", title: L10n.text("最大容量", "Maximum Capacity"), value: healthSummary?.batteryCapacityPercent.map { "\($0)%" } ?? "--", detail: healthSummary?.batteryCycleCount.map { L10n.text("\($0) 次循环", "\($0) cycles") } ?? L10n.text("待健康检查", "Awaiting Health Check"), tint: AppDesignTokens.Palette.success, progress: healthSummary?.batteryCapacityPercent.map { Double($0) / 100 }),
            AdvancedMetricTileModel(id: "cycle-count", title: L10n.text("循环次数", "Cycle Count"), value: healthSummary?.batteryCycleCount.map(String.init) ?? "--", detail: healthSummary?.batteryCondition.map(batteryConditionText) ?? L10n.text("待健康检查", "Awaiting Health Check"), tint: AppDesignTokens.Palette.secondary, progress: nil),
            AdvancedMetricTileModel(id: "remaining-time", title: L10n.text("剩余时间", "Remaining Time"), value: batterySnapshot?.remainingTimeMinutes.map(durationMinutesText) ?? "--", detail: batterySnapshot?.isCharging == true ? L10n.text("至充满", "Until full") : L10n.text("预计可用", "Estimated remaining"), tint: batteryTint, progress: nil)
        ]
    }

    var geekCleanupTiles: [AdvancedMetricTileModel] {
        [
            AdvancedMetricTileModel(id: "safe-bytes", title: L10n.text("可安全清理", "Safe Cleanup"), value: safeCleanupBytesText, detail: safeCleanupCountText, tint: AppDesignTokens.Palette.success, progress: nil),
            AdvancedMetricTileModel(id: "disk-free", title: L10n.text("启动卷可用", "Disk Available"), value: storageSnapshot.map { ByteFormat.storageString($0.userAvailableBytes) } ?? "--", detail: storagePressureTitle, tint: storageTint, progress: storageSnapshot?.userAvailableRatio),
            AdvancedMetricTileModel(id: "actionable", title: L10n.text("当前可操作", "Actionable Now"), value: "\(actionableCleanupItems.count)", detail: actionableCleanupItems.isEmpty ? L10n.text("需重新扫描", "Rescan Required") : L10n.text("已加载明细", "Details Loaded"), tint: AppDesignTokens.Palette.warning, progress: nil)
        ]
    }

    var geekTopProcesses: [MemoryProcess] {
        Array((processMemorySnapshot?.topProcesses ?? []).prefix(4))
    }

    var geekEnergyApps: [EnergyImpactApp] {
        var apps = store.energyImpactSnapshot?.apps ?? []
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            apps = MiniWindowDemoData.energyApps
        }
#endif
        return Array(
            apps
                .filter { $0.isApplication && $0.isSignificantCurrentEnergy }
                .sorted {
                    if $0.currentPowerWatts != $1.currentPowerWatts {
                        return $0.currentPowerWatts > $1.currentPowerWatts
                    }
                    return $0.cpuPercent > $1.cpuPercent
                }
                .prefix(5)
        )
    }

    var geekShouldRefreshOnDemandSnapshot: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return false }
#endif
        return !store.isMenuBarRefreshPaused
            && store.canRefreshEnergyImpact
            && GeekOnDemandSnapshotFreshness.state(
                generatedAt: store.energyImpactSnapshot?.generatedAt
            ) != .current
    }

    var geekOnDemandSnapshotStatusText: String {
        GeekOnDemandSnapshotFreshness.statusText(
            generatedAt: store.energyImpactSnapshot?.generatedAt
        )
    }

    var geekDiskReadRateText: String {
        guard let point = nativeDiskIOHistory.last else { return "--" }
        return "\(ByteFormat.string(point.readBytesPerSecond))/s"
    }

    var geekDiskWriteRateText: String {
        guard let point = nativeDiskIOHistory.last else { return "--" }
        return "\(ByteFormat.string(point.writeBytesPerSecond))/s"
    }

    var geekDiskReadIOPSText: String {
        guard let point = nativeDiskIOHistory.last else { return "--" }
        return point.readOperationsPerSecond.formatted(
            .number.precision(.fractionLength(0))
        )
    }

    var geekDiskWriteIOPSText: String {
        guard let point = nativeDiskIOHistory.last else { return "--" }
        return point.writeOperationsPerSecond.formatted(
            .number.precision(.fractionLength(0))
        )
    }

    var geekNetworkDownAverage: Int64? {
        geekAverageRate(networkChartHistory.compactMap(\.downBytesPerSecond))
    }

    var geekNetworkUpAverage: Int64? {
        geekAverageRate(networkChartHistory.compactMap(\.upBytesPerSecond))
    }

    var geekNetworkDownPeak: Int64? {
        networkChartHistory.compactMap(\.downBytesPerSecond).max()
    }

    var geekNetworkUpPeak: Int64? {
        networkChartHistory.compactMap(\.upBytesPerSecond).max()
    }

    var geekPeakTemperature: Double? {
        geekChartHistory.compactMap(\.chipTemperature).max()
    }

    func geekAverageRate(_ values: [Int64]) -> Int64? {
        guard !values.isEmpty else { return nil }
        return Int64((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }
}

struct GeekLiveNetworkValue: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            Text(value)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            HStack(spacing: 4) {
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)

                Text(title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .help("\(title): \(value)")
        .accessibilityElement(children: .combine)
    }
}

struct GeekTelemetryRow: View {
    let title: String
    let value: String

    /// `tint` remains part of the call-site contract because many telemetry
    /// producers already classify their state. The advanced window presents
    /// ordinary table text neutrally; status color belongs in charts, gauges,
    /// and explicit warnings rather than every row label.
    init(title: String, value: String, tint _: Color) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title)
                .font(AdvancedPanelTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(value)
                .font(AdvancedPanelTypography.captionStrong)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .help("\(title): \(value)")
        .accessibilityElement(children: .combine)
    }
}
