import SwiftUI

struct GeekDetailContentMeasurement: Equatable {
    let section: PanelSection
    let density: PanelDensity
    let size: CGSize
    var cleanupReadiness: GeekCleanupLayoutReadiness = .unrestricted

    func canReportSize(smartCleanup: Bool, cleanupIsVisible: Bool, cleanupVisibilityID: UUID, cleanupRevision: UInt64? = nil) -> Bool {
        guard cleanupReadiness.isReady else { return false }
        guard smartCleanup else { return cleanupReadiness.visibilityID == nil }
        // An initial unrestricted preference or a queued old-page report must
        // not publish a pending height before the real cleanup layout settles.
        return cleanupIsVisible && cleanupReadiness.visibilityID == cleanupVisibilityID
            && (cleanupRevision == nil || cleanupReadiness.revision == cleanupRevision)
    }
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

private struct GeekPausedRowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The shell passes its actual visible height. Only the explicit pause state
/// reserves a status row; sample provenance belongs in hover help.
private struct GeekDetailPageFrame<Content: View>: View {
    let isPaused: Bool
    @ViewBuilder let content: Content
    @Environment(\.geekCleanupAvailableHeight) private var availableHeight
    @State private var pausedHeight: CGFloat = 0
    var body: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            if isPaused {
                MiniWindowPausedSamplingRow()
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: GeekPausedRowHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            content.environment(\.geekCleanupAvailableHeight,
                max(0, availableHeight - (isPaused ? pausedHeight + GeekPanelLayout.detailSpacing : 0)))
        }
        .onPreferenceChange(GeekPausedRowHeightKey.self) { height in
            Task { @MainActor in if pausedHeight != height { pausedHeight = height } }
        }
    }
}

enum GeekOnDemandSnapshotFreshnessState: Equatable {
    case notMeasured
    case current
    case stale
}

enum GeekOnDemandSnapshotFreshness {
    static let refreshInterval = MenuBarPerformancePolicy.visibleProcessInterval
    static let staleAfter: TimeInterval = 5 * 60

    static func shouldRefresh(startedAt: Date?, now: Date = Date()) -> Bool {
        startedAt.map { now.timeIntervalSince($0) >= refreshInterval - 0.05 } ?? true
    }

    static func state(
        generatedAt: Date?,
        now: Date = Date()
    ) -> GeekOnDemandSnapshotFreshnessState {
        guard let generatedAt else { return .notMeasured }
        return now.timeIntervalSince(generatedAt) >= staleAfter ? .stale : .current
    }

