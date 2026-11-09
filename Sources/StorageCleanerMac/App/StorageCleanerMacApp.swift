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
    var startupApplicationUpdateScheduler = StartupApplicationUpdateScheduler.shared
    var terminationTimeout: Duration = .seconds(3)
    var replyToApplicationShouldTerminate:
        (@MainActor (NSApplication) -> Void)?
    /// D256: a user's quit closes only the main program while the panel stays.
    var quitDecision: @MainActor () -> AppQuitDecision = {
        // Configured only once a status item exists (AppLaunchWork): without a
        // panel to keep (unit tests, acceptance) nothing else is read.
        guard MenuBarOnlyMode.shared.isConfigured,
              AppQuitPreferences.keepsMenuBarPanelAfterQuit() else { return .terminate }
        return AppQuitPolicy.decision(
            reason: AppQuitIntent.shared.reason(
                currentEvent: NSAppleEventManager.shared().currentAppleEvent,
                isInstallingUpdate: AppUpdater.shared.isInstallingUpdate),
            // D270: a status item the system has not placed in a menu bar
            // (hidden in System Settings) leaves no panel to keep.
            keepsMenuBarPanel: true, hasMenuBarPanel: MenuBarStatusController.shared.isShowingStatusItem)
    }
    var enterMenuBarOnly: @MainActor () -> Void = { MenuBarOnlyMode.shared.enter() }

    private var terminationReplySent = false
    private var terminationCleanupTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private var appAppearanceObservation: NSKeyValueObservation?

    /// D88: the Finder extension opens the selected `.app` files with this
    /// exact application (an open-documents event; there is no URL scheme).
    /// On a cold launch this can arrive before the main window exists: the
    /// request center queues it and presents the window once it attaches.
    /// Dragging an app onto the Dock icon or "Open With" lands here too and
    /// only opens the review.
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalUninstallRequestCenter.shared.receive(openedURLs: urls)
        // D257: the event opens its own main window; the main program comes
        // back around it without asking for a second one.
        MenuBarOnlyMode.shared.leaveWithoutOpeningWindow()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppLaunchCoordinator.shared.register(delegate: self)
        // D258: a login item's launch starts with the panel alone, and so
        // does (D271) the relaunch after an update installed from that state.
        let isLoginLaunch = AppLaunchKind.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)
        let isRelaunchAfterUpdate = MenuBarOnlyRelaunch.consume(
            currentBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        if AppQuitPreferences.keepsMenuBarPanelAfterQuit(),
           isLoginLaunch || isRelaunchAfterUpdate || MenuBarOnlyMode.isLoginLaunchRehearsalRequested {
            MenuBarOnlyMode.shared.beginAtLaunch()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Login-item registration is managed separately with SMAppService.
        // Never let macOS Session Restore relaunch an app that was merely left
        // open when the user shut down or logged out.
        NSApp.disableRelaunchOnLogin()
        let isMenuBarOnly = MenuBarOnlyMode.shared.isActive
#if DEBUG || STORAGE_CLEANER_BETA
        // An isolated latency-script launch stays out of the way: no Dock
        // icon, no activation, no main window.
        let isLatencyScript = MenuBarLatencyScript.isRequested
        NSApp.setActivationPolicy(isLatencyScript || isMenuBarOnly ? .accessory : .regular)
#else
        NSApp.setActivationPolicy(isMenuBarOnly ? .accessory : .regular)
#endif
        // D106: an acceptance session deletes nothing on its own; the next
        // normal launch removes what has expired by then.
        if !AcceptanceLaunch.isActive {
            Task.detached(priority: .utility) {
                SQLiteSnapshotService().cleanupOrphans()
            }
            BrowserPrivacyRecoveryMaintenance.enableAndPurge()
        }
        // BOARD N19: memory quit suggestions skip the app the user works in,
        // which is the one in front before this app's own window is used.
        UserFrontmostApplicationTracker.shared.start()
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
        AppQuitIntent.shared.startObservingSession()
        // D255: the panel and the termination work do not wait for a window.
        AppLaunchCoordinator.shared.start(delegate: self)
#if DEBUG || STORAGE_CLEANER_BETA
        guard !isLatencyScript else { return }
#endif
        // D258: a login launch does not come forward.
        guard !isMenuBarOnly else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // D256: none of the termination work runs; fan control and live
        // monitoring go on for the panel (D257).
        if quitDecision() == .keepMenuBarPanel {
            enterMenuBarOnly()
            return .terminateCancel
        }
        startupApplicationUpdateScheduler.cancelForTermination()
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
            await self?.prepareForTermination()
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

    /// Shared by the real exit sequence and isolated lifecycle tests.
    func prepareForTermination() async {
        startupApplicationUpdateScheduler.cancelForTermination()
        if let prepareBenchmarkForTermination = prepareBenchmarkForTermination {
            await prepareBenchmarkForTermination()
        }
        if let prepareApplicationUpdatesForTermination = prepareApplicationUpdatesForTermination {
            await prepareApplicationUpdatesForTermination()
        }
        if let prepareStartupItemsForTermination = prepareStartupItemsForTermination {
            await prepareStartupItemsForTermination()
        }
        if let prepareMemoryOptimizationForTermination = prepareMemoryOptimizationForTermination {
            await prepareMemoryOptimizationForTermination()
        }
        if let prepareMetricHistoryForTermination = prepareMetricHistoryForTermination {
            await prepareMetricHistoryForTermination()
        }
        if let prepareFanControlForTermination = prepareFanControlForTermination {
            await prepareFanControlForTermination()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupApplicationUpdateScheduler.cancelForTermination()
        // Covers forceful or system-driven termination paths that bypassed the
        // deferred reply above. Cancellation is idempotent.
        requestBenchmarkCancellation?()
        requestApplicationUpdateCancellation?()
        requestStartupItemCancellation?()
        requestMemoryOptimizationCancellation?()
        FanControlCoordinator.shared.disconnectForTermination()
        AgentInterface.shared.terminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // D257: opening the app again while only the panel runs brings the
        // main program back; leave() opens the window itself.
        if MenuBarOnlyMode.shared.isActive {
            MenuBarOnlyMode.shared.leave()
            return false
        }
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
        // D257: from the menu-bar-only state the main program comes back
        // first; leave() calls this again to open the window.
        if MenuBarOnlyMode.shared.isActive {
            MenuBarOnlyMode.shared.leave()
            return
        }
        if let openMainWindow {
            openMainWindow()
        } else {
            NotificationCenter.default.post(name: .storageCleanerShowMainWindow, object: nil)
        }
    }
}

/// D248: the main window a focused command value belongs to, kept in that
/// window's state. A value made of closures is new on every body evaluation
/// and SwiftUI cannot compare closures, so each redraw was an update of the
/// focused value; several in one frame logged "FocusedValue update tried to
/// update multiple times per frame" (install22 at launch). The values compare
/// by this scope, and by what else their closures read from the body.
struct MainWindowCommandScope: Hashable {
    private let id = UUID()
}

struct MainWindowSidebarAction: Equatable {
    let scope: MainWindowCommandScope
    /// The fold animates unless Reduce Motion is on; a change must replace
    /// the closure that read it.
    let reducesMotion: Bool
    let perform: @MainActor () -> Void

    @MainActor
    func callAsFunction() {
        perform()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.reducesMotion == rhs.reducesMotion
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
            // D175: it folds the sidebar to icons and back (was “显示或隐藏边栏”,
            // which hid the whole column).
            Button(L10n.text("展开或收起侧栏", "Expand or Collapse Sidebar")) {
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
    @StateObject private var installationConflictController: AppInstallationConflictController
    @AppStorage(L10n.languageDefaultsKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(L10n.appearanceDefaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue

    init() {
#if STORAGE_CLEANER_BETA
        // D106: first, so a refused acceptance launch exits before any
        // window, status item, store or helper connection exists.
        AcceptanceLaunch.configureOrExit()
#endif
        Self.terminateIfDuplicateInstance()
        let coordinator = HeavyWorkCoordinator(operationLockDirectory:
            AppDataDirectories.applicationSupportRoot.appendingPathComponent("OperationLocks"))
        let activityStore = HeavyWorkActivityStore(coordinator: coordinator)
        StartupApplicationUpdateScheduler.shared.observeCompletion(of: activityStore)
        heavyWorkCoordinator = coordinator
        // Set before any window appears (a launch may never show the main
        // window): Sparkle's install relaunch takes its lease from this
        // coordinator, so it waits for heavy work and blocks new work.
        AppUpdater.shared.heavyWorkCoordinator = coordinator
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
#if DEBUG
        let privacyStore = BrowserPrivacyPreviewFixture.isRequested
            ? BrowserPrivacyPreviewFixture.makeStore()
            : BrowserPrivacyStore()
#else
        let privacyStore = BrowserPrivacyStore()
#endif
        _browserPrivacyStore = StateObject(wrappedValue: privacyStore)
        let benchmarkCatalog = MacBenchmarkProductionBaselineCatalog.runtimeCatalog()
        let benchmarkProcessor = MacBenchmarkResultProcessor(
            baselineCatalog: benchmarkCatalog
        )
        let benchmarkService = MacBenchmarkService(heavyWorkCoordinator: coordinator)
        let sustainedBenchmarkService = MacSustainedBenchmarkService(
            heavyWorkCoordinator: coordinator,
            workloadRunner: SystemMacSustainedBenchmarkWorkloadRunner()
        )
        let benchmarkTelemetry = MSeriesV11TelemetryBridge(monitor: scanStore.helperPowerMetricsMonitor)
        var v11Dependencies = MSeriesV11Dependencies()
        v11Dependencies.telemetry = { await MainActor.run { benchmarkTelemetry.readings.map(\.telemetry) } }
        v11Dependencies.telemetryReasons = { await MainActor.run { benchmarkTelemetry.missingReasons } }
        v11Dependencies.beginTelemetrySession = { await benchmarkTelemetry.beginSession(sessionID: $0) }
        v11Dependencies.finishTelemetry = { await benchmarkTelemetry.finish() }
        v11Dependencies.onLiveObservation = { await benchmarkTelemetry.present($0) }
        let benchmarkV7Coordinator = BenchmarkV7Coordinator(
            workloadRunner: SystemBenchmarkV7WorkloadRunner(),
            heavyWorkCoordinator: coordinator,
            sustainedService: sustainedBenchmarkService,
            v11Runner: MSeriesV11Runner(dependencies: v11Dependencies)
        )
        let benchmarkLeaderboardStore = BenchmarkV7LeaderboardStore()
        _macBenchmarkLeaderboardStore = StateObject(
            wrappedValue: benchmarkLeaderboardStore
        )
        let benchmarkStore = MacBenchmarkStore(
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
            v7Coordinator: benchmarkV7Coordinator,
            v11TelemetryBridge: benchmarkTelemetry
        )
        _macBenchmarkStore = StateObject(wrappedValue: benchmarkStore)
        let conflictController = AppInstallationConflictController()
        _installationConflictController = StateObject(wrappedValue: conflictController)
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
        // The latency script measures the menu-bar panel alone: only the
        // menu-bar part of the main window's launch work runs, here, and the
        // main window itself is kept hidden (MainWindowReopenBridge).
        if MenuBarLatencyScript.isRequested {
            MenuBarLatencyScript.prepareApplicationIfRequested()
            Task { @MainActor in
                MenuBarStatusController.shared.install(
                    store: scanStore,
                    computerHealthStore: healthStore
                )
                scanStore.prepareMenuBarLiveStatusOnLaunch()
                Task { await healthStore.prepareMenuBarHealthOnLaunch() }
                scanStore.startSystemEnergyMonitoring()
                MenuBarLatencyScript.start(store: scanStore)
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
        // D255: started by applicationDidFinishLaunching, with or without a window.
        let launchWork = AppLaunchWork(
            store: scanStore, computerHealthStore: healthStore, benchmarkStore: benchmarkStore,
            heavyWorkCoordinator: coordinator, installationConflictController: conflictController,
            browserPrivacyStore: privacyStore)
        AppLaunchCoordinator.shared.prepare { delegate in launchWork.run(delegate: delegate) }
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
                .modifier(ExternalUninstallRequestBridge(store: store, center: .shared))
                .id(languageRawValue)
                .environment(\.locale, L10n.locale)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    localizeMainMenu()
                    // D255: the launch work normally ran already, from
                    // applicationDidFinishLaunching; this covers a window that comes first.
                    AppLaunchCoordinator.shared.start(delegate: nil)
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
                    // D100 G5: offer a rescan when access granted meanwhile
                    // makes roots the last scan missed readable.
                    store.checkAccessAfterReturn()
                    StartupApplicationUpdateScheduler.shared.scheduleIfDue(
                        shouldCheck: { ApplicationUpdateCheckSchedule.shouldCheck() },
                        executionAvailable: { store.canRefreshAppUpdates },
                        priorityReady: { MenuBarSamplingContext.shared.startupPriorityReady
                            && store.menuBarMonitorSnapshot?.cpuUsageBreakdown != nil },
                        operation: { store.prepareApplicationUpdatesOnLaunch() }
                    )
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
                // D154: CleanMyMac's View menu lists its modules in sidebar
                // order; ⌘1–⌘8 open the eight above, ⌘9 My Tools.
                ForEach(Array(CareStudioFamily.allCases.enumerated()), id: \.element) { index, family in
                    if family == .myTools {
                        Divider()
                    }
                    if index < 9 {
                        Button(family.title) {
                            store.showFilter(family.primaryRoute)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                    } else {
                        Button(family.title) {
                            store.showFilter(family.primaryRoute)
                        }
                    }
                }
            }

            CommandMenu(L10n.text("工具", "Tools")) {
                Button(L10n.text("监控小窗", "Monitoring Panel")) {
                    menuBarStatusController.showMonitoringPanel()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                Divider()

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
            // Locale and SettingsView's language subscription refresh text in place.
            // Replacing the split-view root discards drafts and can displace its content.
            SettingsView(cleanupArchitectureMode: store.cleanupFeatureConfiguration.mode, scanStore: store)
                .environment(\.locale, L10n.locale)
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(SettingsWindowPlacement.preferredSize())
    }

    private var preferredColorScheme: ColorScheme? {
        (AppAppearance(rawValue: appearanceRawValue) ?? .system).preferredColorScheme
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
#if DEBUG || STORAGE_CLEANER_BETA
            .background {
                if MenuBarLatencyScript.isRequested {
                    MenuBarLatencyScriptWindowSuppressor()
                }
            }
#endif
            // D258: the window SwiftUI opens at a login launch is built, so
            // Open Main Program can use its openWindow, but never shown.
            .background {
                if MenuBarOnlyMode.shared.isLaunchWindowSuppressionPending {
                    HiddenLaunchWindowSuppressor()
                }
            }
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

/// D255: what the main window's appearance used to start.
@MainActor
struct AppLaunchWork {
    let store: ScanStore
    let computerHealthStore: ComputerHealthStore
    let benchmarkStore: MacBenchmarkStore
    let heavyWorkCoordinator: HeavyWorkCoordinator
    let installationConflictController: AppInstallationConflictController
    let browserPrivacyStore: BrowserPrivacyStore

    func run(delegate: AppDelegate?) {
#if DEBUG || STORAGE_CLEANER_BETA
        // Started from init for the latency script (StorageCleanerMacApp).
        guard !MenuBarLatencyScript.isRequested else { return }
#endif
        if let delegate { installTerminationWork(on: delegate) }
        // D267: off until the user turns it on, and needs no window.
        AgentInterface.shared.start(source: AgentStoreReadSource(store: store, health: computerHealthStore))
        let menuBarStatusController = MenuBarStatusController.shared
        menuBarStatusController.install(store: store, computerHealthStore: computerHealthStore)
        // D256: a quit keeps the panel only when there is one in the menu bar
        // (an acceptance session installs none).
        if menuBarStatusController.hasStatusItem {
            MenuBarOnlyMode.shared.configure(menuBarOnlyDependencies())
        }
        // D270: a launch that began with the panel alone opens the main
        // program when the system does not place its status item in a menu
        // bar in time (System Settings → Menu Bar → Allow in the Menu Bar is
        // off for this app); `isVisible` stays true for such an item.
        Task { @MainActor in
            _ = await menuBarStatusController.waitForStatusItemPlacement(timeout: MenuBarStatusItemPlacement.launchWait)
            MenuBarOnlyMode.shared.statusItemVisibilityChanged(isShowing: menuBarStatusController.isShowingStatusItem)
        }
        AppLifecycleReminderCenter.shared.start(store: store)
        store.prepareMenuBarLiveStatusOnLaunch()
        let computerHealthStore = computerHealthStore
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
        let store = store
        StartupApplicationUpdateScheduler.shared.scheduleIfDue(
            shouldCheck: { ApplicationUpdateCheckSchedule.shouldCheck() },
            executionAvailable: { store.canRefreshAppUpdates },
            priorityReady: { MenuBarSamplingContext.shared.startupPriorityReady
                && store.menuBarMonitorSnapshot?.cpuUsageBreakdown != nil },
            operation: { store.prepareApplicationUpdatesOnLaunch() }
        )
        store.reconcileInterruptedOperationsOnLaunch()
        let benchmarkStore = benchmarkStore, installationConflictController = installationConflictController
        Task {
            await benchmarkStore.prepareLifecycleOnLaunch()
            await installationConflictController.checkIfNeeded()
        }
    }

    private func installTerminationWork(on appDelegate: AppDelegate) {
        let store = store, benchmarkStore = benchmarkStore, coordinator = heavyWorkCoordinator
        appDelegate.requestBenchmarkCancellation = { [weak benchmarkStore] in
            benchmarkStore?.cancelAll()
        }
        appDelegate.requestApplicationUpdateCancellation = { [weak store] in
            StartupApplicationUpdateScheduler.shared.cancelForTermination()
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
            StartupApplicationUpdateScheduler.shared.cancel()
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
    }

    /// D257/D259: fan control and live monitoring are not part of it.
    private func menuBarOnlyDependencies() -> MenuBarOnlyMode.Dependencies {
        let store = store, benchmarkStore = benchmarkStore, privacy = browserPrivacyStore
        return MenuBarOnlyMode.Dependencies(
            cancelBenchmark: { [weak benchmarkStore] in benchmarkStore?.cancelAll() },
            closeWindows: { MenuBarOnlyMode.closeMainProgramWindows() },
            setActivationPolicy: { NSApp.setActivationPolicy($0) },
            flushMetrics: { [weak store] in await store?.flushMenuBarMetricHistory() },
            releaseMemory: { [weak store, weak privacy] in
                guard let store, store.releaseMainWindowData(privacy: privacy) else { return false }
                Task {
                    await AppIconCache.shared.purge()
                    await MenuBarDerivedCache.shared.purge()
                }
                return true
            },
            waitUntilIdle: { [weak store] in
                // At least one pause, so a refusal that is not a heavy-work
                // lease (a scan starting) does not spin.
                repeat {
                    try? await Task.sleep(for: .seconds(5))
                } while store?.heavyWorkActivityStore.activeOwner != nil && !Task.isCancelled
            },
            openMainWindow: { MainWindowReopenCoordinator.shared.requestMainWindow() },
            activate: { NSApp.activate(ignoringOtherApps: true) },
            isPanelShown: { MenuBarStatusController.shared.isPanelShown }
        )
    }
}

#if DEBUG || STORAGE_CLEANER_BETA
private struct GoldenUnmeasuredHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}
#endif
