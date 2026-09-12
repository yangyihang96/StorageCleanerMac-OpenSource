import Foundation

enum MacBenchmarkLeaderboardConstants {
    static let schemaVersion = 1
    /// Client and service activate this frozen Standard contract atomically.
    static let activeBaselineVersion = "m5-pro-2026-07-v6"
    static let legacyBaselineVersion = "m5-pro-2026-07-v3"
    static let minimumSourceAppVersion = "1.8.2"
    static let legacyMinimumSourceAppVersion = "1.6.0"
    static let quickWorkloadVersion = "mac-benchmark-quick-v3"
    static let fullWorkloadVersion = "mac-benchmark-full-v3"
    static let standardWorkloadVersion = "mac-benchmark-standard-v6"
    static let pageSize = 50

    static func workloadVersion(for profile: BenchmarkProfile) -> String {
        switch profile {
        case .standard: standardWorkloadVersion
        case .quick: quickWorkloadVersion
        case .full: fullWorkloadVersion
        }
    }

    static func baselineVersion(for profile: BenchmarkProfile) -> String {
        switch profile {
        case .standard: activeBaselineVersion
        case .quick, .full: legacyBaselineVersion
        }
    }

    static func minimumSourceAppVersion(for profile: BenchmarkProfile) -> String {
        switch profile {
        case .standard: minimumSourceAppVersion
        case .quick, .full: legacyMinimumSourceAppVersion
        }
    }
}

struct MacBenchmarkLeaderboardMetrics: Equatable, Codable, Sendable {
    let cpuSingle: Double
    let cpuMulti: Double
    let gpu: Double
    let memory: Double
    let diskRead: Double
    let diskWrite: Double
    let physicalMemoryBytes: UInt64?
    let systemDiskCapacityBytes: UInt64?
    /// Per-run repeatability evidence. Older v3/v4 clients may omit this
    /// optional object; v6 requires every component when the public protocol
    /// is activated after calibration.
    let stability: MacBenchmarkLeaderboardStability?

    init(
        measurements: [BenchmarkComponent: BenchmarkComponentMeasurement],
        environment: BenchmarkEnvironmentMetadata
    ) throws {
        func value(_ component: BenchmarkComponent) throws -> Double {
            guard let value = measurements[component]?.medianValue,
                  value.isFinite,
                  value > 0 else {
                throw MacBenchmarkLeaderboardEligibilityError.incompleteMetrics
            }
            return value
        }

        cpuSingle = try value(.cpuSingle)
        cpuMulti = try value(.cpuMulti)
        gpu = try value(.gpu)
        memory = try value(.memory)
        diskRead = try value(.diskRead)
        diskWrite = try value(.diskWrite)
        physicalMemoryBytes = environment.physicalMemoryBytes > 0
            ? environment.physicalMemoryBytes
            : nil
        systemDiskCapacityBytes = environment.systemDiskCapacityBytes.flatMap {
            $0 > 0 ? $0 : nil
        }
        stability = try MacBenchmarkLeaderboardStability(
            measurements: measurements
        )
    }
}

struct MacBenchmarkLeaderboardMetricStability: Equatable, Codable, Sendable {
    let coefficientOfVariation: Double
    let sampleCount: Int
}

struct MacBenchmarkLeaderboardStability: Equatable, Codable, Sendable {
    let cpuSingle: MacBenchmarkLeaderboardMetricStability
    let cpuMulti: MacBenchmarkLeaderboardMetricStability
    let gpu: MacBenchmarkLeaderboardMetricStability
    let memory: MacBenchmarkLeaderboardMetricStability
    let diskRead: MacBenchmarkLeaderboardMetricStability
    let diskWrite: MacBenchmarkLeaderboardMetricStability

    init(
        measurements: [BenchmarkComponent: BenchmarkComponentMeasurement]
    ) throws {
        func evidence(
            _ component: BenchmarkComponent
        ) throws -> MacBenchmarkLeaderboardMetricStability {
            guard let measurement = measurements[component],
                  !measurement.samples.isEmpty,
                  measurement.coefficientOfVariation.isFinite,
                  measurement.coefficientOfVariation >= 0 else {
                throw MacBenchmarkLeaderboardEligibilityError.incompleteMetrics
            }
            return MacBenchmarkLeaderboardMetricStability(
                coefficientOfVariation: measurement.coefficientOfVariation,
                sampleCount: measurement.samples.count
            )
        }

        cpuSingle = try evidence(.cpuSingle)
        cpuMulti = try evidence(.cpuMulti)
        gpu = try evidence(.gpu)
        memory = try evidence(.memory)
        diskRead = try evidence(.diskRead)
        diskWrite = try evidence(.diskWrite)
    }
}

