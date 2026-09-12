import CoreFoundation
import Darwin
import Foundation

enum AppleSiliconTemperatureService {
    struct Reading: Equatable {
        let name: String
        let value: Double
    }

    private static let temperatureUsagePage: Int32 = 0xff00
    private static let temperatureUsage: Int32 = 0x0005
    private static let temperatureEventType: Int32 = 15
    private static let clientStore = TemperatureClientStore()

    static func currentChipTemperatureCelsius() -> Double? {
        chipTemperatureCelsius(from: currentTemperatureReadings())
    }

    static func chipTemperatureCelsius(from readings: [Reading]) -> Double? {
        let validReadings = readings.filter { reading in
            isReasonableTemperature(reading.value) && !isPeripheralTemperature(reading.name)
        }
        let candidateGroups = [
            validReadings.filter { isSoCMonitorTemperature($0.name) },
            validReadings.filter { isDieTemperature($0.name) },
            validReadings.filter { isClusterMonitorTemperature($0.name) }
        ]

        for group in candidateGroups where !group.isEmpty {
            return group.map(\.value).max()
        }
        return nil
    }

    static func currentTemperatureReadings() -> [Reading] {
        clientStore.readings()
    }

    static func regionalTemperatures(from readings: [Reading]) -> [SystemTemperatureReading] {
        var hottestByZone: [SystemTemperatureZone: Double] = [:]
        for reading in readings where isReasonableTemperature(reading.value) {
            guard let zone = temperatureZone(for: reading.name) else { continue }
            hottestByZone[zone] = max(hottestByZone[zone] ?? reading.value, reading.value)
        }

        return SystemTemperatureZone.allCases.compactMap { zone in
            hottestByZone[zone].map { SystemTemperatureReading(zone: zone, celsius: $0) }
        }
    }

    static func normalizedTemperature(rawValue: Double, sensorName _: String) -> Double? {
        if isReasonableTemperature(rawValue) { return rawValue }
        let fixedPointCelsius = rawValue / 256
        return isReasonableTemperature(fixedPointCelsius) ? fixedPointCelsius : nil
    }

    /// Creating the private IOHID event client can fail transiently while the
    /// system is resuming or rebuilding its HID service graph. A static
    /// optional would make that first failure permanent for the whole launch,
    /// so retry at a deliberately slow cadence without reconnecting on every
    /// one-second menu-bar refresh.
    private final class TemperatureClientStore: @unchecked Sendable {
        private static let retryInterval: TimeInterval = 30
        private let lock = NSLock()
        private var client: TemperatureClient?
        private var nextRetryAt = Date.distantPast
        private var consecutiveEmptyReadings = 0

        func readings(now: Date = Date()) -> [Reading] {
            guard let currentClient = currentClient(now: now) else { return [] }
            guard let readings = currentClient.readings() else {
                invalidate(currentClient, now: now)
                return []
            }

            recordReadResult(readings, from: currentClient, now: now)
            return readings
        }

        private func currentClient(now: Date) -> TemperatureClient? {
            lock.lock()
            defer { lock.unlock() }

            if let client {
                return client
            }
            guard now >= nextRetryAt else { return nil }

            nextRetryAt = now.addingTimeInterval(Self.retryInterval)
            client = TemperatureClient()
            return client
        }

        private func recordReadResult(
            _ readings: [Reading],
            from currentClient: TemperatureClient,
            now: Date
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard client === currentClient else { return }

            if readings.isEmpty {
                consecutiveEmptyReadings += 1
                if consecutiveEmptyReadings >= 3 {
                    client = nil
                    consecutiveEmptyReadings = 0
                    nextRetryAt = now.addingTimeInterval(Self.retryInterval)
                }
            } else {
                consecutiveEmptyReadings = 0
            }
        }

        private func invalidate(_ currentClient: TemperatureClient, now: Date) {
            lock.lock()
            defer { lock.unlock() }
            guard client === currentClient else { return }
            client = nil
            consecutiveEmptyReadings = 0
            nextRetryAt = now.addingTimeInterval(Self.retryInterval)
        }
    }

    /// IOHID event-system clients are expensive system connections. Keeping one
    /// serialized client avoids reconnecting on every menu-bar sample and keeps
    /// the private driver calls away from concurrent callers.
    private final class TemperatureClient: @unchecked Sendable {
        private let symbols: IOKitHIDTemperatureSymbols
        private let system: UnsafeMutableRawPointer
        private let lock = NSLock()

        init?() {
            guard let symbols = IOKitHIDTemperatureSymbols.shared,
                  let system = symbols.create(kCFAllocatorDefault) else {
                return nil
            }

            self.symbols = symbols
            self.system = system

            let matching: CFDictionary = [
                "PrimaryUsagePage" as CFString: NSNumber(value: temperatureUsagePage),
                "PrimaryUsage" as CFString: NSNumber(value: temperatureUsage)
            ] as CFDictionary
            symbols.setMatching(system, matching)
        }

