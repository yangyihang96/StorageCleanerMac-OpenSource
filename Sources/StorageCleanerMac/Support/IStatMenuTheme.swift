import AppKit
import SwiftUI

/// D135: one color of an iStat Menus 7.30 dropdown theme, kept with the
/// constructor iStat calls (`colorWithWhite:alpha:`, `colorWithDeviceWhite:`,
/// `colorWithSRGBRed:`, `colorWithDeviceRed:`) so it draws the same.
enum IStatThemeColor: Equatable, Sendable {
    case white(CGFloat, alpha: CGFloat)
    case deviceWhite(CGFloat, alpha: CGFloat)
    case sRGB(CGFloat, CGFloat, CGFloat, alpha: CGFloat)
    case deviceRGB(CGFloat, CGFloat, CGFloat, alpha: CGFloat)
    case clear

    var nsColor: NSColor {
        switch self {
        case let .white(white, alpha): NSColor(white: white, alpha: alpha)
        case let .deviceWhite(white, alpha): NSColor(deviceWhite: white, alpha: alpha)
        case let .sRGB(red, green, blue, alpha): NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        case let .deviceRGB(red, green, blue, alpha): NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
        case .clear: .clear
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var alpha: CGFloat {
        switch self {
        case let .white(_, alpha), let .deviceWhite(_, alpha),
             let .sRGB(_, _, _, alpha), let .deviceRGB(_, _, _, alpha): alpha
        case .clear: 0
        }
    }

    /// Whether text in this color is dark (a light theme's text).
    var isDark: Bool {
        switch self {
        case let .white(white, _), let .deviceWhite(white, _): white < 0.5
        case let .sRGB(red, green, blue, _), let .deviceRGB(red, green, blue, _): (red + green + blue) / 3 < 0.5
        case .clear: false
        }
    }
}

/// D135: iStat Menus 7.30's dropdown themes (`+[BBRMenuTheme availableThemes]`).
/// A nil color is a property iStat leaves unset: no menu background, no
/// content fill, no card fill. An unset `border2` strokes in `border1`'s
/// color, because iStat's `[nil set]` keeps the color set just before.
struct IStatMenuTheme: Identifiable, Equatable, Sendable {
    let id: String
    let chineseName: String
    let englishName: String
    /// `vibrantMenu`: the window shows the system menu material.
    let vibrantMenu: Bool
    /// `vibrantMenuItems`: each card shows its own material.
    let vibrantMenuItems: Bool
    let menuBackground: IStatThemeColor?
    let menuContent: IStatThemeColor?
    let card: IStatThemeColor?
    let border1: IStatThemeColor?
    let border2: IStatThemeColor?
    let graphBorder: IStatThemeColor
    let label: IStatThemeColor
    let value: IStatThemeColor

    var name: String { L10n.text(chineseName, englishName) }

    /// Light themes draw dark text (iStat's light and light transparent).
    var isLight: Bool { value.isDark }

    /// `-[MenuContent drawRect:]` fills over `-[BBRMenuView drawRect:]`; no
    /// theme sets both, and the transparent ones set neither.
    var surface: IStatThemeColor { menuContent ?? menuBackground ?? .clear }

    /// An opaque surface for content that cannot sit on the material (a
    /// tooltip, Reduce Transparency): the non-transparent theme of the same
    /// lightness for the transparent ones.
    var opaqueSurface: IStatThemeColor {
        if surface.alpha >= 1 { return surface }
        return Self.theme(id: isLight ? "light" : "dark")?.surface ?? surface
    }

    static let defaultID = "indigo"
    /// 'system' (匹配系统外观) picks dark or light, transparent while the
    /// vibrancy preference is on.
    static let systemID = "system"

    static func theme(id: String) -> IStatMenuTheme? {
        all.first { $0.id == id }
    }

    /// `darkLabelColor`, `darkValueColor` (`whiteColor`).
    private static let darkLabel = IStatThemeColor.white(0.7, alpha: 1)
    private static let darkValue = IStatThemeColor.white(1, alpha: 1)
    /// The colored themes share everything but the menu background.
    private static func colored(
        _ id: String, _ chineseName: String, _ englishName: String,
        background: IStatThemeColor, card: IStatThemeColor = .deviceWhite(0, alpha: 0.1)
    ) -> IStatMenuTheme {
        IStatMenuTheme(
            id: id, chineseName: chineseName, englishName: englishName,
            vibrantMenu: false, vibrantMenuItems: false,
            menuBackground: background, menuContent: nil, card: card,
            border1: .clear, border2: .clear, graphBorder: .white(0.7, alpha: 0.35),
            label: .white(0.85, alpha: 1), value: darkValue
        )
    }

    /// In iStat's order. Names are iStat's ('MenuTheme.*' in BBRMenuKit.strings),
    /// except that iStat's Chinese renders Light as “指示灯” (indicator light);
    /// we write 亮.
    static let all: [IStatMenuTheme] = [
        IStatMenuTheme(
            id: "vibrant-dark", chineseName: "暗 (透明)", englishName: "Dark (Transparent)",
            vibrantMenu: true, vibrantMenuItems: true,
            menuBackground: .clear, menuContent: .clear, card: nil,
            border1: .white(0.8, alpha: 0.2), border2: .white(0, alpha: 0.9),
            graphBorder: .white(0.5, alpha: 0.35), label: .white(0.8, alpha: 1), value: darkValue
        ),
        IStatMenuTheme(
            id: "vibrant-light", chineseName: "亮 (透明)", englishName: "Light (Transparent)",
            vibrantMenu: true, vibrantMenuItems: true,
            menuBackground: .clear, menuContent: .clear, card: .deviceWhite(1, alpha: 0.1),
            border1: .white(0.5, alpha: 0.55), border2: .white(1, alpha: 1),
            graphBorder: .white(0.5, alpha: 0.35), label: .white(0, alpha: 0.65), value: .white(0, alpha: 0.8)
        ),
        IStatMenuTheme(
            id: "dark", chineseName: "暗", englishName: "Dark",
            vibrantMenu: false, vibrantMenuItems: false,
            menuBackground: nil, menuContent: .deviceWhite(0.07, alpha: 1), card: .white(0.065, alpha: 1),
            border1: .white(0.175, alpha: 0.2), border2: nil,
            graphBorder: .white(0.5, alpha: 0.35), label: darkLabel, value: darkValue
        ),
        IStatMenuTheme(
            id: "light", chineseName: "亮", englishName: "Light",
            vibrantMenu: false, vibrantMenuItems: false,
            menuBackground: .white(0.941176, alpha: 1), menuContent: nil, card: .deviceWhite(1, alpha: 0.55),
            border1: .white(0.5, alpha: 0.2), border2: .clear,
            graphBorder: .white(0.5, alpha: 0.35), label: .white(0, alpha: 0.65), value: .white(0, alpha: 0.8)
        ),
        colored("gray", "灰色", "Gray", background: .sRGB(0.2, 0.2, 0.22, alpha: 1),
                card: .deviceWhite(0.1, alpha: 0.15)),
        colored("darkgray", "深灰色", "Dark Gray", background: .sRGB(0.15, 0.15, 0.17, alpha: 1),
                card: .deviceWhite(0.1, alpha: 0.2)),
        colored("purple", "紫色", "Purple", background: .sRGB(0.337, 0.172, 0.429, alpha: 1)),
        colored("darkpurple", "深紫色", "Dark Purple", background: .sRGB(0.096, 0.057, 0.151, alpha: 1)),
        colored("indigo", "靛蓝色", "Indigo", background: .sRGB(0.188, 0.192, 0.379, alpha: 1)),
        colored("blue", "蓝色", "Blue", background: .sRGB(0.098, 0.247, 0.379, alpha: 1)),
        colored("cyan", "青色", "Cyan", background: .sRGB(0.058, 0.298, 0.379, alpha: 1)),
        colored("green", "绿色", "Green", background: .sRGB(0.094, 0.317, 0.305, alpha: 1)),
        IStatMenuTheme(
            id: "navy", chineseName: "海军蓝", englishName: "Navy",
            vibrantMenu: false, vibrantMenuItems: false,
            menuBackground: nil, menuContent: .sRGB(0.07, 0.11, 0.195, alpha: 1),
            card: .sRGB(0.09, 0.13, 0.233, alpha: 0.5),
            border1: .clear, border2: .clear,
            graphBorder: .white(0.5, alpha: 0.35), label: darkLabel, value: darkValue
        ),
        IStatMenuTheme(
            id: "blue-dark", chineseName: "深蓝色", englishName: "Dark Blue",
            vibrantMenu: false, vibrantMenuItems: false,
            menuBackground: nil, menuContent: .deviceRGB(0.072353, 0.091961, 0.132255, alpha: 1),
            card: .deviceRGB(0.082353, 0.101961, 0.157255, alpha: 0.6),
            border1: .clear, border2: .clear,
            graphBorder: .white(0.5, alpha: 0.35), label: darkLabel, value: darkValue
        ),
    ]

    /// The settings choices: 匹配系统外观 first, then iStat's themes.
    static let choiceIDs: [String] = [systemID] + all.map(\.id)

    static func choiceName(_ id: String) -> String {
        id == systemID ? L10n.text("匹配系统外观", "System Appearance") : theme(id: id)?.name ?? id
    }

    func chromePalette(accent: PanelAccentColors) -> PanelChromePalette {
        PanelChromePalette(
            shell: surface.color,
            card: card?.color ?? .clear,
            // A deviation of the single panel (D135): iStat's menus are
            // separate windows edged only by their shadows; attached levels
            // here share one window and keep a one-pixel separator.
            border: isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.12),
            text: value.color,
            secondaryText: label.color,
            tertiaryText: label.color,
            // iStat strokes a highlighted card and keeps its fill.
            selection: card?.color ?? .clear,
            accent: accent.primary,
            controlScheme: isLight ? .light : .dark,
            cardBorder1: border1?.color,
            cardBorder2: (border2 ?? border1)?.color,
            graphBorder: graphBorder.color,
            opaqueSurface: opaqueSurface.color,
            menuMaterialAppearance: vibrantMenu ? (isLight ? .vibrantLight : .vibrantDark) : nil,
            cardMaterial: vibrantMenuItems,
            accentColors: accent,
            themeID: id
        )
    }
}

/// D135: the stored theme pair, as iStat's `Menu.Theme.Dark`,
/// `Menu.Theme.Light` and `Menu.THeme.Vibrancy` (defaults indigo, indigo, on).
enum IStatMenuThemePreferences {
    static let darkThemeKey = "menuBar.menuTheme.dark.v1"
    static let lightThemeKey = "menuBar.menuTheme.light.v1"
    static let vibrancyKey = "menuBar.menuTheme.vibrancy.v1"

