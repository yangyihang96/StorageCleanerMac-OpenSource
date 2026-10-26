// Derived from Status Trio 1.6.0, Sources/StatusTrioCore/UI/Icon/ChargingEffectTimeline.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): copied unchanged apart from this notice.

import Foundation

enum ChargingEffectTimeline {
    static let framesPerSecond = 20
    static let steadyCycleDuration: TimeInterval = 1.8
    static let burstDuration: TimeInterval = 0.6
    static let levelAdvancedBurstDuration: TimeInterval = 0.3

    static func phase(
        elapsed: TimeInterval,
        kind: ChargingEffectPhase.Kind,
        event: ChargingEffectEvent? = nil,
        heartbeatMultiplier: Double = 1
    ) -> ChargingEffectPhase? {
        guard elapsed.isFinite,
              elapsed >= 0,
              heartbeatMultiplier.isFinite,
              heartbeatMultiplier >= 0 else {
            return nil
        }

        let duration = cycleDuration(for: kind, event: event)
        let stepsPerCycle = Int((duration * Double(framesPerSecond)).rounded())
        guard stepsPerCycle > 0 else { return nil }

        let cycleElapsed = elapsed.truncatingRemainder(dividingBy: duration)
        // Date intervals have roughly 50 ns granularity near these values, so an
        // exact 20-Hz edge can arrive just short by about 1e-6 frame units.
        // Snap only that residue forward to avoid a one-tick stall.
        let framePosition = cycleElapsed * Double(framesPerSecond)
        let roundedStep = Int((framePosition + 1e-6).rounded(.down))
        let step = roundedStep % stepsPerCycle
        return ChargingEffectPhase(
            step: step,
            stepsPerCycle: stepsPerCycle,
            kind: kind,
            heartbeatMultiplier: heartbeatMultiplier
        )
    }

    static func cycleDuration(
        for kind: ChargingEffectPhase.Kind,
        event: ChargingEffectEvent? = nil
    ) -> TimeInterval {
        switch kind {
        case .burst:
            event == .levelAdvanced ? levelAdvancedBurstDuration : burstDuration
        case .steady:
            steadyCycleDuration
        }
    }
}
