import Foundation
import XCTest
@testable import StorageCleanerMac

/// DECISIONS D57 ①: SMC keys are decoded by key and platform and range
/// checked; registry and IOReport values are read with their own units.
/// Byte fixtures are Mac17,9's own readings from the read-only research probe
/// (`StorageCleanerMac-evidence/round2/mini-sensors/probe/raw/smc_idle1.tsv`);
/// no serial number or other personal value is used.
final class MiniSensorsDecodingTests: XCTestCase {
    // MARK: - SMC byte order and types

    func testAppleSiliconBatteryIntegersAreLittleEndian() {
        // raw_hex column of the probe, decoded little-endian.
        XCTAssertEqual(decode("B0AV", "ui16", "0e30"), 12_302, "battery voltage, mV")
        XCTAssertEqual(decode("B0AC", "si16", "bcfc"), -836, "battery current, mA, discharging")
        XCTAssertEqual(decode("B0AP", "si32", "01d6ffff"), -10_751, "battery power, mW")
        XCTAssertEqual(decode("B0AT", "ui16", "1c0c"), 3_100, "battery temperature, 0.1 K")
        XCTAssertEqual(decode("BC1V", "ui16", "ff0f"), 4_095, "cell 1, mV")
        XCTAssertEqual(decode("B0CT", "ui16", "3d00"), 61, "cycle count, as the system report")
    }

    func testKeyCountIsBigEndianOnAppleSilicon() {
        XCTAssertEqual(decode("#KEY", "ui32", "00000e1d"), 3_613)
    }

    func testUnknownAppleSiliconIntegerKeysFailClosedInsteadOfGuessing() {
        XCTAssertNil(decode("XYZW", "ui16", "0e30"))
        XCTAssertNil(decode("XYZW", "si32", "01d6ffff"))
        // Single bytes have no byte order.
        XCTAssertEqual(decode("FNum", "ui8 ", "02"), 2)
        XCTAssertEqual(decode("AC-B", "si8 ", "ff"), -1)
    }

    func testIntelIntegersStayBigEndian() {
        XCTAssertEqual(decode("B0AV", "ui16", "3010", platform: .intel), 12_304)
        XCTAssertEqual(decode("B0AC", "si16", "fcbc", platform: .intel), -836)
        XCTAssertEqual(decode("XYZW", "ui32", "00000e1d", platform: .intel), 3_613)
    }

    func testFloatAndFixedPointTypes() throws {
        XCTAssertEqual(try XCTUnwrap(decode("PSTR", "flt ", "9eceaf42")), 87.9035, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(decode("PDBR", "flt ", "6a869540")), 4.67266, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(decode("F0Ac", "flt ", "00a89a45")), 4_949, accuracy: 0.001)
        XCTAssertEqual(decode("F0Ac", "fpe2", "1f40", platform: .intel), 2_000)
        XCTAssertEqual(decode("TC0P", "sp78", "2d80", platform: .intel), 45.5)
        XCTAssertNil(decode("PSTR", "flt ", "0000c07f"), "NaN is not a reading")
        XCTAssertNil(decode("PSTR", "flt ", "9ece"), "short payload")
        XCTAssertNil(decode("PSTR", "{fds", "00000000"), "unknown type")
    }

    func testMeasurementSpecsConvertUnitsAndRejectImplausibleValues() throws {
        let kelvin = SMCPowerTelemetryService.batteryTemperatureKelvin
        XCTAssertEqual(try XCTUnwrap(kelvin.reading(present("ui16", "1c0c"), platform: .appleSilicon).value), 36.85, accuracy: 0.001)
        XCTAssertEqual(SMCPowerTelemetryService.systemPower.reading(.missing, platform: .appleSilicon), .unsupported)
        XCTAssertEqual(SMCPowerTelemetryService.systemPower.reading(.unreadable, platform: .appleSilicon), .invalid)
        // 5 000 W is outside 0…1000 W: invalid, never clamped.
        XCTAssertEqual(
            SMCPowerTelemetryService.systemPower.reading(present("flt ", float(5_000)), platform: .appleSilicon),
            .invalid
        )
        XCTAssertEqual(
            SMCPowerTelemetryService.systemPower.reading(present("flt ", float(0)), platform: .appleSilicon),
            .value(0),
            "a legal zero stays a value"
        )
        // The old big-endian decode of B0AV (3.632 V) would still pass a
        // loose range; the little-endian value is the battery's 12.3 V.
        XCTAssertEqual(
            try XCTUnwrap(SMCPowerTelemetryService.batteryVoltage.reading(present("ui16", "0e30"), platform: .appleSilicon).value),
            12.302, accuracy: 0.0001
        )
    }

    // MARK: - SMC telemetry from a whole fixture

