import Foundation
import XCTest
@testable import StorageCleanerMac

final class BatteryChargeLimitServiceTests: XCTestCase {
    func testReadOnlyStateMatrixSeparatesEffectiveAndManualLimits() throws {
        let cases: [(Bool, Int, Int?, UInt64?, Bool?, BatteryChargeLimitSource, Bool)] = [
            (false, 100, 80, 1, true, .optimized, false),
            (false, 80, 85, nil, true, .optimized, false),
            (true, 90, 85, 1, true, .manualAndOptimized, false),
            (true, 80, 80, 1, true, .manual, false),
            (false, 80, 100, 1, false, .none, false),
            (false, 80, 100, 1, true, .unknown, false),
            (false, 80, 100, nil, false, .none, false),
            (false, 80, 80, 2, nil, .unknown, false),
            (false, 80, nil, nil, nil, .unknown, false),
            (false, 80, 100, 3, false, .none, true),
            (true, 80, 100, 3, false, .manual, true),
        ]
        for (enabled, manual, effective, smart, maxLimited, source, temporary) in cases {
            let state = try XCTUnwrap(BatteryChargeLimitState.resolve(
                manualLimitEnabled: enabled,
                manualLimit: manual,
                availableLimits: [100, 95, 90, 85, 80, 85],
                effectiveLimit: effective,
                smartChargingRawValue: smart,
                maxLimited: maxLimited
            ))
            XCTAssertEqual(state.target.rawValue, enabled ? manual : 100)
            XCTAssertEqual(state.effectiveLimit, effective)
            XCTAssertEqual(state.availableTargets.map(\.rawValue), [80, 85, 90, 95, 100])
            XCTAssertEqual(state.source, source)
            XCTAssertEqual(state.smartChargingTemporarilyDisabled, temporary)
        }
    }

    func testOnlyObservedSmartChargingValuesHaveKnownSemantics() {
        XCTAssertEqual(BatterySmartChargingState(rawValue: 1), .enabled)
        XCTAssertEqual(BatterySmartChargingState(rawValue: 3), .temporarilyDisabled)
        for value: UInt64? in [nil, 0, 2, 4, UInt64.max] {
            XCTAssertEqual(BatterySmartChargingState(rawValue: value), .unknown)
        }
    }

    func testUnavailableAndInvalidReadersDoNotInventAnEffectiveLimit() throws {
        for effective in [0, 101, -1, Int.max] {
            let state = try XCTUnwrap(BatteryChargeLimitState.resolve(
                manualLimitEnabled: false,
                manualLimit: 80,
                availableLimits: [80, 100],
                effectiveLimit: effective
            ))
            XCTAssertNil(state.effectiveLimit)
            XCTAssertEqual(state.source, .unknown)
        }
        XCTAssertNil(BatteryChargeLimitState.resolve(
            manualLimitEnabled: nil, manualLimit: 80, availableLimits: [80, 100],
            effectiveLimit: 100, smartChargingRawValue: 3, maxLimited: false
        ))
        XCTAssertNil(BatteryChargeLimitState.resolve(
            manualLimitEnabled: false, manualLimit: 80, availableLimits: [],
            effectiveLimit: 80, smartChargingRawValue: 1, maxLimited: true
        ))
    }

    @MainActor
    func testOptimizedFullChargeIgnoresLegacyOverridePermissionAndWaitsForReadback() async {
        let before = reading(manual: false, effective: 80, smart: 1, maxLimited: true)
        let after = reading(manual: false, effective: 100, smart: 3, maxLimited: false)
        let client = FakeBatterySmartChargeClient(readings: [before, before, before, after])
        var waits = 0
        let result = await BatteryFullChargeService.requestToFull(
            using: client, snapshot: pausedBattery,
            wait: { waits += 1 }
        )
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(client.operations, [.temporarilyDisableSmartCharging])
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(client.targets, [])
        // 电池快照仍为接电但未充电；接受依据只来自上限回读。
        XCTAssertEqual(pausedBattery.isCharging, false)
    }

