import Foundation
import XCTest

@testable import StorageCleanerMac

@MainActor
final class BenchmarkV7CoordinatorWorkloadIntegrationTests: XCTestCase {
    func testRunSubtestRecordsSuccessfulRealElapsedTime() async throws {
        let runner = SystemBenchmarkV7WorkloadRunner()
        let recorder = BenchmarkV7WorkloadExecutionRecorder()

        let value = try await runner.runSubtest(
            category: .cpu,
            workloadID: "fixture.success",
            repetition: 2,
            executionRecorder: recorder
        ) {
            try await Task.sleep(for: .milliseconds(5))
            return 42
        }

        XCTAssertEqual(value, 42)
        let execution = try XCTUnwrap(recorder.records.first)
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(execution.category, .cpu)
        XCTAssertEqual(execution.workloadID, "fixture.success")
        XCTAssertEqual(execution.repetition, 2)
        XCTAssertEqual(execution.status, .completed)
        XCTAssertNil(execution.failureReason)
        XCTAssertGreaterThan(execution.elapsedSeconds, 0)
        XCTAssertGreaterThanOrEqual(execution.endedAt, execution.startedAt)
    }

    func testRunSubtestRecordsCancellationWithElapsedWork() async throws {
        let runner = SystemBenchmarkV7WorkloadRunner()
        let recorder = BenchmarkV7WorkloadExecutionRecorder()
        let task = Task {
            try await runner.runSubtest(
                category: .memory,
                workloadID: "fixture.cancel",
                repetition: 1,
                executionRecorder: recorder
            ) {
                try await Task.sleep(for: .seconds(30))
            }
        }

        for _ in 0..<100 where recorder.activeCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(recorder.activeCount, 1)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let execution = try XCTUnwrap(recorder.records.first)
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(execution.status, .cancelled)
        XCTAssertEqual(execution.failureReason, "The workload was cancelled.")
        XCTAssertGreaterThanOrEqual(execution.elapsedSeconds, 0)
    }

    func testRunSubtestTimeoutRegistersLateOperationAndPreservesIdentity() async throws {
        let runner = SystemBenchmarkV7WorkloadRunner()
        let recorder = BenchmarkV7WorkloadExecutionRecorder()
        let gate = ControlledBenchmarkSubtestGate()
        let task = Task {
            try await runner.runSubtest(
                category: .storage,
                workloadID: "storage.fixture.blocked",
                repetition: 3,
                executionRecorder: recorder,
                timeout: .seconds(1),
                sleep: { _ in await gate.waitForTimeoutSignal() }
            ) {
                await gate.runNonCooperativeOperation()
            }
        }

        await gate.waitUntilOperationStarts()
        await gate.fireTimeout()
        do {
            _ = try await task.value
            XCTFail("Expected the subtest timeout")
        } catch let fault as BenchmarkV7SubtestTerminalFault {
            guard case .timedOut = fault.kind else {
                return XCTFail("Expected a timed-out terminal fault")
            }
            XCTAssertEqual(fault.context, BenchmarkV7TimeoutContext(
                phase: .running,
                category: .storage,
                workloadID: "storage.fixture.blocked"
            ))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let execution = try XCTUnwrap(recorder.records.first)
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(execution.category, .storage)
        XCTAssertEqual(execution.workloadID, "storage.fixture.blocked")
        XCTAssertEqual(execution.repetition, 3)
        XCTAssertEqual(execution.status, .timedOut)
        XCTAssertEqual(
            execution.failureReason,
            "timedOut phase=running category=storage workload=storage.fixture.blocked"
        )
        XCTAssertEqual(recorder.pendingLateOperationCount, 1)

        await gate.releaseOperation()
        await recorder.waitForLateOperations()
        XCTAssertEqual(recorder.pendingLateOperationCount, 0)
    }

    func testInnerSubtestTimeoutQuarantinesHeavyWorkUntilKernelActuallyStops() async throws {
        let gate = ControlledBenchmarkSubtestGate()
        let heavyWorkCoordinator = HeavyWorkCoordinator()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: InnerTimeoutV7Runner(gate: gate),
            heavyWorkCoordinator: heavyWorkCoordinator,
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )
        let task = Task {
            await coordinator.run(plan: .custom(categories: [.cpu]))
        }

        await gate.waitUntilOperationStarts()
        await gate.fireTimeout()
        let result = await task.value
        let context = BenchmarkV7TimeoutContext(
            phase: .running,
            category: .cpu,
            workloadID: "cpu.fixture.blocked"
        )
        XCTAssertEqual(result.failure, .restartRequired(context))
        XCTAssertTrue(result.failure?.requiresApplicationRestart == true)
        XCTAssertTrue(result.runtimeWarnings.contains { $0.contains("restart required") })
        XCTAssertEqual(result.workloadExecutions?.first?.status, .timedOut)
        XCTAssertEqual(result.workloadExecutions?.first?.workloadID, "cpu.fixture.blocked")
        let ownerAtTimeout = await heavyWorkCoordinator.activeOwner
        XCTAssertEqual(ownerAtTimeout, .benchmark)

        let blockedRetry = await coordinator.run(plan: .custom(categories: [.cpu]))
        XCTAssertEqual(blockedRetry.failure, .restartRequired(context))

        await gate.releaseOperation()
        for _ in 0..<1_000 where await heavyWorkCoordinator.activeOwner != nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let ownerAfterCleanup = await heavyWorkCoordinator.activeOwner
        XCTAssertNil(ownerAfterCleanup)
        let lease = try await heavyWorkCoordinator.acquire(owner: .benchmark)
        await heavyWorkCoordinator.release(lease)
    }

    func testOuterTimeoutAlsoWaitsForNestedLateSubtestBeforeClearingQuarantine() async {
        let gate = ControlledBenchmarkSubtestGate()
        let heavyWorkCoordinator = HeavyWorkCoordinator()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: InnerTimeoutV7Runner(gate: gate),
            heavyWorkCoordinator: heavyWorkCoordinator,
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider(),
            timeouts: .testing(milliseconds: 20)
        )
        let task = Task {
            await coordinator.run(plan: .custom(categories: [.cpu]))
        }

        await gate.waitUntilOperationStarts()
        let result = await task.value
        XCTAssertEqual(result.failure, .restartRequired(BenchmarkV7TimeoutContext(
            phase: .running,
            category: .cpu,
            workloadID: "cpu.fixture.blocked"
        )))
        let ownerAtTimeout = await heavyWorkCoordinator.activeOwner
        XCTAssertEqual(ownerAtTimeout, .benchmark)

