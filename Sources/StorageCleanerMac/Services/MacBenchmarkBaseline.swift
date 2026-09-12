import CryptoKit
import Foundation

enum MacBenchmarkBaselineError: Error, Equatable, Sendable {
    case invalidBaseline
    case emptyCalibrationReport
    case invalidCalibrationReport
    case calibrationReportMismatch
    case reportHashMismatch
}

/// Stable Codable representation for the six benchmark component values.
///
/// Swift encodes dictionaries whose keys are enums as alternating JSON arrays,
/// and dictionary iteration order is intentionally undefined. A frozen report
/// cannot be hashed reproducibly with that representation, so calibration
/// documents use this fixed component order instead.
struct MacBenchmarkComponentValues: Equatable, Sendable, Codable {
    private struct Entry: Equatable, Sendable, Codable {
        let component: BenchmarkComponent
        let value: Double
    }

    private let storage: [BenchmarkComponent: Double]

    init(_ values: [BenchmarkComponent: Double]) {
        storage = values
    }

    var count: Int { storage.count }
    var dictionary: [BenchmarkComponent: Double] { storage }

    subscript(component: BenchmarkComponent) -> Double? {
        storage[component]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let entries = try container.decode([Entry].self)
        guard Set(entries.map(\.component)).count == entries.count else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Duplicate benchmark component"
            )
        }
        storage = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.component, $0.value) }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let entries = BenchmarkComponent.allCases.compactMap { component in
            storage[component].map { Entry(component: component, value: $0) }
        }
        try container.encode(entries)
    }
}

struct MacBenchmarkCalibrationReport: Equatable, Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let key: BenchmarkComparisonKey
    let referenceMetrics: [BenchmarkComponent: Double]
    let referenceHardware: String
    let frozenAt: Date
    let sourceRunSHA256s: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case key
        case referenceMetrics
        case referenceHardware
        case frozenAt
        case sourceRunSHA256s
    }

    init(
        schemaVersion: Int,
        key: BenchmarkComparisonKey,
        referenceMetrics: [BenchmarkComponent: Double],
        referenceHardware: String,
        frozenAt: Date,
        sourceRunSHA256s: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.key = key
        self.referenceMetrics = referenceMetrics
        self.referenceHardware = referenceHardware
        self.frozenAt = frozenAt
        self.sourceRunSHA256s = sourceRunSHA256s
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        key = try container.decode(BenchmarkComparisonKey.self, forKey: .key)
        referenceMetrics = try container.decode(
            MacBenchmarkComponentValues.self,
            forKey: .referenceMetrics
        ).dictionary
        referenceHardware = try container.decode(
            String.self,
            forKey: .referenceHardware
        )
        frozenAt = try container.decode(Date.self, forKey: .frozenAt)
        sourceRunSHA256s = try container.decode(
            [String].self,
            forKey: .sourceRunSHA256s
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(key, forKey: .key)
        try container.encode(
            MacBenchmarkComponentValues(referenceMetrics),
            forKey: .referenceMetrics
        )
        try container.encode(referenceHardware, forKey: .referenceHardware)
        try container.encode(frozenAt, forKey: .frozenAt)
        try container.encode(sourceRunSHA256s, forKey: .sourceRunSHA256s)
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !key.workloadVersion.isEmpty
            && !key.baselineVersion.isEmpty
            && key.architecture != .unsupported
            && key.capabilitySet == .all
            && referenceMetrics.count == BenchmarkComponent.allCases.count
            && BenchmarkComponent.allCases.allSatisfy { component in
                guard let value = referenceMetrics[component] else { return false }
                return value.isFinite && value > 0
            }
            && !referenceHardware.isEmpty
            && frozenAt.timeIntervalSinceReferenceDate.isFinite
            && !sourceRunSHA256s.isEmpty
            && Set(sourceRunSHA256s.map { $0.lowercased() }).count
                == sourceRunSHA256s.count
            && sourceRunSHA256s.allSatisfy(
                MacBenchmarkBaselineVerification.isSHA256Hex
            )
    }
}

