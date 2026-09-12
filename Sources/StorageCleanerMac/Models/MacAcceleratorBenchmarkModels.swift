import Foundation

enum MacAcceleratorMetric: String, CaseIterable, Codable, Sendable {
    case metalRaster3D = "gpu.raster3d"
    case rayTracingBuild = "gpu.rayTracing.build"
    case rayTracingTraversal = "gpu.rayTracing.traversal"
    case gpuTensorFP16 = "gpu.tensor.fp16Gemm"
    case mediaH264Encode = "media.h264.encode"
    case mediaH264Decode = "media.h264.decode"

    var domain: MacAcceleratorDomain {
        switch self {
        case .metalRaster3D, .rayTracingBuild, .rayTracingTraversal,
             .gpuTensorFP16:
            .gpu
        case .mediaH264Encode, .mediaH264Decode:
            .mediaEngine
        }
    }

    var unit: MacAcceleratorMetricUnit {
        switch self {
        case .metalRaster3D, .rayTracingBuild:
            .millionTrianglesPerSecond
        case .rayTracingTraversal:
            .millionRaysPerSecond
        case .gpuTensorFP16:
            .trillionFloatingPointOperationsPerSecond
        case .mediaH264Encode, .mediaH264Decode:
            .megapixelsPerSecond
        }
    }

    var maximumStableCoefficientOfVariation: Double {
        switch self {
        case .gpuTensorFP16:
            0.05
        case .rayTracingTraversal, .mediaH264Decode:
            0.08
        case .metalRaster3D, .rayTracingBuild, .mediaH264Encode:
            0.10
        }
    }
}

enum MacAcceleratorDomain: String, Codable, Sendable {
    case gpu
    case mediaEngine
}

enum MacAcceleratorMetricUnit: String, Codable, Sendable {
    case millionTrianglesPerSecond
    case millionRaysPerSecond
    case trillionFloatingPointOperationsPerSecond
    case megapixelsPerSecond
}

enum MacAcceleratorAvailability: String, Codable, Sendable {
    case measured
    case unsupported
    case temporarilyUnavailable
}

struct MacAcceleratorMeasurement: Equatable, Codable, Sendable {
    let metric: MacAcceleratorMetric
    let availability: MacAcceleratorAvailability
    let samples: [BenchmarkComponentSample]

    var medianValue: Double? {
        Self.median(samples.map(\.value))
    }

    var coefficientOfVariation: Double? {
        Self.coefficientOfVariation(samples.map(\.value))
    }

    var isStable: Bool {
        guard availability == .measured,
              let coefficientOfVariation else { return false }
        return coefficientOfVariation <= metric.maximumStableCoefficientOfVariation
    }

    func isValid(expectedSampleCount: Int) -> Bool {
        guard expectedSampleCount > 0 else { return false }
        switch availability {
        case .unsupported, .temporarilyUnavailable:
            return samples.isEmpty
        case .measured:
            guard samples.count == expectedSampleCount,
                  let validationDigest = samples.first?.checksum,
                  validationDigest != 0,
                  samples.allSatisfy({ sample in
                      sample.checksum == validationDigest
                          && sample.value.isFinite
                          && sample.value > 0
                          && sample.elapsedSeconds.isFinite
                          && sample.elapsedSeconds > 0
                  }),
                  let medianValue,
                  medianValue.isFinite,
                  medianValue > 0,
                  let coefficientOfVariation,
                  coefficientOfVariation.isFinite,
                  coefficientOfVariation >= 0
            else { return false }
            return true
        }
    }

    private static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard !values.isEmpty,
              values.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean.isFinite, mean > 0 else { return nil }
        let squaredError = values.reduce(0) { partial, value in
            let difference = value - mean
            return partial + difference * difference
        }
        let coefficient = sqrt(squaredError / Double(values.count - 1)) / mean
        return coefficient.isFinite ? coefficient : nil
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

enum MacAcceleratorBenchmarkFailure: Equatable, Codable, Sendable {
    case busy(activeTask: String)
    case safetyCheck(BenchmarkSafetyIssue)
    case timedOut(MacAcceleratorMetric)
    case validationFailed(MacAcceleratorMetric)
    case cancelled
    case invalidResult
}

struct MacAcceleratorBenchmarkResult: Equatable, Codable, Sendable {
    static let protocolVersion = "mac-accelerator-suite-v1"
    static let sampleCount = 3

