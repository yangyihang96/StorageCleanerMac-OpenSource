import Darwin
import Foundation

/// D61: copyfile owns data forks, resource forks, ACLs, compression and metadata.
/// An abandoned worker owns its private output until the syscall returns; it
/// can only clean up, never publish. The caller alone can publish a success.
struct GuardedFileCopy: Sendable {
    let reader: GuardedFileContentReader
    var supportsACL: @Sendable (URL) throws -> Bool = { destination in
        try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeSupportsExtendedSecurityKey])
            .volumeSupportsExtendedSecurity ?? true
    }
    var allowsCloning = true
    var durability = MigrationDurability()
    var creationTime = MigrationCreationTime()
    var progressObserver: @Sendable (Int32, Int32) -> Void = { _, _ in }
    // The injected operation exercises errors reported through the real C
    // callback, including errno changes made by copyfile after it returns.
    var copyfileOperation: @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>, copyfile_state_t, copyfile_flags_t) -> Int32 = {
        Darwin.copyfile($0, $1, $2, $3)
    }

    struct Timestamp: Equatable, Sendable {
        let seconds: Int
        let nanoseconds: Int
        init(_ value: timespec) { seconds = value.tv_sec; nanoseconds = value.tv_nsec }
        var value: timespec { timespec(tv_sec: seconds, tv_nsec: nanoseconds) }
    }

    struct Entry: Sendable {
        let relativePath: String
        let device: Int32
        let inode: UInt64
        let kind: mode_t
        let size: Int64
        let modified: Timestamp
        let changed: Timestamp
        let accessed: Timestamp
        let created: Timestamp
    }

    struct PreparedCopy: Sendable {
        let entries: [Entry]
        let deferredFlags: UInt32
        var deferredRootMode: mode_t? = nil
        // Birth-time limitations are informational; they never gate a proof.
        var metadataWarnings: [String] = []
        var durabilityCapability: MigrationDurability.Capability? = nil

        /// Verification reads may update atime. Restore the captured times on
        /// our owned copy only, before publishing it; never write the source.
        func restoreTimes(at root: URL, creationTime: MigrationCreationTime = .init(), progress: () throws -> Void) throws -> [String] {
            var warnings: [String] = []
            let quantum = creationTime.precision(root)
            for entry in entries.reversed() {
                try progress()
                let url = entry.relativePath.isEmpty ? root : root.appendingPathComponent(entry.relativePath)
                var status = stat()
                guard url.path.withCString({ lstat($0, &status) }) == 0 else { throw GuardedFileCopy.posixError() }
                let flags = status.st_flags
                let blocked = flags & GuardedFileCopy.renameBlockingFlags
                if blocked != 0 {
                    guard url.path.withCString({ lchflags($0, flags & ~GuardedFileCopy.renameBlockingFlags) }) == 0 else {
                        throw GuardedFileCopy.posixError()
                    }
                }
                let times = [entry.accessed.value, entry.modified.value]
                let result = url.path.withCString { path in
                    times.withUnsafeBufferPointer { utimensat(AT_FDCWD, path, $0.baseAddress, AT_SYMLINK_NOFOLLOW) }
                }
                let timeError = result != 0 && errno != ENOTSUP ? GuardedFileCopy.posixError() : nil
                // copyfile can replace birth time with mtime across volumes.
                // This public API writes the link itself, never its referent.
                var creationResult = creationTime.write(url, entry.created)
                var creationCode = errno
                if creationResult != 0, [EACCES, EPERM].contains(creationCode), status.st_uid == geteuid(),
                   status.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK),
                   status.st_mode & mode_t(S_IWUSR) == 0,
                   status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) || status.st_nlink == 1 {
                    // Some filesystems require data-write permission even for
                    // birth-time attributes. Relax only this owned target inode
                    // and restore its exact mode before restoring locked flags.
                    let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
                    if descriptor >= 0 {
                        defer { close(descriptor) }
                        var owned = stat()
                        guard fstat(descriptor, &owned) == 0, owned.st_uid == geteuid(),
                              owned.st_dev == status.st_dev, owned.st_ino == status.st_ino else {
                            throw FileContentReadError.changed
                        }
                        let mode = owned.st_mode & 0o7777
                        if fchmod(descriptor, mode | mode_t(S_IWUSR)) == 0 {
                            creationResult = creationTime.write(url, entry.created)
                            creationCode = errno
                            guard fchmod(descriptor, mode) == 0 else { throw GuardedFileCopy.posixError() }
                        }
                    }
                }
                if blocked != 0, url.path.withCString({ lchflags($0, flags) }) != 0 { throw GuardedFileCopy.posixError() }
                if let timeError { throw timeError }
                if creationResult != 0 {
                    if [ENOTSUP, EINVAL, EPERM, EACCES].contains(creationCode) {
                        warnings.append(L10n.text("目标磁盘未能保留创建时间。", "The destination could not retain creation times."))
                    } else { throw POSIXError(POSIXErrorCode(rawValue: creationCode) ?? .EIO) }
                } else {
                    var restored = stat()
                    guard url.path.withCString({ lstat($0, &restored) }) == 0 else { throw GuardedFileCopy.posixError() }
                    if !MigrationCreationTime.matches(entry.created, Timestamp(restored.st_birthtimespec), quantum: quantum) {
                        warnings.append(L10n.text("目标磁盘未能完整保留创建时间。", "The destination could not fully retain creation times."))
                    }
                }
            }
            try progress()
            return Array(Set(warnings)).sorted()
        }

        func restorePublishedFlags(
            at url: URL,
            setFlags: @Sendable (UnsafePointer<CChar>, UInt32) -> Int32 = { Darwin.lchflags($0, $1) }
        ) throws {
            let flagsToRestore = deferredFlags & GuardedFileCopy.publicationFlags
            guard flagsToRestore != 0 else { return }
            var status = stat()
            guard url.path.withCString({ lstat($0, &status) }) == 0,
                  url.path.withCString({ setFlags($0, GuardedFileCopy.flagsAfterPublication(
                    destinationFlags: status.st_flags, deferredFlags: flagsToRestore)) }) == 0 else {
                throw GuardedFileCopy.posixError()
            }
            guard url.path.withCString({ lstat($0, &status) }) == 0 else { throw GuardedFileCopy.posixError() }
            guard status.st_flags & flagsToRestore == flagsToRestore else { throw POSIXError(.ENOTSUP) }
        }

        func restorePublishedPermissions(at url: URL) throws {
            guard let mode = deferredRootMode else { return }
            let descriptor = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else { throw GuardedFileCopy.posixError() }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_uid == geteuid() else {
                throw POSIXError(.EPERM)
            }
            guard fchmod(descriptor, mode) == 0 else { throw GuardedFileCopy.posixError() }
        }
    }

    // copyfile decides which SF_* flags the destination can represent. Only
    // owner-settable rename blockers and hidden state belong to publication.
    // In particular, never clear UF_COMPRESSED or demand privileged SF_* bits.
    static let renameBlockingFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
    static let publicationFlags = renameBlockingFlags | UInt32(UF_HIDDEN)

    static func flagsAfterPublication(destinationFlags: UInt32, deferredFlags: UInt32) -> UInt32 {
        destinationFlags | (deferredFlags & publicationFlags)
    }

    @discardableResult
    func copy(
        _ source: URL, to destination: URL, deferRootFlags: Bool = false,
        onFailure: (@Sendable () -> Void)? = nil
    ) throws -> PreparedCopy {
        try perform(source: source, destination: destination, onFailure: onFailure) { job in
            try copyOnWorker(source, to: destination, deferRootFlags: deferRootFlags, job: job)
        }
    }

    /// Hashing/signature checks may update atime. This second metadata pass is
    /// also cancellable and bounded; an abandoned worker still owns staging.
    @discardableResult
    func restoreTimes(_ copy: PreparedCopy, at destination: URL, onFailure: @escaping @Sendable () -> Void) throws -> PreparedCopy {
        try perform(source: destination, destination: destination, onFailure: onFailure) { job in
            job.waiting(for: .writingTimedOut)
            var updated = copy
            updated.metadataWarnings += try copy.restoreTimes(at: destination, creationTime: creationTime) { try job.check(); job.progress() }
            return updated
        }
    }

    /// Uses the same abandoned-worker protocol as copying. A published copy
    /// has no cleanup callback; late cancellation cannot unpublish it.
    @discardableResult
    func makeDurable(_ copy: PreparedCopy, at destination: URL, volumeRoot: URL? = nil,
                     committed: Bool = false, contents: Bool = true,
                     bytes: Int64? = nil, onFailure: (@Sendable () -> Void)? = nil) throws -> [String] {
        let totalBytes = bytes ?? copy.entries.filter { $0.kind == mode_t(S_IFREG) }.reduce(Int64(0)) {
            let size = max(0, $1.size)
            return $0 > Int64.max - size ? Int64.max : $0 + size
        }
        let result = try perform(source: destination, destination: destination, onFailure: onFailure,
                        ignoreCancellation: committed, timeout: durability.timeBudget(bytes: totalBytes, minimum: reader.timeout)) { job in
            job.waiting(for: .writingTimedOut)
            var updated = copy
            updated.metadataWarnings = try durability.synchronize(destination, entries: copy.entries, volumeRoot: volumeRoot, contents: contents,
                                                                  capability: copy.durabilityCapability) {
                try job.check(); job.progress()
            }
            return updated
        }
        return result.metadataWarnings
    }

    func probeDurability(at staging: URL, onFailure: @escaping @Sendable () -> Void) throws -> MigrationDurability.Capability {
        let result = try perform(source: staging, destination: staging, onFailure: onFailure,
                                 timeout: durability.timeBudget(bytes: 0, minimum: reader.timeout)) { job in
            job.waiting(for: .writingTimedOut)
            let capability = try durability.probe(staging) { try job.check(); job.progress() }
            return PreparedCopy(entries: [], deferredFlags: 0, durabilityCapability: capability)
        }
        guard let capability = result.durabilityCapability else { throw POSIXError(.EIO) }
        return capability
    }

    private func perform(
        source: URL, destination: URL, onFailure: (@Sendable () -> Void)?,
        ignoreCancellation: Bool = false,
        timeout: TimeInterval? = nil,
        operation: @escaping @Sendable (Job) throws -> PreparedCopy
    ) throws -> PreparedCopy {
        // Migration supplies its identity-bound staging owner. Lower-level
        // callers retain cleanup ownership; never delete an arbitrary existing
        // destination merely because COPYFILE_EXCL rejected it.
        let cleanup: @Sendable () -> Void = onFailure ?? {}
        let job = Job(guardPolicy: reader.guardPolicy, observer: progressObserver, cleanup: cleanup)
        let key = "copy|" + reader.pool.volumeIdentity(for: source) + "|" + reader.pool.volumeIdentity(for: destination)
        let slot: DispatchSemaphore
        do { slot = try reader.pool.reserveSlot(for: key) }
        catch {
            DispatchQueue.global(qos: .userInitiated).async(execute: cleanup)
            throw error
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { slot.signal() }
            let result = Result {
                try job.check()
                let restore = try FileContentReadGuard.refuseMaterializationOnThisThread()
                defer { restore() }
                return try operation(job)
            }
            job.finish(result)
        }
        while true {
            if !ignoreCancellation, Task.isCancelled { job.abandon(); throw CancellationError() }
            if job.idleSeconds >= (timeout ?? reader.timeout) { job.abandon(); throw job.timeoutReason }
            if let result = job.take() { return try result.get() }
            _ = job.completed.wait(timeout: .now() + 0.01)
        }
    }

    private func copyOnWorker(_ source: URL, to destination: URL, deferRootFlags: Bool, job: Job) throws -> PreparedCopy {
        var entries: [Entry] = []
        try collect(source, relativePath: "", depth: 0, job: job, entries: &entries)
        try job.check()
        // Reject an existing root before copyfile's permission fallback can
        // touch it. EXCL/mkdir still guard creation after this precheck.
        var existing = stat()
        if destination.path.withCString({ lstat($0, &existing) }) == 0 { throw POSIXError(.EEXIST) }
        guard errno == ENOENT else { throw Self.posixError() }
        try reader.willRead(source)
        try job.check()
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        if allowsCloning { flags |= copyfile_flags_t(COPYFILE_CLONE) }
        if !(try supportsACL(destination)) { flags &= ~copyfile_flags_t(COPYFILE_ACL) }
        // Recursive CLONE fallback reapplies STAT to directories before their
        // children, and recursive symlinks are copied after directory cleanup.
        // Keep our exclusively created directories writable until every child
        // (including links) exists, then let copyfile restore their metadata.
        // Data, xattrs, ACLs, resource forks and compression remain system-owned.
        for entry in entries {
            try job.check()
            job.waiting(for: .timedOut)
            let from = entry.relativePath.isEmpty ? source : source.appendingPathComponent(entry.relativePath)
            let to = entry.relativePath.isEmpty ? destination : destination.appendingPathComponent(entry.relativePath)
            try checkSource(from, against: entry)
            try job.check()
            if entry.kind == mode_t(S_IFDIR) {
                job.waiting(for: .writingTimedOut)
                guard to.path.withCString({ mkdir($0, 0o700) }) == 0 else { throw Self.posixError() }
            } else {
                job.waiting(for: .copyTimedOut)
                try copyEntry(from, to: to, flags: flags, job: job)
            }
            job.progress()
        }
        let directoryFlags = flags & ~copyfile_flags_t(COPYFILE_CLONE | COPYFILE_EXCL)
        for entry in entries.reversed() where entry.kind == mode_t(S_IFDIR) {
            try job.check()
            job.waiting(for: .timedOut)
            let from = entry.relativePath.isEmpty ? source : source.appendingPathComponent(entry.relativePath)
            let to = entry.relativePath.isEmpty ? destination : destination.appendingPathComponent(entry.relativePath)
            try checkSource(from, against: entry)
            job.waiting(for: .copyTimedOut)
            try copyEntry(from, to: to, flags: directoryFlags, job: job)
            job.progress()
        }
        // A clone can complete without progress callbacks. Recheck the
        // source and cloud flags even in that case before accepting it.
        for entry in entries {
            try job.check()
            job.waiting(for: .timedOut)
            let url = entry.relativePath.isEmpty ? source : source.appendingPathComponent(entry.relativePath)
            try checkSource(url, against: entry)
            job.progress()
        }
        var destinationStatus = stat()
        guard destination.path.withCString({ lstat($0, &destinationStatus) }) == 0 else { throw Self.posixError() }
        let deferred = deferRootFlags ? destinationStatus.st_flags & Self.publicationFlags : 0
        let blocked = deferred & Self.renameBlockingFlags
        if blocked != 0 {
            guard destination.path.withCString({ lchflags($0, destinationStatus.st_flags & ~Self.renameBlockingFlags) }) == 0 else {
                throw Self.posixError()
            }
        }
        var deferredMode: mode_t?
        if deferRootFlags, destinationStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
           destinationStatus.st_mode & mode_t(S_IWUSR) == 0 {
            // Only our new, owned staging root may be made writable. Its
            // original mode is restored after the cross-parent rename.
            let descriptor = destination.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else { throw Self.posixError() }
            defer { close(descriptor) }
            var owned = stat()
            guard fstat(descriptor, &owned) == 0, owned.st_uid == geteuid(),
                  owned.st_dev == destinationStatus.st_dev, owned.st_ino == destinationStatus.st_ino else {
                throw POSIXError(.EPERM)
            }
            deferredMode = destinationStatus.st_mode & 0o7777
            guard fchmod(descriptor, (destinationStatus.st_mode & 0o7777) | mode_t(S_IWUSR)) == 0 else {
                throw Self.posixError()
            }
        }
        var copied = PreparedCopy(entries: entries, deferredFlags: deferred, deferredRootMode: deferredMode)
        job.waiting(for: .writingTimedOut)
        copied.metadataWarnings = try copied.restoreTimes(at: destination, creationTime: creationTime) { try job.check(); job.progress() }
        try job.check()
        return copied
    }

    private func checkSource(_ url: URL, against entry: Entry) throws {
        var current = stat()
        guard url.path.withCString({ lstat($0, &current) }) == 0 else { throw Self.posixError() }
        guard Int32(current.st_dev) == entry.device, UInt64(current.st_ino) == entry.inode,
              current.st_mode & mode_t(S_IFMT) == entry.kind, Int64(current.st_size) == entry.size,
              Timestamp(current.st_mtimespec) == entry.modified,
              Timestamp(current.st_ctimespec) == entry.changed else { throw FileContentReadError.changed }
        if entry.kind != mode_t(S_IFLNK) { try reader.guardPolicy.check(url, isDirectory: entry.kind == mode_t(S_IFDIR)) }
    }

    private func copyEntry(_ source: URL, to destination: URL, flags: copyfile_flags_t, job: Job) throws {
        try job.check()
        // A fresh state is required per entry: copyfile keeps open descriptors
        // and filenames in its state until it is freed.
        guard let state = copyfile_state_alloc() else { throw Self.posixError() }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passUnretained(job).toOpaque()
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                unsafeBitCast(Self.callback, to: UnsafeRawPointer.self)) == 0 else { throw Self.posixError() }
        var preservePermissions: UInt32 = 1
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_PRESERVE_SUID), &preservePermissions) == 0 else {
            throw Self.posixError()
        }
        try job.check()
        let result = source.path.withCString { from in
            destination.path.withCString { to in copyfileOperation(from, to, state, flags) }
        }
        let systemError = Self.posixError()
        try job.check()
        if let callbackError = job.callbackError { throw callbackError }
        guard result == 0 else { throw systemError }
    }

    private func collect(_ source: URL, relativePath: String, depth: Int, job: Job, entries: inout [Entry]) throws {
        try job.check()
        guard depth < 128 else { throw FileContentReadError.tooDeep }
        var status = stat()
        guard source.path.withCString({ lstat($0, &status) }) == 0 else { throw Self.posixError() }
        let kind = status.st_mode & mode_t(S_IFMT)
        guard [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(kind) else { throw FileContentReadError.unsupportedType }
        if kind != mode_t(S_IFLNK) { try reader.guardPolicy.check(source, isDirectory: kind == mode_t(S_IFDIR)) }
        entries.append(Entry(relativePath: relativePath, device: Int32(status.st_dev), inode: UInt64(status.st_ino),
            kind: kind, size: Int64(status.st_size), modified: Timestamp(status.st_mtimespec),
            changed: Timestamp(status.st_ctimespec), accessed: Timestamp(status.st_atimespec),
            created: Timestamp(status.st_birthtimespec)))
        job.progress()
        if kind == mode_t(S_IFDIR) {
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                let relative = relativePath.isEmpty ? child.lastPathComponent : relativePath + "/" + child.lastPathComponent
                try collect(child, relativePath: relative, depth: depth + 1, job: job, entries: &entries)
            }
        }
    }

    private static var callback: copyfile_callback_t { { what, stage, _, source, _, context in
        // Capture errno before locks, observers, URL construction or progress
        // checks can replace it. CONTINUE at ERR would silently accept loss.
        let systemError = stage == COPYFILE_ERR ? GuardedFileCopy.posixError() : nil
        guard let context else { return Int32(COPYFILE_QUIT) }
        let job = Unmanaged<Job>.fromOpaque(context).takeUnretainedValue()
        if let systemError {
            job.failCallback(systemError)
            return Int32(COPYFILE_QUIT)
        }
        do {
            try job.check()
            if stage == COPYFILE_START, let source {
                let url = URL(fileURLWithPath: String(cString: source))
                var status = stat()
                guard lstat(source, &status) == 0 else { throw GuardedFileCopy.posixError() }
                let kind = status.st_mode & mode_t(S_IFMT)
                if kind != mode_t(S_IFLNK) { try job.guardPolicy.check(url, isDirectory: kind == mode_t(S_IFDIR)) }
            }
            job.observer(what, stage)
            try job.check()
            job.progress()
            return Int32(COPYFILE_CONTINUE)
        } catch {
            job.failCallback(error)
            return Int32(COPYFILE_QUIT)
        }
    } }

    /// Lock protects every mutable field. Only the synchronous copyfile worker
    /// uses the raw callback context, retained by the worker for its full call.
    private final class Job: @unchecked Sendable {
        let guardPolicy: FileContentReadGuard
        let observer: @Sendable (Int32, Int32) -> Void
        let cleanup: @Sendable () -> Void
        let completed = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var abandoned = false
        private var finished = false
        private var cleanupClaimed = false
        private var lastProgress = ProcessInfo.processInfo.systemUptime
        private var result: Result<PreparedCopy, Error>?
        private var failure: Error?
        private var stalledReason: FileContentReadError = .timedOut
        init(guardPolicy: FileContentReadGuard, observer: @escaping @Sendable (Int32, Int32) -> Void,
             cleanup: @escaping @Sendable () -> Void) {
            self.guardPolicy = guardPolicy; self.observer = observer; self.cleanup = cleanup
        }
        var idleSeconds: TimeInterval { lock.withLock { ProcessInfo.processInfo.systemUptime - lastProgress } }
        var callbackError: Error? { lock.withLock { failure } }
        var timeoutReason: FileContentReadError { lock.withLock { stalledReason } }
        func waiting(for reason: FileContentReadError) { lock.withLock { stalledReason = reason } }
        func failCallback(_ error: Error) { lock.withLock { if failure == nil { failure = error } } }
        func progress() { lock.withLock { lastProgress = ProcessInfo.processInfo.systemUptime } }
        func check() throws { if lock.withLock({ abandoned }) { throw CancellationError() } }
        func take() -> Result<PreparedCopy, Error>? { lock.withLock { result } }
        func finish(_ value: Result<PreparedCopy, Error>) {
            let shouldClean = lock.withLock {
                finished = true
                if !abandoned { result = value }
                let failed: Bool
                if case .failure = value { failed = true } else { failed = false }
                guard (abandoned || failed), !cleanupClaimed else { return false }
                cleanupClaimed = true
                return true
            }
            completed.signal()
            if shouldClean { cleanup() }
        }
        func abandon() {
            let shouldClean = lock.withLock {
                abandoned = true; result = nil
                guard finished, !cleanupClaimed else { return false }
                cleanupClaimed = true
                return true
            }
            if shouldClean { DispatchQueue.global(qos: .userInitiated).async(execute: cleanup) }
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