        // Let the injected timer task observe cancellation, then release the
        // non-cooperative kernel. Quarantine must survive until both finish.
        await gate.fireTimeout()
        let ownerBeforeKernelRelease = await heavyWorkCoordinator.activeOwner
        XCTAssertEqual(ownerBeforeKernelRelease, .benchmark)
        await gate.releaseOperation()
        for _ in 0..<1_000 where await heavyWorkCoordinator.activeOwner != nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let ownerAfterCleanup = await heavyWorkCoordinator.activeOwner
        XCTAssertNil(ownerAfterCleanup)
    }

    func testCoordinatorPersistsStructuredPartialFailureAndCompletedMetrics() async throws {
        let reason = "The workload returned a non-finite measurement."
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: PartialFailureV7Runner(reason: reason),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )

        let result = await coordinator.run(
            plan: .custom(categories: [.cpu, .gpu])
        )

        XCTAssertEqual(
            result.failure,
            .validationFailed("gpu/gpu.compute.fp16: \(reason)")
        )
        XCTAssertEqual(result.completionStatus, .partiallyCompleted)
        XCTAssertTrue(result.isPartiallyCompleted)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.metrics.map(\.manifest.id), ["fixture.cpu"])
        XCTAssertEqual(result.workloadFailure, BenchmarkV7WorkloadFailureRecord(
            category: .gpu,
            workloadID: "gpu.compute.fp16",
            reason: reason
        ))
        XCTAssertEqual(
            result.runtimeWarnings,
            ["v7 workload failure: category=gpu workload=gpu.compute.fp16 reason=\(reason)"]
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = BenchmarkV7HistoryRepository(
            storageURL: directory.appendingPathComponent("history.json")
        )
        try await repository.save(result)
        let stored = await repository.load()
        XCTAssertEqual(stored, [result])
        XCTAssertEqual(stored.first?.completionStatus, .partiallyCompleted)
        XCTAssertEqual(stored.first?.metrics.map(\.manifest.id), ["fixture.cpu"])
    }

    func testFullStandardSessionFailsClosedWhenScoringProducesNoScores() async {
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: ScriptedV7Runner(),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )
        let recorder = V7StateRecorder()
        let expectedFailure = BenchmarkV7Failure.validationFailed(
            "Official benchmark Core/Experience score validation failed."
        )

        let result = await coordinator.run(plan: .standard) { state in
            await recorder.append(state)
        }
        let states = await recorder.values()

        XCTAssertEqual(result.failure, expectedFailure)
        XCTAssertEqual(result.completionStatus, .partiallyCompleted)
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.completedAt)
        XCTAssertNil(result.coreScore)
        XCTAssertNil(result.experienceScore)
        XCTAssertEqual(result.metrics.map(\.manifest.id), ["fixture.cpu"])
        XCTAssertTrue(states.contains { $0.phase == .failed })
        XCTAssertFalse(states.contains { $0.phase == .completed })
    }

    func testSystemRunnerWrapsKernelFailureWithSubtestAndActionableReason() async {
        let invalidCPU = CPUBenchmarkV7Kernel(configuration: .init(
            quick: .testing,
            standard: .testing,
            sampleCount: 0,
            maximumSampleSeconds: 2,
            maximumWorkerCount: 4
        ))
        let runner = SystemBenchmarkV7WorkloadRunner(cpuKernel: invalidCPU)
        let recorder = BenchmarkV7WorkloadExecutionRecorder()

        do {
            _ = try await runner.run(
                plan: .quick,
                categories: [.cpu],
                targetDirectory: FileManager.default.temporaryDirectory,
                executionRecorder: recorder,
                progress: { _, _, _, _ in }
            )
            XCTFail("Expected the invalid CPU configuration to fail closed")
        } catch let failure as BenchmarkV7WorkloadFailure {
            XCTAssertEqual(failure.record.category, .cpu)
            XCTAssertEqual(failure.record.workloadID, "cpu.single.mixed")
            XCTAssertEqual(
                failure.record.reason,
                "The workload configuration was rejected."
            )
            XCTAssertTrue(failure.completedMetrics.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let execution = recorder.records.first
        XCTAssertEqual(recorder.records.count, 1)
        XCTAssertEqual(execution?.category, .cpu)
        XCTAssertEqual(execution?.workloadID, "cpu.single.mixed")
        XCTAssertEqual(execution?.repetition, 1)
        XCTAssertEqual(execution?.status, .failed)
        XCTAssertEqual(
            execution?.failureReason,
            "The workload configuration was rejected."
        )
        XCTAssertGreaterThanOrEqual(execution?.elapsedSeconds ?? -1, 0)
    }

    func testCoordinatorPersistsRawKernelFailureWithProgressContext() async throws {
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: RawKernelFailureV7Runner(),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )

        let result = await coordinator.run(
            plan: .custom(categories: [.gpu])
        )
        let expectedFailure = BenchmarkV7WorkloadFailureRecord(
            category: .gpu,
            workloadID: "gpu.compute.fp16",
            reason: "The workload returned a non-finite, zero, or out-of-budget measurement."
        )

        XCTAssertEqual(
            result.failure,
            .validationFailed("A benchmark kernel failed validation.")
        )
        XCTAssertEqual(result.workloadFailure, expectedFailure)
        XCTAssertEqual(result.completionStatus, .failed)
        XCTAssertTrue(result.metrics.isEmpty)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = BenchmarkV7HistoryRepository(
            storageURL: directory.appendingPathComponent("history.json")
        )
        try await repository.save(result)
        let stored = await repository.load()
        XCTAssertEqual(stored.first?.workloadFailure, expectedFailure)

        let encoded = try JSONEncoder().encode(result)
        let roundTrip = try JSONDecoder().decode(BenchmarkV7Result.self, from: encoded)
        XCTAssertEqual(roundTrip.workloadFailure, expectedFailure)
        XCTAssertEqual(roundTrip.completionStatus, .failed)
    }

    func testCoordinatorRedactsUnknownFailureDetailsFromWarningsAndJSON() async throws {
        let secret = "/Users/example/private/secret-token"
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: SecretFailureV7Runner(secret: secret),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )

        let result = await coordinator.run(
            plan: .custom(categories: [.gpu])
        )

        XCTAssertEqual(result.failure, .internalFailure)
        XCTAssertNil(result.workloadFailure)
        XCTAssertEqual(result.runtimeWarnings, ["v7 workload failure: internal failure"])
        XCTAssertFalse(result.runtimeWarnings.joined(separator: " ").contains(secret))

        let encoded = try JSONEncoder().encode(result)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
    }

    func testPreflightTimeoutWarningUsesStableDescription() async throws {
        let blockingPreflight = BlockingFirstV7Preflight(report: fixturePreflight())
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: ScriptedV7Runner(),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: blockingPreflight,
            environmentProvider: FixedEnvironmentProvider(),
            timeouts: .testing(milliseconds: 20)
        )

        let result = await coordinator.run(
            plan: .custom(categories: [.cpu])
        )

        let timeoutContext = BenchmarkV7TimeoutContext(
            phase: .preflighting,
            category: nil,
            workloadID: "preflight"
        )
        XCTAssertEqual(result.failure, .restartRequired(timeoutContext))
        XCTAssertEqual(
            result.runtimeWarnings,
            [
                "v7 workload failure: operation termination unconfirmed "
                    + "phase=preflighting workload=preflight; restart required; "
                    + "cleanup quarantine remains active",
            ]
        )
        let encoded = try JSONEncoder().encode(result)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("BenchmarkV7TimedOutFault"))

        await blockingPreflight.releaseFirstCapture()
        await blockingPreflight.waitUntilFirstCaptureFinishes()
    }

    func testCoordinatorAllowsOnlyOneActiveSessionAndEchoesSuppliedIDs() async {
        let runner = ScriptedV7Runner(blockedRuns: [1])
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )
        let firstID = UUID()
        let rejectedID = UUID()

        let first = Task {
            await coordinator.run(sessionID: firstID, plan: .custom(categories: [.cpu]))
        }
        await runner.waitUntilRunStarts(1)

        let rejected = await coordinator.run(
            sessionID: rejectedID,
            plan: .custom(categories: [.cpu])
        )
        XCTAssertEqual(rejected.failure, .alreadyRunning)
        XCTAssertEqual(rejected.session.id, rejectedID)
        let runCount = await runner.runCount()
        XCTAssertEqual(runCount, 1)

        await runner.releaseRun(1)
        let completed = await first.value
        XCTAssertNil(completed.failure)
        XCTAssertEqual(completed.session.id, firstID)
    }

    func testStorageBlockReturnsPartialResultWithLegalSessionScopedStates() async throws {
        let warning = "Fixture power warning."
        let preflight = fixturePreflight(
            checks: [
                BenchmarkV7PreflightCheck(
                    issue: .acPowerRecommended,
                    severity: .warning,
                    detail: warning
                ),
                BenchmarkV7PreflightCheck(
                    issue: .targetVolumeReadOnly,
                    severity: .blocked,
                    detail: "Fixture storage block."
                ),
            ],
            blocked: [.storage]
        )
        let environment = FixedEnvironmentProvider().value
        let runner = ScriptedV7Runner()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: preflight),
            environmentProvider: FixedEnvironmentProvider()
        )
        let recorder = V7StateRecorder()
        let sessionID = UUID()
        let plan = BenchmarkV7Plan.custom(categories: [.cpu, .storage, .display])

        let result = await coordinator.run(sessionID: sessionID, plan: plan) { state in
            await recorder.append(state)
        }
        let states = await recorder.values()

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.failure)
        XCTAssertNil(result.coreScore)
        XCTAssertEqual(result.session.id, sessionID)
        XCTAssertEqual(result.session.categories, [.cpu, .display])
        XCTAssertEqual(result.metrics.map(\.manifest.category), [.cpu])
        XCTAssertEqual(result.environment, environment)
        XCTAssertEqual(result.versions.schemaVersion, BenchmarkV7VersionManifest.resultSchemaVersion)
        XCTAssertEqual(result.versions.planVersion, plan.planVersion)
        XCTAssertEqual(result.versions.workloadVersion, plan.workloadVersion)
        XCTAssertTrue(result.runtimeWarnings.contains(warning))
        XCTAssertTrue(result.runtimeWarnings.contains("Skipped blocked categories: storage."))
        XCTAssertTrue(result.runtimeWarnings.contains(
            "Display cadence was unavailable; no Display Experience metric was recorded."
        ))
        XCTAssertFalse(result.runtimeWarnings.contains { $0.contains("non-scoreable zero observations") })
        XCTAssertTrue(states.allSatisfy { $0.sessionID == sessionID })
        XCTAssertTrue(zip(states, states.dropFirst()).allSatisfy { current, next in
            current.canTransition(to: next)
        })
    }

    func testOfficialStorageHardBlockFailsBeforeAnyWorkloadStarts() async {
        let preflight = fixturePreflight(
            checks: [BenchmarkV7PreflightCheck(
                issue: .targetVolumeReadOnly,
                severity: .blocked,
                detail: "Fixture storage block."
            )],
            blocked: [.storage]
        )
        let runner = ScriptedV7Runner()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: preflight),
            environmentProvider: FixedEnvironmentProvider()
        )
        let recorder = V7StateRecorder()
        let official = OfficialBenchmarkPlan.current

        let result = await coordinator.run(
            plan: official.plan,
            categories: official.categories
        ) { state in
            await recorder.append(state)
        }

        XCTAssertEqual(result.failure, .preflightBlocked)
        XCTAssertEqual(result.resolvedCompletionStatus, .failed)
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.completedAt)
        let runCount = await runner.runCount()
        let states = await recorder.values()
        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(states.last?.phase, .failed)
    }

    func testForceContinuationNeverRestoresHardBlockedStorage() async {
        let preflight = fixturePreflight(
            checks: [BenchmarkV7PreflightCheck(
                issue: .targetVolumeReadOnly,
                severity: .blocked,
                detail: "Fixture storage block."
            )],
            blocked: [.storage]
        )
        let runner = ScriptedV7Runner()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: preflight),
            environmentProvider: FixedEnvironmentProvider()
        )

        let result = await coordinator.run(
            plan: .custom(categories: [.cpu, .storage]),
            forcePreflightContinuation: true
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.session.categories, [.cpu])
        XCTAssertTrue(result.runtimeWarnings.contains("Skipped blocked categories: storage."))
    }

    func testSafetyStoppedSustainedRecordNeverCompletesV7Session() async throws {
        let sustainedResult = try fixtureSafetyStoppedSustainedResult()
        XCTAssertTrue(sustainedResult.isComplete)
        XCTAssertFalse(sustainedResult.reachedTargetDuration)
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: ScriptedV7Runner(),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            sustainedService: FixedSustainedService(result: sustainedResult),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )
        let recorder = V7StateRecorder()

        let result = await coordinator.run(plan: .sustained) { state in
            await recorder.append(state)
        }

        XCTAssertEqual(
            result.failure,
            .validationFailed(
                "Sustained check stopped because the power source changed to battery."
            )
        )
        XCTAssertEqual(result.resolvedCompletionStatus, .failed)
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.completedAt)
        XCTAssertEqual(result.sustainedResult, sustainedResult)
        XCTAssertEqual(result.workloadFailure, BenchmarkV7WorkloadFailureRecord(
            category: .sustained,
            workloadID: "sustained",
            reason: "Sustained check stopped because the power source changed to battery."
        ))
        let states = await recorder.values()
        XCTAssertFalse(states.contains { $0.phase == .completed })
    }

    func testStoreIgnoresFirstRunProgressAfterLaterRunStarts() async throws {
        let runner = ScriptedV7Runner(blockedRuns: [2])
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )
        let store = try makeStore(v7Coordinator: coordinator)

        store.startV7(plan: .custom(categories: [.cpu]))
        await store.waitUntilIdle()
        store.startV7(plan: .custom(categories: [.cpu]))
        await runner.waitUntilRunStarts(2)
        let stateBeforeStaleProgress = store.v7State

        await runner.emitProgress(
            fromRun: 1,
            category: .cpu,
            workloadID: "stale-fixture",
            repetition: 99,
            fraction: 0.99
        )

        XCTAssertEqual(store.v7State, stateBeforeStaleProgress)
        await runner.releaseRun(2)
        await store.waitUntilIdle()
        XCTAssertEqual(store.v7State.phase, .completed)
        XCTAssertEqual(store.v7State.sessionID, stateBeforeStaleProgress.sessionID)
    }

    func testStorePublishesPreflightBeforeStartingAnyWorkload() async throws {
        let preflight = fixturePreflight()
        let runner = ScriptedV7Runner()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: preflight),
            environmentProvider: FixedEnvironmentProvider()
        )
        let store = try makeStore(v7Coordinator: coordinator)

        store.preflightV7(plan: .custom(categories: [.cpu]))
        for _ in 0..<100 where store.isV7Preflighting {
            await Task.yield()
        }

        XCTAssertFalse(store.isV7Preflighting)
        XCTAssertEqual(store.v7Preflight, preflight)
        XCTAssertEqual(store.v7State, .idle)
        XCTAssertFalse(store.isV7BenchmarkRunning)
        let runCount = await runner.runCount()
        XCTAssertEqual(runCount, 0)
    }

    func testStandalonePreflightTimeoutRequiresRestartEvenAfterLateCleanup() async throws {
        let blockingPreflight = BlockingFirstV7Preflight(report: fixturePreflight())
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: ScriptedV7Runner(),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: blockingPreflight,
            environmentProvider: FixedEnvironmentProvider(),
            timeouts: .testing(milliseconds: 20)
        )
        let store = try makeStore(v7Coordinator: coordinator)

        store.preflightV7(plan: .custom(categories: [.cpu]))
        await blockingPreflight.waitUntilFirstCaptureStarts()
        for _ in 0..<1_000 where store.isV7Preflighting {
            try? await Task.sleep(for: .milliseconds(1))
        }

        let timeoutContext = BenchmarkV7TimeoutContext(
            phase: .preflighting,
            category: nil,
            workloadID: "preflight"
        )
        XCTAssertFalse(store.isV7Preflighting)
        XCTAssertEqual(store.v7State.phase, .failed)
        XCTAssertEqual(store.v7State.failure, .restartRequired(timeoutContext))
        XCTAssertTrue(store.v7State.failure?.requiresApplicationRestart == true)
        XCTAssertNotNil(store.v7Preflight)

        await blockingPreflight.releaseFirstCapture()
        await blockingPreflight.waitUntilFirstCaptureFinishes()
        store.preflightV7(plan: .custom(categories: [.cpu]))
        for _ in 0..<100 where store.isV7Preflighting {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(store.v7State.failure, .restartRequired(timeoutContext))
    }

    func testCancellingV7IgnoresLateProgressAndNeverPublishesSuccess() async throws {
        let runner = ScriptedV7Runner(blockedRuns: [1])
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )
        let store = try makeStore(v7Coordinator: coordinator)

        store.startV7(plan: .custom(categories: [.cpu]))
        await runner.waitUntilRunStarts(1)
        store.cancelV7()
        XCTAssertEqual(store.v7State.phase, .cancelling)

        await runner.emitProgress(
            fromRun: 1,
            category: .cpu,
            workloadID: "late-progress",
            repetition: 2,
            fraction: 0.9
        )
        XCTAssertEqual(store.v7State.phase, .cancelling)

        await runner.releaseRun(1)
        await store.waitUntilIdle()
        XCTAssertEqual(store.v7State.phase, .cancelled)
        XCTAssertEqual(store.v7LatestResult?.failure, .cancelled)
        XCTAssertNil(store.v7LatestResult?.coreScore)
        XCTAssertEqual(store.v7LatestResult?.workloadExecutions?.count, 1)
        XCTAssertEqual(
            store.v7LatestResult?.workloadExecutions?.first?.status,
            .cancelled
        )
    }

    func testPersistencePhaseLatchesResultAndIgnoresLateCancellation() async throws {
        let runner = ScriptedV7Runner()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )
        let history = DelayedV7History()
        let store = try makeStore(
            v7Coordinator: coordinator,
            v7HistoryRepository: history
        )

        store.startV7(plan: .custom(categories: [.cpu]))
        await history.waitUntilFirstSaveStarts()
        store.cancelV7()
        XCTAssertEqual(store.v7State.phase, .persisting)

        await history.releaseFirstSave()
        await store.waitUntilIdle()

        XCTAssertEqual(store.v7State.phase, .completed)
        XCTAssertNil(store.v7LatestResult?.failure)
        XCTAssertEqual(store.v7LatestResult?.workloadExecutions?.first?.status, .completed)
        let records = await history.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.failure)
        XCTAssertEqual(records.first?.recordID, store.v7LatestResult?.recordID)
    }

    func testPromotionTimeoutRequiresRelaunchAndNeverLeavesStorePersisting() async throws {
        let runner = ScriptedV7Runner()
        let history = BlockingFirstSaveV7History(blockReplacement: true)
        let defaultsName = "BenchmarkV7PromotionTimeout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = try makeStore(
            v7Coordinator: BenchmarkV7Coordinator(
                workloadRunner: runner,
                heavyWorkCoordinator: HeavyWorkCoordinator(),
                preflightService: FixedV7Preflight(report: fixturePreflight()),
                environmentProvider: FixedEnvironmentProvider()
            ),
            v7HistoryRepository: history,
            v7PromotionRevocationDefaults: defaults,
            v7PersistenceTimeout: .milliseconds(20)
        )

        store.startV7(plan: .custom(categories: [.cpu]))
        await history.waitUntilFirstSaveStarts()
        await history.releaseFirstSave()
        await history.waitUntilReplacementStarts()
        await store.waitUntilIdle()

        let context = BenchmarkV7TimeoutContext(
            phase: .persisting,
            category: nil,
            workloadID: "history-promote"
        )
        XCTAssertEqual(store.v7State.failure, .restartRequired(context))
        XCTAssertFalse(store.isV7BenchmarkRunning)

        store.startV7(plan: .custom(categories: [.cpu]))
        try? await Task.sleep(for: .milliseconds(10))
        let runCount = await runner.runCount()
        XCTAssertEqual(runCount, 1)

        await history.releaseReplacement()
        var records: [BenchmarkV7Result] = []
        for _ in 0..<1_000 {
            records = await history.load()
            if records.first?.failure == nil { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.failure)
        XCTAssertEqual(store.v7State.failure, .restartRequired(context))

        let relaunchedStore = try makeStore(
            v7Coordinator: BenchmarkV7Coordinator(
                workloadRunner: ScriptedV7Runner(),
                heavyWorkCoordinator: HeavyWorkCoordinator(),
                preflightService: FixedV7Preflight(report: fixturePreflight()),
                environmentProvider: FixedEnvironmentProvider()
            ),
            v7HistoryRepository: history,
            v7PromotionRevocationDefaults: defaults
        )
        await relaunchedStore.loadHistory()
        XCTAssertTrue(relaunchedStore.v7History.isEmpty)
        XCTAssertNil(relaunchedStore.v7LatestResult)
        XCTAssertNil(relaunchedStore.latestOfficialV7Result)
    }

    func testTimeoutReturnsBeforeNonresponsiveRunnerAndQuarantinesUntilCleanup() async {
        let runner = ScriptedV7Runner(blockedRuns: [1])
        let heavyWorkCoordinator = HeavyWorkCoordinator()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: heavyWorkCoordinator,
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider(),
            timeouts: .testing(milliseconds: 20)
        )
        let recorder = V7StateRecorder()

        let result = await coordinator.run(
            plan: .custom(categories: [.cpu])
        ) { state in
            await recorder.append(state)
        }

        let context = BenchmarkV7TimeoutContext(
            phase: .running,
            category: .cpu,
            workloadID: "fixture.cpu.1"
        )
        XCTAssertEqual(result.failure, .restartRequired(context))
        XCTAssertEqual(result.workloadFailure, BenchmarkV7WorkloadFailureRecord(
            category: .cpu,
            workloadID: "fixture.cpu.1",
            reason: "timedOut phase=running category=cpu workload=fixture.cpu.1"
        ))
        let execution = result.workloadExecutions?.first
        XCTAssertEqual(result.workloadExecutions?.count, 1)
        XCTAssertEqual(execution?.category, .cpu)
        XCTAssertEqual(execution?.workloadID, "fixture.cpu.1")
        XCTAssertEqual(execution?.repetition, 1)
        XCTAssertEqual(execution?.status, .timedOut)
        XCTAssertEqual(
            execution?.failureReason,
            "timedOut phase=running category=cpu workload=fixture.cpu.1"
        )
        XCTAssertGreaterThan(execution?.elapsedSeconds ?? -1, 0)
        let ownerAtTimeout = await heavyWorkCoordinator.activeOwner
        XCTAssertEqual(ownerAtTimeout, .benchmark)

        let statesAtTimeout = await recorder.values()
        await runner.emitProgress(
            fromRun: 1,
            category: .cpu,
            workloadID: "late-success",
            repetition: 99,
            fraction: 1
        )
        let statesAfterLateProgress = await recorder.values()
        XCTAssertEqual(statesAfterLateProgress, statesAtTimeout)

        let blockedRetry = await coordinator.run(
            plan: .custom(categories: [.cpu])
        )
        XCTAssertEqual(blockedRetry.failure, .restartRequired(context))

        await runner.releaseRun(1)
        for _ in 0..<1_000 where await heavyWorkCoordinator.activeOwner != nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let ownerAfterCleanup = await heavyWorkCoordinator.activeOwner
        XCTAssertNil(ownerAfterCleanup)

        let retry = await coordinator.run(
            plan: .custom(categories: [.cpu])
        )
        XCTAssertEqual(retry.failure, .restartRequired(context))
        XCTAssertFalse(retry.isComplete)
    }

    func testPersistenceTimeoutNeverPublishesLateSuccessAndReturnsStoreToRetryableState() async throws {
        let runner = ScriptedV7Runner()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider(),
            timeouts: .testing(milliseconds: 20)
        )
        let history = BlockingFirstSaveV7History()
        let store = try makeStore(
            v7Coordinator: coordinator,
            v7HistoryRepository: history,
            v7PersistenceTimeout: .milliseconds(20)
        )

        store.startV7(plan: .custom(categories: [.cpu]))
        await history.waitUntilFirstSaveStarts()
        await store.waitUntilIdle()

        let context = BenchmarkV7TimeoutContext(
            phase: .persisting,
            category: nil,
            workloadID: "history-save"
        )
        let sessionID = try XCTUnwrap(store.v7LatestResult?.session.id)
        XCTAssertEqual(store.v7State, .failed(
            .timedOut(context),
            sessionID: sessionID
        ))
        XCTAssertEqual(store.v7LatestResult?.failure, .timedOut(context))
        XCTAssertEqual(
            store.v7LatestResult?.workloadExecutions?.first?.status,
            .completed
        )
        XCTAssertFalse(store.isV7BenchmarkRunning)
        let recordsBeforeRelease = await history.load()
        XCTAssertTrue(recordsBeforeRelease.isEmpty)

        await history.releaseFirstSave()
        var records: [BenchmarkV7Result] = []
        for _ in 0..<1_000 {
            records = await history.load()
            if records.count == 1, records.first?.failure == .timedOut(context) {
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.failure, .timedOut(context))
        XCTAssertEqual(records.first?.workloadExecutions?.first?.status, .completed)
        XCTAssertFalse(records.contains { $0.failure == nil })
    }

    func testFailedLateReplacementKeepsProvisionalRecordNonOfficialAfterReload() async throws {
        let runner = ScriptedV7Runner()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider(),
            timeouts: .testing(milliseconds: 20)
        )
        let history = BlockingFirstSaveV7History(failReplacement: true)
        let store = try makeStore(
            v7Coordinator: coordinator,
            v7HistoryRepository: history,
            v7PersistenceTimeout: .milliseconds(20)
        )

        store.startV7(plan: .custom(categories: [.cpu]))
        await history.waitUntilFirstSaveStarts()
        await store.waitUntilIdle()
        await history.releaseFirstSave()

        for _ in 0..<1_000 where store.v7State.failure != .persistenceFailed {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(store.v7State.failure, .persistenceFailed)
        XCTAssertNil(store.latestOfficialV7Result)

        let records = await history.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.failure, .persistenceFailed)
        XCTAssertFalse(records.contains { $0.failure == nil })

        let relaunchedStore = try makeStore(
            v7Coordinator: BenchmarkV7Coordinator(
                workloadRunner: ScriptedV7Runner(),
                heavyWorkCoordinator: HeavyWorkCoordinator(),
                preflightService: FixedV7Preflight(report: fixturePreflight()),
                environmentProvider: FixedEnvironmentProvider()
            ),
            v7HistoryRepository: history
        )
        await relaunchedStore.loadHistory()
        XCTAssertNil(relaunchedStore.latestOfficialV7Result)
        XCTAssertEqual(relaunchedStore.v7History.first?.failure, .persistenceFailed)
    }

    func testHistorySaveFailureDoesNotPublishAnUnsavedCompletedScore() async throws {
        let runner = ScriptedV7Runner()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider()
        )
        let history = FailingV7History()
        let store = try makeStore(
            v7Coordinator: coordinator,
            v7HistoryRepository: history
        )

        store.startV7(plan: .custom(categories: [.cpu]))
        await store.waitUntilIdle()

        XCTAssertEqual(store.v7State.phase, .failed)
        XCTAssertEqual(store.v7State.failure, .persistenceFailed)
        XCTAssertEqual(store.v7LatestResult?.failure, .persistenceFailed)
        XCTAssertNil(store.v7LatestResult?.coreScore)
        XCTAssertNil(store.latestOfficialV7Result)
        let records = await history.load()
        XCTAssertTrue(records.isEmpty)
    }

    func testHistoryReloadTimeoutPublishesPersistenceFailureAndLateReloadIsDiscarded() async throws {
        let runner = ScriptedV7Runner()
        let coordinator = BenchmarkV7Coordinator(
            workloadRunner: runner,
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: FixedV7Preflight(report: fixturePreflight()),
            environmentProvider: FixedEnvironmentProvider(),
            timeouts: .testing(milliseconds: 20)
        )
        let history = BlockingFirstReloadV7History()
        let store = try makeStore(
            v7Coordinator: coordinator,
            v7HistoryRepository: history,
            v7PersistenceTimeout: .milliseconds(20)
        )

        store.startV7(plan: .custom(categories: [.cpu]))
        await history.waitUntilFirstLoadStarts()
        await store.waitUntilIdle()

        XCTAssertEqual(store.v7State.phase, .failed)
        XCTAssertEqual(store.v7State.failure, .persistenceFailed)
        XCTAssertEqual(store.v7LatestResult?.failure, .persistenceFailed)
        XCTAssertFalse(store.isV7BenchmarkRunning)

        await history.releaseFirstLoad()
        await history.waitUntilFirstLoadFinishes()
        store.startV7(plan: .custom(categories: [.cpu]))
        await store.waitUntilIdle()

        XCTAssertEqual(store.v7State.phase, .completed)
        XCTAssertNil(store.v7LatestResult?.failure)
        let runCount = await runner.runCount()
        XCTAssertEqual(runCount, 2)
    }

    private func makeStore(
        v7Coordinator: BenchmarkV7Coordinator,
        v7HistoryRepository: any BenchmarkV7HistoryPersisting = InMemoryV7History(),
        v7PromotionRevocationDefaults: UserDefaults = .standard,
        v7PersistenceTimeout: Duration = BenchmarkV7TimeoutPolicy.standard.persistence
    ) throws -> MacBenchmarkStore {
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "fixture",
            verifiedBaselines: []
        )
        return MacBenchmarkStore(
            service: UnusedCoreService(),
            resultProcessor: MacBenchmarkResultProcessor(baselineCatalog: catalog),
            lifecycleCleaner: NoopLifecycleCleaner(),
            historyRepository: InMemoryV6History(),
            v7Coordinator: v7Coordinator,
            v7HistoryRepository: v7HistoryRepository,
            v7PromotionRevocationDefaults: v7PromotionRevocationDefaults,
            v7PersistenceTimeout: v7PersistenceTimeout
        )
    }

    private func fixturePreflight(
        checks: [BenchmarkV7PreflightCheck] = [],
        blocked: [BenchmarkV7Category] = []
    ) -> BenchmarkV7PreflightReport {
        BenchmarkV7PreflightReport(
            capturedAt: Date(timeIntervalSinceReferenceDate: 1),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            backgroundLoadRatio: 0.1,
            availableMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
            storageTarget: BenchmarkV7StorageTarget(
                volumeName: "Fixture",
                fileSystem: "APFS",
                availableBytes: 16 * 1_024 * 1_024 * 1_024,
                isReadOnly: false
            ),
            displayDescription: "Fixture display",
            checks: checks,
            blockedCategories: blocked
        )
    }
}

