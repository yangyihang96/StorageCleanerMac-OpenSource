import Foundation

struct MacSustainedBenchmarkConfiguration: Equatable, Sendable {
    let targetDurationSeconds: Double
    let telemetryIntervalSeconds: Double
    let cooldownTimeoutSeconds: Double
    let maximumWindowCount: Int

    static func production(for profile: MacSustainedBenchmarkProfile) -> Self {
        Self(
            targetDurationSeconds: profile.targetDurationSeconds,
            telemetryIntervalSeconds: 1,
            cooldownTimeoutSeconds: 30,
            maximumWindowCount: MacSustainedBenchmarkResult.maximumWindowCount
        )
    }

    var isValid: Bool {
        targetDurationSeconds.isFinite
            && targetDurationSeconds > 0
            && targetDurationSeconds <= 900
            && telemetryIntervalSeconds.isFinite
            && telemetryIntervalSeconds > 0
            && telemetryIntervalSeconds <= 2
            && cooldownTimeoutSeconds.isFinite
            && cooldownTimeoutSeconds >= 0
            && cooldownTimeoutSeconds <= 30
            && maximumWindowCount >= 3
            && maximumWindowCount <= MacSustainedBenchmarkResult.maximumWindowCount
    }
}

struct MacSustainedWorkloadSample: Equatable, Sendable {
    let cpuMultiSample: BenchmarkComponentSample
    let gpuRasterSample: BenchmarkComponentSample
}

enum MacSustainedWorkloadError: Error, Equatable, Sendable {
    case unsupportedCPU
    case unsupportedGPU
    case temporarilyUnavailable
    case invalidResult
}

protocol MacSustainedWorkloadRunning: Sendable {
    func runSerialRound(activeProcessorCount: Int) async throws
        -> MacSustainedWorkloadSample
}

protocol MacSustainedTelemetryProbing: Sendable {
    func capture(elapsedSeconds: Double) async -> MacSustainedTelemetrySample
}

protocol MacSustainedBenchmarkServicing: Sendable {
    func run(
        profile: MacSustainedBenchmarkProfile,
        coolingMode: MacSustainedCoolingMode,
        progress: @escaping @Sendable (MacSustainedBenchmarkProgress) async -> Void
    ) async -> MacSustainedBenchmarkResult
}

actor MacSustainedBenchmarkService: MacSustainedBenchmarkServicing {
    static let requiredDiskBytes: Int64 = 64 * 1_024 * 1_024

    private let heavyWorkCoordinator: HeavyWorkCoordinator
    private let preflightService: any MacBenchmarkPreflighting
    private let workloadRunner: any MacSustainedWorkloadRunning
    private let telemetryProbe: any MacSustainedTelemetryProbing
    private let environmentProvider: any MacBenchmarkEnvironmentProviding
    private let configurationProvider:
        @Sendable (MacSustainedBenchmarkProfile) -> MacSustainedBenchmarkConfiguration
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> UInt64
    private let sleep: @Sendable (Duration) async throws -> Void
    private var activeRunID: UUID?

    init(
        heavyWorkCoordinator: HeavyWorkCoordinator,
        preflightService: any MacBenchmarkPreflighting = MacBenchmarkPreflightService(),
        workloadRunner: any MacSustainedWorkloadRunning,
        telemetryProbe: any MacSustainedTelemetryProbing =
            SystemMacSustainedTelemetryProbe(),
        environmentProvider: any MacBenchmarkEnvironmentProviding =
            SystemMacBenchmarkEnvironmentProvider(),
        configurationProvider: @escaping @Sendable
            (MacSustainedBenchmarkProfile) -> MacSustainedBenchmarkConfiguration = {
                MacSustainedBenchmarkConfiguration.production(for: $0)
            },
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.heavyWorkCoordinator = heavyWorkCoordinator
        self.preflightService = preflightService
        self.workloadRunner = workloadRunner
        self.telemetryProbe = telemetryProbe
        self.environmentProvider = environmentProvider
        self.configurationProvider = configurationProvider
        self.now = now
        self.monotonicNow = monotonicNow
        self.sleep = sleep
    }

    func run(
        profile: MacSustainedBenchmarkProfile,
        coolingMode: MacSustainedCoolingMode = .systemAutomatic,
        progress: @escaping @Sendable (MacSustainedBenchmarkProgress) async -> Void = {
            _ in
        }
    ) async -> MacSustainedBenchmarkResult {
        let startedAt = now()
        let configuration = configurationProvider(profile)
        let fallbackPreflight = Self.fallbackPreflight(capturedAt: startedAt)
        let fallbackEnvironment = environmentProvider.metadata(
            preflight: fallbackPreflight
        )

        guard activeRunID == nil else {
            return Self.failureResult(
                profile: profile,
                coolingMode: coolingMode,
                configuration: configuration,
                startedAt: startedAt,
                preflight: fallbackPreflight,
                environment: fallbackEnvironment,
                failure: .busy(activeTask: "benchmark")
            )
        }
        guard !Task.isCancelled else {
            return Self.failureResult(
                profile: profile,
                coolingMode: coolingMode,
                configuration: configuration,
                startedAt: startedAt,
                preflight: fallbackPreflight,
                environment: fallbackEnvironment,
                failure: .cancelled
            )
        }

        let runID = UUID()
        activeRunID = runID
        defer {
            if activeRunID == runID { activeRunID = nil }
        }

        do {
            guard configuration.isValid else {
                throw MacSustainedServiceFault(.invalidResult)
            }
            return try await heavyWorkCoordinator.withLease(owner: .benchmark) {
                [self] _ in
                try await execute(
                    profile: profile,
                    coolingMode: coolingMode,
                    configuration: configuration,
                    startedAt: startedAt,
                    fallbackPreflight: fallbackPreflight,
                    fallbackEnvironment: fallbackEnvironment,
                    progress: progress
                )
            }
        } catch {
            return Self.failureResult(
                profile: profile,
                coolingMode: coolingMode,
                configuration: configuration,
                startedAt: startedAt,
                preflight: fallbackPreflight,
                environment: fallbackEnvironment,
                failure: Self.failure(from: error)
            )
        }
    }
}

