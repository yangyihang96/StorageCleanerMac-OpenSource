import Foundation
import XCTest
@testable import StorageCleanerMac

final class MacAcceleratorBenchmarkServiceTests: XCTestCase {
    func testCompleteRunCollectsThreeSamplesForSixRawMetrics() async {
        let runner = ScriptedAcceleratorRunner()
        let preflight = AcceleratorPreflightSequence()
        let progress = AcceleratorProgressRecorder()
        let service = makeService(runner: runner, preflight: preflight)

        let result = await service.run { update in
            await progress.append(update)
        }

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.workloadVersion, "mac-accelerator-suite-v1")
        XCTAssertEqual(
            result.workloadFingerprint,
            MacAcceleratorBenchmarkResult.currentWorkloadFingerprint
        )
        XCTAssertEqual(result.measurements.map(\.metric), MacAcceleratorMetric.allCases)
        XCTAssertTrue(result.measurements.allSatisfy {
            $0.availability == .measured && $0.samples.count == 3
        })
        let counts = await runner.counts()
        XCTAssertEqual(counts.raster, 3)
        XCTAssertEqual(counts.rayTracing, 3)
        XCTAssertEqual(counts.tensor, 3)
        XCTAssertEqual(counts.media, 3)
        let captureCount = await preflight.captureCount()
        XCTAssertEqual(captureCount, 6)

        let updates = await progress.values()
        XCTAssertEqual(updates.last?.completedSampleCount, 18)
        XCTAssertEqual(updates.last?.totalSampleCount, 18)
        XCTAssertEqual(updates.last?.progress, 1)
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { lhs, rhs in
            rhs.completedSampleCount >= lhs.completedSampleCount
                && rhs.elapsedSeconds >= lhs.elapsedSeconds
        })
    }

    func testUnsupportedRayTracingAndTemporarilyUnavailableMediaStayStatuses() async {
        let runner = ScriptedAcceleratorRunner(
            rayTracingOutcome: .unsupported,
            mediaOutcome: .temporarilyUnavailable
        )
        let service = makeService(
            runner: runner,
            preflight: AcceleratorPreflightSequence()
        )

        let result = await service.run()

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.failure)
        XCTAssertFalse(result.isFullyMeasured)
        XCTAssertEqual(
            result.measurementsByMetric[.rayTracingBuild]?.availability,
            .unsupported
        )
        XCTAssertEqual(
            result.measurementsByMetric[.rayTracingTraversal]?.samples,
            []
        )
        XCTAssertEqual(
            result.measurementsByMetric[.mediaH264Encode]?.availability,
            .temporarilyUnavailable
        )
        XCTAssertEqual(
            result.measurementsByMetric[.mediaH264Decode]?.samples,
            []
        )
        let counts = await runner.counts()
        XCTAssertEqual(counts.rayTracing, 1)
        XCTAssertEqual(counts.media, 1)
    }

    func testSafetyGateRunsBeforeAnyKernel() async {
        let runner = ScriptedAcceleratorRunner()
        let preflight = AcceleratorPreflightSequence(thermalState: .serious)
        let service = makeService(runner: runner, preflight: preflight)

        let result = await service.run()

        XCTAssertEqual(result.failure, .safetyCheck(.thermalNotNominal))
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.measurements.isEmpty)
        let counts = await runner.counts()
        XCTAssertEqual(counts, .zero)
    }

    func testMismatchedDeterministicDigestFailsClosed() async {
        let runner = ScriptedAcceleratorRunner(mismatchRasterChecksum: true)
        let service = makeService(
            runner: runner,
            preflight: AcceleratorPreflightSequence()
        )

        let result = await service.run()

        XCTAssertEqual(result.failure, .validationFailed(.metalRaster3D))
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.measurements.isEmpty)
    }

    func testPairValidationAttributesFirstMetricFailureCorrectly() async {
        let runner = ScriptedAcceleratorRunner(mismatchRayBuildChecksum: true)
        let service = makeService(
            runner: runner,
            preflight: AcceleratorPreflightSequence()
        )

        let result = await service.run()

        XCTAssertEqual(result.failure, .validationFailed(.rayTracingBuild))
        XCTAssertFalse(result.isComplete)
    }

    func testWorkloadTimeoutPreservesMetricIdentity() async {
        let runner = ScriptedAcceleratorRunner(
            tensorError: .timedOut(.gpuTensorFP16)
        )
        let service = makeService(
            runner: runner,
            preflight: AcceleratorPreflightSequence()
        )

        let result = await service.run()

        XCTAssertEqual(result.failure, .timedOut(.gpuTensorFP16))
        XCTAssertFalse(result.isComplete)
    }

    func testSharedHeavyWorkLeasePreventsConcurrentSystemWork() async throws {
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .cleanup)
        let service = makeService(
            coordinator: coordinator,
            runner: ScriptedAcceleratorRunner(),
            preflight: AcceleratorPreflightSequence()
        )

        let result = await service.run()
        await coordinator.release(lease)

        XCTAssertEqual(result.failure, .busy(activeTask: "cleanup"))
        XCTAssertFalse(result.isComplete)
    }

    func testCancellationStopsRunAndReleasesLease() async {
        let coordinator = HeavyWorkCoordinator()
        let runner = ScriptedAcceleratorRunner(blockRasterUntilCancellation: true)
        let service = makeService(
            coordinator: coordinator,
            runner: runner,
            preflight: AcceleratorPreflightSequence()
        )
        let task = Task { await service.run() }
        await runner.waitUntilRasterStarted()

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.failure, .cancelled)
        let activeOwner = await coordinator.activeOwner
        XCTAssertNil(activeOwner)
    }
}

