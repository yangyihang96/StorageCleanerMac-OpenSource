import Foundation

/// D46: why an item in File Analysis cannot be moved to the Trash from here.
/// Each case has a short label for the row and a sentence for the hover help
/// and the review sheet.
enum FileAnalysisTrashBlock: String, CaseIterable, Equatable, Sendable, Error {
    case analysisRoot
    case homeFolder
    case standardFolder
    case systemLocation
    case outsideHome
    case applicationsFolder
    case applicationBundle
    case appData
    case trash
    case cloudStorage
    case cloudOnly
    case readOnlyVolume
    case symbolicLink
    case incompleteMeasurement
    case unreadable
    case excluded
    case locked
    case changedSinceAnalysis
    case missing
    // D54: the protected scope.
    case systemData
    case credentials
    case libraryFolder
    case appContainer
    case containsProtectedLocation
    case containsRunningApplication
    case containsMountPoint
    case cloudStateUnknown
    case runningApplicationStateUnknown
    /// r2-fa-followups P1-1: finding the D54 locations reached through links
    /// ran out of time.
    case protectedLocationsUnknown
    /// r2-fa-followups P2-3: whether an external volume is read-only was not
    /// known in time (`cloudStateUnknown` is iCloud's, for the home folder).
    case volumeStateUnknown

    /// The row's note. r2-fa-followups P2-3: the reasons this batch added are
    /// short phrases that fit one line; the whole sentence is `explanation`,
    /// on hover and in the review.
    var shortTitle: String {
        switch self {
        case .analysisRoot: L10n.text("分析范围本身", "Analyzed location")
        case .homeFolder: L10n.text("用户文件夹", "User folder")
        case .standardFolder: L10n.text("系统标准文件夹", "Standard folder")
        case .systemLocation: L10n.text("系统位置", "System location")
        case .outsideHome: L10n.text("个人目录以外", "Outside your home folder")
        case .applicationsFolder: L10n.text("应用程序文件夹", "Applications folder")
        case .applicationBundle: L10n.text("应用", "App")
        case .appData: L10n.text("本应用的数据", "This app's data")
        case .trash: L10n.text("已在废纸篓", "In the Trash")
        case .cloudStorage: L10n.text("云盘位置", "Cloud storage")
        case .cloudOnly: L10n.text("仅在云端", "Only in the cloud")
        case .readOnlyVolume: L10n.text("只读卷", "Read-only volume")
        case .symbolicLink: L10n.text("符号链接", "Symbolic link")
        case .incompleteMeasurement: L10n.text("测量不完整", "Not fully measured")
        case .unreadable: L10n.text("无法读取", "Unreadable")
        case .excluded: L10n.text("已排除", "Excluded")
        case .locked: L10n.text("已锁定或受保护", "Locked or protected")
        case .changedSinceAnalysis: L10n.text("分析后已变化", "Changed since analysis")
        case .missing: L10n.text("已不存在", "No longer there")
        case .systemData: L10n.text("系统数据", "System data")
        case .credentials: L10n.text("密钥与凭据", "Keys and credentials")
        case .libraryFolder: L10n.text("资源库文件夹", "Library folder")
        case .appContainer: L10n.text("应用容器", "App container")
        case .containsProtectedLocation: L10n.text("含受保护的位置", "Holds a protected location")
        case .containsRunningApplication: L10n.text("含正在运行的应用", "Holds a running app")
        case .containsMountPoint: L10n.text("含挂载点", "Holds a mount point")
        case .cloudStateUnknown: L10n.text("云端状态未知", "iCloud state unknown")
        case .runningApplicationStateUnknown: L10n.text("运行应用位置未知", "Running app location unknown")
        case .protectedLocationsUnknown: L10n.text("保护范围未知", "Protected locations unknown")
        case .volumeStateUnknown: L10n.text("卷状态未知", "Volume state unknown")
        }
    }

