import SwiftUI

/// Presentation-only metadata for a main-window route.  It deliberately has
/// no knowledge of scanners, permissions, or cleanup operations.
enum ModulePresentationStyle: String, Hashable {
    case hero
    case management
    case dashboard
}

/// A category-level visual identity. Business outcome colors remain separate
/// in `AppDesignTokens.Palette` so a warning or a failure never masquerades
/// as module branding.
enum FeatureGroup: String, CaseIterable, Hashable, Identifiable {
    case smartScan = "smart-scan"
    case cleanup
    case protection
    case performance
    case applications
    case files
    case settings

    var id: String { rawValue }

}

enum SidebarGroup: String, CaseIterable, Identifiable {
    case cleanup
    case protection
    case performance
    case applications
    case files

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .cleanup:
            "sparkles"
        case .protection:
            "checkmark.shield.fill"
        case .performance:
            "gauge.with.dots.needle.67percent"
        case .applications:
            "square.stack.3d.up.fill"
        case .files:
            "folder.fill"
        }
    }

    var title: String {
        switch self {
        case .cleanup:
            L10n.text("清理", "CLEANUP")
        case .protection:
            L10n.text("保护", "PROTECTION")
        case .performance:
            L10n.text("性能", "PERFORMANCE")
        case .applications:
            L10n.text("应用", "APPLICATIONS")
        case .files:
            L10n.text("文件", "FILES")
        }
    }

    var expansionDefaultsKey: String {
        "mainWindow.sidebar.section.v2.\(rawValue).expanded"
    }
}

/// D53 module pigments (UI-V2-SPEC 1.2). The module-to-color mapping is
/// unchanged (D3, D44①); only the values are new. `bright` drives night
/// accents, the page glow and chart series. The gradient pair fills icon
/// tiles and primary buttons; both stops keep white labels at >= 4.5:1 in
/// both appearances (lighter end top-leading, darker end bottom-trailing).
struct ModulePigment: Equatable, Sendable {
    let bright: UInt32
    let gradientLight: UInt32
    let gradientDark: UInt32

    static let smartScan = ModulePigment(bright: 0x4C8DFF, gradientLight: 0x2B66F0, gradientDark: 0x1D4ED8)
    static let cleanup = ModulePigment(bright: 0xFF8A3D, gradientLight: 0xC44A16, gradientDark: 0xA13A0B)
    static let developer = ModulePigment(bright: 0xFFB547, gradientLight: 0xA85E0C, gradientDark: 0x8A4A06)
    static let protection = ModulePigment(bright: 0x3FC777, gradientLight: 0x1E8449, gradientDark: 0x136536)
    static let performance = ModulePigment(bright: 0xFF5FA2, gradientLight: 0xD6266E, gradientDark: 0xAD1653)
    static let memory = ModulePigment(bright: 0xA285FF, gradientLight: 0x7357E8, gradientDark: 0x5137C7)
    static let applications = memory
    static let files = ModulePigment(bright: 0x2CC9DD, gradientLight: 0x0E7C8C, gradientDark: 0x09616E)
    /// Settings and other neutral surfaces use the shared control blue.
    static let neutral = ModulePigment(bright: 0x007AFF, gradientLight: 0x006BD6, gradientDark: 0x0057B0)

    /// Destructive actions never take a module color (N19, D49).
    /// #DE2F38 is the brightest red that keeps a white label at 4.6:1; the
    /// suggested #FF5A5F would give 3.0:1 (review 6).
    static let danger = ModulePigment(bright: 0xFF5A5F, gradientLight: 0xDE2F38, gradientDark: 0xB71C28)

    var brightColor: Color { MonitorPalette.color(bright) }
    var lightStop: Color { MonitorPalette.color(gradientLight) }
    var darkStop: Color { MonitorPalette.color(gradientDark) }
    var gradientStops: [Color] { [lightStop, darkStop] }
}

struct ModuleTheme {
    let featureGroup: FeatureGroup
    let accent: Color
    let actionFill: Color
    let gradientStart: Color
    let gradientEnd: Color
    let darkGradientStart: Color
    let darkGradientEnd: Color
    let radialHighlight: Color
    let darkRadialHighlight: Color

    /// The main window has an immersive visual surface when this is true.
    /// Settings and sheets use the neutral default instead.
    let isImmersive: Bool

