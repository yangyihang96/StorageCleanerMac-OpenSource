import SwiftUI

enum HealthDashboardSafeAction: String, Hashable, Sendable {
    case openDiskUtility
    case openSafeCleanup
    case battery
    case openTimeMachineSettings
    case openDiagnosticReports
}

enum HealthDashboardActionReason: Int, Hashable, Sendable {
    case smartFailing
    case currentCapacityPressure
    case batteryService
    case backupStaleOrUnconfigured
    case recentPanicOrRestart
    case forecastWithinThirtyDays
    case lowComponentScore
    case attentionComponentScore
}

struct HealthDashboardAction: Identifiable, Equatable, Sendable {
    let factor: HealthFactor
    let reason: HealthDashboardActionReason
    let weightedDeduction: Double
    let safeAction: HealthDashboardSafeAction

    var id: HealthFactor { factor }
}

struct HealthDashboardActionContext: Sendable {
    let evaluation: ComputerHealthEvaluation
    let smartIsFailing: Bool
    let isUnderCurrentCapacityPressure: Bool
    let batteryServiceRecommended: Bool
    let backupNeedsAttention: Bool
    let hasRecentPanicOrRestart: Bool
    let forecastDaysUntilPressure: Int?

    static func make(
        evaluation: ComputerHealthEvaluation,
        snapshot: ComputerHealthSnapshot,
        storageForecast: StoragePressureForecast?,
        referenceDate: Date
    ) -> HealthDashboardActionContext {
        HealthDashboardActionContext(
            evaluation: evaluation,
            smartIsFailing: snapshot.disk.smartStatus == .failing,
            isUnderCurrentCapacityPressure: isUnderPressure(snapshot.capacity),
            batteryServiceRecommended: snapshot.battery?.condition == .serviceRecommended,
            backupNeedsAttention: backupNeedsAttention(snapshot.backup, referenceDate: referenceDate),
            hasRecentPanicOrRestart: hasRecentSeriousStabilityEvent(
                snapshot.stability,
                referenceDate: referenceDate
            ),
            forecastDaysUntilPressure: storageForecast?.daysUntilPressure
        )
    }

    private static func isUnderPressure(_ capacity: CapacityTrendSnapshot) -> Bool {
        guard let total = capacity.totalBytes,
              let available = capacity.availableForImportantUsageBytes,
              total > 0,
              available >= 0 else {
            return false
        }
        let twentyGiB = Int64(20) * 1_024 * 1_024 * 1_024
        let pressureLine = max(Int64((Double(total) * 0.15).rounded(.up)), twentyGiB)
        return available <= pressureLine
    }

    private static func backupNeedsAttention(
        _ backup: TimeMachineSnapshot,
        referenceDate: Date
    ) -> Bool {
        if backup.destinationState == .unconfigured { return true }
        guard let latest = backup.latestCompleteBackup,
              latest.timeIntervalSinceReferenceDate.isFinite,
              referenceDate.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        return referenceDate.timeIntervalSince(latest) > 14 * 86_400
    }

    private static func hasRecentSeriousStabilityEvent(
        _ stability: StabilitySummary,
        referenceDate: Date
    ) -> Bool {
        stability.events.contains { event in
            guard event.type == .panic || event.type == .unexpectedRestart else { return false }
            let age = referenceDate.timeIntervalSince(event.occurredAt)
            return age >= 0 && age <= 7 * 86_400
        }
    }
}

