import SwiftUI

enum HealthDashboardText {
    static var dataInsufficient: String {
        L10n.text("数据不足", "Data Insufficient")
    }

    static var environmentTitle: String {
        L10n.text("环境状态（不计入总分）", "Environment (Not Scored)")
    }

    static var scoreEvidenceTitle: String {
        L10n.text("评分构成与原始证据", "Score Breakdown & Raw Evidence")
    }
}

enum HealthScoreDeltaSelector {
    static func delta(
        current: ComputerHealthEvaluation,
        history: [ComputerHealthHistoryEntry],
        targetDaysAgo: Int,
        toleranceDays: Int,
        calendar inputCalendar: Calendar = .current
    ) -> Double? {
        guard let currentScore = current.score,
              currentScore.isFinite,
              targetDaysAgo > 0,
              toleranceDays >= 0,
              current.evaluatedAt.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }

        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let currentDay = calendar.startOfDay(for: current.evaluatedAt)
        guard let targetDay = calendar.date(byAdding: .day, value: -targetDaysAgo, to: currentDay) else {
            return nil
        }

        struct Candidate {
            let score: Double
            let recordedAt: Date
            let dayDistance: Int
        }

        let candidates = history.compactMap { entry -> Candidate? in
            guard entry.modelVersion == ComputerHealthHistoryEntry.currentModelVersion,
                  entry.evaluation.modelVersion == current.modelVersion,
                  let score = entry.evaluation.score,
                  score.isFinite,
                  entry.recordedAt.timeIntervalSinceReferenceDate.isFinite else {
                return nil
            }
            let day = calendar.startOfDay(for: entry.recordedAt)
            guard day < currentDay else { return nil }
            let distance = abs(calendar.dateComponents([.day], from: targetDay, to: day).day ?? .max)
            guard distance <= toleranceDays else { return nil }
            return Candidate(score: score, recordedAt: entry.recordedAt, dayDistance: distance)
        }

        guard let selected = candidates.min(by: { lhs, rhs in
            if lhs.dayDistance != rhs.dayDistance {
                return lhs.dayDistance < rhs.dayDistance
            }
            return lhs.recordedAt > rhs.recordedAt
        }) else {
            return nil
        }
        return currentScore - selected.score
    }
}

enum HealthDashboardVisuals {
    static func color(for status: ComputerHealthEvaluationStatus) -> Color {
        switch status {
        case .healthy: AppDesignTokens.Palette.success
        case .attention: AppDesignTokens.Palette.warning
        case .actionRequired: AppDesignTokens.Palette.destructive
        case .dataInsufficient: .secondary
        }
    }

    static func color(
        score: Double?,
        availability: HealthEvidenceAvailability
    ) -> Color {
        guard availability == .available || availability == .partial,
              let score,
              score.isFinite else {
            return .secondary
        }
        if score >= 85 { return AppDesignTokens.Palette.success
        }
        if score >= 60 { return AppDesignTokens.Palette.warning
        }
        return AppDesignTokens.Palette.destructive
    }

    static func availabilityText(_ availability: HealthEvidenceAvailability) -> String {
        switch availability {
        case .available: L10n.text("证据完整", "Available")
        case .partial: L10n.text("部分证据", "Partial Evidence")
        case .permissionDenied: L10n.text("权限受限", "Permission Limited")
        case .timedOut: L10n.text("读取超时", "Timed Out")
        case .unavailable: L10n.text("暂不可用", "Unavailable")
        case .notApplicable: L10n.text("不适用于此 Mac", "Not Applicable")
        }
    }

    static func factorTitle(_ factor: HealthFactor) -> String {
        switch factor {
        case .diskReliability: L10n.text("磁盘可靠性", "Disk Reliability")
        case .capacity: L10n.text("容量余量", "Capacity")
        case .stability: L10n.text("系统稳定性", "Stability")
        case .backup: L10n.text("备份", "Backup")
        case .battery: L10n.text("电池", "Battery")
        }
    }

    static func factorSymbol(_ factor: HealthFactor) -> String {
        switch factor {
        case .diskReliability: "internaldrive.fill"
        case .capacity: "chart.line.downtrend.xyaxis"
        case .stability: "waveform.path.ecg"
        case .backup: "clock.arrow.circlepath"
        case .battery: "battery.75"
        }
    }
}

struct HealthScoreHero: View {
    @Environment(\.windowLayoutMetrics) private var layout

    let evaluation: ComputerHealthEvaluation?
    let checkedAt: Date?
    let isRefreshing: Bool
    let errorText: String?
    let refreshTitle: String
    var isPortrait = false
    let onRefresh: () -> Void

    var body: some View {
        Group {
            if isPortrait {
                portraitContent
            } else if layout.density == .compact {
                compactContent
            } else {
                regularContent
            }
        }
        .padding(AppDesignTokens.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var portraitContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            scoreSummary.frame(maxWidth: .infinity, alignment: .center)
            statusSummary
            refreshButton.frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 8)
    }

