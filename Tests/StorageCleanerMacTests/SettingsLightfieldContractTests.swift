import Foundation
import XCTest
@testable import StorageCleanerMac

final class SettingsLightfieldContractTests: XCTestCase {
    func testFrozenSettingsReferenceGeometryAndSevenSizeMatrix() {
        let windows: [CGSize] = [.init(width: 1180, height: 760), .init(width: 820, height: 560),
            .init(width: 1000, height: 700), .init(width: 1280, height: 763), .init(width: 1680, height: 1050),
            .init(width: 2400, height: 1350), .init(width: 677, height: 390), .init(width: 1280, height: 390)]
        for window in windows {
            // D154 batch 3I: the pane spans the window under the tabs and their
            // hairline (was `window.width - (window.width < 820 ? 180 : 210)` wide
            // and `window.height - 28` high, beside the sidebar).
            let size = CGSize(width: window.width, height: window.height - 28 - SettingsTabBar.height - 1)
            for category in SettingsCategory.allCases {
                let geometry = SettingsLightfieldGeometry(size: size, category: category)
                // D210＋旧值：was `let bounds = CGRect(origin: .zero, size: size)`
                // for every page. The ignore list keeps its minimum content
                // height in a shorter window and the whole page scrolls, so its
                // content and footer sit in the page's document; every other
                // page's document is still the viewport.
                if category == .ignoreList {
                    XCTAssertGreaterThanOrEqual(geometry.content.height, SettingsIgnoreListMetrics.minimumHeight, "\(window)")
                } else {
                    XCTAssertEqual(geometry.documentHeight, size.height, "\(window)/\(category) must not scroll")
                }
                let bounds = CGRect(origin: .zero, size: CGSize(width: size.width, height: geometry.documentHeight))
                XCTAssertTrue(bounds.contains(geometry.title), "\(window)/\(category)/title")
                XCTAssertTrue(bounds.contains(geometry.content), "\(window)/\(category)/content")
                XCTAssertGreaterThanOrEqual(geometry.content.minY, geometry.title.maxY)
            }
        }
        let reference = CGSize(width: 970, height: 732)
        // D272: every page starts at the same place, so the title stays put
        // between tabs (was title (96, 92), content (96, 176, 778, 424) and a
        // footer (96, 624, 778, 108) on the pages without a preview).
        for category in SettingsCategory.allCases where category != .ignoreList {
            let page = SettingsLightfieldGeometry(size: reference, category: category)
            XCTAssertEqual(page.title.origin, .init(x: 52, y: 12), "\(category)")
            XCTAssertEqual(page.content, CGRect(x: 52, y: 72, width: 894, height: 660), "\(category)")
        }
    }