private extension MacSustainedBenchmarkService {
    func execute(
        profile: MacSustainedBenchmarkProfile,
        coolingMode: MacSustainedCoolingMode,
        configuration: MacSustainedBenchmarkConfiguration,
        startedAt: Date,
        fallbackPreflight: BenchmarkPreflight,
        fallbackEnvironment: BenchmarkEnvironmentMetadata,
        progress: @escaping @Sendable (MacSustainedBenchmarkProgress) async -> Void
    ) async throws -> MacSustainedBenchmarkResult {
        var preflight = fallbackPreflight
        var environment = fallbackEnvironment
        try Task.checkCancellation()

        preflight = try await captureSafePreflight()
        environment = environmentProvider.metadata(preflight: preflight)
        guard Self.isValid(environment) else {
            throw MacSustainedServiceFault(.invalidResult)
        }

        let monotonicStartedAt = monotonicNow()
        let recorder = MacSustainedTelemetryRecorder()
        let initialTelemetry = await telemetryProbe.capture(elapsedSeconds: 0)
        guard initialTelemetry.isValid else {
            throw MacSustainedServiceFault(.invalidResult)
        }
        if let stop = Self.stopReason(for: initialTelemetry) {
            throw MacSustainedServiceFault(Self.failure(for: stop))
        }
        guard await recorder.append(initialTelemetry) else {
            throw MacSustainedServiceFault(.invalidResult)
        }
        await progress(
            Self.progress(
                stage: .preflight,
                completedWindowCount: 0,
                telemetry: initialTelemetry,
                targetDurationSeconds: configuration.targetDurationSeconds
            )
        )

        var windows: [MacSustainedBenchmarkWindow] = []
        windows.reserveCapacity(min(256, configuration.maximumWindowCount))
        var termination: MacSustainedBenchmarkTermination?
        var workloadStoppedAtSeconds: Double?

        while termination == nil {
            try Task.checkCancellation()
            guard windows.count < configuration.maximumWindowCount else {
                throw MacSustainedServiceFault(.invalidResult)
            }
            let windowStartedAt = try elapsedSeconds(since: monotonicStartedAt)
            if windowStartedAt >= configuration.targetDurationSeconds {
                termination = .targetDurationReached
                workloadStoppedAtSeconds = windowStartedAt
                break
            }

            let outcome = await runGuardedRound(
                activeProcessorCount: environment.activeProcessorCount,
                completedWindowCount: windows.count,
                monotonicStartedAt: monotonicStartedAt,
                configuration: configuration,
                recorder: recorder,
                progress: progress
            )
            switch outcome {
            case let .sample(sample):
                let completedAt = try elapsedSeconds(since: monotonicStartedAt)
                let window = MacSustainedBenchmarkWindow(
                    index: windows.count,
                    startedAtSeconds: windowStartedAt,
                    completedAtSeconds: completedAt,
                    cpuMultiSample: sample.cpuMultiSample,
                    gpuRasterSample: sample.gpuRasterSample
                )
                guard window.isValid else {
                    throw MacSustainedServiceFault(.invalidResult)
                }
                windows.append(window)

                let telemetry = await telemetryProbe.capture(
                    elapsedSeconds: completedAt
                )
                guard telemetry.isValid,
                      await recorder.append(telemetry) else {
                    throw MacSustainedServiceFault(.invalidResult)
                }
                await progress(
                    Self.progress(
                        stage: .mixedLoad,
                        completedWindowCount: windows.count,
                        telemetry: telemetry,
                        targetDurationSeconds: configuration.targetDurationSeconds
                    )
                )
                if let stop = Self.stopReason(for: telemetry) {
                    termination = stop
                    workloadStoppedAtSeconds = completedAt
                } else if completedAt >= configuration.targetDurationSeconds {
                    termination = .targetDurationReached
                    workloadStoppedAtSeconds = completedAt
                }
            case let .stopped(reason):
                termination = reason
                workloadStoppedAtSeconds = await recorder.lastElapsedSeconds()
            case let .failed(error):
                throw error.value
            case .cancelled:
                throw CancellationError()
            }
        }

        guard let termination,
              let workloadDuration = workloadStoppedAtSeconds else {
            throw MacSustainedServiceFault(.invalidResult)
        }
        if termination == .targetDurationReached, windows.count < 3 {
            throw MacSustainedServiceFault(.insufficientSamples)
        }

        let cooldownReachedNominal: Bool?
        switch termination {
        case .thermalSafety:
            cooldownReachedNominal = try await observeCooldown(
                completedWindowCount: windows.count,
                monotonicStartedAt: monotonicStartedAt,
                configuration: configuration,
                recorder: recorder,
                progress: progress
            )
        case .targetDurationReached, .powerSourceChanged, .lowPowerModeEnabled:
            cooldownReachedNominal = nil
        }

        let totalObservationDuration = try elapsedSeconds(since: monotonicStartedAt)
        let telemetry = await recorder.values()
        let completedAt = max(max(startedAt, preflight.capturedAt), now())
        let result = MacSustainedBenchmarkResult(
            profile: profile,
            coolingMode: coolingMode,
            targetDurationSeconds: configuration.targetDurationSeconds,
            workloadDurationSeconds: workloadDuration,
            totalObservationDurationSeconds: totalObservationDuration,
            startedAt: startedAt,
            completedAt: completedAt,
            environment: environment,
            preflight: preflight,
            windows: windows,
            telemetry: telemetry,
            termination: termination,
            cooldownReachedNominal: cooldownReachedNominal,
            failure: nil
        )
        guard result.isComplete else {
            throw MacSustainedServiceFault(.invalidResult)
        }
        try Task.checkCancellation()
        return result
    }

