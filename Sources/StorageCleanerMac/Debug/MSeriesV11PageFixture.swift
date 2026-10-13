#if DEBUG
import Foundation

/// Screenshot values only. Every measurement, helper interval and reference run
/// below is synthetic; no provider, workload, persistence or reference activation
/// is invoked. The repository catalog supplies specifications, never scores.
enum MSeriesV11PageFixture {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let nanoseconds: UInt64 = 1_000_000_000
    private static var extensionHash: String { MSeriesV11Protocol.contractHash }

    static var catalog: AppleSiliconCatalogLoader.Loaded {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Resources/Benchmark", isDirectory: true)
        return AppleSiliconCatalogLoader.load(
            catalogURL: resources.appendingPathComponent("AppleSiliconCatalog.json"),
            manifestURL: resources.appendingPathComponent("AppleSiliconCatalog.manifest.json"))
    }

    static var identity: AppleSiliconIdentity? {
        let loaded = catalog
        let model = loaded.catalog?.chips.first { $0.id == "m5-pro" }?.typicalMacs
            .first { $0.cooling == "active" }?.model
        let evidence = AppleSiliconHardwareEvidence(capturedAt: epoch,
            nativeARM64: true, translated: false, brandString: "Apple M5 Pro",
            modelIdentifier: model, perfLevelCount: 2, perfLevels: [
                .init(index: 0, name: "Super", physicalCores: 6, logicalCores: nil),
                .init(index: 1, name: "Performance", physicalCores: 12, logicalCores: nil)
            ], physicalCPUCount: 18, metalDeviceName: nil, profilerGPUName: "Apple M5 Pro",
            profilerGPUCores: 20, physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024,
            missingReasons: ["debugSyntheticEvidence", "logicalCoresNotRead", "metalNameNotRead"])
        return AppleSiliconIdentifier.identify(evidence, catalog: loaded)
    }

    static var runState: BenchmarkV7State {
        .phase(.running, sessionID: fixedID(1), category: .cpu,
            workloadID: "cpu.multi.compression", repetition: 2, progress: 68.0 / 460.0)
    }

    static var telemetry: [MSeriesV11Telemetry] {
        // The live page drops readings older than 60 seconds. Translate the
        // synthetic timeline to the current monotonic epoch without probing a
        // provider; result() keeps its fixed, sealed history timeline intact.
        let samples = Array(extensionData(helper: true).telemetry.prefix(34))
        let end = samples.last?.responseReceivedMonotonicNs ?? 0
        let now = MSeriesV11Clock.nanoseconds
        let offset = now >= end ? now - end : 0
        return samples.map { sample in
            .init(sampleID: sample.sampleID, helperBootID: sample.helperBootID,
                clockDomain: sample.clockDomain,
                measurementStartMonotonicNs: sample.measurementStartMonotonicNs.map { $0 + offset },
                measurementEndMonotonicNs: sample.measurementEndMonotonicNs.map { $0 + offset },
                requestStartMonotonicNs: sample.requestStartMonotonicNs.map { $0 + offset },
                responseReceivedMonotonicNs: sample.responseReceivedMonotonicNs.map { $0 + offset },
                durationSeconds: sample.durationSeconds, cpuMilliwatts: sample.cpuMilliwatts,
                gpuMilliwatts: sample.gpuMilliwatts, aneMilliwatts: sample.aneMilliwatts,
                timestampQuality: sample.timestampQuality, clusters: sample.clusters,
                gpuMegahertz: sample.gpuMegahertz)
        }
    }

