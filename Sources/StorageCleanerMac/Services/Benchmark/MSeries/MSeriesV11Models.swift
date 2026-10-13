import FanControlShared
import Foundation

enum MSeriesReferenceStatus: String, Codable, Sendable { case unavailable, provisional, final }
enum MSeriesComparability: String, Codable, Sendable { case comparable, restricted, incomparable }

struct MSeriesComparabilityLabel: Codable, Equatable, Sendable {
    let status: MSeriesComparability
    let reasonCodes: [String]
    var title: String {
        switch status { case .comparable: "可比"; case .restricted: "受限"; case .incomparable: "不可比" }
    }
}

/// One stage's environment. Optional readings are unknown, never nominal/false/AC by default.
struct MSeriesV11Environment: Codable, Equatable, Sendable {
    var releaseBuild: Bool? = nil
    var nativeARM64: Bool? = nil
    var translated: Bool? = nil
    var powerSource: String? = nil
    var powerChanged: Bool? = nil
    var lowPower: Bool? = nil
    var automaticPowerMode: Bool? = nil
    var thermalState: Int? = nil
    var backgroundLoadHigh: Bool? = nil
    var assessmentVersion: String? = nil
    var startMonotonicNs: UInt64? = nil
    var endMonotonicNs: UInt64? = nil
}

struct MSeriesV11MetricContract: Codable, Equatable, Sendable {
    let unit: String
    let timing: String
    let statisticsVersion: String
    let workloadHash: String
}

struct MSeriesV11Metric: Codable, Equatable, Sendable {
    let id: String
    let contract: MSeriesV11MetricContract
    /// String retains unknown future availability values for read-only history.
    let availability: String
    let reasonCode: String?
    let samples: [BenchmarkV7RawSample]
    let environment: [MSeriesV11Environment]
    let usedWallClockFallback: Bool?
    var powerAlignment: MSeriesV11PowerAlignment? = nil
    var statistics: BenchmarkStatisticsSummary? { try? BenchmarkStatistics.summarize(samples.map(\.value)) }
    var sampleCV: Double? {
        guard samples.count >= 3 else { return nil }
        return MSeriesScoringV11.coefficientOfVariation(samples.map(\.value))
    }
}

struct MSeriesV11PowerAlignment: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let matchedWorkUnits: Double
        let joules: Double
        let observedSeconds: Double
        let validSampleCount: Int
    }
    let timestampQuality: String
    let expectedSampleCount: Int
    let validSampleCount: Int
    let windows: [Window]

    func validates(_ samples: [BenchmarkV7RawSample]) -> Bool {
        guard timestampQuality == "helperMeasured", expectedSampleCount == 5,
              validSampleCount >= 4 && validSampleCount <= 5, windows.count == 3, samples.count == 3,
              windows.reduce(0, { $0 + $1.validSampleCount }) >= validSampleCount else { return false }
        var observed = 0.0
        for (window, sample) in zip(windows, samples) {
            guard window.matchedWorkUnits.isFinite, window.matchedWorkUnits > 0,
                  window.joules.isFinite, window.joules > 0,
                  window.observedSeconds.isFinite, window.observedSeconds > 0,
                  window.validSampleCount >= 1,
                  window.matchedWorkUnits / window.joules == sample.value else { return false }
            observed += window.observedSeconds
        }
        return observed > 0 && observed <= 10
    }
}

struct MSeriesV11Frequency: Codable, Equatable, Sendable {
    let cluster: String
    let gigahertz: Double?
    let source: String
    let startMonotonicNs: UInt64?
    let endMonotonicNs: UInt64?
}

struct MSeriesV11Window: Codable, Equatable, Sendable {
    let id: String
    let startMonotonicNs: UInt64
    let endMonotonicNs: UInt64
    let elapsedSeconds: Double
    let workUnits: Double
    let wallThroughput: Double?
    let gpuTimedThroughput: Double?
    let temperatureC: Double?
    let powerW: Double?
    let frequencies: [MSeriesV11Frequency]
    let validityReasons: [String]
    let environment: [MSeriesV11Environment]
}

