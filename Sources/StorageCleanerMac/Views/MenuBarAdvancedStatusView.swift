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
        switch self {
        case .reduced:
            return [
                .processorGraphics,
                .coreMetrics,
                .disk,
                .network,
                .sensors,
                .power,
            ]
        case .full:
            return configuredModules
                .filter {
                    $0.isVisible && $0.module.isAvailableInOverview
                }
                .map(\.module)
        }
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
        geekConfiguration: GeekDashboardConfiguration = .defaultValue
    ) -> MenuBarAuxiliaryMonitorDemand {
        let needsComplexOverviewTelemetry = self == .complex && section == .overview
        let visibleGeekModules = Set(
            geekConfiguration.modules
                .filter {
                    $0.isVisible && $0.module.isAvailableInOverview
                }
                .map(\.module)
        )
        let needsGeekOverviewDisk = self == .geek
            && visibleGeekModules.contains(.disk)
        let needsGeekOverviewProcessor = self == .geek
            && !visibleGeekModules.isDisjoint(with: [.processorGraphics, .sensors])
        return MenuBarAuxiliaryMonitorDemand(
            needsProcessorTelemetry: section == .processor
                || section == .sensors
                || needsComplexOverviewTelemetry
                || needsGeekOverviewProcessor,
            needsDiskIOSampling: section == .disk
                || needsComplexOverviewTelemetry
                || needsGeekOverviewDisk,
            needsNetworkInterface: section == .network
                || needsComplexOverviewTelemetry,
            needsPublicNetworkAddress: self == .geek
                && section == .network,
            needsNetworkProcesses: self == .geek
                && section == .network,
            needsStorageVolumes: section == .disk
        )
    }
}

struct MenuBarAdvancedStatusView: View {
    @State private var historyDemandID = UUID()
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

    @State var selectedRailSection = PanelSection.overview
    @State var measuredDetailContentMeasurement: GeekDetailContentMeasurement?
    @State var activeTertiaryDetail: MenuBarTertiaryDetail?
    @State var activeInlineTertiaryRequest: GeekInlineTertiaryRequest?
    @State var measuredTertiaryContentMeasurement: GeekTertiaryContentMeasurement?
    @State var tertiaryHoverIntent: GeekPanelCoordinator.HoverIntent?
    @State var hoveredTertiaryButton: MenuBarTertiaryDetail?
    @State var isTertiaryDetailSurfaceHovered = false
    @State var overviewPanelSize = GeekPanelPresentationMetrics.overviewSize
    @State private var geekPanelDismissIntent: GeekPanelCoordinator.HoverIntent?
    @State var geekPanelHoverActivityState = GeekPanelHoverActivityState()
    @State var hasPrefetchedGeekDetails = false
    @State private var isChartPanelVisible = false
    @State private var isChartDisplayAwake = true
    @State private var isChartLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var chartThermalState = ProcessInfo.processInfo.thermalState

    init(
        store: ScanStore,
        computerHealthStore: ComputerHealthStore,
        panelSettingsState: MenuBarPanelSettingsState,
        panelCoordinator: GeekPanelCoordinator? = nil,
        presentation: PanelDensity = .geek,
        initialSection: PanelSection = .overview,
        onSectionChange: ((PanelSection) -> Void)? = nil
    ) {
        self.store = store
        self.computerHealthStore = computerHealthStore
        monitorState = store.menuBarMonitorState
        auxiliaryState = store.menuBarAuxiliaryMonitorState
        _panelSettingsState = ObservedObject(wrappedValue: panelSettingsState)
        _panelCoordinator = ObservedObject(
            wrappedValue: panelCoordinator
                ?? GeekPanelCoordinator(initialSection: initialSection)
        )
        fanControl = FanControlCoordinator.shared
        _selectedRailSection = State(initialValue: initialSection)
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

    var selectedChartRange: GeekChartRange {
        if let metric = selectedChartRangeMetric {
            return panelSettingsState.geekChartRange(
                for: metric,
                fallbackTo: selectedSection
            )
        }
        return panelSettingsState.geekChartRange(for: selectedSection)
    }

    var historyReferenceDate: Date {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.referenceDate }
#endif
        return Date()
    }

    var history: [MenuBarTelemetryPoint] {
        telemetryHistory(for: selectedChartRange)
    }

