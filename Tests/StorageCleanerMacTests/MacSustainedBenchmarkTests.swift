import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacSustainedBenchmarkTests: XCTestCase {
    func testWorkloadFingerprintIsFrozenToCanonicalManifest() {
        XCTAssertEqual(
            MacBenchmarkBaselineVerification.sha256Hex(
                Data(MacSustainedBenchmarkResult.workloadManifest.utf8)
            ),
            MacSustainedBenchmarkResult.currentWorkloadFingerprint
        )
    }

    func testSerialRunReportsPeakSustainedAndRetentionWithoutCompositeScore() async throws {
        let clock = SustainedMonotonicClock(stepNanoseconds: 1_000_000_000)
        let runner = SustainedScriptedRunner(
            clock: clock,
            cpuValues: [100, 90, 80],
            gpuValues: [200, 180, 150]
        )
        let service = makeService(
            clock: clock,
            runner: runner,
            telemetry: SustainedTelemetryProbe(states: [.nominal])
        )

        let result = await service.run(profile: .standard)

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.termination, .targetDurationReached)
        XCTAssertEqual(result.windows.count, 3)
        let cpuSummary = try XCTUnwrap(result.cpuSummary)
        let gpuSummary = try XCTUnwrap(result.gpuSummary)
        XCTAssertEqual(cpuSummary.peakValue, 100)
        XCTAssertEqual(cpuSummary.sustainedMedianValue, 80)
        XCTAssertEqual(cpuSummary.retentionRatio, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(gpuSummary.peakValue, 200)
        XCTAssertEqual(gpuSummary.retentionRatio, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(
            result.workloadFingerprint,
            MacSustainedBenchmarkResult.currentWorkloadFingerprint
        )
    }

    func testSystemRunnerStartsGPUOnlyAfterCPUCompletes() async throws {
        let recorder = SustainedExecutionRecorder()
        let runner = SystemMacSustainedBenchmarkWorkloadRunner(
            cpuOperation: {
                _ in
                await recorder.append(.cpuStarted)
                await recorder.append(.cpuCompleted)
                return BenchmarkComponentSample(
                    value: 100,
                    elapsedSeconds: 0.5,
                    checksum: 101
                )
            },
            gpuOperation: {
                await recorder.append(.gpuStarted)
                return BenchmarkComponentSample(
                    value: 200,
                    elapsedSeconds: 0.5,
                    checksum: 202
                )
            }
        )

        _ = try await runner.runSerialRound(activeProcessorCount: 10)
        let events = await recorder.events()

        XCTAssertEqual(
            events,
            [.cpuStarted, .cpuCompleted, .gpuStarted]
        )
    }

    func testLegacyMixedProtocolIsExplicitlyMarkedLegacy() {
        XCTAssertTrue(
            MacSustainedBenchmarkResult.isLegacyWorkload(
                version: MacSustainedBenchmarkResult.legacyMixedProtocolVersion,
                fingerprint: MacSustainedBenchmarkResult.legacyMixedWorkloadFingerprint
            )
        )
        XCTAssertFalse(
            MacSustainedBenchmarkResult.isLegacyWorkload(
                version: MacSustainedBenchmarkResult.protocolVersion,
                fingerprint: MacSustainedBenchmarkResult.currentWorkloadFingerprint
            )
        )
    }

    func testFairThermalStateIsRecordedButDoesNotFabricateAStop() async {
        let clock = SustainedMonotonicClock(stepNanoseconds: 1_000_000_000)
        let service = makeService(
            clock: clock,
            runner: SustainedScriptedRunner(clock: clock),
            telemetry: SustainedTelemetryProbe(states: [.nominal, .fair, .fair])
        )

        let result = await service.run(profile: .standard)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.termination, .targetDurationReached)
        XCTAssertNotNil(result.firstThermalChangeSeconds)
        XCTAssertTrue(result.telemetry.contains { $0.thermalState == .fair })
    }

    func testSeriousThermalStateCancelsLoadAndObservesCooldown() async {
        let clock = SustainedMonotonicClock(stepNanoseconds: 1_000_000_000)
        let runner = SustainedScriptedRunner(clock: clock, blocksUntilCancelled: true)
        let service = makeService(
            clock: clock,
            runner: runner,
            telemetry: SustainedTelemetryProbe(
                states: [.nominal, .serious, .nominal]
            ),
            sleep: { _ in await Task.yield() }
        )

        let result = await service.run(profile: .standard)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.termination, .thermalSafety(.serious))
        XCTAssertEqual(result.cooldownReachedNominal, true)
        XCTAssertTrue(result.windows.isEmpty)
        let wasCancelled = await runner.wasCancelled()
        XCTAssertTrue(wasCancelled)
    }

    func testUnknownThermalStateFailsSafeAndObservesCooldown() async {
        let clock = SustainedMonotonicClock(stepNanoseconds: 1_000_000_000)
        let runner = SustainedScriptedRunner(clock: clock, blocksUntilCancelled: true)
        let service = makeService(
            clock: clock,
            runner: runner,
            telemetry: SustainedTelemetryProbe(
                states: [.nominal, .unknown, .nominal]
            ),
            sleep: { _ in await Task.yield() }
        )

        let result = await service.run(profile: .standard)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.termination, .thermalSafety(.unknown))
        XCTAssertEqual(result.cooldownReachedNominal, true)
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testLowPowerModeChangeStopsAsRawResult() async {
        let clock = SustainedMonotonicClock(stepNanoseconds: 1_000_000_000)
        let service = makeService(
            clock: clock,
            runner: SustainedScriptedRunner(clock: clock),
            telemetry: SustainedTelemetryProbe(
                states: [.nominal],
                lowPowerModes: [false, true]
            )
        )

        let result = await service.run(profile: .standard)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.termination, .lowPowerModeEnabled)
        XCTAssertNil(result.cpuSummary)
        XCTAssertNil(result.gpuSummary)
    }

    func testPowerDisconnectStopsAsRawResultInsteadOfLowScore() async {
        let clock = SustainedMonotonicClock(stepNanoseconds: 1_000_000_000)
        let service = makeService(
            clock: clock,
            runner: SustainedScriptedRunner(clock: clock),
            telemetry: SustainedTelemetryProbe(
                states: [.nominal],
                powerSources: [.acPower, .battery]
            )
        )

        let result = await service.run(profile: .standard)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.termination, .powerSourceChanged(.battery))
        XCTAssertNil(result.cpuSummary)
        XCTAssertNil(result.gpuSummary)
    }

    func testFanlessAndMissingTemperatureRemainUnsupportedTelemetry() async {
        let clock = SustainedMonotonicClock(stepNanoseconds: 1_000_000_000)
        let service = makeService(
            clock: clock,
            runner: SustainedScriptedRunner(clock: clock),
            telemetry: SustainedTelemetryProbe(
                states: [.nominal],
                temperature: nil,
                fans: .unsupported
            )
        )

        let result = await service.run(profile: .standard)

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.maximumChipTemperatureCelsius)
        XCTAssertNil(result.maximumFanSpeedRPM)
        XCTAssertTrue(result.telemetry.allSatisfy { $0.fans == .unsupported })
    }

    func testSharedHeavyWorkLeaseRejectsConcurrentRun() async throws {
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .cleanup)
        let clock = SustainedMonotonicClock(stepNanoseconds: 1_000_000_000)
        let service = makeService(
            coordinator: coordinator,
            clock: clock,
            runner: SustainedScriptedRunner(clock: clock),
            telemetry: SustainedTelemetryProbe(states: [.nominal])
        )

        let result = await service.run(profile: .standard)
        await coordinator.release(lease)

        XCTAssertEqual(result.failure, .busy(activeTask: "cleanup"))
        XCTAssertFalse(result.isComplete)
    }

    func testCallerCancellationReleasesHeavyWorkLease() async {
        let coordinator = HeavyWorkCoordinator()
        let clock = SustainedMonotonicClock(stepNanoseconds: 100_000_000)
        let runner = SustainedScriptedRunner(clock: clock, blocksUntilCancelled: true)
        let service = makeService(
            coordinator: coordinator,
            clock: clock,
            runner: runner,
            telemetry: SustainedTelemetryProbe(states: [.nominal]),
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        let task = Task { await service.run(profile: .standard) }
        await runner.waitUntilStarted()

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.failure, .cancelled)
        let activeOwner = await coordinator.activeOwner
        XCTAssertNil(activeOwner)
    }
}

