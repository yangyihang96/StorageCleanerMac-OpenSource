import Foundation

/// The measurement layer used by the v7 coordinator. Each category is run
/// serially; progress is emitted only at workload boundaries, never inside a
/// timed loop.
protocol BenchmarkV7WorkloadRunning: Sendable {
    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult]

    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult]
}

extension BenchmarkV7WorkloadRunning {
    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult] {
        do {
            let metrics = try await run(
                plan: plan,
                categories: categories,
                targetDirectory: targetDirectory
            ) { category, workloadID, repetition, fraction in
                executionRecorder.observeCategory(
                    category: category,
                    workloadID: workloadID,
                    repetition: repetition
                )
                await progress(category, workloadID, repetition, fraction)
            }
            try Task.checkCancellation()
            executionRecorder.finishActive(status: .completed, failureReason: nil)
            return metrics
        } catch {
            executionRecorder.finishActive(
                status: BenchmarkV7WorkloadFailureReason.executionStatus(for: error),
                failureReason: BenchmarkV7WorkloadFailureReason.executionReason(for: error)
            )
            throw error
        }
    }
}

final class BenchmarkV7WorkloadExecutionRecorder: @unchecked Sendable {
    struct Token: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Entry {
        let token: Token
        let category: BenchmarkV7Category
        let workloadID: String
        let repetition: Int?
        let startedAt: Date
        let startedInstant: ContinuousClock.Instant
        var record: BenchmarkV7WorkloadExecutionRecord?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var lateOperations: [BenchmarkLateOperationHandle] = []
    private var isClosed = false

    @discardableResult
    func begin(
        category: BenchmarkV7Category,
        workloadID: String,
        repetition: Int?
    ) -> Token {
        let entry = Entry(
            token: Token(id: UUID()),
            category: category,
            workloadID: workloadID,
            repetition: repetition,
            startedAt: Date(),
            startedInstant: ContinuousClock.now,
            record: nil
        )
        lock.lock()
        if !isClosed { entries.append(entry) }
        lock.unlock()
        return entry.token
    }

    func observeCategory(
        category: BenchmarkV7Category,
        workloadID: String,
        repetition: Int?
    ) {
        let endedAt = Date()
        let endedInstant = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        if let active = entries.last(where: { $0.record == nil }),
           active.category == category,
           active.workloadID == workloadID,
           active.repetition == repetition {
            return
        }
        finishActiveLocked(
            status: .completed,
            failureReason: nil,
            endedAt: endedAt,
            endedInstant: endedInstant
        )
        entries.append(Entry(
            token: Token(id: UUID()),
            category: category,
            workloadID: workloadID,
            repetition: repetition,
            startedAt: endedAt,
            startedInstant: endedInstant,
            record: nil
        ))
    }

    func finish(
        _ token: Token,
        status: BenchmarkV7WorkloadExecutionStatus,
        failureReason: String?
    ) {
        let endedAt = Date()
        let endedInstant = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: {
            $0.token == token && $0.record == nil
        }) else { return }
        entries[index].record = Self.record(
            from: entries[index],
            status: status,
            failureReason: failureReason,
            endedAt: endedAt,
            endedInstant: endedInstant
        )
    }

    func finishActive(
        status: BenchmarkV7WorkloadExecutionStatus,
        failureReason: String?
    ) {
        let endedAt = Date()
        let endedInstant = ContinuousClock.now
        lock.lock()
        finishActiveLocked(
            status: status,
            failureReason: failureReason,
            endedAt: endedAt,
            endedInstant: endedInstant
        )
        lock.unlock()
    }

    func markTimedOut(reason: String) {
        let endedAt = Date()
        let endedInstant = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        if entries.contains(where: { $0.record == nil }) {
            finishActiveLocked(
                status: .timedOut,
                failureReason: reason,
                endedAt: endedAt,
                endedInstant: endedInstant
            )
            return
        }
        guard let index = entries.lastIndex(where: { $0.record?.status == .cancelled }),
              let cancelled = entries[index].record else { return }
        entries[index].record = BenchmarkV7WorkloadExecutionRecord(
            category: cancelled.category,
            workloadID: cancelled.workloadID,
            repetition: cancelled.repetition,
            startedAt: cancelled.startedAt,
            endedAt: cancelled.endedAt,
            elapsedSeconds: cancelled.elapsedSeconds,
            status: .timedOut,
            failureReason: reason
        )
    }

