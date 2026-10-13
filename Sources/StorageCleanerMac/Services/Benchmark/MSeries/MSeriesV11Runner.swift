import Foundation

enum MSeriesV11Protocol {
    static let extensions = "mseries-efficiency-sustained-v11.1"
    // A separate extension contract: the unchanged v10 Core hash is not repurposed.
    static let contract = "mseries-efficiency-sustained-v11.1;clock:mach-continuous-v1;cpu:integer262144u64,pilot1,locked150ms,workers1-highestPhysical-allLogical,10s,thirds;gpu:Metal3D1920x1080,262144cubes,12triangles,fixed1frame,30s,3x10s;standard:cpu90-gpu90,5s;pressure:cpu300-gpu300,5s,rawOnly;retention:median-last30/median-first10;power:shared-helper-measured-intervals,requestStart2s,80pctIndependentSamples,overlap-work-joules,noInterpolation;warmup2s;deadline:15-35-95,standard480,pressure660;thermal:serious-critical-stop-drain;validation:outside-timing;write:512MiB,metadata2MiB,final1MiB"
    static var contractHash: String { MSeriesV11Digest.sha256(Data(contract.utf8)) }
    static func plan(mode: String) -> BenchmarkV7Plan {
        .init(kind: .standard, planVersion: mode == "pressure10m" ? "mseries-pressure-v11" : "mseries-core-v11",
            workloadVersion: MSeriesProtocol.workload, expectedMinimumDurationSeconds: mode == "pressure10m" ? 600 : 420,
            expectedMaximumDurationSeconds: mode == "pressure10m" ? 660 : 480, categories: BenchmarkV7Category.corePerformance)
    }
    static func versions(mode: String) -> BenchmarkV7VersionManifest {
        .init(schemaVersion: "mseries-result-v11", planVersion: plan(mode: mode).planVersion,
            workloadVersion: MSeriesProtocol.workload, cpuWorkloadVersion: MSeriesProtocol.implementation,
            gpuWorkloadVersion: MSeriesProtocol.implementation, memoryWorkloadVersion: MSeriesProtocol.implementation,
            storageWorkloadVersion: MSeriesProtocol.implementation, displayWorkloadVersion: "extension-not-implemented",
            statisticsVersion: "mseries-window-cv-v11.1", scoringVersion: MSeriesScoringV11.version,
            referenceSetVersion: "unavailable-raw-only")
    }
}

enum MSeriesV11RunError: Error, Equatable { case timeout, thermalProtection, clockInvalid, invalidBatch, warmupTimeout, metadataBudget, evidenceBudgetForecast }

