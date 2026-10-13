import CoreFoundation
import Darwin
import Foundation

enum AppleSiliconTemperatureService {
    struct Reading: Equatable {
        let name: String
        let value: Double
        var serviceID: String? = nil
        var ordinal: Int = 0
        var sampledAt: Date? = nil
    }

    private static let temperatureUsagePage: Int32 = 0xff00
    private static let temperatureUsage: Int32 = 0x0005
    private static let temperatureEventType: Int32 = 15
    private static let clientStore = TemperatureClientStore()

    static func currentChipTemperatureCelsius() -> Double? {
        chipTemperatureCelsius(from: currentTemperatureReadings())
    }

    static func chipTemperatureCelsius(from readings: [Reading], now: Date = Date()) -> Double? {
        // D57: `PMU tdie*` is the power-management IC's die, not the CPU; it
        // is listed as "电源管理芯片" among the hardware probes instead.
        let validReadings = readings.filter { reading in
            isCurrent(reading, now: now)
        }
        let candidateGroups = [
            validReadings.filter { temperatureZone(for: $0.name) == .soc },
            validReadings.filter { temperatureZone(for: $0.name) == .chip },
            validReadings.filter {
                let zone = temperatureZone(for: $0.name)
                return zone == .performanceCores || zone == .efficiencyCores
            }
        ]

        for group in candidateGroups where !group.isEmpty {
            return group.map(\.value).max()
        }
        return nil
    }

    static func currentTemperatureReadings() -> [Reading] {
        clientStore.readings()
    }

    static func regionalTemperatures(from readings: [Reading], now: Date = Date()) -> [SystemTemperatureReading] {
        var hottestByZone: [SystemTemperatureZone: Double] = [:]
        for reading in readings where isCurrent(reading, now: now) {
            guard let zone = temperatureZone(for: reading.name) else { continue }
            hottestByZone[zone] = max(hottestByZone[zone] ?? reading.value, reading.value)
        }

        return SystemTemperatureZone.allCases.compactMap { zone in
            hottestByZone[zone].map { SystemTemperatureReading(zone: zone, celsius: $0) }
        }
    }

