import Darwin
import Foundation

/// Write-ahead evidence owned by CleanReportStore, not a second operation/history
/// service. An interrupted in-flight entry is never retried automatically.
struct CleanupReportJournal: Sendable {
    struct Entry: Codable, Sendable {
        let schemaVersion: Int
        let expectedIdentities: [String: FileIdentity]
        let report: CleanReport
    }
    let directory: URL
    static var live: Self {
        Self(directory: AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("CleanupReports", isDirectory: true))
    }
    enum Failure: Error { case unsafePath, invalidEntry, tooLarge, staleRevision }

    func checkpoint(_ report: CleanReport, expectedIdentities: [String: FileIdentity]) throws {
        _ = try checkpointVersioned(report, expectedIdentities: expectedIdentities)
    }

    /// Read the latest sequence only after obtaining the process-shared lock.
    /// Recovery supplies its observed sequence, so an intervening writer fails
    /// before any further file move can begin.
    func checkpointVersioned(_ report: CleanReport, expectedIdentities: [String: FileIdentity],
                             expectedSequence: UInt64? = nil) throws -> UInt64 {
        let processLock = try OperationFileLock(directory: directory,
            name: report.planID.rawValue.uuidString + ".lock", wait: true)
        defer { withExtendedLifetime(processLock) {} }
        return try CleanupJournalEvents.shared.synchronized {
            try checkpointLocked(report, expectedIdentities: expectedIdentities, expectedSequence: expectedSequence)
        }
    }

    private func checkpointLocked(_ report: CleanReport, expectedIdentities: [String: FileIdentity],
                                  expectedSequence: UInt64?) throws -> UInt64 {
        let fm = FileManager.default
        guard directory.isFileURL,
              ancestorsAreSafe(directory) else {
            throw Failure.unsafePath
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        guard !PathSafety.containsSymbolicLinkComponent(in: directory.path) else {
            throw Failure.unsafePath
        }
        let url = directory.appendingPathComponent(report.planID.rawValue.uuidString + ".json")
        guard ancestorsAreSafe(url) else { throw Failure.unsafePath }
        var identities = expectedIdentities
        if fm.fileExists(atPath: url.path) {
            let previous = try readWithEventsLocked(url)
            if let expectedSequence, previous.sequence != expectedSequence { throw Failure.staleRevision }
            guard previous.entry.report.planID == report.planID else { throw Failure.invalidEntry }
            if identities.isEmpty { identities = previous.entry.expectedIdentities }
            // Once registered, the source identity of an intent is immutable.
            guard identities == previous.entry.expectedIdentities else { throw Failure.invalidEntry }
            try CleanupJournalEvents.shared.append(report, to: url, previous: previous)
            refreshIndex(report)
            return previous.sequence + 1
        }
        if expectedSequence != nil { throw Failure.staleRevision }
        let events = CleanupJournalEvents.eventURL(for: url)
        guard !fm.fileExists(atPath: events.path), ancestorsAreSafe(events) else { throw Failure.invalidEntry }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Entry(schemaVersion: 1, expectedIdentities: identities, report: report))
        guard data.count <= 16 * 1024 * 1024 else { throw Failure.tooLarge }
        try data.write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafePath }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.unsafePath }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
        refreshIndex(report)
        return 0
    }

    private func ancestorsAreSafe(_ url: URL) -> Bool {
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path) {
            // lstat also catches broken links, which fileExists ignores.
            if (try? FileManager.default.attributesOfItem(atPath: existing.path)) != nil { return false }
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { return false }
            existing = parent
        }
        return !PathSafety.containsSymbolicLinkComponent(in: existing.path)
    }

    func read(_ url: URL) throws -> Entry {
        try readWithEvents(url).entry
    }

    func readWithEvents(_ url: URL) throws -> CleanupJournalEvents.Loaded {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { throw Failure.unsafePath }
        let processLock = try OperationFileLock(directory: directory,
            name: url.deletingPathExtension().lastPathComponent + ".lock", wait: true)
        defer { withExtendedLifetime(processLock) {} }
        return try readWithEventsLocked(url)
    }

    private func readWithEventsLocked(_ url: URL) throws -> CleanupJournalEvents.Loaded {
        guard ancestorsAreSafe(url), ancestorsAreSafe(CleanupJournalEvents.eventURL(for: url)) else {
            throw Failure.unsafePath
        }
        return try CleanupJournalEvents.shared.load(baseURL: url) { try readBase(url) }
    }

    private func readBase(_ url: URL) throws -> Entry {
        guard !PathSafety.containsSymbolicLinkComponent(in: url.path) else { throw Failure.unsafePath }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= 16 * 1024 * 1024 else { throw Failure.tooLarge }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
        guard entry.schemaVersion == 1,
              url.lastPathComponent == entry.report.planID.rawValue.uuidString + ".json" else {
            throw Failure.invalidEntry
        }
        return entry
    }

    struct LoadResult: Sendable {
        let reports: [CleanReport]
        /// Local file names only. Corrupt evidence is retained for review.
        let unreadableEntries: [String]
    }

    func loadAvailable() throws -> LoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return LoadResult(reports: [], unreadableEntries: [])
        }
        guard !PathSafety.containsSymbolicLinkComponent(in: directory.path) else { throw Failure.unsafePath }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        var reports: [CleanReport] = []
        var unreadable: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let loaded = try readWithEvents(file)
                reports.append(loaded.entry.report)
                if loaded.damagedSuffix { unreadable.append(CleanupJournalEvents.eventURL(for: file).lastPathComponent) }
            }
            catch { unreadable.append(file.lastPathComponent) }
        }
        return LoadResult(reports: reports, unreadableEntries: unreadable)
    }

    func load() throws -> [CleanReport] { try loadAvailable().reports }
}

