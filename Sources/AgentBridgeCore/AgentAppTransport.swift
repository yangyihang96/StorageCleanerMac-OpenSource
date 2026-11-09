import AgentShared
import Foundation

public enum AgentCallResult: Equatable, Sendable {
    case result(AgentJSONValue)
    case refused(AgentRefusal)
}

/// How the bridge reaches the App. In the product this is the private socket
/// (`AgentSocketTransport`); MCP and the command line share it (plan §4.5).
public protocol AgentAppTransport: Sendable {
    func call(_ request: AgentChannelRequest) async -> AgentCallResult
}

/// What the bridge says about itself: taken from the App bundle it lives in.
public struct AgentServerIdentity: Equatable, Sendable {
    public var name: String
    public var title: String
    public var version: String

    public init(name: String, title: String, version: String) {
        self.name = name; self.title = title; self.version = version
    }

    var json: AgentJSONValue { ["name": .string(name), "title": .string(title), "version": .string(version)] }
}
