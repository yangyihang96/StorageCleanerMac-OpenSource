import Foundation

struct MacAcceleratorRayTracingSamplePair: Equatable, Sendable {
    let build: BenchmarkComponentSample
    let traversal: BenchmarkComponentSample
}

struct MacAcceleratorMediaSamplePair: Equatable, Sendable {
    let encode: BenchmarkComponentSample
    let decode: BenchmarkComponentSample
}

private struct MacAcceleratorSamplePair: Equatable, Sendable {
    let first: BenchmarkComponentSample
    let second: BenchmarkComponentSample
}

enum MacAcceleratorWorkloadOutcome<Value: Sendable>: Sendable {
    case measured(Value)
    case unsupported
    case temporarilyUnavailable
}

extension MacAcceleratorWorkloadOutcome: Equatable where Value: Equatable {}

enum MacAcceleratorWorkloadError: Error, Equatable, Sendable {
    /// The hardware capability exists, but the system could not allocate a
    /// transient command/session resource for this run.
    case temporarilyUnavailable
    case timedOut(MacAcceleratorMetric)
}

protocol MacAcceleratorWorkloadRunning: Sendable {
    func runMetalRaster3D() async throws -> BenchmarkComponentSample
    func runRayTracing() async throws
        -> MacAcceleratorWorkloadOutcome<MacAcceleratorRayTracingSamplePair>
    func runGPUTensor() async throws
        -> MacAcceleratorWorkloadOutcome<BenchmarkComponentSample>
    func runH264Media() async throws
        -> MacAcceleratorWorkloadOutcome<MacAcceleratorMediaSamplePair>
}

protocol MacAcceleratorBenchmarkServicing: Sendable {
    func run(
        progress: @escaping @Sendable (MacAcceleratorBenchmarkProgress) async -> Void
    ) async -> MacAcceleratorBenchmarkResult
}

