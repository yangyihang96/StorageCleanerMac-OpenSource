import Foundation

enum MacBenchmarkScoringError: Error, Equatable, Sendable {
    case incompleteResult
    case unsupportedWorkloadVersion
    case invalidSampleContract
    case nonComparableEnvironment
    case comparisonKeyMismatch
    case performanceRatioOutsideAcceptedRange(BenchmarkComponent)
    case invalidMetric
}

struct MacBenchmarkScoring: Sendable {
    private enum ScoreFormula: Sendable {
        case legacyV2WeightedIndex
        case directSum
        case capacityAwareDirectSum
        case balancedComposite
    }

    private struct WorkloadProtocol: Sendable {
        let profile: BenchmarkProfile
        let sampleCount: Int
        let formula: ScoreFormula
    }

    /// Every component maps the frozen reference Mac to 1,000 points.
    /// Standard v6 combines those six ratios geometrically (6,000 at reference).
    static let referenceScore = 1_000.0
    static let referenceTotalScore = referenceScore * Double(BenchmarkComponent.allCases.count)
    /// Legacy v2-v5 scoring clamps ratios before combining them. Keep those
    /// constants frozen so existing history never changes meaning.
    static let minimumRatio = 0.2
    static let maximumRatio = 5.0

    /// Standard v6 rejects implausible measurements instead of flattening them
    /// into a score cap. Within this validated range, 2x performance is 2x points.
    static let balancedCompositeWorkloadVersion = "mac-benchmark-standard-v6"
    static let minimumAcceptedPerformanceRatio = 0.02
    static let maximumAcceptedPerformanceRatio = 5.0
    static let strictMaximumComparableCoefficientOfVariation = 0.05
    static let relaxedMaximumComparableCoefficientOfVariation = 0.10
    static let balancedComponentWeights: [BenchmarkComponent: Double] = [
        .cpuSingle: 0.14,
        .cpuMulti: 0.21,
        .gpu: 0.25,
        .memory: 0.20,
        .diskRead: 0.11,
        .diskWrite: 0.09,
    ]

    /// Standard v5/v6 keep the six public components, while making installed
    /// memory and system-disk capacity a visible, bounded part of the result.
    /// Capacity cannot dominate throughput: together it contributes 450 of
    /// the 6,000 reference points (7.5%).
    static let capacityAwareWorkloadVersion = "mac-benchmark-standard-v5"
    static let referencePhysicalMemoryBytes: UInt64 = 48 * 1_024 * 1_024 * 1_024
    static let referenceSystemDiskCapacityBytes: UInt64 = 994_610_155_520
    static let memoryPerformanceWeight = 0.75
    static let memoryCapacityWeight = 0.25
    static let diskPerformanceWeight = 0.90
    static let diskCapacityWeight = 0.10
    static let minimumCapacityRatio = 0.25
    static let maximumCapacityRatio = 2.0

    /// v2 history used this weighted index. Keep it only to decode and revalidate
    /// existing results without silently changing their historical meaning.
    private static let legacyV2ComponentWeights: [BenchmarkComponent: Double] = [
        .cpuSingle: 0.20,
        .cpuMulti: 0.25,
        .gpu: 0.20,
        .memory: 0.15,
        .diskRead: 0.10,
        .diskWrite: 0.10,
    ]

