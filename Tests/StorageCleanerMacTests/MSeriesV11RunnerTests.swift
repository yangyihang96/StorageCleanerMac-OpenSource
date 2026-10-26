import Foundation
import Combine
import XCTest
@testable import StorageCleanerMac

final class MSeriesV11RunnerTests: XCTestCase {
    private func run(_ control: V11RunSubstitute, mode: String = "standard") async -> MSeriesV11Runner.Output {
        await MSeriesV11Runner(dependencies: control.dependencies()).run(sessionID: control.session, mode: mode,
            root: FileManager.default.temporaryDirectory, resourceJournal: nil)
    }
    func testStandardOrderThreeThreadTiersDurationsAndMissingPowerDegradeOnlyEfficiency() async throws {
        let control = V11RunSubstitute()
        let output = await run(control)
        XCTAssertEqual(control.events, ["identity", "core", "power.cpu.single:1", "power.cpu.performanceCores:2",
            "power.cpu.allCores:8", "power.gpu.peak:1", "sustained.cpu.allCores:8", "sustained.gpu:1"])
        XCTAssertEqual(control.finishes, 6)
        XCTAssertEqual(output.envelope.state, "completed")
        XCTAssertEqual(output.envelope.efficiencyPoints.count, 4)
        XCTAssertTrue(output.envelope.efficiencyPoints.allSatisfy { $0.efficiency == nil && $0.throughput != nil && !$0.missingReasons.isEmpty })
        XCTAssertEqual(output.envelope.sustainedCPU?.windows.count, 18)
        XCTAssertEqual(output.envelope.sustainedGPU?.windows.count, 18)
        XCTAssertEqual(output.envelope.sustainedCPU?.durationSeconds, 90)
        XCTAssertEqual(output.envelope.sustainedGPU?.durationSeconds, 90)
        XCTAssertEqual(output.envelope.sustainedCPU?.retention, 1)
        XCTAssertEqual(output.envelope.dispatchDeadlineSeconds, 480)
        XCTAssertTrue(output.envelope.hasCompletedRequiredMeasurements)
        XCTAssertTrue(MSeriesV11RawPayload.validates(core: output.core, envelope: output.envelope))
        XCTAssertTrue(output.envelope.scores?.componentScores.isEmpty == true)
        XCTAssertEqual(control.telemetryLifecycle, ["begin", "finish"])
    }
    func testPressureIsCPU300ThenGPU300WithSixtyWindowsAndNoStandardScoreInputs() async throws {
        let control = V11RunSubstitute()
        let output = await run(control, mode: "pressure10m")
        XCTAssertEqual(control.events, ["identity", "pressure.cpu.allCores:8", "pressure.gpu:1"])
        XCTAssertEqual(control.finishes, 2)
        XCTAssertNil(output.core)
        XCTAssertEqual(output.envelope.state, "completed")
        XCTAssertEqual(output.envelope.sustainedCPU?.durationSeconds, 300)
        XCTAssertEqual(output.envelope.sustainedGPU?.durationSeconds, 300)
        XCTAssertEqual(output.envelope.sustainedCPU?.windows.count, 60)
        XCTAssertEqual(output.envelope.sustainedGPU?.windows.count, 60)
        XCTAssertEqual(output.envelope.measuredDurationSeconds, 600)
        XCTAssertEqual(output.envelope.dispatchDeadlineSeconds, 660)
        XCTAssertNil(output.envelope.scores)
        XCTAssertTrue(output.envelope.efficiencyPoints.isEmpty)
    }
    func testCancellationAtEveryExtensionStopsDispatchAndFinishesItsDriver() async {
        for stage in ["power.cpu.single", "power.cpu.performanceCores", "power.cpu.allCores", "power.gpu.peak", "sustained.cpu.allCores", "sustained.gpu"] {
            let control = V11RunSubstitute(); control.cancelStage = stage
            let output = await run(control)
            XCTAssertEqual(output.envelope.state, "cancelled", stage)
            XCTAssertEqual(output.envelope.failure, "cancelled", stage)
            XCTAssertEqual(control.events.last?.split(separator: ":").first.map(String.init), stage)
            XCTAssertEqual(control.finishes, control.events.count - 2)
            XCTAssertEqual(control.telemetryLifecycle.last, "finish")
            XCTAssertFalse(output.envelope.hasCompletedRequiredMeasurements)
        }
    }
    func testDeadlineAndThermalProtectionNeverStartNextStageAndKeepCompletedCore() async {
        for failure in ["timeout", "thermal"] {
            let control = V11RunSubstitute(); control.failStage = "power.cpu.allCores"; control.failure = failure
            let output = await run(control)
            XCTAssertEqual(output.envelope.state, "partial")
            XCTAssertEqual(output.envelope.failure, failure == "timeout" ? "timeout" : "thermalProtection")
            XCTAssertTrue(output.core?.isCompleteCore == true)
            XCTAssertEqual(control.events.last, "power.cpu.allCores:8")
            XCTAssertEqual(control.finishes, 3)
            XCTAssertNil(output.envelope.sustainedGPU)
        }
    }
    func testPreflightSeriousAndCriticalRefuseBeforeIdentityOrWork() async {
        for thermal in [2,3] {
            let control = V11RunSubstitute(); control.thermal = thermal
            let output = await run(control)
            XCTAssertTrue(control.events.isEmpty)
            XCTAssertEqual(output.envelope.failure, "thermalProtection")
            XCTAssertEqual(control.finishes, 0)
            XCTAssertEqual(control.telemetryLifecycle, ["begin", "finish"])
        }
    }
    func testRawDigestCoversActualPayloadAndExcludesOnlyDerivedCaches() async throws {
        let output = await run(V11RunSubstitute())
        var raw = output.envelope
        let digest = raw.rawPayloadSHA256
        raw.derivedCacheKey = "a-different-reference"
        raw.referenceIdentity = .unavailable
        XCTAssertEqual(try MSeriesV11RawPayload.seal(core: output.core, envelope: raw).rawPayloadSHA256, digest)
        raw.failure = "different-raw-evidence"
        XCTAssertFalse(MSeriesV11RawPayload.validates(core: output.core, envelope: raw))
        XCTAssertNotEqual(try MSeriesV11RawPayload.seal(core: output.core, envelope: raw).rawPayloadSHA256, digest)
        raw.telemetry = Array(repeating: MSeriesV11WindowTests.telemetry(0), count: 1025)
        XCTAssertThrowsError(try MSeriesV11RawPayload.seal(core: output.core, envelope: raw))
    }
    func testCancellationKeepsLeaseUntilInFlightSubstituteDrains() async throws {
        let control = V11RunSubstitute()
        let driver = V11DrainBatchSubstitute(control: control)
        var dependencies = control.dependencies()
        dependencies.driverFactory = { driver }
        let leaseCoordinator = HeavyWorkCoordinator()
        let coordinator = BenchmarkV7Coordinator(workloadRunner: V11UnusedWorkloadRunner(), heavyWorkCoordinator: leaseCoordinator,
            preflightService: V11PreflightSubstitute(report: MSeriesV11TestFixtures.result().preflight), resourceJournal: nil,
            v11Runner: .init(dependencies: dependencies))
        let task = Task { await coordinator.run(sessionID: control.session, plan: MSeriesV11Protocol.plan(mode: "standard"),
            targetDirectory: FileManager.default.temporaryDirectory) }
        await driver.waitUntilEntered()
        task.cancel()
        let owner = await leaseCoordinator.activeOwner
        XCTAssertEqual(owner, .benchmark)
        let finishedBeforeDrain = await driver.didFinish
        XCTAssertFalse(finishedBeforeDrain)
        do { _ = try await leaseCoordinator.acquire(owner: .benchmark); XCTFail("in-flight work must retain lease") }
        catch HeavyWorkCoordinator.Error.busy {}
        await driver.release()
        let result = await task.value
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(result.mSeriesV11?.state, "cancelled")
        let finished = await driver.didFinish
        XCTAssertTrue(finished)
        XCTAssertEqual(control.events.last, "power.cpu.single:1")
        XCTAssertEqual(result.mSeriesV11?.drainDurationSeconds, 0.5)
        let lease = try await leaseCoordinator.acquire(owner: .benchmark)
        await leaseCoordinator.release(lease)
    }

