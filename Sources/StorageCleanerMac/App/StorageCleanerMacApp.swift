import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var prepareBenchmarkForTermination: (@MainActor () async -> Void)?
    var requestBenchmarkCancellation: (@MainActor () -> Void)?
    var prepareApplicationUpdatesForTermination: (@MainActor () async -> Void)?
    var requestApplicationUpdateCancellation: (@MainActor () -> Void)?
    var prepareStartupItemsForTermination: (@MainActor () async -> Void)?
    var requestStartupItemCancellation: (@MainActor () -> Void)?
    var prepareMemoryOptimizationForTermination: (@MainActor () async -> Void)?
    var requestMemoryOptimizationCancellation: (@MainActor () -> Void)?
    var prepareMetricHistoryForTermination: (@MainActor () async -> Void)?
    var prepareFanControlForTermination: (@MainActor () async -> Void)?
    var terminationTimeout: Duration = .seconds(3)
    var replyToApplicationShouldTerminate:
        (@MainActor (NSApplication) -> Void)?

    private var terminationReplySent = false
    private var terminationCleanupTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private var appAppearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Login-item registration is managed separately with SMAppService.
        // Never let macOS Session Restore relaunch an app that was merely left
        // open when the user shut down or logged out.
        NSApp.disableRelaunchOnLogin()
        NSApp.setActivationPolicy(.regular)
        Task.detached(priority: .utility) {
            SQLiteSnapshotService().cleanupOrphans()
        }
        MainMenuLocalizer.scheduleApply()
        appAppearanceObservation = NSApp.observe(
            \.effectiveAppearance,
            options: [.initial, .new]
        ) { _, _ in
            Task { @MainActor in
                let colorScheme: ColorScheme = NSApp.effectiveAppearance.bestMatch(
                    from: [.darkAqua, .aqua]
                ) == .darkAqua ? .dark : .light
                AppArtwork.applyDockIcon(for: colorScheme)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard prepareBenchmarkForTermination != nil
                || prepareApplicationUpdatesForTermination != nil
                || prepareStartupItemsForTermination != nil
                || prepareMemoryOptimizationForTermination != nil
                || prepareMetricHistoryForTermination != nil
                || prepareFanControlForTermination != nil else {
            return .terminateNow
        }
        guard terminationCleanupTask == nil else { return .terminateLater }

        terminationReplySent = false
        terminationCleanupTask = Task { @MainActor [weak self, weak sender] in
            if let prepareBenchmarkForTermination = self?.prepareBenchmarkForTermination {
                await prepareBenchmarkForTermination()
            }
            if let prepareApplicationUpdatesForTermination = self?.prepareApplicationUpdatesForTermination {
                await prepareApplicationUpdatesForTermination()
            }
            if let prepareStartupItemsForTermination = self?.prepareStartupItemsForTermination {
                await prepareStartupItemsForTermination()
            }
            if let prepareMemoryOptimizationForTermination = self?.prepareMemoryOptimizationForTermination {
                await prepareMemoryOptimizationForTermination()
            }
            if let prepareMetricHistoryForTermination = self?.prepareMetricHistoryForTermination {
                await prepareMetricHistoryForTermination()
            }
            if let prepareFanControlForTermination = self?.prepareFanControlForTermination {
                await prepareFanControlForTermination()
            }
            guard let self, let sender else { return }
            finishDeferredTermination(sender)
        }
        // A non-responsive hardware driver must not trap the whole app in its
        // termination handshake. The preparation closure waits for both the
        // Store task and the coordinator's cleanup quarantine.
        terminationTimeoutTask = Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            try? await Task.sleep(for: self.terminationTimeout)
            guard !Task.isCancelled, let sender else { return }
            finishDeferredTermination(sender)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Covers forceful or system-driven termination paths that bypassed the
        // deferred reply above. Cancellation is idempotent.
        requestBenchmarkCancellation?()
        requestApplicationUpdateCancellation?()
        requestStartupItemCancellation?()
        requestMemoryOptimizationCancellation?()
        FanControlCoordinator.shared.disconnectForTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        // WindowGroup restores its default value for Dock/reopen events. Do
        // not also call openWindow here or SwiftUI creates a second main window.
        return true
    }

    private func finishDeferredTermination(_ sender: NSApplication) {
        guard !terminationReplySent else { return }
        terminationReplySent = true
        terminationCleanupTask?.cancel()
        terminationTimeoutTask?.cancel()
        terminationCleanupTask = nil
        terminationTimeoutTask = nil
        if let replyToApplicationShouldTerminate {
            replyToApplicationShouldTerminate(sender)
        } else {
            sender.reply(toApplicationShouldTerminate: true)
        }
    }
}

