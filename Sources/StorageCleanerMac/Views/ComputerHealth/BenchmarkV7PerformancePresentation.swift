import SwiftUI

struct BenchmarkV7PerformanceProfile: Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        let category: BenchmarkV7Category
        let ratio: Double
        let score: Double

        var id: BenchmarkV7Category { category }
    }

    let items: [Item]

    init?(coreScore: BenchmarkV7CoreScore?) {
        guard let coreScore else { return nil }
        let items = BenchmarkV7Category.corePerformance.compactMap { category -> Item? in
            guard let value = coreScore.categoryScores[category],
                  value.ratio.isFinite,
                  value.ratio > 0,
                  value.score.isFinite,
                  value.score > 0
            else {
                return nil
            }
            return Item(category: category, ratio: value.ratio, score: value.score)
        }
        guard items.count == BenchmarkV7Category.corePerformance.count else { return nil }
        self.items = items
    }

    var strongest: Item { items.max(by: { $0.ratio < $1.ratio })! }
    var weakest: Item { items.min(by: { $0.ratio < $1.ratio })! }

    var relativeSpread: Double {
        max(0, strongest.ratio / weakest.ratio - 1)
    }

    var isBalanced: Bool { relativeSpread <= 0.12 }

    var scaleMaximum: Double {
        max(1.15, strongest.ratio * 1.08)
    }
}

struct BenchmarkV7PerformanceSummaryView: View {
    let profile: BenchmarkV7PerformanceProfile
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
                insight(
                    title: L10n.text("相对强项", "Relative strength"),
                    item: profile.strongest,
                    symbol: "arrow.up.right.circle.fill",
                    color: AppDesignTokens.Palette.success
                )

                Divider()

