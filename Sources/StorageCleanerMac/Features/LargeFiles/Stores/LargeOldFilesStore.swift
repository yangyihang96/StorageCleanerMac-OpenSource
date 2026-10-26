import Combine
import Foundation

/// D221: the clutter manager's Large & Old Files — the files of the
/// large-file list with when each was last opened, the three filters, the
/// files the person checked (none at first), the review before anything
/// moves to the Trash, and the D207 Ignore List.
@MainActor
final class LargeOldFilesStore: ObservableObject {
    @Published var filters = LargeOldFileFilters()
    @Published var searchText = ""
    @Published var sort: LargeOldFileSort = .size
    @Published private(set) var selectedIDs: Set<String> = []
    /// Spotlight's last-opened dates of the listed files, read once per list.
    @Published private(set) var lastOpened: [String: Date] = [:]
    @Published private(set) var isReadingDates = false
    @Published private(set) var trashPlan: LargeOldFilesTrashPlan?
    @Published private(set) var isPreparingReview = false
    @Published private(set) var isMoving = false
    /// What the last review or move said, until it is closed.
    @Published private(set) var notice: String?
    /// What the Ignore List keeps out of Large & Old Files.
    @Published private(set) var ignoreSnapshot: IgnoreListSnapshot
    /// D226: My Clutter's Downloads drops what moved from here (`ToolboxStores`).
    var onMovedToTrash: ((Set<String>) -> Void)?

    let largeFiles: LargeFilesStore
    private let trash: LargeOldFilesTrashing
    private let ignoreList: () -> IgnoreListStore?
    private let readLastOpened: @Sendable ([String]) -> [String: Date]
    private let now: () -> Date
    private var listedAt: Date?
    private var datesTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(largeFiles: LargeFilesStore, trash: LargeOldFilesTrashing,
         ignoreList: @escaping () -> IgnoreListStore?,
         readLastOpened: @escaping @Sendable ([String]) -> [String: Date] = { LargeOldFileDates.lastOpened(paths: $0) },
         now: @escaping () -> Date = Date.init) {
        self.largeFiles = largeFiles
        self.trash = trash
        self.ignoreList = ignoreList
        self.readLastOpened = readLastOpened
        self.now = now
        ignoreSnapshot = ignoreList()?.snapshot() ?? .empty
        // `@Published` sends before it stores: the date that arrives is the
        // new list's, and the items were stored just before it.
        largeFiles.$lastScanAt
            .sink { [weak self] scannedAt in self?.listChanged(scannedAt: scannedAt) }
            .store(in: &cancellables)
    }

    // MARK: The list

    /// Whether the large-file scan has made a list yet.
    var hasList: Bool { largeFiles.lastScanAt != nil }

    var rows: [LargeOldFileRow] {
        LargeOldFilesPresenter.rows(from: largeFiles.items, lastOpened: lastOpened, ignoring: ignoreSnapshot, moved: [])
    }

    var visibleRows: [LargeOldFileRow] {
        LargeOldFilesPresenter.visible(rows, filters: filters, query: searchText, sort: sort, now: now())
    }

    var selectedRows: [LargeOldFileRow] { rows.filter { selectedIDs.contains($0.id) } }

    var selectedBytes: Int64 { selectedRows.reduce(0) { $0 + max(0, $1.bytes) } }

    var totalBytes: Int64 { rows.reduce(0) { $0 + max(0, $1.bytes) } }

    /// Nothing is checked, filtered or ignored while a review is open or a
    /// move runs.
    var canEdit: Bool { trashPlan == nil && !isPreparingReview && !isMoving }

    func count(_ type: LargeOldFileType) -> Int { rows.filter { $0.type == type }.count }
    func count(_ size: LargeOldFileSize) -> Int { rows.filter { $0.size == size }.count }
    func count(_ age: LargeOldFileAge) -> Int {
        let date = now()
        return rows.filter { row in row.date.map { age.includes($0, now: date) } == true }.count
    }

