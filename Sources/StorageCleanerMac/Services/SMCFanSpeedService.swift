@preconcurrency import Darwin
import Foundation
import IOKit

enum SMCFanSpeedService {
    struct HardwareReadings: Sendable {
        let fanReadings: [SystemFanReading]
        let fanCount: Int?
        let temperatureReadings: [SystemTemperatureReading]
        let temperatureDetails: [SystemTemperatureDetailReading]
        let chipTemperatureCelsius: Double?
        /// The hottest per-PMU SMC reading (`TPDX/TRDX/TUDX`), the fallback
        /// for the "电源管理芯片" probe when the HID `PMU tdie*` are missing.
        var powerManagementTemperatureCelsius: Double? = nil
        /// Zones whose meaning is inferred from SMC key names (D57: palm rest
        /// `Ts0P/Ts1P`, Thunderbolt `TaLT/TaRT`); the third level says so.
        var inferredZones: Set<SystemTemperatureZone> = []

        static let empty = HardwareReadings(
            fanReadings: [],
            fanCount: nil,
            temperatureReadings: [],
            temperatureDetails: [],
            chipTemperatureCelsius: nil
        )
    }

    // M5 exposes its two CPU tiers and GPU thermal zones through AppleSMC.
    // Keep these groups explicit: similarly shaped keys have different
    // meanings on earlier Apple Silicon generations.
    private static let m5SuperCoreTemperatureKeys = [
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"
    ]

    private static let m5PerformanceCoreTemperatureKeys = [
        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
        "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
    ]

    // Complete M5 GPU cluster table.  A short representative list misses most
    // Pro/Max clusters and can materially under-report the graphics region.
    // Keep this explicit instead of enumerating thousands of SMC keys during
    // the first panel sample.
    private static let m5GPUTemperatureKeys = [
        "Tg08", "Tg0C", "Tg0O", "Tg0R", "Tg0U", "Tg0X", "Tg0a", "Tg0d",
        "Tg0g", "Tg0j", "Tg12", "Tg16", "Tg1I", "Tg1M", "Tg1Q", "Tg1U",
        "Tg1Y", "Tg1c", "Tg1k", "Tg1o", "Tg1x", "Tg29", "Tg2D", "Tg2P",
        "Tg2T", "Tg2X", "Tg2b", "Tg2f", "Tg2j", "Tg2n", "Tg2r", "Tg3B",
        "Tg3F", "Tg3R", "Tg3V", "Tg3Z", "Tg3d", "Tg3h", "Tg3l", "Tg3t",
        "Tg3x", "Tg43"
    ]

    private static let peripheralTemperatureKeys: [(SystemTemperatureZone, [String])] = [
        (.ambient, ["TaLP", "TaRF", "TA0P", "TA1P"]),
        (.battery, ["TB0T", "TB1T", "TB2T", "TB3T", "TBXT"]),
        (.storage, ["TH0x", "TH0X", "TH0F", "TH0R", "TH0A", "TH0B", "TH0C", "Th0N"]),
        (.wifi, ["TW0P", "TW0p"])
    ]

    /// Apple silicon only: Asahi's common sensors name `TCHP` the charge
    /// regulator ("充电电路", D57). The external adapter is not readable.
    private static let appleSiliconPeripheralTemperatureKeys: [(SystemTemperatureZone, [String])] = [
        (.chargingCircuit, ["TCHP"])
    ]

    // These M5 chassis keys are only interpreted after the complete M5 CPU
    // topology has been observed. D57: palm rest is `Ts0P/Ts1P` (the keys
    // iStat collects on Mac17,9; they stay flat under SSD load, so they are
    // not SSD sensors) and Thunderbolt is `TaLT/TaRT`. Neither group has a
    // public definition, so their meaning is inferred from the key names
    // (`inferredZones`) until the names are checked in iStat.
    private static let m5ChassisTemperatureKeys: [(SystemTemperatureZone, [String])] = [
        (.palmRest, ["Ts0P", "Ts1P"]),
        (.thunderboltLeft, ["TaLT"]),
        (.thunderboltRight, ["TaRT"])
    ]

    /// The hottest sensor of each power-management IC (research §4.1).
    private static let powerManagementTemperatureKeys = ["TPDX", "TRDX", "TUDX"]

    private static let primaryChipTemperatureKeys = [
        "TCMz", "TCMb"
    ]

    private static let proximityChipTemperatureKeys = [
        "TCHP", "TPMP"
    ]

