import AgentGatewayCore
import AgentShared
import Foundation
import XCTest

/// D261/D265/D268: the App decides every call in one place, in a fixed order.
final class AgentGatewayRouterTests: XCTestCase {
    private let client = AgentClientIdentity(kind: .signed, identifier: "com.openai.codex", team: "T", cdhash: nil,
                                             executablePath: "/Applications/Codex.app/Contents/MacOS/Codex", displayName: "Codex")

    private func request(_ tool: String, _ arguments: [String: AgentJSONValue] = [:], id: String = "r") -> AgentChannelRequest {
        .init(id: id, tool: tool, arguments: arguments, surface: .mcp, reportedClient: .init(name: "Totally Trusted App"))
    }

    func testOrderIsSwitchThenApprovalThenPermissionThenAvailability() async throws {
        let fixture = try RouterFixture(self)
        var response = await fixture.router(enabled: false).handle(request("get_overview"), from: client)
        XCTAssertEqual(response.refusal?.reason, .interfaceOff)

        let router = fixture.router()
        response = await router.handle(request("get_overview"), from: client)
        XCTAssertEqual(response.refusal?.reason, .approvalRequired)
        response = await router.handle(request("get_overview"), from: client)
        XCTAssertEqual(fixture.prompts.values.count, 1, "One prompt per client per ten minutes")

        fixture.registry.decide(client, .readOnly, at: Date())
        response = await router.handle(request("get_overview"), from: client)
        XCTAssertEqual(response.result?["app"]?["name"], "测试版")
        XCTAssertEqual(response.id, "r")
        response = await router.handle(request("start_scan", ["module": "junk"]), from: client)
        XCTAssertEqual(response.refusal?.reason, .insufficientPermission, "Read-only clients get R0 only")

        fixture.registry.decide(client, .propose, at: Date())
        response = await router.handle(request("start_scan", ["module": "junk"]), from: client)
        XCTAssertEqual(response.refusal?.reason, .notYetAvailable)
        response = await router.handle(request("propose_empty_trash"), from: client)
        XCTAssertEqual(response.refusal?.reason, .notYetAvailable, "Batch 1 opens no proposal")

        fixture.registry.decide(client, .denied, at: Date())
        response = await router.handle(request("get_overview"), from: client)
        XCTAssertEqual(response.refusal?.reason, .clientDenied)
        XCTAssertEqual(fixture.provider.calls.values, ["get_overview"], "The App's data is read only once, for the approved call")
    }

    func testArgumentsAreCheckedAgainAndOnlyOpenModulesAreRead() async throws {
        let fixture = try RouterFixture(self)
        fixture.registry.decide(client, .readOnly, at: Date())
        let router = fixture.router()
        var response = await router.handle(request("list_results", ["module": "junk", "path": "/"]), from: client)
        XCTAssertEqual(response.refusal?.reason, .invalidArguments)
        response = await router.handle(request("no_such_tool"), from: client)
        XCTAssertEqual(response.refusal?.reason, .invalidArguments)
        response = await router.handle(request("list_results", ["module": "large_files"]), from: client)
        XCTAssertEqual(response.refusal?.reason, .notYetAvailable)
        response = await router.handle(request("list_results", ["module": "junk"]), from: client)
        XCTAssertEqual(response.result?["module"], "junk")
    }

    func testRequestToolsAndCapabilitiesAreAnsweredByTheGateway() async throws {
        let fixture = try RouterFixture(self)
        fixture.registry.decide(client, .readOnly, at: Date())
        let router = fixture.router()
        var response = await router.handle(request("list_requests"), from: client)
        XCTAssertEqual(response.result, ["items": []])
        response = await router.handle(request("get_request", ["request_id": "Q-1"]), from: client)
        XCTAssertEqual(response.refusal?.reason, .unknownItem)
        response = await router.handle(request("describe_capabilities"), from: client)
        let capabilities = try XCTUnwrap(response.result)
        XCTAssertEqual(capabilities["permission"], "read_only")
        let tools = try XCTUnwrap(capabilities["tools"]?.arrayValue)
        XCTAssertEqual(tools.first(where: { $0["name"] == "get_overview" })?["allowed"], true)
        XCTAssertEqual(tools.first(where: { $0["name"] == "propose_move_to_trash" })?["allowed"], false)
        XCTAssertFalse(capabilities["rules"]?.arrayValue?.isEmpty ?? true)
        XCTAssertTrue(fixture.provider.calls.values.isEmpty)
    }

