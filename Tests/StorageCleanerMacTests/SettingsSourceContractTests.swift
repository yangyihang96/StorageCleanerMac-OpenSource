import Foundation
import XCTest

/// Pure-split evidence: guards still inspect all seven production settings pages.
final class SettingsSourceContractTests: XCTestCase {
    private let pageNames = [
        "SettingsGeneral.swift", "SettingsMiniWindow.swift", "SettingsScan.swift",
        "SettingsAccess.swift", "SettingsSystem.swift", "SettingsUpdates.swift", "SettingsAbout.swift",
        // D207＋旧值：7 个设置页，新增第 8 页“忽略列表”；仍逐个检查全部文件。
        "SettingsIgnoreList.swift",
    ]

    func testMergedSettingsSourceIncludesRootAndAllSevenProductionPages() throws {
        let directory = settingsURL.deletingLastPathComponent().appendingPathComponent("Settings")
        let actualPages = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.map(\.lastPathComponent)
        // D153: plus the combined status icon's section (was without
        // "SettingsCombinedStatusIcon.swift").
        // D273＋旧值：没有 "SettingsAIAssistant.swift"。AI 助手页是独立视图，只读给它的
        // AgentInterface，不是 extension SettingsView，所以不进 pageNames。
        XCTAssertEqual(Set(actualPages), Set(pageNames + [
            "SettingsLightfield.swift", "SettingsPermissionRow.swift", "SettingsActivationRefresh.swift", "SettingsMiniWindowPreview.swift",
            "SettingsCombinedStatusIcon.swift", "SettingsAIAssistant.swift",
        ]))

        let root = try String(contentsOf: settingsURL, encoding: .utf8)
        // D154 batch 3I: the tabs replace the sidebar (was
        // `private var settingsSidebar: some View`).
        XCTAssertTrue(root.contains("private var settingsTabBar: some View"))
        XCTAssertTrue(root.contains("private func settingsSections(for category: SettingsCategory)"))
        var expected = root
        for name in actualPages.sorted() {
            let page = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            if pageNames.contains(name) { XCTAssertTrue(page.contains("extension SettingsView {"), name) }
            expected += "\n" + page
        }
        XCTAssertEqual(try SettingsSourceContract.source(at: settingsURL), expected)
    }

    /// D274: a pop-up menu draws its title in the tint, and the window's tint is the
    /// one for white labels on a fill. The count is the settings window's list.
    func testEveryMenuPickerInTheSettingsWindowDrawsItsTitleAsAValue() throws {
        let views = settingsURL.deletingLastPathComponent()
        let sources = [
            try SettingsSourceContract.source(at: settingsURL),
            try String(contentsOf: views.appendingPathComponent("FanCurveEditor.swift"), encoding: .utf8),
            try String(contentsOf: views.deletingLastPathComponent().appendingPathComponent(
                "Features/AppLifecycle/Reminders/UI/AppLifecycleReminderSettingsSection.swift"), encoding: .utf8),
        ]
        var checked = 0
        for source in sources {
            for following in source.components(separatedBy: ".pickerStyle(.menu)").dropFirst() {
                XCTAssertTrue(following.prefix(60).contains(".featureLightfieldMenuTint()"), String(following.prefix(60)))
                checked += 1
            }
        }
        XCTAssertEqual(checked, 5)
    }

    /// D274: as text the overview accent measured 2.3–2.4:1 on the day canvas.
    func testTextThatActsInTheSettingsWindowTakesTheColorChosenForIt() throws {
        let settings = try SettingsSourceContract.source(at: settingsURL)
        let link = try r2SourceDeclaration("struct SettingsLinkButton", in: settings)
        XCTAssertTrue(link.contains("FeatureLightfieldPalette.settingsAction"))
        XCTAssertFalse(settings.contains(".foregroundStyle(FeatureLightfieldPalette.accent(.overview)"))
        let modules = try String(contentsOf: settingsURL.deletingLastPathComponent().appendingPathComponent(
            "MiniWindowConfigurationSettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(modules.contains("accent(.overview)"))
        XCTAssertFalse(settings.contains("FeatureLightfieldBackdrop(module: .overview, phase: .landing"))
    }

    func testSharedSourceGuardReadersSeeEveryExtractedCategory() throws {
        let merged = try SettingsSourceContract.source(at: settingsURL)
        let readers: [(String, String)] = [
            ("r2ProductionSource", try r2ProductionSource(at: settingsURL)),
            ("MiniWindowLogicFixtures", try MiniWindowLogicFixtures.source(
                "Sources/StorageCleanerMac/Views/SettingsView.swift"
            )),
        ]
        let declarations = [
            "var interfaceSection:", "var miniWindowSettings:", "var maintenanceReminderSection:",
            "var permissionSetupSection:", "var fanControlSection:", "var updateSourceSection:", "var aboutSection:",
        ]
        for (reader, source) in readers {
            XCTAssertEqual(source, merged, reader)
            for declaration in declarations {
                let body = try r2SourceDeclaration(declaration, in: source)
                XCTAssertTrue(body.hasPrefix(declaration), "\(reader): \(declaration)")
            }
        }
    }

    func testOtherViewSourceGuardsKeepTheirSingleFileScope() throws {
        for name in ["MiniWindowConfigurationSettingsView.swift", "MenuBarPanelSettingsView.swift"] {
            let url = settingsURL.deletingLastPathComponent().appendingPathComponent(name)
            let original = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(try SettingsSourceContract.source(at: url), original, name)
            XCTAssertEqual(try r2ProductionSource(at: url), original, name)
            XCTAssertEqual(try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/" + name), original, name)
        }
    }

    private var settingsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SettingsView.swift")
    }
}
