import AppKit
import SwiftUI

enum AppDesignTokens {
    enum Palette {
        // A stable blue identifies primary controls in both appearances.
        // Metric, warning and destructive colors keep their own meaning.
        static let primary: Color = AppAppearanceColors.controlAccent
        static let secondary: Color = .indigo
        static let tertiary = AppAppearanceColors.adaptive(light: 0x087487, dark: .cyan)
        static let steadyChrome: Color = AppAppearanceColors.controlAccent
        static let technicalLine = tertiary

        static let primaryText = Color(nsColor: .labelColor)
        static let secondaryText = AppAppearanceColors.secondaryText
        static let tertiaryText = AppAppearanceColors.tertiaryText
        static let accent: Color = AppAppearanceColors.controlAccent
        static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)
        static let information = AppAppearanceColors.adaptive(light: 0x0068C9, dark: MonitorPalette.blue)
        static let destructive = AppAppearanceColors.adaptive(light: 0xC32C35, dark: .red)
        static let success = AppAppearanceColors.adaptive(light: 0x18753C, dark: .green)
        static let warning = AppAppearanceColors.adaptive(light: 0xA95300, dark: .orange)
        static let sensitive = AppAppearanceColors.adaptive(light: 0xB32C61, dark: .pink)
        // Battery health is informational capacity, not an error state.
        // Keep it visibly magenta-pink rather than sharing destructive red.
        static let batteryHealth = Color(
            red: 0.84,
            green: 0.24,
            blue: 0.62
        )
        static let diagnostic = AppAppearanceColors.adaptive(light: 0x7643B5, dark: .purple)
        static let storage = AppAppearanceColors.adaptive(light: 0x08776F, dark: .teal)
        static let freshness = AppAppearanceColors.adaptive(light: 0x11734F, dark: .mint)
        static let caution = AppAppearanceColors.adaptive(light: 0x805B00, dark: .yellow)

        /// Stable categorical colors for the storage map. These colors describe
        /// content type only; they intentionally do not reuse cleanup risk colors.
        enum StorageCategory {
            static let application = Color(red: 0.64, green: 0.39, blue: 0.91)
            static let image = Color(red: 0.92, green: 0.34, blue: 0.62)
            static let video = Color(red: 0.35, green: 0.43, blue: 0.91)
            static let audio = Color(red: 0.91, green: 0.56, blue: 0.22)
            static let document = Color(red: 0.22, green: 0.56, blue: 0.92)
            static let archive = Color(red: 0.69, green: 0.48, blue: 0.25)
            static let developer = Color(red: 0.12, green: 0.70, blue: 0.80)
            static let data = Color(red: 0.10, green: 0.63, blue: 0.54)
            static let system = Color(red: 0.43, green: 0.47, blue: 0.56)
            static let other = Color(red: 0.38, green: 0.66, blue: 0.48)
            static let measuredRemainder = Color(red: 0.42, green: 0.44, blue: 0.52)
            static let unmeasuredRemainder = Color(nsColor: .disabledControlTextColor)
        }

        // Popover chrome is shared with the mini window; it keeps the
        // pre-D53 canvas (D56: the mini window is out of scope).
        static let contentBackground = AppAppearanceColors.legacyCanvas
        static let secondaryBackground = AppAppearanceColors.secondarySurface
        static let selection = AppAppearanceColors.controlAccent
        static let focus = Color(nsColor: .keyboardFocusIndicatorColor)
        static let separator = AppAppearanceColors.border
        static let glassTint = AppAppearanceColors.controlAccent.opacity(0.08)
        static let artworkForeground = onAccent
        static let sidebarBackgroundStart = Color(nsColor: .windowBackgroundColor)
        static let sidebarBackgroundEnd = Color(nsColor: .windowBackgroundColor)
        static let sidebarPrimaryText = Color.primary
        static let sidebarSecondaryText = AppAppearanceColors.secondaryText
        static let sidebarHover = AppAppearanceColors.hoverSurface
        static let sidebarEdge = AppAppearanceColors.border
        static let sidebarSelection = AppAppearanceColors.controlAccent

