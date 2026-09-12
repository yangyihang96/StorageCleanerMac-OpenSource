import Foundation

enum AccessRepairStepKind: String, Equatable, Sendable {
    case openSettings
    case grantAccess
    case rescan
}

struct AccessRepairStep: Identifiable, Equatable, Sendable {
    let id: AccessRepairStepKind
    let title: String
    let detail: String
    let systemImage: String
}

enum AccessRepairGuideService {
    static func shouldRefreshCurrentReadinessBeforeScan(
        latestStatus: LastScanStatusSummary?
    ) -> Bool {
        return latestStatus?.recommendedAction == .repairAccess
    }

    static func shouldPromptBeforeScan(
        latestStatus: LastScanStatusSummary?,
        currentReadiness: ScanReadinessSummary?
    ) -> Bool {
        guard latestStatus?.recommendedAction == .repairAccess else { return false }
        return currentReadiness?.level == .needsPermission
    }

    static func steps() -> [AccessRepairStep] {
        [
            AccessRepairStep(
                id: .openSettings,
                title: L10n.text("打开权限设置", "Open Access Settings"),
                detail: L10n.text(
                    "优先打开“文件与文件夹”，必要时再打开“完整磁盘访问”。",
                    "Start with Files & Folders, then use Full Disk Access if needed."
                ),
                systemImage: "folder"
            ),
            AccessRepairStep(
                id: .grantAccess,
                title: L10n.text("允许关键位置", "Allow Key Locations"),
                detail: L10n.text(
                    "给存储清理助手允许下载、桌面、文稿和 iCloud Drive 等位置；媒体资料库默认不主动读取。",
                    "Allow Storage Cleaner to read Downloads, Desktop, Documents, iCloud Drive, and similar locations; media libraries are not read by default."
                ),
                systemImage: "checkmark.shield.fill"
            ),
            AccessRepairStep(
                id: .rescan,
                title: L10n.text("重新扫描验证", "Rescan To Verify"),
                detail: L10n.text(
                    "授权后回到软件重新扫描，评分和排行才会更新。",
                    "Return and rescan after granting access so the score and rankings update."
                ),
                systemImage: "arrow.clockwise"
            )
        ]
    }
}