    func testAllSevenPagesUseB2SkeletonAndFlatRowsWithoutDiscardingActions() throws {
        let settings = try SettingsSourceContract.source(at: root.appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift"))
        // D154 batch 3I: the window draws the backdrop (was
        // `SettingsLightfieldPane(category: category)`).
        XCTAssertTrue(settings.contains("SettingsLightfieldPane(category: category, drawsBackdrop: false)"))
        XCTAssertTrue(settings.contains("FeatureLightfieldBackdrop("))
        XCTAssertTrue(settings.contains("FeatureLightfieldHairline()"))
        XCTAssertTrue(settings.contains("FeatureLightfieldRowButtonStyle()"))
        XCTAssertFalse(settings.contains(".formStyle(.grouped)"))
        XCTAssertFalse(settings.contains(".formStyle(.columns)"))
        for token in [".ultraThinMaterial", ".regularMaterial", ".thinMaterial", "NSVisualEffectView"] {
            XCTAssertFalse(settings.contains(token), token)
        }
        // D272: was also "addExclusion()", "copyExclusions()", "clearExclusions()"
        // (the Scan Exclusions group; the ignore list's Other category has them).
        for action in ["showsOperations = true",
            "ApplicationUpdatePreferences", "resetUpdateSources()", "copyRuntimeDiagnostics()",
            "showsSupportExport", "await fanControl.unregisterHelper()", "await fanControl.selectMode(.maximum)"] {
            XCTAssertTrue(settings.contains(action), action)
        }
        // D272: was also "LightfieldPathText(path: path)", in the removed exclusion row.
        XCTAssertTrue(settings.contains(".truncationMode(.middle)"))
        // D272: was XCTAssertTrue(settings.contains("偏好更改即时保存")) (the footer
        // repeating that on every page). Preferences still save at once; only the
        // module list has Apply.
    }

    func testSettingsColorsExposeEveryExistingPresetAndMetricKey() throws {
        // D272: these moved from General to the menu bar page's icon and appearance parts.
        let general = try ["Sources/StorageCleanerMac/Views/Settings/SettingsMiniWindow.swift",
                           "Sources/StorageCleanerMac/Views/Settings/SettingsCombinedStatusIcon.swift"]
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        for type in ["PanelStatusColorPreset", "PanelMetricColorRole"] {
            XCTAssertTrue(general.contains(type + ".allCases"), type)
        }
        // D135 (R9a): iStat's theme choices (system and 14 themes, one picker
        // per appearance) replace the dropdown surface and chart color
        // presets, which were in the list above; their types stay.
        for type in ["PanelSurfacePreset", "PanelColorTheme"] {
            XCTAssertFalse(general.contains(type + ".allCases"), type)
        }
        XCTAssertEqual(general.components(separatedBy: "items: IStatMenuThemeChoice.all").count - 1, 2)
        XCTAssertEqual(IStatMenuThemeChoice.all.count, 15)
        XCTAssertEqual(PanelStatusColorPreset.allCases.count, 11)
        XCTAssertEqual(PanelSurfacePreset.allCases.count, 10)
        XCTAssertEqual(PanelColorTheme.allCases.count, 6)
        XCTAssertEqual(PanelMetricColorRole.allCases.count, 18)
        XCTAssertEqual(Set(PanelMetricColorRole.allCases.map(\.defaultsKey)).count, 18)
        // D272: was settingsConfiguration.configuration (General had no draft).
        XCTAssertTrue(general.contains("SettingsMiniWindowPreview(configuration: miniWindowDraft.value)"))
        XCTAssertTrue(general.contains("ColorPicker"))
        // D135: was XCTAssertTrue(general.contains("selectedSurfacePreset.wrappedValue == .original"))
        // (the custom background color showed only on the original surface).
        XCTAssertFalse(general.contains("selectedSurfacePreset"))
        XCTAssertTrue(general.contains("isOn: $menuThemeVibrancy"))
    }

    /// The settings window's background is clear, so a backdrop that stopped
    /// at the title bar left a see-through strip above the pane (2.0.1).
    func testPaneBackdropAlsoFillsTheTitleBar() throws {
        let lightfield = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/Settings/SettingsLightfield.swift"), encoding: .utf8)
        let pane = try r2SourceDeclaration("struct SettingsLightfieldPane", in: lightfield)
        let backdrop = try XCTUnwrap(pane.range(of: ".background {").map { String(pane[$0.lowerBound...]) },
            "The backdrop sits behind the pane, not inside its safe-area GeometryReader")
        XCTAssertTrue(backdrop.contains("FeatureLightfieldBackdrop(module: .overview"))
        XCTAssertTrue(backdrop.contains("canvasTopInset: topInset"))
        XCTAssertTrue(backdrop.contains(".ignoresSafeArea(.container, edges: .top)"))
        XCTAssertEqual(pane.components(separatedBy: "FeatureLightfieldBackdrop(").count, 2, "One backdrop")
        // D154 batch 3I: the window draws that backdrop once behind the tabs
        // and the pane, and the pane leaves its own out.
        let settings = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/SettingsView.swift"), encoding: .utf8)
        let body = try XCTUnwrap(settings.range(of: "    var body: some View {").map { String(settings[$0.lowerBound...]) })
        let window = String(body.prefix(1_400))
        XCTAssertTrue(window.contains("settingsTabBar"))
        XCTAssertTrue(window.contains("FeatureLightfieldBackdrop(module: .overview"))
        XCTAssertTrue(window.contains(".ignoresSafeArea(.container, edges: .top)"))
        XCTAssertTrue(settings.contains("SettingsLightfieldPane(category: category, drawsBackdrop: false)"))
        XCTAssertTrue(pane.contains("if drawsBackdrop {"))
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
