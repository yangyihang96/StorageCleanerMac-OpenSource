import Darwin
import Foundation

/// App-owned fixture only. F_NOCACHE requests cache bypass; writes include fsync
/// at the end of each repeat (not an assertion about SSD hardware persistence).
final class MSeriesStorageKernel {
    private static let fileBytes = 64 * 1024 * 1024
    private static let chunkBytes = 1024 * 1024
    private static let randomOperations = 1024
    private let directory: URL
    private let fileURL: URL
    private let descriptor: Int32
    private let source: UnsafeMutableRawPointer
    private let readBuffer: UnsafeMutableRawPointer
    private let identity: FileIdentity
    private let directoryIdentity: FileIdentity
    private let writeBudget: MSeriesWriteBudget
    private let resourceReceipt: TemporaryResourceReceipt?
    var writtenBytes: UInt64 { writeBudget.writtenBytes }
    private var closed = false
    private let cancellation: MSeriesCancellation
    private let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000

    init(root: URL, sessionID: UUID, budget: UInt64, cancellation: MSeriesCancellation,
         writeBudget: MSeriesWriteBudget = MSeriesWriteBudget(),
         resourceJournal: CleanupReportJournal? = nil) throws {
        guard budget >= 128 * 1024 * 1024 else { throw MSeriesKernelError.resourceBudget }
        self.cancellation = cancellation
        self.writeBudget = writeBudget
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !PathSafety.containsSymbolicLinkComponent(in: root.path) else { throw MSeriesKernelError.unsafePath }
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = capacity.volumeAvailableCapacityForImportantUsage, free >= 128 * 1024 * 1024 else {
            throw MSeriesKernelError.resourceBudget
        }
        directory = root.appendingPathComponent("mseries-" + sessionID.uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw MSeriesKernelError.unsafePath }
        do {
            directoryIdentity = try FoundationReadOnlyFileSystem().snapshot(at: directory).identity
            if let resourceJournal {
                resourceReceipt = try TemporaryResourceReceipt(url: directory, journal: resourceJournal,
                                                               ruleID: "benchmark.fixture.v1")
            } else { resourceReceipt = nil }
        } catch {
            _ = rmdir(directory.path)
            throw error
        }
        fileURL = directory.appendingPathComponent("fixed-64MiB.bin")
        let fd = open(fileURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if rmdir(directory.path) == 0 { try? resourceReceipt?.checkpoint(pending: false) }
            throw MSeriesKernelError.io
        }
        guard fcntl(fd, F_NOCACHE, 1) == 0,
              let snapshot = try? FoundationReadOnlyFileSystem().snapshot(at: fileURL) else {
            close(fd); _ = rmdir(directory.path); throw MSeriesKernelError.io
        }
        descriptor = fd; identity = snapshot.identity
        source = .allocate(byteCount: Self.chunkBytes, alignment: 4096)
        readBuffer = .allocate(byteCount: Self.fileBytes, alignment: 4096)
        for i in 0..<Self.chunkBytes { source.storeBytes(of: UInt8((i * 31 + 17) % 251), toByteOffset: i, as: UInt8.self) }
        // Fixture initialization counts against the same total write budget.
        do {
            try reserveWrite(Self.fileBytes)
            for offset in stride(from: 0, to: Self.fileBytes, by: Self.chunkBytes) {
                try check()
                try writeAll(source, size: Self.chunkBytes, offset: offset)
            }
            guard fsync(fd) == 0 else { throw MSeriesKernelError.io }
        } catch {
            close(fd); closed = true
            source.deallocate(); readBuffer.deallocate()
            if let current = try? FoundationReadOnlyFileSystem().snapshot(at: fileURL),
               !current.hasSymbolicLinkComponent, current.identity == identity {
                try? fm.removeItem(at: fileURL)
            }
            if rmdir(directory.path) == 0 { try? resourceReceipt?.checkpoint(pending: false) }
            throw error
        }
    }
    deinit {
        if !closed { close(descriptor); source.deallocate(); readBuffer.deallocate() }
        // Retain unknown/replaced paths; never recursively clean by a prefix.
        if let current = try? FoundationReadOnlyFileSystem().snapshot(at: fileURL),
           !current.hasSymbolicLinkComponent, current.identity == identity,
           let parent = try? FoundationReadOnlyFileSystem().snapshot(at: directory),
           !parent.hasSymbolicLinkComponent, parent.identity == directoryIdentity {
            try? FileManager.default.removeItem(at: fileURL)
            if rmdir(directory.path) == 0 { try? resourceReceipt?.checkpoint(pending: false) }
        }
    }

