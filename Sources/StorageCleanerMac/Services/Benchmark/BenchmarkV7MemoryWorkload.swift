import Darwin
import Foundation

protocol BenchmarkV7MemoryAllocating: Sendable {
    func allocate(byteCount: Int, alignment: Int) throws -> UnsafeMutableRawPointer
    func deallocate(_ pointer: UnsafeMutableRawPointer)
}

struct SystemBenchmarkV7MemoryAllocator: BenchmarkV7MemoryAllocating {
    func allocate(byteCount: Int, alignment: Int) throws -> UnsafeMutableRawPointer {
        var pointer: UnsafeMutableRawPointer?
        guard posix_memalign(&pointer, alignment, byteCount) == 0, let pointer else {
            throw BenchmarkV7MemoryWorkloadError.unavailable
        }
        return pointer
    }

    func deallocate(_ pointer: UnsafeMutableRawPointer) {
        free(pointer)
    }
}

protocol BenchmarkV7MemoryClock: Sendable {
    func nowNanoseconds() -> UInt64
}

struct SystemBenchmarkV7MemoryClock: BenchmarkV7MemoryClock {
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

enum BenchmarkV7MemoryWorkloadError: Error, Equatable, Sendable {
    case unsupportedPlan(BenchmarkV7PlanKind)
    case invalidConfiguration
    case unavailable
    case timedOut
    case checksumMismatch
    case invalidMeasurement
}

/// Independent memory workload for the v7 protocol.  It owns its working set,
/// produces raw samples only, and intentionally does not participate in the
/// frozen v2-v6 coordinator, result, or scoring paths.
struct BenchmarkV7MemoryWorkload: Sendable {
    static let quickWorkingSetBytes = 128 * 1_024 * 1_024
    static let standardWorkingSetBytes = 512 * 1_024 * 1_024
    static let maximumWorkingSetBytes = standardWorkingSetBytes

    struct Limits: Equatable, Sendable {
        /// Total allocation across source, destination, addend, and pointer-chain lanes.
        let workingSetBytes: Int
        let sampleCount: Int
        let warmupPassCount: Int
        let pointerChaseStepCount: Int
        let checkIntervalWords: Int
        let maximumElapsedSeconds: Double
    }

    struct Configuration: Equatable, Sendable {
        let quick: Limits
        let standardLimits: Limits
        let seed: UInt64

        static let standard = Self(
            quick: Limits(
                workingSetBytes: BenchmarkV7MemoryWorkload.quickWorkingSetBytes,
                sampleCount: 3,
                warmupPassCount: 1,
                pointerChaseStepCount: 4 * 1_024 * 1_024,
                checkIntervalWords: 32 * 1_024,
                maximumElapsedSeconds: 30
            ),
            standardLimits: Limits(
                workingSetBytes: BenchmarkV7MemoryWorkload.standardWorkingSetBytes,
                sampleCount: 5,
                warmupPassCount: 1,
                pointerChaseStepCount: 16 * 1_024 * 1_024,
                checkIntervalWords: 32 * 1_024,
                maximumElapsedSeconds: 90
            ),
            seed: 0xA076_1D64_78BD_642F
        )

        /// Small, injectable limits keep XCTest from allocating production-sized buffers.
        static let testing = Self(
            quick: Limits(
                workingSetBytes: 256 * 1_024,
                sampleCount: 2,
                warmupPassCount: 1,
                pointerChaseStepCount: 4 * 1_024,
                checkIntervalWords: 256,
                maximumElapsedSeconds: 10
            ),
            standardLimits: Limits(
                workingSetBytes: 512 * 1_024,
                sampleCount: 3,
                warmupPassCount: 1,
                pointerChaseStepCount: 8 * 1_024,
                checkIntervalWords: 256,
                maximumElapsedSeconds: 10
            ),
            seed: 0xA076_1D64_78BD_642F
        )

        func limits(for planKind: BenchmarkV7PlanKind) -> Limits? {
            switch planKind {
            case .quick:
                quick
            case .standard:
                standardLimits
            case .sustained, .custom:
                nil
            }
        }
    }