        static func chartContrastSurface(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.black.opacity(0.45)
                : AppAppearanceColors.panel.opacity(0.90)
        }
    }

    typealias Typography = AppTypography

    enum Spacing {
        static let hairline: CGFloat = 2
        static let micro: CGFloat = 3
        static let compact: CGFloat = 4
        static let tight: CGFloat = 6
        static let small: CGFloat = 8
        static let regular: CGFloat = 10
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let section: CGFloat = 24
    }

    enum Layout {
        static let sidebarExpandedWidth: CGFloat = 196
        static let sidebarMinimumWidth: CGFloat = 196
        static let sidebarMaximumWidth: CGFloat = 228
        /// Primary feature workspaces use the complete detail region. Individual
        /// cards may still constrain prose locally, but the page itself must not
        /// float inside a second, narrower canvas when the window grows.
        static let taskPageMaxWidth: CGFloat = .infinity
        static let readablePageMaxWidth: CGFloat = .infinity
        static let settingsPageMaxWidth: CGFloat = 600
        static let pagePadding: CGFloat = 24
        static let pageSpacing: CGFloat = 14
        static let heroPadding: CGFloat = 20
        static let sectionPadding: CGFloat = 16
        static let compactPadding: CGFloat = 12
        static let textTightSpacing: CGFloat = 4
        static let textRegularSpacing: CGFloat = 6
        static let metadataPillHorizontalPadding: CGFloat = 8
        static let metadataPillVerticalPadding: CGFloat = 4
        static let pageHeaderSymbolFrame: CGFloat = 24
        static let pageHeaderHorizontalPadding: CGFloat = 14
        static let pageHeaderVerticalPadding: CGFloat = 12
        static let heroRadius: CGFloat = 20
        static let cardRadius: CGFloat = 16
        static let rowRadius: CGFloat = 10
        static let technicalGridSpacing: CGFloat = 32
        static let technicalGridMajorSpacing: CGFloat = 128
        static let technicalRuleHeight: CGFloat = 1
        static let moduleContentMaxWidth: CGFloat = 1_120
        static let integratedTitlebarHeight: CGFloat = 52
        static let sidebarTrafficLightClearance: CGFloat = 44
        /// D53: the main sidebar starts right below the toolbar band.
        static let sidebarTopInset: CGFloat = 6
        static let sidebarFooterHeight: CGFloat = 72
        static let sidebarRowHeight: CGFloat = 26
        static let toolbarButtonHorizontalPadding: CGFloat = 11
        static let segmentedOptionHorizontalPadding: CGFloat = 12
        static let segmentedOptionHeight: CGFloat = 24
        /// A stable landing-page slot keeps the title and primary action fixed
        /// whether a feature supplies a segmented control, summary, or no accessory.
        static let landingAccessorySlotHeight: CGFloat = 84
        static let modulePageHeaderMinimumHeight: CGFloat = 64
        static let modulePageHeaderIconFrame = AppIconRole.pageFeature.frameSize
    }

    enum Icon {
        static let sidebarHeader: CGFloat = 48
        static let sidebarRow: CGFloat = 40
        static let sidebarRowGlyph: CGFloat = 34
        static let settingsMetric: CGFloat = 34
        static let settingsMetricGlyph: CGFloat = 18
        static let settingsInline: CGFloat = 30
        static let settingsInlineGlyph: CGFloat = 17
        static let settingsNotice: CGFloat = 22
        static let settingsNoticeGlyph: CGFloat = 15
        static let settingsOption: CGFloat = 36
        static let settingsOptionGlyph: CGFloat = 19
        static let modulePageHeaderGlyph = AppIconRole.pageFeature.glyphSize
        static let sidebarDisclosureGlyph: CGFloat = 9
        static let sidebarNavigationGlyph: CGFloat = 16
        static let sidebarSettingsGlyph = AppIconRole.sidebar.glyphSize
        static let sheetHeaderGlyph: CGFloat = 28
        static let stateRingGlyphRatio: CGFloat = 0.32
    }

    enum Radius {
        static let sidebarHeaderIcon: CGFloat = 8
        static let sidebarRow: CGFloat = 8
        static let settingsMetricIcon: CGFloat = 8
        static let settingsInlineIcon: CGFloat = 8
        static let settingsOptionIcon: CGFloat = 8
        static let settingsTile: CGFloat = 10
        static let settingsPanel: CGFloat = 12
        static let panel: CGFloat = 12
        static let modulePanel: CGFloat = 14
        static let glassControl: CGFloat = 8
    }

    enum Elevation {
        static func contentShadow(
            elevated: Bool,
            colorScheme: ColorScheme,
            opacityInDark: Double,
            opacityInLight: Double
        ) -> Color {
            Color.black.opacity(
                elevated
                    ? (colorScheme == .dark ? opacityInDark : opacityInLight)
                    : 0
            )
        }

        static let floatingShadow = Color.black.opacity(0.25)
        static let prominentShadow = Color.black.opacity(0.16)
        static let standardShadow = Color.black.opacity(0.10)
        static let subtleShadow = Color.black.opacity(0.08)
    }

}

