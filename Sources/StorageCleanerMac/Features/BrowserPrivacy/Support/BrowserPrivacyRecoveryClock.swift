import Darwin
import Foundation

/// A persisted continuous-clock reading is comparable only within one boot.
/// Wall dates remain responsible for the seven-day privacy retention period.
struct BrowserPrivacyRecoveryClockReading: Sendable {
    let seconds: TimeInterval
    let bootSessionIdentifier: String

    static func current() -> BrowserPrivacyRecoveryClockReading? {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: 128)
        var size = bytes.count
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname("kern.bootsessionuuid", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > 1, size <= bytes.count,
              let identifier = String(
                  bytes: bytes.prefix(size).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                  encoding: .utf8
              ), !identifier.isEmpty else { return nil }
        // Matches the continuous counter used by EnergyModelCounterReader;
        // unlike mach_absolute_time, it includes time spent asleep.
        let seconds = Double(mach_continuous_time())
            * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        return BrowserPrivacyRecoveryClockReading(seconds: seconds, bootSessionIdentifier: identifier)
    }
}
