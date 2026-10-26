// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/ChargingEffectTestModeTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon; dropped what tests the Dock icon, the settings preview, the localization tables or the settings store, which this app does not include.

import Foundation
import Testing
@testable import CombinedStatusIcon

@MainActor
struct ChargingEffectTestModeTests {

    @Test func absentBatteryGetsAVisibleTestArcOnlyInTheDevBundle() {
        let simulated = ChargingEffectTestMode.battery(
            BatteryStatus(
                rawPercentage: nil,
                isPresent: false,
                isCharging: false,
                isLowPowerMode: false,
                isConnectedToPower: false
            ),
            enabled: true
        )
        #expect(simulated.isPresent)
        #expect(simulated.percentage == 62)
        #expect(ChargingEffectTestMode.isAvailable(bundleIdentifier: "com.lingsmbp.StatusTrio.dev.feature-charging-effects"))
        #expect(!ChargingEffectTestMode.isAvailable(bundleIdentifier: "com.lingsmbp.StatusTrio"))
    }

    @Test func testBatteryStartsAndStopsTheProductionClockWhenUnplugged() {
        let clock = ChargingEffectClock()
        let realBattery = BatteryStatus(
            rawPercentage: 46,
            isPresent: true,
            isCharging: false,
            isLowPowerMode: false,
            isConnectedToPower: false
        )
        clock.update(
            battery: ChargingEffectTestMode.battery(realBattery, enabled: true),
            enabled: true,
            reduceMotion: false,
            displayAsleep: false
        )
        #expect(clock.isRunning)
        #expect(clock.phase != nil)

        clock.update(battery: realBattery, enabled: true, reduceMotion: false, displayAsleep: false)
        #expect(!clock.isRunning)
        #expect(clock.phase == nil)
    }
}
