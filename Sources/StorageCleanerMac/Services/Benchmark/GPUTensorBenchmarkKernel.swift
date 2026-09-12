@preconcurrency import Metal
@preconcurrency import MetalPerformanceShaders
import Foundation

enum GPUTensorBenchmarkPrecision: Equatable, Sendable {
    case float16
    case float32

    fileprivate var mpsDataType: MPSDataType {
        switch self {
        case .float16: .float16
        case .float32: .float32
        }
    }
}

struct GPUTensorBenchmarkWorkload: Equatable, Sendable {
    let rows: Int
    let columns: Int
    let innerDimension: Int
    let iterationCount: Int
    let warmUpIterationCount: Int
    let precision: GPUTensorBenchmarkPrecision
}

struct GPUTensorBenchmarkExecution: Equatable, Sendable {
    /// Metal command-buffer GPU execution time. Wall-clock time is never used
    /// as a substitute because the published value is effective GPU TFLOP/s.
    let gpuElapsedSeconds: Double
    /// Submission-to-completion wall time for the same bounded command batches.
    /// It is diagnostic metadata and never replaces GPU timing in the score.
    let wallElapsedSeconds: Double?

    init(gpuElapsedSeconds: Double, wallElapsedSeconds: Double? = nil) {
        self.gpuElapsedSeconds = gpuElapsedSeconds
        self.wallElapsedSeconds = wallElapsedSeconds
    }
}

protocol GPUTensorBenchmarkDriving: Sendable {
    func prepare(workload: GPUTensorBenchmarkWorkload) async throws
    func warmUp() async throws
    func execute() async throws -> GPUTensorBenchmarkExecution
    func validate() async throws -> UInt64
    func tearDown() async
}

/// Deterministic dense matrix multiplication encoded through
/// `MPSMatrixMultiplication`. Preparation, warm-up and validation are excluded
/// from the metric, while the safety deadline covers the entire run.
struct GPUTensorBenchmarkKernel: Sendable {
    static let minimumDimension = 16
    static let maximumDimension = 4_096
    static let maximumIterationCount = 256
    static let maximumWarmUpIterationCount = 16
    static let maximumAllocatedBytes = 128 * 1_024 * 1_024
    static let maximumElapsedSeconds = 30.0

    struct Limits: Equatable, Sendable {
        let rows: Int
        let columns: Int
        let innerDimension: Int
        let iterationCount: Int
        let warmUpIterationCount: Int
        let precision: GPUTensorBenchmarkPrecision
        let maximumElapsedSeconds: Double
    }

    struct Configuration: Equatable, Sendable {
        let limits: Limits

        /// The default scored workload measures FP16 tensor throughput.
        static let standard = Self(
            limits: Limits(
                rows: 2_048,
                columns: 2_048,
                innerDimension: 2_048,
                iterationCount: 128,
                warmUpIterationCount: 4,
                precision: .float16,
                maximumElapsedSeconds: 20
            )
        )

        /// Kept separate so FP16 and FP32 never share a reference baseline.
        static let standardFP32 = Self(
            limits: Limits(
                rows: 2_048,
                columns: 2_048,
                innerDimension: 2_048,
                iterationCount: 64,
                warmUpIterationCount: 4,
                precision: .float32,
                maximumElapsedSeconds: 20
            )
        )

        static let testing = Self(
            limits: Limits(
                rows: 256,
                columns: 256,
                innerDimension: 256,
                iterationCount: 8,
                warmUpIterationCount: 1,
                precision: .float16,
                maximumElapsedSeconds: 3
            )
        )

        static let testingFP32 = Self(
            limits: Limits(
                rows: 256,
                columns: 256,
                innerDimension: 256,
                iterationCount: 8,
                warmUpIterationCount: 1,
                precision: .float32,
                maximumElapsedSeconds: 3
            )
        )
    }

    struct RunResult: Equatable, Sendable {
        let sample: BenchmarkComponentSample
        let wallElapsedSeconds: Double?
    }

    let configuration: Configuration
    private let clock: any BenchmarkKernelClock
    private let driverFactory: @Sendable () -> any GPUTensorBenchmarkDriving

    init(
        configuration: Configuration = .standard,
        clock: any BenchmarkKernelClock = SystemBenchmarkKernelClock(),
        driverFactory: @escaping @Sendable () -> any GPUTensorBenchmarkDriving = {
            SystemGPUTensorBenchmarkDriver()
        }
    ) {
        self.configuration = configuration
        self.clock = clock
        self.driverFactory = driverFactory
    }

