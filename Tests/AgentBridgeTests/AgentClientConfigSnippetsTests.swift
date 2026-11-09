import AgentGatewayCore
import AgentShared
import Foundation
import XCTest

/// D265 "复制接入配置": the app gives the snippets; editing a client's own
/// configuration stays with the user.
final class AgentClientConfigSnippetsTests: XCTestCase {
    private let path = "/Applications/测试版.app/Contents/Helpers/storage-cleaner-agent"

    func testEachClientGetsItsOwnFormat() throws {
        let snippets = AgentClientConfigSnippets(serverName: "storage-cleaner-beta", bridgePath: path)
        let desktop = try JSONDecoder().decode(AgentJSONValue.self, from: Data(snippets.claudeDesktop.utf8))
        XCTAssertEqual(desktop, ["mcpServers": ["storage-cleaner-beta": ["command": .string(path), "args": ["mcp"]]]])
        XCTAssertFalse(snippets.claudeDesktop.contains("\\/"), "Paths stay readable")
        XCTAssertEqual(snippets.claudeCode, "claude mcp add --scope user storage-cleaner-beta -- '\(path)' mcp")
        XCTAssertEqual(snippets.codex, """
            [mcp_servers.storage-cleaner-beta]
            command = "\(path)"
            args = ["mcp"]
            """)
    }

    func testPathsWithQuotesAreEscapedForEachFormat() throws {
        let odd = "/Volumes/It's \"Here\"\\/App.app/Contents/Helpers/storage-cleaner-agent"
        let snippets = AgentClientConfigSnippets(serverName: "storage-cleaner", bridgePath: odd)
        let desktop = try JSONDecoder().decode(AgentJSONValue.self, from: Data(snippets.claudeDesktop.utf8))
        XCTAssertEqual(desktop["mcpServers"]?["storage-cleaner"]?["command"], .string(odd))
        XCTAssertTrue(snippets.claudeCode.contains(#"'/Volumes/It'\''s "Here"\/App.app/Contents/Helpers/storage-cleaner-agent'"#),
                      snippets.claudeCode)
        XCTAssertTrue(snippets.codex.contains(#"command = "/Volumes/It's \"Here\"\\/App.app/Contents/Helpers/storage-cleaner-agent""#),
                      snippets.codex)
    }
}
