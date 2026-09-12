@preconcurrency import Darwin
import Foundation
import IOKit

enum SMCFanSpeedService {
    struct HardwareReadings: Sendable {
        let fanReadings: [SystemFanReading]
        let fanCount: Int?
        let temperatureReadings: [SystemTemperatureReading]
        let chipTemperatureCelsius: Double?

        static let empty = HardwareReadings(
            fanReadings: [],
            fanCount: nil,
            temperatureReadings: [],
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

    // These M5 chassis keys are only interpreted after the complete M5 CPU
    // topology has been observed.  Ts0P/Ts1P are SSD controllers on M5 and
    // must never be presented as palm-rest temperature.
    private static let m5ChassisTemperatureKeys: [(SystemTemperatureZone, [String])] = [
        (.palmRest, ["TDeL", "TDeR"]),
        (.thunderboltLeft, ["TaLT"]),
        (.thunderboltRight, ["TaRT"])
    ]

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

    static func currentFanReadings() -> [SystemFanReading] {
        guard let connection = SMCConnection() else { return [] }
        return fanReadings(
            readValue: { connection.readDouble($0) },
            readName: { connection.readFanName($0) },
            isPortable: isPortableHardware
        )
    }

    static func currentHardwareReadings() -> HardwareReadings {
        guard let connection = SMCConnection() else { return .empty }

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
            let value = connection.readDouble(key)
            if let value {
                valuesByKey[key] = value
            }
            return value
        }

        return HardwareReadings(
            fanReadings: fanReadings(
                readValue: readCached,
                readName: { connection.readFanName($0) },
                isPortable: isPortableHardware
            ),
            fanCount: fanCount(readValue: readCached),
            temperatureReadings: temperatureReadings(readValue: readCached),
            chipTemperatureCelsius: chipTemperatureCelsius(readValue: readCached)
        )
    }

    static func currentChipTemperatureCelsius() -> Double? {
        guard let connection = SMCConnection() else { return nil }
        return chipTemperatureCelsius { key in
            connection.readDouble(key)
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
        readValue: (String) -> Double?
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

        for (zone, keys) in peripheralTemperatureKeys {
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

private final class SMCConnection {
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

    private struct Value {
        let dataType: String
        let bytes: [UInt8]
    }

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &openedConnection) == kIOReturnSuccess else {
            return nil
        }
        connection = openedConnection
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func readDouble(_ key: String) -> Double? {
        guard let value = read(key) else { return nil }
        return decodeDouble(dataType: value.dataType, bytes: value.bytes)
    }

    func readFanName(_ key: String) -> String? {
        guard let value = read(key) else { return nil }
        return SMCFanSpeedService.decodeFanName(
            dataType: value.dataType,
            bytes: value.bytes
        )
    }

    private func read(_ key: String) -> Value? {
        guard let keyCode = smcKeyCode(key) else { return nil }

        var input = KeyData()
        var output = KeyData()
        input.key = keyCode
        input.data8 = Command.readKeyInfo.rawValue

        guard call(input: &input, output: &output) == kIOReturnSuccess,
              output.result == 0 else {
            return nil
        }

        let dataSize = output.keyInfo.dataSize
        let dataType = output.keyInfo.dataType.smcString
        guard dataSize > 0 else { return nil }

        input.keyInfo.dataSize = dataSize
        input.data8 = Command.readBytes.rawValue

        guard call(input: &input, output: &output) == kIOReturnSuccess,
              output.result == 0 else {
            return nil
        }

        let bytes = withUnsafeBytes(of: output.bytes) { rawBuffer in
            Array(rawBuffer.prefix(Int(min(dataSize, 32))))
        }
        return Value(dataType: dataType, bytes: bytes)
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

    private func decodeDouble(dataType: String, bytes: [UInt8]) -> Double? {
        switch dataType {
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(
                UInt32(bytes[0]) << 24
                    | UInt32(bytes[1]) << 16
                    | UInt32(bytes[2]) << 8
                    | UInt32(bytes[3])
            )
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
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

    private func smcKeyCode(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { partialResult, byte in
            partialResult << 8 | UInt32(byte)
        }
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