    /// Returns effective tera-floating-point-operations per second. The unit is
    /// intentionally assigned by the caller so this kernel stays independent
    /// from score models and UI presentation.
    func run() async throws -> BenchmarkComponentSample {
        try await runDetailed().sample
    }

    func runDetailed() async throws -> RunResult {
        try Task.checkCancellation()
        try Self.validate(configuration.limits)
        let limits = configuration.limits
        let clock = clock
        let factory = driverFactory
        let worker = Task.detached(priority: .userInitiated) {
            try await Self.runDetached(
                limits: limits,
                clock: clock,
                driverFactory: factory
            )
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

private extension GPUTensorBenchmarkKernel {
    static func validate(_ limits: Limits) throws {
        guard limits.rows >= minimumDimension,
              limits.rows <= maximumDimension,
              limits.columns >= minimumDimension,
              limits.columns <= maximumDimension,
              limits.innerDimension >= minimumDimension,
              limits.innerDimension <= maximumDimension,
              limits.iterationCount > 0,
              limits.iterationCount <= maximumIterationCount,
              limits.warmUpIterationCount > 0,
              limits.warmUpIterationCount <= maximumWarmUpIterationCount,
              limits.maximumElapsedSeconds.isFinite,
              limits.maximumElapsedSeconds > 0,
              limits.maximumElapsedSeconds <= maximumElapsedSeconds
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        let leftRowBytes = MPSMatrixDescriptor.rowBytes(
            fromColumns: limits.innerDimension,
            dataType: limits.precision.mpsDataType
        )
        let rightRowBytes = MPSMatrixDescriptor.rowBytes(
            fromColumns: limits.columns,
            dataType: limits.precision.mpsDataType
        )
        let resultRowBytes = MPSMatrixDescriptor.rowBytes(
            fromColumns: limits.columns,
            dataType: limits.precision.mpsDataType
        )
        let (leftBytes, leftOverflow) = leftRowBytes.multipliedReportingOverflow(by: limits.rows)
        let (rightBytes, rightOverflow) = rightRowBytes.multipliedReportingOverflow(
            by: limits.innerDimension
        )
        let (resultBytes, resultOverflow) = resultRowBytes.multipliedReportingOverflow(
            by: limits.rows
        )
        let (inputBytes, firstSumOverflow) = leftBytes.addingReportingOverflow(rightBytes)
        let (allocatedBytes, secondSumOverflow) = inputBytes.addingReportingOverflow(resultBytes)
        guard !leftOverflow,
              !rightOverflow,
              !resultOverflow,
              !firstSumOverflow,
              !secondSumOverflow,
              allocatedBytes > 0,
              allocatedBytes <= maximumAllocatedBytes
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        _ = try floatingPointOperationCount(
            rows: limits.rows,
            columns: limits.columns,
            innerDimension: limits.innerDimension,
            iterationCount: limits.iterationCount
        )
    }

    static func runDetached(
        limits: Limits,
        clock: any BenchmarkKernelClock,
        driverFactory: @Sendable () -> any GPUTensorBenchmarkDriving
    ) async throws -> RunResult {
        let safetyStartedAt = clock.nowNanoseconds()
        let driver = driverFactory()
        let workload = GPUTensorBenchmarkWorkload(
            rows: limits.rows,
            columns: limits.columns,
            innerDimension: limits.innerDimension,
            iterationCount: limits.iterationCount,
            warmUpIterationCount: limits.warmUpIterationCount,
            precision: limits.precision
        )
        let result: RunResult

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
            let execution = try await driver.execute()
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )
            let checksum = try await driver.validate()
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )
            try Task.checkCancellation()

            let elapsedSeconds = execution.gpuElapsedSeconds
            guard elapsedSeconds.isFinite, elapsedSeconds > 0, checksum != 0 else {
                throw BenchmarkKernelError.invalidMetric
            }
            let operationCount = try floatingPointOperationCount(
                rows: limits.rows,
                columns: limits.columns,
                innerDimension: limits.innerDimension,
                iterationCount: limits.iterationCount
            )
            let throughput = (Double(operationCount) / 1_000_000_000_000) / elapsedSeconds
            guard throughput.isFinite, throughput > 0 else {
                throw BenchmarkKernelError.invalidMetric
            }
            result = RunResult(
                sample: BenchmarkComponentSample(
                    value: throughput,
                    elapsedSeconds: elapsedSeconds,
                    checksum: checksum
                ),
                wallElapsedSeconds: execution.wallElapsedSeconds
            )
        } catch {
            await driver.tearDown()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let workloadError = error as? MacAcceleratorWorkloadError {
                throw workloadError
            }
            if let kernelError = error as? BenchmarkKernelError { throw kernelError }
            throw BenchmarkKernelError.systemFailure
        }

        await driver.tearDown()
        try Task.checkCancellation()
        return result
    }

