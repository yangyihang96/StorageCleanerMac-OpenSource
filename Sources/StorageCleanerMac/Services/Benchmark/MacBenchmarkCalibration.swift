import Foundation

enum MacBenchmarkCalibrationError: Error, Equatable, Sendable {
    case invalidBaselineVersion
    case invalidFrozenDate
    case invalidSessionLabel
    case debugBuildNotAllowed
    case referenceHardwareMismatch
    case invalidRawResult
    case workloadVersionMismatch
    case excessiveWithinRunVariation(BenchmarkComponent)
    case insufficientValidRuns(profile: BenchmarkProfile, actual: Int)
    case insufficientIndependentSessions(profile: BenchmarkProfile, actual: Int)
    case insufficientRunsPerSession(
        profile: BenchmarkProfile,
        sessionLabel: String,
        actual: Int
    )
    case excessiveAggregateVariation(
        profile: BenchmarkProfile,
        component: BenchmarkComponent
    )
    case invalidSessionTimeline
    case insufficientCoolingInterval
    case inconsistentSourceBuild
    case duplicateSourceRun
    case nonCanonicalSourceRun
    case invalidCalibrationDocument
    case calibrationDocumentHashMismatch
    case duplicateProfile
    case incompleteProfileSet
}

struct MacBenchmarkCalibrationHardware: Equatable, Codable, Sendable {
    let modelIdentifier: String
    let chipName: String
    let activeProcessorCount: Int
    let physicalMemoryBytes: UInt64
    let architecture: BenchmarkArchitecture

    static let m5ProReference = Self(
        modelIdentifier: "Mac17,9",
        chipName: "Apple M5 Pro",
        activeProcessorCount: 18,
        physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024,
        architecture: .arm64
    )

    var referenceDescription: String {
        "MacBook Pro \(modelIdentifier) · \(chipName) · "
            + "\(activeProcessorCount) cores · 48 GB"
    }

    func matches(_ rawResult: MacBenchmarkRawResult) -> Bool {
        let environment = rawResult.environment
        return modelIdentifier == Self.m5ProReference.modelIdentifier
            && chipName == Self.m5ProReference.chipName
            && activeProcessorCount == Self.m5ProReference.activeProcessorCount
            && physicalMemoryBytes == Self.m5ProReference.physicalMemoryBytes
            && architecture == Self.m5ProReference.architecture
            && environment.chipName.trimmingCharacters(in: .whitespacesAndNewlines)
                == chipName
            && environment.activeProcessorCount == activeProcessorCount
            && environment.physicalMemoryBytes == physicalMemoryBytes
            && environment.architecture == architecture
    }
}

enum MacBenchmarkCalibrationBuildConfiguration: String, Codable, Sendable {
    case release
}

struct MacBenchmarkCalibrationRunRecord: Equatable, Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessionLabel: String
    let buildConfiguration: MacBenchmarkCalibrationBuildConfiguration
    let hardware: MacBenchmarkCalibrationHardware
    let rawResult: MacBenchmarkRawResult

    init(
        sessionLabel: String,
        hardware: MacBenchmarkCalibrationHardware,
        rawResult: MacBenchmarkRawResult
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.sessionLabel = sessionLabel
        buildConfiguration = .release
        self.hardware = hardware
        self.rawResult = rawResult
    }
}

struct MacBenchmarkCalibrationRunSummary: Equatable, Codable, Sendable {
    let sourceRunSHA256: String
    let sessionLabel: String
    let startedAt: Date
    let completedAt: Date
    let profile: BenchmarkProfile
    let workloadVersion: String
    let sourceBuild: MacBenchmarkCalibrationSourceBuild
    let componentMedians: MacBenchmarkComponentValues
    let componentCoefficientsOfVariation: MacBenchmarkComponentValues
}

struct MacBenchmarkCalibrationSourceBuild: Equatable, Hashable, Codable, Sendable {
    let appVersion: String
    let appBuild: String

    var isValid: Bool {
        let versionParts = appVersion.split(separator: ".", omittingEmptySubsequences: false)
        let buildBytes = appBuild.utf8
        return versionParts.count == 3
            && versionParts.allSatisfy { part in
                !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
            }
            && !buildBytes.isEmpty
            && buildBytes.allSatisfy { (48...57).contains($0) }
    }
}

struct MacBenchmarkCalibrationDocument: Equatable, Codable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let baselineReport: MacBenchmarkCalibrationReport
    let baselineReportBase64: String
    let baselineReportSHA256: String
    let hardware: MacBenchmarkCalibrationHardware
    let harnessIdentifier: String
    let sourceBuild: MacBenchmarkCalibrationSourceBuild
    let validRunCount: Int
    let independentSessionCount: Int
    let maximumAllowedCoefficientOfVariation: Double
    let maximumAllowedGPUAggregateCoefficientOfVariation: Double
    let maximumAllowedDurableWriteAggregateCoefficientOfVariation: Double
    let aggregateCoefficientsOfVariation: MacBenchmarkComponentValues
    let runs: [MacBenchmarkCalibrationRunSummary]
}

struct MacBenchmarkCalibrationArtifact: Equatable, Sendable {
    let profile: BenchmarkProfile
    let document: MacBenchmarkCalibrationDocument
    let documentData: Data
    let documentSHA256: String
    let verifiedBaseline: VerifiedMacBenchmarkBaseline
}

struct FrozenMacBenchmarkCalibrationDocument: Equatable, Sendable {
    let profile: BenchmarkProfile
    let documentBase64: String
    let documentSHA256: String
}

enum MacBenchmarkCalibrationCoding {
    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

struct MacBenchmarkCalibrationAggregator: Sendable {
    static let minimumValidRunsPerProfile = 8
    static let minimumIndependentSessionsPerProfile = 2
    static let minimumValidRunsPerProfilePerSession = 4
    static let maximumCoefficientOfVariation = 0.05
    static let maximumGPUAggregateCoefficientOfVariation = 0.10
    static let maximumDurableWriteAggregateCoefficientOfVariation = 0.10
    static let minimumCoolingInterval: TimeInterval = 10 * 60
    static let semanticTolerance = 1e-12
    static let harnessIdentifier = "swiftpm-release-xctest.v1"

    let expectedHardware: MacBenchmarkCalibrationHardware
    let profiles: [BenchmarkProfile]

    init(
        expectedHardware: MacBenchmarkCalibrationHardware = .m5ProReference,
        profiles: [BenchmarkProfile] = []
    ) {
        self.expectedHardware = expectedHardware
        self.profiles = profiles
    }

    func makeArtifacts(
        records: [MacBenchmarkCalibrationRunRecord],
        baselineVersion: String,
        frozenAt: Date
    ) throws -> [MacBenchmarkCalibrationArtifact] {
        let normalizedVersion = baselineVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedVersion.isEmpty else {
            throw MacBenchmarkCalibrationError.invalidBaselineVersion
        }
        guard frozenAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MacBenchmarkCalibrationError.invalidFrozenDate
        }

        let activeProfiles = profiles.isEmpty
            ? BenchmarkProfile.persistedCases.filter { profile in
                records.contains { $0.rawResult.profile == profile }
            }
            : profiles
        guard !activeProfiles.isEmpty,
              Set(activeProfiles).count == activeProfiles.count,
              records.allSatisfy({ activeProfiles.contains($0.rawResult.profile) })
        else {
            throw MacBenchmarkCalibrationError.incompleteProfileSet
        }
        let validated = try records.map(validate)
        guard validated.allSatisfy({ run in
            frozenAt >= run.summary.completedAt
        }) else {
            throw MacBenchmarkCalibrationError.invalidFrozenDate
        }
        let sourceBuilds = Set(validated.map(\.summary.sourceBuild))
        guard sourceBuilds.count == 1, let sourceBuild = sourceBuilds.first else {
            throw MacBenchmarkCalibrationError.inconsistentSourceBuild
        }
        try Self.validateSessionTimeline(validated.map(\.summary))

        let profileSessionSets = activeProfiles.map { profile in
            Set(validated.lazy.filter { $0.summary.profile == profile }
                .map { $0.summary.sessionLabel })
        }
        guard let firstSessionSet = profileSessionSets.first,
              profileSessionSets.allSatisfy({ $0 == firstSessionSet })
        else {
            throw MacBenchmarkCalibrationError.invalidSessionTimeline
        }
        let hashes = validated.map(\.summary.sourceRunSHA256)
        guard Set(hashes).count == hashes.count else {
            throw MacBenchmarkCalibrationError.duplicateSourceRun
        }

        return try activeProfiles.map { profile in
            try makeArtifact(
                profile: profile,
                validatedRuns: validated.filter { $0.record.rawResult.profile == profile },
                baselineVersion: normalizedVersion,
                frozenAt: frozenAt,
                sourceBuild: sourceBuild
            )
        }
    }

    func validateCanonicalRecordData(_ data: Data) throws
        -> MacBenchmarkCalibrationRunRecord
    {
        let record: MacBenchmarkCalibrationRunRecord
        do {
            record = try MacBenchmarkCalibrationCoding.decode(
                MacBenchmarkCalibrationRunRecord.self,
                from: data
            )
        } catch {
            throw MacBenchmarkCalibrationError.nonCanonicalSourceRun
        }
        guard try MacBenchmarkCalibrationCoding.canonicalData(record) == data else {
            throw MacBenchmarkCalibrationError.nonCanonicalSourceRun
        }
        _ = try validate(record)
        return record
    }
}

private extension MacBenchmarkCalibrationAggregator {
    struct ValidatedRun: Sendable {
        let record: MacBenchmarkCalibrationRunRecord
        let summary: MacBenchmarkCalibrationRunSummary
    }

    func validate(_ record: MacBenchmarkCalibrationRunRecord) throws -> ValidatedRun {
        guard record.schemaVersion == MacBenchmarkCalibrationRunRecord.currentSchemaVersion,
              Self.isSafeSessionLabel(record.sessionLabel)
        else {
            throw MacBenchmarkCalibrationError.invalidSessionLabel
        }
        guard record.hardware == expectedHardware,
              record.hardware.matches(record.rawResult)
        else {
            throw MacBenchmarkCalibrationError.referenceHardwareMismatch
        }

        let rawResult = record.rawResult
        let sourceBuild = MacBenchmarkCalibrationSourceBuild(
            appVersion: rawResult.environment.appVersion,
            appBuild: rawResult.environment.appBuild
        )
        guard rawResult.isComplete,
              MacBenchmarkScoring.hasComparableEnvironment(rawResult),
              rawResult.measurements.map(\.component) == BenchmarkComponent.allCases,
              let completedAt = rawResult.completedAt,
              sourceBuild.isValid
        else {
            throw MacBenchmarkCalibrationError.invalidRawResult
        }
        if MacBenchmarkScoring.usesCapacityAwareScoring(
            workloadVersion: rawResult.workloadVersion
        ) {
            guard rawResult.environment.physicalMemoryBytes
                    == MacBenchmarkScoring.referencePhysicalMemoryBytes,
                  rawResult.environment.systemDiskCapacityBytes
                    == MacBenchmarkScoring.referenceSystemDiskCapacityBytes else {
                throw MacBenchmarkCalibrationError.referenceHardwareMismatch
            }
        }
        guard rawResult.workloadVersion == Self.expectedWorkloadVersion(
            for: rawResult.profile
        ) else {
            throw MacBenchmarkCalibrationError.workloadVersionMismatch
        }

        let measurements = rawResult.measurementsByComponent
        var medians: [BenchmarkComponent: Double] = [:]
        var coefficients: [BenchmarkComponent: Double] = [:]
        for component in BenchmarkComponent.allCases {
            guard let measurement = measurements[component], measurement.isValid else {
                throw MacBenchmarkCalibrationError.invalidRawResult
            }
            let coefficient = measurement.calibrationStabilityCoefficientOfVariation
            guard coefficient <= Self.maximumCoefficientOfVariation else {
                throw MacBenchmarkCalibrationError.excessiveWithinRunVariation(component)
            }
            medians[component] = measurement.medianValue
            coefficients[component] = coefficient
        }

        let canonicalData = try MacBenchmarkCalibrationCoding.canonicalData(record)
        return ValidatedRun(
            record: record,
            summary: MacBenchmarkCalibrationRunSummary(
                sourceRunSHA256: MacBenchmarkBaselineVerification.sha256Hex(canonicalData),
                sessionLabel: record.sessionLabel,
                startedAt: rawResult.startedAt,
                completedAt: completedAt,
                profile: rawResult.profile,
                workloadVersion: rawResult.workloadVersion,
                sourceBuild: sourceBuild,
                componentMedians: MacBenchmarkComponentValues(medians),
                componentCoefficientsOfVariation: MacBenchmarkComponentValues(coefficients)
            )
        )
    }

    func makeArtifact(
        profile: BenchmarkProfile,
        validatedRuns: [ValidatedRun],
        baselineVersion: String,
        frozenAt: Date,
        sourceBuild: MacBenchmarkCalibrationSourceBuild
    ) throws -> MacBenchmarkCalibrationArtifact {
        guard validatedRuns.count >= Self.minimumValidRunsPerProfile else {
            throw MacBenchmarkCalibrationError.insufficientValidRuns(
                profile: profile,
                actual: validatedRuns.count
            )
        }
        let sessions = Set(validatedRuns.map { $0.record.sessionLabel })
        guard sessions.count >= Self.minimumIndependentSessionsPerProfile else {
            throw MacBenchmarkCalibrationError.insufficientIndependentSessions(
                profile: profile,
                actual: sessions.count
            )
        }
        try Self.validateSessionCoverage(
            validatedRuns.map(\.summary),
            profile: profile
        )

        // The document and the loader both use this digest order. Keeping all
        // floating-point reductions in that one order makes exact frozen-data
        // verification deterministic across collection and runtime loading.
        let sortedRuns = validatedRuns.sorted {
            $0.summary.sourceRunSHA256 < $1.summary.sourceRunSHA256
        }

        var referenceMetrics: [BenchmarkComponent: Double] = [:]
        var aggregateCoefficients: [BenchmarkComponent: Double] = [:]
        for component in BenchmarkComponent.allCases {
            let values = sortedRuns.compactMap {
                $0.summary.componentMedians[component]
            }
            guard values.count == sortedRuns.count,
                  let reference = Self.median(values),
                  let coefficient = Self.coefficientOfVariation(values)
            else {
                throw MacBenchmarkCalibrationError.invalidRawResult
            }
            guard coefficient <= Self.maximumAggregateCoefficientOfVariation(
                for: component
            ) else {
                throw MacBenchmarkCalibrationError.excessiveAggregateVariation(
                    profile: profile,
                    component: component
                )
            }
            referenceMetrics[component] = reference
            aggregateCoefficients[component] = coefficient
        }

        let sortedSummaries = sortedRuns.map(\.summary)
        let key = BenchmarkComparisonKey(
            workloadVersion: Self.expectedWorkloadVersion(for: profile),
            baselineVersion: baselineVersion,
            profile: profile,
            architecture: .arm64,
            capabilitySet: .all
        )
        let baselineReport = MacBenchmarkCalibrationReport(
            schemaVersion: MacBenchmarkCalibrationReport.currentSchemaVersion,
            key: key,
            referenceMetrics: referenceMetrics,
            referenceHardware: expectedHardware.referenceDescription,
            frozenAt: frozenAt,
            sourceRunSHA256s: sortedSummaries.map(\.sourceRunSHA256)
        )
        let baselineReportData = try MacBenchmarkCalibrationCoding.canonicalData(
            baselineReport
        )
        let baselineReportSHA256 = MacBenchmarkBaselineVerification.sha256Hex(
            baselineReportData
        )
        let baseline = MacBenchmarkBaseline(
            comparisonKey: key,
            referenceMetrics: referenceMetrics,
            reportSHA256: baselineReportSHA256,
            referenceHardware: expectedHardware.referenceDescription,
            frozenAt: frozenAt
        )
        let verifiedBaseline = try VerifiedMacBenchmarkBaseline(
            baseline: baseline,
            calibrationReport: baselineReportData
        )
        let document = MacBenchmarkCalibrationDocument(
            schemaVersion: MacBenchmarkCalibrationDocument.currentSchemaVersion,
            baselineReport: baselineReport,
            baselineReportBase64: baselineReportData.base64EncodedString(),
            baselineReportSHA256: baselineReportSHA256,
            hardware: expectedHardware,
            harnessIdentifier: Self.harnessIdentifier,
            sourceBuild: sourceBuild,
            validRunCount: sortedSummaries.count,
            independentSessionCount: sessions.count,
            maximumAllowedCoefficientOfVariation: Self.maximumCoefficientOfVariation,
            maximumAllowedGPUAggregateCoefficientOfVariation:
                Self.maximumGPUAggregateCoefficientOfVariation,
            maximumAllowedDurableWriteAggregateCoefficientOfVariation:
                Self.maximumDurableWriteAggregateCoefficientOfVariation,
            aggregateCoefficientsOfVariation: MacBenchmarkComponentValues(
                aggregateCoefficients
            ),
            runs: sortedSummaries
        )
        let documentData = try MacBenchmarkCalibrationCoding.canonicalData(document)
        return MacBenchmarkCalibrationArtifact(
            profile: profile,
            document: document,
            documentData: documentData,
            documentSHA256: MacBenchmarkBaselineVerification.sha256Hex(documentData),
            verifiedBaseline: verifiedBaseline
        )
    }

