import Foundation

struct MacBenchmarkDiskSamplePair: Equatable, Sendable {
    let write: BenchmarkComponentSample
    let read: BenchmarkComponentSample
}

protocol MacBenchmarkWorkloadRunning: Sendable {
    func requiredDiskBytes(for profile: BenchmarkProfile) -> Int64
    func cleanupTemporaryArtifacts() async throws
    func runCPUSingle(profile: BenchmarkProfile) async throws -> BenchmarkComponentSample
    func runCPUMulti(
        profile: BenchmarkProfile,
        activeProcessorCount: Int
    ) async throws -> BenchmarkComponentSample
    func runGPU(profile: BenchmarkProfile) async throws -> BenchmarkComponentSample
    func runMemory(profile: BenchmarkProfile) async throws -> BenchmarkComponentSample
    func runDisk(profile: BenchmarkProfile) async throws -> MacBenchmarkDiskSamplePair
}

struct SystemMacBenchmarkWorkloadRunner: MacBenchmarkWorkloadRunning {
    private let cpuKernel: CPUBenchmarkKernel
    private let memoryKernel: MemoryBenchmarkKernel
    private let metalKernel: MetalBenchmarkKernel
    private let metal3DKernel: Metal3DBenchmarkKernel
    private let diskKernel: DiskBenchmarkKernel

    init(
        cpuKernel: CPUBenchmarkKernel = CPUBenchmarkKernel(),
        memoryKernel: MemoryBenchmarkKernel = MemoryBenchmarkKernel(),
        metalKernel: MetalBenchmarkKernel = MetalBenchmarkKernel(),
        metal3DKernel: Metal3DBenchmarkKernel = Metal3DBenchmarkKernel(),
        diskKernel: DiskBenchmarkKernel = DiskBenchmarkKernel()
    ) {
        self.cpuKernel = cpuKernel
        self.memoryKernel = memoryKernel
        self.metalKernel = metalKernel
        self.metal3DKernel = metal3DKernel
        self.diskKernel = diskKernel
    }

    func requiredDiskBytes(for profile: BenchmarkProfile) -> Int64 {
        let fileBytes = diskKernel.configuration.limits(for: profile).fileBytes
        return DiskBenchmarkKernel.requiredCapacity(forFileBytes: fileBytes)
    }

    func cleanupTemporaryArtifacts() async throws {
        _ = try await diskKernel.cleanupOrphans(olderThan: 24 * 60 * 60)
    }

    func runCPUSingle(profile: BenchmarkProfile) async throws
        -> BenchmarkComponentSample
    {
        try await cpuKernel.runSingle(profile: profile).sample
    }

    func runCPUMulti(
        profile: BenchmarkProfile,
        activeProcessorCount: Int
    ) async throws -> BenchmarkComponentSample {
        try await cpuKernel.runMulti(
            profile: profile,
            activeProcessorCount: activeProcessorCount
        ).sample
    }

    func runGPU(profile: BenchmarkProfile) async throws -> BenchmarkComponentSample {
        switch profile {
        case .standard:
            try await metal3DKernel.run().sample
        case .quick, .full:
            try await metalKernel.run(profile: profile).sample
        }
    }

    func runMemory(profile: BenchmarkProfile) async throws
        -> BenchmarkComponentSample
    {
        try await memoryKernel.run(profile: profile).sample
    }

    func runDisk(profile: BenchmarkProfile) async throws -> MacBenchmarkDiskSamplePair {
        let result = try await diskKernel.run(profile: profile)
        return MacBenchmarkDiskSamplePair(
            write: result.writeSample,
            read: result.readSample
        )
    }
}

protocol MacBenchmarkEnvironmentProviding: Sendable {
    func metadata(preflight: BenchmarkPreflight) -> BenchmarkEnvironmentMetadata
}