    @MainActor
    func testManualFullChargeUsesOnlyTemporaryManualOverrideAndKeepsTarget() async {
        let before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        let after = reading(manual: true, effective: 100, smart: 1, maxLimited: false)
        let client = FakeBatterySmartChargeClient(readings: [before, after])
        let result = await BatteryFullChargeService.requestToFull(
            using: client, snapshot: pausedBattery, wait: {}
        )
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit])
        XCTAssertEqual(client.targets, [])
        XCTAssertEqual(after.chargeLimitState?.target.rawValue, 80)
    }

    @MainActor
    func testLegacyPauseRequiresBothEngagementAndPermission() async {
        for engaged in [false, true] {
            for allowed in [false, true] {
                var before = reading(manual: false, effective: nil, smart: nil, maxLimited: true)
                // 旧式挂起并非上限策略：缺少上限读数，maxLimited 为 false。
                before.engagement = BatteryChargingEngagement(
                    obcEngaged: engaged, maxLimited: false, chargingOverrideAllowed: allowed
                )
                let client = FakeBatterySmartChargeClient(readings: [before])
                let result = await BatteryFullChargeService.requestToFull(
                    using: client, snapshot: pausedBattery, wait: {}
                )
                XCTAssertEqual(result, engaged && allowed ? .verificationFailed : .noActiveLimit)
                XCTAssertEqual(client.operations, engaged && allowed ? [.temporarilyEnableCharging] : [])
            }
        }
    }

    @MainActor
    func testLegacyPauseMustTransitionEngagementOrOverridePermission() async {
        var before = reading(manual: false, effective: nil, smart: nil, maxLimited: false)
        before.engagement = BatteryChargingEngagement(obcEngaged: true, maxLimited: false, chargingOverrideAllowed: true)
        for afterEngagement in [
            BatteryChargingEngagement(obcEngaged: false, maxLimited: false, chargingOverrideAllowed: true),
            BatteryChargingEngagement(obcEngaged: true, maxLimited: false, chargingOverrideAllowed: false),
        ] {
            var after = before
            after.engagement = afterEngagement
            let client = FakeBatterySmartChargeClient(readings: [before, after])
            let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: {})
            XCTAssertEqual(result, .accepted)
            XCTAssertEqual(client.operations, [.temporarilyEnableCharging])
        }
    }

    @MainActor
    func testReviewUnchangedSmartOneAt100DoesNotUseSmartOverride() async {
        var before = reading(manual: false, effective: 100, smart: 1, maxLimited: false)
        before.engagement = BatteryChargingEngagement(obcEngaged: true, maxLimited: false, chargingOverrideAllowed: true)
        XCTAssertEqual(before.source, .none)
        let client = FakeBatterySmartChargeClient(readings: [before])
        let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: {})
        XCTAssertEqual(result, .verificationFailed)
        XCTAssertEqual(client.operations, [.temporarilyEnableCharging])
        XCTAssertEqual(client.readCount, 32)
    }

    @MainActor
    func testContradictoryLimitFailsClosedBeforeAndAfterWriting() async {
        let contradictory = reading(manual: false, effective: 100, smart: 1, maxLimited: true)
        XCTAssertEqual(contradictory.source, .unknown)
        XCTAssertFalse(contradictory.confirmsFullCharge)
        let noWrite = FakeBatterySmartChargeClient(readings: [contradictory])
        let closed = await BatteryFullChargeService.requestToFull(using: noWrite, snapshot: pausedBattery, wait: {})
        XCTAssertEqual(closed, .unsupported)
        XCTAssertEqual(noWrite.operations, [])
        let client = FakeBatterySmartChargeClient(readings: [
            reading(manual: false, effective: 80, smart: 1, maxLimited: true), contradictory,
        ])
        let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: {})
        XCTAssertEqual(result, .verificationFailed)
        XCTAssertEqual(client.operations, [.temporarilyDisableSmartCharging])
    }

    @MainActor
    func testAlreadyUnlimitedNeverWritesForAnySource() async {
        for manual in [false, true] {
            for smart: UInt64? in [nil, 1, 3] {
                let before = reading(manual: manual, effective: 100, smart: smart, maxLimited: false)
                let client = FakeBatterySmartChargeClient(readings: [before])
                let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: { XCTFail("不得等待") })
                XCTAssertEqual(result, .noActiveLimit)
                XCTAssertEqual(client.operations, [])
                XCTAssertEqual(client.readCount, 1)
            }
        }
    }

    @MainActor
    func testManualAndOptimizedWritesManualThenSmartOnlyWhenStillLimited() async {
        var before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        before.manualLimit = 90
        XCTAssertEqual(before.source, .manualAndOptimized)
        let full = reading(manual: true, effective: 100, smart: 3, maxLimited: false)
        // 第一轮只立即回读一次；仍有优化限制就进入第二步，无须先耗尽手动等待。
        let client = FakeBatterySmartChargeClient(readings: [before, before, full])
        var waits = 0
        let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: { waits += 1 })
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit, .temporarilyDisableSmartCharging])
        XCTAssertEqual(waits, 0)
        XCTAssertEqual(client.readCount, 3)
        XCTAssertEqual(client.readCountsAtRequest, [1, 2])
        XCTAssertEqual(client.targets, [])
    }

    @MainActor
    func testManualAndOptimizedStopsAfterFirstStepWhenFull() async {
        var before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        before.manualLimit = 90
        let full = reading(manual: true, effective: 100, smart: 1, maxLimited: false)
        let client = FakeBatterySmartChargeClient(readings: [before, full])
        let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: { XCTFail("无需等待") })
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit])
        XCTAssertEqual(client.readCount, 2)
    }

    @MainActor
    func testManualAndOptimizedUnchangedReadbackFailsAfterBothWindows() async {
        var before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        before.manualLimit = 90
        let client = FakeBatterySmartChargeClient(readings: [before])
        var waits = 0
        let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: { waits += 1 })
        XCTAssertEqual(result, .verificationFailed)
        XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit, .temporarilyDisableSmartCharging])
        XCTAssertEqual(waits, 30, "并存来源只在第二步等最多约三秒")
        XCTAssertEqual(client.readCount, 33)
        XCTAssertEqual(client.readCountsAtRequest, [1, 2])
    }

    func testSystemOnlyLimitCanBeShownWithoutInventingManualTargets() throws {
        let before = BatterySmartChargeReading(
            supportsManualChargeLimit: false, manualLimitEnabled: false,
            effectiveLimit: 80, smartChargingRawValue: 1,
            engagement: BatteryChargingEngagement(obcEngaged: false, maxLimited: true, chargingOverrideAllowed: false))
        let state = try XCTUnwrap(before.chargeLimitState)
        XCTAssertEqual(state.source, .optimized)
        XCTAssertEqual(state.effectiveLimit, 80)
        XCTAssertEqual(state.availableTargets, [], "不支持手动上限时不得生成选择项")
    }

    @MainActor
    func testRejectedStepStopsSequenceAndNeverReportsSuccess() async {
        var before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        before.manualLimit = 90
        for rejections in [[false], [true, false]] {
            let client = FakeBatterySmartChargeClient(readings: [before])
            client.requestResponses = rejections
            let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: {})
            XCTAssertEqual(result, rejections.count == 1
                ? .rejected : .optimizedChargingRejectedAfterManualLift(effectiveLimit: 80))
            XCTAssertEqual(client.operations, rejections.count == 1
                ? [.temporarilyDisableManualLimit] : [.temporarilyDisableManualLimit, .temporarilyDisableSmartCharging])
            XCTAssertEqual(client.readCount, rejections.count == 1 ? 1 : 3)
        }
    }

    @MainActor
    func testCombinedLimitWaitsOnlyForSecondStepAndRequiresItsTransition() async {
        var before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        before.manualLimit = 90
        let manualLifted = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        let full = reading(manual: true, effective: 100, smart: 3, maxLimited: false)
        let client = FakeBatterySmartChargeClient(readings: [before, manualLifted, manualLifted, manualLifted, full])
        var waits = 0
        let result = await BatteryFullChargeService.requestToFull(
            using: client, snapshot: pausedBattery, wait: { waits += 1 }
        )
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit, .temporarilyDisableSmartCharging])
        XCTAssertEqual(client.readCountsAtRequest, [1, 2])
        XCTAssertEqual(client.readCount, 5)
        XCTAssertEqual(waits, 2, "总计只等第二步的两个 100 ms 间隔")
        XCTAssertEqual(client.targets, [])
    }

    @MainActor
    func testManualSourceKeepsFirstVerificationWindowBeforeSecondStep() async {
        let before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        XCTAssertEqual(before.source, .manual)
        let full = reading(manual: true, effective: 100, smart: 3, maxLimited: false)
        let client = FakeBatterySmartChargeClient(readings: [before] + Array(repeating: before, count: 31) + [full])
        var waits = 0
        let result = await BatteryFullChargeService.requestToFull(
            using: client, snapshot: pausedBattery, wait: { waits += 1 }
        )
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit, .temporarilyDisableSmartCharging])
        XCTAssertEqual(client.readCountsAtRequest, [1, 32])
        XCTAssertEqual(client.readCount, 33)
        XCTAssertEqual(waits, 30, "手动来源仍等满原有 30 个间隔再按回读决定第二步")
    }

    @MainActor
    func testCombinedFirstReadCannotStartSecondStepWhenSmartOrLimitIsUnverifiable() async {
        var before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        before.manualLimit = 90
        let cases = [
            reading(manual: true, effective: 80, smart: 3, maxLimited: true),
            reading(manual: true, effective: 100, smart: 1, maxLimited: true),
            BatterySmartChargeReading(),
        ]
        for after in cases {
            let client = FakeBatterySmartChargeClient(readings: [before, after])
            let result = await BatteryFullChargeService.requestToFull(
                using: client, snapshot: pausedBattery, wait: { XCTFail("并存首步不能等待") }
            )
            XCTAssertEqual(result, .verificationFailed)
            XCTAssertEqual(client.readCount, 2)
            XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit])
        }
    }

    @MainActor
    func testSecondRejectionRecordsManualStepAndUsesFreshReadbackEvenWhenUnknown() async {
        for combined in [false, true] {
            var before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
            if combined { before.manualLimit = 90 }
            for effective: Int? in [85, nil, 100] {
                let afterRejection = effective.map {
                    reading(manual: true, effective: $0, smart: 1, maxLimited: $0 < 100)
                } ?? BatterySmartChargeReading()
                let firstReadCount = combined ? 1 : 31
                let client = FakeBatterySmartChargeClient(readings:
                    [before] + Array(repeating: before, count: firstReadCount) + [afterRejection])
                client.requestResponses = [true, false]
                var waits = 0
                let result = await BatteryFullChargeService.requestToFull(
                    using: client, snapshot: pausedBattery, wait: { waits += 1 }
                )
                XCTAssertEqual(result, .optimizedChargingRejectedAfterManualLift(effectiveLimit: effective))
                XCTAssertNotEqual(result, .accepted, "第二步拒绝不能按满充成功处理")
                XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit, .temporarilyDisableSmartCharging])
                XCTAssertEqual(client.readCount, firstReadCount + 2, "拒绝后仅补一次回读")
                XCTAssertEqual(waits, combined ? 0 : 30)
                XCTAssertEqual(client.targets, [])
            }
        }
    }

    @MainActor
    func testSecondStepRequiresSmartOneAndNeverFallsBackWhenMissing() async {
        let before = reading(manual: true, effective: 80, smart: 1, maxLimited: true)
        for raw: UInt64? in [nil, 0, 2, 3, 4] {
            let after = reading(manual: true, effective: 80, smart: raw, maxLimited: true)
            let client = FakeBatterySmartChargeClient(readings: [before, after])
            let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: {})
            XCTAssertEqual(result, .verificationFailed)
            XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit])
        }
        let client = FakeBatterySmartChargeClient(readings: [before])
        client.availableOperations.remove(.temporarilyDisableSmartCharging)
        let result = await BatteryFullChargeService.requestToFull(using: client, snapshot: pausedBattery, wait: {})
        XCTAssertEqual(result, .unsupported)
        XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit])
    }

    @MainActor
    func testEffective100OrUnlimitedFlagIsEnoughWithoutChargingCurrent() async {
        let before = reading(manual: false, effective: 80, smart: 1, maxLimited: true)
        var effectiveOnly = reading(manual: false, effective: 100, smart: 3, maxLimited: true)
        effectiveOnly.engagement = nil
        let flagOnly = reading(manual: false, effective: nil, smart: 3, maxLimited: false)
        for after in [effectiveOnly, flagOnly] {
            let client = FakeBatterySmartChargeClient(readings: [before, after])
            let result = await BatteryFullChargeService.requestToFull(
                using: client, snapshot: pausedBattery, wait: {}
            )
            XCTAssertEqual(result, .accepted)
            XCTAssertEqual(client.operations, [.temporarilyDisableSmartCharging])
        }
    }

    @MainActor
    func testOverridePermissionChangeAloneDoesNotConfirmFullCharge() async {
        var before = reading(manual: true, effective: 80, smart: nil, maxLimited: true)
        before.engagement = BatteryChargingEngagement(
            obcEngaged: false, maxLimited: true, chargingOverrideAllowed: true
        )
        let after = reading(manual: true, effective: 80, smart: nil, maxLimited: true)
        let client = FakeBatterySmartChargeClient(readings: [before, after])
        var waits = 0
        let result = await BatteryFullChargeService.requestToFull(
            using: client, snapshot: pausedBattery, wait: { waits += 1 }
        )
        XCTAssertEqual(result, .verificationFailed)
        XCTAssertEqual(waits, 30)
        XCTAssertEqual(client.readCount, 32)
        XCTAssertEqual(client.operations, [.temporarilyDisableManualLimit])
    }

    @MainActor
    func testTemporarySmartStateAloneDoesNotConfirmFullCharge() async {
        let before = reading(manual: false, effective: 80, smart: 1, maxLimited: true)
        let after = reading(manual: false, effective: 80, smart: 3, maxLimited: true)
        let client = FakeBatterySmartChargeClient(readings: [before, after])
        let result = await BatteryFullChargeService.requestToFull(
            using: client, snapshot: pausedBattery, wait: {}
        )
        XCTAssertEqual(result, .verificationFailed)
    }

    @MainActor
    func testMissingTemporaryMethodFailsClosedForEverySourceWithoutFallback() async {
        var legacy = reading(manual: false, effective: 100, smart: nil, maxLimited: false)
        legacy.engagement = BatteryChargingEngagement(
            obcEngaged: true, maxLimited: false, chargingOverrideAllowed: true
        )
        let cases: [(BatterySmartChargeReading, BatteryFullChargeOperation)] = [
            (reading(manual: false, effective: 80, smart: 1, maxLimited: true), .temporarilyDisableSmartCharging),
            (reading(manual: true, effective: 80, smart: nil, maxLimited: true), .temporarilyDisableManualLimit),
            (legacy, .temporarilyEnableCharging),
        ]
        for (before, missing) in cases {
            let client = FakeBatterySmartChargeClient(readings: [before])
            client.availableOperations.remove(missing)
            let result = await BatteryFullChargeService.requestToFull(
                using: client, snapshot: pausedBattery, wait: { XCTFail("不得等待") }
            )
            XCTAssertEqual(result, .unsupported)
            XCTAssertEqual(client.operations, [])
        }
    }

    @MainActor
    func testMissingReadersAndUnknownSourcePreventAnyWrite() async {
        var noReadback = reading(manual: false, effective: nil, smart: 1, maxLimited: true)
        noReadback.engagement = nil
        let unknown = reading(manual: false, effective: 80, smart: 2, maxLimited: nil)
        var missingManualFlag = reading(manual: false, effective: 80, smart: 1, maxLimited: true)
        missingManualFlag.manualLimitEnabled = nil
        for before in [noReadback, unknown, missingManualFlag] {
            let client = FakeBatterySmartChargeClient(readings: [before])
            let result = await BatteryFullChargeService.requestToFull(
                using: client, snapshot: pausedBattery, wait: {}
            )
            XCTAssertEqual(result, .unsupported)
            XCTAssertEqual(client.operations, [])
        }
        let result = await BatteryFullChargeService.requestToFull(
            using: nil, snapshot: pausedBattery, wait: {}
        )
        XCTAssertEqual(result, .unsupported)
        XCTAssertNil(BatteryFullChargeService.currentChargeLimitState(using: nil))
    }

    @MainActor
    func testMissingReadbackAfterWriteIsNotSuccess() async {
        let before = reading(manual: false, effective: 80, smart: 1, maxLimited: true)
        let client = FakeBatterySmartChargeClient(readings: [before, BatterySmartChargeReading()])
        let result = await BatteryFullChargeService.requestToFull(
            using: client, snapshot: pausedBattery, wait: {}
        )
        XCTAssertEqual(result, .verificationFailed)
        XCTAssertEqual(client.operations, [.temporarilyDisableSmartCharging])
    }

    @MainActor
    func testRejectedRequestAndCancelledVerificationAreNotSuccess() async {
        let before = reading(manual: false, effective: 80, smart: 1, maxLimited: true)
        let rejected = FakeBatterySmartChargeClient(readings: [before])
        rejected.requestAccepted = false
        let rejection = await BatteryFullChargeService.requestToFull(
            using: rejected, snapshot: pausedBattery, wait: { XCTFail("不得等待") }
        )
        XCTAssertEqual(rejection, .rejected)
        XCTAssertEqual(rejected.readCount, 1)

        let cancelled = FakeBatterySmartChargeClient(readings: [before])
        let cancellation = await BatteryFullChargeService.requestToFull(
            using: cancelled, snapshot: pausedBattery, wait: { throw CancellationError() }
        )
        XCTAssertEqual(cancellation, .verificationFailed)
        XCTAssertEqual(cancelled.readCount, 2)
    }

    @MainActor
    func testPreflightNeverReadsOrWritesPowerUIWhenNotEligible() async {
        let cases: [(BatteryPowerSnapshot?, BatteryFullChargeResult)] = [
            (nil, .unsupported),
            (battery(percent: 80, charging: false, source: .batteryPower), .requiresACPower),
            (battery(percent: 100, charging: false), .alreadyFull),
            (battery(percent: 80, charging: true), .alreadyCharging),
            (battery(percent: nil, charging: false), .unsupported),
        ]
        for (snapshot, expected) in cases {
            let client = FakeBatterySmartChargeClient(readings: [])
            let result = await BatteryFullChargeService.requestToFull(
                using: client, snapshot: snapshot, wait: { XCTFail("不得等待") }
            )
            XCTAssertEqual(result, expected)
            XCTAssertEqual(client.readCount, 0)
            XCTAssertEqual(client.operations, [])
        }
    }

    @MainActor
    func testD5SamplingAndRefreshNeverWriteAnyChargingSetting() throws {
        let defaults = try makeDefaults()
        let cases = [
            reading(manual: false, effective: 80, smart: 1, maxLimited: true),
            reading(manual: true, effective: 80, smart: nil, maxLimited: true),
            reading(manual: false, effective: 100, smart: 3, maxLimited: false),
            reading(manual: false, effective: 80, smart: 2, maxLimited: nil),
        ]
        for before in cases {
            let client = FakeBatterySmartChargeClient(readings: [before])
            for _ in 0..<4 {
                XCTAssertEqual(BatteryFullChargeService.currentChargeLimitState(using: client), before.chargeLimitState)
                let state = BatteryFullChargeService.reconcileSystemTarget(using: client, defaults: defaults)
                XCTAssertEqual(state, before.chargeLimitState)
                XCTAssertEqual(BatteryChargeTarget.stored(in: defaults), state?.target)
            }
            XCTAssertEqual(client.operations, [])
            XCTAssertEqual(client.targets, [])
            XCTAssertEqual(client.matchCount, 0)
        }
    }

    @MainActor
    func testD5UnavailableSamplingLeavesPreferenceUntouched() throws {
        let defaults = try makeDefaults()
        let target = try XCTUnwrap(BatteryChargeTarget(rawValue: 90))
        target.save(in: defaults)
        let client = FakeBatterySmartChargeClient(readings: [BatterySmartChargeReading()])
        XCTAssertNil(BatteryFullChargeService.reconcileSystemTarget(using: client, defaults: defaults))
        XCTAssertEqual(BatteryChargeTarget.stored(in: defaults), target)
        XCTAssertEqual(client.operations, [])
        XCTAssertEqual(client.targets, [])
    }

    @MainActor
    func testManualPicker100ChangesOnlyManualLimitEvenWhenOptimizedLimitRemains80() async throws {
        let defaults = try makeDefaults()
        let client = FakeBatterySmartChargeClient(readings: [
            reading(manual: true, effective: 80, smart: 1, maxLimited: true),
        ])
        let result = await BatteryFullChargeService.setPreferredTarget(
            .full, using: client, defaults: defaults, wait: {}
        )
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(client.targets, [.full])
        XCTAssertEqual(client.operations, [])
        XCTAssertEqual(BatteryChargeTarget.stored(in: defaults), .full)
    }

    @MainActor
    func testManualTargetPersistsOnlyAfterReadbackAndRejectsUnavailableTargets() async throws {
        let defaults = try makeDefaults()
        let client = FakeBatterySmartChargeClient(readings: [
            reading(manual: false, effective: 80, smart: 1, maxLimited: true),
        ])
        client.targetMatches = false
        let target = try XCTUnwrap(BatteryChargeTarget(rawValue: 90))
        let failed = await BatteryFullChargeService.setPreferredTarget(
            target, using: client, defaults: defaults, wait: {}
        )
        XCTAssertEqual(failed, .verificationFailed)
        XCTAssertEqual(client.matchCount, 10)
        XCTAssertEqual(BatteryChargeTarget.stored(in: defaults), .protected)
        client.targetMatches = true
        let applied = await BatteryFullChargeService.setPreferredTarget(
            target, using: client, defaults: defaults, wait: {}
        )
        XCTAssertEqual(applied, .applied)
        XCTAssertEqual(BatteryChargeTarget.stored(in: defaults), target)
        let unsupported = await BatteryFullChargeService.setPreferredTarget(
            try XCTUnwrap(BatteryChargeTarget(rawValue: 70)),
            using: client, defaults: defaults, wait: {}
        )
        XCTAssertEqual(unsupported, .unsupported)
        XCTAssertEqual(client.targets, [target, target])
        XCTAssertEqual(client.operations, [])
    }

    private var pausedBattery: BatteryPowerSnapshot { battery(percent: 80, charging: false) }

    private func battery(
        percent: Int?, charging: Bool, source: BatteryPowerSource = .acPower
    ) -> BatteryPowerSnapshot {
        BatteryPowerSnapshot(
            chargePercent: percent, isCharging: charging, powerSource: source,
            timeToEmptyMinutes: nil, timeToFullChargeMinutes: nil
        )
    }

    private func reading(
        manual: Bool, effective: Int?, smart: UInt64?, maxLimited: Bool?
    ) -> BatterySmartChargeReading {
        BatterySmartChargeReading(
            supportsManualChargeLimit: true,
            manualLimitEnabled: manual,
            manualLimit: 80,
            availableLimits: [80, 85, 90, 95, 100],
            effectiveLimit: effective,
            smartChargingRawValue: smart,
            engagement: maxLimited.map {
                BatteryChargingEngagement(obcEngaged: false, maxLimited: $0, chargingOverrideAllowed: false)
            }
        )
    }

    /// 临时目录里的绝对路径域，测试结束自动清理（D48）。
    private func makeDefaults() throws -> UserDefaults {
        TestPreferenceDomain.make(for: self)
    }
}