    func testAtomicHistoryCountsOwnCommitAndAcceptsResultBesideLargeHistory() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let output = await run(V11RunSubstitute())
        let core = try XCTUnwrap(output.core)
        let preflight = MSeriesV11TestFixtures.result().preflight
        let result = BenchmarkV7Result(mSeries: core, mSeriesV11: output.envelope,
            session: .init(id: core.sessionID, plan: MSeriesV11Protocol.plan(mode: "standard"), storageTarget: preflight.storageTarget),
            preflight: preflight, versions: MSeriesV11Protocol.versions(mode: "standard"), metrics: [], coreScore: nil,
            completedAt: output.envelope.completedAt, failure: nil)
        let url = root.appendingPathComponent("v11.json")
        let repo = BenchmarkV7HistoryRepository(storageURL: url)
        try await repo.save(result)
        // D95: a save writes its own record file and the index, each through
        // an atomic temporary copy; nothing else is rewritten.
        let commit = try BenchmarkV7HistoryStoreProbe.commitBytes(for: url, recordID: result.recordID)
        let records = await repo.load()
        let saved = try XCTUnwrap(records.first?.mSeriesV11)
        XCTAssertEqual(saved.metadataWrittenBytes, UInt64(commit * 2))
        XCTAssertEqual(saved.writtenBytes, core.writtenBytes + UInt64(commit * 2))
        XCTAssertEqual(saved.rawPayloadSHA256, output.envelope.rawPayloadSHA256)
        XCTAssertTrue(records.first?.isComplete == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no single-file history is written")

        // 2026-10-13: once the history passed 1 MiB, every new v11 result was
        // refused. Older records no longer count against a new result.
        let largeURL = root.appendingPathComponent("old-history.json")
        let largeRepo = BenchmarkV7HistoryRepository(storageURL: largeURL)
        let legacy = MSeriesV11TestFixtures.result()
        let large = BenchmarkV7Result(mSeries: legacy.mSeries, session: legacy.session, preflight: legacy.preflight,
            versions: legacy.versions, metrics: [], coreScore: nil, runtimeWarnings: [String(repeating: "x", count: 1_100_000)],
            completedAt: legacy.completedAt, failure: nil)
        try await largeRepo.save(large)
        let largeBytes = try BenchmarkV7HistoryStoreProbe.recordData(for: largeURL, recordID: large.recordID)
        XCTAssertGreaterThan(largeBytes.count, 1_048_576)
        try await largeRepo.save(result)
        let both = await largeRepo.load()
        XCTAssertEqual(Set(both.compactMap(\.recordID)), Set([large.recordID, result.recordID].compactMap { $0 }))
        XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.recordData(for: largeURL, recordID: large.recordID), largeBytes,
            "the older record is not rewritten")
        let besideLarge = try XCTUnwrap(both.first { $0.recordID == result.recordID }?.mSeriesV11)
        XCTAssertEqual(besideLarge.metadataWrittenBytes,
            UInt64(try BenchmarkV7HistoryStoreProbe.commitBytes(for: largeURL, recordID: result.recordID) * 2))

