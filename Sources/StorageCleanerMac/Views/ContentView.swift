import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    private let computerHealthStore: ComputerHealthStore
    private let networkSpeedTestStore: NetworkSpeedTestStore
    @StateObject private var browserPrivacyStore: BrowserPrivacyStore
    private let macBenchmarkStore: MacBenchmarkStore
    private let macBenchmarkLeaderboardStore: BenchmarkV7LeaderboardStore
    private let heavyWorkActivityStore: HeavyWorkActivityStore
    @ObservedObject private var navigationState: AppNavigationState
    @AppStorage(L10n.languageDefaultsKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(L10n.appearanceDefaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(FirstLaunchOnboardingPolicy.completionDefaultsKey)
    private var didCompleteFirstLaunchOnboarding = false
    @SceneStorage("selectedFilter.v2") private var selectedFilterRaw = ReviewFilter.overview.rawValue
    @State private var isShowingFirstLaunchOnboarding = false

    init(
        store: ScanStore,
        computerHealthStore: ComputerHealthStore,
        networkSpeedTestStore: NetworkSpeedTestStore,
        macBenchmarkStore: MacBenchmarkStore,
        macBenchmarkLeaderboardStore: BenchmarkV7LeaderboardStore,
        heavyWorkActivityStore: HeavyWorkActivityStore,
        browserPrivacyStore: BrowserPrivacyStore? = nil
    ) {
        self.store = store
        self.computerHealthStore = computerHealthStore
        self.networkSpeedTestStore = networkSpeedTestStore
        _browserPrivacyStore = StateObject(
            wrappedValue: browserPrivacyStore ?? BrowserPrivacyStore()
        )
        self.macBenchmarkStore = macBenchmarkStore
        self.macBenchmarkLeaderboardStore = macBenchmarkLeaderboardStore
        self.heavyWorkActivityStore = heavyWorkActivityStore
        _navigationState = ObservedObject(wrappedValue: store.navigationState)
    }

    private var selectedFilter: Binding<ReviewFilter> {
        Binding {
            navigationState.selectedFilter
        } set: { newValue in
            selectFilter(newValue)
        }
    }

    private var launchFilter: ReviewFilter? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--open-filter"),
              arguments.indices.contains(index + 1) else { return nil }
        let rawValue = arguments[index + 1].trimmed
        return ReviewFilter(rawValue: rawValue) ?? ReviewFilter.resolvedDestination(rawValue: rawValue)
    }

#if DEBUG
    private var debugScanPresentation: DebugScanPresentationScenario? {
        DebugScanPresentationScenario.launchScenario
    }
#endif

#if DEBUG
    private var debugSmartScanSession: DebugSmartScanSessionFixture.Scenario? {
        DebugSmartScanSessionFixture.launchScenario
    }
#endif

#if DEBUG
    private var debugAppUpdatePresentation: DebugAppUpdatePresentationFixture.Scenario? {
        DebugAppUpdatePresentationFixture.launchScenario
    }
#endif

    var body: some View {
        GeometryReader { proxy in
            mainContent(metrics: WindowLayoutMetrics(contentSize: proxy.size))
        }
    }

    private func mainContent(metrics: WindowLayoutMetrics) -> some View {
        fullWorkspace(metrics: metrics)
        .navigationSplitViewStyle(.balanced)
        .environment(\.windowLayoutMetrics, metrics)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) {
                    IntegratedTitlebar(theme: activePresentationFilter.moduleTheme)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    IntegratedTitlebar(theme: activePresentationFilter.moduleTheme)
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(MainWindowChromeConfigurator().frame(width: 0, height: 0))
        .focusedSceneValue(
            \.mainWindowSidebarAction,
            MainWindowSidebarAction {
                NSApp.sendAction(
                    #selector(NSSplitViewController.toggleSidebar(_:)),
                    to: nil,
                    from: nil
                )
            }
        )
        .focusedSceneValue(
            \.startupItemsKeyboardActions,
            startupItemsKeyboardActions
        )
        .id(languageRawValue + appearanceRawValue)
        .task {
            await Task.yield()
            await store.loadPersistedHistoryIfNeeded()
        }
        .task {
            await networkSpeedTestStore.restoreLastSuccessfulResult()
        }
#if DEBUG || STORAGE_CLEANER_BETA
        .task {
            await MainWindowSnapshotPipeline.runIfRequested(
                navigationState: navigationState,
                browserPrivacyStore: browserPrivacyStore,
                store: store
            )
        }
#endif
        .onChange(of: store.requestedFilter) { _, requestedFilter in
            guard let requestedFilter else { return }
            selectFilter(requestedFilter)
            Task { @MainActor in
                store.requestedFilter = nil
            }
        }
        .overlay(alignment: .bottom) {
            if let actionMessage = store.actionMessage {
                StatusToastView(message: actionMessage)
                    .padding(.bottom, 18)
                    .allowsHitTesting(false)
                    .transition(
                        AppMotionTokens.stateTransition(
                            reduceMotion: reduceMotion,
                            edge: .bottom
                        )
                    )
            }
        }
        .animation(
            reduceMotion ? nil : AppMotionTokens.stateChange,
            value: store.actionMessage
        )
        .overlay {
            if let snapshot = store.cleanupOperationSnapshot,
               store.cleanupExecutionProgress == nil,
               store.lastCleanReport == nil {
                CleanupOperationOverlay(store: store, snapshot: snapshot)
                    .environment(\.moduleTheme, activePresentationFilter.moduleTheme)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : AppMotionTokens.stateChange,
            value: store.cleanupOperationSnapshot
        )
        .onAppear {
#if DEBUG
            if let debugAppUpdatePresentation {
                selectFilter(.updater)
                store.installDebugAppUpdatePresentationFixture(debugAppUpdatePresentation)
                return
            }
#endif
            let initialFilter = store.requestedFilter
                ?? launchFilter
                ?? ReviewFilter.resolvedDestination(rawValue: selectedFilterRaw)
                ?? .overview
            selectFilter(initialFilter)
            if store.requestedFilter != nil {
                Task { @MainActor in
                    store.requestedFilter = nil
                }
            }
#if DEBUG
            if debugSmartScanSession != nil || debugScanPresentation != nil {
                return
            }
#endif
            if FirstLaunchOnboardingPolicy.shouldPresent(
                isCompleted: didCompleteFirstLaunchOnboarding,
                isApplicationHost: Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            ) {
                isShowingFirstLaunchOnboarding = true
            }
            store.prepareInitialPermissionCheckOnLaunch()
        }
        .onChange(of: navigationState.route) { _, newRoute in
            Task { @MainActor in
                let newFilter = newRoute.filter
                if selectedFilterRaw != newFilter.rawValue {
                    selectedFilterRaw = newFilter.rawValue
                }
                if newFilter.isStorageFilter && newFilter != .overview {
                    preserveSelectionOrSelectFirst(for: newFilter)
                }
            }
        }
        .alert(L10n.text("移到废纸篓？", "Move to Trash?"), isPresented: trashAlertBinding) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.pendingTrashItem = nil
            }
            Button(trashConfirmationTitle, role: .destructive) {
                store.confirmTrash()
            }
        } message: {
            if let item = store.pendingTrashItem {
                Text(trashConfirmationMessage(for: item))
            }
        }
        .alert(L10n.text("选择扫描文件夹", "Choose Scan Folders"), isPresented: initialFolderAccessPromptBinding) {
            Button(L10n.text("稍后", "Later"), role: .cancel) {
                store.skipInitialFolderAccessPrompt()
            }
            Button(L10n.text("选择文件夹", "Choose Folders")) {
                store.requestRequiredFolderAccess()
            }
        } message: {
            Text(
                L10n.text(
                    "选择下载、桌面、文稿等需要扫描的文件夹。授权仍有效时，应用会在下次启动时自动恢复访问。",
                    "Choose folders such as Downloads, Desktop, and Documents. If authorization remains valid, the app restores access automatically at the next launch."
                )
            )
        }
        .sheet(isPresented: bulkTrashSheetBinding) {
            CleanupPreviewSheet(store: store)
                .environment(\.locale, L10n.locale)
                .environment(\.moduleTheme, activePresentationFilter.moduleTheme)
        }
        .sheet(isPresented: $isShowingFirstLaunchOnboarding) {
            FirstLaunchOnboardingView(store: store) {
                store.skipInitialFolderAccessPrompt()
                didCompleteFirstLaunchOnboarding = true
                isShowingFirstLaunchOnboarding = false
            }
            .environment(\.locale, L10n.locale)
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: v2CleanupConfirmationBinding) {
            if let plan = store.pendingCleanPlan,
               let preflight = store.pendingCleanPreflight {
                CleanupPlanConfirmationSheet(
                    store: store,
                    plan: plan,
                    preflight: preflight
                )
                .environment(\.locale, L10n.locale)
                .environment(\.moduleTheme, activePresentationFilter.moduleTheme)
            }
        }
        .alert(L10n.text("清空废纸篓？", "Empty Trash?"), isPresented: emptyTrashAlertBinding) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelEmptyTrash()
            }
            Button(L10n.text("永久删除", "Permanently Delete"), role: .destructive) {
                store.confirmEmptyTrash()
            }
            .disabled(!store.canRequestEmptyTrash)
        } message: {
            if let summary = store.pendingEmptyTrashSummary {
                Text(L10n.emptyTrashMessage(count: summary.itemCount, bytes: ByteFormat.string(summary.totalBytes)))
            }
        }
        .alert(L10n.text("撤销最近清理？", "Undo Latest Cleanup?"), isPresented: cleanupRestoreAlertBinding) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelRestoreLatestCleanup()
            }
            Button(L10n.text("恢复到原位置", "Restore to Original Locations")) {
                store.confirmRestoreLatestCleanup()
            }
        } message: {
            let count = store.pendingCleanupRestoreEntry?.restorableMoveRecords.count ?? 0
            Text(L10n.text(
                "将尝试从废纸篓恢复 \(count) 项。如果原位置已有同名文件，该项会跳过，不会覆盖或自动改名。",
                "The app will try to restore \(count) item(s) from Trash. Existing items at the original locations are skipped without overwrite or automatic renaming."
            ))
        }
        .alert(
            L10n.text("恢复安全清理项目？", "Restore Safe Cleanup Items?"),
            isPresented: v2CleanupRestoreAlertBinding
        ) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelRestoreLatestV2Cleanup()
            }
            Button(L10n.text("恢复到原位置", "Restore to Original Locations")) {
                store.confirmRestoreLatestV2Cleanup()
            }
        } message: {
            Text(L10n.text(
                "只恢复身份仍与清理回执一致的项目；原位置已有内容、路径不安全或身份变化时会跳过，不会覆盖。",
                "Only items whose identity still matches the cleanup receipt are restored. Existing destinations, unsafe paths, or identity changes are skipped without overwrite."
            ))
        }
        .sheet(isPresented: oneClickUpdateSheetBinding) {
            if let plan = store.pendingOneClickUpdatePlan {
                OneClickUpdatePreviewSheet(store: store, plan: plan)
                    .environment(\.locale, L10n.locale)
            }
        }
        .sheet(isPresented: uninstallPreviewSheetBinding) {
            if let app = store.pendingUninstallApp {
                UninstallPreviewSheet(
                    app: app,
                    canConfirm: store.canRequestUninstall(app),
                    isProcessing: store.isUninstallingApp,
                    cancel: {
                        store.pendingUninstallApp = nil
                    },
                    confirm: {
                        store.confirmUninstall()
                    }
                )
                .environment(\.locale, L10n.locale)
            }
        }
        .alert(L10n.text("是否清除关联文件？", "Remove Associated Files?"), isPresented: relatedAppCleanupAlertBinding) {
            Button(L10n.text("保留", "Keep"), role: .cancel) {
                store.keepRelatedAppFiles()
            }
            Button(L10n.text("清除关联文件", "Remove Associated Files"), role: .destructive) {
                store.confirmRelatedAppCleanup()
            }
        } message: {
            if let app = store.pendingRelatedCleanupApp {
                Text(L10n.text(
                    "\(app.name) 已卸载。是否将发现的 \(app.relatedItems.count) 个关联文件（\(ByteFormat.string(app.relatedBytes))）也移到废纸篓？",
                    "\(app.name) was uninstalled. Move \(app.relatedItems.count) associated files (\(ByteFormat.string(app.relatedBytes))) to Trash too?"
                ))
            }
        }
        .sheet(isPresented: accessRepairGuideBinding) {
            AccessRepairGuideSheet(
                deniedCount: store.scanHistorySummary.latest?.deniedCount ?? 0,
                rescan: {
                    store.startScan()
                }
            )
            .environment(\.locale, L10n.locale)
        }
        .alert(startupOperationTitle, isPresented: startupAlertBinding) {
            Button(
                store.isPerformingStartupOperation
                    ? L10n.text("取消操作", "Cancel Operation")
                    : L10n.text("取消", "Cancel"),
                role: .cancel
            ) {
                if store.isPerformingStartupOperation {
                    store.cancelStartupOperation()
                } else {
                    store.cancelPendingStartupOperation()
                }
            }
            Button(startupOperationActionTitle, role: startupOperationButtonRole) {
                store.confirmStartupOperation()
            }
            .disabled(store.isPerformingStartupOperation || store.pendingStartupOperationPlan == nil)
        } message: {
            if let plan = store.pendingStartupOperationPlan,
               let candidate = store.pendingStartupOperationCandidate {
                let warnings = plan.warnings.isEmpty ? "" : "\n\n" + plan.warnings.joined(separator: "\n")
                Text("\(candidate.name)\n\(plan.impactSummary)\(warnings)\n\nLabel: \(plan.label)\n\(plan.plistURL.path)")
            }
        }
        .alert(L10n.text("退出应用？", "Quit App?"), isPresented: memoryQuitAlertBinding) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.pendingMemoryProcess = nil
            }
            Button(L10n.text("退出", "Quit"), role: .destructive) {
                store.confirmQuitProcess()
            }
            .disabled(store.pendingMemoryProcess.map { !store.canRequestMemoryQuit($0) } ?? true)
        } message: {
            if let process = store.pendingMemoryProcess {
                Text(L10n.text("正常退出“\(process.name)”", "Quit “\(process.name)” normally"))
            }
        }
        .alert(L10n.text("退出所选应用？", "Quit Selected Apps?"), isPresented: memoryBatchQuitAlertBinding) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelQuitSelectedMemoryProcesses()
            }
            Button(L10n.text("退出所选应用", "Quit Selected Apps"), role: .destructive) {
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
        .alert(L10n.text("操作失败", "Operation Failed"), isPresented: errorAlertBinding) {
            Button(L10n.text("关闭", "Close")) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func fullWorkspace(metrics: WindowLayoutMetrics) -> some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                selection: selectedFilter
            )
            .navigationSplitViewColumnWidth(
                min: metrics.sidebarMinimumWidth,
                ideal: metrics.sidebarIdealWidth,
                max: metrics.sidebarMaximumWidth
            )
        } detail: {
            MainContentHost(
                route: activePresentationFilter,
                showsIntegratedTitlebar: false
            ) {
#if DEBUG
                if debugAppUpdatePresentation != nil {
                    AppUpdaterView(store: store)
                } else if let debugSmartScanSession {
                    SmartScanFlowHost(store: store, selection: selectedFilter)
                        .onAppear {
                            navigationState.select(.overview)
                            store.installDebugSmartScanSessionFixture(debugSmartScanSession)
                        }
                } else if let debugScanPresentation {
                    DebugScanPresentationView(
                        scenario: debugScanPresentation,
                        module: activePresentationFilter
                    )
                } else {
                    DetailRouterView(
                        store: store,
                        largeFilesWorkspace: store.largeFilesWorkspace,
                        computerHealthStore: computerHealthStore,
                        networkSpeedTestStore: networkSpeedTestStore,
                        browserPrivacyStore: browserPrivacyStore,
                        macBenchmarkStore: macBenchmarkStore,
                        macBenchmarkLeaderboardStore: macBenchmarkLeaderboardStore,
                        heavyWorkActivityStore: heavyWorkActivityStore,
                        selection: selectedFilter
                    )
                }
#else
                DetailRouterView(
                    store: store,
                    largeFilesWorkspace: store.largeFilesWorkspace,
                    computerHealthStore: computerHealthStore,
                    networkSpeedTestStore: networkSpeedTestStore,
                    browserPrivacyStore: browserPrivacyStore,
                    macBenchmarkStore: macBenchmarkStore,
                    macBenchmarkLeaderboardStore: macBenchmarkLeaderboardStore,
                    heavyWorkActivityStore: heavyWorkActivityStore,
                    selection: selectedFilter
                )
#endif
            }
        }
    }

    private func selectFilter(_ filter: ReviewFilter) {
        navigationState.select(filter)
    }

    private var startupItemsKeyboardActions: StartupItemsKeyboardActions? {
        guard navigationState.selectedFilter == .startup else { return nil }
        return StartupItemsKeyboardActions(
            refresh: { store.refreshStartupItems() },
            focusSearch: {
                NotificationCenter.default.post(name: .storageCleanerFocusStartupItemsSearch, object: nil)
            }
        )
    }

    private var activePresentationFilter: ReviewFilter {
#if DEBUG
        if debugAppUpdatePresentation != nil {
            return .updater
        }
        if debugSmartScanSession != nil {
            return .overview
        }
#endif
        return navigationState.selectedFilter == .utilityHub
            ? navigationState.selectedUtilityFilter
            : navigationState.selectedFilter
    }

    private func preserveSelectionOrSelectFirst(for filter: ReviewFilter) {
        let items = store.items(for: filter)
        if let selectedItemID = store.selectedItemID,
           items.contains(where: { $0.id == selectedItemID }) {
            return
        }
        store.selectedItemID = items.first?.id
    }

    private var trashAlertBinding: Binding<Bool> {
        Binding {
            store.pendingTrashItem != nil
        } set: { isPresented in
            if !isPresented {
                store.pendingTrashItem = nil
            }
        }
    }

    private var trashConfirmationTitle: String {
        guard meaningfulCloseRequirement(for: store.pendingTrashItem) != nil else {
            return L10n.text("移到废纸篓", "Move to Trash")
        }
        return L10n.text("已退出，移到废纸篓", "Quit Done, Move to Trash")
    }

    private func trashConfirmationMessage(for item: StorageItem) -> String {
        let base = L10n.moveItemToTrashMessage(item.title)
        guard let requirement = meaningfulCloseRequirement(for: item) else { return base }
        return base + "\n\n" + L10n.text(
            "清理前必须先退出：\(requirement)",
            "Before cleanup, you must first quit: \(requirement)"
        )
    }

    private func meaningfulCloseRequirement(for item: StorageItem?) -> String? {
        guard let item else { return nil }
        let value = item.requiresClose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "无", value.lowercased() != "none" else { return nil }
        return value
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding {
            store.errorMessage != nil && store.scanPresentationState != .failed
        } set: { isPresented in
            if !isPresented {
                store.errorMessage = nil
            }
        }
    }

    private var initialFolderAccessPromptBinding: Binding<Bool> {
        Binding {
            store.isShowingInitialFolderAccessPrompt && !isShowingFirstLaunchOnboarding
        } set: { isPresented in
            if !isPresented {
                store.skipInitialFolderAccessPrompt()
            }
        }
    }

    private var bulkTrashSheetBinding: Binding<Bool> {
        Binding {
            !store.pendingBulkTrashItems.isEmpty
        } set: { isPresented in
            if !isPresented {
                store.cancelTrashAllGreenPreview()
            }
        }
    }

    private var v2CleanupConfirmationBinding: Binding<Bool> {
        Binding {
            store.scanPresentationState == .confirming
                && store.pendingCleanPlan != nil
                && store.pendingCleanPreflight?.isConfirmable == true
        } set: { isPresented in
            if !isPresented {
                store.cancelV2CleanupConfirmation()
            }
        }
    }

    private var emptyTrashAlertBinding: Binding<Bool> {
        Binding {
            store.pendingEmptyTrashSummary != nil
        } set: { isPresented in
            if !isPresented {
                store.cancelEmptyTrash()
            }
        }
    }

    private var cleanupRestoreAlertBinding: Binding<Bool> {
        Binding {
            store.pendingCleanupRestoreEntry != nil
        } set: { isPresented in
            if !isPresented {
                store.cancelRestoreLatestCleanup()
            }
        }
    }

    private var v2CleanupRestoreAlertBinding: Binding<Bool> {
        Binding {
            store.isV2RestoreConfirmationPresented
        } set: { isPresented in
            if !isPresented {
                store.cancelRestoreLatestV2Cleanup()
            }
        }
    }

    private var oneClickUpdateSheetBinding: Binding<Bool> {
        Binding {
            store.pendingOneClickUpdatePlan != nil
        } set: { isPresented in
            if !isPresented {
                store.dismissOneClickUpdatePreview()
            }
        }
    }

    private var accessRepairGuideBinding: Binding<Bool> {
        Binding {
            store.isShowingAccessRepairGuide
        } set: { isPresented in
            store.isShowingAccessRepairGuide = isPresented
        }
    }

    private var startupAlertBinding: Binding<Bool> {
        Binding {
            store.pendingStartupOperationPlan != nil
        } set: { isPresented in
            if !isPresented {
                if store.isPerformingStartupOperation {
                    store.cancelStartupOperation()
                } else {
                    store.cancelPendingStartupOperation()
                }
            }
        }
    }

    private var startupOperationTitle: String {
        switch store.pendingStartupOperationPlan?.kind {
        case .enable:
            L10n.text("启用启动项？", "Enable Startup Item?")
        case .disable:
            L10n.text("停用启动项？", "Disable Startup Item?")
        case .stopCurrentSession:
            L10n.text("停止本次运行？", "Stop This Run?")
        case nil:
            L10n.text("启动项操作", "Startup Item Action")
        }
    }

    private var startupOperationActionTitle: String {
        switch store.pendingStartupOperationPlan?.kind {
        case .enable:
            L10n.text("启用", "Enable")
        case .disable:
            L10n.text("停用", "Disable")
        case .stopCurrentSession:
            L10n.text("停止本次运行", "Stop This Run")
        case nil:
            L10n.text("继续", "Continue")
        }
    }

    private var startupOperationButtonRole: ButtonRole? {
        switch store.pendingStartupOperationPlan?.kind {
        case .disable, .stopCurrentSession:
            .destructive
        case .enable, nil:
            nil
        }
    }

    private var memoryQuitAlertBinding: Binding<Bool> {
        Binding {
            store.pendingMemoryProcess != nil
        } set: { isPresented in
            if !isPresented {
                store.pendingMemoryProcess = nil
            }
        }
    }

    private var memoryBatchQuitAlertBinding: Binding<Bool> {
        Binding {
            store.pendingMemoryQuitSummary != nil
                && !store.pendingMemoryProcessesToQuit.isEmpty
                && !store.isMemoryBatchQuitConfirmationPresentedInMenuBar
        } set: { _ in
            // Alert actions own the operation intent. A passive binding write
            // is presentation state only and must not invalidate the plan.
        }
    }

    private var uninstallPreviewSheetBinding: Binding<Bool> {
        Binding {
            store.pendingUninstallApp != nil
        } set: { isPresented in
            if !isPresented && !store.isUninstallingApp {
                store.pendingUninstallApp = nil
            }
        }
    }

    private var relatedAppCleanupAlertBinding: Binding<Bool> {
        Binding {
            store.pendingRelatedCleanupApp != nil
        } set: { _ in }
    }

}