struct MacBenchmarkLeaderboardConditions: Equatable, Codable, Sendable {
    let powerSource: String
    let lowPowerModeEnabled: Bool
    let preflightThermalState: String
    let postflightThermalState: String
}

struct MacBenchmarkLeaderboardSubmission: Equatable, Encodable, Sendable {
    let submissionId: String
    let installationId: String
    let displayName: String
    let processorModel: String
    let profile: BenchmarkProfile
    let workloadVersion: String
    let baselineVersion: String
    let architecture: String
    let completedAt: String
    let appVersion: String
    let appBuild: String
    let conditions: MacBenchmarkLeaderboardConditions
    let metrics: MacBenchmarkLeaderboardMetrics
    let proposedScore: Double
}

struct MacBenchmarkLeaderboardRemoval: Equatable, Encodable, Sendable {
    let installationId: String
    let profile: BenchmarkProfile
    let workloadVersion: String
}

struct MacBenchmarkLeaderboardRemovalReceipt: Equatable, Decodable, Sendable {
    struct DataPayload: Equatable, Decodable, Sendable {
        let deleted: Bool
    }

    let data: DataPayload
}

enum MacBenchmarkLeaderboardEligibilityError: Error, Equatable, Sendable {
    case noComparableScore
    case comparisonKeyMismatch
    case incompleteMetrics
    case incompatibleEnvironment
    case incompatibleSourceVersion
    case resultTooOld
    case invalidDisplayName
}

struct MacBenchmarkLeaderboardUploadDraft: Identifiable, Equatable, Sendable {
    let submissionID: UUID
    let installationID: UUID
    let defaultDisplayName: String
    let processorModel: String
    let score: Double
    let profile: BenchmarkProfile
    let workloadVersion: String
    let baselineVersion: String
    let completedAt: Date
    let appVersion: String
    let appBuild: String
    let conditions: MacBenchmarkLeaderboardConditions
    let metrics: MacBenchmarkLeaderboardMetrics

    var id: UUID { submissionID }

    static func make(
        result: MacBenchmarkResult,
        installationID: UUID,
        defaultDisplayName: String,
        now: Date = Date()
    ) throws -> Self {
        guard let raw = result.rawResult,
              raw.isComplete,
              let score = result.overallScore,
              score.isFinite,
              score > 0,
              let completedAt = raw.completedAt,
              let postflight = raw.postflight else {
            throw MacBenchmarkLeaderboardEligibilityError.noComparableScore
        }
        guard raw.profile == .standard,
              raw.workloadVersion
                == MacBenchmarkLeaderboardConstants.standardWorkloadVersion else {
            throw MacBenchmarkLeaderboardEligibilityError.comparisonKeyMismatch
        }
        let expectedWorkload = MacBenchmarkLeaderboardConstants.workloadVersion(
            for: raw.profile
        )
        guard raw.workloadVersion == expectedWorkload,
              let key = result.comparisonKey,
              key == result.matchedBaselineKey,
              key.workloadVersion == expectedWorkload,
              key.profile == raw.profile,
              key.baselineVersion
                == MacBenchmarkLeaderboardConstants.baselineVersion(for: raw.profile),
              key.architecture == .arm64,
              key.capabilitySet == .all else {
            throw MacBenchmarkLeaderboardEligibilityError.comparisonKeyMismatch
        }
        guard MacBenchmarkScoring.hasComparableEnvironment(raw) else {
            throw MacBenchmarkLeaderboardEligibilityError.incompatibleEnvironment
        }
        guard Self.isAtLeastVersion(
            raw.environment.appVersion,
            minimum: MacBenchmarkLeaderboardConstants.minimumSourceAppVersion(
                for: raw.profile
            )
        ), (8...20).contains(raw.environment.appBuild.count),
           raw.environment.appBuild.allSatisfy(\.isNumber) else {
            throw MacBenchmarkLeaderboardEligibilityError.incompatibleSourceVersion
        }
        let minimumCompletionDate = now.addingTimeInterval(-30 * 24 * 60 * 60)
        guard completedAt >= minimumCompletionDate,
              completedAt <= now.addingTimeInterval(5 * 60) else {
            throw MacBenchmarkLeaderboardEligibilityError.resultTooOld
        }
        let normalizedName = MacBenchmarkLeaderboardText.normalized(defaultDisplayName)
        guard MacBenchmarkLeaderboardText.isValid(normalizedName) else {
            throw MacBenchmarkLeaderboardEligibilityError.invalidDisplayName
        }
        let processorModel = MacBenchmarkLeaderboardText.normalizedProcessorModel(
            raw.environment.chipName
        )
        let metrics = try MacBenchmarkLeaderboardMetrics(
            measurements: raw.measurementsByComponent,
            environment: raw.environment
        )

        return Self(
            submissionID: UUID(),
            installationID: installationID,
            defaultDisplayName: normalizedName,
            processorModel: processorModel,
            score: score,
            profile: raw.profile,
            workloadVersion: raw.workloadVersion,
            baselineVersion: key.baselineVersion,
            completedAt: completedAt,
            appVersion: raw.environment.appVersion,
            appBuild: raw.environment.appBuild,
            conditions: MacBenchmarkLeaderboardConditions(
                powerSource: raw.preflight.powerSource.rawValue,
                lowPowerModeEnabled: raw.preflight.lowPowerModeEnabled
                    || postflight.lowPowerModeEnabled,
                preflightThermalState: raw.preflight.thermalState.rawValue,
                postflightThermalState: postflight.thermalState.rawValue
            ),
            metrics: metrics
        )
    }