    static func floatingPointOperationCount(
        rows: Int,
        columns: Int,
        innerDimension: Int,
        iterationCount: Int
    ) throws -> UInt64 {
        let (outputElements, firstOverflow) = UInt64(rows)
            .multipliedReportingOverflow(by: UInt64(columns))
        let (multiplyAccumulates, secondOverflow) = outputElements
            .multipliedReportingOverflow(by: UInt64(innerDimension))
        let (operationsPerIteration, thirdOverflow) = multiplyAccumulates
            .multipliedReportingOverflow(by: 2)
        let (operationCount, fourthOverflow) = operationsPerIteration
            .multipliedReportingOverflow(by: UInt64(iterationCount))
        guard !firstOverflow,
              !secondOverflow,
              !thirdOverflow,
              !fourthOverflow,
              operationCount > 0
        else {
            throw BenchmarkKernelError.resourceLimit
        }
        return operationCount
    }

    static func checkSafetyBoundary(
        clock: any BenchmarkKernelClock,
        startedAt: UInt64,
        maximumElapsedSeconds: Double
    ) throws {
        try Task.checkCancellation()
        let finishedAt = clock.nowNanoseconds()
        guard finishedAt >= startedAt,
              Double(finishedAt - startedAt) / 1_000_000_000 <= maximumElapsedSeconds
        else {
            throw BenchmarkKernelError.resourceLimit
        }
    }
}

