import SwiftUI

struct MacAcceleratorBenchmarkSection: View {
    let state: MacAcceleratorBenchmarkState
    let progress: MacAcceleratorBenchmarkProgress?
    let latestResult: MacAcceleratorBenchmarkResult?
    let history: [MacAcceleratorBenchmarkResult]
    let notice: MacAcceleratorBenchmarkStoreNotice?
    let onCancel: () -> Void

    init(
        state: MacAcceleratorBenchmarkState,
        progress: MacAcceleratorBenchmarkProgress? = nil,
        latestResult: MacAcceleratorBenchmarkResult? = nil,
        history: [MacAcceleratorBenchmarkResult] = [],
        notice: MacAcceleratorBenchmarkStoreNotice? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.progress = progress
        self.latestResult = latestResult
        self.history = history
        self.notice = notice
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if isActive {
                progressPanel
            }

            if let statusMessage {
                statusBanner(statusMessage)
            }

            if let noticeMessage {
                noticeBanner(noticeMessage)
            }

            domainSection(.gpu)
            domainSection(.mediaEngine)

            methodologyNote
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.tertiary.opacity(0.025)
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    L10n.text("图形与媒体加速", "Graphics & Media Acceleration"),
                    systemImage: "cube.transparent"
                )
                .font(AppDesignTokens.Typography.sectionTitle)
                .foregroundStyle(AppDesignTokens.Palette.primary)

