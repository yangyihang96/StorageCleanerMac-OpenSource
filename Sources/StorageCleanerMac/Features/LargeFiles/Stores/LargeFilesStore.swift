import Foundation

/// Lifecycle for a feature-owned scan.  A failed or cancelled run never
/// replaces the last successful result.
enum FeatureScanPhase: String, Equatable, Sendable {
    case idle
    case scanning
    case paused
    case cancelling
    case finished
    case failed
    case cancelled
}

/// A verified copy on an external drive, and whether its original was then
/// moved to the Trash.
struct ExternalMigrationCompletion: Equatable, Sendable {
    /// After the move the original's place held a file again: the same file,
    /// put back from Operation History, or another one. Either way the row no
    /// longer says where the file is, so it asks for a new scan.
    enum ReturnedOriginal: Equatable, Sendable {
        case restored
        case replaced
    }

    let destinationURL: URL
    let volume: ExternalStorageVolume
    let didMoveSourceToTrash: Bool
    var originalPath: String? = nil
    var originalIdentity: FileIdentity? = nil
    var returnedOriginal: ReturnedOriginal? = nil
    var contentVerification: MigrationContentVerification? = nil
    var information: [String] = []

    /// The original is in the Trash and nothing came back to its place.
    var isMovedAway: Bool {
        didMoveSourceToTrash && returnedOriginal == nil
    }

    /// After the original went to the Trash the row shows where the file
    /// is now; until then, and once something is back in its place, it shows
    /// the original path.
    func displayPath(original: String) -> String {
        isMovedAway ? destinationURL.path : original
    }
}

/// D85：一次大文件清单扫描的结果与截断情况（注入的旧式扫描没有 summary）。
struct LargeFileScanOutcome: Sendable {
    let items: [StorageItem]
    let summary: LargeFileListingSummary?
}

@MainActor
final class LargeFilesStore: ObservableObject {
    typealias ScanOperation = @Sendable (
        @escaping DiskScanProgressHandler
    ) async throws -> [StorageItem]
    /// D85：带门槛的大文件清单扫描，返回结果与截断情况。
    typealias ListingScanOperation = @Sendable (
        _ threshold: LargeFileThreshold,
        _ progressHandler: @escaping DiskScanProgressHandler
    ) async throws -> LargeFileScanOutcome
    typealias StorageAnalysisOperation = @Sendable (
        _ target: StorageMapScanTarget,
        _ progressHandler: @escaping @Sendable (StorageMapScanProgress) -> Void
    ) async throws -> StorageMapAnalysisResult
    typealias DirectoryBrowseOperation = @Sendable (
        _ path: String,
        _ index: StorageMapAnalysisIndex?
    ) async throws -> StorageMapDirectorySnapshot

    private enum Key {
        static let searchText = "large-files.search-text"
        static let selectedFilter = "large-files.selected-filter"
        static let sortMode = "large-files.sort-mode"
        static let selectedStorageMapTarget = "storage-map.selected-target"
        static let largeFileThreshold = "large-files.threshold"
    }

    private let defaults: UserDefaults
    /// D90 shares the existing lease; cloud eviction cannot race app cleanup/restore.
    var cloudLocalCopyCoordinator: HeavyWorkCoordinator { coordinator }
    private let coordinator: HeavyWorkCoordinator
    private let activityStore: HeavyWorkActivityStore
    private let listingScanOperation: ListingScanOperation
    private let storageAnalysisOperation: StorageAnalysisOperation
    private let directoryBrowseOperation: DirectoryBrowseOperation

    @Published private(set) var items: [StorageItem] = []
    /// D85：最近一次成功扫描的门槛与截断情况；取消或失败不替换。
    @Published private(set) var listingSummary: LargeFileListingSummary?
    @Published private(set) var phase: FeatureScanPhase = .idle
    @Published private(set) var progress: DiskScanProgress?
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var scanSeconds: TimeInterval?
    @Published private(set) var errorMessage: String?
    @Published private(set) var cancellationRequested = false
    @Published private(set) var storageAnalysis: StorageMapAnalysisResult?
    @Published private(set) var storageAnalysisPhase: FeatureScanPhase = .idle
    @Published private(set) var storageAnalysisProgress: StorageMapScanProgress?
    @Published private(set) var storageAnalysisErrorMessage: String?
    @Published private(set) var storageAnalysisCancellationRequested = false
    @Published private(set) var storageMapNavigation: [StorageMapDirectorySnapshot] = []
    @Published private(set) var storageMapForwardNavigation: [StorageMapDirectorySnapshot] = []
    @Published private(set) var storageMapBrowsePhase: StorageMapBrowsePhase = .idle
    let storageMapTargets: [StorageMapScanTarget]

    // D46: checked items and their move to the Trash.
    @Published private(set) var trashSelections: [FileAnalysisTrashSelection] = []
    @Published private(set) var trashPolicy: FileAnalysisTrashPolicy?
    @Published private(set) var trashPhase: FileAnalysisTrashPhase = .idle
    @Published private(set) var trashReview: FileAnalysisTrashReview?
    @Published private(set) var trashProgress: FileAnalysisTrashProgress?
    @Published private(set) var trashOutcome: FileAnalysisTrashOutcome?
    /// Why the last click could not check an item, or why a move did not start.
    @Published private(set) var trashNotice: String?
    /// 中文说明或错误域与错误码；不展示 Swift 枚举或关联值。
    @Published private(set) var trashNoticeDetail: String?
    /// Items Operation History put back since the last move, now counted again.
    @Published private(set) var trashPutBackCount = 0

    @Published private(set) var migrationSourcePath: String? = nil
    @Published private(set) var migrationCompletions: [String: ExternalMigrationCompletion] = [:]
    @Published var migrationDestinationVolumeID = ""
    @Published var migrationKind: ExternalMigrationItem.Kind = .file

    @Published var selectedStorageMapTargetID: String {
        didSet { defaults.set(selectedStorageMapTargetID, forKey: Key.selectedStorageMapTarget) }
    }

