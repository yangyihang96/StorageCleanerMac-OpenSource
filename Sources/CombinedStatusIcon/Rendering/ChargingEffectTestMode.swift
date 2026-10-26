// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/UI/Icon/ChargingEffectTestMode.swift
// and the StatusSnapshot.replacingBattery extension in Sources/StatusTrioCore/Store/SystemStatusStore.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): kept for
// IconPresentationViewModel only; the app never turns the test mode on, and the
// MenuBarStatus projection of the upstream popover is not ported.

import Foundation

/// Keeps the temporary CPU test local to icon rendering. Monitoring and the
/// status shown in the popover continue to use the actual battery reading.
enum ChargingEffectTestMode {
    static func isAvailable(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleIdentifier?.contains(".dev.") == true
    }

    static func battery(_ battery: BatteryStatus, enabled: Bool) -> BatteryStatus {
        guard enabled else { return battery }
        return BatteryStatus(
            rawPercentage: battery.isPresent ? battery.rawPercentage : 62,
            isPresent: true,
            isCharging: true,
            isLowPowerMode: battery.isLowPowerMode,
            isConnectedToPower: true
        )
    }

    static func snapshot(_ snapshot: StatusSnapshot, enabled: Bool) -> StatusSnapshot {
        guard enabled else { return snapshot }
        return snapshot.replacingBattery(battery(snapshot.battery, enabled: true))
    }
}

extension StatusSnapshot {
    func replacingBattery(_ value: BatteryStatus) -> StatusSnapshot {
        StatusSnapshot(battery: value, wifi: wifi, connection: connection, volume: volume)
    }
}