        deinit {
            Unmanaged<CFTypeRef>.fromOpaque(system).release()
        }

        func readings() -> [Reading]? {
            lock.lock()
            defer { lock.unlock() }

            guard let services = symbols.copyServices(system)?.takeRetainedValue() else {
                return nil
            }

            let field = temperatureEventType << 16
            var readings: [Reading] = []
            for index in 0..<CFArrayGetCount(services) {
                let service = unsafeBitCast(
                    CFArrayGetValueAtIndex(services, index),
                    to: UnsafeMutableRawPointer.self
                )
                guard let event = symbols.copyEvent(service, temperatureEventType, 0, 0) else {
                    continue
                }
                defer { Unmanaged<CFTypeRef>.fromOpaque(event).release() }

                let name = sensorName(for: service, symbols: symbols)
                let rawValue = symbols.getFloatValue(event, field)
                guard let value = normalizedTemperature(
                    rawValue: rawValue,
                    sensorName: name
                ) else { continue }

                readings.append(Reading(
                    name: name,
                    value: value
                ))
            }
            return readings
        }
    }

    private static func sensorName(for service: UnsafeMutableRawPointer, symbols: IOKitHIDTemperatureSymbols) -> String {
        guard let rawName = symbols.copyProperty(service, "Product" as CFString)?.takeRetainedValue() else {
            return ""
        }
        return rawName as? String ?? "\(rawName)"
    }

    private static func isSoCMonitorTemperature(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("soc mtr temp") || lowered.contains("hottest soc")
    }

    private static func isDieTemperature(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("tdie")
            || lowered.contains("tdev")
            || lowered.contains("die temp")
    }

    private static func isClusterMonitorTemperature(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("pacc mtr temp") || lowered.contains("eacc mtr temp")
    }

    private static func isPeripheralTemperature(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("battery")
            || lowered.contains("gas gauge")
            || lowered.contains("nand")
            || lowered.contains("ssd")
            || lowered.contains("ambient")
            || lowered.contains("airflow")
            || lowered.contains("inlet")
            || lowered.contains("palm")
            || lowered.contains("thunderbolt")
            || lowered.contains("wifi")
            || lowered.contains("wi-fi")
            || lowered.contains("wlan")
            || lowered.contains("tcal")
    }

    private static func temperatureZone(for name: String) -> SystemTemperatureZone? {
        let lowered = name.lowercased()
        if isSoCMonitorTemperature(name) { return .soc }
        if lowered.contains("pacc") || lowered.contains("performance core") {
            return .performanceCores
        }
        if lowered.contains("eacc") || lowered.contains("efficiency core") {
            return .efficiencyCores
        }
        if lowered.contains("gpu") || lowered.contains("graphics") { return .gpu }
        if lowered.contains("thunderbolt") {
            if lowered.contains("left") { return .thunderboltLeft }
            if lowered.contains("right") { return .thunderboltRight }
            return nil
        }
        if lowered.contains("palm") { return .palmRest }
        if lowered.contains("wifi") || lowered.contains("wi-fi") || lowered.contains("wlan") {
            return .wifi
        }
        if lowered.contains("nand") || lowered.contains("ssd") || lowered.contains("storage") {
            return .storage
        }
        if lowered.contains("battery") || lowered.contains("gas gauge") { return .battery }
        if lowered.contains("ambient") || lowered.contains("airflow") || lowered.contains("inlet") {
            return .ambient
        }
        if isDieTemperature(name) || lowered.contains("cpu") { return .chip }
        return nil
    }

    private static func isReasonableTemperature(_ value: Double) -> Bool {
        value.isFinite && (5...130).contains(value)
    }
}

private struct IOKitHIDTemperatureSymbols {
    typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    typealias SetMatching = @convention(c) (UnsafeMutableRawPointer?, CFDictionary) -> Void
    typealias CopyServices = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFArray>?
    typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer?, CFString) -> Unmanaged<CFTypeRef>?
    typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer?, Int32, Int64, Int32) -> UnsafeMutableRawPointer?
    typealias GetFloatValue = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double

    let create: Create
    let setMatching: SetMatching
    let copyServices: CopyServices
    let copyProperty: CopyProperty
    let copyEvent: CopyEvent
    let getFloatValue: GetFloatValue

    static let shared: IOKitHIDTemperatureSymbols? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard let create = load("IOHIDEventSystemClientCreate", as: Create.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let getFloatValue = load("IOHIDEventGetFloatValue", as: GetFloatValue.self) else {
            return nil
        }

        return IOKitHIDTemperatureSymbols(
            create: create,
            setMatching: setMatching,
            copyServices: copyServices,
            copyProperty: copyProperty,
            copyEvent: copyEvent,
            getFloatValue: getFloatValue
        )
    }()
}
