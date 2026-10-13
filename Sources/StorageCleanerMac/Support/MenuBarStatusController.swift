import AppKit
import Combine
import SwiftUI

enum MenuBarPanelIdleReclamationPolicy {
    static let delay = MenuBarPerformancePolicy.cachedWindowLifetime

    @MainActor
    static func shouldReclaim(_ session: MenuBarPanelSession?) -> Bool {
        guard let session else { return false }
        return !session.isTornDown && !session.panel.isVisible
    }
}

/// AppKit can notify effectiveAppearance while capturing status-item replicas.
/// Compare the resolved theme, not NSAppearance object identity or notifications.
struct MenuBarStatusRenderIdentity: Equatable {
    let summary: String
    let appearanceName: NSAppearance.Name?
    let statusPreset: PanelStatusColorPreset
    let customDayHex: String
    let customNightHex: String

    init(summary: String, appearance: NSAppearance,
         statusPreset: PanelStatusColorPreset = .original,
         customDayHex: String = "", customNightHex: String = "") {
        self.summary = summary
        appearanceName = appearance.bestMatch(from: [.aqua, .darkAqua])
        self.statusPreset = statusPreset
        self.customDayHex = customDayHex
        self.customNightHex = customNightHex
    }
}

@MainActor
final class MenuBarStatusController: NSObject, ObservableObject {
    static let shared = MenuBarStatusController()

    private var statusItem: NSStatusItem?
    private weak var store: ScanStore?
    private weak var computerHealthStore: ComputerHealthStore?
    private var panelSession: MenuBarPanelSession?
    private let geometryStore = PanelGeometryStore()
    private var snapshotCancellable: AnyCancellable?
    private var deviceStatusCancellable: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var statusVisibilityObservation: NSKeyValueObservation?
    private var samplingEnvironmentCancellable: AnyCancellable?
    private var sleepCancellables: [AnyCancellable] = []
    private var systemSleeping = false
    private var displaySleeping = false
    private var palettePreferenceCancellable: AnyCancellable?
    private var statusHighlighted = false
    private var pauseCancellable: AnyCancellable?
    private var fanModeCancellable: AnyCancellable?
    private var refreshIntervalCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var panelReclamationTask: Task<Void, Never>?
    private var panelMemoryPressureSource: DispatchSourceMemoryPressure?
    private var renderedIdentity: MenuBarStatusRenderIdentity?
    private var renderedWidth: CGFloat?
    private var hasCreatedPanelSession = false
    /// Audit only: when the panel was last hidden.
    private var panelHiddenUptime: Double?
    private(set) var statusDisplayMode = MenuBarStatusDisplayMode.stored()

    private let fanControlProvider: @MainActor () -> FanControlCoordinator
    private lazy var fanControl = fanControlProvider()

    private init(fanControlProvider: @escaping @MainActor () -> FanControlCoordinator = { FanControlCoordinator.shared }) {
        self.fanControlProvider = fanControlProvider
        super.init()
    }

    /// UserDefaults posts `didChangeNotification` synchronously on the thread
    /// that wrote, and receipts are saved off the main thread
    /// (`CleanReportStore.recordDetached`). A sink written here would inherit
    /// main-actor isolation, which Swift 6 checks at run time: delivery on a
    /// worker thread trapped right after "Move to Trash" (2026-10-06). The
    /// `@Sendable` sink is nonisolated and only schedules `refresh`.
    static func defaultsChangeSubscription(
        center: NotificationCenter = .default,
        refresh: @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable {
        center.publisher(for: UserDefaults.didChangeNotification)
            .sink { @Sendable _ in
                Task { @MainActor in refresh() }
            }
    }

    func install(store: ScanStore, computerHealthStore: ComputerHealthStore) {
        self.store = store
        self.computerHealthStore = computerHealthStore
        store.attachMenuBarResidentSampling(.shared)
        guard statusItem == nil else { return }
        MenuBarSamplingContext.shared.beginStartup()
        scheduleStartupRounds(store: store)
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                Task {
                    await MenuBarDerivedCache.shared.purge()
                    await AppIconCache.shared.purge()
                }
                // D39: windows kept for the next opening are dropped when
                // nothing is on screen.
                self?.store?.menuBarMonitorState.releaseKeptDisplayHistory()
                guard let self, let session = self.panelSession,
                      MenuBarPanelIdleReclamationPolicy.shouldReclaim(session) else { return }
                self.cancelPanelReclamation()
                session.teardown()
            }
        }
        panelMemoryPressureSource = pressure
        pressure.resume()

