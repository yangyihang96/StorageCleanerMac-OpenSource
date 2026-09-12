import Foundation

enum ScanReadinessLevel: Equatable, Sendable {
    case ready
    case needsPermission
}

enum ScanReadinessStatus: Equatable, Sendable {
    case readable
    case needsPermission
    case missing
}

enum FullDiskAccessState: Equatable, Sendable {
    case unknown
    case verified
    case notVerified
}

struct ScanReadinessLocation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let path: String
    let systemImage: String
    let isHighImpact: Bool

    init(
        title: String,
        path: String,
        systemImage: String,
        isHighImpact: Bool = true
    ) {
        let normalizedPath = PathSafety.normalizedPath(path)
        self.id = normalizedPath
        self.title = title
        self.path = normalizedPath
        self.systemImage = systemImage
        self.isHighImpact = isHighImpact
    }
}

struct ScanReadinessItem: Identifiable, Equatable, Sendable {
    let location: ScanReadinessLocation
    let status: ScanReadinessStatus

    var id: String {
        location.id
    }
}

struct ScanReadinessSummary: Equatable, Sendable {
    let items: [ScanReadinessItem]
    let fullDiskAccessState: FullDiskAccessState

    init(
        items: [ScanReadinessItem],
        fullDiskAccessState: FullDiskAccessState = .unknown
    ) {
        self.items = items
        self.fullDiskAccessState = fullDiskAccessState
    }

    var checkedItems: [ScanReadinessItem] {
        items.filter { $0.status != .missing }
    }

    var readableCount: Int {
        checkedItems.filter { $0.status == .readable }.count
    }

    var blockedItems: [ScanReadinessItem] {
        checkedItems.filter { $0.status == .needsPermission }
    }

    var blockedCount: Int {
        blockedItems.count
    }

    var highImpactBlockedCount: Int {
        blockedItems.filter(\.location.isHighImpact).count
    }

    var missingCount: Int {
        items.filter { $0.status == .missing }.count
    }

    var level: ScanReadinessLevel {
        blockedCount == 0 ? .ready : .needsPermission
    }

    var isFullDiskAccessVerified: Bool {
        fullDiskAccessState == .verified
    }

    var folderAuthorizationRequiredCount: Int {
        isFullDiskAccessVerified ? 0 : blockedCount
    }

    var estimatedCoveragePercent: Int {
        guard !checkedItems.isEmpty else { return 100 }
        if isFullDiskAccessVerified {
            return max(90, 100 - blockedCount * 3)
        }
        return max(55, 100 - blockedCount * 10 - highImpactBlockedCount * 5)
    }
}

struct ScanReadinessDisplayText: Equatable, Sendable {
    let title: String
    let detail: String
    let actionTitle: String
    let actionSystemImage: String
}

enum ScanReadinessService {
    static func defaultLocations(homePath: String = PathSafety.homePath) -> [ScanReadinessLocation] {
        [
            ScanReadinessLocation(
                title: L10n.text("下载", "Downloads"),
                path: "\(homePath)/Downloads",
                systemImage: "arrow.down.circle.fill"
            ),
            ScanReadinessLocation(
                title: L10n.text("桌面", "Desktop"),
                path: "\(homePath)/Desktop",
                systemImage: "menubar.rectangle"
            ),
            ScanReadinessLocation(
                title: L10n.text("文稿", "Documents"),
                path: "\(homePath)/Documents",
                systemImage: "doc.text.fill"
            ),
            ScanReadinessLocation(
                title: "iCloud Drive",
                path: "\(homePath)/Library/Mobile Documents/com~apple~CloudDocs",
                systemImage: "icloud.fill"
            )
        ]
    }

    static func summary(
        locations: [ScanReadinessLocation] = defaultLocations(),
        fileExists: (String) -> Bool = pathExists,
        canReadDirectory: (String) -> Bool = canReadDirectory,
        restoreSavedAccess: () -> Void = {
            _ = FolderAccessGrantService.restoreSavedAccess()
        },
        detectFullDiskAccess: () -> FullDiskAccessState = {
            fullDiskAccessState()
        }
    ) -> ScanReadinessSummary {
        restoreSavedAccess()
        let fullDiskAccessState = detectFullDiskAccess()

        let items = locations.map { location in
            ScanReadinessItem(
                location: location,
                status: status(for: location.path, fileExists: fileExists, canReadDirectory: canReadDirectory)
            )
        }
        return ScanReadinessSummary(items: items, fullDiskAccessState: fullDiskAccessState)
    }

