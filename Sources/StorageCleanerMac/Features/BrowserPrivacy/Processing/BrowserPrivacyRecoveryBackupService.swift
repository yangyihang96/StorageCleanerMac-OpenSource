import CSQLite
import CryptoKit
import Darwin
import Foundation

/// How long the backup taken before a direct deletion is kept (decision
/// D26, 2026-10-04): seven days, at most twelve backups. Expiry, pruning and
/// every text that mentions the period read these values.
enum BrowserPrivacyBackupRetention {
    static let days = 7
    static let maximumCount = 12

    static func expiry(ofBackupCreatedAt createdAt: Date) -> Date {
        createdAt.addingTimeInterval(TimeInterval(days) * 86_400)
    }
}

/// The recovery folder, or a file in it, could not be prepared or written.
/// Errors from reading the browser's database keep their own meaning.
struct BrowserPrivacyBackupStorageFailure: Error, Equatable, Sendable {
    var timeMachineExclusionFailed = false
    var rootIsSymbolicLink = false
}

struct BrowserPrivacyRecoveryBackup: Equatable, Sendable {
    let id: UUID
    let databaseURL: URL
    let sha256: Data
    let createdAt: Date
    /// Keeps an operation's unfinished backup hidden across sleep. Listing
    /// handles have no writing lease; equality compares the persisted backup.
    var writingLease: BrowserPrivacyRecoveryLease? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.databaseURL == rhs.databaseURL
            && lhs.sha256 == rhs.sha256 && lhs.createdAt == rhs.createdAt
    }
}

/// What happened to the database the backup was taken from.
enum BrowserPrivacyRecoveryOutcome: String, Codable, Equatable, Sendable {
    /// The deletion was committed and confirmed by a fresh read.
    case deleted
    /// The deletion was committed, but the final read-only check failed.
    case unverified
    /// The deletion did not complete and this backup was restored automatically.
    case restoredAfterFailure
    /// Neither the rollback nor the automatic restore could be confirmed.
    case restoreUnconfirmed
    /// The state just before a restore, saved so the restore can be undone.
    case savedBeforeRestore
    /// Processing stopped on an error nobody planned for.
    case unexpectedError

    /// Whether the database may be in a state nobody has confirmed. Such a
    /// backup may be the only way back, so the count limit never removes
    /// it; it still expires with the retention period (D26).
    var leavesTheResultUnknown: Bool {
        switch self {
        case .unverified, .restoreUnconfirmed, .unexpectedError: true
        case .deleted, .restoredAfterFailure, .savedBeforeRestore: false
        }
    }
}

/// Stored next to a backup so "Recent Deletions" can say what it belongs to.
/// It names the browser and profile and counts rows; it never contains an
/// address or a title.
struct BrowserPrivacyRecoverySummary: Equatable, Sendable {
    let browserDisplayName: String
    let profileDisplayName: String
    /// What the deletion behind the backup covered. Nil for a state saved
    /// before a restore, which deleted nothing.
    let visitCount: Int?
    let pageCount: Int?
    let outcome: BrowserPrivacyRecoveryOutcome
    var dataContract: BrowserPrivacyDataContract? = nil
}

/// One restorable backup as listed in "Recent Deletions".
struct BrowserPrivacyRecoveryEntry: Identifiable, Equatable, Sendable {
    let backup: BrowserPrivacyRecoveryBackup
    let browserID: String
    /// SHA-256 of the profile identifier the backup was taken from.
    let profileFingerprint: String
    /// Nil for backups written before the summary existed.
    let summary: BrowserPrivacyRecoverySummary?
    let restoredAt: Date?
    var dataContract: BrowserPrivacyDataContract? = nil
    var rowBackup = false

    var canRestore: Bool {
        guard let dataContract else { return true }
        return dataContract.permitsDeletion && (!dataContract.usesRowBackup || rowBackup)
    }
    var id: UUID { backup.id }
    var createdAt: Date { backup.createdAt }
    var expiresAt: Date { BrowserPrivacyBackupRetention.expiry(ofBackupCreatedAt: createdAt) }
}

