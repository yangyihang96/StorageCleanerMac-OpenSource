import Darwin
import Foundation

struct DiskBenchmarkOrphanCandidate: Equatable, Sendable {
    let url: URL
    let modificationDate: Date
    let isRegularFile: Bool
    let isSymbolicLink: Bool
}

protocol DiskBenchmarkFileSession: Sendable {
    func disableCache() async throws
    func write(_ data: Data) async throws
    func synchronize() async throws
    func rewind() async throws
    func read(upToCount count: Int) async throws -> Data
    func close() async
}

protocol DiskBenchmarkFileManaging: Sendable {
    func prepareDirectory(_ url: URL) async throws
    func availableCapacity(at url: URL) async throws -> Int64
    func createExclusiveFile(at url: URL) async throws -> any DiskBenchmarkFileSession
    func removeFile(at url: URL) async throws
    func orphanCandidates(in directory: URL) async throws -> [DiskBenchmarkOrphanCandidate]
}

struct DiskBenchmarkKernel: Sendable {
    static let quickFileBytes = 256 * 1_024 * 1_024
    static let fullFileBytes = 768 * 1_024 * 1_024
    static let reservedCapacityBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let maximumQuickElapsedSeconds = 60.0
    static let maximumFullElapsedSeconds = 120.0

    struct Limits: Equatable, Sendable {
        let fileBytes: Int
        let blockBytes: Int
        let writePassCount: Int
        let maximumElapsedSeconds: Double
    }

    struct Configuration: Equatable, Sendable {
        let quick: Limits
        let full: Limits

        static let standard = Self(
            quick: Limits(
                fileBytes: DiskBenchmarkKernel.quickFileBytes,
                blockBytes: 1 * 1_024 * 1_024,
                writePassCount: 3,
                maximumElapsedSeconds: DiskBenchmarkKernel.maximumQuickElapsedSeconds
            ),
            full: Limits(
                fileBytes: DiskBenchmarkKernel.fullFileBytes,
                blockBytes: 1 * 1_024 * 1_024,
                writePassCount: 3,
                maximumElapsedSeconds: DiskBenchmarkKernel.maximumFullElapsedSeconds
            )
        )

        static let testing = Self(
            quick: Limits(
                fileBytes: 32 * 1_024,
                blockBytes: 4 * 1_024,
                writePassCount: 1,
                maximumElapsedSeconds: 2
            ),
            full: Limits(
                fileBytes: 64 * 1_024,
                blockBytes: 4 * 1_024,
                writePassCount: 1,
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
        let writeSample: BenchmarkComponentSample
        let readSample: BenchmarkComponentSample
        let fileBytes: Int
        let requiredCapacityBytes: Int64
        let ranOnMainThread: Bool
    }

    static var defaultRootDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("StorageCleanerMac", isDirectory: true)
            .appendingPathComponent("BenchmarkTemporary", isDirectory: true)
    }

    let configuration: Configuration
    let rootDirectory: URL
    private let clock: any BenchmarkKernelClock
    private let fileManager: any DiskBenchmarkFileManaging

    init(
        configuration: Configuration = .standard,
        rootDirectory: URL = DiskBenchmarkKernel.defaultRootDirectory,
        clock: any BenchmarkKernelClock = SystemBenchmarkKernelClock(),
        fileManager: (any DiskBenchmarkFileManaging)? = nil
    ) {
        let standardizedRoot = rootDirectory.standardizedFileURL
        self.configuration = configuration
        self.rootDirectory = standardizedRoot
        self.clock = clock
        self.fileManager = fileManager
            ?? SystemDiskBenchmarkFileManager(rootDirectory: standardizedRoot)
    }

    static func requiredCapacity(forFileBytes fileBytes: Int) -> Int64 {
        guard fileBytes >= 0 else { return .max }
        let (twice, firstOverflow) = Int64(fileBytes).multipliedReportingOverflow(by: 2)
        let (required, secondOverflow) = twice.addingReportingOverflow(reservedCapacityBytes)
        return firstOverflow || secondOverflow ? .max : required
    }

