import Combine
import Foundation

/// D226: My Clutter's Downloads — the top of the Downloads folder without
/// installers (they are under Applications → Installers), grouped by where
/// each item came from, none checked at first, the D46 review before
/// anything moves to the Trash, and the D207 Ignore List under Downloads.
@MainActor
final class DownloadsStore: ObservableObject {
    typealias Analyze = @Sendable (_ target: StorageMapScanTarget) throws -> StorageMapAnalysisResult
    typealias ReadSources = @Sendable (_ analysis: StorageMapAnalysisResult, _ paths: [String]) -> [String: DownloadSource]

    /// One reading of the folder.
    struct Reading: Sendable {
        let analysis: StorageMapAnalysisResult
        let sources: [String: DownloadSource]
        let modifiedDates: [String: Date]
    }

    @Published var searchText = ""
    @Published var sort: DownloadSort = .size
    @Published private(set) var analysis: StorageMapAnalysisResult?
    @Published private(set) var sources: [String: DownloadSource] = [:]
    @Published private(set) var modifiedDates: [String: Date] = [:]
    @Published private(set) var isReading = false
    @Published private(set) var readError: String?
    @Published private(set) var lastReadAt: Date?
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var trashPlan: DownloadsTrashPlan?
    @Published private(set) var isPreparingReview = false
    @Published private(set) var isMoving = false
    /// What the last review or move said, until it is closed.
    @Published private(set) var notice: String?
    /// What the Ignore List keeps out of Downloads.
    @Published private(set) var ignoreSnapshot: IgnoreListSnapshot
    /// What moved to the Trash from here or from Large & Old Files since the
    /// folder was read.
    @Published private(set) var removedPaths: Set<String> = []

    /// Large & Old Files drops what moved from here (`ToolboxStores`).
    var onMovedToTrash: ((Set<String>) -> Void)?

    let downloadsURL: URL?
    private let homePath: String
    private let trash: DownloadsTrashing
    private let ignoreList: () -> IgnoreListStore?
    private let analyze: Analyze
    private let readSources: ReadSources
    private let now: () -> Date
    private var readTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?

    init(downloadsURL: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
         homePath: String = PathSafety.lexicalHomePath,
         trash: DownloadsTrashing, ignoreList: @escaping () -> IgnoreListStore?,
         analyze: @escaping Analyze = { try DiskScanner(excludedPaths: [], scanMode: .fallback).storageMapAnalysis(target: $0) },
         readSources: @escaping ReadSources = { DownloadsStore.readSources(analysis: $0, paths: $1) },
         now: @escaping () -> Date = Date.init) {
        self.downloadsURL = downloadsURL
        self.homePath = homePath
        self.trash = trash
        self.ignoreList = ignoreList
        self.analyze = analyze
        self.readSources = readSources
        self.now = now
        ignoreSnapshot = ignoreList()?.snapshot() ?? .empty
    }

    /// The system's Downloads folder (`FileManager`), in `homePath`: a store
    /// that reads another home (a test store's own) takes the same folder in
    /// that home. In the app the two homes are the same.
    nonisolated static func downloadsURL(homePath: String) -> URL? {
        guard let system = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let realHome = PathSafety.lexicalHomePath
        let path = PathSafety.lexicalPath(system.path)
        guard homePath != realHome, path.hasPrefix(realHome + "/") else { return system }
        return URL(fileURLWithPath: homePath + String(path.dropFirst(realHome.count)), isDirectory: true)
    }

    // MARK: The list

    /// Whether the folder has been read.
    var hasRead: Bool { analysis != nil }

    var rows: [DownloadRow] {
        guard let analysis else { return [] }
        return DownloadsPresenter.rows(from: analysis, homePath: homePath, ignoring: ignoreSnapshot, removed: removedPaths,
                                       sources: sources, modifiedDates: modifiedDates)
    }

