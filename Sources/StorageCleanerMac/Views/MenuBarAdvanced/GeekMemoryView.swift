import SwiftUI

extension MenuBarAdvancedStatusView {
    var geekMemoryPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.memory) { geekMemoryHistoryHoverTarget }
            liveCard(.memory) { geekMemoryCompositionHoverTarget }
            liveCard(.memoryProcesses) {
            if let result = store.memoryOptimizationResult {
                GeekMemoryQuitResultCard(
                    result: result,
                    onDone: {
                        store.memoryOptimizationResult = nil
                        store.clearMemoryProcessSelection()
                    },
                    onOpenReport: { openApp(filter: .memory) }
                )
            } else {
                geekMemoryProcessesCard
            }
            if showsExtendedGeekDetails, store.memoryOptimizationResult == nil {
                geekMemoryPagesCard
            }
            }
            if showsExtendedGeekDetails {
                liveCard(.memory) { geekMemorySwapHoverTarget }
            }
        }


    }

    private var geekMemoryHistoryHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("内存历史三级详情", "Memory History Deep Detail"),
            chartRangeMetric: .memory,
            popoverSize: GeekHoverDetailMetrics.memoryHistorySize
        ) {
            geekMemoryRingsCard
        } detail: {
            GeekMemoryHistoryHoverDetail(
                points: memoryHistory,
                duration: geekChartDuration,
                currentValue: memoryRingUsedPercentText,
                pressure: memoryPressureDisplayText,
                snapshot: memorySnapshot
            )
        }
    }

    private var geekMemoryCompositionHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("内存组成实时占比", "Live Memory Composition"),
            chartRangeMetric: .memory,
            popoverSize: GeekMemoryCompositionHistoryDetail.preferredSize
        ) {
            MiniWindowGroup {
                GeekMemoryCompositionRows(composition: memorySnapshot?.ringComposition)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.text("内存组成", "Memory Composition"))
            .accessibilityValue(GeekMemoryComponent.allCases.map {
                "\($0.title) \($0.value(in: memorySnapshot?.ringComposition, asPercent: false))"
            }.joined(separator: ", "))
            .accessibilityAddTraits(.isButton)
        } detail: {
            GeekMemoryCompositionHistoryDetail(
                points: memoryHistory,
                duration: geekChartDuration,
                composition: memorySnapshot?.ringComposition
            )
        }
    }

    private var geekMemoryRingsCard: some View {
        GeekCombinedCard(height: 174) {
            VStack(spacing: 6) {
                HStack {
                    Label(L10n.text("内存", "Memory"), systemImage: AppSymbols.Monitor.memory)
                        .font(AdvancedPanelTypography.captionStrong)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: MemorySampleStatusPresentation.refreshInterval)) { timeline in
                        Text(memorySampleStatusText(at: timeline.date))
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .help(memorySampleEvidenceText)
                            .accessibilityHint(memorySampleEvidenceText)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("内存采样", "Memory sample"))
                .accessibilityValue(memorySampleEvidenceText)
                HStack(spacing: 40) {
                    GeekCombinedRing(
                        title: L10n.text("占用", "Used"),
                        value: memoryRingUsedPercentText,
                        progress: memoryRingUsedProgress,
                        tint: resolvedPrimaryTint,
                        size: GeekVisualTokens.detailMemoryGaugeSize,
                        segments: memoryRingSegments,
                        strokeWidth: GeekVisualTokens.gaugeStrokeWidth(size: GeekVisualTokens.detailMemoryGaugeSize)
                    )
                    .help(memoryRingExplanation)
                    geekMemoryPressureRing(size: GeekVisualTokens.detailMemoryGaugeSize)
                }
                Text(memoryUsageAmountText)
                    .font(AdvancedPanelTypography.body)
                    .monospacedDigit()
                    .help(memoryRingExplanation)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var geekMemoryProcessesCard: some View {
        GeekCombinedCard(
            height: showsExtendedGeekDetails ? 119 : 83
        ) {
            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    memoryProcessHeader
                    VStack(alignment: .leading, spacing: 2) {
                        memoryProcessTitle
                        memoryProcessActions
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                if geekMemoryTopProcesses.isEmpty {
                    if store.isLoadingMemory {
                        geekMemoryLoadingIndicator
                    } else {
                        Text(L10n.text("未获得进程数据", "No process data"))
                            .font(AdvancedPanelTypography.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel(L10n.text("未获得内存进程数据", "No memory process data"))
                    }
                } else {
                    VStack(spacing: 1) {
                        ForEach(geekMemoryTopProcesses) { process in
                            GeekCompactMemoryProcessRow(
                                process: process,
                                isSelected: store.isMemoryAppUsageSelected(process),
                                isSelectionEnabled: store.canEditMemorySelection
                                    && !process.selectableProcessIDs.isEmpty,
                                selectionTint: memoryTint,
                                onToggle: {
                                    store.toggleMemoryAppUsageSelection(process)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var memoryProcessHeader: some View {
        HStack(spacing: 8) {
            memoryProcessTitle
            Spacer(minLength: 8)
            memoryProcessActions
        }
    }

    private var memoryProcessTitle: some View {
        Text(L10n.text(
            "进程组 · 前\(geekMemoryTopProcesses.count)/\(geekMemoryAllProcesses.count)项",
            "Process groups · \(geekMemoryTopProcesses.count)/\(geekMemoryAllProcesses.count)"
        ))
            .font(AdvancedPanelTypography.captionStrong)
            .foregroundStyle(memoryTint)
            .lineLimit(1)
            .layoutPriority(1)
            .help(L10n.text("按应用或可执行路径合并为进程组；已选项优先，其余按内存占用排序。", "Grouped by app or executable path; selected groups first, then memory use."))
    }

    private var memoryProcessActions: some View {
        HStack(spacing: 6) {
            Button(L10n.text("查看全部", "View all")) {
                store.memoryShowsAllProcesses = true
                openApp(filter: .memory)
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .font(AdvancedPanelTypography.caption)
            .accessibilityLabel(L10n.text("在主窗口只读查看全部已采样进程", "View all sampled processes read-only in the main window"))
            GeekMemoryProcessSelectionMenu(store: store, tint: memoryTint)
            GeekMemoryCleanupButton(store: store, tint: memoryTint)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var geekMemoryPagesCard: some View {
        GeekCombinedCard(height: 42) {
            VStack(spacing: 1) {
                if let snapshot = memorySnapshot {
                    GeekMemoryInlineFact(
                        title: L10n.text("换入（累计）", "Page Ins (Total)"),
                        value: compactPageCount(snapshot.pageInsCount)
                    )
                    GeekMemoryInlineFact(
                        title: L10n.text("换出（累计）", "Page Outs (Total)"),
                        value: compactPageCount(snapshot.pageOutsCount)
                    )
                } else {
                    geekMemoryLoadingIndicator
                }
            }
        }
    }

    private var geekMemorySwapCard: some View {
        GeekCombinedCard(height: 40) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.text("交换内存", "Swap Memory"))
                        .font(AdvancedPanelTypography.captionStrong)
                        .foregroundStyle(memoryTint)
                        .help(geekSwapExplanation)

                    Text(memorySnapshot.map(swapUsageText) ?? "—")
                        .font(AdvancedPanelTypography.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                GeekCombinedRing(
                    title: L10n.text("交换内存", "Swap Memory"),
                    value: geekSwapPercentText,
                    detail: geekSwapExplanation,
                    progress: geekSwapProgress,
                    tint: memoryTint,
                    size: 30
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
        }
    }

    private var geekMemorySwapHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("交换内存三级详情", "Swap Memory Deep Detail"),
            popoverSize: GeekHoverDetailMetrics.historySize
        ) {
            geekMemorySwapCard
        } detail: {
            GeekSwapHoverDetail(snapshot: memorySnapshot)
        }
    }

    private var geekSwapProgress: Double? {
        guard let snapshot = memorySnapshot,
              let used = snapshot.measurements.swapUsedBytes.value else { return nil }
        guard snapshot.swapTotalBytes > 0 else { return used == 0 ? 0 : nil }
        return min(1, max(0, Double(used) / Double(snapshot.swapTotalBytes)))
    }

    private var geekSwapPercentText: String {
        geekSwapProgress.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private var geekSwapExplanation: String {
        L10n.text(
            "内存不够用时，macOS 暂时存放到磁盘上的数据",
            "Memory data macOS temporarily stores on disk when physical memory is under pressure"
        )
    }

    private var geekMemoryAllProcesses: [MemoryAppUsage] {
        let apps: [MemoryAppUsage]
#if DEBUG || STORAGE_CLEANER_BETA
        if MiniWindowDemoData.isEnabled {
            apps = MiniWindowDemoData.memorySnapshot.appsByResidentUsage
        } else {
            apps = store.menuBarPreparedMemoryApps
        }
#else
        apps = store.menuBarPreparedMemoryApps
#endif
        return apps
    }

    private var geekMemoryTopProcesses: [MemoryAppUsage] {
        let apps = geekMemoryAllProcesses
        let selected = apps.filter { store.isMemoryAppUsageSelected($0) }
        let selectedIDs = Set(selected.map(\.id))
        return Array(
            (selected + apps.filter { !selectedIDs.contains($0.id) })
                .prefix(showsExtendedGeekDetails ? 5 : 3)
        )
    }

    private func swapUsageText(_ snapshot: MemorySnapshot) -> String {
        guard let used = snapshot.measurements.swapUsedBytes.value else {
            return snapshot.measurements.swapUsedBytes.availability.title
        }
        let usedText = ByteFormat.string(Int64(clamping: used))
        guard snapshot.swapTotalBytes > 0 else {
            return L10n.text("\(usedText) · 未使用", "\(usedText) · Inactive")
        }
        return "\(usedText) / \(ByteFormat.string(snapshot.swapTotalBytes))"
    }

    private func compactPageCount(_ value: Int64) -> String {
        let count = Double(max(0, value))
        switch count {
        case 1_000_000_000...:
            return String(format: "%.1fB", count / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", count / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", count / 1_000)
        default:
            return "\(value)"
        }
    }

    private var geekMemoryLoadingIndicator: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(L10n.text("正在采样", "Sampling"))
    }
}

private struct GeekMemoryProcessSelectionMenu: View {
    @ObservedObject var store: ScanStore
    let tint: Color

    private var selectableApps: [MemoryAppUsage] {
        (store.menuBarPreparedMemoryApps)
            .filter { !$0.selectableProcessIDs.isEmpty }
    }

    private var selectedCount: Int {
        store.selectedMemoryAppCount
    }

    private var hasRecommendedApps: Bool {
        store.memorySnapshot?.recommendedQuitApps.isEmpty == false
    }

    var body: some View {
        Menu {
            ForEach(selectableApps) { app in
                Toggle(isOn: selectionBinding(for: app)) {
                    Text("\(app.name) · \(ByteFormat.string(app.bytes))")
                }
                .accessibilityLabel(L10n.text(
                    "选择 \(app.name)",
                    "Select \(app.name)"
                ))
            }

            Divider()

            if hasRecommendedApps {
                Button(L10n.text("选择建议项", "Select Suggested")) {
                    _ = store.selectRecommendedMemoryApps()
                }
            }

            Button(L10n.text("全选", "Select All")) {
                store.selectAllMemoryProcessesForQuit()
            }

            if selectedCount > 0 {
                Button(L10n.text("清空选择", "Clear Selection")) {
                    store.clearMemoryProcessSelection()
                }
            }
        } label: {
            Label(
                selectedCount == 0
                    ? L10n.text("选择", "Select")
                    : L10n.text("已选 \(selectedCount)", "\(selectedCount) Selected"),
                systemImage: "checklist"
            )
            .font(AdvancedPanelTypography.body)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(tint)
        .disabled(selectableApps.isEmpty || !store.canEditMemorySelection)
        .help(L10n.text(
            "选择要正常退出的应用",
            "Choose applications to quit normally"
        ))
        .accessibilityLabel(L10n.text("选择内存进程", "Select Memory Processes"))
        .accessibilityValue(
            selectedCount == 0
                ? L10n.text("未选择", "None Selected")
                : L10n.text("已选择 \(selectedCount) 个应用", "\(selectedCount) Apps Selected")
        )
        .accessibilityHint(L10n.text(
            "打开所有可退出应用列表",
            "Opens the list of all quittable applications"
        ))
    }

    private func selectionBinding(for app: MemoryAppUsage) -> Binding<Bool> {
        Binding {
            store.isMemoryAppUsageSelected(app)
        } set: { isSelected in
            store.setMemoryAppUsageSelection(app, isSelected: isSelected)
        }
    }
}

private struct GeekMemoryCleanupButton: View {
    @ObservedObject var store: ScanStore
    let tint: Color

    private var hasRecommendedApps: Bool {
        store.memorySnapshot?.recommendedQuitApps.isEmpty == false
    }

    private var selectedCount: Int {
        store.selectedMemoryAppCount
    }

    private var canPrepareSelection: Bool {
        selectedCount > 0 || hasRecommendedApps
    }

    private var confirmationBinding: Binding<Bool> {
        Binding {
            store.pendingMemoryQuitSummary != nil
                && !store.pendingMemoryProcessesToQuit.isEmpty
                && store.isMemoryBatchQuitConfirmationPresentedInMenuBar
        } set: { _ in
            // SwiftUI writes `false` while running either alert action. The
            // buttons below own confirm/cancel semantics; treating dismissal
            // as cancellation races the confirmed plan.
        }
    }

    var body: some View {
        Button {
            guard store.ensureMemorySelectionForQuit() else { return }
            store.requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: true)
        } label: {
            Label(
                L10n.text("内存清理", "Clean Memory"),
                systemImage: "checkmark.circle"
            )
        }
        .buttonStyle(.bordered)
        .font(AdvancedPanelTypography.body)
        .controlSize(.small)
        .tint(tint)
        .disabled(!canPrepareSelection || !store.canRequestMemoryQuitActions)
        .help(
            selectedCount > 0
                ? L10n.text(
                    "确认后正常退出已选择的 \(selectedCount) 个应用",
                    "Quit the \(selectedCount) selected applications normally after confirmation"
                )
                : hasRecommendedApps
                    ? L10n.text(
                        "未手动选择时使用建议项，并在确认后正常退出",
                        "Uses suggested apps when none are selected, then quits normally after confirmation"
                    )
                    : L10n.text(
                        "当前没有可选择的应用",
                        "No applications are currently available for selection"
                    )
        )
        .accessibilityLabel(L10n.text("内存清理", "Clean Memory"))
        .accessibilityHint(
            L10n.text(
                "优先使用手动选择；未选择时使用建议项，确认后统一退出",
                "Uses the manual selection first, or suggested apps when none are selected"
            )
        )
        .alert(
            L10n.text("退出所选应用？", "Quit Selected Apps?"),
            isPresented: confirmationBinding
        ) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelQuitSelectedMemoryProcesses()
            }
            Button(L10n.text("正常退出", "Quit Normally"), role: .destructive) {
                store.confirmQuitSelectedMemoryProcesses()
            }
            .disabled(!store.canRequestMemoryQuitActions)
        } message: {
            if let summary = store.pendingMemoryQuitSummary {
                Text(
                    L10n.text(
                        "已选择 \(summary.appCount) 个应用，目前约占 \(ByteFormat.string(summary.estimatedBytes))；退出后将刷新重测实际释放量。",
                        "\(summary.appCount) apps are selected and currently use about \(ByteFormat.string(summary.estimatedBytes)); actual release will be remeasured after quitting."
                    )
                )
            }
        }
    }
}

private struct GeekMemoryQuitResultCard: View {
    let result: MemoryOptimizationResult
    let onDone: () -> Void
    let onOpenReport: () -> Void

    var body: some View {
        GeekCombinedCard(height: 220) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AppDesignTokens.Palette.success)
                    Text(L10n.text("退出结果", "Quit Result"))
                        .font(AdvancedPanelTypography.captionStrong)
                    Spacer(minLength: 4)
                    Text(L10n.scanSeconds(result.durationSeconds))
                        .font(AdvancedPanelTypography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 6) {
                    resultCount(
                        title: L10n.text("正常退出", "Quit"),
                        value: successfulCount,
                        tint: AppDesignTokens.Palette.success
                    )
                    resultCount(
                        title: L10n.text("跳过", "Skipped"),
                        value: skippedCount,
                        tint: AppDesignTokens.Palette.warning
                    )
                    resultCount(
                        title: L10n.text("失败", "Failed"),
                        value: failedCount,
                        tint: AppDesignTokens.Palette.destructive
                    )
                }

                HStack(spacing: 12) {
                    GeekCombinedRing(
                        title: L10n.text("操作前", "Before"),
                        value: result.beforeSnapshot.usedPercentText,
                        detail: result.beforeSnapshot.pressureLevel.title,
                        progress: result.beforeSnapshot.measuredUsedRatio,
                        tint: AppDesignTokens.Palette.warning,
                        size: 54
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    GeekCombinedRing(
                        title: L10n.text("操作后", "After"),
                        value: result.snapshot.usedPercentText,
                        detail: result.snapshot.pressureLevel.title,
                        progress: result.snapshot.measuredUsedRatio,
                        tint: AppDesignTokens.Palette.success,
                        size: 54
                    )
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L10n.text("可用内存增加", "More Available"))
                            .font(AdvancedPanelTypography.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteFormat.string(result.releasedBytes))
                            .font(AdvancedPanelTypography.captionStrong)
                            .foregroundStyle(AppDesignTokens.Palette.success)
                            .monospacedDigit()
                    }
                }

                Text(result.detail)
                    .font(AdvancedPanelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Button(L10n.text("完成", "Done"), action: onDone)
                        .buttonStyle(.borderedProminent)
                    Button(action: onOpenReport) {
                        Label(L10n.text("查看报告", "View Report"), systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var successfulCount: Int {
        targetResults.filter {
            $0.outcome == .gracefulQuitSucceeded
                || $0.outcome == .forceQuitSucceeded
        }.count
    }

    private var skippedCount: Int {
        targetResults.filter {
            $0.outcome == .targetExitedBeforeRequest
                || $0.outcome == .userCancelled
        }.count
    }

    private var failedCount: Int {
        max(0, targetResults.count - successfulCount - skippedCount)
    }

    private var targetResults: [MemoryOptimizationTargetResult] {
        result.executionResult?.targetResults ?? []
    }

    private func resultCount(title: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .font(AdvancedPanelTypography.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeekMemoryInlineFact: View {
    let title: String
    let value: String
    var color: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(AdvancedPanelTypography.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct GeekCompactMemoryProcessRow: View {
    let process: MemoryAppUsage
    let isSelected: Bool
    let isSelectionEnabled: Bool
    let selectionTint: Color
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(AdvancedPanelTypography.captionStrong)
                    .foregroundStyle(isSelected ? selectionTint : Color.secondary.opacity(0.55))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)

                AdvancedAppIcon(path: process.iconPath, fallback: "gearshape.2")
                    .scaleEffect(0.62)
                    .frame(width: 14, height: 14)

                Text(process.name)
                    .font(AdvancedPanelTypography.body)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(ByteFormat.string(process.bytes))
                    .font(AdvancedPanelTypography.body)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 3)
            .frame(minHeight: 14)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius, style: .continuous)
                    .fill(isSelected ? selectionTint.opacity(0.14) : .clear)
            }
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .disabled(!isSelectionEnabled)
        .help(
            isSelectionEnabled
                ? L10n.text(
                    "点击选择或取消选择 \(process.name)",
                    "Select or deselect \(process.name)"
                )
                : L10n.text(
                    "此进程仅供查看，不能从这里退出",
                    "This process is read-only and cannot be quit here"
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(process.name)
        .accessibilityValue(
            !isSelectionEnabled
                ? L10n.text("仅查看", "Read Only")
                : isSelected
                ? L10n.text("已选择清理", "Selected for cleanup")
                : L10n.text("未选择清理", "Not selected for cleanup")
        )
        .accessibilityHint(
            isSelectionEnabled
                ? L10n.text("切换此应用的选择状态", "Toggles this application's selection")
                : ""
        )
    }
}
