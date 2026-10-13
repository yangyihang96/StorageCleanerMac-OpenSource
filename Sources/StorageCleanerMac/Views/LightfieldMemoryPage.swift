import SwiftUI

struct LightfieldMemoryPage: View {
    @Environment(\.colorScheme) private var scheme
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
    @Environment(\.featureDemoPrimaryAction) private var demoAction
#endif
    @ObservedObject var store: ScanStore
    let snapshot: MemorySnapshot?
    let displaySnapshot: MemorySnapshot?
    let trendPoints: [MenuBarTelemetryPoint]
    var startsWithProcesses = false
    var showsResultsWhenSampled = false
    @Binding var showsProcesses: Bool
    @State private var scope = 0
    @State private var selection: LightfieldTrendSelection?
    @State private var requestedPressurePreview = false

    private var result: Bool {
        startsWithProcesses || showsProcesses || (showsResultsWhenSampled && snapshot != nil && !requestedPressurePreview)
    }
    private var palette: FeatureLightfieldPalette { .resolve(scheme) }
    private var display: MemorySnapshot? { displaySnapshot ?? snapshot }
    private var pressureStatus: FeatureLightfieldStatus {
        switch display?.reportablePressureLevel {
        case .normal: .normal
        case .elevated: .warning
        case .critical: .failure
        case nil: .unknown
        }
    }
    private var groups: [MemoryAppUsage] {
        snapshot.map { LightfieldPerformancePresentation.memoryGroups($0, scope: scope) } ?? []
    }
    private var selectedAmount: FeatureLightfieldAmount { .parse(ByteFormat.string(store.selectedMemoryAppEstimatedBytes)) }
    private var actionTitle: String {
        if !result { return L10n.text("查看进程与应用", "View Processes & Apps") }
        if store.selectedMemoryAppCount > 0 {
            return L10n.text("退出所选应用 · \(store.selectedMemoryAppCount) 个", "Quit Selected Apps · \(store.selectedMemoryAppCount)")
        }
        return L10n.text("刷新内存快照", "Refresh Memory Snapshot")
    }
    var body: some View {
        FeatureLightfieldPage(module: .memory, phase: result ? .result : .landing,
            title: L10n.text("内存管理", "Memory Management"),
            status: display?.reportablePressureLevel.map { L10n.text("压力\($0.title) · 进程快照仅含可读样本", "Pressure \($0.title) · Readable process samples only") }
                ?? L10n.text("内存状态不可用 · 刷新以重新读取", "Memory unavailable · Refresh to read again"),
            safety: L10n.text("先保存工作 · 请求正常退出，不强制结束", "Save your work · Normal quit, never force quit"),
            actionTitle: actionTitle,
            actionAccessibilityLabel: actionTitle,
            actionEnabled: result && store.selectedMemoryAppCount > 0 ? store.canRequestMemoryQuitActions : store.canRefreshMemory,
            showsArtwork: !result, action: primaryAction) {
            if result { results } else { landing }
        }
        .onAppear { scope = store.memoryShowsAllProcesses ? 0 : 1 }
    }
    private func primaryAction() {
#if DEBUG
        if let demoAction { demoAction(); return }
        guard !isFixture else { showsProcesses = true; return }
#endif
        if !result {
            requestedPressurePreview = false
            showsProcesses = true
            if snapshot == nil { store.refreshMemory() }
        } else if store.selectedMemoryAppCount > 0 {
            // Existing confirmation and normal-quit implementation remain in Store.
            store.requestQuitSelectedMemoryProcesses()
        } else { store.refreshMemory() }
    }
    private var landing: some View {
        FeatureLightfieldOptions {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    Circle().fill(pressureStatus.color(palette)).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(L10n.text("实时压力预览", "Live Pressure Preview")).font(.system(size: 13)).foregroundStyle(palette.fg2)
                }
                HStack(spacing: 24) {
                    LightfieldRing(diameter: 120, progress: display?.measuredUsedRatio,
                        color: pressureStatus.color(palette),
                        value: display?.measuredUsedRatio.map { String(format: "%.0f", $0 * 100) } ?? "—",
                        unit: "%", label: display?.reportablePressureLevel?.title ?? L10n.text("未提供", "Unavailable"),
                        labelIsStatus: true, probeID: "memory.usageRing")
                    LightfieldMetricGroup(metrics: memoryMetrics, probeID: "memory.landing.metrics")
                }
                LightfieldTrendChart(samples: trendSamples, module: .memory,
                    title: L10n.text("2 分钟内存占用", "Memory Use · 2 Minutes"), legend: .pressure,
                    onSelection: { selection = $0 })
                    .padding(.top, 8)
                Text(selectionText).font(.system(size: 13)).foregroundStyle(palette.fg2)
                    .lineLimit(1).truncationMode(.middle).help(selectionText)
                // The monitor history contains totals, not historical app lists.
                // Do not claim today's process snapshot describes a hovered moment.
                if let snapshot {
                    Text(L10n.text("最新进程快照：", "Latest Process Snapshot: ") + snapshot.appsByResidentUsage.prefix(3)
                        .map { $0.name + " " + ByteFormat.string($0.bytes) }.joined(separator: " · "))
                        .font(.system(size: 13)).foregroundStyle(palette.fg2)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
    private var trendSamples: [LightfieldTrendSample] {
        trendPoints.map { LightfieldTrendSample(time: $0.date,
            value: $0.memory.flatMap { $0.isFinite ? $0 / 100 : nil }) }
    }
    private var selectionText: String {
        guard let selection, let average = selection.average else {
            return L10n.text("悬停回看 · 拖选看平均", "Hover to Inspect · Drag for the Average")
        }
        return L10n.text("所选区间平均 \(String(format: "%.1f%%", average * 100)) · \(selection.measuredCount) 个样本",
            "Range Average \(String(format: "%.1f%%", average * 100)) · \(selection.measuredCount) Samples")
    }
    private var memoryMetrics: [LightfieldMetric] {
        let used = display?.measuredUsedBytes.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—"
        let total = display?.measurements.physicalBytes.value.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—"
        return [
            .init(id: "used", label: L10n.text("已用 / 总量", "Used / Total"), value: used + " / " + total),
            .init(id: "cache", label: L10n.text("缓存", "Cache"), value: display?.measurements.cachedBytes.value.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—"),
            .init(id: "swap", label: L10n.text("交换", "Swap"), value: display?.measurements.swapUsedBytes.value.map { ByteFormat.string(Int64(clamping: $0)) } ?? "—")]
    }
    private var results: some View {
        GeometryReader { proxy in
            LightfieldResultContent(listHeader: AnyView(tableHeader(width: proxy.size.width))) {
                LightfieldMemoryResultOverview(usedAndTotal: memoryMetrics[0].value,
                    secondary: overviewSecondary, contentWidth: proxy.size.width,
                    note: display?.reportablePressureLevel.map { L10n.text("压力 \($0.title)", "Pressure \($0.title)") },
                    probeID: "lightfield.memory.overview")
            } rows: {
                ForEach(groups) { app in
                    LightfieldMemoryAppRow(app: app,
                        processes: snapshot.map { LightfieldPerformancePresentation.children(of: app, in: $0) } ?? [], store: store,
                        initiallyExpanded: false)
                        .lightfieldComponentProbe("memory.row." + app.id)
                }
            }
        }
    }
    private var overviewSecondary: [LightfieldMetric] {
        Array(memoryMetrics.dropFirst()) + [
            .init(id: "selection", label: store.selectedMemoryAppCount > 0
                ? L10n.text("选中应用的预计释放量", "Estimated Release from Selected Apps")
                : L10n.text("已采样应用与进程", "Sampled Apps & Processes"),
                value: store.selectedMemoryAppCount > 0
                    ? selectedAmount.value.map { String(format: "%.*f", selectedAmount.precision, $0) } ?? "—"
                    : "\(groups.count)",
                unit: store.selectedMemoryAppCount > 0 ? selectedAmount.unit : L10n.text("项", "items"))]
    }
    private func tableHeader(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if width < 700 {
                LightfieldMetricGroup(metrics: overviewSecondary, probeID: "memory.overview.details")
                    .padding(.bottom, 8)
            }
            resultControls
            if let result = store.memoryOptimizationResult {
                // Preserve the actual verification outcome; a changed total alone
                // is not proof an application quit or memory was reclaimed.
                Text(LightfieldPerformancePresentation.memoryOutcome(result.status) + " · " + result.detail).font(.system(size: 13))
                    .foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            }
            FeatureLightfieldHairline()
            HStack {
                Text(L10n.text("应用与进程", "Apps & Processes"))
                Spacer()
                Text(L10n.text("内存占用 · CPU% · 能耗影响", "Memory · CPU% · Energy Impact"))
            }.font(.system(size: 13)).foregroundStyle(palette.fg3).lineLimit(1).frame(height: 28)
            FeatureLightfieldHairline()
            if groups.isEmpty {
                Text(L10n.text("本次没有可读的进程样本", "No Readable Process Samples"))
                    .font(.system(size: 15)).foregroundStyle(palette.fg2).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            }
        }
    }
    private var resultControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            LightfieldTextSegments(titles: [L10n.text("占用最多", "Most Memory"), L10n.text("可退出应用", "Quittable Apps"),
                L10n.text("系统进程", "System Processes")], selection: $scope, module: .memory)
                .onChange(of: scope) { _, value in store.memoryShowsAllProcesses = value != 1 }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { pressurePreview; selectionCommands; resultCount }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack { pressurePreview; Spacer(minLength: 0); resultCount }
                    selectionCommands
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(FeatureLightfieldRowButtonStyle()).font(.system(size: 13)).foregroundStyle(palette.fg2)
        }
    }
    private var pressurePreview: some View {
        Button(L10n.text("压力预览", "Pressure Preview")) { requestedPressurePreview = true; showsProcesses = false }
    }
    private var resultCount: some View {
        Text(L10n.text("\(groups.count) 项 · 按占用排序", "\(groups.count) Items · Sorted by Memory"))
            .foregroundStyle(palette.fg3).lineLimit(1)
    }
    // D67 migrates the old command strip to text controls. Its selection
    // semantics and VoiceOver names remain available in every selection state.
    private var selectionCommands: some View {
        HStack(spacing: 12) {
            Button(L10n.text("选择建议退出项", "Select Suggested Apps")) { _ = store.selectRecommendedMemoryApps() }
                .disabled(!store.canRequestMemoryQuitActions || snapshot?.recommendedQuitApps.isEmpty != false)
                .lightfieldComponentProbe("lightfield.memory.command.suggested")
            Button(L10n.text("全选", "Select All")) {
                snapshot?.appsByResidentUsage.filter { $0.canQuit && $0.bundlePath?.hasSuffix(".app") == true }
                    .forEach { store.setMemoryAppUsageSelection($0, isSelected: true) }
            }.disabled(!store.canRequestMemoryQuitActions)
                .lightfieldComponentProbe("lightfield.memory.command.selectAll")
            if store.selectedMemoryAppCount > 0 {
                Button(L10n.text("清空选择", "Clear Selection")) { store.clearMemoryProcessSelection() }
                    .disabled(!store.canRequestMemoryQuitActions)
                    .lightfieldComponentProbe("lightfield.memory.command.clear")
            }
        }
    }

}