    static func summary(
        fromScanDeniedPaths deniedPaths: [String],
        locations: [ScanReadinessLocation] = defaultLocations(),
        fullDiskAccessState: FullDiskAccessState = .unknown
    ) -> ScanReadinessSummary {
        let normalizedDeniedPaths = deniedPaths.map(PathSafety.normalizedPath)
        let items = locations.map { location in
            let isDenied = normalizedDeniedPaths.contains { deniedPath in
                deniedPath == location.path || deniedPath.hasPrefix(location.path + "/")
            }
            return ScanReadinessItem(
                location: location,
                status: isDenied ? .needsPermission : .readable
            )
        }
        return ScanReadinessSummary(items: items, fullDiskAccessState: fullDiskAccessState)
    }

    static func displayText(
        summary: ScanReadinessSummary?,
        lastDeniedCount: Int?,
        isChecking: Bool
    ) -> ScanReadinessDisplayText {
        if isChecking {
            return ScanReadinessDisplayText(
                title: L10n.text("当前权限检查中", "Checking Current Access"),
                detail: L10n.text("正在读取当前关键位置", "Reading current key locations"),
                actionTitle: L10n.text("检查中", "Checking"),
                actionSystemImage: "arrow.clockwise"
            )
        }

        guard let summary else {
            let deniedCount = lastDeniedCount ?? 0
            let detail = deniedCount > 0
                ? L10n.text(
                    "上次扫描 \(deniedCount) 处受限，点击检查当前状态",
                    "Last scan had \(deniedCount) access gaps; check current status"
                )
                : L10n.text("点击检查当前关键位置", "Check current key locations")

            return ScanReadinessDisplayText(
                title: L10n.text("当前权限未检查", "Current Access Not Checked"),
                detail: detail,
                actionTitle: L10n.text("检查当前", "Check Current"),
                actionSystemImage: "arrow.clockwise"
            )
        }

        if summary.isFullDiskAccessVerified {
            if summary.level == .ready {
                return ScanReadinessDisplayText(
                    title: L10n.text("完整磁盘访问已生效", "Full Disk Access Active"),
                    detail: L10n.text("关键位置已可读，无需再重复授权文件夹。", "Key locations are readable; no duplicate folder authorization is needed."),
                    actionTitle: L10n.text("检查当前", "Check Current"),
                    actionSystemImage: "checklist"
                )
            }

            return ScanReadinessDisplayText(
                title: L10n.text("完整磁盘访问已生效", "Full Disk Access Active"),
                detail: L10n.text(
                    "\(summary.blockedCount) 个位置仍未读取，通常重启本应用或重新检查即可，不需要重复授权文件夹。",
                    "\(summary.blockedCount) location(s) still did not read; restart or check again instead of granting duplicate folder access."
                ),
                actionTitle: L10n.text("检查当前", "Check Current"),
                actionSystemImage: "checklist"
            )
        }

        if summary.level == .ready {
            return ScanReadinessDisplayText(
                title: L10n.text("当前权限完整", "Current Access Ready"),
                detail: L10n.text("当前关键位置可读", "Current key locations are readable"),
                actionTitle: L10n.text("检查当前", "Check Current"),
                actionSystemImage: "arrow.clockwise"
            )
        }

        return ScanReadinessDisplayText(
            title: L10n.text("当前权限受限", "Current Access Limited"),
            detail: L10n.text(
                "当前 \(summary.blockedCount) 处未读取；若已开启完整磁盘访问，请重启本应用后检查。",
                "\(summary.blockedCount) location(s) did not read; if Full Disk Access is already enabled, restart the app and check again."
            ),
            actionTitle: L10n.text("检查当前", "Check Current"),
            actionSystemImage: "checklist"
        )
    }

    static func defaultFullDiskAccessProbePaths(homePath: String = PathSafety.homePath) -> [String] {
        [
            "\(homePath)/Library/Safari",
            "\(homePath)/Library/Mail",
            "\(homePath)/Library/Messages"
        ]
    }

    static func fullDiskAccessState(
        probePaths: [String] = defaultFullDiskAccessProbePaths(),
        fileExists: (String) -> Bool = pathExists,
        canReadDirectory: (String) -> Bool = canReadDirectory
    ) -> FullDiskAccessState {
        let existingProbePaths = probePaths.map(PathSafety.normalizedPath).filter(fileExists)
        guard !existingProbePaths.isEmpty else { return .unknown }
        return existingProbePaths.contains(where: canReadDirectory) ? .verified : .notVerified
    }

    private static func status(
        for path: String,
        fileExists: (String) -> Bool,
        canReadDirectory: (String) -> Bool
    ) -> ScanReadinessStatus {
        guard fileExists(path) else { return .missing }
        return canReadDirectory(path) ? .readable : .needsPermission
    }

    private static func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func canReadDirectory(_ path: String) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return true
        } catch {
            return false
        }
    }
}
