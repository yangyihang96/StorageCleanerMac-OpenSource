import Foundation

enum BenchmarkKernelError: Error, Equatable, Sendable {
    case unavailable
    case invalidConfiguration
    case resourceLimit
    case invalidMetric
    case checksumMismatch
    case systemFailure
}

struct CPUBenchmarkKernel: Sendable {
    static let maximumQuickOperationCount = 160_000_000
    static let maximumFullOperationCount = 512_000_000
    static let maximumQuickMultiOperationCountPerWorker = 768_000_000
    static let maximumFullMultiOperationCountPerWorker = 1_024_000_000
    static let maximumWarmupOperationCount = 256_000_000
    static let maximumWorkerCount = 64
    #if DEBUG
    // XCTest's unoptimized mix is deliberately much slower; production keeps the
    // tighter budgets below while tests still exercise the exact bounded workload.
    static let maximumQuickElapsedSeconds = 15.0
    static let maximumFullElapsedSeconds = 45.0
    #else
    static let maximumQuickElapsedSeconds = 5.0
    static let maximumFullElapsedSeconds = 20.0
    #endif

    struct Limits: Equatable, Sendable {
        let operationCount: Int
        let multiOperationCountPerWorker: Int?
        let warmupOperationCount: Int
        let multiWarmupOperationCount: Int
        let chunkSize: Int
        let maximumElapsedSeconds: Double

        init(
            operationCount: Int,
            multiOperationCountPerWorker: Int? = nil,
            warmupOperationCount: Int = 4_096,
            multiWarmupOperationCount: Int? = nil,
            chunkSize: Int,
            maximumElapsedSeconds: Double
        ) {
            self.operationCount = operationCount
            self.multiOperationCountPerWorker = multiOperationCountPerWorker
            self.warmupOperationCount = warmupOperationCount
            self.multiWarmupOperationCount = multiWarmupOperationCount
                ?? warmupOperationCount
            self.chunkSize = chunkSize
            self.maximumElapsedSeconds = maximumElapsedSeconds
        }
    }

    struct Configuration: Equatable, Sendable {
        let quick: Limits
        let full: Limits

        static let standard = Self(
            quick: Limits(
                operationCount: 96_000_000,
                multiOperationCountPerWorker: 768_000_000,
                warmupOperationCount: 32_000_000,
                multiWarmupOperationCount: 128_000_000,
                chunkSize: 32_768,
                maximumElapsedSeconds: CPUBenchmarkKernel.maximumQuickElapsedSeconds
            ),
            full: Limits(
                operationCount: 384_000_000,
                multiOperationCountPerWorker: 1_024_000_000,
                warmupOperationCount: 64_000_000,
                multiWarmupOperationCount: 256_000_000,
                chunkSize: 32_768,
                maximumElapsedSeconds: CPUBenchmarkKernel.maximumFullElapsedSeconds
            )
        )

        static let testing = Self(
            quick: Limits(
                operationCount: 131_072,
                chunkSize: 4_096,
                maximumElapsedSeconds: 2
            ),
            full: Limits(
                operationCount: 262_144,
                chunkSize: 4_096,
                maximumElapsedSeconds: 3
            )
        )

        func limits(for profile: BenchmarkProfile) -> Limits {
            switch profile {
            case .standard, .quick: quick
            case .full: full
            }
        }
    }

    struct RunResult: Equatable, Sendable {
        let sample: BenchmarkComponentSample
        let workerCount: Int
        let operationCount: Int
        let ranOnMainThread: Bool
    }

    let configuration: Configuration

    init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    static func workerCount(activeProcessorCount: Int) -> Int {
        guard activeProcessorCount > 1 else { return 1 }
        return activeProcessorCount - 1
    }

