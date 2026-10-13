import Foundation
import IOKit

/// The value of one SMC key, its unit conversion and its plausible range.
/// Out of range is "读数无效" (D57 ④), never clamped.
struct SMCMeasurementSpec: Equatable, Sendable {
    let key: String
    /// raw × scale + offset gives the displayed unit.
    let scale: Double
    let offset: Double
    let validRange: ClosedRange<Double>

    init(_ key: String, scale: Double = 1, offset: Double = 0, range: ClosedRange<Double>) {
        self.key = key
        self.scale = scale
        self.offset = offset
        self.validRange = range
    }

    func reading(_ read: SMCKeyRead, platform: SMCPlatform) -> HardwareReading<Double> {
        switch read {
        case .missing:
            return .unsupported
        case .unreadable:
            return .invalid
        case let .present(dataType, bytes):
            guard let raw = SMCValueDecoder.decode(
                key: key,
                dataType: dataType,
                bytes: bytes,
                platform: platform
            ) else { return .invalid }
            let value = raw * scale + offset
            guard value.isFinite, validRange.contains(value) else { return .invalid }
            return .value(value)
        }
    }
}

/// Which way the battery current flows, from the sign of the current.
enum BatteryCurrentDirection: Equatable, Sendable {
    /// Current into the battery (positive).
    case charging
    /// Current out of the battery (negative; measured on Mac17,9).
    case discharging

    /// Below this the current gives no direction.
    static let idleAmps = 0.005

    init?(amps: Double?) {
        guard let amps, amps.isFinite, abs(amps) >= Self.idleAmps else { return nil }
        self = amps > 0 ? .charging : .discharging
    }
}

/// What the battery row's power is computed from.
enum SMCBatteryPowerBasis: Equatable, Sendable {
    /// `B0AP`, the SMC's own V × I.
    case batteryPowerKey
    /// `B0AV × B0AC` on a Mac without `B0AP` (incremental review P2-2).
    case voltageTimesCurrent
}

/// The battery's live electrical readings from the SMC (D57 ①): about once
/// a second, unlike AppleSmartBattery's once-a-minute values.
struct SMCBatteryTelemetry: Equatable, Sendable {
    /// `B0AC`, signed (negative while discharging).
    var currentAmps: HardwareReading<Double>
    /// `B0AV`.
    var voltageVolts: HardwareReading<Double>
    /// `B0AP`, signed (negative while discharging).
    var powerWatts: HardwareReading<Double>
    /// `TB0T`, else `B0AT`.
    var temperatureCelsius: HardwareReading<Double>
    var temperatureSourceKey: String?
    /// `BC1V`… in cell order; only cells whose key exists.
    var cellVoltages: [HardwareReading<Double>]

    static let unsupported = SMCBatteryTelemetry(
        currentAmps: .unsupported,
        voltageVolts: .unsupported,
        powerWatts: .unsupported,
        temperatureCelsius: .unsupported,
        temperatureSourceKey: nil,
        cellVoltages: []
    )

    /// The direction of `B0AC`; nil when the current is missing, invalid
    /// or about zero.
    var currentDirection: BatteryCurrentDirection? {
        BatteryCurrentDirection(amps: currentAmps.value)
    }

    /// What `rowPowerWatts` comes from: `B0AP` when the key exists, else
    /// `B0AV × B0AC` when both exist, else nothing (no battery row).
    var rowPowerBasis: SMCBatteryPowerBasis? {
        if powerWatts.isSupported { return .batteryPowerKey }
        if voltageVolts.isSupported, currentAmps.isSupported { return .voltageTimesCurrent }
        return nil
    }