enum HealthDashboardActionSelector {
    static func select(from context: HealthDashboardActionContext) -> [HealthDashboardAction] {
        let accounting = ComputerHealthScoring.accounting(
            for: context.evaluation.components
        )
        var candidates: [HealthDashboardAction] = []

        if context.smartIsFailing {
            candidates.append(candidate(.diskReliability, .smartFailing, accounting))
        }
        if context.isUnderCurrentCapacityPressure {
            candidates.append(candidate(.capacity, .currentCapacityPressure, accounting))
        }
        if context.batteryServiceRecommended {
            candidates.append(candidate(.battery, .batteryService, accounting))
        }
        if context.backupNeedsAttention {
            candidates.append(candidate(.backup, .backupStaleOrUnconfigured, accounting))
        }
        if context.hasRecentPanicOrRestart {
            candidates.append(candidate(.stability, .recentPanicOrRestart, accounting))
        }
        if let days = context.forecastDaysUntilPressure, (1...30).contains(days) {
            candidates.append(candidate(.capacity, .forecastWithinThirtyDays, accounting))
        }

        for component in context.evaluation.components {
            guard component.availability == .available || component.availability == .partial,
                  let score = component.score,
                  score.isFinite else {
                continue
            }
            if score < 60 {
                candidates.append(candidate(component.factor, .lowComponentScore, accounting))
            } else if score < 85 {
                candidates.append(candidate(component.factor, .attentionComponentScore, accounting))
            }
        }

        let ordered = candidates.sorted(by: comesBefore)
        var selectedFactors = Set<HealthFactor>()
        var selected: [HealthDashboardAction] = []
        for action in ordered where !selectedFactors.contains(action.factor) {
            selectedFactors.insert(action.factor)
            selected.append(action)
            if selected.count == 3 { break }
        }
        return selected
    }

    private static func candidate(
        _ factor: HealthFactor,
        _ reason: HealthDashboardActionReason,
        _ accounting: ComputerHealthScoreAccounting
    ) -> HealthDashboardAction {
        return HealthDashboardAction(
            factor: factor,
            reason: reason,
            weightedDeduction: accounting.component(for: factor)?.normalizedDeduction ?? 0,
            safeAction: safeAction(for: factor)
        )
    }

    private static func comesBefore(
        _ lhs: HealthDashboardAction,
        _ rhs: HealthDashboardAction
    ) -> Bool {
        if lhs.reason.rawValue != rhs.reason.rawValue {
            return lhs.reason.rawValue < rhs.reason.rawValue
        }
        if abs(lhs.weightedDeduction - rhs.weightedDeduction) > 0.000_001 {
            return lhs.weightedDeduction > rhs.weightedDeduction
        }
        return stableFactorIndex(lhs.factor) < stableFactorIndex(rhs.factor)
    }

    private static func stableFactorIndex(_ factor: HealthFactor) -> Int {
        HealthFactor.allCases.firstIndex(of: factor) ?? .max
    }

    private static func safeAction(for factor: HealthFactor) -> HealthDashboardSafeAction {
        switch factor {
        case .diskReliability: .openDiskUtility
        case .capacity: .openSafeCleanup
        case .stability: .openDiagnosticReports
        case .backup: .openTimeMachineSettings
        case .battery: .battery
        }
    }
}

