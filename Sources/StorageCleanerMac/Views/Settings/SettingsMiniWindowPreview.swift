import SwiftUI

/// An inert, full-size sample available in Release Settings. Its immutable
/// values describe this preview only, never the user's hardware or readings.
struct SettingsMiniWindowPreview: View {
    let configuration: GeekDashboardConfiguration
    var notebookExample = true
    @Environment(\.colorScheme) private var colorScheme

    var modules: [GeekDashboardModule] {
        configuration.modules.filter {
            $0.isVisible && $0.module.isAvailableInOverview
                && ($0.module != .power || notebookExample)
        }.map(\.module)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("实时预览 · 与菜单栏小窗同尺寸", "Live preview · Same size as the menu-bar panel"))
                .font(.system(size: 13))
                .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg2)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
                .help(L10n.text("模拟数据，仅用于预览外观与模块顺序；不采样、不控制硬件。",
                               "Simulated data for appearance and module order; no sampling or hardware control."))
#if DEBUG
                .layoutProbe("settings.preview.caption")
#endif
            Color.clear.frame(height: 8)
            SettingsMiniWindowStatusPreview(notebookExample: notebookExample)
                .modifier(PanelAppearanceEnvironment())
#if DEBUG
                .layoutProbe("settings.preview.status")
#endif
            Color.clear.frame(height: 6)
            panel
        }
        .frame(width: MiniWindowStyleTokens.overviewSize.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("模拟小窗预览 · 非实时数据", "Simulated panel preview · Not live data"))
    }

    private var panel: some View {
        GeekOverviewPanel(modules: modules) {
            Text(L10n.text("未显示任何模块", "No visible modules"))
                .font(AdvancedPanelTypography.body)
                .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
        } content: { module in
            MiniWindowConfigurationPreviewCard(module: module)
        }
        .metricPanelShell()
        // Hit testing preserves the live colors; disabled would dim controls.
        // A nil coordinator also blocks AX/programmatic presses on the fan entry.
        .allowsHitTesting(false)
#if DEBUG
        .background(SettingsMiniWindowRenderProbe())
        .layoutProbe("settings.preview.panel")
#endif
        .environment(\.controlPaletteCoordinator, nil)
        .environment(\.miniWindowPreviewDate, MiniWindowConfigurationPreviewCard.history.last?.date)
        .modifier(PanelAppearanceEnvironment())
    }
}

private struct SettingsMiniWindowStatusPreview: View {
    @Environment(\.panelStatusAppearance) private var appearance
    let notebookExample: Bool

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            reading(AppSymbols.Monitor.processor, "34%")
            reading(AppSymbols.Monitor.memory, "81%")
            if notebookExample { reading(AppSymbols.Monitor.battery, "76%") }
        }
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(appearance.ink)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(MiniWindowStyleTokens.shellColor(for: appearance.isNight ? .graphite : .black)
            .opacity(appearance.isNight ? 1 : 0.06))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("模拟菜单栏读数", "Simulated menu-bar readings"))
    }

    private func reading(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(value)
        }
    }
}

#if DEBUG
/// Readback originates under the actual panel's appearance modifier. It does
/// not read defaults or re-resolve preferences in the test fixture.
struct SettingsMiniWindowRenderSnapshot: Equatable, Sendable {
    let identity: UUID
    let visualMode: MiniWindowVisualMode
    let controlScheme: ColorScheme
    let shell: Color
    let backgroundTint: Color?
    let chartAccent: Color?
    let statusInk: Color
    let metrics: [String: Color]
    let gpuTint: Color
    let sensorTint: Color
    let permitsHardwareControl: Bool
}

struct SettingsMiniWindowRenderPreferenceKey: PreferenceKey {
    static let defaultValue: SettingsMiniWindowRenderSnapshot? = nil
    static func reduce(value: inout SettingsMiniWindowRenderSnapshot?,
                       nextValue: () -> SettingsMiniWindowRenderSnapshot?) {
        if let next = nextValue() { value = next }
    }
}

private struct SettingsMiniWindowRenderProbe: View {
    @Environment(\.miniWindowVisualMode) private var visualMode
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelChromePalette) private var chrome
    @Environment(\.panelBackgroundTint) private var background
    @Environment(\.panelChartAccentColor) private var chart
    @Environment(\.panelStatusAppearance) private var status
    @Environment(\.panelMetricColors) private var colors
    @Environment(\.controlPaletteCoordinator) private var coordinator
    @State private var identity = UUID()

    var body: some View {
        Color.clear.preference(key: SettingsMiniWindowRenderPreferenceKey.self,
            value: SettingsMiniWindowRenderSnapshot(identity: identity,
                visualMode: visualMode, controlScheme: scheme,
                shell: chrome?.shell ?? MiniWindowStyleTokens.shellColor(for: visualMode),
                backgroundTint: background, chartAccent: chart, statusInk: status.ink,
                metrics: Dictionary(uniqueKeysWithValues: PanelMetricColorRole.allCases.map {
                    ($0.rawValue, colors.color(for: $0))
                }), gpuTint: colors.gpu(chartAccent: chart),
                sensorTint: colors.sensorGraph(chartAccent: chart),
                permitsHardwareControl: coordinator != nil))
            .allowsHitTesting(false)
    }
}
#endif
