import SwiftUI

enum AppIconRole: Equatable {
    case toolbar
    case sidebar
    case panelNavigation
    case panelHeader
    case panelMode
    case inline
    case pageFeature
    case emptyState

    var glyphSize: CGFloat {
        switch self {
        case .toolbar, .inline, .sidebar: 16
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
        case .panelHeader, .panelMode: 24
        case .pageFeature: 32
        case .emptyState: 40
        }
    }

    var weight: Font.Weight {
        .regular
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
    static let headerSymbolGlyph: CGFloat = 22
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

    var body: some View {
        ZStack {
            Image(systemName: systemImage)
                .symbolRenderingMode(
                    role == .pageFeature || role == .emptyState ? .hierarchical : .monochrome
                )
                .font(.system(size: role.glyphSize, weight: role.weight))
                .foregroundStyle(tint)
        }
        .frame(width: role.frameSize, height: role.frameSize)
        .contentShape(Rectangle())
        .accessibilityHidden(isDecorative)
    }
}