    var explanation: String {
        switch self {
        case .analysisRoot:
            L10n.text("这是正在分析的位置本身，不能整体移到废纸篓。",
                      "This is the location being analyzed; it cannot be moved to the Trash as a whole.")
        case .homeFolder:
            L10n.text("用户的个人目录不能整体移到废纸篓。",
                      "A user's home folder cannot be moved to the Trash as a whole.")
        case .standardFolder:
            L10n.text("这是系统的标准文件夹，不能整体移到废纸篓；可以打开它，处理里面的项目。",
                      "This is a standard macOS folder and cannot be moved to the Trash as a whole; open it to handle the items inside.")
        case .systemLocation:
            L10n.text("系统位置中的项目不能在这里移到废纸篓。",
                      "Items in system locations cannot be moved to the Trash here.")
        case .outsideHome:
            L10n.text("这里只处理个人目录和外接卷中的项目；这个位置请在访达中处理。",
                      "Only items in your home folder and on external drives can be moved here; use Finder for this location.")
        case .applicationsFolder:
            L10n.text("“应用程序”文件夹中的项目请在“卸载”中处理。",
                      "Handle items in the Applications folder in Uninstall.")
        case .applicationBundle:
            L10n.text("应用请在“卸载”中处理，那里会一并检查它的关联文件。",
                      "Remove apps in Uninstall, which also checks their related files.")
        case .appData:
            L10n.text("这里有本应用的数据和操作记录，不能在这里移走。",
                      "This holds this app's data and Operation History and cannot be moved here.")
        case .trash:
            L10n.text("这是废纸篓中的项目。", "This item is in the Trash.")
        case .cloudStorage:
            L10n.text("这是 iCloud 云盘或其他云盘中的项目；移到废纸篓会从所有设备删除，请在访达或云盘应用中处理。",
                      "This is in iCloud Drive or another cloud drive. Moving it to the Trash deletes it from every device; use Finder or the cloud drive's app.")
        case .cloudOnly:
            L10n.text("这个项目只在云端、没有下载到本机；请在访达或云盘应用中处理。",
                      "This item is only in the cloud and not downloaded; use Finder or the cloud drive's app.")
        case .readOnlyVolume:
            L10n.text("这个卷是只读的，不能移到废纸篓。",
                      "This volume is read-only; nothing on it can be moved to the Trash.")
        case .symbolicLink:
            L10n.text("这是符号链接，只是指向别处的链接本身，移走它不会释放空间。",
                      "This is a symbolic link: only the link itself, which frees no space.")
        case .incompleteMeasurement:
            L10n.text("这个项目没能完整测量，可能含有未读取的部分，不能整体移到废纸篓。",
                      "This item was not fully measured and may contain unread parts, so it cannot be moved as a whole.")
        case .unreadable:
            L10n.text("无法读取这个项目的信息。", "This item's information could not be read.")
        case .excluded:
            L10n.text("这个位置在扫描排除清单中，或含有排除的项目，不会被移到废纸篓。",
                      "This location is on the scan exclusion list, or contains an excluded item, so it is not moved to the Trash.")
        case .locked:
            L10n.text("这个项目已锁定或受系统保护；可在访达的“显示简介”中解锁。",
                      "This item is locked or protected by macOS; unlock it in Finder's Get Info.")
        case .changedSinceAnalysis:
            L10n.text("这个项目在分析后被修改或替换了，请重新分析后再处理。",
                      "This item was changed or replaced after the analysis; analyze again first.")
        case .missing:
            L10n.text("这个项目已不在原处。", "This item is no longer where the analysis found it.")
        case .systemData:
            L10n.text("这是系统数据（如钥匙串、邮件、信息、偏好设置、系统应用的容器），连同其中的内容都不能移到废纸篓：系统和应用离不开它们，移走后会被重建，“操作记录”也无法放回。",
                      "This is system data (such as keychains, Mail, Messages, preferences or Apple apps' containers); neither it nor anything inside it can be moved to the Trash. macOS and apps rely on it and recreate it, so Operation History could not put it back.")
        case .credentials:
            L10n.text("这里保存密钥与登录凭据（如 SSH、GPG、云服务的配置），连同其中的内容都不能移到废纸篓。",
                      "This holds keys and sign-in credentials (such as SSH, GPG or cloud service settings); neither it nor anything inside it can be moved to the Trash.")
        case .libraryFolder:
            L10n.text("这是“资源库”第一层的文件夹，系统和应用会用到它，不能整个移到废纸篓；可以打开它，按规则处理里面的项目。",
                      "This is a top-level folder of your Library, which macOS and apps use; it cannot be moved to the Trash whole. Open it to handle the items inside.")
        case .appContainer:
            L10n.text("这是应用的容器（或其中的 Data 文件夹），应用离不开它，不能整个移到废纸篓；可以打开它，按规则处理里面的项目。",
                      "This is an app's container (or its Data folder), which the app relies on; it cannot be moved to the Trash whole. Open it to handle the items inside.")
        case .containsProtectedLocation:
            L10n.text("这个文件夹里有受保护的位置（如密钥与凭据、本应用的数据），不能整个移到废纸篓；可以打开它，处理里面的其他项目。",
                      "This folder holds a protected location (such as keys and credentials or this app's data), so it cannot be moved to the Trash whole. Open it to handle the other items inside.")
        case .containsRunningApplication:
            L10n.text("这个文件夹里有正在运行的应用，不能整个移到废纸篓；请先退出该应用。",
                      "A running app is inside this folder, so it cannot be moved to the Trash whole. Quit the app first.")
        case .containsMountPoint:
            L10n.text("这个文件夹里挂载着其他磁盘或磁盘映像，不能整个移到废纸篓；请先推出该磁盘。",
                      "Another disk or disk image is mounted inside this folder, so it cannot be moved to the Trash whole. Eject it first.")
        case .cloudStateUnknown:
            L10n.text("无法确认云端状态，暂不可选：确认这个位置是否由 iCloud 保管已超时，请重新分析后再试。",
                      "The cloud state could not be confirmed, so this item is unavailable for now. Checking whether iCloud keeps it timed out; analyze again to retry.")
        case .volumeStateUnknown:
            L10n.text("无法确认卷状态，暂不可选：确认这个卷是否只读已超时，请重新分析后再试。",
                      "The volume's state could not be confirmed, so this item is unavailable for now. Checking whether the volume is read-only timed out; analyze again to retry.")
        case .runningApplicationStateUnknown:
            L10n.text("无法确认由系统转移运行的应用的原始位置，暂不能整个勾选文件夹；请退出该应用后重试。",
                      "The original location of an app macOS runs translocated could not be confirmed, so folders cannot be moved whole for now. Quit that app and retry.")
        case .protectedLocationsUnknown:
            L10n.text("无法确认受保护的位置，暂不可选：核对经由链接到达的系统数据和密钥已超时，请重新分析后再试。",
                      "Protected locations could not be confirmed, so this item is unavailable for now. Checking system data and keys reached through links timed out; analyze again to retry.")
        }
    }

