import Foundation

enum BrowserPrivacyDataType: String, CaseIterable, Codable, Sendable {
    case cookies, siteStorage, downloads, autofill, sessions
    var title: String {
        switch self {
        case .cookies: L10n.text("Cookie", "Cookies")
        case .siteStorage: L10n.text("站点存储", "Site Storage")
        case .downloads: L10n.text("下载记录", "Download Records")
        case .autofill: L10n.text("表单自动填充", "Form Autofill")
        case .sessions: L10n.text("最近关闭的标签与窗口", "Recently Closed Tabs and Windows")
        }
    }
    var limitation: String {
        switch self {
        case .siteStorage: L10n.text("仅只读 Firefox 旧版站点存储数据库（不代表当前站点存储已清理）；其他本地存储、索引数据库与服务工作线程缓存尚不能安全按站点恢复。", "Firefox legacy site-storage databases are read only; other local storage, IndexedDB and Service Worker caches cannot yet be safely restored by site.")
        case .sessions: L10n.text("会话文件同时包含当前标签，无法在不读取内容时区分最近关闭的标签；不提供删除。", "Session files also contain current tabs; recently closed tabs cannot be separated without reading contents. Deletion is unavailable.")
        case .cookies: L10n.text("格式、应用身份或权限未通过核验的组合不提供删除。Safari Cookie 受系统保护，目前没有不读取值的安全读取器，只读入口不提供删除。", "Deletion requires verified format, app identity and access. Safari cookies are protected; a reader that avoids values is not available, and its read-only entry offers no deletion.")
        default: L10n.text("格式、应用身份或权限未通过核验的组合不提供删除。", "Deletion requires verified format, app identity and access.")
        }
    }
}

/// A fixed adapter identifier, never an arbitrary path/table supplied by metadata.
enum BrowserPrivacyDataContract: String, Codable, CaseIterable, Sendable {
    case chromiumCookies, chromiumNetworkCookies, firefoxCookies
    case chromiumAutofill, firefoxAutofill, chromiumDownloads, firefoxLegacyStorage
    var type: BrowserPrivacyDataType {
        switch self {
        case .chromiumCookies, .chromiumNetworkCookies, .firefoxCookies: .cookies
        case .chromiumAutofill, .firefoxAutofill: .autofill
        case .chromiumDownloads: .downloads
        case .firefoxLegacyStorage: .siteStorage
        }
    }
    var engine: BrowserPrivacyEngine {
        switch self {
        case .firefoxCookies, .firefoxAutofill, .firefoxLegacyStorage: .firefox
        default: .chromium
        }
    }
    var relativePath: String {
        switch self {
        case .chromiumCookies: "Cookies"
        case .chromiumNetworkCookies: "Network/Cookies"
        case .firefoxCookies: "cookies.sqlite"
        case .chromiumAutofill: "Web Data"
        case .firefoxAutofill: "formhistory.sqlite"
        case .chromiumDownloads: "History"
        case .firefoxLegacyStorage: "webappsstore.sqlite"
        }
    }
    var table: String {
        switch self {
        case .chromiumCookies, .chromiumNetworkCookies: "cookies"
        case .firefoxCookies: "moz_cookies"
        case .chromiumAutofill: "autofill"
        case .firefoxAutofill: "moz_formhistory"
        case .chromiumDownloads: "downloads"
        case .firefoxLegacyStorage: "webappsstore2"
        }
    }
    var keyColumn: String {
        switch self {
        case .chromiumCookies, .chromiumNetworkCookies: "host_key"
        case .firefoxCookies: "host"
        case .chromiumAutofill: "name"
        case .firefoxAutofill: "fieldname"
        case .chromiumDownloads: "id"
        case .firefoxLegacyStorage: "originKey"
        }
    }
    var usesRowBackup: Bool { type == .cookies || self == .chromiumAutofill }
    var permitsDeletion: Bool { self != .firefoxAutofill && self != .firefoxLegacyStorage }
    var unavailableReason: String {
        switch self {
        case .firefoxAutofill: L10n.text("只读：新版表单外键关系尚未完成行级恢复适配。", "Read only: modern form-history foreign keys do not yet have a verified row restore adapter.")
        case .firefoxLegacyStorage: L10n.text("仅遗留文件（Firefox 92 起）；读取结果不代表当前站点存储，暂不开放删除。", "Legacy file only (Firefox 92 onward). These results do not describe current site storage; deletion is unavailable.")
        default: L10n.text("只读：应用身份或数据库格式未通过写入核验。", "Read only: app identity or database format has not passed write verification.")
        }
    }
    var schema: SQLiteSchemaAllowlist {
        .init(requiredTables: [.init(name: table, requiredColumns: [keyColumn])])
    }
}