    /// The "电池" row on the card, in its third level, in the history and
    /// in the energy integration (D57 supplement): `B0AP`, the SMC's V × I
    /// about every second, its sign taken from `B0AC`'s direction; without
    /// a direction from `B0AC` (about 0 A) `B0AP` keeps its own sign. A Mac
    /// without `B0AP` uses `B0AV × B0AC` (incremental review P2-2), whose
    /// sign is `B0AC`'s; either key invalid makes it invalid.
    var rowPowerWatts: HardwareReading<Double> {
        switch rowPowerBasis {
        case .batteryPowerKey?:
            guard case let .value(watts) = powerWatts else { return powerWatts }
            switch currentDirection {
            case .charging?: return .value(abs(watts))
            case .discharging?: return .value(-abs(watts))
            case nil: return .value(watts)
            }
        case .voltageTimesCurrent?:
            guard let volts = voltageVolts.value, let amps = currentAmps.value else { return .invalid }
            let watts = volts * amps
            return watts.isFinite ? .value(watts) : .invalid
        case nil:
            return .unsupported
        }
    }
}

/// The built-in display's backlight power (D57 ①): `PBwo` first, then
/// `PDBR`, shown only when it agrees with `IDBR × VP0R` within ±20 %.
struct BacklightPowerReading: Equatable, Sendable {
    enum Verification: Equatable, Sendable {
        /// The reported power agrees with current × rail voltage.
        case verified(deviation: Double)
        /// It disagrees by more than the tolerance.
        case mismatch(deviation: Double)
        /// Current or rail voltage is missing or invalid.
        case unverifiable
    }

    static let tolerance = 0.20
    /// Below this both readings count as a (legal) zero: display off.
    static let zeroThresholdWatts = 0.05

    let sourceKey: String?
    let reportedWatts: HardwareReading<Double>
    let currentAmps: HardwareReading<Double>
    let railVoltageVolts: HardwareReading<Double>

    var verification: Verification? {
        guard let watts = reportedWatts.value else { return nil }
        guard let current = currentAmps.value, let voltage = railVoltageVolts.value else {
            return .unverifiable
        }
        let expected = current * voltage
        guard expected.isFinite else { return .unverifiable }
        if watts < Self.zeroThresholdWatts, expected < Self.zeroThresholdWatts {
            return .verified(deviation: 0)
        }
        guard expected >= Self.zeroThresholdWatts else {
            return .mismatch(deviation: .infinity)
        }
        let deviation = (watts - expected) / expected
        return abs(deviation) <= Self.tolerance
            ? .verified(deviation: deviation)
            : .mismatch(deviation: deviation)
    }

    /// What the power card may show: unsupported without either key, the
    /// value only after a passing check, otherwise invalid ("—").
    var displayWatts: HardwareReading<Double> {
        switch reportedWatts {
        case .unsupported: return .unsupported
        case .invalid: return .invalid
        case let .value(watts):
            if case .verified = verification { return .value(watts) }
            return .invalid
        }
    }

    static let unsupported = BacklightPowerReading(
        sourceKey: nil,
        reportedWatts: .unsupported,
        currentAmps: .unsupported,
        railVoltageVolts: .unsupported
    )
}

/// The SMC's whole-computer power readings (D57 ①).
struct SMCPowerTelemetry: Equatable, Sendable {
    /// `PSTR`: the whole computer.
    var systemPowerWatts: HardwareReading<Double>
    /// `PDTR`, `VD0R`, `ID0R`: measured power input (not the negotiated value).
    var inputPowerWatts: HardwareReading<Double>
    var inputVoltageVolts: HardwareReading<Double>
    var inputCurrentAmps: HardwareReading<Double>
    /// `PPBR`, as reported ("电池轨（SMC）"): only a reference in the
    /// battery row's third level (D57 supplement). On Mac17,9 it is positive
    /// while the battery supplies power; its sign while charging has not
    /// been measured. The row itself is `battery.rowPowerWatts` (`B0AP`).
    var batteryPowerWatts: HardwareReading<Double>
    /// `PZC0`: the SMC's chip power estimate, a cross-check for the Energy
    /// Model sum (meaning not public; within 1 W of the sum on Mac17,9).
    var chipPowerReferenceWatts: HardwareReading<Double>
    var backlight: BacklightPowerReading
    var battery: SMCBatteryTelemetry

