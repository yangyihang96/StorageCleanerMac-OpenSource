import SwiftUI

struct MacBenchmarkDashboardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let benchmarkProfile: BenchmarkProfile = .standard
    @State private var sustainedSafetyConfirmed = false

    let suiteStep: MacBenchmarkSuiteStep?
    let suiteOutcome: MacBenchmarkSuiteOutcome?
    let state: MacBenchmarkState
    let progress: MacBenchmarkPresentationProgress?
    let latestResult: MacBenchmarkResult?
    let history: [MacBenchmarkResult]
    private let leaderboardStore: MacBenchmarkLeaderboardStore
    let explicitRawOnlyReason: MacBenchmarkRawOnlyPresentationReason?
    let hasVerifiedActiveBaseline: Bool
    let canStart: Bool
    let supplementalExplanation: String?
    let onStart: () -> Void
    let onCancel: () -> Void
    let acceleratorState: MacAcceleratorBenchmarkState
    let acceleratorProgress: MacAcceleratorBenchmarkProgress?
    let latestAcceleratorResult: MacAcceleratorBenchmarkResult?
    let acceleratorHistory: [MacAcceleratorBenchmarkResult]
    let acceleratorNotice: MacAcceleratorBenchmarkStoreNotice?
    let sustainedState: MacSustainedBenchmarkState
    let sustainedProgress: MacSustainedBenchmarkProgress?
    let latestSustainedResult: MacSustainedBenchmarkResult?

    init(
        suiteStep: MacBenchmarkSuiteStep? = nil,
        suiteOutcome: MacBenchmarkSuiteOutcome? = nil,
        state: MacBenchmarkState,
        progress: MacBenchmarkPresentationProgress? = nil,
        latestResult: MacBenchmarkResult? = nil,
        history: [MacBenchmarkResult] = [],
        leaderboardStore: MacBenchmarkLeaderboardStore,
        explicitRawOnlyReason: MacBenchmarkRawOnlyPresentationReason? = nil,
        hasVerifiedActiveBaseline: Bool = false,
        canStart: Bool = true,
        supplementalExplanation: String? = nil,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        acceleratorState: MacAcceleratorBenchmarkState = .idle,
        acceleratorProgress: MacAcceleratorBenchmarkProgress? = nil,
        latestAcceleratorResult: MacAcceleratorBenchmarkResult? = nil,
        acceleratorHistory: [MacAcceleratorBenchmarkResult] = [],
        acceleratorNotice: MacAcceleratorBenchmarkStoreNotice? = nil,
        sustainedState: MacSustainedBenchmarkState = .idle,
        sustainedProgress: MacSustainedBenchmarkProgress? = nil,
        latestSustainedResult: MacSustainedBenchmarkResult? = nil
    ) {
        self.suiteStep = suiteStep
        self.suiteOutcome = suiteOutcome
        self.state = state
        self.progress = progress
        self.latestResult = latestResult
        self.history = history
        self.leaderboardStore = leaderboardStore
        self.explicitRawOnlyReason = explicitRawOnlyReason
        self.hasVerifiedActiveBaseline = hasVerifiedActiveBaseline
        self.canStart = canStart
        self.supplementalExplanation = supplementalExplanation
        self.onStart = onStart
        self.onCancel = onCancel
        self.acceleratorState = acceleratorState
        self.acceleratorProgress = acceleratorProgress
        self.latestAcceleratorResult = latestAcceleratorResult
        self.acceleratorHistory = acceleratorHistory
        self.acceleratorNotice = acceleratorNotice
        self.sustainedState = sustainedState
        self.sustainedProgress = sustainedProgress
        self.latestSustainedResult = latestSustainedResult
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppDesignTokens.Layout.pageSpacing) {
                benchmarkHero

                if let displayedProgress {
                    MacBenchmarkProgressCard(
                        progress: displayedProgress,
                        isCancelling: isCancelling
                    )
                }

                runPreparationSection

                if let latestResult {
                    MacBenchmarkResultOverview(
                        result: latestResult,
                        explicitRawOnlyReason: explicitRawOnlyReason
                    )
                    MacBenchmarkComponentGrid(result: latestResult)
                } else {
                    emptyResultCard
                }

                secondaryBenchmarkSections
            }
            .padding(AppDesignTokens.Layout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // macOS 26 glass effects are hosted in an independent compositor layer
        // that can escape a ScrollView's clip. Keep this scrolling surface on
        // Apple's material/bordered variants so text and controls never render
        // through the fixed workspace header.
        .environment(\.scrollSafeGlass, true)
        .transaction { transaction in
            transaction.animation = reduceMotion ? nil : transaction.animation
        }
        .accessibilityElement(children: .contain)
    }

    private var benchmarkHero: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppDesignTokens.Spacing.section) {
                    scoreSummary
                    benchmarkHeroCopy
                        .layoutPriority(1)
                    Spacer(minLength: AppDesignTokens.Spacing.medium)
                    primaryAction
                }

                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.large) {
                    HStack(alignment: .top, spacing: AppDesignTokens.Spacing.large) {
                        scoreSummary
                        benchmarkHeroCopy
                            .layoutPriority(1)
                    }
                    primaryAction
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppDesignTokens.Spacing.section) {
                    referenceSummary
                    Text("·")
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.tertiary)
                    executionSummary
                }

                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    referenceSummary
                    executionSummary
                }
            }

            if let supplementalExplanation,
               !supplementalExplanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(supplementalExplanation, systemImage: "info.circle")
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
        }
        .padding(.horizontal, AppDesignTokens.Spacing.compact)
        .padding(.top, AppDesignTokens.Spacing.small)
    }

    private var benchmarkHeroCopy: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(
                MacBenchmarkPresentation.performanceIndexTitle,
                systemImage: AppSymbols.Benchmark.performance
            )
            .font(AppDesignTokens.Typography.pageTitle)
            .foregroundStyle(AppDesignTokens.Palette.primary)
            .fixedSize(horizontal: false, vertical: true)

            Text(heroDetail)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benchmarkMetadata(
        _ text: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label(text, systemImage: systemImage)
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    private var referenceSummary: some View {
        benchmarkMetadata(
            referenceMetadata.text,
            systemImage: referenceMetadata.systemImage,
            tint: referenceMetadata.tint
        )
    }

    private var executionSummary: some View {
        benchmarkMetadata(
            L10n.text("3 项串行 · 本机离线", "3 Sequential Tests · Runs Locally"),
            systemImage: "network.slash",
            tint: .secondary
        )
    }

    private var scoreSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(MacBenchmarkPresentation.scoreText(displayedScore))
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(displayedScore == nil
                ? L10n.text("暂无结果", "No Result")
                : latestResult.map(MacBenchmarkPresentation.resultScoreLabel)
                    ?? L10n.text("综合指数", "INDEX"))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 104, alignment: .leading)
        .accessibilityLabel(MacBenchmarkPresentation.performanceIndexTitle)
        .accessibilityValue(
            displayedScore.map(MacBenchmarkPresentation.scoreText)
                ?? L10n.text("尚无可比分", "No comparable score")
        )
    }

    @ViewBuilder
    private var primaryAction: some View {
        if isActive {
            AppButton(
                title: isCancelling
                    ? L10n.text("正在安全停止", "Stopping Safely")
                    : L10n.text("取消并清理", "Cancel & Clean Up"),
                systemImage: isCancelling ? "hourglass" : "stop.circle",
                kind: .secondary,
                controlSize: .regular,
                isLoading: isCancelling,
                isDisabled: isCancelling,
                action: onCancel
            )
            .keyboardShortcut(.escape, modifiers: [])
            .fixedSize(horizontal: true, vertical: false)
        } else {
            AppButton(
                title: L10n.text("开始完整测试", "Start Complete Test"),
                systemImage: "play.fill",
                kind: .primary,
                controlSize: .regular,
                isDisabled: !canStart || !sustainedSafetyConfirmed,
                action: onStart
            )
            .keyboardShortcut(.return, modifiers: [])
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var runPreparationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("测试前检查", "Before Testing"), systemImage: "checkmark.shield.fill")
                    .font(AppDesignTokens.Typography.cardTitle)
                Spacer()
                if !sustainedSafetyConfirmed, !isActive {
                    Text(L10n.text("勾选后才能开始", "Required to start"))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                }
            }

            Toggle(isOn: $sustainedSafetyConfirmed) {
                Text(L10n.text(
                    "我已接通电源，并确认电脑放在 10–35°C、坚硬且通风的表面，通风口无遮挡。",
                    "Power is connected and the Mac is on a hard, ventilated surface at 10–35°C with vents unobstructed."
                ))
                .font(AppDesignTokens.Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .disabled(isActive)

            Divider()
        }
        .padding(.horizontal, AppDesignTokens.Spacing.compact)
        .padding(.vertical, AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var secondaryBenchmarkSections: some View {
        acceleratorSection
        sustainedSection
        MacBenchmarkHistorySection(results: history)
        MacBenchmarkLeaderboardSection(
            store: leaderboardStore,
            profile: benchmarkProfile,
            results: latestResult.map { [$0] + history } ?? history
        )
    }

    private var acceleratorSection: some View {
        MacAcceleratorBenchmarkSection(
            state: acceleratorState,
            progress: acceleratorProgress,
            latestResult: latestAcceleratorResult,
            history: acceleratorHistory,
            notice: acceleratorNotice,
            onCancel: onCancel
        )
    }

    private var sustainedSection: some View {
        MacSustainedBenchmarkSection(
            state: sustainedState,
            progress: sustainedProgress,
            latestResult: latestSustainedResult,
            onCancel: onCancel
        )
    }

    private var emptyResultCard: some View {
        AppEmptyState(
            title: L10n.text("暂无测试结果", "No Test Result"),
            detail: L10n.text(
                "完成测试后显示原始指标与性能指数",
                "Complete a test to see raw metrics and the performance index"
            ),
            systemImage: AppSymbols.Benchmark.performance
        )
    }

    private var displayedProgress: MacBenchmarkPresentationProgress? {
        if let progress { return progress }
        if let fallback = MacBenchmarkPresentationProgress.stateFallback(state) {
            return fallback
        }
        if case .preflighting = state {
            return MacBenchmarkPresentationProgress(
                stage: .preflight,
                progress: 0,
                elapsedSeconds: 0
            )
        }
        if case .cancelling = state {
            return MacBenchmarkPresentationProgress(
                stage: .finalizing,
                progress: 0.99,
                elapsedSeconds: 0
            )
        }
        return nil
    }

    private var isActive: Bool {
        if suiteStep != nil { return true }
        switch state {
        case .preflighting, .running, .cancelling:
            return true
        case .idle, .completed, .cancelled, .failed:
            break
        }
        switch acceleratorState {
        case .preflighting, .running, .cancelling:
            return true
        case .idle, .completed, .cancelled, .failed:
            break
        }
        switch sustainedState {
        case .preflighting, .running, .coolingDown, .cancelling:
            return true
        case .idle, .completed, .cancelled, .failed:
            return false
        }
    }

    private var isCancelling: Bool {
        if case .cancelling = state { return true }
        if case .cancelling = acceleratorState { return true }
        return sustainedState == .cancelling
    }

    private var heroDetail: String {
        if let suiteStep {
            return suiteStepDetail(suiteStep)
        }
        if let suiteOutcome {
            return suiteOutcomeDetail(suiteOutcome)
        }
        return switch state {
        case .idle:
            hasVerifiedReferenceForDisplay
                ? L10n.text(
                    "与冻结参考标准比较 Apple 芯片，不是同型号排名。",
                    "Compares Apple chips with a frozen reference; this is not a same-model ranking."
                )
                : L10n.text(
                    "v6 正式基线仍在校准；当前可运行六项测试并查看原始值，但不会生成或上传猜测分数。",
                    "The formal v6 baseline is still being calibrated. You can run all six tests and inspect raw metrics, but no estimated score will be generated or uploaded."
                )
        case let .preflighting(profile):
            L10n.text(
                "正在为\(MacBenchmarkPresentation.profileTitle(profile))性能测试核对电源、热状态与磁盘条件。",
                "Checking power, thermal state, and disk conditions for the \(MacBenchmarkPresentation.profileTitle(profile)) benchmark."
            )
        case let .running(stage, progress, _):
            L10n.text(
                "正在进行\(MacBenchmarkPresentation.stageTitle(stage)) · \(Int((min(max(progress, 0), 1) * 100).rounded()))%",
                "Running \(MacBenchmarkPresentation.stageTitle(stage)) · \(Int((min(max(progress, 0), 1) * 100).rounded()))%"
            )
        case .cancelling:
            L10n.text(
                "正在等待当前采样安全退出并清理临时文件，请不要强制退出应用。",
                "Waiting for the active sample to stop safely and cleaning temporary files. Do not force quit the app."
            )
        case .completed:
            displayedScore == nil
                ? completedRawOnlyDetail
                : L10n.text("测试、复核和临时文件清理均已完成。", "Measurement, verification, and temporary-file cleanup are complete.")
        case .cancelled:
            L10n.text("测试已取消；不完整结果不会保存为分数。", "The run was cancelled; incomplete results are never saved as a score.")
        case let .failed(failure):
            MacBenchmarkPresentation.failureDetail(failure)
        }
    }

    private var displayedScore: Double? {
        guard suiteStep == nil else { return nil }
        if suiteOutcome == .cancelled { return nil }
        if case .failed = suiteOutcome { return nil }
        return latestResult.flatMap(MacBenchmarkPresentation.displayScore)?.overallScore
    }

    private func suiteStepDetail(_ step: MacBenchmarkSuiteStep) -> String {
        switch step {
        case .standard:
            return L10n.text(
                "第 1/3 项 · 正在运行 Standard v6，完成后自动继续。",
                "Step 1 of 3 · Running Standard v6; the next test starts automatically."
            )
        case .accelerator:
            return L10n.text(
                "第 2/3 项 · 正在运行图形与媒体加速测试。",
                "Step 2 of 3 · Running Graphics & Media Acceleration."
            )
        case .sustained:
            return L10n.text(
                "第 3/3 项 · 正在运行持续性能与散热稳定性测试。",
                "Step 3 of 3 · Running Sustained Performance & Thermals."
            )
        }
    }

    private func suiteOutcomeDetail(_ outcome: MacBenchmarkSuiteOutcome) -> String {
        switch outcome {
        case .completed:
            if displayedScore == nil {
                return completedRawOnlyDetail
            }
            return L10n.text(
                "三项测试已完成。性能指数采用校准后的 Standard v6；加速与持续测试保留真实原始指标。",
                "All three tests completed. The performance index uses calibrated Standard v6; acceleration and sustained tests retain their real raw metrics."
            )
        case .cancelled:
            return L10n.text(
                "完整测试已取消；已完成的有效结果会保留，不完整结果不会计分。",
                "The complete test was cancelled. Valid completed results are retained; incomplete results are not scored."
            )
        case let .failed(step):
            return L10n.text(
                "完整测试在第 \(step.rawValue)/3 项停止；请查看对应测试区块中的失败原因。",
                "The complete test stopped at step \(step.rawValue) of 3. See that test section for the failure reason."
            )
        }
    }

    private var completedRawOnlyDetail: String {
        guard let latestResult,
              let reason = MacBenchmarkPresentation.rawOnlyReason(
                for: latestResult,
                explicitReason: explicitRawOnlyReason
              ) else {
            return L10n.text(
                "测试完成；原始数据已保留，本次没有发布综合分。",
                "The run completed and raw data was retained; no overall score was published."
            )
        }
        if MacBenchmarkPresentation.displayScore(for: latestResult) != nil {
            return MacBenchmarkPresentation.nonLeaderboardDetail(reason)
        }
        return MacBenchmarkPresentation.rawOnlyDetail(reason)
    }

    private var hasVerifiedReferenceForDisplay: Bool {
        latestResult?.comparisonKey != nil || hasVerifiedActiveBaseline
    }

    private var referenceMetadata: (text: String, systemImage: String, tint: Color) {
        if let latestResult, latestResult.comparisonKey != nil {
            return (
                MacBenchmarkPresentation.referenceSummary(for: latestResult),
                "checkmark.seal",
                AppDesignTokens.Palette.information
            )
        }
        if hasVerifiedActiveBaseline {
            return (
                MacBenchmarkPresentation.activeReferenceSummary,
                "checkmark.seal",
                AppDesignTokens.Palette.information
            )
        }
        return (
            L10n.text(
                "v6 冻结参照未能载入 · 仅原始值",
                "v6 Frozen Reference Unavailable · Raw Only"
            ),
            "clock.badge.exclamationmark",
            AppDesignTokens.Palette.warning
        )
    }
}

private struct MacBenchmarkProgressCard: View {
    let progress: MacBenchmarkPresentationProgress
    let isCancelling: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 148), spacing: 8, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    isCancelling
                        ? L10n.text("安全停止与清理", "Stopping & Cleaning Up")
                        : MacBenchmarkPresentation.stageTitle(progress.stage),
                    systemImage: isCancelling ? "stop.circle" : MacBenchmarkPresentation.stageSymbol(progress.stage)
                )
                .font(AppDesignTokens.Typography.sectionTitle)

                Spacer()

                if progress.totalSampleCount > 0 {
                    Text(L10n.text(
                        "样本 \(min(progress.completedSampleCount, progress.totalSampleCount)) / \(progress.totalSampleCount)",
                        "Samples \(min(progress.completedSampleCount, progress.totalSampleCount)) / \(progress.totalSampleCount)"
                    ))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                Text(MacBenchmarkPresentation.durationText(progress.elapsedSeconds))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            AppStateIconRing(
                systemImage: isCancelling
                    ? "stop.circle"
                    : MacBenchmarkPresentation.stageSymbol(progress.stage),
                tint: isCancelling
                    ? AppDesignTokens.Palette.warning
                    : AppDesignTokens.Palette.primary,
                progress: progress.progress
            )
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(L10n.text("性能测试进度", "Performance test progress"))
                .accessibilityValue("\(Int((progress.progress * 100).rounded()))%")

            if progress.stage == .gpu, !isCancelling {
                Metal3DProgressVisualization(progress: progress.progress)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(MacBenchmarkPresentation.orderedStages, id: \.self) { stage in
                    stageItem(stage)
                }
            }

            if isCancelling {
                Label(
                    L10n.text(
                        "取消不会中断正在进行的文件系统调用；界面会等待资源释放后再结束。",
                        "Cancellation does not tear down an active file-system call; the run finishes only after resources are released."
                    ),
                    systemImage: "hourglass"
                )
                .font(AppTypography.body)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: AppDesignTokens.Palette.information.opacity(0.035))
    }

    private func stageItem(_ stage: BenchmarkStage) -> some View {
        let stageIndex = MacBenchmarkPresentation.orderedStages.firstIndex(of: stage) ?? 0
        let currentIndex = MacBenchmarkPresentation.orderedStages.firstIndex(of: progress.stage) ?? 0
        let isComplete = stageIndex < currentIndex || progress.progress >= 1
        let isCurrent = stage == progress.stage && !isComplete

        return HStack(spacing: 6) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : (isCurrent ? "circle.inset.filled" : "circle"))
                .foregroundStyle(
                    isComplete
                        ? AppDesignTokens.Palette.success
                        : (isCurrent ? AppDesignTokens.Palette.primary : Color.secondary.opacity(0.65))
                )
            Text(MacBenchmarkPresentation.stageTitle(stage))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(AppTypography.body)
        .foregroundStyle(isCurrent || isComplete ? .primary : .secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct Metal3DProgressVisualization: View {
    let progress: Double

    private var normalizedProgress: Double {
        min(1, max(0, progress))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(
                    L10n.text("Metal 3D 离屏渲染", "Metal 3D Offscreen Render"),
                    systemImage: "cube.transparent"
                )
                .font(AppDesignTokens.Typography.secondary.weight(.semibold))

                Spacer()

                Text(L10n.text("低频静态进度", "Low-frequency static progress"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Image(systemName: "cube.transparent")
                    .font(.title2)
                    .foregroundStyle(AppDesignTokens.Palette.primary)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("1920 × 1080  OFFSCREEN METAL")
                    Text("262,144 INSTANCES  ·  600 FRAMES")
                    Text("1.887B TRIANGLES / SAMPLE")
                }
                .font(AppDesignTokens.Typography.compactMonospaced.weight(.semibold))
                .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text("\(Int((normalizedProgress * 100).rounded()))%")
                    .font(AppDesignTokens.Typography.compactMonospaced.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppDesignTokens.Palette.primary)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: AppDesignTokens.Layout.rowRadius, style: .continuous)
                    .fill(AppDesignTokens.Palette.primary.opacity(0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppDesignTokens.Layout.rowRadius, style: .continuous)
                    .stroke(.secondary.opacity(0.12), lineWidth: 1)
            }

            ProgressView(value: normalizedProgress)
                .tint(AppDesignTokens.Palette.primary)
                .accessibilityLabel(L10n.text("Metal 3D 测试进度", "Metal 3D test progress"))
                .accessibilityValue("\(Int((normalizedProgress * 100).rounded()))%")

            Text(L10n.text(
                "正式 GPU 测量期间不运行 Canvas 或高帧率动画；此处只在低频进度事件到达时更新固定条件与总体进度。",
                "No Canvas or high-frame-rate animation runs during formal GPU measurement; this static panel updates only when a low-frequency progress event arrives."
            ))
            .font(AppTypography.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Metal 3D 性能测试静态进度", "Metal 3D performance test static progress"))
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

#if DEBUG
enum MacBenchmarkDebugFixture: String, CaseIterable {
    case scored
    case running
    case rawOnly
    case longLocalizedText
}

struct MacBenchmarkDashboardDebugView: View {
    @StateObject private var leaderboardStore = MacBenchmarkLeaderboardStore(
        service: UnavailableMacBenchmarkLeaderboardService()
    )
    let fixture: MacBenchmarkDebugFixture

    var body: some View {
        MacBenchmarkDashboardView(
            state: debugState,
            progress: debugProgress,
            latestResult: debugResult,
            history: debugHistory,
            leaderboardStore: leaderboardStore,
            explicitRawOnlyReason: fixture == .rawOnly ? .environmentNotComparable : nil,
            supplementalExplanation: fixture == .longLocalizedText
                ? L10n.text(
                    "这是一段用于验证 980×680 窗口、超长中文安全说明、进度动画和取消按钮不会互相覆盖的固定调试文本；所有内容都应自然换行并保持可滚动。",
                    "This fixed debug sentence verifies that long localized safety guidance, progress animation, and cancellation actions remain readable in a 980×680 window without overlapping; all content must wrap naturally and remain scrollable."
                )
                : nil,
            onStart: {},
            onCancel: {}
        )
        .frame(width: 980, height: 680)
    }

    private var debugState: MacBenchmarkState {
        switch fixture {
        case .running, .longLocalizedText:
            .running(stage: .gpu, progress: 0.52, elapsedSeconds: 23)
        case .scored, .rawOnly:
            .completed
        }
    }

    private var debugProgress: MacBenchmarkPresentationProgress? {
        guard fixture == .running || fixture == .longLocalizedText else { return nil }
        return MacBenchmarkPresentationProgress(
            stage: .gpu,
            completedSampleCount: 9,
            totalSampleCount: 18,
            progress: 0.52,
            elapsedSeconds: 23
        )
    }

    private var debugResult: MacBenchmarkResult? {
        Self.fixtureResult(rawOnly: fixture == .rawOnly)
    }

    private var debugHistory: [MacBenchmarkResult] {
        [
            Self.fixtureResult(rawOnly: false, dateOffset: -86_400 * 7),
            Self.fixtureResult(rawOnly: true, dateOffset: -86_400 * 14),
        ].compactMap { $0 }
    }

    private static func fixtureResult(
        rawOnly: Bool,
        dateOffset: TimeInterval = 0
    ) -> MacBenchmarkResult? {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + dateOffset)
        let completedAt = startedAt.addingTimeInterval(42)
        let preflightAt = startedAt.addingTimeInterval(1)
        let postflightAt = completedAt.addingTimeInterval(-1)
        let measurements = BenchmarkComponent.allCases.enumerated().map { index, component in
            BenchmarkComponentMeasurement(
                component: component,
                unit: component == .gpu ? .millionTrianglesPerSecond : component.metricUnit,
                samples: [0.98, 1.0, 1.02].enumerated().map { sampleIndex, ratio in
                    BenchmarkComponentSample(
                        value: Double(index + 1) * 1_000 * ratio,
                        elapsedSeconds: 0.8 + Double(sampleIndex) * 0.1,
                        checksum: UInt64(index * 10 + sampleIndex + 1)
                    )
                }
            )
        }
        let environment = BenchmarkEnvironmentMetadata(
            architecture: .arm64,
            chipName: "Apple M5 Pro",
            activeProcessorCount: 18,
            physicalMemoryBytes: 48 * 1_024 * 1_024 * 1_024,
            systemDiskCapacityBytes: MacBenchmarkScoring.referenceSystemDiskCapacityBytes,
            powerSource: .acPower,
            thermalState: .nominal,
            operatingSystemVersion: "macOS 26.0",
            appVersion: "1.8.2",
            appBuild: "202607172016"
        )
        let preflight = BenchmarkPreflight(
            capturedAt: preflightAt,
            powerSource: .acPower,
            batteryPercent: 80,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            diskReliability: .verified,
            availableDiskBytes: 120_000_000_000,
            requiredDiskBytes: 2_000_000_000,
            warnings: []
        )
        let raw = MacBenchmarkRawResult(
            profile: .standard,
            workloadVersion: "mac-benchmark-standard-v6",
            startedAt: startedAt,
            completedAt: completedAt,
            environment: environment,
            preflight: preflight,
            postflight: BenchmarkPostflight(
                capturedAt: postflightAt,
                powerSource: .acPower,
                lowPowerModeEnabled: false,
                thermalState: .nominal
            ),
            capabilitySet: .all,
            measurements: measurements,
            failure: nil
        )
        if rawOnly {
            return MacBenchmarkScoring.rawOnly(rawResult: raw)
        }
        let key = BenchmarkComparisonKey(
            workloadVersion: raw.workloadVersion,
            baselineVersion: "m5-pro-v1",
            profile: raw.profile,
            architecture: raw.environment.architecture,
            capabilitySet: raw.capabilitySet
        )
        let scores = Dictionary(uniqueKeysWithValues: BenchmarkComponent.allCases.enumerated().map {
            ($0.element, 940 + Double($0.offset * 35))
        })
        return MacBenchmarkResult(
            rawResult: raw,
            comparisonKey: key,
            matchedBaselineKey: key,
            componentScores: scores,
            proposedOverallScore: 1_018
        )
    }
}
#endif
