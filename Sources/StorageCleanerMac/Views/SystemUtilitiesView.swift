import AppKit
import QuickLook
import ServiceManagement
import SwiftUI

private typealias UtilitySizing = AppControlSizes

struct SystemUtilitiesHubView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    @ObservedObject private var navigationState: AppNavigationState

    init(store: ScanStore) {
        self.store = store
        _navigationState = ObservedObject(wrappedValue: store.navigationState)
    }

    private var selectedTool: Binding<ReviewFilter> {
        Binding {
            let selected = navigationState.selectedUtilityFilter
            return ReviewFilter.utilityToolCases.contains(selected) ? selected : .memory
        } set: { newValue in
            guard ReviewFilter.utilityToolCases.contains(newValue) else { return }
            navigationState.select(newValue)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
                .transition(AppMotionTokens.pageTransition(reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : AppMotionTokens.navigation,
            value: selectedTool.wrappedValue
        )
        .onAppear {
            if !ReviewFilter.utilityToolCases.contains(navigationState.selectedUtilityFilter) {
                navigationState.select(.memory)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTool.wrappedValue {
        case .startup:
            StartupItemsView(store: store)
        case .memory:
            MemoryOptimizerView(store: store)
        case .energy:
            EnergyImpactView(store: store)
        case .uninstall:
            AppUninstallerView(store: store)
        case .updater:
            AppUpdaterView(store: store)
        case .overview, .healthHub, .performance, .green, .privacy, .devCaches, .largeFiles, .migration, .duplicates, .utilityHub,
             .cloudCleanup, .myTools, .myActivity, .extensions, .maintenance, .chatFiles:
            MemoryOptimizerView(store: store)
        }
    }
}

private extension ReviewFilter {
    var utilityTabTitle: String {
        switch self {
        case .startup:
            L10n.text("登录项与后台任务", "Login Items & Background Tasks")
        case .memory:
            L10n.text("内存", "Memory")
        case .energy:
            L10n.text("能耗", "Energy")
        case .uninstall:
            L10n.text("卸载", "Uninstall")
        case .updater:
            L10n.text("更新", "Updates")
        case .overview, .healthHub, .performance, .green, .privacy, .devCaches, .largeFiles, .migration, .duplicates, .utilityHub,
             .cloudCleanup, .myTools, .myActivity, .extensions, .maintenance, .chatFiles:
            title
        }
    }
}

struct StartupItemsView: View {
    @ObservedObject var store: ScanStore
    /// D202: Smart Care's Review shows its result here.
    @ObservedObject private var navigation: AppNavigationState
    /// D154 batch 2: the Maintenance tile on the Performance results (D161).
    @ObservedObject private var maintenance: SystemMaintenanceStore
    /// D143: the classic console, opened from the studio manager; tests of
    /// the D70 console set `careStudioClassicResults`.
    @Environment(\.careStudioClassicResults) private var usesClassicConsole
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
#else
    /// Release builds have no presentation fixtures (the key is DEBUG-only).
    private let isFixture = false
#endif
    @State private var showsClassicConsole = false
    /// Report §4 item 13: the recommended tasks the tile's Run Tasks asks
    /// about; these, as listed, are the ones that run (D168).
    @State private var maintenanceRunTasks: [SystemMaintenanceTaskID] = []
    @State private var confirmsMaintenanceRun = false

    init(store: ScanStore) {
        self.store = store
        _navigation = ObservedObject(wrappedValue: store.navigationState)
        _maintenance = ObservedObject(wrappedValue: ToolboxStores.of(store).maintenance)
    }

    /// D202: Smart Care's scan and result stay on Smart Care; this page keeps
    /// its landing for them (its Review excepted).
    private var showsOwnResult: Bool { store.moduleShowsResult(.performance) }

    var body: some View {
        Group {
            if store.isLoadingStartupItems && showsOwnResult {
                StartupItemsRunningPage(
                    title: store.startupScanProgress?.title ?? L10n.text("正在读取启动项", "Reading Startup Items"),
                    discoveredCount: store.startupScanProgress?.discoveredCount ?? store.startupDomainItems.count,
                    onCancel: store.cancelStartupScan)
            } else if !store.hasScannedStartupItems || !showsOwnResult {
                startupLanding
            } else if !showsClassicConsole && !usesClassicConsole {
                CareStudioStartupResultsPage(
                    items: store.startupDomainItems,
                    activeOperationCandidateID: store.isPerformingStartupOperation
                        ? store.pendingStartupOperationCandidate?.id
                        : nil,
                    isPerformingOperation: store.isPerformingStartupOperation,
                    coverageAction: AnyView(startupCoverageAction),
                    actions: studioActions,
                    onShowClassicList: { showsClassicConsole = true },
                    leadingTiles: [maintenanceTile], coverage: store.startupCoverage)
            } else {
                StartupItemsDashboardView(
                    items: store.startupDomainItems,
                    isLoading: store.isLoadingStartupItems,
                    progress: store.startupScanProgress,
                    activeOperationCandidateID: store.isPerformingStartupOperation
                        ? store.pendingStartupOperationCandidate?.id
                        : nil,
                    isPerformingOperation: store.isPerformingStartupOperation,
                    coverageAction: AnyView(startupCoverageAction),
                    // Ordinary refreshes stay fast and silent. The explicit Full Scan
                    // button below owns the bounded BTM diagnostic.
                    onRefresh: { store.refreshStartupItems() },
                    onCancel: { store.cancelStartupScan() },
                    onEnable: { store.requestStartupOperation(.enable, candidate: $0) },
                    onDisable: { store.requestStartupOperation(.disable, candidate: $0) },
                    onStop: { store.requestStartupOperation(.stopCurrentSession, candidate: $0) },
                    onReveal: { item in
                        let locations = item.components
                            .filter { $0.actionCapability.canRevealInFinder }
                            .compactMap { candidate in
                                candidate.plistURL
                                    ?? candidate.executableURL
                                    ?? candidate.applicationURL
                                    ?? candidate.attribution?.applicationURL
                            }
                        guard !locations.isEmpty else { return }
                        NSWorkspace.shared.activateFileViewerSelecting(locations)
                    },
                    onOpenParentApplication: { item in
                        guard let applicationURL = item.components.first(where: {
                            $0.actionCapability.canOpenParentApp
                        }).flatMap({ $0.attribution?.applicationURL ?? $0.applicationURL }) else {
                            return
                        }
                        NSWorkspace.shared.open(applicationURL)
                    },
                    onCopyText: { text in
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                    },
                    onOpenSystemSettings: { SMAppService.openSystemSettingsLoginItems() },
                    onUndo: store.canUndoLastStartupOperation ? { store.undoLastStartupOperation() } : nil
                )
                .overlay(alignment: .topTrailing) {
                    // Back to the studio cards (D143), placed as on the
                    // classic cleanup list.
                    if showsClassicConsole {
                        Button(L10n.text("返回卡片视图", "Back to Cards")) { showsClassicConsole = false }
                            .buttonStyle(.link)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.top, 14)
                            .padding(.trailing, 18)
                    }
                }
            }
        }
        // D154 batch 2: the maintenance states (read-only probes, D161) are
        // read with the scan the user starts, as CleanMyMac's Performance scan does.
        .onChange(of: store.isLoadingStartupItems) { _, loading in
            if loading, !isFixture, !maintenance.isRefreshing { maintenance.refresh() }
        }
        .featureFlowTransition(value: store.isLoadingStartupItems)
        .maintenanceRunConfirmation(maintenance, tasks: maintenanceRunTasks, isPresented: $confirmsMaintenanceRun) {
            maintenance.run(maintenanceRunTasks)
        }
        // D94: Undo is in the result controls only. A toolbar item here
        // would add a window toolbar to this page alone and move the
        // window buttons.
    }

    /// CleanMyMac's Performance results open with the maintenance tasks.
    private var maintenanceTile: CareStudioTileModel {
        .maintenance(maintenance, onReview: { store.showFilter(.maintenance) }) { tasks in
            maintenanceRunTasks = tasks
            confirmsMaintenanceRun = true
        }
    }

    private var startupLanding: some View {
        LightfieldStartupLandingView(items: store.startupDomainItems, canRefresh: store.canRefreshStartupItems,
            onStart: { store.refreshStartupItems() })
    }

    /// The same actions the classic console wires, for the studio manager.
    private var studioActions: CareStudioStartupActions {
        CareStudioStartupActions(
            onRefresh: { store.refreshStartupItems() },
            onEnable: { store.requestStartupOperation(.enable, candidate: $0) },
            onDisable: { store.requestStartupOperation(.disable, candidate: $0) },
            onStop: { store.requestStartupOperation(.stopCurrentSession, candidate: $0) },
            onReveal: { item in
                let locations = item.components
                    .filter { $0.actionCapability.canRevealInFinder }
                    .compactMap { candidate in
                        candidate.plistURL ?? candidate.executableURL ?? candidate.applicationURL
                            ?? candidate.attribution?.applicationURL
                    }
                guard !locations.isEmpty else { return }
                NSWorkspace.shared.activateFileViewerSelecting(locations)
            },
            onOpenParentApplication: { item in
                guard let applicationURL = item.components.first(where: {
                    $0.actionCapability.canOpenParentApp
                }).flatMap({ $0.attribution?.applicationURL ?? $0.applicationURL }) else { return }
                NSWorkspace.shared.open(applicationURL)
            },
            onCopyText: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            onOpenSystemSettings: { SMAppService.openSystemSettingsLoginItems() },
            onUndo: store.canUndoLastStartupOperation ? { store.undoLastStartupOperation() } : nil,
            onStartOver: { store.startOverStartupItems() },
            startOverActivity: store.heavyWorkActivityStore)
    }

    private var startupCoverageAction: some View {
        Button(startupCoverageActionTitle) {
            store.refreshStartupItems(includeBackgroundTaskDiagnostic: true)
        }
        .buttonStyle(FeatureLightfieldRowButtonStyle())
        .font(.system(size: 13))
        .disabled(!store.canRefreshStartupItems)
        .help(startupCoverageActionHelp)
    }

    private var startupCoverageActionTitle: String {
        if store.startupCoverage.managedItemCoverageAvailable {
            return L10n.text("系统项已读取", "System Items Read")
        }
        if store.startupCoverage.sources.contains(where: {
            $0.source == .backgroundTaskDiagnostic
                && $0.errorDescription != nil
        }) {
            return L10n.text("重试系统项", "Retry System Items")
        }
        return L10n.text("完整扫描", "Full Scan")
    }

    private var startupCoverageActionHelp: String {
        if let failure = store.startupCoverage.sources.first(where: {
            $0.source == .backgroundTaskDiagnostic
        })?.errorDescription {
            return L10n.text(
                "系统后台项读取诊断：\(failure)",
                "System background-item read diagnostic: \(failure)"
            )
        }
        if let help = StartupReadPresentation(coverage: store.startupCoverage).databaseReadHelp {
            return help
        }
        return L10n.text(
            "额外读取 macOS 登录项与后台任务数据库；系统可能要求管理员确认",
            "Also reads the macOS login-item and background-task database; the system may request administrator approval"
        )
    }

    private var startupCoverageActionSymbol: String {
        if store.startupCoverage.managedItemCoverageAvailable { return "checkmark.shield" }
        if store.startupCoverage.sources.contains(where: {
            $0.source == .backgroundTaskDiagnostic && $0.errorDescription != nil
        }) { return "exclamationmark.triangle" }
        return "shield.lefthalf.filled"
    }
}

extension CareStudioTileModel {
    /// Report §4 item 13 (`cmm/24` against `ours/04`): the Performance
    /// results' maintenance tile, "N maintenance tasks recommended" with
    /// Review and Run Tasks; the count is Smart Care's. Run Tasks hands over
    /// the recommended tasks that can run now, to be confirmed first
    /// (D154⑮); what is ticked on the maintenance page is not added.
    @MainActor
    static func maintenance(_ store: SystemMaintenanceStore, onReview: @escaping () -> Void,
                            onRun: @escaping ([SystemMaintenanceTaskID]) -> Void) -> CareStudioTileModel {
        let count = store.summary.recommendedCount
        return CareStudioTileModel(
            id: "maintenance", module: .startup,
            title: count > 0
                ? L10n.text("\(ByteFormat.count(count)) 个维护任务推荐",
                            count == 1 ? "1 Maintenance Task Recommended" : "\(ByteFormat.count(count)) Maintenance Tasks Recommended")
                : L10n.text("维护任务", "Maintenance Tasks"),
            detail: L10n.text("重建邮件索引、刷新“打开方式”等系统维护，逐项确认后才运行。",
                              "System upkeep such as reindexing Mail and refreshing “Open With”; each task runs only after you confirm."),
            note: lastRunNote(store),
            systemImage: "wrench.adjustable",
            reviewTitle: L10n.text("查看", "Review"), onReview: onReview,
            cleanTitle: store.isRunning ? L10n.text("正在运行…", "Running…")
                : (count > 0 ? L10n.text("运行任务", "Run Tasks") : nil),
            cleanEnabled: !store.isRunning && !store.recommendedTasks.isEmpty,
            onClean: {
                let tasks = store.recommendedTasks
                if !tasks.isEmpty { onRun(tasks) }
            },
            art: .tileMaintenance)
    }

    /// What the last run did, until its results are dismissed on the page.
    @MainActor
    private static func lastRunNote(_ store: SystemMaintenanceStore) -> String? {
        guard !store.isRunning, !store.results.isEmpty else { return nil }
        let ran = store.results.count
        let unfinished = store.results.values.filter { $0.outcome != .succeeded }.count
        return unfinished == 0
            ? L10n.text("已运行 \(ByteFormat.count(ran)) 项，结果在“查看”里",
                        ran == 1 ? "1 task ran; see Review for the result" : "\(ByteFormat.count(ran)) tasks ran; see Review for the results")
            : L10n.text("\(ByteFormat.count(unfinished)) 项没有完成，原因在“查看”里",
                        unfinished == 1 ? "1 task did not finish; see Review for why"
                            : "\(ByteFormat.count(unfinished)) tasks did not finish; see Review for why")
    }
}

/// Value-driven production presentation, also used by Debug captures.
struct StartupItemsRunningPage: View {
    @Environment(\.careStudioClassicResults) private var usesClassicPage
    let title: String
    let discoveredCount: Int
    let onCancel: () -> Void
    /// D143: the CleanMyMac running page (still read-only: nothing changes);
    /// the D70 template stays as the classic view.
    var body: some View {
        if usesClassicPage {
            FeatureRunningTemplate(module: .startup, title: title,
                metrics: [.init(title: L10n.text("已发现", "Items Found"), value: String(discoveredCount))],
                trustText: L10n.text("只读检查 · 更改前逐项确认并保留撤销记录", "Read-only check · Changes require confirmation and keep an undo record"),
                canCancel: true, cancelTitle: L10n.text("取消读取", "Cancel Reading"), onCancel: onCancel
            ) { EmptyView() } actions: { EmptyView() }
        } else {
            CareStudioStartupRunning(title: title, discoveredCount: discoveredCount, onCancel: onCancel)
        }
    }
}

struct MemoryOptimizerView: View {
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isPresentationFixture
#endif
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.pageLayout) private var pageLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    @ObservedObject private var monitorState: MenuBarMonitorState
    @State private var showsMemoryProcesses = false
    /// D144: the app list and quit flow live on the classic page; tests of
    /// that page set `careStudioClassicResults`.
    @Environment(\.careStudioClassicResults) private var usesClassicMemory
    @State private var showsClassicMemory = false
    @State private var dismissedReclaimAt: Date?

    init(store: ScanStore) {
        self.store = store
        _monitorState = ObservedObject(wrappedValue: store.menuBarMonitorState)
    }

    private var processSnapshot: MemorySnapshot? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return store.menuBarDisplayMemorySnapshot }
#endif
        return store.memorySnapshot
    }

    private var page: PageLayout {
        pageLayout ?? PageLayout.approximated(from: layout)
    }

    /// D144: a reclaim result not yet dismissed with "完成".
    private var pendingReclaim: (MemoryOptimizationResult, MemoryReclaimer.Outcome)? {
        guard let result = store.memoryOptimizationResult, let reclaim = result.reclaim,
              result.snapshot.generatedAt != dismissedReclaimAt else { return nil }
        return (result, reclaim)
    }

    /// D144: CleanMyMac's memory page (pressure, use, cache; "释放"); the
    /// D70 page stays as the classic view with the app list and quit flow.
    var body: some View {
        Group {
            if usesClassicMemory {
                classicBody()
            } else if store.isReclaimingMemory {
                CareStudioMemoryRunning(onStop: { store.cancelMemoryOptimization() })
            } else if showsClassicMemory || (store.isOptimizingMemory && !store.isReclaimingMemory) {
                // Back to the studio page from the classic page's status line.
                classicBody(backToFreeUp: store.isOptimizingMemory ? nil : { showsClassicMemory = false })
            } else if case let (result, reclaim)? = pendingReclaim {
                CareStudioMemoryResultPage(result: result, reclaim: reclaim,
                    onDone: { dismissedReclaimAt = result.snapshot.generatedAt },
                    onShowApps: {
                        dismissedReclaimAt = result.snapshot.generatedAt
                        showsClassicMemory = true
                    })
            } else {
                CareStudioMemoryLanding(snapshot: processSnapshot, isLoading: store.isLoadingMemory,
                                        canFreeUp: store.canOptimizeMemory,
                                        onFreeUp: { store.optimizeMemory() },
                                        onShowApps: { showsClassicMemory = true })
            }
        }
        .featureFlowTransition(value: store.isOptimizingMemory || store.isLoadingMemory)
        .onChange(of: store.memoryOptimizationResult?.snapshot.generatedAt) { _, date in
            if date != nil { showsMemoryProcesses = true }
        }
        .task {
#if DEBUG
            guard !FeaturePresentationDemo.isEnabled, !isPresentationFixture else { return }
#endif
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  store.canRefreshMemory,
                  store.selectedMemoryAppEstimatedBytes == 0,
                  store.memorySnapshot.map({ Date().timeIntervalSince($0.generatedAt) > 30 }) ?? true else { return }
            store.refreshMemory(priority: .utility)
        }
    }

    /// D70 separates the live pressure preview and the grouped process result.
    private func classicBody(backToFreeUp: (() -> Void)? = nil) -> some View {
        Group {
            if store.isOptimizingMemory || store.isLoadingMemory {
                memoryRunningPage
            } else {
                LightfieldMemoryPage(store: store, snapshot: processSnapshot,
                    displaySnapshot: store.menuBarDisplayMemorySnapshot,
                    trendPoints: monitorState.memoryHistory(within: 120), showsResultsWhenSampled: true,
                    showsProcesses: $showsMemoryProcesses, backToFreeUp: backToFreeUp)
            }
        }
    }

    private var memoryRunningPage: some View {
        let cancelAction: (() -> Void)?
        if store.isOptimizingMemory { cancelAction = { store.cancelMemoryOptimization() } }
        else { cancelAction = nil }
        return MemoryRunningPage(isOptimizing: store.isOptimizingMemory, onCancel: cancelAction)
    }

}

