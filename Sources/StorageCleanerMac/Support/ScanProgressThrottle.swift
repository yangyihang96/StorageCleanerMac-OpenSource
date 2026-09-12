import Foundation

/// Keeps high-frequency scanner callbacks off the UI without changing the
/// scanner's work or its final result. Phase changes remain immediate.
final class ScanProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDeliveredPhase: String?
    private var lastDeliveredAt = DispatchTime(uptimeNanoseconds: 0)
    private let minimumIntervalNanoseconds: UInt64

    init(minimumInterval: TimeInterval = 0.25) {
        minimumIntervalNanoseconds = UInt64(max(0, minimumInterval) * 1_000_000_000)
    }

    func shouldDeliver(phase: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now()
        if let phase, phase != lastDeliveredPhase {
            lastDeliveredPhase = phase
            lastDeliveredAt = now
            return true
        }
        guard now.uptimeNanoseconds &- lastDeliveredAt.uptimeNanoseconds
                >= minimumIntervalNanoseconds else {
            return false
        }
        lastDeliveredAt = now
        return true
    }
}
