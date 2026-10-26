import Foundation
import XCTest
@testable import StorageCleanerMac

/// D210/D211: the ignore list page's sizes, selection and scrolling, and
/// the reminder reset that no longer borrows the Ignore List's name. The
/// page's on-screen geometry is `SettingsLightfieldGeometryTests` (window).
@MainActor
final class SettingsIgnoreListPageTests: XCTestCase {
    private typealias Metrics = SettingsIgnoreListMetrics

    func testMinimumHeightHoldsEveryCategoryAndThreeWholeEntries() {
        XCTAssertEqual(Metrics.categoriesHeight,
                       5 * Metrics.groupTitleHeight + 11 * Metrics.categoryRowHeight + 4 * Metrics.groupGap)
        XCTAssertEqual(Metrics.minimumHeight, Metrics.categoriesHeight)
        XCTAssertGreaterThanOrEqual(Metrics.minimumHeight,
                                    Metrics.headerHeight + Metrics.headerGap + CGFloat(Metrics.visibleEntries) * Metrics.entryRowHeight)
        XCTAssertEqual(SettingsCategory.ignoreList.minimumContentHeight, Metrics.minimumHeight)
        for category in SettingsCategory.allCases where category != .ignoreList {
            XCTAssertEqual(category.minimumContentHeight, 0, "\(category)")
        }
    }

    /// The group titles open where `IgnoreCategory.group` changes (D207's
    /// module groups), in both languages.
    func testGroupTitlesOpenEachModuleGroup() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            var starts: [IgnoreCategory] = []
            var previous: String?
            for category in IgnoreCategory.allCases where category.group != previous {
                starts.append(category)
                previous = category.group
            }
            XCTAssertEqual(starts, Metrics.groupStarts, "\(language)")
        }
    }

    /// The frozen page where the window has room (the test build's saved
    /// 934 × 673 and the default 1180 × 760); a whole-page scroll below.
    func testOnlyAShortWindowScrollsTheWholePage() {
        let cases: [(CGSize, Bool)] = [(.init(width: 1180, height: 760), false), (.init(width: 934, height: 673), false),
            (.init(width: 1000, height: 700), false), (.init(width: 1680, height: 1050), false),
            (.init(width: 820, height: 560), true), (.init(width: 560, height: 441), true), (.init(width: 677, height: 390), true)]
        for (window, scrolls) in cases {
            let size = CGSize(width: window.width, height: window.height - 28 - SettingsTabBar.height - 1)
            let geometry = SettingsLightfieldGeometry(size: size, category: .ignoreList)
            let frozen = SettingsLightfieldGeometry(size: size, category: .accessAndSetup)
            XCTAssertEqual(geometry.documentHeight > size.height, scrolls, "\(window)")
            XCTAssertEqual(geometry.title, frozen.title, "\(window)")
            XCTAssertGreaterThanOrEqual(geometry.content.height, Metrics.minimumHeight, "\(window)")
            if scrolls {
                XCTAssertEqual(geometry.content.minY, frozen.content.minY, "\(window)")
                XCTAssertEqual(geometry.footer.minY, geometry.content.maxY + 24, "\(window)")
                XCTAssertEqual(geometry.footer.height, 108, "\(window)")
                XCTAssertEqual(geometry.documentHeight, geometry.footer.maxY, "\(window)")
            } else {
                XCTAssertEqual(geometry.content, frozen.content, "\(window)")
                XCTAssertEqual(geometry.footer, frozen.footer, "\(window)")
            }
        }
    }

    func testSelectionFollowsClickCommandAndShift() {
        let order = ["a", "b", "c", "d", "e"]
        var selection = SettingsIgnoreListSelection()
        selection.click("b", in: order, command: false, shift: false)
        XCTAssertEqual(selection.ids, ["b"])
        selection.click("d", in: order, command: false, shift: true)
        XCTAssertEqual(selection.ids, ["b", "c", "d"])
        selection.click("a", in: order, command: true, shift: false)
        XCTAssertEqual(selection.ids, ["a", "b", "c", "d"])
        selection.click("c", in: order, command: true, shift: false)
        XCTAssertEqual(selection.ids, ["a", "b", "d"])
        XCTAssertEqual(selection.anchor, "c")
        selection.click("e", in: order, command: true, shift: true)
        XCTAssertEqual(selection.ids, ["a", "b", "c", "d", "e"])
        selection.click("b", in: order, command: false, shift: false)
        XCTAssertEqual(selection.ids, ["b"])
        // An anchor that left the list (another category) picks one row.
        var stale = SettingsIgnoreListSelection(ids: ["x"], anchor: "x")
        stale.click("c", in: order, command: false, shift: true)
        XCTAssertEqual(stale.ids, ["c"])
    }

    func testArrowsMoveOneSelection() {
        let order = ["a", "b", "c"]
        var selection = SettingsIgnoreListSelection()
        selection.step(by: 1, in: order)
        XCTAssertEqual(selection.ids, ["a"])
        selection.step(by: 1, in: order)
        selection.step(by: 1, in: order)
        selection.step(by: 1, in: order)
        XCTAssertEqual(selection.ids, ["c"])
        selection.step(by: -1, in: order)
        XCTAssertEqual(selection.ids, ["b"])
        var fresh = SettingsIgnoreListSelection()
        fresh.step(by: -1, in: order)
        XCTAssertEqual(fresh.ids, ["c"])
        var empty = SettingsIgnoreListSelection(ids: ["a"], anchor: "a")
        empty.step(by: 1, in: [])
        XCTAssertEqual(empty.ids, ["a"])
    }

    /// P2: the Scan & Safety reminders reset what the reminders were told to
    /// ignore; it names those reminders and never the Ignore List (D207).
    func testReminderResetNamesRemindersNotTheIgnoreList() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageCleanerMac/Features/AppLifecycle/Reminders/UI/AppLifecycleReminderSettingsSection.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for old in ["重置忽略列表", "Reset Ignore List", "确定要重置忽略列表吗", "Reset the Ignore List"] {
            XCTAssertFalse(source.contains(old), old)
        }
        XCTAssertEqual(source.components(separatedBy: "L10n.text(\"重置已忽略的提醒\", \"Reset Ignored Reminders\")").count - 1, 2)
        XCTAssertTrue(source.contains("忽略列表里的项目不受影响"))
        XCTAssertTrue(source.contains("center.ignoreList.reset()"))
        XCTAssertFalse(source.contains("IgnoreListStore"))
    }
}
