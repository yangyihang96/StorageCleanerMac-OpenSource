import AppKit
import SwiftUI

/// The two selectors mirror the separation in a menu-bar monitor: the small
/// status item has its own ink, while the opened panel has its own surface.
/// Empty stored values retain the pre-2.0 palette without rewriting a user's
/// existing metric overrides or custom RGB preferences.
enum PanelPalettePreferences {
    static let statusThemeKey = "menuBar.statusColorPreset.v1"
    static let surfaceThemeKey = "menuBar.surfaceColorPreset.v1"
    static let statusCustomDayKey = "menuBar.statusCustomDayHex.v1"
    static let statusCustomNightKey = "menuBar.statusCustomNightHex.v1"
}

enum PanelStatusColorPreset: String, CaseIterable, Identifiable {
    case original, black, blue, graphite, yellow, orange, cyan, green, pink, purple, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: L10n.text("原有", "Original")
        case .black: L10n.text("黑色", "Black")
        case .blue: L10n.text("蓝色", "Blue")
        case .graphite: L10n.text("石墨", "Graphite")
        case .yellow: L10n.text("黄色", "Yellow")
        case .orange: L10n.text("橙色", "Orange")
        case .cyan: L10n.text("青色", "Cyan")
        case .green: L10n.text("绿色", "Green")
        case .pink: L10n.text("粉色", "Pink")
        case .purple: L10n.text("紫色", "Purple")
        case .custom: L10n.text("自定义", "Custom")
        }
    }

    /// Deliberately specified for both appearances. A single RGB value on a
    /// bright menu bar is either too pale, or too dim on a dark menu bar.
    func ink(dark: Bool, customDayHex: String = "", customNightHex: String = "") -> NSColor? {
        if self == .custom {
            let hex = dark ? customNightHex : customDayHex
            return PanelAppearancePreferences.color(from: hex).map(NSColor.init)
                ?? PanelStatusColorPreset.blue.ink(dark: dark)
        }
        let pair: (UInt32, UInt32) = switch self {
        case .original: (0, 0)
        case .black: (0x111111, 0xF7F7F7)
        case .blue: (0x146ACB, 0x53AAFF)
        case .graphite: (0x414247, 0xD3D4D8)
        case .yellow: (0x8A6500, 0xFFD24A)
        case .orange: (0xAD4F0C, 0xFFAA52)
        case .cyan: (0x087F9A, 0x58D5EE)
        case .green: (0x168044, 0x75D997)
        case .pink: (0xAF3B75, 0xFF8BC2)
        case .purple: (0x6743AD, 0xB69BFF)
        case .custom: (0, 0)
        }
        guard self != .original else { return nil }
        let rgb = dark ? pair.1 : pair.0
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                       green: CGFloat((rgb >> 8) & 0xff) / 255,
                       blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

struct PanelChromePalette {
    let shell: Color
    let card: Color
    let border: Color
    let text: Color
    let secondaryText: Color
    let tertiaryText: Color
    let selection: Color
    let accent: Color
    let controlScheme: ColorScheme
}

enum PanelSurfacePreset: String, CaseIterable, Identifiable {
    case original, ivory, white, graphite, black, navy, blue, teal, indigo, purple

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: L10n.text("原有", "Original")
        case .ivory: L10n.text("暖白", "Warm White")
        case .white: L10n.text("纯白", "White")
        case .graphite: L10n.text("石墨", "Graphite")
        case .black: L10n.text("纯黑", "Black")
        case .navy: L10n.text("深蓝", "Dark Blue")
        case .blue: L10n.text("蓝色", "Blue")
        case .teal: L10n.text("青墨", "Deep Teal")
        case .indigo: L10n.text("靛蓝", "Indigo")
        case .purple: L10n.text("暗紫", "Dark Purple")
        }
    }

    func palette(for mode: MiniWindowVisualMode) -> PanelChromePalette? {
        guard self != .original else { return nil }
        let night = mode == .black
        // These are independent day/night surfaces, not a color inversion.
        let shell: UInt32
        let card: UInt32
        let border: UInt32
        let isLight: Bool
        switch self {
        case .original: return nil
        case .ivory:
            (shell, card, border, isLight) = night
                ? (0x171716, 0x1D1D1B, 0x363633, false)
                : (0xF3F2EF, 0xFCFCFA, 0xD6D5D1, true)
        case .white:
            (shell, card, border, isLight) = night
                ? (0x161616, 0x1E1E1E, 0x363636, false)
                : (0xF0F0F0, 0xF8F8F8, 0xD5D5D5, true)
        case .graphite:
            (shell, card, border, isLight) = night
                ? (0x27262D, 0x232228, 0x3A3940, false)
                : (0x34333A, 0x2F2E33, 0x47464D, false)
        case .black:
            (shell, card, border, isLight) = night
                ? (0x050505, 0x101010, 0x303030, false)
                : (0x191919, 0x242424, 0x474747, false)
        case .navy:
            (shell, card, border, isLight) = night
                ? (0x101523, 0x141B2B, 0x2B364B, false)
                : (0x141623, 0x141926, 0x303441, false)
        case .blue:
            (shell, card, border, isLight) = night
                ? (0x0D263A, 0x113044, 0x2B465A, false)
                : (0x1B3F62, 0x183859, 0x375871, false)
        case .teal:
            (shell, card, border, isLight) = night
                ? (0x082429, 0x0B2C31, 0x2B484D, false)
                : (0x18514F, 0x174846, 0x315E60, false)
        case .indigo:
            (shell, card, border, isLight) = night
                ? (0x141526, 0x1B1D34, 0x353850, false)
                : (0x121C31, 0x151F38, 0x34415A, false)
        case .purple:
            (shell, card, border, isLight) = night
                ? (0x23132C, 0x2D1C35, 0x45304D, false)
                : (0x180E28, 0x170D23, 0x392941, false)
        }
        let accent = readableBlue(on: [shell, card], isLight: isLight)
        return PanelChromePalette(
            shell: Self.color(shell), card: Self.color(card), border: Self.color(border),
            text: Self.color(isLight ? 0x242426 : 0xF6F6F7),
            secondaryText: Self.color(isLight ? 0x535355 : 0xC3C3C5),
            tertiaryText: Self.color(isLight ? 0x646466 : 0xBDBDC0),
            selection: Self.color(isLight ? 0xDFECFA : 0x102A44),
            accent: Self.color(accent), controlScheme: isLight ? .light : .dark
        )
    }

    private static func color(_ rgb: UInt32) -> Color {
        MonitorPalette.color(rgb)
    }

    /// Text blue follows the surface's contrast, while graph pigments stay
    /// stable. No preferences are read and custom metric colors are untouched.
    private func readableBlue(on surfaces: [UInt32], isLight: Bool) -> UInt32 {
        func luminance(_ rgb: UInt32) -> Double {
            let components = [16, 8, 0].map { shift -> Double in
                let value = Double((rgb >> shift) & 0xff) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        }
        let candidates: [UInt32] = isLight
            ? [0x0068C9, 0x0055AD] : [0x007AFF, 0x459DFF, 0x74B6FF, 0x99CBFF, 0xC2E0FF]
        return candidates.first { candidate in
            let foreground = luminance(candidate)
            return surfaces.allSatisfy { surface in
                let background = luminance(surface)
                return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05) >= 4.5
            }
        } ?? (isLight ? 0x0055AD : 0xC2E0FF)
    }
}

