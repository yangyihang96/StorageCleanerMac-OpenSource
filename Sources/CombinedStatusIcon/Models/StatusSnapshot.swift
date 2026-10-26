// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Models/StatusSnapshot.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): made public what the app reads.

import Foundation

public struct BatteryStatus: Equatable, Sendable {
    public let rawPercentage: Int?
    public let isPresent: Bool
    public let isCharging: Bool
    public let isCharged: Bool
    public let timeToFullChargeMinutes: Int?
    public let isLowPowerMode: Bool
    public let isConnectedToPower: Bool

    public init(
        rawPercentage: Int?,
        isPresent: Bool,
        isCharging: Bool,
        isCharged: Bool = false,
        timeToFullChargeMinutes: Int? = nil,
        isLowPowerMode: Bool,
        isConnectedToPower: Bool
    ) {
        self.rawPercentage = rawPercentage
        self.isPresent = isPresent
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.timeToFullChargeMinutes = timeToFullChargeMinutes
        self.isLowPowerMode = isLowPowerMode
        self.isConnectedToPower = isConnectedToPower
    }

    public var percentage: Int {
        guard isPresent else { return 100 }
        let value = rawPercentage ?? 100
        return min(100, max(0, value))
    }

    public static let placeholder = BatteryStatus(
        rawPercentage: 100,
        isPresent: true,
        isCharging: false,
        isLowPowerMode: false,
        isConnectedToPower: false
    )
}

public enum WiFiState: Equatable, Sendable {
    case connected
    case notAssociated
    case off
    case noInternet
    case hotspot
    case temporary
    case shared
    case unavailable

    public var isNetworkAssociated: Bool {
        switch self {
        case .connected, .noInternet, .hotspot, .temporary, .shared:
            true
        case .notAssociated, .off, .unavailable:
            false
        }
    }
}

public enum WiFiNameAccess: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public struct WiFiStatus: Equatable, Sendable {
    public let state: WiFiState
    public let rssi: Int?
    public let ssid: String?
    public let nameAccess: WiFiNameAccess
    public let band: WiFiFrequencyBand?

    public init(
        state: WiFiState,
        rssi: Int?,
        ssid: String? = nil,
        nameAccess: WiFiNameAccess = .notDetermined,
        band: WiFiFrequencyBand? = nil
    ) {
        self.state = state
        self.rssi = rssi
        self.ssid = ssid
        self.nameAccess = nameAccess
        self.band = band
    }

    public static let placeholder = WiFiStatus(state: .unavailable, rssi: nil)
}

extension WiFiStatus {
    /// True while a network name is expected but not known yet: the popover shows
    /// no subtitle until the fresh read delivers the name, instead of flashing the
    /// generic state text first.
    var isAwaitingName: Bool {
        state.isNetworkAssociated
            && nameAccess == .authorized
            && (ssid ?? "").isEmpty
    }
}

public struct VolumeStatus: Equatable, Sendable {
    public let scalar: Double?
    public let isMuted: Bool
    public let deviceName: String?
    public let currentDevice: AudioOutputDevice?
    public let outputDevices: [AudioOutputDevice]
    public let canSetVolume: Bool
    public let canMute: Bool

    public init(
        scalar: Double?,
        isMuted: Bool,
        deviceName: String?,
        currentDevice: AudioOutputDevice? = nil,
        outputDevices: [AudioOutputDevice] = [],
        canSetVolume: Bool? = nil,
        canMute: Bool? = nil
    ) {
        self.scalar = scalar
        self.isMuted = isMuted
        self.deviceName = deviceName
        self.currentDevice = currentDevice
        self.outputDevices = outputDevices
        self.canSetVolume = canSetVolume ?? (scalar != nil)
        self.canMute = canMute ?? (scalar != nil)
    }

    public static let placeholder = VolumeStatus(
        scalar: nil,
        isMuted: false,
        deviceName: nil
    )
}

public struct StatusSnapshot: Equatable, Sendable {
    public let battery: BatteryStatus
    public let wifi: WiFiStatus
    public let connection: NetworkConnection
    public let volume: VolumeStatus

    public init(
        battery: BatteryStatus,
        wifi: WiFiStatus,
        connection: NetworkConnection = .unknown,
        volume: VolumeStatus
    ) {
        self.battery = battery
        self.wifi = wifi
        self.connection = connection
        self.volume = volume
    }

    public static let placeholder = StatusSnapshot(
        battery: .placeholder,
        wifi: .placeholder,
        volume: .placeholder
    )
}
