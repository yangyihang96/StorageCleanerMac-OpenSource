import Foundation
import IOKit

struct GPUPerformanceSnapshot: Equatable, Sendable {
    let usagePercent: Double?
    let memoryUsedBytes: Int64?
}

enum GPUPerformanceService {
    static func currentUsagePercent() -> Double? {
        currentSnapshot()?.usagePercent
    }

    static func currentSnapshot() -> GPUPerformanceSnapshot? {
        for className in ["AGXAccelerator", "IOAccelerator"] {
            if let snapshot = snapshot(fromServicesMatching: className) {
                return snapshot
            }
        }
        return nil
    }

    static func snapshot(fromPerformanceStatistics statistics: [String: Any]) -> GPUPerformanceSnapshot? {
        let usagePercent = usagePercent(fromPerformanceStatistics: statistics)
        let memoryUsedBytes = normalizedByteCount(numericValue(statistics["In use system memory"]))
        guard usagePercent != nil || memoryUsedBytes != nil else { return nil }
        return GPUPerformanceSnapshot(
            usagePercent: usagePercent,
            memoryUsedBytes: memoryUsedBytes
        )
    }

    static func usagePercent(fromPerformanceStatistics statistics: [String: Any]) -> Double? {
        if let deviceUsage = normalizedPercent(numericValue(statistics["Device Utilization %"])) {
            return deviceUsage
        }

        let fallbackValues = [
            "Renderer Utilization %",
            "Tiler Utilization %"
        ].compactMap { key in
            normalizedPercent(numericValue(statistics[key]))
        }

        return fallbackValues.max()
    }

    private static func snapshot(fromServicesMatching className: String) -> GPUPerformanceSnapshot? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let retainedProperty = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            ) else {
                continue
            }

            guard let statistics = retainedProperty.takeRetainedValue() as? NSDictionary else {
                continue
            }

            var values: [String: Any] = [:]
            for (key, value) in statistics {
                guard let key = key as? String else { continue }
                values[key] = value
            }

            if let snapshot = snapshot(fromPerformanceStatistics: values) {
                return snapshot
            }
        }

        return nil
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            return value.doubleValue
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as Int64:
            return Double(value)
        case let value as UInt64:
            return Double(value)
        default:
            return nil
        }
    }

    private static func normalizedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    private static func normalizedByteCount(_ value: Double?) -> Int64? {
        guard let value, value.isFinite, value >= 0, value <= Double(Int64.max) else { return nil }
        return Int64(value.rounded())
    }
}