    static func expectedWorkloadVersion(for profile: BenchmarkProfile) -> String {
        MacBenchmarkService.workloadVersion(for: profile)
    }

    static func maximumAggregateCoefficientOfVariation(
        for component: BenchmarkComponent
    ) -> Double {
        switch component {
        case .gpu:
            maximumGPUAggregateCoefficientOfVariation
        case .diskWrite:
            maximumDurableWriteAggregateCoefficientOfVariation
        default:
            maximumCoefficientOfVariation
        }
    }

    static func isSafeSessionLabel(_ value: String) -> Bool {
        guard value.hasPrefix("session-") else { return false }
        let suffix = value.dropFirst("session-".count)
        let bytes = suffix.utf8
        return !bytes.isEmpty
            && bytes.first != 48
            && bytes.allSatisfy { (48...57).contains($0) }
    }

    static func validateSessionTimeline(
        _ summaries: [MacBenchmarkCalibrationRunSummary]
    ) throws {
        let grouped = Dictionary(grouping: summaries, by: \.sessionLabel)
        let sessions = try grouped.map { label, runs -> (
            index: Int,
            startedAt: Date,
            completedAt: Date
        ) in
            guard isSafeSessionLabel(label),
                  let index = Int(label.dropFirst("session-".count)),
                  let first = runs.min(by: { $0.startedAt < $1.startedAt }),
                  let last = runs.max(by: { $0.completedAt < $1.completedAt })
            else {
                throw MacBenchmarkCalibrationError.invalidSessionTimeline
            }
            let ordered = runs.sorted { $0.startedAt < $1.startedAt }
            for pair in zip(ordered, ordered.dropFirst()) {
                guard pair.1.startedAt >= pair.0.completedAt else {
                    throw MacBenchmarkCalibrationError.invalidSessionTimeline
                }
            }
            return (index, first.startedAt, last.completedAt)
        }.sorted { $0.index < $1.index }

        guard sessions.map(\.index) == Array(1...sessions.count) else {
            throw MacBenchmarkCalibrationError.invalidSessionTimeline
        }
        for pair in zip(sessions, sessions.dropFirst()) {
            guard pair.1.startedAt.timeIntervalSince(pair.0.completedAt)
                    >= minimumCoolingInterval
            else {
                throw MacBenchmarkCalibrationError.insufficientCoolingInterval
            }
        }
    }

    static func validateSessionCoverage(
        _ summaries: [MacBenchmarkCalibrationRunSummary],
        profile: BenchmarkProfile
    ) throws {
        guard summaries.allSatisfy({ $0.profile == profile }) else {
            throw MacBenchmarkCalibrationError.invalidSessionTimeline
        }
        let grouped = Dictionary(grouping: summaries, by: \.sessionLabel)
        for label in grouped.keys.sorted() {
            let count = grouped[label]?.count ?? 0
            guard count >= minimumValidRunsPerProfilePerSession else {
                throw MacBenchmarkCalibrationError.insufficientRunsPerSession(
                    profile: profile,
                    sessionLabel: label,
                    actual: count
                )
            }
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        if values.count == 1 { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean.isFinite, mean > 0 else { return nil }
        let squaredError = values.reduce(0) { result, value in
            let difference = value - mean
            return result + difference * difference
        }
        let variance = squaredError / Double(values.count - 1)
        let coefficient = sqrt(variance) / mean
        return coefficient.isFinite ? coefficient : nil
    }

    static func areSemanticallyEqual(
        _ lhs: [BenchmarkComponent: Double],
        _ rhs: [BenchmarkComponent: Double]
    ) -> Bool {
        guard lhs.count == BenchmarkComponent.allCases.count,
              rhs.count == BenchmarkComponent.allCases.count
        else { return false }
        return BenchmarkComponent.allCases.allSatisfy { component in
            guard let left = lhs[component], let right = rhs[component],
                  left.isFinite, right.isFinite
            else { return false }
            let scale = max(1, max(abs(left), abs(right)))
            return abs(left - right) <= semanticTolerance * scale
        }
    }
}

enum MacBenchmarkFrozenCatalogLoader {
    static func verifiedBaselines(
        from frozenDocuments: [FrozenMacBenchmarkCalibrationDocument],
        activeBaselineVersion: String,
        expectedHardware: MacBenchmarkCalibrationHardware = .m5ProReference,
        requireCompleteProfileSet: Bool,
        requireCanonicalEncoding: Bool = false,
        expectedSourceBuild: MacBenchmarkCalibrationSourceBuild? = nil,
        requiredProfiles: [BenchmarkProfile] = BenchmarkProfile.allCases,
        expectedWorkloadVersions: [BenchmarkProfile: String]? = nil
    ) throws -> [VerifiedMacBenchmarkBaseline] {
        if frozenDocuments.isEmpty {
            if requireCompleteProfileSet {
                throw MacBenchmarkCalibrationError.incompleteProfileSet
            }
            return []
        }
        guard Set(frozenDocuments.map(\.profile)).count == frozenDocuments.count else {
            throw MacBenchmarkCalibrationError.duplicateProfile
        }
        if requireCompleteProfileSet,
           Set(frozenDocuments.map(\.profile)) != Set(requiredProfiles)
        {
            throw MacBenchmarkCalibrationError.incompleteProfileSet
        }

        return try frozenDocuments.map { frozen in
            guard let data = Data(base64Encoded: frozen.documentBase64),
                  MacBenchmarkBaselineVerification.sha256Hex(data)
                    .caseInsensitiveCompare(frozen.documentSHA256) == .orderedSame
            else {
                throw MacBenchmarkCalibrationError.calibrationDocumentHashMismatch
            }
            let document: MacBenchmarkCalibrationDocument
            do {
                document = try MacBenchmarkCalibrationCoding.decode(
                    MacBenchmarkCalibrationDocument.self,
                    from: data
                )
            } catch {
                throw MacBenchmarkCalibrationError.invalidCalibrationDocument
            }
            if requireCanonicalEncoding {
                guard try MacBenchmarkCalibrationCoding.canonicalData(document) == data else {
                    throw MacBenchmarkCalibrationError.invalidCalibrationDocument
                }
            }
            guard let reportData = Data(
                base64Encoded: document.baselineReportBase64
            ) else {
                throw MacBenchmarkCalibrationError.invalidCalibrationDocument
            }
            let reportHash = MacBenchmarkBaselineVerification.sha256Hex(reportData)
            guard reportHash.caseInsensitiveCompare(document.baselineReportSHA256)
                    == .orderedSame,
                  let report = try? MacBenchmarkCalibrationCoding.decode(
                    MacBenchmarkCalibrationReport.self,
                    from: reportData
                  ),
                  Self.reportsSemanticallyEqual(report, document.baselineReport)
            else {
                throw MacBenchmarkCalibrationError.calibrationDocumentHashMismatch
            }
            if requireCanonicalEncoding {
                guard try MacBenchmarkCalibrationCoding.canonicalData(report)
                        == reportData
                else {
                    throw MacBenchmarkCalibrationError.invalidCalibrationDocument
                }
            }
            let expectedWorkloadVersion: String
            if let expectedWorkloadVersions {
                guard let archivedWorkloadVersion = expectedWorkloadVersions[frozen.profile]
                else {
                    throw MacBenchmarkCalibrationError.invalidCalibrationDocument
                }
                expectedWorkloadVersion = archivedWorkloadVersion
            } else {
                expectedWorkloadVersion = MacBenchmarkCalibrationAggregator
                    .expectedWorkloadVersion(for: frozen.profile)
            }
            guard document.schemaVersion == MacBenchmarkCalibrationDocument.currentSchemaVersion,
                  document.hardware == expectedHardware,
                  document.harnessIdentifier
                    == MacBenchmarkCalibrationAggregator.harnessIdentifier,
                  document.sourceBuild.isValid,
                  expectedSourceBuild.map({ $0 == document.sourceBuild }) ?? true,
                  report.key.profile == frozen.profile,
                  report.key.baselineVersion == activeBaselineVersion,
                  report.key.workloadVersion == expectedWorkloadVersion,
                  report.key.architecture == .arm64,
                  report.key.capabilitySet == .all,
                  report.referenceHardware
                    == expectedHardware.referenceDescription,
                  document.validRunCount >= MacBenchmarkCalibrationAggregator
                    .minimumValidRunsPerProfile,
                  document.runs.count == document.validRunCount,
                  document.independentSessionCount
                    >= MacBenchmarkCalibrationAggregator.minimumIndependentSessionsPerProfile,
                  Set(document.runs.map(\.sessionLabel)).count
                    == document.independentSessionCount,
                  document.maximumAllowedCoefficientOfVariation.isFinite,
                  abs(
                    document.maximumAllowedCoefficientOfVariation
                        - MacBenchmarkCalibrationAggregator
                            .maximumCoefficientOfVariation
                  ) <= MacBenchmarkCalibrationAggregator.semanticTolerance,
                  document.maximumAllowedGPUAggregateCoefficientOfVariation.isFinite,
                  abs(
                    document.maximumAllowedGPUAggregateCoefficientOfVariation
                        - MacBenchmarkCalibrationAggregator
                            .maximumGPUAggregateCoefficientOfVariation
                  ) <= MacBenchmarkCalibrationAggregator.semanticTolerance,
                  document.maximumAllowedDurableWriteAggregateCoefficientOfVariation
                    .isFinite,
                  abs(
                    document.maximumAllowedDurableWriteAggregateCoefficientOfVariation
                        - MacBenchmarkCalibrationAggregator
                            .maximumDurableWriteAggregateCoefficientOfVariation
                  ) <= MacBenchmarkCalibrationAggregator.semanticTolerance
            else {
                throw MacBenchmarkCalibrationError.invalidCalibrationDocument
            }

            guard document.runs.allSatisfy({ summary in
                summary.profile == frozen.profile
                    && summary.workloadVersion
                        == report.key.workloadVersion
                    && summary.sourceBuild == document.sourceBuild
                    && MacBenchmarkCalibrationAggregator.isSafeSessionLabel(
                        summary.sessionLabel
                    )
                    && summary.startedAt.timeIntervalSinceReferenceDate.isFinite
                    && summary.completedAt.timeIntervalSinceReferenceDate.isFinite
                    && summary.startedAt <= summary.completedAt
                    && summary.completedAt <= report.frozenAt
                    && summary.componentMedians.count
                        == BenchmarkComponent.allCases.count
                    && summary.componentCoefficientsOfVariation.count
                        == BenchmarkComponent.allCases.count
                    && BenchmarkComponent.allCases.allSatisfy { component in
                        guard let median = summary.componentMedians[component],
                              let coefficient = summary
                                .componentCoefficientsOfVariation[component]
                        else { return false }
                        return median.isFinite
                            && median > 0
                            && coefficient.isFinite
                            && coefficient >= 0
                            && coefficient <= MacBenchmarkCalibrationAggregator
                                .maximumCoefficientOfVariation
                    }
            }) else {
                throw MacBenchmarkCalibrationError.invalidCalibrationDocument
            }
            do {
                try MacBenchmarkCalibrationAggregator.validateSessionCoverage(
                    document.runs,
                    profile: frozen.profile
                )
            } catch {
                throw MacBenchmarkCalibrationError.invalidCalibrationDocument
            }
            try MacBenchmarkCalibrationAggregator.validateSessionTimeline(
                document.runs
            )

            let sourceHashes = document.runs.map(\.sourceRunSHA256)
            guard sourceHashes == report.sourceRunSHA256s,
                  sourceHashes == sourceHashes.sorted(),
                  Set(sourceHashes).count == sourceHashes.count,
                  sourceHashes.allSatisfy(MacBenchmarkBaselineVerification.isSHA256Hex),
                  MacBenchmarkCalibrationAggregator.areSemanticallyEqual(
                    try Self.recomputedReferences(in: document),
                    report.referenceMetrics
                  ),
                  MacBenchmarkCalibrationAggregator.areSemanticallyEqual(
                    try Self.recomputedAggregateCoefficients(in: document),
                    document.aggregateCoefficientsOfVariation.dictionary
                  )
            else {
                throw MacBenchmarkCalibrationError.invalidCalibrationDocument
            }

            let baseline = MacBenchmarkBaseline(
                comparisonKey: report.key,
                referenceMetrics: report.referenceMetrics,
                reportSHA256: reportHash,
                referenceHardware: report.referenceHardware,
                frozenAt: report.frozenAt
            )
            do {
                return try VerifiedMacBenchmarkBaseline(
                    baseline: baseline,
                    calibrationReport: reportData
                )
            } catch {
                throw MacBenchmarkCalibrationError.invalidCalibrationDocument
            }
        }
    }
}

private extension MacBenchmarkFrozenCatalogLoader {
    static func reportsSemanticallyEqual(
        _ lhs: MacBenchmarkCalibrationReport,
        _ rhs: MacBenchmarkCalibrationReport
    ) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.key == rhs.key
            && MacBenchmarkCalibrationAggregator.areSemanticallyEqual(
                lhs.referenceMetrics,
                rhs.referenceMetrics
            )
            && lhs.referenceHardware == rhs.referenceHardware
            && lhs.frozenAt.timeIntervalSinceReferenceDate.isFinite
            && rhs.frozenAt.timeIntervalSinceReferenceDate.isFinite
            && abs(lhs.frozenAt.timeIntervalSince(rhs.frozenAt)) <= 1e-6
            && lhs.sourceRunSHA256s == rhs.sourceRunSHA256s
    }

    static func recomputedReferences(
        in document: MacBenchmarkCalibrationDocument
    ) throws -> [BenchmarkComponent: Double] {
        try Dictionary(uniqueKeysWithValues: BenchmarkComponent.allCases.map { component in
            let values = document.runs.compactMap { $0.componentMedians[component] }
            guard values.count == document.runs.count,
                  let value = MacBenchmarkCalibrationAggregator.median(values)
            else {
                throw MacBenchmarkCalibrationError.invalidCalibrationDocument
            }
            return (component, value)
        })
    }

    static func recomputedAggregateCoefficients(
        in document: MacBenchmarkCalibrationDocument
    ) throws -> [BenchmarkComponent: Double] {
        try Dictionary(uniqueKeysWithValues: BenchmarkComponent.allCases.map { component in
            let values = document.runs.compactMap { $0.componentMedians[component] }
            let withinRunValues = document.runs.compactMap {
                $0.componentCoefficientsOfVariation[component]
            }
            guard values.count == document.runs.count,
                  withinRunValues.count == document.runs.count,
                  withinRunValues.allSatisfy({
                      $0.isFinite
                          && $0 >= 0
                          && $0 <= MacBenchmarkCalibrationAggregator
                            .maximumCoefficientOfVariation
                  }),
                  let coefficient = MacBenchmarkCalibrationAggregator
                    .coefficientOfVariation(values),
                  coefficient <= MacBenchmarkCalibrationAggregator
                    .maximumAggregateCoefficientOfVariation(for: component)
                    + MacBenchmarkCalibrationAggregator.semanticTolerance
            else {
                throw MacBenchmarkCalibrationError.invalidCalibrationDocument
            }
            return (component, coefficient)
        })
    }
}

enum MacBenchmarkProductionBaselineCatalog {
    static let activeBaselineVersion = "m5-pro-2026-07-v6"
    static let calibrationSourceBuild = MacBenchmarkCalibrationSourceBuild(
        appVersion: "1.8.2",
        appBuild: "202607172016"
    )

