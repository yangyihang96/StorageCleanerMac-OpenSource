import AppKit
import SwiftUI

enum GeekPanelContentProfile: Equatable, Sendable {
    case reduced
    case full

    var showsExtendedDetails: Bool {
        self == .full
    }

    func overviewModules(
        configuredModules: [GeekDashboardModuleConfiguration]
    ) -> [GeekDashboardModule] {
        configuredModules.filter { $0.isVisible && $0.module.isAvailableInOverview }.map(\.module)
    }
}

extension PanelDensity {
    var geekContentProfile: GeekPanelContentProfile? {
        switch self {
        case .simple:
            nil
        case .complex:
            .reduced
        case .geek:
            .full
        }
    }

    var usesGeekLayout: Bool {
        usesAttachedDetailPresentation
    }

    func auxiliaryDemand(
        for section: PanelSection,
        geekConfiguration: GeekDashboardConfiguration = .defaultValue,
        startsProcessLists: Bool = false
    ) -> MenuBarAuxiliaryMonitorDemand {
        let isOverview = self == .geek || (self == .complex && section == .overview)
        let visibleGeekModules = Set(
            geekConfiguration.modules
                .filter {
                    $0.isVisible && $0.module.isAvailableInOverview
                }
                .map(\.module)
        )
        let needsGeekOverviewDisk = isOverview
            && visibleGeekModules.contains(.disk)
        let needsGeekOverviewProcessor = isOverview
            && !visibleGeekModules.isDisjoint(with: [.processorGraphics, .sensors])
        var primaryKinds: Set<MenuBarMetricKind> = []
        if self == .simple { primaryKinds = MenuBarMetricKind.defaultSelection }
        if isOverview {
            if visibleGeekModules.contains(.coreMetrics) { primaryKinds.insert(.memoryUsage) }
            if visibleGeekModules.contains(.processorGraphics) { primaryKinds.formUnion([.cpuUsage, .gpuUsage]) }
            if visibleGeekModules.contains(.network) { primaryKinds.insert(.networkSpeed) }
            if visibleGeekModules.contains(.sensors) { primaryKinds.formUnion([.chipTemperature, .fanSpeed]) }
        }
        switch section {
        case .processor: primaryKinds.formUnion([.cpuUsage, .gpuUsage])
        case .memory: primaryKinds.insert(.memoryUsage)
        case .network: primaryKinds.insert(.networkSpeed)
        case .sensors: primaryKinds.formUnion([.chipTemperature, .fanSpeed])
        case .overview, .disk, .power, .cleanup: break
        }
        return MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: section == .processor
                || section == .sensors
                || needsGeekOverviewProcessor,
            needsDiskIOSampling: section == .disk
                || needsGeekOverviewDisk,
            needsNetworkInterface: section == .network
                || (self == .complex && section == .overview && visibleGeekModules.contains(.network)),
            needsPublicNetworkAddress: self == .geek
                && section == .network,
            // D167: the network page's app list, once its first frame is
            // drawn (was: only while a level-3 page was open).
            needsNetworkProcesses: self == .geek
                && section == .network && startsProcessLists,
            needsStorageVolumes: section == .disk,
            // D119: the sensors page shows the power, current and voltage rows.
            needsPowerTelemetry: section == .power || section == .sensors,
            needsChargeLimit: usesGeekLayout && section == .power,
            needsStorageCapacity: section == .disk || needsGeekOverviewDisk,
            needsBattery: section == .power || section == .sensors
                || (isOverview && visibleGeekModules.contains(.power)),
            primaryKinds: primaryKinds
        )
    }
}

struct MenuBarAdvancedStatusView: View {
    // Retain the delivery across routing without subscribing the overview.
    @State var cleanupDetailsModel = MiniWindowCleanupDetailsModel()
    @State private var historyDemandID = UUID()
    @State var reportedInternalBatteryAvailability = InternalBatteryAvailability.unknown
    let store: ScanStore
    let computerHealthStore: ComputerHealthStore
    let monitorState: MenuBarMonitorState
    let auxiliaryState: MenuBarAuxiliaryMonitorState
    @ObservedObject var panelSettingsState: MenuBarPanelSettingsState
    @ObservedObject var panelCoordinator: GeekPanelCoordinator
    let fanControl: FanControlCoordinator
    let presentation: PanelDensity
    let onSectionChange: ((PanelSection) -> Void)?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.panelChartAccentColor) var panelChartAccentColor
    @Environment(\.panelMetricColors) var panelMetricColors

    @State var measuredDetailContentMeasurement: GeekDetailContentMeasurement?
    @State var activeTertiaryDetail: MenuBarTertiaryDetail?
    @State var activeInlineTertiaryRequest: GeekInlineTertiaryRequest?
    @State var measuredTertiaryContentMeasurement: GeekTertiaryContentMeasurement?
    @State var tertiaryHoverIntent: GeekPanelCoordinator.HoverIntent?
    @State var isTertiaryDetailSurfaceHovered = false
    @State var overviewPanelSize = GeekPanelPresentationMetrics.overviewSize
    @State private var geekPanelDismissIntent: GeekPanelCoordinator.HoverIntent?
    @State var geekPanelHoverActivityState = GeekPanelHoverActivityState()
    @State var hasPrefetchedGeekDetails = false
    @State private var isChartPanelVisible = false
    @State private var isChartDisplayAwake = true
    @State private var isChartLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var chartThermalState = ProcessInfo.processInfo.thermalState
    // D136: the volumes hidden from the disk page (iStat's `Disks.Menu.Filtering`),
    // in the panel's preference store.
    @AppStorage(MiniWindowHiddenItems.disksKey) var hiddenDiskKeysRaw = ""

    init(
        store: ScanStore,
        computerHealthStore: ComputerHealthStore,
        panelSettingsState: MenuBarPanelSettingsState,
        panelCoordinator: GeekPanelCoordinator? = nil,
        presentation: PanelDensity = .geek,
        initialSection: PanelSection = .overview,
        onSectionChange: ((PanelSection) -> Void)? = nil,
        fanControl: FanControlCoordinator? = nil
    ) {
        self.store = store
        self.computerHealthStore = computerHealthStore
        monitorState = store.menuBarMonitorState
        auxiliaryState = store.menuBarAuxiliaryMonitorState
        _panelSettingsState = ObservedObject(wrappedValue: panelSettingsState)
        _hiddenDiskKeysRaw = AppStorage(wrappedValue: "", MiniWindowHiddenItems.disksKey,
                                        store: panelSettingsState.defaults)
        _panelCoordinator = ObservedObject(
            wrappedValue: panelCoordinator
                ?? GeekPanelCoordinator(initialSection: initialSection)
        )
        // Tests pass their own coordinator (no hardware helper connection).
        self.fanControl = fanControl ?? FanControlCoordinator.shared
        self.presentation = presentation
        self.onSectionChange = onSectionChange
    }

    var selectedSection: PanelSection {
        get { panelCoordinator.selectedSection }
        nonmutating set { panelCoordinator.selectModule(newValue) }
    }

    var selectedChartRangeMetric: GeekChartRangeMetric? {
        activeInlineTertiaryRequest?.chartRangeMetric
    }

    /// The history windows this page reads and their visible priority.
    var historyDemandPlan: MenuBarHistoryDemandPlan {
        MenuBarHistoryDemandPlan(
            settings: panelSettingsState,
            section: selectedSection,
            inlineMetric: selectedChartRangeMetric
        )
    }

    var selectedChartRange: GeekChartRange {
        historyDemandPlan.selectedRange
    }

    var historyReferenceDate: Date {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.referenceDate }