extension Notification.Name {
    static let storageCleanerShowMainWindow = Notification.Name("StorageCleanerMac.showMainWindow")
    static let storageCleanerFocusStartupItemsSearch = Notification.Name("StorageCleanerMac.focusStartupItemsSearch")
}

@MainActor
final class MainWindowReopenCoordinator {
    static let shared = MainWindowReopenCoordinator()

    var openMainWindow: (() -> Void)?

    private init() {}

    func requestMainWindow() {
        if let openMainWindow {
            openMainWindow()
        } else {
            NotificationCenter.default.post(name: .storageCleanerShowMainWindow, object: nil)
        }
    }
}

struct MainWindowSidebarAction {
    let perform: @MainActor () -> Void

    @MainActor
    func callAsFunction() {
        perform()
    }
}

private struct MainWindowSidebarActionKey: FocusedValueKey {
    typealias Value = MainWindowSidebarAction
}

extension FocusedValues {
    var mainWindowSidebarAction: MainWindowSidebarAction? {
        get { self[MainWindowSidebarActionKey.self] }
        set { self[MainWindowSidebarActionKey.self] = newValue }
    }
}

private struct MainWindowSidebarCommands: Commands {
    @FocusedValue(\.mainWindowSidebarAction) private var sidebarAction

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(L10n.text("显示或隐藏边栏", "Toggle Sidebar")) {
                sidebarAction?()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(sidebarAction == nil)
        }
    }
}

/// Reads the window-scoped startup console actions at command evaluation time,
/// so the shared Command-R shortcut does not fall through to a storage scan.
private struct MainScanCommands: Commands {
    let store: ScanStore
    @FocusedValue(\.startupItemsKeyboardActions) private var startupItemsKeyboardActions