private actor SystemGPUTensorBenchmarkDriver: GPUTensorBenchmarkDriving {
    private static let leftSalt: UInt64 = 0xA341_316C_D15C_A11A
    private static let rightSalt: UInt64 = 0xC801_3EA4_C0FF_EE00
    private static let maximumValidationSampleCount = 64
    private static let commandBufferIterationBatchSize = 16

    private var device: (any MTLDevice)?
    private var commandQueue: (any MTLCommandQueue)?
    private var multiplication: MPSMatrixMultiplication?
    private var leftMatrix: MPSMatrix?
    private var rightMatrix: MPSMatrix?
    private var resultMatrix: MPSMatrix?
    private var workload: GPUTensorBenchmarkWorkload?
    private var resultRowBytes = 0

    func prepare(workload: GPUTensorBenchmarkWorkload) throws {
        try Task.checkCancellation()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BenchmarkKernelError.unavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MacAcceleratorWorkloadError.temporarilyUnavailable
        }

        let leftRowBytes = MPSMatrixDescriptor.rowBytes(
            fromColumns: workload.innerDimension,
            dataType: workload.precision.mpsDataType
        )
        let rightRowBytes = MPSMatrixDescriptor.rowBytes(
            fromColumns: workload.columns,
            dataType: workload.precision.mpsDataType
        )
        let resultRowBytes = MPSMatrixDescriptor.rowBytes(
            fromColumns: workload.columns,
            dataType: workload.precision.mpsDataType
        )
        let (leftLength, leftOverflow) = leftRowBytes.multipliedReportingOverflow(by: workload.rows)
        let (rightLength, rightOverflow) = rightRowBytes.multipliedReportingOverflow(
            by: workload.innerDimension
        )
        let (resultLength, resultOverflow) = resultRowBytes.multipliedReportingOverflow(
            by: workload.rows
        )
        guard !leftOverflow,
              !rightOverflow,
              !resultOverflow,
              let leftBuffer = device.makeBuffer(length: leftLength, options: .storageModeShared),
              let rightBuffer = device.makeBuffer(length: rightLength, options: .storageModeShared),
              let resultBuffer = device.makeBuffer(length: resultLength, options: .storageModeShared)
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        try Self.fill(
            buffer: leftBuffer,
            rows: workload.rows,
            columns: workload.innerDimension,
            rowBytes: leftRowBytes,
            salt: Self.leftSalt,
            precision: workload.precision
        )
        try Self.fill(
            buffer: rightBuffer,
            rows: workload.innerDimension,
            columns: workload.columns,
            rowBytes: rightRowBytes,
            salt: Self.rightSalt,
            precision: workload.precision
        )

        let leftDescriptor = MPSMatrixDescriptor(
            rows: workload.rows,
            columns: workload.innerDimension,
            rowBytes: leftRowBytes,
            dataType: workload.precision.mpsDataType
        )
        let rightDescriptor = MPSMatrixDescriptor(
            rows: workload.innerDimension,
            columns: workload.columns,
            rowBytes: rightRowBytes,
            dataType: workload.precision.mpsDataType
        )
        let resultDescriptor = MPSMatrixDescriptor(
            rows: workload.rows,
            columns: workload.columns,
            rowBytes: resultRowBytes,
            dataType: workload.precision.mpsDataType
        )

        self.device = device
        self.commandQueue = commandQueue
        self.multiplication = MPSMatrixMultiplication(
            device: device,
            transposeLeft: false,
            transposeRight: false,
            resultRows: workload.rows,
            resultColumns: workload.columns,
            interiorColumns: workload.innerDimension,
            alpha: 1,
            beta: 0
        )
        self.leftMatrix = MPSMatrix(buffer: leftBuffer, descriptor: leftDescriptor)
        self.rightMatrix = MPSMatrix(buffer: rightBuffer, descriptor: rightDescriptor)
        self.resultMatrix = MPSMatrix(buffer: resultBuffer, descriptor: resultDescriptor)
        self.workload = workload
        self.resultRowBytes = resultRowBytes
    }

    func warmUp() throws {
        guard let workload else { throw BenchmarkKernelError.invalidConfiguration }
        _ = try encodeAndWait(
            iterationCount: workload.warmUpIterationCount,
            requireGPUTiming: false
        )
    }

    func execute() throws -> GPUTensorBenchmarkExecution {
        guard let workload else { throw BenchmarkKernelError.invalidConfiguration }
        let wallStartedAt = DispatchTime.now().uptimeNanoseconds
        let gpuElapsedSeconds = try encodeAndWait(
            iterationCount: workload.iterationCount,
            requireGPUTiming: true
        )
        let wallFinishedAt = DispatchTime.now().uptimeNanoseconds
        let wallElapsedSeconds = Double(wallFinishedAt - wallStartedAt) / 1_000_000_000
        guard wallElapsedSeconds.isFinite, wallElapsedSeconds > 0 else {
            throw BenchmarkKernelError.invalidMetric
        }
        return GPUTensorBenchmarkExecution(
            gpuElapsedSeconds: gpuElapsedSeconds,
            wallElapsedSeconds: wallElapsedSeconds
        )
    }

    func validate() throws -> UInt64 {
        guard let workload,
              let resultMatrix,
              resultRowBytes > 0
        else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        try Task.checkCancellation()

        var checksum: UInt64 = workload.precision == .float16
            ? 0x16F1_6F1A_CB42_2325
            : 0x32F3_2F3A_CB42_2325
        for row in 0..<workload.rows {
            if row.isMultiple(of: 16) { try Task.checkCancellation() }
            for column in 0..<workload.columns {
                let value = Self.resultValue(
                    matrix: resultMatrix,
                    row: row,
                    column: column,
                    rowBytes: resultRowBytes,
                    precision: workload.precision
                )
                guard value.isFinite else { throw BenchmarkKernelError.checksumMismatch }
                let scaled = Double(value) * 1_024
                guard scaled.isFinite,
                      scaled >= Double(Int64.min),
                      scaled <= Double(Int64.max)
                else {
                    throw BenchmarkKernelError.checksumMismatch
                }
                let quantized = Int64(scaled.rounded(.toNearestOrEven))
                checksum ^= UInt64(bitPattern: quantized)
                checksum &*= 0x0000_0100_0000_01B3
                checksum = (checksum << 13) | (checksum >> 51)
            }
        }

        let (resultElementCount, overflow) = workload.rows.multipliedReportingOverflow(
            by: workload.columns
        )
        guard !overflow, resultElementCount > 0 else {
            throw BenchmarkKernelError.resourceLimit
        }
        let validationSampleCount = min(Self.maximumValidationSampleCount, resultElementCount)
        for sampleIndex in 0..<validationSampleCount {
            if sampleIndex.isMultiple(of: 8) { try Task.checkCancellation() }
            let linearIndex = sampleIndex * resultElementCount / validationSampleCount
            let row = linearIndex / workload.columns
            let column = linearIndex % workload.columns
            var expected = 0.0
            for inner in 0..<workload.innerDimension {
                expected += Double(Self.inputValue(
                    row: row,
                    column: inner,
                    salt: Self.leftSalt,
                    precision: workload.precision
                )) * Double(Self.inputValue(
                    row: inner,
                    column: column,
                    salt: Self.rightSalt,
                    precision: workload.precision
                ))
            }
            let actual = Double(Self.resultValue(
                matrix: resultMatrix,
                row: row,
                column: column,
                rowBytes: resultRowBytes,
                precision: workload.precision
            ))
            let tolerance: Double = switch workload.precision {
            case .float16: max(0.5, abs(expected) * 0.05)
            case .float32: max(0.005, abs(expected) * 0.001)
            }
            guard actual.isFinite, abs(actual - expected) <= tolerance else {
                throw BenchmarkKernelError.checksumMismatch
            }
        }

        guard checksum != 0 else { throw BenchmarkKernelError.checksumMismatch }
        return checksum
    }

    func tearDown() {
        resultMatrix = nil
        rightMatrix = nil
        leftMatrix = nil
        multiplication = nil
        commandQueue = nil
        device = nil
        workload = nil
        resultRowBytes = 0
    }
}

