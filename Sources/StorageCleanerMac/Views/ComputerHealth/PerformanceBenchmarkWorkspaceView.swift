import SwiftUI

struct PerformanceBenchmarkWorkspaceView: View {
    @ObservedObject var benchmarkStore: MacBenchmarkStore
    @ObservedObject var leaderboardStore: BenchmarkV7LeaderboardStore
    @ObservedObject var heavyWorkActivityStore: HeavyWorkActivityStore
    @ObservedObject var monitorState: MenuBarMonitorState
    @ObservedObject var auxiliaryState: MenuBarAuxiliaryMonitorState
    let isTelemetryPaused: Bool
    let refreshTelemetry: () -> Void
    @State private var telemetryConsumerID = UUID()
    @State private var showsBenchmarkInfo = false

    var body: some View {
        DashboardPage(
            title: L10n.text("性能测试", "Performance Benchmark"),
            subtitle: L10n.text(
                "一键评估 CPU、GPU、内存、存储与显示性能",
                "One tap evaluates CPU, GPU, memory, storage, and display performance"
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
            BenchmarkV7DashboardView(
                state: benchmarkStore.v7State,
                latestResult: benchmarkStore.latestOfficialV7Result,
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
                onStart: benchmarkStore.startOfficialBenchmark,
                onCancel: benchmarkStore.cancelV7,
                onDeleteHistoryRecord: { recordID in
                    Task {
                        await benchmarkStore.deleteV7HistoryRecord(recordID: recordID)
                    }
                },
                onExportHistoryRecord: benchmarkStore.exportV7HistoryRecord,
                liveTelemetry: monitorState.history(within: 120)
            )
            .clipped()
            .zIndex(0)
        }
        .onAppear {
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
        .onDisappear { auxiliaryState.unregisterConsumer(telemetryConsumerID) }
        .task {
            await benchmarkStore.loadHistory()
            await heavyWorkActivityStore.refresh()
        }
        .task(id: benchmarkStore.isRunning) {
            await trackBenchmarkActivity()
        }
    }

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Text(L10n.text("测试说明", "About this test"))
                .font(AppDesignTokens.Typography.cardTitle)
            Text(L10n.text(
                "自动完成 CPU、GPU、内存、存储、显示体验和持续性能检查，约 \(durationText(TimeInterval(OfficialBenchmarkPlan.current.plan.expectedMaximumDurationSeconds)))。",
                "CPU, GPU, memory, storage, display, and a sustained check run automatically in about \(durationText(TimeInterval(OfficialBenchmarkPlan.current.plan.expectedMaximumDurationSeconds)))."
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

    private var canStartBenchmark: Bool {
        !benchmarkStore.isRunning
            && heavyWorkActivityStore.activeOwner == nil
            && benchmarkStore.v7State.failure?.requiresApplicationRestart != true
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
