import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D135 (R9a): the panel draws iStat Menus 7.30's dropdown themes
/// (`+[BBRMenuTheme availableThemes]`), chosen per appearance
/// (`Menu.Theme.Dark` / `Menu.Theme.Light`, indigo by default), with data
/// colors derived from the system accent (`-[BBRMenuAttributes accentColors]`).
@MainActor
final class IStatMenuThemeTests: XCTestCase {
    private let blueAccent = NSColor(srgbRed: 0, green: 0.478431, blue: 1, alpha: 1)

    func testThemeListAndColorsAreIStats() throws {
        XCTAssertEqual(IStatMenuTheme.all.map(\.id), [
            "vibrant-dark", "vibrant-light", "dark", "light", "gray", "darkgray", "purple",
            "darkpurple", "indigo", "blue", "cyan", "green", "navy", "blue-dark",
        ])

        let vibrantDark = try theme("vibrant-dark")
        XCTAssertTrue(vibrantDark.vibrantMenu)
        XCTAssertTrue(vibrantDark.vibrantMenuItems)
        XCTAssertEqual(vibrantDark.menuBackground, .clear)
        XCTAssertEqual(vibrantDark.menuContent, .clear)
        XCTAssertNil(vibrantDark.card)
        XCTAssertEqual(vibrantDark.border1, .white(0.8, alpha: 0.2))
        XCTAssertEqual(vibrantDark.border2, .white(0, alpha: 0.9))
        XCTAssertEqual(vibrantDark.graphBorder, .white(0.5, alpha: 0.35))
        XCTAssertEqual(vibrantDark.label, .white(0.8, alpha: 1))
        XCTAssertEqual(vibrantDark.value, .white(1, alpha: 1))

        let vibrantLight = try theme("vibrant-light")
        XCTAssertTrue(vibrantLight.vibrantMenu)
        XCTAssertEqual(vibrantLight.card, .deviceWhite(1, alpha: 0.1))
        XCTAssertEqual(vibrantLight.border1, .white(0.5, alpha: 0.55))
        XCTAssertEqual(vibrantLight.border2, .white(1, alpha: 1))
        XCTAssertEqual(vibrantLight.label, .white(0, alpha: 0.65))
        XCTAssertEqual(vibrantLight.value, .white(0, alpha: 0.8))

        let dark = try theme("dark")
        XCTAssertFalse(dark.vibrantMenu)
        XCTAssertNil(dark.menuBackground)
        XCTAssertEqual(dark.menuContent, .deviceWhite(0.07, alpha: 1))
        XCTAssertEqual(dark.card, .white(0.065, alpha: 1))
        XCTAssertEqual(dark.border1, .white(0.175, alpha: 0.2))
        XCTAssertNil(dark.border2)
        XCTAssertEqual(dark.label, .white(0.7, alpha: 1))

        let light = try theme("light")
        XCTAssertEqual(light.menuBackground, .white(0.941176, alpha: 1))
        XCTAssertNil(light.menuContent)
        XCTAssertEqual(light.card, .deviceWhite(1, alpha: 0.55))
        XCTAssertEqual(light.border1, .white(0.5, alpha: 0.2))
        XCTAssertEqual(light.border2, .clear)
        XCTAssertEqual(light.label, .white(0, alpha: 0.65))
        XCTAssertEqual(light.value, .white(0, alpha: 0.8))

        XCTAssertEqual(try theme("gray").menuBackground, .sRGB(0.2, 0.2, 0.22, alpha: 1))
        XCTAssertEqual(try theme("gray").card, .deviceWhite(0.1, alpha: 0.15))
        XCTAssertEqual(try theme("darkgray").menuBackground, .sRGB(0.15, 0.15, 0.17, alpha: 1))
        XCTAssertEqual(try theme("darkgray").card, .deviceWhite(0.1, alpha: 0.2))
        let colored: [String: IStatThemeColor] = [
            "purple": .sRGB(0.337, 0.172, 0.429, alpha: 1),
            "darkpurple": .sRGB(0.096, 0.057, 0.151, alpha: 1),
            "indigo": .sRGB(0.188, 0.192, 0.379, alpha: 1),
            "blue": .sRGB(0.098, 0.247, 0.379, alpha: 1),
            "cyan": .sRGB(0.058, 0.298, 0.379, alpha: 1),
            "green": .sRGB(0.094, 0.317, 0.305, alpha: 1),
        ]
        for (id, background) in colored {
            let theme = try theme(id)
            XCTAssertEqual(theme.menuBackground, background, id)
            XCTAssertNil(theme.menuContent, id)
            XCTAssertEqual(theme.card, .deviceWhite(0, alpha: 0.1), id)
            XCTAssertEqual(theme.border1, .clear, id)
            XCTAssertEqual(theme.border2, .clear, id)
            XCTAssertEqual(theme.graphBorder, .white(0.7, alpha: 0.35), id)
            XCTAssertEqual(theme.label, .white(0.85, alpha: 1), id)
            XCTAssertEqual(theme.value, .white(1, alpha: 1), id)
        }
        for id in ["gray", "darkgray"] {
            XCTAssertEqual(try theme(id).graphBorder, .white(0.7, alpha: 0.35), id)
            XCTAssertEqual(try theme(id).label, .white(0.85, alpha: 1), id)
        }

        let navy = try theme("navy")
        XCTAssertEqual(navy.menuContent, .sRGB(0.07, 0.11, 0.195, alpha: 1))
        XCTAssertEqual(navy.card, .sRGB(0.09, 0.13, 0.233, alpha: 0.5))
        XCTAssertEqual(navy.graphBorder, .white(0.5, alpha: 0.35))
        XCTAssertEqual(navy.label, .white(0.7, alpha: 1))
        let darkBlue = try theme("blue-dark")
        XCTAssertEqual(darkBlue.menuContent, .deviceRGB(0.072353, 0.091961, 0.132255, alpha: 1))
        XCTAssertEqual(darkBlue.card, .deviceRGB(0.082353, 0.101961, 0.157255, alpha: 0.6))

        XCTAssertEqual(IStatMenuTheme.all.filter(\.isLight).map(\.id), ["vibrant-light", "light"])
        XCTAssertEqual(IStatMenuTheme.all.filter(\.vibrantMenu).map(\.id), ["vibrant-dark", "vibrant-light"])
    }

