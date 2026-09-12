import Foundation

enum BenchmarkConfidenceRating: String, Codable, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"
}

struct BenchmarkStatisticsSummary: Equatable, Codable, Sendable {
    let sampleCount: Int
    let median: Double
    let medianAbsoluteDeviation: Double
    let p50: Double
    let p95: Double
    let p99: Double
    let relativeMedianAbsoluteDeviation: Double
    let confidence: BenchmarkConfidenceRating
}

struct MacBenchmarkDisplayScore: Equatable, Sendable {
    let componentScores: [BenchmarkComponent: Double]
    let overallScore: Double
}

/// Calculates the score shown for a complete Standard v6 run without changing
/// the stricter score that is persisted and accepted by the public leaderboard.
enum MacBenchmarkDisplayScoring {
    private static let productionCatalog =
        MacBenchmarkProductionBaselineCatalog.runtimeCatalog()

    static func score(for result: MacBenchmarkResult) -> MacBenchmarkDisplayScore? {
        score(for: result, baselineCatalog: productionCatalog)
    }

    static func score(
        for result: MacBenchmarkResult,
        baselineCatalog: MacBenchmarkBaselineCatalog
    ) -> MacBenchmarkDisplayScore? {
        if let overallScore = result.overallScore {
            return MacBenchmarkDisplayScore(
                componentScores: result.componentScores,
                overallScore: overallScore
            )
        }
        guard let raw = result.rawResult,
              raw.failure == nil,
              raw.isComplete,
              raw.profile == .standard,
              raw.workloadVersion == MacBenchmarkScoring.balancedCompositeWorkloadVersion,
              raw.environment.architecture == .arm64,
              MacBenchmarkScoring.hasValidSampleContract(raw),
              case let .matched(verifiedBaseline) = baselineCatalog.lookup(matching: raw),
              let diskCapacity = raw.environment.systemDiskCapacityBytes
        else { return nil }

        let references = verifiedBaseline.baseline.referenceMetrics
        let measurements = raw.measurementsByComponent
        guard references.count == BenchmarkComponent.allCases.count,
              measurements.count == BenchmarkComponent.allCases.count,
              let memoryCapacityScore = try? MacBenchmarkScoring.capacityScore(
                actualBytes: raw.environment.physicalMemoryBytes,
                referenceBytes: MacBenchmarkScoring.referencePhysicalMemoryBytes
              ),
              let diskCapacityScore = try? MacBenchmarkScoring.capacityScore(
                actualBytes: diskCapacity,
                referenceBytes: MacBenchmarkScoring.referenceSystemDiskCapacityBytes
              ) else { return nil }

        var componentScores: [BenchmarkComponent: Double] = [:]
        for component in BenchmarkComponent.allCases {
            guard let measured = measurements[component]?.medianValue,
                  let reference = references[component],
                  measured.isFinite,
                  measured > 0,
                  reference.isFinite,
                  reference > 0 else { return nil }
            let ratio = measured / reference
            guard ratio.isFinite,
                  ratio >= MacBenchmarkScoring.minimumAcceptedPerformanceRatio,
                  ratio <= MacBenchmarkScoring.maximumAcceptedPerformanceRatio
            else { return nil }

            let performanceScore = MacBenchmarkScoring.referenceScore * ratio
            switch component {
            case .memory:
                componentScores[component] =
                    MacBenchmarkScoring.memoryPerformanceWeight * performanceScore
                    + MacBenchmarkScoring.memoryCapacityWeight * memoryCapacityScore
            case .diskRead, .diskWrite:
                componentScores[component] =
                    MacBenchmarkScoring.diskPerformanceWeight * performanceScore
                    + MacBenchmarkScoring.diskCapacityWeight * diskCapacityScore
            case .cpuSingle, .cpuMulti, .gpu:
                componentScores[component] = performanceScore
            }
        }
        guard let overallScore = try? MacBenchmarkScoring.balancedCompositeScore(
            componentScores: componentScores
        ) else { return nil }
        return MacBenchmarkDisplayScore(
            componentScores: componentScores,
            overallScore: overallScore
        )
    }
}

/// A read-only manifest assembled from the versioned fields already persisted
/// by the frozen benchmark result model. Keeping this outside the Standard v6
/// protocol sources makes the version boundary visible without changing the
/// calibrated workload or its source fingerprint.
struct BenchmarkAlgorithmManifest: Equatable, Sendable {
    static let measurementSchemaVersion = "mac-benchmark-measurement-schema-v1"