    func testMac17_9FixtureGivesEveryPowerReading() throws {
        let telemetry = SMCPowerTelemetryService.telemetry(read: Self.mac17_9.read, platform: .appleSilicon)
        XCTAssertEqual(try XCTUnwrap(telemetry.systemPowerWatts.value), 87.9035, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(telemetry.inputPowerWatts.value), 63.3567, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(telemetry.inputVoltageVolts.value), 19.4297, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(telemetry.inputCurrentAmps.value), 3.26081, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(telemetry.batteryPowerWatts.value), 11.4289, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(telemetry.chipPowerReferenceWatts.value), 45.0066, accuracy: 0.001)
        // The battery row: B0AP with B0AC's direction (discharging); PPBR
        // above is only the third level's reference (D57 supplement).
        XCTAssertEqual(try XCTUnwrap(telemetry.battery.rowPowerWatts.value), -10.751, accuracy: 0.0001)
        XCTAssertEqual(telemetry.battery.currentDirection, .discharging)
        XCTAssertEqual(try XCTUnwrap(telemetry.battery.currentAmps.value), -0.836, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(telemetry.battery.voltageVolts.value), 12.302, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(telemetry.battery.powerWatts.value), -10.751, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(telemetry.battery.temperatureCelsius.value), 36.7, accuracy: 0.001)
        XCTAssertEqual(telemetry.battery.temperatureSourceKey, "TB0T")
        XCTAssertEqual(telemetry.battery.cellVoltages.compactMap(\.value).map { ($0 * 1_000).rounded() }, [4_095, 4_100, 4_102])
        XCTAssertEqual(telemetry.backlight.sourceKey, "PDBR")
        XCTAssertEqual(try XCTUnwrap(telemetry.backlight.displayWatts.value), 4.67266, accuracy: 0.0001)
    }

    func testBatteryTemperatureFallsBackFromTB0TToB0AT() throws {
        var fixture = Self.mac17_9
        fixture.keys["TB0T"] = nil
        let battery = SMCPowerTelemetryService.batteryTelemetry(read: fixture.read, platform: .appleSilicon)
        XCTAssertEqual(battery.temperatureSourceKey, "B0AT")
        XCTAssertEqual(try XCTUnwrap(battery.temperatureCelsius.value), 36.85, accuracy: 0.001)

        fixture.keys["B0AT"] = nil
        XCTAssertEqual(
            SMCPowerTelemetryService.batteryTelemetry(read: fixture.read, platform: .appleSilicon).temperatureCelsius,
            .unsupported
        )
    }

    // MARK: - Backlight check (IDBR × VP0R within ±20 %)

    func testBacklightIsShownOnlyWhenItAgreesWithCurrentTimesRailVoltage() throws {
        // Mac17,9: 4.67 W against 0.38157 A × 12.2473 V = 4.673 W.
        let passing = backlight(watts: 4.67266, current: 0.38157, rail: 12.2473)
        guard case let .verified(deviation)? = passing.verification else {
            return XCTFail("expected a passing check")
        }
        XCTAssertLessThan(abs(deviation), 0.01)
        XCTAssertEqual(try XCTUnwrap(passing.displayWatts.value), 4.67266, accuracy: 0.0001)

        // 20 % is the edge; beyond it the value is not shown.
        XCTAssertNotNil(backlight(watts: 5.5, current: 0.38157, rail: 12.2473).displayWatts.value, "+18 %")
        let failing = backlight(watts: 9.0, current: 0.38157, rail: 12.2473)
        guard case .mismatch? = failing.verification else { return XCTFail("expected a failing check") }
        XCTAssertEqual(failing.displayWatts, .invalid)
        XCTAssertEqual(backlight(watts: 2.0, current: 0.38157, rail: 12.2473).displayWatts, .invalid, "−57 %")

        // Without the current or the rail the check cannot pass.
        let unverifiable = BacklightPowerReading(
            sourceKey: "PDBR", reportedWatts: .value(4.67), currentAmps: .unsupported, railVoltageVolts: .value(12.2)
        )
        XCTAssertEqual(unverifiable.verification, .unverifiable)
        XCTAssertEqual(unverifiable.displayWatts, .invalid)

        // A dark display is a legal zero.
        XCTAssertEqual(backlight(watts: 0, current: 0, rail: 12.2).displayWatts, .value(0))
        XCTAssertEqual(BacklightPowerReading.unsupported.displayWatts, .unsupported)
    }

    /// Review: with the tolerance widened to 50 % every earlier case still
    /// passed. ±19 % is shown, ±21 % is "读数无效", on either side.
    func testBacklightCheckEdgeIsTwentyPercentOnBothSides() throws {
        let current = 0.38157, rail = 12.2473
        let expected = current * rail // 4.673 W
        for (factor, label) in [(1.19, "+19 %"), (0.81, "−19 %")] {
            let reading = backlight(watts: expected * factor, current: current, rail: rail)
            guard case let .verified(deviation)? = reading.verification else {
                return XCTFail("\(label) should pass the check")
            }
            XCTAssertEqual(deviation, factor - 1, accuracy: 1e-9, label)
            XCTAssertEqual(try XCTUnwrap(reading.displayWatts.value), expected * factor, accuracy: 1e-9, label)
        }
        for (factor, label) in [(1.21, "+21 %"), (0.79, "−21 %")] {
            let reading = backlight(watts: expected * factor, current: current, rail: rail)
            guard case let .mismatch(deviation)? = reading.verification else {
                return XCTFail("\(label) should fail the check")
            }
            XCTAssertEqual(deviation, factor - 1, accuracy: 1e-9, label)
            XCTAssertEqual(reading.displayWatts, .invalid, label)
        }
        XCTAssertEqual(BacklightPowerReading.tolerance, 0.20)
    }

    func testBacklightPrefersPBwoOverPDBR() {
        var fixture = Self.mac17_9
        fixture.keys["PBwo"] = .init("flt ", float(4.7))
        XCTAssertEqual(SMCPowerTelemetryService.backlight(read: fixture.read, platform: .appleSilicon).sourceKey, "PBwo")
        fixture.keys["PBwo"] = nil
        XCTAssertEqual(SMCPowerTelemetryService.backlight(read: fixture.read, platform: .appleSilicon).sourceKey, "PDBR")
        fixture.keys["PDBR"] = nil
        XCTAssertEqual(SMCPowerTelemetryService.backlight(read: fixture.read, platform: .appleSilicon), .unsupported)
    }

