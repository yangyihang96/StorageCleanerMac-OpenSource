import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let dashboardModule = UTType(exportedAs: "com.local.StorageCleanerMac.dashboard-module")
}
private struct DashboardModuleDrag: Codable, Transferable {
    let module: GeekDashboardModule
    let editorID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .dashboardModule)
    }
}

struct MiniWindowEmptyConfigurationView: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 8) {
            Text(L10n.text("未显示任何模块", "No visible modules"))
            Button(L10n.text("小窗设置…", "Panel Settings…")) {
                UserDefaults.standard.set("miniWindow", forKey: "settings.selected-category.v1")
                openSettings()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
    }
}

struct MiniWindowConfigurationSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var owner = GeekDashboardConfigurationStore.shared
    @Binding var draft: GeekDashboardDraft
    @State private var editorID = UUID()
    @State private var notebookExample = true
    @State private var notice: String?
    @State private var previewSection: GeekDashboardModule?
    @State private var previewHistory = false
    @State private var targetedGap: Int?
    @State private var previewRanges: [GeekDashboardModule: GeekChartRange] = [:]

    var body: some View {
        SettingsPreviewColumns {
            editor
        } preview: {
            SettingsMiniWindowPreview(configuration: draft.value, notebookExample: notebookExample)
#if DEBUG
                .layoutProbe("miniSettings.preview")
#endif
        } actions: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { actions }
                        VStack(alignment: .leading, spacing: 8) { actions }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 16)
#if DEBUG
                .layoutProbe("miniSettings.actions")
#endif
                if let notice {
                    Text(notice).font(AppTypography.caption)
                        .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg2)
                }
            }
        }
        .onChange(of: owner.revision) {
            if !draft.isDirty { draft.didApply(owner.configuration) }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("模块与顺序", "Modules & Order"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg2)
                .frame(height: 32, alignment: .leading)
            FeatureLightfieldHairline()
            ForEach(Array(draft.value.modules.enumerated()), id: \.element.id) { index, item in
                gap(index)
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal")
                        .draggable(DashboardModuleDrag(module: item.module, editorID: editorID))
                        .accessibilityLabel(L10n.text("拖动调整顺序", "Drag to reorder"))
                    Button {
                        draft.value.setModule(item.module, isVisible: !item.isVisible)
                    } label: {
                        HStack(spacing: 12) {
                            FeatureLightfieldCheck(selected: item.isVisible, module: .overview)
                            Text(item.module.title).font(.system(size: 16)).lineLimit(1)
                                .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(FeatureLightfieldRowButtonStyle())
                    .accessibilityLabel(item.module.title)
                    .accessibilityValue(item.isVisible ? L10n.text("已选", "Selected") : L10n.text("未选", "Not selected"))
                    Button(L10n.text("上移", "Move up")) { draft.value.moveModule(item.module, by: -1) }
                        .disabled(index == 0)
                        .accessibilityLabel(L10n.text("上移", "Move up") + item.module.title)
                    Button(L10n.text("下移", "Move down")) { draft.value.moveModule(item.module, by: 1) }
                        .disabled(index == draft.value.modules.count - 1)
                        .accessibilityLabel(L10n.text("下移", "Move down") + item.module.title)
                }
                .buttonStyle(FeatureLightfieldRowButtonStyle())
                .foregroundStyle(FeatureLightfieldPalette.accent(.overview))
                .frame(height: 44)
                .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            }
            gap(draft.value.modules.count)
            LightfieldSettingsRow {
                Toggle(L10n.text("MacBook 示例（仅预览）", "MacBook example (preview only)"), isOn: $notebookExample)
                    .toggleStyle(.switch)
                    .lightfieldComponentProbe("miniSettings.notebookExample")
            }
            .onChange(of: notebookExample) { previewSection = nil; previewHistory = false }
            readOnlyExamples.padding(.vertical, 12)
        }
        .onChange(of: draft.value.modules) { previewSection = nil; previewHistory = false }
    }

    @ViewBuilder private var actions: some View {
        Button(L10n.text("恢复默认", "Defaults")) { draft.reset() }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .lightfieldComponentProbe("miniSettings.actions.defaults")
        Button(L10n.text("取消", "Cancel")) { draft.cancel(); notice = nil }
            .disabled(!draft.isDirty).buttonStyle(FeatureLightfieldRowButtonStyle())
            .lightfieldComponentProbe("miniSettings.actions.cancel")
        Button(L10n.text("应用", "Apply")) { apply() }
            .buttonStyle(FeatureLightfieldButtonStyle(module: .overview))
            .frame(width: 180, height: 52)
            .disabled(!draft.isDirty)
            .lightfieldComponentProbe("miniSettings.actions.apply")
    }

    private func gap(_ index: Int) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(targetedGap == index ? AppAppearanceColors.controlAccent : Color.clear)
            .frame(height: 8).contentShape(Rectangle())
            .dropDestination(for: DashboardModuleDrag.self) { items, _ in
                guard items.count == 1, let item = items.first, item.editorID == editorID else { return false }
                draft.value.moveModule(item.module, toGap: index)
                return true
            } isTargeted: { active in
                if active { targetedGap = index }
                else if targetedGap == index { targetedGap = nil }
            }
            .accessibilityHidden(true)
    }

    private func apply() {
        do {
            try owner.applyLive(draft.value)
            draft.didApply(owner.configuration)
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Preserve the existing read-only detail/history ability separately from
    /// the complete level-one sample; no live routing or range setting changes.
    private var readOnlyExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu(L10n.text("只读详情与历史示例", "Read-only detail and history examples")) {
                ForEach(draft.value.modules.filter { $0.isVisible && $0.module.isAvailableInOverview
                    && ($0.module != .power || notebookExample) }) { item in
                    Button(item.module.title) { previewSection = item.module; previewHistory = false }
                }
            }
            if let section = previewSection {
                HStack {
                    Text(section.title).font(AppTypography.sectionTitle)
                    Spacer(minLength: 0)
                    Button(L10n.text("收起示例", "Close example")) { previewSection = nil; previewHistory = false }
                }
                Group {
                    if previewHistory {
                        MiniWindowPreviewHistory(module: section, range: previewRanges[section] ?? .oneHour)
                            .environment(\.geekChartRangeSelection, GeekChartRangeSelection(
                                range: previewRanges[section] ?? .oneHour,
                                select: { previewRanges[section] = $0 }))
                    } else {
                        MiniWindowConfigurationPreviewCard(module: section)
                            .frame(width: MiniWindowStyleTokens.overviewSize.width - GeekPanelLayout.contentPadding * 2)
                            .padding(GeekPanelLayout.contentPadding)
                            .metricPanelShell()
                    }
                }
                .environment(\.controlPaletteCoordinator, nil)
                .environment(\.miniWindowPreviewDate, MiniWindowConfigurationPreviewCard.history.last?.date)
                .modifier(PanelAppearanceEnvironment())
                Button(previewHistory ? L10n.text("收起历史", "Hide history") : L10n.text("只读历史示例", "Read-only history example")) {
                    previewHistory.toggle()
                }
            }
        }
    }

}

