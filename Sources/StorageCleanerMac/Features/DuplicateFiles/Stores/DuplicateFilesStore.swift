import Foundation

enum DuplicateResultFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case exact
    case sameName
    case sameSize
    case sameType
    case similarImage
    case candidates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .exact: L10n.text("内容完全相同", "Exact Matches")
        case .sameName: DuplicateFileCandidateGroup.Rule.sameName.title
        case .sameSize: DuplicateFileCandidateGroup.Rule.sameSize.title
        case .sameType: DuplicateFileCandidateGroup.Rule.sameType.title
        case .similarImage: DuplicateFileCandidateGroup.Rule.similarImage.title
        case .candidates: L10n.text("人工候选", "Review Candidates")
        }
    }
}

enum DuplicateResultSort: String, CaseIterable, Identifiable, Sendable {
    case reclaimable
    case size
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reclaimable: L10n.text("可审阅空间", "Reviewable Space")
        case .size: L10n.text("单个大小", "File Size")
        case .name: L10n.text("名称", "Name")
        }
    }
}

@MainActor
final class DuplicateFilesStore: ObservableObject {
    typealias ScanOperation = @Sendable (
        _ configuration: DuplicateFileScanner.Configuration,
        _ resumeIndexData: Data?,
        _ control: DuplicateFileScanControl,
        _ resumeIndex: @escaping DuplicateFileScanner.ResumeIndexHandler,
        _ progress: @escaping DuplicateFileScanner.ProgressHandler
    ) async throws -> DuplicateFileScanReport

    private enum Key {
        static let searchText = "duplicate-files.search-text"
        static let resultFilter = "duplicate-files.result-filter"
        static let resultSort = "duplicate-files.result-sort"
        static let customRoots = "duplicate-files.custom-roots"
        static let externalRoots = "duplicate-files.external-roots"
        static let candidateRules = "duplicate-files.candidate-rules"
        static let candidateRulesVersion = "duplicate-files.candidate-rules-version"
        static let scanScope = "duplicate-files.scan-scope"
    }

    private static let currentCandidateRulesVersion = 2

    private let defaults: UserDefaults
    private let coordinator: HeavyWorkCoordinator
    private let activityStore: HeavyWorkActivityStore
    private let scanOperation: ScanOperation
    private let resultStore: DuplicateFileResultStore?

    @Published private(set) var items: [StorageItem] = []
    @Published private(set) var phase: FeatureScanPhase = .idle
    @Published private(set) var scanProgress: DuplicateFileScanProgress?
    @Published private(set) var scanCoverage: DuplicateFileScanCoverage?
    @Published private(set) var scanOutcome: DuplicateFileScanOutcome?
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var scanSeconds: TimeInterval?
    @Published private(set) var errorMessage: String?
    @Published private(set) var cancellationRequested = false

    @Published var searchText: String {
        didSet { defaults.set(searchText, forKey: Key.searchText) }
    }
    @Published var resultFilter: DuplicateResultFilter {
        didSet { defaults.set(resultFilter.rawValue, forKey: Key.resultFilter) }
    }
    @Published var resultSort: DuplicateResultSort {
        didSet { defaults.set(resultSort.rawValue, forKey: Key.resultSort) }
    }
    @Published private(set) var customRootPaths: [String] {
        didSet { defaults.set(customRootPaths, forKey: Key.customRoots) }
    }
    @Published private(set) var externalRootPaths: [String] {
        didSet { defaults.set(externalRootPaths, forKey: Key.externalRoots) }
    }
    @Published private(set) var candidateRules: Set<DuplicateFileCandidateGroup.Rule> {
        didSet {
            defaults.set(
                candidateRules.map(\.rawValue).sorted(),
                forKey: Key.candidateRules
            )
        }
    }
    @Published var scanScope: DuplicateFileScanScope {
        didSet { defaults.set(scanScope.rawValue, forKey: Key.scanScope) }
    }
    @Published private(set) var selectedItemIDs = Set<String>()
    @Published private(set) var selectionMessage: String?

    private var scanTask: Task<Void, Never>?
    private var resultRestoreTask: Task<Void, Never>?
    private var scanGeneration: UUID?
    private var scanControl: DuplicateFileScanControl?
    private var lastScanConfiguration: DuplicateFileScanner.Configuration?

