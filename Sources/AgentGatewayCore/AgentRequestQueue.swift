import AgentShared
import Foundation

public enum AgentRequestState: String, Codable, Sendable {
    case waitingForUser = "waiting_for_user"
    /// The user has it open on the confirmation page.
    case confirming
    case completed
    case failed
    case rejected
    case cancelled
    case expired
    /// The switch was turned off or the App quit (D265, D267).
    case voided
}

/// What a `propose_*` tool hands over: already checked and summarised by the
/// App from its own results. The reason is the AI's and is shown as unverified.
public struct AgentProposal: Equatable, Sendable {
    public let tool: String
    public let module: String
    public let summary: String
    public let reason: String?

    public init(tool: String, module: String, summary: String, reason: String?) {
        self.tool = tool; self.module = module; self.summary = summary; self.reason = reason
    }
}

public struct AgentQueuedRequest: Equatable, Sendable {
    public let id: String
    public let clientKey: String
    public let clientName: String
    public let tool: String
    public let module: String
    public let summary: String
    public let reason: String?
    public let createdAt: Date
    public let expiresAt: Date
    public internal(set) var state: AgentRequestState
    /// The receipt's summary once the App has acted (or why it could not).
    public internal(set) var outcome: String?

    /// What the client that made the request may read back. Never the client
    /// key, which only the App's records need.
    public var json: AgentJSONValue {
        ["id": .string(id), "state": .string(state.rawValue), "tool": .string(tool), "module": .string(module),
         "summary": .string(summary), "reason": reason.map(AgentJSONValue.string) ?? .null,
         "created_at": .string(createdAt.formatted(.iso8601)), "expires_at": .string(expiresAt.formatted(.iso8601)),
         "outcome": outcome.map(AgentJSONValue.string) ?? .null]
    }

    var isActive: Bool { state == .waitingForUser || state == .confirming }
}

/// D262: a proposal only ever becomes an entry here. The queue executes
/// nothing; the App's confirmation page does, after the user has acted. One
/// request per module at a time, three per client, fifteen minutes to be
/// opened. Kept in memory only: quitting voids everything (D267).
public final class AgentRequestQueue: @unchecked Sendable {
    public static let lifetime: TimeInterval = 15 * 60
    public static let perClientLimit = 3

    private let lock = NSLock()
    private var stored: [AgentQueuedRequest] = []
    private let maximumFinished: Int

    public init(maximumFinished: Int = 50) { self.maximumFinished = maximumFinished }

    public func add(_ proposal: AgentProposal, from client: AgentClientIdentity, at now: Date) throws(AgentRefusal) -> AgentQueuedRequest {
        try locked(now) { () throws(AgentRefusal) in
            guard !stored.contains(where: { $0.isActive && $0.module == proposal.module }) else {
                throw AgentRefusal(.busy, "这个模块已有一个请求在等用户处理。")
            }
            let key = client.bindingKey
            guard stored.count(where: { $0.isActive && $0.clientKey == key }) < Self.perClientLimit else {
                throw AgentRefusal(.busy, "本客户端已有 \(Self.perClientLimit) 个请求在等用户处理。")
            }
            let request = AgentQueuedRequest(id: "Q-" + UUID().uuidString.prefix(8), clientKey: key, clientName: client.displayName,
                                             tool: proposal.tool, module: proposal.module, summary: proposal.summary,
                                             reason: proposal.reason, createdAt: now, expiresAt: now.addingTimeInterval(Self.lifetime),
                                             state: .waitingForUser, outcome: nil)
            stored.append(request)
            return request
        }
    }

    // MARK: What a client may see

    /// Another client's number reads the same as a number that never existed.
    public func request(_ id: String, for client: AgentClientIdentity, at now: Date) throws(AgentRefusal) -> AgentQueuedRequest {
        try locked(now) { () throws(AgentRefusal) in
            guard let request = stored.first(where: { $0.id == id && $0.clientKey == client.bindingKey }) else {
                throw AgentRefusal(.unknownItem)
            }
            return request
        }
    }

