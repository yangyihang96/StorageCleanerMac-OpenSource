import Foundation

enum IgnoreCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case systemJunk, aiClutter, mailAttachments, malware, uninstaller, updates
    case duplicates, similar, largeAndOld, downloads, other
    var id: String { rawValue }
    var isApplication: Bool { self == .uninstaller || self == .updates }
    var group: String {
        switch self {
        case .systemJunk, .aiClutter, .mailAttachments: L10n.text("垃圾清理", "Cleanup")
        case .malware: L10n.text("安全防护", "Protection")
        case .uninstaller, .updates: L10n.text("应用", "Applications")
        case .duplicates, .similar, .largeAndOld, .downloads: L10n.text("杂乱", "Clutter")
        case .other: L10n.text("其他", "Other")
        }
    }
    var title: String {
        switch self {
        case .systemJunk: L10n.text("系统垃圾", "System Junk")
        case .aiClutter: L10n.text("AI 杂物", "AI Clutter")
        case .mailAttachments: L10n.text("邮件附件", "Mail Attachments")
        case .malware: L10n.text("恶意软件", "Malware")
        case .uninstaller: L10n.text("卸载", "Uninstaller")
        case .updates: L10n.text("更新", "Updates")
        case .duplicates: L10n.text("重复文件", "Duplicates")
        case .similar: L10n.text("相似文件", "Similar Files")
        case .largeAndOld: L10n.text("大型和旧文件", "Large & Old Files")
        case .downloads: L10n.text("下载", "Downloads")
        case .other: L10n.text("其他", "Other")
        }
    }
    static func cleanup(for rule: CleanupRule) -> Self {
        cleanup(for: CareJunkGroup.group(for: rule))
    }
    /// A junk group's category; the managers file a candidate by its rule's group, as the scan does.
    static func cleanup(for group: CareJunkGroup) -> Self {
        switch group.scanScope {
        case .aiClutter: .aiClutter
        case .mailAttachments: .mailAttachments
        case .trashBins: .other
        default: .systemJunk
        }
    }
}