struct SystemMacBenchmarkEnvironmentProvider: MacBenchmarkEnvironmentProviding {
    func metadata(preflight: BenchmarkPreflight) -> BenchmarkEnvironmentMetadata {
        let processInfo = ProcessInfo.processInfo
        let rawChipName = CPUPerformanceStateService.staticSnapshot()?.processorModel
            ?? "Mac"
        let chipName = rawChipName.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = Bundle.main.infoDictionary
        let appVersion = nonemptyString(info?["CFBundleShortVersionString"])
            ?? "development"
        let appBuild = nonemptyString(info?["CFBundleVersion"]) ?? "development"
        let operatingSystemVersion = processInfo.operatingSystemVersionString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return BenchmarkEnvironmentMetadata(
            architecture: .current,
            chipName: chipName.isEmpty ? "Mac" : chipName,
            activeProcessorCount: max(1, processInfo.activeProcessorCount),
            physicalMemoryBytes: max(1, processInfo.physicalMemory),
            systemDiskCapacityBytes: systemDiskCapacityBytes(),
            powerSource: preflight.powerSource,
            thermalState: preflight.thermalState,
            operatingSystemVersion: operatingSystemVersion.isEmpty
                ? "macOS"
                : operatingSystemVersion,
            appVersion: appVersion,
            appBuild: appBuild
        )
    }

    private func systemDiskCapacityBytes() -> UInt64? {
        let fileManager = FileManager.default
        var probeURL = DiskBenchmarkKernel.defaultRootDirectory.standardizedFileURL
        while !fileManager.fileExists(atPath: probeURL.path) {
            let parent = probeURL.deletingLastPathComponent()
            guard parent.path != probeURL.path else { return nil }
            probeURL = parent
        }
        guard let attributes = try? fileManager.attributesOfFileSystem(
            forPath: probeURL.path
        ), let size = attributes[.systemSize] as? NSNumber else {
            return nil
        }
        let value = size.uint64Value
        return value > 0 ? value : nil
    }