    /// A new large-file list: nothing checked, and the last-opened dates
    /// read again.
    private func listChanged(scannedAt: Date?) {
        guard scannedAt != listedAt else { return }
        listedAt = scannedAt
        selectedIDs = []
        notice = nil
        ignoreSnapshot = ignoreList()?.snapshot() ?? ignoreSnapshot
        datesTask?.cancel()
        let paths = largeFiles.items.filter { !$0.isDirectory }.map(\.path)
        guard !paths.isEmpty else {
            lastOpened = [:]
            isReadingDates = false
            return
        }
        isReadingDates = true
        let read = readLastOpened
        datesTask = Task { [weak self] in
            let dates = await Task.detached(priority: .utility) { read(paths) }.value
            guard let self, !Task.isCancelled, self.listedAt == scannedAt else { return }
            self.lastOpened = dates
            self.isReadingDates = false
            self.datesTask = nil
        }
    }

    // MARK: Filters and selection

    func toggle(_ type: LargeOldFileType) { filters.types.formSymmetricDifference([type]) }
    func toggle(_ size: LargeOldFileSize) { filters.sizes.formSymmetricDifference([size]) }
    func toggle(_ age: LargeOldFileAge) { filters.ages.formSymmetricDifference([age]) }

    func clearFilters() { filters = LargeOldFileFilters() }

    func setSelected(_ selected: Bool, row: LargeOldFileRow) {
        guard canEdit, rows.contains(where: { $0.id == row.id }) else { return }
        if selected { selectedIDs.insert(row.id) } else { selectedIDs.remove(row.id) }
    }

    func selectAll(_ shown: [LargeOldFileRow]) {
        guard canEdit else { return }
        selectedIDs.formUnion(shown.map(\.id))
    }

    func clearSelection() {
        guard canEdit else { return }
        selectedIDs = []
    }

    func dismissNotice() { notice = nil }

    // MARK: Opening from the results page (D221 补)

    /// The results page's tile asked for the manager on this category; the
    /// manager takes the request when it appears. The page that owns which
    /// category the manager shows learns it that way, without a new callback.
    private(set) var isManagerRequested = false

    func requestManager() { isManagerRequested = true }

    /// Any other way into the manager drops a request left behind.
    func withdrawManagerRequest() { isManagerRequested = false }

    func takeManagerRequest() -> Bool {
        defer { isManagerRequested = false }
        return isManagerRequested
    }

    // MARK: Move to Trash (D46 review, D90/D93 wording)

    /// Checks the selected files and opens the review; nothing moves yet.
    func requestTrashReview() {
        let chosen = selectedRows
        guard canEdit, !chosen.isEmpty else { return }
        isPreparingReview = true
        notice = nil
        let trash = trash
        reviewTask = Task { [weak self] in
            do {
                let plan = try await trash.prepare(chosen)
                guard let self, !Task.isCancelled else { return }
                self.trashPlan = plan
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.notice = L10n.text("没能核对选中的文件，什么都没有移动。", "The selected files could not be checked. Nothing was moved.")
            }
            self?.isPreparingReview = false
            self?.reviewTask = nil
        }
    }

    func cancelReview() {
        guard !isMoving else { return }
        reviewTask?.cancel()
        reviewTask = nil
        isPreparingReview = false
        trashPlan = nil
    }

    /// Moves the review's ready files; each is checked again just before it
    /// moves. What moved leaves this list and the large-file list.
    func confirmTrash() {
        guard let plan = trashPlan, !plan.review.readyItems.isEmpty, !isMoving else { return }
        isMoving = true
        notice = nil
        let trash = trash
        reviewTask = Task { [weak self] in
            do {
                let outcome = try await trash.execute(plan)
                guard let self else { return }
                let moved = Set(outcome.movedPaths)
                self.largeFiles.forgetMovedFiles(moved)
                self.selectedIDs = Set(self.rows.filter { self.selectedIDs.contains($0.id) }.map(\.id))
                self.trashPlan = nil
                self.notice = LargeOldFilesPresentation.moveNotice(outcome)
                if !moved.isEmpty { self.onMovedToTrash?(moved) }
            } catch {
                guard let self else { return }
                if case HeavyWorkCoordinator.Error.busy(let owner) = error {
                    self.notice = HeavyWorkActivityStore.conflictMessage(activeOwner: owner)
                } else {
                    self.notice = FileAnalysisTrashPresentation.moveDidNotStart
                }
            }
            self?.isMoving = false
            self?.reviewTask = nil
        }
    }

