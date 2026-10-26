// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Models/MenuBarStatus.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import Foundation
@testable import CombinedStatusIcon

struct MenuBarVolumeStatus: Equatable, Sendable {
    let scalar: Double?
    let isMuted: Bool
    let deviceName: String?
    let currentDevice: AudioOutputDevice?

    init(
        scalar: Double?,
        isMuted: Bool,
        deviceName: String?,
        currentDevice: AudioOutputDevice? = nil
    ) {
        self.scalar = scalar
        self.isMuted = isMuted
        self.deviceName = deviceName
        self.currentDevice = currentDevice
    }

    init(volume: VolumeStatus) {
        self.init(
            scalar: volume.scalar,
            isMuted: volume.isMuted,
            deviceName: volume.deviceName,
            currentDevice: volume.currentDevice
        )
    }
}

struct MenuBarStatus: Equatable, Sendable {
    let battery: BatteryStatus
    let wifi: WiFiStatus
    let connection: NetworkConnection
    let volume: MenuBarVolumeStatus

    init(
        battery: BatteryStatus,
        wifi: WiFiStatus,
        connection: NetworkConnection,
        volume: MenuBarVolumeStatus
    ) {
        self.battery = battery
        // The frequency band is popover-only metadata, not an icon input.
        self.wifi = WiFiStatus(state: wifi.state, rssi: wifi.rssi,
                               ssid: wifi.ssid, nameAccess: wifi.nameAccess)
        self.connection = connection
        self.volume = volume
    }

    init(snapshot: StatusSnapshot) {
        self.init(
            battery: snapshot.battery,
            wifi: snapshot.wifi,
            connection: snapshot.connection,
            volume: MenuBarVolumeStatus(volume: snapshot.volume)
        )
    }

    static let placeholder = MenuBarStatus(snapshot: .placeholder)
}
