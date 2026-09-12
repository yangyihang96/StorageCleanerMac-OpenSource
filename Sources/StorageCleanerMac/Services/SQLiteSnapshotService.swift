import CSQLite
import Darwin
import Foundation

enum SQLiteSnapshotFailure: Error, Equatable, Sendable {
    case busy
    case permissionDenied
    case malformedSchema
    case corrupt
    case sizeLimitExceeded
    case timedOut
    case cancelled
    case unavailable
}

struct SQLiteTableAllowlist: Equatable, Sendable {
    let name: String
    let requiredColumns: Set<String>
    let oneOfColumns: Set<String>

    init(
        name: String,
        requiredColumns: Set<String>,
        oneOfColumns: Set<String> = []
    ) {
        self.name = name
        self.requiredColumns = requiredColumns
        self.oneOfColumns = oneOfColumns
    }
}

struct SQLiteSchemaAllowlist: Equatable, Sendable {
    let requiredTables: [SQLiteTableAllowlist]
    let optionalTables: [SQLiteTableAllowlist]

    init(
        requiredTables: [SQLiteTableAllowlist],
        optionalTables: [SQLiteTableAllowlist] = []
    ) {
        self.requiredTables = requiredTables
        self.optionalTables = optionalTables
    }
}

struct SQLiteSnapshotSource: Equatable, Sendable {
    let databaseURL: URL
    let trustedParentURL: URL
    let allowsImmutableReadFallback: Bool

    init(
        databaseURL: URL,
        trustedParentURL: URL,
        allowsImmutableReadFallback: Bool = false
    ) {
        self.databaseURL = databaseURL
        self.trustedParentURL = trustedParentURL
        self.allowsImmutableReadFallback = allowsImmutableReadFallback
    }
}

struct SQLiteSnapshotDatabase: Sendable {
    let fileURL: URL
    let deadlineNanoseconds: UInt64
    let busyDeadlineNanoseconds: UInt64
    let control: SQLiteExecutionControl
}

struct SQLiteSnapshotService: Sendable {
    static let temporaryDirectoryPrefix = "StorageCleanerPrivacy-"
    static let temporaryContainerName = ".StorageCleanerPrivacySnapshots"
    static let leaseFileName = ".lease"
    static let containerLockFileName = ".container-lock"
    private static let snapshotEntryAllowlist: Set<String> = [
        leaseFileName,
        "History.snapshot.sqlite",
        "History.snapshot.sqlite-journal",
        "History.snapshot.sqlite-wal",
        "History.snapshot.sqlite-shm"
    ]

    private let temporaryRoot: URL
    private let maximumSnapshotBytes: Int64

    init(
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        maximumSnapshotBytes: Int64 = 512 * 1_024 * 1_024
    ) {
        self.temporaryRoot = temporaryRoot.standardizedFileURL
        self.maximumSnapshotBytes = min(
            max(maximumSnapshotBytes, 4 * 1_024),
            2 * 1_024 * 1_024 * 1_024
        )
    }

    /// Deletes only direct, non-symlink directories created by this service.
    /// A bounded pass runs at app launch and at the start of every explicit privacy scan.
    func cleanupOrphans(
        maximumEntries: Int = 128,
        deadlineNanoseconds: UInt64 = .max
    ) {
        let entryLimit = min(max(maximumEntries, 0), 512)
        guard entryLimit > 0,
              let container = try? Self.privateContainer(
                  in: temporaryRoot,
                  createIfMissing: false
              ),
              let enumerator = FileManager.default.enumerator(
                  at: container,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [
                      .skipsSubdirectoryDescendants,
                      .skipsPackageDescendants,
                      .skipsHiddenFiles
                  ]
              ) else {
            return
        }
        guard let containerLock = Self.tryAcquireContainerLock(in: container) else {
            return
        }
        defer {
            flock(containerLock, LOCK_UN)
            Darwin.close(containerLock)
        }

        var inspectedEntries = 0
        while inspectedEntries < entryLimit,
              MonotonicClock.now < deadlineNanoseconds,
              let entry = enumerator.nextObject() as? URL {
            inspectedEntries += 1
            guard Self.isOwnedSnapshotDirectory(entry) else {
                continue
            }
            switch Self.cleanupLease(in: entry) {
            case .unleased:
                _ = Self.removeFlatSnapshotDirectory(
                    entry,
                    deadlineNanoseconds: deadlineNanoseconds
                )
            case let .acquired(leaseDescriptor):
                _ = Self.removeFlatSnapshotDirectory(
                    entry,
                    deadlineNanoseconds: deadlineNanoseconds
                )
                flock(leaseDescriptor, LOCK_UN)
                Darwin.close(leaseDescriptor)
            case .protected:
                continue
            }
        }
    }

