import AgentBridgeCore
import AgentShared
import Foundation
import XCTest

/// D269 conversations, checked line by line against the 2026-07-28 schema and
/// the two legacy revisions (versioning, stdio and tools pages).
final class AgentMCPServerTests: XCTestCase {
    private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"claude-code","version":"3.0"}}"#

    func testLegacyHandshakeNegotiatesAndThenServesTools() async throws {
        let harness = MCPHarness(answer: { _ in .result(["app": ["name": "测试版"], "client": [:], "modules": []]) })
        await harness.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"codex","version":"0.9"}}}"#)
        await harness.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_overview","arguments":{}}}"#)
        let lines = await harness.responses()
        XCTAssertEqual(lines.count, 4, "The initialized notification gets no answer")

        let initialize = try XCTUnwrap(lines[0]["result"])
        XCTAssertEqual(lines[0]["id"], 1)
        XCTAssertEqual(initialize["protocolVersion"], "2025-06-18")
        XCTAssertEqual(initialize["capabilities"], ["tools": [:]])
        XCTAssertEqual(initialize["serverInfo"]?["name"], "storage-cleaner-beta")
        XCTAssertNotNil(initialize["instructions"]?.stringValue?.range(of: "确认"))
        XCTAssertNil(initialize["resultType"], "Legacy results keep the legacy shape")

        let tools = try XCTUnwrap(lines[1]["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.map { $0["name"]?.stringValue ?? "" }, AgentToolCatalog.tools.map(\.name))
        XCTAssertEqual(tools[0]["title"], "概况")
        XCTAssertEqual(tools[0]["annotations"]?["readOnlyHint"], true)
        XCTAssertNil(lines[1]["result"]?["ttlMs"])

        XCTAssertEqual(lines[2], ["jsonrpc": "2.0", "id": "p", "result": [:]])

        let call = try XCTUnwrap(lines[3]["result"])
        XCTAssertEqual(call["structuredContent"]?["app"]?["name"], "测试版")
        XCTAssertNil(call["isError"])
        let text = try XCTUnwrap(call["content"]?[0]?["text"]?.stringValue)
        XCTAssertEqual(try JSONDecoder().decode(AgentJSONValue.self, from: Data(text.utf8)), call["structuredContent"],
                       "Structured results also come back as a text block with the same JSON")

        let forwarded = await harness.transport.requests
        XCTAssertEqual(forwarded.map(\.tool), ["get_overview"])
        XCTAssertEqual(forwarded.first?.surface, .mcp)
        XCTAssertEqual(forwarded.first?.reportedClient, AgentReportedClient(name: "codex", version: "0.9"))
    }

    func testLegacyHandshakeFallsBackToTheNewestLegacyVersion() async {
        let harness = MCPHarness()
        await harness.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#)
        let lines = await harness.responses()
        XCTAssertEqual(lines.first?["result"]?["protocolVersion"], "2025-11-25")
    }

    func testModernDiscoverAndCallsAreStatelessWithRequiredFields() async throws {
        let harness = MCPHarness(answer: { _ in .result(["issues": []]) })
        await harness.send(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"# + modernMeta + "}}")
        await harness.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"# + modernMeta + "}}")
        await harness.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_health","arguments":{},"# + modernMeta + "}}")
        let lines = await harness.responses()
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertEqual(line["result"]?["resultType"], "complete")
            XCTAssertEqual(line["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"], "storage-cleaner-beta")
        }
        let discover = try XCTUnwrap(lines[0]["result"])
        XCTAssertEqual(discover["supportedVersions"], ["2026-07-28", "2025-11-25", "2025-06-18"])
        XCTAssertEqual(discover["capabilities"], ["tools": [:]])
        XCTAssertNotNil(discover["instructions"]?.stringValue)
        for cacheable in [discover, try XCTUnwrap(lines[1]["result"])] {
            XCTAssertEqual(cacheable["ttlMs"], 3_600_000, "Required by CacheableResult in 2026-07-28")
            XCTAssertEqual(cacheable["cacheScope"], "private")
        }
        XCTAssertEqual(lines[2]["result"]?["structuredContent"], ["issues": []])
        let forwarded = await harness.transport.requests
        XCTAssertEqual(forwarded.first?.reportedClient, AgentReportedClient(name: "claude-code", version: "3.0"))
    }

    func testVersionErrorsAndEraMistakes() async throws {
        let harness = MCPHarness()
        await harness.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":4,"method":"ping","params":{"# + modernMeta + "}}")
        let lines = await harness.responses()
        XCTAssertEqual(lines[0]["error"]?["code"], -32022)
        XCTAssertEqual(lines[0]["error"]?["data"], ["supported": ["2026-07-28", "2025-11-25", "2025-06-18"], "requested": "1900-01-01"])
        XCTAssertEqual(lines[1]["error"]?["code"], -32602, "clientCapabilities is required in 2026-07-28")
        XCTAssertEqual(lines[2]["error"]?["code"], -32600, "Neither initialize nor modern _meta")
        XCTAssertNotNil(lines[2]["error"]?["message"]?.stringValue?.range(of: "2026-07-28"))
        XCTAssertEqual(lines[3]["error"]?["code"], -32601, "There is no ping in 2026-07-28")
    }

    func testMalformedInputGetsJSONRPCErrorsWithoutAnID() async {
        let harness = MCPHarness()
        await harness.send("{not json")
        await harness.send(#"[{"jsonrpc":"2.0","id":1,"method":"tools/list"}]"#)
        await harness.server.receive(.overlong)
        await harness.send(#"{"jsonrpc":"2.0","id":9,"method":"resources/list","params":{"# + modernMeta + "}}")
        await harness.send(#"{"jsonrpc":"2.0","method":"notifications/unknown"}"#)
        let lines = await harness.responses()
        XCTAssertEqual(lines.map { $0["error"]?["code"] }, [-32700, -32600, -32600, -32601])
        // 2025-11-25 onwards: `id?: RequestId`. An unknown id is left out; null
        // is not a RequestId, and the official schema rejects it.
        XCTAssertEqual(lines.prefix(3).map { $0["id"] }, [nil, nil, nil])
        XCTAssertEqual(lines[3]["id"], 9)
    }

    func testToolErrorsAreProtocolErrorsAndRefusalsAreToolResults() async throws {
        let harness = MCPHarness(answer: { request in
            request.tool == "get_overview" ? .refused(AgentRefusal(.approvalRequired)) : .result(["unexpected": true])
        })
        await harness.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rm_rf","arguments":{},"# + modernMeta + "}}")
        await harness.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_results","arguments":{"module":"junk","limit":999},"# + modernMeta + "}}")
        await harness.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_overview","arguments":{},"# + modernMeta + "}}")
        await harness.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_history","arguments":{"kind":"scans"},"# + modernMeta + "}}")
        let lines = await harness.responses()
        XCTAssertEqual(lines[0]["error"]?["code"], -32602)
        XCTAssertEqual(lines[0]["error"]?["message"], "Unknown tool: rm_rf")
        XCTAssertEqual(lines[1]["error"]?["code"], -32602)
        XCTAssertNotNil(lines[1]["error"]?["message"]?.stringValue?.range(of: "limit"))

        let refused = try XCTUnwrap(lines[2]["result"])
        XCTAssertEqual(refused["isError"], true)
        XCTAssertEqual(refused["resultType"], "complete")
        XCTAssertNil(refused["structuredContent"], "An error result carries text only")
        XCTAssertNotNil(refused["content"]?[0]?["text"]?.stringValue?.range(of: "approval_required"))

        XCTAssertEqual(lines[3]["error"]?["code"], -32603, "A result that breaks the output schema is never passed on")
        let forwarded = await harness.transport.requests
        XCTAssertEqual(forwarded.map(\.tool), ["get_overview", "get_history"], "Unknown tools and bad arguments stop at the bridge")
    }

    func testCancelledRequestsGetNoAnswerAndOthersStillDo() async throws {
        let harness = MCPHarness(answer: { _ in .result(["issues": []]) })
        await harness.transport.holdNext()
        await harness.post(#"{"jsonrpc":"2.0","id":"slow","method":"tools/call","params":{"name":"get_health","arguments":{},"# + modernMeta + "}}")
        await harness.transport.waitUntilHeld()
        await harness.post(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"slow","reason":"user"}}"#)
        await harness.post(#"{"jsonrpc":"2.0","id":"fast","method":"tools/call","params":{"name":"get_health","arguments":{},"# + modernMeta + "}}")
        await harness.transport.release()
        await harness.server.drain()
        let lines = await harness.responses()
        XCTAssertEqual(lines.map { $0["id"] }, ["fast"], "MUST NOT send any further messages for a cancelled request")
    }

    func testEveryOutputLineIsOneJSONRPCMessage() async throws {
        let harness = MCPHarness(answer: { _ in .result(["text": "two\nlines", "app": [:], "client": [:], "modules": []]) })
        await harness.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_overview"}}"#)
        await harness.server.drain()
        for line in harness.output.lines {
            XCTAssertEqual(line.last, 0x0A)
            XCTAssertFalse(line.dropLast().contains(0x0A))
            XCTAssertEqual(try JSONDecoder().decode(AgentJSONValue.self, from: line)["jsonrpc"], "2.0")
        }
        XCTAssertEqual(harness.output.lines.count, 2, "A missing arguments object is an empty one")
    }
}

/// Collects what the server writes to stdout.
final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []
    var lines: [Data] { lock.withLock { stored } }
    func write(_ line: Data) { lock.withLock { stored.append(line) } }
}

actor FakeTransport: AgentAppTransport {
    private(set) var requests: [AgentChannelRequest] = []
    private let answer: @Sendable (AgentChannelRequest) -> AgentCallResult
    private var holding = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    init(answer: @escaping @Sendable (AgentChannelRequest) -> AgentCallResult) { self.answer = answer }

    func call(_ request: AgentChannelRequest) async -> AgentCallResult {
        requests.append(request)
        if holding {
            holding = false
            await withCheckedContinuation { continuation in
                held = continuation
                heldWaiters.forEach { $0.resume() }; heldWaiters = []
            }
        }
        return answer(request)
    }

    func holdNext() { holding = true }
    func waitUntilHeld() async { if held == nil { await withCheckedContinuation { heldWaiters.append($0) } } }
    func release() { held?.resume(); held = nil }
}

struct MCPHarness {
    let output = LineSink()
    let transport: FakeTransport
    let server: AgentMCPServer

    init(answer: @escaping @Sendable (AgentChannelRequest) -> AgentCallResult = { _ in .result([:]) }) {
        transport = FakeTransport(answer: answer)
        let sink = output
        server = AgentMCPServer(identity: .init(name: "storage-cleaner-beta", title: "测试版", version: "2.0.2 (1)"),
                                transport: transport, output: { sink.write($0) })
    }

    /// One line, then wait for its answer so the order of output is fixed.
    func send(_ text: String) async {
        await server.receive(.line(Data(text.utf8)))
        await server.drain()
    }

    /// One line without waiting, as a client does while a call is still running.
    func post(_ text: String) async { await server.receive(.line(Data(text.utf8))) }

    func responses() async -> [AgentJSONValue] {
        await server.drain()
        return output.lines.compactMap { try? JSONDecoder().decode(AgentJSONValue.self, from: $0) }
    }
}
