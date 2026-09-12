import Foundation

enum MacSustainedBenchmarkProfile: String, CaseIterable, Codable, Sendable {
    case standard
    case extended

    var targetDurationSeconds: Double {
        switch self {
        case .standard: 600
        case .extended: 900
        }
    }
}

enum MacSustainedCoolingMode: String, Codable, Sendable {
    /// macOS remains the sole owner of the fan and thermal policy.
    case systemAutomatic
    /// The user disclosed external cooling. The app still performs no fan write.
    case externallyAssisted
    case unknown
}

enum MacSustainedFanReading: Equatable, Codable, Sendable {
    case measured([Int])
    case unsupported

    var speedsRPM: [Int]? {
        guard case let .measured(speeds) = self else { return nil }
        return speeds
    }

    var isValid: Bool {
        switch self {
        case .unsupported:
            true
        case let .measured(speeds):
            !speeds.isEmpty && speeds.count <= 16
                && speeds.allSatisfy { (0...20_000).contains($0) }
        }
    }
}

struct MacSustainedTelemetrySample: Equatable, Codable, Sendable {
    let elapsedSeconds: Double
    let thermalState: BenchmarkThermalState
    let powerSource: BenchmarkPowerSource
    let lowPowerModeEnabled: Bool
    let chipTemperatureCelsius: Double?
    let fans: MacSustainedFanReading

    var isValid: Bool {
        guard elapsedSeconds.isFinite,
              elapsedSeconds >= 0,
              fans.isValid else { return false }
        guard let chipTemperatureCelsius else { return true }
        return chipTemperatureCelsius.isFinite
            && (5...130).contains(chipTemperatureCelsius)
    }
}

struct MacSustainedBenchmarkWindow: Equatable, Codable, Sendable {
    let index: Int
    let startedAtSeconds: Double
    let completedAtSeconds: Double
    let cpuMultiSample: BenchmarkComponentSample
    let gpuRasterSample: BenchmarkComponentSample

    var isValid: Bool {
        index >= 0
            && startedAtSeconds.isFinite
            && startedAtSeconds >= 0
            && completedAtSeconds.isFinite
            && completedAtSeconds > startedAtSeconds
            && Self.isValid(cpuMultiSample)
            && Self.isValid(gpuRasterSample)
    }

    private static func isValid(_ sample: BenchmarkComponentSample) -> Bool {
        sample.value.isFinite
            && sample.value > 0
            && sample.elapsedSeconds.isFinite
            && sample.elapsedSeconds > 0
            && sample.checksum != 0
    }
}

enum MacSustainedBenchmarkTermination: Equatable, Codable, Sendable {
    case targetDurationReached
    case thermalSafety(BenchmarkThermalState)
    case powerSourceChanged(BenchmarkPowerSource)
    case lowPowerModeEnabled
}

enum MacSustainedBenchmarkFailure: Equatable, Codable, Sendable {
    case busy(activeTask: String)
    case safetyCheck(BenchmarkSafetyIssue)
    case unsupportedCPU
    case unsupportedGPU
    case insufficientSamples
    case workloadFailed
    case cancelled
    case invalidResult
}

struct MacSustainedPerformanceSummary: Equatable, Sendable {
    let peakValue: Double
    let openingMedianValue: Double
    let sustainedMedianValue: Double
    let retentionRatio: Double
}

struct MacSustainedBenchmarkResult: Equatable, Codable, Sendable {
    static let protocolVersion = "mac-sustained-serial-v3"
    static let legacySerialProtocolVersion = "mac-sustained-serial-v2"
    static let legacyMixedProtocolVersion = "mac-sustained-mixed-v1"
    static let legacyMixedWorkloadFingerprint =
        "443149fb0bfd73f47b625a58799e84d061211aec09829f9de15bed059d168623"
    static let workloadManifest = "mac-sustained-serial-v3|cpu:multi,mixed-int-fp,worker-count=active-minus-one,ops-per-worker=64000000,warmup=4000000|gpu:raster3d,1920x1080,instances=262144,frames=90,triangles-per-instance=12,scene=instanced-cube-v1,shader=metal3d-v1|execution:cpu-then-gpu-serial,telemetry=1hz,target=600-or-900s,thermal-unknown-serious-critical=stop,cooling=system-owned"
    static let currentWorkloadFingerprint =
        "c54cf73c76f30d75d82c51c38e62d5d1fc15ae8d36d6004f7e8febf3e7509122"
    static let maximumWindowCount = 4_096
    static let maximumTelemetrySampleCount = 8_192

