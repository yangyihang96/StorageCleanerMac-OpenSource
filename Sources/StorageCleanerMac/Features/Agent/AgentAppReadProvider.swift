import AgentGatewayCore
import AgentShared
import CryptoKit
import Foundation

/// D266 paging and tokens over the App's results: the App's answers to the
/// gateway's R0 reads. Off the main thread throughout; only the source hops.
struct AgentAppReadProvider: AgentReadProvider {
    let source: any AgentReadSource
    let tokens: AgentItemTokens
    let identity: AgentAppIdentity
    private let generations = ResultGenerations()

    init(source: any AgentReadSource, tokens: AgentItemTokens, identity: AgentAppIdentity) {
        self.source = source
        self.tokens = tokens
        self.identity = identity
    }

    func read(_ tool: String, arguments: [String: AgentJSONValue], context: AgentCallContext) async throws(AgentRefusal) -> AgentJSONValue {
        switch tool {
        case "get_overview": return await overview(context)
        case "get_live_status": return AgentReadModels.liveStatus(await source.live())
        case "get_health": return AgentReadModels.health(await source.health())
        case "list_results": return try await results(arguments)
        case "list_operation_records": return try operationRecords(arguments)
        case "get_operation_record": return try operationRecord(arguments)
        case "list_hardware_operations": return try await hardwareOperations(arguments)
        case "get_history": return try await history(arguments)
        default: throw AgentRefusal(.internalError)
        }
    }

    // MARK: Overview

    private func overview(_ context: AgentCallContext) async -> AgentJSONValue {
        let junk = await source.junk()
        let startup = await source.startupItems()
        let installed = await source.installedApps()
        let updates = await source.appUpdates()
        let modules = [
            AgentReadModels.moduleSummary("junk", status: junk.status, updatedAt: junk.updatedAt, count: junk.items.count,
                                          bytes: Self.total(junk.items, \.estimatedSizeBytes)),
            AgentReadModels.moduleSummary("startup_items", status: startup.status, updatedAt: startup.updatedAt, count: startup.items.count, bytes: nil),
            AgentReadModels.moduleSummary("installed_apps", status: installed.status, updatedAt: installed.updatedAt, count: installed.items.count,
                                          bytes: Self.total(installed.items, \.sizeBytes)),
            AgentReadModels.moduleSummary("app_updates", status: updates.status, updatedAt: updates.updatedAt,
                                          count: updates.items.filter(AgentReadModels.offersUpdate).count, bytes: nil)
        ]
        return AgentReadModels.overview(await source.overview(), identity: identity, context: context, modules: modules, now: Date())
    }

    // MARK: Module results

    private func results(_ arguments: [String: AgentJSONValue]) async throws(AgentRefusal) -> AgentJSONValue {
        let tokens = tokens
        switch arguments["module"]?.stringValue {
        case "junk":
            let results = await source.junk()
            var fields = try list(results, module: "junk", arguments: arguments, id: { $0.id.rawValue.uuidString },
                                  bytes: Self.total(results.items, \.estimatedSizeBytes)) { AgentReadModels.junkItem($0, tokens: tokens) }
            // D267: with nothing in memory, what the last scan found stays readable.
            if results.status != .ready, let last = await source.lastCleanupScan() { fields["last_scan"] = AgentReadModels.scanHistory(last) }
            return .object(fields)
        case "startup_items":
            return .object(try list(await source.startupItems(), module: "startup_items", arguments: arguments, id: \.id, bytes: nil) {
                AgentReadModels.startupItem($0, tokens: tokens)
            })
        case "installed_apps":
            let results = await source.installedApps()
            return .object(try list(results, module: "installed_apps", arguments: arguments, id: \.id, bytes: Self.total(results.items, \.sizeBytes)) {
                AgentReadModels.installedApp($0, tokens: tokens)
            })
        case "app_updates":
            var results = await source.appUpdates()
            results.items = results.items.filter(AgentReadModels.offersUpdate)
            return .object(try list(results, module: "app_updates", arguments: arguments, id: \.id, bytes: nil) {
                AgentReadModels.appUpdate($0, tokens: tokens)
            })
        default:
            throw AgentRefusal(.notYetAvailable)
        }
    }

    /// Items are built only for the page asked for, so only rows actually read
    /// get a token. New results make old cursors and tokens lead nowhere.
    private func list<Item>(_ results: AgentModuleResults<Item>, module: String, arguments: [String: AgentJSONValue], id: (Item) -> String,
                            bytes: Int64?, build: (Item) -> AgentJSONValue) throws(AgentRefusal) -> [String: AgentJSONValue] {
        let generation = results.generation ?? Self.generation(of: results.items.map(id))
        if generations.note(generation, module: module) { tokens.forget(module: module) }
        var fields = try page(results.items, arguments: arguments, generation: generation, build: build)
        fields["module"] = .string(module)
        fields["status"] = .string(results.status.rawValue)
        fields["total_bytes"] = bytes.map(AgentJSONValue.integer) ?? .null
        fields["updated_at"] = results.updatedAt.map { .string($0.ISO8601Format()) } ?? .null
        return fields
    }