private extension SystemGPUTensorBenchmarkDriver {
    func encodeAndWait(iterationCount: Int, requireGPUTiming: Bool) throws -> Double {
        guard iterationCount > 0,
              let commandQueue,
              let multiplication,
              let leftMatrix,
              let rightMatrix,
              let resultMatrix
        else {
            throw BenchmarkKernelError.invalidConfiguration
        }

        var encodedCount = 0
        var totalGPUElapsedSeconds = 0.0
        while encodedCount < iterationCount {
            try Task.checkCancellation()
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw MacAcceleratorWorkloadError.temporarilyUnavailable
            }
            let batchCount = min(
                Self.commandBufferIterationBatchSize,
                iterationCount - encodedCount
            )
            for _ in 0..<batchCount {
                multiplication.encode(
                    commandBuffer: commandBuffer,
                    leftMatrix: leftMatrix,
                    rightMatrix: rightMatrix,
                    resultMatrix: resultMatrix
                )
            }
            commandBuffer.commit()
            // Submitted Metal work cannot be cancelled safely. Always wait for
            // the bounded batch before observing cancellation so no GPU work
            // escapes the heavy-work lease.
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed,
                  commandBuffer.error == nil else {
                throw BenchmarkKernelError.systemFailure
            }
            try Task.checkCancellation()

            if requireGPUTiming {
                let gpuStartTime = commandBuffer.gpuStartTime
                let gpuEndTime = commandBuffer.gpuEndTime
                let elapsed = gpuEndTime - gpuStartTime
                guard gpuStartTime.isFinite,
                      gpuEndTime.isFinite,
                      gpuEndTime >= gpuStartTime,
                      elapsed.isFinite,
                      elapsed > 0 else {
                    throw BenchmarkKernelError.invalidMetric
                }
                totalGPUElapsedSeconds += elapsed
            }
            encodedCount += batchCount
        }
        guard !requireGPUTiming
                || totalGPUElapsedSeconds.isFinite && totalGPUElapsedSeconds > 0
        else {
            throw BenchmarkKernelError.invalidMetric
        }
        return totalGPUElapsedSeconds
    }

    static func fill(
        buffer: any MTLBuffer,
        rows: Int,
        columns: Int,
        rowBytes: Int,
        salt: UInt64,
        precision: GPUTensorBenchmarkPrecision
    ) throws {
        let bytesPerElement = precision == .float16
            ? MemoryLayout<Float16>.stride
            : MemoryLayout<Float>.stride
        let base = buffer.contents()
        for row in 0..<rows {
            if row.isMultiple(of: 16) { try Task.checkCancellation() }
            for column in 0..<columns {
                let value = inputValue(
                    row: row,
                    column: column,
                    salt: salt,
                    precision: precision
                )
                let offset = row * rowBytes + column * bytesPerElement
                switch precision {
                case .float16:
                    base.storeBytes(of: Float16(value), toByteOffset: offset, as: Float16.self)
                case .float32:
                    base.storeBytes(of: value, toByteOffset: offset, as: Float.self)
                }
            }
        }
    }

    static func inputValue(
        row: Int,
        column: Int,
        salt: UInt64,
        precision: GPUTensorBenchmarkPrecision
    ) -> Float {
        var value = UInt64(row) &* 0x9E37_79B9_7F4A_7C15
        value ^= UInt64(column) &* 0xBF58_476D_1CE4_E5B9
        value ^= salt
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        let centered = Int(value % 17) - 8
        let result = Float(centered) / 16
        return precision == .float16 ? Float(Float16(result)) : result
    }

    static func resultValue(
        matrix: MPSMatrix,
        row: Int,
        column: Int,
        rowBytes: Int,
        precision: GPUTensorBenchmarkPrecision
    ) -> Float {
        let base = matrix.data.contents()
        switch precision {
        case .float16:
            return Float(base.load(
                fromByteOffset: row * rowBytes + column * MemoryLayout<Float16>.stride,
                as: Float16.self
            ))
        case .float32:
            return base.load(
                fromByteOffset: row * rowBytes + column * MemoryLayout<Float>.stride,
                as: Float.self
            )
        }
    }
}