    /// Canonical parameters and deterministic content revisions for every raw
    /// metric. Changing a scene, shader, matrix, batching rule, or media
    /// validation contract requires a new manifest and fingerprint so history
    /// from different workloads can never be compared as if it were identical.
    static let workloadManifest = "mac-accelerator-suite-v1|metal3d:1920x1080,instances=262144,frames=600,trianglesPerInstance=12,scene=instanced-cube-v1,shader=metal3d-v1|raytracing:triangles=131072,rays=262144,passes=64,scene=tiled-plane-v1,shader=metal-intersection-v1,family=apple9-apple10,batch=16|tensor:fp16,m=2048,n=2048,k=2048,iterations=128,warmup=4,input=hashed-v1,validation=full-digest-plus-64-samples-v1,batch=16|h264:1920x1080,frames=60,fps=60,bitrate=12000000,source=deterministic-bi-planar-yuv-v1,validation=decoded-content-v2,hardware-required=true"
    static let currentWorkloadFingerprint =
        "5acd3a0e91e8d1c93104710d2fc52e3aecead0ca0e28a0a6865d537d9e31d9ff"

    let workloadVersion: String
    let workloadFingerprint: String
    let startedAt: Date
    let completedAt: Date?
    let environment: BenchmarkEnvironmentMetadata
    let preflight: BenchmarkPreflight
    let postflight: BenchmarkPostflight?
    let measurements: [MacAcceleratorMeasurement]
    let failure: MacAcceleratorBenchmarkFailure?

    init(
        workloadVersion: String,
        workloadFingerprint: String = Self.currentWorkloadFingerprint,
        startedAt: Date,
        completedAt: Date?,
        environment: BenchmarkEnvironmentMetadata,
        preflight: BenchmarkPreflight,
        postflight: BenchmarkPostflight?,
        measurements: [MacAcceleratorMeasurement],
        failure: MacAcceleratorBenchmarkFailure?
    ) {
        self.workloadVersion = workloadVersion
        self.workloadFingerprint = workloadFingerprint
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.environment = environment
        self.preflight = preflight
        self.postflight = postflight
        self.measurements = measurements
        self.failure = failure
    }

    var measurementsByMetric: [MacAcceleratorMetric: MacAcceleratorMeasurement] {
        guard Set(measurements.map(\.metric)).count == measurements.count else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: measurements.map { ($0.metric, $0) })
    }

    var isComplete: Bool {
        guard workloadVersion == Self.protocolVersion,
              workloadFingerprint == Self.currentWorkloadFingerprint,
              failure == nil,
              let completedAt,
              let postflight,
              completedAt >= startedAt,
              preflight.capturedAt >= startedAt,
              postflight.capturedAt >= preflight.capturedAt,
              completedAt >= postflight.capturedAt else {
            return false
        }
        let byMetric = measurementsByMetric
        return byMetric.count == MacAcceleratorMetric.allCases.count
            && MacAcceleratorMetric.allCases.allSatisfy { metric in
                guard let measurement = byMetric[metric],
                      measurement.metric == metric else { return false }
                return measurement.isValid(expectedSampleCount: Self.sampleCount)
            }
    }

    var isFullyMeasured: Bool {
        isComplete && measurements.allSatisfy { $0.availability == .measured }
    }

    var hasStableMeasuredSamples: Bool {
        isComplete && measurements.allSatisfy { measurement in
            measurement.availability != .measured || measurement.isStable
        }
    }
}

enum MacAcceleratorBenchmarkState: Equatable, Sendable {
    case idle
    case preflighting
    case running(metric: MacAcceleratorMetric, progress: Double)
    case cancelling
    case completed
    case cancelled
    case failed(MacAcceleratorBenchmarkFailure)
}

struct MacAcceleratorBenchmarkProgress: Equatable, Sendable {
    let metric: MacAcceleratorMetric
    let completedSampleCount: Int
    let totalSampleCount: Int
    let elapsedSeconds: Double

    var progress: Double {
        guard totalSampleCount > 0 else { return 0 }
        return min(1, max(0, Double(completedSampleCount) / Double(totalSampleCount)))
    }
}
