import Foundation

enum MacBenchmarkRawOnlyReason: Equatable, Sendable {
    case verifiedBaselineUnavailable
    case unsupportedWorkloadVersion
    case invalidSampleContract
    case implausiblePerformanceRatio
    case unsupportedArchitecture
    case nonComparableEnvironment
    case unstableSamples
    case ambiguousBaseline
}

enum MacBenchmarkResultProcessingError: Error, Equatable, Sendable {
    case incompleteRawResult
    case ambiguousBaseline
    case scoringFailed(MacBenchmarkScoringError)
}

struct ProcessedMacBenchmarkResult: Equatable, Sendable {
    let result: MacBenchmarkResult
    let rawOnlyReason: MacBenchmarkRawOnlyReason?
}

struct MacBenchmarkResultProcessor: Sendable {
    private let baselineCatalog: MacBenchmarkBaselineCatalog
    private let scoring: MacBenchmarkScoring

    var hasVerifiedActiveBaseline: Bool {
        baselineCatalog.hasVerifiedActiveBaseline
    }

    init(
        baselineCatalog: MacBenchmarkBaselineCatalog,
        scoring: MacBenchmarkScoring = MacBenchmarkScoring()
    ) {
        self.baselineCatalog = baselineCatalog
        self.scoring = scoring
    }

    func process(_ rawResult: MacBenchmarkRawResult) throws
        -> ProcessedMacBenchmarkResult
    {
        guard rawResult.failure == nil, rawResult.isComplete else {
            throw MacBenchmarkResultProcessingError.incompleteRawResult
        }
        guard MacBenchmarkScoring.isSupportedWorkloadVersion(
            rawResult.workloadVersion,
            profile: rawResult.profile
        ) else {
            return Self.rawOnly(rawResult, reason: .unsupportedWorkloadVersion)
        }
        guard MacBenchmarkScoring.hasValidSampleContract(rawResult) else {
            return Self.rawOnly(rawResult, reason: .invalidSampleContract)
        }
        guard rawResult.environment.architecture == .arm64 else {
            return Self.rawOnly(rawResult, reason: .unsupportedArchitecture)
        }
        guard MacBenchmarkScoring.hasComparableMeasurementStability(rawResult) else {
            return ProcessedMacBenchmarkResult(
                result: MacBenchmarkScoring.rawOnly(rawResult: rawResult),
                rawOnlyReason: .unstableSamples
            )
        }
        guard MacBenchmarkScoring.hasComparableEnvironment(rawResult) else {
            return ProcessedMacBenchmarkResult(
                result: MacBenchmarkScoring.rawOnly(rawResult: rawResult),
                rawOnlyReason: .nonComparableEnvironment
            )
        }

        switch baselineCatalog.lookup(matching: rawResult) {
        case let .matched(baseline):
            do {
                return ProcessedMacBenchmarkResult(
                    result: try scoring.score(
                        rawResult: rawResult,
                        against: baseline
                    ),
                    rawOnlyReason: nil
                )
            } catch let error as MacBenchmarkScoringError {
                switch error {
                case .nonComparableEnvironment:
                    return Self.rawOnly(rawResult, reason: .nonComparableEnvironment)
                case .unsupportedWorkloadVersion:
                    return Self.rawOnly(rawResult, reason: .unsupportedWorkloadVersion)
                case .invalidSampleContract:
                    return Self.rawOnly(rawResult, reason: .invalidSampleContract)
                case .performanceRatioOutsideAcceptedRange:
                    return Self.rawOnly(rawResult, reason: .implausiblePerformanceRatio)
                case .incompleteResult, .comparisonKeyMismatch, .invalidMetric:
                    throw MacBenchmarkResultProcessingError.scoringFailed(error)
                }
            }
        case .notFound:
            return ProcessedMacBenchmarkResult(
                result: MacBenchmarkScoring.rawOnly(rawResult: rawResult),
                rawOnlyReason: .verifiedBaselineUnavailable
            )
        case .unsupportedArchitecture:
            return ProcessedMacBenchmarkResult(
                result: MacBenchmarkScoring.rawOnly(rawResult: rawResult),
                rawOnlyReason: .unsupportedArchitecture
            )
        case .ambiguous:
            return ProcessedMacBenchmarkResult(
                result: MacBenchmarkScoring.rawOnly(rawResult: rawResult),
                rawOnlyReason: .ambiguousBaseline
            )
        }
    }

    private static func rawOnly(
        _ rawResult: MacBenchmarkRawResult,
        reason: MacBenchmarkRawOnlyReason
    ) -> ProcessedMacBenchmarkResult {
        ProcessedMacBenchmarkResult(
            result: MacBenchmarkScoring.rawOnly(rawResult: rawResult),
            rawOnlyReason: reason
        )
    }
}
