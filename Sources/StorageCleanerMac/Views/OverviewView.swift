import SwiftUI

enum OverviewResultPrimaryActionKind: Equatable {
    case reviewAndClean
    case scanAgain
}

struct OverviewResultActionPolicy {
    let hasCleanableItems: Bool
    let canRequestGreenTrash: Bool
    let canRequestTrashActions: Bool

    var action: OverviewResultPrimaryActionKind {
        hasCleanableItems ? .reviewAndClean : .scanAgain
    }

    var isEnabled: Bool {
        switch action {
        case .reviewAndClean:
            canRequestGreenTrash
        case .scanAgain:
            canRequestTrashActions
        }
    }
}

struct OverviewView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let result: ScanResult
    @ObservedObject var store: ScanStore
    @Binding var selection: ReviewFilter
    @State private var isPermissionListExpanded = true
    private let scoreBreakdown: SmartScoreBreakdown
    private let cleanupProjection: CleanupScoreProjection
    private let cleanupFollowUp: CleanupFollowUpSummary

    init(result: ScanResult, store: ScanStore, selection: Binding<ReviewFilter>) {
        self.result = result
        self.store = store
        _selection = selection

        let projection = ScanHistoryService.cleanupProjection(for: result)
        scoreBreakdown = ScanHistoryService.scoreBreakdown(for: result, referenceDate: Date())
        cleanupProjection = projection
        cleanupFollowUp = CleanupFollowUpSummary(
            projection: projection,
            movedToTrashCount: result.movedToTrashItems.count,
            movedToTrashBytes: result.movedToTrashBytes
        )
    }

    var body: some View {
        DashboardPage(
            title: ReviewFilter.overview.title,
            subtitle: L10n.text(
                "扫描完成 · \(L10n.scanSeconds(result.scanSeconds))",
                "Scan complete · \(L10n.scanSeconds(result.scanSeconds))"
            ),
            systemImage: AppSymbols.Navigation.overview
        ) {
            resultHeaderActions
        } content: {
            ScrollView {
                VStack(spacing: 14) {
                    resultHeroStage
                        .appMotionEntrance(delay: 0.035)
                    tierSection
                        .appMotionEntrance(delay: 0.07)
                    resultTaskGrid
                        .appMotionEntrance(delay: 0.10)

                    if store.shouldShowPermissionPanelInMainInterface {
                        permissionPanel
                            .transition(AppMotionTokens.stateTransition(reduceMotion: reduceMotion, edge: .bottom))
                            .appMotionEntrance(delay: 0.13)
                    }
                }
                .padding(AppDesignTokens.Layout.pagePadding)
                .animation(
                    AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                    value: store.shouldShowPermissionPanelInMainInterface
                )
            }
            .scrollIndicators(.hidden)
        }
        .onAppear {
            store.prepareInitialPermissionCheckOnLaunch()
        }
    }

    @ViewBuilder
    private var resultHeaderActions: some View {
            if resultActionPolicy.action == .reviewAndClean {
                GlassToolbarButton(
                    title: L10n.text("重新扫描", "Scan Again"),
                    systemImage: "arrow.counterclockwise",
                    isDisabled: !store.canRequestTrashActions
                ) {
                    store.startScanRespectingAccessGuide()
                }
            }

            Menu {
                Button {
                    store.exportReport()
                } label: {
                    Label(L10n.text("导出报告", "Export Report"), systemImage: "square.and.arrow.down")
                }
                .disabled(!store.canExportCurrentScanArtifacts)

                if scanCoverageSummary.level != .complete,
                   !store.shouldShowPermissionPanelInMainInterface {
                    Divider()

                    Button {
                        CleanupService.openFullDiskAccessSettings()
                    } label: {
                        Label(L10n.text("完整磁盘访问", "Full Disk Access"), systemImage: "externaldrive")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppDesignTokens.Typography.toolbar)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel(L10n.text("更多操作", "More Actions"))
            .help(L10n.text("更多操作", "More Actions"))
    }

    private var resultHeroStage: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 32) {
                SmartScanResultRing(
                    candidateBytes: candidateBytes,
                    recommendedBytes: cleanupProjection.cleanableBytes,
                    candidateCount: candidateCount
                )
                .frame(width: 168, height: 168)

                resultHeroCopy
            }
            .frame(minWidth: 650, minHeight: 204, alignment: .center)

            VStack(spacing: 20) {
                SmartScanResultRing(
                    candidateBytes: candidateBytes,
                    recommendedBytes: cleanupProjection.cleanableBytes,
                    candidateCount: candidateCount
                )
                .frame(width: 168, height: 168)

                resultHeroCopy
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, minHeight: 350)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .fullBleedSection()
    }

    private var resultHeroCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(resultHeadingTitle)
                .font(AppDesignTokens.Typography.metricValueLarge)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                L10n.text(
                    "\(L10n.scanSeconds(result.scanSeconds)) · \(resultSummaryDetail)",
                    "\(L10n.scanSeconds(result.scanSeconds)) · \(resultSummaryDetail)"
                )
            )
            .font(AppDesignTokens.Typography.body)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)

            if cleanupProjection.hasCleanableItems {
                Label(
                    L10n.text(
                        "建议选择 \(ByteFormat.string(cleanupProjection.cleanableBytes)) · \(cleanupProjection.cleanableCount) 项",
                        "\(ByteFormat.string(cleanupProjection.cleanableBytes)) recommended · \(L10n.items(cleanupProjection.cleanableCount))"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(AppDesignTokens.Palette.success)
                .monospacedDigit()
            }

            Button {
                performResultPrimaryAction()
            } label: {
                Label(resultPrimaryActionTitle, systemImage: resultPrimaryActionIcon)
                    .frame(minWidth: 112)
            }
            .appButtonChrome(.primary)
            .controlSize(.large)
            .tint(resultPrimaryActionTint)
            .disabled(!resultActionPolicy.isEnabled)
            .padding(.top, 6)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var resultTaskGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 14)],
            spacing: 14
        ) {
            SmartCareResultTaskTile(
                title: L10n.text("可安全清理", "Safe Cleanup"),
                value: cleanupProjection.hasCleanableItems
                    ? ByteFormat.string(cleanupProjection.cleanableBytes)
                    : L10n.text("无可清理项", "Nothing to Clean"),
                detail: cleanupProjection.hasCleanableItems
                    ? L10n.text("\(cleanupProjection.cleanableCount) 项可移到废纸篓", "\(cleanupProjection.cleanableCount) items can move to Trash")
                    : L10n.text("未发现可安全清理项目", "No safe cleanup items found"),
                systemImage: "sparkles",
                tint: AppDesignTokens.Palette.success,
                isReady: cleanupProjection.hasCleanableItems,
                isActionable: cleanupProjection.hasCleanableItems,
                actionTitle: L10n.text("查看", "Review")
            ) {
                store.showCleanupReview(scope: .cleanable)
                selection = .green
            }

            SmartCareResultTaskTile(
                title: ReviewFilter.devCaches.title,
                value: developerCacheItems.isEmpty
                    ? L10n.text("无开发产物", "No Artifacts")
                    : ByteFormat.string(developerCacheBytes),
                detail: developerCacheItems.isEmpty
                    ? L10n.text("未发现 Codex 或开发中间产物", "No Codex or development artifacts found")
                    : L10n.text("\(developerCacheItems.count) 组候选可复核", "\(developerCacheItems.count) candidate groups to review"),
                systemImage: "hammer.fill",
                tint: AppDesignTokens.Palette.freshness,
                isReady: !developerCacheItems.isEmpty,
                isActionable: !developerCacheItems.isEmpty,
                actionTitle: L10n.text("查看", "Review")
            ) {
                selection = .devCaches
            }

            SmartCareResultTaskTile(
                title: ReviewFilter.largeFiles.title,
                value: store.largeFilesWorkspace.storageAnalysis.map {
                    ByteFormat.string($0.rootSnapshot.measuredBytes)
                } ?? L10n.text("尚未分析", "Not Analyzed"),
                detail: store.largeFilesWorkspace.storageAnalysis.map {
                    L10n.text(
                        "已索引 \($0.inspectedItemCount) 项，可逐层查看",
                        "\($0.inspectedItemCount) items indexed for drill-down"
                    )
                } ?? L10n.text("建立目录索引并查看空间比例", "Build an index and inspect space usage"),
                systemImage: "doc.text.magnifyingglass",
                tint: AppDesignTokens.Palette.storage,
                isReady: store.largeFilesWorkspace.hasStorageAnalysis,
                isActionable: true,
                actionTitle: store.largeFilesWorkspace.hasStorageAnalysis
                    ? L10n.text("查看", "View")
                    : L10n.text("分析", "Analyze")
            ) {
                selection = .largeFiles
            }

            SmartCareResultTaskTile(
                title: ReviewFilter.duplicates.title,
                value: duplicateTileValue,
                detail: duplicateTileDetail,
                systemImage: "square.on.square",
                tint: AppDesignTokens.Palette.tertiary,
                isReady: !duplicateItems.isEmpty,
                actionTitle: duplicateItems.isEmpty ? L10n.text("扫描", "Scan") : L10n.text("查看", "Review")
            ) {
                selection = .duplicates
            }
        }
    }

    private var developerCacheItems: [StorageItem] {
        result.items(for: .devCaches)
    }

    private var developerCacheBytes: Int64 {
        developerCacheItems.reduce(0) { $0 + $1.sizeBytes }
    }

    private var largeFileItems: [StorageItem] {
        let workspaceItems = store.largeFilesWorkspace.items
        if store.largeFilesWorkspace.hasScanned || store.largeFilesWorkspace.isScanning || !workspaceItems.isEmpty {
            return workspaceItems
        }
        return result.items(for: .largeFiles)
    }

    private var duplicateItems: [StorageItem] {
        let workspaceItems = store.duplicateFilesWorkspace.items
        if store.duplicateFilesWorkspace.hasScanned || store.duplicateFilesWorkspace.isScanning || !workspaceItems.isEmpty {
            return workspaceItems
        }
        return result.items(for: .duplicates)
    }

    private var duplicateTileValue: String {
        guard !duplicateItems.isEmpty else {
            return store.duplicateFilesWorkspace.hasScanned
                ? L10n.text("无重复文件", "No Duplicates")
                : L10n.text("尚未扫描", "Not Scanned")
        }
        return ByteFormat.string(duplicateItems.reduce(0) { $0 + $1.sizeBytes })
    }

    private var duplicateTileDetail: String {
        guard !duplicateItems.isEmpty else {
            return store.duplicateFilesWorkspace.hasScanned
                ? L10n.text("没有重复候选", "No duplicate candidates")
                : L10n.text("单独扫描并逐组复核", "Scan separately and review each group")
        }
        return L10n.text("\(duplicateItems.count) 组待复核", "\(duplicateItems.count) groups to review")
    }

    private var resultHeadingTitle: String {
        candidateCount > 0
            ? L10n.text("扫描完成", "Scan Complete")
            : L10n.text("没有发现需要处理的候选", "No Candidates Need Attention")
    }

    private var candidateBytes: Int64 {
        result.identifiedDecisionBytes
    }

    private var candidateCount: Int {
        result.items.filter {
            $0.status == .available && $0.tier != .other
        }.count
    }

    private var resultActionPolicy: OverviewResultActionPolicy {
        OverviewResultActionPolicy(
            hasCleanableItems: cleanupProjection.hasCleanableItems,
            canRequestGreenTrash: store.canRequestGreenTrash,
            canRequestTrashActions: store.canRequestTrashActions
        )
    }

    private var resultSummaryDetail: String {
        if cleanupProjection.hasCleanableItems {
            return L10n.text(
                "发现 \(ByteFormat.string(cleanupProjection.cleanableBytes)) 可安全复核",
                "\(ByteFormat.string(cleanupProjection.cleanableBytes)) ready for safe review"
            )
        }
        if !developerCacheItems.isEmpty || !largeFileItems.isEmpty {
            return L10n.text("有项目等待确认", "Items Are Waiting for Review")
        }
        return L10n.text("没有需要立即处理的项目", "No Items Need Immediate Action")
    }

    private var resultPrimaryActionTitle: String {
        switch resultActionPolicy.action {
        case .reviewAndClean:
            L10n.text("选择清理项目", "Choose Cleanup Items")
        case .scanAgain:
            L10n.text("重新扫描", "Scan Again")
        }
    }

    private var resultPrimaryActionIcon: String {
        switch resultActionPolicy.action {
        case .reviewAndClean:
            "checkmark.square"
        case .scanAgain:
            "arrow.clockwise"
        }
    }

    private var resultPrimaryActionTint: Color {
        switch resultActionPolicy.action {
        case .reviewAndClean:
            AppDesignTokens.Palette.success
        case .scanAgain:
            scoreTint
        }
    }

    private func performResultPrimaryAction() {
        guard resultActionPolicy.isEnabled else { return }

        switch resultActionPolicy.action {
        case .reviewAndClean:
            store.requestTrashAllGreen()
        case .scanAgain:
            store.startScanRespectingAccessGuide()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AppDesignTokens.Spacing.medium) {
            AppSymbolIcon(
                systemImage: AppSymbols.Navigation.overview,
                role: .pageFeature,
                tint: AppDesignTokens.Palette.accent,
                isDecorative: true
            )

            VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textTightSpacing) {
                Text(L10n.text("智能扫描", "Smart Scan"))
                    .font(AppDesignTokens.Typography.sectionTitle)

                Text(L10n.text("扫描完成 · \(L10n.scanSeconds(result.scanSeconds))", "Scan complete · \(L10n.scanSeconds(result.scanSeconds))"))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Label(L10n.text("本机体检完成", "Local scan complete"), systemImage: "checkmark.seal.fill")
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.success)
        }
        .frame(maxWidth: .infinity)
    }

    private var scanCoverageSummary: ScanCoverageSummary {
        ScanCoverageService.summary(deniedPaths: result.deniedPaths)
    }

    private var scanFreshnessSummary: ScanFreshnessSummary {
        ScanFreshnessService.summary(generatedAt: result.generatedAt)
    }

    private var scanFreshnessSection: some View {
        HStack(alignment: .center, spacing: 14) {
            AppSymbolIcon(
                systemImage: scanFreshnessIcon,
                role: .pageFeature,
                tint: scanFreshnessTint,
                isDecorative: true
            )

            VStack(alignment: .leading, spacing: AppDesignTokens.Layout.textRegularSpacing) {
                Text(scanFreshnessTitle)
                    .font(AppDesignTokens.Typography.inlineTitle)
                Text(scanFreshnessDetail)
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                MetadataPill(
                    text: scanFreshnessPillText,
                    systemImage: "clock",
                    tint: scanFreshnessTint
                )

                HStack(spacing: 8) {
                    Button {
                        store.startScanRespectingAccessGuide()
                    } label: {
                        Label(
                            store.scanActionTitle(normalTitle: scanFreshnessButtonTitle),
                            systemImage: store.scanActionSystemImage(normalSystemImage: "arrow.clockwise")
                        )
                    }
                    .appButtonChrome(.primary)
                    .controlSize(.regular)
                    .tint(scanFreshnessTint)
                    .disabled(store.isPreparingScan)

                }
            }
        }
        .padding(16)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: scanFreshnessTint,
            elevated: scanFreshnessSummary.shouldRescan,
            prominence: scanFreshnessSummary.shouldRescan ? .regular : .quiet
        )
    }

    private var scanFreshnessTint: Color {
        switch scanFreshnessSummary.level {
        case .fresh:
            AppDesignTokens.Palette.success
        case .aging:
            AppDesignTokens.Palette.warning
        case .stale:
            AppDesignTokens.Palette.destructive
        }
    }

    private var scanFreshnessIcon: String {
        switch scanFreshnessSummary.level {
        case .fresh:
            "clock.fill"
        case .aging:
            "clock.badge.exclamationmark"
        case .stale:
            "clock.arrow.circlepath"
        }
    }

    private var scanFreshnessTitle: String {
        switch scanFreshnessSummary.level {
        case .fresh:
            L10n.text("结果仍然新鲜", "Results Are Current")
        case .aging:
            L10n.text("建议重新扫描", "Rescan")
        case .stale:
            L10n.text("扫描结果可能过期", "Scan May Be Outdated")
        }
    }

    private var scanFreshnessDetail: String {
        let dateText = result.generatedAt.formatted(date: .abbreviated, time: .shortened)
        switch scanFreshnessSummary.level {
        case .fresh:
            return L10n.text("扫描于 \(dateText)", "Scanned \(dateText)")
        case .aging:
            return L10n.text("扫描于 \(dateText)", "Scanned \(dateText)")
        case .stale:
            return L10n.text("扫描于 \(dateText)", "Scanned \(dateText)")
        }
    }

    private var scanFreshnessPillText: String {
        switch scanFreshnessSummary.level {
        case .fresh:
            L10n.text("2 小时内", "Under 2h")
        case .aging:
            L10n.text("超过 2 小时", "Over 2h")
        case .stale:
            L10n.text("超过 24 小时", "Over 24h")
        }
    }

    private var scanFreshnessButtonTitle: String {
        scanFreshnessSummary.shouldRescan
            ? L10n.text("重新扫描", "Rescan")
            : L10n.text("再次扫描", "Scan Again")
    }

    private var scanCoverageTint: Color {
        switch scanCoverageSummary.level {
        case .complete:
            AppDesignTokens.Palette.success
        case .partial:
            AppDesignTokens.Palette.warning
        case .limited:
            AppDesignTokens.Palette.destructive
        }
    }

    private var scanCoverageTitle: String {
        switch scanCoverageSummary.level {
        case .complete:
            L10n.text("扫描口径完整", "Full Scan Coverage")
        case .partial:
            L10n.text("扫描口径局部受限", "Scan Coverage Partially Limited")
        case .limited:
            L10n.text("扫描口径明显受限", "Scan Coverage Limited")
        }
    }

    private var scanCoverageDetail: String {
        switch scanCoverageSummary.level {
        case .complete:
            L10n.text("未发现权限阻断", "No access blocks")
        case .partial, .limited:
            L10n.text("\(scanCoverageSummary.deniedCount) 个位置未读取", "\(scanCoverageSummary.deniedCount) unread locations")
        }
    }

    private var smartScore: Int {
        scoreBreakdown.score
    }

    private var usedRatio: Double {
        guard result.system.diskTotalBytes > 0 else { return 0 }
        return Double(result.system.diskUsedBytes) / Double(result.system.diskTotalBytes)
    }

    private var scoreTint: Color {
        switch SmartScoreBand(score: smartScore) {
        case .excellent:
            AppDesignTokens.Palette.success
        case .good:
            AppDesignTokens.Palette.freshness
        case .fair:
            AppDesignTokens.Palette.information
        case .attention:
            AppDesignTokens.Palette.warning
        case .critical:
            AppDesignTokens.Palette.destructive
        }
    }

    private var statusHeadline: String {
        if !result.deniedPaths.isEmpty {
            return L10n.text("授权后评分会更准确", "Grant access for a more accurate score")
        }
        if usedRatio >= 0.9 {
            return L10n.text("磁盘压力偏高", "Disk pressure is high")
        }
        if result.greenBytes > 0 {
            return L10n.text("可清理缓存", "Cleanable cache")
        }
        return L10n.text("当前状态平稳", "Current state is steady")
    }

    private var statusDetail: String {
        if !result.deniedPaths.isEmpty {
            return L10n.text("\(result.deniedPaths.count) 个位置未读取", "\(result.deniedPaths.count) unread locations")
        }
        if usedRatio >= 0.9 {
            return L10n.text("已使用 \(ByteFormat.percent(result.system.diskUsedBytes, of: result.system.diskTotalBytes))", "\(ByteFormat.percent(result.system.diskUsedBytes, of: result.system.diskTotalBytes)) used")
        }
        if result.greenBytes > 0 {
            return L10n.text("可安全清理 \(ByteFormat.string(result.greenBytes))", "\(ByteFormat.string(result.greenBytes)) safe to clean")
        }
        return L10n.text("没有紧急项目", "No urgent items")
    }

    private var primaryScoreFactor: SmartScoreFactor? {
        scoreBreakdown.factors
            .filter { $0.penalty > 0 }
            .sorted {
                if $0.penalty == $1.penalty {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.penalty > $1.penalty
            }
            .first
    }

    private var cleanActionPanel: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 26) {
                cleanActionVisual
                cleanActionCopy
                Spacer(minLength: 12)
                cleanActionButtons
            }

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 20) {
                    cleanActionVisual
                    cleanActionCopy
                }
                cleanActionButtons
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 246, alignment: .leading)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: scoreTint, elevated: true, prominence: .regular)
    }

    private var cleanActionVisual: some View {
        SmartCareGauge(
            score: smartScore,
            tint: scoreTint,
            label: L10n.text("存储评分", "Storage score")
        )
        .frame(width: 176, height: 176)
        .accessibilityHidden(true)
    }

    private var cleanActionCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cleanActionEyebrow)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(StorageTier.green.color)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ByteFormat.string(cleanupProjection.cleanableBytes))
                    .font(AppDesignTokens.Typography.heroTitle)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)

                Text(cleanActionAmountSuffix)
                    .font(AppDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(cleanActionDetail)
                .font(AppDesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    private var cleanActionButtons: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if store.canRequestGreenTrash {
                Button {
                    store.requestTrashAllGreen()
                } label: {
                    Label(cleanActionPrimaryTitle, systemImage: "sparkles")
                        .frame(minWidth: 96)
                }
                .appButtonChrome(.primary)
                .controlSize(.large)
                .tint(StorageTier.green.color)
            } else {
                Button {
                    store.startScanRespectingAccessGuide()
                } label: {
                    Label(
                        store.scanActionTitle(normalTitle: L10n.text("再次扫描", "Scan Again")),
                        systemImage: store.scanActionSystemImage(normalSystemImage: "arrow.clockwise")
                    )
                    .frame(minWidth: 96)
                }
                .appButtonChrome(.primary)
                .controlSize(.large)
                .tint(scoreTint)
                .disabled(store.isPreparingScan)
            }

            if store.canRequestGreenTrash {
                Button {
                    store.startScanRespectingAccessGuide()
                } label: {
                    Image(systemName: store.scanActionSystemImage(normalSystemImage: "arrow.clockwise"))
                        .frame(width: 18, height: 18)
                }
                .appButtonChrome(.secondary)
                .controlSize(.large)
                .help(L10n.text("重新扫描", "Rescan"))
                .accessibilityLabel(L10n.text("重新扫描", "Rescan"))
                .disabled(store.isPreparingScan)
            }
        }
    }

    private var cleanActionRingProgress: CGFloat {
        guard cleanupProjection.hasCleanableItems else { return 1 }
        let reference = max(Double(result.greenBytes + result.yellowBytes + result.redBytes), Double(cleanupProjection.cleanableBytes))
        guard reference > 0 else { return 1 }
        return CGFloat(min(1, max(0.12, Double(cleanupProjection.cleanableBytes) / reference)))
    }

    private var cleanActionEyebrow: String {
        cleanupProjection.hasCleanableItems
            ? L10n.text("批量清理预览", "Batch Cleanup Preview")
            : L10n.text("当前无批量清理候选", "No Batch Cleanup Candidates")
    }

    private var cleanActionAmountSuffix: String {
        cleanupProjection.hasCleanableItems
            ? L10n.text("可处理", "ready")
            : L10n.text("待清理", "pending")
    }

    private var cleanActionDetail: String {
        if cleanupProjection.hasCleanableItems {
            return L10n.text("\(cleanupProjection.cleanableCount) 个可安全清理项目", "\(cleanupProjection.cleanableCount) safe cleanup items")
        }
        return L10n.text("没有可安全清理项目", "No safe cleanup items")
    }

    private var cleanActionPrimaryTitle: String {
        cleanupProjection.hasCleanableItems
            ? L10n.text("预览清理", "Preview Cleanup")
            : L10n.text("已清理", "Clean")
    }

    private var permissionSummary: ScanReadinessSummary {
        store.scanReadinessSummary ?? ScanReadinessService.summary(fromScanDeniedPaths: result.deniedPaths)
    }

    private var permissionTint: Color {
        if store.isCheckingScanReadiness {
            return AppDesignTokens.Palette.secondary
        }
        if permissionSummary.isFullDiskAccessVerified {
            return permissionSummary.level == .ready ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.information
        }
        return permissionSummary.level == .ready ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.warning
    }

    private var permissionTitle: String {
        if store.isCheckingScanReadiness {
            return L10n.text("正在检查权限", "Checking Permissions")
        }
        if permissionSummary.isFullDiskAccessVerified {
            return L10n.text("完整磁盘访问已生效", "Full Disk Access Active")
        }
        return permissionSummary.level == .ready
            ? L10n.text("权限状态正常", "Permissions Ready")
            : L10n.text("权限需要确认", "Permissions Need Review")
    }

    private var permissionDetail: String {
        if store.isCheckingScanReadiness {
            return L10n.text("正在读取关键位置，稍后显示当前状态。", "Reading key locations; current status will appear shortly.")
        }
        if permissionSummary.isFullDiskAccessVerified {
            if permissionSummary.blockedCount == 0 {
                return L10n.text("完整磁盘访问已覆盖关键位置，无需重复授权文件夹。", "Full Disk Access covers key locations; no duplicate folder authorization is needed.")
            }
            return L10n.text(
                "\(permissionSummary.blockedCount) 个位置仍未读取，通常重启本应用或重新检查即可，不需要重复授权。",
                "\(permissionSummary.blockedCount) location(s) still did not read; restart or check again instead of granting duplicate access."
            )
        }
        if let checkedAt = store.scanReadinessCheckedAt {
            return L10n.text(
                "当前检查于 \(checkedAt.formatted(date: .omitted, time: .shortened))，可读 \(permissionSummary.readableCount) 项，受限 \(permissionSummary.blockedCount) 项。",
                "Checked \(checkedAt.formatted(date: .omitted, time: .shortened)): \(permissionSummary.readableCount) readable, \(permissionSummary.blockedCount) blocked."
            )
        }
        return L10n.text(
            "正在使用上次扫描推断的权限状态，点击重新检查可读取当前状态。",
            "Showing access inferred from the last scan. Check again to read the current status."
        )
    }

    private var permissionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    permissionHeader
                    Spacer(minLength: 12)
                    globalPermissionActions
                }

                VStack(alignment: .leading, spacing: 12) {
                    permissionHeader
                    globalPermissionActions
                }
            }

            DisclosureGroup(isExpanded: $isPermissionListExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                        .padding(.bottom, 10)

                    Text(L10n.text("系统权限开关由 macOS 管理；这里显示各文件夹当前是否能实际读取。", "macOS manages system permission switches; this list shows whether each folder is currently readable."))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)

                    ForEach(Array(permissionSummary.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                        }
                        PermissionRequirementRow(
                            title: item.location.title,
                            detail: item.location.path,
                            statusTitle: permissionStatusTitle(item),
                            systemImage: item.location.systemImage,
                            statusSystemImage: permissionStatusSystemImage(item),
                            tint: permissionStatusTint(item)
                        )
                    }
                }
                .padding(.top, 10)
            } label: {
                Label(L10n.text("打开权限列表", "Open Permission List"), systemImage: "list.bullet.rectangle")
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
            }
            .animation(reduceMotion ? nil : AppMotionTokens.stateChange, value: isPermissionListExpanded)
        }
        .padding(16)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: permissionTint,
            elevated: permissionSummary.folderAuthorizationRequiredCount > 0 || store.isCheckingScanReadiness,
            prominence: permissionSummary.folderAuthorizationRequiredCount > 0 ? .regular : .quiet
        )
    }

    private var permissionHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: permissionSummary.level == .ready ? "checkmark.shield.fill" : "lock.shield.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.title2.weight(.semibold))
                .foregroundStyle(permissionTint)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("权限", "Permissions"))
                    .font(AppDesignTokens.Typography.sectionTitle)
                Text(permissionTitle)
                    .font(AppDesignTokens.Typography.inlineTitle)
                Text(permissionDetail)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .layoutPriority(1)
    }

    private var globalPermissionActions: some View {
        HStack(spacing: 8) {
            Button {
                store.refreshScanReadiness()
            } label: {
                Label(
                    store.isCheckingScanReadiness ? L10n.text("检查中", "Checking") : L10n.text("重新检查", "Check Again"),
                    systemImage: store.isCheckingScanReadiness ? "arrow.clockwise" : "checklist"
                )
            }
            .appButtonChrome(.primary)
            .controlSize(.regular)
            .tint(permissionTint)
            .disabled(store.isCheckingScanReadiness)

            if shouldOfferFolderAccessGrant {
                Button {
                    store.requestRequiredFolderAccess()
                } label: {
                    Label(L10n.text("授权文件夹", "Allow Folders"), systemImage: "folder.badge.plus")
                }
                .appButtonChrome(.secondary)
                .controlSize(.regular)
            }

            Menu {
                Button {
                    CleanupService.openFullDiskAccessSettings()
                } label: {
                    Label(L10n.text("完整磁盘访问", "Full Disk Access"), systemImage: "externaldrive")
                }

                Button {
                    CleanupService.openFilesAndFoldersSettings()
                } label: {
                    Label(L10n.text("文件与文件夹", "Files & Folders"), systemImage: "folder")
                }
            } label: {
                Label(L10n.text("系统设置", "System Settings"), systemImage: "gearshape")
            }
            .controlSize(.regular)
        }
    }

    private var shouldOfferFolderAccessGrant: Bool {
        !permissionSummary.isFullDiskAccessVerified
    }

    private func permissionStatusTitle(_ item: ScanReadinessItem) -> String {
        let hasSavedAccess = FolderAccessGrantService.hasSavedAccess(for: item.location.path)
        switch item.status {
        case .readable:
            if hasSavedAccess {
                return L10n.text("已保存授权", "Saved Access")
            }
            if permissionSummary.isFullDiskAccessVerified {
                return L10n.text("完整磁盘访问覆盖", "Covered by Full Disk Access")
            }
            return L10n.text("可读", "Readable")
        case .needsPermission:
            if permissionSummary.isFullDiskAccessVerified {
                return L10n.text("无需重复授权", "No Duplicate Grant Needed")
            }
            if hasSavedAccess {
                return L10n.text("授权需重选", "Rechoose Access")
            }
            return L10n.text("需要授权", "Needs Access")
        case .missing:
            return L10n.text("不存在", "Missing")
        }
    }

    private func permissionStatusSystemImage(_ item: ScanReadinessItem) -> String {
        if permissionSummary.isFullDiskAccessVerified, item.status != .missing {
            return item.status == .readable ? "checkmark.shield.fill" : "arrow.clockwise"
        }
        switch item.status {
        case .readable:
            return "checkmark"
        case .needsPermission:
            return "lock.fill"
        case .missing:
            return "minus"
        }
    }

    private func permissionStatusTint(_ item: ScanReadinessItem) -> Color {
        if permissionSummary.isFullDiskAccessVerified, item.status != .missing {
            return item.status == .readable ? AppDesignTokens.Palette.success : AppDesignTokens.Palette.information
        }
        switch item.status {
        case .readable:
            return AppDesignTokens.Palette.success
        case .needsPermission:
            return AppDesignTokens.Palette.warning
        case .missing:
            return .secondary
        }
    }

    private var systemStatusSection: some View {
        HStack(alignment: .center, spacing: 14) {
            ArtworkIconTile(
                systemImage: "waveform.path.ecg.rectangle",
                filter: nil,
                tint: scoreTint,
                size: 50,
                glyphSize: 31,
                showsGlass: true,
                showsGlow: true
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(statusHeadline)
                    .font(AppDesignTokens.Typography.sectionTitle)
                Text(primaryScoreFactor.map {
                    L10n.text("主要影响：\($0.title) · -\($0.penalty)", "Main factor: \($0.title) · -\($0.penalty)")
                } ?? statusDetail)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                MetadataPill(
                    text: "\(smartScore)/100",
                    systemImage: "gauge.with.dots.needle.67percent",
                    tint: scoreTint
                )
                Text(L10n.text("总扣 \(scoreBreakdown.totalPenalty) 分", "\(scoreBreakdown.totalPenalty) deducted"))
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: scoreTint, prominence: .quiet)
    }

    private var moduleSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 12)], spacing: 12) {
            CompactModuleCard(
                title: L10n.text("清理", "Cleanup"),
                value: ByteFormat.string(result.greenBytes),
                systemImage: "sparkles",
                filter: .green,
                tint: AppDesignTokens.Palette.success
            ) {
                selection = .green
            }

            CompactModuleCard(
                title: L10n.text("内存", "Memory"),
                value: store.memorySnapshot.map {
                    $0.reportablePressureLevel?.title ?? L10n.text("不可用", "Unavailable")
                } ?? L10n.text("打开刷新", "Open to refresh"),
                systemImage: "gauge.with.dots.needle.67percent",
                filter: .memory,
                tint: AppDesignTokens.Palette.information
            ) {
                selection = .memory
            }

            CompactModuleCard(
                title: L10n.text("应用", "Apps"),
                value: store.installedApps.isEmpty
                    ? L10n.text("打开查看", "Open to review")
                    : L10n.items(store.installedApps.count),
                systemImage: "app.fill",
                filter: .uninstall,
                tint: AppDesignTokens.Palette.sensitive
            ) {
                selection = .uninstall
            }

            CompactModuleCard(
                title: L10n.text("文件", "Files"),
                value: store.largeFilesWorkspace.storageAnalysis.map {
                    ByteFormat.string($0.rootSnapshot.measuredBytes)
                } ?? L10n.text("尚未分析", "Not analyzed"),
                systemImage: "doc.text.fill",
                filter: .largeFiles,
                tint: AppDesignTokens.Palette.storage
            ) {
                selection = .largeFiles
            }
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                MetricCard(title: L10n.text("总容量", "Capacity"), value: ByteFormat.string(result.system.diskTotalBytes), detail: result.system.diskName, systemImage: "internaldrive", tint: AppDesignTokens.Palette.tertiary)
                MetricCard(title: L10n.text("已使用", "Used"), value: ByteFormat.string(result.system.diskUsedBytes), detail: ByteFormat.percent(result.system.diskUsedBytes, of: result.system.diskTotalBytes), systemImage: "chart.pie", tint: AppDesignTokens.Palette.secondary)
                MetricCard(title: L10n.text("可用", "Available"), value: ByteFormat.string(result.system.diskFreeBytes), detail: ByteFormat.percent(result.system.diskFreeBytes, of: result.system.diskTotalBytes), systemImage: "checkmark.circle", tint: AppDesignTokens.Palette.success)
            }

            DiskSegmentBar(result: result)
                .glassPanel(cornerRadius: AppDesignTokens.Layout.rowRadius, tint: AppDesignTokens.Palette.information, prominence: .quiet)

            HStack(spacing: 14) {
                LegendDot(title: StorageTier.green.title, color: StorageTier.green.color)
                LegendDot(title: StorageTier.yellow.title, color: StorageTier.yellow.color)
                LegendDot(title: StorageTier.red.title, color: StorageTier.red.color)
                LegendDot(title: StorageTier.other.title, color: StorageTier.other.color)
                LegendDot(title: L10n.text("可用空间", "Free Space"), color: .secondary.opacity(0.35))
            }
            .font(AppDesignTokens.Typography.compactLabel)
            .foregroundStyle(.secondary)
        }
    }

    private var tierSection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            TierSummaryCard(tier: .green, bytes: result.greenBytes, count: result.items(forTier: .green).count) {
                store.showCleanupReview(scope: .cleanable)
                selection = .green
            }
            TierSummaryCard(tier: .yellow, bytes: result.yellowBytes, count: result.items(forTier: .yellow).count) {
                store.showCleanupReview(scope: .needsReview)
                selection = .green
            }
            TierSummaryCard(tier: .red, bytes: result.redBytes, count: result.items(forTier: .red).count) {
                store.showCleanupReview(scope: .careful)
                selection = .green
            }
        }
    }

    private var topItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("占用排行 Top 5", "Top 5 by Size"))
                .font(AppDesignTokens.Typography.sectionTitle)

            VStack(spacing: 0) {
                ForEach(result.topItems) { item in
                    TopItemRow(item: item) {
                        let destination = filter(for: item)
                        if destination == .green {
                            store.showCleanupReview(scope: scope(for: item), selectedItemID: item.id)
                        } else {
                            store.selectedItemID = item.id
                        }
                        selection = destination
                    }
                    if item.id != result.topItems.last?.id {
                        Divider()
                    }
                }
            }
            .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, prominence: .quiet)
        }
    }

    private func filter(for item: StorageItem) -> ReviewFilter {
        switch item.sourceID {
        case "dev_caches", "codex_intermediates", "codex_runtime_records", "codex_installers":
            .devCaches
        case "large_files", "mail_attachments", "downloads":
            .largeFiles
        case "duplicate_files":
            .duplicates
        default:
            .green
        }
    }

    private func scope(for item: StorageItem) -> ItemScopeFilter {
        if item.status == .movedToTrash {
            return .removed
        }
        switch item.tier {
        case .green:
            return .cleanable
        case .yellow:
            return .needsReview
        case .red:
            return .careful
        case .other:
            return .all
        }
    }
}