    // MARK: - Registry values

    func testRegistryBrightnessLuxAndUSBPowerOut() throws {
        XCTAssertEqual(
            try XCTUnwrap(DisplayBacklightService.brightnessNits(displayParameters: [
                "BrightnessMilliNits": ["min": 976, "value": 381_794, "max": 1_599_999]
            ]).value),
            381.794, accuracy: 0.001
        )
        XCTAssertEqual(DisplayBacklightService.brightnessNits(displayParameters: nil), .unsupported)
        XCTAssertEqual(DisplayBacklightService.brightnessNits(displayParameters: ["BrightnessMilliNits": ["max": 1]]), .invalid)

        XCTAssertEqual(AmbientLightService.lux(NSNumber(value: 161)), .value(161))
        XCTAssertEqual(AmbientLightService.lux(NSNumber(value: 0)), .value(0), "darkness is a legal zero")
        XCTAssertEqual(AmbientLightService.lux(nil), .unsupported)
        XCTAssertEqual(AmbientLightService.lux(NSNumber(value: -5)), .invalid)
        XCTAssertEqual(AmbientLightService.lux("161"), .invalid)

        // PowerOutDetails as read on Mac17,9 (port 2: 1 258 mW = 5.206 V × 0.241 A).
        let ports = NativeBatteryElectricalService.usbPowerOut([
            ["PortIndex": 2, "Watts": 1_258, "AdapterVoltage": 5_205, "Current": 239],
            ["PortIndex": 3, "Watts": 28],
        ])
        XCTAssertEqual(ports, .value([
            USBPowerOutPort(portIndex: 2, watts: 1.258),
            USBPowerOutPort(portIndex: 3, watts: 0.028),
        ]))
        XCTAssertEqual(NativeBatteryElectricalService.usbPowerOut(nil), .unsupported)
        XCTAssertEqual(NativeBatteryElectricalService.usbPowerOut([[String: Any]]()), .value([]))
        XCTAssertEqual(NativeBatteryElectricalService.usbPowerOut([["PortIndex": 2, "Watts": 999_999]]), .invalid)
        XCTAssertEqual(NativeBatteryElectricalService.usbPowerOut("nope"), .invalid)
    }

    /// Review item 5: one port without `Watts` made the whole group invalid,
    /// against the doc comment. Only that port is skipped now.
    func testUSBPowerOutSkipsOnlyThePortWithoutWatts() {
        XCTAssertEqual(
            NativeBatteryElectricalService.usbPowerOut([
                ["PortIndex": 1],
                ["PortIndex": 2, "Watts": 1_258],
            ]),
            .value([USBPowerOutPort(portIndex: 2, watts: 1.258)])
        )
        XCTAssertEqual(
            NativeBatteryElectricalService.usbPowerOut([["PortIndex": 1], ["PortIndex": 2]]),
            .unsupported,
            "no port has a value: no reading, not a zero"
        )
        XCTAssertEqual(
            NativeBatteryElectricalService.usbPowerOut([["PortIndex": 1, "Watts": "1258"], ["PortIndex": 2, "Watts": 1_258]]),
            .invalid,
            "a value that is not a number is still invalid"
        )
        XCTAssertEqual(
            NativeBatteryElectricalService.usbPowerOut([["PortIndex": 1, "Watts": 999_999], ["PortIndex": 2, "Watts": 1_258]]),
            .invalid,
            "an out-of-range value is still invalid"
        )
    }

    // MARK: - Battery electrical snapshot: SMC first

