import Foundation
import Metal

/// Metal 3 baseline with offscreen resources; no drawable, present or display link.
/// Shader compilation, encoding and CPU verification are excluded from GPU timing.
final class MSeriesGPUKernel {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let library: any MTLLibrary
    static let elementCount = 262_144
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void core_fp32(device const float *input [[buffer(0)]], device float *output [[buffer(1)]], uint i [[thread_position_in_grid]]) {
        float x=input[i];
        for(uint k=0;k<256;k++) x=fma(x, 0.999f, 0.0001f);
        output[i]=x;
    }
    kernel void core_fp16(device const half *input [[buffer(0)]], device half *output [[buffer(1)]], uint i [[thread_position_in_grid]]) {
        half x=input[i];
        for(uint k=0;k<256;k++) x=fma(x, half(0.999), half(0.0001));
        output[i]=x;
    }
    vertex float4 core_vertex(uint id [[vertex_id]]) {
        const float2 positions[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
        return float4(positions[id],0,1);
    }
    fragment float4 core_fragment(float4 position [[position]]) {
        uint x=uint(position.x),y=uint(position.y);
        return float4(float(x%256)/255.0f,float(y%256)/255.0f,float((x+y)%256)/255.0f,1.0f);
    }
    """
    init(budget: UInt64) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw MSeriesKernelError.allocation
        }
        guard budget >= 64 * 1024 * 1024,
              device.recommendedMaxWorkingSetSize / 4 >= 64 * 1024 * 1024 else {
            throw MSeriesKernelError.resourceBudget
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        options.languageVersion = .version3_0
        self.library = try device.makeLibrary(source: Self.shader, options: options)
        self.device = device; self.queue = queue
    }

    func compute(halfPrecision: Bool, cancellation: MSeriesCancellation) throws -> MSeriesMeasurement {
        let function = try required(library.makeFunction(name: halfPrecision ? "core_fp16" : "core_fp32"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let stride = halfPrecision ? MemoryLayout<Float16>.stride : MemoryLayout<Float>.stride
        let input = try required(device.makeBuffer(length: Self.elementCount * stride, options: .storageModeShared))
        let output = try required(device.makeBuffer(length: Self.elementCount * stride, options: .storageModeShared))
        for i in 0..<Self.elementCount {
            if halfPrecision { input.contents().assumingMemoryBound(to: Float16.self)[i] = Float16(i % 64) / 64 }
            else { input.contents().assumingMemoryBound(to: Float.self)[i] = Float(i % 64) / 64 }
        }
        var expectedFloat = (0..<64).map { Float($0) / 64 }
        var expectedHalf = (0..<64).map { Float16($0) / 64 }
        for i in 0..<64 {
            for _ in 0..<256 {
                expectedFloat[i] = Float(0.0001).addingProduct(expectedFloat[i], Float(0.999))
                expectedHalf[i] = Float16(0.0001).addingProduct(expectedHalf[i], Float16(0.999))
            }
        }
        func sample(_ repetitions: Int) throws -> BenchmarkV7RawSample {
            try cancellation.check()
            let command = try required(queue.makeCommandBuffer())
            let encoder = try required(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(input, offset: 0, index: 0); encoder.setBuffer(output, offset: 0, index: 1)
            let width = min(256, pipeline.maxTotalThreadsPerThreadgroup)
            for _ in 0..<repetitions {
                encoder.dispatchThreads(MTLSize(width: Self.elementCount, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
                encoder.memoryBarrier(scope: .buffers)
            }
            encoder.endEncoding()
            let elapsed = try submit(command, cancellation: cancellation)
            var checksum: UInt64 = 0
            for i in 0..<Self.elementCount {
                if halfPrecision {
                    let result = output.contents().assumingMemoryBound(to: Float16.self)[i]
                    let expected = expectedHalf[i % 64]
                    guard result.isFinite, abs(result - expected) <= expected.ulp * 2 else { throw MSeriesKernelError.invalidOutput }
                    checksum &+= UInt64(result.bitPattern)
                } else {
                    let result = output.contents().assumingMemoryBound(to: Float.self)[i]
                    let expected = expectedFloat[i % 64]
                    guard result.isFinite, abs(result - expected) <= expected.ulp * 2 else { throw MSeriesKernelError.invalidOutput }
                    checksum &+= UInt64(result.bitPattern)
                }
            }
            return BenchmarkV7RawSample(value: Double(repetitions) / elapsed, elapsedSeconds: elapsed,
                wallElapsedSeconds: nil, checksum: checksum)
        }
        return try measure(id: halfPrecision ? "gpu.compute.fp16" : "gpu.compute.fp32", sample: sample)
    }

    func graphics(cancellation: MSeriesCancellation) throws -> MSeriesMeasurement {
        let textureDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 1024, height: 1024, mipmapped: false)
        textureDescription.usage = [.renderTarget]
        textureDescription.storageMode = .shared
        let texture = try required(device.makeTexture(descriptor: textureDescription))
        let pipelineDescription = MTLRenderPipelineDescriptor()
        pipelineDescription.vertexFunction = library.makeFunction(name: "core_vertex")
        pipelineDescription.fragmentFunction = library.makeFunction(name: "core_fragment")
        pipelineDescription.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescription)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        var pixels = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
        func sample(_ repetitions: Int) throws -> BenchmarkV7RawSample {
            try cancellation.check()
            let command = try required(queue.makeCommandBuffer())
            for _ in 0..<repetitions {
                let encoder = try required(command.makeRenderCommandEncoder(descriptor: pass))
                encoder.setRenderPipelineState(pipeline)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            let elapsed = try submit(command, cancellation: cancellation)
            pixels.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: 4096,
                    from: MTLRegionMake2D(0, 0, 1024, 1024), mipmapLevel: 0)
            }
            var checksum: UInt64 = 0
            for y in 0..<1024 { for x in 0..<1024 {
                let offset = (y * 1024 + x) * 4
                guard pixels[offset] == UInt8(x % 256), pixels[offset + 1] == UInt8(y % 256),
                      pixels[offset + 2] == UInt8((x + y) % 256), pixels[offset + 3] == 255 else {
                    throw MSeriesKernelError.invalidOutput
                }
                checksum &+= UInt64(pixels[offset])
            } }
            return BenchmarkV7RawSample(value: Double(repetitions) / elapsed, elapsedSeconds: elapsed,
                wallElapsedSeconds: nil, checksum: checksum)
        }
        return try measure(id: "gpu.graphics.offscreen", sample: sample)
    }

    private func measure(id: String, sample: (Int) throws -> BenchmarkV7RawSample) throws -> MSeriesMeasurement {
        let pilot = try sample(1)
        let repetitions = max(1, min(256, Int(ceil(0.04 / pilot.elapsedSeconds))))
        let samples = try (0..<MSeriesProtocol.samples).map { _ in try sample(repetitions) }
        return MSeriesMeasurement(id: id, unit: "fixed-fixtures/s", availability: .available, reason: nil,
            samples: samples, statistics: try BenchmarkStatistics.summarize(samples.map(\.value)),
            repetitions: repetitions, workers: 1)
    }
    private func submit(_ command: any MTLCommandBuffer, cancellation: MSeriesCancellation) throws -> Double {
        command.commit()
        // No early timeout return: retain the lease until the GPU really drains.
        command.waitUntilCompleted()
        try cancellation.check()
        guard command.status == .completed, command.error == nil else { throw MSeriesKernelError.invalidOutput }
        let elapsed = command.gpuEndTime - command.gpuStartTime
        guard elapsed.isFinite, elapsed > 0 else { throw MSeriesKernelError.invalidTiming }
        return elapsed
    }
    private func required<T>(_ object: T?) throws -> T {
        guard let object else { throw MSeriesKernelError.allocation }; return object
    }
}