private struct DetailRouterView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var largeFilesWorkspace: LargeFilesStore
    let computerHealthStore: ComputerHealthStore
    let networkSpeedTestStore: NetworkSpeedTestStore
    @ObservedObject var browserPrivacyStore: BrowserPrivacyStore
    let macBenchmarkStore: MacBenchmarkStore
    let macBenchmarkLeaderboardStore: BenchmarkV7LeaderboardStore
    let heavyWorkActivityStore: HeavyWorkActivityStore
    @Binding var selection: ReviewFilter
    private var filter: ReviewFilter {
        selection
    }

    private var presentationFilter: ReviewFilter {
        filter == .utilityHub ? store.navigationState.selectedUtilityFilter : filter
    }

    var body: some View {
        Group {
            // The overview is the one Smart Scan flow. Its host performs one
            // direct switch over the Store's presentation state, so SwiftUI
            // never retains the old scan page beneath results during a
            // removal transition.
            if presentationFilter == .overview || presentsV2CleanupPage {
                SmartScanFlowHost(store: store, selection: $selection)
            } else if store.scanPresentationState.showsProgressPage,
                      store.scanPresentationRoute == presentationFilter {
                ScanProgressView(store: store, module: presentationFilter)
            } else {
                routedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var presentsV2CleanupPage: Bool {
        guard store.cleanupFeatureConfiguration.mode == .v2Full else { return false }

        return switch store.scanPresentationState {
        case .cleaning, .verifying, .completed:
            true
        case .cancelling:
            if case .cancellingExecution = store.cleanupWorkflowState {
                true
            } else {
                false
            }
        case .cancelled, .failed:
            store.lastCleanReport != nil
        case .idle, .preparing, .scanning, .finalizing, .results, .confirming:
            false
        }
    }

    @ViewBuilder
    private var routedContent: some View {
        if filter == .overview {
            if let session = store.cleanupScanSession,
               session.includedCategoryIDs == nil {
                CleanupScanOverviewView(
                    store: store,
                    session: session
                )
            } else if let result = store.result {
                OverviewView(result: result, store: store, selection: $selection)
            } else {
                StartView(store: store)
            }
        } else if ReviewFilter.cleanupWorkspaceCases.contains(filter) {
            cleanupWorkspace
        } else if filter == .privacy {
            BrowserPrivacyWorkspaceView(
                browserPrivacyStore: browserPrivacyStore
            )
        } else if ReviewFilter.fileWorkspaceCases.contains(filter) {
            fileWorkspace
        } else if filter == .healthHub {
            ComputerHealthWorkspaceView(
                scanStore: store,
                healthStore: computerHealthStore,
                networkStore: networkSpeedTestStore
            )
        } else if filter == .performance {
            PerformanceBenchmarkWorkspaceView(
                benchmarkStore: macBenchmarkStore,
                leaderboardStore: macBenchmarkLeaderboardStore,
                heavyWorkActivityStore: heavyWorkActivityStore,
                monitorState: store.menuBarMonitorState,
                auxiliaryState: store.menuBarAuxiliaryMonitorState,
                isTelemetryPaused: store.isMenuBarRefreshPaused,
                refreshTelemetry: store.refreshMenuBarMonitor
            )
        } else if filter == .utilityHub {
            SystemUtilitiesHubView(store: store)
        } else {
            StartView(store: store)
        }
    }

    @ViewBuilder
    private var cleanupWorkspace: some View {
        Group {
            if cleanupSessionForCurrentFilter == nil,
               (store.cleanupScanSession != nil || store.result == nil) {
                ToolPreparationView(
                    store: store,
                    filter: filter
                )
            } else {
                ReviewWorkspaceShell(
                    filter: filter,
                    headerActions: { EmptyView() }
                ) {
                    Group {
                        if let session = cleanupSessionForCurrentFilter {
                            CleanupScanResultsView(
                                store: store,
                                filter: filter,
                                session: session
                            )
                        } else if store.result != nil {
                            ItemListView(store: store, filter: filter)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .layoutPriority(1)
                    .clipped()
                }
            }
        }
#if DEBUG
        .layoutProbe(LayoutProbeID.workspace)
#endif
    }

    private var cleanupSessionForCurrentFilter: ScanSession? {
        guard let session = store.cleanupScanSession else { return nil }
        if filter == .devCaches {
            guard session.includedCategoryIDs?.contains("developer") ?? true else {
                return nil
            }
            return session
        }
        if filter == .green, session.includedRuleIDs != nil {
            return session
        }
        return session.includedCategoryIDs == nil ? session : nil
    }

    @ViewBuilder
    private var fileWorkspace: some View {
        if filter == .duplicates {
            DuplicateFilesView(store: store)
        } else if filter == .migration,
                  (largeFilesWorkspace.migrationKind == .file
                    ? !largeFilesWorkspace.hasScanned
                    : !store.hasScannedInstalledApps) {
            LargeFilesScanLandingView(
                store: store,
                workspace: largeFilesWorkspace,
                mode: .migration
            )
        } else if filter == .migration {
            FeatureDataPageShell(
                title: ReviewFilter.migration.sidebarTitle,
                subtitle: ReviewFilter.migration.pageSubtitle,
                systemImage: ReviewFilter.migration.systemImage
            ) {
                fileAnalysisScanButton
            } controls: {
                EmptyView()
            } content: {
                LargeFilesView(
                    store: store,
                    workspace: largeFilesWorkspace,
                    mode: .migration
                )
            }
        } else if largeFilesWorkspace.hasStorageAnalysis {
            FeatureDataPageShell(
                title: ReviewFilter.largeFiles.sidebarTitle,
                subtitle: ReviewFilter.largeFiles.pageSubtitle,
                systemImage: ReviewFilter.largeFiles.systemImage
            ) {
                fileAnalysisScanButton
            } controls: {
                EmptyView()
            } content: {
                LargeFilesView(store: store, workspace: largeFilesWorkspace)
            }
        } else {
            LargeFilesScanLandingView(store: store, workspace: largeFilesWorkspace)
        }
    }

    private var fileAnalysisScanButton: some View {
        Button {
            if filter == .migration, largeFilesWorkspace.migrationKind == .application {
                store.refreshInstalledApps()
            } else if filter == .migration {
                if largeFilesWorkspace.isScanning {
                    largeFilesWorkspace.cancelScan()
                } else {
                    largeFilesWorkspace.startScan()
                }
            } else if largeFilesWorkspace.isAnalyzingStorage {
                largeFilesWorkspace.cancelStorageAnalysis()
            } else {
                largeFilesWorkspace.startStorageAnalysis()
            }
        } label: {
            Label(fileScanActionTitle, systemImage: fileScanActionSystemImage)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel(fileScanActionTitle)
        .help(fileScanActionTitle)
        .appButtonChrome(.secondary)
        .disabled(
            filter == .migration && largeFilesWorkspace.migrationKind == .application
                ? !store.canRefreshInstalledApps
                : filter == .migration
                ? largeFilesWorkspace.phase == .cancelling
                    || (!largeFilesWorkspace.isScanning && !largeFilesWorkspace.canScan)
                : largeFilesWorkspace.storageAnalysisPhase == .cancelling
                    || (!largeFilesWorkspace.isAnalyzingStorage
                        && !largeFilesWorkspace.canStartStorageAnalysis)
        )
    }

    private var fileScanActionTitle: String {
        if filter == .migration, largeFilesWorkspace.migrationKind == .application {
            if store.isLoadingInstalledApps {
                return L10n.text("正在读取可搬移 App…", "Reading Movable Apps…")
            }
            return store.hasScannedInstalledApps
                ? L10n.text("重新读取可搬移 App", "Read Movable Apps Again")
                : L10n.text("读取可搬移 App", "Read Movable Apps")
        }
        if filter == .migration, largeFilesWorkspace.isScanning {
            return L10n.text("取消扫描", "Cancel Scan")
        }
        if filter != .migration, largeFilesWorkspace.isAnalyzingStorage {
            return L10n.text("取消分析", "Cancel Analysis")
        }
        if filter == .migration {
            return largeFilesWorkspace.hasScanned
                ? L10n.text("重新扫描可搬移文件", "Rescan Movable Files")
                : L10n.text("扫描可搬移文件", "Scan Movable Files")
        }
        return largeFilesWorkspace.hasStorageAnalysis
            ? L10n.text("重新分析磁盘", "Rescan Disk")
            : L10n.text("分析磁盘空间", "Analyze Disk Space")
    }

    private var fileScanActionSystemImage: String {
        if filter == .migration, largeFilesWorkspace.migrationKind == .application {
            return store.hasScannedInstalledApps ? "arrow.clockwise" : "app.badge"
        }
        if (filter == .migration && largeFilesWorkspace.isScanning)
            || (filter != .migration && largeFilesWorkspace.isAnalyzingStorage) {
            return "xmark"
        }
        let hasResult = filter == .migration
            ? largeFilesWorkspace.hasScanned
            : largeFilesWorkspace.hasStorageAnalysis
        return hasResult ? "arrow.clockwise" : "play.fill"
    }
}

/// The overview has a single, mutually-exclusive Smart Scan page. The Store
/// remains alive above this view, so switching pages never recreates a scanner,
/// a frozen plan, or an executor.
private struct SmartScanFlowHost: View {
    @ObservedObject var store: ScanStore
    @Binding var selection: ReviewFilter

    var body: some View {
        Group {
            switch store.scanPresentationState {
            case .idle:
                StartView(store: store)

            case .preparing, .scanning, .finalizing:
                SmartScanScanningPage(
                    progress: store.mainScanProgress ?? .starting(mode: .fallback),
                    isFinalizing: store.scanPresentationState == .finalizing,
                    canCancel: store.canCancelMainScan,
                    isCancelling: store.isCancellingMainScan,
                    onCancel: store.cancelMainScan
                )

            case .cancelling:
                if isCancellingCleanup {
                    SmartScanCleanupProgressPage(
                        store: store,
                        progress: store.cleanupExecutionProgress,
                        isCancelling: true
                    )
                } else {
                    SmartScanScanningPage(
                        progress: store.mainScanProgress ?? .starting(mode: .fallback),
                        isCancelling: true,
                        onCancel: store.cancelMainScan
                    )
                }

            case .results, .confirming:
                resultsPage

            case .cleaning:
                SmartScanCleanupProgressPage(
                    store: store,
                    progress: store.cleanupExecutionProgress,
                    isCancelling: isCancellingCleanup,
                    onCancel: store.cancelV2CleanupExecution
                )

            case .verifying:
                SmartScanCleanupProgressPage(
                    store: store,
                    progress: store.cleanupExecutionProgress,
                    isPreflight: isPreflightingCleanup,
                    isVerifying: true
                )

            case .completed:
                if let report = store.lastCleanReport {
                    SmartScanCleanupCompletedPage(
                        store: store,
                        report: report,
                        onDone: store.dismissV2CleanupReport
                    )
                } else {
                    SmartScanTerminalPage(
                        title: L10n.text("安全清理完成", "Safe Cleanup Complete"),
                        detail: L10n.text("已生成清理报告。", "A cleanup report is available."),
                        systemImage: "checkmark.shield.fill",
                        status: .completed(L10n.text("已完成", "Completed")),
                        actionTitle: L10n.text("完成", "Done"),
                        action: store.dismissV2CleanupReport
                    )
                }

            case .cancelled:
                if let report = store.lastCleanReport {
                    SmartScanCleanupCompletedPage(
                        store: store,
                        report: report,
                        onDone: store.dismissV2CleanupReport
                    )
                } else {
                    SmartScanTerminalPage(
                        title: L10n.text("扫描已取消", "Scan Cancelled"),
                        detail: L10n.text(
                            "本次只读扫描已停止，未执行任何清理。",
                            "This read-only scan was stopped; no cleanup was performed."
                        ),
                        systemImage: "xmark.circle.fill",
                        status: .idle(L10n.text("未改动文件", "No files changed")),
                        actionTitle: L10n.text("返回首页", "Back to Home"),
                        action: store.resetSmartScanPresentation
                    )
                }

            case .failed:
                if let report = store.lastCleanReport {
                    SmartScanCleanupCompletedPage(
                        store: store,
                        report: report,
                        onDone: store.dismissV2CleanupReport
                    )
                } else {
                    SmartScanTerminalPage(
                        title: L10n.text("扫描未完成", "Scan Did Not Finish"),
                        detail: store.errorMessage ?? L10n.text(
                            "请检查权限后重试。",
                            "Check access and try again."
                        ),
                        systemImage: "exclamationmark.triangle.fill",
                        status: .failed(L10n.text("未执行清理", "No cleanup was performed")),
                        actionTitle: L10n.text("重新扫描", "Scan Again"),
                        action: restart
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var resultsPage: some View {
        if let session = store.cleanupScanSession {
            CleanupScanOverviewView(store: store, session: session)
        } else if let result = store.result {
            // Legacy file scans do not create a V2 session; preserve their
            // established result surface while the V2 Smart Scan uses the
            // compact results page above.
            OverviewView(result: result, store: store, selection: $selection)
        } else {
            StartView(store: store)
        }
    }

    private var isCancellingCleanup: Bool {
        if case .cancellingExecution = store.cleanupWorkflowState {
            return true
        }
        return false
    }

    private var isPreflightingCleanup: Bool {
        switch store.cleanupWorkflowState {
        case .buildingPlan, .preflighting:
            true
        case .idle, .results, .awaitingConfirmation, .executing,
             .cancellingExecution, .completed, .failed:
            false
        }
    }

    private func restart() {
        store.resetSmartScanPresentation()
        store.startScanRespectingAccessGuide()
    }
}

private struct SmartScanTerminalPage: View {
    let title: String
    let detail: String
    let systemImage: String
    let status: ScanStatusPresentation
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HeroScanPage(
            title: title,
            subtitle: detail,
            headerSystemImage: systemImage,
            actionTitle: actionTitle,
            actionDetail: L10n.text("返回智能扫描首页", "Return to Smart Scan home"),
            actionSystemImage: systemImage,
            status: status,
            action: action
        )
    }
}

private struct ReviewWorkspaceShell<Content: View, HeaderActions: View>: View {
    let filter: ReviewFilter
    let headerActions: HeaderActions
    let content: Content

    init(
        filter: ReviewFilter,
        @ViewBuilder headerActions: () -> HeaderActions,
        @ViewBuilder content: () -> Content
    ) {
        self.filter = filter
        self.headerActions = headerActions()
        self.content = content()
    }

    var body: some View {
        ManagementListPage(
            title: filter.sidebarTitle,
            subtitle: filter.pageSubtitle,
            systemImage: filter.systemImage
        ) {
            headerActions
        } controls: {
            EmptyView()
        } content: {
            content
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)
                .clipped()
        }
#if DEBUG
        .layoutProbe(LayoutProbeID.picker)
#endif
    }

}

private struct ToolPreparationView: View {
    @ObservedObject var store: ScanStore
    let filter: ReviewFilter

    private var latestStatus: LastScanStatusSummary? {
        store.scanHistorySummary.latestStatus()
    }

    var body: some View {
        HeroScanPage(
            title: filter.sidebarTitle,
            subtitle: filter.pageSubtitle,
            headerSystemImage: filter.systemImage,
            configurationTitle: L10n.text("扫描范围", "Scan Scope"),
            actionTitle: scanActionTitle,
            actionDetail: "",
            actionSystemImage: scanActionSystemImage,
            status: preparationStatus,
            isLoading: store.isPreparingMainScan,
            isActionDisabled: store.isPreparingScan || hasEmptySafeCleanupSelection,
            trustText: L10n.text("只显示可审阅项目，不会自动删除", "Only reviewable items are shown; nothing is deleted automatically"),
            showsAccessory: filter == .devCaches || filter == .green,
            action: store.startScanRespectingAccessGuide
        ) {
            if filter == .devCaches {
                DeveloperCleanupThresholdControl(store: store)
                    .frame(maxWidth: 560)
            } else if filter == .green {
                SafeCleanupScopeSelectionView(store: store)
                    .frame(maxWidth: 560)
            }
        }
    }

    private var hasEmptySafeCleanupSelection: Bool {
        filter == .green && store.selectedSafeCleanupScopes.isEmpty
    }

    private var scanActionTitle: String {
        latestStatus == nil
            ? L10n.text("开始扫描", "Start Scan")
            : L10n.text("重新扫描", "Rescan")
    }

    private var scanActionSystemImage: String {
        latestStatus == nil ? "play.fill" : "arrow.clockwise"
    }

    private var preparationStatus: ScanStatusPresentation {
        if let activity = store.activeScanStatusText {
            return store.isPreparingMainScan ? .scanning(activity) : .idle(activity)
        }
        if hasEmptySafeCleanupSelection {
            return .idle(L10n.text(
                "请至少选择一个扫描项目",
                "Select at least one scan item"
            ))
        }
        guard let latestStatus else { return .neverScanned }

        switch latestStatus.attentionLevel {
        case .rescanRecommended:
            return .expired
        case .permissionLimited:
            return .idle(L10n.text("部分位置需要授权", "Some locations need permission"))
        case .current:
            return .completed(L10n.text("重新扫描以载入当前项目", "Rescan to load current items"))
        }
    }

}

private struct SafeCleanupScopeSelectionView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: AppDesignTokens.Spacing.small),
                GridItem(.flexible(), spacing: AppDesignTokens.Spacing.small),
            ],
            spacing: AppDesignTokens.Spacing.small
        ) {
            ForEach(SafeCleanupScanScope.allCases) { scope in
                SafeCleanupScopeButton(
                    scope: scope,
                    isSelected: store.selectedSafeCleanupScopes.contains(scope)
                ) {
                    store.toggleSafeCleanupScope(scope)
                }
            }
        }
    }
}

private struct SafeCleanupScopeButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.moduleTheme) private var theme
    @State private var isHovered = false

    let scope: SafeCleanupScanScope
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.16), in: RoundedRectangle(
                        cornerRadius: 9,
                        style: .continuous
                    ))
                    .accessibilityHidden(true)

                Text(title)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, AppDesignTokens.Spacing.medium)
            .padding(.vertical, AppDesignTokens.Spacing.small)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? tint : theme.secondaryText.opacity(0.72))
                    .padding(8)
                    .accessibilityHidden(true)
            }
            .background(
                LinearGradient(
                    colors: isSelected
                        ? [tint.opacity(isHovered ? 0.22 : 0.17), tint.opacity(0.08)]
                        : [Color.white.opacity(isHovered ? 0.085 : 0.055), Color.white.opacity(0.025)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(
                    cornerRadius: AppDesignTokens.Radius.glassControl,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppDesignTokens.Radius.glassControl,
                    style: .continuous
                )
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isSelected ? 0.30 : 0.16),
                            isSelected ? tint.opacity(0.72) : Color.white.opacity(0.08),
                            Color.black.opacity(0.22),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isSelected ? 1.25 : 1
                )
            }
        }
        .contentShape(RoundedRectangle(
            cornerRadius: AppDesignTokens.Radius.glassControl,
            style: .continuous
        ))
        .buttonStyle(ResponsivePlainButtonStyle())
        .onHover { isHovered = $0 }
        .shadow(
            color: tint.opacity(isSelected ? (isHovered ? 0.30 : 0.18) : 0),
            radius: isHovered ? 10 : 7,
            y: 3
        )
        .animation(
            AppMotionTokens.resolved(AppMotionTokens.hover, reduceMotion: reduceMotion),
            value: isHovered
        )
        .accessibilityLabel(title)
        .accessibilityValue(isSelected
            ? L10n.text("已选择", "Selected")
            : L10n.text("未选择", "Not selected"))
        .accessibilityHint(detail)
        .help(detail)
    }

    private var title: String {
        switch scope {
        case .caches: L10n.text("系统缓存", "System Caches")
        case .logs: L10n.text("日志文件", "Log Files")
        case .temporaryFiles: L10n.text("临时文件", "Temporary Files")
        case .downloadResidue: L10n.text("下载残留", "Download Residue")
        }
    }

    private var detail: String {
        switch scope {
        case .caches:
            L10n.text("可重新生成的系统与应用缓存", "Regenerable system and app caches")
        case .logs:
            L10n.text("扫描后仅供逐项审阅", "Review individually after scanning")
        case .temporaryFiles:
            L10n.text("已知可再生成的临时目录", "Known regenerable temporary folders")
        case .downloadResidue:
            L10n.text("安装包与下载内容需确认", "Installers and downloads require review")
        }
    }

    private var systemImage: String {
        switch scope {
        case .caches: "internaldrive.fill"
        case .logs: "doc.text.fill"
        case .temporaryFiles: "clock.fill"
        case .downloadResidue: "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        switch scope {
        case .caches: .orange
        case .logs: .blue
        case .temporaryFiles: .mint
        case .downloadResidue: .cyan
        }
    }
}