/// Like the reference's surface strip, show the actual menu colors before
/// selecting them. This is a fixed drawing: no history, Store or timer.
struct PanelSurfacePresetPicker: View {
    @Binding var selection: PanelSurfacePreset

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("展开菜单底色", "Dropdown Surface"))
                .font(AppTypography.sectionTitle)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
                    ForEach(PanelSurfacePreset.allCases) { preset in
                        Button { selection = preset } label: {
                            VStack(spacing: 6) {
                                HStack(spacing: 2) {
                                    sample(preset, mode: .graphite)
                                    sample(preset, mode: .black)
                                }
                                Text(preset.title)
                                    .font(AppTypography.caption)
                                    .lineLimit(1)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity)
                            .background(selection == preset ? AppAppearanceColors.selectedSurface
                                        : AppAppearanceColors.secondarySurface,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selection == preset ? AppAppearanceColors.controlAccent
                                              : AppAppearanceColors.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.title)
                        .accessibilityValue(selection == preset ? L10n.text("已选中", "Selected") : "")
                        .accessibilityHint(L10n.text("应用此展开菜单配色；左日间，右夜间。",
                                                   "Apply this dropdown palette; day on the left, night on the right."))
                    }
                .padding(2)
            }
            .accessibilityLabel(L10n.text("展开菜单配色列表", "Dropdown color palettes"))
        }
    }

    private func sample(_ preset: PanelSurfacePreset, mode: MiniWindowVisualMode) -> some View {
        let palette = preset.palette(for: mode)
        let shell = palette?.shell ?? MiniWindowStyleTokens.shellColor(for: mode)
        let card = palette?.card ?? GeekVisualTokens.cardFill(for: .dark, visualMode: mode)
        let colors = PanelMetricColors(visualMode: mode, lightSurface: palette?.controlScheme == .light,
                                       surfaceAccent: palette?.accent)
        return VStack(alignment: .leading, spacing: 7) {
            Text("CPU").font(.system(size: 8)).foregroundStyle(colors.sectionHeader)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<7) { index in
                    VStack(spacing: 0) {
                        Rectangle().fill(colors.cpuSystem).frame(height: CGFloat(3 + index % 3))
                        Rectangle().fill(colors.cpuUser).frame(height: CGFloat(5 + index % 4))
                    }
                }
            }
            .frame(height: 17, alignment: .bottom)
        }
        .padding(4)
        .background(card, in: RoundedRectangle(cornerRadius: 4))
        .padding(3)
        .background(shell, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

private struct PanelChromePaletteKey: EnvironmentKey {
    static let defaultValue: PanelChromePalette? = nil
}

extension EnvironmentValues {
    var panelChromePalette: PanelChromePalette? {
        get { self[PanelChromePaletteKey.self] }
        set { self[PanelChromePaletteKey.self] = newValue }
    }
}

/// Static, side-by-side samples: they call the same status-icon renderer and
/// panel palette resolver as the live windows, but create no monitor or Store.
struct PanelPalettePairPreview: View {
    let statusPreset: PanelStatusColorPreset
    let surfacePreset: PanelSurfacePreset
    let graphTheme: PanelColorTheme
    let customChartHex: String
    let customBackgroundHex: String
    let statusCustomDayHex: String
    let statusCustomNightHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("模拟配色 · 非实时数据", "Color preview · Simulated data"))
                .font(AppTypography.caption)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { pair }
                VStack(spacing: 10) { pair }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("日间和夜间配色预览", "Day and night color previews"))
    }

    @ViewBuilder private var pair: some View {
        PanelPalettePreviewCard(mode: .graphite, statusPreset: statusPreset,
                                surfacePreset: surfacePreset, graphTheme: graphTheme,
                                customChartHex: customChartHex,
                                customBackgroundHex: customBackgroundHex,
                                statusCustomDayHex: statusCustomDayHex,
                                statusCustomNightHex: statusCustomNightHex)
        PanelPalettePreviewCard(mode: .black, statusPreset: statusPreset,
                                surfacePreset: surfacePreset, graphTheme: graphTheme,
                                customChartHex: customChartHex,
                                customBackgroundHex: customBackgroundHex,
                                statusCustomDayHex: statusCustomDayHex,
                                statusCustomNightHex: statusCustomNightHex)
    }
}