    func runGuardedRound(
        activeProcessorCount: Int,
        completedWindowCount: Int,
        monotonicStartedAt: UInt64,
        configuration: MacSustainedBenchmarkConfiguration,
        recorder: MacSustainedTelemetryRecorder,
        progress: @escaping @Sendable (MacSustainedBenchmarkProgress) async -> Void
    ) async -> MacSustainedRoundOutcome {
        let race = MacSustainedRoundRace()
        let runner = workloadRunner
        let telemetryProbe = telemetryProbe
        let monotonicNow = monotonicNow
        let sleep = sleep

        let workloadTask = Task<Void, Never> {
            do {
                let sample = try await runner.runSerialRound(
                    activeProcessorCount: activeProcessorCount
                )
                await race.resolve(.sample(sample))
            } catch {
                await race.resolve(.failed(MacSustainedUncheckedError(error)))
            }
        }
        let monitorTask = Task<Void, Never> {
            while !Task.isCancelled {
                do {
                    try await sleep(.seconds(configuration.telemetryIntervalSeconds))
                    try Task.checkCancellation()
                } catch {
                    return
                }
                let sampledAt = monotonicNow()
                guard sampledAt >= monotonicStartedAt else {
                    await race.resolve(
                        .failed(MacSustainedUncheckedError(
                            MacSustainedServiceFault(.invalidResult)
                        ))
                    )
                    return
                }
                let elapsed = Double(sampledAt - monotonicStartedAt) / 1_000_000_000
                let telemetry = await telemetryProbe.capture(elapsedSeconds: elapsed)
                guard telemetry.isValid,
                      await recorder.append(telemetry) else {
                    await race.resolve(
                        .failed(MacSustainedUncheckedError(
                            MacSustainedServiceFault(.invalidResult)
                        ))
                    )
                    return
                }
                await progress(
                    Self.progress(
                        stage: .mixedLoad,
                        completedWindowCount: completedWindowCount,
                        telemetry: telemetry,
                        targetDurationSeconds: configuration.targetDurationSeconds
                    )
                )
                if let stop = Self.stopReason(for: telemetry) {
                    await race.resolve(.stopped(stop))
                    return
                }
                if elapsed >= configuration.targetDurationSeconds {
                    await race.resolve(.stopped(.targetDurationReached))
                    return
                }
            }
        }

        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            workloadTask.cancel()
            monitorTask.cancel()
            Task { await race.resolve(.cancelled) }
        }
        workloadTask.cancel()
        monitorTask.cancel()
        await workloadTask.value
        await monitorTask.value
        return outcome
    }

    func observeCooldown(
        completedWindowCount: Int,
        monotonicStartedAt: UInt64,
        configuration: MacSustainedBenchmarkConfiguration,
        recorder: MacSustainedTelemetryRecorder,
        progress: @escaping @Sendable (MacSustainedBenchmarkProgress) async -> Void
    ) async throws -> Bool {
        let cooldownStartedAt = monotonicNow()
        guard cooldownStartedAt >= monotonicStartedAt else {
            throw MacSustainedServiceFault(.invalidResult)
        }
        while true {
            try Task.checkCancellation()
            let sampledAt = monotonicNow()
            guard sampledAt >= cooldownStartedAt,
                  sampledAt >= monotonicStartedAt else {
                throw MacSustainedServiceFault(.invalidResult)
            }
            let cooldownElapsed = Double(sampledAt - cooldownStartedAt)
                / 1_000_000_000
            let totalElapsed = Double(sampledAt - monotonicStartedAt)
                / 1_000_000_000
            let telemetry = await telemetryProbe.capture(
                elapsedSeconds: totalElapsed
            )
            guard telemetry.isValid,
                  await recorder.append(telemetry) else {
                throw MacSustainedServiceFault(.invalidResult)
            }
            await progress(
                Self.progress(
                    stage: .coolingDown,
                    completedWindowCount: completedWindowCount,
                    telemetry: telemetry,
                    targetDurationSeconds: configuration.targetDurationSeconds
                )
            )
            if telemetry.thermalState == .nominal { return true }
            if cooldownElapsed >= configuration.cooldownTimeoutSeconds { return false }
            try await sleep(.seconds(configuration.telemetryIntervalSeconds))
        }
    }

    func captureSafePreflight() async throws -> BenchmarkPreflight {
        try Task.checkCancellation()
        let snapshot: BenchmarkPreflight
        do {
            snapshot = try await preflightService.capture(
                requiredDiskBytes: Self.requiredDiskBytes
            )
        } catch is CancellationError {
            throw MacSustainedServiceFault(.cancelled)
        } catch {
            throw MacSustainedServiceFault(.invalidResult)
        }
        if let issue = MacBenchmarkPreflightPolicy.blockingIssue(in: snapshot) {
            throw MacSustainedServiceFault(.safetyCheck(issue))
        }
        guard MacBenchmarkPreflightPolicy.isComparable(snapshot) else {
            throw MacSustainedServiceFault(.invalidResult)
        }
        return snapshot
    }

    func elapsedSeconds(since startedAt: UInt64) throws -> Double {
        let sampledAt = monotonicNow()
        guard sampledAt >= startedAt else {
            throw MacSustainedServiceFault(.invalidResult)
        }
        return Double(sampledAt - startedAt) / 1_000_000_000
    }
}

