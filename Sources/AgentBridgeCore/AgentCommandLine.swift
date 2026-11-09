import AgentShared
import Foundation

/// Plan §4.5: `storage-cleaner-agent <command>` for terminals and agents that
/// only run commands. Same requests, permissions and records as MCP; every
/// call prints one JSON object, and the exit status says what happened.
public enum AgentCommandLine {
    public enum Parsed: Equatable, Sendable {
        case mcp
        case tools
        case help
        case version
        case call(tool: String, arguments: [String: AgentJSONValue])
    }

    public struct UsageError: Error, Equatable, Sendable {
        public let message: String
        init(_ message: String) { self.message = message }
    }

    public static let usage = """
        用法：storage-cleaner-agent <命令> [参数]

          mcp                                  作为 MCP 服务器运行（stdio）
          status | live | health               概况 | 实时状态 | 电脑健康
          results <模块> [--cursor C] [--limit N]
                                               模块结果：junk、startup_items、installed_apps、app_updates 等
          records [--cursor C] [--limit N]     操作记录
          record <编号>                         一条操作记录
          hardware [--cursor C] [--limit N]    硬件操作记录
          history <scans|capacity> [--cursor C] [--limit N]
          capabilities                         能力说明与本客户端的权限
          requests | request <编号> | cancel-request <编号>
          scan <模块>                           开始只读扫描
          call <工具> ['{"参数":"值"}']           按工具名调用（见 tools）
          tools                                列出全部工具（不连接 App）

        输出都是一行 JSON。退出码：0 成功；1 出错；2 用法有误；3 需要在 App 里批准本客户端；
        4 接口已关闭；5 App 没在运行；6 请求被拒绝。
        """

    private struct Command {
        let tool: String
        var positional: String? = nil
        var paging = false
    }

    private static let commands: [String: Command] = [
        "status": .init(tool: "get_overview"),
        "live": .init(tool: "get_live_status"),
        "health": .init(tool: "get_health"),
        "results": .init(tool: "list_results", positional: "module", paging: true),
        "records": .init(tool: "list_operation_records", paging: true),
        "record": .init(tool: "get_operation_record", positional: "record_id"),
        "hardware": .init(tool: "list_hardware_operations", paging: true),
        "history": .init(tool: "get_history", positional: "kind", paging: true),
        "capabilities": .init(tool: "describe_capabilities"),
        "requests": .init(tool: "list_requests"),
        "request": .init(tool: "get_request", positional: "request_id"),
        "cancel-request": .init(tool: "cancel_request", positional: "request_id"),
        "scan": .init(tool: "start_scan", positional: "module")
    ]

    /// `arguments` excludes the program name. `--json` is accepted anywhere:
    /// the output is JSON either way.
    public static func parse(_ arguments: [String]) throws(UsageError) -> Parsed {
        var words = arguments.filter { $0 != "--json" }
        guard !words.isEmpty else { return .help }
        let command = words.removeFirst()
        switch command {
        case "help", "-h", "--help":
            return .help
        case "version", "--version":
            return .version
        case "mcp", "tools":
            guard words.isEmpty else { throw UsageError("\(command) 不接受参数：\(words.joined(separator: " "))") }
            return command == "mcp" ? .mcp : .tools
        case "call":
            guard let tool = words.first else { throw UsageError("call 需要工具名，见 storage-cleaner-agent tools") }
            guard words.count <= 2 else { throw UsageError("call 只接受工具名和一个 JSON 对象") }
            var arguments: [String: AgentJSONValue] = [:]
            if words.count == 2 {
                guard let object = (try? JSONDecoder().decode(AgentJSONValue.self, from: Data(words[1].utf8)))?.objectValue else {
                    throw UsageError("call 的参数必须是一个 JSON 对象")
                }
                arguments = object
            }
            return try checked(tool, arguments)
        default:
            guard let spec = commands[command] else { throw UsageError("未知命令：\(command)。用 --help 查看用法") }
            var arguments: [String: AgentJSONValue] = [:]
            if let name = spec.positional {
                guard let value = words.first, !value.hasPrefix("--") else { throw UsageError("\(command) 需要参数 <\(name)>") }
                arguments[name] = .string(value)
                words.removeFirst()
            }
            while !words.isEmpty {
                let option = words.removeFirst()
                guard spec.paging, option == "--cursor" || option == "--limit" else {
                    throw UsageError("\(command) 不认识：\(option)")
                }
                guard !words.isEmpty else { throw UsageError("\(option) 需要一个值") }
                let value = words.removeFirst()
                if option == "--limit" {
                    guard let number = Int64(value) else { throw UsageError("--limit 需要整数") }
                    arguments["limit"] = .integer(number)
                } else {
                    arguments["cursor"] = .string(value)
                }
            }
            return try checked(spec.tool, arguments)
        }
    }

    private static func checked(_ name: String, _ arguments: [String: AgentJSONValue]) throws(UsageError) -> Parsed {
        guard let tool = AgentToolCatalog.tool(named: name) else { throw UsageError("没有这个工具：\(name)") }
        if let violation = AgentSchemaValidator.violation(of: .object(arguments), against: tool.inputSchema) {
            throw UsageError("\(name) 的参数不对：\(violation.description)")
        }
        return .call(tool: name, arguments: arguments)
    }

    public static func run(tool: String, arguments: [String: AgentJSONValue],
                           transport: any AgentAppTransport) async -> (output: String, status: Int32) {
        let request = AgentChannelRequest(id: "c1", tool: tool, arguments: arguments, surface: .commandLine)
        switch await transport.call(request) {
        case .result(let value):
            return (line(["ok": true, "tool": .string(tool), "result": value]), 0)
        case .refused(let refusal):
            return (line(["ok": false, "tool": .string(tool), "reason": .string(refusal.reason.rawValue),
                          "message": .string(refusal.message)]), exitStatus(for: refusal.reason))
        }
    }

    public static func exitStatus(for reason: AgentRefusalReason) -> Int32 {
        switch reason {
        case .approvalRequired: 3
        case .interfaceOff: 4
        case .appNotRunning: 5
        case .internalError, .appUnverified, .channelVersionMismatch: 1
        case .clientUnidentified, .clientDenied, .insufficientPermission, .rateLimited, .notYetAvailable, .unknownItem,
             .invalidArguments, .busy: 6
        }
    }

    /// The catalog as the bridge knows it; no App needed.
    public static func toolListing() -> String {
        line(["tools": .array(AgentToolCatalog.tools.map { tool in
            ["name": .string(tool.name), "title": .string(tool.title), "description": .string(tool.summary),
             "level": .string(tool.level.rawValue), "available": .bool(tool.availability == .now)]
        })])
    }

    private static func line(_ value: AgentJSONValue) -> String {
        (try? AgentLineCodec.encodeLine(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{\"ok\":false}\n"
    }
}