    private static let fallbackChipTemperatureKeys = [
        "TPDX",
        "TPD0", "TPD1", "TPD2", "TPD3", "TPD4", "TPD5", "TPD6", "TPD7", "TPD8", "TPD9",
        "TPDa", "TPDb", "TPDc", "TPDd", "TPDe", "TPDf",
        "TRDX", "TRD0", "TRD1", "TRD2", "TRD3", "TRD4", "TRD5", "TRD6", "TRD7", "TRD8", "TRD9",
        "TRDa", "TRDb", "TRDc", "TRDd", "TRDe", "TRDf",
        "TUDX", "TUD0", "TUD1", "TUD2", "TUD3", "TUD4", "TUD5", "TUD6", "TUD7", "TUD8", "TUD9",
        "TUDa", "TUDb", "TUDc", "TUDd", "TUDe", "TUDf",
        "TVDM", "TVDP", "TVDA", "TVDG", "TVDc",
        "TC0P", "TG0P", "TG0D", "TG0H", "TG0T",
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R",
        "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
        "Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c"
    ]

    private static let isPortableHardware: Bool = {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }()

    static func currentFanSpeedsRPM() -> [Int] {
        currentFanReadings().map(\.actualRPM)
    }

    static func currentFanReadings(connection: SMCReadSession = .shared, isPortable: Bool? = nil) -> [SystemFanReading] {
        connection.withReadPass(fallback: []) { reader in
            fanReadings(
                readValue: { reader.readDouble($0) },
                readName: { reader.readFanName($0) },
                isPortable: isPortable ?? isPortableHardware
            )
        }
    }

    static func currentHardwareReadings(connection: SMCReadSession = .shared, isPortable: Bool? = nil) -> HardwareReadings {
        connection.withReadPass(fallback: .empty) { reader in
            // A single thermal pass can ask for the same core keys while grouping
            // zones and resolving the headline chip value. Cache within this pass
            // so AppleSMC is never queried twice for the same key.
            var attemptedKeys = Set<String>()
            var valuesByKey: [String: Double] = [:]
            func readCached(_ key: String) -> Double? {
                if attemptedKeys.contains(key) {
                    return valuesByKey[key]
                }
                attemptedKeys.insert(key)
                let value = reader.readDouble(key)
                if let value {
                    valuesByKey[key] = value
                }
                return value
            }

            let temperatureReadings = temperatureReadings(readValue: readCached, platform: reader.platform)
            let chipTemperature = chipTemperatureCelsius(readValue: readCached)
            return HardwareReadings(
                fanReadings: fanReadings(
                    readValue: readCached,
                    readName: { reader.readFanName($0) },
                    isPortable: isPortable ?? isPortableHardware
                ),
                fanCount: fanCount(readValue: readCached),
                temperatureReadings: temperatureReadings,
                temperatureDetails: detailedTemperatureReadings(readValue: readCached),
                chipTemperatureCelsius: chipTemperature,
                powerManagementTemperatureCelsius: powerManagementTemperatureCelsius(readValue: readCached),
                inferredZones: inferredTemperatureZones(readValue: readCached)
            )
        }
    }

    /// The hottest valid `TPDX/TRDX/TUDX` reading.
    static func powerManagementTemperatureCelsius(readValue: (String) -> Double?) -> Double? {
        temperatures(for: powerManagementTemperatureKeys, readValue: readValue).max()
    }

    /// The zones `temperatureReadings` filled from key names alone.
    static func inferredTemperatureZones(readValue: (String) -> Double?) -> Set<SystemTemperatureZone> {
        guard m5TemperatureGroups(readValue: readValue).isCompleteTopology else { return [] }
        return Set(m5ChassisTemperatureKeys.compactMap { zone, keys in
            temperatures(for: keys, readValue: readValue).isEmpty ? nil : zone
        })
    }

    static func currentChipTemperatureCelsius(connection: SMCReadSession = .shared) -> Double? {
        connection.withReadPass(fallback: nil) { reader in
            chipTemperatureCelsius { key in
                reader.readDouble(key)
            }
        }
    }

    static func fanSpeedsRPM(readValue: (String) -> Double?) -> [Int] {
        fanReadings(readValue: readValue).map(\.actualRPM)
    }

    /// Completes the legacy speed-only sampling path with the same stable SMC
    /// index identities used by the structured reader. A monitor refresh can
    /// briefly publish F0/F1 speeds before the richer descriptor pass arrives;
    /// those samples must not regress to generic labels on a dual-fan MacBook.
    static func resolvedFanReadings(
        _ readings: [SystemFanReading]?,
        fallbackSpeeds: [Int]?
    ) -> [SystemFanReading]? {
        resolvedFanReadings(
            readings,
            fallbackSpeeds: fallbackSpeeds,
            isPortable: isPortableHardware
        )
    }

