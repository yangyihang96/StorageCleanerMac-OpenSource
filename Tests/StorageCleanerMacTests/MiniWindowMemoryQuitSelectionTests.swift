import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Decision D2 (2026-10-04): the mini-window memory page's "内存清理" is named
/// "退出所选应用" and never brings in the suggested apps on its own. Without a
/// manual selection the action is unavailable; "选择建议项" stays in the
/// selection menu as an explicit user action.
@MainActor
final class MiniWindowMemoryQuitSelectionTests: XCTestCase {
    private let manual = MiniWindowLogicFixtures.memoryProcess(
        id: 7_401, name: "Manual", residentBytes: 200 * 1024 * 1024)
    private let suggested = MiniWindowLogicFixtures.memoryProcess(
        id: 7_402, name: "Suggested", residentBytes: 900 * 1024 * 1024)

    private func makeStore() throws -> ScanStore {
        let store = try ScanStore.makeForTests(for: self)
        store.memorySnapshot = MiniWindowLogicFixtures.memorySnapshot(processes: [suggested, manual])
        // The fixture must offer a suggestion, or the tests below prove nothing.
        XCTAssertEqual(store.memorySnapshot?.recommendedQuitApps.map(\.name), ["Suggested"])
        XCTAssertTrue(store.canRequestMemoryQuitActions)
        return store
    }

    func testWithoutAManualSelectionTheActionIsUnavailableAndBringsInNoSuggestion() throws {
        let store = try makeStore()
        XCTAssertEqual(store.selectedMemoryAppCount, 0)

        XCTAssertFalse(GeekMemoryQuitSelection.isAvailable(store: store),
                       "D2: suggested apps alone must not enable the action")
        GeekMemoryQuitSelection.request(store: store)

        XCTAssertTrue(store.selectedMemoryProcessIDs.isEmpty, "D2: no suggestion is selected on the user's behalf")
        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertTrue(store.pendingMemoryProcessesToQuit.isEmpty)
        XCTAssertFalse(store.isMemoryBatchQuitConfirmationPresentedInMenuBar)
    }

    func testAManualSelectionIsConfirmedExactlyAsSelected() throws {
        let store = try makeStore()
        let manualApp = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first { $0.name == "Manual" })
        store.setMemoryAppUsageSelection(manualApp, isSelected: true)

        XCTAssertTrue(GeekMemoryQuitSelection.isAvailable(store: store))
        GeekMemoryQuitSelection.request(store: store)