    private var regularContent: some View {
        HStack(alignment: .center, spacing: AppDesignTokens.Spacing.section) {
            scoreSummary
            statusSummary

            Spacer(minLength: 12)
            refreshButton
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppDesignTokens.Spacing.large) {
                    scoreSummary
                    statusSummary
                        .frame(minWidth: 240, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
                    scoreSummary
                    statusSummary
                }
            }

            refreshButton
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(statusTitle, systemImage: statusSystemImage)
                .font(AppDesignTokens.Typography.sectionTitle)
                .foregroundStyle(statusColor)

            DisclosureGroup(L10n.text("评分说明", "Score details")) {
                Text(statusDetail)
                Text(L10n.text(
                    "磁盘、容量、稳定性、电池参与计分；备份与即时状态独立呈现。",
                    "Disk, capacity, stability, and battery affect the score; backup and live status remain separate."
                ))
            }
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppDesignTokens.Spacing.medium) {
                    evidenceMetadata
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    evidenceMetadata
                }
            }
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if let errorText, !errorText.trimmed.isEmpty {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.body)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
            }
        }
    }

    private var refreshButton: some View {
        AppButton(
            title: isRefreshing ? L10n.text("检查中", "Checking") : refreshTitle,
            systemImage: isRefreshing ? "hourglass" : "arrow.clockwise",
            kind: .primary,
            controlSize: .regular,
            isLoading: isRefreshing,
            isDisabled: isRefreshing,
            action: onRefresh
        )
    }

    @ViewBuilder
    private var evidenceMetadata: some View {
        if let confidence = evaluation?.confidence {
            Label(
                L10n.text(
                    "评估可信度 \(confidence.value)% · \(confidenceLevelText(confidence.level))",
                    "Assessment confidence \(confidence.value)% · \(confidenceLevelText(confidence.level))"
                ),
                systemImage: "checkmark.shield"
            )
        }
        if let evaluation {
            Label(
                L10n.text(
                    "核心证据 \(percent(evaluation.coverage))",
                    "Core evidence \(percent(evaluation.coverage))"
                ),
                systemImage: "checkmark.seal"
            )
        }
        if let checkedAt {
            Label(
                checkedAt.formatted(date: .abbreviated, time: .shortened),
                systemImage: "clock"
            )
            .foregroundStyle(.tertiary)
        }
    }

    private var scoreSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("实测健康分", "Measured Health Score"), systemImage: "heart.text.square.fill")
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(statusColor)

            if let score = evaluation?.score, score.isFinite {
                GeekCombinedRing(
                    title: L10n.text("实测", "MEASURED"),
                    value: "\(Int(score.rounded()))",
                    detail: "/ 100",
                    progress: min(1, max(0, score / 100)),
                    tint: statusColor,
                    size: layout.density == .compact ? 112 : 148
                )
            } else {
                ZStack {
                    Circle().stroke(.white.opacity(0.14), lineWidth: 10)
                    VStack(spacing: 8) {
                        Text("—").font(.system(size: 32, weight: .medium)).monospacedDigit()
                        Text(evaluation == nil ? L10n.text("尚未检查", "Not Checked") : HealthDashboardText.dataInsufficient)
                            .font(AppDesignTokens.Typography.secondary).foregroundStyle(.secondary)
                    }
                }
                .frame(width: layout.density == .compact ? 112 : 148, height: layout.density == .compact ? 112 : 148)
            }
        }
        .frame(width: layout.density == .compact ? 166 : 186, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("系统健康分", "System health score"))
        .accessibilityValue(scoreAccessibilityValue)
    }

    private var statusColor: Color {
        evaluation.map { HealthDashboardVisuals.color(for: $0.status) } ?? .secondary
    }

    private var statusTitle: String {
        guard let evaluation else {
            return L10n.text("尚未检查", "Not Checked")
        }
        switch evaluation.status {
        case .healthy:
            return L10n.text("核心状态良好", "Core Health Is Good")
        case .attention:
            return L10n.text("存在需要关注的指标", "A Core Indicator Needs Attention")
        case .actionRequired:
            return L10n.text("核心指标需要处理", "A Core Indicator Requires Action")
        case .dataInsufficient:
            return HealthDashboardText.dataInsufficient
        }
    }

    private var statusSystemImage: String {
        guard let evaluation else { return "questionmark.circle" }
        switch evaluation.status {
        case .healthy: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .actionRequired: return "exclamationmark.triangle.fill"
        case .dataInsufficient: return "questionmark.circle"
        }
    }

    private var statusDetail: String {
        guard let evaluation else {
            return L10n.text(
                "检查磁盘、电池与系统状态",
                "Check disk, battery, and system status"
            )
        }
        switch evaluation.status {
        case .healthy:
            return L10n.text(
                "已测核心指标未发现明显风险。",
                "Measured core indicators show no material risk."
            )
        case .attention:
            return L10n.text(
                "至少一项实测指标需要关注；平均分不会掩盖单项异常。",
                "At least one measured indicator needs attention; the average never hides an unhealthy component."
            )
        case .actionRequired:
            return L10n.text(
                "至少一项核心指标达到需处理阈值，请先核对原始证据。",
                "At least one core indicator reached the action threshold; review its raw evidence first."
            )
        case .dataInsufficient:
            return L10n.text(
                "部分状态暂不可用，可在详情中查看",
                "Some status information is unavailable; review details below"
            )
        }
    }

    private var scoreAccessibilityValue: String {
        guard let score = evaluation?.score, score.isFinite else {
            return evaluation == nil
                ? L10n.text("尚未检查", "Not Checked")
                : HealthDashboardText.dataInsufficient
        }
        return "\(Int(score.rounded())) / 100"
    }

    private func confidenceLevelText(_ level: HealthConfidenceLevel) -> String {
        switch level {
        case .high: L10n.text("高", "High")
        case .medium: L10n.text("中", "Medium")
        case .low: L10n.text("低", "Low")
        }
    }

    private func percent(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        return "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }
}
