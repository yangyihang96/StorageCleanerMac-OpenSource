import Foundation

enum MaintenanceReminderCadence: String, CaseIterable, Identifiable, Sendable {
    case off
    case daily
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            L10n.text("关闭", "Off")
        case .daily:
            L10n.text("每日", "Daily")
        case .weekly:
            L10n.text("每周", "Weekly")
        case .monthly:
            L10n.text("每月", "Monthly")
        }
    }

    var detail: String {
        switch self {
        case .off:
            L10n.text("只在结果明显过期时提示。", "Only prompt when results are clearly stale.")
        case .daily:
            L10n.text("适合频繁下载、安装和开发测试。", "Best for frequent downloads, installs, and dev work.")
        case .weekly:
            L10n.text("适合大多数日常使用。", "Good for most everyday use.")
        case .monthly:
            L10n.text("适合空间稳定、少安装软件的设备。", "Best for stable devices with few installs.")
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off:
            nil
        case .daily:
            24 * 60 * 60
        case .weekly:
            7 * 24 * 60 * 60
        case .monthly:
            30 * 24 * 60 * 60
        }
    }
}

enum MaintenanceReminderStatus: Equatable, Sendable {
    case disabled
    case waitingForFirstScan
    case due
    case scheduled
}

struct MaintenanceReminderSummary: Equatable, Sendable {
    let cadence: MaintenanceReminderCadence
    let status: MaintenanceReminderStatus
    let lastScanAt: Date?
    let nextDueAt: Date?
    let referenceDate: Date

    var isDue: Bool {
        status == .due || status == .waitingForFirstScan
    }

    var statusTitle: String {
        switch status {
        case .disabled:
            L10n.text("已关闭", "Off")
        case .waitingForFirstScan:
            L10n.text("等待首次扫描", "First scan needed")
        case .due:
            L10n.text("建议重新扫描", "Rescan recommended")
        case .scheduled:
            L10n.text("未到期", "Not due")
        }
    }

    var statusDetail: String {
        switch status {
        case .disabled:
            L10n.text("菜单栏会回到基础过期判断，不按固定频率提醒。", "The menu bar falls back to basic stale-result prompts.")
        case .waitingForFirstScan:
            L10n.text("完成一次扫描后，系统会按所选频率给出下一次建议。", "After the first scan, the next recommendation follows the selected cadence.")
        case .due:
            L10n.text("距离上次扫描已经超过设定频率，建议重新扫描后再清理。", "The selected cadence has elapsed; rescan before cleaning.")
        case .scheduled:
            if let nextDueAt {
                L10n.text(
                    "下次建议扫描：\(nextDueAt.formatted(date: .abbreviated, time: .shortened))。",
                    "Next suggested scan: \(nextDueAt.formatted(date: .abbreviated, time: .shortened))."
                )
            } else {
                cadence.detail
            }
        }
    }
}

enum MaintenanceReminderService {
    static let defaultsKey = "maintenance.reminder.cadence"
    static let defaultCadence: MaintenanceReminderCadence = .weekly

    static func cadence(from rawValue: String) -> MaintenanceReminderCadence {
        MaintenanceReminderCadence(rawValue: rawValue) ?? defaultCadence
    }

    static func summary(
        cadence: MaintenanceReminderCadence,
        lastScanAt: Date?,
        referenceDate: Date = Date()
    ) -> MaintenanceReminderSummary {
        guard cadence != .off else {
            return MaintenanceReminderSummary(
                cadence: cadence,
                status: .disabled,
                lastScanAt: lastScanAt,
                nextDueAt: nil,
                referenceDate: referenceDate
            )
        }

        guard let interval = cadence.interval else {
            return MaintenanceReminderSummary(
                cadence: cadence,
                status: .disabled,
                lastScanAt: lastScanAt,
                nextDueAt: nil,
                referenceDate: referenceDate
            )
        }

        guard let lastScanAt else {
            return MaintenanceReminderSummary(
                cadence: cadence,
                status: .waitingForFirstScan,
                lastScanAt: nil,
                nextDueAt: nil,
                referenceDate: referenceDate
            )
        }

        let nextDueAt = lastScanAt.addingTimeInterval(interval)
        return MaintenanceReminderSummary(
            cadence: cadence,
            status: nextDueAt <= referenceDate ? .due : .scheduled,
            lastScanAt: lastScanAt,
            nextDueAt: nextDueAt,
            referenceDate: referenceDate
        )
    }
}