private struct FixedSustainedService: MacSustainedBenchmarkServicing {
    let result: MacSustainedBenchmarkResult

    func run(
        profile: MacSustainedBenchmarkProfile,
        coolingMode: MacSustainedCoolingMode,
        progress: @escaping @Sendable (MacSustainedBenchmarkProgress) async -> Void
    ) async -> MacSustainedBenchmarkResult {
        _ = profile
        _ = coolingMode
        _ = progress
        return result
    }
}

private func fixtureSafetyStoppedSustainedResult() throws
    -> MacSustainedBenchmarkResult
{
    let startedAt = Date(timeIntervalSinceReferenceDate: 100)
    let environment = FixedEnvironmentProvider().value
    let preflight = BenchmarkPreflight(
        capturedAt: startedAt.addingTimeInterval(1),
        powerSource: .acPower,
        batteryPercent: 100,
        lowPowerModeEnabled: false,
        thermalState: .nominal,
        diskReliability: .verified,
        availableDiskBytes: 100_000_000_000,
        requiredDiskBytes: 1,
        warnings: []
    )
    var windows: [MacSustainedBenchmarkWindow] = []
    for index in 0..<3 {
        windows.append(MacSustainedBenchmarkWindow(
            index: index,
            startedAtSeconds: Double(index * 2),
            completedAtSeconds: Double(index * 2 + 1),
            cpuMultiSample: BenchmarkComponentSample(
                value: 100 - Double(index),
                elapsedSeconds: 1,
                checksum: 101
            ),
            gpuRasterSample: BenchmarkComponentSample(
                value: 200 - Double(index),
                elapsedSeconds: 1,
                checksum: 202
            )
        ))
    }
    return MacSustainedBenchmarkResult(
        profile: .standard,
        coolingMode: .systemAutomatic,
        targetDurationSeconds: 6,
        workloadDurationSeconds: 5,
        totalObservationDurationSeconds: 5,
        startedAt: startedAt,
        completedAt: startedAt.addingTimeInterval(6),
        environment: environment,
        preflight: preflight,
        windows: windows,
        telemetry: [
            MacSustainedTelemetrySample(
                elapsedSeconds: 0,
                thermalState: .nominal,
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                chipTemperatureCelsius: 45,
                fans: .unsupported
            ),
            MacSustainedTelemetrySample(
                elapsedSeconds: 5,
                thermalState: .nominal,
                powerSource: .battery,
                lowPowerModeEnabled: false,
                chipTemperatureCelsius: 55,
                fans: .unsupported
            ),
        ],
        termination: .powerSourceChanged(.battery),
        cooldownReachedNominal: nil,
        failure: nil
    )
}