private struct StartView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if store.shouldShowPermissionPanelInMainInterface {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 14) {
                            heroStage
                                .frame(minHeight: 420)

                            ScanReadinessPanel(store: store, latestStatus: latestScanStatus)
                                .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
                                .transition(AppMotionTokens.stateTransition(reduceMotion: reduceMotion, edge: .bottom))
                                .appMotionEntrance(delay: 0.07)
                        }
                        .padding(.vertical, AppDesignTokens.Spacing.section)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    heroStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(
            AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
            value: store.shouldShowPermissionPanelInMainInterface
        )
    }

    private var heroStage: some View {
        SmartCareLandingView(store: store, latestStatus: latestScanStatus)
    }

    private var latestScanStatus: LastScanStatusSummary? {
        store.scanHistorySummary.latestStatus()
    }

}

private struct AccessRepairGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deniedCount: Int
    let rescan: () -> Void

    private var steps: [AccessRepairStep] {
        AccessRepairGuideService.steps()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "lock.open.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: AppDesignTokens.Icon.sheetHeaderGlyph, weight: .semibold))
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .frame(width: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textRegularSpacing) {
                    Text(L10n.text("修复扫描权限", "Fix Scan Access"))
                        .font(AppDesignTokens.Typography.sheetTitle)
                    Text(headerDetail)
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            VStack(spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    AccessRepairStepRow(number: index + 1, step: step)
                }
            }

            HStack {
                Menu {
                    Button {
                        CleanupService.openFilesAndFoldersSettings()
                    } label: {
                        Label(L10n.text("文件与文件夹", "Files & Folders"), systemImage: "folder")
                    }

                    Button {
                        CleanupService.openFullDiskAccessSettings()
                    } label: {
                        Label(L10n.text("完整磁盘访问", "Full Disk Access"), systemImage: "externaldrive")
                    }
                } label: {
                    Label(L10n.text("打开隐私设置", "Open Privacy Settings"), systemImage: "gearshape")
                }
                .controlSize(.regular)

                Spacer()

                Button(L10n.text("完成", "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    dismiss()
                    rescan()
                } label: {
                    Label(L10n.text("重新扫描", "Rescan"), systemImage: "arrow.clockwise")
                }
                .appButtonChrome(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 680, alignment: .topLeading)
        .background(AppDesignTokens.Palette.contentBackground)
    }

    private var headerDetail: String {
        if deniedCount > 0 {
            return L10n.text("\(deniedCount) 个位置未读取", "\(deniedCount) unread locations")
        }
        return L10n.text("确认关键位置权限", "Check key location access")
    }
}

private struct AccessRepairStepRow: View {
    let number: Int
    let step: AccessRepairStep

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(number).")
                .font(AppDesignTokens.Typography.compactLabel)
                .fontWeight(.bold)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .frame(width: 24, alignment: .trailing)

            ArtworkIconTile(
                systemImage: step.systemImage,
                filter: nil,
                tint: AppDesignTokens.Palette.warning,
                size: 40,
                glyphSize: 24,
                showsGlass: true
            )

            VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textTightSpacing) {
                Text(step.title)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                Text(step.detail)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: AppDesignTokens.Palette.warning, prominence: .quiet)
    }
}

