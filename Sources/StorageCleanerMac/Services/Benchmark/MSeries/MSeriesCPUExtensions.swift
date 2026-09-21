import Foundation

/// Optional raw-only extensions. Fixed integer work units are identical to
/// Core; only worker count and the number of complete observations vary.
/// Core environment evidence is sealed before entering this phase.
enum MSeriesCPUExtensions {
    static let version = "mseries-cpu-extensions-v1"
    struct Result: Sendable {
        let measurements: [MSeriesMeasurement]
        let environment: [MSeriesEnvironmentPoint]
    }
    static func threadCounts(logicalCores: Int) -> [Int] {
        guard logicalCores > 0 else { return [] }
        var counts = [1], next = 2
        while next < logicalCores {
            counts.append(next)
            guard next <= Int.max / 2 else { break }
            next *= 2
        }
        if counts.last != logicalCores { counts.append(logicalCores) }
        return counts
    }
    static func run(hardware: MSeriesHardware, cancellation: MSeriesCancellation,
                    progress: @Sendable (String) async -> Void) async -> Result {
        var values: [MSeriesMeasurement] = [], environment: [MSeriesEnvironmentPoint] = []
        let counts = threadCounts(logicalCores: hardware.logicalCores)
        do {
            for count in counts {
                try cancellation.check()
                await progress("cpu.threadCurve.\(count)")
                environment.append(.capture())
                let budget = min(hardware.sharedBudgetBytes, MSeriesHardware.capture().sharedBudgetBytes)
                let kernel = try MSeriesCPUMemoryKernel(kind: 0, workers: count, budgetBytes: budget)
                values.append(try kernel.measure(id: "cpu.threadCurve.\(count)", cancellation: cancellation))
                environment.append(.capture())
            }
            // At most twelve complete batches and about six seconds of
            // observation. Keep every sample, including slow batches; never
            // repeat until a target score is reached.
            let started = ContinuousClock.now
            let budget = min(hardware.sharedBudgetBytes, MSeriesHardware.capture().sharedBudgetBytes)
            let kernel = try MSeriesCPUMemoryKernel(kind: 0, workers: hardware.logicalCores, budgetBytes: budget)
            for index in 0..<12 {
                try cancellation.check()
                if index > 0 && started.duration(to: .now) >= .seconds(6) { break }
                await progress("cpu.sustained.short.\(index + 1)")
                environment.append(.capture())
                values.append(try kernel.measure(id: "cpu.sustained.short.\(index + 1)", cancellation: cancellation))
                environment.append(.capture())
            }
        } catch {
            let status: MSeriesAvailability
            switch error {
            case is CancellationError: status = .cancelled
            case MSeriesKernelError.resourceBudget, MSeriesKernelError.allocation: status = .insufficientResources
            default: status = .failed
            }
            values.append(MSeriesMeasurement(id: "cpu.extensions.remaining", unit: "unavailable", availability: status,
                reason: error is MSeriesKernelError ? String(describing: error) : "cancelled-or-failed",
                samples: [], statistics: nil, repetitions: 1, workers: 1))
        }
        return Result(measurements: values, environment: environment)
    }
}