    func testProviderRefusalsPassThroughAndBadResultsAreNotReturned() async throws {
        let fixture = try RouterFixture(self)
        fixture.registry.decide(client, .readOnly, at: Date())
        let router = fixture.router()
        var response = await router.handle(request("get_operation_record", ["record_id": "gone"]), from: client)
        XCTAssertEqual(response.refusal?.reason, .unknownItem)
        response = await router.handle(request("get_history", ["kind": "scans"]), from: client)
        XCTAssertEqual(response.refusal?.reason, .internalError, "A result that breaks the output schema stays in the App")
    }

    func testRateLimitAndAccessLog() async throws {
        let fixture = try RouterFixture(self)
        fixture.registry.decide(client, .readOnly, at: Date())
        let router = fixture.router()
        var reasons: [AgentRefusalReason?] = []
        for index in 0..<22 { reasons.append(await router.handle(request("get_health", id: "r\(index)"), from: client).refusal?.reason) }
        XCTAssertEqual(reasons.filter { $0 == nil }.count, 20)
        XCTAssertEqual(reasons.last, .rateLimited)

        let entries = fixture.log.entries()
        XCTAssertEqual(entries.filter { $0.outcome == .allowed }.count, 20)
        XCTAssertEqual(entries.filter { $0.reason == .rateLimited }.count, 1, "Repeated limit hits are logged once")
        XCTAssertEqual(Set(entries.map(\.client)), ["Codex"], "The App's identification, never the reported name")
        XCTAssertNotNil(fixture.registry.records.first?.lastUsedAt)
    }
}

/// The App side of a call, recorded for assertions.
final class RecordingProvider: AgentReadProvider, @unchecked Sendable {
    let calls = LockedValues<String>()
    let answers = LockedAnswers()
    func read(_ tool: String, arguments: [String: AgentJSONValue], context: AgentCallContext) async throws(AgentRefusal) -> AgentJSONValue {
        calls.append(tool)
        if let answer = answers.value(tool) { return answer }
        switch tool {
        case "get_overview": return ["app": ["name": "测试版"], "client": ["name": .string(context.client.displayName)], "modules": []]
        case "get_health": return ["issues": []]
        case "list_results": return ["module": arguments["module"] ?? .null, "status": "ready", "items": []]
        case "get_operation_record": throw AgentRefusal(.unknownItem)
        default: return ["unexpected": true]
        }
    }
}

final class LockedAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: AgentJSONValue] = [:]
    func set(_ tool: String, _ answer: AgentJSONValue) { lock.withLock { stored[tool] = answer } }
    func value(_ tool: String) -> AgentJSONValue? { lock.withLock { stored[tool] } }
}

final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

struct RouterFixture {
    let registry = AgentClientRegistry(storage: .memory())
    let provider = RecordingProvider()
    let prompts = LockedValues<String>()
    let queue = AgentRequestQueue()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let log: AgentAccessLog
    let home: String

    init(_ testCase: XCTestCase, home: String = "/Users/nobody-here") throws {
        log = AgentAccessLog(fileURL: try AgentTestDirectory.make(testCase).appendingPathComponent("access.jsonl"))
        self.home = home
    }

    func router(enabled: Bool = true) -> AgentGatewayRouter {
        let prompts = prompts
        let now = now
        return AgentGatewayRouter(isEnabled: { enabled }, registry: registry, accessLog: log, provider: provider, queue: queue,
                                  resultGuard: AgentResultGuard(home: home), onApprovalNeeded: { prompts.append($0.displayName) },
                                  clock: { now })
    }
}