#endif
        return Date()
    }

    // MARK: History windows
    //
    // A chart draws a prepared window. Right after another range is selected
    // that window does not exist yet, so every chart reads its points and the
    // window they cover from one slice (`MenuBarMonitorState.displayHistorySlice`):
    // the selected range once it is prepared, until then the range it drew
    // before. `selectedChartRange` and `historyDemandPlan` stay the selection
    // (the picker's label and the demand); the accessors below are what the
    // charts draw.

    var history: [MenuBarTelemetryPoint] {
        selectedDisplayedHistory.points
    }

    /// Facts about `history` for the sensors pages: prepared with the window
    /// off the main thread; computed here only without a prepared window
    /// (demo data, tests).
    var historySummary: MenuBarTelemetryWindowSummary {
        let displayed = selectedDisplayedHistory
        return displayed.summary ?? MenuBarTelemetryWindowSummary(points: displayed.points)
    }

    /// The open history's (or the page's) points and window.
    var selectedDisplayedHistory: MenuBarDisplayedHistory {
        displayedHistory(
            slot: selectedChartRangeMetric?.storageKey ?? "section.\(selectedSection.rawValue)",
            range: selectedChartRange
        )
    }

    var cpuChartRange: GeekChartRange {
        cpuDisplayedHistory.range
    }

    var cpuChartHistory: [MenuBarTelemetryPoint] {
        cpuDisplayedHistory.points
    }

    var cpuDisplayedHistory: MenuBarDisplayedHistory {
        displayedHistory(slot: GeekChartRangeMetric.cpu.storageKey, range: historyDemandPlan.cpuRange)
    }

    /// The CPU reading shown as "now" (D39, `MenuBarDisplayedHistory.currentReading`).
    var cpuCurrentReading: MenuBarTelemetryPoint? {
        currentReading(of: cpuDisplayedHistory)
    }

    /// "Now" beside `displayed`: its last point while it is current, the live
    /// snapshot while it is not prepared or still a kept/previous window (D39).
    func currentReading(of displayed: MenuBarDisplayedHistory) -> MenuBarTelemetryPoint? {
        displayed.currentReading(live: monitorSnapshot.map(MenuBarTelemetryPoint.init(snapshot:)))
    }

    var networkChartRange: GeekChartRange {
        networkDisplayedHistory.range
    }

    var networkChartHistory: [MenuBarTelemetryPoint] {
        networkDisplayedHistory.points
    }

    var networkDisplayedHistory: MenuBarDisplayedHistory {
        displayedHistory(slot: GeekChartRangeMetric.network.storageKey, range: historyDemandPlan.networkRange)
    }

    /// The inline memory histories read the memory metric's own range.
    var memoryHistory: [MenuBarTelemetryPoint] {
        metricDisplayedHistory(.memory).points
    }

    /// A memory history opened by route reads the page's range, the one its
    /// label and picker use (first review, P2-1).
    var routedMemoryDisplayedHistory: MenuBarDisplayedHistory {
        displayedHistory(slot: "route.memory", range: historyDemandPlan.routedMemoryRange, memory: true)
    }

    /// The window a metric's charts draw.
    func geekMetricRange(_ metric: GeekChartRangeMetric) -> GeekChartRange {
        metricDisplayedHistory(metric).range
    }

    func geekMetricHistory(_ metric: GeekChartRangeMetric) -> [MenuBarTelemetryPoint] {
        metricDisplayedHistory(metric).points
    }

    /// The metric's charts still draw the previous window while the selected
    /// one is prepared; the histories pass it to their plot block.
    func geekMetricIsUpdating(_ metric: GeekChartRangeMetric) -> Bool {
        metricDisplayedHistory(metric).isUpdating
    }

    private func metricDisplayedHistory(_ metric: GeekChartRangeMetric) -> MenuBarDisplayedHistory {
        let selected = panelSettingsState.geekChartRange(for: metric, fallbackTo: selectedSection)
        switch metric {
        case .cpu:
            return cpuDisplayedHistory
        case .network:
            return networkDisplayedHistory
        case .gpu, .temperature, .fan:
            return displayedHistory(slot: metric.storageKey, range: selected)
        case .memory:
            return displayedHistory(slot: metric.storageKey, range: selected, memory: true)
        case .disk, .battery, .energy:
            // These histories are read from their own stores; nothing is
            // prepared for them, so they always draw the selected range.
            return MenuBarDisplayedHistory(points: [], range: selected, isUpdating: false)
        }
    }

    /// Exactly `range`, without a previous window to fall back to (the
    /// snapshot-capture routes, which never switch ranges).
    private func telemetryHistory(for range: GeekChartRange) -> [MenuBarTelemetryPoint] {
        displayedHistory(slot: "range.\(range.rawValue)", range: range).points
    }

    private func displayedHistory(
        slot: String,
        range: GeekChartRange,
        memory: Bool = false
    ) -> MenuBarDisplayedHistory {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            let points = memory
                ? monitorState.memoryHistory(within: range.duration, referenceDate: historyReferenceDate)
                : monitorState.history(within: range.duration, referenceDate: historyReferenceDate)
            return MenuBarDisplayedHistory(points: points, range: range, isUpdating: false)
        }
#endif
        let slice = monitorState.displayHistorySlice(slot: slot, within: range.duration, memory: memory)
        return MenuBarDisplayedHistory(
            points: slice.points,
            range: GeekChartRange(rawValue: Int(slice.duration)) ?? range,
            isUpdating: slice.isUpdating,
            summary: slice.summary
        )
    }

    private var displayHistoryDurations: [TimeInterval] {
        historyDemandPlan.durations
    }

    var showsExtendedGeekDetails: Bool {
        presentation.geekContentProfile?.showsExtendedDetails == true
    }

    var hasActiveTertiary: Bool {
        activeTertiaryDetail != nil || activeInlineTertiaryRequest != nil
    }

    var activeDetailPreferredSize: CGSize {
        let preferredSize: CGSize?
        if let measurement = measuredDetailContentMeasurement,
           measurement.section == selectedSection,
           measurement.density == presentation {
            preferredSize = measurement.size
        } else {
            preferredSize = nil
        }
        return GeekPanelPresentationMetrics.normalizedDetailSize(
            preferredSize,
            for: selectedSection,
            density: presentation
        )
    }

    var activeTertiaryPreferredSize: CGSize {
        if let request = activeInlineTertiaryRequest {
            guard let measurement = measuredTertiaryContentMeasurement,
                  measurement.density == presentation,
                  measurement.requestID == request.id else {
                return request.preferredSize
            }
            return GeekPanelPresentationMetrics.normalizedTertiarySize(
                CGSize(
                    width: request.preferredSize.width,
                    height: measurement.size.height
                )
            )
        }
        let measuredSize: CGSize?
        if let measurement = measuredTertiaryContentMeasurement,
           measurement.density == presentation {
            let matchesDetail = activeTertiaryDetail != nil
                && measurement.requestID == nil
                && measurement.detail == activeTertiaryDetail
            measuredSize = matchesDetail ? measurement.size : nil
        } else {
            measuredSize = nil
        }
        return GeekPanelPresentationMetrics.normalizedTertiarySize(
            measuredSize
        )
    }

    var activeTertiarySourceOffset: CGFloat? {
        activeInlineTertiaryRequest?.sourceOffset
    }

    var storageSnapshot: StorageCapacitySnapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.storageSnapshot
        }