    static func resolvedFanReadings(
        _ readings: [SystemFanReading]?,
        fallbackSpeeds: [Int]?,
        isPortable: Bool
    ) -> [SystemFanReading]? {
        let source: [SystemFanReading]
        if let readings, !readings.isEmpty {
            source = readings
        } else if let fallbackSpeeds, !fallbackSpeeds.isEmpty {
            source = fallbackSpeeds.enumerated().map { index, speed in
                SystemFanReading(
                    index: index,
                    actualRPM: speed,
                    minimumRPM: nil,
                    maximumRPM: nil,
                    targetRPM: nil
                )
            }
        } else {
            return nil
        }

        let fanCount = source.count
        return source.map { reading in
            guard reading.identity == nil else { return reading }
            return SystemFanReading(
                index: reading.index,
                identity: fanIdentity(
                    reportedName: nil,
                    index: reading.index,
                    fanCount: fanCount,
                    isPortable: isPortable
                ),
                actualRPM: reading.actualRPM,
                minimumRPM: reading.minimumRPM,
                maximumRPM: reading.maximumRPM,
                targetRPM: reading.targetRPM
            )
        }
    }

    static func fanReadings(readValue: (String) -> Double?) -> [SystemFanReading] {
        fanReadings(
            readValue: readValue,
            readName: { _ in nil },
            isPortable: false
        )
    }

    static func fanCount(readValue: (String) -> Double?) -> Int? {
        guard let value = readValue("FNum"),
              value.isFinite,
              (0...16).contains(value),
              value.rounded(.down) == value else { return nil }
        return Int(value)
    }

    static func fanReadings(
        readValue: (String) -> Double?,
        readName: (String) -> String?,
        isPortable: Bool
    ) -> [SystemFanReading] {
        guard let fanCount = Self.fanCount(readValue: readValue) else { return [] }

        var readings: [SystemFanReading] = []
        readings.reserveCapacity(fanCount)
        for index in 0..<fanCount {
            guard let speed = readValue("F\(index)Ac"),
                  speed.isFinite,
                  (0...20_000).contains(speed) else {
                return []
            }
            readings.append(SystemFanReading(
                index: index,
                identity: fanIdentity(
                    reportedName: readName("F\(index)ID"),
                    index: index,
                    fanCount: fanCount,
                    isPortable: isPortable
                ),
                actualRPM: Int(speed.rounded()),
                minimumRPM: normalizedFanRPM(readValue("F\(index)Mn")),
                maximumRPM: normalizedFanRPM(readValue("F\(index)Mx")),
                targetRPM: normalizedFanRPM(readValue("F\(index)Tg"))
            ))
        }
        return readings
    }

    static func fanIdentity(
        reportedName: String?,
        index: Int,
        fanCount: Int,
        isPortable: Bool
    ) -> SystemFanIdentity? {
        if let name = normalizedReportedFanName(reportedName) {
            let normalized = name.lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")

            if normalized.contains("left") { return .left }
            if normalized.contains("right") { return .right }
            if normalized.contains("cpu") { return .cpu }
            if normalized.contains("gpu") { return .gpu }
            if normalized == "hdd"
                || normalized.contains("hard drive")
                || normalized.contains("storage")
                || normalized.contains("disk") {
                return .storage
            }
            if normalized == "odd" || normalized.contains("optical") {
                return .opticalDrive
            }
            if normalized == "ps"
                || normalized == "psu"
                || normalized.contains("power supply") {
                return .powerSupply
            }
            if normalized.contains("exhaust") { return .exhaust }
            if normalized.contains("intake") { return .intake }
            return .named(name)
        }

        // Recent Apple Silicon notebooks no longer expose F0ID/F1ID.  For a
        // two-fan portable, the SMC index is still the physical ordering used
        // by the thermal controller: F0 is left and F1 is right.  Never apply
        // this fallback to desktops, fanless Macs, or other fan counts.
        guard isPortable, fanCount == 2 else { return nil }
        if index == 0 { return .left }
        if index == 1 { return .right }
        return nil
    }