/// §3.2.8: placeholders with a sheen while the first sample loads, instead
/// of a text-only "loading" line.
private struct MemoryLoadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SurfaceCard {
                HStack(spacing: 20) {
                    SkeletonBlock(width: 96, height: 96, cornerRadius: 48)
                    SkeletonBlock(width: 72, height: 72, cornerRadius: 36)
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBlock(width: 120, height: 14)
                        SkeletonBlock(width: 180, height: 22)
                        SkeletonBlock(width: 160, height: 12)
                    }
                    SkeletonBlock(height: 96, cornerRadius: 12)
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonBlock(height: 18)
                    }
                }
            }
        }
        .accessibilityLabel(L10n.text("正在读取内存状态", "Reading memory status"))
    }
}

struct EnergyImpactView: View {
    @ObservedObject var store: ScanStore
    @State private var searchText = ""
    @State private var sortMode: EnergyImpactSortMode = .estimatedEnergy

    var body: some View {
        Group {
            if store.hasScannedEnergyImpact, !store.isEnergyImpactPageScanActive, let snapshot = store.energyImpactSnapshot {
                LightfieldEnergyPage(snapshot: snapshot, searchText: $searchText, sortMode: $sortMode,
                    canRefresh: store.canRefreshEnergyImpact, refresh: { store.scanEnergyImpact() }) {
                    HelperPowerMetricsView(monitor: store.helperPowerMetricsMonitor, lightfield: true)
                }
            } else {
                EnergyImpactScanLandingView(store: store)
            }
        }
    }
}

enum EnergyImpactSortMode: String, CaseIterable, Identifiable {
    case estimatedEnergy
    case currentPower
    case averagePower
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .estimatedEnergy:
            L10n.text("累计能耗", "Cumulative Energy")
        case .currentPower:
            L10n.text("当前功率", "Current Power")
        case .averagePower:
            L10n.text("平均功率", "Average Power")
        case .name:
            L10n.text("名称", "Name")
        }
    }

    var systemImage: String {
        switch self {
        case .estimatedEnergy:
            "battery.100.bolt"
        case .currentPower:
            "bolt.fill"
        case .averagePower:
            "gauge.with.dots.needle.67percent"
        case .name:
            "textformat"
        }
    }

    func sorted(_ apps: [EnergyImpactApp]) -> [EnergyImpactApp] {
        apps.sorted { lhs, rhs in
            switch self {
            case .estimatedEnergy:
                if lhs.estimatedEnergyWh != rhs.estimatedEnergyWh {
                    return lhs.estimatedEnergyWh > rhs.estimatedEnergyWh
                }
                if lhs.currentPowerWatts != rhs.currentPowerWatts {
                    return lhs.currentPowerWatts > rhs.currentPowerWatts
                }
            case .currentPower:
                if lhs.currentPowerWatts != rhs.currentPowerWatts {
                    return lhs.currentPowerWatts > rhs.currentPowerWatts
                }
                if lhs.estimatedEnergyWh != rhs.estimatedEnergyWh {
                    return lhs.estimatedEnergyWh > rhs.estimatedEnergyWh
                }
            case .averagePower:
                if lhs.averagePowerWatts != rhs.averagePowerWatts {
                    return lhs.averagePowerWatts > rhs.averagePowerWatts
                }
            case .name:
                break
            }

            if lhs.name != rhs.name {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}

private struct EnergyImpactSummaryGrid: View {
    let snapshot: EnergyImpactSnapshot
    let systemEnergy: SystemEnergySessionSnapshot?

    private var coveragePercentText: String {
        String(
            format: "%.0f%%",
            locale: Locale(identifier: "en_US_POSIX"),
            systemEnergy?.coveragePercent(uptimeSeconds: snapshot.uptimeSeconds) ?? 0
        )
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            // BOARD N16-5: what was recorded, for the period it covers; a
            // session with nothing recorded is not shown as 0 kWh.
            UtilityMetricCard(
                title: systemEnergy?.energyTitle(uptimeSeconds: snapshot.uptimeSeconds)
                    ?? L10n.text("监测期间耗电", "Energy While Monitored"),
                value: systemEnergy?.recordedEnergyText ?? "—",
                detail: systemEnergy?.recordedEnergyDetail
                    ?? L10n.text("正在建立监测会话", "Starting monitoring session"),
                systemImage: "battery.100.bolt",
                tint: AppDesignTokens.Palette.information
            )
            // Review P2-6: only a recent reading is current; redrawn while
            // shown, so a reading that stopped does not stay on screen.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                UtilityMetricCard(
                    title: L10n.text("当前功率", "Current Power"),
                    value: systemEnergy?.currentPowerText(now: context.date) ?? snapshot.currentPowerWattsText,
                    detail: systemEnergy?.currentPowerDetail(now: context.date)
                        ?? L10n.text("应用进程归属估算", "Attributed-process estimate"),
                    systemImage: "bolt.fill",
                    tint: AppDesignTokens.Palette.secondary
                )
            }
            UtilityMetricCard(
                title: L10n.text("监测覆盖率", "Monitoring Coverage"),
                value: coveragePercentText,
                detail: systemEnergy.map {
                    L10n.text(
                        "已记录 \(EnergyImpactApp.durationText($0.coveredSeconds))",
                        "\(EnergyImpactApp.durationText($0.coveredSeconds)) recorded"
                    )
                } ?? L10n.text("等待第一个有效样本", "Awaiting the first valid sample"),
                systemImage: "checkmark.seal.fill",
                tint: AppDesignTokens.Palette.information
            )
            UtilityMetricCard(
                title: L10n.text("系统运行时间", "System Uptime"),
                value: snapshot.uptimeText,
                detail: systemEnergy.map {
                    L10n.text(
                        "从 \($0.monitoringStartedAt.formatted(date: .abbreviated, time: .shortened)) 开始记录",
                        "Recording since \($0.monitoringStartedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                } ?? L10n.text("监测尚未开始", "Monitoring has not started"),
                systemImage: "power.circle.fill",
                tint: AppDesignTokens.Palette.tertiary
            )
        }
    }
}

private struct EnergyImpactMeasurementBar: View {
    let snapshot: EnergyImpactSnapshot
    let systemEnergy: SystemEnergySessionSnapshot?

    private var qualityTint: Color {
        switch snapshot.measurementQuality {
        case .measured: AppDesignTokens.Palette.success
        case .mixed: AppDesignTokens.Palette.information
        case .estimated: AppDesignTokens.Palette.warning
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                sourcePill
                measurementExplanation
                Spacer(minLength: 8)
                sampleWindow
            }
            .frame(minWidth: 700)

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    sourcePill
                    Spacer(minLength: AppDesignTokens.Spacing.small)
                    sampleWindow
                }
                measurementExplanation
            }
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.rowRadius, tint: qualityTint, prominence: .quiet)
        .help(L10n.text(
            "电池供电时优先使用电池电压与电流；插电时 macOS 没有公开的便携式插座功耗接口，因此使用明确标注的进程归属估算。睡眠和未监测时段不会外推。",
            "On battery, voltage and current are preferred. On AC, macOS exposes no portable public wall-power API, so an explicitly labelled attributed-process estimate is used. Sleep and unmonitored gaps are not extrapolated."
        ))
    }

    private var sourcePill: some View {
        MetadataPill(text: snapshot.source, systemImage: "waveform.path.ecg", tint: qualityTint)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var measurementExplanation: some View {
        Text(L10n.text(
            "上方为整机监测估算；下方应用列表仅显示可归属能耗。\(snapshot.calibrationText)",
            "The summary is a whole-system monitoring estimate; the list below shows attributable app energy only. \(snapshot.calibrationText)"
        ))
        .font(AppDesignTokens.Typography.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sampleWindow: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(L10n.text(
                "实时采样窗口 \(snapshot.sampleDurationText)",
                "Live sample window \(snapshot.sampleDurationText)"
            ))
        }
        .font(AppDesignTokens.Typography.compactLabelEmphasis)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct EnergyImpactControlsBar: View {
    @Binding var sortMode: EnergyImpactSortMode
    let visibleCount: Int
    let snapshot: EnergyImpactSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.text(
                "\(ByteFormat.count(visibleCount)) 个应用 · 合并统计 \(ByteFormat.count(snapshot.processCount)) 个进程",
                "\(ByteFormat.count(visibleCount)) apps · \(ByteFormat.count(snapshot.processCount)) processes grouped"
            ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Menu {
                ForEach(EnergyImpactSortMode.allCases) { mode in
                    Button {
                        sortMode = mode
                    } label: {
                        Label(mode.title, systemImage: mode == sortMode ? "checkmark" : mode.systemImage)
                    }
                }
            } label: {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text(sortMode.title)
                }
            }
            .menuStyle(.button)
            .fixedSize()
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: AppDesignTokens.Palette.information, prominence: .quiet)
    }
}

private struct EnergyImpactTableHeader: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularHeader
                .frame(minWidth: 700)

            HStack(spacing: AppDesignTokens.Spacing.small) {
                Text(L10n.text("应用与能耗明细", "App energy details"))
                Spacer(minLength: AppDesignTokens.Spacing.small)
                Text(L10n.text("累计 · 当前 · 平均", "Energy · Current · Average"))
                    .foregroundStyle(.secondary)
            }
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var regularHeader: some View {
        HStack(spacing: 12) {
            Text("")
                .frame(width: UtilitySizing.rowIconFrame)

            Text(L10n.text("应用", "App"))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)

            Spacer(minLength: 10)

            Text(L10n.text("累计能耗", "Energy"))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            Text(L10n.text("当前功率", "Current"))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            Text(L10n.text("平均功率", "Average"))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            Color.clear
                .frame(width: 28, height: 1)
        }
    }
}

private struct EnergyImpactAppRow: View {
    let app: EnergyImpactApp
    let sortMode: EnergyImpactSortMode
    let maxEstimatedEnergyWh: Double
    let maxCurrentPowerWatts: Double
    let maxAveragePowerWatts: Double

    private var tint: Color {
        if app.currentPowerWatts >= 2 || app.cpuPercent >= 20 {
            return AppDesignTokens.Palette.warning
        }
        if app.currentPowerWatts >= 0.5 || app.cpuPercent >= 5 {
            return AppDesignTokens.Palette.information
        }
        if app.estimatedEnergyWh >= 1 {
            return AppDesignTokens.Palette.secondary
        }
        return AppDesignTokens.Palette.success
    }

    private var measurementTint: Color {
        switch app.measurementQuality {
        case .measured: AppDesignTokens.Palette.success
        case .mixed: AppDesignTokens.Palette.information
        case .estimated: AppDesignTokens.Palette.warning
        }
    }

    private var measurementSystemImage: String {
        switch app.measurementQuality {
        case .measured: "checkmark.seal.fill"
        case .mixed: "circle.lefthalf.filled"
        case .estimated: "function"
        }
    }

    private var barPercent: Double {
        switch sortMode {
        case .estimatedEnergy:
            app.estimatedEnergyWh / maxEstimatedEnergyWh * 100
        case .currentPower:
            app.currentPowerWatts / maxCurrentPowerWatts * 100
        case .averagePower:
            app.averagePowerWatts / maxAveragePowerWatts * 100
        case .name:
            app.estimatedEnergyWh / maxEstimatedEnergyWh * 100
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularLayout
                .frame(minWidth: 700)
            compactLayout
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, AppDesignTokens.Spacing.medium)
        .help(app.sourceTitle)
        .contextMenu {
            Button {
                activateApplication()
            } label: {
                Label(L10n.text("切换到应用", "Switch to App"), systemImage: "arrow.up.forward.app")
            }
            Button {
                revealApplication()
            } label: {
                Label(L10n.text("在访达中显示", "Show in Finder"), systemImage: "folder")
            }
        }
    }

    private var regularLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            ProcessIcon(path: app.iconPath, fallbackSystemImage: "app.fill")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    appName
                    measurementPills
                }

                runtimeLabel
                usageBar
            }

            Spacer(minLength: 10)

            EnergyImpactValueColumn(title: L10n.text("累计能耗", "Energy"), value: app.estimatedEnergyText, evidence: app.cumulativeEvidence)
                .frame(width: 92, alignment: .trailing)
            EnergyImpactValueColumn(title: L10n.text("当前功率", "Current power"), value: app.currentEvidence.source == .unknown ? "—" : app.currentPowerWattsText, evidence: app.currentEvidence)
                .frame(width: 92, alignment: .trailing)
            EnergyImpactValueColumn(title: L10n.text("平均功率", "Average power"), value: app.averagePowerWattsText, evidence: app.averageEvidence)
                .frame(width: 92, alignment: .trailing)

            AppIconButton(
                title: L10n.text("切换到应用", "Switch to app"),
                systemImage: "arrow.up.forward.app",
                kind: .toolbar,
                action: activateApplication
            )
            .frame(width: 28)
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.regular) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { evidenceColumns }
                VStack(alignment: .leading, spacing: 8) { evidenceColumns }
            }


            usageBar
        }
    }

    private var appName: some View {
        Text(app.name)
            .font(AppDesignTokens.Typography.inlineTitle)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    private var measurementPills: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            if app.processCount > 1 {
                MetadataPill(
                    text: L10n.text("\(ByteFormat.count(app.processCount)) 进程", "\(ByteFormat.count(app.processCount)) processes"),
                    systemImage: "square.stack.3d.up.fill",
                    tint: AppDesignTokens.Palette.diagnostic
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var runtimeLabel: some View {
        Text(L10n.text(
            "运行 \(app.runningTimeText) · CPU \(app.cpuPercentText)",
            "Running \(app.runningTimeText) · CPU \(app.cpuPercentText)"
        ))
        .font(AppDesignTokens.Typography.secondary)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var usageBar: some View {
        EnergyImpactUsageBar(percent: barPercent, tint: tint)
            .frame(maxWidth: 330)
    }

    @ViewBuilder
    private var evidenceColumns: some View {
        EnergyImpactValueColumn(title: L10n.text("累计能耗", "Energy"), value: app.estimatedEnergyText, evidence: app.cumulativeEvidence)
        EnergyImpactValueColumn(title: L10n.text("当前功率", "Current power"), value: app.currentEvidence.source == .unknown ? "—" : app.currentPowerWattsText, evidence: app.currentEvidence)
        EnergyImpactValueColumn(title: L10n.text("平均功率", "Average power"), value: app.averagePowerWattsText, evidence: app.averageEvidence)
    }

    private func activateApplication() {
        guard let bundlePath = app.bundlePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: bundlePath))
    }

    private func revealApplication() {
        guard let bundlePath = app.bundlePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundlePath)])
    }
}

private struct EnergyImpactValueColumn: View {
    let title: String
    let value: String
    let evidence: EnergyMetricEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            Text(value).font(AppDesignTokens.Typography.inlineTitle).monospacedDigit()
            Text(evidence.source.title).font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(evidence.detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value) · \(evidence.detail)")
    }
}

private struct EnergyImpactUsageBar: View {
    let percent: Double
    let tint: Color

    var body: some View {
        ProgressView(value: clampedPercent, total: 100)
            .progressViewStyle(.linear)
            .tint(tint)
            .frame(height: 6)
            .accessibilityLabel(L10n.text("能耗占比 \(String(format: "%.1f", percent))%", "Energy share \(String(format: "%.1f", percent))%"))
    }

    private var clampedPercent: Double {
        min(100, max(0, percent))
    }
}

/// The uninstall page: the inventory scan first, then CleanMyMac's
/// Applications manager (`ApplicationsManagerView`). A rescan keeps the
/// manager on screen; only the very first scan shows the landing page.
struct AppUninstallerView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var manager: ApplicationsManagerModel

    init(store: ScanStore) {
        self.store = store
        manager = ApplicationsManagerModel.of(store)
    }

    var body: some View {
        Group {
            if !store.hasScannedInstalledApps || (store.isLoadingInstalledApps && manager.entries.isEmpty) {
                // D154: CleanMyMac's Applications landing and reading page.
                CareStudioApplicationsStart(store: store)
            } else {
                ApplicationsManagerView(store: store)
            }
        }
    }
}

struct RelatedAppFilesReviewSheet: View {
    let app: InstalledAppItem
    let isProcessing: Bool
    let cancel: () -> Void
    let confirm: (Set<String>) -> Void
    @State private var selectedPaths = Set<String>()