    func score(
        rawResult: MacBenchmarkRawResult,
        against verifiedBaseline: VerifiedMacBenchmarkBaseline
    ) throws -> MacBenchmarkResult {
        guard rawResult.isComplete else {
            throw MacBenchmarkScoringError.incompleteResult
        }
        guard let workloadProtocol = Self.workloadProtocol(
            for: rawResult.workloadVersion
        ), workloadProtocol.profile == rawResult.profile else {
            throw MacBenchmarkScoringError.unsupportedWorkloadVersion
        }
        guard Self.hasValidSampleContract(rawResult) else {
            throw MacBenchmarkScoringError.invalidSampleContract
        }
        guard Self.hasComparableEnvironment(rawResult) else {
            throw MacBenchmarkScoringError.nonComparableEnvironment
        }
        let baseline = verifiedBaseline.baseline
        let key = baseline.comparisonKey
        guard key.workloadVersion == rawResult.workloadVersion,
              key.profile == rawResult.profile,
              key.architecture == rawResult.environment.architecture,
              key.capabilitySet == rawResult.capabilitySet,
              key.capabilitySet == .all
        else {
            throw MacBenchmarkScoringError.comparisonKeyMismatch
        }

        let measurements = rawResult.measurementsByComponent
        guard measurements.count == BenchmarkComponent.allCases.count else {
            throw MacBenchmarkScoringError.invalidMetric
        }

        let usesBalancedComposite = workloadProtocol.formula == .balancedComposite
        let capacityScores = try capacityScoresIfRequired(for: rawResult)
        var componentScores: [BenchmarkComponent: Double] = [:]
        componentScores.reserveCapacity(BenchmarkComponent.allCases.count)
        for component in BenchmarkComponent.allCases {
            guard let measured = measurements[component]?.medianValue,
                  let reference = baseline.referenceMetrics[component],
                  measured.isFinite,
                  measured > 0,
                  reference.isFinite,
                  reference > 0
            else {
                throw MacBenchmarkScoringError.invalidMetric
            }

            let rawRatio = measured / reference
            guard rawRatio.isFinite, rawRatio > 0 else {
                throw MacBenchmarkScoringError.invalidMetric
            }
            let ratio: Double
            if usesBalancedComposite {
                guard rawRatio >= Self.minimumAcceptedPerformanceRatio,
                      rawRatio <= Self.maximumAcceptedPerformanceRatio else {
                    throw MacBenchmarkScoringError
                        .performanceRatioOutsideAcceptedRange(component)
                }
                ratio = rawRatio
            } else {
                ratio = min(Self.maximumRatio, max(Self.minimumRatio, rawRatio))
            }
            let performanceScore = Self.referenceScore * ratio
            switch (component, capacityScores) {
            case (.memory, let capacity?):
                componentScores[component] =
                    Self.memoryPerformanceWeight * performanceScore
                    + Self.memoryCapacityWeight * capacity.memory
            case (.diskRead, let capacity?),
                 (.diskWrite, let capacity?):
                componentScores[component] =
                    Self.diskPerformanceWeight * performanceScore
                    + Self.diskCapacityWeight * capacity.disk
            default:
                componentScores[component] = performanceScore
            }
        }

        let overallScore: Double
        switch workloadProtocol.formula {
        case .legacyV2WeightedIndex:
            guard Self.legacyV2ComponentWeights.count == BenchmarkComponent.allCases.count,
                  abs(Self.legacyV2ComponentWeights.values.reduce(0, +) - 1) <= 0.000_000_1
            else {
                throw MacBenchmarkScoringError.invalidMetric
            }
            let weightedLog = try BenchmarkComponent.allCases.reduce(into: 0.0) {
                partial, component in
                guard let score = componentScores[component],
                      let weight = Self.legacyV2ComponentWeights[component]
                else {
                    throw MacBenchmarkScoringError.invalidMetric
                }
                partial += weight * log(score / Self.referenceScore)
            }
            overallScore = Self.referenceScore * exp(weightedLog)
        case .balancedComposite:
            overallScore = try Self.balancedCompositeScore(
                componentScores: componentScores
            )
        case .directSum, .capacityAwareDirectSum:
            let orderedScores = BenchmarkComponent.allCases.compactMap {
                componentScores[$0]
            }
            guard orderedScores.count == BenchmarkComponent.allCases.count else {
                throw MacBenchmarkScoringError.invalidMetric
            }
            overallScore = orderedScores.reduce(0, +)
        }
        guard overallScore.isFinite, overallScore > 0 else {
            throw MacBenchmarkScoringError.invalidMetric
        }

        let result = MacBenchmarkResult(
            rawResult: rawResult,
            comparisonKey: key,
            matchedBaselineKey: key,
            componentScores: componentScores,
            proposedOverallScore: overallScore
        )
        guard result.overallScore != nil else {
            throw MacBenchmarkScoringError.invalidMetric
        }
        return result
    }

    static func usesLegacyV2WeightedIndex(workloadVersion: String) -> Bool {
        workloadProtocol(for: workloadVersion)?.formula == .legacyV2WeightedIndex
    }

    static func usesCapacityAwareScoring(workloadVersion: String) -> Bool {
        workloadVersion == capacityAwareWorkloadVersion
            || workloadVersion == balancedCompositeWorkloadVersion
    }

