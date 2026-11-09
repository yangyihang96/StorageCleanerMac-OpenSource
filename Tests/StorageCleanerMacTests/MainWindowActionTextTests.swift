import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D276: text that acts on a main-window page (a menu's title, a link, a
/// borderless or bordered button, the unit beside a reading) reads 4.5:1 on
/// its module's gradient. The tint stays the module's fill colour.
@MainActor
final class MainWindowActionTextTests: XCTestCase {
    func testEveryModuleActionTextReadsOnItsGradientInBothAppearances() {
        var whiteAtNight: [CareStudioFamily] = []
        for family in CareStudioFamily.allCases {
            let palette = family.palette
            let day = palette.readableText(palette.action[1], night: false)
            XCTAssertGreaterThanOrEqual(worst(day, on: dayGrounds(palette)), 4.5, "\(family) day #\(hex(day))")
            XCTAssertTrue(channels(day).elementsEqual(channels(palette.action[1]), by: <=), "\(family) darkens by day")

            let night = palette.readableText(palette.actionGlow, night: true)
            XCTAssertTrue(channels(night).elementsEqual(channels(palette.actionGlow), by: >=), "\(family) lightens at night")
            if worst(night, on: nightGrounds(palette)) < 4.5 {
                // Only white is left: the glow itself is too bright for any colour.
                XCTAssertEqual(night, 0xFFFFFF, "\(family) night #\(hex(night))")
                whiteAtNight.append(family)
            }
            assertResolves(CareStudioInk.actionText(for: family), day: day, night: night, "\(family)")
        }
        XCTAssertEqual(whiteAtNight, [.performance, .clutter, .cloudCleanup])
    }

    func testPagesWithTheirOwnAccentKeepItsHueAndOtherPagesTakeTheirModules() {
        let smartCare = CareStudioFamily.smartCare.palette, cleanup = CareStudioFamily.cleanup.palette
        assertResolves(FeatureLightfieldPalette.actionText(.overview),
                       day: smartCare.readableText(0x2A55D6, night: false),
                       night: smartCare.readableText(0x4F8BFF, night: true), "overview")
        assertResolves(FeatureLightfieldPalette.actionText(.green),
                       day: cleanup.readableText(0xC4441A, night: false),
                       night: cleanup.readableText(0xFF7A2F, night: true), "green")
        for module in [ReviewFilter.updater, .startup, .duplicates, .performance] {
            let palette = CareStudioFamily(route: module).palette
            assertResolves(FeatureLightfieldPalette.actionText(module),
                           day: palette.readableText(palette.action[1], night: false),
                           night: palette.readableText(palette.actionGlow, night: true), "\(module)")
        }
        // The utility hub has no module gradient; it keeps its accent.
        XCTAssertEqual(resolve(FeatureLightfieldPalette.actionText(.utilityHub), .light),
                       resolve(FeatureLightfieldPalette.accent(.utilityHub), .light))
    }

    /// A borderless menu draws its title in the tint. The menu bar panels and
    /// the mini window's settings are not on a module gradient.
    func testEveryBorderlessMenuOnAMainWindowPageTakesTheReadableActionColour() throws {
        let offStudio: Set = ["MiniWindowConfigurationSettingsView.swift", "MenuBarPanelChrome.swift", "GeekMemoryView.swift"]
        var checked = 0
        for (name, source) in try sources() where !offStudio.contains(name) {
            for following in source.components(separatedBy: ".menuStyle(.borderlessButton)").dropFirst() {
                XCTAssertTrue(following.hasPrefix(".careStudioActionTint()"), "\(name): \(following.prefix(40))")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 37)
    }

    /// D274's rule for the whole app: a menu picker's title is the setting's value.
    func testEveryMenuPickerDrawsItsTitleAsAValue() throws {
        var checked: [String] = []
        for (name, source) in try sources() {
            for following in source.components(separatedBy: ".pickerStyle(.menu)").dropFirst() {
                XCTAssertTrue(following.prefix(60).contains(".featureLightfieldMenuTint()"), "\(name): \(following.prefix(60))")
                checked.append(name)
            }
        }
        // D276＋旧值：设置窗口 5 个（D274），加主窗口 5 个。
        XCTAssertEqual(checked.count, 10, "\(checked)")
        XCTAssertEqual(checked.filter { ["AppUpdatesView.swift", "CleanupScanViews.swift", "BenchmarkV7DashboardView.swift"].contains($0) }.count, 5)
    }

    func testButtonsThatDrawTheirTitleInTheTintAndTheLightfieldTextTakeTheActionColour() throws {
        let all = Dictionary(try sources(), uniquingKeysWith: { first, _ in first })
        let host = try XCTUnwrap(all["ModulePresentation.swift"])
        XCTAssertTrue(host.contains(".environment(\\.careStudioActionText, studio.map { CareStudioInk.actionText(for: $0.family) })"))
        XCTAssertTrue(host.contains("        .buttonStyle(.bordered)\n        .careStudioActionTint()"), "GlassToolbarButton")
        let controls = try XCTUnwrap(all["AppControls.swift"])
        XCTAssertEqual(controls.components(separatedBy: ".careStudioActionTint()").count - 1, 3, "bordered and borderless chrome")
        for (name, count) in ["FeatureLightfield.swift": 3, "FeatureLightfieldComponents.swift": 1,
                              "FeatureLightfieldResultSpace.swift": 1, "CleanupScanViews.swift": 1,
                              "PerformanceBenchmarkV11ResultPage.swift": 3] {
            let source = try XCTUnwrap(all[name])
            XCTAssertEqual(source.components(separatedBy: "FeatureLightfieldPalette.actionText(").count - 1, count, name)
        }
        // What is left of the accent as a foreground is the glyphs (non-text).
        var glyphs: [String] = []
        for (name, source) in try sources() where !name.hasPrefix("Settings") {
            for marker in [".foregroundStyle(FeatureLightfieldPalette.accent(", ".foregroundColor(FeatureLightfieldPalette.accent("] {
                glyphs += Array(repeating: name, count: source.components(separatedBy: marker).count - 1)
            }
        }
        XCTAssertEqual(glyphs.sorted(), ["ApplicationsManagerSheets.swift", "ApplicationsManagerSheets.swift", "SystemUpdateAvailableCard.swift"])
    }

    /// The studio start page shows the readiness panel on a plain sheet, which inherits the
    /// page's environment; there its buttons keep their own tints over the action colour.
    func testTheReadinessPanelKeepsItsButtonsOwnTints() throws {
        let all = Dictionary(try sources(), uniquingKeysWith: { first, _ in first })
        let content = try XCTUnwrap(all["ContentView.swift"])
        let start = try XCTUnwrap(content.range(of: "private struct ScanReadinessPanel: View {"))
        let end = content.range(of: "\nprivate struct ", range: start.upperBound..<content.endIndex)?.lowerBound ?? content.endIndex
        let panel = content[start.upperBound..<end]
        XCTAssertTrue(panel.contains(".environment(\\.careStudioActionText, nil)"))
        XCTAssertTrue(panel.contains(".appButtonChrome(.secondary)\n                .tint(AppDesignTokens.Palette.information)"), "Allow Folders")
        XCTAssertTrue(panel.contains(".appButtonChrome(.secondary)\n        .tint(tint)"), "Check Current")
    }

    // MARK: - Helpers

    private func dayGrounds(_ palette: CareStudioPalette) -> [UInt32] {
        let day = palette.daylight
        return [day.deep, day.base] + day.glows
    }

    private func nightGrounds(_ palette: CareStudioPalette) -> [UInt32] {
        [palette.base, palette.deep, blend(0xFFFFFF, 0.16, over: palette.base)]
            + CareStudioBackdrop.glows.map { blend(palette.glows[$0.colorIndex], $0.opacity, over: palette.base) }
    }

    private func worst(_ color: UInt32, on grounds: [UInt32]) -> Double {
        grounds.map { contrast(color, $0) }.min() ?? 0
    }

    private func blend(_ top: UInt32, _ opacity: Double, over bottom: UInt32) -> UInt32 {
        zip(channels(top), channels(bottom)).reduce(0) { packed, pair in
            packed << 8 | UInt32((Double(pair.0) * opacity + Double(pair.1) * (1 - opacity)).rounded())
        }
    }

    private func channels(_ hex: UInt32) -> [UInt32] { [hex >> 16 & 0xff, hex >> 8 & 0xff, hex & 0xff] }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let linear = channels(hex).map { channel -> Double in
                let value = Double(channel) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func hex(_ value: UInt32) -> String { String(format: "%06X", value) }

    private func assertResolves(_ color: Color, day: UInt32, night: UInt32, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        for (scheme, expected) in [(ColorScheme.light, day), (.dark, night)] {
            let resolved = resolve(color, scheme)
            let actual = [resolved.red, resolved.green, resolved.blue].reduce(UInt32(0)) {
                $0 << 8 | UInt32((Double($1) * 255).rounded())
            }
            XCTAssertEqual(hex(actual), hex(expected), "\(label) \(scheme)", file: file, line: line)
        }
    }

    private func resolve(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues(); environment.colorScheme = scheme
        return color.resolve(in: environment)
    }

    /// Every app source file, by file name.
    private func sources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
}
