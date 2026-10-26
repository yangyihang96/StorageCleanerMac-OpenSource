// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/UI/Icon/ChargingEffectEvent.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import Foundation

enum ChargingEffectEvent: Equatable, Sendable {
    case pluggedIn
    case levelAdvanced

    static func between(
        previous: BatteryStatus,
        current: BatteryStatus
    ) -> ChargingEffectEvent? {
        guard current.isCharging, !current.isCharged else { return nil }

        if !previous.isCharging {
            return .pluggedIn
        }
        guard !previous.isCharged,
              current.percentage > previous.percentage else {
            return nil
        }
        return .levelAdvanced
    }
}