private struct PanelPalettePreviewCard: View {
    let mode: MiniWindowVisualMode
    let statusPreset: PanelStatusColorPreset
    let surfacePreset: PanelSurfacePreset
    let graphTheme: PanelColorTheme
    let customChartHex: String
    let customBackgroundHex: String
    let statusCustomDayHex: String
    let statusCustomNightHex: String

    private var isNight: Bool { mode == .black }
    private var chrome: PanelChromePalette? { surfacePreset.palette(for: mode) }
    private var shell: Color { chrome?.shell ?? MiniWindowStyleTokens.shellColor(for: mode) }
    private var card: Color {
        chrome?.card ?? GeekVisualTokens.cardFill(for: .dark, visualMode: mode)
    }
    private var ink: Color { chrome?.text ?? MiniWindowColorPalette.primaryText }
    private var muted: Color { chrome?.secondaryText ?? MiniWindowColorPalette.secondaryText }
    private var stroke: Color { chrome?.border ?? .white.opacity(0.14) }
    private var graphAccent: Color? {
        PanelColorTheme.chartColor(storedTheme: graphTheme.rawValue,
                                   backgroundHex: customBackgroundHex, customHex: customChartHex)
    }
    private var backgroundTint: Color? {
        guard chrome == nil else { return nil }
        return PanelColorTheme.backgroundTint(storedTheme: graphTheme.rawValue,
                                             backgroundHex: customBackgroundHex, chartHex: customChartHex)
    }

