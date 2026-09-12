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

@MainActor
final class LargeFilesStore: ObservableObject {
    typealias ScanOperation = @Sendable (
        @escaping DiskScanProgressHandler
    ) async throws -> [StorageItem]
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
    }

    private let defaults: UserDefaults
    private let coordinator: HeavyWorkCoordinator
    private let activityStore: HeavyWorkActivityStore
    private let scanOperation: ScanOperation
    private let storageAnalysisOperation: StorageAnalysisOperation
    private let directoryBrowseOperation: DirectoryBrowseOperation

    @Published private(set) var items: [StorageItem] = []
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

    @Published private(set) var migrationSourcePath: String? = nil
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

    private var scanTask: Task<Void, Never>?
    private var scanGeneration: UUID?
    private var storageAnalysisTask: Task<Void, Never>?
    private var storageAnalysisGeneration: UUID?
    private var storageMapBrowseTask: Task<Void, Never>?
    private var storageMapBrowseGeneration: UUID?
    private var storageMapCache: [String: StorageMapDirectorySnapshot] = [:]
    private let usesDefaultScanOperation: Bool

    init(
        coordinator: HeavyWorkCoordinator,
        activityStore: HeavyWorkActivityStore,
        defaults: UserDefaults = .standard,
        scanOperation: ScanOperation? = nil,
        storageMapTargets: [StorageMapScanTarget]? = nil,
        storageAnalysisOperation: StorageAnalysisOperation? = nil,
        directoryBrowseOperation: DirectoryBrowseOperation? = nil
    ) {
        self.coordinator = coordinator
        self.activityStore = activityStore
        self.defaults = defaults
        self.scanOperation = scanOperation ?? Self.defaultScanOperation
        usesDefaultScanOperation = scanOperation == nil
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
    }

    var currentStorageMapSnapshot: StorageMapDirectorySnapshot? {
        storageMapNavigation.last
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
        let operation = scanOperation
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
                            progressHandler: progressHandler
                        )
                    } else {
                        try await operation(progressHandler)
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
                items = scannedItems
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
        lastScanAt = scannedAt
        phase = .finished
        errorMessage = nil
    }

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
    }

    var storageMapSunburstSegments: [StorageSunburstLayout.Segment] {
        guard let currentStorageMapSnapshot else { return [] }
        let rootEntries = StorageTreemapPresentation.mapLayoutEntries(
            from: StorageTreemapPresentation.visibleEntries(from: currentStorageMapSnapshot),
            measuredBytes: currentStorageMapSnapshot.measuredBytes,
            referenceBytes: currentStorageMapSnapshot.referenceBytes,
            limit: 30
        )
        let scanner = DiskScanner(excludedPaths: [])
        return StorageSunburstLayout.segments(entries: rootEntries) { entry in
            guard let index = storageAnalysis?.index,
                  let snapshot = try? scanner.storageMapSnapshot(at: entry.path, using: index) else { return [] }
            // ponytail: bound child wedges; the existing list exposes every indexed item.
            return StorageTreemapPresentation.mapLayoutEntries(
                from: snapshot.entries,
                measuredBytes: snapshot.measuredBytes,
                referenceBytes: snapshot.referenceBytes,
                limit: 6
            )
        }
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

        // Deep sunburst sectors must keep every parent in the breadcrumb. Resolve
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

    private static let defaultScanOperation: ScanOperation = { progressHandler in
        try await scanLargeFiles(sourcePath: nil, progressHandler: progressHandler)
    }

    private static func scanLargeFiles(
        sourcePath: String?,
        progressHandler: @escaping DiskScanProgressHandler
    ) async throws -> [StorageItem] {
        try await Task.detached(priority: .utility) {
            let result = try DiskScanner(
                scanMode: .fallback,
                progressHandler: progressHandler,
                largeFileRoots: sourcePath.map { [$0] }
            ).scan()
            return result.items(for: .largeFiles)
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