    func run(profile: BenchmarkProfile) async throws -> RunResult {
        try Task.checkCancellation()
        let limits = configuration.limits(for: profile)
        try Self.validate(limits, profile: profile)
        let clock = clock
        let fileManager = fileManager
        let rootDirectory = rootDirectory

        let worker = Task.detached(priority: .userInitiated) {
            try await Self.runDetached(
                limits: limits,
                rootDirectory: rootDirectory,
                clock: clock,
                fileManager: fileManager
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

    @discardableResult
    func cleanupOrphans(
        olderThan age: TimeInterval,
        now: Date = Date()
    ) async throws -> Int {
        guard age.isFinite, age >= 0 else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        let rootDirectory = rootDirectory
        let fileManager = fileManager
        let worker = Task.detached(priority: .utility) {
            try await fileManager.prepareDirectory(rootDirectory)
            let candidates = try await fileManager.orphanCandidates(in: rootDirectory)
            let cutoff = now.addingTimeInterval(-age)
            var removed = 0
            for candidate in candidates {
                try Task.checkCancellation()
                let standardized = candidate.url.standardizedFileURL
                guard standardized.deletingLastPathComponent().path == rootDirectory.path,
                      standardized.lastPathComponent.hasPrefix("benchmark-"),
                      standardized.pathExtension == "tmp",
                      candidate.isRegularFile,
                      !candidate.isSymbolicLink,
                      candidate.modificationDate <= cutoff
                else { continue }
                try await fileManager.removeFile(at: standardized)
                removed += 1
            }
            return removed
        }
        return try await withTaskCancellationHandler {
            let removed = try await worker.value
            try Task.checkCancellation()
            return removed
        } onCancel: {
            worker.cancel()
        }
    }
}

private extension DiskBenchmarkKernel {
    static let minimumFileBytes = 4 * 1_024

    static func validate(_ limits: Limits, profile: BenchmarkProfile) throws {
        let maximumFileBytes: Int
        let maximumElapsedSeconds: Double
        switch profile {
        case .standard, .quick:
            maximumFileBytes = quickFileBytes
            maximumElapsedSeconds = maximumQuickElapsedSeconds
        case .full:
            maximumFileBytes = fullFileBytes
            maximumElapsedSeconds = maximumFullElapsedSeconds
        }

        guard limits.fileBytes >= minimumFileBytes,
              limits.fileBytes <= maximumFileBytes,
              limits.blockBytes >= 4 * 1_024,
              limits.blockBytes <= 4 * 1_024 * 1_024,
              limits.blockBytes.isMultiple(of: 4 * 1_024),
              limits.fileBytes.isMultiple(of: 4 * 1_024),
              (1...4).contains(limits.writePassCount),
              limits.maximumElapsedSeconds.isFinite,
              limits.maximumElapsedSeconds > 0,
              limits.maximumElapsedSeconds <= maximumElapsedSeconds,
              requiredCapacity(forFileBytes: limits.fileBytes) != .max
        else {
            throw BenchmarkKernelError.resourceLimit
        }
    }

    static func runDetached(
        limits: Limits,
        rootDirectory: URL,
        clock: any BenchmarkKernelClock,
        fileManager: any DiskBenchmarkFileManaging
    ) async throws -> RunResult {
        let safetyStartedAt = clock.nowNanoseconds()
        try Task.checkCancellation()
        try await fileManager.prepareDirectory(rootDirectory)
        try checkSafetyBoundary(
            clock: clock,
            startedAt: safetyStartedAt,
            maximumElapsedSeconds: limits.maximumElapsedSeconds
        )

        let requiredCapacity = requiredCapacity(forFileBytes: limits.fileBytes)
        let capacity = try await fileManager.availableCapacity(at: rootDirectory)
        guard capacity >= requiredCapacity else {
            throw BenchmarkKernelError.resourceLimit
        }
        try checkSafetyBoundary(
            clock: clock,
            startedAt: safetyStartedAt,
            maximumElapsedSeconds: limits.maximumElapsedSeconds
        )

        let fileURL = rootDirectory
            .appendingPathComponent("benchmark-\(UUID().uuidString.lowercased()).tmp")
            .standardizedFileURL
        guard fileURL.deletingLastPathComponent().path == rootDirectory.path else {
            throw BenchmarkKernelError.invalidConfiguration
        }

        let session: any DiskBenchmarkFileSession
        do {
            session = try await fileManager.createExclusiveFile(at: fileURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BenchmarkKernelError {
            throw error
        } catch {
            throw BenchmarkKernelError.systemFailure
        }

        do {
            let result = try await execute(
                session: session,
                limits: limits,
                requiredCapacity: requiredCapacity,
                clock: clock,
                safetyStartedAt: safetyStartedAt
            )
            await session.close()
            do {
                try await fileManager.removeFile(at: fileURL)
            } catch {
                throw BenchmarkKernelError.systemFailure
            }
            return result
        } catch {
            await session.close()
            try? await fileManager.removeFile(at: fileURL)
            if error is CancellationError { throw CancellationError() }
            if let kernelError = error as? BenchmarkKernelError { throw kernelError }
            throw BenchmarkKernelError.systemFailure
        }
    }

    static func execute(
        session: any DiskBenchmarkFileSession,
        limits: Limits,
        requiredCapacity: Int64,
        clock: any BenchmarkKernelClock,
        safetyStartedAt: UInt64
    ) async throws -> RunResult {
        try await session.disableCache()
        let block = deterministicBlock(byteCount: limits.blockBytes)
        let expectedChecksum = fileChecksum(block: block, fileBytes: limits.fileBytes)
        try checkSafetyBoundary(
            clock: clock,
            startedAt: safetyStartedAt,
            maximumElapsedSeconds: limits.maximumElapsedSeconds
        )

        var durableWriteElapsedSamples: [Double] = []
        durableWriteElapsedSamples.reserveCapacity(limits.writePassCount)
        for passIndex in 0..<limits.writePassCount {
            if passIndex > 0 {
                try await session.rewind()
            }
            let passStartedAt = clock.nowNanoseconds()
            var writtenBytes = 0
            while writtenBytes < limits.fileBytes {
                try checkSafetyBoundary(
                    clock: clock,
                    startedAt: safetyStartedAt,
                    maximumElapsedSeconds: limits.maximumElapsedSeconds
                )
                let count = min(block.count, limits.fileBytes - writtenBytes)
                if count == block.count {
                    try await session.write(block)
                } else {
                    try await session.write(block.prefix(count))
                }
                writtenBytes += count
            }
            // F_NOCACHE keeps the sequential write representative of device I/O.
            // Flush every pass and include it in the timing so the metric reflects
            // data committed through APFS, not bytes only accepted by a cache.
            try await session.synchronize()
            let passFinishedAt = clock.nowNanoseconds()
            let passElapsed = seconds(from: passStartedAt, to: passFinishedAt)
            guard passElapsed.isFinite, passElapsed > 0 else {
                throw BenchmarkKernelError.invalidMetric
            }
            durableWriteElapsedSamples.append(passElapsed)
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )
        }

        try await session.rewind()
        let readStartedAt = clock.nowNanoseconds()
        var readBytes = 0
        while readBytes < limits.fileBytes {
            try checkSafetyBoundary(
                clock: clock,
                startedAt: safetyStartedAt,
                maximumElapsedSeconds: limits.maximumElapsedSeconds
            )
            let expectedCount = min(block.count, limits.fileBytes - readBytes)
            var blockOffset = 0
            while blockOffset < expectedCount {
                try checkSafetyBoundary(
                    clock: clock,
                    startedAt: safetyStartedAt,
                    maximumElapsedSeconds: limits.maximumElapsedSeconds
                )
                let remaining = expectedCount - blockOffset
                let data = try await session.read(upToCount: remaining)
                guard !data.isEmpty,
                      data.count <= remaining,
                      data.elementsEqual(
                          block[blockOffset..<(blockOffset + data.count)]
                      )
                else {
                    throw BenchmarkKernelError.checksumMismatch
                }
                blockOffset += data.count
                readBytes += data.count
            }
        }
        let readFinishedAt = clock.nowNanoseconds()
        try checkSafetyBoundary(
            clock: clock,
            startedAt: safetyStartedAt,
            maximumElapsedSeconds: limits.maximumElapsedSeconds,
            sampledAt: readFinishedAt
        )

        let writeElapsed = representativeElapsedSeconds(durableWriteElapsedSamples)
        let readElapsed = seconds(from: readStartedAt, to: readFinishedAt)
        let decimalGigabytes = Double(limits.fileBytes) / 1_000_000_000
        let writeThroughput = decimalGigabytes / writeElapsed
        let readThroughput = decimalGigabytes / readElapsed
        guard writeElapsed.isFinite, writeElapsed > 0,
              readElapsed.isFinite, readElapsed > 0,
              writeThroughput.isFinite, writeThroughput > 0,
              readThroughput.isFinite, readThroughput > 0
        else {
            throw BenchmarkKernelError.invalidMetric
        }

        return RunResult(
            writeSample: BenchmarkComponentSample(
                value: writeThroughput,
                elapsedSeconds: writeElapsed,
                checksum: expectedChecksum
            ),
            readSample: BenchmarkComponentSample(
                value: readThroughput,
                elapsedSeconds: readElapsed,
                checksum: expectedChecksum
            ),
            fileBytes: limits.fileBytes,
            requiredCapacityBytes: requiredCapacity,
            ranOnMainThread: benchmarkKernelIsMainThread()
        )
    }

    static func checkSafetyBoundary(
        clock: any BenchmarkKernelClock,
        startedAt: UInt64,
        maximumElapsedSeconds: Double,
        sampledAt: UInt64? = nil
    ) throws {
        try Task.checkCancellation()
        let finishedAt = sampledAt ?? clock.nowNanoseconds()
        guard seconds(from: startedAt, to: finishedAt) <= maximumElapsedSeconds else {
            throw BenchmarkKernelError.resourceLimit
        }
    }

    static func seconds(from startedAt: UInt64, to finishedAt: UInt64) -> Double {
        guard finishedAt >= startedAt else { return .infinity }
        return Double(finishedAt - startedAt) / 1_000_000_000
    }

    static func representativeElapsedSeconds(_ samples: [Double]) -> Double {
        guard !samples.isEmpty,
              samples.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return .infinity }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func deterministicBlock(byteCount: Int) -> Data {
        var data = Data(count: byteCount)
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        data.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<byteCount {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[index] = UInt8(truncatingIfNeeded: state &+ UInt64(index))
            }
        }
        return data
    }

    static func fileChecksum(block: Data, fileBytes: Int) -> UInt64 {
        var checksum: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in block {
            checksum ^= UInt64(byte)
            checksum &*= 0x0000_0100_0000_01B3
        }
        var offset = 0
        while offset < fileBytes {
            checksum ^= UInt64(offset)
            checksum = checksum.rotatedLeft(by: 13)
            offset += min(block.count, fileBytes - offset)
        }
        return checksum
    }
}

private actor SystemDiskBenchmarkFileManager: DiskBenchmarkFileManaging {
    private let rootDirectory: URL
    private var rootDescriptor: Int32 = -1

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    deinit {
        if rootDescriptor >= 0 {
            _ = Darwin.close(rootDescriptor)
        }
    }

    func prepareDirectory(_ url: URL) throws {
        try requireRoot(url)
        if rootDescriptor >= 0 {
            try Self.validateOwnedDirectory(descriptor: rootDescriptor)
            return
        }
        rootDescriptor = try Self.openPrivateRootDirectory(
            rootDirectory,
            createIfMissing: true
        )
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        try requireRoot(url)
        let descriptor = try requirePreparedDescriptor()
        var fileSystem = statfs()
        guard fstatfs(descriptor, &fileSystem) == 0 else {
            throw BenchmarkKernelError.systemFailure
        }
        let (available, overflow) = fileSystem.f_bavail.multipliedReportingOverflow(
            by: UInt64(fileSystem.f_bsize)
        )
        guard !overflow else { return Int64.max }
        return Int64(min(available, UInt64(Int64.max)))
    }

    func createExclusiveFile(at url: URL) throws -> any DiskBenchmarkFileSession {
        let name = try validatedBenchmarkFileName(url)
        let rootDescriptor = try requirePreparedDescriptor()
        let descriptor = name.withCString { fileName in
            openat(
                rootDescriptor,
                fileName,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw BenchmarkKernelError.systemFailure
        }

        var keepDescriptor = false
        defer {
            if !keepDescriptor {
                _ = Darwin.close(descriptor)
                _ = name.withCString { unlinkat(rootDescriptor, $0, 0) }
            }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0
        else {
            throw BenchmarkKernelError.systemFailure
        }
        keepDescriptor = true
        return POSIXDiskBenchmarkFileSession(descriptor: descriptor)
    }

    func removeFile(at url: URL) throws {
        let name = try validatedBenchmarkFileName(url)
        let rootDescriptor = try requirePreparedDescriptor()
        let result = name.withCString { unlinkat(rootDescriptor, $0, 0) }
        guard result == 0 || errno == ENOENT else {
            throw BenchmarkKernelError.systemFailure
        }
    }

    func orphanCandidates(in directory: URL) throws -> [DiskBenchmarkOrphanCandidate] {
        try requireRoot(directory)
        let rootDescriptor = try requirePreparedDescriptor()
        let enumerationDescriptor = dup(rootDescriptor)
        guard enumerationDescriptor >= 0 else {
            throw BenchmarkKernelError.systemFailure
        }
        guard let stream = fdopendir(enumerationDescriptor) else {
            _ = Darwin.close(enumerationDescriptor)
            throw BenchmarkKernelError.systemFailure
        }
        defer { closedir(stream) }

        var candidates: [DiskBenchmarkOrphanCandidate] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw BenchmarkKernelError.systemFailure }
                break
            }
            var nameBytes = entry.pointee.d_name
            let name = withUnsafePointer(to: &nameBytes) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != "..", !name.hasPrefix(".") else { continue }

            var info = stat()
            let result = name.withCString { fileName in
                fstatat(rootDescriptor, fileName, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else { continue }
            let type = info.st_mode & S_IFMT
            let seconds = TimeInterval(info.st_mtimespec.tv_sec)
            let nanoseconds = TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            candidates.append(
                DiskBenchmarkOrphanCandidate(
                    url: rootDirectory.appendingPathComponent(name).standardizedFileURL,
                    modificationDate: Date(
                        timeIntervalSince1970: seconds + nanoseconds
                    ),
                    isRegularFile: type == S_IFREG,
                    isSymbolicLink: type == S_IFLNK
                )
            )
        }
        return candidates
    }
}

private extension SystemDiskBenchmarkFileManager {
    func requireRoot(_ url: URL) throws {
        guard url.standardizedFileURL.path == rootDirectory.path else {
            throw BenchmarkKernelError.invalidConfiguration
        }
    }

    func requirePreparedDescriptor() throws -> Int32 {
        guard rootDescriptor >= 0 else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        try Self.validateOwnedDirectory(descriptor: rootDescriptor)
        return rootDescriptor
    }

    func validatedBenchmarkFileName(_ url: URL) throws -> String {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        guard standardized.deletingLastPathComponent().path == rootDirectory.path,
              name.hasPrefix("benchmark-"),
              standardized.pathExtension == "tmp",
              name != "benchmark-.tmp",
              !name.utf8.contains(0),
              name.utf8.count <= Int(NAME_MAX)
        else {
            throw BenchmarkKernelError.invalidConfiguration
        }
        return name
    }

    static func openPrivateRootDirectory(
        _ rootDirectory: URL,
        createIfMissing: Bool
    ) throws -> Int32 {
        let (trustedBase, components) = try trustedBaseAndComponents(
            for: rootDirectory
        )
        let baseDescriptor = trustedBase.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard baseDescriptor >= 0 else {
            throw BenchmarkKernelError.systemFailure
        }
        var currentDescriptor = baseDescriptor
        do {
            try validateOwnedDirectory(descriptor: baseDescriptor)
            for component in components {
                var nextDescriptor = component.withCString { name in
                    openat(
                        currentDescriptor,
                        name,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                if nextDescriptor < 0, errno == ENOENT, createIfMissing {
                    let createResult = component.withCString { name in
                        mkdirat(currentDescriptor, name, 0o700)
                    }
                    guard createResult == 0 || errno == EEXIST else {
                        throw BenchmarkKernelError.systemFailure
                    }
                    nextDescriptor = component.withCString { name in
                        openat(
                            currentDescriptor,
                            name,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                }
                guard nextDescriptor >= 0 else {
                    throw BenchmarkKernelError.systemFailure
                }
                do {
                    try validateOwnedDirectory(descriptor: nextDescriptor)
                    guard fchmod(nextDescriptor, 0o700) == 0 else {
                        throw BenchmarkKernelError.systemFailure
                    }
                } catch {
                    _ = Darwin.close(nextDescriptor)
                    throw error
                }
                _ = Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }
            return currentDescriptor
        } catch {
            _ = Darwin.close(currentDescriptor)
            throw error
        }
    }

    static func trustedBaseAndComponents(
        for rootDirectory: URL
    ) throws -> (URL, [String]) {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let applicationSupportBase = applicationSupport.standardizedFileURL
        let temporaryBase = fileManager.temporaryDirectory.standardizedFileURL
        let rootPath = rootDirectory.standardizedFileURL.path

        let allowedBases: [URL]
        if rootPath == DiskBenchmarkKernel.defaultRootDirectory.standardizedFileURL.path {
            allowedBases = [applicationSupportBase]
        } else {
            allowedBases = [temporaryBase]
        }
        for base in allowedBases {
            let basePath = base.path
            let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
            guard rootPath.hasPrefix(prefix) else { continue }
            let relative = String(rootPath.dropFirst(prefix.count))
            let components = relative.split(separator: "/").map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({
                      !$0.isEmpty
                          && $0 != "."
                          && $0 != ".."
                          && !$0.contains("/")
                          && !$0.utf8.contains(0)
                          && $0.utf8.count <= Int(NAME_MAX)
                  })
            else {
                throw BenchmarkKernelError.invalidConfiguration
            }
            return (base, components)
        }
        throw BenchmarkKernelError.invalidConfiguration
    }

    static func validateOwnedDirectory(descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid()
        else {
            throw BenchmarkKernelError.systemFailure
        }
    }
}

private final class POSIXDiskBenchmarkFileSession: DiskBenchmarkFileSession,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        closeDescriptor()
    }

    func disableCache() async throws {
        let descriptor = currentDescriptor()
        guard descriptor >= 0, fcntl(descriptor, F_NOCACHE, 1) == 0 else {
            throw BenchmarkKernelError.systemFailure
        }
    }

    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        let descriptor = currentDescriptor()
        guard descriptor >= 0 else { throw BenchmarkKernelError.systemFailure }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                try Task.checkCancellation()
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw BenchmarkKernelError.systemFailure }
                offset += result
            }
        }
    }

    func synchronize() async throws {
        try Task.checkCancellation()
        let descriptor = currentDescriptor()
        guard descriptor >= 0 else { throw BenchmarkKernelError.systemFailure }
        var result: Int32
        repeat {
            result = fsync(descriptor)
        } while result != 0 && errno == EINTR
        guard result == 0 else { throw BenchmarkKernelError.systemFailure }

        // fsync can return after the drive has accepted a flush into volatile
        // hardware caches. F_FULLFSYNC measures a durable local-disk write on
        // macOS; unsupported filesystems safely retain the completed fsync.
        repeat {
            result = fcntl(descriptor, F_FULLFSYNC)
        } while result != 0 && errno == EINTR
        guard result == 0 || errno == ENOTSUP || errno == EINVAL else {
            throw BenchmarkKernelError.systemFailure
        }
    }

    func rewind() async throws {
        try Task.checkCancellation()
        let descriptor = currentDescriptor()
        guard descriptor >= 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw BenchmarkKernelError.systemFailure
        }
    }

    func read(upToCount count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard count > 0 else { return Data() }
        let descriptor = currentDescriptor()
        guard descriptor >= 0 else { throw BenchmarkKernelError.systemFailure }
        var data = Data(count: count)
        let bytesRead: Int = try data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return 0 }
            while true {
                try Task.checkCancellation()
                let result = Darwin.read(descriptor, base, count)
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw BenchmarkKernelError.systemFailure }
                return result
            }
        }
        if bytesRead < data.count {
            data.removeSubrange(bytesRead..<data.count)
        }
        return data
    }

    func close() async {
        closeDescriptor()
    }

    private func currentDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    private func closeDescriptor() {
        lock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        lock.unlock()
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }
}

private extension UInt64 {
    func rotatedLeft(by amount: UInt64) -> UInt64 {
        let shift = amount & 63
        guard shift != 0 else { return self }
        return (self << shift) | (self >> (64 - shift))
    }
}