    enum MetricID: String, CaseIterable, Codable, Sendable {
        case copyBandwidth = "memory.copy.bandwidth"
        case triadBandwidth = "memory.triad.bandwidth"
        case pointerChaseLatency = "memory.pointer-chase.latency"
    }

    struct MetricResult: Equatable, Sendable {
        let id: MetricID
        let unit: String
        let direction: BenchmarkV7MetricDirection
        let samples: [BenchmarkV7RawSample]
        let bytesTransferredPerSample: UInt64?
        let operationsPerSample: UInt64

        var isValid: Bool {
            !samples.isEmpty
                && samples.allSatisfy(\.isValid)
                && operationsPerSample > 0
        }
    }

    struct RunResult: Equatable, Sendable {
        let workingSetBytes: Int
        let copyBandwidth: MetricResult
        let triadBandwidth: MetricResult
        let pointerChaseLatency: MetricResult
        let ranOnMainThread: Bool

        var metrics: [MetricResult] {
            [copyBandwidth, triadBandwidth, pointerChaseLatency]
        }
    }

    private let configuration: Configuration
    private let allocator: any BenchmarkV7MemoryAllocating
    private let clock: any BenchmarkV7MemoryClock

    init(
        configuration: Configuration = .standard,
        allocator: any BenchmarkV7MemoryAllocating = SystemBenchmarkV7MemoryAllocator(),
        clock: any BenchmarkV7MemoryClock = SystemBenchmarkV7MemoryClock()
    ) {
        self.configuration = configuration
        self.allocator = allocator
        self.clock = clock
    }