                if profile.isBalanced {
                    balancedInsight
                } else {
                    insight(
                        title: L10n.text("相对短板", "Relative weakness"),
                        item: profile.weakest,
                        symbol: "arrow.down.right.circle.fill",
                        color: AppDesignTokens.Palette.warning
                    )
                }
            }

            VStack(spacing: AppDesignTokens.Spacing.small) {
                ForEach(profile.items) { item in
                    performanceRow(item)
                }
            }

            Text(L10n.text(
                "强弱按同一 V7 参考基准下的四项结果比较，仅用于定位性能侧重，不代表硬件故障。",
                "Strengths and weaknesses compare the four results against the same V7 reference. They show performance emphasis, not hardware faults."
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func insight(
        title: String,
        item: BenchmarkV7PerformanceProfile.Item,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                Text(categoryTitle(item.category))
                    .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                Text(referenceText(item.ratio))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var balancedInsight: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: "equal.circle.fill")
                .foregroundStyle(accent)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("整体均衡", "Balanced overall"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                Text(L10n.text("四项差距较小", "Small four-category gap"))
                    .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                Text(L10n.text(
                    "最大差距 " + percent(profile.relativeSpread),
                    "Largest gap " + percent(profile.relativeSpread)
                ))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func performanceRow(_ item: BenchmarkV7PerformanceProfile.Item) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Label(categoryTitle(item.category), systemImage: categorySymbol(item.category))
                    .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                Spacer()
                Text(item.score.formatted(.number.precision(.fractionLength(0))))
                    .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                    .monospacedDigit()
                Text(referenceText(item.ratio))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: item.ratio, total: profile.scaleMaximum)
                .tint(rowColor(item))
        }
        .accessibilityElement(children: .combine)
    }

    private func rowColor(_ item: BenchmarkV7PerformanceProfile.Item) -> Color {
        if item.category == profile.strongest.category {
            return AppDesignTokens.Palette.success
        }
        if !profile.isBalanced, item.category == profile.weakest.category {
            return AppDesignTokens.Palette.warning
        }
        return accent
    }

    private func referenceText(_ ratio: Double) -> String {
        let difference = ratio - 1
        if difference >= 0.05 {
            return L10n.text(
                "高于 V7 基准 " + percent(difference),
                percent(difference) + " above V7 reference"
            )
        }
        if difference <= -0.05 {
            return L10n.text(
                "低于 V7 基准 " + percent(-difference),
                percent(-difference) + " below V7 reference"
            )
        }
        return L10n.text("接近 V7 基准", "Near V7 reference")
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

struct BenchmarkV7RunProgressView: View {
    private enum Stage: Int, CaseIterable, Identifiable {
        case cpu
        case gpu
        case memory
        case storage
        case extensions
        case validation

        var id: Self { self }

        var title: String {
            switch self {
            case .cpu: L10n.text("CPU", "CPU")
            case .gpu: L10n.text("GPU", "GPU")
            case .memory: L10n.text("内存", "Memory")
            case .storage: L10n.text("存储", "Storage")
            case .extensions: L10n.text("扩展", "Extensions")
            case .validation: L10n.text("保存", "Save")
            }
        }

        var category: BenchmarkV7Category? {
            switch self {
            case .cpu: .cpu
            case .gpu: .gpu
            case .memory: .memory
            case .storage: .storage
            case .extensions, .validation: nil
            }
        }
    }

    private enum StageStatus {
        case waiting
        case running
        case completed
    }

    @Environment(\.featureCardPresentation) private var cardPresentation
    let state: BenchmarkV7State
    let isPreflighting: Bool
    let accent: Color
    let canCancel: Bool
    let onCancel: () -> Void

    /// Review P2-3: the live monitor is no longer stacked below the progress
    /// at a fixed 330 pt. The dashboard places it where the landing page has
    /// it (`BenchmarkLandingLayout`), so it keeps its place and size when a
    /// test starts.
    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            RuntimeInlineStatus(
                state: state.phase == .cancelling ? .stopping : .running,
                title: phaseTitle,
                detail: currentTaskTitle
            )
            HStack(spacing: 12) {
                if let repetition = state.repetition, repetition > 0 {
                    Text(L10n.text("第 \(ByteFormat.count(repetition)) 次采样", "Sample \(ByteFormat.count(repetition))"))
                        .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let progressValue {
                    Text(progressValue.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 23, weight: .semibold)).monospacedDigit().foregroundStyle(accent)
                }
                if canCancel {
                    Button(role: .cancel, action: onCancel) {
                        Label(L10n.text("取消测试", "Cancel Test"), systemImage: "stop.circle")
                    }
                    .appButtonChrome(.secondary)
                    .disabled(state.phase == .cancelling)
                }
            }
            if let progressValue { ProgressView(value: progressValue).tint(accent) }
            stageGrid
            Text(stageCaption)
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .contain)
    }

    /// The template keeps all six stages in one row. Legacy dashboards keep
    /// their approved wrapping layout; full labels remain in help and AX.
    var stageGrid: some View {
        Group {
            if cardPresentation == .running {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Stage.allCases) { stage in stageView(stage) }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    stageGrid(columns: Array(repeating: GridItem(.flexible(minimum: 58), spacing: 8),
                                             count: Stage.allCases.count))
                        .frame(minWidth: CGFloat(Stage.allCases.count) * 58
                            + CGFloat(Stage.allCases.count - 1) * 8)
                    stageGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)])
                }
            }
        }
#if DEBUG
        .layoutProbe("benchmark.stages")
