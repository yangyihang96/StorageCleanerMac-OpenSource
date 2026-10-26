import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// 2.0.1 runtime UI review, second round: rows that looked like something
/// they were not, and text that showed tool names instead of words.
final class RuntimeUIRound201Tests: XCTestCase {
    /// `MemoryAppUsage` carries no CPU or energy readings, so the memory
    /// table has no columns that could only ever show “—”.
    func testMemoryTableShowsNoColumnsItHasNoDataFor() throws {
        let app = MemoryAppUsage(id: "app", name: "App", iconPath: "", bundlePath: nil, bytes: 1, canQuit: false,
            isActive: false, percent: 1, processCount: 1, processIDs: [1], selectableProcessIDs: [])
        let fields = Mirror(reflecting: app).children.compactMap { $0.label?.lowercased() }
        XCTAssertFalse(fields.contains { $0.contains("cpu") || $0.contains("energy") },
            "Once the snapshot reads CPU or energy, show them as columns again")
        let page = try source("Sources/StorageCleanerMac/Views/LightfieldMemoryPage.swift")
        let row = try r2SourceDeclaration("struct LightfieldMemoryAppRow", in: page)
        XCTAssertFalse(row.contains("id: \"cpu\""))
        XCTAssertFalse(row.contains("id: \"energy\""))
        XCTAssertFalse(page.contains("CPU% · 能耗影响"))
        XCTAssertTrue(page.contains("各应用的 CPU% 与能耗见“能耗”页"), "The header says where those readings are")
    }

    /// Login items always check all three scopes. Their rows state that fact
    /// and must not look like the boxed check of a row that can be toggled.
    func testAlwaysIncludedScopeIsNotDrawnAsACheckbox() throws {
        let components = try source("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldComponents.swift")
        let row = try r2SourceDeclaration("struct LightfieldOptionRow", in: components)
        let included = try XCTUnwrap(row.range(of: "else if isIncluded {").map { String(row[$0.lowerBound...].prefix(400)) })
        XCTAssertFalse(included.contains("FeatureLightfieldCheck("))
        XCTAssertTrue(included.contains("Image(systemName: \"checkmark\")"))
        XCTAssertEqual(row.components(separatedBy: "FeatureLightfieldCheck(").count - 1, 1,
            "Only a row with a selection draws the boxed check")
    }

