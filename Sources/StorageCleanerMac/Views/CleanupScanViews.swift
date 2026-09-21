import SwiftUI

struct CleanupScanOverviewView: View {
    @ObservedObject var store: ScanStore
    let session: ScanSession

    var body: some View {
        CleanupScanResultsView(
            store: store,
            filter: .overview,
            session: session
        )
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

struct CleanupScanResultsView: View {
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ObservedObject var store: ScanStore
    let filter: ReviewFilter
    let session: ScanSession
    @State private var resultFilter: CleanupResultFilter = .all
    @State private var sortOrder: CleanupResultSort = .largest
    @State private var isSecondaryDetailsExpanded = false
    @State private var expandedRiskTierIDs: Set<String> = []

    private var categories: [CleanupScanCategory] {
        filter == .devCaches
            ? session.categories.filter { $0.id == "developer" }
            : session.categories
    }

    private var candidates: [ScanCandidate] { categories.flatMap(\.candidates) }

    /// Only selectable candidates may be described as safe-to-clean. Review
    /// and protected items stay visible in their own summary instead of being
    /// folded into the primary cleanup number.
    private var safeCandidates: [ScanCandidate] {
        candidates.filter { $0.risk == .safe && $0.isSelectable }
    }

    private var reviewCandidates: [ScanCandidate] {
        candidates.filter { $0.risk == .reviewOnly }
    }

    private var actionableReviewCandidates: [ScanCandidate] {
        reviewCandidates.filter(\.isSelectable)
    }

    private var advisoryReviewCandidates: [ScanCandidate] {
        reviewCandidates.filter { !$0.isSelectable }
    }

    private var protectedCandidates: [ScanCandidate] {
        candidates.filter { $0.risk == .protected }
    }

    private var actionableProtectedCandidates: [ScanCandidate] {
        protectedCandidates.filter(\.isSelectable)
    }

    private var protectedReferenceCandidates: [ScanCandidate] {
        protectedCandidates.filter { !$0.isSelectable }
    }

    private func decisionCount(for risk: CleanupRisk) -> Int {
        categories.reduce(0) { count, category in
            count + category.subcategories.filter {
                $0.risk == risk && !$0.candidates.isEmpty
            }.count
        }
    }

    private func selectedDecisionCount(for risk: CleanupRisk) -> Int {
        categories.reduce(0) { count, category in
            count + category.subcategories.filter { subcategory in
                subcategory.risk == risk
                    && !subcategory.selectableCandidateIDs.isEmpty
                    && store.cleanupSelection.state(
                        for: subcategory.selectableCandidateIDs
                    ) != .unchecked
            }.count
        }
    }

    private func selectableDecisionCount(for risk: CleanupRisk) -> Int {
        categories.reduce(0) { count, category in
            count + category.subcategories.filter { subcategory in
                subcategory.risk == risk
                    && !subcategory.selectableCandidateIDs.isEmpty
            }.count
        }
    }

    private var safeBytes: Int64 {
        CleanupByteCount.sum(safeCandidates.map(\.estimatedSizeBytes))
    }

    private var reviewBytes: Int64 {
        CleanupByteCount.sum(actionableReviewCandidates.map(\.estimatedSizeBytes))
    }

    private var protectedBytes: Int64 {
        CleanupByteCount.sum(protectedCandidates.map(\.estimatedSizeBytes))
    }

    private var selectedBytes: Int64 {
        let candidateIDs = Set(categories.flatMap(\.selectableCandidateIDs))
        return store.cleanupSelection.selectedCandidates(in: session)
            .filter { candidateIDs.contains($0.id) }
            .reduce(0) { CleanupByteCount.adding($1.estimatedSizeBytes, to: $0) }
    }

    private var recommendedCount: Int {
        categories.flatMap(\.candidates)
            .filter {
                $0.isSelectable
                    && $0.defaultSelection != .forbidden
                    && $0.recommendation.level == .recommended
            }
            .count
    }

    private var safeSelectableCount: Int {
        candidates.filter { $0.risk == .safe && $0.isSelectable }.count
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
        }
    }

    private var selectedCount: Int {
        [CleanupRisk.safe, .reviewOnly, .protected].reduce(0) {
            $0 + selectedDecisionCount(for: $1)
        }
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
            selectionScopeIDs.contains($0.id) && $0.risk == .protected
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
        let matching = categories.flatMap { category in
            category.subcategories.filter { subcategory in
                subcategory.risk == risk
                    && subcategory.candidates.contains(where: matchesCurrentFilter)
            }
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
        Set(candidates.filter { $0.risk == risk && $0.isSelectable }.map(\.id))
    }

    var body: some View {
        SmartScanPageShell {
            resultHeader
                .padding(.bottom, AppDesignTokens.Spacing.small)
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: layout.sectionSpacing) {
                        riskSummary { risk in
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
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
                                    "目录内最近一次可读修改超过一年；默认选中，执行前仍会确认。",
                                    "The latest readable change inside the folder is over one year old; selected by default and still confirmed before cleanup."
                                )
                                : L10n.text(
                                    "可重新生成；已按现有安全规则默认选择，执行前仍会确认。",
                                    "Regenerable and selected by the existing safety rules; still confirmed before cleanup."
                                )
                        )
                        tierSection(
                            risk: .reviewOnly,
                            title: L10n.text("黄色 · 需要人工判断", "Yellow · Manual Review"),
                            detail: filter == .devCaches
                                ? L10n.text(
                                    "可重新生成缓存超过 \(session.developerInactivityThresholdDays) 天但未满一年时可人工判断；日志、会话与检查点只读展示，不能加入清理计划。",
                                    "Regenerable caches older than \(session.developerInactivityThresholdDays) days but under one year can be reviewed; logs, sessions, and checkpoints remain read-only and cannot enter a cleanup plan."
                                )
                                : L10n.text(
                                    "默认不选；可逐项核对并手动加入带额外确认的计划。",
                                    "Off by default; review individual items before adding them to a separately confirmed plan."
                                )
                        )
                        tierSection(
                            risk: .protected,
                            title: L10n.text("红色 · 高风险", "Red · High Risk"),
                            detail: filter == .devCaches
                                ? L10n.text(
                                    "最近 \(session.developerInactivityThresholdDays) 天内有变动；默认不选，可按分组或逐项选择，执行前仍需双重确认。",
                                    "Changed within the last \(session.developerInactivityThresholdDays) days; off by default, selectable by group or item, and requires two confirmations before execution."
                                )
                                : L10n.text(
                                    "默认不选；核对版本、用途和备份后可手动选择，执行前需要双重确认。",
                                    "Off by default; after checking versions, purpose, and backups, you may select manually with two confirmations before execution."
                                )
                        )
                        secondaryDetailsSection
                            .id("scan-coverage-details")
                    }
                    .padding(.top, AppDesignTokens.Spacing.small)
                    .padding(.bottom, AppDesignTokens.Spacing.medium)
                }
                .scrollIndicators(.automatic)
            }
        } footer: {
            cleanupActionBar
        }
    }

    private var resultHeader: some View {
        AppPageHeader(
            title: filter.sidebarTitle,
            subtitle: resultHeaderSubtitle,
            systemImage: filter.systemImage,
            isHero: true
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

    private var resultHeaderSubtitle: String {
        switch session.outcome {
        case .complete:
            L10n.text("扫描完成 · 请审阅结果", "Scan complete · Review results")
        case .partial:
            L10n.text("扫描结束 · 部分结果可供审阅", "Scan finished · Partial results available")
        case .cancelled:
            L10n.text("扫描已取消 · 保留已完成结果", "Scan cancelled · Completed results kept")
        }
    }

    private var resultDetailedSummary: String {
        let advisorySuffix = advisoryReviewCandidates.isEmpty
            ? ""
            : L10n.text(
                "，另识别出 \(CleanupMeasurementPresentation.aggregateValue(advisoryReviewCandidates)) 仅供查看",
                "; another \(CleanupMeasurementPresentation.aggregateValue(advisoryReviewCandidates)) is shown for reference only"
            )
        let summary = L10n.text(
            "扫描完成：发现 \(ByteFormat.string(safeBytes)) 可安全清理，另有 \(CleanupMeasurementPresentation.aggregateValue(actionableReviewCandidates)) 需要人工判断\(advisorySuffix)。",
            "Scan complete: \(ByteFormat.string(safeBytes)) is safe to clean and \(CleanupMeasurementPresentation.aggregateValue(actionableReviewCandidates)) needs review\(advisorySuffix)."
        )
        guard let outcomeNotice else { return summary }
        return "\(summary) · \(outcomeNotice)"
    }

    private var selectionHeaderSummary: String {
        L10n.text(
            "已选择 \(selectedCount) 项 · \(ByteFormat.string(selectedBytes))",
            "\(selectedCount) selected · \(ByteFormat.string(selectedBytes))"
        )
    }

    private var outcomeNotice: String? {
        switch session.outcome {
        case .complete:
            nil
        case .partial:
            if filter == .devCaches,
               session.includedCategoryIDs == ["developer"],
               session.metrics.timedOutRuleCount == 0,
               session.metrics.permissionFailureCount == 0,
               session.metrics.failedMeasurementCandidateCount == 0 {
                L10n.text(
                    "会话与检查点仅采集顶层元数据",
                    "Sessions and checkpoints use top-level metadata only"
                )
            } else {
                L10n.text("部分范围已因安全边界跳过", "Some scopes were safely skipped")
            }
        case .cancelled:
            L10n.text("仅显示已完成的只读结果", "Only completed read-only results are shown")
        }
    }

    private func riskSummary(
        onSelect: @escaping (CleanupRisk) -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: layout.cardSpacing) {
                ForEach([CleanupRisk.safe, .reviewOnly, .protected], id: \.rawValue) { risk in
                    riskSummaryButton(risk: risk, action: { onSelect(risk) })
                        .frame(minWidth: 200)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: layout.cardSpacing)], spacing: layout.cardSpacing) {
                ForEach([CleanupRisk.safe, .reviewOnly, .protected], id: \.rawValue) { risk in
                    riskSummaryButton(risk: risk, action: { onSelect(risk) })
                }
            }
        }
    }

    private func riskSummaryButton(
        risk: CleanupRisk,
        action: @escaping () -> Void
    ) -> some View {
        let tint = CleanupRiskPresentation.tint(risk)
        let count = decisionCount(for: risk)
        let selection = riskSelectionSummary(risk: risk)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: CleanupRiskPresentation.systemImage(risk))
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 22))
                        .foregroundStyle(tint)
                        .frame(width: 40, height: 40)
                        .background(tint.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(riskTitle(risk))
                            .font(AppDesignTokens.Typography.compactLabelEmphasis)
                        Text(riskValueText(risk))
                            .font(.system(size: 23, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .help(riskValueText(risk))
                    }
                    Spacer(minLength: 0)
                }
                Text("\(count) · \(selection)")
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AppDesignTokens.Layout.compactPadding)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(
                cornerRadius: AppDesignTokens.Layout.cardRadius,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppDesignTokens.Layout.cardRadius,
                    style: .continuous
                )
                .stroke(
                    tint.opacity(colorSchemeContrast == .increased ? 0.82 : 0.34),
                    lineWidth: colorSchemeContrast == .increased ? 2 : 1
                )
                .accessibilityHidden(true)
            }
        }
        .buttonStyle(ResponsivePlainButtonStyle())