struct BrowserPrivacyDataGroup: Identifiable, Equatable, Sendable {
    let profile: BrowserPrivacyProfile
    let contract: BrowserPrivacyDataContract
    let key: String
    let count: Int
    let identities: [BrowserPrivacyPathIdentity]
    let writable: Bool
    var members: [String: Int] = [:]
    var writeFailure: BrowserPrivacyDataFailure? = nil
    var unavailableReason: String { writeFailure?.text ?? contract.unavailableReason }
    var deletionCounts: [String: Int] { members.isEmpty ? [key: count] : members }
    var id: String { profile.id + ":" + contract.rawValue + ":" + key }
    var isDefaultSelected: Bool { false }
    var site: String? {
        switch contract.type {
        case .cookies: return Self.normalizedSite(key)
        case .siteStorage:
            // Firefox originKey encodes the host reversed before :scheme:port.
            let host = key.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return Self.normalizedSite(String(host.reversed()))
        default: return nil
        }
    }
    var label: String {
        if let site { return site }
        if contract.type == .downloads { return L10n.text("下载列表（文件保留）", "Download list (files kept)") }
        let field = key.lowercased()
        if field.contains("mail") { return L10n.text("电子邮箱字段", "Email fields") }
        if field.contains("address") { return L10n.text("地址字段", "Address fields") }
        if field.contains("name") { return L10n.text("姓名字段", "Name fields") }
        return L10n.text("其他表单字段", "Other form fields")
    }
    func isProtected(by sites: Set<String>) -> Bool {
        guard let site else { return false }
        if Self.isKept(site, by: sites) { return true }
        guard contract.type == .cookies else { return false }
        return deletionCounts.keys.contains { domain in
            guard domain.hasPrefix(".") else { return false }
            let parent = Self.normalizedSite(domain)
            return sites.contains { Self.normalizedSite($0).hasSuffix("." + parent) }
        }
    }
    static func isKept(_ site: String, by sites: Set<String>) -> Bool {
        let normalized = normalizedSite(site)
        return sites.contains { normalized == normalizedSite($0) || normalized.hasSuffix("." + normalizedSite($0)) }
    }
    static func normalizedSite(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
    }
}

struct BrowserPrivacyDataRunFailure: Error {
    let completedCount: Int
    let underlying: any Error
}

