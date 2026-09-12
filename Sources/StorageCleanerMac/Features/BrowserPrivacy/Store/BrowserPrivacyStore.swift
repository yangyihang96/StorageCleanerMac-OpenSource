import Combine
import Foundation

/// Owns the new record-level browser-privacy session.  It intentionally has no
/// persistence: URLs, titles, selections, and guidance reports leave memory
/// when the user clears the session or the app exits.
@MainActor
final class BrowserPrivacyStore: ObservableObject {
    @Published private(set) var state: BrowserPrivacyScanState = .idle
    @Published private(set) var records: [BrowserPrivacyRecord] = []
    @Published private(set) var coverage: [BrowserPrivacyProviderCoverage] = []
    @Published var filters: BrowserPrivacyFilters = .empty {
        didSet { rebuildFilteredRecords() }
    }
    @Published var groupsByWebsite = true
    @Published var resultSort: BrowserPrivacyResultSort = .largestFirst {
        didSet { rebuildFilteredRecords() }
    }
    @Published private(set) var filteredRecords: [BrowserPrivacyRecord] = []
    @Published private(set) var filteredDisplayItems: [BrowserPrivacyDisplayItem] = []
    @Published private(set) var selectedRecordIDs = Set<UUID>()
    @Published private(set) var runningBrowserIDs = Set<String>()
    @Published private(set) var processingReport: BrowserPrivacyProcessingReport?
    @Published private(set) var manualGuidanceRecords: [BrowserPrivacyRecord] = []
    @Published private(set) var reverificationStatus: BrowserPrivacyReverificationStatus?
    @Published private(set) var isProcessing = false
    @Published private(set) var isRunningBrowserPreflight = false
    @Published private(set) var error: BrowserPrivacyScanError?
    @Published private(set) var resultRevision = 0
    @Published private(set) var scanSnapshot: BrowserPrivacyScanSnapshot?

    private struct ScanOperation {
        let generation: UUID
        let task: Task<Void, Never>
        /// A refresh keeps the last completed in-memory result visible. This
        /// state is restored if the refresh is cancelled or fails, while the
        /// error remains available for a truthful UI notice.
        let fallbackState: BrowserPrivacyScanState?
    }

    private struct ProcessingOperation {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private let scanner: any BrowserPrivacyScanning
    private let processor: any BrowserPrivacyHistoryProcessing
    private let runningApplicationChecker: any BrowserPrivacyRunningApplicationChecking
    private var scanOperation: ScanOperation?
    private var processingOperation: ProcessingOperation?
    private var runningStatusTask: Task<Void, Never>?
    private var reverificationBaseline: BrowserPrivacyReverificationBaseline?

    init(
        scanner: any BrowserPrivacyScanning = BrowserPrivacyRecordScanner(),
        processor: any BrowserPrivacyHistoryProcessing = BrowserPrivacyHistoryProcessor(),
        runningApplicationChecker: any BrowserPrivacyRunningApplicationChecking = BrowserPrivacyWorkspaceRunningApplicationChecker()
    ) {
        self.scanner = scanner
        self.processor = processor
        self.runningApplicationChecker = runningApplicationChecker
    }