/// Static values only; does not import or instantiate any production stores.
struct MiniWindowConfigurationPreviewCard: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.panelChartAccentColor) private var chartAccent
    let module: GeekDashboardModule
    // Immutable Settings samples are intentionally available in Release.
    static let history: [MenuBarTelemetryPoint] = (0..<120).map { index in
        let user = index == 119 ? 22 : 18 + Double(index % 9)
        return MenuBarTelemetryPoint(date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 30)),
            cpuTotal: user + 12, cpuUser: user, cpuSystem: 12, gpu: 12, memory: 81, memoryPressure: 49,
            chipTemperature: 53, fanRPM: 1_620, downBytesPerSecond: 3_774_874,
            upBytesPerSecond: 419_840)
    }
    static let fanTelemetry = FanTelemetryState(actualRPM: 1_620, minRPM: nil, maxRPM: nil,
        targetRPM: nil, fanCount: 1, timestamp: nil, telemetryAvailable: true,
        isSampling: false, isFanless: false,
        readings: [.init(index: 0, actualRPM: 1_620, minimumRPM: nil, maximumRPM: nil, targetRPM: nil)])
    static var fanEntry: FanControlEntryPresentation {
        FanControlEntryPresentation(telemetry: fanTelemetry, helperState: .enabled,
                                   observedMode: .systemAutomatic, manualPercentage: nil)
    }
    var body: some View {
        Group {
            switch module {
            case .processorGraphics:
                GeekProcessorPresentation(cpuChartHistory: Self.history, cpuChartRange: .oneHour, samplingInterval: 1,
                    processorTint: metricColors.cpuUser, geekCPUUserBarColor: metricColors.cpuUser, geekCPUSystemBarColor: metricColors.cpuSystem,
                    // D43: the same title readout as the live card (simulated values).
                    headerFrequencyText: "3.60 GHz", headerTemperatureText: "53°C",
                    headerReadoutTint: metricColors.temperature(53, chartAccent: chartAccent))
            case .coreMetrics:
                GeekMemoryPresentation(memoryRingUsedPercentText: "81%", memoryRingUsedProgress: 0.81,
                    memoryRingSegments: [.init(id: "app", progress: 0.55, color: metricColors.memoryApp),
                                         .init(id: "wired", progress: 0.18, color: metricColors.memoryWired),
                                         .init(id: "compressed", progress: 0.08, color: metricColors.memoryCompressed)],
                    pressure: 49, memoryTint: metricColors.memoryPressure(for: .normal))
            case .network:
                GeekNetworkPresentation(networkUpText: "410 KiB/s", networkDownText: "3.6 MiB/s", networkChartHistory: Self.history,
                    networkChartRange: .oneHour, resolvedUploadTint: metricColors.networkUpload, resolvedDownloadTint: metricColors.networkDownload)
            case .disk:
                GeekDiskPresentation(storageSnapshot: .init(totalBytes: 1_000_000_000_000, availableBytes: 560_000_000_000),
                    volumeName: "Macintosh HD", geekPrimaryDiskHealthText: "96%",
                    geekPrimaryDiskHealthTint: AppDesignTokens.Palette.success,
                    healthHelp: L10n.text("仅为模拟数据", "Simulated data only"))
            case .power:
                GeekBatteryPresentation(percent: 76, geekOverviewPowerSourceAndModeTitle: L10n.text("电源适配器 · 已接通电源", "Power Adapter · Connected"),
                    geekOverviewBatteryHelpText: L10n.text("仅为模拟数据", "Simulated data only"))
            case .sensors:
                GeekSensorsPresentation(geekCompactTemperatureText: "53°C", geekCompactFrequencyText: "3.60 GHz",
                    temperatureProgress: 0.53, temperatureTint: metricColors.temperature(53, chartAccent: chartAccent),
                    geekOverviewGPUTemperature: 49, gpuUsageText: "12%", gpuUsageProgress: 0.12,
                    resolvedGPUTint: metricColors.temperature(49, chartAccent: chartAccent),
                    geekFanTelemetry: Self.fanTelemetry, openDetail: {},
                    geekCompactGPUFrequencyText: "0.34 GHz", fanControlEntry: Self.fanEntry)
                    .allowsHitTesting(false)
                    .environment(\.controlPaletteCoordinator, nil)
            default: EmptyView()
            }
        }.frame(maxWidth: .infinity)
    }
}

