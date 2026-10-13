import CSQLite
import Darwin
import Foundation

/// Metadata readers return keys and counts only. Opaque row copying and
/// equality checks stay inside SQLite; Swift never receives payloads.
struct BrowserPrivacyDataService: Sendable {
    let registry: BrowserPrivacyProviderRegistry
    let homeDirectory: URL
    let recovery: BrowserPrivacyRecoveryBackupService
    let snapshots: SQLiteSnapshotService
    let running: any BrowserPrivacyRunningApplicationChecking
    /// Only temporary, explicitly injected profiles can use the fixture gate.
    let fixtureRoot: URL?
    var observeSQL: (@Sendable (String) -> Void)? = nil
    var reportedChanges: (@Sendable (Int) -> Int)? = nil
    var transactionGroups: (@Sendable ([String: Int]) -> [String: Int])? = nil
    var committedGroups: (@Sendable ([String: Int]) -> [String: Int])? = nil
    var afterRowArchive: (@Sendable () throws -> Void)? = nil
    var beforeRestoreReadback: (@Sendable () throws -> Void)? = nil
    var attachmentReadOnly: (@Sendable (String, Bool) -> Void)? = nil
    var restoredChanges: (@Sendable (Int) -> Int)? = nil
    var observeFirefoxWriteProbe: (@Sendable () -> Void)? = nil
    var beforeReadback: (@Sendable () throws -> Void)? = nil

    init(registry: BrowserPrivacyProviderRegistry = .init(),
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         recovery: BrowserPrivacyRecoveryBackupService = .init(),
         snapshots: SQLiteSnapshotService = .init(),
         running: any BrowserPrivacyRunningApplicationChecking = BrowserPrivacyWorkspaceRunningApplicationChecker(),
         fixtureRoot: URL? = nil) {
        self.registry = registry; self.homeDirectory = homeDirectory
        self.recovery = recovery; self.snapshots = snapshots; self.running = running
        self.fixtureRoot = fixtureRoot
    }

    func discover() async -> [BrowserPrivacyProfile] {
        let apps = await BrowserPrivacyApplicationLocator.discoverWithSigningIdentity(homeDirectory: homeDirectory)
        return registry.discover(homeDirectory: homeDirectory, installedApplications: apps).flatMap(\.profiles)
    }

