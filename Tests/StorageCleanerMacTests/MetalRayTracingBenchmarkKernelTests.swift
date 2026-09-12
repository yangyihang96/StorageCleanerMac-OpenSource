import Foundation
import XCTest
@testable import StorageCleanerMac

final class MetalRayTracingBenchmarkKernelTests: XCTestCase {
    func testUsesSeparateGPUBuildAndTraversalTimesAndAlwaysTearsDown() async throws {
        let recorder = RayTracingEventRecorder()
        let driver = FakeRayTracingDriver(
            recorder: recorder,
            buildElapsedSeconds: 0.25,
            traversalElapsedSeconds: 0.5
        )
        let kernel = MetalRayTracingBenchmarkKernel(
            configuration: .testing,
            driverFactory: { driver }
        )

        let result = try await kernel.run()

        XCTAssertEqual(result.buildSample.elapsedSeconds, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(result.traversalSample.elapsedSeconds, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.buildSample.value, 0.032_768, accuracy: 0.000_001)
        XCTAssertEqual(result.traversalSample.value, 0.016_384, accuracy: 0.000_001)
        XCTAssertEqual(result.buildSample.checksum, FakeRayTracingDriver.buildChecksum)
        XCTAssertEqual(
            result.traversalSample.checksum,
            FakeRayTracingDriver.traversalChecksum
        )
        XCTAssertEqual(result.hardwareFamily, .apple9)
        XCTAssertEqual(result.triangleCount, 8_192)
        XCTAssertEqual(result.rayCount, 4_096)
        XCTAssertEqual(result.traversalPassCount, 2)
        XCTAssertEqual(result.hitCount, 1_024)
        XCTAssertFalse(result.ranOnMainThread)
        let events = await recorder.snapshot()
        XCTAssertEqual(
            events,
            [.prepare, .warmUp, .build, .traversal, .validate, .tearDown]
        )
    }

    func testPreparationWarmupAndValidationAreExcludedFromSamples() async throws {
        let clock = RayTracingManualClock()
        let recorder = RayTracingEventRecorder()
        let driver = FakeRayTracingDriver(
            recorder: recorder,
            clock: clock,
            prepareNanoseconds: 800_000_000,
            warmupNanoseconds: 900_000_000,
            buildNanoseconds: 300_000_000,
            traversalNanoseconds: 400_000_000,
            validationNanoseconds: 700_000_000,
            buildElapsedSeconds: 0.2,
            traversalElapsedSeconds: 0.4
        )
        let kernel = MetalRayTracingBenchmarkKernel(
            configuration: .testing,
            clock: clock,
            driverFactory: { driver }
        )

        let result = try await kernel.run()

        XCTAssertEqual(result.buildSample.elapsedSeconds, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(result.traversalSample.elapsedSeconds, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(result.buildSample.value, 0.040_96, accuracy: 0.000_001)
        XCTAssertEqual(result.traversalSample.value, 0.020_48, accuracy: 0.000_001)
    }

    func testRejectsNonSquareOrUnboundedConfigurationsBeforePreparingDriver() async {
        let recorder = RayTracingEventRecorder()
        let driver = FakeRayTracingDriver(recorder: recorder)
        let invalidLimits = [
            MetalRayTracingBenchmarkKernel.Limits(
                triangleCount: 126,
                rayCount: 4_096,
                traversalPassCount: 1,
                maximumElapsedSeconds: 3
            ),
            MetalRayTracingBenchmarkKernel.Limits(
                triangleCount: 8_192,
                rayCount: 4_095,
                traversalPassCount: 1,
                maximumElapsedSeconds: 3
            ),
            MetalRayTracingBenchmarkKernel.Limits(
                triangleCount: 8_192,
                rayCount: 4_096,
                traversalPassCount:
                    MetalRayTracingBenchmarkKernel.maximumTraversalPassCount + 1,
                maximumElapsedSeconds: 3
            ),
        ]

        for limits in invalidLimits {
            let kernel = MetalRayTracingBenchmarkKernel(
                configuration: .init(limits: limits),
                driverFactory: { driver }
            )
            do {
                _ = try await kernel.run()
                XCTFail("Expected a resource-limit failure")
            } catch {
                XCTAssertEqual(error as? BenchmarkKernelError, .resourceLimit)
            }
        }
        let events = await recorder.snapshot()
        XCTAssertTrue(events.isEmpty)
    }

    func testBuildFailurePublishesNoSamplesAndTearsDown() async {
        let recorder = RayTracingEventRecorder()
        let driver = FakeRayTracingDriver(
            recorder: recorder,
            buildError: BenchmarkKernelError.systemFailure
        )
        let kernel = MetalRayTracingBenchmarkKernel(
            configuration: .testing,
            driverFactory: { driver }
        )

        do {
            _ = try await kernel.run()
            XCTFail("Expected a build failure")
        } catch {
            XCTAssertEqual(error as? BenchmarkKernelError, .systemFailure)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events, [.prepare, .warmUp, .build, .tearDown])
    }

    func testValidationMismatchFailsClosedAndTearsDown() async {
        let recorder = RayTracingEventRecorder()
        let driver = FakeRayTracingDriver(
            recorder: recorder,
            validationError: BenchmarkKernelError.checksumMismatch
        )
        let kernel = MetalRayTracingBenchmarkKernel(
            configuration: .testing,
            driverFactory: { driver }
        )

        do {
            _ = try await kernel.run()
            XCTFail("Expected a validation failure")
        } catch {
            XCTAssertEqual(error as? BenchmarkKernelError, .checksumMismatch)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testCancellationWaitsForTraversalCleanup() async {
        let recorder = RayTracingEventRecorder()
        let driver = FakeRayTracingDriver(
            recorder: recorder,
            waitsForTraversalCancellation: true
        )
        let kernel = MetalRayTracingBenchmarkKernel(
            configuration: .testing,
            driverFactory: { driver }
        )
        let task = Task { try await kernel.run() }

        await recorder.wait(until: .traversal)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testWholeRunSafetyLimitFailsAfterCleanup() async {
        let clock = RayTracingManualClock()
        let recorder = RayTracingEventRecorder()
        let driver = FakeRayTracingDriver(
            recorder: recorder,
            clock: clock,
            buildNanoseconds: 4_000_000_000
        )
        let limits = MetalRayTracingBenchmarkKernel.Limits(
            triangleCount: 8_192,
            rayCount: 4_096,
            traversalPassCount: 2,
            maximumElapsedSeconds: 3
        )
        let kernel = MetalRayTracingBenchmarkKernel(
            configuration: .init(limits: limits),
            clock: clock,
            driverFactory: { driver }
        )

        do {
            _ = try await kernel.run()
            XCTFail("Expected the safety deadline to fail")
        } catch {
            XCTAssertEqual(error as? BenchmarkKernelError, .resourceLimit)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testSystemDriverCompletesTestingWorkloadWhenHardwareRayTracingIsAvailable()
        async throws
    {
        do {
            let result = try await MetalRayTracingBenchmarkKernel(
                configuration: .testing
            ).run()
            XCTAssertGreaterThan(result.buildSample.value, 0)
            XCTAssertGreaterThan(result.traversalSample.value, 0)
            XCTAssertGreaterThan(result.hitCount, 0)
            XCTAssertLessThan(result.hitCount, result.rayCount)
            XCTAssertTrue([.apple9, .apple10].contains(result.hardwareFamily))
            XCTAssertFalse(result.ranOnMainThread)
        } catch BenchmarkKernelError.unavailable {
            throw XCTSkip("Apple GPU family 9/10 hardware ray tracing is unavailable")
        }
    }
}

private enum RayTracingEvent: Equatable, Sendable {
    case prepare
    case warmUp
    case build
    case traversal
    case validate
    case tearDown
}

private actor RayTracingEventRecorder {
    private var events: [RayTracingEvent] = []
    private var waiters: [(RayTracingEvent, CheckedContinuation<Void, Never>)] = []

    func append(_ event: RayTracingEvent) {
        events.append(event)
        var remaining: [(RayTracingEvent, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if waiter.0 == event {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func wait(until event: RayTracingEvent) async {
        if events.contains(event) { return }
        await withCheckedContinuation { continuation in
            waiters.append((event, continuation))
        }
    }

    func snapshot() -> [RayTracingEvent] {
        events
    }
}

private final class RayTracingManualClock: BenchmarkKernelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        value &+= nanoseconds
        lock.unlock()
    }
}

private actor FakeRayTracingDriver: MetalRayTracingBenchmarkDriving {
    static let buildChecksum: UInt64 = 0xB017_DA7A_600D_CAFE
    static let traversalChecksum: UInt64 = 0x7A6E_12A1_C0DE_BAAD

    private let recorder: RayTracingEventRecorder
    private let clock: RayTracingManualClock?
    private let prepareNanoseconds: UInt64
    private let warmupNanoseconds: UInt64
    private let buildNanoseconds: UInt64
    private let traversalNanoseconds: UInt64
    private let validationNanoseconds: UInt64
    private let buildElapsedSeconds: Double
    private let traversalElapsedSeconds: Double
    private let buildError: Error?
    private let validationError: Error?
    private let waitsForTraversalCancellation: Bool
    private var workload: MetalRayTracingBenchmarkWorkload?

    init(
        recorder: RayTracingEventRecorder,
        clock: RayTracingManualClock? = nil,
        prepareNanoseconds: UInt64 = 0,
        warmupNanoseconds: UInt64 = 0,
        buildNanoseconds: UInt64 = 0,
        traversalNanoseconds: UInt64 = 0,
        validationNanoseconds: UInt64 = 0,
        buildElapsedSeconds: Double = 0.25,
        traversalElapsedSeconds: Double = 0.5,
        buildError: Error? = nil,
        validationError: Error? = nil,
        waitsForTraversalCancellation: Bool = false
    ) {
        self.recorder = recorder
        self.clock = clock
        self.prepareNanoseconds = prepareNanoseconds
        self.warmupNanoseconds = warmupNanoseconds
        self.buildNanoseconds = buildNanoseconds
        self.traversalNanoseconds = traversalNanoseconds
        self.validationNanoseconds = validationNanoseconds
        self.buildElapsedSeconds = buildElapsedSeconds
        self.traversalElapsedSeconds = traversalElapsedSeconds
        self.buildError = buildError
        self.validationError = validationError
        self.waitsForTraversalCancellation = waitsForTraversalCancellation
    }

    func prepare(
        workload: MetalRayTracingBenchmarkWorkload
    ) async throws -> MetalRayTracingHardwareFamily {
        await recorder.append(.prepare)
        self.workload = workload
        clock?.advance(by: prepareNanoseconds)
        return .apple9
    }

    func warmUp() async throws {
        await recorder.append(.warmUp)
        clock?.advance(by: warmupNanoseconds)
    }

    func executeBuild() async throws -> MetalRayTracingBenchmarkExecution {
        await recorder.append(.build)
        if let buildError { throw buildError }
        clock?.advance(by: buildNanoseconds)
        return MetalRayTracingBenchmarkExecution(
            gpuElapsedSeconds: buildElapsedSeconds,
            ranOnMainThread: benchmarkKernelIsMainThread()
        )
    }

    func executeTraversal() async throws -> MetalRayTracingBenchmarkExecution {
        await recorder.append(.traversal)
        if waitsForTraversalCancellation {
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
        clock?.advance(by: traversalNanoseconds)
        return MetalRayTracingBenchmarkExecution(
            gpuElapsedSeconds: traversalElapsedSeconds,
            ranOnMainThread: benchmarkKernelIsMainThread()
        )
    }

    func validate() async throws -> MetalRayTracingBenchmarkValidation {
        await recorder.append(.validate)
        if let validationError { throw validationError }
        clock?.advance(by: validationNanoseconds)
        guard let workload else { throw BenchmarkKernelError.invalidConfiguration }
        return MetalRayTracingBenchmarkValidation(
            buildChecksum: Self.buildChecksum,
            traversalChecksum: Self.traversalChecksum,
            hitCount: max(1, workload.rayCount / 4)
        )
    }

    func tearDown() async {
        await recorder.append(.tearDown)
        workload = nil
    }
}