    private func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct MacBenchmarkStageTimeouts: Equatable, Sendable {
    let preflight: Duration
    let cpuSingle: Duration
    let cpuMulti: Duration
    let gpu: Duration
    let memory: Duration
    let diskWrite: Duration
    let diskRead: Duration
    let finalizing: Duration

    static let standard = Self(
        preflight: .seconds(30),
        cpuSingle: .seconds(130),
        cpuMulti: .seconds(130),
        gpu: .seconds(180),
        memory: .seconds(150),
        diskWrite: .seconds(330),
        diskRead: .seconds(330),
        finalizing: .seconds(30)
    )

    static func testing(milliseconds: Int) -> Self {
        let timeout = Duration.milliseconds(max(1, milliseconds))
        return Self(
            preflight: timeout,
            cpuSingle: timeout,
            cpuMulti: timeout,
            gpu: timeout,
            memory: timeout,
            diskWrite: timeout,
            diskRead: timeout,
            finalizing: timeout
        )
    }

    func timeout(for stage: BenchmarkStage) -> Duration {
        switch stage {
        case .preflight: preflight
        case .cpuSingle: cpuSingle
        case .cpuMulti: cpuMulti
        case .gpu: gpu
        case .memory: memory
        case .diskWrite: diskWrite
        case .diskRead: diskRead
        case .finalizing: finalizing
        }
    }

    var combinedDiskTimeout: Duration {
        diskWrite + diskRead
    }
}

actor MacBenchmarkService: MacBenchmarkServicing {
    static func workloadVersion(for profile: BenchmarkProfile) -> String {
        switch profile {
        case .standard: "mac-benchmark-standard-v6"
        case .quick: "mac-benchmark-quick-v3"
        case .full: "mac-benchmark-full-v3"
        }
    }

    static func sampleCount(for profile: BenchmarkProfile) -> Int {
        switch profile {
        case .standard, .quick: 3
        case .full: 5
        }
    }

    static func cpuMultiRecoveryDelay(for profile: BenchmarkProfile) -> Duration {
        switch profile {
        case .standard, .quick: .seconds(2)
        case .full: .seconds(3)
        }
    }

    private let heavyWorkCoordinator: HeavyWorkCoordinator
    private let preflightService: any MacBenchmarkPreflighting
    private let workloadRunner: any MacBenchmarkWorkloadRunning
    private let environmentProvider: any MacBenchmarkEnvironmentProviding
    private let timeouts: MacBenchmarkStageTimeouts
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> UInt64
    private let sleep: @Sendable (Duration) async throws -> Void
    private let recoverySleep: @Sendable (Duration) async throws -> Void
    private var activeRunID: UUID?

    init(
        heavyWorkCoordinator: HeavyWorkCoordinator = HeavyWorkCoordinator(),
        preflightService: any MacBenchmarkPreflighting = MacBenchmarkPreflightService(),
        workloadRunner: any MacBenchmarkWorkloadRunning = SystemMacBenchmarkWorkloadRunner(),
        environmentProvider: any MacBenchmarkEnvironmentProviding
            = SystemMacBenchmarkEnvironmentProvider(),
        timeouts: MacBenchmarkStageTimeouts = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        recoverySleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.heavyWorkCoordinator = heavyWorkCoordinator
        self.preflightService = preflightService
        self.workloadRunner = workloadRunner
        self.environmentProvider = environmentProvider
        self.timeouts = timeouts
        self.now = now
        self.monotonicNow = monotonicNow
        self.sleep = sleep
        self.recoverySleep = recoverySleep
    }

    func run(
        profile: BenchmarkProfile,
        progress: @escaping @Sendable (MacBenchmarkProgress) async -> Void = { _ in }
    ) async -> MacBenchmarkRawResult {
        let startedAt = now()
        let requiredDiskBytes = workloadRunner.requiredDiskBytes(for: profile)
        let fallbackPreflight = Self.fallbackPreflight(
            capturedAt: startedAt,
            requiredDiskBytes: requiredDiskBytes
        )
        let fallbackEnvironment = environmentProvider.metadata(
            preflight: fallbackPreflight
        )

        guard activeRunID == nil else {
            return Self.failureResult(
                profile: profile,
                startedAt: startedAt,
                preflight: fallbackPreflight,
                environment: fallbackEnvironment,
                failure: .busy(activeTask: "benchmark")
            )
        }
        guard !Task.isCancelled else {
            return Self.failureResult(
                profile: profile,
                startedAt: startedAt,
                preflight: fallbackPreflight,
                environment: fallbackEnvironment,
                failure: .cancelled
            )
        }

        let runID = UUID()
        activeRunID = runID
        let relay = MacBenchmarkProgressRelay(
            totalSampleCount: Self.sampleCount(for: profile)
                * BenchmarkComponent.allCases.count,
            startedAt: monotonicNow(),
            monotonicNow: monotonicNow,
            callback: progress
        )

        let lease: HeavyWorkCoordinator.Lease
        do {
            lease = try await heavyWorkCoordinator.acquire(owner: .benchmark)
        } catch {
            await relay.close()
            if activeRunID == runID { activeRunID = nil }
            return Self.failureResult(
                profile: profile,
                startedAt: startedAt,
                preflight: fallbackPreflight,
                environment: fallbackEnvironment,
                failure: Self.failure(from: error)
            )
        }

        var outcome = await withTaskCancellationHandler {
            await execute(
                profile: profile,
                startedAt: startedAt,
                requiredDiskBytes: requiredDiskBytes,
                fallbackPreflight: fallbackPreflight,
                fallbackEnvironment: fallbackEnvironment,
                relay: relay
            )
        } onCancel: {
            Task { await relay.close() }
        }

        if Task.isCancelled, outcome.result.failure == nil {
            await relay.close()
            outcome = ExecutionOutcome(
                result: Self.failureResult(
                    profile: profile,
                    startedAt: startedAt,
                    preflight: outcome.result.preflight,
                    environment: outcome.result.environment,
                    failure: .cancelled
                ),
                cleanup: outcome.cleanup
            )
        }

        await relay.close()
        if let cleanup = outcome.cleanup {
            await handOffCleanup(cleanup, lease: lease)
        } else {
            await heavyWorkCoordinator.release(lease)
        }
        if activeRunID == runID { activeRunID = nil }

        if Task.isCancelled, outcome.result.failure == nil {
            return Self.failureResult(
                profile: profile,
                startedAt: startedAt,
                preflight: outcome.result.preflight,
                environment: outcome.result.environment,
                failure: .cancelled
            )
        }
        return outcome.result
    }

    private func handOffCleanup(
        _ cleanup: MacBenchmarkCleanupHandle,
        lease: HeavyWorkCoordinator.Lease
    ) async {
        let coordinator = heavyWorkCoordinator
        do {
            let quarantine = try await coordinator.beginCleanupQuarantine(lease)
            await coordinator.release(lease)
            Task {
                await cleanup.wait()
                await coordinator.clearCleanupQuarantine(quarantine)
            }
        } catch {
            // A valid benchmark lease should always be quarantinable. If that
            // invariant is ever broken, retain the lease until the physical
            // worker exits instead of opening a second heavy-work slot.
            Task {
                await cleanup.wait()
                await coordinator.release(lease)
            }
        }
    }
}

private extension MacBenchmarkService {
    struct ExecutionOutcome: Sendable {
        let result: MacBenchmarkRawResult
        let cleanup: MacBenchmarkCleanupHandle?
    }