@MainActor
private final class FakeBatterySmartChargeClient: BatterySmartChargeClient {
    let readings: [BatterySmartChargeReading]
    var availableOperations = Set(BatteryFullChargeOperation.allCases)
    var operations: [BatteryFullChargeOperation] = []
    var readCountsAtRequest: [Int] = []
    var targets: [BatteryChargeTarget] = []
    var readCount = 0
    var matchCount = 0
    var requestAccepted = true
    var requestResponses: [Bool] = []
    var targetAccepted = true
    var targetMatches = true

    init(readings: [BatterySmartChargeReading]) { self.readings = readings }

    func read() -> BatterySmartChargeReading {
        let index = min(readCount, readings.count - 1)
        readCount += 1
        return index >= 0 ? readings[index] : BatterySmartChargeReading()
    }

    func supportsFullCharge(_ operation: BatteryFullChargeOperation) -> Bool {
        availableOperations.contains(operation)
    }

    func requestFullCharge(_ operation: BatteryFullChargeOperation) -> Bool {
        operations.append(operation)
        readCountsAtRequest.append(readCount)
        if !requestResponses.isEmpty { return requestResponses.removeFirst() }
        return requestAccepted
    }

    func setChargeTarget(_ target: BatteryChargeTarget) -> Bool {
        targets.append(target)
        return targetAccepted
    }

    func matchesChargeTarget(_ target: BatteryChargeTarget) -> Bool {
        matchCount += 1
        return targetMatches
    }
}