private struct HomeStatusBoard: View {
    private enum Layout {
        static let panelHorizontalPadding: CGFloat = 26
        static let panelVerticalPadding: CGFloat = 24
        static let cardMinHeight: CGFloat = 208
        static let rowSpacing: CGFloat = 28
        static let copySpacing: CGFloat = 8
        static let summaryWidth: CGFloat = 132
        static let gaugeSize: CGFloat = 132
    }

    @ObservedObject var store: ScanStore
    @Binding var selection: ReviewFilter
    let summary: LastScanStatusSummary?

    private var candidates: [StorageItem] {
        store.greenTrashCandidates
    }

    private var hasLiveResult: Bool {
        store.result != nil
    }

    private var hasCleanableCandidates: Bool {
        hasLiveResult && !candidates.isEmpty
    }

    private var cleanableBytes: Int64 {
        if hasLiveResult {
            return candidates.reduce(0) { $0 + $1.sizeBytes }
        }
        return summary?.entry.greenBytes ?? store.scanHistorySummary.latest?.greenBytes ?? 0
    }

    var body: some View {
        statusCard
    }

    private var statusCard: some View {
        ViewThatFits(in: .horizontal) {
            statusRow
            statusLead
        }
            .padding(.horizontal, Layout.panelHorizontalPadding)
            .padding(.vertical, Layout.panelVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: Layout.cardMinHeight, alignment: .leading)
            .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: cleanupTint, elevated: statusShouldElevate, prominence: statusProminence)
            .accessibilityElement(children: .combine)
    }

    private var statusRow: some View {
        HStack(alignment: .center, spacing: Layout.rowSpacing) {
            statusLead
            Spacer(minLength: 16)
            cleanupSummaryColumn
        }
    }

    private var statusLead: some View {
        HStack(alignment: .center, spacing: 26) {
            SmartCareGauge(
                score: gaugeScore,
                tint: cleanupTint,
                label: gaugeScore == nil ? L10n.text("尚未扫描", "Ready to scan") : L10n.text("存储评分", "Storage Score")
            )
            .frame(width: Layout.gaugeSize, height: Layout.gaugeSize)

            statusCopy
        }
        .layoutPriority(1)
    }

    private var cleanupSummaryColumn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if cleanableBytes > 0 {
                Text(ByteFormat.string(cleanableBytes))
                    .font(AppDesignTokens.Typography.numeric)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)

                Text(!hasLiveResult ? L10n.text("上次可清理", "Last cleanable") : L10n.text("可安全清理", "Safe to clean"))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: Layout.summaryWidth, alignment: .trailing)
    }

    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: Layout.copySpacing) {
            Label(statusEyebrow, systemImage: statusSystemImage)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(cleanupTint)

            Text(statusTitle)
                .font(AppDesignTokens.Typography.pageTitle)
                .fixedSize(horizontal: false, vertical: true)

            Text(statusDetail)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            statusPills

            cleanupActions
                .padding(.top, 6)
        }
        .layoutPriority(1)
    }

    private var statusPills: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                statusPillItems
            }

            VStack(alignment: .leading, spacing: 8) {
                statusPillItems
            }
        }
    }

    @ViewBuilder
    private var statusPillItems: some View {
        if let summary {
            SmartCareMetric(
                title: L10n.text("存储评分", "Storage Score"),
                value: "\(summary.entry.score)/100",
                systemImage: "gauge.with.dots.needle.67percent",
                tint: cleanupTint
            )
            SmartCareMetric(
                title: L10n.text("结果", "Result"),
                value: freshnessText(for: summary),
                systemImage: "clock",
                tint: cleanupTint
            )
            SmartCareMetric(
                title: L10n.text("扫描权限", "Access"),
                value: accessText(for: summary),
                systemImage: summary.entry.deniedCount == 0 ? "checkmark.shield.fill" : "lock.fill",
                tint: summary.entry.deniedCount == 0 ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning
            )
            if store.cleanupHistorySummary.totalCount > 0 {
                SmartCareMetric(
                    title: L10n.text("累计移到废纸篓", "Moved to Trash"),
                    value: ByteFormat.string(store.cleanupHistorySummary.totalBytes),
                    systemImage: "trash",
                    tint: AppDesignTokens.Palette.tertiary
                )
            }
        } else {
            SmartCareMetric(
                title: L10n.text("状态", "Status"),
                value: L10n.text("尚未扫描", "Not scanned"),
                systemImage: "play.circle.fill",
                tint: AppDesignTokens.Palette.information
            )
        }
    }

    private var cleanupActions: some View {
        HStack(spacing: 8) {
            if hasCleanableCandidates {
                Button {
                    performCleanupSecondaryAction()
                } label: {
                    Image(systemName: cleanupSecondaryActionIcon)
                        .frame(width: 18, height: 18)
                }
                .appButtonChrome(.secondary)
                .controlSize(.regular)
                .help(cleanupSecondaryActionTitle)
                .accessibilityLabel(cleanupSecondaryActionTitle)
            }

            Button {
                performCleanupPrimaryAction()
            } label: {
                Label(cleanupPrimaryActionTitle, systemImage: cleanupPrimaryActionIcon)
                    .frame(minWidth: 122)
            }
            .appButtonChrome(.primary)
            .controlSize(.regular)
            .tint(cleanupTint)
            .disabled(store.isPreparingScan)
        }
    }

    private var gaugeScore: Int? {
        summary?.entry.score
    }

    private var statusEyebrow: String {
        if hasCleanableCandidates {
            return L10n.text("可以开始清理", "Ready to clean")
        }
        if hasLiveResult {
            return L10n.text("本机状态", "Mac status")
        }
        return L10n.text("智能扫描", "Smart Scan")
    }

    private var statusTitle: String {
        guard let summary else {
            return L10n.text("从一次完整体检开始", "Start with a full scan")
        }
        if hasCleanableCandidates {
            return L10n.text("发现可安全清理的项目", "Safe cleanup is ready")
        }
        if hasLiveResult {
            return L10n.text("当前状态良好", "Your Mac looks good")
        }
        switch summary.attentionLevel {
        case .current:
            return L10n.text("上次扫描结果仍可参考", "Your last scan is still current")
        case .rescanRecommended:
            return L10n.text("建议重新扫描", "Run a fresh scan")
        case .permissionLimited:
            return L10n.text("完善权限后再体检", "Review access before scanning")
        }
    }

    private var statusDetail: String {
        guard let summary else {
            return L10n.text("扫描缓存、开发中间文件和可处理项目。", "Scan caches, development files, and actionable items.")
        }
        if hasCleanableCandidates {
            return L10n.text("先预览，再将可安全清理项目移到废纸篓。", "Review first, then move safe cleanup items to Trash.")
        }
        if hasLiveResult {
            return L10n.text("没有需要立即处理的可安全清理项目。", "No safe cleanup items need attention right now.")
        }
        let dateText = summary.entry.date.formatted(date: .abbreviated, time: .shortened)
        switch summary.attentionLevel {
        case .current:
            return L10n.text("扫描于 \(dateText)", "Scanned \(dateText)")
        case .rescanRecommended:
            return L10n.text("扫描于 \(dateText)", "Scanned \(dateText)")
        case .permissionLimited:
            return L10n.text("\(summary.entry.deniedCount) 个位置未读取", "\(summary.entry.deniedCount) unread locations")
        }
    }

    private var cleanupTint: Color {
        if hasCleanableCandidates { return AppDesignTokens.Palette.success
        }
        if hasLiveResult { return AppDesignTokens.Palette.information
        }
        switch summary?.attentionLevel {
        case .permissionLimited, .rescanRecommended:
            return AppDesignTokens.Palette.warning
        case .current, .none:
            return AppDesignTokens.Palette.tertiary
        }
    }

    private var statusSystemImage: String {
        if hasCleanableCandidates {
            return "sparkles"
        }
        if hasLiveResult {
            return "checkmark.seal.fill"
        }
        switch summary?.attentionLevel {
        case .permissionLimited:
            return "lock.trianglebadge.exclamationmark.fill"
        case .rescanRecommended:
            return "clock.arrow.circlepath"
        case .current:
            return "checkmark.seal.fill"
        case .none:
            return "play.fill"
        }
    }

    private var statusShouldElevate: Bool {
        hasCleanableCandidates || summary?.attentionLevel == .permissionLimited || summary?.attentionLevel == .rescanRecommended
    }

    private var statusProminence: GlassPanelProminence {
        statusShouldElevate ? .regular : .quiet
    }

    private var cleanupPrimaryActionTitle: String {
        if hasCleanableCandidates {
            return L10n.text("查看并清理", "Review and Clean")
        }
        if hasLiveResult {
            return L10n.text("再次扫描", "Scan Again")
        }
        return summary == nil ? L10n.text("开始扫描", "Start Scan") : L10n.text("重新扫描", "Rescan")
    }

    private var cleanupPrimaryActionIcon: String {
        if hasCleanableCandidates {
            return "sparkles"
        }
        if hasLiveResult {
            return "arrow.clockwise"
        }
        return summary == nil ? "play.fill" : "arrow.clockwise"
    }

    private var cleanupSecondaryActionTitle: String {
        L10n.text("查看可清理项目", "Review cleanable items")
    }

    private var cleanupSecondaryActionIcon: String {
        "list.bullet"
    }

    private func performCleanupPrimaryAction() {
        if hasCleanableCandidates {
            store.requestTrashAllGreen()
        } else {
            store.startScanRespectingAccessGuide()
        }
    }

    private func performCleanupSecondaryAction() {
        selection = .green
    }

    private func freshnessText(for status: LastScanStatusSummary) -> String {
        switch status.freshness.level {
        case .fresh:
            return L10n.text("2 小时内", "Under 2h")
        case .aging:
            return L10n.text("超过 2 小时", "Over 2h")
        case .stale:
            return L10n.text("超过 24 小时", "Over 24h")
        }
    }

    private func accessText(for status: LastScanStatusSummary) -> String {
        status.entry.deniedCount == 0
            ? L10n.text("权限完整", "Full access")
            : L10n.text("\(status.entry.deniedCount) 处受限", "\(status.entry.deniedCount) gaps")
    }

}