#endif
        return auxiliaryState.storageSnapshot
    }
    var externalStorageVolumes: [MountedStorageVolumeSnapshot] {
        auxiliaryState.externalStorageVolumes
    }
    var networkStorageVolumes: [MountedStorageVolumeSnapshot] {
        auxiliaryState.networkStorageVolumes
    }
    var storageRefreshedAt: Date? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.referenceDate }
#endif
        return auxiliaryState.storageRefreshedAt
    }
    var batterySnapshot: BatteryPowerSnapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.batterySnapshot
        }
#endif
        return auxiliaryState.batterySnapshot
    }
    var batteryElectricalSnapshot: NativeBatteryElectricalSnapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.batteryElectricalSnapshot
        }
#endif
        return auxiliaryState.batteryElectricalSnapshot
    }
    /// D57: the power page's "功耗" readings.
    var powerTelemetry: MenuBarPowerTelemetry? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.powerTelemetry
        }
#endif
        return auxiliaryState.powerTelemetry
    }
    /// "Now" for the power readings' staleness (the demo's fixed date).
    var powerTelemetryReferenceDate: Date {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.referenceDate }
#endif
        return Date()
    }
    var batteryChargeLimitState: BatteryChargeLimitState? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.chargeLimitState()
        }
#endif
        return auxiliaryState.batteryChargeLimitState
    }
    var batteryRefreshedAt: Date? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.referenceDate }
#endif
        return auxiliaryState.batteryRefreshedAt
    }
    var networkInterfaceSnapshot: NativeNetworkInterfaceSnapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.networkInterfaceSnapshot
        }
#endif
        return auxiliaryState.networkInterfaceSnapshot
    }
    var networkTopologySnapshot: NetworkTopologySnapshot? {
        auxiliaryState.networkTopologySnapshot
    }
    var publicNetworkAddressSnapshot: PublicNetworkAddressSnapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.publicNetworkAddressSnapshot(for:
                MiniWindowDemoData.capturedMenuBarPanelScenario(arguments: ProcessInfo.processInfo.arguments))
        }
#endif
        return auxiliaryState.publicNetworkAddressSnapshot
    }
    var isRefreshingPublicNetworkAddress: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return false }
#endif
        return auxiliaryState.isRefreshingPublicNetworkAddress
    }
    var networkProcessSnapshot: NativeNetworkProcessSnapshot? {
        auxiliaryState.networkProcessSnapshot
    }
    var networkProcessSamplingState: MenuBarNetworkProcessSamplingState {
        auxiliaryState.networkProcessSamplingState
    }
    var processorTelemetry: CPUPerformanceStateService.Snapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.processorTelemetry(for:
                MiniWindowDemoData.capturedMenuBarPanelScenario(arguments: ProcessInfo.processInfo.arguments))
        }
#endif
        return auxiliaryState.processorTelemetry
    }
    var volumeName: String {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.volumeName }
#endif
        return auxiliaryState.volumeName
    }
    var isRefreshingLocalData: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return false }
#endif
        return auxiliaryState.isRefreshingLocalData
    }
    var nativeDiskIOCounters: NativeDiskIOCounters? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.nativeDiskIOCounters
        }
#endif
        return auxiliaryState.nativeDiskIOCounters
    }
    var nativeDiskIOHistory: [NativeDiskIOPoint] {
        let points: [NativeDiskIOPoint]
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            points = MiniWindowDemoData.nativeDiskIOHistory
        } else {
            points = auxiliaryState.nativeDiskIOHistory
        }
#else
        points = auxiliaryState.nativeDiskIOHistory
#endif
        return points
    }
    var powerHistory: [MenuBarPowerHistoryPoint] { batteryPowerHistory }

    /// Raw shared battery history. The compact preview and the tertiary
    /// historical chart intentionally apply their own ranges to this source.
    var batteryPowerHistory: [MenuBarPowerHistoryPoint] {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.powerHistory
        }
#endif
        return auxiliaryState.powerHistory
    }

    var healthSummary: MenuBarHealthSummary? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.healthSummary
        }
