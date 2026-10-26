import SwiftUI

struct CleanupScanOverviewView: View {
    @Environment(\.careStudioClassicResults) private var usesClassicResults
    @ObservedObject var store: ScanStore
    let session: ScanSession

    var body: some View {
        Group {
            // D141: the studio results show health-only scans too; the
            // classic list keeps its own health page.
            if session.smartScanScopes == [.health], usesClassicResults {
                SmartScanPageShell(alignsWithFeatureFlow: true) {
                    AppPageHeader(title: ReviewFilter.overview.title, isHero: true, role: .landing) {
                        Button { store.rescanAfterV2Cleanup() } label: {
                            Label(L10n.text("重新扫描", "Scan Again"), systemImage: "arrow.clockwise")
                        }
                    }
                } content: {
                    ScrollView { SmartScanHealthResultsView(snapshot: session.smartScanHealthSnapshot, status: session.smartScanHealthStatus).padding(.vertical, 16) }
                } footer: {
                    StatusFooter(status: session.outcome == .cancelled
                        ? .idle(L10n.text("扫描已取消", "Scan cancelled"))
                        : session.smartScanHealthSnapshot == nil
                            ? .failed(session.smartScanHealthStatus?.title ?? L10n.text("健康信息不可用", "Health information unavailable"))
                            : .completed(L10n.text("健康检查完成", "Health check completed")),
                        trustText: L10n.text("只读检查 · 不会更改系统设置", "Read-only check · System settings stay unchanged"),
                        isIntegrated: true)
                }
            } else {
                CleanupScanResultsView(store: store, filter: .overview, session: session)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

struct CleanupScanResultsView: View {
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.pageLayout) private var pageLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    @AppSurfaces private var surfaces
    @ObservedObject var store: ScanStore
    let filter: ReviewFilter
    let session: ScanSession
    @State private var resultFilter: CleanupResultFilter = .all
    @State private var sortOrder: CleanupResultSort = .largest
    @State private var isSecondaryDetailsExpanded = false
    @State private var expandedRiskTierIDs: Set<String> = []
    @State private var expandedLightfieldSubcategoryIDs: Set<String> = []
    /// The list has scrolled under the fixed header (shows the hairline).
    @State private var isListScrolled = false
    @Environment(\.careStudioClassicResults) private var usesClassicResults
    /// D141: the classic list opened from the studio review panel.
    @State private var showsClassicList = false

    private var categories: [CleanupScanCategory] {
        filter == .devCaches
            ? session.categories.filter { $0.id == "developer" }
            : session.categories
    }

    private var candidates: [ScanCandidate] { categories.flatMap(\.candidates) }

    /// D23: emptying the Trash is listed and counted on its own, apart from
    /// the green, yellow and red items that move to Trash.
    private var trashCandidates: [ScanCandidate] {
        candidates.filter { $0.action.permanentlyDeletes && $0.isSelectable }
    }

    /// D19: the risk cards and tiers only count items that can be selected and
    /// moved to Trash. The scanner no longer lists anything else. The scan
    /// history counts with the same definition (BOARD N20).
    private var tierTotals: CleanupScanTierTotals {
        CleanupScanTierTotals(categories: categories)
    }

    private var tierCandidates: [ScanCandidate] {
        tierTotals.all
    }

    private var safeCandidates: [ScanCandidate] {
        tierTotals.safe
    }

    private var reviewCandidates: [ScanCandidate] {
        tierTotals.review
    }

    private var protectedCandidates: [ScanCandidate] {
        tierTotals.protected
    }

    /// Groups on the three tiers; the Trash group has its own section.
    private var tierSubcategories: [CleanupScanSubcategory] {
        categories.flatMap(\.subcategories).filter { subcategory in
            !subcategory.candidates.contains { $0.action.permanentlyDeletes }
        }
    }

    private func decisionCount(for risk: CleanupRisk) -> Int {
        selectableDecisionCount(for: risk)
    }

    private func selectedDecisionCount(for risk: CleanupRisk) -> Int {
        tierSubcategories.filter { subcategory in
            subcategory.risk == risk
                && !subcategory.selectableCandidateIDs.isEmpty
                && store.cleanupSelection.state(
                    for: subcategory.selectableCandidateIDs
                ) != .unchecked
        }.count
    }

    private func selectableDecisionCount(for risk: CleanupRisk) -> Int {
        tierSubcategories.filter { subcategory in
            subcategory.risk == risk
                && !subcategory.selectableCandidateIDs.isEmpty
        }.count
    }

    private var safeBytes: Int64 {
        tierTotals.safeBytes
    }

    private var reviewBytes: Int64 {
        tierTotals.reviewBytes
    }

    private var protectedBytes: Int64 {
        tierTotals.protectedBytes
    }

    private var trashCandidateIDs: [ScanCandidateID] {
        trashCandidates.map(\.id)
    }

    private var isTrashSelected: Bool {
        trashCandidates.contains {
            store.cleanupSelection.selectedCandidateIDs.contains($0.id)
        }
    }

    /// Only pages that list the Trash item explain why it is missing.
    private var trashPermissionDenied: Bool {
        filter != .devCaches && session.permissions.contains {
            $0.ruleID == CleanupCoverageCatalog.userTrashRule.id
                && $0.status == .permissionDenied
        }
    }

    private var selectedBytes: Int64 {
        let candidateIDs = Set(categories.flatMap(\.selectableCandidateIDs))
        return store.cleanupSelection.selectedCandidates(in: session)
            .filter { candidateIDs.contains($0.id) }
            .reduce(0) { CleanupByteCount.adding($1.estimatedSizeBytes, to: $0) }
    }

    /// D100 G1: what the selection frees once the Trash is emptied; review
    /// A-R2: full clones are matched across the selected items.
    private var selectedReclaimable: CleanupSelectionReclaimable {
        let candidateIDs = Set(categories.flatMap(\.selectableCandidateIDs))
        return CleanupSelectionReclaimable(candidates: store.cleanupSelection.selectedCandidates(in: session)
            .filter { candidateIDs.contains($0.id) })
    }

    private var selectionQuitNotice: String? {
        let candidateIDs = Set(categories.flatMap(\.selectableCandidateIDs))
        return OperationQuitNotice.text(forSelected: store.cleanupSelection.selectedCandidates(in: session)
            .filter { candidateIDs.contains($0.id) })
    }

    private var recommendedCount: Int {
        candidates.filter(\.isRecommendedForSelection).count
    }

    private var safeSelectableCount: Int {
        safeCandidates.count
    }

    /// Rows that can be checked on this page (the confirmation sheet counts
    /// rows too, so the two numbers agree).
    private var selectableLeafCount: Int {
        selectionScopeIDs.count
    }

    private var selectedLeafCount: Int {
        let candidateIDs = Set(categories.flatMap(\.selectableCandidateIDs))
        return store.cleanupSelection.selectedCandidates(in: session)
            .filter { candidateIDs.contains($0.id) }
            .count
    }

    private var decisionItemCount: Int {
        [CleanupRisk.safe, .reviewOnly, .protected].reduce(0) {
            $0 + selectableDecisionCount(for: $1)
        } + (trashCandidates.isEmpty ? 0 : 1)
    }

    private var selectedCount: Int {
        [CleanupRisk.safe, .reviewOnly, .protected].reduce(0) {
            $0 + selectedDecisionCount(for: $1)
        } + (isTrashSelected ? 1 : 0)
    }

    private var selectionScopeIDs: Set<ScanCandidateID> {
        Set(categories.flatMap(\.selectableCandidateIDs))
    }

    private var selectedReviewCandidates: [ScanCandidate] {
        store.cleanupSelection.selectedCandidates(in: session).filter {
            selectionScopeIDs.contains($0.id) && $0.risk == .reviewOnly
        }
    }

    private var selectedProtectedCandidates: [ScanCandidate] {
        store.cleanupSelection.selectedCandidates(in: session).filter {
            selectionScopeIDs.contains($0.id)
                && $0.risk == .protected
                && !$0.action.permanentlyDeletes
        }
    }

    private var identifiedBytes: Int64 {
        CleanupByteCount.sum([safeBytes, reviewBytes, protectedBytes])
    }

    private var summaryGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: layout.cardSpacing),
            count: 3
        )
    }

    private var legendGridColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: layout.density == .compact ? 116 : 138),
            spacing: layout.cardSpacing,
            alignment: .leading
        )]
    }

    private var topCandidates: [ScanCandidate] {
        candidates.sorted {
            if $0.estimatedSizeBytes == $1.estimatedSizeBytes {
                return $0.snapshot.standardizedPath.localizedStandardCompare(
                    $1.snapshot.standardizedPath
                ) == .orderedAscending
            }
            return $0.estimatedSizeBytes > $1.estimatedSizeBytes
        }
        .prefix(5)
        .map { $0 }
    }

    private func displayedSubcategories(for risk: CleanupRisk) -> [CleanupScanSubcategory] {
        let matching = tierSubcategories.filter { subcategory in
            subcategory.risk == risk
                && subcategory.candidates.contains(where: matchesCurrentFilter)
        }
        switch sortOrder {
        case .largest:
            return matching.sorted {
                $0.discoveredBytes > $1.discoveredBytes
            }
        case .name:
            return matching.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .category:
            return matching.sorted {
                let leftCategory = $0.candidates.first?.categoryID ?? ""
                let rightCategory = $1.candidates.first?.categoryID ?? ""
                return leftCategory == rightCategory
                    ? $0.id < $1.id
                    : leftCategory < rightCategory
            }
        }
    }

    private func sortedCandidates(in subcategory: CleanupScanSubcategory) -> [ScanCandidate] {
        subcategory.candidates
            .filter(matchesCurrentFilter)
            .sorted { left, right in
                switch sortOrder {
                case .largest:
                    left.estimatedSizeBytes > right.estimatedSizeBytes
                case .name:
                    left.sourceURL.lastPathComponent.localizedStandardCompare(
                        right.sourceURL.lastPathComponent
                    ) == .orderedAscending
                case .category:
                    left.categoryTitle.localizedStandardCompare(
                        right.categoryTitle
                    ) == .orderedAscending
                }
            }
    }

    private func selectableCandidateIDs(for risk: CleanupRisk) -> Set<ScanCandidateID> {
        Set(tierCandidates.filter { $0.risk == risk }.map(\.id))
    }

    /// D141: the CleanMyMac-style results (tiles and the review panel) are
    /// the default; this tiered list stays as the classic list, opened from
    /// the review panel or forced with `careStudioClassicResults`.
    var body: some View {
        Group {
            if usesClassicResults || showsClassicList {
                classicBody
                    .overlay(alignment: .topTrailing) {
                        if showsClassicList && !usesClassicResults {
                            Button(L10n.text("返回卡片视图", "Back to Cards")) { showsClassicList = false }
                                .buttonStyle(.link)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.top, 14)
                                .padding(.trailing, 18)
                        }
                    }
            } else {
                CareStudioJunkResultsPage(
                    store: store,
                    module: CareStudioModule.junkFlow(route: filter),
                    filter: filter,
                    session: session,
                    onShowClassicList: { showsClassicList = true })
            }
        }
    }

    private var classicBody: some View {
        Group {
            if filter == .green { lightfieldResults } else { legacyResults }
        }
#if DEBUG
        // Review screenshots of the debug fixture open the green tier.
        .onAppear {
            if DebugSmartScanSessionFixture.expandsGreenTier {
                expandedRiskTierIDs.insert(CleanupRisk.safe.rawValue)
            }
        }
#endif
        // A2: row owners follow apps that open or quit after the scan; the
        // selection is not changed.
        .task(id: session.id) { await refreshOwnerRunningState() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didTerminateApplicationNotification
        )) { _ in
            Task { await refreshOwnerRunningState() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didLaunchApplicationNotification
        )) { _ in
            Task { await refreshOwnerRunningState() }
        }
        .confirmationDialog(
            L10n.text("正常退出这些应用？", "Quit These Apps Normally?"),
            isPresented: Binding(
                get: {
                    guard let request = store.cleanupOwnerQuitRequest else { return false }
                    return !request.isFromConfirmation
                },
                set: { if !$0 { store.cancelQuitCleanupOwners() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("正常退出并清理", "Quit Normally and Clean")) {
                store.quitOwnersAndRecheckCleanup()
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelQuitCleanupOwners()
            }
        } message: {
            Text(CleanupOwnerQuitPresentation.message(for: store.cleanupOwnerQuitRequest))
        }
    }

    private var legacyResults: some View {
        SmartScanPageShell(alignsWithFeatureFlow: filter == .overview) {
            resultHeader
                .padding(.bottom, AppDesignTokens.Spacing.small)
                .overlay(alignment: .bottom) {
                    FixedHeaderDivider(isVisible: isListScrolled)
                }
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: layout.sectionSpacing) {
                        // D45 / U3 (D53 V0): one-sentence conclusion, then the
                        // bento of risk cards and the largest categories.
                        if candidates.isEmpty {
                            // D58: nothing found is an all-clear state; the
                            // risk cards below still show their empty tiers.
                            StateArtPanel(
                                art: .stateAllClear,
                                fallbackSystemImage: "checkmark.seal.fill",
                                title: L10n.text("没有发现可清理的项目", "Nothing Found to Clean"),
                                detail: L10n.text(
                                    "本次只读扫描没有发现需要你处理的项目。",
                                    "This read-only scan found nothing that needs your attention."
                                ),
                                arrangement: .banner
                            )
                            .id(Self.topAnchorID)
                        } else {
                            conclusionHead
                                .id(Self.topAnchorID)
                        }
                        if session.smartScanScopes?.contains(.health) == true {
                            SmartScanHealthResultsView(snapshot: session.smartScanHealthSnapshot, status: session.smartScanHealthStatus)
                        }
                        riskSummary { risk in
                            tierScope(for: risk).perform(AppMotion.layout(reduceMotion: reduceMotion)) {
                                expandedRiskTierIDs.insert(risk.rawValue)
                                proxy.scrollTo(risk.rawValue, anchor: .top)
                            }
                        }
                        categoryBento { risk in
                            tierScope(for: risk).perform(AppMotion.layout(reduceMotion: reduceMotion)) {
                                expandedRiskTierIDs.insert(risk.rawValue)
                                proxy.scrollTo(risk.rawValue, anchor: .top)
                            }
                        }
                        if let outcomeNotice {
                            Button {
                                isSecondaryDetailsExpanded = true
                                proxy.scrollTo("scan-coverage-details", anchor: .top)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "exclamationmark.circle")
                                    Text(outcomeNotice)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                }
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(AppDesignTokens.Palette.warning)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassPanel(cornerRadius: AppDesignTokens.Layout.cardRadius,
                                    tint: AppDesignTokens.Palette.warning, prominence: .quiet)
                            }
                            .buttonStyle(ResponsivePlainButtonStyle())
                            .help(resultDetailedSummary)
                        }
                        if let notice = store.accessReturnNotice, notice.sessionID == session.id {
                            CleanupAccessReturnBanner(store: store, notice: notice)
                        }
                        if filter == .devCaches {
                            DeveloperCleanupThresholdControl(
                                store: store,
                                scannedThresholdDays:
                                    session.developerInactivityThresholdDays,
                                onRescan: store.startScanRespectingAccessGuide
                            )
                        }
                        selectionToolbar
                        tierSection(
                            risk: .safe,
                            title: L10n.text("绿色 · 可安全清理", "Green · Safe to Clean"),
                            detail: filter == .devCaches
                                ? L10n.text(
                                    "超过一年未修改的开发缓存与开发工具日志；默认全部勾选，所属应用正在运行的行除外，执行前仍会确认。",
                                    "Developer caches unchanged for over a year and developer tool logs. All are selected by default except rows whose app is running; still confirmed before cleanup."
                                )
                                : L10n.text(
                                    "可重新生成的缓存与日志；默认全部勾选，所属应用正在运行的行除外。最近仍有写入、未识别所属应用或体积较大的行会在行内注明；执行前仍会确认，文件移入废纸篓可恢复。",
                                    "Rebuildable caches and logs. All are selected by default except rows whose app is running; rows still being written, whose app is unknown, or that are large say so. Still confirmed before cleanup; files move to Trash and can be restored."
                                )
                        )
                        tierSection(
                            risk: .reviewOnly,
                            title: L10n.text("黄色 · 需要人工判断", "Yellow · Manual Review"),
                            detail: filter == .devCaches
                                ? L10n.text(
                                    "超过 \(session.developerInactivityThresholdDays) 天但未满一年未修改的可重新生成缓存；默认不选，可逐项选择，执行前需额外确认。",
                                    "Rebuildable caches unchanged for more than \(session.developerInactivityThresholdDays) days but under a year; off by default, selectable individually, with an extra confirmation before cleanup."
                                )
                                : L10n.text(
                                    "下载内容、邮件附件副本、CloudKit 缓存等需要你判断的项目；默认不选，可逐项选择，执行前需额外确认。",
                                    "Items that need your judgment, such as downloads, mail attachment copies, and the CloudKit cache; off by default, selectable individually, with an extra confirmation before cleanup."
                                )
                        )
                        tierSection(
                            risk: .protected,
                            title: L10n.text("红色 · 高风险", "Red · High Risk"),
                            detail: filter == .devCaches
                                ? L10n.text(
                                    "最近 \(session.developerInactivityThresholdDays) 天内有变动，或部分内容无法读取；默认不选，可按分组或逐项选择，执行前仍需双重确认。",
                                    "Changed within the last \(session.developerInactivityThresholdDays) days, or partly unreadable; off by default, selectable by group or item, and requires two confirmations before execution."
                                )
                                : L10n.text(
                                    "近期仍有活动的开发产物与重复的应用副本；默认不选，可按分组或逐项选择，执行前需要双重确认。重复应用整组勾选时自动保留一份。",
                                    "Recently active developer files and duplicate app copies; off by default, selectable by group or item, with two confirmations before execution. Checking a whole duplicate-app group keeps one copy."
                                )
                        )
                        trashSection
                        secondaryDetailsSection
                            .id("scan-coverage-details")
                    }
                    .padding(.top, 14)
                    .padding(.bottom, AppDesignTokens.Spacing.medium)
                }
                .scrollIndicators(.automatic)
                // Rows scrolling under the fixed header fade out instead of
                // showing through it (main session review of 06/06b).
                .scrollTopFade(height: 14)
                .reportsScrollOffset($isListScrolled)
