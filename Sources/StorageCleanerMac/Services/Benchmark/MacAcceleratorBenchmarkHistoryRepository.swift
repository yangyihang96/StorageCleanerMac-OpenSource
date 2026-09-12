import Darwin
import Foundation

private actor MacAcceleratorBenchmarkHistoryProcessLockCoordinator {
    private var heldKeys: Set<String> = []

    func acquireIfAvailable(_ key: String) -> Bool {
        heldKeys.insert(key).inserted
    }

    func release(_ key: String) {
        heldKeys.remove(key)
    }
}

protocol MacAcceleratorBenchmarkHistoryPersisting: Sendable {
    func load() async -> [MacAcceleratorBenchmarkResult]
    func save(_ result: MacAcceleratorBenchmarkResult) async throws
}

enum MacAcceleratorBenchmarkHistoryRepositoryError: Error, Equatable {
    case invalidResult
    case atomicReplacementFailed(Int32)
    case fileLockFailed(Int32)
    case fileLockTimedOut
}

actor MacAcceleratorBenchmarkHistoryRepository:
    MacAcceleratorBenchmarkHistoryPersisting
{
    static let maximumResults = 12
    static let maximumFileBytes: Int64 = 1_024 * 1_024
    static let maximumFutureClockSkew: TimeInterval = 5 * 60

    private static let processFileLocks =
        MacAcceleratorBenchmarkHistoryProcessLockCoordinator()

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileLockTimeout: Duration
    private let fileLockRetryInterval: Duration

    init(
        fileURL: URL = MacAcceleratorBenchmarkHistoryRepository.defaultFileURL,
        fileManager: FileManager = .default,
        fileLockTimeout: Duration = .milliseconds(350),
        fileLockRetryInterval: Duration = .milliseconds(5)
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.fileLockTimeout = fileLockTimeout > .zero
            ? fileLockTimeout
            : .milliseconds(1)
        self.fileLockRetryInterval = fileLockRetryInterval > .zero
            ? fileLockRetryInterval
            : .milliseconds(1)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func load() async -> [MacAcceleratorBenchmarkResult] {
        (try? await withExclusiveFileLock { directoryDescriptor in
            boundedAndValidated(
                readResults(in: directoryDescriptor),
                now: Date()
            )
        }) ?? []
    }

    func save(_ result: MacAcceleratorBenchmarkResult) async throws {
        guard validated(result, now: Date()) != nil else {
            throw MacAcceleratorBenchmarkHistoryRepositoryError.invalidResult
        }

        try await withExclusiveFileLock { directoryDescriptor in
            let now = Date()
            var results = readResults(in: directoryDescriptor)
            results.append(result)
            try persist(
                boundedAndValidated(results, now: now),
                in: directoryDescriptor
            )
        }
    }
}

private extension MacAcceleratorBenchmarkHistoryRepository {
    struct RunIdentity: Hashable {
        let workloadVersion: String
        let startedAt: Date
    }

    static var defaultFileURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("mac-accelerator-benchmark-history.json")
    }

    func boundedAndValidated(
        _ results: [MacAcceleratorBenchmarkResult],
        now: Date
    ) -> [MacAcceleratorBenchmarkResult] {
        var latestByIdentity: [RunIdentity: MacAcceleratorBenchmarkResult] = [:]
        for candidate in results {
            guard let result = validated(candidate, now: now),
                  let completedAt = result.completedAt else { continue }
            let identity = RunIdentity(
                workloadVersion: result.workloadVersion,
                startedAt: result.startedAt
            )
            if let existing = latestByIdentity[identity],
               let existingCompletedAt = existing.completedAt,
               existingCompletedAt > completedAt {
                continue
            }
            latestByIdentity[identity] = result
        }

        return Array(
            latestByIdentity.values
                .sorted { lhs, rhs in
                    let lhsCompletedAt = lhs.completedAt ?? .distantPast
                    let rhsCompletedAt = rhs.completedAt ?? .distantPast
                    if lhsCompletedAt == rhsCompletedAt {
                        return lhs.startedAt > rhs.startedAt
                    }
                    return lhsCompletedAt > rhsCompletedAt
                }
                .prefix(Self.maximumResults)
        )
    }

    func validated(
        _ result: MacAcceleratorBenchmarkResult,
        now: Date
    ) -> MacAcceleratorBenchmarkResult? {
        guard result.isComplete,
              result.failure == nil,
              let completedAt = result.completedAt,
              let postflight = result.postflight,
              result.startedAt.timeIntervalSinceReferenceDate.isFinite,
              result.preflight.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              postflight.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt.timeIntervalSinceReferenceDate.isFinite,
              result.startedAt <= result.preflight.capturedAt,
              result.preflight.capturedAt <= postflight.capturedAt,
              postflight.capturedAt <= completedAt,
              completedAt <= now.addingTimeInterval(Self.maximumFutureClockSkew),
              isValid(environment: result.environment, preflight: result.preflight),
              isValid(preflight: result.preflight),
              isValid(postflight: postflight),
              result.measurements.count == MacAcceleratorMetric.allCases.count,
              result.measurementsByMetric.count
                == MacAcceleratorMetric.allCases.count,
              MacAcceleratorMetric.allCases.allSatisfy({ metric in
                  guard let measurement = result.measurementsByMetric[metric],
                        measurement.metric == metric else { return false }
                  return measurement.isValid(
                      expectedSampleCount: MacAcceleratorBenchmarkResult.sampleCount
                  )
              }) else {
            return nil
        }
        return result
    }

    func isValid(
        environment: BenchmarkEnvironmentMetadata,
        preflight: BenchmarkPreflight
    ) -> Bool {
        guard environment.architecture == .arm64,
              environment.activeProcessorCount > 0,
              environment.activeProcessorCount <= 4_096,
              environment.physicalMemoryBytes > 0,
              environment.systemDiskCapacityBytes.map({ $0 > 0 }) ?? true,
              environment.powerSource == preflight.powerSource,
              environment.thermalState == preflight.thermalState,
              isShortNonempty(environment.chipName, maximum: 256),
              isShortNonempty(
                  environment.operatingSystemVersion,
                  maximum: 128
              ),
              isShortNonempty(environment.appVersion, maximum: 64),
              isShortNonempty(environment.appBuild, maximum: 64) else {
            return false
        }
        return true
    }

    func isValid(preflight: BenchmarkPreflight) -> Bool {
        guard preflight.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              preflight.requiredDiskBytes
                == MacAcceleratorBenchmarkService.requiredDiskBytes,
              preflight.availableDiskBytes >= 0,
              MacBenchmarkPreflightPolicy.isComparable(preflight) else {
            return false
        }
        guard let batteryPercent = preflight.batteryPercent else { return true }
        return batteryPercent.isFinite && (0...100).contains(batteryPercent)
    }

    func isValid(postflight: BenchmarkPostflight) -> Bool {
        guard postflight.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              postflight.hasCompleteDiskSnapshot,
              let diskReliability = postflight.diskReliability,
              let availableDiskBytes = postflight.availableDiskBytes,
              let requiredDiskBytes = postflight.requiredDiskBytes,
              let warnings = postflight.warnings,
              requiredDiskBytes
                == MacAcceleratorBenchmarkService.requiredDiskBytes,
              availableDiskBytes >= 0 else {
            return false
        }

        let draft = BenchmarkPreflight(
            capturedAt: postflight.capturedAt,
            powerSource: postflight.powerSource,
            batteryPercent: postflight.powerSource == .battery ? 100 : nil,
            lowPowerModeEnabled: postflight.lowPowerModeEnabled,
            thermalState: postflight.thermalState,
            diskReliability: diskReliability,
            availableDiskBytes: availableDiskBytes,
            requiredDiskBytes: requiredDiskBytes,
            warnings: []
        )
        let withoutLowBattery = MacBenchmarkPreflightPolicy.warnings(for: draft)
        guard postflight.powerSource == .battery else {
            return warnings == withoutLowBattery
        }

        let lowBatteryDraft = BenchmarkPreflight(
            capturedAt: draft.capturedAt,
            powerSource: draft.powerSource,
            batteryPercent: nil,
            lowPowerModeEnabled: draft.lowPowerModeEnabled,
            thermalState: draft.thermalState,
            diskReliability: draft.diskReliability,
            availableDiskBytes: draft.availableDiskBytes,
            requiredDiskBytes: draft.requiredDiskBytes,
            warnings: []
        )
        return warnings == withoutLowBattery
            || warnings == MacBenchmarkPreflightPolicy.warnings(for: lowBatteryDraft)
    }

    func isShortNonempty(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == value
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    func withExclusiveFileLock<T>(
        _ operation: (Int32) throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: fileLockTimeout)
        let key = fileURL.path
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

    func acquireProcessLock(
        key: String,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockTimedOut
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

    func withAdvisoryFileLock<T>(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant,
        _ operation: (Int32) throws -> T
    ) async throws -> T {
        let directoryDescriptor = try openStorageDirectory()
        defer { _ = Darwin.close(directoryDescriptor) }

        let fileName = try validatedStorageFileName()
        let lockName = fileName + ".lock"
        guard lockName.utf8.count <= Int(NAME_MAX) else {
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(
                ENAMETOOLONG
            )
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
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(errno)
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
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(EPERM)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(errno)
        }

        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockTimedOut
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                lockAcquired = true
                break
            }
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(code)
            }
            try await waitForLockRetry(clock: clock, deadline: deadline)
        }
        try Task.checkCancellation()
        return try operation(directoryDescriptor)
    }

    func waitForLockRetry(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        try Task.checkCancellation()
        guard clock.now < deadline else {
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockTimedOut
        }
        try await Task.sleep(for: fileLockRetryInterval)
    }

    func openStorageDirectory() throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(errno)
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(code)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            _ = Darwin.close(descriptor)
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(EPERM)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(code)
        }
        return descriptor
    }

    func validatedStorageFileName() throws -> String {
        let fileName = fileURL.lastPathComponent
        guard fileName != ".", fileName != "..", !fileName.isEmpty,
              !fileName.utf8.contains(0),
              fileName.utf8.count <= Int(NAME_MAX) else {
            throw MacAcceleratorBenchmarkHistoryRepositoryError.fileLockFailed(EINVAL)
        }
        return fileName
    }

    func readResults(
        in directoryDescriptor: Int32
    ) -> [MacAcceleratorBenchmarkResult] {
        guard let fileName = try? validatedStorageFileName() else { return [] }
        let descriptor = fileName.withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { return [] }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= Self.maximumFileBytes,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              let data = readData(
                  from: descriptor,
                  byteCount: Int(status.st_size)
              ),
              let results = try? decoder.decode(
                  [MacAcceleratorBenchmarkResult].self,
                  from: data
              ) else {
            return []
        }
        return results
    }

    func readData(from descriptor: Int32, byteCount: Int) -> Data? {
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
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        return succeeded ? data : nil
    }

    func persist(
        _ results: [MacAcceleratorBenchmarkResult],
        in directoryDescriptor: Int32
    ) throws {
        let data: Data
        do {
            data = try encoder.encode(results)
        } catch {
            throw MacAcceleratorBenchmarkHistoryRepositoryError.invalidResult
        }
        guard Int64(data.count) <= Self.maximumFileBytes else {
            throw MacAcceleratorBenchmarkHistoryRepositoryError.invalidResult
        }

        let fileName = try validatedStorageFileName()
        let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
        guard temporaryName.utf8.count <= Int(NAME_MAX) else {
            throw MacAcceleratorBenchmarkHistoryRepositoryError
                .atomicReplacementFailed(ENAMETOOLONG)
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
            throw MacAcceleratorBenchmarkHistoryRepositoryError
                .atomicReplacementFailed(errno)
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
                throw MacAcceleratorBenchmarkHistoryRepositoryError
                    .atomicReplacementFailed(errno)
            }
            guard (temporaryStatus.st_mode & S_IFMT) == S_IFREG,
                  temporaryStatus.st_uid == geteuid(),
                  temporaryStatus.st_nlink == 1 else {
                throw MacAcceleratorBenchmarkHistoryRepositoryError
                    .atomicReplacementFailed(EPERM)
            }
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw MacAcceleratorBenchmarkHistoryRepositoryError
                    .atomicReplacementFailed(errno)
            }
            try write(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw MacAcceleratorBenchmarkHistoryRepositoryError
                    .atomicReplacementFailed(errno)
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
                    throw MacAcceleratorBenchmarkHistoryRepositoryError
                        .atomicReplacementFailed(EPERM)
                }
            } else if errno != ENOENT {
                throw MacAcceleratorBenchmarkHistoryRepositoryError
                    .atomicReplacementFailed(errno)
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
                throw MacAcceleratorBenchmarkHistoryRepositoryError
                    .atomicReplacementFailed(errno)
            }
            shouldRemoveTemporary = false
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw MacAcceleratorBenchmarkHistoryRepositoryError
                    .atomicReplacementFailed(errno)
            }
        } catch let error as MacAcceleratorBenchmarkHistoryRepositoryError {
            throw error
        } catch {
            throw MacAcceleratorBenchmarkHistoryRepositoryError
                .atomicReplacementFailed(EIO)
        }
    }

    func write(_ data: Data, to descriptor: Int32) throws {
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
                if count < 0, errno == EINTR { continue }
                throw MacAcceleratorBenchmarkHistoryRepositoryError
                    .atomicReplacementFailed(count == 0 ? EIO : errno)
            }
        }
    }
}