struct MSeriesV11Dependencies: Sendable {
    var now: @Sendable () -> UInt64 = { MSeriesV11Clock.nanoseconds }
    var sleep: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    var environment: @Sendable () async -> MSeriesV11Observation = {
        let point = MSeriesEnvironmentPoint.capture()
        let hardware = MSeriesHardware.capture()
        let readings = AppleSiliconTemperatureService.currentTemperatureReadings()
        return .init(atMonotonicNs: MSeriesV11Clock.nanoseconds,
            cpuTemperatureC: AppleSiliconTemperatureService.chipTemperatureCelsius(from: readings),
            gpuTemperatureC: AppleSiliconTemperatureService.regionalTemperatures(from: readings).first { $0.zone == .gpu }?.celsius,
            environment: .init(releaseBuild: hardware.releaseBuild, nativeARM64: hardware.nativeARM64,
                translated: hardware.translated, powerSource: point.powerSource, powerChanged: false,
                lowPower: point.lowPower, thermalState: point.thermalState))
    }
    var identity: @Sendable () async -> AppleSiliconIdentity? = {
        await Task.detached(priority: .utility) {
            AppleSiliconIdentifier.identify(AppleSiliconHardwareCollector.capture(), catalog: AppleSiliconCatalogLoader.load())
        }.value
    }
    var telemetry: @Sendable () async -> [MSeriesV11Telemetry] = { [] }
    var telemetryReasons: @Sendable () async -> [String] = { ["helperUnavailable"] }
    var beginTelemetry: @Sendable () async -> Void = {}
    var beginTelemetrySession: @Sendable (UUID) async -> Void = { _ in }
    var finishTelemetry: @Sendable () async -> Void = {}
    var onEvidenceBudgetForecast: @Sendable (MSeriesV11BudgetForecast) async -> Void = { _ in }
    var onLiveObservation: @Sendable (MSeriesV11LiveObservation) async -> Void = { _ in }
    var driverFactory: @Sendable () -> any MSeriesV11BatchDriving = { SystemMSeriesV11BatchDriver() }
    var core: @Sendable (UUID, URL, CleanupReportJournal?, MSeriesCancellation, UInt64,
        @escaping @Sendable (UUID, String, Int) async -> Void) async -> MSeriesResult = { session, root, journal, cancellation, deadline, progress in
        await MSeriesCoreRunner.run(sessionID: session, root: root, resourceJournal: journal,
            includeLegacyExtensions: false, cancellation: cancellation, dispatchDeadlineNanoseconds: deadline, progress: progress)
    }
    var accelerators: @Sendable ([MSeriesV11AcceleratorUnit], MSeriesCancellation) async -> [MSeriesV11Accelerator] = { units, cancellation in
        let identity = await AppleSiliconHardwareCollector.captureAsync()
        let loaded = AppleSiliconCatalogLoader.load()
        let chip = loaded.catalog?.chips.first { AppleSiliconIdentifier.normalizedName($0.marketingName)
            == AppleSiliconIdentifier.normalizedName(identity.brandString ?? "") }
        let capabilities = SystemMacAcceleratorWorkloadRunner.v11Capabilities(catalogChip: chip)
        let suite = MSeriesV11Accelerators(runner: SystemMacAcceleratorWorkloadRunner(), checkEnvironment: {
            if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical { throw MSeriesV11AcceleratorError.thermalProtection }
        })
        var results: [MSeriesV11Accelerator] = []
        for unit in units {
            if cancellation.isCancelled || Task.isCancelled { break }
            let budget = MSeriesHardware.capture().sharedBudgetBytes
            let measured = await suite.measure(unit, capabilities: capabilities,
                maximumEncodedBytes: Int(min(UInt64(VideoMediaBenchmarkKernel.maximumEncodedBytes), budget)))
            results += measured.map { $0.result() }
        }
        return results
    }
}

private actor MSeriesV11RunLedger {
    var batches: [MSeriesV11Batch] = []
    var observations: [String: [MSeriesV11Observation]] = [:]
    private var retainedCore: MSeriesResult?
    func retainCore(_ result: MSeriesResult) { retainedCore = result }
    func coreEvidence() -> MSeriesResult? { retainedCore }
    func append(_ batch: MSeriesV11Batch) { batches.append(batch) }
    func observe(_ observation: MSeriesV11Observation, stage: String) { observations[stage, default: []].append(observation) }
    func stageBatches(_ id: String) -> [MSeriesV11Batch] { batches.filter { $0.stageID == id } }
    func stageObservations(_ id: String) -> [MSeriesV11Observation] { observations[id] ?? [] }
    func allBatches() -> [MSeriesV11Batch] { batches }
    func environments() -> [String: [MSeriesV11Environment]] { observations.mapValues { $0.map(\.environment) } }
    func budgetSnapshot(_ template: MSeriesV11Result) -> MSeriesV11Result {
        var result = template
        result.workloadBatches = batches
        result.perStageEnvironment = environments()
        return result
    }
}

/// Runs under the existing coordinator's single lease; every submitted operation is awaited.
struct MSeriesV11Runner: Sendable {
    struct Output: Sendable { let core: MSeriesResult?; let envelope: MSeriesV11Result }
    let dependencies: MSeriesV11Dependencies
    init(dependencies: MSeriesV11Dependencies = .init()) { self.dependencies = dependencies }

    func run(sessionID: UUID, mode: String = "standard", acceleratorSelection: [MSeriesV11AcceleratorUnit] = [],
             root: URL, resourceJournal: CleanupReportJournal?,
             progress: @escaping @Sendable (String, Int) async -> Void = { _, _ in }) async -> Output {
        let cancellation = MSeriesCancellation(clock: dependencies.now)
        return await withTaskCancellationHandler {
            await execute(sessionID: sessionID, mode: mode, acceleratorSelection: acceleratorSelection, root: root, resourceJournal: resourceJournal,
                cancellation: cancellation, progress: progress)
        } onCancel: { cancellation.cancel() }
    }

