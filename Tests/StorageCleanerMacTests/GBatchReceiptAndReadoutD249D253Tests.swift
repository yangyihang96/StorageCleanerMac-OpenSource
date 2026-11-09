import FileOperationShared
import XCTest
@testable import StorageCleanerMac

/// D249 and D253 (G batch on install22, 2026-10-27).
/// D249: three system-cache clears in a row left only the last message in the
/// sheet and nothing in `CleanupReports`; each clear is now a receipt.
/// D253: the benchmark result charts stamp samples with elapsed seconds, and
/// the accessibility value read 90 s as “11:01:30 AM” (UTC+11).
final class GBatchReceiptAndReadoutD249D253Tests: XCTestCase {
    private func inventoryItem(_ cache: SystemCacheID, bytes: Int64, inode: UInt64) -> SystemCacheInventoryItem {
        SystemCacheInventoryItem(cache: cache, allocatedBytes: bytes, entryCount: 10, device: 16_777_234, inode: inode, failure: nil)
    }
    private var plan: SystemCacheClearPlan {
        SystemCacheClearPlan(items: [inventoryItem(.coreSymbolication, bytes: 4_400_000_000, inode: 11),
                                     inventoryItem(.iconServices, bytes: 120_900_000, inode: 22)])
    }

    // MARK: D249