    /// Supported variants: standard, provisional, nohelper, unavailable,
    /// partial, legacy-v10 and legacy-v9. All results remain in memory.
    static func result(variant: String = "standard") -> BenchmarkV7Result {
        if variant == "legacy-v9" { return legacyV9() }
        let sessionID = UUID()
        let partial = variant == "partial"
        let core = core(sessionID: sessionID, partial: partial)
        let preflight = preflight()
        if variant == "legacy-v10" {
            return .init(mSeries: core,
                session: .init(id: sessionID, plan: MSeriesProtocol.officialPlan,
                    storageTarget: preflight.storageTarget, startedAt: epoch),
                preflight: preflight, versions: MSeriesProtocol.versions,
                metrics: [], coreScore: nil, runtimeWarnings: ["debugSyntheticLayoutOnly"],
                completedAt: core.completedAt, failure: nil)
        }

        var envelope = MSeriesV11Result(sessionID: sessionID, extensionContractHash: extensionHash,
            rawPayloadSHA256: String(repeating: "0", count: 64))
        envelope.hardwareIdentity = identity
        envelope.preflight = nominal
        envelope.postflight = nominal
        envelope.perStageEnvironment = ["core": [nominal]]
        envelope.startedAt = epoch
        envelope.completedAt = core.completedAt
        envelope.elapsedSeconds = partial ? 68 : 452
        envelope.measuredDurationSeconds = envelope.elapsedSeconds
        envelope.dispatchDeadlineSeconds = 480
        envelope.drainDurationSeconds = 0
        envelope.state = partial ? "cancelled" : "completed"
        envelope.failure = partial ? "cancelled" : nil
        envelope.cancellationRequestedAt = partial ? core.completedAt : nil
        envelope.missingReasons = ["debugSyntheticLayoutOnly"]
        if !partial {
            let data = extensionData(helper: variant != "nohelper")
            envelope.efficiencyPoints = data.points
            envelope.sustainedCPU = data.cpu
            envelope.sustainedGPU = data.gpu
            envelope.telemetry = data.telemetry
            envelope.workloadBatches = data.batches
            envelope.accelerators = acceleratorRows
        }
        envelope.telemetryAvailability = variant == "nohelper" || partial ? "unavailable" : "available"
        let reference: MSeriesReferenceV11.Loaded = variant == "unavailable" ? .unavailable
            : syntheticReference(provisional: variant == "provisional")
        envelope.scores = MSeriesScoringV11.evaluate(
            metrics: MSeriesScoringV11.inputs(core: core, envelope: envelope),
            reference: reference, extensionHash: extensionHash)
        envelope.referenceIdentity = reference.identity
        do {
            // This only seals a value in memory. It never writes a history file.
            envelope = try MSeriesV11RawPayload.seal(core: core, envelope: envelope)
        } catch {
            preconditionFailure("Debug benchmark fixture cannot be sealed: \(error)")
        }
        return .init(mSeries: core, mSeriesV11: envelope,
            session: .init(id: sessionID, plan: MSeriesV11Protocol.plan(mode: "standard"),
                storageTarget: preflight.storageTarget, startedAt: epoch),
            preflight: preflight, versions: MSeriesV11Protocol.versions(mode: "standard"),
            metrics: [], coreScore: nil, runtimeWarnings: ["debugSyntheticLayoutOnly"],
            completionStatus: partial ? .cancelled : .completed,
            completedAt: core.completedAt, failure: partial ? .cancelled : nil)
    }

    /// A nominal *synthetic* release environment lets the scorer exercise layout
    /// states in Debug. It is not a claim about this process or the real device.
    private static var nominal: MSeriesV11Environment {
        .init(releaseBuild: true, nativeARM64: true, translated: false,
            powerSource: "AC Power", powerChanged: false, lowPower: false,
            automaticPowerMode: true, thermalState: 0, backgroundLoadHigh: false)
    }

    private static let coreValues: [Double] = [
        148.2, 82.4, 215.6, 92.8, 1_258.6, 702.8, 1_675.2, 744.9,
        186.4, 92.6, 174.8, 74.2, 51.8, 92.4, 5.82, 4.96, 24_180, 18_540
    ]
    private static let cpuSustained = [
        1_258.6, 1_258.6, 1_255, 1_252, 1_248, 1_244, 1_240, 1_236, 1_234,
        1_232, 1_228, 1_225, 1_223, 1_220, 1_218.8, 1_221, 1_217, 1_222
    ]
    private static let gpuSustained: [Double] = [
        2_560, 2_560, 2_548, 2_536, 2_520, 2_508, 2_492, 2_480, 2_470,
        2_460, 2_450, 2_442, 2_436, 2_432, 2_430, 2_434, 2_432, 2_428
    ]

