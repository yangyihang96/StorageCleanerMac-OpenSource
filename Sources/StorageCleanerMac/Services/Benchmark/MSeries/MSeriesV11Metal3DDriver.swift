@preconcurrency import Metal
import Foundation

// The v6 source fingerprint covers Metal3DBenchmarkKernel.swift byte-for-byte.
// Its driver is file-private. Keep this v11 copy identical to that frozen
// renderer except for type names and the continuous-clock timing envelope.
// MSeriesV11KernelBoundaryTests guards shader, render, validation and draining.
struct MSeriesV11Metal3DExecution: Equatable, Sendable {
    /// GPU timeline elapsed time when Metal exposes it, otherwise the bounded
    /// submission-to-completion wall time retained below is used for the
    /// throughput sample and explicitly marked as a fallback.
    let gpuElapsedSeconds: Double
    let wallElapsedSeconds: Double?
    let usedWallClockFallback: Bool
    let ranOnMainThread: Bool
    var startMonotonicNs: UInt64? = nil
    var endMonotonicNs: UInt64? = nil

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

protocol MSeriesV11Metal3DDriving: Sendable {
    func prepare(workload: Metal3DBenchmarkWorkload) async throws
    func warmUp() async throws
    func execute() async throws -> MSeriesV11Metal3DExecution
    func validate() async throws -> UInt64
    func tearDown() async
}

extension Metal3DBenchmarkKernel {
    static func makeV11Driver() -> any MSeriesV11Metal3DDriving { SystemMSeriesV11Metal3DDriver() }
}

private actor SystemMSeriesV11Metal3DDriver: MSeriesV11Metal3DDriving {
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

    func execute() throws -> MSeriesV11Metal3DExecution {
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

private extension SystemMSeriesV11Metal3DDriver {
    func render(frameCount: Int, copyFinalFrame: Bool) throws -> MSeriesV11Metal3DExecution {
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
        let continuousStartedAt = MSeriesV11Clock.nanoseconds
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
        let continuousFinishedAt = MSeriesV11Clock.nanoseconds
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
        var execution = MSeriesV11Metal3DExecution(
            gpuElapsedSeconds: elapsed,
            wallElapsedSeconds: wallElapsed,
            usedWallClockFallback: !hasReliableGPUTiming,
            ranOnMainThread: ranOnMainThread
        )
        execution.startMonotonicNs = continuousStartedAt
        execution.endMonotonicNs = continuousFinishedAt
        return execution
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
