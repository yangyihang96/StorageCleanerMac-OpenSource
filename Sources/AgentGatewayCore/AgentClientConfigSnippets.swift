import AgentShared
import Foundation

/// D265 "复制接入配置": the App gives these three texts with the real path of
/// its bridge. Editing a client's configuration stays with the user.
public struct AgentClientConfigSnippets: Equatable, Sendable {
    /// For `~/Library/Application Support/Claude/claude_desktop_config.json`.
    public let claudeDesktop: String
    /// A command for a terminal.
    public let claudeCode: String
    /// For `~/.codex/config.toml`.
    public let codex: String

    public init(serverName: String, bridgePath: String) {
        let server: AgentJSONValue = ["command": .string(bridgePath), "args": ["mcp"]]
        claudeDesktop = Self.prettyJSON(.object(["mcpServers": .object([serverName: server])]))
        claudeCode = "claude mcp add --scope user \(serverName) -- \(Self.shellQuoted(bridgePath)) mcp"
        codex = """
            [mcp_servers.\(serverName)]
            command = \(Self.tomlQuoted(bridgePath))
            args = ["mcp"]
            """
    }

    private static func prettyJSON(_ value: AgentJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tomlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
