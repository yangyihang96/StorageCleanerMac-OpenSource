import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MacBenchmarkStoreTests: XCTestCase {
    func testSuccessfulRunPublishesRawOnlyTruthAndPersistsOnlyRawMetrics() async throws {
        let raw = makeRawResult()
        let service = ScriptedMacBenchmarkService(result: raw)
        let history = RecordingMacBenchmarkHistory()
        let store = try makeStore(service: service, history: history)

        store.start()
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(store.latestResult?.rawResult, raw)
        XCTAssertNil(store.latestResult?.overallScore)
        XCTAssertEqual(store.rawOnlyReason, .verifiedBaselineUnavailable)
        XCTAssertEqual(store.history.count, 1)
        let saved = await history.savedResults()
        XCTAssertEqual(saved.count, 1)
        XCTAssertNil(saved.first?.overallScore)
        XCTAssertTrue(saved.first?.componentScores.isEmpty == true)
        let callCount = await service.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testSuccessfulRunInvokesAutomaticUploadHookOnlyAfterCompletion() async throws {
        let raw = makeRawResult()
        var completedResult: MacBenchmarkResult?
        var completedHistory: [MacBenchmarkResult] = []
        let history = RecordingMacBenchmarkHistory()
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: raw),
            history: history,
            onCompletedResult: { result, history in
                completedResult = result
                completedHistory = history
            }
        )

        XCTAssertNil(completedResult)
        store.start()
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(completedResult?.rawResult, raw)
        XCTAssertEqual(completedHistory.count, 1)
    }

    func testScoredRunPersistsImmutableScoreSnapshotAndExposesVersionManifest()
        async throws {
        let raw = makeRawResult()
        let baseline = try makeVerifiedBaseline(for: raw)
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: baseline.baseline.comparisonKey.baselineVersion,
            verifiedBaselines: [baseline]
        )
        let history = RecordingMacBenchmarkHistory()
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: raw),
            history: history,
            catalog: catalog
        )

        store.start()
        await store.waitUntilIdle()

        let savedResults = await history.savedResults()
        let saved = try XCTUnwrap(savedResults.first)
        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(saved.rawResult, raw)
        XCTAssertNotNil(saved.overallScore)
        XCTAssertEqual(saved.componentScores.count, BenchmarkComponent.allCases.count)
        XCTAssertEqual(
            saved.algorithmManifest?.workloadVersion,
            MacBenchmarkScoring.balancedCompositeWorkloadVersion
        )
        XCTAssertEqual(
            saved.algorithmManifest?.referenceSetVersion,
            baseline.baseline.comparisonKey.baselineVersion
        )
    }

    func testUnstableV6RunCompletesPersistsAndExplainsRawOnlyResult() async throws {
        let raw = makeRawResult(
            samplesByComponent: [.cpuSingle: [80, 100, 120]]
        )
        let baseline = try makeVerifiedBaseline(for: raw)
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: [baseline]
        )
        let history = RecordingMacBenchmarkHistory()
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: raw),
            history: history,
            catalog: catalog
        )

        store.start()
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(store.rawOnlyReason, .unstableSamples)
        XCTAssertEqual(store.latestResult?.rawResult, raw)
        XCTAssertNil(store.latestResult?.overallScore)
        let saved = await history.savedResults()
        XCTAssertEqual(saved.count, 1)
        XCTAssertNil(saved.first?.overallScore)
    }

    func testProgressIsMonotonicAndInvalidLateValuesAreClampedOrIgnored() async throws {
        let raw = makeRawResult()
        let updates = [
            MacBenchmarkProgress(
                stage: .cpuSingle,
                completedSampleCount: 3,
                totalSampleCount: 18,
                progress: 0.3,
                elapsedSeconds: 3
            ),
            MacBenchmarkProgress(
                stage: .cpuMulti,
                completedSampleCount: 2,
                totalSampleCount: 18,
                progress: 0.1,
                elapsedSeconds: 2
            ),
            MacBenchmarkProgress(
                stage: .preflight,
                completedSampleCount: 3,
                totalSampleCount: 18,
                progress: 0.3,
                elapsedSeconds: 3
            ),
            MacBenchmarkProgress(
                stage: .preflight,
                completedSampleCount: 4,
                totalSampleCount: 18,
                progress: 0.4,
                elapsedSeconds: 4
            ),
            MacBenchmarkProgress(
                stage: .gpu,
                completedSampleCount: 20,
                totalSampleCount: 18,
                progress: 2,
                elapsedSeconds: 4
            ),
        ]
        let gate = StoreServiceGate()
        let service = ScriptedMacBenchmarkService(
            result: raw,
            updates: updates,
            gate: gate
        )
        let store = try makeStore(service: service)

        store.start()
        await gate.waitUntilPaused()

        XCTAssertEqual(store.progress?.stage, .cpuSingle)
        XCTAssertEqual(store.progress?.completedSampleCount, 3)
        XCTAssertEqual(store.progress?.progress, 0.3)
        XCTAssertEqual(store.progress?.elapsedSeconds, 3)
        await gate.resume()
        await store.waitUntilIdle()
        XCTAssertEqual(store.state, .completed)
    }

    func testDiskWriteReadAlternationRemainsVisibleAcrossSamples() async throws {
        let updates = [
            MacBenchmarkProgress(
                stage: .diskWrite,
                completedSampleCount: 13,
                totalSampleCount: 18,
                progress: 13.0 / 18.0,
                elapsedSeconds: 7
            ),
            MacBenchmarkProgress(
                stage: .diskRead,
                completedSampleCount: 14,
                totalSampleCount: 18,
                progress: 14.0 / 18.0,
                elapsedSeconds: 8
            ),
            MacBenchmarkProgress(
                stage: .diskWrite,
                completedSampleCount: 15,
                totalSampleCount: 18,
                progress: 15.0 / 18.0,
                elapsedSeconds: 9
            ),
            MacBenchmarkProgress(
                stage: .diskRead,
                completedSampleCount: 16,
                totalSampleCount: 18,
                progress: 16.0 / 18.0,
                elapsedSeconds: 10
            ),
        ]
        let gate = StoreServiceGate()
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(
                result: makeRawResult(),
                updates: updates,
                gate: gate
            )
        )

        store.start()
        await gate.waitUntilPaused()

        XCTAssertEqual(store.progress?.stage, .diskRead)
        XCTAssertEqual(store.progress?.completedSampleCount, 16)
        XCTAssertEqual(store.progress?.elapsedSeconds, 10)

        await gate.resume()
        await store.waitUntilIdle()
        XCTAssertEqual(store.state, .completed)
    }

    func testReentrantStartRunsServiceOnlyOnce() async throws {
        let gate = StoreServiceGate()
        let service = ScriptedMacBenchmarkService(
            result: makeRawResult(),
            gate: gate
        )
        let store = try makeStore(service: service)

        store.start()
        store.start()
        await gate.waitUntilPaused()
        let callCountWhileRunning = await service.calls()
        XCTAssertEqual(callCountWhileRunning, 1)

        await gate.resume()
        await store.waitUntilIdle()
        let finalCallCount = await service.calls()
        XCTAssertEqual(finalCallCount, 1)
    }

    func testLaunchCleanupAndHistorySyncAreRequestedOnlyOnce() async throws {
        let lifecycleCleaner = ScriptedMacBenchmarkLifecycleCleaner()
        let service = ScriptedMacBenchmarkService(result: makeRawResult())
        let storedResult = MacBenchmarkScoring.rawOnly(rawResult: makeRawResult())
        let history = RecordingMacBenchmarkHistory(initial: [storedResult])
        var syncedResults: [[MacBenchmarkResult]] = []
        let store = try makeStore(
            service: service,
            lifecycleCleaner: lifecycleCleaner,
            history: history,
            onCompletedResult: { result, history in
                syncedResults.append([result] + history)
            }
        )

        await store.prepareLifecycleOnLaunch()
        await store.prepareLifecycleOnLaunch()

        let cleanupCount = await lifecycleCleaner.calls()
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(syncedResults, [[storedResult, storedResult]])
    }

    func testHistoryLoadFailureIsVisibleWithoutInventingEmptySuccess()
        async throws {
        let history = RecordingMacBenchmarkHistory(
            loadStatus: .failed(.historyFileCorrupt)
        )
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: makeRawResult()),
            history: history
        )

        await store.loadHistory()

        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.notice, .historyLoadFailed)
    }

    func testCancelAllRejectsLateCoreSuccessAndNeverPersists() async throws {
        let gate = StoreServiceGate()
        let service = ScriptedMacBenchmarkService(
            result: makeRawResult(),
            gate: gate
        )
        let history = RecordingMacBenchmarkHistory()
        let store = try makeStore(service: service, history: history)

        store.start()
        await gate.waitUntilPaused()
        store.cancelAll()
        XCTAssertEqual(store.state, .cancelling)
        await gate.resume()
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .cancelled)
        XCTAssertNil(store.latestResult)
        let saved = await history.savedResults()
        XCTAssertTrue(saved.isEmpty)
    }

    func testServiceFailureNeverReplacesSuccessfulHistory() async throws {
        let raw = makeRawResult(failure: .timedOut(.gpu))
        let existingRaw = makeRawResult(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let existing = MacBenchmarkScoring.rawOnly(rawResult: existingRaw)
        let history = RecordingMacBenchmarkHistory(initial: [existing])
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: raw),
            history: history
        )
        await store.loadHistory()

        store.start()
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .failed(.timedOut(.gpu)))
        XCTAssertEqual(store.latestResult?.rawResult, existingRaw)
        let saved = await history.savedResults()
        XCTAssertEqual(saved, [existing])
    }

    func testHistoryLoadKeepsRepositoryValidatedLegacyGenerationsVisible() async throws {
        let currentRaw = makeRawResult()
        let v4Raw = makeRawResult(
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            workloadVersion: "mac-benchmark-standard-v4"
        )
        let v3Raw = makeRawResult(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            profile: .quick,
            workloadVersion: "mac-benchmark-quick-v3"
        )
        let history = RecordingMacBenchmarkHistory(initial: [
            MacBenchmarkScoring.rawOnly(rawResult: currentRaw),
            MacBenchmarkScoring.rawOnly(rawResult: v4Raw),
            MacBenchmarkScoring.rawOnly(rawResult: v3Raw),
        ])
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: currentRaw),
            history: history
        )

        await store.loadHistory()

        XCTAssertEqual(store.history.count, 3)
        XCTAssertEqual(
            Set(store.history.compactMap { $0.rawResult?.workloadVersion }),
            Set([
                MacBenchmarkScoring.balancedCompositeWorkloadVersion,
                "mac-benchmark-standard-v4",
                "mac-benchmark-quick-v3",
            ])
        )
        XCTAssertEqual(store.latestResult?.rawResult, currentRaw)
    }

    func testHistoryWriteFailureDoesNotMisreportCompletedMeasurementsAsFailed() async throws {
        let history = RecordingMacBenchmarkHistory(saveShouldFail: true)
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: makeRawResult()),
            history: history
        )

        store.start()
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .completed)
        XCTAssertNotNil(store.latestResult)
        XCTAssertEqual(store.notice, .historySaveFailed)
        XCTAssertTrue(store.history.isEmpty)
    }

    func testStaleHistoryLoadCannotOverwriteACompletedRun() async throws {
        let olderRaw = makeRawResult(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newerRaw = makeRawResult(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let history = DelayedFirstLoadMacBenchmarkHistory(
            initial: [MacBenchmarkScoring.rawOnly(rawResult: olderRaw)]
        )
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: newerRaw),
            history: history
        )

        let loadTask = Task { await store.loadHistory() }
        await history.waitUntilFirstLoadStarts()
        store.start()
        await store.waitUntilIdle()
        await history.releaseFirstLoad()
        await loadTask.value

        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(store.latestResult?.rawResult, newerRaw)
        XCTAssertEqual(store.history.first?.rawResult, newerRaw)
    }

    func testCancellationDuringPersistenceKeepsCommittedResultConsistent() async throws {
        let raw = makeRawResult()
        let history = BlockingSaveMacBenchmarkHistory()
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: raw),
            history: history
        )

        store.start()
        await history.waitUntilSaveStarts()
        XCTAssertTrue(store.isRunning)

        store.cancel()
        XCTAssertTrue(store.isRunning)
        XCTAssertNotEqual(store.state, .cancelling)

        await history.releaseSave()
        await store.waitUntilIdle()

        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(store.latestResult?.rawResult, raw)
        let saved = await history.savedResults()
        XCTAssertEqual(saved.map(\.rawResult), [raw])
    }

    func testAcceleratorRunPublishesRawOnlyResultAndPersistsSeparateHistory() async throws {
        let coreService = ScriptedMacBenchmarkService(result: makeRawResult())
        let result = makeAcceleratorResult()
        var uploadedCoreResult: MacBenchmarkResult?
        let acceleratorService = ScriptedMacAcceleratorBenchmarkService(
            result: result,
            updates: [
                MacAcceleratorBenchmarkProgress(
                    metric: .metalRaster3D,
                    completedSampleCount: 1,
                    totalSampleCount: 18,
                    elapsedSeconds: 0.1
                ),
                MacAcceleratorBenchmarkProgress(
                    metric: .mediaH264Decode,
                    completedSampleCount: 18,
                    totalSampleCount: 18,
                    elapsedSeconds: 2
                ),
            ]
        )
        let acceleratorHistory = RecordingMacAcceleratorBenchmarkHistory()
        let store = try makeStore(
            service: coreService,
            acceleratorService: acceleratorService,
            acceleratorHistory: acceleratorHistory,
            onCompletedResult: { result, _ in uploadedCoreResult = result }
        )

        store.startAcceleratorBenchmark()
        await store.waitUntilIdle()

        XCTAssertEqual(store.acceleratorState, .completed)
        XCTAssertEqual(store.latestAcceleratorResult, result)
        XCTAssertEqual(store.acceleratorHistory, [result])
        XCTAssertNil(store.acceleratorNotice)
        XCTAssertNil(store.acceleratorProgress)
        XCTAssertFalse(store.isRunning)
        let acceleratorCalls = await acceleratorService.calls()
        let coreCalls = await coreService.calls()
        let saved = await acceleratorHistory.savedResults()
        XCTAssertEqual(acceleratorCalls, 1)
        XCTAssertEqual(coreCalls, 0)
        XCTAssertNil(uploadedCoreResult)
        XCTAssertEqual(saved, [result])
    }

    func testAcceleratorInvalidResultIsRejectedWithoutSaving() async throws {
        let complete = makeAcceleratorResult()
        let invalid = MacAcceleratorBenchmarkResult(
            workloadVersion: complete.workloadVersion,
            startedAt: complete.startedAt,
            completedAt: nil,
            environment: complete.environment,
            preflight: complete.preflight,
            postflight: nil,
            measurements: [],
            failure: nil
        )
        let history = RecordingMacAcceleratorBenchmarkHistory()
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: makeRawResult()),
            acceleratorService: ScriptedMacAcceleratorBenchmarkService(result: invalid),
            acceleratorHistory: history
        )

        store.startAcceleratorBenchmark()
        await store.waitUntilIdle()

        XCTAssertEqual(store.acceleratorState, .failed(.invalidResult))
        XCTAssertEqual(store.acceleratorNotice, .resultRejected)
        XCTAssertNil(store.latestAcceleratorResult)
        let saved = await history.savedResults()
        XCTAssertTrue(saved.isEmpty)
    }

    func testCancelAllCancelsAcceleratorSessionWithoutPersisting() async throws {
        let gate = StoreServiceGate()
        let history = RecordingMacAcceleratorBenchmarkHistory()
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: makeRawResult()),
            acceleratorService: ScriptedMacAcceleratorBenchmarkService(
                result: makeAcceleratorResult(),
                gate: gate
            ),
            acceleratorHistory: history
        )

        store.startAcceleratorBenchmark()
        await gate.waitUntilPaused()
        store.cancelAll()
        XCTAssertEqual(store.acceleratorState, .cancelling)
        await gate.resume()
        await store.waitUntilIdle()

        XCTAssertEqual(store.acceleratorState, .cancelled)
        XCTAssertNil(store.latestAcceleratorResult)
        let saved = await history.savedResults()
        XCTAssertTrue(saved.isEmpty)
    }

    func testAcceleratorCancellationDuringPersistenceKeepsCommittedResult() async throws {
        let result = makeAcceleratorResult()
        let history = BlockingSaveMacAcceleratorBenchmarkHistory()
        let store = try makeStore(
            service: ScriptedMacBenchmarkService(result: makeRawResult()),
            acceleratorService: ScriptedMacAcceleratorBenchmarkService(result: result),
            acceleratorHistory: history
        )

        store.startAcceleratorBenchmark()
        await history.waitUntilSaveStarts()
        XCTAssertTrue(store.isRunning)

        store.cancelAcceleratorBenchmark()
        XCTAssertTrue(store.isRunning)
        XCTAssertNotEqual(store.acceleratorState, .cancelling)

        await history.releaseSave()
        await store.waitUntilIdle()

        XCTAssertEqual(store.acceleratorState, .completed)
        XCTAssertEqual(store.latestAcceleratorResult, result)
        let saved = await history.savedResults()
        XCTAssertEqual(saved, [result])
    }

    func testCompleteSuiteRunsAllThreeBenchmarksWithOneStart() async throws {
        let raw = makeRawResult()
        let baseline = try makeVerifiedBaseline(for: raw)
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: baseline.baseline.comparisonKey.baselineVersion,
            verifiedBaselines: [baseline]
        )
        let coreService = ScriptedMacBenchmarkService(result: raw)
        let acceleratorService = ScriptedMacAcceleratorBenchmarkService(
            result: makeAcceleratorResult()
        )
        let sustainedService = ScriptedMacSustainedBenchmarkService()
        var submittedResult: MacBenchmarkResult?
        let store = try makeStore(
            service: coreService,
            catalog: catalog,
            acceleratorService: acceleratorService,
            sustainedService: sustainedService,
            onCompletedResult: { result, _ in submittedResult = result }
        )

        store.startCompleteSuite()
        await store.waitUntilIdle()

        let coreCalls = await coreService.calls()
        let acceleratorCalls = await acceleratorService.calls()
        let sustainedCalls = await sustainedService.calls()
        XCTAssertEqual(coreCalls, 1)
        XCTAssertEqual(acceleratorCalls, 1)
        XCTAssertEqual(sustainedCalls, 1)
        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(store.acceleratorState, .completed)
        XCTAssertEqual(store.sustainedState, .completed)
        XCTAssertEqual(store.suiteOutcome, .completed)
        XCTAssertNotNil(store.latestResult?.overallScore)
        XCTAssertEqual(submittedResult, store.latestResult)
        XCTAssertNil(store.suiteStep)
        XCTAssertFalse(store.isRunning)
    }

    private func makeStore(
        service: any MacBenchmarkServicing,
        lifecycleCleaner: (any MacBenchmarkLifecycleCleaning)? = nil,
        history: (any MacBenchmarkHistoryPersisting)? = nil,
        catalog: MacBenchmarkBaselineCatalog? = nil,
        acceleratorService: (any MacAcceleratorBenchmarkServicing)? = nil,
        acceleratorHistory: (any MacAcceleratorBenchmarkHistoryPersisting)? = nil,
        sustainedService: (any MacSustainedBenchmarkServicing)? = nil,
        onCompletedResult: ((MacBenchmarkResult, [MacBenchmarkResult]) -> Void)? = nil
    ) throws -> MacBenchmarkStore {
        let resolvedCatalog = try catalog ?? MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "m5-pro-v1",
            verifiedBaselines: []
        )
        return MacBenchmarkStore(
            service: service,
            resultProcessor: MacBenchmarkResultProcessor(
                baselineCatalog: resolvedCatalog
            ),
            lifecycleCleaner: lifecycleCleaner
                ?? NoopMacBenchmarkLifecycleCleaner(),
            historyRepository: history,
            acceleratorService: acceleratorService,
            acceleratorHistoryRepository: acceleratorHistory,
            sustainedService: sustainedService,
            onCompletedResult: onCompletedResult
        )
    }

    private func makeAcceleratorResult() -> MacAcceleratorBenchmarkResult {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let requiredBytes = MacAcceleratorBenchmarkService.requiredDiskBytes
        let preflight = BenchmarkPreflight(
            capturedAt: startedAt.addingTimeInterval(1),
            powerSource: .acPower,
            batteryPercent: 80,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 100_000_000_000,
            requiredDiskBytes: requiredBytes,
            warnings: []
        )
        return MacAcceleratorBenchmarkResult(
            workloadVersion: MacAcceleratorBenchmarkResult.protocolVersion,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(4),
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: "Apple Test",
                activeProcessorCount: 10,
                physicalMemoryBytes: 16_000_000_000,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS Test",
                appVersion: "1.0",
                appBuild: "1"
            ),
            preflight: preflight,
            postflight: BenchmarkPostflight(
                capturedAt: startedAt.addingTimeInterval(3),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: requiredBytes,
                warnings: []
            ),
            measurements: MacAcceleratorMetric.allCases.enumerated().map { index, metric in
                MacAcceleratorMeasurement(
                    metric: metric,
                    availability: .measured,
                    samples: [99, 100, 101].map { value in
                        BenchmarkComponentSample(
                            value: Double(value + index * 100),
                            elapsedSeconds: 0.25,
                            checksum: UInt64(index + 1)
                        )
                    }
                )
            },
            failure: nil
        )
    }

    private func makeRawResult(
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        profile: BenchmarkProfile = .standard,
        workloadVersion: String = MacBenchmarkScoring.balancedCompositeWorkloadVersion,
        failure: MacBenchmarkFailure? = nil,
        samplesByComponent: [BenchmarkComponent: [Double]] = [:]
    ) -> MacBenchmarkRawResult {
        let isComplete = failure == nil
        return MacBenchmarkRawResult(
            profile: profile,
            workloadVersion: workloadVersion,
            startedAt: startedAt,
            completedAt: isComplete ? startedAt.addingTimeInterval(12) : nil,
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: "Apple Test",
                activeProcessorCount: 10,
                physicalMemoryBytes: 16_000_000_000,
                systemDiskCapacityBytes:
                    MacBenchmarkScoring.referenceSystemDiskCapacityBytes,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS 26",
                appVersion: "1.5.0",
                appBuild: "1"
            ),
            preflight: BenchmarkPreflight(
                capturedAt: startedAt,
                powerSource: .acPower,
                batteryPercent: 80,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 3_000_000_000,
                warnings: []
            ),
            postflight: isComplete ? BenchmarkPostflight(
                capturedAt: startedAt.addingTimeInterval(11),
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 3_000_000_000,
                warnings: []
            ) : nil,
            capabilitySet: .all,
            measurements: isComplete ? BenchmarkComponent.allCases.map { component in
                let values = samplesByComponent[component] ?? [100, 101, 102]
                return BenchmarkComponentMeasurement(
                    component: component,
                    unit: component == .gpu
                        ? .millionTrianglesPerSecond
                        : component.metricUnit,
                    samples: values.enumerated().map { index, value in
                        BenchmarkComponentSample(
                            value: value,
                            elapsedSeconds: 1,
                            checksum: UInt64(component.rawValue.count)
                        )
                    }
                )
            } : [],
            failure: failure
        )
    }

    private func makeVerifiedBaseline(
        for raw: MacBenchmarkRawResult
    ) throws -> VerifiedMacBenchmarkBaseline {
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "m5-pro-v1",
            profile: raw.profile,
            architecture: raw.environment.architecture,
            capabilitySet: raw.capabilitySet
        )
        let metrics = Dictionary(
            uniqueKeysWithValues: BenchmarkComponent.allCases.map { ($0, 101.0) }
        )
        let frozenAt = Date(timeIntervalSince1970: 1_800_000_500)
        let report = MacBenchmarkCalibrationReport(
            schemaVersion: MacBenchmarkCalibrationReport.currentSchemaVersion,
            key: key,
            referenceMetrics: metrics,
            referenceHardware: "Apple M5 Pro reference",
            frozenAt: frozenAt,
            sourceRunSHA256s: [
                MacBenchmarkBaselineVerification.sha256Hex(Data("run-1".utf8)),
                MacBenchmarkBaselineVerification.sha256Hex(Data("run-2".utf8)),
                MacBenchmarkBaselineVerification.sha256Hex(Data("run-3".utf8)),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        return try VerifiedMacBenchmarkBaseline(
            baseline: MacBenchmarkBaseline(
                comparisonKey: key,
                referenceMetrics: metrics,
                reportSHA256: MacBenchmarkBaselineVerification.sha256Hex(data),
                referenceHardware: report.referenceHardware,
                frozenAt: frozenAt
            ),
            calibrationReport: data
        )
    }
}

