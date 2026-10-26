import Darwin
import Foundation

public enum FileOperationHelperIdlePolicy {
    public static func mayExit(connectionCount: Int, pendingRequests: Int,
                               hasPendingApproval: Bool, updateIsBusy: Bool) -> Bool {
        connectionCount == 0 && pendingRequests == 0 && !hasPendingApproval && !updateIsBusy
    }
}

/// D195: admission, request accounting and the final exit decision share one
/// lock. The process exits while holding it, so admission cannot race the exit.
/// Injectable clocks/exit keep tests away from launchd and the real process.
public final class FileOperationHelperLifecycle: @unchecked Sendable {
    public struct Admission: Sendable {
        public let id: UUID
        public let requirement: String
    }
    public enum Approval: Hashable, Sendable { case move, systemCache }
    private struct ApprovalKey: Hashable { let connection: UUID; let kind: Approval }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let signer: @Sendable () -> String?
    private let updateIsBusy: @Sendable () -> Bool
    private let exitProcess: @Sendable (Int32) -> Void
    private let uptime: @Sendable () -> TimeInterval
    private let date: @Sendable () -> Date
    private var connections = Set<UUID>()
    private var pendingRequests = 0
    private var approvals: [ApprovalKey: Date] = [:]
    private var idleSince: TimeInterval?
    private var timer: DispatchWorkItem?
    private var generation = 0
    private var signerUnavailable = false
    private var signatureExitAfter: TimeInterval = 0
    private var acceptsConnections = true
    public static let idleDelay: TimeInterval = 15
    public static let signatureFailureDelay: TimeInterval = 0.5

    public init(queue: DispatchQueue = DispatchQueue(label: "file-operation.lifecycle"),
                signer: @escaping @Sendable () -> String?,
                updateIsBusy: @escaping @Sendable () -> Bool = { false },
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                date: @escaping @Sendable () -> Date = { Date() },
                exitProcess: @escaping @Sendable (Int32) -> Void = { exit($0) }) {
        self.queue = queue; self.signer = signer; self.updateIsBusy = updateIsBusy
        self.uptime = uptime; self.date = date; self.exitProcess = exitProcess
    }

    public func start() { lock.withLock { scheduleLocked() } }

    public func admit(uid: uid_t) -> Admission? {
        lock.withLock {
            guard acceptsConnections, uid >= 501 else { return nil }
            guard let requirement = signer() else {
                // No client data, credentials or signing material in this log.
                NSLog("FileOperationHelper: own signing information unavailable; rejecting connection and scheduling exit.")
                signerUnavailable = true
                signatureExitAfter = uptime() + Self.signatureFailureDelay
                acceptsConnections = false
                scheduleLocked()
                return nil
            }
            let id = UUID()
            connections.insert(id)
            scheduleLocked()
            return Admission(id: id, requirement: requirement)
        }
    }

    public func invalidate(_ id: UUID) {
        lock.withLock {
            connections.remove(id)
            scheduleLocked()
        }
    }

    public func beginRequest() {
        lock.withLock { pendingRequests += 1; scheduleLocked() }
    }

    public func finishRequest() {
        lock.withLock {
            precondition(pendingRequests > 0)
            pendingRequests -= 1
            scheduleLocked()
        }
    }

    /// Approval is recorded before the prepare reply and cleared before the
    /// commit reply. An abandoned connection's approval still expires normally.
    public func setApproval(until: Date?, connection: UUID, kind: Approval) {
        lock.withLock {
            approvals[ApprovalKey(connection: connection, kind: kind)] = until
            scheduleLocked()
        }
    }

    /// Also used by deterministic tests after advancing their injected clock.
    public func checkForExit() { lock.withLock { evaluateLocked() } }

    private func isIdleLocked() -> Bool {
        approvals = approvals.filter { $0.value > date() }
        return FileOperationHelperIdlePolicy.mayExit(connectionCount: connections.count,
            pendingRequests: pendingRequests, hasPendingApproval: !approvals.isEmpty, updateIsBusy: updateIsBusy())
    }

    private func evaluateLocked() {
        guard timer != nil else { return }
        if signerUnavailable {
            // Never interrupt a mutation or an already granted commit window.
            _ = isIdleLocked()
            if uptime() >= signatureExitAfter && pendingRequests == 0 && approvals.isEmpty && !updateIsBusy() {
                timer = nil
                exitProcess(EXIT_SUCCESS)
                return
            }
        } else if isIdleLocked(), let idleSince, uptime() - idleSince >= Self.idleDelay {
            acceptsConnections = false
            timer = nil
            exitProcess(EXIT_SUCCESS)
            return
        }
        scheduleLocked()
    }

    private func scheduleLocked() {
        timer?.cancel()
        generation += 1
        let currentGeneration = generation
        let idle = isIdleLocked()
        if !idle { idleSince = nil }
        else if idleSince == nil { idleSince = uptime() }
        let delay: TimeInterval
        if signerUnavailable { delay = Self.signatureFailureDelay }
        else if let idleSince { delay = max(0, Self.idleDelay - (uptime() - idleSince)) }
        else {
            // Expiring approvals need a wake even if the client has left.
            delay = max(0.01, min(Self.idleDelay, approvals.values.map { $0.timeIntervalSince(date()) }.min() ?? Self.idleDelay))
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.generation == currentGeneration else { return }
                self.evaluateLocked()
            }
        }
        timer = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
