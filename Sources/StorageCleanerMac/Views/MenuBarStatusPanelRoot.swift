import AppKit
import SwiftUI

struct PanelScene: View {
    let store: ScanStore
    let computerHealthStore: ComputerHealthStore
    @StateObject private var panelSettingsState: MenuBarPanelSettingsState
    @StateObject private var panelCoordinator: GeekPanelCoordinator
    private let controlPaletteCoordinator: ControlPaletteCoordinator?
    @AppStorage(L10n.languageDefaultsKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(L10n.appearanceDefaultsKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(PanelAppearancePreferences.miniWindowAppearanceKey) private var miniWindowAppearanceRawValue = ""
    @AppStorage(PanelAppearancePreferences.colorThemeKey) private var panelColorTheme = PanelColorTheme.graphite.rawValue
    @AppStorage(PanelAppearancePreferences.backgroundColorKey) private var panelBackgroundColor = ""
    @AppStorage(PanelAppearancePreferences.chartColorKey) private var panelChartColor = ""

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
        .environment(\.panelBackgroundTint, resolvedPanelBackgroundTint)
        .environment(\.panelChartAccentColor, resolvedPanelChartAccentColor)
        .preferredColorScheme(preferredColorScheme)
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

    private var preferredColorScheme: ColorScheme? {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            switch MiniWindowDemoData.forcedColorScheme {
            case "light": return .light
            case "dark": return .dark
            default: break
            }
        }
#endif
        if let appearance = MiniWindowAppearance(rawValue: miniWindowAppearanceRawValue) {
            return appearance.preferredColorScheme
        }

        // The first release with this dedicated setting preserves existing
        // app/panel preferences until the user explicitly chooses an option.
        switch AppAppearance(rawValue: appearanceRawValue) ?? .system {
        case .system:
            return resolvedPanelTheme == .graphite ? ColorScheme.dark : nil
        case .light:
            return ColorScheme.light
        case .dark:
            return ColorScheme.dark
        }
    }

    private var resolvedPanelTheme: PanelColorTheme {
        PanelColorTheme.resolved(
            storedTheme: panelColorTheme,
            backgroundHex: panelBackgroundColor,
            chartHex: panelChartColor
        )
    }

    private var resolvedPanelBackgroundTint: Color? {
        return PanelAppearancePreferences.color(
            from: PanelColorTheme.resolvedBackgroundHex(
                storedTheme: panelColorTheme,
                customHex: panelBackgroundColor,
                chartHex: panelChartColor
            ) ?? ""
        )?.opacity(MiniWindowStyleTokens.panelBackgroundTintOpacity)
    }

    private var resolvedPanelChartAccentColor: Color? {
        PanelColorTheme.chartColor(
            storedTheme: panelColorTheme,
            backgroundHex: panelBackgroundColor,
            customHex: panelChartColor
        )
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