    static func decodeFanName(dataType: String, bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return nil }
        let payload: ArraySlice<UInt8>
        if dataType == "{fds", bytes.count > 4 {
            payload = bytes.dropFirst(4)
        } else {
            payload = bytes[...]
        }
        let printableRuns = payload.split { byte in
            byte < 0x20 || byte > 0x7e
        }
        guard let longest = printableRuns.max(by: { $0.count < $1.count }) else {
            return nil
        }
        return normalizedReportedFanName(String(decoding: longest, as: UTF8.self))
    }

    static func chipTemperatureCelsius(readValue: (String) -> Double?) -> Double? {
        let m5Groups = m5TemperatureGroups(readValue: readValue)
        if m5Groups.isCompleteTopology {
            return (m5Groups.superCores + m5Groups.performanceCores).max()
        }

        for key in primaryChipTemperatureKeys + fallbackChipTemperatureKeys + proximityChipTemperatureKeys {
            guard let temperature = readValue(key),
                  isReasonableTemperature(temperature) else {
                continue
            }
            return temperature
        }
        return nil
    }

    static func temperatureReadings(
        readValue: (String) -> Double?,
        platform: SMCPlatform = .current
    ) -> [SystemTemperatureReading] {
        var valueByZone: [SystemTemperatureZone: Double] = [:]
        let m5Groups = m5TemperatureGroups(readValue: readValue)

        if m5Groups.isCompleteTopology {
            // Core rows are hotspot summaries, matching the way the reference
            // monitor rounds the hottest active core.  The many GPU clusters
            // are intentionally averaged to avoid a single noisy die point.
            valueByZone[.superCores] = m5Groups.superCores.max()
            valueByZone[.performanceCores] = m5Groups.performanceCores.max()
            valueByZone[.gpu] = averageTemperature(m5Groups.gpu)

            for (zone, keys) in m5ChassisTemperatureKeys {
                let values = temperatures(for: keys, readValue: readValue)
                if let average = averageTemperature(values) {
                    valueByZone[zone] = average
                }
            }
        }

        let peripheralKeys = platform == .appleSilicon
            ? peripheralTemperatureKeys + appleSiliconPeripheralTemperatureKeys
            : peripheralTemperatureKeys
        for (zone, keys) in peripheralKeys {
            let values = temperatures(for: keys, readValue: readValue)
            if let average = averageTemperature(values) {
                valueByZone[zone] = average
            }
        }

        return SystemTemperatureZone.allCases.compactMap { zone in
            valueByZone[zone].map {
                SystemTemperatureReading(zone: zone, celsius: $0)
            }
        }
    }

    /// Only the complete known M5 topology gives these SMC keys a verified
    /// per-core meaning. Other Macs use the named HID sensor details instead.
    static func detailedTemperatureReadings(
        readValue: (String) -> Double?
    ) -> [SystemTemperatureDetailReading] {
        let groups = m5TemperatureGroups(readValue: readValue)
        guard groups.isCompleteTopology else { return [] }

        func coreRows(
            keys: [String], zone: SystemTemperatureZone,
            title: (Int) -> String
        ) -> [SystemTemperatureDetailReading] {
            keys.enumerated().compactMap { offset, key in
                guard let value = readValue(key), isReasonableTemperature(value) else { return nil }
                return SystemTemperatureDetailReading(
                    id: "smc.\(key)", name: title(offset + 1), zone: zone, celsius: value
                )
            }
        }

        var result = coreRows(
            keys: m5SuperCoreTemperatureKeys, zone: .superCores,
            title: { L10n.text("超级核心 \($0)", "Super Core \($0)") }
        ) + coreRows(
            keys: m5PerformanceCoreTemperatureKeys, zone: .performanceCores,
            title: { L10n.text("性能核心 \($0)", "Performance Core \($0)") }
        )
        let midpoint = m5GPUTemperatureKeys.count / 2
        for (index, keys) in [
            Array(m5GPUTemperatureKeys[..<midpoint]),
            Array(m5GPUTemperatureKeys[midpoint...])
        ].enumerated() {
            let values = temperatures(for: keys, readValue: readValue)
            guard let average = averageTemperature(values) else { continue }
            result.append(SystemTemperatureDetailReading(
                id: "smc.gpu-region-\(index + 1)",
                name: L10n.text("GPU 区域 \(index + 1) 均值", "GPU Region \(index + 1) Average"),
                zone: .gpu, celsius: average
            ))
        }
        return result
    }

    /// Metadata only: use the existing verified recipe, without another read.
    /// GPU detail rows are explicitly named regional averages, not single probes.
    static func rawTemperatureKeys(forDetailID id: String) -> [String] {
        let prefix = "smc.gpu-region-"
        if id.hasPrefix(prefix), let region = Int(id.dropFirst(prefix.count)), (1...2).contains(region) {
            let midpoint = m5GPUTemperatureKeys.count / 2
            return region == 1 ? Array(m5GPUTemperatureKeys[..<midpoint]) : Array(m5GPUTemperatureKeys[midpoint...])
        }
        if id == SystemTemperatureDetailReading.powerManagementID { return powerManagementTemperatureKeys }
        return id.hasPrefix("smc.") ? [String(id.dropFirst(4))] : []
    }

    static func averageRPM(from speeds: [Int]) -> Int? {
        guard !speeds.isEmpty else { return nil }
        return Int((Double(speeds.reduce(0, +)) / Double(speeds.count)).rounded())
    }

    private static func isReasonableTemperature(_ value: Double) -> Bool {
        value.isFinite && (5...130).contains(value)
    }

    private static func m5TemperatureGroups(
        readValue: (String) -> Double?
    ) -> (
        superCores: [Double],
        performanceCores: [Double],
        gpu: [Double],
        isCompleteTopology: Bool
    ) {
        let superCores = temperatures(
            for: m5SuperCoreTemperatureKeys,
            readValue: readValue
        )
        let performanceCores = temperatures(
            for: m5PerformanceCoreTemperatureKeys,
            readValue: readValue
        )
        let isCompleteTopology = superCores.count >= 4 && performanceCores.count >= 6
        let gpu = isCompleteTopology
            ? temperatures(for: m5GPUTemperatureKeys, readValue: readValue)
            : []
        return (superCores, performanceCores, gpu, isCompleteTopology)
    }

    private static func temperatures(
        for keys: [String],
        readValue: (String) -> Double?
    ) -> [Double] {
        keys.compactMap { key in
            guard let value = readValue(key), isReasonableTemperature(value) else {
                return nil
            }
            return value
        }
    }

    private static func averageTemperature(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func normalizedFanRPM(_ value: Double?) -> Int? {
        guard let value, value.isFinite, (0...20_000).contains(value) else { return nil }
        return Int(value.rounded())
    }

    private static func normalizedReportedFanName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 48 else { return nil }
        return normalized
    }
}