private struct PartialFailureV7Runner: BenchmarkV7WorkloadRunning {
    let reason: String

    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult] {
        _ = plan
        _ = categories
        _ = targetDirectory
        await progress(.cpu, "fixture.cpu", 1, 0.5)
        throw BenchmarkV7WorkloadFailure(
            category: .gpu,
            workloadID: "gpu.compute.fp16",
            reason: reason,
            completedMetrics: [try fixtureCPUMetric()]
        )
    }

    private func fixtureCPUMetric() throws -> BenchmarkV7MetricResult {
        let samples = [BenchmarkV7RawSample(
            value: 42,
            elapsedSeconds: 1,
            wallElapsedSeconds: 1,
            checksum: 42
        )]
        return BenchmarkV7MetricResult(
            manifest: BenchmarkV7MetricManifest(
                id: "fixture.cpu",
                category: .cpu,
                unit: "Mops/s",
                direction: .higherIsBetter,
                weight: 1,
                workloadVersion: "fixture"
            ),
            samples: samples,
            statistics: try BenchmarkStatistics.summarize(samples.map(\.value))
        )
    }
}

private struct RawKernelFailureV7Runner: BenchmarkV7WorkloadRunning {
    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult] {
        _ = plan
        _ = categories
        _ = targetDirectory
        await progress(.gpu, "gpu.compute.fp16", 1, 0.5)
        throw BenchmarkKernelError.invalidMetric
    }
}