    func submission(displayName: String) throws -> MacBenchmarkLeaderboardSubmission {
        let normalizedName = MacBenchmarkLeaderboardText.normalized(displayName)
        guard MacBenchmarkLeaderboardText.isValid(normalizedName) else {
            throw MacBenchmarkLeaderboardEligibilityError.invalidDisplayName
        }
        return MacBenchmarkLeaderboardSubmission(
            submissionId: submissionID.uuidString.lowercased(),
            installationId: installationID.uuidString.lowercased(),
            displayName: normalizedName,
            processorModel: processorModel,
            profile: profile,
            workloadVersion: workloadVersion,
            baselineVersion: baselineVersion,
            architecture: BenchmarkArchitecture.arm64.rawValue,
            completedAt: MacBenchmarkLeaderboardDateCodec.string(from: completedAt),
            appVersion: appVersion,
            appBuild: appBuild,
            conditions: conditions,
            metrics: metrics,
            proposedScore: score
        )
    }

    private static func isAtLeastVersion(_ version: String, minimum: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            let core = value.split(whereSeparator: { $0 == "-" || $0 == "+" }).first
            guard let core else { return nil }
            let values = core.split(separator: ".").map(String.init).compactMap(Int.init)
            return values.count == 3 ? values : nil
        }
        guard let current = components(version),
              let required = components(minimum) else { return false }
        return current.lexicographicallyPrecedes(required) == false
    }
}

struct MacBenchmarkLeaderboardEntry: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let rank: Int
    let displayName: String
    let processorModel: String
    let score: Double
    let profile: BenchmarkProfile
    let workloadVersion: String
    let physicalMemoryBytes: UInt64?
    let systemDiskCapacityBytes: UInt64?
    let completedAt: Date

    init(
        id: String,
        rank: Int,
        displayName: String,
        processorModel: String,
        score: Double,
        profile: BenchmarkProfile,
        workloadVersion: String,
        physicalMemoryBytes: UInt64? = nil,
        systemDiskCapacityBytes: UInt64? = nil,
        completedAt: Date
    ) {
        self.id = id
        self.rank = rank
        self.displayName = displayName
        self.processorModel = processorModel
        self.score = score
        self.profile = profile
        self.workloadVersion = workloadVersion
        self.physicalMemoryBytes = physicalMemoryBytes
        self.systemDiskCapacityBytes = systemDiskCapacityBytes
        self.completedAt = completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        rank = try container.decode(Int.self, forKey: .rank)
        displayName = try container.decode(String.self, forKey: .displayName)
        processorModel = try container.decode(String.self, forKey: .processorModel)
        score = try container.decode(Double.self, forKey: .score)
        profile = try container.decode(BenchmarkProfile.self, forKey: .profile)
        workloadVersion = try container.decode(String.self, forKey: .workloadVersion)
        physicalMemoryBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .physicalMemoryBytes
        )
        systemDiskCapacityBytes = try container.decodeIfPresent(
            UInt64.self,
            forKey: .systemDiskCapacityBytes
        )
        let dateString = try container.decode(String.self, forKey: .completedAt)
        guard let date = MacBenchmarkLeaderboardDateCodec.date(from: dateString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .completedAt,
                in: container,
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        completedAt = date
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case rank
        case displayName
        case processorModel
        case score
        case profile
        case workloadVersion
        case physicalMemoryBytes
        case systemDiskCapacityBytes
        case completedAt
    }
}