    /// iStat's names ('MenuTheme.*' in BBRMenuKit.strings), except its Chinese
    /// “指示灯” for Light.
    func testThemeNamesAreIStats() {
        XCTAssertEqual(IStatMenuTheme.all.map(\.englishName), [
            "Dark (Transparent)", "Light (Transparent)", "Dark", "Light", "Gray", "Dark Gray", "Purple",
            "Dark Purple", "Indigo", "Blue", "Cyan", "Green", "Navy", "Dark Blue",
        ])
        XCTAssertEqual(IStatMenuTheme.all.map(\.chineseName), [
            "暗 (透明)", "亮 (透明)", "暗", "亮", "灰色", "深灰色", "紫色",
            "深紫色", "靛蓝色", "蓝色", "青色", "绿色", "海军蓝", "深蓝色",
        ])
        XCTAssertFalse(IStatMenuTheme.all.contains { $0.chineseName.contains("指示灯") })
    }

    /// The menu bar app's choice: the dark or light key by appearance,
    /// 'system' made transparent by the vibrancy switch, an unknown theme
    /// falling back to dark / light and a missing one to indigo.
    func testThemeChoiceFollowsAppearanceAndVibrancy() {
        func id(_ dark: String, _ light: String, vibrancy: Bool, isDark: Bool) -> String {
            IStatMenuThemePreferences.theme(darkID: dark, lightID: light, vibrancy: vibrancy, isDark: isDark).id
        }
        XCTAssertEqual(IStatMenuTheme.defaultID, "indigo")
        XCTAssertEqual(id("navy", "light", vibrancy: true, isDark: true), "navy")
        XCTAssertEqual(id("navy", "light", vibrancy: true, isDark: false), "light")
        XCTAssertEqual(id("system", "system", vibrancy: true, isDark: true), "vibrant-dark")
        XCTAssertEqual(id("system", "system", vibrancy: true, isDark: false), "vibrant-light")
        XCTAssertEqual(id("system", "system", vibrancy: false, isDark: true), "dark")
        XCTAssertEqual(id("system", "system", vibrancy: false, isDark: false), "light")
        XCTAssertEqual(id("indigo", "cyan", vibrancy: false, isDark: true), "indigo", "Vibrancy only affects 'system'")
        XCTAssertEqual(id("vibrant-dark", "cyan", vibrancy: false, isDark: true), "vibrant-dark")
        XCTAssertEqual(id("bogus", "bogus", vibrancy: true, isDark: true), "dark")
        XCTAssertEqual(id("bogus", "bogus", vibrancy: true, isDark: false), "light")
        XCTAssertEqual(id("", "", vibrancy: true, isDark: true), "indigo")
        XCTAssertEqual(id("", "", vibrancy: true, isDark: false), "indigo")

        XCTAssertEqual(IStatMenuThemeChoice.all.map(\.id), ["system"] + IStatMenuTheme.all.map(\.id))
        // The pickers show the theme the panel uses for the stored setting.
        XCTAssertEqual(IStatMenuThemeChoice.stored("bogus", isDark: true).id, "dark")
        XCTAssertEqual(IStatMenuThemeChoice.stored("bogus", isDark: false).id, "light")
        XCTAssertEqual(IStatMenuThemeChoice.stored("", isDark: true).id, "indigo")
        XCTAssertEqual(IStatMenuThemeChoice.stored("", isDark: false).id, "indigo")
        XCTAssertEqual(IStatMenuThemeChoice.stored("navy", isDark: false).id, "navy")
        XCTAssertEqual(IStatMenuThemeChoice.stored("system", isDark: true).id, "system")
        XCTAssertEqual(IStatMenuThemeChoice.stored("system", isDark: false).id, "system")
        XCTAssertEqual(IStatMenuTheme.choiceName("navy"), IStatMenuTheme.theme(id: "navy")?.name)
    }