        // Pin the SPEC boundary rather than deriving it from the implementation:
        // one result's commit (record + index) with its atomic copies ≤ 2 MiB,
        // beside an older record that is itself larger than 1 MiB.
        let limit = 1_048_576
        XCTAssertEqual(BenchmarkV7HistoryRepository.maximumV11ResultBytes, limit)
        XCTAssertGreaterThan(BenchmarkV7HistoryRepository.maximumFileBytes, limit)
        func padded(_ count: Int) -> BenchmarkV7Result {
            BenchmarkV7Result(recordID: result.recordID, mSeries: core, mSeriesV11: output.envelope, session: result.session,
                preflight: preflight, versions: result.versions, metrics: [], coreScore: nil,
                runtimeWarnings: [String(repeating: "x", count: count)], completedAt: result.completedAt, failure: nil)
        }
        var probeCount = 0
        func probeCommit(padding: Int) async throws -> Int {
            probeCount += 1
            let probeURL = root.appendingPathComponent("probe-\(probeCount).json")
            let probeRepo = BenchmarkV7HistoryRepository(storageURL: probeURL)
            try await probeRepo.save(large)
            try await probeRepo.save(padded(padding))
            return try BenchmarkV7HistoryStoreProbe.commitBytes(for: probeURL, recordID: result.recordID)
        }
        // Approach the boundary from below: the ledger's own digits grow.
        var padding = 0
        let unpadded = try await probeCommit(padding: padding)
        padding += limit - unpadded - 64
        let nearLimit = try await probeCommit(padding: padding)
        padding += limit - nearLimit
        let atLimit = try await probeCommit(padding: padding)
        XCTAssertEqual(atLimit, limit)
        for extraByte in [0, 1] {
            let incoming = padded(padding + extraByte)
            XCTAssertTrue(incoming.isPersistable)
            let boundaryURL = root.appendingPathComponent("boundary-\(extraByte).json")
            let boundaryRepo = BenchmarkV7HistoryRepository(storageURL: boundaryURL)
            try await boundaryRepo.save(large)
            let before = try BenchmarkV7HistoryStoreProbe.files(for: boundaryURL)
            var rejected = false
            do { try await boundaryRepo.save(incoming) } catch { rejected = true }
            let remaining = await boundaryRepo.load()
            if extraByte == 0 {
                XCTAssertFalse(rejected, "exactly 2 MiB of commit writes must remain writable")
                XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.commitBytes(for: boundaryURL, recordID: incoming.recordID), limit)
                XCTAssertEqual(remaining.count, 2)
                XCTAssertEqual(remaining.first(where: { $0.recordID == incoming.recordID })?.mSeriesV11?.metadataWrittenBytes,
                    UInt64(limit * 2))
            } else {
                XCTAssertTrue(rejected, "1 byte over must reject before any write")
                XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.files(for: boundaryURL), before,
                    "rejection must leave every history file unchanged")
                XCTAssertEqual(remaining.count, 1)
            }
        }
    }

    func testP1CompletedCoreAndEmptyExtensionsCannotBecomeCompleteResult() throws {
        let core = MSeriesV11TestFixtures.legacyCore()
        var envelope = MSeriesV11Result(sessionID: core.sessionID, extensionContractHash: MSeriesV11Protocol.contractHash, rawPayloadSHA256: "")
        envelope.state = "completed"; envelope.completedAt = core.completedAt; envelope.writtenBytes = core.writtenBytes
        envelope = try MSeriesV11RawPayload.seal(core: core, envelope: envelope)
        let legacy = MSeriesV11TestFixtures.result(core: core)
        let result = BenchmarkV7Result(mSeries: core, mSeriesV11: envelope,
            session: .init(id: core.sessionID, plan: MSeriesV11Protocol.plan(mode: "standard"), storageTarget: legacy.preflight.storageTarget),
            preflight: legacy.preflight, versions: MSeriesV11Protocol.versions(mode: "standard"), metrics: [], coreScore: nil,
            completedAt: core.completedAt, failure: nil)
        XCTAssertTrue(result.isPersistable)
        XCTAssertFalse(result.isComplete)
    }
    func testHighFrequencyStandardAndPressurePreserveAllBatchesAndFitAtomicBudget() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        for mode in ["standard", "pressure10m"] {
            let control = V11RunSubstitute()
            control.batchNanoseconds = 50_000_000
            control.add(3_000_000_000_000_000)
            let output = await run(control, mode: mode)
            XCTAssertEqual(output.envelope.state, "completed", mode)
            XCTAssertNil(output.envelope.failure, mode)
            let seconds = mode == "standard" ? 240 : 600
            XCTAssertEqual(output.envelope.workloadBatches.count, seconds * 20)
            XCTAssertEqual(output.envelope.measuredDurationSeconds, Double(seconds))
            XCTAssertEqual(output.envelope.sustainedGPU?.windows.count, mode == "standard" ? 18 : 60)
            XCTAssertEqual(output.envelope.sustainedCPU?.windows.count, mode == "standard" ? 18 : 60)
            if mode == "pressure10m" {
                XCTAssertEqual(output.envelope.workloadBatches.filter { $0.stageID == "pressure.gpu" }.count, 6000)
            }
            let result = record(output, session: control.session, mode: mode)
            XCTAssertTrue(result.isComplete)
            XCTAssertTrue(result.isPersistable)
            let url = root.appendingPathComponent("fast-\(mode).json")
            let repository = BenchmarkV7HistoryRepository(storageURL: url)
            try await repository.save(result)
            let bytes = try BenchmarkV7HistoryStoreProbe.recordData(for: url, recordID: result.recordID)
            XCTAssertLessThanOrEqual(bytes.count, 1_048_576)
            let commit = try BenchmarkV7HistoryStoreProbe.commitBytes(for: url, recordID: result.recordID)
            let records = await repository.load()
            let saved = try XCTUnwrap(records.first?.mSeriesV11)
            XCTAssertEqual(saved.metadataWrittenBytes, UInt64(commit * 2))
            XCTAssertEqual(saved.workloadBatches, output.envelope.workloadBatches)
            XCTAssertEqual(saved.perStageEnvironment, output.envelope.perStageEnvironment)
            XCTAssertEqual(saved.sustainedCPU, output.envelope.sustainedCPU)
            XCTAssertEqual(saved.sustainedGPU, output.envelope.sustainedGPU)
            XCTAssertEqual(saved.rawPayloadSHA256, output.envelope.rawPayloadSHA256)
            XCTAssertTrue(MSeriesV11RawPayload.validates(core: output.core, envelope: saved))
            for sustained in [saved.sustainedCPU, saved.sustainedGPU].compactMap({ $0 }) {
                for window in sustained.windows {
                    let batches = saved.workloadBatches.filter { $0.stageID == sustained.id &&
                        $0.startMonotonicNs >= window.startMonotonicNs && $0.endMonotonicNs <= window.endMonotonicNs }
                    let work = batches.reduce(0) { $0 + $1.workUnits }
                    XCTAssertEqual(window.workUnits, work, accuracy: 1e-9)
                    XCTAssertEqual(try XCTUnwrap(window.wallThroughput), work / 5, accuracy: 1e-9)
                    if sustained.id.contains("gpu") {
                        XCTAssertEqual(try XCTUnwrap(window.gpuTimedThroughput),
                            work / batches.compactMap(\.gpuElapsedSeconds).reduce(0, +), accuracy: 1e-9)
                    }
                }
            }
            XCTAssertGreaterThan(control.forecasts.count, 1)
            XCTAssertEqual(control.forecasts.first?.measuredSeconds, 5)
            XCTAssertTrue(control.forecasts.allSatisfy { $0.projectedStorageBytes <= 768 * 1024 })
            print("fix2 fake \(mode): batches=\(saved.workloadBatches.count), fileBytes=\(bytes.count), forecasts=\(control.forecasts.count)")
        }
    }

    func testBudgetForecastStopsEarlyAndPersistsPartialWithoutDroppingEvidence() async throws {
        let control = V11RunSubstitute()
        control.batchNanoseconds = 50_000_000
        control.highEntropyEnvironment = true
        // A disabled forecast must fail assertions, not spend minutes encoding
        // a deliberately incompressible fake run or time out the mutation harness.
        control.maximumBatchRequests = 100
        let output = await run(control, mode: "pressure10m")
        XCTAssertEqual(output.envelope.state, "partial")
        XCTAssertEqual(output.envelope.failure, "evidenceBudgetForecast")
        XCTAssertLessThan(try XCTUnwrap(output.envelope.measuredDurationSeconds), 300)
        XCTAssertEqual(control.events, ["identity", "pressure.cpu.allCores:8"])
        XCTAssertEqual(control.finishes, 1)
        XCTAssertGreaterThan(try XCTUnwrap(control.forecasts.first).projectedStorageBytes, 768 * 1024)
        XCTAssertEqual(control.forecasts.count, 1)
        XCTAssertEqual(output.envelope.workloadBatches.count, 100)
        XCTAssertEqual(control.batchRequests, 100, "the forecast must refuse another submission")
        let result = record(output, session: control.session, mode: "pressure10m")
        XCTAssertTrue(result.isPersistable)
        XCTAssertFalse(result.isComplete)
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("forecast-partial.json")
        let repo = BenchmarkV7HistoryRepository(storageURL: url)
        try await repo.save(result)
        let savedRecords = await repo.load()
        let saved = try XCTUnwrap(savedRecords.first?.mSeriesV11)
        XCTAssertEqual(saved.workloadBatches, output.envelope.workloadBatches)
        XCTAssertEqual(saved.perStageEnvironment, output.envelope.perStageEnvironment)
        XCTAssertTrue(MSeriesV11RawPayload.validates(core: nil, envelope: saved))
        XCTAssertLessThanOrEqual(try BenchmarkV7HistoryStoreProbe.recordData(for: url, recordID: result.recordID).count, 1_048_576)
    }

    private func record(_ output: MSeriesV11Runner.Output, session: UUID, mode: String) -> BenchmarkV7Result {
        let preflight = MSeriesV11TestFixtures.result().preflight
        return BenchmarkV7Result(mSeries: output.core, mSeriesV11: output.envelope,
            session: .init(id: session, plan: MSeriesV11Protocol.plan(mode: mode), storageTarget: preflight.storageTarget),
            preflight: preflight, versions: MSeriesV11Protocol.versions(mode: mode), metrics: [], coreScore: nil,
            completedAt: output.envelope.completedAt, failure: nil)
    }
    func testCoordinatorV11UsesOneLeaseAndReleasesOnlyAfterSubstituteCleanup() async throws {
        let control = V11RunSubstitute()
        let leaseCoordinator = HeavyWorkCoordinator()
        let legacy = MSeriesV11TestFixtures.result()
        let coordinator = BenchmarkV7Coordinator(workloadRunner: V11UnusedWorkloadRunner(), heavyWorkCoordinator: leaseCoordinator,
            preflightService: V11PreflightSubstitute(report: legacy.preflight), resourceJournal: nil,
            v11Runner: .init(dependencies: control.dependencies()))
        let result = await coordinator.run(sessionID: control.session, plan: MSeriesV11Protocol.plan(mode: "standard"),
            targetDirectory: FileManager.default.temporaryDirectory)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(control.finishes, 6)
        let lease = try await leaseCoordinator.acquire(owner: .benchmark)
        await leaseCoordinator.release(lease)
    }

    @MainActor
    func testRealV11CompletionAfterPageObservationCancellationReplaysDueScanExactlyOnce() async throws {
        let control = V11RunSubstitute()
        let driver = V11DrainBatchSubstitute(control: control)
        var dependencies = control.dependencies()
        dependencies.driverFactory = { driver }
        let leases = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: leases)
        let coordinator = BenchmarkV7Coordinator(workloadRunner: V11UnusedWorkloadRunner(),
            heavyWorkCoordinator: leases,
            preflightService: V11PreflightSubstitute(report: MSeriesV11TestFixtures.result().preflight),
            resourceJournal: nil, v11Runner: .init(dependencies: dependencies))
        let deadline = StartupSleepGate(), calls = StartupWorkCounter()
        let scheduler = StartupApplicationUpdateScheduler(sleep: { try await deadline.sleep($0) })
        scheduler.observeCompletion(of: activity)
        defer { scheduler.cancelForTermination() }
        var pageObservation: AnyCancellable? = activity.$activeOwner.sink { _ in }
        let benchmark = Task {
            await coordinator.run(sessionID: control.session, plan: MSeriesV11Protocol.plan(mode: "standard"),
                                  targetDirectory: FileManager.default.temporaryDirectory)
        }
        await driver.waitUntilEntered()
        let acquired = await HeavyWorkObservationTestWait.until { activity.activeOwner == .benchmark }
        XCTAssertTrue(acquired)
        pageObservation?.cancel()
        pageObservation = nil
        scheduler.scheduleIfDue(shouldCheck: { true }, executionAvailable: { activity.activeOwner == nil },
                                priorityReady: { true }, operation: { calls.read("automatic") })
        try await StartupTestWait.until { await deadline.delays.count == 1 }
        await deadline.release()
        try await StartupTestWait.until { !scheduler.isDelaying }
        XCTAssertTrue(scheduler.isWaitingForAvailability)
        XCTAssertEqual(calls.count("automatic"), 0)
        benchmark.cancel()
        XCTAssertEqual(activity.activeOwner, .benchmark, "in-flight work still owns the lease")
        await driver.release()
        let result = await benchmark.value
        XCTAssertEqual(result.failure, .cancelled)
        let completed = await HeavyWorkObservationTestWait.until { !scheduler.isPending }
        XCTAssertTrue(completed, "coordinator completion alone must deliver the retained scan")
        XCTAssertNil(activity.activeOwner, "no page task or explicit refresh may be needed")
        XCTAssertNil(activity.conflictMessage)
        XCTAssertEqual(calls.count("automatic"), 1)
        XCTAssertFalse(scheduler.isPending)
        let next = try await leases.acquire(owner: .mainScan)
        await leases.release(next)
        let idle = await HeavyWorkObservationTestWait.until { activity.activeOwner == nil }
        XCTAssertTrue(idle)
        XCTAssertEqual(calls.count("automatic"), 1, "later heavy-work completions cannot replay twice")
        let delays = await deadline.delays
        XCTAssertEqual(delays, [6], "completion adds no polling or extra startup timer")
    }
}

@MainActor
final class MSeriesV11PersistenceTests: XCTestCase {
    private func store(control: V11RunSubstitute, repository: any BenchmarkV7HistoryPersisting,
                       driver: (any MSeriesV11BatchDriving)? = nil,
                       configure: (inout MSeriesV11Dependencies) -> Void = { _ in },
                       validate: @escaping @Sendable (BenchmarkV7Result) -> Bool) throws -> MacBenchmarkStore {
        var dependencies = control.dependencies()
        if let driver { dependencies.driverFactory = { driver } }
        configure(&dependencies)
        let coordinator = BenchmarkV7Coordinator(workloadRunner: V11UnusedWorkloadRunner(),
            heavyWorkCoordinator: HeavyWorkCoordinator(),
            preflightService: V11PreflightSubstitute(report: MSeriesV11TestFixtures.result().preflight),
            resourceJournal: nil, v11Runner: .init(dependencies: dependencies))
        let catalog = try MacBenchmarkBaselineCatalog(activeBaselineVersion: "fixture", verifiedBaselines: [])
        return MacBenchmarkStore(service: V11UnusedLegacyService(),
            resultProcessor: MacBenchmarkResultProcessor(baselineCatalog: catalog),
            lifecycleCleaner: V11NoopLifecycle(), historyRepository: V11EmptyLegacyHistory(),
            v7Coordinator: coordinator, v11PersistabilityCheck: validate, v7HistoryRepository: repository,
            v7PromotionRevocationDefaults: TestPreferenceDomain.make(for: self))
    }