    /// The iStat Menus menu bar app's choice (0x10005e08c): the dark or the
    /// light key by appearance; 'system' becomes vibrant-dark / vibrant-light
    /// with vibrancy on, dark / light with it off; an unknown identifier
    /// falls back to dark / light (`themeWithIdentifier:`).
    static func theme(darkID: String, lightID: String, vibrancy: Bool, isDark: Bool) -> IStatMenuTheme {
        var id = isDark ? darkID : lightID
        // An empty setting is iStat's missing one: indigo.
        if id.isEmpty { id = IStatMenuTheme.defaultID }
        if id == IStatMenuTheme.systemID {
            id = vibrancy ? (isDark ? "vibrant-dark" : "vibrant-light") : (isDark ? "dark" : "light")
        }
        if let theme = IStatMenuTheme.theme(id: id) { return theme }
        return IStatMenuTheme.theme(id: isDark ? "dark" : "light") ?? IStatMenuTheme.all[0]
    }
}

/// D135: one choice of the settings' theme pickers: 'system' or a theme.
struct IStatMenuThemeChoice: Hashable, Identifiable, Sendable {
    let id: String

    static let all = IStatMenuTheme.choiceIDs.map(IStatMenuThemeChoice.init(id:))

    /// The stored identifier as a choice: the theme the panel uses for it
    /// (an empty setting is indigo, an unknown one dark or light); 'system'
    /// stays 'system'.
    static func stored(_ id: String, isDark: Bool) -> IStatMenuThemeChoice {
        if id == IStatMenuTheme.systemID { return IStatMenuThemeChoice(id: id) }
        let theme = IStatMenuThemePreferences.theme(darkID: id, lightID: id, vibrancy: false, isDark: isDark)
        return IStatMenuThemeChoice(id: theme.id)
    }

