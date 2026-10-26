import Darwin
import Foundation

/// Cross-process admission, independent of the running daemon. The production
/// location and root owner are fixed locally, never taken from an XPC request.
/// Untrusted filesystem state fails closed. Damaged contents are repaired under
/// the same lock, retaining cooldown rather than permanently blocking upgrades.
/// Normal records use boot uptime. Wall time is used only to recover a damaged
/// record's mtime into uptime, then persisted so later reads cannot reset it.
public final class HelperUpgradeLedger: @unchecked Sendable {
    public static let minimumInterval: TimeInterval = 600
    /// macOS keeps `/var/run` as root:daemon 0775. Group write is trusted only
    /// for these system groups (wheel, daemon); world write never is. Without
    /// this the production ledger always failed closed and the helper never
    /// handed over to a replaced executable (D97).
    static let productionTrustedWriterGroups: Set<gid_t> = [0, 1]
    private let directory: URL
    private let filename: String
    private let owner: uid_t
    private let trustedWriterGroups: Set<gid_t>
    private let wallClock: @Sendable () -> TimeInterval
    private struct Record: Codable {
        let highestYieldedBuild: String?
        let yieldedAtUptime: TimeInterval?
        let neverYielded: Bool?
    }
    private struct CooldownTimestamp: Decodable {
        let yieldedAtUptime: TimeInterval
    }

    public convenience init(label: String) {
        self.init(directory: URL(fileURLWithPath: "/var/run").resolvingSymlinksInPath(),
                  filename: label + ".handoff", owner: 0,
                  trustedWriterGroups: Self.productionTrustedWriterGroups)
    }

    // Pure filesystem tests use their own protected temporary directory/uid.
    // This initializer is not part of the privileged adapter's public API.
    init(directory: URL, filename: String, owner: uid_t, trustedWriterGroups: Set<gid_t> = [],
         wallClock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.directory = directory; self.filename = filename; self.owner = owner
        self.trustedWriterGroups = trustedWriterGroups
        self.wallClock = wallClock
    }

    public func permits(target: HelperSignedBuildVersion, running: HelperSignedBuildVersion,
                        at time: TimeInterval) -> Bool {
        access(target: target, running: running, at: time, commit: false, validate: { true })
    }

    /// The final full image validation runs under the same lock as admission
    /// and persistence. Only a durable record permits the subsequent exit.
    public func commitIfPermitted(target: HelperSignedBuildVersion, running: HelperSignedBuildVersion,
                                  at time: TimeInterval,
                                  validate: () throws -> Bool) -> Bool {
        access(target: target, running: running, at: time, commit: true, validate: validate)
    }

    private func access(target: HelperSignedBuildVersion, running: HelperSignedBuildVersion, at time: TimeInterval,
                        commit: Bool, validate: () throws -> Bool) -> Bool {
        guard time.isFinite, time >= 0, !filename.isEmpty,
              !filename.contains("/"), filename != ".", filename != ".." else { return false }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return false }
        defer { close(parent) }
        var parentStat = stat()
        guard fstat(parent, &parentStat) == 0, parentStat.st_uid == owner,
              parentStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              parentStat.st_mode & 0o002 == 0,
              parentStat.st_mode & 0o020 == 0 || trustedWriterGroups.contains(parentStat.st_gid) else { return false }
        let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var fd = openat(parent, filename, flags | O_CREAT | O_EXCL, 0o600)
        let created = fd >= 0
        if !created {
            guard errno == EEXIST else { return false }
            fd = openat(parent, filename, flags)
        }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == owner,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o7777 == 0o600, metadata.st_nlink == 1,
              metadata.st_size >= 0 else { return false }
        var contents = Data()
        if metadata.st_size > 0, metadata.st_size <= 1_024 {
            var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
            guard count == bytes.count else { return false }
            contents = Data(bytes)
        }
        let record: Record
        if created && metadata.st_size == 0 {
            // Only O_EXCL proves first creation. An existing zero-length file
            // could be a cleared handoff record and must retain mtime cooldown.
            record = Record(highestYieldedBuild: nil, yieldedAtUptime: nil, neverYielded: true)
            guard write(record, to: fd) else { return false }
        } else if let decoded = try? JSONDecoder().decode(Record.self, from: contents),
                  isUsable(decoded, target: target, running: running) {
            record = decoded
        } else {
            let wallTime = wallClock()
            let modified = Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
            guard wallTime.isFinite, modified.isFinite else { return false }
            // A future mtime/invalid future record time gets a full cooldown,
            // not an unbounded refusal. Preserve the later credible timestamp.
            let fromMtime = max(0, time - max(0, wallTime - modified))
            let stored = (try? JSONDecoder().decode(CooldownTimestamp.self, from: contents))?.yieldedAtUptime
            let fromRecord = stored.flatMap { $0.isFinite && $0 >= 0 ? min(time, $0) : nil } ?? 0
            record = Record(highestYieldedBuild: nil, yieldedAtUptime: max(fromMtime, fromRecord), neverYielded: nil)
            // Repair without consuming the candidate, even if cooldown denies
            // admission. Same inode, protected ownership/mode and lock remain.
            guard write(record, to: fd) else { return false }
        }
        if let text = record.highestYieldedBuild, let previous = HelperSignedBuildVersion(text) {
            guard target > previous else { return false }
        }
        if let yieldedAt = record.yieldedAtUptime {
            guard time - yieldedAt >= Self.minimumInterval else { return false }
        }
        guard commit else { return true }
        guard (try? validate()) == true else { return false }
        return write(Record(highestYieldedBuild: target.description, yieldedAtUptime: time, neverYielded: nil), to: fd)
    }

    private func isUsable(_ record: Record, target: HelperSignedBuildVersion,
                          running: HelperSignedBuildVersion) -> Bool {
        if record.neverYielded == true {
            return record.highestYieldedBuild == nil && record.yieldedAtUptime == nil
        }
        guard let time = record.yieldedAtUptime, time.isFinite, time >= 0 else { return false }
        guard let text = record.highestYieldedBuild else { return true } // repaired cooldown only
        guard let previous = HelperSignedBuildVersion(text) else { return false }
        return !(previous > target && previous > running)
    }

    private func write(_ record: Record, to fd: Int32) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        // Keep the locked inode: atomic rename would give concurrent processes
        // different locks. Partial writes deny exit; later recovery retains mtime.
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard written == data.count, ftruncate(fd, off_t(data.count)) == 0, fsync(fd) == 0 else { return false }
        return true
    }
}