        let statusItem = NSStatusBar.system.statusItem(withLength: MenuBarStatusRenderer.initialWidth)
        guard let button = statusItem.button else {
            NSStatusBar.system.removeStatusItem(statusItem)
            return
        }

        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.title = ""
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseUp])
        button.toolTip = L10n.appName

        self.statusItem = statusItem
        updateSamplingContext(store: store)
        statusVisibilityObservation = statusItem.observe(\.isVisible, options: [.new]) { [weak self, weak store] _, _ in
            Task { @MainActor in
                guard let self, let store else { return }
                self.startRefreshLoop(store: store)
                self.refreshDeviceStatus(force: true)
            }
        }
        samplingEnvironmentCancellable = Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
        ).sink { @Sendable [weak self, weak store] _ in
            Task { @MainActor in
                guard let self, let store else { return }
                self.startRefreshLoop(store: store)
            }
        }
        // Notifications pause the same resident clock. Separate flags prevent
        // a screen wake from resuming while the system is still asleep.
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, system, sleeping) in [
            (NSWorkspace.willSleepNotification, true, true),
            (NSWorkspace.didWakeNotification, true, false),
            (NSWorkspace.screensDidSleepNotification, false, true),
            (NSWorkspace.screensDidWakeNotification, false, false)
        ] {
            sleepCancellables.append(workspace.publisher(for: name).sink { @Sendable [weak self, weak store] _ in
                Task { @MainActor in
                    guard let self, let store else { return }
                    if system { self.systemSleeping = sleeping } else { self.displaySleeping = sleeping }
                    self.updateSamplingContext(store: store)
                    if self.systemSleeping || self.displaySleeping {
                        self.refreshTask?.cancel()
                        self.refreshTask = nil
                        store.suspendMenuBarResidentSampling()
                    } else {
                        self.startRefreshLoop(store: store)
                        store.refreshMenuBarResidentSamples()
                        store.refreshMenuBarLiveStatus()
                    }
                }
            })
        }
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItem(snapshot: self.store?.menuBarMonitorSnapshot)
            }
        }
        palettePreferenceCancellable = Self.defaultsChangeSubscription { [weak self] in
            guard let self else { return }
            self.updateStatusItem(snapshot: self.store?.menuBarMonitorSnapshot)
        }
        updateStatusItem(snapshot: store.menuBarMonitorSnapshot)
        deviceStatusCancellable = store.menuBarAuxiliaryMonitorState.objectWillChange
            .sink { [weak self, weak store] _ in
                // Published sends before mutation. Read the committed value on
                // the next main-actor turn, including power-only/radio updates.
                Task { @MainActor in
                    guard let self, let store, self.statusDisplayMode == .deviceStatus else { return }
                    self.updateStatusItem(snapshot: store.menuBarMonitorSnapshot)
                }
            }
        pauseCancellable = store.$isMenuBarRefreshPaused
            .removeDuplicates()
            .sink { [weak self, weak store] paused in
                Task { @MainActor in
                    guard let self, let store else { return }
                    self.updateStatusItem(snapshot: store.menuBarMonitorSnapshot)
                    self.updateSamplingContext(store: store)
                    if !paused { self.refreshDeviceStatus(force: true) }
                }
            }
        snapshotCancellable = store.menuBarMonitorState.$snapshot
            .sink { [weak self] snapshot in
                Task { @MainActor in
                    self?.updateStatusItem(snapshot: snapshot)
                }
            }
        refreshIntervalCancellable = store.$menuBarRefreshInterval
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak store] _ in
                Task { @MainActor in
                    guard let self, let store else { return }
                    self.startRefreshLoop(store: store)
                }
            }
        fanModeCancellable = fanControl.$selectedMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak store] _ in
                Task { @MainActor in
                    guard let self, let store else { return }
                    self.startRefreshLoop(store: store)
                    store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
                }
            }
