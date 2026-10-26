import FileOperationShared
import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SystemCachePresentationTests: XCTestCase {
    private var measured: SystemCacheInventoryReply {
        .init(items: [.init(cache: .coreSymbolication, allocatedBytes: 41_500_000_000, entryCount: 10, device: 1, inode: 2),
                      .init(cache: .iconServices, allocatedBytes: 473_000_000, entryCount: 5, device: 1, inode: 3)])
    }
    private func makeStore(_ service: RecordingSystemCacheService) throws -> ScanStore {
        // These tests never perform file operations. Keep a unique, owned URL
        // for the factory's operation scope without creating an unused home.
        // All other writes remain refused by TestOperationFactory.
        let inertHome = TestFileSystem.uniqueOperationRoot("d182-inert")
        TestFileSystem.registerOwnership(of: inertHome, for: self)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inertHome.path))
        addTeardownBlock {
            XCTAssertFalse(FileManager.default.fileExists(atPath: inertHome.path), "Fake cache review must not create an operation home")
        }
        return try ScanStore.makeForTests(for: self, systemCacheService: service, cleanupUserHomeURL: inertHome)
    }
    func testUnavailableInventoryIsSilentAndCannotCreateAClearPlan() async throws {
        let fake = RecordingSystemCacheService(inventory: nil)
        let store = try makeStore(fake)
        await store.refreshSystemCacheInventory()
        XCTAssertNil(store.systemCacheInventory); XCTAssertNil(store.errorMessage); XCTAssertNil(store.actionMessage)
        XCTAssertNil(store.systemCacheResultMessage)
        store.requestSystemCacheClear([.coreSymbolication])
        XCTAssertNil(store.pendingSystemCacheClear)
        XCTAssertEqual(fake.events, ["inventory"])
    }
    func testReviewCancelAndWrongConfirmationNeverCallClear() async throws {
        let fake = RecordingSystemCacheService(inventory: measured)
        let store = try makeStore(fake)
        await store.refreshSystemCacheInventory()
        store.requestSystemCacheClear([])
        XCTAssertNil(store.pendingSystemCacheClear)
        store.requestSystemCacheClear([.coreSymbolication])
        XCTAssertNotNil(store.pendingSystemCacheClear)
        XCTAssertEqual(fake.events, ["inventory"])
        await store.confirmSystemCacheClear(planID: UUID())
        XCTAssertEqual(fake.events, ["inventory"])
        let cancelled = try XCTUnwrap(store.pendingSystemCacheClear)
        store.cancelSystemCacheClear()
        await store.confirmSystemCacheClear(planID: cancelled.id)
        XCTAssertEqual(fake.events, ["inventory"])
    }
    func testConfirmedPlanIsUsedOnceAndInventoryRefreshFollowsClear() async throws {
        let fake = RecordingSystemCacheService(inventory: measured)
        let store = try makeStore(fake)
        await store.refreshSystemCacheInventory()
        store.requestSystemCacheClear([.coreSymbolication])
        let plan = try XCTUnwrap(store.pendingSystemCacheClear)
        await store.confirmSystemCacheClear(planID: plan.id)
        XCTAssertEqual(fake.events, ["inventory", "clear", "inventory"])
        XCTAssertEqual(fake.cleared, [try XCTUnwrap(measured.items[0].identity)])
        XCTAssertNotNil(store.systemCacheResultMessage)
        XCTAssertFalse(store.isClearingSystemCaches); XCTAssertNil(store.pendingSystemCacheClear)
        await store.confirmSystemCacheClear(planID: plan.id)
        XCTAssertEqual(fake.events, ["inventory", "clear", "inventory"])
    }
    func testFailureRefreshesInventoryAndShowsAResult() async throws {
        let fake = RecordingSystemCacheService(inventory: measured); fake.shouldFail = true
        let store = try makeStore(fake)
        await store.refreshSystemCacheInventory(); store.requestSystemCacheClear([.iconServices])
        let plan = try XCTUnwrap(store.pendingSystemCacheClear)
        await store.confirmSystemCacheClear(planID: plan.id)
        XCTAssertEqual(fake.events, ["inventory", "clear", "inventory"])
        XCTAssertNotNil(store.systemCacheResultMessage); XCTAssertFalse(store.isClearingSystemCaches)
    }
    func testFactsHavePermanentDeletionIndividualSizesAndAdminWarning() throws {
        let plan = SystemCacheClearPlan(items: measured.items)
        XCTAssertEqual(plan.facts.actions, [.permanentDeletion])
        XCTAssertEqual(plan.facts.recovery, [.notRecoverable])
        XCTAssertEqual(plan.facts.items.map(\.bytes), measured.items.map(\.allocatedBytes))
        // D178 (integration): every page writes decimal sizes (was `plan.facts.byteStyle == .storage`).
        XCTAssertFalse(plan.facts.value(for: .capacity).contains("iB"), plan.facts.value(for: .capacity))
        XCTAssertEqual(plan.facts.permanentDeletionBytes, 41_973_000_000)
        XCTAssertFalse(plan.facts.objectWarnings.isEmpty)
        XCTAssertEqual(SystemCachePresentation.bytes(nil), 0)
    }
    func testHeadlineAddsOnlyAvailableSystemCachesAndLeavesReviewSeparate() {
        let text = CareStudioJunkResultsPage.cleanupHeadline([], systemCacheBytes: SystemCachePresentation.bytes(measured))
        XCTAssertTrue(text.contains(ByteFormat.storageString(41_973_000_000)))
    }
    func testResultAndWarningsAreLocalizedInBothLanguages() {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        let reply = SystemCacheClearReply(requestID: UUID(), items: [
            .init(cache: .coreSymbolication, result: .init(deletedEntries: 1_234, freedBytes: 2_000_000_000, skippedEntries: 2, failure: "io"))])
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            let text = SystemCachePresentation.result(reply)
            XCTAssertTrue(text.contains(ByteFormat.count(1_234)))
            XCTAssertTrue(text.contains(ByteFormat.storageString(2_000_000_000)))
            XCTAssertTrue(text.contains(language == .zhHans ? "已删除" : "Deleted"))
            XCTAssertTrue(text.contains(language == .zhHans ? "跳过" : "Skipped"))
            XCTAssertTrue(SystemCacheID.iconServices.explanation.contains(language == .zhHans ? "重新登录" : "signing in again"))
        }
    }
    func testViewSelectionStartsEmptyAndClearIsOnlyInConfirmationAction() throws {
        let sources = try SwiftSourceScanning.sources()
        let sheet = try XCTUnwrap(sources["Sources/StorageCleanerMac/Views/CareStudio/CareStudioSystemCaches.swift"])
        XCTAssertTrue(sheet.contains("@State private var selected = Set<SystemCacheID>()"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "confirmSystemCacheClear(", in: sheet), 1)
        let confirm = try SwiftSourceScanning.body(of: "private func confirmation(", in: sheet)
        XCTAssertTrue(confirm.contains("store.confirmSystemCacheClear(planID: plan.id)"))
        let page = try XCTUnwrap(sources["Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkResults.swift"])
        XCTAssertTrue(page.contains("filter != .devCaches && store.systemCacheInventory != nil"))
        XCTAssertTrue(page.contains("if hasSystemCacheTile {"))
        let smart = try XCTUnwrap(sources["Sources/StorageCleanerMac/Views/CareStudio/CareStudioSmartCare.swift"])
        XCTAssertTrue(smart.contains("SystemCachePresentation.bytes(store.systemCacheInventory)"))
    }
}

@MainActor
private final class RecordingSystemCacheService: SystemCacheServicing {
    let reply: SystemCacheInventoryReply?
    var events: [String] = []
    var cleared: [SystemCacheDirectoryIdentity] = []
    var shouldFail = false
    init(inventory: SystemCacheInventoryReply?) { reply = inventory }
    func inventory() async -> SystemCacheInventoryReply? { events.append("inventory"); return reply }
    func clear(_ directories: [SystemCacheDirectoryIdentity]) async throws -> SystemCacheClearReply {
        events.append("clear"); cleared = directories
        if shouldFail { throw SystemCacheServiceError.identityChanged }
        return .init(requestID: UUID(), items: directories.map {
            .init(cache: $0.cache, result: .init(deletedEntries: 2, freedBytes: 4_096))
        })
    }
}
