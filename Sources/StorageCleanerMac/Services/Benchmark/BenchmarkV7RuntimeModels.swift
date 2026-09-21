import Foundation

enum BenchmarkV7Phase: String, Codable, Sendable, Equatable {
    case idle
    case preflighting
    case ready
    case preparing
    case warmingUp
    case calibrating
    case running
    case validating
    case aggregating
    case scoring
    case persisting
    case cancelling
    case cancelled
    case failed
    case completed

    var isActive: Bool {
        switch self {
        case .preflighting, .preparing, .warmingUp, .calibrating, .running,
             .validating, .aggregating, .scoring, .persisting, .cancelling:
            true
        case .idle, .ready, .cancelled, .failed, .completed:
            false
        }
    }
}

enum BenchmarkV7Failure: Equatable, Codable, Sendable {
    case alreadyRunning
    case cancelled
    case timedOut(BenchmarkV7TimeoutContext)
    /// The deadline elapsed while the operation remained alive. The cleanup
    /// quarantine stays held, so the app must be restarted before another run.
    case restartRequired(BenchmarkV7TimeoutContext)
    case preflightBlocked
    case unsupportedCategory(BenchmarkV7Category)
    case invalidMeasurement(String)
    case validationFailed(String)
    case persistenceFailed
    case internalFailure

    var requiresApplicationRestart: Bool {
        if case .restartRequired = self { return true }
        return false
    }
}

struct BenchmarkV7TimeoutContext: Equatable, Codable, Sendable {
    let phase: BenchmarkV7Phase
    let category: BenchmarkV7Category?
    let workloadID: String?

    var detail: String {
        var parts = ["phase=\(phase.rawValue)"]
        if let category { parts.append("category=\(category.rawValue)") }
        if let workloadID, !workloadID.isEmpty {
            parts.append("workload=\(workloadID)")
        }
        return parts.joined(separator: " ")
    }
}

struct BenchmarkV7PreflightOutcome: Sendable {
    let report: BenchmarkV7PreflightReport
    let failure: BenchmarkV7Failure?
}

struct BenchmarkV7TimeoutPolicy: Sendable {
    let preflight: Duration
    let workloadGrace: Duration
    let sustainedGrace: Duration
    let persistence: Duration
    private let usesDeclaredDurations: Bool

    static let standard = Self(
        preflight: .seconds(30),
        workloadGrace: .seconds(60),
        sustainedGrace: .seconds(30),
        persistence: .seconds(30),
        usesDeclaredDurations: true
    )

    static func testing(milliseconds: Int) -> Self {
        let timeout = Duration.milliseconds(max(1, milliseconds))
        return Self(
            preflight: timeout,
            workloadGrace: timeout,
            sustainedGrace: timeout,
            persistence: timeout,
            usesDeclaredDurations: false
        )
    }

    func workload(
        plan: BenchmarkV7Plan,
        includesSustainedCheck: Bool
    ) -> Duration {
        guard usesDeclaredDurations else { return workloadGrace }
        let sustainedSeconds = includesSustainedCheck
            ? Int(MacSustainedBenchmarkProfile.standard.targetDurationSeconds)
            : 0
        return .seconds(max(1, plan.expectedMaximumDurationSeconds - sustainedSeconds))
            + workloadGrace
    }

    func sustained(
        profile: MacSustainedBenchmarkProfile = .standard
    ) -> Duration {
        usesDeclaredDurations
            ? .seconds(profile.targetDurationSeconds) + sustainedGrace
            : sustainedGrace
    }
}

enum BenchmarkV7TransitionError: Error, Equatable, Sendable {
    case invalidTransition(from: BenchmarkV7Phase, to: BenchmarkV7Phase)
}

struct BenchmarkV7State: Equatable, Codable, Sendable {
    let phase: BenchmarkV7Phase
    let sessionID: UUID?
    let category: BenchmarkV7Category?
    let workloadID: String?
    let repetition: Int?
    let progress: Double?
    let failure: BenchmarkV7Failure?

    static let idle = Self(
        phase: .idle,
        sessionID: nil,
        category: nil,
        workloadID: nil,
        repetition: nil,
        progress: nil,
        failure: nil
    )

    static func phase(
        _ phase: BenchmarkV7Phase,
        sessionID: UUID,
        category: BenchmarkV7Category? = nil,
        workloadID: String? = nil,
        repetition: Int? = nil,
        progress: Double? = nil
    ) -> Self {
        Self(
            phase: phase,
            sessionID: sessionID,
            category: category,
            workloadID: workloadID,
            repetition: repetition,
            progress: normalizedProgress(progress),
            failure: nil
        )
    }