#endif
    }

    private func stageGrid(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Stage.allCases) { stage in stageView(stage) }
        }
    }

    private func stageView(_ stage: Stage) -> some View {
        let status = stageStatus(stage)
        return VStack(spacing: 5) {
            Image(systemName: stageSymbol(status))
                .foregroundStyle(stageColor(status))
                .font(.system(size: 14, weight: .semibold))
            Text(stage.title)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(status == .waiting ? .secondary : .primary)
                .lineLimit(cardPresentation == .running ? 1 : nil)
                .help(stage.title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
#if DEBUG
        .layoutProbe("benchmark.stage.\(stage.rawValue)")
#endif
    }

    var phaseTitle: String {
        if isPreflighting { return L10n.text("正在检查环境", "Checking environment") }
        return switch state.phase {
        case .preflighting: L10n.text("正在检查环境", "Checking environment")
        case .ready, .preparing: L10n.text("正在准备测试", "Preparing test")
        case .warmingUp, .calibrating: L10n.text("正在预热", "Warming up")
        case .running: L10n.text("正在进行性能测试", "Running performance test")
        case .validating, .aggregating, .scoring:
            L10n.text("正在校验原始结果", "Validating raw results")
        case .persisting: L10n.text("正在保存结果", "Saving result")
        case .cancelling: L10n.text("正在取消测试", "Stopping test")
        case .idle, .cancelled, .failed, .completed:
            L10n.text("性能测试", "Performance test")
        }
    }

    var currentTaskTitle: String {
        if isPreflighting || state.phase == .preflighting {
            return L10n.text("检查电源、温度、内存与存储环境", "Checking power, temperature, memory, and storage")
        }
        switch state.phase {
        case .validating: return L10n.text("核对采样完整性", "Checking sample integrity")
        case .aggregating: return L10n.text("汇总测试结果", "Aggregating results")
        case .scoring: return L10n.text("计算综合分与各项得分", "Calculating overall and category scores")
        case .persisting: return L10n.text("安全保存本次结果", "Safely saving this result")
        case .cancelling: return L10n.text("等待当前工作负载安全停止", "Waiting for the current workload to stop safely")
        default: break
        }

        if let id = state.workloadID,
           MSeriesRunItemTitles.titles[id] != nil || id.hasPrefix("cpu.threadCurve.")
                || id.hasPrefix("cpu.sustained.short.") {
            return MSeriesRunItemTitles.chineseTitle(for: id)
        }

        switch state.workloadID {
        case "cpu.single.mixed": return L10n.text("CPU 单核混合运算", "CPU single-core mixed workload")
        case "cpu.multi.particle": return L10n.text("CPU 多核粒子运算", "CPU multi-core particle workload")
        case "gpu.graphics.offscreen": return L10n.text("GPU 离屏图形渲染", "GPU offscreen graphics rendering")
        case "gpu.compute.fp16": return L10n.text("GPU FP16 计算", "GPU FP16 compute")
        case "memory.workload": return L10n.text("内存带宽与延迟", "Memory bandwidth and latency")
        case "storage.sequential": return L10n.text("存储连续读写", "Sequential storage read and write")
        case "storage.random-access": return L10n.text("存储随机访问", "Random storage access")
        case "display.cadence": return L10n.text("显示刷新节奏", "Display frame cadence")
        case "sustained.preflight": return L10n.text("持续性能安全检查", "Sustained-performance safety check")
        case "sustained.cpu-then-gpu", "sustained": return L10n.text("CPU 与 GPU 持续负载", "Sustained CPU and GPU load")
        case "sustained.cooling-down": return L10n.text("负载结束与温度恢复", "Load completion and thermal recovery")
        default:
            if let id = state.workloadID { return MSeriesRunItemTitles.chineseTitle(for: id) }
            return L10n.text("准备首个测试项目", "Preparing the first test")
        }
    }

    private var progressValue: Double? {
        RuntimeWorkflowState.measuredFraction(state.progress)
    }

    private var currentStage: Stage? {
        switch state.phase {
        case .validating, .aggregating, .scoring, .persisting:
            return .validation
        default:
            if state.workloadID?.hasPrefix("cpu.threadCurve.") == true
                || state.workloadID?.hasPrefix("cpu.sustained.short.") == true {
                return .extensions
            }
            guard let category = state.category else { return nil }
            return Stage.allCases.first { $0.category == category }
        }
    }

    private var stageCaption: String {
        guard let currentStage else {
            return L10n.text("环境检查完成后，将依次运行 18 项 Core 并保存", "After the environment check, 18 Core workloads run and are saved")
        }
        return L10n.text(
            "第 \(currentStage.rawValue + 1) / \(ByteFormat.count(Stage.allCases.count)) 阶段 · \(currentStage.title)",
            "Stage \(currentStage.rawValue + 1) of \(ByteFormat.count(Stage.allCases.count)) · \(currentStage.title)"
        )
    }

    private func stageStatus(_ stage: Stage) -> StageStatus {
        guard let currentStage else { return .waiting }
        if stage == currentStage { return .running }
        return stage.rawValue < currentStage.rawValue ? .completed : .waiting
    }

    private func stageSymbol(_ status: StageStatus) -> String {
        switch status {
        case .waiting: "circle"
        case .running: "circle.inset.filled"
        case .completed: "checkmark.circle.fill"
        }
    }

    private func stageColor(_ status: StageStatus) -> Color {
        switch status {
        case .waiting: .secondary.opacity(0.55)
        case .running: accent
        case .completed: AppDesignTokens.Palette.success
        }
    }
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

private func categorySymbol(_ category: BenchmarkV7Category) -> String {
    switch category {
    case .cpu: "cpu"
    case .gpu: "square.3.layers.3d"
    case .memory: "memorychip"
    case .storage: "internaldrive"
    case .display: "display"
    case .sustained: "waveform.path.ecg"
    }
}

/// UI plan U1 029 (gap list 029): the temperature dial and the load chart are
/// separate. The dial is a complete circle next to the CPU and GPU gauges; the
/// load chart has its own full-width area below it. Both share the height the
/// page can show above its status bar, so neither is cut off. All plotted
/// values keep their provider timestamps through the existing chart.
struct BenchmarkMonitorLayout: Equatable {
    static let headerHeight: CGFloat = 18
    static let sectionSpacing: CGFloat = 8
    static let chartCaptionHeight: CGFloat = 14
    static let chartCaptionSpacing: CGFloat = 4
    /// Header, the two gaps between the three rows and the chart caption.
    static let fixedChromeHeight: CGFloat = headerHeight + 2 * sectionSpacing
        + chartCaptionHeight + chartCaptionSpacing
    static let maximumDiameter: CGFloat = 240
    static let dialGaugeSpacing: CGFloat = 16
    static let maximumGaugeSize: CGFloat = 64
    static let gaugeSpacing: CGFloat = 8
    static let minimumChartHeight: CGFloat = 80
    static let maximumChartHeight: CGFloat = 120
    /// The chart's share of the height left for the dial and the chart.
    static let chartShare: CGFloat = 0.38

    /// The landing page's segmented page picker plus a little slack.
    static let pagePickerAllowance: CGFloat = 28
    static let landingMinimumHeight: CGFloat = 250
    static let landingMaximumHeight: CGFloat = 430
    /// The monitor height when no page height is given. The performance page
    /// itself, idle or running, always passes `landingHeight` (review P2-3).
    static let defaultHeight: CGFloat = 330

    let diameter: CGFloat
    let gaugeSize: CGFloat
    let chartHeight: CGFloat

    /// `width` and `height` are the monitor's content size, inside its padding.
    init(width: CGFloat, height: CGFloat) {
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite ? max(0, height) : 0
        guard width > 0, height > 0 else {
            diameter = 0
            gaugeSize = 0
            chartHeight = 0
            return
        }
        let flexible = max(0, height - Self.fixedChromeHeight)
        chartHeight = min(Self.maximumChartHeight,
                          max(min(Self.minimumChartHeight, flexible), flexible * Self.chartShare))
        let byHeight = flexible - chartHeight
        let byWidth = width - Self.dialGaugeSpacing - Self.maximumGaugeSize
        diameter = max(0, min(Self.maximumDiameter, byHeight, byWidth))
        gaugeSize = max(0, min(Self.maximumGaugeSize, (diameter - Self.gaugeSpacing) / 2))
    }

    /// The landing monitor's height: what the scroll area shows below the page
    /// picker, so the dial is complete above the status bar (default window
    /// and 900 x 640), within fixed limits.
    static func landingHeight(scrollViewportHeight: CGFloat) -> CGFloat {
        guard scrollViewportHeight.isFinite else { return landingMinimumHeight }
        return min(landingMaximumHeight,
                   max(landingMinimumHeight, visibleHeight(scrollViewportHeight: scrollViewportHeight)))
    }

    /// The height the scroll area shows below the page picker, before the
    /// landing limits are applied.
    static func visibleHeight(scrollViewportHeight: CGFloat) -> CGFloat {
        guard scrollViewportHeight.isFinite else { return 0 }
        return scrollViewportHeight - AppDesignTokens.Layout.pagePadding - pagePickerAllowance
            - AppDesignTokens.Layout.pageSpacing - AppDesignTokens.Spacing.small
    }
}

/// U1 029 and review P2-3/P2-4: how the performance page arranges its first
/// screen, idle or running. The test card — or, while a test runs, its
/// progress — sits beside the monitor while both fit, so the monitor has the
/// same place and size in both states. Narrower pages stack the monitor below
/// it; there, and where the page is too short to show the monitor, the status
/// bar keeps a compact chip-temperature reading instead.
struct BenchmarkLandingLayout: Equatable {
    static let cardMinimumWidth: CGFloat = 290
    static let cardIdealWidth: CGFloat = 300
    static let cardMaximumWidth: CGFloat = 440
    static let monitorMinimumWidth: CGFloat = 280
    static let monitorIdealWidth: CGFloat = 300
    /// Both ideal widths and the gap between them: where the earlier
    /// ViewThatFits switched to the stacked arrangement.
    static let sideBySideMinimumContentWidth: CGFloat = cardIdealWidth
        + AppDesignTokens.Spacing.large + monitorIdealWidth

    let placesMonitorBeside: Bool
    let monitorHeight: CGFloat
    let showsCompactTemperature: Bool

    /// `scrollViewportSize` is the size of the page's scroll area (above the
    /// status bar); the page content is inset by the page padding.
    init(scrollViewportSize size: CGSize) {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        placesMonitorBeside = width - 2 * AppDesignTokens.Layout.pagePadding
            >= Self.sideBySideMinimumContentWidth
        monitorHeight = BenchmarkMonitorLayout.landingHeight(scrollViewportHeight: height)
        let monitorFitsFirstScreen = BenchmarkMonitorLayout.visibleHeight(scrollViewportHeight: height)
            >= BenchmarkMonitorLayout.landingMinimumHeight
        showsCompactTemperature = width > 0 && height > 0
            && (!placesMonitorBeside || !monitorFitsFirstScreen)
    }
}

/// Review P2-4: the chip temperature in one line for the status bar, shown
/// when the dial is not on the first screen. It reads the same latest sample
/// as the dial.
struct BenchmarkCompactTemperature: View {
    let telemetryPoints: [MenuBarTelemetryPoint]
    let accent: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: AppSymbols.Panel.temperature)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(L10n.text("芯片温度", "Chip temperature"))
                .foregroundStyle(.secondary)
            Text(BenchmarkSystemMonitor.temperatureText(
                BenchmarkSystemMonitor.latestChipTemperature(in: telemetryPoints)
            ))
            .monospacedDigit()
            .foregroundStyle(.primary)
        }
        .font(AppDesignTokens.Typography.metadata)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
#if DEBUG
        .layoutProbe("benchmark.compactTemperature")
#endif
    }
}

