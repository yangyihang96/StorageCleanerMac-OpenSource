import Foundation

struct MSeriesReferenceV11: Codable, Equatable, Sendable {
    struct Hardware: Codable, Equatable, Sendable {
        let chipID: String
        let modelIdentifier: String
        let cpuTotal: Int
        let gpuCores: Int
        let memoryBytes: UInt64
        let storageCapacityBytes: UInt64?
        let cooling: String?
    }
    struct Median: Codable, Equatable, Sendable {
        let median: Double
        let contract: MSeriesV11MetricContract
        let perRunMedians: [Double]
        let perRunCV: [Double]
    }
    struct Run: Codable, Equatable, Sendable {
        let id: UUID
        let startedAt: Date
        let completedAt: Date
        let environment: [MSeriesV11Environment]
    }
    struct Session: Codable, Equatable, Sendable { let id: UUID; let runs: [Run] }
    struct Artifact: Codable, Equatable, Sendable { let relativePath: String; let sha256: String }
    let schema: String
    let version: String
    let status: MSeriesReferenceStatus
    let provisionalAgainst: String?
    let scoringVersion: String
    let coreContractHash: String
    let extensionContractHash: String
    let scoringContractHash: String
    let referenceHardware: Hardware
    let timingPolicy: String
    let powerPolicy: String
    let independentRunIDs: [UUID]
    let sessions: [Session]
    let medians: [String: Median]
    let crossRunCV: [String: Double]
    let sourceArtifacts: [Artifact]
    let frozenAt: Date

    struct Manifest: Codable, Sendable { let version: String; let sha256: String }
    struct Loaded: Sendable {
        // Only the byte/hash/structure gate below constructs an active reference.
        let reference: MSeriesReferenceV11?
        let identity: MSeriesReferenceIdentity
        let reason: String?
        fileprivate init(reference: MSeriesReferenceV11?, identity: MSeriesReferenceIdentity, reason: String?) {
            self.reference = reference
            self.identity = identity
            self.reason = reason
        }
        static let unavailable = Self(reference: nil, identity: .unavailable, reason: "referenceUnavailable")
    }

    static func load(bytes: Data, manifest: Manifest, sourceBytes: [String: Data]) -> Loaded {
        let digest = MSeriesV11Digest.sha256(bytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard bytes.count <= 1_048_576, digest == manifest.sha256,
              let reference = try? decoder.decode(Self.self, from: bytes),
              reference.version == manifest.version, reference.isValid(sourceBytes: sourceBytes) else {
            return Loaded(reference: nil, identity: .unavailable, reason: "referenceInvalid")
        }
        return Loaded(reference: reference, identity: .init(version: reference.version, sha256: digest,
            referenceStatus: reference.status, provisionalAgainst: reference.provisionalAgainst), reason: nil)
    }

    private func isValid(sourceBytes: [String: Data]) -> Bool {
        guard schema == "reference-v11", !version.isEmpty, status != .unavailable,
              scoringVersion == MSeriesScoringV11.version, coreContractHash == MSeriesProtocol.contractHash,
              scoringContractHash == MSeriesScoringV11.scoringContractHash,
              MSeriesV11Digest.isSHA256(extensionContractHash),
              MSeriesV11Digest.sha256(Data(MSeriesScoringV11.contract.utf8)) == scoringContractHash,
              timingPolicy == "gpu-timeline-and-aligned-wall-v11.1",
              powerPolicy == "helper-powermetrics-cpu-package-v11.1",
              referenceHardware.cpuTotal > 0, referenceHardware.gpuCores > 0,
              referenceHardware.memoryBytes > 0, !referenceHardware.modelIdentifier.isEmpty,
              referenceHardware.storageCapacityBytes != nil, referenceHardware.cooling != nil,
              sessions.count >= 2, Set(sessions.map(\.id)).count == sessions.count,
              sessions.allSatisfy({ $0.runs.count >= 4 }), !sourceArtifacts.isEmpty,
              Set(sourceArtifacts.map(\.relativePath)).count == sourceArtifacts.count else { return false }
        if status == .provisional {
            guard referenceHardware.chipID == "m5-pro", provisionalAgainst == "Apple M5 Pro" else { return false }
        } else {
            guard referenceHardware.chipID == "m1", referenceHardware.cpuTotal == 8,
                  referenceHardware.gpuCores == 8, provisionalAgainst == nil else { return false }
        }
        let runs = sessions.flatMap(\.runs).sorted { $0.startedAt < $1.startedAt }
        guard runs.count >= 8, Set(runs.map(\.id)).count == runs.count,
              Set(runs.map(\.id)) == Set(independentRunIDs), independentRunIDs.count == runs.count,
              runs.allSatisfy({ $0.completedAt > $0.startedAt && $0.completedAt <= frozenAt
                  && MSeriesScoringV11.environmentLabel($0.environment).status == .comparable }) else { return false }
        for index in 1..<runs.count {
            guard runs[index].startedAt >= runs[index - 1].completedAt else { return false }
        }
        let orderedSessions = sessions.sorted { ($0.runs.map(\.startedAt).min() ?? .distantPast) < ($1.runs.map(\.startedAt).min() ?? .distantPast) }
        for index in 1..<orderedSessions.count {
            guard let start = orderedSessions[index].runs.map(\.startedAt).min(),
                  let previousEnd = orderedSessions[index - 1].runs.map(\.completedAt).max(),
                  start.timeIntervalSince(previousEnd) >= 600 else { return false }
        }
        for artifact in sourceArtifacts {
            guard !artifact.relativePath.hasPrefix("/"), !artifact.relativePath.split(separator: "/").contains(".."),
                  let bytes = sourceBytes[artifact.relativePath], MSeriesV11Digest.sha256(bytes) == artifact.sha256 else { return false }
        }
        guard Set(medians.keys) == Set(MSeriesScoringV11.inputIDs), Set(crossRunCV.keys) == Set(medians.keys) else { return false }
        for (id, value) in medians {
            guard value.contract == MSeriesScoringV11.metricContract(id, extensionHash: extensionContractHash),
                  value.perRunMedians.count == runs.count, value.perRunCV.count == runs.count,
                  value.perRunCV.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= MSeriesScoringV11.maximumCV(id) }),
                  let summary = try? BenchmarkStatistics.summarize(value.perRunMedians), summary.median == value.median,
                  let cv = MSeriesScoringV11.coefficientOfVariation(value.perRunMedians),
                  cv == crossRunCV[id], cv <= MSeriesScoringV11.maximumCV(id) else { return false }
        }
        return true
    }
}
