import AppKit
import SwiftUI

/// Shared pigments for native controls, module icons and monitoring data.
/// Surfaces and data stay separate, as in the reference monitor. These are
/// app-owned colors, not extracted vendor assets or a global appearance override.
enum MonitorPalette {
    static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xff) / 255,
              green: Double((rgb >> 8) & 0xff) / 255,
              blue: Double(rgb & 0xff) / 255)
    }

    static let blue = color(0x007AFF)
    static let pink = color(0xF74F9E)
    static let yellow = color(0xFFC600)
    static let cyan = color(0x20C7DB)
    static let green = color(0x68BE45)
    static let orange = color(0xFF922B)
    static let purple = color(0x9973EF)
    static let actionBlue = color(0x006BD6)
    static let blackShell = color(0x050505)
    static let blackCard = color(0x101010)
    static let blackBorder = color(0x303030)
    // sRGB samples of the reference's Dark Gray preview. A 10% black
    // inset over this shell resolves to its #232228 card at eight-bit depth.
    static let graphiteShell = color(0x27262D)
    static let graphiteCard = color(0x232228)
    static let graphiteCardOverlay = Color.black.opacity(0.10)
    static let graphiteBorder = color(0x3A3940)
    static let graphiteRingTrack = color(0x555459)
    static let blackRingTrack = color(0x333333)
    static let lightRingTrack = color(0xC7C7CA)
    static let lightShell = color(0xF3F2EF)
    static let lightCard = color(0xFCFCFA)
    static let lightBorder = color(0xD6D5D1)
    static let lightBlue = color(0x0068C9)
    static let lightPink = color(0xBD286D)
    static let lightYellow = color(0x906500)
    static let headerBlue = color(0x459DFF)
    static let secondaryText = color(0xC3C3C5)
    static let tertiaryText = color(0xA0A0A3)
}

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

    /// D53/D56: night values follow the canvas theme (`AppCanvasTheme.current`,
    /// cached), light values follow D63 daylight tokens. Only the canvas
    /// and sidebar tokens follow the theme: the cards, borders and text below
    /// are shared with the menu-bar mini window, which keeps its own look
    /// (D56: the mini window's night palette is out of scope). Main-window
    /// surfaces read the v2 set through `@AppSurfaces` instead.
    static func canvasAdaptive(
        light: UInt32,
        pureBlack: UInt32,
        deepSpace: UInt32,
        nightOpacity: Double = 1
    ) -> Color {
        let day = srgb(light, alpha: 1)
        let black = srgb(pureBlack, alpha: nightOpacity)
        let indigo = srgb(deepSpace, alpha: nightOpacity)
        return Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return day }
            return AppCanvasTheme.current == .deepSpace ? indigo : black
        })
    }

    private static func srgb(_ rgb: UInt32, alpha: Double) -> NSColor {
        NSColor(
            srgbRed: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            alpha: alpha
        )
    }

    private typealias Spec = AppDesignTokens.SurfaceSpec

    // Share the mini-panel's warm-white and clean-black surface hierarchy.
    // Blue marks controls and selection; category colors stay on data and icons.
    static let controlAccent = adaptive(light: 0x0068C9, dark: MonitorPalette.blue)
    static let controlFill = MonitorPalette.actionBlue
    static let secondarySurface = adaptive(light: 0xEBEBE7, dark: MonitorPalette.color(0x1C1C1C))
    static let hoverSurface = adaptive(light: 0xE7E7E3, dark: .white.opacity(0.07))
    static let accent = controlAccent
    static let selectedSurface = adaptive(light: 0xDFECFA, dark: MonitorPalette.color(0x102A44))
    static let selectedScopeSurface = adaptive(light: 0xEBF2F9, dark: .clear)
    // UI-V2-SPEC 1.1 canvases (D53, D56): deep space or pure black at night,
    // D63: the selected Morning Mist palette is identical in Debug and Release.
    static let canvasTop = canvasAdaptive(
        light: AppDaylightTheme.current.surfaceSpec.canvasTop, pureBlack: Spec.pureBlack.canvasTop, deepSpace: Spec.deepSpace.canvasTop
    )
    static let canvasBottom = canvasAdaptive(
        light: AppDaylightTheme.current.surfaceSpec.canvasBottom, pureBlack: Spec.pureBlack.canvasBottom, deepSpace: Spec.deepSpace.canvasBottom
    )
    /// The pre-D53 canvas, for chrome shared with the mini window and for
    /// Settings until V4.
    static let legacyCanvas = adaptive(light: 0xF3F2EF, dark: MonitorPalette.blackShell)
    static let legacyCanvasBottom = adaptive(light: 0xF0EFEC, dark: .black)
    static let ink = adaptive(light: 0x242426, dark: .white)
    static let secondaryText = adaptive(light: 0x535355, dark: MonitorPalette.secondaryText)
    static let tertiaryText = adaptive(light: 0x646466, dark: MonitorPalette.tertiaryText)
    static let panel = adaptive(light: 0xFCFCFA, dark: MonitorPalette.blackCard)
    static let border = adaptive(light: 0xD6D5D1, dark: MonitorPalette.blackBorder)
    static let illustrationTile = adaptive(light: 0xFCFCFA, dark: .black.opacity(0.34))
    static let tooltip = adaptive(light: 0xFCFCFA, dark: MonitorPalette.blackCard)
    static let sidebarTop = canvasAdaptive(
        light: AppDaylightTheme.current.surfaceSpec.sidebar, pureBlack: Spec.pureBlack.sidebar, deepSpace: Spec.deepSpace.sidebar
    )
    static let sidebarBottom = sidebarTop
    /// Settings keeps its sidebar until V4 restyles that window.
    static let settingsSidebarTop = adaptive(light: 0xEAE9E5, dark: MonitorPalette.color(0x141414))
    static let settingsSidebarBottom = settingsSidebarTop
    static let sidebarIcon = controlAccent
    static let amberMark = adaptive(light: 0x9F6510, dark: .orange)
    static let amberSurface = adaptive(light: 0xFFF0CC, dark: .clear)
}