#if DEBUG
        .layoutProbe(LayoutProbeID.cleanupRiskSummary(risk))
#endif
        .accessibilityLabel(L10n.text(
            "\(riskTitle(risk))，\(count) 项，\(riskValueText(risk))，\(selection)",
            "\(riskTitle(risk)), \(count) items, \(riskValueText(risk)), \(selection)"
        ))
        .accessibilityHint(L10n.text(
            "定位到此风险分组，不会改变选择。",
            "Moves to this risk group without changing selection."
        ))
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
        let valueCandidates: [ScanCandidate]
        switch risk {
        case .safe: valueCandidates = safeCandidates
        case .reviewOnly: valueCandidates = actionableReviewCandidates
        case .protected: valueCandidates = protectedCandidates
        case .informational: valueCandidates = candidates.filter { $0.risk == risk }
        }
        return CleanupMeasurementPresentation.aggregateValue(valueCandidates)
    }

    private func riskSelectionSummary(risk: CleanupRisk) -> String {
        let selectableCount = selectableDecisionCount(for: risk)
        guard selectableCount > 0 else {
            return L10n.text("无可操作项目", "No actionable items")
        }
        return L10n.text(
            "已选 \(selectedDecisionCount(for: risk))/\(selectableCount) 个可操作分组",
            "\(selectedDecisionCount(for: risk))/\(selectableCount) actionable groups selected"
        )
    }

    @ViewBuilder
    private var summaryCards: some View {
        LazyVGrid(columns: summaryGridColumns, spacing: layout.cardSpacing) {
            if !safeCandidates.isEmpty {
                CleanupResultSummaryCard(
                    title: L10n.text("可安全清理", "Safe to Clean"),
                    value: ByteFormat.string(safeBytes),
                    detail: L10n.items(safeCandidates.count),
                    tint: AppDesignTokens.Palette.success
                )
            }
            if !actionableReviewCandidates.isEmpty {
                CleanupResultSummaryCard(
                    title: L10n.text("需要人工判断", "Manual Review"),
                    value: CleanupMeasurementPresentation.aggregateValue(actionableReviewCandidates),
                    detail: L10n.items(actionableReviewCandidates.count),
                    tint: AppDesignTokens.Palette.warning
                )
            }
            if !advisoryReviewCandidates.isEmpty {
                CleanupResultSummaryCard(
                    title: L10n.text("只读参考", "Read-only Reference"),
                    value: CleanupMeasurementPresentation.aggregateValue(advisoryReviewCandidates),
                    detail: L10n.items(advisoryReviewCandidates.count),
                    tint: AppDesignTokens.Palette.information
                )
            }
            if !protectedCandidates.isEmpty {
                CleanupResultSummaryCard(
                    title: L10n.text("红色高风险", "Red High Risk"),
                    value: CleanupMeasurementPresentation.aggregateValue(protectedCandidates),
                    detail: protectedSelectionSummary,
                    tint: AppDesignTokens.Palette.destructive
                )
            }
        }
    }

    private var protectedSelectionSummary: String {
        let actionable = actionableProtectedCandidates.count
        let protected = protectedReferenceCandidates.count
        if actionable > 0, protected > 0 {
            return L10n.text(
                "\(actionable) 项可选择 · \(protected) 项受保护",
                "\(actionable) selectable · \(protected) protected"
            )
        }
        if actionable > 0 {
            return L10n.text(
                "\(actionable) 项可手动选择",
                "\(actionable) manually selectable"
            )
        }
        return L10n.text(
            "\(protected) 项受保护",
            "\(protected) protected"
        )
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
                "已勾选 \(selectedCount)/\(decisionItemCount) 项",
                "\(selectedCount) of \(decisionItemCount) selected"
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

    private var selectionMenu: some View {
            Menu {
                Button {
                    store.selectRecommendedCleanupCandidates()
                } label: {
                    Label(L10n.text("选择推荐项目", "Select Recommended"), systemImage: "checkmark.square")
                }
                .disabled(!store.canEditV2CleanupSelection || session.outcome == .cancelled || recommendedCount == 0)

                Button {
                    store.restoreDefaultCleanupSelection()
                } label: {
                    Label(L10n.text("恢复默认选择", "Restore Default Selection"), systemImage: "arrow.uturn.backward.square")
                }
                .disabled(!store.canEditV2CleanupSelection || selectedLeafCount == 0)

                Button {
                    store.selectAllCleanupCandidates()
                } label: {
                    Label(L10n.text("全选绿色", "Select All Green"), systemImage: "checkmark.square")
                }
                .disabled(!store.canEditV2CleanupSelection || session.outcome == .cancelled || safeSelectableCount == 0)

                Button {
                    store.clearCleanupCandidates()
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
                        value: ByteFormat.string(system.diskTotalBytes),
                        detail: system.diskName,
                        systemImage: "internaldrive",
                        tint: AppDesignTokens.Palette.storage
                    )
                    CleanupSpaceMetric(
                        title: L10n.text("已使用", "Used"),
                        value: ByteFormat.string(system.diskUsedBytes),
                        detail: L10n.text("系统报告值", "System reported"),
                        systemImage: "chart.pie.fill",
                        tint: AppDesignTokens.Palette.information
                    )
                    CleanupSpaceMetric(
                        title: L10n.text("可用空间", "Available"),
                        value: ByteFormat.string(system.diskFreeBytes),
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
                        value: ByteFormat.string(safeBytes),
                        tint: AppDesignTokens.Palette.success
                    )
                    CleanupStorageLegend(
                        title: L10n.text("黄色待判断", "Yellow review"),
                        value: CleanupMeasurementPresentation.aggregateValue(reviewCandidates),
                        tint: AppDesignTokens.Palette.warning
                    )
                    CleanupStorageLegend(
                        title: L10n.text("红色受保护", "Red protected"),
                        value: CleanupMeasurementPresentation.aggregateValue(protectedCandidates),
                        tint: AppDesignTokens.Palette.destructive
                    )
                    CleanupStorageLegend(
                        title: L10n.text("其余已用", "Other used"),
                        value: ByteFormat.string(max(
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
                    "先处理低风险高收益项目，再人工核对黄色内容；红色项目不直接删除。",
                    "Handle low-risk, high-value items first, then review yellow items; never directly delete red items."
                ),
                systemImage: "checklist"
            )
            VStack(spacing: 0) {
                CleanupReportAdviceRow(
                    number: 1,
                    title: L10n.text("先确认默认勾选的绿色项目", "Review the selected green items first"),
                    detail: L10n.text(
                        "当前可安全清理 \(ByteFormat.string(safeBytes))；实际执行仍经过预检、确认和废纸篓。",
                        "\(ByteFormat.string(safeBytes)) is safe to review; execution still uses preflight, confirmation, and Trash."
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
                    title: L10n.text("通过正规入口处理红色项目", "Use supported flows for red items"),
                    detail: L10n.text(
                        "大型应用请使用卸载器或系统入口，不手动删除容器和关联数据。",
                        "Use uninstallers or system controls for large apps; do not hand-delete containers or related data."
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
                        state: store.cleanupSelection.state(for: Array(tierSelectionIDs)),
                        isEnabled: session.outcome != .cancelled
                            && store.canEditV2CleanupSelection,
                        label: riskSelectionLabel(
                            risk,
                            selectableCount: tierSelectionIDs.count
                        ),
                        tint: tint,
                        enabledHint: riskSelectionHint(risk)
                    ) {
                        let state = store.cleanupSelection.state(for: Array(tierSelectionIDs))
                        store.setCleanupCandidates(
                            Array(tierSelectionIDs),
                            selected: state != .checked
                        )
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
            .glassPanel(
                cornerRadius: AppDesignTokens.Layout.cardRadius,
                tint: tint,
                prominence: .quiet
            )

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
                        ForEach(tierSubcategories) { subcategory in
                            CleanupSubcategorySelectionView(
                                store: store,
                                session: session,
                                subcategory: subcategory,
                                candidates: sortedCandidates(in: subcategory)
                            )
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
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
                "全部可操作的绿色项目（\(selectableCount) 项）",
                "All actionable green items (\(selectableCount))"
            )
        case .reviewOnly:
            L10n.text(
                "全部可操作的黄色项目（\(selectableCount) 项）",
                "All actionable yellow items (\(selectableCount))"
            )
        case .protected:
            L10n.text(
                "全部可操作的红色高风险项目（\(selectableCount) 项）",
                "All actionable red high-risk items (\(selectableCount))"
            )
        case .informational:
            L10n.text(
                "全部可操作的信息项目（\(selectableCount) 项）",
                "All actionable informational items (\(selectableCount))"
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

    private func toggleTierExpansion(_ risk: CleanupRisk) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
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
                    value: "\(session.metrics.completeMeasurementCandidateCount)",
                    detail: L10n.text(
                        "至少值 \(session.metrics.lowerBoundMeasurementCandidateCount) · 失败 \(session.metrics.failedMeasurementCandidateCount)",
                        "Lower bounds \(session.metrics.lowerBoundMeasurementCandidateCount) · failed \(session.metrics.failedMeasurementCandidateCount)"
                    ),
                    tint: session.metrics.lowerBoundMeasurementCandidateCount == 0
                        && session.metrics.failedMeasurementCandidateCount == 0
                            ? AppDesignTokens.Palette.success
                            : AppDesignTokens.Palette.warning
                )
                CleanupResultSummaryCard(
                    title: L10n.text("已访问目录", "Visited Directories"),
                    value: "\(session.metrics.visitedDirectoryCount)",
                    detail: L10n.text(
                        "条目 \(session.metrics.visitedEntryCount)",
                        "\(session.metrics.visitedEntryCount) entries"
                    ),
                    tint: AppDesignTokens.Palette.information
                )
                CleanupResultSummaryCard(
                    title: L10n.text("安全跳过", "Safely Skipped"),
                    value: "\(session.metrics.permissionFailureCount)",
                    detail: L10n.text(
                        "权限失败 · 云文件 \(session.metrics.cloudSkippedCount) · 超时 \(session.metrics.timedOutRuleCount)",
                        "permission failures · cloud \(session.metrics.cloudSkippedCount) · timeouts \(session.metrics.timedOutRuleCount)"
                    ),
                    tint: session.metrics.permissionFailureCount == 0
                        && session.metrics.timedOutRuleCount == 0
                            ? AppDesignTokens.Palette.information
                            : AppDesignTokens.Palette.warning
                )
                CleanupResultSummaryCard(
                    title: L10n.text("候选截断", "Truncated Candidates"),
                    value: "\(session.metrics.truncatedCandidateCount)",
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
        VStack(spacing: AppDesignTokens.Spacing.small) {
            HStack(spacing: AppDesignTokens.Spacing.medium) {
                Text(L10n.text(
                    selectionActionSummaryChinese,
                    selectionActionSummaryEnglish
                ))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()

                Spacer()

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
                                    ? "checkmark.shield"
                                    : "exclamationmark.shield"
                        )
                    }
                    .appButtonChrome(.primary)
                    .tint(cleanupActionTint)
                    .disabled(
                        selectedBytes == 0
                            || session.outcome == .cancelled
                            || !store.canRequestV2Cleanup
                    )
                } else {
                    AppButton(
                        title: L10n.text("生成 Dry-run · \(ByteFormat.string(selectedBytes))", "Create Dry Run · \(ByteFormat.string(selectedBytes))"),
                        systemImage: "checkmark.shield",
                        kind: .primary,
                        tint: AppDesignTokens.Palette.steadyChrome,
                        isDisabled: selectedBytes == 0 || session.outcome == .cancelled
                    ) {
                        store.prepareCleanupDryRun(candidateIDs: selectionScopeIDs)
                    }
                }
            }

            if store.cleanupFeatureConfiguration.mode == .v2Full {
                Label(
                    L10n.text(
                        "文件会先移入废纸篓；清空废纸篓后，磁盘空间才会真正释放。",
                        "Files move to Trash first; disk space is released after Trash is emptied."
                    ),
                    systemImage: "trash"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let summary = store.cleanupDryRunSummary,
               summary.sessionID == session.id {
                Label(
                    L10n.text(
                        "已核对 \(summary.selectedCount) 项、\(ByteFormat.string(summary.selectedBytes))；文件系统改动：0",
                        "\(summary.selectedCount) item(s), \(ByteFormat.string(summary.selectedBytes)) validated; file-system changes: 0"
                    ),
                    systemImage: "checkmark.seal.fill"
                )
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.success)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(AppDesignTokens.Layout.compactPadding)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: cleanupActionTint,
            elevated: true
        )
    }

    private var cleanupActionTitle: String {
        selectedReviewCandidates.isEmpty && selectedProtectedCandidates.isEmpty
            ? L10n.text(
                "安全清理 · \(ByteFormat.string(selectedBytes))",
                "Safe Cleanup · \(ByteFormat.string(selectedBytes))"
            )
            : L10n.text(
                "清理所选 · \(ByteFormat.string(selectedBytes))",
                "Clean Selected · \(ByteFormat.string(selectedBytes))"
            )
    }

    private var cleanupActionTint: Color {
        if !selectedProtectedCandidates.isEmpty {
            return AppDesignTokens.Palette.destructive
        }
        return selectedReviewCandidates.isEmpty
            ? AppDesignTokens.Palette.information
            : AppDesignTokens.Palette.warning
    }

    private var selectionActionSummaryChinese: String {
        if !selectedProtectedCandidates.isEmpty {
            return "已选择 \(selectedCount) 项 · 红色 \(selectedProtectedCandidates.count) 项需双重确认"
        }
        if !selectedReviewCandidates.isEmpty {
            return "已选择 \(selectedCount) 项 · 黄色 \(selectedReviewCandidates.count) 项需确认"
        }
        return "已选择 \(selectedCount) 项 · \(ByteFormat.string(selectedBytes))"
    }

    private var selectionActionSummaryEnglish: String {
        if !selectedProtectedCandidates.isEmpty {
            return "\(selectedCount) selected · \(selectedProtectedCandidates.count) red item(s) need two confirmations"
        }
        if !selectedReviewCandidates.isEmpty {
            return "\(selectedCount) selected · \(selectedReviewCandidates.count) yellow item(s) need confirmation"
        }
        return "\(selectedCount) selected · \(ByteFormat.string(selectedBytes))"
    }

    private func matchesCurrentFilter(_ candidate: ScanCandidate) -> Bool {
        switch resultFilter {
        case .all:
            true
        case .selected:
            store.cleanupSelection.selectedCandidateIDs.contains(candidate.id)
        case .recommended:
            candidate.isSelectable
                && candidate.defaultSelection != .forbidden
                && candidate.recommendation.level == .recommended
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
                title: L10n.text("在 Finder 中显示", "Show in Finder"),
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

private enum CleanupMeasurementPresentation {
    static func value(_ candidate: ScanCandidate) -> String {
        switch candidate.measurementCompleteness {
        case .complete:
            return ByteFormat.string(candidate.estimatedSizeBytes)
        case .lowerBound:
            return L10n.text(
                "至少 \(ByteFormat.string(candidate.estimatedSizeBytes))",
                "At least \(ByteFormat.string(candidate.estimatedSizeBytes))"
            )
        case .failed:
            return L10n.text("无法计算", "Unavailable")
        }
    }

    static func aggregateValue(_ candidates: [ScanCandidate]) -> String {
        guard !candidates.isEmpty else { return ByteFormat.string(0) }
        let measured = candidates.filter { !$0.measurementCompleteness.isFailed }
        guard !measured.isEmpty else { return L10n.text("无法计算", "Unavailable") }
        let bytes = CleanupByteCount.sum(measured.map(\.estimatedSizeBytes))
        guard candidates.allSatisfy({ $0.measurementCompleteness.isComplete }) else {
            return L10n.text(
                "至少 \(ByteFormat.string(bytes))",
                "At least \(ByteFormat.string(bytes))"
            )
        }
        return ByteFormat.string(bytes)
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
            return L10n.text(
                "\(reasonText)，因此不能加入清理计划。",
                "\(reasonText), so this item cannot enter a cleanup plan."
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
    @State private var isExpanded = false
    @State private var isShowingDetails = false

    private var state: TriStateSelection {
        store.cleanupSelection.state(for: subcategory.selectableCandidateIDs)
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
            let status = subcategory.risk == .protected
                ? L10n.text("受保护", "protected")
                : L10n.text("仅供查看", "view only")
            return "\(L10n.items(total)) · \(status)"
        }
        if selectable < total {
            return L10n.text(
                "\(L10n.items(total)) · \(selectable) 项可选择",
                "\(L10n.items(total)) · \(selectable) selectable"
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
                        store.setCleanupCandidates(
                            subcategory.selectableCandidateIDs,
                            selected: state != .checked
                        )
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
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: AppDesignTokens.Spacing.small) {
                                Text(subcategory.title)
                                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                                CleanupRiskBadge(risk: subcategory.risk)
                                CleanupRecommendationBadge(level: displayedRecommendation)
                            }
                            Text(itemCountSummary)
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                        Spacer(minLength: AppDesignTokens.Spacing.small)
                        Text(CleanupMeasurementPresentation.aggregateValue(candidates))
                            .font(AppDesignTokens.Typography.compactLabelEmphasis)
                            .monospacedDigit()
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
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(
                    cornerRadius: max(8, AppDesignTokens.Layout.cardRadius - 4),
                    style: .continuous
                )
            )

            if isExpanded {
                ForEach(candidates) { candidate in
                    Divider()
                        .padding(.leading, layout.cardPadding + 56)
                    CleanupCandidateRow(
                        store: store,
                        session: session,
                        candidate: candidate
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: CleanupRiskPresentation.tint(subcategory.risk),
            prominence: .quiet
        )
    }

    private func toggleExpansion() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            isExpanded.toggle()
        }
    }
}

private struct CleanupCandidateRow: View {
    @Environment(\.windowLayoutMetrics) private var layout
    @ObservedObject var store: ScanStore
    let session: ScanSession
    let candidate: ScanCandidate
    @State private var isShowingDetails = false

    private var isSelected: Bool {
        store.cleanupSelection.selectedCandidateIDs.contains(candidate.id)
    }

    private var canSelect: Bool {
        candidate.isSelectable
            && session.outcome != .cancelled
            && store.canEditV2CleanupSelection
    }

    private var selection: Binding<Bool> {
        Binding {
            isSelected
        } set: { selected in
            store.setCleanupCandidate(candidate.id, selected: selected)
        }
    }

    var body: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            Toggle(isOn: selection) {
                candidateContent
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .disabled(!canSelect)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(selectionAccessibilityValue)
            .accessibilityHint(selectionAccessibilityHint)

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
                    "在 Finder 中显示 \(candidate.sourceURL.lastPathComponent)",
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
            }
            Spacer(minLength: 8)
            Text(CleanupMeasurementPresentation.value(candidate))
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
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
            }
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
        .frame(width: 380, alignment: .leading)
        .accessibilityElement(children: .contain)
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
        if isDeveloperMetadataReference {
            return L10n.text("目录修改约 \(days) 天前", "Folder changed about \(days) days ago")
        }
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
        if isDeveloperMetadataReference {
            return L10n.text(
                "\(date.formatted(date: .abbreviated, time: .shortened)) · 顶层目录修改时间；未读取会话内容",
                "\(date.formatted(date: .abbreviated, time: .shortened)) · top-level folder modification time; session contents were not read"
            )
        }
        return L10n.text(
            "\(date.formatted(date: .abbreviated, time: .shortened)) · 距扫描约 \(days) 天 · 本次阈值 \(session.developerInactivityThresholdDays) 天",
            "\(date.formatted(date: .abbreviated, time: .shortened)) · about \(days) days before scan · \(session.developerInactivityThresholdDays)-day threshold"
        )
    }

    private var isDeveloperMetadataReference: Bool {
        candidate.categoryID == "developer"
            && candidate.action == .revealOnly
            && candidate.measurementCompleteness.isLowerBound
    }

    private var developerActivityTitle: String {
        isDeveloperMetadataReference
            ? L10n.text("目录修改时间", "Folder Modified")
            : L10n.text("最近活动", "Latest Activity")
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
        let artifact = candidate.developerArtifactSummary.map { "\($0)，" } ?? ""
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
        if !candidate.measurementCompleteness.isComplete {
            return CleanupMeasurementPresentation.detail(candidate)
                ?? L10n.text("容量测量不完整，不能加入清理计划。", "Measurement is incomplete, so this item cannot enter a cleanup plan.")
        }
        if canSelect {
            switch candidate.selectionEligibility {
            case .selectableWithReview:
                return L10n.text(
                    "按空格切换选择；黄色项目在执行前还需要风险确认。文件夹按钮只在 Finder 中显示。",
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
            ? L10n.text("按空格切换选择；文件夹按钮只在 Finder 中显示。", "Press Space to toggle selection; the folder button only reveals the item in Finder.")
            : L10n.text("此项目不能加入清理计划。", "This item cannot be added to the cleanup plan.")
    }

}

private struct CleanupSelectionAvailabilityIndicator: View {
    let risk: CleanupRisk

    private var title: String {
        risk == .protected
            ? L10n.text("受保护，不能加入清理计划", "Protected and cannot be added to the cleanup plan")
            : L10n.text("仅供查看，不能加入清理计划", "View only and cannot be added to the cleanup plan")
    }

    var body: some View {
        Image(systemName: risk == .protected ? "lock.fill" : "eye")
            .font(AppDesignTokens.Typography.compactSymbol)
            .foregroundStyle(CleanupRiskPresentation.tint(risk))
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
            Image(systemName: systemImage)
                .font(AppDesignTokens.Typography.symbol)
                .foregroundStyle(
                    state == .unchecked
                        ? AppDesignTokens.Palette.secondaryText
                        : tint
                )
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
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

    private var accessibilityValue: String {
        switch state {
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
            if subcategory.candidates.contains(where: { !$0.requiredClosedBundleIDs.isEmpty }) {
                return L10n.text(
                    "清理前请退出相关应用；清理后首次启动或构建可能较慢。",
                    "Quit related apps first; the next launch or build may be slower."
                )
            }
            return L10n.text(
                "确认不再需要后勾选；执行时仍会再次核对文件身份并移至废纸篓。",
                "Select only after review; execution rechecks identity and moves items to Trash."
            )
        case .reviewOnly:
            if subcategory.selectableCandidateIDs.isEmpty {
                return L10n.text(
                    "包含应用数据，只能在 Finder 中审查；请使用原应用或卸载器管理。",
                    "Contains app data. Review in Finder and manage it from the owning app or an uninstaller."
                )
            }
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
            return L10n.text(
                "默认不选。只有规则明确允许的应用才可逐项选择；执行前需要双重确认，并只会移入废纸篓。",
                "Off by default. Only apps explicitly allowed by a rule can be selected individually; two confirmations are required and the app only moves to Trash."
            )
        case .informational:
            return L10n.text("仅作容量参考。", "For capacity reference only.")
        }
    }
}