    func testBatteryElectricalUsesTheLiveSMCKeysBeforeTheBatteryController() throws {
        let smc = SMCPowerTelemetryService.batteryTelemetry(read: Self.mac17_9.read, platform: .appleSilicon)
        // AppleSmartBattery's once-a-minute values differ on purpose.
        let snapshot = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: ["Voltage": 12_311, "Amperage": -674, "CurrentCapacity": 80],
            smcBattery: smc
        ))
        XCTAssertEqual(snapshot.electricalSource, .smc)
        XCTAssertEqual(try XCTUnwrap(snapshot.voltageVolts), 12.302, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.amperageAmps), -0.836, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.powerWatts), -10.751, accuracy: 0.0001, "B0AP, not V × I")
        XCTAssertEqual(try XCTUnwrap(snapshot.temperatureCelsius), 36.7, accuracy: 0.001)
        XCTAssertEqual(snapshot.temperatureSource, "TB0T")
        XCTAssertEqual(snapshot.cellVoltages.count, 3)

        // Without the SMC keys the controller's values remain, labelled.
        let controllerOnly = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: ["Voltage": 12_311, "Amperage": -674],
            smcBattery: .unsupported
        ))
        XCTAssertEqual(controllerOnly.electricalSource, .batteryController)
        XCTAssertEqual(try XCTUnwrap(controllerOnly.voltageVolts), 12.311, accuracy: 0.0001)
        XCTAssertEqual(controllerOnly.temperatureReading, .unsupported, "macOS 27.2 has no Temperature")

        // A present but out-of-range SMC key is invalid, not replaced.
        var broken = Self.mac17_9
        broken.keys["B0AV"] = .init("ui16", "0000")
        let invalid = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: ["Voltage": 12_311, "Amperage": -674],
            smcBattery: SMCPowerTelemetryService.batteryTelemetry(read: broken.read, platform: .appleSilicon)
        ))
        XCTAssertEqual(invalid.voltageReading, .invalid)
        XCTAssertNil(invalid.voltageVolts)
    }

    /// D57 supplement: the battery power everywhere (card, third level,
    /// history, energy integration) is B0AP with the sign of B0AC's
    /// direction; PPBR is not used for it.
    func testBatteryPowerIsB0APSignedByTheCurrentsDirection() throws {
        let discharging = SMCPowerTelemetryService.telemetry(read: Self.mac17_9.read, platform: .appleSilicon)
        XCTAssertEqual(discharging.battery.currentDirection, .discharging)
        XCTAssertEqual(try XCTUnwrap(discharging.battery.rowPowerWatts.value), -10.751, accuracy: 0.0001, "B0AP, not PPBR's 11.43 W")

        var charging = Self.mac17_9
        charging.keys["B0AC"] = .init("si16", "e204") // +1 250 mA
        charging.keys["B0AP"] = .init("si32", "283c0000") // +15 400 mW
        let chargingBattery = SMCPowerTelemetryService.batteryTelemetry(read: charging.read, platform: .appleSilicon)
        XCTAssertEqual(chargingBattery.currentDirection, .charging)
        XCTAssertEqual(try XCTUnwrap(chargingBattery.rowPowerWatts.value), 15.4, accuracy: 0.0001)

        // The current's direction wins over B0AP's own sign.
        var disagreeing = Self.mac17_9
        disagreeing.keys["B0AP"] = .init("si32", "ff290000") // +10 751 mW while B0AC is -0.836 A
        let override = SMCPowerTelemetryService.batteryTelemetry(read: disagreeing.read, platform: .appleSilicon)
        XCTAssertEqual(try XCTUnwrap(override.rowPowerWatts.value), -10.751, accuracy: 0.0001)

        // Without a direction from B0AC (about 0 A, or no key) B0AP keeps its own sign.
        var idle = Self.mac17_9
        idle.keys["B0AC"] = .init("si16", "0200") // 2 mA
        let idleBattery = SMCPowerTelemetryService.batteryTelemetry(read: idle.read, platform: .appleSilicon)
        XCTAssertNil(idleBattery.currentDirection)
        XCTAssertEqual(try XCTUnwrap(idleBattery.rowPowerWatts.value), -10.751, accuracy: 0.0001)
        var noCurrent = Self.mac17_9
        noCurrent.keys["B0AC"] = nil
        XCTAssertNil(SMCPowerTelemetryService.batteryTelemetry(read: noCurrent.read, platform: .appleSilicon).currentDirection)

        // The snapshot behind the history and the energy integration agrees,
        // and its source label says where the value comes from.
        let snapshot = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: ["Voltage": 12_311, "Amperage": -674], smcBattery: override
        ))
        XCTAssertEqual(try XCTUnwrap(snapshot.powerWatts), -10.751, accuracy: 0.0001)
        XCTAssertEqual(SystemEnergyPowerSample.batterySource(snapshot), SystemEnergyPowerSample.batterySMCSource)
        let controllerOnly = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: ["Voltage": 12_311, "Amperage": -674], smcBattery: .unsupported
        ))
        XCTAssertEqual(try XCTUnwrap(controllerOnly.powerWatts), 12.311 * -0.674, accuracy: 0.0001)
        XCTAssertEqual(SystemEnergyPowerSample.batterySource(controllerOnly), SystemEnergyPowerSample.batteryControllerSource)
        XCTAssertFalse(SystemEnergyPowerSample.batterySMCSource.contains("voltage-current"))
    }

    /// Incremental review P2-2: on a Mac with `B0AV`/`B0AC` but no `B0AP`
    /// the card hid the battery row while the history and the energy
    /// integration used V × I labelled as `B0AP`. Now all of them use
    /// `B0AV × B0AC` (sign from `B0AC`), labelled as such.
    func testWithoutB0APTheBatteryPowerIsVoltageTimesCurrentEverywhere() throws {
        func battery(_ change: (inout SMCFixture) -> Void) -> SMCBatteryTelemetry {
            var fixture = Self.mac17_9
            fixture.keys["B0AP"] = nil
            change(&fixture)
            return SMCPowerTelemetryService.batteryTelemetry(read: fixture.read, platform: .appleSilicon)
        }
        let discharging = battery { _ in }
        XCTAssertEqual(discharging.rowPowerBasis, .voltageTimesCurrent)
        XCTAssertEqual(try XCTUnwrap(discharging.rowPowerWatts.value), -10.284, accuracy: 0.001, "12.302 V × -0.836 A")
        let charging = battery { $0.keys["B0AC"] = .init("si16", "e204") } // +1 250 mA
        XCTAssertEqual(try XCTUnwrap(charging.rowPowerWatts.value), 15.378, accuracy: 0.001)
        XCTAssertEqual(battery { $0.keys["B0AV"] = .init("ui16", "0000") }.rowPowerWatts, .invalid, "0 V is out of range")
        XCTAssertEqual(battery { $0.keys["B0AC"] = nil }.rowPowerWatts, .unsupported)
        XCTAssertNil(battery { $0.keys["B0AC"] = nil }.rowPowerBasis)
        XCTAssertEqual(
            SMCPowerTelemetryService.batteryTelemetry(read: Self.mac17_9.read, platform: .appleSilicon).rowPowerBasis,
            .batteryPowerKey, "B0AP first when it exists"
        )

        // The snapshot behind the history and the integration: the same
        // value as the card, labelled as voltage × current from the SMC.
        let snapshot = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: ["Voltage": 12_311, "Amperage": -674], smcBattery: discharging
        ))
        XCTAssertEqual(try XCTUnwrap(snapshot.powerWatts), try XCTUnwrap(discharging.rowPowerWatts.value), accuracy: 1e-12)
        XCTAssertEqual(snapshot.powerBasis, .smcVoltageTimesCurrent)
        XCTAssertEqual(SystemEnergyPowerSample.batterySource(snapshot), "smc-battery-voltage-current")

        let withB0AP = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: ["Voltage": 12_311, "Amperage": -674],
            smcBattery: SMCPowerTelemetryService.batteryTelemetry(read: Self.mac17_9.read, platform: .appleSilicon)
        ))
        XCTAssertEqual(withB0AP.powerBasis, .smcPowerKey)
        XCTAssertEqual(SystemEnergyPowerSample.batterySource(withB0AP), "smc-battery-power-b0ap")

        let controllerOnly = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: ["Voltage": 12_311, "Amperage": -674], smcBattery: .unsupported
        ))
        XCTAssertEqual(controllerOnly.powerBasis, .batteryController)
        XCTAssertEqual(SystemEnergyPowerSample.batterySource(controllerOnly), "battery-controller-voltage-current")
        let noPower = try XCTUnwrap(NativeBatteryElectricalService.snapshot(properties: ["CycleCount": 108]))
        XCTAssertNil(noPower.powerWatts)
        XCTAssertNil(noPower.powerBasis)
    }

    func testTheMinuteAverageLoadIsCheckedAgainstTheControllersOwnBatteryPower() throws {
        // On external power under a heavy load the battery supplements the
        // adapter: the minute averages are 87 W load = 63 W in + 24 W from
        // the battery. The live SMC battery power may read only 5 W at the
        // same moment; the check must use the controller's same-minute V x I.
        var lighter = Self.mac17_9
        lighter.keys["B0AP"] = .init("si32", "78ecffff") // -5 000 mW
        let snapshot = try XCTUnwrap(NativeBatteryElectricalService.snapshot(
            properties: [
                "Voltage": 12_200, "Amperage": -1_970, "ExternalConnected": true,
                "PowerTelemetryData": [
                    "SystemLoad": 87_000, "SystemPowerIn": 63_000,
                    "SystemVoltageIn": 19_430, "SystemCurrentIn": 3_242,
                ],
            ],
            smcBattery: SMCPowerTelemetryService.batteryTelemetry(read: lighter.read, platform: .appleSilicon)
        ))
        XCTAssertEqual(try XCTUnwrap(snapshot.powerWatts), -5, accuracy: 0.001, "the live reading is shown")
        XCTAssertEqual(try XCTUnwrap(snapshot.systemLoadWatts), 87, accuracy: 0.001)
    }

    // MARK: - IOReport element timestamp and units

    // MARK: - Saved history across versions (review item 6)

    /// Earlier versions decode `temperatureReadings` strictly, with the
    /// zones up to `wifi`: the charging circuit is written apart so they
    /// can still read the whole history, and this version reads both.
    func testSavedHistoryKeepsTheChargingCircuitWhereEarlierVersionsIgnoreIt() throws {
        let point = MenuBarTelemetryPoint(
            date: Date(timeIntervalSinceReferenceDate: 800_000_000),
            cpuTotal: 12, cpuUser: 8, cpuSystem: 4, gpu: 3, memory: 61,
            chipTemperature: 85,
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 85),
                SystemTemperatureReading(zone: .battery, celsius: 31.8),
                SystemTemperatureReading(zone: .chargingCircuit, celsius: 55.7),
            ],
            fanRPM: nil, downBytesPerSecond: 1_000, upBytesPerSecond: 200
        )
        let data = try JSONEncoder().encode([point])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first
        let original = try XCTUnwrap(object?["temperatureReadings"] as? [[String: Any]])
        XCTAssertEqual(original.compactMap { $0["zone"] as? String }, ["chip", "battery"])
        let added = try XCTUnwrap(object?["addedTemperatureReadings"] as? [[String: Any]])
        XCTAssertEqual(added.compactMap { $0["zone"] as? String }, ["chargingCircuit"])

        // An earlier version's strict decoding reads the whole file.
        let earlier = try JSONDecoder().decode([EarlierTelemetryPoint].self, from: data)
        XCTAssertEqual(earlier.first?.temperatureReadings?.map(\.zone), [.chip, .battery])

        // This version reads every zone back, the same point as written.
        let decoded = try JSONDecoder().decode(BoundedMonitoringArray<MenuBarTelemetryPoint>.self, from: data).values
        XCTAssertEqual(decoded, [point])
        XCTAssertEqual(decoded.first?.temperature(.chargingCircuit), 55.7)

        // Without the new zone the file is as before: no extra key.
        let plain = MenuBarTelemetryPoint(
            date: point.date, cpuTotal: 12, cpuUser: nil, cpuSystem: nil, gpu: nil, memory: nil,
            chipTemperature: 85, temperatureReadings: [SystemTemperatureReading(zone: .chip, celsius: 85)],
            fanRPM: nil, downBytesPerSecond: nil, upBytesPerSecond: nil
        )
        let plainObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertNil(plainObject["addedTemperatureReadings"])
        XCTAssertEqual(SystemTemperatureZone.addedAfterOriginalHistoryFormat, [.chargingCircuit])
        XCTAssertEqual(
            Set(SystemTemperatureZone.allCases.map(\.rawValue)).subtracting(EarlierZone.allCases.map(\.rawValue)),
            ["chargingCircuit"], "only the charging circuit is newer than the saved format"
        )
    }

    /// Incremental review P2-1: with the encoding of `fanTargetRPM` deleted,
    /// every related test still passed, because no fixture filled that
    /// field. Every one of the 25 fields filled (D80's `bucketStatistics`
    /// and D133's `swapUsedPercent` among them; 24 before D133), written
    /// and read back by this version, field by field; the file has exactly
    /// their keys.
    func testSavedHistoryRoundTripsEveryField() throws {
        let point = Self.everyFieldPoint
        let fields = Mirror(reflecting: point).children.map { (label: $0.label ?? "?", value: $0.value) }
        // D133: 25 with the swap share (was 24).
        XCTAssertEqual(fields.count, 25, "MenuBarTelemetryPoint gained or lost a stored field: fill it here and code it")
        for field in fields {
            let value = Mirror(reflecting: field.value)
            XCTAssertFalse(value.displayStyle == .optional && value.children.isEmpty, "\(field.label) is not filled")
        }

        let data = try JSONEncoder().encode([point])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first
        XCTAssertEqual(
            Set(object?.keys.map { $0 } ?? []),
            Set(fields.map(\.label)).union(["addedTemperatureReadings"]),
            "one key per field, the charging circuit under its own key"
        )

        let decoded = try XCTUnwrap(
            JSONDecoder().decode(BoundedMonitoringArray<MenuBarTelemetryPoint>.self, from: data).values.first
        )
        let readBack = Mirror(reflecting: decoded).children.map { (label: $0.label ?? "?", value: $0.value) }
        XCTAssertEqual(readBack.map(\.label), fields.map(\.label))
        for (written, read) in zip(fields, readBack) where written.label != "bucketStatistics" {
            XCTAssertEqual(String(describing: read.value), String(describing: written.value), written.label)
        }
        // Dictionaries print in a per-instance order: the statistics are
        // compared by value, every metric and companion included.
        XCTAssertEqual(decoded.bucketStatistics, point.bucketStatistics, "bucketStatistics")
        XCTAssertEqual(decoded.bucketStatistics?.metrics.keys.sorted(), ["cpuTotal", "memory"])
        XCTAssertEqual(decoded.bucketStatistics?.metrics["cpuTotal"]?.peakCompanions, ["cpuUser": 71.5, "cpuSystem": 22.25])
        XCTAssertEqual(decoded, point)
    }

    /// The same file read by an earlier build (the synthesized, strict
    /// decoding before D57, zones up to `wifi`): every field arrives, only
    /// the charging circuit is not seen; written back by that build and
    /// read by this one, nothing else is lost.
    func testAnEarlierBuildReadsEveryFieldOfTheNewFileAndWritesItBack() throws {
        let point = Self.everyFieldPoint
        let data = try JSONEncoder().encode([point])
        let earlier = try XCTUnwrap(
            JSONDecoder().decode(BoundedMonitoringArray<EarlierFullTelemetryPoint>.self, from: data).values.first
        )
        // D71④: earlier builds ignore the two new optional source-time keys;
        // D80: and the bucket statistics, written under their own optional key;
        // D133: and the swap share (the list was the first four).
        // The full original payload must still arrive unchanged.
        let laterFields = ["temperatureReadings", "sensorSampledAt", "gpuSampledAt", "bucketStatistics",
                           "swapUsedPercent"]
        let expected = Mirror(reflecting: point).children.filter { !laterFields.contains($0.label ?? "") }
        let actual = Mirror(reflecting: earlier).children.filter { $0.label != "temperatureReadings" }
        XCTAssertEqual(actual.map(\.label), expected.map(\.label))
        XCTAssertEqual(actual.count, 20)
        for (written, read) in zip(expected, actual) {
            XCTAssertEqual(String(describing: read.value), String(describing: written.value), written.label ?? "?")
        }
        let withoutChargingCircuit = point.temperatureReadings?.filter { $0.zone != .chargingCircuit }
        XCTAssertEqual(
            earlier.temperatureReadings?.map { "\($0.zone.rawValue) \($0.celsius)" },
            withoutChargingCircuit?.map { "\($0.zone.rawValue) \($0.celsius)" }
        )

        let rewritten = try JSONEncoder().encode([earlier])
        let backAgain = try XCTUnwrap(
            JSONDecoder().decode(BoundedMonitoringArray<MenuBarTelemetryPoint>.self, from: rewritten).values.first
        )
        XCTAssertNil(backAgain.sensorSampledAt)
        XCTAssertNil(backAgain.gpuSampledAt)
        XCTAssertNotNil(point.bucketStatistics, "the fixture carries a compacted bucket")
        XCTAssertNil(backAgain.bucketStatistics, "an earlier build drops only the statistics, never an old field")
        // D133: and the swap share, new as well; those minutes have no swap bar.
        XCTAssertNotNil(point.swapUsedPercent, "the fixture carries a swap share")
        XCTAssertNil(backAgain.swapUsedPercent, "an earlier build drops the swap share, never an old field")
        XCTAssertEqual(backAgain, MenuBarTelemetryPoint(
            date: point.date, cpuTotal: point.cpuTotal, cpuUser: point.cpuUser, cpuSystem: point.cpuSystem,
            gpu: point.gpu, memory: point.memory, memoryPressure: point.memoryPressure,
            memoryPressureLevelCode: point.memoryPressureLevelCode, memoryAppOrOtherBytes: point.memoryAppOrOtherBytes,
            memoryWiredBytes: point.memoryWiredBytes, memoryPhysicalBytes: point.memoryPhysicalBytes,
            compressedMemoryBytes: point.compressedMemoryBytes, swapUsedBytes: point.swapUsedBytes,
            chipTemperature: point.chipTemperature, gpuTemperature: point.gpuTemperature,
            temperatureReadings: withoutChargingCircuit, fanRPM: point.fanRPM, fanTargetRPM: point.fanTargetRPM,
            fanReadings: point.fanReadings, downBytesPerSecond: point.downBytesPerSecond,
            upBytesPerSecond: point.upBytesPerSecond
        ))
    }

    /// A zone written by a later version is skipped, not a failed file.
    func testAZoneThisVersionDoesNotKnowIsSkipped() throws {
        let json = #"""
        [{"date": 800000000, "cpuTotal": 12, "chipTemperature": 85,
          "temperatureReadings": [{"zone": "chip", "celsius": 85}, {"zone": "futureZone", "celsius": 40}],
          "addedTemperatureReadings": [{"zone": "chargingCircuit", "celsius": 55.7}, {"zone": "laterStill", "celsius": 41}]},
         {"date": 800000002, "cpuTotal": 13}]
        """#
        let points = try JSONDecoder().decode(BoundedMonitoringArray<MenuBarTelemetryPoint>.self, from: Data(json.utf8)).values
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first?.temperatureReadings?.map(\.zone), [.chip, .chargingCircuit])
        XCTAssertNil(points.last?.temperatureReadings)
    }

    func testEnergyModelUpdateTimestampIsReadFromTheIOReportElement() {
        var element = Data(count: 64)
        element.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt64(0x1_0000_058e), toByteOffset: 0, as: UInt64.self)
            raw.storeBytes(of: UInt64(123_456_789), toByteOffset: 24, as: UInt64.self)
            raw.storeBytes(of: Int64(3_437_448_181), toByteOffset: 32, as: Int64.self)
        }
        XCTAssertEqual(
            EnergyModelCounterReader.updateTimestamp(rawElements: element, expectedValue: 3_437_448_181, notAfter: 200_000_000),
            123_456_789
        )
        // Any mismatch with the library's value, a future time or another
        // layout is rejected (the estimator then uses its window).
        XCTAssertNil(EnergyModelCounterReader.updateTimestamp(rawElements: element, expectedValue: 1, notAfter: 200_000_000))
        XCTAssertNil(EnergyModelCounterReader.updateTimestamp(rawElements: element, expectedValue: 3_437_448_181, notAfter: 100))
        XCTAssertNil(EnergyModelCounterReader.updateTimestamp(rawElements: element + Data(count: 64), expectedValue: 3_437_448_181, notAfter: 200_000_000))
        XCTAssertNil(EnergyModelCounterReader.updateTimestamp(rawElements: nil, expectedValue: 0, notAfter: 1))
    }

    func testEnergyUnitsComeFromEachChannelsOwnLabel() {
        XCTAssertEqual(SoCEnergyUnit.joules(perUnitLabel: "mJ"), 1e-3)
        XCTAssertEqual(SoCEnergyUnit.joules(perUnitLabel: "uJ"), 1e-6)
        XCTAssertEqual(SoCEnergyUnit.joules(perUnitLabel: "\u{00B5}J"), 1e-6)
        XCTAssertEqual(SoCEnergyUnit.joules(perUnitLabel: "nJ"), 1e-9)
        XCTAssertEqual(SoCEnergyUnit.joules(perUnitLabel: "J"), 1)
        XCTAssertNil(SoCEnergyUnit.joules(perUnitLabel: "W"))
        XCTAssertNil(SoCEnergyUnit.joules(perUnitLabel: ""))
    }

    // MARK: - Fixtures

    struct SMCFixture: Sendable {
        struct Entry: Sendable {
            let type: String
            let hex: String
            init(_ type: String, _ hex: String) {
                self.type = type
                self.hex = hex
            }
        }

        var keys: [String: Entry]

        func read(_ key: String) -> SMCKeyRead {
            guard let entry = keys[key] else { return .missing }
            return .present(dataType: entry.type, bytes: MiniSensorsDecodingTests.bytes(entry.hex))
        }
    }

    /// Mac17,9 (M5 Pro), raw bytes of the probe's idle1 snapshot.
    static let mac17_9 = SMCFixture(keys: [
        "PSTR": .init("flt ", "9eceaf42"), "PDTR": .init("flt ", "366d7d42"),
        "VD0R": .init("flt ", "1b709b41"), "ID0R": .init("flt ", "16b15040"),
        "PPBR": .init("flt ", "b2dc3641"), "PZC0": .init("flt ", "ba063442"),
        "PDBR": .init("flt ", "6a869540"), "IDBR": .init("flt ", "1f5dc33e"), "VP0R": .init("flt ", "ccf44341"),
        "B0AC": .init("si16", "bcfc"), "B0AV": .init("ui16", "0e30"), "B0AP": .init("si32", "01d6ffff"),
        "B0AT": .init("ui16", "1c0c"), "TB0T": .init("flt ", "cccc1242"),
        "BC1V": .init("ui16", "ff0f"), "BC2V": .init("ui16", "0410"), "BC3V": .init("ui16", "0610"),
    ])

    static func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    private func decode(_ key: String, _ type: String, _ hex: String, platform: SMCPlatform = .appleSilicon) -> Double? {
        SMCValueDecoder.decode(key: key, dataType: type.count == 3 ? type + " " : type, bytes: Self.bytes(hex), platform: platform)
    }

    private func present(_ type: String, _ hex: String) -> SMCKeyRead {
        .present(dataType: type, bytes: Self.bytes(hex))
    }

    private func float(_ value: Float) -> String {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Every one of MenuBarTelemetryPoint's 25 fields (24 before D133) filled with a value of
    /// its own (no two equal), the charging circuit among the zones, and a
    /// compacted bucket's statistics (D80) whose peak differs from the
    /// representative sample's own values.
    static let everyFieldPoint: MenuBarTelemetryPoint = {
        var point = MenuBarTelemetryPoint(
            date: Date(timeIntervalSinceReferenceDate: 800_000_123.5),
            cpuTotal: 37.25, cpuUser: 24.5, cpuSystem: 12.75, gpu: 18.5, memory: 61.25,
            memoryPressure: 42.5, memoryPressureLevelCode: 2,
            memoryAppOrOtherBytes: 9_663_676_416, memoryWiredBytes: 3_221_225_472,
            memoryPhysicalBytes: 25_769_803_776, compressedMemoryBytes: 1_073_741_824, swapUsedBytes: 536_870_912,
            // D133: the swap files' used share.
            swapUsedPercent: 12.5,
            chipTemperature: 85.5, gpuTemperature: 62.25,
            temperatureReadings: [
                SystemTemperatureReading(zone: .chip, celsius: 85.5),
                SystemTemperatureReading(zone: .superCores, celsius: 84.75),
                SystemTemperatureReading(zone: .battery, celsius: 37.1),
                SystemTemperatureReading(zone: .chargingCircuit, celsius: 53.1),
            ],
            fanRPM: 2_350, fanTargetRPM: 2_400,
            fanReadings: [
                SystemFanReading(index: 0, identity: .left, actualRPM: 2_340, minimumRPM: 1_200, maximumRPM: 5_700, targetRPM: 2_410),
                SystemFanReading(index: 1, identity: .named("Right"), actualRPM: 2_360, minimumRPM: 1_250, maximumRPM: 5_900, targetRPM: 2_390),
            ],
            downBytesPerSecond: 3_774_873, upBytesPerSecond: 419_430,
            sensorSampledAt: Date(timeIntervalSinceReferenceDate: 800_000_121.5),
            gpuSampledAt: Date(timeIntervalSinceReferenceDate: 800_000_120.5)
        )
        let peakDate = Date(timeIntervalSinceReferenceDate: 800_000_063.5)
        let bucketStart = Date(timeIntervalSinceReferenceDate: 800_000_003.5)
        point.bucketStatistics = MenuBarHistoryStatistics(metrics: [
            "cpuTotal": MenuBarHistoryStatistic(value: 93.75, date: peakDate,
                coverage: [DateInterval(start: bucketStart, end: peakDate)],
                peakCompanions: ["cpuUser": 71.5, "cpuSystem": 22.25]),
            "memory": MenuBarHistoryStatistic(value: 77.5, date: peakDate,
                coverage: [DateInterval(start: bucketStart, end: peakDate)]),
        ])
        return point
    }()

    /// MenuBarTelemetryPoint as it was before D57 (`d490207`): the same 21
    /// stored fields with the synthesized, strict Codable.
    private struct EarlierFullTelemetryPoint: Codable {
        struct Reading: Codable {
            let zone: EarlierZone
            let celsius: Double
        }

        let date: Date
        let cpuTotal: Double?
        let cpuUser: Double?
        let cpuSystem: Double?
        let gpu: Double?
        let memory: Double?
        let memoryPressure: Double?
        private(set) var memoryPressureLevelCode: Int?
        let memoryAppOrOtherBytes: UInt64?
        let memoryWiredBytes: UInt64?
        let memoryPhysicalBytes: UInt64?
        let compressedMemoryBytes: UInt64?
        let swapUsedBytes: UInt64?
        let chipTemperature: Double?
        let gpuTemperature: Double?
        let temperatureReadings: [Reading]?
        let fanRPM: Double?
        let fanTargetRPM: Double?
        let fanReadings: [SystemFanReading]?
        let downBytesPerSecond: Int64?
        let upBytesPerSecond: Int64?
    }

    /// The zones and the strict decoding of the saved history before D57
    /// (an earlier build): an unknown zone fails the whole array.
    private enum EarlierZone: String, CaseIterable, Codable {
        case chip, soc, performanceCores, superCores, efficiencyCores, gpu, storage, battery, ambient
        case palmRest, thunderboltLeft, thunderboltRight, wifi
    }

    private struct EarlierTelemetryPoint: Decodable {
        struct Reading: Decodable {
            let zone: EarlierZone
            let celsius: Double
        }

        let date: Date
        let temperatureReadings: [Reading]?
    }

    private func backlight(watts: Double, current: Double, rail: Double) -> BacklightPowerReading {
        BacklightPowerReading(
            sourceKey: "PDBR",
            reportedWatts: .value(watts),
            currentAmps: .value(current),
            railVoltageVolts: .value(rail)
        )
    }
}