    private var items: [InstalledAppRelatedItem] {
        AppUninstallService.reviewableRelatedItems(for: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("关联文件由你决定", "You Decide About Related Files"))
                    .font(AppDesignTokens.Typography.sheetTitle)
                Text(L10n.text(
                    "\(app.name) 已移入废纸篓。这些文件默认保留，勾选后才会移动。",
                    "\(app.name) is in Trash. These files stay unless you select them."
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(AppAppearanceColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Label(
                L10n.text("精确 Bundle ID 只提供候选线索，不能证明专属归属；应用数据可能含个人内容。", "An exact bundle ID only suggests candidates, not exclusive ownership. App data may contain personal content."),
                systemImage: "info.circle"
            )
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(AppAppearanceColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppAppearanceColors.secondarySurface, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if items.isEmpty {
                ContentUnavailableView(
                    L10n.text("没有可逐项处理的文件", "No Files to Review"),
                    systemImage: "folder"
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(items) { item in
                    Toggle(isOn: Binding(
                        get: { selectedPaths.contains(item.path) },
                        set: { enabled in
                            if enabled { selectedPaths.insert(item.path) }
                            else { selectedPaths.remove(item.path) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                    .font(AppDesignTokens.Typography.secondary.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(ByteFormat.storageString(item.sizeBytes))
                                    .font(AppDesignTokens.Typography.metadata.monospacedDigit())
                                    .foregroundStyle(AppAppearanceColors.secondaryText)
                            }
                            Text(item.path)
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(AppAppearanceColors.tertiaryText)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(item.path)
                        }
                    }
                    .disabled(isProcessing)
                }
                .listStyle(.inset)
                .frame(minHeight: 160, maxHeight: 320)
            }

            Divider()
            HStack(spacing: 10) {
                Button(L10n.text("保留所有文件", "Keep All Files"), role: .cancel, action: cancel)
                    .disabled(isProcessing)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 10)
                Button(role: .destructive) {
                    confirm(selectedPaths)
                } label: {
                    if isProcessing {
                        Label(L10n.text("正在移动…", "Moving…"), systemImage: "hourglass")
                    } else {
                        Label(L10n.text("将所选 \(ByteFormat.count(selectedPaths.count)) 项移入废纸篓", "Move \(ByteFormat.count(selectedPaths.count)) to Trash"), systemImage: "trash")
                    }
                }
                .appButtonChrome(.primary)
                .tint(AppDesignTokens.Palette.destructive)
                .disabled(isProcessing || selectedPaths.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 590, alignment: .topLeading)
        .background(AppAppearanceColors.panel)
        .interactiveDismissDisabled(isProcessing)
    }
}
struct UninstallPreviewAppIcon: View {
    let path: String

    var body: some View {
        CachedAppIconView(
            path: path,
            size: UtilitySizing.previewIcon
        ) {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
            .shadow(color: AppDesignTokens.Elevation.prominentShadow, radius: 12, y: 6)
    }
}

struct OneClickUpdatePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ScanStore
    let plan: AppUpdateOneClickPlan
    @State private var reopensUpdatedApplications = true

    private var allApps: [AppUpdateItem] {
        plan.applications
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 14) {
                ArtworkIconTile(
                    systemImage: "wand.and.stars",
                    filter: nil,
                    tint: AppDesignTokens.Palette.secondary,
                    size: UtilitySizing.headerIcon,
                    glyphSize: UtilitySizing.headerSymbolGlyph,
                    showsGlass: true,
                    showsGlow: true
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("更新计划", "Update Plan"))
                        .font(AppDesignTokens.Typography.sheetTitle)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                OneClickPlanMetric(
                    title: L10n.text("自动更新", "Automatic"),
                    value: ByteFormat.count(plan.automaticApps.count),
                    systemImage: "bolt.fill",
                    tint: AppDesignTokens.Palette.information
                )
                if plan.authorizationApps.count > 0 {
                    OneClickPlanMetric(
                        title: L10n.text("需要授权", "Authorization"),
                        value: ByteFormat.count(plan.authorizationApps.count),
                        systemImage: "lock.shield",
                        tint: .secondary
                    )
                }
                if plan.appStoreApps.count > 0 {
                    OneClickPlanMetric(
                        title: "App Store",
                        value: ByteFormat.count(plan.appStoreApps.count),
                        systemImage: "bag.fill",
                        tint: .secondary
                    )
                }
                if plan.manualReviewCount > 0 {
                    OneClickPlanMetric(
                        title: L10n.text("需要手动", "Manual"),
                        value: ByteFormat.count(plan.manualReviewCount),
                        systemImage: "hand.raised.fill",
                        tint: .secondary
                    )
                }
            }

            Toggle(isOn: $reopensUpdatedApplications) {
                Text(L10n.text(
                    "更新后重新打开应用",
                    "Reopen Applications After Update"
                ))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
            }
            .toggleStyle(.switch)
            .accessibilityHint(L10n.text(
                "关闭后，更新成功也不会自动重新打开应用",
                "Turn off to keep updated applications closed"
            ))

            if !plan.appStoreApps.isEmpty {
                Label(
                    L10n.text("App Store 项目需在 App Store 中确认", "Confirm App Store items in the App Store"),
                    systemImage: "bag"
                )
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: AppDesignTokens.Palette.information, prominence: .quiet)
            }

            if plan.manualReviewCount > 0 {
                Label(
                    L10n.text(
                        "应用内和手动项目会打开各自的更新入口；打开入口不等于安装完成，返回后需复查版本。已核实的官网项目会加入可恢复的引导队列。",
                        "In-app and manual items open their own update entry. Opening it does not complete installation; recheck the version afterwards. Verified website items join a resumable guided queue."
                    ),
                    systemImage: "hand.raised"
                )
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: AppDesignTokens.Palette.warning, prominence: .quiet)
            }

                    VStack(spacing: 0) {
                    ForEach(allApps) { app in
                        OneClickUpdatePreviewRow(
                            app: app,
                            automaticallyUpdated: plan.automaticApps.contains { $0.id == app.id },
                            guidedWebsite: plan.guidedWebsiteApps.contains { $0.id == app.id },
                            onOpen: {
                                if app.primaryUpdateProvider == .macAppStore {
                                    store.requestAppStoreUpdate(app)
                                } else {
                                    store.openUpdateEntry(app)
                                }
                            }
                        )
                        if app.id != allApps.last?.id {
                            Divider()
                        }
                    }
                    }
                    .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: AppDesignTokens.Palette.secondary, prominence: .quiet)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack {
                Button {
                    store.dismissOneClickUpdatePreview()
                    dismiss()
                } label: {
                    Label(L10n.text("取消", "Cancel"), systemImage: "xmark")
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

                Spacer()

                if plan.automaticCount > 0 || !plan.guidedWebsiteApps.isEmpty {
                    Button {
                        store.confirmOneClickAppUpdates(
                            reopensUpdatedApplications: reopensUpdatedApplications
                        )
                    } label: {
                        Label(L10n.text("开始安全更新与官网引导", "Start Safe Updates and Website Guidance"), systemImage: "arrow.down.circle")
                    }
                    .appButtonChrome(.primary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canRequestOneClickAppUpdates)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 860, height: 680, alignment: .topLeading)
        .background(AppDesignTokens.Palette.contentBackground)
    }
}

private struct OneClickPlanMetric: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(value)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
            Text(title)
                .font(AppDesignTokens.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: tint, prominence: .quiet)
        .accessibilityElement(children: .combine)
    }
}

private struct OneClickUpdatePreviewRow: View {
    let app: AppUpdateItem
    let automaticallyUpdated: Bool
    let guidedWebsite: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                InstalledAppIcon(path: app.path)
                VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textTightSpacing) {
                    Text(app.name)
                        .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    Text(app.source.trimmed.nonEmpty ?? app.primaryUpdateProvider.rawValue)
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if app.isRunning || app.requiresApplicationQuit {
                    Label(L10n.text("应用退出后更新", "Update After App Quits"), systemImage: "power")
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                } else if app.requiresAdministratorAuthorization {
                    Label(L10n.text("需要管理员授权", "Administrator Authorization Required"), systemImage: "lock.shield")
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                }
            }
            HStack(spacing: 10) {
                Text(L10n.text(
                    "当前 \(app.currentVersionDisplay) → 最新 \(app.latestVersionDisplay)",
                    "Current \(app.currentVersionDisplay) → Latest \(app.latestVersionDisplay)"
                ))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !automaticallyUpdated && !guidedWebsite {
                    AppButton(
                        title: L10n.text("打开入口", "Open Entry"),
                        systemImage: "arrow.up.right",
                        kind: .secondary,
                        action: onOpen
                    )
                } else if guidedWebsite {
                    Text(L10n.text("官网引导", "Website Guidance"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(AppDesignTokens.Typography.compactLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct DuplicateFilesView: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// D154 batch 2: tests of the D67 result list keep it as the result.
    @Environment(\.careStudioClassicResults) private var usesClassicPages
    @ObservedObject var store: ScanStore
    @ObservedObject private var workspace: DuplicateFilesStore
    /// D202: Smart Care's Review shows its result here.
    @ObservedObject private var navigation: AppNavigationState
    private let presentationFilter: DuplicateResultFilter?
    @State private var usesSystemPhotoLibrary = false
    /// D154 batch 2: the review list was opened from the My Clutter tiles.
    @State private var showsList = false
    /// D221: the manager shows Large & Old Files.
    @State private var showsLargeOld = false
    /// D226: the manager shows Downloads.
    @State private var showsDownloads = false
    @StateObject private var photoLibrary = PhotoLibraryStore.live()
    @AppSurfaces private var surfaces

    init(store: ScanStore, presentationFilter: DuplicateResultFilter? = nil) {
        self.presentationFilter = presentationFilter
        self.store = store
        _workspace = ObservedObject(wrappedValue: store.duplicateFilesWorkspace)
        _navigation = ObservedObject(wrappedValue: store.navigationState)
    }

    /// D202: Smart Care's scan and result stay on Smart Care; this page keeps
    /// its landing for them (its Review excepted).
    private var showsOwnResult: Bool { store.moduleShowsResult(.clutter) }

    private var effectiveResultFilter: DuplicateResultFilter { presentationFilter ?? workspace.resultFilter }
    private var resultFilterBinding: Binding<DuplicateResultFilter> {
        if let presentationFilter { return .constant(presentationFilter) }
        return $workspace.resultFilter
    }

    private var allItems: [StorageItem] {
        workspace.items
    }

    private var allGroups: [DuplicateDisplayGroup] {
        DuplicateFilesPresenter.groups(from: allItems)
    }

    private var groups: [DuplicateDisplayGroup] {
        DuplicateFilesPresenter.groups(
            from: allItems,
            matching: workspace.searchText,
            filter: effectiveResultFilter,
            sort: workspace.resultSort
        )
    }

    private var logicalDuplicateBytes: Int64 {
        allGroups.filter(\.isContentConfirmed).reduce(0) { $0 + $1.logicalDuplicateBytes }
    }

    private var confirmedFileCount: Int {
        allGroups
            .filter(\.isContentConfirmed)
            .reduce(0) { $0 + $1.items.count }
    }

    private var physicalReclaimableBytes: Int64? {
        let exactGroups = allGroups.filter(\.isContentConfirmed)
        guard !exactGroups.isEmpty,
              exactGroups.allSatisfy({ $0.physicalReclaimableBytes != nil }) else { return nil }
        return exactGroups.compactMap(\.physicalReclaimableBytes).reduce(0, +)
    }

    private var selectedItems: [StorageItem] {
        workspace.selectedItems(from: allItems)
    }

    private var isSimilarPhotosRoute: Bool {
        effectiveResultFilter == .similarImage
    }

    private var pageTitle: String {
        isSimilarPhotosRoute
            ? L10n.text("相似照片", "Similar Photos")
            : ReviewFilter.duplicates.sidebarTitle
    }

    var body: some View {
        // The photo-source switch lives inside the D-locked skeleton (landing
        // status action / result toolbar), never above the page: a row above
        // FeatureLightfieldPage shifts title, content and status frames.
        Group {
            if isSimilarPhotosRoute && usesSystemPhotoLibrary && PhotoLibraryAvailability.isEnabledInMainBundle {
                PhotoLibraryLightfieldView(model: photoLibrary) { usesSystemPhotoLibrary = false }
            } else if workspace.isScanning && showsOwnResult {
                duplicateRuntimePage
            } else if !workspace.hasScanned || !showsOwnResult {
                duplicateScanHero
            } else if showsClutterResults {
                clutterResults
            } else if showsClutterManager {
                clutterManager
            } else {
                duplicateDataPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .id(workspace.hasScanned)
        // A new scan opens on its results again.
        .onChange(of: workspace.lastScanAt) { _, _ in
            showsList = false
            showsLargeOld = false
            showsDownloads = false
        }
        .featureFlowTransition(value: workspace.isScanning)
        .transition(AppMotionTokens.pageTransition(reduceMotion: reduceMotion))
        .animation(
            AppMotionTokens.resolved(AppMotionTokens.navigation, reduceMotion: reduceMotion),
            value: workspace.hasScanned
        )
        .sheet(
            isPresented: Binding(
                get: { store.isDuplicateCleanupConfirmationPresented },
                set: { isPresented in
                    if isPresented {
                        store.isDuplicateCleanupConfirmationPresented = true
                    } else if store.isDuplicateCleanupConfirmationPresented {
                        store.cancelVerifiedDuplicateCleanupConfirmation()
                    }
                }
            )
        ) {
            DuplicateCleanupConfirmationSheet(
                presentation: DuplicateCleanupConfirmationPresentation(
                    plan: store.pendingDuplicateCleanPlan,
                    preflight: store.pendingDuplicateCleanPreflight
                ),
                facts: store.pendingDuplicateCleanPlan.map {
                    .cleanupPlan($0, preflight: store.pendingDuplicateCleanPreflight, surface: .duplicateFiles,
                                 appsToQuit: [], permission: .from(store.scanReadinessSummary))
                },
                onCancel: store.cancelVerifiedDuplicateCleanupConfirmation,
                onConfirm: store.confirmVerifiedDuplicateCleanup
            )
        }
        .alert(
            L10n.text("恢复已处理副本？", "Restore Handled Copies?"),
            isPresented: Binding(
                get: { store.isDuplicateRestoreConfirmationPresented },
                set: { store.isDuplicateRestoreConfirmationPresented = $0 }
            )
        ) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelRestoreLatestVerifiedDuplicateCleanup()
            }
            Button(L10n.text("恢复", "Restore")) {
                store.confirmRestoreLatestVerifiedDuplicateCleanup()
            }
        } message: {
            Text(L10n.text(
                "恢复前会重新核对隔离区或废纸篓中的文件身份；目标位置已有文件时不会覆盖。",
                "Identity is rechecked before restore, and an existing destination is never overwritten."
            ))
        }
        .alert(
            L10n.text("无法选择", "Cannot Select"),
            isPresented: Binding(
                get: { workspace.selectionMessage != nil },
                set: { if !$0 { workspace.dismissSelectionMessage() } }
            )
        ) {
            Button(L10n.text("好", "OK")) { workspace.dismissSelectionMessage() }
        } message: {
            Text(workspace.selectionMessage ?? "")
        }
    }

    private var duplicateScanHero: some View {
        FeatureLightfieldPage(module: .duplicates, phase: .landing, title: pageTitle,
            status: duplicateScanStatus.title, safety: L10n.text("只读扫描 · 不会自动删除文件", "Read-only scan · Files are never deleted automatically"),
            actionTitle: scanButtonTitle, actionEnabled: workspace.canScan,
            artwork: isSimilarPhotosRoute ? .similarPhotos : nil,
            statusActionTitle: L10n.text("改用系统照片图库", "Use System Photo Library"),
            statusAction: systemPhotoLibraryAction, action: store.scanDuplicateFiles) {
            FeatureLightfieldOptions(title: L10n.text("扫描位置", "Scan Locations")) {
                duplicateLightfieldOptions
            }
        }
    }

    private var duplicateLightfieldOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSimilarPhotosRoute {
                // These are facts about the existing user-files scope, not fake
                // per-folder controls: the store has no independent photo scope.
                LightfieldOptionRow(title: L10n.text("图片", "Pictures"), icon: .duplicatesPhotos, module: .duplicates,
                    metadata: workspace.scanScope == .selectedLocations ? L10n.text("仅所选位置", "Selected only") : L10n.text("随用户文件范围", "User-files scope"))
                LightfieldOptionRow(title: L10n.text("下载", "Downloads"), icon: .migrationSourceFolder, module: .duplicates,
                    metadata: workspace.scanScope == .selectedLocations ? L10n.text("仅所选位置", "Selected only") : L10n.text("随用户文件范围", "User-files scope"))
                // A titled row like the two above, not a bare menu below them.
                HStack(spacing: 14) {
                    LightfieldOptionIconView(icon: duplicateScopeIcon(workspace.scanScope))
                    Text(L10n.text("扫描范围", "Scan Scope")).font(.system(size: 16))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        ForEach(DuplicateFileScanScope.allCases) { scope in
                            Button(scope.title) { workspace.scanScope = scope }.disabled(workspace.scopeUnavailableReason(scope) != nil)
                        }
                    } label: { Text(workspace.scanScope.title).font(.system(size: 13)) }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel(L10n.text("扫描范围", "Scan Scope"))
                }
                .padding(.trailing, 6).frame(height: FeatureLightfield.optionHeight)
                .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
                .lightfieldComponentProbe("lightfield.similarPhotos.scope")
            } else {
                ForEach(DuplicateFileScanScope.allCases) { scope in
                    let unavailableReason = workspace.scopeUnavailableReason(scope)
                    // The note is one line, so the full reason was cut in the
                    // middle; the note stays short and the help gives the reason.
                    LightfieldOptionRow(title: scope.title, icon: duplicateScopeIcon(scope), module: .duplicates,
                        selection: Binding(get: { workspace.scanScope == scope }, set: { if $0 { workspace.scanScope = scope } }),
                        metadata: unavailableReason == nil ? "" : L10n.text("需先添加位置", "Add a location first"),
                        probeID: "lightfield.duplicates.scope." + scope.rawValue)
                        .disabled(unavailableReason != nil).help(unavailableReason ?? scopeDetail(scope))
                }
            }
            Button { chooseDuplicateRoot(externalVolume: false) } label: {
                HStack(spacing: 14) {
                    LightfieldOptionIconView(icon: .duplicatesAddFolder)
                    Text(L10n.text("添加文件夹", "Add Folder")).font(.system(size: 16))
                }.frame(height: 56).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(FeatureLightfieldRowButtonStyle())
                .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            Menu {
                Button(L10n.text("选择外接卷", "Choose External Volume")) { chooseDuplicateRoot(externalVolume: true) }
                ForEach(workspace.customRootPaths, id: \.self) { path in
                    Button(L10n.text("移除：", "Remove: ") + path) { workspace.removeCustomRoot(path) }
                }
                ForEach(workspace.externalRootPaths, id: \.self) { path in
                    Button(L10n.text("移除：", "Remove: ") + path) { workspace.removeExternalRoot(path) }
                }
            } label: { Text(L10n.text("已添加 \(ByteFormat.count(workspace.configuredAdditionalRoots.count)) 个位置", "\(ByteFormat.count(workspace.configuredAdditionalRoots.count)) added locations")).font(.system(size: 13)) }
                .menuStyle(.borderlessButton).frame(height: 40)
        }
    }

    private func duplicateScopeIcon(_ scope: DuplicateFileScanScope) -> LightfieldOptionIcon {
        switch scope {
        case .userFiles: .duplicatesUserFiles
        case .wholeComputer: .duplicatesUserData
        case .selectedLocations: .duplicatesSelectedLocation
        }
    }

    private var duplicateDataPage: some View {
        DuplicateFilesLightfieldView(store: store, workspace: workspace, groups: groups, allGroups: allGroups,
            allItems: allItems, isSimilarPhotos: isSimilarPhotosRoute, title: pageTitle, resultFilter: resultFilterBinding,
            details: AnyView(VStack(alignment: .leading, spacing: 16) { duplicateCoveragePanel; duplicateCleanupReportPanel }),
            onUseSystemPhotoLibrary: systemPhotoLibraryAction)
    }

    /// D154 batch 3B: the review is CleanMyMac's light manager; the D67 list
    /// stays for its tests (classic layout) and the presentation demo.
    private var showsClutterManager: Bool {
        !usesClassicPages && presentationFilter == nil
    }

    private var clutterManager: some View {
        CareStudioClutterManager(
            store: store, workspace: workspace, allItems: allItems, groups: groups, filter: effectiveResultFilter,
            details: AnyView(VStack(alignment: .leading, spacing: 16) { duplicateCoveragePanel; duplicateCleanupReportPanel }),
            onUseSystemPhotoLibrary: systemPhotoLibraryAction,
            onFilter: {
                workspace.resultFilter = $0
                showsLargeOld = false
                showsDownloads = false
            },
            onBack: {
                workspace.resultFilter = .all
                showsLargeOld = false
                showsDownloads = false
                showsList = false
            },
            showsLargeOld: showsLargeOld,
            onLargeOld: {
                showsLargeOld = true
                showsDownloads = false
            },
            showsDownloads: showsDownloads,
            onDownloads: {
                showsDownloads = true
                showsLargeOld = false
            })
    }

    /// D154 batch 2: CleanMyMac's My Clutter results come first; Similar
    /// Photos opened from My Tools goes straight to its review.
    private var showsClutterResults: Bool {
        !usesClassicPages && presentationFilter == nil && !showsList && !isSimilarPhotosRoute
    }

    private var clutterResults: some View {
        CareStudioClutterResults(
            store: store,
            confirmedGroups: allGroups.filter(\.isContentConfirmed).count,
            confirmedFiles: confirmedFileCount,
            logicalBytes: logicalDuplicateBytes,
            physicalBytes: physicalReclaimableBytes,
            candidateGroups: DuplicateFilesPresenter.groups(from: allItems, matching: "", filter: .candidates,
                                                            sort: workspace.resultSort).count,
            startOverEnabled: !workspace.isScanning,
            onReview: { filter in
                workspace.resultFilter = filter
                showsLargeOld = false
                showsDownloads = false
                showsList = true
            },
            onStartOver: workspace.startOver)
    }

    /// Only the similar-photos route of a bundle that declares Photos access
    /// offers the system library; other duplicate pages keep their layout.
    private var systemPhotoLibraryAction: (() -> Void)? {
        guard isSimilarPhotosRoute, PhotoLibraryAvailability.isEnabledInMainBundle else { return nil }
        return { usesSystemPhotoLibrary = true }
    }

    private var duplicateResultControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                duplicateSearchField
                duplicateFilterControls
            }

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                duplicateSearchField
                duplicateFilterControls
            }
        }
    }

    private var duplicateSearchField: some View {
        TaskSearchField(
            placeholder: L10n.text("搜索文件名、路径或类型", "Search file, path, or type"),
            text: $workspace.searchText,
            tint: AppDesignTokens.Palette.tertiary
        )
    }

    private var duplicateFilterControls: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            Menu {
                Picker(L10n.text("结果", "Results"), selection: resultFilterBinding) {
                    ForEach(DuplicateResultFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            } label: {
                Label(effectiveResultFilter.title, systemImage: "line.3.horizontal.decrease.circle")
            }
            .appButtonChrome(.secondary)

            Menu {
                ForEach(DuplicateFileCandidateGroup.Rule.selectableCases) { rule in
                    Button {
                        workspace.setCandidateRule(
                            rule,
                            enabled: !workspace.isCandidateRuleEnabled(rule)
                        )
                    } label: {
                        Label(
                            rule.title,
                            systemImage: workspace.isCandidateRuleEnabled(rule)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                    }
                }
                Divider()
                Text(L10n.text(
                    "内容完全相同始终使用完整 SHA-256 校验",
                    "Exact matches always use a full SHA-256 verification"
                ))
            } label: {
                Label(L10n.text("规则", "Rules"), systemImage: "checklist")
            }
            .appButtonChrome(.secondary)

            Menu {
                Picker(L10n.text("排序", "Sort"), selection: $workspace.resultSort) {
                    ForEach(DuplicateResultSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
            } label: {
                Label(workspace.resultSort.title, systemImage: "arrow.up.arrow.down")
            }
            .appButtonChrome(.secondary)

            Menu {
                Picker(L10n.text("扫描范围", "Scan Scope"), selection: $workspace.scanScope) {
                    ForEach(DuplicateFileScanScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                            .disabled(!workspace.canSelectScanScope(scope))
                    }
                }
                if let reason = workspace.scopeUnavailableReason(.selectedLocations) {
                    Text(reason)
                }
                Divider()
                Button(L10n.text("添加自定义文件夹", "Add Custom Folder")) {
                    chooseDuplicateRoot(externalVolume: false)
                }
                Button(L10n.text("选择外接卷", "Choose External Volume")) {
                    chooseDuplicateRoot(externalVolume: true)
                }
                if !workspace.configuredAdditionalRoots.isEmpty {
                    Divider()
                    ForEach(workspace.customRootPaths, id: \.self) { path in
                        Button(role: .destructive) {
                            workspace.removeCustomRoot(path)
                        } label: {
                            Label(path, systemImage: "minus.circle")
                        }
                    }
                    ForEach(workspace.externalRootPaths, id: \.self) { path in
                        Button(role: .destructive) {
                            workspace.removeExternalRoot(path)
                        } label: {
                            Label(path, systemImage: "externaldrive.badge.minus")
                        }
                    }
                }
            } label: {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Image(systemName: "folder.badge.gearshape")
                        .accessibilityHidden(true)
                    Text(workspace.scanScope.title)
                }
            }
            .appButtonChrome(.secondary)
        }
        .controlSize(.regular)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var duplicateScanAccessory: some View {
        if workspace.isScanning {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                duplicateProgressLabel
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Button {
                        if workspace.phase == .paused {
                            store.resumeDuplicateFileScan()
                        } else {
                            store.pauseDuplicateFileScan()
                        }
                    } label: {
                        Label(
                            workspace.phase == .paused
                                ? L10n.text("继续", "Resume")
                                : L10n.text("暂停", "Pause"),
                            systemImage: workspace.phase == .paused
                                ? "play.fill"
                                : "pause.fill"
                        )
                    }
                    .appButtonChrome(.secondary)
                    .disabled(workspace.phase == .cancelling)

                    Button(role: .cancel) {
                        store.cancelDuplicateFileScan()
                    } label: {
                        Label(L10n.text("取消", "Cancel"), systemImage: "xmark")
                    }
                    .appButtonChrome(.secondary)
                    .disabled(workspace.phase == .cancelling)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                CapsuleSegmentedControl(selection: Binding(
                    get: { workspace.scanScope },
                    set: { scope in
                        guard workspace.scopeUnavailableReason(scope) == nil else { return }
                        workspace.scanScope = scope
                    }), options: DuplicateFileScanScope.allCases, title: { $0.title },
                    label: L10n.text("扫描范围", "Scan Scope"), pigment: nil,
                    isOptionDisabled: { workspace.scopeUnavailableReason($0) != nil },
                    optionHelp: { workspace.scopeUnavailableReason($0) ?? scopeDetail($0) })
                    .help(duplicateScanScopeDetail)
                    .padding(.bottom, 8)

                if let reason = workspace.scopeUnavailableReason(.selectedLocations) {
                    let blocksScan = workspace.scanScope == .selectedLocations
                    Label(reason, systemImage: blocksScan ? "exclamationmark.triangle" : "info.circle")
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(blocksScan ? AppDesignTokens.Palette.warning : theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }

                duplicateLocationButtons
                additionalLocationCount
                    .padding(.top, 8)
            }
        }
    }

    private func duplicateScopeButton(_ scope: DuplicateFileScanScope) -> some View {
        let unavailableReason = workspace.scopeUnavailableReason(scope)
        return Button { workspace.scanScope = scope } label: {
            Text(scope.title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: GoldenLandingMetrics.scopeControlHeight)
                .background(workspace.scanScope == scope ? AppAppearanceColors.selectedSurface : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(workspace.scanScope == scope ? AppAppearanceColors.controlAccent : .clear))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        // N17: "Selected only" needs an added location first.
        .disabled(unavailableReason != nil)
        .help(unavailableReason ?? scopeDetail(scope))
        .accessibilityLabel(scope.title)
        .accessibilityHint(unavailableReason ?? scopeDetail(scope))
        .accessibilityAddTraits(workspace.scanScope == scope ? [.isSelected] : [])
    }

    private var duplicateLocationButtons: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            duplicateLocationButton(externalVolume: false)
            duplicateLocationButton(externalVolume: true)
        }
    }

    private func duplicateLocationButton(externalVolume: Bool) -> some View {
        Button {
            chooseDuplicateRoot(externalVolume: externalVolume)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: externalVolume ? "externaldrive" : "folder")
                    .font(.system(size: 27, weight: .light))
                    .accessibilityHidden(true)
                Text(externalVolume
                    ? L10n.text("选择外接卷", "Choose External Volume")
                    : L10n.text("添加文件夹", "Add Folder"))
                    .font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: GoldenLandingMetrics.locationButtonHeight)
            .foregroundStyle(surfaces.textPrimary)
            .surfaceBackground(.inset, cornerRadius: AppDesignTokens.Corner.row)
        }
        .buttonStyle(ResponsivePlainButtonStyle())
    }

    private var additionalLocationCount: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                L10n.text(
                    "额外位置 \(ByteFormat.count(workspace.configuredAdditionalRoots.count)) 个",
                    "\(ByteFormat.count(workspace.configuredAdditionalRoots.count)) additional locations"
                ),
                systemImage: workspace.configuredAdditionalRoots.isEmpty
                    ? "folder"
                    : "folder.fill.badge.checkmark"
            )
            .font(AppTypography.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(AppAppearanceColors.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(AppAppearanceColors.ink.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .fixedSize(horizontal: false, vertical: true)
            ForEach(workspace.configuredAdditionalRoots, id: \.self) { path in
                HStack {
                    Text(path)
                        .font(AppDesignTokens.Typography.metadata)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                        .accessibilityLabel(path)
                    Spacer(minLength: 8)
                    Button(L10n.text("移出范围", "Remove from Scope")) {
                        if workspace.externalRootPaths.contains(path) {
                            workspace.removeExternalRoot(path)
                        } else {
                            workspace.removeCustomRoot(path)
                        }
                    }
                    .controlSize(.regular)
                }
            }
        }
    }

    @ViewBuilder
    private var duplicateToolbarActions: some View {
        HStack(spacing: 8) {
            if workspace.isScanning {
                Button {
                    if workspace.phase == .paused {
                        store.resumeDuplicateFileScan()
                    } else {
                        store.pauseDuplicateFileScan()
                    }
                } label: {
                    Image(systemName: workspace.phase == .paused ? "play.fill" : "pause.fill")
                }
                .help(workspace.phase == .paused
                    ? L10n.text("继续扫描", "Resume Scan")
                    : L10n.text("暂停扫描", "Pause Scan"))
                .appButtonChrome(.secondary)
                .disabled(workspace.phase == .cancelling)

                Button(role: .cancel) {
                    store.cancelDuplicateFileScan()
                } label: {
                    Image(systemName: "xmark")
                }
                .help(L10n.text("取消扫描", "Cancel Scan"))
                .appButtonChrome(.secondary)
                .disabled(workspace.phase == .cancelling)
            } else {
                UnifiedToolbarButton(
                    title: scanButtonTitle,
                    systemImage: scanButtonSystemImage,
                    isLoading: false,
                    isDisabled: !workspace.canScan
                ) {
                    store.scanDuplicateFiles()
                }
                .help(workspace.scanUnavailableReason ?? "")
            }

            if !isSimilarPhotosRoute && !selectedItems.isEmpty {
                Menu {
                    Button {
                        store.requestVerifiedDuplicateCleanup(disposition: .quarantine, workspace: workspace)
                    } label: {
                        Label(L10n.text("移到隔离区（推荐）", "Move to Quarantine (Recommended)"), systemImage: "archivebox")
                    }
                    Button {
                        store.requestVerifiedDuplicateCleanup(disposition: .trash, workspace: workspace)
                    } label: {
                        Label(L10n.text("移到废纸篓", "Move to Trash"), systemImage: "trash")
                    }
                } label: {
                    Label(
                        L10n.text("查看清理计划 · \(ByteFormat.count(selectedItems.count)) 个", "Review Cleanup Plan · \(ByteFormat.count(selectedItems.count))"),
                        systemImage: "checkmark.shield"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var duplicateProgressLabel: some View {
        let progress = workspace.scanProgress ?? .initial
        return Text(L10n.text(
            "已扫描 \(ByteFormat.count(progress.scannedDirectories)) 个目录、\(ByteFormat.count(progress.scannedFiles)) 个文件；完整哈希 \(ByteFormat.count(progress.hashedFiles)) 个（\(ByteFormat.storageString(progress.hashedBytes))）",
            "\(ByteFormat.count(progress.scannedDirectories)) folders and \(ByteFormat.count(progress.scannedFiles)) files scanned; \(ByteFormat.count(progress.hashedFiles)) fully hashed (\(ByteFormat.storageString(progress.hashedBytes)))"
        ))
        .font(AppDesignTokens.Typography.secondary)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func chooseDuplicateRoot(externalVolume: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = externalVolume
            ? L10n.text("选择外接卷", "Choose External Volume")
            : L10n.text("添加", "Add")
        if externalVolume {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if externalVolume {
                let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsReadOnlyKey])
                guard values?.volumeIsInternal == false else {
                    store.errorMessage = L10n.text(
                        "请选择已挂载的外接卷；内置磁盘不会作为额外范围加入。",
                        "Choose a mounted external volume; the internal disk is not added as an extra scope."
                    )
                    continue
                }
                workspace.addExternalRoot(url.path)
            } else {
                workspace.addCustomRoot(url.path)
            }
        }
    }

    @ViewBuilder
    private var duplicateDataContent: some View {
        if allItems.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
                    if workspace.isScanning {
                        duplicateProgressPanel
                    } else {
                        duplicateEmptyState
                    }
                    duplicateCoveragePanel
                }
                .padding(AppDesignTokens.Layout.sectionPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
                    duplicateSummaryPanel

                    if workspace.isScanning {
                        duplicateProgressPanel
                    }

                    duplicateCleanupReportPanel
                    duplicateCoveragePanel

                    if groups.isEmpty {
                        EmptyUtilityPanel(systemImage: "magnifyingglass", title: emptyTitle)
                    } else {
                        LazyVStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                            Text(L10n.text("显示 \(ByteFormat.count(groups.count)) 组结果", "Showing \(ByteFormat.count(groups.count)) result groups"))
                                .font(AppDesignTokens.Typography.secondary)
                                .foregroundStyle(.secondary)

                            ForEach(groups) { group in
                                DuplicateGroupCard(
                                    group: group,
                                    allItems: allItems,
                                    store: store,
                                    workspace: workspace
                                )
                            }
                        }
                    }
                }
                .padding(AppDesignTokens.Layout.sectionPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var duplicateSummaryPanel: some View {
        Group {
            if isSimilarPhotosRoute {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("相似照片候选", "Similar Photo Candidates"))
                        .font(AppDesignTokens.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                    Text(L10n.text("\(ByteFormat.count(groups.count)) 组", "\(ByteFormat.count(groups.count)) groups"))
                        .font(AppDesignTokens.Typography.metricValue)
                        .monospacedDigit()
                    Text(L10n.text(
                        "仅供人工对照；视觉相近不等于内容完全相同。",
                        "For manual review only; visual similarity does not prove identical content."
                    ))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        duplicatePrimarySummary
                        Divider()
                            .frame(height: 52)
                        duplicateSummaryMetrics
                    }

                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                        duplicatePrimarySummary
                        duplicateSummaryMetrics
                    }
                }
            }
        }
        .padding(AppDesignTokens.Spacing.large)
        .fullBleedSection()
        .appMotionEntrance(delay: 0.035)
    }

    private var duplicatePrimarySummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text("扫描结果", "Scan Result"))
                .font(AppDesignTokens.Typography.compactLabel)
                .foregroundStyle(.secondary)
            Text(L10n.text("\(ByteFormat.count(allGroups.count)) 组", "\(ByteFormat.count(allGroups.count)) groups"))
                .font(AppDesignTokens.Typography.metricValue)
                .monospacedDigit()
            Text(scanTimeText)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    private var duplicateSummaryMetrics: some View {
        HStack(spacing: 20) {
            SmartCareMetric(
                title: L10n.text("内容已确认", "Content Confirmed"),
                value: L10n.items(confirmedFileCount),
                systemImage: "checkmark.shield.fill",
                tint: AppDesignTokens.Palette.tertiary
            )
            SmartCareMetric(
                title: L10n.text("逻辑重复数据", "Logical Duplicate Data"),
                value: ByteFormat.storageString(logicalDuplicateBytes),
                systemImage: "internaldrive.fill",
                tint: AppDesignTokens.Palette.storage
            )
            SmartCareMetric(
                title: L10n.text("物理可释放", "Physical Reclaimable"),
                value: physicalReclaimableBytes.map { ByteFormat.storageString($0) }
                    ?? L10n.text("待确认", "Unknown"),
                systemImage: "questionmark.circle",
                tint: AppDesignTokens.Palette.warning
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var duplicateRuntimeState: RuntimeWorkflowState {
        workspace.phase == .paused ? .paused : workspace.phase == .cancelling ? .stopping : .running
    }

    private var duplicateRuntimeTitle: String {
        if workspace.phase == .paused {
            return isSimilarPhotosRoute
                ? L10n.text("相似照片扫描已暂停", "Similar Photo Scan Paused")
                : L10n.text("重复文件扫描已暂停", "Duplicate Scan Paused")
        }
        if workspace.phase == .cancelling { return L10n.text("正在停止扫描", "Stopping Scan") }
        return switch workspace.scanProgress?.phase ?? .discovering {
        case .discovering: L10n.text("正在查找候选文件", "Discovering Candidate Files")
        case .fingerprinting: L10n.text("正在比对文件指纹", "Comparing File Fingerprints")
        case .hashing: L10n.text("正在确认文件内容", "Verifying File Contents")
        case .paused: isSimilarPhotosRoute
            ? L10n.text("相似照片扫描已暂停", "Similar Photo Scan Paused")
            : L10n.text("重复文件扫描已暂停", "Duplicate Scan Paused")
        case .finished: L10n.text("正在整理重复组", "Preparing Duplicate Groups")
        }
    }

    private var duplicateRuntimePage: some View {
        let progress = workspace.scanProgress ?? .initial
        return DuplicateFilesRunningPage(progress: progress, state: duplicateRuntimeState,
            title: duplicateRuntimeTitle, pageTitle: pageTitle, isSimilarPhotos: isSimilarPhotosRoute,
            canCancel: workspace.phase != .cancelling, onCancel: store.cancelDuplicateFileScan,
            onPauseOrResume: {
                if workspace.phase == .paused { store.resumeDuplicateFileScan() }
                else { store.pauseDuplicateFileScan() }
            })
    }

    private var duplicateRuntimeActions: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            Button {
                if workspace.phase == .paused { store.resumeDuplicateFileScan() }
                else { store.pauseDuplicateFileScan() }
            } label: {
                Label(workspace.phase == .paused ? L10n.text("继续", "Resume") : L10n.text("暂停", "Pause"),
                      systemImage: workspace.phase == .paused ? "play.fill" : "pause.fill")
            }
            .appButtonChrome(.secondary)
            Button(role: .cancel) { store.cancelDuplicateFileScan() } label: {
                Label(L10n.text("取消扫描", "Cancel Scan"), systemImage: "xmark")
            }
            .appButtonChrome(.secondary)
        }
        .disabled(workspace.phase == .cancelling)
    }

    private var duplicateProgressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            RuntimeInlineStatus(state: duplicateRuntimeState, title: duplicateRuntimeTitle)
            duplicateProgressLabel
            if let path = workspace.scanProgress?.currentPath {
                Text(path).font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(path)
            }
            HStack { Spacer(); duplicateRuntimeActions }
        }
        .padding(AppDesignTokens.Spacing.large)
        .fullBleedSection()
    }