    static func usesBalancedCompositeScoring(workloadVersion: String) -> Bool {
        workloadVersion == balancedCompositeWorkloadVersion
    }

    static func isSupportedWorkloadVersion(
        _ workloadVersion: String,
        profile: BenchmarkProfile
    ) -> Bool {
        workloadProtocol(for: workloadVersion)?.profile == profile
    }

    /// Revalidates persisted raw results against the same versioned sampling
    /// contract enforced by the live service. This prevents a one-sample record
    /// (CV = 0) or mixed kernel checksums from being promoted into a score.
    static func hasValidSampleContract(_ rawResult: MacBenchmarkRawResult) -> Bool {
        guard let protocolSpec = workloadProtocol(for: rawResult.workloadVersion),
              protocolSpec.profile == rawResult.profile else {
            return false
        }
        let measurements = rawResult.measurementsByComponent
        guard measurements.count == BenchmarkComponent.allCases.count else {
            return false
        }
        return BenchmarkComponent.allCases.allSatisfy { component in
            guard let samples = measurements[component]?.samples,
                  samples.count == protocolSpec.sampleCount,
                  let checksum = samples.first?.checksum else {
                return false
            }
            return samples.allSatisfy { $0.checksum == checksum }
        }
    }

    static func maximumComparableCoefficientOfVariation(
        for component: BenchmarkComponent
    ) -> Double {
        switch component {
        case .cpuSingle, .cpuMulti, .memory, .diskRead:
            strictMaximumComparableCoefficientOfVariation
        case .gpu, .diskWrite:
            relaxedMaximumComparableCoefficientOfVariation
        }
    }

    static func balancedCompositeScore(
        componentScores: [BenchmarkComponent: Double]
    ) throws -> Double {
        guard balancedComponentWeights.count == BenchmarkComponent.allCases.count,
              abs(balancedComponentWeights.values.reduce(0, +) - 1) <= 0.000_000_1
        else {
            throw MacBenchmarkScoringError.invalidMetric
        }

        let weightedLogRatio = try BenchmarkComponent.allCases.reduce(into: 0.0) {
            partial, component in
            guard let score = componentScores[component],
                  let weight = balancedComponentWeights[component],
                  score.isFinite,
                  score > 0,
                  weight.isFinite,
                  weight > 0 else {
                throw MacBenchmarkScoringError.invalidMetric
            }
            partial += weight * log(score / referenceScore)
        }
        let total = referenceTotalScore * exp(weightedLogRatio)
        guard total.isFinite, total > 0 else {
            throw MacBenchmarkScoringError.invalidMetric
        }
        return total
    }

    static func rawOnly(rawResult: MacBenchmarkRawResult) -> MacBenchmarkResult {
        return MacBenchmarkResult(
            rawResult: rawResult,
            comparisonKey: nil,
            matchedBaselineKey: nil,
            componentScores: [:],
            proposedOverallScore: nil
        )
    }

    static func hasComparableEnvironment(
        _ rawResult: MacBenchmarkRawResult
    ) -> Bool {
        guard rawResult.environment.architecture == .arm64,
              let completedAt = rawResult.completedAt,
              let postflight = rawResult.postflight,
              rawResult.startedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt.timeIntervalSinceReferenceDate.isFinite,
              rawResult.preflight.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              postflight.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              rawResult.startedAt <= rawResult.preflight.capturedAt,
              rawResult.preflight.capturedAt <= postflight.capturedAt,
              postflight.capturedAt <= completedAt,
              rawResult.preflight.powerSource != .battery,
              postflight.powerSource != .battery,
              rawResult.preflight.powerSource == postflight.powerSource,
              rawResult.environment.powerSource == postflight.powerSource,
              !rawResult.preflight.lowPowerModeEnabled,
              !postflight.lowPowerModeEnabled,
              rawResult.preflight.hasRequiredDiskCapacity,
              rawResult.preflight.diskReliability != .failing,
              rawResult.preflight.warnings.isEmpty,
              rawResult.preflight.thermalState == .nominal,
              postflight.thermalState == .nominal,
              rawResult.environment.thermalState == .nominal
        else {
            return false
        }
        if usesBalancedCompositeScoring(workloadVersion: rawResult.workloadVersion) {
            guard postflight.hasCompleteDiskSnapshot,
                  let postflightDiskReliability = postflight.diskReliability,
                  let postflightRequiredDiskBytes = postflight.requiredDiskBytes,
                  let postflightWarnings = postflight.warnings,
                  postflightDiskReliability == rawResult.preflight.diskReliability,
                  postflightDiskReliability != .failing,
                  postflightRequiredDiskBytes == rawResult.preflight.requiredDiskBytes,
                  postflight.hasRequiredDiskCapacity,
                  postflightWarnings.isEmpty else {
                return false
            }
        }
        if usesCapacityAwareScoring(workloadVersion: rawResult.workloadVersion) {
            guard rawResult.environment.physicalMemoryBytes > 0,
                  let diskCapacity = rawResult.environment.systemDiskCapacityBytes,
                  diskCapacity > 0 else {
                return false
            }
        }
        return hasComparableMeasurementStability(rawResult)
    }

