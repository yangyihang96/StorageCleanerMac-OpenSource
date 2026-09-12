import AppKit
import SwiftUI

private typealias MenuBarTypography = MenuBarPanelTypography

struct MenuBarStatusView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var monitorState: MenuBarMonitorState
    @ObservedObject private var auxiliaryState: MenuBarAuxiliaryMonitorState
    @ObservedObject private var panelSettingsState: MenuBarPanelSettingsState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var auxiliaryConsumerID = UUID()

    init(store: ScanStore, panelSettingsState: MenuBarPanelSettingsState) {
        _store = ObservedObject(wrappedValue: store)
        _monitorState = ObservedObject(wrappedValue: store.menuBarMonitorState)
        _auxiliaryState = ObservedObject(wrappedValue: store.menuBarAuxiliaryMonitorState)
        _panelSettingsState = ObservedObject(wrappedValue: panelSettingsState)
    }

    var body: some View {
        PanelShell(density: .simple, showsNavigation: false) {
            panelHeader
        } navigation: {
            EmptyView()
        } content: {
            ZStack(alignment: .top) {
                Group {
                    switch selectedTab {
                    case .cleanup:
                        cleanupPage
                    case .overview:
                        systemStatusPage
                    case .processor, .memory, .disk, .network, .sensors, .power:
                        systemStatusPage
                    }
                }
                .id(selectedTab)
                .transition(AppMotionTokens.listTransition(reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(
                AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                value: selectedTab
            )
        }
        .onAppear {
            auxiliaryState.registerConsumer(
                auxiliaryConsumerID,
                demand: MenuBarAuxiliaryMonitorDemand(
                    needsProcessorTelemetry: false,
                    needsDiskIOSampling: false,
                    needsNetworkInterface: false,
                    needsPublicNetworkAddress: false,
                    needsNetworkProcesses: false
                ),
                paused: store.isMenuBarRefreshPaused
            )
            // Lightweight refresh keeps the first frame instant; the periodic
            // loop and explicit refresh still refresh the memory snapshot on
            // their own cadence instead of blocking panel open on a full scan.
            store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
        }
        .onChange(of: monitorState.snapshot?.generatedAt) {
            auxiliaryState.refreshFromPrimaryMonitorUpdate()
        }
        .onChange(of: store.isMenuBarRefreshPaused) {
            auxiliaryState.setPaused(store.isMenuBarRefreshPaused)
        }
        .onChange(of: panelSettingsState.refreshGeneration) {
            refreshAll()
        }
        .onDisappear {
            auxiliaryState.unregisterConsumer(auxiliaryConsumerID)
        }
        .alert(L10n.text("退出建议应用？", "Quit Suggested Apps?"), isPresented: memoryBatchQuitAlertBinding) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelQuitSelectedMemoryProcesses()
            }
            Button(L10n.text("正常退出", "Quit Normally"), role: .destructive) {
                store.confirmQuitSelectedMemoryProcesses()
            }
            .disabled(!store.canRequestMemoryQuitActions)
        } message: {
            if let summary = store.pendingMemoryQuitSummary {
                Text(
                    L10n.text(
                        "所选 \(summary.appCount) 个应用目前约占 \(ByteFormat.string(summary.estimatedBytes))；预计释放量以退出后的刷新重测为准。",
                        "The selected \(summary.appCount) apps currently use about \(ByteFormat.string(summary.estimatedBytes)); estimated release will be remeasured after quitting and refresh."
                    )
                )
            }
        }
    }

    private var panelHeader: some View {
        PanelHeader(
            store: store,
            state: panelSettingsState,
            title: selectedTab.title,
            updatedAt: compactUpdatedAt,
            unavailableText: compactUnavailableText,
            systemImage: selectedTab.systemImage,
            isConnected: monitorState.snapshot != nil,
            isRefreshing: auxiliaryState.isRefreshingLocalData,
            simpleSectionSelection: selectedTabBinding,
            showMainWindow: { openAppWindow(filter: .overview) },
            togglePause: { store.toggleMenuBarRefreshPaused() },
            refresh: refreshAll
        )
    }

    private var selectedTab: PanelSection {
        PanelSection.simpleChoices.contains(panelSettingsState.selectedSection)
            ? panelSettingsState.selectedSection
            : .overview
    }

    private var selectedTabBinding: Binding<PanelSection> {
        Binding {
            selectedTab
        } set: { section in
            panelSettingsState.selectSection(section)
        }
    }

    private var cleanupPage: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                cleanupOverview

                if let result = store.memoryOptimizationResult {
                    Divider()
                    resultBanner(result)
                        .transition(
                            AppMotionTokens.stateTransition(
                                reduceMotion: reduceMotion,
                                edge: .top
                            )
                        )
                }

                Divider()
                recommendationSection

                if !cleanupGroups.isEmpty {
                    Divider()
                    cleanupGroupRows
                }

                if showsCleanupQuickActions {
                    Divider()
                    cleanupQuickActions
                }
            }
            .animation(
                reduceMotion ? nil : AppMotionTokens.stateChange,
                value: store.memoryOptimizationResult != nil
            )
        }
        .scrollIndicators(.hidden)
    }

    private var cleanupOverview: some View {
        VStack(spacing: 4) {
            Text(cleanupSummaryValue)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)

            Text(cleanupSummaryLabel)
                .font(MenuBarTypography.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .accessibilityElement(children: .combine)
    }

    private var cleanupGroupRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(cleanupGroups.enumerated()), id: \.element.id) { index, group in
                MenuBarCleanupGroupRow(group: group, tint: steadyChromeTint)

                if index < cleanupGroups.count - 1 {
                    Divider()
                        .padding(.leading, 42)
                }
            }
        }
    }

    private var cleanupQuickActions: some View {
        VStack(spacing: 0) {
            if showsScanQuickAction {
                Button {
                    openAppWindow(filter: .overview)
                    if !store.isPreparingScan {
                        store.startScanRespectingAccessGuide()
                    }
                } label: {
                    MenuBarUtilityActionRow(
                        title: L10n.text("扫描缓存与开发文件", "Scan Caches and Build Files"),
                        systemImage: AppSymbols.Action.refresh,
                        tint: steadyChromeTint
                    )
                }
                .buttonStyle(ResponsivePlainButtonStyle())
            }

            if showsScanQuickAction && showsLargeFilesQuickAction {
                Divider()
                    .padding(.leading, 42)
            }

            if showsLargeFilesQuickAction {
                Button {
                    openAppWindow(filter: .largeFiles)
                } label: {
                    MenuBarUtilityActionRow(
                        title: L10n.text("分析磁盘空间", "Analyze Disk Space"),
                        systemImage: AppSymbols.Navigation.fileAnalysis,
                        tint: storageTint
                    )
                }
                .buttonStyle(ResponsivePlainButtonStyle())
            }
        }
    }

    private var showsCleanupQuickActions: Bool {
        showsScanQuickAction || showsLargeFilesQuickAction
    }

    private var showsScanQuickAction: Bool {
        guard !store.isPreparingScan else { return false }
        switch maintenanceRecommendation {
        case .firstScan, .repairAccess, .rescan, .currentScan:
            return false
        case .cleanup, .lowDisk, nil:
            return true
        }
    }

    private var showsLargeFilesQuickAction: Bool {
        maintenanceRecommendation != .lowDisk
    }

    private var systemStatusPage: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: systemMetricColumns, spacing: 0) {
                ForEach(systemStatusMetrics) { item in
                    MenuBarStatusMetricCell(
                        value: item.value,
                        title: item.title,
                        tint: item.tint,
                        progress: item.progress,
                        detail: item.detail
                    )
                    .frame(height: 76)
                }
            }
            .padding(.vertical, 4)
            .frame(height: 86, alignment: .top)

            Divider()

            networkSummaryRow

            GeekPrecisionNetworkChart(
                points: monitorState.history(
                    within: GeekChartWindow.defaultDuration + GeekChartWindow.futureSampleTolerance + 10
                ),
                accessibilityLabel: L10n.text("最近两分钟实时网络上下行", "Live network transfers over the last two minutes")
            )
                .frame(minHeight: 72, idealHeight: 78, maxHeight: 84)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var networkSummaryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: AppSymbols.Panel.networkGlobe)
                .font(MenuBarTypography.metricValue)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            networkMetricText(
                title: L10n.text("下载", "Download"),
                value: metric(for: .networkSpeed).value,
                systemImage: AppSymbols.Panel.download,
                tint: MenuBarNetworkPalette.download
            )

            Spacer(minLength: 8)

            networkMetricText(
                title: L10n.text("上传", "Upload"),
                value: networkUploadValue,
                systemImage: AppSymbols.Panel.upload,
                tint: MenuBarNetworkPalette.upload
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func networkMetricText(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        let displayValue = networkTransferDisplayValue(value)

        return Label {
            HStack(spacing: 3) {
                Text(title)
                    .font(MenuBarTypography.caption)
                    .foregroundStyle(.secondary)

                Text(displayValue)
                    .font(MenuBarTypography.metricValue)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(MenuBarTypography.captionStrong)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(displayValue)
    }

    private func networkTransferDisplayValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first,
              first == "↓" || first == "↑" else {
            return trimmed
        }
        return String(trimmed.dropFirst())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var recommendationSection: some View {
        Group {
            if store.isPreparingScan {
                scanningRecommendation
            } else if hasCurrentMemoryPressure,
                      let action = snapshot?.cleanupPlan.primaryAction,
                      action != .observe {
                memoryRecommendation(action: action)
            } else if let recommendation = maintenanceRecommendation {
                maintenanceRecommendationCard(recommendation)
            }
        }
        .animation(
            AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
            value: recommendationAnimationKey
        )
    }

    private var scanningRecommendation: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.activeScanStatusText ?? L10n.text("正在读取系统状态", "Reading system status"))
                    .font(MenuBarTypography.sectionTitle)
                Text(L10n.text("扫描会在主窗口继续", "The scan continues in the main window"))
                    .font(MenuBarTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func memoryRecommendation(action: MemoryCleanupPrimaryAction) -> some View {
        switch action {
        case .observe:
            EmptyView()
        case .quitHighUsageApps:
            if recommendedApps.isEmpty {
                MenuBarActionRecommendation(
                    title: L10n.text("内存压力较高", "Memory Pressure Is High"),
                    detail: L10n.text("打开内存工具查看可操作项", "Open Memory to review available actions"),
                    actionTitle: L10n.text("查看", "Review"),
                    systemImage: AppSymbols.Monitor.memory,
                    actionImage: AppSymbols.Panel.openProcesses,
                    tint: memoryTint
                ) {
                    openAppWindow(filter: .memory)
                }
            } else {
                recommendedAppsCard
            }
        }
    }

    private var recommendedAppsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                MenuBarSectionLabel(
                    title: L10n.text("可退出应用", "Quittable Apps"),
                    systemImage: AppSymbols.Panel.powerState,
                    tint: memoryTint
                )

                Text("\(recommendedAppCount)")
                    .font(MenuBarTypography.captionStrong)
                    .monospacedDigit()
                    .foregroundStyle(memoryTint)

                Spacer(minLength: 0)

                Button {
                    runMemoryAction()
                } label: {
                    Label(L10n.text("正常退出", "Quit"), systemImage: AppSymbols.Action.quit)
                        .font(MenuBarTypography.captionStrong)
                }
                .appButtonChrome(.primary)
                .controlSize(.small)
                .tint(memoryTint)
                .disabled(!store.canRequestMemoryQuitActions)
            }

            VStack(spacing: 0) {
                ForEach(Array(recommendedApps.enumerated()), id: \.element.id) { index, app in
                    MenuBarRecommendedAppRow(app: app)
                    if index < recommendedApps.count - 1 {
                        Divider()
                            .padding(.leading, 34)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func maintenanceRecommendationCard(_ recommendation: MaintenanceRecommendation) -> some View {
        MenuBarActionRecommendation(
            title: recommendationTitle(recommendation),
            detail: recommendationDetail(recommendation),
            actionTitle: recommendationActionTitle(recommendation),
            systemImage: recommendationIcon(recommendation),
            actionImage: recommendationActionIcon(recommendation),
            tint: recommendationTint(recommendation)
        ) {
            performRecommendation(recommendation)
        }
    }

    private func resultBanner(_ result: MemoryOptimizationResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: resultIcon(for: result.status))
                .font(MenuBarTypography.sectionTitle)
                .foregroundStyle(resultTint(for: result.status))
                .frame(width: 22, height: 22)

            Text(resultTitle(for: result.status))
                .font(MenuBarTypography.value)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var memoryBatchQuitAlertBinding: Binding<Bool> {
        Binding {
            store.pendingMemoryQuitSummary != nil
                && !store.pendingMemoryProcessesToQuit.isEmpty
                && store.isMemoryBatchQuitConfirmationPresentedInMenuBar
        } set: { _ in
            // Alert buttons explicitly confirm or cancel. SwiftUI's passive
            // dismissal write must not cancel a plan that is being confirmed.
        }
    }

    private var snapshot: MemorySnapshot? {
        store.memorySnapshot
    }

    private var displayMemorySnapshot: MemorySnapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return MiniWindowDemoData.memorySnapshot
        }
#endif
        return store.menuBarDisplayMemorySnapshot
    }

    private var storageSnapshot: StorageCapacitySnapshot? {
        auxiliaryState.storageSnapshot
    }

    private var recommendedApps: [MemoryAppUsage] {
        Array(
            (snapshot?.recommendedQuitApps ?? [])
                .filter { $0.canQuit && $0.bundlePath?.hasSuffix(".app") == true }
                .prefix(3)
        )
    }

    private var recommendedAppCount: Int {
        (snapshot?.recommendedQuitApps ?? [])
            .filter { $0.canQuit && $0.bundlePath?.hasSuffix(".app") == true }
            .count
    }

    private func metric(for kind: MenuBarMetricKind) -> SystemMonitorMetric {
        monitorState.snapshot?.metric(for: kind)
            ?? SystemMonitorMetric(
                kind: kind,
                value: "--",
                detail: L10n.text("读取中", "Reading"),
                isAvailable: false
            )
    }

    private var networkUploadValue: String {
        let network = metric(for: .networkSpeed)
        return network.isAvailable ? network.detail : "--"
    }

    private var systemMetricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 4)
    }

    private var systemStatusMetrics: [MenuBarStatusMetric] {
        [
            systemStatusMetric(
                for: .cpuUsage,
                title: "CPU",
                tint: usageTint(for: .cpuUsage, normal: neutralMetricTint)
            ),
            systemStatusMetric(
                for: .memoryUsage,
                title: L10n.text("内存", "Memory"),
                tint: memoryStatusTint
            ),
            systemStatusMetric(
                for: .chipTemperature,
                title: L10n.text("温度", "Temperature"),
                tint: processorTint
            ),
            MenuBarStatusMetric(
                id: "storage",
                value: storageUsageValue,
                title: L10n.text("磁盘", "Disk"),
                tint: storageSnapshot == nil
                    ? AppDesignTokens.Palette.secondaryText
                    : storageTint,
                progress: storageSnapshot?.userUsedRatio,
                detail: storageSnapshot.map {
                    L10n.text(
                        "可用 \(ByteFormat.storageString($0.userAvailableBytes))",
                        "\(ByteFormat.storageString($0.userAvailableBytes)) available"
                    )
                } ?? L10n.text("读取中", "Reading")
            ),
        ]
    }

    private func systemStatusMetric(
        for kind: MenuBarMetricKind,
        title: String,
        tint: Color
    ) -> MenuBarStatusMetric {
        let resolved = metric(for: kind)
        return MenuBarStatusMetric(
            id: kind.id,
            value: resolved.value,
            title: title,
            tint: resolved.isAvailable ? tint : AppDesignTokens.Palette.secondaryText,
            progress: resolved.isAvailable ? metricProgress(resolved.value) : nil,
            detail: resolved.isAvailable ? resolved.detail : L10n.text("读取中", "Reading")
        )
    }

    private func metricProgress(_ value: String) -> Double? {
        let numeric = value.filter { $0.isNumber || $0 == "." }
        guard let percent = Double(numeric), percent.isFinite else { return nil }
        return min(1, max(0, percent / 100))
    }

    private var cleanupSummaryValue: String {
        guard let latestStatus = store.scanHistorySummary.latestStatus() else { return "--" }
        return ByteFormat.string(latestStatus.entry.greenBytes)
    }

    private var cleanupSummaryLabel: String {
        guard let latestStatus = store.scanHistorySummary.latestStatus() else {
            return L10n.text("等待首次扫描", "Waiting for first scan")
        }
        return L10n.text(
            "可安全清理 · \(latestStatus.entry.greenCount) 项",
            "Safe to clean · \(latestStatus.entry.greenCount) items"
        )
    }

    private var cleanupGroups: [MenuBarCleanupGroup] {
        let groupedItems = Dictionary(
            grouping: store.items(for: .green).filter(\.canMoveToTrash)
        ) { item in
            item.groupTitle.isEmpty ? item.kind : item.groupTitle
        }

        return Array(
            groupedItems.map { title, items in
                MenuBarCleanupGroup(
                    title: title,
                    itemCount: items.count,
                    bytes: items.reduce(Int64(0)) { $0 + $1.sizeBytes }
                )
            }
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(2)
        )
    }

    private var storageUsageValue: String {
        guard let storageSnapshot, storageSnapshot.totalBytes > 0 else { return "--" }
        return "\(storageSnapshot.userUsedPercent)%"
    }

    private var steadyChromeTint: Color {
        AppDesignTokens.Palette.steadyChrome
    }

    private var neutralMetricTint: Color {
        AppDesignTokens.Palette.primaryText
    }

    private var memoryTint: Color {
        switch displayMemorySnapshot?.reportablePressureLevel {
        case .critical:
            AppDesignTokens.Palette.destructive
        case .elevated:
            AppDesignTokens.Palette.warning
        case .normal:
            AppDesignTokens.Palette.success
        case .none:
            neutralMetricTint
        }
    }

    private var memoryStatusTint: Color {
        switch displayMemorySnapshot?.reportablePressureLevel {
        case .critical:
            AppDesignTokens.Palette.destructive
        case .elevated:
            AppDesignTokens.Palette.warning
        case .normal, .none:
            neutralMetricTint
        }
    }

    private var hasCurrentMemoryPressure: Bool {
        switch displayMemorySnapshot?.reportablePressureLevel {
        case .critical, .elevated:
            true
        case .normal, .none:
            false
        }
    }

    private var processorTint: Color {
        guard let temperatureCelsius else { return neutralMetricTint }
        if temperatureCelsius >= 90 { return AppDesignTokens.Palette.destructive
        }
        if temperatureCelsius >= 80 { return AppDesignTokens.Palette.warning
        }
        return neutralMetricTint
    }

    private var storageTint: Color {
        switch storageSnapshot?.pressure {
        case .critical:
            AppDesignTokens.Palette.destructive
        case .attention:
            AppDesignTokens.Palette.warning
        case .normal, .none:
            neutralMetricTint
        }
    }

    private func usageTint(for kind: MenuBarMetricKind, normal: Color) -> Color {
        let usage = metric(for: kind)
        guard usage.isAvailable else { return .secondary }
        let numeric = usage.value.filter { $0.isNumber || $0 == "." }
        guard let percent = Double(numeric) else { return normal }
        if percent >= 90 { return AppDesignTokens.Palette.destructive
        }
        if percent >= 75 { return AppDesignTokens.Palette.warning
        }
        return normal
    }

    private var temperatureCelsius: Double? {
        let temperature = metric(for: .chipTemperature)
        guard temperature.isAvailable else { return nil }
        let numeric = temperature.value.filter { $0.isNumber || $0 == "." }
        return Double(numeric)
    }

    private var maintenanceRecommendation: MaintenanceRecommendation? {
        guard let latestStatus = store.scanHistorySummary.latestStatus() else {
            return .firstScan
        }

        switch latestStatus.attentionLevel {
        case .permissionLimited:
            return .repairAccess(latestStatus.entry.deniedCount)
        case .rescanRecommended:
            return .rescan
        case .current:
            if latestStatus.entry.greenBytes > 0 {
                return .cleanup(
                    bytes: latestStatus.entry.greenBytes,
                    itemCount: latestStatus.entry.greenCount
                )
            }
            if storageSnapshot?.pressure != .normal {
                return .lowDisk
            }
            return .currentScan(latestStatus.entry.date)
        }
    }

    private var recommendationAnimationKey: String {
        if store.isPreparingScan { return "scanning" }
        if hasCurrentMemoryPressure,
           let action = snapshot?.cleanupPlan.primaryAction,
           action != .observe {
            return "memory-\(String(describing: action))-\(recommendedAppCount)"
        }
        return String(describing: maintenanceRecommendation)
    }

    private func recommendationTitle(_ recommendation: MaintenanceRecommendation) -> String {
        switch recommendation {
        case .firstScan:
            L10n.text("检查可清理空间", "Check Cleanable Space")
        case .repairAccess:
            L10n.text("扫描范围受限", "Scan Access Is Limited")
        case .rescan:
            L10n.text("建议更新扫描结果", "Refresh Scan Results")
        case .cleanup(let bytes, _):
            L10n.text("可安全清理 \(ByteFormat.string(bytes))", "\(ByteFormat.string(bytes)) Safe to Clean")
        case .lowDisk:
            L10n.text("磁盘空间偏紧", "Storage Is Running Low")
        case .currentScan:
            L10n.text("智能扫描", "Smart Scan")
        }
    }

    private func recommendationDetail(_ recommendation: MaintenanceRecommendation) -> String {
        switch recommendation {
        case .firstScan:
            L10n.text("尚未完成智能扫描", "No Smart Scan yet")
        case .repairAccess(let count):
            L10n.text("\(count) 个位置需要检查权限", "Check access for \(count) locations")
        case .rescan:
            L10n.text("上次结果已过期", "The previous result is out of date")
        case .cleanup(_, let itemCount):
            L10n.text("\(itemCount) 项可在确认后移到废纸篓", "\(itemCount) items can move to Trash after review")
        case .lowDisk:
            L10n.text("建议检查占用较大的文件", "Review files using the most space")
        case .currentScan(let date):
            L10n.lastScan(shortTime(date))
        }
    }

    private func recommendationActionTitle(_ recommendation: MaintenanceRecommendation) -> String {
        switch recommendation {
        case .firstScan:
            L10n.text("扫描", "Scan")
        case .repairAccess:
            L10n.text("检查", "Check")
        case .rescan:
            L10n.text("重新扫描", "Rescan")
        case .cleanup:
            L10n.text("查看", "Review")
        case .lowDisk:
            L10n.text("磁盘分析", "Disk Analysis")
        case .currentScan:
            L10n.text("重新扫描", "Rescan")
        }
    }

    private func recommendationIcon(_ recommendation: MaintenanceRecommendation) -> String {
        switch recommendation {
        case .firstScan, .rescan:
            "sparkles"
        case .repairAccess:
            "lock.open"
        case .cleanup:
            "trash.slash"
        case .lowDisk:
            "externaldrive.badge.exclamationmark"
        case .currentScan:
            "waveform.path.ecg.rectangle"
        }
    }

    private func recommendationActionIcon(_ recommendation: MaintenanceRecommendation) -> String {
        switch recommendation {
        case .firstScan, .rescan:
            "arrow.clockwise"
        case .repairAccess:
            "lock.open"
        case .cleanup:
            "chevron.right"
        case .lowDisk:
            "doc.text.magnifyingglass"
        case .currentScan:
            "arrow.clockwise"
        }
    }

    private func recommendationTint(_ recommendation: MaintenanceRecommendation) -> Color {
        switch recommendation {
        case .repairAccess, .lowDisk:
            AppDesignTokens.Palette.warning
        case .cleanup:
            AppDesignTokens.Palette.success
        case .firstScan, .rescan, .currentScan:
            steadyChromeTint
        }
    }

    private func performRecommendation(_ recommendation: MaintenanceRecommendation) {
        switch recommendation {
        case .firstScan, .repairAccess, .rescan, .currentScan:
            openAppWindow(filter: .overview)
            store.startScanRespectingAccessGuide()
        case .cleanup:
            openAppWindow(filter: .green)
        case .lowDisk:
            openAppWindow(filter: .largeFiles)
        }
    }

    private func runMemoryAction() {
        store.performRecommendedMemoryAction(presentConfirmationInMenuBar: true)
    }

    private func openAppWindow(filter: ReviewFilter) {
        store.showFilter(filter)
        MenuBarStatusController.shared.dismissPanel()
        MainWindowReopenCoordinator.shared.requestMainWindow()
    }

    private func refreshAll() {
        store.refreshMenuBarNow()
        auxiliaryState.requestManualRefresh()
    }

    private func shortTime(_ date: Date) -> String {
        PanelTimestampFormat.shortTime(date)
    }

    private var compactUpdatedAt: Date? {
        let date: Date?
        switch selectedTab {
        case .overview:
            date = monitorState.snapshot?.generatedAt
        case .cleanup:
            date = store.scanHistorySummary.latest?.date
        case .processor, .memory, .disk, .network, .sensors, .power:
            date = monitorState.snapshot?.generatedAt
        }

        return date
    }

    private var compactUnavailableText: String {
        selectedTab == .overview
            ? L10n.text("正在采样…", "Sampling…")
            : L10n.text("等待扫描", "Waiting for a scan")
    }

    private func resultTitle(for status: MemoryOptimizationStatus) -> String {
        switch status {
        case .completed:
            L10n.text("应用退出已验证", "App exits verified")
        case .partial:
            L10n.text("部分完成", "Partially completed")
        case .cancelled:
            L10n.text("已取消", "Cancelled")
        case .verificationFailed:
            L10n.text("结果无法验证", "Result not verified")
        case .notNeeded:
            L10n.text("无需处理", "No action needed")
        case .restricted:
            L10n.text("操作受系统限制", "Action restricted")
        case .timedOut:
            L10n.text("等待退出超时", "Quit timed out")
        case .unavailable:
            L10n.text("内存测量不可用", "Memory measurement unavailable")
        }
    }

    private func resultIcon(for status: MemoryOptimizationStatus) -> String {
        switch status {
        case .completed:
            "checkmark.circle.fill"
        case .notNeeded:
            "checkmark.seal.fill"
        case .partial, .restricted:
            "lock.fill"
        case .timedOut, .verificationFailed:
            "clock.badge.exclamationmark"
        case .cancelled:
            "xmark.circle.fill"
        case .unavailable:
            "exclamationmark.triangle.fill"
        }
    }

    private func resultTint(for status: MemoryOptimizationStatus) -> Color {
        switch status {
        case .completed, .notNeeded:
            AppDesignTokens.Palette.success
        case .partial, .restricted, .timedOut, .verificationFailed:
            AppDesignTokens.Palette.warning
        case .cancelled:
            .secondary
        case .unavailable:
            AppDesignTokens.Palette.destructive
        }
    }
}