protocol BrowserPrivacyDatabaseBackingUp: Sendable {
    func backup(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        browserID: String,
        profileID: String,
        deadlineNanoseconds: UInt64
    ) async throws -> BrowserPrivacyRecoveryBackup
    func restore(
        _ backup: BrowserPrivacyRecoveryBackup,
        destination: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        deadlineNanoseconds: UInt64
    ) async throws
    /// Held from before saving the undo state until the restore result has
    /// been persisted. Test doubles without on-disk backups may return nil.
    func beginRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws -> BrowserPrivacyRecoveryLease?
    func finishRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws
    /// Records what the backup belongs to once the outcome is known. The
    /// count limit is applied afterwards; it never removes the backups in
    /// `sparing` (the one a restore has just written back).
    func annotate(
        _ backup: BrowserPrivacyRecoveryBackup,
        summary: BrowserPrivacyRecoverySummary,
        sparing: Set<UUID>
    ) async
    /// Removes a backup whose database was left unchanged.
    func discard(_ backup: BrowserPrivacyRecoveryBackup) async
}

extension BrowserPrivacyDatabaseBackingUp {
    func beginRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws -> BrowserPrivacyRecoveryLease? { nil }
    func finishRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws {}

    func annotate(
        _ backup: BrowserPrivacyRecoveryBackup,
        summary: BrowserPrivacyRecoverySummary
    ) async {
        await annotate(backup, summary: summary, sparing: [])
    }

    func annotate(
        _ backup: BrowserPrivacyRecoveryBackup,
        summary: BrowserPrivacyRecoverySummary,
        sparing: Set<UUID>
    ) async {}

    func discard(_ backup: BrowserPrivacyRecoveryBackup) async {}
}

extension BrowserPrivacyDatabaseBackingUp {
    func restore(
        _ backup: BrowserPrivacyRecoveryBackup,
        destination: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        deadlineNanoseconds: UInt64
    ) async throws {
        throw SQLiteSnapshotFailure.unavailable
    }
}

struct BrowserPrivacyRecoveryBackupService: BrowserPrivacyDatabaseBackingUp, Sendable {
    private struct Metadata: Codable {
        var version: Int
        let backupID: UUID
        let browserID: String
        let profileFingerprint: String
        let createdAt: Date
        var sha256: String
        // Added in version 2; absent in older backups.
        var browserDisplayName: String?
        var profileDisplayName: String?
        var visitCount: Int?
        var pageCount: Int?
        var outcome: BrowserPrivacyRecoveryOutcome?
        var restoredAt: Date?
        // Added for N12. If recording the final result fails or the process
        // exits during a restore, count pruning must still spare its source.
        var restorePending: Bool?
        var continuousCreatedAt: TimeInterval?
        var bootSessionIdentifier: String?
        var rowBackup: Bool?
        var dataContract: BrowserPrivacyDataContract?

        var summary: BrowserPrivacyRecoverySummary? {
            guard let browserDisplayName, let profileDisplayName, let outcome else { return nil }
            return BrowserPrivacyRecoverySummary(
                browserDisplayName: browserDisplayName,
                profileDisplayName: profileDisplayName,
                visitCount: visitCount,
                pageCount: pageCount,
                outcome: outcome,
                dataContract: dataContract
            )
        }
    }

    private static let databaseFileName = "History.backup.sqlite"
    private static let metadataFileName = "metadata.json"
    private static let maximumMetadataBytes = 64 * 1_024