                Text(L10n.text(
                    "实验性原始指标，不计入 v6 总分，不上传、不进榜单。",
                    "Experimental raw metrics. Not scored into v6, never uploaded, never ranked."
                ))
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    MetadataPill(
                        text: L10n.text("每项 3 次采样", "3 samples per metric"),
                        systemImage: "repeat",
                        tint: AppDesignTokens.Palette.tertiary
                    )
                    MetadataPill(
                        text: MacAcceleratorBenchmarkResult.protocolVersion,
                        systemImage: "doc.badge.gearshape",
                        tint: AppDesignTokens.Palette.secondary
                    )
                }
            }

            Spacer(minLength: 8)
            primaryAction
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if isActive {
            Button(action: onCancel) {
                Label(
                    isCancelling
                        ? L10n.text("正在安全停止", "Stopping Safely")
                        : L10n.text("取消并清理", "Cancel & Clean Up"),
                    systemImage: isCancelling ? "hourglass" : "stop.circle"
                )
                .frame(minWidth: 138)
            }
            .appButtonChrome(.secondary)
            .controlSize(.large)
            .disabled(isCancelling)
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(progressTitle, systemImage: progressSymbol)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                Spacer(minLength: 8)
                if let progress {
                    Text("\(progress.completedSampleCount) / \(progress.totalSampleCount)")
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            AppStateIconRing(
                systemImage: progressSymbol,
                tint: AppDesignTokens.Palette.primary,
                progress: progressValue
            )
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 8) {
                Text(L10n.text("完成 \(progressPercentage)%", "\(progressPercentage)% complete"))
                Spacer(minLength: 8)
                if let progress {
                    Text(L10n.text(
                        "已用时 \(elapsedText(progress.elapsedSeconds))",
                        "Elapsed \(elapsedText(progress.elapsedSeconds))"
                    ))
                }
            }
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(AppDesignTokens.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppDesignTokens.Palette.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.settingsPanel, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func domainSection(_ domain: MacAcceleratorDomain) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: domain.acceleratorSymbol)
                    .foregroundStyle(domain.acceleratorTint)
                Text(domain.acceleratorTitle)
                    .font(AppDesignTokens.Typography.cardTitle)
                Text(domain.acceleratorDetail)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 220, maximum: 320),
                        spacing: 12,
                        alignment: .top
                    )
                ],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(metrics(in: domain), id: \.rawValue) { metric in
                    metricCard(
                        metric,
                        measurement: latestResult?.measurementsByMetric[metric]
                    )
                }
            }
        }
    }

    private func metricCard(
        _ metric: MacAcceleratorMetric,
        measurement: MacAcceleratorMeasurement?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: metric.acceleratorSymbol)
                    .foregroundStyle(metric.domain.acceleratorTint)
                    .frame(width: 18)
                Text(metric.acceleratorTitle)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                domainBadge(metric.domain)
            }

            Divider()
            measurementBody(metric, measurement: measurement)
        }
        .padding(AppDesignTokens.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: AppDesignTokens.Radius.settingsPanel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func measurementBody(
        _ metric: MacAcceleratorMetric,
        measurement: MacAcceleratorMeasurement?
    ) -> some View {
        if let measurement {
            switch measurement.availability {
            case .measured:
                measuredBody(metric, measurement: measurement)
            case .unsupported:
                availabilityBody(
                    L10n.text("硬件不支持，不记 0", "Unsupported hardware — never recorded as zero"),
                    symbol: "nosign",
                    tint: .secondary
                )
            case .temporarilyUnavailable:
                availabilityBody(
                    L10n.text("硬件资源暂不可用，可重试", "Hardware resource temporarily unavailable — retry later"),
                    symbol: "arrow.clockwise.circle",
                    tint: AppDesignTokens.Palette.warning
                )
            }
        } else {
            availabilityBody(
                L10n.text("等待测试", "Waiting to run"),
                symbol: "circle.dashed",
                tint: .secondary
            )
        }
    }

    private func measuredBody(
        _ metric: MacAcceleratorMetric,
        measurement: MacAcceleratorMeasurement
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(metricValueText(measurement.medianValue))
                    .font(AppDesignTokens.Typography.metricValue)
                    .monospacedDigit()
                    .textSelection(.enabled)
                Text(metric.unit.acceleratorText)
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
            }

            valueRow(
                title: L10n.text("中位数", "Median"),
                value: metricValueText(measurement.medianValue)
            )
            valueRow(
                title: L10n.text("CV 波动", "CV variation"),
                value: variationText(measurement.coefficientOfVariation)
            )
            valueRow(
                title: L10n.text("样本", "Samples"),
                value: "\(measurement.samples.count)"
            )

            Label(
                measurement.isStable
                    ? L10n.text("采样稳定", "Stable samples")
                    : L10n.text("波动偏高，建议重试", "High variation — retry recommended"),
                systemImage: measurement.isStable
                    ? "checkmark.circle.fill"
                    : "waveform.path.ecg"
            )
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(measurement.isStable ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning)
        }
    }

    private func availabilityBody(
        _ text: String,
        symbol: String,
        tint: Color
    ) -> some View {
        Label(text, systemImage: symbol)
            .font(AppDesignTokens.Typography.body)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .center)
    }

    private func domainBadge(_ domain: MacAcceleratorDomain) -> some View {
        Text(domain.acceleratorShortTitle)
            .font(AppTypography.body.weight(.semibold))
            .foregroundStyle(domain.acceleratorTint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                domain.acceleratorTint.opacity(0.09),
                in: Capsule(style: .continuous)
            )
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(AppDesignTokens.Typography.secondary)
    }

    private var methodologyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cube.fill")
                .foregroundStyle(AppDesignTokens.Palette.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("固定测试模型", "Deterministic Test Model"))
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                Text(L10n.text(
                    "3D 模型与场景由程序固定生成；几何体、材质、相机和测试参数通过工作负载指纹冻结，不读取用户文件。视频编解码标为媒体引擎，不冒充 GPU 性能。",
                    "The 3D model and scene are generated deterministically in code; geometry, materials, camera, and parameters are frozen by a workload fingerprint without reading user files. Video encode/decode is labeled as Media Engine work, not GPU performance."
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppDesignTokens.Palette.secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func statusBanner(_ message: String) -> some View {
        Label(message, systemImage: statusSymbol)
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(statusTint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppDesignTokens.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                statusTint.opacity(0.07),
                in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.settingsPanel, style: .continuous)
            )
    }

    private func noticeBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(AppDesignTokens.Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppDesignTokens.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppDesignTokens.Palette.warning.opacity(0.07),
                in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.settingsPanel, style: .continuous)
            )
    }

    private func metrics(in domain: MacAcceleratorDomain) -> [MacAcceleratorMetric] {
        MacAcceleratorMetric.allCases.filter { $0.domain == domain }
    }

    private var isActive: Bool {
        switch state {
        case .preflighting, .running, .cancelling:
            true
        case .idle, .completed, .cancelled, .failed:
            false
        }
    }

    private var isCancelling: Bool {
        if case .cancelling = state { return true }
        return false
    }

    private var progressValue: Double {
        if let progress { return progress.progress }
        switch state {
        case let .running(_, value):
            return min(1, max(0, value))
        case .cancelling:
            return 0.99
        case .idle, .preflighting, .completed, .cancelled, .failed:
            return 0
        }
    }

    private var progressPercentage: Int {
        Int((progressValue * 100).rounded())
    }

    private var progressTitle: String {
        if isCancelling {
            return L10n.text("正在安全停止并清理", "Stopping safely and cleaning up")
        }
        if let progress {
            return L10n.text(
                "正在测试：\(progress.metric.acceleratorTitle)",
                "Testing: \(progress.metric.acceleratorTitle)"
            )
        }
        if case let .running(metric, _) = state {
            return L10n.text(
                "正在测试：\(metric.acceleratorTitle)",
                "Testing: \(metric.acceleratorTitle)"
            )
        }
        return L10n.text("正在进行运行前检查", "Running preflight checks")
    }

    private var progressSymbol: String {
        if isCancelling { return "hourglass" }
        if let progress { return progress.metric.acceleratorSymbol }
        if case let .running(metric, _) = state {
            return metric.acceleratorSymbol
        }
        return "checkmark.shield"
    }

    private var statusMessage: String? {
        switch state {
        case .completed:
            L10n.text(
                "加速测试已完成并保留原始指标；未生成或改变任何总分。",
                "The accelerator suite completed and retained raw metrics only; no composite was generated or changed."
            )
        case .cancelled:
            L10n.text(
                "测试已取消；不完整结果不会写入历史。",
                "The run was cancelled; incomplete results are not saved to history."
            )
        case let .failed(failure):
            failureMessage(failure)
        case .idle, .preflighting, .running, .cancelling:
            nil
        }
    }

    private var statusSymbol: String {
        switch state {
        case .completed:
            "checkmark.circle.fill"
        case .cancelled:
            "stop.circle"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle, .preflighting, .running, .cancelling:
            "info.circle"
        }
    }

    private var statusTint: Color {
        switch state {
        case .completed:
            AppDesignTokens.Palette.success
        case .failed:
            AppDesignTokens.Palette.warning
        case .idle, .preflighting, .running, .cancelling, .cancelled:
            .secondary
        }
    }

    private var noticeMessage: String? {
        switch notice {
        case .historySaveFailed:
            L10n.text(
                "测试已完成，但本地历史保存失败；当前结果仍可查看。",
                "The run completed, but local history could not be saved; the current result remains visible."
            )
        case .resultRejected:
            L10n.text(
                "结果未通过完整性校验，因此没有进入历史。",
                "The result failed completeness validation and was not added to history."
            )
        case nil:
            nil
        }
    }

    private func failureMessage(_ failure: MacAcceleratorBenchmarkFailure) -> String {
        switch failure {
        case let .busy(activeTask):
            L10n.text(
                "另一项高负载任务正在运行（\(activeTask)），请稍后重试。",
                "Another heavy task is running (\(activeTask)); retry later."
            )
        case .safetyCheck:
            L10n.text(
                "运行前安全检查未通过；调整电源、温度或磁盘条件后重试。",
                "Preflight safety checks did not pass; correct the power, thermal, or disk condition and retry."
            )
        case let .timedOut(metric):
            L10n.text(
                "\(metric.acceleratorTitle) 超时，未保存不完整结果。",
                "\(metric.acceleratorTitle) timed out; the incomplete result was not saved."
            )
        case let .validationFailed(metric):
            L10n.text(
                "\(metric.acceleratorTitle) 未通过结果校验，请重试。",
                "\(metric.acceleratorTitle) failed result validation; please retry."
            )
        case .cancelled:
            L10n.text("测试已取消。", "The run was cancelled.")
        case .invalidResult:
            L10n.text(
                "结果不完整或无效，因此没有进入历史。",
                "The result was incomplete or invalid and was not added to history."
            )
        }
    }

    private func metricValueText(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(2)))
    }

    private func variationText(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(1)))
    }

    private func elapsedText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        return seconds.formatted(.number.precision(.fractionLength(1))) + " s"
    }
}

