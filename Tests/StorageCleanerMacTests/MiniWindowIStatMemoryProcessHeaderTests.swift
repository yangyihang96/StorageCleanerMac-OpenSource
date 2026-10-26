#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D139 (R9 inventory B7): the memory page's process section in iStat's
/// words and on iStat's single title row. `-[BBRMemoryMenuProcessSection
/// drawRect:]` draws 'Processes' upper-cased and alone on the row; our
/// actions (查看全部, the selection menu and, while nothing is selected, the
/// dimmed quit button) share it. Where the quit button's full title does not
/// fit, it takes its short title, iStat's own rule for the energy mode row
/// ('Power.Energy Mode' → 'Power.Mode'); only then do the actions take the
/// next row.
@MainActor
final class MiniWindowIStatMemoryProcessHeaderTests: XCTestCase {
    private let memoryView = "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift"

    func testTitleIsIStatsProcessesAndTheScopeIsTheHelpAndVoiceOverValue() throws {
        let view = try MiniWindowLogicFixtures.source(memoryView)
        let title = try MiniWindowLogicFixtures.section(
            view, from: "private var memoryProcessTitleText: String {", to: "private var memoryProcessScopeText")
        XCTAssertTrue(title.contains("L10n.text(\"进程\", \"PROCESSES\")"), "iStat's 'Processes'")
        XCTAssertFalse(title.contains("进程组"), "the scope is no longer the title")
        // The same words as the other process sections.
        for page in ["GeekProcessorView", "GeekDiskView", "GeekNetworkView"] {
            let source = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Views/MenuBarAdvanced/\(page).swift")
            XCTAssertTrue(source.contains("title: L10n.text(\"进程\", \"PROCESSES\")"), page)
        }
        // The scope: the title's help (with the grouping rule) and its
        // VoiceOver value, on the title row and on the two-row fallback.
        let scope = try MiniWindowLogicFixtures.section(
            view, from: "private var memoryProcessScopeText: String {", to: "private var memoryProcessTitleHelp")
        XCTAssertTrue(scope.contains("\"进程组 · 前\\(geekMemoryTopProcesses.count)/\\(geekMemoryAllProcesses.count)项\""))
        XCTAssertTrue(scope.contains("\"Process groups · \\(geekMemoryTopProcesses.count)/\\(geekMemoryAllProcesses.count)\""))
        let help = try MiniWindowLogicFixtures.section(
            view, from: "private var memoryProcessTitleHelp: String {", to: "/// D119: 12 pt text actions")
        XCTAssertTrue(help.contains("memoryProcessScopeText + L10n.text(\"。按应用或可执行路径合并为进程组；已选项优先，其余按内存占用排序。\""))
        let header = try MiniWindowLogicFixtures.section(
            view, from: "private func memoryProcessHeader(", to: "private var memoryProcessTitle: some View")
        XCTAssertTrue(header.contains("GeekProcessListHeader(title: memoryProcessTitleText, help: memoryProcessTitleHelp,\n"
            + "                              accessibilityValue: memoryProcessScopeText)"))
        let fallback = try MiniWindowLogicFixtures.section(
            view, from: "private var memoryProcessTitle: some View {", to: "private var memoryProcessTitleText")
        XCTAssertTrue(fallback.contains(".help(memoryProcessTitleHelp)"))
        XCTAssertTrue(fallback.contains(".accessibilityValue(memoryProcessScopeText)"))
        // The shared header reads the value before its status (others pass
        // neither and keep an empty value).
        let components = try MiniWindowLogicFixtures.source(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPanelComponents.swift")
        XCTAssertTrue(components.contains(".accessibilityValue(titleAccessibilityValue ?? status ?? \"\")"))
        XCTAssertFalse(components.contains(".accessibilityValue(status ?? \"\")"))
    }

    func testQuitButtonTakesItsShortTitleOnlyWhereTheFullOneDoesNotFit() throws {
        // The card's content width on iStat's 270 pt memory page.
        let content = MiniWindowStyleTokens.memoryDetailWidth - 2 * MiniWindowStyleTokens.contentInset
            - 2 * MiniWindowStyleTokens.cardHorizontalInset
        XCTAssertEqual(content, 238)
        let processes = (0..<12).map { index in
            MiniWindowLogicFixtures.memoryProcess(
                id: Int32(7_600 + index), name: "Application \(index)", residentBytes: Int64(900 - index) * 1024 * 1024)
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
                let full = headerWidth(store: store, quitHint: .header)
                let short = headerWidth(store: store, quitHint: .headerShort)
                let tag = "\(language.rawValue), \(selectedCount) selected: full \(full), short \(short) of \(content) pt"
                if selectedCount > 0 {
                    // No quit button in the header: the two forms are one.
                    XCTAssertEqual(full, short, accuracy: 0.01, tag)
                    XCTAssertLessThanOrEqual(full, content, tag)
                } else if language == .english {
                    XCTAssertGreaterThan(full, content, "the full title does not fit: \(tag)")
                    XCTAssertLessThanOrEqual(short, content, "the short title fits: \(tag)")
                } else {
                    XCTAssertLessThanOrEqual(full, content, "Chinese keeps the full title: \(tag)")
                }
            }
        }

        // The first form that fits wins, then the actions' own row.
        let view = try MiniWindowLogicFixtures.source(memoryView)
        let card = try MiniWindowLogicFixtures.section(
            view, from: "private var geekMemoryProcessesCard: some View {", to: "private func memoryProcessHeader(")
        let forms = try ["ViewThatFits(in: .horizontal) {", "memoryProcessHeader(quitHint: .header)\n",
                         "memoryProcessHeader(quitHint: .headerShort)\n", "memoryProcessTitle\n",
                         "memoryProcessActions\n"].map {
            try XCTUnwrap(card.range(of: $0), "the card no longer has \($0)").lowerBound
        }
        XCTAssertEqual(forms, forms.sorted())
        // The measured header is the production header.
        let actions = try MiniWindowLogicFixtures.section(
            view, from: "private func memoryProcessActions(quitHint:", to: "private var geekMemoryPagesCard")
        let order = try ["HStack(spacing: 6) {", "Button(L10n.text(\"查看全部\", \"View all\"))",
                         ".buttonStyle(ResponsivePlainButtonStyle())",
                         ".font(.system(size: GeekIStatCardGeometry.textFontSize))",
                         "GeekMemoryProcessSelectionMenu(store: store, tint: memoryTint)",
                         "if store.selectedMemoryAppCount == 0 {",
                         "GeekMemoryQuitSelectedButton(store: store, tint: memoryTint, presentation: quitHint)",
                         ".frame(height: GeekIStatSectionGeometry.rowHeight)",
                         ".fixedSize(horizontal: true, vertical: false)"].map {
            try XCTUnwrap(actions.range(of: $0), "the actions no longer have \($0)").lowerBound
        }
        XCTAssertEqual(order, order.sorted())
        XCTAssertTrue(view.contains("private var memoryProcessActions: some View {\n        memoryProcessActions(quitHint: .header)\n    }"),
                      "the two-row fallback keeps the full title")
    }