private extension MacSustainedBenchmarkService {
    static func stopReason(
        for telemetry: MacSustainedTelemetrySample
    ) -> MacSustainedBenchmarkTermination? {
        switch telemetry.thermalState {
        case .serious, .critical:
            return .thermalSafety(telemetry.thermalState)
        case .unknown:
            return .thermalSafety(.unknown)
        case .nominal, .fair:
            break
        }
        guard telemetry.powerSource == .acPower else {
            return .powerSourceChanged(telemetry.powerSource)
        }
        if telemetry.lowPowerModeEnabled { return .lowPowerModeEnabled }
        return nil
    }

    static func progress(
        stage: MacSustainedBenchmarkStage,
        completedWindowCount: Int,
        telemetry: MacSustainedTelemetrySample,
        targetDurationSeconds: Double
    ) -> MacSustainedBenchmarkProgress {
        MacSustainedBenchmarkProgress(
            stage: stage,
            completedWindowCount: completedWindowCount,
            elapsedSeconds: telemetry.elapsedSeconds,
            targetDurationSeconds: targetDurationSeconds,
            thermalState: telemetry.thermalState,
            currentFanSpeedRPM: telemetry.fans.speedsRPM?.max()
        )
    }

    static func failure(
        for reason: MacSustainedBenchmarkTermination
    ) -> MacSustainedBenchmarkFailure {
        switch reason {
        case let .thermalSafety(state):
            return .safetyCheck(
                state == .critical ? .thermalCritical : .thermalNotNominal
            )
        case .powerSourceChanged:
            return .safetyCheck(.acPowerRequired)
        case .lowPowerModeEnabled:
            return .safetyCheck(.lowPowerModeEnabled)
        case .targetDurationReached:
            return .invalidResult
        }
    }