private struct PermissionRequirementRow: View {
    let title: String
    let detail: String
    let statusTitle: String
    let systemImage: String
    let statusSystemImage: String
    let tint: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                content
                Spacer(minLength: 10)
                statusBadge
            }

            VStack(alignment: .leading, spacing: 10) {
                content
                statusBadge
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .layoutPriority(1)
    }

    private var statusBadge: some View {
        Label(statusTitle, systemImage: statusSystemImage)
            .font(AppDesignTokens.Typography.metadata)
            .fontWeight(.medium)
            .foregroundStyle(tint)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ArtworkIconTile(
                systemImage: systemImage,
                filter: nil,
                tint: tint,
                size: 44,
                glyphSize: 28,
                showsGlass: true
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(tint)
                Text(value)
                    .font(AppDesignTokens.Typography.metricValue)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minHeight: 96)
        .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: tint, prominence: .quiet)
    }
}

private struct TierSummaryCard: View {
    let tier: StorageTier
    let bytes: Int64
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ArtworkIconTile(
                        systemImage: tier.systemImage,
                        filter: nil,
                        tint: tier.color,
                        size: 48,
                        glyphSize: 30,
                        showsGlass: true
                    )
                    Text(tier.title)
                        .font(AppDesignTokens.Typography.inlineTitle)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppDesignTokens.Typography.compactLabel)
                        .foregroundStyle(.tertiary)
                }

                Text(ByteFormat.string(bytes))
                    .font(AppDesignTokens.Typography.metricValue)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.countTierDetail(count: count, detail: tier.detail))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(minHeight: 134)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius, tint: tier.color, prominence: .quiet)
        }
        .buttonStyle(ResponsivePlainButtonStyle())
    }
}