    @Published var searchText: String {
        didSet { defaults.set(searchText, forKey: Key.searchText) }
    }
    @Published var selectedFilter: LargeFileFilter {
        didSet { defaults.set(selectedFilter.rawValue, forKey: Key.selectedFilter) }
    }
    @Published var sortMode: LargeFileSortMode {
        didSet { defaults.set(sortMode.rawValue, forKey: Key.sortMode) }
    }
    /// D85：大文件门槛（50 MiB / 200 MiB / 1 GiB），默认 200 MiB。
    @Published var largeFileThreshold: LargeFileThreshold {
        didSet { defaults.set(largeFileThreshold.rawValue, forKey: Key.largeFileThreshold) }
    }

    private var scanTask: Task<Void, Never>?
    private var scanGeneration: UUID?
    private var storageAnalysisTask: Task<Void, Never>?
    private var storageAnalysisGeneration: UUID?
    private var storageMapBrowseTask: Task<Void, Never>?
    private var storageMapBrowseGeneration: UUID?
    private var storageMapCache: [String: StorageMapDirectorySnapshot] = [:]
    private let usesDefaultScanOperation: Bool
    private var trashEnvironment: FileAnalysisTrashEnvironment
    /// Moved items as they left the index, to put back after a restore.
    private var trashedItems: [FileAnalysisTrashedItem] = []
    private var trashTask: Task<Void, Never>?
    private var trashGeneration = UUID()
    private var trashRefinementTasks: [Task<Void, Never>] = []
    private var trashRefinementTimeoutTask: Task<Void, Never>?
    /// r2-fa-followups P1-1: finds the D54 locations reached through links
    /// off the main thread after an analysis.
    private var trashProtectionTask: Task<Void, Never>?

    init(
        coordinator: HeavyWorkCoordinator,
        activityStore: HeavyWorkActivityStore,
        defaults: UserDefaults = .standard,
        scanOperation: ScanOperation? = nil,
        listingScanOperation: ListingScanOperation? = nil,
        storageMapTargets: [StorageMapScanTarget]? = nil,
        storageAnalysisOperation: StorageAnalysisOperation? = nil,
        directoryBrowseOperation: DirectoryBrowseOperation? = nil,
        trashEnvironment: FileAnalysisTrashEnvironment = .live
    ) {
        self.coordinator = coordinator
        self.trashEnvironment = trashEnvironment
        self.activityStore = activityStore
        self.defaults = defaults
        if let listingScanOperation {
            self.listingScanOperation = listingScanOperation
        } else if let scanOperation {
            self.listingScanOperation = { _, progressHandler in
                LargeFileScanOutcome(items: try await scanOperation(progressHandler), summary: nil)
            }
        } else {
            self.listingScanOperation = Self.defaultListingScanOperation
        }
        usesDefaultScanOperation = scanOperation == nil && listingScanOperation == nil
        self.storageAnalysisOperation = storageAnalysisOperation ?? Self.defaultStorageAnalysisOperation
        self.directoryBrowseOperation = directoryBrowseOperation ?? Self.defaultDirectoryBrowseOperation
        let resolvedTargets = storageMapTargets ?? DiskScanner.storageMapScanTargets()
        self.storageMapTargets = resolvedTargets
        let storedTargetID = defaults.string(forKey: Key.selectedStorageMapTarget)
        selectedStorageMapTargetID = resolvedTargets.contains { $0.id == storedTargetID }
            ? (storedTargetID ?? resolvedTargets.first?.id ?? "")
            : (resolvedTargets.first?.id ?? "")
        searchText = defaults.string(forKey: Key.searchText) ?? ""
        selectedFilter = LargeFileFilter(
            rawValue: defaults.string(forKey: Key.selectedFilter) ?? ""
        ) ?? .all
        sortMode = LargeFileSortMode(
            rawValue: defaults.string(forKey: Key.sortMode) ?? ""
        ) ?? .size
        largeFileThreshold = LargeFileThreshold.stored(defaults.string(forKey: Key.largeFileThreshold))
    }

    var isScanning: Bool {
        phase == .scanning || phase == .paused || phase == .cancelling
    }

    var hasScanned: Bool {
#if DEBUG || STORAGE_CLEANER_BETA
        if DebugExternalMigrationPresentationFixture.launchScenario != nil { return true }
#endif
        return lastScanAt != nil
    }

    var isAnalyzingStorage: Bool {
        storageAnalysisPhase == .scanning
            || storageAnalysisPhase == .paused
            || storageAnalysisPhase == .cancelling
    }

    var hasStorageAnalysis: Bool {
        storageAnalysis != nil
    }

    var selectedStorageMapTarget: StorageMapScanTarget? {
        storageMapTargets.first { $0.id == selectedStorageMapTargetID }
            ?? storageMapTargets.first
    }

    var visibleItems: [StorageItem] {
        LargeFilePresenter.visibleItems(
            from: items,
            query: searchText,
            filter: selectedFilter,
            sortMode: sortMode
        )
    }

    var summaries: [LargeFileKindSummary] {
        LargeFilePresenter.summaries(for: items)
    }

    var availableFilters: [LargeFileFilter] {
        LargeFilePresenter.availableFilters(for: items)
    }

    var canScan: Bool {
        !isScanning
            && scanTask == nil
            && !isAnalyzingStorage
            && storageAnalysisTask == nil
            && !storageMapBrowsePhase.isLoading
            && storageMapBrowseTask == nil
    }

    var canStartStorageAnalysis: Bool {
        selectedStorageMapTarget != nil
            && !isScanning
            && scanTask == nil
            && !isAnalyzingStorage
            && storageAnalysisTask == nil
            && !storageMapBrowsePhase.isLoading
            && storageMapBrowseTask == nil
            && trashPhase == .idle
    }

    var currentStorageMapSnapshot: StorageMapDirectorySnapshot? {
        storageMapNavigation.last
    }

    /// N18: kept by the store so a moved row still shows its new location
    /// after switching pages; a new scan result starts a fresh list.
    func recordMigrationCompletion(_ completion: ExternalMigrationCompletion, for itemID: String) {
        migrationCompletions[itemID] = completion
    }