    func testStoreChecksSHAAndJSONOffMainAndPublishesOnlyAfterOneAtomicSave() async throws {
        let probe = V11ValidationProbe()
        let repository = V11MemoryHistory()
        let store = try store(control: V11RunSubstitute(), repository: repository, validate: {
            probe.record(); return $0.isPersistable
        })
        store.startV11Benchmark(mode: "pressure10m")
        await store.waitUntilIdle()
        XCTAssertEqual(probe.mainThreadReadings, [false], "production store validation must run off the main actor")
        let saved = await repository.records
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(store.v7History, saved)
        XCTAssertEqual(store.v7LatestResult, saved.first)
        XCTAssertEqual(store.v7State.phase, .completed)
        XCTAssertFalse(store.isRunning)
    }

    func testMainActorStaysResponsiveDuringValidationAndCommitStillCannotBeCancelled() async throws {
        let probe = V11ValidationProbe(block: true)
        defer { probe.release() }
        let repository = V11MemoryHistory()
        let store = try store(control: V11RunSubstitute(), repository: repository, validate: {
            probe.record(); return $0.isPersistable
        })
        store.startV11Benchmark(mode: "pressure10m")
        let deadline = ContinuousClock.now + .seconds(5)
        while !probe.entered && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(probe.entered)
        XCTAssertEqual(probe.mainThreadReadings, [false])
        XCTAssertFalse(probe.released, "the main actor must execute this assertion while validation is still blocked")
        XCTAssertEqual(store.v7State.phase, .persisting)
        XCTAssertNil(store.v7LatestResult)
        store.cancelV7()
        XCTAssertEqual(store.v7State.phase, .persisting)
        let before = await repository.records
        XCTAssertTrue(before.isEmpty)
        probe.release()
        await store.waitUntilIdle()
        let saved = await repository.records
        XCTAssertEqual(saved.count, 1)
        XCTAssertNil(saved.first?.failure)
        XCTAssertEqual(store.v7State.phase, .completed)
    }