private struct SecretFailureV7Runner: BenchmarkV7WorkloadRunning {
    let secret: String

    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult] {
        _ = plan
        _ = categories
        _ = targetDirectory
        _ = progress
        throw SecretFailureV7Error(secret: secret)
    }
}

private struct SecretFailureV7Error: Error {
    let secret: String
}

private actor ControlledBenchmarkSubtestGate {
    private var operationStarted = false
    private var operationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var timeoutFired = false
    private var timeoutContinuation: CheckedContinuation<Void, Never>?

    func runNonCooperativeOperation() async -> Double {
        operationStarted = true
        operationStartWaiters.forEach { $0.resume() }
        operationStartWaiters.removeAll()
        await withCheckedContinuation { operationContinuation = $0 }
        return 42
    }

    func waitUntilOperationStarts() async {
        guard !operationStarted else { return }
        await withCheckedContinuation { operationStartWaiters.append($0) }
    }

    func releaseOperation() {
        operationContinuation?.resume()
        operationContinuation = nil
    }

    func waitForTimeoutSignal() async {
        guard !timeoutFired else { return }
        await withCheckedContinuation { timeoutContinuation = $0 }
    }

    func fireTimeout() {
        timeoutFired = true
        timeoutContinuation?.resume()
        timeoutContinuation = nil
    }
}

