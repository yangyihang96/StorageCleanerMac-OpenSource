import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacBenchmarkServiceTests: XCTestCase {
    func testSelectableProfilesUseExpectedVersionsAndSampleCounts() async {
        for profile in BenchmarkProfile.allCases {
            let expectedSampleCount: Int
            let expectedWorkloadVersion: String
            switch profile {
            case .standard:
                expectedSampleCount = 3
                expectedWorkloadVersion = "mac-benchmark-standard-v6"
            case .quick:
                expectedSampleCount = 3
                expectedWorkloadVersion = "mac-benchmark-quick-v3"
            case .full:
                expectedSampleCount = 5
                expectedWorkloadVersion = "mac-benchmark-full-v3"
            }
            let runner = ScriptedBenchmarkWorkloadRunner()
            let preflight = SequencedBenchmarkPreflight(states: [.nominal])
            let progress = BenchmarkProgressRecorder()
            let service = makeService(runner: runner, preflight: preflight)

            let result = await service.run(profile: profile) { update in
                await progress.append(update)
            }

            XCTAssertNil(result.failure)
            XCTAssertTrue(result.isComplete)
            XCTAssertEqual(result.workloadVersion, expectedWorkloadVersion)
            XCTAssertEqual(result.profile, profile)
            XCTAssertEqual(
                result.measurements.map(\.component),
                BenchmarkComponent.allCases
            )
            XCTAssertTrue(
                result.measurements.allSatisfy {
                    $0.samples.count == expectedSampleCount
                        && $0.unit == $0.component.metricUnit(for: profile)
                }
            )
            XCTAssertEqual(result.capabilitySet, .all)
            XCTAssertNotNil(result.postflight)
            let captureCount = await preflight.captureCount()
            let cleanupCount = await runner.cleanupCount()
            XCTAssertEqual(captureCount, 7)
            XCTAssertEqual(cleanupCount, 1)
            for component in BenchmarkComponent.allCases {
                let callCount = await runner.callCount(for: component)
                XCTAssertEqual(callCount, expectedSampleCount)
            }

            let updates = await progress.values()
            let expectedTotal = expectedSampleCount * BenchmarkComponent.allCases.count
            XCTAssertEqual(updates.count, expectedTotal + 2)
            XCTAssertEqual(updates.first?.stage, .preflight)
            XCTAssertEqual(updates.first?.completedSampleCount, 0)
            XCTAssertEqual(updates.last?.stage, .finalizing)
            XCTAssertEqual(updates.last?.completedSampleCount, expectedTotal)
            XCTAssertEqual(updates.last?.totalSampleCount, expectedTotal)
            XCTAssertEqual(updates.last?.progress, 1)
            XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { lhs, rhs in
                rhs.completedSampleCount >= lhs.completedSampleCount
                    && rhs.progress >= lhs.progress
                    && rhs.elapsedSeconds >= lhs.elapsedSeconds
            })
        }
    }

    func testEveryStageRechecksEnvironmentBeforeStartingItsWorkload() async {
        let states: [BenchmarkPreflightState] = [
            .nominal,
            .nominal,
            .seriousThermal,
        ]
        let runner = ScriptedBenchmarkWorkloadRunner()
        let preflight = SequencedBenchmarkPreflight(states: states)
        let service = makeService(runner: runner, preflight: preflight)

        let result = await service.run(profile: .quick)

        XCTAssertEqual(result.failure, .safetyCheck(.thermalNotNominal))
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.completedAt)
        XCTAssertNil(result.postflight)
        XCTAssertEqual(result.capabilitySet, .none)
        XCTAssertTrue(result.measurements.isEmpty)
        let captureCount = await preflight.captureCount()
        let singleCallCount = await runner.callCount(for: .cpuSingle)
        let multiCallCount = await runner.callCount(for: .cpuMulti)
        XCTAssertEqual(captureCount, 3)
        XCTAssertEqual(singleCallCount, 3)
        XCTAssertEqual(multiCallCount, 0)
    }

    func testUnsafePostflightRetainsCompletedSamplesAsRawOnlyEvidence() async {
        let preflight = SequencedBenchmarkPreflight(states: [
            .nominal,
            .nominal,
            .nominal,
            .nominal,
            .nominal,
            .nominal,
            .seriousThermal,
        ])
        let runner = ScriptedBenchmarkWorkloadRunner()
        let service = makeService(runner: runner, preflight: preflight)

        let result = await service.run(profile: .full)

        XCTAssertNil(result.failure)
        XCTAssertTrue(result.isComplete)
        XCTAssertNotNil(result.completedAt)
        XCTAssertEqual(result.postflight?.thermalState, .serious)
        XCTAssertEqual(result.postflight?.diskReliability, .verified)
        XCTAssertEqual(result.postflight?.availableDiskBytes, 100_000_000_000)
        XCTAssertEqual(result.postflight?.requiredDiskBytes, 1_000)
        XCTAssertEqual(result.postflight?.warnings, [.thermalNotNominal])
        XCTAssertEqual(result.capabilitySet, .all)
        XCTAssertEqual(result.measurements.count, BenchmarkComponent.allCases.count)
        XCTAssertFalse(MacBenchmarkScoring.hasComparableEnvironment(result))
        let captureCount = await preflight.captureCount()
        XCTAssertEqual(captureCount, 7)
        for component in BenchmarkComponent.allCases {
            let callCount = await runner.callCount(for: component)
            XCTAssertEqual(callCount, 5)
        }
    }

    func testFinalDiskAnomaliesRetainCompleteV6RawSamplesButCannotScore() async {
        for finalState in [
            BenchmarkPreflightState.failingDisk,
            .insufficientDisk,
        ] {
            let preflight = SequencedBenchmarkPreflight(states: [
                .nominal,
                .nominal,
                .nominal,
                .nominal,
                .nominal,
                .nominal,
                finalState,
            ])
            let service = makeService(
                runner: ScriptedBenchmarkWorkloadRunner(),
                preflight: preflight
            )

            let result = await service.run(profile: .standard)

            XCTAssertNil(result.failure)
            XCTAssertTrue(result.isComplete)
            XCTAssertEqual(result.measurements.count, BenchmarkComponent.allCases.count)
            XCTAssertTrue(result.postflight?.hasCompleteDiskSnapshot == true)
            XCTAssertFalse(MacBenchmarkScoring.hasComparableEnvironment(result))
            switch finalState {
            case .failingDisk:
                XCTAssertEqual(result.postflight?.diskReliability, .failing)
                XCTAssertEqual(result.postflight?.warnings, [.diskReliabilityFailing])
            case .insufficientDisk:
                XCTAssertFalse(result.postflight?.hasRequiredDiskCapacity == true)
                XCTAssertEqual(result.postflight?.warnings, [.insufficientDiskCapacity])
            default:
                XCTFail("测试仅应覆盖最终磁盘异常")
            }
        }
    }

    func testFinalPowerAndLowPowerAnomaliesAlsoRetainCompleteRawSamples() async {
        let cases: [(BenchmarkPreflightState, [BenchmarkSafetyIssue])] = [
            (BenchmarkPreflightState.unknownPower, [.acPowerRequired]),
            (.lowPower, [.lowPowerModeEnabled]),
        ]
        for (finalState, expectedWarnings) in cases {
            let preflight = SequencedBenchmarkPreflight(states: [
                .nominal,
                .nominal,
                .nominal,
                .nominal,
                .nominal,
                .nominal,
                finalState,
            ])
            let service = makeService(
                runner: ScriptedBenchmarkWorkloadRunner(),
                preflight: preflight
            )

            let result = await service.run(profile: .standard)

            XCTAssertNil(result.failure)
            XCTAssertTrue(result.isComplete)
            XCTAssertEqual(result.measurements.count, BenchmarkComponent.allCases.count)
            XCTAssertEqual(result.postflight?.warnings, expectedWarnings)
            XCTAssertFalse(MacBenchmarkScoring.hasComparableEnvironment(result))
        }
    }

    func testMalformedPostflightStillFailsClosedAndDoesNotPublishSamples() async {
        let preflight = SequencedBenchmarkPreflight(states: [
            .nominal,
            .nominal,
            .nominal,
            .nominal,
            .nominal,
            .nominal,
            .malformedWarnings,
        ])
        let service = makeService(
            runner: ScriptedBenchmarkWorkloadRunner(),
            preflight: preflight
        )

        let result = await service.run(profile: .standard)

        XCTAssertEqual(result.failure, .invalidResult)
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.completedAt)
        XCTAssertNil(result.postflight)
        XCTAssertEqual(result.capabilitySet, .none)
        XCTAssertTrue(result.measurements.isEmpty)
    }

    func testUnreadablePostflightStillFailsClosedAndDoesNotPublishSamples() async {
        let preflight = SequencedBenchmarkPreflight(
            states: [.nominal],
            failingCaptureIndex: 6
        )
        let service = makeService(
            runner: ScriptedBenchmarkWorkloadRunner(),
            preflight: preflight
        )

        let result = await service.run(profile: .standard)

        XCTAssertEqual(result.failure, .invalidResult)
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.completedAt)
        XCTAssertNil(result.postflight)
        XCTAssertEqual(result.capabilitySet, .none)
        XCTAssertTrue(result.measurements.isEmpty)
    }

    func testACLowPowerDiskAndCapacitySafetyGatesRunBeforeAnyKernel() async {
        let cases: [(BenchmarkPreflightState, MacBenchmarkFailure)] = [
            (.unknownPower, .safetyCheck(.acPowerRequired)),
            (.lowPower, .safetyCheck(.lowPowerModeEnabled)),
            (.failingDisk, .safetyCheck(.diskReliabilityFailing)),
            (.insufficientDisk, .safetyCheck(.insufficientDiskCapacity)),
        ]

        for (state, expectedFailure) in cases {
            let runner = ScriptedBenchmarkWorkloadRunner()
            let service = makeService(
                runner: runner,
                preflight: SequencedBenchmarkPreflight(states: [state])
            )

            let result = await service.run(profile: .quick)

            XCTAssertEqual(result.failure, expectedFailure)
            XCTAssertFalse(result.isComplete)
            XCTAssertTrue(result.measurements.isEmpty)
            XCTAssertEqual(result.capabilitySet, .none)
            let cleanupCount = await runner.cleanupCount()
            let kernelCallCount = await runner.totalKernelCallCount()
            XCTAssertEqual(cleanupCount, 0)
            XCTAssertEqual(kernelCallCount, 0)
        }
    }

    func testReentrantRunFailsFastAndHeavyLeaseBlocksOtherOperations() async {
        let gate = BenchmarkOperationGate()
        let runner = ScriptedBenchmarkWorkloadRunner(
            blockedComponent: .cpuSingle,
            gate: gate
        )
        let coordinator = HeavyWorkCoordinator()
        let service = makeService(
            runner: runner,
            preflight: SequencedBenchmarkPreflight(states: [.nominal]),
            coordinator: coordinator
        )

        let resultProbe = BenchmarkRunResultProbe()
        let first = Task {
            let result = await service.run(profile: .quick)
            await resultProbe.record(result)
            return result
        }
        await gate.waitUntilStarted()

        let ownerDuringFirstRun = await coordinator.activeOwner
        XCTAssertEqual(ownerDuringFirstRun, .benchmark)
        let second = await service.run(profile: .full)
        XCTAssertEqual(second.failure, .busy(activeTask: "benchmark"))
        XCTAssertTrue(second.measurements.isEmpty)
        do {
            _ = try await coordinator.acquire(owner: .networkTest)
            XCTFail("跑分期间其他重任务不得取得租约")
        } catch {
            XCTAssertEqual(
                error as? HeavyWorkCoordinator.Error,
                .busy(activeOwner: .benchmark)
            )
        }

        first.cancel()
        await gate.waitUntilCancellationObserved()
        guard let cancelled = await waitForResult(resultProbe) else {
            await gate.finishCleanup()
            _ = await first.value
            XCTFail("取消后 run 必须在物理 worker 退出前有界返回")
            return
        }
        XCTAssertEqual(cancelled.failure, .cancelled)
        XCTAssertTrue(cancelled.measurements.isEmpty)
        let ownerDuringCleanup = await coordinator.activeOwner
        XCTAssertEqual(ownerDuringCleanup, .benchmark)
        let third = await service.run(profile: .quick)
        XCTAssertEqual(third.failure, .busy(activeTask: "benchmark"))
        await gate.finishCleanup()

        await waitForCoordinatorToBecomeIdle(coordinator)
        let ownerAfterCancellation = await coordinator.activeOwner
        XCTAssertNil(ownerAfterCancellation)
    }

    func testCancellationDuringDiskReturnsBeforeCleanupAndQuarantinesLease() async {
        let gate = BenchmarkOperationGate()
        let runner = ScriptedBenchmarkWorkloadRunner(
            blockedComponent: .diskWrite,
            gate: gate
        )
        let coordinator = HeavyWorkCoordinator()
        let progress = BenchmarkProgressRecorder()
        let service = makeService(
            runner: runner,
            preflight: SequencedBenchmarkPreflight(states: [.nominal]),
            coordinator: coordinator
        )

        let resultProbe = BenchmarkRunResultProbe()
        let task = Task {
            let result = await service.run(profile: .quick) { update in
                await progress.append(update)
            }
            await resultProbe.record(result)
            return result
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.waitUntilCancellationObserved()

        guard let result = await waitForResult(resultProbe) else {
            await gate.finishCleanup()
            _ = await task.value
            XCTFail("取消后 run 必须在磁盘 worker 完成清理前有界返回")
            return
        }
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.completedAt)
        XCTAssertTrue(result.measurements.isEmpty)
        XCTAssertEqual(result.capabilitySet, .none)
        let ownerDuringCleanup = await coordinator.activeOwner
        XCTAssertEqual(ownerDuringCleanup, .benchmark)
        let updatesBeforeCleanup = await progress.values()
        let blockedRetry = await service.run(profile: .quick)
        XCTAssertEqual(blockedRetry.failure, .busy(activeTask: "benchmark"))

        await gate.finishCleanup()
        await waitForCoordinatorToBecomeIdle(coordinator)
        let ownerAfterCleanup = await coordinator.activeOwner
        XCTAssertNil(ownerAfterCleanup)
        try? await Task.sleep(for: .milliseconds(30))
        let updatesAfterCleanup = await progress.values()
        XCTAssertEqual(updatesAfterCleanup, updatesBeforeCleanup)
    }

    func testStageTimeoutReturnsBeforeNonresponsiveKernelAndQuarantinesLease() async {
        let gate = BenchmarkOperationGate()
        let sleeper = ManualBenchmarkSleeper()
        let runner = ScriptedBenchmarkWorkloadRunner(
            blockedComponent: .cpuSingle,
            gate: gate
        )
        let coordinator = HeavyWorkCoordinator()
        let progress = BenchmarkProgressRecorder()
        let timeouts = MacBenchmarkStageTimeouts(
            preflight: .seconds(30),
            cpuSingle: .seconds(30),
            cpuMulti: .seconds(30),
            gpu: .seconds(30),
            memory: .seconds(30),
            diskWrite: .seconds(30),
            diskRead: .seconds(30),
            finalizing: .seconds(30)
        )
        let service = makeService(
            runner: runner,
            preflight: SequencedBenchmarkPreflight(states: [.nominal]),
            coordinator: coordinator,
            timeouts: timeouts,
            sleep: { duration in try await sleeper.sleep(duration) }
        )

        let resultProbe = BenchmarkRunResultProbe()
        let task = Task {
            let result = await service.run(profile: .quick) { update in
                await progress.append(update)
            }
            await resultProbe.record(result)
            return result
        }
        await gate.waitUntilStarted()
        await sleeper.waitForRegistrationCount(2)
        await sleeper.triggerAll()
        await gate.waitUntilCancellationObserved()

        guard let result = await waitForResult(resultProbe) else {
            await gate.finishCleanup()
            _ = await task.value
            XCTFail("阶段超时必须在不响应取消的 kernel 退出前有界返回")
            return
        }
        XCTAssertEqual(result.failure, .timedOut(.cpuSingle))
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.measurements.isEmpty)
        let ownerDuringCleanup = await coordinator.activeOwner
        XCTAssertEqual(ownerDuringCleanup, .benchmark)
        let updatesAtTimeout = await progress.values()
        XCTAssertEqual(updatesAtTimeout.map(\.stage), [.preflight])
        let blockedRetry = await service.run(profile: .quick)
        XCTAssertEqual(blockedRetry.failure, .busy(activeTask: "benchmark"))
        do {
            _ = try await coordinator.acquire(owner: .networkTest)
            XCTFail("超时 worker 收尾期间网络测速不得取得租约")
        } catch {
            XCTAssertEqual(
                error as? HeavyWorkCoordinator.Error,
                .busy(activeOwner: .benchmark)
            )
        }
        await gate.finishCleanup()

        await waitForCoordinatorToBecomeIdle(coordinator)
        let ownerAfterTimeout = await coordinator.activeOwner
        XCTAssertNil(ownerAfterTimeout)
        try? await Task.sleep(for: .milliseconds(30))
        let updatesAfterTimeout = await progress.values()
        XCTAssertEqual(updatesAfterTimeout, updatesAtTimeout)

        let retryService = makeService(
            runner: runner,
            preflight: SequencedBenchmarkPreflight(states: [.nominal]),
            coordinator: coordinator
        )
        let retry = await retryService.run(profile: .quick)
        XCTAssertNil(retry.failure)
        XCTAssertTrue(retry.isComplete)
    }

    func testKernelFailuresMapToRawFailureWithoutPublishingPartialMeasurements() async {
        let cases: [(BenchmarkKernelError, MacBenchmarkFailure)] = [
            (.unavailable, .unsupported(.gpu)),
            (
                .checksumMismatch,
                .kernelFailure(component: .gpu, reason: .checksumMismatch)
            ),
            (
                .resourceLimit,
                .kernelFailure(component: .gpu, reason: .resourceLimit)
            ),
            (
                .systemFailure,
                .kernelFailure(component: .gpu, reason: .systemFailure)
            ),
        ]

        for (kernelError, expectedFailure) in cases {
            let runner = ScriptedBenchmarkWorkloadRunner(
                failingComponent: .gpu,
                kernelError: kernelError
            )
            let service = makeService(
                runner: runner,
                preflight: SequencedBenchmarkPreflight(states: [.nominal])
            )

            let result = await service.run(profile: .quick)

            XCTAssertEqual(result.failure, expectedFailure)
            XCTAssertFalse(result.isComplete)
            XCTAssertNil(result.completedAt)
            XCTAssertNil(result.postflight)
            XCTAssertTrue(result.measurements.isEmpty)
            XCTAssertEqual(result.capabilitySet, .none)
        }
    }

    func testMismatchedSamplesAreRejectedInsteadOfBecomingComplete() async {
        let runner = ScriptedBenchmarkWorkloadRunner(
            mismatchedChecksumComponent: .memory
        )
        let service = makeService(
            runner: runner,
            preflight: SequencedBenchmarkPreflight(states: [.nominal])
        )

        let result = await service.run(profile: .full)

        XCTAssertEqual(
            result.failure,
            .kernelFailure(component: .memory, reason: .checksumMismatch)
        )
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.measurements.isEmpty)
    }

    func testCoordinatorConflictReturnsBusyRawResultWithoutStartingWork() async throws {
        let coordinator = HeavyWorkCoordinator()
        let existingLease = try await coordinator.acquire(owner: .mainScan)
        let runner = ScriptedBenchmarkWorkloadRunner()
        let service = makeService(
            runner: runner,
            preflight: SequencedBenchmarkPreflight(states: [.nominal]),
            coordinator: coordinator
        )

        let result = await service.run(profile: .quick)

        XCTAssertEqual(result.failure, .busy(activeTask: "mainScan"))
        XCTAssertTrue(result.measurements.isEmpty)
        let cleanupCount = await runner.cleanupCount()
        let kernelCallCount = await runner.totalKernelCallCount()
        let ownerDuringConflict = await coordinator.activeOwner
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertEqual(kernelCallCount, 0)
        XCTAssertEqual(ownerDuringConflict, .mainScan)
        await coordinator.release(existingLease)
    }

    func testAlreadyCancelledTaskReturnsCancelledRawResultWithoutLeaseOrWork() async {
        let coordinator = HeavyWorkCoordinator()
        let runner = ScriptedBenchmarkWorkloadRunner()
        let service = makeService(
            runner: runner,
            preflight: SequencedBenchmarkPreflight(states: [.nominal]),
            coordinator: coordinator
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.run(profile: .quick)
        }
        let result = await task.value

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertTrue(result.measurements.isEmpty)
        let ownerAfterCancelledStart = await coordinator.activeOwner
        let cleanupCount = await runner.cleanupCount()
        let kernelCallCount = await runner.totalKernelCallCount()
        XCTAssertNil(ownerAfterCancelledStart)
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertEqual(kernelCallCount, 0)
    }

    func testSystemRunnerDerivesCapacityFromTheRealDiskKernelConfiguration() {
        let runner = SystemMacBenchmarkWorkloadRunner()

        XCTAssertEqual(
            runner.requiredDiskBytes(for: .standard),
            DiskBenchmarkKernel.requiredCapacity(
                forFileBytes: DiskBenchmarkKernel.Configuration.standard.quick.fileBytes
            )
        )
        XCTAssertEqual(
            runner.requiredDiskBytes(for: .quick),
            DiskBenchmarkKernel.requiredCapacity(
                forFileBytes: DiskBenchmarkKernel.Configuration.standard.quick.fileBytes
            )
        )
        XCTAssertEqual(
            runner.requiredDiskBytes(for: .full),
            DiskBenchmarkKernel.requiredCapacity(
                forFileBytes: DiskBenchmarkKernel.Configuration.standard.full.fileBytes
            )
        )
    }

    func testCPUMultiRecoveryPolicySeparatesQuickAndFullSamplingWindows() {
        XCTAssertEqual(MacBenchmarkService.cpuMultiRecoveryDelay(for: .standard), .seconds(2))
        XCTAssertEqual(MacBenchmarkService.cpuMultiRecoveryDelay(for: .quick), .seconds(2))
        XCTAssertEqual(MacBenchmarkService.cpuMultiRecoveryDelay(for: .full), .seconds(3))
    }
}