    // The v3 Quick/Full documents remain byte-for-byte frozen so older local
    // history can still be decoded and audited. They are not selectable in v4.
    private static let legacyV3FrozenDocuments: [FrozenMacBenchmarkCalibrationDocument] = [
            FrozenMacBenchmarkCalibrationDocument(
                profile: .full,
                documentBase64: "eyJhZ2dyZWdhdGVDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDIwNTUxNzYwNDI3NzkzMTU0fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDAyMzk4MzMzMzkxMzA1MDY0fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjo1LjM1MTcyNDYwNDY1NzEzNWUtMDV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjAuMDE0NTQ2MDg2Njc4NDA1NzY5fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDA0NjEyNjQ1ODI3NjcyNjA0fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjAwOTQwMTQ5NjQyNjEzODA5fV0sImJhc2VsaW5lUmVwb3J0Ijp7ImZyb3plbkF0Ijo4MDU5NDM1MjAsImtleSI6eyJhcmNoaXRlY3R1cmUiOiJhcm02NCIsImJhc2VsaW5lVmVyc2lvbiI6Im01LXByby0yMDI2LTA3LXYzIiwiY2FwYWJpbGl0eVNldCI6WyJjcHVTaW5nbGUiLCJjcHVNdWx0aSIsImdwdSIsIm1lbW9yeSIsImRpc2tSZWFkIiwiZGlza1dyaXRlIl0sInByb2ZpbGUiOiJmdWxsIiwid29ya2xvYWRWZXJzaW9uIjoibWFjLWJlbmNobWFyay1mdWxsLXYzIn0sInJlZmVyZW5jZUhhcmR3YXJlIjoiTWFjQm9vayBQcm8gTWFjMTcsOSDCtyBBcHBsZSBNNSBQcm8gwrcgMTggY29yZXMgwrcgNDggR0IiLCJyZWZlcmVuY2VNZXRyaWNzIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6NDE2LjA3ODU1MTIxMDAzMzI1fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY4MzEuMTU0MjE3NTczODM4fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMzgwLjc5NDI1NjI5ODAzMzR9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI5LjMyMTMzNDY0ODQxODA2fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTkwNzM3Nzc5NjQ2MDM3MjJ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjcuMDczOTY3MTAyNjY0OTQzfV0sInNjaGVtYVZlcnNpb24iOjEsInNvdXJjZVJ1blNIQTI1NnMiOlsiNWQyMTE2MDM0NDBiZTllNzZiMWVmZTYyODcwNWYzZTVjMjFhZGE1YjVlZTMxMjg4ZDZhYWRkOTgzYWM4NDY5MiIsIjlhYTVjOThiYzExYWY0MzhiNzAyNjQ4MTA0YzMwNjhmZDlmNGMxZDRiYjE4OWYxYTBjZWNmOTA0OWJlZTA3NTkiLCJhZGRkNDEyMzg3YTA5MzViYmRhY2U0YTYxM2ViMTkwNjk1MDZjYTMzMDJiNmYwZjBiMTIwOTc2YjUzZTVkMWUyIiwiYzliMjRjNDM5ZDIwOTJmZmFlNDA1ZmVjYjc2NzZkNDNkNTY4NTA2M2RjMjllZWZmMmM0MTc3NTIzNjk5MjY3NyIsImUzMzAyMjhjYmRkZWRmOTA1MTgxZDA0MzE1ZGM3N2NkZDI1NzNmN2E3MWNiMjE2ODBhOTdiMTQzNzllMGJlMzMiLCJlYjhiMzgyMjY2NTBkMGMyODU2MjhiMWU5Y2U5NjBjN2MwMWQzZjJiOWYyMTRkNGI3NTFiMTNiNDA0NGQxODk1IiwiZWVkN2EzMzViMDg1ZDUyODcxYzBhZGRlZjEzZDM2OGQwNDgwMmRmZmM2MWVjYTg1MzVjZDAwOTZlMjY3N2E4YiIsImY4ZGI1MjcyM2NmMjA2MGZkOGRmZWRiMWFhZjdlMDJkNTQ5MGJkODU5NDQ1MTZiNDY2YzljMDRlNjBjNjM3OTIiXX0sImJhc2VsaW5lUmVwb3J0QmFzZTY0IjoiZXlKbWNtOTZaVzVCZENJNk9EQTFPVFF6TlRJd0xDSnJaWGtpT25zaVlYSmphR2wwWldOMGRYSmxJam9pWVhKdE5qUWlMQ0ppWVhObGJHbHVaVlpsY25OcGIyNGlPaUp0TlMxd2NtOHRNakF5Tmkwd055MTJNeUlzSW1OaGNHRmlhV3hwZEhsVFpYUWlPbHNpWTNCMVUybHVaMnhsSWl3aVkzQjFUWFZzZEdraUxDSm5jSFVpTENKdFpXMXZjbmtpTENKa2FYTnJVbVZoWkNJc0ltUnBjMnRYY21sMFpTSmRMQ0p3Y205bWFXeGxJam9pWm5Wc2JDSXNJbmR2Y210c2IyRmtWbVZ5YzJsdmJpSTZJbTFoWXkxaVpXNWphRzFoY21zdFpuVnNiQzEyTXlKOUxDSnlaV1psY21WdVkyVklZWEprZDJGeVpTSTZJazFoWTBKdmIyc2dVSEp2SUUxaFl6RTNMRGtnd3JjZ1FYQndiR1VnVFRVZ1VISnZJTUszSURFNElHTnZjbVZ6SU1LM0lEUTRJRWRDSWl3aWNtVm1aWEpsYm1ObFRXVjBjbWxqY3lJNlczc2lZMjl0Y0c5dVpXNTBJam9pWTNCMVUybHVaMnhsSWl3aWRtRnNkV1VpT2pReE5pNHdOemcxTlRFeU1UQXdNek15Tlgwc2V5SmpiMjF3YjI1bGJuUWlPaUpqY0hWTmRXeDBhU0lzSW5aaGJIVmxJam8yT0RNeExqRTFOREl4TnpVM016Z3pPSDBzZXlKamIyMXdiMjVsYm5RaU9pSm5jSFVpTENKMllXeDFaU0k2TXpNNE1DNDNPVFF5TlRZeU9UZ3dNek0wZlN4N0ltTnZiWEJ2Ym1WdWRDSTZJbTFsYlc5eWVTSXNJblpoYkhWbElqb3lPUzR6TWpFek16UTJORGcwTVRnd05uMHNleUpqYjIxd2IyNWxiblFpT2lKa2FYTnJVbVZoWkNJc0luWmhiSFZsSWpvd0xqRTVNRGN6TnpjM09UWTBOakF6TnpJeWZTeDdJbU52YlhCdmJtVnVkQ0k2SW1ScGMydFhjbWwwWlNJc0luWmhiSFZsSWpvM0xqQTNNemsyTnpFd01qWTJORGswTTMxZExDSnpZMmhsYldGV1pYSnphVzl1SWpveExDSnpiM1Z5WTJWU2RXNVRTRUV5TlRaeklqcGJJalZrTWpFeE5qQXpORFF3WW1VNVpUYzJZakZsWm1VMk1qZzNNRFZtTTJVMVl6SXhZV1JoTldJMVpXVXpNVEk0T0dRMllXRmtaRGs0TTJGak9EUTJPVElpTENJNVlXRTFZems0WW1NeE1XRm1ORE00WWpjd01qWTBPREV3TkdNek1EWTRabVE1WmpSak1XUTBZbUl4T0RsbU1XRXdZMlZqWmprd05EbGlaV1V3TnpVNUlpd2lZV1JrWkRReE1qTTROMkV3T1RNMVltSmtZV05sTkdFMk1UTmxZakU1TURZNU5UQTJZMkV6TXpBeVlqWm1NR1l3WWpFeU1EazNObUkxTTJVMVpERmxNaUlzSW1NNVlqSTBZelF6T1dReU1Ea3labVpoWlRRd05XWmxZMkkzTmpjMlpEUXpaRFUyT0RVd05qTmtZekk1WldWbVpqSmpOREUzTnpVeU16WTVPVEkyTnpjaUxDSmxNek13TWpJNFkySmtaR1ZrWmprd05URTRNV1F3TkRNeE5XUmpOemRqWkdReU5UY3paamRoTnpGallqSXhOamd3WVRrM1lqRTBNemM1WlRCaVpUTXpJaXdpWldJNFlqTTRNakkyTmpVd1pEQmpNamcxTmpJNFlqRmxPV05sT1RZd1l6ZGpNREZrTTJZeVlqbG1NakUwWkRSaU56VXhZakV6WWpRd05EUmtNVGc1TlNJc0ltVmxaRGRoTXpNMVlqQTROV1ExTWpnM01XTXdZV1JrWldZeE0yUXpOamhrTURRNE1ESmtabVpqTmpGbFkyRTROVE0xWTJRd01EazJaVEkyTnpkaE9HSWlMQ0ptT0dSaU5USTNNak5qWmpJd05qQm1aRGhrWm1Wa1lqRmhZV1kzWlRBeVpEVTBPVEJpWkRnMU9UUTBOVEUyWWpRMk5tTTVZekEwWlRZd1l6WXpOemt5SWwxOSIsImJhc2VsaW5lUmVwb3J0U0hBMjU2IjoiNGEwYjU0OTBiMDFmZWQ5MjQyODNmZGVlZDNhZTA2YTY4MTYwZDllODFjMjZkNjg4YzZiYjlkZTMyYjhhNDQyMiIsImhhcmR3YXJlIjp7ImFjdGl2ZVByb2Nlc3NvckNvdW50IjoxOCwiYXJjaGl0ZWN0dXJlIjoiYXJtNjQiLCJjaGlwTmFtZSI6IkFwcGxlIE01IFBybyIsIm1vZGVsSWRlbnRpZmllciI6Ik1hYzE3LDkiLCJwaHlzaWNhbE1lbW9yeUJ5dGVzIjo1MTUzOTYwNzU1Mn0sImhhcm5lc3NJZGVudGlmaWVyIjoic3dpZnRwbS1yZWxlYXNlLXhjdGVzdC52MSIsImluZGVwZW5kZW50U2Vzc2lvbkNvdW50IjoyLCJtYXhpbXVtQWxsb3dlZENvZWZmaWNpZW50T2ZWYXJpYXRpb24iOjAuMDUsIm1heGltdW1BbGxvd2VkRHVyYWJsZVdyaXRlQWdncmVnYXRlQ29lZmZpY2llbnRPZlZhcmlhdGlvbiI6MC4xLCJtYXhpbXVtQWxsb3dlZEdQVUFnZ3JlZ2F0ZUNvZWZmaWNpZW50T2ZWYXJpYXRpb24iOjAuMSwicnVucyI6W3siY29tcGxldGVkQXQiOjgwNTk0MzI4My44Nzc1MTcsImNvbXBvbmVudENvZWZmaWNpZW50c09mVmFyaWF0aW9uIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6MC4wMDE2MjkyMjc0ODk3NzcyODF9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDY2MDI2OTM2ODk5NDI4OTJ9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjEuOTYxODI4NDI5NTQxODE5OGUtMDV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjAuMDIxNzM0OTczODEyMjQ5OTR9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMDc2NTgyMzU3ODQ4MjQxNDV9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDA4MjE0NjkwNTQwNjQyMDU0fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTYuMTIzMDE0NzcxMTAzNX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2ODMwLjY5ODIyNzgwMDU3NX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MzM4MC43NDM3OTgwNjY0OTI3fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjoyOC44NTEzMzg5NDg0NDAwMn0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE5MTcxMjcxMDgwMzA5NjI2fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjo3LjE4NTQxMDQyNTQ3MDcyNX1dLCJwcm9maWxlIjoiZnVsbCIsInNlc3Npb25MYWJlbCI6InNlc3Npb24tMiIsInNvdXJjZUJ1aWxkIjp7ImFwcEJ1aWxkIjoiMjAyNjA3MTcwOTAwIiwiYXBwVmVyc2lvbiI6IjEuNi4wIn0sInNvdXJjZVJ1blNIQTI1NiI6IjVkMjExNjAzNDQwYmU5ZTc2YjFlZmU2Mjg3MDVmM2U1YzIxYWRhNWI1ZWUzMTI4OGQ2YWFkZDk4M2FjODQ2OTIiLCJzdGFydGVkQXQiOjgwNTk0MzIxMi40NzcyMzIsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstZnVsbC12MyJ9LHsiY29tcGxldGVkQXQiOjgwNTk0MjI4Ny4yOTY3NDUsImNvbXBvbmVudENvZWZmaWNpZW50c09mVmFyaWF0aW9uIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6MC4wMDE4Njc4MDE0MzQyNTI0ODQ1fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDA1OTE0MDA3MDA4MTE0NjQ0fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozLjUyMDk1OTUxMjEwNzk3NDNlLTA1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMzk1NTMzNTg3NjgwNzgxM30seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwMzE0MzY0ODk2MDI2MTkwNjZ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDEyNjgwOTkwNDY0NDI3NDI1fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTYuODUzNTEwMzA2NjM4NDR9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6NjgyMy4xOTc3NjM2MjY2OTR9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjMzODAuNzczNjc4NzcxODM2fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjoyOS4zMzIxMTgwMTE0NTMzNTd9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4xOTExOTQ5MTQ1OTc1NjA4OH0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6Ny4wODcwMTc1NzM1NTI1MDV9XSwicHJvZmlsZSI6ImZ1bGwiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTEiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MDkwMCIsImFwcFZlcnNpb24iOiIxLjYuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiI5YWE1Yzk4YmMxMWFmNDM4YjcwMjY0ODEwNGMzMDY4ZmQ5ZjRjMWQ0YmIxODlmMWEwY2VjZjkwNDliZWUwNzU5Iiwic3RhcnRlZEF0Ijo4MDU5NDIyMTUuODIxMDY5LCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLWZ1bGwtdjMifSx7ImNvbXBsZXRlZEF0Ijo4MDU5NDI0MzAuNzIxMzg5LCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDAxNjU0NjI1NjEyNzUxNjkyM30seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAwODc1MDgzMTU4Mjg3MjYwM30seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6NC44Njk5MzcyMzQ0NDUwNThlLTA1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMTc5NTAwNjAzOTE5NjI0NDJ9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMDQ5ODkyNjE4MzU1NjU3NTN9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDA4NzUwNjYwMzg4MzUzODM0fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTUuMzQ0NzM0NzAyMDU1Mn0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2ODQ5LjAzMzAxMTIyMDU2fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMzgwLjYxNjQ1ODg1Njk1OTV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI5LjM0MzA1Njk3NDU0OTQ5fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTkxNzgwMTI2ODUyNTA4MzR9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjcuMDYwOTE2NjMxNzc3Mzh9XSwicHJvZmlsZSI6ImZ1bGwiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTEiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MDkwMCIsImFwcFZlcnNpb24iOiIxLjYuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiJhZGRkNDEyMzg3YTA5MzViYmRhY2U0YTYxM2ViMTkwNjk1MDZjYTMzMDJiNmYwZjBiMTIwOTc2YjUzZTVkMWUyIiwic3RhcnRlZEF0Ijo4MDU5NDIzNTkuMjExNDQ0LCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLWZ1bGwtdjMifSx7ImNvbXBsZXRlZEF0Ijo4MDU5NDM0MjYuOTIwMTU2LCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDAxMDY0NDEzODQxNTA5NTEwMn0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAwODQyNTE2NzMyNTc4Mzc4fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjo4LjU1MzcwNzg5ODQzOTc1OWUtMDV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjAuMDAyOTIwMzAxNzMxOTkwMTI4fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDI1NTQzMDEzMDExMDIyNDZ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDA1MjYyNzYzNTUzNDc0MzAyfV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTYuNzc2NjE1NDY3MjY5NDR9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6NjgxNy4yOTI0NDMwOTE1OTd9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjMzODAuNTg0MjAwNjk3NjY3M30seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjkuMjgxODQ5OTQxOTY0MTF9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4xODk3ODUwNDM4NjUxMjE4NX0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6Ny4xOTIxMTY0MjM4Nzc1NzN9XSwicHJvZmlsZSI6ImZ1bGwiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTIiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MDkwMCIsImFwcFZlcnNpb24iOiIxLjYuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiJjOWIyNGM0MzlkMjA5MmZmYWU0MDVmZWNiNzY3NmQ0M2Q1Njg1MDYzZGMyOWVlZmYyYzQxNzc1MjM2OTkyNjc3Iiwic3RhcnRlZEF0Ijo4MDU5NDMzNTUuMTk2NjQzLCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLWZ1bGwtdjMifSx7ImNvbXBsZXRlZEF0Ijo4MDU5NDMyMTIuNDc2NTc5LCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDAzMTI0MzU3OTk2MDk2OTg2fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDA1NzQ4MjE5ODk3NTc2Mjk2fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjoyLjg4MDI5NDAwNDkxNDYxMDNlLTA1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMzk0NjA1NDI3MTE3NTg5fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDE4Mzg0NTk0ODgyNjE4MDI4fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjAxMjYxNjg2NzAyNDIwOTUzNH1dLCJjb21wb25lbnRNZWRpYW5zIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6MzkyLjI0Njc1OTQzNzMwODd9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6Njg1NC42NTMyNTM1NjE0MDJ9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjMzODEuMDA2MjkyMzE2NzMyNX0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjguMTY4NTUxOTczMzEyMTYyfSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTkwNDM1NTgxMTE1OTc3MjV9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjcuMDAzMjg4Mjc1Njk0MTM4fV0sInByb2ZpbGUiOiJmdWxsIiwic2Vzc2lvbkxhYmVsIjoic2Vzc2lvbi0yIiwic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzA5MDAiLCJhcHBWZXJzaW9uIjoiMS42LjAifSwic291cmNlUnVuU0hBMjU2IjoiZTMzMDIyOGNiZGRlZGY5MDUxODFkMDQzMTVkYzc3Y2RkMjU3M2Y3YTcxY2IyMTY4MGE5N2IxNDM3OWUwYmUzMyIsInN0YXJ0ZWRBdCI6ODA1OTQzMTM5LjkxMzAyNiwid29ya2xvYWRWZXJzaW9uIjoibWFjLWJlbmNobWFyay1mdWxsLXYzIn0seyJjb21wbGV0ZWRBdCI6ODA1OTQyMjE1LjgyMDI1NiwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMTE5ODYwMTE0ODc2NTc3ODR9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMTAwNDI0MTYwNDI5NzA4ODd9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjAuMDAwMTExNDgxNTcyMjYwODI5ODF9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjAuMDAyMTYzODQ4MDM0MDU4MjQyMn0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwODI3MDc2NTg1NDE3NTQxMn0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDQzNzIzMzIyNjU3MDkwMTk1fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTYuMDM0MDg3NjQ4OTYzfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY4NDIuNTE0MTMwNjQzNjUzfSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMzgxLjEyMDIyMjMwNzM5NTZ9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI5LjMxMTU4OTAyOTUxMTE0N30seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE5MDg1MjYxMDY1MTc2Njc5fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjo3LjA1NzAxODQ1Mjk5Nzc2M31dLCJwcm9maWxlIjoiZnVsbCIsInNlc3Npb25MYWJlbCI6InNlc3Npb24tMSIsInNvdXJjZUJ1aWxkIjp7ImFwcEJ1aWxkIjoiMjAyNjA3MTcwOTAwIiwiYXBwVmVyc2lvbiI6IjEuNi4wIn0sInNvdXJjZVJ1blNIQTI1NiI6ImViOGIzODIyNjY1MGQwYzI4NTYyOGIxZTljZTk2MGM3YzAxZDNmMmI5ZjIxNGQ0Yjc1MWIxM2I0MDQ0ZDE4OTUiLCJzdGFydGVkQXQiOjgwNTk0MjE0NC4wMjM1MzgsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstZnVsbC12MyJ9LHsiY29tcGxldGVkQXQiOjgwNTk0MzM1NS4xOTU4NiwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMTczOTY4OTQyOTQwNjc0MDh9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDUwMzg1MDE4NjE3NzQwNjk2fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjo5LjE4MDg0NzgxMTYyOTk0MWUtMDV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjAuMDAxMzIxMTkzODk0MDMwMjcyNn0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAxMTQyNjk1MTE5MTQxMzA4MX0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDI5NzgwMzA3NTgxMjIyMDI2fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTUuODg4Njk5MzgxMDY4MTR9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6NjgzMS42MTAyMDczNDcxfSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMzgwLjgxNDgzMzgyNDIzMX0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjkuMzk4MTI1Mjk0NjU0MDY1fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTkwNjIyOTQ4NjQwMzA3NjN9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjcuMTI4ODQ5ODU3MjA3Njl9XSwicHJvZmlsZSI6ImZ1bGwiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTIiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MDkwMCIsImFwcFZlcnNpb24iOiIxLjYuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiJlZWQ3YTMzNWIwODVkNTI4NzFjMGFkZGVmMTNkMzY4ZDA0ODAyZGZmYzYxZWNhODUzNWNkMDA5NmUyNjc3YThiIiwic3RhcnRlZEF0Ijo4MDU5NDMyODMuODc4MzMyLCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLWZ1bGwtdjMifSx7ImNvbXBsZXRlZEF0Ijo4MDU5NDIzNTkuMjEwNjM2LCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDAwNjYzMjI0NzQzMDAwMTk0OX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAxMDczMzE1MTQ2OTY3MzQ4Nn0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6NS42MDY4MTY3NTM5NjE1NzdlLTA1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwNTczNzcwNDEwNjM1MTc3Nn0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwNDEwNzQyMzAyODgwNDE1Nn0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDk1NTQxMDEzNzYxNzcyMDV9XSwiY29tcG9uZW50TWVkaWFucyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQxNi41NTk5MzkwMDIxNzM1fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY4MDYuMTE2OTc2MzYzMzkyfSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMzgwLjgyNDc5MjY4NjY0MTZ9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI5LjMzMTA4MDI2NzMyNDk3NX0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE4OTI3MDQ3ODUzMzkwMjIyfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjo3LjA1ODI1ODA0MDA3MjgzMn1dLCJwcm9maWxlIjoiZnVsbCIsInNlc3Npb25MYWJlbCI6InNlc3Npb24tMSIsInNvdXJjZUJ1aWxkIjp7ImFwcEJ1aWxkIjoiMjAyNjA3MTcwOTAwIiwiYXBwVmVyc2lvbiI6IjEuNi4wIn0sInNvdXJjZVJ1blNIQTI1NiI6ImY4ZGI1MjcyM2NmMjA2MGZkOGRmZWRiMWFhZjdlMDJkNTQ5MGJkODU5NDQ1MTZiNDY2YzljMDRlNjBjNjM3OTIiLCJzdGFydGVkQXQiOjgwNTk0MjI4Ny4yOTc1NjcsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstZnVsbC12MyJ9XSwic2NoZW1hVmVyc2lvbiI6Mywic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzA5MDAiLCJhcHBWZXJzaW9uIjoiMS42LjAifSwidmFsaWRSdW5Db3VudCI6OH0=",
                documentSHA256: "09e9af893ed4da240ca5390f64d7550cc844a51d38a36b8f33e9d5f7d75cd6dd"
            ),
            FrozenMacBenchmarkCalibrationDocument(
                profile: .quick,
                documentBase64: "eyJhZ2dyZWdhdGVDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDM5NjMzNTM5MDQ1MjI3Nzh9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMTIyMjA1NDY0MzYzMjY1NTl9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjAuMDAwMTQwODkzMDcyNDM3MjkwNn0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMjE2NTA1Njc3NDgxODExfSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDMwNTUzNTE0MTA1NTI4MDYyfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjA5NjQzNzM0NTA3MjcyMzExfV0sImJhc2VsaW5lUmVwb3J0Ijp7ImZyb3plbkF0Ijo4MDU5NDM1MjAsImtleSI6eyJhcmNoaXRlY3R1cmUiOiJhcm02NCIsImJhc2VsaW5lVmVyc2lvbiI6Im01LXByby0yMDI2LTA3LXYzIiwiY2FwYWJpbGl0eVNldCI6WyJjcHVTaW5nbGUiLCJjcHVNdWx0aSIsImdwdSIsIm1lbW9yeSIsImRpc2tSZWFkIiwiZGlza1dyaXRlIl0sInByb2ZpbGUiOiJxdWljayIsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstcXVpY2stdjMifSwicmVmZXJlbmNlSGFyZHdhcmUiOiJNYWNCb29rIFBybyBNYWMxNyw5IMK3IEFwcGxlIE01IFBybyDCtyAxOCBjb3JlcyDCtyA0OCBHQiIsInJlZmVyZW5jZU1ldHJpY3MiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTMuODYwMjAwNjEzNTYwOX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2OTI0LjY4MjM5ODI4NTU2OX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MzMxOS45OTU3NTMyMDAzNTM2fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjoyOS45NjI5MzcxMTgxMjAxNjZ9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4xODk1NDEwMTE5MjY1MDU3fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoxLjkzMTMwMzI0Mjc2NDA5NzV9XSwic2NoZW1hVmVyc2lvbiI6MSwic291cmNlUnVuU0hBMjU2cyI6WyIxNDM1NzRmN2FhODgzMWEyYWY1NWY5ZmYzNjYyNjJiYWIzYjRkYzc1NmY2OTY1MDU0OWViMjA4YTUwZGE3YjRlIiwiM2JlZmVmZDhhYmQ5ZTQ2OWE2MDlkMWE0YjliYjRiZDc4YjBkOTg2ZTZlZjVkNTIwNzA5MmU4NmRmMTc0MGVhYyIsIjQ3ODhkZTY3YzEzYjdiMWFiOTRhMGI5NjQzMjg5ZDdlYTU4Mjk2OWEzZWMyMGVjYTgxYWFmNGY2Zjc2NGEyYjciLCI1NThiMDU5MWEwMmQwNWYyYTliNDg1YjhkZTc0YThmODAyYjQ2YzNiMWQ0Yzk0YmJiNjhiOThkMjViZjg2MGIxIiwiNTY0YTI1OWFhYzgwMjY1YmQ0NjJhNjg0NzRjOWU0ZDQ0NjMxYTYzNWUwNzQwZjRkMDQzYmFiYmRkZDc4YTYwOCIsIjhhNzY4ZmYzNzI0ODk4ZTdjODg4YzlhNGNhMGYwYzU2OTk0MmFmNDcyY2VkMzVlODdhZDFmMGNiMWI2NWVmYWYiLCJkNmFiZDc4YTg2MmM5MjQzNGZiYjA0N2M3MDMyMGMwOTNjOTk2NTE5NDMxZTk2NGViYzk3Yjk3ZmU3ZmMyNDkyIiwiZmE4MmQ1MTllYWNhN2UzNGM5NDhmYjZhMDQ4YjllMmQxNmZmZWUxMmRmNTIxM2JlYzdjNTA5YWEzZjViYThiNCJdfSwiYmFzZWxpbmVSZXBvcnRCYXNlNjQiOiJleUptY205NlpXNUJkQ0k2T0RBMU9UUXpOVEl3TENKclpYa2lPbnNpWVhKamFHbDBaV04wZFhKbElqb2lZWEp0TmpRaUxDSmlZWE5sYkdsdVpWWmxjbk5wYjI0aU9pSnROUzF3Y204dE1qQXlOaTB3TnkxMk15SXNJbU5oY0dGaWFXeHBkSGxUWlhRaU9sc2lZM0IxVTJsdVoyeGxJaXdpWTNCMVRYVnNkR2tpTENKbmNIVWlMQ0p0WlcxdmNua2lMQ0prYVhOclVtVmhaQ0lzSW1ScGMydFhjbWwwWlNKZExDSndjbTltYVd4bElqb2ljWFZwWTJzaUxDSjNiM0pyYkc5aFpGWmxjbk5wYjI0aU9pSnRZV010WW1WdVkyaHRZWEpyTFhGMWFXTnJMWFl6SW4wc0luSmxabVZ5Wlc1alpVaGhjbVIzWVhKbElqb2lUV0ZqUW05dmF5QlFjbThnVFdGak1UY3NPU0RDdHlCQmNIQnNaU0JOTlNCUWNtOGd3cmNnTVRnZ1kyOXlaWE1nd3JjZ05EZ2dSMElpTENKeVpXWmxjbVZ1WTJWTlpYUnlhV056SWpwYmV5SmpiMjF3YjI1bGJuUWlPaUpqY0hWVGFXNW5iR1VpTENKMllXeDFaU0k2TkRFekxqZzJNREl3TURZeE16VTJNRGw5TEhzaVkyOXRjRzl1Wlc1MElqb2lZM0IxVFhWc2RHa2lMQ0oyWVd4MVpTSTZOamt5TkM0Mk9ESXpPVGd5T0RVMU5qbDlMSHNpWTI5dGNHOXVaVzUwSWpvaVozQjFJaXdpZG1Gc2RXVWlPak16TVRrdU9UazFOelV6TWpBd016VXpObjBzZXlKamIyMXdiMjVsYm5RaU9pSnRaVzF2Y25raUxDSjJZV3gxWlNJNk1qa3VPVFl5T1RNM01URTRNVEl3TVRZMmZTeDdJbU52YlhCdmJtVnVkQ0k2SW1ScGMydFNaV0ZrSWl3aWRtRnNkV1VpT2pBdU1UZzVOVFF4TURFeE9USTJOVEExTjMwc2V5SmpiMjF3YjI1bGJuUWlPaUprYVhOclYzSnBkR1VpTENKMllXeDFaU0k2TVM0NU16RXpNRE15TkRJM05qUXdPVGMxZlYwc0luTmphR1Z0WVZabGNuTnBiMjRpT2pFc0luTnZkWEpqWlZKMWJsTklRVEkxTm5NaU9sc2lNVFF6TlRjMFpqZGhZVGc0TXpGaE1tRm1OVFZtT1dabU16WTJNall5WW1GaU0ySTBaR00zTlRabU5qazJOVEExTkRsbFlqSXdPR0UxTUdSaE4ySTBaU0lzSWpOaVpXWmxabVE0WVdKa09XVTBOamxoTmpBNVpERmhOR0k1WW1JMFltUTNPR0l3WkRrNE5tVTJaV1kxWkRVeU1EY3dPVEpsT0Raa1pqRTNOREJsWVdNaUxDSTBOemc0WkdVMk4yTXhNMkkzWWpGaFlqazBZVEJpT1RZME16STRPV1EzWldFMU9ESTVOamxoTTJWak1qQmxZMkU0TVdGaFpqUm1ObVkzTmpSaE1tSTNJaXdpTlRVNFlqQTFPVEZoTURKa01EVm1NbUU1WWpRNE5XSTRaR1UzTkdFNFpqZ3dNbUkwTm1NellqRmtOR001TkdKaVlqWTRZams0WkRJMVltWTROakJpTVNJc0lqVTJOR0V5TlRsaFlXTTRNREkyTldKa05EWXlZVFk0TkRjMFl6bGxOR1EwTkRZek1XRTJNelZsTURjME1HWTBaREEwTTJKaFltSmtaR1EzT0dFMk1EZ2lMQ0k0WVRjMk9HWm1NemN5TkRnNU9HVTNZemc0T0dNNVlUUmpZVEJtTUdNMU5qazVOREpoWmpRM01tTmxaRE0xWlRnM1lXUXhaakJqWWpGaU5qVmxabUZtSWl3aVpEWmhZbVEzT0dFNE5qSmpPVEkwTXpSbVltSXdORGRqTnpBek1qQmpNRGt6WXprNU5qVXhPVFF6TVdVNU5qUmxZbU01TjJJNU4yWmxOMlpqTWpRNU1pSXNJbVpoT0RKa05URTVaV0ZqWVRkbE16UmpPVFE0Wm1JMllUQTBPR0k1WlRKa01UWm1abVZsTVRKa1pqVXlNVE5pWldNM1l6VXdPV0ZoTTJZMVltRTRZalFpWFgwPSIsImJhc2VsaW5lUmVwb3J0U0hBMjU2IjoiNTFmMmVmYjIwYTcwYTIwNTYyMTgxOGVjOGY3NjIzY2M2NTE3NzM0OWVlNDI1ZWUxMTRiMGQ2ODRmMDMxMTY2NyIsImhhcmR3YXJlIjp7ImFjdGl2ZVByb2Nlc3NvckNvdW50IjoxOCwiYXJjaGl0ZWN0dXJlIjoiYXJtNjQiLCJjaGlwTmFtZSI6IkFwcGxlIE01IFBybyIsIm1vZGVsSWRlbnRpZmllciI6Ik1hYzE3LDkiLCJwaHlzaWNhbE1lbW9yeUJ5dGVzIjo1MTUzOTYwNzU1Mn0sImhhcm5lc3NJZGVudGlmaWVyIjoic3dpZnRwbS1yZWxlYXNlLXhjdGVzdC52MSIsImluZGVwZW5kZW50U2Vzc2lvbkNvdW50IjoyLCJtYXhpbXVtQWxsb3dlZENvZWZmaWNpZW50T2ZWYXJpYXRpb24iOjAuMDUsIm1heGltdW1BbGxvd2VkRHVyYWJsZVdyaXRlQWdncmVnYXRlQ29lZmZpY2llbnRPZlZhcmlhdGlvbiI6MC4xLCJtYXhpbXVtQWxsb3dlZEdQVUFnZ3JlZ2F0ZUNvZWZmaWNpZW50T2ZWYXJpYXRpb24iOjAuMSwicnVucyI6W3siY29tcGxldGVkQXQiOjgwNTk0MzA3NC4xMTU1OSwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwNDg0NjE2NTQxODM2MTE4Mn0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAwNjI3NjQyMDg1ODYwNzc3OH0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6Ny44NDU5Mjk5MDY2Mzc2MzdlLTA1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMzQ3MDYzMjA1NjY0NTUxNn0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwNDEzOTk0ODE3OTQ3MDA3MX0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDM5OTMzNDQzNzYxMTM5MzZ9XSwiY29tcG9uZW50TWVkaWFucyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQ0MS42MDQxNzMxNTk0MzYzNn0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2OTMwLjY5NzQ5MDU1MzA1NX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MzMxOS45MDc2MjUyODI0Nzc1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjoyOS4xMjkyODk1Nzg1NTcwNTZ9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4xODk1Mzk0MDg3Mjg4MjQyfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoxLjY1OTYwMzM5ODUyMjY5MDh9XSwicHJvZmlsZSI6InF1aWNrIiwic2Vzc2lvbkxhYmVsIjoic2Vzc2lvbi0yIiwic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzA5MDAiLCJhcHBWZXJzaW9uIjoiMS42LjAifSwic291cmNlUnVuU0hBMjU2IjoiMTQzNTc0ZjdhYTg4MzFhMmFmNTVmOWZmMzY2MjYyYmFiM2I0ZGM3NTZmNjk2NTA1NDllYjIwOGE1MGRhN2I0ZSIsInN0YXJ0ZWRBdCI6ODA1OTQzMDUyLjQ1MDE3LCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXF1aWNrLXYzIn0seyJjb21wbGV0ZWRBdCI6ODA1OTQyMTQ0LjAyMjc5OCwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDk5MjE5MjA1NzU4OTMxMTR9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDQ3NzM5MDY3MDkwODg0Nzl9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjYuNTY1NzgzNjUzODEyNDAxZS0wNX0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDAyODY1NTUzNjk2MzIxMjQ5NX0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwMTE0NzY2MjUyOTkxMTI5OTF9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDA0MTg3MDk1ODMxOTc5OTk5fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTQuNDQ3NDUxNjYzNjQxM30seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2OTM3LjM4OTA2MTA1NDQ3MX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MzMyMC4yMDA4NjA2ODQ4MDF9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjMwLjM5NjA2NzQ5Nzg3MjgyNH0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE5MDk1Mzk0Mzk3NDQ5MDQyfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoyLjA3MzYwMDU3OTIyMTM1M31dLCJwcm9maWxlIjoicXVpY2siLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTEiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MDkwMCIsImFwcFZlcnNpb24iOiIxLjYuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiIzYmVmZWZkOGFiZDllNDY5YTYwOWQxYTRiOWJiNGJkNzhiMGQ5ODZlNmVmNWQ1MjA3MDkyZTg2ZGYxNzQwZWFjIiwic3RhcnRlZEF0Ijo4MDU5NDIxMjIuNjYxNDgyLCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXF1aWNrLXYzIn0seyJjb21wbGV0ZWRBdCI6ODA1OTQyMTIyLjY2MDc3NSwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMTI2MjgxNDUwOTMzMzY5Njl9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDczOTk2NDk5MzAyMDI0NjZ9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjAuMDAwMjI2ODU4MDg2NjgxMzA2M30seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDA0MTA5NzU4NjkxMTk2NTA4N30seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwNjc4OTgxNjg2ODQ4NjI5NX0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDg4NTc1MDExOTQ1NzkzNH1dLCJjb21wb25lbnRNZWRpYW5zIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6NDEzLjA3NTU2MjcwNzg4MjQ1fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY5MTguNjY3MzA2MDE4MDg0fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMzE5LjQ4MzMxMjY0MzI2MzZ9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjMwLjQ1OTIwMDc3NjU4ODEyfSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTkyMDUxODg5OTk2NTg0NjJ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjIuMDYxODEzODk1MTE4ODczfV0sInByb2ZpbGUiOiJxdWljayIsInNlc3Npb25MYWJlbCI6InNlc3Npb24tMSIsInNvdXJjZUJ1aWxkIjp7ImFwcEJ1aWxkIjoiMjAyNjA3MTcwOTAwIiwiYXBwVmVyc2lvbiI6IjEuNi4wIn0sInNvdXJjZVJ1blNIQTI1NiI6IjQ3ODhkZTY3YzEzYjdiMWFiOTRhMGI5NjQzMjg5ZDdlYTU4Mjk2OWEzZWMyMGVjYTgxYWFmNGY2Zjc2NGEyYjciLCJzdGFydGVkQXQiOjgwNTk0MjEwMS4yODA1NDcsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstcXVpY2stdjMifSx7ImNvbXBsZXRlZEF0Ijo4MDU5NDIwODAuMDcxOTEyLCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDAwOTM1NjYzNTA0MTkzODg2NH0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAwMDcyNjE2NTc0MTMyNTM0NzN9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjAuMDAwNDAzNTc3OTI0OTc4MDUyNDV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjAuMDA5MDE4Mjc3NzI4ODAyMjU4fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDAxNjkxMTUxMTM5MDU0NzY4fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjAwOTI5NDA0OTM3NDU0MjU3NH1dLCJjb21wb25lbnRNZWRpYW5zIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6NDM3LjM3OTk2NjI1MDc1OTV9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6Njk1Ny4yNzcxOTM4NTg2Mzc1fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMzE5LjM3NjQyNDY5MzI5NjV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjMwLjA5MDQ4OTY2NDI3MDEzfSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTkxODg0MjA5ODg2NzM2MDd9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjIuMDUxMTE2NzIwMzA1MTIyNn1dLCJwcm9maWxlIjoicXVpY2siLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTEiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MDkwMCIsImFwcFZlcnNpb24iOiIxLjYuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiI1NThiMDU5MWEwMmQwNWYyYTliNDg1YjhkZTc0YThmODAyYjQ2YzNiMWQ0Yzk0YmJiNjhiOThkMjViZjg2MGIxIiwic3RhcnRlZEF0Ijo4MDU5NDIwNTguNzA1NjI1LCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXF1aWNrLXYzIn0seyJjb21wbGV0ZWRBdCI6ODA1OTQzMTM5LjkxMjIwNywiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwNTM0OTc0NzUxNTMzODY2NX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAwNjc0MzM0ODg2NTg4NTA3OX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6Ny40NTYxMzY1NjM3MDkyNzNlLTA1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMDkyMjU1NzAzMDQ0MDA1ODh9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMDYwMDg0NTU4NjY1MjMzOTN9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDI1NDI1NDQyOTI4NDc4MDIzfV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjozOTIuNzQ1ODYxMjEwMzYzfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY4ODguNTM0MjU4Njk4NzN9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjMzMjAuMzMwMzYxOTA2MTQyNn0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjguOTQ2NTkwODAzNjMwNjV9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4xNzgzOTE4Njk4MjEwNDEwOH0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MS42OTcwOTA5NzY2MjMwMzZ9XSwicHJvZmlsZSI6InF1aWNrIiwic2Vzc2lvbkxhYmVsIjoic2Vzc2lvbi0yIiwic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzA5MDAiLCJhcHBWZXJzaW9uIjoiMS42LjAifSwic291cmNlUnVuU0hBMjU2IjoiNTY0YTI1OWFhYzgwMjY1YmQ0NjJhNjg0NzRjOWU0ZDQ0NjMxYTYzNWUwNzQwZjRkMDQzYmFiYmRkZDc4YTYwOCIsInN0YXJ0ZWRBdCI6ODA1OTQzMTE3Ljg5MjcsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstcXVpY2stdjMifSx7ImNvbXBsZXRlZEF0Ijo4MDU5NDMxMTcuODkxOTU1LCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDE1NDA1MzQ1MzI0MDI2MzQ3fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDAzMzM1Nzg1MzcxMzQxMDY3Mn0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MC4wMDAxMzcwNDAxNTQzNTQwNjkzMn0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6NS42NjM1MzgxMTUxMzU4OTFlLTA2fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDAzNzMwODMxNTI3NjA0ODUxN30seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMjU4MDE1ODU4MjIwNzI5MTV9XSwiY29tcG9uZW50TWVkaWFucyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQwMC44MzUzNTI1NjU3NzgyfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY5MTIuODUzNTM2NTMyMzcwNX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MzMyMC41OTI3NDQxMzc5MzY3fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjoyOS44MzUzODQ1NzE5NzAyfSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTc4MjY1NTMzMjEyNTg4MjN9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjEuNzI3MTUwMDIxMjk1MDU3Mn1dLCJwcm9maWxlIjoicXVpY2siLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTIiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MDkwMCIsImFwcFZlcnNpb24iOiIxLjYuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiI4YTc2OGZmMzcyNDg5OGU3Yzg4OGM5YTRjYTBmMGM1Njk5NDJhZjQ3MmNlZDM1ZTg3YWQxZjBjYjFiNjVlZmFmIiwic3RhcnRlZEF0Ijo4MDU5NDMwOTUuODg0NjgsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstcXVpY2stdjMifSx7ImNvbXBsZXRlZEF0Ijo4MDU5NDMwOTUuODg0MDI0LCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDA0MjYwNzU5OTg0OTU1NjcxfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDAxMDIzNjUzMTY3NTUzMDQzM30seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6My4zNDU0NzcxNTI0NTgxMjY0ZS0wNX0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDA1NDgyMjIxNTE4MjI5MTk0fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDAxMDEwNDQ0NDI5NzA5MjA1Mn0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDE1ODAzMzU1NDg1MDkyNjA0fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTMuMjcyOTQ5NTYzNDgwNDR9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6NjcwNi43MzUwNDkwNzAwOTV9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjMzMjAuMDgzODgxMTE4MjMwMn0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjkuMTQ4NjU3OTAyNzczNzI0fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTg2MjUxNDc4NzkxNjI3NjJ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjEuODIyNzg1OTIxMzQ2NTU2M31dLCJwcm9maWxlIjoicXVpY2siLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTIiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MDkwMCIsImFwcFZlcnNpb24iOiIxLjYuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiJkNmFiZDc4YTg2MmM5MjQzNGZiYjA0N2M3MDMyMGMwOTNjOTk2NTE5NDMxZTk2NGViYzk3Yjk3ZmU3ZmMyNDkyIiwic3RhcnRlZEF0Ijo4MDU5NDMwNzQuMTE2NjgyLCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXF1aWNrLXYzIn0seyJjb21wbGV0ZWRBdCI6ODA1OTQyMTAxLjI3OTg0MSwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDIwNzQzMjg3NzQ1NDk4OTYyfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDAzMDgwNDUzNzQxNjA4NTk1Nn0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MC4wMDAyMTgxMzI3MjM2NDYwOTg0M30seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDE0NDcwMjQ4NzU1NjU3MTE0fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDAxMjA5MTc5ODUwMDgxNzkzM30seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDc2NTA4NjM2MzE2ODg3NjJ9XSwiY29tcG9uZW50TWVkaWFucyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQxNC44NDkyMjU1MzM3NTM4fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY5NzkuNjA1NjM5MzY1Njg0fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMzE5LjM1NTU0MDk1ODY2MzR9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjMwLjQ2MTk3MDE1MzUyNDQ2fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTg5NTQyNjE1MTI0MTg3Mn0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6Mi4wMzk4MjA1NjQxODE2Mzl9XSwicHJvZmlsZSI6InF1aWNrIiwic2Vzc2lvbkxhYmVsIjoic2Vzc2lvbi0xIiwic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzA5MDAiLCJhcHBWZXJzaW9uIjoiMS42LjAifSwic291cmNlUnVuU0hBMjU2IjoiZmE4MmQ1MTllYWNhN2UzNGM5NDhmYjZhMDQ4YjllMmQxNmZmZWUxMmRmNTIxM2JlYzdjNTA5YWEzZjViYThiNCIsInN0YXJ0ZWRBdCI6ODA1OTQyMDgwLjA3MzE4NCwid29ya2xvYWRWZXJzaW9uIjoibWFjLWJlbmNobWFyay1xdWljay12MyJ9XSwic2NoZW1hVmVyc2lvbiI6Mywic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzA5MDAiLCJhcHBWZXJzaW9uIjoiMS42LjAifSwidmFsaWRSdW5Db3VudCI6OH0=",
                documentSHA256: "9254fc76fa09661f2951290651ab683c3cdb203f6cf6ac03c47437beef8aa9f2"
            )
    ]