private extension MacSustainedBenchmarkTests {
    func makeService(
        coordinator: HeavyWorkCoordinator = HeavyWorkCoordinator(),
        clock: SustainedMonotonicClock,
        runner: SustainedScriptedRunner,
        telemetry: SustainedTelemetryProbe,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
            try await Task.sleep(for: .seconds(3_600))
        }
    ) -> MacSustainedBenchmarkService {
        MacSustainedBenchmarkService(
            heavyWorkCoordinator: coordinator,
            preflightService: SustainedPreflightService(),
            workloadRunner: runner,
            telemetryProbe: telemetry,
            environmentProvider: SustainedEnvironmentProvider(),
            configurationProvider: { _ in
                MacSustainedBenchmarkConfiguration(
                    targetDurationSeconds: 6,
                    telemetryIntervalSeconds: 1,
                    cooldownTimeoutSeconds: 4,
                    maximumWindowCount: 20
                )
            },
            now: { Date(timeIntervalSince1970: 1_700_000_010) },
            monotonicNow: clock.now,
            sleep: sleep
        )
    }
}

private final class SustainedMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private let stepNanoseconds: UInt64
    private var value: UInt64 = 0

    init(stepNanoseconds: UInt64) {
        self.stepNanoseconds = stepNanoseconds
    }

    func now() -> UInt64 {
        lock.withLock {
            value += stepNanoseconds
            return value
        }
    }
}

