import XCTest
@testable import StorageCleanerMac

/// D64 removes the simple panel. Its confirmation and cancellation coverage
/// now exercises the live mini window with an explicit manual selection (D2).
@MainActor
final class MenuBarSimplePanelQuitTests: XCTestCase {
    /// Five eligible apps; the fixture manually selects the first three.
    private func makeStore() throws -> (ScanStore, listed: [MemoryAppUsage]) {
        let processes = (0..<5).map { index in
            MiniWindowLogicFixtures.memoryProcess(
                id: Int32(7_500 + index), name: "Heavy\(index)", residentBytes: Int64(1_200 - index * 100) * 1024 * 1024)
        }
        let store = try ScanStore.makeForTests(for: self)
        store.memorySnapshot = MiniWindowLogicFixtures.memorySnapshot(processes: processes)
        let suggested = try XCTUnwrap(store.memorySnapshot?.recommendedQuitApps)
        XCTAssertEqual(suggested.count, 5, "the fixture offers five suggestions")
        XCTAssertTrue(store.canRequestMemoryQuitActions)
        let listed = Array(suggested.filter { $0.canQuit && $0.bundlePath?.hasSuffix(".app") == true }.prefix(3))
        return (store, listed)
    }

    func testTheButtonAsksToQuitExactlyTheListedAppsAndTheConfirmationNamesThem() throws {
        let (store, listed) = try makeStore()

        for app in listed { store.setMemoryAppUsageSelection(app, isSelected: true) }
        GeekMemoryQuitSelection.request(store: store)

        XCTAssertEqual(store.pendingMemoryQuitSummary?.appCount, 3, "the three apps the card lists, not all five")
        XCTAssertEqual(store.pendingMemoryQuitSummary?.appNames, listed.map(\.name))
        XCTAssertEqual(Set(store.pendingMemoryProcessesToQuit.map(\.id)), Set(listed.flatMap(\.selectableProcessIDs)))
        XCTAssertTrue(store.isMemoryBatchQuitConfirmationPresentedInMenuBar, "nothing quits before the confirmation")
        XCTAssertFalse(store.isOptimizingMemory)
        store.cancelQuitSelectedMemoryProcesses()
        XCTAssertNil(store.pendingMemoryQuitSummary)
    }

    /// D64: the real mini-window request uses the manual selection, and
    /// cancellation preserves it for a subsequent confirmation.
    func testCancellingTheRequestGivesThePreviousSelectionBack() throws {
        let (store, listed) = try makeStore()
        for app in listed { store.setMemoryAppUsageSelection(app, isSelected: true) }
        let selectionBefore = store.selectedMemoryProcessIDs
        GeekMemoryQuitSelection.request(store: store)
        XCTAssertEqual(store.selectedMemoryProcessIDs, selectionBefore)
        XCTAssertEqual(store.pendingMemoryQuitSummary?.appNames, listed.map(\.name))
        XCTAssertFalse(store.isOptimizingMemory)
        store.cancelQuitSelectedMemoryProcesses()
        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertEqual(store.selectedMemoryProcessIDs, selectionBefore)
        // A second confirmation must still use exactly the manual selection.
        GeekMemoryQuitSelection.request(store: store)
        XCTAssertEqual(Set(store.pendingMemoryProcessesToQuit.map(\.id)), selectionBefore)
        store.cancelQuitSelectedMemoryProcesses()
        XCTAssertEqual(store.selectedMemoryProcessIDs, selectionBefore)
    }

    func testButtonAndConfirmationWording() {
        let chinese = MiniWindowLogicLanguageScope(.zhHans)
        XCTAssertEqual(GeekMemoryQuitSelection.prominentTitle(selectedCount: 3), "退出所选应用（3 个）")
        XCTAssertEqual(GeekMemoryQuitSelection.prominentTitle(selectedCount: 1), "退出所选应用（1 个）")
        let three = MemoryQuitSelectionSummary(appCount: 3, estimatedBytes: 1, appNames: ["A", "B", "C"])
        XCTAssertEqual(three.appNameList, "A、B、C")
        let five = MemoryQuitSelectionSummary(appCount: 5, estimatedBytes: 1, appNames: ["A", "B", "C", "D", "E"])
        XCTAssertEqual(five.appNameList, "A、B、C 等 5 个")
        chinese.restore()

        let english = MiniWindowLogicLanguageScope(.english)
        defer { english.restore() }
        XCTAssertEqual(GeekMemoryQuitSelection.prominentTitle(selectedCount: 3), "Quit Selected Apps (3)")
        XCTAssertEqual(GeekMemoryQuitSelection.prominentTitle(selectedCount: 1), "Quit Selected App (1)")
        XCTAssertEqual(three.appNameList, "A, B, C")
        XCTAssertEqual(five.appNameList, "A, B, C and 2 more")
    }

    func testTheCardUsesTheListedAppsAndTheConfirmationListsNames() throws {
        let source = try D64MenuBarSource.source("MenuBarAdvanced/GeekMemoryView.swift")
        let button = try r2SourceDeclaration("struct GeekMemoryQuitSelectedButton:", in: source)
        XCTAssertTrue(button.contains("GeekMemoryQuitSelection.request(store: store)"))
        XCTAssertTrue(button.contains(".disabled(!GeekMemoryQuitSelection.isAvailable(store: store))"))
        XCTAssertFalse(button.contains("confirmQuitSelectedMemoryProcesses"))
        let host = try r2SourceDeclaration("struct GeekMemoryQuitConfirmationHost<", in: source)
        XCTAssertTrue(host.contains("Text(summary.confirmationMessage)"))
        XCTAssertEqual(host.components(separatedBy: "store.confirmQuitSelectedMemoryProcesses()").count - 1, 1)
        let named = MemoryQuitSelectionSummary(appCount: 2, estimatedBytes: 1, appNames: ["Alpha", "Beta"])
        XCTAssertTrue(named.confirmationMessage.contains(named.appNameList))
        XCTAssertFalse(source.contains("store.performRecommendedMemoryAction(presentConfirmationInMenuBar: true)"))
    }
}