    @ViewBuilder
    private var duplicateCoveragePanel: some View {
        if let coverage = workspace.scanCoverage {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text((workspace.lastCompletedScanScope ?? workspace.scanScope).coverageDescription)
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    let addedRoots = workspace.lastScanSelectedRootPaths
                    ForEach(Array(coverage.roots.enumerated()), id: \.offset) { _, root in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: root.status == .scanned ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(root.status == .scanned
                                    ? AppDesignTokens.Palette.success
                                    : AppDesignTokens.Palette.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(root.rootPath)
                                    .font(AppDesignTokens.Typography.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if addedRoots.contains(PathSafety.lexicalPath(root.rootPath)) {
                                    // N17: added locations are walked first with their own quota.
                                    Text(L10n.text("你添加的位置 · 先扫描、单独计数", "Added location · scanned first with its own quota"))
                                        .font(AppDesignTokens.Typography.compactLabel)
                                        .foregroundStyle(.secondary)
                                }
                                Text(root.status == .scanned
                                    ? L10n.text(
                                        "扫描 \(ByteFormat.count(root.scannedDirectories)) 个目录、\(ByteFormat.count(root.scannedFiles)) 个文件（\(ByteFormat.storageString(root.scannedBytes))）",
                                        "\(ByteFormat.count(root.scannedDirectories)) folders and \(ByteFormat.count(root.scannedFiles)) files scanned (\(ByteFormat.storageString(root.scannedBytes)))"
                                    )
                                    : duplicateSkipReasonTitle(root.skipReason))
                                    .font(AppDesignTokens.Typography.compactLabel)
                                    .foregroundStyle(.secondary)
                                if let cloudOnly = root.cloudOnlyFiles, cloudOnly > 0 {
                                    Text(L10n.text(
                                        "其中 \(ByteFormat.count(cloudOnly)) 个文件仅在云端，未下载比对",
                                        "\(ByteFormat.count(cloudOnly)) of them are cloud-only and were not compared"
                                    ))
                                    .font(AppDesignTokens.Typography.compactLabel)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let cloudOnly = coverage.cloudOnlySummary {
                        Label(cloudOnly, systemImage: "icloud")
                            .font(AppDesignTokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if coverage.contentReadUnresponsive == true {
                        Label(
                            L10n.text("磁盘或网络无响应，已停止等待部分文件；结果为部分覆盖，请检查连接后重试。", "The disk or network is unresponsive. Waiting for some files stopped; coverage is partial. Check the connection and retry."),
                            systemImage: "exclamationmark.circle"
                        )
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                    } else if coverage.reachedTimeLimit || coverage.reachedFileLimit
                        || coverage.reachedDirectoryLimit || coverage.reachedResultLimit {
                        Label(
                            L10n.text("本次扫描达到保护上限，结果为部分覆盖。", "This scan reached a safety limit and has partial coverage."),
                            systemImage: "exclamationmark.circle"
                        )
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Label(L10n.text("扫描覆盖报告", "Scan Coverage Report"), systemImage: "list.clipboard")
                        .font(AppDesignTokens.Typography.inlineTitle)
                    Spacer()
                    AppButton(
                        title: L10n.text("添加文件夹", "Add Folder"),
                        systemImage: "folder.badge.plus"
                    ) {
                        chooseDuplicateRoot(externalVolume: false)
                    }
                    AppButton(
                        title: L10n.text("外接卷", "External Volume"),
                        systemImage: "externaldrive.badge.plus"
                    ) {
                        chooseDuplicateRoot(externalVolume: true)
                    }
                }
            }
            .padding(AppDesignTokens.Spacing.large)
            .fullBleedSection()
        }
    }

    @ViewBuilder
    private var duplicateCleanupReportPanel: some View {
        if let progress = store.duplicateCleanupProgress {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text("正在安全处理", "Safely Handling Copies"), systemImage: "checkmark.shield")
                    .font(AppDesignTokens.Typography.inlineTitle)
                ProgressView(
                    value: Double(progress.processedItemCount),
                    total: Double(max(1, progress.totalItemCount))
                )
                Text(L10n.text(
                    "已处理 \(ByteFormat.count(progress.processedItemCount))/\(ByteFormat.count(progress.totalItemCount))，移动 \(ByteFormat.count(progress.movedItemCount))，跳过 \(ByteFormat.count(progress.skippedItemCount))，失败 \(ByteFormat.count(progress.failedItemCount))",
                    "Processed \(ByteFormat.count(progress.processedItemCount))/\(ByteFormat.count(progress.totalItemCount)); moved \(ByteFormat.count(progress.movedItemCount)), skipped \(ByteFormat.count(progress.skippedItemCount)), failed \(ByteFormat.count(progress.failedItemCount))"
                ))
                .font(AppDesignTokens.Typography.secondary)
                Button(L10n.text("取消剩余项目", "Cancel Remaining Items"), role: .cancel) {
                    store.cancelVerifiedDuplicateCleanupExecution()
                }
                .appButtonChrome(.secondary)
            }
            .padding(AppDesignTokens.Spacing.large)
            .fullBleedSection()
        } else if let report = store.duplicateCleanupReport, let refusal = report.startRefusal {
            // D214: nothing was tried; why, and that nothing moved.
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(CleanStartRefusalPresentation.title)
                        .font(AppDesignTokens.Typography.inlineTitle)
                    Text(CleanStartRefusalPresentation.message(refusal))
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L10n.text("关闭", "Dismiss")) {
                    store.dismissVerifiedDuplicateCleanupReport()
                }
                .appButtonChrome(.secondary)
            }
            .padding(AppDesignTokens.Spacing.large)
            .fullBleedSection()
        } else if let report = store.duplicateCleanupReport {
            HStack(spacing: 12) {
                Image(systemName: report.summary.failedItemCount == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.summary.failedItemCount == 0
                        ? AppDesignTokens.Palette.success
                        : AppDesignTokens.Palette.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("安全处理报告", "Safe Handling Report"))
                        .font(AppDesignTokens.Typography.inlineTitle)
                    Text(L10n.text(
                        "移动 \(ByteFormat.count(report.summary.movedItemCount))，跳过 \(ByteFormat.count(report.summary.skippedItemCount))，失败 \(ByteFormat.count(report.summary.failedItemCount))。尚未永久删除。",
                        "Moved \(ByteFormat.count(report.summary.movedItemCount)), skipped \(ByteFormat.count(report.summary.skippedItemCount)), failed \(ByteFormat.count(report.summary.failedItemCount)). Nothing was permanently deleted."
                    ))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    // D93: four groups with reasons; moved copies are not freed space.
                    OperationCompletionTallyView(tally: OperationCompletionTally(report: report))
                }
                Spacer()
                if !report.restorableReceipts.isEmpty {
                    Button(L10n.text("恢复", "Restore")) {
                        store.requestRestoreLatestVerifiedDuplicateCleanup()
                    }
                    .appButtonChrome(.secondary)
                }
                Button(L10n.text("关闭", "Dismiss")) {
                    store.dismissVerifiedDuplicateCleanupReport()
                }
                .appButtonChrome(.secondary)
            }
            .padding(AppDesignTokens.Spacing.large)
            .fullBleedSection()
        }
    }