    func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
    }

    func registerLateOperation(_ operation: BenchmarkLateOperationHandle) {
        lock.lock()
        lateOperations.append(operation)
        lock.unlock()
    }

    func waitForLateOperations() async {
        for operation in takeLateOperations() {
            await operation.wait()
        }
    }

    var pendingLateOperationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lateOperations.count
    }

    private func takeLateOperations() -> [BenchmarkLateOperationHandle] {
        lock.lock()
        defer { lock.unlock() }
        let operations = lateOperations
        lateOperations.removeAll()
        return operations
    }

    var records: [BenchmarkV7WorkloadExecutionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return entries.compactMap(\.record)
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.lazy.filter { $0.record == nil }.count
    }

    private func finishActiveLocked(
        status: BenchmarkV7WorkloadExecutionStatus,
        failureReason: String?,
        endedAt: Date,
        endedInstant: ContinuousClock.Instant
    ) {
        for index in entries.indices where entries[index].record == nil {
            entries[index].record = Self.record(
                from: entries[index],
                status: status,
                failureReason: failureReason,
                endedAt: endedAt,
                endedInstant: endedInstant
            )
        }
    }

    private static func record(
        from entry: Entry,
        status: BenchmarkV7WorkloadExecutionStatus,
        failureReason: String?,
        endedAt: Date,
        endedInstant: ContinuousClock.Instant
    ) -> BenchmarkV7WorkloadExecutionRecord {
        let components = entry.startedInstant.duration(to: endedInstant).components
        let elapsed = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return BenchmarkV7WorkloadExecutionRecord(
            category: entry.category,
            workloadID: entry.workloadID,
            repetition: entry.repetition,
            startedAt: entry.startedAt,
            endedAt: endedAt,
            elapsedSeconds: max(0, elapsed),
            status: status,
            failureReason: failureReason
        )
    }
}

struct SystemBenchmarkV7WorkloadRunner: BenchmarkV7WorkloadRunning {
    static let workloadVersion = "benchmark-v7-workload-runner-v1"

    private typealias MetricSeries = [
        String: (manifest: BenchmarkV7MetricManifest, samples: [BenchmarkV7RawSample])
    ]

    private let cpuKernel: CPUBenchmarkV7Kernel
    private let memoryWorkload: BenchmarkV7MemoryWorkload

    init(
        cpuKernel: CPUBenchmarkV7Kernel = CPUBenchmarkV7Kernel(),
        memoryWorkload: BenchmarkV7MemoryWorkload = BenchmarkV7MemoryWorkload()
    ) {
        self.cpuKernel = cpuKernel
        self.memoryWorkload = memoryWorkload
    }

    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult] {
        try await run(
            plan: plan,
            categories: categories,
            targetDirectory: targetDirectory,
            executionRecorder: BenchmarkV7WorkloadExecutionRecorder(),
            progress: progress
        )
    }

    func run(
        plan: BenchmarkV7Plan,
        categories: [BenchmarkV7Category],
        targetDirectory: URL,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder,
        progress: @escaping @Sendable (
            BenchmarkV7Category,
            String,
            Int,
            Double
        ) async -> Void
    ) async throws -> [BenchmarkV7MetricResult] {
        guard plan.kind != .sustained else {
            throw BenchmarkV7WorkloadRunnerError.unsupportedPlan(plan.kind)
        }
        let orderedCategories = categories.filter { $0 != .sustained }
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = plan.kind == .custom
            ? startedAt.advanced(by: .seconds(plan.expectedMaximumDurationSeconds))
            : nil
        var series: MetricSeries = [:]
        let total = max(1, orderedCategories.count)
        var cycle = 0
        repeat {
            for (index, category) in orderedCategories.enumerated() {
                // Custom runs stop before beginning the next category, so the
                // declared budget can overrun only by the category in flight.
                if let deadline, clock.now >= deadline {
                    break
                }
                try Task.checkCancellation()
                let startingFraction = deadline.map { _ in
                    min(1, elapsedSeconds(from: startedAt, to: clock.now)
                        / Double(plan.expectedMaximumDurationSeconds))
                } ?? Double(index) / Double(total)
                await progress(
                    category,
                    category.rawValue,
                    cycle * total + index + 1,
                    startingFraction
                )
                let measured: [BenchmarkV7MetricResult]
                do {
                    switch category {
                    case .cpu:
                        measured = try await cpuMetrics(
                            for: plan,
                            cycle: cycle,
                            executionRecorder: executionRecorder
                        )
                    case .gpu:
                        measured = try await gpuMetrics(
                            for: plan,
                            cycle: cycle,
                            executionRecorder: executionRecorder
                        )
                    case .memory:
                        measured = try await memoryMetrics(
                            for: plan,
                            cycle: cycle,
                            executionRecorder: executionRecorder
                        )
                    case .storage:
                        measured = try await storageMetrics(
                            for: plan,
                            targetDirectory: targetDirectory,
                            cycle: cycle,
                            executionRecorder: executionRecorder
                        )
                    case .display:
                        measured = try await displayMetrics(
                            for: plan,
                            cycle: cycle,
                            executionRecorder: executionRecorder
                        )
                    case .sustained:
                        measured = []
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    if error is BenchmarkV7SubtestTerminalFault {
                        throw error
                    }
                    let failure = workloadFailure(from: error, category: category)
                    let priorMetrics = (try? finalizedMetrics(from: series)) ?? []
                    throw BenchmarkV7WorkloadFailure(
                        record: failure.record,
                        completedMetrics: priorMetrics + failure.completedMetrics
                    )
                }
                for metric in measured {
                    if var existing = series[metric.manifest.id] {
                        guard existing.manifest == metric.manifest else {
                            throw BenchmarkV7WorkloadRunnerError.invalidMeasurement
                        }
                        existing.samples.append(contentsOf: metric.samples)
                        series[metric.manifest.id] = existing
                    } else {
                        series[metric.manifest.id] = (metric.manifest, metric.samples)
                    }
                }
                let fraction = deadline.map { _ in
                    min(1, elapsedSeconds(from: startedAt, to: clock.now)
                        / Double(plan.expectedMaximumDurationSeconds))
                } ?? Double(index + 1) / Double(total)
                await progress(
                    category,
                    measured.first?.manifest.id ?? category.rawValue,
                    cycle * total + index + 1,
                    fraction
                )
                if index < orderedCategories.count - 1 {
                    // A versioned, brief settle interval belongs to the plan rather
                    // than any workload's timed region.
                    try await Task.sleep(for: settleDuration(for: plan))
                }
            }
            cycle += 1
        } while deadline.map({ clock.now < $0 }) ?? false

        let metrics = try finalizedMetrics(from: series)
        guard !metrics.isEmpty,
              metrics.allSatisfy(\.isValid) else {
            throw BenchmarkV7WorkloadRunnerError.invalidMeasurement
        }
        return metrics
    }
}

