import Foundation
import XCTest
@testable import StorageCleanerMac

final class GPUTensorBenchmarkKernelTests: XCTestCase {
    func testUsesGPUTimeComputesEffectiveTFLOPSAndAlwaysCleansUp() async throws {
        let recorder = GPUTensorEventRecorder()
        let driver = FakeGPUTensorBenchmarkDriver(
            recorder: recorder,
            gpuElapsedSeconds: 0.5
        )
        let configuration = GPUTensorBenchmarkKernel.Configuration(
            limits: GPUTensorBenchmarkKernel.Limits(
                rows: 16,
                columns: 16,
                innerDimension: 16,
                iterationCount: 2,
                warmUpIterationCount: 1,
                precision: .float16,
                maximumElapsedSeconds: 3
            )
        )

        let sample = try await GPUTensorBenchmarkKernel(
            configuration: configuration,
            driverFactory: { driver }
        ).run()

        let expectedOperations = Double(2 * 16 * 16 * 16 * 2)
        XCTAssertEqual(sample.elapsedSeconds, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            sample.value,
            expectedOperations / 1_000_000_000_000 / 0.5,
            accuracy: 0.000_000_000_001
        )
        XCTAssertEqual(sample.checksum, FakeGPUTensorBenchmarkDriver.validChecksum)
        let events = await recorder.snapshot()
        XCTAssertEqual(events, [.prepare, .warmUp, .execute, .validate, .tearDown])
        let workload = await driver.preparedWorkload
        XCTAssertEqual(workload?.precision, .float16)
        XCTAssertEqual(workload?.iterationCount, 2)
    }

    func testStandardAndTestingConfigurationsAreFixedAndBounded() {
        let standard = GPUTensorBenchmarkKernel.Configuration.standard.limits
        XCTAssertEqual(standard.rows, 2_048)
        XCTAssertEqual(standard.columns, 2_048)
        XCTAssertEqual(standard.innerDimension, 2_048)
        XCTAssertEqual(standard.iterationCount, 128)
        XCTAssertEqual(standard.warmUpIterationCount, 4)
        XCTAssertEqual(standard.precision, .float16)
        XCTAssertLessThanOrEqual(
            standard.iterationCount,
            GPUTensorBenchmarkKernel.maximumIterationCount
        )

        let standardFP32 = GPUTensorBenchmarkKernel.Configuration.standardFP32.limits
        XCTAssertEqual(standardFP32.precision, .float32)
        XCTAssertEqual(standardFP32.iterationCount, 64)

        let testing = GPUTensorBenchmarkKernel.Configuration.testing.limits
        XCTAssertEqual(testing.rows, 256)
        XCTAssertEqual(testing.iterationCount, 8)
        XCTAssertEqual(testing.precision, .float16)
        XCTAssertEqual(
            GPUTensorBenchmarkKernel.Configuration.testingFP32.limits.precision,
            .float32
        )
    }

