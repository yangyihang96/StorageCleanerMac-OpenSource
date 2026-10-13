import Foundation
import SwiftUI

/// D63: the user selected Morning Mist. Debug and Release share one palette.
enum AppDaylightTheme: String, CaseIterable, Sendable {
    case morningMist = "morning-mist"
    static let current = AppDaylightTheme.morningMist

    var surfaceSpec: AppDesignTokens.SurfaceSpec {
        .init(canvasTop: 0xEDF3F9, canvasBottom: 0xE4EDF6, sidebar: 0xE7EFF7,
            card: 0xEDF3F9, cardOpacity: 1, cardOpaque: 0xEDF3F9, cardElevated: 0xEDF3F9, inset: 0xE1EAF3,
            textPrimary: 0x202C40, textSecondary: 0x495970,
            textSecondaryIncreased: 0x33445C, textTertiary: 0x526078,
            strokeIsLight: false, strokeTopOpacity: 0.055, strokeBottomOpacity: 0.055,
            strokeIncreasedOpacity: 0.18, dividerOpacity: 0.065,
            glowOpacity: 0.055, shadowOpacity: 0, shadowRadius: 0, shadowY: 0)
    }
}

private struct DaylightThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppDaylightTheme.current
}
extension EnvironmentValues {
    var daylightTheme: AppDaylightTheme {
        get { self[DaylightThemeEnvironmentKey.self] }
        set { self[DaylightThemeEnvironmentKey.self] = newValue }
    }
}