    /// The live panel, the control palettes and Settings read the same keys
    /// with iStat's defaults (indigo, indigo, vibrancy on).
    func testEveryReaderUsesTheSameKeysAndDefaults() throws {
        XCTAssertEqual(IStatMenuThemePreferences.darkThemeKey, "menuBar.menuTheme.dark.v1")
        XCTAssertEqual(IStatMenuThemePreferences.lightThemeKey, "menuBar.menuTheme.light.v1")
        XCTAssertEqual(IStatMenuThemePreferences.vibrancyKey, "menuBar.menuTheme.vibrancy.v1")
        let environment = try source("Sources/StorageCleanerMac/Support/PanelAppearanceEnvironment.swift")
        let settings = try source("Sources/StorageCleanerMac/Views/SettingsView.swift")
        for text in [environment, settings] {
            XCTAssertTrue(text.contains("@AppStorage(IStatMenuThemePreferences.darkThemeKey)"))
            XCTAssertTrue(text.contains("@AppStorage(IStatMenuThemePreferences.lightThemeKey)"))
            XCTAssertTrue(text.contains("@AppStorage(IStatMenuThemePreferences.vibrancyKey)"))
            XCTAssertEqual(text.components(separatedBy: "= IStatMenuTheme.defaultID").count - 1, 2)
            XCTAssertTrue(text.contains("Vibrancy = true") || text.contains("vibrancy = true"))
        }
        // A changed system accent re-derives the colors, as iStat's
        // `systemColorsChanged` runs `updateAccentConfig` and `updateControlColor`;
        // the system setting is not changed here.
        XCTAssertTrue(environment.contains(".onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification))"))
        XCTAssertTrue(environment.contains("systemColorsGeneration &+= 1"))
        XCTAssertTrue(environment.contains("_ = systemColorsGeneration"))
        let palette = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/ControlPaletteViews.swift")
        XCTAssertTrue(palette.contains(".modifier(PanelAppearanceEnvironment())"))
        XCTAssertFalse(palette.contains("PanelSurfacePreset(rawValue:"))
        let general = try source("Sources/StorageCleanerMac/Views/Settings/SettingsGeneral.swift")
        XCTAssertTrue(general.contains("items: IStatMenuThemeChoice.all, selection: menuThemeBinding($menuThemeDarkID, isDark: true)"))
        XCTAssertTrue(general.contains("items: IStatMenuThemeChoice.all, selection: menuThemeBinding($menuThemeLightID, isDark: false)"))
        XCTAssertTrue(general.contains("isOn: $menuThemeVibrancy"))
    }