struct IgnoreListTarget: Codable, Hashable, Sendable {
    let path: String
    var bundleIdentifier: String? = nil
    var latestVersion: String? = nil
    static func application(bundleIdentifier: String, path: String) -> Self {
        Self(path: path, bundleIdentifier: bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct IgnoreListEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let category: IgnoreCategory
    let target: IgnoreListTarget
    let displayName: String
    let addedAt: Date
    var detail: String {
        if let version = target.latestVersion {
            return L10n.text("只忽略 \(version)", "Ignore only \(version)") + " · " + target.path
        }
        return target.path
    }
}

/// Value copied once at scan entry; no live defaults or store reads during a walk.
struct IgnoreListSnapshot: Codable, Hashable, Sendable {
    var entries: [IgnoreListEntry] = []
    static let empty = Self()
    func paths(for category: IgnoreCategory) -> [String] {
        entries.filter {
            ($0.category == category || $0.category == .other) && $0.target.bundleIdentifier == nil
        }.map(\.target.path)
    }
    func ignores(path: String, category: IgnoreCategory, includingDescendants: Bool = false) -> Bool {
        let path = PathSafety.normalizedPath(path)
        return paths(for: category).contains {
            PathSafety.isContained(path, in: $0, resolvingSymlinks: false)
                || (includingDescendants && PathSafety.isContained($0, in: path, resolvingSymlinks: false))
        }
    }
    func ignoresApplication(bundleIdentifier: String, path: String, category: IgnoreCategory,
                            latestVersion: String? = nil) -> Bool {
        if ignores(path: path, category: category) { return true }
        let key = AppUpdateIgnoreService.identifier(bundleIdentifier: bundleIdentifier, path: path)
        return entries.contains {
            guard $0.category == category, $0.target.bundleIdentifier != nil,
                  AppUpdateIgnoreService.identifier(bundleIdentifier: $0.target.bundleIdentifier ?? "", path: $0.target.path) == key else { return false }
            return $0.target.latestVersion == nil || $0.target.latestVersion == latestVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    func applying(to applications: [InstalledApplication]) -> [InstalledApplication] {
        applications.map { app in
            guard ignoresApplication(bundleIdentifier: app.bundleIdentifier, path: app.path, category: .updates,
                                     latestVersion: app.latestVersion) else { return app }
            var app = app
            app.updateStatus = .ignored
            app.canAutomaticallyUpdate = false
            app.requiresUserInteraction = true
            return app
        }
    }
    static func summary(_ count: Int) -> String {
        L10n.text("已忽略 \(ByteFormat.count(count)) 项", "Ignored \(ByteFormat.count(count)) items")
    }
    /// D207 补: a status line or headline names the ignored only when there
    /// are some. The details sheets keep the count beside their other counts,
    /// zero included (`summary`).
    static func appendingSummary(_ count: Int, to text: String) -> String {
        count > 0 ? text + " · " + summary(count) : text
    }
}

/// All mutable state and disk writes share one lock. Notifications are posted
/// after releasing it, on the main queue, so observers may safely take snapshots.
final class IgnoreListStore: @unchecked Sendable {
    static let shared = IgnoreListStore(fileURL: AppDataDirectories.applicationSupportRoot.appendingPathComponent("IgnoreList.json"))
    static let didChange = Notification.Name("StorageCleanerMac.IgnoreListDidChange")
    static let schemaVersion = 1
    private struct Document: Codable {
        var version = IgnoreListStore.schemaVersion
        var migratedLegacyPaths = false
        var importedAt = Date()
        var entries: [IgnoreListEntry] = []
    }
    private let lock = NSRecursiveLock()
    private let fileURL: URL
    private let defaults: UserDefaults
    private var document = Document()
    private var loaded = false
    private var writable = true
    private var notice: String?
    private var lastAdded: [String] = []
    private var suppressLegacy = false

    init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
    }
    func snapshot() -> IgnoreListSnapshot {
        lock.lock(); defer { lock.unlock() }
        load()
        let versions = suppressLegacy ? [:] : AppUpdateIgnoreService.ignoredVersions(defaults: defaults)
        let legacy = versions.sorted { $0.key < $1.key }.map { key, version in
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let path = parts.count == 2 ? parts[1] : key
            return IgnoreListEntry(id: "legacy-version:" + key, category: .updates,
                target: IgnoreListTarget(path: PathSafety.normalizedPath(path), bundleIdentifier: parts.count == 2 ? parts[0] : "", latestVersion: version),
                displayName: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                addedAt: document.importedAt)
        }
        return IgnoreListSnapshot(entries: document.entries + legacy)
    }
    /// Returns a recovery/write notice once per store instance.
    func takeNotice() -> String? {
        lock.lock(); defer { lock.unlock() }
        load()
        defer { notice = nil }
        return notice
    }
    @discardableResult
    func add(_ target: IgnoreListTarget, category: IgnoreCategory, displayName: String? = nil) -> Bool {
        add([target], category: category, displayNames: displayName.map { [target.path: $0] } ?? [:]) > 0
    }
    @discardableResult
    func add(_ path: String, category: IgnoreCategory) -> Bool {
        add(IgnoreListTarget(path: path), category: category)
    }
    /// A manager's multi-selection is one undo operation.
    @discardableResult
    func add(_ targets: [IgnoreListTarget], category: IgnoreCategory, displayNames: [String: String] = [:]) -> Int {
        lock.lock(); load()
        let previous = document
        var added: [String] = []
        for target in targets {
            guard target.path.hasPrefix("/") || target.path.hasPrefix("~/"), target.latestVersion == nil else { continue }
            let path = PathSafety.normalizedPath(target.path)
            guard path != "/" else { continue }
            let normalized = IgnoreListTarget(path: path, bundleIdentifier: category.isApplication ? target.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            guard !document.entries.contains(where: { $0.category == category && $0.target == normalized }) else { continue }
            let entry = IgnoreListEntry(id: UUID().uuidString, category: category, target: normalized,
                displayName: displayNames[target.path] ?? URL(fileURLWithPath: path).lastPathComponent, addedAt: Date())
            document.entries.append(entry); added.append(entry.id)
        }
        guard !added.isEmpty, persist() else { document = previous; lock.unlock(); return 0 }
        lastAdded = added
        lock.unlock(); changed()
        return added.count
    }
    @discardableResult
    func remove(_ entry: IgnoreListEntry) -> Bool { remove(ids: [entry.id]) }
    @discardableResult
    func remove(ids: Set<String>) -> Bool {
        lock.lock(); load()
        let previous = document
        document.entries.removeAll { ids.contains($0.id) }
        guard persist() else { document = previous; lock.unlock(); return false }
        for id in ids where id.hasPrefix("legacy-version:") {
            AppUpdateIgnoreService.remove(identifier: String(id.dropFirst("legacy-version:".count)), defaults: defaults)
        }
        lastAdded.removeAll { ids.contains($0) }
        lock.unlock(); changed()
        return true
    }
    @discardableResult
    func undoLastAdd() -> Bool {
        lock.lock(); load()
        let ids = Set(lastAdded)
        guard !ids.isEmpty else { lock.unlock(); return false }
        let result = remove(ids: ids)
        lock.unlock()
        return result
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
                guard decoded.version == Self.schemaVersion,
                      decoded.entries.allSatisfy({ $0.target.path.hasPrefix("/") && $0.target.path != "/"
                          && $0.target.path == PathSafety.normalizedPath($0.target.path)
                          && $0.target.latestVersion == nil }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                document = decoded
            } catch {
                // Keep the original bytes even after the next explicit add.
                let backup = fileURL.appendingPathExtension("unreadable-" + UUID().uuidString)
                do { try FileManager.default.copyItem(at: fileURL, to: backup) }
                catch { writable = false }
                document.migratedLegacyPaths = true
                suppressLegacy = true
                notice = L10n.text("忽略列表无法读取，本次按空列表处理。原文件已保留。", "The ignore list could not be read and is treated as empty. The original file is preserved.")
                return
            }
        }
        if !document.migratedLegacyPaths {
            document.migratedLegacyPaths = true
            let legacyPaths = (defaults.stringArray(forKey: ScanExclusionService.defaultsKey) ?? [])
                + (defaults.stringArray(forKey: CleanupMigration.excludedPathsKey) ?? [])
            for path in legacyPaths {
                guard path.hasPrefix("/") || path.hasPrefix("~/") else { continue }
                let path = PathSafety.normalizedPath(path)
                guard path != "/", !document.entries.contains(where: { $0.category == .other && $0.target.path == path }) else { continue }
                document.entries.append(IgnoreListEntry(id: UUID().uuidString, category: .other,
                    target: IgnoreListTarget(path: path), displayName: URL(fileURLWithPath: path).lastPathComponent, addedAt: document.importedAt))
            }
            // Migration never removes or overwrites the legacy defaults.
            _ = persist()
        }
    }
    private func persist() -> Bool {
        guard writable else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            notice = L10n.text("忽略列表未能保存，请检查数据目录是否可写。", "The ignore list could not be saved. Check that the data folder is writable.")
            return false
        }
    }
    private func changed() {
        DispatchQueue.main.async { [self] in
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}

/// An encountered directory counts as one ignored scope; its children are not read.
final class IgnoreListScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [IgnoreCategory: Set<String>] = [:]
    func record(_ path: String, category: IgnoreCategory) {
        let path = PathSafety.normalizedPath(path)
        lock.lock(); defer { lock.unlock() }
        paths[category, default: []].insert(path)
    }
    var counts: [IgnoreCategory: Int] {
        lock.lock(); defer { lock.unlock() }
        return paths.mapValues(\.count)
    }
}
