import Foundation

/// Admission uses monotonic time. Reading cached availability cannot consume an
/// attempt or move the deadline. Only a failed transport advances the backoff.
struct HelperReconnectBackoff {
    private(set) var failureCount = 0
    private(set) var nextAttemptAt: TimeInterval?

    func permitsAttempt(at time: TimeInterval) -> Bool {
        time.isFinite && (nextAttemptAt.map { time >= $0 } ?? true)
    }

    func remainingDelay(at time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 300 }
        return max(0, (nextAttemptAt ?? time) - time)
    }

    mutating func recordFailure(at time: TimeInterval, jitter: Double) {
        failureCount = min(failureCount + 1, 10)
        let base = min(300, pow(2, Double(failureCount - 1)))
        let unit = jitter.isFinite ? min(1, max(0, jitter)) : 0.5
        let delay = min(300, base * (0.8 + 0.4 * unit))
        nextAttemptAt = (time.isFinite ? time : 0) + delay
    }

    mutating func reset() {
        failureCount = 0
        nextAttemptAt = nil
    }
}

/// Independent of automatic backoff: success, transport failure and a manual
/// reset cannot erase the previous user attempt. Monotonic rollback fails closed.
struct HelperManualReconnectCooldown {
    static let minimumInterval: TimeInterval = 10
    private(set) var nextAttemptAt: TimeInterval?

    func remainingSeconds(at time: TimeInterval) -> Int {
        guard time.isFinite else { return 10 }
        return Int(min(10, max(0, ceil((nextAttemptAt ?? time) - time))))
    }

    mutating func admit(at time: TimeInterval) -> Bool {
        guard time.isFinite, nextAttemptAt.map({ time >= $0 }) ?? true else { return false }
        nextAttemptAt = time + Self.minimumInterval
        return true
    }
}