    private func duplicateSkipReasonTitle(_ reason: DuplicateFileScanSkipReason?) -> String {
        switch reason {
        case .excluded, .policyExcluded:
            L10n.text("已按排除规则跳过", "Skipped by exclusion policy")
        case .missing: L10n.text("位置不存在", "Location is missing")
        case .notDirectory: L10n.text("不是可扫描目录", "Not a scannable folder")
        case .symbolicLink: L10n.text("符号链接目录已跳过", "Symbolic-link folder skipped")
        case .package: L10n.text("应用或软件包已跳过", "App or package skipped")
        case .pseudoFilesystem: L10n.text("伪文件系统已跳过", "Pseudo filesystem skipped")
        case .timeMachine: L10n.text("Time Machine 位置已跳过", "Time Machine location skipped")
        case .permissionDenied: L10n.text("没有读取权限", "Permission denied")
        case .timedOut: L10n.text("目录读取超时", "Folder read timed out")
        case .unreadable: L10n.text("目录不可读取", "Folder is unreadable")
        case .depthLimit: L10n.text("达到目录深度上限", "Folder depth limit reached")
        case .timeLimit: L10n.text("达到扫描时间上限", "Scan time limit reached")
        case .fileLimit: L10n.text("达到文件数量上限", "File count limit reached")
        case .directoryLimit: L10n.text("达到目录数量上限", "Folder count limit reached")
        case .cancelled: L10n.text("扫描已取消", "Scan cancelled")
        case .cloudPlaceholder: L10n.text("仅在云端，未下载比对", "Cloud-only; not downloaded to compare")
        case nil: L10n.text("未扫描", "Not scanned")
        }
    }

    private var duplicateEmptyState: some View {
        // With cloud-only files skipped, "nothing found" covers only what was compared.
        let cloudOnly = workspace.scanCoverage?.cloudOnlySummary
        return EmptyStateView(
            title: isSimilarPhotosRoute
                ? L10n.text("未发现相似照片候选", "No Similar Photo Candidates Found")
                : cloudOnly == nil
                    ? L10n.text("未发现内容相同文件", "No Identical Files Found")
                    : L10n.text("已比对的文件中未发现内容相同文件", "No Identical Files Among Compared Files"),
            detail: [scanTimeText, cloudOnly].compactMap { $0 }.joined(separator: "\n"),
            systemImage: "checkmark.seal.fill",
            density: .workspace
        )
        .appMotionEntrance(distance: 6)
    }

    private var duplicateScanStatus: ScanStatusPresentation {
        if workspace.isScanning {
            return .scanning(scanButtonTitle)
        }
        if store.isScanning {
            return .idle(scanButtonTitle)
        }
        return .neverScanned
    }

    private var scanButtonTitle: String {
        if store.isCheckingScanReadiness {
            return L10n.text("检查权限", "Checking Access")
        }
        if store.isScanning {
            return L10n.text("正在扫描", "Scanning")
        }
        if workspace.isScanning {
            return L10n.text("扫描中", "Scanning")
        }
        if isSimilarPhotosRoute {
            return workspace.hasScanned
                ? L10n.text("重新扫描相似照片", "Rescan Similar Photos")
                : L10n.text("扫描相似照片", "Scan Similar Photos")
        }
        return workspace.hasScanned
            ? L10n.text("重新扫描重复文件", "Rescan Duplicate Files")
            : L10n.text("扫描重复文件", "Scan Duplicates")
    }

    private var duplicateScanScopeDetail: String {
        scopeDetail(workspace.scanScope)
    }

    private func scopeDetail(_ scope: DuplicateFileScanScope) -> String {
        switch scope {
        case .userFiles:
            L10n.text(
                "扫描常用用户文件夹和你明确选择的位置。",
                "Scans common user folders and locations you select."
            )
        case .wholeComputer:
            L10n.text(
                "扫描用户数据区和你明确选择的卷。",
                "Scans user data areas and volumes you select."
            )
        case .selectedLocations:
            L10n.text(
                "只扫描你添加的文件夹和外接卷，不碰默认位置。",
                "Scans only the folders and volumes you add, never the default folders."
            )
        }
    }

    private var scanButtonSystemImage: String {
        if workspace.isBusy {
            return "hourglass"
        }
        return workspace.hasScanned ? "arrow.clockwise" : "viewfinder"
    }

    private var scanTimeText: String {
        guard let seconds = workspace.scanSeconds else {
            return L10n.text("已完成", "Complete")
        }
        return L10n.scanSeconds(seconds)
    }

    private var emptyTitle: String {
        if isSimilarPhotosRoute {
            if !workspace.searchText.trimmed.isEmpty {
                return L10n.text("没有匹配的相似照片", "No matching similar photos")
            }
            return workspace.hasScanned
                ? L10n.text("未发现相似照片候选", "No similar photo candidates found")
                : L10n.text("尚未扫描相似照片", "Similar photos have not been scanned")
        }
        if !workspace.searchText.trimmed.isEmpty {
            return L10n.text("没有匹配的重复文件", "No matching duplicate files")
        }
        if workspace.hasScanned {
            return L10n.text("未发现内容相同文件", "No identical files found")
        }
        return L10n.text("尚未扫描重复文件", "Duplicate files have not been scanned")
    }
}

struct DuplicateCleanupConfirmationPresentation: Equatable {
    struct Group: Identifiable, Equatable {
        let id: String
        let retainedPaths: [String]
        let destinationPaths: [String]
    }

    let disposition: CleanupDisposition
    let readyCount: Int
    let skippedCount: Int
    let groups: [Group]

    init?(plan: CleanPlan?, preflight: CleanPreflightReport?) {
        guard let plan,
              let preflight,
              preflight.planID == plan.id,
              preflight.isConfirmable else { return nil }

        let readyIDs = Set(preflight.items.compactMap {
            $0.status == .ready ? $0.planItemID : nil
        })
        let readyItems = plan.items.filter { readyIDs.contains($0.id) }
        guard readyItems.count == readyIDs.count,
              readyItems.count == preflight.readyCount else { return nil }

        var groupedPaths = [String: (retained: Set<String>, destination: Set<String>)]()
        for item in readyItems {
            guard let evidence = item.verifiedDuplicateEvidence,
                  !evidence.retainedCopies.isEmpty else { return nil }
            var paths = groupedPaths[evidence.groupID] ?? ([], [])
            paths.destination.insert(item.sourceURL.path)
            paths.retained.formUnion(evidence.retainedCopies.map(\.url.path))
            groupedPaths[evidence.groupID] = paths
        }

        let groups = groupedPaths.map { groupID, paths in
            Group(
                id: groupID,
                retainedPaths: paths.retained.sorted(by: Self.pathSort),
                destinationPaths: paths.destination.sorted(by: Self.pathSort)
            )
        }
        .sorted {
            Self.pathSort(
                $0.destinationPaths.first ?? $0.id,
                $1.destinationPaths.first ?? $1.id
            )
        }
        guard !groups.isEmpty,
              groups.allSatisfy({ !$0.retainedPaths.isEmpty && !$0.destinationPaths.isEmpty }) else {
            return nil
        }

        self.disposition = plan.disposition
        self.readyCount = preflight.readyCount
        self.skippedCount = preflight.skippedCount
        self.groups = groups
    }

