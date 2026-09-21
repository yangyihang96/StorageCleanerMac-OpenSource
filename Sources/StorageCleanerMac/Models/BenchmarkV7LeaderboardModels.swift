import Foundation

enum BenchmarkV7LeaderboardConstants {
    static let schemaVersion = 2
    static let pageSize = 50
    static let maximumResponseBytes = 512 * 1_024

    static var currentVersions: BenchmarkV7VersionManifest {
        BenchmarkV7ReferenceCatalog.versions(for: OfficialBenchmarkPlan.legacyV9.plan)
    }

    static let requiredCoreMetricIDs = [
        "cpu.single.mixed",
        "cpu.multi.particle",
        "gpu.graphics.offscreen",
        "gpu.compute.fp16",
        "memory.copy.bandwidth",
        "memory.triad.bandwidth",
        "memory.pointer-chase.latency",
        "storage.sequential.read",
        "storage.sequential.write",
        "storage.random.read.qd1.iops",
        "storage.random.read.qd1.latency.p50.ns",
        "storage.random.read.qd1.latency.p95.ns",
        "storage.random.read.qd16.iops",
        "storage.random.read.qd16.latency.p50.ns",
        "storage.random.read.qd16.latency.p95.ns",
        "storage.random.write.qd1.iops",
        "storage.random.write.qd1.latency.p50.ns",
        "storage.random.write.qd1.latency.p95.ns",
        "storage.random.write.qd16.iops",
        "storage.random.write.qd16.latency.p50.ns",
        "storage.random.write.qd16.latency.p95.ns",
    ]
}

enum BenchmarkV7LeaderboardEligibilityError: Error, Equatable, Sendable {
    case notRankingEligible
    case missingIdentity
    case missingEnvironment
    case missingComputerModel
    case incompatibleVersions
    case incompleteMetrics
    case invalidPublicData
}

struct BenchmarkV7LeaderboardConditions: Equatable, Codable, Sendable {
    let powerSource: String
    let lowPowerModeEnabled: Bool
    let thermalState: String
    let confidence: String
    let sustainedReachedTargetDuration: Bool
}

struct BenchmarkV7LeaderboardSubmission: Equatable, Encodable, Sendable {
    let submissionId: String
    let installationId: String
    let displayName: String
    let computerModel: String
    let processorModel: String
    let memoryGB: Int
    let architecture: String
    let planVersion: String
    let workloadVersion: String
    let scoringVersion: String
    let referenceSetVersion: String
    let completedAt: String
    let appVersion: String
    let appBuild: String
    let conditions: BenchmarkV7LeaderboardConditions
    let metrics: [String: Double]
    let proposedScore: Double
}

struct BenchmarkV7LeaderboardRemoval: Equatable, Encodable, Sendable {
    let installationId: String
    let workloadVersion: String
}

struct BenchmarkV7LeaderboardEntry: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let rank: Int
    let displayName: String
    let computerModel: String
    let processorModel: String
    let memoryGB: Int
    let score: Double
    let workloadVersion: String
    let completedOn: String
    /// "high", "medium" or "low". Older server responses may omit it.
    let confidence: String?
}

struct BenchmarkV7LeaderboardPagination: Equatable, Decodable, Sendable {
    let page: Int
    let pageSize: Int
    let total: Int
    let totalPages: Int
}

struct BenchmarkV7LeaderboardMetadata: Equatable, Sendable, Decodable {
    let generatedAt: Date
    let planVersion: String
    let workloadVersion: String
    let scoringVersion: String
    let referenceSetVersion: String

