@preconcurrency import Metal
import Foundation

protocol BenchmarkKernelClock: Sendable {
    func nowNanoseconds() -> UInt64
}

struct SystemBenchmarkKernelClock: BenchmarkKernelClock {
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

@inline(never)
func benchmarkKernelIsMainThread() -> Bool {
    Thread.isMainThread
}

struct MetalBenchmarkWorkload: Equatable, Sendable {
    let elementCount: Int
    let roundsPerElement: Int
    let operationsPerRound: Int
    let dispatchPassCount: Int
}

protocol MetalBenchmarkDriving: Sendable {
    func prepare(workload: MetalBenchmarkWorkload) async throws
    func warmUp() async throws
    /// Returns whether the actual command submission/wait occurred on the main thread.
    func execute() async throws -> Bool
    func validate() async throws -> UInt64
    func tearDown() async
}

struct MetalBenchmarkKernel: Sendable {
    // Three shifts, three XORs, one multiply and one add per element/round.
    static let operationsPerRound = 8
    static let maximumQuickElementCount = 1_048_576
    static let maximumFullElementCount = 4_194_304
    static let maximumRoundsPerElement = 256
    static let maximumDispatchPassCount = 1_024
    static let maximumValidationSampleCount = 1_024
    static let maximumQuickElapsedSeconds = 10.0
    static let maximumFullElapsedSeconds = 30.0

    struct Limits: Equatable, Sendable {
        let elementCount: Int
        let roundsPerElement: Int
        let dispatchPassCount: Int
        let maximumElapsedSeconds: Double
    }

    struct Configuration: Equatable, Sendable {
        let quick: Limits
        let full: Limits

        static let standard = Self(
            quick: Limits(
                elementCount: 524_288,
                roundsPerElement: 128,
                dispatchPassCount: 1_024,
                maximumElapsedSeconds: MetalBenchmarkKernel.maximumQuickElapsedSeconds
            ),
            full: Limits(
                elementCount: 2_097_152,
                roundsPerElement: 256,
                dispatchPassCount: 512,
                maximumElapsedSeconds: MetalBenchmarkKernel.maximumFullElapsedSeconds
            )
        )

        static let testing = Self(
            quick: Limits(
                elementCount: 32_768,
                roundsPerElement: 8,
                dispatchPassCount: 1,
                maximumElapsedSeconds: 2
            ),
            full: Limits(
                elementCount: 65_536,
                roundsPerElement: 12,
                dispatchPassCount: 1,
                maximumElapsedSeconds: 3
            )
        )

        func limits(for profile: BenchmarkProfile) -> Limits {
            switch profile {
            case .standard, .quick: quick
            case .full: full
            }
        }
    }

    struct RunResult: Equatable, Sendable {
        let sample: BenchmarkComponentSample
        let operationCount: UInt64
        let elementCount: Int
        let roundsPerElement: Int
        let ranOnMainThread: Bool
    }

    let configuration: Configuration
    private let clock: any BenchmarkKernelClock
    private let driverFactory: @Sendable () -> any MetalBenchmarkDriving

    init(
        configuration: Configuration = .standard,
        clock: any BenchmarkKernelClock = SystemBenchmarkKernelClock(),
        driverFactory: @escaping @Sendable () -> any MetalBenchmarkDriving = {
            SystemMetalBenchmarkDriver()
        }
    ) {
        self.configuration = configuration
        self.clock = clock
        self.driverFactory = driverFactory
    }