enum BenchmarkV7WorkloadRunnerError: Error, Equatable, Sendable {
    case unsupportedPlan(BenchmarkV7PlanKind)
    case invalidMeasurement
    case unavailableCategory(BenchmarkV7Category)
}

/// Stable, non-sensitive descriptions for workload failures. Do not fall back
/// to `String(reflecting:)` here: kernel errors can carry implementation
/// details that are not suitable for persisted history or user-facing output.
enum BenchmarkV7WorkloadFailureReason {
    static func safe(_ error: Error) -> String {
        if let error = error as? BenchmarkKernelError {
            return switch error {
            case .unavailable: "The workload is unavailable on this Mac."
            case .invalidConfiguration: "The workload configuration was rejected."
            case .resourceLimit: "The workload exceeded its safety or time limit."
            case .invalidMetric:
                "The workload returned a non-finite, zero, or out-of-budget measurement."
            case .checksumMismatch: "The workload output did not match its calibration checksum."
            case .systemFailure: "The workload reported a system failure."
            }
        }
        if let error = error as? BenchmarkV7MemoryWorkloadError {
            return switch error {
            case .unsupportedPlan: "The memory workload does not support this plan."
            case .invalidConfiguration: "The memory workload configuration was rejected."
            case .unavailable: "The memory workload is unavailable on this Mac."
            case .timedOut: "The memory workload exceeded its time limit."
            case .checksumMismatch: "The memory workload checksum did not match."
            case .invalidMeasurement: "The memory workload returned an invalid measurement."
            }
        }
        if let error = error as? StorageRandomAccessBenchmarkV7.Failure {
            return switch error {
            case .invalidConfiguration: "The random-storage workload configuration was rejected."
            case .systemFailure: "The random-storage workload reported a system failure."
            case .validationFailed: "The random-storage readback validation failed."
            case .invalidMetric: "The random-storage workload returned an invalid measurement."
            }
        }
        if let error = error as? BenchmarkV7WorkloadRunnerError {
            return switch error {
            case .unsupportedPlan: "The workload plan is unsupported."
            case .invalidMeasurement: "The workload returned an invalid measurement."
            case .unavailableCategory: "The workload category is unavailable on this Mac."
            }
        }
        if error is BenchmarkStatisticsError {
            return "The workload samples could not produce valid statistics."
        }
        return "The workload failed validation."
    }

    static func executionStatus(
        for error: Error
    ) -> BenchmarkV7WorkloadExecutionStatus {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let error = error as? BenchmarkV7MemoryWorkloadError,
           error == .timedOut {
            return .timedOut
        }
        return .failed
    }