    let sessionID: UUID
    let measurementSchemaVersion: String
    let workloadVersion: String
    let statisticsVersion: String
    let diagnosticStatisticsVersion: String
    let scoringVersion: String
    let referenceSetVersion: String?

    static func make(for result: MacBenchmarkResult) -> Self? {
        guard let rawResult = result.rawResult,
              let sessionID = BenchmarkSessionIdentity.stableID(for: rawResult)
        else { return nil }
        return Self(
            sessionID: sessionID,
            measurementSchemaVersion: measurementSchemaVersion,
            workloadVersion: rawResult.workloadVersion,
            statisticsVersion: BenchmarkStatistics.frozenResultVersion,
            diagnosticStatisticsVersion: BenchmarkStatistics.version,
            scoringVersion: scoringVersion(for: rawResult.workloadVersion),
            referenceSetVersion: result.matchedBaselineKey?.baselineVersion
                ?? result.comparisonKey?.baselineVersion
        )
    }

    /// Scoring has an independent explicit version map. Do not derive it from
    /// the workload suffix: a future scoring-only revision must be able to move
    /// without renaming the measured workload.
    private static func scoringVersion(for workloadVersion: String) -> String {
        switch workloadVersion {
        case "mac-benchmark-quick-v2", "mac-benchmark-full-v2":
            "mac-benchmark-scoring-v2"
        case "mac-benchmark-quick-v3", "mac-benchmark-full-v3":
            "mac-benchmark-scoring-v3"
        case "mac-benchmark-standard-v4":
            "mac-benchmark-scoring-v4"
        case MacBenchmarkScoring.capacityAwareWorkloadVersion:
            "mac-benchmark-scoring-v5"
        case MacBenchmarkScoring.balancedCompositeWorkloadVersion:
            "mac-benchmark-scoring-v6"
        default:
            "mac-benchmark-scoring-unsupported"
        }
    }
}

enum BenchmarkSessionIdentity {
    /// The identity is derived from the canonical encoded raw result, so it is
    /// stable after a legacy array round-trip without adding fields to the
    /// calibration-frozen result schema.
    static func stableID(for rawResult: MacBenchmarkRawResult) -> UUID? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rawResult) else { return nil }
        let digest = MacBenchmarkBaselineVerification.sha256Hex(data)
        guard digest.count >= 32 else { return nil }

        var characters = Array(digest.prefix(32))
        // Mark this deterministic identifier as UUID version 5 / RFC variant.
        characters[12] = "5"
        characters[16] = "8"
        let compact = String(characters)
        let uuidString = "\(compact.prefix(8))-"
            + "\(compact.dropFirst(8).prefix(4))-"
            + "\(compact.dropFirst(12).prefix(4))-"
            + "\(compact.dropFirst(16).prefix(4))-"
            + "\(compact.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString)
    }
}

enum BenchmarkStatisticsError: Error, Equatable {
    case emptySamples
    case invalidSample
    case invalidPercentile
}

/// Diagnostic statistics derived from persisted raw samples.
///
/// Standard v6 scoring remains frozen on its existing median/CV contract. This
/// layer adds robust spread and percentile evidence without changing a workload,
/// a reference set, or the interpretation of an existing score.
enum BenchmarkStatistics {
    static let version = "mac-benchmark-statistics-v2"
    static let legacyVersion = "mac-benchmark-statistics-v1"
    /// Standard v6 result aggregation remains on its frozen median/CV contract.
    static let frozenResultVersion = legacyVersion
    private static let normalConsistencyFactor = 1.4826
    private static let confidenceBoundaryTolerance = 1e-12

    static func summarize(
        _ samples: [Double]
    ) throws -> BenchmarkStatisticsSummary {
        let sorted = try validatedSorted(samples)
        let median = try percentile(0.50, sortedSamples: sorted)
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = try percentile(0.50, sortedSamples: deviations)
        let relativeMAD = normalConsistencyFactor * mad / median
        guard median.isFinite,
              mad.isFinite,
              relativeMAD.isFinite,
              relativeMAD >= 0 else {
            throw BenchmarkStatisticsError.invalidSample
        }

        let confidence: BenchmarkConfidenceRating
        if relativeMAD <= 0.02 + confidenceBoundaryTolerance {
            confidence = .a
        } else if relativeMAD <= 0.05 + confidenceBoundaryTolerance {
            confidence = .b
        } else {
            confidence = .c
        }

        return BenchmarkStatisticsSummary(
            sampleCount: sorted.count,
            median: median,
            medianAbsoluteDeviation: mad,
            p50: median,
            p95: try percentile(0.95, sortedSamples: sorted),
            p99: try percentile(0.99, sortedSamples: sorted),
            relativeMedianAbsoluteDeviation: relativeMAD,
            confidence: confidence
        )
    }