    /// D226: My Clutter's Downloads moved these to the Trash, a folder with
    /// the files inside it; they leave this list and the large-file list.
    func forgetMovedPaths(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let gone = largeFiles.items.map(\.path).filter { path in
            paths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        largeFiles.forgetMovedFiles(Set(gone))
        selectedIDs = Set(rows.filter { selectedIDs.contains($0.id) }.map(\.id))
    }

    // MARK: D207 Ignore List

    /// CleanMyMac's Add to Ignore List: the files go on the list as Large &
    /// Old Files and leave this list at once; Put Back brings them back,
    /// checked as they were.
    func ignore(_ chosen: [LargeOldFileRow], feedback: IgnoreListFeedback) {
        guard canEdit, !chosen.isEmpty, let snapshot = feedback.add(chosen.map {
            IgnoreListFeedback.Item(target: IgnoreListTarget(path: $0.path), category: .largeAndOld, name: $0.item.title)
        }) else { return }
        let hidden = Set(rows.filter { snapshot.ignores(path: $0.path, category: .largeAndOld) }.map(\.id))
        let wasSelected = selectedIDs.intersection(hidden)
        ignoreSnapshot = snapshot
        selectedIDs.subtract(hidden)
        let list = listedAt
        feedback.onPutBack { [weak self] snapshot in
            guard let self, self.listedAt == list else { return }
            self.ignoreSnapshot = snapshot
            let back = Set(self.rows.map(\.id))
            self.selectedIDs.formUnion(wasSelected.intersection(back))
        }
    }
}

enum LargeOldFilesPresentation {
    /// D90/D93: what moved, in “move to the Trash” words; nothing here says
    /// space was freed, which happens only when the Trash is emptied.
    static func moveNotice(_ outcome: FileAnalysisTrashOutcome) -> String {
        if outcome.receiptUnavailable { return FileAnalysisTrashPresentation.moveDidNotStart }
        if outcome.receiptIncomplete { return FileAnalysisTrashPresentation.receiptIncompleteNote }
        let moved = outcome.movedPaths.count
        let kept = outcome.skipped.count
        if moved == 0 {
            return L10n.text("没有移动任何文件；\(ByteFormat.count(kept)) 个在移动前的复核中被跳过。",
                             "Nothing was moved; \(L10n.items(kept)) were skipped by the check before moving.")
        }
        if kept == 0 {
            return L10n.text("已把 \(ByteFormat.count(moved)) 个文件（\(ByteFormat.storageString(outcome.movedBytes))）移到废纸篓，可在“操作记录”中恢复。",
                             "Moved \(L10n.items(moved)) (\(ByteFormat.storageString(outcome.movedBytes))) to the Trash. Restore them from Operation History.")
        }
        return L10n.text("已把 \(ByteFormat.count(moved)) 个文件移到废纸篓，\(ByteFormat.count(kept)) 个没有移动；可在“操作记录”中恢复。",
                         "Moved \(L10n.items(moved)) to the Trash; \(L10n.items(kept)) stayed. Restore them from Operation History.")
    }

    /// The row's date, saying which one it is.
    static func dateText(_ row: LargeOldFileRow) -> String {
        guard let date = row.date else { return L10n.text("没有打开或修改时间", "No opened or modified date") }
        let day = date.formatted(.dateTime.year().month().day().locale(L10n.locale))
        return row.dateIsLastOpened
            ? L10n.text("上次打开 \(day)", "Last opened \(day)")
            : L10n.text("无打开记录 · 修改于 \(day)", "Never opened · Modified \(day)")
    }
}