    init(
        defaults: UserDefaults = .standard,
        coordinator: HeavyWorkCoordinator? = nil,
        activityStore: HeavyWorkActivityStore? = nil,
        scanOperation: ScanOperation? = nil,
        resultStore: DuplicateFileResultStore? = nil
    ) {
        let resolvedCoordinator = coordinator ?? HeavyWorkCoordinator()
        self.defaults = defaults
        self.coordinator = resolvedCoordinator
        self.activityStore = activityStore ?? HeavyWorkActivityStore(coordinator: resolvedCoordinator)
        self.scanOperation = scanOperation ?? Self.defaultScanOperation
        self.resultStore = resultStore ?? (defaults === UserDefaults.standard
            ? DuplicateFileResultStore()
            : nil)
        searchText = defaults.string(forKey: Key.searchText) ?? ""
        resultFilter = DuplicateResultFilter(
            rawValue: defaults.string(forKey: Key.resultFilter) ?? ""
        ) ?? .all
        resultSort = DuplicateResultSort(
            rawValue: defaults.string(forKey: Key.resultSort) ?? ""
        ) ?? .reclaimable
        customRootPaths = Self.normalizedPaths(defaults.stringArray(forKey: Key.customRoots) ?? [])
        externalRootPaths = Self.normalizedPaths(defaults.stringArray(forKey: Key.externalRoots) ?? [])
        let savedRules = defaults.stringArray(forKey: Key.candidateRules)?
            .compactMap(DuplicateFileCandidateGroup.Rule.init(rawValue:))
        var restoredRules = Set(savedRules ?? DuplicateFileCandidateGroup.Rule.selectableCases)
        if defaults.integer(forKey: Key.candidateRulesVersion) < Self.currentCandidateRulesVersion {
            restoredRules.insert(.similarImage)
            defaults.set(
                restoredRules.map(\.rawValue).sorted(),
                forKey: Key.candidateRules
            )
            defaults.set(Self.currentCandidateRulesVersion, forKey: Key.candidateRulesVersion)
        }
        candidateRules = restoredRules
            .intersection(DuplicateFileCandidateGroup.Rule.selectableCases)
        scanScope = DuplicateFileScanScope(
            rawValue: defaults.string(forKey: Key.scanScope) ?? ""
        ) ?? .userFiles

        if let resultStore = self.resultStore {
            let configuration = Self.configuration(
                scope: scanScope,
                customRootPaths: customRootPaths,
                externalRootPaths: externalRootPaths,
                candidateRules: candidateRules
            )
            // Revalidate only the saved snapshot off the main actor. Loading a
            // previous result never starts discovery or revives its selection.
            resultRestoreTask = Task { [weak self] in
                let restored = await Task.detached(priority: .utility) {
                    resultStore.load(configuration: configuration)
                }.value
                guard let self, let restored,
                      self.scanGeneration == nil,
                      self.phase == .idle,
                      self.lastScanAt == nil,
                      Self.configuration(
                        scope: self.scanScope,
                        customRootPaths: self.customRootPaths,
                        externalRootPaths: self.externalRootPaths,
                        candidateRules: self.candidateRules
                      ) == configuration else { return }
                self.items = restored.items
                self.scanCoverage = restored.coverage
                self.scanProgress = restored.progress
                self.scanOutcome = restored.outcome
                self.lastScanAt = restored.lastScanAt
                self.scanSeconds = restored.scanSeconds
                self.lastScanConfiguration = restored.configuration
                self.phase = .finished
            }
        }
    }

    var isScanning: Bool {
        phase == .scanning || phase == .paused || phase == .cancelling
    }

    var hasScanned: Bool {
        lastScanAt != nil
    }

    var lastCompletedScanScope: DuplicateFileScanScope? {
        lastScanConfiguration?.scope
    }

    var canScan: Bool {
        !isScanning && scanTask == nil
    }

