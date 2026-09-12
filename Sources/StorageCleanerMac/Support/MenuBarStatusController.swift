import AppKit
import Combine
import SwiftUI

enum MenuBarPanelIdleReclamationPolicy {
    static let delay: Duration = .seconds(60)

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

    init(summary: String, appearance: NSAppearance) {
        self.summary = summary
        appearanceName = appearance.bestMatch(from: [.aqua, .darkAqua])
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
    private var statusHighlighted = false
    private var pauseCancellable: AnyCancellable?
    private var fanModeCancellable: AnyCancellable?
    private var refreshIntervalCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var panelReclamationTask: Task<Void, Never>?
    private var renderedIdentity: MenuBarStatusRenderIdentity?
    private var renderedWidth: CGFloat?
    private(set) var statusDisplayMode = MenuBarStatusDisplayMode.stored()

    private override init() {
        super.init()
    }

    func install(store: ScanStore, computerHealthStore: ComputerHealthStore) {
        self.store = store
        self.computerHealthStore = computerHealthStore
        guard statusItem == nil else { return }

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
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItem(snapshot: self.store?.menuBarMonitorSnapshot)
            }
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
        fanModeCancellable = FanControlCoordinator.shared.$selectedMode
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
        if let session = panelSession,
           session.panel.isVisible,
           session.panel.isOnActiveSpace {
            session.hide(reason: "status-item-toggle")
            return
        }

        presentPanel(from: sender)
    }

    private func presentPanel(from sender: NSStatusBarButton) {
        guard let store, let computerHealthStore else { return }
        cancelPanelReclamation()
        startRefreshLoop(store: store)
        store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)

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

        if let session = panelSession, !session.isTornDown {
            let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
            let state = PerformanceTelemetry.signposter.beginInterval(
                "WindowOpen",
                id: signpostID
            )
            session.show(anchor: resolvedAnchor, screen: screen, density: .geek)
            PerformanceTelemetry.signposter.endInterval("WindowOpen", state)
            setStatusHighlighted(true)
            return
        }

        let signpostID = PerformanceTelemetry.signposter.makeSignpostID()
        let state = PerformanceTelemetry.signposter.beginInterval(
            "WindowOpen",
            id: signpostID
        )
        defer { PerformanceTelemetry.signposter.endInterval("WindowOpen", state) }

        let panel = MenuBarStatusPanel(contentRect: .zero)
        let panelSettingsState = MenuBarPanelSettingsState(
            initialDensity: .geek,
            isGeekEditorPresented: PanelScene.shouldPresentGeekEditorOnLaunch
        )
        var showsPower = true
        if case .notPresent? = computerHealthStore.snapshot?.batteryEvidence {
            showsPower = false
        }
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
            paletteFanControl = .shared
        }
#else
        paletteFanControl = .shared
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
            }
        )

        panelSession = session
        session.show(anchor: resolvedAnchor, screen: screen, density: .geek)
        setStatusHighlighted(true)
    }

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
        refreshDeviceStatus(force: true)
        if let store {
            startRefreshLoop(store: store)
            store.refreshMenuBarLiveStatus(showLoadingWhenEmpty: false)
        }
    }

    func setPanelAlwaysOnTop(_ value: Bool) {
        panelSession?.setAlwaysOnTop(value)
    }

    func setGeekPanelSection(_ section: PanelSection) {
        panelSession?.setGeekSection(section)
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
        statusHighlighted = highlighted
        statusItem?.button?.highlight(highlighted)
        updateStatusItem(snapshot: store?.menuBarMonitorSnapshot, force: true)
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
        let identity = MenuBarStatusRenderIdentity(summary: summary, appearance: appearance)
        guard force || identity != renderedIdentity else { return }

        let image = MenuBarStatusRenderer.image(
            for: snapshot, mode: statusDisplayMode, deviceStatus: deviceStatus,
            // Selection changes the button's effective appearance even when the
            // menu bar behind it remains light. Use its containing bar window.
            appearance: appearance,
            highlighted: statusHighlighted
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
        guard statusDisplayMode == .deviceStatus, let store,
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

    private func startRefreshLoop(store: ScanStore) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self, weak store] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                guard let self, let store else { return }
                let interval = store.menuBarRefreshInterval
                let panelVisible = panelSession?.panel.isVisible == true
                    || store.menuBarAuxiliaryMonitorState.activeConsumerCount > 0
                let customFanControlActive = FanControlCoordinator.shared.selectedMode
                    != .systemAutomatic
                do {
                    let nanoseconds = interval.sleepNanoseconds(
                            panelVisible: panelVisible,
                            statusDisplayMode: statusDisplayMode,
                            customFanControlActive: customFanControlActive,
                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
                        )
                    deadline += .nanoseconds(Int64(nanoseconds))
                    if deadline < clock.now { deadline = clock.now }
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !store.isMenuBarRefreshPaused else { continue }
                if deadline < clock.now { deadline = clock.now }
                refreshDeviceStatus()
                store.refreshMenuBarLiveStatus()
            }
        }
    }

}
