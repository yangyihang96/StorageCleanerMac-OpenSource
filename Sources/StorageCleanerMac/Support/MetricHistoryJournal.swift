import CryptoKit
import Darwin
import Foundation

/// Incremental persistence owned by MetricHistoryStore. Not an operation receipt.
struct MetricHistoryJournal: Sendable {
    static let checkpointBytes = 1_024 * 1_024
    static let checkpointInterval: TimeInterval = 6 * 60 * 60
    static let maximumJournalBytes = 16 * 1_024 * 1_024
    let url: URL
    let maximumSnapshotBytes: Int
    var beforeWrite: @Sendable () throws -> Void = {}
    var eventsURL: URL { url.appendingPathExtension("events") }

    init(url: URL, maximumSnapshotBytes: Int, beforeWrite: @escaping @Sendable () throws -> Void = {}) {
        // macOS exposes its private temporary roots through these system aliases.
        // Only normalize the known root, never an application-controlled symlink.
        let path = (try? OperationFileLock.systemAliasResolvedPath(url.path)) ?? url.path
        self.url = URL(fileURLWithPath: path)
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.beforeWrite = beforeWrite
    }

    struct Loaded: Sendable {
        var snapshot: MetricHistorySnapshot?
        var sequence: UInt64 = 0
        var checkpointAt: Date?
        var journalBytes = 0
        var issue: String?
    }
    struct Saved: Sendable { let sequence: UInt64; let issue: String? }
    private struct Payload: Codable {
        let version: Int
        let sequence: UInt64
        let points: MetricHistorySnapshot
    }
    private struct Record: Codable { let payload: Payload; let sha256: String }
    enum Failure: Error { case staleSequence, damagedJournal, unsafePath }

    func load() throws -> Loaded {
        let lease = try OperationFileLock(directory: url.deletingLastPathComponent(),
                                          name: url.lastPathComponent + ".lock", wait: true)
        defer { withExtendedLifetime(lease) {} }
        return try loadLocked()
    }

    private func loadLocked() throws -> Loaded {
        var loaded = Loaded()
        if let data = try BoundedMonitoringFile.read(url, maximumBytes: maximumSnapshotBytes) {
            let base = try JSONDecoder().decode(MetricHistorySnapshot.self, from: data)
            guard base.version == MetricHistorySnapshot.currentVersion else { throw MonitoringFileError.invalidStructure }
            loaded.snapshot = base
            loaded.sequence = base.checkpointSequence
            loaded.checkpointAt = base.checkpointWrittenAt
        }
        guard let data = try BoundedMonitoringFile.read(eventsURL, maximumBytes: Self.maximumJournalBytes) else { return loaded }
        loaded.journalBytes = data.count
        // An interrupted tail never authorizes replacing the original bytes.
        let completeTail = data.isEmpty || data.last == 0x0A
        let rows = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for (index, row) in rows.enumerated() {
            if index == rows.count - 1 && !completeTail {
                loaded.issue = "Incomplete monitoring journal tail"
                break
            }
            do {
                let record = try JSONDecoder().decode(Record.self, from: Data(row))
                guard record.payload.version == 1,
                      record.sha256 == Self.digest(try Self.encode(record.payload)) else { throw Failure.damagedJournal }
                if record.payload.sequence <= loaded.sequence { continue }
                guard loaded.snapshot != nil, record.payload.sequence == loaded.sequence + 1 else { throw Failure.damagedJournal }
                var snapshot = loaded.snapshot ?? .empty
                MetricHistoryStore.merge(record.payload.points, into: &snapshot)
                loaded.snapshot = snapshot
                loaded.sequence = record.payload.sequence
            } catch {
                loaded.issue = "Invalid monitoring journal record at \(index + 1): \(error)"
                break
            }
        }
        return loaded
    }

