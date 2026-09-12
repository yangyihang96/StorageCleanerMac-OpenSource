import Darwin
import Dispatch
import Foundation

/// Clean-room v7 storage random-access measurement. This type is intentionally
/// standalone while the v6 sequential disk path remains frozen for migration.
struct StorageRandomAccessBenchmarkV7: Sendable {
    static let workloadVersion = "storage-random-access-v7"
    static let blockBytes = 4 * 1_024
    static let quickFileBytesV7 = 128 * 1_024 * 1_024
    static let standardFileBytesV7 = 512 * 1_024 * 1_024
    static let fixedSeed: UInt64 = 0x94D0_49BB_1331_11EB

    enum CacheMode: String, Equatable, Sendable {
        /// Normal filesystem buffering is in use; results must not be presented
        /// as a direct device-only measurement.
        case buffered
        /// `F_NOCACHE` succeeded for the benchmark descriptor. This is an
        /// explicit request, not a claim that every filesystem layer is bypassed.
        case noCacheRequested
    }

    enum WriteSyncMode: String, Equatable, Sendable {
        /// Each random-write workload ends with `fsync`; its duration is
        /// included in IOPS elapsed time and retained separately from per-I/O
        /// latency samples.
        case afterEachWriteWorkload
    }

    enum OperationKind: String, Equatable, Sendable {
        case randomRead
        case randomWrite
    }

    enum Failure: Error, Equatable, Sendable {
        case invalidConfiguration
        case systemFailure(Int32)
        case validationFailed
        case invalidMetric
    }

    struct Configuration: Equatable, Sendable {
        let targetDirectory: URL
        let fileBytes: Int
        let operationCount: Int
        let seed: UInt64
        let cacheMode: CacheMode

        init(
            targetDirectory: URL,
            fileBytes: Int,
            operationCount: Int,
            seed: UInt64 = StorageRandomAccessBenchmarkV7.fixedSeed,
            cacheMode: CacheMode = .buffered
        ) {
            self.targetDirectory = targetDirectory.standardizedFileURL
            self.fileBytes = fileBytes
            self.operationCount = operationCount
            self.seed = seed
            self.cacheMode = cacheMode
        }

        static func quick(
            in targetDirectory: URL,
            cacheMode: CacheMode = .buffered
        ) -> Self {
            Self(
                targetDirectory: targetDirectory,
                fileBytes: StorageRandomAccessBenchmarkV7.quickFileBytesV7,
                operationCount: 4_096,
                cacheMode: cacheMode
            )
        }

        static func standard(
            in targetDirectory: URL,
            cacheMode: CacheMode = .buffered
        ) -> Self {
            Self(
                targetDirectory: targetDirectory,
                fileBytes: StorageRandomAccessBenchmarkV7.standardFileBytesV7,
                operationCount: 16_384,
                cacheMode: cacheMode
            )
        }

        static func fixture(
            in targetDirectory: URL,
            cacheMode: CacheMode = .buffered
        ) -> Self {
            Self(
                targetDirectory: targetDirectory,
                fileBytes: 256 * 1_024,
                operationCount: 16,
                cacheMode: cacheMode
            )
        }
    }

    struct LatencySummary: Equatable, Sendable {
        let p50Nanoseconds: Double
        let p95Nanoseconds: Double
    }

    struct MetricSample: Equatable, Sendable {
        let metricID: String
        let direction: BenchmarkV7MetricDirection
        let unit: String
        let value: Double
        let elapsedSeconds: Double
        let checksum: UInt64
    }

    struct WorkloadMeasurement: Equatable, Sendable {
        let operation: OperationKind
        let queueDepth: Int
        let operationCount: Int
        let elapsedNanoseconds: UInt64
        let latency: LatencySummary
        let flushLatencyNanoseconds: UInt64?
        let iopsSample: MetricSample
        let p50LatencySample: MetricSample
        let p95LatencySample: MetricSample

        var iops: Double { iopsSample.value }
        var validationChecksum: UInt64 { iopsSample.checksum }
    }

    struct Result: Equatable, Sendable {
        let workloadVersion: String
        let fileBytes: Int
        let blockBytes: Int
        let cacheMode: CacheMode
        let writeSyncMode: WriteSyncMode
        let randomWriteQD1: WorkloadMeasurement
        let randomWriteQD16: WorkloadMeasurement
        let randomReadQD1: WorkloadMeasurement
        let randomReadQD16: WorkloadMeasurement
    }