        XCTAssertEqual(store.pendingMemoryProcessesToQuit.map(\.id), [manual.id])
        XCTAssertEqual(store.pendingMemoryQuitSummary,
                       MemoryQuitSelectionSummary(appCount: 1, estimatedBytes: 200 * 1024 * 1024,
                                                  appNames: ["Manual"]))
        XCTAssertTrue(store.isMemoryBatchQuitConfirmationPresentedInMenuBar)
        XCTAssertEqual(store.selectedMemoryProcessIDs, [manual.id], "the suggestion is not added to the selection")
        store.cancelQuitSelectedMemoryProcesses()
    }

    func testSuggestionsAreSelectedOnlyByTheExplicitMenuAction() throws {
        let store = try makeStore()
        // The selection menu's "选择建议项" item.
        XCTAssertTrue(store.selectRecommendedMemoryApps())
        XCTAssertEqual(store.selectedMemoryProcessIDs, [suggested.id])

        XCTAssertTrue(GeekMemoryQuitSelection.isAvailable(store: store))
        GeekMemoryQuitSelection.request(store: store)
        XCTAssertEqual(store.pendingMemoryProcessesToQuit.map(\.id), [suggested.id])
        store.cancelQuitSelectedMemoryProcesses()

        let view = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        let menu = try MiniWindowLogicFixtures.section(
            view, from: "struct GeekMemoryProcessSelectionMenu: View {", to: "enum GeekMemoryQuitSelection {")
        XCTAssertTrue(menu.contains("Button(L10n.text(\"选择建议项\", \"Select Suggested\")) {\n                    _ = store.selectRecommendedMemoryApps()"))
    }

    func testBusyOrDemoStoresCannotRequestAQuit() throws {
        let store = try makeStore()
        let manualApp = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first { $0.name == "Manual" })
        store.setMemoryAppUsageSelection(manualApp, isSelected: true)
        store.isLoadingMemory = true
        XCTAssertFalse(GeekMemoryQuitSelection.isAvailable(store: store))
        GeekMemoryQuitSelection.request(store: store)
        XCTAssertNil(store.pendingMemoryQuitSummary)
    }

    func testTitleHelpAndAccessibilityNameTheQuitAction() throws {
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(GeekMemoryQuitSelection.title, "退出所选应用")
        XCTAssertEqual(GeekMemoryQuitSelection.help(selectedCount: 2, hasSelectableApps: true),
                       "确认后正常退出已选择的 2 个应用")
        XCTAssertEqual(GeekMemoryQuitSelection.help(selectedCount: 0, hasSelectableApps: true),
                       "先在列表或“选择”菜单中选择要退出的应用")
        XCTAssertEqual(GeekMemoryQuitSelection.help(selectedCount: 0, hasSelectableApps: false),
                       "当前没有可选择的应用")
        XCTAssertTrue(GeekMemoryQuitSelection.accessibilityHint.contains("未选择应用时不可用"))
        chinese.restore()
        let english = MiniWindowLogicLanguageScope(.english)
        XCTAssertEqual(GeekMemoryQuitSelection.title, "Quit Selected Apps")
        XCTAssertEqual(GeekMemoryQuitSelection.help(selectedCount: 0, hasSelectableApps: true),
                       "Select the applications to quit in the list or the Select menu first")
        english.restore()

        let view = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        for removed in ["内存清理", "Clean Memory", "未选择时使用建议项", "suggested apps when none are selected",
                        "ensureMemorySelectionForQuit", "已选择清理", "for cleanup"] {
            XCTAssertFalse(view.contains(removed), "D2 removes \(removed)")
        }
        let button = try MiniWindowLogicFixtures.section(
            view, from: "struct GeekMemoryQuitSelectedButton: View {", to: "private struct GeekMemoryQuitResultCard: View {")
        // D139: the header form shows the short title where the full one
        // does not fit (was `Button(GeekMemoryQuitSelection.title) {`).
        XCTAssertTrue(button.contains("Button(presentation == .header ? GeekMemoryQuitSelection.title : GeekMemoryQuitSelection.shortTitle) {\n                GeekMemoryQuitSelection.request(store: store)"))
        // U1 066/068 (BOARD N19): the full-width form requests the same way.
        XCTAssertEqual(button.components(separatedBy: "GeekMemoryQuitSelection.request(store: store)").count - 1, 2)
        XCTAssertTrue(button.contains(".accessibilityLabel(GeekMemoryQuitSelection.title)"))
        XCTAssertTrue(button.contains(".accessibilityHint(GeekMemoryQuitSelection.accessibilityHint)"))
        XCTAssertTrue(button.contains(".disabled(!GeekMemoryQuitSelection.isAvailable(store: store))"))
        // Rows describe the selection as a quit selection, not a cleanup.
        XCTAssertTrue(view.contains("L10n.text(\"已选择退出\", \"Selected to quit\")"))
        XCTAssertTrue(view.contains("L10n.text(\"未选择退出\", \"Not selected to quit\")"))
    }
}