    private static func core(sessionID: UUID, partial: Bool) -> MSeriesResult {
        let ids = partial ? Array(MSeriesProtocol.coreIDs.prefix(7)) : MSeriesProtocol.coreIDs
        let metrics: [MSeriesMeasurement] = ids.enumerated().map { index, id in
            let median = coreValues[index]
            let spread = id == "gpu.compute.fp16" ? 0.025 : id == "storage.randomWriteQD1" ? 0.044 : 0.006
            let samples: [BenchmarkV7RawSample] = [median * (1 - spread), median, median * (1 + spread)]
                .map { .init(value: $0, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 1) }
            return .init(id: id, unit: MSeriesScoringV11.metricContract(id, extensionHash: extensionHash).unit,
                availability: .available, reason: nil, samples: samples,
                statistics: try? BenchmarkStatistics.summarize(samples.map(\.value)), repetitions: 3,
                workers: id.hasPrefix("cpu.multi.") ? 18 : 1)
        }
        return .init(sessionID: sessionID, schema: MSeriesProtocol.schema, plan: MSeriesProtocol.plan,
            workload: MSeriesProtocol.workload, fixture: MSeriesProtocol.fixture,
            implementation: MSeriesProtocol.implementation, statisticsVersion: MSeriesProtocol.statistics,
            scoringVersion: MSeriesProtocol.scoring, referenceVersion: MSeriesProtocol.reference,
            contractHash: MSeriesProtocol.contractHash,
            hardware: .init(nativeARM64: true, releaseBuild: true, translated: false,
                logicalCores: 18, coreLevels: [], physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024,
                metalDevice: "Debug Synthetic GPU", recommendedMetalWorkingSetBytes: nil,
                sharedBudgetBytes: 1_024 * 1_024 * 1_024, osVersion: "Debug Fixture OS"),
            coreEnvironment: [.init(capturedAt: epoch, thermalState: 0, lowPower: false, powerSource: "AC Power")],
            metrics: metrics, extensions: [], cancelled: partial, globalFailure: partial ? "cancelled" : nil,
            writtenBytes: partial ? 0 : 337 * 1_024 * 1_024, startedAt: epoch,
            completedAt: epoch.addingTimeInterval(partial ? 68 : 452))
    }

    private struct Stage {
        let batches: [MSeriesV11Batch]
        let telemetry: [MSeriesV11Telemetry]
        let windows: [MSeriesV11Window]
    }
    private struct Extensions {
        let points: [MSeriesV11EfficiencyPoint]
        let cpu: MSeriesV11Sustained
        let gpu: MSeriesV11Sustained
        let batches: [MSeriesV11Batch]
        let telemetry: [MSeriesV11Telemetry]
    }