/// Production overview renderer, independent of Store operations so native
/// header/VoiceOver tests do not need a home-directory mutation fixture.
struct LightfieldMemoryResultOverview: View {
    let usedAndTotal: String
    let secondary: [LightfieldMetric]
    let contentWidth: CGFloat
    let note: String?
    var probeID = "lightfield.memory.overview"
    var body: some View {
        LightfieldSummary(module: .memory, label: L10n.text("内存总览 · 已用 / 总量", "Memory Overview · Used / Total"),
            value: usedAndTotal, unit: "", secondary: contentWidth >= 700 ? secondary : [],
            note: note, probeID: probeID)
    }
}

struct LightfieldMemoryAppRow: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.featureLightfieldCompactResults) private var compactResults
    let app: MemoryAppUsage
    let processes: [MemoryProcess]
    @ObservedObject var store: ScanStore
    var initiallyExpanded = false
    @State private var expanded = false
    @State private var appliedInitialExpansion = false
    private var selectable: Bool { app.canQuit && app.bundlePath?.hasSuffix(".app") == true }
    var body: some View {
        GeometryReader { proxy in
            let metricsWidth = min(336, max(124, proxy.size.width * 0.40))
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if selectable {
                        FeatureLightfieldCheck(selected: store.isMemoryAppUsageSelected(app), module: .memory,
                            accessibilityLabel: L10n.text("选择 \(app.name)", "Select \(app.name)"),
                            action: { store.setMemoryAppUsageSelection(app, isSelected: !store.isMemoryAppUsageSelected(app)) })
                            .disabled(!store.canRequestMemoryQuitActions)
                            .lightfieldComponentProbe("lightfield.memory.selection." + app.id)
                    } else { LightfieldStatusGlyph(status: .readOnly) }
                }.frame(width: 20, height: rowHeight)
                LightfieldExpandableRow(title: app.name,
                    metadata: L10n.text("\(app.processCount) 个进程 · 内存 \(ByteFormat.string(app.bytes)) · CPU 与能耗影响未提供",
                        "\(app.processCount) Processes · Memory \(ByteFormat.string(app.bytes)) · CPU and Energy Impact Unavailable"),
                    subtitle: L10n.text("\(app.processCount) 个进程", "\(app.processCount) Processes"),
                    trailing: AnyView(values(memory: ByteFormat.string(app.bytes), percent: app.percent, width: metricsWidth)),
                    rowHeight: rowHeight, reportsCompactBoundaries: true, probeID: "memory.app." + app.id, expanded: $expanded) {
                    LightfieldAppIcon(path: app.bundlePath ?? app.iconPath, processIdentifier: app.processIDs.first, size: .large)
                } content: {
                    ForEach(processes) { process in
                        HStack(spacing: 16) {
                            LightfieldAppIcon(path: process.bundlePath, processIdentifier: process.id, size: .medium)
                            Text(LightfieldPerformancePresentation.processName(name: process.name, path: process.path, application: app.name))
                                .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lightfieldComponentProbe("memory.child.text.\(process.id)")
                            Text(process.availability == .available ? ByteFormat.string(process.residentBytes) : "—")
                                .font(.system(size: 13)).monospacedDigit().lineLimit(1).frame(width: metricsWidth, alignment: .trailing)
                        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                            .accessibilityElement(children: .combine)
                            .frame(height: 48).help(LightfieldPerformancePresentation.processHelp(id: process.id, path: process.path))
                            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
                            .lightfieldResultRowBoundary()
                    }
                }
            }
        }.frame(height: rowHeight + (expanded ? CGFloat(processes.count) * 48 : 0))
        .onAppear {
            guard !appliedInitialExpansion else { return }
            appliedInitialExpansion = true
            expanded = initiallyExpanded
        }
    }
    private var rowHeight: CGFloat { compactResults ? FeatureLightfield.compactProcessRowHeight : 56 }
    private func values(memory: String, percent: Double, width: CGFloat) -> some View {
        VStack(spacing: 6) {
            LightfieldMetricGroup(metrics: [.init(id: "memory", label: L10n.text("内存占用", "Memory Use"), value: memory),
                .init(id: "cpu", label: "CPU%", value: "—"), .init(id: "energy", label: L10n.text("能耗影响", "Energy Impact"), value: "—")],
                showsLabels: false, probeID: "memory.values." + app.id)
            LightfieldDataBar(progress: percent.isFinite ? percent / 100 : nil, module: .memory,
                accessibilityLabel: L10n.text("内存占比", "Memory Share"))
        }.frame(width: width).help(L10n.text("内存快照未提供 CPU 与能耗影响读数", "The Memory Snapshot Does Not Provide CPU or Energy Impact"))
    }
}