/// The same snapshot-only history views used by live third-level windows.
/// Range selection belongs to this preview, never to the live sampling settings.
private struct MiniWindowPreviewHistory: View {
    @Environment(\.panelMetricColors) private var metricColors
    @Environment(\.panelChartAccentColor) private var chartAccent
    let module: GeekDashboardModule
    let range: GeekChartRange
    private static let diskPoints = MiniWindowConfigurationPreviewCard.history.map {
        NativeDiskIOPoint(date: $0.date, readBytesPerSecond: 4_000_000,
                          writeBytesPerSecond: 2_000_000, readOperationsPerSecond: 40,
                          writeOperationsPerSecond: 20, intervalStart: $0.date.addingTimeInterval(-30))
    }
    private static let powerPoints = MiniWindowConfigurationPreviewCard.history.enumerated().map { index, point in
        MenuBarPowerHistoryPoint(date: point.date, chargePercent: 85 - Double(index) * 5 / 119,
                                 batteryPowerWatts: -8, isCharging: false)
    }
    var body: some View {
        Group {
            switch module {
            case .processorGraphics:
                GeekProcessorActivityHoverDetail(points: MiniWindowConfigurationPreviewCard.history,
                    duration: range.duration, userValue: "22%", systemValue: "12%")
            case .network:
                GeekNetworkHistoryHoverDetail(points: MiniWindowConfigurationPreviewCard.history,
                    duration: range.duration, uploadValue: "410 KiB/s", downloadValue: "3.6 MiB/s")
            case .coreMetrics:
                GeekMemoryHistoryHoverDetail(points: MiniWindowConfigurationPreviewCard.history,
                    duration: range.duration, currentValue: "81%", pressure: "49%", snapshot: nil)
            case .sensors:
                GeekSensorMetricHoverDetail(title: "CPU", currentValue: "53°C",
                    points: MiniWindowConfigurationPreviewCard.history, channel: .chipTemperature,
                    unit: .temperature, valueRange: 0...100, tint: metricColors.sensorGraph(chartAccent: chartAccent),
                    duration: range.duration)
            case .disk:
                GeekDiskThroughputHoverDetail(points: Self.diskPoints, counters: nil,
                    duration: range.duration, mode: .write)
            case .power:
                GeekBatteryHistoryHoverDetail(points: Self.powerPoints,
                    tint: metricColors.battery, chargingTint: metricColors.batteryCharging)
            default:
                Text(L10n.text("该模块暂未提供历史预览。", "History preview is not available for this module yet."))
            }
        }
        .metricPanelShell()
    }
}
