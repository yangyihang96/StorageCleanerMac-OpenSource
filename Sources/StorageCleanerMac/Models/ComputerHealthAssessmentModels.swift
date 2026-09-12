import Foundation

enum HealthFactor: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case diskReliability
    case capacity
    case stability
    case backup
    case battery
}

enum HealthEvidenceAvailability: String, Codable, Equatable, Hashable, Sendable {
    case available
    case partial
    case permissionDenied
    case timedOut
    case unavailable
    case notApplicable
}

struct HealthComponentEvaluation: Codable, Equatable, Sendable {
    let factor: HealthFactor
    let availability: HealthEvidenceAvailability
    let score: Double?
    let evidenceSummary: String?
    let evaluatedAt: Date
    let modelVersion: String

    init(
        factor: HealthFactor,
        availability: HealthEvidenceAvailability,
        score: Double?,
        evidenceSummary: String? = nil,
        evaluatedAt: Date,
        modelVersion: String
    ) {
        self.factor = factor
        self.availability = availability
        self.score = score
        self.evidenceSummary = evidenceSummary
        self.evaluatedAt = evaluatedAt
        self.modelVersion = modelVersion
    }
}

enum HealthConfidenceLevel: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

enum ThermalReadiness: String, Codable, Equatable, Sendable {
    case ready
    case elevated
    case constrained
    case critical
    case unknown
}

struct HealthConfidence: Codable, Equatable, Sendable {
    let value: Int
    let level: HealthConfidenceLevel
    let modelVersion: String
}

enum ComputerHealthEvaluationStatus: String, Codable, Equatable, Sendable {
    case healthy
    case attention
    case actionRequired
    case dataInsufficient
}

struct ComputerHealthEvaluation: Codable, Equatable, Sendable {
    static let currentModelVersion = "computer-health-v2"

    let score: Double?
    let status: ComputerHealthEvaluationStatus
    let coverage: Double
    let confidence: HealthConfidence
    let components: [HealthComponentEvaluation]
    let evaluatedAt: Date
    let modelVersion: String

    init(
        score: Double?,
        status: ComputerHealthEvaluationStatus,
        coverage: Double,
        confidence: HealthConfidence,
        components: [HealthComponentEvaluation],
        evaluatedAt: Date,
        modelVersion: String = ComputerHealthEvaluation.currentModelVersion
    ) {
        self.score = score
        self.status = status
        self.coverage = coverage
        self.confidence = confidence
        self.components = components
        self.evaluatedAt = evaluatedAt
        self.modelVersion = modelVersion
    }

    static func dataInsufficient(
        coverage: Double,
        confidence: HealthConfidence,
        components: [HealthComponentEvaluation],
        evaluatedAt: Date = Date(),
        modelVersion: String = ComputerHealthEvaluation.currentModelVersion
    ) -> ComputerHealthEvaluation {
        ComputerHealthEvaluation(
            score: nil,
            status: .dataInsufficient,
            coverage: coverage,
            confidence: confidence,
            components: components,
            evaluatedAt: evaluatedAt,
            modelVersion: modelVersion
        )
    }
}

struct ComputerHealthHistoryEntry: Codable, Equatable, Sendable {
    static let currentModelVersion = "computer-health-history-v1"

    let recordedAt: Date
    let evaluation: ComputerHealthEvaluation
    let totalBytes: Int64?
    let availableForImportantUsageBytes: Int64?
    let diskRemainingLifePercent: Int?
    let maximumCapacityPercent: Int?
    let batteryCycleCount: Int?
    let latestVerifiedCompleteBackupAt: Date?
    let modelVersion: String

    init(
        recordedAt: Date,
        evaluation: ComputerHealthEvaluation,
        totalBytes: Int64? = nil,
        availableForImportantUsageBytes: Int64? = nil,
        diskRemainingLifePercent: Int? = nil,
        maximumCapacityPercent: Int? = nil,
        batteryCycleCount: Int? = nil,
        latestVerifiedCompleteBackupAt: Date? = nil,
        modelVersion: String = ComputerHealthHistoryEntry.currentModelVersion
    ) {
        self.recordedAt = recordedAt
        self.evaluation = evaluation
        self.totalBytes = totalBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.diskRemainingLifePercent = diskRemainingLifePercent
        self.maximumCapacityPercent = maximumCapacityPercent
        self.batteryCycleCount = batteryCycleCount
        self.latestVerifiedCompleteBackupAt = latestVerifiedCompleteBackupAt
        self.modelVersion = modelVersion
    }
}
