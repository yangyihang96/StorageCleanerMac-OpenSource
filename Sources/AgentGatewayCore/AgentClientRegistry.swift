import Foundation

/// D261: two grants and a refusal. There is no grant that skips the user's
/// confirmation, and Settings offers none (D262).
public enum AgentClientDecision: String, Codable, Sendable {
    case readOnly = "read_only"
    case propose
    case denied
}

public struct AgentClientRecord: Codable, Equatable, Sendable {
    public var identity: AgentClientIdentity
    public var decision: AgentClientDecision
    public var decidedAt: Date
    public var lastUsedAt: Date?
}

/// A client that asked before the user decided; listed in Settings.
public struct AgentPendingClient: Equatable, Sendable {
    public var identity: AgentClientIdentity
    public var firstSeen: Date
    public var lastPrompted: Date
}

public struct AgentClientStorage: Sendable {
    public var load: @Sendable () -> Data?
    public var save: @Sendable (Data) -> Void

    public init(load: @escaping @Sendable () -> Data?, save: @escaping @Sendable (Data) -> Void) {
        self.load = load; self.save = save
    }

    public static func memory(_ initial: Data? = nil) -> AgentClientStorage {
        let box = AgentLockedBox(initial)
        return .init(load: { box.value }, save: { box.value = $0 })
    }
}

/// D263 approvals: bound to the client's signing identity, revocable, and a
/// client that keeps asking is announced at most once every ten minutes.
public final class AgentClientRegistry: @unchecked Sendable {
    public static let promptInterval: TimeInterval = 600
    /// "Last used" is for Settings only; writing it on every call would be waste.
    static let usageWriteInterval: TimeInterval = 60

    private let lock = NSLock()
    private let storage: AgentClientStorage
    private var stored: [String: AgentClientRecord]
    private var waiting: [String: AgentPendingClient] = [:]

    public init(storage: AgentClientStorage) {
        self.storage = storage
        let records = storage.load().flatMap { try? JSONDecoder().decode([AgentClientRecord].self, from: $0) } ?? []
        stored = Dictionary(records.map { ($0.identity.bindingKey, $0) }, uniquingKeysWith: { _, last in last })
    }

    public var records: [AgentClientRecord] { lock.withLock { stored.values.sorted { $0.decidedAt < $1.decidedAt } } }
    public var pending: [AgentPendingClient] { lock.withLock { waiting.values.sorted { $0.firstSeen < $1.firstSeen } } }

    public func decision(for identity: AgentClientIdentity) -> AgentClientDecision? {
        lock.withLock { stored[identity.bindingKey]?.decision }
    }

    /// Records an undecided client; true when the user should be told now.
    public func notePending(_ identity: AgentClientIdentity, at now: Date) -> Bool {
        lock.withLock {
            let key = identity.bindingKey
            guard var entry = waiting[key] else {
                waiting[key] = .init(identity: identity, firstSeen: now, lastPrompted: now)
                return true
            }
            entry.identity = identity
            let due = now.timeIntervalSince(entry.lastPrompted) >= Self.promptInterval
            if due { entry.lastPrompted = now }
            waiting[key] = entry
            return due
        }
    }

    public func decide(_ identity: AgentClientIdentity, _ decision: AgentClientDecision, at now: Date) {
        lock.withLock {
            let key = identity.bindingKey
            stored[key] = .init(identity: identity, decision: decision, decidedAt: now, lastUsedAt: stored[key]?.lastUsedAt)
            waiting[key] = nil
            persist()
        }
    }

    /// Back to undecided: the next call asks the user again.
    public func revoke(bindingKey: String) {
        lock.withLock {
            stored[bindingKey] = nil
            persist()
        }
    }

    public func markUsed(_ identity: AgentClientIdentity, at now: Date) {
        lock.withLock {
            let key = identity.bindingKey
            guard var record = stored[key] else { return }
            if let last = record.lastUsedAt, now.timeIntervalSince(last) < Self.usageWriteInterval { return }
            record.lastUsedAt = now
            record.identity = identity
            stored[key] = record
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stored.values.sorted { $0.decidedAt < $1.decidedAt }) { storage.save(data) }
    }
}

final class AgentLockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