    private func execute(sessionID: UUID, mode: String, acceleratorSelection: [MSeriesV11AcceleratorUnit], root: URL, resourceJournal: CleanupReportJournal?,
                         cancellation: MSeriesCancellation, progress: @escaping @Sendable (String, Int) async -> Void) async -> Output {
        let start = dependencies.now()
        let deadlineSeconds = mode == "pressure10m" ? 660 : 480
        let deadline = start.addingReportingOverflow(UInt64(deadlineSeconds) * 1_000_000_000)
        let ledger = MSeriesV11RunLedger()
        var envelope = MSeriesV11Result(sessionID: sessionID, extensionContractHash: MSeriesV11Protocol.contractHash, rawPayloadSHA256: "", mode: mode)
        envelope.startedAt = Date()
        envelope.dispatchDeadlineSeconds = Double(deadlineSeconds)
        await dependencies.beginTelemetry()
        await dependencies.beginTelemetrySession(sessionID)
        let livePublisher = MSeriesV11LivePublisher(sessionID: sessionID, telemetry: dependencies.telemetry, publish: dependencies.onLiveObservation)
        defer { livePublisher.finish() }
        var core: MSeriesResult?
        var terminalError: String?
        var active: (id: String, start: UInt64, duration: Int, count: Int, gpu: Bool, workers: Int, type: String)?
        do {
            guard ["standard", "pressure10m"].contains(mode), !deadline.overflow else { throw MSeriesV11RunError.clockInvalid }
            await progress("preflight", 0)
            envelope.preflight = await dependencies.environment().environment
            try check(observation: envelope.preflight!, cancellation: cancellation, deadline: deadline.partialValue)
            envelope.hardwareIdentity = try await guarded(stage: "preflight", deadline: min(deadline.partialValue, start + 5_000_000_000),
                cancellation: cancellation, ledger: ledger) { await dependencies.identity() }
            if envelope.preflight?.nativeARM64 == false || envelope.preflight?.translated == true {
                terminalError = "native-arm64-required"
            } else if mode == "standard" {
                await progress("core", 0)
                core = try await guarded(stage: "core", deadline: min(deadline.partialValue, dependencies.now() + 180_000_000_000),
                    cancellation: cancellation, ledger: ledger) {
                    let measured = await dependencies.core(sessionID, root, resourceJournal, cancellation,
                        min(deadline.partialValue, dependencies.now() + 180_000_000_000)) { _, id, index in await progress(id, index) }
                    // Retain drained partial evidence before the outer cancellation
                    // check throws. The measured operation itself is unchanged.
                    await ledger.retainCore(measured)
                    return measured
                }
                if core?.isCompleteCore != true { terminalError = core?.globalFailure ?? (core?.cancelled == true ? "cancelled" : "coreIncomplete") }
            }
            if terminalError == nil {
                let identity = envelope.hardwareIdentity?.identificationEvidence
                let logical = identity?.perfLevels.compactMap(\.logicalCores).reduce(0, +) ?? core?.hardware.logicalCores ?? ProcessInfo.processInfo.processorCount
                let levels = identity?.perfLevels ?? []
                func type(_ name: String?) -> String? {
                    let tokens = (name ?? "").lowercased().split { !$0.isLetter }
                    if tokens.contains("super") { return "super" }
                    if tokens.contains("performance") { return "performance" }
                    return nil
                }
                let highestType = levels.contains { type($0.name) == "super" } ? "super" : "performance"
                let highest = levels.filter { type($0.name) == highestType }.compactMap(\.physicalCores).reduce(0, +)
                let stages: [(String, Int, Int, Bool, Int, String)] = mode == "pressure10m" ? [
                    ("pressure.cpu.allCores", 300, 60, false, logical, "allLogical"), ("pressure.gpu", 300, 60, true, 1, "gpu")
                ] : [
                    ("power.cpu.single", 10, 3, false, 1, "single"),
                    ("power.cpu.performanceCores", 10, 3, false, highest, highestType),
                    ("power.cpu.allCores", 10, 3, false, logical, "allLogical"),
                    ("power.gpu.peak", 30, 3, true, 1, "gpu"),
                    ("sustained.cpu.allCores", 90, 18, false, logical, "allLogical"),
                    ("sustained.gpu", 90, 18, true, 1, "gpu")
                ]
                for (id, duration, count, gpu, workers, coreType) in stages {
                    await progress(id, MSeriesProtocol.coreIDs.count)
                    let stageStart = dependencies.now()
                    guard workers > 0 else {
                        envelope.efficiencyPoints.append(.init(id: id, throughput: nil, efficiency: nil, resolvedWorkers: nil,
                            coreType: coreType, meanPowerW: nil, matchedWorkUnits: nil, joules: nil, expectedSampleCount: 5,
                            validSampleCount: 0, observedSeconds: nil, timestampQuality: "legacyUntimed", alignmentQuality: "unavailable",
                            missingReasons: ["highestPerformanceTopologyUnknown"], frequencies: [], windows: []))
                        envelope.missingReasons.append("highestPerformanceTopologyUnknown")
                        continue
                    }
                    let driver = dependencies.driverFactory()
                    let stageDeadline = min(deadline.partialValue, stageStart + UInt64(duration + 5) * 1_000_000_000)
                    var measuringStart = stageStart
                    do {
                        try await guarded(stage: id, deadline: stageDeadline, cancellation: cancellation, ledger: ledger) {
                            try await driver.prepare(id: id, workers: workers, cancellation: cancellation)
                        }
                        measuringStart = dependencies.now()
                        active = (id, measuringStart, duration, count, gpu, workers, coreType)
                        let measurementOrigin = measuringStart
                        let measurementEnd = measurementOrigin + UInt64(duration) * 1_000_000_000
                        let budgetTemplate = envelope
                        let coreSnapshot = core
                        let measuredBeforeStage = envelope.measuredDurationSeconds ?? 0
                        let plannedSeconds = mode == "pressure10m" ? 600.0 : 240.0
                        try await guarded(stage: id, deadline: stageDeadline, cancellation: cancellation, ledger: ledger) {
                            var previousEnd = measurementOrigin
                            var nextBudgetCheck = measurementOrigin + 5_000_000_000
                            while dependencies.now() < measurementEnd {
                                let observation = await dependencies.environment()
                                try check(observation: observation.environment, cancellation: cancellation, deadline: stageDeadline)
                                await ledger.observe(observation, stage: id)
                                let batch = try await driver.next(id: id, cancellation: cancellation)
                                guard batch.isValid, batch.stageID == id, batch.startMonotonicNs >= previousEnd,
                                      dependencies.now() >= batch.endMonotonicNs else { throw MSeriesV11RunError.invalidBatch }
                                await ledger.append(batch)
                                previousEnd = batch.endMonotonicNs
                                if dependencies.now() >= nextBudgetCheck {
                                    let snapshot = await ledger.budgetSnapshot(budgetTemplate)
                                    let measured = measuredBeforeStage + MSeriesV11Windows.seconds(measurementOrigin, dependencies.now())
                                    let forecast = try await Task.detached(priority: .utility) {
                                        try MSeriesV11EvidenceBudget.forecast(snapshot, core: coreSnapshot,
                                            measuredSeconds: measured, plannedSeconds: plannedSeconds)
                                    }.value
                                    await dependencies.onEvidenceBudgetForecast(forecast)
                                    // Reuse the existing five-second observation boundary.
                                    // The current C/Metal batch has already completed.
                                    let liveEnd = dependencies.now()
                                    livePublisher.submit(.init(sessionID: sessionID, stageID: id,
                                        batches: snapshot.workloadBatches, end: liveEnd, gpu: gpu))
                                    guard forecast.projectedStorageBytes <= MSeriesV11EvidenceBudget.maximumProjectedEvidenceBytes else {
                                        throw MSeriesV11RunError.evidenceBudgetForecast
                                    }
                                    nextBudgetCheck = dependencies.now() + 5_000_000_000
                                }
                            }
                        }
                    } catch {
                        let drainStart = dependencies.now()
                        await driver.finish()
                        envelope.drainDurationSeconds = (envelope.drainDurationSeconds ?? 0) + MSeriesV11Windows.seconds(drainStart, dependencies.now())
                        throw error
                    }
                    await driver.finish()
                    await recordStage(active!, finishedAt: dependencies.now(), ledger: ledger, envelope: &envelope)
                    active = nil
                }
                if terminalError == nil, !acceleratorSelection.isEmpty {
                    await progress("accelerators", MSeriesProtocol.coreIDs.count)
                    let acceleratorDeadline = dependencies.now() + UInt64(acceleratorSelection.reduce(0) { $0 + $1.collectionDeadlineSeconds }) * 1_000_000_000
                    envelope.accelerators = try await guarded(stage: "accelerators", deadline: acceleratorDeadline,
                        cancellation: cancellation, ledger: ledger) {
                        await dependencies.accelerators(acceleratorSelection, cancellation)
                    }
                }
            }
        } catch {
            if core == nil { core = await ledger.coreEvidence() }
            if let active { await recordStage(active, finishedAt: dependencies.now(), ledger: ledger, envelope: &envelope) }
            terminalError = error is CancellationError ? "cancelled" : String(describing: error)
        }
        if let requestedAt = cancellation.requestedAtNanoseconds {
            envelope.drainDurationSeconds = MSeriesV11Windows.seconds(requestedAt, dependencies.now())
        }
        livePublisher.finish()
        envelope.workloadBatches = await ledger.allBatches()
        envelope.perStageEnvironment = await ledger.environments()
        envelope.postflight = await dependencies.environment().environment
        envelope.telemetry = await dependencies.telemetry()
        envelope.missingReasons += await dependencies.telemetryReasons()
        await dependencies.finishTelemetry()
        envelope.telemetryAvailability = envelope.telemetry.isEmpty ? "unavailable" : "available"
        envelope.elapsedSeconds = MSeriesV11Windows.seconds(start, dependencies.now())
        envelope.measuredDurationSeconds = envelope.measuredDurationSeconds ?? 0
        envelope.completedAt = Date()
        envelope.state = terminalError == "cancelled" ? "cancelled" : terminalError == nil && envelope.hasCompletedRequiredMeasurements ? "completed" : "partial"
        envelope.failure = terminalError
        if terminalError == "cancelled" { envelope.cancellationRequestedAt = cancellation.requestedAt }
        if let terminalError { envelope.missingReasons.append(terminalError) }
        envelope.writtenBytes = core?.writtenBytes ?? 0
        envelope.scores = core.map { MSeriesScoringV11.evaluate(metrics: MSeriesScoringV11.inputs(core: $0, envelope: envelope),
            reference: .unavailable, extensionHash: envelope.extensionContractHash, mode: mode) }
        do {
            let sealed = try MSeriesV11RawPayload.seal(core: core, envelope: envelope)
            envelope = sealed
        } catch {
            envelope.state = "partial"; envelope.failure = "metadataBudget"
            envelope.missingReasons.append("metadataBudget")
            // Keep the evidence in memory; persistence must reject an over-budget result.
        }
        return Output(core: core, envelope: envelope)
    }

