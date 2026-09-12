import SwiftUI

struct EnergyImpactScanLandingView: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        FeatureLandingPageShell(
            title: L10n.text("能耗", "Energy"),
            subtitle: ReviewFilter.energy.pageSubtitle,
            headerSystemImage: AppSymbols.Navigation.energy,
            configurationTitle: L10n.text("测量流程", "Measurement Stages"),
            actionTitle: store.isEnergyImpactPageScanActive
                ? L10n.text("正在测量", "Measuring")
                : L10n.text("开始测量", "Start Measurement"),
            actionDetail: "",
            actionSystemImage: "bolt.fill",
            status: scanStatus,
            isLoading: store.isEnergyImpactPageScanActive,
            isActionDisabled: !store.canRefreshEnergyImpact,
            trustText: L10n.text(
                "只读测量，不会更改电源模式或结束应用",
                "Read-only measurement; power modes and apps are not changed"
            ),
            action: { store.scanEnergyImpact() }
        ) {
            EnergyImpactScanPipelineView(phase: visiblePhase, showsStageDetails: true)
        }
    }

    private var visiblePhase: EnergyImpactScanPhase? {
        store.isEnergyImpactPageScanActive ? store.energyImpactScanPhase : nil
    }

    private var scanStatus: ScanStatusPresentation {
        guard store.isEnergyImpactPageScanActive else {
            return store.isLoadingEnergyImpact
                ? .idle(L10n.text("正在完成后台能耗测量", "Finishing background energy measurement"))
                : .idle(L10n.text("尚未开始测量", "Measurement not started"))
        }
        return .scanning(
            store.energyImpactScanPhase?.detail
                ?? L10n.text("正在准备能耗测量…", "Preparing energy measurement…")
        )
    }
}

struct EnergyImpactScanProgressPanel: View {
    @Environment(\.moduleTheme) private var theme
    let phase: EnergyImpactScanPhase?

    var body: some View {
        EnergyImpactScanPipelineView(phase: phase)
            .padding(.horizontal, AppDesignTokens.Spacing.medium)
            .padding(.vertical, AppDesignTokens.Spacing.small)
            .glassPanel(
                cornerRadius: AppDesignTokens.Radius.settingsPanel,
                tint: theme.accent,
                prominence: .quiet
            )
    }
}

