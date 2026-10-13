import SwiftUI

struct PerformanceBenchmarkV11RunningPage: View {
    @Environment(\.colorScheme) private var scheme
    let run: MSeriesV11PagePresentation.Run
    let telemetry: [MSeriesV11Telemetry]
    let systemTelemetry: [MenuBarTelemetryPoint]
    var now: Date = .now
    var liveObservation: MSeriesV11LiveObservation? = nil
    let onCancel: () -> Void
    private var gpuStage: Bool { ["power.gpu.peak", "sustained.gpu", "pressure.gpu"].contains(run.state.workloadID ?? "") }
    private var palette: FeatureLightfieldPalette { .resolve(scheme) }
    var body: some View {
        FeatureLightfieldPage(module: .performance, phase: .running, title: ReviewFilter.performance.sidebarTitle,
            status: run.title, safety: L10n.text("功率、频率、温度各自独立纵轴", "Power, frequency, temperature use separate axes"),
            actionTitle: run.state.phase == .cancelling ? L10n.text("正在停止", "Stopping") :
                run.state.phase == .persisting ? L10n.text("正在保存", "Saving") : L10n.text("取消", "Cancel"),
            actionEnabled: run.canCancel, action: onCancel,
            subtitle: run.mode == "pressure10m" ? L10n.text("独立压力观察 · CPU 5 分钟＋GPU 5 分钟 · 不计分", "Independent pressure · CPU 5 min + GPU 5 min · Unscored") : L10n.text("标准流程 · 核心测试 → 能效 → 持续性能", "Standard flow · Core → Efficiency → Sustained")) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(run.title).font(.system(size: 15)).foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true)
                            .lightfieldComponentProbe("performance.running.stage")
                        Text(run.displayedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? MSeriesV11PagePresentation.unread)
                            .font(.system(size: 64, weight: .bold)).monospacedDigit().foregroundStyle(palette.fg)
                            .lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: running-progress
                            .lightfieldComponentProbe("performance.running.percent")
                        Text(run.position + " · " + MSeriesV11PagePresentation.duration(run.elapsedSeconds)).font(.system(size: 13)).foregroundStyle(palette.fg2)
                        LightfieldDataBar(progress: run.displayedFraction, module: .performance, style: .progress(), accessibilityLabel: L10n.text("加权总进度", "Weighted total progress"))
                            .lightfieldComponentProbe("performance.running.progress.total")
                        HStack {
                            Text(L10n.text("18 项核心 · 子进度", "18 Core measurements · Subprogress")); Spacer(minLength: 0)
                            Text("\(run.completedCoreCount)/18")
                        }.font(.system(size: 13)).foregroundStyle(palette.fg2)
                        LightfieldDataBar(progress: Double(run.completedCoreCount) / 18, module: .performance,
                            style: .progress(segments: 18), accessibilityLabel: L10n.text("核心子进度", "Core subprogress"))
                            .lightfieldComponentProbe("performance.running.progress.core")
                        FeatureLightfieldHairline()
                        liveCharts
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(L10n.text("每瓦性能", "Performance per watt")).font(.system(size: 13)).foregroundStyle(palette.fg2)
                            Text(MSeriesV11PagePresentation.number(currentObservation?.efficiency)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok: running-efficiency
                                .lightfieldComponentProbe("performance.running.efficiency.value")
                            Text(MSeriesV11PagePresentation.unit(currentObservation?.unit ?? "fixed-fixtures/J"))
                                .font(.system(size: 13)).foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true)
                        }.foregroundStyle(palette.fg)
                        Text(currentObservation?.efficiency == nil ? L10n.text("当前吞吐未读取", "Live throughput not read") :
                            L10n.text("实测功率与负载重叠区间", "Measured power and workload overlap interval"))
                            .font(.system(size: 12)).foregroundStyle(palette.fg2)
                        if let latest = systemTelemetry.last {
                            Text("CPU " + MSeriesV11PagePresentation.number(latest.cpuTotal.map { $0 * 100 }, digits: 0)
                                + "% / GPU " + MSeriesV11PagePresentation.number(latest.gpu.map { $0 * 100 }, digits: 0) + "%")
                                .font(.system(size: 13)).foregroundStyle(palette.fg2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.hidden)
            }
    }
    private var currentObservation: MSeriesV11LiveObservation? {
        guard let liveObservation, liveObservation.sessionID == run.state.sessionID,
              liveObservation.stageID == run.state.workloadID else { return nil }
        let clock = MSeriesV11Clock.nanoseconds
        guard clock >= liveObservation.endedAtNanoseconds, clock - liveObservation.endedAtNanoseconds <= 10_000_000_000 else { return nil }
        return liveObservation
    }
    private var liveCharts: some View {
        VStack(spacing: 4) {
            LightfieldMetricGroup(metrics: [
                .init(id: "power", label: gpuStage ? L10n.text("GPU 功率", "GPU power") : L10n.text("CPU 功率", "CPU power"), value: MSeriesV11PagePresentation.number(freshValue(powerValues)), unit: "W"),
                .init(id: "frequency", label: gpuStage ? L10n.text("GPU 频率", "GPU frequency") : L10n.text("性能簇频率", "Performance cluster"), value: MSeriesV11PagePresentation.number(freshValue(frequencyValues)), unit: "GHz"),
                .init(id: "temperature", label: L10n.text("芯片温度", "Chip temperature"), value: MSeriesV11PagePresentation.number(freshValue(temperatureValues), digits: 0), unit: "°C")], probeID: "performance.running.metrics")
            HStack(alignment: .top, spacing: 12) {
                chart(powerValues, unit: "W", color: FeatureLightfieldPalette.accent(.performance), minimumMaximum: 40)
                    .lightfieldComponentProbe("performance.running.chart.power")
                chart(frequencyValues, unit: "GHz", color: FeatureLightfieldPalette.accent(.overview), minimumMaximum: 4)
                    .lightfieldComponentProbe("performance.running.chart.frequency")
                chart(temperatureValues, unit: "°C", color: palette.warningColor, minimumMaximum: 80)
                    .lightfieldComponentProbe("performance.running.chart.temperature")
            }
            if powerValues.compactMap(\.1).isEmpty { Text(MSeriesV11PagePresentation.helperRequired).font(.system(size: 13)).foregroundStyle(palette.fg2) }
        }.lightfieldComponentProbe("performance.running.monitor")
    }
    private var powerValues: [(Date, Double?)] { readingValues { (gpuStage ? $0.gpuMilliwatts : $0.cpuMilliwatts).map { $0 / 1000 } } }
    private var frequencyValues: [(Date, Double?)] {
        readingValues { gpuStage ? $0.gpuMegahertz.map { $0 / 1000 } : $0.clusters?.filter { $0.kind == .performance }.compactMap(\.megahertz).max().map { $0 / 1000 } }
    }
    private func readingValues(_ value: (MSeriesV11Telemetry) -> Double?) -> [(Date, Double?)] {
        let clock = MSeriesV11Clock.nanoseconds
        return telemetry.suffix(30).map { sample in
            let at = sample.responseReceivedMonotonicNs ?? 0
            let age = clock >= at ? Double(clock - at) / 1e9 : .infinity
            return (now.addingTimeInterval(-min(age, 120)), age <= 60 ? value(sample) : nil)
        }
    }
    private var temperatureValues: [(Date, Double?)] { systemTelemetry.suffix(60).map { ($0.date, now.timeIntervalSince($0.date) <= 60 ? (gpuStage ? $0.gpuTemperature : $0.chipTemperature) : nil) } }
    private func freshValue(_ values: [(Date, Double?)]) -> Double? {
        guard let last = values.last, now.timeIntervalSince(last.0) >= 0, now.timeIntervalSince(last.0) <= 6 else { return nil }
        return last.1
    }
    private func chart(_ values: [(Date, Double?)], unit: String, color: Color, minimumMaximum: Double) -> some View {
        let maximum = max(minimumMaximum, (values.compactMap(\.1).max() ?? 0) * 1.1)
        return LightfieldTrendChart(samples: values.map { .init(time: $0.0, value: $0.1.map { $0 / maximum }) }, module: .performance, height: 46,
            primaryColor: color, showsPressureBands: false,
            axis: .labels(top: MSeriesV11PagePresentation.number(maximum, digits: 0), middle: MSeriesV11PagePresentation.number(maximum / 2, digits: 0), bottom: "0"),
            fillsArea: false, showsCurrentValue: false, valueFormat: .scaled(maximum: maximum, unit: unit)).frame(maxWidth: .infinity)
    }
}