#endif
        return computerHealthStore.menuBarSummary
    }

    // Paired series keep stable semantic colors so they remain distinguishable
    // even when the panel uses a custom accent color.
    var resolvedPrimaryTint: Color {
        panelMetricColors.cpuUser
    }

    var resolvedSecondaryTint: Color {
        panelMetricColors.cpuSystem
    }

    var resolvedGPUTint: Color {
        panelMetricColors.gpu(chartAccent: panelChartAccentColor)
    }

    var resolvedThermalTint: Color {
        panelMetricColors.sensorGraph(chartAccent: panelChartAccentColor)
    }

    var resolvedEnergyTint: Color {
        panelChartAccentColor ?? panelMetricColors.battery
    }

    var resolvedUploadTint: Color {
        panelMetricColors.networkUpload
    }

    var resolvedDownloadTint: Color {
        panelMetricColors.networkDownload
    }

    var body: some View {
        PanelChartTimeline(
            duration: (geekVisibleOverviewModules.contains(.processorGraphics) || selectedSection == .processor)
                ? min(geekChartDuration, cpuChartRange.duration) : geekChartDuration,
            policy: ChartActivityPolicy(
                isPanelVisible: isChartPanelVisible,
                isDisplayAwake: isChartDisplayAwake,
                isLowPowerModeEnabled: isChartLowPowerModeEnabled,
                thermalState: chartThermalState,
                reduceMotion: reduceMotion
            ),
            sampleSource: monitorState
        ) {
            panelSurface
        }
        .menuBarPresentationProbe("presentation")
        .environment(\.menuBarChartContext, rootChartContext)
        .environment(\.menuBarCascadeDirection, panelSettingsState.cascadeDirection)
        .onChange(of: panelSettingsState.geekDashboardConfiguration) {
            panelCoordinator.reset()
        }
        .onReceive(auxiliaryState.internalBatteryAvailabilityPublisher) { availability in
            reportedInternalBatteryAvailability = availability
            if availability == .absent && selectedSection == .power {
                panelCoordinator.reset()
            }
        }
        .environment(\.panelAutomaticRefreshPaused, store.isMenuBarRefreshPaused)
        .environment(\.panelStoredSampleDate, monitorSnapshot?.generatedAt)
        .environment(\.geekPanelHoverCoordinator, panelCoordinator)
        .environment(
            \.geekPanelHoverEnvelopeActive,
            panelCoordinator.isPointerWithinHoverEnvelope
        )
        .environment(\.geekKeyboardHighlight, panelCoordinator.keyboardHighlight)
        .environment(\.geekKeyboardRowOpenRequest, panelCoordinator.rowOpenRequest)
        .environment(
            \.menuBarTertiaryPresentationMode,
            panelSettingsState.tertiaryPresentationMode
        )
        .environment(\.geekInlineTertiaryEvent, handleInlineTertiaryEvent)
        .environment(
            \.geekInlineTertiaryActiveRequestID,
            activeInlineTertiaryRequest?.id
        )
        .environment(
            \.geekChartRangeSelection,
            GeekChartRangeSelection(
                range: selectedChartRange,
                select: selectGeekChartRange,
                rangeForMetric: { metric in
                    panelSettingsState.geekChartRange(for: metric, fallbackTo: selectedSection)
                },
                selectForMetric: { range, metric in
                    panelSettingsState.setGeekChartRange(range, for: metric)
                }
            )
        )
        .background {
            MenuBarAdvancedSamplingCoordinator(
                store: store,
                monitorState: monitorState,
                auxiliaryState: auxiliaryState,
                panelSettingsState: panelSettingsState,
                presentation: presentation,
                selectedSection: selectedSection
            )
        }
        .task(id: displayHistoryDurations) {
            monitorState.updateDisplayHistoryConsumer(historyDemandID, durations: displayHistoryDurations)
        }
        .onAppear {
            let appearStartedAt = MenuBarPresentationTrace.uptime
            defer { MenuBarPresentationTrace.span("root.onAppear", from: appearStartedAt) }
            isChartPanelVisible = true
            isChartDisplayAwake = true
            isChartLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            chartThermalState = ProcessInfo.processInfo.thermalState
#if DEBUG || STORAGE_CLEANER_BETA
            if !MiniWindowDemoData.isEnabled {
                MenuBarSamplingContext.shared.refreshVisibleRead("helper.connection") { [fanControl] in
                    await fanControl.refreshConnection()
                }
                MenuBarSamplingContext.shared.refreshVisibleRead("power.modes-read") { [computerHealthStore] in
                    await computerHealthStore.refreshBatteryPowerModes()
                }
            }
#else
            MenuBarSamplingContext.shared.refreshVisibleRead("helper.connection") { [fanControl] in
                await fanControl.refreshConnection()
            }
            MenuBarSamplingContext.shared.refreshVisibleRead("power.modes-read") { [computerHealthStore] in
                await computerHealthStore.refreshBatteryPowerModes()
            }
#endif
            guard presentation.usesGeekLayout else { return }
            resetAttachedPanelNavigation()
        }
        .onChange(of: presentation) {
            guard presentation.usesGeekLayout else { return }
            reconcileAttachedPanelAfterDensityChange()
        }
        .onChange(of: selectedSection) {
            resetTertiaryHoverState()
            activeTertiaryDetail = nil
            activeInlineTertiaryRequest = nil
            if selectedSection == .overview {
                cancelGeekPanelDismissal()
                geekPanelHoverActivityState.reset()
            }
            if presentation.usesGeekLayout {
                MenuBarStatusController.shared.setGeekPanelSection(
                    selectedSection,
                    preferredDetailSize: selectedSection == .overview ? nil : activeDetailPreferredSize
                )
            }
            onSectionChange?(selectedSection)
        }
        .onChange(of: panelCoordinator.route) {
            synchronizeViewWithPanelRoute()
        }
        .onChange(of: panelCoordinator.isPointerWithinHoverEnvelope) {
            if !panelCoordinator.isPointerWithinHoverEnvelope {
                // Native cascade geometry is authoritative after a frame move;
                // discard SwiftUI hover callbacks from the previous layout.
                geekPanelHoverActivityState.reset()
            }
            if !panelCoordinator.isPointerWithinHoverEnvelope,
               let detail = activeTertiaryDetail,
               !isTertiaryDetailSurfaceHovered {
                scheduleTertiaryDetailDismissal(detail)
            }
            reconcileGeekPanelDismissal()
        }
        .onChange(of: hasActiveTertiary) {
            synchronizeTertiaryPresentation()
            reconcileGeekPanelDismissal()
        }
        .onChange(of: activeTertiaryDetail) {
            synchronizeTertiaryPresentation()
        }
        .onChange(of: activeInlineTertiaryRequest?.id) {
            synchronizeTertiaryPresentation()
        }
        .onChange(of: panelSettingsState.tertiaryPresentationMode) {
            if panelSettingsState.tertiaryPresentationMode == .unavailable {
                resetTertiaryHoverState()
                activeTertiaryDetail = nil
                activeInlineTertiaryRequest = nil
            }
            reconcileGeekPanelDismissal()
        }
        .onDisappear {
            monitorState.updateDisplayHistoryConsumer(historyDemandID, durations: [])
            isChartPanelVisible = false
            resetTertiaryHoverState()
            cancelGeekPanelDismissal()
            MenuBarStatusController.shared.setGeekPanelTertiaryPresented(false)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.NSProcessInfoPowerStateDidChange
            )
            .receive(on: DispatchQueue.main)
        ) { _ in
            isChartLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: ProcessInfo.thermalStateDidChangeNotification
            )
            .receive(on: DispatchQueue.main)
        ) { _ in
            chartThermalState = ProcessInfo.processInfo.thermalState
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.screensDidSleepNotification
            )
            .receive(on: DispatchQueue.main)
        ) { _ in
            isChartDisplayAwake = false
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.screensDidWakeNotification
            )
            .receive(on: DispatchQueue.main)
        ) { _ in
            isChartDisplayAwake = true
        }
    }

    private func selectGeekChartRange(_ range: GeekChartRange) {
        if let metric = selectedChartRangeMetric {
            panelSettingsState.setGeekChartRange(range, for: metric)
        } else {
            panelSettingsState.setGeekChartRange(range, for: selectedSection)
        }
    }

    private func resetTertiaryHoverState() {
        cancelTertiaryHoverIntent()
        isTertiaryDetailSurfaceHovered = false
    }

    func cancelTertiaryHoverIntent() {
        guard let tertiaryHoverIntent else { return }
        panelCoordinator.invalidateHoverIntent(tertiaryHoverIntent)
        self.tertiaryHoverIntent = nil
    }

    private func resetAttachedPanelNavigation() {
        resetTertiaryHoverState()
        cancelGeekPanelDismissal()
        activeTertiaryDetail = nil
        activeInlineTertiaryRequest = nil
        panelCoordinator.reset()
        geekPanelHoverActivityState.reset()
        MenuBarStatusController.shared.setGeekPanelSection(.overview)
    }

    private func reconcileAttachedPanelAfterDensityChange() {
        resetTertiaryHoverState()
        activeTertiaryDetail = nil
        activeInlineTertiaryRequest = nil
        geekPanelHoverActivityState.reset()
        MenuBarStatusController.shared.setGeekPanelSection(
            selectedSection,
            preferredDetailSize: selectedSection == .overview ? nil : activeDetailPreferredSize
        )
    }

    /// Charts outside live cards are prepared again only for a new window
    /// (bounds and count are in the key). The level-three page keeps this
    /// context inside its card, whose revision changes with every reading it
    /// follows.
    var rootChartContext: MenuBarChartContext {
        MenuBarChartContext(page: selectedSection.rawValue, revision: MenuBarDisplayRevision(sampledAt: nil, version: 0))
    }

    @ViewBuilder
    private var panelSurface: some View {
        if presentation.usesGeekLayout, selectedSection != .overview {
            GeekAttachedPanelShell(
                section: selectedSection,
                density: presentation,
                overviewSize: overviewPanelSize,
                direction: panelSettingsState.cascadeDirection,
                presentationMode: panelSettingsState.secondaryPresentationMode,
                tertiaryPresentationMode: panelSettingsState.tertiaryPresentationMode,
                cascadeLayout: panelSettingsState.cascadeLayout,
                detailPreferredSize: activeDetailPreferredSize,
                showsTertiary: hasActiveTertiary,
                tertiaryPreferredSize: activeTertiaryPreferredSize,
                tertiarySourceOffset: activeTertiarySourceOffset,
                onHoverChange: geekAttachedPanelHoverChanged,
                detailOwnsScrolling: selectedSection == .cleanup && store.cleanupFeatureConfiguration.mode != .legacy
            ) {
                tertiaryDetailRootHost {
                    liveCurrentContent
                }
            } overview: {
                liveGeekOverview
            } tertiary: {
                tertiaryDetailColumnSurface
            }
            .environment(\.geekPanelHoverActivity, geekPanelHoverActivityChanged)
        } else {
            PanelShell(
                density: presentation,
                preferredSize: overviewPanelSize,
                showsHeader: false,
                showsNavigation: false
            ) {
                EmptyView()
            } navigation: {
                EmptyView()
            } content: {
                liveCurrentContent
            }
            .menuBarPresentationProbe("summary")
        }
    }


    private func geekAttachedPanelHoverChanged(
        _ region: GeekAttachedPanelRegion,
        _ hovering: Bool
    ) {
        geekPanelHoverActivityState.setShellRegion(region, hovered: hovering)
        reconcileGeekPanelDismissal()
    }

    private func geekPanelHoverActivityChanged(_ id: UUID, _ active: Bool) {
        geekPanelHoverActivityState.setDetailTarget(id, active: active)
        reconcileGeekPanelDismissal()
    }

    @discardableResult
    private func handleInlineTertiaryEvent(_ event: GeekInlineTertiaryEvent) -> Bool {
        switch event {
        case let .present(request):
            guard panelCoordinator.presentHistory(
                .inline(request.id),
                pinned: request.isPinned
            ) else { return false }
            activeTertiaryDetail = nil
            activeInlineTertiaryRequest = request
        case let .dismiss(id):
            guard activeInlineTertiaryRequest?.id == id else { return false }
            guard !panelCoordinator.isHistoryPinned else { return false }
            activeInlineTertiaryRequest = nil
            // D123: a row's page closes alone (was the whole unpinned
            // hierarchy); the module column follows its own rules, as a
            // submenu does in iStat Menus 7.30.
            panelCoordinator.dismissHistory()
        case let .updateSourceOffset(id, offset):
            guard GeekInlineTertiaryRequest.updateSourceOffset(
                id: id,
                offset: offset,
                currentRequest: &activeInlineTertiaryRequest,
                route: panelCoordinator.route
            ) else { return false }
            synchronizeTertiaryPresentation()
            return true
        }
        synchronizeTertiaryPresentation()
        reconcileGeekPanelDismissal()
        return true
    }

    /// D136: iStat's hide button appends the volume's key, rebuilds the
    /// menu and closes the submenu (`closeSubmenu`), pinned or not.
    func hideDiskVolume(_ key: String) {
        activeInlineTertiaryRequest = nil
        panelCoordinator.dismissHistory()
        synchronizeTertiaryPresentation()
        reconcileGeekPanelDismissal()
        hiddenDiskKeysRaw = MiniWindowHiddenItems.raw(appending: key, to: hiddenDiskKeysRaw)
    }

    private func synchronizeTertiaryPresentation() {
        MenuBarStatusController.shared.setGeekPanelTertiaryPresented(
            hasActiveTertiary,
            preferredSize: activeTertiaryPreferredSize,
            sourceOffset: activeTertiarySourceOffset
        )
    }

    private func synchronizeViewWithPanelRoute() {
        if case let .history(_, selection) = panelCoordinator.route {
            if case let .builtIn(rawValue) = selection {
                if let detail = MenuBarTertiaryDetail(rawValue: rawValue),
                   activeTertiaryDetail != detail {
                    activeInlineTertiaryRequest = nil
                    activeTertiaryDetail = detail
                }
#if DEBUG || STORAGE_CLEANER_BETA
                if rawValue == "debug.processor.activity",
                   activeInlineTertiaryRequest == nil {
                    presentDebugProcessorActivityHistory()
                }
                if let scenario = MiniWindowDemoData.MenuBarSnapshotScenario(
                    debugRouteIdentifier: rawValue
                ), activeInlineTertiaryRequest == nil {
                    presentDebugSnapshotScenario(scenario)
                }
#endif
            }
            return
        } else {
            resetTertiaryHoverState()
            activeTertiaryDetail = nil
            activeInlineTertiaryRequest = nil
        }
    }