struct EnergyImpactScanPipelineView: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    let phase: EnergyImpactScanPhase?

    var showsStageDetails = false

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.tight) {
            if showsStageDetails {
                detailedStages
            } else if layout.density == .compact {
                compactStages
                Text(compactStageSummary)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(phase == nil ? Color.secondary : theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                labeledStages
            }

            if phase != nil || !showsStageDetails {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                    Capsule(style: .continuous)
                        .fill(theme.accent)
                        .frame(width: geometry.size.width * progressFraction)
                }
            }
                .frame(maxWidth: 560)
                .frame(height: 4)
                .accessibilityLabel(L10n.text("能耗扫描进度", "Energy scan progress"))
                .accessibilityValue("\(Int(progressFraction * 100))%")

            Text(
                phase?.detail
                    ?? L10n.text(
                        "按真实数据流完成进程识别、采样、校准与汇总",
                        "Processes, sampling, calibration, and results follow the real data flow"
                    )
            )
            .font(AppDesignTokens.Typography.compactLabel)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            phase?.detail
                ?? L10n.text("能耗扫描共六个步骤", "Energy scan has six steps")
        )
    }

    private var detailedStages: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(EnergyImpactScanPhase.allCases.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 14) {
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .frame(width: 23, height: 23)
                        .background(theme.accent.opacity(0.7), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.30)))
                        .accessibilityHidden(true)
                    Text(step.shortTitle)
                        .font(AppDesignTokens.Typography.compactLabelEmphasis)
                        .frame(width: 48, alignment: .leading)
                    Text(step.overview)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if phase == step {
                        Image(systemName: "circle.inset.filled")
                            .accessibilityLabel(L10n.text("当前步骤", "Current step"))
                    }
                }
                .help(step.overview)
                .foregroundStyle(phase == step ? theme.accent : Color.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labeledStages: some View {
        HStack(spacing: AppDesignTokens.Spacing.tight) {
            ForEach(Array(EnergyImpactScanPhase.allCases.enumerated()), id: \.element.id) { index, step in
                stage(step)

                if index < EnergyImpactScanPhase.allCases.count - 1 {
                    Capsule(style: .continuous)
                        .fill(connectorColor(after: step))
                        .frame(width: 18, height: 2)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: 620)
    }

    private var compactStages: some View {
        HStack(spacing: 0) {
            ForEach(Array(EnergyImpactScanPhase.allCases.enumerated()), id: \.element.id) { index, step in
                let isComplete = phase.map { step.rawValue < $0.rawValue } ?? false
                let isCurrent = phase == step

                Image(systemName: isComplete ? "checkmark.circle.fill" : isCurrent ? "circle.inset.filled" : "circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isComplete || isCurrent ? theme.accent : Color.secondary.opacity(0.72))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                if index < EnergyImpactScanPhase.allCases.count - 1 {
                    Capsule(style: .continuous)
                        .fill(connectorColor(after: step))
                        .frame(maxWidth: .infinity)
                        .frame(height: 2)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: 560)
    }

    private var compactStageSummary: String {
        let steps = EnergyImpactScanPhase.allCases
        guard let phase,
              let index = steps.firstIndex(of: phase) else {
            return L10n.text("六个测量步骤", "Six measurement steps")
        }
        return L10n.text(
            "步骤 \(index + 1)/\(steps.count) · \(phase.shortTitle)",
            "Step \(index + 1) of \(steps.count) · \(phase.shortTitle)"
        )
    }

    private func stage(_ step: EnergyImpactScanPhase) -> some View {
        let isComplete = phase.map { step.rawValue < $0.rawValue } ?? false
        let isCurrent = phase == step

        return HStack(spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : isCurrent ? "circle.inset.filled" : "circle")
                .symbolRenderingMode(.hierarchical)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(step.shortTitle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(AppDesignTokens.Typography.compactLabel)
        .foregroundStyle(isComplete || isCurrent ? theme.accent : Color.secondary.opacity(0.72))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func connectorColor(after step: EnergyImpactScanPhase) -> Color {
        guard let phase else { return Color.secondary.opacity(0.20) }
        return step.rawValue < phase.rawValue
            ? theme.accent.opacity(0.82)
            : Color.secondary.opacity(0.20)
    }

    private var progressFraction: CGFloat {
        CGFloat(phase?.fractionCompleted ?? 0)
    }
}

private extension EnergyImpactScanPhase {
    var overview: String {
        switch self {
        case .readingProcesses:
            L10n.text("读取当前运行的进程", "Read currently running processes")
        case .identifyingApplications:
            L10n.text("将子进程归属到对应应用", "Attribute child processes to their apps")
        case .capturingBaseline:
            L10n.text("记录 CPU、能耗与磁盘计数基线", "Record CPU, energy, and disk baselines")
        case .preparingPreview:
            L10n.text("生成第一组可归属数据", "Prepare the first attributable snapshot")
        case .measuringChanges:
            L10n.text("测量 1.2 秒内的真实变化", "Measure real changes over 1.2 seconds")
        case .calculatingResults:
            L10n.text("按本机数据校准并汇总结果", "Calibrate and assemble results from this Mac")
        }
    }

    var shortTitle: String {
        switch self {
        case .readingProcesses:
            L10n.text("进程", "Processes")
        case .identifyingApplications:
            L10n.text("归属", "Apps")
        case .capturingBaseline:
            L10n.text("基线", "Baseline")
        case .preparingPreview:
            L10n.text("初算", "Preview")
        case .measuringChanges:
            L10n.text("采样", "Measure")
        case .calculatingResults:
            L10n.text("汇总", "Results")
        }
    }

    var detail: String {
        switch self {
        case .readingProcesses:
            L10n.text("正在读取当前运行进程…", "Reading running processes…")
        case .identifyingApplications:
            L10n.text("正在识别应用及其子进程归属…", "Attributing processes to applications…")
        case .capturingBaseline:
            L10n.text("正在采集 CPU、能耗与磁盘计数基线…", "Capturing CPU, energy, and disk baselines…")
        case .preparingPreview:
            L10n.text("正在生成第一组可归属能耗数据…", "Preparing the first attributable energy snapshot…")
        case .measuringChanges:
            L10n.text("正在测量 1.2 秒内的实时变化…", "Measuring live changes over 1.2 seconds…")
        case .calculatingResults:
            L10n.text("正在按本机数据校准并汇总结果…", "Calibrating and assembling results from this Mac…")
        }
    }
}
