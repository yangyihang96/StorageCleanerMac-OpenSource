import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The single public performance-test surface. Measurement and persistence are
/// app-scoped; this view only presents the current official session state.
struct BenchmarkV7DashboardView: View {
    enum HistoryBadgeStatus: Equatable {
        case cancelled
        case failed
        case completed
        case incomplete
    }

    private enum Page: Hashable {
        case benchmark
        case localBest
        case history
        case leaderboard
    }

    private enum HistoryFeedback: Equatable {
        case success(String)
        case failure(String)

        var text: String {
            switch self {
            case let .success(text), let .failure(text): text
            }
        }

        var symbol: String {
            switch self {
            case .success: "checkmark.circle"
            case .failure: "exclamationmark.triangle"
            }
        }

        var color: Color {
            switch self {
            case .success: AppDesignTokens.Palette.success
            case .failure: AppDesignTokens.Palette.warning
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.moduleTheme) private var moduleTheme
    @Environment(\.windowLayoutMetrics) private var layout
    @State private var selectedPage: Page = .benchmark
    @State private var pendingDeletionRecordID: UUID?
    @State private var historyFeedback: HistoryFeedback?
    @State private var comparisonRecordIDs: [UUID] = []

    let state: BenchmarkV7State
    let latestResult: BenchmarkV7Result?
    let history: [BenchmarkV7Result]
    let localBestResult: BenchmarkV7Result?
    let localBestResultsByCategory: [BenchmarkV7Category: BenchmarkV7Result]
    let currentScoringVersion: String
    let historyStatus: BenchmarkV7HistoryLoadStatus
    @ObservedObject var leaderboardStore: BenchmarkV7LeaderboardStore
    let preflight: BenchmarkV7PreflightReport?
    let isPreflighting: Bool
    let canStart: Bool
    let explanation: String?
    let onStart: () -> Void
    let onCancel: () -> Void
    let onDeleteHistoryRecord: (UUID) -> Void
    let onExportHistoryRecord: (UUID) -> Data?
    var liveTelemetry: [MenuBarTelemetryPoint] = []

    private let officialPlan = OfficialBenchmarkPlan.current
    private var accent: Color { moduleTheme.accent }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppDesignTokens.Layout.pageSpacing) {
                pagePicker
                pageContent
            }
            .padding(AppDesignTokens.Layout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedPage == .benchmark && !isRunning {
                benchmarkStatusBar.padding(.horizontal, AppDesignTokens.Layout.pagePadding)
            }
        }
        .environment(\.scrollSafeGlass, true)
        .transaction { transaction in
            transaction.animation = reduceMotion ? nil : transaction.animation
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            L10n.text("删除这条本机记录？", "Delete this local record?"),
            isPresented: Binding(
                get: { pendingDeletionRecordID != nil },
                set: { if !$0 { pendingDeletionRecordID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                L10n.text("删除记录", "Delete record"),
                role: .destructive
            ) {
                if let recordID = pendingDeletionRecordID {
                    onDeleteHistoryRecord(recordID)
                }
                pendingDeletionRecordID = nil
            }
        } message: {
            Text(L10n.text(
                "删除后无法从应用内恢复；导出的 JSON 文件不会受影响。",
                "This cannot be restored in the app; any exported JSON stays unchanged."
            ))
        }
    }

    private var pagePicker: some View {
        Picker(L10n.text("性能测试页面", "Performance benchmark page"), selection: $selectedPage) {
            Text(L10n.text("性能测试", "Performance test"))
                .tag(Page.benchmark)
            Text(L10n.text("本机最佳", "Local best"))
                .tag(Page.localBest)
            Text(L10n.text("历史记录", "History"))
                .tag(Page.history)
            Text(L10n.text("全球排行", "Global ranking"))
                .tag(Page.leaderboard)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(L10n.text("性能测试页面", "Performance benchmark page"))
        .accessibilityHint(L10n.text(
            "切换页面不会取消正在运行的性能测试。",
            "Changing pages does not cancel a running benchmark."
        ))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .benchmark:
            if isRunning {
                runningCard
            } else {
                benchmarkLanding
            }
        case .localBest:
            localBestPage
        case .history:
            historyPage
        case .leaderboard:
            BenchmarkV7LeaderboardSection(
                store: leaderboardStore,
                results: ([latestResult] + history.map(Optional.some)).compactMap { $0 }
            )
        }
    }

    private var benchmarkLanding: some View {
        VStack(spacing: AppDesignTokens.Spacing.large) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppDesignTokens.Spacing.large) {
                    actionCard
                        .frame(minWidth: 340, idealWidth: 410, maxWidth: 440)
                    benchmarkMonitor
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
                VStack(spacing: AppDesignTokens.Spacing.large) {
                    actionCard
                    benchmarkMonitor
                }
            }
        }
    }

