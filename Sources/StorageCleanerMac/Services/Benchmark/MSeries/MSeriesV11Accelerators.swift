import CryptoKit
import Foundation

enum MSeriesV11AcceleratorID: String, CaseIterable, Sendable {
    case h264Encode = "media.h264.encode"
    case h264Decode = "media.h264.decode"
    case hevcEncode = "media.hevc.encode"
    case hevcDecode = "media.hevc.decode"
    case proResEncode = "media.prores.encode"
    case proResDecode = "media.prores.decode"
    case av1Decode = "media.av1.decode"
    case rayTracingBuild = "gpu.hardwareRayTracing.build"
    case rayTracingTraversal = "gpu.hardwareRayTracing.traversal"
    case tensorFP16 = "gpu.tensor.fp16"
    case smallModelCPU = "ai.smallModel.cpu"
    case smallModelANECandidate = "ai.smallModel.aneCandidate"
    case smallModelAccelerationRatio = "ai.smallModel.accelerationRatio"

    var cvLimit: Double {
        switch self {
        case .h264Encode, .hevcEncode, .proResEncode, .rayTracingBuild, .rayTracingTraversal: 0.10
        default: 0.05
        }
    }

    var unit: String {
        switch self {
        case .rayTracingBuild: "Mtri/s"
        case .rayTracingTraversal: "Mray/s"
        case .tensorFP16: "TFLOP/s"
        case .smallModelAccelerationRatio: "×"
        case .smallModelCPU, .smallModelANECandidate: "inferences/s"
        default: "MPix/s"
        }
    }

    var isGPU: Bool { [.rayTracingBuild, .rayTracingTraversal, .tensorFP16].contains(self) }
}

/// Nil is missing evidence; it must never be collapsed into hardware absence.
struct MSeriesV11AcceleratorCapability: Equatable, Sendable {
    var catalogSupported: Bool? = nil
    var runtimeSupported: Bool? = nil
    var hardwarePathConfirmed: Bool? = nil
    var evidence: String? = nil
}

struct MSeriesV11AcceleratorGate: Equatable, Sendable {
    let availability: String
    let reasonCode: String?
    let canRun: Bool
    let canClaimDedicatedHardware: Bool

    static func resolve(_ capability: MSeriesV11AcceleratorCapability) -> Self {
        if let catalog = capability.catalogSupported, let runtime = capability.runtimeSupported,
           catalog != runtime {
            return Self(availability: "unknown", reasonCode: "capabilityConflict",
                        canRun: runtime, canClaimDedicatedHardware: false)
        }
        if capability.catalogSupported == false {
            return Self(availability: "unsupported", reasonCode: "noHardwareUnit",
                        canRun: false, canClaimDedicatedHardware: false)
        }
        if capability.runtimeSupported == false {
            return Self(availability: "unknown", reasonCode: "systemUnavailable",
                        canRun: false, canClaimDedicatedHardware: false)
        }
        if capability.hardwarePathConfirmed == false {
            return Self(availability: "unknown", reasonCode: "hardwarePathUnverified",
                        canRun: false, canClaimDedicatedHardware: false)
        }
        let reason = capability.runtimeSupported == nil ? "runtimeCapabilityUnverified"
            : (capability.catalogSupported == nil ? "catalogUnverified" : nil)
        return Self(availability: capability.runtimeSupported == nil ? "unknown" : "available",
                    reasonCode: reason, canRun: true,
                    canClaimDedicatedHardware: capability.catalogSupported == true
                        && capability.runtimeSupported == true && capability.hardwarePathConfirmed == true)
    }
}

/// Official family mapping checked 2026-10-10: M3/M4 = Apple9, M5 = Apple10.
/// https://developer.apple.com/metal/capabilities/
/// An API reporting ray tracing support alone also permits software paths.
/// Unknown/future families remain unknown; chip marketing names are not input.
enum MSeriesV11RayTracingSupport {
    static func runtime(supportsRaytracing: Bool?, supportedFamilies: Set<String>) -> Bool? {
        guard let supportsRaytracing else { return nil }
        guard supportsRaytracing else { return false }
        if !supportedFamilies.isDisjoint(with: ["apple9", "apple10"]) { return true }
        return nil
    }
}

