import AgentBridgeCore
import AgentGatewayCore
import AgentShared
import Darwin
import FileOperationShared
import Foundation
import XCTest

/// D266: the last check before anything leaves the App. Builders in the App
/// follow the rules themselves; this catches the day one of them does not.
final class AgentResultGuardTests: XCTestCase {
    private let check = AgentResultGuard(home: "/Users/fixture")
    private let client = AgentClientIdentity(kind: .signed, identifier: "com.openai.codex", team: "T", cdhash: nil,
                                             executablePath: "/Applications/Codex.app/Contents/MacOS/Codex", displayName: "Codex")

    func testHomeFolderBecomesTildeEverywhereAndOtherUsersStayIntact() throws {
        let cleaned = try check.cleaned([
            "path": "/Users/fixture/.cache/x",
            "home": "/Users/fixture",
            "other": "/Users/fixturez/Documents/report.pdf",
            "message": "无法读取 /Users/fixture/Documents/a b.txt，已跳过 /Users/fixture/.Trash",
            "list": [["path": "/Users/fixture/Downloads"]],
            "count": 3
        ])
        XCTAssertEqual(cleaned["path"], "~/.cache/x")
        XCTAssertEqual(cleaned["home"], "~")
        XCTAssertEqual(cleaned["other"], "/Users/fixturez/Documents/report.pdf", "Another user's folder only looks similar")
        XCTAssertEqual(cleaned["message"], "无法读取 ~/Documents/a b.txt，已跳过 ~/.Trash")
        XCTAssertEqual(cleaned["list"]?[0]?["path"], "~/Downloads")
        XCTAssertEqual(cleaned["count"], 3)
    }

    func testIdentifyingAndContentFieldsAreRefusedHoweverTheyAreSpelled() {
        let banned = ["serial_number", "serialNumber", "hardware_uuid", "platform-uuid", "computer_name", "hostname", "user_name",
                      "username", "ip", "ip_address", "ipv6", "mac_address", "ssid", "wifi_name", "command_line", "cmdline", "argv",
                      "arguments", "file_content", "contents", "cookie", "password", "token", "api_key"]
        for key in banned {
            XCTAssertThrowsError(try check.cleaned(["items": [["nested": .object([key: "x"])]]]), key) {
                XCTAssertEqual(($0 as? AgentResultViolation)?.path, "items[0].nested.\(key)")
            }
        }
        for key in ["name", "bundle_id", "file_name", "total_bytes", "module", "network", "bytes_in", "category", "tokens_used_by_nobody"] {
            XCTAssertNoThrow(try check.cleaned(.object([key: 1])), key)
        }
    }

    func testPagesNeverExceedTheLimitAndAnObjectIsRequired() {
        XCTAssertNoThrow(try check.cleaned(["items": .array(Array(repeating: 1, count: 200))]))
        XCTAssertThrowsError(try check.cleaned(["items": .array(Array(repeating: 1, count: 201))])) {
            XCTAssertEqual(($0 as? AgentResultViolation)?.path, "items")
        }
        XCTAssertThrowsError(try check.cleaned("not an object"))
    }

    func testTheRouterFailsClosedOnALeakAndRewritesPaths() async throws {
        let fixture = try RouterFixture(self, home: "/Users/fixture")
        fixture.registry.decide(client, .readOnly, at: Date())
        fixture.provider.answers.set("get_overview", ["app": ["path": "/Users/fixture/Applications/x.app"], "client": [:], "modules": []])
        fixture.provider.answers.set("get_health", ["issues": [], "serial_number": "C02ABC"])
        let router = fixture.router()
        let cleaned = await router.handle(.init(id: "1", tool: "get_overview", arguments: [:], surface: .mcp), from: client)
        XCTAssertEqual(cleaned.result?["app"]?["path"], "~/Applications/x.app")

        let leak = await router.handle(.init(id: "2", tool: "get_health", arguments: [:], surface: .mcp), from: client)
        XCTAssertEqual(leak.refusal?.reason, .internalError)
        XCTAssertNil(leak.result)
        XCTAssertEqual(fixture.log.entries().last?.outcome, .failed, "Recorded as a failure, with no value in the log")
    }

    // MARK: Paging

    func testPagingWalksEveryItemOnceAndRefusesStaleCursors() throws {
        let items: [AgentJSONValue] = (0..<450).map { .integer(Int64($0)) }
        var seen: [AgentJSONValue] = []
        var cursor: String?
        var pages = 0
        repeat {
            var arguments: [String: AgentJSONValue] = ["limit": 200]
            if let cursor { arguments["cursor"] = .string(cursor) }
            let page = try AgentPage(items, arguments: arguments, generation: "g1")
            XCTAssertEqual(page.totalCount, 450)
            XCTAssertLessThanOrEqual(page.items.count, 200)
            seen += page.items
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10
        XCTAssertEqual(seen, items)
        XCTAssertEqual(pages, 3)

        let first = try AgentPage(items, arguments: [:], generation: "g1")
        XCTAssertEqual(first.items.count, AgentPage.defaultLimit)
        let next = try XCTUnwrap(first.nextCursor)
        XCTAssertThrowsError(try AgentPage(items, arguments: ["cursor": .string(next)], generation: "g2"),
                             "New results make an old cursor meaningless") {
            XCTAssertEqual(($0 as? AgentRefusal)?.reason, .invalidArguments)
        }
        for bad in ["", "garbage", "g1:", "g1:-5", "g1:abc", "g1:99999"] {
            XCTAssertThrowsError(try AgentPage(items, arguments: ["cursor": .string(bad)], generation: "g1"), bad)
        }
        XCTAssertNil(try AgentPage([], arguments: [:], generation: "g1").nextCursor)
    }

    func testPageFieldsHaveTheSharedShape() throws {
        let page = try AgentPage((0..<3).map { .integer(Int64($0)) }, arguments: ["limit": 2], generation: "g")
        XCTAssertEqual(page.fields["items"], [0, 1])
        XCTAssertEqual(page.fields["total_count"], 3)
        XCTAssertNotNil(page.fields["next_cursor"]?.stringValue)
        let last = try AgentPage([1], arguments: [:], generation: "g")
        XCTAssertEqual(last.fields["next_cursor"], .null, "Present and null, as the output schemas allow")
    }

    // MARK: Size limit

    func testAnAnswerTooBigForTheChannelBecomesARefusalAndTheConnectionSurvives() async throws {
        let path = try AgentSocketDirectory.prepare(dataDirectory: try AgentTestDirectory.make(self))
        let client = client
        let server = try AgentSocketServer(socketPath: path, authorizePeer: { $0.pid == getpid() }, identifyClient: { _ in client },
                                           handle: { request, _ in
            request.tool == "huge"
                ? .success(request.id, ["text": .string(String(repeating: "x", count: AgentChannel.maximumResponseLineBytes))])
                : .success(request.id, ["ok": true])
        })
        defer { server.stop() }
        let bridge = AgentSocketTransport(socketPath: path, authorizeApp: { $0.pid == getpid() }, interfaceEnabled: { true })
        defer { bridge.close() }
        let huge = await bridge.call(.init(id: "1", tool: "huge", arguments: [:], surface: .mcp))
        guard case .refused(let refusal) = huge else { return XCTFail("\(huge)") }
        XCTAssertEqual(refusal.reason, .internalError)
        let next = await bridge.call(.init(id: "2", tool: "small", arguments: [:], surface: .mcp))
        XCTAssertEqual(next, .result(["ok": true]))
        XCTAssertEqual(server.connectionCount, 1)
    }
}
