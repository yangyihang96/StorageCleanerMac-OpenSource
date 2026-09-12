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
        case .overview, .healthHub, .performance, .green, .privacy, .devCaches, .largeFiles, .migration, .duplicates, .utilityHub:
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
        case .overview, .healthHub, .performance, .green, .privacy, .devCaches, .largeFiles, .migration, .duplicates, .utilityHub:
            title
        }
    }
}

struct StartupItemsView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        Group {
            if !store.hasScannedStartupItems && !store.isLoadingStartupItems {
                startupLanding
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
                    onOpenSystemSettings: { SMAppService.openSystemSettingsLoginItems() }
                )
            }
        }
        .toolbar {
            if store.canUndoLastStartupOperation {
                ToolbarItem {
                    Button {
                        store.undoLastStartupOperation()
                    } label: {
                        Label(L10n.text("撤销启动项操作", "Undo Startup Item Change"), systemImage: "arrow.uturn.backward")
                    }
                    .help(L10n.text("恢复上一次已验证的启用或停用操作", "Restore the last verified enable or disable operation"))
                }
            }
        }
    }

    private var startupLanding: some View {
        HeroScanPage(
            title: ReviewFilter.startup.sidebarTitle,
            subtitle: ReviewFilter.startup.pageSubtitle,
            headerSystemImage: ReviewFilter.startup.systemImage,
            actionTitle: L10n.text("读取启动项", "Read Startup Items"),
            actionDetail: L10n.text(
                "检查登录项、后台代理与系统守护进程",
                "Check login items, background agents, and system daemons"
            ),
            actionSystemImage: "magnifyingglass",
            status: .idle(L10n.text("尚未读取启动项", "Startup items not read")),
            trustText: L10n.text(
                "只读检查 · 更改前逐项确认并保留撤销记录",
                "Read-only check · Changes require confirmation and keep an undo record"
            ),
            action: { store.refreshStartupItems() }
        )
    }

    private var startupCoverageAction: some View {
        GlassToolbarButton(
            title: startupCoverageActionTitle,
            systemImage: startupCoverageActionSymbol,
            isDisabled: !store.canRefreshStartupItems
        ) {
            store.refreshStartupItems(includeBackgroundTaskDiagnostic: true)
        }
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
        if store.startupCoverage.managedItemCoverageAvailable {
            let count = store.startupCoverage.managedItemCount ?? 0
            return L10n.text(
                "已读取 \(count) 个系统后台项；点击可重新完整扫描",
                "\(count) system background items read; click to run the full scan again"
            )
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

struct MemoryOptimizerView: View {
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    @ObservedObject private var monitorState: MenuBarMonitorState

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

    private func memoryPanels(snapshot: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryReleasePanel(
                snapshot: store.menuBarDisplayMemorySnapshot ?? snapshot,
                processSnapshot: snapshot,
                trendPoints: monitorState.memoryHistory(within: 120),
                store: store
            )
            .fixedSize(horizontal: false, vertical: true)
            MemoryProcessSelectionPanel(snapshot: snapshot, store: store, minimumListHeight: 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppPageHeader(
                title: L10n.text("内存管理", "Memory Management"),
                subtitle: ReviewFilter.memory.pageSubtitle,
                systemImage: AppSymbols.Navigation.memory, isHero: true
            ) {
                if layout.density != .compact, let image = GoldenLandingAsset.memory.image {
                    GoldenLandingArtwork(image: image)
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                }
                Button {
                    store.refreshMemory()
                } label: {
                    Label(L10n.text("刷新", "Refresh"), systemImage: "arrow.clockwise")
                }
                .appButtonChrome(.secondary)
                .disabled(!store.canRefreshMemory)
            }
            .padding(.horizontal, UtilitySizing.pagePadding)
            .padding(.bottom, AppDesignTokens.Spacing.small)

            VStack(alignment: .leading, spacing: 12) {
                if store.isOptimizingMemory || store.isLoadingMemory {
                    VStack(alignment: .trailing, spacing: 8) {
                        LoadingPanel(title: store.isOptimizingMemory
                            ? L10n.text("正在执行并验证内存操作", "Running and verifying memory action")
                            : L10n.text("正在读取内存状态", "Reading memory status"))
                        if store.isOptimizingMemory {
                            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                                store.cancelMemoryOptimization()
                            }
                        }
                    }
                    .transition(AppMotionTokens.listTransition(reduceMotion: reduceMotion))
                }

                if let result = store.memoryOptimizationResult {
                    MemoryOptimizationResultPanel(result: result)
                        .transition(AppMotionTokens.listTransition(reduceMotion: reduceMotion))
                }

                if let snapshot = processSnapshot {
                    if layout.density == .compact {
                        ScrollView {
                            memoryPanels(snapshot: snapshot)
                                .frame(minHeight: 720)
                        }
                    } else {
                        memoryPanels(snapshot: snapshot)
                    }
                } else {
                    EmptyUtilityPanel(
                        systemImage: "memorychip",
                        title: L10n.text("刷新以读取内存状态", "Refresh to inspect memory")
                    )
                    .transition(AppMotionTokens.listTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.horizontal, UtilitySizing.pagePadding)
            .padding(.bottom, UtilitySizing.pagePadding)
            .frame(maxWidth: UtilitySizing.pageMaxWidth, maxHeight: .infinity, alignment: .topLeading)
            .animation(
                AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                value: store.isLoadingMemory || store.isOptimizingMemory
            )
            .animation(
                AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                value: store.memoryOptimizationResult != nil
            )
            .animation(
                AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                value: processSnapshot != nil
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
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

}

struct EnergyImpactView: View {
    @ObservedObject var store: ScanStore
    @State private var searchText = ""
    @State private var sortMode: EnergyImpactSortMode = .estimatedEnergy

    var body: some View {
        if store.hasScannedEnergyImpact, let snapshot = store.energyImpactSnapshot {
            resultContent(snapshot: snapshot)
        } else {
            EnergyImpactScanLandingView(store: store)
        }
    }

    private func resultContent(snapshot: EnergyImpactSnapshot) -> some View {
        VStack(spacing: 0) {
            UtilityHeader(
                title: L10n.text("能耗", "Energy"),
                subtitle: ReviewFilter.energy.pageSubtitle,
                systemImage: AppSymbols.Navigation.energy
            ) {
                if store.isEnergyImpactPageScanActive {
                    ProgressView()
                        .controlSize(.small)
                }
                AppButton(
                    title: store.isEnergyImpactPageScanActive
                        ? L10n.text("正在扫描", "Scanning")
                        : L10n.text("重新扫描", "Rescan"),
                    systemImage: "arrow.clockwise",
                    isDisabled: !store.canRefreshEnergyImpact
                ) {
                    store.scanEnergyImpact()
                }
            }
            .padding(.horizontal, UtilitySizing.pagePadding)
            .padding(.bottom, AppDesignTokens.Spacing.small)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.isEnergyImpactPageScanActive {
                        EnergyImpactScanProgressPanel(phase: store.energyImpactScanPhase)
                            .appMotionEntrance(delay: 0.02, distance: 4)
                    }

                    let presentation = EnergyImpactListPresenter.presentation(
                        apps: snapshot.apps,
                        query: searchText,
                        sortMode: sortMode
                    )

                    EnergyImpactSummaryGrid(
                        snapshot: snapshot,
                        systemEnergy: store.systemEnergySnapshot
                    )
                    .appMotionEntrance(delay: 0.035)
                    EnergyImpactMeasurementBar(
                        snapshot: snapshot,
                        systemEnergy: store.systemEnergySnapshot
                    )
                    .appMotionEntrance(delay: 0.05)

                    UtilitySearchField(
                        placeholder: L10n.text("搜索应用、Bundle ID 或路径", "Search app, bundle ID, or path"),
                        text: $searchText,
                        tint: AppDesignTokens.Palette.information
                    )
                    .appMotionEntrance(delay: 0.065)

                    EnergyImpactControlsBar(
                        sortMode: $sortMode,
                        visibleCount: presentation.apps.count,
                        snapshot: snapshot
                    )
                    .appMotionEntrance(delay: 0.08)

                    if presentation.apps.isEmpty {
                        EmptyUtilityPanel(
                            systemImage: "bolt.batteryblock",
                            title: searchText.trimmed.isEmpty
                                ? L10n.text("没有可展示的运行应用", "No running apps to show")
                                : L10n.text("没有匹配应用", "No matching app")
                        )
                    } else {
                        LazyVStack(spacing: 0) {
                            EnergyImpactTableHeader()
                            ForEach(presentation.apps) { app in
                                EnergyImpactAppRow(
                                    app: app,
                                    sortMode: sortMode,
                                    maxEstimatedEnergyWh: presentation.maxEstimatedEnergyWh,
                                    maxCurrentPowerWatts: presentation.maxCurrentPowerWatts,
                                    maxAveragePowerWatts: presentation.maxAveragePowerWatts
                                )
                                if app.id != presentation.lastID {
                                    Divider()
                                        .padding(.leading, 72)
                                }
                            }
                        }
                        .glassPanel(cornerRadius: UtilitySizing.listCornerRadius)
                        .appMotionEntrance(delay: 0.10)
                    }
                }
                .padding(.horizontal, UtilitySizing.pagePadding)
                .padding(.bottom, UtilitySizing.pagePadding)
                .frame(maxWidth: UtilitySizing.pageMaxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            UtilityMetricCard(
                title: systemEnergy?.isEstimated == false
                    ? L10n.text("本次开机耗电", "Energy Since Boot")
                    : L10n.text("本次开机估算耗电", "Estimated Energy Since Boot"),
                value: systemEnergy?.totalKilowattHoursText ?? "—",
                detail: systemEnergy?.sourceBreakdownText
                    ?? L10n.text("正在建立监测会话", "Starting monitoring session"),
                systemImage: "battery.100.bolt",
                tint: AppDesignTokens.Palette.information
            )
            UtilityMetricCard(
                title: L10n.text("当前功率", "Current Power"),
                value: systemEnergy?.currentPowerText ?? snapshot.currentPowerWattsText,
                detail: systemEnergy?.lastSample?.confidence == .measured
                    ? L10n.text("电池电压与电流实测", "Measured battery voltage and current")
                    : L10n.text("应用进程归属估算", "Attributed-process estimate"),
                systemImage: "bolt.fill",
                tint: AppDesignTokens.Palette.secondary
            )
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
                "\(visibleCount) 个应用 · 合并统计 \(snapshot.processCount) 个进程",
                "\(visibleCount) apps · \(snapshot.processCount) processes grouped"
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

            EnergyImpactValueColumn(title: L10n.text("累计能耗", "Energy"), value: app.estimatedEnergyText)
                .frame(width: 92, alignment: .trailing)
            EnergyImpactValueColumn(title: L10n.text("当前功率", "Current power"), value: app.currentPowerWattsText)
                .frame(width: 92, alignment: .trailing)
            EnergyImpactValueColumn(title: L10n.text("平均功率", "Average power"), value: app.averagePowerWattsText)
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
            HStack(alignment: .top, spacing: 12) {
                ProcessIcon(path: app.iconPath, fallbackSystemImage: "app.fill")

                VStack(alignment: .leading, spacing: 6) {
                    appName
                    measurementPills
                    runtimeLabel
                }

                Spacer(minLength: AppDesignTokens.Spacing.small)

                AppIconButton(
                    title: L10n.text("切换到应用", "Switch to app"),
                    systemImage: "arrow.up.forward.app",
                    kind: .toolbar,
                    action: activateApplication
                )
                .frame(width: 28)
            }

            HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
                compactValueColumn(
                    title: L10n.text("累计能耗", "Energy"),
                    value: app.estimatedEnergyText
                )
                compactValueColumn(
                    title: L10n.text("当前功率", "Current power"),
                    value: app.currentPowerWattsText
                )
                compactValueColumn(
                    title: L10n.text("平均功率", "Average power"),
                    value: app.averagePowerWattsText
                )
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
            MetadataPill(
                text: app.measurementTitle,
                systemImage: measurementSystemImage,
                tint: measurementTint
            )
            if app.processCount > 1 {
                MetadataPill(
                    text: L10n.text("\(app.processCount) 进程", "\(app.processCount) processes"),
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

    private func compactValueColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
            Text(title)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(AppDesignTokens.Typography.inlineTitle)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
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

    var body: some View {
        Text(value)
            .font(AppDesignTokens.Typography.inlineTitle)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(title) \(value)")
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

struct AppUninstallerView: View {
    @ObservedObject var store: ScanStore
    @State private var searchText = ""
    @State private var listFilter: AppUninstallListFilter = .all
    @State private var sortMode: AppUninstallSortMode = .recommendation
    @State private var selectedApplicationID: String?

    private let sortModes: [AppUninstallSortMode] = [.recommendation, .bundleSize, .lastUsed, .modified, .name]

    private func listSummaryText(for presentation: AppUninstallListPresentation) -> String {
        let formattedTotal = ByteFormat.string(presentation.apps.reduce(0) { $0 + $1.sizeBytes })
        return L10n.text(
            "显示 \(presentation.count) 个应用 · 合计 \(formattedTotal) · 按\(sortMode.title)排序",
            "\(presentation.count) apps shown · \(formattedTotal) total · sorted by \(sortMode.title.lowercased())"
        )
    }

    private func shouldShowListControls(hasManageableApps: Bool) -> Bool {
        hasManageableApps || !searchText.trimmed.isEmpty
    }

    private var emptyTitle: String {
        if !searchText.trimmed.isEmpty || listFilter != .all {
            return L10n.text("当前筛选没有匹配应用", "No apps match the current filters")
        }
        return L10n.text("没有可管理应用", "No apps to manage")
    }

    private func incompleteScanText(_ coverage: AppUninstallScanCoverage) -> String {
        if coverage.didReachTimeLimit || coverage.didReachCandidateLimit {
            return L10n.text(
                "已检查 \(coverage.examinedCandidateCount)/\(coverage.discoveredCandidateCount) 个候选。为避免应用卡住，本次先保留已完成结果，可稍后重新扫描。",
                "Checked \(coverage.examinedCandidateCount) of \(coverage.discoveredCandidateCount) candidates. Completed results were kept to avoid stalling the app; retry later to continue."
            )
        }
        return L10n.text(
            "检测到的应用超过当前显示上限，本页优先保留占用空间最大的应用。",
            "The detected app count exceeds the display limit, so the largest apps are shown first."
        )
    }

    var body: some View {
        if !store.hasScannedInstalledApps {
            AppUninstallScanLandingView(store: store)
        } else {
            resultContent
        }
    }

    private var resultContent: some View {
        let manageableApps = store.installedApps.filter(\.canMoveToTrash)
        let presentation = AppUninstallListPresentation.make(
            apps: manageableApps,
            query: searchText,
            filter: listFilter,
            sortMode: sortMode
        )

        return ManagementListPage(
            title: L10n.text("卸载", "Uninstall"),
            subtitle: ReviewFilter.uninstall.pageSubtitle,
            systemImage: AppSymbols.Navigation.uninstall
        ) {
            Button {
                store.refreshInstalledApps()
            } label: {
                Label(L10n.text("刷新应用列表", "Refresh App List"), systemImage: "arrow.clockwise")
            }
            .disabled(!store.canRefreshInstalledApps)
        } controls: {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                if store.isLoadingInstalledApps {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在刷新应用列表…", "Refreshing application list…"))
                            .font(AppDesignTokens.Typography.secondary)
                    }
                }
                if let coverage = store.installedAppsScanCoverage, !coverage.isComplete {
                    Label(incompleteScanText(coverage), systemImage: "exclamationmark.triangle.fill")
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if shouldShowListControls(hasManageableApps: !manageableApps.isEmpty) {
                    HStack(spacing: AppDesignTokens.Spacing.small) {
                        TaskSearchField(
                            placeholder: L10n.text("搜索应用或路径", "Search Apps or Paths"),
                            text: $searchText,
                            tint: AppDesignTokens.Palette.information
                        )
                        Picker(L10n.text("筛选", "Filter"), selection: $listFilter) {
                            ForEach(AppUninstallListFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                        uninstallSortMenu
                    }
                }
            }
        } content: {
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.text("名称与位置", "Name and Location"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.text("应用大小", "App Size"))
                        .frame(width: 100, alignment: .trailing)
                    Text(L10n.text("操作", "Actions"))
                        .frame(width: 130, alignment: .trailing)
                }
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider()
                if presentation.apps.isEmpty {
                    if store.isLoadingInstalledApps {
                        LoadingPanel(title: L10n.text("正在读取应用列表", "Reading Applications"))
                            .frame(maxHeight: .infinity)
                    } else {
                        EmptyUtilityPanel(systemImage: "trash", title: emptyTitle)
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    ScrollViewReader { proxy in
                        List(selection: $selectedApplicationID) {
                            ForEach(presentation.apps) { app in
                                InstalledAppRow(app: app, store: store)
                                    .tag(app.id)
                                    .id(app.id)
                            }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                        .onChange(of: selectedApplicationID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                        .accessibilityLabel(L10n.text("可卸载应用列表", "Uninstallable Applications"))
                    }
                }
                Divider()
                Text(listSummaryText(for: presentation))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let app = presentation.apps.first(where: { app in
                    urls.contains { $0.isFileURL && PathSafety.lexicalPath($0.path) == PathSafety.lexicalPath(app.path) }
                }) else { return false }
                selectedApplicationID = app.id
                return true
            }
            .help(L10n.text("拖入列表中的应用可选中它；查看计划后才会确认卸载。", "Drop an application from this list to select it; uninstalling requires plan review and confirmation."))
        }
        .onChange(of: presentation.apps.map(\.id)) { _, ids in
            if let selectedApplicationID, !ids.contains(selectedApplicationID) {
                self.selectedApplicationID = nil
            }
        }
    }

    private var uninstallSortMenu: some View {
        Menu {
            ForEach(sortModes) { mode in
                Button {
                    sortMode = mode
                } label: {
                    if sortMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Label(
                L10n.text("排序 \(sortMode.title)", "Sort \(sortMode.title)"),
                systemImage: "arrow.up.arrow.down"
            )
            .foregroundStyle(AppDesignTokens.Palette.information)
            .fixedSize(horizontal: false, vertical: true)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.regular)
        .fixedSize()
    }
}

struct UninstallPreviewSheet: View {
    let app: InstalledAppItem
    let canConfirm: Bool
    let isProcessing: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                UninstallPreviewAppIcon(path: app.path)

                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("确认卸载", "Confirm Uninstall"))
                        .font(AppDesignTokens.Typography.sheetTitle)
                    Text(app.name)
                        .font(AppDesignTokens.Typography.inlineTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(app.bundleIdentifier.isEmpty ? app.path : app.bundleIdentifier)
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ByteFormat.string(app.sizeBytes))
                        .font(AppDesignTokens.Typography.secondary.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
            }
            .padding(22)

            Text(L10n.text(
                "应用会先移到废纸篓，清空废纸篓前仍可恢复。",
                "The app will be moved to Trash and remains recoverable until Trash is emptied."
            ))
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.bottom, app.externalManagementProviderName == nil ? 18 : 10)

            if let provider = app.externalManagementProviderName {
                Text(L10n.text(
                    "此应用来自 \(provider)。存储清理助手会在此完成卸载，但不会修改 \(provider) 中的订阅或安装记录。",
                    "This app comes from \(provider). Storage Cleaner will uninstall it here without changing its subscription or installation records in \(provider)."
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }

            Divider()

            HStack {
                Button(L10n.text("取消", "Cancel"), role: .cancel) {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isProcessing)

                Spacer()

                Button(role: .destructive) {
                    confirm()
                } label: {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L10n.text("卸载", "Uninstall"), systemImage: "trash")
                    }
                }
                .appButtonChrome(.primary)
                .tint(AppDesignTokens.Palette.destructive)
                .disabled(!canConfirm || isProcessing)
            }
            .padding(16)
        }
        .frame(width: 520, alignment: .topLeading)
        .background(AppDesignTokens.Palette.contentBackground)
        .interactiveDismissDisabled(isProcessing)
    }

}
private struct UninstallPreviewAppIcon: View {
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
        plan.automaticApps
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
                    value: "\(plan.automaticApps.count)",
                    systemImage: "bolt.fill",
                    tint: AppDesignTokens.Palette.information
                )
                if plan.authorizationApps.count > 0 {
                    OneClickPlanMetric(
                        title: L10n.text("需要授权", "Authorization"),
                        value: "\(plan.authorizationApps.count)",
                        systemImage: "lock.shield",
                        tint: .secondary
                    )
                }
                if plan.appStoreApps.count > 0 {
                    OneClickPlanMetric(
                        title: "App Store",
                        value: "\(plan.appStoreApps.count)",
                        systemImage: "bag.fill",
                        tint: .secondary
                    )
                }
                if plan.manualReviewCount > 0 {
                    OneClickPlanMetric(
                        title: L10n.text("需要手动", "Manual"),
                        value: "\(plan.manualReviewCount)",
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

                    VStack(spacing: 0) {
                    ForEach(allApps) { app in
                        OneClickUpdatePreviewRow(app: app)
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

                if plan.automaticCount > 0 {
                    Button {
                        store.confirmOneClickAppUpdates(
                            reopensUpdatedApplications: reopensUpdatedApplications
                        )
                    } label: {
                        Label(L10n.text("更新全部可自动更新项目", "Update All Automatic Items"), systemImage: "arrow.down.circle")
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

    var body: some View {
        HStack(spacing: 12) {
            InstalledAppIcon(path: app.path)

            VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textTightSpacing) {
                Text(app.name)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                Text(app.source.trimmed.nonEmpty ?? app.primaryUpdateProvider.rawValue)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Text(L10n.text("当前 \(app.currentVersionDisplay) → 最新 \(app.latestVersionDisplay)", "Current \(app.currentVersionDisplay) -> Latest \(app.latestVersionDisplay)"))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if app.isRunning || app.requiresApplicationQuit {
                Label(L10n.text("应用退出后更新", "Update After App Quits"), systemImage: "power")
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
            } else if app.requiresAdministratorAuthorization {
                Label(L10n.text("需要管理员授权", "Administrator Authorization Required"), systemImage: "lock.shield")
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct DuplicateFilesView: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    @ObservedObject private var workspace: DuplicateFilesStore

    init(store: ScanStore) {
        self.store = store
        _workspace = ObservedObject(wrappedValue: store.duplicateFilesWorkspace)
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
            filter: workspace.resultFilter,
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

    var body: some View {
        Group {
            if !workspace.hasScanned {
                duplicateScanHero
            } else {
                duplicateDataPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .id(workspace.hasScanned)
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
        FileToolLandingPage(
            title: ReviewFilter.duplicates.sidebarTitle,
            subtitle: ReviewFilter.duplicates.pageSubtitle,
            systemImage: ReviewFilter.duplicates.systemImage,
            configurationTitle: L10n.text("扫描位置", "Scan Locations"),
            actionTitle: scanButtonTitle,
            actionDetail: "",
            actionSystemImage: scanButtonSystemImage,
            status: duplicateScanStatus,
            isLoading: workspace.isScanning,
            isActionDisabled: !workspace.canScan,
            trustText: L10n.text(
                "只读扫描 · 不会自动删除文件",
                "Read-only scan · Files are never deleted automatically"
            ),
            action: store.scanDuplicateFiles
        ) { duplicateScanAccessory }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var duplicateDataPage: some View {
        FeatureDataPageShell(
            title: ReviewFilter.duplicates.sidebarTitle,
            subtitle: ReviewFilter.duplicates.pageSubtitle,
            systemImage: ReviewFilter.duplicates.systemImage
        ) {
            duplicateToolbarActions
        } controls: {
            duplicateResultControls
        } content: {
            duplicateDataContent
        }
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
                Picker(L10n.text("结果", "Results"), selection: $workspace.resultFilter) {
                    ForEach(DuplicateResultFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            } label: {
                Label(workspace.resultFilter.title, systemImage: "line.3.horizontal.decrease.circle")
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
                    }
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
                HStack(spacing: 2) {
                    ForEach(DuplicateFileScanScope.allCases) { scope in
                        Button { workspace.scanScope = scope } label: {
                            Text(scope.title)
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: GoldenLandingMetrics.scopeControlHeight)
                                .background(workspace.scanScope == scope ? theme.accent.opacity(0.40) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(workspace.scanScope == scope ? theme.accent : .clear))
                        }
                        .buttonStyle(ResponsivePlainButtonStyle())
                        .accessibilityLabel(scope.title)
                        .accessibilityAddTraits(workspace.scanScope == scope ? [.isSelected] : [])
                    }
                }
                .padding(2)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.15)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.text("扫描范围", "Scan Scope"))
                .help(duplicateScanScopeDetail)
                .padding(.bottom, 8)

                duplicateLocationButtons
                additionalLocationCount
                    .padding(.top, 8)
            }
        }
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
            .foregroundStyle(theme.primaryText)
            .background(theme.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.24)))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
    }

    private var additionalLocationCount: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                L10n.text(
                    "额外位置 \(workspace.configuredAdditionalRoots.count) 个",
                    "\(workspace.configuredAdditionalRoots.count) additional locations"
                ),
                systemImage: workspace.configuredAdditionalRoots.isEmpty
                    ? "folder"
                    : "folder.fill.badge.checkmark"
            )
            .font(AppTypography.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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
            }

            if !selectedItems.isEmpty {
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
                        L10n.text("查看清理计划 · \(selectedItems.count) 个", "Review Cleanup Plan · \(selectedItems.count)"),
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
            "已扫描 \(progress.scannedDirectories) 个目录、\(progress.scannedFiles) 个文件；完整哈希 \(progress.hashedFiles) 个（\(ByteFormat.string(progress.hashedBytes))）",
            "\(progress.scannedDirectories) folders and \(progress.scannedFiles) files scanned; \(progress.hashedFiles) fully hashed (\(ByteFormat.string(progress.hashedBytes)))"
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
                            Text(L10n.text("显示 \(groups.count) 组结果", "Showing \(groups.count) result groups"))
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
        .padding(AppDesignTokens.Spacing.large)
        .fullBleedSection()
        .appMotionEntrance(delay: 0.035)
    }

    private var duplicatePrimarySummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text("扫描结果", "Scan Result"))
                .font(AppDesignTokens.Typography.compactLabel)
                .foregroundStyle(.secondary)
            Text(L10n.text("\(allGroups.count) 组", "\(allGroups.count) groups"))
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
                value: ByteFormat.string(logicalDuplicateBytes),
                systemImage: "internaldrive.fill",
                tint: AppDesignTokens.Palette.storage
            )
            SmartCareMetric(
                title: L10n.text("物理可释放", "Physical Reclaimable"),
                value: physicalReclaimableBytes.map(ByteFormat.string)
                    ?? L10n.text("待确认", "Unknown"),
                systemImage: "questionmark.circle",
                tint: AppDesignTokens.Palette.warning
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var duplicateProgressPanel: some View {
        let progress = workspace.scanProgress ?? .initial
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progress.phase == .paused
                    ? L10n.text("扫描已暂停", "Scan Paused")
                    : L10n.text("正在后台扫描", "Scanning in Background"))
                    .font(AppDesignTokens.Typography.inlineTitle)
                Spacer()
                Button {
                    if progress.phase == .paused {
                        store.resumeDuplicateFileScan()
                    } else {
                        store.pauseDuplicateFileScan()
                    }
                } label: {
                    Label(
                        progress.phase == .paused ? L10n.text("继续", "Resume") : L10n.text("暂停", "Pause"),
                        systemImage: progress.phase == .paused ? "play.fill" : "pause.fill"
                    )
                }
                .appButtonChrome(.secondary)
                Button(role: .cancel) {
                    store.cancelDuplicateFileScan()
                } label: {
                    Label(L10n.text("取消", "Cancel"), systemImage: "xmark")
                }
                .appButtonChrome(.secondary)
            }
            duplicateProgressLabel
            if let currentPath = progress.currentPath {
                Text(currentPath)
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(currentPath)
                    .accessibilityLabel(currentPath)
            }
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
                                Text(root.status == .scanned
                                    ? L10n.text(
                                        "扫描 \(root.scannedDirectories) 个目录、\(root.scannedFiles) 个文件（\(ByteFormat.string(root.scannedBytes))）",
                                        "\(root.scannedDirectories) folders and \(root.scannedFiles) files scanned (\(ByteFormat.string(root.scannedBytes)))"
                                    )
                                    : duplicateSkipReasonTitle(root.skipReason))
                                    .font(AppDesignTokens.Typography.compactLabel)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if coverage.reachedTimeLimit || coverage.reachedFileLimit
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
                    "已处理 \(progress.processedItemCount)/\(progress.totalItemCount)，移动 \(progress.movedItemCount)，跳过 \(progress.skippedItemCount)，失败 \(progress.failedItemCount)",
                    "Processed \(progress.processedItemCount)/\(progress.totalItemCount); moved \(progress.movedItemCount), skipped \(progress.skippedItemCount), failed \(progress.failedItemCount)"
                ))
                .font(AppDesignTokens.Typography.secondary)
                Button(L10n.text("取消剩余项目", "Cancel Remaining Items"), role: .cancel) {
                    store.cancelVerifiedDuplicateCleanupExecution()
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
                        "移动 \(report.summary.movedItemCount)，跳过 \(report.summary.skippedItemCount)，失败 \(report.summary.failedItemCount)。尚未永久删除。",
                        "Moved \(report.summary.movedItemCount), skipped \(report.summary.skippedItemCount), failed \(report.summary.failedItemCount). Nothing was permanently deleted."
                    ))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
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
        case nil: L10n.text("未扫描", "Not scanned")
        }
    }

    private var duplicateEmptyState: some View {
        EmptyStateView(
            title: L10n.text("未发现内容相同文件", "No Identical Files Found"),
            detail: scanTimeText,
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
        return workspace.hasScanned
            ? L10n.text("重新扫描重复文件", "Rescan Duplicate Files")
            : L10n.text("扫描重复文件", "Scan Duplicates")
    }

    private var duplicateScanScopeDetail: String {
        switch workspace.scanScope {
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
        }
    }

    private var scanButtonSystemImage: String {
        if !workspace.canScan {
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
                HStack(spacing: AppDesignTokens.Spacing.medium) {
                    Label(
                        L10n.text("可执行 \(presentation.readyCount) 个", "\(presentation.readyCount) ready"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(AppDesignTokens.Palette.success)
                    Label(
                        L10n.text("跳过 \(presentation.skippedCount) 个", "\(presentation.skippedCount) skipped"),
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
                        MetadataPill(text: ByteFormat.string(group.sizeBytes), systemImage: "doc", tint: .secondary)
                        MetadataPill(
                            text: group.isContentConfirmed
                                ? group.relationship.title
                                : L10n.text("兼容数据待复核", "Legacy result to review"),
                            systemImage: group.isContentConfirmed ? "checkmark.seal" : "exclamationmark.triangle",
                            tint: group.isContentConfirmed && group.relationship != .unknown
                                ? AppDesignTokens.Palette.success
                                : AppDesignTokens.Palette.warning
                        )
                        MetadataPill(
                            text: group.relationship == .apfsClone
                                ? L10n.text("物理释放空间待删除后确认", "Physical reclaimable space confirmed after deletion")
                                : group.physicalReclaimableBytes.map {
                                    L10n.text("物理可释放 \(ByteFormat.string($0))", "Physical \(ByteFormat.string($0))")
                                } ?? L10n.text("物理可释放待确认", "Physical savings unknown"),
                            systemImage: "internaldrive",
                            tint: AppDesignTokens.Palette.warning
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(AppDesignTokens.Spacing.medium)

            Divider()

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
        .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: AppDesignTokens.Palette.tertiary, prominence: .quiet)
        .accessibilityElement(children: .contain)
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

            Text(ByteFormat.string(item.sizeBytes))
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
            ArtworkIconTile(
                systemImage: statusImage,
                filter: nil,
                tint: statusTint,
                size: UtilitySizing.supportIcon,
                glyphSize: UtilitySizing.supportGlyph,
                showsGlass: true,
                showsGlow: result.status == .completed
            )

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
            "预计应用减少 \(ByteFormat.string(Int64(clamping: execution.estimatedApplicationReductionBytes)))",
            "Estimated app reduction \(ByteFormat.string(Int64(clamping: execution.estimatedApplicationReductionBytes)))"
        )
    }

    private var observedAppDeltaText: String {
        guard let delta = result.executionResult?.observedApplicationMemoryDeltaBytes else {
            return L10n.text("应用变化不可用", "App change unavailable")
        }
        let value = ByteFormat.string(magnitude(delta))
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
        let value = ByteFormat.string(magnitude(delta))
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
    @State private var renderedUsedRatio: Double = 0
    let snapshot: MemorySnapshot
    let processSnapshot: MemorySnapshot
    let trendPoints: [MenuBarTelemetryPoint]
    @ObservedObject var store: ScanStore

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
        measurement.value.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—"
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
            : ByteFormat.string(cleanupPlan.estimatedRecoverableBytes)
    }

    private var summaryCaption: String {
        isObserving
            ? L10n.text("当前可用", "available now")
            : L10n.text("预计应用占用减少", "estimated app reduction")
    }

    var body: some View {
        ContentPanel {
            VStack(alignment: .leading, spacing: 12) {
#if DEBUG || STORAGE_CLEANER_BETA
                if MiniWindowDemoData.isEnabled {
                    Text("FIXTURE · " + L10n.text("内存摘要与历史", "Memory summary and history"))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
#endif
                if layout.density == .compact {
                    compactContent
                } else {
                    regularContent
                }
            }
            .padding(14)
        }
        .task(id: usedRatio) {
            guard let usedRatio else {
                renderedUsedRatio = 0
                return
            }
            guard AppMotionPolicy.shouldAnimate(reduceMotion: reduceMotion) else {
                renderedUsedRatio = usedRatio
                return
            }

            if renderedUsedRatio == 0 {
                await Task.yield()
            }
            withAnimation(AppMotionTokens.progress) {
                renderedUsedRatio = usedRatio
            }
        }
    }

    private var regularContent: some View {
        HStack(alignment: .center, spacing: 18) {
            HStack(spacing: 12) {
                pressureSummary
                usageSummary
            }
            recommendationSummary
                .frame(width: 268, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if !isObserving { recommendedActionButton }
                memoryTrend
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppDesignTokens.Spacing.large) {
                    pressureSummary
                        .frame(width: 96, alignment: .leading)
                    usageSummary
                        .frame(width: 96, alignment: .leading)
                    recommendationSummary
                        .frame(minWidth: 240, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
                    HStack(spacing: AppDesignTokens.Spacing.large) {
                        pressureSummary
                        usageSummary
                    }
                    recommendationSummary
                }
            }

            if !isObserving {
                recommendedActionButton
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            memoryTrend
        }
    }

    private var memoryTrend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Label(
                    L10n.text("内存使用趋势", "Memory Usage Trend"),
                    systemImage: "waveform.path.ecg"
                )
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(AppChartPalette.memory)

                Spacer(minLength: AppDesignTokens.Spacing.small)

                Text(snapshot.generatedAt, format: .dateTime.hour().minute().second())
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(L10n.text("最近更新", "Last updated"))
            }

            GeekPrecisionLineChart(
                points: trendPoints,
                series: [
                    MenuBarTelemetrySeries(
                        id: "memory-management-usage",
                        title: L10n.text("内存占用", "Memory Usage"),
                        channel: .memory,
                        color: AppChartPalette.memory
                    ),
                    MenuBarTelemetrySeries(
                        id: "memory-management-pressure",
                        title: L10n.text("压力趋势估算", "Pressure estimate"),
                        channel: .memoryPressure,
                        color: AppDesignTokens.Palette.caution
                    ),
                ],
                valueRange: 0...100,
                unit: .percent,
                accessibilityLabel: L10n.text(
                    "最近两分钟的内存占用与压力趋势估算",
                    "Memory usage and estimated pressure trend over the last two minutes"
                ),
                duration: 120,
                showsTimelineLabels: true,
                showsTooltip: true,
                showsValueLabels: true,
                lineWidth: 1.6,
                fillOpacity: 0.08
            )
            .frame(height: layout.density == .compact ? 112 : 90)

            DisclosureGroup(L10n.text("指标说明", "Metric details")) {
                Text(L10n.text(
                    "压力趋势估算 = 100 − 系统压力余量；不是占用率，也不等同于压力等级。",
                    "Pressure estimate = 100 − system pressure headroom; it is neither memory usage nor the pressure grade."
                ))
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
        }
        .padding(AppDesignTokens.Spacing.small)

    }

    private var pressureSummary: some View {
        GeekCombinedRing(
            title: L10n.text("内存压力", "Memory Pressure"),
            value: snapshot.reportablePressureLevel?.title ?? L10n.text("不可用", "Unavailable"),
            progress: nil,
            tint: releaseTint,
            size: layout.density == .compact ? 96 : 80,
            fixedValueFontSize: 20,
            strokeWidth: 6,
            isStatusOnly: snapshot.reportablePressureLevel != nil
        )
        .help(pressureHeadroomText + L10n.text(
            "；环颜色表示评估等级，不是压力百分比或可用内存比例。",
            "; ring color shows the assessed grade, not a pressure percentage or available memory ratio."
        ))
    }

    private var usageSummary: some View {
        GeekCombinedRing(
            title: L10n.text("内存占用", "Memory Used"),
            value: usedPercentText,
            progress: usedRatio,
            tint: AppChartPalette.memory,
            size: layout.density == .compact ? 96 : 80,
            fixedValueFontSize: 20,
            strokeWidth: 6
        )
        .help(usedRatio == nil
            ? (snapshot.measurements.availableBytes.unavailableDetail
                ?? snapshot.measurements.physicalBytes.unavailableDetail
                ?? L10n.text("数据不可用", "Data unavailable"))
            : L10n.text("实测使用量 / 物理总内存；容量明细见下方", "Measured used / total physical memory; capacity details below"))
        .accessibilityLabel(L10n.text("内存占用", "Memory used"))
        .accessibilityValue(usedPercentText)
    }

    private var recommendationSummary: some View {
        let usedGiB = snapshot.measuredUsedBytes.map {
            String(format: "%.1f", Double($0) / 1_073_741_824)
        } ?? "—"
        let totalGiB = snapshot.measurements.physicalBytes.value.map {
            String(format: "%.1f", Double($0) / 1_073_741_824)
        } ?? "—"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(summaryTitle)
                    .font(AppDesignTokens.Typography.sheetTitle)
                Label(
                    snapshot.reportablePressureLevel?.title ?? L10n.text("不可用", "Unavailable"),
                    systemImage: "gauge.with.dots.needle.67percent"
                )
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(releaseTint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summaryValue)
                    .font(AppDesignTokens.Typography.pageTitle)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .appNumericTransition(value: summaryValue)
                Text(summaryCaption)
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                MemoryInlineMetric(
                    title: L10n.text("已用 / 总量", "Used / Total"),
                    value: "\(usedGiB) / \(totalGiB) GiB"
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
                .frame(minWidth: 118)
        }
        .appButtonChrome(.primary)
        .controlSize(.large)
        .tint(store.isRecommendedMemorySelectionPrepared
            ? AppDesignTokens.Palette.destructive
            : releaseTint)
        .disabled(!store.canOptimizeMemory)
        .help(store.isRecommendedMemorySelectionPrepared
            ? L10n.text(
                "再次点击将正常退出已选中的高占用应用",
                "Click again to quit the selected high-usage apps normally"
            )
            : L10n.text(
                "先选中建议退出的高占用应用，不会立即退出",
                "Select suggested high-usage apps first without quitting them"
            ))
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
    let snapshot: MemorySnapshot
    @ObservedObject var store: ScanStore
    var minimumListHeight: CGFloat = 140

    var sampledProcesses: [MemoryProcess] {
        snapshot.processesByResidentUsage
    }

    private var apps: [MemoryAppUsage] {
        snapshot.appsByResidentUsage.filter {
            $0.canQuit && $0.bundlePath?.hasSuffix(".app") == true
        }
    }

    private var selectedBytesText: String {
        ByteFormat.string(store.selectedMemoryAppEstimatedBytes)
    }

    private func selectAllApps() {
        apps.forEach { store.setMemoryAppUsageSelection($0, isSelected: true) }
    }

    var body: some View {
        let selectedAppCount = apps.filter { store.isMemoryAppUsageSelected($0) }.count
        let recommendedAppIDs = Set(snapshot.recommendedQuitApps.map(\.id))
        let lastAppID = apps.last?.id

        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text("进程列表范围", "Process list scope"), selection: $store.memoryShowsAllProcesses) {
                Text(L10n.text("已采样进程 (\(sampledProcesses.count))", "Sampled Processes (\(sampledProcesses.count))"))
                    .tag(true)
                Text(L10n.text("可退出应用 (\(apps.count))", "Quittable Apps (\(apps.count))"))
                    .tag(false)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 4) {
#if DEBUG || STORAGE_CLEANER_BETA
                if MiniWindowDemoData.isEnabled { Text("FIXTURE ·") }
#endif
                Text(L10n.text("进程快照", "Process snapshot"))
                Spacer(minLength: 6)
                Text(L10n.text("采样于", "Sampled at"))
                Text(snapshot.generatedAt, format: .dateTime.year().month().day().hour().minute().second())
                    .monospacedDigit()
            }
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)

            if store.memoryShowsAllProcesses {
                sampledProcessList
            } else {
                selectionHeader(
                    visibleCount: apps.count,
                    selectedAppCount: selectedAppCount
                )

                if !apps.isEmpty {
                    selectionActions(
                        hasRecommendedApps: !recommendedAppIDs.isEmpty,
                        selectedAppCount: selectedAppCount
                    )
                }

                if apps.isEmpty {
                    Label(L10n.text("没有可退出的运行应用", "No quittable running apps"), systemImage: "checkmark.circle")
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(AppDesignTokens.Palette.success)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        MemoryAppSelectionTableHeader()
                        ScrollView {
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
                        .frame(minHeight: minimumListHeight, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(14)
        .fullBleedSection()
    }

    private var sampledProcessList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("只读 · Top 256 可读进程", "Read-only · Top 256 readable processes"), systemImage: "info.circle")
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .help(L10n.text(
                    "本次快照仅包含可读取且物理内存足迹大于 0 的进程，最多 256 项；不代表全部系统 PID。",
                    "The snapshot includes readable processes with a positive physical footprint, up to 256; it is not every system PID."
                ))

            if sampledProcesses.isEmpty {
                Text(L10n.text("本次没有可读的进程样本", "No readable process samples in this snapshot"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(L10n.text("进程 · 按占用排序", "Process · by memory use"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("PID")
                            .frame(width: 60, alignment: .trailing)
                        Text(L10n.text("内存占用", "Memory Use"))
                            .frame(width: 110, alignment: .trailing)
                    }
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()

                    ScrollView {
                        // The snapshot is capped at 256 rows. Eager layout avoids the
                        // macOS 27 lazy-layout accessibility scroll assertion.
                        VStack(spacing: 0) {
                            ForEach(sampledProcesses) { process in
                                MemoryReadOnlyProcessRow(process: process)
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: minimumListHeight, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func selectionHeader(
        visibleCount: Int,
        selectedAppCount: Int
    ) -> some View {
        if layout.density == .compact {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                selectionTitle(visibleCount: visibleCount)
                if visibleCount > 0 {
                    selectionSummary(
                        selectedAppCount: selectedAppCount,
                        alignment: .leading,
                        textAlignment: .leading
                    )
                }
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                selectionTitle(visibleCount: visibleCount)
                Spacer(minLength: 8)
                if visibleCount > 0 {
                    selectionSummary(
                        selectedAppCount: selectedAppCount,
                        alignment: .trailing,
                        textAlignment: .trailing
                    )
                    .frame(minWidth: 118, alignment: .trailing)
                }
            }
        }
    }

    private func selectionTitle(visibleCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(L10n.text("可退出应用", "Quittable Apps"))
                .font(AppDesignTokens.Typography.inlineTitle)
            Text(L10n.text("\(visibleCount) 个", "\(visibleCount) apps"))
                .font(AppDesignTokens.Typography.compactLabel)
                .foregroundStyle(.secondary)
        }
    }

    private func selectionSummary(
        selectedAppCount: Int,
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: AppDesignTokens.Layout.textTightSpacing) {
            Text(
                selectedAppCount == 0
                    ? L10n.text("未选择", "None selected")
                    : L10n.text("已选 \(selectedAppCount) 个应用", "\(selectedAppCount) apps selected")
            )
            .font(AppDesignTokens.Typography.compactLabelEmphasis)
            .monospacedDigit()
            .appNumericTransition(value: selectedAppCount)

            Text(
                selectedAppCount == 0
                    ? L10n.text("选择后显示合计", "Total appears after selection")
                    : L10n.text(
                        "目前约占 \(selectedBytesText) · 预计释放以刷新重测为准",
                        "Uses about \(selectedBytesText) · release remeasured after refresh"
                    )
            )
            .font(AppDesignTokens.Typography.compactLabel)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .appNumericTransition(value: selectedBytesText)
            .multilineTextAlignment(textAlignment)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func selectionActions(
        hasRecommendedApps: Bool,
        selectedAppCount: Int
    ) -> some View {
        if layout.density == .compact {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                HStack(spacing: 8) {
                    if hasRecommendedApps {
                        recommendedSelectionButton
                    }
                    selectAllButton
                }
                if selectedAppCount > 0 {
                    HStack(spacing: 8) {
                        clearSelectionButton
                        quitSelectionButton(selectedAppCount: selectedAppCount)
                    }
                }
            }
            .controlSize(.regular)
            .font(AppDesignTokens.Typography.secondary)
        } else {
            HStack(spacing: 8) {
                if hasRecommendedApps {
                    recommendedSelectionButton
                }
                selectAllButton
                Spacer(minLength: 8)
                if selectedAppCount > 0 {
                    clearSelectionButton
                    quitSelectionButton(selectedAppCount: selectedAppCount)
                }
            }
            .controlSize(.regular)
            .font(AppDesignTokens.Typography.secondary)
        }
    }

    private var recommendedSelectionButton: some View {
        Button {
            _ = store.selectRecommendedMemoryApps()
        } label: {
            Label(L10n.text("选择建议退出项", "Select Suggested Apps"), systemImage: "checkmark.circle")
        }
        .disabled(!store.canRequestMemoryQuitActions)
    }

    private var selectAllButton: some View {
        Button {
            selectAllApps()
        } label: {
            Label(L10n.text("全选", "Select All"), systemImage: "checkmark.circle")
        }
        .disabled(!store.canRequestMemoryQuitActions)
    }

    private var clearSelectionButton: some View {
        Button {
            store.clearMemoryProcessSelection()
        } label: {
            Label(L10n.text("清空选择", "Clear Selection"), systemImage: "xmark.circle")
        }
        .disabled(!store.canRequestMemoryQuitActions)
    }

    private func quitSelectionButton(selectedAppCount: Int) -> some View {
        Button(role: .destructive) {
            store.requestQuitSelectedMemoryProcesses()
        } label: {
            Label(
                L10n.text(
                    "退出 \(selectedAppCount) 个应用",
                    "Quit \(selectedAppCount) Apps"
                ),
                systemImage: "xmark.circle.fill"
            )
        }
        .appButtonChrome(.primary)
        .disabled(!store.canRequestMemoryQuitActions)
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
            Text(process.availability == .available ? ByteFormat.string(process.residentBytes) : process.availability.title)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)
        }
        .font(AppDesignTokens.Typography.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
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
                .font(AppDesignTokens.Typography.compactLabelEmphasis)

            Spacer(minLength: 10)

            Text(L10n.text("内存", "Memory"))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
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
    let app: MemoryAppUsage
    let isSuggested: Bool
    @ObservedObject var store: ScanStore

    private var rowTint: Color {
        isSuggested ? AppDesignTokens.Palette.warning : AppDesignTokens.Palette.steadyChrome
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
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 22)
                .help(L10n.text("选择后可统一退出", "Select to quit together"))
                .accessibilityLabel(L10n.text("选择 \(app.name)", "Select \(app.name)"))
                .accessibilityValue(isSelected ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not selected"))
                .disabled(!store.canRequestMemoryQuitActions)

            ProcessIcon(path: app.iconPath, fallbackSystemImage: "app.fill")

            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .fixedSize(horizontal: false, vertical: true)

                if app.processCount > 1 || isSuggested || app.isActive {
                    HStack(spacing: 8) {
                        if app.processCount > 1 {
                            Label("x\(app.processCount)", systemImage: "square.stack.3d.up")
                                .foregroundStyle(.secondary)
                        }
                        if isSuggested {
                            Label(L10n.text("建议", "Suggested"), systemImage: "sparkles")
                                .foregroundStyle(AppDesignTokens.Palette.warning)
                        } else if app.isActive {
                            Label(L10n.text("正在使用", "Active"), systemImage: "circle.fill")
                                .foregroundStyle(AppDesignTokens.Palette.information)
                        }
                    }
                    .font(AppDesignTokens.Typography.compactLabel)
                    .fixedSize(horizontal: false, vertical: true)
                }

                MemoryProcessUsageBar(percent: app.percent, tint: rowTint)
                    .frame(maxWidth: 240)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteFormat.string(app.bytes))
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .appNumericTransition(value: app.bytes)
                Text(String(format: "%.1f%%", app.percent))
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 94, alignment: .trailing)
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, 9)
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

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            InstalledAppIcon(path: app.path)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .lineLimit(1)
                    .help(app.name)
                Text(app.path)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(app.path)
                    .accessibilityLabel(app.path)
                HStack(spacing: 8) {
                    if !app.versionDisplay.trimmed.isEmpty {
                        Text(app.versionDisplay)
                            .help(app.versionDisplay)
                    }
                    if let provider = app.externalManagementProviderName {
                        Label(
                            L10n.text("来源：\(provider)", "Source: \(provider)"),
                            systemImage: "shippingbox.fill"
                        )
                        .foregroundStyle(AppDesignTokens.Palette.tertiary)
                        .help(L10n.text("来源：\(provider)", "Source: \(provider)"))
                    }
                    if let reason = app.uninstallSuggestionReason {
                        Label(
                            L10n.text("建议卸载：\(reason)", "Suggested Uninstall: \(reason)"),
                            systemImage: "lightbulb.fill"
                        )
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                        .help(reason)
                        .accessibilityValue(reason)
                    }
                }
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            Text(ByteFormat.string(app.sizeBytes))
                .font(AppDesignTokens.Typography.compactLabel)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)

            Button {
                store.requestUninstall(app)
            } label: {
                Label(L10n.text("查看卸载计划", "Review Uninstall Plan"), systemImage: "list.clipboard")
            }
            .appButtonChrome(.secondary)
            .controlSize(.regular)
            .disabled(!store.canRequestUninstall(app))
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 60)
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
        AppEmptyState(
            title: title,
            systemImage: "arrow.triangle.2.circlepath",
            density: .inline,
            isLoading: true
        )
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
