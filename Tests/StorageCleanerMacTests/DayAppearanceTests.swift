import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class DayAppearanceTests: XCTestCase {
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
            XCTAssertGreaterThan(luminance(rgb(theme.startColor(for: .light), .light)), 0.80, "\(route)")
            XCTAssertLessThan(luminance(rgb(theme.startColor(for: .dark), .dark)), 0.05, "\(route)")
            // Large colored actions keep their white labels in both themes.
            XCTAssertGreaterThanOrEqual(contrast(rgb(theme.accent, .light), rgb(.white, .light)), 4.5, "\(route)")
            for stop in theme.actionGradient(for: .light) {
                XCTAssertEqual(rgb(stop, .light).a, 1)
                XCTAssertGreaterThanOrEqual(contrast(rgb(stop, .light), rgb(.white, .light)), 4.5, "\(route) action")
            }
        }
    }

    func testSemanticStatusAndChartLabelsRemainReadableOnLightCards() {
        typealias P = AppDesignTokens.Palette
        let colors = [P.information, P.destructive, P.success, P.warning,
                      P.sensitive, P.diagnostic, P.storage, P.freshness, P.caution, P.technicalLine]
        for color in colors {
            XCTAssertGreaterThanOrEqual(contrast(rgb(color, .light), rgb(.white, .light)), 4.5)
        }
    }

    func testColorResolutionUsesTheViewAppearanceWithoutChangingGlobalPreference() {
        let day = rgb(AppAppearanceColors.ink, .light)
        let night = rgb(AppAppearanceColors.ink, .dark)
        XCTAssertLessThan(luminance(day), 0.04)
        XCTAssertEqual(luminance(night), 1, accuracy: 0.001)
        XCTAssertEqual(rgb(AppAppearanceColors.ink, .light), day)
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
        for theme in [PanelColorTheme.ocean, .violet, .mint, .graphite] {
            let color = try XCTUnwrap(PanelColorTheme.chartColor(storedTheme: theme.rawValue, backgroundHex: "", customHex: ""))
            XCTAssertGreaterThanOrEqual(contrast(rgb(color, .light), rgb(.white, .light)), 4.5)
            let original = try XCTUnwrap(PanelAppearancePreferences.color(from: theme.chartHex!))
            let adapted = rgb(color, .dark), expected = rgb(original, .dark)
            // NSColor converts between floating point color spaces on the way
            // to SwiftUI; compare channels within that conversion precision.
            XCTAssertEqual(adapted.r, expected.r, accuracy: 0.000001)
            XCTAssertEqual(adapted.g, expected.g, accuracy: 0.000001)
            XCTAssertEqual(adapted.b, expected.b, accuracy: 0.000001)
            XCTAssertEqual(adapted.a, expected.a, accuracy: 0.000001)
        }
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
