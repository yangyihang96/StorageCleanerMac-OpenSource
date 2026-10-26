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
                XCTAssertTrue(bounds.contains(geometry.footer), "\(window)/\(category)/footer")
                XCTAssertGreaterThanOrEqual(geometry.content.minY, geometry.title.maxY)
                if !geometry.hasPreview {
                    XCTAssertEqual(geometry.footer.minY - geometry.content.maxY, 24, accuracy: 0.5)
                }
            }
        }
        let reference = CGSize(width: 970, height: 732)
        let standard = SettingsLightfieldGeometry(size: reference, category: .accessAndSetup)
        XCTAssertEqual(standard.title.origin, .init(x: 96, y: 92))
        XCTAssertEqual(standard.content, CGRect(x: 96, y: 176, width: 778, height: 424))
        XCTAssertEqual(standard.footer, CGRect(x: 96, y: 624, width: 778, height: 108))
        let preview = SettingsLightfieldGeometry(size: reference, category: .general)
        XCTAssertEqual(preview.title.origin, .init(x: 52, y: 12))
        XCTAssertEqual(preview.content, CGRect(x: 52, y: 64, width: 894, height: 668))
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
        for action in ["showsOperations = true", "addExclusion()", "copyExclusions()", "clearExclusions()",
            "ApplicationUpdatePreferences", "resetUpdateSources()", "copyRuntimeDiagnostics()",
            "showsSupportExport", "await fanControl.unregisterHelper()", "await fanControl.selectMode(.maximum)"] {
            XCTAssertTrue(settings.contains(action), action)
        }
        XCTAssertTrue(settings.contains("LightfieldPathText(path: path)"))
        XCTAssertTrue(settings.contains(".truncationMode(.middle)"))
        XCTAssertTrue(settings.contains("偏好更改即时保存"), "General keeps its established immediate persistence semantics")
    }

    func testSettingsColorsExposeEveryExistingPresetAndMetricKey() throws {
        let general = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/Settings/SettingsGeneral.swift"), encoding: .utf8)
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
        XCTAssertTrue(general.contains("SettingsMiniWindowPreview(configuration: settingsConfiguration.configuration)"))
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