private struct MenuBarCleanupGroup: Identifiable {
    let title: String
    let itemCount: Int
    let bytes: Int64

    var id: String { title }
}

private struct MenuBarStatusMetric: Identifiable {
    let id: String
    let value: String
    let title: String
    let tint: Color
    let progress: Double?
    let detail: String
}

private enum MaintenanceRecommendation: Equatable {
    case firstScan
    case repairAccess(Int)
    case rescan
    case cleanup(bytes: Int64, itemCount: Int)
    case lowDisk
    case currentScan(Date)
}

private struct MenuBarStatusMetricCell: View {
    let value: String
    let title: String
    let tint: Color
    let progress: Double?
    let detail: String

    var body: some View {
        PanelCircularGauge(
            title: title,
            value: value,
            progress: progress,
            tint: tint,
            detail: detail,
            size: 48
        )
        .frame(maxWidth: .infinity)
    }
}

private struct MenuBarCleanupGroupRow: View {
    let group: MenuBarCleanupGroup
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: AppSymbols.Panel.archive)
                .font(MenuBarTypography.symbol)
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(MenuBarTypography.value)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(L10n.text("\(group.itemCount) 项", "\(group.itemCount) items"))
                    .font(MenuBarTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(ByteFormat.string(group.bytes))
                .font(MenuBarTypography.value)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)

        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MenuBarUtilityActionRow: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(MenuBarTypography.symbol)
                .foregroundStyle(tint)
                .frame(width: 20)

            Text(title)
                .font(MenuBarTypography.value)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Image(systemName: AppSymbols.Panel.disclosure)
                .font(MenuBarTypography.captionStrong)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MenuBarActionRecommendation: View {
    let title: String
    let detail: String
    let actionTitle: String
    let systemImage: String
    let actionImage: String
    let tint: Color
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(MenuBarTypography.symbol)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MenuBarTypography.sectionTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(detail)
                    .font(MenuBarTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.91)
            }

            Spacer(minLength: 6)

            Button(action: action) {
                Label(actionTitle, systemImage: actionImage)
                    .font(MenuBarTypography.captionStrong)
            }
            .appButtonChrome(.primary)
            .controlSize(.small)
            .tint(tint)
            .disabled(!isEnabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct MenuBarSectionLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(MenuBarTypography.symbol)
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)

            Text(title)
                .font(MenuBarTypography.sectionTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MenuBarRecommendedAppRow: View {
    let app: MemoryAppUsage

    var body: some View {
        HStack(spacing: 7) {
            MenuBarProcessIcon(path: app.iconPath, fallbackSystemImage: "app.fill")

            HStack(spacing: 5) {
                Text(app.name)
                    .font(MenuBarTypography.value)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if app.processCount > 1 {
                    Text("x\(app.processCount)")
                        .font(MenuBarTypography.captionStrong)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            Text(ByteFormat.string(app.bytes))
                .font(MenuBarTypography.value)
                .monospacedDigit()
                .lineLimit(1)

            Text(String(format: "%.1f%%", app.percent))
                .font(MenuBarTypography.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 2)
        .frame(height: 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.text(
                "\(app.name)，合并 \(app.processCount) 个进程，内存 \(ByteFormat.string(app.bytes))",
                "\(app.name), \(app.processCount) merged processes, \(ByteFormat.string(app.bytes)) memory"
            )
        )
    }
}

private struct MenuBarProcessIcon: View {
    let path: String
    let fallbackSystemImage: String

    var body: some View {
        CachedAppIconView(
            path: path,
            size: 22
        ) {
            Image(systemName: fallbackSystemImage)
                .symbolRenderingMode(.hierarchical)
                .font(MenuBarTypography.value)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
            .frame(width: 26, height: 26)
            .shadow(color: AppDesignTokens.Elevation.subtleShadow, radius: 2, y: 1)
    }
}