    func testCancelledSubstituteIsResealedValidatedAndSavedBeforePublishingCancelled() async throws {
        let control = V11RunSubstitute()
        let driver = V11DrainBatchSubstitute(control: control)
        let probe = V11ValidationProbe()
        let repository = V11MemoryHistory()
        let store = try store(control: control, repository: repository, driver: driver,
            validate: { probe.record(); return $0.isPersistable })
        store.startV11Benchmark()
        await driver.waitUntilEntered()
        store.cancelV7()
        XCTAssertEqual(store.v7State.phase, .cancelling)
        XCTAssertNil(store.v7LatestResult)
        let beforeDrain = await repository.records
        XCTAssertTrue(beforeDrain.isEmpty)
        await driver.release()
        await store.waitUntilIdle()
        let saved = await repository.records
        XCTAssertEqual(probe.mainThreadReadings, [false])
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.failure, .cancelled)
        XCTAssertTrue(saved.first?.isPersistable == true)
        XCTAssertEqual(store.v7LatestResult, saved.first)
        XCTAssertEqual(store.v7State.phase, .cancelled)
        XCTAssertEqual(control.finishes, 1)
        let didDrain = await driver.didFinish
        XCTAssertTrue(didDrain)
    }
    func testThrowingMemorySaveSeparatesMeasurementCompletionFromPersistenceFailure() async throws {
        let repository = V11MemoryHistory(throwsOnSave: true)
        let store = try store(control: V11RunSubstitute(), repository: repository, validate: { $0.isPersistable })
        store.startV11Benchmark()
        await store.waitUntilIdle()
        let result = try XCTUnwrap(store.v7LatestResult)
        XCTAssertNil(result.failure, "save failure must not replace a completed measurement with a stop failure")
        XCTAssertEqual(store.v11SaveState?.state, .failed)
        XCTAssertEqual(store.v7State.phase, .failed)
        XCTAssertEqual(result.mSeriesV11?.state, "completed", "measuring finished before the memory repository threw")
        XCTAssertTrue(store.v7History.isEmpty)
        let disposition = MSeriesV11PagePresentation.ResultDisposition(result: result, history: store.v7History, saveState: store.v11SaveState)
        XCTAssertEqual(disposition.measuredCoreCount, 18)
        XCTAssertTrue(disposition.measurementCompleted)
        XCTAssertFalse(disposition.savedLocally)
        XCTAssertNil(disposition.failure)
        XCTAssertTrue(disposition.saveFailed)
        XCTAssertEqual(disposition.storageText, L10n.text("保存失败 · 仅当前会话可查看", "Save failed · Available only in this session"))
        XCTAssertTrue(disposition.completionText.contains(L10n.text("保存失败", "Save failed")))
        XCTAssertNotNil(disposition.saveFailureText)
        XCTAssertNil(disposition.terminationText)
        // Keep the original outer-failure mutation meaningful even though a
        // completed run now preserves nil as its measurement failure.
        let stopped = BenchmarkV7Result(recordID: result.recordID, mSeries: result.mSeries,
            mSeriesV11: result.mSeriesV11, session: result.session, preflight: result.preflight,
            versions: result.versions, metrics: [], coreScore: nil, completedAt: nil, failure: .cancelled)
        let stoppedPresentation = MSeriesV11PagePresentation.ResultDisposition(result: stopped, history: [], saveState: store.v11SaveState)
        XCTAssertEqual(stoppedPresentation.failure, .cancelled, "outer stop failure remains authoritative even if inner measurement state is completed")
        XCTAssertTrue(stoppedPresentation.completionText.contains(L10n.text("已取消", "Cancelled")))
    }

    func testFullHistoryIsShownAsCapacityRatherThanAWriteFailure() async throws {
        let repository = V11MemoryHistory(saveError: .capacityReached)
        let store = try store(control: V11RunSubstitute(), repository: repository, validate: { $0.isPersistable })
        store.startV11Benchmark()
        await store.waitUntilIdle()
        let result = try XCTUnwrap(store.v7LatestResult)
        XCTAssertNil(result.failure, "a full history is not a measurement failure")
        XCTAssertEqual(store.v11SaveState?.state, .failed)
        XCTAssertEqual(store.v11SaveState?.historyFull, true)
        let disposition = MSeriesV11PagePresentation.ResultDisposition(result: result, history: store.v7History, saveState: store.v11SaveState)
        XCTAssertTrue(disposition.saveFailed)
        XCTAssertTrue(disposition.historyFull)
        XCTAssertFalse(disposition.savedLocally)
        let text = try XCTUnwrap(disposition.saveFailureText)
        // D178: counts are grouped, "1,000" (was "\(maximumRecordCount)", "1000").
        XCTAssertTrue(text.contains(ByteFormat.count(BenchmarkV7HistoryRepository.maximumRecordCount)), text)
        XCTAssertTrue(text.contains(L10n.text("历史已满", "history is full")))
        XCTAssertTrue(text.contains(L10n.text("删除不需要的旧记录", "Delete records you no longer need")))
        // Any other refused write keeps the generic text, and a saved state
        // can never carry the capacity flag.
        let generic = MSeriesV11PagePresentation.ResultDisposition(result: result, history: [],
            saveState: .init(result: result, state: .failed))
        XCTAssertFalse(generic.historyFull)
        XCTAssertEqual(generic.saveFailureText, L10n.text("测量结果未能安全保存；仅当前应用会话可查看。",
            "Measurements were not safely saved; available only in the current app session."))
        XCTAssertFalse(MSeriesV11SaveState(result: result, state: .saved, historyFull: true).historyFull)
        let other = V11MemoryHistory(saveError: .invalidResult)
        let otherStore = try self.store(control: V11RunSubstitute(), repository: other, validate: { $0.isPersistable })
        otherStore.startV11Benchmark()
        await otherStore.waitUntilIdle()
        XCTAssertEqual(otherStore.v11SaveState?.state, .failed)
        XCTAssertEqual(otherStore.v11SaveState?.historyFull, false)
    }

    func testMissingReadbackCannotBePresentedAsSaved() async throws {
        let repository = V11MemoryHistory(hidesReadback: true)
        let store = try store(control: V11RunSubstitute(), repository: repository, validate: { $0.isPersistable })
        store.startV11Benchmark(mode: "pressure10m")
        await store.waitUntilIdle()
        XCTAssertNil(store.v7LatestResult?.failure)
        XCTAssertEqual(store.v11SaveState?.state, .failed)
        XCTAssertEqual(store.v7State.phase, .failed)
        XCTAssertTrue(store.v7History.isEmpty)
    }

    func testCoreReturnedFailureCodesPreserveRawEvidenceAndTranslateBothLanguages() async throws {
        let codes = try V11CoreStopContract.codes(in: V11CoreStopContract.source())
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            for code in codes {
                let control = V11RunSubstitute()
                let repository = V11MemoryHistory()
                let store = try store(control: control, repository: repository, configure: { dependencies in
                    dependencies.core = { session, _, _, _, _, progress in
                        control.event("core")
                        await progress(session, MSeriesProtocol.coreIDs[7], 7)
                        let core = MSeriesV11TestFixtures.legacyCore()
                        return MSeriesResult(sessionID: session, schema: core.schema, plan: core.plan,
                            workload: core.workload, fixture: core.fixture, implementation: core.implementation,
                            statisticsVersion: core.statisticsVersion, scoringVersion: core.scoringVersion,
                            referenceVersion: core.referenceVersion, contractHash: core.contractHash,
                            hardware: core.hardware, coreEnvironment: core.coreEnvironment,
                            metrics: Array(core.metrics.prefix(7)), extensions: [], cancelled: false,
                            globalFailure: code, writtenBytes: 0, startedAt: core.startedAt, completedAt: core.completedAt)
                    }
                }, validate: { $0.isPersistable })
                store.startV11Benchmark()
                await store.waitUntilIdle()
                let result = try XCTUnwrap(store.v7LatestResult)
                let envelope = try XCTUnwrap(result.mSeriesV11)
                XCTAssertEqual(result.mSeries?.globalFailure, code)
                XCTAssertEqual(envelope.failure, code)
                XCTAssertEqual(result.failure, .validationFailed(code))
                XCTAssertTrue(MSeriesV11RawPayload.validates(core: result.mSeries, envelope: envelope))
                XCTAssertTrue(result.isPersistable)
                XCTAssertEqual(store.v11SaveState?.state, .saved)
                let saved = await repository.records
                XCTAssertEqual(saved, [result], "raw Core codes must be archived unchanged")
                let presentation = MSeriesV11PagePresentation.ResultDisposition(
                    result: result, history: store.v7History, saveState: store.v11SaveState)
                let expected = try V11CoreStopContract.text(code)
                XCTAssertEqual(presentation.terminationText, language == .zhHans ? expected.zh : expected.en)
                XCTAssertEqual(presentation.measuredCoreCount, 7)
                XCTAssertFalse(presentation.measurementCompleted)
                XCTAssertTrue(presentation.savedLocally)
                XCTAssertFalse(presentation.terminationText?.contains(code) == true)
                XCTAssertEqual(control.events, ["identity", "core"], "Core failure must not dispatch extension workloads")
                XCTAssertEqual(control.telemetryLifecycle, ["begin", "finish"])
            }
        }
    }

    func testFailedFirstReadbackRecoversAfterLaterExactLoadedRecordWithoutChangingMeasurement() async throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            for stopped in [false, true] {
                let control = V11RunSubstitute()
                if stopped { control.failStage = "power.cpu.single"; control.failure = "thermal" }
                let repository = V11RecoveryHistory()
                let store = try store(control: control, repository: repository, validate: { $0.isPersistable })
                store.startV11Benchmark()
                await store.waitUntilIdle()
                let result = try XCTUnwrap(store.v7LatestResult)
                let saved = await repository.records
                XCTAssertEqual(saved, [result], "the memory commit succeeded, but its first readback was hidden")
                XCTAssertEqual(result.failure, stopped ? .validationFailed("thermalProtection") : nil)
                XCTAssertEqual(store.v11SaveState?.state, .failed)
                XCTAssertTrue(store.v7History.isEmpty)
                let initial = MSeriesV11PagePresentation.ResultDisposition(
                    result: result, history: store.v7History, saveState: store.v11SaveState)
                XCTAssertTrue(initial.saveFailed)
                XCTAssertFalse(initial.savedLocally)
                XCTAssertEqual(initial.storageText, L10n.text("保存失败 · 仅当前会话可查看", "Save failed · Available only in this session"))
                await store.loadHistory()
                XCTAssertEqual(store.v11SaveState?.state, .failed, "an empty second readback still cannot confirm the save")
                await repository.show(saved, status: .loaded)
                await store.loadHistory()
                XCTAssertEqual(store.v11SaveState, MSeriesV11SaveState(result: result, state: .saved))
                XCTAssertEqual(store.v7LatestResult, result, "storage reconciliation must not rewrite the measurement or stop reason")
                XCTAssertEqual(store.v7History, saved)
                let recovered = MSeriesV11PagePresentation.ResultDisposition(
                    result: result, history: store.v7History, saveState: store.v11SaveState)
                XCTAssertTrue(recovered.savedLocally)
                XCTAssertFalse(recovered.saveFailed)
                XCTAssertNil(recovered.saveFailureText)
                XCTAssertEqual(recovered.storageText, L10n.text("结果保存在本机", "Saved locally"))
                XCTAssertEqual(recovered.failure, initial.failure)
                XCTAssertEqual(recovered.terminationText, initial.terminationText)
                XCTAssertEqual(recovered.measurementCompleted, initial.measurementCompleted)
                XCTAssertFalse(recovered.completionText.contains(L10n.text("保存失败", "Save failed")))
                await store.loadHistory()
                XCTAssertEqual(store.v11SaveState?.state, .saved, "confirmed readback stays idempotent")
                XCTAssertEqual(control.telemetryLifecycle, ["begin", "finish"])
            }
        }
    }

    func testReadbackRecoveryRejectsDifferentIdentitiesAndUnconfirmedLoads() async throws {
        let repository = V11RecoveryHistory()
        let store = try store(control: V11RunSubstitute(), repository: repository, validate: { $0.isPersistable })
        store.startV11Benchmark(mode: "pressure10m")
        await store.waitUntilIdle()
        let result = try XCTUnwrap(store.v7LatestResult)
        XCTAssertNotNil(result.recordID)
        let rawSHA = try XCTUnwrap(result.mSeriesV11?.rawPayloadSHA256)
        XCTAssertFalse(rawSHA.isEmpty)
        XCTAssertEqual(store.v11SaveState?.state, .failed)
        // Deliberately untrusted header substitutions isolate each identity
        // guard. The repository reports these as loaded; none confirms ours.
        let data = try JSONEncoder().encode(result)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for identity in ["recordID", "session", "mSeriesV11", "failure"] {
            var changed = original
            switch identity {
            case "recordID": changed[identity] = UUID().uuidString
            case "session":
                var session = try XCTUnwrap(changed[identity] as? [String: Any])
                session["id"] = UUID().uuidString; changed[identity] = session
            case "mSeriesV11": break // Its compact payload is replaced through the model below.
            default:
                changed[identity] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BenchmarkV7Failure.cancelled))
            }
            let other: BenchmarkV7Result
            if identity == "mSeriesV11" {
                let envelope = try XCTUnwrap(result.mSeriesV11).replacingRawDigest(String(repeating: "0", count: 64))
                other = result.replacingV11Envelope(envelope)
                XCTAssertNotEqual(other.mSeriesV11?.rawPayloadSHA256, rawSHA)
            } else {
                other = try JSONDecoder().decode(BenchmarkV7Result.self, from: JSONSerialization.data(withJSONObject: changed))
            }
            XCTAssertFalse(other == result, "each substitute must actually differ from the saved measurement")
            await repository.show([other], status: .loaded)
            await store.loadHistory()
            XCTAssertEqual(store.v11SaveState?.state, .failed, "different \(identity) must remain isolated")
            XCTAssertEqual(store.v7LatestResult, result)
        }
        for status in [BenchmarkV7HistoryLoadStatus.missing, .failed, .corrupt] {
            await repository.show([result], status: status)
            await store.loadHistory()
            XCTAssertEqual(store.v11SaveState?.state, .failed, "unconfirmed \(status) readback cannot clear a failed save")
            let presentation = MSeriesV11PagePresentation.ResultDisposition(
                result: result, history: store.v7History, saveState: store.v11SaveState)
            XCTAssertTrue(presentation.saveFailed)
            XCTAssertFalse(presentation.savedLocally)
        }
        await repository.show([result], status: .loaded)
        await store.loadHistory()
        XCTAssertEqual(store.v11SaveState?.state, .saved)
    }

    func testCancellationThermalAndTimeoutKeepStopReasonAcrossSuccessfulAndFailedSaves() async throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            for cause in ["cancelled", "thermalProtection", "timeout"] {
                for saveFails in [false, true] {
                    let control = V11RunSubstitute()
                    if cause == "cancelled" { control.cancelStage = "power.cpu.single" }
                    else { control.failStage = "power.cpu.single"; control.failure = cause == "timeout" ? "timeout" : "thermal" }
                    let repository = V11MemoryHistory(throwsOnSave: saveFails)
                    let store = try store(control: control, repository: repository, validate: { $0.isPersistable })
                    store.startV11Benchmark()
                    await store.waitUntilIdle()
                    let result = try XCTUnwrap(store.v7LatestResult)
                    let expected: BenchmarkV7Failure = cause == "cancelled" ? .cancelled : .validationFailed(cause)
                    XCTAssertEqual(result.failure, expected, "a local save must not overwrite the original stop cause")
                    XCTAssertEqual(result.mSeriesV11?.failure, cause)
                    XCTAssertEqual(store.v11SaveState?.state, saveFails ? .failed : .saved)
                    XCTAssertEqual(store.v7State.phase, saveFails ? .failed : cause == "cancelled" ? .cancelled : .failed)
                    let presentation = MSeriesV11PagePresentation.ResultDisposition(result: result, history: store.v7History, saveState: store.v11SaveState)
                    XCTAssertEqual(presentation.failure, expected)
                    XCTAssertFalse(presentation.measurementCompleted)
                    XCTAssertEqual(presentation.savedLocally, !saveFails)
                    XCTAssertEqual(presentation.saveFailed, saveFails)
                    XCTAssertEqual(presentation.saveFailureText != nil, saveFails)
                    XCTAssertEqual(presentation.terminationText, MSeriesV11PagePresentation.ResultDisposition.reasonText(cause))
                    XCTAssertTrue(presentation.completionText.contains(L10n.text(cause == "cancelled" ? "已取消" : "已中止", cause == "cancelled" ? "Cancelled" : "Stopped")))
                    XCTAssertEqual(presentation.completionText.contains(L10n.text("保存失败", "Save failed")), saveFails)
                    if cause != "cancelled" { XCTAssertFalse(presentation.terminationText?.contains(cause) == true) }
                    XCTAssertEqual(control.telemetryLifecycle, ["begin", "finish"])
                    let saved = await repository.records
                    XCTAssertEqual(saved.count, saveFails ? 0 : 1)
                    if !saveFails { XCTAssertEqual(saved.first?.failure, expected) }
                }
            }
        }
    }

    func testCoreItemEightCancellingPersistingCancelledKeepsSevenAndRecreatedWorkspace() async throws {
        let coreGate = V11AsyncGate()
        let saveGate = V11AsyncGate()
        let repository = V11MemoryHistory(saveGate: saveGate)
        let store = try store(control: V11RunSubstitute(), repository: repository, configure: { dependencies in
            dependencies.core = { session, _, _, _, _, progress in
                await progress(session, MSeriesProtocol.coreIDs[7], 7)
                await coreGate.wait()
                let core = MSeriesV11TestFixtures.legacyCore()
                return MSeriesResult(sessionID: session, schema: core.schema, plan: core.plan, workload: core.workload,
                    fixture: core.fixture, implementation: core.implementation, statisticsVersion: core.statisticsVersion,
                    scoringVersion: core.scoringVersion, referenceVersion: core.referenceVersion, contractHash: core.contractHash,
                    hardware: core.hardware, coreEnvironment: core.coreEnvironment, metrics: Array(core.metrics.prefix(7)),
                    extensions: [], cancelled: true, globalFailure: "cancelled", writtenBytes: 0,
                    startedAt: core.startedAt, completedAt: core.completedAt)
            }
        }, validate: { $0.isPersistable })
        store.startV11Benchmark(accelerators: [.tensorFP16])
        await assertEntered(coreGate)
        XCTAssertEqual(store.v7State.workloadID, MSeriesProtocol.coreIDs[7])
        var phases: [BenchmarkV7Phase] = []
        var fractions: [Double] = []
        func capture() {
            // Destroy and reconstruct the actual Workspace value; its @State
            // selection/count cannot supply the running presentation.
            var workspace: PerformanceBenchmarkWorkspaceView? = makeWorkspace(store)
            let first = workspace!.runningPresentation
            workspace = nil
            let rebuilt = makeWorkspace(store).runningPresentation
            XCTAssertEqual(first.state, rebuilt.state)
            XCTAssertEqual(first.mode, rebuilt.mode)
            XCTAssertEqual(first.knownCoreCount, rebuilt.knownCoreCount)
            XCTAssertGreaterThanOrEqual(rebuilt.elapsedSeconds ?? 0, first.elapsedSeconds ?? 0)
            XCTAssertEqual(rebuilt.mode, "standard")
            XCTAssertEqual(rebuilt.completedCoreCount, 7)
            XCTAssertEqual(store.v11RunConfiguration?.accelerators, [.tensorFP16])
            XCTAssertLessThanOrEqual(rebuilt.displayedFraction ?? 1, 0.99)
            phases.append(store.v7State.phase); fractions.append(rebuilt.displayedFraction ?? 1)
        }
        capture()
        store.cancelV7(); capture()
        await coreGate.release()
        await assertEntered(saveGate); capture()
        await saveGate.release()
        await store.waitUntilIdle(); capture()
        XCTAssertEqual(phases, [.running, .cancelling, .persisting, .cancelled])
        XCTAssertTrue(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertEqual(store.v7LatestResult?.failure, .cancelled)
        XCTAssertEqual(store.v7LatestResult?.mSeries?.metrics.count, 7)
        XCTAssertTrue(store.v7LatestResult?.isPersistable == true)
    }

    func testPressureModeIsFrozenAcrossWorkspaceReconstruction() async throws {
        let control = V11RunSubstitute()
        let driver = V11DrainBatchSubstitute(control: control)
        let store = try store(control: control, repository: V11MemoryHistory(), driver: driver, validate: { $0.isPersistable })
        store.startV11Benchmark(mode: "pressure10m")
        await driver.waitUntilEntered()
        var workspace: PerformanceBenchmarkWorkspaceView? = makeWorkspace(store)
        XCTAssertEqual(workspace?.runningPresentation.mode, "pressure10m")
        workspace = nil
        let rebuilt = makeWorkspace(store)
        XCTAssertEqual(rebuilt.runningPresentation.mode, "pressure10m")
        XCTAssertEqual(rebuilt.runningPresentation.completedCoreCount, 0)
        store.cancelV7()
        await driver.release()
        await store.waitUntilIdle()
        XCTAssertEqual(makeWorkspace(store).runningPresentation.completedCoreCount, 0)
    }

    private func assertEntered(_ gate: V11AsyncGate) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.entered) && ContinuousClock.now < deadline { await Task.yield() }
        let entered = await gate.entered
        XCTAssertTrue(entered, "synthetic gate must be reached before its bounded deadline")
    }
    private func makeWorkspace(_ store: MacBenchmarkStore) -> PerformanceBenchmarkWorkspaceView {
        .init(benchmarkStore: store, leaderboardStore: BenchmarkV7LeaderboardStore(identityProvider:
            DefaultBenchmarkV7LeaderboardIdentityProvider(defaults: TestPreferenceDomain.make(for: self))),
            heavyWorkActivityStore: HeavyWorkActivityStore(coordinator: HeavyWorkCoordinator()),
            monitorState: MenuBarMonitorState(), auxiliaryState: MenuBarAuxiliaryMonitorState(powerHistoryURL: nil),
            helperMonitor: HelperPowerMetricsMonitor(availability: { .needsHelper }, request: {
                XCTFail("reconstructing a Workspace must not request live helper telemetry"); return .failure(.unavailable)
            }, automaticSampling: false), isTelemetryPaused: true, refreshTelemetry: {
                XCTFail("value reconstruction must not refresh live providers")
            })
    }

}

