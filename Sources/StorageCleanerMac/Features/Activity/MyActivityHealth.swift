import Foundation

/// D187: a conservative summary of existing evidence, never a new health probe.
/// The strongest finding wins; several attention findings do not invent a fault.
struct MyActivityHealth: Equatable, Sendable {
    enum Grade: Int, Equatable, Sendable {
        case good, attention, problem

        var title: String {
            switch self {
            case .good: L10n.text("良好", "Good")
            case .attention: L10n.text("需要注意", "Needs Attention")
            case .problem: L10n.text("有问题", "Problems Found")
            }
        }
    }

    enum Reason: Equatable, Sendable {
        case diskFailure, diskWarning, lowSpace, criticalSpace, capacityWarning, backup, stability, severeStability, batteryService, batteryWarning
        case protectionDisabled(SystemProtectionCheck)
        case incomplete, stale

        var grade: Grade {
            switch self {
            case .diskFailure, .criticalSpace, .batteryService, .severeStability: .problem
            case .protectionDisabled(let check):
                [.systemIntegrityProtection, .gatekeeper].contains(check) ? .problem : .attention
            default: .attention
            }
        }

        var text: String {
            switch self {
            case .diskFailure: L10n.text("磁盘检查报告硬件故障或需要处理。", "The disk check reports a hardware failure or required action.")
            case .diskWarning: L10n.text("磁盘检查有需要注意的项目。", "The disk check has findings to review.")
            case .lowSpace: L10n.text("启动磁盘可用空间低于 10%。", "Startup disk free space is below 10%.")
            case .criticalSpace: L10n.text("启动磁盘可用空间低于 5%。", "Startup disk free space is below 5%.")
            case .capacityWarning: L10n.text("容量趋势检查有需要注意的项目。", "The capacity trend check has findings to review.")
            case .backup: L10n.text("Time Machine 尚未配置，或备份检查需要注意。", "Time Machine is not configured or its check needs attention.")
            case .stability: L10n.text("检查窗口内至少有 5 次崩溃或卡住，或系统稳定性检查有警告。", "The check window contains at least 5 crashes or hangs, or a stability warning.")
            case .severeStability: L10n.text("检查窗口内出现内核崩溃、意外重启、至少 10 次崩溃或卡住，或稳定性检查要求处理。", "The check window reports a kernel panic, unexpected restart, at least 10 crashes or hangs, or required stability action.")
            case .batteryService: L10n.text("电池检查建议维修。", "The battery check recommends service.")
            case .batteryWarning: L10n.text("电池检查有需要注意的项目。", "The battery check has findings to review.")
            case .protectionDisabled(let check): L10n.text("\(check.title)已关闭。", "\(check.title) is off.")
            case .incomplete: L10n.text("部分检查数据缺失或无法读取，尚不能确认良好。", "Some checks are missing or unreadable; a good result cannot be confirmed.")
            case .stale: L10n.text("最近一次检查已超过 7 天，建议重新检查。", "The latest check is over 7 days old; check again.")
            }
        }
    }

    let grade: Grade?
    let reasons: [Reason]
    let checkedAt: Date?

    static var title: String { L10n.text("Mac 健康度", "Mac Health") }
    var statusText: String { grade?.title ?? L10n.text("还没检查过", "Not Checked Yet") }
    var helpText: String {
        if grade == nil { return L10n.text("还没有可用的健康检查快照。", "No health check snapshot is available yet.") }
        if reasons.isEmpty { return L10n.text("最近一次检查的磁盘、容量、备份、稳定性、电池和系统防护未报告这些风险。", "The latest disk, capacity, backup, stability, battery and protection checks reported none of these risks.") }
        return reasons.map(\.text).joined(separator: "\n")
    }

    static func evaluate(_ snapshot: ComputerHealthSnapshot?, now: Date) -> Self {
        guard let snapshot else { return Self(grade: nil, reasons: [], checkedAt: nil) }
        var reasons: [Reason] = []
        var severity = Grade.good
        var incomplete = false
        func add(_ reason: Reason, grade: Grade? = nil) {
            if !reasons.contains(reason) { reasons.append(reason) }
            let proposed = grade ?? reason.grade
            if proposed.rawValue > severity.rawValue { severity = proposed }
        }
        let disk = snapshot.disk
        if disk.availability.hasUsableData {
            if disk.smartStatus == .failing || disk.status == .actionRequired { add(.diskFailure) }
            else if disk.status == .attention { add(.diskWarning) }
        }
        incomplete = disk.availability != .available

        let capacity = snapshot.capacity
        if capacity.availability.hasUsableData,
           let total = capacity.totalBytes, total > 0,
           let free = capacity.availableBytes, (0...total).contains(free) {
            let ratio = Double(free) / Double(total)
            if ratio < 0.05 { add(.criticalSpace) }
            else if ratio < 0.10 { add(.lowSpace) }
            else if capacity.status == .attention || capacity.status == .actionRequired { add(.capacityWarning) }
        } else { incomplete = true }
        incomplete = incomplete || capacity.availability != .available

        let backup = snapshot.backup
        if backup.availability.hasUsableData {
            if backup.destinationState == .unconfigured || backup.destinationState == .unreachable
                || backup.status == .attention || backup.status == .actionRequired { add(.backup) }
        }
        incomplete = incomplete || backup.availability != .available

        let stability = snapshot.stability
        if stability.availability.hasUsableData {
            let crashes = max(0, stability.crashCount ?? 0)
            let hangs = max(0, stability.hangCount ?? 0)
            let many = crashes >= 5 || hangs >= max(0, 5 - crashes)
            let severe = crashes >= 10 || hangs >= max(0, 10 - crashes)
                || (stability.panicCount ?? 0) > 0 || (stability.unexpectedRestartCount ?? 0) > 0
                || stability.status == .actionRequired
            if severe { add(.severeStability) }
            else if many || stability.status == .attention { add(.stability) }
            incomplete = incomplete || stability.crashCount == nil || stability.hangCount == nil
        }
        incomplete = incomplete || stability.availability != .available

        switch snapshot.batteryEvidence {
        case .notPresent: break // A desktop is not a failed battery check.
        case .failed: incomplete = true
        case .present(let battery):
            if battery.availability.hasUsableData {
                if battery.condition == .serviceRecommended || battery.status == .actionRequired { add(.batteryService) }
                else if battery.status == .attention { add(.batteryWarning) }
            }
            incomplete = incomplete || battery.availability != .available
        }

        for check in SystemProtectionCheck.healthChecks {
            guard let finding = snapshot.security?.findings.first(where: { $0.check == check }) else {
                incomplete = true
                continue
            }
            if finding.state == .disabled { add(.protectionDisabled(check)) }
            else if finding.state != .enabled { incomplete = true }
        }
        if incomplete { add(.incomplete) }
        let age = now.timeIntervalSince(snapshot.generatedAt)
        if !age.isFinite || age < 0 || age > 7 * 86_400 { add(.stale) }
        return Self(grade: severity, reasons: reasons, checkedAt: snapshot.generatedAt)
    }

    static func latest(_ first: ComputerHealthSnapshot?, _ second: ComputerHealthSnapshot?) -> ComputerHealthSnapshot? {
        [first, second].compactMap { $0 }.max { $0.generatedAt < $1.generatedAt }
    }
}