    /// `updateAccentConfig`: components times 255 truncated, the distance
    /// truncated, a strictly nearer entry replacing the current one.
    func testAccentEntryMatchingTruncatesAsIStatDoes() throws {
        XCTAssertEqual(IStatAccentPalette.entries.map(\.name), [
            "green", "blue", "red", "purple", "yellow", "pink", "orange", "graphite",
            "yellow-hardware", "green-hardware", "blue-hardware", "pink-hardware", "purple-hardware", "orange-hardware",
        ])
        for entry in IStatAccentPalette.entries {
            let color = try XCTUnwrap(entry.main.nsColor.usingColorSpace(.sRGB))
            XCTAssertEqual(IStatAccentPalette.nearestEntry(
                red: color.redComponent, green: color.greenComponent, blue: color.blueComponent
            ).name, entry.name)
        }
        // (0, 0, 183) is 140.62 from purple-hardware and 140.80 from blue:
        // both truncate to 140, so the earlier entry, blue, stays.
        XCTAssertEqual(IStatAccentPalette.nearestEntry(red: 0.5 / 255, green: 0.5 / 255, blue: 183.5 / 255).name, "blue")
        // The components truncate: (0.6, 10.6, 180.6) / 255 reads (0, 10, 180),
        // 133 from both blue and purple-hardware (blue stays); rounded,
        // (1, 11, 181) would be nearer purple-hardware.
        XCTAssertEqual(IStatAccentPalette.nearestEntry(red: 0.6 / 255, green: 10.6 / 255, blue: 180.6 / 255).name, "blue")
    }

    func testAccentColorsDeriveFromTheSystemAccent() throws {
        let blue = IStatAccentPalette.colors(systemAccent: blueAccent, themeID: "indigo")
        XCTAssertEqual(blue.entryName, "blue")
        try assertColor(blue.primary, equals: blueAccent)
        try assertColor(blue.secondary, equals: accent("pink"))
        try assertColor(blue.tertiary, equals: accent("yellow"))
        try assertColor(blue.control, equals: blueAccent)
        try assertColor(blue.controlText, equals: .white)

        // A custom accent is itself the first color; the nearest entry gives
        // the other two and the control color.
        let custom = NSColor(srgbRed: 0.9, green: 0.75, blue: 0.05, alpha: 1)
        let yellow = IStatAccentPalette.colors(systemAccent: custom, themeID: nil)
        XCTAssertEqual(yellow.entryName, "yellow")
        try assertColor(yellow.primary, equals: custom)
        try assertColor(yellow.secondary, equals: accent("blue"))
        try assertColor(yellow.tertiary, equals: accent("pink"))
        try assertColor(yellow.control, equals: accent("yellow"))
        try assertColor(yellow.controlText, equals: .black)

        // `updateControlColor` uses blue's entry for graphite.
        let graphite = IStatAccentPalette.colors(systemAccent: accent("graphite"), themeID: nil)
        XCTAssertEqual(graphite.entryName, "graphite")
        try assertColor(graphite.control, equals: blueAccent)
        try assertColor(graphite.controlText, equals: .white)
        try assertColor(graphite.secondary, equals: accent("blue"))

        // darkpurple fixes its three colors; the control color still follows the accent.
        let darkPurple = IStatAccentPalette.colors(systemAccent: blueAccent, themeID: "darkpurple")
        try assertColor(darkPurple.primary, equals: NSColor(srgbRed: 0.082, green: 0.894, blue: 0.988, alpha: 1))
        try assertColor(darkPurple.secondary, equals: NSColor(srgbRed: 0.992, green: 0.212, blue: 0.212, alpha: 1))
        try assertColor(darkPurple.tertiary, equals: NSColor(srgbRed: 0.427, green: 0.298, blue: 0.91, alpha: 1))
        try assertColor(darkPurple.control, equals: blueAccent)
    }

    func testMetricColorsTakeTheirAccentRoleAndStoredColorsStillWin() throws {
        let accent = PanelAccentColors(primary: .red, secondary: .green, tertiary: .blue,
                                       control: .orange, controlText: .white, entryName: "test")
        // No light variants and no graphite header under a theme.
        let colors = PanelMetricColors(visualMode: .graphite, lightSurface: true, accentColors: accent)
        for color in [colors.sectionHeader, colors.cpuUser, colors.gpu, colors.memoryPressure, colors.memoryApp,
                      colors.swap, colors.diskWrite, colors.networkDownload, colors.sensorGraph,
                      colors.battery, colors.batteryCharging] {
            XCTAssertEqual(color, .red)
        }
        for color in [colors.cpuSystem, colors.memoryWired, colors.diskRead, colors.networkUpload,
                      colors.batteryHealth, colors.batteryDraining] {
            XCTAssertEqual(color, .green)
        }
        XCTAssertEqual(colors.memoryCompressed, .blue)
        let custom = PanelMetricColors(accentColors: accent, cpuUser: "#123456")
        try assertColor(custom.cpuUser, equals: NSColor(srgbRed: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0, alpha: 1))
        XCTAssertEqual(custom.cpuSystem, .green)
    }

