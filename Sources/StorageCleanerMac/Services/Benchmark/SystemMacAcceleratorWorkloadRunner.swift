import Foundation

/// Production adapter for the independent raw-only accelerator suite.
///
/// Each kernel owns a fixed in-memory workload. Unsupported hardware is
/// surfaced as availability metadata and never converted into a zero sample.
struct SystemMacAcceleratorWorkloadRunner: MacAcceleratorWorkloadRunning {
    private let rasterKernel: Metal3DBenchmarkKernel
    private let rayTracingKernel: MetalRayTracingBenchmarkKernel
    private let tensorKernel: GPUTensorBenchmarkKernel
    private let videoKernel: VideoMediaBenchmarkKernel

    init(
        rasterKernel: Metal3DBenchmarkKernel = Metal3DBenchmarkKernel(),
        rayTracingKernel: MetalRayTracingBenchmarkKernel
            = MetalRayTracingBenchmarkKernel(),
        tensorKernel: GPUTensorBenchmarkKernel = GPUTensorBenchmarkKernel(),
        videoKernel: VideoMediaBenchmarkKernel = VideoMediaBenchmarkKernel()
    ) {
        self.rasterKernel = rasterKernel
        self.rayTracingKernel = rayTracingKernel
        self.tensorKernel = tensorKernel
        self.videoKernel = videoKernel
    }

    func runMetalRaster3D() async throws -> BenchmarkComponentSample {
        try await rasterKernel.run().sample
    }

    func runRayTracing() async throws
        -> MacAcceleratorWorkloadOutcome<MacAcceleratorRayTracingSamplePair>
    {
        do {
            let result = try await rayTracingKernel.run()
            return .measured(
                MacAcceleratorRayTracingSamplePair(
                    build: result.buildSample,
                    traversal: result.traversalSample
                )
            )
        } catch BenchmarkKernelError.unavailable {
            return .unsupported
        } catch MacAcceleratorWorkloadError.temporarilyUnavailable {
            return .temporarilyUnavailable
        }
    }

    func runGPUTensor() async throws
        -> MacAcceleratorWorkloadOutcome<BenchmarkComponentSample>
    {
        do {
            return .measured(try await tensorKernel.run())
        } catch BenchmarkKernelError.unavailable {
            return .unsupported
        } catch MacAcceleratorWorkloadError.temporarilyUnavailable {
            return .temporarilyUnavailable
        }
    }

    func runH264Media() async throws
        -> MacAcceleratorWorkloadOutcome<MacAcceleratorMediaSamplePair>
    {
        do {
            let result = try await videoKernel.run(profile: .standard)
            return .measured(
                MacAcceleratorMediaSamplePair(
                    encode: result.encodeSample,
                    decode: result.decodeSample
                )
            )
        } catch VideoMediaBenchmarkError.unsupported(_) {
            return .unsupported
        } catch VideoMediaBenchmarkError.temporarilyUnavailable(_) {
            return .temporarilyUnavailable
        } catch let VideoMediaBenchmarkError.timedOut(capability) {
            let metric: MacAcceleratorMetric = switch capability {
            case .h264HardwareEncoder:
                .mediaH264Encode
            case .h264HardwareDecoder:
                .mediaH264Decode
            }
            throw MacAcceleratorWorkloadError.timedOut(metric)
        }
    }
}