actor MacAcceleratorBenchmarkService: MacAcceleratorBenchmarkServicing {
    static let requiredDiskBytes: Int64 = 64 * 1_024 * 1_024

    private let heavyWorkCoordinator: HeavyWorkCoordinator
    private let preflightService: any MacBenchmarkPreflighting
    private let workloadRunner: any MacAcceleratorWorkloadRunning
    private let environmentProvider: any MacBenchmarkEnvironmentProviding
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> UInt64
    private var activeRunID: UUID?

    init(
        heavyWorkCoordinator: HeavyWorkCoordinator,
        preflightService: any MacBenchmarkPreflighting = MacBenchmarkPreflightService(),
        workloadRunner: any MacAcceleratorWorkloadRunning,
        environmentProvider: any MacBenchmarkEnvironmentProviding
            = SystemMacBenchmarkEnvironmentProvider(),
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.heavyWorkCoordinator = heavyWorkCoordinator
        self.preflightService = preflightService
        self.workloadRunner = workloadRunner
        self.environmentProvider = environmentProvider
        self.now = now
        self.monotonicNow = monotonicNow
    }

    func run(
        progress: @escaping @Sendable (MacAcceleratorBenchmarkProgress) async -> Void
            = { _ in }
    ) async -> MacAcceleratorBenchmarkResult {
        let startedAt = now()
        let fallbackPreflight = Self.fallbackPreflight(capturedAt: startedAt)
        let fallbackEnvironment = environmentProvider.metadata(
            preflight: fallbackPreflight
        )

        guard activeRunID == nil else {
            return Self.failureResult(
                startedAt: startedAt,
                preflight: fallbackPreflight,
                environment: fallbackEnvironment,
                failure: .busy(activeTask: "benchmark")
            )
        }
        guard !Task.isCancelled else {
            return Self.failureResult(
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
            return try await heavyWorkCoordinator.withLease(owner: .benchmark) {
                [self] _ in
                try await execute(
                    startedAt: startedAt,
                    fallbackPreflight: fallbackPreflight,
                    fallbackEnvironment: fallbackEnvironment,
                    progress: progress
                )
            }
        } catch {
            return Self.failureResult(
                startedAt: startedAt,
                preflight: fallbackPreflight,
                environment: fallbackEnvironment,
                failure: Self.failure(from: error)
            )
        }
    }
}

private extension MacAcceleratorBenchmarkService {
    static let totalSampleCount = MacAcceleratorMetric.allCases.count
        * MacAcceleratorBenchmarkResult.sampleCount

    func execute(
        startedAt: Date,
        fallbackPreflight: BenchmarkPreflight,
        fallbackEnvironment: BenchmarkEnvironmentMetadata,
        progress: @escaping @Sendable (MacAcceleratorBenchmarkProgress) async -> Void
    ) async throws -> MacAcceleratorBenchmarkResult {
        var initialPreflight = fallbackPreflight
        var environment = fallbackEnvironment
        var measurements: [MacAcceleratorMeasurement] = []

        do {
            try Task.checkCancellation()
            initialPreflight = try await captureSafePreflight()
            environment = environmentProvider.metadata(preflight: initialPreflight)
            guard Self.isValid(environment) else {
                throw MacAcceleratorServiceFault(.invalidResult)
            }

            let timerStartedAt = monotonicNow()
            let raster = try await collectSingle(
                metric: .metalRaster3D,
                completedBefore: 0,
                timerStartedAt: timerStartedAt,
                progress: progress
            ) {
                .measured(try await self.workloadRunner.runMetalRaster3D())
            }
            measurements.append(raster)

            let ray = try await collectPair(
                firstMetric: .rayTracingBuild,
                secondMetric: .rayTracingTraversal,
                completedBefore: MacAcceleratorBenchmarkResult.sampleCount,
                timerStartedAt: timerStartedAt,
                progress: progress
            ) {
                let result = try await self.workloadRunner.runRayTracing()
                switch result {
                case let .measured(pair):
                    return MacAcceleratorWorkloadOutcome.measured(
                        MacAcceleratorSamplePair(
                        first: pair.build,
                        second: pair.traversal
                        )
                    )
                case .unsupported:
                    return MacAcceleratorWorkloadOutcome.unsupported
                case .temporarilyUnavailable:
                    return MacAcceleratorWorkloadOutcome.temporarilyUnavailable
                }
            }
            measurements.append(contentsOf: ray)

            let tensor = try await collectSingle(
                metric: .gpuTensorFP16,
                completedBefore: MacAcceleratorBenchmarkResult.sampleCount * 3,
                timerStartedAt: timerStartedAt,
                progress: progress
            ) {
                try await self.workloadRunner.runGPUTensor()
            }
            measurements.append(tensor)

            let media = try await collectPair(
                firstMetric: .mediaH264Encode,
                secondMetric: .mediaH264Decode,
                completedBefore: MacAcceleratorBenchmarkResult.sampleCount * 4,
                timerStartedAt: timerStartedAt,
                progress: progress
            ) {
                let result = try await self.workloadRunner.runH264Media()
                switch result {
                case let .measured(pair):
                    return MacAcceleratorWorkloadOutcome.measured(
                        MacAcceleratorSamplePair(
                        first: pair.encode,
                        second: pair.decode
                        )
                    )
                case .unsupported:
                    return MacAcceleratorWorkloadOutcome.unsupported
                case .temporarilyUnavailable:
                    return MacAcceleratorWorkloadOutcome.temporarilyUnavailable
                }
            }
            measurements.append(contentsOf: media)

            let finalPreflight = try await capturePostflight()
            guard initialPreflight.capturedAt <= finalPreflight.capturedAt else {
                throw MacAcceleratorServiceFault(.invalidResult)
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
            let completedAt = max(max(startedAt, postflight.capturedAt), now())
            let result = MacAcceleratorBenchmarkResult(
                workloadVersion: MacAcceleratorBenchmarkResult.protocolVersion,
                startedAt: startedAt,
                completedAt: completedAt,
                environment: environment,
                preflight: initialPreflight,
                postflight: postflight,
                measurements: measurements,
                failure: nil
            )
            guard result.isComplete else {
                throw MacAcceleratorServiceFault(.invalidResult)
            }
            try Task.checkCancellation()
            return result
        } catch {
            throw error
        }
    }

    func collectSingle(
        metric: MacAcceleratorMetric,
        completedBefore: Int,
        timerStartedAt: UInt64,
        progress: @escaping @Sendable (MacAcceleratorBenchmarkProgress) async -> Void,
        operation: @escaping @Sendable () async throws
            -> MacAcceleratorWorkloadOutcome<BenchmarkComponentSample>
    ) async throws -> MacAcceleratorMeasurement {
        _ = try await captureSafePreflight()
        let expectedCount = MacAcceleratorBenchmarkResult.sampleCount
        let first = try await operation()
        switch first {
        case .unsupported:
            try await emitSkipped(
                metric: metric,
                completedSampleCount: completedBefore + expectedCount,
                timerStartedAt: timerStartedAt,
                progress: progress
            )
            return MacAcceleratorMeasurement(
                metric: metric,
                availability: .unsupported,
                samples: []
            )
        case .temporarilyUnavailable:
            try await emitSkipped(
                metric: metric,
                completedSampleCount: completedBefore + expectedCount,
                timerStartedAt: timerStartedAt,
                progress: progress
            )
            return MacAcceleratorMeasurement(
                metric: metric,
                availability: .temporarilyUnavailable,
                samples: []
            )
        case let .measured(firstSample):
            var samples = [firstSample]
            try await emit(
                metric: metric,
                completedSampleCount: completedBefore + 1,
                timerStartedAt: timerStartedAt,
                progress: progress
            )
            while samples.count < expectedCount {
                try Task.checkCancellation()
                guard case let .measured(sample) = try await operation() else {
                    throw MacAcceleratorServiceFault(.invalidResult)
                }
                samples.append(sample)
                try await emit(
                    metric: metric,
                    completedSampleCount: completedBefore + samples.count,
                    timerStartedAt: timerStartedAt,
                    progress: progress
                )
            }
            let measurement = MacAcceleratorMeasurement(
                metric: metric,
                availability: .measured,
                samples: samples
            )
            guard measurement.isValid(expectedSampleCount: expectedCount) else {
                throw MacAcceleratorServiceFault(.validationFailed(metric))
            }
            return measurement
        }
    }

    func collectPair(
        firstMetric: MacAcceleratorMetric,
        secondMetric: MacAcceleratorMetric,
        completedBefore: Int,
        timerStartedAt: UInt64,
        progress: @escaping @Sendable (MacAcceleratorBenchmarkProgress) async -> Void,
        operation: @escaping @Sendable () async throws
            -> MacAcceleratorWorkloadOutcome<MacAcceleratorSamplePair>
    ) async throws -> [MacAcceleratorMeasurement] {
        _ = try await captureSafePreflight()
        let expectedCount = MacAcceleratorBenchmarkResult.sampleCount
        let first = try await operation()
        switch first {
        case .unsupported, .temporarilyUnavailable:
            let availability: MacAcceleratorAvailability = {
                if case .unsupported = first { return .unsupported }
                return .temporarilyUnavailable
            }()
            try await emitSkipped(
                metric: firstMetric,
                completedSampleCount: completedBefore + expectedCount,
                timerStartedAt: timerStartedAt,
                progress: progress
            )
            try await emitSkipped(
                metric: secondMetric,
                completedSampleCount: completedBefore + expectedCount * 2,
                timerStartedAt: timerStartedAt,
                progress: progress
            )
            return [
                MacAcceleratorMeasurement(
                    metric: firstMetric,
                    availability: availability,
                    samples: []
                ),
                MacAcceleratorMeasurement(
                    metric: secondMetric,
                    availability: availability,
                    samples: []
                ),
            ]
        case let .measured(pair):
            var firstSamples = [pair.first]
            var secondSamples = [pair.second]
            try await emit(
                metric: firstMetric,
                completedSampleCount: completedBefore + 1,
                timerStartedAt: timerStartedAt,
                progress: progress
            )
            try await emit(
                metric: secondMetric,
                completedSampleCount: completedBefore + 2,
                timerStartedAt: timerStartedAt,
                progress: progress
            )
            while firstSamples.count < expectedCount {
                try Task.checkCancellation()
                guard case let .measured(next) = try await operation() else {
                    throw MacAcceleratorServiceFault(.invalidResult)
                }
                firstSamples.append(next.first)
                secondSamples.append(next.second)
                try await emit(
                    metric: firstMetric,
                    completedSampleCount: completedBefore + firstSamples.count * 2 - 1,
                    timerStartedAt: timerStartedAt,
                    progress: progress
                )
                try await emit(
                    metric: secondMetric,
                    completedSampleCount: completedBefore + firstSamples.count * 2,
                    timerStartedAt: timerStartedAt,
                    progress: progress
                )
            }
            let firstMeasurement = MacAcceleratorMeasurement(
                metric: firstMetric,
                availability: .measured,
                samples: firstSamples
            )
            let secondMeasurement = MacAcceleratorMeasurement(
                metric: secondMetric,
                availability: .measured,
                samples: secondSamples
            )
            guard firstMeasurement.isValid(expectedSampleCount: expectedCount) else {
                throw MacAcceleratorServiceFault(.validationFailed(firstMetric))
            }
            guard secondMeasurement.isValid(expectedSampleCount: expectedCount) else {
                throw MacAcceleratorServiceFault(.validationFailed(secondMetric))
            }
            return [firstMeasurement, secondMeasurement]
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
            throw MacAcceleratorServiceFault(.cancelled)
        } catch {
            throw MacAcceleratorServiceFault(.invalidResult)
        }
        if let issue = MacBenchmarkPreflightPolicy.blockingIssue(in: snapshot) {
            throw MacAcceleratorServiceFault(.safetyCheck(issue))
        }
        guard MacBenchmarkPreflightPolicy.isComparable(snapshot) else {
            throw MacAcceleratorServiceFault(.invalidResult)
        }
        return snapshot
    }

    func capturePostflight() async throws -> BenchmarkPreflight {
        try Task.checkCancellation()
        do {
            let snapshot = try await preflightService.capture(
                requiredDiskBytes: Self.requiredDiskBytes
            )
            guard snapshot.requiredDiskBytes == Self.requiredDiskBytes,
                  snapshot.availableDiskBytes >= 0,
                  MacBenchmarkPreflightPolicy.warnings(for: snapshot)
                    == snapshot.warnings else {
                throw MacAcceleratorServiceFault(.invalidResult)
            }
            return snapshot
        } catch is CancellationError {
            throw MacAcceleratorServiceFault(.cancelled)
        } catch let fault as MacAcceleratorServiceFault {
            throw fault
        } catch {
            throw MacAcceleratorServiceFault(.invalidResult)
        }
    }

    func emitSkipped(
        metric: MacAcceleratorMetric,
        completedSampleCount: Int,
        timerStartedAt: UInt64,
        progress: @escaping @Sendable (MacAcceleratorBenchmarkProgress) async -> Void
    ) async throws {
        try await emit(
            metric: metric,
            completedSampleCount: completedSampleCount,
            timerStartedAt: timerStartedAt,
            progress: progress
        )
    }

    func emit(
        metric: MacAcceleratorMetric,
        completedSampleCount: Int,
        timerStartedAt: UInt64,
        progress: @escaping @Sendable (MacAcceleratorBenchmarkProgress) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let sampledAt = monotonicNow()
        guard sampledAt >= timerStartedAt,
              completedSampleCount >= 0,
              completedSampleCount <= Self.totalSampleCount else {
            throw MacAcceleratorServiceFault(.invalidResult)
        }
        await progress(
            MacAcceleratorBenchmarkProgress(
                metric: metric,
                completedSampleCount: completedSampleCount,
                totalSampleCount: Self.totalSampleCount,
                elapsedSeconds: Double(sampledAt - timerStartedAt) / 1_000_000_000
            )
        )
        try Task.checkCancellation()
    }

    static func isValid(_ environment: BenchmarkEnvironmentMetadata) -> Bool {
        environment.architecture == .arm64
            && environment.activeProcessorCount > 0
            && environment.physicalMemoryBytes > 0
            && !environment.chipName.isEmpty
            && !environment.operatingSystemVersion.isEmpty
            && !environment.appVersion.isEmpty
            && !environment.appBuild.isEmpty
    }

    static func failure(from error: Error) -> MacAcceleratorBenchmarkFailure {
        if let fault = error as? MacAcceleratorServiceFault {
            return fault.failure
        }
        if let workloadError = error as? MacAcceleratorWorkloadError {
            switch workloadError {
            case let .timedOut(metric):
                return .timedOut(metric)
            case .temporarilyUnavailable:
                return .invalidResult
            }
        }
        if error is CancellationError || Task.isCancelled {
            return .cancelled
        }
        if let coordinatorError = error as? HeavyWorkCoordinator.Error {
            switch coordinatorError {
            case let .busy(activeOwner):
                return .busy(activeTask: String(describing: activeOwner))
            case .invalidLease:
                return .invalidResult
            }
        }
        if let kernelError = error as? BenchmarkKernelError {
            switch kernelError {
            case .checksumMismatch, .invalidMetric:
                return .invalidResult
            case .resourceLimit:
                return .invalidResult
            case .unavailable, .invalidConfiguration, .systemFailure:
                return .invalidResult
            }
        }
        return .invalidResult
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
        startedAt: Date,
        preflight: BenchmarkPreflight,
        environment: BenchmarkEnvironmentMetadata,
        failure: MacAcceleratorBenchmarkFailure
    ) -> MacAcceleratorBenchmarkResult {
        MacAcceleratorBenchmarkResult(
            workloadVersion: MacAcceleratorBenchmarkResult.protocolVersion,
            startedAt: startedAt,
            completedAt: nil,
            environment: environment,
            preflight: preflight,
            postflight: nil,
            measurements: [],
            failure: failure
        )
    }
}

private struct MacAcceleratorServiceFault: Error, Sendable {
    let failure: MacAcceleratorBenchmarkFailure

    init(_ failure: MacAcceleratorBenchmarkFailure) {
        self.failure = failure
    }
}