    func testChromePaletteCarriesTheThemesColors() throws {
        let accent = IStatAccentPalette.colors(systemAccent: blueAccent, themeID: "indigo")
        let indigo = try theme("indigo").chromePalette(accent: accent)
        try assertColor(indigo.shell, equals: IStatThemeColor.sRGB(0.188, 0.192, 0.379, alpha: 1).nsColor)
        try assertColor(indigo.card, equals: IStatThemeColor.deviceWhite(0, alpha: 0.1).nsColor)
        try assertColor(indigo.selection, equals: IStatThemeColor.deviceWhite(0, alpha: 0.1).nsColor,
                        "iStat strokes a highlighted card and keeps its fill")
        try assertColor(indigo.text, equals: .white)
        try assertColor(indigo.secondaryText, equals: IStatThemeColor.white(0.85, alpha: 1).nsColor)
        try assertColor(XCTUnwrap(indigo.graphBorder), equals: IStatThemeColor.white(0.7, alpha: 0.35).nsColor)
        try assertColor(XCTUnwrap(indigo.cardBorder1), equals: .clear)
        try assertColor(indigo.accent, equals: blueAccent)
        XCTAssertEqual(indigo.controlScheme, .dark)
        XCTAssertNil(indigo.menuMaterialAppearance)
        XCTAssertFalse(indigo.cardMaterial)
        XCTAssertEqual(indigo.accentColors, accent)
        XCTAssertEqual(indigo.themeID, "indigo")

        let light = try theme("light").chromePalette(accent: accent)
        XCTAssertEqual(light.controlScheme, .light)
        try assertColor(XCTUnwrap(light.opaqueSurface), equals: IStatThemeColor.white(0.941176, alpha: 1).nsColor)

        // border2 nil: iStat's `[nil set]` leaves border1 as the stroke color.
        let dark = try theme("dark").chromePalette(accent: accent)
        try assertColor(XCTUnwrap(dark.cardBorder2), equals: IStatThemeColor.white(0.175, alpha: 0.2).nsColor)

        let vibrantDark = try theme("vibrant-dark").chromePalette(accent: accent)
        XCTAssertEqual(vibrantDark.menuMaterialAppearance, .vibrantDark)
        XCTAssertTrue(vibrantDark.cardMaterial)
        try assertColor(vibrantDark.shell, equals: .clear)
        try assertColor(vibrantDark.card, equals: .clear)
        try assertColor(XCTUnwrap(vibrantDark.opaqueSurface), equals: IStatThemeColor.deviceWhite(0.07, alpha: 1).nsColor,
                        "A tooltip sits on the dark theme's surface")
        let vibrantLight = try theme("vibrant-light").chromePalette(accent: accent)
        XCTAssertEqual(vibrantLight.menuMaterialAppearance, .vibrantLight)
        XCTAssertEqual(vibrantLight.controlScheme, .light)
    }

    func testTracksFreeLegendAndTextColorsComeFromTheTheme() throws {
        let accent = IStatAccentPalette.colors(systemAccent: blueAccent, themeID: "navy")
        let navy = try theme("navy").chromePalette(accent: accent)
        let graphBorder = IStatThemeColor.white(0.5, alpha: 0.35).nsColor
        try assertColor(GeekVisualTokens.ringTrack(for: .dark, visualMode: .black, palette: navy), equals: graphBorder)
        try assertColor(GeekMemoryComponent.free.legendColor(in: PanelMetricColors(), colorScheme: .dark,
                                                             visualMode: .black, chrome: navy), equals: graphBorder)
        XCTAssertEqual(GeekVisualTokens.ringTrack(for: .dark, visualMode: .graphite, palette: nil),
                       GeekVisualTokens.ringTrack(for: .dark, visualMode: .graphite))

        try assertColor(GeekIStatCardGeometry.labelColor(navy), equals: IStatThemeColor.white(0.7, alpha: 1).nsColor)
        try assertColor(GeekIStatCardGeometry.valueColor(navy), equals: .white)
        XCTAssertEqual(GeekIStatTextColor.resolve(.value, color: .primary, palette: navy), navy.text)
        XCTAssertEqual(GeekIStatTextColor.resolve(.value, color: .red, palette: navy), .red,
                       "A state readout keeps its color")
        XCTAssertEqual(GeekIStatTextColor.resolve(.label, color: .primary, palette: navy), navy.secondaryText)
        XCTAssertEqual(GeekIStatTextColor.resolve(.label, color: .primary, palette: nil),
                       Color.primary.opacity(GeekIStatCardGeometry.labelOpacity))
        XCTAssertEqual(GeekIStatTextColor.resolve(.value, color: .primary, palette: nil), Color.primary)
    }