    var name: String { IStatMenuTheme.choiceName(id) }

    /// The swatch: the theme's surface, dimmed for a transparent theme;
    /// 'system' shows the theme it picks for the appearance.
    func swatch(isDark: Bool, vibrancy: Bool) -> Color {
        let theme = IStatMenuThemePreferences.theme(darkID: id, lightID: id, vibrancy: vibrancy, isDark: isDark)
        let color = theme.opaqueSurface.color
        return theme.vibrantMenu ? color.opacity(0.6) : color
    }
}

/// D135: iStat's accent-derived data colors (`-[BBRMenuAttributes accentColors]`,
/// `themeColors`, `updateAccentConfig`, `updateControlColor`).
struct PanelAccentColors: Equatable, Sendable {
    var primary: Color
    var secondary: Color
    var tertiary: Color
    /// Switches' on track and the prominent button.
    var control: Color
    var controlText: Color
    /// The table entry the system accent matched.
    var entryName: String
}

enum IStatAccentPalette {
    static let accentColors: [String: IStatThemeColor] = [
        "blue": .sRGB(0, 0.478431, 1, alpha: 1),
        "green": .sRGB(0.384314, 0.729412, 0.27451, alpha: 1),
        "pink": .sRGB(0.968627, 0.309804, 0.619608, alpha: 1),
        "purple": .sRGB(0.647059, 0.313725, 0.654902, alpha: 1),
        "red": .sRGB(1, 0.321569, 0.341176, alpha: 1),
        "yellow": .sRGB(1, 0.776471, 0, alpha: 1),
        "orange": .sRGB(0.968627, 0.509804, 0.105882, alpha: 1),
        "graphite": .sRGB(0.54902, 0.54902, 0.54902, alpha: 1),
    ]