private struct InnerTimeoutV7Runner: BenchmarkV7WorkloadRunning {
    let gate: ControlledBenchmarkSubtestGate

    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult] {
        try await run(
            plan: plan,
            categories: categories,
            targetDirectory: targetDirectory,
            executionRecorder: BenchmarkV7WorkloadExecutionRecorder(),
            progress: progress
        )
    }

    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult] {
        _ = plan
        _ = categories
        _ = targetDirectory
        await progress(.cpu, "cpu.fixture.blocked", 1, 0.5)
        let value = try await SystemBenchmarkV7WorkloadRunner().runSubtest(
            category: .cpu,
            workloadID: "cpu.fixture.blocked",
            repetition: 1,
            executionRecorder: executionRecorder,
            timeout: .seconds(1),
            sleep: { _ in await gate.waitForTimeoutSignal() }
        ) {
            await gate.runNonCooperativeOperation()
        }
        let samples = [BenchmarkV7RawSample(
            value: value,
            elapsedSeconds: 1,
            wallElapsedSeconds: 1,
            checksum: UInt64(value)
        )]
        return [BenchmarkV7MetricResult(
            manifest: BenchmarkV7MetricManifest(
                id: "fixture.cpu",
                category: .cpu,
                unit: "Mops/s",
                direction: .higherIsBetter,
                weight: 1,
                workloadVersion: "fixture"
            ),
            samples: samples,
            statistics: try BenchmarkStatistics.summarize(samples.map(\.value))
        )]
    }
}