    private func page<Item>(_ items: [Item], arguments: [String: AgentJSONValue], generation: String,
                            build: (Item) -> AgentJSONValue) throws(AgentRefusal) -> [String: AgentJSONValue] {
        let window = try AgentPage.window(count: items.count, arguments: arguments, generation: generation)
        return ["items": .array(items[window.range].map(build)),
                "next_cursor": window.nextCursor.map(AgentJSONValue.string) ?? .null,
                "total_count": .integer(Int64(items.count))]
    }

    /// For results that carry no session number of their own.
    private static func generation(of ids: [String]) -> String {
        guard !ids.isEmpty else { return "none" }
        var hash = SHA256()
        for id in ids {
            hash.update(data: Data(id.utf8))
            hash.update(data: Data([0]))
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func total<Item>(_ items: [Item], _ size: (Item) -> Int64) -> Int64 {
        items.reduce(0) { sum, item in
            let (value, overflow) = sum.addingReportingOverflow(max(0, size(item)))
            return overflow ? .max : value
        }
    }

    // MARK: Operation records

    private func operationRecords(_ arguments: [String: AgentJSONValue]) throws(AgentRefusal) -> AgentJSONValue {
        var cursor: CleanupReportIndex.Cursor?
        if let text = arguments["cursor"]?.stringValue {
            guard let decoded = Self.decodeCursor(text) else {
                throw AgentRefusal(.invalidArguments, "这个游标已经失效。请从第一页重新读取。")
            }
            cursor = decoded
        }
        // The journal's own limit per page is 100.
        let limit = min(arguments["limit"]?.integerValue.map(Int.init) ?? AgentPage.defaultLimit, 100)
        let page: CleanupReportJournal.SummaryPage
        do {
            page = try source.operationRecords(after: cursor, limit: limit)
        } catch {
            throw AgentRefusal(.internalError)
        }
        return ["items": .array(page.reports.map(AgentReadModels.operationRecordSummary)),
                "next_cursor": page.next.map { .string(Self.encodeCursor($0)) } ?? .null,
                "unreadable_count": .integer(Int64(page.unreadableEntries.count))]
    }

    static func encodeCursor(_ cursor: CleanupReportIndex.Cursor) -> String {
        "\(cursor.date.timeIntervalSinceReferenceDate)|\(cursor.id.uuidString)"
    }

    static func decodeCursor(_ text: String) -> CleanupReportIndex.Cursor? {
        let parts = text.split(separator: "|")
        guard parts.count == 2, let seconds = Double(parts[0]), seconds.isFinite, let id = UUID(uuidString: String(parts[1])) else { return nil }
        return .init(date: Date(timeIntervalSinceReferenceDate: seconds), id: id)
    }

    private func operationRecord(_ arguments: [String: AgentJSONValue]) throws(AgentRefusal) -> AgentJSONValue {
        guard let id = arguments["record_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw AgentRefusal(.unknownItem) }
        do {
            return ["record": AgentReadModels.operationRecord(try source.operationRecord(CleanPlanID(rawValue: id)))]
        } catch {
            throw AgentRefusal(.unknownItem)
        }
    }

    // MARK: Hardware and history

    private func hardwareOperations(_ arguments: [String: AgentJSONValue]) async throws(AgentRefusal) -> AgentJSONValue {
        let records: [HardwareOperationRecord]
        do {
            records = try await source.hardwareOperations()
        } catch {
            throw AgentRefusal(.internalError)
        }
        return .object(try page(records, arguments: arguments, generation: records.first?.id.uuidString ?? "none",
                                build: AgentReadModels.hardwareOperation))
    }

    private func history(_ arguments: [String: AgentJSONValue]) async throws(AgentRefusal) -> AgentJSONValue {
        var fields: [String: AgentJSONValue]
        switch arguments["kind"]?.stringValue {
        case "scans":
            let entries = await source.scanHistory()
            fields = try page(entries, arguments: arguments, generation: entries.first?.id.uuidString ?? "none", build: AgentReadModels.scanHistory)
        case "capacity":
            let points: [CapacityHistoryPoint]
            do {
                points = try source.capacityHistory().sorted { $0.recordedAt > $1.recordedAt }
            } catch {
                throw AgentRefusal(.internalError)
            }
            let generation = points.first.map { String($0.recordedAt.timeIntervalSinceReferenceDate) } ?? "none"
            fields = try page(points, arguments: arguments, generation: generation, build: AgentReadModels.capacityHistory)
        default:
            throw AgentRefusal(.invalidArguments)
        }
        fields["kind"] = arguments["kind"]
        return .object(fields)
    }
}

/// Which results each module's tokens belong to.
private final class ResultGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: String] = [:]

    /// True when the module's results are not the ones last seen.
    func note(_ generation: String, module: String) -> Bool {
        lock.withLock {
            defer { known[module] = generation }
            return known[module].map { $0 != generation } ?? false
        }
    }
}