    func run(profile: BenchmarkProfile) async throws -> RunResult {
        try Task.checkCancellation()
        let limits = configuration.limits(for: profile)
        try Self.validate(limits, profile: profile)
        let clock = clock
        let factory = driverFactory

        let worker = Task.detached(priority: .userInitiated) {
            try await Self.runDetached(limits: limits, clock: clock, driverFactory: factory)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}

private extension MetalBenchmarkKernel {
    static func validate(_ limits: Limits, profile: BenchmarkProfile) throws {
        let maximumElements: Int
        let maximumSeconds: Double
        switch profile {
        case .standard, .quick:
            maximumElements = maximumQuickElementCount
            maximumSeconds = maximumQuickElapsedSeconds
        case .full:
            maximumElements = maximumFullElementCount
            maximumSeconds = maximumFullElapsedSeconds
        }

        guard limits.elementCount >= 4_096,
              limits.elementCount <= maximumElements,
              limits.roundsPerElement > 0,
              limits.roundsPerElement <= maximumRoundsPerElement,
              limits.dispatchPassCount > 0,
              limits.dispatchPassCount <= maximumDispatchPassCount,
              limits.maximumElapsedSeconds.isFinite,
              limits.maximumElapsedSeconds > 0,
              limits.maximumElapsedSeconds <= maximumSeconds
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        let (elementRounds, firstOverflow) = UInt64(limits.elementCount)
            .multipliedReportingOverflow(by: UInt64(limits.roundsPerElement))
        let (passOperations, secondOverflow) = elementRounds
            .multipliedReportingOverflow(by: UInt64(operationsPerRound))
        let (_, thirdOverflow) = passOperations
            .multipliedReportingOverflow(by: UInt64(limits.dispatchPassCount))
        guard !firstOverflow, !secondOverflow, !thirdOverflow else {
            throw BenchmarkKernelError.resourceLimit
        }
    }

    static func runDetached(
        limits: Limits,
        clock: any BenchmarkKernelClock,
        driverFactory: @Sendable () -> any MetalBenchmarkDriving
    ) async throws -> RunResult {
        let safetyStartedAt = clock.nowNanoseconds()
        let driver = driverFactory()
        let workload = MetalBenchmarkWorkload(
            elementCount: limits.elementCount,
            roundsPerElement: limits.roundsPerElement,
            operationsPerRound: operationsPerRound,
            dispatchPassCount: limits.dispatchPassCount
        )

        do {
            try Task.checkCancellation()
            try await driver.prepare(workload: workload)
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )

            try await driver.warmUp()
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )

            let timedStartedAt = clock.nowNanoseconds()
            let ranOnMainThread = try await driver.execute()
            let timedFinishedAt = clock.nowNanoseconds()
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds,
                sampledAt: timedFinishedAt
            )

            let checksum = try await driver.validate()
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )
            try Task.checkCancellation()

            let elapsedSeconds = seconds(from: timedStartedAt, to: timedFinishedAt)
            let (elementRounds, firstOverflow) = UInt64(limits.elementCount)
                .multipliedReportingOverflow(by: UInt64(limits.roundsPerElement))
            let (passOperations, secondOverflow) = elementRounds
                .multipliedReportingOverflow(by: UInt64(operationsPerRound))
            let (operationCount, thirdOverflow) = passOperations
                .multipliedReportingOverflow(by: UInt64(limits.dispatchPassCount))
            guard !firstOverflow, !secondOverflow, !thirdOverflow,
                  elapsedSeconds.isFinite,
                  elapsedSeconds > 0
            else {
                throw BenchmarkKernelError.invalidMetric
            }

            let throughput = (Double(operationCount) / 1_000_000_000) / elapsedSeconds
            guard throughput.isFinite, throughput > 0 else {
                throw BenchmarkKernelError.invalidMetric
            }

            await driver.tearDown()
            return RunResult(
                sample: BenchmarkComponentSample(
                    value: throughput,
                    elapsedSeconds: elapsedSeconds,
                    checksum: checksum
                ),
                operationCount: operationCount,
                elementCount: limits.elementCount,
                roundsPerElement: limits.roundsPerElement,
                ranOnMainThread: ranOnMainThread
            )
        } catch {
            await driver.tearDown()
            if error is CancellationError { throw CancellationError() }
            if let kernelError = error as? BenchmarkKernelError { throw kernelError }
            throw BenchmarkKernelError.systemFailure
        }
    }

    static func checkSafetyBoundary(
        clock: any BenchmarkKernelClock,
        startedAt: UInt64,
        maximumElapsedSeconds: Double,
        sampledAt: UInt64? = nil
    ) throws {
        try Task.checkCancellation()
        let finishedAt = sampledAt ?? clock.nowNanoseconds()
        guard seconds(from: startedAt, to: finishedAt) <= maximumElapsedSeconds else {
            throw BenchmarkKernelError.resourceLimit
        }
    }

    static func seconds(from startedAt: UInt64, to finishedAt: UInt64) -> Double {
        guard finishedAt >= startedAt else { return .infinity }
        return Double(finishedAt - startedAt) / 1_000_000_000
    }
}