    /// D53 pigment: tile and button gradient, glow and chart color.
    var pigment: ModulePigment = .neutral

    var identifier: String { featureGroup.rawValue }
    var sidebarIconColor: Color { accent }
    var iconTint: Color { AppIconPalette.feature(featureGroup, night: accent) }
    var scanProgressColor: Color { accent }

    /// Icon tiles and primary buttons (UI-V2-SPEC 1.2). Both stops are opaque
    /// and keep the white label above 4.5:1, so the same pair serves both
    /// appearances.
    func actionGradient(for scheme: ColorScheme) -> [Color] {
        isImmersive ? pigment.gradientStops : [actionFill, actionFill]
    }

    /// The page glow and chart primary series: the bright pigment at night,
    /// the deeper gradient stop in daylight.
    var glowColor: Color {
        AppAppearanceColors.adaptive(light: pigment.gradientLight, dark: pigment.brightColor)
    }

    static let neutral = ModuleTheme(
        featureGroup: .settings,
        accent: AppAppearanceColors.controlAccent,
        actionFill: AppAppearanceColors.controlFill,
        gradientStart: Color(nsColor: .windowBackgroundColor),
        gradientEnd: Color(nsColor: .windowBackgroundColor),
        darkGradientStart: Color(nsColor: .windowBackgroundColor),
        darkGradientEnd: Color(nsColor: .windowBackgroundColor),
        radialHighlight: .clear,
        darkRadialHighlight: .clear,
        isImmersive: false
    )

    /// D53: module pages use the v2 canvas; neutral surfaces (Settings)
    /// keep the pre-D53 canvas until V4.
    func startColor(for colorScheme: ColorScheme) -> Color {
        isImmersive ? AppAppearanceColors.canvasTop : AppAppearanceColors.legacyCanvas
    }

    func endColor(for colorScheme: ColorScheme) -> Color {
        isImmersive ? AppAppearanceColors.canvasBottom : AppAppearanceColors.legacyCanvasBottom
    }

    var primaryText: Color { isImmersive ? AppAppearanceColors.ink : .primary }
    var secondaryText: Color { isImmersive ? AppAppearanceColors.secondaryText : AppDesignTokens.Palette.secondaryText }
    var tertiaryText: Color {
        isImmersive ? AppAppearanceColors.tertiaryText : AppDesignTokens.Palette.tertiaryText
    }

    func panelFill(for colorScheme: ColorScheme, reduceTransparency: Bool) -> Color {
        guard isImmersive else {
            return Color(nsColor: .windowBackgroundColor)
        }
        return AppAppearanceColors.panel
    }

    func panelBorder(for contrast: ColorSchemeContrast) -> Color {
        isImmersive
            ? (contrast == .increased
                ? AppAppearanceColors.ink.opacity(0.65)
                : AppAppearanceColors.border)
            : Color(nsColor: .separatorColor).opacity(contrast == .increased ? 1 : 0.65)
    }
}

private struct ModuleThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ModuleTheme.neutral
}

extension EnvironmentValues {
    var moduleTheme: ModuleTheme {
        get { self[ModuleThemeEnvironmentKey.self] }
        set { self[ModuleThemeEnvironmentKey.self] = newValue }
    }
}

enum ModuleThemeCatalog {
    static func theme(for filter: ReviewFilter) -> ModuleTheme {
        if filter == .memory {
            let base = theme(for: FeatureGroup.performance)
            return immersive(
                .performance,
                pigment: .memory,
                tone: .mauve,
                gradientStart: base.gradientStart, gradientEnd: base.gradientEnd,
                darkGradientStart: base.darkGradientStart, darkGradientEnd: base.darkGradientEnd
            )
        }
        if filter == .privacy {
            return immersive(
                .protection,
                pigment: .protection,
                tone: .sage,
                gradientStart: Color(red: 0.94, green: 0.98, blue: 0.98),
                gradientEnd: Color(red: 0.98, green: 0.99, blue: 1.0),
                darkGradientStart: Color(red: 0.045, green: 0.085, blue: 0.14),
                darkGradientEnd: Color(red: 0.04, green: 0.075, blue: 0.13)
            )
        }
        if filter == .devCaches {
            return immersive(
                .cleanup,
                pigment: .developer,
                tone: .ochre,
                gradientStart: Color(red: 0.99, green: 0.97, blue: 0.92),
                gradientEnd: Color(red: 1.0, green: 0.99, blue: 0.97),
                darkGradientStart: Color(red: 0.10, green: 0.09, blue: 0.065),
                darkGradientEnd: Color(red: 0.045, green: 0.048, blue: 0.055)
            )
        }
        return theme(for: filter.featureGroup)
    }

