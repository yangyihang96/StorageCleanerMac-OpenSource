@preconcurrency import Metal
import Foundation

enum MetalRayTracingHardwareFamily: String, Equatable, Codable, Sendable {
    case apple9
    case apple10
}

struct MetalRayTracingBenchmarkWorkload: Equatable, Sendable {
    let triangleCount: Int
    let rayCount: Int
    let traversalPassCount: Int
}

struct MetalRayTracingBenchmarkExecution: Equatable, Sendable {
    let gpuElapsedSeconds: Double
    let ranOnMainThread: Bool
}

struct MetalRayTracingBenchmarkValidation: Equatable, Sendable {
    let buildChecksum: UInt64
    let traversalChecksum: UInt64
    let hitCount: Int
}

protocol MetalRayTracingBenchmarkDriving: Sendable {
    func prepare(
        workload: MetalRayTracingBenchmarkWorkload
    ) async throws -> MetalRayTracingHardwareFamily
    func warmUp() async throws
    func executeBuild() async throws -> MetalRayTracingBenchmarkExecution
    func executeTraversal() async throws -> MetalRayTracingBenchmarkExecution
    func validate() async throws -> MetalRayTracingBenchmarkValidation
    func tearDown() async
}

/// A deterministic, offscreen Metal ray-tracing workload.
///
/// The scene is generated in memory as a tiled triangle plane. Pipeline creation,
/// geometry generation, resource allocation, and an unscored warm-up are excluded
/// from both metrics. The two published samples use Metal command-buffer GPU time:
/// acceleration-structure build throughput in Mtri/s and traversal throughput in
/// Mray/s. Only Apple GPU family 9 or 10 devices that also report
/// `supportsRaytracing` are identified as hardware ray tracing.
struct MetalRayTracingBenchmarkKernel: Sendable {
    static let maximumTriangleCount = 524_288
    static let maximumRayCount = 1_048_576
    static let maximumTraversalPassCount = 256
    static let maximumTotalRayCount: UInt64 = 268_435_456
    static let maximumElapsedSeconds = 30.0

    struct Limits: Equatable, Sendable {
        let triangleCount: Int
        let rayCount: Int
        let traversalPassCount: Int
        let maximumElapsedSeconds: Double
    }

    struct Configuration: Equatable, Sendable {
        let limits: Limits

        static let standard = Self(
            limits: Limits(
                triangleCount: 131_072,
                rayCount: 262_144,
                traversalPassCount: 64,
                maximumElapsedSeconds: 20
            )
        )

        static let testing = Self(
            limits: Limits(
                triangleCount: 8_192,
                rayCount: 4_096,
                traversalPassCount: 2,
                maximumElapsedSeconds: 8
            )
        )
    }

    struct RunResult: Equatable, Sendable {
        let buildSample: BenchmarkComponentSample
        let traversalSample: BenchmarkComponentSample
        let triangleCount: Int
        let rayCount: Int
        let traversalPassCount: Int
        let hitCount: Int
        let hardwareFamily: MetalRayTracingHardwareFamily
        let ranOnMainThread: Bool
    }

    let configuration: Configuration
    private let clock: any BenchmarkKernelClock
    private let driverFactory: @Sendable () -> any MetalRayTracingBenchmarkDriving

    init(
        configuration: Configuration = .standard,
        clock: any BenchmarkKernelClock = SystemBenchmarkKernelClock(),
        driverFactory: @escaping @Sendable () -> any MetalRayTracingBenchmarkDriving = {
            SystemMetalRayTracingBenchmarkDriver()
        }
    ) {
        self.configuration = configuration
        self.clock = clock
        self.driverFactory = driverFactory
    }