private actor SystemMetalBenchmarkDriver: MetalBenchmarkDriving {
    private static let baseSeed: UInt32 = 0xA341_316C
    private static let checksumSeed: UInt64 = 0xCBF2_9CE4_8422_2325

    private var device: (any MTLDevice)?
    private var commandQueue: (any MTLCommandQueue)?
    private var pipeline: (any MTLComputePipelineState)?
    private var benchmarkInputBuffer: (any MTLBuffer)?
    private var benchmarkOutputBuffer: (any MTLBuffer)?
    private var workload: MetalBenchmarkWorkload?

    func prepare(workload: MetalBenchmarkWorkload) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BenchmarkKernelError.unavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw BenchmarkKernelError.systemFailure
        }

        let library: any MTLLibrary
        let pipeline: any MTLComputePipelineState
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let function = library.makeFunction(name: "storage_cleaner_benchmark") else {
                throw BenchmarkKernelError.systemFailure
            }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch let error as BenchmarkKernelError {
            throw error
        } catch {
            throw BenchmarkKernelError.systemFailure
        }

        let (byteCount, overflow) = workload.elementCount
            .multipliedReportingOverflow(by: MemoryLayout<UInt32>.stride)
        guard !overflow,
              let benchmarkInputBuffer = device.makeBuffer(
                  length: byteCount,
                  options: .storageModeShared
              ),
              let benchmarkOutputBuffer = device.makeBuffer(
                  length: byteCount,
                  options: .storageModeShared
              )
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        Self.initialize(
            buffer: benchmarkInputBuffer,
            elementCount: workload.elementCount,
            seed: Self.baseSeed
        )
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.benchmarkInputBuffer = benchmarkInputBuffer
        self.benchmarkOutputBuffer = benchmarkOutputBuffer
        self.workload = workload
    }

    func warmUp() throws {
        guard let benchmarkInputBuffer, let benchmarkOutputBuffer, let workload else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        try executeCommand(
            inputBuffer: benchmarkInputBuffer,
            outputBuffer: benchmarkOutputBuffer,
            elementCount: workload.elementCount,
            rounds: workload.roundsPerElement,
            dispatchPassCount: min(workload.dispatchPassCount, 64)
        )
    }

    func execute() throws -> Bool {
        guard let benchmarkInputBuffer, let benchmarkOutputBuffer, let workload else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        let ranOnMainThread = benchmarkKernelIsMainThread()
        try executeCommand(
            inputBuffer: benchmarkInputBuffer,
            outputBuffer: benchmarkOutputBuffer,
            elementCount: workload.elementCount,
            rounds: workload.roundsPerElement,
            dispatchPassCount: workload.dispatchPassCount
        )
        return ranOnMainThread
    }

    func validate() throws -> UInt64 {
        guard let benchmarkOutputBuffer, let workload else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        let values = benchmarkOutputBuffer.contents().assumingMemoryBound(to: UInt32.self)
        return try metalBenchmarkValidatedChecksum(
            values: values,
            workload: workload,
            baseSeed: Self.baseSeed,
            checksumSeed: Self.checksumSeed
        )
    }

    func tearDown() {
        benchmarkInputBuffer = nil
        benchmarkOutputBuffer = nil
        pipeline = nil
        commandQueue = nil
        device = nil
        workload = nil
    }
}