struct MacBenchmarkLeaderboardPagination: Equatable, Decodable, Sendable {
    let page: Int
    let pageSize: Int
    let total: Int
    let totalPages: Int
}

struct MacBenchmarkLeaderboardMetadata: Equatable, Decodable, Sendable {
    let baselineVersion: String
    let profile: BenchmarkProfile
    let workloadVersion: String
    let generatedAt: Date

    init(
        baselineVersion: String,
        profile: BenchmarkProfile,
        workloadVersion: String,
        generatedAt: Date
    ) {
        self.baselineVersion = baselineVersion
        self.profile = profile
        self.workloadVersion = workloadVersion
        self.generatedAt = generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baselineVersion = try container.decode(String.self, forKey: .baselineVersion)
        profile = try container.decode(BenchmarkProfile.self, forKey: .profile)
        workloadVersion = try container.decode(String.self, forKey: .workloadVersion)
        let dateString = try container.decode(String.self, forKey: .generatedAt)
        guard let date = MacBenchmarkLeaderboardDateCodec.date(from: dateString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .generatedAt,
                in: container,
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        generatedAt = date
    }

    private enum CodingKeys: String, CodingKey {
        case baselineVersion
        case profile
        case workloadVersion
        case generatedAt
    }
}

struct MacBenchmarkLeaderboardPage: Equatable, Decodable, Sendable {
    let data: [MacBenchmarkLeaderboardEntry]
    let pagination: MacBenchmarkLeaderboardPagination
    let meta: MacBenchmarkLeaderboardMetadata
}

struct MacBenchmarkLeaderboardSubmissionReceipt: Equatable, Decodable, Sendable {
    let data: MacBenchmarkLeaderboardEntry
    let disposition: String
}

enum MacBenchmarkLeaderboardText {
    static let maximumDisplayNameCharacters = 40
    static let maximumDisplayNameBytes = 120
    static let maximumProcessorCharacters = 80
    static let maximumProcessorBytes = 240

    static func normalized(_ value: String) -> String {
        normalizedPublicText(
            value,
            maximumCharacters: maximumDisplayNameCharacters,
            maximumBytes: maximumDisplayNameBytes,
            fallback: ""
        )
    }

    static func normalizedProcessorModel(_ value: String) -> String {
        normalizedPublicText(
            value,
            maximumCharacters: maximumProcessorCharacters,
            maximumBytes: maximumProcessorBytes,
            fallback: "Mac"
        )
    }

    static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumDisplayNameCharacters
            && value.utf8.count <= maximumDisplayNameBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func normalizedPublicText(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int,
        fallback: String
    ) -> String {
        let compatibilityNormalized = value.precomposedStringWithCompatibilityMapping
        let withoutControls = String(compatibilityNormalized.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        })
        let collapsed = withoutControls
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        var normalized = String(collapsed.prefix(maximumCharacters))
        while normalized.utf8.count > maximumBytes, !normalized.isEmpty {
            normalized.removeLast()
        }
        return normalized.isEmpty ? fallback : normalized
    }
}

enum MacBenchmarkLeaderboardDateCodec {
    static func string(from date: Date) -> String {
        AppISO8601DateCodec.string(from: date)
    }

    static func date(from value: String) -> Date? {
        AppISO8601DateCodec.date(from: value)
    }
}
