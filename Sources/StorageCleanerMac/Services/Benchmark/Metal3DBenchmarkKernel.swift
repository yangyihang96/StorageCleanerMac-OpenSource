@preconcurrency import Metal
import Foundation

struct Metal3DBenchmarkWorkload: Equatable, Sendable {
    let width: Int
    let height: Int
    let instanceCount: Int
    let frameCount: Int
    let trianglesPerInstance: Int
}

struct Metal3DBenchmarkExecution: Equatable, Sendable {
    /// GPU timeline elapsed time when Metal exposes it, otherwise the bounded
    /// submission-to-completion wall time retained below is used for the
    /// throughput sample and explicitly marked as a fallback.
    let gpuElapsedSeconds: Double
    let wallElapsedSeconds: Double?
    let usedWallClockFallback: Bool
    let ranOnMainThread: Bool

    init(
        gpuElapsedSeconds: Double,
        wallElapsedSeconds: Double? = nil,
        usedWallClockFallback: Bool = false,
        ranOnMainThread: Bool
    ) {
        self.gpuElapsedSeconds = gpuElapsedSeconds
        self.wallElapsedSeconds = wallElapsedSeconds
        self.usedWallClockFallback = usedWallClockFallback
        self.ranOnMainThread = ranOnMainThread
    }
}

protocol Metal3DBenchmarkDriving: Sendable {
    func prepare(workload: Metal3DBenchmarkWorkload) async throws
    func warmUp() async throws
    func execute() async throws -> Metal3DBenchmarkExecution
    func validate() async throws -> UInt64
    func tearDown() async
}

/// A deterministic offscreen 3D render workload. The scored value comes from
/// Metal command-buffer GPU time, so window size, occlusion and display refresh
/// rate do not change the result.
struct Metal3DBenchmarkKernel: Sendable {
    static let trianglesPerInstance = 12
    static let maximumWidth = 2_560
    static let maximumHeight = 1_440
    static let maximumInstanceCount = 262_144
    static let maximumFrameCount = 600
    static let maximumElapsedSeconds = 20.0

    struct Limits: Equatable, Sendable {
        let width: Int
        let height: Int
        let instanceCount: Int
        let frameCount: Int
        let maximumElapsedSeconds: Double
    }

    struct Configuration: Equatable, Sendable {
        let limits: Limits

        static let standard = Self(
            limits: Limits(
                width: 1_920,
                height: 1_080,
                instanceCount: 262_144,
                frameCount: 600,
                maximumElapsedSeconds: Metal3DBenchmarkKernel.maximumElapsedSeconds
            )
        )

        static let testing = Self(
            limits: Limits(
                width: 320,
                height: 180,
                instanceCount: 256,
                frameCount: 3,
                maximumElapsedSeconds: 3
            )
        )
    }

    struct RunResult: Equatable, Sendable {
        let sample: BenchmarkComponentSample
        let wallElapsedSeconds: Double?
        let gpuTimingWasReliable: Bool
        let triangleCount: UInt64
        let resolution: BenchmarkRenderResolution
        let instanceCount: Int
        let frameCount: Int
        let ranOnMainThread: Bool
    }

    struct BenchmarkRenderResolution: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    let configuration: Configuration
    private let clock: any BenchmarkKernelClock
    private let driverFactory: @Sendable () -> any Metal3DBenchmarkDriving

