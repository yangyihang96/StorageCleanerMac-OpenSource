import AppKit
import SwiftUI

struct PanelScene: View {
    let store: ScanStore
    let computerHealthStore: ComputerHealthStore
    @StateObject private var panelSettingsState: MenuBarPanelSettingsState
    @StateObject private var panelCoordinator: GeekPanelCoordinator
    private let controlPaletteCoordinator: ControlPaletteCoordinator?
    @AppStorage(L10n.languageDefaultsKey) private var languageRawValue = AppLanguage.system.rawValue

    init(
        store: ScanStore,
        computerHealthStore: ComputerHealthStore,
        panelSettingsState: MenuBarPanelSettingsState? = nil,
        panelCoordinator: GeekPanelCoordinator? = nil,
        controlPaletteCoordinator: ControlPaletteCoordinator? = nil
    ) {
        self.store = store
        self.computerHealthStore = computerHealthStore
        _panelSettingsState = StateObject(
            wrappedValue: panelSettingsState ?? MenuBarPanelSettingsState(
                initialDensity: .geek,
                isGeekEditorPresented: Self.shouldPresentGeekEditorOnLaunch
            )
        )
        _panelCoordinator = StateObject(
            wrappedValue: panelCoordinator ?? GeekPanelCoordinator()
        )
        self.controlPaletteCoordinator = controlPaletteCoordinator
    }

    var body: some View {
        MenuBarAdvancedStatusView(
            store: store,
            computerHealthStore: computerHealthStore,
            panelSettingsState: panelSettingsState,
            panelCoordinator: panelCoordinator,
            presentation: .geek,
            initialSection: .overview,
            onSectionChange: panelSettingsState.selectSection
        )
        // A live appearance update must not reset the chart clock, hover
        // corridor, or currently open detail stack.
        .id(languageRawValue)
        .environment(\.locale, L10n.locale)
        .environment(\.controlPaletteCoordinator, controlPaletteCoordinator)
        .modifier(PanelAppearanceEnvironment(forcedVisualMode: captureVisualMode))
        .onAppear {
            // Normalize preferences written by pre-1.9.2 releases without
            // reintroducing a second panel presentation at runtime.
            _ = PanelDensity.stored()
            Task {
#if DEBUG || STORAGE_CLEANER_BETA
                guard !MiniWindowDemoData.isEnabled else { return }
#endif
                await computerHealthStore.prepareMenuBarHealthOnLaunch()
            }
        }
    }

    private var captureVisualMode: MiniWindowVisualMode? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            switch MiniWindowDemoData.forcedColorScheme {
            case "light": return .graphite
            case "dark": return .black
            default: break
            }
        }
#endif
        return nil
    }

    static var shouldPresentGeekEditorOnLaunch: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--open-menu-bar-panel-geek-editor")
            || ProcessInfo.processInfo.arguments.contains("--open-menu-bar-panel-settings")
#else
        false
#endif
    }
}
