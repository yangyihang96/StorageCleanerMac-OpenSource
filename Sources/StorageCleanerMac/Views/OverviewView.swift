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
    @ObservedObject private var duplicateFilesWorkspace: DuplicateFilesStore
    @Binding var selection: ReviewFilter
    @State private var isPermissionListExpanded = true
    private let scoreBreakdown: SmartScoreBreakdown
    private let cleanupProjection: CleanupScoreProjection

    init(result: ScanResult, store: ScanStore, selection: Binding<ReviewFilter>) {
        self.result = result
        self.store = store
        _duplicateFilesWorkspace = ObservedObject(wrappedValue: store.duplicateFilesWorkspace)
        _selection = selection

        let projection = ScanHistoryService.cleanupProjection(for: result)
        scoreBreakdown = ScanHistoryService.scoreBreakdown(for: result, referenceDate: Date())
        cleanupProjection = projection
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
                    Text(L10n.text("导出报告", "Export Report"))
                }
                .disabled(!store.canExportCurrentScanArtifacts)

                if scanCoverageSummary.level != .complete,
                   !store.shouldShowPermissionPanelInMainInterface {
                    Divider()

                    Button {
                        CleanupService.openFullDiskAccessSettings()
                    } label: {
                        Text(L10n.text("完整磁盘访问", "Full Disk Access"))
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

            Text(L10n.scanSeconds(result.scanSeconds))
            .font(AppDesignTokens.Typography.body)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)

            if cleanupProjection.hasCleanableItems {
                Text(L10n.text(
                        "建议选择 \(ByteFormat.string(cleanupProjection.cleanableBytes)) · \(cleanupProjection.cleanableCount) 项",
                        "\(ByteFormat.string(cleanupProjection.cleanableBytes)) recommended · \(L10n.items(cleanupProjection.cleanableCount))"
                    ))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(AppDesignTokens.Palette.success)
                .monospacedDigit()
            }

            Button {
                performResultPrimaryAction()
            } label: {
                Text(resultPrimaryActionTitle)
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
                        "已索引 \($0.inspectedItemCount) 项",
                        "\($0.inspectedItemCount) items indexed"
                    )
                } ?? "",
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

            SmartCareResultTaskTile(
                title: L10n.text("相似照片", "Similar Photos"),
                value: duplicateFilesWorkspace.hasScanned
                    ? L10n.text("\(similarImageGroupCount) 组候选", "\(similarImageGroupCount) candidate groups")
                    : L10n.text("尚未扫描", "Not Scanned"),
                detail: "",
                systemImage: "photo.on.rectangle.angled",
                tint: AppDesignTokens.Palette.StorageCategory.image,
                isReady: similarImageGroupCount > 0,
                actionTitle: duplicateFilesWorkspace.hasScanned
                    ? L10n.text("查看", "Review")
                    : L10n.text("扫描", "Scan")
            ) {
                duplicateFilesWorkspace.resultFilter = .similarImage
                selection = .duplicates
            }
        }
    }

    private var similarImageGroupCount: Int {
        Set(duplicateFilesWorkspace.items.compactMap { item in
            item.duplicateMatchKind == DuplicateFileCandidateGroup.Rule.similarImage.rawValue
                ? item.duplicateGroupID : nil
        }).count
    }

    private var developerCacheItems: [StorageItem] {
        result.items(for: .devCaches)
    }

    private var developerCacheBytes: Int64 {
        developerCacheItems.reduce(0) { $0 + $1.sizeBytes }
    }

    private var duplicateItems: [StorageItem] {
        let workspaceItems = duplicateFilesWorkspace.items
        if duplicateFilesWorkspace.hasScanned || duplicateFilesWorkspace.isScanning || !workspaceItems.isEmpty {
            return workspaceItems
        }
        return result.items(for: .duplicates)
    }

    private var duplicateTileValue: String {
        guard !duplicateItems.isEmpty else {
            return duplicateFilesWorkspace.hasScanned
                ? L10n.text("无重复文件", "No Duplicates")
                : L10n.text("尚未扫描", "Not Scanned")
        }
        return ByteFormat.string(duplicateItems.reduce(0) { $0 + $1.sizeBytes })
    }

    private var duplicateTileDetail: String {
        guard !duplicateItems.isEmpty else {
            return duplicateFilesWorkspace.hasScanned
                ? L10n.text("没有重复候选", "No duplicate candidates")
                : ""
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

    private var resultPrimaryActionTitle: String {
        switch resultActionPolicy.action {
        case .reviewAndClean:
            L10n.text("选择清理项目", "Choose Cleanup Items")
        case .scanAgain:
            L10n.text("重新扫描", "Scan Again")
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

    private var scanCoverageSummary: ScanCoverageSummary {
        ScanCoverageService.summary(deniedPaths: result.deniedPaths)
    }

    private var smartScore: Int {
        scoreBreakdown.score
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

                    ForEach(Array(permissionSummary.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                        }
                        PermissionRequirementRow(
                            title: item.location.title,
                            detail: item.location.path,
                            statusTitle: permissionStatusTitle(item),
                            tint: permissionStatusTint(item)
                        )
                    }
                }
                .padding(.top, 10)
            } label: {
                Text(L10n.text("打开权限列表", "Open Permission List"))
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

            VStack(alignment: .leading, spacing: 6) {
                Text(permissionTitle)
                    .font(AppDesignTokens.Typography.inlineTitle)
            }
        }
        .layoutPriority(1)
    }

    private var globalPermissionActions: some View {
        HStack(spacing: 8) {
            Button {
                store.refreshScanReadiness()
            } label: {
                Text(store.isCheckingScanReadiness ? L10n.text("检查中", "Checking") : L10n.text("重新检查", "Check Again"))
            }
            .appButtonChrome(.primary)
            .controlSize(.regular)
            .tint(permissionTint)
            .disabled(store.isCheckingScanReadiness)

            if shouldOfferFolderAccessGrant {
                Button {
                    store.requestRequiredFolderAccess()
                } label: {
                    Text(L10n.text("授权文件夹", "Allow Folders"))
                }
                .appButtonChrome(.secondary)
                .controlSize(.regular)
            }

            Menu {
                Button {
                    CleanupService.openFullDiskAccessSettings()
                } label: {
                    Text(L10n.text("完整磁盘访问", "Full Disk Access"))
                }

                Button {
                    CleanupService.openFilesAndFoldersSettings()
                } label: {
                    Text(L10n.text("文件与文件夹", "Files & Folders"))
                }
            } label: {
                Text(L10n.text("系统设置", "System Settings"))
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
        Text(statusTitle)
            .font(AppDesignTokens.Typography.metadata)
            .fontWeight(.medium)
            .foregroundStyle(tint)
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
                        size: 28,
                        glyphSize: 18,
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

                Text(L10n.items(count))
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
                if isActionable {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Text(statusTitle)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(showsSuccessStatus ? tint : Color.secondary)
            }

            Text(value)
                .font(AppDesignTokens.Typography.metricValue)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if !detail.isEmpty {
                    Text(detail)
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
