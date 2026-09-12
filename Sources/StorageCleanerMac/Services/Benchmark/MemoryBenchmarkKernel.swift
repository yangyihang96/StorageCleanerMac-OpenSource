import Darwin
import Foundation

protocol MemoryBenchmarkAllocating: Sendable {
    func allocate(byteCount: Int, alignment: Int) throws -> UnsafeMutableRawPointer
    func deallocate(_ pointer: UnsafeMutableRawPointer)
}

struct SystemMemoryBenchmarkAllocator: MemoryBenchmarkAllocating {
    func allocate(byteCount: Int, alignment: Int) throws -> UnsafeMutableRawPointer {
        var pointer: UnsafeMutableRawPointer?
        let result = posix_memalign(&pointer, alignment, byteCount)
        guard result == 0, let pointer else {
            throw BenchmarkKernelError.resourceLimit
        }
        return pointer
    }

    func deallocate(_ pointer: UnsafeMutableRawPointer) {
        free(pointer)
    }
}

struct MemoryBenchmarkKernel: Sendable {
    static let maximumQuickAllocatedBytes = 64 * 1_024 * 1_024
    static let maximumFullAllocatedBytes = 256 * 1_024 * 1_024
    static let maximumQuickPassCount = 384
    static let maximumFullPassCount = 512
    static let maximumQuickElapsedSeconds = 8.0
    static let maximumFullElapsedSeconds = 35.0

    struct Limits: Equatable, Sendable {
        let totalAllocatedBytes: Int
        let passCount: Int
        let copyChunkBytes: Int
        let scanChunkBytes: Int
        let maximumElapsedSeconds: Double
    }

    struct Configuration: Equatable, Sendable {
        let quick: Limits
        let full: Limits

        static let standard = Self(
            quick: Limits(
                totalAllocatedBytes: MemoryBenchmarkKernel.maximumQuickAllocatedBytes,
                passCount: 384,
                copyChunkBytes: 1 * 1_024 * 1_024,
                scanChunkBytes: 256 * 1_024,
                maximumElapsedSeconds: MemoryBenchmarkKernel.maximumQuickElapsedSeconds
            ),
            full: Limits(
                totalAllocatedBytes: 192 * 1_024 * 1_024,
                passCount: 512,
                copyChunkBytes: 1 * 1_024 * 1_024,
                scanChunkBytes: 256 * 1_024,
                maximumElapsedSeconds: MemoryBenchmarkKernel.maximumFullElapsedSeconds
            )
        )

