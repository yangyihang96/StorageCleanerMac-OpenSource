import AppKit
import SwiftUI

enum AppDesignTokens {
    enum Palette {
        // Brand emphasis follows the user's macOS accent choice. Functional
        // colors remain semantic so Light, Dark and increased-contrast modes
        // keep their native behavior.
        static let primary: Color = .accentColor
        static let secondary: Color = .indigo
        static let tertiary = AppAppearanceColors.adaptive(light: 0x087487, dark: .cyan)
        static let steadyChrome: Color = .accentColor
        static let technicalLine = tertiary

        static let primaryText = Color(nsColor: .labelColor)
        static let secondaryText = AppAppearanceColors.adaptive(light: 0x4B576B, dark: Color(nsColor: .secondaryLabelColor))
        static let tertiaryText = AppAppearanceColors.adaptive(light: 0x596477, dark: Color(nsColor: .tertiaryLabelColor))
        static let accent: Color = .accentColor
        static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)
        static let information = AppAppearanceColors.adaptive(light: 0x245BCC, dark: .blue)
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

        static let contentBackground = Color(nsColor: .windowBackgroundColor)
        static let secondaryBackground = Color(nsColor: .controlBackgroundColor)
        static let selection = Color(nsColor: .selectedContentBackgroundColor)
        static let focus = Color(nsColor: .keyboardFocusIndicatorColor)
        static let separator = Color(nsColor: .separatorColor)
        static let glassTint = Color.accentColor.opacity(0.08)
        static let artworkForeground = onAccent
        static let sidebarBackgroundStart = Color(nsColor: .windowBackgroundColor)
        static let sidebarBackgroundEnd = Color(nsColor: .windowBackgroundColor)
        static let sidebarPrimaryText = Color.primary
        static let sidebarSecondaryText = Color.secondary
        static let sidebarHover = Color.primary.opacity(0.06)
        static let sidebarEdge = Color(nsColor: .separatorColor)
        static let sidebarSelection = Color.accentColor

        static func chartContrastSurface(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.black.opacity(0.45)
                : Color.white.opacity(0.90)
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
        static let sidebarFooterHeight: CGFloat = 72
        static let sidebarRowHeight: CGFloat = 26
        static let toolbarButtonHorizontalPadding: CGFloat = 11
        static let segmentedOptionHorizontalPadding: CGFloat = 12
        static let segmentedOptionHeight: CGFloat = 24
        /// A stable landing-page slot keeps the title and primary action fixed
        /// whether a feature supplies a segmented control, summary, or no accessory.
        static let landingAccessorySlotHeight: CGFloat = 84
        static let modulePageHeaderMinimumHeight: CGFloat = 64
        static let modulePageHeaderIconFrame: CGFloat = 48
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
        static let modulePageHeaderGlyph: CGFloat = 24
        static let sidebarDisclosureGlyph: CGFloat = 9
        static let sidebarNavigationGlyph: CGFloat = 16
        static let sidebarSettingsGlyph: CGFloat = 15
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