enum MSeriesV11AcceleratorUnit: Equatable, Sendable {
    case media(VideoMediaBenchmarkV11Codec)
    case rayTracing, tensorFP16, av1, smallModel

    var ids: [MSeriesV11AcceleratorID] {
        switch self {
        case .media(.h264): [.h264Encode, .h264Decode]
        case .media(.hevc): [.hevcEncode, .hevcDecode]
        case .media(.proRes422): [.proResEncode, .proResDecode]
        case .rayTracing: [.rayTracingBuild, .rayTracingTraversal]
        case .tensorFP16: [.tensorFP16]
        case .av1: [.av1Decode]
        case .smallModel: [.smallModelCPU, .smallModelANECandidate, .smallModelAccelerationRatio]
        }
    }

    var sampleDeadlineSeconds: Double {
        switch self { case .media(let codec): codec.maximumElapsedSeconds; default: 20 }
    }

    var collectionDeadlineSeconds: Double {
        switch self { case .media(let codec): codec.collectionDeadlineSeconds; default: 80 }
    }

    var fixtureVersion: String? {
        switch self {
        case .media(let codec): codec.fixtureVersion
        case .rayTracing: "procedural-131072tri-262144ray-64pass-v11.1"
        case .tensorFP16: "mps-fp16-2048cubed-128iterations-4warmup-v11.1"
        case .av1, .smallModel: nil
        }
    }
}

enum MSeriesV11AcceleratorError: Error, Equatable, Sendable {
    case timedOut, thermalProtection, invalidOutput, hardwarePathUnverified
}

/// These calls each return only after their VT/GPU callbacks/workers are drained.
/// Tests implement this protocol and must not instantiate production kernels.
protocol MSeriesV11AcceleratorWorkloadRunning: Sendable {
    func runV11MediaSample(
        codec: VideoMediaBenchmarkV11Codec, warmUp: Bool, maximumEncodedBytes: Int
    ) async throws -> VideoMediaBenchmarkKernel.RunResult
    func runV11RayTracingSample(warmUp: Bool) async throws -> MetalRayTracingBenchmarkKernel.RunResult
    func runV11TensorSample() async throws -> BenchmarkComponentSample
}

struct MSeriesV11AcceleratorMeasurement: Equatable, Sendable {
    let id: MSeriesV11AcceleratorID
    let availability: String
    let reasonCode: String?
    let samples: [BenchmarkComponentSample]
    let capability: MSeriesV11AcceleratorCapability
    let fixtureVersion: String?
    let allocationEvidenceKind: String?

    var canClaimDedicatedHardware: Bool {
        MSeriesV11AcceleratorGate.resolve(capability).canClaimDedicatedHardware
            && samples.count == 3 && allocationEvidenceKind != nil
    }

    /// No accelerator is a score input. Unstable values are retained as raw-only.
    var sampleCV: Double? { MSeriesScoringV11.coefficientOfVariation(samples.map(\.value)) }
    var passesCV: Bool { samples.count == 3 && (sampleCV.map { $0 <= id.cvLimit } ?? false) }