    var groups: [DownloadGroup] { DownloadsPresenter.groups(rows, query: searchText, sort: sort) }
    var totalBytes: Int64 { rows.reduce(0) { $0 + max(0, $1.bytes) } }
    var selectedRows: [DownloadRow] { rows.filter { selectedIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedRows.reduce(0) { $0 + max(0, $1.bytes) } }

    /// Nothing is checked, read or ignored while a review is open or a move
    /// runs.
    var canEdit: Bool { trashPlan == nil && !isPreparingReview && !isMoving }

    // MARK: Reading the folder

    /// Reads the folder when it was never read, or when a clutter scan
    /// finished after the last reading: the results page shows what that
    /// scan saw.
    func refresh(after scannedAt: Date?) {
        guard !isReading else { return }
        if let lastReadAt, scannedAt.map({ lastReadAt >= $0 }) ?? true { return }
        read()
    }

    /// Reads the top of the Downloads folder and where each item came from:
    /// names, sizes and the files' own records, never their contents, and
    /// nothing is written. A new reading checks nothing.
    func read() {
        guard !isReading, canEdit else { return }
        guard let downloadsURL else {
            readError = L10n.text("找不到“下载”文件夹。", "The Downloads folder could not be found.")
            return
        }
        isReading = true
        readError = nil
        let target = StorageMapScanTarget(path: downloadsURL.path, title: IgnoreCategory.downloads.title, kind: .homeDirectory)
        let analyze = analyze, readSources = readSources
        readTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { () throws -> Reading in
                try Self.reading(target, analyze: analyze, readSources: readSources)
            }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled else { return }
            isReading = false
            readTask = nil
            switch result {
            case .success(let reading):
                analysis = reading.analysis
                sources = reading.sources
                modifiedDates = reading.modifiedDates
                removedPaths = []
                selectedIDs = []
                notice = nil
                lastReadAt = now()
                ignoreSnapshot = ignoreList()?.snapshot() ?? ignoreSnapshot
            case .failure(let error):
                readError = Self.readFailure(error)
            }
        }
    }

    /// For tests of the pages that read the shared store: a reading as if
    /// the folder had just been read.
    func replaceReadingForTesting(_ reading: Reading, at date: Date = Date()) {
        guard !isReading, canEdit else { return }
        analysis = reading.analysis
        sources = reading.sources
        modifiedDates = reading.modifiedDates
        removedPaths = []
        selectedIDs = []
        notice = nil
        lastReadAt = date
    }