    private static func pathSort(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

private struct DuplicateCleanupConfirmationSheet: View {
    let presentation: DuplicateCleanupConfirmationPresentation?
    /// D93: the six fixed confirmation fields.
    let facts: OperationConfirmationFacts?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            Label(
                L10n.text("确认安全处理", "Confirm Safe Handling"),
                systemImage: "checkmark.shield"
            )
            .font(AppDesignTokens.Typography.sectionTitle)

            Text(L10n.text(
                "请逐组核对保留副本和将要移动的副本。执行时仍会再次验证身份、大小和完整 SHA-256。",
                "Review the retained and moving copies in every group. Identity, size, and full SHA-256 are checked again at execution time."
            ))
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)

            if let presentation {
                if let facts {
                    OperationConfirmationFactsView(facts: facts, showsItemList: false)
                }
                HStack(spacing: AppDesignTokens.Spacing.medium) {
                    Label(
                        L10n.text("可执行 \(ByteFormat.count(presentation.readyCount)) 个", "\(ByteFormat.count(presentation.readyCount)) ready"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(AppDesignTokens.Palette.success)
                    Label(
                        L10n.text("跳过 \(ByteFormat.count(presentation.skippedCount)) 个", "\(ByteFormat.count(presentation.skippedCount)) skipped"),
                        systemImage: "minus.circle"
                    )
                    .foregroundStyle(presentation.skippedCount == 0 ? .secondary : AppDesignTokens.Palette.warning)
                }
                .font(AppDesignTokens.Typography.compactLabelEmphasis)

                List {
                    ForEach(Array(presentation.groups.enumerated()), id: \.element.id) { index, group in
                        Section {
                            DuplicateCleanupConfirmationPathsRow(
                                title: L10n.text("保留", "Keep"),
                                systemImage: "checkmark.shield.fill",
                                tint: AppDesignTokens.Palette.success,
                                paths: group.retainedPaths
                            )
                            DuplicateCleanupConfirmationPathsRow(
                                title: destinationTitle(for: presentation.disposition),
                                systemImage: presentation.disposition == .quarantine ? "archivebox.fill" : "trash.fill",
                                tint: AppDesignTokens.Palette.warning,
                                paths: group.destinationPaths
                            )
                        } header: {
                            Text(L10n.text("重复组 \(index + 1)", "Duplicate Group \(index + 1)"))
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220, maxHeight: 420)
                .accessibilityLabel(L10n.text("重复文件确认明细", "Duplicate file confirmation details"))
            } else {
                Label(
                    L10n.text("执行计划已失效，请取消后重新选择。", "The plan expired. Cancel and select the copies again."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.text("取消", "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.text("取消安全处理", "Cancel safe handling"))
                Button(L10n.text("确认执行", "Confirm"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(presentation == nil)
                    .accessibilityLabel(L10n.text("确认执行安全处理", "Confirm safe handling"))
            }
        }
        .padding(AppDesignTokens.Spacing.large)
        .frame(width: 700)
    }

    private func destinationTitle(for disposition: CleanupDisposition) -> String {
        disposition == .quarantine
            ? L10n.text("将移入隔离区", "Move to Quarantine")
            : L10n.text("将移入废纸篓", "Move to Trash")
    }
}

private struct DuplicateCleanupConfirmationPathsRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(title, systemImage: systemImage)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(tint)
            ForEach(paths, id: \.self) { path in
                Text(path)
                    .font(AppDesignTokens.Typography.metadata)
                    .monospaced()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(title): \(path)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

enum DuplicateFilesPresenter {
    static func groups(
        from items: [StorageItem],
        matching query: String = "",
        filter: DuplicateResultFilter = .all,
        sort: DuplicateResultSort = .reclaimable
    ) -> [DuplicateDisplayGroup] {
        let completeGroups = displayGroups(from: items)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = completeGroups.filter { group in
            switch filter {
            case .all: true
            case .exact: group.isContentConfirmed
            case .sameName: group.candidateRule == .sameName
            case .sameSize: group.candidateRule == .sameSize
            case .sameType: group.candidateRule == .sameType
            case .similarImage: group.candidateRule == .similarImage
            case .candidates: !group.isContentConfirmed
            }
        }.filter { group in
            guard !trimmedQuery.isEmpty else { return true }
            return group.items.contains { item in
                item.title.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.path.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.kind.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .reclaimable:
                if lhs.logicalDuplicateBytes != rhs.logicalDuplicateBytes {
                    return lhs.logicalDuplicateBytes > rhs.logicalDuplicateBytes
                }
            case .size:
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            case .name:
                break
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func displayGroups(from items: [StorageItem]) -> [DuplicateDisplayGroup] {
        let grouped = Dictionary(grouping: items, by: duplicateKey(for:))
        return grouped.map { key, items in
            let sortedItems = items.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let isContentConfirmed = sortedItems.allSatisfy {
                $0.duplicateMatchKind == DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue
            }
            let candidateRule = isContentConfirmed
                ? nil
                : sortedItems.first?.duplicateMatchKind.flatMap(
                    DuplicateFileCandidateGroup.Rule.init(rawValue:)
                )
            return DuplicateDisplayGroup(
                id: key,
                title: isContentConfirmed
                    ? L10n.text("内容完全相同", "Identical Content")
                    : candidateRule?.title ?? L10n.text("相似候选", "Review Candidate"),
                sizeBytes: sortedItems.first?.sizeBytes ?? 0,
                items: sortedItems,
                isContentConfirmed: isContentConfirmed,
                candidateRule: candidateRule,
                relationship: isContentConfirmed
                    ? sortedItems.first?.duplicateRelationship.flatMap(
                        DuplicateFileStorageRelationship.init(rawValue:)
                    ) ?? .unknown
                    : .unknown,
                physicalReclaimableBytes: isContentConfirmed
                    ? sortedItems.compactMap(\.duplicatePhysicalReclaimableBytes).first
                    : nil
            )
        }
        .filter { $0.items.count > 1 }
        .sorted {
            if $0.logicalDuplicateBytes == $1.logicalDuplicateBytes {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.logicalDuplicateBytes > $1.logicalDuplicateBytes
        }
    }

    private static func duplicateKey(for item: StorageItem) -> String {
        item.duplicateGroupID ?? "legacy|\(item.title.lowercased())|\(item.sizeBytes)"
    }
}

struct DuplicateDisplayGroup: Identifiable {
    let id: String
    let title: String
    let sizeBytes: Int64
    let items: [StorageItem]
    let isContentConfirmed: Bool
    let candidateRule: DuplicateFileCandidateGroup.Rule?
    let relationship: DuplicateFileStorageRelationship
    let physicalReclaimableBytes: Int64?

    var logicalDuplicateBytes: Int64 {
        Int64(max(0, items.count - 1)) * sizeBytes
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateDisplayGroup
    let allItems: [StorageItem]
    @ObservedObject var store: ScanStore
    @ObservedObject var workspace: DuplicateFilesStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ArtworkIconTile(
                    systemImage: "doc.on.doc.fill",
                    filter: nil,
                    tint: AppDesignTokens.Palette.tertiary,
                    size: UtilitySizing.supportIcon,
                    glyphSize: UtilitySizing.supportGlyph,
                    showsGlass: true
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(AppDesignTokens.Typography.inlineTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        MetadataPill(text: L10n.items(group.items.count), systemImage: "number", tint: AppDesignTokens.Palette.tertiary)
                        MetadataPill(
                            text: ByteFormat.storageString(group.candidateRule == .similarImage
                                ? group.items.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
                                : group.sizeBytes),
                            systemImage: "doc", tint: .secondary
                        )
                        MetadataPill(
                            text: group.isContentConfirmed
                                ? group.relationship.title
                                : group.candidateRule == .similarImage
                                    ? L10n.text("仅视觉候选", "Visual candidate only")
                                    : L10n.text("人工候选", "Review candidate"),
                            systemImage: group.isContentConfirmed ? "checkmark.seal" : "exclamationmark.triangle",
                            tint: group.isContentConfirmed && group.relationship != .unknown
                                ? AppDesignTokens.Palette.success
                                : AppDesignTokens.Palette.warning
                        )
                        if group.isContentConfirmed {
                            MetadataPill(
                            // D100 G1: copies with one clone ID share all of their blocks.
                            text: group.relationship == .apfsClone
                                ? L10n.text("已是克隆，删除几乎不释放空间", "Already clones; deleting frees almost no space")
                                : group.physicalReclaimableBytes.map {
                                    L10n.text("物理可释放 \(ByteFormat.storageString($0))", "Physical \(ByteFormat.storageString($0))")
                                } ?? L10n.text("物理可释放待确认", "Physical savings unknown"),
                            systemImage: "internaldrive",
                            tint: AppDesignTokens.Palette.warning
                            )
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(AppDesignTokens.Spacing.medium)

            Divider()

            if group.candidateRule == .similarImage {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                    Label(
                        L10n.text(
                            "仅供并排比对；相似不代表文件相同，无法直接安全清理。",
                            "Compare side by side. Similarity does not prove identical files or permit safe cleanup."
                        ),
                        systemImage: "eye"
                    )
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(group.items) { item in
                            SimilarImageReviewTile(item: item, store: store)
                        }
                    }
                }
                .padding(AppDesignTokens.Spacing.medium)
            } else {
                ForEach(group.items) { item in
                    DuplicateFileRow(
                        item: item,
                        allItems: allItems,
                        store: store,
                        workspace: workspace
                    )
                    if item.id != group.items.last?.id {
                        Divider()
                            .padding(.leading, 76)
                    }
                }
            }
        }
        .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: AppDesignTokens.Palette.tertiary, prominence: .quiet)
        .accessibilityElement(children: .contain)
    }
}

private struct SimilarImageReviewTile: View {
    let item: StorageItem
    @ObservedObject var store: ScanStore
    @State private var thumbnail: NSImage?
    @State private var previewUnavailableReason: String?
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: AppDesignTokens.Radius.glassControl)
                    .fill(AppDesignTokens.Palette.tertiary.opacity(0.08))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 27))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 146)
            .clipShape(RoundedRectangle(cornerRadius: AppDesignTokens.Radius.glassControl))

            Text(item.title)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.path)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(item.path)
            Text(ByteFormat.storageString(item.sizeBytes))
                .font(AppDesignTokens.Typography.metadata)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if let previewUnavailableReason {
                Text(previewUnavailableReason)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    quickLookURL = URL(fileURLWithPath: item.path)
                } label: {
                    Label(L10n.text("预览原件", "Quick Look"), systemImage: "eye")
                }
                .appButtonChrome(.secondary)
                Button {
                    store.reveal(item.path)
                } label: {
                    Label(L10n.text("访达", "Finder"), systemImage: "folder")
                }
                .appButtonChrome(.secondary)
            }
            .disabled(item.status != .available)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppDesignTokens.Radius.settingsPanel)
                .fill(.quaternary.opacity(0.35))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("相似图片候选：\(item.title)", "Similar image candidate: \(item.title)"))
        .quickLookPreview($quickLookURL)
        .task(id: item.id) {
            guard item.status == .available else { return }
            let loaded = await SimilarImagePreviewCache.shared.loadedIcon(for: item.path)
            guard !Task.isCancelled else { return }
            thumbnail = loaded.image
            previewUnavailableReason = loaded.unavailableReason
        }
    }
}

private struct DuplicateFileRow: View {
    let item: StorageItem
    let allItems: [StorageItem]
    @ObservedObject var store: ScanStore
    @ObservedObject var workspace: DuplicateFilesStore
    @State private var quickLookURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            if item.duplicateMatchKind == DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue,
               item.status == .available {
                Toggle(
                    isOn: Binding(
                        get: { workspace.isSelected(item) },
                        set: {
                            workspace.setSelected(
                                $0,
                                item: item,
                                allItems: allItems
                            )
                        }
                    )
                ) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(workspace.isSelected(item)
                    ? L10n.text("取消选择此副本", "Deselect this copy")
                    : L10n.text("选择此副本", "Select this copy"))
            }

            ArtworkIconTile(
                systemImage: "doc.fill",
                filter: nil,
                tint: AppDesignTokens.Palette.tertiary,
                size: UtilitySizing.smallIcon,
                glyphSize: UtilitySizing.smallGlyph,
                showsGlass: true
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.path)
                    .font(AppDesignTokens.Typography.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(item.path)
                    .accessibilityLabel(item.path)
                Text(item.status == .movedToTrash
                    ? L10n.text("已移动到可恢复位置", "Moved to a recoverable location")
                    : item.duplicateMatchKind == DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue
                        ? L10n.text("完整 SHA-256 已确认", "Full SHA-256 confirmed")
                        : L10n.text("人工候选 · 默认不选", "Review candidate · Unselected by default"))
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .focusable()
            .onKeyPress(.space) {
                guard item.status == .available else { return .ignored }
                quickLookURL = URL(fileURLWithPath: item.path)
                return .handled
            }
            .onTapGesture(count: 2) {
                if item.status == .available { quickLookURL = URL(fileURLWithPath: item.path) }
            }

            Spacer(minLength: 10)

            Text(ByteFormat.storageString(item.sizeBytes))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            AppIconButton(
                title: L10n.text("快速预览", "Quick Look"),
                systemImage: "eye",
                kind: .toolbar
            ) {
                quickLookURL = URL(fileURLWithPath: item.path)
            }
            .disabled(item.status != .available)

            Button {
                store.copyPath(item.path)
            } label: {
                Label(L10n.text("复制", "Copy"), systemImage: "doc.on.doc")
            }
            .controlSize(.regular)

            Button {
                store.reveal(item.path)
            } label: {
                Label(L10n.text("在访达中显示", "Show in Finder"), systemImage: "folder")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, AppDesignTokens.Spacing.medium)
        .accessibilityElement(children: .contain)
        .quickLookPreview($quickLookURL)
    }
}

private extension AppUninstallListFilter {
    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .reviewRecommended: "sparkle.magnifyingglass"
        case .thirdParty: "person.crop.square"
        case .apple: "apple.logo"
        case .withLeftovers: "externaldrive.badge.xmark"
        case .longUnused: "clock.badge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .all: AppDesignTokens.Palette.information
        case .reviewRecommended: AppDesignTokens.Palette.information
        case .thirdParty: AppDesignTokens.Palette.secondary
        case .apple: AppDesignTokens.Palette.information
        case .withLeftovers: AppDesignTokens.Palette.warning
        case .longUnused: AppDesignTokens.Palette.diagnostic
        }
    }
}

private extension AppUpdateListFilter {
    var title: String {
        switch self {
        case .all:
            L10n.text("全部", "All")
        case .updateAvailable:
            L10n.text("有更新", "Updates")
        case .automatic:
            L10n.text("可自动更新", "Automatic")
        case .websiteDownload:
            L10n.text("官网可下载", "Website Download")
        case .websiteManual:
            L10n.text("官网完成", "Website")
        case .applicationInternal:
            L10n.text("应用内更新", "In-app Update")
        case .appStore:
            L10n.text("App Store", "App Store")
        case .homebrew:
            "Homebrew"
        case .sparkle:
            "Sparkle"
        case .upToDate:
            L10n.text("已是最新", "Up to Date")
        case .sourceUnconfirmed:
            L10n.text("来源待确认", "Source Unconfirmed")
        case .failed:
            L10n.text("更新失败", "Failed")
        case .ignored:
            L10n.text("已忽略", "Ignored")
        case .systemManaged:
            L10n.text("系统管理", "System Managed")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .updateAvailable: "arrow.down.circle"
        case .automatic: "bolt"
        case .websiteDownload: "safari"
        case .websiteManual: "globe"
        case .applicationInternal: "arrow.triangle.2.circlepath"
        case .appStore: "bag"
        case .homebrew: "terminal"
        case .sparkle: "sparkles"
        case .upToDate: "checkmark.circle"
        case .sourceUnconfirmed: "questionmark.circle"
        case .failed: "exclamationmark.triangle"
        case .ignored: "eye.slash"
        case .systemManaged: "apple.logo"
        }
    }

    var tint: Color {
        switch self {
        case .all: AppDesignTokens.Palette.secondary
        case .updateAvailable, .automatic, .websiteDownload, .applicationInternal:
            AppDesignTokens.Palette.information
        case .websiteManual, .sourceUnconfirmed:
            AppDesignTokens.Palette.warning
        case .appStore: AppDesignTokens.Palette.information
        case .homebrew: AppDesignTokens.Palette.warning
        case .sparkle: AppDesignTokens.Palette.diagnostic
        case .upToDate: AppDesignTokens.Palette.success
        case .failed: AppDesignTokens.Palette.destructive
        case .ignored, .systemManaged: .secondary
        }
    }
}

private struct UtilityHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ModulePageHeader(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage
        ) {
            actions
        }
    }
}

private struct UtilitySearchField: View {
    let placeholder: String
    @Binding var text: String
    let tint: Color

    var body: some View {
        TaskSearchField(placeholder: placeholder, text: $text, tint: tint)
    }
}

private struct UtilityMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            AppSymbolIcon(
                systemImage: systemImage,
                role: .pageFeature,
                tint: .secondary,
                isDecorative: true
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(AppDesignTokens.Typography.metricValue)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(AppDesignTokens.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct MemoryOptimizationResultPanel: View {
    let result: MemoryOptimizationResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // D58: finished, nothing needed, restricted and failed actions
            // show their state picture; others keep the status tile.
            GeneratedArtView(art: statusArt, variant: .header) {
                ArtworkIconTile(
                    systemImage: statusImage,
                    filter: nil,
                    tint: statusTint,
                    size: UtilitySizing.supportIcon,
                    glyphSize: UtilitySizing.supportGlyph,
                    showsGlass: true,
                    showsGlow: result.status == .completed
                )
            }
            .frame(width: UtilitySizing.supportIcon, height: UtilitySizing.supportIcon)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(L10n.text("最近一次内存操作", "Latest Memory Action"))
                        .font(AppDesignTokens.Typography.inlineTitle)
                    MetadataPill(
                        text: statusTitle,
                        systemImage: statusImage,
                        tint: statusTint
                    )
                    MetadataPill(
                        text: L10n.scanSeconds(result.durationSeconds),
                        systemImage: "timer",
                        tint: .secondary
                    )
                }

                Text(statusDetail)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    MetadataPill(
                        text: estimatedReductionText,
                        systemImage: "clock.arrow.circlepath",
                        tint: AppDesignTokens.Palette.information
                    )
                    MetadataPill(
                        text: observedAppDeltaText,
                        systemImage: "memorychip",
                        tint: AppDesignTokens.Palette.storage
                    )
                    MetadataPill(
                        text: availableDeltaText,
                        systemImage: result.availableDeltaBytes >= 0 ? "plus.circle.fill" : "minus.circle.fill",
                        tint: availableDeltaTint
                    )
                    MetadataPill(
                        text: pressureChangeText,
                        systemImage: "gauge.with.dots.needle.50percent",
                        tint: statusTint
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: statusTint, elevated: true, prominence: .regular)
        .appMotionEntrance(distance: 6)
    }

    private var statusTitle: String {
        switch result.status {
        case .completed:
            L10n.text("退出已验证", "Exit Verified")
        case .partial:
            L10n.text("部分完成", "Partial")
        case .cancelled:
            L10n.text("已取消", "Cancelled")
        case .verificationFailed:
            L10n.text("无法验证", "Unverified")
        case .notNeeded:
            L10n.text("无需处理", "Not Needed")
        case .restricted:
            L10n.text("系统限制", "Restricted")
        case .timedOut:
            L10n.text("已停止等待", "Stopped Waiting")
        case .unavailable:
            L10n.text("测量不可用", "Unavailable")
        }
    }

    private var statusDetail: String {
        result.detail
    }

    private var estimatedReductionText: String {
        guard let execution = result.executionResult else {
            return L10n.text("未执行应用退出", "No app quit performed")
        }
        return L10n.text(
            "预计应用减少 \(ByteFormat.memoryString(Int64(clamping: execution.estimatedApplicationReductionBytes)))",
            "Estimated app reduction \(ByteFormat.memoryString(Int64(clamping: execution.estimatedApplicationReductionBytes)))"
        )
    }

    private var observedAppDeltaText: String {
        guard let delta = result.executionResult?.observedApplicationMemoryDeltaBytes else {
            return L10n.text("应用变化不可用", "App change unavailable")
        }
        let value = ByteFormat.memoryString(magnitude(delta))
        if delta > 0 {
            return L10n.text("应用实测减少 \(value)", "Observed app reduction \(value)")
        }
        if delta < 0 {
            return L10n.text("应用实测增加 \(value)", "Observed app increase \(value)")
        }
        return L10n.text("应用实测无变化", "Observed app memory unchanged")
    }

    private var availableDeltaText: String {
        let delta = result.executionResult?.observedAvailableMemoryDeltaBytes
            ?? result.availableDeltaBytes
        let value = ByteFormat.memoryString(magnitude(delta))
        if delta > 0 {
            return L10n.text("可用增加 \(value)", "\(value) more available")
        }
        if delta < 0 {
            return L10n.text("可用减少 \(value)", "\(value) less available")
        }
        return L10n.text("可用无变化", "Available unchanged")
    }

    private var availableDeltaTint: Color {
        let delta = result.executionResult?.observedAvailableMemoryDeltaBytes
            ?? result.availableDeltaBytes
        return delta >= 0 ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning
    }

    private var pressureChangeText: String {
        guard let execution = result.executionResult else {
            guard let pressure = result.snapshot.reportablePressureLevel else {
                return L10n.text("压力不可用", "Pressure unavailable")
            }
            return L10n.text("压力 \(pressure.title)", "Pressure \(pressure.title)")
        }
        guard
            let before = execution.snapshotBefore.reportablePressureLevel,
            let after = execution.snapshotAfter?.reportablePressureLevel
        else {
            return L10n.text("压力变化不可用", "Pressure change unavailable")
        }
        return L10n.text(
            "压力 \(before.title) → \(after.title)",
            "Pressure \(before.title) → \(after.title)"
        )
    }

    private func magnitude(_ value: Int64) -> Int64 {
        value == Int64.min ? Int64.max : abs(value)
    }

    private var statusArt: GeneratedArt? {
        switch result.status {
        case .completed: .stateSuccess
        case .notNeeded: .stateAllClear
        case .partial, .restricted: .statePermission
        case .timedOut, .verificationFailed, .unavailable: .stateError
        case .cancelled: nil
        }
    }

    private var statusImage: String {
        switch result.status {
        case .completed:
            "checkmark.seal.fill"
        case .notNeeded:
            "leaf.fill"
        case .partial, .restricted:
            "lock.fill"
        case .timedOut, .verificationFailed:
            "timer"
        case .cancelled:
            "xmark.circle.fill"
        case .unavailable:
            "questionmark.circle.fill"
        }
    }

    private var statusTint: Color {
        switch result.status {
        case .completed:
            AppDesignTokens.Palette.success
        case .notNeeded:
            AppDesignTokens.Palette.information
        case .partial, .restricted, .timedOut, .verificationFailed:
            AppDesignTokens.Palette.warning
        case .cancelled, .unavailable:
            .secondary
        }
    }
}