private struct ScanReadinessPanel: View {
    private enum Layout {
        static let rowSpacing: CGFloat = 16
        static let copySpacing: CGFloat = 6
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 10
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    let latestStatus: LastScanStatusSummary?
    @State private var isPermissionListExpanded = true

    private var summary: ScanReadinessSummary? {
        store.scanReadinessSummary
    }

    private var tint: Color {
        guard let summary else { return AppDesignTokens.Palette.information
        }
        if summary.isFullDiskAccessVerified {
            return summary.level == .ready ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.information
        }
        return summary.level == .ready ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning
    }

    private var displayText: ScanReadinessDisplayText {
        ScanReadinessService.displayText(
            summary: summary,
            lastDeniedCount: latestStatus?.entry.deniedCount,
            isChecking: store.isCheckingScanReadiness
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: Layout.rowSpacing) {
                readinessCopy
                Spacer(minLength: 12)
                globalReadinessActions
            }

            DisclosureGroup(isExpanded: $isPermissionListExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.text("系统权限开关由 macOS 管理；这里显示各文件夹当前是否能实际读取。", "macOS manages system permission switches; this list shows whether each folder is currently readable."))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)

                    ForEach(Array(permissionItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                        }
                        ScanReadinessPermissionRow(
                            title: item.location.title,
                            detail: item.location.path,
                            statusTitle: permissionStatusTitle(item),
                            systemImage: item.location.systemImage,
                            statusSystemImage: permissionStatusSystemImage(item),
                            tint: permissionStatusTint(item)
                        )
                    }
                }
                .padding(.top, 6)
            } label: {
                Label(L10n.text("打开权限列表", "Open Permission List"), systemImage: "list.bullet.rectangle")
                    .font(AppDesignTokens.Typography.metadata.weight(.semibold))
            }
            .animation(reduceMotion ? nil : AppMotionTokens.stateChange, value: isPermissionListExpanded)
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: tint,
            elevated: (summary?.folderAuthorizationRequiredCount ?? 0) > 0,
            prominence: (summary?.folderAuthorizationRequiredCount ?? 0) > 0 ? .regular : .quiet
        )
    }

    private var readinessCopy: some View {
        VStack(alignment: .leading, spacing: Layout.copySpacing) {
            Text(title)
                .font(AppDesignTokens.Typography.inlineTitle)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    private var globalReadinessActions: some View {
        HStack(spacing: 8) {
            checkAccessButton

            if shouldOfferFolderAccessGrant {
                Button {
                    store.requestRequiredFolderAccess()
                } label: {
                    Label(L10n.text("授权文件夹", "Allow Folders"), systemImage: "folder.badge.plus")
                        .frame(minWidth: 92)
                }
                .appButtonChrome(.secondary)
                .tint(AppDesignTokens.Palette.information)
                .controlSize(.regular)
            }

            Menu {
                Button {
                    CleanupService.openFullDiskAccessSettings()
                } label: {
                    Label(L10n.text("完整磁盘访问", "Full Disk Access"), systemImage: "externaldrive")
                }

                Button {
                    CleanupService.openFilesAndFoldersSettings()
                } label: {
                    Label(L10n.text("文件与文件夹", "Files & Folders"), systemImage: "folder")
                }
            } label: {
                Label(L10n.text("系统设置", "System Settings"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .frame(width: 124)
        }
        .controlSize(.regular)
        .font(AppDesignTokens.Typography.metadata)
    }

    private var shouldOfferFolderAccessGrant: Bool {
        summary?.isFullDiskAccessVerified != true
    }

    private var checkAccessButton: some View {
        Button {
            store.refreshScanReadiness()
        } label: {
            Label(
                store.isCheckingScanReadiness ? L10n.text("检查中", "Checking") : L10n.text("检查当前", "Check Current"),
                systemImage: store.isCheckingScanReadiness ? "arrow.clockwise" : "checklist"
            )
            .frame(minWidth: 74)
        }
        .appButtonChrome(.secondary)
        .tint(tint)
        .disabled(store.isCheckingScanReadiness)
        .controlSize(.regular)
    }

    private var permissionItems: [ScanReadinessItem] {
        summary?.items ?? ScanReadinessService.defaultLocations().map {
            ScanReadinessItem(location: $0, status: .missing)
        }
    }

    private func permissionStatusTitle(_ item: ScanReadinessItem) -> String {
        guard summary != nil else { return L10n.text("未检查", "Not Checked") }
        let hasSavedAccess = FolderAccessGrantService.hasSavedAccess(for: item.location.path)
        switch item.status {
        case .readable:
            if hasSavedAccess {
                return L10n.text("已保存授权", "Saved Access")
            }
            if summary?.isFullDiskAccessVerified == true {
                return L10n.text("完整磁盘访问覆盖", "Covered by Full Disk Access")
            }
            return L10n.text("可读", "Readable")
        case .needsPermission:
            if summary?.isFullDiskAccessVerified == true {
                return L10n.text("无需重复授权", "No Duplicate Grant Needed")
            }
            if hasSavedAccess {
                return L10n.text("授权需重选", "Rechoose Access")
            }
            return L10n.text("需要授权", "Needs Access")
        case .missing:
            return L10n.text("不存在", "Missing")
        }
    }

    private func permissionStatusSystemImage(_ item: ScanReadinessItem) -> String {
        guard summary != nil else { return "clock" }
        if summary?.isFullDiskAccessVerified == true, item.status != .missing {
            return item.status == .readable ? "checkmark.shield.fill" : "arrow.clockwise.circle.fill"
        }
        switch item.status {
        case .readable:
            return "checkmark.circle.fill"
        case .needsPermission:
            return "lock.fill"
        case .missing:
            return "minus.circle.fill"
        }
    }

    private func permissionStatusTint(_ item: ScanReadinessItem) -> Color {
        guard summary != nil else { return AppDesignTokens.Palette.information
        }
        if summary?.isFullDiskAccessVerified == true, item.status != .missing {
            return item.status == .readable ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.information
        }
        switch item.status {
        case .readable:
            return AppDesignTokens.Palette.success
        case .needsPermission:
            return AppDesignTokens.Palette.warning
        case .missing:
            return .secondary
        }
    }

    private func readinessSummaryPills(_ summary: ScanReadinessSummary) -> some View {
        HStack(spacing: 8) {
            MetadataPill(
                text: L10n.text("可读 \(summary.readableCount)", "\(summary.readableCount) readable"),
                systemImage: "checkmark.circle.fill",
                tint: AppDesignTokens.Palette.success
            )

            if summary.blockedCount > 0 {
                MetadataPill(
                    text: L10n.text("受限 \(summary.blockedCount)", "\(summary.blockedCount) blocked"),
                    systemImage: "lock.fill",
                    tint: AppDesignTokens.Palette.warning
                )
            }

            if summary.missingCount > 0 {
                MetadataPill(
                    text: L10n.text("跳过 \(summary.missingCount)", "\(summary.missingCount) skipped"),
                    systemImage: "minus.circle",
                    tint: .secondary
                )
            }
        }
    }

    private var title: String {
        displayText.title
    }

    private var detail: String {
        displayText.detail
    }
}

private struct ScanReadinessStatusRow: View {
    let summary: ScanReadinessSummary

    var body: some View {
        HStack(spacing: 7) {
            ForEach(summary.items.prefix(6)) { item in
                Image(systemName: item.location.systemImage)
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: statusSystemImage(for: item.status))
                            .font(AppDesignTokens.Typography.microSymbol)
                            .foregroundStyle(tint(for: item.status))
                            .frame(width: 10, height: 10)
                            .offset(x: 2, y: 1)
                    }
                    .help(helpText(for: item))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(helpText(for: item))
            }
        }
    }

    private func statusSystemImage(for status: ScanReadinessStatus) -> String {
        switch status {
        case .readable:
            "checkmark"
        case .needsPermission:
            "lock.fill"
        case .missing:
            "minus"
        }
    }

    private func tint(for status: ScanReadinessStatus) -> Color {
        switch status {
        case .readable:
            AppDesignTokens.Palette.success
        case .needsPermission:
            AppDesignTokens.Palette.warning
        case .missing:
            .secondary
        }
    }

    private func helpText(for item: ScanReadinessItem) -> String {
        switch item.status {
        case .readable:
            return L10n.text("\(item.location.title) 可读", "\(item.location.title) is readable")
        case .needsPermission:
            return L10n.text("\(item.location.title) 需要授权", "\(item.location.title) needs access")
        case .missing:
            return L10n.text("\(item.location.title) 不存在，已跳过", "\(item.location.title) is missing and skipped")
        }
    }
}

private struct ScanReadinessPermissionRow: View {
    let title: String
    let detail: String
    let statusTitle: String
    let systemImage: String
    let statusSystemImage: String
    let tint: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                content
                Spacer(minLength: 8)
                statusBadge
            }

            VStack(alignment: .leading, spacing: 8) {
                content
                statusBadge
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(AppDesignTokens.Typography.symbol)
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppDesignTokens.Typography.metadata.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .layoutPriority(1)
    }

    private var statusBadge: some View {
        MetadataPill(text: statusTitle, systemImage: statusSystemImage, tint: tint)
    }
}

private struct SmartCleanupFocusPanel: View {
    @ObservedObject var store: ScanStore
    @Binding var selection: ReviewFilter
    var showsActions = true
    var showsStatusLine = true

    private var candidates: [StorageItem] {
        store.greenTrashCandidates
    }

    private var liveCleanableBytes: Int64 {
        candidates.reduce(0) { $0 + $1.sizeBytes }
    }

    private var displayBytes: Int64 {
        if store.result != nil {
            return liveCleanableBytes
        }
        return store.scanHistorySummary.latest?.greenBytes ?? 0
    }

    private var displayCount: Int {
        if store.result != nil {
            return candidates.count
        }
        return store.scanHistorySummary.latest?.greenCount ?? 0
    }

    private var lastScanStatus: LastScanStatusSummary? {
        store.scanHistorySummary.latestStatus()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                metricColumn
                copyColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsActions {
                    actionButtons
                        .frame(width: 144, alignment: .trailing)
                }
            }

            if showsStatusLine {
                Divider()
                    .opacity(0.35)

                statusLine
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.heroRadius, tint: tint, elevated: shouldElevate, prominence: shouldElevate ? .regular : .quiet)
    }

    private var metricColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            CleanupAmountMetric(bytes: displayBytes, tint: tint, isHistorical: !hasLiveResult)

            Text(displayCount > 0 ? L10n.items(displayCount) : L10n.text("等待扫描", "Awaiting scan"))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 204, alignment: .leading)
    }

    private var copyColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(AppDesignTokens.Typography.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)

                MetadataPill(
                    text: statusPillText,
                    systemImage: statusPillIcon,
                    tint: tint
                )
            }

            Text(detail)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    private var statusLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                compactStatusLabels
            }

            VStack(alignment: .leading, spacing: 7) {
                compactStatusLabels
            }
        }
    }

    @ViewBuilder
    private var compactStatusLabels: some View {
        FocusInfoLabel(text: L10n.items(displayCount), systemImage: "checkmark.seal.fill", tint: AppDesignTokens.Palette.success)
        FocusInfoLabel(text: L10n.text("移到废纸篓 · 可恢复", "Trash only · Restorable"), systemImage: "trash.fill", tint: AppDesignTokens.Palette.information)
        if let lastScanStatus {
            FocusInfoLabel(
                text: lastScanStatus.entry.usesCurrentScoreModel
                    ? "\(lastScanStatus.entry.score)/100"
                    : L10n.text("\(lastScanStatus.entry.score)/100 · 旧标准", "\(lastScanStatus.entry.score)/100 · Legacy"),
                systemImage: "gauge.with.dots.needle.67percent",
                tint: tint
            )
            FocusInfoLabel(
                text: freshnessText(for: lastScanStatus),
                systemImage: "clock",
                tint: freshnessTint(for: lastScanStatus)
            )
            FocusInfoLabel(
                text: lastScanStatus.entry.deniedCount == 0 ? L10n.text("权限完整", "Full access") : L10n.text("\(lastScanStatus.entry.deniedCount) 处受限", "\(lastScanStatus.entry.deniedCount) gaps"),
                systemImage: lastScanStatus.entry.deniedCount == 0 ? "checkmark.shield.fill" : "lock.fill",
                tint: lastScanStatus.entry.deniedCount == 0 ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning
            )
        }
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .trailing, spacing: 8) {
                primaryButton
                    .frame(width: 144)
                if showsSecondaryButton {
                    secondaryButton
                        .frame(width: 144)
                }
            }

            HStack(spacing: 8) {
                primaryButton
                if showsSecondaryButton {
                    secondaryButton
                }
            }
        }
    }

    private var primaryButton: some View {
        Button {
            performPrimaryAction()
        } label: {
            Label(primaryActionTitle, systemImage: primaryActionIcon)
                .frame(maxWidth: .infinity)
        }
        .appButtonChrome(.primary)
        .controlSize(.large)
        .tint(tint)
    }

    private var secondaryButton: some View {
        Button {
            performSecondaryAction()
        } label: {
            Label(secondaryActionTitle, systemImage: secondaryActionIcon)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private var hasLiveResult: Bool {
        store.result != nil
    }

    private var hasCleanableCandidates: Bool {
        hasLiveResult && !candidates.isEmpty
    }

    private var showsSecondaryButton: Bool {
        !hasLiveResult || hasCleanableCandidates
    }

    private var title: String {
        if hasCleanableCandidates {
            return L10n.text("发现可安全清理项目", "Safe Cleanup Items Found")
        }
        if hasLiveResult {
            return L10n.text("当前没有可安全清理项", "No Safe Cleanup Items")
        }
        return L10n.text("上次发现可安全清理项", "Safe Cleanup Items From Last Scan")
    }

    private var detail: String {
        if hasCleanableCandidates {
            return L10n.text("\(displayCount) 个可安全清理项目", "\(displayCount) safe cleanup items")
        }
        if hasLiveResult {
            return L10n.text("没有可安全清理项目", "No safe cleanup items")
        }
        return L10n.text("历史记录", "History")
    }

    private var statusPillText: String {
        hasLiveResult ? L10n.text("当前结果", "Current") : L10n.text("历史记录", "History")
    }

    private var statusPillIcon: String {
        hasLiveResult ? "checkmark.circle.fill" : "clock.arrow.circlepath"
    }

    private var primaryActionTitle: String {
        if hasCleanableCandidates {
            return L10n.text("预览清理项目", "Preview Cleanup")
        }
        if hasLiveResult {
            return L10n.text("分析磁盘空间", "Analyze Disk Space")
        }
        return L10n.text("重新扫描", "Rescan")
    }

    private var primaryActionIcon: String {
        if hasCleanableCandidates {
            return "sparkles"
        }
        if hasLiveResult {
            return "doc.text.magnifyingglass"
        }
        return "arrow.clockwise"
    }

    private var secondaryActionTitle: String {
        if hasLiveResult {
            return L10n.text("查看绿色项", "Green Items")
        }
        return L10n.text("重新扫描", "Rescan")
    }

    private var secondaryActionIcon: String {
        hasLiveResult ? "checkmark.seal" : "arrow.clockwise"
    }

    private var tint: Color {
        if hasCleanableCandidates { return AppDesignTokens.Palette.success
        }
        if hasLiveResult { return AppDesignTokens.Palette.information
        }
        switch lastScanStatus?.attentionLevel {
        case .permissionLimited, .rescanRecommended:
            return AppDesignTokens.Palette.warning
        case .current, .none:
            return AppDesignTokens.Palette.tertiary
        }
    }

    private var shouldElevate: Bool {
        if hasCleanableCandidates { return true }
        if hasLiveResult { return false }
        return lastScanStatus?.attentionLevel != .current
    }

    private func freshnessText(for status: LastScanStatusSummary) -> String {
        switch status.freshness.level {
        case .fresh:
            return L10n.text("2 小时内", "Under 2h")
        case .aging:
            return L10n.text("超过 2 小时", "Over 2h")
        case .stale:
            return L10n.text("超过 24 小时", "Over 24h")
        }
    }

    private func freshnessTint(for status: LastScanStatusSummary) -> Color {
        switch status.freshness.level {
        case .fresh:
            return AppDesignTokens.Palette.success
        case .aging:
            return AppDesignTokens.Palette.warning
        case .stale:
            return AppDesignTokens.Palette.destructive
        }
    }

    private func performPrimaryAction() {
        if hasCleanableCandidates {
            store.requestTrashAllGreen()
        } else if hasLiveResult {
            selection = .largeFiles
        } else {
            store.startScanRespectingAccessGuide()
        }
    }

    private func performSecondaryAction() {
        if hasLiveResult {
            selection = .green
        } else {
            store.startScanRespectingAccessGuide()
        }
    }
}

private struct FocusInfoLabel: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(AppDesignTokens.Typography.metadata)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CleanupAmountMetric: View {
    let bytes: Int64
    let tint: Color
    let isHistorical: Bool

    private var progress: Double {
        guard bytes > 0 else { return 0.08 }
        let reference = 10_000_000_000.0
        return min(1, max(0.12, Double(bytes) / reference))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: isHistorical ? "clock.arrow.circlepath" : "trash")
                    .foregroundStyle(tint)

                Text(ByteFormat.string(bytes))
                    .font(AppDesignTokens.Typography.sectionTitle)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Text(isHistorical ? L10n.text("上次", "Last") : L10n.text("可清理", "Cleanable"))
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .tint(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isHistorical ? L10n.text("上次可清理空间", "Last cleanable space") : L10n.text("可清理空间", "Cleanable space"))
        .accessibilityValue(ByteFormat.string(bytes))
    }
}