    struct Entry: Equatable, Sendable {
        let name: String
        /// iStat's 'match', 'main' and 'primary' are this one color.
        let main: IStatThemeColor
        let secondary: IStatThemeColor
        let tertiary: IStatThemeColor
        /// 'controltext': black, otherwise white.
        let controlTextIsBlack: Bool
    }

    private static func accent(_ name: String) -> IStatThemeColor { accentColors[name] ?? .clear }

    /// In iStat's order; the first of equally near entries wins.
    static let entries: [Entry] = [
        Entry(name: "green", main: accent("green"), secondary: accent("pink"), tertiary: accent("blue"), controlTextIsBlack: true),
        Entry(name: "blue", main: accent("blue"), secondary: accent("pink"), tertiary: accent("yellow"), controlTextIsBlack: false),
        Entry(name: "red", main: accent("red"), secondary: accent("blue"), tertiary: accent("yellow"), controlTextIsBlack: false),
        Entry(name: "purple", main: accent("purple"), secondary: accent("blue"), tertiary: accent("yellow"), controlTextIsBlack: false),
        Entry(name: "yellow", main: accent("yellow"), secondary: accent("blue"), tertiary: accent("pink"), controlTextIsBlack: true),
        Entry(name: "pink", main: accent("pink"), secondary: accent("blue"), tertiary: accent("yellow"), controlTextIsBlack: false),
        Entry(name: "orange", main: accent("orange"), secondary: accent("blue"), tertiary: accent("pink"), controlTextIsBlack: false),
        Entry(name: "graphite", main: accent("graphite"), secondary: accent("blue"), tertiary: accent("pink"), controlTextIsBlack: false),
        Entry(name: "yellow-hardware", main: .sRGB(0.952941, 0.690196, 0.211765, alpha: 1),
              secondary: accent("blue"), tertiary: accent("pink"), controlTextIsBlack: true),
        Entry(name: "green-hardware", main: .sRGB(0.258824, 0.494118, 0.509804, alpha: 1),
              secondary: accent("pink"), tertiary: accent("blue"), controlTextIsBlack: true),
        Entry(name: "blue-hardware", main: .sRGB(0.313725, 0.466667, 0.568627, alpha: 1),
              secondary: accent("pink"), tertiary: accent("yellow"), controlTextIsBlack: false),
        Entry(name: "pink-hardware", main: .sRGB(0.803922, 0.337255, 0.352941, alpha: 1),
              secondary: accent("blue"), tertiary: accent("yellow"), controlTextIsBlack: false),
        Entry(name: "purple-hardware", main: .sRGB(0.364706, 0.384314, 0.568627, alpha: 1),
              secondary: accent("blue"), tertiary: accent("yellow"), controlTextIsBlack: false),
        Entry(name: "orange-hardware", main: .sRGB(0.937255, 0.501961, 0.337255, alpha: 1),
              secondary: accent("blue"), tertiary: accent("pink"), controlTextIsBlack: false),
    ]