    struct DiskSamples: Sendable {
        let writes: [BenchmarkComponentSample]
        let reads: [BenchmarkComponentSample]
    }

    func execute(
        profile: BenchmarkProfile,
        startedAt: Date,
        requiredDiskBytes: Int64,
        fallbackPreflight: BenchmarkPreflight,
        fallbackEnvironment: BenchmarkEnvironmentMetadata,
        relay: MacBenchmarkProgressRelay
    ) async -> ExecutionOutcome {
        var initialPreflight = fallbackPreflight
        var environment = fallbackEnvironment

        do {
            guard requiredDiskBytes > 0 else {
                throw MacBenchmarkServiceFault(.invalidResult)
            }
            try Self.checkCancellation()

            let runner = workloadRunner
            initialPreflight = try await Self.withTimeout(
                stage: .preflight,
                timeout: timeouts.preflight,
                sleep: sleep,
                relay: relay
            ) { [preflightService] in
                let snapshot = try await Self.captureSafePreflight(
                    service: preflightService,
                    requiredDiskBytes: requiredDiskBytes
                )
                try await runner.cleanupTemporaryArtifacts()
                try Self.checkCancellation()
                return snapshot
            }
            environment = environmentProvider.metadata(preflight: initialPreflight)
            guard Self.isValid(environment) else {
                throw MacBenchmarkServiceFault(.invalidResult)
            }
            try await relay.emit(stage: .preflight, completedSampleCount: 0)
            try Self.checkCancellation()

            let sampleCount = Self.sampleCount(for: profile)
            let totalSampleCount = sampleCount * BenchmarkComponent.allCases.count
            let cpuSingle = try await collectComponentSamples(
                component: .cpuSingle,
                stage: .cpuSingle,
                profile: profile,
                count: sampleCount,
                completedBefore: 0,
                requiredDiskBytes: requiredDiskBytes,
                relay: relay
            ) {
                try await runner.runCPUSingle(profile: profile)
            }
            let activeProcessorCount = environment.activeProcessorCount
            let cpuMulti = try await collectComponentSamples(
                component: .cpuMulti,
                stage: .cpuMulti,
                profile: profile,
                count: sampleCount,
                completedBefore: sampleCount,
                requiredDiskBytes: requiredDiskBytes,
                relay: relay,
                interSampleDelay: Self.cpuMultiRecoveryDelay(for: profile)
            ) {
                try await runner.runCPUMulti(
                    profile: profile,
                    activeProcessorCount: activeProcessorCount
                )
            }
            let gpu = try await collectComponentSamples(
                component: .gpu,
                stage: .gpu,
                profile: profile,
                count: sampleCount,
                completedBefore: sampleCount * 2,
                requiredDiskBytes: requiredDiskBytes,
                relay: relay
            ) {
                try await runner.runGPU(profile: profile)
            }
            let memory = try await collectComponentSamples(
                component: .memory,
                stage: .memory,
                profile: profile,
                count: sampleCount,
                completedBefore: sampleCount * 3,
                requiredDiskBytes: requiredDiskBytes,
                relay: relay
            ) {
                try await runner.runMemory(profile: profile)
            }
            let disk = try await collectDiskSamples(
                profile: profile,
                count: sampleCount,
                completedBefore: sampleCount * 4,
                requiredDiskBytes: requiredDiskBytes,
                relay: relay
            )

            let measurements = try [
                Self.measurement(
                    component: .cpuSingle,
                    profile: profile,
                    samples: cpuSingle,
                    expectedCount: sampleCount
                ),
                Self.measurement(
                    component: .cpuMulti,
                    profile: profile,
                    samples: cpuMulti,
                    expectedCount: sampleCount
                ),
                Self.measurement(
                    component: .gpu,
                    profile: profile,
                    samples: gpu,
                    expectedCount: sampleCount
                ),
                Self.measurement(
                    component: .memory,
                    profile: profile,
                    samples: memory,
                    expectedCount: sampleCount
                ),
                Self.measurement(
                    component: .diskRead,
                    profile: profile,
                    samples: disk.reads,
                    expectedCount: sampleCount
                ),
                Self.measurement(
                    component: .diskWrite,
                    profile: profile,
                    samples: disk.writes,
                    expectedCount: sampleCount
                ),
            ]

            let finalPreflight = try await Self.withTimeout(
                stage: .finalizing,
                timeout: timeouts.finalizing,
                sleep: sleep,
                relay: relay
            ) { [preflightService] in
                try await Self.capturePostflight(
                    service: preflightService,
                    requiredDiskBytes: requiredDiskBytes
                )
            }
            try Self.checkCancellation()
            guard startedAt <= initialPreflight.capturedAt,
                  initialPreflight.capturedAt <= finalPreflight.capturedAt else {
                throw MacBenchmarkServiceFault(.invalidResult)
            }

            let postflight = BenchmarkPostflight(
                capturedAt: finalPreflight.capturedAt,
                powerSource: finalPreflight.powerSource,
                lowPowerModeEnabled: finalPreflight.lowPowerModeEnabled,
                thermalState: finalPreflight.thermalState,
                diskReliability: finalPreflight.diskReliability,
                availableDiskBytes: finalPreflight.availableDiskBytes,
                requiredDiskBytes: finalPreflight.requiredDiskBytes,
                warnings: finalPreflight.warnings
            )
            let completedAt = max(max(startedAt, finalPreflight.capturedAt), now())
            let rawResult = MacBenchmarkRawResult(
                profile: profile,
                workloadVersion: Self.workloadVersion(for: profile),
                startedAt: startedAt,
                completedAt: completedAt,
                environment: environment,
                preflight: initialPreflight,
                postflight: postflight,
                capabilitySet: .all,
                measurements: measurements,
                failure: nil
            )
            guard rawResult.isComplete else {
                throw MacBenchmarkServiceFault(.invalidResult)
            }
            try await relay.emit(
                stage: .finalizing,
                completedSampleCount: totalSampleCount
            )
            try Self.checkCancellation()
            return ExecutionOutcome(result: rawResult, cleanup: nil)
        } catch {
            await relay.close()
            let rawResult = Self.failureResult(
                profile: profile,
                startedAt: startedAt,
                preflight: initialPreflight,
                environment: environment,
                failure: Self.failure(from: error)
            )
            return ExecutionOutcome(
                result: rawResult,
                cleanup: (error as? MacBenchmarkCleanupPendingFault)?.cleanup
            )
        }
    }