    private var benchmarkMonitor: some View {
        BenchmarkSystemMonitor(
            telemetryPoints: liveTelemetry,
            accent: accent,
            chartHeight: layout.isShort ? 200 : 250
        )
    }

    private var benchmarkStatusBar: some View {
        HStack(spacing: AppDesignTokens.Spacing.section) {
            Label(
                visibleLatestResult == nil
                    ? L10n.text("完成测试后生成结果", "Complete the test to generate a result")
                    : L10n.text("上一次完整结果仍保留", "The last complete result is preserved"),
                systemImage: "info.circle"
            )
            .foregroundStyle(accent)

            Spacer(minLength: AppDesignTokens.Spacing.medium)

            Label(
                L10n.text("测试可随时取消", "The test can be cancelled at any time"),
                systemImage: "checkmark.shield.fill"
            )
            .foregroundStyle(AppDesignTokens.Palette.success)
        }
        .font(AppDesignTokens.Typography.metadata)
        .padding(.horizontal, AppDesignTokens.Spacing.section)
        .frame(maxWidth: .infinity, minHeight: layout.footerHeight)
        .fullBleedSection()
    }

    private var actionCard: some View {
        ContentPanel {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                benchmarkCategoryOverview

                Divider()

                Text(L10n.text(
                    "7 个阶段自动完成，预计约 \(durationText(Double(officialPlan.expectedMaximumDurationSeconds)))",
                    "7 stages run automatically, expected to take about \(durationText(Double(officialPlan.expectedMaximumDurationSeconds)))"
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup(L10n.text("7 个阶段说明", "About the 7 stages")) {
                    benchmarkScopeDetails
                }
                .font(AppDesignTokens.Typography.metadata)

                if let explanation {
                    Label(explanation, systemImage: "exclamationmark.triangle")
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state.phase == .cancelled {
                    Label(
                        L10n.text("本次测试已取消；上一次完整结果仍保留。", "This test was cancelled; the last complete result is kept."),
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                }

                if let preflightWarning = preflightWarning {
                    Label(preflightWarning, systemImage: "info.circle")
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: onStart) {
                    Label(actionTitle, systemImage: "speedometer")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(accent)
                .disabled(!canStart || isRunning)
                .accessibilityHint(L10n.text(
                    "开始后将自动检查环境并运行全部项目",
                    "Starts the automatic environment check and all benchmark stages"
                ))
            }
            .padding(AppDesignTokens.Layout.sectionPadding)
        }
    }

    private var benchmarkCategoryOverview: some View {
        let result = visibleLatestResult
        return VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
                ForEach(BenchmarkV7Category.corePerformance, id: \.self) { category in
                    let score = result?.coreScore?.categoryScores[category]?.score
                    VStack(spacing: AppDesignTokens.Spacing.small) {
                        Image(systemName: categorySystemImage(category))
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(accent)
                            .frame(height: 40)
                            .accessibilityHidden(true)
                        Text(categoryTitle(category))
                            .font(AppDesignTokens.Typography.secondary)
                        Text(scoreText(score))
                            .font(.system(size: 24, weight: .medium))
                            .monospacedDigit()
                        Text(validScore(score) != nil
                            ? L10n.text("上次分项", "Last score")
                            : result == nil
                                ? L10n.text("尚未测试", "Not tested")
                                : L10n.text("未记录", "Unavailable"))
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }

            if let result {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Text(L10n.text("上次完整记录", "Last complete record"))
                    Text(historyTimestamp(result), format: .dateTime.year().month().day().hour().minute())
                }
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, AppDesignTokens.Spacing.small)
    }

    private func categorySystemImage(_ category: BenchmarkV7Category) -> String {
        switch category {
        case .cpu: "cpu"
        case .gpu: "square.3.layers.3d"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .display: "display"
        case .sustained: "waveform.path.ecg"
        }
    }

    private var benchmarkScopeDetails: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Text(L10n.text("1. CPU：单核与多核工作负载", "1. CPU: single and multi-core workloads"))
            Text(L10n.text("2. GPU：图形渲染与计算", "2. GPU: graphics rendering and compute"))
            Text(L10n.text("3. 内存：带宽与延迟", "3. Memory: bandwidth and latency"))
            Text(L10n.text("4. 存储：连续读写与随机访问", "4. Storage: sequential I/O and random access"))
            Text(L10n.text("5. 显示：刷新节奏", "5. Display: frame cadence"))
            Text(L10n.text("6. 持续检查：CPU 与 GPU 负载稳定性", "6. Sustained check: CPU and GPU load stability"))
            Text(L10n.text("7. 校验评分：核对采样并保存结果", "7. Validation: verify samples, score, and save"))
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, AppDesignTokens.Spacing.small)
    }

    private var runningCard: some View {
        BenchmarkV7RunProgressView(
            state: state,
            isPreflighting: isPreflighting,
            accent: accent,
            canCancel: Self.allowsCancellation(during: state.phase),
            onCancel: onCancel,
            telemetryPoints: liveTelemetry
        )
        .padding(AppDesignTokens.Layout.sectionPadding)
        .fullBleedSection()
        .accessibilityElement(children: .contain)
    }

    private var latestResultCard: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            Label(L10n.text("最新结果", "Latest result"), systemImage: "chart.bar.xaxis")
                .font(AppDesignTokens.Typography.cardTitle)
                .foregroundStyle(accent)

            if let result = visibleLatestResult {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.coreScore?.overallScore.formatted(.number.precision(.fractionLength(0))) ?? "—")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(L10n.text("综合分", "Overall score"))
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let completedAt = result.completedAt {
                        Text(completedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }

                if let profile = BenchmarkV7PerformanceProfile(coreScore: result.coreScore) {
                    BenchmarkV7PerformanceSummaryView(profile: profile, accent: accent)
                }

                DisclosureGroup(L10n.text("原始指标与技术详情", "Raw metrics and technical details")) {
                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170), spacing: AppDesignTokens.Spacing.small)],
                            spacing: AppDesignTokens.Spacing.small
                        ) {
                            ForEach(BenchmarkV7Category.corePerformance + [.display, .sustained], id: \.self) { category in
                                metricSummary(for: category, result: result)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Protocol \(result.versions.planVersion)")
                            Text("Workload \(result.versions.workloadVersion)")
                        }
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                }
                .font(AppDesignTokens.Typography.metadata)
            } else {
                Text(L10n.text(
                    "尚未完成当前版本的性能测试",
                    "No complete result for the current benchmark version yet"
                ))
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
            }
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
        .fullBleedSection()
    }

    private func metricSummary(
        for category: BenchmarkV7Category,
        result: BenchmarkV7Result
    ) -> some View {
        let metrics = result.metrics.filter { $0.manifest.category == category }
        let detail = metrics.isEmpty
            ? L10n.text("未记录", "Unavailable")
            : metrics.prefix(2).map { metric in
                "\(metricTitle(metric.manifest.id)) \(metric.statistics.median.formatted(.number.precision(.fractionLength(1)))) \(metric.manifest.unit)"
            }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 3) {
            Text(categoryTitle(category))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var localBestPage: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            Label(L10n.text("本机最佳", "Local best"), systemImage: "trophy")
                .font(AppDesignTokens.Typography.cardTitle)
                .foregroundStyle(accent)

            Text(L10n.text(
                "本机安全保存、成功完成且与当前评分版本可比的记录。",
                "Safely saved, successfully completed local records comparable with the current scoring version."
            ))
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let result = localBestResult {
                HStack(alignment: .firstTextBaseline) {
                    Text(scoreText(result.coreScore?.overallScore))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(L10n.text("综合最佳", "Best overall"))
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(historyTimestamp(result), format: .dateTime.year().month().day().hour().minute())
                        if let duration = resultDurationText(result) {
                            Text(L10n.text("用时 \(duration)", "Duration \(duration)"))
                        }
                    }
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                }

                Text(L10n.text(
                    "评分算法：\(currentScoringVersion)",
                    "Scoring algorithm: \(currentScoringVersion)"
                ))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), spacing: AppDesignTokens.Spacing.small)],
                    spacing: AppDesignTokens.Spacing.small
                ) {
                    ForEach(BenchmarkV7Category.corePerformance, id: \.self) { category in
                        localBestCategoryCard(category)
                    }
                }

                DisclosureGroup(L10n.text("最佳记录详情", "Best record details")) {
                    historyDetails(result)
                }
                .font(AppDesignTokens.Typography.metadata)
            } else {
                ContentUnavailableView(
                    L10n.text("尚无可比较的本机最佳成绩", "No comparable local best result"),
                    systemImage: "trophy",
                    description: Text(L10n.text(
                        "完成并安全保存一次当前版本的性能测试后，这里会显示最佳成绩。",
                        "Complete and safely save a current-version benchmark to see a best result here."
                    ))
                )
            }
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
        .fullBleedSection()
    }

    private func localBestCategoryCard(_ category: BenchmarkV7Category) -> some View {
        let result = localBestResultsByCategory[category]
        let score = result?.coreScore?.categoryScores[category]?.score
        return VStack(alignment: .leading, spacing: 3) {
            Text(categoryTitle(category))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            Text(scoreText(score))
                .font(AppDesignTokens.Typography.cardTitle)
                .monospacedDigit()
            if let result {
                Text(historyTimestamp(result), format: .dateTime.year().month().day())
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.text("暂无结果", "No result"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("本机历史", "Local history"), systemImage: "clock.arrow.circlepath")
                    .font(AppDesignTokens.Typography.cardTitle)
                    .foregroundStyle(accent)
                Spacer()
                Text(L10n.text("最新在前", "Newest first"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.text(
                "仅保存在本机；失败或取消的记录不会显示为成功成绩。",
                "Records stay on this Mac; failed or cancelled runs are never shown as successful scores."
            ))
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            #if DEBUG || STORAGE_CLEANER_BETA
            if MiniWindowDemoData.isEnabled {
                Text(L10n.text(
                    "本机实际测试记录，与 FIXTURE 固定监控数据无关。",
                    "Actual local benchmark records, independent of FIXTURE monitor samples."
                ))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            }
            #endif

            if let message = historyStatusMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let historyFeedback {
                Label(historyFeedback.text, systemImage: historyFeedback.symbol)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(historyFeedback.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            comparisonCard

            if chronologicalHistory.isEmpty {
                ContentUnavailableView(
                    L10n.text("暂无本机历史记录", "No local history yet"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(L10n.text(
                        "完成、失败或取消的测试记录会在这里按时间显示。",
                        "Completed, failed, and cancelled benchmark records appear here over time."
                    ))
                )
            } else {
                ForEach(Array(chronologicalHistory.enumerated()), id: \.offset) { entry in
                    historyCard(entry.element)
                }
            }
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
        .fullBleedSection()
    }

    private func historyCard(_ result: BenchmarkV7Result) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(historyTimestamp(result), format: .dateTime.year().month().day().hour().minute())
                        .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                    Text(L10n.text(
                        "协议 \(result.versions.planVersion) · \(result.versions.scoringVersion)",
                        "Protocol \(result.versions.planVersion) · \(result.versions.scoringVersion)"
                    ))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: AppDesignTokens.Spacing.small)
                historyStatusBadge(result)
            }

            if let failure = result.failure {
                Label(failureTitle(failure), systemImage: "exclamationmark.triangle")
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let score = validScore(result.coreScore?.overallScore) {
                HStack(alignment: .firstTextBaseline) {
                    Text(scoreText(score))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(L10n.text("综合分", "Overall score"))
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Text(L10n.text("本次未生成综合分", "No overall score was generated for this run"))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }

            if result.failure == nil, !result.isCurrentComparableOfficialResult {
                Label(L10n.text(
                    "此记录已保留，但与当前完整评分版本不直接可比，不参与本机最佳或结果比较。",
                    "This record is preserved but is not directly comparable with the current full scoring version, so it is excluded from local best and comparison."
                ), systemImage: "arrow.triangle.branch")
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AppDesignTokens.Spacing.small) {
                if let recordID = result.recordID,
                   result.isCurrentComparableOfficialResult {
                    Button {
                        toggleComparison(recordID)
                    } label: {
                        Label(
                            comparisonRecordIDs.contains(recordID)
                                ? L10n.text("已选比较", "Selected")
                                : L10n.text("选择比较", "Compare"),
                            systemImage: comparisonRecordIDs.contains(recordID)
                                ? "checkmark.circle"
                                : "arrow.left.arrow.right"
                        )
                    }
                    .appButtonChrome(.secondary)
                }

                Spacer()

                if let recordID = result.recordID {
                    Button {
                        exportHistoryRecord(recordID)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .appButtonChrome(.icon)
                    .controlSize(.small)
                    .help(L10n.text("导出 JSON", "Export JSON"))
                    .accessibilityLabel(L10n.text("导出 JSON", "Export JSON"))

                    Button(role: .destructive) {
                        pendingDeletionRecordID = recordID
                    } label: {
                        Image(systemName: "trash")
                    }
                    .appButtonChrome(.icon)
                    .controlSize(.small)
                    .disabled(isRunning)
                    .help(L10n.text("删除本机记录", "Delete local record"))
                    .accessibilityLabel(L10n.text("删除本机记录", "Delete local record"))
                }
            }

            DisclosureGroup(L10n.text("查看详情", "View details")) {
                historyDetails(result)
            }
            .font(AppDesignTokens.Typography.metadata)
        }
        .padding(AppDesignTokens.Spacing.medium)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var comparisonCard: some View {
        let results = selectedComparisonResults
        if results.count == 2 {
            comparisonCard(first: results[0], second: results[1])
        }
    }

    private func comparisonCard(
        first: BenchmarkV7Result,
        second: BenchmarkV7Result
    ) -> some View {
        let firstScore = first.coreScore?.overallScore ?? 0
        let secondScore = second.coreScore?.overallScore ?? 0
        return VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(L10n.text("结果比较", "Result comparison"), systemImage: "arrow.left.arrow.right")
                .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                .foregroundStyle(accent)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("第一条", "First"))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                    Text(scoreText(firstScore))
                        .font(AppDesignTokens.Typography.cardTitle)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L10n.text("第二条", "Second"))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                    Text(scoreText(secondScore))
                        .font(AppDesignTokens.Typography.cardTitle)
                        .monospacedDigit()
                }
            }

            Text(L10n.text(
                "综合分变化：\(signedScoreText(secondScore - firstScore))",
                "Overall score change: \(signedScoreText(secondScore - firstScore))"
            ))
            .font(AppDesignTokens.Typography.secondary)
            .monospacedDigit()

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: AppDesignTokens.Spacing.small)],
                spacing: AppDesignTokens.Spacing.small
            ) {
                ForEach(BenchmarkV7Category.corePerformance, id: \.self) { category in
                    if let firstCategory = first.coreScore?.categoryScores[category]?.score,
                       let secondCategory = second.coreScore?.categoryScores[category]?.score,
                       validScore(firstCategory) != nil,
                       validScore(secondCategory) != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(categoryTitle(category))
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(.secondary)
                            Text(signedScoreText(secondCategory - firstCategory))
                                .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                                .monospacedDigit()
                        }
                        .padding(AppDesignTokens.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
        .padding(AppDesignTokens.Spacing.medium)
        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func historyDetails(_ result: BenchmarkV7Result) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("版本", "Versions"))
                    .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                detailRow(L10n.text("协议", "Protocol"), result.versions.planVersion)
                detailRow(L10n.text("工作负载", "Workload"), result.versions.workloadVersion)
                detailRow(L10n.text("评分", "Scoring"), result.versions.scoringVersion)
                detailRow(L10n.text("参考集", "Reference set"), result.versions.referenceSetVersion)
                if let duration = resultDurationText(result) {
                    detailRow(L10n.text("测试时长", "Test duration"), duration)
                }
            }

            if let environment = result.environment {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("测试环境", "Test environment"))
                        .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                    if let computerName = result.hardwareProfile?.computerName {
                        detailRow(L10n.text("电脑名称", "Computer name"), computerName)
                    }
                    if let computerModel = result.hardwareProfile?.computerModel {
                        detailRow(L10n.text("电脑型号", "Computer model"), computerModel)
                    }
                    if let modelIdentifier = result.hardwareProfile?.modelIdentifier {
                        detailRow(L10n.text("型号标识", "Model identifier"), modelIdentifier)
                    }
                    detailRow(L10n.text("芯片", "Chip"), environment.chipName)
                    if let gpuCoreCount = result.hardwareProfile?.gpuCoreCount {
                        detailRow(
                            L10n.text("GPU 核心数", "GPU cores"),
                            "\(gpuCoreCount)"
                        )
                    }
                    detailRow(
                        L10n.text("处理器", "Processors"),
                        "\(environment.activeProcessorCount)"
                    )
                    detailRow(
                        L10n.text("内存", "Memory"),
                        ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: environment.physicalMemoryBytes),
                            countStyle: .file
                        )
                    )
                    if let systemDiskCapacityBytes = environment.systemDiskCapacityBytes {
                        detailRow(
                            L10n.text("系统磁盘容量", "System disk capacity"),
                            ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: systemDiskCapacityBytes),
                                countStyle: .file
                            )
                        )
                    }
                    if let storageModel = result.hardwareProfile?.storageModel {
                        detailRow(L10n.text("存储型号", "Storage model"), storageModel)
                    }
                    detailRow(L10n.text("电源", "Power"), powerSourceTitle(environment.powerSource))
                    detailRow(L10n.text("热状态", "Thermal"), thermalStateTitle(environment.thermalState))
                    detailRow(L10n.text("系统", "System"), environment.operatingSystemVersion)
                    detailRow(
                        L10n.text("应用", "App"),
                        "\(environment.appVersion) (\(environment.appBuild))"
                    )
                }
            } else {
                Text(L10n.text(
                    "这条早期记录没有保存完整测试环境。",
                    "This early record did not retain a complete test environment."
                ))
                .foregroundStyle(.secondary)
            }

            if let executions = result.workloadExecutions, !executions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("子测试记录", "Subtest log"))
                        .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                    ForEach(executions.indices, id: \.self) { index in
                        let execution = executions[index]
                        detailRow(
                            workloadExecutionTitle(execution),
                            workloadExecutionDetail(execution)
                        )
                        if let failureReason = execution.failureReason {
                            Text("↳ \(failureReason)")
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(AppDesignTokens.Palette.warning)
                        }
                    }
                }
            }

            if !result.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("指标", "Metrics"))
                        .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                    ForEach(Array(result.metrics.enumerated()), id: \.offset) { entry in
                        let metric = entry.element
                        detailRow(
                            metricTitle(metric.manifest.id),
                            "\(metric.statistics.median.formatted(.number.precision(.fractionLength(2)))) \(metric.manifest.unit)"
                        )
                    }
                }
            }

            if !result.runtimeWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("运行提示", "Runtime notes"))
                        .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                    ForEach(Array(result.runtimeWarnings.enumerated()), id: \.offset) { entry in
                        Text("• \(entry.element)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.small) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: AppDesignTokens.Spacing.small)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func historyStatusBadge(_ result: BenchmarkV7Result) -> some View {
        let status: (text: String, color: Color) = switch Self.historyBadgeStatus(for: result) {
        case .cancelled:
            (L10n.text("已取消", "Cancelled"), .secondary)
        case .failed:
            (L10n.text("失败", "Failed"), AppDesignTokens.Palette.warning)
        case .completed:
            (L10n.text("已完成", "Completed"), AppDesignTokens.Palette.success)
        case .incomplete:
            (L10n.text("未完成", "Incomplete"), .secondary)
        }
        return Text(status.text)
            .font(AppDesignTokens.Typography.metadata.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.12), in: Capsule())
    }

    static func historyBadgeStatus(for result: BenchmarkV7Result) -> HistoryBadgeStatus {
        if result.resolvedCompletionStatus == .cancelled {
            return .cancelled
        }
        if result.failure != nil {
            return .failed
        }
        if result.isComplete {
            return .completed
        }
        return .incomplete
    }

    private var chronologicalHistory: [BenchmarkV7Result] {
        history.sorted { historyTimestamp($0) > historyTimestamp($1) }
    }

    private var selectedComparisonResults: [BenchmarkV7Result] {
        comparisonRecordIDs.compactMap { recordID in
            history.first(where: { $0.recordID == recordID })
        }
        .filter(\.isCurrentComparableOfficialResult)
    }

    private var historyStatusMessage: String? {
        switch historyStatus {
        case .missing, .loaded:
            nil
        case .corrupt:
            L10n.text(
                "无法安全读取本机历史文件；原文件已保留，未覆盖或删除任何记录。",
                "The local history file could not be read safely. It was preserved and no records were overwritten or deleted."
            )
        case .failed:
            L10n.text(
                "无法安全更新本机历史记录；请稍后重试。",
                "The local history could not be updated safely. Please try again later."
            )
        }
    }

    private func toggleComparison(_ recordID: UUID) {
        if let index = comparisonRecordIDs.firstIndex(of: recordID) {
            comparisonRecordIDs.remove(at: index)
            return
        }
        if comparisonRecordIDs.count == 2 {
            comparisonRecordIDs.removeFirst()
        }
        comparisonRecordIDs.append(recordID)
    }

    private func exportHistoryRecord(_ recordID: UUID) {
        guard let data = onExportHistoryRecord(recordID) else {
            historyFeedback = .failure(L10n.text(
                "无法找到要导出的本机记录。",
                "The local record to export could not be found."
            ))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "StorageCleanerMac-Benchmark-\(recordID.uuidString.prefix(8)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            historyFeedback = .success(L10n.text(
                "已导出本机性能测试 JSON。",
                "Local benchmark JSON exported."
            ))
        } catch {
            historyFeedback = .failure(L10n.text(
                "无法写入导出文件。",
                "The export file could not be written."
            ))
        }
    }

    private func historyTimestamp(_ result: BenchmarkV7Result) -> Date {
        result.completedAt ?? result.session.startedAt
    }

    private func resultDurationText(_ result: BenchmarkV7Result) -> String? {
        guard let completedAt = result.completedAt else { return nil }
        let seconds = completedAt.timeIntervalSince(result.session.startedAt)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return durationText(seconds)
    }

    private func workloadExecutionTitle(
        _ execution: BenchmarkV7WorkloadExecutionRecord
    ) -> String {
        guard let repetition = execution.repetition else { return execution.workloadID }
        return "\(execution.workloadID) · #\(repetition)"
    }

    private func workloadExecutionDetail(
        _ execution: BenchmarkV7WorkloadExecutionRecord
    ) -> String {
        let status = switch execution.status {
        case .completed: L10n.text("完成", "Completed")
        case .failed: L10n.text("失败", "Failed")
        case .cancelled: L10n.text("已取消", "Cancelled")
        case .timedOut: L10n.text("已超时", "Timed out")
        }
        let duration = execution.elapsedSeconds < 10
            ? "\(execution.elapsedSeconds.formatted(.number.precision(.fractionLength(2))))s"
            : durationText(execution.elapsedSeconds)
        let start = execution.startedAt.formatted(date: .omitted, time: .standard)
        return "\(status) · \(duration) · \(start)"
    }

    private func validScore(_ score: Double?) -> Double? {
        guard let score, score.isFinite, score > 0 else { return nil }
        return score
    }

    private func scoreText(_ score: Double?) -> String {
        guard let score = validScore(score) else { return "—" }
        return score.formatted(.number.precision(.fractionLength(0)))
    }

    private func signedScoreText(_ score: Double) -> String {
        guard score.isFinite else { return "—" }
        let sign = score > 0 ? "+" : ""
        return "\(sign)\(score.formatted(.number.precision(.fractionLength(0))))"
    }

    private func failureTitle(_ failure: BenchmarkV7Failure) -> String {
        switch failure {
        case .alreadyRunning:
            L10n.text("已有测试正在运行", "Another benchmark was already running")
        case .cancelled:
            L10n.text("测试已取消", "Benchmark cancelled")
        case let .timedOut(context):
            L10n.text(
                "测试超时：\(context.detail)",
                "Benchmark timed out: \(context.detail)"
            )
        case let .restartRequired(context):
            L10n.text(
                "操作未确认停止（\(context.detail)）。安全隔离仍保留，请重启应用后再测试。",
                "The operation did not confirm termination (\(context.detail)). Safety quarantine remains active; restart the app before running another test."
            )
        case .preflightBlocked:
            L10n.text("环境检查未通过", "Preflight was blocked")
        case let .unsupportedCategory(category):
            L10n.text(
                "不支持的测试项目：\(categoryTitle(category))",
                "Unsupported category: \(categoryTitle(category))"
            )
        case let .invalidMeasurement(detail):
            L10n.text("无效测量：\(detail)", "Invalid measurement: \(detail)")
        case let .validationFailed(detail):
            L10n.text("校验失败：\(detail)", "Validation failed: \(detail)")
        case .persistenceFailed:
            L10n.text("结果未能安全保存", "Result could not be saved safely")
        case .internalFailure:
            L10n.text("测试内部失败", "Internal benchmark failure")
        }
    }

    private func powerSourceTitle(_ source: BenchmarkPowerSource) -> String {
        switch source {
        case .acPower: L10n.text("外接电源", "AC power")
        case .battery: L10n.text("电池", "Battery")
        case .unknown: L10n.text("未知", "Unknown")
        }
    }

    private func thermalStateTitle(_ state: BenchmarkThermalState) -> String {
        switch state {
        case .nominal: L10n.text("正常", "Nominal")
        case .fair: L10n.text("一般", "Fair")
        case .serious: L10n.text("严重", "Serious")
        case .critical: L10n.text("临界", "Critical")
        case .unknown: L10n.text("未知", "Unknown")
        }
    }

    private var visibleLatestResult: BenchmarkV7Result? {
        let candidates = ([latestResult] + history.map(Optional.some)).compactMap { $0 }
            .filter(\.isCurrentComparableOfficialResult)
        return candidates.max { lhs, rhs in
            historyTimestamp(lhs) < historyTimestamp(rhs)
        }
    }

    private var isRunning: Bool {
        state.phase.isActive || isPreflighting
    }

    static func allowsCancellation(during phase: BenchmarkV7Phase) -> Bool {
        switch phase {
        case .preflighting, .ready, .preparing, .warmingUp, .calibrating,
             .running, .validating, .aggregating, .scoring:
            true
        case .persisting, .cancelling, .idle, .cancelled, .failed, .completed:
            false
        }
    }

    private var actionTitle: String {
        if isRunning {
            return L10n.text("正在进行性能测试", "Running performance test")
        }
        return visibleLatestResult == nil
            ? L10n.text("开始性能测试", "Start performance test")
            : L10n.text("重新测试", "Run again")
    }

    private var preflightWarning: String? {
        guard let preflight, !preflight.warnings.isEmpty else { return nil }
        return preflight.warnings.map(\.detail).joined(separator: " · ")
    }

    private func categoryTitle(_ category: BenchmarkV7Category) -> String {
        switch category {
        case .cpu: L10n.text("CPU", "CPU")
        case .gpu: L10n.text("GPU", "GPU")
        case .memory: L10n.text("内存", "Memory")
        case .storage: L10n.text("存储", "Storage")
        case .display: L10n.text("显示体验", "Display experience")
        case .sustained: L10n.text("持续检查", "Sustained check")
        }
    }

    private func metricTitle(_ id: String) -> String {
        switch id {
        case "cpu.single.mixed": L10n.text("单核", "Single")
        case "cpu.multi.particle": L10n.text("多核", "Multi")
        case "gpu.graphics.offscreen": L10n.text("图形", "Graphics")
        case "gpu.compute.fp16": L10n.text("计算", "Compute")
        case "memory.copy.bandwidth": L10n.text("复制", "Copy")
        case "memory.triad.bandwidth": L10n.text("带宽", "Bandwidth")
        case "memory.pointer-chase.latency": L10n.text("延迟", "Latency")
        case "storage.sequential.read": L10n.text("顺序读", "Seq read")
        case "storage.sequential.write": L10n.text("顺序写", "Seq write")
        case "storage.random.read.qd1.iops", "storage.random.read.qd16.iops":
            L10n.text("随机读 IOPS", "Random read IOPS")
        case "storage.random.read.qd1.latency.p50.ns",
             "storage.random.read.qd1.latency.p95.ns",
             "storage.random.read.qd16.latency.p50.ns",
             "storage.random.read.qd16.latency.p95.ns":
            L10n.text("随机读延迟", "Random read latency")
        case "storage.random.write.qd1.iops", "storage.random.write.qd16.iops":
            L10n.text("随机写 IOPS", "Random write IOPS")
        case "storage.random.write.qd1.latency.p50.ns",
             "storage.random.write.qd1.latency.p95.ns",
             "storage.random.write.qd16.latency.p50.ns",
             "storage.random.write.qd16.latency.p95.ns":
            L10n.text("随机写延迟", "Random write latency")
        case "display.cadence.jitter.ms": L10n.text("抖动", "Jitter")
        case "display.cadence.p50.ms": L10n.text("P50", "P50")
        case "display.cadence.p95.ms": L10n.text("P95", "P95")
        case "display.cadence.p99.ms": L10n.text("P99", "P99")
        case "display.effective-fps": L10n.text("有效帧率", "FPS")
        case "sustained.cpu.multi": L10n.text("CPU 持续", "CPU sustained")
        case "sustained.gpu.graphics": L10n.text("GPU 持续", "GPU sustained")
        default: L10n.text("指标", "Metric")
        }
    }

    private func durationText(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let minutes = rounded / 60
        let remainder = rounded % 60
        if minutes > 0 {
            return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
        }
        return "\(remainder)s"
    }
}