extension AppTypography {
    static let integratedTitlebar: Font = .system(size: 14, weight: .semibold)
    static let sidebarGroup: Font = .system(size: 10, weight: .medium)
    static let sidebarItem: Font = .system(size: 13, weight: .semibold)
    static let sidebarVersion: Font = .system(size: 10, weight: .medium)
}

// MARK: - UI 2.0 visual language v2 (DECISIONS D53, docs/2.0.0/UI-V2-SPEC.md)

/// The night canvas of the main window. D56 (the user chose after the V0
/// samples): deep space is the default; pure black stays selectable in
/// Settings › Interface, and a stored choice is always kept. The light
/// appearance uses D63 morning mist; comparison candidates exist only in Debug. The menu-bar
/// mini window keeps its own palette.
enum AppCanvasTheme: String, CaseIterable, Identifiable, Sendable {
    case pureBlack
    case deepSpace

    static let defaultsKey = "app.canvasTheme"
    static let defaultTheme: AppCanvasTheme = .deepSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pureBlack: L10n.text("纯黑", "Pure Black")
        case .deepSpace: L10n.text("深空", "Deep Space")
        }
    }

    /// A stored choice wins; nothing stored (or an unknown value) gets the
    /// D56 default. Users who picked pure black keep it.
    static func resolve(rawValue: String?) -> AppCanvasTheme {
        rawValue.flatMap(AppCanvasTheme.init(rawValue:)) ?? defaultTheme
    }

    static func resolve(defaults: UserDefaults) -> AppCanvasTheme {
        resolve(rawValue: defaults.string(forKey: defaultsKey))
    }

    /// Read by the legacy dynamic colors at draw time. Cached like
    /// `L10n.usesChinese` and invalidated by any defaults change, so drawing
    /// never reads UserDefaults. Views read `\.canvasTheme` instead.
    static var current: AppCanvasTheme {
        AppCanvasThemeCache.shared.value
    }

    /// Resolves the legacy dynamic colors with `theme` while `body` runs,
    /// without reading or writing any defaults domain (tests, previews).
    static func withCurrent<T>(_ theme: AppCanvasTheme, _ body: () throws -> T) rethrows -> T {
        AppCanvasThemeCache.shared.setOverride(theme)
        defer { AppCanvasThemeCache.shared.setOverride(nil) }
        return try body()
    }
}

private final class AppCanvasThemeCache: @unchecked Sendable {
    static let shared = AppCanvasThemeCache()

    private let lock = NSLock()
    private var cached: AppCanvasTheme?
    private var token: NSObjectProtocol?

    private init() {
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    private var override: AppCanvasTheme?

    func setOverride(_ theme: AppCanvasTheme?) {
        lock.lock()
        override = theme
        lock.unlock()
    }

    var value: AppCanvasTheme {
        lock.lock()
        defer { lock.unlock() }
        if let override { return override }
        if let cached { return cached }
        let resolved = AppCanvasTheme.resolve(defaults: .standard)
        cached = resolved
        return resolved
    }

    private func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}

private struct CanvasThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppCanvasTheme.defaultTheme
}

extension EnvironmentValues {
    /// Injected at the main window and Settings roots from `app.canvasTheme`.
    var canvasTheme: AppCanvasTheme {
        get { self[CanvasThemeEnvironmentKey.self] }
        set { self[CanvasThemeEnvironmentKey.self] = newValue }
    }
}

extension AppDesignTokens {
    /// Canvas, card and text values of one appearance (UI-V2-SPEC 1.1).
    /// Plain sRGB values so tests can check every contrast pair.
    struct SurfaceSpec: Equatable, Sendable {
        let canvasTop: UInt32
        let canvasBottom: UInt32
        let sidebar: UInt32
        let card: UInt32
        let cardOpacity: Double
        /// `card` composited over the canvas: used where translucency
        /// would read wrong (legacy panels, reduced transparency).
        let cardOpaque: UInt32
        let cardElevated: UInt32
        let inset: UInt32
        let textPrimary: UInt32
        let textSecondary: UInt32
        let textSecondaryIncreased: UInt32
        let textTertiary: UInt32
        /// White strokes at night, black strokes in daylight.
        let strokeIsLight: Bool
        let strokeTopOpacity: Double
        let strokeBottomOpacity: Double
        let strokeIncreasedOpacity: Double
        let dividerOpacity: Double
        let glowOpacity: Double
        let shadowOpacity: Double
        let shadowRadius: CGFloat
        let shadowY: CGFloat