private extension MacBenchmarkServiceTests {
    func makeService(
        runner: any MacBenchmarkWorkloadRunning,
        preflight: any MacBenchmarkPreflighting,
        coordinator: HeavyWorkCoordinator = HeavyWorkCoordinator(),
        timeouts: MacBenchmarkStageTimeouts = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) -> MacBenchmarkService {
        let monotonicClock = BenchmarkTestMonotonicClock()
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        return MacBenchmarkService(
            heavyWorkCoordinator: coordinator,
            preflightService: preflight,
            workloadRunner: runner,
            environmentProvider: BenchmarkTestEnvironmentProvider(),
            timeouts: timeouts,
            now: { fixedDate },
            monotonicNow: { monotonicClock.next() },
            sleep: sleep,
            recoverySleep: { _ in }
        )
    }

    func waitForResult(
        _ probe: BenchmarkRunResultProbe
    ) async -> MacBenchmarkRawResult? {
        for _ in 0..<1_000 {
            if let result = await probe.value() { return result }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    func waitForCoordinatorToBecomeIdle(
        _ coordinator: HeavyWorkCoordinator
    ) async {
        for _ in 0..<1_000 {
            if await coordinator.activeOwner == nil { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum BenchmarkPreflightState: Sendable, Equatable {
    case nominal
    case seriousThermal
    case unknownPower
    case lowPower
    case failingDisk
    case insufficientDisk
    case malformedWarnings

    func snapshot(requiredDiskBytes: Int64) -> BenchmarkPreflight {
        let powerSource: BenchmarkPowerSource
        let lowPowerModeEnabled: Bool
        let thermalState: BenchmarkThermalState
        let diskReliability: BenchmarkDiskReliability
        let availableDiskBytes: Int64

        switch self {
        case .nominal:
            powerSource = .acPower
            lowPowerModeEnabled = false
            thermalState = .nominal
            diskReliability = .verified
            availableDiskBytes = 100_000_000_000
        case .seriousThermal:
            powerSource = .acPower
            lowPowerModeEnabled = false
            thermalState = .serious
            diskReliability = .verified
            availableDiskBytes = 100_000_000_000
        case .unknownPower:
            powerSource = .unknown
            lowPowerModeEnabled = false
            thermalState = .nominal
            diskReliability = .verified
            availableDiskBytes = 100_000_000_000
        case .lowPower:
            powerSource = .acPower
            lowPowerModeEnabled = true
            thermalState = .nominal
            diskReliability = .verified
            availableDiskBytes = 100_000_000_000
        case .failingDisk:
            powerSource = .acPower
            lowPowerModeEnabled = false
            thermalState = .nominal
            diskReliability = .failing
            availableDiskBytes = 100_000_000_000
        case .insufficientDisk:
            powerSource = .acPower
            lowPowerModeEnabled = false
            thermalState = .nominal
            diskReliability = .verified
            availableDiskBytes = max(0, requiredDiskBytes - 1)
        case .malformedWarnings:
            powerSource = .acPower
            lowPowerModeEnabled = false
            thermalState = .nominal
            diskReliability = .verified
            availableDiskBytes = 100_000_000_000
        }

        let draft = BenchmarkPreflight(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            powerSource: powerSource,
            batteryPercent: 80,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState,
            diskReliability: diskReliability,
            availableDiskBytes: availableDiskBytes,
            requiredDiskBytes: requiredDiskBytes,
            warnings: []
        )
        return BenchmarkPreflight(
            capturedAt: draft.capturedAt,
            powerSource: draft.powerSource,
            batteryPercent: draft.batteryPercent,
            lowPowerModeEnabled: draft.lowPowerModeEnabled,
            thermalState: draft.thermalState,
            diskReliability: draft.diskReliability,
            availableDiskBytes: draft.availableDiskBytes,
            requiredDiskBytes: draft.requiredDiskBytes,
            warnings: self == .malformedWarnings
                ? [.thermalNotNominal]
                : MacBenchmarkPreflightPolicy.warnings(for: draft)
        )
    }
}

private actor SequencedBenchmarkPreflight: MacBenchmarkPreflighting {
    private let states: [BenchmarkPreflightState]
    private let failingCaptureIndex: Int?
    private var captures = 0

    init(
        states: [BenchmarkPreflightState],
        failingCaptureIndex: Int? = nil
    ) {
        self.states = states.isEmpty ? [.nominal] : states
        self.failingCaptureIndex = failingCaptureIndex
    }

    func capture(requiredDiskBytes: Int64) async throws -> BenchmarkPreflight {
        try Task.checkCancellation()
        if captures == failingCaptureIndex {
            captures += 1
            throw BenchmarkPreflightReadError()
        }
        let index = min(captures, states.count - 1)
        captures += 1
        return states[index].snapshot(requiredDiskBytes: requiredDiskBytes)
    }

    func captureCount() -> Int { captures }
}

private struct BenchmarkPreflightReadError: Error {}

private struct BenchmarkTestEnvironmentProvider: MacBenchmarkEnvironmentProviding {
    func metadata(preflight: BenchmarkPreflight) -> BenchmarkEnvironmentMetadata {
        BenchmarkEnvironmentMetadata(
            architecture: .arm64,
            chipName: "Apple Test",
            activeProcessorCount: 10,
            physicalMemoryBytes: 32_000_000_000,
            powerSource: preflight.powerSource,
            thermalState: preflight.thermalState,
            operatingSystemVersion: "macOS 26",
            appVersion: "1.5.0",
            appBuild: "1"
        )
    }
}

private actor ScriptedBenchmarkWorkloadRunner: MacBenchmarkWorkloadRunning {
    nonisolated func requiredDiskBytes(for profile: BenchmarkProfile) -> Int64 {
        1_000
    }

    private let blockedComponent: BenchmarkComponent?
    private let gate: BenchmarkOperationGate?
    private let failingComponent: BenchmarkComponent?
    private let kernelError: BenchmarkKernelError?
    private let mismatchedChecksumComponent: BenchmarkComponent?
    private var cleanups = 0
    private var calls: [BenchmarkComponent: Int] = [:]

    init(
        blockedComponent: BenchmarkComponent? = nil,
        gate: BenchmarkOperationGate? = nil,
        failingComponent: BenchmarkComponent? = nil,
        kernelError: BenchmarkKernelError? = nil,
        mismatchedChecksumComponent: BenchmarkComponent? = nil
    ) {
        self.blockedComponent = blockedComponent
        self.gate = gate
        self.failingComponent = failingComponent
        self.kernelError = kernelError
        self.mismatchedChecksumComponent = mismatchedChecksumComponent
    }

    func cleanupTemporaryArtifacts() async throws {
        try Task.checkCancellation()
        cleanups += 1
    }

    func runCPUSingle(profile: BenchmarkProfile) async throws -> BenchmarkComponentSample {
        try await sample(for: .cpuSingle)
    }

    func runCPUMulti(
        profile: BenchmarkProfile,
        activeProcessorCount: Int
    ) async throws -> BenchmarkComponentSample {
        XCTAssertGreaterThan(activeProcessorCount, 0)
        return try await sample(for: .cpuMulti)
    }

    func runGPU(profile: BenchmarkProfile) async throws -> BenchmarkComponentSample {
        try await sample(for: .gpu)
    }

    func runMemory(profile: BenchmarkProfile) async throws
        -> BenchmarkComponentSample
    {
        try await sample(for: .memory)
    }

    func runDisk(profile: BenchmarkProfile) async throws -> MacBenchmarkDiskSamplePair {
        let write = try await sample(for: .diskWrite)
        let read = try await sample(for: .diskRead)
        return MacBenchmarkDiskSamplePair(write: write, read: read)
    }

    func cleanupCount() -> Int { cleanups }

    func callCount(for component: BenchmarkComponent) -> Int {
        calls[component, default: 0]
    }

    func totalKernelCallCount() -> Int {
        calls.values.reduce(0, +)
    }

    private func sample(
        for component: BenchmarkComponent
    ) async throws -> BenchmarkComponentSample {
        let callIndex = calls[component, default: 0]
        calls[component] = callIndex + 1

        if blockedComponent == component, let gate {
            await gate.runUntilCleanupFinishes()
        }
        if failingComponent == component, let kernelError {
            throw kernelError
        }

        let componentIndex = BenchmarkComponent.allCases.firstIndex(of: component) ?? 0
        let checksum = mismatchedChecksumComponent == component && callIndex == 2
            ? UInt64(9_999)
            : UInt64(componentIndex + 1)
        return BenchmarkComponentSample(
            value: 100 + Double(componentIndex),
            elapsedSeconds: 0.01 + Double(callIndex) / 1_000,
            checksum: checksum
        )
    }
}

private actor BenchmarkOperationGate {
    private var didStart = false
    private var didObserveCancellation = false
    private var cleanupCanFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []

    func runUntilCleanupFinishes() async {
        didStart = true
        let starts = startWaiters
        startWaiters.removeAll()
        starts.forEach { $0.resume() }

        await withTaskCancellationHandler {
            guard !cleanupCanFinish else { return }
            await withCheckedContinuation { continuation in
                cleanupWaiters.append(continuation)
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !didObserveCancellation else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func finishCleanup() {
        cleanupCanFinish = true
        let waiters = cleanupWaiters
        cleanupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func recordCancellation() {
        didObserveCancellation = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor BenchmarkProgressRecorder {
    private var updates: [MacBenchmarkProgress] = []

    func append(_ update: MacBenchmarkProgress) {
        updates.append(update)
    }

    func values() -> [MacBenchmarkProgress] { updates }
}

private actor BenchmarkRunResultProbe {
    private var result: MacBenchmarkRawResult?

    func record(_ result: MacBenchmarkRawResult) {
        self.result = result
    }

    func value() -> MacBenchmarkRawResult? { result }
}

private actor ManualBenchmarkSleeper {
    private var registrations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var registrationWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    func sleep(_ duration: Duration) async throws {
        _ = duration
        await withCheckedContinuation { continuation in
            registrations += 1
            waiters.append(continuation)
            resumeRegistrationWaitersIfNeeded()
        }
        try Task.checkCancellation()
    }

    func waitForRegistrationCount(_ count: Int) async {
        guard registrations < count else { return }
        await withCheckedContinuation { continuation in
            registrationWaiters.append((count, continuation))
        }
    }

    func triggerAll() {
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func resumeRegistrationWaitersIfNeeded() {
        var pending: [(
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in registrationWaiters {
            if registrations >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        registrationWaiters = pending
    }
}

private final class BenchmarkTestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1_000_000
        return value
    }
}