    private func check(observation: MSeriesV11Environment, cancellation: MSeriesCancellation, deadline: UInt64) throws {
        if dependencies.now() >= deadline { throw MSeriesV11RunError.timeout }
        if observation.thermalState == 2 || observation.thermalState == 3 { throw MSeriesV11RunError.thermalProtection }
        if Task.isCancelled || cancellation.isCancelled { throw CancellationError() }
    }

    private func guarded<T: Sendable>(stage: String, deadline: UInt64, cancellation: MSeriesCancellation,
                                      ledger: MSeriesV11RunLedger, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                while !Task.isCancelled {
                    let observation = await dependencies.environment()
                    // Completing a stage cancels only its watcher, never the run token.
                    if Task.isCancelled { return nil }
                    await ledger.observe(observation, stage: stage)
                    do { try check(observation: observation.environment, cancellation: cancellation, deadline: deadline) }
                    catch {
                        if Task.isCancelled { return nil }
                        cancellation.cancel(); throw error
                    }
                    do { try await dependencies.sleep() }
                    catch { if Task.isCancelled { return nil }; throw error }
                }
                return nil
            }
            do {
                while let value = try await group.next() {
                    if let value {
                        try check(observation: await dependencies.environment().environment, cancellation: cancellation, deadline: deadline)
                        group.cancelAll(); return value
                    }
                }
                throw CancellationError()
            } catch { cancellation.cancel(); group.cancelAll(); throw error }
            // Structured concurrency waits for the worker and watcher before leaving scope.
        }
    }

    private func recordStage(_ stage: (id: String, start: UInt64, duration: Int, count: Int, gpu: Bool, workers: Int, type: String),
                             finishedAt: UInt64, ledger: MSeriesV11RunLedger, envelope: inout MSeriesV11Result) async {
        envelope.measuredDurationSeconds = (envelope.measuredDurationSeconds ?? 0)
            + min(Double(stage.duration), MSeriesV11Windows.seconds(stage.start, finishedAt))
        let batches = await ledger.stageBatches(stage.id)
        let telemetry = await dependencies.telemetry()
        let windows = MSeriesV11Windows.windows(id: stage.id, start: stage.start, durationSeconds: stage.duration,
            count: stage.count, finishedAt: finishedAt, batches: batches, telemetry: telemetry,
            observations: await ledger.stageObservations(stage.id), gpu: stage.gpu)
        if stage.id.hasPrefix("power.") {
            envelope.efficiencyPoints.append(MSeriesV11Windows.efficiencyPoint(id: stage.id, workers: stage.workers, coreType: stage.type,
                windows: windows, batches: batches, telemetry: telemetry, extensionHash: envelope.extensionContractHash))
        } else {
            let sustained = MSeriesV11Windows.sustained(id: stage.id, duration: stage.duration, windows: windows, batches: batches,
                extensionHash: envelope.extensionContractHash, gpu: stage.gpu)
            if stage.gpu { envelope.sustainedGPU = sustained } else { envelope.sustainedCPU = sustained }
        }
    }
}