    static func executionReason(for error: Error) -> String {
        if error is CancellationError || Task.isCancelled {
            return "The workload was cancelled."
        }
        if let failure = error as? BenchmarkV7WorkloadFailure {
            return failure.record.reason
        }
        return safe(error)
    }
}

struct BenchmarkV7WorkloadFailure: Error, Equatable, Sendable {
    let record: BenchmarkV7WorkloadFailureRecord
    let completedMetrics: [BenchmarkV7MetricResult]

    init(
        category: BenchmarkV7Category,
        workloadID: String,
        reason: String,
        completedMetrics: [BenchmarkV7MetricResult] = []
    ) {
        record = BenchmarkV7WorkloadFailureRecord(
            category: category,
            workloadID: workloadID,
            reason: reason
        )
        self.completedMetrics = completedMetrics
    }

    init(
        record: BenchmarkV7WorkloadFailureRecord,
        completedMetrics: [BenchmarkV7MetricResult]
    ) {
        self.record = record
        self.completedMetrics = completedMetrics
    }
}

enum BenchmarkV7SubtestTerminalKind: Sendable {
    case timedOut
    case timerFailure
}

struct BenchmarkV7SubtestTerminalFault: Error, Sendable {
    let kind: BenchmarkV7SubtestTerminalKind
    let context: BenchmarkV7TimeoutContext
    let lateOperation: BenchmarkLateOperationHandle
}

extension SystemBenchmarkV7WorkloadRunner {
    func runSubtest<Value: Sendable>(
        category: BenchmarkV7Category,
        workloadID: String,
        repetition: Int? = nil,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder,
        timeout: Duration = .seconds(120),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let token = executionRecorder.begin(
            category: category,
            workloadID: workloadID,
            repetition: repetition
        )
        let context = BenchmarkV7TimeoutContext(
            phase: .running,
            category: category,
            workloadID: workloadID
        )
        let outcome = await BenchmarkTimedOperation.run(
            timeout: timeout,
            sleep: sleep,
            operation: operation
        )
        switch outcome {
        case let .success(value):
            executionRecorder.finish(token, status: .completed, failureReason: nil)
            return value
        case let .failure(error):
            let status = BenchmarkV7WorkloadFailureReason.executionStatus(for: error.value)
            let reason = BenchmarkV7WorkloadFailureReason.executionReason(for: error.value)
            executionRecorder.finish(token, status: status, failureReason: reason)
            if status == .cancelled { throw CancellationError() }
            if let failure = error.value as? BenchmarkV7WorkloadFailure { throw failure }
            throw BenchmarkV7WorkloadFailure(
                category: category,
                workloadID: workloadID,
                reason: reason
            )
        case let .timedOut(lateOperation):
            let reason = "timedOut \(context.detail)"
            executionRecorder.registerLateOperation(lateOperation.handle)
            executionRecorder.finish(token, status: .timedOut, failureReason: reason)
            throw BenchmarkV7SubtestTerminalFault(
                kind: .timedOut,
                context: context,
                lateOperation: lateOperation.handle
            )
        case let .cancelled(lateOperation):
            executionRecorder.registerLateOperation(lateOperation.handle)
            executionRecorder.finish(
                token,
                status: .cancelled,
                failureReason: "The workload was cancelled."
            )
            throw CancellationError()
        case let .timerFailure(lateOperation):
            executionRecorder.registerLateOperation(lateOperation.handle)
            executionRecorder.finish(
                token,
                status: .failed,
                failureReason: "The workload timeout timer failed."
            )
            throw BenchmarkV7SubtestTerminalFault(
                kind: .timerFailure,
                context: context,
                lateOperation: lateOperation.handle
            )
        }
    }
}

private extension SystemBenchmarkV7WorkloadRunner {
    private func finalizedMetrics(from series: MetricSeries) throws -> [BenchmarkV7MetricResult] {
        try series.values
            .map { entry in
                try metric(
                    id: entry.manifest.id,
                    category: entry.manifest.category,
                    unit: entry.manifest.unit,
                    direction: entry.manifest.direction,
                    weight: entry.manifest.weight,
                    workloadVersion: entry.manifest.workloadVersion,
                    samples: entry.samples
                )
            }
            .sorted { $0.manifest.id < $1.manifest.id }
    }

    func workloadFailure(
        from error: Error,
        category: BenchmarkV7Category
    ) -> BenchmarkV7WorkloadFailure {
        if let failure = error as? BenchmarkV7WorkloadFailure { return failure }
        return BenchmarkV7WorkloadFailure(
            category: category,
            workloadID: category.rawValue,
            reason: actionableReason(for: error)
        )
    }

    func actionableReason(for error: Error) -> String {
        BenchmarkV7WorkloadFailureReason.safe(error)
    }