private final class V11ValidationProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var readings: [Bool] = []
    private var isReleased = false
    let block: Bool
    init(block: Bool = false) { self.block = block }
    var entered: Bool { condition.withLock { !readings.isEmpty } }
    var released: Bool { condition.withLock { isReleased } }
    var mainThreadReadings: [Bool] { condition.withLock { readings } }
    func record() {
        condition.lock()
        readings.append(Thread.isMainThread)
        // Bounded wait also lets a main-thread regression finish and fail assertions.
        let deadline = Date().addingTimeInterval(3)
        while block && !isReleased {
            if !condition.wait(until: deadline) { isReleased = true }
        }
        condition.unlock()
    }
    func release() { condition.withLock { isReleased = true; condition.broadcast() } }
}
private actor V11MemoryHistory: BenchmarkV7HistoryPersisting {
    private(set) var records: [BenchmarkV7Result] = []
    let throwsOnSave: Bool
    let saveError: BenchmarkV7HistoryError?
    let hidesReadback: Bool
    let saveGate: V11AsyncGate?
    init(throwsOnSave: Bool = false, saveError: BenchmarkV7HistoryError? = nil, hidesReadback: Bool = false, saveGate: V11AsyncGate? = nil) {
        self.throwsOnSave = throwsOnSave; self.saveError = saveError; self.hidesReadback = hidesReadback; self.saveGate = saveGate
    }
    func load() -> [BenchmarkV7Result] { hidesReadback ? [] : records }
    func save(_ result: BenchmarkV7Result) async throws {
        if let saveGate { await saveGate.wait() }
        if throwsOnSave { throw CocoaError(.fileWriteUnknown) }
        if let saveError { throw saveError }
        records.append(result)
    }
    func replace(recordID: UUID, with result: BenchmarkV7Result) { records = records.map { $0.recordID == recordID ? result : $0 } }
    func delete(recordID: UUID) -> Bool { let count = records.count; records.removeAll { $0.recordID == recordID }; return records.count != count }
    func loadStatus() -> BenchmarkV7HistoryLoadStatus { .loaded }
}
private actor V11RecoveryHistory: BenchmarkV7HistoryPersisting {
    private(set) var records: [BenchmarkV7Result] = []
    private var visible: [BenchmarkV7Result] = []
    private var status: BenchmarkV7HistoryLoadStatus = .loaded
    func load() -> [BenchmarkV7Result] { visible }
    func loadStatus() -> BenchmarkV7HistoryLoadStatus { status }
    func show(_ records: [BenchmarkV7Result], status: BenchmarkV7HistoryLoadStatus) {
        visible = records; self.status = status
    }
    func save(_ result: BenchmarkV7Result) { records.append(result) }
    func replace(recordID: UUID, with result: BenchmarkV7Result) {
        records = records.map { $0.recordID == recordID ? result : $0 }
    }
    func delete(recordID: UUID) -> Bool {
        let count = records.count; records.removeAll { $0.recordID == recordID }; return records.count != count
    }
}
private actor V11AsyncGate {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private struct V11UnusedLegacyService: MacBenchmarkServicing {
    func run(profile: BenchmarkProfile, progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void) async -> MacBenchmarkRawResult {
        fatalError("v11 substitute must never enter the real legacy workload")
    }
}
private actor V11EmptyLegacyHistory: MacBenchmarkHistoryPersisting {
    func load() -> [MacBenchmarkResult] { [] }
    func save(_ result: MacBenchmarkResult) {}
}
private struct V11NoopLifecycle: MacBenchmarkLifecycleCleaning { func cleanupOrphanedArtifactsOnLaunch() async {} }

private final class V11RunSubstitute: @unchecked Sendable {
    let session = UUID()
    private let lock = NSLock()
    private var ns: UInt64 = 1_000_000_000
    private var recorded: [String] = []
    private var cleaned = 0
    private var lifecycle: [String] = []
    private var budgetForecasts: [MSeriesV11BudgetForecast] = []
    private var randomState: UInt64 = 0x92837ac59
    private var requests = 0
    var batchNanoseconds: UInt64 = 500_000_000
    var highEntropyEnvironment = false
    var maximumBatchRequests: Int?
    var cancelStage: String?
    var failStage: String?
    var failure = "timeout"
    var thermal = 0
    var events: [String] { lock.withLock { recorded } }
    var finishes: Int { lock.withLock { cleaned } }
    var telemetryLifecycle: [String] { lock.withLock { lifecycle } }
    var now: UInt64 { lock.withLock { ns } }
    var forecasts: [MSeriesV11BudgetForecast] { lock.withLock { budgetForecasts } }
    var batchRequests: Int { lock.withLock { requests } }
    func requestBatch() throws {
        let count = lock.withLock { requests += 1; return requests }
        if let maximumBatchRequests, count > maximumBatchRequests { throw MSeriesV11RunError.invalidBatch }
    }
    func recordForecast(_ value: MSeriesV11BudgetForecast) { lock.withLock { budgetForecasts.append(value) } }
    func entropy() -> String {
        lock.withLock {
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
            return String(decoding: (0..<1024).map { _ in
                randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
                return alphabet[Int((randomState >> 32) % UInt64(alphabet.count))]
            }, as: UTF8.self)
        }
    }
    func add(_ value: UInt64) { lock.withLock { ns += value } }
    func event(_ event: String) { lock.withLock { recorded.append(event) } }
    func finish() { lock.withLock { cleaned += 1 } }
    func recordLifecycle(_ event: String) { lock.withLock { lifecycle.append(event) } }
    func dependencies() -> MSeriesV11Dependencies {
        var deps = MSeriesV11Dependencies()
        deps.now = { self.now }
        deps.sleep = { try await Task.sleep(for: .milliseconds(1)) }
        deps.environment = {
            var env = MSeriesV11TestFixtures.nominal
            env.thermalState = self.thermal
            if self.highEntropyEnvironment { env.assessmentVersion = self.entropy() }
            return .init(atMonotonicNs: self.now, cpuTemperatureC: nil, gpuTemperatureC: nil, environment: env)
        }
        deps.identity = {
            self.event("identity")
            let evidence = AppleSiliconHardwareEvidence(capturedAt: Date(), nativeARM64: true, translated: false,
                brandString: "Synthetic", modelIdentifier: "Synthetic", perfLevelCount: 2,
                perfLevels: [.init(index: 0, name: "Super", physicalCores: 2, logicalCores: 2),
                             .init(index: 1, name: "Performance", physicalCores: 6, logicalCores: 6)], physicalCPUCount: 8,
                metalDeviceName: "Synthetic", profilerGPUName: "Synthetic", profilerGPUCores: 8, physicalMemoryBytes: 16*1024*1024*1024, missingReasons: [])
            return AppleSiliconIdentity(identificationStatus: .matched, chipID: "synthetic", matchedCPUOption: nil,
                matchedSKU: nil, candidateSKUIDs: [], catalogVersion: nil, catalogSHA256: nil, identificationEvidence: evidence, reasonCodes: [])
        }
        deps.core = { session, _, _, _, _, progress in
            self.event("core")
            let core = MSeriesV11TestFixtures.legacyCore()
            await progress(session, "cpu.single.integer",0)
            return MSeriesResult(sessionID: session, schema: core.schema, plan: core.plan, workload: core.workload,
                fixture: core.fixture, implementation: core.implementation, statisticsVersion: core.statisticsVersion,
                scoringVersion: core.scoringVersion, referenceVersion: core.referenceVersion, contractHash: core.contractHash,
                hardware: core.hardware, coreEnvironment: core.coreEnvironment, metrics: core.metrics, extensions: [],
                cancelled: false, globalFailure: nil, writtenBytes: 0, startedAt: core.startedAt, completedAt: core.completedAt)
        }
        deps.driverFactory = { V11BatchSubstitute(control: self) }
        deps.beginTelemetry = { self.recordLifecycle("begin") }
        deps.finishTelemetry = { self.recordLifecycle("finish") }
        deps.onEvidenceBudgetForecast = { self.recordForecast($0) }
        return deps
    }
}
private actor V11BatchSubstitute: MSeriesV11BatchDriving {
    let control: V11RunSubstitute
    init(control: V11RunSubstitute) { self.control = control }
    func prepare(id: String, workers: Int, cancellation: MSeriesCancellation) {
        control.event("\(id):\(workers)")
        if control.cancelStage == id { cancellation.cancel() }
        if control.failStage == id {
            if control.failure == "timeout" { control.add(100_000_000_000) }
            else { control.thermal = 2 }
        }
    }
    func next(id: String, cancellation: MSeriesCancellation) async throws -> MSeriesV11Batch {
        if cancellation.isCancelled { throw CancellationError() }
        try control.requestBatch()
        let start = control.now
        let interval = control.batchNanoseconds
        control.add(interval)
        await Task.yield()
        return .init(stageID: id, startMonotonicNs: start, endMonotonicNs: start + interval,
            workUnits: 50, gpuElapsedSeconds: id.contains("gpu") ? Double(interval) / 2e9 : nil, checksum: 1,
            clockDomain: MSeriesV11Windows.clockDomain)
    }
    func finish() { control.finish() }
}
private struct V11PreflightSubstitute: BenchmarkV7Preflighting {
    let report: BenchmarkV7PreflightReport
    func capture(plan: BenchmarkV7Plan, categories: [BenchmarkV7Category], targetDirectory: URL) async -> BenchmarkV7PreflightReport { report }
}
private struct V11UnusedWorkloadRunner: BenchmarkV7WorkloadRunning {
    func run(plan: BenchmarkV7Plan, categories: [BenchmarkV7Category], targetDirectory: URL,
             progress: @escaping @Sendable (BenchmarkV7Category, String, Int, Double) async -> Void) async throws -> [BenchmarkV7MetricResult] {
        XCTFail("v11 must not dispatch the legacy v7 runner")
        throw MSeriesV11RunError.invalidBatch
    }
}

private actor V11DrainBatchSubstitute: MSeriesV11BatchDriving {
    let control: V11RunSubstitute
    private var entered = false
    private var enterWaiter: CheckedContinuation<Void, Never>?
    private var drainWaiter: CheckedContinuation<Void, Never>?
    private(set) var didFinish = false
    init(control: V11RunSubstitute) { self.control = control }
    func prepare(id: String, workers: Int, cancellation: MSeriesCancellation) { control.event("\(id):\(workers)") }
    func next(id: String, cancellation: MSeriesCancellation) async -> MSeriesV11Batch {
        let start = control.now
        entered = true
        enterWaiter?.resume(); enterWaiter = nil
        await withCheckedContinuation { drainWaiter = $0 }
        control.add(500_000_000)
        return .init(stageID: id, startMonotonicNs: start, endMonotonicNs: start + 500_000_000, workUnits: 50,
            gpuElapsedSeconds: nil, checksum: 1, clockDomain: MSeriesV11Windows.clockDomain)
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { enterWaiter = $0 } } }
    func release() { drainWaiter?.resume(); drainWaiter = nil }
    func finish() { didFinish = true; control.finish() }
}

