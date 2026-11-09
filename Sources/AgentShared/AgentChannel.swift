import Foundation

/// Messages between the bridge and the App on the private socket (D263). The
/// bridge turns MCP and command-line calls into `AgentChannelRequest`; the App
/// alone decides permission, limits and logging (D261, D264, D268).
public enum AgentChannel {
    public static let version = 1
    /// Tool arguments are small; a longer request line is a protocol error.
    public static let maximumRequestLineBytes = 256 * 1024
    /// A results page holds at most 200 items (D266).
    public static let maximumResponseLineBytes = 4 * 1024 * 1024
    /// More than this many unanswered requests on one connection are refused.
    public static let maximumRequestsInFlight = 8
}

public enum AgentSurface: String, Codable, Sendable {
    case mcp
    case commandLine = "command_line"
}

/// What an MCP client says about itself (`clientInfo`). Display only: the App
/// identifies the client from the process chain and never trusts this (D263).
public struct AgentReportedClient: Codable, Equatable, Sendable {
    public var name: String
    public var version: String?
    public init(name: String, version: String? = nil) { self.name = name; self.version = version }
}

/// The App's first line on a new connection: either ready, or why not.
public struct AgentChannelGreeting: Codable, Equatable, Sendable {
    public var channelVersion: Int
    public var refusal: AgentRefusal?
    /// The client the App identified, for the bridge's stderr log.
    public var client: String?
    public init(channelVersion: Int = AgentChannel.version, refusal: AgentRefusal? = nil, client: String? = nil) {
        self.channelVersion = channelVersion; self.refusal = refusal; self.client = client
    }
}

public struct AgentChannelRequest: Codable, Equatable, Sendable {
    /// Unique per connection; chosen by the bridge.
    public var id: String
    public var tool: String
    public var arguments: [String: AgentJSONValue]
    public var surface: AgentSurface
    public var reportedClient: AgentReportedClient?
    public init(id: String, tool: String, arguments: [String: AgentJSONValue], surface: AgentSurface,
                reportedClient: AgentReportedClient? = nil) {
        self.id = id; self.tool = tool; self.arguments = arguments; self.surface = surface; self.reportedClient = reportedClient
    }
}

public struct AgentChannelResponse: Codable, Equatable, Sendable {
    public var id: String
    /// A tool's structured result: always a JSON object (legacy MCP requires one).
    public var result: AgentJSONValue?
    public var refusal: AgentRefusal?
    public init(id: String, result: AgentJSONValue? = nil, refusal: AgentRefusal? = nil) {
        self.id = id; self.result = result; self.refusal = refusal
    }
    public static func success(_ id: String, _ result: AgentJSONValue) -> Self { .init(id: id, result: result) }
    public static func refused(_ id: String, _ refusal: AgentRefusal) -> Self { .init(id: id, refusal: refusal) }
}

/// A business refusal. MCP reports it inside the tool result with `isError`
/// so the model can read it (tools page, "Tool Execution Errors"); the command
/// line maps it to an exit code.
public struct AgentRefusal: Error, Codable, Equatable, Sendable {
    public var reason: AgentRefusalReason
    public var message: String
    public init(_ reason: AgentRefusalReason, _ message: String? = nil) {
        self.reason = reason; self.message = message ?? reason.defaultMessage
    }
}

public enum AgentRefusalReason: String, CaseIterable, Sendable {
    case interfaceOff = "interface_off"
    case appNotRunning = "app_not_running"
    case appUnverified = "app_unverified"
    case clientUnidentified = "client_unidentified"
    case approvalRequired = "approval_required"
    case clientDenied = "client_denied"
    case insufficientPermission = "insufficient_permission"
    case rateLimited = "rate_limited"
    case notYetAvailable = "not_yet_available"
    case unknownItem = "unknown_item"
    case invalidArguments = "invalid_arguments"
    case busy = "busy"
    case channelVersionMismatch = "channel_version_mismatch"
    case internalError = "internal_error"

    public var defaultMessage: String {
        switch self {
        case .interfaceOff: "存储清理助手的 AI 助手接口已关闭。需要用户在 App 的“设置 › AI 助手”里打开。"
        case .appNotRunning: "存储清理助手没有在运行。"
        case .appUnverified: "无法确认连到的是真正的存储清理助手，已断开。"
        case .clientUnidentified: "无法识别是哪个程序在调用本接口，已拒绝。"
        case .approvalRequired: "本客户端还没有被批准。需要用户在存储清理助手的“设置 › AI 助手”里批准后再试。"
        case .clientDenied: "用户已拒绝本客户端使用 AI 助手接口。"
        case .insufficientPermission: "本客户端只有“只读”权限，不能调用这个工具。"
        case .rateLimited: "请求太频繁，请稍后再试。"
        case .notYetAvailable: "这个工具在本版本里还没有开放。"
        case .unknownItem: "找不到这一项，可能已过期或不在当前结果里。"
        case .invalidArguments: "参数不符合要求。"
        case .busy: "存储清理助手正忙，请稍后再试。"
        case .channelVersionMismatch: "桥接程序与存储清理助手的版本不一致，需要重新打开 App。"
        case .internalError: "存储清理助手内部出错。"
        }
    }
}

extension AgentRefusalReason: Codable {
    /// A reason added by a newer App still decodes, as a refusal.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .internalError
    }
}