struct MSeriesV11EfficiencyPoint: Codable, Equatable, Sendable {
    let id: String
    let throughput: MSeriesV11Metric?
    let efficiency: MSeriesV11Metric?
    let resolvedWorkers: Int?
    let coreType: String?
    let meanPowerW: Double?
    let matchedWorkUnits: Double?
    let joules: Double?
    let expectedSampleCount: Int
    let validSampleCount: Int
    let observedSeconds: Double?
    /// helperMeasured | requestBracketOnly | legacyUntimed; unknown values retained.
    let timestampQuality: String
    let alignmentQuality: String?
    let missingReasons: [String]
    let frequencies: [MSeriesV11Frequency]
    let windows: [MSeriesV11Window]
    /// Independent sample coverage and measured time coverage are distinct.
    /// Optional so existing v11 history remains decodable.
    var sampleCoverageFraction: Double? = nil
    var timeCoverageFraction: Double? = nil
}

struct MSeriesV11Sustained: Codable, Equatable, Sendable {
    let id: String
    let durationSeconds: Double
    let windows: [MSeriesV11Window]
    let first10Median: Double?
    let tail30Metric: MSeriesV11Metric?
    let retention: Double?
    let missingReasons: [String]
    var overallCV: Double? {
        MSeriesScoringV11.coefficientOfVariation(windows.compactMap {
            id.contains("gpu") ? $0.gpuTimedThroughput : $0.wallThroughput
        })
    }
    var tailCV: Double? { tail30Metric?.sampleCV }
}

struct MSeriesV11Accelerator: Codable, Equatable, Sendable {
    let id: String
    let availability: String
    let reasonCode: String?
    let metric: MSeriesV11Metric?
    let allocationEvidence: String?
    let allocationEvidenceKind: String?
    let fixtureVersion: String?
    let fixtureSHA256: String?
}

struct MSeriesV11BackgroundLoadAssessment: Codable, Equatable, Sendable {
    let startMonotonicNs: UInt64?
    let endMonotonicNs: UInt64?
    let cpuMedianRatio: Double?
    let gpuMedianRatio: Double?
    let removedApplicationLoad: Bool?
    let detectionVersion: String
    let thresholdRatio: Double
    let status: String
    let reasonCodes: [String]
}

struct MSeriesV11Telemetry: Codable, Equatable, Sendable {
    let sampleID: String
    /// Runtime only. Nil in sealed/newly saved history; old histories still decode.
    var helperBootID: String?
    let clockDomain: String
    let measurementStartMonotonicNs: UInt64?
    let measurementEndMonotonicNs: UInt64?
    let requestStartMonotonicNs: UInt64?
    let responseReceivedMonotonicNs: UInt64?
    let durationSeconds: Double?
    let cpuMilliwatts: Double?
    let gpuMilliwatts: Double?
    let aneMilliwatts: Double?
    let timestampQuality: String
    var clusters: [PowermetricsSample.ClusterFrequency]? = nil
    var gpuMegahertz: Double? = nil
    /// First-seen group number within ONE result, never a hash of the helper ID.
    var helperProcessOrdinal: Int? = nil

    static func forPersistence(_ samples: [Self]) -> [Self] {
        enum Identity: Hashable { case runtime(String), saved(Int) }
        var ordinals: [Identity: Int] = [:]
        return samples.map { sample in
            var copy = sample
            let identity: Identity?
            if let bootID = sample.helperBootID, !bootID.isEmpty {
                identity = .runtime(bootID)
            } else if let ordinal = sample.helperProcessOrdinal, (1...1_024).contains(ordinal) {
                identity = .saved(ordinal)
            } else {
                identity = nil
            }
            if let identity {
                let ordinal = ordinals[identity] ?? ordinals.count + 1
                ordinals[identity] = ordinal
                copy.helperProcessOrdinal = ordinal
            } else {
                copy.helperProcessOrdinal = nil
            }
            copy.helperBootID = nil
            return copy
        }
    }
}