    func testEachClearedFolderBecomesAPermanentDeletionReceipt() throws {
        let reply = SystemCacheClearReply(requestID: UUID(), items: [
            SystemCacheClearItem(cache: .coreSymbolication, result: .init(deletedEntries: 687, freedBytes: 121_000_000)),
            SystemCacheClearItem(cache: .iconServices, result: .init(deletedEntries: 7, freedBytes: 1_200_000)),
        ])
        let started = Date(timeIntervalSince1970: 1_000), finished = Date(timeIntervalSince1970: 1_005)
        let report = try XCTUnwrap(SystemCacheClearReceipt.report(plan: plan, reply: reply, outcomeUnknown: false,
                                                                  startedAt: started, completedAt: finished))
        XCTAssertEqual(report.rulesVersion, SystemCacheClearReceipt.ruleID)
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.items.map(\.sourcePath), [SystemCacheID.coreSymbolication.directoryPath,
                                                        SystemCacheID.iconServices.directoryPath])
        XCTAssertEqual(report.items.map(\.deletedEntryCount), [687, 7])
        for item in report.items {
            guard case .deleted(let receipt) = item.outcome else { return XCTFail("\(item.outcome)") }
            XCTAssertEqual(receipt.deletedAt, finished)
            XCTAssertEqual(receipt.deletedIdentity.entryKind, .directory)
        }
        XCTAssertEqual(report.summary.deletedItemCount, 2)
        XCTAssertEqual(report.summary.permanentlyFreedBytes, 122_200_000)
        XCTAssertEqual(report.summary.movedItemCount, 0)
        XCTAssertTrue(report.restorableReceipts.isEmpty, "a permanent deletion has nothing to restore")
        XCTAssertEqual(report.startedAt, started)
    }

    func testOnlyAClearThatCanHaveDeletedSomethingIsRecorded() throws {
        XCTAssertNil(SystemCacheClearReceipt.report(plan: plan, reply: nil, outcomeUnknown: false,
                                                    startedAt: Date(), completedAt: Date()), "authorization not given")
        XCTAssertNil(SystemCacheClearReceipt.report(plan: plan, reply: SystemCacheClearReply(requestID: UUID(), failure: "expired"),
                                                    outcomeUnknown: false, startedAt: Date(), completedAt: Date()),
                     "the helper refused before committing")
        let unknown = try XCTUnwrap(SystemCacheClearReceipt.report(plan: plan, reply: nil, outcomeUnknown: true,
                                                                   startedAt: Date(), completedAt: Date()))
        XCTAssertEqual(unknown.outcome, .failed)
        XCTAssertTrue(unknown.items.allSatisfy { $0.outcome == .failed(CleanFailure(code: .deletionOutcomeUnknown, detailCode: "connection-interrupted")) })
        let partial = try XCTUnwrap(SystemCacheClearReceipt.report(plan: plan, reply: SystemCacheClearReply(requestID: UUID(), items: [
            SystemCacheClearItem(cache: .coreSymbolication, result: .init(deletedEntries: 3, freedBytes: 4_096, skippedEntries: 1, failure: "timeLimit")),
            SystemCacheClearItem(cache: .iconServices, result: .init(deletedEntries: 0, failure: "identityChanged")),
        ]), outcomeUnknown: false, startedAt: Date(), completedAt: Date()))
        XCTAssertEqual(partial.outcome, .failed)
        XCTAssertEqual(partial.items.first?.outcome, .failed(CleanFailure(code: .deletionOutcomeUnknown, detailCode: "timeLimit")))
        XCTAssertEqual(partial.items.last?.outcome, .failed(CleanFailure(code: .unexpected, detailCode: "identityChanged")))
    }

    @MainActor func testOperationHistoryNamesTheClearAndOffersNoRestore() throws {
        XCTAssertEqual(OperationRecordPresentation.title(rulesVersion: SystemCacheClearReceipt.ruleID, subject: "com.apple.coresymbolicationd"),
                       SystemCacheClearReceipt.historyTitle)
        XCTAssertFalse(OperationRecordPresentation.offersRestore(rulesVersion: SystemCacheClearReceipt.ruleID))
        XCTAssertTrue(OperationRecordPresentation.offersRestore(rulesVersion: "system.user-caches"))
        let language = MiniWindowLogicLanguageScope(.zhHans)
        defer { language.restore() }
        let report = try XCTUnwrap(SystemCacheClearReceipt.report(plan: plan, reply: SystemCacheClearReply(requestID: UUID(), items: [
            SystemCacheClearItem(cache: .coreSymbolication, result: .init(deletedEntries: 687, freedBytes: 121_000_000)),
        ]), outcomeUnknown: false, startedAt: Date(), completedAt: Date()))
        XCTAssertEqual(SystemCacheClearReceipt.itemLabel(report.items[0]), "已永久清除 · 687 项内容 · 不可恢复")
        XCTAssertEqual(SystemCacheClearReceipt.itemLabel(report.items[1]), "清除未完成，部分内容可能已删除")
        XCTAssertTrue(SystemCacheClearReceipt.freedLabel(report.summary).hasPrefix("永久释放：约 "))
        XCTAssertEqual(report.outcome, .partiallyCompleted, "the icon cache came back without a result")
    }

    func testOlderReceiptsWithoutTheNewFieldsStillDecode() throws {
        let item = CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "r", sourcePath: "/x", estimatedBytes: 1, outcome: .notProcessed)
        let encoded = try JSONEncoder().encode(item)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("deletedEntryCount"), "nil is not written, so older readers see the same JSON")
        XCTAssertNil(try JSONDecoder().decode(CleanReportItem.self, from: encoded).deletedEntryCount)
    }

    func testTheStoreRecordsEveryClearInTheOperationJournal() throws {
        let source = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Stores/ScanStore.swift"), encoding: .utf8)
        let confirm = SwiftSourceScanning.code(try r2SourceDeclaration("func confirmSystemCacheClear(planID: UUID) async", in: source))
        XCTAssertTrue(confirm.contains("SystemCacheClearReceipt.report(plan: plan, reply: reply, outcomeUnknown: outcomeUnknown"))
        XCTAssertTrue(confirm.contains("CleanReportStore.recordDetached(report, journal: operationJournal)"))
        XCTAssertTrue(confirm.contains("== .outcomeUnknown"))
    }

    // MARK: D253

    @MainActor func testAChartWhoseXIsNotTimeReadsItsXValue() {
        let elapsed = Date(timeIntervalSinceReferenceDate: 90)
        XCTAssertEqual(LightfieldTrendChart.readoutLabel(time: elapsed, xFraction: 0.5,
                                                         xValueFormat: .scaled(maximum: 180, unit: "s"), precise: true),
                       "90.0 s")
        XCTAssertEqual(LightfieldTrendChart.readoutLabel(time: elapsed, xFraction: 0.25,
                                                         xValueFormat: .scaled(maximum: 40, unit: "W"), precise: false),
                       "10.0 W")
        let wall = Date(timeIntervalSince1970: 1_793_070_984)
        XCTAssertEqual(LightfieldTrendChart.readoutLabel(time: wall, xFraction: nil, xValueFormat: nil, precise: true),
                       wall.formatted(date: .omitted, time: .standard), "a time chart keeps the clock")
        XCTAssertEqual(LightfieldTrendChart.readoutLabel(time: wall, xFraction: nil, xValueFormat: .scaled(maximum: 1, unit: "W"), precise: false),
                       wall.formatted(date: .omitted, time: .shortened), "no x position: clock time")
    }

    func testNoReadoutFormatsASampleTimeAsAClock() throws {
        let source = SwiftSourceScanning.code(try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldCharts.swift"), encoding: .utf8))
        XCTAssertFalse(source.contains("samples[index].time.formatted("), "readouts go through readoutLabel(at:precise:)")
        XCTAssertTrue(source.contains("readoutLabel(at: index, precise: true)"))
        XCTAssertTrue(source.contains("readoutLabel(at: index, precise: false)"))
    }
}