    static func detailedTemperatures(from readings: [Reading], now: Date = Date()) -> [SystemTemperatureDetailReading] {
        // Names are labels. The retained HID service + ordinal is the identity.
        let valid = readings.enumerated().filter { _, reading in
            isCurrent(reading, now: now) && !isCalibrationTemperature(reading.name)
        }.sorted {
            let lhs = $0.element.serviceID ?? "legacy.\($0.offset)"
            let rhs = $1.element.serviceID ?? "legacy.\($1.offset)"
            if lhs != rhs { return lhs < rhs }
            return $0.element.ordinal < $1.element.ordinal
        }
        var seen: Set<String> = []
        var channels: [(title: String, zone: SystemTemperatureZone?, value: Double, channel: MenuBarTemperatureChannel)] = []
        for (offset, reading) in valid {
            let raw = String(reading.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            let zone = temperatureZone(for: raw)
            let isPMU = isPowerManagementTemperature(raw)
            let ordinal = reading.ordinal > 0 ? reading.ordinal : offset + 1
            let channel = MenuBarTemperatureChannel(source: .hid,
                rawKey: reading.serviceID ?? "legacy-service-\(offset + 1)", ordinal: ordinal,
                rawName: raw, location: zone.map(MenuBarTemperatureChannel.zoneTitle),
                confidence: zone != nil || isPMU ? .recognized : .unknown)
            guard seen.insert(channel.id).inserted else { continue }
            let title = isPMU ? L10n.text("电源管理芯片", "Power Management IC")
                : zone.map(MenuBarTemperatureChannel.zoneTitle)
                    ?? L10n.text("未识别温度通道", "Unidentified Temperature Channel")
            channels.append((title, zone, reading.value, channel))
        }
        // Display numbers follow the raw label then raw service key (numeric
        // order), never the cache's discovery ordinal, so "PMU tdie2" stays
        // before "PMU tdie10" and numbering does not depend on enumeration.
        channels.sort { lhs, rhs in
            let options: String.CompareOptions = [.literal, .numeric]
            let name = lhs.channel.rawName.compare(rhs.channel.rawName, options: options)
            if name != .orderedSame { return name == .orderedAscending }
            let key = lhs.channel.rawKey.compare(rhs.channel.rawKey, options: options)
            if key != .orderedSame { return key == .orderedAscending }
            return lhs.channel.ordinal < rhs.channel.ordinal
        }
        var numberByTitle: [String: Int] = [:]
        var details: [SystemTemperatureDetailReading] = []
        for item in channels {
            let number = (numberByTitle[item.title] ?? 0) + 1
            numberByTitle[item.title] = number
            details.append(SystemTemperatureDetailReading(id: item.channel.id,
                name: "\(item.title) \(number)", zone: item.zone, celsius: item.value, channel: item.channel))
        }
        return selectDetails(details)
    }

    /// Known locations first, then conservative unknowns; identity breaks ties.
    /// The same rule bounds the combined SMC/HID inspector to 23 rows.
    static func selectDetails(_ readings: [SystemTemperatureDetailReading]) -> [SystemTemperatureDetailReading] {
        Array(readings.filter { isReasonableTemperature($0.celsius) }.sorted {
            let lhs = $0.channel?.confidence.rank ?? ($0.zone == nil ? 0 : 1)
            let rhs = $1.channel?.confidence.rank ?? ($1.zone == nil ? 0 : 1)
            if lhs != rhs { return lhs > rhs }
            let name = $0.name.compare($1.name, options: [.literal, .numeric])
            if name != .orderedSame { return name == .orderedAscending }
            return $0.id < $1.id
        }.prefix(23))
    }

    /// The hottest valid `PMU tdie*`/`tdev*` reading (D57 "电源管理芯片").
    static func powerManagementTemperatureCelsius(from readings: [Reading], now: Date = Date()) -> Double? {
        readings.filter { isPowerManagementTemperature($0.name) && isCurrent($0, now: now) }
            .map(\.value)
            .max()
    }

    /// One "电源管理芯片" hardware-probe row, the hottest PMU die reading.
    static func powerManagementDetail(from readings: [Reading]) -> SystemTemperatureDetailReading? {
        powerManagementTemperatureCelsius(from: readings).map {
            SystemTemperatureDetailReading.powerManagement(celsius: $0)
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
        private let metadata: HIDTemperatureMetadataCache<IOKitHIDTemperatureDriver>
        private let lock = NSLock()

        init?() {
            guard let driver = IOKitHIDTemperatureDriver() else { return nil }
            metadata = HIDTemperatureMetadataCache(driver: driver)
        }

        func readings() -> [Reading]? {
            lock.lock()
            defer { lock.unlock() }
            return metadata.readings()
        }
    }

    /// The retained object is the identity, not merely its unowned address.
    /// Retention prevents a removed service's address being recycled while its
    /// name is cached. Reads still use the services copied in the current pass.
    private struct HIDServiceIdentity: Hashable {
        let object: CFTypeRef

        var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(object).toOpaque() }

        static func == (lhs: Self, rhs: Self) -> Bool {
            ObjectIdentifier(lhs.object) == ObjectIdentifier(rhs.object)
        }

        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(object)) }
    }

    private final class IOKitHIDTemperatureDriver: HIDTemperatureReadingDriver {
        private let symbols: IOKitHIDTemperatureSymbols
        private let system: UnsafeMutableRawPointer

        init?() {
            guard let symbols = IOKitHIDTemperatureSymbols.shared,
                  let system = symbols.create(kCFAllocatorDefault) else { return nil }
            self.symbols = symbols
            self.system = system
            let matching: CFDictionary = [
                "PrimaryUsagePage" as CFString: NSNumber(value: temperatureUsagePage),
                "PrimaryUsage" as CFString: NSNumber(value: temperatureUsage)
            ] as CFDictionary
            symbols.setMatching(system, matching)
        }

        deinit { Unmanaged<CFTypeRef>.fromOpaque(system).release() }

        func services() -> [HIDServiceIdentity]? {
            guard let services = symbols.copyServices(system)?.takeRetainedValue() else { return nil }
            var identities: [HIDServiceIdentity] = []
            for index in 0..<CFArrayGetCount(services) {
                let service = unsafeBitCast(
                    CFArrayGetValueAtIndex(services, index),
                    to: UnsafeMutableRawPointer.self
                )
                identities.append(HIDServiceIdentity(object: Unmanaged<CFTypeRef>.fromOpaque(service).takeUnretainedValue()))
            }
            return identities
        }

        func identity(of service: HIDServiceIdentity) -> HIDServiceIdentity { service }

        func name(of service: HIDServiceIdentity) -> String? {
            guard let rawName = symbols.copyProperty(service.pointer, "Product" as CFString)?.takeRetainedValue() else { return nil }
            return rawName as? String ?? "\(rawName)"
        }

        func rawIdentifier(of service: HIDServiceIdentity) -> String? {
            guard let value = symbols.copyProperty(service.pointer, "RegistryID" as CFString)?.takeRetainedValue() else { return nil }
            return (value as? NSNumber)?.stringValue
        }

        func temperature(of service: HIDServiceIdentity) -> Double? {
            guard let event = symbols.copyEvent(service.pointer, temperatureEventType, 0, 0) else { return nil }
            defer { Unmanaged<CFTypeRef>.fromOpaque(event).release() }
            return symbols.getFloatValue(event, temperatureEventType << 16)
        }
    }

    /// The power-management IC's die sensors (`PMU tdie1…`, `PMU tdev1…`).
    /// `PMU tcal` is a fixed calibration value and is not one of them.
    static func isPowerManagementTemperature(_ name: String) -> Bool {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        return lowered.range(of: #"^pmu\d* t(die|dev)\s*\d+$"#, options: .regularExpression) != nil
    }

    private static func isCalibrationTemperature(_ name: String) -> Bool {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^pmu\d* tcal\s*\d*$"#, options: .regularExpression) != nil
    }

    /// A bounded vocabulary, anchored to a complete channel label. An arbitrary
    /// product string containing "gpu"/"cpu" is not a confirmed location.
    private static func temperatureZone(for name: String) -> SystemTemperatureZone? {
        let name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog: [(String, SystemTemperatureZone)] = [
            // Real Apple Silicon HID labels are "<block> MTR Temp Sensor<N>"
            // (pACC/eACC/GPU/SOC; ANE/ISP stay unmapped), see round2 probe notes.
            (#"^(soc mtr temp( sensor)?|hottest soc sensor|pmgr soc die temp sensor)\s*\d*$"#, .soc),
            (#"^(pacc mtr temp( sensor)?|performance core temp)\s*\d*$"#, .performanceCores),
            (#"^(eacc mtr temp( sensor)?|efficiency core temp)\s*\d*$"#, .efficiencyCores),
            (#"^(gpu mtr temp( sensor)?|gpu tdie|gpu die temp)( die)?\s*\d*$"#, .gpu),
            (#"^(cpu tdie|cpu die temp)( die)?\s*\d*$"#, .chip),
            (#"^(nand ch\d+ temp|ssd temp|storage temperature)$"#, .storage),
            (#"^(gas gauge battery|battery temp|battery temperature)$"#, .battery),
            (#"^(ambient temp|ambient temperature|airflow temp|inlet temp)$"#, .ambient),
            (#"^palm rest temp$"#, .palmRest),
            (#"^thunderbolt left proximity$"#, .thunderboltLeft),
            (#"^thunderbolt right proximity$"#, .thunderboltRight),
            (#"^(wi-fi module temperature|wifi module temperature|wlan temperature)$"#, .wifi)
        ]
        return catalog.first { name.range(of: $0.0, options: .regularExpression) != nil }?.1
    }

    private static func isCurrent(_ reading: Reading, now: Date) -> Bool {
        isReasonableTemperature(reading.value)
            && (reading.sampledAt.map { now.timeIntervalSince($0) >= -5 && now.timeIntervalSince($0) <= 180 } ?? true)
    }

    /// Sampling floor (unchanged): a 0/near-0 HID or SMC reading is treated as
    /// not-a-measurement here; legal 0°C is only preserved by history/models.
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
