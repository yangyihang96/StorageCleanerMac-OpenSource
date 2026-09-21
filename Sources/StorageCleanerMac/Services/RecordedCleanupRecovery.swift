import Darwin
import Foundation

/// Atomic no-replace rename. No copy/delete fallback: a cross-volume recovery
/// remains in its safe location and is reported for manual resolution.
enum ExclusiveRecoveryMove {
    static func perform(source: URL, destination: URL, expectedIdentity: FileIdentity) throws {
        let sourceParent = try openDirectory(source.deletingLastPathComponent())
        defer { close(sourceParent) }
        let destinationParent = try openDirectory(destination.deletingLastPathComponent())
        defer { close(destinationParent) }
        var metadata = stat()
        guard fstatat(sourceParent, source.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let birth: Int64? = metadata.st_birthtimespec.tv_sec > 0
            ? Int64(metadata.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_birthtimespec.tv_nsec) : nil
        guard
              UInt64(metadata.st_dev) == expectedIdentity.deviceID,
              UInt64(metadata.st_ino) == expectedIdentity.inode,
              metadata.st_mode & S_IFMT != S_IFLNK,
              expectedIdentity.creationTimeNanoseconds == birth else {
            throw CleanupReportJournal.Failure.invalidEntry
        }
        guard renameatx_np(sourceParent, source.lastPathComponent,
                           destinationParent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path == PathSafety.lexicalPath(url.path) else {
            throw CleanupReportJournal.Failure.unsafePath
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        for component in url.pathComponents.dropFirst() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            fd = next
        }
        return fd
    }
}

extension CleanupRecoveryService {
    /// The report journal is the existing operation history. Register every
    /// intent before touching a file, checkpoint each result, and retain rows.
    func restore(
        report requestedReport: CleanReport,
        coordinator: HeavyWorkCoordinator,
        lease: HeavyWorkCoordinator.Lease,
        journal: CleanupReportJournal = .live,
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashURL: URL = CleanupService.userTrashURL(),
        quarantineRootURL: URL = CleanupQuarantineLocation.defaultURL,
        checkpoint: (@Sendable (CleanReport) throws -> Void)? = nil
    ) async -> (report: CleanReport, recovery: CleanupRecoveryReport) {
        var report = requestedReport
        let attemptID = UUID()
        var results: [CleanupRecoveryItem] = []
        let persist: @Sendable (CleanReport) throws -> Void = checkpoint ?? {
            try journal.checkpoint($0, expectedIdentities: [:])
        }
        func snapshot(failure: String? = nil) -> CleanupRecoveryReport {
            CleanupRecoveryReport(completedAt: Date(), items: results,
                                  attemptID: attemptID, persistenceFailure: failure)
        }
        func replacingAttempt(_ recovery: CleanupRecoveryReport, in current: CleanReport) -> CleanReport {
            var updated = current
            var attempts = current.recoveryAttempts ?? []
            attempts.removeAll { $0.attemptID == attemptID }
            attempts.append(recovery)
            updated.recoveryAttempts = attempts
            return updated
        }
        do {
            try await coordinator.requireValid(lease, owner: .restore)
            let path = journal.directory.appendingPathComponent(report.planID.rawValue.uuidString + ".json")
            if FileManager.default.fileExists(atPath: path.path) {
                let latest = try journal.read(path).report
                guard latest.id == report.id else { throw CleanupReportJournal.Failure.invalidEntry }
                report = latest // stale UI cannot overwrite already restored evidence
            }
            let receipts = report.restorableReceipts
            results = receipts.map { CleanupRecoveryItem(id: UUID(), originalPath: $0.originalPath, outcome: .notProcessed) }
            report = replacingAttempt(snapshot(), in: report)
            try persist(report)
            for (index, receipt) in receipts.enumerated() {
                if Task.isCancelled { break }
                try await coordinator.requireValid(lease, owner: .restore)
                results[index] = CleanupRecoveryItem(id: results[index].id,
                    originalPath: receipt.originalPath, outcome: .outcomeUnknown)
                report = replacingAttempt(snapshot(), in: report)
                try persist(report)
                let item = await restoreOne(receipt, userHomeURL: userHomeURL, trashURL: trashURL,
                    quarantineRootURL: quarantineRootURL,
                    allowedApplicationPaths: report.rulesVersion == "uninstall.application.v1"
                        ? Set(receipts.map(\.originalPath)) : [],
                    beforeMove: { try await coordinator.requireValid(lease, owner: .restore) })
                results[index] = CleanupRecoveryItem(id: results[index].id,
                    originalPath: item.originalPath, outcome: item.outcome)
                report = replacingAttempt(snapshot(), in: report)
                try persist(report)
            }
            report = replacingAttempt(snapshot(), in: report)
            try persist(report)
            return (report, snapshot())
        } catch {
            // Do not claim rollback: a prior move may already be complete. Its
            // durable unknown intent is reconciled by identity after relaunch.
            if results.isEmpty {
                results = requestedReport.restorableReceipts.map {
                    CleanupRecoveryItem(id: UUID(), originalPath: $0.originalPath, outcome: .notProcessed)
                }
            }
            let recovery = snapshot(failure: "recovery-checkpoint-or-lease-failed")
            report = replacingAttempt(recovery, in: report)
            return (report, recovery)
        }
    }
}

extension CleanupReportJournal {
    /// Only call while holding the restore lease, with no active restore worker.
    /// Reconciliation changes evidence, never file contents or locations.
    func reconcileInterruptedRecoveries() throws {
        let reader = FoundationReadOnlyFileSystem()
        for var report in try loadAvailable().reports {
            guard var attempts = report.recoveryAttempts else { continue }
            var changed = false
            for index in attempts.indices {
                let prior = attempts[index]
                let items = prior.items.map { item -> CleanupRecoveryItem in
                    guard item.outcome == .outcomeUnknown,
                          let original = report.items.first(where: { $0.sourcePath == item.originalPath }),
                          case .moved(let receipt) = original.outcome,
                          let identity = receipt.movedIdentity, receipt.isRestorable else { return item }
                    func identityOrMissing(_ url: URL) -> (FileIdentity?, Bool) {
                        do {
                            let value = try reader.snapshot(at: url)
                            return value.hasSymbolicLinkComponent ? (nil, false) : (value.identity, false)
                        } catch CleanupFileSystemError.vanished { return (nil, true) }
                        catch { return (nil, false) }
                    }
                    let source = identityOrMissing(receipt.resultingItemURL)
                    let destination = identityOrMissing(URL(fileURLWithPath: receipt.originalPath))
                    let outcome: CleanupRecoveryItemOutcome
                    if source.1, destination.0 == identity { outcome = .restored }
                    else if source.0 == identity, destination.1 { outcome = .notProcessed }
                    else { return item } // conflict, permissions or replacement stays ambiguous
                    changed = true
                    return CleanupRecoveryItem(id: item.id, originalPath: item.originalPath, outcome: outcome)
                }
                attempts[index] = CleanupRecoveryReport(completedAt: prior.completedAt, items: items,
                    attemptID: prior.attemptID, persistenceFailure: prior.persistenceFailure)
            }
            if changed {
                report.recoveryAttempts = attempts
                try checkpoint(report, expectedIdentities: [:])
            }
        }
    }
}