#if DEBUG
                // Review screenshots open the green tier; start them at the
                // top of the page (the open tier must not scroll the list).
                .task {
                    guard DebugSmartScanSessionFixture.expandsGreenTier else { return }
                    for _ in 0..<3 {
                        try? await Task.sleep(for: .milliseconds(150))
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
#endif
            }
        } footer: {
            cleanupActionBar
        }
    }

    private var lightfieldResults: some View {
        let amount: FeatureLightfieldAmount = FeatureLightfieldAmount.parse(
            CleanupMeasurementPresentation.aggregateValue(tierCandidates)
        )
        let summaryLabel: String = resultHeaderSubtitle
            + (amount.qualifier.isEmpty ? "" : " · " + amount.qualifier)
        let safetyLine: String = isTrashSelected
            ? L10n.text("永久清空废纸篓 · 单独双重确认，不可恢复", "Empty Trash permanently · Separate double confirmation; not recoverable")
            : L10n.text("移到废纸篓 · 清理前逐项确认", "Move to Trash · Review before cleanup")
        let actionTitle: String = store.cleanupFeatureConfiguration.mode == .v2Full
            ? cleanupActionTitle : L10n.text("生成 Dry-run", "Create Dry Run")
        let actionEnabled: Bool = selectedBytes > 0 && session.outcome != .cancelled
            && (store.cleanupFeatureConfiguration.mode != .v2Full || store.canRequestV2Cleanup)
        return FeatureLightfieldPage(module: .green, phase: .result, title: filter.sidebarTitle,
            status: L10n.text(selectionActionSummaryChinese, selectionActionSummaryEnglish),
            safety: safetyLine, actionTitle: actionTitle, actionEnabled: actionEnabled,
            action: {
                if store.cleanupFeatureConfiguration.mode == .v2Full {
                    store.requestV2Cleanup(disposition: .trash, candidateIDs: selectionScopeIDs)
                } else { store.prepareCleanupDryRun(candidateIDs: selectionScopeIDs) }
            }) {
            FeatureLightfieldResults(module: .green,
                label: summaryLabel,
                value: amount.value, unit: amount.unit, precision: amount.precision) {
                lightfieldResultItems
            }
        }
#if DEBUG
        // Screenshot fixture flag only: opens the green groups to show item rows.
        .onAppear {
            if DebugSmartScanSessionFixture.expandsGreenTier {
                expandedLightfieldSubcategoryIDs = Set(displayedSubcategories(for: .safe).map(\.id))
            }
        }
#endif
    }

    @ViewBuilder
    private var lightfieldResultItems: some View {
        lightfieldResultToolbar
        if let outcomeNotice {
            Text(outcomeNotice).font(.system(size: 13))
                .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).warningColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let notice = store.accessReturnNotice, notice.sessionID == session.id {
            CleanupAccessReturnBanner(store: store, notice: notice)
        }
        // D93: a checked row whose app is running is named as soon as it is
        // checked, not only when the cleanup skips it.
        if let quitNotice = selectionQuitNotice {
            Text(quitNotice).font(.system(size: 13))
                .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).warningColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        lightfieldSubcategoryRows
        if let trash = trashCandidates.first,
           resultFilter == .all || (resultFilter == .selected && isTrashSelected) {
            let entryCount = trash.permanentDeletionEntries?.count ?? 0
            CleanupListDisclosure(title: L10n.text("清空废纸篓 · 永久删除", "Empty Trash · Permanent deletion"),
                                  probe: "lightfield.cleanup.trashDisclosure") {
                ForEach(trashCandidates) { candidate in
                    CleanupCandidateRow(store: store, session: session, candidate: candidate,
                        cleanupScopeIDs: selectionScopeIDs, usesLightfield: true)
                }
            }
            // D23 scope note (restored from V1): only what was already in the
            // Trash at scan time is deleted; this cleanup's moves are not.
            Text(L10n.text(
                "单独一项，默认不选。只永久删除扫描时废纸篓里已有的 \(ByteFormat.count(entryCount)) 项，本次移入废纸篓的文件不受影响；执行前单独二次确认。",
                "A separate item, off by default. It permanently deletes only the \(ByteFormat.count(entryCount)) item(s) already in the Trash during the scan; files this cleanup moves to Trash are not affected. Confirmed twice on its own."
            ))
            .font(.system(size: 13))
            .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
        } else if trashPermissionDenied, resultFilter == .all {
            // Restored V1 guidance: without Full Disk Access the Trash cannot
            // be read, so emptying it is unknown rather than “nothing”.
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("无法读取废纸篓", "Trash Cannot Be Read"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).warningColor)
                Text(L10n.text(
                    "没有读取废纸篓的权限，因此不知道其中是否有可清空的项目。请在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”中允许本应用，然后重新扫描。",
                    "This app cannot read the Trash, so it cannot tell whether anything can be emptied. Allow this app in System Settings › Privacy & Security › Full Disk Access, then scan again."
                ))
                .font(.system(size: 13))
                .foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg2)
                .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("打开系统设置", "Open System Settings")) {
                    _ = CleanupService.openFullDiskAccessSettings()
                }
                .buttonStyle(FeatureLightfieldRowButtonStyle())
                .foregroundStyle(FeatureLightfieldPalette.accent(.green))
            }
            .padding(.vertical, 8)
#if DEBUG
            .layoutProbe("lightfield.cleanup.trashDenied")