    init(
        generatedAt: Date,
        planVersion: String,
        workloadVersion: String,
        scoringVersion: String,
        referenceSetVersion: String
    ) {
        self.generatedAt = generatedAt
        self.planVersion = planVersion
        self.workloadVersion = workloadVersion
        self.scoringVersion = scoringVersion
        self.referenceSetVersion = referenceSetVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generatedAt = try container.decode(String.self, forKey: .generatedAt)
        guard let date = MacBenchmarkLeaderboardDateCodec.date(from: generatedAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .generatedAt,
                in: container,
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        self.generatedAt = date
        planVersion = try container.decode(String.self, forKey: .planVersion)
        workloadVersion = try container.decode(String.self, forKey: .workloadVersion)
        scoringVersion = try container.decode(String.self, forKey: .scoringVersion)
        referenceSetVersion = try container.decode(String.self, forKey: .referenceSetVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case planVersion
        case workloadVersion
        case scoringVersion
        case referenceSetVersion
    }
}

struct BenchmarkV7LeaderboardPage: Equatable, Decodable, Sendable {
    let data: [BenchmarkV7LeaderboardEntry]
    let pagination: BenchmarkV7LeaderboardPagination
    let meta: BenchmarkV7LeaderboardMetadata
}

struct BenchmarkV7LeaderboardReceiptMetadata: Equatable, Sendable, Decodable {
    let submittedAt: Date
    let planVersion: String
    let workloadVersion: String
    let scoringVersion: String
    let referenceSetVersion: String

    init(
        submittedAt: Date,
        planVersion: String,
        workloadVersion: String,
        scoringVersion: String,
        referenceSetVersion: String
    ) {
        self.submittedAt = submittedAt
        self.planVersion = planVersion
        self.workloadVersion = workloadVersion
        self.scoringVersion = scoringVersion
        self.referenceSetVersion = referenceSetVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let submittedAt = try container.decode(String.self, forKey: .submittedAt)
        guard let date = MacBenchmarkLeaderboardDateCodec.date(from: submittedAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .submittedAt,
                in: container,
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        self.submittedAt = date
        planVersion = try container.decode(String.self, forKey: .planVersion)
        workloadVersion = try container.decode(String.self, forKey: .workloadVersion)
        scoringVersion = try container.decode(String.self, forKey: .scoringVersion)
        referenceSetVersion = try container.decode(String.self, forKey: .referenceSetVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case submittedAt
        case planVersion
        case workloadVersion
        case scoringVersion
        case referenceSetVersion
    }
}

enum BenchmarkV7LeaderboardDisposition: String, Equatable, Decodable, Sendable {
    case created
    case updated
    case unchanged
}

struct BenchmarkV7LeaderboardReceipt: Equatable, Decodable, Sendable {
    let data: BenchmarkV7LeaderboardEntry
    let disposition: BenchmarkV7LeaderboardDisposition
    let meta: BenchmarkV7LeaderboardReceiptMetadata
}

struct BenchmarkV7LeaderboardRemovalReceipt: Equatable, Decodable, Sendable {
    struct DataPayload: Equatable, Decodable, Sendable {
        let deleted: Bool
    }

    struct Metadata: Equatable, Sendable, Decodable {
        let deletedAt: Date
        let planVersion: String
        let workloadVersion: String
        let scoringVersion: String
        let referenceSetVersion: String

        init(
            deletedAt: Date,
            planVersion: String,
            workloadVersion: String,
            scoringVersion: String,
            referenceSetVersion: String
        ) {
            self.deletedAt = deletedAt
            self.planVersion = planVersion
            self.workloadVersion = workloadVersion
            self.scoringVersion = scoringVersion
            self.referenceSetVersion = referenceSetVersion
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let deletedAt = try container.decode(String.self, forKey: .deletedAt)
            guard let date = MacBenchmarkLeaderboardDateCodec.date(from: deletedAt) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deletedAt,
                    in: container,
                    debugDescription: "Invalid ISO-8601 date"
                )
            }
            self.deletedAt = date
            planVersion = try container.decode(String.self, forKey: .planVersion)
            workloadVersion = try container.decode(String.self, forKey: .workloadVersion)
            scoringVersion = try container.decode(String.self, forKey: .scoringVersion)
            referenceSetVersion = try container.decode(String.self, forKey: .referenceSetVersion)
        }

        private enum CodingKeys: String, CodingKey {
            case deletedAt
            case planVersion
            case workloadVersion
            case scoringVersion
            case referenceSetVersion
        }
    }

    let data: DataPayload
    let meta: Metadata
}

struct BenchmarkV7LeaderboardDraft: Identifiable, Equatable, Sendable {
    let submissionID: UUID
    let installationID: UUID
    let displayName: String
    let computerModel: String
    let processorModel: String
    let memoryGB: Int
    let architecture: String
    let versions: BenchmarkV7VersionManifest
    let completedAt: Date
    let appVersion: String
    let appBuild: String
    let conditions: BenchmarkV7LeaderboardConditions
    let metrics: [String: Double]
    let score: Double

    var id: UUID { submissionID }

    static func make(
        result: BenchmarkV7Result,
        installationID: UUID,
        displayName: String
    ) throws -> Self {
        guard result.isLegacyArchiveEligible else {
            throw BenchmarkV7LeaderboardEligibilityError.notRankingEligible
        }
        guard let recordID = result.recordID else {
            throw BenchmarkV7LeaderboardEligibilityError.missingIdentity
        }
        guard let environment = result.environment else {
            throw BenchmarkV7LeaderboardEligibilityError.missingEnvironment
        }
        guard let rawComputerModel = result.hardwareProfile?.computerModel,
              let computerModel = BenchmarkV7LeaderboardText.normalized(
                  rawComputerModel,
                  maximumCharacters: 80,
                  maximumBytes: 240
              ) else {
            throw BenchmarkV7LeaderboardEligibilityError.missingComputerModel
        }
        guard let completedAt = result.completedAt,
              let coreScore = result.coreScore,
              coreScore.overallScore.isFinite,
              coreScore.overallScore > 0 else {
            throw BenchmarkV7LeaderboardEligibilityError.notRankingEligible
        }

        let currentVersions = BenchmarkV7LeaderboardConstants.currentVersions
        guard result.versions == currentVersions else {
            throw BenchmarkV7LeaderboardEligibilityError.incompatibleVersions
        }
        guard let normalizedName = BenchmarkV7LeaderboardText.normalized(
            displayName,
            maximumCharacters: 40,
            maximumBytes: 120
        ), let processorModel = BenchmarkV7LeaderboardText.normalized(
            environment.chipName,
            maximumCharacters: 80,
            maximumBytes: 240
        ), !environment.appVersion.isEmpty,
           (8...20).contains(environment.appBuild.count),
           environment.appBuild.allSatisfy(\.isNumber),
           environment.architecture == .arm64 else {
            throw BenchmarkV7LeaderboardEligibilityError.invalidPublicData
        }

        let gibibyte = UInt64(1_073_741_824)
        let roundedMemory = Int(
            (Double(environment.physicalMemoryBytes) / Double(gibibyte)).rounded()
        )
        guard (1...2_048).contains(roundedMemory) else {
            throw BenchmarkV7LeaderboardEligibilityError.invalidPublicData
        }

        let requiredIDs = Set(BenchmarkV7LeaderboardConstants.requiredCoreMetricIDs)
        let candidates = result.metrics.filter { requiredIDs.contains($0.manifest.id) }
        let grouped = Dictionary(grouping: candidates, by: { $0.manifest.id })
        guard Set(grouped.keys) == requiredIDs else {
            throw BenchmarkV7LeaderboardEligibilityError.incompleteMetrics
        }
        var metrics: [String: Double] = [:]
        for id in BenchmarkV7LeaderboardConstants.requiredCoreMetricIDs {
            guard let matches = grouped[id], matches.count == 1,
                  let metric = matches.first,
                  BenchmarkV7Category.corePerformance.contains(metric.manifest.category),
                  metric.isValid,
                  metric.statistics.median.isFinite,
                  metric.statistics.median > 0 else {
                throw BenchmarkV7LeaderboardEligibilityError.incompleteMetrics
            }
            metrics[id] = metric.statistics.median
        }

        guard let confidence = result.confidence else {
            throw BenchmarkV7LeaderboardEligibilityError.notRankingEligible
        }
        return Self(
            submissionID: recordID,
            installationID: installationID,
            displayName: normalizedName,
            computerModel: computerModel,
            processorModel: processorModel,
            memoryGB: roundedMemory,
            architecture: environment.architecture.rawValue,
            versions: currentVersions,
            completedAt: completedAt,
            appVersion: environment.appVersion,
            appBuild: environment.appBuild,
            conditions: BenchmarkV7LeaderboardConditions(
                powerSource: BenchmarkPowerSource.acPower.rawValue,
                lowPowerModeEnabled: false,
                thermalState: BenchmarkThermalState.nominal.rawValue,
                confidence: confidence.rating.rawValue,
                sustainedReachedTargetDuration: true
            ),
            metrics: metrics,
            score: coreScore.overallScore
        )
    }

    func submission() -> BenchmarkV7LeaderboardSubmission {
        BenchmarkV7LeaderboardSubmission(
            submissionId: submissionID.uuidString.lowercased(),
            installationId: installationID.uuidString.lowercased(),
            displayName: displayName,
            computerModel: computerModel,
            processorModel: processorModel,
            memoryGB: memoryGB,
            architecture: architecture,
            planVersion: versions.planVersion,
            workloadVersion: versions.workloadVersion,
            scoringVersion: versions.scoringVersion,
            referenceSetVersion: versions.referenceSetVersion,
            completedAt: MacBenchmarkLeaderboardDateCodec.string(from: completedAt),
            appVersion: appVersion,
            appBuild: appBuild,
            conditions: conditions,
            metrics: metrics,
            proposedScore: score
        )
    }
}

enum BenchmarkV7LeaderboardText {
    static func normalized(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> String? {
        let compatible = value.precomposedStringWithCompatibilityMapping
        let withoutControls = String(compatible.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        })
        let collapsed = withoutControls
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        var result = String(collapsed.prefix(maximumCharacters))
        while result.utf8.count > maximumBytes, !result.isEmpty {
            result.removeLast()
        }
        return result.isEmpty ? nil : result
    }

    static func isValid(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> Bool {
        normalized(
            value,
            maximumCharacters: maximumCharacters,
            maximumBytes: maximumBytes
        ) == value
    }
}

enum BenchmarkV7LeaderboardDateCodec {
    static func completedOn(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func isValidCompletedOn(_ value: String) -> Bool {
        value.utf8.count == 10
            && value.enumerated().allSatisfy { index, character in
                (index == 4 || index == 7) ? character == "-" : character.isNumber
            }
            && formatter.date(from: value).map { formatter.string(from: $0) == value } == true
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}
