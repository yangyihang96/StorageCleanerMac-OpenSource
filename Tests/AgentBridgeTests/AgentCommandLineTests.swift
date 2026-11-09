import AgentBridgeCore
import AgentShared
import Foundation
import XCTest

/// Plan §4.5: the command line shares the request layer with MCP; every call
/// prints one JSON object and the exit status tells scripts what happened.
final class AgentCommandLineTests: XCTestCase {
    func testSubcommandsMapToCatalogTools() throws {
        let cases: [([String], AgentCommandLine.Parsed)] = [
            (["status"], .call(tool: "get_overview", arguments: [:])),
            (["live", "--json"], .call(tool: "get_live_status", arguments: [:])),
            (["health"], .call(tool: "get_health", arguments: [:])),
            (["results", "junk", "--limit", "50", "--cursor", "c1"],
             .call(tool: "list_results", arguments: ["module": "junk", "limit": 50, "cursor": "c1"])),
            (["records"], .call(tool: "list_operation_records", arguments: [:])),
            (["record", "R-1"], .call(tool: "get_operation_record", arguments: ["record_id": "R-1"])),
            (["hardware", "--limit", "5"], .call(tool: "list_hardware_operations", arguments: ["limit": 5])),
            (["history", "capacity"], .call(tool: "get_history", arguments: ["kind": "capacity"])),
            (["capabilities"], .call(tool: "describe_capabilities", arguments: [:])),
            (["requests"], .call(tool: "list_requests", arguments: [:])),
            (["request", "Q-7"], .call(tool: "get_request", arguments: ["request_id": "Q-7"])),
            (["cancel-request", "Q-7"], .call(tool: "cancel_request", arguments: ["request_id": "Q-7"])),
            (["scan", "junk"], .call(tool: "start_scan", arguments: ["module": "junk"])),
            (["call", "list_results", #"{"module":"startup_items"}"#],
             .call(tool: "list_results", arguments: ["module": "startup_items"])),
            (["call", "get_health"], .call(tool: "get_health", arguments: [:])),
            (["mcp"], .mcp), (["tools"], .tools), (["--version"], .version), ([], .help), (["--help"], .help)
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(try AgentCommandLine.parse(arguments), expected, arguments.joined(separator: " "))
        }
    }

    func testUsageMistakesNeverReachTheApp() {
        let mistakes: [[String]] = [
            ["results"], ["results", "everything"], ["results", "junk", "--limit", "abc"], ["results", "junk", "--limit", "0"],
            ["results", "junk", "--depth", "3"], ["record"], ["delete", "/"], ["call", "rm_rf"], ["call", "get_health", "{oops"],
            ["call", "get_health", "[1]"], ["call", "list_results", #"{"module":"junk","path":"/"}"#], ["status", "extra"]
        ]
        for arguments in mistakes {
            XCTAssertThrowsError(try AgentCommandLine.parse(arguments), arguments.joined(separator: " ")) {
                XCTAssertFalse(($0 as? AgentCommandLine.UsageError)?.message.isEmpty ?? true)
            }
        }
    }

    func testOutputIsOneJSONObjectAndExitStatusesAreDistinct() async throws {
        let success = await AgentCommandLine.run(tool: "get_health", arguments: [:],
                                                 transport: FakeTransport(answer: { _ in .result(["issues": []]) }))
        XCTAssertEqual(success.status, 0)
        XCTAssertEqual(success.output, #"{"ok":true,"result":{"issues":[]},"tool":"get_health"}"# + "\n")

        let expected: [(AgentRefusalReason, Int32)] = [
            (.approvalRequired, 3), (.interfaceOff, 4), (.appNotRunning, 5), (.clientDenied, 6), (.insufficientPermission, 6),
            (.rateLimited, 6), (.notYetAvailable, 6), (.unknownItem, 6), (.internalError, 1), (.appUnverified, 1)
        ]
        for (reason, status) in expected {
            let refused = await AgentCommandLine.run(tool: "get_health", arguments: [:],
                                                     transport: FakeTransport(answer: { _ in .refused(AgentRefusal(reason)) }))
            XCTAssertEqual(refused.status, status, reason.rawValue)
            let object = try JSONDecoder().decode(AgentJSONValue.self, from: Data(refused.output.utf8))
            XCTAssertEqual(object["ok"], false)
            XCTAssertEqual(object["reason"], .string(reason.rawValue))
            XCTAssertEqual(object["message"], .string(AgentRefusal(reason).message))
        }
        XCTAssertEqual(Set(expected.map(\.1)).count, 5)
    }

    func testToolsListingNeedsNoAppAndShowsAvailability() throws {
        let listing = try JSONDecoder().decode(AgentJSONValue.self, from: Data(AgentCommandLine.toolListing().utf8))
        let tools = try XCTUnwrap(listing["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, AgentToolCatalog.tools.count)
        XCTAssertEqual(tools.first?["name"], "get_overview")
        XCTAssertEqual(tools.first?["available"], true)
        XCTAssertEqual(tools.last?["available"], false)
        XCTAssertEqual(tools.last?["level"], "R2")
    }
}
