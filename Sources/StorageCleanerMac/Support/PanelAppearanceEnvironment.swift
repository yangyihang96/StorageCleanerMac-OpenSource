import AppKit
import SwiftUI

/// Reads the caller's defaultAppStorage domain. The live panel and Settings
/// share one resolver; preference changes never replace the content identity.
///
/// D135: the panel draws iStat's theme for the current appearance (the app's,
/// else the system's): `Menu.Theme.Dark` or `Menu.Theme.Light`, indigo by
/// default, with data colors derived from the system accent. The former
/// mini-window appearance, dropdown surface and chart color preferences stay
/// stored but no longer apply.
struct PanelAppearanceEnvironment: ViewModifier {
    @Environment(\.colorScheme) private var inheritedColorScheme
    @AppStorage(L10n.appearanceDefaultsKey) private var appAppearance = AppAppearance.system.rawValue
    @AppStorage(IStatMenuThemePreferences.darkThemeKey) private var darkThemeID = IStatMenuTheme.defaultID
    @AppStorage(IStatMenuThemePreferences.lightThemeKey) private var lightThemeID = IStatMenuTheme.defaultID
    @AppStorage(IStatMenuThemePreferences.vibrancyKey) private var vibrancy = true
    @AppStorage(PanelPalettePreferences.statusThemeKey) private var statusPreset = ""
    @AppStorage(PanelPalettePreferences.statusCustomDayKey) private var statusDayHex = ""
    @AppStorage(PanelPalettePreferences.statusCustomNightKey) private var statusNightHex = ""
    /// iStat recomputes its accent colors on `systemColorsChanged`.
    @State private var systemColorsGeneration = 0

    // Only the live host passes a capture-only override. Settings resolves
    // ordinary user preferences in every build configuration, including Release.
    var forcedVisualMode: MiniWindowVisualMode? = nil
    /// D135: a capture or test render (either override) pins the theme,
    /// iStat's default unless one is named, and the fixture accent, so the
    /// image depends neither on stored preferences nor on the system accent.
    var forcedThemeID: String? = nil

    init(forcedVisualMode: MiniWindowVisualMode? = nil, forcedThemeID: String? = nil) {
        self.forcedVisualMode = forcedVisualMode
        self.forcedThemeID = forcedThemeID
    }

    private var isFixture: Bool { forcedVisualMode != nil || forcedThemeID != nil }

    /// The appearance slot: graphite is the light appearance, black the dark.
    private var visualMode: MiniWindowVisualMode {
        forcedVisualMode ?? MiniWindowVisualMode.resolve(miniWindowRawValue: "",
            appRawValue: appAppearance, systemColorScheme: inheritedColorScheme)
    }
    private var theme: IStatMenuTheme {
        if isFixture {
            let id = forcedThemeID ?? IStatMenuTheme.defaultID
            return IStatMenuThemePreferences.theme(darkID: id, lightID: id, vibrancy: true, isDark: visualMode == .black)
        }
        return IStatMenuThemePreferences.theme(darkID: darkThemeID, lightID: lightThemeID,
                                               vibrancy: vibrancy, isDark: visualMode == .black)
    }
    private var chrome: PanelChromePalette {
        _ = systemColorsGeneration
        let theme = theme
        let accent = isFixture
            ? IStatAccentPalette.colors(systemAccent: IStatAccentPalette.fixtureAccent, themeID: theme.id)
            : IStatAccentPalette.current(themeID: theme.id)
        return theme.chromePalette(accent: accent)
    }

    func body(content: Content) -> some View {
        let chrome = chrome
        content
            .foregroundStyle(chrome.text, chrome.secondaryText, chrome.tertiaryText)
            .tint(chrome.accentColors?.control ?? chrome.accent)
            .environment(\.panelBackgroundTint, nil)
            .environment(\.panelChartAccentColor, nil)
            .environment(\.panelStatusAppearance, PanelStatusAppearance(
                preset: PanelStatusColorPreset(rawValue: statusPreset) ?? .original,
                customDayHex: statusDayHex, customNightHex: statusNightHex,
                // Status items follow the menu bar, independently of panel chrome.
                isNight: inheritedColorScheme == .dark))
            .modifier(PanelMetricColorEnvironment())
            .environment(\.miniWindowVisualMode, visualMode)
            .environment(\.panelChromePalette, chrome)
            .environment(\.colorScheme, chrome.controlScheme)
            .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in
                systemColorsGeneration &+= 1
            }
    }
}

struct PanelStatusAppearance: Sendable {
    var preset: PanelStatusColorPreset = .original
    var customDayHex = ""
    var customNightHex = ""
    var isNight = false

    var ink: Color {
        Color(nsColor: preset.ink(dark: isNight, customDayHex: customDayHex,
            customNightHex: customNightHex) ?? (isNight ? .white : .black))
    }
}

private struct PanelStatusAppearanceKey: EnvironmentKey {
    static let defaultValue = PanelStatusAppearance()
}
extension EnvironmentValues {
    var panelStatusAppearance: PanelStatusAppearance {
        get { self[PanelStatusAppearanceKey.self] }
        set { self[PanelStatusAppearanceKey.self] = newValue }
    }
}
