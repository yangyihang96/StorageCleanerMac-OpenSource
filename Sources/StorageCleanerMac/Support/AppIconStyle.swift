import SwiftUI

/// Legacy tone names remain source-compatible. Daylight now derives from the
/// same pigment as night; an icon must not change from blue to brown when the
/// appearance changes. Data series and saved chart colors remain independent.
enum AppIconTone {
    case bronze
    case teal
    case ochre
    case sage
    case mauve
    case clay
    case fileGreen

}

enum AppIconPalette {
    static func color(_ tone: AppIconTone, night: Color) -> Color {
        AppAppearanceColors.adaptive(light: daylightRGB(for: night), dark: night)
    }

    /// A filled primary control keeps its module's pigment but needs a darker
    /// value than an icon or data series because its label is always white.
    /// Resolve once when a module theme is created; no preference or panel
    /// palette is changed by this presentation-only adjustment.
    static func actionFill(for pigment: Color) -> Color {
        let day = readableRGB(for: pigment, scheme: .light,
                              backgroundLuminance: 1, minimumContrast: 5.0)
        let night = readableRGB(for: pigment, scheme: .dark,
                                backgroundLuminance: 1, minimumContrast: 4.7)
        return AppAppearanceColors.adaptive(light: day, dark: MonitorPalette.color(night))
    }

    /// Lower brightness, not saturation or hue, to keep a small icon legible
    /// on the shared light card. Pure arithmetic: no preferences or system read.
    private static func daylightRGB(for pigment: Color) -> UInt32 {
        // D63: use the darkest candidate surface, preserving hue and a
        // rounding margin above 4.5:1 on every daylight background.
        readableRGB(for: pigment, scheme: .dark,
                    backgroundLuminance: minimumDaylightLuminance, minimumContrast: 4.6)
    }