    /// `explanation`, naming the apps whose original location is unknown
    /// (r2-fa-followups P2-2: the hint says which app to quit).
    func explanation(naming applications: [String]) -> String {
        guard self == .runningApplicationStateUnknown, !applications.isEmpty else { return explanation }
        let names = applications.map { "“\($0)”" }.joined(separator: L10n.text("、", ", "))
        return L10n.text(
            "无法确认\(names)的原始位置（由系统转移运行），暂不能整个勾选文件夹；请退出\(names)后重试。",
            "The original location of \(names) (run translocated by macOS) could not be confirmed, so folders cannot be moved whole for now. Quit \(names) and retry."
        )
    }

    /// How a block found right before the move is written in the receipt.
    var skipReason: CleanSkipReason {
        switch self {
        case .missing: .itemMissing
        case .changedSinceAnalysis: .changedSinceAnalysis
        case .symbolicLink: .symbolicLinkDetected
        case .cloudStorage, .cloudOnly, .cloudStateUnknown: .cloudStateChanged
        case .readOnlyVolume: .volumeReadOnly
        case .locked: .permissionChanged
        case .incompleteMeasurement: .measurementIncomplete
        case .excluded: .excludedByUser
        case .containsRunningApplication: .relatedAppStillRunning
        case .containsMountPoint: .containsMountPoint
        case .analysisRoot, .homeFolder, .standardFolder, .systemLocation, .outsideHome,
             .applicationsFolder, .applicationBundle, .appData, .trash, .unreadable,
             .systemData, .credentials, .libraryFolder, .appContainer, .containsProtectedLocation,
             .runningApplicationStateUnknown, .protectedLocationsUnknown, .volumeStateUnknown:
            .preflightNotApproved
        }
    }
}

