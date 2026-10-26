// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/ChargingEffectTimelineTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import Foundation
import Testing
@testable import CombinedStatusIcon

struct ChargingEffectTimelineTests {
    @Test func pluggingInStartsAChargingEventOnlyWhenChargingBegins() {
        let previous = batteryStatus(53, charging: false, connected: false)
        let charging = batteryStatus(53, charging: true, connected: true)
        let connectedButPaused = batteryStatus(53, charging: false, connected: true)

        #expect(ChargingEffectEvent.between(previous: previous, current: charging) == .pluggedIn)
        #expect(ChargingEffectEvent.between(previous: previous, current: connectedButPaused) == nil)
        #expect(ChargingEffectEvent.between(previous: charging, current: charging) == nil)
    }

    @Test func integerLevelAdvanceDoesNotResetTheSteadyTimeline() {
        let previous = batteryStatus(53, charging: true, connected: true)
        let increased = batteryStatus(54, charging: true, connected: true)
        let decreased = batteryStatus(52, charging: true, connected: true)

        #expect(ChargingEffectEvent.between(previous: previous, current: increased) == .levelAdvanced)
        #expect(ChargingEffectEvent.between(previous: previous, current: decreased) == nil)
        #expect(ChargingEffectTimeline.phase(elapsed: 0.9, kind: .steady)?.step == 18)
    }

    @Test func steadyCycleHasThirtySixTwentyHertzSteps() throws {
        let halfway = try #require(ChargingEffectTimeline.phase(elapsed: 0.9, kind: .steady))
        let wrapped = try #require(ChargingEffectTimeline.phase(elapsed: 1.8, kind: .steady))

        #expect(halfway.stepsPerCycle == 36)
        #expect(halfway.step == 18)
        #expect(wrapped.step == 0)
        #expect(wrapped.kind == .steady)
    }

    @Test func dateDerivedFrameBoundariesDoNotSlipToThePreviousTick() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let secondCycle = start.addingTimeInterval(1.8).timeIntervalSince(start)
        let lastFrame = start.addingTimeInterval(3.55).timeIntervalSince(start)

        #expect(ChargingEffectTimeline.phase(elapsed: secondCycle, kind: .steady)?.step == 0)
        #expect(ChargingEffectTimeline.phase(elapsed: lastFrame, kind: .steady)?.step == 35)
    }

    @Test func plugInBurstIsOneTwelveStepCompressedRound() throws {
        let lastBurstStep = try #require(ChargingEffectTimeline.phase(elapsed: 0.55, kind: .burst))
        let nextSteadyStep = try #require(ChargingEffectTimeline.phase(elapsed: 0.6, kind: .steady))

        #expect(lastBurstStep.stepsPerCycle == 12)
        #expect(lastBurstStep.step == 11)
        #expect(lastBurstStep.kind == .burst)
        #expect(nextSteadyStep.stepsPerCycle == 36)
        #expect(nextSteadyStep.step == 12)
    }

    @Test func heartbeatMultiplierIsCarriedWithoutChangingCyclePosition() throws {
        let normal = try #require(ChargingEffectTimeline.phase(elapsed: 1.6, kind: .steady))
        let boosted = try #require(ChargingEffectTimeline.phase(
            elapsed: 1.6,
            kind: .steady,
            heartbeatMultiplier: 1.35
        ))

        #expect(normal.step == boosted.step)
        #expect(normal.stepsPerCycle == boosted.stepsPerCycle)
        #expect(boosted.heartbeatMultiplier == 1.35)
    }

    @Test func invalidElapsedTimeDoesNotProduceAFrame() {
        #expect(ChargingEffectTimeline.phase(elapsed: .nan, kind: .steady) == nil)
        #expect(ChargingEffectTimeline.phase(elapsed: .infinity, kind: .burst) == nil)
        #expect(ChargingEffectTimeline.phase(elapsed: -0.01, kind: .steady) == nil)
    }

    private func batteryStatus(
        _ percentage: Int,
        charging: Bool,
        connected: Bool,
        charged: Bool = false
    ) -> BatteryStatus {
        BatteryStatus(
            rawPercentage: percentage,
            isPresent: true,
            isCharging: charging,
            isCharged: charged,
            isLowPowerMode: false,
            isConnectedToPower: connected
        )
    }
}
