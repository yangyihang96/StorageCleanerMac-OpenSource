import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MacSustainedBenchmarkStoreTests: XCTestCase {
    func testStoreRunsOnlyFixedStandardProfileAndKeepsResultRawOnly() async throws {
        let result = makeResult()
        let service = ScriptedSustainedBenchmarkService(result: result)
        let completionCounter = SustainedCoreCompletionCounter()
        let store = try makeStore(
            sustainedService: service,
            onCoreCompleted: { _, _ in completionCounter.count += 1 }
        )

        store.startSustainedBenchmark()
        await store.waitUntilIdle()

        XCTAssertEqual(store.sustainedState, .completed)
        XCTAssertEqual(store.latestSustainedResult, result)
        let requestedProfiles = await service.requestedProfiles()
        let requestedCoolingModes = await service.requestedCoolingModes()
        XCTAssertEqual(requestedProfiles, [.standard])
        XCTAssertEqual(requestedCoolingModes, [.systemAutomatic])
        XCTAssertEqual(completionCounter.count, 0)
    }

    func testSustainedRunBlocksOtherBenchmarkStartsUntilItFinishes() async throws {
        let service = ScriptedSustainedBenchmarkService(
            result: makeResult(),
            blocksUntilCancelled: true
        )
        let store = try makeStore(sustainedService: service)

        store.startSustainedBenchmark()
        await service.waitUntilStarted()
        store.start()
        store.startAcceleratorBenchmark()

        XCTAssertTrue(store.isRunning)
        XCTAssertTrue(store.isSustainedBenchmarkRunning)
        XCTAssertEqual(store.state, .idle)
        XCTAssertEqual(store.acceleratorState, .idle)

        store.cancelAll()
        await store.waitUntilIdle()
        XCTAssertEqual(store.sustainedState, .cancelled)
        XCTAssertFalse(store.isRunning)
    }

    func testProgressTransitionsToCoolingDownWithoutPublishingPartialResult() async throws {
        let result = makeResult(
            termination: .thermalSafety(.serious),
            cooldownReachedNominal: true,
            windows: []
        )
        let progress = MacSustainedBenchmarkProgress(
            stage: .coolingDown,
            completedWindowCount: 0,
            elapsedSeconds: 3,
            targetDurationSeconds: 6,
            thermalState: .serious,
            currentFanSpeedRPM: 4_000
        )
        let service = ScriptedSustainedBenchmarkService(
            result: result,
            progressUpdates: [progress],
            pauseAfterProgress: true
        )
        let store = try makeStore(sustainedService: service)

        store.startSustainedBenchmark()
        await service.waitUntilProgressPauses()

        XCTAssertEqual(store.sustainedState, .coolingDown)
        XCTAssertNil(store.latestSustainedResult)

        await service.resumeAfterProgress()
        await store.waitUntilIdle()
        XCTAssertEqual(store.sustainedState, .completed)
        XCTAssertEqual(store.latestSustainedResult, result)
    }
}