    func collectComponentSamples(
        component: BenchmarkComponent,
        stage: BenchmarkStage,
        profile: BenchmarkProfile,
        count: Int,
        completedBefore: Int,
        requiredDiskBytes: Int64,
        relay: MacBenchmarkProgressRelay,
        interSampleDelay: Duration = .zero,
        operation: @escaping @Sendable () async throws -> BenchmarkComponentSample
    ) async throws -> [BenchmarkComponentSample] {
        let preflightService = preflightService
        let recoverySleep = recoverySleep
        return try await Self.withTimeout(
            stage: stage,
            timeout: timeouts.timeout(for: stage),
            sleep: sleep,
            relay: relay
        ) {
            _ = try await Self.captureSafePreflight(
                service: preflightService,
                requiredDiskBytes: requiredDiskBytes
            )
            var samples: [BenchmarkComponentSample] = []
            samples.reserveCapacity(count)
            for index in 0..<count {
                try Self.checkCancellation()
                do {
                    samples.append(try await operation())
                } catch {
                    throw Self.kernelFault(error, component: component)
                }
                try await relay.emit(
                    stage: stage,
                    completedSampleCount: completedBefore + index + 1
                )
                try Self.checkCancellation()
                if index + 1 < count, interSampleDelay > .zero {
                    try await recoverySleep(interSampleDelay)
                    try Self.checkCancellation()
                }
            }
            return samples
        }
    }

