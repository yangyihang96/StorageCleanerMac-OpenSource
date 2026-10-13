import FanControlShared
import SwiftUI

/// The mini window keeps the shared monitor's stored reading. Missing channels
/// are omitted, and a measured zero remains a real reading (D57, D74, D76).
struct GeekHelperPowerMetricsPresentation {
    let powerRows: [GeekSensorReadout]
    let frequencyRows: [GeekSensorReadout]
    let unavailableText: String
    let helpText: String

    init(state: HelperPowerMetricsState, now: Date) {
        let scope = L10n.text("系统助手：CPU/GPU/神经网络引擎功率与频率；CPU 功率不代表整机功率。",
                              "System helper: CPU/GPU/ANE power and frequency; CPU power is not whole-system power.")
        helpText = scope + " " + HelperPowerMetricsPresentation.source + " · "
            + HelperPowerMetricsPresentation.detail(state, now: now)
        switch state {
        case .needsHelper:
            unavailableText = L10n.text("系统助手未连接", "System helper is not connected")
        case .needsUpdate:
            unavailableText = L10n.text("需更新系统助手", "System helper needs an update")
        default:
            unavailableText = L10n.text("尚无读数", "No readings yet")
        }
        guard let sample = HelperPowerMetricsPresentation.sample(state, now: now) else {
            powerRows = []; frequencyRows = []
            return
        }
        func row(_ id: String, _ title: String, _ value: String) -> GeekSensorReadout {
            GeekSensorReadout(id: id, title: title, value: value,
                source: HelperPowerMetricsPresentation.source,
                note: scope + " " + HelperPowerMetricsPresentation.detail(state, now: now), sampledAt: state.sampledAt)
        }
        powerRows = [
            ("cpu", "CPU", sample.cpuMilliwatts),
            ("gpu", "GPU", sample.gpuMilliwatts),
            ("ane", L10n.text("神经网络引擎", "Neural Engine"), sample.aneMilliwatts),
        ].compactMap { id, title, value in
            value.map { row(id, title, HardwareReadingText.watts($0 / 1_000)) }
        }
        var frequencies: [GeekSensorReadout] = []
        for (kind, title) in [(PowermetricsSample.ClusterFrequency.Kind.performance, L10n.text("性能簇", "Performance Cluster")),
                              (.efficiency, L10n.text("能效簇", "Efficiency Cluster"))] {
            let clusters = sample.clusters.filter { $0.kind == kind }
            frequencies += clusters.map {
                row("cluster-\($0.name)", title + (clusters.count > 1 ? " · " + $0.name : ""),
                    HardwareReadingText.megahertz($0.megahertz))
            }
        }
        if let frequency = sample.gpuMegahertz {
            frequencies.append(row("gpu-frequency", "GPU", HardwareReadingText.megahertz(frequency)))
        }
        frequencyRows = frequencies
    }
}

/// A passive leaf subscription: the existing resident scheduler owns sampling
/// and the visible/hidden/low-power cadence. Rendering cannot request the helper.
struct GeekHelperPowerMetricsCards<Content: View>: View {
    @ObservedObject var monitor: HelperPowerMetricsMonitor
    @ViewBuilder let content: (GeekHelperPowerMetricsPresentation) -> Content

    var body: some View {
        content(GeekHelperPowerMetricsPresentation(state: presentedState, now: Date()))
    }

    private var presentedState: HelperPowerMetricsState {
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled { return MiniWindowDemoData.helperPowerMetricsState }
#endif
        return monitor.state
    }
}

extension MenuBarAdvancedStatusView {
    var geekHelperPowerMetricsCards: some View {
        GeekHelperPowerMetricsCards(monitor: store.helperPowerMetricsMonitor) { presentation in
            VStack(spacing: GeekPanelLayout.detailSpacing) {
                geekHelperReadoutCard(L10n.text("功率", "POWER"), rows: presentation.powerRows,
                    unavailableText: presentation.unavailableText)
                geekHelperReadoutCard(L10n.text("频率", "FREQUENCY"), rows: presentation.frequencyRows,
                    unavailableText: presentation.unavailableText)
            }
            .help(presentation.helpText)
        }
    }

    @ViewBuilder
    func geekHelperReadoutCard(_ title: String, rows: [GeekSensorReadout], unavailableText: String) -> some View {
        if !rows.isEmpty {
            geekSensorReadoutCard(title, rows: rows)
        } else {
            GeekHelperPowerMetricsUnavailableCard(title: title, detail: unavailableText)
        }
    }
}

struct GeekHelperPowerMetricsUnavailableCard: View {
    let title: String
    let detail: String
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.selected-category.v1") private var settingsCategory = SettingsCategory.general

    var body: some View {
        GeekCombinedCard(height: GeekSensorReadoutLayout.cardHeight(rowCount: 1)) {
            VStack(alignment: .leading, spacing: 0) {
                GeekSectionTitle(title: title)
                HStack(spacing: 6) {
                    Text(detail).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(L10n.text("开启", "Enable")) {
                        settingsCategory = .accessAndSetup
                        SystemHelperSettingsNavigation.shared.requestID = UUID()
                        openSettings()
                    }
                    .buttonStyle(ResponsivePlainButtonStyle())
                    .accessibilityLabel(L10n.text("开启系统助手", "Enable System Helper"))
                }
                .font(AdvancedPanelTypography.caption)
                .frame(height: 23)
            }
        }
    }
}