    func startScan() {
        guard canScan else { return }

        let configuration = Self.configuration(
            scope: scanScope,
            customRootPaths: customRootPaths,
            externalRootPaths: externalRootPaths,
            candidateRules: candidateRules
        )
        let control = DuplicateFileScanControl()
        let resumeStore = DuplicateFileResumeIndexStore()
        let resumeIndexData = resumeStore.load()
        let generation = UUID()
        scanGeneration = generation
        scanControl = control
        phase = .scanning
        cancellationRequested = false
        errorMessage = nil
        scanProgress = .initial
        scanCoverage = nil
        scanOutcome = nil
        let started = Date()
        let operation = scanOperation
        let coordinator = coordinator
        let activityStore = activityStore

        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if scanGeneration == generation {
                    scanGeneration = nil
                    scanControl = nil
                    scanTask = nil
                    if phase == .cancelling {
                        phase = .cancelled
                    }
                }
            }
            do {
                let report = try await coordinator.withLease(owner: .duplicateScan) { lease in
                    await activityStore.refresh()
                    try await coordinator.requireValid(lease, owner: .duplicateScan)
                    return try await operation(
                        configuration,
                        resumeIndexData,
                        control,
                        { data in
                            if let data {
                                try? resumeStore.save(data)
                            } else {
                                try? resumeStore.clear()
                            }
                        },
                        { [weak self, progressThrottle = ScanProgressThrottle()] progress in
                            guard progressThrottle.shouldDeliver(phase: progress.phase.rawValue) else {
                                return
                            }
                            Task { @MainActor [weak self] in
                                guard let self, self.scanGeneration == generation else { return }
                                self.scanProgress = progress
                                if progress.phase == .paused {
                                    self.phase = .paused
                                } else if self.phase == .paused {
                                    self.phase = .scanning
                                }
                            }
                        }
                    )
                }
                await activityStore.refresh()
                guard scanGeneration == generation else { return }
                scanProgress = report.progress
                scanCoverage = report.coverage
                scanOutcome = report.outcome
                scanSeconds = Date().timeIntervalSince(started)
                if Task.isCancelled || cancellationRequested || report.outcome == .cancelled {
                    phase = .cancelled
                    return
                }
                items = Self.storageItems(from: report)
                let completedAt = Date()
                lastScanAt = completedAt
                lastScanConfiguration = configuration
                persistCurrentResult()
                phase = .finished
                reconcileSelection(with: items)
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

    func pauseScan() {
        guard phase == .scanning else { return }
        scanControl?.pause()
        phase = .paused
    }

    func resumeScan() {
        guard phase == .paused else { return }
        scanControl?.resume()
        phase = .scanning
    }

    func cancelScan() {
        guard phase == .scanning || phase == .paused else { return }
        cancellationRequested = true
        phase = .cancelling
        scanControl?.cancel()
        scanTask?.cancel()
    }

    func waitForCurrentScan() async {
        await scanTask?.value
    }

    func waitForResultRestore() async {
        await resultRestoreTask?.value
    }

    func replaceItemsForTesting(_ items: [StorageItem], scannedAt: Date = Date()) {
        guard !isScanning else { return }
        self.items = items
        lastScanAt = scannedAt
        phase = .finished
        errorMessage = nil
        reconcileSelection(with: items)
    }

    func markItemsMoved(at paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for index in items.indices
        where paths.contains(PathSafety.lexicalPath(items[index].path)) {
            items[index].status = .movedToTrash
        }
        reconcileSelection(with: items)
        persistCurrentResult()
    }

    func markItemsRestored(at paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for index in items.indices
        where paths.contains(PathSafety.lexicalPath(items[index].path)) {
            items[index].status = .available
        }
        persistCurrentResult()
    }

    static func storageItems(from report: DuplicateFileScanReport) -> [StorageItem] {
        let exactItems = DiskScanner.itemsForDuplicateGroups(report.exactGroups)
        let candidateItems = report.candidates.flatMap { group in
            group.files.map { entry in
                let fileType = URL(fileURLWithPath: entry.path).pathExtension.uppercased()
                return StorageItem(
                    id: "duplicate-candidate|\(group.id)|\(entry.id)",
                    title: entry.name,
                    path: entry.path,
                    sourceID: "duplicate_candidates",
                    groupTitle: L10n.text("人工候选", "Review Candidate"),
                    sizeBytes: entry.sizeBytes,
                    tier: .yellow,
                    kind: fileType.isEmpty ? L10n.text("文件", "File") : fileType,
                    reason: group.rule.explanation,
                    recommendation: L10n.text(
                        "请人工比较；此候选默认不选，也不能进入安全清理。",
                        "Compare manually. This candidate is unselected by default and cannot enter safe cleanup."
                    ),
                    risk: L10n.text("需人工确认", "Manual review required"),
                    requiresClose: L10n.text("无", "None"),
                    trashPaths: [],
                    openPath: entry.path,
                    duplicateGroupID: "candidate|\(group.id)",
                    duplicateMatchKind: group.rule.rawValue,
                    status: .available
                )
            }
        }
        return exactItems + candidateItems
    }

    private static let defaultScanOperation: ScanOperation = { configuration, resumeIndexData, control, resumeIndex, progress in
        await Task.detached(priority: .utility) {
            DuplicateFileScanner.scanReport(
                configuration: configuration,
                resumeIndexData: resumeIndexData,
                control: control,
                resumeIndex: resumeIndex,
                progress: progress
            )
        }.value
    }

    private static func configuration(
        scope: DuplicateFileScanScope,
        customRootPaths: [String],
        externalRootPaths: [String],
        candidateRules: Set<DuplicateFileCandidateGroup.Rule>
    ) -> DuplicateFileScanner.Configuration {
        switch scope {
        case .userFiles:
            .userFiles(
                customRoots: customRootPaths,
                externalVolumeRoots: externalRootPaths,
                candidateRules: candidateRules
            )
        case .wholeComputer:
            .wholeComputer(
                customRoots: customRootPaths,
                externalVolumeRoots: externalRootPaths,
                candidateRules: candidateRules
            )
        }
    }

    var configuredAdditionalRoots: [String] {
        Self.normalizedPaths(customRootPaths + externalRootPaths)
    }

    func addCustomRoot(_ path: String) {
        customRootPaths = Self.normalizedPaths(customRootPaths + [path])
    }

    func removeCustomRoot(_ path: String) {
        let lexical = PathSafety.lexicalPath(path)
        customRootPaths.removeAll { $0 == lexical }
    }

    func addExternalRoot(_ path: String) {
        externalRootPaths = Self.normalizedPaths(externalRootPaths + [path])
    }

    func removeExternalRoot(_ path: String) {
        let lexical = PathSafety.lexicalPath(path)
        externalRootPaths.removeAll { $0 == lexical }
    }

    func isCandidateRuleEnabled(_ rule: DuplicateFileCandidateGroup.Rule) -> Bool {
        candidateRules.contains(rule)
    }

    func setCandidateRule(_ rule: DuplicateFileCandidateGroup.Rule, enabled: Bool) {
        guard DuplicateFileCandidateGroup.Rule.selectableCases.contains(rule) else { return }
        if enabled {
            candidateRules.insert(rule)
        } else {
            candidateRules.remove(rule)
        }
    }

    func isSelected(_ item: StorageItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func setSelected(_ selected: Bool, item: StorageItem, allItems: [StorageItem]) {
        selectionMessage = nil
        guard selected else {
            selectedItemIDs.remove(item.id)
            return
        }
        guard item.status == .available,
              item.duplicateMatchKind == DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue,
              let groupID = item.duplicateGroupID else {
            selectionMessage = L10n.text(
                "只有完整 SHA-256 确认的副本才能进入安全清理。",
                "Only copies confirmed by a full SHA-256 hash can enter safe cleanup."
            )
            return
        }
        let groupItems = allItems.filter {
            $0.duplicateGroupID == groupID && $0.status == .available
        }
        let selectedCount = groupItems.reduce(0) {
            $0 + (selectedItemIDs.contains($1.id) ? 1 : 0)
        }
        guard groupItems.count - selectedCount > 1 else {
            selectionMessage = L10n.text(
                "每组必须至少保留一份未选中的副本。",
                "At least one unselected copy must remain in every group."
            )
            return
        }
        let homePath = PathSafety.lexicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
        guard PathSafety.isContained(item.path, in: homePath, resolvingSymlinks: false) else {
            selectionMessage = L10n.text(
                "外接卷结果当前仅供审阅，不能在应用内移动。",
                "External-volume results are review-only and cannot be moved in the app."
            )
            return
        }
        selectedItemIDs.insert(item.id)
    }

    func reconcileSelection(with items: [StorageItem]) {
        let availableIDs = Set(items.filter { $0.status == .available }.map(\.id))
        selectedItemIDs.formIntersection(availableIDs)
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
        selectionMessage = nil
    }

    func selectedItems(from items: [StorageItem]) -> [StorageItem] {
        items.filter { selectedItemIDs.contains($0.id) && $0.status == .available }
    }

    func dismissSelectionMessage() {
        selectionMessage = nil
    }

    private func persistCurrentResult() {
        guard let resultStore,
              let configuration = lastScanConfiguration,
              let lastScanAt,
              let scanCoverage,
              let scanProgress,
              let scanOutcome else {
            return
        }
        try? resultStore.save(
            configuration: configuration,
            items: items,
            coverage: scanCoverage,
            progress: scanProgress,
            outcome: scanOutcome,
            lastScanAt: lastScanAt,
            scanSeconds: scanSeconds
        )
    }

    private static func normalizedPaths(_ paths: [String]) -> [String] {
        // Keep explicitly selected symlink roots lexical so the scanner can
        // reject them instead of silently following their targets.
        Array(Set(paths.map(PathSafety.lexicalPath).filter { !$0.trimmed.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

enum VerifiedDuplicateRequestFactory {
    static func makeRequests(
        selectedItemIDs: Set<String>,
        items: [StorageItem],
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        metadataReader: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()
    ) throws -> [VerifiedDuplicatePlanRequest] {
        guard !selectedItemIDs.isEmpty else {
            throw VerifiedDuplicatePlanBuildError.emptySelection
        }
        let selectedItems = items.filter {
            selectedItemIDs.contains($0.id) && $0.status == .available
        }
        guard selectedItems.count == selectedItemIDs.count,
              selectedItems.allSatisfy({
                  $0.duplicateMatchKind == DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue
                      && $0.duplicateGroupID != nil
              }) else {
            throw VerifiedDuplicatePlanBuildError.invalidEvidence
        }

        let homePath = PathSafety.lexicalPath(userHomeURL.path)
        let itemsByGroup = Dictionary(grouping: items.filter { $0.status == .available }) {
            $0.duplicateGroupID ?? ""
        }
        return try selectedItems.map { item in
            guard let groupID = item.duplicateGroupID,
                  let digest = Data(base64Encoded: groupID),
                  digest.count == VerifiedDuplicateEvidence.digestByteCount else {
                throw VerifiedDuplicatePlanBuildError.invalidEvidence
            }
            let sourcePath = PathSafety.lexicalPath(item.path)
            guard PathSafety.isContained(sourcePath, in: homePath, resolvingSymlinks: false) else {
                throw VerifiedDuplicatePlanBuildError.targetOutsideUserHome
            }
            let retainedItems = (itemsByGroup[groupID] ?? []).filter {
                !selectedItemIDs.contains($0.id)
                    && $0.duplicateMatchKind == DuplicateFileGroup.MatchKind.logicalContentSHA256.rawValue
            }
            guard !retainedItems.isEmpty else {
                throw VerifiedDuplicatePlanBuildError.noRetainedCopy
            }

            let sourceURL = URL(fileURLWithPath: sourcePath)
            let snapshot = try metadataReader.snapshot(at: sourceURL)
            let retained = try retainedItems.map { retainedItem in
                let retainedURL = URL(fileURLWithPath: PathSafety.lexicalPath(retainedItem.path))
                return VerifiedDuplicateRetainedCopy(
                    url: retainedURL,
                    expectedSnapshot: try metadataReader.snapshot(at: retainedURL)
                )
            }
            return VerifiedDuplicatePlanRequest(
                sourceURL: sourceURL,
                allowedRootURL: sourceURL.deletingLastPathComponent(),
                expectedSnapshot: snapshot,
                groupID: groupID,
                digest: digest,
                retainedCopies: retained
            )
        }
    }
}