    func testRejectsOversizedDimensionBeforeCreatingDriver() async {
        let recorder = GPUTensorEventRecorder()
        let driver = FakeGPUTensorBenchmarkDriver(recorder: recorder)
        let configuration = GPUTensorBenchmarkKernel.Configuration(
            limits: GPUTensorBenchmarkKernel.Limits(
                rows: GPUTensorBenchmarkKernel.maximumDimension + 1,
                columns: 16,
                innerDimension: 16,
                iterationCount: 1,
                warmUpIterationCount: 1,
                precision: .float16,
                maximumElapsedSeconds: 3
            )
        )

        await XCTAssertGPUTensorThrowsError(
            try await GPUTensorBenchmarkKernel(
                configuration: configuration,
                driverFactory: { driver }
            ).run()
        ) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .resourceLimit)
        }
        let events = await recorder.snapshot()
        XCTAssertTrue(events.isEmpty)
    }

    func testRejectsConfigurationBeyondTotalBufferBudget() async {
        let recorder = GPUTensorEventRecorder()
        let driver = FakeGPUTensorBenchmarkDriver(recorder: recorder)
        let configuration = GPUTensorBenchmarkKernel.Configuration(
            limits: GPUTensorBenchmarkKernel.Limits(
                rows: 4_096,
                columns: 4_096,
                innerDimension: 4_096,
                iterationCount: 1,
                warmUpIterationCount: 1,
                precision: .float32,
                maximumElapsedSeconds: 3
            )
        )

        await XCTAssertGPUTensorThrowsError(
            try await GPUTensorBenchmarkKernel(
                configuration: configuration,
                driverFactory: { driver }
            ).run()
        ) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .resourceLimit)
        }
        let events = await recorder.snapshot()
        XCTAssertTrue(events.isEmpty)
    }

    func testInvalidGPUTimePublishesNoMetricAndCleansUp() async {
        let recorder = GPUTensorEventRecorder()
        let driver = FakeGPUTensorBenchmarkDriver(
            recorder: recorder,
            gpuElapsedSeconds: 0
        )

        await XCTAssertGPUTensorThrowsError(
            try await GPUTensorBenchmarkKernel(
                configuration: .testing,
                driverFactory: { driver }
            ).run()
        ) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .invalidMetric)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testWholeRunSafetyLimitIncludesPreparationAndCleansUp() async {
        let clock = ManualGPUTensorBenchmarkClock()
        let recorder = GPUTensorEventRecorder()
        let driver = FakeGPUTensorBenchmarkDriver(
            recorder: recorder,
            clock: clock,
            prepareNanoseconds: 3_100_000_000
        )

        await XCTAssertGPUTensorThrowsError(
            try await GPUTensorBenchmarkKernel(
                configuration: .testing,
                clock: clock,
                driverFactory: { driver }
            ).run()
        ) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .resourceLimit)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events, [.prepare, .tearDown])
    }

    func testCancellationWaitsForCleanupAndPublishesNoMetric() async {
        let recorder = GPUTensorEventRecorder()
        let driver = FakeGPUTensorBenchmarkDriver(
            recorder: recorder,
            waitsForCancellation: true
        )
        let task = Task {
            try await GPUTensorBenchmarkKernel(
                configuration: .testing,
                driverFactory: { driver }
            ).run()
        }

        await recorder.wait(until: .execute)
        task.cancel()

        await XCTAssertGPUTensorThrowsError(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events.last, .tearDown)
    }

    func testValidationFailureStillCleansUp() async {
        let recorder = GPUTensorEventRecorder()
        let driver = FakeGPUTensorBenchmarkDriver(
            recorder: recorder,
            validationError: BenchmarkKernelError.checksumMismatch
        )

        await XCTAssertGPUTensorThrowsError(
            try await GPUTensorBenchmarkKernel(
                configuration: .testing,
                driverFactory: { driver }
            ).run()
        ) { error in
            XCTAssertEqual(error as? BenchmarkKernelError, .checksumMismatch)
        }
        let events = await recorder.snapshot()
        XCTAssertEqual(events, [.prepare, .warmUp, .execute, .validate, .tearDown])
    }

    func testSystemDriverCompletesTestingWorkloadsWhenMetalIsAvailable() async throws {
        do {
            for configuration in [
                GPUTensorBenchmarkKernel.Configuration.testing,
                GPUTensorBenchmarkKernel.Configuration.testingFP32
            ] {
                let sample = try await GPUTensorBenchmarkKernel(
                    configuration: configuration
                ).run()
                XCTAssertGreaterThan(sample.value, 0)
                XCTAssertGreaterThan(sample.elapsedSeconds, 0)
                XCTAssertGreaterThan(sample.checksum, 0)
            }
        } catch BenchmarkKernelError.unavailable {
            throw XCTSkip("Metal Performance Shaders is unavailable in this environment")
        }
    }
}

private enum GPUTensorEvent: Equatable, Sendable {
    case prepare
    case warmUp
    case execute
    case validate
    case tearDown
}

private actor GPUTensorEventRecorder {
    private var events: [GPUTensorEvent] = []

    func append(_ event: GPUTensorEvent) {
        events.append(event)
    }

    func snapshot() -> [GPUTensorEvent] {
        events
    }

    func wait(until event: GPUTensorEvent) async {
        while !events.contains(event) {
            await Task.yield()
        }
    }
}

private final class ManualGPUTensorBenchmarkClock: BenchmarkKernelClock, @unchecked Sendable {
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

private actor FakeGPUTensorBenchmarkDriver: GPUTensorBenchmarkDriving {
    static let validChecksum: UInt64 = 0x7E05_0A11_C0DE_BAAD

    private let recorder: GPUTensorEventRecorder
    private let gpuElapsedSeconds: Double
    private let clock: ManualGPUTensorBenchmarkClock?
    private let prepareNanoseconds: UInt64
    private let waitsForCancellation: Bool
    private let validationError: Error?
    private(set) var preparedWorkload: GPUTensorBenchmarkWorkload?

    init(
        recorder: GPUTensorEventRecorder,
        gpuElapsedSeconds: Double = 0.25,
        clock: ManualGPUTensorBenchmarkClock? = nil,
        prepareNanoseconds: UInt64 = 0,
        waitsForCancellation: Bool = false,
        validationError: Error? = nil
    ) {
        self.recorder = recorder
        self.gpuElapsedSeconds = gpuElapsedSeconds
        self.clock = clock
        self.prepareNanoseconds = prepareNanoseconds
        self.waitsForCancellation = waitsForCancellation
        self.validationError = validationError
    }

    func prepare(workload: GPUTensorBenchmarkWorkload) async {
        preparedWorkload = workload
        await recorder.append(.prepare)
        clock?.advance(by: prepareNanoseconds)
    }

    func warmUp() async {
        await recorder.append(.warmUp)
    }

    func execute() async throws -> GPUTensorBenchmarkExecution {
        await recorder.append(.execute)
        if waitsForCancellation {
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }
        return GPUTensorBenchmarkExecution(gpuElapsedSeconds: gpuElapsedSeconds)
    }

    func validate() async throws -> UInt64 {
        await recorder.append(.validate)
        if let validationError { throw validationError }
        return Self.validChecksum
    }

    func tearDown() async {
        await recorder.append(.tearDown)
    }
}

private func XCTAssertGPUTensorThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