    func run() async throws -> RunResult {
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

private extension MetalRayTracingBenchmarkKernel {
    static func validate(_ limits: Limits) throws {
        guard limits.triangleCount >= 2,
              limits.triangleCount <= maximumTriangleCount,
              limits.triangleCount.isMultiple(of: 2),
              exactSquareRoot(limits.triangleCount / 2) != nil,
              limits.rayCount >= 64,
              limits.rayCount <= maximumRayCount,
              exactSquareRoot(limits.rayCount) != nil,
              limits.traversalPassCount > 0,
              limits.traversalPassCount <= maximumTraversalPassCount,
              limits.maximumElapsedSeconds.isFinite,
              limits.maximumElapsedSeconds > 0,
              limits.maximumElapsedSeconds <= maximumElapsedSeconds
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        let (totalRays, overflow) = UInt64(limits.rayCount)
            .multipliedReportingOverflow(by: UInt64(limits.traversalPassCount))
        guard !overflow, totalRays <= maximumTotalRayCount else {
            throw BenchmarkKernelError.resourceLimit
        }
    }

    static func exactSquareRoot(_ value: Int) -> Int? {
        guard value > 0 else { return nil }
        let root = Int(Double(value).squareRoot())
        for candidate in max(1, root - 1)...(root + 1) where candidate * candidate == value {
            return candidate
        }
        return nil
    }

    static func runDetached(
        limits: Limits,
        clock: any BenchmarkKernelClock,
        driverFactory: @Sendable () -> any MetalRayTracingBenchmarkDriving
    ) async throws -> RunResult {
        let safetyStartedAt = clock.nowNanoseconds()
        let driver = driverFactory()
        let workload = MetalRayTracingBenchmarkWorkload(
            triangleCount: limits.triangleCount,
            rayCount: limits.rayCount,
            traversalPassCount: limits.traversalPassCount
        )
        var didTearDown = false

        do {
            try Task.checkCancellation()
            let hardwareFamily = try await driver.prepare(workload: workload)
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

            let buildExecution = try await driver.executeBuild()
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )
            let traversalExecution = try await driver.executeTraversal()
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )
            let validation = try await driver.validate()
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )

            let buildElapsed = buildExecution.gpuElapsedSeconds
            let traversalElapsed = traversalExecution.gpuElapsedSeconds
            let (totalRays, rayOverflow) = UInt64(limits.rayCount)
                .multipliedReportingOverflow(by: UInt64(limits.traversalPassCount))
            guard !rayOverflow,
                  totalRays > 0,
                  buildElapsed.isFinite,
                  buildElapsed > 0,
                  traversalElapsed.isFinite,
                  traversalElapsed > 0,
                  validation.buildChecksum != 0,
                  validation.traversalChecksum != 0,
                  validation.hitCount > 0,
                  validation.hitCount < limits.rayCount
            else {
                throw BenchmarkKernelError.invalidMetric
            }

            let buildThroughput = (Double(limits.triangleCount) / 1_000_000)
                / buildElapsed
            let traversalThroughput = (Double(totalRays) / 1_000_000)
                / traversalElapsed
            guard buildThroughput.isFinite,
                  buildThroughput > 0,
                  traversalThroughput.isFinite,
                  traversalThroughput > 0
            else {
                throw BenchmarkKernelError.invalidMetric
            }

            await driver.tearDown()
            didTearDown = true
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )

            return RunResult(
                buildSample: BenchmarkComponentSample(
                    value: buildThroughput,
                    elapsedSeconds: buildElapsed,
                    checksum: validation.buildChecksum
                ),
                traversalSample: BenchmarkComponentSample(
                    value: traversalThroughput,
                    elapsedSeconds: traversalElapsed,
                    checksum: validation.traversalChecksum
                ),
                triangleCount: limits.triangleCount,
                rayCount: limits.rayCount,
                traversalPassCount: limits.traversalPassCount,
                hitCount: validation.hitCount,
                hardwareFamily: hardwareFamily,
                ranOnMainThread: buildExecution.ranOnMainThread
                    || traversalExecution.ranOnMainThread
            )
        } catch {
            if !didTearDown {
                await driver.tearDown()
            }
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if let workloadError = error as? MacAcceleratorWorkloadError {
                throw workloadError
            }
            if let kernelError = error as? BenchmarkKernelError {
                throw kernelError
            }
            throw BenchmarkKernelError.systemFailure
        }
    }

    static func checkSafetyBoundary(
        clock: any BenchmarkKernelClock,
        startedAt: UInt64,
        maximumElapsedSeconds: Double
    ) throws {
        try Task.checkCancellation()
        let finishedAt = clock.nowNanoseconds()
        guard finishedAt >= startedAt,
              Double(finishedAt - startedAt) / 1_000_000_000
                <= maximumElapsedSeconds
        else {
            throw BenchmarkKernelError.resourceLimit
        }
    }
}

