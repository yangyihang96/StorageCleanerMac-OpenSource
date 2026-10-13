import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class DayAppearanceTests: XCTestCase {
    func testMiniWindowFollowsAppAndSystemUnlessExplicitlyPinned() {
        for miniWindowRawValue in ["", MiniWindowAppearance.system.rawValue, "invalid"] {
            XCTAssertNil(MiniWindowAppearance.resolvedPreferredColorScheme(
                miniWindowRawValue: miniWindowRawValue,
                appRawValue: AppAppearance.system.rawValue
            ))
            XCTAssertEqual(MiniWindowAppearance.resolvedPreferredColorScheme(
                miniWindowRawValue: miniWindowRawValue,
                appRawValue: AppAppearance.light.rawValue
            ), .light)
            XCTAssertEqual(MiniWindowAppearance.resolvedPreferredColorScheme(
                miniWindowRawValue: miniWindowRawValue,
                appRawValue: AppAppearance.dark.rawValue
            ), .dark)
        }
        XCTAssertEqual(MiniWindowAppearance.resolvedPreferredColorScheme(
            miniWindowRawValue: MiniWindowAppearance.dark.rawValue,
            appRawValue: AppAppearance.light.rawValue
        ), .dark)
        XCTAssertEqual(MiniWindowAppearance.resolvedPreferredColorScheme(
            miniWindowRawValue: MiniWindowAppearance.light.rawValue,
            appRawValue: AppAppearance.dark.rawValue
        ), .light)
    }

    func testMiniWindowChromeFollowsSystemAppAndExplicitOverrides() {
        XCTAssertEqual(MiniWindowVisualMode.resolve(
            miniWindowRawValue: "", appRawValue: AppAppearance.system.rawValue,
            systemColorScheme: .light
        ), .graphite)
        XCTAssertEqual(MiniWindowVisualMode.resolve(
            miniWindowRawValue: "", appRawValue: AppAppearance.system.rawValue,
            systemColorScheme: .dark
        ), .black)
        XCTAssertEqual(MiniWindowVisualMode.resolve(
            miniWindowRawValue: MiniWindowAppearance.light.rawValue,
            appRawValue: AppAppearance.dark.rawValue, systemColorScheme: .dark
        ), .graphite)
        XCTAssertEqual(MiniWindowVisualMode.resolve(
            miniWindowRawValue: MiniWindowAppearance.dark.rawValue,
            appRawValue: AppAppearance.light.rawValue, systemColorScheme: .light
        ), .black)
        XCTAssertEqual(MiniWindowVisualMode.resolve(
            miniWindowRawValue: MiniWindowAppearance.system.rawValue,
            appRawValue: AppAppearance.light.rawValue, systemColorScheme: .dark
        ), .graphite)
    }

    func testEverySelectableDropdownHasDistinctReadableDayAndNightPalettes() throws {
        for preset in PanelSurfacePreset.allCases where preset != .original {
            let day = try XCTUnwrap(preset.palette(for: .graphite))
            let night = try XCTUnwrap(preset.palette(for: .black))
            XCTAssertNotEqual(rgb(day.shell, day.controlScheme), rgb(night.shell, night.controlScheme),
                              preset.rawValue)
            for palette in [day, night] {
                let shell = rgb(palette.shell, palette.controlScheme)
                XCTAssertGreaterThanOrEqual(contrast(rgb(palette.text, palette.controlScheme), shell), 4.5,
                                            preset.rawValue)
                XCTAssertGreaterThanOrEqual(contrast(rgb(palette.secondaryText, palette.controlScheme), shell), 4.5,
                                            preset.rawValue)
                XCTAssertGreaterThanOrEqual(contrast(rgb(palette.text, palette.controlScheme),
                                                    rgb(palette.card, palette.controlScheme)), 4.5,
                                            preset.rawValue)
                for foreground in [palette.secondaryText, palette.tertiaryText, palette.accent] {
                    for background in [palette.shell, palette.card] {
                        XCTAssertGreaterThanOrEqual(contrast(rgb(foreground, palette.controlScheme),
                                                            rgb(background, palette.controlScheme)), 4.5,
                                                    "\(preset.rawValue) \(palette.controlScheme) text")
                    }
                }
            }
        }
        XCTAssertNil(PanelSurfacePreset.original.palette(for: .graphite))
        XCTAssertNil(PanelSurfacePreset.original.palette(for: .black))
    }

    func testMenuBarPresetsResolveBothAppearancesAndKeepLegacyAutomatic() throws {
        for preset in PanelStatusColorPreset.allCases where preset != .original {
            let day = try XCTUnwrap(preset.ink(dark: false))
            let night = try XCTUnwrap(preset.ink(dark: true))
            XCTAssertNotEqual(day, night, preset.rawValue)
        }
        XCTAssertNil(PanelStatusColorPreset.original.ink(dark: false))
        let custom = try XCTUnwrap(PanelStatusColorPreset.custom.ink(
            dark: false, customDayHex: "#123456", customNightHex: "#ABCDEF"))
        XCTAssertEqual(custom.usingColorSpace(.sRGB)?.redComponent ?? -1, 0x12 / 255.0, accuracy: 0.001)
        XCTAssertEqual(PanelMetricColors(lightSurface: true, cpuUser: "#123456").cpuUser,
                       PanelAppearancePreferences.color(from: "#123456"))
        XCTAssertNotEqual(rgb(PanelMetricColors(lightSurface: true).cpuUser, .light),
                          rgb(PanelMetricColors().cpuUser, .dark))
    }

    func testEveryIllustratedRouteHasADistinctLightSurfaceAndReadableText() {
        for route in ReviewFilter.allCases where route.moduleTheme.isImmersive {
            let theme = route.moduleTheme
            for scheme in [ColorScheme.light, .dark] {
                let backgrounds = [theme.startColor(for: scheme), theme.endColor(for: scheme)]
                for background in backgrounds {
                    let bg = rgb(background, scheme)
                    for foreground in [theme.primaryText, theme.secondaryText, theme.tertiaryText] {
                        let fg = composited(rgb(foreground, scheme), over: bg)
                        XCTAssertGreaterThanOrEqual(contrast(fg, bg), 4.5, "\(route) \(scheme)")
                    }
                }
            }
            // The daylight canvas is neutral, separate from the lightly raised navigation.
            // Contrast requirements above remain unchanged for every foreground.
            let daylightLuminance = luminance(rgb(theme.startColor(for: .light), .light))
            XCTAssertGreaterThan(daylightLuminance, 0.82, "\(route)")
            XCTAssertLessThan(daylightLuminance, 0.90, "\(route)")
            XCTAssertLessThan(luminance(rgb(theme.startColor(for: .dark), .dark)), 0.05, "\(route)")
            // Large colored actions keep their white labels in both themes.
            XCTAssertGreaterThanOrEqual(contrast(rgb(theme.accent, .light), rgb(.white, .light)), 4.5, "\(route)")
            for scheme in [ColorScheme.light, .dark] {
                for stop in theme.actionGradient(for: scheme) {
                    XCTAssertEqual(rgb(stop, scheme).a, 1)
                    XCTAssertGreaterThanOrEqual(contrast(rgb(stop, scheme), rgb(.white, scheme)), 4.5, "\(route) \(scheme) action")
                }
            }
        }
    }

    func testSemanticStatusAndChartLabelsRemainReadableOnLightCards() {
        typealias P = AppDesignTokens.Palette
        let colors = [P.information, P.destructive, P.success, P.warning,
                      P.sensitive, P.diagnostic, P.storage, P.freshness, P.caution, P.technicalLine]
        for color in colors {
            XCTAssertGreaterThanOrEqual(contrast(rgb(color, .light), rgb(AppAppearanceColors.panel, .light)), 4.5)
        }
    }

    func testColorResolutionUsesTheViewAppearanceWithoutChangingGlobalPreference() {
        let day = rgb(AppAppearanceColors.ink, .light)
        let night = rgb(AppAppearanceColors.ink, .dark)
        XCTAssertLessThan(luminance(day), 0.04)
        XCTAssertEqual(luminance(night), 1, accuracy: 0.001)
        XCTAssertEqual(rgb(AppAppearanceColors.ink, .light), day)
    }

    func testModuleIconsKeepTheirHueAcrossAppearanceChanges() {
        for route in ReviewFilter.allCases where route.moduleTheme.isImmersive {
            let color = route.moduleTheme.iconTint
            let day = rgb(color, .light), night = rgb(color, .dark)
            func hue(_ value: RGBA) -> CGFloat {
                let color = NSColor(srgbRed: value.r, green: value.g, blue: value.b, alpha: 1)
                return color.hueComponent
            }
            let difference = abs(hue(day) - hue(night))
            XCTAssertLessThan(min(difference, 1 - difference), 0.02, route.rawValue)
            XCTAssertGreaterThanOrEqual(contrast(day, rgb(AppAppearanceColors.panel, .light)), 4.5, route.rawValue)
        }
    }

    func testMainAndMiniWindowDefaultDataColorsAgreeInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            let panel = PanelMetricColors(lightSurface: scheme == .light)
            let pairs: [(Color, Color)] = [
                (AppChartPalette.cpuUser, panel.cpuUser), (AppChartPalette.cpuSystem, panel.cpuSystem),
                (AppChartPalette.memoryWired, panel.memoryWired), (AppChartPalette.memoryCompressed, panel.memoryCompressed),
                (AppChartPalette.upload, panel.networkUpload), (AppChartPalette.download, panel.networkDownload)
            ]
            for (main, mini) in pairs {
                let a = rgb(main, scheme), b = rgb(mini, scheme)
                XCTAssertEqual(a.r, b.r, accuracy: 0.001)
                XCTAssertEqual(a.g, b.g, accuracy: 0.001)
                XCTAssertEqual(a.b, b.b, accuracy: 0.001)
            }
        }
    }

    func testLightPanelsRemainLegibleWhenTransparencyIsReduced() {
        for route in ReviewFilter.allCases where route.moduleTheme.isImmersive {
            let theme = route.moduleTheme
            for opaque in [false, true] {
                let background = composited(rgb(theme.panelFill(for: .light, reduceTransparency: opaque), .light),
                                             over: rgb(theme.startColor(for: .light), .light))
                XCTAssertGreaterThan(luminance(background), 0.8)
                XCTAssertGreaterThanOrEqual(contrast(rgb(theme.secondaryText, .light), background), 4.5)
                if opaque { XCTAssertEqual(rgb(theme.panelFill(for: .light, reduceTransparency: true), .light).a, 1) }
            }
        }
    }

    func testBuiltInPanelChartHuesHaveDaylightContrastAndCustomHuesArePreserved() throws {
        for theme in [PanelColorTheme.ocean, .violet, .mint] {
            let color = try XCTUnwrap(PanelColorTheme.chartColor(storedTheme: theme.rawValue, backgroundHex: "", customHex: ""))
            XCTAssertGreaterThanOrEqual(contrast(rgb(color, .light), rgb(AppAppearanceColors.panel, .light)), 4.5)
            let original = try XCTUnwrap(PanelAppearancePreferences.color(from: theme.chartHex!))
            let adapted = rgb(color, .dark), expected = rgb(original, .dark)
            // NSColor converts between floating point color spaces on the way
            // to SwiftUI; compare channels within that conversion precision.
            XCTAssertEqual(adapted.r, expected.r, accuracy: 0.000001)
            XCTAssertEqual(adapted.g, expected.g, accuracy: 0.000001)
            XCTAssertEqual(adapted.b, expected.b, accuracy: 0.000001)
            XCTAssertEqual(adapted.a, expected.a, accuracy: 0.000001)
        }
        XCTAssertNil(PanelColorTheme.chartColor(
            storedTheme: PanelColorTheme.graphite.rawValue,
            backgroundHex: "", customHex: ""))
        let custom = try XCTUnwrap(PanelColorTheme.chartColor(storedTheme: "custom", backgroundHex: "#123456", customHex: "#AABBCC"))
        XCTAssertEqual(rgb(custom, .light), rgb(custom, .dark))
    }

    func testMainAndRuntimeHostsDoNotOverrideTheSelectedAppearanceOrRecreateState() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Views/ModulePresentation.swift", "Views/SidebarView.swift", "Views/FileToolLandingPage.swift",
                     "Views/RuntimeActivityLayout.swift", "Views/RuntimeWorkflowPresentation.swift",
                     "Views/ContentView.swift", "App/StorageCleanerMacApp.swift"]
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/" + file), encoding: .utf8)
            XCTAssertFalse(source.contains(".environment(\\.colorScheme, .dark)"), file)
            XCTAssertFalse(source.contains("theme.isImmersive ? .dark : colorScheme"), file)
            XCTAssertFalse(source.contains(".id(languageRawValue + appearanceRawValue)"), file)
        }
    }

    func testD63EveryDaylightCandidateUsesOneCanvasAndReadableSemanticTokens() {
        for daylight in AppDaylightTheme.allCases {
            let palette = AppDesignTokens.Surface.palette(theme: .deepSpace, scheme: .light, daylightTheme: daylight)
            XCTAssertEqual(palette.spec.card, palette.spec.canvasTop)
            XCTAssertEqual(palette.spec.cardOpaque, palette.spec.canvasTop)
            XCTAssertEqual(palette.spec.shadowOpacity, 0)
            for base in [palette.canvasTop, palette.canvasBottom, palette.sidebar, palette.inset, palette.hover] {
                // Hover is transparent ink; composite it onto the actual canvas.
                let background = composited(rgb(base, .light), over: rgb(palette.canvasBottom, .light))
                for text in [palette.textPrimary, palette.textSecondary, palette.textTertiary] {
                    XCTAssertGreaterThanOrEqual(contrast(rgb(text, .light), background), 4.5, daylight.rawValue)
                }
            }
            // Worst-case overlapping light sources, including every module pigment.
            for module in ReviewFilter.allCases where module.moduleTheme.isImmersive {
                let moduleGlow = rgb(module.moduleTheme.glowColor.opacity(palette.glowOpacity * 1.5), .light)
                for canvas in [palette.canvasTop, palette.canvasBottom] {
                    let background = composited(moduleGlow, over: rgb(canvas, .light))
                    for text in [palette.textPrimary, palette.textSecondary, palette.textTertiary] {
                        XCTAssertGreaterThanOrEqual(contrast(rgb(text, .light), background), 4.5,
                                                    "\(daylight)/\(module) glow")
                    }
                }
            }
        }
    }

    func testD63DaylightSelectionHasADeterministicProductionDefault() throws {
        // D63 final selection: Debug and Release share the one production palette.
        XCTAssertEqual(AppDaylightTheme.allCases, [.morningMist])
        XCTAssertEqual(AppDaylightTheme.current, .morningMist)
        let spec = AppDaylightTheme.current.surfaceSpec
        XCTAssertEqual(spec.canvasTop, 0xEDF3F9)
        XCTAssertEqual(spec.canvasBottom, 0xE4EDF6)
        XCTAssertEqual(spec.sidebar, 0xE7EFF7)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Support/AppDaylightTheme.swift"), encoding: .utf8)
        for obsolete in ["cleanWhite", "lightAurora", "debug-daylight-theme", "STORAGE_CLEANER_DEBUG_DAYLIGHT_THEME",
                         "ProcessInfo", "static func resolve", "ambientTopGlow", "ambientSideGlow"] {
            XCTAssertFalse(source.contains(obsolete), obsolete)
        }
    }

    private struct RGBA: Equatable { var r, g, b, a: Double }
    private func rgb(_ color: Color, _ scheme: ColorScheme) -> RGBA {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let resolved = color.resolve(in: environment)
        return RGBA(r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue), a: Double(resolved.opacity))
    }
    private func composited(_ foreground: RGBA, over background: RGBA) -> RGBA {
        RGBA(r: foreground.r * foreground.a + background.r * (1 - foreground.a),
             g: foreground.g * foreground.a + background.g * (1 - foreground.a),
             b: foreground.b * foreground.a + background.b * (1 - foreground.a), a: 1)
    }
    private func luminance(_ c: RGBA) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return linear(c.r) * 0.2126 + linear(c.g) * 0.7152 + linear(c.b) * 0.0722
    }
    private func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
