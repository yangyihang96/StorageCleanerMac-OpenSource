import AppKit
import XCTest
@testable import StorageCleanerMac

@MainActor
final class RecentItemsPresentationTests: XCTestCase {
    func testProtectionCardHasBothLanguagesAndNoDefaultSelection() throws {
        let fixture = try RecentItemsTestFixture(self)
        try fixture.write(count: 3)
        let store = RecentItemsStore(environment: fixture.environment, snapshot: fixture.scanner.scan())
        // Integration: a plain store (was the Debug-only BrowserPrivacyPreviewFixture,
        // which broke the Release test build); only the recent-items tile is read.
        let privacy = BrowserPrivacyStore()
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let page = CareStudioProtectionResults(privacy: privacy, onReview: {}, onShowDataTypes: {}, recentItems: store)
            let tile = try XCTUnwrap(page.tiles.first { $0.id == "recentItems" })
            XCTAssertEqual(tile.title, language == .zhHans ? "最近使用项目" : "Recent Items")
            XCTAssertEqual(tile.valueCaption, language == .zhHans ? "发现 \(ByteFormat.count(3)) 个最近使用项目" : "Found \(ByteFormat.count(3)) recent items")
            XCTAssertEqual(tile.detail, RecentItemsPresentation.detail)
            XCTAssertEqual(tile.reviewTitle, language == .zhHans ? "查看" : "Review")
            XCTAssertEqual(tile.cleanTitle, language == .zhHans ? "移除" : "Remove")
            XCTAssertNotNil(tile.onClean)
            XCTAssertTrue(store.selectedIDs.isEmpty)
            store.beginReview(confirm: true)
            XCTAssertEqual(store.confirmation?.count, 0)
            XCTAssertTrue(fixture.events.values.isEmpty)
        }
    }

    func testConfirmationFreezesOnlyUserCheckedListsAndReportsRunningAppsWithoutQuittingThem() throws {
        let fixture = try RecentItemsTestFixture(self)
        try fixture.write()
        let app = try fixture.write("com.example.Editor.sfl4", count: 4, app: true)
        let store = RecentItemsStore(environment: fixture.environment, snapshot: fixture.scanner.scan(), resolveApplication: { _ in
            RecentItemsApplication(name: "Fixture Editor", icon: nil, isRunning: true)
        })
        store.setSelected(true, listID: app.path)
        store.prepareConfirmation()
        XCTAssertEqual(store.confirmation?.map(\.id), [app.path])
        XCTAssertEqual(store.confirmationFacts.items.map(\.title), ["Fixture Editor"])
        XCTAssertEqual(store.confirmationFacts.appsToQuit, ["Fixture Editor"])
        XCTAssertEqual(store.confirmationFacts.recovery, [.trashAndOperationHistory])
        XCTAssertEqual(store.confirmationFacts.actions, [.moveToTrash])
        store.setSelected(false, listID: app.path)
        XCTAssertEqual(store.selectedIDs, [app.path], "A confirmation keeps the reviewed selection frozen")
        XCTAssertTrue(fixture.events.values.isEmpty)
    }

    func testMissingAppUsesBundleIdentifierAndUnknownCountsRemainUnknown() throws {
        let fixture = try RecentItemsTestFixture(self)
        let app = try fixture.write("com.example.Removed.sfl2", app: true)
        try Data("unknown".utf8).write(to: app)
        let snapshot = fixture.scanner.scan()
        let store = RecentItemsStore(environment: fixture.environment, snapshot: snapshot, resolveApplication: { bundleID in
            RecentItemsApplication(name: bundleID, icon: nil, isRunning: false)
        })
        XCTAssertEqual(store.name(for: try XCTUnwrap(snapshot.lists.first)), "com.example.Removed")
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(RecentItemsPresentation.count(nil), language == .zhHans ? "条目数未知" : "Item count unknown")
            XCTAssertTrue(RecentItemsPresentation.summary(snapshot).contains(language == .zhHans ? "条目数未知" : "unknown"))
            XCTAssertFalse(RecentItemsPresentation.summary(snapshot).contains(language == .zhHans ? "发现 0" : "Found 0"))
        }
    }

    func testConfirmationAndWritebackMessagesAreLocalizedAndExplainRecoveryAndSidebarSafety() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let notes = RecentItemsPresentation.confirmationNotes.joined(separator: " ")
            for term in language == .zhHans ? ["废纸篓", "操作记录", "重启", "访达边栏", "收藏", "退出"] :
                ["Trash", "Operation History", "restart", "sidebar", "favorites", "Quit"] {
                XCTAssertTrue(notes.contains(term), term)
            }
            XCTAssertEqual(RecentItemsPresentation.verification(.writtenBack), language == .zhHans
                           ? "系统已写回，可能要注销后才清空"
                           : "The system wrote the list back; signing out may be needed to clear it")
            XCTAssertFalse(RecentItemsPresentation.verification(.unknown).isEmpty)
            XCTAssertFalse(RecentItemsPresentation.restart(.failed).isEmpty)
            XCTAssertEqual(OperationRecordPresentation.title(rulesVersion: RecentItemsCleanupService.ruleID, subject: nil),
                           language == .zhHans ? "最近使用项目 · 移到废纸篓" : "Recent Items · Moved to Trash")
        }
    }

    func testStoreRequiresConfirmationAndClearsSelectionAfterVerifiedCleanup() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let app = try fixture.write("com.example.Editor.sfl4", app: true)
        let store = RecentItemsStore(environment: fixture.environment, snapshot: fixture.scanner.scan(), resolveApplication: {
            RecentItemsApplication(name: $0, icon: nil, isRunning: false)
        })
        store.setSelected(true, listID: app.path)
        await store.clean(confirmed: true, coordinator: HeavyWorkCoordinator())
        XCTAssertTrue(fixture.events.values.isEmpty, "A selection without the confirmation page is insufficient")
        store.prepareConfirmation()
        await store.clean(confirmed: false, coordinator: HeavyWorkCoordinator())
        XCTAssertTrue(fixture.events.values.isEmpty)
        await store.clean(confirmed: true, coordinator: HeavyWorkCoordinator())
        XCTAssertEqual(store.result?.verification[app.path], .cleared)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertNil(store.confirmation)
        XCTAssertFalse(store.isCleaning)
    }

    func testNewReadResetsSelectionWithoutRunningAnyCleanup() async throws {
        let fixture = try RecentItemsTestFixture(self)
        let file = try fixture.write()
        let store = RecentItemsStore(environment: fixture.environment, snapshot: fixture.scanner.scan())
        store.setSelected(true, listID: file.path)
        await store.scan()
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertEqual(store.snapshot?.knownEntryCount, 2)
        XCTAssertTrue(fixture.events.values.isEmpty)
    }
}