struct MSeriesReferenceIdentity: Codable, Equatable, Sendable {
    let version: String?
    let sha256: String?
    let referenceStatus: MSeriesReferenceStatus
    let provisionalAgainst: String?
    static let unavailable = Self(version: nil, sha256: nil, referenceStatus: .unavailable, provisionalAgainst: nil)
}

struct MSeriesV11Scores: Codable, Equatable, Sendable {
    let componentScores: [String: Double]
    let labels: [String: MSeriesComparabilityLabel]
    let referenceIdentity: MSeriesReferenceIdentity
    let scoreStatus: String
    var chipScore: Double? { componentScores["chip"] }
    var systemScore: Double? { componentScores["system"] }
    var efficiencyScore: Double? { componentScores["efficiency"] }

    func displayScore(_ id: String) -> String {
        guard let value = componentScores[id], value.isFinite else { return "待校准" }
        let prefix = referenceIdentity.referenceStatus == .provisional ? "暂定 " : ""
        return prefix + String(format: "%.0f", value)
    }
}

/// Optional envelope inside the existing BenchmarkV7Result. Core stays v10 verbatim.
/// No runner switches protocol in B2a; B2b supplies extension measurements.
struct MSeriesV11Result: Codable, Equatable, Sendable {
    let schema: String
    let plan: String
    let mode: String
    let sessionID: UUID
    let coreContractHash: String
    let extensionContractHash: String
    let scoringContractHash: String
    private(set) var rawPayloadSHA256: String
    var hardwareIdentity: AppleSiliconIdentity? = nil
    var efficiencyPoints: [MSeriesV11EfficiencyPoint] = []
    var sustainedCPU: MSeriesV11Sustained? = nil
    var sustainedGPU: MSeriesV11Sustained? = nil
    var accelerators: [MSeriesV11Accelerator] = []
    var legacyExtensions: [MSeriesMeasurement] = []
    var perStageEnvironment: [String: [MSeriesV11Environment]] = [:]
    var preflight: MSeriesV11Environment? = nil
    var postflight: MSeriesV11Environment? = nil
    var backgroundLoadAssessment: MSeriesV11BackgroundLoadAssessment? = nil
    var telemetryAvailability: String? = nil
    var telemetry: [MSeriesV11Telemetry] = []
    /// Actual validated workload intervals; never reconstructed from aggregate throughput.
    var workloadBatches: [MSeriesV11Batch] = []
    var scores: MSeriesV11Scores? = nil
    var derivedCacheKey: String? = nil
    var referenceIdentity: MSeriesReferenceIdentity? = nil
    var elapsedSeconds: Double? = nil
    var measuredDurationSeconds: Double? = nil
    var dispatchDeadlineSeconds: Double? = nil
    var drainDurationSeconds: Double? = nil
    var cancellationRequestedAt: Date? = nil
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var state: String? = nil
    var failure: String? = nil
    var metadataWrittenBytes: UInt64? = nil
    var writtenBytes: UInt64? = nil
    var missingReasons: [String] = []

    enum CodingKeys: String, CodingKey {
        case schema, plan, mode, sessionID, coreContractHash, extensionContractHash, scoringContractHash, rawPayloadSHA256
        case hardwareIdentity, efficiencyPoints, sustainedCPU, sustainedGPU, accelerators, legacyExtensions
        case perStageEnvironment, telemetry, workloadBatches, scores, derivedCacheKey, referenceIdentity, elapsedSeconds
        case preflight, postflight, backgroundLoadAssessment, telemetryAvailability, startedAt, completedAt, writtenBytes
        case measuredDurationSeconds, dispatchDeadlineSeconds, drainDurationSeconds, cancellationRequestedAt
        case state, failure, metadataWrittenBytes, missingReasons
        case payloadEncoding, payloadLengthBytes, payloadSHA256, payload
    }

    init(sessionID: UUID, extensionContractHash: String, rawPayloadSHA256: String, mode: String = "standard") {
        self.schema = "mseries-result-v11"
        self.plan = mode == "pressure10m" ? "mseries-pressure-v11" : "mseries-core-v11"
        self.mode = mode
        self.sessionID = sessionID
        self.coreContractHash = MSeriesProtocol.contractHash
        self.extensionContractHash = extensionContractHash
        self.scoringContractHash = MSeriesScoringV11.scoringContractHash
        self.rawPayloadSHA256 = rawPayloadSHA256
    }

