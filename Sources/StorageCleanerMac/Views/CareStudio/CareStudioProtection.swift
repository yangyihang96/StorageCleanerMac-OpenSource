import SwiftUI

/// D154 batch 2: CleanMyMac's Protection results — what the browser privacy
/// scan read, as tiles, each opening the review list (or the cookies page).
/// The list keeps every safety step: nothing is selected here, records are
/// backed up before deletion and running browsers must quit first.
struct CareStudioProtectionResults: View {
    @ObservedObject var privacy: BrowserPrivacyStore
    @ObservedObject var malware: MalwareScanStore
    @State private var showsMalware = false
    @Environment(\.ignoreListFeedback) private var ignoreListFeedback
    let onReview: () -> Void
    let onShowDataTypes: () -> Void
    @ObservedObject var recentItems: RecentItemsStore
    let recentItemsCoordinator: HeavyWorkCoordinator?
    let onRecentOperationComplete: () -> Void
    @State private var showsRecentItems = false

    // Integration: D186's initializer also takes D188's recent-item inputs.
    init(privacy: BrowserPrivacyStore, malware: MalwareScanStore? = nil,
         onReview: @escaping () -> Void, onShowDataTypes: @escaping () -> Void,
         recentItems: RecentItemsStore? = nil, recentItemsCoordinator: HeavyWorkCoordinator? = nil,
         onRecentOperationComplete: @escaping () -> Void = {}) {
        self.privacy = privacy; self.malware = malware ?? MalwareScanStore()
        self.onReview = onReview; self.onShowDataTypes = onShowDataTypes
        self.recentItems = recentItems ?? RecentItemsStore()
        self.recentItemsCoordinator = recentItemsCoordinator
        self.onRecentOperationComplete = onRecentOperationComplete
    }

