import AppKit
import Foundation
import SwiftUI

enum BrowserPrivacyManualWorkflow {
    static func normalizedDomains(_ domains: [String?]) -> [String] {
        Array(Set(domains.compactMap { domain -> String? in
            guard let domain else { return nil }
            let value = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value.lowercased()
        })).sorted()
    }

    static func clipboardText(domains: [String]) -> String {
        normalizedDomains(domains.map(Optional.some)).joined(separator: "\n")
    }

    static func groups(from records: [BrowserPrivacyRecord]) -> [BrowserPrivacyManualGuidanceGroup] {
        Dictionary(grouping: records, by: { $0.browser.id }).values.map { records in
            BrowserPrivacyManualGuidanceGroup(
                browser: records[0].browser,
                recordCount: records.count,
                domains: normalizedDomains(records.map(\.domain))
            )
        }.sorted {
            $0.browser.displayName.localizedCaseInsensitiveCompare($1.browser.displayName)
                == .orderedAscending
        }
    }

    /// Canonical browsers reuse the audited cleanup router. Derivatives have
    /// no safe, stable internal URL and therefore launch the app only.
    static func historyRoute(for browser: BrowserPrivacyBrowser) -> BrowserPrivacyCleanupRoute? {
        guard let kind = canonicalKind(for: browser) else { return nil }
        return BrowserPrivacyCleanupRouter().route(for: .history, browser: kind)
    }

    static func historyInstruction(for browser: BrowserPrivacyBrowser) -> String {
        historyRoute(for: browser)?.instruction ?? L10n.text(
            "仅启动 \(browser.displayName)。请从该浏览器的“历史记录”菜单打开完整历史列表，再按已复制的域名逐项核对。",
            "Only \(browser.displayName) will be launched. Open its full History list from the browser menu, then review the copied domains one by one."
        )
    }

    private static func canonicalKind(for browser: BrowserPrivacyBrowser) -> BrowserKind? {
        switch browser.id.lowercased() {
        case "safari": .safari
        case "chrome": .chrome
        case "edge": .edge
        case "firefox": .firefox
        default: nil
        }
    }
}

struct BrowserPrivacyManualGuidanceGroup: Identifiable, Equatable {
    let browser: BrowserPrivacyBrowser
    let recordCount: Int
    let domains: [String]

    var id: String { browser.id }
}

/// Record URLs stay local and are never opened. Canonical browsers use only
/// audited native history routes; derivatives are launched without a URL.
struct BrowserPrivacyRecordResultsView: View {
    private struct BulkSelectionRequest {
        let title: String
        let recordIDs: Set<UUID>
    }

    @ObservedObject var store: BrowserPrivacyStore
    @Environment(\.moduleTheme) private var theme

    @State private var isShowingProcessingConfirmation = false
    @State private var isShowingReviewSelectionConfirmation = false
    @State private var isShowingRunningBrowserPreflight = false
    @State private var showsBulkSelection = false
    @State private var pendingBulkSelection: BulkSelectionRequest?
    @State private var searchQuery = ""
    @State private var showsPermissionDetails = false
    @State private var showsCoverageDetails = false

