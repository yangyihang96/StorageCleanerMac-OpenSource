import Foundation

enum SmartMaintenancePriority: Int, Comparable, Sendable {
    case urgent = 0
    case recommended = 1
    case routine = 2
    case complete = 3

    static func < (lhs: SmartMaintenancePriority, rhs: SmartMaintenancePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .urgent:
            L10n.text("优先", "Priority")
        case .recommended:
            L10n.text("建议", "Recommended")
        case .routine:
            L10n.text("检查", "Check")
        case .complete:
            L10n.text("完成", "Done")
        }
    }
}

enum SmartMaintenanceAction: Equatable, Sendable {
    case cleanGreen
    case openPermissions
    case review(ReviewFilter)
    case scanAppUpdates
    case scanStartupItems
    case refreshMemory
    case optimizeMemory
    case scanDuplicates
    case exportReport

    var canStartFromOverview: Bool {
        switch self {
        case .cleanGreen, .scanAppUpdates, .scanStartupItems, .refreshMemory, .optimizeMemory, .scanDuplicates, .exportReport:
            true
        case .openPermissions, .review:
            false
        }
    }

    var needsHumanReview: Bool {
        !canStartFromOverview
    }
}

struct SmartMaintenanceTask: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let value: String
    let systemImage: String
    let priority: SmartMaintenancePriority
    let action: SmartMaintenanceAction
}

struct SmartMaintenancePlan: Equatable, Sendable {
    let tasks: [SmartMaintenanceTask]
    let quickStartTasks: [SmartMaintenanceTask]
    let reviewTasks: [SmartMaintenanceTask]
    let safeCleanupBytes: Int64

    var primaryTask: SmartMaintenanceTask? {
        if let first = tasks.first, first.priority == .urgent {
            return first
        }
        return quickStartTasks.first ?? tasks.first
    }

    var firstReviewTask: SmartMaintenanceTask? {
        reviewTasks.first
    }

    var opportunityBytes: Int64 {
        safeCleanupBytes
    }

    var statusPriority: SmartMaintenancePriority {
        tasks.map(\.priority).min() ?? .complete
    }

    var statusTitle: String {
        switch statusPriority {
        case .urgent:
            L10n.text("需要优先处理", "Needs Priority")
        case .recommended:
            L10n.text("建议维护", "Recommended")
        case .routine:
            L10n.text("可补充检查", "Routine Checks")
        case .complete:
            L10n.text("状态良好", "All Clear")
        }
    }

    var headline: String {
        if tasks.contains(where: { $0.id == "permissions" }) {
            return L10n.text("先补权限，再做维护", "Grant access before maintenance")
        }
        if safeCleanupBytes > 0 {
            return L10n.text("可先处理安全缓存", "Start with safe cache")
        }
        if !reviewTasks.isEmpty {
            return L10n.text("需要人工确认后处理", "Review before changing anything")
        }
        if !quickStartTasks.isEmpty {
            return L10n.text("可以继续补充检测", "Continue with extra checks")
        }
        return L10n.text("当前状态良好", "Current state is healthy")
    }

    var detail: String {
        if tasks.isEmpty {
            return L10n.text("没有需要处理的维护项。", "There are no maintenance items to handle.")
        }

        let opportunity = opportunityBytes > 0
            ? ByteFormat.string(opportunityBytes)
            : L10n.text("无明显空间收益", "no obvious space gain")

        return L10n.text(
            "可从总览直接推进 \(quickStartTasks.count) 项，另有 \(reviewTasks.count) 项需要你确认；预计安全收益 \(opportunity)。",
            "\(quickStartTasks.count) items can start from Overview, \(reviewTasks.count) need your review; estimated safe gain is \(opportunity)."
        )
    }
}