private struct StatusToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppDesignTokens.Palette.success)
                .accessibilityHidden(true)
            Text(message)
        }
            .font(AppDesignTokens.Typography.secondary)
            .padding(.horizontal, AppDesignTokens.Layout.pageSpacing)
            .padding(.vertical, AppDesignTokens.Spacing.small)
            .glassCapsule(tint: AppDesignTokens.Palette.success, elevated: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
            .onChange(of: message, initial: true) { _, newMessage in
                AccessibilityNotification.Announcement(newMessage).post()
            }
    }
}

private struct CleanupSelectionGroup: Identifiable {
    let id: String
    let title: String
    let items: [StorageItem]

    var bytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }
}

private struct CleanupPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var store: ScanStore
    @State private var confirmedCloseRequirements = false
    @State private var selectedItemIDs = Set<String>()
    @State private var expandedGroupIDs = Set<String>()

    private var items: [StorageItem] {
        store.pendingBulkTrashItems
    }

    private var selectedItems: [StorageItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var totalBytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var groups: [CleanupSelectionGroup] {
        var order = [String]()
        var groupedItems = [String: [StorageItem]]()

        for item in items {
            let title = item.groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let groupTitle = title.isEmpty ? item.kind : title
            if groupedItems[groupTitle] == nil {
                order.append(groupTitle)
            }
            groupedItems[groupTitle, default: []].append(item)
        }

        return order.map { title in
            CleanupSelectionGroup(
                id: title,
                title: title,
                items: groupedItems[title, default: []]
            )
        }
    }

    private var closeRequirements: [String] {
        var seen = Set<String>()
        return selectedItems.compactMap { item in
            let value = item.requiresClose.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value != "无",
                  value.lowercased() != "none",
                  seen.insert(value).inserted else {
                return nil
            }
            return value
        }
    }

    private var canConfirmCleanup: Bool {
        store.canRequestGreenTrash
            && !selectedItemIDs.isEmpty
            && (closeRequirements.isEmpty || confirmedCloseRequirements)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: AppDesignTokens.Icon.sheetHeaderGlyph, weight: .semibold))
                    .foregroundStyle(AppDesignTokens.Palette.success)
                    .frame(width: 58, height: 58)
                    .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: AppDesignTokens.Palette.success)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("选择清理项目", "Choose Cleanup Items"))
                        .font(AppDesignTokens.Typography.sheetTitle)
                    Text(L10n.text("按分类检查并选择；确认后只会移入废纸篓", "Review and choose by category; confirmed items only move to Trash"))
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            selectionSummary

            if !closeRequirements.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        L10n.text(
                            "清理前先退出所选项目标注的应用和任务",
                            "Before cleanup, quit the apps and tasks listed below"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(AppDesignTokens.Palette.warning)

                    Toggle(
                        L10n.text("我已退出以上应用和任务", "I have quit the apps and tasks above"),
                        isOn: $confirmedCloseRequirements
                    )
                    .toggleStyle(.checkbox)
                }
                .padding(12)
                .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: AppDesignTokens.Palette.warning, prominence: .quiet)
            }

            ScrollView {
                LazyVStack(spacing: AppDesignTokens.Spacing.small) {
                    ForEach(groups) { group in
                        CleanupSelectionGroupView(
                            group: group,
                            selectedItemIDs: $selectedItemIDs,
                            isExpanded: expansionBinding(for: group.id)
                        )
                    }
                }
            }
            .frame(minHeight: 180, idealHeight: 260, maxHeight: .infinity)
            .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: AppDesignTokens.Palette.success, prominence: .quiet)

            HStack {
                Button {
                    store.cancelTrashAllGreenPreview()
                    dismiss()
                } label: {
                    Label(L10n.text("取消", "Cancel"), systemImage: "xmark")
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

                Spacer()

                if !items.isEmpty {
                    Button(role: .destructive) {
                        store.confirmTrashAllGreen(selectedItemIDs: selectedItemIDs)
                        dismiss()
                    } label: {
                        Label(
                            L10n.text(
                                "移入废纸篓 · \(ByteFormat.string(selectedBytes))",
                                "Move to Trash · \(ByteFormat.string(selectedBytes))"
                            ),
                            systemImage: "trash"
                        )
                    }
                    .appButtonChrome(.primary)
                    .controlSize(.large)
                    .disabled(!canConfirmCleanup)
                }
            }
        }
        .padding(AppDesignTokens.Layout.pagePadding)
        .frame(
            minWidth: 560,
            idealWidth: 660,
            maxWidth: 720,
            minHeight: 500,
            idealHeight: closeRequirements.isEmpty ? 560 : 630,
            maxHeight: 700,
            alignment: .topLeading
        )
        .background(ModuleBackground(theme: theme))
        .foregroundStyle(theme.primaryText)
        .onAppear {
            selectedItemIDs = Set(items.map(\.id))
            expandedGroupIDs = Set(groups.map(\.id))
        }
        .onChange(of: selectedItemIDs) { _, _ in
            confirmedCloseRequirements = false
        }
    }

    private var selectionSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppDesignTokens.Spacing.large) {
                CleanupSelectionRing(
                    selectedBytes: selectedBytes,
                    totalBytes: totalBytes,
                    selectedCount: selectedItemIDs.count
                )
                .frame(width: 150, height: 150)

                selectionSummaryCopy
            }

            VStack(spacing: AppDesignTokens.Spacing.medium) {
                CleanupSelectionRing(
                    selectedBytes: selectedBytes,
                    totalBytes: totalBytes,
                    selectedCount: selectedItemIDs.count
                )
                .frame(width: 150, height: 150)

                selectionSummaryCopy
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.success,
            prominence: .quiet
        )
    }

    private var selectionSummaryCopy: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Text(
                L10n.text(
                    "本页 \(items.count) 项可安全清理",
                    "\(L10n.items(items.count)) safe to clean on this page"
                )
            )
            .font(AppDesignTokens.Typography.sectionTitle)

            Text(
                L10n.text(
                    "当前选择 \(selectedItemIDs.count) 项，共 \(ByteFormat.string(selectedBytes))",
                    "\(L10n.items(selectedItemIDs.count)) selected, \(ByteFormat.string(selectedBytes))"
                )
            )
            .font(AppDesignTokens.Typography.body)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Button {
                toggleAllSelection()
            } label: {
                Label(
                    selectedItemIDs.count == items.count
                        ? L10n.text("取消全选", "Deselect All")
                        : L10n.text("全选可安全项", "Select All Safe Items"),
                    systemImage: selectedItemIDs.count == items.count
                        ? "square"
                        : "checkmark.square"
                )
            }
            .appButtonChrome(.secondary)
            .controlSize(.regular)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func toggleAllSelection() {
        if selectedItemIDs.count == items.count {
            selectedItemIDs.removeAll()
        } else {
            selectedItemIDs = Set(items.map(\.id))
        }
        confirmedCloseRequirements = false
    }

    private func expansionBinding(for groupID: String) -> Binding<Bool> {
        Binding {
            expandedGroupIDs.contains(groupID)
        } set: { isExpanded in
            if isExpanded {
                expandedGroupIDs.insert(groupID)
            } else {
                expandedGroupIDs.remove(groupID)
            }
        }
    }
}

