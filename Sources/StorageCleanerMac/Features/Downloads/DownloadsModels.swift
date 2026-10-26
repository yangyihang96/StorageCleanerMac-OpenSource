import CoreServices
import Darwin
import Foundation

/// D226: where a download came from. The app named in the file's quarantine
/// record comes first; without one, the site in Spotlight's “where from”
/// record; with neither, other sources. (CleanMyMac reads each browser's own
/// download history instead; this reads what macOS records on the file.)
enum DownloadSource: Hashable, Sendable {
    case application(String)
    case site(String)
    case other

    var id: String {
        switch self {
        case .application(let name): "app:" + name.lowercased()
        case .site(let host): "site:" + host.lowercased()
        case .other: "other"
        }
    }

    var title: String {
        switch self {
        case .application(let name), .site(let name):
            // D228: a space before a Latin name or a number (来自 Chrome), none
            // before a Chinese one (来自隔空投送).
            L10n.text(Self.startsWide(name) ? "来自\(name)" : "来自 \(name)", "From \(name)")
        case .other:
            L10n.text("其他来源", "Other Sources")
        }
    }

    /// Whether `name` starts with a Chinese, Japanese or Korean character or
    /// full-width punctuation.
    static func startsWide(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(first) || (0xAC00...0xD7AF).contains(first) || (0xF900...0xFAFF).contains(first)
            || (0xFE30...0xFE4F).contains(first) || (0xFF00...0xFFEF).contains(first) || (0x20000...0x3134F).contains(first)
    }

    var systemImage: String {
        switch self {
        case .application: "app.badge"
        case .site: "globe"
        case .other: "tray"
        }
    }

    /// Names some agents record (a process or an internal name), shown as
    /// people know the app; any other name as recorded.
    static func applicationName(forAgent agent: String) -> String {
        switch agent {
        case "sharingd": L10n.text("隔空投送", "AirDrop")
        case "com.apple.shortcuts": L10n.text("快捷指令", "Shortcuts")
        case "com.apple.Safari": "Safari"
        case "Mail", "com.apple.mail": L10n.text("邮件", "Mail")
        case "Preview", "com.apple.Preview": L10n.text("预览", "Preview")
        case "wpsoffice": "WPS Office"
        default: agent
        }
    }
}

/// One item at the top of the Downloads folder.
struct DownloadRow: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let kind: String
    let bytes: Int64
    /// For a folder, the items inside it.
    let itemCount: Int?
    let modifiedAt: Date?
    var source: DownloadSource

    var id: String { path }
}

/// How the items of each source are ordered; the sources stay largest first.
enum DownloadSort: String, CaseIterable, Identifiable, Sendable {
    case size
    case name
    case modified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size: L10n.text("按大小", "Size")
        case .name: L10n.text("按名称", "Name")
        case .modified: L10n.text("按修改时间", "Date Modified")
        }
    }
}

struct DownloadGroup: Identifiable, Equatable, Sendable {
    let source: DownloadSource
    let rows: [DownloadRow]

    var id: String { source.id }
    var bytes: Int64 { rows.reduce(0) { $0 + max(0, $1.bytes) } }
}

