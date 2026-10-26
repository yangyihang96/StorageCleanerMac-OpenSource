import SwiftUI

extension MenuBarAdvancedStatusView {
    /// D119: iStat Menus 7.30's memory menu, 270 pt wide: the two rings
    /// (112), the composition rows (76), the processes, the swap activity
    /// rows in the page-ins slot (42) and the swap bar (40). The selection
    /// and quit actions, the quit result and the sample row are ours (D126:
    /// drawn as iStat's button items and text section).
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
                        // D126: with apps selected, iStat's destructive button
                        // item follows the list as its own 31 pt item (was a
                        // full-width bordered button inside the process card).
                        if store.selectedMemoryAppCount > 0 {
                            GeekMemoryQuitSelectedButton(store: store, tint: memoryTint, presentation: .prominent)
                        }
                    }
                    if showsExtendedGeekDetails, store.memoryOptimizationResult == nil {
                        geekMemoryPagesCard
                    }
                }
            }
            if showsExtendedGeekDetails {
                liveCard(.memory) { geekMemorySwapHoverTarget }
            }
            liveCard(.memory) { geekMemorySampleCard }
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
            // iStat: App, Wired, Compressed and Free, four untitled rows (76).
            GeekIStatRowsCard(rowCount: GeekMemoryComponent.allCases.count) {
                GeekMemoryCompositionIStatRows(composition: memorySnapshot?.ringComposition)
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
        // iStat `memory-overview` (D119, as the overview card): two 96 pt
        // rings (line 6) centered in the halves, 56 pt below the top, no
        // title. D43: pressure on the left, usage on the right.
        GeekIStatCard(height: GeekIStatCardGeometry.memoryHeight) {
            HStack(spacing: 0) {
                geekMemoryPressureRing(size: GeekIStatCardGeometry.memoryRingSize)
                    .frame(maxWidth: .infinity)
                // D138: iStat's 'Memory.Memory' (was 占用 / Used).
                GeekCombinedRing(
                    title: L10n.text("内存", "Memory"),
                    value: memoryRingUsedPercentText,
                    progress: memoryRingUsedProgress,
                    tint: resolvedPrimaryTint,
                    size: GeekIStatCardGeometry.memoryRingSize,
                    segments: memoryRingSegments,
                    fixedValueFontSize: GeekIStatCardGeometry.memoryValueFontSize,
                    strokeWidth: GeekIStatCardGeometry.memoryRingLineWidth,
                    fixedLabelFontSize: GeekIStatCardGeometry.ringLabelFontSize
                )
                .help(memoryRingExplanation)
                .frame(maxWidth: .infinity)
            }
            .geekIStatLayer(
                top: GeekIStatCardGeometry.memoryRingCenterY - GeekIStatCardGeometry.memoryRingSize / 2,
                height: GeekIStatCardGeometry.memoryRingSize
            )
        }
    }

    /// iStat's process section: the title row, then the rows on the 17 pt
    /// pitch, 25 + 17n. Our actions share the title's row; with apps selected
    /// the quit item follows the card (D126). D139: where the dimmed quit
    /// button does not fit beside the title (English, nothing selected) it
    /// takes its short title, as iStat's energy mode row takes 'Power.Mode';
    /// only when that does not fit either do the actions take the next row
    /// (was: the next row whenever all three did not fit, at 270 pt wide
    /// until apps were selected).
    private var geekMemoryProcessesCard: some View {
        GeekCombinedCard(
            height: GeekIStatSectionGeometry.processesHeight(geekMemoryProcessCapacity),
            contentInsets: GeekMemoryProcessLayout.cardInsets
        ) {
            VStack(alignment: .leading, spacing: GeekIStatSectionGeometry.rowGap) {
                ViewThatFits(in: .horizontal) {
                    memoryProcessHeader(quitHint: .header)
                    memoryProcessHeader(quitHint: .headerShort)
                    VStack(alignment: .leading, spacing: GeekIStatSectionGeometry.rowGap) {
                        memoryProcessTitle
                        memoryProcessActions
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Group {
                    if geekMemoryTopProcesses.isEmpty {
                        if store.isLoadingMemory {
                            geekMemoryLoadingIndicator
                        } else {
                            Text(L10n.text("未获得进程数据", "No process data"))
                                .geekIStatLabelText()
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityLabel(L10n.text("未获得内存进程数据", "No memory process data"))
                        }
                    } else {
                        VStack(spacing: GeekIStatSectionGeometry.rowGap) {
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
                }
                // The section keeps the height of its row capacity, and the
                // rows start 9 pt from the card's edge (iStat).
                .frame(height: GeekMemoryProcessLayout.rowsHeight(geekMemoryProcessCapacity), alignment: .top)
                .padding(.leading, GeekIStatSectionGeometry.processIconLeading - GeekIStatCardGeometry.inset)
            }
        }
    }

    /// The title row with the actions; `quitHint` is the dimmed quit button's
    /// form while nothing is selected (D139).
    private func memoryProcessHeader(quitHint: GeekMemoryQuitSelectedButton.Presentation) -> some View {
        GeekProcessListHeader(title: memoryProcessTitleText, help: memoryProcessTitleHelp,
                              accessibilityValue: memoryProcessScopeText) {
            memoryProcessActions(quitHint: quitHint)
        }
    }

    private var memoryProcessTitle: some View {
        GeekSectionTitle(title: memoryProcessTitleText)
            .layoutPriority(1)
            .frame(height: GeekIStatCardGeometry.titleHeight)
            .help(memoryProcessTitleHelp)
            .accessibilityValue(memoryProcessScopeText)
    }

    /// D139: iStat's 'Processes', which `-[BBRMemoryMenuProcessSection
    /// drawRect:]` draws upper-cased and alone on the title row, as on the
    /// CPU, disk and network pages (was 进程组 · 前N/M项 / Process groups ·
    /// N/M, now the help and the VoiceOver value).
    private var memoryProcessTitleText: String {
        L10n.text("进程", "PROCESSES")
    }

    /// How many groups are listed of how many sampled.
    private var memoryProcessScopeText: String {
        L10n.text(
            "进程组 · 前\(geekMemoryTopProcesses.count)/\(geekMemoryAllProcesses.count)项",
            "Process groups · \(geekMemoryTopProcesses.count)/\(geekMemoryAllProcesses.count)"
        )
    }

    private var memoryProcessTitleHelp: String {
        memoryProcessScopeText + L10n.text("。按应用或可执行路径合并为进程组；已选项优先，其余按内存占用排序。", ". Grouped by app or executable path; selected groups first, then memory use.")
    }

    /// D119: 12 pt text actions on one 15 pt row (iStat's row height).
    private var memoryProcessActions: some View {
        memoryProcessActions(quitHint: .header)
    }

    /// The actions with the dimmed quit button in full or, D139, with its
    /// short title (`.headerShort`).
    private func memoryProcessActions(quitHint: GeekMemoryQuitSelectedButton.Presentation) -> some View {
        HStack(spacing: 6) {
            Button(L10n.text("查看全部", "View all")) {
                store.memoryShowsAllProcesses = true
                openApp(filter: .memory)
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .font(.system(size: GeekIStatCardGeometry.textFontSize))
            .accessibilityLabel(L10n.text("在主窗口只读查看全部已采样进程", "View all sampled processes read-only in the main window"))
            GeekMemoryProcessSelectionMenu(store: store, tint: memoryTint)
            // Once apps are selected the action moves below the list.
            if store.selectedMemoryAppCount == 0 {
                GeekMemoryQuitSelectedButton(store: store, tint: memoryTint, presentation: quitHint)
            }
        }
        .frame(height: GeekIStatSectionGeometry.rowHeight)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Cumulative swap activity (the kernel's swap page counters as bytes),
    /// in iStat's page-ins slot: two untitled rows (42).
    private var geekMemoryPagesCard: some View {
        GeekIStatRowsCard(rowCount: 2) {
            if let snapshot = memorySnapshot {
                ForEach(GeekMemorySwapActivity.rows(
                    swappedInBytes: snapshot.swappedInBytes,
                    swappedOutBytes: snapshot.swappedOutBytes
                )) { row in
                    GeekIStatRow(title: row.title, value: row.value)
                        .help(row.help)
                        .accessibilityHint(row.help)
                }
            } else {
                geekMemoryLoadingIndicator
            }
        }
    }

    /// iStat's SWAP section (40): the title row with the amount used on the
    /// right, then the 8 pt bar at 24 (was a 30 pt ring with the percentage).
    private var geekMemorySwapCard: some View {
        GeekIStatCard(height: GeekIStatSectionGeometry.barSectionHeight) {
            HStack(spacing: MiniWindowStyleTokens.inlineSpacing) {
                // D138: iStat's 'Memory.Swap' (was 交换内存 / Swap Memory).
                Text(L10n.text("已使用的交换", "Swap"))
                    .font(AdvancedPanelTypography.header)
                    .textCase(.uppercase)
                    .foregroundStyle(panelMetricColors.sectionHeader)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help(geekSwapExplanation)
                Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)
                Text(memorySnapshot.map(swapUsageText) ?? "—")
                    .geekIStatValueText()
                    .truncationMode(.middle)
            }
            .geekIStatLayer(top: GeekIStatCardGeometry.titleTop, height: GeekIStatCardGeometry.titleHeight)

            GeekMemorySwapBar(progress: geekSwapProgress, tint: panelMetricColors.swap)
                .geekIStatLayer(top: GeekIStatCardGeometry.batteryBarTop, height: GeekIStatCardGeometry.batteryBarHeight)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("已使用的交换", "Swap"))
        .accessibilityValue([memorySnapshot.map(swapUsageText), geekSwapPercentText]
            .compactMap { $0 }
            .joined(separator: ", "))
    }

    private var geekMemorySwapHoverTarget: some View {
        GeekHoverDetailTarget(
            accessibilityLabel: L10n.text("交换内存三级详情", "Swap Memory Deep Detail"),
            chartRangeMetric: .memory,
            popoverSize: GeekSwapHoverDetail.popoverSize
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

    /// The memory snapshot's freshness: "采样 12 秒前", or 已过期 / 已暂停 /
    /// an unavailability reason. D119: a 25 pt row at the end of the page;
    /// it was the trailing readout of the rings card's title, which iStat
    /// does not draw.
    private var geekMemorySampleCard: some View {
        GeekIStatSingleRowCard(title: L10n.text("数据", "Data")) {
            TimelineView(.periodic(from: .now, by: MemorySampleStatusPresentation.refreshInterval)) { timeline in
                Text(memorySampleStatusText(at: timeline.date))
                    .geekIStatValueText()
                    .help(memorySampleEvidenceText)
                    .accessibilityHint(memorySampleEvidenceText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("内存采样", "Memory sample"))
        .accessibilityValue(memorySampleEvidenceText)
    }

    private var geekMemoryProcessCapacity: Int {
        GeekMemoryProcessLayout.rowCapacity(extended: showsExtendedGeekDetails)
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
                .prefix(geekMemoryProcessCapacity)
        )
    }

    private func swapUsageText(_ snapshot: MemorySnapshot) -> String {
        guard let used = snapshot.measurements.swapUsedBytes.value else {
            return snapshot.measurements.swapUsedBytes.availability.title
        }
        // D128: iStat's swap section (`format:`) uses its memory format.
        let usedText = IStatNumberFormat.memory(used)
        guard snapshot.swapTotalBytes > 0 else {
            return L10n.text("\(usedText) · 未使用", "\(usedText) · Inactive")
        }
        return "\(usedText) / \(IStatNumberFormat.memory(snapshot.swapTotalBytes))"
    }

    private var geekMemoryLoadingIndicator: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(L10n.text("正在采样", "Sampling"))
    }
}

/// iStat's 8 pt bar on the ring track of the current appearance.
private struct GeekMemorySwapBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelChromePalette) private var panelChromePalette
    @Environment(\.miniWindowVisualMode) private var visualMode
    let progress: Double?
    let tint: Color

    var body: some View {
        GeekIStatBar(progress: progress, tint: tint,
                     track: GeekVisualTokens.ringTrack(for: colorScheme, visualMode: visualMode, palette: panelChromePalette))
    }
}

/// D119: the memory page's process section in iStat's geometry (270 pt
/// wide): the title's 5 pt top inset and the 8 pt sides, rows on the 17 pt
/// pitch; each row starts with our 12 pt selection mark where iStat draws
/// the icon (9 pt from the card's edge), the icon and the name follow.
/// D150: the mark only on the rows that can be quit; the others keep its
/// slot blank.
enum GeekMemoryProcessLayout {
    static let selectionMarkSize: CGFloat = 12

    static var cardInsets: EdgeInsets {
        EdgeInsets(top: GeekIStatCardGeometry.titleTop, leading: GeekIStatCardGeometry.inset,
                   bottom: GeekIStatCardGeometry.titleTop, trailing: GeekIStatCardGeometry.inset)
    }

    /// Five rows with the extended details (the geek density), three
    /// otherwise; the card keeps this height whatever the number listed.
    static func rowCapacity(extended: Bool) -> Int { extended ? 5 : 3 }

    static func rowsHeight(_ capacity: Int) -> CGFloat {
        CGFloat(max(1, capacity)) * GeekIStatSectionGeometry.rowPitch - GeekIStatSectionGeometry.rowGap
    }

    /// The card without a quit button: iStat's 25 + 17n, one row more when
    /// the actions take their own row.
    static func cardHeight(rowCapacity: Int, actionsOnOwnRow: Bool) -> CGFloat {
        GeekIStatSectionGeometry.processesHeight(rowCapacity) + (actionsOnOwnRow ? GeekIStatSectionGeometry.rowPitch : 0)
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
        bytes.map { IStatNumberFormat.memory($0) } ?? "—"
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
                    Text("\(app.name) · \(IStatNumberFormat.memory(app.bytes))")
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
                    : L10n.text("已选 \(ByteFormat.count(selectedCount))", "\(ByteFormat.count(selectedCount)) Selected")
            )
            // D119: iStat's 12 pt row text (was 11 pt).
            .font(.system(size: GeekIStatCardGeometry.textFontSize))
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
                : L10n.text("已选择 \(ByteFormat.count(selectedCount)) 个应用", "\(ByteFormat.count(selectedCount)) Apps Selected")
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

    /// D139: the header button's short title where the full one does not
    /// fit beside the section title (English, nothing selected), as iStat
    /// shortens 'Power.Energy Mode' to 'Power.Mode'. VoiceOver keeps `title`.
    static var shortTitle: String { L10n.text("退出", "Quit") }

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
                "确认后正常退出已选择的 \(ByteFormat.count(selectedCount)) 个应用",
                "Quit the \(ByteFormat.count(selectedCount)) selected applications normally after confirmation"
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
            "退出所选应用（\(ByteFormat.count(selectedCount)) 个）",
            selectedCount == 1 ? "Quit Selected App (1)" : "Quit Selected Apps (\(ByteFormat.count(selectedCount)))"
        )
    }
}

/// "退出所选应用". Without a selection it is the small, unavailable header
/// button (D2). With apps selected it becomes a full-width destructive button
/// below the process card (UI plan U1, 066/068; BOARD N19; D126: iStat's
/// destructive button item) and the header shows no second one. Either asks
/// for confirmation first (`GeekMemoryQuitConfirmationHost`).
struct GeekMemoryQuitSelectedButton: View {
    enum Presentation {
        case header
        /// D139: the header button with `GeekMemoryQuitSelection.shortTitle`.
        case headerShort
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
        case .header, .headerShort:
            // Text only, like the other actions on the 15 pt row. D119: plain
            // 12 pt text (was a small bordered button, taller than iStat's
            // rows); shown only without a selection, so it is dimmed (D2).
            Button(presentation == .header ? GeekMemoryQuitSelection.title : GeekMemoryQuitSelection.shortTitle) {
                GeekMemoryQuitSelection.request(store: store)
            }
            .buttonStyle(ResponsivePlainButtonStyle())
            .font(.system(size: GeekIStatCardGeometry.textFontSize))
            .tint(tint)
            .disabled(!GeekMemoryQuitSelection.isAvailable(store: store))
            .help(GeekMemoryQuitSelection.help(selectedCount: selectedCount, hasSelectableApps: hasSelectableApps))
            .accessibilityLabel(GeekMemoryQuitSelection.title)
            .accessibilityHint(GeekMemoryQuitSelection.accessibilityHint)
        case .prominent:
            // A destructive action. D126: iStat's destructive button item
            // (`BBRButtonMenuItem` type 2: the red gradient, white text, 31
            // pt); was a bordered prominent button in the destructive color
            // with "退出所选应用" as its spoken label and the count as its
            // value, which the item's label now carries.
            GeekIStatButtonItem(title: GeekMemoryQuitSelection.prominentTitle(selectedCount: selectedCount),
                                kind: .destructive) {
                GeekMemoryQuitSelection.request(store: store)
            }
            .disabled(!GeekMemoryQuitSelection.isAvailable(store: store))
            .help(GeekMemoryQuitSelection.help(selectedCount: selectedCount, hasSelectableApps: hasSelectableApps))
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

/// D126: the quit result in iStat's style (the memory cleanup is one of the
/// four features of ours the mini window keeps, drawn with iStat's parts): a
/// text section with the major label and a label and value row each for the
/// apps quit, skipped and failed, the memory before and after (used,
/// pressure), the memory made available and the time taken, then our note
/// (the coordinator's summary), and "完成" and "查看报告" as button items. Was
/// a 220 pt card with two 54 pt rings and an arrow, the counts as colored
/// dots and bordered buttons; the time read "扫描 … 秒".
private struct GeekMemoryQuitResultCard: View {
    let result: MemoryOptimizationResult
    let onDone: () -> Void
    let onOpenReport: () -> Void

    var body: some View {
        VStack(spacing: GeekPanelLayout.detailSpacing) {
            GeekIStatTextSectionCard {
                GeekIStatMajorLabelRow(title: L10n.text("退出结果", "Quit Result"))
                ForEach(rows, id: \.title) { row in
                    GeekIStatValueRow(title: row.title, value: row.value)
                }
                if !result.detail.isEmpty {
                    Text(result.detail)
                        .geekIStatSectionNote()
                }
            }
            GeekIStatButtonItem(title: L10n.text("完成", "Done"), kind: .standard, action: onDone)
            GeekIStatButtonItem(title: L10n.text("查看报告", "View Report"), kind: .standard, action: onOpenReport)
        }
    }

    /// The label and value rows, in the order above.
    var rows: [GeekIStatInterfaceModel.Row] {
        [
            .init(title: L10n.text("正常退出", "Quit"), value: ByteFormat.count(successfulCount)),
            .init(title: L10n.text("跳过", "Skipped"), value: ByteFormat.count(skippedCount)),
            .init(title: L10n.text("失败", "Failed"), value: ByteFormat.count(failedCount)),
            .init(title: L10n.text("操作前", "Before"), value: memoryText(
                used: result.beforeSnapshot.usedPercentText,
                pressure: result.beforeSnapshot.reportablePressureLevel?.title
            )),
            .init(title: L10n.text("操作后", "After"), value: memoryText(
                used: result.snapshot.usedPercentText,
                pressure: result.snapshot.reportablePressureLevel?.title
            )),
            .init(title: L10n.text("可用内存增加", "More Available"), value: IStatNumberFormat.memory(result.releasedBytes)),
            .init(title: L10n.text("用时", "Time"), value: durationText),
        ]
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

    /// The used share and the system's pressure level, as the two rings
    /// showed them.
    private func memoryText(used: String, pressure: String?) -> String {
        "\(used) · \(pressure ?? L10n.text("不可用", "Unavailable"))"
    }

    private var durationText: String {
        let seconds = String(format: "%.1f", result.durationSeconds)
        return L10n.text("\(seconds) 秒", "\(seconds) s")
    }
}

/// D150: internal, so the offscreen test renders the production row.
struct GeekCompactMemoryProcessRow: View {
    let process: MemoryAppUsage
    let isSelected: Bool
    let isSelectionEnabled: Bool
    let selectionTint: Color
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            // D119: iStat's 15 pt process row (12 pt name and value, the
            // value at the trailing inset) behind our selection mark.
            HStack(spacing: GeekIStatSectionGeometry.processNameSpacing) {
                // D150: the mark only where the application can be quit
                // (user, 2026-10-19: "进程里关闭的程序要显示的都是可以关闭的"),
                // also while a quit locks the selection; a read-only row
                // keeps the slot blank, so its icon and name stay in the
                // column (was: a dimmed circle on every row).
                ZStack {
                    if process.canQuit {
                        AppSymbolGlyph(systemImage: isSelected ? "checkmark.circle.fill" : "circle",
                                       size: GeekMemoryProcessLayout.selectionMarkSize, weight: .semibold)
                            .foregroundStyle(isSelected ? selectionTint : Color.secondary.opacity(0.55))
                    }
                }
                .frame(width: GeekMemoryProcessLayout.selectionMarkSize,
                       height: GeekMemoryProcessLayout.selectionMarkSize)
                .accessibilityHidden(true)

                GeekSecondaryProcessIcon(path: process.iconPath, fallback: "gearshape.2")

                Text(process.name)
                    .geekIStatLabelText()
                    .truncationMode(.middle)

                Spacer(minLength: MiniWindowStyleTokens.inlineSpacing)

                Text(IStatNumberFormat.memory(process.bytes))
                    .geekIStatValueText()
            }
            .frame(height: GeekIStatSectionGeometry.rowHeight)
            .contentShape(Rectangle())
            .background {
                // The selection fills the row's pitch, 1 pt around the row.
                RoundedRectangle(cornerRadius: MiniWindowStyleTokens.controlCornerRadius, style: .continuous)
                    .fill(isSelected ? selectionTint.opacity(0.14) : .clear)
                    .padding(.vertical, -GeekIStatSectionGeometry.rowGap / 2)
                    .padding(.horizontal, -GeekIStatSectionGeometry.rowGap)
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
