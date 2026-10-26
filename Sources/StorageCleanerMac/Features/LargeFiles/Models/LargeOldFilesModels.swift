import CoreServices
import Darwin
import Foundation

/// D221: the clutter manager's Large & Old Files, built on the large-file
/// list (`LargeFilesStore`). CleanMyMac narrows them by kind, size and when
/// a file was last opened (its `laof_filter_*` groups): the checked choices
/// of one group add up, the groups narrow each other, and with nothing
/// checked every file shows.
enum LargeOldFileType: String, CaseIterable, Identifiable, Sendable {
    case documents
    case pictures
    case videos
    case archives
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents: L10n.text("文稿", "Documents")
        case .pictures: L10n.text("图片", "Pictures")
        case .videos: L10n.text("视频", "Videos")
        case .archives: L10n.text("压缩包", "Archives")
        case .other: L10n.text("其他", "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .documents: LargeFileKind.document.systemImage
        case .pictures: LargeFileKind.image.systemImage
        case .videos: LargeFileKind.video.systemImage
        case .archives: LargeFileKind.archive.systemImage
        case .other: LargeFileKind.other.systemImage
        }
    }

    /// The large-file list's own kinds; audio, mail attachments and
    /// developer files count as Other (D226: installers are not listed).
    static func of(_ item: StorageItem) -> LargeOldFileType {
        switch LargeFileKind.classify(item) {
        case .document: .documents
        case .image: .pictures
        case .video: .videos
        case .archive: .archives
        default: .other
        }
    }
}

/// D221: size bands, in decimal units as everywhere since D178. CleanMyMac
/// describes small files as a few MB, the middle band as hundreds of MB to
/// over a GB and the largest as gigabytes; the borders here are 100 MB and
/// 1 GB.
enum LargeOldFileSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    static let mediumFloor: Int64 = 100_000_000
    static let largeFloor: Int64 = 1_000_000_000

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: L10n.text("小", "Small")
        case .medium: L10n.text("中", "Medium")
        case .large: L10n.text("大", "Large")
        }
    }

    var range: String {
        switch self {
        case .small: L10n.text("100 MB 以下", "Under 100 MB")
        case .medium: L10n.text("100 MB–1 GB", "100 MB–1 GB")
        case .large: L10n.text("1 GB 及以上", "1 GB and over")
        }
    }

    static func of(bytes: Int64) -> LargeOldFileSize {
        if bytes >= largeFloor { return .large }
        return bytes >= mediumFloor ? .medium : .small
    }
}

/// D221: how long ago a file was last opened. As in CleanMyMac, every band
/// after the first takes in all older files: a file last opened two years
/// ago is more than a week, a month, half a year and a year old.
enum LargeOldFileAge: String, CaseIterable, Identifiable, Sendable {
    case withinWeek
    case overWeek
    case overMonth
    case overHalfYear
    case overYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .withinWeek: L10n.text("一周内", "Within a Week")
        case .overWeek: L10n.text("一周前", "Over a Week Ago")
        case .overMonth: L10n.text("一个月前", "Over a Month Ago")
        case .overHalfYear: L10n.text("半年前", "Over Six Months Ago")
        case .overYear: L10n.text("一年前", "Over a Year Ago")
        }
    }

    /// Where the band starts (`withinWeek` ends there).
    var days: Int {
        switch self {
        case .withinWeek, .overWeek: 7
        case .overMonth: 30
        case .overHalfYear: 182
        case .overYear: 365
        }
    }

    func includes(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        let border = TimeInterval(days) * 24 * 60 * 60
        return self == .withinWeek ? age < border : age >= border
    }
}

enum LargeOldFileSort: String, CaseIterable, Identifiable, Sendable {
    case size
    case name
    case lastOpened

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size: L10n.text("按大小", "Size")
        case .name: L10n.text("按名称", "Name")
        case .lastOpened: L10n.text("按上次打开", "Last Opened")
        }
    }
}