/// D46: which items File Analysis may move to the Trash. Location rules are
/// pure string checks on the index's logical paths, so each row can ask
/// while it draws; what needs the file system is checked again in the
/// review and right before the move (`FileAnalysisTrashService`).
///
/// On the startup disk only items inside the user's home folder qualify:
/// Operation History restores into the home folder. On an external volume
/// everything except the volume's own system folders qualifies; it goes to
/// that volume's Trash.
struct FileAnalysisTrashPolicy: Equatable, Sendable {
    /// Standard folders at the top of a home folder, kept whole.
    static let standardFolderNames: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
    ]

    /// D54 ①: `~/Library` folders kept whole, with everything inside them.
    static let protectedLibraryFolderNames: Set<String> = [
        "Keychains", "Mail", "Messages", "Safari", "Accounts", "Calendars", "Cookies", "HomeKit", "Passes",
        "Autosave Information", "LaunchAgents", "Preferences", "Mobile Documents", "CloudStorage", "Biome",
        "IdentityServices", "Sharing", "Suggestions", "Metadata", "Daemon Containers", "Reminders", "Shortcuts",
    ]
    /// D54 ①: in these `~/Library` folders Apple's own entries and a few
    /// named stores are kept whole.
    static let sharedLibraryFolderNames: Set<String> = ["Containers", "Group Containers", "Application Support"]
    static let protectedSharedEntryNames: Set<String> = [
        "AddressBook", "CallHistoryDB", "Knowledge",
        // D54 supplement (second review P2-1): the File Provider and iCloud
        // Drive databases, more system stores, and the Shortcuts group
        // containers, whose names do not carry `com.apple`.
        "FileProvider", "CloudDocs", "iCloud", "CallHistoryTransactions", "DifferentialPrivacy", "Dock",
        "group.is.workflow.shortcuts", "group.is.workflow.my.app",
    ]
    /// D54 ②: app containers; a container's root and its Data folder are not
    /// moved whole.
    static let appContainerFolderNames: Set<String> = ["Containers", "Group Containers"]
    /// D54 ①: keys and credentials, relative to the home folder.
    static let credentialPaths: [String] = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config/gh", ".config/gcloud", ".netrc",
        // D54 supplement (second review P2-1).
        ".git-credentials", ".npmrc", ".pypirc", ".pgpass", ".cargo/credentials", ".cargo/credentials.toml",
        ".config/op", ".password-store", ".terraform.d/credentials.tfrc.json",
    ]
    /// The credential paths above that are single files.
    static let credentialFilePaths: Set<String> = [
        ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".pgpass", ".cargo/credentials",
        ".cargo/credentials.toml", ".terraform.d/credentials.tfrc.json",
    ]
    /// D54 ①: this app's data folder for every identity (release, beta),
    /// relative to the home folder; the integration identity keeps its data
    /// in folders starting with `integrationDataPrefix`.
    static var appDataRelativePaths: [String] {
        [false, true].map { "Library/Application Support/" + AppDataDirectories.applicationSupportDirectoryName(isBeta: $0) }
    }
    static let integrationDataPrefix = "Library/Caches/StorageCleanerIntegration-"

    // r2-fa-followups P2-4: rows and map tiles ask while they draw, so the
    // lists above are folded once here and `block()` folds only the item's
    // own path.
    static let foldedStandardFolderNames = folded(standardFolderNames)
    static let foldedProtectedLibraryFolderNames = folded(protectedLibraryFolderNames)
    static let foldedSharedLibraryFolderNames = folded(sharedLibraryFolderNames)
    static let foldedProtectedSharedEntryNames = folded(protectedSharedEntryNames)
    static let foldedAppContainerFolderNames = folded(appContainerFolderNames)
    static let foldedCredentialPaths: [String] = credentialPaths.map(protectedName)
    static let foldedAppDataRelativePaths: [String] = appDataRelativePaths.map(protectedName)
    static let foldedIntegrationDataPrefix = protectedName(integrationDataPrefix)
    private static let foldedCloudLocations = ["Library/Mobile Documents", "Library/CloudStorage"].map(protectedName)
    private static let foldedTrash = protectedName(".Trash")
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    let rootPath: String
    let targetKind: StorageMapScanTarget.Kind
    let homePath: String
    let appDataPath: String
    /// `homePath` and `appDataPath` folded once (P2-4), and the home folder in
    /// NFC with its component count, for the case-keeping home check.
    private let foldedHomePath: String
    private let foldedAppDataPath: String
    private let canonicalHomePath: String
    private let homeComponentCount: Int
    /// Scan exclusions, normalized.
    let excludedPaths: [String]
    /// This user's Desktop and Documents when iCloud keeps them.
    var cloudSyncedFolders: [String]
    /// Only asked for an external volume: the startup disk's root reads as
    /// read-only (the sealed system volume) while the home folder is not.
    var isReadOnlyVolume: Bool
    /// D54 ③: running apps' bundles and every mount point, as last read.
    /// The review and the move read them again.
    var runningApplicationPaths: [String]
    /// r2-fa-followups P2-2: translocated apps whose original location is
    /// unknown, by name; while there is one, no folder is moved whole.
    var unknownRunningApplicationNames: [String] = []
    var runningApplicationPathsKnown: Bool { unknownRunningApplicationNames.isEmpty }
    var mountPointPaths: [String]
    /// D54 locations reached through a symbolic link, including links in
    /// their parents. Collected once for an analysis, never while drawing.
    var protectedLinkTargets: [FileAnalysisProtectedLocation]
    /// r2-fa-followups P1-1: the store looks for them off the main thread
    /// when an analysis ends; until then every item that no other rule
    /// blocks waits ("checking"). If that runs out of time, every item is
    /// blocked (`protectedLocationsUnknown`).
    var awaitsProtectedLinkTargets = false
    var protectedLinkTargetsUnknown = false
    /// r2-fa-followups P2-1: folders named `….app` (the scanner indexes them
    /// all as packages) with no executable under the CFBundle naming rules. Read
    /// off the main thread with the links; until then, and for rules made
    /// without the file system, a package named `….app` is an app.
    var nonApplicationBundlePaths: Set<String> = []
    var pendingRefinementPaths: Set<String>
    var failedRefinementPaths: Set<String> = []

    /// Whether everything that needs the file system is known: iCloud's
    /// Desktop and Documents, an external volume's read-only state (review
    /// P2-12) and the D54 locations reached through links (P1-1).
    var isRefined: Bool { pendingRefinementPaths.isEmpty && !awaitsProtectedLinkTargets }

    /// `isRefined: false` leaves iCloud (or the volume) to be asked;
    /// `awaitsProtectedLinkTargets: true` leaves the links to be found.
    init(
        rootPath: String,
        targetKind: StorageMapScanTarget.Kind,
        homePath: String,
        appDataPath: String,
        excludedPaths: [String],
        cloudSyncedFolders: [String] = [],
        isReadOnlyVolume: Bool = false,
        runningApplicationPaths: [String] = [],
        mountPointPaths: [String] = [],
        isRefined: Bool = true,
        protectedLinkTargets: [FileAnalysisProtectedLocation] = [],
        awaitsProtectedLinkTargets: Bool = false
    ) {
        self.rootPath = rootPath
        self.targetKind = targetKind
        self.homePath = Self.trimmed(homePath)
        self.appDataPath = Self.trimmed(appDataPath)
        foldedHomePath = Self.protectedName(self.homePath)
        foldedAppDataPath = Self.protectedName(self.appDataPath)
        canonicalHomePath = self.homePath.precomposedStringWithCanonicalMapping
        homeComponentCount = self.homePath.split(separator: "/").count
        self.excludedPaths = excludedPaths.map(Self.trimmed)
        self.cloudSyncedFolders = cloudSyncedFolders.map(Self.trimmed)
        self.isReadOnlyVolume = isReadOnlyVolume
        self.runningApplicationPaths = runningApplicationPaths.map(Self.trimmed)
        self.mountPointPaths = mountPointPaths.map(Self.trimmed)
        self.protectedLinkTargets = protectedLinkTargets
        self.awaitsProtectedLinkTargets = awaitsProtectedLinkTargets
        self.pendingRefinementPaths = isRefined ? [] : Set(targetKind == .externalVolume
            ? [rootPath] : ["Desktop", "Documents"].map { Self.trimmed(homePath) + "/" + $0 })
    }

    func block(for entry: StorageTreemapEntry) -> FileAnalysisTrashBlock? {
        guard entry.role == .content, !entry.path.isEmpty else { return .unreadable }
        return block(path: entry.path, name: entry.title, kind: entry.kind,
                     isDirectory: entry.isDirectory, isEstimated: entry.isEstimated,
                     isCloudOnly: entry.isCloudOnly)
    }

    /// Review P2-12: until iCloud's Desktop and Documents (or an external
    /// volume's read-only state) are known, items whose answer depends on
    /// them are still being checked; P1-1: until the D54 locations reached
    /// through links are known, every item is.
    func awaitsRefinement(of path: String) -> Bool {
        pendingCheck(for: path) != nil
    }

    /// What the item still waits for, if anything.
    func pendingCheck(for path: String) -> FileAnalysisTrashPendingCheck? {
        if awaitsProtectedLinkTargets { return .protectedLocations }
        guard !pendingRefinementPaths.isEmpty else { return nil }
        let folded = Self.protectedName(path)
        guard pendingRefinementPaths.contains(where: { Self.contains(folded, in: Self.protectedName($0)) }) else {
            return nil
        }
        return targetKind == .externalVolume ? .volume : .iCloud
    }

    func block(
        path: String, name: String, kind: String, isDirectory: Bool, isEstimated: Bool,
        isCloudOnly: Bool = false
    ) -> FileAnalysisTrashBlock? {
        if path == rootPath || !DiskScanner.storageMapPath(path, isWithinRoot: rootPath) { return .analysisRoot }
        // P2-4: the item's path is folded once; the lists were folded ahead.
        let folded = Self.protectedName(path)
        for location in protectedLinkTargets where Self.contains(folded, in: location.foldedPath) {
            if location.protectsContents || folded == location.foldedPath { return location.block }
        }
        if isDirectory, protectedLinkTargets.contains(where: { Self.contains($0.foldedPath, in: folded) }) {
            return .containsProtectedLocation
        }
        if let location = locationBlock(path: path, folded: folded, name: name, kind: kind, isDirectory: isDirectory) {
            return location
        }
        if protectedLinkTargetsUnknown { return .protectedLocationsUnknown }
        if failedRefinementPaths.contains(where: { Self.contains(folded, in: Self.protectedName($0)) }) {
            // P2-3: on an external volume it was the read-only state, not iCloud.
            return targetKind == .externalVolume ? .volumeStateUnknown : .cloudStateUnknown
        }
        if isReadOnlyVolume { return .readOnlyVolume }
        // D46：运行中的包自身始终不可选，即使探测结果把它记成普通文件夹。
        if isDirectory, runningApplicationPaths.contains(path) { return .applicationBundle }
        if isDirectory, Self.isApplicationBundle(name: name, kind: kind), !nonApplicationBundlePaths.contains(path) {
            return .applicationBundle
        }
        // D54 ③: a folder holding a running app, or another disk's mount point.
        if isDirectory, runningApplicationPaths.contains(where: { $0 != path && Self.contains($0, in: path) }) {
            return .containsRunningApplication
        }
        if isDirectory, !runningApplicationPathsKnown { return .runningApplicationStateUnknown }
        if isDirectory, mountPointPaths.contains(where: { $0 != path && Self.contains($0, in: path) }) {
            return .containsMountPoint
        }
        if kind == "alias" { return .symbolicLink }
        if kind == "excluded" || touchesExclusion(path) { return .excluded }
        if kind == "unavailable" { return .unreadable }
        if isCloudOnly { return .cloudOnly }
        if isEstimated { return .incompleteMeasurement }
        return nil
    }

    static func isApplicationBundle(name: String, kind: String) -> Bool {
        kind == "package" && (name as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    /// `folded` is `protectedName(path)`, folded once by `block()`.
    private func locationBlock(
        path: String, folded: String, name: String, kind: String, isDirectory: Bool
    ) -> FileAnalysisTrashBlock? {
        if targetKind == .externalVolume {
            let relative = path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1)
            let first = relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if first == ".Trashes" { return .trash }
            // The volume's own bookkeeping (Spotlight, file events, versions)
            // and Time Machine backups.
            if first.hasPrefix(".") || first == "Backups.backupdb" { return .systemLocation }
            return nil
        }
        // 可处理范围保留家目录的大小写；只有受保护名称忽略大小写，
        // 不能因此把区分大小写卷上的另一位用户纳入可处理范围。
        guard Self.contains(path.precomposedStringWithCanonicalMapping, in: canonicalHomePath) else {
            if path == "/Users" || (path.hasPrefix("/Users/") && !path.dropFirst(7).contains("/")) {
                return .homeFolder
            }
            if Self.contains(path, in: "/Applications") {
                if path == "/Applications" { return .systemLocation }
                return isDirectory && Self.isApplicationBundle(name: name, kind: kind)
                    ? .applicationBundle : .applicationsFolder
            }
            if Self.systemRoots.contains(where: { Self.contains(path, in: $0) }) || !path.hasPrefix("/Users/") {
                return .systemLocation
            }
            return .outsideHome
        }
        if folded == foldedHomePath { return .homeFolder }
        // Compare components, not character offsets: NFC and NFD spellings
        // have different lengths even when they denote the same name. Folding
        // keeps the components, so the folded path's parts line up with them.
        let parts = folded.split(separator: "/").dropFirst(homeComponentCount).map(String.init)
        let relative = parts.joined(separator: "/")
        if parts.count == 1, Self.foldedStandardFolderNames.contains(relative) { return .standardFolder }
        // This app's data (with Operation History) and every folder holding
        // it; D54: every identity's data folder.
        if Self.contains(folded, in: foldedAppDataPath) || Self.contains(foldedAppDataPath, in: folded) { return .appData }
        if Self.foldedAppDataRelativePaths.contains(where: { Self.contains(relative, in: $0) })
            || relative.hasPrefix(Self.foldedIntegrationDataPrefix) {
            return .appData
        }
        if Self.contains(relative, in: Self.foldedTrash) { return .trash }
        if Self.foldedCloudLocations.contains(where: { Self.contains(relative, in: $0) }) { return .cloudStorage }
        if cloudSyncedFolders.contains(where: { Self.contains(folded, in: Self.protectedName($0)) }) { return .cloudStorage }
        // D54 ①: keys and credentials, and system data in the Library, with
        // everything inside them.
        if Self.foldedCredentialPaths.contains(where: { Self.contains(relative, in: $0) }) { return .credentials }
        if parts.count >= 2, parts[0] == "library" {
            if Self.foldedProtectedLibraryFolderNames.contains(parts[1]) { return .systemData }
            if parts.count >= 3, Self.foldedSharedLibraryFolderNames.contains(parts[1]),
               Self.isFoldedAppleOwned(parts[2]) || Self.foldedProtectedSharedEntryNames.contains(parts[2]) {
                return .systemData
            }
            // D54 ②: not whole, though what is inside follows the rules.
            if isDirectory, parts.count == 2 { return .libraryFolder }
            if isDirectory, Self.foldedAppContainerFolderNames.contains(parts[1]),
               parts.count == 3 || (parts.count == 4 && parts[3] == "data") {
                return .appContainer
            }
        }
        // D54 ⑤: a folder holding any of these is not moved whole.
        if isDirectory, Self.foldedCredentialPaths.contains(where: { $0 != relative && Self.contains($0, in: relative) }) {
            return .containsProtectedLocation
        }
        return nil
    }

    /// Apple's own entries: `com.apple.…`, also as the group containers name
    /// them (`group.com.apple.…`, `<team>.groups.com.apple.…`).
    static func isAppleOwned(_ name: String) -> Bool {
        isFoldedAppleOwned(protectedName(name))
    }

    private static func isFoldedAppleOwned(_ folded: String) -> Bool {
        folded.hasPrefix("com.apple.") || folded.contains(".com.apple.")
    }

    /// Only protection rules fold case; indexed item identities and exact
    /// paths still use their original spelling. Accents are not stripped.
    static func protectedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: foldingLocale)
            .precomposedStringWithCanonicalMapping
    }

    static func protectedContains(_ path: String, in root: String) -> Bool {
        contains(protectedName(path), in: protectedName(root))
    }

    private static func folded(_ names: Set<String>) -> Set<String> {
        Set(names.map(protectedName))
    }

    /// The item is excluded, inside an exclusion, or holds one.
    private func touchesExclusion(_ path: String) -> Bool {
        excludedPaths.contains { Self.contains(path, in: $0) || Self.contains($0, in: path) }
    }

    /// The protected top-level system locations (shared with the duplicate
    /// finder's whole-computer scope).
    static var systemRoots: [String] { DuplicateFileScanner.protectedWholeComputerRoots }

    static func contains(_ path: String, in root: String) -> Bool {
        guard !root.isEmpty else { return false }
        if root == "/" { return true }
        return path == root || path.hasPrefix(root + "/")
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

struct FileAnalysisProtectedLocation: Equatable, Sendable {
    let path: String
    let block: FileAnalysisTrashBlock
    /// Whole protected stores include descendants; Library/container roots
    /// only block moving the root, preserving D54's inside-content rules.
    let protectsContents: Bool
    /// `path` folded once (r2-fa-followups P2-4).
    let foldedPath: String

    init(path: String, block: FileAnalysisTrashBlock, protectsContents: Bool) {
        self.path = path
        self.block = block
        self.protectsContents = protectsContents
        foldedPath = FileAnalysisTrashPolicy.protectedName(path)
    }
}

/// What reading the file system adds to an analysis's rules
/// (r2-fa-followups P1-1), found off the main thread when it ends.
struct FileAnalysisTrashProtection: Equatable, Sendable {
    /// D54 locations reached through symbolic links in the home folder.
    var linkTargets: [FileAnalysisProtectedLocation]
    /// P2-1: packages named `….app` a row can show that are not apps.
    var nonApplicationBundlePaths: Set<String> = []
}

/// One item the user checked in File Analysis (D46).
struct FileAnalysisTrashSelection: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let title: String
    let isDirectory: Bool
    let kind: String
    /// The size the page shows for it, which leaves the folders above it.
    let bytes: Int64
    /// For a folder, the items inside it.
    let itemCount: Int?
    /// Main-session ruling on r2-fa-followups P2-1: a folder named ….app
    /// that is not an app is shown as a folder in the review.
    var presentsAsFolder = false
}