    var body: some View {
        VStack(spacing: 0) {
            resultSurface
            Divider()
            compactSelectionHeader
        }
        .confirmationDialog(
            processingConfirmationTitle,
            isPresented: $isShowingProcessingConfirmation,
            titleVisibility: .visible
        ) {
            if store.selectedRecordsContainVerifiedDeletionCandidate {
                Button(L10n.text("创建恢复备份并清理", "Back Up and Clean")) {
                    store.processSelectedRecords()
                }
            } else {
                Button(L10n.text("查看处理步骤", "Review Handling Steps")) {
                    store.prepareManualGuidance()
                }
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(processingConfirmationMessage)
        }
        .confirmationDialog(
            L10n.text("选择当前浏览记录？", "Select Current History Records?"),
            isPresented: $isShowingReviewSelectionConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("选择需确认记录", "Select Review Records")) {
                store.setFilteredSelection(true, confirmingReview: true)
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text(
                "浏览历史属于需确认数据，默认不会选中。此操作只选择当前筛选中的记录，清理前仍会再次显示确认和浏览器运行状态。",
                "Browsing history requires review and is not selected by default. This selects only the current filter; cleanup still requires confirmation and a browser-running preflight."
            ))
        }
        .confirmationDialog(
            L10n.text(
                "批量选择\(pendingBulkSelection?.title ?? "")的浏览记录？",
                "Bulk Select Browsing Records for \(pendingBulkSelection?.title ?? "")?"
            ),
            isPresented: bulkSelectionConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(L10n.text(
                "加入 \(pendingBulkSelection?.recordIDs.count ?? 0) 项到已选",
                "Add \(pendingBulkSelection?.recordIDs.count ?? 0) Items to Selection"
            )) {
                if let request = pendingBulkSelection {
                    store.setSelection(
                        true,
                        recordIDs: request.recordIDs,
                        confirmingReview: true
                    )
                }
                pendingBulkSelection = nil
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                pendingBulkSelection = nil
            }
        } message: {
            Text(L10n.text(
                "只会把匹配记录加入当前选择，不会立即删除。点击“清理所选”后仍需确认，并继续执行浏览器运行预检、恢复备份和删除后回读验证。",
                "Matching records are only added to the current selection and are not deleted immediately. Clean Selected still requires confirmation, browser-running preflight, recovery backup, and post-delete read-back verification."
            ))
        }
        .confirmationDialog(
            L10n.text("浏览器仍在运行", "Browser Still Running"),
            isPresented: $isShowingRunningBrowserPreflight,
            titleVisibility: .visible
        ) {
            Button(L10n.text("正常退出并继续", "Quit Normally and Continue")) {
                Task { await store.requestNormalBrowserExitAndProcess() }
            }
            Button(L10n.text("跳过运行中的浏览器", "Skip Running Browsers")) {
                store.processSelectedRecords(
                    excludingBrowserIDs: store.selectedRunningBrowserIDs
                )
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text(
                "直接清理前浏览器必须正常退出，以便重新检查数据库身份、WAL、Schema 和所选 Visit。不会强制结束浏览器进程。",
                "Browsers must quit normally before direct cleanup so database identity, WAL, schema, and selected visits can be checked again. The app never force-quits a browser."
            ))
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            searchQuery = store.filters.query
        }
        .task(id: searchQuery) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                store.filters.query = searchQuery
            } catch {
                // A newer keystroke superseded this debounce task.
            }
        }
    }

    private var compactSelectionHeader: some View {
        HStack(alignment: .center, spacing: AppDesignTokens.Spacing.section) {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                Text(selectionSummaryDetail)
                    .font(AppDesignTokens.Typography.compactLabelEmphasis.monospacedDigit())
                if !store.selectedRecordIDs.isEmpty {
                    Text(selectedCapacityTitle)
                        .font(AppDesignTokens.Typography.metadata.monospacedDigit())
                        .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                }
                Text(L10n.text(
                    "删除前仍会检查浏览器运行状态并再次确认。",
                    "Browser state is checked and confirmation is required before deletion."
                ))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
            }

            Spacer(minLength: AppDesignTokens.Spacing.medium)

            Button {
                beginProcessingConfirmation()
            } label: {
                Label(
                    store.isProcessing
                        ? L10n.text("正在处理", "Processing")
                        : primaryActionTitle,
                    systemImage: store.isProcessing
                        ? "arrow.triangle.2.circlepath"
                        : (store.selectedRecordsContainVerifiedDeletionCandidate
                            ? "trash"
                            : "hand.raised")
                )
                .frame(minWidth: 132)
            }
            .appButtonChrome(.primary)
            .controlSize(.large)
            .disabled(
                store.selectedRecordIDs.isEmpty
                    || store.isProcessing
                    || store.isRunningBrowserPreflight
                    || store.state == .scanning
            )
            .help(L10n.text(
                "精确 Schema 项会先创建恢复备份再清理；其余项在浏览器内处理",
                "Exact-schema items are backed up before cleanup; remaining items are handled in the browser"
            ))
        }
        .padding(.horizontal, AppDesignTokens.Spacing.compact)
        .frame(minHeight: 76)
        .accessibilityElement(children: .contain)
    }

    private var resultSurface: some View {
        VStack(spacing: 0) {
            resultToolbar
            dateAndGroupingToolbar

            Divider()
                .overlay(AppDesignTokens.Palette.separator.opacity(0.55))

            if store.isRefreshingCachedResults || (store.error != nil && store.hasCachedResults) {
                refreshStatus
                    .padding(.horizontal, AppDesignTokens.Spacing.medium)
                    .padding(.top, AppDesignTokens.Spacing.small)
            }

            if requiresFullDiskAccess {
                permissionBanner
                    .padding(.horizontal, AppDesignTokens.Spacing.medium)
                    .padding(.top, AppDesignTokens.Spacing.small)
            }

            if store.isProcessing {
                BrowserPrivacyProcessingProgress()
                    .padding(AppDesignTokens.Spacing.medium)
            } else if let report = store.processingReport {
                ScrollView {
                    BrowserPrivacyProcessingReportView(
                        report: report,
                        selectedRecords: store.manualGuidanceRecords,
                        reverificationStatus: store.reverificationStatus,
                        onRescan: store.startScan
                    )
                    .padding(AppDesignTokens.Spacing.medium)
                }
            } else {
                resultGroupHeader
                Divider()
                    .overlay(AppDesignTokens.Palette.separator.opacity(0.45))
                compactRecordContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dateAndGroupingToolbar: some View {
        BrowserPrivacyDateControls(store: store)
            .padding(.horizontal, AppDesignTokens.Spacing.medium)
            .padding(.bottom, AppDesignTokens.Spacing.small)
    }

    private func applyDateRange(days: Int) {
        guard let preset = BrowserPrivacyDatePreset(rawValue: days) else { return }
        var filters = store.filters
        preset.apply(to: &filters, now: Date())
        store.filters = filters
    }

    nonisolated static func websiteGroups(_ items: [BrowserPrivacyDisplayItem]) -> [(domain: String, items: [BrowserPrivacyDisplayItem])] {
        Dictionary(grouping: items) { item in
            item.domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        }
        .map { (domain: $0.key, items: $0.value) }
        .sorted { $0.domain < $1.domain }
    }

    private var resultToolbar: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            compactSearchField

            Spacer(minLength: AppDesignTokens.Spacing.small)

            Button {
                showsBulkSelection.toggle()
            } label: {
                Label(L10n.text("批量选择", "Bulk Select"), systemImage: "checklist.checked")
            }
            .appButtonChrome(.toolbar)
            .disabled(store.records.isEmpty || store.state == .scanning || store.isProcessing)
            .help(L10n.text("按日期或网站批量选择", "Select in bulk by date or website"))
            .popover(isPresented: $showsBulkSelection, arrowEdge: .bottom) {
                BrowserPrivacyBulkSelectionView(
                    records: store.records,
                    isDisabled: store.state == .scanning || store.isProcessing,
                    onSelect: requestBulkSelection
                )
            }

            sortMenu
            advancedFiltersMenu

            if !store.coverage.isEmpty {
                Button {
                    showsCoverageDetails.toggle()
                } label: {
                    Image(systemName: "checklist")
                }
                .appButtonChrome(.icon)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("扫描覆盖范围", "Scan Coverage"))
                .help(coverageSummary)
                .popover(isPresented: $showsCoverageDetails, arrowEdge: .bottom) {
                    coverageDetails
                }
            }

            Button {
                if store.state == .scanning {
                    store.cancel()
                } else {
                    store.startScan()
                }
            } label: {
                Image(systemName: store.state == .scanning ? "xmark" : "arrow.clockwise")
            }
            .appButtonChrome(.icon)
            .controlSize(.small)
            .accessibilityLabel(store.state == .scanning
                ? L10n.text("取消扫描", "Cancel Scan")
                : L10n.text("重新扫描", "Scan Again"))
            .help(store.state == .scanning
                ? L10n.text("取消当前只读扫描", "Cancel the current read-only scan")
                : L10n.text("重新扫描浏览器隐私记录", "Scan browser privacy records again"))
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, AppDesignTokens.Spacing.small)
    }

    private var compactSearchField: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                .accessibilityHidden(true)
            TextField(
                L10n.text("搜索浏览器、标题、域名或类别", "Search browser, title, domain, or category"),
                text: $searchQuery
            )
            .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .appButtonChrome(.icon)
                .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                .accessibilityLabel(L10n.text("清除搜索", "Clear Search"))
            }
        }
        .padding(.horizontal, AppDesignTokens.Spacing.small)
        .frame(maxWidth: 360, minHeight: 30)
        .background(
            AppDesignTokens.Palette.secondaryBackground.opacity(0.72),
            in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.glassControl, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppDesignTokens.Radius.glassControl, style: .continuous)
                .stroke(AppDesignTokens.Palette.separator.opacity(0.55), lineWidth: 1)
        }
        .accessibilityLabel(L10n.text("搜索浏览器隐私结果", "Search browser privacy results"))
    }

    private var sortMenu: some View {
        Menu {
            Picker(L10n.text("排序", "Sort"), selection: $store.resultSort) {
                Text(L10n.text("容量优先", "Largest First"))
                    .tag(BrowserPrivacyResultSort.largestFirst)
                Text(L10n.text("最近访问", "Newest First"))
                    .tag(BrowserPrivacyResultSort.newestFirst)
                Text(L10n.text("按浏览器", "By Browser"))
                    .tag(BrowserPrivacyResultSort.browser)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.text("结果排序", "Sort Results"))
    }

    private var advancedFiltersMenu: some View {
        Menu {
            Picker(L10n.text("浏览器", "Browser"), selection: browserFilterBinding) {
                Text(L10n.text("所有浏览器", "All Browsers")).tag(Optional<String>.none)
                ForEach(browsers) { browser in
                    Text(browser.displayName).tag(browser.id as String?)
                }
            }

            if profileIDs.count > 1 {
                Picker(L10n.text("配置文件", "Profile"), selection: filterBinding(\.profileID)) {
                    Text(L10n.text("所有配置文件", "All Profiles")).tag(Optional<String>.none)
                    ForEach(profileIDs, id: \.self) { profileID in
                        Text(profileID).tag(profileID as String?)
                    }
                }
            }

            Picker(L10n.text("类别", "Category"), selection: filterBinding(\.category)) {
                Text(L10n.text("所有类别", "All Categories")).tag(Optional<BrowserPrivacyCategory>.none)
                ForEach(BrowserPrivacyCategory.allCases, id: \.self) { category in
                    Text(category.browserPrivacyTitle).tag(category as BrowserPrivacyCategory?)
                }
            }

            Picker(L10n.text("置信度", "Confidence"), selection: filterBinding(\.confidence)) {
                Text(L10n.text("所有置信度", "All Confidence")).tag(Optional<BrowserPrivacySelectionConfidence>.none)
                ForEach(confidences, id: \.self) { confidence in
                    Text(confidence.browserPrivacyTitle).tag(confidence as BrowserPrivacySelectionConfidence?)
                }
            }

            Divider()
            Button(L10n.text("最近 7 天", "Last 7 Days")) { applyDateRange(days: 7) }
            Button(L10n.text("最近 30 天", "Last 30 Days")) { applyDateRange(days: 30) }
            Button(L10n.text("清除高级筛选", "Clear Advanced Filters")) {
                let query = store.filters.query
                store.filters = .empty
                store.filters.query = query
            }
            .disabled(!hasAdvancedFilters)
        } label: {
            Image(systemName: hasAdvancedFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.text("高级筛选", "Advanced Filters"))
    }

    private var coverageDetails: some View {
        let scannedCoverage = store.coverage.filter { $0.availability != .noProfiles }
        let noProfileBrowsers = store.coverage.filter { $0.availability == .noProfiles }

        return VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Text(L10n.text("扫描覆盖范围", "Scan Coverage"))
                .font(AppTypography.sectionTitle)
            Text(coverageSummary)
                .font(AppTypography.caption)
                .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !scannedCoverage.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    ForEach(scannedCoverage) { item in
                        BrowserPrivacyCoverageRow(coverage: item)
                    }
                }
            }

            if !noProfileBrowsers.isEmpty {
                Divider()
                Text(L10n.text(
                    "未发现配置文件：\(noProfileBrowsers.map(\.browser.displayName).joined(separator: "、"))",
                    "No profiles found: \(noProfileBrowsers.map(\.browser.displayName).joined(separator: ", "))"
                ))
                .font(AppTypography.caption)
                .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(L10n.text(
                    "未发现配置文件的浏览器列表",
                    "Browsers without profiles"
                ))
            }
        }
        .padding(AppDesignTokens.Spacing.medium)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("浏览器覆盖范围", "Browser coverage"))
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("部分浏览器需要完全磁盘访问权限", "Some Browsers Need Full Disk Access"))
                        .font(AppTypography.metadata)
                    Text(L10n.text(
                        "当前结果不代表这些浏览器没有历史记录。",
                        "Current results do not prove those browsers have no history."
                    ))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                }
                Spacer(minLength: AppDesignTokens.Spacing.small)
                Button(showsPermissionDetails
                    ? L10n.text("收起", "Hide")
                    : L10n.text("详情", "Details")) {
                    showsPermissionDetails.toggle()
                }
                .appButtonChrome(.toolbar)
                Button(L10n.text("打开系统设置", "Open System Settings")) {
                    PrivacySystemSettingsOpener.openFullDiskAccess()
                }
                .appButtonChrome(.secondary)
            }

            if showsPermissionDetails {
                ForEach(store.coverage.filter(\.requiresFullDiskAccess)) { item in
                    HStack {
                        Text(item.browser.displayName)
                        Spacer()
                        Text(item.availability.browserPrivacyTitle)
                            .foregroundStyle(AppDesignTokens.Palette.warning)
                    }
                    .font(AppTypography.caption)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(AppDesignTokens.Spacing.small)
        .background(
            AppDesignTokens.Palette.warning.opacity(0.10),
            in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.glassControl, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var resultGroupHeader: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            Button {
                if store.filteredSelectionState == .checked {
                    store.setFilteredSelection(false)
                } else {
                    isShowingReviewSelectionConfirmation = true
                }
            } label: {
                Image(systemName: groupSelectionSystemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            .appButtonChrome(.toolbar)
            .foregroundStyle(AppDesignTokens.Palette.accent)
            .disabled(store.filteredRecords.isEmpty || store.state == .scanning || store.isProcessing)
            .accessibilityLabel(L10n.text("选择当前结果", "Select Current Results"))
            .accessibilityValue(groupSelectionAccessibilityValue)

            Text(L10n.text("浏览记录", "Browsing History"))
                .font(AppTypography.metadata)
                .foregroundStyle(theme.primaryText)

            Spacer(minLength: AppDesignTokens.Spacing.small)

            Text(L10n.text(
                "\(store.filteredRecords.count) 项 · 已选 \(selectedFilteredCount)",
                "\(store.filteredRecords.count) items · \(selectedFilteredCount) selected"
            ))
            .font(AppTypography.caption.monospacedDigit())
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, AppDesignTokens.Spacing.small)
    }

    @ViewBuilder
    private var compactRecordContent: some View {
        if store.filteredRecords.isEmpty {
            BrowserPrivacyRecordsEmptyState(
                scanState: store.state,
                hasFilters: hasActiveFilters,
                hasRecords: !store.records.isEmpty,
                requiresFullDiskAccess: requiresFullDiskAccess
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.groupsByWebsite {
                        ForEach(Self.websiteGroups(store.filteredDisplayItems), id: \.domain) { group in
                            HStack {
                                Text(group.domain.isEmpty ? L10n.text("无网站信息", "No website") : group.domain)
                                Spacer()
                                Text(L10n.text("\(group.items.count) 组记录", "\(group.items.count) record groups"))
                            }
                            .font(AppDesignTokens.Typography.compactLabelEmphasis)
                            .padding(AppDesignTokens.Spacing.small)
                            .background(theme.accent.opacity(0.08))
                            ForEach(group.items) { item in recordRow(item) }
                        }
                    } else {
                        ForEach(store.filteredDisplayItems) { item in recordRow(item) }
                    }
                }
            }
            .accessibilityLabel(L10n.text("浏览器隐私记录列表", "Browser privacy record list"))
        }
    }

    @ViewBuilder
    private func recordRow(_ item: BrowserPrivacyDisplayItem) -> some View {
        BrowserPrivacyDisplayItemRow(
            item: item,
            selectionState: store.selectionState(for: item),
            isDisabled: store.state == .scanning || store.isProcessing,
            isBrowserRunning: store.runningBrowserIDs.contains(item.browser.id),
            toggleSelection: {
                store.setSelected(
                    store.selectionState(for: item) != .checked,
                    displayItem: item
                )
            }
        )
        Divider()
            .padding(.leading, 42)
            .overlay(AppDesignTokens.Palette.separator.opacity(0.38))
    }

    private var selectedCapacityTitle: String {
        if store.selectedRecordIDs.isEmpty { return "0 B" }
        if store.selectedUnknownSizeCount > 0 {
            return L10n.text("大小不可用", "Size unavailable")
        }
        return BrowserPrivacyByteFormatter.string(store.selectedKnownSizeBytes)
    }

    private var selectedFilteredCount: Int {
        store.selectedRecordIDs.intersection(Set(store.filteredRecords.map(\.id))).count
    }

    private var selectionSummaryDetail: String {
        if store.selectedRecordIDs.isEmpty {
            return L10n.text("未选择项目", "No items selected")
        }
        if store.selectedUnknownSizeCount > 0 {
            return L10n.text(
                "已选择 \(store.selectedRecordIDs.count) 项 · 历史行没有可信的独立容量",
                "\(store.selectedRecordIDs.count) selected · history rows have no reliable individual size"
            )
        }
        return L10n.text(
            "已选择 \(store.selectedRecordIDs.count) 项",
            "\(store.selectedRecordIDs.count) selected"
        )
    }

    private var primaryActionTitle: String {
        store.selectedRecordsContainVerifiedDeletionCandidate
            ? L10n.text("清理所选", "Clean Selected")
            : L10n.text("在浏览器内处理", "Handle in Browser")
    }

    private var processingConfirmationTitle: String {
        store.selectedRecordsContainVerifiedDeletionCandidate
            ? L10n.text("确认清理所选浏览记录", "Confirm Selected History Cleanup")
            : L10n.text("准备在浏览器内处理", "Prepare In-Browser Handling")
    }

    private var processingConfirmationMessage: String {
        if store.selectedRecordsContainVerifiedDeletionCandidate {
            return L10n.text(
                "将处理 \(store.selectedRecordIDs.count) 条 Visit（\(selectedBrowserSummary)）。受支持项目会先创建 SQLite 在线恢复备份，再按真实 Visit 主键执行事务和回读验证；不支持的 Schema 不会写入。书签、密码、Cookie、自动填充和未选 Visit 不在计划中。",
                "This processes \(store.selectedRecordIDs.count) visits in \(selectedBrowserSummary). Supported items receive an online SQLite recovery backup before an exact Visit-key transaction and read-back verification; unsupported schemas are not written. Bookmarks, passwords, cookies, autofill, and unselected visits are outside the plan."
            )
        }
        return L10n.text(
            "将为 \(store.selectedRecordIDs.count) 条记录（\(selectedBrowserSummary)）生成浏览器内处理流程。本应用不会把不支持的数据库 Schema 假装成可直接清理。",
            "This prepares an in-browser workflow for \(store.selectedRecordIDs.count) records in \(selectedBrowserSummary). Unsupported database schemas are never presented as direct cleanup."
        )
    }

    private func beginProcessingConfirmation() {
        if store.selectedRecordsContainVerifiedDeletionCandidate,
           !store.selectedRunningBrowserIDs.isEmpty {
            isShowingRunningBrowserPreflight = true
        } else {
            isShowingProcessingConfirmation = true
        }
    }

    private var groupSelectionSystemImage: String {
        switch store.filteredSelectionState {
        case .unchecked: "square"
        case .mixed: "minus.square.fill"
        case .checked: "checkmark.square.fill"
        }
    }

    private var groupSelectionAccessibilityValue: String {
        switch store.filteredSelectionState {
        case .unchecked: L10n.text("未选择", "Not selected")
        case .mixed: L10n.text("部分选择", "Mixed")
        case .checked: L10n.text("已全选", "All selected")
        }
    }

    private var hasAdvancedFilters: Bool {
        store.filters.browserID != nil
            || store.filters.profileID != nil
            || store.filters.category != nil
            || store.filters.source != nil
            || store.filters.confidence != nil
            || !store.filters.domain.isEmpty
            || !store.filters.keyword.isEmpty
            || store.filters.startDate != nil
            || store.filters.endDate != nil
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if store.isRefreshingCachedResults {
            BrowserPrivacyRefreshStatus(
                systemImage: "arrow.clockwise",
                title: L10n.text("正在刷新，继续显示上次结果", "Refreshing While Keeping Previous Results"),
                detail: L10n.text(
                    "新快照完成前不会清空当前记录或选择；处理操作暂时不可用。",
                    "Current records and selection stay visible until the new snapshot completes; processing is temporarily unavailable."
                ),
                tint: AppDesignTokens.Palette.information,
                isLoading: true
            )
        } else if let error = store.error, store.hasCachedResults {
            BrowserPrivacyRefreshStatus(
                systemImage: error == .cancelled ? "pause.circle" : "exclamationmark.triangle",
                title: error == .cancelled
                    ? L10n.text("刷新已取消", "Refresh Cancelled")
                    : L10n.text("刷新失败，仍显示上次结果", "Refresh Failed; Previous Results Remain"),
                detail: L10n.text(
                    "当前列表来自上一次已完成、部分完成或权限受限的本机只读扫描。可再次刷新。",
                    "The current list is from the last completed, partial, or permission-limited local read-only scan. You can refresh again."
                ),
                tint: error == .cancelled
                    ? AppDesignTokens.Palette.secondaryText
                    : AppDesignTokens.Palette.warning,
                isLoading: false
            )
        }
    }

    private var browsers: [BrowserPrivacyBrowser] {
        Self.uniqueBrowsers(from: store.records)
    }

    nonisolated static func uniqueBrowsers(from records: [BrowserPrivacyRecord]) -> [BrowserPrivacyBrowser] {
        Array(
            Dictionary(
                records.map { ($0.browser.id, $0.browser) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedBrowserSummary: String {
        let names = Array(Set(store.selectedRecords.map { $0.browser.displayName })).sorted()
        return names.isEmpty
            ? L10n.text("0 个浏览器", "0 browsers")
            : names.joined(separator: L10n.text("、", ", "))
    }

    private var profileIDs: [String] {
        let records = store.filters.browserID.map { browserID in
            store.records.filter { $0.browser.id == browserID }
        } ?? store.records
        return Array(Set(records.map(\.profileID))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var confidences: [BrowserPrivacySelectionConfidence] {
        [.high, .medium, .low, .unavailable]
    }

    private var fullyReadBrowserCount: Int {
        store.coverage.count { coverage in
            coverage.availability == .available
        }
    }

    private var partialBrowserCount: Int {
        store.coverage.count { $0.availability == .partial }
    }

    private var requiresFullDiskAccess: Bool {
        store.coverage.contains { $0.requiresFullDiskAccess }
    }

    private var coverageSummary: String {
        guard !store.coverage.isEmpty else {
            return L10n.text("覆盖信息等待扫描", "Coverage pending scan")
        }
        let permissionCount = store.coverage.count { $0.requiresFullDiskAccess }
        return L10n.text(
            "覆盖：\(fullyReadBrowserCount) 个完整读取 · \(partialBrowserCount) 个部分读取 · 其中 \(permissionCount) 个需完全磁盘访问权限",
            "Coverage: \(fullyReadBrowserCount) fully read · \(partialBrowserCount) partial · \(permissionCount) need Full Disk Access"
        )
    }

    private var hasActiveFilters: Bool {
        store.filters != .empty
    }

    private var bulkSelectionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingBulkSelection != nil },
            set: { isPresented in
                if !isPresented {
                    pendingBulkSelection = nil
                }
            }
        )
    }

    private func requestBulkSelection(_ scope: BrowserPrivacyBulkSelectionScope) {
        let recordIDs = scope.matchingRecordIDs(in: store.records)
        guard !recordIDs.isEmpty else { return }
        showsBulkSelection = false
        pendingBulkSelection = BulkSelectionRequest(
            title: scope.title,
            recordIDs: recordIDs
        )
    }

    private func filterBinding<Value>(
        _ keyPath: WritableKeyPath<BrowserPrivacyFilters, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.filters[keyPath: keyPath] },
            set: { store.filters[keyPath: keyPath] = $0 }
        )
    }

    private var browserFilterBinding: Binding<String?> {
        Binding(
            get: { store.filters.browserID },
            set: { browserID in
                store.filters.browserID = browserID
                guard let profileID = store.filters.profileID else { return }
                let profileStillExists = store.records.contains { record in
                    record.profileID == profileID
                        && (browserID == nil || record.browser.id == browserID)
                }
                if !profileStillExists {
                    store.filters.profileID = nil
                }
            }
        )
    }


}

private struct BrowserPrivacyRefreshStatus: View {
    let systemImage: String
    let title: String
    let detail: String
    let tint: Color
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                Text(title)
                    .font(AppTypography.metadata)
                    .foregroundStyle(tint)
                Text(detail)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(0.08),
            in: RoundedRectangle(
                cornerRadius: AppDesignTokens.Radius.glassControl,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }
}

/// One browser per row inside the coverage popover; rows wrap vertically, so
/// narrow windows can never truncate coverage the way the old horizontal card
/// strip did.
private struct BrowserPrivacyCoverageRow: View {
    let coverage: BrowserPrivacyProviderCoverage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: coverage.availability.browserPrivacySystemImage)
                .foregroundStyle(coverage.availability.browserPrivacyTint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(coverage.browser.displayName)
                            .font(AppTypography.metadata)
                        Spacer(minLength: AppDesignTokens.Spacing.small)
                        Text(coverage.availability.browserPrivacyTitle)
                            .font(AppTypography.caption)
                            .foregroundStyle(coverage.availability.browserPrivacyTint)
                    }

                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                        Text(coverage.browser.displayName)
                            .font(AppTypography.metadata)
                        Text(coverage.availability.browserPrivacyTitle)
                            .font(AppTypography.caption)
                            .foregroundStyle(coverage.availability.browserPrivacyTint)
                    }
                }

                Text(L10n.text(
                    "\(coverage.profileCount) 个配置文件 · \(coverage.recordCount) 条记录",
                    "\(coverage.profileCount) profiles · \(coverage.recordCount) records"
                ))
                .font(AppTypography.caption.monospacedDigit())
                .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                if let detail = coverage.detail, !detail.isEmpty {
                    Text(detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if coverage.requiresFullDiskAccess {
                    Text(L10n.text(
                        "下一步：检查系统设置授权",
                        "Next: Check System Settings access"
                    ))
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(coverage.browser.displayName)，\(coverage.availability.browserPrivacyTitle)")
    }
}

private struct BrowserPrivacyDisplayItemRow: View {
    @Environment(\.moduleTheme) private var theme

    let item: BrowserPrivacyDisplayItem
    let selectionState: BrowserPrivacySelectionState
    let isDisabled: Bool
    let isBrowserRunning: Bool
    let toggleSelection: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: toggleSelection) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Image(systemName: selectionImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selectionState == .unchecked
                        ? theme.secondaryText
                        : AppDesignTokens.Palette.accent)

                BrowserPrivacyRecordIdentityView(item: item)
                    .layoutPriority(1)

                Spacer(minLength: AppDesignTokens.Spacing.small)

                badge(item.risk.browserPrivacyTitle, tint: item.risk.browserPrivacyTint)
                badge(
                    item.selectionEligibility.browserPrivacyTitle,
                    tint: item.selectionEligibility == .selectableWithConfirmation
                        ? AppDesignTokens.Palette.accent
                        : theme.secondaryText
                )
                if isBrowserRunning {
                    badge(L10n.text("运行中", "Running"), tint: AppDesignTokens.Palette.warning)
                }
            }
            .contentShape(Rectangle())
        }
        .appButtonChrome(.toolbar)
        .disabled(isDisabled || !item.selectionEligibility.canSelect)
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .frame(minHeight: 72)
        .background(
            selectionState != .unchecked
                ? AppDesignTokens.Palette.selection.opacity(0.12)
                : (isHovering ? theme.primaryText.opacity(0.035) : .clear)
        )
        .onHover { isHovering = $0 }
        .accessibilityLabel(recordAccessibilityLabel)
        .accessibilityValue(selectionAccessibilityValue)
        .accessibilityHint(L10n.text(
            "切换此聚合项目中的全部访问记录",
            "Toggles every underlying visit in this aggregate item"
        ))
    }

    private var selectionImage: String {
        switch selectionState {
        case .unchecked: "square"
        case .mixed: "minus.square.fill"
        case .checked: "checkmark.square.fill"
        }
    }

    private var selectionAccessibilityValue: String {
        switch selectionState {
        case .unchecked: L10n.text("未选择", "Not selected")
        case .mixed: L10n.text("部分选择", "Partially selected")
        case .checked: L10n.text("已选择", "Selected")
        }
    }

    private var recordAccessibilityLabel: String {
        guard let record = item.records.first else {
            return L10n.text(
                "\(item.browser.displayName)，\(item.profileDisplayName)，\(item.visitCount) 次访问",
                "\(item.browser.displayName), \(item.profileDisplayName), \(item.visitCount) visits"
            )
        }
        let presentation = BrowserPrivacySafeRecordPresentation(record: record)
        return L10n.text(
            "\(presentation.accessibilityLabel)，\(item.visitCount) 次访问",
            "\(presentation.accessibilityLabel), \(item.visitCount) visits"
        )
    }

    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(AppTypography.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.11), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct BrowserPrivacyProcessingProgress: View {
    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                Text(L10n.text("正在安全处理浏览记录", "Safely Processing Browser History"))
                    .font(AppTypography.sectionTitle)
                Text(L10n.text(
                    "正在复核浏览器运行状态、路径与数据库身份，并执行事务删除和只读复读。完成前不会从列表移除任何记录。",
                    "Checking browser state, trusted paths, and database identity before transactional deletion and read-only verification. No record leaves the list before verification."
                ))
                .font(AppTypography.secondary)
                .foregroundStyle(.secondary)
            }
        }
        .padding(AppDesignTokens.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppDesignTokens.Palette.information.opacity(0.08), in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppDesignTokens.Radius.panel, style: .continuous)
                .stroke(AppDesignTokens.Palette.information.opacity(0.32), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BrowserPrivacyProcessingReportView: View {
    let report: BrowserPrivacyProcessingReport
    let selectedRecords: [BrowserPrivacyRecord]
    let reverificationStatus: BrowserPrivacyReverificationStatus?
    let onRescan: () -> Void

    @State private var manualActionFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(
                reportTitle,
                systemImage: isManualGuidanceOnly
                    ? "hand.raised.fill"
                    : (report.verifiedDeletedRecordCount > 0
                        ? "checkmark.shield.fill"
                        : "exclamationmark.shield.fill")
            )
            .font(AppTypography.sectionTitle)
            .foregroundStyle(reportTint)

            Text(reportSummary)
                .font(AppTypography.secondary)
                .foregroundStyle(.secondary)

            if let reverificationStatus {
                BrowserPrivacyReverificationStatusView(status: reverificationStatus)
            }

            if hasManualGuidance {
                manualWorkflow
            }

            ForEach(report.entries) { entry in
                HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
                    Image(systemName: entry.outcome.browserPrivacySystemImage)
                        .foregroundStyle(entry.outcome.browserPrivacyTint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                        Text("\(entry.browser.displayName) · \(entry.profileID)")
                            .font(AppTypography.metadata)
                        Text(L10n.text(
                            "\(entry.recordCount) 条记录 · \(entry.outcome.browserPrivacyTitle)",
                            "\(entry.recordCount) records · \(entry.outcome.browserPrivacyTitle)"
                        ))
                        .font(AppTypography.caption)
                        .foregroundStyle(entry.outcome.browserPrivacyTint)
                        if !entry.detail.isEmpty {
                            Text(entry.detail)
                                .font(AppTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(entry.capability.browserPrivacyTitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                }
            }
        }
        .padding(AppDesignTokens.Spacing.medium)
        .background(reportTint.opacity(0.08), in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppDesignTokens.Radius.panel, style: .continuous)
                .stroke(reportTint.opacity(0.32), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var manualWorkflow: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                manualStep(
                    number: "1",
                    title: L10n.text("按浏览器复制所选域名", "Copy Selected Domains by Browser"),
                    detail: L10n.text(
                        "页面只显示遮罩值。真实域名只保留在本次内存会话中，并且只有点击对应浏览器的复制按钮后才写入剪贴板。",
                        "This page shows masked values only. Real domains remain in this in-memory session and are written to the clipboard only after you click Copy for that browser."
                    )
                )

                if guidanceGroups.allSatisfy({ $0.domains.isEmpty }) {
                    Text(L10n.text("所选记录没有可显示的域名。", "The selected records have no displayable domains."))
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                } else {
                    ForEach(guidanceGroups) { group in
                        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                            HStack {
                                Label(group.browser.displayName, systemImage: "safari")
                                    .font(AppTypography.metadata)
                                Spacer(minLength: AppDesignTokens.Spacing.small)
                                Text(L10n.text(
                                    "\(group.recordCount) 条记录",
                                    "\(group.recordCount) records"
                                ))
                                .font(AppTypography.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }

                            Text(maskedDomainSummary(for: group))
                                .font(AppTypography.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(BrowserPrivacyManualWorkflow.historyInstruction(for: group.browser))
                                .font(AppTypography.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: AppDesignTokens.Spacing.small) {
                                Button {
                                    copyDomains(for: group)
                                } label: {
                                    Label(
                                        L10n.text(
                                            "复制 \(group.domains.count) 个域名",
                                            "Copy \(group.domains.count) Domains"
                                        ),
                                        systemImage: "doc.on.doc"
                                    )
                                }
                                .appButtonChrome(.secondary)
                                .disabled(group.domains.isEmpty)

                                Button {
                                    openHistory(for: group.browser)
                                } label: {
                                    Label(
                                        BrowserPrivacyManualWorkflow.historyRoute(for: group.browser) == nil
                                            ? L10n.text("启动 \(group.browser.displayName)", "Launch \(group.browser.displayName)")
                                            : L10n.text("打开 \(group.browser.displayName) 历史记录", "Open \(group.browser.displayName) History"),
                                        systemImage: "clock.arrow.circlepath"
                                    )
                                }
                                .appButtonChrome(.secondary)
                            }
                        }
                        .padding(AppDesignTokens.Spacing.small)
                        .background(
                            AppDesignTokens.Palette.secondaryBackground.opacity(0.66),
                            in: RoundedRectangle(
                                cornerRadius: AppDesignTokens.Radius.glassControl,
                                style: .continuous
                            )
                        )
                        .accessibilityElement(children: .contain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                manualStep(
                    number: "2",
                    title: L10n.text("打开浏览器历史页并手动处理", "Open Browser History and Process Manually"),
                    detail: L10n.text(
                        "Safari 使用 Command-Y，Chrome 使用 chrome://history/，Edge 使用 edge://history/all，Firefox 使用 Command-Shift-H；衍生浏览器只启动应用并给出说明。任何按钮都不会打开列表中的网页或自动删除内容。",
                        "Safari uses Command-Y, Chrome uses chrome://history/, Edge uses edge://history/all, and Firefox uses Command-Shift-H. Derivative browsers are only launched with guidance. No button opens a listed website or deletes anything automatically."
                    )
                )
            }

            manualStep(
                number: "3",
                title: L10n.text("处理完成后正常退出浏览器", "Quit the Browsers Normally After Processing"),
                detail: L10n.text(
                    "完成历史页操作后，从浏览器菜单正常退出，并等待窗口和菜单栏图标消失。本应用不会代替你强制退出浏览器。",
                    "After finishing in History, quit from each browser's menu and wait for its windows and menu-bar activity to disappear. This app will not force-quit a browser for you."
                )
            )

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                manualStep(
                    number: "4",
                    title: L10n.text("处理后重新扫描", "Scan Again After Processing"),
                    detail: L10n.text(
                        "确认相关浏览器已经完全退出，再回到本应用重新扫描；只有新的只读扫描不再读到记录，才能确认浏览器内操作结果。",
                        "Confirm the related browsers are fully quit, then return here and scan again. Only a new read-only scan that no longer sees a record can confirm the in-browser result."
                    )
                )
                Button(action: onRescan) {
                    Label(L10n.text("已处理，重新扫描", "Done in Browser, Scan Again"), systemImage: "arrow.clockwise")
                }
                .appButtonChrome(.primary)
                .padding(.leading, 34)
            }

            if let manualActionFeedback {
                Label(manualActionFeedback, systemImage: "info.circle")
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppDesignTokens.Spacing.small)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(
            cornerRadius: AppDesignTokens.Radius.panel,
            style: .continuous
        ))
    }

    private func manualStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            Text(number)
                .font(AppTypography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.accent)
                .frame(width: 24, height: 24)
                .background(AppDesignTokens.Palette.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppTypography.metadata)
                Text(detail)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyDomains(for group: BrowserPrivacyManualGuidanceGroup) {
        let text = BrowserPrivacyManualWorkflow.clipboardText(domains: group.domains)
        guard !text.isEmpty else {
            manualActionFeedback = L10n.text(
                "没有可复制的所选域名。",
                "There are no selected domains to copy."
            )
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        manualActionFeedback = pasteboard.setString(text, forType: .string)
            ? L10n.text(
                "已复制 \(group.browser.displayName) 的 \(group.domains.count) 个域名。",
                "Copied \(group.domains.count) domains for \(group.browser.displayName)."
            )
            : L10n.text(
                "剪贴板未接受内容，请重试。",
                "The clipboard did not accept the text. Try again."
            )
    }

    private func openHistory(for browser: BrowserPrivacyBrowser) {
        Task { @MainActor in
            let instruction = BrowserPrivacyManualWorkflow.historyInstruction(for: browser)
            if let route = BrowserPrivacyManualWorkflow.historyRoute(for: browser) {
                do {
                    try await BrowserPrivacyCleanupRouter().openNativeManagement(route)
                    manualActionFeedback = L10n.text(
                        "已请求打开 \(browser.displayName)。请在浏览器内确认后按说明操作：\(instruction)",
                        "Requested \(browser.displayName). Confirm it in the browser, then follow: \(instruction)"
                    )
                } catch {
                    manualActionFeedback = L10n.text(
                        "系统未接受 \(browser.displayName) 的打开请求。\(instruction)",
                        "The system did not accept the open request for \(browser.displayName). \(instruction)"
                    )
                }
                return
            }

            let launcher = NSWorkspaceBrowserLauncher()
            let applicationURL = browser.bundleIdentifier.flatMap {
                launcher.applicationURL(forBundleIdentifier: $0)
            } ?? browser.applicationURL
            guard let applicationURL else {
                manualActionFeedback = L10n.text(
                    "无法定位 \(browser.displayName)。\(instruction)",
                    "\(browser.displayName) could not be located. \(instruction)"
                )
                return
            }
            let accepted = await launcher.open(applicationURL: applicationURL, destinationURL: nil)
            manualActionFeedback = accepted
                ? L10n.text(
                    "已请求启动 \(browser.displayName)。\(instruction)",
                    "Requested launch of \(browser.displayName). \(instruction)"
                )
                : L10n.text(
                    "系统未接受 \(browser.displayName) 的启动请求。\(instruction)",
                    "The system did not accept the launch request for \(browser.displayName). \(instruction)"
                )
        }
    }

    private var hasManualGuidance: Bool {
        report.entries.contains {
            $0.capability == .manualBrowserGuidance || $0.outcome == .manual
        }
    }

    private var guidanceGroups: [BrowserPrivacyManualGuidanceGroup] {
        BrowserPrivacyManualWorkflow.groups(from: selectedRecords)
    }

    private func maskedDomainSummary(for group: BrowserPrivacyManualGuidanceGroup) -> String {
        let masked = group.domains.map(BrowserPrivacySafeRecordPresentation.maskedDomain)
        guard !masked.isEmpty else {
            return L10n.text("没有可复制的域名", "No domains available to copy")
        }
        return L10n.text(
            "遮罩域名：\(masked.joined(separator: "、"))",
            "Masked domains: \(masked.joined(separator: ", "))"
        )
    }

    private var isManualGuidanceOnly: Bool {
        !report.entries.isEmpty && report.entries.allSatisfy {
            $0.capability == .manualBrowserGuidance && $0.outcome == .manual
        }
    }

    private var reportSummary: String {
        if isManualGuidanceOnly {
            return L10n.text(
                "所选 \(report.selectedRecordCount) 条记录仅支持浏览器内手动处理。请按以下四步操作；本应用未修改浏览器数据库，也未自动删除任何记录。",
                "The \(report.selectedRecordCount) selected records support in-browser manual handling only. Follow the four steps below; this app did not change a browser database or delete any record automatically."
            )
        }
        return L10n.text(
            "请求 \(report.selectedRecordCount) 条 · 已删除并复读确认 \(report.verifiedDeletedRecordCount) 条 · 结果不确定 \(report.indeterminateRecordCount) 条 · 失败 \(report.failedRecordCount) 条 · 手动/不支持 \(report.manualRecordCount) 条。只有复读确认不存在的记录已从列表移除。",
            "Requested \(report.selectedRecordCount) · deleted and read-back verified \(report.verifiedDeletedRecordCount) · indeterminate \(report.indeterminateRecordCount) · failed \(report.failedRecordCount) · manual/unsupported \(report.manualRecordCount). Only records confirmed absent by read-back were removed from the list."
        )
    }

    private var reportTitle: String {
        if isManualGuidanceOnly {
            return L10n.text("浏览器内手动处理说明", "In-Browser Manual Handling Guidance")
        }
        if report.verifiedDeletedRecordCount == report.selectedRecordCount {
            return L10n.text("所选访问记录已验证删除", "Selected Visits Verified Deleted")
        }
        if report.verifiedDeletedRecordCount > 0 {
            return L10n.text("处理完成，部分记录需要注意", "Processing Complete with Attention Needed")
        }
        return L10n.text("未确认删除任何记录", "No Deletion Was Verified")
    }

    private var reportTint: Color {
        report.verifiedDeletedRecordCount == report.selectedRecordCount
            ? AppDesignTokens.Palette.success
            : AppDesignTokens.Palette.warning
    }
}

private struct BrowserPrivacyReverificationStatusView: View {
    let status: BrowserPrivacyReverificationStatus

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            if case .checking = status {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                Text(title)
                    .font(AppTypography.metadata)
                    .foregroundStyle(tint)
                Text(detail)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(0.08),
            in: RoundedRectangle(
                cornerRadius: AppDesignTokens.Radius.glassControl,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch status {
        case .checking:
            L10n.text("正在复核浏览器内处理结果", "Checking In-Browser Changes")
        case .noLongerFound:
            L10n.text("新扫描不再发现所选记录", "Selected Records No Longer Found")
        case let .stillPresent(remainingCount, _):
            L10n.text(
                "仍发现 \(remainingCount) 条所选记录",
                "\(remainingCount) Selected Records Still Present"
            )
        case .coverageIncomplete:
            L10n.text("覆盖不完整，无法确认处理结果", "Incomplete Coverage; Result Unconfirmed")
        }
    }

    private var detail: String {
        switch status {
        case let .checking(totalCount):
            L10n.text(
                "正在用新的只读快照复核 \(totalCount) 条稳定记录指纹；上次报告和分组保持可见。",
                "A new read-only snapshot is checking \(totalCount) stable record fingerprints; the previous report and groups remain visible."
            )
        case let .noLongerFound(totalCount):
            L10n.text(
                "相关浏览器已完整读取，\(totalCount) 条记录均不再出现。",
                "The relevant browsers were read completely and none of the \(totalCount) records appeared again."
            )
        case let .stillPresent(remainingCount, totalCount):
            L10n.text(
                "相关浏览器已完整读取；\(totalCount) 条记录中仍有 \(remainingCount) 条存在，可回到浏览器继续处理。",
                "The relevant browsers were read completely; \(remainingCount) of \(totalCount) records remain. Continue in the browser if needed."
            )
        case let .coverageIncomplete(totalCount):
            L10n.text(
                "权限受限、部分扫描、超时或浏览器忙碌时，未看到 \(totalCount) 条记录也不能证明它们已移除。请检查上方覆盖状态后再试。",
                "With restricted access, a partial scan, timeout, or busy browser, not seeing \(totalCount) records does not prove removal. Review coverage above and try again."
            )
        }
    }

    private var systemImage: String {
        switch status {
        case .checking: "arrow.clockwise"
        case .noLongerFound: "checkmark.shield.fill"
        case .stillPresent: "exclamationmark.circle.fill"
        case .coverageIncomplete: "questionmark.diamond.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .checking: AppDesignTokens.Palette.information
        case .noLongerFound: AppDesignTokens.Palette.success
        case .stillPresent, .coverageIncomplete: AppDesignTokens.Palette.warning
        }
    }
}

enum BrowserPrivacyRecordsEmptyStateKind: Equatable, Sendable {
    case scanning
    case filtered
    case permissionRequired
    case partial
    case completed

    static func resolve(
        scanState: BrowserPrivacyScanState,
        hasFilters: Bool,
        hasRecords: Bool,
        requiresFullDiskAccess: Bool
    ) -> Self {
        if scanState == .scanning {
            return .scanning
        }
        // Coverage warnings outrank a filter mismatch. A partial result can
        // contain rows while another profile is unreadable; showing only
        // "no records match" would hide the permission/coverage boundary and
        // could be mistaken for a complete negative result.
        if requiresFullDiskAccess || scanState == .permissionDenied {
            return .permissionRequired
        }
        if scanState == .partial {
            return .partial
        }
        // A filter mismatch is possible only when the scan actually returned
        // rows. With no coverage warning, keep the actionable filter message.
        if hasFilters && hasRecords {
            return .filtered
        }
        return .completed
    }
}

private struct BrowserPrivacyRecordsEmptyState: View {
    let scanState: BrowserPrivacyScanState
    let hasFilters: Bool
    let hasRecords: Bool
    let requiresFullDiskAccess: Bool

    private var kind: BrowserPrivacyRecordsEmptyStateKind {
        .resolve(
            scanState: scanState,
            hasFilters: hasFilters,
            hasRecords: hasRecords,
            requiresFullDiskAccess: requiresFullDiskAccess
        )
    }

    var body: some View {
        VStack(spacing: AppDesignTokens.Spacing.small) {
            if kind == .scanning {
                ProgressView()
                    .controlSize(.small)
            }
            Image(systemName: kind == .scanning ? "lock.doc" : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                .accessibilityHidden(true)
            Text(title)
                .font(AppTypography.emptyStateTitle)
            Text(detail)
                .font(AppTypography.emptyStateDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .padding(AppDesignTokens.Spacing.section)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch kind {
        case .scanning:
            return L10n.text("正在读取本机浏览记录", "Reading Local Browser Records")
        case .filtered:
            return L10n.text("没有符合当前筛选条件的记录", "No Records Match These Filters")
        case .permissionRequired:
            return L10n.text("部分浏览器需要授权", "Some Browsers Need Access")
        case .partial:
            return L10n.text("部分扫描未读取到记录", "Partial Scan Found No Readable Records")
        case .completed:
            return L10n.text("没有可显示的浏览器记录", "No Browser Records to Show")
        }
    }

    private var detail: String {
        switch kind {
        case .scanning:
            return L10n.text(
                "扫描不会打开网页、上传记录或同步浏览器数据。",
                "The scan does not open websites, upload records, or sync browser data."
            )
        case .filtered:
            return L10n.text(
                "调整来源、浏览器、时间、关键词或类别筛选后重试。",
                "Adjust source, browser, date, keyword, or category filters and try again."
            )
        case .permissionRequired:
            return L10n.text(
                "查看上方权限提示，并使用“打开系统设置”检查完全磁盘访问权限。当前结果不代表这些浏览器没有历史记录。",
                "Review the access banner above and use Open System Settings to check Full Disk Access. This result does not mean those browsers have no history."
            )
        case .partial:
            return L10n.text(
                "查看上方各浏览器的读取状态后重试；部分扫描不能证明没有历史记录。",
                "Review each browser's read status above and try again; a partial scan does not prove that no history exists."
            )
        case .completed:
            return L10n.text(
                "本次已完成的只读扫描没有返回可显示记录。可重新扫描或检查浏览器本地配置文件。",
                "The completed read-only scan returned no displayable records. You can rescan or review local browser profiles."
            )
        }
    }
}

private enum BrowserPrivacyByteFormatter {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension BrowserPrivacyRecordSource {
    var browserPrivacyTitle: String {
        switch self {
        case .history:
            L10n.text("浏览记录", "History")
        }
    }
}

private extension BrowserPrivacyRisk {
    var browserPrivacyTitle: String {
        switch self {
        case .safe: L10n.text("安全", "Safe")
        case .review: L10n.text("需确认", "Review")
        case .protected: L10n.text("受保护", "Protected")
        }
    }

    var browserPrivacyTint: Color {
        switch self {
        case .safe: AppDesignTokens.Palette.success
        case .review: AppDesignTokens.Palette.warning
        case .protected: AppDesignTokens.Palette.sensitive
        }
    }
}

private extension BrowserPrivacySelectionEligibility {
    var browserPrivacyTitle: String {
        switch self {
        case .selectable: L10n.text("可处理", "Selectable")
        case .selectableWithConfirmation: L10n.text("确认后处理", "Confirm First")
        case .browserActionOnly: L10n.text("浏览器内处理", "In Browser")
        case .forbidden: L10n.text("禁止处理", "Forbidden")
        }
    }
}

private extension BrowserPrivacyCategory {
    var browserPrivacyTitle: String {
        switch self {
        case .adult: L10n.text("成人内容", "Adult")
        case .finance: L10n.text("金融与账户", "Finance & Accounts")
        case .social: L10n.text("社交", "Social")
        case .shopping: L10n.text("购物", "Shopping")
        case .entertainment: L10n.text("娱乐", "Entertainment")
        case .search: L10n.text("搜索", "Search")
        case .productivity: L10n.text("效率", "Productivity")
        case .news: L10n.text("新闻", "News")
        case .other: L10n.text("其他", "Other")
        case .unknown: L10n.text("未知", "Unknown")
        }
    }

    var browserPrivacyTint: Color {
        switch self {
        case .adult: AppDesignTokens.Palette.sensitive
        case .finance: AppDesignTokens.Palette.warning
        case .social: AppDesignTokens.Palette.diagnostic
        case .shopping: AppDesignTokens.Palette.storage
        case .entertainment: AppDesignTokens.Palette.secondary
        case .search: AppDesignTokens.Palette.information
        case .productivity: AppDesignTokens.Palette.success
        case .news: AppDesignTokens.Palette.tertiary
        case .other, .unknown: AppDesignTokens.Palette.secondaryText
        }
    }
}

private extension BrowserPrivacySelectionConfidence {
    var browserPrivacyTitle: String {
        switch self {
        case .high: L10n.text("高置信度", "High Confidence")
        case .medium: L10n.text("中等置信度", "Medium Confidence")
        case .low: L10n.text("低置信度", "Low Confidence")
        case .unavailable: L10n.text("置信度不可用", "Confidence Unavailable")
        }
    }

    var browserPrivacyTint: Color {
        switch self {
        case .high: AppDesignTokens.Palette.accent
        case .medium: AppDesignTokens.Palette.warning
        case .low, .unavailable: AppDesignTokens.Palette.secondaryText
        }
    }
}

private extension BrowserPrivacyProviderAvailability {
    var browserPrivacyTitle: String {
        switch self {
        case .available: L10n.text("可读取", "Available")
        case .noProfiles: L10n.text("未发现配置文件", "No Profiles")
        case .permissionDenied: L10n.text("需要授权", "Permission Needed")
        case .partial: L10n.text("部分完成", "Partial")
        case .malformedSchema: L10n.text("格式不受支持", "Unsupported Format")
        case .busy: L10n.text("浏览器忙碌", "Browser Busy")
        case .timedOut: L10n.text("读取超时", "Timed Out")
        case .unavailable: L10n.text("不可用", "Unavailable")
        }
    }

    var browserPrivacySystemImage: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .permissionDenied: "lock.fill"
        case .partial, .busy, .timedOut: "exclamationmark.triangle.fill"
        case .noProfiles, .malformedSchema, .unavailable: "minus.circle"
        }
    }

    var browserPrivacyTint: Color {
        switch self {
        case .available: AppDesignTokens.Palette.success
        case .permissionDenied, .partial, .busy, .timedOut: AppDesignTokens.Palette.warning
        case .noProfiles, .malformedSchema, .unavailable: AppDesignTokens.Palette.secondaryText
        }
    }
}

private extension BrowserPrivacyWriteCapability {
    var browserPrivacyTitle: String {
        switch self {
        case .verifiedVisitDeletion:
            L10n.text("已验证访问记录删除", "Verified Visit Deletion")
        case .manualBrowserGuidance:
            L10n.text("浏览器内手动处理", "Manual Browser Guidance")
        case .unsupported:
            L10n.text("当前格式不支持", "Unsupported Format")
        }
    }
}

private extension BrowserPrivacyProcessingOutcome {
    var browserPrivacyTitle: String {
        switch self {
        case .deleted:
            L10n.text("已删除并复读确认", "Deleted and Read-back Verified")
        case .failed:
            L10n.text("失败，未确认删除", "Failed; Deletion Not Verified")
        case .indeterminate:
            L10n.text("已提交，最终复核失败", "Committed; Final Verification Failed")
        case .manual:
            L10n.text("需要浏览器内手动处理", "Manual Browser Processing Required")
        case .unsupported:
            L10n.text("不支持安全写入", "Safe Write Unsupported")
        }
    }

    var browserPrivacySystemImage: String {
        switch self {
        case .deleted: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .indeterminate: "exclamationmark.triangle.fill"
        case .manual: "hand.raised.fill"
        case .unsupported: "minus.circle.fill"
        }
    }

    var browserPrivacyTint: Color {
        switch self {
        case .deleted: AppDesignTokens.Palette.success
        case .failed: AppDesignTokens.Palette.sensitive
        case .indeterminate: AppDesignTokens.Palette.warning
        case .manual: AppDesignTokens.Palette.warning
        case .unsupported: AppDesignTokens.Palette.secondaryText
        }
    }
}