private actor ScriptedMacBenchmarkService: MacBenchmarkServicing {
    private let result: MacBenchmarkRawResult
    private let updates: [MacBenchmarkProgress]
    private let gate: StoreServiceGate?
    private var callCount = 0

    init(
        result: MacBenchmarkRawResult,
        updates: [MacBenchmarkProgress] = [],
        gate: StoreServiceGate? = nil
    ) {
        self.result = result
        self.updates = updates
        self.gate = gate
    }

    func run(
        profile: BenchmarkProfile,
        progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void
    ) async -> MacBenchmarkRawResult {
        callCount += 1
        for update in updates {
            await progress(update)
        }
        if let gate {
            await gate.pause()
        }
        return result
    }

    func calls() -> Int { callCount }
}

private struct NoopMacBenchmarkLifecycleCleaner: MacBenchmarkLifecycleCleaning {
    func cleanupOrphanedArtifactsOnLaunch() async {}
}

private actor ScriptedMacBenchmarkLifecycleCleaner:
    MacBenchmarkLifecycleCleaning
{
    private var callCount = 0

    func cleanupOrphanedArtifactsOnLaunch() async {
        callCount += 1
    }

    func calls() -> Int { callCount }
}

private actor StoreServiceGate {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor RecordingMacBenchmarkHistory: MacBenchmarkHistoryPersisting {
    private var results: [MacBenchmarkResult]
    private let saveShouldFail: Bool
    private let reportedLoadStatus: MacBenchmarkHistoryLoadStatus

    init(
        initial: [MacBenchmarkResult] = [],
        saveShouldFail: Bool = false,
        loadStatus: MacBenchmarkHistoryLoadStatus = .loaded
    ) {
        results = initial
        self.saveShouldFail = saveShouldFail
        reportedLoadStatus = loadStatus
    }

    func load() async -> [MacBenchmarkResult] { results }

    func loadStatus() async -> MacBenchmarkHistoryLoadStatus {
        reportedLoadStatus
    }

    func save(_ result: MacBenchmarkResult) async throws {
        if saveShouldFail {
            throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(EIO)
        }
        results.insert(result, at: 0)
    }

    func savedResults() -> [MacBenchmarkResult] { results }
}

private actor DelayedFirstLoadMacBenchmarkHistory: MacBenchmarkHistoryPersisting {
    private var results: [MacBenchmarkResult]
    private var didDelayFirstLoad = false
    private var firstLoadStarted = false
    private var firstLoadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?

    init(initial: [MacBenchmarkResult]) {
        results = initial
    }

    func load() async -> [MacBenchmarkResult] {
        guard !didDelayFirstLoad else { return results }
        didDelayFirstLoad = true
        let snapshot = results
        firstLoadStarted = true
        firstLoadStartWaiters.forEach { $0.resume() }
        firstLoadStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstLoadContinuation = continuation
        }
        return snapshot
    }

    func save(_ result: MacBenchmarkResult) async throws {
        results.insert(result, at: 0)
    }

    func waitUntilFirstLoadStarts() async {
        guard !firstLoadStarted else { return }
        await withCheckedContinuation { continuation in
            firstLoadStartWaiters.append(continuation)
        }
    }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }
}

