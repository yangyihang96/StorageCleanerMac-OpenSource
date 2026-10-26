// Derived from Status Trio 1.6.0, Tests/StatusTrioCoreTests/ChargingEffectClockTests.swift
// (https://github.com/lingyired/status-trio, tag v1.6.0, commit 64caf379).
// Copyright 2026 lingyired. Licensed under the Apache License, Version 2.0;
// see THIRD_PARTY_NOTICES.md. Modified for StorageCleanerMac (D153): imports CombinedStatusIcon.

import Foundation
import Testing
@testable import CombinedStatusIcon

@MainActor
struct ChargingEffectClockTests {
    @Test func idleBatteryDoesNotStartATickLoop() {
        let time = ManualDateProvider()
        let sleeper = ManualEventSleeper()
        let clock = makeClock(time: time, sleeper: sleeper)

        clock.update(
            battery: batteryStatus(61, charging: false),
            enabled: true,
            reduceMotion: false,
            displayAsleep: false
        )

        #expect(clock.phase == nil)
        #expect(clock.isRunning == false)
        #expect(sleeper.callCount == 0)
    }

    @Test func chargingStartsOnePlugInBurstAndTicksEveryFiftyMilliseconds() async {
        let time = ManualDateProvider()
        let sleeper = ManualEventSleeper()
        let clock = makeClock(time: time, sleeper: sleeper)

        clock.update(
            battery: batteryStatus(61, charging: true),
            enabled: true,
            reduceMotion: false,
            displayAsleep: false
        )

        #expect(clock.phase?.kind == .burst)
        #expect(clock.phase?.step == 0)
        await sleeper.waitForCallCount(1)
        #expect(sleeper.durations.first == .milliseconds(50))

        time.advance(.milliseconds(50))
        sleeper.releaseAll()
        await sleeper.waitForCallCount(2)
        #expect(clock.phase?.kind == .burst)
        #expect(clock.phase?.step == 1)

        clock.stop()
        sleeper.releaseAll()
        await sleeper.waitForCompletionCount(2)
        #expect(sleeper.callCount == 2)
    }

    @Test func disablingTheSettingStopsImmediatelyAndDoesNotLeaveATick() async {
        await assertStopsImmediately(enabled: false, reduceMotion: false, displayAsleep: false)
    }

    @Test func unpluggingStopsImmediatelyAndDoesNotLeaveATick() async {
        await assertStopsImmediately(
            battery: batteryStatus(61, charging: false),
            enabled: true,
            reduceMotion: false,
            displayAsleep: false
        )
    }

    @Test func reduceMotionStopsImmediatelyAndDoesNotLeaveATick() async {
        await assertStopsImmediately(enabled: true, reduceMotion: true, displayAsleep: false)
    }

    @Test func displaySleepStopsImmediatelyAndDoesNotLeaveATick() async {
        await assertStopsImmediately(enabled: true, reduceMotion: false, displayAsleep: true)
    }

    @Test func wakingResumesWithAFreshSteadyPhase() async {
        let time = ManualDateProvider()
        let sleeper = ManualEventSleeper()
        let clock = makeClock(time: time, sleeper: sleeper)
        let battery = batteryStatus(61, charging: true)

        clock.update(battery: battery, enabled: true, reduceMotion: false, displayAsleep: false)
        await sleeper.waitForCallCount(1)
        clock.update(battery: battery, enabled: true, reduceMotion: false, displayAsleep: true)
        #expect(clock.phase == nil)
        #expect(clock.isRunning == false)

        clock.update(battery: battery, enabled: true, reduceMotion: false, displayAsleep: false)
        #expect(clock.phase?.kind == .steady)
        #expect(clock.phase?.step == 0)
        #expect(clock.isRunning)
        await sleeper.waitForCallCount(2)

        clock.stop()
        sleeper.releaseAll()
        await sleeper.waitForCompletionCount(2)
        #expect(sleeper.callCount == 2)
    }

    @Test func initialPlugInBurstTransitionsToSteadyExactlyOnce() async {
        let time = ManualDateProvider()
        let sleeper = ManualEventSleeper()
        let clock = makeClock(time: time, sleeper: sleeper)
        let battery = batteryStatus(61, charging: true)

        clock.update(battery: battery, enabled: true, reduceMotion: false, displayAsleep: false)
        for frame in 1...12 {
            await sleeper.waitForCallCount(frame)
            time.advance(.milliseconds(50))
            sleeper.releaseAll()
        }
        await sleeper.waitForCallCount(13)

        #expect(clock.phase?.kind == .steady)
        #expect(clock.phase?.step == 0)

        clock.stop()
        sleeper.releaseAll()
        await sleeper.waitForCompletionCount(13)
        #expect(sleeper.callCount == 13)
    }

