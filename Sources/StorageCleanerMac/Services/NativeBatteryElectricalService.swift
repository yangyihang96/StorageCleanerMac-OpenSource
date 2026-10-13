import Foundation
import IOKit
import IOKit.ps

struct NativeBatteryElectricalSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let voltageVolts: Double?
    let amperageAmps: Double?
    let powerWatts: Double?
    let temperatureCelsius: Double?
    let adapterPowerWatts: Double?
    let adapterVoltageVolts: Double?
    let adapterAmperageAmps: Double?
    let adapterName: String?
    let designCapacityMAh: Int?
    let currentCapacityMAh: Int?
    let maximumCapacityMAh: Int?
    let cycleCount: Int?
    let condition: BatteryCondition?
    /// BOARD N16-5/6: the whole computer's load while on external power
    /// (AppleSmartBattery PowerTelemetryData.SystemLoad), when consistent.
    var systemLoadWatts: Double? = nil
    /// D57: where current, voltage and power come from. The SMC battery
    /// keys update about once a second; AppleSmartBattery's only once a
    /// minute, so it is a fallback and is labelled as such.
    var electricalSource: BatteryElectricalSource = .batteryController
    /// The battery current and voltage under D57's no-value rule.
    var currentReading: HardwareReading<Double> = .unsupported
    var voltageReading: HardwareReading<Double> = .unsupported
    /// Battery temperature under the no-value rule and its source key
    /// (`TB0T`, `B0AT`, or AppleSmartBattery's `Temperature`).
    var temperatureReading: HardwareReading<Double> = .unsupported
    var temperatureSource: String? = nil
    /// Cell voltages (`BC1V`…), only cells whose key exists.
    var cellVoltages: [HardwareReading<Double>] = []
    /// Power this Mac supplies through its USB-C ports
    /// (AppleSmartBattery `PowerOutDetails`).
    var usbPowerOut: HardwareReading<[USBPowerOutPort]> = .unsupported
    /// What `powerWatts` is computed from (the energy integration labels its
    /// samples with it); nil without a power reading.
    var powerBasis: BatteryPowerBasis? = nil

    var hasBatteryData: Bool {
        voltageVolts != nil
            || amperageAmps != nil
            || temperatureCelsius != nil
            || designCapacityMAh != nil
            || currentCapacityMAh != nil
            || maximumCapacityMAh != nil
            || cycleCount != nil
            || condition != nil
    }

    var hasAdapterData: Bool {
        adapterPowerWatts != nil
            || adapterVoltageVolts != nil
            || adapterAmperageAmps != nil
            || adapterName != nil
    }
}

enum BatteryElectricalSource: Equatable, Sendable {
    /// SMC `B0AC`/`B0AV`/`B0AP`, about once a second.
    case smc
    /// AppleSmartBattery `Voltage`/`Amperage`, about once a minute.
    case batteryController
}

/// Where the battery power (`powerWatts`) comes from.
enum BatteryPowerBasis: Equatable, Sendable {
    /// SMC `B0AP`, signed by `B0AC`.
    case smcPowerKey
    /// SMC `B0AV × B0AC` (a Mac without `B0AP`).
    case smcVoltageTimesCurrent
    /// AppleSmartBattery `Voltage × Amperage`, about once a minute.
    case batteryController
}

/// One USB-C port's outgoing power (`PowerOutDetails[].Watts`, mW).
struct USBPowerOutPort: Equatable, Sendable, Identifiable {
    let portIndex: Int?
    let watts: Double
    var id: String { portIndex.map(String.init) ?? "port" }
}

enum NativeBatteryElectricalService {
    static let validUSBPowerOutWatts: ClosedRange<Double> = 0...240

