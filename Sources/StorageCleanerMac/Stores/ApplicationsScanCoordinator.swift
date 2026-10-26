import Foundation

/// The Applications landing scan reads the inventory first, then uses Smart
/// Care's read-only update entry. Keeping the task here lets it finish after
/// the landing view gives way to the results, without a second heavy-work lease.
@MainActor
final class ApplicationsScanCoordinator: ObservableObject {
    @Published private(set) var showsUpdateTile = true
    private var task: Task<Void, Never>?
    private var previousUpdateDate: Date?

    func permitsUpdateTile(lastScannedAt: Date?) -> Bool {
        showsUpdateTile || (lastScannedAt != nil && lastScannedAt != previousUpdateDate)
    }

    @discardableResult
    func start(
        store: ScanStore,
        readInstalledApps: (@MainActor () async -> Void)? = nil,
        isOnline: @escaping @MainActor () async -> Bool = LiveSmartCareScanner.isOnline
    ) -> Task<Void, Never>? {
        guard task == nil, store.canRefreshInstalledApps else { return nil }
        previousUpdateDate = store.appUpdatesLastScannedAt
        showsUpdateTile = false
        // Set the loading state synchronously so the button immediately gives
        // way to the reading page. Tests inject a local inventory operation.
        if readInstalledApps == nil { store.refreshInstalledApps() }
        let operation = Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            defer { task = nil }
            if let readInstalledApps {
                await readInstalledApps()
            } else {
                while store.isLoadingInstalledApps {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
            }
            guard !Task.isCancelled, await isOnline(), !Task.isCancelled else { return }
            // Refresh the lease snapshot before checking eligibility; the update
            // entry acquires its own .appUpdates lease and handles a later race.
            await store.heavyWorkActivityStore.refresh()
            if !store.isLoadingAppUpdates {
                // D202: the Applications page's own check, not Smart Care's.
                if store.canRefreshAppUpdates { store.noteModuleScan(.applications) }
                store.checkAppUpdatesForSmartCare()
            }
            showsUpdateTile = store.isLoadingAppUpdates
        }
        task = operation
        return operation
    }
}
