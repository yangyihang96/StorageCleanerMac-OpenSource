import AgentShared
import Foundation
import XCTest

/// D260/D269: the bridge ↔ App channel and the tool catalog are plain data;
/// these tests pin their wire form and the catalog every client sees.
final class AgentProtocolTests: XCTestCase {
    func testJSONValueRoundTripKeepsIntegersAndSortsKeys() throws {
        let text = #"{"b":[true,null,"x",1.5,-2],"a":7,"c":{"z":9007199254740993,"y":"/Users/x"}}"#
        let value = try JSONDecoder().decode(AgentJSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(value["a"], .integer(7))
        XCTAssertEqual(value["c"]?["z"], .integer(9_007_199_254_740_993), "Large integers must not pass through Double")
        XCTAssertEqual(String(decoding: try AgentLineCodec.encodeLine(value), as: UTF8.self),
                       #"{"a":7,"b":[true,null,"x",1.5,-2],"c":{"y":"/Users/x","z":9007199254740993}}"# + "\n")
    }

    func testEncodedLinesNeverContainARawNewline() throws {
        let value: AgentJSONValue = ["text": "line one\nline two\r\n", "list": ["a\nb"]]
        let line = try AgentLineCodec.encodeLine(value)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertFalse(line.dropLast().contains(0x0A), "MCP stdio messages must not contain embedded newlines")
        XCTAssertEqual(try AgentLineCodec.decode(AgentJSONValue.self, from: line.dropLast()), value)
    }

    func testLineBufferSplitsChunksDropsBlankLinesAndReportsOverlongLinesOnce() {
        var buffer = AgentLineBuffer(maximumLineLength: 8)
        XCTAssertEqual(buffer.append(Data("ab".utf8)), [])
        XCTAssertEqual(buffer.append(Data("c\r\n\n12345".utf8)), [.line(Data("abc".utf8))])
        XCTAssertEqual(buffer.append(Data("6789TOO-LONG".utf8)), [.overlong], "Reported as soon as the limit is passed")
        XCTAssertEqual(buffer.append(Data("STILL\nok\n".utf8)), [.line(Data("ok".utf8))], "The rest of the long line is dropped")
        XCTAssertEqual(buffer.append(Data("tail".utf8)), [])
        XCTAssertEqual(buffer.finish(), [.line(Data("tail".utf8))])
    }

    func testChannelMessagesRoundTripAndIgnoreUnknownFields() throws {
        let request = AgentChannelRequest(id: "r1", tool: "get_overview", arguments: ["limit": 5], surface: .mcp,
                                          reportedClient: .init(name: "claude-code", version: "2.1"))
        let decoded = try AgentLineCodec.decode(AgentChannelRequest.self, from: try AgentLineCodec.encodeLine(request).dropLast())
        XCTAssertEqual(decoded, request)

        let future = #"{"id":"r2","refusal":{"reason":"approval_required","message":"m","hint":"new"},"extra":1}"#
        let response = try AgentLineCodec.decode(AgentChannelResponse.self, from: Data(future.utf8))
        XCTAssertEqual(response.refusal?.reason, .approvalRequired)
        XCTAssertNil(response.result)

        let unknownReason = #"{"id":"r3","refusal":{"reason":"something_new","message":"m"}}"#
        XCTAssertEqual(try AgentLineCodec.decode(AgentChannelResponse.self, from: Data(unknownReason.utf8)).refusal?.reason,
                       .internalError, "A reason from a newer App is still a refusal, never a success")
    }

    func testEveryRefusalHasAChineseDefaultMessage() {
        for reason in AgentRefusalReason.allCases {
            XCTAssertFalse(AgentRefusal(reason).message.isEmpty, reason.rawValue)
            XCTAssertNotNil(AgentRefusal(reason).message.range(of: "\\p{Han}", options: .regularExpression), reason.rawValue)
        }
    }

    func testCatalogNamesAndLevelsAreStable() {
        let snapshot = AgentToolCatalog.tools.map { "\($0.name):\($0.level.rawValue):\($0.availability.rawValue)" }
        XCTAssertEqual(snapshot, [
            "get_overview:R0:now", "get_live_status:R0:now", "get_health:R0:now", "list_results:R0:now",
            "list_operation_records:R0:now", "get_operation_record:R0:now", "list_hardware_operations:R0:now",
            "get_history:R0:now", "describe_capabilities:R0:now",
            "list_requests:R0:now", "get_request:R0:now", "cancel_request:R0:now",
            "start_scan:R1:later", "cancel_scan:R1:later", "get_scan_status:R1:later",
            "propose_move_to_trash:R2:later", "propose_restore:R2:later", "propose_startup_change:R2:later",
            "propose_quit_apps:R2:later", "propose_uninstall:R2:later", "propose_app_updates:R2:later",
            "propose_empty_trash:R2:later", "propose_system_cache_clear:R2:later", "propose_hardware_change:R2:later"
        ])
        XCTAssertEqual(Set(AgentToolCatalog.tools.map(\.name)).count, AgentToolCatalog.tools.count)
        XCTAssertEqual(AgentToolCatalog.tool(named: "list_results")?.level, .read)
        XCTAssertNil(AgentToolCatalog.tool(named: "delete_everything"))
    }

    func testCatalogSchemasAreObjectsAndAnnotationsAreWrittenOut() {
        for tool in AgentToolCatalog.tools {
            XCTAssertEqual(tool.inputSchema["type"], "object", tool.name)
            XCTAssertEqual(tool.inputSchema["additionalProperties"], false, tool.name)
            XCTAssertEqual(tool.outputSchema["type"], "object", "Legacy MCP requires an object root: \(tool.name)")
            XCTAssertNotNil(tool.title.range(of: "\\p{Han}", options: .regularExpression), tool.name)
            XCTAssertNotNil(tool.summary.range(of: "\\p{Han}", options: .regularExpression), tool.name)
            let hints = tool.annotations
            XCTAssertEqual(Set(hints.keys), ["title", "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"], tool.name)
            XCTAssertEqual(hints["openWorldHint"], false, tool.name)
            switch tool.level {
            case .read where tool.name == "cancel_request":
                XCTAssertEqual(hints["readOnlyHint"], false)
                XCTAssertEqual(hints["destructiveHint"], false)
            case .read, .scan:
                XCTAssertEqual(hints["readOnlyHint"], true, tool.name)
                XCTAssertEqual(hints["destructiveHint"], false, tool.name)
            case .propose:
                XCTAssertEqual(hints["readOnlyHint"], false, tool.name)
                XCTAssertEqual(hints["destructiveHint"], true, "Plan §4.4 keeps proposals cautious: \(tool.name)")
                XCTAssertEqual(hints["idempotentHint"], false, tool.name)
            }
        }
    }

    func testLiveStatusCanSayThereIsNoSampleYet() throws {
        let schema = try XCTUnwrap(AgentToolCatalog.tool(named: "get_live_status")?.outputSchema)
        XCTAssertNil(AgentSchemaValidator.violation(of: ["data_time": nil], against: schema),
                     "D268: nothing is sampled for an AI, so there may be no reading to give")
    }

    func testProposalsReferToItemsByIDNeverByPath() {
        for tool in AgentToolCatalog.tools where tool.level == .propose {
            let properties = tool.inputSchema["properties"]?.objectValue ?? [:]
            for name in properties.keys {
                XCTAssertFalse(name.contains("path"), "D266: \(tool.name).\(name)")
            }
        }
    }

    func testSchemaValidatorChecksTypesRequiredEnumsRangesAndExtras() throws {
        let schema = try XCTUnwrap(AgentToolCatalog.tool(named: "list_results")?.inputSchema)
        XCTAssertNil(AgentSchemaValidator.violation(of: ["module": "junk", "limit": 50], against: schema))
        XCTAssertEqual(AgentSchemaValidator.violation(of: [:], against: schema)?.path, "module")
        XCTAssertEqual(AgentSchemaValidator.violation(of: ["module": "everything"], against: schema)?.path, "module")
        XCTAssertEqual(AgentSchemaValidator.violation(of: ["module": "junk", "limit": 201], against: schema)?.path, "limit")
        XCTAssertEqual(AgentSchemaValidator.violation(of: ["module": "junk", "limit": "5"], against: schema)?.path, "limit")
        XCTAssertEqual(AgentSchemaValidator.violation(of: ["module": "junk", "path": "/"], against: schema)?.path, "path")

        let nested: AgentJSONValue = ["type": "object", "required": ["items"], "properties": [
            "items": ["type": "array", "maxItems": 2, "items": ["type": "object", "required": ["id"],
                                                                "properties": ["id": ["type": "string"]]]],
            "note": ["type": ["string", "null"]]
        ]]
        XCTAssertNil(AgentSchemaValidator.violation(of: ["items": [["id": "a"]], "note": nil], against: nested))
        XCTAssertEqual(AgentSchemaValidator.violation(of: ["items": [["id": 1]]], against: nested)?.path, "items[0].id")
        XCTAssertEqual(AgentSchemaValidator.violation(of: ["items": [["id": "a"], ["id": "b"], ["id": "c"]]], against: nested)?.path,
                       "items")
    }
}
