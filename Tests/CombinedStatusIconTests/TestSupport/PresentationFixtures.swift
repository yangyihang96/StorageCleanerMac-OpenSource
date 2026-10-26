// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/TestSupport/PresentationFixtures.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import Foundation
@testable import CombinedStatusIcon

enum PresentationFixtures {
    static func snapshot(
        rssi: Int = -61,
        scalar: Double? = 0.51,
        muted: Bool = false
    ) -> StatusSnapshot {
        StatusSnapshot(
            battery: BatteryStatus(
                rawPercentage: 68,
                isPresent: true,
                isCharging: false,
                isLowPowerMode: false,
                isConnectedToPower: false
            ),
            wifi: WiFiStatus(state: .connected, rssi: rssi),
            connection: .wifi,
            volume: VolumeStatus(scalar: scalar, isMuted: muted, deviceName: "Output")
        )
    }

    static var bluetoothDevice: AudioOutputDevice { SheetFixtures.bluetoothDevice }
}