#if DEBUG || STORAGE_CLEANER_BETA
        if !MiniWindowDemoData.isEnabled {
            startRefreshLoop(store: store)
            store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
        }
#else
        startRefreshLoop(store: store)
        store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
#endif

        var shouldOpenPanel = UserDefaults.standard.bool(
            forKey: MenuBarPanelSettingsState.restoreOnLaunchDefaultsKey
        )
#if DEBUG || STORAGE_CLEANER_BETA
        shouldOpenPanel = shouldOpenPanel
            || ProcessInfo.processInfo.arguments.contains("--open-menu-bar-panel")
            || ProcessInfo.processInfo.arguments.contains("--open-menu-bar-panel-geek-editor")
            || ProcessInfo.processInfo.arguments.contains("--open-menu-bar-panel-settings")
            || MiniWindowDemoData.isCapturingMenuBarPanelSnapshots
#endif
        if shouldOpenPanel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                if let session = self.panelSession,
                   session.panel.isVisible,
                   session.panel.isOnActiveSpace {
                    return
                }
                self.presentPanel(from: button)
            }
        }
    }

    @objc
    private func togglePanel(_ sender: NSStatusBarButton) {
        PerformanceTelemetry.panelInput("action", target: "status-item.toggle", window: sender.window)
        if let session = self.panelSession,
           session.panel.isVisible,
           session.panel.isOnActiveSpace {
            session.hide(reason: "status-item-toggle")
            return
        }

        presentPanel(from: sender)
    }

    /// The menu command and status item share the exact same presentation path.
    func showMonitoringPanel() {
        guard let button = statusItem?.button else { return }
        presentPanel(from: button)
    }

    private func presentPanel(from sender: NSStatusBarButton) {
        guard let store, computerHealthStore != nil else { return }
        let openStartedAt = MenuBarPresentationTrace.uptime
        beginPanelPresentation(store: store)

        let rectInWindow = sender.convert(sender.bounds, to: nil)
        let anchor = sender.window?.convertToScreen(rectInWindow)
        let mouseLocation = NSEvent.mouseLocation
        let resolvedAnchor = MenuBarPanelPlacement.anchor(
            statusItemFrame: anchor,
            fallbackPoint: mouseLocation
        )
        guard let screen = ScreenContextResolver.resolve(
            statusItemScreen: sender.window?.screen,
            anchorRect: resolvedAnchor,
            pointerLocation: mouseLocation
        ) else {
            return
        }
        showPanel(anchor: resolvedAnchor, screen: screen, startedAt: openStartedAt)
    }

    /// What every open does before the panel is placed.
    private func beginPanelPresentation(store: ScanStore) {
        if MenuBarPresentationTrace.enabled {
            // first: no panel since launch; cold: the panel was reclaimed
            // (hidden over five minutes or memory pressure); warm: reused.
            let openKind = panelSession.map { $0.isTornDown ? "cold" : "warm" }
                ?? (hasCreatedPanelSession ? "cold" : "first")
            MenuBarPresentationTrace.startPresentation(event: NSApp.currentEvent, label: "open.\(openKind)")
            let now = Date()
            MenuBarPresentationTrace.mark("open.context", [
                "open": openKind,
                "hiddenSec": panelHiddenUptime.map { MenuBarPresentationTrace.uptime - $0 } ?? -1,
                "snapshotAgeMs": store.menuBarMonitorState.snapshot
                    .map { now.timeIntervalSince($0.generatedAt) * 1000 } ?? -1,
                "memoryAgeMs": store.menuBarDisplayMemorySnapshot
                    .map { now.timeIntervalSince($0.generatedAt) * 1000 } ?? -1,
                "load1": MenuBarPresentationTrace.loadAverage
            ])
        } else {
            MenuBarPresentationTrace.startPresentation(event: NSApp.currentEvent)
        }
        cancelPanelReclamation()
        // One plan update per open; the loop keeps its previous tick.
        updateSamplingContext(store: store, panelVisible: true)
        startRefreshLoop(store: store, updatesContext: false)
        // Show the cached presentation before scheduling any live refresh.
        Task { @MainActor [weak store] in
            store?.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
        }
    }

    private func showPanel(
        anchor resolvedAnchor: NSRect,
        screen: NSScreen,
        fixedVisibleFrame: NSRect? = nil,
        startedAt openStartedAt: Double
    ) {
        guard let store, let computerHealthStore else { return }
        if let session = self.panelSession, !session.isTornDown {
            let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
            let state = PerformanceTelemetry.signposter.beginInterval(
                "WindowOpen",
                id: signpostID
            )
            session.show(anchor: resolvedAnchor, screen: screen, density: .geek)
            PerformanceTelemetry.signposter.endInterval("WindowOpen", state)
            setStatusHighlighted(true)
            MenuBarPresentationTrace.span("open.sync", from: openStartedAt, ["open": "warm"])
            return
        }

        let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
        let state = PerformanceTelemetry.signposter.beginInterval(
            "WindowOpen",
            id: signpostID
        )
        defer { PerformanceTelemetry.signposter.endInterval("WindowOpen", state) }
        let buildStartedAt = MenuBarPresentationTrace.uptime

        let panel = MenuBarStatusPanel(contentRect: .zero)
        let panelSettingsState = MenuBarPanelSettingsState(
            initialDensity: .geek,
            isGeekEditorPresented: PanelScene.shouldPresentGeekEditorOnLaunch
        )
        let liveBattery = store.menuBarAuxiliaryMonitorState.internalBatteryAvailability
        let absentInHealth: Bool
        if case .notPresent? = computerHealthStore.snapshot?.batteryEvidence { absentInHealth = true }
        else { absentInHealth = false }
        var showsPower = liveBattery == .present || (liveBattery == .unknown && !absentInHealth)
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            showsPower = MiniWindowDemoData.hardwareControlProfile.hasInternalBattery
        }