/// One file of Large & Old Files.
struct LargeOldFileRow: Identifiable, Equatable, Sendable {
    let item: StorageItem
    let type: LargeOldFileType
    let size: LargeOldFileSize
    /// When Spotlight says the file was last opened; its modification date
    /// when Spotlight has none (`dateIsLastOpened` false, and the row says
    /// so).
    let date: Date?
    let dateIsLastOpened: Bool

    var id: String { item.id }
    var path: String { item.path }
    var bytes: Int64 { item.sizeBytes }
}

struct LargeOldFileFilters: Equatable, Sendable {
    var types: Set<LargeOldFileType> = []
    var sizes: Set<LargeOldFileSize> = []
    var ages: Set<LargeOldFileAge> = []

    var isEmpty: Bool { types.isEmpty && sizes.isEmpty && ages.isEmpty }

    func includes(_ row: LargeOldFileRow, now: Date) -> Bool {
        guard types.isEmpty || types.contains(row.type),
              sizes.isEmpty || sizes.contains(row.size) else { return false }
        guard !ages.isEmpty else { return true }
        guard let date = row.date else { return false }
        return ages.contains { $0.includes(date, now: now) }
    }
}

enum LargeOldFilesPresenter {
    /// The listed files (folders stay with the large-file list), less
    /// installers (D226: Applications → Installers lists them), what the
    /// Ignore List keeps out of Large & Old Files and what moved from here
    /// since the list was made.
    static func rows(from items: [StorageItem], lastOpened: [String: Date],
                     ignoring snapshot: IgnoreListSnapshot, moved: Set<String>) -> [LargeOldFileRow] {
        items.compactMap { item in
            guard !item.isDirectory, !InstallerFileTypes.isInstaller(path: item.path), !moved.contains(item.path),
                  !snapshot.ignores(path: item.path, category: .largeAndOld) else { return nil }
            let opened = lastOpened[item.path]
            return LargeOldFileRow(item: item, type: .of(item), size: .of(bytes: item.sizeBytes),
                                   date: opened ?? item.modifiedAt, dateIsLastOpened: opened != nil)
        }
    }

