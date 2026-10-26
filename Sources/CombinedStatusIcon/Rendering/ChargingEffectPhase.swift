// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/UI/Icon/ChargingEffectPhase.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import Foundation

struct ChargingEffectPhase: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case burst
        case steady
    }

    let step: Int
    let stepsPerCycle: Int
    let kind: Kind
    let heartbeatMultiplier: Double

    init(
        step: Int,
        stepsPerCycle: Int,
        kind: Kind,
        heartbeatMultiplier: Double = 1
    ) {
        self.step = step
        self.stepsPerCycle = stepsPerCycle
        self.kind = kind
        self.heartbeatMultiplier = heartbeatMultiplier
    }
}