private struct MemoryReleasePanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.pageLayout) private var pageLayout
    @Environment(\.moduleTheme) private var moduleTheme
    @AppSurfaces private var surfaces
    let snapshot: MemorySnapshot
    let processSnapshot: MemorySnapshot
    let trendPoints: [MenuBarTelemetryPoint]
    @ObservedObject var store: ScanStore
    @State private var showsMetricDetails = false
    var isLandingSummary = false
    var compactLandingSummary = false
    var landingTrendHeight: CGFloat = 48
    var integratesWithCanvas = false

    private var usedRatio: Double? {
        snapshot.measuredUsedRatio
    }

    private var usedPercentText: String {
        usedRatio.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    private var pressureHeadroomText: String {
        snapshot.pressureHeadroomPercent.map {
            L10n.text("系统压力余量 \($0)%", "System pressure headroom \($0)%")
        } ?? L10n.text("系统压力余量不可用", "System pressure headroom unavailable")
    }

    private func byteText(_ measurement: MemoryMeasurement<UInt64>) -> String {
        measurement.value.map { ByteFormat.memoryString(Int64(clamping: $0)) } ?? "—"
    }

    private var releaseTint: Color {
        switch snapshot.reportablePressureLevel {
        case .critical:
            AppDesignTokens.Palette.destructive
        case .elevated:
            AppDesignTokens.Palette.warning
        case .normal:
            AppDesignTokens.Palette.success
        case .none:
            AppDesignTokens.Palette.primaryText
        }
    }

    private var cleanupPlan: MemoryCleanupPlan {
        processSnapshot.cleanupPlan
    }

    private var isObserving: Bool {
        cleanupPlan.primaryAction == .observe
    }

    private var summaryTitle: String {
        isObserving
            ? L10n.text("内存状态", "Memory Status")
            : L10n.text("处理建议", "Recommended Action")
    }

    private var summaryValue: String {
        isObserving
            ? byteText(snapshot.measurements.availableBytes)
            : ByteFormat.memoryString(cleanupPlan.estimatedRecoverableBytes)
    }

    private var summaryCaption: String {
        isObserving
            ? L10n.text("当前可用", "available now")
            : L10n.text("预计应用占用减少", "estimated app reduction")
    }

    private var page: PageLayout {
        pageLayout ?? PageLayout.approximated(from: layout)
    }

    private var isShort: Bool { page.height == .short }

    /// The pressure ring leads at 104 pt in wide windows, 92 pt in regular
    /// ones (so the trend keeps ~260 pt), 74 pt in short ones.
    private var pressureRingSide: CGFloat {
        isLandingSummary ? 64 : (isShort ? 66 : (page.width >= .wide ? 104 : 92))
    }

    private var usageRingSide: CGFloat {
        isLandingSummary ? 48 : (isShort ? 56 : (page.width >= .wide ? 80 : 70))
    }

    /// D53 V0: the overview in one row — the pressure ring leads, the usage
    /// ring follows, the recommendation, then the trend filling the rest.
    var body: some View {
        if isLandingSummary {
            VStack(alignment: .leading, spacing: 8) {
                if compactLandingSummary {
                    compactDashboardSummary
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("内存摘要", "Memory Summary"))
                                .font(AppDesignTokens.TypeScale.sectionTitle)
                                .accessibilityAddTraits(.isHeader)
                            rings
                        }
                        recommendationSummary(includesAction: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    memoryTrendRegion
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
        SurfaceCard(padding: integratesWithCanvas ? 0 : (isShort ? 10 : 16), isIntegrated: integratesWithCanvas) {
            VStack(alignment: .leading, spacing: 10) {
#if DEBUG || STORAGE_CLEANER_BETA
                if MiniWindowDemoData.isEnabled {
                    Text("FIXTURE · " + L10n.text("内存摘要与历史", "Memory summary and history"))
                        .font(AppDesignTokens.TypeScale.caption)
                        .foregroundStyle(surfaces.textTertiary)
                }
#endif
                if isShort {
                    // Short windows keep the list visible: no trend, and the
                    // action moves to the trailing edge of the same row.
                    HStack(alignment: .center, spacing: 16) {
                        rings
                        recommendationSummary(includesAction: false)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        if !isObserving {
                            // Narrow and short: the icon, with its title as help.
                            if page.width == .compact {
                                recommendedActionButton.labelStyle(.iconOnly).fixedSize()
                            } else {
                                recommendedActionButton.fixedSize()
                            }
                        }
                    }
                } else if page.width >= .regular {
                    HStack(alignment: .center, spacing: page.width >= .wide ? 22 : 16) {
                        rings
                        recommendationSummary(includesAction: true)
                            .fixedSize(horizontal: true, vertical: false)
                        memoryTrendRegion
                            .frame(minWidth: 220, maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 16) {
                            rings
                            recommendationSummary(includesAction: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        memoryTrendRegion
                    }
                }
            }
        }
    }
    }

    private var compactDashboardSummary: some View {
        HStack(spacing: 8) {
            MetricRing(fraction: snapshot.reportablePressureLevel == nil ? nil : 1,
                       colors: [releaseTint.opacity(0.75), releaseTint], lineWidth: 3) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(releaseTint)
            }
            .frame(width: 32, height: 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("内存压力", "Memory Pressure"))
            .accessibilityValue(snapshot.reportablePressureLevel?.title ?? L10n.text("不可用", "Unavailable"))
            MetricRing(fraction: usedRatio, colors: ModulePigment.memory.gradientStops, lineWidth: 3) {
                Text(usedPercentText).font(AppDesignTokens.TypeScale.caption).monospacedDigit()
            }
            .frame(width: 32, height: 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("内存占用", "Memory used"))
            .accessibilityValue(usedPercentText)
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("内存摘要", "Memory Summary"))
                    .font(AppDesignTokens.TypeScale.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Text((snapshot.reportablePressureLevel?.title ?? "—") + " · " + summaryValue)
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(surfaces.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            metricDetailsButton
        }
        .frame(height: 32)
        .help(pressureHeadroomText + " · " + summaryTitle + ": " + summaryValue + " · " + summaryCaption)
    }

    private var rings: some View {
        HStack(alignment: .center, spacing: 14) {
            pressureSummary
            // A short, narrow window keeps the pressure ring only; usage is
            // still in "已用 / 总量" beside it.
            if !(isShort && page.width == .compact) {
                usageSummary
            }
        }
    }

    /// The metric notes open in a popover instead of a disclosure row, so
    /// the overview stays one row high (D53 V0).
    private var metricDetailsButton: some View {
        AppIconButton(
            title: L10n.text("指标说明", "Metric details"),
            systemImage: "info.circle"
        ) {
            showsMetricDetails.toggle()
        }
        .popover(isPresented: $showsMetricDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("指标说明", "Metric details"))
                    .font(AppDesignTokens.TypeScale.sectionTitle)
                // D28: the level is the system's; only this percentage is estimated.
                Text(L10n.text(
                    "压力等级取自 macOS 系统（与活动监视器一致），系统未给出等级时按百分比估算（85% 起为升高、95% 起为高）。压力趋势估算 = 100 − 系统压力余量，仅用于趋势，不是占用率。",
                    "The pressure level comes from macOS (the same source as Activity Monitor); when macOS reports no level, it is estimated from the percentage (Elevated from 85%, High from 95%). Pressure estimate = 100 − system pressure headroom, for trends only; it is not memory usage."
                ))
                .font(AppDesignTokens.TypeScale.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if compactLandingSummary {
                    recommendationSummary(includesAction: true)
                    // The popover uses the pure chart, without another details
                    // control. Reusing memoryTrendRegion here would recursively
                    // include this popover in its own opaque View type.
                    MemoryTrendChartView(
                        trendPoints: trendPoints,
                        updatedAt: snapshot.generatedAt,
                        chartHeight: memoryTrendHeight
                    )
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }

    private var memoryTrendHeight: CGFloat {
        isLandingSummary ? landingTrendHeight : (page.height == .tall ? 170 : 118)
    }

    private var memoryTrendRegion: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MemoryTrendHeader(updatedAt: snapshot.generatedAt)
                metricDetailsButton
            }
            MemoryTrendChartView(
                trendPoints: trendPoints,
                updatedAt: snapshot.generatedAt,
                chartHeight: memoryTrendHeight,
                showsHeader: false
            )
        }
    }

    /// §1.5 MetricRing: the macOS pressure level is the leading, larger ring
    /// (its color is the level, D28); usage is the smaller ring (audit 4.8).
    private var pressureSummary: some View {
        let side = pressureRingSide
        return MetricRing(
            fraction: snapshot.reportablePressureLevel == nil ? nil : 1,
            colors: [releaseTint.opacity(0.75), releaseTint],
            lineWidth: isShort ? 7 : 9
        ) {
            VStack(spacing: 1) {
                // English level names are longer ("Unavailable"): step the
                // size down instead of truncating or scaling the label.
                ViewThatFits(in: .horizontal) {
                    pressureLevelText(size: isShort ? 14 : 18)
                    pressureLevelText(size: isShort ? 12 : 14)
                    pressureLevelText(size: 11)
                }
                // The 66 pt short-window ring has room for the short label.
                ViewThatFits(in: .horizontal) {
                    Text(L10n.text("内存压力", "Pressure"))
                    Text(L10n.text("压力", "Pressure"))
                }
                .font(AppDesignTokens.TypeScale.caption)
                .foregroundStyle(surfaces.textSecondary)
                .lineLimit(1)
            }
            .padding(.horizontal, isShort ? 4 : 10)
        }
        .frame(width: side, height: side)
        .help(pressureHeadroomText + L10n.text(
            "；环颜色表示 macOS 报告的内存压力等级（与活动监视器同源），不是压力百分比或可用内存比例；系统未给出等级时按百分比估算（85% 起为升高、95% 起为高）。",
            "; ring color shows the memory pressure level macOS reports (the source Activity Monitor uses), not a pressure percentage or available memory ratio; when macOS reports no level, it is estimated from the percentage (Elevated from 85%, High from 95%)."
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("内存压力", "Memory Pressure"))
        .accessibilityValue(snapshot.reportablePressureLevel?.title ?? L10n.text("不可用", "Unavailable"))
    }

    private func pressureLevelText(size: CGFloat) -> some View {
        Text(snapshot.reportablePressureLevel?.title ?? L10n.text("不可用", "Unavailable"))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(releaseTint)
            .lineLimit(1)
            .fixedSize()
    }

    private var usageSummary: some View {
        let side = usageRingSide
        return MetricRing(
            fraction: usedRatio,
            colors: [ModulePigment.memory.lightStop, ModulePigment.memory.brightColor],
            lineWidth: 6
        ) {
            VStack(spacing: 0) {
                // A live value: no rolling digits on every refresh (audit 5.2).
                Text(usedPercentText)
                    .font(.system(size: isShort ? 13 : 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(L10n.text("占用", "Used"))
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(surfaces.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: side, height: side)
        .help(usedRatio == nil
            ? (snapshot.measurements.availableBytes.unavailableDetail
                ?? snapshot.measurements.physicalBytes.unavailableDetail
                ?? L10n.text("数据不可用", "Data unavailable"))
            : L10n.text("实测使用量 / 物理总内存；容量明细见下方", "Measured used / total physical memory; capacity details below"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("内存占用", "Memory used"))
        .accessibilityValue(usedPercentText)
    }

    private func recommendationSummary(includesAction: Bool) -> some View {
        // D178: memory as Activity Monitor writes it, "41.3 GB / 48 GB"
        // (was "41.3 / 48.0 GiB").
        let used = snapshot.measuredUsedBytes.map { ByteFormat.memoryString(Int64(clamping: $0)) } ?? "—"
        let total = snapshot.measurements.physicalBytes.value.map { ByteFormat.memoryString(Int64(clamping: $0)) } ?? "—"
        return VStack(alignment: .leading, spacing: isShort || isLandingSummary ? 4 : 8) {
            HStack(spacing: 8) {
                Text(summaryTitle)
                    .font(AppDesignTokens.TypeScale.sectionTitle)
                    .foregroundStyle(surfaces.textPrimary)
                Label(
                    snapshot.reportablePressureLevel?.title ?? L10n.text("不可用", "Unavailable"),
                    systemImage: "gauge.with.dots.needle.67percent"
                )
                    .font(AppDesignTokens.TypeScale.captionEmphasis)
                    .foregroundStyle(releaseTint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summaryValue)
                    .font(AppDesignTokens.TypeScale.metricCard)
                    .foregroundStyle(surfaces.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                    .appNumericTransition(value: summaryValue)
                Text(summaryCaption)
                    .font(AppDesignTokens.TypeScale.secondary)
                    .foregroundStyle(surfaces.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                MemoryInlineMetric(
                    title: L10n.text("已用 / 总量", "Used / Total"),
                    value: "\(used) / \(total)"
                )
                Divider().frame(height: 26)
                MemoryInlineMetric(
                    title: L10n.text("缓存", "Cache"),
                    value: byteText(snapshot.measurements.cachedBytes)
                )
                Divider().frame(height: 26)
                MemoryInlineMetric(
                    title: L10n.text("交换", "Swap"),
                    value: byteText(snapshot.measurements.swapUsedBytes)
                )
            }

            if includesAction, !isObserving { recommendedActionButton }
        }
    }

    private var recommendedActionButton: some View {
        Button(role: store.isRecommendedMemorySelectionPrepared ? .destructive : nil) {
            store.performRecommendedMemoryAction()
        } label: {
            Label(
                store.isRecommendedMemorySelectionPrepared
                    ? L10n.text("退出高占用应用", "Quit High-Usage Apps")
                    : cleanupPlan.title,
                systemImage: store.isRecommendedMemorySelectionPrepared
                    ? "xmark.circle.fill"
                    : "checkmark.circle"
            )
        }
        // BOARD N19 / D49: a quit never takes a safe or module color. Picking
        // the suggestions is the module's secondary step; once apps are
        // selected the same button quits (after confirmation) in red.
        .buttonStyle(GradientButtonStyle(
            kind: store.isRecommendedMemorySelectionPrepared ? .destructive : .secondary,
            size: .small
        ))
        .disabled(!store.canOptimizeMemory)
        .help(store.isRecommendedMemorySelectionPrepared
            ? L10n.text(
                "确认后正常退出已选中的高占用应用；确认框会列出这些应用",
                "Quits the selected high-usage apps normally after a confirmation that lists them"
            )
            : L10n.text(
                "先选中建议退出的高占用应用，不会立即退出",
                "Select suggested high-usage apps first without quitting them"
            ))
    }
}

/// A read-only trend with optional header. It owns no actions, presentation
/// state, or store, so a details popover cannot nest another details popover.
private struct MemoryTrendChartView: View {
    let trendPoints: [MenuBarTelemetryPoint]
    let updatedAt: Date
    let chartHeight: CGFloat
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                MemoryTrendHeader(updatedAt: updatedAt)
            }
            // §1.5 TrendChart: preserve both measured series, unknown values,
            // the two-minute window, readouts and the existing data animation.
            TrendChart(
                samples: trendPoints.map { TrendChart.Sample(date: $0.date, value: $0.memory) },
                secondarySamples: trendPoints.map { TrendChart.Sample(date: $0.date, value: $0.memoryPressure) },
                secondaryColor: AppDesignTokens.Palette.caution,
                range: 0...100,
                duration: 120,
                color: ModulePigment.memory.brightColor,
                accessibilityLabel: L10n.text(
                    "最近两分钟的内存占用与压力趋势估算",
                    "Memory usage and estimated pressure trend over the last two minutes"
                ),
                title: L10n.text("内存占用", "Memory Usage"),
                secondaryTitle: L10n.text("压力趋势估算", "Pressure estimate")
            )
            .frame(height: chartHeight)
        }
    }
}

/// Shared by the page and the pure popover chart, without a details button.
private struct MemoryTrendHeader: View {
    @AppSurfaces private var surfaces
    let updatedAt: Date

    var body: some View {
        // §2.4: drop the title, then the time, before the header wraps.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                Label(
                    L10n.text("内存使用趋势", "Memory Usage Trend"),
                    systemImage: "waveform.path.ecg"
                )
                .font(AppDesignTokens.TypeScale.secondaryEmphasis)
                .foregroundStyle(surfaces.textPrimary)
                .lineLimit(1)
                .fixedSize()
                legend.fixedSize()
                Spacer(minLength: AppDesignTokens.Spacing.small)
                timestamp.fixedSize()
            }
            HStack(spacing: 12) {
                legend.fixedSize()
                Spacer(minLength: AppDesignTokens.Spacing.small)
                timestamp.fixedSize()
            }
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(title: L10n.text("内存占用", "Memory Usage"), color: ModulePigment.memory.brightColor, dashed: false)
            legendItem(title: L10n.text("压力趋势估算", "Pressure estimate"), color: AppDesignTokens.Palette.caution, dashed: true)
        }
    }

    private var timestamp: some View {
        Text(updatedAt, format: .dateTime.hour().minute().second())
            .font(AppDesignTokens.TypeScale.caption)
            .foregroundStyle(surfaces.textTertiary)
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityLabel(L10n.text("最近更新", "Last updated"))
    }

    private func legendItem(title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: dashed ? 6 : 12, height: 3)
                .overlay(alignment: .trailing) {
                    if dashed {
                        Capsule().fill(color).frame(width: 4, height: 3).offset(x: 6)
                    }
                }
                .frame(width: 12, alignment: .leading)
                .accessibilityHidden(true)
            Text(title)
                .font(AppDesignTokens.TypeScale.caption)
                .foregroundStyle(surfaces.textSecondary)
        }
    }
}

private struct MemoryInlineMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .appNumericTransition(value: value)
            Text(title)
                .font(AppDesignTokens.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct MemoryProcessSelectionPanel: View {
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.pageLayout) private var pageLayout
    @AppSurfaces private var surfaces
    let snapshot: MemorySnapshot
    @ObservedObject var store: ScanStore
    var minimumListHeight: CGFloat = 140
    var isLandingDashboard = false

    var sampledProcesses: [MemoryProcess] {
        snapshot.processesByResidentUsage
    }

    private var apps: [MemoryAppUsage] {
        snapshot.appsByResidentUsage.filter {
            $0.canQuit && $0.bundlePath?.hasSuffix(".app") == true
        }
    }

    private var selectedBytesText: String {
        ByteFormat.memoryString(store.selectedMemoryAppEstimatedBytes)
    }

    private var isShortHeight: Bool {
        pageLayout?.height == .short
    }

    /// Below 960 pt of detail width the secondary selection commands show
    /// their icons only (their titles stay in help and accessibility).
    private var showsCommandTitles: Bool {
        if isLandingDashboard { return false }
        guard let pageLayout else { return layout.density == .regular }
        return pageLayout.size.width >= 960
    }

    /// §3.3: selecting or clearing changes every row of the list at once.
    private var listScope: BulkUpdateScope {
        BulkUpdateScope(rowCount: apps.count)
    }

    private func selectAllApps() {
        listScope.perform {
            apps.forEach { store.setMemoryAppUsageSelection($0, isSelected: true) }
        }
    }

    var body: some View {
        let selectedAppCount = apps.filter { store.isMemoryAppUsageSelected($0) }.count
        let recommendedAppIDs = Set(snapshot.recommendedQuitApps.map(\.id))
        let lastAppID = apps.last?.id

        VStack(alignment: .leading, spacing: isLandingDashboard ? 2 : (isShortHeight ? 6 : 10)) {
            HStack(alignment: .center, spacing: 12) {
                CapsuleSegmentedControl(
                    selection: $store.memoryShowsAllProcesses,
                    options: [true, false],
                    title: { showsAll in
                        showsAll
                            ? L10n.text("已采样进程 (\(ByteFormat.count(sampledProcesses.count)))", "Sampled Processes (\(ByteFormat.count(sampledProcesses.count)))")
                            : L10n.text("可退出应用 (\(ByteFormat.count(apps.count)))", "Quittable Apps (\(ByteFormat.count(apps.count)))")
                    },
                    label: L10n.text("进程列表范围", "Process list scope")
                )
                if !isLandingDashboard {
                Spacer(minLength: 6)
                HStack(spacing: 4) {
#if DEBUG || STORAGE_CLEANER_BETA
                    if MiniWindowDemoData.isEnabled { Text("FIXTURE ·") }
#endif
                    Text(L10n.text("进程快照", "Process snapshot"))
                    Text(L10n.text("采样于", "Sampled at"))
                    Text(snapshot.generatedAt, format: .dateTime.year().month().day().hour().minute().second())
                        .monospacedDigit()
                }
                .font(AppDesignTokens.TypeScale.caption)
                .foregroundStyle(surfaces.textTertiary)
                .lineLimit(1)
                .listColumn(.p2)
                }
            }

            if store.memoryShowsAllProcesses {
                sampledProcessList
            } else {
                if apps.isEmpty {
                    HStack(spacing: 12) {
                        // D58: nothing to quit is an all-clear state.
                        GeneratedArtView(art: .stateAllClear, variant: .header) {
                            Image(systemName: "checkmark.circle")
                                .font(AppDesignTokens.TypeScale.sectionTitle)
                                .foregroundStyle(AppDesignTokens.Palette.success)
                        }
                        .frame(width: 44, height: 44)
                        Text(L10n.text("没有可退出的运行应用", "No quittable running apps"))
                            .font(AppDesignTokens.TypeScale.secondaryEmphasis)
                            .foregroundStyle(surfaces.textPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                } else {
                    VStack(spacing: 0) {
                        // Short windows give the header row to the list.
                        if !isShortHeight && !isLandingDashboard {
                            MemoryAppSelectionTableHeader()
                        }
                        memoryListViewport(probePrefix: "memory.apps") {
                            LazyVStack(spacing: 0) {
                                ForEach(apps) { app in
                                    MemorySelectableAppRow(
                                        app: app,
                                        isSuggested: recommendedAppIDs.contains(app.id),
                                        store: store
                                    )
                                    if app.id != lastAppID {
                                        Divider()
                                            .padding(.leading, 52)
                                    }
                                }
                            }
                        }
                        .scrollTopFade(height: 8)
                        .frame(minHeight: minimumListHeight, maxHeight: .infinity)
#if DEBUG
                        .layoutProbe("memory.list")
#endif
                    }
                    .appBulkAnimationGuard(listScope)
                }

                if !apps.isEmpty {
                    // §2.4: the selection and the quit action stay pinned at
                    // the bottom of the list instead of scrolling away.
                    if isLandingDashboard {
                        dashboardSelectionBar(selectedAppCount: selectedAppCount,
                            hasRecommendedApps: !recommendedAppIDs.isEmpty)
                    } else {
                    PinnedActionBar {
                        selectionSummary(
                            selectedAppCount: selectedAppCount,
                            alignment: .leading,
                            textAlignment: .leading
                        )
                    } actions: {
                        selectionActions(
                            hasRecommendedApps: !recommendedAppIDs.isEmpty,
                            selectedAppCount: selectedAppCount
                        )
                    }
#if DEBUG
                    .layoutProbe("memory.pinnedActionBar")
#endif
                    }
                }
            }
        }
        .padding(isLandingDashboard ? 0 : (isShortHeight ? 10 : 14))
        .background {
            if !isLandingDashboard {
                SurfaceBackground(level: .card, cornerRadius: AppDesignTokens.Corner.card)
            }
        }
        .fullBleedSection()
    }

    private func dashboardSelectionBar(selectedAppCount: Int, hasRecommendedApps: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                selectionSummary(selectedAppCount: selectedAppCount,
                    alignment: .leading, textAlignment: .leading)
                Spacer(minLength: 0)
                selectionActions(hasRecommendedApps: hasRecommendedApps, selectedAppCount: selectedAppCount)
            }
            selectionActions(hasRecommendedApps: hasRecommendedApps, selectedAppCount: selectedAppCount)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: isShortHeight ? 44 : 56)
        .surfaceBackground(.inset)
        .accessibilityElement(children: .contain)
        .accessibilityValue(selectionDetail(selectedAppCount: selectedAppCount))
        .help(selectionDetail(selectedAppCount: selectedAppCount))
#if DEBUG
        .layoutProbe("memory.pinnedActionBar")
#endif
    }

    @ViewBuilder
    private func memoryListViewport<Content: View>(probePrefix: String,
        @ViewBuilder content: () -> Content) -> some View {
        if isLandingDashboard {
            FeatureOptionsScrollView(probePrefix: probePrefix, balancesContent: false) { content() }
        } else {
            ScrollView { content() }
        }
    }

    private var sampledListHeader: some View {
        HStack(spacing: 12) {
            Text(L10n.text("进程 · 按占用排序", "Process · by memory use"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("PID")
                .frame(width: 60, alignment: .trailing)
                .listColumn(.p2)
            Text(L10n.text("内存占用", "Memory Use"))
                .frame(width: 110, alignment: .trailing)
        }
        .font(AppDesignTokens.TypeScale.captionEmphasis)
        .foregroundStyle(surfaces.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sampledProcessList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("只读 · Top 256 可读进程", "Read-only · Top 256 readable processes"), systemImage: "info.circle")
                .font(AppDesignTokens.TypeScale.caption)
                .foregroundStyle(surfaces.textSecondary)
                .help(L10n.text(
                    "本次快照仅包含可读取且物理内存足迹大于 0 的进程，最多 256 项；不代表全部系统 PID。",
                    "The snapshot includes readable processes with a positive physical footprint, up to 256; it is not every system PID."
                ))

            if sampledProcesses.isEmpty {
                Text(L10n.text("本次没有可读的进程样本", "No readable process samples in this snapshot"))
                    .font(AppDesignTokens.TypeScale.secondary)
                    .foregroundStyle(surfaces.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    if !isShortHeight && !isLandingDashboard {
                        sampledListHeader
                        Divider()
                    }

                    memoryListViewport(probePrefix: "memory.sampled") {
                        // The snapshot is capped at 256 rows. Eager layout avoids the
                        // macOS 27 lazy-layout accessibility scroll assertion.
                        VStack(spacing: 0) {
                            ForEach(sampledProcesses) { process in
                                MemoryReadOnlyProcessRow(process: process)
                                Divider()
                            }
                        }
                    }
                    .scrollTopFade(height: 8)
                    .frame(minHeight: minimumListHeight, maxHeight: .infinity)
#if DEBUG
                    .layoutProbe("memory.list")
#endif
                    // §3.3: a refresh replaces up to 256 rows at once.
                    .appBulkAnimationGuard(rowCount: sampledProcesses.count)
                }
            }
        }
    }

    private func selectionSummary(
        selectedAppCount: Int,
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        let detail = selectionDetail(selectedAppCount: selectedAppCount)
        return VStack(alignment: alignment, spacing: AppDesignTokens.Layout.textTightSpacing) {
            Text(
                selectedAppCount == 0
                    ? L10n.text("未选择", "None selected")
                    : L10n.text("已选 \(ByteFormat.count(selectedAppCount)) 个应用", "\(ByteFormat.count(selectedAppCount)) apps selected")
            )
            .font(AppDesignTokens.TypeScale.bodyEmphasis)
            .monospacedDigit()
            .appDataTransition(value: selectedAppCount)

            // Short windows keep the bar to one line; the detail stays in
            // the help text.
            if !isShortHeight && !isLandingDashboard {
                Text(detail)
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(surfaces.textSecondary)
                    .monospacedDigit()
                    .appDataTransition(value: selectedBytesText)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(detail)
    }

    private func selectionDetail(selectedAppCount: Int) -> String {
        selectedAppCount == 0
            ? L10n.text("选择后显示合计", "Total appears after selection")
            : L10n.text(
                "目前约占 \(selectedBytesText) · 预计释放以刷新重测为准",
                "Uses about \(selectedBytesText) · release remeasured after refresh"
            )
    }

    /// The selection commands keep their conditions from before V0 (review
    /// P2-1): "Select Suggested Apps" (when there are suggestions) and
    /// "Select All" are offered whatever is already selected; "Clear
    /// Selection" and the quit action appear once something is selected; all
    /// of them are disabled only by `canRequestMemoryQuitActions`. Narrow
    /// windows show the three secondary commands as icons; the quit action
    /// always keeps its title.
    @ViewBuilder
    private func selectionActions(
        hasRecommendedApps: Bool,
        selectedAppCount: Int
    ) -> some View {
        let commands = HStack(spacing: 8) {
            if hasRecommendedApps {
                recommendedSelectionButton
            }
            selectAllButton
            if selectedAppCount > 0 {
                clearSelectionButton
            }
        }
        HStack(spacing: 8) {
            if showsCommandTitles {
                commands.labelStyle(.titleAndIcon)
            } else {
                commands.labelStyle(.iconOnly)
            }
            if selectedAppCount > 0 {
                quitSelectionButton(selectedAppCount: selectedAppCount)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var recommendedSelectionButton: some View {
        Button {
            _ = listScope.perform { store.selectRecommendedMemoryApps() }
        } label: {
            Label(L10n.text("选择建议退出项", "Select Suggested Apps"), systemImage: "sparkles")
        }
        .buttonStyle(GradientButtonStyle(kind: .secondary, size: .small))
        .help(L10n.text("选择建议退出项", "Select Suggested Apps"))
        .accessibilityLabel(L10n.text("选择建议退出项", "Select Suggested Apps"))
        .disabled(!store.canRequestMemoryQuitActions)
#if DEBUG
        .layoutProbe("memory.command.suggested")
#endif
    }

    private var selectAllButton: some View {
        Button {
            selectAllApps()
        } label: {
            Label(L10n.text("全选", "Select All"), systemImage: "checkmark.circle")
        }
        .buttonStyle(GradientButtonStyle(kind: .ghost, size: .small))
        .help(L10n.text("全选", "Select All"))
        .accessibilityLabel(L10n.text("全选", "Select All"))
        .disabled(!store.canRequestMemoryQuitActions)
#if DEBUG
        .layoutProbe("memory.command.selectAll")
#endif
    }

    private var clearSelectionButton: some View {
        Button {
            listScope.perform { store.clearMemoryProcessSelection() }
        } label: {
            Label(L10n.text("清空选择", "Clear Selection"), systemImage: "xmark.circle")
        }
        .buttonStyle(GradientButtonStyle(kind: .ghost, size: .small))
        .help(L10n.text("清空选择", "Clear Selection"))
        .accessibilityLabel(L10n.text("清空选择", "Clear Selection"))
        .disabled(!store.canRequestMemoryQuitActions)
#if DEBUG
        .layoutProbe("memory.command.clear")
#endif
    }

    private func quitSelectionButton(selectedAppCount: Int) -> some View {
        Button(role: .destructive) {
            store.requestQuitSelectedMemoryProcesses()
        } label: {
            Label(
                L10n.text(
                    "退出 \(ByteFormat.count(selectedAppCount)) 个应用",
                    "Quit \(ByteFormat.count(selectedAppCount)) Apps"
                ),
                systemImage: "xmark.circle.fill"
            )
        }
        // N19 / D49: quitting is destructive and always asks first.
        .buttonStyle(GradientButtonStyle(kind: .destructive, size: .medium))
        .help(L10n.text("退出前会列出这些应用并请你确认", "Lists these apps and asks before quitting"))
        .accessibilityLabel(L10n.text("退出 \(ByteFormat.count(selectedAppCount)) 个应用", "Quit \(ByteFormat.count(selectedAppCount)) Apps"))
        .disabled(!store.canRequestMemoryQuitActions)
#if DEBUG
        .layoutProbe("memory.command.quit")
#endif
    }
}

private struct MemoryReadOnlyProcessRow: View {
    let process: MemoryProcess

    private var sourceTitle: String {
        process.dataSource == .procPIDRUsage
            ? L10n.text("物理内存足迹", "Physical footprint")
            : L10n.text("驻留内存（旧来源）", "Resident memory (legacy source)")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(process.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(process.id))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
                .listColumn(.p2)
            Text(process.availability == .available ? ByteFormat.memoryString(process.residentBytes) : process.availability.title)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)
        }
        .font(AppDesignTokens.TypeScale.body)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .listRowHover()
        .help("\(process.path)\n\(sourceTitle) · \(process.capturedAt.formatted(date: .numeric, time: .standard))")
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.text("只读进程样本", "Read-only process sample") + " · " + sourceTitle)
    }
}

private struct MemoryAppSelectionTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("")
                .frame(width: 22)

            Text("")
                .frame(width: UtilitySizing.rowIconFrame)

            Text(L10n.text("应用", "Application"))
                .font(AppDesignTokens.TypeScale.captionEmphasis)

            Spacer(minLength: 10)

            Text(L10n.text("内存", "Memory"))
                .font(AppDesignTokens.TypeScale.captionEmphasis)
                .foregroundStyle(.secondary)
                .frame(width: 94, alignment: .trailing)
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .padding(.bottom, 2)
    }
}

private struct MemorySelectableAppRow: View {
    @Environment(\.pageLayout) private var pageLayout
    let app: MemoryAppUsage
    let isSuggested: Bool
    @ObservedObject var store: ScanStore

    private var rowTint: Color {
        isSuggested ? AppDesignTokens.Palette.warning : ModulePigment.memory.brightColor
    }

    private var selectionBinding: Binding<Bool> {
        Binding {
            store.isMemoryAppUsageSelected(app)
        } set: { isSelected in
            store.setMemoryAppUsageSelection(app, isSelected: isSelected)
        }
    }

    private var isSelected: Bool {
        store.isMemoryAppUsageSelected(app)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: selectionBinding)
                // D53: animated box; quitting stays destructive, so the box
                // takes the danger color (N19, D49).
                .toggleStyle(AnimatedCheckboxToggleStyle(tint: ModulePigment.danger.lightStop))
                .labelsHidden()
                .frame(width: 22)
                .help(L10n.text("选择后可统一退出", "Select to quit together"))
                .accessibilityLabel(L10n.text("选择 \(app.name)", "Select \(app.name)"))
                .accessibilityValue(isSelected ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not selected"))
                .disabled(!store.canRequestMemoryQuitActions)

            ProcessIcon(path: app.iconPath, fallbackSystemImage: "app.fill")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(app.name)
                        .font(AppDesignTokens.TypeScale.bodyEmphasis)
                        .fixedSize(horizontal: false, vertical: true)
                    if isSuggested {
                        Label(L10n.text("建议", "Suggested"), systemImage: "sparkles")
                            .font(AppDesignTokens.TypeScale.captionEmphasis)
                            .foregroundStyle(AppDesignTokens.Palette.warning)
                    } else if app.isActive {
                        Label(L10n.text("正在使用", "Active"), systemImage: "circle.fill")
                            .font(AppDesignTokens.TypeScale.caption)
                            .foregroundStyle(AppDesignTokens.Palette.information)
                    }
                    if app.processCount > 1 {
                        Label("x\(ByteFormat.count(app.processCount))", systemImage: "square.stack.3d.up")
                            .font(AppDesignTokens.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .listColumn(.p2)
                    }
                }

                MemoryProcessUsageBar(percent: app.percent, tint: rowTint)
                    .frame(maxWidth: 280)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteFormat.memoryString(app.bytes))
                    .font(AppDesignTokens.TypeScale.bodyEmphasis)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: "%.1f%%", app.percent))
                    .font(AppDesignTokens.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 94, alignment: .trailing)
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, pageLayout?.height == .short ? 5 : 8)
        .listRowHover(isSelected: isSelected, tint: ModulePigment.danger.brightColor)
    }
}