        static let pureBlack = SurfaceSpec(
            canvasTop: 0x000000, canvasBottom: 0x000000, sidebar: 0x060607,
            card: 0x16171A, cardOpacity: 1, cardOpaque: 0x16171A,
            cardElevated: 0x1D1E22, inset: 0x212227,
            textPrimary: 0xF2F2F4, textSecondary: 0xA1A1AA,
            textSecondaryIncreased: 0xC8C8D0, textTertiary: 0x8E8E96,
            strokeIsLight: true, strokeTopOpacity: 0.16, strokeBottomOpacity: 0.05,
            strokeIncreasedOpacity: 0.24, dividerOpacity: 0.08,
            glowOpacity: 0.20, shadowOpacity: 0, shadowRadius: 0, shadowY: 0
        )

        static let deepSpace = SurfaceSpec(
            canvasTop: 0x10162E, canvasBottom: 0x0A0E20, sidebar: 0x0B1022,
            card: 0x161D3B, cardOpacity: 0.88, cardOpaque: 0x151B37,
            cardElevated: 0x1B2347, inset: 0x1F2752,
            textPrimary: 0xEEF1FA, textSecondary: 0xA3ABC6,
            textSecondaryIncreased: 0xC5CCE3, textTertiary: 0x8A93B2,
            strokeIsLight: true, strokeTopOpacity: 0.14, strokeBottomOpacity: 0.03,
            strokeIncreasedOpacity: 0.22, dividerOpacity: 0.07,
            glowOpacity: 0.22, shadowOpacity: 0, shadowRadius: 0, shadowY: 0
        )

        static let morningMist = AppDaylightTheme.morningMist.surfaceSpec

        static func spec(theme: AppCanvasTheme, scheme: ColorScheme,
                         daylightTheme: AppDaylightTheme = .current) -> SurfaceSpec {
            guard scheme == .dark else { return daylightTheme.surfaceSpec }
            return theme == .deepSpace ? .deepSpace : .pureBlack
        }
    }

    /// One resolved surface set for the current environment.
    struct SurfacePalette {
        let spec: SurfaceSpec
        let canvasTop: Color
        let canvasBottom: Color
        let sidebar: Color
        let card: Color
        let cardElevated: Color
        let inset: Color
        let strokeTop: Color
        let strokeBottom: Color
        let divider: Color
        let hover: Color
        let textPrimary: Color
        let textSecondary: Color
        let textTertiary: Color
        let highlight: Color
        let shadow: Color
        let glowOpacity: Double
        let isNight: Bool
    }

    enum Surface {
        static func color(_ rgb: UInt32, opacity: Double = 1) -> Color {
            Color(
                .sRGB,
                red: Double((rgb >> 16) & 0xff) / 255,
                green: Double((rgb >> 8) & 0xff) / 255,
                blue: Double(rgb & 0xff) / 255,
                opacity: opacity
            )
        }

