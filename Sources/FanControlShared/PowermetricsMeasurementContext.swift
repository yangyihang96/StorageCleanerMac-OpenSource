import CoreFoundation
import Foundation

/// Local-only execution evidence. Nothing here is accepted in the XPC request.
/// Both processes use mach_continuous_time, not a process-relative origin.
public struct PowermetricsMeasurementContext: Sendable {
    public struct Anchor: Sendable {
        public let beforeMonotonicNs: UInt64
        public let wallTime: Date
        public let afterMonotonicNs: UInt64

        public init(beforeMonotonicNs: UInt64, wallTime: Date, afterMonotonicNs: UInt64) {
            self.beforeMonotonicNs = beforeMonotonicNs
            self.wallTime = wallTime
            self.afterMonotonicNs = afterMonotonicNs
        }

        public static func capture() -> Self {
            let before = PowermetricsMonotonicClock.nanoseconds
            let wall = Date()
            return Self(beforeMonotonicNs: before, wallTime: wall,
                        afterMonotonicNs: PowermetricsMonotonicClock.nanoseconds)
        }

        fileprivate var midpoint: UInt64? {
            guard afterMonotonicNs >= beforeMonotonicNs,
                  afterMonotonicNs - beforeMonotonicNs <= 1_000_000,
                  wallTime.timeIntervalSinceReferenceDate.isFinite else { return nil }
            return beforeMonotonicNs + (afterMonotonicNs - beforeMonotonicNs) / 2
        }

        fileprivate func project(_ date: Date) -> UInt64? {
            guard let midpoint else { return nil }
            let offset = date.timeIntervalSince(wallTime) * 1e9
            guard offset.isFinite, abs(offset) <= PowermetricsExecutionPolicy.timeoutSeconds * 1e9 else { return nil }
            let distance = UInt64(abs(offset).rounded())
            if offset >= 0 {
                guard midpoint <= UInt64.max - distance else { return nil }
                return midpoint + distance
            }
            guard midpoint >= distance else { return nil }
            return midpoint - distance
        }
    }

    public let launched: Anchor
    public let finished: Anchor
    public let helperBootID: String

    public init(launched: Anchor, finished: Anchor, helperBootID: String) {
        self.launched = launched; self.finished = finished; self.helperBootID = helperBootID
    }

    /// Supported native shape: a delta sample, integral elapsed_ns, and a plist
    /// timestamp at a measurement boundary (Date or fractional Unix seconds).
    /// Numeric units/epoch must agree with both local wall/monotonic anchors;
    /// arbitrary integers, uptime epochs and nanosecond epochs cannot pass.
    /// Start vs end is accepted only
    /// when exactly one orientation fits wholly inside the child lifecycle.
    /// Strings, whole-second output, ambiguous orientation,
    /// wall-clock steps and duration-only fixtures cannot prove an interval.
    /// This shape is a contract fixture until the host's native output is checked.
    func timing(root: [String: Any]) -> PowermetricsSample.Timing {
        var result = PowermetricsSample.Timing(sampleID: UUID().uuidString, helperBootID: helperBootID,
            clockDomain: PowermetricsMonotonicClock.clockDomain, timestampQuality: .requestBracketOnly)
        result.helperProcessStartMonotonicNs = launched.beforeMonotonicNs
        result.helperProcessEndMonotonicNs = finished.afterMonotonicNs
        guard UUID(uuidString: helperBootID) != nil,
              let first = launched.midpoint, let last = finished.midpoint, last > first,
              Double(last - first) / 1e9 <= PowermetricsExecutionPolicy.timeoutSeconds,
              let delta = root["is_delta"] as? NSNumber,
              CFGetTypeID(delta) == CFBooleanGetTypeID(), delta.boolValue,
              let elapsed = root["elapsed_ns"] as? NSNumber,
              CFGetTypeID(elapsed) != CFBooleanGetTypeID(), elapsed.doubleValue.isFinite,
              (50_000_000...5_000_000_000).contains(elapsed.doubleValue),
              elapsed.doubleValue.rounded() == elapsed.doubleValue,
              let timestamp = Self.nativeTimestamp(root["timestamp"]) else { return result }
        let wallSeconds = timestamp.timeIntervalSinceReferenceDate
        guard wallSeconds.isFinite, wallSeconds != wallSeconds.rounded(),
              let a = launched.project(timestamp), let b = finished.project(timestamp),
              max(a, b) - min(a, b) <= 1_000_000 else { return result }
        let boundary = min(a, b) + (max(a, b) - min(a, b)) / 2
        let duration = UInt64(elapsed.doubleValue)
        var candidates: [(UInt64, UInt64, String)] = []
        // Bounds validate native evidence; they never supply a missing timestamp.
        if boundary >= duration {
            let start = boundary - duration
            if start >= launched.afterMonotonicNs, boundary <= finished.beforeMonotonicNs {
                candidates.append((start, boundary, "nativeTimestampEnd+elapsed_ns"))
            }
        }
        if boundary <= UInt64.max - duration {
            let end = boundary + duration
            if boundary >= launched.afterMonotonicNs, end <= finished.beforeMonotonicNs {
                candidates.append((boundary, end, "nativeTimestampStart+elapsed_ns"))
            }
        }
        guard candidates.count == 1, let interval = candidates.first else { return result }
        var measured = PowermetricsSample.Timing(sampleID: result.sampleID, helperBootID: helperBootID,
            clockDomain: result.clockDomain, measurementStartMonotonicNs: interval.0,
            measurementEndMonotonicNs: interval.1, timestampQuality: .helperMeasured)
        measured.helperProcessStartMonotonicNs = result.helperProcessStartMonotonicNs
        measured.helperProcessEndMonotonicNs = result.helperProcessEndMonotonicNs
        measured.timestampSource = interval.2
        return measured
    }

    private static func nativeTimestamp(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
}
