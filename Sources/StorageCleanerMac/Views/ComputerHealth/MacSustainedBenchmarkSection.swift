import SwiftUI

struct MacSustainedBenchmarkSection: View {
    let state: MacSustainedBenchmarkState
    let progress: MacSustainedBenchmarkProgress?
    let latestResult: MacSustainedBenchmarkResult?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if isActive, let progress {
                Divider()
                progressPanel(progress)
            }
            if let statusMessage {
                statusBanner(statusMessage)
            }
            if let latestResult {
                if latestResult.isLegacyWorkload {
                    legacyResultBanner
                } else if latestResult.isComplete {
                    resultGrid(latestResult)
                }
            }
            safetyDisclosure
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.warning.opacity(0.02)
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    L10n.text("持续性能与散热稳定性", "Sustained Performance & Thermals"),
                    systemImage: "gauge.with.dots.needle.67percent"
                )
                .font(AppDesignTokens.Typography.sectionTitle)
                .foregroundStyle(AppDesignTokens.Palette.warning)

                Text(L10n.text(
                    "CPU 后 GPU 串行受载 10 分钟，分别报告峰值、持续值与性能保持率。仅供本机分析，不计分、不上传。",
                    "CPU then GPU run serially for 10 minutes to report peak, sustained throughput and retention separately. Local analysis only; not scored, never uploaded."
                ))
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Label(
                        MacSustainedBenchmarkResult.protocolVersion,
                        systemImage: "doc.badge.gearshape"
                    )
                    Text("·")
                    Text(L10n.text("固定 10 分钟", "Fixed 10 minutes"))
                    Text("·")
                    Text(L10n.text("1 Hz 热监控", "1 Hz thermal watchdog"))
                    Text("·")
                    Text(L10n.text("系统自动风扇", "System-managed fans"))
                }
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isActive {
            Button(action: onCancel) {
                Label(
                    state == .cancelling
                        ? L10n.text("正在安全停止", "Stopping Safely")
                        : L10n.text("停止并冷却", "Stop & Cool Down"),
                    systemImage: state == .cancelling ? "hourglass" : "stop.circle"
                )
                .frame(minWidth: 138)
            }
            .appButtonChrome(.secondary)
            .controlSize(.large)
            .disabled(state == .cancelling)
        }
    }

    private func progressPanel(_ progress: MacSustainedBenchmarkProgress) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(progressTitle(progress), systemImage: progressSymbol(progress))
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                Spacer(minLength: 8)
                Text(elapsedText(progress.elapsedSeconds))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            AppStateIconRing(
                systemImage: progressSymbol(progress),
                tint: AppDesignTokens.Palette.warning,
                progress: progress.progress
            )
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 12) {
                Text(L10n.text(
                    "窗口 \(progress.completedWindowCount)",
                    "Window \(progress.completedWindowCount)"
                ))
                Text(thermalText(progress.thermalState))
                if let fan = progress.currentFanSpeedRPM {
                    Text("\(fan) RPM")
                } else {
                    Text(L10n.text("风扇数据不可用", "Fan data unavailable"))
                }
            }
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultGrid(_ result: MacSustainedBenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(
                    L10n.text("最近一次持续结果", "Latest Sustained Result"),
                    systemImage: "waveform.path.ecg.rectangle"
                )
                .font(AppDesignTokens.Typography.cardTitle)
                Spacer(minLength: 8)
                Text(terminationText(result.termination))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                performanceCard(
                    title: L10n.text("CPU 多核持续", "CPU Multi Sustained"),
                    unit: "Mop/s",
                    summary: result.cpuSummary,
                    symbol: "cpu"
                )
                performanceCard(
                    title: L10n.text("GPU 光栅持续", "GPU Raster Sustained"),
                    unit: "Mtri/s",
                    summary: result.gpuSummary,
                    symbol: "cube.fill"
                )
                telemetryCard(result)
            }
        }
    }

    private var legacyResultBanner: some View {
        Label(
            L10n.text(
                "检测到旧版 CPU/GPU 并行持续测试结果。v2 已改为串行负载，旧结果保留为 Legacy，不与当前结果直接比较。",
                "An earlier CPU/GPU concurrent sustained result was detected. v2 uses serial load, so this legacy result is not directly comparable."
            ),
            systemImage: "clock.arrow.circlepath"
        )
        .font(AppDesignTokens.Typography.secondary)
        .foregroundStyle(AppDesignTokens.Palette.warning)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func performanceCard(
        title: String,
        unit: String,
        summary: MacSustainedPerformanceSummary?,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
            Divider()
            if let summary {
                valueRow(
                    L10n.text("峰值", "Peak"),
                    "\(metricText(summary.peakValue)) \(unit)"
                )
                valueRow(
                    L10n.text("末段持续", "End sustained"),
                    "\(metricText(summary.sustainedMedianValue)) \(unit)"
                )
                valueRow(
                    L10n.text("性能保持率", "Retention"),
                    percentText(summary.retentionRatio)
                )
            } else {
                Text(L10n.text(
                    "安全停止前样本不足，不生成保持率。",
                    "Not enough completed windows before the safe stop to calculate retention."
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
    }

    private func telemetryCard(_ result: MacSustainedBenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(L10n.text("热与散热", "Thermals & Cooling"), systemImage: "fan")
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
            Divider()
            valueRow(
                L10n.text("负载时长", "Load duration"),
                elapsedText(result.workloadDurationSeconds)
            )
            valueRow(
                L10n.text("峰值温度", "Peak temperature"),
                result.maximumChipTemperatureCelsius.map {
                    String(format: "%.1f °C", $0)
                } ?? L10n.text("不可用", "Unavailable")
            )
            valueRow(
                L10n.text("最高风扇", "Peak fan"),
                result.maximumFanSpeedRPM.map { "\($0) RPM" }
                    ?? L10n.text("无风扇或不可用", "Fanless or unavailable")
            )
            if let reached = result.cooldownReachedNominal {
                valueRow(
                    L10n.text("冷却观察", "Cooldown observation"),
                    reached
                        ? L10n.text("已恢复正常", "Returned to nominal")
                        : L10n.text("观察超时，负载已停止", "Observation timed out; load remains stopped")
                )
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
    }

    private var safetyDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("安全边界", "Safety Boundary"))
                        .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    Text(L10n.text(
                        "本应用不会写入 SMC、不会强制风扇转速，也不会请求管理员权限。macOS 始终控制风扇；热状态达到 serious 或 critical 时，测试立即停止当前串行 CPU/GPU 负载并进入冷却观察。温度和 RPM 只是只读佐证，缺失时不记 0、不惩罚无风扇机型。",
                        "The app never writes SMC values, forces fan speed, or requests administrator access. macOS always controls the fans. At serious or critical thermal state, the current serial CPU/GPU load stops and cooldown observation begins. Temperature and RPM are read-only evidence; missing data is never treated as zero or penalized on fanless Macs."
                    ))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(AppDesignTokens.Typography.secondary)
    }

    private func statusBanner(_ message: String) -> some View {
        Label(message, systemImage: statusSymbol)
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(statusTint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isActive: Bool {
        switch state {
        case .preflighting, .running, .coolingDown, .cancelling:
            true
        case .idle, .completed, .cancelled, .failed:
            false
        }
    }

    private var statusMessage: String? {
        switch state {
        case .completed:
            return L10n.text(
                "持续测试已完成；结果仅保留原始指标，不影响标准总分。",
                "The sustained test completed with raw metrics only and did not affect the standard score."
            )
        case .cancelled:
            return L10n.text(
                "测试已取消，CPU/GPU 负载已经释放。",
                "The test was cancelled and CPU/GPU load was released."
            )
        case let .failed(failure):
            return failureText(failure)
        case .idle, .preflighting, .running, .coolingDown, .cancelling:
            return nil
        }
    }

    private var statusSymbol: String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .cancelled: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .idle, .preflighting, .running, .coolingDown, .cancelling: "info.circle"
        }
    }

    private var statusTint: Color {
        switch state {
        case .completed: AppDesignTokens.Palette.success
        case .failed: AppDesignTokens.Palette.warning
        case .idle, .preflighting, .running, .coolingDown, .cancelling, .cancelled:
            .secondary
        }
    }

    private func progressTitle(_ progress: MacSustainedBenchmarkProgress) -> String {
        switch progress.stage {
        case .preflight:
            L10n.text("正在进行安全检查", "Running safety checks")
        case .mixedLoad:
            L10n.text("CPU 后 GPU 串行持续负载", "CPU then GPU sustained serial load")
        case .coolingDown:
            L10n.text("负载已停止，正在观察冷却", "Load stopped; observing cooldown")
        }
    }

    private func progressSymbol(_ progress: MacSustainedBenchmarkProgress) -> String {
        switch progress.stage {
        case .preflight: "checkmark.shield"
        case .mixedLoad: "flame.fill"
        case .coolingDown: "snowflake"
        }
    }

    private func terminationText(
        _ termination: MacSustainedBenchmarkTermination?
    ) -> String {
        switch termination {
        case .targetDurationReached:
            L10n.text("达到目标时长", "Target duration reached")
        case let .thermalSafety(state):
            L10n.text(
                "热保护停止 · \(thermalText(state))",
                "Thermal safety stop · \(thermalText(state))"
            )
        case .powerSourceChanged:
            L10n.text("电源变化后停止", "Stopped after power change")
        case .lowPowerModeEnabled:
            L10n.text("低电量模式开启后停止", "Stopped after Low Power Mode enabled")
        case nil:
            L10n.text("已完成", "Completed")
        }
    }

    private func failureText(_ failure: MacSustainedBenchmarkFailure) -> String {
        switch failure {
        case let .busy(activeTask):
            L10n.text("另一项重任务正在运行：\(activeTask)", "Another heavy task is active: \(activeTask)")
        case .safetyCheck:
            L10n.text("当前电源、低电量模式或热状态不适合持续测试。", "Power, Low Power Mode, or thermal state is not safe for this test.")
        case .unsupportedCPU:
            L10n.text("当前 CPU 配置不支持此持续负载。", "This CPU configuration does not support the sustained workload.")
        case .unsupportedGPU:
            L10n.text("当前 GPU 不支持固定 Metal 3D 负载。", "The GPU does not support the fixed Metal 3D workload.")
        case .insufficientSamples:
            L10n.text("完成窗口不足，未生成保持率。", "Too few windows completed to calculate retention.")
        case .workloadFailed:
            L10n.text("持续负载未能完成，请冷却后重试。", "The sustained workload could not complete; cool down and retry.")
        case .cancelled:
            L10n.text("测试已取消。", "The test was cancelled.")
        case .invalidResult:
            L10n.text("结果校验失败，未保留数据。", "Result validation failed and no data was retained.")
        }
    }

    private func thermalText(_ state: BenchmarkThermalState) -> String {
        switch state {
        case .nominal: L10n.text("温控正常", "Thermal nominal")
        case .fair: L10n.text("温控 Fair", "Thermal fair")
        case .serious: L10n.text("温控 Serious", "Thermal serious")
        case .critical: L10n.text("温控 Critical", "Thermal critical")
        case .unknown: L10n.text("温控未知", "Thermal unknown")
        }
    }

    private func metricText(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private func percentText(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }

    private func elapsedText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let rounded = Int(seconds.rounded())
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}