private actor SystemMetalRayTracingBenchmarkDriver: MetalRayTracingBenchmarkDriving {
    private static let sceneHalfExtent: Float = 0.7
    private static let rayOffsetX: Float = 0.000_731
    private static let rayOffsetY: Float = -0.000_419
    private static let checksumSeed: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let checksumPrime: UInt64 = 0x0000_0100_0000_01B3
    private static let commandBufferTraversalBatchSize = 16

    private var device: (any MTLDevice)?
    private var commandQueue: (any MTLCommandQueue)?
    private var pipeline: (any MTLComputePipelineState)?
    private var vertexBuffer: (any MTLBuffer)?
    private var outputBuffer: (any MTLBuffer)?
    private var scratchBuffer: (any MTLBuffer)?
    private var accelerationStructure: (any MTLAccelerationStructure)?
    private var accelerationDescriptor: MTLPrimitiveAccelerationStructureDescriptor?
    private var accelerationSizes: MTLAccelerationStructureSizes?
    private var workload: MetalRayTracingBenchmarkWorkload?
    private var rayGridWidth = 0
    private var geometryChecksum: UInt64 = 0

    func prepare(
        workload: MetalRayTracingBenchmarkWorkload
    ) throws -> MetalRayTracingHardwareFamily {
        try Task.checkCancellation()
        guard let device = MTLCreateSystemDefaultDevice(),
              let hardwareFamily = Self.hardwareFamily(for: device) else {
            throw BenchmarkKernelError.unavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MacAcceleratorWorkloadError.temporarilyUnavailable
        }
        guard let triangleGridWidth = MetalRayTracingBenchmarkKernel
                .exactSquareRoot(workload.triangleCount / 2),
              let rayGridWidth = MetalRayTracingBenchmarkKernel
                .exactSquareRoot(workload.rayCount)
        else {
            throw BenchmarkKernelError.invalidConfiguration
        }

        let vertices = try Self.makeSceneVertices(gridWidth: triangleGridWidth)
        let vertexLength = vertices.count.multipliedReportingOverflow(
            by: MemoryLayout<SIMD3<Float>>.stride
        )
        let outputLength = workload.rayCount.multipliedReportingOverflow(
            by: MemoryLayout<UInt32>.stride
        )
        guard !vertexLength.overflow,
              !outputLength.overflow,
              vertexLength.partialValue > 0,
              outputLength.partialValue > 0,
              vertexLength.partialValue <= device.maxBufferLength,
              outputLength.partialValue <= device.maxBufferLength
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        let vertexBuffer = vertices.withUnsafeBytes { bytes -> (any MTLBuffer)? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
        guard let vertexBuffer,
              let outputBuffer = device.makeBuffer(
                length: outputLength.partialValue,
                options: .storageModeShared
              )
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        let pipeline: any MTLComputePipelineState
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let function = library.makeFunction(name: "benchmark_trace_rays") else {
                throw BenchmarkKernelError.systemFailure
            }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch let error as BenchmarkKernelError {
            throw error
        } catch {
            throw BenchmarkKernelError.systemFailure
        }

        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = vertexBuffer
        geometry.vertexBufferOffset = 0
        geometry.vertexFormat = .float3
        geometry.vertexStride = MemoryLayout<SIMD3<Float>>.stride
        geometry.triangleCount = workload.triangleCount
        geometry.opaque = true

        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [geometry]
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard sizes.accelerationStructureSize > 0,
              sizes.buildScratchBufferSize > 0,
              sizes.accelerationStructureSize <= device.maxBufferLength,
              sizes.buildScratchBufferSize <= device.maxBufferLength,
              let scratchBuffer = device.makeBuffer(
                length: sizes.buildScratchBufferSize,
                options: .storageModePrivate
              )
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.vertexBuffer = vertexBuffer
        self.outputBuffer = outputBuffer
        self.scratchBuffer = scratchBuffer
        accelerationDescriptor = descriptor
        accelerationSizes = sizes
        self.workload = workload
        self.rayGridWidth = rayGridWidth
        geometryChecksum = Self.geometryChecksum(vertices)
        guard geometryChecksum != 0 else {
            throw BenchmarkKernelError.checksumMismatch
        }
        return hardwareFamily
    }

    func warmUp() throws {
        let (warmAccelerationStructure, _) = try buildNewAccelerationStructure()
        _ = try trace(
            accelerationStructure: warmAccelerationStructure,
            passCount: 1
        )
        try Task.checkCancellation()
    }

    func executeBuild() throws -> MetalRayTracingBenchmarkExecution {
        let (accelerationStructure, execution) = try buildNewAccelerationStructure()
        self.accelerationStructure = accelerationStructure
        return execution
    }

    func executeTraversal() throws -> MetalRayTracingBenchmarkExecution {
        guard let accelerationStructure, let workload else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        return try trace(
            accelerationStructure: accelerationStructure,
            passCount: workload.traversalPassCount
        )
    }

    func validate() throws -> MetalRayTracingBenchmarkValidation {
        guard accelerationStructure != nil,
              let outputBuffer,
              let workload,
              rayGridWidth > 0,
              geometryChecksum != 0
        else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        try Task.checkCancellation()

        let output = outputBuffer.contents().assumingMemoryBound(to: UInt32.self)
        var checksum = Self.checksumSeed
        var hitCount = 0
        for index in 0..<workload.rayCount {
            if index.isMultiple(of: 16_384) {
                try Task.checkCancellation()
            }
            let expected = Self.expectedHit(index: index, gridWidth: rayGridWidth)
            let actual = output[index]
            guard actual == expected else {
                throw BenchmarkKernelError.checksumMismatch
            }
            if actual == 1 { hitCount += 1 }
            checksum = Self.mixChecksum(checksum, value: actual, index: index)
        }
        guard hitCount > 0,
              hitCount < workload.rayCount,
              checksum != 0 else {
            throw BenchmarkKernelError.checksumMismatch
        }
        return MetalRayTracingBenchmarkValidation(
            buildChecksum: geometryChecksum,
            traversalChecksum: checksum,
            hitCount: hitCount
        )
    }

    func tearDown() {
        accelerationStructure = nil
        scratchBuffer = nil
        outputBuffer = nil
        vertexBuffer = nil
        pipeline = nil
        commandQueue = nil
        device = nil
        accelerationDescriptor = nil
        accelerationSizes = nil
        workload = nil
        rayGridWidth = 0
        geometryChecksum = 0
    }
}

private extension SystemMetalRayTracingBenchmarkDriver {
    static func hardwareFamily(
        for device: any MTLDevice
    ) -> MetalRayTracingHardwareFamily? {
        guard device.supportsRaytracing else { return nil }
#if compiler(>=6.2)
        if device.supportsFamily(.apple10) { return .apple10 }
#endif
        if device.supportsFamily(.apple9) { return .apple9 }
        return nil
    }

    static func makeSceneVertices(gridWidth: Int) throws -> [SIMD3<Float>] {
        guard gridWidth > 0 else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        let (cellCount, cellOverflow) = gridWidth.multipliedReportingOverflow(
            by: gridWidth
        )
        let (vertexCount, vertexOverflow) = cellCount.multipliedReportingOverflow(by: 6)
        guard !cellOverflow,
              !vertexOverflow,
              vertexCount > 0 else {
            throw BenchmarkKernelError.resourceLimit
        }

        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(vertexCount)
        let step = (sceneHalfExtent * 2) / Float(gridWidth)
        for y in 0..<gridWidth {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            let y0 = -sceneHalfExtent + Float(y) * step
            let y1 = y0 + step
            for x in 0..<gridWidth {
                let x0 = -sceneHalfExtent + Float(x) * step
                let x1 = x0 + step
                let lowerLeft = SIMD3<Float>(x0, y0, 0)
                let lowerRight = SIMD3<Float>(x1, y0, 0)
                let upperLeft = SIMD3<Float>(x0, y1, 0)
                let upperRight = SIMD3<Float>(x1, y1, 0)
                vertices.append(lowerLeft)
                vertices.append(lowerRight)
                vertices.append(upperRight)
                vertices.append(lowerLeft)
                vertices.append(upperRight)
                vertices.append(upperLeft)
            }
        }
        return vertices
    }

    static func geometryChecksum(_ vertices: [SIMD3<Float>]) -> UInt64 {
        var checksum = checksumSeed
        for (index, vertex) in vertices.enumerated() {
            checksum = mixChecksum(checksum, value: vertex.x.bitPattern, index: index * 3)
            checksum = mixChecksum(checksum, value: vertex.y.bitPattern, index: index * 3 + 1)
            checksum = mixChecksum(checksum, value: vertex.z.bitPattern, index: index * 3 + 2)
        }
        return checksum
    }

    static func expectedHit(index: Int, gridWidth: Int) -> UInt32 {
        let x = index % gridWidth
        let y = index / gridWidth
        let normalizedX = ((Float(x) + 0.5) / Float(gridWidth)) * 2 - 1
        let normalizedY = ((Float(y) + 0.5) / Float(gridWidth)) * 2 - 1
        let rayX = normalizedX + rayOffsetX
        let rayY = normalizedY + rayOffsetY
        return abs(rayX) < sceneHalfExtent && abs(rayY) < sceneHalfExtent ? 1 : 0
    }

    static func mixChecksum(
        _ checksum: UInt64,
        value: UInt32,
        index: Int
    ) -> UInt64 {
        var mixed = checksum
        mixed ^= UInt64(value) &+ UInt64(index) &* 0x9E37_79B9
        mixed &*= checksumPrime
        return (mixed << 11) | (mixed >> 53)
    }

    func buildNewAccelerationStructure() throws
        -> (any MTLAccelerationStructure, MetalRayTracingBenchmarkExecution)
    {
        guard let device,
              let commandQueue,
              let scratchBuffer,
              let descriptor = accelerationDescriptor,
              let sizes = accelerationSizes,
              let accelerationStructure = device.makeAccelerationStructure(
                size: sizes.accelerationStructureSize
              ),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeAccelerationStructureCommandEncoder()
        else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        try Task.checkCancellation()
        let ranOnMainThread = benchmarkKernelIsMainThread()
        encoder.build(
            accelerationStructure: accelerationStructure,
            descriptor: descriptor,
            scratchBuffer: scratchBuffer,
            scratchBufferOffset: 0
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return (
            accelerationStructure,
            try Self.completedExecution(
                commandBuffer: commandBuffer,
                ranOnMainThread: ranOnMainThread
            )
        )
    }

    func trace(
        accelerationStructure: any MTLAccelerationStructure,
        passCount: Int
    ) throws -> MetalRayTracingBenchmarkExecution {
        guard let commandQueue,
              let pipeline,
              let outputBuffer,
              let workload,
              rayGridWidth > 0,
              passCount > 0
        else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        try Task.checkCancellation()
        let threadsPerThreadgroup = MTLSize(
            width: max(
                1,
                min(
                    pipeline.maxTotalThreadsPerThreadgroup,
                    pipeline.threadExecutionWidth * 4
                )
            ),
            height: 1,
            depth: 1
        )
        let grid = MTLSize(width: workload.rayCount, height: 1, depth: 1)
        var completedPassCount = 0
        var totalGPUElapsedSeconds = 0.0
        var ranOnMainThread = false
        while completedPassCount < passCount {
            try Task.checkCancellation()
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw MacAcceleratorWorkloadError.temporarilyUnavailable
            }
            ranOnMainThread = ranOnMainThread || benchmarkKernelIsMainThread()
            var gridWidth = UInt32(rayGridWidth)
            encoder.setComputePipelineState(pipeline)
            encoder.setAccelerationStructure(accelerationStructure, bufferIndex: 0)
            encoder.setBuffer(outputBuffer, offset: 0, index: 1)
            encoder.setBytes(
                &gridWidth,
                length: MemoryLayout<UInt32>.stride,
                index: 2
            )
            let batchCount = min(
                Self.commandBufferTraversalBatchSize,
                passCount - completedPassCount
            )
            for _ in 0..<batchCount {
                encoder.dispatchThreads(grid, threadsPerThreadgroup: threadsPerThreadgroup)
            }
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let execution = try Self.completedExecution(
                commandBuffer: commandBuffer,
                ranOnMainThread: ranOnMainThread
            )
            totalGPUElapsedSeconds += execution.gpuElapsedSeconds
            completedPassCount += batchCount
        }
        guard totalGPUElapsedSeconds.isFinite,
              totalGPUElapsedSeconds > 0 else {
            throw BenchmarkKernelError.invalidMetric
        }
        return MetalRayTracingBenchmarkExecution(
            gpuElapsedSeconds: totalGPUElapsedSeconds,
            ranOnMainThread: ranOnMainThread
        )
    }

    static func completedExecution(
        commandBuffer: any MTLCommandBuffer,
        ranOnMainThread: Bool
    ) throws -> MetalRayTracingBenchmarkExecution {
        guard commandBuffer.status == .completed,
              commandBuffer.error == nil else {
            throw BenchmarkKernelError.systemFailure
        }
        try Task.checkCancellation()
        let elapsed = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        guard elapsed.isFinite, elapsed > 0 else {
            throw BenchmarkKernelError.invalidMetric
        }
        return MetalRayTracingBenchmarkExecution(
            gpuElapsedSeconds: elapsed,
            ranOnMainThread: ranOnMainThread
        )
    }

    static let shaderSource = """
    #include <metal_stdlib>
    #include <metal_raytracing>
    using namespace metal;
    using namespace metal::raytracing;

    kernel void benchmark_trace_rays(
        primitive_acceleration_structure scene [[buffer(0)]],
        device uint *hits [[buffer(1)]],
        constant uint &rayGridWidth [[buffer(2)]],
        uint tid [[thread_position_in_grid]])
    {
        uint x = tid % rayGridWidth;
        uint y = tid / rayGridWidth;
        float2 normalized = ((float2(float(x), float(y)) + 0.5f)
            / float(rayGridWidth)) * 2.0f - 1.0f;
        normalized += float2(0.000731f, -0.000419f);

        ray queryRay;
        queryRay.origin = float3(normalized, 1.0f);
        queryRay.direction = float3(0.0f, 0.0f, -1.0f);
        queryRay.min_distance = 0.001f;
        queryRay.max_distance = 2.0f;

        intersector<triangle_data> rayIntersector;
        rayIntersector.assume_geometry_type(geometry_type::triangle);
        intersection_result<triangle_data> intersection = rayIntersector.intersect(
            queryRay,
            scene
        );
        hits[tid] = intersection.type == intersection_type::triangle ? 1u : 0u;
    }
    """
}