#if DEBUG || STORAGE_CLEANER_BETA
    private func presentDebugProcessorActivityHistory() {
        let contentStore = GeekInlineTertiaryContentStore()
        contentStore.update(AnyView(
            MenuBarObservedObjectBoundary(model: panelSettingsState) {
                MenuBarObservedObjectBoundary(model: monitorState) {
                    let range = panelSettingsState.geekChartRange(for: .cpu, fallbackTo: .processor)
                    let points = telemetryHistory(for: range)
                    GeekProcessorActivityHoverDetail(
                        points: points,
                        duration: range.duration,
                        userValue: percentText(points.last?.cpuUser),
                        systemValue: percentText(points.last?.cpuSystem),
                        samplingInterval: store.menuBarRefreshInterval.seconds
                    )
                }
            }
        ))
        activeTertiaryDetail = nil
        activeInlineTertiaryRequest = GeekInlineTertiaryRequest(
            id: UUID(),
            accessibilityLabel: L10n.text(
                "CPU 活动历史",
                "CPU Activity History"
            ),
            chartRangeMetric: .cpu,
            preferredSize: GeekHoverDetailMetrics.cpuHistorySize,
            isPinned: true,
            sourceOffset: 0,
            contentStore: contentStore,
            hoverChanged: { _ in }
        )
    }

    private func presentDebugSnapshotScenario(
        _ scenario: MiniWindowDemoData.MenuBarSnapshotScenario
    ) {
        let content: AnyView
        let preferredSize: CGSize
        let chartMetric: GeekChartRangeMetric?
        let accessibilityLabel: String

        switch scenario {
        case .memoryComposition:
            content = AnyView(GeekMemoryCompositionHistoryDetail(
                points: memoryHistory,
                duration: geekMetricRange(.memory).duration,
                composition: memorySnapshot?.ringComposition
            ))
            preferredSize = GeekMemoryCompositionHistoryDetail.preferredSize
            chartMetric = .memory
            accessibilityLabel = L10n.text("内存组成占比", "Memory Composition")
        case .gpuActivityHistory:
            content = AnyView(GeekGPUHoverDetail(
                points: geekChartHistory,
                duration: geekTelemetryChartDuration,
                isAvailable: metricAvailable(.gpuUsage),
                currentValue: metricValue(.gpuUsage),
                memoryValue: nil,
                temperatureValue: geekGPUTemperature.map {
                    IStatNumberFormat.temperature($0)
                }
            ))
            preferredSize = GeekGPUHoverDetail.popoverSize
            chartMetric = .gpu
            accessibilityLabel = L10n.text("GPU 活动历史", "GPU Activity History")
        case .cpuUsageInspector:
            content = AnyView(GeekProcessorUsageHoverDetail(
                total: cpuBreakdown?.totalPercent,
                applications: cpuBreakdown?.userPercent,
                system: cpuBreakdown?.systemPercent,
                points: geekChartHistory,
                duration: geekTelemetryChartDuration
            ))
            preferredSize = GeekHoverDetailMetrics.cpuUsageSize
            chartMetric = .cpu
            accessibilityLabel = L10n.text("CPU 使用率", "CPU Usage")
        case .cpuUptimeInspector:
            let poweredOnAt = monitorSnapshot?.systemBootAt.map {
                PanelTimestampFormat.monthDayAndTime($0)
            } ?? "—"
            let durations = uptimeBreakdownTexts
            let detail = GeekProcessorUptimeHoverDetail(
                poweredOnAt: poweredOnAt,
                awake: durations.awake,
                asleep: durations.asleep
            )
            content = AnyView(detail)
            preferredSize = detail.popoverSize
            chartMetric = nil
            accessibilityLabel = L10n.text("运行时间", "Uptime")
        case .diskVolumeInspector:
            let smartStatus = healthSummary?.diskSMARTStatus ?? .unavailable
            let detail = GeekDiskVolumeHoverDetail(
                snapshot: storageSnapshot,
                volumeName: volumeName,
                status: diskSMARTStatusText(smartStatus),
                temperature: nil,
                actions: .inert
            )
            content = AnyView(detail)
            preferredSize = detail.popoverSize
            chartMetric = nil
            accessibilityLabel = L10n.text("磁盘卷详情", "Disk Volume Detail")
        case .networkHistory:
            content = AnyView(GeekNetworkHistoryHoverDetail(
                points: geekChartHistory,
                duration: geekTelemetryChartDuration,
                uploadValue: networkUpText,
                downloadValue: networkDownText
            ))
            preferredSize = GeekNetworkHistoryHoverDetail.popoverSize
            chartMetric = .network
            accessibilityLabel = L10n.text("网络活动历史", "Network Activity History")
        case .networkVPNPPP, .networkVPNThirdParty, .networkVPNSystem,
             .networkVPNReadOnly, .networkVPNDisconnectConfirmation:
            guard let tunnel = MiniWindowDemoData.vpnTunnel(for: scenario) else { return }
            content = AnyView(GeekVPNHoverDetail(
                tunnel: tunnel,
                refresh: {},
                capabilityResolver: MiniWindowDemoData.vpnCapabilityResolver,
                initiallyConfirmsDisconnect: scenario == .networkVPNDisconnectConfirmation,
                controlAction: { _ in .unavailable(.unsupported) }
            ))
            preferredSize = GeekVPNHoverDetail.preferredSize(for: tunnel)
            chartMetric = nil
            accessibilityLabel = L10n.text("VPN 连接详情", "VPN Connection Details")
        case .fanControlFull, .fanControlAutoCompact:
            let presentation = ControlPalettePresentationState()
            presentation.present(.fan)
            let snapshotFanControl = makeDebugFanControlCoordinator()
            // D152: both scenarios show the one palette (no expanded details).
            content = AnyView(
                FanControlPaletteView(
                    presentation: presentation,
                    fanControl: snapshotFanControl,
                    telemetry: FanTelemetryState.resolve(snapshot: MiniWindowDemoData.fixture.snapshot),
                    thermalState: MiniWindowDemoData.hardwareControlProfile.thermalState
                )
                .controlSize(.small)
                .padding(GeekPanelLayout.contentPadding)
                .frame(width: ControlPaletteMetrics.fanSize.width, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
            )
            // Only an initial proposal; the existing inline geometry reader
            // measures the production content after layout.
            preferredSize = ControlPaletteMetrics.fanSize
            chartMetric = nil
            accessibilityLabel = L10n.text("风扇控制", "Fan Control")
        case .powerModeAndChargeTarget:
            content = AnyView(
                GeekEnergyModeHoverDetail(
                    batteryMode: .automatic,
                    batterySupportedModes: [.lowPower, .automatic, .highPower],
                    adapterMode: .automatic,
                    adapterSupportedModes: [.automatic, .highPower],
                    powerSource: .acPower,
                    isCharging: true,
                    showsChargeTargetSetting: true,
                    showsFullChargeAction: true,
                    chargeLimitState: MiniWindowDemoData.chargeLimitState(),
                    batteryPowerWatts: 0,
                    adapterPowerWatts: 94,
                    adjustmentState: .idle,
                    controlsEnabled: false,
                    chargeLimitControlsEnabled: false,
                    onChargeToFull: { .unsupported },
                    onSetChargeTarget: { _ in .unsupported },
                    onOpenBatterySettings: {},
                    onChangeMode: { _, _ in }
                )
                .controlSize(.small)
                .padding(GeekPanelLayout.contentPadding)
                .frame(width: ControlPaletteMetrics.powerSize.width, height: 440, alignment: .top)
            )
            preferredSize = CGSize(width: ControlPaletteMetrics.powerSize.width, height: 440)
            chartMetric = nil
            accessibilityLabel = L10n.text("电源模式与充电目标", "Power Modes and Charge Target")
        case .sensorGPUTemperature:
            content = AnyView(GeekSensorMetricHoverDetail(
                title: L10n.text("GPU 温度", "GPU Temperature"),
                currentValue: geekGPUTemperature.map {
                    IStatNumberFormat.temperature($0)
                } ?? "--",
                points: geekChartHistory,
                channel: .gpuTemperature,
                unit: .temperature,
                valueRange: 0...100,
                tint: resolvedGPUTint,
                duration: geekTelemetryChartDuration,
                secondaryTitle: metricAvailable(.gpuUsage)
                    ? L10n.text("负载", "Load")
                    : nil,
                secondaryValue: metricAvailable(.gpuUsage)
                    ? metricValue(.gpuUsage)
                    : nil
            ))
            preferredSize = GeekSensorMetricHoverDetail.popoverSize(
                extraRowCount: metricAvailable(.gpuUsage) ? 1 : 0,
                hasNote: false
            )
            chartMetric = .temperature
            accessibilityLabel = L10n.text("GPU 温度历史", "GPU Temperature History")
        case .sensorCPUTemperature:
            content = AnyView(GeekSensorMetricHoverDetail(
                title: L10n.text("CPU 温度", "CPU Temperature"),
                currentValue: metricValue(.chipTemperature),
                points: geekChartHistory,
                channel: .chipTemperature,
                unit: .temperature,
                valueRange: 0...100,
                tint: temperatureTint,
                duration: geekTelemetryChartDuration,
                secondaryTitle: L10n.text("频率", "Frequency"),
                secondaryValue: processorTelemetry?.clusters
                    .compactMap(\.frequencyMHz)
                    .max()
                    .map(processorFrequencyText) ?? "--"
            ))
            preferredSize = GeekSensorMetricHoverDetail.popoverSize(extraRowCount: 1, hasNote: false)
            chartMetric = .temperature
            accessibilityLabel = L10n.text("CPU 温度历史", "CPU Temperature History")
        case .powerChipBreakdown, .powerBacklightDetail, .powerBatteryRowDetail,
             .powerChipBreakdownUltra, .powerChipWithoutCPU, .powerSystemDetail:
            let readouts = switch scenario {
            case .powerChipBreakdownUltra:
                geekDebugPowerReadouts(soc: MiniWindowDemoData.socPowerReading(
                    channelWatts: MiniWindowDemoData.ultraPowerChannelWatts
                ))
            case .powerChipWithoutCPU:
                geekDebugPowerReadouts(soc: MiniWindowDemoData.socPowerReading(
                    channelWatts: MiniWindowDemoData.powerChannelWattsWithoutCPU
                ))
            default:
                geekPowerReadouts
            }
            let id = switch scenario {
            case .powerBacklightDetail: "power-backlight"
            case .powerSystemDetail: "power-system"
            case .powerBatteryRowDetail: "power-battery"
            default: "power-chip"
            }
            guard let readout = readouts.first(where: { $0.id == id }) else { return }
            content = AnyView(GeekSensorReadoutDetail(readout: readout))
            preferredSize = GeekSensorReadoutLayout.detailSize(readout)
            chartMetric = nil
            accessibilityLabel = readout.title
        case .powerBatteryDetail:
            let detail = GeekBatteryElectricalHoverDetail(
                electrical: batteryElectricalSnapshot,
                cycleCount: healthSummary?.batteryCycleCount ?? batteryElectricalSnapshot?.cycleCount,
                condition: healthSummary?.batteryCondition.map(batteryConditionText),
                chargePercent: batterySnapshot?.chargePercent,
                healthPercent: healthSummary?.batteryCapacityPercent,
                statusText: batteryStatusTitle,
                isCharging: batterySnapshot?.isCharging,
                chargeTargetPercent: batteryChargeLimitState?.target.rawValue,
                remainingTimeMinutes: batterySnapshot?.remainingTimeMinutes,
                runtimeEstimate: batteryRuntimeEstimate
            )
            content = AnyView(detail)
            preferredSize = detail.popoverSize
            chartMetric = nil
            accessibilityLabel = L10n.text("电池与充电三级详情", "Battery and Charging Deep Detail")
        case .sensorCPURowDetail, .sensorPalmRestDetail:
            let zone: SystemTemperatureZone = scenario == .sensorCPURowDetail ? .chip : .palmRest
            guard let detail = geekDebugTemperatureDetail(zone) else { return }
            content = detail.view
            preferredSize = detail.size
            chartMetric = .temperature
            accessibilityLabel = L10n.text("温度三级详情", "Temperature Deep Detail")
        case .sensorHardwareProbes:
            let detail = geekDebugHardwareProbesDetail
            content = detail.view
            preferredSize = detail.size
            chartMetric = nil
            accessibilityLabel = L10n.text("全部核心与硬件温度", "All Core & Hardware Temperatures")
        case .sensorAmbientLightDetail:
            guard let readout = geekDebugAmbientLightReadout else { return }
            content = AnyView(GeekSensorReadoutDetail(readout: readout))
            preferredSize = GeekSensorReadoutLayout.detailSize(readout)
            chartMetric = nil
            accessibilityLabel = readout.title
        case .sensorFanSpeedHistory:
            let readings = geekFanTelemetry.readings
            content = AnyView(GeekFanHoverDetail(
                points: geekChartHistory,
                duration: geekTelemetryChartDuration,
                currentValue: readings.first?.displayRPM ?? "--",
                readings: readings,
                valueRange: 0...fanTrendMaximum,
                selectedFanIndex: readings.first?.index
            ))
            preferredSize = GeekFanHoverDetail.popoverSize(selectedFanIndex: readings.first?.index,
                                                           readingCount: readings.count)
            chartMetric = .fan
            accessibilityLabel = L10n.text("风扇转速历史", "Fan Speed History")
        default:
            return
        }

        let contentStore = GeekInlineTertiaryContentStore()
        contentStore.update(content)
        activeTertiaryDetail = nil
        activeInlineTertiaryRequest = GeekInlineTertiaryRequest(
            id: UUID(),
            accessibilityLabel: accessibilityLabel,
            chartRangeMetric: chartMetric,
            preferredSize: preferredSize,
            isPinned: true,
            sourceOffset: 0,
            contentStore: contentStore,
            hoverChanged: { _ in }
        )
    }

    @MainActor
    private func makeDebugFanControlCoordinator() -> FanControlCoordinator {
        let defaults = UserDefaults(suiteName: "StorageCleanerMac.Snapshot.FanControl")!
        return FanControlCoordinator.makeReadOnlyFixture(
            defaults: defaults,
            profile: MiniWindowDemoData.hardwareControlProfile,
            snapshot: MiniWindowDemoData.fixture.snapshot
        )
    }
#endif

    func updateMeasuredDetailContentSize(
        _ size: CGSize,
        for section: PanelSection,
        density: PanelDensity
    ) {
        guard section == selectedSection,
              density == presentation,
              section != .overview,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else { return }
        let normalized = GeekPanelPresentationMetrics.normalizedDetailSize(
            size,
            for: section,
            density: density
        )
        let measurement = GeekDetailContentMeasurement(
            section: section,
            density: density,
            size: normalized
        )
        guard measuredDetailContentMeasurement != measurement else { return }
        measuredDetailContentMeasurement = measurement
        MenuBarStatusController.shared.setGeekPanelDetailSize(normalized)
    }

    func updateMeasuredTertiaryContentSize(
        _ size: CGSize,
        for detail: MenuBarTertiaryDetail?,
        requestID: UUID?,
        density: PanelDensity
    ) {
        let matchesCurrentDetail = requestID == nil
            && activeInlineTertiaryRequest == nil
            && activeTertiaryDetail == detail
        let matchesCurrentRequest = activeTertiaryDetail == nil
            && requestID != nil
            && activeInlineTertiaryRequest?.id == requestID
        guard density == presentation,
              matchesCurrentDetail || matchesCurrentRequest,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else { return }
        let normalized = GeekPanelPresentationMetrics.normalizedTertiarySize(
            CGSize(
                width: activeInlineTertiaryRequest?.preferredSize.width
                    ?? GeekPanelPresentationMetrics.tertiarySize.width,
                height: size.height.rounded(.up)
            )
        )
        let measurement = GeekTertiaryContentMeasurement(
            detail: detail,
            requestID: requestID,
            density: density,
            size: normalized
        )
        guard measuredTertiaryContentMeasurement != measurement else { return }
        measuredTertiaryContentMeasurement = measurement
        synchronizeTertiaryPresentation()
    }

    private func reconcileGeekPanelDismissal() {
        cancelGeekPanelDismissal()

        guard !geekPanelHoverActivityState.keepsPanelExpanded,
              !panelCoordinator.isPointerWithinHoverEnvelope,
              !panelCoordinator.isModulePinned,
              activeTertiaryDetail == nil,
              activeInlineTertiaryRequest == nil,
              presentation.usesGeekLayout,
              selectedSection != .overview else { return }

        geekPanelDismissIntent = panelCoordinator.scheduleHoverDismissal(
            condition: {
                !geekPanelHoverActivityState.keepsPanelExpanded
                    && !panelCoordinator.isPointerWithinHoverEnvelope
                    && !panelCoordinator.isModulePinned
                    && activeTertiaryDetail == nil
                    && activeInlineTertiaryRequest == nil
                    && selectedSection != .overview
            },
            action: {
                panelCoordinator.dismissUnpinnedModule()
                geekPanelDismissIntent = nil
            }
        )
    }

    private func cancelGeekPanelDismissal() {
        guard let geekPanelDismissIntent else { return }
        panelCoordinator.invalidateHoverIntent(geekPanelDismissIntent)
        self.geekPanelDismissIntent = nil
    }

    @ViewBuilder
    private var liveGeekOverview: some View {
        liveCard(.availability, page: MenuBarCardIdentity.overviewPage) { geekOverviewPage }
    }

    // Preserve the navigation erasure boundary and the per-card observation
    // scopes; overview opening must not construct unused detail pages.
    private var liveCurrentContent: AnyView {
        geekDetailPage
    }

    func openApp(filter: ReviewFilter) {
        store.showFilter(filter)
        MenuBarStatusController.shared.dismissPanel()
        MainWindowReopenCoordinator.shared.requestMainWindow()
    }
}