    // Byte-for-byte v4 document retained only for old Standard history.
    private static let legacyV4FrozenDocuments: [FrozenMacBenchmarkCalibrationDocument] = [
        FrozenMacBenchmarkCalibrationDocument(
            profile: .standard,
            documentBase64: "eyJhZ2dyZWdhdGVDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDEyNzIwNTE4NzU0MzkwNjQ2fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDE1NTk2OTkwNTczMzU1ODU3fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjowLjAwMzQzNTQ3NzEzNDc0MDg5M30seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMTcyODcwMzM3NTU0OTAzNzJ9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMTMwODQ4NDM5MjI5OTQ1NjV9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDU4MTYxMjY0MzExODM3MDk1fV0sImJhc2VsaW5lUmVwb3J0Ijp7ImZyb3plbkF0Ijo4MDU5NzM2MDcsImtleSI6eyJhcmNoaXRlY3R1cmUiOiJhcm02NCIsImJhc2VsaW5lVmVyc2lvbiI6Im01LXByby0yMDI2LTA3LXY0IiwiY2FwYWJpbGl0eVNldCI6WyJjcHVTaW5nbGUiLCJjcHVNdWx0aSIsImdwdSIsIm1lbW9yeSIsImRpc2tSZWFkIiwiZGlza1dyaXRlIl0sInByb2ZpbGUiOiJzdGFuZGFyZCIsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstc3RhbmRhcmQtdjQifSwicmVmZXJlbmNlSGFyZHdhcmUiOiJNYWNCb29rIFBybyBNYWMxNyw5IMK3IEFwcGxlIE01IFBybyDCtyAxOCBjb3JlcyDCtyA0OCBHQiIsInJlZmVyZW5jZU1ldHJpY3MiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTkuMTE5NjgwMTMzMzA5OX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2OTA2LjM0NzM4Njk4NzczOH0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MjUxMy4wNDc4Njc2NTQ2NDA0fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjoyOC4xODc5NzY1NTM1OTczMjN9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4xODYxMjIyMjI1NTUwMDc4OH0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6Mi4wNDI2NDUwNzY3MjM4Njh9XSwic2NoZW1hVmVyc2lvbiI6MSwic291cmNlUnVuU0hBMjU2cyI6WyIwNTZmOGRiZDRmZjE5ZGQzMjI4ZWMxOGNhYzVkZGUxN2I4OWJmYzFhMDM4ZTAzZTQ4NmE3MGJkMTM5YzQ4NTU5IiwiMWY3YWY4Yzc3ZWM0MjE2MWQwNWY0ZGVjZDRmYTAxZDI4MDA1ODVhNmU3OGU1MTM3YzAyYjM0ZGI4NWZlYWExYSIsIjIxZTFjNGZiODQ4ODk5ZDk0ZjY2NmVhNmFlZTQwNzRmNDA2NDMyOGM3ZjBmYTA0YTIwNDY1MjRiOGI3NDNjMWIiLCIyMmVkNzViZTUwYTQ5MTFiOTlmMzRiMWRlZGM5ZTRlYzEwMDU0YzM0NDY1YWZmMzFhNDFjMjk3NDA0YzhlOGE4IiwiNTlmMWFjNzdlY2E3ZTIxOGEzNmY5NjRhZjE5OGQxNTYyMGExMjEyNzI0MjliMjQ0ZjgxNGY0MjU5MGM3MzEyOCIsIjYwZDg4ZWI3NjYyOGY2ZmUxNjYzZjUyYWZlYzAwODlhZDFlMWY1OWUwYjYwMWZiY2I5ZjM4ZjUzZjEyZGNlNTMiLCJkZTIwZTkxZDhhZTkxNTg4MjRkZWJkM2I4OTQ1NTFkMGMyMzBlOGRkZjg0MjUxYTIwYmUyOGQ3ZDk0NWRhZTE4IiwiZWNjYmUxYzY0ZTJiYmQxZWY0Mzc0N2RkZTI3YzA4YzhlNDZjNWZiZWJlNGYzYzQzMDY2MDBkNzVhNmU2NjQyYyJdfSwiYmFzZWxpbmVSZXBvcnRCYXNlNjQiOiJleUptY205NlpXNUJkQ0k2T0RBMU9UY3pOakEzTENKclpYa2lPbnNpWVhKamFHbDBaV04wZFhKbElqb2lZWEp0TmpRaUxDSmlZWE5sYkdsdVpWWmxjbk5wYjI0aU9pSnROUzF3Y204dE1qQXlOaTB3TnkxMk5DSXNJbU5oY0dGaWFXeHBkSGxUWlhRaU9sc2lZM0IxVTJsdVoyeGxJaXdpWTNCMVRYVnNkR2tpTENKbmNIVWlMQ0p0WlcxdmNua2lMQ0prYVhOclVtVmhaQ0lzSW1ScGMydFhjbWwwWlNKZExDSndjbTltYVd4bElqb2ljM1JoYm1SaGNtUWlMQ0ozYjNKcmJHOWhaRlpsY25OcGIyNGlPaUp0WVdNdFltVnVZMmh0WVhKckxYTjBZVzVrWVhKa0xYWTBJbjBzSW5KbFptVnlaVzVqWlVoaGNtUjNZWEpsSWpvaVRXRmpRbTl2YXlCUWNtOGdUV0ZqTVRjc09TREN0eUJCY0hCc1pTQk5OU0JRY204Z3dyY2dNVGdnWTI5eVpYTWd3cmNnTkRnZ1IwSWlMQ0p5WldabGNtVnVZMlZOWlhSeWFXTnpJanBiZXlKamIyMXdiMjVsYm5RaU9pSmpjSFZUYVc1bmJHVWlMQ0oyWVd4MVpTSTZOREU1TGpFeE9UWTRNREV6TXpNd09UbDlMSHNpWTI5dGNHOXVaVzUwSWpvaVkzQjFUWFZzZEdraUxDSjJZV3gxWlNJNk5qa3dOaTR6TkRjek9EWTVPRGMzTXpoOUxIc2lZMjl0Y0c5dVpXNTBJam9pWjNCMUlpd2lkbUZzZFdVaU9qSTFNVE11TURRM09EWTNOalUwTmpRd05IMHNleUpqYjIxd2IyNWxiblFpT2lKdFpXMXZjbmtpTENKMllXeDFaU0k2TWpndU1UZzNPVGMyTlRVek5UazNNekl6ZlN4N0ltTnZiWEJ2Ym1WdWRDSTZJbVJwYzJ0U1pXRmtJaXdpZG1Gc2RXVWlPakF1TVRnMk1USXlNakl5TlRVMU1EQTNPRGg5TEhzaVkyOXRjRzl1Wlc1MElqb2laR2x6YTFkeWFYUmxJaXdpZG1Gc2RXVWlPakl1TURReU5qUTFNRGMyTnpJek9EWTRmVjBzSW5OamFHVnRZVlpsY25OcGIyNGlPakVzSW5OdmRYSmpaVkoxYmxOSVFUSTFObk1pT2xzaU1EVTJaamhrWW1RMFptWXhPV1JrTXpJeU9HVmpNVGhqWVdNMVpHUmxNVGRpT0RsaVptTXhZVEF6T0dVd00yVTBPRFpoTnpCaVpERXpPV00wT0RVMU9TSXNJakZtTjJGbU9HTTNOMlZqTkRJeE5qRmtNRFZtTkdSbFkyUTBabUV3TVdReU9EQXdOVGcxWVRabE56aGxOVEV6TjJNd01tSXpOR1JpT0RWbVpXRmhNV0VpTENJeU1XVXhZelJtWWpnME9EZzVPV1E1TkdZMk5qWmxZVFpoWldVME1EYzBaalF3TmpRek1qaGpOMll3Wm1Fd05HRXlNRFEyTlRJMFlqaGlOelF6WXpGaUlpd2lNakpsWkRjMVltVTFNR0UwT1RFeFlqazVaak0wWWpGa1pXUmpPV1UwWldNeE1EQTFOR016TkRRMk5XRm1aak14WVRReFl6STVOelF3TkdNNFpUaGhPQ0lzSWpVNVpqRmhZemMzWldOaE4yVXlNVGhoTXpabU9UWTBZV1l4T1Roa01UVTJNakJoTVRJeE1qY3lOREk1WWpJME5HWTRNVFJtTkRJMU9UQmpOek14TWpnaUxDSTJNR1E0T0dWaU56WTJNamhtTm1abE1UWTJNMlkxTW1GbVpXTXdNRGc1WVdReFpURm1OVGxsTUdJMk1ERm1ZbU5pT1dZek9HWTFNMll4TW1SalpUVXpJaXdpWkdVeU1HVTVNV1E0WVdVNU1UVTRPREkwWkdWaVpETmlPRGswTlRVeFpEQmpNak13WlRoa1pHWTROREkxTVdFeU1HSmxNamhrTjJRNU5EVmtZV1V4T0NJc0ltVmpZMkpsTVdNMk5HVXlZbUprTVdWbU5ETTNORGRrWkdVeU4yTXdPR000WlRRMll6Vm1ZbVZpWlRSbU0yTTBNekEyTmpBd1pEYzFZVFpsTmpZME1tTWlYWDA9IiwiYmFzZWxpbmVSZXBvcnRTSEEyNTYiOiI0M2EwZGY0OGM2OWU4ODI0YjA5NTcwZjk2NmY0NDk2YmE4YmIyYzc4YTEzNDIyMjE3ZjRhOWI3NjBjZDM4NTA2IiwiaGFyZHdhcmUiOnsiYWN0aXZlUHJvY2Vzc29yQ291bnQiOjE4LCJhcmNoaXRlY3R1cmUiOiJhcm02NCIsImNoaXBOYW1lIjoiQXBwbGUgTTUgUHJvIiwibW9kZWxJZGVudGlmaWVyIjoiTWFjMTcsOSIsInBoeXNpY2FsTWVtb3J5Qnl0ZXMiOjUxNTM5NjA3NTUyfSwiaGFybmVzc0lkZW50aWZpZXIiOiJzd2lmdHBtLXJlbGVhc2UteGN0ZXN0LnYxIiwiaW5kZXBlbmRlbnRTZXNzaW9uQ291bnQiOjIsIm1heGltdW1BbGxvd2VkQ29lZmZpY2llbnRPZlZhcmlhdGlvbiI6MC4wNSwibWF4aW11bUFsbG93ZWREdXJhYmxlV3JpdGVBZ2dyZWdhdGVDb2VmZmljaWVudE9mVmFyaWF0aW9uIjowLjEsIm1heGltdW1BbGxvd2VkR1BVQWdncmVnYXRlQ29lZmZpY2llbnRPZlZhcmlhdGlvbiI6MC4xLCJydW5zIjpbeyJjb21wbGV0ZWRBdCI6ODA1OTczNTcxLjUxODYyMiwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDMzNDUzMzcyMTU2NDYyNn0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAwMDMxODY1ODUyNjM0MTQxNTY0fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjowLjAwMTAwODUwNDY4MTI3NzQ0ODJ9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjAuMDAwMjUwMjMxMDU4OTkxMTc5MzZ9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMDg2MjQzODkxOTA4NTMwNzR9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDAzODg3Njk0MTg2NDY5MjEzfV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTkuMTM5NTQwODM5NzA2fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY5ODMuNDMzODAxMDk1MjkzfSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjoyNTEzLjU0OTM4Mzc0OTEwOH0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjguNDI2NTI4MTY2MzYwMjd9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4xODkzODMzMDU0MjQ2NjgwMn0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6Mi4wNzk4MjAxNTk5MTc4Mn1dLCJwcm9maWxlIjoic3RhbmRhcmQiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTIiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MTkxMCIsImFwcFZlcnNpb24iOiIxLjkuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiIwNTZmOGRiZDRmZjE5ZGQzMjI4ZWMxOGNhYzVkZGUxN2I4OWJmYzFhMDM4ZTAzZTQ4NmE3MGJkMTM5YzQ4NTU5Iiwic3RhcnRlZEF0Ijo4MDU5NzM1NDkuMTQ5Njk3LCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXN0YW5kYXJkLXY0In0seyJjb21wbGV0ZWRBdCI6ODA1OTcyMzI4LjI4ODAyNSwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDY4ODA5OTY3MzMzNTk1OX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAwMDM0NjQ0NDY4OTQ5MDgxNjN9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjAuMDAzMDkzOTg4NDExNjU0MDgwNH0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDM1ODM3MDMyMTYwNDY3NzUyfSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDA2NzQ0MzIyNzc2NTYwNzh9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDAyNjM2OTQ2OTE0ODczMzE3fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MjAuMDQ5NTYyNDM1NDY0N30seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2NzM0LjcxNTkyOTcyODUwOX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MjQ5NS45MDU4OTk1MDY4MTd9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI3LjYwODc5ODIxNjM5NTkxNX0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE4NTE2MzM1ODQ1MTIwNzY1fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoyLjA1NzI3NDIzMDI3NjYwMTR9XSwicHJvZmlsZSI6InN0YW5kYXJkIiwic2Vzc2lvbkxhYmVsIjoic2Vzc2lvbi0xIiwic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzE5MTAiLCJhcHBWZXJzaW9uIjoiMS45LjAifSwic291cmNlUnVuU0hBMjU2IjoiMWY3YWY4Yzc3ZWM0MjE2MWQwNWY0ZGVjZDRmYTAxZDI4MDA1ODVhNmU3OGU1MTM3YzAyYjM0ZGI4NWZlYWExYSIsInN0YXJ0ZWRBdCI6ODA1OTcyMzA1LjczODg5Mywid29ya2xvYWRWZXJzaW9uIjoibWFjLWJlbmNobWFyay1zdGFuZGFyZC12NCJ9LHsiY29tcGxldGVkQXQiOjgwNTk3MzUyNi43MDIyMiwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMzUyNzM5OTM0NTI5MDc1OX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAwMjQ1NzQ5Njk0NzM3MTY4Mn0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MC4wMDAxOTg2MTY1MDAyMzk2MjY2NH0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDA5OTAwMDk1ODU3MTY0NjE3fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDAyMTM1MzQ3NzA0ODQyNDM5N30seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDEwNjQxMDM5ODI1ODQ2MTEyfV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MzMuOTE0NzMwMTA1NjAyODd9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6Njk1MS4yNjA1MTQ5Mzk1Mzk1fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjoyNTE0LjkyMTYyMDI4MTE0ODV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI4LjQ5MjM0OTkyODIyMzk0fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTg2NjUwMzc3ODI4ODIwMDJ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjIuMDgzODQxNzM3NjYwOTIxN31dLCJwcm9maWxlIjoic3RhbmRhcmQiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTIiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MTkxMCIsImFwcFZlcnNpb24iOiIxLjkuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiIyMWUxYzRmYjg0ODg5OWQ5NGY2NjZlYTZhZWU0MDc0ZjQwNjQzMjhjN2YwZmEwNGEyMDQ2NTI0YjhiNzQzYzFiIiwic3RhcnRlZEF0Ijo4MDU5NzM1MDQuMTMwMDA3LCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXN0YW5kYXJkLXY0In0seyJjb21wbGV0ZWRBdCI6ODA1OTcyMzA1LjczODEzOCwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDUxODAwMzU3NTU5NzgxMjN9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDM3MjA5NzExMDAxOTk1MTQ1fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjowLjAwMDM1MzgxMDU3NDgzNDQxMX0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDAyMzY1OTY0ODU3MDA3NjA0fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDEzMDQ5NjM4NDk5NTM4MjkxfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjAwNTQ4NTU4NjY0Mzk4NTQ1Mn1dLCJjb21wb25lbnRNZWRpYW5zIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6NDE3LjMxMjgzMTM5MTQ4ODN9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6Njg0Ni4yMDA0MTM5MzQxOTh9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjI1MTkuNjQ5MzczMTk0NDE5N30seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjguMTEyMjgzMjIxMDM3MTI0fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTgyMzA4NTUxMjQ4Mjk1fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoyLjA5MTc2NDYyNzUxODAwNX1dLCJwcm9maWxlIjoic3RhbmRhcmQiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTEiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MTkxMCIsImFwcFZlcnNpb24iOiIxLjkuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiIyMmVkNzViZTUwYTQ5MTFiOTlmMzRiMWRlZGM5ZTRlYzEwMDU0YzM0NDY1YWZmMzFhNDFjMjk3NDA0YzhlOGE4Iiwic3RhcnRlZEF0Ijo4MDU5NzIyODMuMzA3NzM0LCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXN0YW5kYXJkLXY0In0seyJjb21wbGV0ZWRBdCI6ODA1OTcyMjgzLjMwNjMzNSwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDg4NDE0MTMwOTQ1NTA5MDl9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDQ0ODcxNDY4Nzk4OTY5NDR9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjAuMDA0NzQ4MzAwNzIxOTU0MTY3fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMDM1ODM4ODgyNzczNDE5MDh9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMDE4NTY5OTgwOTc0MjU1MDk4fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjAwNTIyMDg1MjQ3MTk2MDAzMjV9XSwiY29tcG9uZW50TWVkaWFucyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQxOC4zODI1MzYyNTI3MTZ9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6Njg2MS40MzQyNTkwMzU5Mzd9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjI0OTcuMDA2NTYyMTgwNzh9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI4LjI2MzY2OTg4NjE1NzUyM30seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE4NjAyNTk3MzE0ODQ3MzF9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjIuMDIzMjM0MTUxODc4MjA2fV0sInByb2ZpbGUiOiJzdGFuZGFyZCIsInNlc3Npb25MYWJlbCI6InNlc3Npb24tMSIsInNvdXJjZUJ1aWxkIjp7ImFwcEJ1aWxkIjoiMjAyNjA3MTcxOTEwIiwiYXBwVmVyc2lvbiI6IjEuOS4wIn0sInNvdXJjZVJ1blNIQTI1NiI6IjU5ZjFhYzc3ZWNhN2UyMThhMzZmOTY0YWYxOThkMTU2MjBhMTIxMjcyNDI5YjI0NGY4MTRmNDI1OTBjNzMxMjgiLCJzdGFydGVkQXQiOjgwNTk3MjI2MC43MDM1NDEsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstc3RhbmRhcmQtdjQifSx7ImNvbXBsZXRlZEF0Ijo4MDU5NzIzNTEuMjI0NDY5LCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDAxMzM4Mjc3ODQ3ODMyMTUxOH0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjowLjAwMTM4MzE3MDg1ODYwNTg4NjR9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjAuMDAxMzU1ODc3MjE2NzQ2MTYzMn0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDg2OTE0NDU4NzU3ODczNDZ9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMDEyNzA3Njc1NzU1Njk0Mjc1fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjAwNDA5ODQ4Nzg5NDgxOTEzMjV9XSwiY29tcG9uZW50TWVkaWFucyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQxOC42ODkwMTI3Mzg5NDAzfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY3MjEuNzY5NTc0MDQ2NTU5fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjoyNTA3LjEzMzA2MTkyMjUyN30seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjcuMzQ5NzY1NTQ0Mjg2NX0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE4MTk1MTUyMzc0OTg5OTg3fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoyLjAwMDg1MDAxMDQxNTQ5NH1dLCJwcm9maWxlIjoic3RhbmRhcmQiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTEiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MTkxMCIsImFwcFZlcnNpb24iOiIxLjkuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiI2MGQ4OGViNzY2MjhmNmZlMTY2M2Y1MmFmZWMwMDg5YWQxZTFmNTllMGI2MDFmYmNiOWYzOGY1M2YxMmRjZTUzIiwic3RhcnRlZEF0Ijo4MDU5NzIzMjguMjg4NzkzLCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXN0YW5kYXJkLXY0In0seyJjb21wbGV0ZWRBdCI6ODA1OTczNTkzLjk3NDg5MSwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDM2OTc2MDMxNzIzMjc0MjF9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDA0NzQ1NzQwNDQ2NTgyNzIyN30seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MC4wMDA4NDY2NDg1MTU4MzUwMzMxfSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwNzEyMTY3MTExNzgzNTU2Mn0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwMDI3NDgwNzcwNjcyNDUwMDJ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDA0Mjc1ODkwOTA3NDEwOTA4fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTkuMDk5ODE5NDI2OTEzN30seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2OTcxLjQxNDY1MDI2Mjg5NH0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MjUxMy4yODc2NjYwMjcyfSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjoyNy40NTk4NzQ0MTQ5MDQ0Mn0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE4NjIxODQ3MTk2MTU0MjYyfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoyLjAyODAxNTkyMzE3MTEzNDV9XSwicHJvZmlsZSI6InN0YW5kYXJkIiwic2Vzc2lvbkxhYmVsIjoic2Vzc2lvbi0yIiwic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzE5MTAiLCJhcHBWZXJzaW9uIjoiMS45LjAifSwic291cmNlUnVuU0hBMjU2IjoiZGUyMGU5MWQ4YWU5MTU4ODI0ZGViZDNiODk0NTUxZDBjMjMwZThkZGY4NDI1MWEyMGJlMjhkN2Q5NDVkYWUxOCIsInN0YXJ0ZWRBdCI6ODA1OTczNTcxLjUxOTMyOSwid29ya2xvYWRWZXJzaW9uIjoibWFjLWJlbmNobWFyay1zdGFuZGFyZC12NCJ9LHsiY29tcGxldGVkQXQiOjgwNTk3MzU0OS4xNDg5NDksImNvbXBvbmVudENvZWZmaWNpZW50c09mVmFyaWF0aW9uIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6MC4wMDA3MjU3NTQxNTgyMDY1MjEzfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDAwNjI5ODM0NTAyNjg2MzY1fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjowLjAwMjY0NTc4NzAwNjkwNDU5NH0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDEzMzQ1ODA4ODI5MDIzMzk1fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDAyMDI5MjI1MjY1ODk5MjM2fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjA0Njk0OTMzNzQ0Njc2MDc3fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MjEuNDU5MjI1MTIzODU4NzR9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6Njk3NC4wOTc0MTU5MDIwNDI1fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjoyNTEyLjgwODA2OTI4MjA4MX0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjguNTI1OTg0Mzg3NTIyNDE3fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTg2NTg2MzQwOTg1Mzg1ODJ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjEuNzM0MTI4NjQyODQyOTM3OX1dLCJwcm9maWxlIjoic3RhbmRhcmQiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTIiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MTkxMCIsImFwcFZlcnNpb24iOiIxLjkuMCJ9LCJzb3VyY2VSdW5TSEEyNTYiOiJlY2NiZTFjNjRlMmJiZDFlZjQzNzQ3ZGRlMjdjMDhjOGU0NmM1ZmJlYmU0ZjNjNDMwNjYwMGQ3NWE2ZTY2NDJjIiwic3RhcnRlZEF0Ijo4MDU5NzM1MjYuNzAzMzkxLCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXN0YW5kYXJkLXY0In1dLCJzY2hlbWFWZXJzaW9uIjozLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MTkxMCIsImFwcFZlcnNpb24iOiIxLjkuMCJ9LCJ2YWxpZFJ1bkNvdW50Ijo4fQ==",
            documentSHA256: "220a7c0c88ccbe0ebae22d91d92c4cf260b355301df8452873bdadce2b145ed7"
        )
    ]

