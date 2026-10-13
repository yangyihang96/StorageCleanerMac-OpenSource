import Foundation

/// The sensor batch and power card often request the same battery SMC keys
/// on the same tick. Coalesce those reads without changing the source or
/// replacing its measurement timestamp. Hidden energy integration uses this
/// same read-only source about every 30 seconds (N16-5, D5).
final class MenuBarBatteryElectricalCache: @unchecked Sendable {
    static let shared = MenuBarBatteryElectricalCache {
        MenuBarPresentationTrace.measureSample("battery.smc-registry") {
            NativeBatteryElectricalService.snapshot()
        }
    }
    private let lock = NSLock()
    private let read: @Sendable () -> NativeBatteryElectricalSnapshot?
    private let clock: @Sendable () -> TimeInterval
    private var sampledAt: TimeInterval?
    private var cached: NativeBatteryElectricalSnapshot?

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         read: @escaping @Sendable () -> NativeBatteryElectricalSnapshot?) {
        self.clock = clock
        self.read = read
    }

    func snapshot() -> NativeBatteryElectricalSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if let sampledAt, now >= sampledAt, now - sampledAt < 1 { return cached }
        cached = read()
        sampledAt = clock()
        return cached
    }
}
