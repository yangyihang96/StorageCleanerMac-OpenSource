import CryptoKit
import Darwin
import Foundation

/// Incremental storage belonging to CleanupReportJournal. The original JSON is
/// immutable; length-prefixed, hash-chained events extend it. A torn suffix is
/// retained and readable up to the last verified event, but never appended over.
final class CleanupJournalEvents: @unchecked Sendable {
    static let shared = CleanupJournalEvents()
    private let lock = NSRecursiveLock()
    private var cached: Cached?
    private static let maximumFrameBytes = 16 * 1_024 * 1_024
    private static let maximumEventBytes = 256 * 1_024 * 1_024

    struct Loaded {
        let entry: CleanupReportJournal.Entry
        let sequence: UInt64
        let digest: String
        let damagedSuffix: Bool
    }

    private struct FileStamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
        init?(_ url: URL) {
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                  value.st_nlink == 1, value.st_uid == getuid() else { return nil }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            seconds = value.st_mtimespec.tv_sec; nanoseconds = value.st_mtimespec.tv_nsec
        }
    }
    private struct Cached {
        let path: String
        let baseStamp: FileStamp
        let eventStamp: FileStamp?
        let loaded: Loaded
    }
    private struct Row: Codable { let index: Int; let value: CleanReportItem }
    private struct RecoveryRow: Codable { let index: Int; let value: CleanupRecoveryItem }
    private struct Recovery: Codable {
        let index: Int
        let header: CleanupRecoveryReport
        let rows: [RecoveryRow]
    }
    private struct Delta: Codable {
        let version: Int
        let sequence: UInt64
        let previousDigest: String
        let header: CleanReport
        let rows: [Row]
        let recovery: [Recovery]
    }

    static func eventURL(for baseURL: URL) -> URL { baseURL.deletingPathExtension().appendingPathExtension("events") }

    func synchronized<T>(_ body: () throws -> T) rethrows -> T { try lock.withLock(body) }

    func load(baseURL: URL, readBase: () throws -> CleanupReportJournal.Entry) throws -> Loaded {
        try lock.withLock {
            let eventURL = Self.eventURL(for: baseURL)
            guard let baseStamp = FileStamp(baseURL) else { throw CleanupReportJournal.Failure.unsafePath }
            let eventExists = try Self.entryExists(eventURL)
            let eventStamp = FileStamp(eventURL)
            if let cached, cached.path == baseURL.path, cached.baseStamp == baseStamp,
               cached.eventStamp == eventStamp {
                // A newly inserted non-regular entry must not masquerade as a missing file.
                if eventStamp == nil, eventExists {
                    throw CleanupReportJournal.Failure.unsafePath
                }
                return cached.loaded
            }
            var entry = try readBase()
            var digest = Self.hash(try Data(contentsOf: baseURL))
            var sequence: UInt64 = 0
            var damaged = false
            if eventExists {
                let fd = open(eventURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw CleanupReportJournal.Failure.unsafePath }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                try Self.validateFile(fd)
                var consumed = 0
                while true {
                    do {
                        let prefix = try Self.read(handle, count: 4)
                        if prefix.isEmpty { break }
                        guard prefix.count == 4 else { throw CleanupReportJournal.Failure.invalidEntry }
                        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
                        guard length > 0, length <= Self.maximumFrameBytes,
                              consumed + length + 36 <= Self.maximumEventBytes else {
                            throw CleanupReportJournal.Failure.tooLarge
                        }
                        let payload = try Self.read(handle, count: length)
                        let checksum = try Self.read(handle, count: 32)
                        guard payload.count == length, checksum == Data(SHA256.hash(data: payload)) else {
                            throw CleanupReportJournal.Failure.invalidEntry
                        }
                        let delta = try JSONDecoder().decode(Delta.self, from: payload)
                        guard delta.version == 2, delta.sequence == sequence + 1,
                              delta.previousDigest == digest else { throw CleanupReportJournal.Failure.invalidEntry }
                        entry = try Self.applying(delta, to: entry)
                        sequence = delta.sequence; digest = Self.hash(payload)
                        consumed += length + 36
                    } catch {
                        // Preserve valid preceding receipts and the damaged bytes.
                        damaged = true
                        break
                    }
                }
            }
            let loaded = Loaded(entry: entry, sequence: sequence, digest: digest, damagedSuffix: damaged)
            remember(loaded, baseURL: baseURL, baseStamp: baseStamp, eventStamp: eventStamp)
            return loaded
        }
    }

    func append(_ report: CleanReport, to baseURL: URL, previous: Loaded) throws {
        try lock.withLock {
            guard !previous.damagedSuffix else { throw CleanupReportJournal.Failure.invalidEntry }
            let prior = previous.entry.report
            guard report.completedAt >= prior.completedAt else { throw CleanupReportJournal.Failure.staleRevision }
            guard report.planID == prior.planID, report.sessionID == prior.sessionID,
                  report.rulesVersion == prior.rulesVersion, report.rulesProvenance == prior.rulesProvenance,
                  report.disposition == prior.disposition,
                  report.items.count == prior.items.count,
                  report.restoreAuthorizations == prior.restoreAuthorizations,
                  report.uninstallOwnership == prior.uninstallOwnership else {
                throw CleanupReportJournal.Failure.invalidEntry
            }
            let rows = try report.items.enumerated().compactMap { index, item -> Row? in
                let old = prior.items[index]
                guard old.planItemID == item.planItemID, old.sourcePath == item.sourcePath,
                      old.ruleID == item.ruleID, old.ruleRevision == item.ruleRevision, old.estimatedBytes == item.estimatedBytes else {
                    throw CleanupReportJournal.Failure.invalidEntry
                }
                if case .moved(let receipt) = old.outcome, receipt.isRestorable,
                   old.outcome != item.outcome { throw CleanupReportJournal.Failure.invalidEntry }
                return old == item ? nil : Row(index: index, value: item)
            }
            let before = prior.recoveryAttempts ?? []
            let after = report.recoveryAttempts ?? []
            guard after.count >= before.count else { throw CleanupReportJournal.Failure.invalidEntry }
            let recovery = try after.enumerated().compactMap { index, attempt -> Recovery? in
                let old = before.indices.contains(index) ? before[index] : nil
                if old == attempt { return nil }
                let oldRows = old?.items ?? []
                guard old == nil || old?.attemptID == attempt.attemptID,
                      attempt.items.count >= oldRows.count else { throw CleanupReportJournal.Failure.invalidEntry }
                let changed = try attempt.items.enumerated().compactMap { row, value -> RecoveryRow? in
                    if oldRows.indices.contains(row) {
                        guard oldRows[row].originalPath == value.originalPath else { throw CleanupReportJournal.Failure.invalidEntry }
                        if oldRows[row].outcome == .restored, value.outcome != .restored {
                            throw CleanupReportJournal.Failure.invalidEntry
                        }
                        if oldRows[row] == value { return nil }
                    }
                    return RecoveryRow(index: row, value: value)
                }
                return Recovery(index: index, header: CleanupRecoveryReport(completedAt: attempt.completedAt,
                    items: [], attemptID: attempt.attemptID, persistenceFailure: attempt.persistenceFailure), rows: changed)
            }
            let header = Self.report(report, items: [], recovery: report.recoveryAttempts.map { _ in [] }, authorizations: nil)
            let delta = Delta(version: 2, sequence: previous.sequence + 1, previousDigest: previous.digest,
                              header: header, rows: rows, recovery: recovery)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(delta)
            guard payload.count <= Self.maximumFrameBytes else { throw CleanupReportJournal.Failure.tooLarge }
            var size = UInt32(payload.count).bigEndian
            var frame = withUnsafeBytes(of: &size) { Data($0) }
            frame.append(payload); frame.append(Data(SHA256.hash(data: payload)))
            let eventURL = Self.eventURL(for: baseURL)
            let fd = open(eventURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CleanupReportJournal.Failure.unsafePath }
            defer { close(fd) }
            try Self.validateFile(fd)
            var metadata = stat()
            guard fstat(fd, &metadata) == 0,
                  metadata.st_size + Int64(frame.count) <= Self.maximumEventBytes else {
                throw CleanupReportJournal.Failure.tooLarge
            }
            // Drop the cached state before writing: a partial write or fsync
            // failure requires a verified replay, never an assumed rollback.
            cached = nil
            try frame.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < frame.count {
                    let written = write(fd, base.advanced(by: offset), frame.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
            let parent = open(baseURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw CleanupReportJournal.Failure.unsafePath }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
            let next = Loaded(entry: .init(schemaVersion: previous.entry.schemaVersion,
                expectedIdentities: previous.entry.expectedIdentities, report: report),
                sequence: delta.sequence, digest: Self.hash(payload), damagedSuffix: false)
            if let baseStamp = FileStamp(baseURL) {
                remember(next, baseURL: baseURL, baseStamp: baseStamp, eventStamp: FileStamp(eventURL))
            }
        }
    }

    private func remember(_ loaded: Loaded, baseURL: URL, baseStamp: FileStamp, eventStamp: FileStamp?) {
        // One active operation only; at most ~8 MiB encoded base plus a bounded
        // number of recovery rows. Larger evidence stays on disk without caching.
        let rows = loaded.entry.report.items.count
            + (loaded.entry.report.recoveryAttempts ?? []).reduce(0) { $0 + $1.items.count }
        guard baseStamp.size <= 8 * 1_024 * 1_024, rows <= 8_192 else { cached = nil; return }
        cached = Cached(path: baseURL.path, baseStamp: baseStamp, eventStamp: eventStamp, loaded: loaded)
    }

    private static func applying(_ delta: Delta, to entry: CleanupReportJournal.Entry) throws -> CleanupReportJournal.Entry {
        guard delta.header.planID == entry.report.planID, delta.header.sessionID == entry.report.sessionID,
              delta.header.rulesVersion == entry.report.rulesVersion,
              delta.header.rulesProvenance == entry.report.rulesProvenance,
              delta.header.disposition == entry.report.disposition,
              delta.header.items.isEmpty, delta.header.restoreAuthorizations == nil else {
            throw CleanupReportJournal.Failure.invalidEntry
        }
        var items = entry.report.items
        var seen = Set<Int>()
        for row in delta.rows {
            guard items.indices.contains(row.index), seen.insert(row.index).inserted,
                  items[row.index].planItemID == row.value.planItemID,
                  items[row.index].sourcePath == row.value.sourcePath,
                  items[row.index].ruleID == row.value.ruleID,
                  items[row.index].ruleRevision == row.value.ruleRevision,
                  items[row.index].estimatedBytes == row.value.estimatedBytes else {
                throw CleanupReportJournal.Failure.invalidEntry
            }
            if case .moved(let receipt) = items[row.index].outcome, receipt.isRestorable,
               items[row.index].outcome != row.value.outcome { throw CleanupReportJournal.Failure.invalidEntry }
            items[row.index] = row.value
        }
        var attempts = entry.report.recoveryAttempts ?? []
        var seenAttempts = Set<Int>()
        for change in delta.recovery {
            guard change.index >= 0, change.index <= attempts.count,
                  change.header.items.isEmpty, seenAttempts.insert(change.index).inserted else {
                throw CleanupReportJournal.Failure.invalidEntry
            }
            let old = attempts.indices.contains(change.index) ? attempts[change.index] : nil
            guard old == nil || old?.attemptID == change.header.attemptID else { throw CleanupReportJournal.Failure.invalidEntry }
            var values = old?.items ?? []
            var seenRows = Set<Int>()
            for row in change.rows {
                guard row.index >= 0, row.index <= values.count, seenRows.insert(row.index).inserted else {
                    throw CleanupReportJournal.Failure.invalidEntry
                }
                if row.index == values.count { values.append(row.value) }
                else {
                    guard values[row.index].originalPath == row.value.originalPath,
                          values[row.index].outcome != .restored || row.value.outcome == .restored else {
                        throw CleanupReportJournal.Failure.invalidEntry
                    }
                    values[row.index] = row.value
                }
            }
            let updated = CleanupRecoveryReport(completedAt: change.header.completedAt, items: values,
                attemptID: change.header.attemptID, persistenceFailure: change.header.persistenceFailure)
            if change.index == attempts.count { attempts.append(updated) } else { attempts[change.index] = updated }
        }
        guard delta.header.recoveryAttempts != nil || attempts.isEmpty else { throw CleanupReportJournal.Failure.invalidEntry }
        let report = report(delta.header, items: items,
                            recovery: delta.header.recoveryAttempts == nil ? nil : attempts,
                            authorizations: entry.report.restoreAuthorizations, ownership: entry.report.uninstallOwnership)
        return .init(schemaVersion: entry.schemaVersion, expectedIdentities: entry.expectedIdentities, report: report)
    }

    private static func report(_ header: CleanReport, items: [CleanReportItem],
                               recovery: [CleanupRecoveryReport]?,
                               authorizations: [String: CleanupRestoreAuthorization]?,
                               ownership: [String: UninstallOwnershipEvidence]? = nil) -> CleanReport {
        CleanReport(id: header.id, planID: header.planID, sessionID: header.sessionID,
            rulesVersion: header.rulesVersion, disposition: header.disposition, scanWasPartial: header.scanWasPartial,
            startedAt: header.startedAt, completedAt: header.completedAt, outcome: header.outcome,
            items: items, summary: header.summary, persistenceFailure: header.persistenceFailure,
            recoveryAttempts: recovery, restoreAuthorizations: authorizations, uninstallOwnership: ownership,
            rulesProvenance: header.rulesProvenance)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        return data
    }
    private static func validateFile(_ fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_uid == getuid() else { throw CleanupReportJournal.Failure.unsafePath }
    }

    private static func entryExists(_ url: URL) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