/// How a row offers its checkbox.
enum FileAnalysisTrashSelectionState: Equatable, Sendable {
    case available
    case selected
    /// Inside a checked folder (whose title it carries): it moves with it.
    case includedInSelection(String)
    /// What stops it; for `runningApplicationStateUnknown`, the apps whose
    /// original location is unknown (r2-fa-followups P2-2).
    case blocked(FileAnalysisTrashBlock, applications: [String] = [])
    /// Review P2-12, r2-fa-followups P1-1: what decides whether the item can
    /// move is not known yet; it cannot be checked until it is.
    case checking(FileAnalysisTrashPendingCheck)
}

/// What a "checking" item waits for.
enum FileAnalysisTrashPendingCheck: Equatable, Sendable {
    /// Review P2-12: whether iCloud keeps Desktop and Documents.
    case iCloud
    /// Review P2-12: whether the external volume is read-only.
    case volume
    /// r2-fa-followups P1-1: the D54 locations reached through links in the
    /// home folder.
    case protectedLocations
}

/// One item of the review sheet: ready to move, or what stops it.
struct FileAnalysisTrashReviewItem: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case ready(FileIdentity)
        case blocked(FileAnalysisTrashBlock)
    }

    var id: String { selection.path }
    let selection: FileAnalysisTrashSelection
    let status: Status
    /// The external volume the item is on, if any (its Trash is there).
    let externalVolumeName: String?
    /// D54 ④: a file with other hard links; its space may stay in use.
    var hasOtherHardLinks = false

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }
}