private actor ScriptedV7Runner: BenchmarkV7WorkloadRunning {
    typealias Progress = @Sendable (BenchmarkV7Category, String, Int, Double) async -> Void

    private let blockedRuns: Set<Int>
    private var callbacks: [Progress] = []
    private var startedRuns = Set<Int>()
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(blockedRuns: Set<Int> = []) {
        self.blockedRuns = blockedRuns
    }

    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        progress: @escaping Progress
    ) async throws -> [BenchmarkV7MetricResult] {
        _ = plan
        _ = categories
        _ = targetDirectory
        let run = callbacks.count + 1
        callbacks.append(progress)
        await progress(.cpu, "fixture.cpu.\(run)", 1, 0.5)
        startedRuns.insert(run)
        startWaiters.removeValue(forKey: run)?.forEach { $0.resume() }
        if blockedRuns.contains(run) {
            await withCheckedContinuation { releaseWaiters[run] = $0 }
        }
        return [try Self.cpuMetric()]
    }

    func waitUntilRunStarts(_ run: Int) async {
        guard !startedRuns.contains(run) else { return }
        await withCheckedContinuation { startWaiters[run, default: []].append($0) }
    }

    func releaseRun(_ run: Int) {
        releaseWaiters.removeValue(forKey: run)?.resume()
    }

    func runCount() -> Int { callbacks.count }

    func emitProgress(
        fromRun run: Int,
        category: BenchmarkV7Category,
        workloadID: String,
        repetition: Int,
        fraction: Double
    ) async {
        guard callbacks.indices.contains(run - 1) else { return }
        await callbacks[run - 1](category, workloadID, repetition, fraction)
    }

    private static func cpuMetric() throws -> BenchmarkV7MetricResult {
        let samples = [BenchmarkV7RawSample(
            value: 42,
            elapsedSeconds: 1,
            wallElapsedSeconds: 1,
            checksum: 42
        )]
        return BenchmarkV7MetricResult(
            manifest: BenchmarkV7MetricManifest(
                id: "fixture.cpu",
                category: .cpu,
                unit: "Mops/s",
                direction: .higherIsBetter,
                weight: 1,
                workloadVersion: "fixture"
            ),
            samples: samples,
            statistics: try BenchmarkStatistics.summarize(samples.map(\.value))
        )
    }
}

private struct FixedV7Preflight: BenchmarkV7Preflighting {
    let report: BenchmarkV7PreflightReport

    func capture(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL
    ) async -> BenchmarkV7PreflightReport {
        _ = plan
        _ = categories
        _ = targetDirectory
        return report
    }
}

