import Combine
import Foundation

/// Backs "Recent Deletions": lists the recovery backups this app took before
/// deleting history, restores one on request, or removes one.
///
/// A backup is a full copy of a browser's history database from before a
/// deletion, so it still contains the deleted pages. It stays in this app's
/// data folder, which Time Machine skips, for
/// `BrowserPrivacyBackupRetention.days` days (at most
/// `BrowserPrivacyBackupRetention.maximumCount` backups of finished
/// deletions) unless it is removed here first.
@MainActor
final class BrowserPrivacyRecoveryStore: ObservableObject {
    @Published private(set) var entries: [BrowserPrivacyRecoveryEntry] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastResult: BrowserPrivacyRestoreResult?
    /// The backup whose removal just failed; Recent Deletions says so under
    /// its row.
    @Published private(set) var failedRemovalID: UUID?
    /// Retired data is not restorable, but its cleanup remains visible and
    /// retryable even after the source row or the previous app session is gone.
    @Published private(set) var pendingRemovalIDs: Set<UUID> = []

    var unlistedRemovalIDs: [UUID] {
        var ids = pendingRemovalIDs
        if let failedRemovalID, !entries.contains(where: { $0.id == failedRemovalID }) {
            ids.insert(failedRemovalID)
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    private let service: BrowserPrivacyRecoveryBackupService
    private let processor: BrowserPrivacyHistoryProcessor
    private let installedApplications: [BrowserPrivacyInstalledApplication]?

    init(
        service: BrowserPrivacyRecoveryBackupService = BrowserPrivacyRecoveryBackupService(),
        processor: BrowserPrivacyHistoryProcessor? = nil,
        installedApplications: [BrowserPrivacyInstalledApplication]? = nil
    ) {
        self.service = service
        self.processor = processor ?? BrowserPrivacyHistoryProcessor(backupService: service)
        self.installedApplications = installedApplications
    }

    func refresh() async {
        await refresh(sparing: [])
    }

    /// `sparing` survives the count limit in this refresh.
    private func refresh(sparing: Set<UUID>) async {
        let service = self.service
        let failedID = failedRemovalID
        let state = await Task.detached(priority: .utility) {
            service.purgeExpired(sparing: sparing)
            return (service.entries(), service.pendingRemovalIDs(), failedID.map { service.isRemoved(backupID: $0) })
        }.value
        entries = state.0
        if let pending = state.1 { pendingRemovalIDs = pending }
        if failedRemovalID == failedID, state.2 == true { failedRemovalID = nil }
    }

    /// The caller has already shown what a restore discards.
    func restore(_ entry: BrowserPrivacyRecoveryEntry) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let result = await restoreResult(entry)
        // The processor persisted the restored marker before releasing the
        // source lease; leaving it to this actor would reopen N12's window.
        lastResult = result
        // A restore that failed is not marked restored; the user may want
        // to try that backup again, so this refresh must not prune it.
        await refresh(sparing: [entry.id])
    }

    private func restoreResult(_ entry: BrowserPrivacyRecoveryEntry) async -> BrowserPrivacyRestoreResult {
        if entry.dataContract != nil {
            let dataService = BrowserPrivacyDataService(recovery: service)
            return await dataService.restore(entry, profiles: await dataService.discover())
        }
        return await processor.restore(entry, installedApplications: installedApplications)
    }

    /// Permanently removes one backup; that deletion can then no longer be undone.
    func remove(_ entry: BrowserPrivacyRecoveryEntry) async {
        await remove(backupID: entry.id)
    }

    /// Removes one backup by its identifier. It is this app's own copy of
    /// the history, so it is deleted directly rather than moved to the
    /// Trash, where the deleted pages would live on. Returns whether it is gone.
    @discardableResult
    func remove(backupID: UUID) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        failedRemovalID = nil
        let service = self.service
        _ = await Task.detached(priority: .utility) {
            service.remove(backupID: backupID)
        }.value
        await refresh()
        // Refresh may have retried cleanup. Report the final on-disk state,
        // not the earlier result of removing only the original UUID path.
        let removed = await Task.detached(priority: .utility) {
            service.isRemoved(backupID: backupID)
        }.value
        failedRemovalID = removed ? nil : backupID
        if removed { pendingRemovalIDs.remove(backupID) }
        return removed
    }

    func retryPendingRemovals() async {
        for id in unlistedRemovalIDs {
            await remove(backupID: id)
        }
    }

    func clearResult() {
        lastResult = nil
        failedRemovalID = nil
    }
}
