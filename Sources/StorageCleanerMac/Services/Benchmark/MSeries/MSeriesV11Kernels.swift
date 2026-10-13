import Darwin
import FanControlShared
import Foundation

/// mach_continuous_time is system-wide (unlike a process-relative clock origin).
enum MSeriesV11Clock {
    static var nanoseconds: UInt64 { PowermetricsMonotonicClock.nanoseconds }
}

protocol MSeriesV11BatchDriving: Sendable {
    /// Allocates outside timing; one fixed batch warms up/pilots, then locks batch size.
    func prepare(id: String, workers: Int, cancellation: MSeriesCancellation) async throws
    func next(id: String, cancellation: MSeriesCancellation) async throws -> MSeriesV11Batch
    /// Called after cancellation/timeout and after every successful stage; must drain.
    func finish() async
}

/// The orchestration never owns C workspaces or Metal commands; this actor does.
actor SystemMSeriesV11BatchDriver: MSeriesV11BatchDriving {
    private var cpu: MSeriesCPUMemoryKernel?
    private var gpu: (any MSeriesV11Metal3DDriving)?
    private var repetitions = 1
    private var gpuMode = false
    private let gpuDriverFactory: @Sendable () -> any MSeriesV11Metal3DDriving
    private let now: @Sendable () -> UInt64

    init(gpuDriverFactory: @escaping @Sendable () -> any MSeriesV11Metal3DDriving = { Metal3DBenchmarkKernel.makeV11Driver() },
         now: @escaping @Sendable () -> UInt64 = { MSeriesV11Clock.nanoseconds }) {
        self.gpuDriverFactory = gpuDriverFactory
        self.now = now
    }

    func prepare(id: String, workers: Int, cancellation: MSeriesCancellation) async throws {
        try cancellation.check()
        gpuMode = id.contains("gpu")
        let worker = Task.detached(priority: .userInitiated) { () throws -> (MSeriesCPUMemoryKernel?, MSeriesV11Batch?) in
            if id.contains("gpu") { return (nil, nil) }
            let kernel = try MSeriesCPUMemoryKernel(kind: 0, workers: workers, budgetBytes: MSeriesHardware.capture().sharedBudgetBytes)
            let pilot = try kernel.v11Batch(id: id, repetitions: 1, cancellation: cancellation)
            return (kernel, pilot)
        }
        let pair = try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
        cpu = pair.0
        if let pilot = pair.1 {
            let elapsed = MSeriesV11Windows.seconds(pilot.startMonotonicNs, pilot.endMonotonicNs)
            guard elapsed <= 2 else { throw MSeriesV11RunError.warmupTimeout }
            repetitions = max(1, min(4096, Int(ceil(0.15 / elapsed))))
        } else {
            let driver = gpuDriverFactory()
            gpu = driver
            // Same standard scene; one frame is the bounded, fixed command batch.
            try await driver.prepare(workload: .init(width: 1920, height: 1080, instanceCount: 262144, frameCount: 1, trianglesPerInstance: 12))
            let warmupStart = now()
            try await driver.warmUp()
            guard MSeriesV11Windows.seconds(warmupStart, now()) <= 2 else { throw MSeriesV11RunError.warmupTimeout }
        }
        try cancellation.check()
    }

    func next(id: String, cancellation: MSeriesCancellation) async throws -> MSeriesV11Batch {
        try cancellation.check()
        if let cpu {
            let repetitions = repetitions
            let worker = Task.detached(priority: .userInitiated) {
                try cpu.v11Batch(id: id, repetitions: repetitions, cancellation: cancellation)
            }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
        }
        guard gpuMode, let gpu else { throw MSeriesKernelError.invalidOutput }
        let execution = try await gpu.execute()
        let checksum = try await gpu.validate() // outside the recorded GPU/wall interval
        guard let start = execution.startMonotonicNs, let end = execution.endMonotonicNs else { throw MSeriesKernelError.invalidTiming }
        return .init(stageID: id, startMonotonicNs: start, endMonotonicNs: end,
            workUnits: Double(262144 * 12) / 1e6,
            gpuElapsedSeconds: execution.usedWallClockFallback ? nil : execution.gpuElapsedSeconds,
            checksum: checksum, clockDomain: MSeriesV11Windows.clockDomain)
    }
    func finish() async {
        if let gpu { await gpu.tearDown() }
        gpu = nil
        cpu = nil
    }
}
