import AppKit
import SwiftUI

struct LightfieldEnergyPage<PowerMetrics: View>: View {
    @Environment(\.colorScheme) private var scheme
    let snapshot: EnergyImpactSnapshot
    @Binding var searchText: String
    @Binding var sortMode: EnergyImpactSortMode
    let canRefresh: Bool
    let refresh: () -> Void
    @ViewBuilder let powerMetrics: PowerMetrics
    @State private var showsSearch = false
    private var palette: FeatureLightfieldPalette { .resolve(scheme) }
    private var currentTotal: String {
        guard !snapshot.apps.isEmpty, snapshot.apps.allSatisfy({ $0.currentEvidence.source != .unknown }) else { return "—" }
        return String(format: "%.2f", snapshot.totalCurrentPowerWatts)
    }
    var body: some View {
        // Filter, sort and maxima are one snapshot per render, shared by every row.
        let presentation = EnergyImpactListPresenter.presentation(apps: snapshot.apps, query: searchText, sortMode: sortMode)
        let apps = presentation.apps
        let maximum = maximumValue(presentation)
        FeatureLightfieldPage(module: .energy, phase: .result, title: L10n.text("能耗", "Energy"),
            status: L10n.text("已采样 · \(ByteFormat.count(snapshot.apps.count)) 个应用 · \(ByteFormat.count(snapshot.processCount)) 个进程", "Sampled · \(ByteFormat.count(snapshot.apps.count)) Apps · \(ByteFormat.count(snapshot.processCount)) Processes"),
            safety: snapshot.calibrationText, actionTitle: L10n.text("重新采样能耗", "Sample Energy Again"),
            actionEnabled: canRefresh, showsArtwork: false, action: refresh) {
            GeometryReader { proxy in
                LightfieldResultContent(listHeader: AnyView(VStack(spacing: 0) {
                    tableHeader(width: proxy.size.width, isEmpty: apps.isEmpty)
                    // Keep the potentially large first disclosure outside the
                    // stable-row lazy estimate, without expanding it on entry.
                    if let first = apps.first {
                        appRow(first, maximum: maximum, width: proxy.size.width, initiallyExpanded: false)
                            .id(first.id)
                    }
                }),
                    listFooter: AnyView(powerMetrics.padding(.top, 16))) {
                    LightfieldSummary(module: .energy, label: L10n.text("当前应用功率", "Current App Power"),
                        value: currentTotal, unit: "W", secondary: proxy.size.width >= 700 ? summaryMetrics : [],
                        note: L10n.text("当前读数：", "Current Reading: ") + LightfieldPerformancePresentation.currentEnergySource(snapshot.apps).title)
                } rows: {
                    // D77: no automatically expanded app consumes the first
                    // result screen; its real child processes open on request.
                    ForEach(apps.dropFirst()) { app in
                        appRow(app, maximum: maximum, width: proxy.size.width, initiallyExpanded: false)
                    }

                }
            }
        }
    }
    private func appRow(_ app: EnergyImpactApp, maximum: Double, width: CGFloat, initiallyExpanded: Bool) -> some View {
        LightfieldEnergyAppRow(app: app, maximum: maximum, sortMode: sortMode,
            metricsWidth: min(336, max(144, width * 0.40)), initiallyExpanded: initiallyExpanded)
            .lightfieldComponentProbe("energy.row." + app.id)
    }
    private func tableHeader(width: CGFloat, isEmpty: Bool) -> some View {
        VStack(spacing: 0) {
                    if width < 700 { LightfieldMetricGroup(metrics: summaryMetrics) }
                    tableControls
                    if showsSearch || !searchText.isEmpty {
                        TextField(L10n.text("搜索应用、Bundle ID 或路径", "Search App, Bundle ID or Path"), text: $searchText)
                            .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(palette.fg).padding(.vertical, 8)
                    }
                    FeatureLightfieldHairline()
                    if isEmpty {
                        Text(L10n.text("没有匹配的运行应用", "No Matching Running Apps"))
                            .font(.system(size: 15)).foregroundStyle(palette.fg2).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    }
        }
    }
    private var summaryMetrics: [LightfieldMetric] {
        [.init(id: "uptime", label: L10n.text("系统运行时间", "System Uptime"), value: EnergyImpactApp.durationText(snapshot.uptimeSeconds)),
         .init(id: "coverage", label: L10n.text("进程测量覆盖率", "Process Measurement Coverage"),
            value: snapshot.processCount > 0 ? snapshot.energyCoveragePercentText : "—")]
    }
    private func maximumValue(_ presentation: EnergyImpactListPresentation) -> Double {
        switch sortMode {
        case .estimatedEnergy, .name: presentation.maxEstimatedEnergyWh
        case .currentPower: presentation.maxCurrentPowerWatts
        case .averagePower: presentation.maxAveragePowerWatts
        }
    }
    private var tableControls: some View {
        HStack(spacing: 16) {
            Menu {
                Picker(L10n.text("排序", "Sort"), selection: $sortMode) {
                    ForEach(EnergyImpactSortMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L10n.text("显示搜索", "Show Search"), isOn: $showsSearch)
            } label: {
                Text(L10n.text("应用 · 按\(sortMode.title)排序", "Apps · Sorted by \(sortMode.title)"))
                    .font(.system(size: 13)).lineLimit(1)
            }.menuStyle(.borderlessButton)
            Spacer(minLength: 0)
            Text(L10n.text("累计 Wh · 当前 W · 平均 W", "Total Wh · Current W · Average W")).font(.system(size: 13)).lineLimit(1)
        }.foregroundStyle(palette.fg3).frame(height: 28)
    }
}

struct LightfieldEnergyAppRow: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.featureLightfieldCompactResults) private var compactResults
    @Environment(\.lightfieldEnergyProcessResolver) private var processResolver
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
#endif
    let app: EnergyImpactApp
    let maximum: Double
    let sortMode: EnergyImpactSortMode
    let metricsWidth: CGFloat
    var initiallyExpanded = false
    @State private var expanded = false
    @State private var appliedInitialExpansion = false
    @State private var showsAllChildren = false
    @State private var names: [Int32: String] = [:]
    @State private var children: [Int32: LightfieldEnergyProcessIdentity] = [:]
    private var values: [LightfieldMetric] {
        [.init(id: "cumulative", label: L10n.text("累计能耗 Wh", "Cumulative Energy Wh"), value: app.cumulativeEvidence.source == .unknown ? "—" : String(format: "%.2f", app.estimatedEnergyWh)),
         .init(id: "current", label: L10n.text("当前功率 W", "Current Power W"), value: app.currentEvidence.source == .unknown ? "—" : String(format: "%.2f", app.currentPowerWatts)),
         .init(id: "average", label: L10n.text("平均功率 W", "Average Power W"), value: app.averageEvidence.source == .unknown ? "—" : String(format: "%.2f", app.averagePowerWatts))]
    }
    private var progress: Double? {
        switch sortMode {
        case .estimatedEnergy, .name: app.cumulativeEvidence.source == .unknown ? nil : app.estimatedEnergyWh / maximum
        case .currentPower: app.currentEvidence.source == .unknown ? nil : app.currentPowerWatts / maximum
        case .averagePower: app.averageEvidence.source == .unknown ? nil : app.averagePowerWatts / maximum
        }
    }
    var body: some View {
        let namingRequest = LightfieldEnergyNamingRequest(expanded: expanded, app: app)
        return LightfieldExpandableRow(title: app.name,
            metadata: values.map { $0.label + " " + $0.value }.joined(separator: " · ") + " · " + evidenceText,
            subtitle: L10n.text("\(ByteFormat.count(app.processCount)) 个进程 · CPU \(app.cpuPercentText)", "\(ByteFormat.count(app.processCount)) Processes · CPU \(app.cpuPercentText)"),
            trailing: AnyView(LightfieldMetricGroup(metrics: values, showsLabels: false, probeID: "energy.values." + app.id)
            .frame(width: metricsWidth).help(evidenceText)), rowHeight: rowHeight, reportsCompactBoundaries: true,
            probeID: "energy.app." + app.id, expanded: $expanded) {
            LightfieldAppIcon(path: app.bundlePath ?? app.iconPath, processIdentifier: app.processIDs.first, size: .medium)
        } content: {
            ForEach(showsAllChildren ? app.processIDs : Array(app.processIDs.prefix(1)), id: \.self) { id in
                HStack(spacing: 16) {
                    LightfieldAppIcon(path: children[id]?.bundlePath,
                        processIdentifier: children[id] == nil ? nil : id, size: .medium)
                        .lightfieldComponentProbe("energy.child.icon.\(id)")
                    Text(names[id] ?? L10n.text("进程名称不可用", "Process Name Unavailable"))
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lightfieldComponentProbe("energy.child.text.\(id)")
                    Text("—").font(.system(size: 13)).monospacedDigit()
                        .frame(width: metricsWidth * 2 / 3, alignment: .trailing)
                }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2).frame(height: 48)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(names[id] ?? L10n.text("进程名称不可用", "Process Name Unavailable"))
                    .accessibilityValue("—")
                    .help(LightfieldPerformancePresentation.processHelp(id: id, path: children[id]?.path ?? "") + "\n" +
                        L10n.text("快照未提供逐子进程功率", "The Snapshot Does Not Provide Power per Child Process"))
                    .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
                    .lightfieldResultRowBoundary()
            }
            if !showsAllChildren && app.processIDs.count > 1 {
                Button(L10n.text("再显示 \(app.processIDs.count - 1) 个", "Show \(app.processIDs.count - 1) More")) { showsAllChildren = true }
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).font(.system(size: 13))
                    .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2).frame(height: 24)
                    .accessibilityLabel(L10n.text("再显示 \(app.processIDs.count - 1) 个", "Show \(app.processIDs.count - 1) More"))
                    .lightfieldComponentProbe("energy.app." + app.id + ".more")
                    .lightfieldResultRowBoundary()
            }
        }
        .onAppear {
            guard !appliedInitialExpansion else { return }
            appliedInitialExpansion = true
            expanded = initiallyExpanded
        }
        .contextMenu {
            if let bundle = app.bundlePath {
                Button(L10n.text("切换到应用", "Switch to App")) { NSWorkspace.shared.open(URL(fileURLWithPath: bundle)) }
                Button(L10n.text("在访达中显示", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundle)])
                }
            }
        }
        .overlay(alignment: .topLeading) {
            LightfieldDataBar(progress: progress, module: .energy,
                accessibilityLabel: L10n.text("应用能耗占比", "App Energy Share"))
                .padding(.leading, 40).padding(.trailing, metricsWidth + 36).offset(y: rowHeight - 3)
                .allowsHitTesting(false)
        }
        .task(id: namingRequest) {
            names = [:]
            children = [:]
            // onAppear can expand the row before the previous task starts.
            // Read this task's captured key, not the later live State value.
            guard namingRequest.expanded, !Task.isCancelled else { return }
#if DEBUG
            if isFixture && processResolver == nil {
                names = LightfieldPerformanceFixture.energyProcessNames(app)
                children = names.mapValues { LightfieldEnergyProcessIdentity(name: $0, path: "", bundlePath: app.bundlePath) }
                return
            }
#endif
            let resolved = await (processResolver ?? LightfieldEnergyProcessResolver()).resolve(app)
            // The View task publishes on MainActor. A collapsed, disappeared,
            // or resampled row must never publish the cancelled pass's result.
            guard !Task.isCancelled else { return }
            children = resolved
            names = resolved.mapValues(\.name)
        }
    }
    private var evidenceText: String {
        app.measurementTitle + " · " + app.sourceTitle + "\n" +
            L10n.text("累计：\(app.cumulativeEvidence.source.title) · 当前：\(app.currentEvidence.source.title) · 平均：\(app.averageEvidence.source.title)",
                "Cumulative: \(app.cumulativeEvidence.source.title) · Current: \(app.currentEvidence.source.title) · Average: \(app.averageEvidence.source.title)")
    }
    private var rowHeight: CGFloat { compactResults ? FeatureLightfield.compactProcessRowHeight : 56 }
}