/// Digest covers expanded canonical evidence after helper identity redaction,
/// excluding itself, reference-dependent display caches and the write ledger.
/// Legacy envelopes with IDs retain their original digest when read/validated;
/// a subsequent save reseals the privacy-safe evidence before writing.
enum MSeriesV11RawPayload {
    private struct Payload: Codable { let core: MSeriesResult?; let envelope: MSeriesV11Result }
    static func bytes(core: MSeriesResult?, envelope: MSeriesV11Result) throws -> Data {
        var raw = envelope
        raw = withoutDigest(raw)
        raw.scores = nil; raw.referenceIdentity = nil; raw.derivedCacheKey = nil
        raw.metadataWrittenBytes = nil
        raw.writtenBytes = core?.writtenBytes ?? 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[MSeriesV11CompactStorage.expandedEncoding] = true
        return try encoder.encode(Payload(core: core, envelope: raw))
    }
    private static func withoutDigest(_ envelope: MSeriesV11Result) -> MSeriesV11Result {
        // The immutable digest has a dedicated copy initializer below.
        envelope.replacingRawDigest("")
    }
    static func seal(core: MSeriesResult?, envelope unredacted: MSeriesV11Result) throws -> MSeriesV11Result {
        var envelope = unredacted
        envelope.telemetry = MSeriesV11Telemetry.forPersistence(unredacted.telemetry)
        let data = try bytes(core: core, envelope: envelope)
        guard envelope.telemetry.count <= 1024,
              (core?.writtenBytes ?? 0) <= 510 * 1024 * 1024 else { throw MSeriesV11RunError.metadataBudget }
        var result = envelope.replacingRawDigest(MSeriesV11Digest.sha256(data))
        // Budget actual storage bytes, while the unchanged SHA input may be a
        // larger, fully expanded in-memory representation.
        for _ in 0..<5 {
            let size = try JSONEncoder().encode(result).count
            guard size <= 1_048_576 else { throw MSeriesV11RunError.metadataBudget }
            let metadata = UInt64(size * 2)
            if result.metadataWrittenBytes == metadata { break }
            result.metadataWrittenBytes = metadata
            result.writtenBytes = (core?.writtenBytes ?? 0) + metadata
        }
        return result
    }
    static func validates(core: MSeriesResult?, envelope: MSeriesV11Result) -> Bool {
        guard let bytes = try? bytes(core: core, envelope: envelope) else { return false }
        return MSeriesV11Digest.sha256(bytes) == envelope.rawPayloadSHA256
    }
}
