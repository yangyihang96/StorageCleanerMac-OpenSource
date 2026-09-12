import SwiftUI

struct HealthFactorGrid: View {
    let evaluation: ComputerHealthEvaluation?
    var snapshot: ComputerHealthSnapshot? = nil

    var usesTwoColumns = false

    private var columns: [GridItem] {
        if usesTwoColumns { return [GridItem(.flexible()), GridItem(.flexible())] }
        return [
        GridItem(
            .adaptive(minimum: 230, maximum: 360),
            spacing: AppDesignTokens.Spacing.large,
            alignment: .top
        )
    ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("核心健康指标", "Core Health Indicators"), systemImage: "square.grid.2x2")
                    .font(AppDesignTokens.Typography.sectionTitle)
                Spacer()
                Text(L10n.text(
                    "只显示可验证的四项计分依据",
                    "Only four verifiable factors affect the score"
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(ComputerHealthScoring.scoredFactors, id: \.self) { factor in
                    factorRow(factor)
                }
            }
        }
    }

    private func factorRow(_ factor: HealthFactor) -> some View {
        let component = component(for: factor)
        let availability = component?.availability ?? .unavailable
        let color = HealthDashboardVisuals.color(
            score: component?.score,
            availability: availability
        )
        let progress = progressValue(component)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: HealthDashboardVisuals.factorSymbol(factor))
                    .font(AppDesignTokens.Typography.sectionSymbol)
                    .foregroundStyle(color)
                    .frame(width: 30, height: 30)

                Text(HealthDashboardVisuals.factorTitle(factor))
                    .font(AppDesignTokens.Typography.cardTitle)

                Spacer(minLength: 8)

                Text(scoreText(component))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(progress == nil ? .secondary : .primary)
                    .monospacedDigit()
            }

            Text(primaryValue(for: factor))
                .font(AppDesignTokens.Typography.compactMetricValue)
                .foregroundStyle(progress == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            // The source explanation stays available without displacing the measured value.
            DisclosureGroup(L10n.text("指标来源", "Source")) {
                Text(detail(for: factor))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(AppDesignTokens.Typography.metadata)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    if let progress {
                        Capsule().fill(color.gradient)
                            .frame(width: proxy.size.width * min(1, max(0, progress / 100)))
                    }
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)

            HStack {
                Text(HealthDashboardVisuals.availabilityText(availability))
                    .foregroundStyle(color)
                Spacer()
                if let updatedAt = component?.evaluatedAt {
                    Text(updatedAt.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .font(AppTypography.body.weight(.medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
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
                return L10n.text("同时考虑可用比例与绝对余量。", "Uses both available ratio and absolute headroom.")
            }
            let percent = Int((Double(available) / Double(total) * 100).rounded())
            return L10n.text(
                "占总容量 \(percent)%；同时考虑比例与绝对余量。",
                "\(percent)% of total; uses both ratio and absolute headroom."
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