    private static func stage(_ id: String, startSeconds: Int, duration: Int, values: [Double],
                              watts: Double, gpu: Bool = false, helper: Bool) -> Stage {
        let start = UInt64(startSeconds) * nanoseconds
        let batches: [MSeriesV11Batch] = (0..<duration).map { second in
            let value = values[min(values.count - 1, second * values.count / duration)]
            return .init(stageID: id, startMonotonicNs: start + UInt64(second) * nanoseconds,
                endMonotonicNs: start + UInt64(second + 1) * nanoseconds, workUnits: value,
                gpuElapsedSeconds: gpu ? 1 : nil, checksum: 1, clockDomain: MSeriesV11Windows.clockDomain)
        }
        let samples: [MSeriesV11Telemetry] = helper ? (0..<(duration / 2)).map { index in
            let a = start + UInt64(index * 2) * nanoseconds
            let b = a + 2 * nanoseconds
            return .init(sampleID: "debug.\(id).\(index)", helperBootID: "debug-synthetic-helper",
                clockDomain: MSeriesV11Windows.clockDomain, measurementStartMonotonicNs: a,
                measurementEndMonotonicNs: b, requestStartMonotonicNs: a,
                responseReceivedMonotonicNs: b, durationSeconds: 2,
                cpuMilliwatts: gpu ? 4_000 : watts * 1_000,
                gpuMilliwatts: gpu ? watts * 1_000 : 1_000, aneMilliwatts: nil,
                timestampQuality: "helperMeasured",
                clusters: [.init(name: "Super", kind: .performance, megahertz: gpu ? 1_200 : 4_200)],
                gpuMegahertz: gpu ? 1_400 : 400)
        } : []
        let observations: [MSeriesV11Observation] = (0..<duration).map { second in
            .init(atMonotonicNs: start + UInt64(second) * nanoseconds,
                cpuTemperatureC: 50 + Double(second) * 0.18,
                gpuTemperatureC: 51 + Double(second) * 0.21, environment: nominal)
        }
        let windows = MSeriesV11Windows.windows(id: id, start: start, durationSeconds: duration,
            count: duration == 90 ? 18 : 3, finishedAt: start + UInt64(duration) * nanoseconds,
            batches: batches, telemetry: samples, observations: observations, gpu: gpu)
        return .init(batches: batches, telemetry: samples, windows: windows)
    }

    private static func extensionData(helper: Bool) -> Extensions {
        let plans: [(String, Int, Int, Double, Double, Int)] = [
            ("power.cpu.single", 185, 10, 148.2, 4.8, 1),
            ("power.cpu.performanceCores", 195, 10, 730, 18.5, 6),
            ("power.cpu.allCores", 205, 10, 1_258.6, 34, 18),
            ("power.gpu.peak", 215, 30, 2_560, 28, 20)
        ]
        let stages = plans.map { id, start, duration, value, watts, _ in
            stage(id, startSeconds: start, duration: duration, values: [value],
                watts: watts, gpu: id == MSeriesScoringV11.peakID, helper: helper)
        }
        let points = zip(plans, stages).map { plan, data in
            MSeriesV11Windows.efficiencyPoint(id: plan.0, workers: plan.5,
                coreType: plan.0 == "power.cpu.performanceCores" ? "super-count" : "all",
                windows: data.windows, batches: data.batches, telemetry: data.telemetry,
                extensionHash: extensionHash, extraReasons: helper ? [] : ["helperUnavailable"])
        }
        let cpu = stage("sustained.cpu.allCores", startSeconds: 245, duration: 90,
            values: cpuSustained, watts: 34, helper: helper)
        let gpu = stage("sustained.gpu", startSeconds: 335, duration: 90,
            values: gpuSustained, watts: 28, gpu: true, helper: helper)
        return .init(points: points,
            cpu: MSeriesV11Windows.sustained(id: "sustained.cpu.allCores", duration: 90,
                windows: cpu.windows, batches: cpu.batches, extensionHash: extensionHash, gpu: false),
            gpu: MSeriesV11Windows.sustained(id: "sustained.gpu", duration: 90,
                windows: gpu.windows, batches: gpu.batches, extensionHash: extensionHash, gpu: true),
            batches: stages.flatMap(\.batches) + cpu.batches + gpu.batches,
            telemetry: stages.flatMap(\.telemetry) + cpu.telemetry + gpu.telemetry)
    }