    /// `isSampling`: the first measurement is being taken (BOARD N16-2).
    static func statusText(
        generatedAt: Date?,
        now: Date = Date(),
        isSampling: Bool = false
    ) -> String {
        guard let generatedAt else {
            return isSampling
                ? L10n.text("正在采样…", "Sampling…")
                : L10n.text("未测量", "Not Measured")
        }

        let timestamp = PanelTimestampFormat.age(generatedAt, now: now)
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

/// Review P2-8: a process page whose first measurement did not come within
/// `MenuBarPerformancePolicy.processSampleTimeout` says "未测量" and why.
extension GeekOnDemandSnapshotFreshness {
    /// The header help's reason, appended to "按需快照 · 未测量"; "" otherwise.
    static func nothingMeasuredReason(_ nothingMeasured: Bool) -> String {
        guard nothingMeasured else { return "" }
        let seconds = Int(MenuBarPerformancePolicy.processSampleTimeout)
        return L10n.text(
            "：\(seconds) 秒内没有取得进程数据，仍在继续采样",
            ": no process data within \(seconds) s; sampling continues"
        )
    }

    /// In place of the empty list's "—".
    static var nothingMeasuredText: String {
        L10n.text("未取得进程数据", "No process data")
    }
}

extension MenuBarAdvancedStatusView {
    // An overview opening must not instantiate the metadata for all detail
    // pages. Erase only at this navigation boundary; card identity stays stable.
    var geekDetailPage: AnyView {
        if selectedSection == .overview {
            return AnyView(geekOverviewPage)
        } else {
            return AnyView(geekSelectedDetailPage)
        }
    }

    private var requestedGeekPage: AnyView {
        switch selectedSection {
        case .overview: return AnyView(EmptyView())
        case .processor: return AnyView(geekProcessorPage)
        case .memory: return AnyView(geekMemoryPage)
        case .disk: return AnyView(geekDiskPage)
        case .network: return AnyView(geekNetworkPage)
        case .sensors: return AnyView(geekSensorsPage)
        case .power: return AnyView(geekPowerPage)
        case .cleanup: return AnyView(geekCleanupPage)
        }
    }

    var geekOverviewPage: some View {
        geekCanvas
        .contextMenu { overviewContextMenu }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Level-one anchors are measured from the overview shell's top-left
        // corner and, beside a secondary page, from the cascade's overview
        // frame (GeekModuleAnchorRegistration).
        .coordinateSpace(name: GeekOverviewAnchorSpace.name)
        .environment(\.geekOverviewAnchorPlacement, geekOverviewAnchorPlacement)
        .onAppear {
            synchronizeGeekOverviewPresentation()
        }
        .onChange(of: geekVisibleOverviewModules) {
            synchronizeGeekOverviewPresentation()
        }
    }

    private var geekOverviewAnchorPlacement: GeekOverviewAnchorPlacement {
        guard selectedSection != .overview else { return .overviewOnly }
        guard let layout = panelSettingsState.cascadeLayout, !layout.isCompact else {
            return .attached(overviewScreenFrame: nil)
        }
        return .attached(overviewScreenFrame: layout.parentFrame)
    }

    private var showsOverviewPowerModule: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.hardwareControlProfile.hasInternalBattery
        }
#endif
        // Unknown hardware must not create a battery card on desktop startup.
        // A positive live sample will publish this module on a portable Mac.
        return hasInternalBattery
    }

