import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// The 2.0.1 review's wording, accessibility and localization items
/// (2026-10-27, E batch, D231–D239). The single round-button element and the
/// clean subtitle are read from the live accessibility tree in the
/// display-bound `CareStudioAccessibilityD231Tests`.
@MainActor
final class ReviewWordingD231D239Tests: XCTestCase {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// D231: the label, hint and value sit on the button, not on the framed
    /// container (which made a second element of the same name).
    func testRoundButtonLabelsTheButtonItself() throws {
        let button = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioActionButton.swift")
        let body = try r2SourceDeclaration("var body: some View", in: button)
        let label = try XCTUnwrap(body.range(of: ".accessibilityLabel(fullTitle ?? title)"))
        let frame = try XCTUnwrap(body.range(of: ".frame(width: CareStudioMetrics.actionDiameter"))
        XCTAssertLessThan(label.lowerBound, frame.lowerBound)
        for modifier in [".accessibilityHint(accessibilityHint ?? \"\")", ".accessibilityValue(progressAccessibilityValue)",
                         ".help(fullTitle ?? \"\")"] {
            XCTAssertLessThan(try XCTUnwrap(body.range(of: modifier)).lowerBound, frame.lowerBound, modifier)
        }
    }

    /// D232＋旧值“实时预览 · 与菜单栏小窗同尺寸”: the preview's data is simulated.
    func testSettingsPreviewCaptionSaysSimulated() throws {
        let preview = try source("Sources/StorageCleanerMac/Views/Settings/SettingsMiniWindowPreview.swift")
        XCTAssertTrue(preview.contains("L10n.text(\"模拟预览 · 与菜单栏小窗同尺寸\", \"Sample data · Same size as the menu-bar panel\")"))
        XCTAssertFalse(preview.contains("Text(L10n.text(\"实时预览"))
        XCTAssertTrue(preview.contains("模拟小窗预览 · 非实时数据"), "the accessibility label already said so")
    }

    /// D233＋旧值“共 N 分钟”: the time card's second line counts operations.
    func testTimeSavedCardCountsOperationsInsteadOfRepeatingMinutes() throws {
        let savings = MyActivityTimeSavings(records: [
            .init(id: "a", category: .uninstall), .init(id: "b", category: .uninstall),
            .init(id: "c", category: .update), .init(id: "c", category: .update),
        ])
        XCTAssertEqual(savings.totalOperations, 3, "the duplicate record counts once")
        XCTAssertEqual(savings.totalMinutes, 26)
        XCTAssertEqual(MyActivityTimeSavings().totalOperations, 0)
        let card = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioActivityCards.swift")
        XCTAssertTrue(card.contains("Text(L10n.text(\"\\(ByteFormat.count(savings.totalOperations)) 次操作\","))
        XCTAssertFalse(card.contains("Text(L10n.text(\"共 \\(ByteFormat.count(savings.totalMinutes)) 分钟\""))
    }

    /// D234: Chinese UI text goes through L10n; script/verify.sh runs the guard
    /// (its own cases are in script/test_check_cjk_literals.py).
    func testVerifyRunsTheChineseLiteralGuardAndTheSheetIsLocalized() throws {
        let verify = try source("script/verify.sh")
        XCTAssertTrue(verify.contains("python3 -B test_check_cjk_literals.py"))
        XCTAssertTrue(verify.contains("python3 -B \"$ROOT_DIR/script/check_cjk_literals.py\""))
        let sheet = try source("Sources/StorageCleanerMac/Views/ProjectArtifactView.swift")
        for localized in ["Text(L10n.text(\"项目产物\", \"Project Artifacts\"))", "Button(L10n.text(\"选择文件夹\", \"Choose Folders\"))",
                          "Button(L10n.text(\"确认移到废纸篓\", \"Move to Trash\"))"] {
            XCTAssertTrue(sheet.contains(localized), localized)
        }
        let language = MiniWindowLogicLanguageScope(.english)
        defer { language.restore() }
        XCTAssertEqual(L10n.text("未测量", "Not measured"), "Not measured")
    }