    let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func run() async throws -> Result {
        try Task.checkCancellation()
        try Self.validate(configuration)
        let configuration = configuration
        let worker = Task.detached(priority: .userInitiated) {
            try await Self.runDetached(configuration: configuration)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    static func latencySummary(for samples: [UInt64]) throws -> LatencySummary {
        guard !samples.isEmpty else { throw Failure.invalidMetric }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let p50: Double
        if sorted.count.isMultiple(of: 2) {
            p50 = (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2
        } else {
            p50 = Double(sorted[middle])
        }
        let p95Index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        let p95 = Double(sorted[p95Index])
        guard p50.isFinite, p50 > 0, p95.isFinite, p95 > 0 else {
            throw Failure.invalidMetric
        }
        return LatencySummary(p50Nanoseconds: p50, p95Nanoseconds: p95)
    }
}

private extension StorageRandomAccessBenchmarkV7 {
    static let privateDirectoryPrefix = ".storage-cleaner-random-v7-"
    static let privateFileName = "random-access.bin"

    struct WorkItem: Sendable {
        let blockIndex: Int
        let bytes: [UInt8]
        let checksum: UInt64
    }

    static func validate(_ configuration: Configuration) throws {
        let blockCount = configuration.fileBytes / blockBytes
        guard configuration.targetDirectory.isFileURL,
              configuration.fileBytes >= blockBytes,
              configuration.fileBytes <= standardFileBytesV7,
              configuration.fileBytes.isMultiple(of: blockBytes),
              configuration.operationCount > 0,
              configuration.operationCount <= blockCount / 2
        else {
            throw Failure.invalidConfiguration
        }
    }

    static func runDetached(configuration: Configuration) async throws -> Result {
        let session = try makePrivateSession(
            in: configuration.targetDirectory,
            cacheMode: configuration.cacheMode
        )
        do {
            try prefill(
                fileDescriptor: session.fileDescriptor,
                fileBytes: configuration.fileBytes,
                seed: configuration.seed
            )
            let blockOrder = shuffledBlockOrder(
                blockCount: configuration.fileBytes / blockBytes,
                seed: configuration.seed
            )
            let writeQD1Items = workItems(
                blockIndices: Array(blockOrder.prefix(configuration.operationCount)),
                seed: configuration.seed,
                generation: 1
            )
            let writeQD16Items = workItems(
                blockIndices: Array(blockOrder.dropFirst(configuration.operationCount)
                    .prefix(configuration.operationCount)),
                seed: configuration.seed,
                generation: 2
            )

            let randomWriteQD1 = try await measure(
                fileDescriptor: session.fileDescriptor,
                operation: .randomWrite,
                queueDepth: 1,
                items: writeQD1Items
            )
            let randomWriteQD16 = try await measure(
                fileDescriptor: session.fileDescriptor,
                operation: .randomWrite,
                queueDepth: 16,
                items: writeQD16Items
            )
            let randomReadQD1 = try await measure(
                fileDescriptor: session.fileDescriptor,
                operation: .randomRead,
                queueDepth: 1,
                items: writeQD1Items
            )
            let randomReadQD16 = try await measure(
                fileDescriptor: session.fileDescriptor,
                operation: .randomRead,
                queueDepth: 16,
                items: writeQD16Items
            )
            try Task.checkCancellation()
            try session.cleanup()
            return Result(
                workloadVersion: workloadVersion,
                fileBytes: configuration.fileBytes,
                blockBytes: blockBytes,
                cacheMode: configuration.cacheMode,
                writeSyncMode: .afterEachWriteWorkload,
                randomWriteQD1: randomWriteQD1,
                randomWriteQD16: randomWriteQD16,
                randomReadQD1: randomReadQD1,
                randomReadQD16: randomReadQD16
            )
        } catch {
            session.cleanupBestEffort()
            throw error
        }
    }

    static func prefill(
        fileDescriptor: Int32,
        fileBytes: Int,
        seed: UInt64
    ) throws {
        let blockCount = fileBytes / blockBytes
        for blockIndex in 0..<blockCount {
            try Task.checkCancellation()
            let bytes = blockData(
                blockIndex: blockIndex,
                generation: 0,
                seed: seed
            )
            try writeExactly(
                fileDescriptor: fileDescriptor,
                bytes: bytes,
                offset: offset(forBlockIndex: blockIndex)
            )
        }
        try synchronize(fileDescriptor: fileDescriptor)
    }

    static func workItems(
        blockIndices: [Int],
        seed: UInt64,
        generation: UInt64
    ) -> [WorkItem] {
        blockIndices.map { blockIndex in
            let bytes = blockData(
                blockIndex: blockIndex,
                generation: generation,
                seed: seed
            )
            return WorkItem(
                blockIndex: blockIndex,
                bytes: bytes,
                checksum: checksum(bytes)
            )
        }
    }

    static func measure(
        fileDescriptor: Int32,
        operation: OperationKind,
        queueDepth: Int,
        items: [WorkItem]
    ) async throws -> WorkloadMeasurement {
        guard !items.isEmpty, queueDepth > 0 else {
            throw Failure.invalidConfiguration
        }
        let startedAt = monotonicNanoseconds()
        let latencies: [UInt64]
        if queueDepth == 1 {
            var measurements: [UInt64] = []
            measurements.reserveCapacity(items.count)
            for item in items {
                measurements.append(try executeTimedOperation(
                    fileDescriptor: fileDescriptor,
                    operation: operation,
                    item: item
                ))
            }
            latencies = measurements
        } else {
            let cursor = WorkItemCursor(items: items)
            latencies = try await withThrowingTaskGroup(of: [UInt64].self) { group in
                // Each worker issues one blocking positioned I/O at a time, so
                // this path has at most `queueDepth` operations in flight.
                for _ in 0..<queueDepth {
                    group.addTask {
                        var localLatencies: [UInt64] = []
                        localLatencies.reserveCapacity(max(1, items.count / queueDepth))
                        while let item = cursor.next() {
                            try Task.checkCancellation()
                            localLatencies.append(try executeTimedOperation(
                                fileDescriptor: fileDescriptor,
                                operation: operation,
                                item: item
                            ))
                        }
                        return localLatencies
                    }
                }
                var values: [UInt64] = []
                values.reserveCapacity(items.count)
                for try await localLatencies in group {
                    values.append(contentsOf: localLatencies)
                }
                return values
            }
        }

        let flushLatencyNanoseconds: UInt64?
        if operation == .randomWrite {
            let flushStartedAt = monotonicNanoseconds()
            try synchronize(fileDescriptor: fileDescriptor)
            flushLatencyNanoseconds = elapsedNanoseconds(
                from: flushStartedAt,
                to: monotonicNanoseconds()
            )
        } else {
            flushLatencyNanoseconds = nil
        }
        let elapsed = elapsedNanoseconds(from: startedAt, to: monotonicNanoseconds())
        guard latencies.count == items.count,
              elapsed > 0
        else {
            throw Failure.invalidMetric
        }
        let iops = Double(items.count) * 1_000_000_000 / Double(elapsed)
        guard iops.isFinite, iops > 0 else {
            throw Failure.invalidMetric
        }
        let checksum = items.reduce(0) { $0 ^ $1.checksum }
        let elapsedSeconds = Double(elapsed) / 1_000_000_000
        let latency = try latencySummary(for: latencies)
        let metricOperation = operation == .randomRead ? "read" : "write"
        let metricPrefix = "storage.random.\(metricOperation).qd\(queueDepth)"
        return WorkloadMeasurement(
            operation: operation,
            queueDepth: queueDepth,
            operationCount: items.count,
            elapsedNanoseconds: elapsed,
            latency: latency,
            flushLatencyNanoseconds: flushLatencyNanoseconds,
            iopsSample: MetricSample(
                metricID: "\(metricPrefix).iops",
                direction: .higherIsBetter,
                unit: "IOPS",
                value: iops,
                elapsedSeconds: elapsedSeconds,
                checksum: checksum
            ),
            p50LatencySample: MetricSample(
                metricID: "\(metricPrefix).latency.p50.ns",
                direction: .lowerIsBetter,
                unit: "ns",
                value: latency.p50Nanoseconds,
                elapsedSeconds: elapsedSeconds,
                checksum: checksum
            ),
            p95LatencySample: MetricSample(
                metricID: "\(metricPrefix).latency.p95.ns",
                direction: .lowerIsBetter,
                unit: "ns",
                value: latency.p95Nanoseconds,
                elapsedSeconds: elapsedSeconds,
                checksum: checksum
            )
        )
    }

    static func executeTimedOperation(
        fileDescriptor: Int32,
        operation: OperationKind,
        item: WorkItem
    ) throws -> UInt64 {
        try Task.checkCancellation()
        switch operation {
        case .randomWrite:
            let startedAt = monotonicNanoseconds()
            try writeExactly(
                fileDescriptor: fileDescriptor,
                bytes: item.bytes,
                offset: offset(forBlockIndex: item.blockIndex)
            )
            let elapsed = elapsedNanoseconds(from: startedAt, to: monotonicNanoseconds())
            guard elapsed > 0 else { throw Failure.invalidMetric }
            return elapsed
        case .randomRead:
            // Keep the per-worker read buffer allocation outside the measured
            // I/O call so P50/P95 describe positioned reads, not allocation.
            var bytes = [UInt8](repeating: 0, count: blockBytes)
            let startedAt = monotonicNanoseconds()
            try readExactly(
                fileDescriptor: fileDescriptor,
                bytes: &bytes,
                offset: offset(forBlockIndex: item.blockIndex)
            )
            let elapsed = elapsedNanoseconds(from: startedAt, to: monotonicNanoseconds())
            guard elapsed > 0 else { throw Failure.invalidMetric }
            guard bytes == item.bytes else { throw Failure.validationFailed }
            return elapsed
        }
    }

    static func writeExactly(
        fileDescriptor: Int32,
        bytes: [UInt8],
        offset: off_t
    ) throws {
        var writtenBytes = 0
        while writtenBytes < bytes.count {
            try Task.checkCancellation()
            let count = bytes.withUnsafeBytes { rawBuffer -> ssize_t in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.pwrite(
                    fileDescriptor,
                    baseAddress.advanced(by: writtenBytes),
                    bytes.count - writtenBytes,
                    offset + off_t(writtenBytes)
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.systemFailure(errno)
            }
            guard count > 0 else { throw Failure.systemFailure(EIO) }
            writtenBytes += Int(count)
        }
    }

    static func readExactly(
        fileDescriptor: Int32,
        bytes: inout [UInt8],
        offset: off_t
    ) throws {
        let totalBytes = bytes.count
        var readBytes = 0
        while readBytes < totalBytes {
            try Task.checkCancellation()
            let count = bytes.withUnsafeMutableBytes { rawBuffer -> ssize_t in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.pread(
                    fileDescriptor,
                    baseAddress.advanced(by: readBytes),
                    totalBytes - readBytes,
                    offset + off_t(readBytes)
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.systemFailure(errno)
            }
            guard count > 0 else { throw Failure.systemFailure(EIO) }
            readBytes += Int(count)
        }
    }

    static func synchronize(fileDescriptor: Int32) throws {
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw Failure.systemFailure(errno)
        }
    }

    static func makePrivateSession(
        in targetDirectory: URL,
        cacheMode: CacheMode
    ) throws -> PrivateFileSession {
        let targetDirectory = targetDirectory.standardizedFileURL
        var parentDescriptor = targetDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else { throw Failure.systemFailure(errno) }

        var directoryDescriptor: Int32 = -1
        var fileDescriptor: Int32 = -1
        var directoryName: String?
        defer {
            if fileDescriptor >= 0 { _ = Darwin.close(fileDescriptor) }
            if directoryDescriptor >= 0 {
                if let directoryName {
                    _ = privateFileName.withCString {
                        unlinkat(directoryDescriptor, $0, 0)
                    }
                    _ = directoryName.withCString {
                        unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
                    }
                }
                _ = Darwin.close(directoryDescriptor)
            }
            if parentDescriptor >= 0 { _ = Darwin.close(parentDescriptor) }
        }

        for _ in 0..<4 {
            let candidate = privateDirectoryPrefix + UUID().uuidString.lowercased()
            let created = candidate.withCString {
                mkdirat(parentDescriptor, $0, mode_t(0o700))
            }
            if created == 0 {
                directoryName = candidate
                break
            }
            if errno != EEXIST { throw Failure.systemFailure(errno) }
        }
        guard let directoryName else { throw Failure.systemFailure(EEXIST) }

        directoryDescriptor = directoryName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard directoryDescriptor >= 0 else { throw Failure.systemFailure(errno) }

        fileDescriptor = privateFileName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard fileDescriptor >= 0 else { throw Failure.systemFailure(errno) }
        if cacheMode == .noCacheRequested,
           Darwin.fcntl(fileDescriptor, F_NOCACHE, 1) != 0 {
            throw Failure.systemFailure(errno)
        }

        let session = PrivateFileSession(
            parentDescriptor: parentDescriptor,
            directoryDescriptor: directoryDescriptor,
            fileDescriptor: fileDescriptor,
            directoryName: directoryName,
            fileName: privateFileName
        )
        parentDescriptor = -1
        directoryDescriptor = -1
        fileDescriptor = -1
        return session
    }

    static func shuffledBlockOrder(blockCount: Int, seed: UInt64) -> [Int] {
        var values = Array(0..<blockCount)
        var state = seed ^ 0xA24B_AED4_963E_E407
        guard values.count > 1 else { return values }
        for index in values.indices.dropFirst().reversed() {
            let swapIndex = Int(nextRandom(&state) % UInt64(index + 1))
            values.swapAt(index, swapIndex)
        }
        return values
    }

    static func blockData(
        blockIndex: Int,
        generation: UInt64,
        seed: UInt64
    ) -> [UInt8] {
        var state = seed
            ^ (UInt64(blockIndex) &* 0x9E37_79B9_7F4A_7C15)
            ^ (generation &* 0xD1B5_4A32_D192_ED03)
        var bytes = [UInt8](repeating: 0, count: blockBytes)
        var word: UInt64 = 0
        for index in bytes.indices {
            if index.isMultiple(of: MemoryLayout<UInt64>.size) {
                word = nextRandom(&state)
            }
            bytes[index] = UInt8(truncatingIfNeeded: word >> ((index & 7) * 8))
        }
        return bytes
    }

    static func checksum(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
    }

    static func nextRandom(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    static func offset(forBlockIndex blockIndex: Int) -> off_t {
        off_t(blockIndex) * off_t(blockBytes)
    }

    static func monotonicNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedNanoseconds(from startedAt: UInt64, to finishedAt: UInt64) -> UInt64 {
        finishedAt >= startedAt ? finishedAt - startedAt : 0
    }
}

private final class WorkItemCursor: @unchecked Sendable {
    private let lock = NSLock()
    private let items: [StorageRandomAccessBenchmarkV7.WorkItem]
    private var nextIndex = 0

    init(items: [StorageRandomAccessBenchmarkV7.WorkItem]) {
        self.items = items
    }

    func next() -> StorageRandomAccessBenchmarkV7.WorkItem? {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < items.count else { return nil }
        let item = items[nextIndex]
        nextIndex += 1
        return item
    }
}

private final class PrivateFileSession {
    private var parentDescriptor: Int32
    private var directoryDescriptor: Int32
    private var storedFileDescriptor: Int32
    private let directoryName: String
    private let fileName: String

    var fileDescriptor: Int32 { storedFileDescriptor }

    init(
        parentDescriptor: Int32,
        directoryDescriptor: Int32,
        fileDescriptor: Int32,
        directoryName: String,
        fileName: String
    ) {
        self.parentDescriptor = parentDescriptor
        self.directoryDescriptor = directoryDescriptor
        self.storedFileDescriptor = fileDescriptor
        self.directoryName = directoryName
        self.fileName = fileName
    }

    deinit {
        cleanupBestEffort()
    }

    func cleanup() throws {
        var firstError: StorageRandomAccessBenchmarkV7.Failure?
        if storedFileDescriptor >= 0 {
            if Darwin.close(storedFileDescriptor) != 0 {
                firstError = .systemFailure(errno)
            }
            storedFileDescriptor = -1
        }
        if directoryDescriptor >= 0 {
            let fileRemoved = fileName.withCString {
                unlinkat(directoryDescriptor, $0, 0)
            }
            if fileRemoved != 0, errno != ENOENT, firstError == nil {
                firstError = .systemFailure(errno)
            }
        }
        if parentDescriptor >= 0 {
            let directoryRemoved = directoryName.withCString {
                unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            }
            if directoryRemoved != 0, errno != ENOENT, firstError == nil {
                firstError = .systemFailure(errno)
            }
        }
        if directoryDescriptor >= 0 {
            _ = Darwin.close(directoryDescriptor)
            directoryDescriptor = -1
        }
        if parentDescriptor >= 0 {
            _ = Darwin.close(parentDescriptor)
            parentDescriptor = -1
        }
        if let firstError { throw firstError }
    }

    func cleanupBestEffort() {
        try? cleanup()
    }
}