    static let unsupported = SMCPowerTelemetry(
        systemPowerWatts: .unsupported,
        inputPowerWatts: .unsupported,
        inputVoltageVolts: .unsupported,
        inputCurrentAmps: .unsupported,
        batteryPowerWatts: .unsupported,
        chipPowerReferenceWatts: .unsupported,
        backlight: .unsupported,
        battery: .unsupported
    )
}

/// Read-only SMC power, battery and backlight readings. Keys are decoded by
/// key and platform (`SMCValueDecoder`) and range-checked; nothing is
/// written. SMC and registry reads need no private-API allowlist entry.
enum SMCPowerTelemetryService {
    static let systemPower = SMCMeasurementSpec("PSTR", range: 0...1_000)
    static let inputPower = SMCMeasurementSpec("PDTR", range: 0...1_000)
    static let inputVoltage = SMCMeasurementSpec("VD0R", range: 0...60)
    static let inputCurrent = SMCMeasurementSpec("ID0R", range: 0...20)
    static let batteryPower = SMCMeasurementSpec("PPBR", range: -1_000...1_000)
    static let chipPowerReference = SMCMeasurementSpec("PZC0", range: 0...1_000)
    /// `PBwo` (Stats: M5 base, A18 Pro) is looked for before `PDBR`.
    static let backlightPowerKeys = ["PBwo", "PDBR"]
    static let backlightPowerRange: ClosedRange<Double> = 0...200
    static let backlightCurrent = SMCMeasurementSpec("IDBR", range: 0...20)
    static let railVoltage = SMCMeasurementSpec("VP0R", range: 0...30)

    static let batteryCurrent = SMCMeasurementSpec("B0AC", scale: 0.001, range: -30...30)
    static let batteryVoltage = SMCMeasurementSpec("B0AV", scale: 0.001, range: 1...30)
    static let batteryNetPower = SMCMeasurementSpec("B0AP", scale: 0.001, range: -1_000...1_000)
    static let batteryTemperature = SMCMeasurementSpec("TB0T", range: 5...130)
    /// 0.1 K.
    static let batteryTemperatureKelvin = SMCMeasurementSpec("B0AT", scale: 0.1, offset: -273.15, range: 5...130)
    static let cellVoltageKeys = ["BC1V", "BC2V", "BC3V", "BC4V"]
    static let cellVoltageRange: ClosedRange<Double> = 2...5

    /// One SMC pass on the caller's (background) thread.
    static func currentTelemetry(connection: SMCReadSession = .shared) -> SMCPowerTelemetry {
        connection.withReadPass(fallback: telemetry(read: { _ in .unreadable }, platform: connection.platform)) { reader in
            telemetry(read: { reader.readRaw($0) }, platform: reader.platform)
        }
    }

    static func currentBatteryTelemetry(connection: SMCReadSession = .shared) -> SMCBatteryTelemetry {
        connection.withReadPass(fallback: batteryTelemetry(read: { _ in .unreadable }, platform: connection.platform)) { reader in
            batteryTelemetry(read: { reader.readRaw($0) }, platform: reader.platform)
        }
    }

    static func telemetry(
        read: (String) -> SMCKeyRead,
        platform: SMCPlatform
    ) -> SMCPowerTelemetry {
        SMCPowerTelemetry(
            systemPowerWatts: systemPower.reading(read(systemPower.key), platform: platform),
            inputPowerWatts: inputPower.reading(read(inputPower.key), platform: platform),
            inputVoltageVolts: inputVoltage.reading(read(inputVoltage.key), platform: platform),
            inputCurrentAmps: inputCurrent.reading(read(inputCurrent.key), platform: platform),
            batteryPowerWatts: batteryPower.reading(read(batteryPower.key), platform: platform),
            chipPowerReferenceWatts: chipPowerReference.reading(read(chipPowerReference.key), platform: platform),
            backlight: backlight(read: read, platform: platform),
            battery: batteryTelemetry(read: read, platform: platform)
        )
    }