private struct SmartCareResultTaskTile: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let isReady: Bool
    var isActionable = true
    let actionTitle: String
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        Group {
            if isActionable {
                Button(action: action) {
                    tileContent
                }
                .buttonStyle(ResponsivePlainButtonStyle())
            } else {
                tileContent
            }
        }
    }

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Text(title)
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Group {
                    if showsSuccessStatus {
                        Label(statusTitle, systemImage: "checkmark")
                    } else {
                        Text(statusTitle)
                    }
                }
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(showsSuccessStatus ? tint : Color.secondary)
            }

            Text(value)
                .font(AppDesignTokens.Typography.metricValue)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(detail)
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if isActionable {
                    HStack(spacing: 5) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right")
                            .font(AppDesignTokens.Typography.microSymbol)
                    }
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .foregroundStyle(tint)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: tint,
            elevated: false,
            prominence: .quiet
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(statusTitle)")
        .accessibilityHint(isActionable ? "\(detail) · \(actionTitle)" : detail)
    }

    private var showsSuccessStatus: Bool {
        isReady || !isActionable
    }

    private var statusTitle: String {
        if !isActionable {
            return L10n.text("无需处理", "No Action Needed")
        }
        return isReady
            ? L10n.text("已就绪", "Ready")
            : L10n.text("待处理", "Pending")
    }
}

