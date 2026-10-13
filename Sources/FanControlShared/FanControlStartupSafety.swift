import Foundation

/// Startup may run once. The fault state cannot become ready in this process;
/// only a new helper launch with verified recovery can resume hardware control.
public final class FanControlStartupSafety: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case awaitingRecovery
        case recovering
        case ready
        case recoveryFailed
    }

    public static let failureMessageChinese =
        "启动时未能恢复风扇自动控制，已禁用风扇写入和曲线控制。请检查风扇状态；如需重新启用，请移除并重新授权系统助手。"
    public static let failureMessageEnglish =
        "Automatic fan control could not be restored at startup. Fan writes and curve control are disabled. Check the fan state. To enable control again, remove and authorize the helper after resolving the fault."

    private let lock = NSLock()
    private var value = State.awaitingRecovery
    public var state: State { lock.withLock { value } }
    public var isReady: Bool { state == .ready }

    public init() {}

    @discardableResult
    public func start(recoverFans: () -> Bool, prepareMacMiniForTermination: () -> Void) -> State {
        let mayStart = lock.withLock {
            guard value == .awaitingRecovery else { return false }
            value = .recovering
            return true
        }
        guard mayStart else { return state }
        if recoverFans() {
            complete(.ready)
        } else {
            // Keep request dispatch blocked while sleep restoration is running.
            // Publish the failure only AFTER this callback finishes.
            prepareMacMiniForTermination()
            complete(.recoveryFailed)
        }
        return state
    }

    @discardableResult
    public func startNormalWork(_ start: () -> Void) -> Bool {
        guard isReady else { return false }
        start()
        return true
    }

    public func dispatch<Response>(execute: () -> Response, reject: (State) -> Response) -> Response {
        let observed = state
        guard observed == .ready else { return reject(observed) }
        return execute()
    }

    /// One whitelist shared by helper routing and app fault-mode dispatch.
    public static func permitsSleepRecovery(operation: String, mode: MacMiniMode?, hasEmptyPayload: Bool) -> Bool {
        guard hasEmptyPayload else { return false }
        switch operation {
        case "readMacMiniMode": return mode == nil
        case "setMacMiniMode": return mode == .off
        default: return false
        }
    }

    /// Separate, non-fan executor. Only after startup termination completes may
    /// a failed process read sleep state or turn the persistent policy OFF.
    public func dispatchSleepRecovery<Response>(recover: () -> Response, reject: (State) -> Response) -> Response {
        let observed = state
        guard observed == .ready || observed == .recoveryFailed else { return reject(observed) }
        return recover()
    }

    /// A failed helper has already attempted safe Mac mini termination and must
    /// not resurrect its enabled policy or stay resident merely to poll it.
    public func requiresResidentHelper(macMiniRequested: Bool) -> Bool {
        state == .recoveryFailed ? false : macMiniRequested
    }

    private func complete(_ next: State) { lock.withLock { value = next } }
}
