import SwiftUI

extension MenuBarAdvancedStatusView {
    var geekMemoryPage: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            liveCard(.memory) { geekMemoryHistoryHoverTarget }
            liveCard(.memory) { geekMemoryCompositionHoverTarget }
            GeekMemoryQuitConfirmationHost(store: store) {
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
                duration: geekMetricRange(.memory).duration,
                currentValue: memoryRingUsedPercentText,
                pressure: memoryPressureDisplayText,
                snapshot: memorySnapshot,
                isUpdating: geekMetricIsUpdating(.memory)
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
                duration: geekMetricRange(.memory).duration,
                composition: memorySnapshot?.ringComposition,
                isUpdating: geekMetricIsUpdating(.memory)
            )
        }
    }

    private var geekMemoryRingsCard: some View {
        GeekCombinedCard(
            height: GeekVisualTokens.detailMemoryGaugeSize
                + MiniWindowStyleTokens.dataRowHeight
                + GeekPanelLayout.detailSpacing
                + GeekVisualTokens.cardVerticalPadding * 2
        ) {
            VStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                // Same module header as the CPU page's first card. The
                // trailing text is the memory snapshot's freshness: its
                // sample time, or 已过期 / 已暂停 / an unavailability reason.
                GeekModuleHeader(systemImage: AppSymbols.Monitor.memory, title: L10n.text("内存", "Memory")) {
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
                // D43: pressure on the left, usage on the right (iStat).
                HStack(spacing: 40) {
                    geekMemoryPressureRing(size: GeekVisualTokens.detailMemoryGaugeSize)
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
                }
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
                                    MenuBarPresentationTrace.beginInput("process.select", label: "process.select")
                                    store.toggleMemoryAppUsageSelection(process)
                                }
                            )
                        }
                    }
                    .menuBarPresentationProbe(
                        "process.select",
                        revision: UInt64(truncatingIfNeeded: store.selectedMemoryProcessIDs.sorted().hashValue)
                    )
                }

                // U1 066/068 (BOARD N19): with apps selected the quit action
                // is a full-width destructive button below the list.
                if store.selectedMemoryAppCount > 0 {
                    GeekMemoryQuitSelectedButton(store: store, tint: memoryTint, presentation: .prominent)
                        .padding(.top, MiniWindowStyleTokens.rowSpacing)
                }
            }
        }
    }

    private var memoryProcessHeader: some View {
        GeekProcessListHeader(title: memoryProcessTitleText, help: memoryProcessTitleHelp) {
            memoryProcessActions
        }
    }

    private var memoryProcessTitle: some View {
        GeekSectionTitle(title: memoryProcessTitleText)
            .layoutPriority(1)
            .help(memoryProcessTitleHelp)
    }

    private var memoryProcessTitleText: String {
        L10n.text(
            "进程组 · 前\(geekMemoryTopProcesses.count)/\(geekMemoryAllProcesses.count)项",
            "Process groups · \(geekMemoryTopProcesses.count)/\(geekMemoryAllProcesses.count)"
        )
    }

    private var memoryProcessTitleHelp: String {
        L10n.text("按应用或可执行路径合并为进程组；已选项优先，其余按内存占用排序。", "Grouped by app or executable path; selected groups first, then memory use.")
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
            // Once apps are selected the action moves below the list.
            if store.selectedMemoryAppCount == 0 {
                GeekMemoryQuitSelectedButton(store: store, tint: memoryTint)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Cumulative swap activity (the kernel's swap page counters as bytes).
    private var geekMemoryPagesCard: some View {
        GeekCombinedCard(height: 42) {
            VStack(spacing: 1) {
                if let snapshot = memorySnapshot {
                    ForEach(GeekMemorySwapActivity.rows(
                        swappedInBytes: snapshot.swappedInBytes,
                        swappedOutBytes: snapshot.swappedOutBytes
                    )) { row in
                        GeekMemoryInlineFact(title: row.title, value: row.value)
                            .help(row.help)
                            .accessibilityHint(row.help)
                    }
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
                        .foregroundStyle(panelMetricColors.sectionHeader)
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
                    progress: geekSwapProgress,
                    tint: panelMetricColors.swap,
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
            chartRangeMetric: .memory,
            popoverSize: GeekHoverDetailMetrics.historySize
        ) {
            geekMemorySwapCard
        } detail: {
            GeekSwapHoverDetail(
                snapshot: memorySnapshot,
                points: memoryHistory,
                duration: geekMetricRange(.memory).duration,
                isUpdating: geekMetricIsUpdating(.memory)
            )
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

    private var geekMemoryLoadingIndicator: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(L10n.text("正在采样", "Sampling"))
    }
}

struct GeekMemorySwapActivityRow: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let help: String
}

/// The memory page's cumulative swap rows, directly above the swap card.
/// macOS counts the compressed data read back from and written to the swap
/// files in pages (vm_stat's Swapins / Swapouts); the rows show that amount
/// in bytes (pages x page size) through the memory byte format. A missing
/// reading is a dash, never zero.
enum GeekMemorySwapActivity {
    static func rows(swappedInBytes: Int64?, swappedOutBytes: Int64?) -> [GeekMemorySwapActivityRow] {
        [
            GeekMemorySwapActivityRow(
                id: "swapped-in",
                title: L10n.text("换入（累计）", "Swapped In (Total)"),
                value: value(swappedInBytes),
                help: help(
                    L10n.text(
                        "开机以来从交换文件读回内存的数据量（压缩后的大小）。",
                        "Compressed data read back from the swap files since startup."
                    ),
                    isKnown: swappedInBytes != nil
                )
            ),
            GeekMemorySwapActivityRow(
                id: "swapped-out",
                title: L10n.text("换出（累计）", "Swapped Out (Total)"),
                value: value(swappedOutBytes),
                help: help(
                    L10n.text(
                        "开机以来写入交换文件的数据量（压缩后的大小）。",
                        "Compressed data written to the swap files since startup."
                    ),
                    isKnown: swappedOutBytes != nil
                )
            ),
        ]
    }

    private static func value(_ bytes: Int64?) -> String {
        bytes.map(ByteFormat.string) ?? "—"
    }

    /// `man vm_stat` (line 107 on macOS 27.2): "Both swap counters also include
    /// I/O used for swapfile maintenance." (BOARD N11-4)
    private static func help(_ meaning: String, isKnown: Bool) -> String {
        let conversion = L10n.text(
            "macOS 按页统计，这里按页大小换算成字节；也包含交换文件维护产生的读写。",
            " macOS counts it in pages; shown here in bytes (pages × page size). It also includes I/O for swap file maintenance."
        )
        guard isKnown else {
            return meaning + conversion + L10n.text(
                "当前未能读取系统的虚拟内存统计。",
                " The system's virtual memory statistics could not be read."
            )
        }
        return meaning + conversion
    }
}

struct GeekMemoryProcessSelectionMenu: View {
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
            Text(
                selectedCount == 0
                    ? L10n.text("选择", "Select")
                    : L10n.text("已选 \(selectedCount)", "\(selectedCount) Selected")
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

/// D2 (2026-10-04): the mini-window memory page quits exactly the apps the
/// user selected. Without a manual selection the action is unavailable and
/// does nothing; the suggested apps are only selected by the menu's explicit
/// "选择建议项" item.
@MainActor
enum GeekMemoryQuitSelection {
    static var title: String { L10n.text("退出所选应用", "Quit Selected Apps") }

    static func isAvailable(store: ScanStore) -> Bool {
        store.selectedMemoryAppCount > 0 && store.canRequestMemoryQuitActions
    }

    /// Asks for confirmation in the mini window, for the manual selection only.
    static func request(store: ScanStore) {
        guard isAvailable(store: store) else { return }
        store.requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: true)
    }

    static func help(selectedCount: Int, hasSelectableApps: Bool) -> String {
        if selectedCount > 0 {
            return L10n.text(
                "确认后正常退出已选择的 \(selectedCount) 个应用",
                "Quit the \(selectedCount) selected applications normally after confirmation"
            )
        }
        return hasSelectableApps
            ? L10n.text(
                "先在列表或“选择”菜单中选择要退出的应用",
                "Select the applications to quit in the list or the Select menu first"
            )
            : L10n.text(
                "当前没有可选择的应用",
                "No applications are currently available for selection"
            )
    }

    static var accessibilityHint: String {
        L10n.text(
            "确认后正常退出已选择的应用；未选择应用时不可用",
            "Quits the selected applications normally after confirmation; unavailable until applications are selected"
        )
    }

    /// The full-width button's title once apps are selected (U1 066/068).
    static func prominentTitle(selectedCount: Int) -> String {
        L10n.text(
            "退出所选应用（\(selectedCount) 个）",
            selectedCount == 1 ? "Quit Selected App (1)" : "Quit Selected Apps (\(selectedCount))"
        )
    }
}

/// "退出所选应用". Without a selection it is the small, unavailable header
/// button (D2). With apps selected it becomes a full-width destructive button
/// at the bottom of the process card (UI plan U1, 066/068; BOARD N19) and the
/// header shows no second one. Either asks for confirmation first
/// (`GeekMemoryQuitConfirmationHost`).
struct GeekMemoryQuitSelectedButton: View {
    enum Presentation {
        case header
        case prominent
    }

    @ObservedObject var store: ScanStore
    let tint: Color
    var presentation: Presentation = .header

    private var selectedCount: Int {
        store.selectedMemoryAppCount
    }

    private var hasSelectableApps: Bool {
        store.menuBarPreparedMemoryApps.contains { !$0.selectableProcessIDs.isEmpty }
    }

    var body: some View {
        switch presentation {
        case .header:
            // Text only: with an icon the English header actions ("View all",
            // "12 Selected", "Quit Selected Apps") exceed the card's 280 pt.
            Button(GeekMemoryQuitSelection.title) {
                GeekMemoryQuitSelection.request(store: store)
            }
            .buttonStyle(.bordered)
            .font(AdvancedPanelTypography.body)
            .controlSize(.small)
            .tint(tint)
            .disabled(!GeekMemoryQuitSelection.isAvailable(store: store))
            .help(GeekMemoryQuitSelection.help(selectedCount: selectedCount, hasSelectableApps: hasSelectableApps))
            .accessibilityLabel(GeekMemoryQuitSelection.title)
            .accessibilityHint(GeekMemoryQuitSelection.accessibilityHint)
        case .prominent:
            // A destructive action: the destructive color, never a status
            // or safe color.
            Button {
                GeekMemoryQuitSelection.request(store: store)
            } label: {
                Text(GeekMemoryQuitSelection.prominentTitle(selectedCount: selectedCount))
                    .font(AdvancedPanelTypography.captionStrong)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(AppDesignTokens.Palette.destructive)
            .disabled(!GeekMemoryQuitSelection.isAvailable(store: store))
            .help(GeekMemoryQuitSelection.help(selectedCount: selectedCount, hasSelectableApps: hasSelectableApps))
            .accessibilityLabel(GeekMemoryQuitSelection.title)
            .accessibilityValue(L10n.text("已选择 \(selectedCount) 个应用", "\(selectedCount) apps selected"))
            .accessibilityHint(GeekMemoryQuitSelection.accessibilityHint)
        }
    }
}

/// The mini window's "退出所选应用？" confirmation. It is attached to the
/// process card, not to a button, so it stays presented while the button
/// changes between its header and full-width forms.
struct GeekMemoryQuitConfirmationHost<Content: View>: View {
    @ObservedObject var store: ScanStore
    let content: Content

    init(store: ScanStore, @ViewBuilder content: () -> Content) {
        self.store = store
        self.content = content()
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
        content
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
                // BOARD N19: the apps by name and who handles unsaved work.
                if let summary = store.pendingMemoryQuitSummary {
                    Text(summary.confirmationMessage)
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
                HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
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
                        detail: result.beforeSnapshot.reportablePressureLevel?.title
                            ?? L10n.text("不可用", "Unavailable"),
                        progress: result.beforeSnapshot.measuredUsedRatio,
                        tint: AppDesignTokens.Palette.warning,
                        size: 54
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    GeekCombinedRing(
                        title: L10n.text("操作后", "After"),
                        value: result.snapshot.usedPercentText,
                        detail: result.snapshot.reportablePressureLevel?.title
                            ?? L10n.text("不可用", "Unavailable"),
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
                        Text(L10n.text("查看报告", "View Report"))
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
                AppSymbolGlyph(systemImage: isSelected ? "checkmark.circle.fill" : "circle",
                               size: MiniWindowStyleTokens.disclosureIconSlotSize, weight: .semibold)
                    .foregroundStyle(isSelected ? selectionTint : Color.secondary.opacity(0.55))
                    .frame(width: MiniWindowStyleTokens.disclosureIconSlotSize,
                           height: MiniWindowStyleTokens.disclosureIconSlotSize)
                    .accessibilityHidden(true)

                GeekSecondaryProcessIcon(path: process.iconPath, fallback: "gearshape.2")

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
            .frame(minHeight: MiniWindowStyleTokens.dataRowHeight)
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
                ? L10n.text("已选择退出", "Selected to quit")
                : L10n.text("未选择退出", "Not selected to quit")
        )
        .accessibilityHint(
            isSelectionEnabled
                ? L10n.text("切换此应用的选择状态", "Toggles this application's selection")
                : ""
        )
    }
}