    func runSingle(profile: BenchmarkProfile) async throws -> RunResult {
        try Task.checkCancellation()
        let limits = configuration.limits(for: profile)
        try Self.validate(limits, profile: profile)

        let worker = Task.detached(priority: .userInitiated) {
            try Self.runSingleSynchronously(limits: limits)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    func runMulti(
        profile: BenchmarkProfile,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async throws -> RunResult {
        try Task.checkCancellation()
        let limits = configuration.limits(for: profile)
        try Self.validate(limits, profile: profile)
        let width = Self.workerCount(activeProcessorCount: activeProcessorCount)
        guard width <= Self.maximumWorkerCount,
              limits.multiOperationCountPerWorker != nil || limits.operationCount >= width
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        let worker = Task.detached(priority: .userInitiated) {
            try await Self.runMultiDetached(limits: limits, workerCount: width)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}

private actor CPUStartGate {
    private let expectedWorkerCount: Int
    private var arrivedWorkerCount = 0
    private var startedAt: UInt64?
    private var isCancelled = false
    private var waiters: [CheckedContinuation<UInt64, Error>] = []

    init(expectedWorkerCount: Int) {
        self.expectedWorkerCount = expectedWorkerCount
    }

    func arriveAndWait() async throws -> UInt64 {
        guard !isCancelled else { throw CancellationError() }
        if let startedAt { return startedAt }

        arrivedWorkerCount += 1
        if arrivedWorkerCount == expectedWorkerCount {
            let start = DispatchTime.now().uptimeNanoseconds
            startedAt = start
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            for waiter in pending {
                waiter.resume(returning: start)
            }
            return start
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func cancel() {
        guard startedAt == nil, !isCancelled else { return }
        isCancelled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(throwing: CancellationError())
        }
    }
}

private extension CPUBenchmarkKernel {
    static let inputElementCount = 4_096
    static let baseSeed: UInt64 = 0x9E37_79B9_7F4A_7C15

    struct PartitionWork: Sendable {
        let index: Int
        let operationCount: Int
        let input: [UInt64]
        let seed: UInt64
    }

    struct PartitionResult: Sendable {
        let index: Int
        let checksum: UInt64
        let ranOnMainThread: Bool
        let timedStartedAt: UInt64
    }

    static func validate(_ limits: Limits, profile: BenchmarkProfile) throws {
        let maximumOperations: Int
        let maximumMultiOperationsPerWorker: Int
        let maximumSeconds: Double
        switch profile {
        case .standard, .quick:
            maximumOperations = maximumQuickOperationCount
            maximumMultiOperationsPerWorker = maximumQuickMultiOperationCountPerWorker
            maximumSeconds = maximumQuickElapsedSeconds
        case .full:
            maximumOperations = maximumFullOperationCount
            maximumMultiOperationsPerWorker = maximumFullMultiOperationCountPerWorker
            maximumSeconds = maximumFullElapsedSeconds
        }

        guard limits.operationCount > 0,
              limits.operationCount <= maximumOperations,
              (limits.multiOperationCountPerWorker.map {
                  $0 > 0 && $0 <= maximumMultiOperationsPerWorker
              } ?? true),
              limits.warmupOperationCount > 0,
              limits.warmupOperationCount <= maximumWarmupOperationCount,
              limits.multiWarmupOperationCount > 0,
              limits.multiWarmupOperationCount <= maximumWarmupOperationCount,
              limits.chunkSize > 0,
              limits.chunkSize <= 65_536,
              limits.maximumElapsedSeconds.isFinite,
              limits.maximumElapsedSeconds > 0,
              limits.maximumElapsedSeconds <= maximumSeconds
        else {
            throw BenchmarkKernelError.resourceLimit
        }
    }

    static func runSingleSynchronously(limits: Limits) throws -> RunResult {
        let safetyStartedAt = DispatchTime.now().uptimeNanoseconds
        let seed = partitionSeed(index: 0)
        let input = try makeInput(
            seed: seed,
            limits: limits,
            safetyStartedAt: safetyStartedAt
        )
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)

        let warmupChecksum = try warmUpPartition(
            index: 0,
            input: input,
            operationCount: limits.warmupOperationCount,
            limits: limits,
            safetyStartedAt: safetyStartedAt
        )
        guard warmupChecksum != 0 else {
            throw BenchmarkKernelError.checksumMismatch
        }
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)

        let timedStartedAt = DispatchTime.now().uptimeNanoseconds
        let partition = try executePartition(
            PartitionWork(
                index: 0,
                operationCount: limits.operationCount,
                input: input,
                seed: seed
            ),
            limits: limits,
            timedStartedAt: timedStartedAt,
            safetyStartedAt: safetyStartedAt
        )
        let elapsedSeconds = elapsedSeconds(since: timedStartedAt)
        let value = millionsOfOperationsPerSecond(
            operationCount: limits.operationCount,
            elapsedSeconds: elapsedSeconds
        )
        guard value.isFinite, value > 0, elapsedSeconds.isFinite, elapsedSeconds > 0 else {
            throw BenchmarkKernelError.invalidMetric
        }

        return RunResult(
            sample: BenchmarkComponentSample(
                value: value,
                elapsedSeconds: elapsedSeconds,
                checksum: partition.checksum
            ),
            workerCount: 1,
            operationCount: limits.operationCount,
            ranOnMainThread: partition.ranOnMainThread
        )
    }

    static func runMultiDetached(
        limits: Limits,
        workerCount: Int
    ) async throws -> RunResult {
        let safetyStartedAt = DispatchTime.now().uptimeNanoseconds
        let baseOperations = limits.multiOperationCountPerWorker
            ?? (limits.operationCount / workerCount)
        let remainder = limits.multiOperationCountPerWorker == nil
            ? limits.operationCount % workerCount
            : 0
        let work = try (0..<workerCount).map { index in
            let seed = partitionSeed(index: index)
            return PartitionWork(
                index: index,
                operationCount: baseOperations + (index < remainder ? 1 : 0),
                input: try makeInput(
                    seed: seed,
                    limits: limits,
                    safetyStartedAt: safetyStartedAt
                ),
                seed: seed
            )
        }
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)

        let startGate = CPUStartGate(expectedWorkerCount: workerCount)
        let partitions = try await withThrowingTaskGroup(
            of: PartitionResult.self,
            returning: [PartitionResult].self
        ) { group in
            for partition in work {
                group.addTask(priority: .userInitiated) {
                    do {
                        let warmupChecksum = try warmUpPartition(
                            index: partition.index,
                            input: partition.input,
                            operationCount: limits.multiWarmupOperationCount,
                            limits: limits,
                            safetyStartedAt: safetyStartedAt
                        )
                        guard warmupChecksum != 0 else {
                            throw BenchmarkKernelError.checksumMismatch
                        }
                        let timedStartedAt = try await waitForCoordinatedStart(
                            gate: startGate
                        )
                        return try executePartition(
                            partition,
                            limits: limits,
                            timedStartedAt: timedStartedAt,
                            safetyStartedAt: safetyStartedAt
                        )
                    } catch {
                        await startGate.cancel()
                        throw error
                    }
                }
            }

            var completed: [PartitionResult] = []
            completed.reserveCapacity(workerCount)
            do {
                for try await result in group {
                    completed.append(result)
                }
            } catch {
                group.cancelAll()
                await startGate.cancel()
                throw error
            }
            return completed.sorted { $0.index < $1.index }
        }

        guard let timedStartedAt = partitions.first?.timedStartedAt,
              partitions.allSatisfy({ $0.timedStartedAt == timedStartedAt })
        else {
            throw BenchmarkKernelError.invalidMetric
        }

        try checkWorkBoundary(
            limits: limits,
            timedStartedAt: timedStartedAt,
            safetyStartedAt: safetyStartedAt
        )
        let elapsedSeconds = elapsedSeconds(since: timedStartedAt)
        let value = millionsOfOperationsPerSecond(
            operationCount: work.reduce(0) { $0 + $1.operationCount },
            elapsedSeconds: elapsedSeconds
        )
        guard partitions.count == workerCount,
              value.isFinite,
              value > 0,
              elapsedSeconds.isFinite,
              elapsedSeconds > 0
        else {
            throw BenchmarkKernelError.invalidMetric
        }

        var checksum: UInt64 = 0xCBF2_9CE4_8422_2325
        for partition in partitions {
            checksum ^= partition.checksum &+ UInt64(partition.index)
            checksum = (checksum &* 0x0000_0100_0000_01B3).rotatedLeft(by: 13)
        }

        return RunResult(
            sample: BenchmarkComponentSample(
                value: value,
                elapsedSeconds: elapsedSeconds,
                checksum: checksum
            ),
            workerCount: workerCount,
            operationCount: work.reduce(0) { $0 + $1.operationCount },
            ranOnMainThread: partitions.contains(where: \.ranOnMainThread)
        )
    }

    static func executePartition(
        _ work: PartitionWork,
        limits: Limits,
        timedStartedAt: UInt64,
        safetyStartedAt: UInt64
    ) throws -> PartitionResult {
        var integerState = work.seed
        var floatingState = Double(work.seed & 0xFFFF) / 65_535.0 + 1
        var offset = 0
        let ranOnMainThread = Thread.isMainThread

        while offset < work.operationCount {
            try checkWorkBoundary(
                limits: limits,
                timedStartedAt: timedStartedAt,
                safetyStartedAt: safetyStartedAt
            )
            let end = min(offset + limits.chunkSize, work.operationCount)
            (integerState, floatingState) = mixChunk(
                input: work.input,
                range: offset..<end,
                integerState: integerState,
                floatingState: floatingState
            )
            offset = end
        }
        try checkWorkBoundary(
            limits: limits,
            timedStartedAt: timedStartedAt,
            safetyStartedAt: safetyStartedAt
        )

        var checksum = integerState ^ floatingState.bitPattern
        checksum ^= UInt64(work.operationCount) &* 0xD6E8_FEB8_6659_FD93
        checksum ^= UInt64(work.index) &* 0xA076_1D64_78BD_642F
        return PartitionResult(
            index: work.index,
            checksum: checksum,
            ranOnMainThread: ranOnMainThread,
            timedStartedAt: timedStartedAt
        )
    }

    static func warmUpPartition(
        index: Int,
        input: [UInt64],
        operationCount: Int,
        limits: Limits,
        safetyStartedAt: UInt64
    ) throws -> UInt64 {
        var integerState = partitionSeed(index: index) ^ 0xD1B5_4A32_D192_ED03
        var floatingState = Double(integerState & 0xFFFF) / 65_535.0 + 1
        var offset = 0
        while offset < operationCount {
            try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)
            let end = min(offset + limits.chunkSize, operationCount)
            (integerState, floatingState) = mixChunk(
                input: input,
                range: offset..<end,
                integerState: integerState,
                floatingState: floatingState
            )
            offset = end
        }
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)
        return integerState ^ floatingState.bitPattern ^ UInt64(operationCount)
    }

    static func waitForCoordinatedStart(gate: CPUStartGate) async throws -> UInt64 {
        try await withTaskCancellationHandler {
            let startedAt = try await gate.arriveAndWait()
            try Task.checkCancellation()
            return startedAt
        } onCancel: {
            Task { await gate.cancel() }
        }
    }

    @inline(never)
    static func mixChunk(
        input: [UInt64],
        range: Range<Int>,
        integerState: UInt64,
        floatingState: Double
    ) -> (UInt64, Double) {
        var integerState = integerState
        var floatingState = floatingState
        let mask = input.count - 1

        for operation in range {
            let value = input[operation & mask]
            integerState ^= value &+ UInt64(operation)
            integerState = (integerState &* 0xD134_2543_DE82_EF95).rotatedLeft(by: 17)
            floatingState = (floatingState + Double(integerState & 0xFFFF) * 0.000_000_1)
                * 1.000_000_119_209_289_6
            if floatingState > 100_000 {
                floatingState *= 0.000_01
            }
        }
        return (integerState, floatingState)
    }

    static func makeInput(
        seed: UInt64,
        limits: Limits,
        safetyStartedAt: UInt64
    ) throws -> [UInt64] {
        var state = seed == 0 ? baseSeed : seed
        var input: [UInt64] = []
        input.reserveCapacity(inputElementCount)
        for index in 0..<inputElementCount {
            if index.isMultiple(of: 512) {
                try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)
            }
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            input.append(state)
        }
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)
        return input
    }

    static func partitionSeed(index: Int) -> UInt64 {
        baseSeed &+ (UInt64(index) &* 0xA076_1D64_78BD_642F)
    }

    static func checkSafetyBoundary(limits: Limits, startedAt: UInt64) throws {
        try Task.checkCancellation()
        let elapsed = elapsedSeconds(since: startedAt)
        guard elapsed <= limits.maximumElapsedSeconds else {
            throw BenchmarkKernelError.resourceLimit
        }
    }

    static func checkWorkBoundary(
        limits: Limits,
        timedStartedAt: UInt64,
        safetyStartedAt: UInt64
    ) throws {
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)
        guard elapsedSeconds(since: timedStartedAt) <= limits.maximumElapsedSeconds else {
            throw BenchmarkKernelError.resourceLimit
        }
    }

    static func elapsedSeconds(since startedAt: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= startedAt else { return .nan }
        return Double(now - startedAt) / 1_000_000_000
    }

    static func millionsOfOperationsPerSecond(
        operationCount: Int,
        elapsedSeconds: Double
    ) -> Double {
        (Double(operationCount) / 1_000_000) / elapsedSeconds
    }
}

private extension UInt64 {
    func rotatedLeft(by count: UInt64) -> UInt64 {
        let normalized = count & 63
        guard normalized != 0 else { return self }
        return (self << normalized) | (self >> (64 - normalized))
    }
}