    init(
        configuration: Configuration = .standard,
        clock: any BenchmarkKernelClock = SystemBenchmarkKernelClock(),
        driverFactory: @escaping @Sendable () -> any Metal3DBenchmarkDriving = {
            SystemMetal3DBenchmarkDriver()
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

private extension Metal3DBenchmarkKernel {
    static func validate(_ limits: Limits) throws {
        guard limits.width >= 128,
              limits.width <= maximumWidth,
              limits.height >= 128,
              limits.height <= maximumHeight,
              limits.instanceCount >= 64,
              limits.instanceCount <= maximumInstanceCount,
              limits.frameCount > 0,
              limits.frameCount <= maximumFrameCount,
              limits.maximumElapsedSeconds.isFinite,
              limits.maximumElapsedSeconds > 0,
              limits.maximumElapsedSeconds <= maximumElapsedSeconds
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        let (trianglesPerFrame, firstOverflow) = UInt64(limits.instanceCount)
            .multipliedReportingOverflow(by: UInt64(trianglesPerInstance))
        let (_, secondOverflow) = trianglesPerFrame
            .multipliedReportingOverflow(by: UInt64(limits.frameCount))
        guard !firstOverflow, !secondOverflow else {
            throw BenchmarkKernelError.resourceLimit
        }
    }

    static func runDetached(
        limits: Limits,
        clock: any BenchmarkKernelClock,
        driverFactory: @Sendable () -> any Metal3DBenchmarkDriving
    ) async throws -> RunResult {
        let safetyStartedAt = clock.nowNanoseconds()
        let driver = driverFactory()
        let workload = Metal3DBenchmarkWorkload(
            width: limits.width,
            height: limits.height,
            instanceCount: limits.instanceCount,
            frameCount: limits.frameCount,
            trianglesPerInstance: trianglesPerInstance
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

            let (trianglesPerFrame, firstOverflow) = UInt64(limits.instanceCount)
                .multipliedReportingOverflow(by: UInt64(trianglesPerInstance))
            let (triangleCount, secondOverflow) = trianglesPerFrame
                .multipliedReportingOverflow(by: UInt64(limits.frameCount))
            let elapsedSeconds = execution.gpuElapsedSeconds
            guard !firstOverflow,
                  !secondOverflow,
                  elapsedSeconds.isFinite,
                  elapsedSeconds > 0
            else {
                throw BenchmarkKernelError.invalidMetric
            }
            let throughput = (Double(triangleCount) / 1_000_000) / elapsedSeconds
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
                wallElapsedSeconds: execution.wallElapsedSeconds,
                gpuTimingWasReliable: !execution.usedWallClockFallback,
                triangleCount: triangleCount,
                resolution: BenchmarkRenderResolution(width: limits.width, height: limits.height),
                instanceCount: limits.instanceCount,
                frameCount: limits.frameCount,
                ranOnMainThread: execution.ranOnMainThread
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

private actor SystemMetal3DBenchmarkDriver: Metal3DBenchmarkDriving {
    private static let clearRed: Double = 0.025
    private static let clearGreen: Double = 0.04
    private static let clearBlue: Double = 0.08

    private var device: (any MTLDevice)?
    private var commandQueue: (any MTLCommandQueue)?
    private var pipeline: (any MTLRenderPipelineState)?
    private var depthState: (any MTLDepthStencilState)?
    private var colorTexture: (any MTLTexture)?
    private var depthTexture: (any MTLTexture)?
    private var readbackBuffer: (any MTLBuffer)?
    private var workload: Metal3DBenchmarkWorkload?
    private var bytesPerRow = 0

    func prepare(workload: Metal3DBenchmarkWorkload) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            throw BenchmarkKernelError.unavailable
        }

        let library: any MTLLibrary
        let pipeline: any MTLRenderPipelineState
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertex = library.makeFunction(name: "benchmark_3d_vertex"),
                  let fragment = library.makeFunction(name: "benchmark_3d_fragment")
            else {
                throw BenchmarkKernelError.systemFailure
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch let error as BenchmarkKernelError {
            throw error
        } catch {
            throw BenchmarkKernelError.systemFailure
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw BenchmarkKernelError.systemFailure
        }

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: workload.width,
            height: workload.height,
            mipmapped: false
        )
        colorDescriptor.storageMode = .private
        colorDescriptor.usage = [.renderTarget]
        let depthTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: workload.width,
            height: workload.height,
            mipmapped: false
        )
        depthTextureDescriptor.storageMode = .private
        depthTextureDescriptor.usage = [.renderTarget]

        let unalignedBytesPerRow = workload.width * 4
        let bytesPerRow = ((unalignedBytesPerRow + 255) / 256) * 256
        let (bufferLength, overflow) = bytesPerRow
            .multipliedReportingOverflow(by: workload.height)
        guard !overflow,
              let colorTexture = device.makeTexture(descriptor: colorDescriptor),
              let depthTexture = device.makeTexture(descriptor: depthTextureDescriptor),
              let readbackBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared)
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.depthState = depthState
        self.colorTexture = colorTexture
        self.depthTexture = depthTexture
        self.readbackBuffer = readbackBuffer
        self.workload = workload
        self.bytesPerRow = bytesPerRow
    }

    func warmUp() throws {
        guard let workload else { throw BenchmarkKernelError.invalidConfiguration }
        // A few frames only compile the pipeline; they do not give Apple Silicon
        // enough time to settle its dynamic GPU performance state. Use a bounded
        // unscored warm-up so each scored sample starts from a comparable state.
        _ = try render(frameCount: min(180, workload.frameCount), copyFinalFrame: false)
    }

    func execute() throws -> Metal3DBenchmarkExecution {
        guard let workload else { throw BenchmarkKernelError.invalidConfiguration }
        return try render(frameCount: workload.frameCount, copyFinalFrame: true)
    }

    func validate() throws -> UInt64 {
        guard let readbackBuffer, let workload, bytesPerRow > 0 else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        try Task.checkCancellation()
        let bytes = readbackBuffer.contents().assumingMemoryBound(to: UInt8.self)
        var checksum: UInt64 = 0xCBF2_9CE4_8422_2325
        var renderedSampleCount = 0
        for y in stride(from: 0, to: workload.height, by: 3) {
            if y.isMultiple(of: 48) { try Task.checkCancellation() }
            for x in stride(from: 0, to: workload.width, by: 3) {
                let offset = y * bytesPerRow + x * 4
                let red = bytes[offset]
                let green = bytes[offset + 1]
                let blue = bytes[offset + 2]
                if red > 32 || green > 32 || blue > 40 {
                    renderedSampleCount += 1
                }
                checksum ^= UInt64(red)
                    | (UInt64(green) << 8)
                    | (UInt64(blue) << 16)
                    | (UInt64(bytes[offset + 3]) << 24)
                let mixed = checksum &* 0x0000_0100_0000_01B3
                checksum = (mixed << 11) | (mixed >> 53)
            }
        }
        guard renderedSampleCount >= 64, checksum != 0 else {
            throw BenchmarkKernelError.checksumMismatch
        }
        return checksum
    }

    func tearDown() {
        readbackBuffer = nil
        depthTexture = nil
        colorTexture = nil
        depthState = nil
        pipeline = nil
        commandQueue = nil
        device = nil
        workload = nil
        bytesPerRow = 0
    }
}

private extension SystemMetal3DBenchmarkDriver {
    func render(frameCount: Int, copyFinalFrame: Bool) throws -> Metal3DBenchmarkExecution {
        guard let commandQueue,
              let pipeline,
              let depthState,
              let colorTexture,
              let depthTexture,
              let readbackBuffer,
              let workload,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            throw BenchmarkKernelError.invalidConfiguration
        }

        let ranOnMainThread = benchmarkKernelIsMainThread()
        let wallStartedAt = DispatchTime.now().uptimeNanoseconds
        let gridWidth = UInt32(ceil(sqrt(Double(workload.instanceCount))))
        var mutableGridWidth = gridWidth
        var aspectScale = Float(workload.height) / Float(workload.width)

        for frame in 0..<frameCount {
            if frame.isMultiple(of: 8) { try Task.checkCancellation() }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = colorTexture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = frame == frameCount - 1 && copyFinalFrame
                ? .store
                : .dontCare
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: Self.clearRed,
                green: Self.clearGreen,
                blue: Self.clearBlue,
                alpha: 1
            )
            pass.depthAttachment.texture = depthTexture
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw BenchmarkKernelError.systemFailure
            }
            var phase = Float(frame) * 0.041_887_9
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBytes(
                &mutableGridWidth,
                length: MemoryLayout<UInt32>.stride,
                index: 0
            )
            encoder.setVertexBytes(&phase, length: MemoryLayout<Float>.stride, index: 1)
            encoder.setVertexBytes(&aspectScale, length: MemoryLayout<Float>.stride, index: 2)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 36,
                instanceCount: workload.instanceCount
            )
            encoder.endEncoding()
        }

        if copyFinalFrame {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw BenchmarkKernelError.systemFailure
            }
            blit.copy(
                from: colorTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: workload.width, height: workload.height, depth: 1),
                to: readbackBuffer,
                destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerRow * workload.height
            )
            blit.endEncoding()
        }

        commandBuffer.commit()
        // Metal command buffers cannot be cancelled safely once submitted. Waiting here
        // guarantees no benchmark GPU work survives the benchmark lease or cancellation.
        commandBuffer.waitUntilCompleted()
        let wallFinishedAt = DispatchTime.now().uptimeNanoseconds
        guard commandBuffer.status == .completed, commandBuffer.error == nil else {
            throw BenchmarkKernelError.systemFailure
        }
        try Task.checkCancellation()

        let gpuElapsed = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        let wallElapsed = Double(wallFinishedAt - wallStartedAt) / 1_000_000_000
        let hasReliableGPUTiming = gpuElapsed.isFinite && gpuElapsed > 0
        let elapsed = hasReliableGPUTiming ? gpuElapsed : wallElapsed
        guard elapsed.isFinite, elapsed > 0 else {
            throw BenchmarkKernelError.invalidMetric
        }
        return Metal3DBenchmarkExecution(
            gpuElapsedSeconds: elapsed,
            wallElapsedSeconds: wallElapsed,
            usedWallClockFallback: !hasReliableGPUTiming,
            ranOnMainThread: ranOnMainThread
        )
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BenchmarkVertexOut {
        float4 position [[position]];
        half3 color;
        float3 normal;
    };

    float2 benchmark_cube_corner(uint corner) {
        switch (corner) {
            case 0: return float2(-1.0, -1.0);
            case 1: return float2( 1.0, -1.0);
            case 2: return float2( 1.0,  1.0);
            case 3: return float2(-1.0, -1.0);
            case 4: return float2( 1.0,  1.0);
            default: return float2(-1.0,  1.0);
        }
    }

    vertex BenchmarkVertexOut benchmark_3d_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant uint &gridWidth [[buffer(0)]],
        constant float &phase [[buffer(1)]],
        constant float &aspectScale [[buffer(2)]])
    {
        uint face = vertexID / 6;
        float2 corner = benchmark_cube_corner(vertexID % 6);
        float3 normal;
        float3 tangent;
        float3 bitangent;
        switch (face) {
            case 0: normal = float3( 1, 0, 0); tangent = float3(0, 1, 0); bitangent = float3(0, 0, 1); break;
            case 1: normal = float3(-1, 0, 0); tangent = float3(0, 1, 0); bitangent = float3(0, 0,-1); break;
            case 2: normal = float3(0,  1, 0); tangent = float3(1, 0, 0); bitangent = float3(0, 0,-1); break;
            case 3: normal = float3(0, -1, 0); tangent = float3(1, 0, 0); bitangent = float3(0, 0, 1); break;
            case 4: normal = float3(0, 0,  1); tangent = float3(1, 0, 0); bitangent = float3(0, 1, 0); break;
            default: normal = float3(0, 0, -1); tangent = float3(-1, 0, 0); bitangent = float3(0, 1, 0); break;
        }

        uint gridX = instanceID % gridWidth;
        uint gridY = instanceID / gridWidth;
        float2 grid = (float2(gridX, gridY) + 0.5) / float(gridWidth);
        float2 center = grid * 1.9 - 0.95;
        float seed = float(instanceID) * 0.0174532925;
        float angleY = phase + seed;
        float angleX = phase * 0.73 + seed * 0.37;
        float sy = sin(angleY), cy = cos(angleY);
        float sx = sin(angleX), cx = cos(angleX);
        float3 local = normal + tangent * corner.x + bitangent * corner.y;
        float3 rotated = float3(
            local.x * cy + local.z * sy,
            local.y,
            -local.x * sy + local.z * cy
        );
        rotated = float3(
            rotated.x,
            rotated.y * cx - rotated.z * sx,
            rotated.y * sx + rotated.z * cx
        );
        float cubeScale = 0.64 / float(gridWidth);
        float wave = sin(center.x * 8.0 + phase) * cos(center.y * 7.0 - phase * 0.8);
        float3 world = float3(
            center.x + rotated.x * cubeScale * aspectScale,
            center.y + rotated.y * cubeScale,
            0.52 + wave * 0.16 + rotated.z * cubeScale
        );

        BenchmarkVertexOut out;
        out.position = float4(world, 1.0);
        float hue = fract(float(instanceID) * 0.61803398875 + phase * 0.04);
        out.color = half3(
            0.22 + 0.68 * hue,
            0.36 + 0.52 * (1.0 - hue),
            0.82 + 0.16 * wave
        );
        out.normal = normalize(rotated);
        return out;
    }

    fragment half4 benchmark_3d_fragment(BenchmarkVertexOut in [[stage_in]]) {
        float light = 0.30 + 0.70 * max(0.0, dot(normalize(in.normal), normalize(float3(0.4, 0.7, 0.6))));
        return half4(in.color * half(light), 1.0);
    }
    """
}