private struct MemoryProcessUsageBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedPercent: Double = 0
    let percent: Double
    let tint: Color

    var body: some View {
        ProgressView(value: min(100, max(0, renderedPercent)), total: 100)
            .progressViewStyle(.linear)
            .tint(tint)
            .frame(height: 6)
            .accessibilityLabel(L10n.text("内存占比 \(String(format: "%.1f", percent))%", "Memory share \(String(format: "%.1f", percent))%"))
            .task(id: percent) {
                guard AppMotionPolicy.shouldAnimate(reduceMotion: reduceMotion) else {
                    renderedPercent = percent
                    return
                }

                if renderedPercent == 0 {
                    await Task.yield()
                }
                withAnimation(AppMotionTokens.progress) {
                    renderedPercent = percent
                }
            }
    }
}

private struct ProcessIcon: View {
    let path: String
    let fallbackSystemImage: String

    var body: some View {
        CachedAppIconView(
            path: path,
            size: UtilitySizing.rowIconGlyph
        ) {
            Image(systemName: fallbackSystemImage)
                .symbolRenderingMode(.hierarchical)
                .resizable()
                .scaledToFit()
                .frame(width: UtilitySizing.supportGlyph, height: UtilitySizing.supportGlyph)
                .foregroundStyle(.secondary)
                .frame(width: UtilitySizing.rowIconGlyph, height: UtilitySizing.rowIconGlyph)
        }
        .frame(width: UtilitySizing.rowIconFrame, height: UtilitySizing.rowIconFrame)
    }
}

private struct InstalledAppRow: View {
    let app: InstalledAppItem
    @ObservedObject var store: ScanStore
    let select: () -> Void
    var body: some View {
        Button(action: select) {
        HStack(spacing: 10) {
            InstalledAppIcon(path: app.path)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .lineLimit(2).help(app.name)
                Text(app.versionDisplay).font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary).lineLimit(1)
                Text((app.path as NSString).abbreviatingWithTildeInPath)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(AppAppearanceColors.tertiaryText)
                    .lineLimit(1).truncationMode(.middle).help(app.path)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(ByteFormat.storageString(app.sizeBytes)).font(AppDesignTokens.Typography.metadata)
                .monospacedDigit().foregroundStyle(.secondary).fixedSize()
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .contentShape(Rectangle()).help(app.path)
        }
        .appButtonChrome(.selectionRow)
        .accessibilityLabel("\(app.name), \(ByteFormat.storageString(app.sizeBytes))")
        .accessibilityHint(L10n.text("选择应用并查看关联文件", "Select application and review related files"))
        .contextMenu {
            Button(L10n.text("在访达中显示", "Show in Finder")) { store.reveal(app.path) }
            Button(L10n.text("复制路径", "Copy Path")) { store.copyPath(app.path) }
        }
    }
}

private struct InstalledAppIcon: View {
    let path: String
    private let size = UtilitySizing.rowIconFrame

    var body: some View {
        CachedAppIconView(
            path: path,
            size: size
        ) {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
            .frame(width: size, height: size)
            .shadow(color: AppDesignTokens.Elevation.standardShadow, radius: 6, y: 3)
    }
}

private struct LoadingPanel: View {
    let title: String

    var body: some View {
        RuntimeInlineStatus(title: title)
        .appMotionEntrance(distance: 5)
    }
}

private struct EmptyUtilityPanel: View {
    let systemImage: String
    let title: String

    var body: some View {
        AppEmptyState(
            title: title,
            systemImage: systemImage,
            density: .inline
        )
        .appMotionEntrance(distance: 5)
    }
}

/// Shared with Debug data fixtures; mode title and capabilities remain owned
/// by the existing duplicate workspace and its published phase.
struct DuplicateFilesRunningPage: View {
    let progress: DuplicateFileScanProgress
    let state: RuntimeWorkflowState
    let title: String
    let pageTitle: String
    let isSimilarPhotos: Bool
    let canCancel: Bool
    let onCancel: () -> Void
    let onPauseOrResume: () -> Void
    var body: some View {
        FeatureRuntimePage(module: .duplicates, title: title, state: state,
            metrics: [
                .init(title: L10n.text("已扫描文件", "Files Scanned"), value: String(progress.scannedFiles)),
                .init(title: L10n.text("已完整比对", "Fully Verified"), value: String(progress.hashedFiles)),
                .init(title: L10n.text("已读取内容", "Content Read"), value: ByteFormat.storageString(progress.hashedBytes))
            ], currentItem: progress.currentPath,
            pageTitle: pageTitle,
            pageSystemImage: isSimilarPhotos ? GeneratedArt.similarPhotosSystemImage : ReviewFilter.duplicates.systemImage,
            trustText: isSimilarPhotos
                ? L10n.text("只读扫描 · 相似候选须人工确认，不会自动清理", "Read-only scan · Review similar candidates; no automatic cleanup")
                : L10n.text("只读扫描 · 保留原件，清理前确认", "Read-only scan · Originals retained until cleanup is confirmed"),
            canCancel: canCancel, onCancel: onCancel
        ) { EmptyView() } actions: {
            Button(action: onPauseOrResume) {
                Label(state == .paused ? L10n.text("继续", "Resume") : L10n.text("暂停", "Pause"),
                    systemImage: state == .paused ? "play.fill" : "pause.fill")
            }
            .appButtonChrome(.secondary).disabled(state == .stopping)
        }
    }
}
