import Foundation

/// Uses the existing cleanup report and recovery store for explicit operations
/// outside the scan planner (currently uninstall). No independent history file.
enum RecordedTrashOperation {
    struct Item: Sendable {
        let path: String
        let bytes: Int64
        let identity: FileIdentity?
    }

    static func run(
        items: [Item], ruleID: String,
        validate: (Item) throws -> Void,
        move: (URL) throws -> URL = { source in
            var target: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &target)
            guard let target = target as URL? else { throw CleanupMoveError.invalidResult }
            return target
        },
        metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem(),
        persist: (CleanReport, [String: FileIdentity]) throws -> Void = {
            try CleanupReportJournal.live.checkpoint($0, expectedIdentities: $1)
        }
    ) -> CleanReport {
        let planID = CleanPlanID()
        let sessionID = ScanSessionID()
        let reportID = UUID()
        let startedAt = Date()
        let itemIDs = items.map { _ in UUID() }
        let identities = Dictionary(items.compactMap { item in item.identity.map { (item.path, $0) } },
                                    uniquingKeysWith: { a, _ in a })
        var outcomes = [CleanItemOutcome](repeating: .notProcessed, count: items.count)
        var cancelled = false
        var persistenceFailure: String?
        func report() -> CleanReport {
            let rows = zip(items.indices, items).map { index, item in
                CleanReportItem(id: itemIDs[index], planItemID: itemIDs[index], ruleID: ruleID,
                    sourcePath: item.path, estimatedBytes: item.bytes, outcome: outcomes[index])
            }
            var moved = 0, failed = 0, skipped = 0, pending = 0, unverified = 0
            var bytes: Int64 = 0
            for row in rows {
                switch row.outcome {
                case .moved(let receipt):
                    moved += 1
                    bytes += max(0, row.estimatedBytes)
                    if !receipt.isRestorable { unverified += 1 }
                case .failed: failed += 1
                case .skipped: skipped += 1
                case .notProcessed: pending += 1
                }
            }
            let outcome: CleanReportOutcome = cancelled ? .cancelled :
                (failed + pending + unverified == 0 && persistenceFailure == nil ? .completed :
                    (moved > 0 ? .partiallyCompleted : .failed))
            return CleanReport(id: reportID, planID: planID, sessionID: sessionID,
                rulesVersion: ruleID, disposition: .trash, scanWasPartial: false,
                startedAt: startedAt, completedAt: Date(), outcome: outcome, items: rows,
                summary: CleanReportSummary(requestedItemCount: items.count, movedItemCount: moved,
                    skippedItemCount: skipped, failedItemCount: failed, notProcessedItemCount: pending,
                    unverifiedMoveCount: unverified, plannedBytes: items.reduce(0) { $0 + max(0, $1.bytes) },
                    movedToRecoverableLocationBytes: bytes, reclaimableAfterEmptyingTrashBytes: bytes,
                    permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil),
                persistenceFailure: persistenceFailure)
        }
        do { try persist(report(), identities) }
        catch { persistenceFailure = "intent-write-failed"; return report() }
        for (index, item) in items.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            var invokedMove = false
            do {
                guard item.identity != nil else { throw AppUninstallError.identityChanged(item.path) }
                try validate(item)
                let current = try metadata.snapshot(at: URL(fileURLWithPath: item.path))
                guard current.identity == item.identity, !current.hasSymbolicLinkComponent else {
                    throw AppUninstallError.identityChanged(item.path)
                }
                outcomes[index] = .failed(CleanFailure(code: .moveOutcomeUnknown, detailCode: "move-in-flight"))
                do { try persist(report(), identities) }
                catch { persistenceFailure = "intent-write-failed"; outcomes[index] = .notProcessed; break }
                try Task.checkCancellation()
                // Revalidate after the journal write, immediately before moving.
                try validate(item)
                let immediate = try metadata.snapshot(at: URL(fileURLWithPath: item.path))
                guard immediate.identity == item.identity, !immediate.hasSymbolicLinkComponent else {
                    throw AppUninstallError.identityChanged(item.path)
                }
                invokedMove = true
                let target = try move(URL(fileURLWithPath: item.path))
                let moved = try? metadata.snapshot(at: target)
                let verification: CleanupMoveVerification = moved.map {
                    $0.identity == item.identity ? .identityVerified : .identityMismatch
                } ?? .destinationMetadataUnavailable
                outcomes[index] = .moved(CleanupMoveReceipt(originalPath: item.path,
                    resultingItemURL: target, disposition: .trash, movedIdentity: moved?.identity,
                    verification: verification, movedAt: Date()))
            } catch is CancellationError {
                cancelled = true
                outcomes[index] = invokedMove
                    ? .failed(CleanFailure(code: .moveOutcomeUnknown, detailCode: "cancelled-during-move"))
                    : .notProcessed
            } catch {
                outcomes[index] = .failed(CleanFailure(
                    code: invokedMove ? .moveOutcomeUnknown : .trashMoveRejected,
                    detailCode: String(describing: type(of: error))))
            }
            do { try persist(report(), identities) }
            catch { persistenceFailure = "result-write-failed"; break }
        }
        do { try persist(report(), identities) }
        catch { persistenceFailure = "final-write-failed" }
        return report()
    }
}
