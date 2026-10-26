// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/Models/ConnectionIconOptions.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

struct ConnectionIconOptions: Equatable, Hashable, Sendable {
    let showsWiFiIconForEthernet: Bool
    let showsWiFiIconForHotspot: Bool
    let showsWiFiIconForTemporaryConnection: Bool
    let showsWiFiIconForInternetSharing: Bool
    let showsBatteryPercentageInConnectionSlot: Bool
    let wifiScale: Double

    static let standard = ConnectionIconOptions(
        showsWiFiIconForEthernet: false,
        showsWiFiIconForHotspot: false,
        showsWiFiIconForTemporaryConnection: false,
        showsWiFiIconForInternetSharing: false,
        showsBatteryPercentageInConnectionSlot: false,
        wifiScale: 1.0
    )

    init(
        showsWiFiIconForEthernet: Bool = false,
        showsWiFiIconForHotspot: Bool = false,
        showsWiFiIconForTemporaryConnection: Bool = false,
        showsWiFiIconForInternetSharing: Bool = false,
        showsBatteryPercentageInConnectionSlot: Bool = false,
        wifiScale: Double = 1.0
    ) {
        self.showsWiFiIconForEthernet = showsWiFiIconForEthernet
        self.showsWiFiIconForHotspot = showsWiFiIconForHotspot
        self.showsWiFiIconForTemporaryConnection = showsWiFiIconForTemporaryConnection
        self.showsWiFiIconForInternetSharing = showsWiFiIconForInternetSharing
        self.showsBatteryPercentageInConnectionSlot = showsBatteryPercentageInConnectionSlot
        self.wifiScale = wifiScale
    }
}