    private static func normalizedProgress(_ progress: Double?) -> Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(1, max(0, progress))
    }

    static func failed(_ failure: BenchmarkV7Failure, sessionID: UUID) -> Self {
        Self(
            phase: .failed,
            sessionID: sessionID,
            category: nil,
            workloadID: nil,
            repetition: nil,
            progress: nil,
            failure: failure
        )
    }

    func canTransition(to next: BenchmarkV7State) -> Bool {
        guard sessionID == next.sessionID || phase == .idle else { return false }
        return switch (phase, next.phase) {
        case (.idle, .preflighting),
             (.preflighting, .ready),
             (.preflighting, .cancelling),
             (.preflighting, .cancelled),
             (.preflighting, .failed),
             (.ready, .preparing),
             (.ready, .preflighting),
             (.ready, .idle),
             (.preparing, .warmingUp),
             (.preparing, .calibrating),
             (.preparing, .running),
             (.warmingUp, .calibrating),
             (.warmingUp, .running),
             (.calibrating, .running),
             (.running, .running),
             (.running, .validating),
             (.validating, .aggregating),
             (.aggregating, .scoring),
             (.scoring, .persisting),
             (.persisting, .completed),
             (.preparing, .cancelling),
             (.warmingUp, .cancelling),
             (.calibrating, .cancelling),
             (.running, .cancelling),
             (.validating, .cancelling),
             (.aggregating, .cancelling),
             (.scoring, .cancelling),
             (.persisting, .cancelling),
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

struct BenchmarkV7StateMachine: Sendable {
    private(set) var state: BenchmarkV7State = .idle

    mutating func transition(to next: BenchmarkV7State) -> Result<Void, BenchmarkV7TransitionError> {
        guard state.canTransition(to: next) else {
            #if DEBUG
            assertionFailure("Illegal benchmark v7 transition: \(state.phase) -> \(next.phase)")
            #endif
            return .failure(.invalidTransition(from: state.phase, to: next.phase))
        }
        state = next
        return .success(())
    }
}

struct BenchmarkV7StorageTarget: Equatable, Codable, Sendable {
    let volumeName: String
    let fileSystem: String?
    let availableBytes: Int64
    let isReadOnly: Bool

    var isValid: Bool {
        !volumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && availableBytes >= 0
    }
}

enum BenchmarkV7PreflightSeverity: String, Codable, Sendable, Equatable {
    case pass
    case warning
    case blocked
}

enum BenchmarkV7PreflightIssue: String, Codable, Sendable, CaseIterable {
    case acPowerRecommended
    case lowPowerMode
    case thermalFair
    case thermalSerious
    case thermalCritical
    case highBackgroundLoad
    case lowAvailableMemory
    case storageSpaceInsufficient
    case targetVolumeReadOnly
    case displayMirroring
    case displayUnavailable
}

struct BenchmarkV7PreflightCheck: Equatable, Codable, Sendable {
    let issue: BenchmarkV7PreflightIssue
    let severity: BenchmarkV7PreflightSeverity
    let detail: String
}

struct BenchmarkV7PreflightReport: Equatable, Codable, Sendable {
    let capturedAt: Date
    let powerSource: BenchmarkPowerSource
    let batteryPercent: Double?
    let lowPowerModeEnabled: Bool
    let thermalState: BenchmarkThermalState
    let backgroundLoadRatio: Double?
    let availableMemoryBytes: UInt64?
    let storageTarget: BenchmarkV7StorageTarget
    let displayDescription: String?
    let checks: [BenchmarkV7PreflightCheck]
    let blockedCategories: [BenchmarkV7Category]

    var hasBlockingIssue: Bool {
        checks.contains { $0.severity == .blocked }
    }

    var warnings: [BenchmarkV7PreflightCheck] {
        checks.filter { $0.severity == .warning }
    }

    /// Serious/critical thermal pressure and unsafe storage targets are hard
    /// safety boundaries. Fair thermal pressure remains advisory.
    var hardBlockedCategories: Set<BenchmarkV7Category> {
        let hasUnsafeThermalState = checks.contains { check in
            check.severity == .blocked
                && (check.issue == .thermalSerious || check.issue == .thermalCritical)
        }
        let hasUnsafeStorageTarget = checks.contains { check in
            check.severity == .blocked
                && (check.issue == .storageSpaceInsufficient
                    || check.issue == .targetVolumeReadOnly)
        }
        var categories = hasUnsafeThermalState
            ? Set(BenchmarkV7Category.allCases)
            : []
        if hasUnsafeStorageTarget {
            categories.insert(.storage)
        }
        return categories
    }
}

struct BenchmarkV7Session: Equatable, Codable, Sendable, Identifiable {
    let id: UUID
    let plan: BenchmarkV7Plan
    let categories: [BenchmarkV7Category]
    let storageTarget: BenchmarkV7StorageTarget
    let startedAt: Date
    let forcedPreflightContinuation: Bool

    init(
        id: UUID = UUID(),
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category]? = nil,
        storageTarget: BenchmarkV7StorageTarget,
        startedAt: Date = Date(),
        forcedPreflightContinuation: Bool = false
    ) {
        self.id = id
        self.plan = plan
        self.categories = categories ?? plan.categories
        self.storageTarget = storageTarget
        self.startedAt = startedAt
        self.forcedPreflightContinuation = forcedPreflightContinuation
    }

    var isValid: Bool {
        plan.isValid
            && !categories.isEmpty
            && Set(categories).count == categories.count
            && Set(categories).isSubset(of: Set(plan.categories))
            && storageTarget.isValid
    }
}

struct BenchmarkV7RawSample: Equatable, Codable, Sendable {
    let value: Double
    let elapsedSeconds: Double
    let wallElapsedSeconds: Double?
    let checksum: UInt64?

    var isValid: Bool {
        value.isFinite && value > 0
            && elapsedSeconds.isFinite && elapsedSeconds > 0
            && (wallElapsedSeconds == nil
                || (wallElapsedSeconds!.isFinite && wallElapsedSeconds! > 0))
    }
}

struct BenchmarkV7MetricResult: Equatable, Codable, Sendable {
    let manifest: BenchmarkV7MetricManifest
    let samples: [BenchmarkV7RawSample]
    let statistics: BenchmarkStatisticsSummary

    var isValid: Bool {
        manifest.isValid
            && !samples.isEmpty
            && samples.allSatisfy(\.isValid)
            && statistics.sampleCount == samples.count
    }
}

enum BenchmarkV7ConfidenceRating: String, Codable, Sendable, Equatable {
    case high
    case medium
    case low
}

struct BenchmarkV7Confidence: Equatable, Codable, Sendable {
    let rating: BenchmarkV7ConfidenceRating
    let maximumRelativeMAD: Double?
    let reasons: [String]
}

enum BenchmarkV7CompletionStatus: String, Equatable, Codable, Sendable {
    case completed
    case partiallyCompleted
    case failed
    case cancelled
}

enum BenchmarkV7WorkloadExecutionStatus: String, Equatable, Codable, Sendable {
    case completed
    case failed
    case cancelled
    case timedOut
}

struct BenchmarkV7WorkloadExecutionRecord: Equatable, Codable, Sendable {
    let category: BenchmarkV7Category
    let workloadID: String
    let repetition: Int?
    let startedAt: Date
    let endedAt: Date
    let elapsedSeconds: Double
    let status: BenchmarkV7WorkloadExecutionStatus
    let failureReason: String?

    var isValid: Bool {
        !workloadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (repetition == nil || repetition! > 0)
            && endedAt >= startedAt
            && elapsedSeconds.isFinite
            && elapsedSeconds >= 0
            && (status == .completed
                ? failureReason == nil
                : failureReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
}

/// Persisted failure context for the exact workload that stopped a session.
/// Optional fields on `BenchmarkV7Result` keep early v7 JSON decodable.
struct BenchmarkV7WorkloadFailureRecord: Equatable, Codable, Sendable {
    let category: BenchmarkV7Category
    let workloadID: String
    let reason: String

    var isValid: Bool {
        !workloadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct BenchmarkV7Result: Equatable, Codable, Sendable {
    /// A history record is not the same thing as a measurement session: a
    /// cancellation/failure record may legitimately share a session ID with a
    /// prior result. New records always carry a distinct persistent identity.
    let recordID: UUID?
    let mSeries: MSeriesResult?
    let session: BenchmarkV7Session
    let preflight: BenchmarkV7PreflightReport
    /// The non-sensitive system snapshot that accompanied this session. New
    /// production records always fill this; `nil` remains decodable for early
    /// v7 fixtures rather than rewriting them during migration.
    let environment: BenchmarkEnvironmentMetadata?
    /// Optional non-unique hardware details collected by the V7 provider.
    /// Early V7 history predates this field and decodes it as nil.
    let hardwareProfile: BenchmarkV7HardwareProfile?
    let versions: BenchmarkV7VersionManifest
    let metrics: [BenchmarkV7MetricResult]
    let coreScore: BenchmarkV7CoreScore?
    let experienceScore: BenchmarkV7ExperienceScore?
    /// Retains the full serial sustained run, including raw windows and thermal
    /// telemetry, instead of collapsing it into a Core score.
    let sustainedResult: MacSustainedBenchmarkResult?
    let confidence: BenchmarkV7Confidence?
    /// Explicit run-time observations that are not score inputs (for example
    /// unavailable display cadence). They keep partial results honest.
    let runtimeWarnings: [String]
    /// New records persist an explicit terminal status. `nil` remains valid for
    /// early v7 history and is interpreted from the existing terminal fields.
    let completionStatus: BenchmarkV7CompletionStatus?
    let workloadFailure: BenchmarkV7WorkloadFailureRecord?
    /// Optional only for decoding early v7 history written before per-workload
    /// execution records existed. New results always persist an array.
    let workloadExecutions: [BenchmarkV7WorkloadExecutionRecord]?
    let completedAt: Date?
    let failure: BenchmarkV7Failure?

    init(
        recordID: UUID? = UUID(),
        mSeries: MSeriesResult? = nil,
        session: BenchmarkV7Session,
        preflight: BenchmarkV7PreflightReport,
        environment: BenchmarkEnvironmentMetadata? = nil,
        hardwareProfile: BenchmarkV7HardwareProfile? = nil,
        versions: BenchmarkV7VersionManifest,
        metrics: [BenchmarkV7MetricResult],
        coreScore: BenchmarkV7CoreScore?,
        experienceScore: BenchmarkV7ExperienceScore? = nil,
        sustainedResult: MacSustainedBenchmarkResult? = nil,
        confidence: BenchmarkV7Confidence? = nil,
        runtimeWarnings: [String] = [],
        completionStatus: BenchmarkV7CompletionStatus? = nil,
        workloadFailure: BenchmarkV7WorkloadFailureRecord? = nil,
        workloadExecutions: [BenchmarkV7WorkloadExecutionRecord]? = [],
        completedAt: Date?,
        failure: BenchmarkV7Failure?
    ) {
        self.recordID = recordID
        self.mSeries = mSeries
        self.session = session
        self.preflight = preflight
        self.environment = environment
        self.hardwareProfile = hardwareProfile
        self.versions = versions
        self.metrics = metrics
        self.coreScore = coreScore
        self.experienceScore = experienceScore
        self.sustainedResult = sustainedResult
        self.confidence = confidence
        self.runtimeWarnings = runtimeWarnings
        self.completionStatus = completionStatus ?? Self.inferredCompletionStatus(
            metrics: metrics,
            completedAt: completedAt,
            failure: failure
        )
        self.workloadFailure = workloadFailure
        self.workloadExecutions = workloadExecutions
        self.completedAt = completedAt
        self.failure = failure
    }

    var resolvedCompletionStatus: BenchmarkV7CompletionStatus? {
        completionStatus ?? Self.inferredCompletionStatus(
            metrics: metrics,
            completedAt: completedAt,
            failure: failure
        )
    }

    var isPartiallyCompleted: Bool {
        resolvedCompletionStatus == .partiallyCompleted
    }

    var isComplete: Bool {
        if let mSeries { return failure == nil && isPersistable && mSeries.isCompleteCore }
        return failure == nil
            && completedAt != nil
            && isPersistable
            && !metrics.isEmpty
            && Self.scoresSatisfyCompletionContract(
                plan: session.plan,
                categories: session.categories,
                coreScore: coreScore,
                experienceScore: experienceScore
            )
    }

    static func scoresSatisfyCompletionContract(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        coreScore: BenchmarkV7CoreScore?,
        experienceScore: BenchmarkV7ExperienceScore?
    ) -> Bool {
        // Quick/custom and partial standard captures remain valid raw-only
        // records. A full standard session is the scored product contract.
        guard plan.kind == .standard,
              BenchmarkV7Plan.standard.categories.allSatisfy(categories.contains)
        else {
            return true
        }
        guard let coreScore, let experienceScore else { return false }
        return coreScore.overallScore.isFinite
            && coreScore.overallScore > 0
            && experienceScore.overallScore.isFinite
            && experienceScore.overallScore > 0
    }

    var isPersistable: Bool {
        if let mSeries {
            return session.isValid && session.id == mSeries.sessionID
                && session.plan == MSeriesProtocol.officialPlan && versions == MSeriesProtocol.versions
                && mSeries.isValid && metrics.isEmpty && coreScore == nil && experienceScore == nil
                && sustainedResult == nil
        }
        return session.plan.planVersion != MSeriesProtocol.plan
            && versions.schemaVersion == BenchmarkV7VersionManifest.resultSchemaVersion && session.isValid
            && versions.isValid
            && metrics.allSatisfy(\.isValid)
            && (workloadFailure?.isValid ?? true)
            && (workloadExecutions?.allSatisfy(\.isValid) ?? true)
    }

    private static func inferredCompletionStatus(
        metrics: [BenchmarkV7MetricResult],
        completedAt: Date?,
        failure: BenchmarkV7Failure?
    ) -> BenchmarkV7CompletionStatus? {
        if failure == .cancelled { return .cancelled }
        if failure != nil { return metrics.isEmpty ? .failed : .partiallyCompleted }
        if completedAt != nil { return .completed }
        return nil
    }
}