    func testShortTitleKeepsTheFullNameForVoiceOver() throws {
        let font = NSFont.systemFont(ofSize: GeekIStatCardGeometry.textFontSize)
        for (language, title, short) in [(AppLanguage.zhHans, "退出所选应用", "退出"), (.english, "Quit Selected Apps", "Quit")] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(GeekMemoryQuitSelection.title, title)
            XCTAssertEqual(GeekMemoryQuitSelection.shortTitle, short)
            let width = { (text: String) in (text as NSString).size(withAttributes: [.font: font]).width }
            XCTAssertLessThan(width(short), width(title), "\(language)")
        }
        let view = try MiniWindowLogicFixtures.source(memoryView)
        let header = try MiniWindowLogicFixtures.section(view, from: "case .header, .headerShort:", to: "case .prominent:")
        XCTAssertTrue(header.contains(
            "Button(presentation == .header ? GeekMemoryQuitSelection.title : GeekMemoryQuitSelection.shortTitle) {"))
        // Either form: the full name for VoiceOver, the same request, dimmed
        // until apps are selected (D2).
        XCTAssertTrue(header.contains(".accessibilityLabel(GeekMemoryQuitSelection.title)"))
        XCTAssertTrue(header.contains("GeekMemoryQuitSelection.request(store: store)"))
        XCTAssertTrue(header.contains(".disabled(!GeekMemoryQuitSelection.isAvailable(store: store))"))
    }

    /// The production header's natural width: iStat's title, the 6 pt
    /// spacing and the spacer's 4 pt minimum on each side, the actions.
    private func headerWidth(store: ScanStore, quitHint: GeekMemoryQuitSelectedButton.Presentation) -> CGFloat {
        let header = GeekProcessListHeader(title: L10n.text("进程", "PROCESSES")) {
            HStack(spacing: 6) {
                Button(L10n.text("查看全部", "View all")) {}
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .font(.system(size: GeekIStatCardGeometry.textFontSize))
                GeekMemoryProcessSelectionMenu(store: store, tint: .blue)
                if store.selectedMemoryAppCount == 0 {
                    GeekMemoryQuitSelectedButton(store: store, tint: .blue, presentation: quitHint)
                }
            }
            .frame(height: GeekIStatSectionGeometry.rowHeight)
            .fixedSize(horizontal: true, vertical: false)
        }
        return NSHostingView(rootView: header.fixedSize()).fittingSize.width
    }
}
#endif