    /// Called by ScanStore after a restore from Operation History finishes.
    /// Operation History is a sheet over the page, so the page does not
    /// appear again afterwards; its rows update here at once (N18 review
    /// P2-7 follow-up). A page that appears later still looks again.
    func operationHistoryDidRestore(_ restoredReceipts: [CleanupMoveReceipt]) {
        refreshMigrationCompletions()
        putBackRestoredTrashItems(restoredReceipts)
    }

    /// N18 review P2-7: looks at the place of each moved original again.
    /// Operation History can put the original back while this page keeps its
    /// old row; then the row no longer points at the copy and asks for a new
    /// scan. The same file (by identity) counts as put back, anything else
    /// as replaced.
    func refreshMigrationCompletions() {
        let metadata = FoundationReadOnlyFileSystem()
        var refreshed = migrationCompletions
        for (itemID, completion) in migrationCompletions where completion.isMovedAway {
            guard let path = completion.originalPath,
                  let current = try? metadata.snapshot(at: URL(fileURLWithPath: path)).identity else { continue }
            var updated = completion
            updated.returnedOriginal = current == completion.originalIdentity ? .restored : .replaced
            refreshed[itemID] = updated
        }
        if refreshed != migrationCompletions {
            migrationCompletions = refreshed
        }
    }

    @discardableResult
    func selectMigrationSource(_ url: URL?) -> Bool {
        guard let url else {
            migrationSourcePath = nil
            return true
        }
        let path = url.standardizedFileURL.path
        guard PathSafety.isLexicallyInsideHome(path), PathSafety.isInsideHome(path) else {
            return false
        }
        migrationSourcePath = path
        return true
    }

    func startScan() {
        guard canScan else { return }

        let generation = UUID()
        scanGeneration = generation
        phase = .scanning
        cancellationRequested = false
        errorMessage = nil
        progress = DiskScanProgress.starting(mode: .fallback)
        let started = Date()
        let operation = listingScanOperation
        let threshold = largeFileThreshold
        let sourcePath = migrationSourcePath
        let usesDefaultScanOperation = usesDefaultScanOperation
        let coordinator = coordinator
        let activityStore = activityStore

        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if scanGeneration == generation {
                    let finalPhase = phase == .cancelling ? FeatureScanPhase.cancelled : phase
                    scanGeneration = nil
                    scanTask = nil
                    phase = finalPhase
                }
            }

            do {
                let scannedItems = try await coordinator.withLease(owner: .largeFilesScan) { lease in
                    await activityStore.refresh()
                    try await coordinator.requireValid(lease, owner: .largeFilesScan)
                    let progressHandler: DiskScanProgressHandler = {
                        [weak self, progressThrottle = ScanProgressThrottle()] update in
                        guard progressThrottle.shouldDeliver(phase: update.currentGroupTitle) else {
                            return
                        }
                        Task { @MainActor [weak self] in
                            guard let self, self.scanGeneration == generation else { return }
                            self.progress = update
                        }
                    }
                    let result = if usesDefaultScanOperation {
                        try await Self.scanLargeFiles(
                            sourcePath: sourcePath,
                            threshold: threshold,
                            progressHandler: progressHandler
                        )
                    } else {
                        try await operation(threshold, progressHandler)
                    }
                    try Task.checkCancellation()
                    return result
                }
                await activityStore.refresh()
                guard scanGeneration == generation else { return }
                if Task.isCancelled || cancellationRequested {
                    phase = .cancelled
                    return
                }
                items = scannedItems.items
                listingSummary = scannedItems.summary
                migrationCompletions = [:]
                lastScanAt = Date()
                scanSeconds = Date().timeIntervalSince(started)
                phase = .finished
            } catch is CancellationError {
                guard scanGeneration == generation else { return }
                phase = .cancelled
            } catch {
                guard scanGeneration == generation else { return }
                phase = .failed
                errorMessage = error.localizedDescription
                await activityStore.refresh()
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        cancellationRequested = true
        phase = .cancelling
        scanTask?.cancel()
    }

    func startStorageAnalysis() {
        guard canStartStorageAnalysis,
              let target = selectedStorageMapTarget else { return }

        let generation = UUID()
        storageAnalysisGeneration = generation
        storageAnalysisPhase = .scanning
        storageAnalysisCancellationRequested = false
        storageAnalysisErrorMessage = nil
        storageAnalysisProgress = StorageMapScanProgress(
            currentPath: target.path,
            inspectedItemCount: 0,
            measuredBytes: 0
        )
        let operation = storageAnalysisOperation
        let coordinator = coordinator
        let activityStore = activityStore

        storageAnalysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if storageAnalysisGeneration == generation {
                    let finalPhase = storageAnalysisPhase == .cancelling
                        ? FeatureScanPhase.cancelled
                        : storageAnalysisPhase
                    storageAnalysisGeneration = nil
                    storageAnalysisTask = nil
                    storageAnalysisPhase = finalPhase
                }
            }