private extension SystemMetalBenchmarkDriver {
    func executeCommand(
        inputBuffer: any MTLBuffer,
        outputBuffer: any MTLBuffer,
        elementCount: Int,
        rounds: Int,
        dispatchPassCount: Int
    ) throws {
        guard let commandQueue,
              let pipeline,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw BenchmarkKernelError.systemFailure
        }

        var roundValue = UInt32(rounds)
        let width = max(1, min(pipeline.threadExecutionWidth,
                               pipeline.maxTotalThreadsPerThreadgroup))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.setBytes(&roundValue, length: MemoryLayout<UInt32>.stride, index: 2)
        for _ in 0..<dispatchPassCount {
            try Task.checkCancellation()
            encoder.dispatchThreads(
                MTLSize(width: elementCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
            )
        }
        encoder.endEncoding()
        commandBuffer.commit()
        // Metal has no safe general command-buffer cancellation. Waiting here guarantees
        // the benchmark lease never ends while this app still owns live GPU work.
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed, commandBuffer.error == nil else {
            throw BenchmarkKernelError.systemFailure
        }
        try Task.checkCancellation()
    }

    static func initialize(buffer: any MTLBuffer, elementCount: Int, seed: UInt32) {
        let values = buffer.contents().assumingMemoryBound(to: UInt32.self)
        var state = seed
        for index in 0..<elementCount {
            state = xorshift(state &+ UInt32(truncatingIfNeeded: index))
            values[index] = state
        }
    }

    static func xorshift(_ value: UInt32) -> UInt32 {
        var result = value
        result ^= result << 13
        result ^= result >> 17
        result ^= result << 5
        return result
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void storage_cleaner_benchmark(
        const device uint *input [[buffer(0)]],
        device uint *output [[buffer(1)]],
        constant uint &rounds [[buffer(2)]],
        uint index [[thread_position_in_grid]])
    {
        uint value = input[index];
        for (uint round = 0; round < rounds; ++round) {
            value ^= value << 13;
            value ^= value >> 17;
            value ^= value << 5;
            value = value * 1664525u + 1013904223u;
        }
        output[index] = value;
    }
    """
}

@inline(__always)
func metalBenchmarkReferenceMix(_ value: UInt32) -> UInt32 {
    var shifted = value
    shifted ^= shifted << 13
    shifted ^= shifted >> 17
    shifted ^= shifted << 5
    return shifted &* 1_664_525 &+ 1_013_904_223
}

@inline(never)
func metalBenchmarkValidatedChecksum(
    values: UnsafePointer<UInt32>,
    workload: MetalBenchmarkWorkload,
    baseSeed: UInt32,
    checksumSeed: UInt64,
    cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
) throws -> UInt64 {
    try cancellationCheck()
    var state = baseSeed
    var checksum = checksumSeed
    let validationStride = max(
        1,
        workload.elementCount / MetalBenchmarkKernel.maximumValidationSampleCount
    )
    for index in 0..<workload.elementCount {
        if index > 0, index.isMultiple(of: 4_096) {
            try cancellationCheck()
        }
        var shifted = state &+ UInt32(truncatingIfNeeded: index)
        shifted ^= shifted << 13
        shifted ^= shifted >> 17
        shifted ^= shifted << 5
        state = shifted

        let actual = values[index]
        if index.isMultiple(of: validationStride) || index == workload.elementCount - 1 {
            var expected = state
            for _ in 0..<workload.roundsPerElement {
                expected = metalBenchmarkReferenceMix(expected)
            }
            guard actual == expected else {
                throw BenchmarkKernelError.checksumMismatch
            }
        }
        checksum ^= UInt64(actual) &+ UInt64(index)
        checksum = (checksum &* 0x0000_0100_0000_01B3).rotatedLeft(by: 13)
    }
    return checksum
}

private extension UInt64 {
    func rotatedLeft(by amount: UInt64) -> UInt64 {
        let shift = amount & 63
        guard shift != 0 else { return self }
        return (self << shift) | (self >> (64 - shift))
    }
}