    private static func filter(
        records: [BrowserPrivacyRecord],
        filters: BrowserPrivacyFilters,
        sort: BrowserPrivacyResultSort
    ) -> [BrowserPrivacyRecord] {
        let calendar = Calendar.current
        let upperDate = filters.endDate.flatMap {
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))
        }
        let query = Self.normalizedSearch(filters.query)
        let domain = filters.domain.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let keyword = filters.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return records.filter { record in
            guard (filters.browserID == nil || record.browser.id == filters.browserID),
                  (filters.profileID == nil || record.profileID == filters.profileID),
                  (filters.category == nil || record.category == filters.category),
                  (filters.source == nil || record.source == filters.source),
                  (filters.confidence == nil || record.selectionConfidence == filters.confidence) else {
                return false
            }
            if let startDate = filters.startDate,
               let visitedAt = record.visitedAt,
               visitedAt < calendar.startOfDay(for: startDate) {
                return false
            } else if filters.startDate != nil, record.visitedAt == nil {
                return false
            }
            if let upperDate,
               let visitedAt = record.visitedAt,
               visitedAt >= upperDate {
                return false
            } else if filters.endDate != nil, record.visitedAt == nil {
                return false
            }
            let normalizedDomain = record.domain?.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) ?? ""
            guard domain.isEmpty || normalizedDomain.contains(domain) else {
                return false
            }
            if !query.isEmpty {
                let searchable = [
                    record.browser.displayName,
                    record.profileID,
                    record.title ?? "",
                    normalizedDomain,
                    record.searchKeyword ?? "",
                    record.source.rawValue,
                    record.category.rawValue,
                ]
                .map(Self.normalizedSearch)
                .joined(separator: " ")
                guard searchable.contains(query) else { return false }
            }
            guard !keyword.isEmpty else { return true }
            let searchableKeyword = record.searchKeyword?.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) ?? ""
            return searchableKeyword.contains(keyword)
        }
        .sorted { lhs, rhs in
            switch sort {
            case .largestFirst:
                let left = lhs.sizeBytes ?? -1
                let right = rhs.sizeBytes ?? -1
                if left != right { return left > right }
                if lhs.visitedAt != rhs.visitedAt {
                    return (lhs.visitedAt ?? .distantPast) > (rhs.visitedAt ?? .distantPast)
                }
            case .newestFirst:
                if lhs.visitedAt != rhs.visitedAt {
                    return (lhs.visitedAt ?? .distantPast) > (rhs.visitedAt ?? .distantPast)
                }
            case .browser:
                let order = lhs.browser.displayName.localizedCaseInsensitiveCompare(
                    rhs.browser.displayName
                )
                if order != .orderedSame { return order == .orderedAscending }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func normalizedSearch(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    var selectedRecords: [BrowserPrivacyRecord] {
        records.filter { selectedRecordIDs.contains($0.id) }
    }

    var selectedKnownSizeBytes: Int64 {
        selectedRecords.compactMap(\.sizeBytes).reduce(0, +)
    }

    var selectedUnknownSizeCount: Int {
        selectedRecords.count { $0.sizeBytes == nil }
    }

    var filteredSelectionState: BrowserPrivacySelectionState {
        let selectableIDs = Set(filteredRecords.lazy
            .filter { $0.selectionEligibility.canSelect }
            .map(\.id))
        guard !selectableIDs.isEmpty else { return .unchecked }
        let selectedCount = selectedRecordIDs.intersection(selectableIDs).count
        if selectedCount == 0 { return .unchecked }
        return selectedCount == selectableIDs.count ? .checked : .mixed
    }

    var selectedVerifiedDeletionCandidateCount: Int {
        selectedRecords.count { $0.locator != nil }
    }

    var selectedManualGuidanceCount: Int {
        selectedRecords.count - selectedVerifiedDeletionCandidateCount
    }

    var selectedRecordsContainVerifiedDeletionCandidate: Bool {
        selectedVerifiedDeletionCandidateCount > 0
    }

    var selectedRunningBrowserIDs: Set<String> {
        runningBrowserIDs.intersection(Set(selectedRecords.map { $0.browser.id }))
    }

    var hasCachedResults: Bool {
        !records.isEmpty || !coverage.isEmpty
    }

    var isRefreshingCachedResults: Bool {
        state == .scanning && hasCachedResults
    }

    func startScan() {
        guard !isProcessing else { return }
        let fallbackState = scanOperation?.fallbackState ?? cachedTerminalState
        scanOperation?.task.cancel()
        let generation = UUID()
        let scanner = self.scanner
        let task = Task { [weak self] in
            let result: Result<BrowserPrivacyScanOutcome, BrowserPrivacyScanError>
            do {
                try Task.checkCancellation()
                let outcome = try await scanner.scan()
                try Task.checkCancellation()
                result = .success(outcome)
            } catch is CancellationError {
                result = .failure(.cancelled)
            } catch let scanError as BrowserPrivacyScanError {
                result = .failure(scanError)
            } catch {
                result = .failure(.readFailed)
            }
            self?.finish(result, generation: generation)
        }
        scanOperation = ScanOperation(
            generation: generation,
            task: task,
            fallbackState: fallbackState
        )
        if fallbackState == nil {
            clearSessionValues(keepingFilters: true)
        } else if let baseline = reverificationBaseline {
            // Keep the manual report and its in-memory domain snapshot visible
            // while a new read-only snapshot verifies the same stable visits.
            reverificationStatus = .checking(totalCount: baseline.totalCount)
        } else {
            clearManualGuidanceSession()
        }
        error = nil
        state = .scanning
    }

    func cancel() {
        guard let scanOperation else { return }
        scanOperation.task.cancel()
        self.scanOperation = nil
        error = .cancelled
        if let fallbackState = scanOperation.fallbackState {
            state = fallbackState
            if let baseline = reverificationBaseline {
                reverificationStatus = .coverageIncomplete(
                    totalCount: baseline.totalCount
                )
            }
        } else {
            clearSessionValues(keepingFilters: true)
            state = .cancelled
        }
    }

    func clearSession() {
        guard !isProcessing else { return }
        scanOperation?.task.cancel()
        scanOperation = nil
        clearSessionValues(keepingFilters: false)
        error = nil
        state = .idle
    }

    func setSelected(_ selected: Bool, recordID: UUID) {
        setSelection(selected, recordIDs: [recordID])
    }

    func setSelection(
        _ selected: Bool,
        recordIDs: Set<UUID>,
        confirmingReview: Bool = true
    ) {
        guard !isProcessing, scanOperation == nil else { return }
        let selectableIDs = Set(records.lazy
            .filter {
                recordIDs.contains($0.id)
                    && $0.selectionEligibility.canSelect
                    && (!selected || confirmingReview || $0.risk == .safe)
            }
            .map(\.id))
        if selected {
            selectedRecordIDs.formUnion(selectableIDs)
        } else {
            selectedRecordIDs.subtract(selectableIDs)
        }
        clearManualGuidanceSession()
    }

    func toggleSelection(_ record: BrowserPrivacyRecord) {
        setSelected(!selectedRecordIDs.contains(record.id), recordID: record.id)
    }

    func selectDefaultRecords() {
        guard !isProcessing, scanOperation == nil else { return }
        selectedRecordIDs = Set(records.lazy.filter(\.isDefaultSelected).map(\.id))
        clearManualGuidanceSession()
    }

    func setFilteredSelection(
        _ selected: Bool,
        confirmingReview: Bool = true
    ) {
        setSelection(
            selected,
            recordIDs: Set(filteredRecords.map(\.id)),
            confirmingReview: confirmingReview
        )
    }

    func selectionState(for item: BrowserPrivacyDisplayItem) -> BrowserPrivacySelectionState {
        let ids = Set(item.records.map(\.id))
        let count = selectedRecordIDs.intersection(ids).count
        if count == 0 { return .unchecked }
        return count == ids.count ? .checked : .mixed
    }

    func setSelected(
        _ selected: Bool,
        displayItem: BrowserPrivacyDisplayItem
    ) {
        setSelection(selected, recordIDs: Set(displayItem.records.map(\.id)))
    }

    func clearSelection() {
        guard !isProcessing, scanOperation == nil else { return }
        selectedRecordIDs.removeAll()
        clearManualGuidanceSession()
    }

    /// Produces only a transparent manual-guidance plan.  No browser URL is
    /// opened here and no browser database is changed.
    func prepareManualGuidance() {
        let selected = selectedRecords
        guard !isProcessing, scanOperation == nil, !selected.isEmpty else { return }
        let entries = Dictionary(grouping: selected) {
            "\($0.browser.id):\($0.profileID)"
        }
        .values
        .map { records in
            BrowserPrivacyProcessingEntry(
                browser: records[0].browser,
                profileID: records[0].profileID,
                recordCount: records.count,
                capability: .manualBrowserGuidance,
                outcome: .manual,
                detail: BrowserPrivacySQLiteWriteAdapter.manualGuidanceReason(
                    for: records[0].browser.engine
                )
            )
        }
        .sorted { lhs, rhs in
            if lhs.browser.displayName != rhs.browser.displayName {
                return lhs.browser.displayName < rhs.browser.displayName
            }
            return lhs.profileID < rhs.profileID
        }
        processingReport = BrowserPrivacyProcessingReport(
            selectedRecordCount: selectedRecordIDs.count,
            entries: entries
        )
        manualGuidanceRecords = selected
        reverificationBaseline = BrowserPrivacyReverificationBaseline(records: selected)
        reverificationStatus = nil
    }

    /// Processes an immutable snapshot of the current selection. The visible
    /// store removes only IDs returned by the processor's post-commit,
    /// read-only verification result.
    func processSelectedRecords(excludingBrowserIDs: Set<String> = []) {
        guard !isProcessing, !isRunningBrowserPreflight, scanOperation == nil else { return }
        let selected = selectedRecords.filter {
            !excludingBrowserIDs.contains($0.browser.id)
        }
        guard !selected.isEmpty, let scanSnapshot else { return }
        let selectedIDs = Set(selected.map(\.selectionID))
        guard let plan = try? BrowserPrivacyCleanPlan(
            snapshot: scanSnapshot,
            selectedIDs: selectedIDs
        ) else { return }

        let generation = UUID()
        let processor = self.processor
        let task = Task { [weak self] in
            let report = await processor.process(plan: plan)
            self?.finishProcessing(report, generation: generation)
        }
        processingOperation = ProcessingOperation(generation: generation, task: task)
        processingReport = nil
        manualGuidanceRecords = plan.records.filter { $0.locator == nil }
        reverificationBaseline = manualGuidanceRecords.isEmpty
            ? nil
            : BrowserPrivacyReverificationBaseline(records: manualGuidanceRecords)
        reverificationStatus = nil
        isProcessing = true
    }

    func requestNormalBrowserExitAndProcess() async {
        guard !isProcessing, !isRunningBrowserPreflight, scanOperation == nil else { return }
        let records = selectedRecords.filter { runningBrowserIDs.contains($0.browser.id) }
        let bundleIDs = Set(records.compactMap(\.browser.bundleIdentifier))
        guard !bundleIDs.isEmpty else {
            processSelectedRecords()
            return
        }
        isRunningBrowserPreflight = true
        let remainingBundleIDs = await runningApplicationChecker.requestNormalTermination(
            bundleIdentifiers: bundleIDs,
            timeoutSeconds: 3
        )
        let browserIDsByBundle = Dictionary(
            records.compactMap { record in
                record.browser.bundleIdentifier.map { ($0, record.browser.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let remainingBrowserIDs = Set(remainingBundleIDs.compactMap {
            browserIDsByBundle[$0]
        })
        runningBrowserIDs.subtract(Set(browserIDsByBundle.values))
        runningBrowserIDs.formUnion(remainingBrowserIDs)
        isRunningBrowserPreflight = false
        processSelectedRecords(excludingBrowserIDs: remainingBrowserIDs)
    }

    func waitUntilIdle() async {
        let task = scanOperation?.task
        await task?.value
    }

    func waitUntilProcessingCompletes() async {
        let task = processingOperation?.task
        await task?.value
    }

    func waitUntilRunningStatusRefreshCompletes() async {
        let task = runningStatusTask
        await task?.value
    }

    private func finish(
        _ result: Result<BrowserPrivacyScanOutcome, BrowserPrivacyScanError>,
        generation: UUID
    ) {
        guard scanOperation?.generation == generation else { return }
        let operation = scanOperation
        scanOperation = nil

        switch result {
        case let .success(outcome):
            let previousSelection = Set(selectedRecords.map(\.selectionID))
            records = outcome.records
            coverage = outcome.coverage
            scanSnapshot = BrowserPrivacyScanSnapshot(
                records: outcome.records,
                coverage: outcome.coverage
            )
            reconcileFilters(with: outcome.records)
            selectedRecordIDs = Set(outcome.records.lazy.filter {
                previousSelection.contains($0.selectionID) || $0.isDefaultSelected
            }.map(\.id))
            rebuildFilteredRecords()
            refreshRunningBrowserIDs(for: outcome.records)
            if let baseline = reverificationBaseline {
                reverificationStatus = reverificationStatus(
                    for: outcome,
                    baseline: baseline
                )
            } else {
                processingReport = nil
            }
            error = nil
            state = outcome.state
            resultRevision &+= 1
        case let .failure(scanError):
            error = scanError
            if let baseline = reverificationBaseline {
                reverificationStatus = .coverageIncomplete(
                    totalCount: baseline.totalCount
                )
            }
            if let fallbackState = operation?.fallbackState {
                state = fallbackState
            } else {
                clearSessionValues(keepingFilters: true)
                state = scanError == .cancelled ? .cancelled : .failed
            }
        }
    }

    private var cachedTerminalState: BrowserPrivacyScanState? {
        guard hasCachedResults else { return nil }
        switch state {
        case .completed, .partial, .permissionDenied:
            return state
        case .scanning:
            return scanOperation?.fallbackState
        case .idle, .cancelled, .failed:
            return nil
        }
    }

    private func reconcileFilters(with records: [BrowserPrivacyRecord]) {
        let availableBrowserIDs = Set(records.map(\.browser.id))
        if let browserID = filters.browserID,
           !availableBrowserIDs.contains(browserID) {
            filters.browserID = nil
            filters.profileID = nil
        }

        if let profileID = filters.profileID {
            let profileStillExists = records.contains { record in
                record.profileID == profileID
                    && (filters.browserID == nil || record.browser.id == filters.browserID)
            }
            if !profileStillExists {
                filters.profileID = nil
            }
        }
    }

    private func clearSessionValues(keepingFilters: Bool) {
        records = []
        coverage = []
        scanSnapshot = nil
        selectedRecordIDs.removeAll()
        runningStatusTask?.cancel()
        runningStatusTask = nil
        runningBrowserIDs.removeAll()
        clearManualGuidanceSession()
        if !keepingFilters {
            filters = .empty
            groupsByWebsite = true
        }
        rebuildFilteredRecords()
        resultRevision &+= 1
    }

    private func rebuildFilteredRecords() {
        filteredRecords = Self.filter(
            records: records,
            filters: filters,
            sort: resultSort
        )
        filteredDisplayItems = BrowserPrivacyDisplayItem.aggregate(filteredRecords)
    }

    private func refreshRunningBrowserIDs(for records: [BrowserPrivacyRecord]) {
        runningStatusTask?.cancel()
        let browserIDsByBundleIdentifier = Dictionary(
            records.compactMap { record in
                record.browser.bundleIdentifier.map { ($0, record.browser.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard !browserIDsByBundleIdentifier.isEmpty else {
            runningBrowserIDs.removeAll()
            runningStatusTask = nil
            return
        }
        let checker = runningApplicationChecker
        runningStatusTask = Task { [weak self] in
            let bundleIDs = await checker.runningBundleIdentifiers(
                matching: Set(browserIDsByBundleIdentifier.keys)
            )
            guard !Task.isCancelled else { return }
            self?.runningBrowserIDs = Set(bundleIDs.compactMap {
                browserIDsByBundleIdentifier[$0]
            })
        }
    }

    private func clearManualGuidanceSession() {
        processingReport = nil
        manualGuidanceRecords = []
        reverificationBaseline = nil
        reverificationStatus = nil
    }

    private func reverificationStatus(
        for outcome: BrowserPrivacyScanOutcome,
        baseline: BrowserPrivacyReverificationBaseline
    ) -> BrowserPrivacyReverificationStatus {
        let coverageIsComplete = outcome.state == .completed
            && baseline.profileIdentities.allSatisfy { profile in
                outcome.coverage.contains { coverage in
                    coverage.browser.id == profile.browserID
                        && coverage.availability == .available
                        && !coverage.requiresFullDiskAccess
                        && coverage.fullyScannedProfileIDs.contains(profile.profileID)
                }
            }
        guard coverageIsComplete else {
            return .coverageIncomplete(totalCount: baseline.totalCount)
        }

        let currentCounts = outcome.records.reduce(into: [BrowserPrivacyRecordFingerprint: Int]()) {
            counts, record in
            counts[record.reverificationFingerprint, default: 0] += 1
        }
        let remainingCount = baseline.fingerprintCounts.reduce(0) { count, entry in
            count + min(entry.value, currentCounts[entry.key, default: 0])
        }
        return remainingCount == 0
            ? .noLongerFound(totalCount: baseline.totalCount)
            : .stillPresent(
                remainingCount: remainingCount,
                totalCount: baseline.totalCount
            )
    }

    private func finishProcessing(
        _ report: BrowserPrivacyProcessingReport,
        generation: UUID
    ) {
        guard processingOperation?.generation == generation else { return }
        processingOperation = nil
        isProcessing = false
        processingReport = report

        let verifiedDeletedIDs = report.verifiedDeletedRecordIDs
        guard !verifiedDeletedIDs.isEmpty else { return }
        records.removeAll { verifiedDeletedIDs.contains($0.id) }
        selectedRecordIDs.subtract(verifiedDeletedIDs)
        scanSnapshot = BrowserPrivacyScanSnapshot(
            records: records,
            coverage: coverage
        )
        rebuildFilteredRecords()
        resultRevision &+= 1
    }

    deinit {
        scanOperation?.task.cancel()
        processingOperation?.task.cancel()
        runningStatusTask?.cancel()
    }
}