#endif
        }
        CleanupListDisclosure(title: L10n.text("扫描详情与权限", "Scan Details & Permissions"),
                              probe: "lightfield.cleanup.detailsDisclosure") {
            lightfieldScanDetails
        }
        if let summary = store.cleanupDryRunSummary, summary.sessionID == session.id {
            Text(L10n.text("已核对 \(ByteFormat.count(summary.selectedCount)) 项 · 文件系统改动：0", "\(ByteFormat.count(summary.selectedCount)) validated · File-system changes: 0"))
        }
    }

    private var lightfieldResultToolbar: some View {
        HStack(spacing: 12) {
            Button(L10n.text("重新扫描", "Scan Again"), action: store.startScanRespectingAccessGuide)
            Menu(L10n.text("选择", "Selection")) {
                Button(L10n.text("推荐项目", "Recommended"), action: store.selectRecommendedCleanupCandidates)
                Button(L10n.text("恢复默认", "Restore Defaults"), action: store.restoreDefaultCleanupSelection)
            }.disabled(!store.canEditV2CleanupSelection)
            Picker(L10n.text("筛选", "Filter"), selection: $resultFilter) {
                ForEach(CleanupResultFilter.allCases) { value in Text(value.title).tag(value) }
            }.pickerStyle(.menu)
            Picker(L10n.text("排序", "Sort"), selection: $sortOrder) {
                ForEach(CleanupResultSort.allCases) { value in Text(value.title).tag(value) }
            }.pickerStyle(.menu)
        }
        .font(.system(size: 13))
        .padding(.vertical, 6)
#if DEBUG
        .layoutProbe("lightfield.results.toolbar")
#endif
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(FeatureLightfieldRowButtonStyle())
    }

    private var lightfieldSubcategories: [CleanupScanSubcategory] {
        let risks: [CleanupRisk] = [.safe, .reviewOnly, .protected]
        return risks.flatMap { risk in displayedSubcategories(for: risk) }
    }

    private var lightfieldSubcategoryRows: some View {
        ForEach(Array(lightfieldSubcategories.enumerated()), id: \.element.id) { index, subcategory in
            lightfieldSubcategoryRow(subcategory)
                .lightfieldRowEntrance(index)
        }
    }

    private func lightfieldSubcategoryRow(_ subcategory: CleanupScanSubcategory) -> some View {
        let expanded: Bool = expandedLightfieldSubcategoryIDs.contains(subcategory.id)
        // D67 selection row: the check box stays in the first 20 pt column and
        // the disclosure moves to the row end, inside the row grid.
        return VStack(alignment: .leading, spacing: 0) {
            FeatureLightfieldResultRow(
                title: subcategory.title,
                detail: riskTitle(subcategory.risk) + " · " + riskCaption(for: subcategory.risk),
                value: CleanupMeasurementPresentation.aggregateValue(subcategory.candidates),
                status: lightfieldStatus(for: subcategory.risk),
                reservesTrailing: true
            ) {
                lightfieldSelectionButton(for: subcategory)
            } trailing: {
                Button {
                    withAnimation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.check, reduceMotion: reduceMotion)) {
                        if expanded { expandedLightfieldSubcategoryIDs.remove(subcategory.id) }
                        else { expandedLightfieldSubcategoryIDs.insert(subcategory.id) }
                    }
                } label: {
                    FeatureLightfieldDisclosureChevron(expanded: expanded)
                }
                .buttonStyle(FeatureLightfieldRowButtonStyle())
                .accessibilityLabel(L10n.text("\(subcategory.title) 的项目", "Items in \(subcategory.title)"))
                .accessibilityValue(expanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
            }
            .help(subcategory.reason)
            if expanded {
                ForEach(sortedCandidates(in: subcategory)) { candidate in
                    // Item rows sit one column in from their group's check box.
                    CleanupCandidateRow(store: store, session: session, candidate: candidate,
                        cleanupScopeIDs: selectionScopeIDs, usesLightfield: true)
                        .padding(.leading, FeatureLightfield.childRowIndent)
#if DEBUG
                        .layoutProbe("lightfield.cleanup.child.\(candidate.id.rawValue)")
#endif
                }
            }
        }
    }

    private func lightfieldStatus(for risk: CleanupRisk) -> FeatureLightfieldStatus {
        switch risk {
        case .safe: .normal
        case .protected: .failure
        case .reviewOnly, .informational: .warning
        }
    }

    private func lightfieldSelectionButton(for subcategory: CleanupScanSubcategory) -> some View {
        let ids: [ScanCandidateID] = subcategory.selectableCandidateIDs
        let state: TriStateSelection = store.cleanupSelection.groupState(for: ids, in: session)
        let isDisabled: Bool = !store.canEditV2CleanupSelection
            || session.outcome == .cancelled || ids.isEmpty
        return Button {
            store.setCleanupCandidates(ids, selected: state != .checked)
        } label: {
            FeatureLightfieldCheck(selected: state != .unchecked, module: .green,
                mixed: state == .mixed)
        }
        .buttonStyle(FeatureLightfieldRowButtonStyle())
        .accessibilityLabel(subcategory.title + " · " + riskSelectionSummary(risk: subcategory.risk))
        // Same spoken state and hint as the V1 tri-state control: VoiceOver
        // reads selected / partially selected / not selected.
        .accessibilityValue(state.cleanupAccessibilityValue)
        .accessibilityHint(isDisabled
            ? L10n.text("此分组没有可选择项目。", "This group has no selectable items.")
            : L10n.text("按空格切换此分组的选择状态。", "Press Space to toggle this group's selection."))
        .disabled(isDisabled)
#if DEBUG
        .layoutProbe("lightfield.cleanup.group." + subcategory.id)
#endif
    }

    /// Same scan measurements and advice as V1, in text rows without its cards.
    private var lightfieldScanDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let system = session.system, system.diskTotalBytes > 0 {
                Text(system.diskName)
                Text(L10n.text("总容量", "Total") + " · " + ByteFormat.storageString(system.diskTotalBytes))
                Text(L10n.text("已使用", "Used") + " · " + ByteFormat.storageString(system.diskUsedBytes))
                Text(L10n.text("可用空间", "Available") + " · " + ByteFormat.storageString(system.diskFreeBytes))
                Text(L10n.text("其余已用", "Other Used") + " · " + ByteFormat.storageString(max(0, system.diskUsedBytes - min(system.diskUsedBytes, identifiedBytes))))
            }
            ForEach([CleanupRisk.safe, .reviewOnly, .protected], id: \.rawValue) { risk in
                Text(riskTitle(risk) + " · " + riskValueText(risk) + " · " + riskCaption(for: risk))
            }
            Text(conclusionSentence)
            FeatureLightfieldHairline()
            Text(L10n.text("Top 5 空间占用", "Top 5 Space Users"))
            if topCandidates.isEmpty { Text(L10n.text("本次扫描没有达到显示阈值的项目。", "No item reached the display threshold.")) }
            ForEach(topCandidates) { candidate in
                Button { store.revealCleanupCandidate(candidate) } label: {
                    Text(candidate.sourceURL.lastPathComponent + " · " + CleanupMeasurementPresentation.aggregateValue([candidate]))
                }.buttonStyle(FeatureLightfieldRowButtonStyle())
            }
            Text(L10n.text("已读取范围", "Readable Scopes") + " · \(session.permissions.filter { $0.status == .readable }.count)/\(ByteFormat.count(session.permissions.count))")
            Text(session.metrics.ignoredSummary)
            Text(L10n.text("扫描耗时", "Duration") + " · " + String(format: "%.1fs", session.metrics.duration))
            Text(L10n.text("完整容量", "Complete Measurements") + " · \(ByteFormat.count(session.metrics.completeMeasurementCandidateCount))")
            Text(L10n.text("至少值 / 失败", "Lower Bounds / Failed") + " · \(ByteFormat.count(session.metrics.lowerBoundMeasurementCandidateCount)) / \(ByteFormat.count(session.metrics.failedMeasurementCandidateCount))")
            Text(L10n.text("目录 / 条目", "Directories / Entries") + " · \(ByteFormat.count(session.metrics.visitedDirectoryCount)) / \(ByteFormat.count(session.metrics.visitedEntryCount))")
            Text(L10n.text("权限失败 / 云文件 / 超时 / 未列出", "Permission Failures / Cloud / Timeouts / Not Listed") + " · \(ByteFormat.count(session.metrics.permissionFailureCount)) / \(ByteFormat.count(session.metrics.cloudSkippedCount)) / \(ByteFormat.count(session.metrics.timedOutRuleCount)) / \(ByteFormat.count(session.metrics.notActionableCandidateCount))")
            Text(L10n.text("候选截断", "Truncated Candidates") + " · \(ByteFormat.count(session.metrics.truncatedCandidateCount))")
            Text(L10n.text("先核对绿色，再逐项判断黄色；红色项目双重确认；永久清空废纸篓单独确认。", "Review green items first, then yellow individually; red items require two confirmations; emptying Trash requires separate confirmation."))
            Text(L10n.text("定期复查缓存和开发产物；系统内容交给 macOS 或原应用；个人文件先核对备份可恢复，再归档。", "Review caches and build artifacts periodically; let macOS or the owning app manage system content; verify a restorable backup before archiving personal files."))
        }.font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(colorScheme).fg2)
    }

    private static let topAnchorID = "cleanup-results-top"

    private var resultHeader: some View {
        AppPageHeader(
            title: filter.sidebarTitle,
            subtitle: resultHeaderSubtitle,
            systemImage: filter.systemImage,
            isHero: true,
            // Results are a list page: the regular header leaves the height
            // to the rows (D53 §2.3, review 5).
            role: .tool
        ) {
            Button {
                store.startScanRespectingAccessGuide()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .appButtonChrome(.secondary)
            .accessibilityLabel(L10n.text("重新扫描", "Scan Again"))
            .help(L10n.text("重新扫描", "Scan Again"))
        }
    }

    private var resultHeaderSubtitle: String { Self.resultHeaderSubtitle(for: session) }

    nonisolated static func resultHeaderSubtitle(for session: ScanSession) -> String {
        if session.outcome == .cancelled {
            return L10n.text("扫描已取消 · 保留已完成结果", "Scan cancelled · Completed results kept")
        }
        // D192 + D179: deliberate skips do not make the classic heading partial.
        return session.coverageLimits.isLimited
            ? L10n.text("扫描结束 · 部分结果可供审阅", "Scan finished · Partial results available")
            : L10n.text("扫描完成 · 请审阅结果", "Scan complete · Review results")
    }

    private var resultDetailedSummary: String {
        let trashSuffix = trashCandidates.isEmpty
            ? ""
            : L10n.text(
                "；废纸篓另有 \(CleanupMeasurementPresentation.aggregateValue(trashCandidates)) 可单独清空",
                "; the Trash holds another \(CleanupMeasurementPresentation.aggregateValue(trashCandidates)) that can be emptied separately"
            )
        let summary = L10n.text(
            "扫描完成：发现 \(ByteFormat.storageString(safeBytes)) 可安全清理，另有 \(CleanupMeasurementPresentation.aggregateValue(reviewCandidates)) 需要人工判断、\(CleanupMeasurementPresentation.aggregateValue(protectedCandidates)) 需双重确认\(trashSuffix)。",
            "Scan complete: \(ByteFormat.storageString(safeBytes)) is safe to clean, \(CleanupMeasurementPresentation.aggregateValue(reviewCandidates)) needs review, and \(CleanupMeasurementPresentation.aggregateValue(protectedCandidates)) needs two confirmations\(trashSuffix)."
        )
        guard let outcomeNotice else { return summary }
        return "\(summary) · \(outcomeNotice)"
    }

    private var selectionHeaderSummary: String {
        let summary = L10n.text(
            "已选择 \(ByteFormat.count(selectedCount)) 项 · \(ByteFormat.storageString(selectedBytes))",
            "\(ByteFormat.count(selectedCount)) selected · \(ByteFormat.storageString(selectedBytes))"
        )
        let reclaimable = selectedReclaimable
        guard let note = reclaimable.note(ofSelected: selectedBytes) else { return summary }
        return summary + " · " + note
    }

    /// Why some found items are not listed: cleanup skips anything that holds
    /// a path the user excluded, and rows holding the user's own data (such
    /// as IDE local history) are not junk. Both are counted, not listed.
    private var notListedReasonDetail: (chinese: String, english: String) {
        let excluded = session.metrics.excludedPathCandidateCount
        let protected = session.metrics.protectedDataCandidateCount
        var chinese = [String]()
        var english = [String]()
        if excluded > 0 {
            chinese.append("\(ByteFormat.count(excluded)) 项包含你排除的路径")
            english.append("\(ByteFormat.count(excluded)) contain a path you excluded")
        }
        if protected > 0 {
            chinese.append("\(ByteFormat.count(protected)) 项含本地历史记录等个人数据")
            english.append("\(ByteFormat.count(protected)) hold personal data such as local history")
        }
        guard !chinese.isEmpty else { return ("", "") }
        return (
            "；其中 " + chinese.joined(separator: "，"),
            "; of them, " + english.joined(separator: ", ")
        )
    }

    private var outcomeNotice: String? {
        switch session.outcome {
        case .complete:
            nil
        case .partial:
            if session.metrics.notActionableCandidateCount > 0 {
                L10n.text(
                    "部分范围已因安全边界跳过（\(ByteFormat.count(session.metrics.notActionableCandidateCount)) 项无法安全处理，未列出\(notListedReasonDetail.chinese)）",
                    "Some scopes were safely skipped (\(ByteFormat.count(session.metrics.notActionableCandidateCount)) items could not be handled safely and are not listed\(notListedReasonDetail.english))"
                )
            } else if session.metrics.timedOutRuleCount == 0,
                      session.metrics.permissionFailureCount == 0,
                      session.metrics.lowerBoundMeasurementCandidateCount > 0 {
                // D19: lower-bound items stay listed and selectable.
                L10n.text(
                    "部分项目的大小为“至少”：其中的符号链接未跟随，或有子目录无法读取",
                    "Some sizes are lower bounds: links inside were not followed, or a subfolder could not be read"
                )
            } else {
                L10n.text("部分范围已因安全边界跳过", "Some scopes were safely skipped")
            }
        case .cancelled:
            L10n.text("仅显示已完成的只读结果", "Only completed read-only results are shown")
        }
    }

    /// Three risk cards in one row when they fit. The count and selection
    /// line sits beside the value only where it fits whole; otherwise every
    /// card puts it on its own full-width line (review P2-7: it is never
    /// truncated or shrunk). Narrow windows wrap the cards to two columns.
    private func riskSummary(
        onSelect: @escaping (CleanupRisk) -> Void
    ) -> some View {
        let risks: [CleanupRisk] = [.safe, .reviewOnly, .protected]
        return ViewThatFits(in: .horizontal) {
            riskSummaryRow(risks: risks, captionBelow: false, onSelect: onSelect)
            riskSummaryRow(risks: risks, captionBelow: true, onSelect: onSelect)
            // Only three summaries: eager layout publishes every risk after
            // a short-window reflow, even when the last row needs scrolling.
            AdaptiveCardGrid(minimumColumnWidth: 260, maximumColumns: 3, spacing: layout.cardSpacing) {
                ForEach(risks, id: \.rawValue) { risk in
                    riskSummaryButton(risk: risk, captionBelow: true, action: { onSelect(risk) })
                }
            }
        }
    }

    private func riskSummaryRow(
        risks: [CleanupRisk],
        captionBelow: Bool,
        onSelect: @escaping (CleanupRisk) -> Void
    ) -> some View {
        HStack(spacing: layout.cardSpacing) {
            ForEach(Array(risks.enumerated()), id: \.element.rawValue) { index, risk in
                // Wide enough for "At least 32.75 GB" (about 253 pt) beside
                // the icon; narrower windows wrap to two columns instead of
                // truncating the value.
                riskSummaryButton(risk: risk, captionBelow: captionBelow, action: { onSelect(risk) })
                    .frame(minWidth: 260, maxHeight: .infinity)
                    .appStaggeredAppearance(index: index + 1)
            }
        }
        // The cards of a row share one height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func riskSummaryButton(
        risk: CleanupRisk,
        captionBelow: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let tint = CleanupRiskPresentation.tint(risk)
        let count = decisionCount(for: risk)
        let selection = riskSelectionSummary(risk: risk)
        let caption = Text(riskCaption(for: risk))
            .font(AppDesignTokens.TypeScale.caption)
            .foregroundStyle(surfaces.textTertiary)
            .monospacedDigit()
#if DEBUG
            .layoutProbe("results.riskCaption.\(risk.rawValue)")
#endif
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(tint.opacity(0.16))
                        Circle().strokeBorder(tint.opacity(0.45), lineWidth: 1)
                        Image(systemName: CleanupRiskPresentation.systemImage(risk))
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(riskTitle(risk))
                            .font(AppDesignTokens.TypeScale.secondaryEmphasis)
                            .foregroundStyle(surfaces.textSecondary)
                            .lineLimit(1)
                        Text(riskValueText(risk))
                            .font(AppDesignTokens.TypeScale.metricInline)
                            .foregroundStyle(surfaces.textPrimary)
                            .lineLimit(1)
                            .help(riskValueText(risk))
                            .appDataTransition(value: riskValueText(risk))
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        CleanupSuggestionChip(risk: risk)
                        if !captionBelow {
                            caption
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
                if captionBelow {
                    caption
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, maxHeight: .infinity, alignment: .leading)
            .background {
                SurfaceBackground(level: .card, cornerRadius: AppDesignTokens.Corner.card, tint: tint)
            }
            .overlay {
                if colorSchemeContrast == .increased {
                    RoundedRectangle(cornerRadius: AppDesignTokens.Corner.card, style: .continuous)
                        .stroke(tint.opacity(0.82), lineWidth: 2)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppDesignTokens.Corner.card, style: .continuous))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .appHoverLift(cornerRadius: AppDesignTokens.Corner.card, tint: tint)
#if DEBUG
        .layoutProbe(LayoutProbeID.cleanupRiskSummary(risk))
#endif
        .accessibilityLabel(L10n.text(
            "\(riskTitle(risk))，\(ByteFormat.count(count)) 项，\(riskValueText(risk))，\(selection)",
            "\(riskTitle(risk)), \(ByteFormat.count(count)) items, \(riskValueText(risk)), \(selection)"
        ))
        .accessibilityHint(L10n.text(
            "定位到此风险分组，不会改变选择。",
            "Moves to this risk group without changing selection."
        ))
    }

    /// D45 / U3: "可安全清理 12.4 GB" with the rest in one sentence, on one
    /// short line so the list starts on the first screen (review 5). The
    /// number counts up once (Reduce Motion: shown at once).
    private var conclusionHead: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                conclusionNumber
                Text(conclusionSentence)
                    .font(AppDesignTokens.TypeScale.body)
                    .foregroundStyle(surfaces.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(conclusionSentence)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                conclusionNumber
                Text(conclusionSentence)
                    .font(AppDesignTokens.TypeScale.secondary)
                    .foregroundStyle(surfaces.textSecondary)
                    .lineLimit(2)
                    .help(conclusionSentence)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .appStaggeredAppearance(index: 0)
#if DEBUG
        .layoutProbe("results.conclusion")
#endif
    }

    private var conclusionNumber: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.text("可安全清理", "Safe to clean"))
                .font(AppDesignTokens.TypeScale.sectionTitle)
                .foregroundStyle(surfaces.textSecondary)
            AnimatedByteCount(bytes: safeBytes)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(AppDesignTokens.Palette.success)
        }
        .fixedSize()
    }

    private var conclusionSentence: String {
        var chinese: [String] = []
        var english: [String] = []
        if !reviewCandidates.isEmpty {
            let value = CleanupMeasurementPresentation.aggregateValue(reviewCandidates)
            chinese.append("\(value) 需要你判断")
            english.append("\(value) needs your review")
        }
        if !protectedCandidates.isEmpty {
            let value = CleanupMeasurementPresentation.aggregateValue(protectedCandidates)
            chinese.append("\(value) 为高风险，需双重确认")
            english.append("\(value) is high risk and needs two confirmations")
        }
        if !trashCandidates.isEmpty {
            let value = CleanupMeasurementPresentation.aggregateValue(trashCandidates)
            chinese.append("废纸篓另有 \(value) 可单独清空")
            english.append("the Trash holds \(value) that can be emptied separately")
        }
        let lead = L10n.text(
            "已为你勾选所属应用未运行的绿色项目",
            "Green items whose apps are not running are selected for you"
        )
        guard !chinese.isEmpty else {
            return L10n.text("\(lead)；没有需要人工判断的项目。", "\(lead); nothing needs manual review.")
        }
        return L10n.text(
            "\(lead)；另有 " + chinese.joined(separator: "，") + "。",
            "\(lead); " + english.joined(separator: ", ") + "."
        )
    }

    /// The largest categories as bento cards (CleanMyMac / 柠檬 pattern);
    /// clicking one opens the tier that holds most of it.
    @ViewBuilder
    private func categoryBento(onSelect: @escaping (CleanupRisk) -> Void) -> some View {
        // Review 5: only wide and tall windows have room for the bento
        // before the list; otherwise the risk cards carry the summary.
        if let pageLayout, pageLayout.width >= .wide, pageLayout.height == .tall {
            categoryBentoGrid(onSelect: onSelect)
        }
    }

    private func categoryBentoGrid(onSelect: @escaping (CleanupRisk) -> Void) -> some View {
        let shown = Array(categories
            .filter { !$0.candidates.isEmpty }
            .sorted { $0.discoveredBytes > $1.discoveredBytes }
            .prefix(pageLayout?.width == .extraWide ? 8 : 4))
        return AdaptiveCardGrid(minimumColumnWidth: 180, maximumColumns: 4, spacing: layout.cardSpacing) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, category in
                CleanupCategoryBentoCard(category: category) {
                    onSelect(dominantRisk(of: category))
                }
                .appStaggeredAppearance(index: index + 4)
            }
        }
#if DEBUG
        .layoutProbe("results.bento")
