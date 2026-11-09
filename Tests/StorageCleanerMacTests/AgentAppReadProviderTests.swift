import AgentGatewayCore
import AgentShared
import XCTest
@testable import StorageCleanerMac

/// A source of fixed values: the provider's paging, tokens and statuses, and
/// the whole router on top of them, with none of the App's state.
private final class FixtureReadSource: AgentReadSource, @unchecked Sendable {
    private let lock = NSLock()
    private var junkResults = AgentModuleResults<ScanCandidate>(status: .notScanned)
    private var startupResults = AgentModuleResults<StartupItemsDomain.Item>(status: .notScanned)
    private var installedResults = AgentModuleResults<InstalledAppItem>(status: .notScanned)
    private var updateResults = AgentModuleResults<AppUpdateItem>(status: .notScanned)
    private var history: [ScanHistoryEntry] = []
    private var hardware: [HardwareOperationRecord] = []
    private var capacity: [CapacityHistoryPoint] = []
    private var reports: [CleanReport] = []
    private var failure: Error?

    func set(junk: AgentModuleResults<ScanCandidate>) { lock.withLock { junkResults = junk } }
    func set(installed: AgentModuleResults<InstalledAppItem>) { lock.withLock { installedResults = installed } }
    func set(history: [ScanHistoryEntry]) { lock.withLock { self.history = history } }
    func set(hardware: [HardwareOperationRecord]) { lock.withLock { self.hardware = hardware } }
    func set(capacity: [CapacityHistoryPoint]) { lock.withLock { self.capacity = capacity } }
    func set(reports: [CleanReport]) { lock.withLock { self.reports = reports } }
    func set(failure: Error?) { lock.withLock { self.failure = failure } }

    func overview() async -> AgentOverviewState { AgentOverviewState() }
    func live() async -> AgentLiveState { AgentLiveState() }
    func health() async -> AgentHealthState { AgentHealthState() }
    func junk() async -> AgentModuleResults<ScanCandidate> { lock.withLock { junkResults } }
    func startupItems() async -> AgentModuleResults<StartupItemsDomain.Item> { lock.withLock { startupResults } }
    func installedApps() async -> AgentModuleResults<InstalledAppItem> { lock.withLock { installedResults } }
    func appUpdates() async -> AgentModuleResults<AppUpdateItem> { lock.withLock { updateResults } }
    func lastCleanupScan() async -> ScanHistoryEntry? { lock.withLock { history.first } }
    func scanHistory() async -> [ScanHistoryEntry] { lock.withLock { history } }

    private func throwIfFailing() throws { if let failure = lock.withLock({ failure }) { throw failure } }

    func operationRecords(after cursor: CleanupReportIndex.Cursor?, limit: Int) throws -> CleanupReportJournal.SummaryPage {
        try throwIfFailing()
        let all = lock.withLock { reports }.enumerated().map { index, report in
            CleanupReportIndex(report: report, orderingDate: report.startedAt.addingTimeInterval(-Double(index)))
        }.sorted(by: CleanupReportIndex.newestFirst).filter { $0.follows(cursor) }
        let selected = Array(all.prefix(limit))
        return .init(reports: selected, next: all.count > limit ? selected.last?.cursor : nil, unreadableEntries: ["x"])
    }

    func operationRecord(_ id: CleanPlanID) throws -> CleanReport {
        try throwIfFailing()
        guard let report = lock.withLock({ reports.first { $0.planID == id } }) else { throw CleanupReportJournal.Failure.invalidEntry }
        return report
    }

    func hardwareOperations() async throws -> [HardwareOperationRecord] {
        try throwIfFailing()
        return lock.withLock { hardware }
    }

    func capacityHistory() throws -> [CapacityHistoryPoint] {
        try throwIfFailing()
        return lock.withLock { capacity }
    }
}

final class AgentAppReadProviderTests: XCTestCase {
    private let client = AgentClientIdentity(kind: .signed, identifier: "com.fixture", team: "T", cdhash: nil,
                                             executablePath: "~/fixture", displayName: "Fixture")
    private let source = FixtureReadSource()
    private let tokens = AgentItemTokens()
    private lazy var provider = AgentAppReadProvider(
        source: source, tokens: tokens,
        identity: AgentAppIdentity(name: "测试版", version: "2.0.2", build: "1", channel: "beta"))
    private var context: AgentCallContext { AgentCallContext(client: client, decision: .readOnly) }