struct HealthActionList: View {
    let actions: [HealthDashboardAction]
    let batterySettingsState: BatterySettingsAdjustmentState
    let perform: (HealthDashboardSafeAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("需要核对", "Needs Review"), systemImage: "checklist")
                    .font(AppDesignTokens.Typography.sectionTitle)
                Spacer()
                Text(L10n.text("最多 3 项", "Up to 3"))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array(actions.enumerated()), id: \.element.id) { item in
                let action = item.element
                let control = controlPresentation(for: action)
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: HealthDashboardVisuals.factorSymbol(action.factor))
                        .font(.title3.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint(action))
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(action))
                            .font(AppDesignTokens.Typography.cardTitle)
                        Text(detail(action))
                            .font(AppDesignTokens.Typography.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 10)

                    Button(actionTitle(action.safeAction, control: control)) {
                        perform(action.safeAction)
                    }
                    .appButtonChrome(.secondary)
                    .controlSize(.regular)
                    .disabled(control?.isEnabled == false)
                }
                .padding(.vertical, 8)

                if item.offset < actions.count - 1 {
                    Divider()
                        .padding(.leading, 36)
                }
            }
        }
        .padding(16)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.warning.opacity(0.045)
        )
    }

    private func title(_ action: HealthDashboardAction) -> String {
        switch action.reason {
        case .smartFailing: L10n.text("SMART 报告磁盘需要处理", "SMART Reports a Disk Issue")
        case .currentCapacityPressure: L10n.text("可用空间已进入压力区", "Available Space Is Under Pressure")
        case .batteryService: L10n.text("系统建议检修电池", "Battery Service Is Recommended")
        case .backupStaleOrUnconfigured: L10n.text("备份未配置或已过期", "Backup Is Missing or Stale")
        case .recentPanicOrRestart: L10n.text("近期发生严重稳定性事件", "Recent Serious Stability Event")
        case .forecastWithinThirtyDays: L10n.text("预计 30 天内进入容量压力区", "Capacity Pressure Forecast Within 30 Days")
        case .lowComponentScore:
            L10n.text("\(HealthDashboardVisuals.factorTitle(action.factor))需要处理", "\(HealthDashboardVisuals.factorTitle(action.factor)) Needs Action")
        case .attentionComponentScore:
            L10n.text("留意\(HealthDashboardVisuals.factorTitle(action.factor))", "Review \(HealthDashboardVisuals.factorTitle(action.factor))")
        }
    }

    private func detail(_ action: HealthDashboardAction) -> String {
        switch action.reason {
        case .smartFailing:
            L10n.text("先备份重要数据，再用系统磁盘工具核对；不要在此状态下运行高负载磁盘操作。", "Back up important data, then verify with Disk Utility. Avoid heavy disk work in this state.")
        case .currentCapacityPressure:
            L10n.text("只进入可复核的安全清理页，不会自动删除文件。", "Opens reviewable Safe Cleanup and never deletes files automatically.")
        case .batteryService:
            L10n.text("打开系统电池设置核对状况；本应用不会直接控制充电上限。", "Review the condition in Battery Settings; this app never controls charging limits directly.")
        case .backupStaleOrUnconfigured:
            L10n.text("在系统设置中配置或确认最近一次完整备份。", "Configure Time Machine or verify a recent complete backup in System Settings.")
        case .recentPanicOrRestart:
            L10n.text("打开系统诊断报告，按时间核对内核崩溃或意外重启。", "Open Diagnostic Reports and review kernel panics or unexpected restarts by date.")
        case .forecastWithinThirtyDays:
            L10n.text("预测使用稳健趋势，不代表保证；现在可先复核安全清理候选。", "The robust trend is not a guarantee; review safe cleanup candidates now.")
        case .lowComponentScore, .attentionComponentScore:
            L10n.text("打开对应的系统或本应用安全入口，核对原始证据后再操作。", "Open the safe system or in-app destination and verify the raw evidence before acting.")
        }
    }

    private func actionTitle(
        _ action: HealthDashboardSafeAction,
        control: BatterySettingsActionPresentation?
    ) -> String {
        switch action {
        case .openDiskUtility: L10n.text("打开磁盘工具", "Open Disk Utility")
        case .openSafeCleanup: L10n.text("打开安全清理", "Open Safe Cleanup")
        case .battery:
            (control ?? BatterySettingsActionResolver.resolve(batterySettingsState))
                .label.localizedTitle
        case .openTimeMachineSettings: L10n.text("打开时间机器", "Open Time Machine")
        case .openDiagnosticReports: L10n.text("打开诊断报告", "Open Diagnostic Reports")
        }
    }

    private func controlPresentation(
        for action: HealthDashboardAction
    ) -> BatterySettingsActionPresentation? {
        guard action.safeAction == .battery else { return nil }
        return BatterySettingsActionResolver.resolve(batterySettingsState)
    }

    private func tint(_ action: HealthDashboardAction) -> Color {
        switch action.reason {
        case .smartFailing, .currentCapacityPressure, .batteryService: AppDesignTokens.Palette.destructive
        case .backupStaleOrUnconfigured, .recentPanicOrRestart, .forecastWithinThirtyDays, .lowComponentScore: AppDesignTokens.Palette.warning
        case .attentionComponentScore: AppDesignTokens.Palette.information
        }
    }
}