    private var statusImage: NSImage {
        let sample = MenuBarDeviceStatusSnapshot(
            batteryPercent: 78, isCharging: false, memoryUsedRatio: 0.64,
            wiFi: .connected(rssi: -61), batteryAvailability: .present
        )
        return MenuBarDeviceStatusDrawing.image(
            for: sample,
            appearance: NSAppearance(named: isNight ? .darkAqua : .aqua),
            statusPreset: statusPreset,
            statusCustomDayHex: statusCustomDayHex,
            statusCustomNightHex: statusCustomNightHex
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(isNight ? L10n.text("夜间", "Night") : L10n.text("日间", "Day"))
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                Image(nsImage: statusImage)
                    .frame(width: 28, height: 24)
            }
            .foregroundStyle(isNight ? Color.white : Color.black)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .background(isNight ? Color.black : Color.white,
                        in: RoundedRectangle(cornerRadius: 5))

            PanelPalettePreviewData(chartAccent: graphAccent)
            .padding(7)
            .background(card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(stroke, lineWidth: 0.5))
        }
        .foregroundStyle(ink, muted)
        .padding(8)
        .frame(width: 216, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(shell)
                .overlay {
                    if let backgroundTint { RoundedRectangle(cornerRadius: 10).fill(backgroundTint) }
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stroke, lineWidth: 0.5))
        .environment(\.miniWindowPreviewDate, MiniWindowConfigurationPreviewCard.history.last?.date)
        .modifier(PanelMetricColorEnvironment())
        .environment(\.miniWindowVisualMode, mode)
        .environment(\.panelChromePalette, chrome)
        .environment(\.colorScheme, chrome?.controlScheme ?? .dark)
    }
}

/// Uses the production chart and metric resolver, with immutable fixture data.
/// No Store, timer, monitor or hardware request is created by this preview.
private struct PanelPalettePreviewData: View {
    @Environment(\.panelMetricColors) private var colors
    let chartAccent: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CPU").foregroundStyle(colors.sectionHeader)
                Spacer(minLength: 2)
                Text("26%")
            }
            .font(.system(size: 11, weight: .semibold))
            GeekPrecisionLineChart(points: MiniWindowConfigurationPreviewCard.history,
                series: [
                    .init(id: "user", title: L10n.text("用户", "User"), channel: .cpuUser, color: colors.cpuUser),
                    .init(id: "system", title: L10n.text("系统", "System"), channel: .cpuSystem, color: colors.cpuSystem)
                ], valueRange: 0...100, unit: .percent,
                accessibilityLabel: L10n.text("模拟 CPU 配色", "Simulated CPU colors"),
                style: .stackedBars, duration: 3_600, showsLegend: false,
                showsTimelineLabels: false, horizontalInset: 0, showsSamplingDetails: false)
                .frame(height: 40)
            HStack(spacing: 4) {
                Circle().fill(colors.cpuUser).frame(width: 5, height: 5)
                Text(L10n.text("用户 18%", "User 18%"))
                Spacer(minLength: 2)
                Circle().fill(colors.cpuSystem).frame(width: 5, height: 5)
                Text(L10n.text("系统 8%", "System 8%"))
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("GPU").foregroundStyle(colors.sectionHeader)
                Capsule().fill(colors.gpu(chartAccent: chartAccent))
                    .frame(height: 4)
            }
            .font(.system(size: 10))
        }
    }
}