struct FileAnalysisTrashReview: Equatable, Sendable {
    let items: [FileAnalysisTrashReviewItem]
    /// r2-fa-followups P2-2: named in the reason of a folder that cannot
    /// move whole while their original location is unknown.
    var unknownRunningApplicationNames: [String] = []

    var readyItems: [FileAnalysisTrashReviewItem] { items.filter(\.isReady) }
    var readyBytes: Int64 { readyItems.reduce(0) { $0 + max(0, $1.selection.bytes) } }
    var blockedCount: Int { items.count - readyItems.count }
    var externalVolumeNames: [String] {
        var seen = Set<String>()
        return readyItems.compactMap(\.externalVolumeName).filter { seen.insert($0).inserted }
    }
}

/// What a move to the Trash did, for the page's result line (D46).
struct FileAnalysisTrashOutcome: Equatable, Sendable {
    struct Skipped: Identifiable, Equatable, Sendable {
        var id: String { path }
        let path: String
        let title: String
        let reason: String
    }

    let report: CleanReport?
    let movedPaths: [String]
    let movedBytes: Int64
    let skipped: [Skipped]
    /// Moved items whose receipt cannot restore them from Operation History
    /// (an external volume's Trash, or a move whose result needs checking).
    let notRestorableHereCount: Int
    let externalVolumeNames: [String]
    /// The intent could not be written, so nothing moved.
    let receiptUnavailable: Bool
    let cancelled: Bool
    /// Review P2-2: a later receipt write failed; the run stopped and the
    /// receipt may be behind what moved.
    var receiptIncomplete = false
    /// D93 P1-2: reviewed files that had other hard links; moving them may
    /// free no space, so emptying the Trash frees at most their size.
    var otherHardLinkPaths: Set<String> = []
}

/// Progress of a move for the review sheet.
struct FileAnalysisTrashProgress: Equatable, Sendable {
    var processed: Int
    var total: Int
    /// The folder being compared with the analysis, and items read so far.
    var verifyingTitle: String?
    var verifiedItemCount: Int = 0
}