    private func read(_ tool: String, _ arguments: [String: AgentJSONValue] = [:]) async throws -> AgentJSONValue {
        try await provider.read(tool, arguments: arguments, context: context)
    }

    private func refusal(_ tool: String, _ arguments: [String: AgentJSONValue]) async -> AgentRefusalReason? {
        do {
            _ = try await provider.read(tool, arguments: arguments, context: context)
            return nil
        } catch {
            return error.reason
        }
    }

    private func candidates(_ count: Int, start: Int = 0) -> [ScanCandidate] {
        (start..<(start + count)).map { AgentReadModelsTests.candidate(path: "/fixture/row-\($0)", bytes: 100) }
    }

    func testResultsPageThroughWithCursorsAndGiveTokens() async throws {
        let rows = candidates(5)
        source.set(junk: .init(status: .ready, updatedAt: Date(timeIntervalSince1970: 1_790_000_000), generation: "session-1", items: rows))

        let first = try await read("list_results", ["module": "junk", "limit": 2])
        XCTAssertEqual(first["status"]?.stringValue, "ready")
        XCTAssertEqual(first["module"]?.stringValue, "junk")
        XCTAssertEqual(first["total_count"]?.integerValue, 5)
        XCTAssertEqual(first["total_bytes"]?.integerValue, 500)
        XCTAssertEqual(first["updated_at"]?.stringValue, "2026-09-21T14:13:20Z")
        XCTAssertEqual(first["items"]?.arrayValue?.count, 2)
        let cursor = try XCTUnwrap(first["next_cursor"]?.stringValue)

        let second = try await read("list_results", ["module": "junk", "limit": 2, "cursor": .string(cursor)])
        XCTAssertEqual(second["items"]?[0]?["name"]?.stringValue, "row-2")
        let last = try await read("list_results", ["module": "junk", "limit": 2, "cursor": second["next_cursor"]!])
        XCTAssertEqual(last["items"]?.arrayValue?.count, 1)
        XCTAssertEqual(last["next_cursor"], .null)

        let id = try XCTUnwrap(first["items"]?[0]?["id"]?.stringValue)
        XCTAssertEqual(tokens.internalID(for: id, module: "junk"), rows[0].id.rawValue.uuidString)
    }

    func testOnlyRowsActuallyReadGetATokenAndAMadeUpOneFindsNothing() async throws {
        let rows = candidates(3)
        source.set(junk: .init(status: .ready, generation: "session-1", items: rows))
        _ = try await read("list_results", ["module": "junk", "limit": 1])
        let unread = tokens.tokenWithoutRemembering(for: rows[2].id.rawValue.uuidString, module: "junk")
        XCTAssertNil(tokens.internalID(for: unread, module: "junk"))
        XCTAssertNil(tokens.internalID(for: "/Users/someone/Documents", module: "junk"))
    }

    func testANewScanInvalidatesOldCursorsAndOldTokens() async throws {
        source.set(junk: .init(status: .ready, generation: "session-1", items: candidates(3)))
        let first = try await read("list_results", ["module": "junk", "limit": 1])
        let cursor = try XCTUnwrap(first["next_cursor"]?.stringValue)
        let token = try XCTUnwrap(first["items"]?[0]?["id"]?.stringValue)

        source.set(junk: .init(status: .ready, generation: "session-2", items: candidates(3, start: 10)))
        let refused = await refusal("list_results", ["module": "junk", "cursor": .string(cursor)])
        XCTAssertEqual(refused, .invalidArguments)
        XCTAssertNil(tokens.internalID(for: token, module: "junk"), "the old result's token leads nowhere")
    }

