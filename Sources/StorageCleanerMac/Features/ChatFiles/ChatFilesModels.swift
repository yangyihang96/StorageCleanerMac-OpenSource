import Foundation

/// D-FP3 (竞品对比 2026-10-20, Tencent Lemon's `LemonFileMove`): the chat
/// apps whose received pictures, videos and files the Chat Files page
/// lists. Paths are those Lemon 5.3.4 reads; nothing inside a chat database
/// is read, only folder listings and file sizes.
enum ChatApp: String, CaseIterable, Codable, Sendable, Identifiable {
    case wechat
    case wechatLegacy
    case qq
    case wecom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wechat: L10n.text("微信", "WeChat")
        case .wechatLegacy: L10n.text("微信（旧版数据）", "WeChat (Older Data)")
        case .qq: "QQ"
        case .wecom: L10n.text("企业微信", "WeCom")
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .wechat, .wechatLegacy: "com.tencent.xinWeChat"
        case .qq: "com.tencent.qq"
        case .wecom: "com.tencent.WeWorkMac"
        }
    }

    /// Home-relative folder holding one folder per account.
    var accountsRoot: String {
        switch self {
        case .wechat: "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
        case .wechatLegacy:
            "Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat"
        case .qq: "Library/Containers/com.tencent.qq/Data/Library/Application Support/QQ"
        case .wecom: "Library/Containers/com.tencent.WeWorkMac/Data/Documents/Profiles"
        }
    }

    /// The app's container, the only place its rows may come from.
    var containerRoot: String {
        "Library/Containers/\(bundleIdentifier)"
    }

    /// Where each kind lives below an account folder. `monthDepth` is where
    /// the `YYYY-MM` folders are (1: directly, 2: one chat folder between),
    /// 0 when the kind is not split by month.
    var layouts: [ChatMediaLayout] {
        switch self {
        case .wechat:
            [ChatMediaLayout(kind: .images, path: "msg/attach", monthDepth: 2),
             ChatMediaLayout(kind: .videos, path: "msg/video", monthDepth: 1),
             ChatMediaLayout(kind: .files, path: "msg/file", monthDepth: 1)]
        case .wechatLegacy:
            [ChatMediaLayout(kind: .images, path: "Message/MessageTemp/*/Image", monthDepth: 0),
             ChatMediaLayout(kind: .videos, path: "Message/MessageTemp/*/Video", monthDepth: 0),
             ChatMediaLayout(kind: .files, path: "Message/MessageTemp/*/File", monthDepth: 0)]
        case .qq:
            [ChatMediaLayout(kind: .images, path: "nt_data/Pic", monthDepth: 1),
             ChatMediaLayout(kind: .videos, path: "nt_data/Video", monthDepth: 1),
             ChatMediaLayout(kind: .files, path: "nt_data/File", monthDepth: 1)]
        case .wecom:
            [ChatMediaLayout(kind: .images, path: "Caches/Images", monthDepth: 1),
             ChatMediaLayout(kind: .videos, path: "Caches/Videos", monthDepth: 1),
             ChatMediaLayout(kind: .files, path: "Caches/Files", monthDepth: 1)]
        }
    }

    /// Account folders: WeChat 4 `wxid_…`, older WeChat `<version>/<hash>`,
    /// QQ `nt_qq_…`, WeCom one folder per profile.
    var accountDepth: Int { self == .wechatLegacy ? 2 : 1 }

    func isAccountFolder(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        switch self {
        case .wechat: return !["all_users", "Backup", "WMPF", "applet"].contains(name)
        case .wechatLegacy: return true
        case .qq: return name.hasPrefix("nt_qq_")
        case .wecom: return true
        }
    }
}

enum ChatMediaKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case images
    case videos
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: L10n.text("图片", "Pictures")
        case .videos: L10n.text("视频", "Videos")
        case .files: L10n.text("文件", "Files")
        }
    }

    var systemImage: String {
        switch self {
        case .images: "photo"
        case .videos: "video"
        case .files: "doc"
        }
    }

    /// Pictures are kept in the chat app's own format (WeChat stores them
    /// encrypted), so a copy elsewhere cannot be opened; only videos and
    /// files are offered for copying to another drive.
    var canBeCopiedElsewhere: Bool { self != .images }
}

struct ChatMediaLayout: Equatable, Sendable {
    let kind: ChatMediaKind
    /// Below the account folder; `*` stands for any one folder (a chat).
    let path: String
    let monthDepth: Int
}

/// One row: a month of one kind in one account (all chats together), or
/// the whole kind when the app does not split it by month.
struct ChatFilesRow: Identifiable, Equatable, Sendable {
    struct Folder: Equatable, Sendable {
        let path: String
        let identity: FileIdentity?
    }

    let id: String
    let app: ChatApp
    let account: String
    let kind: ChatMediaKind
    /// `YYYY-MM`, nil for a kind not split by month.
    let month: String?
    let folders: [Folder]
    let bytes: Int64
    let fileCount: Int
    let newestModification: Date?
    let isOlderThanCutoff: Bool
    let sizeIsLowerBound: Bool

    /// The account folder's name, shortened ("wxid_ab…9f2c").
    var accountLabel: String {
        account.count <= 14 ? account : String(account.prefix(7)) + "…" + String(account.suffix(4))
    }

    var title: String {
        if let month { return "\(month) · \(kind.title)" }
        return kind.title
    }
}

struct ChatFilesInventory: Equatable, Sendable {
    let rows: [ChatFilesRow]
    /// Apps whose folders were found (installed or not).
    let appsFound: [ChatApp]
    let scannedAt: Date
    let cutoffDays: Int

    func rows(for app: ChatApp) -> [ChatFilesRow] { rows.filter { $0.app == app } }

    var totalBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }

    /// For the result tile: everything found and what is older than the cutoff.
    var summary: ChatFilesSummary {
        let older = rows.filter(\.isOlderThanCutoff)
        return ChatFilesSummary(totalBytes: totalBytes, fileCount: rows.reduce(0) { $0 + $1.fileCount },
                                olderBytes: older.reduce(0) { $0 + $1.bytes }, appCount: Set(rows.map(\.app)).count)
    }
}

struct ChatFilesSummary: Equatable, Sendable {
    let totalBytes: Int64
    let fileCount: Int
    let olderBytes: Int64
    let appCount: Int
}

enum ChatFilesAccess: Equatable, Sendable {
    case granted
    /// The chat apps' folders are in their containers; without Full Disk
    /// Access macOS would ask for each app, so nothing is read.
    case needsFullDiskAccess
}
