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
                domains: normalizedDomains(records.map(\.domain)),
                pages: BrowserPrivacyDisplayItem.aggregate(records)
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
            "仅启动 \(browser.displayName)。请从该浏览器的“历史记录”菜单打开完整历史列表，再按上面列出的页面逐项核对。",
            "Only \(browser.displayName) will be launched. Open its full History list from the browser menu, then review the pages listed above one by one."
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

/// Writes browsing data the user chose to copy. The content is marked
/// concealed and transient (nspasteboard.org), so clipboard managers that
/// honour the markers neither show nor keep it in their history.
enum BrowserPrivacyClipboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @discardableResult
    static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
        return pasteboard.setString(text, forType: .string)
            && pasteboard.setData(Data(), forType: concealedType)
            && pasteboard.setData(Data(), forType: transientType)
    }
}

/// The text of the deletion confirmations. Every page is listed under what
/// will actually happen to it: deleted, deleted only if its running browser
/// quits, or handled in the browser.
enum BrowserPrivacyConfirmationText {
    /// Direct deletion with no selected browser running.
    static func deletionMessage(
        records: [BrowserPrivacyRecord],
        includesIncompletelyReadProfiles: Bool,
        disclosure: BrowserPrivacyDisclosurePolicy? = nil
    ) -> String {
        let disclosure = disclosure ?? .protecting(records)
        let direct = records.filter { $0.locator != nil }
        let manual = records.filter { $0.locator == nil }
        var sections = [L10n.text(
            "将删除 \(visits(direct))（\(browsers(direct))）：\n\(pageLines(direct, disclosure: disclosure))",
            "This deletes \(visits(direct)) in \(browsers(direct)):\n\(pageLines(direct, disclosure: disclosure))"
        )]
        sections += commonSections(
            manual: manual,
            includesIncompletelyReadProfiles: includesIncompletelyReadProfiles,
            disclosure: disclosure
        )
        return sections.joined(separator: "\n\n")
    }

    /// Direct deletion while some selected browsers are running. The user
    /// either quits them or skips them, so their pages are listed apart.
    static func preflightMessage(
        records: [BrowserPrivacyRecord],
        runningBrowserIDs: Set<String>,
        includesIncompletelyReadProfiles: Bool,
        disclosure: BrowserPrivacyDisclosurePolicy? = nil
    ) -> String {
        let disclosure = disclosure ?? .protecting(records)
        let direct = records.filter { $0.locator != nil }
        let running = direct.filter { runningBrowserIDs.contains($0.browser.id) }
        let others = direct.filter { !runningBrowserIDs.contains($0.browser.id) }
        var sections = [L10n.text(
            "直接清理前浏览器必须正常退出，这样才能重新核对数据库和所选访问记录。不会强制结束浏览器进程。",
            "Browsers must quit normally before direct cleanup so the database and the selected visits can be checked again. The app never force-quits a browser."
        )]
        if !running.isEmpty {
            sections.append(L10n.text(
                "正在运行的 \(browsers(running)) 里的 \(visits(running))：选择“正常退出并继续”会删除，选择“跳过运行中的浏览器”则跳过、不处理：\n\(pageLines(running, disclosure: disclosure))",
                "\(visits(running)) in the running \(browsers(running)): Quit Normally and Continue deletes them; Skip Running Browsers leaves them untouched:\n\(pageLines(running, disclosure: disclosure))"
            ))
        }
        if !others.isEmpty {
            sections.append(L10n.text(
                "其他浏览器（\(browsers(others))）里的 \(visits(others))，两种选择都会删除：\n\(pageLines(others, disclosure: disclosure))",
                "\(visits(others)) in other browsers (\(browsers(others))) are deleted either way:\n\(pageLines(others, disclosure: disclosure))"
            ))
        }
        sections += commonSections(
            manual: records.filter { $0.locator == nil },
            includesIncompletelyReadProfiles: includesIncompletelyReadProfiles,
            disclosure: disclosure
        )
        return sections.joined(separator: "\n\n")
    }