/// The hardware family whose SMC is being read. The integer byte order of a
/// key depends on it (research 2026-10-07 §4.1): the classic Intel SMC is
/// big-endian throughout, while on Apple silicon `#KEY` is big-endian but the
/// battery integer keys are little-endian.
enum SMCPlatform: Equatable, Sendable {
    case appleSilicon
    case intel

    /// Decided from the hardware, not the build architecture, so a
    /// translated process on Apple silicon still decodes Apple silicon keys.
    static let current: SMCPlatform = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1 ? .appleSilicon : .intel
    }()
}

enum SMCByteOrder: Equatable, Sendable {
    case bigEndian
    case littleEndian
}

/// The raw result of asking AppleSMC for one key.
enum SMCKeyRead: Equatable, Sendable {
    /// The driver explicitly reports that this key does not exist on this Mac.
    case missing
    /// Discovery or value reading failed temporarily; support is not known.
    case unreadable
    case present(dataType: String, bytes: [UInt8])
}

/// Decodes an SMC value by key and platform. Multi-byte integers are only
/// decoded when the key's byte order is known: an unknown Apple silicon
/// integer key fails closed instead of being guessed (the old decoder read
/// every `ui16`/`ui32` big-endian, which turns the little-endian battery keys
/// into nonsense, e.g. `B0AV` 12 302 mV as 3 632).
enum SMCValueDecoder {
    /// Apple silicon integer keys stored little-endian: the battery family.
    /// Measured on Mac17,9 (`B0AV` 0e30 = 12 302 mV, `B0CT` 3d00 = 61
    /// cycles, matching the system report); Asahi documents `B0RM` as
    /// "ui16 in reverse byte order".
    static let appleSiliconLittleEndianKeys: Set<String> = [
        "B0AC", "B0AV", "B0AP", "B0AT", "B0RM", "B0CT", "B0FC", "B0DC", "B0TF",
        "BC1V", "BC2V", "BC3V", "BC4V"
    ]

    /// Apple silicon integer keys stored big-endian (`#KEY` = 0x00000e1d =
    /// 3 613 keys on Mac17,9).
    static let appleSiliconBigEndianKeys: Set<String> = ["#KEY"]