    func run(planKind: BenchmarkV7PlanKind) async throws -> RunResult {
        try Task.checkCancellation()
        guard let limits = configuration.limits(for: planKind) else {
            throw BenchmarkV7MemoryWorkloadError.unsupportedPlan(planKind)
        }
        try Self.validate(limits)

        let configuration = configuration
        let allocator = allocator
        let clock = clock
        let worker = Task.detached(priority: .userInitiated) {
            try Self.runSynchronously(
                limits: limits,
                seed: configuration.seed,
                allocator: allocator,
                clock: clock
            )
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

private extension BenchmarkV7MemoryWorkload {
    static let alignment = 64
    static let wordsPerLane = 4
    static let maximumSampleCount = 12
    static let maximumWarmupPassCount = 3
    static let maximumElapsedSeconds = 120.0
    static let initialChecksum: UInt64 = 0xCBF2_9CE4_8422_2325
    static let sourceSeedOffset: UInt64 = 0xD1B5_4A32_D192_ED03
    static let addendSeedOffset: UInt64 = 0x8CB9_2BA7_2F3D_8DD7
    static let chainSeedOffset: UInt64 = 0xDB4F_0B91_75AE_2165
    static let copyChecksumSeed: UInt64 = 0xE703_7ED1_A0B4_28DB
    static let triadChecksumSeed: UInt64 = 0x9E37_79B9_7F4A_7C15

    static func validate(_ limits: Limits) throws {
        let wordStride = MemoryLayout<UInt64>.stride
        let laneWordCount = (limits.workingSetBytes / wordStride) / wordsPerLane
        guard limits.workingSetBytes >= wordsPerLane * wordStride * 64,
              limits.workingSetBytes <= maximumWorkingSetBytes,
              limits.workingSetBytes.isMultiple(of: wordStride),
              limits.sampleCount > 0,
              limits.sampleCount <= maximumSampleCount,
              limits.warmupPassCount > 0,
              limits.warmupPassCount <= maximumWarmupPassCount,
              limits.pointerChaseStepCount > 0,
              limits.pointerChaseStepCount <= laneWordCount,
              limits.checkIntervalWords > 0,
              limits.checkIntervalWords <= laneWordCount,
              limits.maximumElapsedSeconds.isFinite,
              limits.maximumElapsedSeconds > 0,
              limits.maximumElapsedSeconds <= maximumElapsedSeconds
        else {
            throw BenchmarkV7MemoryWorkloadError.invalidConfiguration
        }
    }

    static func runSynchronously(
        limits: Limits,
        seed: UInt64,
        allocator: any BenchmarkV7MemoryAllocating,
        clock: any BenchmarkV7MemoryClock
    ) throws -> RunResult {
        let safetyStartedAt = clock.nowNanoseconds()
        let pointer: UnsafeMutableRawPointer
        do {
            pointer = try allocator.allocate(
                byteCount: limits.workingSetBytes,
                alignment: alignment
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BenchmarkV7MemoryWorkloadError.unavailable
        }
        defer { allocator.deallocate(pointer) }
        try checkBoundary(limits: limits, safetyStartedAt: safetyStartedAt, clock: clock)

        let totalWordCount = limits.workingSetBytes / MemoryLayout<UInt64>.stride
        let laneWordCount = totalWordCount / wordsPerLane
        let words = pointer.bindMemory(to: UInt64.self, capacity: totalWordCount)
        words.initialize(repeating: 0, count: totalWordCount)
        defer { words.deinitialize(count: totalWordCount) }

        let source = words
        let destination = words.advanced(by: laneWordCount)
        let addend = words.advanced(by: laneWordCount * 2)
        let pointerChain = words.advanced(by: laneWordCount * 3)

        // Allocation, initialization, chain construction, and warm-up are all
        // intentionally complete before the first sample clock starts.
        try initializePointerChain(
            pointerChain,
            scratch: destination,
            count: laneWordCount,
            seed: seed &+ chainSeedOffset,
            limits: limits,
            safetyStartedAt: safetyStartedAt,
            clock: clock
        )
        try initializeWords(
            source,
            count: laneWordCount,
            seed: seed &+ sourceSeedOffset,
            limits: limits,
            safetyStartedAt: safetyStartedAt,
            clock: clock
        )
        try initializeWords(
            addend,
            count: laneWordCount,
            seed: seed &+ addendSeedOffset,
            limits: limits,
            safetyStartedAt: safetyStartedAt,
            clock: clock
        )

        for warmupIndex in 0..<limits.warmupPassCount {
            let scalar = UInt64(warmupIndex) &+ 1
            try copy(
                from: source,
                to: destination,
                count: laneWordCount,
                limits: limits,
                safetyStartedAt: safetyStartedAt,
                clock: clock
            )
            try triad(
                source: source,
                addend: addend,
                destination: destination,
                scalar: scalar,
                count: laneWordCount,
                limits: limits,
                safetyStartedAt: safetyStartedAt,
                clock: clock
            )
            _ = try chase(
                pointerChain,
                count: laneWordCount,
                steps: limits.pointerChaseStepCount,
                seed: seed &+ UInt64(warmupIndex),
                limits: limits,
                safetyStartedAt: safetyStartedAt,
                clock: clock
            )
        }

        let expectedCopyChecksum = try checksum(
            source,
            count: laneWordCount,
            seed: copyChecksumSeed,
            limits: limits,
            safetyStartedAt: safetyStartedAt,
            clock: clock
        )
        let laneBytes = UInt64(laneWordCount * MemoryLayout<UInt64>.stride)
        let copyBytes = try multipliedBytes(laneBytes, by: 2)
        let triadBytes = try multipliedBytes(laneBytes, by: 3)

        var copySamples: [BenchmarkV7RawSample] = []
        var triadSamples: [BenchmarkV7RawSample] = []
        var pointerSamples: [BenchmarkV7RawSample] = []
        copySamples.reserveCapacity(limits.sampleCount)
        triadSamples.reserveCapacity(limits.sampleCount)
        pointerSamples.reserveCapacity(limits.sampleCount)

        for sampleIndex in 0..<limits.sampleCount {
            try checkBoundary(limits: limits, safetyStartedAt: safetyStartedAt, clock: clock)
            let copyStartedAt = clock.nowNanoseconds()
            try copy(
                from: source,
                to: destination,
                count: laneWordCount,
                limits: limits,
                safetyStartedAt: safetyStartedAt,
                clock: clock
            )
            let copyElapsedSeconds = try elapsedSeconds(
                since: copyStartedAt,
                clock: clock
            )
            let copyChecksum = try checksum(
                destination,
                count: laneWordCount,
                seed: copyChecksumSeed,
                limits: limits,
                safetyStartedAt: safetyStartedAt,
                clock: clock
            )
            guard copyChecksum == expectedCopyChecksum else {
                throw BenchmarkV7MemoryWorkloadError.checksumMismatch
            }
            copySamples.append(try rawSample(
                value: (Double(copyBytes) / 1_000_000_000) / copyElapsedSeconds,
                elapsedSeconds: copyElapsedSeconds,
                checksum: copyChecksum
            ))

            let scalar = UInt64(sampleIndex) &+ 1
            let triadStartedAt = clock.nowNanoseconds()
            try triad(
                source: source,
                addend: addend,
                destination: destination,
                scalar: scalar,
                count: laneWordCount,
                limits: limits,
                safetyStartedAt: safetyStartedAt,
                clock: clock
            )
            let triadElapsedSeconds = try elapsedSeconds(
                since: triadStartedAt,
                clock: clock
            )
            let expectedTriadChecksum = try triadChecksum(
                source: source,
                addend: addend,
                scalar: scalar,
                count: laneWordCount,
                limits: limits,
                safetyStartedAt: safetyStartedAt,
                clock: clock
            )
            let actualTriadChecksum = try checksum(
                destination,
                count: laneWordCount,
                seed: triadChecksumSeed,
                limits: limits,
                safetyStartedAt: safetyStartedAt,
                clock: clock
            )
            guard actualTriadChecksum == expectedTriadChecksum else {
                throw BenchmarkV7MemoryWorkloadError.checksumMismatch
            }
            triadSamples.append(try rawSample(
                value: (Double(triadBytes) / 1_000_000_000) / triadElapsedSeconds,
                elapsedSeconds: triadElapsedSeconds,
                checksum: actualTriadChecksum
            ))

            let pointerStartedAt = clock.nowNanoseconds()
            let pointerChecksum = try chase(
                pointerChain,
                count: laneWordCount,
                steps: limits.pointerChaseStepCount,
                seed: seed &+ UInt64(sampleIndex),
                limits: limits,
                safetyStartedAt: safetyStartedAt,
                clock: clock
            )
            let pointerElapsedSeconds = try elapsedSeconds(
                since: pointerStartedAt,
                clock: clock
            )
            pointerSamples.append(try rawSample(
                value: pointerElapsedSeconds * 1_000_000_000
                    / Double(limits.pointerChaseStepCount),
                elapsedSeconds: pointerElapsedSeconds,
                checksum: pointerChecksum
            ))
        }

        return RunResult(
            workingSetBytes: limits.workingSetBytes,
            copyBandwidth: MetricResult(
                id: .copyBandwidth,
                unit: "GB/s",
                direction: .higherIsBetter,
                samples: copySamples,
                bytesTransferredPerSample: copyBytes,
                operationsPerSample: UInt64(laneWordCount)
            ),
            triadBandwidth: MetricResult(
                id: .triadBandwidth,
                unit: "GB/s",
                direction: .higherIsBetter,
                samples: triadSamples,
                bytesTransferredPerSample: triadBytes,
                operationsPerSample: UInt64(laneWordCount)
            ),
            pointerChaseLatency: MetricResult(
                id: .pointerChaseLatency,
                unit: "ns/access",
                direction: .lowerIsBetter,
                samples: pointerSamples,
                bytesTransferredPerSample: nil,
                operationsPerSample: UInt64(limits.pointerChaseStepCount)
            ),
            ranOnMainThread: Thread.isMainThread
        )
    }

    static func initializePointerChain(
        _ chain: UnsafeMutablePointer<UInt64>,
        scratch: UnsafeMutablePointer<UInt64>,
        count: Int,
        seed: UInt64,
        limits: Limits,
        safetyStartedAt: UInt64,
        clock: any BenchmarkV7MemoryClock
    ) throws {
        for index in 0..<count {
            if index.isMultiple(of: limits.checkIntervalWords) {
                try checkBoundary(
                    limits: limits,
                    safetyStartedAt: safetyStartedAt,
                    clock: clock
                )
            }
            scratch[index] = UInt64(index)
        }

        var state = seed
        if count > 1 {
            for index in stride(from: count - 1, through: 1, by: -1) {
                if index.isMultiple(of: limits.checkIntervalWords) {
                    try checkBoundary(
                        limits: limits,
                        safetyStartedAt: safetyStartedAt,
                        clock: clock
                    )
                }
                state = nextRandom(state)
                let otherIndex = Int(state % UInt64(index + 1))
                let value = scratch[index]
                scratch[index] = scratch[otherIndex]
                scratch[otherIndex] = value
            }
        }

        for index in 0..<count {
            if index.isMultiple(of: limits.checkIntervalWords) {
                try checkBoundary(
                    limits: limits,
                    safetyStartedAt: safetyStartedAt,
                    clock: clock
                )
            }
            let node = Int(scratch[index])
            let nextIndex = index + 1 == count ? 0 : index + 1
            chain[node] = scratch[nextIndex]
        }
    }

    static func initializeWords(
        _ words: UnsafeMutablePointer<UInt64>,
        count: Int,
        seed: UInt64,
        limits: Limits,
        safetyStartedAt: UInt64,
        clock: any BenchmarkV7MemoryClock
    ) throws {
        var state = seed
        for index in 0..<count {
            if index.isMultiple(of: limits.checkIntervalWords) {
                try checkBoundary(
                    limits: limits,
                    safetyStartedAt: safetyStartedAt,
                    clock: clock
                )
            }
            state = nextRandom(state)
            words[index] = state
        }
    }

    static func copy(
        from source: UnsafeMutablePointer<UInt64>,
        to destination: UnsafeMutablePointer<UInt64>,
        count: Int,
        limits: Limits,
        safetyStartedAt: UInt64,
        clock: any BenchmarkV7MemoryClock
    ) throws {
        var offset = 0
        while offset < count {
            try checkBoundary(limits: limits, safetyStartedAt: safetyStartedAt, clock: clock)
            let wordCount = min(limits.checkIntervalWords, count - offset)
            memcpy(
                destination.advanced(by: offset),
                source.advanced(by: offset),
                wordCount * MemoryLayout<UInt64>.stride
            )
            offset += wordCount
        }
    }

    static func triad(
        source: UnsafeMutablePointer<UInt64>,
        addend: UnsafeMutablePointer<UInt64>,
        destination: UnsafeMutablePointer<UInt64>,
        scalar: UInt64,
        count: Int,
        limits: Limits,
        safetyStartedAt: UInt64,
        clock: any BenchmarkV7MemoryClock
    ) throws {
        var offset = 0
        while offset < count {
            try checkBoundary(limits: limits, safetyStartedAt: safetyStartedAt, clock: clock)
            let end = min(offset + limits.checkIntervalWords, count)
            for index in offset..<end {
                destination[index] = source[index] &+ addend[index] &+ scalar
            }
            offset = end
        }
    }

    static func chase(
        _ chain: UnsafeMutablePointer<UInt64>,
        count: Int,
        steps: Int,
        seed: UInt64,
        limits: Limits,
        safetyStartedAt: UInt64,
        clock: any BenchmarkV7MemoryClock
    ) throws -> UInt64 {
        var index = Int(seed % UInt64(count))
        var checksum = initialChecksum ^ seed
        for step in 0..<steps {
            if step.isMultiple(of: limits.checkIntervalWords) {
                try checkBoundary(
                    limits: limits,
                    safetyStartedAt: safetyStartedAt,
                    clock: clock
                )
            }
            let next = chain[index]
            guard next < UInt64(count) else {
                throw BenchmarkV7MemoryWorkloadError.checksumMismatch
            }
            checksum = updateChecksum(checksum, value: next, index: step)
            index = Int(next)
        }
        return checksum ^ UInt64(index)
    }

    static func checksum(
        _ words: UnsafeMutablePointer<UInt64>,
        count: Int,
        seed: UInt64,
        limits: Limits,
        safetyStartedAt: UInt64,
        clock: any BenchmarkV7MemoryClock
    ) throws -> UInt64 {
        var result = initialChecksum ^ seed
        for index in 0..<count {
            if index.isMultiple(of: limits.checkIntervalWords) {
                try checkBoundary(
                    limits: limits,
                    safetyStartedAt: safetyStartedAt,
                    clock: clock
                )
            }
            result = updateChecksum(result, value: words[index], index: index)
        }
        return result
    }

    static func triadChecksum(
        source: UnsafeMutablePointer<UInt64>,
        addend: UnsafeMutablePointer<UInt64>,
        scalar: UInt64,
        count: Int,
        limits: Limits,
        safetyStartedAt: UInt64,
        clock: any BenchmarkV7MemoryClock
    ) throws -> UInt64 {
        var result = initialChecksum ^ triadChecksumSeed
        for index in 0..<count {
            if index.isMultiple(of: limits.checkIntervalWords) {
                try checkBoundary(
                    limits: limits,
                    safetyStartedAt: safetyStartedAt,
                    clock: clock
                )
            }
            result = updateChecksum(
                result,
                value: source[index] &+ addend[index] &+ scalar,
                index: index
            )
        }
        return result
    }

    static func checkBoundary(
        limits: Limits,
        safetyStartedAt: UInt64,
        clock: any BenchmarkV7MemoryClock
    ) throws {
        try Task.checkCancellation()
        guard try elapsedSeconds(since: safetyStartedAt, clock: clock)
            <= limits.maximumElapsedSeconds else {
            throw BenchmarkV7MemoryWorkloadError.timedOut
        }
    }

    static func elapsedSeconds(
        since startedAt: UInt64,
        clock: any BenchmarkV7MemoryClock
    ) throws -> Double {
        let finishedAt = clock.nowNanoseconds()
        guard finishedAt > startedAt else {
            throw BenchmarkV7MemoryWorkloadError.invalidMeasurement
        }
        return Double(finishedAt - startedAt) / 1_000_000_000
    }

    static func multipliedBytes(_ bytes: UInt64, by multiplier: UInt64) throws -> UInt64 {
        let (value, overflow) = bytes.multipliedReportingOverflow(by: multiplier)
        guard !overflow, value > 0 else {
            throw BenchmarkV7MemoryWorkloadError.invalidConfiguration
        }
        return value
    }

    static func rawSample(
        value: Double,
        elapsedSeconds: Double,
        checksum: UInt64
    ) throws -> BenchmarkV7RawSample {
        guard value.isFinite,
              value > 0,
              elapsedSeconds.isFinite,
              elapsedSeconds > 0 else {
            throw BenchmarkV7MemoryWorkloadError.invalidMeasurement
        }
        return BenchmarkV7RawSample(
            value: value,
            elapsedSeconds: elapsedSeconds,
            wallElapsedSeconds: nil,
            checksum: checksum
        )
    }

    static func nextRandom(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    static func updateChecksum(
        _ checksum: UInt64,
        value: UInt64,
        index: Int
    ) -> UInt64 {
        let mixed = checksum ^ (value &+ UInt64(index) &* 0xD6E8_FEB8_6659_FD93)
        return rotateLeft(mixed &* 0xA24B_AED4_963E_E407, by: 19)
    }

    static func rotateLeft(_ value: UInt64, by count: UInt64) -> UInt64 {
        let normalized = count & 63
        guard normalized != 0 else { return value }
        return (value << normalized) | (value >> (64 - normalized))
    }
}