    var cpuChartRange: GeekChartRange {
        panelSettingsState.geekChartRange(for: .cpu, fallbackTo: .processor)
    }

    var cpuChartHistory: [MenuBarTelemetryPoint] {
        telemetryHistory(for: cpuChartRange)
    }

    var networkChartRange: GeekChartRange {
        panelSettingsState.geekChartRange(for: .network, fallbackTo: .network)
    }

    var networkChartHistory: [MenuBarTelemetryPoint] {
        telemetryHistory(for: networkChartRange)
    }

    var memoryHistory: [MenuBarTelemetryPoint] {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return monitorState.memoryHistory(within: selectedChartRange.duration, referenceDate: historyReferenceDate) }
#endif
        return monitorState.displayHistory(within: selectedChartRange.duration, memory: true)
    }

    private func telemetryHistory(for range: GeekChartRange) -> [MenuBarTelemetryPoint] {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return monitorState.history(within: range.duration, referenceDate: historyReferenceDate) }
#endif
        return monitorState.displayHistory(within: range.duration)
    }

    private var displayHistoryDurations: Set<TimeInterval> {
        [selectedChartRange.duration, cpuChartRange.duration, networkChartRange.duration]
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
    var batteryChargeLimitState: BatteryChargeLimitState? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return BatteryChargeLimitState.resolve(
                manualLimitEnabled: true,
                manualLimit: 80,
                availableLimits: [80, 85, 90, 95, 100]
            )
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
            return MiniWindowDemoData.publicNetworkAddressSnapshot
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
            return MiniWindowDemoData.processorTelemetry
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
        AppChartPalette.cpuUser
    }

    var resolvedSecondaryTint: Color {
        AppChartPalette.cpuSystem
    }

    var resolvedGPUTint: Color {
        panelChartAccentColor ?? AppChartPalette.gpu
    }

    var resolvedThermalTint: Color {
        panelChartAccentColor ?? AppChartPalette.thermal
    }

    var resolvedEnergyTint: Color {
        panelChartAccentColor ?? AppChartPalette.energy
    }

    var resolvedUploadTint: Color {
        MenuBarNetworkPalette.upload
    }

    var resolvedDownloadTint: Color {
        MenuBarNetworkPalette.download
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
        .background {
            if MenuBarPresentationTrace.enabled {
                MenuBarPresentationProbe(key: "presentation")
            }
        }
        .environment(\.menuBarChartContext, MenuBarChartContext(
            page: selectedSection.rawValue, revision: MenuBarDisplayRevision(sampledAt: nil, version: 0)))
        .environment(\.menuBarCascadeDirection, panelSettingsState.cascadeDirection)
        .environment(\.panelAutomaticRefreshPaused, store.isMenuBarRefreshPaused)
        .environment(\.geekPanelHoverCoordinator, panelCoordinator)
        .environment(
            \.geekPanelHoverEnvelopeActive,
            panelCoordinator.isPointerWithinHoverEnvelope
        )
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
                select: selectGeekChartRange
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
            isChartPanelVisible = true
            isChartDisplayAwake = true
            isChartLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            chartThermalState = ProcessInfo.processInfo.thermalState
#if DEBUG || STORAGE_CLEANER_BETA
            if !MiniWindowDemoData.isEnabled {
                Task {
                    await fanControl.refreshConnection()
                }
                Task {
                    await computerHealthStore.refreshBatteryPowerModes()
                }
            }
#else
            Task {
                await fanControl.refreshConnection()
            }
            Task {
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
                MenuBarStatusController.shared.setGeekPanelSection(selectedSection)
                if selectedSection != .overview {
                    MenuBarStatusController.shared.setGeekPanelDetailSize(
                        activeDetailPreferredSize
                    )
                }
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
               hoveredTertiaryButton != detail,
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
        hoveredTertiaryButton = nil
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
        selectedRailSection = .overview
        geekPanelHoverActivityState.reset()
        MenuBarStatusController.shared.setGeekPanelSection(.overview)
    }

    private func reconcileAttachedPanelAfterDensityChange() {
        resetTertiaryHoverState()
        activeTertiaryDetail = nil
        activeInlineTertiaryRequest = nil
        geekPanelHoverActivityState.reset()
        MenuBarStatusController.shared.setGeekPanelSection(selectedSection)
        if selectedSection != .overview {
            MenuBarStatusController.shared.setGeekPanelDetailSize(
                activeDetailPreferredSize
            )
        }
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
                onHoverChange: geekAttachedPanelHoverChanged
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
            let hidesChrome = presentation.usesGeekLayout
            PanelShell(
                density: presentation,
                preferredSize: presentation.usesGeekLayout ? overviewPanelSize : nil,
                showsHeader: !hidesChrome,
                showsNavigation: !hidesChrome
            ) {
                liveHeader
            } navigation: {
                moduleRail
            } content: {
                liveCurrentContent
            }
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
            panelCoordinator.dismissUnpinnedHierarchy()
        }
        synchronizeTertiaryPresentation()
        reconcileGeekPanelDismissal()
        return true
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
            if panelCoordinator.route == .summary {
                selectedRailSection = .overview
            }
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
                duration: geekChartDuration,
                composition: memorySnapshot?.ringComposition
            ))
            preferredSize = GeekMemoryCompositionHistoryDetail.preferredSize
            chartMetric = .memory
            accessibilityLabel = L10n.text("内存组成占比", "Memory Composition")
        case .gpuActivityHistory:
            content = AnyView(GeekGPUHoverDetail(
                points: geekChartHistory,
                duration: geekChartDuration,
                isAvailable: metricAvailable(.gpuUsage),
                currentValue: metricValue(.gpuUsage),
                memoryValue: nil,
                temperatureValue: geekGPUTemperature.map {
                    String(format: "%.1f°C", $0)
                }
            ))
            preferredSize = GeekHoverDetailMetrics.historySize
            chartMetric = .gpu
            accessibilityLabel = L10n.text("GPU 活动历史", "GPU Activity History")
        case .cpuUsageInspector:
            content = AnyView(GeekProcessorUsageHoverDetail(
                total: cpuBreakdown?.totalPercent,
                applications: cpuBreakdown?.userPercent,
                system: cpuBreakdown?.systemPercent,
                points: geekChartHistory,
                duration: geekChartDuration
            ))
            preferredSize = GeekHoverDetailMetrics.cpuUsageSize
            chartMetric = .cpu
            accessibilityLabel = L10n.text("CPU 使用率", "CPU Usage")
        case .cpuUptimeInspector:
            let uptimeSeconds = monitorSnapshot?.systemUptimeSeconds ?? 0
            let poweredOnAt = uptimeSeconds > 0
                ? PanelTimestampFormat.monthDayAndTime(
                    historyReferenceDate.addingTimeInterval(-uptimeSeconds)
                )
                : "--"
            content = AnyView(GeekProcessorUptimeHoverDetail(
                uptime: uptimeText,
                poweredOnAt: poweredOnAt
            ))
            preferredSize = GeekHoverDetailMetrics.uptimeSize
            chartMetric = nil
            accessibilityLabel = L10n.text("运行时间", "Uptime")
        case .diskVolumeInspector:
            let smartStatus = healthSummary?.diskSMARTStatus ?? .unavailable
            content = AnyView(GeekDiskVolumeHoverDetail(
                snapshot: storageSnapshot,
                volumeName: volumeName,
                status: diskSMARTStatusText(smartStatus),
                temperature: nil
            ))
            preferredSize = GeekHoverDetailMetrics.volumeSize
            chartMetric = nil
            accessibilityLabel = L10n.text("磁盘卷详情", "Disk Volume Detail")
        case .networkHistory:
            content = AnyView(GeekNetworkHistoryHoverDetail(
                points: geekChartHistory,
                duration: geekChartDuration,
                uploadValue: networkUpText,
                downloadValue: networkDownText
            ))
            preferredSize = GeekHoverDetailMetrics.compactHistorySize
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
            let isExpanded = scenario == .fanControlFull
            content = AnyView(
                FanControlPaletteView(
                    presentation: presentation,
                    fanControl: snapshotFanControl,
                    telemetry: FanTelemetryState.resolve(snapshot: MiniWindowDemoData.fixture.snapshot),
                    thermalState: MiniWindowDemoData.hardwareControlProfile.thermalState,
                    showsExpandedControls: isExpanded
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
            accessibilityLabel = isExpanded
                ? L10n.text("完整风扇控制", "Full Fan Control")
                : L10n.text("紧凑风扇控制", "Compact Fan Control")
        case .powerModeAndChargeTarget:
            let seventy = BatteryChargeTarget(rawValue: 70)!
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
                    chargeLimitState: BatteryChargeLimitState(
                        target: .full,
                        availableTargets: [seventy, .protected, .full]
                    ),
                    batteryPowerWatts: 0,
                    adapterPowerWatts: 94,
                    adjustmentState: .idle,
                    controlsEnabled: true,
                    onChargeToFull: { .unsupported },
                    onSetChargeTarget: { _ in .unsupported },
                    onOpenBatterySettings: {},
                    onChangeMode: { _, _ in }
                )
                .controlSize(.small)
                .padding(GeekPanelLayout.contentPadding)
                .frame(width: 270, height: 440, alignment: .top)
            )
            preferredSize = CGSize(width: 270, height: 440)
            chartMetric = nil
            accessibilityLabel = L10n.text("电源模式与充电目标", "Power Modes and Charge Target")
        case .sensorGPUTemperature:
            content = AnyView(GeekSensorMetricHoverDetail(
                title: L10n.text("GPU 温度", "GPU Temperature"),
                currentValue: geekGPUTemperature.map {
                    String(format: "%.1f°C", $0)
                } ?? "--",
                points: geekChartHistory,
                channel: .gpuTemperature,
                unit: .temperature,
                valueRange: 0...100,
                tint: resolvedGPUTint,
                duration: geekChartDuration,
                secondaryTitle: metricAvailable(.gpuUsage)
                    ? L10n.text("负载", "Load")
                    : nil,
                secondaryValue: metricAvailable(.gpuUsage)
                    ? metricValue(.gpuUsage)
                    : nil
            ))
            preferredSize = GeekSensorPowerHoverDetailMetrics.sensorHistorySize
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
                duration: geekChartDuration,
                secondaryTitle: L10n.text("频率", "Frequency"),
                secondaryValue: processorTelemetry?.clusters
                    .compactMap(\.frequencyMHz)
                    .max()
                    .map(processorFrequencyText) ?? "--"
            ))
            preferredSize = GeekSensorPowerHoverDetailMetrics.sensorHistorySize
            chartMetric = .temperature
            accessibilityLabel = L10n.text("CPU 温度历史", "CPU Temperature History")
        case .sensorFanSpeedHistory:
            let readings = geekFanTelemetry.readings
            content = AnyView(GeekFanHoverDetail(
                points: geekChartHistory,
                duration: geekChartDuration,
                currentValue: readings.first?.displayRPM ?? "--",
                readings: readings,
                valueRange: 0...fanTrendMaximum,
                selectedFanIndex: readings.first?.index
            ))
            preferredSize = GeekSensorPowerHoverDetailMetrics.sensorHistorySize
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
    private var liveHeader: some View {
        MenuBarObservedObjectBoundary(model: store) {
            MenuBarObservedObjectBoundary(model: monitorState) {
                MenuBarObservedObjectBoundary(model: auxiliaryState) {
                    header
                }
            }
        }
    }

    @ViewBuilder
    private var liveCurrentContent: some View {
        if presentation.usesGeekLayout {
            currentContent
        } else {
        switch selectedSection {
        case .overview:
            MenuBarObservedObjectBoundary(model: store) {
                MenuBarObservedObjectBoundary(model: monitorState) {
                    MenuBarObservedObjectBoundary(model: auxiliaryState) {
                        MenuBarObservedObjectBoundary(model: computerHealthStore) {
                            MenuBarObservedObjectBoundary(model: fanControl) {
                                currentContent
                            }
                        }
                    }
                }
            }
        case .processor:
            MenuBarObservedObjectBoundary(model: store) {
                MenuBarObservedObjectBoundary(model: monitorState) {
                    MenuBarObservedObjectBoundary(model: auxiliaryState) {
                        currentContent
                    }
                }
            }
        case .memory:
            MenuBarObservedObjectBoundary(model: store) {
                MenuBarObservedObjectBoundary(model: monitorState) {
                    currentContent
                }
            }
        case .disk:
            MenuBarObservedObjectBoundary(model: store) {
                MenuBarObservedObjectBoundary(model: auxiliaryState) {
                    MenuBarObservedObjectBoundary(model: computerHealthStore) {
                        currentContent
                    }
                }
            }
        case .network:
            MenuBarObservedObjectBoundary(model: monitorState) {
                MenuBarObservedObjectBoundary(model: auxiliaryState) {
                    MenuBarObservedObjectBoundary(model: computerHealthStore) {
                        currentContent
                    }
                }
            }
        case .sensors:
            MenuBarObservedObjectBoundary(model: monitorState) {
                MenuBarObservedObjectBoundary(model: auxiliaryState) {
                    MenuBarObservedObjectBoundary(model: computerHealthStore) {
                        MenuBarObservedObjectBoundary(model: fanControl) {
                            currentContent
                        }
                    }
                }
            }
        case .power:
            MenuBarObservedObjectBoundary(model: store) {
                MenuBarObservedObjectBoundary(model: auxiliaryState) {
                    MenuBarObservedObjectBoundary(model: computerHealthStore) {
                        currentContent
                    }
                }
            }
        case .cleanup:
            MenuBarObservedObjectBoundary(model: store) {
                MenuBarObservedObjectBoundary(model: auxiliaryState) {
                    currentContent
                }
            }
        }
        }
    }

    @ViewBuilder
    private var liveGeekOverview: some View {
        liveCard(.availability) { geekOverviewPage }
    }

    // Keep the legacy presentation's large generic type out of the live
    // panel's host metadata. Only the requested presentation is constructed.
    private var currentContent: AnyView {
        if presentation.usesGeekLayout {
            return AnyView(geekDetailPage)
        } else {
            return AnyView(detailPage)
        }
    }

    @ViewBuilder
    var detailPage: some View {
        ScrollView(.vertical) {
            VStack(spacing: AppDesignTokens.Spacing.small) {
                switch selectedSection {
                case .overview:
                    overviewPage
                case .processor:
                    processorPage
                case .memory:
                    memoryPage
                case .disk:
                    diskPage
                case .network:
                    networkPage
                case .sensors:
                    sensorsPage
                case .power:
                    powerPage
                case .cleanup:
                    cleanupPage
                }

                if let detail = selectedSection.tertiaryDetail {
                    HStack {
                        Spacer(minLength: 0)
                        tertiaryDetailButton(detail)
                    }
                }
            }
            .padding(AppDesignTokens.Spacing.small)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

private struct MenuBarAdvancedSamplingCoordinator: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var monitorState: MenuBarMonitorState
    let auxiliaryState: MenuBarAuxiliaryMonitorState
    @ObservedObject var panelSettingsState: MenuBarPanelSettingsState
    let presentation: PanelDensity
    let selectedSection: PanelSection

    @State private var consumerID = UUID()

    private var demand: MenuBarAuxiliaryMonitorDemand {
        presentation.auxiliaryDemand(
            for: selectedSection,
            geekConfiguration: panelSettingsState.geekDashboardConfiguration
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                store.updateMenuBarProcessConsumer(consumerID, section: selectedSection)
                auxiliaryState.registerConsumer(
                    consumerID,
                    demand: demand,
                    paused: store.isMenuBarRefreshPaused
                )
                if monitorState.needsRefresh(
                    interval: store.menuBarRefreshInterval.seconds
                ) {
                    store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
                } else {
                    store.refreshMenuBarMonitor()
                }
            }
            .onChange(of: monitorState.snapshot?.generatedAt) {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                auxiliaryState.refreshFromPrimaryMonitorUpdate()
            }
            .onChange(of: selectedSection) {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                store.updateMenuBarProcessConsumer(consumerID, section: selectedSection)
                auxiliaryState.updateConsumer(consumerID, demand: demand)
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
                store.updateMenuBarProcessConsumer(consumerID, section: selectedSection)
                auxiliaryState.setPaused(store.isMenuBarRefreshPaused)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
                .receive(on: DispatchQueue.main)) { _ in
                store.updateMenuBarProcessConsumer(consumerID, section: nil)
                auxiliaryState.setPaused(true)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .receive(on: DispatchQueue.main)) { _ in
                store.updateMenuBarProcessConsumer(consumerID, section: selectedSection)
                auxiliaryState.setPaused(store.isMenuBarRefreshPaused)
            }
            .onDisappear {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                store.updateMenuBarProcessConsumer(consumerID, section: nil)
                auxiliaryState.unregisterConsumer(consumerID)
            }
    }
}