extension CleanupReportJournal {
    enum ReconcileIssue: Sendable, Equatable, Hashable {
        /// ~/.Trash could not be listed, so interrupted moves stay unresolved.
        case trashNotReadable
        case trashMovesFailed
        case recoveriesFailed
    }

    /// Listing ~/.Trash failed; other failures are not a Trash permission issue.
    struct TrashListingFailure: Error { let underlying: Error }

    /// Both passes always run: an unreadable Trash must not also leave
    /// interrupted restores unresolved. Call only while holding the restore lease.
    func reconcileInterruptedOperations(
        trashRoot: URL = CleanupService.userTrashURL()
    ) -> Set<ReconcileIssue> {
        let reports: [CleanReport]
        do { reports = try loadAvailable().reports }
        catch { return [.trashMovesFailed, .recoveriesFailed] }
        var issues = Set<ReconcileIssue>()
        do { try reconcileInterruptedTrashMoves(trashRoot: trashRoot, reports: reports) }
        catch let failure as TrashListingFailure {
            let denied = UninstallErrorEvidence.chain(failure.underlying).contains {
                ($0.domain == NSCocoaErrorDomain && $0.code == NSFileReadNoPermissionError)
                    || ($0.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains($0.code))
            }
            issues.insert(denied ? .trashNotReadable : .trashMovesFailed)
        } catch { issues.insert(.trashMovesFailed) }
        do { try reconcileInterruptedRecoveries(reports: reports) }
        catch { issues.insert(.recoveriesFailed) }
        return issues
    }

    /// Reconcile only ambiguous Trash calls after their workers have stopped.
    /// This reads identities and updates evidence; it never moves or overwrites a file.
    func reconcileInterruptedTrashMoves(trashRoot: URL = CleanupService.userTrashURL()) throws {
        try reconcileInterruptedTrashMoves(trashRoot: trashRoot, reports: loadAvailable().reports)
    }

