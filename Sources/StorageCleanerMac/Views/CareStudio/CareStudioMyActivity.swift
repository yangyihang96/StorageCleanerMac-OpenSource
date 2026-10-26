import SwiftUI

/// D187 adds existing health evidence, explicitly estimated manual time,
/// and read-only recommendations ahead of D154's recorded statistics.
struct CareStudioMyActivityPage: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var healthStore: ComputerHealthStore
    @ObservedObject private var privacy: BrowserPrivacyStore
    @ObservedObject private var maintenance: SystemMaintenanceStore
    @ObservedObject private var cloud: CloudCleanupModel
    @Environment(\.featureOperationHistoryAction) private var openOperationHistory
    @State private var summary: MyActivitySummary?
    @State private var isLoading = false
    @State private var mac: MyActivityMacInfo
    @State private var showsAllRecommendations = false
    private let usesInjectedEvidence: Bool
    private let now: () -> Date
    private let onNavigate: ((ReviewFilter) -> Void)?

    init(store: ScanStore, healthStore: ComputerHealthStore? = nil, privacy: BrowserPrivacyStore? = nil,
         cloud: CloudCleanupModel? = nil, summary: MyActivitySummary? = nil, mac: MyActivityMacInfo? = nil,
         now: @escaping () -> Date = Date.init, onNavigate: ((ReviewFilter) -> Void)? = nil) {
        self.store = store
        self.healthStore = healthStore ?? ComputerHealthStore()
        self.privacy = privacy ?? BrowserPrivacyStore()
        self.maintenance = ToolboxStores.of(store).maintenance
        self.cloud = cloud ?? .shared
        self._summary = State(initialValue: summary)
        self._mac = State(initialValue: mac ?? MyActivityMacInfo())
        self.usesInjectedEvidence = summary != nil || mac != nil
        self.now = now
        self.onNavigate = onNavigate
    }

    var body: some View {
        CareStudioHubFrame(module: .myActivity) {
            CareStudioHubScroll {
                VStack(alignment: .leading, spacing: 22) {
                    CareStudioHubHeader(title: CareStudioModule.myActivity.title, subtitle: subtitle) {
                        if let openOperationHistory {
                            CareStudioPillButton(title: L10n.text("操作记录", "Operation History"),
                                                 systemImage: "clock.arrow.circlepath", action: openOperationHistory)
                        }
                    }
                    overviewCards
                    cards
                    if let summary, summary.unreadableCount > 0 {
                        CareStudioNotice(systemImage: "exclamationmark.triangle",
                            text: L10n.text("\(ByteFormat.count(summary.unreadableCount)) 份记录无法读取；统计和估算只含可读取的结果。",
                                            "\(ByteFormat.count(summary.unreadableCount)) records could not be read; totals and estimates include only readable results."))
                    }
                    recommendationsSection
                    recentSection
                }
                .padding(.horizontal, CareStudioMetrics.pageInset)
                .padding(.top, 24)
                .padding(.bottom, 36)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            guard !usesInjectedEvidence else { return }
            mac = await Task.detached(priority: .utility) { MyActivityMacInfo.read() }.value
            cloud.refreshProviders()
            await load()
        }
        .onChange(of: store.operationReports) { _, _ in
            if !usesInjectedEvidence { Task { await load() } }
        }
        .sheet(isPresented: $showsAllRecommendations) {
            CareStudioActivityRecommendationsList(recommendations: recommendations, onOpen: open,
                                                  onClose: { showsAllRecommendations = false })
                .environment(\.locale, L10n.locale)
        }
    }

    var health: MyActivityHealth {
        MyActivityHealth.evaluate(MyActivityHealth.latest(healthStore.snapshot, store.smartScanHealthSnapshot), now: now())
    }

    var savings: MyActivityTimeSavings {
        MyActivityTimeSavings(records: (summary?.timeSavingsRecords ?? []) + MyActivityTimeSavings.retainedRecords(
            updates: store.appUpdateQueueSnapshot, website: store.websiteUpdateQueueSnapshot,
            maintenance: Array(maintenance.results.values), privacy: privacy.processingReport))
    }

    var recommendationState: MyActivityRecommendations.State {
        var value = MyActivityRecommendations.State()
        value.health = health
        value.latestSmartScanAt = (store.scanHistorySummary.entries.filter { $0.smartScanScopes != nil }.map(\.date)
            + [store.smartScanHealthSnapshot?.generatedAt].compactMap { $0 }).max()
        value.recoverableTrashBytes = summary?.recoverableTrashBytes ?? 0
        // Integration (D190): confirmed newer versions only, the same count as
        // the Applications tile (was every row whose status reads available).
        value.availableUpdateCount = AppUpdateCatalogSnapshot(sessionID: UUID(), applications: store.appUpdates)
            .confirmedUpdateCount
        value.loginItemCount = StartupItemsPresentation.make(items: store.startupDomainItems, query: "", category: .all,
            status: .all, source: .all, includeAppleSystem: false, sort: .recommended,
            includeTechnicalDetails: false).count(for: .loginItems)
        value.managedItemCoverageAvailable = store.startupCoverage.managedItemCoverageAvailable
        value.recommendedMaintenanceCount = maintenance.summary.recommendedCount
        value.hasProtectionScan = privacy.scanSnapshot != nil || privacy.resultPresentation != nil
        value.thirdPartyCloudFolderCount = cloud.providers.count
        value.iCloudAvailable = cloud.iCloudDriveAvailable
        value.iCloudLocalBytes = cloud.snapshot?.localBytes ?? 0
        value.hasCloudStatistics = cloud.snapshot != nil || !cloud.providerSnapshots.isEmpty
        return value
    }

    var recommendations: [MyActivityRecommendation] { MyActivityRecommendations.make(recommendationState, now: now()) }

    /// The same injected callback is used by health, previews, guides and
    /// the complete list. Production uses the existing module navigation.
    func open(_ destination: ReviewFilter) {
        showsAllRecommendations = false
        if let onNavigate { onNavigate(destination) }
        else { store.navigationState.select(destination) }
    }

    private var overviewCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: CareStudioMetrics.tileSpacing)],
                  spacing: CareStudioMetrics.tileSpacing) {
            CareStudioActivityHealthCard(health: health, mac: mac) { open(.healthHub) }
            CareStudioActivityTimeCard(savings: savings)
                .redacted(reason: summary == nil ? .placeholder : [])
        }
    }

    private var recommendationsSection: some View {
        let items = recommendations
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                CareStudioSectionTitle(title: MyActivityRecommendations.title(count: items.count))
                Spacer()
                CareStudioPillButton(title: L10n.text("查看全部", "View All"), compact: true) {
                    showsAllRecommendations = true
                }
                .disabled(items.isEmpty)
            }