    // Frozen from 8 canonical Release runs of the single Standard v6 workload
    // across two independently cooled sessions on the documented M5 Pro.
    private static let frozenDocuments: [FrozenMacBenchmarkCalibrationDocument] = [
            FrozenMacBenchmarkCalibrationDocument(
                profile: .standard,
                documentBase64: "eyJhZ2dyZWdhdGVDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDI3MTMwNjcxODkwNjkwMjE1fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDEzMjQzODgzMDYzNzEwNjkzfSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjowLjA2NzAyNDk4OTgyMTI5NDczfSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjA0NTAwODE0MDM3MTYxNTM0NX0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAxOTgwNzk3NjQ0MDM1MzAyNn0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMTgwOTQyODkzNTI1MjgxNjZ9XSwiYmFzZWxpbmVSZXBvcnQiOnsiZnJvemVuQXQiOjgwNTk5MzYwMCwia2V5Ijp7ImFyY2hpdGVjdHVyZSI6ImFybTY0IiwiYmFzZWxpbmVWZXJzaW9uIjoibTUtcHJvLTIwMjYtMDctdjYiLCJjYXBhYmlsaXR5U2V0IjpbImNwdVNpbmdsZSIsImNwdU11bHRpIiwiZ3B1IiwibWVtb3J5IiwiZGlza1JlYWQiLCJkaXNrV3JpdGUiXSwicHJvZmlsZSI6InN0YW5kYXJkIiwid29ya2xvYWRWZXJzaW9uIjoibWFjLWJlbmNobWFyay1zdGFuZGFyZC12NiJ9LCJyZWZlcmVuY2VIYXJkd2FyZSI6Ik1hY0Jvb2sgUHJvIE1hYzE3LDkgwrcgQXBwbGUgTTUgUHJvIMK3IDE4IGNvcmVzIMK3IDQ4IEdCIiwicmVmZXJlbmNlTWV0cmljcyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQyMC41NzMwNTE1MDQzNX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2OTQ2Ljk2NDg1ODI1Mzc3OX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MzA3OC4zMTczMzk1OTQxNjh9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI5Ljk4OTE3MjgyMTM1MzI1NH0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE5Nzk2NzIzOTg4Mzk0ODd9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjIuMDI5OTE1Mzg2OTgwNTE1fV0sInNjaGVtYVZlcnNpb24iOjEsInNvdXJjZVJ1blNIQTI1NnMiOlsiMTk2NjE0Yzc0NzQ4ZDhkM2RhN2ViNzRjMzlkMzVhN2RkY2Q4ZTQ3NTE0MDUwMDUxZjE1ZmZlODdlMWI3N2I0NCIsIjJiYWQ3MjUwZGNiMzdlYTJlYWUzODBkNDFkZjRiOTcxMTBhZTQwYWNiMTBiNTQ4OWIwZWNjMjcxNWJiMTIzZmUiLCI0N2ZjY2VjZGRmZjA5YzY0ODZhODhmMjIwN2ViY2VjYjNhYWFhMTEwZDQ3ODNhMDVlOGY5ZWVmNDgxOTQ4NDA2IiwiNTM3YWM3M2I1NDk3NTc0ZDQ0MTk1OWZlY2Y0MjE2NDRmOGFlYjNhYjZjNjBjMDFmZjJmN2RiOTZhMGQwNDEyYyIsIjk2MzcxZTZiM2Y4Y2FlNzA1ZmJkNzA5ZDRiNmUzMmY3MDE2YWYwYjk1N2MxZDU3ZGEyMjg3MTc2NDUzZDYzMWQiLCJhOTgwY2Y2NDBhMzY3MTQyYzFjMzE3ZDE4NzZiMWEzOGZlNjdlZThmNmI5ODgxYWFlNTE4YTkwNWFjODRlZjU5IiwiYzA4Zjc2MjEzOTM3NWM3OWZkOGY2NmVjZmFiZjg3NGJhYjNhYTEwMjhiZjhhY2FiYTRhMDIzYzAyZGE4YzQxNyIsImY1MmJlZDYzZDY2MGU5NjE4YTI2NzE2MmI3YjdiNTNhZDE1NzNkYWI2YjhhNzNiMDk4YzE2NzI1ODU3NGViOGYiXX0sImJhc2VsaW5lUmVwb3J0QmFzZTY0IjoiZXlKbWNtOTZaVzVCZENJNk9EQTFPVGt6TmpBd0xDSnJaWGtpT25zaVlYSmphR2wwWldOMGRYSmxJam9pWVhKdE5qUWlMQ0ppWVhObGJHbHVaVlpsY25OcGIyNGlPaUp0TlMxd2NtOHRNakF5Tmkwd055MTJOaUlzSW1OaGNHRmlhV3hwZEhsVFpYUWlPbHNpWTNCMVUybHVaMnhsSWl3aVkzQjFUWFZzZEdraUxDSm5jSFVpTENKdFpXMXZjbmtpTENKa2FYTnJVbVZoWkNJc0ltUnBjMnRYY21sMFpTSmRMQ0p3Y205bWFXeGxJam9pYzNSaGJtUmhjbVFpTENKM2IzSnJiRzloWkZabGNuTnBiMjRpT2lKdFlXTXRZbVZ1WTJodFlYSnJMWE4wWVc1a1lYSmtMWFkySW4wc0luSmxabVZ5Wlc1alpVaGhjbVIzWVhKbElqb2lUV0ZqUW05dmF5QlFjbThnVFdGak1UY3NPU0RDdHlCQmNIQnNaU0JOTlNCUWNtOGd3cmNnTVRnZ1kyOXlaWE1nd3JjZ05EZ2dSMElpTENKeVpXWmxjbVZ1WTJWTlpYUnlhV056SWpwYmV5SmpiMjF3YjI1bGJuUWlPaUpqY0hWVGFXNW5iR1VpTENKMllXeDFaU0k2TkRJd0xqVTNNekExTVRVd05ETTFmU3g3SW1OdmJYQnZibVZ1ZENJNkltTndkVTExYkhScElpd2lkbUZzZFdVaU9qWTVORFl1T1RZME9EVTRNalV6TnpjNWZTeDdJbU52YlhCdmJtVnVkQ0k2SW1kd2RTSXNJblpoYkhWbElqb3pNRGM0TGpNeE56TXpPVFU1TkRFMk9IMHNleUpqYjIxd2IyNWxiblFpT2lKdFpXMXZjbmtpTENKMllXeDFaU0k2TWprdU9UZzVNVGN5T0RJeE16VXpNalUwZlN4N0ltTnZiWEJ2Ym1WdWRDSTZJbVJwYzJ0U1pXRmtJaXdpZG1Gc2RXVWlPakF1TVRrM09UWTNNak01T0Rnek9UUTROMzBzZXlKamIyMXdiMjVsYm5RaU9pSmthWE5yVjNKcGRHVWlMQ0oyWVd4MVpTSTZNaTR3TWprNU1UVXpPRFk1T0RBMU1UVjlYU3dpYzJOb1pXMWhWbVZ5YzJsdmJpSTZNU3dpYzI5MWNtTmxVblZ1VTBoQk1qVTJjeUk2V3lJeE9UWTJNVFJqTnpRM05EaGtPR1F6WkdFM1pXSTNOR016T1dRek5XRTNaR1JqWkRobE5EYzFNVFF3TlRBd05URm1NVFZtWm1VNE4yVXhZamMzWWpRMElpd2lNbUpoWkRjeU5UQmtZMkl6TjJWaE1tVmhaVE00TUdRME1XUm1OR0k1TnpFeE1HRmxOREJoWTJJeE1HSTFORGc1WWpCbFkyTXlOekUxWW1JeE1qTm1aU0lzSWpRM1ptTmpaV05rWkdabU1EbGpOalE0Tm1FNE9HWXlNakEzWldKalpXTmlNMkZoWVdFeE1UQmtORGM0TTJFd05XVTRaamxsWldZME9ERTVORGcwTURZaUxDSTFNemRoWXpjellqVTBPVGMxTnpSa05EUXhPVFU1Wm1WalpqUXlNVFkwTkdZNFlXVmlNMkZpTm1NMk1HTXdNV1ptTW1ZM1pHSTVObUV3WkRBME1USmpJaXdpT1RZek56RmxObUl6WmpoallXVTNNRFZtWW1RM01EbGtOR0kyWlRNeVpqY3dNVFpoWmpCaU9UVTNZekZrTlRka1lUSXlPRGN4TnpZME5UTmtOak14WkNJc0ltRTVPREJqWmpZME1HRXpOamN4TkRKak1XTXpNVGRrTVRnM05tSXhZVE00Wm1VMk4yVmxPR1kyWWprNE9ERmhZV1UxTVRoaE9UQTFZV000TkdWbU5Ua2lMQ0pqTURobU56WXlNVE01TXpjMVl6YzVabVE0WmpZMlpXTm1ZV0ptT0RjMFltRmlNMkZoTVRBeU9HSm1PR0ZqWVdKaE5HRXdNak5qTURKa1lUaGpOREUzSWl3aVpqVXlZbVZrTmpOa05qWXdaVGsyTVRoaE1qWTNNVFl5WWpkaU4ySTFNMkZrTVRVM00yUmhZalppT0dFM00ySXdPVGhqTVRZM01qVTROVGMwWldJNFppSmRmUT09IiwiYmFzZWxpbmVSZXBvcnRTSEEyNTYiOiJlNWZlZGRmN2YxNzg5NTliNTgxZGU0NWVkMDM3NWZkNTExYzgxNGEzMDk2N2Y5Y2UwYThmOWQyZDVlYTE2NmY4IiwiaGFyZHdhcmUiOnsiYWN0aXZlUHJvY2Vzc29yQ291bnQiOjE4LCJhcmNoaXRlY3R1cmUiOiJhcm02NCIsImNoaXBOYW1lIjoiQXBwbGUgTTUgUHJvIiwibW9kZWxJZGVudGlmaWVyIjoiTWFjMTcsOSIsInBoeXNpY2FsTWVtb3J5Qnl0ZXMiOjUxNTM5NjA3NTUyfSwiaGFybmVzc0lkZW50aWZpZXIiOiJzd2lmdHBtLXJlbGVhc2UteGN0ZXN0LnYxIiwiaW5kZXBlbmRlbnRTZXNzaW9uQ291bnQiOjIsIm1heGltdW1BbGxvd2VkQ29lZmZpY2llbnRPZlZhcmlhdGlvbiI6MC4wNSwibWF4aW11bUFsbG93ZWREdXJhYmxlV3JpdGVBZ2dyZWdhdGVDb2VmZmljaWVudE9mVmFyaWF0aW9uIjowLjEsIm1heGltdW1BbGxvd2VkR1BVQWdncmVnYXRlQ29lZmZpY2llbnRPZlZhcmlhdGlvbiI6MC4xLCJydW5zIjpbeyJjb21wbGV0ZWRBdCI6ODA1OTkzNTc0LjIxNzg3OCwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDI3ODg0NTczNTg5MjE3MzQzfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDAzMzEzNjMzNDMwODQyNDU0fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjoyLjkwMzE3ODcwODU4Mjc5NDRlLTA1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMjkzNjU0OTI5MTQwMjk0OX0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwMDE4NDU2NTQ3NjU2NzEzNTQyfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjAwMDg5NTIyOTI4NTk3NDYwNDZ9XSwiY29tcG9uZW50TWVkaWFucyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQyMy42OTQzNzM0MzA1MjEzfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY5MzYuMzQyNDgxOTEwMDQ0fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMDc5LjEyMDAwNTY0MjAyNTd9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI5LjA2MjMwOTEwMjA1ODU5NX0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE5Nzk5MzIyNzUxOTc4MzgyfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoyLjA5NzU1ODk0MjgyMjA4N31dLCJwcm9maWxlIjoic3RhbmRhcmQiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTIiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MjAxNiIsImFwcFZlcnNpb24iOiIxLjguMiJ9LCJzb3VyY2VSdW5TSEEyNTYiOiIxOTY2MTRjNzQ3NDhkOGQzZGE3ZWI3NGMzOWQzNWE3ZGRjZDhlNDc1MTQwNTAwNTFmMTVmZmU4N2UxYjc3YjQ0Iiwic3RhcnRlZEF0Ijo4MDU5OTM1NDkuMzEwMDM2LCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXN0YW5kYXJkLXY2In0seyJjb21wbGV0ZWRBdCI6ODA1OTkzNTI0Ljc0ODk4LCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjUuMDI5ODY0NTcxMDU2NTcyNGUtMDV9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDI3NzI5NDczNTg5OTEzOTQ4fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozLjMyMjExNTczNjc1MDU2NTZlLTA1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMDUyODMyMjg5MjU2MjIzMDZ9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMDM1NzMxNDgyNTg5ODUyNTI1fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjAwMTYwMDQ2MDg2NjU2NDA2Nn1dLCJjb21wb25lbnRNZWRpYW5zIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6NDM5LjM4NzkyMzQ2ODY5MzAzfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY5NTcuNTg3MjM0NTk3NTE2fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMDc5LjgxOTIyNjk3NTMzMzV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjMwLjQxMzk5ODU0MzAyMDI4OH0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE5OTcxNDk5MTgyMzU1MTEyfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoyLjAwOTEyNzc0OTcxMDgzN31dLCJwcm9maWxlIjoic3RhbmRhcmQiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTIiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MjAxNiIsImFwcFZlcnNpb24iOiIxLjguMiJ9LCJzb3VyY2VSdW5TSEEyNTYiOiIyYmFkNzI1MGRjYjM3ZWEyZWFlMzgwZDQxZGY0Yjk3MTEwYWU0MGFjYjEwYjU0ODliMGVjYzI3MTViYjEyM2ZlIiwic3RhcnRlZEF0Ijo4MDU5OTM0OTkuOTIxODI0LCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXN0YW5kYXJkLXY2In0seyJjb21wbGV0ZWRBdCI6ODA1OTkyODc1LjY2NDY1MiwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDIxNjIxMzE0OTkwNzAxNDg1fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDA4NzEzNzUyNDQzMTI3MjMzfSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjowLjAwMDIxMDE3Njc2ODUyOTEzMzI1fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMTQ1MTQzNzkxOTY2MzY1ODJ9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMTQxNzM3OTgxNzUxOTUwMzN9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDA2MTM2OTMxMTA4ODc1NzYyfV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTUuMDgxNTExMDkxMjY5OH0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2ODY5LjA3NTY1MDEyOTI0NH0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MzA3Ni42MDI1MTAxOTE2MzJ9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjMwLjAyNTI4NDk0OTg3MTk5Mn0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE5Nzk0MTI1MjI0ODExMzZ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjIuMDI2NzUzMzI0OTUwMjQ2NX1dLCJwcm9maWxlIjoic3RhbmRhcmQiLCJzZXNzaW9uTGFiZWwiOiJzZXNzaW9uLTEiLCJzb3VyY2VCdWlsZCI6eyJhcHBCdWlsZCI6IjIwMjYwNzE3MjAxNiIsImFwcFZlcnNpb24iOiIxLjguMiJ9LCJzb3VyY2VSdW5TSEEyNTYiOiI0N2ZjY2VjZGRmZjA5YzY0ODZhODhmMjIwN2ViY2VjYjNhYWFhMTEwZDQ3ODNhMDVlOGY5ZWVmNDgxOTQ4NDA2Iiwic3RhcnRlZEF0Ijo4MDU5OTI4NTAuOTExNzcyLCJ3b3JrbG9hZFZlcnNpb24iOiJtYWMtYmVuY2htYXJrLXN0YW5kYXJkLXY2In0seyJjb21wbGV0ZWRBdCI6ODA1OTkyODUwLjkxMDg4NiwiY29tcG9uZW50Q29lZmZpY2llbnRzT2ZWYXJpYXRpb24iOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjowLjAwMDE3NzM0OTc2NDkyMDMxMjJ9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDE3NDUyODk0NDY2MDg1OTc5fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjowLjAwMDE5MDE2NTk1Mzc0NzcwMDI2fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwOTUxNTk3MzU2NjQyMzkyN30seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwMDQxNjcyMjc1OTI4MjY5MjJ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjAuMDAxMDQyODc3Nzk4NzQ0NzE4fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MTYuODg2NTg1MTk2Nzc5NX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2OTc3LjA3Njk0MDg5Njk4MX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MzA3Ny40OTQxODM2MTQzNTY2fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjoyOS4yMjQwNjA5NTI5NTA4MzN9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4xOTMwNjQxNzUzNjY0OTMyNn0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6Mi4wMjk2NDc3MjQzNDMzNDQ2fV0sInByb2ZpbGUiOiJzdGFuZGFyZCIsInNlc3Npb25MYWJlbCI6InNlc3Npb24tMSIsInNvdXJjZUJ1aWxkIjp7ImFwcEJ1aWxkIjoiMjAyNjA3MTcyMDE2IiwiYXBwVmVyc2lvbiI6IjEuOC4yIn0sInNvdXJjZVJ1blNIQTI1NiI6IjUzN2FjNzNiNTQ5NzU3NGQ0NDE5NTlmZWNmNDIxNjQ0ZjhhZWIzYWI2YzYwYzAxZmYyZjdkYjk2YTBkMDQxMmMiLCJzdGFydGVkQXQiOjgwNTk5MjgyNS43OTg3ODUsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstc3RhbmRhcmQtdjYifSx7ImNvbXBsZXRlZEF0Ijo4MDU5OTI1MzEuNDM2MDg3LCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDAwNzY1MTE5MDE5MDg4NjY2fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDEyOTI2MjAyODE3NjY2MTAxfSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjowLjAwMDg5MzI4Njk4OTY1Mzc3NjV9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjAuMDAyNTkwMzcyMjU1NTk2Mjc2NH0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjAwNTAzODMzNzE1MTI4MjQ0NH0seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDA4MzE5OTA3ODAwNTU0NDgxfV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MDguMDcxMTY2NDg5MjR9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6NjcxNy4zNTk4NTUzMTEyNzl9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjI1MDguNjM2NDMzNDQ2NzM3Nn0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MjYuMzEwMzA5NjIxNzEzNjc0fSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMTg4OTQ2NzE0NzI5Mzk0MjZ9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjIuMDMwMTgzMDQ5NjE3Njg1fV0sInByb2ZpbGUiOiJzdGFuZGFyZCIsInNlc3Npb25MYWJlbCI6InNlc3Npb24tMSIsInNvdXJjZUJ1aWxkIjp7ImFwcEJ1aWxkIjoiMjAyNjA3MTcyMDE2IiwiYXBwVmVyc2lvbiI6IjEuOC4yIn0sInNvdXJjZVJ1blNIQTI1NiI6Ijk2MzcxZTZiM2Y4Y2FlNzA1ZmJkNzA5ZDRiNmUzMmY3MDE2YWYwYjk1N2MxZDU3ZGEyMjg3MTc2NDUzZDYzMWQiLCJzdGFydGVkQXQiOjgwNTk5MjUwNS4xMzYzNTQsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstc3RhbmRhcmQtdjYifSx7ImNvbXBsZXRlZEF0Ijo4MDU5OTM1NDkuMzA5MDgxLCJjb21wb25lbnRDb2VmZmljaWVudHNPZlZhcmlhdGlvbiI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjAuMDAwMzUwODk5Nzk0NTQ2ODkxNjZ9LHsiY29tcG9uZW50IjoiY3B1TXVsdGkiLCJ2YWx1ZSI6MC4wMDMyMDc0MTEwNzYyMzkyODJ9LHsiY29tcG9uZW50IjoiZ3B1IiwidmFsdWUiOjAuMDAwMjMxMDQ1MDQzOTQyMjYyMX0seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDE1MDEwMzM1NDI5NTgzNTQyfSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDAzODg3NTQxMjA4NjQxNzI5M30seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6Ny41NjU2OTA5MTYzMzk0NGUtMDV9XSwiY29tcG9uZW50TWVkaWFucyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQzOS4wMTQ5MzczNjg5MTcyfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY5MTkuMDQ0MDQ0NzE1NDM1fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMDgxLjE0MjU0NDk0ODIyNjd9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjMwLjA0NzA4NjY2ODg0MjgzNH0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE5ODY3MzMwMzc2OTk0MzM1fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoyLjA5NTMzMDg2MjgyNDMwMzN9XSwicHJvZmlsZSI6InN0YW5kYXJkIiwic2Vzc2lvbkxhYmVsIjoic2Vzc2lvbi0yIiwic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzIwMTYiLCJhcHBWZXJzaW9uIjoiMS44LjIifSwic291cmNlUnVuU0hBMjU2IjoiYTk4MGNmNjQwYTM2NzE0MmMxYzMxN2QxODc2YjFhMzhmZTY3ZWU4ZjZiOTg4MWFhZTUxOGE5MDVhYzg0ZWY1OSIsInN0YXJ0ZWRBdCI6ODA1OTkzNTI0Ljc1MDMwMSwid29ya2xvYWRWZXJzaW9uIjoibWFjLWJlbmNobWFyay1zdGFuZGFyZC12NiJ9LHsiY29tcGxldGVkQXQiOjgwNTk5MjgyNS43OTczMDUsImNvbXBvbmVudENvZWZmaWNpZW50c09mVmFyaWF0aW9uIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6MC4wMDE5OTE2MTIyOTMwMzgzMjgyfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDAwNTc5NzY2NTg3NzY5NjE1OH0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MC4wMDAxMzE3ODU1NDQ4NzcyOTI5M30seyJjb21wb25lbnQiOiJtZW1vcnkiLCJ2YWx1ZSI6MC4wMDA4MTcwMTM4NTAwNjg0NTMyfSx7ImNvbXBvbmVudCI6ImRpc2tSZWFkIiwidmFsdWUiOjAuMDAyMjQ0MjA0OTk1NDE0Mzk0N30seyJjb21wb25lbnQiOiJkaXNrV3JpdGUiLCJ2YWx1ZSI6MC4wMDI1ODU5OTE1NzY2OTc0NDA0fV0sImNvbXBvbmVudE1lZGlhbnMiOlt7ImNvbXBvbmVudCI6ImNwdVNpbmdsZSIsInZhbHVlIjo0MzAuMDUyMTMyNjIxODA2MX0seyJjb21wb25lbnQiOiJjcHVNdWx0aSIsInZhbHVlIjo2OTk4LjQ5NjY4NDc0NjI5NX0seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MzA3Ny41MTQ2NzM1NDYzMTA0fSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjozMC4wNDA5OTIwMDQ2MTQ3OH0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjIwMDY4NTc3MDk3NjEyMTUzfSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjoyLjAyMDcyNjE5MzU2NzY5MzJ9XSwicHJvZmlsZSI6InN0YW5kYXJkIiwic2Vzc2lvbkxhYmVsIjoic2Vzc2lvbi0xIiwic291cmNlQnVpbGQiOnsiYXBwQnVpbGQiOiIyMDI2MDcxNzIwMTYiLCJhcHBWZXJzaW9uIjoiMS44LjIifSwic291cmNlUnVuU0hBMjU2IjoiYzA4Zjc2MjEzOTM3NWM3OWZkOGY2NmVjZmFiZjg3NGJhYjNhYTEwMjhiZjhhY2FiYTRhMDIzYzAyZGE4YzQxNyIsInN0YXJ0ZWRBdCI6ODA1OTkyODAwLjk1NzA2Mywid29ya2xvYWRWZXJzaW9uIjoibWFjLWJlbmNobWFyay1zdGFuZGFyZC12NiJ9LHsiY29tcGxldGVkQXQiOjgwNTk5MzU5OS4xMzM5OTYsImNvbXBvbmVudENvZWZmaWNpZW50c09mVmFyaWF0aW9uIjpbeyJjb21wb25lbnQiOiJjcHVTaW5nbGUiLCJ2YWx1ZSI6MC4wMDAxNDczMjA5MTU4ODY0NzYzfSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjAuMDAyNjQxMTc5Nzc2OTg1NjQ0N30seyJjb21wb25lbnQiOiJncHUiLCJ2YWx1ZSI6MC4wMDAyNjczNDA3NTQ4ODg0MDcxfSx7ImNvbXBvbmVudCI6Im1lbW9yeSIsInZhbHVlIjowLjAwMDI5MTI4NDQ5Mzc4MDY0NTh9LHsiY29tcG9uZW50IjoiZGlza1JlYWQiLCJ2YWx1ZSI6MC4wMDM3MjUwNzY3Njc3NDI5ODA2fSx7ImNvbXBvbmVudCI6ImRpc2tXcml0ZSIsInZhbHVlIjowLjAwMjQ0NDgxNzE2ODQxMjc0NTd9XSwiY29tcG9uZW50TWVkaWFucyI6W3siY29tcG9uZW50IjoiY3B1U2luZ2xlIiwidmFsdWUiOjQxNy40NTE3Mjk1NzgxNzg4fSx7ImNvbXBvbmVudCI6ImNwdU11bHRpIiwidmFsdWUiOjY5ODMuNTI2MDk0NjIwMDE3fSx7ImNvbXBvbmVudCI6ImdwdSIsInZhbHVlIjozMDc5LjY4OTYxNjY5NTQ0MDd9LHsiY29tcG9uZW50IjoibWVtb3J5IiwidmFsdWUiOjI5Ljk1MzA2MDY5MjgzNDUxNn0seyJjb21wb25lbnQiOiJkaXNrUmVhZCIsInZhbHVlIjowLjE5NTc5NTAxNTY5MTA3Mjh9LHsiY29tcG9uZW50IjoiZGlza1dyaXRlIiwidmFsdWUiOjIuMDg3OTE0NzM4OTU4MTcxfV0sInByb2ZpbGUiOiJzdGFuZGFyZCIsInNlc3Npb25MYWJlbCI6InNlc3Npb24tMiIsInNvdXJjZUJ1aWxkIjp7ImFwcEJ1aWxkIjoiMjAyNjA3MTcyMDE2IiwiYXBwVmVyc2lvbiI6IjEuOC4yIn0sInNvdXJjZVJ1blNIQTI1NiI6ImY1MmJlZDYzZDY2MGU5NjE4YTI2NzE2MmI3YjdiNTNhZDE1NzNkYWI2YjhhNzNiMDk4YzE2NzI1ODU3NGViOGYiLCJzdGFydGVkQXQiOjgwNTk5MzU3NC4yMTkzNjUsIndvcmtsb2FkVmVyc2lvbiI6Im1hYy1iZW5jaG1hcmstc3RhbmRhcmQtdjYifV0sInNjaGVtYVZlcnNpb24iOjMsInNvdXJjZUJ1aWxkIjp7ImFwcEJ1aWxkIjoiMjAyNjA3MTcyMDE2IiwiYXBwVmVyc2lvbiI6IjEuOC4yIn0sInZhbGlkUnVuQ291bnQiOjh9",
                documentSHA256: "86ca44383e3b8667e4529a7da449e353a3d6ac7e6778d876a64562b2a17f4861"
            )
    ]

