import AppKit
import Combine
import CombinedStatusIcon
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

/// D270: macOS 27 hides a status item that System Settings → Menu Bar →
/// "Allow in the Menu Bar" does not allow without changing its `isVisible`:
/// the system never places it, and its button stays at the placeholder below
/// the main screen (`0,-11,53x22`). An allowed item is placed in the active
/// display's menu bar 0.08–0.25 s after it is created, also while that menu
/// bar is hidden (a full-screen Space, or "Automatically hide and show the
/// menu bar: Always"). On the way it passes frames off every screen, at height
/// 0 and mid-animation, so a measurement that finds the button in a menu bar
/// counts for good and one that finds it anywhere else answers nothing.
/// Measured 2026-10-29/30 with a probe app (`review-fixes/d270-signal`).
@MainActor
final class MenuBarStatusItemPlacement {
    /// How far below its screen's top edge a placed button's top can sit: the
    /// measured buttons sat 3–4 pt below it (34 pt mid-animation), the
    /// placeholder and the frames on the way 850 pt or more.
    nonisolated static let menuBarBandDepth: CGFloat = 40
    /// A launch with the panel alone waits this long for the system to place
    /// the item before it counts as not shown.
    nonisolated static let launchWait: Duration = .seconds(10)
    nonisolated static let pollInterval: Duration = .milliseconds(100)

    private let buttonFrame: @MainActor () -> NSRect?
    private let screenFrames: @MainActor () -> [NSRect]
    private(set) var isPlaced = false

    init(buttonFrame: @escaping @MainActor () -> NSRect?,
         screenFrames: @escaping @MainActor () -> [NSRect] = { NSScreen.screens.map(\.frame) }) {
        self.buttonFrame = buttonFrame
        self.screenFrames = screenFrames
    }

    /// Measures now; true once any measurement has found the button in a menu bar.
    @discardableResult
    func measure() -> Bool {
        if !isPlaced, let frame = buttonFrame(),
           Self.isInMenuBar(buttonFrame: frame, screenFrames: screenFrames()) {
            isPlaced = true
        }
        return isPlaced
    }