enum DownloadsPresenter {
    /// The top of the Downloads folder as the analysis saw it, less hidden
    /// items, installers (Applications → Installers), apps (Other Locations),
    /// links, cloud placeholders, protected locations and what the Ignore
    /// List keeps out of Downloads.
    static func rows(from analysis: StorageMapAnalysisResult, homePath: String, ignoring snapshot: IgnoreListSnapshot,
                     removed: Set<String>, sources: [String: DownloadSource] = [:],
                     modifiedDates: [String: Date] = [:]) -> [DownloadRow] {
        let root = analysis.index.rootPath
        return (analysis.index.childrenByDirectory[root] ?? []).compactMap { entry in
            let path = (root as NSString).appendingPathComponent(entry.name)
            let pathExtension = (entry.name as NSString).pathExtension.lowercased()
            guard !entry.name.hasPrefix("."), entry.kind != "alias", entry.kind != "unavailable",
                  pathExtension != "app", !InstallerFileTypes.isInstaller(path: path), !entry.isCloudOnly,
                  !removed.contains(path), !ProtectedLocations.protects(path: path, homePath: homePath),
                  !snapshot.ignores(path: path, category: .downloads) else { return nil }
            // Sized as Space Lens sizes them: a folder by everything in it, a
            // hard link counted once (`duplicateFilePaths`).
            let folder = entry.isDirectory ? analysis.index.directories[path] : nil
            let bytes = entry.isDirectory ? folder?.sizeBytes ?? 0
                : analysis.index.duplicateFilePaths.contains(path) ? 0 : entry.sizeBytes ?? 0
            return DownloadRow(path: path, name: entry.name, isDirectory: entry.isDirectory, kind: entry.kind,
                               bytes: max(0, bytes), itemCount: folder?.descendantItemCount,
                               modifiedAt: modifiedDates[path], source: sources[path] ?? .other)
        }
    }

    /// One group per source, the largest first and other sources last; in a
    /// group the order `sort` picks (the largest, the name, or the oldest
    /// change first).
    static func groups(_ rows: [DownloadRow], query: String = "", sort: DownloadSort = .size) -> [DownloadGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = query.isEmpty ? rows : rows.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
                || $0.source.title.localizedCaseInsensitiveContains(query)
        }
        // By id: two spellings of one app's name make one group.
        return Dictionary(grouping: shown, by: \.source.id).values.map { rows in
            DownloadGroup(source: rows[0].source, rows: rows.sorted { ordered($0, $1, by: sort) })
        }.sorted { lhs, rhs in
            if (lhs.source == .other) != (rhs.source == .other) { return rhs.source == .other }
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.source.title.localizedStandardCompare(rhs.source.title) == .orderedAscending
        }
    }

    private static func ordered(_ lhs: DownloadRow, _ rhs: DownloadRow, by sort: DownloadSort) -> Bool {
        switch sort {
        case .size:
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        case .name:
            break
        case .modified:
            // The oldest first; an item with no date at the end.
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case let (left?, right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
        }
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
    }
}