    static func percentile(
        _ probability: Double,
        samples: [Double]
    ) throws -> Double {
        try percentile(probability, sortedSamples: validatedSorted(samples))
    }

    private static func validatedSorted(
        _ samples: [Double]
    ) throws -> [Double] {
        guard !samples.isEmpty else {
            throw BenchmarkStatisticsError.emptySamples
        }
        guard samples.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BenchmarkStatisticsError.invalidSample
        }
        return samples.sorted()
    }

    /// Linear interpolation on ranks `(count - 1) * probability`.
    private static func percentile(
        _ probability: Double,
        sortedSamples: [Double]
    ) throws -> Double {
        guard probability.isFinite, (0...1).contains(probability) else {
            throw BenchmarkStatisticsError.invalidPercentile
        }
        guard let first = sortedSamples.first else {
            throw BenchmarkStatisticsError.emptySamples
        }
        guard sortedSamples.count > 1 else { return first }

        let rank = Double(sortedSamples.count - 1) * probability
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))
        guard lowerIndex >= 0,
              upperIndex < sortedSamples.count else {
            throw BenchmarkStatisticsError.invalidPercentile
        }
        if lowerIndex == upperIndex { return sortedSamples[lowerIndex] }

        let fraction = rank - Double(lowerIndex)
        let lower = sortedSamples[lowerIndex]
        let upper = sortedSamples[upperIndex]
        let interpolated = lower + ((upper - lower) * fraction)
        guard interpolated.isFinite, interpolated > 0 else {
            throw BenchmarkStatisticsError.invalidSample
        }
        return interpolated
    }
}

extension BenchmarkComponentMeasurement {
    /// Robust diagnostic evidence derived from raw samples. Standard v6 still
    /// scores with its frozen median/CV contract.
    var statistics: BenchmarkStatisticsSummary? {
        try? BenchmarkStatistics.summarize(samples.map(\.value))
    }
}

extension BenchmarkStage {
    fileprivate var presentationSequenceIndex: Int {
        switch self {
        case .preflight: 0
        case .cpuSingle: 1
        case .cpuMulti: 2
        case .gpu: 3
        case .memory: 4
        case .diskWrite: 5
        case .diskRead: 6
        case .finalizing: 7
        }
    }

    func canFollow(
        _ previous: Self,
        previousCompletedSampleCount: Int,
        completedSampleCount: Int
    ) -> Bool {
        guard completedSampleCount >= previousCompletedSampleCount else {
            return false
        }
        if presentationSequenceIndex >= previous.presentationSequenceIndex {
            return true
        }
        // Each disk sample reports write then read. The next sample therefore
        // legitimately moves from diskRead back to diskWrite exactly once.
        return previous == .diskRead
            && self == .diskWrite
            && completedSampleCount == previousCompletedSampleCount + 1
    }
}

extension MacBenchmarkResult {
    var algorithmManifest: BenchmarkAlgorithmManifest? {
        BenchmarkAlgorithmManifest.make(for: self)
    }
}

extension MacBenchmarkState {
    enum Phase: Equatable, Sendable {
        case idle
        case preflighting
        case running
        case cancelling
        case completed
        case cancelled
        case failed
    }

    var phase: Phase {
        switch self {
        case .idle: .idle
        case .preflighting: .preflighting
        case .running: .running
        case .cancelling: .cancelling
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    func canTransition(to next: Self) -> Bool {
        switch (phase, next.phase) {
        case (.idle, .preflighting),
             (.preflighting, .preflighting),
             (.preflighting, .running),
             (.preflighting, .cancelling),
             (.preflighting, .completed),
             (.preflighting, .cancelled),
             (.preflighting, .failed),
             (.running, .running),
             (.running, .cancelling),
             (.running, .completed),
             (.running, .cancelled),
             (.running, .failed),
             (.cancelling, .cancelling),
             (.cancelling, .cancelled),
             (.cancelling, .failed),
             (.completed, .preflighting),
             (.cancelled, .preflighting),
             (.failed, .preflighting):
            true
        default:
            false
        }
    }
}