    func persist(snapshot: MetricHistorySnapshot, delta: MetricHistorySnapshot,
                 expectedSequence: UInt64, now: Date) throws -> Saved {
        let lease = try OperationFileLock(directory: url.deletingLastPathComponent(),
                                          name: url.lastPathComponent + ".lock", wait: true)
        defer { withExtendedLifetime(lease) {} }
        let loaded = try loadLocked()
        guard loaded.issue == nil else { throw Failure.damagedJournal }
        guard loaded.sequence == expectedSequence, expectedSequence < UInt64.max else { throw Failure.staleSequence }
        let sequence = expectedSequence + 1
        let payload = Payload(version: 1, sequence: sequence, points: delta)
        var row = try Self.encode(Record(payload: payload, sha256: Self.digest(try Self.encode(payload))))
        row.append(0x0A)
        let age = loaded.checkpointAt.map { now.timeIntervalSince($0) } ?? .infinity
        let checkpoint = loaded.snapshot == nil || age < 0 || age >= Self.checkpointInterval
            || loaded.journalBytes + row.count >= Self.checkpointBytes
        try beforeWrite()
        if checkpoint {
            try writeCheckpointLocked(snapshot, sequence: sequence, now: now)
            // A crash here leaves the old journal replayable: its sequences are
            // already covered by the durable checkpoint and are ignored.
            do {
                try writeEvents(Data(), truncate: true)
                return Saved(sequence: sequence, issue: nil)
            } catch {
                return Saved(sequence: sequence, issue: "Monitoring checkpoint saved; journal cleanup failed: \(error)")
            }
        }
        guard loaded.journalBytes + row.count <= Self.maximumJournalBytes else { throw MetricHistoryStoreError.fileTooLarge }
        try writeEvents(row, truncate: false)
        return Saved(sequence: sequence, issue: nil)
    }

    /// A torn or invalid tail used to stop every later save. Copy the original
    /// log aside byte for byte first, then checkpoint the valid prefix and start
    /// a fresh log. Returns nil when the journal was not damaged.
    func preserveDamagedTailAndCheckpoint(now: Date) throws -> (loaded: Loaded, preserved: URL)? {
        let lease = try OperationFileLock(directory: url.deletingLastPathComponent(),
                                          name: url.lastPathComponent + ".lock", wait: true)
        defer { withExtendedLifetime(lease) {} }
        var loaded = try loadLocked()
        guard loaded.issue != nil else { return nil }
        // A copy of these exact bytes may already exist when a previous attempt
        // failed after copying; reuse it instead of adding one per launch.
        let current = try Data(contentsOf: eventsURL)
        let prefix = eventsURL.lastPathComponent + ".damaged-"
        let directory = url.deletingLastPathComponent()
        let existing = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .first { (try? Data(contentsOf: $0)) == current }
        let preserved: URL
        if let existing {
            preserved = existing
        } else {
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
            preserved = directory.appendingPathComponent(prefix + stamp + "-" + UUID().uuidString.prefix(8))
            try FileManager.default.copyItem(at: eventsURL, to: preserved)
            try Self.sync(preserved, directory: false)
        }
        try writeCheckpointLocked(loaded.snapshot ?? .empty, sequence: loaded.sequence, now: now)
        try writeEvents(Data(), truncate: true)
        loaded.issue = nil
        loaded.journalBytes = 0
        loaded.checkpointAt = now
        return (loaded, preserved)
    }

    private func writeCheckpointLocked(_ snapshot: MetricHistorySnapshot, sequence: UInt64, now: Date) throws {
        var base = MetricHistoryStore.checkpointSnapshot(snapshot, longRangeBucket: 5 * 60)
        base.checkpointSequence = sequence
        base.checkpointWrittenAt = now
        var bytes = try Self.encode(base)
        if bytes.count > maximumSnapshotBytes {
            base = MetricHistoryStore.checkpointSnapshot(snapshot, longRangeBucket: 30 * 60)
            base.checkpointSequence = sequence
            base.checkpointWrittenAt = now
            bytes = try Self.encode(base)
        }
        guard bytes.count <= maximumSnapshotBytes else { throw MetricHistoryStoreError.fileTooLarge }
        // The lease has walked the parent with openat/O_NOFOLLOW and
        // verified its owner and permissions. Validate the final file too.
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid() else { throw Failure.unsafePath }
        } else if errno != ENOENT { throw Failure.unsafePath }
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.sync(url, directory: false)
        try Self.sync(url.deletingLastPathComponent(), directory: true)
    }

    private func writeEvents(_ data: Data, truncate: Bool) throws {
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (truncate ? 0 : O_APPEND)
        let fd = open(eventsURL.path, flags, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0 else { throw Failure.unsafePath }
        if truncate, ftruncate(fd, 0) != 0 { throw POSIXError(.EIO) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        try Self.sync(url.deletingLastPathComponent(), directory: true)
    }
    private static func sync(_ url: URL, directory: Bool) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw Failure.unsafePath }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