/// D226: reads where downloads came from — the file's own records only,
/// never its contents, and nothing is written.
enum DownloadSourceReader {
    /// The app named in `com.apple.quarantine` (“flags;time;agent;id”).
    static func quarantineAgent(atPath path: String) -> String? {
        let length = getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0, length < 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = buffer.withUnsafeMutableBytes { getxattr(path, "com.apple.quarantine", $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        guard read > 0, let value = String(bytes: buffer.prefix(read), encoding: .utf8) else { return nil }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count > 2 else { return nil }
        let agent = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return agent.isEmpty ? nil : agent
    }

    /// The site in Spotlight's `kMDItemWhereFroms`, without “www.”.
    static func originHost(atPath path: String) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let origins = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] else { return nil }
        for origin in origins {
            guard let host = URL(string: origin)?.host?.lowercased(), !host.isEmpty else { continue }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return nil
    }

    /// How many Spotlight lookups one reading of the folder may make: an
    /// attribute read is quick, Spotlight is not, and a folder of thousands
    /// of items should still list in a moment.
    static let siteLookupBudget = 500

    /// The app in the quarantine record, else the site Spotlight recorded
    /// while `siteLookups` (what is left of the reading's budget) lasts.
    static func source(ofFileAtPath path: String, siteLookups: inout Int) -> DownloadSource {
        if let agent = quarantineAgent(atPath: path) { return .application(DownloadSource.applicationName(forAgent: agent)) }
        guard siteLookups > 0 else { return .other }
        siteLookups -= 1
        if let host = originHost(atPath: path) { return .site(host) }
        return .other
    }

    /// A folder rarely carries a record itself (an archive's contents do):
    /// its own quarantine record, else the source most of the files inside
    /// share, reading at most `limit` of them and asking Spotlight about at
    /// most `perFolderLookups`.
    static func source(ofFolderAtPath path: String, files: [String], limit: Int = 200, perFolderLookups: Int = 50,
                       siteLookups: inout Int) -> DownloadSource {
        if let agent = quarantineAgent(atPath: path) { return .application(DownloadSource.applicationName(forAgent: agent)) }
        var counts: [DownloadSource: Int] = [:]
        var order: [DownloadSource] = []
        var asked = 0
        for file in files.prefix(limit) {
            let found: DownloadSource
            if let agent = quarantineAgent(atPath: file) {
                found = .application(DownloadSource.applicationName(forAgent: agent))
            } else if asked < perFolderLookups, siteLookups > 0 {
                asked += 1
                siteLookups -= 1
                guard let host = originHost(atPath: file) else { continue }
                found = .site(host)
            } else {
                continue
            }
            if counts[found] == nil { order.append(found) }
            counts[found, default: 0] += 1
        }
        // The most files win; on a tie the source met first (`max` keeps the first).
        return order.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? .other
    }

    /// Files under `folder` as the analysis indexed them, nearest first.
    static func indexedFiles(under folder: String, in index: StorageMapAnalysisIndex, limit: Int = 200) -> [String] {
        var files: [String] = []
        var queue = [folder]
        while !queue.isEmpty, files.count < limit {
            let directory = queue.removeFirst()
            for entry in index.childrenByDirectory[directory] ?? [] where !entry.name.hasPrefix(".") {
                let path = (directory as NSString).appendingPathComponent(entry.name)
                if entry.isDirectory {
                    if entry.canDescend { queue.append(path) }
                } else if entry.kind != "alias" {
                    files.append(path)
                    if files.count >= limit { break }
                }
            }
        }
        return files
    }
}

struct DownloadsTrashPlan: Sendable {
    let review: FileAnalysisTrashReview
    let index: StorageMapAnalysisIndex
    let policy: FileAnalysisTrashPolicy
}

/// The test seam: the list moves an item only through these two steps.
protocol DownloadsTrashing: Sendable {
    func prepare(_ rows: [DownloadRow], analysis: StorageMapAnalysisResult) async throws -> DownloadsTrashPlan
    func execute(_ plan: DownloadsTrashPlan) async throws -> FileAnalysisTrashOutcome
}

/// D226 (D46, D93): the File Analysis review and executor on the analysis of
/// the Downloads folder, as Space Lens uses them: every D46/D54 protection,
/// a folder compared with the analysis all the way down, each item checked
/// again right before it moves, under the cleanup lease, with a receipt.
struct DownloadsTrashService: DownloadsTrashing {
    let environment: FileAnalysisTrashEnvironment
    let coordinator: HeavyWorkCoordinator

    func prepare(_ rows: [DownloadRow], analysis: StorageMapAnalysisResult) async throws -> DownloadsTrashPlan {
        let running = await environment.runningApplicationState()
        let environment = environment
        let worker = Task.detached(priority: .userInitiated) { () throws -> DownloadsTrashPlan in
            try Task.checkCancellation()
            var policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
            policy.runningApplicationPaths = running.paths
            policy.unknownRunningApplicationNames = running.unknownApplicationNames
            let selections = rows.map { row in
                FileAnalysisTrashSelection(path: row.path, title: row.name, isDirectory: row.isDirectory, kind: row.kind,
                                           bytes: row.bytes, itemCount: row.itemCount)
            }
            let review = FileAnalysisTrashService.review(selections, index: analysis.index, policy: policy,
                                                         environment: environment, externalVolumeName: nil)
            return DownloadsTrashPlan(review: review, index: analysis.index, policy: policy)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func execute(_ plan: DownloadsTrashPlan) async throws -> FileAnalysisTrashOutcome {
        try await coordinator.withLease(owner: .cleanup) { lease in
            try await coordinator.requireValid(lease, owner: .cleanup)
            return await FileAnalysisTrashService.execute(plan.review.items, index: plan.index, policy: plan.policy,
                environment: environment, beforeEachMove: { try await coordinator.requireValid(lease, owner: .cleanup) })
        }
    }
}