    func scan(profile: BrowserPrivacyProfile, contract: BrowserPrivacyDataContract) async throws -> [BrowserPrivacyDataGroup] {
        guard profile.browser.engine == contract.engine else { throw BrowserPrivacyDataFailure.unsupported }
        let source = source(profile, contract)
        let identities = try identity(source)
        var formatWritable = true
        let scanned = try await snapshots.withSnapshot(source: source, schema: contract.schema,
            busyRetrySeconds: 1, deadlineNanoseconds: deadline) { snapshot in
            try Self.open(snapshot.fileURL, writable: false, observer: observeSQL) { database in
                let groups = try Self.groups(database, contract, observer: observeSQL)
                let writable = (try? Self.validate(database, contract, forWrite: true)) != nil
                return (groups, writable)
            }
        }
        formatWritable = scanned.1
        let groups = scanned.0
        var writeFailure: BrowserPrivacyDataFailure?
        do { try await requireQuit(profile) }
        catch { writeFailure = error as? BrowserPrivacyDataFailure ?? .lockUnverifiable }
        let writable = formatWritable && contract.permitsDeletion && writeRoot(profile, contract) != nil && writeFailure == nil
        guard try identity(source) == identities else { throw BrowserPrivacyDataFailure.changed }
        let rows = groups.map { key, count in
            BrowserPrivacyDataGroup(profile: profile, contract: contract, key: key, count: count,
                  identities: identities, writable: writable, writeFailure: writeFailure)
        }
        // Multiple cookie host spellings/partitions belonging to a site are
        // displayed once, while deletion still binds every original key/count.
        return Dictionary(grouping: rows, by: { $0.site ?? $0.label }).values.map { members in
            let first = members.sorted { $0.key < $1.key }[0]
            return BrowserPrivacyDataGroup(profile: profile, contract: contract, key: first.key,
                count: members.reduce(0) { $0 + $1.count }, identities: identities, writable: writable,
                members: Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.count) }), writeFailure: writeFailure)
        }.sorted { $0.key < $1.key }
    }

    /// The complete selection is reserved before any batch can write.
    func deleteRun(_ groups: [BrowserPrivacyDataGroup], keeping sites: Set<String>) async throws -> Int {
        let batches = Dictionary(grouping: groups) { $0.profile.id + ":" + $0.contract.rawValue }
        guard !batches.isEmpty else { return 0 }
        let runLease = try recovery.beginDataRun(batchCount: batches.count)
        var backups: [BrowserPrivacyRecoveryBackup] = []
        defer {
            let ids = Set(backups.map(\.id))
            recovery.finishDataRun(sparing: ids)
            backups.forEach { $0.writingLease?.release() }
            withExtendedLifetime(runLease) {}
        }
        var count = 0
        for key in batches.keys.sorted() {
            do { count += try await deleteBatch(batches[key]!, keeping: sites, backups: &backups) }
            catch {
                if count > 0 { throw BrowserPrivacyDataRunFailure(completedCount: count, underlying: error) }
                throw error
            }
        }
        return count
    }

    func delete(_ groups: [BrowserPrivacyDataGroup], keeping sites: Set<String>) async throws -> Int {
        try await deleteRun(groups, keeping: sites)
    }

    /// Site protection is checked again at the write boundary.
    private func deleteBatch(_ groups: [BrowserPrivacyDataGroup], keeping sites: Set<String>,
                             backups: inout [BrowserPrivacyRecoveryBackup]) async throws -> Int {
        guard let first = groups.first else { return 0 }
        try await requireQuit(first.profile)
        guard groups.allSatisfy({ $0.profile == first.profile && $0.contract == first.contract && $0.writable }),
              Set(groups.map(\.key)).count == groups.count,
              first.contract.permitsDeletion, writeRoot(first.profile, first.contract) != nil else { throw BrowserPrivacyDataFailure.unsupported }
        let protected = Set(sites.map(BrowserPrivacyDataGroup.normalizedSite))
        let selected = groups.filter { group in
            return !group.isProtected(by: protected)
        }
        guard !selected.isEmpty else { return 0 }
        try await requireQuit(first.profile)
        let source = source(first.profile, first.contract)
        guard try identity(source) == first.identities else { throw BrowserPrivacyDataFailure.changed }
        try Self.requireNoPendingWrites(source)
        var backup = try await makeBackup(source, profile: first.profile, contract: first.contract)
        backups.append(backup)
        var committed = false
        var rowArchiveSealed = false
        do {
            if first.contract.usesRowBackup {
                // Commit and seal the row archive before any deletion. A second
                // transaction rechecks counts, so intervening changes refuse writes.
                try await requireQuit(first.profile)
                try Self.requireNoPendingWrites(source)
                guard try identity(source) == first.identities else { throw BrowserPrivacyDataFailure.changed }
                let sourceStamp = try SecureSourceFile.contentStamp(at: source.databaseURL)
                let before = try Self.open(source.databaseURL, writable: false, observer: observeSQL) { database in
                    try Self.validate(database, first.contract, forWrite: true)
                    return try Self.groups(database, first.contract, observer: observeSQL)
                }
                // The archive is the writable main DB; the stable source is
                // attached read-only/immutable. No source WAL/SHM is created.
                try Self.open(backup.databaseURL, writable: true, observer: observeSQL) { database in
                    try Self.requireProfileUnlocked(first.profile, forWrite: true, observeWriteProbe: observeFirefoxWriteProbe)
                    try attach(database, source.databaseURL, alias: "source", immutable: true)
                    try execute(database, "BEGIN IMMEDIATE")
                    do {
                        try execute(database, "PRAGMA secure_delete=ON")
                        try Self.createRowTable(database, first.contract, sourceSchema: "source", destinationSchema: "main", observer: observeSQL)
                        for group in selected {
                            for (key, count) in group.deletionCounts {
                                guard before[key] == count else { throw BrowserPrivacyDataFailure.changed }
                                try Self.bound(database, "INSERT INTO main.\(first.contract.table) SELECT * FROM source.\(first.contract.table) WHERE \(first.contract.keyColumn)=?1", key: key, observer: observeSQL)
                                guard Int(sqlite3_changes(database)) == count else { throw BrowserPrivacyDataFailure.readback }
                            }
                        }
                        try execute(database, "COMMIT")
                    } catch {
                        do { try execute(database, "ROLLBACK") }
                        catch { throw BrowserPrivacyDataFailure.rollback }
                        throw error
                    }
                }
                guard sourceStamp == (try SecureSourceFile.contentStamp(at: source.databaseURL)) else { throw BrowserPrivacyDataFailure.changed }
                try Self.requireNoPendingWrites(source)
                backup = try recovery.sealRows(backup)
                rowArchiveSealed = true
                backups[backups.count - 1] = backup
                try afterRowArchive?()
            }
            try await requireQuit(first.profile)
            guard try identity(source) == first.identities else { throw BrowserPrivacyDataFailure.changed }
            try Self.requireNoPendingWrites(source)
            let expected = selected.reduce(0) { $0 + $1.count }
            var expectedAfter: [String: Int] = [:]
            let selectedKeys = Set(selected.flatMap { $0.deletionCounts.keys })
            try Self.open(source.databaseURL, writable: true, observer: observeSQL) { database in
                try Self.requireProfileUnlocked(first.profile, forWrite: true, observeWriteProbe: observeFirefoxWriteProbe)
                try Self.validate(database, first.contract, forWrite: true)
                try execute(database, "PRAGMA foreign_keys=ON")
                if first.contract.usesRowBackup { try attach(database, backup.databaseURL) }
                try execute(database, "BEGIN IMMEDIATE")
                do {
                    try execute(database, "PRAGMA secure_delete=ON")
                    try Self.requireTransientWAL(database)
                    try Self.validate(database, first.contract, forWrite: true)
                    let before = try Self.groups(database, first.contract, observer: observeSQL)
                    for group in selected {
                        for (key, count) in group.deletionCounts.sorted(by: { $0.key < $1.key }) {
                            guard before[key] == count else { throw BrowserPrivacyDataFailure.changed }
                            if first.contract.usesRowBackup {
                                try Self.requireArchiveMatches(database, first.contract, key: key, observer: observeSQL)
                            }
                            try Self.remove(database, first.contract, key: key, observer: observeSQL)
                            let actualChanges = Int(sqlite3_changes(database))
                            guard (reportedChanges?(actualChanges) ?? actualChanges) == count else { throw BrowserPrivacyDataFailure.readback }
                        }
                    }
                    try beforeReadback?()
                    let actualAfter = try Self.groups(database, first.contract, observer: observeSQL)
                    let after = transactionGroups?(actualAfter) ?? actualAfter
                    expectedAfter = before.filter { !selectedKeys.contains($0.key) }
                    guard selectedKeys.allSatisfy({ after[$0] == nil }), expectedAfter == after else {
                        throw BrowserPrivacyDataFailure.readback
                    }
                    try execute(database, "COMMIT")
                    committed = true
                } catch {
                    do { try execute(database, "ROLLBACK") }
                    catch { throw BrowserPrivacyDataFailure.rollback }
                    throw error
                }
            }
            // A fresh read-only connection confirms committed counts, not just changes().
            let actual = try Self.open(source.databaseURL, writable: false, observer: observeSQL) { try Self.groups($0, first.contract, observer: observeSQL) }
            let after = committedGroups?(actual) ?? actual
            guard after == expectedAfter else { throw BrowserPrivacyDataFailure.readback }
            recovery.annotateDataRun(backup, summary: summary(first.profile, first.contract, expected, .deleted))
            return expected
        } catch {
            if first.contract.usesRowBackup && !rowArchiveSealed {
                await recovery.discard(backup) // No source row was deleted before sealing.
            } else {
                recovery.annotateDataRun(backup, summary: summary(first.profile, first.contract, nil,
                    committed ? .unverified : (error as? BrowserPrivacyDataFailure == .rollback ? .restoreUnconfirmed : .unexpectedError)))
            }
            throw error
        }
    }

    func restore(_ entry: BrowserPrivacyRecoveryEntry, profiles: [BrowserPrivacyProfile]) async -> BrowserPrivacyRestoreResult {
        guard let contract = entry.dataContract,
              let profile = profiles.first(where: {
                  $0.browser.id == entry.browserID && BrowserPrivacyRecoveryBackupService.profileFingerprint(for: $0.id) == entry.profileFingerprint
              }), profile.browser.engine == contract.engine, writeRoot(profile, contract) != nil else {
            return .init(reason: .profileUnavailable, browserName: entry.summary?.browserDisplayName)
        }
        guard entry.canRestore else { return .init(reason: .unsupportedDataFormat, browserName: profile.browser.displayName, dataType: contract.type) }
        let source = source(profile, contract)
        var undo: BrowserPrivacyRecoveryBackup?
        var wrote = false
        var runLease: BrowserPrivacyDataRunLease?
        defer { undo?.writingLease?.release(); withExtendedLifetime(runLease) {} }
        do {
            runLease = try recovery.beginDataRun(batchCount: contract.usesRowBackup ? 0 : 1)
            try await requireQuit(profile)
            try Self.requireNoPendingWrites(source)
            let identities = try identity(source)
            let lease = try recovery.beginRestoring(entry.backup)
            defer { withExtendedLifetime(lease) {} }
            if contract.usesRowBackup {
                guard entry.rowBackup else { throw BrowserPrivacyDataFailure.unsupported }
                try await requireQuit(profile)
                try Self.requireProfileUnlocked(profile, forWrite: true, observeWriteProbe: observeFirefoxWriteProbe)
                guard try identity(source) == identities else { throw BrowserPrivacyDataFailure.changed }
                guard try FoundationCleanupContentDigestReader().sha256(at: entry.backup.databaseURL) == entry.backup.sha256 else { throw SQLiteSnapshotFailure.corrupt }
                var expectedRows: [String: Int] = [:]
                try Self.requireNoPendingWrites(source)
                try Self.open(source.databaseURL, writable: true, observer: observeSQL) { database in
                    try Self.requireProfileUnlocked(profile, forWrite: true, observeWriteProbe: observeFirefoxWriteProbe)
                    try Self.validate(database, contract, forWrite: true)
                    try execute(database, "PRAGMA foreign_keys=ON")
                    try attach(database, entry.backup.databaseURL)
                    try Self.requireMatchingRowSchema(database, contract)
                    try execute(database, "BEGIN IMMEDIATE")
                    do {
                        try execute(database, "PRAGMA secure_delete=ON")
                        try Self.requireTransientWAL(database)
                        let before = try Self.groups(database, contract, observer: observeSQL)
                        let plan = try Self.restorePlan(database, contract)
                        let expectedAdded = try Self.missingRows(database, contract, keys: plan.keys)
                        wrote = true // A failed rollback must not claim that nothing changed.
                        try execute(database, plan.sql)
                        let actualAdded = Int(sqlite3_changes(database))
                        let added = restoredChanges?(actualAdded) ?? actualAdded
                        guard added == expectedAdded, try Self.missingRows(database, contract, keys: plan.keys) == 0 else { throw BrowserPrivacyDataFailure.readback }
                        let actualTransactionRows = try Self.groups(database, contract, observer: observeSQL)
                        expectedRows = transactionGroups?(actualTransactionRows) ?? actualTransactionRows
                        guard expectedRows.values.reduce(0, +) == before.values.reduce(0, +) + added,
                              before.allSatisfy({ expectedRows[$0.key, default: 0] >= $0.value }) else { throw BrowserPrivacyDataFailure.readback }
                        try execute(database, "COMMIT")
                        wrote = true
                    } catch {
                        do { try execute(database, "ROLLBACK"); wrote = false }
                        catch { throw BrowserPrivacyDataFailure.rollback }
                        throw error
                    }
                }
                // Read-only connection confirms the committed database is readable.
                try beforeRestoreReadback?()
                let actualRows = try Self.open(source.databaseURL, writable: false, observer: observeSQL) { database in
                    // Validate/read first so a closed WAL database can use the
                    // existing guarded immutable fallback before attaching.
                    let groups = try Self.groups(database, contract, observer: observeSQL)
                    try attach(database, entry.backup.databaseURL)
                    let plan = try Self.restorePlan(database, contract)
                    guard try Self.missingRows(database, contract, keys: plan.keys) == 0 else { throw BrowserPrivacyDataFailure.readback }
                    return groups
                }
                guard (committedGroups?(actualRows) ?? actualRows) == expectedRows else { throw BrowserPrivacyDataFailure.readback }
                try recovery.finishRestoring(entry.backup)
                return .init(reason: .restored, browserName: profile.browser.displayName, historyMayHaveChanged: true, dataType: contract.type, rowRestore: true)
            }
            undo = try await makeBackup(source, profile: profile, contract: contract)
            try await requireQuit(profile, forWrite: true)
            guard try identity(source) == identities else { throw BrowserPrivacyDataFailure.changed }
            try Self.requireNoPendingWrites(source)
            let expected = try Self.open(entry.backup.databaseURL, writable: false) { try Self.groups($0, contract) }
            wrote = true
            try await recovery.restore(entry.backup, destination: source, schema: contract.schema, deadlineNanoseconds: deadline)
            try beforeRestoreReadback?()
            let restored = try Self.open(source.databaseURL, writable: false, observer: observeSQL) { try Self.groups($0, contract) }
            guard restored == expected else { throw BrowserPrivacyDataFailure.readback }
            try recovery.finishRestoring(entry.backup)
            if let undo { recovery.annotateDataRun(undo, summary: summary(profile, contract, nil, .savedBeforeRestore)) }
            return .init(reason: .restored, browserName: profile.browser.displayName, undoBackupID: undo?.id, historyMayHaveChanged: true, dataType: contract.type)
        } catch {
            if let undo { recovery.annotateDataRun(undo, summary: summary(profile, contract, nil, wrote ? .unverified : .savedBeforeRestore)) }
            let reason: BrowserPrivacyRestoreReason
            switch error {
            case BrowserPrivacyDataFailure.unsupported: reason = .unsupportedDataFormat
            case BrowserPrivacyDataFailure.browserRunning: reason = .browserRunning
            case BrowserPrivacyDataFailure.pendingWrites: reason = .pendingWrites
            case BrowserPrivacyDataFailure.lockUnverifiable: reason = .profileLockUnverifiable
            case BrowserPrivacyDataFailure.concurrentOperation: reason = .backupInUse
            case BrowserPrivacyDataFailure.capacity: reason = .currentStateNotSaved
            case BrowserPrivacyDataFailure.changed: reason = .databaseChanged
            case is BrowserPrivacyBackupStorageFailure: reason = .currentStateNotSaved
            case SQLiteSnapshotFailure.permissionDenied: reason = .permissionDenied
            case SQLiteSnapshotFailure.busy: reason = .databaseBusy
            default: reason = .failed
            }
            return .init(reason: reason, browserName: profile.browser.displayName, undoBackupID: undo?.id, historyMayHaveChanged: wrote, dataType: contract.type)
        }
    }

    private func makeBackup(_ source: SQLiteSnapshotSource, profile: BrowserPrivacyProfile,
                            contract: BrowserPrivacyDataContract) async throws -> BrowserPrivacyRecoveryBackup {
        if contract.usesRowBackup {
            return try await recovery.rowBackup(source: source, contract: contract,
                browserID: profile.browser.id, profileID: profile.id, deadlineNanoseconds: deadline)
        }
        let backup = try await recovery.backup(source: source, schema: contract.schema,
            browserID: profile.browser.id, profileID: profile.id, deadlineNanoseconds: deadline)
        do { try recovery.setDataContract(contract, for: backup); return backup }
        catch { await recovery.discard(backup); throw error }
    }

    private var deadline: UInt64 { MonotonicClock.now + 15_000_000_000 }
    private func summary(_ profile: BrowserPrivacyProfile, _ contract: BrowserPrivacyDataContract,
                         _ count: Int?, _ outcome: BrowserPrivacyRecoveryOutcome) -> BrowserPrivacyRecoverySummary {
        .init(browserDisplayName: profile.browser.displayName, profileDisplayName: profile.displayName,
              visitCount: count, pageCount: nil, outcome: outcome, dataContract: contract)
    }
    private func source(_ profile: BrowserPrivacyProfile, _ contract: BrowserPrivacyDataContract) -> SQLiteSnapshotSource {
        .init(databaseURL: profile.historyDatabaseURL.deletingLastPathComponent().appendingPathComponent(contract.relativePath),
              trustedParentURL: profile.sourceTrustedParentURL, allowsUnavailableImmutableReadFallback: true)
    }
    private func identity(_ source: SQLiteSnapshotSource) throws -> [BrowserPrivacyPathIdentity] {
        try SecureSourceFile.identityChain(for: source.databaseURL, trustedParent: source.trustedParentURL,
            expectedFinalKind: .regularFile).map { .init(device: $0.device, inode: $0.inode, kind: UInt32($0.kind)) }
    }
    private func writeRoot(_ profile: BrowserPrivacyProfile, _ contract: BrowserPrivacyDataContract) -> URL? {
        if let fixtureRoot {
            let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            let root = fixtureRoot.resolvingSymlinksInPath().path
            if root.hasPrefix(temp), source(profile, contract).databaseURL.path.hasPrefix(fixtureRoot.path + "/") {
                return fixtureRoot
            }
            return nil
        }
        if !Self.permitsDataWriteIdentity(engine: contract.engine, teamIdentifier: profile.browser.signingIdentity?.teamIdentifier) { return nil }
        return registry.provider(id: profile.browser.id)?.descriptor.productionWriteRoot(browser: profile.browser,
            homeDirectory: homeDirectory, databaseURL: source(profile, contract).databaseURL,
            profileParentURL: profile.sourceTrustedParentURL, allowsFirefoxData: true)
    }
    static func permitsDataWriteIdentity(engine: BrowserPrivacyEngine, teamIdentifier: String?) -> Bool {
        engine != .firefox || teamIdentifier == "43AQ936H96"
    }
    private func requireQuit(_ profile: BrowserPrivacyProfile, forWrite: Bool = false) async throws {
        var ids = Set(registry.provider(id: profile.browser.id)?.descriptor.bundleIdentifiers
            ?? profile.browser.bundleIdentifier.map { [$0] } ?? [])
        if profile.browser.engine == .firefox {
            ids.formUnion(["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
                           "app.zen-browser.zen", "io.gitlab.librewolf-community", "net.waterfox.waterfox"])
        }
        guard !ids.isEmpty else { throw BrowserPrivacyDataFailure.unsupported }
        guard await running.runningBundleIdentifiers(matching: ids).isEmpty else { throw BrowserPrivacyDataFailure.browserRunning }
        try Self.requireProfileUnlocked(profile, forWrite: forWrite, observeWriteProbe: observeFirefoxWriteProbe)
    }
    private static func requireProfileUnlocked(_ profile: BrowserPrivacyProfile, forWrite: Bool = false,
                                               observeWriteProbe: (@Sendable () -> Void)? = nil) throws {
        var directory = profile.historyDatabaseURL.deletingLastPathComponent()
        let boundary = profile.sourceTrustedParentURL.standardizedFileURL.path
        repeat {
            let lock = directory.appendingPathComponent(profile.browser.engine == .firefox ? ".parentlock" : "SingletonLock")
            var status = stat()
            if profile.browser.engine == .firefox {
                if forWrite {
                    try requireFirefoxUnlockedForWrite(lock, observeWriteProbe: observeWriteProbe)
                } else {
                    try requireFirefoxUnlocked(lock)
                }
                return
            }
            if lstat(lock.path, &status) == 0 { throw BrowserPrivacyDataFailure.browserRunning }
            guard errno == ENOENT else { throw BrowserPrivacyDataFailure.lockUnverifiable }
            if directory.standardizedFileURL.path == boundary { break }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path, parent.path == boundary || parent.path.hasPrefix(boundary + "/") else { break }
            directory = parent
        } while profile.browser.engine == .chromium
    }
    /// Firefox leaves .parentlock after exit. Read-only callers only query
    /// POSIX record locks; they never acquire a lock or create/remove a file.
    static func requireFirefoxUnlocked(_ url: URL) throws {
        try withFirefoxLockQuery(url) { _ in }
    }
    /// At a write boundary, query first and then briefly try flock. flock and
    /// POSIX record locks have distinct ownership semantics on macOS, so retain
    /// this nonblocking probe for flock holders; no F_SETLK probe is necessary.
    static func requireFirefoxUnlockedForWrite(_ url: URL,
                                               observeWriteProbe: (@Sendable () -> Void)? = nil) throws {
        try withFirefoxLockQuery(url) { fd in
            observeWriteProbe?()
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw BrowserPrivacyDataFailure.browserRunning }
                throw BrowserPrivacyDataFailure.lockUnverifiable
            }
            guard flock(fd, LOCK_UN) == 0 else { throw BrowserPrivacyDataFailure.lockUnverifiable }
        }
    }
    private static func withFirefoxLockQuery(_ url: URL, operation: (Int32) throws -> Void) throws {
        var pathStatus = stat()
        if lstat(url.path, &pathStatus) != 0 {
            guard errno == ENOENT else { throw BrowserPrivacyDataFailure.lockUnverifiable }
            return
        }
        guard pathStatus.st_mode & S_IFMT == S_IFREG else { throw BrowserPrivacyDataFailure.lockUnverifiable }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BrowserPrivacyDataFailure.lockUnverifiable }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == pathStatus.st_dev,
              opened.st_ino == pathStatus.st_ino else { throw BrowserPrivacyDataFailure.lockUnverifiable }
        var record = Darwin.flock()
        record.l_type = Int16(F_WRLCK); record.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &record) != -1 else { throw BrowserPrivacyDataFailure.lockUnverifiable }
        guard record.l_type == Int16(F_UNLCK) else { throw BrowserPrivacyDataFailure.browserRunning }
        try operation(fd)
        guard lstat(url.path, &pathStatus) == 0, pathStatus.st_dev == opened.st_dev,
              pathStatus.st_ino == opened.st_ino else { throw BrowserPrivacyDataFailure.lockUnverifiable }
    }
    private static func requireNoPendingWrites(_ source: SQLiteSnapshotSource) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let url = URL(fileURLWithPath: source.databaseURL.path + suffix)
            var status = stat()
            if lstat(url.path, &status) != 0 {
                guard errno == ENOENT else { throw BrowserPrivacyDataFailure.pendingWrites }
                continue
            }
            _ = try SecureSourceFile.identityChain(for: url, trustedParent: source.trustedParentURL, expectedFinalKind: .regularFile)
            guard status.st_size == 0 else { throw BrowserPrivacyDataFailure.pendingWrites }
        }
    }
    static func open<T>(_ url: URL, writable: Bool, observer: (@Sendable (String) -> Void)? = nil, operation: (OpaquePointer) throws -> T) throws -> T {
        // Reuse the history writer's realpath + identity-chain boundary;
        // Foundation may reintroduce /var aliases when resolving a URL.
        let parent = url.deletingLastPathComponent()
        let identity = try SecureSourceFile.identityChain(for: url, trustedParent: parent, expectedFinalKind: .regularFile)
        let canonical = try SecureSourceFile.canonicalizedURL(for: url, trustedParent: parent, expectedIdentityChain: identity)
        let checked: (OpaquePointer) throws -> T = { database in
            guard try SecureSourceFile.identityChain(for: url, trustedParent: parent, expectedFinalKind: .regularFile) == identity else { throw BrowserPrivacyDataFailure.changed }
            if let observer {
                let recorder = SQLRecorder(observer)
                let context = Unmanaged.passUnretained(recorder).toOpaque()
                sqlite3_trace_v2(database, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
                    guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                    Unmanaged<SQLRecorder>.fromOpaque(context).takeUnretainedValue().observe(String(cString: sql))
                    return 0
                }, context)
                defer { sqlite3_trace_v2(database, 0, nil, nil); withExtendedLifetime(recorder) {} }
                return try operation(database)
            }
            return try operation(database)
        }
        let control = SQLiteExecutionControl(deadlineNanoseconds: MonotonicClock.now + 10_000_000_000)
        if writable {
            return try SQLiteRuntime.withWritableDatabase(at: canonical, control: control,
                busyDeadlineNanoseconds: MonotonicClock.now + 1_000_000_000, forbidSymbolicLinks: true,
                uriFilenames: true, operation: checked)
        }
        return try SQLiteRuntime.withReadOnlyDatabase(at: canonical, control: control,
            busyDeadlineNanoseconds: MonotonicClock.now + 1_000_000_000, forbidSymbolicLinks: true,
            immutableFallbackOnUnavailable: true, operation: checked)
    }
    private final class SQLRecorder {
        let observe: @Sendable (String) -> Void
        init(_ observe: @escaping @Sendable (String) -> Void) { self.observe = observe }
    }
    /// macOS SQLite can persist empty WAL/SHM files. Disable persistence on
    /// this writer so SQLite performs its normal last-connection cleanup;
    /// never unlink browser sidecars ourselves or change journal mode.
    private static func requireTransientWAL(_ database: OpaquePointer) throws {
        var persist: Int32 = 0
        guard sqlite3_file_control(database, "main", SQLITE_FCNTL_PERSIST_WAL, &persist) == SQLITE_OK else {
            throw BrowserPrivacyDataFailure.database
        }
    }
    static func exec(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw BrowserPrivacyDataFailure.database }
    }
    private static func validate(_ database: OpaquePointer, _ contract: BrowserPrivacyDataContract, forWrite: Bool = false) throws {
        let control = SQLiteExecutionControl(deadlineNanoseconds: MonotonicClock.now + 10_000_000_000)
        try SQLiteRuntime.validate(schema: contract.schema, database: database, control: control,
                                  busyDeadlineNanoseconds: MonotonicClock.now + 1_000_000_000)
        guard forWrite else { return } // Reading metadata never executes a trigger or FK cascade.
        // Unknown triggers could touch passwords/cards. Never execute them.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' OR (type='table' AND (upper(sql) LIKE '%REFERENCES%' OR upper(sql) LIKE '%VIRTUAL TABLE%'))", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw BrowserPrivacyDataFailure.database }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 0 else { throw BrowserPrivacyDataFailure.unsupported }
        if contract.usesRowBackup { _ = try restorePlan(database, contract) }
    }
    static func groups(_ database: OpaquePointer, _ contract: BrowserPrivacyDataContract, observer: (@Sendable (String) -> Void)? = nil) throws -> [String: Int] {
        try validate(database, contract)
        let sql = contract == .chromiumDownloads
            ? "SELECT 'downloads', COUNT(*) FROM downloads HAVING COUNT(*) > 0"
            : "SELECT \(contract.keyColumn), COUNT(*) FROM \(contract.table) GROUP BY \(contract.keyColumn) ORDER BY \(contract.keyColumn) LIMIT 10001"
        observer?(sql)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw BrowserPrivacyDataFailure.database }
        defer { sqlite3_finalize(statement) }
        var result: [String: Int] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0), sqlite3_column_bytes(statement, 0) <= 2048,
                  result.count < 10000 else { throw BrowserPrivacyDataFailure.unsupported }
            let key = String(cString: text)
            let count = sqlite3_column_int64(statement, 1)
            guard count > 0, count <= Int64(Int.max) else { throw BrowserPrivacyDataFailure.database }
            result[key] = Int(count)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw BrowserPrivacyDataFailure.database }
        return result
    }
    private static func remove(_ database: OpaquePointer, _ contract: BrowserPrivacyDataContract, key: String, observer: (@Sendable (String) -> Void)?) throws {
        if contract == .chromiumDownloads {
            // Only record tables; never read a download path or remove a file.
            let rules = [("downloads_url_chains", "id"), ("downloads_slices", "download_id"), ("downloads_reroute_info", "download_id")]
            let tables = try strings(database, "SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,10)='downloads_'")
            guard Set(tables).isSubset(of: Set(rules.map { $0.0 })) else { throw BrowserPrivacyDataFailure.unknownDownloadTable }
            for (table, foreignKey) in rules where tables.contains(table) {
                let control = SQLiteExecutionControl(deadlineNanoseconds: MonotonicClock.now + 1_000_000_000)
                let columns = try SQLiteRuntime.tableColumns(table, database: database, control: control,
                    busyDeadlineNanoseconds: MonotonicClock.now + 1_000_000_000)
                guard columns.contains(foreignKey) else { throw BrowserPrivacyDataFailure.unknownDownloadTable }
                let sql = "DELETE FROM \(table) WHERE \(foreignKey) IN (SELECT id FROM downloads)"
                observer?(sql); try exec(database, sql)
            }
            try exec(database, "DELETE FROM downloads")
            return
        }
        try bound(database, "DELETE FROM \(contract.table) WHERE \(contract.keyColumn) = ?1", key: key, observer: observer)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws { observeSQL?(sql); try Self.exec(database, sql) }
    private func attach(_ database: OpaquePointer, _ url: URL, alias: String = "saved", immutable: Bool = false) throws {
        let parent = url.deletingLastPathComponent()
        let identities = try SecureSourceFile.identityChain(for: url, trustedParent: parent, expectedFinalKind: .regularFile)
        let canonical = try SecureSourceFile.canonicalizedURL(for: url, trustedParent: parent, expectedIdentityChain: identities)
        guard alias == "saved" || alias == "source" else { throw BrowserPrivacyDataFailure.unsupported }
        if immutable { guard try SecureSourceFile.allowsImmutableSQLiteRead(at: canonical) else { throw BrowserPrivacyDataFailure.pendingWrites } }
        let sql = "ATTACH DATABASE ?1 AS \(alias)"
        let path = canonical.absoluteString + (immutable ? "?mode=ro&immutable=1" : "?mode=ro")
        try Self.bound(database, sql, key: path, observer: observeSQL)
        attachmentReadOnly?(alias, sqlite3_db_readonly(database, alias) == 1)
        guard try SecureSourceFile.identityChain(for: url, trustedParent: parent, expectedFinalKind: .regularFile) == identities else { throw BrowserPrivacyDataFailure.changed }
    }
    private static func strings(_ database: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw BrowserPrivacyDataFailure.database }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { throw BrowserPrivacyDataFailure.unsupported }
            result.append(String(cString: text)); status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw BrowserPrivacyDataFailure.database }
        return result
    }
    private static func createRowTable(_ database: OpaquePointer, _ contract: BrowserPrivacyDataContract,
                                       sourceSchema: String, destinationSchema: String,
                                       observer: (@Sendable (String) -> Void)?) throws {
        let table = contract.table // Fixed adapter; never accepts an arbitrary table.
        let definitions = try strings(database, "SELECT sql FROM \(sourceSchema).sqlite_master WHERE type='table' AND name='\(table)'")
        guard let definition = definitions.first, definitions.count == 1,
              let opening = definition.firstIndex(of: "(") else { throw BrowserPrivacyDataFailure.unsupported }
        guard definition.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("CREATE TABLE") else { throw BrowserPrivacyDataFailure.unsupported }
        let sql = "CREATE TABLE \(destinationSchema).\(table) " + definition[opening...]
        observer?(sql); try executeSchemaStatement(database, sql)
        // Preserve uniqueness so INSERT OR IGNORE can preserve newer conflicting rows.
        let indexes = try strings(database, "SELECT sql FROM \(sourceSchema).sqlite_master WHERE type='index' AND tbl_name='\(table)' AND sql IS NOT NULL")
        for (index, definition) in indexes.enumerated() where definition.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("CREATE UNIQUE INDEX") {
            guard let opening = definition.firstIndex(of: "(") else { throw BrowserPrivacyDataFailure.unsupported }
            let sql = "CREATE UNIQUE INDEX \(destinationSchema).row_unique_\(index) ON \(table) " + definition[opening...]
            observer?(sql); try executeSchemaStatement(database, sql)
        }
        let unique = try strings(database, "SELECT name FROM pragma_index_list('\(table)', '\(sourceSchema)') WHERE \"unique\"=1")
        let columns = try strings(database, "SELECT name FROM pragma_table_info('\(table)', '\(sourceSchema)') WHERE pk>0")
        guard !unique.isEmpty || !columns.isEmpty else { throw BrowserPrivacyDataFailure.unsupported }
    }
    /// DDL from sqlite_master is untrusted. Never pass it to sqlite3_exec.
    static func executeSchemaStatement(_ database: OpaquePointer, _ sql: String) throws {
        let prefix = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard prefix.hasPrefix("CREATE TABLE ") || prefix.hasPrefix("CREATE UNIQUE INDEX ") else { throw BrowserPrivacyDataFailure.unsupported }
        try sql.withCString { buffer in
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let status = sqlite3_prepare_v2(database, buffer, -1, &statement, &tail)
            defer { if let statement { sqlite3_finalize(statement) } }
            guard status == SQLITE_OK, let statement,
                  tail.map({ String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true else { throw BrowserPrivacyDataFailure.unsupported }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw BrowserPrivacyDataFailure.database }
        }
    }
    private static func quotedColumn(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func restorePlan(_ database: OpaquePointer, _ contract: BrowserPrivacyDataContract) throws -> (sql: String, keys: [String]) {
        let table = contract.table
        let columns = try strings(database, "SELECT name FROM main.pragma_table_info('\(table)') ORDER BY cid")
        let indexes = try strings(database, "SELECT name FROM main.pragma_index_list('\(table)') WHERE \"unique\"=1 AND partial=0 ORDER BY seq")
        var keySets: [[String]] = []
        for index in indexes {
            let escaped = index.replacingOccurrences(of: "'", with: "''")
            let keys = try strings(database, "SELECT name FROM main.pragma_index_info('\(escaped)') ORDER BY seqno")
            guard !keys.isEmpty else { throw BrowserPrivacyDataFailure.unsupported }
            keySets.append(keys)
        }
        let keys: [String]
        if contract == .firefoxCookies {
            keys = ["name", "host", "path", "originAttributes"]
            guard keySets.contains(keys), columns.contains("id") else { throw BrowserPrivacyDataFailure.unsupported }
        } else {
            guard keySets.count == 1, let unique = keySets.first else { throw BrowserPrivacyDataFailure.unsupported }
            keys = unique
        }
        let copied = columns.filter { contract != .firefoxCookies || $0 != "id" }.map(quotedColumn).joined(separator: ",")
        return ("INSERT OR IGNORE INTO main.\(table) (\(copied)) SELECT \(copied) FROM saved.\(table)", keys)
    }
    /// Only COUNT crosses the SQLite boundary, including autofill natural keys.
    private static func missingRows(_ database: OpaquePointer, _ contract: BrowserPrivacyDataContract, keys: [String]) throws -> Int {
        let match = keys.map { "m.\(quotedColumn($0)) IS s.\(quotedColumn($0))" }.joined(separator: " AND ")
        let counts = try strings(database, "SELECT COUNT(*) FROM saved.\(contract.table) s WHERE NOT EXISTS (SELECT 1 FROM main.\(contract.table) m WHERE \(match))")
        guard let text = counts.first, let count = Int(text) else { throw BrowserPrivacyDataFailure.database }
        return count
    }
    private static func requireMatchingRowSchema(_ database: OpaquePointer, _ contract: BrowserPrivacyDataContract) throws {
        let table = contract.table
        let main = try strings(database, "SELECT name || ':' || type || ':' || pk FROM main.pragma_table_info('\(table)')")
        let saved = try strings(database, "SELECT name || ':' || type || ':' || pk FROM pragma_table_info('\(table)', 'saved')")
        guard !main.isEmpty, main == saved else { throw BrowserPrivacyDataFailure.changed }
        func keys(_ schema: String) throws -> Set<String> {
            let indexes = try strings(database, "SELECT name FROM pragma_index_list('\(table)', '\(schema)') WHERE \"unique\"=1")
            var result: Set<String> = []
            for index in indexes {
                let escaped = index.replacingOccurrences(of: "'", with: "''")
                let columns = try strings(database, "SELECT name FROM pragma_index_info('\(escaped)', '\(schema)') ORDER BY seqno")
                guard !columns.isEmpty else { throw BrowserPrivacyDataFailure.unsupported }
                result.insert(columns.joined(separator: ":"))
            }
            return result
        }
        guard try keys("main") == keys("saved") else { throw BrowserPrivacyDataFailure.changed }
    }
    /// SQLite compares opaque rows; Swift receives only the difference count.
    /// This closes the same-count replacement gap between archive and deletion.
    private static func requireArchiveMatches(_ database: OpaquePointer, _ contract: BrowserPrivacyDataContract,
                                               key: String, observer: (@Sendable (String) -> Void)?) throws {
        for (lhs, rhs) in [("main", "saved"), ("saved", "main")] {
            let sql = "SELECT COUNT(*) FROM (SELECT * FROM \(lhs).\(contract.table) WHERE \(contract.keyColumn)=?1 EXCEPT SELECT * FROM \(rhs).\(contract.table) WHERE \(contract.keyColumn)=?1)"
            observer?(sql)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw BrowserPrivacyDataFailure.database }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, transient) }) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 0 else { throw BrowserPrivacyDataFailure.changed }
        }
    }
    private static func bound(_ database: OpaquePointer, _ sql: String, key: String,
                               observer: (@Sendable (String) -> Void)?) throws {
        observer?(sql)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw BrowserPrivacyDataFailure.database }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, transient) }) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw BrowserPrivacyDataFailure.database }
    }
}