    static func hasComparableMeasurementStability(
        _ rawResult: MacBenchmarkRawResult
    ) -> Bool {
        guard usesBalancedCompositeScoring(
            workloadVersion: rawResult.workloadVersion
        ) else {
            return true
        }
        let measurements = rawResult.measurementsByComponent
        return BenchmarkComponent.allCases.allSatisfy { component in
            guard let measurement = measurements[component] else { return false }
            let coefficient = measurement.coefficientOfVariation
            return coefficient.isFinite
                && coefficient >= 0
                && coefficient <= maximumComparableCoefficientOfVariation(
                    for: component
                )
        }
    }

    private static func workloadProtocol(
        for workloadVersion: String
    ) -> WorkloadProtocol? {
        switch workloadVersion {
        case "mac-benchmark-quick-v2":
            WorkloadProtocol(
                profile: .quick,
                sampleCount: 3,
                formula: .legacyV2WeightedIndex
            )
        case "mac-benchmark-full-v2":
            WorkloadProtocol(
                profile: .full,
                sampleCount: 5,
                formula: .legacyV2WeightedIndex
            )
        case "mac-benchmark-quick-v3":
            WorkloadProtocol(profile: .quick, sampleCount: 3, formula: .directSum)
        case "mac-benchmark-full-v3":
            WorkloadProtocol(profile: .full, sampleCount: 5, formula: .directSum)
        case "mac-benchmark-standard-v4":
            WorkloadProtocol(profile: .standard, sampleCount: 3, formula: .directSum)
        case capacityAwareWorkloadVersion:
            WorkloadProtocol(
                profile: .standard,
                sampleCount: 3,
                formula: .capacityAwareDirectSum
            )
        case balancedCompositeWorkloadVersion:
            WorkloadProtocol(
                profile: .standard,
                sampleCount: 3,
                formula: .balancedComposite
            )
        default:
            nil
        }
    }

    private struct CapacityScores {
        let memory: Double
        let disk: Double
    }

    private func capacityScoresIfRequired(
        for rawResult: MacBenchmarkRawResult
    ) throws -> CapacityScores? {
        guard Self.usesCapacityAwareScoring(
            workloadVersion: rawResult.workloadVersion
        ) else {
            return nil
        }
        guard let diskCapacity = rawResult.environment.systemDiskCapacityBytes else {
            throw MacBenchmarkScoringError.invalidMetric
        }
        return CapacityScores(
            memory: try Self.capacityScore(
                actualBytes: rawResult.environment.physicalMemoryBytes,
                referenceBytes: Self.referencePhysicalMemoryBytes
            ),
            disk: try Self.capacityScore(
                actualBytes: diskCapacity,
                referenceBytes: Self.referenceSystemDiskCapacityBytes
            )
        )
    }

    static func capacityScore(
        actualBytes: UInt64,
        referenceBytes: UInt64
    ) throws -> Double {
        guard actualBytes > 0, referenceBytes > 0 else {
            throw MacBenchmarkScoringError.invalidMetric
        }
        let ratio = sqrt(Double(actualBytes) / Double(referenceBytes))
        guard ratio.isFinite, ratio > 0 else {
            throw MacBenchmarkScoringError.invalidMetric
        }
        let bounded = min(maximumCapacityRatio, max(minimumCapacityRatio, ratio))
        return referenceScore * bounded
    }
}