    static func integerByteOrder(forKey key: String, platform: SMCPlatform) -> SMCByteOrder? {
        switch platform {
        case .intel:
            return .bigEndian
        case .appleSilicon:
            if appleSiliconLittleEndianKeys.contains(key) { return .littleEndian }
            if appleSiliconBigEndianKeys.contains(key) { return .bigEndian }
            return nil
        }
    }

    static func decode(
        key: String,
        dataType: String,
        bytes: [UInt8],
        platform: SMCPlatform
    ) -> Double? {
        switch dataType {
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "ui16", "si16", "ui32", "si32", "ui64", "si64":
            return integer(key: key, dataType: dataType, bytes: bytes, platform: platform)
        case "flt ":
            // Single-precision float in host (little-endian) order on both
            // Apple silicon and the T2 SMC.
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: raw))
            return value.isFinite ? value : nil
        // Classic Intel fixed-point formats (big-endian), unchanged.
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 256
        case "spf0":
            guard bytes.count >= 2 else { return nil }
            return Double(Int(bytes[0]) * 256 + Int(bytes[1]))
        default:
            return nil
        }
    }

    private static func integer(
        key: String,
        dataType: String,
        bytes: [UInt8],
        platform: SMCPlatform
    ) -> Double? {
        let width: Int
        switch dataType {
        case "ui16", "si16": width = 2
        case "ui32", "si32": width = 4
        default: width = 8
        }
        guard bytes.count >= width,
              let order = integerByteOrder(forKey: key, platform: platform) else { return nil }
        let ordered = order == .littleEndian
            ? Array(bytes[0..<width].reversed())
            : Array(bytes[0..<width])
        let unsigned = ordered.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard dataType.hasPrefix("si") else { return Double(unsigned) }
        let shift = UInt64(64 - width * 8)
        return Double(Int64(bitPattern: unsigned << shift) >> Int64(shift))
    }
}

/// A read-only AppleSMC connection. It only sends the read selectors
/// (key information 9, read bytes 5, key by index 8); there is no write
/// path, so nothing here can change fans, charging, power or brightness.
final class SMCConnection: SMCReadDriver {
    private enum Command: UInt8 {
        case kernelIndex = 2
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    private struct KeyData {
        typealias Bytes = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        struct Version {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        struct LimitData {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }

        struct KeyInfo {
            var dataSize: IOByteCount32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        var key: UInt32 = 0
        var version = Version()
        var limitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private var connection: io_connect_t = 0

    func open() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &openedConnection) == kIOReturnSuccess else {
            return false
        }
        connection = openedConnection
        return true
    }

    deinit { close() }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    func keyInfo(for key: UInt32) -> SMCDriverRead<SMCKeyInfo> {
        var input = KeyData()
        var output = KeyData()
        input.key = key
        input.data8 = Command.readKeyInfo.rawValue

        guard call(input: &input, output: &output) == kIOReturnSuccess else {
            return SMCReadFailure.classify(transportSucceeded: false, deviceResult: output.result)
        }
        guard output.result == 0 else {
            // AppleSMC's key-not-found result is 0x84. Other controller
            // errors (busy, denied, etc.) must not become negative metadata.
            return SMCReadFailure.classify(transportSucceeded: true, deviceResult: output.result)
        }
        return .success(SMCKeyInfo(dataSize: output.keyInfo.dataSize, dataType: output.keyInfo.dataType.smcString))
    }

    func readBytes(for key: UInt32, info: SMCKeyInfo) -> SMCDriverRead<[UInt8]> {
        var input = KeyData()
        var output = KeyData()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Command.readBytes.rawValue

        guard call(input: &input, output: &output) == kIOReturnSuccess else {
            return SMCReadFailure.classify(transportSucceeded: false, deviceResult: output.result)
        }
        guard output.result == 0 else {
            return SMCReadFailure.classify(transportSucceeded: true, deviceResult: output.result)
        }

        let bytes = withUnsafeBytes(of: output.bytes) { rawBuffer in
            Array(rawBuffer.prefix(Int(min(info.dataSize, 32))))
        }
        return .success(bytes)
    }

    private func call(input: inout KeyData, output: inout KeyData) -> kern_return_t {
        let inputSize = MemoryLayout<KeyData>.stride
        var outputSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(
            connection,
            UInt32(Command.kernelIndex.rawValue),
            &input,
            inputSize,
            &output,
            &outputSize
        )
    }
}

private extension UInt32 {
    var smcString: String {
        String(bytes: [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ], encoding: .utf8) ?? ""
    }
}