private actor BlockingSaveMacBenchmarkHistory: MacBenchmarkHistoryPersisting {
    private var results: [MacBenchmarkResult] = []
    private var saveStarted = false
    private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveContinuation: CheckedContinuation<Void, Never>?

    func load() async -> [MacBenchmarkResult] { results }

    func save(_ result: MacBenchmarkResult) async throws {
        saveStarted = true
        saveStartWaiters.forEach { $0.resume() }
        saveStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
        results.insert(result, at: 0)
    }

    func waitUntilSaveStarts() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { continuation in
            saveStartWaiters.append(continuation)
        }
    }

    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    func savedResults() -> [MacBenchmarkResult] { results }
}

private actor ScriptedMacAcceleratorBenchmarkService:
    MacAcceleratorBenchmarkServicing
{
    private let result: MacAcceleratorBenchmarkResult
    private let updates: [MacAcceleratorBenchmarkProgress]
    private let gate: StoreServiceGate?
    private var callCount = 0

    init(
        result: MacAcceleratorBenchmarkResult,
        updates: [MacAcceleratorBenchmarkProgress] = [],
        gate: StoreServiceGate? = nil
    ) {
        self.result = result
        self.updates = updates
        self.gate = gate
    }

    func run(
        progress: @escaping @Sendable (MacAcceleratorBenchmarkProgress) async -> Void
    ) async -> MacAcceleratorBenchmarkResult {
        callCount += 1
        for update in updates {
            await progress(update)
        }
        if let gate {
            await gate.pause()
        }
        return result
    }

    func calls() -> Int { callCount }
}