    var body: some View {
        // Item 12: Start Over in the title bar goes back to the landing page,
        // forgetting all three results (privacy `clearSession`, malware and
        // recent items `startOver`); Scan Again is gone. The landing page's
        // scan reads records and malware, and this page reads the recent
        // items when it appears, so starting over refreshes all three, as
        // CleanMyMac's does. Their own scanning, review, moving and cleaning
        // are the exclusive work it waits for.
        CareStudioPageFrame(module: .protection,
                            titleBar: .startOver(CareStudioStartOver(
                                isEnabled: !privacy.isProcessing && privacy.state != .scanning
                                    && !malware.isScanning && !malware.isMoving && !malware.isPreparingReview
                                    && !recentItems.isScanning && !recentItems.isCleaning,
                                action: {
                                    malware.startOver()
                                    recentItems.startOver()
                                    privacy.clearSession()
                                })),
                            footnote: L10n.text("浏览记录备份保留 7 天 · 最近使用列表可从废纸篓放回", "History backups kept for 7 days · Recent-item lists can be put back from Trash")) {
            GeometryReader { proxy in
                let compact = proxy.size.height < 560
                VStack(spacing: 0) {
                    if privacy.records.isEmpty {
                        CareStudioResultsStateMark(art: emptyArt, compact: compact)
                    }
                    Text(headline)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(CareStudioInk.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, compact ? 4 : 18)
                        .accessibilityAddTraits(.isHeader)
#if DEBUG
                        .layoutProbe("careStudio.results.headline")
#endif
                    CareStudioPillButton(title: L10n.text("查看所有记录", "Review All Records"), action: onReview)
                        .padding(.top, compact ? 8 : 12)
                    CareStudioTileGrid(tiles: tiles)
                        .padding(.horizontal, CareStudioMetrics.pageInset)
                        .padding(.top, compact ? 10 : 18)
                        .padding(.bottom, compact ? 6 : 12)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                // The row that went to the title bar was 26 pt plus 8 or 12
                // above it; the page below keeps its place.
                .padding(.top, compact ? 34 : 38)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        } action: {
            EmptyView()
        }
        .sheet(isPresented: $showsMalware) {
            MalwareThreatList(store: malware).environment(\.ignoreListFeedback, ignoreListFeedback)
        }
        .sheet(isPresented: $showsRecentItems) {
            CareStudioRecentItemsSheet(store: recentItems, coordinator: recentItemsCoordinator,
                                       onClose: { showsRecentItems = false })
                .environment(\.locale, L10n.locale)
        }
        .onChange(of: recentItems.result?.report.id) { _, id in
            if id != nil { onRecentOperationComplete() }
        }
#if DEBUG
        .layoutProbe("careStudio.results.protection")
#endif
    }

    private var browserCount: Int { Set(privacy.records.map(\.browser.id)).count }

    /// D166: why nothing was read — no access, a partial read, or nothing
    /// there (the review list says the same in words).
    private var emptyArt: GeneratedArt {
        if privacy.state == .permissionDenied || privacy.coverage.contains(where: \.requiresFullDiskAccess) {
            return .statePermission
        }
        return privacy.state == .partial ? .stateError : .stateAllClear
    }

    private var headline: String {
        privacy.records.isEmpty
            ? L10n.text("没有读到浏览记录。", "No browsing history was read.")
            : L10n.text("在 \(ByteFormat.count(browserCount)) 个浏览器里读到 \(ByteFormat.count(privacy.records.count)) 条浏览记录。",
                        "Read \(ByteFormat.count(privacy.records.count)) history records in \(ByteFormat.count(browserCount)) browsers.")
    }

    var tiles: [CareStudioTileModel] {
        var tiles: [CareStudioTileModel] = []
        if !privacy.records.isEmpty {
            tiles.append(CareStudioTileModel(
                id: "history", module: .protection,
                title: L10n.text("浏览记录", "Browsing History"),
                value: ByteFormat.count(privacy.records.count),
                valueCaption: L10n.text("条记录，来自 \(ByteFormat.count(browserCount)) 个浏览器", "records from \(ByteFormat.count(browserCount)) browsers"),
                detail: L10n.text("按浏览器和网站整理；删掉的记录先备份，7 天内可以恢复。",
                                  "Organized by browser and site; deleted records are backed up and restorable for 7 days."),
                systemImage: "clock.arrow.circlepath",
                reviewTitle: L10n.text("查看", "Review"), onReview: onReview, art: .tileHistory))
        }
        // Every record the list folds and masks by default (adult and finance).
        let sensitive = privacy.records.filter { BrowserPrivacyLightfieldPresentation.isSensitive($0.category) }.count
        if sensitive > 0 {
            tiles.append(CareStudioTileModel(
                id: "sensitive", module: .protection,
                title: L10n.text("敏感网站", "Sensitive Sites"),
                value: ByteFormat.count(sensitive),
                valueCaption: L10n.text("条记录默认折叠", "records folded by default"),
                detail: L10n.text("网址和标题在你展开前不会显示。", "Addresses and titles stay hidden until you open them."),
                systemImage: "eye.slash",
                reviewTitle: L10n.text("查看", "Review"), onReview: onReview, art: .tileSensitive))
        }
        tiles.append(CareStudioTileModel(
            id: "dataTypes", module: .protection,
            title: BrowserPrivacyWorkspaceView.dataTypesTitle,
            valueCaption: L10n.text("Cookie、站点数据、缓存和下载记录", "Cookies, site data, caches and download history"),
            systemImage: "tray.full",
            reviewTitle: L10n.text("查看", "Review"), onReview: onShowDataTypes, art: .tileCookies))
        if let snapshot = recentItems.snapshot {
            tiles.append(CareStudioTileModel(
                id: "recentItems", module: .protection, title: RecentItemsPresentation.title,
                valueCaption: RecentItemsPresentation.summary(snapshot), detail: RecentItemsPresentation.detail,
                note: snapshot.unreadableLocations > 0
                    ? L10n.text("部分位置无法读取，结果不完整。", "Some locations could not be read; results are incomplete.") : nil,
                systemImage: "clock", reviewTitle: L10n.text("查看", "Review"),
                onReview: { recentItems.beginReview(confirm: false); showsRecentItems = true },
                cleanTitle: L10n.text("移除", "Remove"), cleanEnabled: !recentItems.isScanning && !recentItems.isCleaning,
                onClean: { recentItems.beginReview(confirm: true); showsRecentItems = true }))
        }
        if !privacy.runningBrowserIDs.isEmpty {
            tiles.append(CareStudioTileModel(
                id: "running", module: .protection,
                title: L10n.text("\(ByteFormat.count(privacy.runningBrowserIDs.count)) 个浏览器正在运行", "\(ByteFormat.count(privacy.runningBrowserIDs.count)) Browsers Running"),
                note: L10n.text("删除它们的记录前要先退出，否则浏览器会把记录写回。",
                                "Quit them before deleting their records, or they write the records back."),
                systemImage: "exclamationmark.triangle",
                iconPaths: (privacy.resultPresentation?.browsers ?? [])
                    .filter { privacy.runningBrowserIDs.contains($0.id) }.compactMap(\.iconPath),
                reviewTitle: L10n.text("查看", "Review"), onReview: onReview, art: .tileBrowsers))
        }
        tiles.append(CareStudioTileModel(
            id: "malware", module: .protection, title: MalwareScanPresentation.title,
            valueCaption: MalwareScanPresentation.summary(isScanning: malware.isScanning, progress: malware.progress, outcome: malware.outcome),
            detail: malware.isScanning ? malware.progress.currentPath : malware.outcome.map { MalwareScanPresentation.coverage($0.counts) },
            systemImage: "shield.lefthalf.filled",
            reviewTitle: L10n.text("查看", "Review"), onReview: { showsMalware = true }))
        return tiles
    }
}