    let workloadVersion: String
    let workloadFingerprint: String
    let profile: MacSustainedBenchmarkProfile
    let coolingMode: MacSustainedCoolingMode
    let targetDurationSeconds: Double
    let workloadDurationSeconds: Double
    let totalObservationDurationSeconds: Double
    let startedAt: Date
    let completedAt: Date?
    let environment: BenchmarkEnvironmentMetadata
    let preflight: BenchmarkPreflight
    let windows: [MacSustainedBenchmarkWindow]
    let telemetry: [MacSustainedTelemetrySample]
    let termination: MacSustainedBenchmarkTermination?
    let cooldownReachedNominal: Bool?
    let failure: MacSustainedBenchmarkFailure?

    static func isLegacyWorkload(version: String, fingerprint: String) -> Bool {
        (version == legacyMixedProtocolVersion
            && fingerprint == legacyMixedWorkloadFingerprint)
            || version == legacySerialProtocolVersion
    }

    var isLegacyWorkload: Bool {
        Self.isLegacyWorkload(
            version: workloadVersion,
            fingerprint: workloadFingerprint
        )
    }

    init(
        workloadVersion: String = Self.protocolVersion,
        workloadFingerprint: String = Self.currentWorkloadFingerprint,
        profile: MacSustainedBenchmarkProfile,
        coolingMode: MacSustainedCoolingMode,
        targetDurationSeconds: Double,
        workloadDurationSeconds: Double,
        totalObservationDurationSeconds: Double,
        startedAt: Date,
        completedAt: Date?,
        environment: BenchmarkEnvironmentMetadata,
        preflight: BenchmarkPreflight,
        windows: [MacSustainedBenchmarkWindow],
        telemetry: [MacSustainedTelemetrySample],
        termination: MacSustainedBenchmarkTermination?,
        cooldownReachedNominal: Bool?,
        failure: MacSustainedBenchmarkFailure?
    ) {
        self.workloadVersion = workloadVersion
        self.workloadFingerprint = workloadFingerprint
        self.profile = profile
        self.coolingMode = coolingMode
        self.targetDurationSeconds = targetDurationSeconds
        self.workloadDurationSeconds = workloadDurationSeconds
        self.totalObservationDurationSeconds = totalObservationDurationSeconds
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.environment = environment
        self.preflight = preflight
        self.windows = windows
        self.telemetry = telemetry
        self.termination = termination
        self.cooldownReachedNominal = cooldownReachedNominal
        self.failure = failure
    }

    var isComplete: Bool {
        guard workloadVersion == Self.protocolVersion,
              workloadFingerprint == Self.currentWorkloadFingerprint,
              failure == nil,
              let completedAt,
              let termination,
              completedAt >= startedAt,
              completedAt >= preflight.capturedAt,
              preflight.capturedAt >= startedAt,
              targetDurationSeconds.isFinite,
              targetDurationSeconds > 0,
              targetDurationSeconds <= 900,
              workloadDurationSeconds.isFinite,
              workloadDurationSeconds >= 0,
              workloadDurationSeconds <= targetDurationSeconds + 10,
              totalObservationDurationSeconds.isFinite,
              totalObservationDurationSeconds >= workloadDurationSeconds,
              totalObservationDurationSeconds <= workloadDurationSeconds + 35,
              windows.count <= Self.maximumWindowCount,
              telemetry.count > 0,
              telemetry.count <= Self.maximumTelemetrySampleCount,
              Self.hasValidWindowSequence(windows),
              Self.hasValidTelemetrySequence(telemetry),
              Self.hasStableDigests(windows),
              windows.last.map({
                  $0.completedAtSeconds <= workloadDurationSeconds + 0.001
              }) ?? true,
              telemetry.last.map({
                  $0.elapsedSeconds <= totalObservationDurationSeconds + 0.001
              }) ?? false,
              Self.terminationMatchesTelemetry(
                  termination,
                  telemetry: telemetry
              )
        else { return false }

        switch termination {
        case .targetDurationReached:
            return windows.count >= 3
                && workloadDurationSeconds + 1 >= targetDurationSeconds
                && cooldownReachedNominal == nil
        case let .thermalSafety(state):
            return state == .serious || state == .critical || state == .unknown
                ? cooldownReachedNominal != nil
                : false
        case .powerSourceChanged, .lowPowerModeEnabled:
            return cooldownReachedNominal == nil
        }
    }

