import Foundation
import IOKit

struct NativeDiskIOCounters: Equatable, Sendable {
    let date: Date
    let readBytes: UInt64
    let writtenBytes: UInt64
    let readOperations: UInt64
    let writeOperations: UInt64
    let driverCount: Int
}

struct NativeDiskIOPoint: Identifiable, Codable, Equatable, Sendable {
    var id: Date { date }

    let date: Date
    let readBytesPerSecond: Int64
    let writeBytesPerSecond: Int64
    let readOperationsPerSecond: Double
    let writeOperationsPerSecond: Double
    /// Present for new counter samples; absent in legacy point-only history.
    var intervalStart: Date? = nil
}

enum NativeDiskIOMonitorService {
    static func counters(now: Date = Date()) -> NativeDiskIOCounters? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var readBytes: UInt64 = 0
        var writtenBytes: UInt64 = 0
        var readOperations: UInt64 = 0
        var writeOperations: UInt64 = 0
        var driverCount = 0

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let unmanagedStatistics = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            ), let statistics = unmanagedStatistics.takeRetainedValue() as? [String: Any] else {
                continue
            }

            driverCount += 1
            readBytes = adding(value(for: "Bytes (Read)", in: statistics), to: readBytes)
            writtenBytes = adding(value(for: "Bytes (Write)", in: statistics), to: writtenBytes)
            readOperations = adding(value(for: "Operations (Read)", in: statistics), to: readOperations)
            writeOperations = adding(value(for: "Operations (Write)", in: statistics), to: writeOperations)
        }

        guard driverCount > 0 else { return nil }
        return NativeDiskIOCounters(
            date: now,
            readBytes: readBytes,
            writtenBytes: writtenBytes,
            readOperations: readOperations,
            writeOperations: writeOperations,
            driverCount: driverCount
        )
    }

    static func throughput(
        current: NativeDiskIOCounters,
        previous: NativeDiskIOCounters
    ) -> NativeDiskIOPoint? {
        let interval = current.date.timeIntervalSince(previous.date)
        guard interval > 0.2,
              !MenuBarSamplingGaps.crosses(MenuBarSamplingGaps.shared.intervals(),
                  from: previous.date, to: current.date),
              current.driverCount == previous.driverCount,
              current.readBytes >= previous.readBytes,
              current.writtenBytes >= previous.writtenBytes,
              current.readOperations >= previous.readOperations,
              current.writeOperations >= previous.writeOperations else {
            return nil
        }

        return NativeDiskIOPoint(
            date: current.date,
            readBytesPerSecond: boundedRate(delta: current.readBytes - previous.readBytes, interval: interval),
            writeBytesPerSecond: boundedRate(delta: current.writtenBytes - previous.writtenBytes, interval: interval),
            readOperationsPerSecond: Double(current.readOperations - previous.readOperations) / interval,
            writeOperationsPerSecond: Double(current.writeOperations - previous.writeOperations) / interval,
            intervalStart: interval <= 90 ? previous.date : nil
        )
    }

    private static func value(for key: String, in statistics: [String: Any]) -> UInt64 {
        if let value = statistics[key] as? UInt64 {
            return value
        }
        if let value = statistics[key] as? Int, value >= 0 {
            return UInt64(value)
        }
        return (statistics[key] as? NSNumber)?.uint64Value ?? 0
    }

    private static func adding(_ value: UInt64, to total: UInt64) -> UInt64 {
        let (result, overflow) = total.addingReportingOverflow(value)
        return overflow ? UInt64.max : result
    }

    private static func boundedRate(delta: UInt64, interval: TimeInterval) -> Int64 {
        let rate = Double(delta) / interval
        guard rate.isFinite, rate > 0 else { return 0 }
        return Int64(min(rate, Double(Int64.max)).rounded())
    }
}