    nonisolated static func reading(_ target: StorageMapScanTarget, analyze: Analyze, readSources: ReadSources) throws -> Reading {
        let analysis = try analyze(target)
        try Task.checkCancellation()
        let root = analysis.index.rootPath
        let paths = (analysis.index.childrenByDirectory[root] ?? [])
            .filter { !$0.name.hasPrefix(".") }
            .map { (root as NSString).appendingPathComponent($0.name) }
        let sources = readSources(analysis, paths)
        var dates: [String: Date] = [:]
        for path in paths {
            if let date = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                dates[path] = date
            }
        }
        return Reading(analysis: analysis, sources: sources, modifiedDates: dates)
    }

    /// Every top-level item's source, with one Spotlight budget for the
    /// whole reading.
    nonisolated static func readSources(analysis: StorageMapAnalysisResult, paths: [String]) -> [String: DownloadSource] {
        var sources: [String: DownloadSource] = [:]
        var lookups = DownloadSourceReader.siteLookupBudget
        for path in paths {
            if Task.isCancelled { break }
            if analysis.index.indexedEntry(at: path)?.isDirectory == true {
                sources[path] = DownloadSourceReader.source(
                    ofFolderAtPath: path, files: DownloadSourceReader.indexedFiles(under: path, in: analysis.index),
                    siteLookups: &lookups)
            } else {
                sources[path] = DownloadSourceReader.source(ofFileAtPath: path, siteLookups: &lookups)
            }
        }
        return sources
    }

    private static func readFailure(_ error: Error) -> String {
        switch error as? StorageMapAnalysisError {
        case .symbolicLinkPath:
            L10n.text("“下载”文件夹是一个链接，这里不读取链接。", "The Downloads folder is a link, and links are not read here.")
        case .unavailable, .notDirectory:
            L10n.text("找不到“下载”文件夹。", "The Downloads folder could not be found.")
        default:
            L10n.text("没能读取“下载”文件夹，请确认已授予完全磁盘访问权限。",
                      "The Downloads folder could not be read. Check that Full Disk Access is granted.")
        }
    }

    // MARK: Selection

    func setSelected(_ selected: Bool, row: DownloadRow) {
        guard canEdit, rows.contains(where: { $0.id == row.id }) else { return }
        if selected { selectedIDs.insert(row.id) } else { selectedIDs.remove(row.id) }
    }

    /// A group's tick: all of it, or none once all of it is checked.
    func toggle(_ group: DownloadGroup) {
        guard canEdit else { return }
        let ids = Set(group.rows.map(\.id))
        if ids.isSubset(of: selectedIDs) { selectedIDs.subtract(ids) } else { selectedIDs.formUnion(ids) }
    }

    func selectAll(_ shown: [DownloadRow]) {
        guard canEdit else { return }
        selectedIDs.formUnion(shown.map(\.id))
    }

    func clearSelection() {
        guard canEdit else { return }
        selectedIDs = []
    }

    func dismissNotice() { notice = nil }

    // MARK: Opening from the results page

    /// As for Large & Old Files (D221 补): the results page's tile asks for
    /// the manager on this category, and the manager takes the request when
    /// it appears.
    private(set) var isManagerRequested = false

    func requestManager() { isManagerRequested = true }

    /// Any other way into the manager drops a request left behind.
    func withdrawManagerRequest() { isManagerRequested = false }

    func takeManagerRequest() -> Bool {
        defer { isManagerRequested = false }
        return isManagerRequested
    }

    // MARK: Move to Trash (D46 review, D90/D93 wording)

    /// Checks the selected items and opens the review; nothing moves yet.
    func requestTrashReview() {
        let chosen = selectedRows
        guard canEdit, !chosen.isEmpty, let analysis else { return }
        isPreparingReview = true
        notice = nil
        let trash = trash
        reviewTask = Task { [weak self] in
            do {
                let plan = try await trash.prepare(chosen, analysis: analysis)
                guard let self, !Task.isCancelled else { return }
                self.trashPlan = plan
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.notice = L10n.text("没能核对选中的项目，什么都没有移动。", "The selected items could not be checked. Nothing was moved.")
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

    /// Moves the review's ready items; each is checked again just before it
    /// moves. What moved leaves this list and Large & Old Files.
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
                self.removedPaths.formUnion(moved)
                self.selectedIDs.subtract(moved)
                self.trashPlan = nil
                self.notice = DownloadsPresentation.moveNotice(outcome)
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

    /// Large & Old Files moved these files to the Trash. One at the top of
    /// the folder leaves this list; one inside a listed folder leaves that
    /// folder's size out of date, so the folder is read again.
    func forgetMovedPaths(_ paths: Set<String>) {
        guard let analysis, !paths.isEmpty else { return }
        let root = analysis.index.rootPath
        removedPaths.formUnion(paths)
        selectedIDs.subtract(paths)
        let insideAFolder = paths.contains {
            $0.hasPrefix(root + "/") && ($0 as NSString).deletingLastPathComponent != root
        }
        if insideAFolder { read() }
    }

    // MARK: D207 Ignore List

    /// The items go on the list under Downloads by path and leave this list
    /// at once; Put Back brings them back, checked as they were.
    func ignore(_ chosen: [DownloadRow], feedback: IgnoreListFeedback) {
        guard canEdit, !chosen.isEmpty, let snapshot = feedback.add(chosen.map {
            IgnoreListFeedback.Item(target: IgnoreListTarget(path: $0.path), category: .downloads, name: $0.name)
        }) else { return }
        let hidden = Set(rows.filter { snapshot.ignores(path: $0.path, category: .downloads) }.map(\.id))
        let wasSelected = selectedIDs.intersection(hidden)
        ignoreSnapshot = snapshot
        selectedIDs.subtract(hidden)
        let reading = lastReadAt
        feedback.onPutBack { [weak self] snapshot in
            guard let self, self.lastReadAt == reading else { return }
            self.ignoreSnapshot = snapshot
            self.selectedIDs.formUnion(wasSelected.intersection(Set(self.rows.map(\.id))))
        }
    }
}

enum DownloadsPresentation {
    /// D90/D93: what moved, in “move to the Trash” words; nothing here says
    /// space was freed, which happens only when the Trash is emptied.
    static func moveNotice(_ outcome: FileAnalysisTrashOutcome) -> String {
        if outcome.receiptUnavailable { return FileAnalysisTrashPresentation.moveDidNotStart }
        if outcome.receiptIncomplete { return FileAnalysisTrashPresentation.receiptIncompleteNote }
        let moved = outcome.movedPaths.count
        let kept = outcome.skipped.count
        if moved == 0 {
            return L10n.text("没有移动任何项目；\(ByteFormat.count(kept)) 个在移动前的复核中被跳过。",
                             "Nothing was moved; \(L10n.items(kept)) were skipped by the check before moving.")
        }
        if kept == 0 {
            return L10n.text("已把 \(ByteFormat.count(moved)) 个项目（\(ByteFormat.storageString(outcome.movedBytes))）移到废纸篓，可在“操作记录”中恢复。",
                             "Moved \(L10n.items(moved)) (\(ByteFormat.storageString(outcome.movedBytes))) to the Trash. Restore them from Operation History.")
        }
        return L10n.text("已把 \(ByteFormat.count(moved)) 个项目移到废纸篓，\(ByteFormat.count(kept)) 个没有移动；可在“操作记录”中恢复。",
                         "Moved \(L10n.items(moved)) to the Trash; \(L10n.items(kept)) stayed. Restore them from Operation History.")
    }

    /// The row's second line: what it is, when it last changed, where.
    static func detail(_ row: DownloadRow) -> String {
        var parts: [String] = []
        if row.isDirectory, let count = row.itemCount {
            parts.append(L10n.text("文件夹 · \(ByteFormat.count(count)) 项", "Folder · \(L10n.items(count))"))
        }
        if let date = row.modifiedAt {
            let day = date.formatted(.dateTime.year().month().day().locale(L10n.locale))
            parts.append(L10n.text("修改于 \(day)", "Modified \(day)"))
        }
        parts.append((row.path as NSString).abbreviatingWithTildeInPath)
        return parts.joined(separator: " · ")
    }
}