    private static var acceleratorRows: [MSeriesV11Accelerator] {
        let rows: [(String, String, String?)] = [
            ("media.h264.encode", "available", nil),
            ("media.av1.decode", "unsupported", "noSuchUnit"),
            ("gpu.hardwareRayTracing.traversal", "unknown", "allocationEvidenceUnknown"),
            ("gpu.tensor.fp16", "unavailable", "fixtureResourceUnavailable"),
            ("ai.smallModel.aneCandidate", "notImplemented", "phase2")
        ]
        return rows.map { id, availability, reason in
            let samples = [BenchmarkV7RawSample](repeating:
                .init(value: 284, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 1), count: 3)
            let metric: MSeriesV11Metric? = availability == "available" ? .init(id: id,
                contract: .init(unit: "MPix/s", timing: "wall-monotonic",
                    statisticsVersion: "debug-layout-only", workloadHash: extensionHash),
                availability: "available", reasonCode: nil, samples: samples,
                environment: [nominal], usedWallClockFallback: false) : nil
            return .init(id: id, availability: availability, reasonCode: reason, metric: metric,
                allocationEvidence: availability == "available" ? "debug-synthetic-hardware" : nil,
                allocationEvidenceKind: availability == "available" ? "debug-only" : nil,
                fixtureVersion: "debug-layout-only", fixtureSHA256: nil)
        }
    }