    static var defaultRootURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("BrowserPrivacyRecovery", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private let recoveryRoot: BrowserPrivacyRecoveryRoot
    private let snapshotService: SQLiteSnapshotService
    private let maximumBackups: Int
    private let continuousNow: @Sendable () -> BrowserPrivacyRecoveryClockReading?
    private let excludeFromTimeMachine: @Sendable (URL) throws -> Void
    private let countDigestReader: any CleanupContentDigestReading
    /// Test-only interleaving after choosing a victim, before taking its lease.
    private let beforeRemovalHook: (@Sendable (UUID) -> Void)?
    /// Test seam for deletion after the live path has become a tombstone.
    private let removeTombstone: @Sendable (URL) throws -> Void

    init(
        rootURL: URL = Self.defaultRootURL,
        snapshotService: SQLiteSnapshotService = SQLiteSnapshotService(),
        maximumBackups: Int = BrowserPrivacyBackupRetention.maximumCount,
        continuousNow: @escaping @Sendable () -> BrowserPrivacyRecoveryClockReading? = {
            BrowserPrivacyRecoveryClockReading.current()
        },
        excludeFromTimeMachine: @escaping @Sendable (URL) throws -> Void = {
            try Self.excludeFromTimeMachine($0)
        },
        beforeRemovalHook: (@Sendable (UUID) -> Void)? = nil,
        countDigestReader: any CleanupContentDigestReading = FoundationCleanupContentDigestReader(),
        removeTombstone: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        self.recoveryRoot = BrowserPrivacyRecoveryRoot(url: rootURL)
        self.snapshotService = snapshotService
        self.maximumBackups = min(max(maximumBackups, 1), 64)
        self.continuousNow = continuousNow
        self.excludeFromTimeMachine = excludeFromTimeMachine
        self.beforeRemovalHook = beforeRemovalHook
        self.countDigestReader = countDigestReader
        self.removeTombstone = removeTombstone
    }

    func backup(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        browserID: String,
        profileID: String,
        deadlineNanoseconds: UInt64
    ) async throws -> BrowserPrivacyRecoveryBackup {
        try await createBackup(source: source, schema: schema, browserID: browserID, profileID: profileID,
                               deadlineNanoseconds: deadlineNanoseconds, rows: nil)
    }

    func rowBackup(source: SQLiteSnapshotSource, contract: BrowserPrivacyDataContract,
                   browserID: String, profileID: String, deadlineNanoseconds: UInt64) async throws -> BrowserPrivacyRecoveryBackup {
        try await createBackup(source: source, schema: contract.schema, browserID: browserID, profileID: profileID,
                               deadlineNanoseconds: deadlineNanoseconds, rows: contract)
    }

    private func createBackup(source: SQLiteSnapshotSource, schema: SQLiteSchemaAllowlist, browserID: String,
                              profileID: String, deadlineNanoseconds: UInt64,
                              rows: BrowserPrivacyDataContract?) async throws -> BrowserPrivacyRecoveryBackup {
        let id = UUID()
        let directory: URL
        let root: BrowserPrivacyRecoveryRoot.Directory
        do {
            root = try prepareRecoveryRoot()
            directory = root.url.appendingPathComponent(id.uuidString, isDirectory: true)
            guard mkdirat(root.descriptor, id.uuidString, S_IRWXU) == 0 else {
                throw BrowserPrivacyBackupStorageFailure()
            }
        } catch let failure as BrowserPrivacyBackupStorageFailure {
            throw failure
        } catch {
            throw BrowserPrivacyBackupStorageFailure()
        }
        let databaseURL = directory.appendingPathComponent(Self.databaseFileName)
        let createdAt = Date()
        let clock = continuousNow()
        let writingLease: BrowserPrivacyRecoveryLease
        do {
            writingLease = try BrowserPrivacyRecoveryLease.acquire(in: directory, root: root)
        } catch {
            _ = remove(backupID: id)
            throw BrowserPrivacyBackupStorageFailure()
        }

        do {
            // Errors here mostly come from reading the browser's database
            // and keep their meaning.
            if rows != nil {
                // An empty private database; no source database or sidecar is copied.
                var database: OpaquePointer?
                guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE, nil) == SQLITE_OK,
                      let database else { throw BrowserPrivacyBackupStorageFailure() }
                defer { sqlite3_close(database) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            } else {
            try await snapshotService.createPersistentBackup(
                source: source,
                schema: schema,
                destinationURL: databaseURL,
                busyRetrySeconds: 2,
                deadlineNanoseconds: deadlineNanoseconds
            )
            }
        } catch {
            _ = retireAndRemove(directory, lease: writingLease)
            if (error as? SQLitePersistentBackupFailure) == .destinationWrite {
                throw BrowserPrivacyBackupStorageFailure()
            }
            throw error
        }
        do {
            try root.validate()
            let digest = try FoundationCleanupContentDigestReader().sha256(at: databaseURL)
            let metadata = Metadata(
                version: 3,
                backupID: id,
                browserID: browserID,
                profileFingerprint: Self.profileFingerprint(for: profileID),
                createdAt: createdAt,
                sha256: digest.map { String(format: "%02x", $0) }.joined(),
                continuousCreatedAt: clock?.seconds,
                bootSessionIdentifier: clock?.bootSessionIdentifier,
                rowBackup: rows != nil,
                dataContract: rows
            )
            try Self.write(metadata, in: directory)
            try root.validate()
            return BrowserPrivacyRecoveryBackup(
                id: id,
                databaseURL: databaseURL,
                sha256: digest,
                createdAt: createdAt,
                writingLease: writingLease
            )
        } catch {
            _ = retireAndRemove(directory, lease: writingLease)
            throw BrowserPrivacyBackupStorageFailure()
        }
    }

    /// Persist routing before the first mutation, including interruption paths.
    func setDataContract(_ contract: BrowserPrivacyDataContract, for backup: BrowserPrivacyRecoveryBackup) throws {
        let directory = try liveDirectory(for: backup)
        guard var metadata = Self.metadata(in: directory) else { throw BrowserPrivacyBackupStorageFailure() }
        metadata.dataContract = contract
        try Self.write(metadata, in: directory)

    }

    /// Seal the attached database after its transaction has committed.
    func sealRows(_ backup: BrowserPrivacyRecoveryBackup) throws -> BrowserPrivacyRecoveryBackup {
        let directory = try liveDirectory(for: backup)
        guard var metadata = Self.metadata(in: directory), metadata.rowBackup == true else { throw BrowserPrivacyBackupStorageFailure() }
        let digest = try FoundationCleanupContentDigestReader().sha256(at: backup.databaseURL)
        metadata.sha256 = digest.map { String(format: "%02x", $0) }.joined()
        try Self.write(metadata, in: directory)
        return .init(id: backup.id, databaseURL: backup.databaseURL, sha256: digest, createdAt: backup.createdAt, writingLease: backup.writingLease)
    }

    /// Serialize data runs across processes before checking the separate quota.
    func beginDataRun(batchCount: Int) throws -> BrowserPrivacyDataRunLease {
        let root = try prepareRecoveryRoot()
        let lease = try BrowserPrivacyDataRunLease(root: root)
        let occupied = ownedDirectories().filter { $0.isData && !$0.wasRestored }.count
        guard batchCount <= maximumBackups - occupied else { throw BrowserPrivacyDataFailure.capacity }
        return lease
    }

    func finishDataRun(sparing: Set<UUID>) { _ = pruneToLimit(sparing: sparing) }

    func annotateDataRun(_ backup: BrowserPrivacyRecoveryBackup, summary: BrowserPrivacyRecoverySummary) {
        updateMetadata(of: backup.id) { metadata in
            metadata.browserDisplayName = summary.browserDisplayName
            metadata.profileDisplayName = summary.profileDisplayName
            metadata.visitCount = summary.visitCount
            metadata.outcome = summary.outcome
            metadata.dataContract = summary.dataContract
        }
        // Retain the writing lease until the entire run ends; no per-batch pruning.
    }

    func restore(
        _ backup: BrowserPrivacyRecoveryBackup,
        destination: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        deadlineNanoseconds: UInt64
    ) async throws {
        do {
            _ = try liveDirectory(for: backup)
            guard try FoundationCleanupContentDigestReader().sha256(at: backup.databaseURL)
                == backup.sha256 else {
                throw SQLiteSnapshotFailure.corrupt
            }
            _ = try liveDirectory(for: backup)
        } catch {
            throw SQLitePersistentBackupFailure.sourceRead(error as? SQLiteSnapshotFailure ?? .unavailable)
        }
        try await snapshotService.restorePersistentBackup(
            backupURL: backup.databaseURL,
            destination: destination,
            schema: schema,
            busyRetrySeconds: 2,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    func beginRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws -> BrowserPrivacyRecoveryLease? {
        // The processor's undo storage can be unavailable even while the
        // supplied source backup still exists elsewhere. Check that storage
        // first, without reclassifying a root failure as a missing source.
        let root = try prepareRecoveryRoot()
        let directory = try liveDirectory(for: backup)
        let lease = try BrowserPrivacyRecoveryLease.acquire(in: directory, root: root)
        guard var metadata = Self.metadata(in: directory), metadata.backupID == backup.id else {
            throw SQLiteSnapshotFailure.unavailable
        }
        // Persist before any browser write. The lease protects both count and
        // expiry removal; this marker survives a failed final metadata write.
        metadata.restorePending = true
        do {
            try Self.write(metadata, in: directory)
            try root.validate()
        } catch {
            throw BrowserPrivacyBackupStorageFailure()
        }
        return lease
    }

    func finishRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws {
        let directory = try liveDirectory(for: backup)
        guard var metadata = Self.metadata(in: directory), metadata.backupID == backup.id else {
            throw SQLiteSnapshotFailure.unavailable
        }
        metadata.version = max(metadata.version, 3)
        metadata.restoredAt = Date()
        metadata.restorePending = nil
        try Self.write(metadata, in: directory)
        _ = try recoveryRoot.verified()
    }

    func annotate(
        _ backup: BrowserPrivacyRecoveryBackup,
        summary: BrowserPrivacyRecoverySummary,
        sparing: Set<UUID>
    ) async {
        updateMetadata(of: backup.id) { metadata in
            metadata.version = max(metadata.version, 3)
            metadata.browserDisplayName = summary.browserDisplayName
            metadata.profileDisplayName = summary.profileDisplayName
            metadata.visitCount = summary.visitCount
            metadata.pageCount = summary.pageCount
            metadata.outcome = summary.outcome
            metadata.dataContract = summary.dataContract
        }
        backup.writingLease?.release()
        // Counting waits until a backup is known to be kept, so a deletion
        // that changed nothing never costs an older backup.
        pruneToLimit(sparing: sparing)
    }

    func discard(_ backup: BrowserPrivacyRecoveryBackup) async {
        backup.writingLease?.release()
        _ = remove(backupID: backup.id)
    }

    /// Removes every backup whose retention period has ended, then keeps
    /// at most `maximumBackups` of the rest; the count limit never removes
    /// `sparing`. A folder left without its description (for example by a
    /// crash) still holds a copy of the history and expires by its creation
    /// date; one still being written is new and therefore kept. Returns how
    /// many backups were removed.
    @discardableResult
    func purgeExpired(now: Date = Date(), sparing: Set<UUID> = []) -> Int {
        guard let root = try? recoveryRoot.verified() else { return 0 }
        // A folder an earlier version left without the exclusion gets it now.
        try? excludeFromTimeMachine(root.url)
        guard (try? root.validate()) != nil else { return 0 }
        var removed = purgeTombstones()
        for directory in ownedDirectories() where directory.createdAt.map({
            BrowserPrivacyBackupRetention.expiry(ofBackupCreatedAt: $0) <= now
        }) == true {
            if remove(backupID: directory.id, onlyIf: { current in
                current.createdAt.map { BrowserPrivacyBackupRetention.expiry(ofBackupCreatedAt: $0) <= now } == true
            }) { removed += 1 }
        }
        return removed + pruneToLimit(sparing: sparing)
    }

    /// When the earliest backup on disk expires, including one still being
    /// written; nil when there is none.
    func earliestExpiry() -> Date? {
        ownedDirectories()
            .compactMap(\.createdAt)
            .min()
            .map(BrowserPrivacyBackupRetention.expiry(ofBackupCreatedAt:))
    }

    /// The backups on disk that are still within their retention period,
    /// newest first. Anything that is not a complete, self-consistent backup
    /// directory of this app is skipped.
    func entries(now: Date = Date()) -> [BrowserPrivacyRecoveryEntry] {
        let clock = continuousNow()
        guard let root = try? recoveryRoot.verified(),
              let directories = try? FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let entries = directories.compactMap { directory -> BrowserPrivacyRecoveryEntry? in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  let metadata = Self.metadata(in: directory),
                  metadata.backupID == id,
                  let digest = Self.data(hex: metadata.sha256),
                  metadata.summary != nil || metadata.restoredAt != nil || (
                      Self.mayShowUnfinishedBackup(metadata, clock: clock)
                          && !BrowserPrivacyRecoveryLease.isInUse(in: directory)
                  ) else { return nil }
            let databaseURL = directory.appendingPathComponent(Self.databaseFileName)
            var status = stat()
            guard lstat(databaseURL.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG else { return nil }
            return BrowserPrivacyRecoveryEntry(
                backup: BrowserPrivacyRecoveryBackup(
                    id: id,
                    databaseURL: databaseURL,
                    sha256: digest,
                    createdAt: metadata.createdAt
                ),
                browserID: metadata.browserID,
                profileFingerprint: metadata.profileFingerprint,
                summary: metadata.summary,
                restoredAt: metadata.restoredAt,
                dataContract: metadata.dataContract,
                rowBackup: metadata.rowBackup == true
            )
        }
        .filter {
            $0.expiresAt > now
        }
        .sorted { $0.createdAt > $1.createdAt }
        return (try? root.validate()) != nil ? entries : []
    }

    private struct OwnedDirectory {
        let id: UUID
        /// From the description when there is one, else the folder's creation date.
        let createdAt: Date?
        /// Nil while the deletion or restore behind it is still running.
        let outcome: BrowserPrivacyRecoveryOutcome?
        /// It has been written back to the browser at least once.
        let wasRestored: Bool
        let restorePending: Bool
        /// Metadata and file kind qualify; no database content has been read.
        let mayCountTowardsLimit: Bool
        let isComplete: Bool
        let isData: Bool

        /// Only backups whose operation finished with a known result count
        /// towards the limit, and only until they are restored: one still
        /// being written can neither be pruned nor push an older one out, one
        /// whose result is unknown may be the only way back, and one that was
        /// restored is what the history now matches. All of them still expire.
        var countsTowardsLimit: Bool {
            guard let outcome, !wasRestored, !restorePending, mayCountTowardsLimit, isComplete else { return false }
            return !outcome.leavesTheResultUnknown
        }
    }

    /// A backup without an outcome this young most likely belongs to an
    /// operation that is still running (each step is bounded to 15 s).
    private static let inFlightAllowance: TimeInterval = 120

    private static func mayShowUnfinishedBackup(
        _ metadata: Metadata,
        clock: BrowserPrivacyRecoveryClockReading?
    ) -> Bool {
        // Legacy backups have no comparable reading; the operation that made
        // them belongs to an earlier version. A previous boot cannot still be
        // running either. Never substitute a wall-date elapsed calculation.
        guard let started = metadata.continuousCreatedAt,
              let boot = metadata.bootSessionIdentifier else { return metadata.version < 3 }
        guard let clock, started.isFinite, clock.seconds.isFinite else { return false }
        guard clock.bootSessionIdentifier == boot else { return true }
        return clock.seconds >= started && clock.seconds - started > inFlightAllowance
    }

    private func ownedDirectories() -> [OwnedDirectory] {
        guard let root = try? recoveryRoot.verified(),
              let directories = try? FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let owned = directories.compactMap { directory -> OwnedDirectory? in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  let values = try? directory.resourceValues(forKeys: [
                      .creationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
                  ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return ownedDirectory(
                in: directory, id: id, fallbackCreatedAt: values.creationDate
            )
        }
        return (try? root.validate()) != nil ? owned : []
    }

    private func ownedDirectory(
        in directory: URL, id: UUID, fallbackCreatedAt: Date?, verifyingCount: Bool = false
    ) -> OwnedDirectory {
        let metadata = Self.metadata(in: directory).flatMap { $0.backupID == id ? $0 : nil }
        let databaseURL = directory.appendingPathComponent(Self.databaseFileName)
        var status = stat()
        let isComplete: Bool
        let mayCountTowardsLimit: Bool
        if let metadata, metadata.summary != nil,
           metadata.restoredAt == nil, metadata.restorePending != true,
           metadata.outcome?.leavesTheResultUnknown == false,
           let digest = Self.data(hex: metadata.sha256),
           lstat(databaseURL.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG {
            mayCountTowardsLimit = true
            isComplete = verifyingCount && (try? countDigestReader.sha256(at: databaseURL)) == digest
        } else {
            mayCountTowardsLimit = false
            isComplete = false
        }
        return OwnedDirectory(
            id: id,
            createdAt: metadata?.createdAt ?? fallbackCreatedAt,
            outcome: metadata?.outcome,
            wasRestored: metadata?.restoredAt != nil,
            restorePending: metadata?.restorePending == true,
            mayCountTowardsLimit: mayCountTowardsLimit,
            isComplete: isComplete,
            isData: metadata?.dataContract != nil
        )
    }

    /// Keeps the newest `maximumBackups` of the backups that count towards
    /// the limit; `sparing` is never removed here. Returns how many were
    /// removed.
    @discardableResult
    private func pruneToLimit(sparing: Set<UUID> = []) -> Int {
        guard let root = try? recoveryRoot.verified() else { return 0 }
        let candidates = ownedDirectories().filter {
            $0.mayCountTowardsLimit && !sparing.contains($0.id)
        }
        // Metadata provides an upper bound. At/below the limit nothing can be
        // pruned, so maintenance and annotation must not read database content.
        let pools = Dictionary(grouping: candidates, by: \.isData)
        var removed = 0
        for candidates in pools.values where candidates.count > maximumBackups {
        let newestFirst = candidates.map { candidate in
            ownedDirectory(
                in: root.url.appendingPathComponent(candidate.id.uuidString, isDirectory: true),
                id: candidate.id, fallbackCreatedAt: candidate.createdAt, verifyingCount: true
            )
        }.filter(\.countsTowardsLimit).sorted {
            ($0.createdAt ?? .distantFuture) > ($1.createdAt ?? .distantFuture)
        }
        for directory in newestFirst.dropFirst(maximumBackups) {
            // Recheck under the lease: the victim list may have been made
            // before a concurrent restore acquired and then released it.
            if remove(backupID: directory.id, verifyingCount: true, onlyIf: { $0.countsTowardsLimit }) {
                removed += 1
            }
        }
        }
        return removed
    }

    /// Permanently removes one backup. Returns whether it is gone.
    ///
    /// The path is the recovery root plus the identifier's own spelling, so
    /// it is always one level below the root. `lstat` does not follow a
    /// link: a symbolic link, a plain file or anything else that is not a
    /// real directory is left alone.
    func remove(backupID: UUID) -> Bool {
        remove(backupID: backupID, onlyIf: { _ in true })
    }

    private func remove(
        backupID: UUID, verifyingCount: Bool = false, onlyIf shouldRemove: (OwnedDirectory) -> Bool
    ) -> Bool {
        guard let root = try? recoveryRoot.verified() else { return false }
        let directory = root.url.appendingPathComponent(backupID.uuidString, isDirectory: true)
        var status = stat()
        if lstat(directory.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFDIR else { return false }
            beforeRemovalHook?(backupID)
            guard let lease = try? BrowserPrivacyRecoveryLease.acquire(in: directory, root: root) else { return false }
            defer { withExtendedLifetime(lease) {} }
            guard shouldRemove(ownedDirectory(in: directory, id: backupID, fallbackCreatedAt: (
                try? directory.resourceValues(forKeys: [.creationDateKey])
            )?.creationDate, verifyingCount: verifyingCount)) else { return false }
            guard retireAndRemove(directory, lease: lease) else { return false }
        } else if errno != ENOENT { return false }
        // A vanished live name can mean retirement, not successful erasure.
        guard let retired = try? tombstones(in: root) else { return false }
        for item in retired where item.matches(backupID) {
            guard removeRetiredDirectory(item.url) else { return false }
        }
        return isRemoved(backupID: backupID)
    }

    /// A readback, including retired copies; an unavailable root is unknown.
    func isRemoved(backupID: UUID) -> Bool {
        guard let root = try? recoveryRoot.verified(),
              let retired = try? tombstones(in: root),
              !retired.contains(where: { $0.matches(backupID) }) else { return false }
        var status = stat()
        return lstat(root.url.appendingPathComponent(backupID.uuidString).path, &status) != 0
            && errno == ENOENT && (try? root.validate()) != nil
    }

    /// Separate from restorable entries and available after a new app session.
    /// Nil means the state could not be read; callers must retain prior warnings.
    func pendingRemovalIDs() -> Set<UUID>? {
        guard let root = try? recoveryRoot.verified(), let retired = try? tombstones(in: root) else { return nil }
        return Set(retired.map(\.retryID))
    }

    private func retireAndRemove(_ directory: URL, lease: BrowserPrivacyRecoveryLease) -> Bool {
        defer { withExtendedLifetime(lease) {} }
        guard let tombstone = try? lease.moveToTombstone(in: directory) else { return false }
        return removeRetiredDirectory(tombstone)
    }

    private func removeRetiredDirectory(_ directory: URL) -> Bool {
        // Enumerated URLs can carry a base URL or a different directory-path
        // spelling from the URL returned by rename. Compare canonical parent
        // paths, then anchor deletion and readback to the verified root.
        guard let root = try? recoveryRoot.verified(),
              directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                  == root.url.path else { return false }
        let retired = root.url.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        var status = stat()
        if lstat(retired.path, &status) == 0 {
            // Do not resolve the child itself: a replaced tombstone must not
            // turn into a recursive deletion through a symbolic link.
            guard status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(), status.st_dev == root.device,
                  (try? root.validate()) != nil else { return false }
            try? removeTombstone(retired)
        } else if errno != ENOENT { return false }
        // Neither a successful callback nor another failed attempt is proof
        // that the data is gone. Always read back the retired path itself.
        return lstat(retired.path, &status) != 0 && errno == ENOENT && (try? root.validate()) != nil
    }

    private struct Tombstone {
        let url: URL
        let retryID: UUID
        let sourceUnknown: Bool
        func matches(_ backupID: UUID) -> Bool { retryID == backupID || sourceUnknown }
    }

    private func tombstones(in root: BrowserPrivacyRecoveryRoot.Directory) throws -> [Tombstone] {
        try root.validate()
        let directories = try FileManager.default.contentsOfDirectory(
            at: root.url, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]
        )
        let retired = try directories.compactMap { directory -> Tombstone? in
            let name = directory.lastPathComponent
            guard name.hasPrefix(BrowserPrivacyRecoveryLease.tombstonePrefix) else { return nil }
            let suffix = String(name.dropFirst(BrowserPrivacyRecoveryLease.tombstonePrefix.count))
            let sourceID: UUID?
            let token: UUID
            if suffix.count == 73, suffix[suffix.index(suffix.startIndex, offsetBy: 36)] == "-",
               let source = UUID(uuidString: String(suffix.prefix(36))),
               let unique = UUID(uuidString: String(suffix.suffix(36))) {
                sourceID = source
                token = unique
            } else if let legacyToken = UUID(uuidString: suffix) {
                // Older random-only names can lose metadata during removal.
                // Unknown leftovers must never make an ID retry claim success.
                sourceID = Self.metadata(in: directory)?.backupID
                token = legacyToken
            } else { return nil }
            var status = stat()
            if lstat(directory.path, &status) != 0 {
                if errno == ENOENT { return nil }
                throw BrowserPrivacyBackupStorageFailure()
            }
            guard status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(), status.st_dev == root.device else { return nil }
            return Tombstone(url: directory, retryID: sourceID ?? token, sourceUnknown: sourceID == nil)
        }
        try root.validate()
        return retired
    }

    /// Startup and hourly/page-open maintenance finish interrupted deletions.
    /// Only our hidden UUID tombstones on this root's filesystem are removed;
    /// they never reenter listing, expiry scheduling or restoration.
    private func purgeTombstones() -> Int {
        guard let root = try? recoveryRoot.verified(), root.isPrivate,
              let retired = try? tombstones(in: root) else { return 0 }
        var removed = 0
        for item in retired {
            if removeRetiredDirectory(item.url) { removed += 1 }
        }
        return removed
    }

    static func profileFingerprint(for profileID: String) -> String {
        sha256Hex(Data(profileID.utf8))
    }

    private func prepareRecoveryRoot() throws -> BrowserPrivacyRecoveryRoot.Directory {
        do {
            let root = try recoveryRoot.verified(createIfMissing: true)
            try root.makePrivate()
            // No backup is written where Time Machine would copy it.
            do {
                try excludeFromTimeMachine(root.url)
            } catch {
                throw BrowserPrivacyBackupStorageFailure(timeMachineExclusionFailed: true)
            }
            try root.validate()
            return root
        } catch let failure as BrowserPrivacyBackupStorageFailure {
            throw failure
        } catch {
            throw BrowserPrivacyBackupStorageFailure()
        }
    }

    private func liveDirectory(for backup: BrowserPrivacyRecoveryBackup) throws -> URL {
        let root = try recoveryRoot.verified()
        let directory = backup.databaseURL.deletingLastPathComponent()
        var status = stat()
        guard directory.lastPathComponent == backup.id.uuidString,
              backup.databaseURL.lastPathComponent == Self.databaseFileName,
              directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                  == root.url,
              lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw SQLiteSnapshotFailure.unavailable
        }
        try root.validate()
        return root.url.appendingPathComponent(backup.id.uuidString, isDirectory: true)
    }

    private func updateMetadata(of backupID: UUID, _ change: (inout Metadata) -> Void) {
        guard let root = try? recoveryRoot.verified() else { return }
        let directory = root.url.appendingPathComponent(backupID.uuidString, isDirectory: true)
        guard var metadata = Self.metadata(in: directory), metadata.backupID == backupID else { return }
        change(&metadata)
        try? Self.write(metadata, in: directory)
    }

    private static func metadata(in directory: URL) -> Metadata? {
        var status = stat()
        guard lstat(directory.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else { return nil }
        let url = directory.appendingPathComponent(metadataFileName)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumMetadataBytes + 1),
              data.count <= maximumMetadataBytes else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private static func write(_ metadata: Metadata, in directory: URL) throws {
        let url = directory.appendingPathComponent(metadataFileName)
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw SQLiteSnapshotFailure.permissionDenied
        }
    }

    private static func data(hex: String) -> Data? {
        guard hex.count == 64 else { return nil }
        var data = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Time Machine skips the recovery folder and everything in it: a copy
    /// there would keep the deleted pages long after this app removed its
    /// backup.
    private static func excludeFromTimeMachine(_ directory: URL) throws {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A distinct root-level lock serializes quota reservations without holding the
/// namespace lock used to create each backup directory.
final class BrowserPrivacyDataRunLease: @unchecked Sendable {
    private let descriptor: Int32
    private let root: BrowserPrivacyRecoveryRoot.Directory
    init(root: BrowserPrivacyRecoveryRoot.Directory) throws {
        self.root = root
        let fd = openat(root.descriptor, ".data-run.lease", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BrowserPrivacyBackupStorageFailure() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1, status.st_mode & 0o777 == 0o600 else {
            Darwin.close(fd); throw BrowserPrivacyBackupStorageFailure()
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure: any Error = errno == EWOULDBLOCK || errno == EAGAIN
                ? BrowserPrivacyDataFailure.concurrentOperation : BrowserPrivacyBackupStorageFailure()
            Darwin.close(fd); throw failure
        }
        descriptor = fd
        try root.validate()
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