    static func failure(from error: Error) -> MacSustainedBenchmarkFailure {
        if let fault = error as? MacSustainedServiceFault { return fault.failure }
        if let workloadError = error as? MacSustainedWorkloadError {
            switch workloadError {
            case .unsupportedCPU:
                return .unsupportedCPU
            case .unsupportedGPU:
                return .unsupportedGPU
            case .temporarilyUnavailable, .invalidResult:
                return .workloadFailed
            }
        }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let coordinatorError = error as? HeavyWorkCoordinator.Error {
            switch coordinatorError {
            case let .busy(activeOwner):
                return .busy(activeTask: String(describing: activeOwner))
            case .invalidLease:
                return .invalidResult
            }
        }
        return .workloadFailed
    }

    static func isValid(_ environment: BenchmarkEnvironmentMetadata) -> Bool {
        environment.architecture == .arm64
            && environment.activeProcessorCount > 1
            && environment.physicalMemoryBytes > 0
            && !environment.chipName.isEmpty
            && !environment.operatingSystemVersion.isEmpty
            && !environment.appVersion.isEmpty
            && !environment.appBuild.isEmpty
    }

    static func fallbackPreflight(capturedAt: Date) -> BenchmarkPreflight {
        let draft = BenchmarkPreflight(
            capturedAt: capturedAt,
            powerSource: .unknown,
            batteryPercent: nil,
            lowPowerModeEnabled: false,
            thermalState: .unknown,
            diskReliability: .unavailable,
            availableDiskBytes: 0,
            requiredDiskBytes: requiredDiskBytes,
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
        profile: MacSustainedBenchmarkProfile,
        coolingMode: MacSustainedCoolingMode,
        configuration: MacSustainedBenchmarkConfiguration,
        startedAt: Date,
        preflight: BenchmarkPreflight,
        environment: BenchmarkEnvironmentMetadata,
        failure: MacSustainedBenchmarkFailure
    ) -> MacSustainedBenchmarkResult {
        MacSustainedBenchmarkResult(
            profile: profile,
            coolingMode: coolingMode,
            targetDurationSeconds: configuration.targetDurationSeconds.isFinite
                ? max(0, configuration.targetDurationSeconds)
                : 0,
            workloadDurationSeconds: 0,
            totalObservationDurationSeconds: 0,
            startedAt: startedAt,
            completedAt: nil,
            environment: environment,
            preflight: preflight,
            windows: [],
            telemetry: [],
            termination: nil,
            cooldownReachedNominal: nil,
            failure: failure
        )
    }
}

private enum MacSustainedRoundOutcome: Sendable {
    case sample(MacSustainedWorkloadSample)
    case stopped(MacSustainedBenchmarkTermination)
    case failed(MacSustainedUncheckedError)
    case cancelled
}

private struct MacSustainedUncheckedError: @unchecked Sendable {
    let value: Error

    init(_ value: Error) {
        self.value = value
    }
}

private actor MacSustainedRoundRace {
    private var outcome: MacSustainedRoundOutcome?
    private var continuation: CheckedContinuation<MacSustainedRoundOutcome, Never>?

    func resolve(_ outcome: MacSustainedRoundOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func wait() async -> MacSustainedRoundOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
    }
}

private actor MacSustainedTelemetryRecorder {
    private var samples: [MacSustainedTelemetrySample] = []

    func append(_ sample: MacSustainedTelemetrySample) -> Bool {
        guard sample.isValid,
              samples.count < MacSustainedBenchmarkResult.maximumTelemetrySampleCount,
              samples.last.map({ sample.elapsedSeconds >= $0.elapsedSeconds }) ?? true
        else { return false }
        samples.append(sample)
        return true
    }

    func values() -> [MacSustainedTelemetrySample] { samples }

    func lastElapsedSeconds() -> Double? { samples.last?.elapsedSeconds }
}

private struct MacSustainedServiceFault: Error, Sendable {
    let failure: MacSustainedBenchmarkFailure

    init(_ failure: MacSustainedBenchmarkFailure) {
        self.failure = failure
    }
}