    /// A safety stop is a complete diagnostic record, but only reaching the
    /// declared duration satisfies the product benchmark completion contract.
    var reachedTargetDuration: Bool {
        isComplete && termination == .targetDurationReached
    }

    var cpuSummary: MacSustainedPerformanceSummary? {
        Self.summary(for: windows.map(\.cpuMultiSample.value))
    }

    var gpuSummary: MacSustainedPerformanceSummary? {
        Self.summary(for: windows.map(\.gpuRasterSample.value))
    }

    var firstThermalChangeSeconds: Double? {
        telemetry.first { $0.thermalState != .nominal }?.elapsedSeconds
    }

    var maximumChipTemperatureCelsius: Double? {
        telemetry.compactMap(\.chipTemperatureCelsius).max()
    }

    var maximumFanSpeedRPM: Int? {
        telemetry.compactMap { $0.fans.speedsRPM?.max() }.max()
    }
}

private extension MacSustainedBenchmarkResult {
    static func hasValidWindowSequence(_ windows: [MacSustainedBenchmarkWindow]) -> Bool {
        for (offset, window) in windows.enumerated() {
            guard window.isValid,
                  window.index == offset else { return false }
            if offset > 0 {
                let previous = windows[offset - 1]
                guard window.startedAtSeconds >= previous.completedAtSeconds else {
                    return false
                }
            }
        }
        return true
    }

    static func hasValidTelemetrySequence(
        _ telemetry: [MacSustainedTelemetrySample]
    ) -> Bool {
        guard telemetry.allSatisfy(\.isValid) else { return false }
        return zip(telemetry, telemetry.dropFirst()).allSatisfy { lhs, rhs in
            rhs.elapsedSeconds >= lhs.elapsedSeconds
        }
    }

    static func hasStableDigests(_ windows: [MacSustainedBenchmarkWindow]) -> Bool {
        guard let first = windows.first else { return true }
        return windows.allSatisfy { window in
            window.cpuMultiSample.checksum == first.cpuMultiSample.checksum
                && window.gpuRasterSample.checksum == first.gpuRasterSample.checksum
        }
    }

    static func terminationMatchesTelemetry(
        _ termination: MacSustainedBenchmarkTermination,
        telemetry: [MacSustainedTelemetrySample]
    ) -> Bool {
        switch termination {
        case .targetDurationReached:
            return telemetry.allSatisfy { sample in
                sample.thermalState == .nominal || sample.thermalState == .fair
            } && telemetry.allSatisfy {
                $0.powerSource == .acPower && !$0.lowPowerModeEnabled
            }
        case let .thermalSafety(state):
            return telemetry.contains { $0.thermalState == state }
        case let .powerSourceChanged(source):
            return source != .acPower
                && telemetry.contains { $0.powerSource == source }
        case .lowPowerModeEnabled:
            return telemetry.contains { $0.lowPowerModeEnabled }
        }
    }

    static func summary(for values: [Double]) -> MacSustainedPerformanceSummary? {
        guard values.count >= 3,
              values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let sliceCount = max(1, Int(ceil(Double(values.count) * 0.2)))
        let opening = Array(values.prefix(sliceCount))
        let sustained = Array(values.suffix(sliceCount))
        guard let openingMedian = median(opening),
              let sustainedMedian = median(sustained),
              openingMedian > 0 else { return nil }
        let retention = sustainedMedian / openingMedian
        guard retention.isFinite, retention > 0 else { return nil }
        return MacSustainedPerformanceSummary(
            peakValue: values.max() ?? openingMedian,
            openingMedianValue: openingMedian,
            sustainedMedianValue: sustainedMedian,
            retentionRatio: retention
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

enum MacSustainedBenchmarkStage: Equatable, Sendable {
    case preflight
    case mixedLoad
    case coolingDown
}

struct MacSustainedBenchmarkProgress: Equatable, Sendable {
    let stage: MacSustainedBenchmarkStage
    let completedWindowCount: Int
    let elapsedSeconds: Double
    let targetDurationSeconds: Double
    let thermalState: BenchmarkThermalState
    let currentFanSpeedRPM: Int?

    var progress: Double {
        guard targetDurationSeconds.isFinite,
              targetDurationSeconds > 0,
              elapsedSeconds.isFinite else { return 0 }
        return min(1, max(0, elapsedSeconds / targetDurationSeconds))
    }
}

enum MacSustainedBenchmarkState: Equatable, Sendable {
    case idle
    case preflighting
    case running(progress: Double)
    case coolingDown
    case cancelling
    case completed
    case cancelled
    case failed(MacSustainedBenchmarkFailure)
}
