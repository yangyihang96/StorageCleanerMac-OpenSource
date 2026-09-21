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
    enum Failure: Error { case unsafePath, invalidEntry, tooLarge }

    func checkpoint(_ report: CleanReport, expectedIdentities: [String: FileIdentity]) throws {
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
            let previous = try read(url)
            guard previous.report.planID == report.planID else { throw Failure.invalidEntry }
            if identities.isEmpty { identities = previous.expectedIdentities }
            // Once registered, the source identity of an intent is immutable.
            guard identities == previous.expectedIdentities else { throw Failure.invalidEntry }
        }
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
            do { reports.append(try read(file).report) }
            catch { unreadable.append(file.lastPathComponent) }
        }
        return LoadResult(reports: reports, unreadableEntries: unreadable)
    }

    func load() throws -> [CleanReport] { try loadAvailable().reports }
}

extension CleanupReportJournal {
    /// Reconcile only ambiguous Trash calls after their workers have stopped.
    /// This reads identities and updates evidence; it never moves or overwrites a file.
    func reconcileInterruptedTrashMoves(trashRoot: URL = CleanupService.userTrashURL()) throws {
        let loaded = try loadAvailable()
        let pending = loaded.reports.filter { report in
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
        let children = try FileManager.default.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil)
        // Bounded review: exceeding this limit leaves ambiguous entries intact.
        guard children.count <= 10_000 else { return }
        var byIdentity: [FileIdentity: [URL]] = [:]
        for child in children {
            guard let snapshot = try? reader.snapshot(at: child), !snapshot.hasSymbolicLinkComponent else { continue }
            byIdentity[snapshot.identity, default: []].append(child)
        }
        for report in pending {
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
                        verification: .identityVerified, movedAt: report.completedAt)))
            }
            guard changed else { continue }
            var moved = 0, skipped = 0, failed = 0, notProcessed = 0, unverified = 0
            var bytes: Int64 = 0
            for item in items {
                switch item.outcome {
                case .moved(let receipt):
                    moved += 1; bytes += max(0, item.estimatedBytes)
                    if !receipt.isRestorable { unverified += 1 }
                case .skipped: skipped += 1
                case .failed: failed += 1
                case .notProcessed: notProcessed += 1
                }
            }
            let updated = CleanReport(id: report.id, planID: report.planID, sessionID: report.sessionID,
                rulesVersion: report.rulesVersion, disposition: report.disposition, scanWasPartial: report.scanWasPartial,
                startedAt: report.startedAt, completedAt: report.completedAt,
                outcome: failed + notProcessed + unverified == 0 ? .completed : .partiallyCompleted,
                items: items, summary: CleanReportSummary(requestedItemCount: report.summary.requestedItemCount,
                    movedItemCount: moved, skippedItemCount: skipped, failedItemCount: failed,
                    notProcessedItemCount: notProcessed, unverifiedMoveCount: unverified,
                    plannedBytes: report.summary.plannedBytes, movedToRecoverableLocationBytes: bytes,
                    reclaimableAfterEmptyingTrashBytes: bytes, permanentlyFreedBytes: 0,
                    availableSpaceDeltaBytes: report.summary.availableSpaceDeltaBytes),
                persistenceFailure: report.persistenceFailure, recoveryAttempts: report.recoveryAttempts)
            try checkpoint(updated, expectedIdentities: entry.expectedIdentities)
        }
    }
}
