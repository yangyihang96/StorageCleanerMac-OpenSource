import Foundation
@testable import StorageCleanerMac

/// Synthetic references live exclusively in tests. Never shipped or activated by the app.
enum MSeriesV11TestFixtures {
    static let extensionHash = String(repeating: "a", count: 64)
    static let artifact = Data("synthetic-only-controlled-evidence".utf8)
    static var nominal: MSeriesV11Environment {
        .init(releaseBuild: true, nativeARM64: true, translated: false, powerSource: "AC Power",
            powerChanged: false, lowPower: false, automaticPowerMode: true, thermalState: 0,
            backgroundLoadHigh: false)
    }
    static func metric(_ id: String, values: [Double]? = nil,
                       environment: [MSeriesV11Environment]? = nil, checksum: UInt64? = 1,
                       fallback: Bool = false) -> MSeriesV11Metric {
        let values = values ?? Array(repeating: 100, count: id == MSeriesScoringV11.sustainedID ? 6 : 3)
        var metric = MSeriesV11Metric(id: id, contract: MSeriesScoringV11.metricContract(id, extensionHash: extensionHash),
            availability: "available", reasonCode: nil,
            samples: values.map { .init(value: $0, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: checksum) },
            environment: environment ?? [nominal], usedWallClockFallback: fallback)
        if id == MSeriesScoringV11.efficiencyID {
            metric.powerAlignment = .init(timestampQuality: "helperMeasured", expectedSampleCount: 5, validSampleCount: 4,
                windows: values.enumerated().map { .init(matchedWorkUnits: $0.element, joules: 1, observedSeconds: 1,
                    validSampleCount: $0.offset == 0 ? 2 : 1) })
        }
        return metric
    }
    static var metrics: [MSeriesV11Metric] { MSeriesScoringV11.inputIDs.map { metric($0) } }

    static func reference(final: Bool = false, scale: Double = 1, version: String = "synthetic-r1") -> MSeriesReferenceV11 {
        let sessions = (0..<2).map { session in
            MSeriesReferenceV11.Session(id: UUID(), runs: (0..<4).map { run in
                let start = Double(session * 2000 + run * 100)
                return .init(id: UUID(), startedAt: Date(timeIntervalSinceReferenceDate: start),
                    completedAt: Date(timeIntervalSinceReferenceDate: start + 50), environment: [nominal])
            })
        }
        return .init(schema: "reference-v11", version: version, status: final ? .final : .provisional,
            provisionalAgainst: final ? nil : "Apple M5 Pro", scoringVersion: MSeriesScoringV11.version,
            coreContractHash: MSeriesProtocol.contractHash, extensionContractHash: extensionHash,
            scoringContractHash: MSeriesScoringV11.scoringContractHash,
            referenceHardware: .init(chipID: final ? "m1" : "m5-pro", modelIdentifier: "SyntheticModel",
                cpuTotal: final ? 8 : 18, gpuCores: final ? 8 : 20, memoryBytes: 16 * 1024 * 1024 * 1024,
                storageCapacityBytes: 512 * 1024 * 1024 * 1024, cooling: "synthetic"),
            timingPolicy: "gpu-timeline-and-aligned-wall-v11.1", powerPolicy: "helper-powermetrics-cpu-package-v11.1",
            independentRunIDs: sessions.flatMap { $0.runs.map(\.id) }, sessions: sessions,
            medians: Dictionary(uniqueKeysWithValues: MSeriesScoringV11.inputIDs.map { id in
                (id, .init(median: 100 * scale, contract: MSeriesScoringV11.metricContract(id, extensionHash: extensionHash),
                    perRunMedians: Array(repeating: 100 * scale, count: 8), perRunCV: Array(repeating: 0, count: 8)))
            }), crossRunCV: Dictionary(uniqueKeysWithValues: MSeriesScoringV11.inputIDs.map { ($0, 0) }),
            sourceArtifacts: [.init(relativePath: "synthetic.json", sha256: MSeriesV11Digest.sha256(artifact))],
            frozenAt: Date(timeIntervalSinceReferenceDate: 3000))
    }
    static func load(_ reference: MSeriesReferenceV11) throws -> MSeriesReferenceV11.Loaded {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(reference)
        return MSeriesReferenceV11.load(bytes: data,
            manifest: .init(version: reference.version, sha256: MSeriesV11Digest.sha256(data)),
            sourceBytes: ["synthetic.json": artifact])
    }
    static func legacyCore() -> MSeriesResult {
        let hardware = MSeriesHardware(nativeARM64: true, releaseBuild: true, translated: false,
            logicalCores: 8, coreLevels: [], physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            metalDevice: "Synthetic", recommendedMetalWorkingSetBytes: nil, sharedBudgetBytes: 1024,
            osVersion: "synthetic")
        return .init(sessionID: UUID(), schema: MSeriesProtocol.schema, plan: MSeriesProtocol.plan,
            workload: MSeriesProtocol.workload, fixture: MSeriesProtocol.fixture,
            implementation: MSeriesProtocol.implementation, statisticsVersion: MSeriesProtocol.statistics,
            scoringVersion: MSeriesProtocol.scoring, referenceVersion: MSeriesProtocol.reference,
            contractHash: MSeriesProtocol.contractHash, hardware: hardware,
            coreEnvironment: [.init(capturedAt: Date(timeIntervalSinceReferenceDate: 1), thermalState: 0,
                lowPower: false, powerSource: "AC Power")],
            metrics: MSeriesProtocol.coreIDs.map { id in
                let metric = metric(id)
                return .init(id: id, unit: metric.contract.unit, availability: .available, reason: nil,
                    samples: metric.samples, statistics: metric.statistics, repetitions: 1, workers: 1)
            }, extensions: [], cancelled: false, globalFailure: nil, writtenBytes: 0,
            startedAt: Date(timeIntervalSinceReferenceDate: 1), completedAt: Date(timeIntervalSinceReferenceDate: 2))
    }
    static func result(core: MSeriesResult? = nil) -> BenchmarkV7Result {
        let core = core ?? legacyCore()
        let storage = BenchmarkV7StorageTarget(volumeName: "Synthetic", fileSystem: "APFS", availableBytes: 1024, isReadOnly: false)
        let preflight = BenchmarkV7PreflightReport(capturedAt: core.startedAt, powerSource: .acPower, batteryPercent: 100,
            lowPowerModeEnabled: false, thermalState: .nominal, backgroundLoadRatio: 0, availableMemoryBytes: 1024,
            storageTarget: storage, displayDescription: "Synthetic", checks: [], blockedCategories: [])
        return .init(mSeries: core, session: .init(id: core.sessionID, plan: MSeriesProtocol.officialPlan, storageTarget: storage),
            preflight: preflight, versions: MSeriesProtocol.versions, metrics: [], coreScore: nil,
            completedAt: core.completedAt, failure: nil)
    }
}