    /// `-[BBRMenuItem drawRect:]` at 2x: row 0 is border2 (0.5 pt at inset
    /// 0.25), row 1 border1 (1 pt at inset 0.5), then the fill; highlighted,
    /// rows 1–2 are the 1 pt accent line at inset 1 and the fill stays.
    func testThemedCardDrawsBothBordersAndTheAccentLine() throws {
        let fill = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let border1 = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let border2 = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        let accentLine = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let palette = testPalette(card: fill, border1: border1, border2: border2, accent: accentLine)
        for highlighted in [false, true] {
            let bitmap = try render(Color.clear.frame(width: 60, height: 30)
                .geekCardSurface(colorScheme: .dark, visualMode: .black, displayScale: 2,
                                 palette: palette, isActive: highlighted))
            XCTAssertEqual(bitmap.pixelsWide, 120)
            for y in [0, bitmap.pixelsHigh - 1] {
                try assertPixel(bitmap, x: 60, y: y, equals: border2, "row \(y), highlighted \(highlighted)")
            }
            for y in [1, bitmap.pixelsHigh - 2] {
                try assertPixel(bitmap, x: 60, y: y, equals: highlighted ? accentLine : border1, "row \(y), highlighted \(highlighted)")
            }
            for y in [2, bitmap.pixelsHigh - 3] {
                try assertPixel(bitmap, x: 60, y: y, equals: highlighted ? accentLine : fill, "row \(y), highlighted \(highlighted)")
            }
            try assertPixel(bitmap, x: 60, y: 3, equals: fill)
            try assertPixel(bitmap, x: 60, y: 30, equals: fill)
            try assertPixel(bitmap, x: 1, y: 30, equals: highlighted ? accentLine : border1, "left edge")
        }
    }

    /// `-[BBRMenuToggle drawRect:]`: the track in the control color while on
    /// and the graph border color while off; the knob in the label color.
    func testSwitchUsesControlGraphBorderAndLabelColors() throws {
        let control = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let graphBorder = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let label = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        let palette = testPalette(card: .black, border1: .black, border2: .black, accent: .red,
                                  label: label, graphBorder: graphBorder, control: control)
        let on = try render(GeekIStatSwitch(isOn: true).environment(\.panelChromePalette, palette))
        XCTAssertEqual(on.pixelsWide, 52)
        try assertPixel(on, x: 10, y: 14, equals: control, "Track while on")
        try assertPixel(on, x: 38, y: 14, equals: label, "Knob at the trailing end while on")
        let off = try render(GeekIStatSwitch(isOn: false).environment(\.panelChromePalette, palette))
        try assertPixel(off, x: 42, y: 14, equals: graphBorder, "Track while off")
        try assertPixel(off, x: 14, y: 14, equals: label, "Knob at the leading end while off")
    }