enum MacBenchmarkBaselineVerification {
    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...70).contains(byte)
                || (97...102).contains(byte)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        let hex = Array("0123456789abcdef".utf8)
        let digest = SHA256.hash(data: data)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(hex[Int(byte >> 4)])
            bytes.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct VerifiedMacBenchmarkBaseline: Equatable, Sendable {
    let baseline: MacBenchmarkBaseline

    init(
        baseline: MacBenchmarkBaseline,
        calibrationReport: Data
    ) throws {
        guard baseline.isValid,
              !baseline.comparisonKey.workloadVersion.isEmpty,
              !baseline.comparisonKey.baselineVersion.isEmpty,
              baseline.comparisonKey.architecture != .unsupported
        else {
            throw MacBenchmarkBaselineError.invalidBaseline
        }
        guard !calibrationReport.isEmpty else {
            throw MacBenchmarkBaselineError.emptyCalibrationReport
        }
        let report: MacBenchmarkCalibrationReport
        do {
            report = try JSONDecoder().decode(
                MacBenchmarkCalibrationReport.self,
                from: calibrationReport
            )
        } catch {
            throw MacBenchmarkBaselineError.invalidCalibrationReport
        }
        guard report.isValid else {
            throw MacBenchmarkBaselineError.invalidCalibrationReport
        }
        guard report.key == baseline.comparisonKey,
              report.referenceMetrics == baseline.referenceMetrics,
              report.referenceHardware == baseline.referenceHardware,
              report.frozenAt == baseline.frozenAt
        else {
            throw MacBenchmarkBaselineError.calibrationReportMismatch
        }
        let computedHash = MacBenchmarkBaselineVerification.sha256Hex(calibrationReport)
        guard computedHash.caseInsensitiveCompare(baseline.reportSHA256) == .orderedSame else {
            throw MacBenchmarkBaselineError.reportHashMismatch
        }
        self.baseline = baseline
    }
}

enum MacBenchmarkBaselineLookup: Equatable, Sendable {
    case matched(VerifiedMacBenchmarkBaseline)
    case notFound
    case ambiguous
    case unsupportedArchitecture
}

enum MacBenchmarkBaselineCatalogError: Error, Equatable, Sendable {
    case invalidActiveBaselineVersion
}

struct MacBenchmarkBaselineCatalog: Sendable {
    private let activeBaselineVersion: String
    private let verifiedBaselines: [VerifiedMacBenchmarkBaseline]

    var hasVerifiedActiveBaseline: Bool {
        verifiedBaselines.contains { verified in
            verified.baseline.comparisonKey.baselineVersion == activeBaselineVersion
        }
    }

    init(
        activeBaselineVersion: String,
        verifiedBaselines: [VerifiedMacBenchmarkBaseline]
    ) throws {
        let normalizedVersion = activeBaselineVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedVersion.isEmpty else {
            throw MacBenchmarkBaselineCatalogError.invalidActiveBaselineVersion
        }
        self.init(
            validatedActiveBaselineVersion: normalizedVersion,
            verifiedBaselines: verifiedBaselines
        )
    }

    /// A non-throwing, deliberately empty catalog for fail-closed runtime use.
    ///
    /// Production calibration data is generated outside the normal app flow.
    /// If those frozen bytes are missing or fail verification, the app must keep
    /// showing genuine raw measurements instead of crashing or inventing scores.
    static func rawOnly(activeBaselineVersion: String) -> Self {
        let normalizedVersion = activeBaselineVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return Self(
            validatedActiveBaselineVersion: normalizedVersion.isEmpty
                ? "baseline-unavailable"
                : normalizedVersion,
            verifiedBaselines: []
        )
    }

    private init(
        validatedActiveBaselineVersion: String,
        verifiedBaselines: [VerifiedMacBenchmarkBaseline]
    ) {
        activeBaselineVersion = validatedActiveBaselineVersion
        self.verifiedBaselines = verifiedBaselines
    }

    func lookup(
        matching rawResult: MacBenchmarkRawResult
    ) -> MacBenchmarkBaselineLookup {
        guard rawResult.environment.architecture == .arm64 else {
            return .unsupportedArchitecture
        }
        let matches = verifiedBaselines.filter { verified in
            let key = verified.baseline.comparisonKey
            return key.baselineVersion == activeBaselineVersion
                && key.workloadVersion == rawResult.workloadVersion
                && key.profile == rawResult.profile
                && key.architecture == rawResult.environment.architecture
                && key.capabilitySet == rawResult.capabilitySet
        }
        switch matches.count {
        case 0:
            return .notFound
        case 1:
            return .matched(matches[0])
        default:
            return .ambiguous
        }
    }
}