    private static var minimumDaylightLuminance: Double {
        AppDaylightTheme.allCases.flatMap { theme in
            let spec = theme.surfaceSpec
            return [spec.canvasTop, spec.canvasBottom, spec.sidebar, spec.inset]
        }.map { rgb in
            func linear(_ channel: UInt32) -> Double {
                let value = Double(channel) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear((rgb >> 16) & 0xff) * 0.2126 + linear((rgb >> 8) & 0xff) * 0.7152 + linear(rgb & 0xff) * 0.0722
        }.min() ?? 0
    }

    private static func readableRGB(for pigment: Color, scheme: ColorScheme,
                                    backgroundLuminance: Double,
                                    minimumContrast: Double) -> UInt32 {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let resolved = pigment.resolve(in: environment)
        let channels = [Double(resolved.red), Double(resolved.green), Double(resolved.blue)]
        func luminance(_ scale: Double) -> Double {
            let linear = channels.map { channel -> Double in
                let value = min(1, max(0, channel * scale))
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let maximumLuminance = (backgroundLuminance + 0.05) / minimumContrast - 0.05
        var lower = 0.0, upper = 1.0
        for _ in 0..<10 {
            let middle = (lower + upper) / 2
            if luminance(middle) <= maximumLuminance { lower = middle } else { upper = middle }
        }
        let rgb = channels.map { UInt32((min(1, max(0, $0 * lower)) * 255).rounded()) }
        return (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]
    }

    static func feature(_ group: FeatureGroup, night: Color) -> Color {
        let tone: AppIconTone = switch group {
        case .smartScan, .cleanup: .ochre
        case .protection: .sage
        case .performance: .mauve
        case .applications: .clay
        case .files: .fileGreen
        case .settings: .bronze
        }
        return color(tone, night: night)
    }

    static func scope(_ group: FeatureGroup, index: Int, night: Color) -> Color {
        let tones: [AppIconTone] = switch group {
        case .smartScan: [.ochre, .clay, .sage]
        case .cleanup: [.ochre, .bronze, .mauve, .sage]
        case .protection: [.sage, .teal, .bronze, .clay]
        case .performance: [.mauve, .teal, .sage, .ochre]
        case .applications: [.clay, .mauve, .sage, .teal]
        case .files: [.fileGreen, .mauve, .ochre, .sage]
        case .settings: [.bronze, .mauve, .ochre, .teal]
        }
        return color(tones[max(0, index) % tones.count], night: night)
    }

    static func benchmark(_ category: BenchmarkV7Category, night: Color) -> Color {
        // The caller supplies one page accent for all categories. Give each
        // metric its own stable pigment so the legend remains distinguishable
        // in both appearances rather than only in daylight.
        let pigment: Color = switch category {
        case .cpu: MonitorPalette.blue
        case .gpu: MonitorPalette.pink
        case .memory: MonitorPalette.yellow
        case .storage: MonitorPalette.cyan
        case .display: MonitorPalette.purple
        case .sustained: MonitorPalette.orange
        }
        return color(.teal, night: pigment)
    }
}

enum AppIconRole: Equatable {
    case toolbar
    case sidebar
    case settingsNavigation
    case settingsInline
    case notice
    case panelNavigation
    case panelHeader
    case panelMode
    case inline
    case pageFeature
    case emptyState

    var glyphSize: CGFloat {
        switch self {
        case .toolbar, .inline, .sidebar, .settingsNavigation: 16
        case .settingsInline: AppDesignTokens.Icon.settingsInlineGlyph
        case .notice: AppDesignTokens.Icon.settingsNoticeGlyph
        case .panelNavigation, .panelHeader, .panelMode: 18
        case .pageFeature: 22
        case .emptyState: 32
        }
    }

    var frameSize: CGFloat {
        switch self {
        case .toolbar, .panelNavigation:
            AppControlSizes.iconHitRegion
        case .inline: 20
        case .sidebar: 18
        case .settingsNavigation: 22
        case .settingsInline: AppDesignTokens.Icon.settingsInline
        case .notice: AppDesignTokens.Icon.settingsNotice
        case .panelHeader, .panelMode: 24
        case .pageFeature: 32
        case .emptyState: 40
        }
    }

    var weight: Font.Weight {
        switch self {
        case .sidebar, .settingsNavigation, .notice: .semibold
        default: .regular
        }
    }
}

enum AppIconSizing {
    static let toolbar: CGFloat = AppIconRole.toolbar.frameSize
    static let sidebar: CGFloat = AppIconRole.sidebar.frameSize
    static let panelNavigation: CGFloat = AppIconRole.panelNavigation.frameSize
    static let panelMode: CGFloat = AppIconRole.panelMode.frameSize
    static let pageFeature: CGFloat = AppIconRole.pageFeature.frameSize
    static let emptyState: CGFloat = AppIconRole.emptyState.frameSize
    static let brand: CGFloat = 40
    static let installedApplication: CGFloat = 28
    static let compactHeroGlyph: CGFloat = 36
    static let compactHeroFrame: CGFloat = 64
}

/// Shared control geometry for list-heavy utility pages. Keeping this beside
/// icon roles prevents each feature from maintaining its own parallel sizing
/// table while preserving compact desktop density.
enum AppControlSizes {
    /// Default macOS controls are 28 pt high. Keep that native minimum while
    /// allowing long translated labels to grow vertically instead of colliding.
    static let minimumControlHeight: CGFloat = 28
    /// Minimum pointer and keyboard-focus target for icon-only macOS controls.
    /// The glyph remains optically compact inside this interaction region.
    static let iconHitRegion: CGFloat = 32
    static let pageMaxWidth = AppDesignTokens.Layout.readablePageMaxWidth
    static let pagePadding = AppDesignTokens.Layout.pagePadding
    static let listCornerRadius = AppDesignTokens.Layout.rowRadius
    static let headerIcon: CGFloat = 36
    static let headerSymbolGlyph = AppIconRole.pageFeature.glyphSize
    static let headerArtworkGlyph: CGFloat = 32
    static let previewIcon: CGFloat = 72
    static let previewCornerRadius: CGFloat = 14
    static let metricIcon = AppIconSizing.pageFeature
    static let metricGlyph: CGFloat = AppIconRole.pageFeature.glyphSize
    static let supportIcon: CGFloat = 40
    static let supportGlyph: CGFloat = 22
    static let rowIconFrame: CGFloat = 44
    static let rowIconGlyph: CGFloat = 32
    static let smallIcon: CGFloat = 32
    static let smallGlyph: CGFloat = 18
    static let emptyIcon = AppIconSizing.emptyState
    static let emptyGlyph: CGFloat = AppIconRole.emptyState.glyphSize
    static let rowActionWidth: CGFloat = 96
}

/// Functional icons always use the same SF Symbol rendering and optical frame.
/// Raster artwork is intentionally handled by `AppIconView` only in brand
/// positions so generated images cannot leak into toolbar or navigation UI.
struct AppSymbolIcon: View {
    let systemImage: String
    let role: AppIconRole
    var tint: Color = AppDesignTokens.Palette.secondaryText
    var isDecorative = false
    var renderingMode: SymbolRenderingMode? = nil

    var body: some View {
        AppSymbolGlyph(
            systemImage: systemImage,
            size: role.glyphSize,
            weight: role.weight,
            renderingMode: renderingMode ?? (role == .pageFeature || role == .emptyState ? .hierarchical : .monochrome)
        )
        .foregroundStyle(tint)
        .frame(width: role.frameSize, height: role.frameSize)
        .contentShape(Rectangle())
        .accessibilityHidden(isDecorative)
    }
}

/// Fit the visible symbol within a square independently of its font advance.
/// A folder and a tall trash can share one optical extent without distortion.
/// Callers retain their own layout slots, hit regions and semantic colours.
struct AppSymbolGlyph: View {
    let systemImage: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var renderingMode: SymbolRenderingMode = .monochrome

    var body: some View {
        Image(systemName: systemImage)
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(renderingMode)
            .font(.system(size: size, weight: weight))
            .frame(width: size, height: size, alignment: .center)
    }
}

enum AppSymbolGeometry {
    /// Explicit glyph requests are honoured whenever they fit. The legacy tile
    /// used to silently reduce 22 pt to 18 pt inside a 36 pt slot.
    static func tileGlyphSize(requested: CGFloat?, slot: CGFloat) -> CGFloat {
        guard slot.isFinite, slot > 0 else { return 0 }
        let proposed = requested.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? slot * 0.48
        return min(proposed, max(0, slot - 8))
    }
}