private extension MacSustainedBenchmarkStoreTests {
    func makeStore(
        sustainedService: any MacSustainedBenchmarkServicing,
        onCoreCompleted: ((MacBenchmarkResult, [MacBenchmarkResult]) -> Void)? = nil
    ) throws -> MacBenchmarkStore {
        let catalog = try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: "test-v1",
            verifiedBaselines: []
        )
        return MacBenchmarkStore(
            service: UnusedCoreBenchmarkService(),
            resultProcessor: MacBenchmarkResultProcessor(
                baselineCatalog: catalog
            ),
            sustainedService: sustainedService,
            onCompletedResult: onCoreCompleted
        )
    }

    func makeResult(
        termination: MacSustainedBenchmarkTermination = .targetDurationReached,
        cooldownReachedNominal: Bool? = nil,
        windows: [MacSustainedBenchmarkWindow]? = nil
    ) -> MacSustainedBenchmarkResult {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let preflight = BenchmarkPreflight(
            capturedAt: startedAt.addingTimeInterval(1),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 100_000_000_000,
            requiredDiskBytes: MacSustainedBenchmarkService.requiredDiskBytes,
            warnings: []
        )
        let resolvedWindows: [MacSustainedBenchmarkWindow]
        if let windows {
            resolvedWindows = windows
        } else {
            var generated: [MacSustainedBenchmarkWindow] = []
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
                generated.append(
                    MacSustainedBenchmarkWindow(
                        index: index,
                        startedAtSeconds: Double(index * 2),
                        completedAtSeconds: Double(index * 2 + 1),
                        cpuMultiSample: cpuSample,
                        gpuRasterSample: gpuSample
                    )
                )
            }
            resolvedWindows = generated
        }
        let finalThermalState: BenchmarkThermalState = switch termination {
        case let .thermalSafety(state): state
        case .targetDurationReached, .powerSourceChanged, .lowPowerModeEnabled: .nominal
        }
        return MacSustainedBenchmarkResult(
            profile: .standard,
            coolingMode: .systemAutomatic,
            targetDurationSeconds: 6,
            workloadDurationSeconds: 6,
            totalObservationDurationSeconds:
                cooldownReachedNominal == nil ? 6 : 7,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(8),
            environment: BenchmarkEnvironmentMetadata(
                architecture: .arm64,
                chipName: "Apple Test",
                activeProcessorCount: 10,
                physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
                powerSource: .acPower,
                thermalState: .nominal,
                operatingSystemVersion: "macOS Test",
                appVersion: "1.8.2",
                appBuild: "182"
            ),
            preflight: preflight,
            windows: resolvedWindows,
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
                    elapsedSeconds: 6,
                    thermalState: finalThermalState,
                    powerSource: .acPower,
                    lowPowerModeEnabled: false,
                    chipTemperatureCelsius: 80,
                    fans: .measured([4_000])
                ),
            ],
            termination: termination,
            cooldownReachedNominal: cooldownReachedNominal,
            failure: nil
        )
    }
}

private struct UnusedCoreBenchmarkService: MacBenchmarkServicing {
    func run(
        profile: BenchmarkProfile,
        progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void
    ) async -> MacBenchmarkRawResult {
        fatalError("Core benchmark must not start during sustained-store tests")
    }
}

@MainActor
private final class SustainedCoreCompletionCounter {
    var count = 0
}

private actor ScriptedSustainedBenchmarkService: MacSustainedBenchmarkServicing {
    private let result: MacSustainedBenchmarkResult
    private let blocksUntilCancelled: Bool
    private let progressUpdates: [MacSustainedBenchmarkProgress]
    private let pauseAfterProgress: Bool
    private var profiles: [MacSustainedBenchmarkProfile] = []
    private var coolingModes: [MacSustainedCoolingMode] = []
    private var started = false
    private var progressPaused = false
    private var shouldResume = false

    init(
        result: MacSustainedBenchmarkResult,
        blocksUntilCancelled: Bool = false,
        progressUpdates: [MacSustainedBenchmarkProgress] = [],
        pauseAfterProgress: Bool = false
    ) {
        self.result = result
        self.blocksUntilCancelled = blocksUntilCancelled
        self.progressUpdates = progressUpdates
        self.pauseAfterProgress = pauseAfterProgress
    }

    func run(
        profile: MacSustainedBenchmarkProfile,
        coolingMode: MacSustainedCoolingMode,
        progress: @escaping @Sendable (MacSustainedBenchmarkProgress) async -> Void
    ) async -> MacSustainedBenchmarkResult {
        profiles.append(profile)
        coolingModes.append(coolingMode)
        started = true
        for update in progressUpdates {
            await progress(update)
        }
        if pauseAfterProgress {
            progressPaused = true
            while !shouldResume, !Task.isCancelled { await Task.yield() }
        }
        if blocksUntilCancelled {
            while !Task.isCancelled { await Task.yield() }
        }
        return result
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func waitUntilProgressPauses() async {
        while !progressPaused { await Task.yield() }
    }

    func resumeAfterProgress() {
        shouldResume = true
    }

    func requestedProfiles() -> [MacSustainedBenchmarkProfile] { profiles }
    func requestedCoolingModes() -> [MacSustainedCoolingMode] { coolingModes }
}