    /// The row names the evidence in words; the command line it came from is
    /// kept for the expanded detail and the event journal.
    @MainActor
    func testSystemQueryRowNamesTheEvidenceWithoutItsCommand() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            for check in SystemProtectionCheck.healthChecks {
                let finding = SystemProtectionFinding(check: check, state: .enabled, evidence: .systemQuery)
                XCTAssertEqual(finding.evidenceRowSummary,
                    language == .zhHans ? "系统查询确认" : "Confirmed by a System Query", check.rawValue)
                if let command = check.queryDisplayName {
                    XCTAssertFalse(finding.evidenceRowSummary.contains(command), check.rawValue)
                    XCTAssertTrue(finding.evidenceSummary.contains(command), "The journal text keeps the command")
                }
            }
            let failed = SystemProtectionFinding(check: .firewall, state: .unreadable, evidence: .readTimedOut)
            XCTAssertEqual(failed.evidenceRowSummary, failed.evidenceSummary, "Other evidence reads the same in both places")
            let legacy = SystemProtectionFinding(check: .firewall, state: .enabled, evidence: .legacy("旧版证据"))
            XCTAssertEqual(legacy.evidenceRowSummary, "旧版证据")
        }
    }

    /// The energy page's helper block is titled in words; the tool name is
    /// only its help, as in the menu-bar cards.
    func testPowerMetricsTitleIsInWordsAndTheToolNameIsHelp() throws {
        XCTAssertFalse(HelperPowerMetricsPresentation.title.contains("powermetrics"))
        let view = try source("Sources/StorageCleanerMac/Views/HelperPowerMetricsView.swift")
        XCTAssertFalse(view.contains("Text(HelperPowerMetricsPresentation.source)"))
        XCTAssertTrue(view.contains("Text(HelperPowerMetricsPresentation.title)"))
        XCTAssertTrue(view.contains(".help(HelperPowerMetricsPresentation.source)"))
    }

    /// Similar photos had a bare “用户文件 ⌄” menu under its two scope rows.
    func testSimilarPhotosScopeMenuIsATitledRow() throws {
        let utilities = try source("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let options = try r2SourceDeclaration("private var duplicateLightfieldOptions", in: utilities)
        let similar = try XCTUnwrap(options.range(of: "if isSimilarPhotosRoute {").flatMap { start in
            options.range(of: "} else {", range: start.upperBound..<options.endIndex).map { String(options[start.lowerBound..<$0.lowerBound]) }
        })
        XCTAssertTrue(similar.contains("Text(L10n.text(\"扫描范围\", \"Scan Scope\"))"))
        XCTAssertTrue(similar.contains(".frame(height: FeatureLightfield.optionHeight)"))
        XCTAssertFalse(similar.contains(".frame(height: 40)"))
    }

    /// The threshold row is about which files count; the shield means
    /// verification and the documents icon is already “可搬移大文件”.
    func testMigrationThresholdDoesNotUseTheVerificationShield() throws {
        let files = try source("Sources/StorageCleanerMac/Views/LargeFilesView.swift")
        let control = try r2SourceDeclaration("private var largeFileThresholdControl", in: files)
        XCTAssertFalse(control.contains(".migrationVerification"))
        XCTAssertFalse(control.contains(".migrationDocuments"), "Two rows on one page would share an icon")
        XCTAssertTrue(control.contains(".migrationItemType"))
    }

    /// The selected palette name sits with its title, and a custom item is
    /// told apart from the preset it falls back to.
    func testPalettePickerNamesTheSelectionByItsTitleAndMarksCustom() throws {
        let lightfield = try source("Sources/StorageCleanerMac/Views/Settings/SettingsLightfield.swift")
        let picker = try r2SourceDeclaration("struct SettingsPalettePicker", in: lightfield)
        XCTAssertFalse(picker.contains(".frame(width: 96, alignment: .trailing)"), "No name alone at the far side")
        XCTAssertTrue(picker.contains("Text(name(selection))"))
        XCTAssertTrue(picker.contains("if isCustom(item) {"))
        XCTAssertTrue(picker.contains("AngularGradient("))
        let general = try source("Sources/StorageCleanerMac/Views/Settings/SettingsGeneral.swift")
        let section = try r2SourceDeclaration("var panelAppearanceSection", in: general)
        // D135: the chart color picker, the other one with a custom item,
        // left with iStat's themes; was 2 ("Both pickers with a custom item mark it").
        XCTAssertEqual(section.components(separatedBy: "isCustom: { $0 == .custom }").count - 1, 1,
            "The picker with a custom item marks it")
        XCTAssertTrue(PanelStatusColorPreset.allCases.contains(.custom))
        XCTAssertTrue(PanelColorTheme.allCases.contains(.custom))
    }

    /// The memory summary shows a number with its unit apart, as the other
    /// summaries do; mixed or missing units keep the full text.
    func testMemorySummarySplitsASharedUnit() {
        let split = LightfieldMemoryResultOverview.sharedUnit("41.0 GiB / 48.0 GiB")
        XCTAssertEqual(split.value, "41.0 / 48.0")
        XCTAssertEqual(split.unit, "GiB")
        XCTAssertEqual(LightfieldMemoryResultOverview.sharedUnit("12.75 GB / 16 GB").value, "12.75 / 16")
        for kept in ["512 MiB / 48.0 GiB", "— / —", "41.0 GiB"] {
            let result = LightfieldMemoryResultOverview.sharedUnit(kept)
            XCTAssertEqual(result.value, kept)
            XCTAssertEqual(result.unit, "")
        }
        // D178: the memory page writes memory as Activity Monitor does, "41 GB"
        // (was `ByteFormat.string`, "41.0 GiB", which split as "GiB").
        let used = ByteFormat.memoryString(41 * 1_073_741_824), total = ByteFormat.memoryString(48 * 1_073_741_824)
        XCTAssertEqual(LightfieldMemoryResultOverview.sharedUnit(used + " / " + total).unit, "GB",
            "ByteFormat output splits as expected")
    }

    /// The landing shows over a legacy history (D72), so its entry check runs
    /// there too, and an item it has not read is named, never a bare “未读取”.
    func testPerformanceLandingChecksOverALegacyHistoryAndNamesUnreadItems() throws {
        let workspace = try source("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkWorkspaceView.swift")
        XCTAssertFalse(workspace.contains("if displayedResult == nil && !benchmarkStore.isRunning"),
            "An empty-history test skipped the check whenever a legacy result existed")
        XCTAssertTrue(workspace.contains("} else if showsLandingPage {"))
        XCTAssertTrue(workspace.contains("if showsLandingPage && !showsSavedDashboard && !benchmarkStore.isRunning {"))
        let landing = try source("Sources/StorageCleanerMac/Views/ComputerHealth/PerformanceBenchmarkLandingView.swift")
        let text = try r2SourceDeclaration("private var preflightText", in: landing)
        XCTAssertFalse(text.contains("?? MSeriesV11PagePresentation.unread"), "No unread value without its name")
        XCTAssertFalse(text.contains(": MSeriesV11PagePresentation.unread"), "No unread value without its name")
        XCTAssertFalse(text.contains("? MSeriesV11PagePresentation.unread"), "No unread value without its name")
        XCTAssertTrue(text.contains("isPreflighting ?"), "The line says when the check is running")
    }

    /// A borderless Menu shows only its label's text and a chevron, so the
    /// migration rows keep the icon, title and free-space bar outside it.
    func testMigrationMenusAreTitledRowsWithTheValueInTheMenu() throws {
        let files = try source("Sources/StorageCleanerMac/Views/LargeFilesView.swift")
        for marker in ["private var migrationSourceControl", "private var migrationDestinationControl"] {
            let control = try r2SourceDeclaration(marker, in: files)
            XCTAssertTrue(control.hasPrefix(marker + ": some View {\n        HStack(spacing: 8) {"), marker)
            let label = try XCTUnwrap(control.range(of: "} label: {").map { String(control[$0.upperBound...]) }, marker)
            let labelBody = String(label.prefix(while: { $0 != "}" }))
            for flattened in ["LightfieldOptionIconView", "FeatureLightfieldHairline", "LightfieldDataBar", ".frame("] {
                XCTAssertFalse(labelBody.contains(flattened), "\(marker): \(flattened) inside the menu label")
            }
        }
    }

    /// The settings editor uses the shared options scroller, whose overflow
    /// hint says more settings continue below the fold.
    func testSettingsEditorScrollsWithTheOverflowHint() throws {
        let lightfield = try source("Sources/StorageCleanerMac/Views/Settings/SettingsLightfield.swift")
        let columns = try r2SourceDeclaration("struct SettingsPreviewColumns", in: lightfield)
        XCTAssertEqual(columns.components(separatedBy: "FeatureOptionsScrollView(probePrefix: \"settings.editor\"").count - 1, 2)
        XCTAssertFalse(columns.contains("ScrollView { editor"))
    }

    /// “本软件更新…” sits with the manager header's other actions, not in a
    /// row of its own above the page header.
    func testOwnUpdateButtonJoinsTheManagerHeader() throws {
        let view = try source("Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift")
        XCTAssertFalse(view.contains("ownUpdateButton"), "No row of its own for the button")
        let manager = try r2SourceDeclaration("private struct AppUpdateManagerPage", in: view)
        let toolbar = try XCTUnwrap(manager.range(of: "ManagementListPage(").flatMap { start in
            manager.range(of: "} controls: {", range: start.upperBound..<manager.endIndex)
                .map { String(manager[start.lowerBound..<$0.lowerBound]) }
        })
        XCTAssertTrue(toolbar.contains("title: L10n.text(\"本软件更新…\", \"This App’s Updates…\")"))
        XCTAssertTrue(toolbar.contains("action: onOwnUpdate"))
    }

    /// The settings layouts follow the window (narrow sidebar, stacked
    /// preview) and the configurator enables zoom, but SwiftUI's Settings
    /// window style has no .resizable and SwiftUI removes it again when the
    /// content's size limits update: the window kept whatever size it was
    /// saved at and the zoom button stayed off. D97: the minimize button is
    /// on as well (D96 had kept it off), so the window has all three buttons.
    @MainActor
    func testSettingsWindowConfiguratorKeepsTheWindowResizable() throws {
        // The mask SwiftUI gives a Settings window on macOS 27.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 450),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SettingsWindowConfigurator(title: "Settings"))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let standardControls: NSWindow.StyleMask = [.resizable, .miniaturizable]
        func waitForStandardControls() {
            let deadline = Date().addingTimeInterval(2)
            while !window.styleMask.isSuperset(of: standardControls), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        waitForStandardControls()
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable), "Settings has its minimize button (D97)")
        // No minimum-size check here: this bare hosting view sets the window's
        // minimum from its own empty content.
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, true)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isEnabled, true)

        window.styleMask.remove(standardControls) // as SwiftUI does after a size-limit update
        waitForStandardControls()
        XCTAssertTrue(window.styleMask.contains(.resizable), "The window gets .resizable back")
        XCTAssertTrue(window.styleMask.contains(.miniaturizable), "The window gets .miniaturizable back")
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, true)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isEnabled, true)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