    /// The panel reads the pair from its defaults by appearance; a capture
    /// or test render (either override) pins indigo and the fixture accent.
    func testEnvironmentReadsThePairAndFixturesPinIStatsDefault() throws {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set("navy", forKey: IStatMenuThemePreferences.darkThemeKey)
        defaults.set("cyan", forKey: IStatMenuThemePreferences.lightThemeKey)
        XCTAssertEqual(try probe(PanelAppearanceEnvironment(), defaults: defaults, scheme: .dark).themeID, "navy")
        XCTAssertEqual(try probe(PanelAppearanceEnvironment(), defaults: defaults, scheme: .light).themeID, "cyan")
        defaults.set("system", forKey: IStatMenuThemePreferences.darkThemeKey)
        XCTAssertEqual(try probe(PanelAppearanceEnvironment(), defaults: defaults, scheme: .dark).themeID, "vibrant-dark",
                       "Vibrancy is on by default")
        defaults.set(false, forKey: IStatMenuThemePreferences.vibrancyKey)
        XCTAssertEqual(try probe(PanelAppearanceEnvironment(), defaults: defaults, scheme: .dark).themeID, "dark")

        for mode in [MiniWindowVisualMode.black, .graphite] {
            let box = ThemeProbeBox()
            let fixture = try probe(PanelAppearanceEnvironment(forcedVisualMode: mode), defaults: defaults,
                                    scheme: .dark, box: box)
            XCTAssertEqual(fixture.themeID, "indigo", "\(mode)")
            XCTAssertEqual(fixture.accentColors?.entryName, "blue")
            try assertColor(XCTUnwrap(fixture.accentColors?.primary), equals: IStatAccentPalette.fixtureAccent)
            // The data colors under the panel follow the accent: blue's entry.
            let metrics = try XCTUnwrap(box.metrics)
            try assertColor(metrics.sectionHeader, equals: IStatAccentPalette.fixtureAccent)
            try assertColor(metrics.cpuUser, equals: IStatAccentPalette.fixtureAccent)
            try assertColor(metrics.cpuSystem, equals: accent("pink"))
            try assertColor(metrics.memoryCompressed, equals: accent("yellow"))
        }
        let named = try probe(PanelAppearanceEnvironment(forcedVisualMode: .graphite, forcedThemeID: "light"),
                              defaults: defaults, scheme: .dark)
        XCTAssertEqual(named.themeID, "light")
        XCTAssertEqual(named.controlScheme, .light)

        // Blue's entry matches the colors without a theme; darkpurple's fixed
        // three do not, for any accent. The data colors under the panel take them.
        let purpleBox = ThemeProbeBox()
        _ = try probe(PanelAppearanceEnvironment(forcedVisualMode: .black, forcedThemeID: "darkpurple"),
                      defaults: defaults, scheme: .dark, box: purpleBox)
        let purpleMetrics = try XCTUnwrap(purpleBox.metrics)
        try assertColor(purpleMetrics.sectionHeader, equals: IStatAccentPalette.darkPurplePrimary.nsColor)
        try assertColor(purpleMetrics.cpuSystem, equals: IStatAccentPalette.darkPurpleSecondary.nsColor)
        try assertColor(purpleMetrics.memoryCompressed, equals: IStatAccentPalette.darkPurpleTertiary.nsColor)
    }

    /// A tooltip's card, translucent in most themes, sits on the theme's
    /// opaque surface (drawn behind it), not on whatever lies below.
    func testTooltipCardSitsOnTheOpaqueSurface() throws {
        let palette = testPalette(card: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5), border1: .black,
                                  border2: .black, accent: .red,
                                  opaqueSurface: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let bitmap = try render(Color.clear.frame(width: 40, height: 20)
            .miniWindowTooltipChrome()
            .environment(\.panelChromePalette, palette)
            .padding(10))
        try assertPixel(bitmap, x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2,
                        equals: NSColor(srgbRed: 0.5, green: 0, blue: 0.5, alpha: 1))
    }

    /// `-[BBRMenu updateCurrentTheme]` sets the menu material (5) behind the
    /// window, active; a card's view (`-[BBRMenuItem initWithFrame:]`) keeps
    /// the default material. Neither takes the pointer.
    func testMaterialBackdropsAreIStats() throws {
        let menu = try effectView(IStatMenuMaterialBackdrop(appearanceName: .vibrantDark))
        XCTAssertEqual(menu.material, .menu)
        XCTAssertEqual(menu.blendingMode, .behindWindow)
        XCTAssertEqual(menu.state, .active)
        XCTAssertEqual(menu.appearance?.name, .vibrantDark)
        XCTAssertNil(menu.hitTest(NSPoint(x: 10, y: 10)))
        let card = try effectView(IStatMenuMaterialBackdrop(material: nil, appearanceName: .vibrantLight))
        XCTAssertEqual(card.material, NSVisualEffectView().material)
        XCTAssertEqual(card.blendingMode, .behindWindow)
        XCTAssertEqual(card.appearance?.name, .vibrantLight)

        let tokens = try source("Sources/StorageCleanerMac/Support/MiniWindowStyleTokens.swift")
        XCTAssertTrue(tokens.contains("if let appearance = panelChromePalette.menuMaterialAppearance {"))
        XCTAssertTrue(tokens.contains("IStatMenuMaterialBackdrop(appearanceName: appearance)"))
        let components = try source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift")
        XCTAssertTrue(components.contains("if let palette, palette.cardMaterial, let appearance = palette.menuMaterialAppearance {"))
        XCTAssertTrue(components.contains("IStatMenuMaterialBackdrop(material: nil, appearanceName: appearance)"))
    }