    public func requests(for client: AgentClientIdentity, at now: Date) -> [AgentQueuedRequest] {
        lock.withLock {
            refresh(now)
            return stored.filter { $0.clientKey == client.bindingKey }
        }
    }

    /// Only while it is still waiting: once the user has it open it is theirs.
    public func cancel(_ id: String, by client: AgentClientIdentity, at now: Date) throws(AgentRefusal) -> AgentQueuedRequest {
        try update(id, from: [.waitingForUser], at: now, client: client, refusal: "这个请求已经不在等待中，无法撤回。") { $0.state = .cancelled }
    }

    // MARK: What the App does on the user's behalf

    public func waitingCount(at now: Date) -> Int {
        lock.withLock {
            refresh(now)
            return stored.count(where: { $0.state == .waitingForUser })
        }
    }

    /// For Settings: everything still remembered, oldest first.
    public func allRequests(at now: Date) -> [AgentQueuedRequest] {
        lock.withLock {
            refresh(now)
            return stored
        }
    }

    public func beginConfirmation(_ id: String, at now: Date) throws(AgentRefusal) -> AgentQueuedRequest {
        try update(id, from: [.waitingForUser], at: now, refusal: "这个请求已经过期或被处理过了。") { $0.state = .confirming }
    }

    public func reject(_ id: String, at now: Date) throws(AgentRefusal) -> AgentQueuedRequest {
        try update(id, from: [.waitingForUser, .confirming], at: now, refusal: "这个请求已经过期或被处理过了。") { $0.state = .rejected }
    }

    /// Only after `beginConfirmation`: nothing reaches `completed` otherwise.
    public func finish(_ id: String, outcome: String, failed: Bool, at now: Date) throws(AgentRefusal) -> AgentQueuedRequest {
        try update(id, from: [.confirming], at: now, refusal: "这个请求不在确认中。") {
            $0.state = failed ? .failed : .completed
            $0.outcome = outcome
        }
    }

    /// "全部拒绝" in Settings. What the user has open stays theirs.
    @discardableResult
    public func rejectAll(at now: Date) -> Int {
        lock.withLock {
            refresh(now)
            var count = 0
            for index in stored.indices where stored[index].state == .waitingForUser {
                stored[index].state = .rejected
                count += 1
            }
            return count
        }
    }

    /// The switch went off or the App is quitting: nothing stays open.
    public func voidAll(at now: Date) {
        lock.withLock {
            refresh(now)
            for index in stored.indices where stored[index].isActive { stored[index].state = .voided }
        }
    }

    // MARK: Internals

    private func locked<T>(_ now: Date, _ body: () throws(AgentRefusal) -> T) throws(AgentRefusal) -> T {
        lock.lock()
        defer { lock.unlock() }
        refresh(now)
        return try body()
    }

    private func update(_ id: String, from states: [AgentRequestState], at now: Date, client: AgentClientIdentity? = nil, refusal message: String,
                        _ change: (inout AgentQueuedRequest) -> Void) throws(AgentRefusal) -> AgentQueuedRequest {
        try locked(now) { () throws(AgentRefusal) in
            guard let index = stored.firstIndex(where: { $0.id == id && (client == nil || $0.clientKey == client?.bindingKey) }) else {
                throw AgentRefusal(.unknownItem)
            }
            guard states.contains(stored[index].state) else { throw AgentRefusal(.unknownItem, message) }
            change(&stored[index])
            return stored[index]
        }
    }

    /// Expires what waited too long and forgets the oldest finished requests.
    /// A request being confirmed no longer expires: the user is on it.
    private func refresh(_ now: Date) {
        for index in stored.indices where stored[index].state == .waitingForUser && now >= stored[index].expiresAt {
            stored[index].state = .expired
        }
        var finished = stored.count(where: { !$0.isActive })
        guard finished > maximumFinished else { return }
        stored.removeAll { request in
            guard finished > maximumFinished, !request.isActive else { return false }
            finished -= 1
            return true
        }
    }
}