    func collectDiskSamples(
        profile: BenchmarkProfile,
        count: Int,
        completedBefore: Int,
        requiredDiskBytes: Int64,
        relay: MacBenchmarkProgressRelay
    ) async throws -> DiskSamples {
        let preflightService = preflightService
        let runner = workloadRunner
        return try await Self.withTimeout(
            stage: .diskRead,
            timeout: timeouts.combinedDiskTimeout,
            sleep: sleep,
            relay: relay
        ) {
            _ = try await Self.captureSafePreflight(
                service: preflightService,
                requiredDiskBytes: requiredDiskBytes
            )
            var writes: [BenchmarkComponentSample] = []
            var reads: [BenchmarkComponentSample] = []
            writes.reserveCapacity(count)
            reads.reserveCapacity(count)
            for index in 0..<count {
                try Self.checkCancellation()
                let pair: MacBenchmarkDiskSamplePair
                do {
                    pair = try await runner.runDisk(profile: profile)
                } catch {
                    throw Self.kernelFault(error, component: .diskWrite)
                }
                writes.append(pair.write)
                reads.append(pair.read)
                try await relay.emit(
                    stage: .diskWrite,
                    completedSampleCount: completedBefore + (index * 2) + 1
                )
                try await relay.emit(
                    stage: .diskRead,
                    completedSampleCount: completedBefore + (index * 2) + 2
                )
                try Self.checkCancellation()
            }
            return DiskSamples(writes: writes, reads: reads)
        }
    }

    static func captureSafePreflight(
        service: any MacBenchmarkPreflighting,
        requiredDiskBytes: Int64
    ) async throws -> BenchmarkPreflight {
        try checkCancellation()
        let preflight: BenchmarkPreflight
        do {
            preflight = try await service.capture(requiredDiskBytes: requiredDiskBytes)
        } catch is CancellationError {
            throw MacBenchmarkServiceFault(.cancelled)
        } catch {
            throw MacBenchmarkServiceFault(.invalidResult)
        }
        try checkCancellation()
        if let issue = MacBenchmarkPreflightPolicy.blockingIssue(in: preflight) {
            throw MacBenchmarkServiceFault(.safetyCheck(issue))
        }
        guard MacBenchmarkPreflightPolicy.isComparable(preflight) else {
            throw MacBenchmarkServiceFault(.invalidResult)
        }
        return preflight
    }

    /// Captures the final environment without applying the safety gate again.
    /// At this point all kernels have completed, so adverse conditions make the
    /// run raw-only rather than erasing valid samples. Transport or malformed
    /// snapshots still fail closed as an invalid result.
    static func capturePostflight(
        service: any MacBenchmarkPreflighting,
        requiredDiskBytes: Int64
    ) async throws -> BenchmarkPreflight {
        try checkCancellation()
        let postflight: BenchmarkPreflight
        do {
            postflight = try await service.capture(
                requiredDiskBytes: requiredDiskBytes
            )
        } catch is CancellationError {
            throw MacBenchmarkServiceFault(.cancelled)
        } catch {
            throw MacBenchmarkServiceFault(.invalidResult)
        }
        try checkCancellation()
        guard isStructurallyValidPostflight(
            postflight,
            requiredDiskBytes: requiredDiskBytes
        ) else {
            throw MacBenchmarkServiceFault(.invalidResult)
        }
        return postflight
    }

    static func isStructurallyValidPostflight(
        _ postflight: BenchmarkPreflight,
        requiredDiskBytes: Int64
    ) -> Bool {
        guard requiredDiskBytes > 0,
              postflight.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              postflight.requiredDiskBytes == requiredDiskBytes,
              postflight.availableDiskBytes >= 0,
              MacBenchmarkPreflightPolicy.warnings(for: postflight)
                == postflight.warnings else {
            return false
        }
        guard let batteryPercent = postflight.batteryPercent else { return true }
        return batteryPercent.isFinite && (0...100).contains(batteryPercent)
    }

    static func measurement(
        component: BenchmarkComponent,
        profile: BenchmarkProfile,
        samples: [BenchmarkComponentSample],
        expectedCount: Int
    ) throws -> BenchmarkComponentMeasurement {
        guard samples.count == expectedCount,
              let checksum = samples.first?.checksum,
              samples.allSatisfy({ $0.checksum == checksum })
        else {
            throw MacBenchmarkServiceFault(
                .kernelFailure(component: component, reason: .checksumMismatch)
            )
        }
        let measurement = BenchmarkComponentMeasurement(
            component: component,
            unit: component.metricUnit(for: profile),
            samples: samples
        )
        guard measurement.isValid else {
            throw MacBenchmarkServiceFault(
                .kernelFailure(component: component, reason: .invalidMetric)
            )
        }
        return measurement
    }