private actor SustainedScriptedRunner: MacSustainedWorkloadRunning {
    private let clock: SustainedMonotonicClock
    private let cpuValues: [Double]
    private let gpuValues: [Double]
    private let blocksUntilCancelled: Bool
    private var count = 0
    private var started = false
    private var cancelled = false

    init(
        clock: SustainedMonotonicClock,
        cpuValues: [Double] = [100, 95, 90, 85],
        gpuValues: [Double] = [200, 190, 180, 170],
        blocksUntilCancelled: Bool = false
    ) {
        self.clock = clock
        self.cpuValues = cpuValues
        self.gpuValues = gpuValues
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    func runSerialRound(activeProcessorCount: Int) async throws
        -> MacSustainedWorkloadSample
    {
        started = true
        if blocksUntilCancelled {
            do {
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch {
                cancelled = true
                throw CancellationError()
            }
        }
        let index = min(count, min(cpuValues.count, gpuValues.count) - 1)
        count += 1
        _ = clock
        return MacSustainedWorkloadSample(
            cpuMultiSample: BenchmarkComponentSample(
                value: cpuValues[index],
                elapsedSeconds: 0.5,
                checksum: 101
            ),
            gpuRasterSample: BenchmarkComponentSample(
                value: gpuValues[index],
                elapsedSeconds: 0.5,
                checksum: 202
            )
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func wasCancelled() -> Bool { cancelled }
}

private actor SustainedExecutionRecorder {
    enum Event: Equatable, Sendable {
        case cpuStarted
        case cpuCompleted
        case gpuStarted
    }

    private var values: [Event] = []

    func append(_ event: Event) {
        values.append(event)
    }

    func events() -> [Event] { values }
}

private actor SustainedTelemetryProbe: MacSustainedTelemetryProbing {
    private let states: [BenchmarkThermalState]
    private let powerSources: [BenchmarkPowerSource]
    private let lowPowerModes: [Bool]
    private let temperature: Double?
    private let fans: MacSustainedFanReading
    private var count = 0

    init(
        states: [BenchmarkThermalState],
        powerSources: [BenchmarkPowerSource] = [.acPower],
        lowPowerModes: [Bool] = [false],
        temperature: Double? = 55,
        fans: MacSustainedFanReading = .measured([2_000])
    ) {
        self.states = states
        self.powerSources = powerSources
        self.lowPowerModes = lowPowerModes
        self.temperature = temperature
        self.fans = fans
    }

    func capture(elapsedSeconds: Double) -> MacSustainedTelemetrySample {
        let index = count
        count += 1
        return MacSustainedTelemetrySample(
            elapsedSeconds: elapsedSeconds,
            thermalState: states[min(index, states.count - 1)],
            powerSource: powerSources[min(index, powerSources.count - 1)],
            lowPowerModeEnabled: lowPowerModes[min(index, lowPowerModes.count - 1)],
            chipTemperatureCelsius: temperature,
            fans: fans
        )
    }
}

private struct SustainedPreflightService: MacBenchmarkPreflighting {
    func capture(requiredDiskBytes: Int64) -> BenchmarkPreflight {
        let draft = BenchmarkPreflight(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_011),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 100_000_000_000,
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
            warnings: MacBenchmarkPreflightPolicy.warnings(for: draft)
        )
    }
}

private struct SustainedEnvironmentProvider: MacBenchmarkEnvironmentProviding {
    func metadata(preflight: BenchmarkPreflight) -> BenchmarkEnvironmentMetadata {
        BenchmarkEnvironmentMetadata(
            architecture: .arm64,
            chipName: "Apple Test",
            activeProcessorCount: 10,
            physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
            powerSource: preflight.powerSource,
            thermalState: preflight.thermalState,
            operatingSystemVersion: "macOS Test",
            appVersion: "1.8.2",
            appBuild: "182"
        )
    }
}
