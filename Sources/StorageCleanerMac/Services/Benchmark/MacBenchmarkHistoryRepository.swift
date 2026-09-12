import Darwin
import Foundation

private actor MacBenchmarkHistoryProcessLockCoordinator {
    private var heldKeys: Set<String> = []

    func acquireIfAvailable(_ key: String) -> Bool {
        heldKeys.insert(key).inserted
    }

    func release(_ key: String) {
        heldKeys.remove(key)
    }
}

protocol MacBenchmarkHistoryPersisting: Sendable {
    func load() async -> [MacBenchmarkResult]
    func save(_ result: MacBenchmarkResult) async throws
    func loadStatus() async -> MacBenchmarkHistoryLoadStatus
}

extension MacBenchmarkHistoryPersisting {
    func loadStatus() async -> MacBenchmarkHistoryLoadStatus { .loaded }
}

enum MacBenchmarkHistoryRepositoryError: Error, Equatable, Sendable {
    case invalidResult
    case historyFileUnreadable
    case historyFileTooLarge
    case historyFileCorrupt
    case atomicReplacementFailed(Int32)
    case fileLockFailed(Int32)
    case fileLockTimedOut
}

enum MacBenchmarkHistoryLoadStatus: Equatable, Sendable {
    case missing
    case loaded
    case failed(MacBenchmarkHistoryRepositoryError)
}