    func replacingRawDigest(_ digest: String) -> Self {
        var copy = self
        copy.rawPayloadSHA256 = digest
        return copy
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if (!workloadBatches.isEmpty || encoder.userInfo[MSeriesV11CompactStorage.forceCompactEncoding] as? Bool == true),
           encoder.userInfo[MSeriesV11CompactStorage.expandedEncoding] as? Bool != true {
            var body = self
            body.metadataWrittenBytes = nil
            body.writtenBytes = nil
            let bytes = try MSeriesV11CompactStorage.expandedBytes(body)
            try c.encode(schema, forKey: .schema)
            try c.encode(MSeriesV11CompactStorage.format, forKey: .payloadEncoding)
            try c.encode(bytes.count, forKey: .payloadLengthBytes)
            try c.encode(MSeriesV11Digest.sha256(bytes), forKey: .payloadSHA256)
            try c.encode(MSeriesV11CompactStorage.compress(bytes), forKey: .payload)
            try c.encodeIfPresent(metadataWrittenBytes, forKey: .metadataWrittenBytes)
            try c.encodeIfPresent(writtenBytes, forKey: .writtenBytes)
            return
        }
        try c.encode(schema, forKey: .schema)
        try c.encode(plan, forKey: .plan)
        try c.encode(mode, forKey: .mode)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(coreContractHash, forKey: .coreContractHash)
        try c.encode(extensionContractHash, forKey: .extensionContractHash)
        try c.encode(scoringContractHash, forKey: .scoringContractHash)
        try c.encode(rawPayloadSHA256, forKey: .rawPayloadSHA256)
        try c.encodeIfPresent(hardwareIdentity, forKey: .hardwareIdentity)
        try c.encode(efficiencyPoints, forKey: .efficiencyPoints)
        try c.encodeIfPresent(sustainedCPU, forKey: .sustainedCPU)
        try c.encodeIfPresent(sustainedGPU, forKey: .sustainedGPU)
        try c.encode(accelerators, forKey: .accelerators)
        try c.encode(legacyExtensions, forKey: .legacyExtensions)
        try c.encode(perStageEnvironment, forKey: .perStageEnvironment)
        try c.encode(telemetry, forKey: .telemetry)
        try c.encode(workloadBatches, forKey: .workloadBatches)
        try c.encodeIfPresent(scores, forKey: .scores)
        try c.encodeIfPresent(derivedCacheKey, forKey: .derivedCacheKey)
        try c.encodeIfPresent(referenceIdentity, forKey: .referenceIdentity)
        try c.encodeIfPresent(elapsedSeconds, forKey: .elapsedSeconds)
        try c.encodeIfPresent(preflight, forKey: .preflight)
        try c.encodeIfPresent(postflight, forKey: .postflight)
        try c.encodeIfPresent(backgroundLoadAssessment, forKey: .backgroundLoadAssessment)
        try c.encodeIfPresent(telemetryAvailability, forKey: .telemetryAvailability)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(writtenBytes, forKey: .writtenBytes)
        try c.encodeIfPresent(measuredDurationSeconds, forKey: .measuredDurationSeconds)
        try c.encodeIfPresent(dispatchDeadlineSeconds, forKey: .dispatchDeadlineSeconds)
        try c.encodeIfPresent(drainDurationSeconds, forKey: .drainDurationSeconds)
        try c.encodeIfPresent(cancellationRequestedAt, forKey: .cancellationRequestedAt)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(failure, forKey: .failure)
        try c.encodeIfPresent(metadataWrittenBytes, forKey: .metadataWrittenBytes)
        try c.encode(missingReasons, forKey: .missingReasons)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let format = try c.decodeIfPresent(String.self, forKey: .payloadEncoding) {
            guard format == MSeriesV11CompactStorage.format,
                  decoder.userInfo[MSeriesV11CompactStorage.expandedEncoding] as? Bool != true else {
                throw MSeriesV11RunError.metadataBudget
            }
            let bytes = try MSeriesV11CompactStorage.expand(c.decode(Data.self, forKey: .payload),
                expectedBytes: c.decode(Int.self, forKey: .payloadLengthBytes), sha256: c.decode(String.self, forKey: .payloadSHA256))
            let expandedDecoder = JSONDecoder()
            expandedDecoder.userInfo[MSeriesV11CompactStorage.expandedEncoding] = true
            self = try expandedDecoder.decode(Self.self, from: bytes)
            guard schema == (try c.decode(String.self, forKey: .schema)) else { throw MSeriesV11RunError.metadataBudget }
            metadataWrittenBytes = try c.decodeIfPresent(UInt64.self, forKey: .metadataWrittenBytes)
            writtenBytes = try c.decodeIfPresent(UInt64.self, forKey: .writtenBytes)
            return
        }
        schema = try c.decode(String.self, forKey: .schema)
        plan = try c.decode(String.self, forKey: .plan)
        mode = try c.decode(String.self, forKey: .mode)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        coreContractHash = try c.decode(String.self, forKey: .coreContractHash)
        extensionContractHash = try c.decode(String.self, forKey: .extensionContractHash)
        scoringContractHash = try c.decode(String.self, forKey: .scoringContractHash)
        rawPayloadSHA256 = try c.decode(String.self, forKey: .rawPayloadSHA256)
        hardwareIdentity = try c.decodeIfPresent(AppleSiliconIdentity.self, forKey: .hardwareIdentity)
        efficiencyPoints = try c.decodeIfPresent([MSeriesV11EfficiencyPoint].self, forKey: .efficiencyPoints) ?? []
        sustainedCPU = try c.decodeIfPresent(MSeriesV11Sustained.self, forKey: .sustainedCPU)
        sustainedGPU = try c.decodeIfPresent(MSeriesV11Sustained.self, forKey: .sustainedGPU)
        accelerators = try c.decodeIfPresent([MSeriesV11Accelerator].self, forKey: .accelerators) ?? []
        legacyExtensions = try c.decodeIfPresent([MSeriesMeasurement].self, forKey: .legacyExtensions) ?? []
        perStageEnvironment = try c.decodeIfPresent([String: [MSeriesV11Environment]].self, forKey: .perStageEnvironment) ?? [:]
        preflight = try c.decodeIfPresent(MSeriesV11Environment.self, forKey: .preflight)
        postflight = try c.decodeIfPresent(MSeriesV11Environment.self, forKey: .postflight)
        backgroundLoadAssessment = try c.decodeIfPresent(MSeriesV11BackgroundLoadAssessment.self, forKey: .backgroundLoadAssessment)
        telemetryAvailability = try c.decodeIfPresent(String.self, forKey: .telemetryAvailability)
        telemetry = try c.decodeIfPresent([MSeriesV11Telemetry].self, forKey: .telemetry) ?? []
        workloadBatches = try c.decodeIfPresent([MSeriesV11Batch].self, forKey: .workloadBatches) ?? []
        scores = try c.decodeIfPresent(MSeriesV11Scores.self, forKey: .scores)
        derivedCacheKey = try c.decodeIfPresent(String.self, forKey: .derivedCacheKey)
        referenceIdentity = try c.decodeIfPresent(MSeriesReferenceIdentity.self, forKey: .referenceIdentity)
        elapsedSeconds = try c.decodeIfPresent(Double.self, forKey: .elapsedSeconds)
        measuredDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .measuredDurationSeconds)
        dispatchDeadlineSeconds = try c.decodeIfPresent(Double.self, forKey: .dispatchDeadlineSeconds)
        drainDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .drainDurationSeconds)
        cancellationRequestedAt = try c.decodeIfPresent(Date.self, forKey: .cancellationRequestedAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        metadataWrittenBytes = try c.decodeIfPresent(UInt64.self, forKey: .metadataWrittenBytes)
        writtenBytes = try c.decodeIfPresent(UInt64.self, forKey: .writtenBytes)
        missingReasons = try c.decodeIfPresent([String].self, forKey: .missingReasons) ?? []
    }
}