#endif
    }

    private func dominantRisk(of category: CleanupScanCategory) -> CleanupRisk {
        let byRisk = Dictionary(grouping: category.candidates.filter { !$0.action.permanentlyDeletes }, by: \.risk)
            .mapValues { $0.reduce(Int64(0)) { CleanupByteCount.adding($1.estimatedSizeBytes, to: $0) } }
        return byRisk.max { $0.value < $1.value }?.key ?? .safe
    }

    private func riskTitle(_ risk: CleanupRisk) -> String {
        switch risk {
        case .safe:
            L10n.text("绿色 · 可安全清理", "Green · Safe")
        case .reviewOnly:
            L10n.text("黄色 · 需要判断", "Yellow · Review")
        case .protected:
            L10n.text("红色 · 高风险", "Red · High Risk")
        case .informational:
            L10n.text("信息", "Information")
        }
    }

    private func riskBytes(_ risk: CleanupRisk) -> Int64 {
        switch risk {
        case .safe: safeBytes
        case .reviewOnly: reviewBytes
        case .protected: protectedBytes
        case .informational: 0
        }
    }

    private func riskValueText(_ risk: CleanupRisk) -> String {
        // D19: each card counts only items that can be selected and cleaned.
        let valueCandidates: [ScanCandidate]
        switch risk {
        case .safe: valueCandidates = safeCandidates
        case .reviewOnly: valueCandidates = reviewCandidates
        case .protected: valueCandidates = protectedCandidates
        case .informational: valueCandidates = tierCandidates.filter { $0.risk == risk }
        }
        return CleanupMeasurementPresentation.aggregateValue(valueCandidates)
    }

    /// The count and selection line of a risk card (tests measure it).
    func riskCaption(for risk: CleanupRisk) -> String {
        "\(decisionCount(for: risk)) · \(riskSelectionSummary(risk: risk))"
    }

    func riskSelectionSummary(risk: CleanupRisk) -> String {
        let selectableCount = selectableDecisionCount(for: risk)
        guard selectableCount > 0 else {
            return L10n.text("无可操作项目", "No actionable items")
        }
        return L10n.text(
            "已选 \(selectedDecisionCount(for: risk))/\(ByteFormat.count(selectableCount)) 个可操作分组",
            "\(selectedDecisionCount(for: risk))/\(ByteFormat.count(selectableCount)) actionable groups selected"
        )
    }

    @ViewBuilder
    private var summaryCards: some View {
        LazyVGrid(columns: summaryGridColumns, spacing: layout.cardSpacing) {
            if !safeCandidates.isEmpty {
                CleanupResultSummaryCard(
                    title: L10n.text("可安全清理", "Safe to Clean"),
                    value: ByteFormat.storageString(safeBytes),
                    detail: L10n.items(safeCandidates.count),
                    tint: AppDesignTokens.Palette.success
                )
            }
            if !reviewCandidates.isEmpty {
                CleanupResultSummaryCard(
                    title: L10n.text("需要人工判断", "Manual Review"),
                    value: CleanupMeasurementPresentation.aggregateValue(reviewCandidates),
                    detail: L10n.items(reviewCandidates.count),
                    tint: AppDesignTokens.Palette.warning
                )
            }
            if !protectedCandidates.isEmpty {
                CleanupResultSummaryCard(
                    title: L10n.text("红色高风险", "Red High Risk"),
                    value: CleanupMeasurementPresentation.aggregateValue(protectedCandidates),
                    detail: L10n.text(
                        "\(ByteFormat.count(protectedCandidates.count)) 项可手动选择",
                        "\(ByteFormat.count(protectedCandidates.count)) manually selectable"
                    ),
                    tint: AppDesignTokens.Palette.destructive
                )
            }
            if !trashCandidates.isEmpty {
                CleanupResultSummaryCard(
                    title: L10n.text("废纸篓", "Trash"),
                    value: CleanupMeasurementPresentation.aggregateValue(trashCandidates),
                    detail: L10n.text("可单独清空，不可恢复", "Can be emptied separately; not recoverable"),
                    tint: AppDesignTokens.Palette.destructive
                )
            }
        }
    }

    private var selectionToolbar: some View {
        ViewThatFits(in: .horizontal) {
            selectionToolbarContent
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                selectionCountLabel
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Spacer(minLength: 0)
                    resultFilterMenu
                    sortMenu
                    selectionMenu
                }
            }
        }
    }

    private var selectionToolbarContent: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            selectionCountLabel
            Spacer()
            resultFilterMenu
            sortMenu
            selectionMenu
        }
    }

    private var selectionCountLabel: some View {
            Text(L10n.text(
                "已勾选 \(ByteFormat.count(selectedLeafCount))/\(ByteFormat.count(selectableLeafCount)) 项 · \(ByteFormat.count(selectedCount)) 组",
                "\(ByteFormat.count(selectedLeafCount)) of \(ByteFormat.count(selectableLeafCount)) selected · \(ByteFormat.count(selectedCount)) groups"
            ))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private var resultFilterMenu: some View {
            Menu {
                ForEach(CleanupResultFilter.allCases) { option in
                    Button {
                        resultFilter = option
                    } label: {
                        if resultFilter == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                Label(resultFilter.title, systemImage: "line.3.horizontal.decrease.circle")
            }
            .appButtonChrome(.secondary)
    }

    private var sortMenu: some View {
            Menu {
                ForEach(CleanupResultSort.allCases) { option in
                    Button {
                        sortOrder = option
                    } label: {
                        if sortOrder == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                Label(sortOrder.title, systemImage: "arrow.up.arrow.down")
            }
            .appButtonChrome(.secondary)
    }

    /// §3.3: the report-wide selection commands may change every listed row.
    private var reportScope: BulkUpdateScope {
        BulkUpdateScope(rowCount: tierCandidates.count)
    }

    /// The rows a group lists under the current filter.
    private func displayedRowCount(in subcategory: CleanupScanSubcategory) -> Int {
        subcategory.candidates.lazy.filter(matchesCurrentFilter).count
    }

    /// §3.3: expanding a tier or toggling its checkbox touches the rows of all
    /// its groups at once, so they are added up.
    private func tierScope(for risk: CleanupRisk) -> BulkUpdateScope {
        BulkUpdateScope(rowCounts: displayedSubcategories(for: risk).map(displayedRowCount(in:)))
    }

    private var selectionMenu: some View {
            Menu {
                Button {
                    reportScope.perform { store.selectRecommendedCleanupCandidates() }
                } label: {
                    Label(L10n.text("选择推荐项目", "Select Recommended"), systemImage: "checkmark.square")
                }
                .disabled(!store.canEditV2CleanupSelection || session.outcome == .cancelled || recommendedCount == 0)

                Button {
                    reportScope.perform { store.restoreDefaultCleanupSelection() }
                } label: {
                    Label(L10n.text("恢复默认选择", "Restore Default Selection"), systemImage: "arrow.uturn.backward.square")
                }
                .disabled(!store.canEditV2CleanupSelection || selectedLeafCount == 0)

                Button {
                    reportScope.perform { store.selectAllCleanupCandidates() }
                } label: {
                    Label(L10n.text("全选绿色", "Select All Green"), systemImage: "checkmark.square")
                }
                .disabled(!store.canEditV2CleanupSelection || session.outcome == .cancelled || safeSelectableCount == 0)

                Button {
                    reportScope.perform { store.clearCleanupCandidates() }
                } label: {
                    Label(L10n.text("清空", "Clear"), systemImage: "xmark.square")
                }
                .disabled(!store.canEditV2CleanupSelection || session.outcome == .cancelled || selectedLeafCount == 0)
            } label: {
                Label(L10n.text("选择", "Select"), systemImage: "checkmark.square")
            }
            .appButtonChrome(.secondary)
    }

    private var storageOverviewSection: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            CleanupReportSectionHeader(
                title: L10n.text("磁盘总览", "Disk Overview"),
                detail: L10n.text(
                    "绿色、黄色、红色为本次只读扫描识别的内容；蓝色为其余已用空间。",
                    "Green, yellow, and red are identified by this read-only scan; blue is other used space."
                ),
                systemImage: "internaldrive"
            )

            if let system = session.system, system.diskTotalBytes > 0 {
                LazyVGrid(columns: summaryGridColumns, spacing: layout.cardSpacing) {
                    CleanupSpaceMetric(
                        title: L10n.text("总容量", "Total"),
                        value: ByteFormat.storageString(system.diskTotalBytes),
                        detail: system.diskName,
                        systemImage: "internaldrive",
                        tint: AppDesignTokens.Palette.storage
                    )
                    CleanupSpaceMetric(
                        title: L10n.text("已使用", "Used"),
                        value: ByteFormat.storageString(system.diskUsedBytes),
                        detail: L10n.text("系统报告值", "System reported"),
                        systemImage: "chart.pie.fill",
                        tint: AppDesignTokens.Palette.information
                    )
                    CleanupSpaceMetric(
                        title: L10n.text("可用空间", "Available"),
                        value: ByteFormat.storageString(system.diskFreeBytes),
                        detail: L10n.text("当前可用", "Currently available"),
                        systemImage: "checkmark.circle.fill",
                        tint: AppDesignTokens.Palette.success
                    )
                }

                CleanupStorageDistributionBar(
                    totalBytes: system.diskTotalBytes,
                    safeBytes: safeBytes,
                    reviewBytes: reviewBytes,
                    protectedBytes: protectedBytes,
                    otherUsedBytes: max(
                        0,
                        system.diskUsedBytes - min(system.diskUsedBytes, identifiedBytes)
                    ),
                    freeBytes: system.diskFreeBytes
                )
                .frame(height: 14)

                LazyVGrid(columns: legendGridColumns, alignment: .leading, spacing: layout.cardSpacing) {
                    CleanupStorageLegend(
                        title: L10n.text("绿色可清理", "Green safe"),
                        value: ByteFormat.storageString(safeBytes),
                        tint: AppDesignTokens.Palette.success
                    )
                    CleanupStorageLegend(
                        title: L10n.text("黄色待判断", "Yellow review"),
                        value: CleanupMeasurementPresentation.aggregateValue(reviewCandidates),
                        tint: AppDesignTokens.Palette.warning
                    )
                    CleanupStorageLegend(
                        title: L10n.text("红色高风险", "Red high risk"),
                        value: CleanupMeasurementPresentation.aggregateValue(protectedCandidates),
                        tint: AppDesignTokens.Palette.destructive
                    )
                    CleanupStorageLegend(
                        title: L10n.text("其余已用", "Other used"),
                        value: ByteFormat.storageString(max(
                            0,
                            system.diskUsedBytes - min(system.diskUsedBytes, identifiedBytes)
                        )),
                        tint: AppDesignTokens.Palette.information
                    )
                }
            }

            summaryCards
        }
    }

    private var topCandidatesSection: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            CleanupReportSectionHeader(
                title: L10n.text("Top 5 空间占用", "Top 5 Space Users"),
                detail: L10n.text(
                    "按本次扫描估算容量排序，帮助你先看影响最大的项目。",
                    "Sorted by estimated scan size so you can review the largest impact first."
                ),
                systemImage: "list.number"
            )

            if topCandidates.isEmpty {
                Text(L10n.text("本次扫描没有达到显示阈值的项目。", "No item reached the display threshold."))
                    .font(AppDesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .padding(AppDesignTokens.Layout.sectionPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassPanel(
                        cornerRadius: AppDesignTokens.Layout.cardRadius,
                        tint: AppDesignTokens.Palette.storage,
                        prominence: .quiet
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(topCandidates.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { Divider() }
                        CleanupTopCandidateRow(
                            rank: index + 1,
                            candidate: candidate
                        ) {
                            store.revealCleanupCandidate(candidate)
                        }
                    }
                }
                .glassPanel(
                    cornerRadius: AppDesignTokens.Layout.cardRadius,
                    tint: AppDesignTokens.Palette.storage,
                    prominence: .quiet
                )
            }
        }
    }

    private var executionAdviceSection: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            CleanupReportSectionHeader(
                title: L10n.text("执行建议", "Action Plan"),
                detail: L10n.text(
                    "先处理默认勾选的绿色项目，再逐项核对黄色内容；红色项目需双重确认后才移入废纸篓，清空废纸篓单独确认。",
                    "Start with the selected green items, then review yellow items one by one; red items move to Trash only after two confirmations, and emptying the Trash is confirmed separately."
                ),
                systemImage: "checklist"
            )
            VStack(spacing: 0) {
                CleanupReportAdviceRow(
                    number: 1,
                    title: L10n.text("先确认默认勾选的绿色项目", "Review the selected green items first"),
                    detail: L10n.text(
                        "当前可安全清理 \(ByteFormat.storageString(safeBytes))；实际执行仍经过预检、确认和废纸篓。",
                        "\(ByteFormat.storageString(safeBytes)) is safe to review; execution still uses preflight, confirmation, and Trash."
                    ),
                    tint: AppDesignTokens.Palette.success
                )
                Divider()
                CleanupReportAdviceRow(
                    number: 2,
                    title: L10n.text("逐项核对黄色项目", "Review yellow items individually"),
                    detail: L10n.text(
                        "可能含应用状态或个人文件；只有你手动勾选并再次确认后才会移到废纸篓。",
                        "These may contain app state or personal files and move to Trash only after manual selection and an extra confirmation."
                    ),
                    tint: AppDesignTokens.Palette.warning
                )
                Divider()
                CleanupReportAdviceRow(
                    number: 3,
                    title: L10n.text("红色项目逐项双重确认", "Confirm red items twice"),
                    detail: L10n.text(
                        "近期仍有活动的开发产物和重复的应用副本默认不选；重复应用整组勾选时自动保留一份。删除应用本身请使用“卸载”页。",
                        "Recently active developer files and duplicate app copies are off by default; checking a whole duplicate-app group keeps one copy. To remove an app itself, use Uninstall."
                    ),
                    tint: AppDesignTokens.Palette.destructive
                )
            }
            .glassPanel(
                cornerRadius: AppDesignTokens.Layout.cardRadius,
                tint: AppDesignTokens.Palette.information,
                prominence: .quiet
            )
        }
    }

    @ViewBuilder
    private func tierSection(
        risk: CleanupRisk,
        title: String,
        detail: String
    ) -> some View {
        let tierSubcategories = displayedSubcategories(for: risk)
        let isExpanded = expandedRiskTierIDs.contains(risk.rawValue)
        let tint = CleanupRiskPresentation.tint(risk)
        let tierSelectionIDs = selectableCandidateIDs(for: risk)
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
                if tierSelectionIDs.isEmpty {
                    CleanupSelectionAvailabilityIndicator(risk: risk)
                } else {
                    CleanupTriStateButton(
                        state: store.cleanupSelection.groupState(for: Array(tierSelectionIDs), in: session),
                        isEnabled: session.outcome != .cancelled
                            && store.canEditV2CleanupSelection,
                        label: riskSelectionLabel(
                            risk,
                            selectableCount: tierSelectionIDs.count
                        ),
                        tint: tint,
                        enabledHint: riskSelectionHint(risk)
                    ) {
                        let state = store.cleanupSelection.groupState(for: Array(tierSelectionIDs), in: session)
                        // §3.3: one update over every group of the tier.
                        BulkUpdateScope(rowCount: tierSelectionIDs.count).perform {
                            store.setCleanupCandidates(
                                Array(tierSelectionIDs),
                                selected: state != .checked
                            )
                        }
                    }
                }
                Button {
                    toggleTierExpansion(risk)
                } label: {
                    HStack(alignment: .center, spacing: AppDesignTokens.Spacing.small) {
                        CleanupReportSectionHeader(
                            title: title,
                            detail: detail,
                            systemImage: CleanupRiskPresentation.systemImage(risk),
                            tint: tint
                        )
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(AppDesignTokens.Typography.compactSymbol)
                            .foregroundStyle(tint)
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .accessibilityLabel(isExpanded
                    ? L10n.text("收起 \(title)", "Collapse \(title)")
                    : L10n.text("展开 \(title)", "Expand \(title)"))
                .accessibilityValue(isExpanded
                    ? L10n.text("已展开", "Expanded")
                    : L10n.text("已收起", "Collapsed"))
                .help(isExpanded
                    ? L10n.text("收起此风险分组", "Collapse this risk group")
                    : L10n.text("查看此风险分组", "Show this risk group"))
            }
            .padding(AppDesignTokens.Layout.compactPadding)
            .background {
                SurfaceBackground(level: .card, cornerRadius: AppDesignTokens.Corner.card, tint: tint)
            }

            if isExpanded {
                VStack(spacing: AppDesignTokens.Spacing.small) {
                    if tierSubcategories.isEmpty {
                        Text(L10n.text("没有符合当前筛选条件的项目。", "No items match the current filter."))
                            .font(AppDesignTokens.Typography.body)
                            .foregroundStyle(.secondary)
                            .padding(AppDesignTokens.Layout.sectionPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassPanel(
                                cornerRadius: AppDesignTokens.Layout.cardRadius,
                                tint: tint,
                                prominence: .quiet
                            )
                    } else {
                        ForEach(Array(tierSubcategories.enumerated()), id: \.element.id) { index, subcategory in
                            CleanupSubcategorySelectionView(
                                store: store,
                                session: session,
                                subcategory: subcategory,
                                candidates: sortedCandidates(in: subcategory),
                                cleanupScopeIDs: selectionScopeIDs
                            )
                            .appStaggeredAppearance(index: index)
                        }
                    }
                }
                // §3.3: the tier's rows add up; above 200 its groups neither
                // stagger in (also when a filter adds one) nor animate rows.
                .appBulkAnimationGuard(tierScope(for: risk))
                .transition(AppMotion.rowTransition(reduceMotion: reduceMotion))
            }
        }
        .id(risk.rawValue)
    }

    private func riskSelectionLabel(
        _ risk: CleanupRisk,
        selectableCount: Int
    ) -> String {
        switch risk {
        case .safe:
            L10n.text(
                "全部可操作的绿色项目（\(ByteFormat.count(selectableCount)) 项）",
                "All actionable green items (\(ByteFormat.count(selectableCount)))"
            )
        case .reviewOnly:
            L10n.text(
                "全部可操作的黄色项目（\(ByteFormat.count(selectableCount)) 项）",
                "All actionable yellow items (\(ByteFormat.count(selectableCount)))"
            )
        case .protected:
            L10n.text(
                "全部可操作的红色高风险项目（\(ByteFormat.count(selectableCount)) 项）",
                "All actionable red high-risk items (\(ByteFormat.count(selectableCount)))"
            )
        case .informational:
            L10n.text(
                "全部可操作的信息项目（\(ByteFormat.count(selectableCount)) 项）",
                "All actionable informational items (\(ByteFormat.count(selectableCount)))"
            )
        }
    }

    private func riskSelectionHint(_ risk: CleanupRisk) -> String {
        switch risk {
        case .safe:
            L10n.text(
                "切换所有可操作的绿色项目。",
                "Toggle all actionable green items."
            )
        case .reviewOnly:
            L10n.text(
                "切换所有可操作的黄色项目；执行前仍需额外确认。",
                "Toggle all actionable yellow items; execution still requires an extra confirmation."
            )
        case .protected:
            L10n.text(
                "切换所有可操作的红色项目；执行前仍需双重确认，且只会移入废纸篓。",
                "Toggle all actionable red items; execution still requires two confirmations and only moves items to Trash."
            )
        case .informational:
            L10n.text(
                "切换所有可操作的信息项目。",
                "Toggle all actionable informational items."
            )
        }
    }

    /// A2: reads again which owner apps are running. The Debug screenshot
    /// fixture keeps its made-up running owner instead (review P2-2).
    private func refreshOwnerRunningState() async {
#if DEBUG
        if store.isDebugSmartScanSessionFixtureActive { return }
#endif
        await store.refreshCleanupOwnerRunningState()
    }

    private func toggleTierExpansion(_ risk: CleanupRisk) {
        // §3.3 / §3.1: the tier's rows appear at once above 200 rows or under
        // Reduce Motion; otherwise the layout moves with `standard`.
        tierScope(for: risk).perform(AppMotion.layout(reduceMotion: reduceMotion)) {
            if expandedRiskTierIDs.contains(risk.rawValue) {
                expandedRiskTierIDs.remove(risk.rawValue)
            } else {
                expandedRiskTierIDs.insert(risk.rawValue)
            }
        }
    }

    private var scanCoverageSection: some View {
        let readable = session.permissions.filter { $0.status == .readable }.count
        let limited = session.permissions.count - readable
        return VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            CleanupReportSectionHeader(
                title: L10n.text("扫描覆盖", "Scan Coverage"),
                detail: L10n.text(
                    "缺失的可选目录属于正常情况；权限受限或超时会明确标记为部分结果。",
                    "Missing optional directories are normal; access limits or timeout are marked as partial results."
                ),
                systemImage: "scope"
            )
            LazyVGrid(columns: summaryGridColumns, spacing: layout.cardSpacing) {
                CleanupResultSummaryCard(
                    title: L10n.text("已读取范围", "Readable Scopes"),
                    value: "\(readable)",
                    detail: L10n.text("只读扫描", "Read only"),
                    tint: AppDesignTokens.Palette.success
                )
                CleanupResultSummaryCard(
                    title: L10n.text("缺失或受限", "Missing or Limited"),
                    value: "\(limited)",
                    detail: L10n.text("未强行访问", "Not forced"),
                    tint: limited == 0
                        ? AppDesignTokens.Palette.information
                        : AppDesignTokens.Palette.warning
                )
                CleanupResultSummaryCard(
                    title: L10n.text("扫描耗时", "Duration"),
                    value: String(format: "%.1fs", session.metrics.duration),
                    detail: session.issues.contains { $0.kind == .timedOut }
                        ? L10n.text("已达到时间上限", "Time limit reached")
                        : L10n.text("有界扫描", "Bounded scan"),
                    tint: session.issues.contains { $0.kind == .timedOut }
                        ? AppDesignTokens.Palette.warning
                        : AppDesignTokens.Palette.information
                )
                CleanupResultSummaryCard(
                    title: L10n.text("完整容量", "Complete Measurements"),
                    value: ByteFormat.count(session.metrics.completeMeasurementCandidateCount),
                    detail: L10n.text(
                        "至少值 \(ByteFormat.count(session.metrics.lowerBoundMeasurementCandidateCount)) · 失败 \(ByteFormat.count(session.metrics.failedMeasurementCandidateCount))",
                        "Lower bounds \(ByteFormat.count(session.metrics.lowerBoundMeasurementCandidateCount)) · failed \(ByteFormat.count(session.metrics.failedMeasurementCandidateCount))"
                    ),
                    tint: session.metrics.lowerBoundMeasurementCandidateCount == 0
                        && session.metrics.failedMeasurementCandidateCount == 0
                            ? AppDesignTokens.Palette.success
                            : AppDesignTokens.Palette.warning
                )
                CleanupResultSummaryCard(
                    title: L10n.text("已访问目录", "Visited Directories"),
                    value: ByteFormat.count(session.metrics.visitedDirectoryCount),
                    detail: L10n.text(
                        "条目 \(ByteFormat.count(session.metrics.visitedEntryCount))",
                        "\(ByteFormat.count(session.metrics.visitedEntryCount)) entries"
                    ),
                    tint: AppDesignTokens.Palette.information
                )
                CleanupResultSummaryCard(
                    title: L10n.text("安全跳过", "Safely Skipped"),
                    value: ByteFormat.count(session.metrics.permissionFailureCount),
                    detail: L10n.text(
                        "权限失败 · 云文件 \(ByteFormat.count(session.metrics.cloudSkippedCount)) · 超时 \(ByteFormat.count(session.metrics.timedOutRuleCount)) · 未列出 \(ByteFormat.count(session.metrics.notActionableCandidateCount))",
                        "permission failures · cloud \(ByteFormat.count(session.metrics.cloudSkippedCount)) · timeouts \(ByteFormat.count(session.metrics.timedOutRuleCount)) · not listed \(ByteFormat.count(session.metrics.notActionableCandidateCount))"
                    ),
                    tint: session.metrics.permissionFailureCount == 0
                        && session.metrics.timedOutRuleCount == 0
                        && session.metrics.notActionableCandidateCount == 0
                            ? AppDesignTokens.Palette.information
                            : AppDesignTokens.Palette.warning
                )
                CleanupResultSummaryCard(
                    title: L10n.text("候选截断", "Truncated Candidates"),
                    value: ByteFormat.count(session.metrics.truncatedCandidateCount),
                    detail: session.metrics.truncatedCandidateCount == 0
                        ? L10n.text("结果未触及上限", "Result limit not reached")
                        : L10n.text("其余候选未显示", "Additional candidates are hidden"),
                    tint: session.metrics.truncatedCandidateCount == 0
                        ? AppDesignTokens.Palette.information
                        : AppDesignTokens.Palette.warning
                )
            }
        }
    }

    private var longTermAdviceSection: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            CleanupReportSectionHeader(
                title: L10n.text("长期建议", "Long-term Suggestions"),
                detail: L10n.text(
                    "这些建议不会自动执行，也不会改动你的文件。",
                    "These suggestions never run automatically or modify your files."
                ),
                systemImage: "calendar.badge.clock"
            )
            VStack(spacing: 0) {
                CleanupReportAdviceRow(
                    number: 1,
                    title: L10n.text("定期复查缓存和开发产物", "Review caches and build artifacts periodically"),
                    detail: L10n.text("应用更新或大型开发任务后再扫描，通常最有价值。", "A scan after app updates or large development work is usually most useful."),
                    tint: AppDesignTokens.Palette.success
                )
                Divider()
                CleanupReportAdviceRow(
                    number: 2,
                    title: L10n.text("使用 macOS 存储设置管理系统内容", "Use macOS Storage settings for system content"),
                    detail: L10n.text("系统数据、iCloud 和媒体库优先交给系统或原应用管理。", "Let macOS or the owning app manage system data, iCloud, and media libraries."),
                    tint: AppDesignTokens.Palette.information
                )
                Divider()
                CleanupReportAdviceRow(
                    number: 3,
                    title: L10n.text("先备份，再归档大型个人文件", "Back up before archiving large personal files"),
                    detail: L10n.text("确认备份可恢复后，再移动到外置磁盘或 NAS。", "Confirm the backup can be restored before moving files to external storage or a NAS."),
                    tint: AppDesignTokens.Palette.warning
                )
            }
            .glassPanel(
                cornerRadius: AppDesignTokens.Layout.cardRadius,
                tint: AppDesignTokens.Palette.information,
                prominence: .quiet
            )
        }
    }

    /// D23: one separate item that empties the Trash. It is never preselected
    /// and is confirmed on its own, apart from items that move to Trash.
    @ViewBuilder
    private var trashSection: some View {
        if let trash = trashCandidates.first,
           resultFilter == .all || (resultFilter == .selected && isTrashSelected) {
            let tint = AppDesignTokens.Palette.destructive
            let entryCount = trash.permanentDeletionEntries?.count ?? 0
            HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
                CleanupTriStateButton(
                    state: store.cleanupSelection.state(for: trashCandidateIDs),
                    isEnabled: session.outcome != .cancelled
                        && store.canEditV2CleanupSelection,
                    label: L10n.text("清空废纸篓", "Empty Trash"),
                    tint: tint,
                    enabledHint: L10n.text(
                        "默认不选；勾选后执行前需要单独二次确认，删除不可恢复。",
                        "Off by default. Once checked, it needs its own two confirmations, and the deletion cannot be undone."
                    )
                ) {
                    let state = store.cleanupSelection.state(for: trashCandidateIDs)
                    store.setCleanupCandidates(trashCandidateIDs, selected: state != .checked)
                }
                CleanupReportSectionHeader(
                    title: L10n.text("清空废纸篓 · 不可恢复", "Empty Trash · Cannot Be Undone"),
                    detail: L10n.text(
                        "单独一项，默认不选。只永久删除扫描时废纸篓里已有的 \(ByteFormat.count(entryCount)) 项，本次移入废纸篓的文件不受影响；执行前单独二次确认。",
                        "A separate item, off by default. It permanently deletes only the \(ByteFormat.count(entryCount)) item(s) already in the Trash during the scan; files this cleanup moves to Trash are not affected. Confirmed twice on its own."
                    ),
                    systemImage: "trash.slash",
                    tint: tint
                )
                Text(CleanupMeasurementPresentation.value(trash))
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .monospacedDigit()
            }
            .padding(AppDesignTokens.Layout.compactPadding)
            .glassPanel(
                cornerRadius: AppDesignTokens.Layout.cardRadius,
                tint: tint,
                prominence: .quiet
            )
            .id("empty-trash")
        } else if trashPermissionDenied, resultFilter == .all {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                CleanupReportSectionHeader(
                    title: L10n.text("无法读取废纸篓", "Trash Cannot Be Read"),
                    detail: L10n.text(
                        "没有读取废纸篓的权限，因此不知道其中是否有可清空的项目。请在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”中允许本应用，然后重新扫描。",
                        "This app cannot read the Trash, so it cannot tell whether anything can be emptied. Allow this app in System Settings › Privacy & Security › Full Disk Access, then scan again."
                    ),
                    systemImage: "lock.trianglebadge.exclamationmark",
                    tint: AppDesignTokens.Palette.warning
                )
                HStack {
                    Spacer(minLength: 0)
                    Button(L10n.text("打开系统设置", "Open System Settings")) {
                        _ = CleanupService.openFullDiskAccessSettings()
                    }
                    .appButtonChrome(.secondary)
                }
            }
            .padding(AppDesignTokens.Layout.compactPadding)
            .glassPanel(
                cornerRadius: AppDesignTokens.Layout.cardRadius,
                tint: AppDesignTokens.Palette.warning,
                prominence: .quiet
            )
            .id("empty-trash")
        }
    }

    private var secondaryDetailsSection: some View {
        DisclosureGroup(isExpanded: $isSecondaryDetailsExpanded) {
            LazyVStack(spacing: layout.sectionSpacing) {
                storageOverviewSection
                topCandidatesSection
                executionAdviceSection
                scanCoverageSection
                longTermAdviceSection
            }
            .padding(.top, AppDesignTokens.Spacing.medium)
        } label: {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(AppDesignTokens.Palette.storage)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("查看磁盘与扫描详情", "View Disk and Scan Details"))
                        .font(AppDesignTokens.Typography.inlineTitle)
                    Text(L10n.text(
                        "容量、扫描覆盖与处理建议",
                        "Capacity, scan coverage, and recommendations"
                    ))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(layout.cardPadding)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.storage,
            prominence: .quiet
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: isSecondaryDetailsExpanded
        )
    }

    private var cleanupActionBar: some View {
        VStack(spacing: 6) {
            PinnedActionBar {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(
                        selectionActionSummaryChinese,
                        selectionActionSummaryEnglish
                    ))
                    .font(AppDesignTokens.TypeScale.bodyEmphasis)
                    .foregroundStyle(surfaces.textPrimary)
                    .monospacedDigit()
                    .appDataTransition(value: selectedLeafCount)
                    if store.cleanupFeatureConfiguration.mode == .v2Full {
                        Text(isTrashSelected
                             ? L10n.text(
                                "已勾选清空废纸篓：扫描时废纸篓里的项目会被永久删除，不可恢复。",
                                "Empty Trash is checked: items in the Trash during the scan will be permanently deleted and cannot be restored."
                             )
                             : L10n.text(
                                "文件会先移入废纸篓；清空废纸篓后，磁盘空间才会真正释放。",
                                "Files move to Trash first; disk space is released after Trash is emptied."
                             ))
                        .font(AppDesignTokens.TypeScale.caption)
                        .foregroundStyle(isTrashSelected ? AppDesignTokens.Palette.destructive : surfaces.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    // D93: named when the row is checked, before cleanup skips it.
                    if let quitNotice = selectionQuitNotice {
                        Text(quitNotice)
                            .font(AppDesignTokens.TypeScale.caption)
                            .foregroundStyle(AppDesignTokens.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } actions: {
                if store.cleanupFeatureConfiguration.mode == .v2Full {
                    Button {
                        store.requestV2Cleanup(
                            disposition: .trash,
                            candidateIDs: selectionScopeIDs
                        )
                    } label: {
                        Label(
                            cleanupActionTitle,
                            systemImage: selectedReviewCandidates.isEmpty
                                && selectedProtectedCandidates.isEmpty
                                && !isTrashSelected
                                    ? "checkmark.shield"
                                    : "exclamationmark.shield"
                        )
                    }
                    // D53 §1.2: cleaning is destructive and always takes the
                    // red gradient (N19, D49); the label still names the risk.
                    .buttonStyle(GradientButtonStyle(kind: .destructive, size: .medium))
                    .disabled(
                        selectedBytes == 0
                            || session.outcome == .cancelled
                            || !store.canRequestV2Cleanup
                    )
                } else {
                    AppButton(
                        title: L10n.text("生成 Dry-run · \(ByteFormat.storageString(selectedBytes))", "Create Dry Run · \(ByteFormat.storageString(selectedBytes))"),
                        systemImage: "checkmark.shield",
                        kind: .primary,
                        tint: AppDesignTokens.Palette.steadyChrome,
                        isDisabled: selectedBytes == 0 || session.outcome == .cancelled
                    ) {
                        store.prepareCleanupDryRun(candidateIDs: selectionScopeIDs)
                    }
                }
            }

            if let summary = store.cleanupDryRunSummary,
               summary.sessionID == session.id {
                Label(
                    L10n.text(
                        "已核对 \(ByteFormat.count(summary.selectedCount)) 项、\(ByteFormat.storageString(summary.selectedBytes))；文件系统改动：0",
                        "\(ByteFormat.count(summary.selectedCount)) item(s), \(ByteFormat.storageString(summary.selectedBytes)) validated; file-system changes: 0"
                    ),
                    systemImage: "checkmark.seal.fill"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.success)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var cleanupActionTitle: String {
        selectedReviewCandidates.isEmpty && selectedProtectedCandidates.isEmpty && !isTrashSelected
            ? L10n.text(
                "安全清理 · \(ByteFormat.storageString(selectedBytes))",
                "Safe Cleanup · \(ByteFormat.storageString(selectedBytes))"
            )
            : L10n.text(
                "清理所选 · \(ByteFormat.storageString(selectedBytes))",
                "Clean Selected · \(ByteFormat.storageString(selectedBytes))"
            )
    }

    private var cleanupActionTint: Color {
        if !selectedProtectedCandidates.isEmpty || isTrashSelected {
            return AppDesignTokens.Palette.destructive
        }
        return selectedReviewCandidates.isEmpty
            ? AppDesignTokens.Palette.information
            : AppDesignTokens.Palette.warning
    }

    /// Rows, like the confirmation sheet (coordinator note, D53 V0); the
    /// number of groups follows as a hint.
    private var selectionActionSummaryChinese: String {
        let lead = "已选择 \(ByteFormat.count(selectedLeafCount)) 项（\(ByteFormat.count(selectedCount)) 组）"
        if isTrashSelected {
            return "\(lead) · 含永久清空废纸篓"
        }
        if !selectedProtectedCandidates.isEmpty {
            return "\(lead) · 红色 \(ByteFormat.count(selectedProtectedCandidates.count)) 项需双重确认"
        }
        if !selectedReviewCandidates.isEmpty {
            return "\(lead) · 黄色 \(ByteFormat.count(selectedReviewCandidates.count)) 项需确认"
        }
        return "\(lead) · \(ByteFormat.storageString(selectedBytes))"
    }

    private var selectionActionSummaryEnglish: String {
        let lead = "\(ByteFormat.count(selectedLeafCount)) selected (\(ByteFormat.count(selectedCount)) groups)"
        if isTrashSelected {
            return "\(lead) · includes permanently emptying the Trash"
        }
        if !selectedProtectedCandidates.isEmpty {
            return "\(lead) · \(ByteFormat.count(selectedProtectedCandidates.count)) red item(s) need two confirmations"
        }
        if !selectedReviewCandidates.isEmpty {
            return "\(lead) · \(ByteFormat.count(selectedReviewCandidates.count)) yellow item(s) need confirmation"
        }
        return "\(lead) · \(ByteFormat.storageString(selectedBytes))"
    }

    private func matchesCurrentFilter(_ candidate: ScanCandidate) -> Bool {
        switch resultFilter {
        case .all:
            true
        case .selected:
            store.cleanupSelection.selectedCandidateIDs.contains(candidate.id)
        case .recommended:
            candidate.isRecommendedForSelection
        }
    }
}

struct DeveloperCleanupThresholdControl: View {
    @ObservedObject var store: ScanStore
    var scannedThresholdDays: Int? = nil
    var onRescan: (() -> Void)? = nil

    private var threshold: Binding<Int> {
        Binding(
            get: { store.developerInactivityThresholdDays },
            set: { store.setDeveloperInactivityThresholdDays($0) }
        )
    }

    private var needsRescan: Bool {
        scannedThresholdDays.map {
            $0 != store.developerInactivityThresholdDays
        } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            ProjectArtifactEntryButton(coordinator: store.heavyWorkCoordinator)
            SimulatorCleanupEntryButton(coordinator: store.heavyWorkCoordinator)
            HStack(alignment: .center, spacing: AppDesignTokens.Spacing.medium) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("开发文件活动阈值", "Developer Activity Threshold"))
                            .font(AppDesignTokens.Typography.inlineTitle)
                        Text(L10n.text(
                            "超过此时间为黄色；此时间以内为红色。超过一年始终为绿色。",
                            "Older than this is yellow; within it is red. Over one year is always green."
                        ))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(AppDesignTokens.Palette.information)
                }
                Spacer(minLength: AppDesignTokens.Spacing.medium)
                Stepper(
                    value: threshold,
                    in: DeveloperCleanupAgePolicy.minimumThresholdDays...DeveloperCleanupAgePolicy.maximumThresholdDays,
                    step: 1
                ) {
                    Text(L10n.text(
                        "\(store.developerInactivityThresholdDays) 天",
                        "\(store.developerInactivityThresholdDays) days"
                    ))
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .monospacedDigit()
                }
                .fixedSize()
                .disabled(store.isPreparingScan)
            }

            if let scannedThresholdDays {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Label(
                        needsRescan
                            ? L10n.text(
                                "当前结果使用 \(scannedThresholdDays) 天；重新扫描后应用新设置。",
                                "These results use \(scannedThresholdDays) days; rescan to apply the new setting."
                            )
                            : L10n.text(
                                "当前结果使用 \(scannedThresholdDays) 天阈值。",
                                "These results use a \(scannedThresholdDays)-day threshold."
                            ),
                        systemImage: needsRescan ? "arrow.clockwise.circle" : "checkmark.circle"
                    )
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(needsRescan
                        ? AppDesignTokens.Palette.warning
                        : AppDesignTokens.Palette.success)
                    Spacer(minLength: 0)
                    if needsRescan, let onRescan {
                        Button(L10n.text("按新阈值重新扫描", "Rescan with New Threshold")) {
                            onRescan()
                        }
                        .appButtonChrome(.secondary)
                    }
                }
            }
        }
        .padding(AppDesignTokens.Layout.compactPadding)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.information,
            prominence: .quiet
        )
    }
}

