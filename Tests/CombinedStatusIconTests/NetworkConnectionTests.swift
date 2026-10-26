// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/NetworkConnectionTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import XCTest
@testable import CombinedStatusIcon

final class NetworkConnectionTests: XCTestCase {
    func testDisconnectedPathIsOfflineEvenWhenInterfacesReportAvailability() {
        XCTAssertEqual(
            NetworkConnection.resolve(connected: false, wired: true, wireless: true),
            .offline
        )
    }

    func testWiredConnectionTakesPriorityOverWireless() {
        XCTAssertEqual(
            NetworkConnection.resolve(connected: true, wired: true, wireless: true),
            .ethernet
        )
    }

    func testWirelessConnectionIsUsedWhenWiredIsUnavailable() {
        XCTAssertEqual(
            NetworkConnection.resolve(connected: true, wired: false, wireless: true),
            .wifi
        )
    }

    func testConnectedPathWithoutWiredOrWirelessIsOther() {
        XCTAssertEqual(
            NetworkConnection.resolve(connected: true, wired: false, wireless: false),
            .other
        )
    }
}
