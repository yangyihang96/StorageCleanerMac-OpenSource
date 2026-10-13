import Foundation
import XCTest
@testable import StorageCleanerMac

/// This Mac's real readings through the production readers (read-only:
/// SMC read selectors, registry properties, IOReport samples). Skipped on a
/// Mac without the SMC power keys. Prints the values for the batch handoff.
final class MiniSensorsLiveReadingTests: XCTestCase {
    func testThisMacsLiveReadingsAreInPlausibleRanges() throws {
        let clock = ContinuousClock()
        var smc = SMCPowerTelemetry.unsupported
        let smcDuration = clock.measure { smc = SMCPowerTelemetryService.currentTelemetry() }
        guard let system = smc.systemPowerWatts.value else {
            throw XCTSkip("This Mac does not expose the SMC power keys.")
        }
        XCTAssertTrue((1...500).contains(system))

        var lux = HardwareReading<Double>.unsupported
        let luxDuration = clock.measure { lux = AmbientLightService.currentLux() }
        let nits = DisplayBacklightService.currentBrightnessNits()
        let battery = NativeBatteryElectricalService.snapshot()

        let sampler = SoCPowerSampler()
        let first = sampler.sample()
        Thread.sleep(forTimeInterval: 2.3)
        var second = SoCPowerReading.unsupported
        let socDuration = clock.measure { second = sampler.sample() }

        func text(_ reading: HardwareReading<Double>, _ unit: String) -> String {
            switch reading {
            case .unsupported: "unsupported"
            case .invalid: "invalid"
            case let .value(value): String(format: "%.3f %@", value, unit)
            }
        }
        var lines = [
            "PSTR \(text(smc.systemPowerWatts, "W"))",
            "PDTR \(text(smc.inputPowerWatts, "W")) VD0R \(text(smc.inputVoltageVolts, "V")) ID0R \(text(smc.inputCurrentAmps, "A"))",
            "PPBR \(text(smc.batteryPowerWatts, "W")) battery row \(text(smc.battery.rowPowerWatts, "W")) direction \(String(describing: smc.battery.currentDirection))",
            "backlight \(smc.backlight.sourceKey ?? "-") \(text(smc.backlight.reportedWatts, "W")) IDBR \(text(smc.backlight.currentAmps, "A")) VP0R \(text(smc.backlight.railVoltageVolts, "V")) check \(String(describing: smc.backlight.verification)) shown \(text(smc.backlight.displayWatts, "W"))",
            "brightness \(text(nits, "nits")) lux \(text(lux, "lx"))",
            "PZC0 \(text(smc.chipPowerReferenceWatts, "W"))",
            "B0AC \(text(smc.battery.currentAmps, "A")) B0AV \(text(smc.battery.voltageVolts, "V")) B0AP \(text(smc.battery.powerWatts, "W")) temp[\(smc.battery.temperatureSourceKey ?? "-")] \(text(smc.battery.temperatureCelsius, "C"))",
            "cells " + smc.battery.cellVoltages.map { text($0, "V") }.joined(separator: ", "),
            "electrical source \(String(describing: battery?.electricalSource)) usbOut \(String(describing: battery?.usbPowerOut))",
            "first window total \(String(describing: first.total))",
            "chip total \(String(describing: second.total?.watts)) updating \(String(describing: second.total?.isUpdating)) cpu \(String(describing: second.cpu?.watts))",
        ]
        lines += second.items.map {
            "  \($0.component.rawValue) \(String(describing: $0.power.watts)) [\($0.channelNames.joined(separator: ","))]"
        }
        lines.append("unsupported \(second.unsupportedComponents.map(\.rawValue))")
        let thermal = SystemMonitorService.temperatureAndFanReadings()
        lines.append("chip \(String(describing: thermal.chipTemperatureCelsius)) inferred \(thermal.inferredTemperatureZones.map(\.rawValue).sorted())")
        lines += (thermal.temperatureReadings ?? []).map { String(format: "  zone %@ %.1f C", $0.zone.rawValue, $0.celsius) }
        let cores = (thermal.temperatureDetails ?? []).filter { [.superCores, .performanceCores].contains($0.zone) }.map(\.celsius)
        if !cores.isEmpty { lines.append(String(format: "  core average %.1f C over %d", cores.reduce(0, +) / Double(cores.count), cores.count)) }
        lines += (thermal.temperatureDetails ?? []).filter { $0.zone == nil }.map { String(format: "  probe %@ %.1f C", $0.id, $0.celsius) }
        lines.append("cost smc \(smcDuration) lux \(luxDuration) energyModel \(socDuration)")
        for line in lines { print("LIVE: \(line)") }

        if second.isSupported {
            XCTAssertNil(first.total?.watts, "the first window has no value")
            let total = try XCTUnwrap(second.total?.watts, "a batch arrives within 2.3 s")
            XCTAssertTrue((0.5...300).contains(total))
            XCTAssertFalse(second.items.contains { $0.power.watts.map { $0 < 0 } ?? false })
        }
    }
}