/// The renamed button is wider than "内存清理". The header's actions (查看全部,
/// the selection menu, 退出所选应用) are laid out at their natural width, on
/// the title's row or on their own row (`ViewThatFits`), so they must fit the
/// card's content width in both languages, also with apps selected. D119:
/// the row is iStat's 15 pt on the 270 pt memory page.
@MainActor
final class MiniWindowMemoryQuitHeaderLayoutTests: XCTestCase {
    func testHeaderActionsFitTheCardInBothLanguagesWithAndWithoutASelection() throws {
        // D119: the memory page is iStat's 270 pt (was the shared 312 pt
        // `MiniWindowStyleTokens.detailWidth`).
        let cardWidth = MiniWindowStyleTokens.memoryDetailWidth - 2 * MiniWindowStyleTokens.contentInset
            - 2 * MiniWindowStyleTokens.cardHorizontalInset
        let processes = (0..<12).map { index in
            MiniWindowLogicFixtures.memoryProcess(
                id: Int32(7_500 + index), name: "Application \(index)", residentBytes: Int64(900 - index) * 1024 * 1024)
        }
        for language in [AppLanguage.zhHans, .english] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for selectedCount in [0, 2, 12] {
                let store = try ScanStore.makeForTests(for: self)
                store.memorySnapshot = MiniWindowLogicFixtures.memorySnapshot(processes: processes)
                for app in (store.memorySnapshot?.appsByResidentUsage ?? []).prefix(selectedCount) {
                    store.setMemoryAppUsageSelection(app, isSelected: true)
                }
                XCTAssertEqual(store.selectedMemoryAppCount, selectedCount)
                // The composition of `memoryProcessActions` (asserted below):
                // the header keeps the small button until apps are selected.
                // D119: 12 pt text on iStat's 15 pt row (was the 11 pt caption).
                let controls = HStack(spacing: 6) {
                    Button(L10n.text("查看全部", "View all")) {}
                        .buttonStyle(ResponsivePlainButtonStyle())
                        .font(.system(size: GeekIStatCardGeometry.textFontSize))
                    GeekMemoryProcessSelectionMenu(store: store, tint: .blue)
                    if store.selectedMemoryAppCount == 0 {
                        GeekMemoryQuitSelectedButton(store: store, tint: .blue)
                    }
                }
                let actions = controls
                    .frame(height: GeekIStatSectionGeometry.rowHeight)
                    .fixedSize(horizontal: true, vertical: false)
                let natural = NSHostingView(rootView: actions).fittingSize.width
                XCTAssertLessThanOrEqual(natural, cardWidth,
                    "\(language.rawValue), \(selectedCount) selected: the actions need \(natural) pt of \(cardWidth) pt")
                // D119: the controls stand on the 15 pt row without spilling
                // onto the process rows 2 pt below.
                let height = NSHostingView(rootView: controls.fixedSize()).fittingSize.height
                XCTAssertLessThanOrEqual(height, GeekIStatSectionGeometry.rowHeight + 0.5,
                    "\(language.rawValue), \(selectedCount) selected: the actions are \(height) pt tall")
                let button = NSHostingView(rootView: GeekMemoryQuitSelectedButton(store: store, tint: .blue)).fittingSize.width
                let label = ceil((GeekMemoryQuitSelection.title as NSString)
                    .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)
                XCTAssertGreaterThan(button, label, "\(language.rawValue): the button shows its complete title")
                // U1 066/068: the full-width form fits the card with its
                // complete title, also for twelve apps.
                guard selectedCount > 0 else { continue }
                let prominent = NSHostingView(rootView: GeekMemoryQuitSelectedButton(
                    store: store, tint: .blue, presentation: .prominent).frame(width: cardWidth))
                XCTAssertLessThanOrEqual(prominent.fittingSize.width, cardWidth + 0.5)
                let title = GeekMemoryQuitSelection.prominentTitle(selectedCount: selectedCount)
                let titleWidth = ceil((title as NSString)
                    .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width)
                XCTAssertLessThan(titleWidth + 16 + 24, cardWidth,
                                  "\(language.rawValue): \(title) needs \(titleWidth) pt beside its icon")
            }
        }

        let view = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift")
        let production = try MiniWindowLogicFixtures.section(
            view, from: "private var memoryProcessActions: some View {", to: "private var geekMemoryPagesCard")
        // D139: the quit button comes in the form the header picks (was
        // `GeekMemoryQuitSelectedButton(store: store, tint: memoryTint)`).
        let order = try ["HStack(spacing: 6) {", "Button(L10n.text(\"查看全部\", \"View all\"))",
                         "GeekMemoryProcessSelectionMenu(store: store, tint: memoryTint)",
                         "if store.selectedMemoryAppCount == 0 {",
                         "GeekMemoryQuitSelectedButton(store: store, tint: memoryTint, presentation: quitHint)",
                         ".fixedSize(horizontal: true, vertical: false)"].map {
            try XCTUnwrap(production.range(of: $0), "memoryProcessActions no longer contains \($0)").lowerBound
        }
        XCTAssertEqual(order, order.sorted(), "the measured composition is the production composition")
        // D139: the header is built per quit-button form (was the end marker
        // "private var memoryProcessHeader").
        let card = try MiniWindowLogicFixtures.section(
            view, from: "private var geekMemoryProcessesCard: some View {", to: "private func memoryProcessHeader(")
        // D126: the full-width button is iStat's button item, its own 31 pt
        // item after the process card (was inside the card, below the list:
        // XCTAssertTrue(card.contains("if store.selectedMemoryAppCount > 0 {\n
        // GeekMemoryQuitSelectedButton(…, presentation: .prominent)"))).
        XCTAssertFalse(card.contains("presentation: .prominent"), "the process card holds no quit button")
        let page = try MiniWindowLogicFixtures.section(
            view, from: "var geekMemoryPage: some View {", to: "private var geekMemoryHistoryHoverTarget")
        XCTAssertTrue(page.contains("geekMemoryProcessesCard\n"
            + "                        // D126: with apps selected, iStat's destructive button\n"
            + "                        // item follows the list as its own 31 pt item (was a\n"
            + "                        // full-width bordered button inside the process card).\n"
            + "                        if store.selectedMemoryAppCount > 0 {\n"
            + "                            GeekMemoryQuitSelectedButton(store: store, tint: memoryTint, presentation: .prominent)"),
                      "with apps selected the full-width button follows the list")
    }
}