    private var geekOverviewPreferredSize: CGSize {
        let size = GeekPanelLayout.overviewSize(modules: geekVisibleOverviewModules)
        // An empty overview retains its Settings action in a 48 pt content
        // area, with the same 8 pt shell insets as the Settings sample.
        let contentHeight = geekVisibleOverviewModules.isEmpty
            ? 48 + GeekPanelLayout.contentPadding * 2
            : size.height
        return CGSize(width: size.width, height: contentHeight)
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


    var geekSelectedDetailPage: some View {
        let measuredSection = selectedSection
        let measuredDensity = presentation
        // Measure every row; the attached shell grows to this complete page.
        return Group {
            GeekDetailPageFrame(isPaused: store.isMenuBarRefreshPaused) {
                requestedGeekPage
                    .menuBarPresentationProbe("secondary")
                    .id(selectedSection)
            }
            .menuBarTraceRegion("secondary")
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, GeekPanelLayout.contentPadding)
            .padding(.horizontal, GeekPanelLayout.contentPadding)
            .backgroundPreferenceValue(GeekCleanupLayoutReadinessKey.self) { readiness in
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: GeekDetailContentSizeKey.self,
                        value: GeekDetailContentMeasurement(
                            section: measuredSection,
                            density: measuredDensity,
                            size: readiness.preferredSize(in: proxy.size), cleanupReadiness: readiness
                        )
                    )
                }
            }
            .coordinateSpace(name: GeekTertiarySourceCoordinateSpace.name)
            .onPreferenceChange(GeekDetailContentSizeKey.self) { measurement in
                Task { @MainActor in
                    guard let measurement, measurement.canReportSize(
                        smartCleanup: measurement.section == .cleanup && store.cleanupFeatureConfiguration.mode != .legacy,
                        cleanupIsVisible: cleanupDetailsModel.isVisible,
                        cleanupVisibilityID: cleanupDetailsModel.visibilityID,
                        cleanupRevision: cleanupDetailsModel.layoutRevision
                    ) else { return }
                    updateMeasuredDetailContentSize(
                        measurement.size,
                        for: measurement.section,
                        density: measurement.density
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var geekCanvas: some View {
        VStack(spacing: GeekPanelLayout.sectionSpacing) {
            GeekOverviewPanel(modules: geekVisibleOverviewModules) {
                MiniWindowEmptyConfigurationView()
            } content: { module in
                liveCard(overviewCardDomain(module), page: MenuBarCardIdentity.overviewPage) { geekOverviewModule(module) }
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

    private func overviewCardDomain(_ module: GeekDashboardModule) -> MenuBarCardDomain {
        switch module {
        case .coreMetrics, .memoryBreakdown: .memory
        case .processorGraphics, .systemLoad: .cpu
        case .network: .network
        case .disk, .cleanupSummary: .capacity
        case .sensors, .fans: .sensors
        case .power: .battery
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
        GeekProcessorPresentation(cpuChartHistory: cpuChartHistory, cpuChartRange: cpuChartRange, samplingInterval: store.menuBarRefreshInterval.seconds, processorTint: processorTint, geekCPUUserBarColor: geekCPUUserBarColor, geekCPUSystemBarColor: geekCPUSystemBarColor, currentPoint: cpuCurrentReading,
                                  isUpdating: cpuDisplayedHistory.isUpdating,
                                  // D43: frequency and temperature, only what was read;
                                  // the temperature color when there is one.
                                  headerFrequencyText: geekCompactFrequencyText,
                                  headerTemperatureText: temperatureValue.map(geekCompactTemperature),
                                  headerReadoutTint: temperatureValue == nil ? .primary : temperatureTint)
    }

    private var geekCPUUserBarColor: Color {
        resolvedPrimaryTint
    }

    var geekCurrentCPUUserPercent: Double? {
        cpuCurrentReading?.cpuUser
    }

    var geekCurrentCPUSystemPercent: Double? {
        cpuCurrentReading?.cpuSystem
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
        GeekMemoryPresentation(memoryRingUsedPercentText: memoryRingUsedPercentText, memoryRingUsedProgress: memoryRingUsedProgress, memoryRingSegments: memoryRingSegments, pressure: memorySnapshot?.pressureEstimatePercent, memoryTint: memoryTint)
    }

    var geekMemoryRingSegments: [GeekCombinedRingSegment] {
        memoryRingSegments
    }

    func geekMemoryPressureRing(size: CGFloat) -> some View {
        let percent = memorySnapshot?.pressureEstimatePercent
        return GeekCombinedRing(
            title: L10n.text("压力评估", "Pressure estimate"),
            value: percent.map { "\($0)%" } ?? "—",
            progress: percent.map { Double($0) / 100 },
            tint: memoryTint,
            size: size,
            fixedValueFontSize: size >= 90 ? 28 : 24,
            strokeWidth: GeekVisualTokens.gaugeStrokeWidth(size: size)
        )
        // D28: the number is the estimate; the ring color is the level.
        .help(L10n.text(
            "百分比为估算：100% − 系统压力余量，仅用于趋势；圆环颜色表示压力等级，取自 macOS 系统，与活动监视器一致；系统未给出等级时按百分比估算（85% 起为升高、95% 起为高）",
            "The percentage is an estimate: 100% minus system pressure headroom, for trends only; the ring color shows the pressure level, which comes from macOS, the same source as Activity Monitor; when macOS reports no level, it is estimated from the percentage (Elevated from 85%, High from 95%)"
        ))
    }

    var geekNetworkCard: some View {
        GeekNetworkPresentation(networkUpText: networkUpText, networkDownText: networkDownText, networkChartHistory: networkChartHistory, networkChartRange: networkChartRange, resolvedUploadTint: resolvedUploadTint, resolvedDownloadTint: resolvedDownloadTint,
                                isUpdating: networkDisplayedHistory.isUpdating)
    }

    var geekDiskCard: some View {
        GeekDiskPresentation(storageSnapshot: storageSnapshot, volumeName: volumeName, geekPrimaryDiskHealthText: geekPrimaryDiskHealthText, geekPrimaryDiskHealthTint: geekPrimaryDiskHealthTint, healthHelp: GeekDiskHealthTimestamp.detailText(GeekDiskHealthTimestamp.checkedAt(snapshot: computerHealthStore.snapshot?.disk, fallbackRemainingLifePercent: healthSummary?.diskRemainingLifePercent)))
    }

    var geekSensorsCard: some View {
        GeekOverviewHoverRegion(destination: .sensors, isSelected: selectedSection == .sensors, preview: previewGeekSection) {
            GeekSensorsPresentation(geekCompactTemperatureText: geekCompactTemperatureText,
                    geekCompactFrequencyText: geekCompactFrequencyText, temperatureProgress: temperatureProgress,
                    temperatureTint: temperatureTint, geekOverviewGPUTemperature: geekOverviewGPUTemperature,
                    gpuUsageText: metricValue(.gpuUsage), gpuUsageProgress: metricPercent(.gpuUsage),
                    // A GPU temperature ring takes the temperature color, as on
                    // the sensors page; GPU usage keeps the GPU color.
                    resolvedGPUTint: geekOverviewGPUTemperature.map(geekTemperatureTint) ?? resolvedGPUTint,
                    geekFanTelemetry: geekFanTelemetry,
                    openDetail: { selectGeekHardwareDetail(.monitoring) },
                    geekCompactGPUFrequencyText: geekCompactGPUFrequencyText,
                    fanControlEntry: geekFanControlEntryPresentation)
        }
    }

    private var geekOverviewGPUTemperature: Double? {
        monitorSnapshot?.temperatureReadings?
            .first(where: { $0.zone == .gpu })?
            .celsius
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
        GeekBatteryPresentation(percent: batterySnapshot?.chargePercent, geekOverviewPowerSourceAndModeTitle: geekOverviewPowerSourceAndModeTitle, geekOverviewBatteryHelpText: geekOverviewBatteryHelpText)
    }

    private var geekAppPowerSummaryCard: some View {
        let snapshot = store.menuBarPreparedProcesses?.snapshot
        return GeekCombinedCard(
            height: GeekPanelLayout.overviewPowerCardHeight
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
                            .font(AdvancedPanelTypography.captionStrong)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 4)

                        Text(snapshot?.source ?? L10n.text("采样中", "Sampling"))
                            .font(AdvancedPanelTypography.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(snapshot.map {
                        L10n.text("\($0.activeAppCount) 个活跃 App", "\($0.activeAppCount) active apps")
                    } ?? L10n.text("正在测量 App 能耗", "Measuring app energy"))
                    .font(AdvancedPanelTypography.body)
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
            height: GeekPanelLayout.overviewPowerCardHeight
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
                            .font(AdvancedPanelTypography.captionStrong)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(geekOverviewPowerModeText
                            ?? batteryElectricalSnapshot?.adapterName
                            ?? L10n.text("已连接", "Connected"))
                            .font(AdvancedPanelTypography.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(geekOverviewAdapterElectricalText)
                        .font(AdvancedPanelTypography.body)
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

    var geekChartHistory: [MenuBarTelemetryPoint] {
        history
    }

    /// The selected range, for the routed histories that read their own
    /// stores (disk, power): they always draw the selected window.
    var geekChartDuration: TimeInterval {
        selectedChartRange.duration
    }

    var geekChartRangeTitle: String {
        selectedChartRange.title
    }

    /// The window `geekChartHistory` covers (see "History windows"): the
    /// selected range once it is prepared, until then the previous one.
    var geekTelemetryChartDuration: TimeInterval {
        selectedDisplayedHistory.range.duration
    }

    var geekTelemetryChartRangeTitle: String {
        selectedDisplayedHistory.range.title
    }

    var geekTelemetryChartIsUpdating: Bool {
        selectedDisplayedHistory.isUpdating
    }

    var geekChartDiskHistory: [NativeDiskIOPoint] {
        nativeDiskIOHistory
    }

    func selectGeekSection(_ section: PanelSection) {
        panelCoordinator.selectModule(section)
    }

    func previewGeekSection(_ section: PanelSection) {
        panelCoordinator.previewModule(section)
    }

    func selectGeekHardwareDetail(_ focus: GeekHardwareDetailFocus) {
        panelCoordinator.selectHardwareDetail(focus)
    }

    func previewGeekHardwareDetail(_ focus: GeekHardwareDetailFocus) {
        panelCoordinator.previewHardwareDetail(focus)
    }

    var geekCleanupTiles: [AdvancedMetricTileModel] {
        [
            AdvancedMetricTileModel(id: "safe-bytes", title: L10n.text("可安全清理", "Safe Cleanup"), value: cleanupPageBytesText, detail: cleanupPageCountText, tint: AppDesignTokens.Palette.success, progress: nil),
            geekCleanupDiskTile,
            AdvancedMetricTileModel(id: "actionable", title: L10n.text("当前可操作", "Actionable Now"), value: cleanupActionableCountText, detail: cleanupActionableDetail, tint: AppDesignTokens.Palette.warning, progress: nil)
        ]
    }

    var geekCleanupDiskTile: AdvancedMetricTileModel {
        AdvancedMetricTileModel(id: "disk-free", title: L10n.text("启动卷可用", "Disk Available"),
                                value: storageSnapshot.map { ByteFormat.storageString($0.userAvailableBytes) } ?? "--",
                                detail: storagePressureTitle, tint: storageTint, progress: storageSnapshot?.userAvailableRatio)
    }

    var cleanupActionableCountText: String {
        String(actionableCleanupItems.count)
    }

    var cleanupActionableDetail: String {
        return actionableCleanupItems.isEmpty ? L10n.text("需重新扫描", "Rescan Required")
            : L10n.text("已加载明细", "Details Loaded")
    }

    var geekEnergyApps: [EnergyImpactApp] {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.preparedProcesses.energy }
#endif
        return store.menuBarPreparedProcesses?.energy ?? []
    }

    var geekShouldRefreshOnDemandSnapshot: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return false }
#endif
        return !store.isMenuBarRefreshPaused
            && store.canRefreshEnergyImpact
            && GeekOnDemandSnapshotFreshness.shouldRefresh(
                startedAt: (store.menuBarPreparedProcesses?.snapshot).map {
                    $0.generatedAt.addingTimeInterval(-max(0, $0.scanSeconds))
                }
            )
    }

    var geekOnDemandSnapshotStatusText: String {
        GeekOnDemandSnapshotFreshness.statusText(
            generatedAt: store.menuBarPreparedProcesses?.snapshot.generatedAt,
            isSampling: store.isMenuBarProcessSamplePending
        )
    }

    /// Review P2-8: the first measurement did not come in time.
    var geekOnDemandSnapshotNothingMeasured: Bool {
        store.isMenuBarProcessSampleUnavailable && store.menuBarPreparedProcesses == nil
    }

    var geekDiskReadRateText: String {
        guard let point = nativeDiskIOHistory.last else { return "--" }
        return "\(ByteFormat.string(point.readBytesPerSecond))/s"
    }

    var geekDiskWriteRateText: String {
        guard let point = nativeDiskIOHistory.last else { return "--" }
        return "\(ByteFormat.string(point.writeBytesPerSecond))/s"
    }

    var geekNetworkDownPeak: Int64? {
        networkChartHistory.compactMap { MenuBarTelemetryChannel.download.peak(in: $0) }.max().map { Int64(clampingHistoryValue: $0) }
    }

    var geekNetworkUpPeak: Int64? {
        networkChartHistory.compactMap { MenuBarTelemetryChannel.upload.peak(in: $0) }.max().map { Int64(clampingHistoryValue: $0) }
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
                    .font(AdvancedPanelTypography.body)
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
        HStack(alignment: .firstTextBaseline, spacing: MiniWindowStyleTokens.inlineSpacing) {
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