private extension MacAcceleratorMetric {
    var acceleratorTitle: String {
        switch self {
        case .metalRaster3D:
            L10n.text("Metal 3D 光栅", "Metal 3D Raster")
        case .rayTracingBuild:
            L10n.text("光线追踪结构构建", "Ray-Tracing Structure Build")
        case .rayTracingTraversal:
            L10n.text("光线追踪遍历", "Ray-Tracing Traversal")
        case .gpuTensorFP16:
            L10n.text("GPU FP16 矩阵计算", "GPU FP16 Matrix Compute")
        case .mediaH264Encode:
            L10n.text("H.264 硬件编码", "H.264 Hardware Encode")
        case .mediaH264Decode:
            L10n.text("H.264 硬件解码", "H.264 Hardware Decode")
        }
    }

    var acceleratorSymbol: String {
        switch self {
        case .metalRaster3D:
            "cube.transparent"
        case .rayTracingBuild:
            "square.3.layers.3d"
        case .rayTracingTraversal:
            "rays"
        case .gpuTensorFP16:
            "square.grid.3x3.fill"
        case .mediaH264Encode:
            "video.badge.ellipsis"
        case .mediaH264Decode:
            "play.rectangle.fill"
        }
    }
}

private extension MacAcceleratorDomain {
    var acceleratorTitle: String {
        switch self {
        case .gpu:
            L10n.text("GPU 图形与计算", "GPU Graphics & Compute")
        case .mediaEngine:
            L10n.text("媒体引擎", "Media Engine")
        }
    }

    var acceleratorShortTitle: String {
        switch self {
        case .gpu:
            "GPU"
        case .mediaEngine:
            L10n.text("媒体引擎", "Media Engine")
        }
    }

    var acceleratorDetail: String {
        switch self {
        case .gpu:
            L10n.text("光栅、光追与矩阵计算", "Raster, ray tracing, and matrix compute")
        case .mediaEngine:
            L10n.text("独立标注硬件视频吞吐", "Hardware video throughput, labeled separately")
        }
    }

    var acceleratorSymbol: String {
        switch self {
        case .gpu:
            "display"
        case .mediaEngine:
            "play.rectangle.on.rectangle"
        }
    }

    var acceleratorTint: Color {
        switch self {
        case .gpu:
            AppDesignTokens.Palette.primary
        case .mediaEngine:
            AppDesignTokens.Palette.secondary
        }
    }
}

private extension MacAcceleratorMetricUnit {
    var acceleratorText: String {
        switch self {
        case .millionTrianglesPerSecond:
            "Mtri/s"
        case .millionRaysPerSecond:
            "Mray/s"
        case .trillionFloatingPointOperationsPerSecond:
            "TFLOP/s"
        case .megapixelsPerSecond:
            "MPix/s"
        }
    }
}