    static func runtimeCatalog() -> MacBenchmarkBaselineCatalog {
        do {
            let verified = try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
                from: frozenDocuments,
                activeBaselineVersion: activeBaselineVersion,
                requireCompleteProfileSet: !frozenDocuments.isEmpty,
                requireCanonicalEncoding: false,
                requiredProfiles: BenchmarkProfile.allCases
            )
            return try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: activeBaselineVersion,
                verifiedBaselines: verified
            )
        } catch {
            return .rawOnly(activeBaselineVersion: activeBaselineVersion)
        }
    }

    /// Verified catalogs used only to audit and canonicalize persisted history.
    /// They must never be used to score a newly produced active workload.
    static func trustedHistoryResultProcessors() -> [MacBenchmarkResultProcessor] {
        [
            try? makeTrustedHistoryResultProcessor(
                frozenDocuments: legacyV3FrozenDocuments,
                baselineVersion: "m5-pro-2026-07-v3",
                requiredProfiles: BenchmarkProfile.legacyCases,
                expectedWorkloadVersions: [
                    .quick: "mac-benchmark-quick-v3",
                    .full: "mac-benchmark-full-v3",
                ]
            ),
            try? makeTrustedHistoryResultProcessor(
                frozenDocuments: legacyV4FrozenDocuments,
                baselineVersion: "m5-pro-2026-07-v4",
                requiredProfiles: [.standard],
                expectedWorkloadVersions: [
                    .standard: "mac-benchmark-standard-v4",
                ]
            ),
        ].compactMap { $0 }
    }

    private static func makeTrustedHistoryResultProcessor(
        frozenDocuments: [FrozenMacBenchmarkCalibrationDocument],
        baselineVersion: String,
        requiredProfiles: [BenchmarkProfile],
        expectedWorkloadVersions: [BenchmarkProfile: String]
    ) throws -> MacBenchmarkResultProcessor {
        let verified = try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
            from: frozenDocuments,
            activeBaselineVersion: baselineVersion,
            requireCompleteProfileSet: true,
            requireCanonicalEncoding: false,
            requiredProfiles: requiredProfiles,
            expectedWorkloadVersions: expectedWorkloadVersions
        )
        return MacBenchmarkResultProcessor(
            baselineCatalog: try MacBenchmarkBaselineCatalog(
                activeBaselineVersion: baselineVersion,
                verifiedBaselines: verified
            )
        )
    }

    static func validateForRelease(
        expectedSourceBuild: MacBenchmarkCalibrationSourceBuild
    ) throws -> MacBenchmarkBaselineCatalog {
        let verified = try MacBenchmarkFrozenCatalogLoader.verifiedBaselines(
            from: frozenDocuments,
            activeBaselineVersion: activeBaselineVersion,
            requireCompleteProfileSet: true,
            requireCanonicalEncoding: true,
            expectedSourceBuild: expectedSourceBuild,
            requiredProfiles: BenchmarkProfile.allCases
        )
        return try MacBenchmarkBaselineCatalog(
            activeBaselineVersion: activeBaselineVersion,
            verifiedBaselines: verified
        )
    }
}