    func result(environment: [MSeriesV11Environment] = []) -> MSeriesV11Accelerator {
        let contractText = "\(fixtureVersion ?? "unimplemented");\(id.rawValue);\(id.unit);"
            + "\(id.isGPU ? "gpu-timeline" : "wall");samples3;cv\(id.cvLimit)"
        let workloadHash = SHA256.hash(data: Data(contractText.utf8)).map { String(format: "%02x", $0) }.joined()
        let metric: MSeriesV11Metric? = samples.isEmpty ? nil : MSeriesV11Metric(
            id: id.rawValue,
            contract: MSeriesV11MetricContract(
                unit: id.unit, timing: id.isGPU ? "gpu-timeline" : "wall",
                statisticsVersion: "mseries-window-cv-v11.1", workloadHash: workloadHash
            ),
            availability: samples.count == 3 ? "available" : availability,
            reasonCode: reasonCode,
            samples: samples.map {
                BenchmarkV7RawSample(value: $0.value, elapsedSeconds: $0.elapsedSeconds,
                                     wallElapsedSeconds: nil, checksum: $0.checksum)
            },
            environment: environment, usedWallClockFallback: false
        )
        return MSeriesV11Accelerator(
            id: id.rawValue, availability: availability, reasonCode: reasonCode, metric: metric,
            allocationEvidence: capability.evidence, allocationEvidenceKind: allocationEvidenceKind,
            fixtureVersion: fixtureVersion, fixtureSHA256: nil
        )
    }
}

/// Local accelerator sampling only. The parent owns stage order, lease and save.
/// Unknown runtime evidence permits a raw-only RequireHardware attempt; only
/// a successful readback can upgrade that evidence. AV1/ANE never dispatch.
struct MSeriesV11Accelerators: Sendable {
    private let runner: any MSeriesV11AcceleratorWorkloadRunning
    private let clock: any BenchmarkKernelClock
    private let checkEnvironment: @Sendable () async throws -> Void

    init(
        runner: any MSeriesV11AcceleratorWorkloadRunning,
        clock: any BenchmarkKernelClock = SystemBenchmarkKernelClock(),
        checkEnvironment: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.runner = runner
        self.clock = clock
        self.checkEnvironment = checkEnvironment
    }

    /// Catalog must already have passed the parent's provenance checks.
    static func catalogCapabilities(for chip: AppleSiliconCatalog.Chip?)
        -> [MSeriesV11AcceleratorID: MSeriesV11AcceleratorCapability]
    {
        let supported: [MSeriesV11AcceleratorID: Bool?] = [
            .h264Encode: chip?.mediaEngine.h264.encode, .h264Decode: chip?.mediaEngine.h264.decode,
            .hevcEncode: chip?.mediaEngine.hevc.encode, .hevcDecode: chip?.mediaEngine.hevc.decode,
            .proResEncode: chip?.mediaEngine.proResEncode, .proResDecode: chip?.mediaEngine.proResDecode,
            .av1Decode: chip?.mediaEngine.av1Decode,
            .rayTracingBuild: chip?.hardwareRayTracing, .rayTracingTraversal: chip?.hardwareRayTracing
        ]
        return supported.mapValues { MSeriesV11AcceleratorCapability(catalogSupported: $0) }
    }