    // MARK: - Helpers

    private func theme(_ id: String) throws -> IStatMenuTheme {
        try XCTUnwrap(IStatMenuTheme.theme(id: id), id)
    }

    private func accent(_ name: String) -> NSColor {
        IStatAccentPalette.accentColors[name]?.nsColor ?? .clear
    }

    private func testPalette(
        card: NSColor, border1: NSColor, border2: NSColor, accent: NSColor,
        label: NSColor = .gray, graphBorder: NSColor = .gray, control: NSColor = .orange,
        opaqueSurface: NSColor = .black
    ) -> PanelChromePalette {
        let accents = PanelAccentColors(primary: Color(nsColor: accent), secondary: .green, tertiary: .yellow,
                                        control: Color(nsColor: control), controlText: .white, entryName: "test")
        return PanelChromePalette(
            shell: .black, card: Color(nsColor: card), border: .gray, text: .white,
            secondaryText: Color(nsColor: label), tertiaryText: Color(nsColor: label),
            selection: Color(nsColor: card), accent: Color(nsColor: accent), controlScheme: .dark,
            cardBorder1: Color(nsColor: border1), cardBorder2: Color(nsColor: border2),
            graphBorder: Color(nsColor: graphBorder), opaqueSurface: Color(nsColor: opaqueSurface),
            accentColors: accents, themeID: "test"
        )
    }

    private func probe(_ environment: PanelAppearanceEnvironment, defaults: UserDefaults,
                       scheme: ColorScheme, box: ThemeProbeBox = ThemeProbeBox()) throws -> PanelChromePalette {
        let renderer = ImageRenderer(content: ThemeProbe(box: box)
            .modifier(environment)
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(defaults))
        _ = renderer.cgImage
        return try XCTUnwrap(box.palette)
    }

    private func effectView<Backdrop: View>(_ backdrop: Backdrop) throws -> NSVisualEffectView {
        let host = NSHostingView(rootView: backdrop.frame(width: 20, height: 20))
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        host.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        return try XCTUnwrap(views(host).compactMap { $0 as? NSVisualEffectView }.first)
    }

    /// At 2x with a 2x layout (a 1x layout rounds fractional insets to points).
    private func render<Content: View>(_ content: Content) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 2))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        return NSBitmapImageRep(cgImage: image)
    }

    private func components(_ color: NSColor) throws -> [CGFloat] {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }

    private func assertColor(_ actual: Color, equals expected: NSColor, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let lhs = try components(NSColor(actual)), rhs = try components(expected)
        for (a, b) in zip(lhs, rhs) {
            XCTAssertEqual(a, b, accuracy: 0.002, "\(message) \(lhs) vs \(rhs)", file: file, line: line)
        }
    }

    /// The image is sRGB; `colorAt` tags its stored components with another
    /// space, so they are compared as stored.
    private func assertPixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int, equals expected: NSColor,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y), file: file, line: line)
        let actual = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent, pixel.alphaComponent]
        let wanted = try components(expected)
        for (a, b) in zip(actual, wanted) {
            XCTAssertEqual(a, b, accuracy: 0.02, "\(message) at (\(x), \(y)): \(actual) vs \(wanted)", file: file, line: line)
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

@MainActor
private final class ThemeProbeBox {
    var palette: PanelChromePalette?
    var metrics: PanelMetricColors?
}

/// Records the palette and data colors the environment hands its content.
private struct ThemeProbe: View {
    @Environment(\.panelChromePalette) private var palette
    @Environment(\.panelMetricColors) private var metrics
    let box: ThemeProbeBox

    var body: some View {
        box.palette = palette
        box.metrics = metrics
        return Color.clear.frame(width: 1, height: 1)
    }
}
