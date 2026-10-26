import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class DaylightRefinementTests: XCTestCase {
    func testDaylightUsesMorningMistAndQuieterSidebarWithLegacyPanelsPreserved() {
        func luminance(_ color: Color) -> Double {
            let c = resolve(color, .light)
            func linear(_ value: Float) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        }
        let canvasTop = resolve(AppAppearanceColors.canvasTop, .light)
        let sidebarTop = resolve(AppAppearanceColors.sidebarTop, .light)
        // D63 replaces the main-window ivory canvas with a cool blue gray.
        // Legacy mini-window/settings panel assertions below are unchanged.
        for color in [canvasTop, sidebarTop] {
            XCTAssertGreaterThanOrEqual(color.blue, color.green)
            XCTAssertGreaterThanOrEqual(color.green, color.red)
            XCTAssertLessThan(color.blue - color.red, 0.07)
        }
        XCTAssertGreaterThan(luminance(AppAppearanceColors.canvasTop),
                             luminance(AppAppearanceColors.canvasBottom) + 0.01)
        XCTAssertEqual(luminance(AppAppearanceColors.sidebarTop),
                       luminance(AppAppearanceColors.sidebarBottom), accuracy: 0.001)
        // D63: the quiet sidebar is a slightly deeper part of the cool canvas.
        XCTAssertLessThan(luminance(AppAppearanceColors.sidebarTop),
                          luminance(AppAppearanceColors.canvasTop) - 0.02)
        XCTAssertLessThan(luminance(AppAppearanceColors.sidebarTop),
                          luminance(AppAppearanceColors.panel))
        let cardLift = luminance(AppAppearanceColors.panel) - luminance(AppAppearanceColors.canvasTop)
        XCTAssertGreaterThan(cardLift, 0.06)
        XCTAssertLessThan(cardLift, 0.16)
        let selection = resolve(AppAppearanceColors.selectedSurface, .light)
        XCTAssertGreaterThan(selection.blue, selection.red + 0.05)
        XCTAssertGreaterThan(selection.blue, selection.green + 0.02)
        for surface in [AppAppearanceColors.panel, AppAppearanceColors.secondarySurface] {
            let color = resolve(surface, .light)
            XCTAssertGreaterThanOrEqual(color.red, color.green)
            XCTAssertGreaterThanOrEqual(color.green, color.blue)
            XCTAssertLessThan(color.red - color.blue, 0.025)
        }
        let icon = resolve(AppAppearanceColors.sidebarIcon, .light)
        XCTAssertGreaterThan(icon.blue, icon.red + 0.10)
        XCTAssertGreaterThan(icon.blue, icon.green + 0.10)
        XCTAssertGreaterThanOrEqual(
            (luminance(AppAppearanceColors.sidebarTop) + 0.05) /
                (luminance(AppAppearanceColors.sidebarIcon) + 0.05),
            3
        )
    }

    func testMorningMistDaySurfacesKeepTextContrastWithoutPureWhiteCanvas() {
        func luminance(_ color: Color) -> Double {
            let c = resolve(color, .light)
            func linear(_ value: Float) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        }
        let surfaces = [AppAppearanceColors.canvasTop, AppAppearanceColors.canvasBottom,
                        AppAppearanceColors.panel, AppAppearanceColors.secondarySurface,
                        AppAppearanceColors.sidebarTop, AppAppearanceColors.settingsSidebarBottom]
        for surface in surfaces {
            let background = luminance(surface)
            XCTAssertLessThan(background, 0.98, "Avoid pure-white daylight surfaces")
            for text in [AppAppearanceColors.ink, AppDesignTokens.Palette.secondaryText,
                         AppDesignTokens.Palette.tertiaryText] {
                XCTAssertGreaterThanOrEqual((background + 0.05) / (luminance(text) + 0.05), 4.5)
            }
        }
        XCTAssertGreaterThan(luminance(AppAppearanceColors.panel), luminance(AppAppearanceColors.canvasTop))
        XCTAssertLessThan(luminance(AppAppearanceColors.canvasTop), 0.9)
        XCTAssertGreaterThanOrEqual(
            (1.0 + 0.05) / (luminance(AppAppearanceColors.controlAccent) + 0.05), 4.5
        )
        let violet = Color(red: 191.0 / 255, green: 90.0 / 255, blue: 242.0 / 255)
        XCTAssertGreaterThanOrEqual((luminance(AppAppearanceColors.panel) + 0.05) / (luminance(violet) + 0.05), 3)
    }

    func testNightUsesNeutralNearBlackSurfacesWithStableDataColors() {
        // D56 makes deep space the default night canvas; pure black stays a
        // choice and keeps every neutral near-black rule below.
        AppCanvasTheme.withCurrent(.pureBlack) {
            assertPureBlackNightSurfaces()
        }
        AppCanvasTheme.withCurrent(.deepSpace) {
            // UI-V2-SPEC 1.2: #10162E → #0A0E20 canvas, #0B1022 sidebar.
            let top = resolve(AppAppearanceColors.canvasTop, .dark)
            let bottom = resolve(AppAppearanceColors.canvasBottom, .dark)
            let sidebar = resolve(AppAppearanceColors.sidebarTop, .dark)
            for color in [top, bottom, sidebar] {
                XCTAssertGreaterThan(color.blue, color.red + 0.05)
                XCTAssertLessThan(color.red, 0.08)
            }
            XCTAssertGreaterThan(top.blue, bottom.blue)
            // The menu bar mini window keeps its neutral shell (D56).
            for surface in [MiniWindowStyleTokens.darkShellTopColor, MiniWindowStyleTokens.darkShellBottomColor] {
                let color = resolve(surface, .dark)
                let channels = [color.red, color.green, color.blue]
                XCTAssertLessThan((channels.max() ?? 0) - (channels.min() ?? 0), 0.04)
            }
        }
    }

    private func assertPureBlackNightSurfaces() {
        let surfaces = [
            AppAppearanceColors.canvasTop,
            AppAppearanceColors.canvasBottom,
            AppAppearanceColors.sidebarTop,
            AppAppearanceColors.sidebarBottom,
            MiniWindowStyleTokens.darkShellTopColor,
            MiniWindowStyleTokens.darkShellBottomColor,
        ]
        for surface in surfaces {
            let color = resolve(surface, .dark)
            let channels = [color.red, color.green, color.blue]
            XCTAssertLessThan((channels.max() ?? 0) - (channels.min() ?? 0), 0.04)
        }
        let day = resolve(AppAppearanceColors.canvasTop, .light)
        let night = resolve(AppAppearanceColors.canvasTop, .dark)
        XCTAssertGreaterThan(day.red, 0.8)
        XCTAssertLessThan(night.red, 0.10)
        let sidebar = resolve(AppAppearanceColors.sidebarTop, .dark)
        XCTAssertGreaterThan(sidebar.red, night.red)
        XCTAssertLessThan(sidebar.red, 0.13)
        XCTAssertLessThan(night.red, 0.025)
        XCTAssertEqual(resolve(AppAppearanceColors.canvasBottom, .dark).red, 0)
        XCTAssertEqual(resolve(AppAppearanceColors.secondarySurface, .dark).red,
                       resolve(AppAppearanceColors.secondarySurface, .dark).blue)
        XCTAssertGreaterThan(resolve(AppAppearanceColors.panel, .dark).red, night.red)
        XCTAssertLessThan(resolve(AppAppearanceColors.panel, .dark).red, 0.09)

        let blue = resolve(AppChartPalette.cpuUser, .dark)
        let rose = resolve(AppChartPalette.cpuSystem, .dark)
        XCTAssertGreaterThan(blue.blue, blue.red + 0.2)
        XCTAssertGreaterThan(rose.red, rose.green + 0.3)
    }

    func testAttachedMiniWindowLevelsUseOneNeutralDarkSurface() {
        let shell = resolve(MiniWindowStyleTokens.darkShellColor, .dark)
        let daylightShell = resolve(MiniWindowStyleTokens.graphiteShellColor, .dark)
        let top = resolve(MiniWindowStyleTokens.darkShellTopColor, .dark)
        let bottom = resolve(MiniWindowStyleTokens.darkShellBottomColor, .dark)
        XCTAssertEqual(shell, top)
        XCTAssertEqual(shell, bottom)
        XCTAssertLessThan(abs(shell.red - shell.blue), 0.01)
        XCTAssertGreaterThan(daylightShell.red, shell.red + 0.08)
        XCTAssertLessThan(shell.red, 0.08)

        let card = resolve(GeekVisualTokens.cardFill(for: .dark, visualMode: .graphite), .dark)
        let cardAlpha = NSColor(GeekVisualTokens.cardFill(for: .dark, visualMode: .graphite)).alphaComponent
        XCTAssertLessThan(cardAlpha, 0.2)
        XCTAssertEqual(card.red, 0)
        XCTAssertEqual(card.green, 0)
        XCTAssertEqual(card.blue, 0)
        let nightCard = resolve(GeekVisualTokens.cardFill(for: .dark, visualMode: .black), .dark)
        XCTAssertEqual(NSColor(GeekVisualTokens.cardFill(for: .dark, visualMode: .black)).alphaComponent, 1)
        XCTAssertGreaterThan(nightCard.red, shell.red)
        XCTAssertLessThan(nightCard.red, 0.08)
        XCTAssertEqual(nightCard.red, nightCard.green)
        XCTAssertEqual(nightCard.green, nightCard.blue)
    }

    func testPanelMetricPaletteKeepsSeriesDistinctAcrossAppearancesAndHonorsOverrides() {
        for scheme in [ColorScheme.light, .dark] {
            let defaults = PanelMetricColors()
            let blue = resolve(defaults.cpuUser, scheme)
            let pink = resolve(defaults.cpuSystem, scheme)
            let gold = resolve(defaults.memoryCompressed, scheme)
            XCTAssertGreaterThan(blue.blue, blue.red + 0.15)
            XCTAssertGreaterThan(pink.red, pink.green + 0.20)
            XCTAssertGreaterThan(gold.red, gold.blue + 0.35)
            XCTAssertEqual(resolve(defaults.memoryApp, scheme), blue)
            XCTAssertEqual(resolve(defaults.memoryWired, scheme), pink)
            XCTAssertEqual(resolve(defaults.memoryPressure, scheme), blue)
            XCTAssertEqual(resolve(defaults.swap, scheme), blue)
            XCTAssertEqual(resolve(defaults.diskRead, scheme), pink)
            XCTAssertEqual(resolve(defaults.diskWrite, scheme), blue)
            XCTAssertEqual(resolve(defaults.sensorGraph, scheme), blue)
            XCTAssertEqual(resolve(defaults.batteryHealth, scheme), pink)
            XCTAssertEqual(resolve(defaults.networkDownload, scheme), blue)
            XCTAssertEqual(resolve(defaults.networkUpload, scheme), pink)
        }

        let custom = PanelMetricColors(cpuUser: "#147852", gpu: "#AABBCC",
                                       memoryCompressed: "not-a-color", diskRead: "#ABCDEF")
        XCTAssertEqual(resolve(custom.cpuUser, .light), resolve(Color(red: 20.0 / 255, green: 120.0 / 255, blue: 82.0 / 255), .light))
        XCTAssertEqual(resolve(custom.memoryCompressed, .light), resolve(MiniWindowColorPalette.yellow, .light))
        XCTAssertEqual(resolve(custom.cpuSystem, .light), resolve(MiniWindowColorPalette.pink, .light))
        XCTAssertEqual(resolve(custom.diskRead, .light), resolve(Color(red: 171.0 / 255, green: 205.0 / 255, blue: 239.0 / 255), .light))
        XCTAssertEqual(resolve(custom.diskWrite, .light), resolve(MiniWindowColorPalette.blue, .light))
        XCTAssertTrue(custom.gpuIsCustomized)
        XCTAssertFalse(custom.sensorGraphIsCustomized)
        let graphite = PanelMetricColors(visualMode: .graphite)
        XCTAssertEqual(resolve(graphite.sectionHeader, .dark), resolve(MiniWindowColorPalette.graphiteHeaderBlue, .dark))
        XCTAssertEqual(resolve(graphite.cpuUser, .dark), resolve(MiniWindowColorPalette.blue, .dark))
    }

    func testBuiltInPanelThemesKeepBothSurfacesNeutral() throws {
        for theme in [PanelColorTheme.ocean, .violet, .mint, .graphite] {
            XCTAssertNil(PanelColorTheme.backgroundTint(
                storedTheme: theme.rawValue, backgroundHex: theme.backgroundHex ?? "", chartHex: theme.chartHex ?? ""))
        }
        let chart = try XCTUnwrap(PanelColorTheme.chartColor(storedTheme: "violet", backgroundHex: "#5E5CE6", customHex: "#BF5AF2"))
        let day = resolve(chart, .light)
        XCTAssertGreaterThan(day.blue, day.green)
        XCTAssertGreaterThan(day.red, day.green)
    }

    func testExplicitCustomBackgroundRemainsTheSameAcrossAppearances() throws {
        let tint = try XCTUnwrap(PanelColorTheme.backgroundTint(storedTheme: "custom", backgroundHex: "#123456", chartHex: "#ABCDEF"))
        let day = resolve(tint, .light), night = resolve(tint, .dark)
        XCTAssertEqual(day.red, night.red, accuracy: 0.0001)
        XCTAssertEqual(day.green, night.green, accuracy: 0.0001)
        XCTAssertEqual(day.blue, night.blue, accuracy: 0.0001)
        XCTAssertEqual(day.opacity, 0.18, accuracy: 0.0001)
    }

    func testPrimaryActionsKeepModulePigmentAndReadableWhiteLabelsInBothAppearances() {
        func luminance(_ color: Color.Resolved) -> Double {
            func linear(_ value: Float) -> Double {
                let channel = Double(value)
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        func hue(_ color: Color.Resolved) -> CGFloat {
            NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green),
                    blue: CGFloat(color.blue), alpha: 1).hueComponent
        }
        for filter in ReviewFilter.allCases {
            let theme = filter.moduleTheme
            for appearance in [ColorScheme.light, .dark] {
                let actual = resolve(theme.actionFill, appearance)
                XCTAssertEqual(actual.opacity, 1, "\(filter) \(appearance)")
                XCTAssertGreaterThanOrEqual(1.05 / (luminance(actual) + 0.05), 4.5,
                                            "\(filter) \(appearance) white label")
                if theme.isImmersive {
                    let difference = abs(hue(actual) - hue(resolve(theme.accent, appearance)))
                    XCTAssertLessThan(min(difference, 1 - difference), 0.02,
                                      "\(filter) \(appearance) action keeps its module hue")
                } else {
                    let expected = resolve(AppAppearanceColors.controlFill, appearance)
                    XCTAssertEqual(actual.red, expected.red, accuracy: 0.000001)
                    XCTAssertEqual(actual.green, expected.green, accuracy: 0.000001)
                    XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.000001)
                }
            }
        }
        for appearance in [ColorScheme.light, .dark] {
            let moduleFills = FeatureGroup.allCases.filter { $0 != .settings }.map {
                resolve(ModuleThemeCatalog.theme(for: $0).actionFill, appearance)
            }
            XCTAssertEqual(Set(moduleFills.map { "\($0.red),\($0.green),\($0.blue)" }).count,
                           moduleFills.count, "Primary actions retain all six module pigments in \(appearance)")
        }
    }

    func testDaylightIconRolesStayReadableAndNightModuleColorsStayIntact() {
        func luminance(_ color: Color) -> Double {
            let c = resolve(color, .light)
            func linear(_ value: Float) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        }
        let background = luminance(AppAppearanceColors.panel)
        for group in FeatureGroup.allCases {
            let theme = ModuleThemeCatalog.theme(for: group)
            let icon = theme.iconTint
            let dayIcon = resolve(icon, .light)
            let channels = [dayIcon.red, dayIcon.green, dayIcon.blue]
            XCTAssertGreaterThanOrEqual((channels.max() ?? 0) - (channels.min() ?? 0), 0.11,
                                        "\(group) icon should retain a discernible pigment")
            XCTAssertGreaterThanOrEqual(
                (background + 0.05) / (luminance(icon) + 0.05), 3,
                "\(group) icon must remain legible on the unchanged legacy panel"
            )
            let nightIcon = resolve(icon, .dark), original = resolve(theme.accent, .dark)
            XCTAssertEqual(nightIcon.red, original.red, accuracy: 0.000001)
            XCTAssertEqual(nightIcon.green, original.green, accuracy: 0.000001)
            XCTAssertEqual(nightIcon.blue, original.blue, accuracy: 0.000001)
        }
        for scheme in [ColorScheme.light, .dark] {
            let categories = BenchmarkV7Category.corePerformance.map {
                resolve(AppIconPalette.benchmark($0, night: .purple), scheme)
            }
            XCTAssertEqual(Set(categories.map { "\($0.red),\($0.green),\($0.blue)" }).count,
                           categories.count, "The benchmark categories need distinct glyphs in \(scheme)")
        }
    }

    func testHoverAndSelectionDoNotChangeBorderGeometryAtEitherScale() {
        // D118 (2026-10-18): iStat draws hover and selection as a 1 pt accent
        // line inset by 1 over the card at every scale (spec §3.3); the
        // resting border keeps the one-pixel hairline. Was `1 / scale` in
        // every state. The highlight is an overlay, so the card's size, and
        // with it the content, never moves.
        for scale: CGFloat in [1, 2] {
            for active in [false, true] {
                for selected in [false, true] {
                    XCTAssertEqual(GeekVisualTokens.cardBorderLineWidth(isActive: active, isSelected: selected, displayScale: scale),
                                   active || selected ? GeekVisualTokens.cardHighlightLineWidth : 1 / scale)
                }
            }
        }
        XCTAssertEqual(GeekVisualTokens.cardHighlightLineWidth, 1)
        XCTAssertEqual(GeekVisualTokens.cardHighlightInset, 1)
        let sizes = [(false, false), (true, false), (false, true)].map { active, selected in
            NSHostingView(rootView: GeekCombinedCard(height: 40) { Text("CPU") }
                .environment(\.geekCombinedCardIsActive, active)
                .environment(\.geekCombinedCardIsSelected, selected)
                .frame(width: 285)).fittingSize
        }
        XCTAssertEqual(Set(sizes.map { "\($0.width)x\($0.height)" }).count, 1, "\(sizes)")
    }

    func testParentOwnedInsetIsAppliedExactlyOnceForInlineHistory() {
        let content = GeekHoverDetailCanvas(title: "CPU") { Color.clear.frame(height: 40) }
        let standalone = NSHostingView(rootView: content.frame(width: 300))
        let parentOwned = NSHostingView(rootView: content
            .environment(\.miniWindowPageProvidesInset, true)
            .padding(MiniWindowStyleTokens.contentInset).frame(width: 300))
        standalone.layoutSubtreeIfNeeded()
        parentOwned.layoutSubtreeIfNeeded()
        XCTAssertEqual(standalone.fittingSize.height, parentOwned.fittingSize.height, accuracy: 1)
    }

    func testTouchingCascadeFitsBothDirectionsAndNegativeCoordinateDisplaysFor100Layouts() throws {
        for index in 0..<100 {
            let left = index.isMultiple(of: 2)
            let visible = CGRect(x: left ? -1500 : 0, y: 24, width: 1400, height: 1000)
            let parent = CGRect(x: visible.minX + (left ? 1050 : 30), y: 400, width: 304, height: 544)
            let plan = MenuBarPanelPlacement.reflowingCascade(parentFrame: parent,
                childSizes: [.init(width: 312, height: 480), .init(width: 380, height: 310)],
                visibleFrame: visible, preferredDirection: left ? .left : .right,
                backingScaleFactor: index.isMultiple(of: 3) ? 1 : 2)
            XCTAssertFalse(plan.isCompact)
            XCTAssertTrue(visible.contains(plan.containerFrame))
            let frames = ([plan.parentFrame] + plan.childFrames).sorted { $0.minX < $1.minX }
            for pair in zip(frames, frames.dropFirst()) {
                XCTAssertEqual(pair.1.minX - pair.0.maxX, 0, accuracy: 0.001)
            }
        }
    }

    private func resolve(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues(); environment.colorScheme = scheme
        return color.resolve(in: environment)
    }
}