private struct CleanupReportSectionHeader: View {
    let title: String
    let detail: String
    let systemImage: String
    var tint: Color = AppDesignTokens.Palette.storage

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
            Image(systemName: systemImage)
                .font(AppDesignTokens.Typography.sectionTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppDesignTokens.Typography.sectionTitle)
                Text(detail)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(detail)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CleanupStorageDistributionBar: View {
    let totalBytes: Int64
    let safeBytes: Int64
    let reviewBytes: Int64
    let protectedBytes: Int64
    let otherUsedBytes: Int64
    let freeBytes: Int64

    private struct Segment: Identifiable {
        let id: String
        let bytes: Int64
        let tint: Color
    }

    private var segments: [Segment] {
        [
            Segment(id: "safe", bytes: safeBytes, tint: AppDesignTokens.Palette.success),
            Segment(id: "review", bytes: reviewBytes, tint: AppDesignTokens.Palette.warning),
            Segment(id: "protected", bytes: protectedBytes, tint: AppDesignTokens.Palette.destructive),
            Segment(id: "other", bytes: otherUsedBytes, tint: AppDesignTokens.Palette.information),
            Segment(id: "free", bytes: freeBytes, tint: Color.primary.opacity(0.12)),
        ]
        .filter { $0.bytes > 0 }
    }

    var body: some View {
        let represented = CleanupByteCount.sum(segments.map(\.bytes))
        let denominator = max(1, max(totalBytes, represented))
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.tint)
                        .frame(
                            width: proxy.size.width
                                * CGFloat(segment.bytes)
                                / CGFloat(denominator)
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CleanupStorageLegend: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CleanupTopCandidateRow: View {
    let rank: Int
    let candidate: ScanCandidate
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
            Text("\(rank)")
                .font(AppDesignTokens.Typography.inlineTitle)
                .monospacedDigit()
                .foregroundStyle(CleanupRiskPresentation.tint(candidate.risk))
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Text(candidate.sourceURL.lastPathComponent)
                        .font(AppDesignTokens.Typography.compactLabelEmphasis)
                        .fixedSize(horizontal: false, vertical: true)
                    CleanupRiskBadge(risk: candidate.risk)
                    CleanupRecommendationBadge(
                        level: CleanupRecommendationDisplayPolicy.level(for: candidate)
                    )
                }
                Text("\(candidate.subcategoryTitle) · \(candidate.reason)")
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(candidate.snapshot.standardizedPath)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppDesignTokens.Spacing.small)
            Text(CleanupMeasurementPresentation.value(candidate))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
            AppIconButton(
                title: L10n.text("在访达中显示", "Show in Finder"),
                systemImage: "folder",
                action: reveal
            )
        }
        .padding(.horizontal, AppDesignTokens.Layout.sectionPadding)
        .padding(.vertical, AppDesignTokens.Layout.compactPadding)
    }
}