enum BrowserPrivacyDataFailure: Error, Equatable {
    case browserRunning, unsupported, changed, pendingWrites, readback, database, rollback, capacity, concurrentOperation, lockUnverifiable, unknownDownloadTable
    static func describe(_ error: Error) -> String {
        if let run = error as? BrowserPrivacyDataRunFailure {
            return L10n.text("本次运行已回读确认删除 \(ByteFormat.count(run.completedCount)) 条，备份保留；后续批次停止：", "This run confirmed deletion of \(ByteFormat.count(run.completedCount)) records and kept their backups; later batches stopped: ") + describe(run.underlying)
        }
        if let failure = error as? Self { return failure.text }
        if error is BrowserPrivacyBackupStorageFailure {
            return L10n.text("恢复备份未能安全保存，没有执行删除。", "The recovery backup could not be saved safely; deletion was not performed.")
        }
        switch error {
        case SQLiteSnapshotFailure.permissionDenied: return L10n.text("没有读取权限，请检查完全磁盘访问权限。", "Read access was denied. Check Full Disk Access.")
        case SQLiteSnapshotFailure.busy: return L10n.text("数据库被占用，请正常退出浏览器后重试。", "The database is busy. Quit the browser normally and retry.")
        case SQLiteSnapshotFailure.timedOut: return L10n.text("读取超时，请稍后重试。", "The read timed out. Retry later.")
        case SQLiteSnapshotFailure.malformedSchema: return L10n.text("数据库格式不支持，不提供删除。", "The database format is unsupported; deletion is unavailable.")
        default: return Self.database.text
        }
    }
    var text: String {
        switch self {
        case .concurrentOperation: L10n.text("已有删除或恢复在进行，请等待完成后重试。", "Another deletion or restore is already in progress. Wait for it to finish and retry.")
        case .lockUnverifiable: L10n.text("无法核实浏览器配置锁是否被持有，暂不提供写入；请退出浏览器并检查配置文件权限。", "The browser profile lock could not be verified. Writes are unavailable; quit the browser and check profile permissions.")
        case .capacity: L10n.text("恢复备份剩余额度不足，请减少选择或先处理旧备份；没有执行删除。", "Recovery backup capacity is insufficient. Reduce the selection or manage older backups first; nothing was deleted.")
        case .unknownDownloadTable: L10n.text("发现未知下载关联表或列，不执行删除，请等待格式适配。", "An unknown download-related table or column was found. Deletion is refused until this format is supported.")
        case .browserRunning: L10n.text("浏览器正在运行，请正常退出后重试；没有写入。", "The browser is running. Quit normally and retry; nothing was written.")
        case .unsupported: L10n.text("此组合不支持直接删除。", "Direct deletion is unavailable for this combination.")
        case .changed: L10n.text("数据或路径已变化，请重新扫描。", "Data or paths changed. Scan again.")
        case .pendingWrites: L10n.text("数据库存在未合并写入，请打开浏览器并正常退出后重试。", "The database has pending writes. Open the browser and quit normally, then retry.")
        case .readback: L10n.text("删除条数回读不一致，操作未能确认，请在备份到期前核对或恢复。", "Deletion counts could not be confirmed. Check or restore before the backup expires.")
        case .database: L10n.text("数据库格式、权限或锁定状态不允许处理。", "Database format, access or locking prevents processing.")
        case .rollback: L10n.text("回滚未能确认，请在备份到期前从操作记录恢复。", "Rollback could not be confirmed. Restore from the operation records before the backup expires.")
        }
    }
}

/// Bounded, type-specific review text; no unopened capability is advertised.
enum BrowserPrivacyDataConfirmation {
    static func message(_ groups: [BrowserPrivacyDataGroup], limit: Int = 8) -> String {
        let types = Set(groups.map { $0.contract.type })
        var parts = [L10n.text("将备份并删除：", "Back up and delete: ") + types.map(\.title).sorted().joined(separator: "、")]
        // Several profiles of one browser can hold the same site; name the profile.
        parts += groups.prefix(limit).map { $0.profile.browser.displayName + " · " + $0.profile.displayName + " · " + $0.contract.type.title + " · " + $0.label }
        if groups.count > limit { parts.append(L10n.text("等 \(ByteFormat.count(groups.count)) 项（仅列前 \(ByteFormat.count(limit)) 项）", "\(ByteFormat.count(groups.count)) items in total (first \(ByteFormat.count(limit)) shown)")) }
        if types.contains(.cookies) {
            parts.append(L10n.text("将退出这些网站的登录。同域名的所有 Cookie 分区会一起删除；分区和过期可能使登录无法恢复。同步可能回填数据。", "You will be signed out. All cookie partitions of a selected domain are deleted together; partitioning and expiry may prevent login restoration. Sync may refill data."))
            if groups.contains(where: { $0.contract == .firefoxCookies }) {
                parts.append(L10n.text("Firefox 会话 Cookie 可能由会话恢复文件在启动时补回。", "Firefox session cookies may be restored from session files at startup."))
            }
        }
        if types.contains(.downloads) { parts.append(L10n.text("下载只删记录，不删文件；恢复会覆盖同库历史与下载记录。", "Only download records are deleted; files are kept. Restore overwrites history and downloads in the same database.")) }
        if types.contains(.autofill) { parts.append(L10n.text("表单仅处理普通自动填充表；不处理已保存密码、支付卡表、地址资料表或钥匙串。同步可能回填数据。", "Only ordinary autofill is processed; saved passwords, payment cards, address tables and Keychain are excluded. Sync may refill data.")) }
        parts.append(L10n.text("Cookie／表单备份仅含所删行；恢复备份 7 天后自动删除。", "Cookie/form backups contain only deleted rows. Recovery backups expire after 7 days."))
        return parts.joined(separator: "\n")
    }
}