private actor BlockingFirstV7Preflight: BenchmarkV7Preflighting {
    let report: BenchmarkV7PreflightReport
    private var isFirstCapture = true
    private var firstCaptureStarted = false
    private var firstCaptureFinished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCaptureContinuation: CheckedContinuation<Void, Never>?

    init(report: BenchmarkV7PreflightReport) {
        self.report = report
    }

    func capture(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL
    ) async -> BenchmarkV7PreflightReport {
        _ = plan
        _ = categories
        _ = targetDirectory
        if isFirstCapture {
            isFirstCapture = false
            firstCaptureStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { firstCaptureContinuation = $0 }
            firstCaptureFinished = true
            finishWaiters.forEach { $0.resume() }
            finishWaiters.removeAll()
        }
        return report
    }

    func waitUntilFirstCaptureStarts() async {
        guard !firstCaptureStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstCapture() {
        firstCaptureContinuation?.resume()
        firstCaptureContinuation = nil
    }

    func waitUntilFirstCaptureFinishes() async {
        guard !firstCaptureFinished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}

private struct FixedEnvironmentProvider: MacBenchmarkEnvironmentProviding {
    let value = BenchmarkEnvironmentMetadata(
        architecture: .arm64,
        chipName: "Fixture Mac",
        activeProcessorCount: 8,
        physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
        powerSource: .acPower,
        thermalState: .nominal,
        operatingSystemVersion: "fixtureOS",
        appVersion: "1.9.9",
        appBuild: "999"
    )

    func metadata(preflight: BenchmarkPreflight) -> BenchmarkEnvironmentMetadata {
        _ = preflight
        return value
    }
}

private actor V7StateRecorder {
    private var states: [BenchmarkV7State] = []

    func append(_ state: BenchmarkV7State) { states.append(state) }
    func values() -> [BenchmarkV7State] { states }
}

private struct UnusedCoreService: MacBenchmarkServicing {
    func run(
        profile: BenchmarkProfile,
        progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void
    ) async -> MacBenchmarkRawResult {
        _ = profile
        _ = progress
        fatalError("v7 workload integration tests do not use the v6 service")
    }
}

private struct NoopLifecycleCleaner: MacBenchmarkLifecycleCleaning {
    func cleanupOrphanedArtifactsOnLaunch() async {}
}

private actor InMemoryV6History: MacBenchmarkHistoryPersisting {
    func load() async -> [MacBenchmarkResult] { [] }
    func save(_ result: MacBenchmarkResult) async throws { _ = result }
    func loadStatus() async -> MacBenchmarkHistoryLoadStatus { .missing }
}

private actor InMemoryV7History: BenchmarkV7HistoryPersisting {
    private var results: [BenchmarkV7Result] = []

    func load() async -> [BenchmarkV7Result] { results }
    func save(_ result: BenchmarkV7Result) async throws { results.append(result) }
    func replace(recordID: UUID, with result: BenchmarkV7Result) async throws {
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            throw V7HistoryFixtureError.missingRecord
        }
        results[index] = result
    }
    func delete(recordID: UUID) async throws -> Bool {
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            return false
        }
        results.remove(at: index)
        return true
    }
    func loadStatus() async -> BenchmarkV7HistoryLoadStatus { .loaded }
}

private actor FailingV7History: BenchmarkV7HistoryPersisting {
    private enum SaveError: Error { case rejected }

    func load() async -> [BenchmarkV7Result] { [] }
    func save(_ result: BenchmarkV7Result) async throws {
        _ = result
        throw SaveError.rejected
    }
    func replace(recordID: UUID, with result: BenchmarkV7Result) async throws {
        _ = recordID
        _ = result
        throw SaveError.rejected
    }
    func delete(recordID: UUID) async throws -> Bool {
        _ = recordID
        return false
    }
    func loadStatus() async -> BenchmarkV7HistoryLoadStatus { .failed }
}

private actor DelayedV7History: BenchmarkV7HistoryPersisting {
    private var results: [BenchmarkV7Result] = []
    private var saveCount = 0
    private var firstSaveStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?

    func load() async -> [BenchmarkV7Result] { results }

    func save(_ result: BenchmarkV7Result) async throws {
        saveCount += 1
        results.append(result)
        guard saveCount == 1 else { return }
        firstSaveStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstSaveContinuation = continuation
        }
    }

    func replace(recordID: UUID, with result: BenchmarkV7Result) async throws {
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            throw V7HistoryFixtureError.missingRecord
        }
        results[index] = result
    }

    func delete(recordID: UUID) async throws -> Bool {
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            return false
        }
        results.remove(at: index)
        return true
    }

    func loadStatus() async -> BenchmarkV7HistoryLoadStatus { .loaded }

    func waitUntilFirstSaveStarts() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
    }
}

private actor BlockingFirstSaveV7History: BenchmarkV7HistoryPersisting {
    private var results: [BenchmarkV7Result] = []
    private let failReplacement: Bool
    private let blockReplacement: Bool
    private var isFirstSave = true
    private var firstSaveStarted = false
    private var replacementStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?
    private var replacementStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var replacementContinuation: CheckedContinuation<Void, Never>?

    init(
        failReplacement: Bool = false,
        blockReplacement: Bool = false
    ) {
        self.failReplacement = failReplacement
        self.blockReplacement = blockReplacement
    }

    func load() async -> [BenchmarkV7Result] { results }

    func save(_ result: BenchmarkV7Result) async throws {
        if isFirstSave {
            isFirstSave = false
            firstSaveStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { firstSaveContinuation = $0 }
        }
        results.append(result)
    }

    func replace(recordID: UUID, with result: BenchmarkV7Result) async throws {
        guard !failReplacement else { throw V7HistoryFixtureError.replacementRejected }
        if blockReplacement {
            replacementStarted = true
            replacementStartWaiters.forEach { $0.resume() }
            replacementStartWaiters.removeAll()
            await withCheckedContinuation { replacementContinuation = $0 }
        }
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            throw V7HistoryFixtureError.missingRecord
        }
        results[index] = result
    }

    func delete(recordID: UUID) async throws -> Bool {
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            return false
        }
        results.remove(at: index)
        return true
    }

    func loadStatus() async -> BenchmarkV7HistoryLoadStatus { .loaded }

    func waitUntilFirstSaveStarts() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
    }

    func waitUntilReplacementStarts() async {
        guard !replacementStarted else { return }
        await withCheckedContinuation { replacementStartWaiters.append($0) }
    }

    func releaseReplacement() {
        replacementContinuation?.resume()
        replacementContinuation = nil
    }
}

private actor BlockingFirstReloadV7History: BenchmarkV7HistoryPersisting {
    private var results: [BenchmarkV7Result] = []
    private var isFirstLoad = true
    private var firstLoadStarted = false
    private var firstLoadFinished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?

    func load() async -> [BenchmarkV7Result] {
        if isFirstLoad {
            isFirstLoad = false
            firstLoadStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { firstLoadContinuation = $0 }
            firstLoadFinished = true
            finishWaiters.forEach { $0.resume() }
            finishWaiters.removeAll()
        }
        return results
    }

    func save(_ result: BenchmarkV7Result) async throws {
        results.append(result)
    }

    func replace(recordID: UUID, with result: BenchmarkV7Result) async throws {
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            throw V7HistoryFixtureError.missingRecord
        }
        results[index] = result
    }

    func delete(recordID: UUID) async throws -> Bool {
        guard let index = results.firstIndex(where: { $0.recordID == recordID }) else {
            return false
        }
        results.remove(at: index)
        return true
    }

    func loadStatus() async -> BenchmarkV7HistoryLoadStatus { .loaded }

    func waitUntilFirstLoadStarts() async {
        guard !firstLoadStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }

    func waitUntilFirstLoadFinishes() async {
        guard !firstLoadFinished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}

private enum V7HistoryFixtureError: Error {
    case missingRecord
    case replacementRejected
}
