import AppKit
import SwiftUI

/// Reads the caller's defaultAppStorage domain. The live panel and Settings
/// share one resolver; preference changes never replace the content identity.
struct PanelAppearanceEnvironment: ViewModifier {
    @Environment(\.colorScheme) private var inheritedColorScheme
    @AppStorage(L10n.appearanceDefaultsKey) private var appAppearance = AppAppearance.system.rawValue
    @AppStorage(PanelAppearancePreferences.miniWindowAppearanceKey) private var miniAppearance = ""
    @AppStorage(PanelAppearancePreferences.colorThemeKey) private var chartTheme = PanelColorTheme.graphite.rawValue
    @AppStorage(PanelAppearancePreferences.backgroundColorKey) private var backgroundHex = ""
    @AppStorage(PanelAppearancePreferences.chartColorKey) private var chartHex = ""
    @AppStorage(PanelPalettePreferences.surfaceThemeKey) private var surfacePreset = ""
    @AppStorage(PanelPalettePreferences.statusThemeKey) private var statusPreset = ""
    @AppStorage(PanelPalettePreferences.statusCustomDayKey) private var statusDayHex = ""
    @AppStorage(PanelPalettePreferences.statusCustomNightKey) private var statusNightHex = ""

    // Only the live host passes a capture-only override. Settings resolves
    // ordinary user preferences in every build configuration, including Release.
    var forcedVisualMode: MiniWindowVisualMode? = nil

    init(forcedVisualMode: MiniWindowVisualMode? = nil) {
        self.forcedVisualMode = forcedVisualMode
    }

    private var visualMode: MiniWindowVisualMode {
        forcedVisualMode ?? MiniWindowVisualMode.resolve(miniWindowRawValue: miniAppearance,
            appRawValue: appAppearance, systemColorScheme: inheritedColorScheme)
    }
    private var chrome: PanelChromePalette? {
        PanelSurfacePreset(rawValue: surfacePreset)?.palette(for: visualMode)
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(chrome?.text ?? MiniWindowColorPalette.primaryText,
                             chrome?.secondaryText ?? MiniWindowColorPalette.secondaryText,
                             chrome?.tertiaryText ?? MiniWindowColorPalette.tertiaryText)
            .tint(chrome?.accent ?? MiniWindowColorPalette.blue)
            .environment(\.panelBackgroundTint, chrome == nil ? PanelColorTheme.backgroundTint(
                storedTheme: chartTheme, backgroundHex: backgroundHex, chartHex: chartHex) : nil)
            .environment(\.panelChartAccentColor, PanelColorTheme.chartColor(
                storedTheme: chartTheme, backgroundHex: backgroundHex, customHex: chartHex))
            .environment(\.panelStatusAppearance, PanelStatusAppearance(
                preset: PanelStatusColorPreset(rawValue: statusPreset) ?? .original,
                customDayHex: statusDayHex, customNightHex: statusNightHex,
                // Status items follow the menu bar, independently of panel chrome.
                isNight: inheritedColorScheme == .dark))
            .modifier(PanelMetricColorEnvironment())
            .environment(\.miniWindowVisualMode, visualMode)
            .environment(\.panelChromePalette, chrome)
            .environment(\.colorScheme, chrome?.controlScheme ?? .dark)
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