        static let testing = Self(
            quick: Limits(
                totalAllocatedBytes: 2 * 1_024 * 1_024,
                passCount: 2,
                copyChunkBytes: 64 * 1_024,
                scanChunkBytes: 64 * 1_024,
                maximumElapsedSeconds: 2
            ),
            full: Limits(
                totalAllocatedBytes: 4 * 1_024 * 1_024,
                passCount: 3,
                copyChunkBytes: 64 * 1_024,
                scanChunkBytes: 64 * 1_024,
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
        let totalAllocatedBytes: Int
        let processedBytes: UInt64
        let passCount: Int
        let ranOnMainThread: Bool
    }

    let configuration: Configuration
    private let allocator: any MemoryBenchmarkAllocating

    init(
        configuration: Configuration = .standard,
        allocator: any MemoryBenchmarkAllocating = SystemMemoryBenchmarkAllocator()
    ) {
        self.configuration = configuration
        self.allocator = allocator
    }

    func run(profile: BenchmarkProfile) async throws -> RunResult {
        try Task.checkCancellation()
        let limits = configuration.limits(for: profile)
        try Self.validate(limits, profile: profile)
        let allocator = allocator

        let worker = Task.detached(priority: .userInitiated) {
            try Self.runSynchronously(limits: limits, allocator: allocator)
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

private extension MemoryBenchmarkKernel {
    static let alignment = 64
    static let initialChecksum: UInt64 = 0xCBF2_9CE4_8422_2325
    static let sourceSeed: UInt64 = 0xD1B5_4A32_D192_ED03

    static func validate(_ limits: Limits, profile: BenchmarkProfile) throws {
        let maximumAllocatedBytes: Int
        let maximumPassCount: Int
        let maximumElapsedSeconds: Double
        switch profile {
        case .standard, .quick:
            maximumAllocatedBytes = maximumQuickAllocatedBytes
            maximumPassCount = maximumQuickPassCount
            maximumElapsedSeconds = maximumQuickElapsedSeconds
        case .full:
            maximumAllocatedBytes = maximumFullAllocatedBytes
            maximumPassCount = maximumFullPassCount
            maximumElapsedSeconds = maximumFullElapsedSeconds
        }

        guard limits.totalAllocatedBytes >= 128,
              limits.totalAllocatedBytes <= maximumAllocatedBytes,
              limits.totalAllocatedBytes.isMultiple(of: 128),
              limits.passCount > 0,
              limits.passCount <= maximumPassCount,
              limits.copyChunkBytes >= alignment,
              limits.copyChunkBytes <= 1 * 1_024 * 1_024,
              limits.copyChunkBytes.isMultiple(of: alignment),
              limits.scanChunkBytes >= alignment,
              limits.scanChunkBytes <= 1 * 1_024 * 1_024,
              limits.scanChunkBytes.isMultiple(of: alignment),
              limits.maximumElapsedSeconds.isFinite,
              limits.maximumElapsedSeconds > 0,
              limits.maximumElapsedSeconds <= maximumElapsedSeconds
        else {
            throw BenchmarkKernelError.resourceLimit
        }

        let (_, overflow) = limits.totalAllocatedBytes.multipliedReportingOverflow(
            by: limits.passCount
        )
        guard !overflow else { throw BenchmarkKernelError.resourceLimit }
    }

    static func runSynchronously(
        limits: Limits,
        allocator: any MemoryBenchmarkAllocating
    ) throws -> RunResult {
        let safetyStartedAt = DispatchTime.now().uptimeNanoseconds
        let pointer: UnsafeMutableRawPointer
        do {
            pointer = try allocator.allocate(
                byteCount: limits.totalAllocatedBytes,
                alignment: alignment
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BenchmarkKernelError.resourceLimit
        }
        defer { allocator.deallocate(pointer) }
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)

        let bufferBytes = limits.totalAllocatedBytes / 2
        let totalWordCount = limits.totalAllocatedBytes / MemoryLayout<UInt64>.stride
        let words = pointer.bindMemory(to: UInt64.self, capacity: totalWordCount)
        words.initialize(repeating: 0, count: totalWordCount)
        defer { words.deinitialize(count: totalWordCount) }
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)

        let wordCount = bufferBytes / MemoryLayout<UInt64>.stride
        let scanChunkWords = limits.scanChunkBytes / MemoryLayout<UInt64>.stride
        let sourceWords = words
        let destinationWords = words.advanced(by: wordCount)
        let source = UnsafeMutableRawPointer(sourceWords)
        let destination = UnsafeMutableRawPointer(destinationWords)

        var sourceState = sourceSeed
        var expectedChecksum = initialChecksum
        var initializedWords = 0
        while initializedWords < wordCount {
            try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)
            let end = min(initializedWords + scanChunkWords, wordCount)
            for index in initializedWords..<end {
                sourceState = xorshift(sourceState)
                sourceWords[index] = sourceState
                expectedChecksum = updateChecksum(
                    expectedChecksum,
                    value: sourceState,
                    index: index
                )
            }
            initializedWords = end
        }
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)

        memcpy(destination, source, bufferBytes)
        guard memcmp(destination, source, bufferBytes) == 0 else {
            throw BenchmarkKernelError.checksumMismatch
        }
        try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)

        let timedStartedAt = DispatchTime.now().uptimeNanoseconds
        var aggregateChecksum = initialChecksum
        for pass in 0..<limits.passCount {
            var copiedBytes = 0
            while copiedBytes < bufferBytes {
                try checkWorkBoundary(
                    limits: limits,
                    timedStartedAt: timedStartedAt,
                    safetyStartedAt: safetyStartedAt
                )
                let byteCount = min(limits.copyChunkBytes, bufferBytes - copiedBytes)
                memcpy(
                    destination.advanced(by: copiedBytes),
                    source.advanced(by: copiedBytes),
                    byteCount
                )
                copiedBytes += byteCount
            }

            try checkWorkBoundary(
                limits: limits,
                timedStartedAt: timedStartedAt,
                safetyStartedAt: safetyStartedAt
            )
            guard memcmp(destination, source, bufferBytes) == 0 else {
                throw BenchmarkKernelError.checksumMismatch
            }
            aggregateChecksum ^= expectedChecksum &+ UInt64(pass)
            aggregateChecksum = rotateLeft(aggregateChecksum &* 0x0000_0100_0000_01B3, by: 13)
        }
        try checkWorkBoundary(
            limits: limits,
            timedStartedAt: timedStartedAt,
            safetyStartedAt: safetyStartedAt
        )

        let elapsedSeconds = elapsedSeconds(since: timedStartedAt)
        var finalChecksum = initialChecksum
        var scannedWords = 0
        while scannedWords < wordCount {
            try checkSafetyBoundary(limits: limits, startedAt: safetyStartedAt)
            let end = min(scannedWords + scanChunkWords, wordCount)
            for index in scannedWords..<end {
                finalChecksum = updateChecksum(
                    finalChecksum,
                    value: destinationWords[index],
                    index: index
                )
            }
            scannedWords = end
        }
        guard finalChecksum == expectedChecksum else {
            throw BenchmarkKernelError.checksumMismatch
        }
        // Only one half of the allocation is copied on each pass. The other half is the
        // destination buffer, so counting the whole allocation would double the reported GB/s.
        let (processedByteCount, overflow) = UInt64(bufferBytes)
            .multipliedReportingOverflow(by: UInt64(limits.passCount))
        guard !overflow else { throw BenchmarkKernelError.resourceLimit }
        let throughput = (Double(processedByteCount) / 1_000_000_000) / elapsedSeconds
        guard throughput.isFinite,
              throughput > 0,
              elapsedSeconds.isFinite,
              elapsedSeconds > 0
        else {
            throw BenchmarkKernelError.invalidMetric
        }

        return RunResult(
            sample: BenchmarkComponentSample(
                value: throughput,
                elapsedSeconds: elapsedSeconds,
                checksum: aggregateChecksum
            ),
            totalAllocatedBytes: limits.totalAllocatedBytes,
            processedBytes: processedByteCount,
            passCount: limits.passCount,
            ranOnMainThread: Thread.isMainThread
        )
    }

    static func checkSafetyBoundary(limits: Limits, startedAt: UInt64) throws {
        try Task.checkCancellation()
        guard elapsedSeconds(since: startedAt) <= limits.maximumElapsedSeconds else {
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

    static func xorshift(_ input: UInt64) -> UInt64 {
        var value = input
        value ^= value << 13
        value ^= value >> 7
        value ^= value << 17
        return value
    }

    static func updateChecksum(
        _ checksum: UInt64,
        value: UInt64,
        index: Int
    ) -> UInt64 {
        let mixed = checksum ^ (value &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
        return rotateLeft(mixed &* 0xD6E8_FEB8_6659_FD93, by: 17)
    }

    static func rotateLeft(_ value: UInt64, by count: UInt64) -> UInt64 {
        let normalized = count & 63
        guard normalized != 0 else { return value }
        return (value << normalized) | (value >> (64 - normalized))
    }

}