            do {
                let result = try await coordinator.withLease(owner: .largeFilesScan) { lease in
                    await activityStore.refresh()
                    try await coordinator.requireValid(lease, owner: .largeFilesScan)
                    let result = try await operation(target) {
                        [weak self, progressThrottle = ScanProgressThrottle()] update in
                        guard progressThrottle.shouldDeliver() else { return }
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.storageAnalysisGeneration == generation else { return }
                            self.storageAnalysisProgress = update
                        }
                    }
                    try Task.checkCancellation()
                    return result
                }
                await activityStore.refresh()
                guard storageAnalysisGeneration == generation else { return }
                if Task.isCancelled || storageAnalysisCancellationRequested {
                    storageAnalysisPhase = .cancelled
                    return
                }
                storageAnalysis = result
                storageMapCache = [
                    PathSafety.normalizedPath(result.rootSnapshot.path): result.rootSnapshot
                ]
                storageMapNavigation = [result.rootSnapshot]
                storageMapForwardNavigation = []
                storageMapBrowsePhase = .idle
                resetTrash(for: result)
                storageAnalysisProgress = StorageMapScanProgress(
                    currentPath: result.target.path,
                    inspectedItemCount: result.inspectedItemCount,
                    measuredBytes: result.rootSnapshot.measuredBytes
                )
                storageAnalysisPhase = .finished
            } catch is CancellationError {
                guard storageAnalysisGeneration == generation else { return }
                storageAnalysisPhase = .cancelled
                await activityStore.refresh()
            } catch {
                guard storageAnalysisGeneration == generation else { return }
                storageAnalysisPhase = .failed
                storageAnalysisErrorMessage = error.localizedDescription
                await activityStore.refresh()
            }
        }
    }

    func cancelStorageAnalysis() {
        guard isAnalyzingStorage else { return }
        storageAnalysisCancellationRequested = true
        storageAnalysisPhase = .cancelling
        storageAnalysisTask?.cancel()
    }

    func replaceItemsForTesting(_ items: [StorageItem], scannedAt: Date = Date()) {
        guard !isScanning else { return }
        self.items = items
        migrationCompletions = [:]
        lastScanAt = scannedAt
        phase = .finished
        errorMessage = nil
    }

    /// 等解析结果在主 actor 上完成处理（包括拒收），供迟到结果测试确认。
    func trashProtectionCompletionForTesting() -> Task<Void, Never>? { trashProtectionTask }

    func replaceStorageAnalysisForTesting(_ result: StorageMapAnalysisResult) {
        guard !isAnalyzingStorage else { return }
        storageAnalysis = result
        storageAnalysisPhase = .finished
        storageAnalysisErrorMessage = nil
        storageMapCache = [
            PathSafety.normalizedPath(result.rootSnapshot.path): result.rootSnapshot
        ]
        storageMapNavigation = [result.rootSnapshot]
        storageMapForwardNavigation = []
        storageMapBrowsePhase = .idle
        resetTrash(for: result)
    }

    func openStorageMapDirectory(_ entry: StorageTreemapEntry, fromLevel level: Int? = nil) {
        guard entry.canDescend,
              !storageMapBrowsePhase.isLoading,
              storageMapBrowseTask == nil else { return }
        let baseLevel = level ?? storageMapNavigation.count - 1
        guard storageMapNavigation.indices.contains(baseLevel) else { return }
        let basePath = DiskScanner.storageMapLogicalPath(storageMapNavigation[baseLevel].path)
        let targetPath = DiskScanner.storageMapLogicalPath(entry.path)
        guard DiskScanner.storageMapPath(targetPath, isWithinRoot: basePath) else { return }

        // Direct navigation must keep every parent in the breadcrumb. Resolve
        // these levels from the completed index before changing navigation.
        var parentPaths: [String] = []
        var parent = DiskScanner.storageMapParentPath(targetPath)
        while targetPath != basePath, parent != basePath {
            guard DiskScanner.storageMapPath(parent, isWithinRoot: basePath), parent != "/" else { return }
            parentPaths.append(parent)
            parent = DiskScanner.storageMapParentPath(parent)
        }
        var parents: [StorageMapDirectorySnapshot] = []
        do {
            if !parentPaths.isEmpty {
                guard let index = storageAnalysis?.index else { return }
                let scanner = DiskScanner(excludedPaths: [])
                parents = try parentPaths.reversed().map { try scanner.storageMapSnapshot(at: $0, using: index) }
            }
        } catch {
            storageMapBrowsePhase = .failed(
                path: entry.path, title: entry.title, referenceBytes: entry.sizeBytes,
                referenceIsEstimated: entry.isEstimated, message: error.localizedDescription
            )
            return
        }
        truncateStorageMapNavigation(after: baseLevel, preserveForwardHistory: false)
        for snapshot in parents {
            storageMapCache[PathSafety.normalizedPath(snapshot.path)] = snapshot
            storageMapNavigation.append(snapshot)
        }
        openStorageMapDirectory(
            path: entry.path,
            title: entry.title,
            referenceBytes: entry.sizeBytes,
            referenceIsEstimated: entry.isEstimated
        )
    }

    func retryStorageMapBrowse() {
        guard case let .failed(
            path,
            title,
            referenceBytes,
            referenceIsEstimated,
            _
        ) = storageMapBrowsePhase else { return }
        openStorageMapDirectory(
            path: path,
            title: title,
            referenceBytes: referenceBytes,
            referenceIsEstimated: referenceIsEstimated
        )
    }

    func showStorageMapRoot() {
        guard !storageMapBrowsePhase.isLoading,
              !storageMapNavigation.isEmpty else { return }
        truncateStorageMapNavigation(after: 0, preserveForwardHistory: true)
        storageMapBrowsePhase = .idle
    }

    func showStorageMapSnapshot(at index: Int) {
        guard !storageMapBrowsePhase.isLoading,
              storageMapNavigation.indices.contains(index) else { return }
        truncateStorageMapNavigation(after: index, preserveForwardHistory: true)
        storageMapBrowsePhase = .idle
    }

    func showPreviousStorageMapLevel() {
        guard !storageMapBrowsePhase.isLoading,
              storageMapNavigation.count > 1 else { return }
        let removed = storageMapNavigation.removeLast()
        storageMapForwardNavigation.insert(removed, at: 0)
        storageMapBrowsePhase = .idle
    }

    func showNextStorageMapLevel() {
        guard !storageMapBrowsePhase.isLoading,
              !storageMapForwardNavigation.isEmpty else { return }
        storageMapNavigation.append(storageMapForwardNavigation.removeFirst())
        storageMapBrowsePhase = .idle
    }

    func cancelStorageMapBrowse() {
        guard storageMapBrowsePhase.isLoading else { return }
        storageMapBrowseTask?.cancel()
        storageMapBrowsePhase = .idle
    }

    private func openStorageMapDirectory(
        path: String,
        title: String,
        referenceBytes: Int64,
        referenceIsEstimated: Bool
    ) {
        let cacheKey = PathSafety.normalizedPath(path)
        if let existingIndex = storageMapNavigation.firstIndex(where: {
            PathSafety.normalizedPath($0.path) == cacheKey
        }) {
            truncateStorageMapNavigation(after: existingIndex, preserveForwardHistory: false)
            storageMapBrowsePhase = .idle
            return
        }
        if let cached = storageMapCache[cacheKey] {
            let referencedSnapshot = cached.referenced(
                totalBytes: referenceBytes,
                isEstimated: referenceIsEstimated
            )
            storageMapCache[cacheKey] = referencedSnapshot
            storageMapNavigation.append(referencedSnapshot)
            storageMapForwardNavigation = []
            storageMapBrowsePhase = .idle
            return
        }

        let generation = UUID()
        storageMapBrowseGeneration = generation
        storageMapBrowsePhase = .loading(
            path: path,
            title: title,
            referenceBytes: referenceBytes,
            referenceIsEstimated: referenceIsEstimated
        )
        let operation = directoryBrowseOperation
        let analysisIndex = storageAnalysis?.index
        let coordinator = coordinator
        let activityStore = activityStore

        storageMapBrowseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if storageMapBrowseGeneration == generation {
                    let finalPhase = storageMapBrowsePhase
                    storageMapBrowseGeneration = nil
                    storageMapBrowseTask = nil
                    storageMapBrowsePhase = finalPhase
                }
            }

            do {
                let snapshot = try await coordinator.withLease(owner: .largeFilesScan) { lease in
                    await activityStore.refresh()
                    try await coordinator.requireValid(lease, owner: .largeFilesScan)
                    let result = try await operation(path, analysisIndex)
                    try Task.checkCancellation()
                    return result
                }
                await activityStore.refresh()
                guard storageMapBrowseGeneration == generation else { return }
                let referencedSnapshot = snapshot.referenced(
                    totalBytes: referenceBytes,
                    isEstimated: referenceIsEstimated
                )
                storageMapCache[cacheKey] = referencedSnapshot
                storageMapNavigation.append(referencedSnapshot)
                storageMapForwardNavigation = []
                storageMapBrowsePhase = .idle
            } catch is CancellationError {
                await activityStore.refresh()
                guard storageMapBrowseGeneration == generation else { return }
                storageMapBrowsePhase = .idle
            } catch {
                await activityStore.refresh()
                guard storageMapBrowseGeneration == generation else { return }
                storageMapBrowsePhase = .failed(
                    path: path,
                    title: title,
                    referenceBytes: referenceBytes,
                    referenceIsEstimated: referenceIsEstimated,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func resetStorageMapNavigation(clearCache: Bool) {
        storageMapBrowseGeneration = nil
        storageMapBrowseTask?.cancel()
        storageMapBrowseTask = nil
        storageMapNavigation = []
        storageMapForwardNavigation = []
        storageMapBrowsePhase = .idle
        if clearCache { storageMapCache = [:] }
    }

    private func truncateStorageMapNavigation(
        after index: Int,
        preserveForwardHistory: Bool
    ) {
        guard storageMapNavigation.indices.contains(index) else { return }
        let removed = Array(storageMapNavigation.dropFirst(index + 1))
        storageMapNavigation = Array(storageMapNavigation.prefix(index + 1))
        storageMapForwardNavigation = preserveForwardHistory ? removed : []
    }

    private static let defaultListingScanOperation: ListingScanOperation = { threshold, progressHandler in
        try await scanLargeFiles(sourcePath: nil, threshold: threshold, progressHandler: progressHandler)
    }

    private static func scanLargeFiles(
        sourcePath: String?,
        threshold: LargeFileThreshold,
        progressHandler: @escaping DiskScanProgressHandler
    ) async throws -> LargeFileScanOutcome {
        try await Task.detached(priority: .utility) {
            let result = try DiskScanner(
                scanMode: .fallback,
                progressHandler: progressHandler,
                largeFileRoots: sourcePath.map { [$0] },
                largeFileThreshold: threshold
            ).scan()
            return LargeFileScanOutcome(items: result.items(for: .largeFiles), summary: result.largeFileListing)
        }.value
    }

    private static let defaultStorageAnalysisOperation: StorageAnalysisOperation = {
        target,
        progressHandler in
        let worker = Task.detached(priority: .utility) {
            try DiskScanner(scanMode: .fallback).storageMapAnalysis(
                target: target,
                progressHandler: progressHandler
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static let defaultDirectoryBrowseOperation: DirectoryBrowseOperation = { path, index in
        guard let index else { throw StorageMapAnalysisError.unavailable }
        let worker = Task.detached(priority: .userInitiated) {
            try DiskScanner(scanMode: .fallback).storageMapSnapshot(
                at: path,
                using: index
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

// MARK: - D46: move checked items to the Trash

enum FileAnalysisTrashPhase: Equatable, Sendable {
    case idle
    case preparingReview
    case reviewing
    case moving
}

/// A moved item as it left the index, and the identity it was moved with.
struct FileAnalysisTrashedItem: Equatable, Sendable {
    let removed: StorageMapRemovedItem
    let movedIdentity: FileIdentity?
}

extension LargeFilesStore {
    var selectedTrashBytes: Int64 {
        trashSelections.reduce(0) { $0 + max(0, $1.bytes) }
    }

    var canReviewTrash: Bool {
        trashSelections.contains { trashPolicy?.awaitsRefinement(of: $0.path) == false }
            && trashPhase == .idle
            && trashPolicy != nil
            && storageAnalysis != nil
            && !isAnalyzingStorage
            && !storageMapBrowsePhase.isLoading
    }

    /// 底栏说明只取决于当前索引中的检查中项目，不被点击提示覆盖。
    var trashRefinementNotice: String? {
        guard let policy = trashPolicy, let index = storageAnalysis?.index else { return nil }
        // P1-1：链接到达的受保护位置未知时，所有项目都在等待。
        if policy.awaitsProtectedLinkTargets {
            return FileAnalysisTrashPresentation.checkingNotice(.protectedLocations)
        }
        guard !policy.pendingRefinementPaths.isEmpty else { return nil }
        let hasCheckingItems = policy.pendingRefinementPaths.contains { pending in
            let parent = FileAnalysisTrashPolicy.protectedContains(index.rootPath, in: pending)
                ? index.rootPath : pending
            return (index.childrenByDirectory[parent] ?? []).contains { entry in
                let path = (parent as NSString).appendingPathComponent(entry.name)
                return policy.awaitsRefinement(of: path)
                    && FileAnalysisTrashService.block(for: path, entry: entry, index: index, policy: policy) == nil
            }
        }
        guard hasCheckingItems else { return nil }
        return FileAnalysisTrashPresentation.checkingNotice(policy.targetKind == .externalVolume ? .volume : .iCloud)
    }

    /// How the row for `entry` offers its checkbox. Pure lookups: rows ask
    /// while they draw.
    func trashSelectionState(for entry: StorageTreemapEntry) -> FileAnalysisTrashSelectionState {
        if trashSelections.contains(where: { $0.path == entry.path }) { return .selected }
        if let folder = trashSelections.first(where: { entry.path.hasPrefix($0.path + "/") }) {
            return .includedInSelection(folder.title)
        }
        guard let trashPolicy else { return .blocked(.unreadable) }
        if let block = trashPolicy.block(for: entry) {
            // P2-2: the reason names the apps whose original location is unknown.
            return .blocked(block, applications: block == .runningApplicationStateUnknown
                ? trashPolicy.unknownRunningApplicationNames : [])
        }
        if let check = trashPolicy.pendingCheck(for: entry.path) { return .checking(check) }
        return .available
    }

    /// Checks or unchecks an item. Checking a folder takes in what was
    /// checked inside it; an item that cannot move says why instead.
    func toggleTrashSelection(_ entry: StorageTreemapEntry) {
        guard trashPhase == .idle, storageAnalysis != nil else { return }
        trashOutcome = nil
        trashPutBackCount = 0
        trashNoticeDetail = nil
        if let index = trashSelections.firstIndex(where: { $0.path == entry.path }) {
            trashSelections.remove(at: index)
            trashNotice = nil
            return
        }
        // D54 ③: whether an app runs or a disk is mounted inside it, now.
        let pruned = refreshTrashRuntimeState()
        defer { if let pruned { trashNotice = [trashNotice, pruned].compactMap { $0 }.joined(separator: "\n") } }
        switch trashSelectionState(for: entry) {
        case .available:
            trashSelections.removeAll { $0.path.hasPrefix(entry.path + "/") }
            trashSelections.append(FileAnalysisTrashSelection(
                path: entry.path,
                title: entry.title,
                isDirectory: entry.isDirectory,
                kind: entry.kind,
                bytes: max(0, entry.sizeBytes),
                itemCount: entry.isDirectory
                    ? storageAnalysis?.index.directories[entry.path]?.descendantItemCount
                    : nil,
                presentsAsFolder: entry.kind == "package"
                    && trashPolicy?.nonApplicationBundlePaths.contains(entry.path) == true
            ))
            trashNotice = nil
        case .blocked(let block, let applications):
            let explanation = block.explanation(naming: applications)
            trashNotice = L10n.text(
                "“\(entry.title)”不能移到废纸篓：\(explanation)",
                "“\(entry.title)” cannot be moved to the Trash: \(explanation)"
            )
        case .includedInSelection(let folder):
            trashNotice = L10n.text(
                "“\(entry.title)”在已勾选的“\(folder)”里，会随它一起移走。",
                "“\(entry.title)” is inside the checked “\(folder)” and moves with it."
            )
        case .checking(let check):
            trashNotice = FileAnalysisTrashPresentation.checkingClickNotice(check, title: entry.title)
        case .selected:
            break
        }
    }

    func clearTrashSelection() {
        guard trashPhase == .idle else { return }
        trashSelections = []
        trashNotice = nil
        trashNoticeDetail = nil
    }

    /// Checks every item against the analysis and opens the review.
    func requestTrashReview() {
        guard canReviewTrash, storageAnalysis != nil else { return }
        trashOutcome = nil
        trashNotice = refreshTrashRuntimeState()
        trashNoticeDetail = nil
        trashPutBackCount = 0
        guard !trashSelections.isEmpty, let analysis = storageAnalysis, let policy = trashPolicy else { return }
        trashPhase = .preparingReview
        let selections = trashSelections.filter { !policy.awaitsRefinement(of: $0.path) }
        guard !selections.isEmpty else { trashPhase = .idle; return }
        let environment = trashEnvironment
        let index = analysis.index
        let volumeName = analysis.target.kind == .externalVolume ? analysis.target.title : nil
        let generation = trashGeneration
        trashTask = Task { @MainActor [weak self] in
            let review = await Task.detached(priority: .userInitiated) {
                FileAnalysisTrashService.review(selections, index: index, policy: policy,
                                                environment: environment, externalVolumeName: volumeName)
            }.value
            guard let self, self.trashGeneration == generation, self.trashPhase == .preparingReview else { return }
            self.trashReview = review
            self.trashPhase = .reviewing
            self.trashTask = nil
        }
    }

    func cancelTrashReview() {
        guard trashPhase == .preparingReview || trashPhase == .reviewing else { return }
        trashTask?.cancel()
        trashTask = nil
        trashReview = nil
        trashPhase = .idle
        // Review P2-10: what the review said does not stay in the bar.
        trashNotice = nil
        trashNoticeDetail = nil
    }

    /// Moves the review's ready items, each checked again right before it
    /// moves, under the cleanup lease. Afterwards the map drops what moved.
    func confirmTrash() {
        guard trashPhase == .reviewing, let review = trashReview, !review.readyItems.isEmpty,
              let analysis = storageAnalysis, let policy = trashPolicy else { return }
        trashPhase = .moving
        trashProgress = FileAnalysisTrashProgress(processed: 0, total: review.readyItems.count)
        let environment = trashEnvironment
        let coordinator = coordinator
        let activityStore = activityStore
        let index = analysis.index
        let generation = trashGeneration
        let relay = FileAnalysisTrashProgressRelay { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.trashGeneration == generation, self.trashPhase == .moving else { return }
                self.trashProgress = progress
            }
        }
        trashTask = Task { @MainActor [weak self] in
            do {
                let outcome = try await coordinator.withLease(owner: .cleanup) { lease in
                    await activityStore.refresh()
                    try await coordinator.requireValid(lease, owner: .cleanup)
                    return await FileAnalysisTrashService.execute(
                        review.items, index: index, policy: policy, environment: environment,
                        beforeEachMove: { try await coordinator.requireValid(lease, owner: .cleanup) },
                        progress: { relay.deliver($0) }
                    )
                }
                await activityStore.refresh()
                self?.finishTrash(outcome, generation: generation)
            } catch {
                await activityStore.refresh()
                guard let self, self.trashGeneration == generation else { return }
                self.trashTask = nil
                self.trashProgress = nil
                self.trashPhase = .reviewing
                self.reportTrashMoveFailure(error)
            }
        }
    }

    /// Review P2-10: why a move did not start, in people's words; the
    /// system's own words only under "Details".
    private func reportTrashMoveFailure(_ error: Error) {
        if case HeavyWorkCoordinator.Error.busy(let owner) = error {
            trashNotice = HeavyWorkActivityStore.conflictMessage(activeOwner: owner)
            trashNoticeDetail = nil
        } else {
            trashNotice = FileAnalysisTrashPresentation.moveDidNotStart
            trashNoticeDetail = FileAnalysisTrashPresentation.moveFailureDetail(error)
        }
    }

    /// Stops after the item that is moving now; nothing half-moved.
    func stopTrashMove() {
        guard trashPhase == .moving else { return }
        trashTask?.cancel()
    }

    func dismissTrashOutcome() {
        trashOutcome = nil
        trashPutBackCount = 0
        trashNotice = nil
        trashNoticeDetail = nil
    }

    // MARK: Private

    /// A new analysis starts a new round: nothing checked, nothing to put back.
    private func resetTrash(for result: StorageMapAnalysisResult) {
        trashTask?.cancel()
        trashTask = nil
        trashRefinementTasks.forEach { $0.cancel() }
        trashRefinementTasks = []
        trashRefinementTimeoutTask?.cancel()
        trashRefinementTimeoutTask = nil
        trashProtectionTask?.cancel()
        trashProtectionTask = nil
        trashGeneration = UUID()
        trashSelections = []
        trashReview = nil
        trashProgress = nil
        trashOutcome = nil
        trashNotice = nil
        trashNoticeDetail = nil
        trashPutBackCount = 0
        trashPhase = .idle
        trashedItems = []
        let environment = trashEnvironment
        // P1-1: only what needs no file system read happens here, on the
        // main actor; the links are found below, off the main thread, and
        // until then every item reads "checking".
        var startingPolicy = FileAnalysisTrashService.startingPolicy(for: result, environment: environment)
        let running = environment.runningApplicationState()
        startingPolicy.runningApplicationPaths = running.paths
        startingPolicy.unknownRunningApplicationNames = running.unknownApplicationNames
        let starting = startingPolicy
        trashPolicy = starting
        let generation = trashGeneration
        let index = result.index
        trashProtectionTask = Task { @MainActor [weak self] in
            let protection = await Task.detached(priority: .userInitiated) {
                FileAnalysisTrashService.protection(for: index, policy: starting, environment: environment)
            }.value
            guard !Task.isCancelled, let self, self.trashGeneration == generation,
                  let current = self.trashPolicy, current.awaitsProtectedLinkTargets else { return }
            let policy = FileAnalysisTrashService.applyingProtection(protection, to: current)
            if let pruned = self.applyTrashPolicy(policy) { self.trashNotice = pruned }
            if policy.isRefined { self.trashRefinementTimeoutTask?.cancel() }
        }
        for path in starting.pendingRefinementPaths.sorted() {
            trashRefinementTasks.append(Task { @MainActor [weak self] in
                let answer = await Task.detached(priority: .utility) {
                    FileAnalysisTrashService.refinementAnswer(for: path, policy: starting, environment: environment)
                }.value
                guard !Task.isCancelled, let self, self.trashGeneration == generation,
                      let current = self.trashPolicy, current.pendingRefinementPaths.contains(path) else { return }
                let policy = FileAnalysisTrashService.applyingRefinementAnswer(answer, for: path, to: current)
                if let pruned = self.applyTrashPolicy(policy) { self.trashNotice = pruned }
                if policy.isRefined { self.trashRefinementTimeoutTask?.cancel() }
            })
        }
        trashRefinementTimeoutTask = Task { @MainActor [weak self] in
            do { try await environment.waitForRefinementTimeout() } catch { return }
            guard !Task.isCancelled, let self, self.trashGeneration == generation,
                  let current = self.trashPolicy, !current.isRefined else { return }
            let policy = FileAnalysisTrashService.refinementTimedOut(current)
            if let pruned = self.applyTrashPolicy(policy) { self.trashNotice = pruned }
        }
    }

    /// D54 ③: reads the running apps and mount points again; checked items
    /// that can no longer move are unchecked. Returns what to tell.
    @discardableResult
    private func refreshTrashRuntimeState() -> String? {
        guard var policy = trashPolicy else { return nil }
        let running = trashEnvironment.runningApplicationState()
        policy.runningApplicationPaths = running.paths
        policy.unknownRunningApplicationNames = running.unknownApplicationNames
        policy.mountPointPaths = trashEnvironment.mountPointPaths()
        guard policy != trashPolicy else { return nil }
        return applyTrashPolicy(policy)
    }

    /// Installs new rules; a checked item they block is unchecked, and the
    /// returned note says which and why (D54 ③, review P2-12).
    private func applyTrashPolicy(_ policy: FileAnalysisTrashPolicy) -> String? {
        trashPolicy = policy
        guard trashPhase == .idle, let index = storageAnalysis?.index else { return nil }
        var dropped: [(title: String, block: FileAnalysisTrashBlock)] = []
        let blocks = FileAnalysisTrashService.selectionBlocks(trashSelections, index: index, policy: policy)
        trashSelections.removeAll { selection in
            guard let block = blocks[selection.path] else { return false }
            dropped.append((selection.title, block))
            return true
        }
        guard let first = dropped.first else { return nil }
        return dropped.count == 1
            ? L10n.text("已取消勾选“\(first.title)”：\(first.block.shortTitle)。",
                        "Unchecked “\(first.title)”: \(first.block.shortTitle).")
            : L10n.text("已取消勾选 \(dropped.count) 项，例如“\(first.title)”：\(first.block.shortTitle)。",
                        "Unchecked \(L10n.items(dropped.count)), such as “\(first.title)”: \(first.block.shortTitle).")
    }

    private func finishTrash(_ outcome: FileAnalysisTrashOutcome, generation: UUID) {
        guard trashGeneration == generation else { return }
        trashTask = nil
        trashProgress = nil
        trashReview = nil
        trashPhase = .idle
        // Review P2-8: after "Stop", what was not reached stays checked.
        let notReached = Set((outcome.report?.items ?? []).compactMap { row -> String? in
            if case .notProcessed = row.outcome { return row.sourcePath }
            return nil
        })
        trashSelections = outcome.cancelled ? trashSelections.filter { notReached.contains($0.path) } : []
        trashOutcome = outcome
        guard !outcome.movedPaths.isEmpty, var analysis = takeStorageAnalysisForEditing() else { return }
        let identities = Dictionary(
            (outcome.report?.items ?? []).compactMap { row -> (String, FileIdentity?)? in
                guard case .moved(let receipt) = row.outcome else { return nil }
                return (row.sourcePath, receipt.movedIdentity)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for path in outcome.movedPaths {
            if let removed = analysis.removeItem(at: path) {
                trashedItems.append(FileAnalysisTrashedItem(removed: removed, movedIdentity: identities[path] ?? nil))
            }
        }
        installEditedStorageAnalysis(analysis)
    }

    /// Items Operation History put back come back into the map, where and as
    /// they were, when the same item (by identity) is back in its place.
    private func putBackRestoredTrashItems(_ receipts: [CleanupMoveReceipt]) {
        guard !trashedItems.isEmpty, trashPhase != .moving else { return }
        let metadata = trashEnvironment.metadata
        let returning = trashedItems.filter { item in
            receipts.contains { receipt in
                guard receipt.originalPath == item.removed.path,
                      let identity = receipt.movedIdentity,
                      identity == item.movedIdentity else { return false }
                return (try? metadata.snapshot(at: URL(fileURLWithPath: item.removed.path)).identity) == identity
            }
        }
        guard !returning.isEmpty, var analysis = takeStorageAnalysisForEditing() else { return }
        // Last out, first back: each item's place among its siblings, and a
        // folder that went later than something inside it, come back first.
        var putBack = 0
        for item in returning.reversed() where analysis.reinsert(item.removed) {
            putBack += 1
            trashedItems.removeAll { $0.removed.path == item.removed.path }
        }
        installEditedStorageAnalysis(analysis)
        trashPutBackCount += putBack
    }

    /// Takes the analysis out of the store, so changing it does not copy
    /// the index (the store held the only other reference).
    private func takeStorageAnalysisForEditing() -> StorageMapAnalysisResult? {
        guard let analysis = storageAnalysis else { return nil }
        storageAnalysis = nil
        return analysis
    }

    /// Puts the edited analysis back and rebuilds every level the page holds
    /// from it; a level whose folder is gone ends the path there.
    private func installEditedStorageAnalysis(_ edited: StorageMapAnalysisResult) {
        var analysis = edited
        let scanner = DiskScanner(excludedPaths: [])
        if let root = try? scanner.storageMapSnapshot(
            at: analysis.index.rootPath, using: analysis.index, titleOverride: analysis.target.title
        ) {
            analysis.rootSnapshot = root
        }
        storageAnalysis = analysis
        func rebuilt(_ snapshots: [StorageMapDirectorySnapshot]) -> [StorageMapDirectorySnapshot] {
            var result: [StorageMapDirectorySnapshot] = []
            for snapshot in snapshots {
                if snapshot.path == analysis.rootSnapshot.path {
                    result.append(analysis.rootSnapshot)
                } else if let fresh = try? scanner.storageMapSnapshot(at: snapshot.path, using: analysis.index) {
                    result.append(fresh)
                } else {
                    break
                }
            }
            return result
        }
        let navigation = rebuilt(storageMapNavigation)
        let forward = navigation.count == storageMapNavigation.count ? rebuilt(storageMapForwardNavigation) : []
        storageMapNavigation = navigation.isEmpty ? [analysis.rootSnapshot] : navigation
        storageMapForwardNavigation = forward
        storageMapCache = Dictionary(
            (storageMapNavigation + storageMapForwardNavigation).map { (PathSafety.normalizedPath($0.path), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

#if DEBUG || STORAGE_CLEANER_BETA
extension LargeFilesStore {
    /// Screenshot pipeline only, on a fixture folder: the rules, the review
    /// and any move read this environment from now on (fixture journal and
    /// fixture "Trash"; the pipeline builds it).
    func useTrashEnvironmentForCapture(_ environment: FileAnalysisTrashEnvironment) {
        trashEnvironment = environment
    }

    /// Screenshot pipeline only: how a move that could not start reads.
    func showTrashMoveFailureForCapture(_ error: Error) {
        guard trashPhase == .reviewing else { return }
        reportTrashMoveFailure(error)
    }
}
#endif

/// Hands progress from the move's threads to the main actor, at most about
/// ten times a second, and always the last one.
final class FileAnalysisTrashProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let deliverOnMain: @Sendable (FileAnalysisTrashProgress) -> Void
    private var lastDelivery = Date.distantPast
    private var lastProcessed = -1
    private var lastVerifyingTitle: String?

    init(_ deliverOnMain: @escaping @Sendable (FileAnalysisTrashProgress) -> Void) {
        self.deliverOnMain = deliverOnMain
    }

    func deliver(_ progress: FileAnalysisTrashProgress) {
        let now = Date()
        let send: Bool = lock.withLock {
            // Review P2-11: a new item or a new folder being compared always
            // shows at once.
            guard progress.processed != lastProcessed || progress.verifyingTitle != lastVerifyingTitle
                    || now.timeIntervalSince(lastDelivery) >= 0.1 else { return false }
            lastProcessed = progress.processed
            lastVerifyingTitle = progress.verifyingTitle
            lastDelivery = now
            return true
        }
        if send { deliverOnMain(progress) }
    }
}