/// Inert virtual-clock drivers: these tests never submit C/Metal work.
final class MSeriesV11LivePublisherTests: XCTestCase {
    func testSlowMainActorCallbackDoesNotHoldUpMeasuredDriverOrTermination() async throws {
        let control = V11RunSubstitute()
        let gate = V11AsyncGate()
        let probe = V11PublisherProbe()
        var dependencies = control.dependencies()
        dependencies.onLiveObservation = { @MainActor live in
            await probe.record(live)
            await gate.wait() // deliberately suspended presentation, not measured work
        }
        let runner = MSeriesV11Runner(dependencies: dependencies)
        let task = Task {
            let output = await runner.run(sessionID: control.session, mode: "pressure10m",
                root: FileManager.default.temporaryDirectory, resourceJournal: nil)
            await probe.markFinished()
            return output
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await probe.finished) && ContinuousClock.now < deadline { await Task.yield() }
        let completedWhileCallbackSuspended = await probe.finished
        let entered = await gate.entered
        let callbacksBeforeRelease = await probe.values
        XCTAssertTrue(entered, "at least one real publication must enter the delayed MainActor callback")
        XCTAssertTrue(completedWhileCallbackSuspended, "measured driver and termination must finish before a delayed display callback is released")
        XCTAssertGreaterThan(control.batchRequests, 1_000)
        XCTAssertEqual(callbacksBeforeRelease.count, 1, "only one callback may be in flight")
        XCTAssertEqual(control.finishes, 2)
        XCTAssertEqual(control.telemetryLifecycle, ["begin", "finish"])
        await gate.release()
        let output = await task.value
        XCTAssertEqual(output.envelope.state, "completed")
        XCTAssertEqual(output.envelope.measuredDurationSeconds, 600)
    }

