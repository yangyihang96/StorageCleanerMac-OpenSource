import AppKit
import SwiftUI

enum PanelAppearancePreferences {
    static let colorThemeKey = "menuBar.panelColorTheme"
    static let backgroundColorKey = "menuBar.panelBackgroundColor"
    static let chartColorKey = "menuBar.panelChartColor"
    static let miniWindowAppearanceKey = "menuBar.miniWindowAppearance"

    static func color(from storedValue: String) -> Color? {
        guard let normalized = normalizedHex(storedValue),
              let value = UInt64(normalized.dropFirst(), radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func normalizedHex(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6,
              digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + digits.uppercased()
    }

    static func hexString(from color: Color) -> String? {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let components = [converted.redComponent, converted.greenComponent, converted.blueComponent]
            .map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", components[0], components[1], components[2])
    }
}

/// This setting applies only to the menu-bar cascade. An unset or `system`
/// value inherits the app appearance, which itself may follow macOS.
enum MiniWindowAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            L10n.text("跟随软件外观", "Follow App Appearance")
        case .light:
            L10n.text("日间石墨", "Day Graphite")
        case .dark:
            L10n.text("夜间近黑", "Night Black")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolvedPreferredColorScheme(
        miniWindowRawValue: String,
        appRawValue: String
    ) -> ColorScheme? {
        if let override = Self(rawValue: miniWindowRawValue), override != .system {
            return override.preferredColorScheme
        }
        return (AppAppearance(rawValue: appRawValue) ?? .system).preferredColorScheme
    }
}

/// Both mini-window palettes use dark controls and text. The visual mode only
/// selects the chrome: graphite in daylight, near-black at night.
enum MiniWindowVisualMode: Equatable {
    case graphite
    case black

    static func resolve(
        miniWindowRawValue: String,
        appRawValue: String,
        systemColorScheme: ColorScheme
    ) -> Self {
        let appearance = MiniWindowAppearance.resolvedPreferredColorScheme(
            miniWindowRawValue: miniWindowRawValue,
            appRawValue: appRawValue
        ) ?? systemColorScheme
        return appearance == .dark ? .black : .graphite
    }
}

private struct MiniWindowVisualModeKey: EnvironmentKey {
    static let defaultValue: MiniWindowVisualMode = .black
}

extension EnvironmentValues {
    var miniWindowVisualMode: MiniWindowVisualMode {
        get { self[MiniWindowVisualModeKey.self] }
        set { self[MiniWindowVisualModeKey.self] = newValue }
    }
}

extension AppAppearance {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum PanelColorTheme: String, CaseIterable, Identifiable {
    case system
    case ocean
    case violet
    case mint
    case graphite
    case custom

    var id: String { rawValue }

    var backgroundHex: String? {
        switch self {
        case .system, .custom:
            nil
        case .ocean:
            "#0A84FF"
        case .violet:
            "#5E5CE6"
        case .mint:
            "#00A896"
        case .graphite:
            "#48484A"
        }
    }

    var chartHex: String? {
        switch self {
        case .system, .custom:
            nil
        case .ocean:
            "#64D2FF"
        case .violet:
            "#BF5AF2"
        case .mint:
            "#63E6BE"
        case .graphite:
            nil
        }
    }

    static func resolved(
        storedTheme: String,
        backgroundHex: String,
        chartHex: String
    ) -> PanelColorTheme {
        if let stored = PanelColorTheme(rawValue: storedTheme) {
            return stored
        }

        let background = PanelAppearancePreferences.normalizedHex(backgroundHex)
        let chart = PanelAppearancePreferences.normalizedHex(chartHex)
        if background == nil, chart == nil {
            return .system
        }

        return allCases.first {
            $0 != .system && $0 != .custom &&
                $0.backgroundHex == background && $0.chartHex == chart
        } ?? .custom
    }

    static func resolvedBackgroundHex(
        storedTheme: String,
        customHex: String,
        chartHex: String
    ) -> String? {
        let theme = resolved(
            storedTheme: storedTheme,
            backgroundHex: customHex,
            chartHex: chartHex
        )
        return switch theme {
        case .system:
            nil
        case .custom:
            PanelAppearancePreferences.normalizedHex(customHex)
        default:
            theme.backgroundHex
        }
    }