    func measure(
        _ unit: MSeriesV11AcceleratorUnit,
        capabilities: [MSeriesV11AcceleratorID: MSeriesV11AcceleratorCapability],
        maximumEncodedBytes: Int = VideoMediaBenchmarkKernel.maximumEncodedBytes
    ) async -> [MSeriesV11AcceleratorMeasurement] {
        let ids = unit.ids
        var resolved = capabilities
        var samples: [MSeriesV11AcceleratorID: [BenchmarkComponentSample]] = [:]
        var evidenceKind: String?
        func capability(_ id: MSeriesV11AcceleratorID) -> MSeriesV11AcceleratorCapability {
            resolved[id] ?? MSeriesV11AcceleratorCapability()
        }
        func outcomes(_ failure: (String, String)? = nil) -> [MSeriesV11AcceleratorMeasurement] {
            ids.map { id in
                let cap = capability(id)
                let gate = MSeriesV11AcceleratorGate.resolve(cap)
                let raw = samples[id] ?? []
                let cv = MSeriesScoringV11.coefficientOfVariation(raw.map(\.value))
                let unstable = raw.count == 3 && (cv == nil || cv! > id.cvLimit)
                let state = failure?.0 ?? (raw.count == 3 ? gate.availability : "unknown")
                let reason = failure?.1 ?? (unstable ? "cvExceeded" : gate.reasonCode)
                return MSeriesV11AcceleratorMeasurement(
                    id: id, availability: state, reasonCode: reason,
                    samples: raw, capability: cap, fixtureVersion: unit.fixtureVersion,
                    allocationEvidenceKind: evidenceKind
                )
            }
        }
        // No model resource/compute plan or frozen, licensed AV1 bitstream was
        // delivered. A caller-supplied Bool cannot bypass these implementation gates.
        if unit == .smallModel { return outcomes(("notImplemented", "aneAllocationUnverified")) }
        if unit == .av1 {
            let gate = MSeriesV11AcceleratorGate.resolve(capability(.av1Decode))
            if gate.availability == "unsupported" { return outcomes((gate.availability, gate.reasonCode ?? "noHardwareUnit")) }
            return outcomes(("notImplemented", "av1FixtureMissing"))
        }

        let gates = ids.map { MSeriesV11AcceleratorGate.resolve(capability($0)) }
        if gates.contains(where: { !$0.canRun }) {
            return zip(ids, gates).map { id, gate in
                MSeriesV11AcceleratorMeasurement(
                    id: id, availability: gate.canRun ? "unknown" : gate.availability,
                    reasonCode: gate.canRun ? "pairedFixtureDependencyUnavailable" : gate.reasonCode,
                    samples: [], capability: capability(id), fixtureVersion: unit.fixtureVersion,
                    allocationEvidenceKind: nil
                )
            }
        }
        if case .media = unit,
           !(1...VideoMediaBenchmarkKernel.maximumEncodedBytes).contains(maximumEncodedBytes) {
            return outcomes(("insufficientResources", "encodedBufferBudget"))
        }
        let collectionStart = clock.nowNanoseconds()
        do {
            for index in 0..<3 {
                try Task.checkCancellation()
                try await checkEnvironment()
                let batch = try await perform(
                    unit, warmUp: index == 0, maximumEncodedBytes: maximumEncodedBytes,
                    collectionStart: collectionStart
                )
                // Validate the whole paired sample before accepting either direction.
                guard Set(batch.keys) == Set(ids), batch.values.allSatisfy({
                    $0.value.isFinite && $0.value > 0 && $0.elapsedSeconds.isFinite
                        && $0.elapsedSeconds > 0 && $0.checksum != 0
                }) else { throw MSeriesV11AcceleratorError.invalidOutput }
                for id in ids {
                    samples[id, default: []].append(batch[id]!)
                    var cap = capability(id)
                    cap.runtimeSupported = true
                    cap.hardwarePathConfirmed = true
                    cap.evidence = switch unit {
                    case .media(let codec): "\(codec.name): RequireHardware + UsingHardware encode/decode readback; decoded semantic checksum"
                    case .rayTracing: "supportsRaytracing + Apple9/Apple10 family; GPU time + scene/hit checksum"
                    default: "MPSMatrixMultiplication FP16 on Metal; GPU time + output checksum; no Core ML/ANE claim"
                    }
                    resolved[id] = cap
                }
                evidenceKind = switch unit {
                case .media: "runtimeReadback"
                case .rayTracing: "metalHardwareFamily"
                default: "mpsMetal"
                }
            }
            return outcomes()
        } catch {
            if error is CancellationError || Task.isCancelled { return outcomes(("cancelled", "cancelled")) }
            return outcomes(Self.failure(error, capabilities: ids.map(capability)))
        }
    }
}