    func testFinishDropsLatestSameSessionSnapshotWhileCallbackIsSuspended() async throws {
        let gate = V11AsyncGate(), probe = V11PublisherProbe(), session = UUID()
        let publisher = MSeriesV11LivePublisher(sessionID: session, telemetry: { [] }, publish: { live in
            await probe.record(live)
            if live.endedAtNanoseconds == 1 { await gate.wait() }
        })
        publisher.submit(.init(sessionID: session, stageID: "power.cpu.allCores", batches: [], end: 1, gpu: false))
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.entered) && ContinuousClock.now < deadline { await Task.yield() }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        // This pending value is valid for the very same session. Session
        // isolation cannot mask a missing worker cancellation at finish.
        publisher.submit(.init(sessionID: session, stageID: "power.cpu.allCores", batches: [], end: 100, gpu: false))
        let beforeFinish = await probe.values
        XCTAssertEqual(beforeFinish.map(\.endedAtNanoseconds), [1])
        publisher.finish()
        await gate.release()
        await publisher.waitUntilFinished()
        let terminal = await probe.values
        XCTAssertEqual(terminal.map(\.endedAtNanoseconds), [1], "finish must discard the same-session latest value submitted while the callback was gated")
        XCTAssertTrue(terminal.allSatisfy { $0.sessionID == session })
    }

    func testCancellationDrainsDriverAndPublishesTerminalBeforeSuspendedDisplayReturns() async throws {
        let control = V11RunSubstitute(), displayGate = V11AsyncGate(), drainGate = V11AsyncGate()
        let driver = V11DisplayDrainBatchSubstitute(control: control, drainGate: drainGate)
        let probe = V11PublisherProbe()
        var dependencies = control.dependencies()
        dependencies.driverFactory = { driver }
        dependencies.onLiveObservation = { @MainActor live in
            await probe.record(live)
            await displayGate.wait()
        }
        let leaseCoordinator = HeavyWorkCoordinator()
        let coordinator = BenchmarkV7Coordinator(workloadRunner: V11UnusedWorkloadRunner(), heavyWorkCoordinator: leaseCoordinator,
            preflightService: V11PreflightSubstitute(report: MSeriesV11TestFixtures.result().preflight),
            resourceJournal: nil, v11Runner: .init(dependencies: dependencies))
        let task = Task {
            let result = await coordinator.run(sessionID: control.session, plan: MSeriesV11Protocol.plan(mode: "pressure10m"),
                targetDirectory: FileManager.default.temporaryDirectory)
            await probe.markFinished()
            return result
        }
        let enteredDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < enteredDeadline {
            let displayEntered = await displayGate.entered, drainEntered = await drainGate.entered
            if displayEntered && drainEntered { break }
            await Task.yield()
        }
        let displayEntered = await displayGate.entered, drainEntered = await drainGate.entered
        XCTAssertTrue(displayEntered, "actual publication must be suspended before cancelling")
        XCTAssertTrue(drainEntered, "one synthetic batch must remain in flight")
        task.cancel()
        let ownerBeforeDrain = await leaseCoordinator.activeOwner, finishedBeforeDrain = await driver.didFinish
        XCTAssertEqual(ownerBeforeDrain, .benchmark)
        XCTAssertFalse(finishedBeforeDrain)
        await drainGate.release()
        let finishedDeadline = ContinuousClock.now + .seconds(5)
        while !(await probe.finished) && ContinuousClock.now < finishedDeadline { await Task.yield() }
        let terminated = await probe.finished, drained = await driver.didFinish, ownerAfterDrain = await leaseCoordinator.activeOwner
        let callbacks = await probe.values
        XCTAssertTrue(terminated, "cancelled terminal result must precede releasing the display callback")
        XCTAssertTrue(drained)
        XCTAssertNil(ownerAfterDrain, "the lease is released only after draining, without waiting for presentation")
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(control.finishes, 1)
        XCTAssertEqual(control.telemetryLifecycle, ["begin", "finish"])
        await displayGate.release()
        let result = await task.value
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(result.mSeriesV11?.state, "cancelled")
        XCTAssertEqual(result.mSeriesV11?.drainDurationSeconds, 0.5)
    }

    func testBoundedQueueRetainsOnlyLatestSnapshotAndFinishDropsPending() async throws {
        let gate = V11AsyncGate(), probe = V11PublisherProbe(), session = UUID()
        let publisher = MSeriesV11LivePublisher(sessionID: session, telemetry: { [] }, publish: { live in
            await probe.record(live)
            if live.endedAtNanoseconds == 1 { await gate.wait() }
        })
        func submit(_ end: UInt64, sessionID: UUID? = nil) {
            publisher.submit(.init(sessionID: sessionID ?? session, stageID: "power.cpu.allCores", batches: [], end: end, gpu: false))
        }
        submit(1)
        let firstDeadline = ContinuousClock.now + .seconds(5)
        while !(await gate.entered) && ContinuousClock.now < firstDeadline { await Task.yield() }
        let entered = await gate.entered; XCTAssertTrue(entered)
        for value in UInt64(2)...100 { submit(value) }
        await gate.release()
        let secondDeadline = ContinuousClock.now + .seconds(5)
        while (await probe.values.count) < 2 && ContinuousClock.now < secondDeadline { await Task.yield() }
        let values = await probe.values
        XCTAssertEqual(values.map(\.endedAtNanoseconds), [1, 100], "a bounded queue must replace waiting snapshots, not accumulate tasks")
        submit(101, sessionID: UUID())
        publisher.finish(); submit(102)
        await publisher.waitUntilFinished()
        let terminal = await probe.values
        XCTAssertEqual(terminal.map(\.endedAtNanoseconds), [1, 100])
        XCTAssertTrue(terminal.allSatisfy { $0.sessionID == session })
    }
}
private actor V11PublisherProbe {
    private(set) var values: [MSeriesV11LiveObservation] = []
    private(set) var finished = false
    func record(_ value: MSeriesV11LiveObservation) { values.append(value) }
    func markFinished() { finished = true }
}

private actor V11DisplayDrainBatchSubstitute: MSeriesV11BatchDriving {
    let control: V11RunSubstitute
    let drainGate: V11AsyncGate
    private var count = 0
    private(set) var didFinish = false
    init(control: V11RunSubstitute, drainGate: V11AsyncGate) { self.control = control; self.drainGate = drainGate }
    func prepare(id: String, workers: Int, cancellation: MSeriesCancellation) { control.event("\(id):\(workers)") }
    func next(id: String, cancellation: MSeriesCancellation) async -> MSeriesV11Batch {
        let start = control.now
        count += 1
        // Publish at the real five-second boundary, then hold an in-flight
        // batch so cancellation must drain before releasing the lease.
        if count == 12 { await drainGate.wait() }
        control.add(500_000_000)
        await Task.yield()
        return .init(stageID: id, startMonotonicNs: start, endMonotonicNs: start + 500_000_000, workUnits: 50,
            gpuElapsedSeconds: nil, checksum: 1, clockDomain: MSeriesV11Windows.clockDomain)
    }
    func finish() { didFinish = true; control.finish() }
}
