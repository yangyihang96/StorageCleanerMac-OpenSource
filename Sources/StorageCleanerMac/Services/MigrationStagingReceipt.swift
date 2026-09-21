import Foundation
import os

/// Staging cleanup evidence uses the same durable operation report store.
/// A missing external volume never silently erases the pending cleanup record.
typealias MigrationStagingReceipt = TemporaryResourceReceipt

struct TemporaryResourceReceipt {
    private let reportID = UUID()
    private let planID = CleanPlanID()
    private let sessionID = ScanSessionID()
    private let itemID = UUID()
    private let startedAt = Date()
    let url: URL
    let identity: FileIdentity
    let journal: CleanupReportJournal
    let ruleID: String

    init(url: URL, journal: CleanupReportJournal = .live, ruleID: String = "migration.staging.v1") throws {
        self.url = url
        self.journal = journal
        self.ruleID = ruleID
        self.identity = try FoundationReadOnlyFileSystem().snapshot(at: url).identity
        try checkpoint(pending: true)
    }

    func checkpoint(pending: Bool) throws {
        let report = CleanReport(id: reportID, planID: planID, sessionID: sessionID,
            rulesVersion: ruleID, disposition: .trash, scanWasPartial: false,
            startedAt: startedAt, completedAt: Date(), outcome: pending ? .partiallyCompleted : .completed,
            items: [CleanReportItem(id: itemID, planItemID: itemID, ruleID: ruleID,
                sourcePath: url.path, estimatedBytes: 0,
                outcome: pending ? .failed(CleanFailure(code: .moveOutcomeUnknown, detailCode: "staging-cleanup-pending")) : .skipped(.itemMissing))],
            summary: CleanReportSummary(requestedItemCount: 1, movedItemCount: 0,
                skippedItemCount: pending ? 0 : 1, failedItemCount: pending ? 1 : 0,
                notProcessedItemCount: 0, unverifiedMoveCount: 0, plannedBytes: 0,
                movedToRecoverableLocationBytes: 0, reclaimableAfterEmptyingTrashBytes: nil,
                permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil))
        try journal.checkpoint(report, expectedIdentities: [url.path: identity])
    }

    func cleanup(_ staging: MigrationStagingDirectory) {
        do {
            let current = try FoundationReadOnlyFileSystem().snapshot(at: url)
            guard current.identity == identity, !current.hasSymbolicLinkComponent else {
                throw CleanupMoveError.unsafeQuarantineRoot
            }
            try staging.remove()
            try checkpoint(pending: false)
        } catch {
            // The write-ahead pending entry is already durable, even if this
            // update fails because the local disk is now full.
            try? checkpoint(pending: true)
            Logger(subsystem: "StorageCleanerMac", category: "Migration")
                .error("Migration staging cleanup remains pending: \(planID.rawValue.uuidString, privacy: .public)")
        }
    }
}