    /// D93: the six fixed confirmation fields for the selected visits.
    static func facts(
        records: [BrowserPrivacyRecord],
        runningBrowserIDs: Set<String>,
        fullDiskAccessBrowsers: [String]
    ) -> OperationConfirmationFacts {
        let direct = records.filter { $0.locator != nil }
        return .browserHistory(
            directRecordCount: direct.count,
            manualRecordCount: records.count - direct.count,
            browsers: Array(Set(records.map { $0.browser.displayName })).sorted(),
            runningBrowsers: OperationQuitNotice.runningBrowserNames(selected: records, runningBrowserIDs: runningBrowserIDs).sorted(),
            fullDiskAccessBrowsers: fullDiskAccessBrowsers
        )
    }

    /// Only in-browser steps; nothing is written.
    static func manualMessage(records: [BrowserPrivacyRecord], disclosure: BrowserPrivacyDisclosurePolicy? = nil) -> String {
        let disclosure = disclosure ?? .protecting(records)
        return L10n.text(
            "将为 \(visits(records))（\(browsers(records))）生成浏览器内的处理步骤：\n\(pageLines(records, disclosure: disclosure))\n\n本应用不会修改这些浏览器的数据库。",
            "This prepares in-browser steps for \(visits(records)) in \(browsers(records)):\n\(pageLines(records, disclosure: disclosure))\n\nThis app will not modify these browsers' databases."
        )
    }

    private static func commonSections(
        manual: [BrowserPrivacyRecord],
        includesIncompletelyReadProfiles: Bool,
        disclosure: BrowserPrivacyDisclosurePolicy
    ) -> [String] {
        var sections: [String] = []
        if !manual.isEmpty {
            sections.append(L10n.text(
                "另有 \(visits(manual))只能在浏览器内处理，稍后会给出步骤：\n\(pageLines(manual, disclosure: disclosure))",
                "\(visits(manual)) more can only be handled in the browser; the steps follow afterwards:\n\(pageLines(manual, disclosure: disclosure))"
            ))
        }
        if includesIncompletelyReadProfiles {
            sections.append(L10n.text(
                "部分配置文件这次没有读取全部记录（超过单个配置文件的读取上限）。只会删除已读取到的访问；同一页面更早的访问不会被删除。",
                "Some profiles were not read completely this time (they exceed the per-profile read limit). Only the visits that were read are deleted; earlier visits of the same pages stay."
            ))
        }
        sections.append(L10n.text(
            "删除前会先备份浏览器的历史数据库，删除后重新读取确认；数据库结构不受支持的配置文件不会被修改。\(BrowserPrivacyRecoveryText.retentionNotice)书签、密码、Cookie、自动填充和未选的访问记录不受影响。",
            "The browser's history database is backed up first and read again afterwards; profiles with an unsupported database schema are not modified. \(BrowserPrivacyRecoveryText.retentionNotice) Bookmarks, passwords, cookies, autofill and unselected visits are not affected."
        ))
        return sections
    }

    private static func visits(_ records: [BrowserPrivacyRecord]) -> String {
        BrowserPrivacyCountText.visits(records.count)
    }

    private static func browsers(_ records: [BrowserPrivacyRecord]) -> String {
        Array(Set(records.map { $0.browser.displayName })).sorted()
            .joined(separator: L10n.text("、", ", "))
    }

    private static func pageLines(_ records: [BrowserPrivacyRecord], disclosure: BrowserPrivacyDisclosurePolicy) -> String {
        BrowserPrivacyPageListText.lines(for: BrowserPrivacyDisplayItem.aggregate(records), disclosure: disclosure)
            .joined(separator: "\n")
    }
}

struct BrowserPrivacyProfileOption: Identifiable, Equatable, Sendable {
    /// The profile identifier the filter stores.
    let id: String
    /// "Browser · profile name" as shown in the filter menu.
    let title: String
}

