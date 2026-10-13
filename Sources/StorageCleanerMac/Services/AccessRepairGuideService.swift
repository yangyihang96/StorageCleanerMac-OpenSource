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
    // D6 still reads this field; remove it with AccessRepairStepRow's icon.
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
                detail: "",
                systemImage: "folder"
            ),
            AccessRepairStep(
                id: .grantAccess,
                title: L10n.text("允许关键位置", "Allow Key Locations"),
                detail: L10n.text("媒体资料库默认不读取。", "Media libraries are not read by default."),
                systemImage: "checkmark.shield.fill"
            ),
            AccessRepairStep(
                id: .rescan,
                title: L10n.text("重新扫描验证", "Rescan To Verify"),
                detail: "",
                systemImage: "arrow.clockwise"
            )
        ]
    }
}