    func elapsedSeconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    func cpuMetrics(
        for plan: BenchmarkV7Plan,
        cycle: Int,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder
    ) async throws -> [BenchmarkV7MetricResult] {
        let profile = cpuProfile(for: plan)
        let batches = cpuBatchCount(for: plan)
        var singleSamples: [BenchmarkV7RawSample] = []
        var multiSamples: [BenchmarkV7RawSample] = []
        singleSamples.reserveCapacity(batches * 3)
        multiSamples.reserveCapacity(batches * 3)
        for batch in 0..<batches {
            let repetition = cycle * batches + batch + 1
            let single = try await runSubtest(
                category: .cpu,
                workloadID: "cpu.single.mixed",
                repetition: repetition,
                executionRecorder: executionRecorder
            ) {
                try await cpuKernel.measureSingle(profile: profile)
            }
            try Task.checkCancellation()
            let multi = try await runSubtest(
                category: .cpu,
                workloadID: "cpu.multi.particle",
                repetition: repetition,
                executionRecorder: executionRecorder
            ) {
                try await cpuKernel.measureMulti(profile: profile)
            }
            singleSamples.append(contentsOf: single.samples)
            multiSamples.append(contentsOf: multi.samples)
        }
        return [
            try metric(
                id: "cpu.single.mixed",
                category: .cpu,
                unit: "Mops/s",
                direction: .higherIsBetter,
                weight: 0.5,
                workloadVersion: CPUBenchmarkV7Kernel.workloadVersion,
                samples: singleSamples
            ),
            try metric(
                id: "cpu.multi.particle",
                category: .cpu,
                unit: "Mops/s",
                direction: .higherIsBetter,
                weight: 0.5,
                workloadVersion: CPUBenchmarkV7Kernel.workloadVersion,
                samples: multiSamples
            ),
        ]
    }

    func gpuMetrics(
        for plan: BenchmarkV7Plan,
        cycle: Int,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder
    ) async throws -> [BenchmarkV7MetricResult] {
        let repeatCount = gpuSampleCount(for: plan)
        let graphicsKernel = graphicsKernel(for: plan)
        let computeKernel = tensorKernel(for: plan)
        var graphicsSamples: [BenchmarkV7RawSample] = []
        var computeSamples: [BenchmarkV7RawSample] = []
        graphicsSamples.reserveCapacity(repeatCount)
        computeSamples.reserveCapacity(repeatCount)

        for index in 0..<repeatCount {
            let repetition = cycle * repeatCount + index + 1
            try Task.checkCancellation()
            let graphics = try await runSubtest(
                category: .gpu,
                workloadID: "gpu.graphics.offscreen",
                repetition: repetition,
                executionRecorder: executionRecorder
            ) {
                try await graphicsKernel.run()
            }
            graphicsSamples.append(BenchmarkV7RawSample(
                value: graphics.sample.value,
                elapsedSeconds: graphics.sample.elapsedSeconds,
                wallElapsedSeconds: graphics.wallElapsedSeconds,
                checksum: graphics.sample.checksum
            ))
            try Task.checkCancellation()
            let compute = try await runSubtest(
                category: .gpu,
                workloadID: "gpu.compute.fp16",
                repetition: repetition,
                executionRecorder: executionRecorder
            ) {
                try await computeKernel.runDetailed()
            }
            computeSamples.append(BenchmarkV7RawSample(
                value: compute.sample.value,
                elapsedSeconds: compute.sample.elapsedSeconds,
                wallElapsedSeconds: compute.wallElapsedSeconds,
                checksum: compute.sample.checksum
            ))
        }

        return [
            try metric(
                id: "gpu.graphics.offscreen",
                category: .gpu,
                unit: "Mtri/s",
                direction: .higherIsBetter,
                weight: 0.5,
                workloadVersion: graphicsWorkloadVersion(for: plan),
                samples: graphicsSamples
            ),
            try metric(
                id: "gpu.compute.fp16",
                category: .gpu,
                unit: "TFLOPS",
                direction: .higherIsBetter,
                weight: 0.5,
                workloadVersion: tensorWorkloadVersion(for: plan),
                samples: computeSamples
            ),
        ]
    }

