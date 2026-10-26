// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/ChargingEffectPolicyTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import CoreGraphics
import Testing
@testable import CombinedStatusIcon

struct ChargingEffectPolicyTests {
    @Test func animationPolicyRequiresActiveChargingAndAllMotionGatesOpen() {
        let charging = batteryStatus(58, charging: true, connected: true)
        let connectedButPaused = batteryStatus(100, charging: false, connected: true, charged: true)

        #expect(ChargingEffectPolicy.shouldAnimate(
            battery: charging, enabled: true, reduceMotion: false, displayAsleep: false
        ))
        #expect(ChargingEffectPolicy.shouldAnimate(
            battery: connectedButPaused, enabled: true, reduceMotion: false, displayAsleep: false
        ) == false)
        let absentButCharging = BatteryStatus(
            rawPercentage: nil,
            isPresent: false,
            isCharging: true,
            isLowPowerMode: false,
            isConnectedToPower: true
        )
        #expect(ChargingEffectPolicy.shouldAnimate(
            battery: absentButCharging, enabled: true, reduceMotion: false, displayAsleep: false
        ) == false)
        #expect(ChargingEffectPolicy.shouldAnimate(
            battery: charging, enabled: false, reduceMotion: false, displayAsleep: false
        ) == false)
        #expect(ChargingEffectPolicy.shouldAnimate(
            battery: charging, enabled: true, reduceMotion: true, displayAsleep: false
        ) == false)
        #expect(ChargingEffectPolicy.shouldAnimate(
            battery: charging, enabled: true, reduceMotion: false, displayAsleep: true
        ) == false)
    }

    @Test func aChargedBatteryStaysStaticEvenIfChargingFlagIsInconsistent() {
        let contradictory = batteryStatus(100, charging: true, connected: true, charged: true)

        #expect(ChargingEffectPolicy.shouldAnimate(
            battery: contradictory, enabled: true, reduceMotion: false, displayAsleep: false
        ) == false)
    }

    @Test func lowVisibleFillKeepsEndpointHeartbeatButSuppressesTail() throws {
        let phase = ChargingEffectPhase(step: 33, stepsPerCycle: 36, kind: .steady)
        let frame = try #require(ChargingEffectPolicy.frame(
            progress: 0.1,
            phase: phase,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        ))

        #expect(frame.tailRange == nil)
        #expect(frame.headProgress == 0.1)
        #expect(frame.heartbeatAlpha > 0)
    }

    @Test func tailLengthIsLimitedToSeventyEightPercentOfVisibleFill() throws {
        let phase = ChargingEffectPhase(step: 31, stepsPerCycle: 36, kind: .steady)
        let frame = try #require(ChargingEffectPolicy.frame(
            progress: 0.2,
            phase: phase,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        ))
        let tail = try #require(frame.tailRange)
        let visibleFill = StatusIconGeometry.visibleFraction(
            forProgress: 0.2,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        )

        #expect(abs((tail.upperBound - tail.lowerBound) - 0.78 * visibleFill) < 1e-9)
    }

    @Test func tailUsesThirtyTwoPercentOfTheVisibleArcWhenBatteryFillIsLongEnough() throws {
        let phase = ChargingEffectPhase(step: 31, stepsPerCycle: 36, kind: .steady)
        let frame = try #require(ChargingEffectPolicy.frame(
            progress: 0.8,
            phase: phase,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        ))
        let tail = try #require(frame.tailRange)

        let visibleTailLength = StatusIconGeometry.visibleFraction(
            forProgress: tail.upperBound,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        ) - StatusIconGeometry.visibleFraction(
            forProgress: tail.lowerBound,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        )

        #expect(abs(visibleTailLength - 0.2466) < 0.001)
    }

    @Test func fillEndingInsideGapUsesTheLeftEdgeForItsHeartbeat() throws {
        let phase = ChargingEffectPhase(step: 33, stepsPerCycle: 36, kind: .steady)
        let frame = try #require(ChargingEffectPolicy.frame(
            progress: 0.5,
            phase: phase,
            hasTopGap: true,
            topGapWidth: StatusIconGeometry.batteryChargingBoltTopGapWidth
        ))

        #expect(abs(frame.headProgress - 0.3854) < 0.001)
        #expect(frame.heartbeatAlpha > 0)
    }

    @Test func nextHeartbeatAppliesTheThirtyFivePercentBoostWithoutChangingGeometry() throws {
        let regular = try #require(ChargingEffectPolicy.frame(
            progress: 0.8,
            phase: ChargingEffectPhase(step: 33, stepsPerCycle: 36, kind: .steady),
            hasTopGap: true
        ))
        let boosted = try #require(ChargingEffectPolicy.frame(
            progress: 0.8,
            phase: ChargingEffectPhase(
                step: 33,
                stepsPerCycle: 36,
                kind: .steady,
                heartbeatMultiplier: 1.35
            ),
            hasTopGap: true
        ))

        #expect(abs(boosted.heartbeatAlpha - regular.heartbeatAlpha * 1.35) < 1e-9)
        #expect(abs(boosted.heartbeatScale - regular.heartbeatScale * 1.35) < 1e-9)
        #expect(boosted.headProgress == regular.headProgress)
        #expect(boosted.tailRange == regular.tailRange)
    }

    @Test func movingTailSplitsAtTheGapAndHidesAHeadInsideIt() throws {
        let crossing = try #require(ChargingEffectPolicy.frame(
            progress: 0.8,
            phase: ChargingEffectPhase(step: 24, stepsPerCycle: 36, kind: .steady),
            hasTopGap: true
        ))
        let insideGap = try #require(ChargingEffectPolicy.frame(
            progress: 0.8,
            phase: ChargingEffectPhase(step: 23, stepsPerCycle: 36, kind: .steady),
            hasTopGap: true
        ))
        let crossingRange = try #require(crossing.tailRange)
        let gapRange = try #require(insideGap.tailRange)

        let crossingPath = StatusIconGeometry.batteryHighlight(
            from: crossingRange.lowerBound,
            to: crossingRange.upperBound,
            hasTopGap: true
        )
        let gapPath = StatusIconGeometry.batteryHighlight(
            from: gapRange.lowerBound,
            to: gapRange.upperBound,
            hasTopGap: true
        )

        #expect(crossing.headIsVisible)
        #expect(moveToCount(in: crossingPath) == 2)
        #expect(insideGap.headIsVisible == false)
        #expect(insideGap.beadAlpha == 0)
        #expect(moveToCount(in: gapPath) == 1)
    }

    @Test func beadFadesOutMonotonicallyDuringTheEndpointHeartbeat() throws {
        func frame(at step: Int) throws -> ChargingEffectFrame {
            try #require(ChargingEffectPolicy.frame(
                progress: 0.8,
                phase: ChargingEffectPhase(step: step, stepsPerCycle: 36, kind: .steady),
                hasTopGap: true
            ))
        }

        let attack = try frame(at: 31)
        let peak = try frame(at: 33)
        let release = try frame(at: 35)

        #expect(attack.beadAlpha == 1)
        #expect(abs(peak.beadAlpha - 0.5) < 1e-9)
        #expect(release.beadAlpha == 0)
        #expect(peak.heartbeatAlpha > attack.heartbeatAlpha)
        #expect(release.heartbeatAlpha == 0)
    }

    @Test func invalidPhaseAndProgressDoNotProduceFrames() {
        let invalidPhase = ChargingEffectPhase(step: 1, stepsPerCycle: 0, kind: .steady)
        #expect(ChargingEffectPolicy.frame(
            progress: 0.5,
            phase: invalidPhase,
            hasTopGap: false
        ) == nil)
        #expect(ChargingEffectPolicy.frame(
            progress: .nan,
            phase: ChargingEffectPhase(step: 4, stepsPerCycle: 36, kind: .steady),
            hasTopGap: false
        ) == nil)
    }

    private func moveToCount(in path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint {
                count += 1
            }
        }
        return count
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