#if DEBUG
            .layoutProbe("careStudio.activity.recommendations.header")
#endif
            if items.isEmpty {
                Text(L10n.text("现有结果中暂无推荐。", "No recommendations from the available results."))
                    .font(.system(size: 13)).foregroundStyle(CareStudioInk.secondary)
            }
            recommendationGrid(Array(items.filter { !$0.isGuide }.prefix(MyActivityRecommendations.previewCount)))
            recommendationGrid(items.filter(\.isGuide))
        }
    }

    private func recommendationGrid(_ items: [MyActivityRecommendation]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: CareStudioMetrics.tileSpacing)],
                  spacing: CareStudioMetrics.tileSpacing) {
            ForEach(items) { item in
                CareStudioActivityRecommendationCard(recommendation: item) { open(item.destination) }
            }
        }
    }

    private var subtitle: String {
        guard let since = summary?.since else {
            return isLoading || summary == nil
                ? L10n.text("正在读取记录…", "Reading records…")
                : L10n.text("这台 Mac 上还没有清理记录。", "No cleanups recorded on this Mac yet.")
        }
        let date = since.formatted(date: .long, time: .omitted)
        return L10n.text("自 \(date) 起，这台 Mac 上做过的清理和维护。", "Cleanups and maintenance on this Mac since \(date).")
    }

    private var cards: some View {
        let value = summary ?? MyActivitySummary()
        // CleanMyMac's My Activity is a grid of four cards, two by two.
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: CareStudioMetrics.tileSpacing),
                                   GridItem(.flexible(), spacing: CareStudioMetrics.tileSpacing)],
                         alignment: .leading, spacing: CareStudioMetrics.tileSpacing) {
            CareStudioStatCard(
                title: L10n.text("本机清理", "Local Storage Cleaned"),
                value: ByteFormat.storageString(value.movedBytes),
                caption: L10n.text("移到废纸篓等可恢复位置的大小；清倒废纸篓实际释放 \(ByteFormat.storageString(value.freedBytes))。",
                                   "Moved to the Trash or another recoverable place; emptying the Trash freed \(ByteFormat.storageString(value.freedBytes))."),
                systemImage: "internaldrive.fill", family: .cleanup, art: .tileCleaned,
                counted: summary != nil, countDelay: CareStudioMotion.tileDelay(0)
            ) {
                CareStudioSegmentBar(segments: [
                    .init(id: "systemJunk", title: L10n.text("系统垃圾", "System Junk"),
                          value: value.bytesByCategory[.systemJunk] ?? 0,
                          color: CareStudioPalette.color(CareStudioFamily.cleanup.palette.actionGlow)),
                    .init(id: "personalFiles", title: L10n.text("个人文件", "Personal Files"),
                          value: value.bytesByCategory[.personalFiles] ?? 0,
                          color: CareStudioPalette.color(CareStudioFamily.clutter.palette.actionGlow)),
                    .init(id: "applications", title: L10n.text("应用程序", "Applications"),
                          value: value.bytesByCategory[.applications] ?? 0,
                          color: CareStudioPalette.color(CareStudioFamily.applications.palette.actionGlow))
                ])
                .padding(.top, 4)
            }
            CareStudioStatCard(
                title: L10n.text("本月", "This Month"),
                value: ByteFormat.storageString(value.monthMovedBytes),
                caption: L10n.text("本月 \(ByteFormat.count(value.monthOperationCount)) 次操作移到废纸篓的大小。",
                                   "Moved to Trash by \(ByteFormat.count(value.monthOperationCount)) operations this month."),
                systemImage: "calendar", family: .smartCare, art: .tileMonth,
                counted: summary != nil, countDelay: CareStudioMotion.tileDelay(1))
            CareStudioStatCard(
                title: L10n.text("清理次数", "Operations"),
                value: ByteFormat.count(value.operationCount),
                caption: L10n.text("共 \(ByteFormat.count(value.movedItemCount)) 项移到废纸篓。", "\(ByteFormat.count(value.movedItemCount)) items moved to Trash in all."),
                systemImage: "checklist", family: .performance, art: .tileCount,
                counted: summary != nil, countDelay: CareStudioMotion.tileDelay(2))
            CareStudioStatCard(
                title: L10n.text("可以放回", "Restorable"),
                value: ByteFormat.count(value.recoverableCount),
                caption: L10n.text("这些项目还在废纸篓里，可以在“操作记录”里放回原处。",
                                   "These items are still in the Trash and can be put back from Operation History."),
                systemImage: "arrow.uturn.backward", family: .myActivity, art: .tileRestore,
                counted: summary != nil, countDelay: CareStudioMotion.tileDelay(3))
        }
        .redacted(reason: summary == nil ? .placeholder : [])
    }

    @ViewBuilder
    private var recentSection: some View {
        let recent = summary?.recent ?? []
        VStack(alignment: .leading, spacing: 10) {
            CareStudioSectionTitle(title: L10n.text("最近的操作", "Recent Activity"),
                                   detail: summary?.isTruncated == true
                                    ? L10n.text("统计只含最近 \(ByteFormat.count(MyActivitySummary.pageSize * MyActivitySummary.maximumPages)) 次", "Totals cover the latest \(ByteFormat.count(MyActivitySummary.pageSize * MyActivitySummary.maximumPages))")
                                    : nil)
            if recent.isEmpty {
                Text(summary == nil ? L10n.text("正在读取…", "Reading…")
                     : L10n.text("清理、卸载或移到废纸篓之后，会在这里出现。", "Cleanups, uninstalls and moves to Trash appear here."))
                    .font(.system(size: 13))
                    .foregroundStyle(CareStudioInk.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, report in
                        recentRow(report)
                        if index < recent.count - 1 {
                            Rectangle().fill(CareStudioInk.hairline).frame(height: 1).padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 4)
                .careStudioCard()
            }
        }
    }

    private func recentRow(_ report: CleanupReportIndex) -> some View {
        let category = MyActivitySummary.category(for: report.rulesVersion)
        let family: CareStudioFamily = switch category {
        case .systemJunk: .cleanup
        case .personalFiles: .clutter
        case .applications: .applications
        }
        let symbol = switch category {
        case .systemJunk: "trash"
        case .personalFiles: "doc.on.doc"
        case .applications: "app.badge.checkmark"
        }
        return HStack(spacing: 12) {
            CareStudioFamilyIcon(family: family, systemImage: symbol, side: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(OperationRecordPresentation.title(rulesVersion: report.rulesVersion, subject: report.subject,
                                                       itemCount: report.summary.requestedItemCount))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CareStudioInk.primary)
                    .lineLimit(1)
                Text(report.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(CareStudioInk.tertiary)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.storageString(report.summary.movedToRecoverableLocationBytes))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CareStudioInk.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        let journal = store.activityJournal
        let loaded = await Task.detached(priority: .utility) { MyActivitySummary.load(journal: journal) }.value
        summary = loaded
        isLoading = false
    }
}