    func testResultsWithoutAGenerationStillNoticeAChange() async throws {
        func app(_ name: String) -> InstalledAppItem {
            InstalledAppItem(id: "/Applications/\(name).app", name: name, bundleIdentifier: "com.fixture.\(name)", path: "/Applications/\(name).app",
                             version: "1", build: "1", category: "", appDescription: "", sizeBytes: 10, source: "", modifiedAt: nil, relatedPaths: [],
                             relatedItems: [], status: .installed)
        }
        source.set(installed: .init(status: .ready, items: [app("A"), app("B")]))
        let first = try await read("list_results", ["module": "installed_apps", "limit": 1])
        let cursor = try XCTUnwrap(first["next_cursor"]?.stringValue)
        source.set(installed: .init(status: .ready, items: [app("C"), app("D")]))
        let refused = await refusal("list_results", ["module": "installed_apps", "cursor": .string(cursor)])
        XCTAssertEqual(refused, .invalidArguments)
    }

    func testNoResultsSayWhyAndKeepTheLastScansSummary() async throws {
        source.set(history: [ScanHistoryEntry(date: Date(timeIntervalSince1970: 1_790_000_000), scanSeconds: 1, score: 80, diskUsedBytes: 1, diskFreeBytes: 2,
                                              greenBytes: 3, yellowBytes: 4, redBytes: 5, itemCount: 6, greenCount: 1, yellowCount: 2, redCount: 3, deniedCount: 0)])
        source.set(junk: .init(status: .released))
        let released = try await read("list_results", ["module": "junk"])
        XCTAssertEqual(released["status"]?.stringValue, "released")
        XCTAssertEqual(released["items"]?.arrayValue?.count, 0)
        XCTAssertEqual(released["next_cursor"], .null)
        XCTAssertEqual(released["last_scan"]?["item_count"]?.integerValue, 6)

        source.set(junk: .init(status: .notScanned))
        let notScanned = try await read("list_results", ["module": "junk"])
        XCTAssertEqual(notScanned["status"]?.stringValue, "not_scanned")

        source.set(junk: .init(status: .scanning))
        let scanning = try await read("list_results", ["module": "junk"])
        XCTAssertEqual(scanning["status"]?.stringValue, "scanning")
    }

    func testOverviewListsTheOpenModulesWithTheirCounts() async throws {
        source.set(junk: .init(status: .ready, updatedAt: Date(timeIntervalSince1970: 1_790_000_000), generation: "s", items: candidates(2)))
        let overview = try await read("get_overview")
        let modules = try XCTUnwrap(overview["modules"]?.arrayValue)
        XCTAssertEqual(Set(modules.compactMap { $0["module"]?.stringValue }), AgentToolCatalog.openResultModules)
        let junk = try XCTUnwrap(modules.first { $0["module"]?.stringValue == "junk" })
        XCTAssertEqual(junk["status"]?.stringValue, "ready")
        XCTAssertEqual(junk["item_count"]?.integerValue, 2)
        XCTAssertEqual(junk["total_bytes"]?.integerValue, 200)
        XCTAssertEqual(overview["client"]?["name"]?.stringValue, "Fixture")
    }

