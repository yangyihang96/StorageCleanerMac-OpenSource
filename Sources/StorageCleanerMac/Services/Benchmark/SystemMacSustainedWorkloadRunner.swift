import Foundation

struct SystemMacSustainedBenchmarkWorkloadRunner: MacSustainedWorkloadRunning {
    private let cpuOperation: @Sendable (Int) async throws -> BenchmarkComponentSample
    private let gpuOperation: @Sendable () async throws -> BenchmarkComponentSample

    init(
        cpuKernel: CPUBenchmarkKernel = CPUBenchmarkKernel(
            configuration: Self.sustainedCPUConfiguration
        ),
        gpuKernel: Metal3DBenchmarkKernel = Metal3DBenchmarkKernel(
            configuration: Self.sustainedGPUConfiguration
        )
    ) {
        cpuOperation = { activeProcessorCount in
            try await Self.runCPU(
                kernel: cpuKernel,
                activeProcessorCount: activeProcessorCount
            )
        }
        gpuOperation = {
            try await Self.runGPU(kernel: gpuKernel)
        }
    }

    init(
        cpuOperation: @escaping @Sendable (Int) async throws -> BenchmarkComponentSample,
        gpuOperation: @escaping @Sendable () async throws -> BenchmarkComponentSample
    ) {
        self.cpuOperation = cpuOperation
        self.gpuOperation = gpuOperation
    }

    func runSerialRound(activeProcessorCount: Int) async throws
        -> MacSustainedWorkloadSample
    {
        guard activeProcessorCount > 1 else {
            throw MacSustainedWorkloadError.unsupportedCPU
        }

        // Keep thermal and power effects attributable to one component at a time.
        let cpuSample = try await cpuOperation(activeProcessorCount)
        try Task.checkCancellation()
        let gpuSample = try await gpuOperation()
        try Task.checkCancellation()
        guard Self.isValid(cpuSample), Self.isValid(gpuSample) else {
            throw MacSustainedWorkloadError.invalidResult
        }
        return MacSustainedWorkloadSample(
            cpuMultiSample: cpuSample,
            gpuRasterSample: gpuSample
        )
    }
}

extension SystemMacSustainedBenchmarkWorkloadRunner {
    static let sustainedCPUConfiguration = CPUBenchmarkKernel.Configuration(
        quick: CPUBenchmarkKernel.Limits(
            operationCount: 64_000_000,
            multiOperationCountPerWorker: 64_000_000,
            warmupOperationCount: 4_000_000,
            multiWarmupOperationCount: 4_000_000,
            chunkSize: 32_768,
            maximumElapsedSeconds: 5
        ),
        full: CPUBenchmarkKernel.Limits(
            operationCount: 64_000_000,
            multiOperationCountPerWorker: 64_000_000,
            warmupOperationCount: 4_000_000,
            multiWarmupOperationCount: 4_000_000,
            chunkSize: 32_768,
            maximumElapsedSeconds: 5
        )
    )

    static let sustainedGPUConfiguration = Metal3DBenchmarkKernel.Configuration(
        limits: Metal3DBenchmarkKernel.Limits(
            width: 1_920,
            height: 1_080,
            instanceCount: 262_144,
            frameCount: 90,
            maximumElapsedSeconds: 5
        )
    )
}

private extension SystemMacSustainedBenchmarkWorkloadRunner {
    static func runCPU(
        kernel: CPUBenchmarkKernel,
        activeProcessorCount: Int
    ) async throws -> BenchmarkComponentSample {
        do {
            return try await kernel.runMulti(
                profile: .quick,
                activeProcessorCount: activeProcessorCount
            ).sample
        } catch is CancellationError {
            throw CancellationError()
        } catch BenchmarkKernelError.unavailable {
            throw MacSustainedWorkloadError.unsupportedCPU
        } catch BenchmarkKernelError.resourceLimit {
            throw MacSustainedWorkloadError.temporarilyUnavailable
        } catch {
            throw MacSustainedWorkloadError.invalidResult
        }
    }

    static func runGPU(
        kernel: Metal3DBenchmarkKernel
    ) async throws -> BenchmarkComponentSample {
        do {
            return try await kernel.run().sample
        } catch is CancellationError {
            throw CancellationError()
        } catch BenchmarkKernelError.unavailable {
            throw MacSustainedWorkloadError.unsupportedGPU
        } catch BenchmarkKernelError.resourceLimit {
            throw MacSustainedWorkloadError.temporarilyUnavailable
        } catch {
            throw MacSustainedWorkloadError.invalidResult
        }
    }

    static func isValid(_ sample: BenchmarkComponentSample) -> Bool {
        sample.value.isFinite
            && sample.value > 0
            && sample.elapsedSeconds.isFinite
            && sample.elapsedSeconds > 0
            && sample.checksum != 0
    }
}

struct SystemMacSustainedTelemetryProbe: MacSustainedTelemetryProbing {
    func capture(elapsedSeconds: Double) async -> MacSustainedTelemetrySample {
        let speeds = SMCFanSpeedService.currentFanSpeedsRPM()
        return MacSustainedTelemetrySample(
            elapsedSeconds: elapsedSeconds,
            thermalState: Self.currentThermalState(),
            powerSource: Self.currentPowerSource(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            chipTemperatureCelsius:
                SMCFanSpeedService.currentChipTemperatureCelsius(),
            fans: speeds.isEmpty ? .unsupported : .measured(speeds)
        )
    }
}

private extension SystemMacSustainedTelemetryProbe {
    static func currentThermalState() -> BenchmarkThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .unknown
        }
    }

    static func currentPowerSource() -> BenchmarkPowerSource {
        switch BatteryPowerService.currentSystemPowerSource() {
        case .acPower:
            .acPower
        case .batteryPower:
            .battery
        case .unknown:
            .unknown
        }
    }
}
