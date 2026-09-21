import AppKit
import SwiftUI

/// Appearance-aware colors for the existing illustrated surfaces. Resolve at
/// drawing time, so the main window and an independently themed panel can be
/// visible together without reading global preferences or rebuilding stores.
enum AppAppearanceColors {
    static func adaptive(light: UInt32, dark: Color, lightOpacity: Double = 1) -> Color {
        let day = NSColor(
            srgbRed: Double((light >> 16) & 0xff) / 255,
            green: Double((light >> 8) & 0xff) / 255,
            blue: Double(light & 0xff) / 255,
            alpha: lightOpacity
        )
        let night = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? night : day
        })
    }

    static let ink = adaptive(light: 0x1C273A, dark: .white)
    static let secondaryText = adaptive(light: 0x4B576B, dark: .white.opacity(0.76))
    static let tertiaryText = adaptive(light: 0x596477, dark: .white.opacity(0.58))
    static let panel = adaptive(light: 0xFFFFFF, dark: .white.opacity(0.035), lightOpacity: 0.78)
    static let border = adaptive(light: 0x465675, dark: .white, lightOpacity: 0.75)
    static let illustrationTile = adaptive(light: 0xFFFFFF, dark: .black.opacity(0.34), lightOpacity: 0.80)
    static let tooltip = adaptive(light: 0xFCFDFF, dark: .black.opacity(0.88))
    static let sidebarTop = adaptive(light: 0xF2F5FA, dark: Color(red: 0.07, green: 0.085, blue: 0.12))
    static let sidebarBottom = adaptive(light: 0xE8EDF5, dark: Color(red: 0.045, green: 0.06, blue: 0.085))
}
