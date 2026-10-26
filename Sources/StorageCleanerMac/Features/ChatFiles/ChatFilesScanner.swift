import Darwin
import Foundation

/// D-FP3: lists what the chat apps keep of received pictures, videos and
/// files, by account, kind and month, and whether each month is older than
/// the cutoff (Lemon splits at 90 days). Only folder listings and file
/// sizes are read; links are not followed and nothing changes.
struct ChatFilesScanner: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var cutoffDays = 90
    var now: @Sendable () -> Date = { Date() }
    var apps: [ChatApp] = ChatApp.allCases
    var metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()
    /// A folder with more entries than this is reported as "at least".
    var entryLimitPerFolder = 200_000
    var fullDiskAccess: @Sendable () -> FullDiskAccessState = { ScanReadinessService.fullDiskAccessState() }

    /// Nothing in the chat apps' containers is read without Full Disk
    /// Access: macOS would otherwise ask once per app.
    func access() -> ChatFilesAccess {
        fullDiskAccess() == .notVerified ? .needsFullDiskAccess : .granted
    }

    func scan() -> ChatFilesInventory {
        var rows: [ChatFilesRow] = []
        var found: [ChatApp] = []
        let cutoff = now().addingTimeInterval(-Double(cutoffDays) * 86_400)
        for app in apps {
            let root = home.appendingPathComponent(app.accountsRoot, isDirectory: true)
            guard isDirectory(root) else { continue }
            found.append(app)
            for account in accountFolders(in: root, app: app) {
                if Task.isCancelled { break }
                let accountName = account.path.dropFirst(root.path.count + 1).description
                for layout in app.layouts {
                    rows += self.rows(app: app, account: accountName, accountURL: account, layout: layout, cutoff: cutoff)
                }
            }
        }
        rows.sort { a, b in
            if a.app != b.app { return ChatApp.allCases.firstIndex(of: a.app)! < ChatApp.allCases.firstIndex(of: b.app)! }
            if a.account != b.account { return a.account < b.account }
            if a.kind != b.kind { return ChatMediaKind.allCases.firstIndex(of: a.kind)! < ChatMediaKind.allCases.firstIndex(of: b.kind)! }
            return (a.month ?? "") > (b.month ?? "")
        }
        return ChatFilesInventory(rows: rows.filter { $0.bytes > 0 || $0.fileCount > 0 }, appsFound: found,
                                  scannedAt: now(), cutoffDays: cutoffDays)
    }

    // MARK: Walking

    func accountFolders(in root: URL, app: ChatApp) -> [URL] {
        var level = [root]
        for _ in 0..<app.accountDepth {
            level = level.flatMap { subdirectories(of: $0) }
        }
        return level.filter { app.isAccountFolder($0.lastPathComponent) }
    }

    func rows(app: ChatApp, account: String, accountURL: URL, layout: ChatMediaLayout, cutoff: Date) -> [ChatFilesRow] {
        let typeFolders = expand(accountURL, components: layout.path.split(separator: "/").map(String.init))
        guard !typeFolders.isEmpty else { return [] }
        if layout.monthDepth == 0 {
            return [row(app: app, account: account, kind: layout.kind, month: nil, folders: typeFolders, cutoff: cutoff)]
        }
        var byMonth: [String: [URL]] = [:]
        var unsorted: [URL] = []
        for typeFolder in typeFolders {
            var level = [typeFolder]
            for depth in 1...layout.monthDepth {
                var next: [URL] = []
                for folder in level {
                    for child in entries(of: folder) {
                        let name = child.lastPathComponent
                        if depth == layout.monthDepth {
                            if Self.isMonth(name), isDirectory(child) { byMonth[name, default: []].append(child) }
                            else if layout.monthDepth == 1 { unsorted.append(child) }
                        } else if isDirectory(child) {
                            next.append(child)
                        }
                    }
                }
                level = next
            }
        }
        var result = byMonth.map { month, folders in
            row(app: app, account: account, kind: layout.kind, month: month, folders: folders, cutoff: cutoff)
        }
        if !unsorted.isEmpty {
            result.append(row(app: app, account: account, kind: layout.kind, month: nil, folders: unsorted, cutoff: cutoff))
        }
        return result
    }

    func row(app: ChatApp, account: String, kind: ChatMediaKind, month: String?, folders: [URL], cutoff: Date) -> ChatFilesRow {
        var bytes: Int64 = 0
        var count = 0
        var newest: Date?
        var lowerBound = false
        for folder in folders {
            let measured = measure(folder)
            bytes += measured.bytes
            count += measured.files
            if let date = measured.newest, newest.map({ date > $0 }) ?? true { newest = date }
            lowerBound = lowerBound || !measured.complete
        }
        let older: Bool
        if let month, let end = Self.endOfMonth(month) {
            older = end < cutoff
        } else {
            older = newest.map { $0 < cutoff } ?? false
        }
        let paths = folders.map { PathSafety.lexicalPath($0.path) }.sorted()
        return ChatFilesRow(
            id: "\(app.rawValue)|\(account)|\(kind.rawValue)|\(month ?? "-")",
            app: app, account: account, kind: kind, month: month,
            folders: paths.map { .init(path: $0, identity: try? metadata.snapshot(at: URL(fileURLWithPath: $0)).identity) },
            bytes: bytes, fileCount: count, newestModification: newest, isOlderThanCutoff: older,
            sizeIsLowerBound: lowerBound)
    }

    /// Allocated bytes, regular files and the newest change below a folder
    /// (or of a single file), links not followed.
    func measure(_ url: URL) -> (bytes: Int64, files: Int, newest: Date?, complete: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .contentModificationDateKey]
        func values(_ url: URL) -> URLResourceValues? { try? url.resourceValues(forKeys: Set(keys)) }
        guard let top = values(url), top.isSymbolicLink != true else { return (0, 0, nil, true) }
        if top.isRegularFile == true {
            return (Int64(top.totalFileAllocatedSize ?? top.fileAllocatedSize ?? 0), 1, top.contentModificationDate, true)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else {
            return (0, 0, nil, false)
        }
        var bytes: Int64 = 0, files = 0, visited = 0
        var newest: Date?
        while let child = enumerator.nextObject() as? URL {
            visited += 1
            if visited > entryLimitPerFolder { return (bytes, files, newest, false) }
            guard let value = values(child), value.isSymbolicLink != true, value.isRegularFile == true else { continue }
            bytes += Int64(value.totalFileAllocatedSize ?? value.fileAllocatedSize ?? 0)
            files += 1
            if let date = value.contentModificationDate, newest.map({ date > $0 }) ?? true { newest = date }
        }
        return (bytes, files, newest, true)
    }

    // MARK: Helpers

    static func isMonth(_ name: String) -> Bool {
        name.count == 7 && name.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil
    }

    static func endOfMonth(_ month: String) -> Date? {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let number = Int(parts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let start = calendar.date(from: DateComponents(year: year, month: number, day: 1)) else { return nil }
        return calendar.date(byAdding: DateComponents(month: 1, second: -1), to: start)
    }

    func expand(_ base: URL, components: [String]) -> [URL] {
        var level = [base]
        for component in components {
            if component == "*" {
                level = level.flatMap { subdirectories(of: $0) }
            } else {
                level = level.map { $0.appendingPathComponent(component, isDirectory: true) }.filter(isDirectory)
            }
        }
        return level
    }

    func entries(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    func subdirectories(of folder: URL) -> [URL] {
        entries(of: folder).filter(isDirectory)
    }

    /// A real folder, not a link to one.
    func isDirectory(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }
}
