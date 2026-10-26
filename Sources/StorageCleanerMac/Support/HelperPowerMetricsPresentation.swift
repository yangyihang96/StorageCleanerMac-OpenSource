import Combine
import FanControlShared
import Foundation

extension HelperPowerMetricsState {
    var sampledAt: Date? {
        if case .available(_, let at) = self { return at }
        return nil
    }
}

enum HelperPowerMetricsPresentation {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let value: String
    }

    static var source: String { L10n.text("系统助手 · powermetrics", "System Helper · powermetrics") }
    static var title: String { L10n.text("芯片功率与频率 · 系统助手", "Chip Power & Frequency · System Helper") }

    static func sample(_ state: HelperPowerMetricsState, now: Date) -> PowermetricsSample? {
        guard case .available(let sample, let at) = state, sample.isValid,
              now.timeIntervalSince(at).isFinite, now >= at else { return nil }
        return sample
    }

    static func rows(_ state: HelperPowerMetricsState, now: Date) -> [Row] {
        let sample = sample(state, now: now)
        var rows = [
            Row(id: "cpu", title: "CPU", value: watts(sample?.cpuMilliwatts)),
            Row(id: "gpu", title: "GPU", value: watts(sample?.gpuMilliwatts)),
            Row(id: "ane", title: L10n.text("神经网络引擎", "Neural Engine"), value: watts(sample?.aneMilliwatts)),
        ]
        let clusters = sample?.clusters ?? []
        for (kind, title) in [(PowermetricsSample.ClusterFrequency.Kind.performance, L10n.text("性能簇频率", "Performance Cluster")),
                              (.efficiency, L10n.text("能效簇频率", "Efficiency Cluster"))] {
            let matching = clusters.filter { $0.kind == kind }
            if matching.isEmpty {
                rows.append(Row(id: kind.rawValue, title: title, value: "—"))
            } else {
                rows += matching.map {
                    Row(id: $0.name, title: title + (matching.count > 1 ? " · " + $0.name : ""),
                        value: frequency($0.megahertz))
                }
            }
        }
        rows.append(Row(id: "gpu-frequency", title: L10n.text("GPU 频率", "GPU Frequency"), value: frequency(sample?.gpuMegahertz)))
        return rows
    }

    static func detail(_ state: HelperPowerMetricsState, now: Date) -> String {
        switch state {
        case .needsHelper: L10n.text("需要系统助手", "System Helper Required")
        case .needsUpdate: L10n.text("需要更新系统助手", "System Helper Update Required")
        case .sampling: L10n.text("正在采样", "Sampling")
        case .available:
            if let sample = sample(state, now: now) {
                PanelTimestampFormat.age(state.sampledAt ?? now, now: now) + " · " + L10n.text("采样时长 \(String(format: "%.2f", sample.durationSeconds)) 秒 · 系统功率模型",
                          "Sample duration \(String(format: "%.2f", sample.durationSeconds)) s · System power model")
            } else { L10n.text("读数已过期", "Reading Expired") }
        case .failed(let failure):
            switch failure {
            case .timedOut: L10n.text("采样超时", "Sampling Timed Out")
            case .throttled, .busy: L10n.text("等待下一次采样", "Waiting for Next Sample")
            default: L10n.text("暂无有效采样", "No Valid Sample")
            }
        }
    }

    private static func watts(_ milliwatts: Double?) -> String {
        milliwatts.map { HardwareReadingText.watts($0 / 1_000) } ?? "—"
    }
    private static func frequency(_ megahertz: Double?) -> String {
        megahertz.map(HardwareReadingText.megahertz) ?? "—"
    }
}

/// A navigation request only; it cannot register or authorize the daemon.
@MainActor
final class SystemHelperSettingsNavigation: ObservableObject {
    static let shared = SystemHelperSettingsNavigation()
    static let anchor = "system-helper-permission"
    @Published var requestID: UUID?
}