actor MacBenchmarkHistoryRepository: MacBenchmarkHistoryPersisting {
    static let maximumResultsPerProfile = 12
    static let maximumFileBytes: Int64 = 4 * 1_024 * 1_024
    static let maximumFutureClockSkew: TimeInterval = 5 * 60
    static let trustedScoreAbsoluteTolerance = 1e-9
    static let trustedScoreRelativeTolerance = 1e-12
    private static let processFileLocks = MacBenchmarkHistoryProcessLockCoordinator()
    static let defaultStorageURL: URL = {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("mac-benchmark-history.json", isDirectory: false)
    }()

    private enum RunIdentity: Hashable {
        case stable(UUID)
        case legacy(
            profile: BenchmarkProfile,
            workloadVersion: String,
            startedAt: Date
        )
    }

    private struct HistoryBucket: Hashable {
        let profile: BenchmarkProfile
        let workloadVersion: String
    }

    private let storageURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let trustedResultProcessors: [MacBenchmarkResultProcessor]
    private let fileLockTimeout: Duration
    private let fileLockRetryInterval: Duration
    private var currentLoadStatus: MacBenchmarkHistoryLoadStatus = .missing

    init(
        storageURL: URL = MacBenchmarkHistoryRepository.defaultStorageURL,
        fileManager: FileManager = .default,
        trustedResultProcessor: MacBenchmarkResultProcessor? = nil,
        trustedResultProcessors: [MacBenchmarkResultProcessor] = [],
        fileLockTimeout: Duration = .milliseconds(350),
        fileLockRetryInterval: Duration = .milliseconds(5)
    ) {
        self.storageURL = storageURL.standardizedFileURL
        self.fileManager = fileManager
        self.trustedResultProcessors =
            (trustedResultProcessor.map { [$0] } ?? [])
            + trustedResultProcessors
        self.fileLockTimeout = fileLockTimeout > .zero
            ? fileLockTimeout
            : .milliseconds(1)
        self.fileLockRetryInterval = fileLockRetryInterval > .zero
            ? fileLockRetryInterval
            : .milliseconds(1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func load() async -> [MacBenchmarkResult] {
        do {
            let stored = try await withExclusiveFileLock { directoryDescriptor in
                try readResults(in: directoryDescriptor)
            }
            currentLoadStatus = stored == nil ? .missing : .loaded
            return boundedAndValidated(stored ?? [])
        } catch let error as MacBenchmarkHistoryRepositoryError {
            currentLoadStatus = .failed(error)
            return []
        } catch {
            currentLoadStatus = .failed(.historyFileUnreadable)
            return []
        }
    }

    func loadStatus() async -> MacBenchmarkHistoryLoadStatus {
        currentLoadStatus
    }

    func save(_ result: MacBenchmarkResult) async throws {
        guard let normalized = normalizedSuccessfulResult(
            result,
            downgradeUntrustedScore: false
        ) else {
            throw MacBenchmarkHistoryRepositoryError.invalidResult
        }

        try await withExclusiveFileLock { directoryDescriptor in
            var results = try readResults(in: directoryDescriptor) ?? []
            results.append(normalized)
            try persist(
                boundedAndValidated(results),
                in: directoryDescriptor
            )
        }
    }

    private func boundedAndValidated(
        _ results: [MacBenchmarkResult]
    ) -> [MacBenchmarkResult] {
        var latestByIdentity: [RunIdentity: MacBenchmarkResult] = [:]
        for candidate in results {
            guard let result = normalizedSuccessfulResult(
                candidate,
                downgradeUntrustedScore: true
            ), let raw = result.rawResult else { continue }
            let identity = BenchmarkSessionIdentity.stableID(for: raw)
                .map(RunIdentity.stable)
                ?? .legacy(
                    profile: raw.profile,
                    workloadVersion: raw.workloadVersion,
                    startedAt: raw.startedAt
                )
            if let existing = latestByIdentity[identity],
               completionDate(of: existing) > completionDate(of: result)
            {
                continue
            }
            if let existing = latestByIdentity[identity],
               completionDate(of: existing) == completionDate(of: result),
               existing.overallScore != nil,
               result.overallScore == nil
            {
                continue
            }
            latestByIdentity[identity] = result
        }

        let newestFirst = latestByIdentity.values.sorted { lhs, rhs in
            let lhsCompleted = completionDate(of: lhs)
            let rhsCompleted = completionDate(of: rhs)
            if lhsCompleted == rhsCompleted {
                return lhs.rawResult!.startedAt > rhs.rawResult!.startedAt
            }
            return lhsCompleted > rhsCompleted
        }

        // Workload generations are not directly comparable. Keep a bounded
        // history for each profile + workload pair so the first raw-only run of
        // a new generation cannot evict the last trusted score from an older one.
        var counts: [HistoryBucket: Int] = [:]
        return newestFirst.filter { result in
            guard let raw = result.rawResult else { return false }
            let bucket = HistoryBucket(
                profile: raw.profile,
                workloadVersion: raw.workloadVersion
            )
            let count = counts[bucket, default: 0]
            guard count < Self.maximumResultsPerProfile else { return false }
            counts[bucket] = count + 1
            return true
        }
    }

    private func completionDate(of result: MacBenchmarkResult) -> Date {
        result.rawResult?.completedAt ?? .distantPast
    }

    /// Returns canonical trusted scores. Persisted scores are never used directly:
    /// a loaded but unverifiable score is reduced to its still-valid raw measurements.
    private func normalizedSuccessfulResult(
        _ result: MacBenchmarkResult,
        downgradeUntrustedScore: Bool
    ) -> MacBenchmarkResult? {
        guard result.isComplete,
              let raw = result.rawResult,
              raw.isComplete,
              let completedAt = raw.completedAt,
              let postflight = raw.postflight,
              raw.startedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt.timeIntervalSinceReferenceDate.isFinite,
              raw.preflight.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              postflight.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              raw.startedAt <= raw.preflight.capturedAt,
              raw.preflight.capturedAt <= postflight.capturedAt,
              postflight.capturedAt <= completedAt,
              completedAt <= Date().addingTimeInterval(Self.maximumFutureClockSkew),
              raw.environment.activeProcessorCount > 0,
              raw.environment.physicalMemoryBytes > 0,
              raw.preflight.availableDiskBytes >= 0,
              raw.preflight.requiredDiskBytes >= 0,
              isShortNonempty(raw.workloadVersion, maximum: 96),
              isShortNonempty(raw.environment.chipName, maximum: 256),
              isShortNonempty(raw.environment.operatingSystemVersion, maximum: 128),
              isShortNonempty(raw.environment.appVersion, maximum: 64),
              isShortNonempty(raw.environment.appBuild, maximum: 64),
              result.componentScores.keys.allSatisfy(BenchmarkComponent.allCases.contains),
              result.componentScores.values.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }

        if let batteryPercent = raw.preflight.batteryPercent,
           !batteryPercent.isFinite || !(0...100).contains(batteryPercent)
        {
            return nil
        }
        if let overallScore = result.overallScore,
           !overallScore.isFinite || overallScore <= 0
        {
            return nil
        }
        let rawOnly = MacBenchmarkScoring.rawOnly(rawResult: raw)
        let declaresScore = !result.componentScores.isEmpty
            || result.overallScore != nil
            || result.matchedBaselineKey != nil
        guard declaresScore else { return rawOnly }

        let hasEveryComponentScore = result.componentScores.count
            == BenchmarkComponent.allCases.count
            && BenchmarkComponent.allCases.allSatisfy {
                result.componentScores[$0] != nil
            }
        guard hasEveryComponentScore,
              result.overallScore != nil,
              MacBenchmarkScoring.hasComparableEnvironment(raw),
              let trusted = uniquelyRecomputedTrustedResult(
                for: raw,
                claimedComparisonKey: result.comparisonKey,
                claimedMatchedBaselineKey: result.matchedBaselineKey
              ),
              scoreDictionaryMatches(
                claimed: result.componentScores,
                trusted: trusted.componentScores
              ),
              scoresMatch(
                claimed: result.overallScore,
                trusted: trusted.overallScore
              ) else {
            return downgradeUntrustedScore ? rawOnly : nil
        }
        // Even accepted tolerance-level drift is discarded; only recomputed values persist.
        return trusted
    }

    private func uniquelyRecomputedTrustedResult(
        for raw: MacBenchmarkRawResult,
        claimedComparisonKey: BenchmarkComparisonKey?,
        claimedMatchedBaselineKey: BenchmarkComparisonKey?
    ) -> MacBenchmarkResult? {
        guard let claimedComparisonKey,
              claimedMatchedBaselineKey == claimedComparisonKey else {
            return nil
        }
        let matches: [MacBenchmarkResult] = trustedResultProcessors.compactMap {
            processor -> MacBenchmarkResult? in
            guard let processed = try? processor.process(raw),
                  processed.rawOnlyReason == nil,
                  processed.result.comparisonKey == claimedComparisonKey,
                  processed.result.matchedBaselineKey == claimedComparisonKey else {
                return nil
            }
            return processed.result
        }
        // Duplicate or conflicting trusted catalogs are a configuration error;
        // fail closed instead of choosing one by order.
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func scoreDictionaryMatches(
        claimed: [BenchmarkComponent: Double],
        trusted: [BenchmarkComponent: Double]
    ) -> Bool {
        guard claimed.count == BenchmarkComponent.allCases.count,
              trusted.count == BenchmarkComponent.allCases.count else {
            return false
        }
        return BenchmarkComponent.allCases.allSatisfy { component in
            scoresMatch(claimed: claimed[component], trusted: trusted[component])
        }
    }

    /// The absolute floor covers only sub-nanopoint serialization drift. The relative
    /// term remains at one trillionth of a score, and accepted values are canonicalized.
    private func scoresMatch(claimed: Double?, trusted: Double?) -> Bool {
        guard let claimed, let trusted,
              claimed.isFinite, trusted.isFinite,
              claimed > 0, trusted > 0 else { return false }
        let tolerance = max(
            Self.trustedScoreAbsoluteTolerance,
            abs(trusted) * Self.trustedScoreRelativeTolerance
        )
        return abs(claimed - trusted) <= tolerance
    }

    private func withExclusiveFileLock<T>(
        _ operation: (Int32) throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: fileLockTimeout)
        let key = storageURL.path
        try await acquireProcessLock(key: key, clock: clock, deadline: deadline)
        do {
            let value = try await withAdvisoryFileLock(
                clock: clock,
                deadline: deadline,
                operation
            )
            await Self.processFileLocks.release(key)
            return value
        } catch {
            await Self.processFileLocks.release(key)
            throw error
        }
    }

    private func acquireProcessLock(
        key: String,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw MacBenchmarkHistoryRepositoryError.fileLockTimedOut
            }
            if await Self.processFileLocks.acquireIfAvailable(key) {
                do {
                    try Task.checkCancellation()
                    return
                } catch {
                    await Self.processFileLocks.release(key)
                    throw error
                }
            }
            try await waitForLockRetry(clock: clock, deadline: deadline)
        }
    }

    private func withAdvisoryFileLock<T>(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant,
        _ operation: (Int32) throws -> T
    ) async throws -> T {
        let directoryDescriptor = try openStorageDirectory()
        defer { _ = Darwin.close(directoryDescriptor) }

        let fileName = try validatedStorageFileName()
        let lockName = fileName + ".lock"
        guard lockName.utf8.count <= Int(NAME_MAX) else {
            throw MacBenchmarkHistoryRepositoryError.fileLockFailed(ENAMETOOLONG)
        }
        let descriptor = lockName.withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw MacBenchmarkHistoryRepositoryError.fileLockFailed(errno)
        }
        var lockAcquired = false
        defer {
            if lockAcquired {
                _ = flock(descriptor, LOCK_UN)
            }
            _ = Darwin.close(descriptor)
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw MacBenchmarkHistoryRepositoryError.fileLockFailed(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            throw MacBenchmarkHistoryRepositoryError.fileLockFailed(EPERM)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw MacBenchmarkHistoryRepositoryError.fileLockFailed(errno)
        }

        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw MacBenchmarkHistoryRepositoryError.fileLockTimedOut
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                lockAcquired = true
                break
            }
            let code = errno
            if code == EINTR {
                continue
            }
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw MacBenchmarkHistoryRepositoryError.fileLockFailed(code)
            }
            try await waitForLockRetry(clock: clock, deadline: deadline)
        }
        try Task.checkCancellation()
        return try operation(directoryDescriptor)
    }

    private func waitForLockRetry(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        try Task.checkCancellation()
        guard clock.now < deadline else {
            throw MacBenchmarkHistoryRepositoryError.fileLockTimedOut
        }
        try await Task.sleep(for: fileLockRetryInterval)
    }

    private func openStorageDirectory() throws -> Int32 {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let descriptor = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw MacBenchmarkHistoryRepositoryError.fileLockFailed(errno)
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw MacBenchmarkHistoryRepositoryError.fileLockFailed(code)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            _ = Darwin.close(descriptor)
            throw MacBenchmarkHistoryRepositoryError.fileLockFailed(EPERM)
        }
        return descriptor
    }

    private func validatedStorageFileName() throws -> String {
        let fileName = storageURL.lastPathComponent
        guard fileName != ".", fileName != "..", !fileName.isEmpty,
              !fileName.utf8.contains(0),
              fileName.utf8.count <= Int(NAME_MAX) else {
            throw MacBenchmarkHistoryRepositoryError.fileLockFailed(EINVAL)
        }
        return fileName
    }

    private func isShortNonempty(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
    }

    /// A missing history file is the only condition treated as an empty history.
    /// Existing bytes that cannot be read or decoded must fail the next save so
    /// a new result never silently replaces potentially recoverable history.
    private func readResults(
        in directoryDescriptor: Int32
    ) throws -> [MacBenchmarkResult]? {
        let fileName = try validatedStorageFileName()
        let descriptor = fileName.withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw MacBenchmarkHistoryRepositoryError.historyFileUnreadable
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw MacBenchmarkHistoryRepositoryError.historyFileUnreadable
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            throw MacBenchmarkHistoryRepositoryError.historyFileUnreadable
        }
        guard status.st_size >= 0 else {
            throw MacBenchmarkHistoryRepositoryError.historyFileUnreadable
        }
        guard status.st_size <= Self.maximumFileBytes else {
            throw MacBenchmarkHistoryRepositoryError.historyFileTooLarge
        }
        guard let data = readData(
            from: descriptor,
            byteCount: Int(status.st_size)
        ) else {
            throw MacBenchmarkHistoryRepositoryError.historyFileUnreadable
        }
        do {
            return try decoder.decode([MacBenchmarkResult].self, from: data)
        } catch {
            throw MacBenchmarkHistoryRepositoryError.historyFileCorrupt
        }
    }

    private func readData(from descriptor: Int32, byteCount: Int) -> Data? {
        var data = Data(count: byteCount)
        let succeeded = data.withUnsafeMutableBytes { buffer -> Bool in
            guard byteCount > 0 else { return true }
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < byteCount {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                return false
            }
            return true
        }
        return succeeded ? data : nil
    }

    private func persist(
        _ results: [MacBenchmarkResult],
        in directoryDescriptor: Int32
    ) throws {
        let data = try encoder.encode(results)
        guard data.count <= Self.maximumFileBytes else {
            throw MacBenchmarkHistoryRepositoryError.invalidResult
        }

        let fileName = try validatedStorageFileName()
        let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
        guard temporaryName.utf8.count <= Int(NAME_MAX) else {
            throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(
                ENAMETOOLONG
            )
        }
        let descriptor = temporaryName.withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(errno)
        }
        var shouldRemoveTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }

        do {
            var temporaryStatus = stat()
            guard Darwin.fstat(descriptor, &temporaryStatus) == 0 else {
                throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(errno)
            }
            guard (temporaryStatus.st_mode & S_IFMT) == S_IFREG,
                  temporaryStatus.st_uid == geteuid(),
                  temporaryStatus.st_nlink == 1 else {
                throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(
                    EPERM
                )
            }
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(errno)
            }
            try write(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(errno)
            }

            var destinationStatus = stat()
            let destinationStatusResult = fileName.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &destinationStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            if destinationStatusResult == 0 {
                guard (destinationStatus.st_mode & S_IFMT) == S_IFREG,
                      destinationStatus.st_uid == geteuid(),
                      destinationStatus.st_nlink == 1 else {
                    throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(
                        EPERM
                    )
                }
            } else if errno != ENOENT {
                throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(errno)
            }

            let renameResult = temporaryName.withCString { temporary in
                fileName.withCString { destination in
                    Darwin.renameat(
                        directoryDescriptor,
                        temporary,
                        directoryDescriptor,
                        destination
                    )
                }
            }
            guard renameResult == 0 else {
                throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(errno)
            }
            shouldRemoveTemporary = false
            _ = Darwin.fsync(directoryDescriptor)
        } catch let error as MacBenchmarkHistoryRepositoryError {
            throw error
        } catch {
            throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(EIO)
        }
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw MacBenchmarkHistoryRepositoryError.atomicReplacementFailed(
                    count == 0 ? EIO : errno
                )
            }
        }
    }
}