private extension MSeriesV11Accelerators {
    func perform(
        _ unit: MSeriesV11AcceleratorUnit, warmUp: Bool, maximumEncodedBytes: Int,
        collectionStart: UInt64
    ) async throws -> [MSeriesV11AcceleratorID: BenchmarkComponentSample] {
        let started = clock.nowNanoseconds()
        let check = checkEnvironment
        let clock = clock
        let runner = runner
        let checkTime: @Sendable () throws -> Void = {
            let now = clock.nowNanoseconds()
            guard now >= started, started >= collectionStart else {
                throw MSeriesV11AcceleratorError.invalidOutput
            }
            if Double(now - started) / 1e9 >= unit.sampleDeadlineSeconds
                || Double(now - collectionStart) / 1e9 >= unit.collectionDeadlineSeconds {
                throw MSeriesV11AcceleratorError.timedOut
            }
        }
        try checkTime()
        return try await withThrowingTaskGroup(
            of: [MSeriesV11AcceleratorID: BenchmarkComponentSample].self
        ) { group in
            group.addTask {
                switch unit {
                case .media(let codec):
                    let result = try await runner.runV11MediaSample(
                        codec: codec, warmUp: warmUp, maximumEncodedBytes: maximumEncodedBytes
                    )
                    let summary = result.semanticSummary
                    guard summary.codec == codec.name, summary.width == 1_920, summary.height == 1_080,
                          summary.frameCount == 60, summary.framesPerSecond == 60,
                          summary.encodedFrameCount == 60, summary.decodedFrameCount == 60,
                          summary.encodedByteCount > 0, summary.encodedByteCount <= maximumEncodedBytes,
                          summary.decodedContentChecksum != 0, summary.checksum != 0,
                          result.encodeSample.checksum == summary.checksum,
                          result.decodeSample.checksum == summary.checksum else {
                        throw MSeriesV11AcceleratorError.invalidOutput
                    }
                    guard summary.encoderUsedHardware && summary.decoderUsedHardware else {
                        throw MSeriesV11AcceleratorError.hardwarePathUnverified
                    }
                    return [unit.ids[0]: result.encodeSample, unit.ids[1]: result.decodeSample]
                case .rayTracing:
                    let result = try await runner.runV11RayTracingSample(warmUp: warmUp)
                    guard result.triangleCount == 131_072, result.rayCount == 262_144,
                          result.traversalPassCount == 64, result.hitCount > 0,
                          result.hitCount < result.rayCount else {
                        throw MSeriesV11AcceleratorError.invalidOutput
                    }
                    return [.rayTracingBuild: result.buildSample, .rayTracingTraversal: result.traversalSample]
                case .tensorFP16:
                    return [.tensorFP16: try await runner.runV11TensorSample()]
                default: throw MSeriesV11AcceleratorError.invalidOutput
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(1))
                    try Task.checkCancellation()
                    try await check()
                    try checkTime()
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MSeriesV11AcceleratorError.invalidOutput }
            try Task.checkCancellation()
            try await check()
            try checkTime()
            return first
            // Structured group exit awaits cancellation and kernel drain.
        }
    }

    static func failure(
        _ error: any Error, capabilities: [MSeriesV11AcceleratorCapability]
    ) -> (String, String) {
        switch error {
        case MSeriesV11AcceleratorError.timedOut, VideoMediaBenchmarkError.timedOut,
             MacAcceleratorWorkloadError.timedOut: return ("failed", "timedOut")
        case MSeriesV11AcceleratorError.thermalProtection: return ("failed", "thermal-protection")
        case BenchmarkKernelError.resourceLimit, VideoMediaBenchmarkError.resourceLimit:
            return ("insufficientResources", "resourceLimit")
        case VideoMediaBenchmarkError.temporarilyUnavailable, MacAcceleratorWorkloadError.temporarilyUnavailable:
            return ("unknown", "temporarilyUnavailable")
        case VideoMediaBenchmarkError.unsupported:
            return ("unknown", capabilities.contains(where: { $0.catalogSupported == true })
                    ? "capabilityConflict" : "systemUnavailable")
        case BenchmarkKernelError.unavailable: return ("unknown", "runtimeCapabilityUnverified")
        case MSeriesV11AcceleratorError.hardwarePathUnverified,
             VideoMediaBenchmarkError.invalidOutput(.hardwarePath): return ("unknown", "hardwarePathUnverified")
        default: return ("failed", "invalidOutput")
        }
    }
}