private extension MacAcceleratorBenchmarkServiceTests {
    func makeService(
        coordinator: HeavyWorkCoordinator = HeavyWorkCoordinator(),
        runner: ScriptedAcceleratorRunner,
        preflight: AcceleratorPreflightSequence
    ) -> MacAcceleratorBenchmarkService {
        MacAcceleratorBenchmarkService(
            heavyWorkCoordinator: coordinator,
            preflightService: preflight,
            workloadRunner: runner,
            environmentProvider: AcceleratorEnvironmentProvider(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            monotonicNow: AcceleratorMonotonicClock.shared.now
        )
    }
}

private struct AcceleratorEnvironmentProvider: MacBenchmarkEnvironmentProviding {
    func metadata(preflight: BenchmarkPreflight) -> BenchmarkEnvironmentMetadata {
        BenchmarkEnvironmentMetadata(
            architecture: .arm64,
            chipName: "Apple Test",
            activeProcessorCount: 10,
            physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
            powerSource: preflight.powerSource,
            thermalState: preflight.thermalState,
            operatingSystemVersion: "macOS Test",
            appVersion: "1.0",
            appBuild: "1"
        )
    }
}

private final class AcceleratorMonotonicClock: @unchecked Sendable {
    static let shared = AcceleratorMonotonicClock()
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 {
        lock.withLock {
            value += 1_000_000
            return value
        }
    }
}

private actor AcceleratorPreflightSequence: MacBenchmarkPreflighting {
    private var captures = 0
    private let thermalState: BenchmarkThermalState

    init(thermalState: BenchmarkThermalState = .nominal) {
        self.thermalState = thermalState
    }

    func capture(requiredDiskBytes: Int64) -> BenchmarkPreflight {
        captures += 1
        let draft = BenchmarkPreflight(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(captures)),
            powerSource: .acPower,
            batteryPercent: 100,
            lowPowerModeEnabled: false,
            thermalState: thermalState,
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

    func captureCount() -> Int { captures }
}

private actor AcceleratorProgressRecorder {
    private var updates: [MacAcceleratorBenchmarkProgress] = []

    func append(_ update: MacAcceleratorBenchmarkProgress) {
        updates.append(update)
    }

    func values() -> [MacAcceleratorBenchmarkProgress] { updates }
}

private struct AcceleratorCallCounts: Equatable, Sendable {
    let raster: Int
    let rayTracing: Int
    let tensor: Int
    let media: Int

    static let zero = Self(raster: 0, rayTracing: 0, tensor: 0, media: 0)
}

private actor ScriptedAcceleratorRunner: MacAcceleratorWorkloadRunning {
    private let rayTracingOutcome:
        MacAcceleratorWorkloadOutcome<MacAcceleratorRayTracingSamplePair>
    private let mediaOutcome:
        MacAcceleratorWorkloadOutcome<MacAcceleratorMediaSamplePair>
    private let mismatchRasterChecksum: Bool
    private let mismatchRayBuildChecksum: Bool
    private let tensorError: MacAcceleratorWorkloadError?
    private let blockRasterUntilCancellation: Bool
    private var rasterCount = 0
    private var rayTracingCount = 0
    private var tensorCount = 0
    private var mediaCount = 0
    private var rasterStarted = false

    init(
        rayTracingOutcome:
            MacAcceleratorWorkloadOutcome<MacAcceleratorRayTracingSamplePair>? = nil,
        mediaOutcome:
            MacAcceleratorWorkloadOutcome<MacAcceleratorMediaSamplePair>? = nil,
        mismatchRasterChecksum: Bool = false,
        mismatchRayBuildChecksum: Bool = false,
        tensorError: MacAcceleratorWorkloadError? = nil,
        blockRasterUntilCancellation: Bool = false
    ) {
        self.rayTracingOutcome = rayTracingOutcome ?? .measured(
            MacAcceleratorRayTracingSamplePair(
                build: Self.sample(value: 200, checksum: 2),
                traversal: Self.sample(value: 300, checksum: 3)
            )
        )
        self.mediaOutcome = mediaOutcome ?? .measured(
            MacAcceleratorMediaSamplePair(
                encode: Self.sample(value: 500, checksum: 5),
                decode: Self.sample(value: 600, checksum: 6)
            )
        )
        self.mismatchRasterChecksum = mismatchRasterChecksum
        self.mismatchRayBuildChecksum = mismatchRayBuildChecksum
        self.tensorError = tensorError
        self.blockRasterUntilCancellation = blockRasterUntilCancellation
    }

    func runMetalRaster3D() async throws -> BenchmarkComponentSample {
        rasterCount += 1
        rasterStarted = true
        if blockRasterUntilCancellation {
            try await Task.sleep(for: .seconds(60))
        }
        return Self.sample(
            value: 100 + Double(rasterCount),
            checksum: mismatchRasterChecksum ? UInt64(rasterCount) : 1
        )
    }

    func runRayTracing() -> MacAcceleratorWorkloadOutcome<MacAcceleratorRayTracingSamplePair> {
        rayTracingCount += 1
        if mismatchRayBuildChecksum {
            return .measured(
                MacAcceleratorRayTracingSamplePair(
                    build: Self.sample(
                        value: 200,
                        checksum: UInt64(rayTracingCount)
                    ),
                    traversal: Self.sample(value: 300, checksum: 3)
                )
            )
        }
        return rayTracingOutcome
    }

    func runGPUTensor() throws -> MacAcceleratorWorkloadOutcome<BenchmarkComponentSample> {
        tensorCount += 1
        if let tensorError { throw tensorError }
        return .measured(Self.sample(value: 400 + Double(tensorCount), checksum: 4))
    }

    func runH264Media() -> MacAcceleratorWorkloadOutcome<MacAcceleratorMediaSamplePair> {
        mediaCount += 1
        return mediaOutcome
    }

    func counts() -> AcceleratorCallCounts {
        AcceleratorCallCounts(
            raster: rasterCount,
            rayTracing: rayTracingCount,
            tensor: tensorCount,
            media: mediaCount
        )
    }

    func waitUntilRasterStarted() async {
        while !rasterStarted {
            await Task.yield()
        }
    }

    private static func sample(value: Double, checksum: UInt64) -> BenchmarkComponentSample {
        BenchmarkComponentSample(
            value: value,
            elapsedSeconds: 0.25,
            checksum: checksum
        )
    }
}
