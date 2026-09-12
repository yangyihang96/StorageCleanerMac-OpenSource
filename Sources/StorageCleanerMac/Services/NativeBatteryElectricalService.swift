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

enum NativeBatteryElectricalService {
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
        return snapshot(
            properties: properties,
            adapterProperties: adapterProperties,
            now: now
        )
    }

    static func snapshot(
        properties: [String: Any],
        adapterProperties: [String: Any] = [:],
        now: Date = Date()
    ) -> NativeBatteryElectricalSnapshot? {
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        let adapterDetails = properties["AdapterDetails"] as? [String: Any] ?? [:]
        let rawVoltage = firstNumber(keys: ["Voltage", "AppleRawBatteryVoltage"], primary: properties, secondary: batteryData)
        let rawAmperage = firstNumber(keys: ["Amperage", "InstantAmperage"], primary: properties, secondary: batteryData)
        let rawTemperature = firstNumber(keys: ["Temperature", "VirtualTemperature"], primary: properties, secondary: batteryData)

        let voltage = normalizedVoltage(rawVoltage)
        let amperage = normalizedAmperage(rawAmperage)
        let temperature = normalizedTemperature(rawTemperature)
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
        let power = voltage.flatMap { voltage in
            amperage.map { voltage * $0 }
        }

        guard voltage != nil
            || amperage != nil
            || temperature != nil
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
            condition: condition
        )
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