    func memoryMetrics(
        for plan: BenchmarkV7Plan,
        cycle: Int,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder
    ) async throws -> [BenchmarkV7MetricResult] {
        let batches = memoryBatchCount(for: plan)
        var rawMetrics: [BenchmarkV7MemoryWorkload.MetricID: [BenchmarkV7RawSample]] = [:]
        for batch in 0..<batches {
            let result = try await runSubtest(
                category: .memory,
                workloadID: "memory.workload",
                repetition: cycle * batches + batch + 1,
                executionRecorder: executionRecorder
            ) {
                try await memoryWorkload.run(planKind: memoryPlanKind(for: plan))
            }
            for metricResult in result.metrics {
                rawMetrics[metricResult.id, default: []].append(contentsOf: metricResult.samples)
            }
        }
        return try rawMetrics.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
            guard let samples = rawMetrics[id] else { return nil }
            return try metric(
                id: id.rawValue,
                category: .memory,
                unit: id == .pointerChaseLatency ? "ns" : "GB/s",
                direction: id == .pointerChaseLatency ? .lowerIsBetter : .higherIsBetter,
                weight: id == .pointerChaseLatency ? 0.34 : 0.33,
                workloadVersion: memoryWorkloadVersion(for: plan),
                samples: samples
            )
        }
    }

    func storageMetrics(
        for plan: BenchmarkV7Plan,
        targetDirectory: URL,
        cycle: Int,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder
    ) async throws -> [BenchmarkV7MetricResult] {
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )
        let profile = diskProfile(for: plan)
        let repetitionCount = storageSampleCount(for: plan)
        var sequentialRead: [BenchmarkV7RawSample] = []
        var sequentialWrite: [BenchmarkV7RawSample] = []
        var randomSamples: [String: [BenchmarkV7RawSample]] = [:]
        sequentialRead.reserveCapacity(repetitionCount)
        sequentialWrite.reserveCapacity(repetitionCount)

        for index in 0..<repetitionCount {
            let repetition = cycle * repetitionCount + index + 1
            try Task.checkCancellation()
            let sequential = try await runSubtest(
                category: .storage,
                workloadID: "storage.sequential",
                repetition: repetition,
                executionRecorder: executionRecorder
            ) {
                try await DiskBenchmarkKernel(
                    rootDirectory: targetDirectory
                ).run(profile: profile)
            }
            sequentialWrite.append(rawSample(from: sequential.writeSample))
            sequentialRead.append(rawSample(from: sequential.readSample))

            let configuration: StorageRandomAccessBenchmarkV7.Configuration = switch plan.kind {
            case .standard:
                .standard(in: targetDirectory, cacheMode: .noCacheRequested)
            case .quick, .custom:
                .quick(in: targetDirectory, cacheMode: .noCacheRequested)
            case .sustained:
                throw BenchmarkV7WorkloadRunnerError.unsupportedPlan(plan.kind)
            }
            let random = try await runSubtest(
                category: .storage,
                workloadID: "storage.random-access",
                repetition: repetition,
                executionRecorder: executionRecorder
            ) {
                try await StorageRandomAccessBenchmarkV7(
                    configuration: configuration
                ).run()
            }
            for sample in randomMetricSamples(random) {
                randomSamples[sample.metricID, default: []].append(rawSample(from: sample))
            }
        }

        var results = [
            try metric(
                id: "storage.sequential.read",
                category: .storage,
                unit: "GB/s",
                direction: .higherIsBetter,
                weight: 0.10,
                workloadVersion: "storage-sequential-adapter-v7",
                samples: sequentialRead
            ),
            try metric(
                id: "storage.sequential.write",
                category: .storage,
                unit: "GB/s",
                direction: .higherIsBetter,
                weight: 0.10,
                workloadVersion: "storage-sequential-adapter-v7",
                samples: sequentialWrite
            ),
        ]
        for id in randomSamples.keys.sorted() {
            guard let samples = randomSamples[id],
                  let descriptor = descriptor(for: id) else { continue }
            results.append(try metric(
                id: id,
                category: .storage,
                unit: descriptor.unit,
                direction: descriptor.direction,
                weight: descriptor.weight,
                workloadVersion: StorageRandomAccessBenchmarkV7.workloadVersion,
                samples: samples
            ))
        }
        return results
    }

    func displayMetrics(
        for plan: BenchmarkV7Plan,
        cycle: Int,
        executionRecorder: BenchmarkV7WorkloadExecutionRecorder
    ) async throws -> [BenchmarkV7MetricResult] {
        let configuration = displayConfiguration(for: plan)
        let repetitions = displaySampleCount(for: plan)
        var values: [String: [BenchmarkV7RawSample]] = [:]
        var nonScoreableMetrics = Set<String>()
        for index in 0..<repetitions {
            try Task.checkCancellation()
            let report = try await runSubtest(
                category: .display,
                workloadID: "display.cadence",
                repetition: cycle * repetitions + index + 1,
                executionRecorder: executionRecorder
            ) {
                await DisplayCadenceKernel(configuration: configuration).measure()
            }
            guard case let .measured(metrics) = report.outcome else {
                // Display is an optional Experience category. Preserve its
                // explicit unavailability in the caller's preflight/result,
                // but do not fabricate a metric or fail Core Performance.
                return []
            }
            let elapsed = metrics.measuredDurationSeconds
            let samples: [(String, String, BenchmarkV7MetricDirection, Double)] = [
                ("display.effective-fps", "FPS", .higherIsBetter, metrics.effectiveFramesPerSecond),
                ("display.cadence.p50.ms", "ms", .lowerIsBetter, metrics.p50IntervalMilliseconds),
                ("display.cadence.p95.ms", "ms", .lowerIsBetter, metrics.p95IntervalMilliseconds),
                ("display.cadence.p99.ms", "ms", .lowerIsBetter, metrics.p99IntervalMilliseconds),
                ("display.cadence.jitter.ms", "ms", .lowerIsBetter, metrics.jitterMilliseconds),
            ]
            for (id, _, _, value) in samples {
                // A zero jitter is a valid cadence observation, but the v7
                // scoring contract intentionally rejects zero inputs rather
                // than hiding them behind an epsilon. Keep the optional
                // Display metric absent and expose the omission as a warning.
                guard value.isFinite, value > 0 else {
                    nonScoreableMetrics.insert(id)
                    values.removeValue(forKey: id)
                    continue
                }
                guard !nonScoreableMetrics.contains(id) else { continue }
                values[id, default: []].append(BenchmarkV7RawSample(
                    value: value,
                    elapsedSeconds: elapsed,
                    wallElapsedSeconds: elapsed,
                    checksum: nil
                ))
            }
        }
        return values.keys.sorted().compactMap { id in
            guard let samples = values[id],
                  samples.count == repetitions,
                  let descriptor = descriptor(for: id) else { return nil }
            // Display is optional and excluded from Core. A metric whose
            // values cannot satisfy the explicit nonzero scoring contract is
            // deliberately omitted rather than coercing it with epsilon.
            return try? metric(
                id: id,
                category: .display,
                unit: descriptor.unit,
                direction: descriptor.direction,
                weight: descriptor.weight,
                workloadVersion: DisplayCadenceKernel.workloadVersion,
                samples: samples
            )
        }
    }

    func metric(
        id: String,
        category: BenchmarkV7Category,
        unit: String,
        direction: BenchmarkV7MetricDirection,
        weight: Double,
        workloadVersion: String,
        samples: [BenchmarkV7RawSample]
    ) throws -> BenchmarkV7MetricResult {
        BenchmarkV7MetricResult(
            manifest: BenchmarkV7MetricManifest(
                id: id,
                category: category,
                unit: unit,
                direction: direction,
                weight: weight,
                workloadVersion: workloadVersion
            ),
            samples: samples,
            statistics: try BenchmarkStatistics.summarize(samples.map(\.value))
        )
    }

    func rawSample(from sample: BenchmarkComponentSample) -> BenchmarkV7RawSample {
        BenchmarkV7RawSample(
            value: sample.value,
            elapsedSeconds: sample.elapsedSeconds,
            wallElapsedSeconds: nil,
            checksum: sample.checksum
        )
    }

    func rawSample(from sample: StorageRandomAccessBenchmarkV7.MetricSample) -> BenchmarkV7RawSample {
        BenchmarkV7RawSample(
            value: sample.value,
            elapsedSeconds: sample.elapsedSeconds,
            wallElapsedSeconds: sample.elapsedSeconds,
            checksum: sample.checksum
        )
    }

    func randomMetricSamples(
        _ result: StorageRandomAccessBenchmarkV7.Result
    ) -> [StorageRandomAccessBenchmarkV7.MetricSample] {
        [
            result.randomWriteQD1,
            result.randomWriteQD16,
            result.randomReadQD1,
            result.randomReadQD16,
        ].flatMap { measurement in
            [
                measurement.iopsSample,
                measurement.p50LatencySample,
                measurement.p95LatencySample,
            ]
        }
    }

    func descriptor(for metricID: String) -> (
        unit: String,
        direction: BenchmarkV7MetricDirection,
        weight: Double
    )? {
        if metricID.hasSuffix(".iops") {
            return ("IOPS", .higherIsBetter, 0.10)
        }
        if metricID.hasSuffix(".latency.p50.ns") {
            return ("ns", .lowerIsBetter, 0.05)
        }
        if metricID.hasSuffix(".latency.p95.ns") {
            return ("ns", .lowerIsBetter, 0.05)
        }
        switch metricID {
        case "display.effective-fps":
            return ("FPS", .higherIsBetter, 0.20)
        case "display.cadence.p50.ms", "display.cadence.p95.ms", "display.cadence.p99.ms":
            return ("ms", .lowerIsBetter, 0.20)
        case "display.cadence.jitter.ms":
            return ("ms", .lowerIsBetter, 0.20)
        default:
            return nil
        }
    }

    func cpuProfile(for plan: BenchmarkV7Plan) -> CPUBenchmarkV7Kernel.Profile {
        plan.kind == .standard ? .standard : .quick
    }

    func memoryPlanKind(for plan: BenchmarkV7Plan) -> BenchmarkV7PlanKind {
        plan.kind == .standard ? .standard : .quick
    }

    func diskProfile(for plan: BenchmarkV7Plan) -> BenchmarkProfile {
        plan.kind == .standard ? .full : .quick
    }

    func graphicsKernel(for plan: BenchmarkV7Plan) -> Metal3DBenchmarkKernel {
        let limits: Metal3DBenchmarkKernel.Limits
        switch plan.kind {
        case .standard:
            limits = .init(
                width: 2_560,
                height: 1_440,
                instanceCount: 262_144,
                frameCount: 600,
                maximumElapsedSeconds: 20
            )
        case .quick, .custom:
            limits = .init(
                width: 1_920,
                height: 1_080,
                instanceCount: 131_072,
                frameCount: 180,
                maximumElapsedSeconds: 12
            )
        case .sustained:
            limits = .init(
                width: 1_920,
                height: 1_080,
                instanceCount: 262_144,
                frameCount: 90,
                maximumElapsedSeconds: 5
            )
        }
        return Metal3DBenchmarkKernel(configuration: .init(limits: limits))
    }

    func tensorKernel(for plan: BenchmarkV7Plan) -> GPUTensorBenchmarkKernel {
        let limits: GPUTensorBenchmarkKernel.Limits
        switch plan.kind {
        case .standard:
            limits = .init(
                rows: 2_048,
                columns: 2_048,
                innerDimension: 2_048,
                iterationCount: 128,
                warmUpIterationCount: 4,
                precision: .float16,
                maximumElapsedSeconds: 20
            )
        case .quick, .custom:
            limits = .init(
                rows: 1_024,
                columns: 1_024,
                innerDimension: 1_024,
                iterationCount: 32,
                warmUpIterationCount: 2,
                precision: .float16,
                maximumElapsedSeconds: 12
            )
        case .sustained:
            limits = .init(
                rows: 1_024,
                columns: 1_024,
                innerDimension: 1_024,
                iterationCount: 16,
                warmUpIterationCount: 1,
                precision: .float16,
                maximumElapsedSeconds: 8
            )
        }
        return GPUTensorBenchmarkKernel(configuration: .init(limits: limits))
    }

    func displayConfiguration(for plan: BenchmarkV7Plan) -> DisplayCadenceKernel.Configuration {
        switch plan.kind {
        case .standard:
            .init(sampleLimit: 360, minimumIntervalCount: 120, timeoutSeconds: 6)
        case .quick, .custom:
            .init(sampleLimit: 120, minimumIntervalCount: 60, timeoutSeconds: 2)
        case .sustained:
            .init(sampleLimit: 120, minimumIntervalCount: 60, timeoutSeconds: 2)
        }
    }

    func gpuSampleCount(for plan: BenchmarkV7Plan) -> Int {
        plan.kind == .standard ? 15 : 3
    }

    func storageSampleCount(for plan: BenchmarkV7Plan) -> Int {
        plan.kind == .standard ? 13 : 2
    }

    func displaySampleCount(for plan: BenchmarkV7Plan) -> Int {
        plan.kind == .standard ? 8 : 2
    }

    func cpuBatchCount(for plan: BenchmarkV7Plan) -> Int {
        plan.kind == .standard ? 8 : 1
    }

    func memoryBatchCount(for plan: BenchmarkV7Plan) -> Int {
        plan.kind == .standard ? 3 : 1
    }

    func settleDuration(for plan: BenchmarkV7Plan) -> Duration {
        plan.kind == .standard ? .seconds(3) : .seconds(1)
    }

    func graphicsWorkloadVersion(for plan: BenchmarkV7Plan) -> String {
        plan.kind == .standard ? "gpu-graphics-2560x1440-v7" : "gpu-graphics-1920x1080-v7"
    }

    func tensorWorkloadVersion(for plan: BenchmarkV7Plan) -> String {
        plan.kind == .standard ? "gpu-compute-fp16-2048-v7" : "gpu-compute-fp16-1024-v7"
    }

    func memoryWorkloadVersion(for plan: BenchmarkV7Plan) -> String {
        plan.kind == .standard ? "memory-512m-v7" : "memory-128m-v7"
    }
}