private struct MenuBarObservedObjectBoundary<Model: ObservableObject, Content: View>: View {
    @ObservedObject var model: Model
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

// Internal so runtime regressions can host this exact coordinator, with an
// isolated context rather than installing the resident status controller.
struct MenuBarAdvancedSamplingCoordinator: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var monitorState: MenuBarMonitorState
    let auxiliaryState: MenuBarAuxiliaryMonitorState
    @ObservedObject var panelSettingsState: MenuBarPanelSettingsState
    let presentation: PanelDensity
    let selectedSection: PanelSection
    let samplingContext: MenuBarSamplingContext

    init(store: ScanStore, monitorState: MenuBarMonitorState,
         auxiliaryState: MenuBarAuxiliaryMonitorState,
         panelSettingsState: MenuBarPanelSettingsState, presentation: PanelDensity,
         selectedSection: PanelSection,
         samplingContext: MenuBarSamplingContext = .shared) {
        self.store = store
        self.monitorState = monitorState
        self.auxiliaryState = auxiliaryState
        self.panelSettingsState = panelSettingsState
        self.presentation = presentation
        self.selectedSection = selectedSection
        self.samplingContext = samplingContext
    }

    /// D167: the open module page's process list (was: only with a level-3
    /// page open too).
    private var processSection: PanelSection? {
        guard hasPresentedFirstFrame,
              samplingContext.plan?.panelVisible != false else { return nil }
        return MenuBarProcessSamplingDemand.section(selectedSection)
    }