private struct CleanupReportAdviceRow: View {
    let number: Int
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
            Text("\(number)")
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppDesignTokens.Typography.inlineTitle)
                Text(detail)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
    }
}

private enum CleanupResultFilter: String, CaseIterable, Identifiable {
    case all
    case selected
    case recommended

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            L10n.text("全部发现", "All Found")
        case .selected:
            L10n.text("已选择", "Selected")
        case .recommended:
            L10n.text("推荐", "Recommended")
        }
    }
}

private enum CleanupResultSort: String, CaseIterable, Identifiable {
    case largest
    case name
    case category

    var id: Self { self }

    var title: String {
        switch self {
        case .largest:
            L10n.text("最大优先", "Largest First")
        case .name:
            L10n.text("名称", "Name")
        case .category:
            L10n.text("类别", "Category")
        }
    }
}

enum CleanupMeasurementPresentation {
    static func value(_ candidate: ScanCandidate) -> String {
        if candidate.ruleID == "trash.icloud-drive", !candidate.measurementCompleteness.isFailed {
            let cloud = ByteFormat.storageString(candidate.snapshot.logicalSizeBytes)
            let local = candidate.snapshot.allocatedSizeBytes.map { ByteFormat.storageString($0) } ?? L10n.text("未知", "Unknown")
            return candidate.measurementCompleteness.isComplete
                ? L10n.text("iCloud 中 \(cloud) · 本机 \(local)", "iCloud \(cloud) · On this Mac \(local)")
                : L10n.text("iCloud 中至少 \(cloud) · 本机至少 \(local)", "iCloud at least \(cloud) · On this Mac at least \(local)")
        }
        switch candidate.measurementCompleteness {
        case .complete:
            return ByteFormat.storageString(candidate.estimatedSizeBytes)
        case .lowerBound:
            return L10n.text(
                "至少 \(ByteFormat.storageString(candidate.estimatedSizeBytes))",
                "At least \(ByteFormat.storageString(candidate.estimatedSizeBytes))"
            )
        case .failed:
            return L10n.text("无法计算", "Unavailable")
        }
    }

    static func aggregateValue(_ candidates: [ScanCandidate]) -> String {
        guard !candidates.isEmpty else { return ByteFormat.storageString(0) }
        let measured = candidates.filter { !$0.measurementCompleteness.isFailed }
        guard !measured.isEmpty else { return L10n.text("无法计算", "Unavailable") }
        let bytes = CleanupByteCount.sum(measured.map(\.estimatedSizeBytes))
        guard candidates.allSatisfy({ $0.measurementCompleteness.isComplete }) else {
            return L10n.text(
                "至少 \(ByteFormat.storageString(bytes))",
                "At least \(ByteFormat.storageString(bytes))"
            )
        }
        return ByteFormat.storageString(bytes)
    }

    static func status(_ candidate: ScanCandidate) -> String {
        switch candidate.measurementCompleteness {
        case .complete:
            return L10n.text("完整容量", "Complete Measurement")
        case .lowerBound:
            return L10n.text("至少占用", "Lower-bound Measurement")
        case .failed:
            return L10n.text("无法计算", "Measurement Unavailable")
        }
    }

    static func detail(_ candidate: ScanCandidate) -> String? {
        switch candidate.measurementCompleteness {
        case .complete:
            return nil
        case let .lowerBound(reason), let .failed(reason):
            let reasonText = switch reason {
            case .unreadableDescendant:
                L10n.text("部分子项目无法读取", "Some descendants could not be read")
            case .permissionDenied:
                L10n.text("部分内容没有读取权限", "Some content is not readable")
            case .symbolicLinkSkipped:
                L10n.text("已跳过符号链接", "A symbolic link was skipped")
            case .excludedDescendant:
                L10n.text("包含用户排除的子目录", "Contains a user-excluded subtree")
            case .depthLimitReached:
                L10n.text("达到扫描深度上限", "The scan depth limit was reached")
            case .unknown:
                L10n.text("容量信息不完整", "Measurement is incomplete")
            }
            if candidate.measurementCompleteness.isFailed {
                return L10n.text(
                    "\(reasonText)，因此不能加入清理计划。",
                    "\(reasonText), so this item cannot enter a cleanup plan."
                )
            }
            if candidate.action.permanentlyDeletes {
                // D23: entries left out at scan time are never deleted.
                return L10n.text(
                    "\(reasonText)；这些项目不会被删除，显示的大小只计入将删除的项目。",
                    "\(reasonText); those entries are not deleted, and the size counts only the entries that will be."
                )
            }
            // D19: a lower bound is still selectable; only the item itself moves.
            return L10n.text(
                "\(reasonText)，大小按已读取部分显示为“至少”；清理时只把该项目本身移入废纸篓，不会跟随其中的符号链接。",
                "\(reasonText), so the size shows the readable part as \"at least\". Cleanup moves only this item itself to Trash and never follows links inside it."
            )
        }
    }
}

private struct CleanupRecommendationBadge: View {
    let level: CleanupRecommendationLevel

    private var title: String {
        switch level {
        case .recommended: L10n.text("推荐", "Recommended")
        case .optional: L10n.text("可选", "Optional")
        case .notRecommended: L10n.text("不建议", "Not Recommended")
        case .advisoryOnly: L10n.text("仅供查看", "View Only")
        }
    }

    private var tint: Color {
        switch level {
        case .recommended: AppDesignTokens.Palette.success
        case .optional: AppDesignTokens.Palette.information
        case .notRecommended: AppDesignTokens.Palette.warning
        case .advisoryOnly: AppDesignTokens.Palette.secondaryText
        }
    }

    var body: some View {
        Text(title)
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.10), in: Capsule())
            .accessibilityLabel(title)
    }
}

private struct CleanupSubcategorySelectionView: View {
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    let session: ScanSession
    let subcategory: CleanupScanSubcategory
    let candidates: [ScanCandidate]
    var cleanupScopeIDs: Set<ScanCandidateID>? = nil
    var usesLightfield = false
    @State private var isExpanded = false
    @State private var isShowingDetails = false

    private var state: TriStateSelection {
        store.cleanupSelection.groupState(for: subcategory.selectableCandidateIDs, in: session)
    }

    private var displayedRecommendation: CleanupRecommendationLevel {
        CleanupRecommendationDisplayPolicy.level(
            for: candidates,
            fallback: subcategory.recommendation
        )
    }

    private var itemCountSummary: String {
        let total = candidates.count
        let selectable = subcategory.selectableCandidateIDs.count
        if selectable == 0 {
            return L10n.text(
                "\(L10n.items(total)) · 没有可清理项目",
                "\(L10n.items(total)) · nothing to clean"
            )
        }
        if selectable < total {
            return L10n.text(
                "\(L10n.items(total)) · \(ByteFormat.count(selectable)) 项可选择",
                "\(L10n.items(total)) · \(ByteFormat.count(selectable)) selectable"
            )
        }
        guard subcategory.risk != .safe else { return L10n.items(total) }
        return L10n.text(
            "\(L10n.items(total)) · 可选择",
            "\(L10n.items(total)) · selectable"
        )
    }

    private var selectionHint: String {
        switch subcategory.risk {
        case .safe:
            L10n.text(
                "切换此分组中的所有可操作项目。",
                "Toggle all actionable items in this group."
            )
        case .reviewOnly:
            L10n.text(
                "切换此黄色分组中的所有可操作项目；执行前仍需额外确认。",
                "Toggle all actionable items in this yellow group; execution still requires an extra confirmation."
            )
        case .protected:
            L10n.text(
                "切换此红色分组中的所有可操作项目；执行前仍需双重确认，且只会移入废纸篓。",
                "Toggle all actionable items in this red group; execution still requires two confirmations and only moves items to Trash."
            )
        case .informational:
            L10n.text(
                "切换此分组中的所有可操作项目。",
                "Toggle all actionable items in this group."
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                if subcategory.selectableCandidateIDs.isEmpty {
                    CleanupSelectionAvailabilityIndicator(risk: subcategory.risk)
                } else {
                    CleanupTriStateButton(
                        state: state,
                        isEnabled: session.outcome != .cancelled
                            && store.canEditV2CleanupSelection,
                        label: subcategory.title,
                        tint: CleanupRiskPresentation.tint(subcategory.risk),
                        enabledHint: selectionHint
                    ) {
                        BulkUpdateScope(rowCount: subcategory.selectableCandidateIDs.count).perform {
                            store.setCleanupCandidates(
                                subcategory.selectableCandidateIDs,
                                selected: state != .checked
                            )
                        }
                    }
                }

                Button {
                    toggleExpansion()
                } label: {
                    HStack(spacing: AppDesignTokens.Spacing.small) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(AppDesignTokens.Typography.compactSymbol)
                            .foregroundStyle(CleanupRiskPresentation.tint(subcategory.risk))
                            .frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: AppDesignTokens.Spacing.small) {
                                Text(subcategory.title)
                                    .font(AppDesignTokens.TypeScale.bodyEmphasis)
                                CleanupRecommendationBadge(level: displayedRecommendation)
                            }
                            // D45 / U3: one sentence on what it is and what to do.
                            Text(CleanupRiskPresentation.oneLineReason(subcategory.reason))
                                .font(AppDesignTokens.TypeScale.secondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(subcategory.reason)
                            Text(itemCountSummary)
                            .font(AppDesignTokens.TypeScale.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        }
                        Spacer(minLength: AppDesignTokens.Spacing.small)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(CleanupMeasurementPresentation.aggregateValue(candidates))
                                .font(AppDesignTokens.TypeScale.bodyEmphasis)
                                .monospacedDigit()
                            CleanupSuggestionChip(risk: subcategory.risk)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .accessibilityLabel(isExpanded
                    ? L10n.text("收起 \(subcategory.title)", "Collapse \(subcategory.title)")
                    : L10n.text("展开 \(subcategory.title)", "Expand \(subcategory.title)"))
                .accessibilityValue(isExpanded
                    ? L10n.text("已展开", "Expanded")
                    : L10n.text("已收起", "Collapsed"))

                AppIconButton(
                    title: L10n.text(
                        "查看 \(subcategory.title) 的判断依据",
                        "View evidence for \(subcategory.title)"
                    ),
                    systemImage: "info.circle"
                ) {
                    isShowingDetails.toggle()
                }
                .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                        HStack(spacing: AppDesignTokens.Spacing.small) {
                            Text(subcategory.title)
                                .font(AppDesignTokens.Typography.sectionTitle)
                            CleanupRiskBadge(risk: subcategory.risk)
                            CleanupRecommendationBadge(level: displayedRecommendation)
                        }
                        Text(subcategory.reason)
                            .font(AppDesignTokens.Typography.body)
                        Label(
                            CleanupRiskPresentation.guidance(subcategory),
                            systemImage: CleanupRiskPresentation.systemImage(subcategory.risk)
                        )
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(CleanupRiskPresentation.tint(subcategory.risk))
                    }
                    .padding(AppDesignTokens.Layout.sectionPadding)
                    .frame(width: 360, alignment: .leading)
                }
            }
            .padding(.leading, layout.cardPadding)
            .padding(.trailing, layout.cardPadding)
            .padding(.vertical, AppDesignTokens.Layout.compactPadding)

            if isExpanded {
                // §3.3: rows animate in only when a group is small enough.
                ForEach(candidates) { candidate in
                    Divider()
                        .padding(.leading, layout.cardPadding + 56)
                    CleanupCandidateRow(
                        store: store,
                        session: session,
                        candidate: candidate,
                        cleanupScopeIDs: cleanupScopeIDs
                    )
                }
                .transition(AppMotion.rowTransition(reduceMotion: reduceMotion))
            }
        }
        .appBulkAnimationGuard(rowCount: candidates.count)
        .background {
            SurfaceBackground(level: .card, cornerRadius: AppDesignTokens.Corner.card)
        }
#if DEBUG
        .layoutProbe("results.group.\(subcategory.id)")
#endif
#if DEBUG
        // Review screenshots of the debug fixture open the green groups too.
        .onAppear {
            if DebugSmartScanSessionFixture.expandsGreenTier, subcategory.risk == .safe {
                isExpanded = true
            }
        }
#endif
    }

    private func toggleExpansion() {
        // §3.3: expanding a group of more than 200 rows is not animated, and
        // under Reduce Motion the layout lands at once (§3.1).
        BulkUpdateScope(rowCount: candidates.count).perform(AppMotion.layout(reduceMotion: reduceMotion)) {
            isExpanded.toggle()
        }
    }
}