    static func resolvedChartHex(
        storedTheme: String,
        backgroundHex: String,
        customHex: String
    ) -> String? {
        let theme = resolved(
            storedTheme: storedTheme,
            backgroundHex: backgroundHex,
            chartHex: customHex
        )
        return switch theme {
        case .system:
            nil
        case .custom:
            PanelAppearancePreferences.normalizedHex(customHex)
        default:
            theme.chartHex
        }
    }

    /// Built-in themes color the chart, not the panel surface. This keeps
    /// graphite chrome neutral in both appearances even with a violet graph.
    /// An explicitly chosen custom background remains available unchanged.
    static func backgroundTint(storedTheme: String, backgroundHex: String, chartHex: String) -> Color? {
        let theme = resolved(storedTheme: storedTheme, backgroundHex: backgroundHex, chartHex: chartHex)
        guard theme == .custom else { return nil }
        guard let color = PanelAppearancePreferences.color(from: resolvedBackgroundHex(
            storedTheme: storedTheme, customHex: backgroundHex, chartHex: chartHex
        ) ?? "") else { return nil }
        return color.opacity(MiniWindowStyleTokens.panelBackgroundTintOpacity)
    }

    /// Keep saved hues intact, but give the built-in pastel series a deeper
    /// daylight variant. A user's custom RGB value remains their choice.
    static func chartColor(storedTheme: String, backgroundHex: String, customHex: String) -> Color? {
        guard let color = PanelAppearancePreferences.color(from: resolvedChartHex(
            storedTheme: storedTheme, backgroundHex: backgroundHex, customHex: customHex
        ) ?? "") else { return nil }
        let theme = resolved(storedTheme: storedTheme, backgroundHex: backgroundHex, chartHex: customHex)
        let light: UInt32
        switch theme {
        case .ocean: light = 0x016CA6
        case .violet: light = 0x8733B4
        case .mint: light = 0x087663
        case .graphite: return nil
        case .system, .custom: return color
        }
        return AppAppearanceColors.adaptive(light: light, dark: color)
    }
}

private struct PanelBackgroundTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

private struct PanelChartAccentColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var panelBackgroundTint: Color? {
        get { self[PanelBackgroundTintKey.self] }
        set { self[PanelBackgroundTintKey.self] = newValue }
    }

    var panelChartAccentColor: Color? {
        get { self[PanelChartAccentColorKey.self] }
        set { self[PanelChartAccentColorKey.self] = newValue }
    }
}

/// Stable semantic data colors shared by the main monitor and menu-bar panels.
/// These colors describe data series, never page identity or selection state.
enum AppChartPalette {
    /// Warm activity series used when paired with the primary blue series.
    /// Kept stable across appearances so compact stacked bars remain legible.
    private static let activityRose = AppAppearanceColors.adaptive(
        light: 0xBD286D, dark: MonitorPalette.pink
    )
    private static let compressedGold = AppAppearanceColors.adaptive(
        light: 0x906500, dark: MonitorPalette.yellow
    )

    static let primary = AppDesignTokens.Palette.information
    static let secondary = AppDesignTokens.Palette.diagnostic
    static let cpu = AppDesignTokens.Palette.information
    static let cpuUser = AppDesignTokens.Palette.information
    static let cpuSystem = activityRose
    static let gpu = AppDesignTokens.Palette.information
    static let memory = AppDesignTokens.Palette.information
    static let memoryAppOrOther = AppDesignTokens.Palette.information
    static let memoryWired = activityRose
    static let memoryCompressed = compressedGold
    static let network = AppDesignTokens.Palette.information
    static let energy = AppDesignTokens.Palette.warning
    static let download = AppDesignTokens.Palette.information
    static let upload = activityRose
    static let storageUsed = AppDesignTokens.Palette.information
    static let storageAvailable = AppDesignTokens.Palette.success
    static let thermal = AppDesignTokens.Palette.information
    static let neutral = AppDesignTokens.Palette.secondaryText
    static let grid = AppDesignTokens.Palette.separator.opacity(0.42)
}
