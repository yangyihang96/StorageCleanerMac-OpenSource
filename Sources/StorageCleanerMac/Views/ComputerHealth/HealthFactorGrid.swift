import SwiftUI

struct HealthFactorGrid: View {
    let evaluation: ComputerHealthEvaluation?
    var snapshot: ComputerHealthSnapshot? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ComputerHealthScoring.scoredFactors.enumerated()), id: \.element) { index, factor in
                factorRow(factor).lightfieldRowEntrance(index)
            }
        }
    }

    private func factorRow(_ factor: HealthFactor) -> some View {
        let component = component(for: factor)
        let availability = component?.availability ?? .unavailable
        let measuredStatus = Self.lightfieldStatus(factor: factor, component: component, smart: snapshot?.disk.smartStatus)
        let status: FeatureLightfieldStatus = factor == .battery && snapshot?.battery?.condition == .serviceRecommended
            ? .warning : measuredStatus
        // D67 status row: the status symbol owns the 20 pt first column, the
        // short semantic status the last column, and the evidence (availability,
        // score, source note, time) stays in collapsed tertiary details behind
        // the row-end disclosure.
        return FeatureLightfieldStatusDisclosure(title: HealthDashboardVisuals.factorTitle(factor),
            detail: primaryValue(for: factor), value: statusText(for: factor, status: status), status: status,
            leadingProbe: "lightfield.health.leading.\(factor.rawValue)",
            disclosureProbe: "lightfield.health.disclosure.\(factor.rawValue)") {
            VStack(alignment: .leading, spacing: 6) {
                Text(HealthDashboardVisuals.availabilityText(availability) + " · " + scoreText(component))
                Text(detail(for: factor))
                if let checkedAt = component?.evaluatedAt {
                    Text(checkedAt.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                }
            }
        }
    }

    private func statusText(for factor: HealthFactor, status: FeatureLightfieldStatus) -> String {
        if factor == .diskReliability && snapshot?.disk.smartStatus == .failing {
            return L10n.text("故障警告", "Failure")
        }
        if factor == .battery && snapshot?.battery?.condition == .serviceRecommended {
            return L10n.text("需检修", "Service")
        }
        switch status {
        case .normal: return L10n.text("正常", "Normal")
        case .warning: return L10n.text("需关注", "Attention")
        case .failure: return L10n.text("异常", "Problem")
        case .unknown: return L10n.text("未取得", "Unknown")
        }
    }

    static func lightfieldStatus(factor: HealthFactor, component: HealthComponentEvaluation?, smart: DiskSMARTStatus?) -> FeatureLightfieldStatus {
        if factor == .diskReliability && smart == .failing { return .warning }
        guard let component, component.availability == .available || component.availability == .partial,
              let score = component.score, score.isFinite else { return .unknown }
        if score < 60 { return .failure }
        if score < 85 || component.availability == .partial { return .warning }
        return .normal
    }

    private func primaryValue(for factor: HealthFactor) -> String {
        guard let snapshot else {
            return L10n.text("查看实测证据", "Review Measured Evidence")
        }
        switch factor {
        case .diskReliability:
            if let remainingLife = snapshot.disk.remainingLifePercent {
                return L10n.text("介质寿命估算 \(remainingLife)%", "Media Life Estimate \(remainingLife)%")
            }
            switch snapshot.disk.smartStatus {
            case .verified: return L10n.text("SMART 当前已验证", "SMART Currently Verified")
            case .failing: return L10n.text("SMART 报告故障", "SMART Reports a Failure")
            case .unsupported: return L10n.text("此介质不支持 SMART", "SMART Is Unsupported")
            case .unavailable: return L10n.text("SMART 暂不可用", "SMART Is Unavailable")
            }
        case .capacity:
            guard let available = snapshot.capacity.availableForImportantUsageBytes else {
                return L10n.text("可用空间未读取", "Available Space Not Read")
            }
            return L10n.text(
                "\(ByteFormat.string(available)) 可用",
                "\(ByteFormat.string(available)) Available"
            )
        case .stability:
            let serious = (snapshot.stability.panicCount ?? 0)
                + (snapshot.stability.unexpectedRestartCount ?? 0)
            return serious == 0
                ? L10n.text("未发现严重系统事件", "No Serious System Events Found")
                : L10n.text("\(serious) 项严重系统事件", "\(serious) Serious System Events")
        case .battery:
            switch snapshot.batteryEvidence {
            case .notPresent:
                return L10n.text("此 Mac 没有内置电池", "No Internal Battery")
            case .failed:
                return L10n.text("电池寿命暂不可用", "Battery Lifespan Unavailable")
            case .present(let battery):
                guard let capacity = battery.maximumCapacityPercent else {
                    return L10n.text("最大容量未读取", "Maximum Capacity Not Read")
                }
                return L10n.text("最大容量 \(capacity)%", "Maximum Capacity \(capacity)%")
            }
        case .backup:
            return L10n.text("独立保护检查", "Separate Protection Check")
        }
    }

    private func detail(for factor: HealthFactor) -> String {
        guard let snapshot else {
            return L10n.text("完成检查后显示来源明确的原始值。", "Run a check to show source-backed raw values.")
        }
        switch factor {
        case .diskReliability:
            if snapshot.disk.remainingLifePercent != nil {
                return L10n.text(
                    "寿命估算来自 NVMe 已用百分比；SMART 同时用于识别当前故障。",
                    "The life estimate comes from NVMe percentage used; SMART separately identifies current failure."
                )
            }
            return L10n.text(
                "SMART 已验证只表示当前未报告故障，不等同于剩余寿命 100%。",
                "SMART Verified means no current failure was reported; it does not mean 100% remaining life."
            )
        case .capacity:
            guard let total = snapshot.capacity.totalBytes,
                  let available = snapshot.capacity.availableForImportantUsageBytes,
                  total > 0 else {
                return L10n.text("可用空间未读取。", "Available space not read.")
            }
            let percent = Int((Double(available) / Double(total) * 100).rounded())
            return L10n.text(
                "占总容量 \(percent)%；同时考虑可用比例与绝对余量",
                "\(percent)% of total; considers both free-space ratio and absolute headroom"
            )
        case .stability:
            return L10n.text(
                "最近 30 天：内核崩溃 \(count(snapshot.stability.panicCount)) · 意外重启 \(count(snapshot.stability.unexpectedRestartCount)) · 卡顿 \(count(snapshot.stability.hangCount))",
                "Last 30 days: kernel panics \(count(snapshot.stability.panicCount)) · unexpected restarts \(count(snapshot.stability.unexpectedRestartCount)) · hangs \(count(snapshot.stability.hangCount))"
            )
        case .battery:
            guard let battery = snapshot.battery else {
                return L10n.text("未知保持未知，不用当前电量代替寿命。", "Unknown stays unknown; current charge never substitutes for lifespan.")
            }
            let cycles = battery.cycleCount.map(String.init) ?? "--"
            return L10n.text(
                "循环 \(cycles) 次 · 系统状况：\(batteryConditionText(battery.condition))",
                "\(cycles) cycles · system condition: \(batteryConditionText(battery.condition))"
            )
        case .backup:
            return L10n.text("备份不参与设备健康分。", "Backup does not affect the device health score.")
        }
    }

    private func progressValue(_ component: HealthComponentEvaluation?) -> Double? {
        guard let component,
              component.availability == .available || component.availability == .partial,
              let score = component.score,
              score.isFinite else {
            return nil
        }
        return min(max(score, 0), 100)
    }

    private func scoreText(_ component: HealthComponentEvaluation?) -> String {
        guard let score = progressValue(component) else { return "—" }
        return "\(Int(score.rounded())) / 100"
    }

    private func component(for factor: HealthFactor) -> HealthComponentEvaluation? {
        evaluation?.components.first { $0.factor == factor }
    }

    private func count(_ value: Int?) -> String {
        value.map(String.init) ?? "--"
    }

    private func batteryConditionText(_ value: BatteryCondition?) -> String {
        switch value {
        case .normal: L10n.text("正常", "Normal")
        case .serviceRecommended: L10n.text("建议检修", "Service Recommended")
        case .unknown, nil: L10n.text("系统未明确", "Not Reported")
        }
    }
}