private struct CleanupSelectionRing: View {
    let selectedBytes: Int64
    let totalBytes: Int64
    let selectedCount: Int

    private var fraction: CGFloat {
        guard totalBytes > 0 else { return 0 }
        return CGFloat(min(1, max(0, Double(selectedBytes) / Double(totalBytes))))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppDesignTokens.Palette.success.opacity(0.14), lineWidth: 13)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AppDesignTokens.Palette.success.gradient,
                    style: StrokeStyle(lineWidth: 11, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: AppDesignTokens.Spacing.compact) {
                Text(L10n.text("已选择", "Selected"))
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)

                Text(ByteFormat.string(selectedBytes))
                    .font(AppDesignTokens.Typography.metricValue)
                    .monospacedDigit()

                Text(L10n.items(selectedCount))
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("已选择清理项目", "Selected cleanup items"))
        .accessibilityValue(
            L10n.text(
                "\(selectedCount) 项，\(ByteFormat.string(selectedBytes))",
                "\(L10n.items(selectedCount)), \(ByteFormat.string(selectedBytes))"
            )
        )
    }
}

private struct CleanupSelectionGroupView: View {
    let group: CleanupSelectionGroup
    @Binding var selectedItemIDs: Set<String>
    @Binding var isExpanded: Bool

