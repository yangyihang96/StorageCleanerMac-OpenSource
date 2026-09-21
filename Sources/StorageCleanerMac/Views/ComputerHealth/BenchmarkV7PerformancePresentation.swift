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

    let state: BenchmarkV7State
    let isPreflighting: Bool
    let accent: Color
    let canCancel: Bool
    let onCancel: () -> Void
    var telemetryPoints: [MenuBarTelemetryPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            RuntimeInlineStatus(
                state: state.phase == .cancelling ? .stopping : .running,
                title: phaseTitle,
                detail: currentTaskTitle
            )
            HStack(spacing: 12) {
                if let repetition = state.repetition, repetition > 0 {
                    Text(L10n.text("第 \(repetition) 次采样", "Sample \(repetition)"))
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 58), spacing: 8),
                                     count: Stage.allCases.count), spacing: 10) {
                ForEach(Stage.allCases) { stage in stageView(stage) }
            }
            Text(stageCaption)
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            BenchmarkSystemMonitor(telemetryPoints: telemetryPoints, accent: accent)
        }
        .accessibilityElement(children: .contain)
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
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var phaseTitle: String {
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

    private var currentTaskTitle: String {
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

        if let id = state.workloadID, id.hasPrefix("cpu.threadCurve.") {
            let workers = id.split(separator: ".").last.map(String.init) ?? "—"
            return L10n.text("扩展：CPU 线程曲线（\(workers) 线程）", "Extension: CPU thread curve (\(workers) workers)")
        }
        if state.workloadID?.hasPrefix("cpu.sustained.short.") == true {
            return L10n.text("扩展：短持续表现观察", "Extension: short sustained observation")
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
            return state.category.map { L10n.text("正在测试 \(categoryTitle($0))", "Testing \(categoryTitle($0))") }
                ?? L10n.text("准备首个测试项目", "Preparing the first test")
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
            "第 \(currentStage.rawValue + 1) / \(Stage.allCases.count) 阶段 · \(currentStage.title)",
            "Stage \(currentStage.rawValue + 1) of \(Stage.allCases.count) · \(currentStage.title)"
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

/// Shared by the initial and running pages; all plotted values retain their
/// provider timestamps through the existing telemetry chart.
struct BenchmarkSystemMonitor: View {
    let telemetryPoints: [MenuBarTelemetryPoint]
    let accent: Color
    var chartHeight: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Label(
                    monitorTitle,
                    systemImage: "waveform.path.ecg"
                )
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(accent)

                Spacer(minLength: AppDesignTokens.Spacing.small)

                if let temperature = latestChipTemperature {
                    Text("\(temperature.formatted(.number.precision(.fractionLength(0))))°C")
                        .monospacedDigit()
                } else {
                    Text(L10n.text("温度不可用", "Temperature unavailable"))
                }
            }
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                liveGauge(title: "CPU", value: telemetryPoints.last?.cpuTotal, tint: accent)
                liveGauge(title: "GPU", value: telemetryPoints.last?.gpu, tint: AppDesignTokens.Palette.caution)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(L10n.text("当前负载", "Current Load"))
                        .font(AppDesignTokens.Typography.secondary)
                    Text(L10n.text("最近 2 分钟 · 0–100%", "Last 2 minutes · 0–100%"))
                        .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                }
            }

            if let point = telemetryPoints.last {
                HStack {
                    Text(L10n.text("最近采样", "Last sample"))
                    Text(point.date, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            } else {
                Text(L10n.text("等待首次采样", "Waiting for the first sample"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                temperatureDial
                    .allowsHitTesting(false)
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
                    unit: .percent,
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
                .frame(maxWidth: max(180, chartHeight - 20))
                .padding(.vertical, 60)
            }
            .frame(height: max(280, chartHeight + 70))
        }
        .padding(AppDesignTokens.Spacing.small)
        .background(accent.opacity(0.018), in: RoundedRectangle(
            cornerRadius: AppDesignTokens.Radius.glassControl,
            style: .continuous
        ))
    }

    private var temperatureDial: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height) - 10
            ZStack {
                Circle().stroke(accent.opacity(0.12), lineWidth: 1)
                Circle().inset(by: 16).stroke(accent.opacity(0.08), lineWidth: 1)
                Circle().inset(by: 34).stroke(accent.opacity(0.06), lineWidth: 1)
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
                if let temperature = latestChipTemperature, temperature.isFinite {
                    Circle().trim(from: 0, to: min(1, max(0, temperature / 100)) * 0.75)
                        .stroke(AngularGradient(colors: [accent, .purple, .orange], center: .center,
                                                startAngle: .degrees(135), endAngle: .degrees(405)),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(135))
                }
                VStack {
                    Text(L10n.text("芯片温度 · 0–100°C", "Chip temperature · 0–100°C"))
                    Spacer()
                    Text(latestChipTemperature.map { "\($0.formatted(.number.precision(.fractionLength(0))))°C" } ?? "—")
                        .font(.system(size: 19, weight: .medium)).monospacedDigit()
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.vertical, 22)
            }
            .frame(width: diameter, height: diameter)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private func liveGauge(title: String, value: Double?, tint: Color) -> some View {
        let valid = value.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        return GeekCombinedRing(
            title: title,
            value: Self.loadText(valid),
            progress: valid.map { $0 / 100 },
            tint: tint,
            size: 72,
            fixedValueFontSize: 15,
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
        return GeekChartUnit.percent.formatted(value)
    }

    private var latestChipTemperature: Double? {
        guard let point = telemetryPoints.last else { return nil }
        return MenuBarTelemetryChannel.chipTemperature.value(in: point)
    }
}