struct BrowserPrivacyManualGuidanceGroup: Identifiable, Equatable {
    let browser: BrowserPrivacyBrowser
    let recordCount: Int
    let domains: [String]
    /// The selected pages, newest first, so they can be found in the browser.
    let pages: [BrowserPrivacyDisplayItem]

    var id: String { browser.id }
}

/// Record URLs stay local and are never opened. Canonical browsers use only
/// audited native history routes; derivatives are launched without a URL.
struct BrowserPrivacyRecordResultsView: View {
    private struct BulkSelectionRequest {
        let title: String
        let recordIDs: Set<UUID>
        var removingIDs: Set<UUID> = []
    }

    @ObservedObject var store: BrowserPrivacyStore
    /// D91: opens the cookie/other-data page from the skeleton's status bar.
    var onShowDataTypes: (() -> Void)? = nil
    @Environment(\.moduleTheme) private var theme
    /// Reads the recovery folder only when "Recent Deletions" is opened.
    @StateObject private var recoveryStore = BrowserPrivacyRecoveryStore()

    @State private var isShowingProcessingConfirmation = false
    @State private var isShowingReviewSelectionConfirmation = false
    @State private var isShowingRunningBrowserPreflight = false
    @State private var showsBulkSelection = false
    @State private var pendingBulkSelection: BulkSelectionRequest?
    @State private var searchQuery = ""
    @State private var showsPermissionDetails = false
    @State private var showsCoverageDetails = false
    @State private var showsRecentDeletions = false
    /// Built when a confirmation is requested, so the selected pages are not
    /// re-aggregated on every redraw.
    @State private var processingConfirmationMessage = ""
    @State private var runningBrowserConfirmationMessage = ""

    var body: some View {
        FeatureLightfieldPage(module: .privacy, phase: .result, title: ReviewFilter.privacy.title,
            status: selectionSummaryDetail,
            safety: L10n.text("只删除所选浏览记录 · 保留书签和密码", "Delete selected history only · Keep bookmarks and passwords"),
            actionTitle: lightfieldActionTitle,
            actionEnabled: !store.isFiltering && !store.selectedRecordIDs.isEmpty && !store.isProcessing
                && !store.isRunningBrowserPreflight && store.state != .scanning,
            showsArtwork: false,
            statusActionTitle: BrowserPrivacyWorkspaceView.dataTypesTitle,
            statusActionEnabled: !store.isProcessing && store.state != .scanning,
            statusAction: onShowDataTypes, action: beginProcessingConfirmation) {
            BrowserPrivacyLightfieldResults(store: store, searchQuery: $searchQuery,
                notices: { lightfieldNotices }, utilities: { lightfieldUtilities },
                showsRecords: !store.isProcessing && store.processingReport == nil,
                pageRow: { AnyView(lightfieldPageRow($0)) },
                selectAll: { if !store.isFiltering { isShowingReviewSelectionConfirmation = true } },
                requestSelection: requestGroupSelection)
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
                guard !store.isFiltering else { return }
                store.setSelection(true,
                    recordIDs: BrowserPrivacyLightfieldPresentation.deletableIDs(store.filteredRecords),
                    confirmingReview: true)
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
                "加入 \(pendingSelectionSummary) 到已选",
                "Add \(pendingSelectionSummary) to Selection"
            )) {
                if let request = pendingBulkSelection {
                    store.setSelection(false, recordIDs: request.removingIDs)
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
                "只加入选择，不立即删除；清理前确认、复核并备份，删除后回读验证",
                "Adds to selection only; confirm, check and back up before deletion, then verify by read-back"
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
            Text(runningBrowserConfirmationMessage)
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            searchQuery = store.filters.query
        }
        .task(id: searchQuery) {
            store.filters.query = searchQuery
        }
    }