struct BenchmarkSystemMonitor: View {
    let telemetryPoints: [MenuBarTelemetryPoint]
    let accent: Color
    /// The monitor's total height, padding included.
    var availableHeight: CGFloat = BenchmarkMonitorLayout.defaultHeight

    private var outerHeight: CGFloat {
        availableHeight.isFinite
            ? max(availableHeight, 2 * AppDesignTokens.Spacing.small)
            : BenchmarkMonitorLayout.defaultHeight
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = BenchmarkMonitorLayout(width: proxy.size.width, height: proxy.size.height)
            VStack(alignment: .leading, spacing: BenchmarkMonitorLayout.sectionSpacing) {
                header
                    .frame(height: BenchmarkMonitorLayout.headerHeight)

                // The dial and gauges are centred so a wide monitor does not
                // leave one large empty block on the right (D45).
                HStack(alignment: .center, spacing: BenchmarkMonitorLayout.dialGaugeSpacing) {
                    Spacer(minLength: 0)
                    temperatureDial(diameter: metrics.diameter)
                        .allowsHitTesting(false)
#if DEBUG
                        .layoutProbe("benchmark.monitor.dial")
#endif
                    VStack(alignment: .center, spacing: BenchmarkMonitorLayout.gaugeSpacing) {
                        liveGauge(title: "CPU", value: telemetryPoints.last?.cpuTotal, tint: accent,
                                  size: metrics.gaugeSize)
                        liveGauge(title: "GPU", value: telemetryPoints.last?.gpu, tint: AppDesignTokens.Palette.caution,
                                  size: metrics.gaugeSize)
                    }
                    .frame(width: BenchmarkMonitorLayout.maximumGaugeSize)
                    Spacer(minLength: 0)
                }
                .frame(height: metrics.diameter)

                loadChart(height: metrics.chartHeight)
#if DEBUG
                    .layoutProbe("benchmark.monitor.chart")
#endif
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .padding(AppDesignTokens.Spacing.small)
        .frame(height: outerHeight)
        .background(accent.opacity(0.018), in: RoundedRectangle(
            cornerRadius: AppDesignTokens.Radius.glassControl,
            style: .continuous
        ))
#if DEBUG
        .layoutProbe("benchmark.monitor")
#endif
    }

    private var header: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            Label(monitorTitle, systemImage: "waveform.path.ecg")
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(accent)
                .lineLimit(1)
            Spacer(minLength: AppDesignTokens.Spacing.small)
            if let point = telemetryPoints.last {
                HStack(spacing: 4) {
                    Text(L10n.text("最近采样", "Last sample"))
                    Text(point.date, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .lineLimit(1)
            } else {
                Text(L10n.text("等待首次采样", "Waiting for the first sample"))
                    .lineLimit(1)
            }
        }
        .font(AppDesignTokens.Typography.metadata)
        .foregroundStyle(.secondary)
    }

    /// The live load curves in their own area below the dial: a caption with
    /// the legend, then the percent axis and the chart.
    private func loadChart(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: BenchmarkMonitorLayout.chartCaptionSpacing) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Text(L10n.text("当前负载", "Current Load"))
                    .foregroundStyle(.primary)
                legendDot("CPU", tint: accent)
                legendDot("GPU", tint: AppDesignTokens.Palette.caution)
                Spacer(minLength: AppDesignTokens.Spacing.small)
                Text(L10n.text("最近 2 分钟 · 0–100%", "Last 2 minutes · 0–100%"))
                    .foregroundStyle(.secondary)
            }
            .font(AppDesignTokens.Typography.metadata)
            .lineLimit(1)
            .frame(height: BenchmarkMonitorLayout.chartCaptionHeight)