/// D100 G5: roots this scan could not read became readable after the app
/// came back. Only the user's click scans again (the page's own scope).
private struct CleanupAccessReturnBanner: View {
    @ObservedObject var store: ScanStore
    let notice: ScanAccessReturnNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.medium) {
            Label(notice.text, systemImage: "lock.open")
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.information)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L10n.text("重新扫描这些位置", "Scan These Locations")) { store.rescanAfterAccessReturn() }
                .appButtonChrome(.secondary)
                .disabled(store.isPreparingScan)
            AppIconButton(title: L10n.text("不再提示", "Dismiss"), systemImage: "xmark") {
                store.dismissAccessReturnNotice()
            }
        }
        .padding(AppDesignTokens.Layout.compactPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.information,
            prominence: .quiet
        )
    }
}

private struct CleanupCandidateRow: View {
    @Environment(\.windowLayoutMetrics) private var layout
    @ObservedObject var store: ScanStore
    let session: ScanSession
    let candidate: ScanCandidate
    /// The page's cleanup scope, used when "正常退出并清理" continues.
    var cleanupScopeIDs: Set<ScanCandidateID>? = nil
    var usesLightfield: Bool = false
    @State private var isShowingDetails = false

    private var isSelected: Bool {
        store.cleanupSelection.selectedCandidateIDs.contains(candidate.id)
    }

    private var canSelect: Bool {
        candidate.isSelectable
            && session.outcome != .cancelled
            && store.canEditV2CleanupSelection
            && !DuplicateApplicationRetentionPolicy.isProtected(candidate)
    }

    /// Round 3 (P2-1): the row's running owners, split into those that can
    /// be asked to quit and those that must be quit by hand.
    private var ownerQuitOptions: CleanupOwnerQuitService.Options {
        candidate.isOwnerRunning ? store.cleanupOwnerQuitOptions(for: candidate) : .init()
    }

    /// A2: only for a selected row whose owner app is running and can be asked
    /// to quit. Duplicate app copies are never offered (a running copy is kept).
    private var canQuitOwnerAndClean: Bool {
        store.cleanupFeatureConfiguration.mode == .v2Full
            && isSelected
            && canSelect
            && candidate.isOwnerRunning
            && candidate.ownerResolution != .applicationBundle
            && !ownerQuitOptions.quittable.isEmpty
    }

    private var selection: Binding<Bool> {
        Binding {
            isSelected
        } set: { selected in
            store.setCleanupCandidate(candidate.id, selected: selected)
        }
    }

    /// A running owner is a warning, shown apart from the path in the warning
    /// colour and never truncated (restored from V1 rows).
    private var lightfieldNote: String? {
        candidate.isOwnerRunning ? ownerStatusLine?.text : nil
    }

    /// D47's rebuild-cost hint stays first so middle truncation keeps it;
    /// "Belongs to X" (D93, rule provenance) follows, then the path.
    private var lightfieldDetail: String {
        CleanupRuleExplanation.lightfieldDetail(
            rebuildCost: CleanupCandidateRowHint.rebuildCost(for: candidate)?.text,
            reclaimable: CleanupCandidateRowHint.reclaimable(for: candidate)?.text,
            ownerStatus: lightfieldNote == nil ? ownerStatusLine?.text : nil,
            ownership: candidate.ruleExplanation.ownership,
            path: candidate.snapshot.standardizedPath
        )
    }

    private var lightfieldHelp: String {
        let parts: [String?] = [
            candidate.reason, ownerStatusLine?.text, developerArtifactLine,
            applicationVersionLine, CleanupCandidateRowHint.rebuildCost(for: candidate)?.text,
            CleanupCandidateRowHint.reclaimable(for: candidate)?.text,
            candidate.ruleExplanation.summary
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if usesLightfield { lightfieldRow } else { legacyRow }
        }
    }

    private var lightfieldRow: some View {
        FeatureLightfieldResultRow(title: candidate.sourceURL.lastPathComponent,
            detail: lightfieldDetail,
            value: CleanupMeasurementPresentation.value(candidate), note: lightfieldNote) {
            Button { selection.wrappedValue.toggle() } label: {
                FeatureLightfieldCheck(selected: isSelected, module: .green)
            }.buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(!canSelect)
                .accessibilityRepresentation {
                    Toggle(isOn: selection) { Text(accessibilitySummary) }.toggleStyle(.checkbox).disabled(!canSelect)
                }
                .accessibilityLabel(accessibilitySummary)
                .accessibilityValue(selectionAccessibilityValue)
                .accessibilityHint(selectionAccessibilityHint)
        }
        .contextMenu {
            Button(L10n.text("详细信息", "Details")) { isShowingDetails = true }
            Button(L10n.text("在访达中显示", "Show in Finder")) { store.revealCleanupCandidate(candidate) }
            if canQuitOwnerAndClean {
                Button(L10n.text("正常退出并清理", "Quit Normally and Clean")) {
                    store.requestQuitCleanupOwners(for: [candidate.id], cleanupScope: cleanupScopeIDs)
                }.disabled(store.isQuittingCleanupOwners)
            }
        }
        .popover(isPresented: $isShowingDetails) { candidateDetails }
        .help(lightfieldHelp)
    }

    private var legacyRow: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            Toggle(isOn: selection) {
                candidateContent
            }
            .toggleStyle(AnimatedCheckboxToggleStyle(tint: CleanupRiskPresentation.tint(candidate.risk)))
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .disabled(!canSelect)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(selectionAccessibilityValue)
            .accessibilityHint(selectionAccessibilityHint)

            if canQuitOwnerAndClean {
                Button(L10n.text("正常退出并清理", "Quit Normally and Clean")) {
                    store.requestQuitCleanupOwners(for: [candidate.id], cleanupScope: cleanupScopeIDs)
                }
                .appButtonChrome(.tertiary)
                .disabled(store.isQuittingCleanupOwners)
                .help(L10n.text(
                    "先列出将退出的应用并请你确认；只发送正常退出请求，不强制结束，然后检查并清理所选项目。",
                    "Lists the apps first for your confirmation, sends only a normal quit request (never a force quit), then checks and cleans the selection."
                ))
            }

            AppIconButton(
                title: L10n.text(
                    "查看 \(candidate.sourceURL.lastPathComponent) 的详细信息",
                    "View details for \(candidate.sourceURL.lastPathComponent)"
                ),
                systemImage: "info.circle"
            ) {
                isShowingDetails.toggle()
            }
            .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
                candidateDetails
            }

            AppIconButton(
                title: L10n.text(
                    "在访达中显示 \(candidate.sourceURL.lastPathComponent)",
                    "Show \(candidate.sourceURL.lastPathComponent) in Finder"
                ),
                systemImage: "folder"
            ) {
                store.revealCleanupCandidate(candidate)
            }
        }
        .padding(.leading, layout.cardPadding + 52)
        .padding(.trailing, layout.cardPadding)
        .padding(.vertical, 3)
        .frame(minHeight: layout.rowHeight)
        .background {
            if isSelected && canSelect {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CleanupRiskPresentation.tint(candidate.risk).opacity(0.10))
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
            }
        }
    }

    private var candidateContent: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Text(candidate.sourceURL.lastPathComponent)
                        .font(AppDesignTokens.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                    CleanupRecommendationBadge(
                        level: CleanupRecommendationDisplayPolicy.level(for: candidate)
                    )
                }
                if let developerArtifactLine {
                    Text(developerArtifactLine)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // D93: belongs to and why (not) preselected; the effect is in the
                // help text and the details popover.
                Text(L10n.text("属于 ", "Belongs to ") + candidate.ruleExplanation.ownership
                     + " · " + candidate.ruleExplanation.preselection)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let applicationVersionLine {
                    Text(applicationVersionLine)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let ownerStatusLine {
                    Label(ownerStatusLine.text, systemImage: ownerStatusLine.systemImage)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(ownerStatusLine.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // D47: a large preselected cache says what cleaning it costs.
                if let rebuildCost = CleanupCandidateRowHint.rebuildCost(for: candidate) {
                    Label(rebuildCost.text, systemImage: rebuildCost.systemImage)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(Self.style(for: rebuildCost.tone))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // D100 G1: the row frees noticeably less than its size.
                if let reclaimable = CleanupCandidateRowHint.reclaimable(for: candidate) {
                    Label(reclaimable.text, systemImage: reclaimable.systemImage)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(Self.style(for: reclaimable.tone))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(CleanupMeasurementPresentation.value(candidate))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
        .help(candidate.ruleExplanation.summary)
    }

    private var candidateDetails: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Text(candidate.sourceURL.lastPathComponent)
                    .font(AppDesignTokens.Typography.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)
                CleanupRiskBadge(risk: candidate.risk)
                CleanupRecommendationBadge(
                    level: CleanupRecommendationDisplayPolicy.level(for: candidate)
                )
            }
            if let tool = candidate.developerTool,
               let kind = candidate.developerArtifactKind {
                HStack(spacing: AppDesignTokens.Spacing.large) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("所属工具", "Tool"))
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                        Text(tool.displayName)
                            .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("残留类型", "Artifact Type"))
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                        Text(kind.displayName)
                            .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    }
                }
            }
            // D93: belongs to, effect after cleanup, why (not) preselected.
            CleanupRuleExplanationView(explanation: candidate.ruleExplanation)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("完整路径", "Full Path"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                Text(candidate.snapshot.standardizedPath)
                    .font(AppDesignTokens.Typography.metadata)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("判断依据", "Evidence"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                Text(candidate.reason)
                    .font(AppDesignTokens.Typography.body)
            }
            if candidate.categoryID == "developer" {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("创建时间", "Created"))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                    Text(developerCreationDetail)
                        .font(AppDesignTokens.Typography.body)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(developerActivityTitle)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                    Text(developerActivityDetail)
                        .font(AppDesignTokens.Typography.body)
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(CleanupMeasurementPresentation.status(candidate))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                Text(CleanupMeasurementPresentation.value(candidate))
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .monospacedDigit()
                if let detail = CleanupMeasurementPresentation.detail(candidate) {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reclaimable = CleanupCandidateRowHint.reclaimable(for: candidate) {
                    Label(reclaimable.text, systemImage: reclaimable.systemImage)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(Self.style(for: reclaimable.tone))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
        .frame(width: 380, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// D22/D47: an owner app that was running when the scan finished (the
    /// only row D47 leaves unchecked); item 10 and D47: a log row still written
    /// in the last 7 days or a cache whose app is unknown; D25: the duplicate
    /// copy that stays when every other copy is checked.
    private var ownerStatusLine: (text: String, systemImage: String, tint: AnyShapeStyle)? {
        // Round 3 (P2-7): a running copy, or the one the command line tools
        // use, is always kept.
        if DuplicateApplicationRetentionPolicy.isProtected(candidate) {
            return (
                candidate.isOwnerRunning
                    ? L10n.text("正在运行，将保留此副本；手动退出后才能选择", "Running, so this copy is kept; quit it by hand to select it")
                    : L10n.text("命令行工具当前使用的 Xcode，将保留此副本", "The Xcode the command line tools use; this copy is kept"),
                "checkmark.seal",
                AnyShapeStyle(AppDesignTokens.Palette.success)
            )
        }
        if candidate.isOwnerRunning {
            let options = ownerQuitOptions
            // Round 3 (P2-1): an app that cannot be asked to quit is named.
            if options.quittable.isEmpty, !options.manual.isEmpty {
                return (
                    CleanupOwnerQuitPresentation.manualQuitText(for: options.manual),
                    "hand.raised",
                    AnyShapeStyle(AppDesignTokens.Palette.warning)
                )
            }
            return (
                L10n.text("正在运行，清理前需退出", "Running; quit it before cleanup"),
                "app.badge",
                AnyShapeStyle(AppDesignTokens.Palette.warning)
            )
        }
        // Item 10 and D47: recent or unconfirmed log writes, an unidentified
        // owner. D47 preselects these rows; the line says why to look twice.
        if let hint = CleanupCandidateRowHint.ownerStatus(for: candidate) {
            return (hint.text, hint.systemImage, Self.style(for: hint.tone))
        }
        if isRetainedDuplicateCopy {
            return (
                L10n.text("将保留此副本", "This copy will be kept"),
                "checkmark.seal",
                AnyShapeStyle(AppDesignTokens.Palette.success)
            )
        }
        return nil
    }

    private static func style(for tone: CleanupCandidateRowHint.Tone) -> AnyShapeStyle {
        switch tone {
        case .warning: AnyShapeStyle(AppDesignTokens.Palette.warning)
        case .secondary: AnyShapeStyle(.secondary)
        }
    }

    /// P2-1: each duplicate copy shows its version and build, and the copy
    /// the command line tools use says so (round 3: without the command name).
    private var applicationVersionLine: String? {
        guard let summary = candidate.applicationVersionSummary else { return nil }
        guard candidate.isActiveDeveloperDirectory else { return summary }
        return summary + L10n.text(
            " · 命令行工具当前使用的 Xcode",
            " · the Xcode the command line tools use"
        )
    }

    private var isRetainedDuplicateCopy: Bool {
        guard !isSelected,
              let groupCode = candidate.duplicateApplicationGroupCode else { return false }
        let others = DuplicateApplicationRetentionPolicy.members(of: groupCode, in: session)
            .filter { $0.id != candidate.id }
        return !others.isEmpty && others.allSatisfy {
            store.cleanupSelection.selectedCandidateIDs.contains($0.id)
        }
    }

    private var developerActivitySummary: String? {
        guard candidate.categoryID == "developer" else { return nil }
        guard let latest = candidate.latestContentModificationTimeNanoseconds else {
            return L10n.text("最近修改时间不可用", "Latest modification time unavailable")
        }
        let days = DeveloperCleanupAgePolicy.inactivityDays(
            latestModificationTimeNanoseconds: latest,
            referenceDate: session.startedAt
        )
        return L10n.text("最近变动约 \(days) 天前", "Last changed about \(days) days ago")
    }

    private var developerArtifactLine: String? {
        guard candidate.categoryID == "developer" else { return nil }
        return [candidate.developerArtifactSummary, developerActivitySummary]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var developerActivityDetail: String {
        guard let date = candidate.latestContentModificationDate else {
            return L10n.text(
                "无法读取；按红色保护且不可执行。",
                "Unavailable; protected in red and not executable."
            )
        }
        let days = candidate.latestContentModificationTimeNanoseconds.map {
            DeveloperCleanupAgePolicy.inactivityDays(
                latestModificationTimeNanoseconds: $0,
                referenceDate: session.startedAt
            )
        } ?? 0
        // Tool logs are not graded by activity, so no threshold applies.
        guard candidate.developerArtifactKind != .logs else {
            return L10n.text(
                "\(date.formatted(date: .abbreviated, time: .shortened)) · 距扫描约 \(days) 天",
                "\(date.formatted(date: .abbreviated, time: .shortened)) · about \(days) days before scan"
            )
        }
        return L10n.text(
            "\(date.formatted(date: .abbreviated, time: .shortened)) · 距扫描约 \(days) 天 · 本次阈值 \(session.developerInactivityThresholdDays) 天",
            "\(date.formatted(date: .abbreviated, time: .shortened)) · about \(days) days before scan · \(session.developerInactivityThresholdDays)-day threshold"
        )
    }

    private var developerActivityTitle: String {
        L10n.text("最近活动", "Latest Activity")
    }

    private var developerCreationDetail: String {
        guard let nanoseconds = candidate.snapshot.identity.creationTimeNanoseconds else {
            return L10n.text("文件系统未提供创建时间", "Creation time unavailable")
        }
        let date = Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000)
        return L10n.text(
            "\(date.formatted(date: .abbreviated, time: .shortened)) · 目录创建时间，不代表首次安装时间",
            "\(date.formatted(date: .abbreviated, time: .shortened)) · folder creation time, not first install time"
        )
    }

    private var accessibilitySummary: String {
        let artifact = (candidate.developerArtifactSummary ?? applicationVersionLine)
            .map { "\($0)，" } ?? ""
        return L10n.text(
            "\(candidate.sourceURL.lastPathComponent)，\(artifact)\(CleanupMeasurementPresentation.value(candidate))，\(selectionAccessibilityValue)，\(eligibilityAccessibilityValue)。",
            "\(candidate.sourceURL.lastPathComponent), \(artifact)\(CleanupMeasurementPresentation.value(candidate)), \(selectionAccessibilityValue), \(eligibilityAccessibilityValue)."
        )
    }

    private var selectionAccessibilityValue: String {
        isSelected
            ? L10n.text("已选择", "selected")
            : L10n.text("未选择", "not selected")
    }

    private var eligibilityAccessibilityValue: String {
        switch candidate.selectionEligibility {
        case .selectable:
            L10n.text("可安全清理", "safe to clean")
        case .selectableWithReview:
            L10n.text("可手动选择，执行前需要风险确认", "manually selectable with risk confirmation")
        case .selectableWithProtectedReview:
            L10n.text("可手动选择，执行前需要双重高风险确认", "manually selectable with two high-risk confirmations")
        case .selectableWithPermanentDeletionReview:
            L10n.text("可手动选择，执行前需要单独二次确认，永久删除不可恢复", "manually selectable with two separate confirmations; permanent deletion cannot be undone")
        case .reviewRequired:
            L10n.text("需要人工判断", "manual review required")
        case .protected:
            L10n.text("受保护", "protected")
        case .readOnly:
            L10n.text("仅供查看", "read only")
        case .unavailable:
            L10n.text("当前不可选择", "currently unavailable")
        }
    }

    private var selectionAccessibilityHint: String {
        if candidate.measurementCompleteness.isFailed {
            return CleanupMeasurementPresentation.detail(candidate)
                ?? L10n.text("容量无法计算，不能加入清理计划。", "The size could not be measured, so this item cannot enter a cleanup plan.")
        }
        if candidate.isOwnerRunning {
            return L10n.text(
                "所属应用正在运行，清理前需退出；运行中会被跳过。按空格切换选择。",
                "Its app is running; quit it before cleanup, or the item is skipped. Press Space to toggle selection."
            )
        }
        if canSelect {
            switch candidate.selectionEligibility {
            case .selectableWithPermanentDeletionReview:
                return L10n.text(
                    "按空格切换选择；清空废纸篓执行前需要单独二次确认，删除不可恢复。",
                    "Press Space to toggle; emptying the Trash needs two separate confirmations and cannot be undone."
                )
            case .selectableWithReview:
                return L10n.text(
                    "按空格切换选择；黄色项目在执行前还需要风险确认。文件夹按钮只在访达中显示。",
                    "Press Space to toggle; yellow items need another risk confirmation before execution. The folder button only reveals in Finder."
                )
            case .selectableWithProtectedReview:
                return L10n.text(
                    "按空格切换选择；红色项目默认不选，执行前需要双重高风险确认，且只会移入废纸篓。",
                    "Press Space to toggle; red items are off by default, need two high-risk confirmations, and only move to Trash."
                )
            default:
                break
            }
        }
        return canSelect
            ? L10n.text("按空格切换选择；文件夹按钮只在访达中显示。", "Press Space to toggle selection; the folder button only reveals the item in Finder.")
            : L10n.text("此项目不能加入清理计划。", "This item cannot be added to the cleanup plan.")
    }

}

/// Shown in place of a checkbox when a group has nothing to clean. D19: every
/// listed item can be selected, so this only appears for an empty tier.
private struct CleanupSelectionAvailabilityIndicator: View {
    let risk: CleanupRisk

    private var title: String {
        L10n.text("此分组没有可清理的项目", "No cleanable items in this group")
    }

    var body: some View {
        Image(systemName: "square.dashed")
            .font(AppDesignTokens.Typography.compactSymbol)
            .foregroundStyle(AppDesignTokens.Palette.secondaryText)
            .frame(width: 28, height: 28)
            .accessibilityLabel(title)
            .help(title)
    }
}

private struct CleanupTriStateButton: View {
    let state: TriStateSelection
    let isEnabled: Bool
    let label: String
    var tint: Color = AppDesignTokens.Palette.accent
    var enabledHint: String? = nil
    var disabledHint: String? = nil
    let action: () -> Void

    private var systemImage: String {
        switch state {
        case .unchecked:
            return "square"
        case .checked:
            return "checkmark.square.fill"
        case .mixed:
            return "minus.square.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            AnimatedCheckmarkBox(
                mark: state == .unchecked ? .off : (state == .checked ? .on : .mixed),
                tint: tint,
                side: 18
            )
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help(systemImage == "square" ? label : label)
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isEnabled
            ? enabledHint ?? L10n.text("按空格切换此分组的选择状态。", "Press Space to toggle this group's selection.")
            : disabledHint ?? L10n.text("此分组没有可选择项目。", "This group has no selectable items."))
        .help(isEnabled ? label : disabledHint ?? label)
    }

    private var accessibilityValue: String { state.cleanupAccessibilityValue }
}

extension TriStateSelection {
    /// Spoken selection state of a cleanup group, shared by V1 and D67 rows.
    var cleanupAccessibilityValue: String {
        switch self {
        case .unchecked:
            return L10n.text("未选择", "Not selected")
        case .checked:
            return L10n.text("已选择", "Selected")
        case .mixed:
            return L10n.text("部分选择", "Partially selected")
        }
    }
}

private struct CleanupResultSummaryCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppDesignTokens.Typography.inlineTitle)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(AppDesignTokens.Layout.compactPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.rowRadius,
            tint: tint,
            prominence: .quiet
        )
    }
}