    /// `darkpurple`'s fixed colors in `_MenuAttributes{Primary,Secondary,Tertiary}ColorWithKey`.
    static let darkPurplePrimary = IStatThemeColor.sRGB(0.082, 0.894, 0.988, alpha: 1)
    static let darkPurpleSecondary = IStatThemeColor.sRGB(0.992, 0.212, 0.212, alpha: 1)
    static let darkPurpleTertiary = IStatThemeColor.sRGB(0.427, 0.298, 0.91, alpha: 1)

    /// Components times 255 truncated, the distance truncated, and a strictly
    /// nearer entry replacing the current one, as `updateAccentConfig` does.
    static func nearestEntry(red: CGFloat, green: CGFloat, blue: CGFloat) -> Entry {
        let target = (Int(red * 255), Int(green * 255), Int(blue * 255))
        var best = Int.max
        var nearest = entries[0]
        for entry in entries {
            guard let color = entry.main.nsColor.usingColorSpace(.sRGB) else { continue }
            let dr = Double(target.0 - Int(color.redComponent * 255))
            let dg = Double(target.1 - Int(color.greenComponent * 255))
            let db = Double(target.2 - Int(color.blueComponent * 255))
            let distance = Int((dr * dr + dg * dg + db * db).squareRoot())
            if best > distance {
                best = distance
                nearest = entry
            }
        }
        return nearest
    }

    /// The colors for a system accent: the accent itself first, the matched
    /// entry's second and third colors; darkpurple's fixed three; the control
    /// color from the matched entry, blue's for graphite.
    static func colors(systemAccent: NSColor, themeID: String?) -> PanelAccentColors {
        let accent = systemAccent.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0.478431, blue: 1, alpha: 1)
        let entry = nearestEntry(red: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent)
        let controlEntry = entry.name == "graphite" ? (entries.first { $0.name == "blue" } ?? entry) : entry
        let darkPurple = themeID == "darkpurple"
        return PanelAccentColors(
            primary: darkPurple ? darkPurplePrimary.color : Color(nsColor: accent),
            secondary: (darkPurple ? darkPurpleSecondary : entry.secondary).color,
            tertiary: (darkPurple ? darkPurpleTertiary : entry.tertiary).color,
            control: controlEntry.main.color,
            controlText: controlEntry.controlTextIsBlack ? .black : .white,
            entryName: entry.name
        )
    }

    /// The accent of captures and test renders: macOS's default (blue),
    /// iStat's blue entry.
    static let fixtureAccent = NSColor(srgbRed: 0, green: 0.478431, blue: 1, alpha: 1)

    /// The colors for the current system accent.
    static func current(themeID: String?) -> PanelAccentColors {
        colors(systemAccent: .controlAccentColor, themeID: themeID)
    }
}

/// D135: the menu's material (`-[BBRMenu updateCurrentTheme]`: material 5,
/// the menu; blending 0, behind the window; state 1, active) or a card's
/// (`-[BBRMenuItem initWithFrame:]`: the default material), in the theme's
/// appearance.
struct IStatMenuMaterialBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material? = .menu
    let appearanceName: NSAppearance.Name

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = IStatPassthroughVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        if let material { view.material = material }
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: appearanceName)
    }
}

private final class IStatPassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
