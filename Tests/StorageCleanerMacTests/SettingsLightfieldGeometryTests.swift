#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SettingsLightfieldGeometryTests: XCTestCase {
    func testAllSevenPaneHostsMatchTheirGeometryAcrossSizesAndThemes() async throws {
        let windows: [CGSize] = [.init(width: 1180, height: 760), .init(width: 820, height: 560),
            .init(width: 1000, height: 700), .init(width: 1280, height: 763), .init(width: 1680, height: 1050),
            .init(width: 2400, height: 1350), .init(width: 677, height: 390), .init(width: 1280, height: 390)]
        for dark in [false, true] {
            for window in windows {
                // D154 batch 3I: the pane spans the window under the tabs and
                // their hairline (was `window.width - (window.width < 820 ? 180 : 210)`
                // wide and `window.height - 28` high, beside the sidebar).
                let size = CGSize(width: window.width, height: window.height - 28 - SettingsTabBar.height - 1)
                for category in SettingsCategory.allCases {
                    let root = SettingsLightfieldPane(category: category) {
                        ScrollView { LightfieldSettingsRow { Text(String(repeating: "长设置名称与路径 ", count: 30)).lineLimit(1).truncationMode(.middle) } }
                    }
                    let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: dark)
                    defer { host.close() }
                    var ids: Set<String> = ["fixture.viewport", "settings.title", "settings.content"]
                    if category != .general && category != .miniWindow { ids.insert("settings.footer") }
                    let frames = try await host.frames(required: ids, size: size)
                    let viewport = try XCTUnwrap(frames["fixture.viewport"])
                    let geometry = SettingsLightfieldGeometry(size: size, category: category)
                    // D210＋旧值：the containment checks below were against
                    // `viewport` for every page. The ignore list keeps its
                    // minimum content height in a shorter window and the whole
                    // page scrolls, so its content and footer are checked
                    // against the page's document (still at the top here); for
                    // every other page the document is the viewport.
                    let document = CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: geometry.documentHeight)
                    XCTAssertTrue(category == .ignoreList || document == viewport, "\(window)/\(category) must not scroll")
                    for (id, expected) in [("settings.title", geometry.title), ("settings.content", geometry.content)] {
                        let actual = try XCTUnwrap(frames[id])
                        XCTAssertEqual(actual.minX - viewport.minX, expected.minX, accuracy: 0.5, "\(window)/\(category)/\(id)")
                        XCTAssertEqual(actual.minY - viewport.minY, expected.minY, accuracy: 0.5)
                        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
                        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
                        XCTAssertTrue(document.insetBy(dx: -0.5, dy: -0.5).contains(actual))
                    }
                    if let footer = frames["settings.footer"] {
                        XCTAssertEqual(footer.minY - viewport.minY, geometry.footer.minY, accuracy: 0.5)
                        XCTAssertTrue(document.insetBy(dx: -0.5, dy: -0.5).contains(footer))
                    }
                }
            }
        }
    }

    /// D154 batch 3I: the seven tabs fit the bar at every supported window
    /// width, left to right without overlapping, in both languages.
    func testSettingsTabsFitTheBarAtEveryWindowWidth() async throws {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            for width: CGFloat in [560, 677, 820, 1180, 1680] {
                let size = CGSize(width: width, height: SettingsTabBar.height)
                let host = CalibrationAppKitLayoutHost(root: SettingsTabBar(selected: .scanAndSafety) { _ in }, size: size, dark: false)
                defer { host.close() }
                let ids = Set(SettingsCategory.allCases.map { "settings.tab." + $0.rawValue } + ["settings.tabs", "fixture.viewport"])
                let frames = try await host.frames(required: ids, size: size)
                let bar = try XCTUnwrap(frames["settings.tabs"])
                XCTAssertEqual(bar.height, SettingsTabBar.height, accuracy: 0.5, "\(language)/\(width)")
                var previous: CGRect?
                for category in SettingsCategory.allCases {
                    let tab = try XCTUnwrap(frames["settings.tab." + category.rawValue])
                    XCTAssertTrue(bar.insetBy(dx: -0.5, dy: -0.5).contains(tab), "\(language)/\(width)/\(category) leaves the bar")
                    if let previous {
                        XCTAssertLessThanOrEqual(previous.maxX, tab.minX + 0.5, "\(language)/\(width)/\(category) overlaps the tab before it")
                    }
                    previous = tab
                }
            }
        }
    }

    /// D210: the ignore list page shows every category at once, whole
    /// entry rows and its + and −. Where the window is shorter than the page
    /// the whole page scrolls: + and − sit at its top, and with the list
    /// scrolled into view every category and three whole rows show together.
    func testIgnoreListShowsEveryCategoryWholeEntryRowsAndItsButtons() async throws {
        typealias Metrics = SettingsIgnoreListMetrics
        let home = try TestFileSystem.makeHome(for: self)
        let store = IgnoreListStore(fileURL: home.appendingPathComponent("IgnoreList.json"),
                                    defaults: TestPreferenceDomain.make(for: self))
        let model = SettingsIgnoreListModel(store: store)
        model.category = .systemJunk
        let folder = home.appendingPathComponent("Library/Caches/" + String(repeating: "很长的缓存目录名称/", count: 6))
        model.add((0..<8).map { IgnoreListTarget(path: folder.appendingPathComponent("com.example.cache-\($0)").path) })
        XCTAssertEqual(model.visibleEntries.count, 8)
        let categoryIDs = IgnoreCategory.allCases.map { "settings.ignoreList.category." + $0.rawValue }
        let rowIDs = (0..<8).map { "settings.ignoreList.entry.\($0)" }
        let buttonIDs = ["settings.ignoreList.add", "settings.ignoreList.remove"]
        let ids = Set(categoryIDs + rowIDs + buttonIDs + ["fixture.viewport", "settings.content", "settings.ignoreList.entries"])
        // 934 × 673 is the window the test build saved; 560 × 441 leaves the
        // frozen geometry about 100 pt of page, as reported on build 15.
        let windows: [CGSize] = [.init(width: 1180, height: 760), .init(width: 934, height: 673),
            .init(width: 1000, height: 700), .init(width: 1680, height: 1050), .init(width: 820, height: 560),
            .init(width: 560, height: 441), .init(width: 677, height: 390)]
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            for window in windows {
                let label = "\(language)/\(window)"
                let size = CGSize(width: window.width, height: window.height - 28 - SettingsTabBar.height - 1)
                let geometry = SettingsLightfieldGeometry(size: size, category: .ignoreList)
                let root = SettingsLightfieldPane(category: .ignoreList) {
                    SettingsIgnoreListPage(model: model, selection: .constant([]), add: {})
                }
                let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: false)
                defer { host.close() }
                let top = try await host.frames(required: ids, size: size)
                let viewport = try XCTUnwrap(top["fixture.viewport"])
                let screen = viewport.insetBy(dx: -0.5, dy: -0.5)
                let content = try XCTUnwrap(top["settings.content"])
                XCTAssertGreaterThanOrEqual(content.height, Metrics.minimumHeight - 0.5, "\(label): the page is squeezed")
                for id in buttonIDs {
                    XCTAssertTrue(screen.contains(try XCTUnwrap(top[id])), "\(label): \(id) is off screen")
                }
                // The categories never scroll on their own: each is whole, in
                // order, inside the page.
                var previous: CGRect?
                for id in categoryIDs {
                    let row = try XCTUnwrap(top[id])
                    XCTAssertEqual(row.height, Metrics.categoryRowHeight, accuracy: 0.5, "\(label): \(id)")
                    XCTAssertTrue(content.insetBy(dx: -0.5, dy: -0.5).contains(row), "\(label): \(id) leaves the page")
                    if let previous { XCTAssertLessThanOrEqual(previous.maxY, row.minY + 0.5, "\(label): \(id) overlaps") }
                    previous = row
                }
                var frames = top
                if geometry.documentHeight > size.height {
                    // The whole page scrolls; bring the list into view.
                    try host.scrollOptionsToReveal(content, matching: viewport)
                    frames = try await host.frames(required: ids, size: size)
                }
                let list = try XCTUnwrap(frames["settings.ignoreList.entries"])
                let shown = list.intersection(viewport).insetBy(dx: -0.5, dy: -0.5)
                let wholeRows = try rowIDs.filter { shown.contains(try XCTUnwrap(frames[$0])) }
                XCTAssertGreaterThanOrEqual(wholeRows.count, Metrics.visibleEntries, "\(label): whole rows \(wholeRows)")
                for id in rowIDs {
                    XCTAssertEqual(try XCTUnwrap(frames[id]).height, Metrics.entryRowHeight, accuracy: 0.5, "\(label): \(id)")
                }
                if size.height >= Metrics.minimumHeight {
                    for id in categoryIDs + buttonIDs {
                        XCTAssertTrue(screen.contains(try XCTUnwrap(frames[id])), "\(label): \(id) is not in view with the list")
                    }
                } else {
                    // Shorter than the page itself: the last category is
                    // reachable at the bottom.
                    let bottom = try await host.bottomFrames(required: ids, size: size, viewport: viewport)
                    let last = try XCTUnwrap(categoryIDs.last)
                    XCTAssertTrue(screen.contains(try XCTUnwrap(bottom[last])), "\(label): last category unreachable")
                }
            }
        }
    }

    func testPermissionActionsRemainAccessibleAtSmallAndReferenceWidths() async throws {
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        for width: CGFloat in [449, 778] {
            let state = SettingsAccessTestCallbacks()
            let row = SettingsPermissionRow(title: "完整磁盘访问", detail: "读取受保护目录，完整扫描",
                status: "未验证 · 待授权", statusKind: .warning,
                open: { state.openCount += 1 }, refresh: { state.refreshCount += 1 })
            let host = CalibrationAppKitLayoutHost(root: row, size: .init(width: width, height: 240), dark: false)
            defer { host.close() }
            let labels = ["完整磁盘访问 · 前往授权", "完整磁盘访问 · 重新检查"]
            try await host.waitForAccessibility(labels: labels, pressLabels: Set(labels))
            XCTAssertTrue(try host.press(label: labels[0]))
            XCTAssertTrue(try host.press(label: labels[1]))
            XCTAssertEqual(state.openCount, 1)
            XCTAssertEqual(state.refreshCount, 1)
        }
    }

    func testMiniSettingsButtonsRemainVisibleSeparateAndPressableInShortNarrowWindows() async throws {
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        for size: CGSize in [.init(width: 280, height: 500), .init(width: 449, height: 362), .init(width: 900, height: 500)] {
            let state = SettingsMiniWindowDraftFixture()
            state.draft.value.setModule(.disk, isVisible: false)
            let root = MiniWindowConfigurationSettingsView(draft: Binding(
                get: { state.draft }, set: { state.draft = $0 }))
                .defaultAppStorage(TestPreferenceDomain.make(for: self))
            let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: false)
            defer { host.close() }
            let ids = ["miniSettings.actions.defaults", "miniSettings.actions.cancel", "miniSettings.actions.apply"]
            let frames = try await host.frames(required: Set(ids).union(["fixture.viewport"]), size: size)
            let viewport = try XCTUnwrap(frames["fixture.viewport"])
            let buttons = try ids.map { try XCTUnwrap(frames[$0]) }
            for button in buttons {
                XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(button), "\(size): \(button)")
            }
            for index in buttons.indices {
                for other in buttons.indices where other > index {
                    XCTAssertFalse(buttons[index].intersects(buttons[other]), "Actions must not overlap")
                }
            }
            let labels = ["恢复默认", "取消", "应用"]
            try await host.waitForAccessibility(labels: labels, pressLabels: Set(labels))
            XCTAssertTrue(try host.press(label: "取消"))
            XCTAssertEqual(state.draft.value, .defaultValue)
            state.draft.value.setModule(.network, isVisible: false)
            _ = try await host.frames(required: Set(ids), size: size)
            XCTAssertTrue(try host.press(label: "恢复默认"))
            XCTAssertEqual(state.draft.value, .defaultValue)
            // Apply exposes the real AX action; invoking it would write the shared store.
        }
    }

    func testExclusionLongPathFitsAndRemovalInvokesOnlyItsExplicitCallback() async throws {
        let language = CalibrationLanguageScope(.zhHans)
        defer { language.restore() }
        let state = SettingsAccessTestCallbacks()
        let path = "/Users/example/Documents/" + String(repeating: "very-long-directory/", count: 20) + "保留资料"
        let label = "移除 · " + ScanExclusionService.displayName(for: path)
        let root = ExclusionPathRow(path: path, remove: { state.openCount += 1 })
            .layoutProbe("settings.exclusion.row")
            .frame(width: 449, height: 120, alignment: .topLeading)
        let size = CGSize(width: 449, height: 120)
        let host = CalibrationAppKitLayoutHost(root: root, size: size, dark: false)
        defer { host.close() }
        let frames = try await host.frames(required: ["settings.exclusion.row", "fixture.viewport"], size: size)
        let row = try XCTUnwrap(frames["settings.exclusion.row"])
        XCTAssertLessThanOrEqual(row.width, size.width + 0.5)
        try await host.waitForAccessibility(labels: [label], pressLabels: [label])
        XCTAssertEqual(state.openCount, 0)
        XCTAssertTrue(try host.press(label: label))
        XCTAssertEqual(state.openCount, 1)
    }

    func testDidBecomeActiveInvokesSameObserverWithoutAuthorizationEffects() async throws {
        let state = SettingsAccessTestCallbacks()
        let root = Text("权限").modifier(SettingsActivationRefresh(isVisible: true, category: .accessAndSetup) {
            state.refreshCount += 1
        }).frame(width: 320, height: 120, alignment: .topLeading)
        let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 320, height: 120), dark: true)
        defer { host.close() }
        _ = try await host.frames(required: ["fixture.viewport"], size: .init(width: 320, height: 120))
        let before = state.refreshCount
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let deadline = Date().addingTimeInterval(3)
        while state.refreshCount == before, Date() < deadline { await Task.yield() }
        XCTAssertEqual(state.refreshCount, before + 1)
        XCTAssertEqual(state.openCount, 0)
    }
}

@MainActor private final class SettingsAccessTestCallbacks {
    var openCount = 0
    var refreshCount = 0
}

@MainActor private final class SettingsMiniWindowDraftFixture: ObservableObject {
    @Published var draft = GeekDashboardDraft(.defaultValue)
}
#endif