    static func snapshot(now: Date = Date()) -> NativeBatteryElectricalSnapshot? {
        var properties: [String: Any] = [:]
        if let matching = IOServiceMatching("AppleSmartBattery") {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            if service != 0 {
                defer { IOObjectRelease(service) }
                var unmanagedProperties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(
                    service,
                    &unmanagedProperties,
                    kCFAllocatorDefault,
                    0
                ) == KERN_SUCCESS,
                let values = unmanagedProperties?.takeRetainedValue() as? [String: Any] {
                    properties = values
                }
            }
        }

        let adapterProperties = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any] ?? [:]
        // The SMC battery keys only exist with a battery; skip the SMC pass
        // on a desktop.
        let smcBattery = properties.isEmpty
            ? SMCBatteryTelemetry.unsupported
            : SMCPowerTelemetryService.currentBatteryTelemetry()
        return snapshot(
            properties: properties,
            adapterProperties: adapterProperties,
            smcBattery: smcBattery,
            now: now
        )
    }

    static func snapshot(
        properties: [String: Any],
        adapterProperties: [String: Any] = [:],
        smcBattery: SMCBatteryTelemetry = .unsupported,
        now: Date = Date()
    ) -> NativeBatteryElectricalSnapshot? {
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        let adapterDetails = properties["AdapterDetails"] as? [String: Any] ?? [:]
        let rawVoltage = firstNumber(keys: ["Voltage", "AppleRawBatteryVoltage"], primary: properties, secondary: batteryData)
        let rawAmperage = firstNumber(keys: ["Amperage", "InstantAmperage"], primary: properties, secondary: batteryData)
        let rawTemperature = firstNumber(keys: ["Temperature", "VirtualTemperature"], primary: properties, secondary: batteryData)

        let controllerVoltage = normalizedVoltage(rawVoltage)
        let controllerAmperage = normalizedAmperage(rawAmperage)
        let controllerTemperature = normalizedTemperature(rawTemperature)
        // D57: the SMC's live battery keys first; AppleSmartBattery's
        // once-a-minute values only when the SMC does not have the key.
        let voltageReading = smcBattery.voltageVolts.isSupported
            ? smcBattery.voltageVolts
            : controllerVoltage.map(HardwareReading.value) ?? .unsupported
        let currentReading = smcBattery.currentAmps.isSupported
            ? smcBattery.currentAmps
            : controllerAmperage.map(HardwareReading.value) ?? .unsupported
        let usesSMC = smcBattery.voltageVolts.isSupported && smcBattery.currentAmps.isSupported
        let voltage = voltageReading.value
        let amperage = currentReading.value
        let temperatureReading: HardwareReading<Double>
        let temperatureSource: String?
        if smcBattery.temperatureCelsius.isSupported {
            temperatureReading = smcBattery.temperatureCelsius
            temperatureSource = smcBattery.temperatureSourceKey
        } else if let controllerTemperature {
            temperatureReading = .value(controllerTemperature)
            temperatureSource = "AppleSmartBattery"
        } else {
            temperatureReading = rawTemperature == nil ? .unsupported : .invalid
            temperatureSource = rawTemperature == nil ? nil : "AppleSmartBattery"
        }
        let temperature = temperatureReading.value
        let adapterVoltage = normalizedVoltage(
            numericValue(adapterProperties["AdapterVoltage"])
                ?? numericValue(adapterDetails["AdapterVoltage"])
        )
        let adapterAmperage = normalizedAmperage(
            numericValue(adapterProperties["Current"])
                ?? numericValue(adapterDetails["Current"])
        )
        let adapterPower = normalizedAdapterPower(
            numericValue(adapterProperties["Watts"])
                ?? numericValue(adapterDetails["Watts"])
        ) ?? adapterVoltage.flatMap { voltage in
            adapterAmperage.map { voltage * $0 }
        }
        let adapterName = firstString(
            keys: ["Description", "Name"],
            primary: adapterProperties,
            secondary: adapterDetails
        )
        let designCapacity = normalizedCapacity(
            firstNumber(keys: ["DesignCapacity"], primary: properties, secondary: batteryData)
        )
        let currentCapacity = normalizedCapacity(
            firstNumber(keys: ["AppleRawCurrentCapacity"], primary: properties, secondary: batteryData)
        )
        let maximumCapacity = normalizedCapacity(
            firstNumber(keys: ["AppleRawMaxCapacity"], primary: properties, secondary: batteryData)
        )
        let cycleCount = normalizedCycleCount(
            firstNumber(keys: ["CycleCount"], primary: properties, secondary: batteryData)
        )
        let condition = batteryCondition(
            firstString(keys: ["BatteryHealth", "Condition"], primary: properties, secondary: batteryData)
        )
        // PowerTelemetryData is a once-a-minute average: check it against
        // the battery controller's own power (same cadence), not the live
        // SMC B0AP, which can differ a lot within that minute.
        let controllerPower = controllerVoltage.flatMap { voltage in
            controllerAmperage.map { voltage * $0 }
        }
        // D57 supplement: the battery power everywhere (card, third level,
        // history, energy integration) is the battery row's SMC value, B0AP
        // signed by B0AC, or B0AV × B0AC without B0AP (incremental review
        // P2-2); the battery controller's V × I only without those keys.
        let power: Double?
        let powerBasis: BatteryPowerBasis?
        switch smcBattery.rowPowerBasis {
        case .batteryPowerKey?:
            power = smcBattery.rowPowerWatts.value
            powerBasis = .smcPowerKey
        case .voltageTimesCurrent?:
            power = smcBattery.rowPowerWatts.value
            powerBasis = .smcVoltageTimesCurrent
        case nil:
            power = controllerPower
            powerBasis = controllerPower == nil ? nil : .batteryController
        }
        let usbPowerOut = usbPowerOut(properties["PowerOutDetails"])
        let systemLoad = systemLoadWatts(
            telemetry: properties["PowerTelemetryData"] as? [String: Any] ?? [:],
            externalConnected: properties["ExternalConnected"] as? Bool,
            batteryPowerWatts: controllerPower
        )

        guard voltage != nil
            || amperage != nil
            || temperature != nil
            || !smcBattery.cellVoltages.isEmpty
            || adapterPower != nil
            || adapterVoltage != nil
            || adapterAmperage != nil
            || adapterName != nil
            || designCapacity != nil
            || currentCapacity != nil
            || maximumCapacity != nil
            || cycleCount != nil
            || condition != nil else { return nil }
        return NativeBatteryElectricalSnapshot(
            generatedAt: now,
            voltageVolts: voltage,
            amperageAmps: amperage,
            powerWatts: power,
            temperatureCelsius: temperature,
            adapterPowerWatts: adapterPower,
            adapterVoltageVolts: adapterVoltage,
            adapterAmperageAmps: adapterAmperage,
            adapterName: adapterName,
            designCapacityMAh: designCapacity,
            currentCapacityMAh: currentCapacity,
            maximumCapacityMAh: maximumCapacity,
            cycleCount: cycleCount,
            condition: condition,
            systemLoadWatts: systemLoad,
            electricalSource: usesSMC ? .smc : .batteryController,
            currentReading: currentReading,
            voltageReading: voltageReading,
            temperatureReading: temperatureReading,
            temperatureSource: temperatureSource,
            cellVoltages: smcBattery.cellVoltages,
            usbPowerOut: usbPowerOut,
            powerBasis: power == nil ? nil : powerBasis
        )
    }

    /// `PowerOutDetails`: one entry per USB-C port, `Watts` in milliwatts
    /// (Mac17,9 port 2: 1 258 mW = 5.206 V × 0.241 A). Missing → unsupported;
    /// a port without `Watts` is skipped (D57 ④: no value, no row), and when
    /// no port has one there is no reading (unsupported); not an array, or a
    /// `Watts` that is not a number or out of range → invalid; an empty or
    /// all-zero list is a legal zero.
    static func usbPowerOut(_ rawValue: Any?) -> HardwareReading<[USBPowerOutPort]> {
        guard let rawValue else { return .unsupported }
        guard let entries = rawValue as? [[String: Any]] else { return .invalid }
        var ports: [USBPowerOutPort] = []
        for entry in entries {
            guard let rawWatts = entry["Watts"] else { continue }
            guard let milliwatts = numericValue(rawWatts), milliwatts.isFinite else { return .invalid }
            let watts = milliwatts / 1_000
            guard validUSBPowerOutWatts.contains(watts) else { return .invalid }
            ports.append(USBPowerOutPort(
                portIndex: numericValue(entry["PortIndex"]).map { Int($0) },
                watts: watts
            ))
        }
        if !entries.isEmpty, ports.isEmpty { return .unsupported }
        return .value(ports)
    }

    /// The whole computer's load in watts while external power is connected:
    /// PowerTelemetryData.SystemLoad (mW). The block's own input reading must
    /// agree with itself (SystemVoltageIn mV × SystemCurrentIn mA ≈
    /// SystemPowerIn mW), and the load must be supplied by that input plus
    /// what the battery gives (`batteryPowerWatts`, negative while
    /// discharging; review P2-5), each within max(1 W, 10%); otherwise there
    /// is no reading. On battery the battery side (voltage × current) is
    /// measured instead.
    static func systemLoadWatts(
        telemetry: [String: Any],
        externalConnected: Bool?,
        batteryPowerWatts: Double? = nil
    ) -> Double? {
        guard externalConnected == true,
              let load = numericValue(telemetry["SystemLoad"]),
              let powerIn = numericValue(telemetry["SystemPowerIn"]),
              let voltage = numericValue(telemetry["SystemVoltageIn"]),
              let current = numericValue(telemetry["SystemCurrentIn"]),
              load > 0, powerIn > 0, voltage > 0, current > 0 else { return nil }
        let inputFromVoltageAndCurrent = voltage * current / 1_000
        guard inputFromVoltageAndCurrent.isFinite,
              abs(inputFromVoltageAndCurrent - powerIn) <= max(1_000, powerIn * 0.1) else { return nil }
        // The battery may discharge on external power when the adapter is too
        // small; a charging or unknown battery supplies nothing.
        let batteryDischarge = batteryPowerWatts.map { $0.isFinite ? max(0, -$0) * 1_000 : 0 } ?? 0
        let supply = powerIn + batteryDischarge
        guard load <= supply + max(1_000, supply * 0.1) else { return nil }
        let watts = load / 1_000
        return watts.isFinite && (0.1...1_000).contains(watts) ? watts : nil
    }

    private static func firstNumber(
        keys: [String],
        primary: [String: Any],
        secondary: [String: Any]
    ) -> Double? {
        for key in keys {
            if let value = numericValue(primary[key]) {
                return value
            }
            if let value = numericValue(secondary[key]) {
                return value
            }
        }
        return nil
    }

    private static func numericValue(_ rawValue: Any?) -> Double? {
        if let value = rawValue as? NSNumber {
            return value.doubleValue
        }
        if let value = rawValue as? Int {
            return Double(value)
        }
        if let value = rawValue as? Int64 {
            return Double(value)
        }
        return nil
    }

    private static func firstString(
        keys: [String],
        primary: [String: Any],
        secondary: [String: Any]
    ) -> String? {
        for key in keys {
            for value in [primary[key], secondary[key]] {
                guard let text = value as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if (1...64).contains(trimmed.count) {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func normalizedVoltage(_ millivolts: Double?) -> Double? {
        guard let millivolts, millivolts.isFinite else { return nil }
        let volts = millivolts / 1_000
        return (0...30).contains(volts) ? volts : nil
    }

    private static func normalizedAmperage(_ milliamps: Double?) -> Double? {
        guard let milliamps, milliamps.isFinite else { return nil }
        let amps = milliamps / 1_000
        return (-20...20).contains(amps) ? amps : nil
    }

    private static func normalizedTemperature(_ hundredthsCelsius: Double?) -> Double? {
        guard let hundredthsCelsius, hundredthsCelsius.isFinite else { return nil }
        let celsius = hundredthsCelsius / 100
        return (0...100).contains(celsius) ? celsius : nil
    }

    private static func normalizedAdapterPower(_ watts: Double?) -> Double? {
        guard let watts, watts.isFinite, (1...1_000).contains(watts) else { return nil }
        return watts
    }

    private static func normalizedCapacity(_ milliampHours: Double?) -> Int? {
        guard let milliampHours,
              milliampHours.isFinite,
              (1...50_000).contains(milliampHours) else { return nil }
        return Int(milliampHours.rounded())
    }

    private static func normalizedCycleCount(_ value: Double?) -> Int? {
        guard let value, value.isFinite, (0...10_000).contains(value) else { return nil }
        return Int(value.rounded())
    }

    private static func batteryCondition(_ rawValue: String?) -> BatteryCondition? {
        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return nil }
        if ["good", "normal", "fair"].contains(normalized) {
            return .normal
        }
        if normalized.contains("service")
            || normalized.contains("poor")
            || normalized.contains("check battery")
            || normalized.contains("failure") {
            return .serviceRecommended
        }
        return .unknown
    }
}
