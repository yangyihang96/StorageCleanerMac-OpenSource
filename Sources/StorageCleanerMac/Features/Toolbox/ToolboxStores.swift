import Foundation

/// D154 batch 2: one set of the D160–D165 tool stores per `ScanStore`, so
/// the module results, My Tools and the tool pages read the same state (a
/// scan started from a result tile is the one its page shows). Built on the
/// store's heavy-work coordinator, as the tools expect.
@MainActor
final class ToolboxStores {
    private static let all = NSMapTable<ScanStore, ToolboxStores>.weakToStrongObjects()

    static func of(_ store: ScanStore) -> ToolboxStores {
        if let stores = all.object(forKey: store) { return stores }
        let stores = ToolboxStores(store: store)
        all.setObject(stores, forKey: store)
        return stores
    }

    let extensions: ExtensionManagerStore
    let maintenance: SystemMaintenanceStore
    let chatFiles: ChatFilesStore
    let cloneMerge: DuplicateCloneMergeAction
    /// D221: Large & Old Files in the clutter manager, on the large-file list.
    let largeOldFiles: LargeOldFilesStore
    /// D226: My Clutter's Downloads. What moves to the Trash from it or from
    /// Large & Old Files leaves the other list too.
    let downloads: DownloadsStore

    private init(store: ScanStore) {
        extensions = ExtensionManagerStore(coordinator: store.heavyWorkCoordinator,
                                           activityStore: store.heavyWorkActivityStore)
        maintenance = SystemMaintenanceStore(coordinator: store.heavyWorkCoordinator,
                                             activityStore: store.heavyWorkActivityStore)
        chatFiles = ChatFilesStore(coordinator: store.heavyWorkCoordinator,
                                   activityStore: store.heavyWorkActivityStore)
        cloneMerge = DuplicateCloneMergeAction(coordinator: store.heavyWorkCoordinator,
                                               activityStore: store.heavyWorkActivityStore)
        largeOldFiles = LargeOldFilesStore(
            largeFiles: store.largeFilesWorkspace,
            trash: LargeOldFilesTrashService(environment: .live, coordinator: store.heavyWorkCoordinator),
            ignoreList: { [weak store] in store?.ignoreListStore })
        // The large-file list's environment: the home a test store reads is its own.
        let environment = store.largeFilesWorkspace.fileAnalysisEnvironment
        downloads = DownloadsStore(
            downloadsURL: DownloadsStore.downloadsURL(homePath: environment.homePath), homePath: environment.homePath,
            trash: DownloadsTrashService(environment: environment, coordinator: store.heavyWorkCoordinator),
            ignoreList: { [weak store] in store?.ignoreListStore })
        largeOldFiles.onMovedToTrash = { [weak downloads] in downloads?.forgetMovedPaths($0) }
        downloads.onMovedToTrash = { [weak largeOldFiles] in largeOldFiles?.forgetMovedPaths($0) }
    }
}