    private func reconcileInterruptedTrashMoves(trashRoot: URL, reports: [CleanReport]) throws {
        let pending = reports.filter { report in
            report.rulesVersion != "migration.staging.v1" && report.rulesVersion != "benchmark.fixture.v1"
                && report.disposition == .trash
                && report.items.contains { item in
                    if case .failed(let failure) = item.outcome { return failure.code == .moveOutcomeUnknown }
                    return false
                }
        }
        guard !pending.isEmpty,
              !PathSafety.containsSymbolicLinkComponent(in: trashRoot.path) else { return }
        let reader = FoundationReadOnlyFileSystem()
        let children: [URL]
        do { children = try FileManager.default.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil) }
        catch { throw TrashListingFailure(underlying: error) }
        // Bounded review: exceeding this limit leaves ambiguous entries intact.
        guard children.count <= 10_000 else { return }
        var byIdentity: [FileIdentity: [URL]] = [:]
        for child in children {
            guard let snapshot = try? reader.snapshot(at: child), !snapshot.hasSymbolicLinkComponent else { continue }
            byIdentity[snapshot.identity, default: []].append(child)
        }
        // One unreadable or unwritable receipt must not hold back the others.
        var firstFailure: Error?
        for report in pending {
            do { try reconcileTrashMoves(in: report, byIdentity: byIdentity, reader: reader) }
            catch { firstFailure = firstFailure ?? error }
        }
        if let firstFailure { throw firstFailure }
    }

    private func reconcileTrashMoves(in report: CleanReport, byIdentity: [FileIdentity: [URL]],
                                     reader: FoundationReadOnlyFileSystem) throws {
        let entry = try read(directory.appendingPathComponent(report.planID.rawValue.uuidString + ".json"))
        var changed = false
        let items = report.items.map { item -> CleanReportItem in
            guard case .failed(let failure) = item.outcome, failure.code == .moveOutcomeUnknown,
                  let expected = entry.expectedIdentities[item.sourcePath],
                  let matches = byIdentity[expected], matches.count == 1, let target = matches.first else { return item }
            if let current = try? reader.snapshot(at: URL(fileURLWithPath: item.sourcePath)), current.identity == expected {
                return item
            }
            guard let immediate = try? reader.snapshot(at: target), immediate.identity == expected,
                  !immediate.hasSymbolicLinkComponent else { return item }
            changed = true
            return CleanReportItem(id: item.id, planItemID: item.planItemID, ruleID: item.ruleID,
                sourcePath: item.sourcePath, estimatedBytes: item.estimatedBytes,
                outcome: .moved(CleanupMoveReceipt(originalPath: item.sourcePath,
                    resultingItemURL: target, disposition: .trash, movedIdentity: expected,
                    verification: .identityVerified, movedAt: report.completedAt)), ruleRevision: item.ruleRevision)
        }
        guard changed else { return }
        var moved = 0, skipped = 0, failed = 0, notProcessed = 0, unverified = 0, deleted = 0
        var bytes: Int64 = 0, deletedBytes: Int64 = 0
        for item in items {
            switch item.outcome {
            case .moved(let receipt):
                moved += 1; bytes += max(0, item.estimatedBytes)
                if !receipt.isRestorable { unverified += 1 }
            case .skipped: skipped += 1
            case .failed: failed += 1
            case .notProcessed: notProcessed += 1
            case .deleted: deleted += 1; deletedBytes += max(0, item.estimatedBytes)
            }
        }
        let updated = CleanReport(id: report.id, planID: report.planID, sessionID: report.sessionID,
            rulesVersion: report.rulesVersion, disposition: report.disposition, scanWasPartial: report.scanWasPartial,
            startedAt: report.startedAt, completedAt: report.completedAt,
            // A user cancellation stays a cancellation; only item evidence changes.
            outcome: report.outcome == .cancelled ? .cancelled
                : failed + notProcessed + unverified == 0 ? .completed : .partiallyCompleted,
            items: items, summary: CleanReportSummary(requestedItemCount: report.summary.requestedItemCount,
                movedItemCount: moved, skippedItemCount: skipped, failedItemCount: failed,
                notProcessedItemCount: notProcessed, unverifiedMoveCount: unverified,
                plannedBytes: report.summary.plannedBytes, movedToRecoverableLocationBytes: bytes,
                reclaimableAfterEmptyingTrashBytes: bytes, permanentlyFreedBytes: deletedBytes,
                availableSpaceDeltaBytes: report.summary.availableSpaceDeltaBytes,
                deletedItemCount: deleted),
            persistenceFailure: report.persistenceFailure, recoveryAttempts: report.recoveryAttempts,
            restoreAuthorizations: report.restoreAuthorizations, uninstallOwnership: report.uninstallOwnership,
            rulesProvenance: report.rulesProvenance)
        try checkpoint(updated, expectedIdentities: entry.expectedIdentities)
    }
}