    var body: some Commands {
        CommandMenu(L10n.text("扫描", "Scan")) {
            Button(startupItemsKeyboardActions == nil
                ? scanCommandTitle
                : L10n.text("重新扫描登录项与后台任务", "Rescan Login Items & Background Tasks")) {
                if let startupItemsKeyboardActions {
                    startupItemsKeyboardActions.refresh()
                } else {
                    store.startScanRespectingAccessGuide()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(startupItemsKeyboardActions == nil && store.isPreparingScan)

            if store.canRequestGreenTrash {
                Button(L10n.text("预览安全清理项目", "Preview Safe Cleanup")) {
                    store.requestTrashAllGreen()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            Button(L10n.text("清空废纸篓", "Empty Trash")) {
                store.showFilter(.green)
                store.requestEmptyTrash()
            }
            .disabled(!store.canRequestEmptyTrash)

            if store.result != nil {
                Button(L10n.text("导出扫描报告", "Export Scan Report")) {
                    store.exportReport()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!store.canExportCurrentScanArtifacts)
            }

            if store.result != nil {
                Button(L10n.text("导出维护清单", "Export Maintenance Checklist")) {
                    store.exportCurrentMaintenanceChecklist()
                }
                .disabled(!store.canExportCurrentScanArtifacts)
            }
        }

        CommandGroup(after: .textEditing) {
            Button(L10n.text("搜索登录项与后台任务", "Search Login Items & Background Tasks")) {
                startupItemsKeyboardActions?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(startupItemsKeyboardActions == nil)
        }
    }

    private var scanCommandTitle: String {
        store.scanActionTitle(
            normalTitle: store.result == nil ? L10n.text("开始扫描", "Start Scan") : L10n.text("重新扫描", "Rescan")
        )
    }
}

@main
struct StorageCleanerMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let heavyWorkCoordinator: HeavyWorkCoordinator
    @StateObject private var heavyWorkActivityStore: HeavyWorkActivityStore
    @StateObject private var store: ScanStore
    @StateObject private var computerHealthStore: ComputerHealthStore
    @StateObject private var networkSpeedTestStore: NetworkSpeedTestStore
    @StateObject private var browserPrivacyStore: BrowserPrivacyStore
    @StateObject private var macBenchmarkStore: MacBenchmarkStore
    @StateObject private var macBenchmarkLeaderboardStore: BenchmarkV7LeaderboardStore
    @StateObject private var updater = AppUpdater.shared
    @StateObject private var menuBarStatusController = MenuBarStatusController.shared
    @StateObject private var installationConflictController = AppInstallationConflictController()
    @AppStorage(L10n.languageDefaultsKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(L10n.appearanceDefaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue

    init() {
        Self.terminateIfDuplicateInstance()
        let coordinator = HeavyWorkCoordinator()
        let activityStore = HeavyWorkActivityStore(coordinator: coordinator)
        heavyWorkCoordinator = coordinator
        _heavyWorkActivityStore = StateObject(wrappedValue: activityStore)
        let scanStore = ScanStore(
            heavyWorkCoordinator: coordinator,
            heavyWorkActivityStore: activityStore,
            metricHistoryStore: MetricHistoryStore.live(),
            cleanupFeatureConfiguration: .productDefault
        )
#if DEBUG || STORAGE_CLEANER_BETA
        if let scenario = MiniWindowDemoData.capturedMenuBarPanelScenario(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            MiniWindowDemoData.configure(store: scanStore, for: scenario)
        }
#endif
        _store = StateObject(wrappedValue: scanStore)
#if DEBUG || STORAGE_CLEANER_BETA
        let healthStore = MiniWindowDemoData.isEnabled
            ? ComputerHealthStore(probe: GoldenUnmeasuredHealthProbe())
            : ComputerHealthStore()
#else
        let healthStore = ComputerHealthStore()
#endif
        _computerHealthStore = StateObject(wrappedValue: healthStore)
        _networkSpeedTestStore = StateObject(wrappedValue: NetworkSpeedTestStore(
            heavyWorkCoordinator: coordinator,
            heavyWorkActivityStore: activityStore,
            resultRepository: NetworkSpeedTestResultRepository(),
            onSuccessfulResult: { result in
                healthStore.recordNetworkSpeedResult(result)
            }
        ))
#if DEBUG || STORAGE_CLEANER_BETA
        _browserPrivacyStore = StateObject(wrappedValue:
            BrowserPrivacyPreviewFixture.isRequested
                ? BrowserPrivacyPreviewFixture.makeStore()
                : BrowserPrivacyStore()
        )
#else
        _browserPrivacyStore = StateObject(wrappedValue: BrowserPrivacyStore())
#endif
        let benchmarkCatalog = MacBenchmarkProductionBaselineCatalog.runtimeCatalog()
        let benchmarkProcessor = MacBenchmarkResultProcessor(
            baselineCatalog: benchmarkCatalog
        )
        let benchmarkService = MacBenchmarkService(heavyWorkCoordinator: coordinator)
        let sustainedBenchmarkService = MacSustainedBenchmarkService(
            heavyWorkCoordinator: coordinator,
            workloadRunner: SystemMacSustainedBenchmarkWorkloadRunner()
        )
        let benchmarkV7Coordinator = BenchmarkV7Coordinator(
            workloadRunner: SystemBenchmarkV7WorkloadRunner(),
            heavyWorkCoordinator: coordinator,
            sustainedService: sustainedBenchmarkService
        )
        let benchmarkLeaderboardStore = BenchmarkV7LeaderboardStore()
        _macBenchmarkLeaderboardStore = StateObject(
            wrappedValue: benchmarkLeaderboardStore
        )
        _macBenchmarkStore = StateObject(wrappedValue: MacBenchmarkStore(
            service: benchmarkService,
            resultProcessor: benchmarkProcessor,
            historyRepository: MacBenchmarkHistoryRepository(
                trustedResultProcessors: [benchmarkProcessor]
                    + MacBenchmarkProductionBaselineCatalog
                        .trustedHistoryResultProcessors()
            ),
            acceleratorService: MacAcceleratorBenchmarkService(
                heavyWorkCoordinator: coordinator,
                workloadRunner: SystemMacAcceleratorWorkloadRunner()
            ),
            acceleratorHistoryRepository:
                MacAcceleratorBenchmarkHistoryRepository(),
            sustainedService: sustainedBenchmarkService,
            v7Coordinator: benchmarkV7Coordinator
        ))
#if DEBUG || STORAGE_CLEANER_BETA
        // SwiftUI can defer the only Window scene on a fresh menu-bar launch.
        // Keep fixture screenshots on the existing panel path without changing
        // normal Debug or Release startup behavior.
        if (MiniWindowDemoData.isEnabled
            && ProcessInfo.processInfo.arguments.contains("--open-menu-bar-panel"))
            || MiniWindowDemoData.isCapturingMenuBarPanelSnapshots {
            Task { @MainActor in
                MenuBarStatusController.shared.install(
                    store: scanStore,
                    computerHealthStore: healthStore
                )
            }
        }
        // Reaching the advanced-control authorization path normally needs
        // pointer interaction inside the panel. This seam runs the same
        // coordinator entry point so the registration result can be verified
        // from a log during development.
        if ProcessInfo.processInfo.arguments.contains(
            HardwareControlDiagnostics.launchArgument
        ) {
            Task { @MainActor in
                await HardwareControlDiagnostics.runRegistrationProbe()
            }
        }
        if ProcessInfo.processInfo.arguments.contains(
            HardwareControlDiagnostics.writesLaunchArgument
        ) {
            Task { @MainActor in
                await HardwareControlDiagnostics.runWritesProbe()
            }
        }
        if ProcessInfo.processInfo.arguments.contains(
            HardwareControlDiagnostics.maxHoldLaunchArgument
        ) {
            Task { @MainActor in
                await HardwareControlDiagnostics.runMaxHoldProbe()
            }
        }
#endif
        L10n.applyAppKitLanguagePreference()
        let rawAppearance = UserDefaults.standard.string(forKey: L10n.appearanceDefaultsKey)
        (AppAppearance(rawValue: rawAppearance ?? AppAppearance.system.rawValue) ?? .system)
            .applyAppKitPreference()
    }

    /// Two GUI instances of this app fight over the single privileged fan
    /// helper: connection churn makes the helper restore automatic control
    /// (its designed fail-safe), which silently erases the other instance's
    /// manual fan targets until the feedback watchdog reverts the mode.
    /// A second instance therefore yields to the first before any stores,
    /// monitors, or helper connections are created.
    private static func terminateIfDuplicateInstance() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let peers = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard !peers.isEmpty else { return }
        // When two instances race at startup, only the newer one exits.
        let currentLaunchDate = NSRunningApplication.current.launchDate ?? Date()
        let hasEarlierPeer = peers.contains { peer in
            guard let peerLaunchDate = peer.launchDate else { return true }
            if peerLaunchDate == currentLaunchDate {
                return peer.processIdentifier < currentPID
            }
            return peerLaunchDate < currentLaunchDate
        }
        guard hasEarlierPeer else { return }
        peers.first?.activate()
        exit(0)
    }

    var body: some Scene {
        // The visible title is rendered by IntegratedTitlebar inside the themed shell.
        WindowGroup("", id: "main", for: String.self) { _ in
            MainWindowReopenBridge {
                ContentView(
                    store: store,
                    computerHealthStore: computerHealthStore,
                    networkSpeedTestStore: networkSpeedTestStore,
                    macBenchmarkStore: macBenchmarkStore,
                    macBenchmarkLeaderboardStore: macBenchmarkLeaderboardStore,
                    heavyWorkActivityStore: heavyWorkActivityStore,
                    browserPrivacyStore: browserPrivacyStore
                )
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let conflict = installationConflictController.conflict {
                            AppInstallationConflictBanner(
                                conflict: conflict,
                                revealCopies: installationConflictController.revealCopies,
                                dismiss: installationConflictController.dismiss
                            )
                        }
                    }
            }
                .id(languageRawValue)
                .environment(\.locale, L10n.locale)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    [weak benchmarkStore = macBenchmarkStore,
                     store = store,
                     coordinator = heavyWorkCoordinator] in
                    appDelegate.requestBenchmarkCancellation = { [weak benchmarkStore] in
                        benchmarkStore?.cancelAll()
                    }
                    appDelegate.requestApplicationUpdateCancellation = { [weak store] in
                        store?.requestApplicationUpdateCancellation()
                    }
                    appDelegate.requestStartupItemCancellation = { [weak store] in
                        store?.requestStartupItemCancellation()
                    }
                    appDelegate.requestMemoryOptimizationCancellation = { [weak store] in
                        store?.cancelMemoryOptimization()
                    }
                    appDelegate.prepareBenchmarkForTermination = { [weak benchmarkStore] in
                        guard let benchmarkStore else { return }
                        benchmarkStore.cancelAll()
                        await benchmarkStore.waitUntilIdle()
                        _ = await coordinator.waitUntilOwnerInactive(.benchmark)
                    }
                    appDelegate.prepareApplicationUpdatesForTermination = { [weak store] in
                        await store?.prepareApplicationUpdatesForTermination()
                    }
                    appDelegate.prepareStartupItemsForTermination = { [weak store] in
                        await store?.prepareStartupItemsForTermination()
                    }
                    appDelegate.prepareMemoryOptimizationForTermination = { [weak store] in
                        await store?.prepareMemoryOptimizationForTermination()
                    }
                    appDelegate.prepareMetricHistoryForTermination = { [weak store] in
                        await store?.flushMenuBarMetricHistory()
                        await store?.stopAndFlushSystemEnergyMonitoring()
                    }
                    appDelegate.prepareFanControlForTermination = {
                        await FanControlCoordinator.shared.prepareForTermination()
                    }
                    localizeMainMenu()
                    menuBarStatusController.install(
                        store: store,
                        computerHealthStore: computerHealthStore
                    )
                    store.prepareMenuBarLiveStatusOnLaunch()
                    Task {
#if DEBUG || STORAGE_CLEANER_BETA
                        // Isolated visual sessions start unmeasured, without restoring live health history.
                        if !MiniWindowDemoData.isEnabled {
                            await computerHealthStore.prepareMenuBarHealthOnLaunch()
                        }
#else
                        await computerHealthStore.prepareMenuBarHealthOnLaunch()
#endif
                    }
                    store.startSystemEnergyMonitoring()
                    store.prepareApplicationUpdatesOnLaunch()
                    Task {
                        await benchmarkStore?.prepareLifecycleOnLaunch()
                        await installationConflictController.checkIfNeeded()
                    }
                }
                .onChange(of: languageRawValue) { _, _ in
                    localizeMainMenu()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    Task {
                        await computerHealthStore.verifyBatterySettingsAfterReturn()
                    }
                    store.prepareApplicationUpdatesOnLaunch()
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didTerminateApplicationNotification
                )) { notification in
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication else { return }
                    store.applicationDidTerminateForUpdates(
                        bundleIdentifier: application.bundleIdentifier,
                        bundleURL: application.bundleURL
                    )
                }
        } defaultValue: {
            "primary"
        }
        .defaultSize(width: 1280, height: 764)
        .commands {
            MainWindowSidebarCommands()
            MainScanCommands(store: store)

            CommandGroup(replacing: .newItem) {
                Button(L10n.text("显示主窗口", "Show Main Window")) {
                    MainWindowReopenCoordinator.shared.requestMainWindow()
                }
            }

            CommandGroup(after: .windowSize) {
                Button(L10n.text("标准窗口大小", "Standard Window Size")) {
                    guard let window = NSApp.windows.first(where: {
                        $0.identifier?.rawValue.hasPrefix("main-") == true
                    }), let screen = window.screen else { return }
                    let size = AppWindowLayoutPolicy.fittedContentSize(NSSize(width: 1280, height: 764), in: screen.visibleFrame)
                    window.setContentSize(size)
                    window.center()
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            }

            CommandMenu(L10n.text("导航", "Navigate")) {
                Button(ReviewFilter.overview.title) {
                    store.showFilter(.overview)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button(ReviewFilter.healthHub.title) {
                    store.showFilter(.healthHub)
                }

                Button(ReviewFilter.performance.title) {
                    store.showFilter(.performance)
                }

                Divider()

                Button(ReviewFilter.green.title) {
                    store.showFilter(.green)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button(ReviewFilter.privacy.title) {
                    store.showFilter(.privacy)
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button(ReviewFilter.devCaches.title) {
                    store.showFilter(.devCaches)
                }
                .keyboardShortcut("4", modifiers: [.command])

                Button(ReviewFilter.largeFiles.title) {
                    store.showFilter(.largeFiles)
                }
                .keyboardShortcut("5", modifiers: [.command])

                Button(ReviewFilter.migration.title) {
                    store.showFilter(.migration)
                }

                Button(ReviewFilter.duplicates.title) {
                    store.showFilter(.duplicates)
                }
                .keyboardShortcut("6", modifiers: [.command])
            }

            CommandMenu(L10n.text("工具", "Tools")) {
                Button(L10n.text("检查权限", "Check Permissions")) {
                    store.checkCurrentPermissionsFromMenu()
                }
                .disabled(store.isCheckingScanReadiness)

                Button(L10n.text("检查存储清理助手更新", "Check Storage Cleaner Updates")) {
                    updater.checkForUpdates()
                }
            }

            CommandMenu(L10n.text("语言", "Language")) {
                Picker(L10n.text("操作语言", "Interface Language"), selection: $languageRawValue) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language.rawValue)
                    }
                }
            }
        }

        Settings {
            SettingsView(cleanupArchitectureMode: store.cleanupFeatureConfiguration.mode, scanStore: store)
                .id(languageRawValue)
                .environment(\.locale, L10n.locale)
                .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch AppAppearance(rawValue: appearanceRawValue) ?? .system {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private func localizeMainMenu() {
        let language = AppLanguage(rawValue: languageRawValue) ?? .system
        L10n.applyAppKitLanguagePreference()
        MainMenuLocalizer.scheduleApply(language: language)
    }
}

private struct MainWindowReopenBridge<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .onAppear {
                MainWindowReopenCoordinator.shared.openMainWindow = {
                    openWindow(id: "main", value: "primary")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .storageCleanerShowMainWindow)) { _ in
                openWindow(id: "main", value: "primary")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

#if DEBUG || STORAGE_CLEANER_BETA
private struct GoldenUnmeasuredHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}
#endif