struct LightfieldEnergyProcessIdentity: Equatable, Sendable {
    let name: String
    let path: String
    let bundlePath: String?
}

/// All kernel reads and application-name lookups of a pass run off MainActor.
/// The existing bounded reader owns one buffer, reused for every captured PID.
struct LightfieldEnergyProcessResolver: Sendable {
    var makeReader: @Sendable () -> EnergyImpactService.ExecutablePathReader = { .init() }
    var runningName: @Sendable (Int32) -> String? = { NSRunningApplication(processIdentifier: $0)?.localizedName }

    func resolve(_ app: EnergyImpactApp) async -> [Int32: LightfieldEnergyProcessIdentity] {
        let worker = Task.detached(priority: .utility) { [self] () -> [Int32: LightfieldEnergyProcessIdentity] in
            var reader = makeReader()
            var result: [Int32: LightfieldEnergyProcessIdentity] = [:]
            result.reserveCapacity(app.processIDs.count)
            for id in app.processIDs {
                guard !Task.isCancelled else { return [:] }
                guard let path = reader.path(of: id) else { continue }
                if let bundle = app.bundlePath {
                    guard path.hasPrefix(bundle + "/") else { continue }
                } else {
                    guard path == app.path else { continue }
                }
                guard !Task.isCancelled else { return [:] }
                let name = runningName(id) ?? URL(fileURLWithPath: path).lastPathComponent
                result[id] = .init(name: LightfieldPerformancePresentation.processName(name: name, path: path, application: app.name),
                    path: path, bundlePath: app.bundlePath)
            }
            return Task.isCancelled ? [:] : result
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }
}

private struct LightfieldEnergyNamingRequest: Hashable {
    let expanded: Bool
    let id: String
    let name: String
    let path: String
    let bundle: String?
    let processes: [Int32]
    let sampledAt: Date?
    init(expanded: Bool, app: EnergyImpactApp) {
        self.expanded = expanded; id = app.id; name = app.name; path = app.path
        bundle = app.bundlePath; processes = app.processIDs; sampledAt = app.sampledAt
    }
}

private struct LightfieldEnergyProcessResolverKey: EnvironmentKey {
    static let defaultValue: LightfieldEnergyProcessResolver? = nil
}
extension EnvironmentValues {
    var lightfieldEnergyProcessResolver: LightfieldEnergyProcessResolver? {
        get { self[LightfieldEnergyProcessResolverKey.self] }
        set { self[LightfieldEnergyProcessResolverKey.self] = newValue }
    }
}