#endif
        let initialOverviewModules = (PanelDensity.geek.geekContentProfile?.overviewModules(
            configuredModules: panelSettingsState.geekDashboardConfiguration.modules
        ) ?? []).filter { $0.isAvailableInOverview && ($0 != .power || showsPower) }
        let panelCoordinator = GeekPanelCoordinator()
        let paletteFanControl: FanControlCoordinator
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            paletteFanControl = FanControlCoordinator.makeReadOnlyFixture(
                defaults: UserDefaults(suiteName: "StorageCleanerMac.Snapshot.FanControl")!,
                profile: MiniWindowDemoData.hardwareControlProfile,
                snapshot: MiniWindowDemoData.fixture.snapshot
            )
        } else {
            paletteFanControl = fanControl
        }
#else
        paletteFanControl = fanControl
#endif
        let controlPaletteCoordinator = ControlPaletteCoordinator(
            hoverIntentController: panelCoordinator.hoverIntentController
        ) { state in
            AnyView(ControlPaletteRootView(
                presentation: state,
                store: store,
                computerHealthStore: computerHealthStore,
                fanControl: paletteFanControl
            ))
        }
        let session = MenuBarPanelSession(
            panel: panel,
            rootView: AnyView(
                PanelScene(
                    store: store,
                    computerHealthStore: computerHealthStore,
                    panelSettingsState: panelSettingsState,
                    panelCoordinator: panelCoordinator,
                    controlPaletteCoordinator: controlPaletteCoordinator
                )
            ),
            initialDensity: .geek,
            initialOverviewSize: GeekPanelLayout.overviewSize(modules: initialOverviewModules),
            geometryStore: geometryStore,
            panelSettingsState: panelSettingsState,
            panelCoordinator: panelCoordinator,
            controlPaletteCoordinator: controlPaletteCoordinator,
            triggerFrameProvider: { [weak self] in
                self?.currentStatusButtonScreenFrame()
            },
            fixedVisibleFrame: fixedVisibleFrame,
            onClose: { [weak self, weak panel] in
                guard let self, let capturedPanel = panel else { return }
                guard self.panelSession?.panel === capturedPanel else { return }
                self.cancelPanelReclamation()
                self.panelSession = nil
                self.setStatusHighlighted(false)
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.setStatusHighlighted(false)
                if let store = self.store {
                    self.startRefreshLoop(store: store)
                }
                self.schedulePanelReclamation()
                if MenuBarPresentationTrace.enabled {
                    self.panelHiddenUptime = MenuBarPresentationTrace.uptime
                }
            }
        )
        MenuBarPresentationTrace.span("open.build", from: buildStartedAt)

        panelSession = session
        hasCreatedPanelSession = true
        session.show(anchor: resolvedAnchor, screen: screen, density: .geek)
        setStatusHighlighted(true)
        MenuBarPresentationTrace.span("open.sync", from: openStartedAt, ["open": "cold"])
    }