private actor ScriptedMacSustainedBenchmarkService:
    MacSustainedBenchmarkServicing
{
    private var callCount = 0

    func run(
        profile: MacSustainedBenchmarkProfile,
        coolingMode: MacSustainedCoolingMode,
        progress: @escaping @Sendable (MacSustainedBenchmarkProgress) async -> Void
    ) async -> MacSustainedBenchmarkResult {
        callCount += 1
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let targetDuration = profile.targetDurationSeconds
        var windows: [MacSustainedBenchmarkWindow] = []
        for index in 0..<3 {
            let cpuSample = BenchmarkComponentSample(
                value: 100 - Double(index * 5),
                elapsedSeconds: 0.5,
                checksum: 101
            )
            let gpuSample = BenchmarkComponentSample(
                value: 200 - Double(index * 10),
                elapsedSeconds: 0.5,
                checksum: 202
            )
            windows.append(MacSustainedBenchmarkWindow(
                index: index,
                startedAtSeconds: Double(index),
                completedAtSeconds: Double(index) + 0.5,
                cpuMultiSample: cpuSample,
                gpuRasterSample: gpuSample
            ))
        }
        return MacSustainedBenchmarkResult(
            profile: profile,
            coolingMode: coolingMode,
            targetDurationSeconds: targetDuration,
            workloadDurationSeconds: targetDuration,
            totalObservationDurationSeconds: targetDuration,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(targetDuration + 2),
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: "Apple Test",
                activeProcessorCount: 10,
                physicalMemoryBytes: 16_000_000_000,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS Test",
                appVersion: "1.0",
                appBuild: "1"
            ),
            preflight: BenchmarkPreflight(
                capturedAt: startedAt.addingTimeInterval(1),
                powerSource: .acPower,
                batteryPercent: 80,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                diskReliability: .verified,
                availableDiskBytes: 100_000_000_000,
                requiredDiskBytes: 0,
                warnings: []
            ),
            windows: windows,
            telemetry: [
                MacSustainedTelemetrySample(
                    elapsedSeconds: 0,
                    thermalState: .nominal,
                    powerSource: .acPower,
                    lowPowerModeEnabled: false,
                    chipTemperatureCelsius: 50,
                    fans: .unsupported
                ),
                MacSustainedTelemetrySample(
                    elapsedSeconds: targetDuration,
                    thermalState: .nominal,
                    powerSource: .acPower,
                    lowPowerModeEnabled: false,
                    chipTemperatureCelsius: 70,
                    fans: .unsupported
                ),
            ],
            termination: .targetDurationReached,
            cooldownReachedNominal: nil,
            failure: nil
        )
    }

    func calls() -> Int { callCount }
}

private actor RecordingMacAcceleratorBenchmarkHistory:
    MacAcceleratorBenchmarkHistoryPersisting
{
    private var results: [MacAcceleratorBenchmarkResult] = []

    func load() async -> [MacAcceleratorBenchmarkResult] { results }

    func save(_ result: MacAcceleratorBenchmarkResult) async throws {
        results.insert(result, at: 0)
    }

    func savedResults() -> [MacAcceleratorBenchmarkResult] { results }
}

private actor BlockingSaveMacAcceleratorBenchmarkHistory:
    MacAcceleratorBenchmarkHistoryPersisting
{
    private var results: [MacAcceleratorBenchmarkResult] = []
    private var saveStarted = false
    private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveContinuation: CheckedContinuation<Void, Never>?

    func load() async -> [MacAcceleratorBenchmarkResult] { results }

    func save(_ result: MacAcceleratorBenchmarkResult) async throws {
        saveStarted = true
        saveStartWaiters.forEach { $0.resume() }
        saveStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
        results.insert(result, at: 0)
    }

    func waitUntilSaveStarts() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { continuation in
            saveStartWaiters.append(continuation)
        }
    }

    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    func savedResults() -> [MacAcceleratorBenchmarkResult] { results }
}