        /// UI-V2-SPEC 1.1: reduced transparency makes cards opaque; increased
        /// contrast darkens strokes (white 20% / black 18%) and lifts
        /// secondary text by one step.
        static func palette(
            theme: AppCanvasTheme,
            scheme: ColorScheme,
            increasedContrast: Bool = false,
            reduceTransparency: Bool = false,
            daylightTheme: AppDaylightTheme = .current
        ) -> SurfacePalette {
            let spec = SurfaceSpec.spec(theme: theme, scheme: scheme, daylightTheme: daylightTheme)
            let ink: Color = spec.strokeIsLight ? .white : .black
            let card = reduceTransparency || spec.cardOpacity >= 1
                ? color(spec.cardOpaque)
                : color(spec.card, opacity: spec.cardOpacity)
            return SurfacePalette(
                spec: spec,
                canvasTop: color(spec.canvasTop),
                canvasBottom: color(spec.canvasBottom),
                sidebar: color(spec.sidebar),
                card: card,
                cardElevated: color(spec.cardElevated),
                inset: color(spec.inset),
                strokeTop: ink.opacity(increasedContrast ? spec.strokeIncreasedOpacity : spec.strokeTopOpacity),
                strokeBottom: ink.opacity(increasedContrast ? spec.strokeIncreasedOpacity : spec.strokeBottomOpacity),
                divider: ink.opacity(increasedContrast ? spec.strokeIncreasedOpacity : spec.dividerOpacity),
                hover: ink.opacity(spec.strokeIsLight ? 0.06 : 0.045),
                textPrimary: color(spec.textPrimary),
                textSecondary: color(increasedContrast ? spec.textSecondaryIncreased : spec.textSecondary),
                textTertiary: color(increasedContrast ? spec.textSecondary : spec.textTertiary),
                highlight: Color.white.opacity(spec.strokeIsLight ? 0.07 : 0.65),
                shadow: Color.black.opacity(spec.shadowOpacity),
                glowOpacity: spec.glowOpacity,
                isNight: scheme == .dark
            )
        }
    }

    /// UI-V2-SPEC 1.3. Four weights only: regular, medium, semibold, bold.
    enum TypeScale {
        /// Main session review of the V0 samples: 28–30 pt in large windows.
        static let pageTitleProminent: Font = .system(size: 30, weight: .bold)
        static let pageTitle: Font = .system(size: 28, weight: .bold)
        static let pageTitleRegular: Font = .system(size: 24, weight: .bold)
        static let pageTitleCompact: Font = .system(size: 20, weight: .semibold)
        static let subtitle: Font = .system(size: 14)
        static let sectionTitle: Font = .system(size: 15, weight: .semibold)
        static let body: Font = .system(size: 13)
        static let bodyEmphasis: Font = .system(size: 13, weight: .semibold)
        static let secondary: Font = .system(size: 12)
        static let secondaryEmphasis: Font = .system(size: 12, weight: .medium)
        /// The smallest size used anywhere in v2 components.
        static let caption: Font = .system(size: 11)
        static let captionEmphasis: Font = .system(size: 11, weight: .semibold)
        static let metricHero: Font = .system(size: 38, weight: .semibold, design: .rounded).monospacedDigit()
        static let metricCard: Font = .system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
        static let metricInline: Font = .system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
        static let sidebarItem: Font = .system(size: 13)
        static let sidebarItemSelected: Font = .system(size: 13, weight: .semibold)
        static let sidebarGroup: Font = .system(size: 11, weight: .semibold)
        static let sidebarGroupTracking: CGFloat = 0.3
        static let buttonLarge: Font = .system(size: 17, weight: .semibold)
        static let buttonHero: Font = .system(size: 18, weight: .semibold)
        static let buttonRegular: Font = .system(size: 13, weight: .semibold)
    }

    /// UI-V2-SPEC 1.4: an 8 pt grid (4 is the only half step).
    enum Grid {
        static let x0_5: CGFloat = 4
        static let x1: CGFloat = 8
        static let x1_5: CGFloat = 12
        static let x2: CGFloat = 16
        static let x2_5: CGFloat = 20
        static let x3: CGFloat = 24
        static let x4: CGFloat = 32
        static let x5: CGFloat = 40
    }

    /// UI-V2-SPEC 1.4 corner radii, all continuous.
    enum Corner {
        static let hero: CGFloat = 24
        static let card: CGFloat = 18
        static let inset: CGFloat = 12
        static let row: CGFloat = 10
        static let button: CGFloat = 12
        static let largeButton: CGFloat = 14

        /// Icon tiles round at 28% of their side.
        static func tile(side: CGFloat) -> CGFloat { (side * 0.28).rounded() }
    }
}

/// Reads the v2 surface set from the view's own environment, so a subtree
/// with an explicit color scheme (tests, previews) resolves correctly.
@MainActor
@propertyWrapper
struct AppSurfaces: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.canvasTheme) private var canvasTheme
    @Environment(\.daylightTheme) private var daylightTheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init() {}

    var wrappedValue: AppDesignTokens.SurfacePalette {
        AppDesignTokens.Surface.palette(
            theme: canvasTheme,
            scheme: colorScheme,
            increasedContrast: contrast == .increased,
            reduceTransparency: reduceTransparency,
            daylightTheme: daylightTheme
        )
    }
}