            HStack(spacing: 2) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("100%")
                    Spacer(minLength: 0)
                    Text("50%")
                    Spacer(minLength: 0)
                    Text("0%")
                }
                .font(AppDesignTokens.Typography.metadata)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36)
                .padding(.bottom, 16)
                .accessibilityLabel(L10n.text("负载纵轴：0、50、100 百分比", "Load axis: 0, 50, 100 percent"))

                GeekPrecisionLineChart(
                    points: telemetryPoints,
                    series: [
                        MenuBarTelemetrySeries(
                            id: "benchmark-live-cpu",
                            title: L10n.text("CPU", "CPU"),
                            channel: .cpuTotal,
                            color: accent
                        ),
                        MenuBarTelemetrySeries(
                            id: "benchmark-live-gpu",
                            title: L10n.text("GPU", "GPU"),
                            channel: .gpu,
                            color: AppDesignTokens.Palette.caution
                        ),
                    ],
                    valueRange: 0...100,
                    unit: .percentWithTenths,
                    accessibilityLabel: L10n.text(
                        "CPU 与 GPU 实时负载",
                        "Live CPU and GPU load"
                    ),
                    duration: 120,
                    showsLegend: false,
                    showsTimelineLabels: true,
                    showsTooltip: true
                )
            }
            .frame(height: height)
        }
    }

    private func legendDot(_ title: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    /// A complete temperature dial: ticks, a 270° track and the reading. The
    /// load curves are no longer drawn inside it (U1 029).
    private func temperatureDial(diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(accent.opacity(0.12), lineWidth: 1)
            Circle().inset(by: diameter * 0.08).stroke(accent.opacity(0.08), lineWidth: 1)
            ForEach(0..<61, id: \.self) { tick in
                Rectangle()
                    .fill(tick >= 48 ? Color.orange.opacity(0.65) : accent.opacity(0.40))
                    .frame(width: 1, height: tick % 10 == 0 ? 8 : 4)
                    .offset(y: -diameter / 2 + 5)
                    .rotationEffect(.degrees(-135 + Double(tick) * 4.5))
            }
            Circle().trim(from: 0, to: 0.75)
                .stroke(accent.opacity(0.16), style: StrokeStyle(lineWidth: 3))
                .rotationEffect(.degrees(135))
                .padding(12)
            if let temperature = latestChipTemperature, temperature.isFinite {
                Circle().trim(from: 0, to: min(1, max(0, temperature / 100)) * 0.75)
                    .stroke(AngularGradient(colors: [accent, .purple, .orange], center: .center,
                                            startAngle: .degrees(135), endAngle: .degrees(405)),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(12)
            }
            VStack(spacing: 2) {
                Text(L10n.text("芯片温度", "Chip temperature"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(Self.temperatureText(latestChipTemperature))
                    .font(.system(size: max(16, diameter * 0.13), weight: .medium))
                    .monospacedDigit()
                    .accessibilityLabel(L10n.text("芯片温度", "Chip temperature"))
                    .accessibilityValue(Self.temperatureText(latestChipTemperature))
                Text("0–100°C")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(width: diameter * 0.7)
        }
        .frame(width: diameter, height: diameter)
    }

    private func liveGauge(title: String, value: Double?, tint: Color, size: CGFloat) -> some View {
        let valid = value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        return GeekCombinedRing(
            title: title,
            value: Self.loadText(valid),
            progress: valid.map { $0 / 100 },
            tint: tint,
            size: size,
            fixedValueFontSize: size >= 60 ? 14 : 12,
            strokeWidth: 5
        )
    }

    private var monitorTitle: String {
        #if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            return "FIXTURE · " + L10n.text("固定监控数据", "Fixed monitor samples")
        }
        #endif
        return L10n.text("系统实时监控", "Live System Monitor")
    }

    static func loadText(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...100).contains(value) else { return "—" }
        return GeekChartUnit.percentWithTenths.formatted(value)
    }

    static func temperatureText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0))))°C"
    }

    private var latestChipTemperature: Double? {
        Self.latestChipTemperature(in: telemetryPoints)
    }

    static func latestChipTemperature(in points: [MenuBarTelemetryPoint]) -> Double? {
        guard let point = points.last else { return nil }
        guard let value = MenuBarTelemetryChannel.chipTemperature.value(in: point),
              value.isFinite else { return nil }
        return value
    }
}