    func testOperationRecordsPageWithTheirOwnCursor() async throws {
        let reports = (0..<3).map { index -> CleanReport in
            let base = AgentReadModelsTests.report()
            return CleanReport(id: UUID(), planID: CleanPlanID(), sessionID: base.sessionID, rulesVersion: base.rulesVersion, disposition: .trash,
                               scanWasPartial: false, startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 100), completedAt: base.completedAt,
                               outcome: .completed, items: [], summary: base.summary)
        }
        source.set(reports: reports)
        let first = try await read("list_operation_records", ["limit": 2])
        XCTAssertEqual(first["items"]?.arrayValue?.count, 2)
        XCTAssertEqual(first["unreadable_count"]?.integerValue, 1)
        let cursor = try XCTUnwrap(first["next_cursor"]?.stringValue)
        let second = try await read("list_operation_records", ["cursor": .string(cursor)])
        XCTAssertEqual(second["items"]?.arrayValue?.count, 1)
        XCTAssertEqual(second["next_cursor"], .null)
        let refused = await refusal("list_operation_records", ["cursor": "not-a-cursor"])
        XCTAssertEqual(refused, .invalidArguments)
    }

    func testAnOperationRecordThatIsNotThereIsAnUnknownItem() async throws {
        source.set(reports: [AgentReadModelsTests.report()])
        let record = try await read("get_operation_record", ["record_id": "11111111-2222-3333-4444-555555555555"])
        XCTAssertEqual(record["record"]?["outcome"]?.stringValue, "partiallyCompleted")
        let missing = await refusal("get_operation_record", ["record_id": "99999999-2222-3333-4444-555555555555"])
        XCTAssertEqual(missing, .unknownItem)
        let garbage = await refusal("get_operation_record", ["record_id": "/Users/someone/report.json"])
        XCTAssertEqual(garbage, .unknownItem)
    }

    func testAReadThatFailsIsAnInternalErrorWithNoDetail() async throws {
        struct Secret: Error {}
        source.set(failure: Secret())
        let records = await refusal("list_operation_records", [:])
        XCTAssertEqual(records, .internalError)
        let hardware = await refusal("list_hardware_operations", [:])
        XCTAssertEqual(hardware, .internalError)
        let capacity = await refusal("get_history", ["kind": "capacity"])
        XCTAssertEqual(capacity, .internalError)
    }

    func testHistoryIsNewestFirstAndPaged() async throws {
        source.set(capacity: (0..<3).map {
            CapacityHistoryPoint(recordedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double($0) * 86_400), totalBytes: 100,
                                 availableBytes: Int64($0), availableForImportantUsageBytes: nil)
        })
        let capacity = try await read("get_history", ["kind": "capacity", "limit": 2])
        XCTAssertEqual(capacity["kind"]?.stringValue, "capacity")
        XCTAssertEqual(capacity["items"]?[0]?["available_bytes"]?.integerValue, 2)
        XCTAssertNotEqual(capacity["next_cursor"], .null)
    }

    func testHardwareRecordsArePaged() async throws {
        source.set(hardware: (0..<3).map { HardwareOperationRecord(recordedAt: Date(timeIntervalSince1970: 1_790_000_000 - Double($0)), operation: .powerMode, outcome: .failed) })
        let page = try await read("list_hardware_operations", ["limit": 1])
        XCTAssertEqual(page["items"]?.arrayValue?.count, 1)
        XCTAssertNotEqual(page["next_cursor"], .null)
    }

    /// The whole way an AI's read goes: every open App tool on the App's
    /// provider, through the router's gates, D266's guard and the output schema.
    func testEveryOpenToolAnswersThroughTheRouter() async throws {
        source.set(junk: .init(status: .ready, generation: "s", items: candidates(2)))
        source.set(reports: [AgentReadModelsTests.report()])
        let registry = AgentClientRegistry(storage: .memory())
        registry.decide(client, .readOnly, at: Date())
        let router = AgentGatewayRouter(isEnabled: { true }, registry: registry, accessLog: nil, provider: provider,
                                        resultGuard: AgentResultGuard(home: AgentReadModelsTests.home), onApprovalNeeded: { _ in })
        let arguments: [String: [String: AgentJSONValue]] = [
            "list_results": ["module": "junk"],
            "get_operation_record": ["record_id": "11111111-2222-3333-4444-555555555555"],
            "get_history": ["kind": "scans"],
            "get_request": ["request_id": "none"],
            "cancel_request": ["request_id": "none"]
        ]
        var answered = 0
        for tool in AgentToolCatalog.tools where tool.availability == .now {
            let response = await router.handle(AgentChannelRequest(id: "1", tool: tool.name, arguments: arguments[tool.name] ?? [:], surface: .mcp), from: client)
            if ["get_request", "cancel_request"].contains(tool.name) {
                XCTAssertEqual(response.refusal?.reason, .unknownItem, tool.name)
            } else {
                XCTAssertNil(response.refusal, "\(tool.name): \(String(describing: response.refusal))")
                XCTAssertNotNil(response.result, tool.name)
            }
            answered += 1
        }
        XCTAssertEqual(answered, 12)
    }

    func testAModuleThatIsNotOpenIsRefusedBeforeTheProvider() async throws {
        let registry = AgentClientRegistry(storage: .memory())
        registry.decide(client, .readOnly, at: Date())
        let router = AgentGatewayRouter(isEnabled: { true }, registry: registry, accessLog: nil, provider: provider, onApprovalNeeded: { _ in })
        let response = await router.handle(AgentChannelRequest(id: "1", tool: "list_results", arguments: ["module": "privacy"], surface: .mcp), from: client)
        XCTAssertEqual(response.refusal?.reason, .notYetAvailable)
    }
}
