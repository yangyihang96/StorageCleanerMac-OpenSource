import Foundation
import XCTest
@testable import StorageCleanerMac

final class SettingsLightfieldContractTests: XCTestCase {
    func testFrozenSettingsReferenceGeometryAndSevenSizeMatrix() {
        let windows: [CGSize] = [.init(width: 1180, height: 760), .init(width: 820, height: 560),
            .init(width: 1000, height: 700), .init(width: 1280, height: 763), .init(width: 1680, height: 1050),
            .init(width: 2400, height: 1350), .init(width: 677, height: 390), .init(width: 1280, height: 390)]
        for window in windows {
            let size = CGSize(width: window.width - (window.width < 820 ? 180 : 210), height: window.height - 28)
            let bounds = CGRect(origin: .zero, size: size)
            for category in SettingsCategory.allCases {
                let geometry = SettingsLightfieldGeometry(size: size, category: category)
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
        XCTAssertTrue(settings.contains("SettingsLightfieldPane(category: category)"))
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
        for type in ["PanelStatusColorPreset", "PanelSurfacePreset", "PanelColorTheme", "PanelMetricColorRole"] {
            XCTAssertTrue(general.contains(type + ".allCases"), type)
        }
        XCTAssertEqual(PanelStatusColorPreset.allCases.count, 11)
        XCTAssertEqual(PanelSurfacePreset.allCases.count, 10)
        XCTAssertEqual(PanelColorTheme.allCases.count, 6)
        XCTAssertEqual(PanelMetricColorRole.allCases.count, 18)
        XCTAssertEqual(Set(PanelMetricColorRole.allCases.map(\.defaultsKey)).count, 18)
        XCTAssertTrue(general.contains("SettingsMiniWindowPreview(configuration: settingsConfiguration.configuration)"))
        XCTAssertTrue(general.contains("ColorPicker"))
        XCTAssertTrue(general.contains("selectedSurfacePreset.wrappedValue == .original"))
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
