import Foundation
@preconcurrency import Metal
@preconcurrency import MetalPerformanceShaders
@preconcurrency import VideoToolbox

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

/// Added v11 entry points leave mac-accelerator-suite-v1 and its 8% gate alone.
extension SystemMacAcceleratorWorkloadRunner: MSeriesV11AcceleratorWorkloadRunning {
    func runV11MediaSample(
        codec: VideoMediaBenchmarkV11Codec, warmUp: Bool, maximumEncodedBytes: Int
    ) async throws -> VideoMediaBenchmarkKernel.RunResult {
        try await videoKernel.runV11(
            codec: codec, warmUp: warmUp, maximumEncodedBytes: maximumEncodedBytes
        )
    }

    func runV11RayTracingSample(warmUp: Bool) async throws -> MetalRayTracingBenchmarkKernel.RunResult {
        try await rayTracingKernel.runV11(warmUp: warmUp)
    }

    func runV11TensorSample() async throws -> BenchmarkComponentSample {
        try await tensorKernel.run()
    }

    /// Capability queries only: no inference, encode, shader or benchmark load.
    /// Encoder hardware is intentionally unknown until RequireHardware session
    /// preparation and UsingHardware readback in the media kernel.
    static func v11Capabilities(catalogChip: AppleSiliconCatalog.Chip?)
        -> [MSeriesV11AcceleratorID: MSeriesV11AcceleratorCapability]
    {
        var result = MSeriesV11Accelerators.catalogCapabilities(for: catalogChip)
        for codec in VideoMediaBenchmarkV11Codec.allCases {
            let ids = MSeriesV11AcceleratorUnit.media(codec).ids
            result[ids[1], default: MSeriesV11AcceleratorCapability()].runtimeSupported
                = VTIsHardwareDecodeSupported(codec.codecType)
        }
        let device = MTLCreateSystemDefaultDevice()
        var families: Set<String> = []
        if let device {
#if compiler(>=6.2)
            if #available(macOS 26.0, *), device.supportsFamily(.apple10) { families.insert("apple10") }
#endif
            if device.supportsFamily(.apple9) { families.insert("apple9") }
        }
        let raySupport = MSeriesV11RayTracingSupport.runtime(
            supportsRaytracing: device?.supportsRaytracing, supportedFamilies: families
        )
        for id in [MSeriesV11AcceleratorID.rayTracingBuild, .rayTracingTraversal] {
            result[id, default: MSeriesV11AcceleratorCapability()].runtimeSupported = raySupport
        }
        result[.tensorFP16] = MSeriesV11AcceleratorCapability(
            runtimeSupported: device.map { MPSSupportsMTLDevice($0) }
        )
        return result
    }
}