    @Test func levelAdvanceDuringPlugInKeepsMenuBarBurst() async {
        let time = ManualDateProvider()
        let sleeper = ManualEventSleeper()
        let clock = makeClock(time: time, sleeper: sleeper)
        let initial = batteryStatus(61, charging: true)
        let increased = batteryStatus(62, charging: true)

        clock.update(battery: initial, enabled: true, reduceMotion: false, displayAsleep: false)
        await sleeper.waitForCallCount(1)
        time.setElapsed(0.25)
        clock.update(battery: initial, enabled: true, reduceMotion: false, displayAsleep: false)
        #expect(clock.phase?.kind == .burst)
        #expect(clock.phase?.step == 5)

        clock.update(battery: increased, enabled: true, reduceMotion: false, displayAsleep: false)

        #expect(clock.phase?.kind == .burst)
        #expect(clock.phase?.step == 5)

        time.setElapsed(0.3)
        clock.update(battery: increased, enabled: true, reduceMotion: false, displayAsleep: false)
        #expect(clock.phase?.kind == .burst)
        #expect(clock.phase?.step == 6)

        clock.stop()
        sleeper.releaseAll()
        await sleeper.waitForCompletionCount(1)
    }

    @Test func levelAdvanceBoostsTheNextHeartbeatWithoutResettingSteadyPosition() async {
        let time = ManualDateProvider()
        let sleeper = ManualEventSleeper()
        let clock = makeClock(time: time, sleeper: sleeper)
        let initial = batteryStatus(61, charging: true)
        let increased = batteryStatus(62, charging: true)

        clock.update(battery: initial, enabled: true, reduceMotion: false, displayAsleep: false)
        await sleeper.waitForCallCount(1)
        time.setElapsed(0.6)
        clock.update(battery: initial, enabled: true, reduceMotion: false, displayAsleep: false)
        time.setElapsed(2.1)
        clock.update(battery: initial, enabled: true, reduceMotion: false, displayAsleep: false)
        #expect(clock.phase?.kind == .steady)
        #expect(clock.phase?.step == 30)

        clock.update(battery: increased, enabled: true, reduceMotion: false, displayAsleep: false)
        #expect(clock.phase?.kind == .steady)
        #expect(clock.phase?.step == 30)
        #expect(clock.phase?.heartbeatMultiplier == 1.35)

        time.setElapsed(2.2)
        clock.update(battery: increased, enabled: true, reduceMotion: false, displayAsleep: false)
        #expect(clock.phase?.step == 32)
        #expect(clock.phase?.heartbeatMultiplier == 1.35)

        time.setElapsed(2.4)
        clock.update(battery: increased, enabled: true, reduceMotion: false, displayAsleep: false)
        #expect(clock.phase?.kind == .steady)
        #expect(clock.phase?.step == 0)
        #expect(clock.phase?.heartbeatMultiplier == 1)

        clock.stop()
        sleeper.releaseAll()
        await sleeper.waitForCompletionCount(1)
        #expect(sleeper.callCount == 1)
    }

    private func assertStopsImmediately(
        battery: BatteryStatus? = nil,
        enabled: Bool,
        reduceMotion: Bool,
        displayAsleep: Bool
    ) async {
        let time = ManualDateProvider()
        let sleeper = ManualEventSleeper()
        let clock = makeClock(time: time, sleeper: sleeper)

        clock.update(
            battery: batteryStatus(61, charging: true),
            enabled: true,
            reduceMotion: false,
            displayAsleep: false
        )
        await sleeper.waitForCallCount(1)

        clock.update(
            battery: battery ?? batteryStatus(61, charging: true),
            enabled: enabled,
            reduceMotion: reduceMotion,
            displayAsleep: displayAsleep
        )
        #expect(clock.phase == nil)
        #expect(clock.isRunning == false)

        sleeper.releaseAll()
        await sleeper.waitForCompletionCount(1)
        #expect(sleeper.callCount == 1)
    }

    private func makeClock(
        time: ManualDateProvider,
        sleeper: ManualEventSleeper
    ) -> ChargingEffectClock {
        ChargingEffectClock(
            now: { time.now },
            sleep: { await sleeper.sleep($0) }
        )
    }

    private func batteryStatus(_ percentage: Int, charging: Bool) -> BatteryStatus {
        BatteryStatus(
            rawPercentage: percentage,
            isPresent: true,
            isCharging: charging,
            isLowPowerMode: false,
            isConnectedToPower: charging
        )
    }
}

@MainActor
private final class ManualDateProvider {
    private let start = Date(timeIntervalSince1970: 1_000)
    private(set) var elapsed: TimeInterval = 0

    var now: Date {
        start.addingTimeInterval(elapsed)
    }

    func advance(_ duration: Duration) {
        elapsed += duration.timeInterval
    }

    func setElapsed(_ interval: TimeInterval) {
        elapsed = interval
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