    private var selectedCount: Int {
        group.items.filter { selectedItemIDs.contains($0.id) }.count
    }

    private var selectionSystemImage: String {
        if selectedCount == group.items.count {
            return "checkmark.square.fill"
        }
        if selectedCount == 0 {
            return "square"
        }
        return "minus.square.fill"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 0) {
                Divider()

                ForEach(group.items) { item in
                    CleanupPreviewRow(
                        item: item,
                        isSelected: Binding {
                            selectedItemIDs.contains(item.id)
                        } set: { isSelected in
                            if isSelected {
                                selectedItemIDs.insert(item.id)
                            } else {
                                selectedItemIDs.remove(item.id)
                            }
                        }
                    )

                    if item.id != group.items.last?.id {
                        Divider()
                            .padding(.leading, 46)
                    }
                }
            }
        } label: {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Button {
                    toggleGroupSelection()
                } label: {
                    Image(systemName: selectionSystemImage)
                        .font(AppDesignTokens.Typography.sectionTitle)
                        .foregroundStyle(AppDesignTokens.Palette.success)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .accessibilityLabel(groupSelectionAccessibilityLabel)

                VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textTightSpacing) {
                    Text(group.title)
                        .font(AppDesignTokens.Typography.compactLabelEmphasis)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        L10n.text(
                            "\(selectedCount)/\(group.items.count) 项已选择",
                            "\(selectedCount) of \(group.items.count) selected"
                        )
                    )
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                Spacer(minLength: 8)

                Text(ByteFormat.string(group.bytes))
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 12)
        .glassPanel(
            cornerRadius: AppDesignTokens.Radius.settingsPanel,
            tint: AppDesignTokens.Palette.success,
            prominence: .quiet
        )
    }

    private var groupSelectionAccessibilityLabel: String {
        selectedCount == group.items.count
            ? L10n.text("取消选择 \(group.title)", "Deselect \(group.title)")
            : L10n.text("选择 \(group.title)", "Select \(group.title)")
    }

    private func toggleGroupSelection() {
        let groupIDs = Set(group.items.map(\.id))
        if selectedCount == group.items.count {
            selectedItemIDs.subtract(groupIDs)
        } else {
            selectedItemIDs.formUnion(groupIDs)
        }
    }
}

private struct CleanupPreviewRow: View {
    let item: StorageItem
    @Binding var isSelected: Bool

    private var meaningfulCloseRequirement: String? {
        let value = item.requiresClose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "无", value.lowercased() != "none" else { return nil }
        return value
    }

    var body: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(
                    L10n.text(
                        "\(isSelected ? "取消选择" : "选择") \(item.title)",
                        "\(isSelected ? "Deselect" : "Select") \(item.title)"
                    )
                )

            VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textTightSpacing) {
                Text(item.title)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.path)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let meaningfulCloseRequirement {
                    Label(
                        L10n.text("先退出：\(meaningfulCloseRequirement)", "Quit first: \(meaningfulCloseRequirement)"),
                        systemImage: "power"
                    )
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Text(ByteFormat.string(item.sizeBytes))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}