private struct CleanupSpaceMetric: View {
    @Environment(\.windowLayoutMetrics) private var layout
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Group {
            if layout.density == .compact {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: AppDesignTokens.Spacing.small) {
                        metricIcon(size: 26)
                        Text(title)
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    metricText
                }
            } else {
                HStack(spacing: AppDesignTokens.Spacing.medium) {
                    metricIcon(size: 34)
                    metricText
                    Spacer()
                }
            }
        }
        .padding(layout.density == .compact ? layout.cardPadding : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: tint,
            prominence: .quiet
        )
    }

    private func metricIcon(size: CGFloat) -> some View {
        Image(systemName: systemImage)
            .font(AppDesignTokens.Typography.sectionTitle)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private var metricText: some View {
        VStack(alignment: .leading, spacing: 2) {
            if layout.density == .regular {
                Text(title)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(value)
                .font(AppDesignTokens.Typography.inlineTitle)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(detail)
        }
    }
}

private struct CleanupRiskBadge: View {
    let risk: CleanupRisk

    var body: some View {
        Text(CleanupRiskPresentation.title(risk))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(CleanupRiskPresentation.tint(risk))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                CleanupRiskPresentation.tint(risk).opacity(0.12),
                in: Capsule()
            )
    }
}

enum CleanupRiskPresentation {
    static func title(_ risk: CleanupRisk) -> String {
        switch risk {
        case .safe:
            L10n.text("安全候选", "Safe")
        case .reviewOnly:
            L10n.text("需要确认", "Review")
        case .protected:
            L10n.text("高风险", "High Risk")
        case .informational:
            L10n.text("信息", "Information")
        }
    }

    static func tint(_ risk: CleanupRisk) -> Color {
        switch risk {
        case .safe:
            AppDesignTokens.Palette.success
        case .reviewOnly:
            AppDesignTokens.Palette.warning
        case .protected:
            AppDesignTokens.Palette.destructive
        case .informational:
            AppDesignTokens.Palette.information
        }
    }

    static func systemImage(_ risk: CleanupRisk) -> String {
        switch risk {
        case .safe:
            "checkmark.shield.fill"
        case .reviewOnly:
            "exclamationmark.triangle.fill"
        case .protected:
            "exclamationmark.octagon.fill"
        case .informational:
            "info.circle.fill"
        }
    }

    static func guidance(_ subcategory: CleanupScanSubcategory) -> String {
        switch subcategory.risk {
        case .safe:
            if subcategory.candidates.contains(where: { !$0.ownerBundleIdentifiers.isEmpty }) {
                return L10n.text(
                    "所属应用未运行时默认勾选；清理前请退出相关应用，运行中的会被跳过。清理后首次启动或构建可能较慢。",
                    "Selected by default while the owning app is closed; quit related apps first, or running ones are skipped. The next launch or build may be slower."
                )
            }
            return L10n.text(
                "确认不再需要后勾选；执行时仍会再次核对文件身份并移至废纸篓。",
                "Select only after review; execution rechecks identity and moves items to Trash."
            )
        case .reviewOnly:
            return L10n.text(
                "先确认内容、所属应用和备份；手动选择后仍需风险确认，并只会移到废纸篓。",
                "Confirm content, owning app, and backup first; manual selection still needs risk confirmation and only moves to Trash."
            )
        case .protected:
            if subcategory.candidates.contains(where: { $0.categoryID == "developer" }) {
                return L10n.text(
                    "最近仍有活动，默认不选。确认当前任务不再使用且已有必要备份后，可逐项选择；执行前需要双重确认。",
                    "Recently active and off by default. After confirming no current task uses it and required backups exist, select it individually; execution needs two confirmations."
                )
            }
            if subcategory.candidates.contains(where: { $0.action.permanentlyDeletes }) {
                return L10n.text(
                    "默认不选。只永久删除扫描时废纸篓里已有的项目，执行前单独二次确认，不可恢复。",
                    "Off by default. Only items already in the Trash during the scan are permanently deleted, after two separate confirmations; this cannot be undone."
                )
            }
            return L10n.text(
                "默认不选。重复安装的应用副本整组勾选时自动保留一份；执行前需要双重确认，并只会移入废纸篓。删除应用本身请使用“卸载”页。",
                "Off by default. Checking a whole group of duplicate app copies keeps one copy; two confirmations are required and copies only move to Trash. To remove an app itself, use Uninstall."
            )
        case .informational:
            return L10n.text("仅作容量参考。", "For capacity reference only.")
        }
    }
}

/// D45 / U3 suggestion words (柠檬 pattern): green → 建议清理,
/// yellow → 需人工判断, red → 谨慎. Presentation of the existing tiers only;
/// selection and confirmation rules are unchanged.
struct CleanupSuggestionChip: View {
    let risk: CleanupRisk

    var body: some View {
        let tint = CleanupRiskPresentation.tint(risk)
        Text(CleanupRiskPresentation.suggestion(risk))
            .font(AppDesignTokens.TypeScale.captionEmphasis)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.30), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel(CleanupRiskPresentation.suggestion(risk))
    }
}

extension CleanupRiskPresentation {
    static func suggestion(_ risk: CleanupRisk) -> String {
        switch risk {
        case .safe: L10n.text("建议清理", "Recommended")
        case .reviewOnly: L10n.text("需人工判断", "Needs Review")
        case .protected: L10n.text("谨慎", "Caution")
        case .informational: L10n.text("仅供查看", "View Only")
        }
    }

    /// The first sentence of a rule's reason, for the one-line row note.
    static func oneLineReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators: [Character] = ["。", "；", ";"]
        if let end = trimmed.firstIndex(where: { separators.contains($0) }) {
            return String(trimmed[..<end])
        }
        if let range = trimmed.range(of: ". ") {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }
}

/// A category tile of the results bento: tile, name, size, row count and
/// the green / yellow / red mix of its bytes.
private struct CleanupCategoryBentoCard: View {
    @AppSurfaces private var surfaces
    let category: CleanupScanCategory
    let action: () -> Void

    private var parts: [(CleanupRisk, Int64)] {
        [CleanupRisk.safe, .reviewOnly, .protected].map { risk in
            (risk, category.candidates
                .filter { $0.risk == risk && !$0.action.permanentlyDeletes }
                .reduce(Int64(0)) { CleanupByteCount.adding($1.estimatedSizeBytes, to: $0) })
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconTile(systemImage: Self.symbol(for: category), side: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .font(AppDesignTokens.TypeScale.bodyEmphasis)
                            .foregroundStyle(surfaces.textPrimary)
                            .lineLimit(1)
                        Text(L10n.items(category.candidates.count))
                            .font(AppDesignTokens.TypeScale.caption)
                            .foregroundStyle(surfaces.textTertiary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                Text(CleanupMeasurementPresentation.aggregateValue(category.candidates))
                    .font(AppDesignTokens.TypeScale.metricInline)
                    .foregroundStyle(surfaces.textPrimary)
                    .lineLimit(1)
                mixBar
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { SurfaceBackground(level: .card, cornerRadius: AppDesignTokens.Corner.card) }
            .contentShape(RoundedRectangle(cornerRadius: AppDesignTokens.Corner.card, style: .continuous))
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .appHoverLift()
        .help(category.title)
        .accessibilityLabel("\(category.title), \(CleanupMeasurementPresentation.aggregateValue(category.candidates))")
        .accessibilityHint(L10n.text("定位到它所在的风险分组，不会改变选择。", "Moves to its risk group without changing selection."))
    }

    private var mixBar: some View {
        let total = max(1, parts.reduce(Int64(0)) { $0 + $1.1 })
        return GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(parts.filter { $0.1 > 0 }, id: \.0.rawValue) { risk, bytes in
                    Capsule(style: .continuous)
                        .fill(CleanupRiskPresentation.tint(risk))
                        .frame(width: max(4, proxy.size.width * CGFloat(Double(bytes) / Double(total)) - 2))
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    static func symbol(for category: CleanupScanCategory) -> String {
        switch category.id {
        case "system": "gearshape.2.fill"
        case "application-cache": "square.stack.3d.up.fill"
        case "browser-cache": "globe"
        case "developer": "hammer.fill"
        case "logs": "doc.text.fill"
        case "mail": "envelope.fill"
        case "trash": "trash.fill"
        case "downloads": "arrow.down.circle.fill"
        case "verified-duplicates", "applications": "square.on.square.fill"
        default: "folder.fill"
        }
    }
}

/// Counts bytes up from zero once, then follows later values (§3.2.4).
/// Reduce Motion shows the final value at once.
struct AnimatedByteCount: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0
    let bytes: Int64

    var body: some View {
        ByteCountText(value: shown)
            .onAppear { animate(to: Double(bytes), fromZero: true) }
            .onChange(of: bytes) { _, value in animate(to: Double(value), fromZero: false) }
            .accessibilityLabel(ByteFormat.storageString(bytes))
    }

    private func animate(to value: Double, fromZero: Bool) {
        guard let animation = AppMotion.resolved(.data, reduceMotion: reduceMotion) else {
            shown = value
            return
        }
        if fromZero { shown = 0 }
        withAnimation(animation) { shown = value }
    }
}

private struct ByteCountText: View, @preconcurrency Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(ByteFormat.storageString(Int64(max(0, value.rounded()))))
            .monospacedDigit()
    }
}

/// D216: the classic list's two closing disclosures (emptying the Trash, the
/// scan details) as one button each — the title and the row-end arrow — so
/// VoiceOver reads their names and state. Their `DisclosureGroup` triangles
/// had no name in the accessibility tree and were read as “disclosure
/// triangle” (second report, 5.2 #12).
struct CleanupListDisclosure<Content: View>: View {
    let title: String
    var probe: String? = nil
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    FeatureLightfieldDisclosureChevron(expanded: isExpanded,
                                                       probe: probe.map { $0 + ".chevron" })
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? L10n.text("已展开", "Expanded") : L10n.text("已收起", "Collapsed"))
#if DEBUG
            .layoutProbe(probe ?? "lightfield.cleanup.disclosure")
#endif
            if isExpanded {
                content
            }
        }
    }
}