    static func withTimeout<Value: Sendable>(
        stage: BenchmarkStage,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        relay: MacBenchmarkProgressRelay,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard timeout > .zero else {
            throw MacBenchmarkServiceFault(.invalidResult)
        }
        let race = MacBenchmarkOperationRace<Value>()
        let operationTask = Task<Void, Never> {
            do {
                race.resolve(.success(try await operation()))
            } catch {
                race.resolve(.failure(MacBenchmarkUncheckedError(error)))
            }
        }
        let timeoutTask = Task<Void, Never> {
            do {
                try await sleep(timeout)
                try Task.checkCancellation()
                race.resolve(.timedOut)
            } catch is CancellationError {
                return
            } catch {
                race.resolve(.timerFailure)
            }
        }

        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            race.resolve(.cancelled)
            Task { await relay.close() }
        }

        switch outcome {
        case let .success(value):
            timeoutTask.cancel()
            return value
        case let .failure(error):
            timeoutTask.cancel()
            throw error.value
        case .timedOut:
            operationTask.cancel()
            timeoutTask.cancel()
            await relay.close()
            throw MacBenchmarkCleanupPendingFault(
                failure: Task.isCancelled ? .cancelled : .timedOut(stage),
                cleanup: MacBenchmarkCleanupHandle(task: operationTask)
            )
        case .cancelled:
            operationTask.cancel()
            timeoutTask.cancel()
            await relay.close()
            throw MacBenchmarkCleanupPendingFault(
                failure: .cancelled,
                cleanup: MacBenchmarkCleanupHandle(task: operationTask)
            )
        case .timerFailure:
            operationTask.cancel()
            timeoutTask.cancel()
            await relay.close()
            throw MacBenchmarkCleanupPendingFault(
                failure: .invalidResult,
                cleanup: MacBenchmarkCleanupHandle(task: operationTask)
            )
        }
    }

    static func kernelFault(
        _ error: Error,
        component: BenchmarkComponent
    ) -> MacBenchmarkServiceFault {
        if let fault = error as? MacBenchmarkServiceFault { return fault }
        if error is CancellationError || Task.isCancelled {
            return MacBenchmarkServiceFault(.cancelled)
        }
        guard let kernelError = error as? BenchmarkKernelError else {
            return MacBenchmarkServiceFault(
                .kernelFailure(component: component, reason: .systemFailure)
            )
        }
        switch kernelError {
        case .unavailable:
            return MacBenchmarkServiceFault(.unsupported(component))
        case .invalidConfiguration, .resourceLimit:
            return MacBenchmarkServiceFault(
                .kernelFailure(component: component, reason: .resourceLimit)
            )
        case .invalidMetric:
            return MacBenchmarkServiceFault(
                .kernelFailure(component: component, reason: .invalidMetric)
            )
        case .checksumMismatch:
            return MacBenchmarkServiceFault(
                .kernelFailure(component: component, reason: .checksumMismatch)
            )
        case .systemFailure:
            return MacBenchmarkServiceFault(
                .kernelFailure(component: component, reason: .systemFailure)
            )
        }
    }

    static func failure(from error: Error) -> MacBenchmarkFailure {
        if let pending = error as? MacBenchmarkCleanupPendingFault {
            return pending.failure
        }
        if let fault = error as? MacBenchmarkServiceFault { return fault.failure }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let coordinatorError = error as? HeavyWorkCoordinator.Error {
            switch coordinatorError {
            case let .busy(activeOwner):
                return .busy(activeTask: String(describing: activeOwner))
            case .invalidLease:
                return .invalidResult
            }
        }
        return .invalidResult
    }

    static func checkCancellation() throws {
        if Task.isCancelled {
            throw MacBenchmarkServiceFault(.cancelled)
        }
    }

    static func isValid(_ environment: BenchmarkEnvironmentMetadata) -> Bool {
        environment.activeProcessorCount > 0
            && environment.physicalMemoryBytes > 0
            && !environment.chipName.isEmpty
            && !environment.operatingSystemVersion.isEmpty
            && !environment.appVersion.isEmpty
            && !environment.appBuild.isEmpty
    }