#if DEBUG || STORAGE_CLEANER_BETA
    /// `MenuBarLatencyScript` opens through the same path as a click, at an
    /// anchor on a virtual display outside every screen.
    func latencyScriptPresent(anchor: NSRect, screen: NSScreen, visibleFrame: NSRect) {
        guard let store, computerHealthStore != nil else { return }
        let openStartedAt = MenuBarPresentationTrace.uptime
        beginPanelPresentation(store: store)
        showPanel(anchor: anchor, screen: screen, fixedVisibleFrame: visibleFrame, startedAt: openStartedAt)
    }

    /// The reclamation a hidden panel receives after five minutes.
    func latencyScriptReclaimPanel() {
        guard let session = panelSession else { return }
        cancelPanelReclamation()
        session.hide(reason: "script-reclaim")
        session.teardown()
    }

    var latencyScriptSession: MenuBarPanelSession? { panelSession }
#endif

    func dismissPanel() {
        panelSession?.hide()
    }

    private func cancelPanelReclamation() {
        panelReclamationTask?.cancel()
        panelReclamationTask = nil
    }

    private func schedulePanelReclamation() {
        cancelPanelReclamation()
        guard let session = panelSession else { return }
        panelReclamationTask = Task { @MainActor [weak self, weak session] in
            do {
                try await Task.sleep(for: MenuBarPanelIdleReclamationPolicy.delay)
            } catch {
                return
            }
            guard let self, let session,
                  self.panelSession === session,
                  MenuBarPanelIdleReclamationPolicy.shouldReclaim(session) else { return }
            session.teardown()
            self.panelReclamationTask = nil
        }
    }

    func selectPanelDensity(_ density: PanelDensity) {
        if density != PanelDensity.stored() {
            UserDefaults.standard.set(density.rawValue, forKey: PanelDensity.defaultsKey)
        }
        panelSession?.selectDensity(density)
    }

    func setStatusDisplayMode(_ mode: MenuBarStatusDisplayMode) {
        guard mode != statusDisplayMode else { return }
        statusDisplayMode = mode
        mode.save()
        renderedIdentity = nil
        updateStatusItem(snapshot: store?.menuBarMonitorSnapshot)
        if let store {
            startRefreshLoop(store: store)
            refreshDeviceStatus(force: true)
            store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
        }
    }

    func setPanelAlwaysOnTop(_ value: Bool) {
        panelSession?.setAlwaysOnTop(value)
    }

    func setGeekPanelSection(_ section: PanelSection, preferredDetailSize: CGSize? = nil) {
        panelSession?.setGeekSection(section, preferredDetailSize: preferredDetailSize)
    }

    func setGeekPanelOverviewSize(_ preferredSize: CGSize) {
        panelSession?.setOverviewSize(preferredSize)
    }

    func setGeekPanelDetailSize(_ preferredSize: CGSize?) {
        panelSession?.setDetailSize(preferredSize)
    }

    func setGeekPanelTertiaryPresented(
        _ presented: Bool,
        preferredSize: CGSize? = nil,
        sourceOffset: CGFloat? = nil
    ) {
        panelSession?.setTertiaryPresented(
            presented,
            preferredSize: preferredSize,
            sourceOffset: sourceOffset
        )
    }

    private func currentStatusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    private func setStatusHighlighted(_ highlighted: Bool) {
        let startedAt = MenuBarPresentationTrace.uptime
        statusHighlighted = highlighted
        statusItem?.button?.highlight(highlighted)
        updateStatusItem(snapshot: store?.menuBarMonitorSnapshot, force: true)
        MenuBarPresentationTrace.span("statusItem.highlight", from: startedAt)
    }

    private func updateStatusItem(snapshot: SystemMonitorSnapshot?, force: Bool = false) {
        guard let statusItem, let button = statusItem.button else { return }
        let auxiliary = store?.menuBarAuxiliaryMonitorState
        let deviceStatus = MenuBarDeviceStatusSnapshot(
            batteryPercent: auxiliary?.batterySnapshot?.chargePercent,
            isCharging: auxiliary?.batterySnapshot?.isCharging,
            memoryUsedRatio: store?.menuBarDisplayMemorySnapshot?.measuredUsedRatio,
            wiFi: auxiliary?.statusWiFiSnapshot?.state ?? .unknown,
            isPaused: store?.isMenuBarRefreshPaused ?? false,
            sampledAt: auxiliary?.statusWiFiSnapshot?.sampledAt,
            isFullyCharged: auxiliary?.batterySnapshot?.isFullyCharged == true,
            isConnectedToAC: auxiliary?.batterySnapshot?.powerSource == .acPower,
            batteryAvailability: auxiliary?.internalBatteryAvailability ?? .unknown
        )
        let summary = statusDisplayMode == .deviceStatus
            ? deviceStatus.accessibilitySummary
            : MenuBarStatusRenderer.accessibilitySummary(for: snapshot)
        let appearance = button.window?.effectiveAppearance ?? button.effectiveAppearance
        let statusPreset = PanelStatusColorPreset(rawValue:
            UserDefaults.standard.string(forKey: PanelPalettePreferences.statusThemeKey) ?? "") ?? .original
        let customDayHex = UserDefaults.standard.string(forKey: PanelPalettePreferences.statusCustomDayKey) ?? ""
        let customNightHex = UserDefaults.standard.string(forKey: PanelPalettePreferences.statusCustomNightKey) ?? ""
        let identity = MenuBarStatusRenderIdentity(summary: summary, appearance: appearance,
                                                   statusPreset: statusPreset,
                                                   customDayHex: customDayHex,
                                                   customNightHex: customNightHex)
        guard force || identity != renderedIdentity else { return }

        let image = MenuBarStatusRenderer.image(
            for: snapshot, mode: statusDisplayMode, deviceStatus: deviceStatus,
            // Selection changes the button's effective appearance even when the
            // menu bar behind it remains light. Use its containing bar window.
            appearance: appearance,
            highlighted: statusHighlighted, statusPreset: statusPreset,
            statusCustomDayHex: customDayHex, statusCustomNightHex: customNightHex
        )
        if renderedWidth != image.size.width {
            statusItem.length = image.size.width
            renderedWidth = image.size.width
        }
        button.image = image
        button.toolTip = summary
        button.setAccessibilityLabel(L10n.appName)
        button.setAccessibilityValue(summary)
        renderedIdentity = identity
    }

    private func refreshDeviceStatus(force: Bool = false) {
        guard let store, MenuBarSamplingContext.shared.plan?.needsStatusWiFi == true,
              !store.isMenuBarRefreshPaused else { return }
#if DEBUG || STORAGE_CLEANER_BETA
        guard !MiniWindowDemoData.isEnabled else { return }
#endif
        store.menuBarAuxiliaryMonitorState.refreshStatusWiFi(
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
                && panelSession?.panel.isVisible != true,
            force: force
        )
        if force { store.menuBarAuxiliaryMonitorState.refreshBackgroundBatteryHistory(force: true) }
    }

    private func updateSamplingContext(store: ScanStore, panelVisible: Bool? = nil) {
        MenuBarSamplingContext.shared.configure(
            statusMode: statusDisplayMode,
            statusVisible: statusItem?.isVisible == true,
            panelVisible: panelVisible ?? (panelSession?.panel.isVisible == true
                && panelSession?.panel.isOnActiveSpace == true),
            customFanControlActive: fanControl.selectedMode != .systemAutomatic,
            paused: store.isMenuBarRefreshPaused,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            suspended: systemSleeping || displaySleeping,
            selectedInterval: store.menuBarRefreshInterval.seconds
        )
        MenuBarSamplingContext.shared.refreshResidentRead("helper.connection") { [fanControl] in
            await fanControl.refreshConnection()
        }
        if let computerHealthStore {
            MenuBarSamplingContext.shared.refreshResidentRead("power.modes-read") {
                await computerHealthStore.refreshBatteryPowerModes()
            }
        }
        let visible = MenuBarSamplingContext.shared.plan?.panelVisible == true
        store.menuBarAuxiliaryMonitorState.setPresentationVisible(visible)
        if !visible { store.setMenuBarProcessDemand(.overview) }
        else { store.refreshMenuBarResidentSamples() } // Missing first samples are promoted immediately.
    }

    /// State changes update demand only. The running loop retains its pending
    /// deadline and uses the new cadence after that tick, so repeated changes
    /// cannot postpone status-item updates indefinitely.
    private func scheduleStartupRounds(store: ScanStore) {
        Task { @MainActor [weak self, weak store] in
            let clock = ContinuousClock(), began = ContinuousClock().now
            for offset in ResidentStartupSchedule.deadlines {
                do { try await clock.sleep(until: began + .seconds(offset)) }
                catch { return }
                guard let self, let store else { return }
                updateSamplingContext(store: store)
                guard MenuBarSamplingContext.shared.plan?.cadence.suspended == false else { continue }
                if MenuBarSamplingContext.shared.permitsStartupSource(.processes) {
                    store.refreshMenuBarResidentSamples()
                } else {
                    store.menuBarAuxiliaryMonitorState.refreshResidentSamples()
                }
                if offset == ResidentStartupSchedule.Source.hardware.offset {
                    store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
                }
            }
        }
    }

    private func startRefreshLoop(store: ScanStore, updatesContext: Bool = true) {
        if updatesContext { updateSamplingContext(store: store) }
        guard !systemSleeping, !displaySleeping, refreshTask == nil else { return }
        if MenuBarSamplingContext.shared.permitsStartupSource(.processes) {
            store.refreshMenuBarResidentSamples()
        }
        refreshTask = Task { @MainActor [weak self, weak store] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                guard let self, let store else { return }
                let interval = store.menuBarRefreshInterval
                let panelVisible = MenuBarSamplingContext.shared.plan?.panelVisible == true
                let customFanControlActive = fanControl.selectedMode
                    != .systemAutomatic
                do {
                    let nanoseconds = interval.sleepNanoseconds(
                            panelVisible: panelVisible,
                            statusDisplayMode: statusDisplayMode,
                            customFanControlActive: customFanControlActive,
                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                            statusVisible: statusItem?.isVisible == true
                        )
                    deadline += .nanoseconds(Int64(nanoseconds))
                    if deadline < clock.now { deadline = clock.now }
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !store.isMenuBarRefreshPaused else { continue }
                updateSamplingContext(store: store)
                if deadline < clock.now { deadline = clock.now }
                store.refreshMenuBarResidentSamples()
                guard MenuBarSamplingContext.shared.plan?.primaryKinds.isEmpty == false
                    || MenuBarSamplingContext.shared.plan?.needsStatusBattery == true
                    || MenuBarSamplingContext.shared.plan?.panelVisible == true else { continue }
                refreshDeviceStatus()
                store.refreshMenuBarLiveStatus()
            }
        }
    }

}