    static func visible(_ rows: [LargeOldFileRow], filters: LargeOldFileFilters, query: String,
                        sort: LargeOldFileSort, now: Date) -> [LargeOldFileRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = rows.filter { row in
            filters.includes(row, now: now)
                && (query.isEmpty || row.item.title.localizedCaseInsensitiveContains(query)
                    || row.path.localizedCaseInsensitiveContains(query))
        }
        return shown.sorted { lhs, rhs in
            switch sort {
            case .size:
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            case .name:
                break
            case .lastOpened:
                // Oldest first; a file with no date at the end.
                switch (lhs.date, rhs.date) {
                case let (left?, right?) where left != right: return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            }
            let order = lhs.item.title.localizedStandardCompare(rhs.item.title)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
    }
}

enum LargeOldFileDates {
    /// Spotlight's `kMDItemLastUsedDate` for every path that has one (a file
    /// never opened, or not indexed, has none).
    static func lastOpened(paths: [String]) -> [String: Date] {
        var dates: [String: Date] = [:]
        for path in paths {
            if Task.isCancelled { break }
            guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
            dates[path] = date
        }
        return dates
    }
}

struct LargeOldFilesTrashPlan: Sendable {
    let review: FileAnalysisTrashReview
    let index: StorageMapAnalysisIndex
    let policy: FileAnalysisTrashPolicy
}

/// The test seam: the list moves a file only through these two steps.
protocol LargeOldFilesTrashing: Sendable {
    func prepare(_ rows: [LargeOldFileRow]) async throws -> LargeOldFilesTrashPlan
    func execute(_ plan: LargeOldFilesTrashPlan) async throws -> FileAnalysisTrashOutcome
}

/// D221 (D90/D93): the D46 review and executor, as Malware Removal uses
/// them. Each file is measured when the review opens; one that is gone, no
/// longer a plain file, or modified since the large-file scan is held back;
/// every D46/D54 protection applies; and each move is checked again right
/// before it happens, under the cleanup lease, with a receipt.
struct LargeOldFilesTrashService: LargeOldFilesTrashing {
    let environment: FileAnalysisTrashEnvironment
    let coordinator: HeavyWorkCoordinator

    func prepare(_ rows: [LargeOldFileRow]) async throws -> LargeOldFilesTrashPlan {
        let running = await environment.runningApplicationState()
        let environment = environment
        let worker = Task.detached(priority: .utility) { () throws -> LargeOldFilesTrashPlan in
            var entries: [String: [StorageMapIndexedEntry]] = [:]
            var selections: [FileAnalysisTrashSelection] = []
            var heldBack: [String: FileAnalysisTrashBlock] = [:]
            for row in rows {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: row.path)
                var status = stat()
                let found = lstat(row.path, &status) == 0
                let isFile = found && status.st_mode & S_IFMT == S_IFREG
                if !found {
                    heldBack[row.path] = .missing
                } else if !isFile {
                    heldBack[row.path] = .unreadable
                } else if Self.isModified(row.item, since: status) {
                    heldBack[row.path] = .changedSinceAnalysis
                }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                let size = DiskScanner.storageMapPreferredSize(logicalSize: values?.fileSize,
                    allocatedSize: values?.totalFileAllocatedSize ?? values?.fileAllocatedSize, path: row.path)
                let entry = StorageMapIndexedEntry(name: url.lastPathComponent, kind: isFile ? "file" : "unavailable",
                    sizeBytes: size.map(Int64.init), isDirectory: false, canDescend: false, isEstimated: !isFile || size == nil,
                    changeStamp: isFile ? DiskScanner.storageMapChangeStamp(status) : 0)
                entries[url.deletingLastPathComponent().path, default: []].append(entry)
                selections.append(FileAnalysisTrashSelection(path: row.path, title: row.item.title, isDirectory: false,
                                                              kind: entry.kind, bytes: entry.sizeBytes ?? row.bytes, itemCount: nil))
            }
            let index = StorageMapAnalysisIndex(rootPath: "/", rootVolumeIdentifier: nil, directories: [:],
                childrenByDirectory: entries, blockedDirectoryPaths: [], duplicateFilePaths: [])
            var policy = FileAnalysisTrashPolicy(rootPath: "/", targetKind: .internalVolume, homePath: environment.homePath,
                appDataPath: environment.appDataPath, excludedPaths: environment.excludedPaths(),
                runningApplicationPaths: running.paths, mountPointPaths: environment.mountPointPaths(),
                protectedLinkTargets: environment.protectedLinkTargets(environment.homePath, environment.appDataPath))
            policy.unknownRunningApplicationNames = running.unknownApplicationNames
            policy = FileAnalysisTrashService.refined(policy, environment: environment)
            let review = FileAnalysisTrashService.review(selections, index: index, policy: policy,
                                                         environment: environment, externalVolumeName: nil)
            let checked = FileAnalysisTrashReview(items: review.items.map { item in
                guard let block = heldBack[item.id] else { return item }
                return FileAnalysisTrashReviewItem(selection: item.selection, status: .blocked(block), externalVolumeName: nil)
            }, unknownRunningApplicationNames: review.unknownRunningApplicationNames)
            return LargeOldFilesTrashPlan(review: checked, index: index, policy: policy)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func execute(_ plan: LargeOldFilesTrashPlan) async throws -> FileAnalysisTrashOutcome {
        try await coordinator.withLease(owner: .cleanup) { lease in
            try await coordinator.requireValid(lease, owner: .cleanup)
            return await FileAnalysisTrashService.execute(plan.review.items, index: plan.index, policy: plan.policy,
                environment: environment, beforeEachMove: { try await coordinator.requireValid(lease, owner: .cleanup) })
        }
    }

    /// The large-file scan recorded the modification date; a different one
    /// now means the file is not the one that was listed.
    static func isModified(_ item: StorageItem, since status: stat) -> Bool {
        guard let listed = item.modifiedAt else { return false }
        let now = TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return abs(now - listed.timeIntervalSince1970) > 1
    }
}