    private static func syntheticReference(provisional: Bool) -> MSeriesReferenceV11.Loaded {
        let demonstration = extensionData(helper: true)
        let metricValues = Dictionary(uniqueKeysWithValues: MSeriesProtocol.coreIDs.enumerated()
            .map { ($0.element, coreValues[$0.offset]) })
        let tail = demonstration.gpu.tail30Metric?.statistics?.median ?? 2_432
        let efficiency = demonstration.points.first { $0.id == "power.cpu.allCores" }?
            .efficiency?.statistics?.median ?? (1_258.6 / 34)
        let medians: [String: MSeriesReferenceV11.Median] = Dictionary(uniqueKeysWithValues:
            MSeriesScoringV11.inputIDs.map { id in
                let measured = metricValues[id] ?? (id == MSeriesScoringV11.peakID ? 2_560 :
                    id == MSeriesScoringV11.sustainedID ? tail : efficiency)
                let ratio = id.hasPrefix("cpu.single.") ? 1.5 : id.hasPrefix("cpu.multi.") ? 1.8 :
                    id.hasPrefix("gpu.") ? 1.6 : id.hasPrefix("memory.") ? 1.45 : 1.7
                let value: Double = provisional ? measured :
                    id == MSeriesScoringV11.peakID || id == MSeriesScoringV11.sustainedID ? 1_600 :
                    id == MSeriesScoringV11.efficiencyID ? (1_258.6 / 1.8 / 24) :
                    id == "memory.pointerChase" ? measured * ratio : measured / ratio
                return (id, .init(median: value,
                    contract: MSeriesScoringV11.metricContract(id, extensionHash: extensionHash),
                    perRunMedians: Array(repeating: value, count: 8), perRunCV: Array(repeating: 0, count: 8)))
            })
        let sessions: [MSeriesReferenceV11.Session] = (0..<2).map { session in
            .init(id: fixedID(100 + session), runs: (0..<4).map { run in
                let start = epoch.addingTimeInterval(Double(session * 2_000 + run * 100))
                return .init(id: fixedID(200 + session * 4 + run), startedAt: start,
                    completedAt: start.addingTimeInterval(50), environment: [nominal])
            })
        }
        let artifact = Data("DEBUG layout reference; no measured or activated M1 data".utf8)
        let reference = MSeriesReferenceV11(schema: "reference-v11",
            version: provisional ? "debug-layout-m5-pro" : "debug-layout-m1",
            status: provisional ? .provisional : .final, provisionalAgainst: provisional ? "Apple M5 Pro" : nil,
            scoringVersion: MSeriesScoringV11.version, coreContractHash: MSeriesProtocol.contractHash,
            extensionContractHash: extensionHash, scoringContractHash: MSeriesScoringV11.scoringContractHash,
            referenceHardware: .init(chipID: provisional ? "m5-pro" : "m1", modelIdentifier: "Debug Layout Reference",
                cpuTotal: provisional ? 18 : 8, gpuCores: provisional ? 20 : 8,
                memoryBytes: 16 * 1_024 * 1_024 * 1_024, storageCapacityBytes: 512 * 1_024 * 1_024 * 1_024,
                cooling: "synthetic"), timingPolicy: "gpu-timeline-and-aligned-wall-v11.1",
            powerPolicy: "helper-powermetrics-cpu-package-v11.1",
            independentRunIDs: sessions.flatMap { $0.runs.map(\.id) }, sessions: sessions, medians: medians,
            crossRunCV: medians.mapValues { MSeriesScoringV11.coefficientOfVariation($0.perRunMedians) ?? 0 },
            sourceArtifacts: [.init(relativePath: "debug-layout-only.json", sha256: MSeriesV11Digest.sha256(artifact))],
            frozenAt: epoch.addingTimeInterval(3_000))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode(reference)
            let loaded = MSeriesReferenceV11.load(bytes: bytes,
                manifest: .init(version: reference.version, sha256: MSeriesV11Digest.sha256(bytes)),
                sourceBytes: ["debug-layout-only.json": artifact])
            precondition(loaded.reference != nil, "Debug layout reference must validate in memory")
            return loaded
        } catch {
            preconditionFailure("Debug layout reference cannot be encoded: \(error)")
        }
    }

    private static func preflight() -> BenchmarkV7PreflightReport {
        .init(capturedAt: epoch, powerSource: .acPower, batteryPercent: 100,
            lowPowerModeEnabled: false, thermalState: .nominal, backgroundLoadRatio: 0,
            availableMemoryBytes: 24 * 1_024 * 1_024 * 1_024,
            storageTarget: .init(volumeName: "Debug Synthetic Volume", fileSystem: "APFS",
                availableBytes: 512 * 1_024 * 1_024 * 1_024, isReadOnly: false),
            displayDescription: "Debug layout only", checks: [], blockedCategories: [])
    }

    private static func legacyV9() -> BenchmarkV7Result {
        let official = OfficialBenchmarkPlan.legacyV9
        let preflight = preflight()
        let metrics: [BenchmarkV7MetricResult] = BenchmarkV7Category.corePerformance.map { category in
            let samples = [BenchmarkV7RawSample](repeating:
                .init(value: 100, elapsedSeconds: 1, wallElapsedSeconds: 1, checksum: 1), count: 3)
            do {
                return .init(manifest: .init(id: "debug.legacy.\(category.rawValue)", category: category,
                    unit: category == .memory || category == .storage ? "GB/s" : "Mops/s",
                    direction: .higherIsBetter, weight: 1, workloadVersion: official.plan.workloadVersion),
                    samples: samples, statistics: try BenchmarkStatistics.summarize(samples.map(\.value)))
            } catch {
                preconditionFailure("Debug legacy samples cannot be summarized: \(error)")
            }
        }
        return .init(session: .init(plan: official.plan, categories: official.categories,
                storageTarget: preflight.storageTarget, startedAt: epoch),
            preflight: preflight, versions: BenchmarkV7ReferenceCatalog.versions(for: official.plan),
            metrics: metrics,
            coreScore: .init(categoryScores: Dictionary(uniqueKeysWithValues:
                BenchmarkV7Category.corePerformance.map { ($0, .init(ratio: 1, score: 6_000)) }), overallScore: 6_000),
            experienceScore: .init(metricRatios: Dictionary(uniqueKeysWithValues:
                metrics.map { ($0.manifest.id, 1) }), overallScore: 6_000),
            runtimeWarnings: ["debugSyntheticLegacyLayoutOnly"], completedAt: epoch.addingTimeInterval(360), failure: nil)
    }

    private static func fixedID(_ value: Int) -> UUID {
        guard let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", Int64(value))) else {
            preconditionFailure("Invalid debug fixture ID")
        }
        return id
    }
}
#endif
