import Foundation

/// CleanMyMac's resource groups (`resource_group_*`), in its display order.
enum ApplicationResourceGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case binaries
    case applications
    case preferences
    case supportingFiles
    case caches
    case logs
    case crashes
    case container
    case plugins
    case loginItems
    case dockIcon
    case help
    case installers
    case userData
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .binaries: L10n.text("二进制文件", "Binaries")
        case .applications: L10n.text("应用程序", "Applications")
        case .preferences: L10n.text("偏好设置", "Preferences")
        case .supportingFiles: L10n.text("支持文件", "Supporting Files")
        case .caches: L10n.text("缓存", "Caches")
        case .logs: L10n.text("日志", "Logs")
        case .crashes: L10n.text("系统崩溃", "Crashes")
        case .container: L10n.text("容器", "Container")
        case .plugins: L10n.text("插件", "Plugins")
        case .loginItems: L10n.text("登录项", "Login Items")
        case .dockIcon: L10n.text("程序坞图标", "Dock Icon")
        case .help: L10n.text("帮助", "Help")
        case .installers: L10n.text("安装器", "Installers")
        case .userData: L10n.text("用户数据", "User Data")
        case .other: L10n.text("其他", "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .binaries: "app"
        case .applications: "square.stack.3d.up"
        case .preferences: "slider.horizontal.3"
        case .supportingFiles: "folder"
        case .caches: "internaldrive"
        case .logs: "doc.text"
        case .crashes: "exclamationmark.triangle"
        case .container: "shippingbox"
        case .plugins: "puzzlepiece.extension"
        case .loginItems: "power"
        case .dockIcon: "dock.rectangle"
        case .help: "questionmark.circle"
        case .installers: "arrow.down.doc"
        case .userData: "person.crop.square"
        case .other: "ellipsis.circle"
        }
    }
}

/// Why a resource is attributed to the application. Ordered from the
/// strongest evidence to the weakest.
enum ApplicationResourceEvidence: String, Codable, Sendable, Comparable {
    case bundle
    case bundleIdentifier
    case helperIdentifier
    case applicationGroup
    case launchdReference
    case dockReference
    case executableName
    case nameMatch

    private var rank: Int {
        switch self {
        case .bundle: 0
        case .bundleIdentifier: 1
        case .helperIdentifier: 2
        case .applicationGroup: 3
        case .launchdReference: 4
        case .dockReference: 5
        case .executableName: 6
        case .nameMatch: 7
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    var title: String {
        switch self {
        case .bundle: L10n.text("应用本体", "The app itself")
        case .bundleIdentifier: L10n.text("与应用标识一致", "Matches the app's identifier")
        case .helperIdentifier: L10n.text("属于应用内的辅助程序", "Belongs to a helper inside the app")
        case .applicationGroup: L10n.text("应用声明的共享组", "An app group the app declares")
        case .launchdReference: L10n.text("启动项指向这个应用", "A launch item that points to the app")
        case .dockReference: L10n.text("程序坞里指向这个应用", "A Dock tile that points to the app")
        case .executableName: L10n.text("以应用程序名命名的报告", "A report named after the app's program")
        case .nameMatch: L10n.text("名称与应用名逐词一致", "Its name matches the app's name word for word")
        }
    }
}

/// Where a resource lives: the user's own Library, or a system location that
/// needs an administrator to change.
enum ApplicationResourceDomain: String, Codable, Sendable {
    case user
    case system
}

/// One thing that belongs to an application and that an uninstall or a reset
/// removes. Every file item is moved to the Trash; the Dock tile and launch
/// items are detached rather than deleted.
struct ApplicationResource: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case file
        /// A launchd property list (LaunchAgents, LaunchDaemons): unloaded
        /// before the file moves.
        case launchdJob(label: String)
        /// A tile in the Dock's `persistent-apps`; nothing on disk moves.
        case dockTile(url: String)
    }

    let path: String
    let group: ApplicationResourceGroup
    let evidence: ApplicationResourceEvidence
    let domain: ApplicationResourceDomain
    let kind: Kind
    var sizeBytes: Int64
    let identity: FileIdentity?
    /// False for items the app may show but never move (system-protected
    /// files, App Store bundles Apple restricts).
    var isRemovable: Bool
    var note: String?

    var id: String {
        switch kind {
        case .dockTile(let url): "dock:" + url
        default: path
        }
    }

    var displayName: String {
        switch kind {
        case .dockTile: L10n.text("程序坞中的图标", "Icon in the Dock")
        default: (path as NSString).lastPathComponent
        }
    }
}

/// What the finder needs to know about an application.
struct ApplicationProfile: Hashable, Sendable {
    let bundleURL: URL
    let bundleIdentifier: String
    let displayName: String
    let bundleName: String
    let executableName: String?
    let version: String
    let teamIdentifier: String?
    let applicationGroups: [String]
    let helperBundleIdentifiers: [String]
    let privilegedExecutables: [String]

    var path: String { bundleURL.path }
    var isAppleApplication: Bool { bundleIdentifier.hasPrefix("com.apple.") }

    /// Bundles under `/System`, and Apple's applications the system protects,
    /// cannot be removed; only their related files can be (a reset).
    var isProtectedSystemApplication: Bool {
        path.hasPrefix("/System/") || (isAppleApplication && Self.isSystemProtected(path))
    }

    static func isSystemProtected(_ path: String) -> Bool {
        var info = statfs()
        if path.hasPrefix("/System/") { return true }
        // A sealed system-volume bundle reached through a firmlink (Safari in
        // /Applications) reports the read-only system volume as its mount.
        guard statfs(path, &info) == 0 else { return false }
        let mount = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mount == "/" && (info.f_flags & UInt32(MNT_RDONLY)) != 0
    }
}
