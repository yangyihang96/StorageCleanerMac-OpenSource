import AgentGatewayCore
import AgentShared
import Darwin
import FileOperationShared
import Foundation

// A test double of the App for Tests/agent-e2e/run_e2e.py: the real gateway,
// real peer policy and real client identification, answering reads with
// fixture values. It reads no user data. Driven by one command per line on
// stdin; answers one JSON line per command on stdout.

struct FixtureProvider: AgentReadProvider {
    let home: String

    func read(_ tool: String, arguments: [String: AgentJSONValue], context: AgentCallContext) async throws(AgentRefusal) -> AgentJSONValue {
        switch tool {
        case "get_overview":
            // A raw home path on purpose: the guard must rewrite it (D266).
            return ["app": ["name": "QA", "version": "2.0.2", "channel": "qa", "mode": "main_window", "support": .string(home + "/fixture")],
                    "client": ["name": .string(context.client.displayName), "permission": .string(context.decision.rawValue)],
                    "modules": [["module": "junk", "status": "ready", "summary": "fixture"]],
                    "disk": nil, "memory": nil, "health": nil, "data_time": "2026-10-31T00:00:00Z"]
        case "get_live_status":
            return ["data_time": "2026-10-31T00:00:00Z", "cpu": nil, "gpu": nil, "memory": nil, "disk": nil, "network": nil,
                    "battery": nil, "thermal": nil, "fans": []]
        case "get_health":
            return ["issues": [["title": "fixture", "severity": "low"]], "score": 90, "battery": nil, "disk": nil,
                    "data_time": "2026-10-31T00:00:00Z"]
        case "list_results":
            let items: [AgentJSONValue] = (1...5).map { index in
                ["id": .string("item-\(index)"), "name": .string("Fixture \(index)"), "path": .string("\(home)/fixture/\(index)"),
                 "size_bytes": .integer(Int64(index) * 1_024)]
            }
            let page = try AgentPage(items, arguments: arguments, generation: "fixture")
            return .object(page.fields.merging(["module": arguments["module"] ?? .null, "status": "ready", "total_bytes": 15_360,
                                                "updated_at": "2026-10-31T00:00:00Z"]) { first, _ in first })
        case "list_operation_records", "list_hardware_operations":
            return .object(try AgentPage([], arguments: arguments, generation: "fixture").fields)
        case "get_operation_record":
            throw AgentRefusal(.unknownItem)
        case "get_history":
            return .object(try AgentPage([], arguments: arguments, generation: "fixture").fields
                .merging(["kind": arguments["kind"] ?? .null]) { first, _ in first })
        default:
            throw AgentRefusal(.internalError)
        }
    }
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func reply(_ value: AgentJSONValue) {
    guard let line = try? AgentLineCodec.encodeLine(value) else { return }
    FileHandle.standardOutput.write(line)
}

func description(_ status: AgentGatewayStatus) -> AgentJSONValue {
    switch status {
    case .off: "off"
    case .listening: "listening"
    case .failed(let failure): .string("failed: \(failure)")
    }
}

func json(_ identity: AgentClientIdentity) -> AgentJSONValue {
    ["name": .string(identity.displayName), "kind": .string(identity.kind.rawValue), "identifier": identity.identifier.map(AgentJSONValue.string) ?? nil,
     "team": identity.team.map(AgentJSONValue.string) ?? nil, "path": .string(identity.executablePath), "key": .string(identity.bindingKey)]
}

guard let data = option("--data"), let executable = Bundle.main.executableURL else { exit(64) }
let home = AgentDataLocation.currentUserHome()?.path ?? NSHomeDirectory()
// .../Name.app/Contents/MacOS/program
let bundle = URL(fileURLWithPath: AgentPaths.real(executable)).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let acceptAny = CommandLine.arguments.contains("--accept-any-peer")
let identifier = AgentClientIdentifier(home: home)

let gateway = AgentGateway(.init(
    dataDirectory: URL(fileURLWithPath: data, isDirectory: true),
    peerAuthorization: {
        if acceptAny { return { _ in true } }
        guard let policy = AgentGatewayPolicy.bridgePolicy(applicationURL: bundle) else { return nil }
        return { policy.permits($0) }
    },
    identifyClient: { identifier.identify(bridge: $0.pid) },
    clientStorage: .memory(),
    provider: FixtureProvider(home: home),
    onApprovalNeeded: { _ in }))

while let line = readLine() {
    let words = line.split(separator: " ").map(String.init)
    switch words.first {
    case "on":
        await gateway.setEnabled(true)
        reply(["status": description(await gateway.status)])
    case "off":
        await gateway.setEnabled(false)
        reply(["status": description(await gateway.status)])
    case "status":
        reply(["status": description(await gateway.status), "connections": .integer(Int64(await gateway.connectionCount))])
    case "pending":
        reply(["pending": .array(gateway.registry.pending.map { json($0.identity) })])
    case "approve":
        let decision = AgentClientDecision(rawValue: words.count > 1 ? words[1] : "") ?? .readOnly
        for entry in gateway.registry.pending { gateway.registry.decide(entry.identity, decision, at: Date()) }
        reply(["approved": .integer(Int64(gateway.registry.records.count))])
    case "propose":
        let decided = gateway.registry.records.first?.identity
        if let decided, let request = try? gateway.queue.add(.init(tool: "propose_empty_trash", module: "trash", summary: "清空废纸篓（fixture）", reason: nil),
                                                             from: decided, at: Date()) {
            reply(["request": .string(request.id)])
        } else {
            reply(["request": nil])
        }
    case "log":
        let entries = await gateway.accessLog.entries()
        reply(["count": .integer(Int64(entries.count)), "last": entries.last?.reason.map { .string($0.rawValue) } ?? nil])
    case "quit":
        gateway.terminate()
        reply(["status": "quit"])
        exit(0)
    default:
        reply(["error": .string("unknown command: \(line)")])
    }
}
gateway.terminate()