    private var lightfieldActionTitle: String {
        if store.isProcessing { return L10n.text("正在处理", "Processing") }
        if !store.selectedRecordIDs.isEmpty && !store.selectedRecordsContainVerifiedDeletionCandidate {
            return L10n.text("在浏览器内处理 · \(store.selectedRecordIDs.count) 条", "Handle in browser · \(store.selectedRecordIDs.count) records")
        }
        return L10n.text("删除所选记录 · \(store.selectedVerifiedDeletionCandidateCount) 条", "Delete selected records · \(store.selectedVerifiedDeletionCandidateCount) records")
    }

    @ViewBuilder private var lightfieldNotices: some View {
        if store.isRefreshingCachedResults || (store.error != nil && store.hasCachedResults) { refreshStatus }
        if requiresFullDiskAccess { permissionBanner }
        if !store.isProcessing, store.processingReport == nil, let notice = runningBrowserSelectionNotice {
            Label(notice, systemImage: "app.badge")
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if store.isProcessing {
            BrowserPrivacyProcessingProgress()
        } else if let report = store.processingReport {
            BrowserPrivacyProcessingReportView(report: report, selectedRecords: store.manualGuidanceRecords,
                reverificationStatus: store.reverificationStatus, onRescan: store.startScan,
                removeBackup: { await recoveryStore.remove(backupID: $0) }, disclosure: store.disclosurePolicy,
                presentationRecords: store.reportPresentationRecords,
                revealSensitive: { store.revealSensitiveSites(in: store.reportPresentationRecords) })
        } else if !store.isFiltering && store.filteredRecords.isEmpty {
            BrowserPrivacyRecordsEmptyState(scanState: store.state, hasFilters: hasActiveFilters,
                hasRecords: !store.records.isEmpty, requiresFullDiskAccess: requiresFullDiskAccess)
        }
    }

    private var lightfieldUtilities: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { utilityButtons }
            VStack(alignment: .leading, spacing: 12) { utilityButtons }
        }
        .font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(lightfieldScheme).fg2)
    }
    @Environment(\.colorScheme) private var lightfieldScheme

    @ViewBuilder private var utilityButtons: some View {
        Button(L10n.text("重新扫描", "Scan Again"), action: store.startScan)
            .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(store.isProcessing || store.state == .scanning)
        Button(L10n.text("读取状态", "Read Status")) { showsCoverageDetails.toggle() }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .popover(isPresented: $showsCoverageDetails) { coverageDetails }
        Button(L10n.text("最近的删除", "Recent Deletions")) { showsRecentDeletions.toggle() }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .popover(isPresented: $showsRecentDeletions) {
                BrowserPrivacyRecentDeletionsView(recoveryStore: recoveryStore,
                    isBusy: store.state == .scanning || store.isProcessing,
                    onRescan: { showsRecentDeletions = false; store.startScan() })
            }
        Button(L10n.text("批量选择", "Bulk Select")) { showsBulkSelection.toggle() }
            .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(store.isFiltering || store.isProcessing || store.state == .scanning)
            .popover(isPresented: $showsBulkSelection) {
                if let snapshot = store.resultPresentation {
                    BrowserPrivacyBulkSelectionView(presentation: snapshot.bulk,
                        isDisabled: store.isFiltering || store.state == .scanning || store.isProcessing, onSelect: requestBulkSelection)
                }
            }
        sortMenu
        advancedFiltersMenu
    }

    private func lightfieldPageRow(_ item: BrowserPrivacyDisplayItem) -> some View {
        let expanded = store.expandedItemIDs.contains(item.id)
        return BrowserPrivacyLightfieldPageRow(item: item, selectedIDs: store.selectedRecordIDs,
            expanded: expanded, disabled: store.isFiltering || store.isProcessing || store.state == .scanning,
            select: {
                guard !store.isFiltering else { return }
                store.setSelected(store.selectionState(for: item) != .checked, displayItem: item)
            },
            disclose: { store.setExpanded(!expanded, itemID: item.id) },
            visit: { if !store.isFiltering { store.toggleSelection($0) } }, disclosure: store.disclosurePolicy)
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

    private var sortMenu: some View {
        Menu {
            Picker(L10n.text("排序", "Sort"), selection: $store.resultSort) {
                ForEach(BrowserPrivacyResultSort.allCases, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
        } label: {
            Text(L10n.text("排序", "Sort"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.text("结果排序", "Sort Results"))
        .accessibilityValue(store.resultSort.title)
        .help(L10n.text("页面排序：\(store.resultSort.title)", "Page order: \(store.resultSort.title)"))
    }

    private var advancedFiltersMenu: some View {
        Menu {
            Picker(L10n.text("浏览器", "Browser"), selection: browserFilterBinding) {
                Text(L10n.text("所有浏览器", "All Browsers")).tag(Optional<String>.none)
                ForEach(browsers) { browser in
                    Text(browser.displayName).tag(browser.id as String?)
                }
            }

            if profileOptions.count > 1 {
                Picker(L10n.text("配置文件", "Profile"), selection: filterBinding(\.profileID)) {
                    Text(L10n.text("所有配置文件", "All Profiles")).tag(Optional<String>.none)
                    ForEach(profileOptions) { option in
                        Text(option.title).tag(option.id as String?)
                    }
                }
            }

            Picker(L10n.text("类别", "Category"), selection: filterBinding(\.category)) {
                Text(L10n.text("所有类别", "All Categories")).tag(Optional<BrowserPrivacyCategory>.none)
                ForEach(BrowserPrivacyCategory.allCases, id: \.self) { category in
                    Text(category.title).tag(category as BrowserPrivacyCategory?)
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
            Text(L10n.text("筛选", "Filters"))
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

    private var selectionSummaryDetail: String {
        if store.selectedRecordIDs.isEmpty {
            return L10n.text("未选择访问记录", "No visits selected")
        }
        let visits = store.disclosurePolicy.summary(store.selectedRecords)
        return L10n.text("已选择 \(visits)", "\(visits) selected")
    }

    private var processingConfirmationTitle: String {
        store.selectedRecordsContainVerifiedDeletionCandidate
            ? L10n.text("确认清理所选浏览记录", "Confirm Selected History Cleanup")
            : L10n.text("准备在浏览器内处理", "Prepare In-Browser Handling")
    }

    private func beginProcessingConfirmation() {
        guard !store.isFiltering else { return }
        let records = store.selectedRecords
        let incomplete = store.selectionIncludesIncompletelyReadProfiles
        // D93: the same six fields as every other confirmation, as text.
        let facts = BrowserPrivacyConfirmationText.facts(
            records: records,
            runningBrowserIDs: store.selectedRunningBrowserIDs,
            fullDiskAccessBrowsers: fullDiskAccessBrowserNames
        ).plainText + "\n\n"
        processingConfirmationMessage = facts + (store.selectedRecordsContainVerifiedDeletionCandidate
            ? BrowserPrivacyConfirmationText.deletionMessage(
                records: records,
                includesIncompletelyReadProfiles: incomplete, disclosure: store.disclosurePolicy
            )
            : BrowserPrivacyConfirmationText.manualMessage(records: records, disclosure: store.disclosurePolicy))
        runningBrowserConfirmationMessage = facts + BrowserPrivacyConfirmationText.preflightMessage(
            records: records,
            runningBrowserIDs: store.selectedRunningBrowserIDs,
            includesIncompletelyReadProfiles: incomplete, disclosure: store.disclosurePolicy
        )
        if store.selectedRecordsContainVerifiedDeletionCandidate,
           !store.selectedRunningBrowserIDs.isEmpty {
            isShowingRunningBrowserPreflight = true
        } else {
            isShowingProcessingConfirmation = true
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
                    "刷新期间保留记录与选择，暂不能处理",
                    "Records and selection stay visible; processing is unavailable during refresh"
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
                detail: "",
                tint: error == .cancelled
                    ? AppDesignTokens.Palette.secondaryText
                    : AppDesignTokens.Palette.warning,
                isLoading: false
            )
        }
    }

    private var browsers: [BrowserPrivacyBrowser] {
        (store.resultPresentation?.browsers ?? []).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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

    private var profileOptions: [BrowserPrivacyProfileOption] {
        guard let snapshot = store.resultPresentation else { return [] }
        if let browserID = store.filters.browserID { return snapshot.profilesByBrowser[browserID] ?? [] }
        return snapshot.allProfiles
    }

    /// Profiles are listed by the name the browser shows, prefixed with the
    /// browser so two "Default" profiles stay distinguishable.
    nonisolated static func profileOptions(
        from records: [BrowserPrivacyRecord],
        browserID: String?
    ) -> [BrowserPrivacyProfileOption] {
        var options: [String: BrowserPrivacyProfileOption] = [:]
        for record in records where browserID == nil || record.browser.id == browserID {
            guard options[record.profileID] == nil else { continue }
            options[record.profileID] = BrowserPrivacyProfileOption(
                id: record.profileID,
                title: "\(record.browser.displayName) · \(record.resolvedProfileDisplayName)"
            )
        }
        return options.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
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

    private var fullDiskAccessBrowserNames: [String] {
        var seen = Set<String>()
        return store.coverage.filter(\.requiresFullDiskAccess).map(\.browser.displayName)
            .filter { seen.insert($0).inserted }
    }

    /// D93: said when the records are checked, not only when cleanup starts.
    /// Only records deleted directly need their browser to quit (P2-5).
    private var runningBrowserSelectionNotice: String? {
        OperationQuitNotice.text(runningBrowsers: OperationQuitNotice.runningBrowserNames(
            selected: store.selectedRecords, runningBrowserIDs: store.selectedRunningBrowserIDs))
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
        guard !store.isFiltering else { return }
        let recordIDs = scope.matchingRecordIDs(in: store.records, disclosure: store.disclosurePolicy)
        guard !recordIDs.isEmpty else { return }
        showsBulkSelection = false
        pendingBulkSelection = BulkSelectionRequest(
            title: scope.title,
            recordIDs: recordIDs
        )
    }

    private var pendingSelectionSummary: String {
        store.disclosurePolicy.summary(store.records(for: pendingBulkSelection?.recordIDs ?? []))
    }

    private func requestGroupSelection(_ adding: Set<UUID>, _ removing: Set<UUID>, _ title: String) {
        guard !store.isFiltering else { return }
        // Keep the existing review confirmation for bulk additions. A pure
        // deselection is immediate; inversion is applied only after approval.
        if adding.isEmpty {
            store.setSelection(false, recordIDs: removing)
        } else {
            pendingBulkSelection = BulkSelectionRequest(title: title, recordIDs: adding, removingIDs: removing)
        }
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
                if !detail.isEmpty {
                    Text(detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }
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

private struct BrowserPrivacyProcessingProgress: View {
    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                Text(L10n.text("正在安全处理浏览记录", "Safely Processing Browser History"))
                    .font(AppTypography.sectionTitle)
                Text(L10n.text(
                    "复核删除并回读，核验前保留记录，请勿打开浏览器",
                    "Check, delete and verify; records stay until verified; keep browsers closed"
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

struct BrowserPrivacyProcessingReportView: View {
    let report: BrowserPrivacyProcessingReport
    let selectedRecords: [BrowserPrivacyRecord]
    let reverificationStatus: BrowserPrivacyReverificationStatus?
    let onRescan: () -> Void
    /// Deletes the app's own backup; returns whether it is gone.
    let removeBackup: (UUID) async -> Bool
    var disclosure: BrowserPrivacyDisclosurePolicy = .init()
    /// All processed records protect receipt text after verified removals.
    /// Manual steps continue to use only the original browser-only subset.
    var presentationRecords: [BrowserPrivacyRecord]? = nil
    var revealSensitive: () -> Void = {}
    private var receiptRecords: [BrowserPrivacyRecord] { presentationRecords ?? selectedRecords }

    @State private var manualActionFeedback: String?
    @State private var pendingBackupRemoval: UUID?
    @State private var removedBackupIDs = Set<UUID>()
    @State private var failedBackupRemovals = Set<UUID>()

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

            // D93: completed / skipped / failed / needs verification per profile;
            // deleting history frees no disk space.
            OperationCompletionTallyView(tally: OperationCompletionTally(browser: report), showsEntryDetails: false)

            if receiptRecords.contains(where: disclosure.isConcealed) {
                Text(disclosure.summary(receiptRecords)).font(AppTypography.caption)
                Button(L10n.text("展开敏感网站", "Reveal Sensitive Websites"), action: revealSensitive)
                    .appButtonChrome(.secondary)
            }

            if let reverificationStatus {
                BrowserPrivacyReverificationStatusView(status: reverificationStatus)
            }

            if report.entries.contains(where: {
                $0.recoveryBackupID.map { !removedBackupIDs.contains($0) } ?? false
            }) {
                Text(L10n.text(
                        "\(BrowserPrivacyRecoveryText.retentionNotice)需要撤销时，在工具栏的“最近的删除”里恢复。",
                        "\(BrowserPrivacyRecoveryText.retentionNotice) To undo, restore it from Recent Deletions in the toolbar."
                    ))
                .font(AppTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                        Text("\(entry.browser.displayName) · \(entry.resolvedProfileDisplayName)")
                            .font(AppTypography.metadata)
                        Text(BrowserPrivacyReportDisclosurePresentation.count(entry, records: receiptRecords, disclosure: disclosure)
                            + " · " + entry.outcome.browserPrivacyTitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(entry.outcome.browserPrivacyTint)
                        let detail = BrowserPrivacyReportDisclosurePresentation.detail(entry, records: receiptRecords, disclosure: disclosure)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(AppTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let backupID = entry.recoveryBackupID {
                            backupControl(backupID)
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
                        "所选页面仅在本次内存会话保留；点击复制才写入剪贴板",
                        "Selected pages stay in this memory session; copying writes to the clipboard only on click"
                    )
                )

                ForEach(guidanceGroups) { group in
                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                        HStack {
                            Text(group.browser.displayName)
                                .font(AppTypography.metadata)
                            Spacer(minLength: AppDesignTokens.Spacing.small)
                            Text(BrowserPrivacyCountText.pagesAndVisits(
                                pages: group.pages.count,
                                visits: group.recordCount
                            ))
                            .font(AppTypography.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        Text(BrowserPrivacyPageListText.siteSummary(group.domains))
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        // Titles and addresses are not selectable; only the
                        // site names above are.
                        Text(BrowserPrivacyPageListText.lines(for: group.pages, disclosure: disclosure).joined(separator: "\n"))
                            .font(AppTypography.caption)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(BrowserPrivacyManualWorkflow.historyInstruction(for: group.browser))
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: AppDesignTokens.Spacing.small) {
                            Button {
                                copyDomains(for: group)
                            } label: {
                                Text(L10n.text(
                                        "复制 \(group.domains.count) 个域名",
                                        "Copy \(group.domains.count) Domains"
                                    ))
                            }
                            .appButtonChrome(.secondary)
                            .disabled(group.domains.isEmpty)

                            Button {
                                openHistory(for: group.browser)
                            } label: {
                                Text(BrowserPrivacyManualWorkflow.historyRoute(for: group.browser) == nil
                                        ? L10n.text("启动 \(group.browser.displayName)", "Launch \(group.browser.displayName)")
                                        : L10n.text("打开 \(group.browser.displayName) 历史记录", "Open \(group.browser.displayName) History"))
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
                    Text(L10n.text("已处理，重新扫描", "Done in Browser, Scan Again"))
                }
                .appButtonChrome(.primary)
                .padding(.leading, 34)
            }

            if let manualActionFeedback {
                Text(manualActionFeedback)
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

    /// "Delete this backup", asking first. The backup is the app's own copy
    /// of the history, so it is deleted directly, not moved to the Trash.
    @ViewBuilder
    private func backupControl(_ backupID: UUID) -> some View {
        if removedBackupIDs.contains(backupID) {
            Text(L10n.text("备份已删除", "Backup Deleted"))
                .font(AppTypography.caption)
                .foregroundStyle(.secondary)
        } else if pendingBackupRemoval == backupID {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                Label(
                    BrowserPrivacyRecoveryText.removalWarning(createdAt: nil),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    Button(L10n.text("取消", "Cancel")) {
                        pendingBackupRemoval = nil
                    }
                    .appButtonChrome(.secondary)
                    Button(L10n.text("删除这份备份", "Delete This Backup")) {
                        pendingBackupRemoval = nil
                        Task {
                            if await removeBackup(backupID) {
                                removedBackupIDs.insert(backupID)
                                failedBackupRemovals.remove(backupID)
                            } else {
                                failedBackupRemovals.insert(backupID)
                            }
                        }
                    }
                    .appButtonChrome(.destructive)
                }
            }
            .padding(AppDesignTokens.Spacing.small)
            .background(
                AppDesignTokens.Palette.warning.opacity(0.10),
                in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.glassControl, style: .continuous)
            )
        } else {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Button {
                    pendingBackupRemoval = backupID
                } label: {
                    Text(L10n.text("删除这份备份…", "Delete This Backup…"))
                }
                .appButtonChrome(.secondary)
                if failedBackupRemovals.contains(backupID) {
                    Text(L10n.text(
                        "没能删除备份，可在“最近的删除”里再试。",
                        "The backup could not be deleted; try again in Recent Deletions."
                    ))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                }
            }
        }
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
        manualActionFeedback = BrowserPrivacyClipboard.write(text, to: NSPasteboard.general)
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
        BrowserPrivacyManualWorkflow.groups(from: disclosure.visibleRecords(selectedRecords))
    }

    private var isManualGuidanceOnly: Bool {
        !report.entries.isEmpty && report.entries.allSatisfy {
            $0.capability == .manualBrowserGuidance && $0.outcome == .manual
        }
    }

    private var reportSummary: String {
        if isManualGuidanceOnly {
            return L10n.text(
                "所选 \(report.selectedRecordCount) 次访问只能在浏览器内手动处理。请按以下四步操作；本应用未修改浏览器数据库，也未自动删除任何记录。",
                "The \(BrowserPrivacyCountText.visits(report.selectedRecordCount)) selected can only be handled manually in the browser. Follow the four steps below; this app did not change a browser database or delete any record automatically."
            )
        }
        return L10n.text(
            "共 \(report.selectedRecordCount) 次访问 · 已删除并重新读取确认 \(report.verifiedDeletedRecordCount) 次 · 结果未确认 \(report.indeterminateRecordCount) 次 · 失败 \(report.failedRecordCount) 次 · 需在浏览器内处理 \(report.manualRecordCount) 次。只有重新读取确认已不存在的记录才从列表移除。",
            "\(BrowserPrivacyCountText.visits(report.selectedRecordCount)) requested · \(report.verifiedDeletedRecordCount) deleted and confirmed by a fresh read · \(report.indeterminateRecordCount) unconfirmed · \(report.failedRecordCount) failed · \(report.manualRecordCount) to handle in the browser. Only records confirmed absent by the fresh read left the list."
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
            Text(title)
                .font(AppTypography.emptyStateTitle)
            if !detail.isEmpty {
                Text(detail)
                    .font(AppTypography.emptyStateDetail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }
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
            return ""
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