    /// True as soon as the button is placed, false once `timeout` passes first.
    func wait(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !measure() {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return true
    }

    /// The button's center lies on a screen whose top edge is at most
    /// `menuBarBandDepth` above the button's top edge.
    nonisolated static func isInMenuBar(buttonFrame frame: NSRect, screenFrames: [NSRect]) -> Bool {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return false }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return screenFrames.contains { screen in
            let depth = screen.maxY - frame.maxY
            return screen.contains(center) && depth >= 0 && depth <= menuBarBandDepth
        }
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
    /// D270: whether the system has placed the status item in a menu bar.
    private lazy var statusItemPlacement = MenuBarStatusItemPlacement(buttonFrame: { [weak self] in
        self?.currentStatusButtonScreenFrame()
    })
    private var placementCancellable: AnyCancellable?
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
    private var installedWithoutStatusItem = false
    /// Audit only: when the panel was last hidden.
    private var panelHiddenUptime: Double?
    private(set) var statusDisplayMode = MenuBarStatusDisplayMode.stored()
    /// D153: the combined icon's monitors and live renderer, present only
    /// while that mode is shown.
    private let combinedStatus = CombinedStatusItemDriver()
    /// D153: what the combined icon draws now, for the settings preview.
    var combinedStatusSnapshot: StatusSnapshot? { combinedStatus.snapshot }

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

    /// D256: a quit keeps the panel only when there is one in the menu bar.
    var hasStatusItem: Bool { statusItem != nil }
    /// D270: whether the panel can be reached from the menu bar now: the item
    /// is visible and the system has placed it in a menu bar.
    var isShowingStatusItem: Bool { statusItem?.isVisible == true && statusItemPlacement.measure() }
    var isPanelShown: Bool { panelSession?.panel.isVisible == true }

    /// D270: true once the system places the status item in a menu bar, false
    /// when there is no item or `timeout` passes first.
    func waitForStatusItemPlacement(timeout: Duration) async -> Bool {
        guard statusItem != nil else { return false }
        return await statusItemPlacement.wait(timeout: timeout)
    }

    func install(store: ScanStore, computerHealthStore: ComputerHealthStore) {
        self.store = store
        self.computerHealthStore = computerHealthStore
        store.attachMenuBarResidentSampling(.shared)
        guard statusItem == nil else { return }
        // D106: the system draws a status item in every display's menu bar,
        // outside the one an acceptance session is confined to.
        if AcceptanceLaunch.isActive {
            installWithoutStatusItem(store: store)
            return
        }
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
        watchStatusItemPlacement(button)
        statusVisibilityObservation = statusItem.observe(\.isVisible, options: [.new]) { [weak self, weak store] _, _ in
            Task { @MainActor in
                guard let self, let store else { return }
                self.startRefreshLoop(store: store)
                self.refreshDeviceStatus(force: true)
                // D153: a hidden item stops the combined icon's monitors.
                if self.statusDisplayMode == .combinedStatus {
                    self.updateStatusItem(snapshot: store.menuBarMonitorSnapshot)
                }
                MenuBarOnlyMode.shared.statusItemVisibilityChanged(isShowing: self.isShowingStatusItem)
            }
        }
        samplingEnvironmentCancellable = Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
        ).sink { @Sendable [weak self, weak store] _ in
            Task { @MainActor in
                guard let self, let store else { return }
                self.startRefreshLoop(store: store)
                // D153: Low Power Mode is part of the combined icon's battery.
                if self.statusDisplayMode == .combinedStatus {
                    self.updateStatusItem(snapshot: store.menuBarMonitorSnapshot)
                }
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
                    if self.statusDisplayMode == .combinedStatus {
                        self.updateStatusItem(snapshot: store.menuBarMonitorSnapshot)
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
                    // D153: the combined icon draws the same battery reading.
                    guard let self, let store,
                          self.statusDisplayMode == .deviceStatus || self.statusDisplayMode == .combinedStatus
                    else { return }
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
            // D270: the panel opens under its status item, so not before the
            // system places the item; one it never places opens no panel (a
            // launch with the panel alone then opens the main program).
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, await self.waitForStatusItemPlacement(timeout: MenuBarStatusItemPlacement.launchWait),
                      let button = self.statusItem?.button else { return }
                if let session = self.panelSession,
                   session.panel.isVisible,
                   session.panel.isOnActiveSpace {
                    return
                }
                self.presentPanel(from: button)
            }
        }
    }

    /// D270: until the system places the item, every move, resize and screen
    /// change of its window and every screen-parameter change measures again,
    /// and the launch polls for `launchWait`. None of them counts as "gone",
    /// and a placed item stays counted.
    private func watchStatusItemPlacement(_ button: NSStatusBarButton) {
        let center = NotificationCenter.default
        var publishers = [center.publisher(for: NSApplication.didChangeScreenParametersNotification)]
        if let window = button.window {
            publishers += [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                           NSWindow.didChangeScreenNotification].map { center.publisher(for: $0, object: window) }
        }
        placementCancellable = Publishers.MergeMany(publishers).sink { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.statusItemPlacement.measure() else { return }
                self.placementCancellable = nil
            }
        }
        Task { @MainActor [weak self] in
            guard let placement = self?.statusItemPlacement,
                  await placement.wait(timeout: MenuBarStatusItemPlacement.launchWait) else { return }
            self?.placementCancellable = nil
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
        if AcceptanceLaunch.isActive {
            presentPanelOnAcceptanceDisplay()
            return
        }
        guard let button = statusItem?.button else { return }
        presentPanel(from: button)
    }

    /// D106: the sampling a status item starts, without the status item. The
    /// panel opens from the menu command or `--open-menu-bar-panel`.
    private func installWithoutStatusItem(store: ScanStore) {
        guard !installedWithoutStatusItem else { return }
        installedWithoutStatusItem = true
        MenuBarSamplingContext.shared.beginStartup()
        scheduleStartupRounds(store: store)
        updateSamplingContext(store: store)
        startRefreshLoop(store: store)
        store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
        if ProcessInfo.processInfo.arguments.contains(AcceptanceLaunch.openPanelArgument) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.presentPanelOnAcceptanceDisplay()
            }
        }
    }

    /// D106: anchored where a status item would sit, at the right end of the
    /// acceptance display's menu bar.
    private func presentPanelOnAcceptanceDisplay() {
        guard let store, computerHealthStore != nil,
              let screen = DisplayConfinementGate.shared.targetScreen() else { return }
        let openStartedAt = MenuBarPresentationTrace.uptime
        beginPanelPresentation(store: store)
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
        let anchor = NSRect(x: screen.visibleFrame.maxX - 44, y: screen.visibleFrame.maxY,
                            width: 28, height: menuBarHeight)
        showPanel(anchor: anchor, screen: screen, startedAt: openStartedAt)
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
        if statusDisplayMode == .combinedStatus {
            updateCombinedStatusItem(statusItem, button: button)
            return
        }
        tearDownCombinedStatus()
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

    /// D153: the combined icon draws itself (a template base, a colour layer
    /// and the 20 fps charging effect, as Status Trio's status item); the
    /// driver gets the app's battery, settings, item colour and state. The
    /// item sizes to the icon like upstream's variable-length item.
    private func updateCombinedStatusItem(_ statusItem: NSStatusItem, button: NSStatusBarButton) {
        if statusItem.length != NSStatusItem.variableLength {
            statusItem.length = NSStatusItem.variableLength
        }
        renderedWidth = nil
        renderedIdentity = nil
        let auxiliary = store?.menuBarAuxiliaryMonitorState
        let defaults = UserDefaults.standard
        let appearance = button.window?.effectiveAppearance ?? button.effectiveAppearance
        let statusPreset = PanelStatusColorPreset(rawValue:
            defaults.string(forKey: PanelPalettePreferences.statusThemeKey) ?? "") ?? .original
        combinedStatus.update(button: button, context: CombinedStatusItemDriver.Context(
            battery: CombinedStatusIconBattery.status(
                snapshot: auxiliary?.batterySnapshot,
                availability: auxiliary?.internalBatteryAvailability ?? .unknown,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            ),
            settings: CombinedStatusIconPreferences.stored(in: defaults),
            foreground: statusPreset.ink(
                dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                customDayHex: defaults.string(forKey: PanelPalettePreferences.statusCustomDayKey) ?? "",
                customNightHex: defaults.string(forKey: PanelPalettePreferences.statusCustomNightKey) ?? ""
            ),
            isVisible: statusItem.isVisible,
            isPaused: store?.isMenuBarRefreshPaused == true,
            isSystemSleeping: systemSleeping,
            isDisplaySleeping: displaySleeping
        ))
    }

    private func tearDownCombinedStatus() {
        guard combinedStatus.isActive else { return }
        combinedStatus.tearDown()
        renderedWidth = nil
        renderedIdentity = nil
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