    func withSnapshot<T: Sendable>(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        busyRetrySeconds: TimeInterval,
        deadlineNanoseconds: UInt64,
        operation: @escaping @Sendable (SQLiteSnapshotDatabase) throws -> T
    ) async throws -> T {
        let busyNanoseconds = Self.nanoseconds(
            seconds: min(max(busyRetrySeconds, 0), 2)
        )
        let now = MonotonicClock.now
        let busyDeadline = min(
            deadlineNanoseconds,
            now.addingClamped(busyNanoseconds)
        )
        let control = SQLiteExecutionControl(deadlineNanoseconds: deadlineNanoseconds)
        let root = temporaryRoot
        let sizeLimit = maximumSnapshotBytes
        let watchdog = Task.detached(priority: .utility) {
            let current = MonotonicClock.now
            if current < deadlineNanoseconds {
                do {
                    try await Task.sleep(
                        nanoseconds: deadlineNanoseconds - current
                    )
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            control.timeout()
        }
        defer { watchdog.cancel() }

        let worker = Task.detached(priority: .utility) {
            try await withTaskCancellationHandler {
                try Self.performSnapshot(
                    source: source,
                    schema: schema,
                    temporaryRoot: root,
                    maximumSnapshotBytes: sizeLimit,
                    busyDeadlineNanoseconds: busyDeadline,
                    control: control,
                    operation: operation
                )
            } onCancel: {
                control.cancel()
            }
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Creates a caller-owned recovery database. The source is never copied as
    /// a standalone file: both stages use SQLite's online backup API so WAL
    /// content is included in a transactionally consistent database image.
    func createPersistentBackup(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        destinationURL: URL,
        busyRetrySeconds: TimeInterval,
        deadlineNanoseconds: UInt64
    ) async throws {
        let sizeLimit = maximumSnapshotBytes
        try await withSnapshot(
            source: source,
            schema: schema,
            busyRetrySeconds: busyRetrySeconds,
            deadlineNanoseconds: deadlineNanoseconds
        ) { snapshot in
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw SQLiteSnapshotFailure.unavailable
            }
            try Self.createPrivateFile(at: destinationURL)
            do {
                try SQLiteRuntime.withReadOnlyDatabase(
                    at: snapshot.fileURL,
                    control: snapshot.control,
                    busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds
                ) { sourceDatabase in
                    let sourcePageSize = try SQLiteRuntime.requireDatabaseSize(
                        database: sourceDatabase,
                        maximumBytes: sizeLimit,
                        control: snapshot.control,
                        busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds
                    )
                    try SQLiteRuntime.withWritableDatabase(
                        at: destinationURL,
                        control: snapshot.control,
                        busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds
                    ) { targetDatabase in
                        try SQLiteRuntime.backup(
                            from: sourceDatabase,
                            to: targetDatabase,
                            control: snapshot.control,
                            busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds,
                            maximumBytes: sizeLimit,
                            sourcePageSize: sourcePageSize
                        )
                        try SQLiteRuntime.validate(
                            schema: schema,
                            database: targetDatabase,
                            control: snapshot.control,
                            busyDeadlineNanoseconds: snapshot.busyDeadlineNanoseconds
                        )
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        }
    }

    func restorePersistentBackup(
        backupURL: URL,
        destination: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        busyRetrySeconds: TimeInterval,
        deadlineNanoseconds: UInt64
    ) async throws {
        let busyDeadline = min(
            deadlineNanoseconds,
            MonotonicClock.now.addingClamped(Self.nanoseconds(
                seconds: min(max(busyRetrySeconds, 0), 2)
            ))
        )
        let control = SQLiteExecutionControl(deadlineNanoseconds: deadlineNanoseconds)
        let sizeLimit = maximumSnapshotBytes
        let worker = Task.detached(priority: .utility) {
            try await withTaskCancellationHandler {
                let destinationIdentity = try SecureSourceFile.identityChain(
                    for: destination.databaseURL,
                    trustedParent: destination.trustedParentURL,
                    expectedFinalKind: .regularFile
                )
                let canonicalDestination = try SecureSourceFile.canonicalizedURL(
                    for: destination.databaseURL,
                    trustedParent: destination.trustedParentURL,
                    expectedIdentityChain: destinationIdentity
                )
                let backupParent = backupURL.deletingLastPathComponent()
                let backupIdentity = try SecureSourceFile.identityChain(
                    for: backupURL,
                    trustedParent: backupParent,
                    expectedFinalKind: .regularFile
                )
                let canonicalBackup = try SecureSourceFile.canonicalizedURL(
                    for: backupURL,
                    trustedParent: backupParent,
                    expectedIdentityChain: backupIdentity
                )
                try SQLiteRuntime.withReadOnlyDatabase(
                    at: canonicalBackup,
                    control: control,
                    busyDeadlineNanoseconds: busyDeadline,
                    forbidSymbolicLinks: true
                ) { backupDatabase in
                    try SQLiteRuntime.validate(
                        schema: schema,
                        database: backupDatabase,
                        control: control,
                        busyDeadlineNanoseconds: busyDeadline
                    )
                    let sourcePageSize = try SQLiteRuntime.requireDatabaseSize(
                        database: backupDatabase,
                        maximumBytes: sizeLimit,
                        control: control,
                        busyDeadlineNanoseconds: busyDeadline
                    )
                    try SQLiteRuntime.withWritableDatabase(
                        at: canonicalDestination,
                        control: control,
                        busyDeadlineNanoseconds: busyDeadline,
                        forbidSymbolicLinks: true
                    ) { targetDatabase in
                        try SQLiteRuntime.backup(
                            from: backupDatabase,
                            to: targetDatabase,
                            control: control,
                            busyDeadlineNanoseconds: busyDeadline,
                            maximumBytes: sizeLimit,
                            sourcePageSize: sourcePageSize
                        )
                        try SQLiteRuntime.validate(
                            schema: schema,
                            database: targetDatabase,
                            control: control,
                            busyDeadlineNanoseconds: busyDeadline
                        )
                    }
                }
                guard try SecureSourceFile.identityChain(
                    for: destination.databaseURL,
                    trustedParent: destination.trustedParentURL,
                    expectedFinalKind: .regularFile
                ) == destinationIdentity else {
                    throw SQLiteSnapshotFailure.unavailable
                }
            } onCancel: {
                control.cancel()
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func performSnapshot<T: Sendable>(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        temporaryRoot: URL,
        maximumSnapshotBytes: Int64,
        busyDeadlineNanoseconds: UInt64,
        control: SQLiteExecutionControl,
        operation: @Sendable (SQLiteSnapshotDatabase) throws -> T
    ) throws -> T {
        try control.check()
        let sourceIdentity = try SecureSourceFile.identityChain(
            for: source.databaseURL,
            trustedParent: source.trustedParentURL,
            expectedFinalKind: .regularFile
        )
        let canonicalSourceURL = try SecureSourceFile.canonicalizedURL(
            for: source.databaseURL,
            trustedParent: source.trustedParentURL,
            expectedIdentityChain: sourceIdentity
        )
        guard try SecureSourceFile.regularFileSize(at: source.databaseURL)
            <= maximumSnapshotBytes else {
            throw SQLiteSnapshotFailure.sizeLimitExceeded
        }
        let container = try privateContainer(in: temporaryRoot, createIfMissing: true)
        let (directory, leaseDescriptor) = try createLeasedSnapshotDirectory(
            in: container,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer {
            _ = Self.removeFlatSnapshotDirectory(directory)
            flock(leaseDescriptor, LOCK_UN)
            Darwin.close(leaseDescriptor)
        }

        let snapshotURL = directory.appendingPathComponent("History.snapshot.sqlite")
        try createPrivateFile(at: snapshotURL)

        try SQLiteRuntime.withReadOnlyDatabase(
            at: canonicalSourceURL,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds,
            forbidSymbolicLinks: true,
            immutableFallbackOnBusy: source.allowsImmutableReadFallback
        ) { sourceDatabase in
            let identityAfterOpen = try SecureSourceFile.identityChain(
                for: source.databaseURL,
                trustedParent: source.trustedParentURL,
                expectedFinalKind: .regularFile
            )
            guard sourceIdentity == identityAfterOpen else {
                throw SQLiteSnapshotFailure.unavailable
            }
            try SQLiteRuntime.requireUnmoved(database: sourceDatabase)
            try SQLiteRuntime.validate(
                schema: schema,
                database: sourceDatabase,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds
            )
            let sourcePageSize = try SQLiteRuntime.requireDatabaseSize(
                database: sourceDatabase,
                maximumBytes: maximumSnapshotBytes,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds
            )

            try SQLiteRuntime.withWritableDatabase(
                at: snapshotURL,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds
            ) { targetDatabase in
                try SQLiteRuntime.backup(
                    from: sourceDatabase,
                    to: targetDatabase,
                    control: control,
                    busyDeadlineNanoseconds: busyDeadlineNanoseconds,
                    maximumBytes: maximumSnapshotBytes,
                    sourcePageSize: sourcePageSize
                )
                try SQLiteRuntime.validate(
                    schema: schema,
                    database: targetDatabase,
                    control: control,
                    busyDeadlineNanoseconds: busyDeadlineNanoseconds
                )
                _ = try SQLiteRuntime.requireDatabaseSize(
                    database: targetDatabase,
                    maximumBytes: maximumSnapshotBytes,
                    control: control,
                    busyDeadlineNanoseconds: busyDeadlineNanoseconds
                )
            }
            let identityAfterBackup = try SecureSourceFile.identityChain(
                for: source.databaseURL,
                trustedParent: source.trustedParentURL,
                expectedFinalKind: .regularFile
            )
            guard sourceIdentity == identityAfterBackup else {
                throw SQLiteSnapshotFailure.unavailable
            }
            try SQLiteRuntime.requireUnmoved(database: sourceDatabase)
        }

        try control.check()
        let value = try operation(
            SQLiteSnapshotDatabase(
                fileURL: snapshotURL,
                deadlineNanoseconds: control.deadlineNanoseconds,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds,
                control: control
            )
        )
        try control.check()
        return value
    }

    private static func createPrivateTemporaryDirectory(in root: URL) throws -> URL {
        var rootMetadata = stat()
        guard lstat(root.path, &rootMetadata) == 0,
              (rootMetadata.st_mode & S_IFMT) == S_IFDIR,
              (rootMetadata.st_mode & S_IFMT) != S_IFLNK else {
            throw SQLiteSnapshotFailure.unavailable
        }

        for _ in 0..<8 {
            let candidate = root.appendingPathComponent(
                Self.temporaryDirectoryPrefix + UUID().uuidString
            )
            if Darwin.mkdir(candidate.path, S_IRWXU) == 0 {
                let descriptor = Darwin.open(
                    candidate.path,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    _ = Darwin.rmdir(candidate.path)
                    throw SecureSourceFile.failure(forErrno: errno)
                }
                var metadata = stat()
                let isPrivateOwnedDirectory = fchmod(descriptor, S_IRWXU) == 0
                    && fstat(descriptor, &metadata) == 0
                    && (metadata.st_mode & S_IFMT) == S_IFDIR
                    && metadata.st_uid == geteuid()
                    && (metadata.st_mode & 0o777) == S_IRWXU
                Darwin.close(descriptor)
                guard isPrivateOwnedDirectory else {
                    _ = Darwin.rmdir(candidate.path)
                    throw SQLiteSnapshotFailure.permissionDenied
                }
                return candidate
            }
            if errno != EEXIST {
                throw SecureSourceFile.failure(forErrno: errno)
            }
        }
        throw SQLiteSnapshotFailure.unavailable
    }

    private static func privateContainer(
        in root: URL,
        createIfMissing: Bool
    ) throws -> URL {
        var rootMetadata = stat()
        guard lstat(root.path, &rootMetadata) == 0,
              (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw SQLiteSnapshotFailure.unavailable
        }

        let container = root.appendingPathComponent(Self.temporaryContainerName)
        var metadata = stat()
        if lstat(container.path, &metadata) != 0 {
            guard errno == ENOENT, createIfMissing else {
                throw SQLiteSnapshotFailure.unavailable
            }
            let created = Darwin.mkdir(container.path, S_IRWXU) == 0
            if !created, errno != EEXIST {
                throw SecureSourceFile.failure(forErrno: errno)
            }
            if created {
                let descriptor = Darwin.open(
                    container.path,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw SecureSourceFile.failure(forErrno: errno)
                }
                defer { Darwin.close(descriptor) }
                guard fchmod(descriptor, S_IRWXU) == 0,
                      fstat(descriptor, &metadata) == 0 else {
                    throw SQLiteSnapshotFailure.permissionDenied
                }
            } else if lstat(container.path, &metadata) != 0 {
                throw SecureSourceFile.failure(forErrno: errno)
            }
        }

        let validationDescriptor = Darwin.open(
            container.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard validationDescriptor >= 0 else {
            throw SecureSourceFile.failure(forErrno: errno)
        }
        defer { Darwin.close(validationDescriptor) }
        guard fstat(validationDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o777) == S_IRWXU else {
            throw SQLiteSnapshotFailure.unavailable
        }
        return container
    }

    private static func isOwnedSnapshotDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(Self.temporaryDirectoryPrefix) else {
            return false
        }
        let suffix = String(name.dropFirst(Self.temporaryDirectoryPrefix.count))
        guard suffix.count == 36, UUID(uuidString: suffix) != nil else {
            return false
        }

        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && (metadata.st_mode & S_IFMT) == S_IFDIR
            && metadata.st_uid == geteuid()
            && (metadata.st_mode & 0o777) == S_IRWXU
    }

    /// Snapshot directories are intentionally flat. Refuse recursive deletion so a
    /// corrupted or attacker-populated orphan cannot turn startup cleanup into an
    /// unbounded filesystem walk.
    @discardableResult
    private static func removeFlatSnapshotDirectory(
        _ directory: URL,
        deadlineNanoseconds: UInt64 = .max
    ) -> Bool {
        guard MonotonicClock.now < deadlineNanoseconds else { return false }
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var directoryMetadata = stat()
        guard fstat(descriptor, &directoryMetadata) == 0,
              (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              directoryMetadata.st_uid == geteuid(),
              (directoryMetadata.st_mode & 0o777) == S_IRWXU else {
            return false
        }

        let enumerationDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard enumerationDescriptor >= 0,
              let stream = fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 {
                Darwin.close(enumerationDescriptor)
            }
            return false
        }
        defer { closedir(stream) }

        var entries: [String] = []
        entries.reserveCapacity(snapshotEntryAllowlist.count)
        while let entry = readdir(stream) {
            guard MonotonicClock.now < deadlineNanoseconds else { return false }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
            if name == "." || name == ".." {
                continue
            }
            guard snapshotEntryAllowlist.contains(name),
                  entries.count < snapshotEntryAllowlist.count else {
                return false
            }
            var metadata = stat()
            guard fstatat(
                descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_uid == geteuid(),
            (metadata.st_mode & 0o077) == 0 else {
                return false
            }
            entries.append(name)
        }

        for name in entries {
            guard MonotonicClock.now < deadlineNanoseconds,
                  unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else {
                return false
            }
        }
        guard MonotonicClock.now < deadlineNanoseconds else { return false }
        return Darwin.rmdir(directory.path) == 0 || errno == ENOENT
    }

    private static func acquireNewLease(in directory: URL) throws -> Int32 {
        let leaseURL = directory.appendingPathComponent(Self.leaseFileName)
        let descriptor = Darwin.open(
            leaseURL.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SecureSourceFile.failure(forErrno: errno)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SecureSourceFile.failure(forErrno: code)
        }
        return descriptor
    }

    private enum CleanupLease {
        case unleased
        case acquired(Int32)
        case protected
    }

    private static func cleanupLease(in directory: URL) -> CleanupLease {
        let leaseURL = directory.appendingPathComponent(Self.leaseFileName)
        let descriptor = Darwin.open(
            leaseURL.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return errno == ENOENT ? .unleased : .protected
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o777) == (S_IRUSR | S_IWUSR),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return .protected
        }
        return .acquired(descriptor)
    }

    private static func createLeasedSnapshotDirectory(
        in container: URL,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> (URL, Int32) {
        let containerLock = try acquireContainerLock(
            in: container,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer {
            flock(containerLock, LOCK_UN)
            Darwin.close(containerLock)
        }

        let directory = try createPrivateTemporaryDirectory(in: container)
        do {
            return (directory, try acquireNewLease(in: directory))
        } catch {
            _ = removeFlatSnapshotDirectory(directory)
            throw error
        }
    }

    private static func acquireContainerLock(
        in container: URL,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Int32 {
        while true {
            try control.check()
            guard let descriptor = openContainerLockFile(in: container) else {
                throw SQLiteSnapshotFailure.unavailable
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return descriptor
            }
            Darwin.close(descriptor)
            try SQLiteRuntime.waitForBusyRetry(
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds
            )
        }
    }

    private static func tryAcquireContainerLock(in container: URL) -> Int32? {
        guard let descriptor = openContainerLockFile(in: container) else {
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func openContainerLockFile(in container: URL) -> Int32? {
        let url = container.appendingPathComponent(Self.containerLockFileName)
        var descriptor = Darwin.open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        let created = descriptor >= 0
        if descriptor < 0, errno == EEXIST {
            descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        if created, fchmod(descriptor, S_IRUSR | S_IWUSR) != 0 {
            Darwin.close(descriptor)
            return nil
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func createPrivateFile(at url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SecureSourceFile.failure(forErrno: errno)
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw SQLiteSnapshotFailure.permissionDenied
        }
    }

    private static func nanoseconds(seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    }
}

/// Synchronous cancellation bridge for SQLite's C callbacks and sqlite3_interrupt().
/// Access to every registered handle is serialized so a handle cannot be closed
/// concurrently with an interrupt call.
final class SQLiteExecutionControl: @unchecked Sendable {
    let deadlineNanoseconds: UInt64

    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false
    private var handles: [OpaquePointer] = []

    init(deadlineNanoseconds: UInt64) {
        self.deadlineNanoseconds = deadlineNanoseconds
    }

    func register(_ handle: OpaquePointer) {
        lock.lock()
        handles.append(handle)
        let shouldInterrupt = cancelled
            || timedOut
            || MonotonicClock.now >= deadlineNanoseconds
        if shouldInterrupt {
            sqlite3_interrupt(handle)
        }
        lock.unlock()
    }

    func unregister(_ handle: OpaquePointer) {
        lock.lock()
        handles.removeAll { $0 == handle }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        for handle in handles {
            sqlite3_interrupt(handle)
        }
        lock.unlock()
    }

    func timeout() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        timedOut = true
        for handle in handles {
            sqlite3_interrupt(handle)
        }
        lock.unlock()
    }

    func failureIfAborted() -> SQLiteSnapshotFailure? {
        lock.lock()
        let wasCancelled = cancelled
        let didTimeOut = timedOut
        lock.unlock()
        if wasCancelled || Task.isCancelled {
            return .cancelled
        }
        if didTimeOut || MonotonicClock.now >= deadlineNanoseconds {
            return .timedOut
        }
        return nil
    }

    func check() throws {
        if let failure = failureIfAborted() {
            throw failure
        }
    }
}

enum SQLiteRuntime {
    static func requireUnmoved(database: OpaquePointer) throws {
        var hasMoved: Int32 = 0
        let result = sqlite3_file_control(
            database,
            "main",
            SQLITE_FCNTL_HAS_MOVED,
            &hasMoved
        )
        guard result == SQLITE_OK, hasMoved == 0 else {
            throw SQLiteSnapshotFailure.unavailable
        }
    }

    static func requireDatabaseSize(
        database: OpaquePointer,
        maximumBytes: Int64,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Int64 {
        let pageSize = try pragmaInteger(
            "PRAGMA page_size",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        let pageCount = try pragmaInteger(
            "PRAGMA page_count",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        guard pageSize >= 512, pageSize <= 65_536, pageCount >= 0 else {
            throw SQLiteSnapshotFailure.corrupt
        }
        let (databaseBytes, overflow) = pageSize.multipliedReportingOverflow(by: pageCount)
        guard !overflow, databaseBytes <= maximumBytes else {
            throw SQLiteSnapshotFailure.sizeLimitExceeded
        }
        return pageSize
    }

    static func withReadOnlyDatabase<T>(
        at url: URL,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64,
        forbidSymbolicLinks: Bool = false,
        immutableFallbackOnBusy: Bool = false,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        let flags = SQLITE_OPEN_READONLY
            | SQLITE_OPEN_FULLMUTEX
            | (forbidSymbolicLinks ? SQLITE_OPEN_NOFOLLOW : 0)
        do {
            return try withDatabase(
                at: url,
                flags: flags,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds,
                operation: operation
            )
        } catch SQLiteSnapshotFailure.busy where immutableFallbackOnBusy {
            let sourceStamp = try SecureSourceFile.contentStamp(at: url)
            guard try SecureSourceFile.allowsImmutableSQLiteRead(at: url) else {
                throw SQLiteSnapshotFailure.busy
            }
            let value = try withDatabase(
                at: url,
                flags: flags | SQLITE_OPEN_URI,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds,
                immutable: true,
                operation: operation
            )
            guard sourceStamp == (try SecureSourceFile.contentStamp(at: url)),
                  try SecureSourceFile.allowsImmutableSQLiteRead(at: url) else {
                throw SQLiteSnapshotFailure.busy
            }
            return value
        }
    }

    static func withWritableDatabase<T>(
        at url: URL,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64,
        forbidSymbolicLinks: Bool = false,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        try withDatabase(
            at: url,
            flags: SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_FULLMUTEX
                | (forbidSymbolicLinks ? SQLITE_OPEN_NOFOLLOW : 0),
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds,
            operation: operation
        )
    }

    static func validate(
        schema: SQLiteSchemaAllowlist,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws {
        guard schema.requiredTables.allSatisfy(validTableAllowlist),
              schema.optionalTables.allSatisfy(validTableAllowlist) else {
            throw SQLiteSnapshotFailure.malformedSchema
        }

        for table in schema.requiredTables {
            guard try tableExists(
                table.name,
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds
            ) else {
                throw SQLiteSnapshotFailure.malformedSchema
            }
            try validateColumns(
                table,
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds
            )
        }

        for table in schema.optionalTables where try tableExists(
            table.name,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) {
            try validateColumns(
                table,
                database: database,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds
            )
        }
    }

    static func tableExists(
        _ name: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Bool {
        guard validIdentifier(name) else {
            throw SQLiteSnapshotFailure.malformedSchema
        }
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, name, -1, sqliteTransient) == SQLITE_OK else {
            throw SQLiteSnapshotFailure.malformedSchema
        }
        let result = try step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        return result == SQLITE_ROW
    }

    static func tableColumns(
        _ name: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Set<String> {
        guard validIdentifier(name) else {
            throw SQLiteSnapshotFailure.malformedSchema
        }
        let statement = try prepare(
            "PRAGMA table_info(\"\(name)\")",
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while true {
            let result = try step(
                statement,
                control: control,
                busyDeadlineNanoseconds: busyDeadlineNanoseconds
            )
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 1) else {
                throw SQLiteSnapshotFailure.malformedSchema
            }
            let column = String(cString: text)
            guard validIdentifier(column) else {
                throw SQLiteSnapshotFailure.malformedSchema
            }
            columns.insert(column)
        }
        return columns
    }

    static func prepare(
        _ sql: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> OpaquePointer {
        while true {
            try control.check()
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            if result == SQLITE_OK, let statement {
                return statement
            }
            if let statement {
                sqlite3_finalize(statement)
            }
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                try waitForBusyRetry(
                    control: control,
                    busyDeadlineNanoseconds: busyDeadlineNanoseconds
                )
                continue
            }
            throw mappedFailure(result, control: control, schemaContext: true)
        }
    }

    static func step(
        _ statement: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Int32 {
        while true {
            try control.check()
            let result = sqlite3_step(statement)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                try waitForBusyRetry(
                    control: control,
                    busyDeadlineNanoseconds: busyDeadlineNanoseconds
                )
                continue
            }
            guard result == SQLITE_ROW || result == SQLITE_DONE else {
                throw mappedFailure(result, control: control, schemaContext: false)
            }
            return result
        }
    }

    static func backup(
        from source: OpaquePointer,
        to target: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64,
        maximumBytes: Int64,
        sourcePageSize: Int64
    ) throws {
        var initializedBackup: OpaquePointer?
        while initializedBackup == nil {
            try control.check()
            initializedBackup = sqlite3_backup_init(target, "main", source, "main")
            guard initializedBackup == nil else { break }
            let code = sqlite3_errcode(target)
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                try waitForBusyRetry(
                    control: control,
                    busyDeadlineNanoseconds: busyDeadlineNanoseconds
                )
                continue
            }
            throw mappedFailure(code, control: control, schemaContext: false)
        }
        guard let backup = initializedBackup else {
            throw SQLiteSnapshotFailure.unavailable
        }
        var completed = false
        defer {
            if !completed {
                sqlite3_backup_finish(backup)
            }
        }

        while true {
            try control.check()
            let result = sqlite3_backup_step(backup, 16)
            let pageCount = Int64(sqlite3_backup_pagecount(backup))
            if pageCount > 0 {
                let (snapshotBytes, overflow) = sourcePageSize
                    .multipliedReportingOverflow(by: pageCount)
                guard !overflow, snapshotBytes <= maximumBytes else {
                    throw SQLiteSnapshotFailure.sizeLimitExceeded
                }
            }
            switch result {
            case SQLITE_DONE:
                let finishResult = sqlite3_backup_finish(backup)
                completed = true
                guard finishResult == SQLITE_OK else {
                    throw mappedFailure(finishResult, control: control, schemaContext: false)
                }
                return
            case SQLITE_OK:
                continue
            case SQLITE_BUSY, SQLITE_LOCKED:
                try waitForBusyRetry(
                    control: control,
                    busyDeadlineNanoseconds: busyDeadlineNanoseconds
                )
            default:
                throw mappedFailure(result, control: control, schemaContext: false)
            }
        }
    }

    private static func withDatabase<T>(
        at url: URL,
        flags: Int32,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64,
        immutable: Bool = false,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        try control.check()
        var database: OpaquePointer?
        let path = immutable ? "\(url.standardizedFileURL.absoluteString)?immutable=1" : url.path
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw mappedFailure(result, control: control, schemaContext: false)
        }

        control.register(database)
        sqlite3_busy_timeout(database, 0)
        sqlite3_progress_handler(
            database,
            256,
            { context in
                guard let context else { return 1 }
                let control = Unmanaged<SQLiteExecutionControl>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return control.failureIfAborted() == nil ? 0 : 1
            },
            Unmanaged.passUnretained(control).toOpaque()
        )
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            control.unregister(database)
            sqlite3_close_v2(database)
        }
        let configurationResult = sqlite3_exec(
            database,
            "PRAGMA temp_store=MEMORY; PRAGMA automatic_index=OFF;",
            nil,
            nil,
            nil
        )
        guard configurationResult == SQLITE_OK else {
            throw mappedFailure(
                configurationResult,
                control: control,
                schemaContext: false
            )
        }
        return try operation(database)
    }

    private static func validateColumns(
        _ table: SQLiteTableAllowlist,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws {
        let columns = try tableColumns(
            table.name,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        guard table.requiredColumns.isSubset(of: columns),
              table.oneOfColumns.isEmpty || !table.oneOfColumns.isDisjoint(with: columns) else {
            throw SQLiteSnapshotFailure.malformedSchema
        }
    }

    private static func validTableAllowlist(_ table: SQLiteTableAllowlist) -> Bool {
        validIdentifier(table.name)
            && table.requiredColumns.allSatisfy(validIdentifier)
            && table.oneOfColumns.allSatisfy(validIdentifier)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 95
        }
    }

    static func waitForBusyRetry(
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws {
        try control.check()
        let current = MonotonicClock.now
        guard current < busyDeadlineNanoseconds else {
            throw SQLiteSnapshotFailure.busy
        }
        let remainingNanoseconds = busyDeadlineNanoseconds - current
        let sleepMicroseconds = useconds_t(
            min(max(remainingNanoseconds / 1_000, 1), 5_000)
        )
        usleep(sleepMicroseconds)
        try control.check()
        guard MonotonicClock.now < busyDeadlineNanoseconds else {
            throw SQLiteSnapshotFailure.busy
        }
    }

    private static func pragmaInteger(
        _ sql: String,
        database: OpaquePointer,
        control: SQLiteExecutionControl,
        busyDeadlineNanoseconds: UInt64
    ) throws -> Int64 {
        let statement = try prepare(
            sql,
            database: database,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        )
        defer { sqlite3_finalize(statement) }
        guard try step(
            statement,
            control: control,
            busyDeadlineNanoseconds: busyDeadlineNanoseconds
        ) == SQLITE_ROW else {
            throw SQLiteSnapshotFailure.corrupt
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func mappedFailure(
        _ result: Int32,
        control: SQLiteExecutionControl,
        schemaContext: Bool
    ) -> SQLiteSnapshotFailure {
        if let failure = control.failureIfAborted() {
            return failure
        }
        switch result {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return .busy
        case SQLITE_PERM, SQLITE_AUTH, SQLITE_READONLY:
            return .permissionDenied
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corrupt
        case SQLITE_INTERRUPT:
            return .cancelled
        case SQLITE_SCHEMA where schemaContext:
            return .malformedSchema
        case SQLITE_ERROR where schemaContext:
            return .malformedSchema
        default:
            return .unavailable
        }
    }
}

enum SecureSourceFile {
    enum ExpectedKind {
        case directory
        case regularFile
    }

    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let kind: mode_t
    }

    struct ContentStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    static func identityChain(
        for source: URL,
        trustedParent: URL,
        expectedFinalKind: ExpectedKind
    ) throws -> [Identity] {
        let anchor = trustedParent.standardizedFileURL
        let candidate = source.standardizedFileURL
        guard candidate.path != anchor.path,
              candidate.path.hasPrefix(anchor.path == "/" ? "/" : anchor.path + "/") else {
            throw SQLiteSnapshotFailure.unavailable
        }

        let suffix = candidate.path.dropFirst(anchor.path.count)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            throw SQLiteSnapshotFailure.unavailable
        }

        var current = anchor
        var result = [try identity(at: current, expectedKind: .directory)]
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            let expected: ExpectedKind = index == components.count - 1
                ? expectedFinalKind
                : .directory
            result.append(try identity(at: current, expectedKind: expected))
        }
        return result
    }

    static func regularFileSize(at source: URL) throws -> Int64 {
        var metadata = stat()
        guard lstat(source.path, &metadata) == 0 else {
            throw failure(forErrno: errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            throw SQLiteSnapshotFailure.unavailable
        }
        return Int64(metadata.st_size)
    }

    static func contentStamp(at source: URL) throws -> ContentStamp {
        var metadata = stat()
        guard lstat(source.path, &metadata) == 0 else {
            throw failure(forErrno: errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_size >= 0 else {
            throw SQLiteSnapshotFailure.unavailable
        }
        return ContentStamp(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    /// Immutable SQLite reads are safe only when the main file stays stable
    /// and no WAL or hot rollback journal needs to be replayed.
    static func allowsImmutableSQLiteRead(at databaseURL: URL) throws -> Bool {
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            var metadata = stat()
            if lstat(sidecar.path, &metadata) == 0 {
                guard (metadata.st_mode & S_IFMT) == S_IFREG else { return false }
                if metadata.st_size > 0 { return false }
            } else if errno != ENOENT {
                throw failure(forErrno: errno)
            }
        }

        let journal = URL(fileURLWithPath: databaseURL.path + "-journal")
        var metadata = stat()
        guard lstat(journal.path, &metadata) == 0 else {
            if errno == ENOENT { return true }
            throw failure(forErrno: errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { return false }
        if metadata.st_size <= 512 { return true }

        let descriptor = Darwin.open(journal.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(forErrno: errno) }
        defer { Darwin.close(descriptor) }
        var header = [UInt8](repeating: 0, count: 8)
        let count = header.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        guard count == header.count else { return false }
        return header.allSatisfy { $0 == 0 }
    }

    static func canonicalizedURL(
        for source: URL,
        trustedParent: URL,
        expectedIdentityChain: [Identity]
    ) throws -> URL {
        let anchor = trustedParent.standardizedFileURL
        let candidate = source.standardizedFileURL
        guard candidate.path != anchor.path,
              candidate.path.hasPrefix(anchor.path == "/" ? "/" : anchor.path + "/"),
              let resolvedAnchorPointer = Darwin.realpath(anchor.path, nil) else {
            throw SQLiteSnapshotFailure.unavailable
        }
        defer { Darwin.free(resolvedAnchorPointer) }

        let resolvedAnchor = URL(
            fileURLWithPath: String(cString: resolvedAnchorPointer),
            isDirectory: true
        )
        let suffix = candidate.path.dropFirst(anchor.path.count)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            throw SQLiteSnapshotFailure.unavailable
        }
        var resolvedCandidate = resolvedAnchor
        for component in components {
            resolvedCandidate.appendPathComponent(String(component))
        }
        let resolvedIdentities = try identityChain(
            for: resolvedCandidate,
            trustedParent: resolvedAnchor,
            expectedFinalKind: .regularFile
        )
        guard resolvedIdentities == expectedIdentityChain else {
            throw SQLiteSnapshotFailure.unavailable
        }
        return resolvedCandidate
    }

    static func readBoundedData(
        at source: URL,
        trustedParent: URL,
        maximumBytes: Int,
        control: SQLiteExecutionControl
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw SQLiteSnapshotFailure.unavailable
        }
        try control.check()
        let before = try identityChain(
            for: source,
            trustedParent: trustedParent,
            expectedFinalKind: .regularFile
        )
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw failure(forErrno: errno)
        }
        defer { Darwin.close(descriptor) }

        var openMetadata = stat()
        guard fstat(descriptor, &openMetadata) == 0 else {
            throw failure(forErrno: errno)
        }
        let openIdentity = identity(from: openMetadata)
        guard openIdentity == before.last else {
            throw SQLiteSnapshotFailure.unavailable
        }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maximumBytes {
            try control.check()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw failure(forErrno: errno)
            }
            data.append(buffer, count: count)
            if data.count > maximumBytes {
                throw SQLiteSnapshotFailure.unavailable
            }
        }
        let after = try identityChain(
            for: source,
            trustedParent: trustedParent,
            expectedFinalKind: .regularFile
        )
        guard before == after else {
            throw SQLiteSnapshotFailure.unavailable
        }
        try control.check()
        return data
    }

    static func failure(forErrno code: Int32) -> SQLiteSnapshotFailure {
        switch code {
        case EACCES, EPERM:
            return .permissionDenied
        default:
            return .unavailable
        }
    }

    private static func identity(
        at url: URL,
        expectedKind: ExpectedKind
    ) throws -> Identity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw failure(forErrno: errno)
        }
        let kind = metadata.st_mode & S_IFMT
        guard kind != S_IFLNK else {
            throw SQLiteSnapshotFailure.unavailable
        }
        switch expectedKind {
        case .directory:
            guard kind == S_IFDIR else { throw SQLiteSnapshotFailure.unavailable }
        case .regularFile:
            guard kind == S_IFREG else { throw SQLiteSnapshotFailure.unavailable }
        }
        return identity(from: metadata)
    }

    private static func identity(from metadata: stat) -> Identity {
        Identity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            kind: metadata.st_mode & S_IFMT
        )
    }
}

enum MonotonicClock {
    static var now: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let (value, overflow) = addingReportingOverflow(other)
        return overflow ? .max : value
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