    @State private var consumerID = UUID()
    @State private var hasPresentedFirstFrame = false
    @State private var firstFrameTask: Task<Void, Never>?

    private var demand: MenuBarAuxiliaryMonitorDemand {
        presentation.auxiliaryDemand(
            for: selectedSection,
            geekConfiguration: panelSettingsState.geekDashboardConfiguration,
            startsProcessLists: hasPresentedFirstFrame
        )
    }

    private func scheduleFirstFrameDemand() {
        guard !hasPresentedFirstFrame, firstFrameTask == nil else { return }
        firstFrameTask = Task { @MainActor in
            await MenuBarSamplingContext.awaitPresentationTurn()
            guard !Task.isCancelled else { return }
            firstFrameTask = nil
            guard auxiliaryState.isConsumerRegistered(consumerID),
                  samplingContext.plan?.panelVisible != false else { return }
            hasPresentedFirstFrame = true
        }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                let appearStartedAt = MenuBarPresentationTrace.uptime
                defer { MenuBarPresentationTrace.span("sampling.onAppear", from: appearStartedAt) }
                // Declared after the first frame (D167: for the open module
                // page; was: only when a level-3 page was already open).
                scheduleFirstFrameDemand()
                MenuBarPresentationTrace.measure("aux.consumer") {
                    auxiliaryState.registerConsumer(
                        consumerID,
                        demand: demand,
                        paused: store.isMenuBarRefreshPaused
                    )
                }
                if monitorState.needsRefresh(
                    interval: store.menuBarRefreshInterval.seconds
                ) {
                    store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
                } else {
                    store.refreshMenuBarMonitor()
                }
            }
            .onChange(of: hasPresentedFirstFrame) {
                guard hasPresentedFirstFrame else { return }
                // Read the current route, not the view captured when the
                // opening task was scheduled.
                MenuBarPresentationTrace.measure("process.demand") {
                    store.updateMenuBarProcessConsumer(consumerID, section: processSection)
                }
                auxiliaryState.updateConsumer(consumerID, demand: demand)
            }
            .onReceive(samplingContext.planChanges.removeDuplicates()) { plan in
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                guard let plan else { return }
                if !plan.panelVisible {
                    firstFrameTask?.cancel()
                    firstFrameTask = nil
                    hasPresentedFirstFrame = false
                    store.updateMenuBarProcessConsumer(consumerID, section: nil)
                    return
                }
                // Cached panels need the same first-frame gate on each reopen.
                if !hasPresentedFirstFrame {
                    scheduleFirstFrameDemand()
                    return
                }
                store.updateMenuBarProcessConsumer(consumerID,
                    section: plan.panelVisible ? MenuBarProcessSamplingDemand.section(selectedSection) : nil)
            }
            .onChange(of: monitorState.snapshot?.generatedAt) {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                MenuBarPresentationTrace.measure("aux.refresh") {
                    auxiliaryState.refreshFromPrimaryMonitorUpdate()
                }
            }
            .onChange(of: selectedSection) {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                MenuBarPresentationTrace.measure("process.demand") {
                    store.updateMenuBarProcessConsumer(consumerID, section: processSection)
                }
                MenuBarPresentationTrace.measure("aux.consumer") {
                    auxiliaryState.updateConsumer(consumerID, demand: demand)
                }
                if selectedSection == .sensors {
                    store.refreshMenuBarMonitor()
                }
            }
            .onChange(of: presentation) {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                auxiliaryState.updateConsumer(consumerID, demand: demand)
            }
            .onChange(of: panelSettingsState.geekDashboardConfiguration) {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                auxiliaryState.updateConsumer(consumerID, demand: demand)
            }
            .onChange(of: store.isMenuBarRefreshPaused) {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                store.updateMenuBarProcessConsumer(consumerID, section: processSection)
                auxiliaryState.setPaused(store.isMenuBarRefreshPaused)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
                .receive(on: DispatchQueue.main)) { _ in
                store.updateMenuBarProcessConsumer(consumerID, section: nil)
                auxiliaryState.setPaused(true)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .receive(on: DispatchQueue.main)) { _ in
                store.updateMenuBarProcessConsumer(consumerID, section: processSection)
                auxiliaryState.setPaused(store.isMenuBarRefreshPaused)
            }
            .onDisappear {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                firstFrameTask?.cancel()
                firstFrameTask = nil
                hasPresentedFirstFrame = false
                MenuBarPresentationTrace.measure("process.demand") {
                    store.updateMenuBarProcessConsumer(consumerID, section: nil)
                }
                MenuBarPresentationTrace.measure("aux.consumer") {
                    auxiliaryState.unregisterConsumer(consumerID)
                }
            }
    }
}
