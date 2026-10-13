import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PerformanceBenchmarkWorkspaceView: View {
    @ObservedObject var benchmarkStore: MacBenchmarkStore
    @ObservedObject var leaderboardStore: BenchmarkV7LeaderboardStore
    @ObservedObject var heavyWorkActivityStore: HeavyWorkActivityStore
    @ObservedObject var monitorState: MenuBarMonitorState
    @ObservedObject var auxiliaryState: MenuBarAuxiliaryMonitorState
    @ObservedObject var helperMonitor: HelperPowerMetricsMonitor
    let isTelemetryPaused: Bool
    let refreshTelemetry: () -> Void
    @State private var telemetryConsumerID = UUID()
    @State private var showsSavedDashboard = false
    @State private var showsLanding = false
    @State private var selection = MSeriesV11Selection()
    @State private var selectedRecord: BenchmarkV7Result?
    @State private var identity: AppleSiliconIdentity?
    @State private var catalog = AppleSiliconCatalogLoader.Loaded(catalog: nil, sha256: nil, reason: "notRead")
    @State private var helperAvailable = false
    @State private var exportFeedback: String?
    private var displayedResult: BenchmarkV7Result? { selectedRecord ?? benchmarkStore.v7LatestResult }

    /// Reconstructed Workspaces read the same Store-owned frozen session.
    var runningPresentation: MSeriesV11PagePresentation.Run {
        .init(state: benchmarkStore.v7State, weightedFraction: benchmarkStore.v7ProgressFraction,
            elapsedSeconds: benchmarkStore.v7ElapsedSeconds,
            knownCoreCount: benchmarkStore.v11RunConfiguration?.completedCoreCount ?? 0,
            mode: benchmarkStore.v11RunConfiguration?.mode ?? "standard")
    }

    var body: some View {
        Group {
            if benchmarkStore.isV7BenchmarkRunning {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    PerformanceBenchmarkV11RunningPage(run: runningPresentation,
                        telemetry: benchmarkStore.v11LiveTelemetry, systemTelemetry: monitorState.history(within: 120),
                        liveObservation: benchmarkStore.v11LiveObservation,
                        onCancel: benchmarkStore.cancelV7)
                }
            } else if showsSavedDashboard {
                FeatureLightfieldPage(module: .performance, phase: .result, title: ReviewFilter.performance.sidebarTitle,
                    status: L10n.text("本机历史 · 保留原协议", "Local history · Original protocols retained"),
                    safety: MSeriesV11PagePresentation.community, actionTitle: L10n.text("开始新测试", "Start new test"),
                    actionEnabled: canStartBenchmark, action: prepareNewTest) {
                        LightfieldResultContent {
                            LightfieldSummary(module: .performance, label: L10n.text("本机测试记录", "Local benchmark records"),
                                value: String(benchmarkStore.v7History.count), unit: L10n.text("项", "items"))
                        } rows: {
                            PerformanceBenchmarkV11HistoryList(history: benchmarkStore.v7History, onOpen: openRecord)
                        }
                    }
            } else if showsLanding || (selectedRecord == nil && displayedResult?.mSeriesV11 == nil) {
                // D72/v11 is the current entry. Legacy results stay accessible
                // through history, never replace the approved current landing.
                PerformanceBenchmarkLandingView(canStart: canStartBenchmark, explanation: explanation,
                    onStart: startV11, onShowSaved: { showsLanding = false; showsSavedDashboard = true }, identity: identity, catalog: catalog,
                    preflight: benchmarkStore.v7Preflight, helperAvailable: helperAvailable, selection: $selection)
            } else if let result = displayedResult, result.mSeriesV11 != nil {
                PerformanceBenchmarkV11ResultPage(result: result, history: benchmarkStore.v7History,
                    catalog: catalog, canStart: canStartBenchmark, onStart: prepareNewTest, onOpenHistory: openRecord,
                    onExport: exportRecord, saveState: benchmarkStore.v11SaveState)
            } else if let result = displayedResult {
            PerformanceBenchmarkLegacyResultPage(result: result, canStart: canStartBenchmark, onStart: prepareNewTest) {
            BenchmarkV7DashboardView(
                state: benchmarkStore.v7State,
                latestResult: displayedResult,
                history: benchmarkStore.v7History,
                localBestResult: benchmarkStore.localBestOfficialV7Result,
                localBestResultsByCategory: benchmarkStore.localBestOfficialV7ResultsByCategory,
                currentScoringVersion: benchmarkStore.currentV7ScoringVersion,
                historyStatus: benchmarkStore.v7HistoryStatus,
                leaderboardStore: leaderboardStore,
                preflight: benchmarkStore.v7Preflight,
                isPreflighting: benchmarkStore.isV7Preflighting,
                canStart: canStartBenchmark,
                explanation: explanation,
                onStart: prepareNewTest,
                onCancel: benchmarkStore.cancelV7,
                onDeleteHistoryRecord: { recordID in
                    Task {
                        await benchmarkStore.deleteV7HistoryRecord(recordID: recordID)
                    }
                },
                onExportHistoryRecord: benchmarkStore.exportV7HistoryRecord,
                liveTelemetry: monitorState.history(within: 120),
                usesCompactResultContainer: true
            )
            .clipped()
            .zIndex(0)
        }
        }
        }
        .featureFlowTransition(value: benchmarkStore.isV7BenchmarkRunning || benchmarkStore.isV7Preflighting)
        .alert(L10n.text("导出原始结果", "Export raw result"), isPresented: Binding(get: { exportFeedback != nil }, set: { if !$0 { exportFeedback = nil } })) {
            Button(L10n.text("好", "OK")) { exportFeedback = nil }
        } message: { Text(exportFeedback ?? "") }
        .onAppear {
            benchmarkStore.setV11TelemetryVisible(true)
            auxiliaryState.registerConsumer(
                telemetryConsumerID,
                demand: MenuBarAuxiliaryMonitorDemand(
                    needsProcessorTelemetry: false,
                    needsDiskIOSampling: false,
                    needsNetworkInterface: false,
                    needsPublicNetworkAddress: false,
                    needsNetworkProcesses: false
                ),
                paused: isTelemetryPaused
            )
            if !isTelemetryPaused { refreshTelemetry() }
        }
        .onDisappear {
            benchmarkStore.setV11TelemetryVisible(false)
            auxiliaryState.unregisterConsumer(telemetryConsumerID)
        }
        .task {
            await benchmarkStore.loadHistory()
            await heavyWorkActivityStore.refresh()
            let loaded = await Task.detached(priority: .utility) { AppleSiliconCatalogLoader.load() }.value
            let evidence = await AppleSiliconHardwareCollector.captureAsync()
            guard !Task.isCancelled else { return }
            catalog = loaded
            identity = AppleSiliconIdentifier.identify(evidence, catalog: loaded)
            helperAvailable = helperMonitor.capabilityAvailability == .ready
            if displayedResult == nil && !benchmarkStore.isRunning {
                benchmarkStore.preflightV7(plan: MSeriesV11Protocol.plan(mode: selection.mode), targetDirectory: MSeriesProtocol.temporaryRoot)
            }
        }
        .task(id: helperMonitor.state) { helperAvailable = helperMonitor.capabilityAvailability == .ready }
        .task(id: benchmarkStore.isRunning) {
            await trackBenchmarkActivity()
        }
    }

    private var canStartBenchmark: Bool {
        !benchmarkStore.isRunning
            && !benchmarkStore.isV7Preflighting
            && heavyWorkActivityStore.activeOwner == nil
            && benchmarkStore.v7State.failure?.requiresApplicationRestart != true
    }

    private func prepareNewTest() {
        showsLanding = true
        showsSavedDashboard = false
        selectedRecord = nil
        benchmarkStore.preflightV7(plan: MSeriesV11Protocol.plan(mode: selection.mode), targetDirectory: MSeriesProtocol.temporaryRoot)
    }
    private func startV11() {
        showsLanding = false
        selectedRecord = nil
        showsSavedDashboard = false
        benchmarkStore.startV11Benchmark(mode: selection.mode, accelerators: selection.units)
    }
    private func openRecord(_ result: BenchmarkV7Result) { selectedRecord = result; showsLanding = false; showsSavedDashboard = false }

    private func exportRecord(_ result: BenchmarkV7Result) {
        guard let id = result.recordID, let data = benchmarkStore.exportV7HistoryRecord(recordID: id) else {
            exportFeedback = L10n.text("无法找到要导出的本机记录。", "The local record to export could not be found.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "StorageCleanerMac-Benchmark-\(id.uuidString.prefix(8)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { exportFeedback = L10n.text("无法写入导出文件。", "The export file could not be written.") }
    }

    private var explanation: String? {
        if case let .restartRequired(context) = benchmarkStore.v7State.failure {
            return L10n.text(
                "操作未确认停止（\(context.detail)）。安全隔离仍保留，请重启应用后再测试。",
                "The operation did not confirm termination (\(context.detail)). Safety quarantine remains active; restart the app before running another test."
            )
        }
        if heavyWorkActivityStore.activeOwner == .benchmark,
           !benchmarkStore.isV7BenchmarkRunning {
            return L10n.text(
                "上一项高负载任务仍在释放资源；完成前不会启动新的测试。",
                "The previous heavy task is still releasing resources. A new test waits for cleanup."
            )
        }
        if let activeOwner = heavyWorkActivityStore.activeOwner,
           activeOwner != .benchmark {
            return HeavyWorkActivityStore.conflictMessage(activeOwner: activeOwner)
        }
        switch benchmarkStore.v7State.failure {
        case .preflightBlocked:
            return L10n.text(
                "当前环境不满足安全测试条件，请稍后重新检查。",
                "The current environment is not safe for a benchmark. Check again later."
            )
        case let .validationFailed(detail):
            return L10n.text(
                "测试校验未通过：\(detail)",
                "Benchmark validation failed: \(detail)"
            )
        case .alreadyRunning:
            return L10n.text("已有性能测试正在运行。", "A performance test is already running.")
        case let .timedOut(context):
            return L10n.text(
                "测试超时（\(context.detail)），可重新运行。",
                "The benchmark timed out (\(context.detail)) and can be retried."
            )
        case .restartRequired:
            return nil
        case .persistenceFailed:
            return L10n.text(
                "测试完成，但结果未能安全保存。",
                "The benchmark completed, but its result could not be saved safely."
            )
        case .cancelled, .unsupportedCategory, .invalidMeasurement, .internalFailure, nil:
            return nil
        }
    }

    private func trackBenchmarkActivity() async {
        do {
            await heavyWorkActivityStore.refresh()
            while benchmarkStore.isRunning {
                try await Task.sleep(for: .seconds(1))
                await heavyWorkActivityStore.refresh()
            }
            await heavyWorkActivityStore.refresh()
            while heavyWorkActivityStore.activeOwner == .benchmark {
                try await Task.sleep(for: .seconds(1))
                await heavyWorkActivityStore.refresh()
            }
        } catch {
            // SwiftUI cancels this task when the health workspace disappears.
        }
    }
}

/// Opening an older record retains its own protocol components and frozen
/// evidence while using the same result-space budget as the v11 result page.
struct PerformanceBenchmarkLegacyResultPage<Content: View>: View {
    let result: BenchmarkV7Result
    let canStart: Bool
    let onStart: () -> Void
    @ViewBuilder let content: Content
    var body: some View {
        FeatureLightfieldPage(module: .performance, phase: .result, title: ReviewFilter.performance.sidebarTitle,
            status: L10n.text("历史记录 · 原协议 ", "History · Original protocol ") + result.versions.planVersion,
            safety: L10n.text("保留原始数据与口径，不按新协议重算", "Original evidence retained; never rescored as a new protocol"),
            actionTitle: L10n.text("开始新测试", "Start new test"), actionEnabled: canStart, action: onStart) {
                content
            }
    }
}

/// The performance page's header and container, shared by the workspace and
/// its layout tests (U1 029), so the tests measure the real header.
struct PerformanceBenchmarkPageChrome<Content: View>: View {
    @State private var showsBenchmarkInfo = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        DashboardPage(
            title: L10n.text("性能测试", "Performance Benchmark"),
            subtitle: L10n.text(
                "一键测量 CPU、GPU、内存与存储性能",
                "One tap measures CPU, GPU, memory, and storage performance"
            ),
            systemImage: "speedometer"
        ) {
            Button {
                showsBenchmarkInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
            }
            .help(L10n.text("查看测试说明", "Show benchmark details"))
            .popover(isPresented: $showsBenchmarkInfo, arrowEdge: .top) {
                infoPopover
                    .padding(AppDesignTokens.Layout.sectionPadding)
                    .frame(width: 320)
            }
        } content: {
            content
        }
    }

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Text(L10n.text("测试说明", "About this test"))
                .font(AppDesignTokens.Typography.cardTitle)
            Text(L10n.text(
                "自动完成 CPU、GPU、内存与存储的 18 项 Core 测量，预计不超过 \(durationText(TimeInterval(OfficialBenchmarkPlan.current.plan.expectedMaximumDurationSeconds)))。扩展项目的实现状态单独显示。",
                "18 CPU, GPU, memory and storage Core measurements run automatically, estimated up to \(durationText(TimeInterval(OfficialBenchmarkPlan.current.plan.expectedMaximumDurationSeconds))). Extension implementation status is reported separately."
            ))
            Text(L10n.text(
                "结果默认只保存在本机；全球排行需在对应页面确认后才上传匿名字段。",
                "Results stay on this Mac by default; the global ranking uploads anonymous fields only after your confirmation there."
            ))
            .foregroundStyle(.secondary)
        }
        .font(AppDesignTokens.Typography.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded())) / 60
        let remainder = max(0, Int(seconds.rounded())) % 60
        if minutes > 0 {
            return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
        }
        return "\(remainder)s"
    }
}