    func measure(random: Bool, write: Bool) throws -> MSeriesMeasurement {
        _ = try sample(random: random, write: write) // Fixed warmup, never scored.
        var samples: [BenchmarkV7RawSample] = [], latencies: [[UInt64]] = []
        for _ in 0..<MSeriesProtocol.samples {
            let measured = try sample(random: random, write: write)
            samples.append(measured.0); latencies.append(measured.1)
        }
        let id = random ? (write ? "storage.randomWriteQD1" : "storage.randomReadQD1") :
            (write ? "storage.seqWrite" : "storage.seqRead")
        return MSeriesMeasurement(id: id, unit: random ? "IOPS" : "GB/s", availability: .available,
            reason: nil, samples: samples, statistics: try BenchmarkStatistics.summarize(samples.map(\.value)),
            repetitions: 1, workers: 1, ioLatencyNanoseconds: random ? latencies : nil)
    }

    private func sample(random: Bool, write: Bool) throws -> (BenchmarkV7RawSample, [UInt64]) {
        try check()
        let count = random ? Self.randomOperations : Self.fileBytes / Self.chunkBytes
        let size = random ? 4096 : Self.chunkBytes
        if write { try reserveWrite(count * size) }
        let offsets = (0..<count).map { index in
            random ? ((index * 7919 + 127) % (Self.fileBytes / 4096)) * 4096 : index * Self.chunkBytes
        }
        var latency = [UInt64](repeating: 0, count: count)
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<count {
            try check()
            let offset = offsets[index]
            let point = DispatchTime.now().uptimeNanoseconds
            if write { try writeAll(source.advanced(by: offset % Self.chunkBytes), size: size, offset: offset) }
            else { try readAll(readBuffer.advanced(by: index * size), size: size, offset: offset) }
            latency[index] = DispatchTime.now().uptimeNanoseconds - point
        }
        if write, fsync(descriptor) != 0 { throw MSeriesKernelError.io }
        let end = DispatchTime.now().uptimeNanoseconds
        // Checksum/content verification is outside the measurement but within
        // the same safety deadline, for both read and write workloads.
        if write {
            for offset in stride(from: 0, to: Self.fileBytes, by: Self.chunkBytes) {
                try check(); try readAll(readBuffer, size: Self.chunkBytes, offset: offset)
                guard memcmp(readBuffer, source, Self.chunkBytes) == 0 else { throw MSeriesKernelError.invalidOutput }
            }
        } else {
            for index in 0..<count {
                try check()
                guard memcmp(readBuffer.advanced(by: index * size), source.advanced(by: offsets[index] % Self.chunkBytes), size) == 0 else {
                    throw MSeriesKernelError.invalidOutput
                }
            }
        }
        try check()
        let elapsed = Double(end - start) / 1e9
        let value = random ? Double(count) / elapsed : Double(count * size) / elapsed / 1e9
        guard elapsed > 0, value.isFinite, value > 0 else { throw MSeriesKernelError.invalidTiming }
        return (BenchmarkV7RawSample(value: value, elapsedSeconds: elapsed,
            wallElapsedSeconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9,
            checksum: UInt64(count * size)), random ? latency : [])
    }
    private func reserveWrite(_ bytes: Int) throws {
        try writeBudget.reserve(bytes)
    }

    private func check() throws {
        try cancellation.check()
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw MSeriesKernelError.io }
    }
    private func writeAll(_ buffer: UnsafeRawPointer, size: Int, offset: Int) throws {
        var done = 0
        while done < size {
            try check()
            let count = pwrite(descriptor, buffer.advanced(by: done), size - done, off_t(offset + done))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw MSeriesKernelError.io }
            try writeBudget.recordWritten(count)
            done += count
        }
    }
    private func readAll(_ buffer: UnsafeMutableRawPointer, size: Int, offset: Int) throws {
        var done = 0
        while done < size {
            try check()
            let count = pread(descriptor, buffer.advanced(by: done), size - done, off_t(offset + done))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw MSeriesKernelError.io }; done += count
        }
    }
}