    static func fallbackPreflight(
        capturedAt: Date,
        requiredDiskBytes: Int64
    ) -> BenchmarkPreflight {
        let safeRequiredBytes = max(0, requiredDiskBytes)
        let draft = BenchmarkPreflight(
            capturedAt: capturedAt,
            powerSource: .unknown,
            batteryPercent: nil,
            lowPowerModeEnabled: false,
            thermalState: .unknown,
            diskReliability: .unavailable,
            availableDiskBytes: 0,
            requiredDiskBytes: safeRequiredBytes,
            warnings: []
        )
        return BenchmarkPreflight(
            capturedAt: draft.capturedAt,
            powerSource: draft.powerSource,
            batteryPercent: draft.batteryPercent,
            lowPowerModeEnabled: draft.lowPowerModeEnabled,
            thermalState: draft.thermalState,
            diskReliability: draft.diskReliability,
            availableDiskBytes: draft.availableDiskBytes,
            requiredDiskBytes: draft.requiredDiskBytes,
            warnings: MacBenchmarkPreflightPolicy.warnings(for: draft)
        )
    }

    static func failureResult(
        profile: BenchmarkProfile,
        startedAt: Date,
        preflight: BenchmarkPreflight,
        environment: BenchmarkEnvironmentMetadata,
        failure: MacBenchmarkFailure
    ) -> MacBenchmarkRawResult {
        MacBenchmarkRawResult(
            profile: profile,
            workloadVersion: workloadVersion(for: profile),
            startedAt: startedAt,
            completedAt: nil,
            environment: environment,
            preflight: preflight,
            postflight: nil,
            capabilitySet: .none,
            measurements: [],
            failure: failure
        )
    }

}

private struct MacBenchmarkCleanupHandle: Sendable {
    let task: Task<Void, Never>

    func wait() async {
        await task.value
    }
}

private struct MacBenchmarkCleanupPendingFault: Error, Sendable {
    let failure: MacBenchmarkFailure
    let cleanup: MacBenchmarkCleanupHandle
}

private struct MacBenchmarkUncheckedError: @unchecked Sendable {
    let value: any Error

    init(_ value: any Error) {
        self.value = value
    }
}

private enum MacBenchmarkOperationRaceOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(MacBenchmarkUncheckedError)
    case timedOut
    case cancelled
    case timerFailure
}

private final class MacBenchmarkOperationRace<Value: Sendable>: @unchecked Sendable {
    typealias Outcome = MacBenchmarkOperationRaceOutcome<Value>

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ proposedOutcome: Outcome) {
        let continuation: CheckedContinuation<Outcome, Never>?
        lock.lock()
        if outcome == nil {
            outcome = proposedOutcome
            continuation = waiter
            waiter = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: proposedOutcome)
    }
}

private struct MacBenchmarkServiceFault: Error, Sendable {
    let failure: MacBenchmarkFailure

    init(_ failure: MacBenchmarkFailure) {
        self.failure = failure
    }
}

private actor MacBenchmarkProgressRelay {
    private let totalSampleCount: Int
    private let startedAt: UInt64
    private let monotonicNow: @Sendable () -> UInt64
    private let callback: @Sendable (MacBenchmarkProgress) async -> Void
    private var lastCompletedSampleCount = 0
    private var lastElapsedSeconds = 0.0
    private var isClosed = false

    init(
        totalSampleCount: Int,
        startedAt: UInt64,
        monotonicNow: @escaping @Sendable () -> UInt64,
        callback: @escaping @Sendable (MacBenchmarkProgress) async -> Void
    ) {
        self.totalSampleCount = max(1, totalSampleCount)
        self.startedAt = startedAt
        self.monotonicNow = monotonicNow
        self.callback = callback
    }

    func emit(
        stage: BenchmarkStage,
        completedSampleCount: Int
    ) async throws {
        guard !isClosed else { return }
        try Task.checkCancellation()

        let completed = min(
            totalSampleCount,
            max(lastCompletedSampleCount, completedSampleCount)
        )
        let current = monotonicNow()
        let measuredElapsed = current >= startedAt
            ? Double(current - startedAt) / 1_000_000_000
            : 0
        let elapsed = max(lastElapsedSeconds, measuredElapsed)
        lastCompletedSampleCount = completed
        lastElapsedSeconds = elapsed

        let update = MacBenchmarkProgress(
            stage: stage,
            completedSampleCount: completed,
            totalSampleCount: totalSampleCount,
            progress: Double(completed) / Double(totalSampleCount),
            elapsedSeconds: elapsed
        )
        await callback(update)
        try Task.checkCancellation()
        guard !isClosed else { return }
    }

    func close() {
        isClosed = true
    }
}