    /// D236: nothing to review behind an empty Update & Sync tile.
    func testEmptyUpdateAndSyncTileOffersNoReview() throws {
        let summary = StartupItemsPresentation.make(items: [], query: "", category: .all, status: .all, source: .all,
                                                    includeAppleSystem: false, sort: .recommended, includeTechnicalDetails: false)
        var coverage = StartupCoverageReport.empty
        coverage.managedItemCoverageAvailable = true
        let tiles = CareStudioStartupResultsPage.tiles(summary, coverage: coverage, helper: nil, leadingTiles: []) { _ in {} }
        let updates = try XCTUnwrap(tiles.first { $0.id == "updates" })
        XCTAssertFalse(updates.showsReview)
        XCTAssertTrue(try XCTUnwrap(tiles.first { $0.id == "background" }).showsReview, "other tiles keep Review")
        let startup = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioStartup.swift")
        XCTAssertTrue(startup.contains("showsReview: updates > 0)"))
        let tile = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkResults.swift")
        XCTAssertTrue(tile.contains("if model.showsReview {"))
    }

    /// D235: the attention category's words no longer promise unknown owners.
    func testAttentionWordingNamesOnlyRealFaults() throws {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let explanation = CareStudioStartupManager.explanation(for: .attention)
        XCTAssertFalse(explanation.hasPrefix("失效、找不到程序、签名异常或归属不明"))
        XCTAssertTrue(explanation.contains("归属未确认的项目留在原来的类别里"))
        let presentation = try source("Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemsPresentation.swift")
        let attention = try r2SourceDeclaration("var isAttentionItem: Bool", in: presentation)
        XCTAssertFalse(attention.contains("manageability == .unknown"))
    }

    /// D237: a notice that counts places without read permission offers the
    /// Full Disk Access settings; other limits keep a plain notice.
    func testPermissionNoticeOffersFullDiskAccess() {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        var denied = ScanCoverageLimits()
        denied.deniedLocationCount = 15
        XCTAssertEqual(CareStudioJunkResultsPage.coverageNoticeActionTitle(denied), "打开完整磁盘访问设置")
        var timed = ScanCoverageLimits()
        timed.reachedTimeLimit = true
        XCTAssertNil(CareStudioJunkResultsPage.coverageNoticeActionTitle(timed))
        XCTAssertNil(CareStudioJunkResultsPage.coverageNoticeActionTitle(ScanCoverageLimits()))
    }

    /// D238: the accessibility text has no word joiner; the drawn text keeps
    /// D228's joiners so lines still break between phrases.
    func testSubtitleAccessibilityTextHasNoWordJoiner() throws {
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let subtitle = CareStudioModule.clutter.subtitle
        XCTAssertTrue(subtitle.contains(CareStudioLineBreaks.wordJoiner))
        let plain = CareStudioLineBreaks.plain(subtitle)
        XCTAssertFalse(plain.contains(CareStudioLineBreaks.wordJoiner))
        XCTAssertEqual(plain, "整理重复文件、相似照片、大型和旧文件、“下载”文件夹以及聊天文件；重复文件每组至少留一份。")
        let hero = try source("Sources/StorageCleanerMac/Views/CareStudio/CareStudioHero.swift")
        XCTAssertTrue(hero.contains(".accessibilityRepresentation { Text(CareStudioLineBreaks.plain(subtitle ?? module.subtitle)) }"))
    }

    /// D239＋旧值“1 pt hairColor”: a 2 pt foreground ring around each swatch.
    func testThemeSwatchesHaveAContrastingRing() throws {
        let night = FeatureLightfieldPalette.resolve(.dark)
        XCTAssertEqual(SettingsPalettePicker<AppCanvasTheme>.swatchRing(night, scheme: .dark), night.fg.opacity(0.34))
        let day = FeatureLightfieldPalette.resolve(.light)
        XCTAssertEqual(SettingsPalettePicker<AppCanvasTheme>.swatchRing(day, scheme: .light), day.fg.opacity(0.2))
        let picker = try r2SourceDeclaration("struct SettingsPalettePicker",
            in: source("Sources/StorageCleanerMac/Views/Settings/SettingsLightfield.swift"))
        XCTAssertTrue(picker.contains(".strokeBorder(Self.swatchRing(palette, scheme: scheme), lineWidth: 2)"))
        XCTAssertFalse(picker.contains("Circle().strokeBorder(palette.hairColor, lineWidth: 1)"))
    }
}