    static func backlight(
        read: (String) -> SMCKeyRead,
        platform: SMCPlatform
    ) -> BacklightPowerReading {
        for key in backlightPowerKeys {
            let raw = read(key)
            if case .missing = raw { continue }
            let spec = SMCMeasurementSpec(key, range: backlightPowerRange)
            return BacklightPowerReading(
                sourceKey: key,
                reportedWatts: spec.reading(raw, platform: platform),
                currentAmps: backlightCurrent.reading(read(backlightCurrent.key), platform: platform),
                railVoltageVolts: railVoltage.reading(read(railVoltage.key), platform: platform)
            )
        }
        return .unsupported
    }

    static func batteryTelemetry(
        read: (String) -> SMCKeyRead,
        platform: SMCPlatform
    ) -> SMCBatteryTelemetry {
        let temperatureCandidates = [batteryTemperature, batteryTemperatureKelvin].map { spec in
            (key: spec.key, reading: spec.reading(read(spec.key), platform: platform))
        }
        // The first key with a value, else the first that exists (invalid),
        // else unsupported.
        let temperature = temperatureCandidates.first { $0.reading.value != nil }
            ?? temperatureCandidates.first { $0.reading.isSupported }
        let cells = cellVoltageKeys.compactMap { key -> HardwareReading<Double>? in
            let reading = SMCMeasurementSpec(key, scale: 0.001, range: cellVoltageRange)
                .reading(read(key), platform: platform)
            return reading.isSupported ? reading : nil
        }
        return SMCBatteryTelemetry(
            currentAmps: batteryCurrent.reading(read(batteryCurrent.key), platform: platform),
            voltageVolts: batteryVoltage.reading(read(batteryVoltage.key), platform: platform),
            powerWatts: batteryNetPower.reading(read(batteryNetPower.key), platform: platform),
            temperatureCelsius: temperature?.reading ?? .unsupported,
            temperatureSourceKey: temperature?.key,
            cellVoltages: cells
        )
    }
}

/// Built-in display brightness (`AppleARMBacklight` ›
/// `IODisplayParameters` › `BrightnessMilliNits` › `value`), public IOKit.
enum DisplayBacklightService {
    static let validNits: ClosedRange<Double> = 0...10_000

    static func currentBrightnessNits() -> HardwareReading<Double> {
        guard let matching = IOServiceMatching("AppleARMBacklight") else { return .unsupported }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return .unsupported }
        defer { IOObjectRelease(service) }
        let parameters = IORegistryEntryCreateCFProperty(
            service, "IODisplayParameters" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]
        return brightnessNits(displayParameters: parameters)
    }

    static func brightnessNits(displayParameters: [String: Any]?) -> HardwareReading<Double> {
        guard let displayParameters,
              let milliNits = displayParameters["BrightnessMilliNits"] as? [String: Any] else {
            return .unsupported
        }
        guard let raw = (milliNits["value"] as? NSNumber)?.doubleValue else { return .invalid }
        let nits = raw / 1_000
        return nits.isFinite && validNits.contains(nits) ? .value(nits) : .invalid
    }
}

/// The ambient light sensor's illuminance: any service with a `CurrentLux`
/// property (public property-exists matching, no class name hard-coded).
enum AmbientLightService {
    static let validLux: ClosedRange<Double> = 0...200_000

    static func currentLux() -> HardwareReading<Double> {
        let matching = ["IOPropertyExistsMatch": "CurrentLux"] as NSDictionary as CFDictionary
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return .unsupported }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(
            service, "CurrentLux" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
        return lux(value)
    }

    static func lux(_ rawValue: Any?) -> HardwareReading<Double> {
        guard let rawValue else { return .unsupported }
        guard let lux = (rawValue as? NSNumber)?.doubleValue,
              lux.isFinite, validLux.contains(lux) else { return .invalid }
        return .value(lux)
    }
}