private struct CompactModuleCard: View {
    let title: String
    let value: String
    let systemImage: String
    var filter: ReviewFilter? = nil
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CardArtworkIcon(systemImage: systemImage, filter: filter, tint: tint, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppDesignTokens.Typography.inlineTitle)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(value)
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .glassPanel(cornerRadius: AppDesignTokens.Radius.settingsPanel, tint: tint, prominence: .quiet)
        }
        .buttonStyle(ResponsivePlainButtonStyle())
    }
}

private struct CardArtworkIcon: View {
    let systemImage: String
    let filter: ReviewFilter?
    let tint: Color
    let size: CGFloat

    var body: some View {
        Group {
            if let filter {
                ArtworkIconTile(
                    systemImage: systemImage,
                    filter: filter,
                    tint: tint,
                    size: size,
                    glyphSize: size * 0.9,
                    showsGlass: false,
                    showsGlow: true
                )
            } else {
                ArtworkIconTile(
                    systemImage: systemImage,
                    filter: nil,
                    tint: tint,
                    size: size,
                    glyphSize: size * 0.62,
                    showsGlass: true,
                    showsGlow: true
                )
            }
        }
        .frame(width: size, height: size)
    }
}

private struct DiskSegmentBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedScale: CGFloat = 0
    let result: ScanResult

    private var segments: [(String, Int64, Color)] {
        [
            ("green", result.greenBytes, StorageTier.green.color),
            ("yellow", result.yellowBytes, StorageTier.yellow.color),
            ("red", result.redBytes, StorageTier.red.color),
            ("other", result.otherUsedBytes, StorageTier.other.color),
            ("free", result.system.diskFreeBytes, .secondary.opacity(0.35))
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments, id: \.0) { segment in
                    if segment.1 > 0 {
                        Rectangle()
                            .fill(segment.2)
                            .frame(width: max(2, geometry.size.width * CGFloat(Double(segment.1) / Double(max(1, result.system.diskTotalBytes))) * renderedScale))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(height: 14)
        .task(id: result.generatedAt) {
            guard AppMotionPolicy.shouldAnimate(reduceMotion: reduceMotion) else {
                renderedScale = 1
                return
            }

            renderedScale = 0
            await Task.yield()
            withAnimation(AppMotionTokens.progress) {
                renderedScale = 1
            }
        }
    }
}

private struct LegendDot: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TopItemRow: View {
    let item: StorageItem
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                ArtworkIconTile(
                    systemImage: item.tier.systemImage,
                    filter: nil,
                    tint: item.tier.color,
                    size: 46,
                    glyphSize: 29,
                    showsGlass: true
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(AppDesignTokens.Typography.inlineTitle)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.path)
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(ByteFormat.string(item.sizeBytes))
                    .font(AppDesignTokens.Typography.body)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .contentShape(Rectangle())
    }
}