    static func theme(for featureGroup: FeatureGroup) -> ModuleTheme {
        guard featureGroup != .settings else { return .neutral }
        let pigment: ModulePigment
        let tone: AppIconTone
        switch featureGroup {
        case .smartScan: pigment = .smartScan; tone = .teal
        case .cleanup: pigment = .cleanup; tone = .clay
        case .protection: pigment = .protection; tone = .sage
        case .performance: pigment = .performance; tone = .mauve
        case .applications: pigment = .applications; tone = .mauve
        case .files: pigment = .files; tone = .teal
        case .settings: pigment = .neutral; tone = .bronze
        }
        let start = featureGroup == .protection
            ? Color(red: 0.055, green: 0.105, blue: 0.125)
            : Color(red: 0.065, green: 0.10, blue: 0.23)
        let end = featureGroup == .protection
            ? Color(red: 0.045, green: 0.075, blue: 0.09)
            : Color(red: 0.04, green: 0.065, blue: 0.16)
        return immersive(
            featureGroup,
            pigment: pigment,
            tone: tone,
            gradientStart: featureGroup == .protection
                ? Color(red: 0.94, green: 0.98, blue: 0.97)
                : Color(red: 0.94, green: 0.96, blue: 1.0),
            gradientEnd: featureGroup == .protection
                ? Color(red: 0.98, green: 0.99, blue: 0.98)
                : Color(red: 0.98, green: 0.98, blue: 1.0),
            darkGradientStart: start,
            darkGradientEnd: end
        )
    }

    private static func immersive(
        _ featureGroup: FeatureGroup,
        pigment: ModulePigment,
        tone: AppIconTone,
        gradientStart: Color,
        gradientEnd: Color,
        darkGradientStart: Color,
        darkGradientEnd: Color
    ) -> ModuleTheme {
        let accent = AppIconPalette.color(tone, night: pigment.brightColor)
        var theme = ModuleTheme(
            featureGroup: featureGroup,
            accent: accent,
            // The lighter gradient stop already keeps white labels readable;
            // native prominent buttons tint with it.
            actionFill: pigment.lightStop,
            gradientStart: gradientStart,
            gradientEnd: gradientEnd,
            darkGradientStart: darkGradientStart,
            darkGradientEnd: darkGradientEnd,
            radialHighlight: accent.opacity(0.10),
            darkRadialHighlight: accent.opacity(0.10),
            isImmersive: true
        )
        theme.pigment = pigment
        return theme
    }
}

extension ReviewFilter {
    var featureGroup: FeatureGroup {
        switch self {
        case .overview:
            .smartScan
        case .green, .devCaches:
            .cleanup
        case .privacy:
            .protection
        case .healthHub:
            .protection
        case .utilityHub:
            .settings
        case .performance, .startup, .memory, .energy:
            .performance
        case .uninstall, .updater:
            .applications
        case .largeFiles, .migration, .duplicates:
            .files
        }
    }

    var moduleTheme: ModuleTheme {
        ModuleThemeCatalog.theme(for: self)
    }

    var pagePresentationStyle: ModulePresentationStyle {
        switch self {
        case .overview, .healthHub, .green, .privacy:
            .hero
        case .performance:
            .dashboard
        case .devCaches, .largeFiles, .migration, .duplicates, .utilityHub, .startup, .memory, .energy, .uninstall, .updater:
            .management
        }
    }

    var sidebarGroup: SidebarGroup? {
        switch self {
        case .green, .devCaches:
            .cleanup
        case .healthHub, .privacy:
            .protection
        case .performance, .startup, .memory, .energy:
            .performance
        case .uninstall, .updater:
            .applications
        case .largeFiles, .migration, .duplicates:
            .files
        case .overview, .utilityHub:
            nil
        }
    }

    static func sidebarItems(in group: SidebarGroup) -> [ReviewFilter] {
        allCases.filter { $0.sidebarGroup == group }
    }
}
