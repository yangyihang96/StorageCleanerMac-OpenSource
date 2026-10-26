// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/StatusSnapshotTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import XCTest
@testable import CombinedStatusIcon

final class StatusSnapshotTests: XCTestCase {
    func testMissingBatteryBehavesAsFull() {
        let battery = BatteryStatus(
            rawPercentage: nil,
            isPresent: false,
            isCharging: false,
            isLowPowerMode: false,
            isConnectedToPower: false
        )

        XCTAssertEqual(battery.percentage, 100)
    }

    func testPresentBatteryWithNegativeRawPercentageClampsToZero() {
        XCTAssertEqual(makeBattery(rawPercentage: -1).percentage, 0)
    }

    func testPresentBatteryAboveMaximumClampsTo100() {
        XCTAssertEqual(makeBattery(rawPercentage: 101).percentage, 100)
    }

    func testPresentBatteryWithNilRawPercentageDefaultsTo100() {
        XCTAssertEqual(makeBattery(rawPercentage: nil).percentage, 100)
    }

    func testWiFiPlaceholderHasStableDefaults() {
        let wifi = WiFiStatus.placeholder

        XCTAssertEqual(wifi.state, .unavailable)
        XCTAssertNil(wifi.rssi)
        XCTAssertNil(wifi.ssid)
        XCTAssertEqual(wifi.nameAccess, .notDetermined)
    }

    func testWiFiStateReportsWhetherANetworkNameCanBeRelevant() {
        XCTAssertTrue(WiFiState.connected.isNetworkAssociated)
        XCTAssertTrue(WiFiState.noInternet.isNetworkAssociated)
        XCTAssertTrue(WiFiState.hotspot.isNetworkAssociated)
        XCTAssertTrue(WiFiState.temporary.isNetworkAssociated)
        XCTAssertTrue(WiFiState.shared.isNetworkAssociated)
        XCTAssertFalse(WiFiState.notAssociated.isNetworkAssociated)
        XCTAssertFalse(WiFiState.off.isNetworkAssociated)
        XCTAssertFalse(WiFiState.unavailable.isNetworkAssociated)
    }

    func testVolumePlaceholderHasStableDefaults() {
        let volume = VolumeStatus.placeholder

        XCTAssertNil(volume.scalar)
        XCTAssertFalse(volume.isMuted)
        XCTAssertNil(volume.deviceName)
    }

    func testSnapshotPlaceholderHasStableDefaults() {
        let snapshot = StatusSnapshot.placeholder

        XCTAssertEqual(snapshot.battery.rawPercentage, 100)
        XCTAssertTrue(snapshot.battery.isPresent)
        XCTAssertFalse(snapshot.battery.isCharging)
        XCTAssertFalse(snapshot.battery.isCharged)
        XCTAssertNil(snapshot.battery.timeToFullChargeMinutes)
        XCTAssertFalse(snapshot.battery.isLowPowerMode)
        XCTAssertFalse(snapshot.battery.isConnectedToPower)
        XCTAssertEqual(snapshot.wifi, .placeholder)
        XCTAssertEqual(snapshot.connection, .unknown)
        XCTAssertEqual(snapshot.volume, .placeholder)
    }

    func testSnapshotDefaultsAreStable() {
        XCTAssertEqual(StatusSnapshot.placeholder.battery.percentage, 100)
        XCTAssertEqual(StatusSnapshot.placeholder.wifi.state, .unavailable)
        XCTAssertNil(StatusSnapshot.placeholder.volume.scalar)
    }

    private func makeBattery(rawPercentage: Int?) -> BatteryStatus {
        BatteryStatus(
            rawPercentage: rawPercentage,
            isPresent: true,
            isCharging: false,
            isLowPowerMode: false,
            isConnectedToPower: false
        )
    }
}
