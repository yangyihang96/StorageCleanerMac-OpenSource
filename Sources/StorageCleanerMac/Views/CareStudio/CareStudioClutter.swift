import SwiftUI

/// D154 batch 2: CleanMyMac's My Clutter results — what the duplicates scan
/// found as tiles, each opening the review list; Similar Photos and Chat
/// Files (D162) beside them. Nothing here selects or removes a file: every
/// copy is chosen in the review list, at least one copy of each group stays,
/// and chat files are only listed (their page reads them when opened).
/// D221 补: Large & Old Files has its tile too, counting what the manager's
/// category lists; it only opens that category. D226: so does Downloads.
struct CareStudioClutterResults: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var chatFiles: ChatFilesStore
    @ObservedObject private var largeOld: LargeOldFilesStore
    @ObservedObject private var largeFiles: LargeFilesStore
    @ObservedObject private var downloads: DownloadsStore
    let confirmedGroups: Int
    let confirmedFiles: Int
    let logicalBytes: Int64
    let physicalBytes: Int64?
    let candidateGroups: Int
    var startOverEnabled = true
    let onReview: (DuplicateResultFilter) -> Void
    /// Item 12: Start Over in the title bar (was Scan Again on the page).
    let onStartOver: () -> Void

    init(store: ScanStore, confirmedGroups: Int, confirmedFiles: Int, logicalBytes: Int64, physicalBytes: Int64?,
         candidateGroups: Int, startOverEnabled: Bool = true,
         onReview: @escaping (DuplicateResultFilter) -> Void, onStartOver: @escaping () -> Void) {
        self.store = store
        let toolbox = ToolboxStores.of(store)
        _chatFiles = ObservedObject(wrappedValue: toolbox.chatFiles)
        _largeOld = ObservedObject(wrappedValue: toolbox.largeOldFiles)
        _largeFiles = ObservedObject(wrappedValue: toolbox.largeOldFiles.largeFiles)
        _downloads = ObservedObject(wrappedValue: toolbox.downloads)
        self.confirmedGroups = confirmedGroups
        self.confirmedFiles = confirmedFiles
        self.logicalBytes = logicalBytes
        self.physicalBytes = physicalBytes
        self.candidateGroups = candidateGroups
        self.startOverEnabled = startOverEnabled
        self.onReview = onReview
        self.onStartOver = onStartOver
    }

    var body: some View {
        CareStudioPageFrame(module: .clutter,
                            titleBar: .startOver(CareStudioStartOver(activity: store.heavyWorkActivityStore,
                                                                     isEnabled: startOverEnabled,
                                                                     action: onStartOver)),
                            footnote: L10n.text("每组至少留一份 · 移到废纸篓可以恢复", "At least one copy of each group stays · Trash can be restored")) {
            GeometryReader { proxy in
                let compact = proxy.size.height < 560
                VStack(spacing: 0) {
                    if confirmedGroups == 0 && candidateGroups == 0 {
                        CareStudioResultsStateMark(art: .stateEmpty, compact: compact)
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
                    CareStudioPillButton(title: L10n.text("查看所有文件", "Review All Files")) { review(.all) }
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
        // D226: the Downloads tile counts what the folder held when this
        // scan's results opened (read once per scan, names and sizes only).
        .task(id: store.duplicateFilesWorkspace.lastScanAt) {
            downloads.refresh(after: store.duplicateFilesWorkspace.lastScanAt)
        }
#if DEBUG
        .layoutProbe("careStudio.results.clutter")
#endif
    }

    private var headline: String {
        confirmedGroups > 0
            ? L10n.text("找到 \(ByteFormat.storageString(logicalBytes)) 的重复文件。",
                        "Found \(ByteFormat.storageString(logicalBytes)) of duplicates.")
            : L10n.text("没有找到内容完全相同的文件。", "No files with identical contents were found.")
    }

    var tiles: [CareStudioTileModel] {
        var tiles: [CareStudioTileModel] = []
        if confirmedGroups > 0 {
            tiles.append(CareStudioTileModel(
                id: "duplicates", module: .clutter,
                title: L10n.text("重复文件", "Duplicates"),
                value: ByteFormat.storageString(logicalBytes),
                valueCaption: L10n.text("\(ByteFormat.count(confirmedGroups)) 组、\(ByteFormat.count(confirmedFiles)) 个文件内容完全相同",
                                        "\(ByteFormat.count(confirmedGroups)) groups, \(ByteFormat.count(confirmedFiles)) files with identical contents"),
                detail: physicalBytes.map {
                    L10n.text("删掉多余的副本后实际能空出约 \(ByteFormat.storageString($0))。",
                              "Removing the extra copies frees about \(ByteFormat.storageString($0)).")
                } ?? L10n.text("副本可能共用存储，实际能空出多少在删除前会再核对。",
                               "Copies may share storage; the real savings are checked again before anything is removed."),
                systemImage: "doc.on.doc",
                reviewTitle: L10n.text("查看", "Review"), onReview: { review(.exact) }, art: .duplicates))
        }
        if candidateGroups > 0 {
            tiles.append(CareStudioTileModel(
                id: "candidates", module: .clutter,
                title: L10n.text("需要人工比较", "Needs Your Comparison"),
                value: ByteFormat.count(candidateGroups),
                valueCaption: L10n.text("组名称、大小或类型相同的文件", "groups with the same name, size or type"),
                detail: L10n.text("内容没有逐字节确认，默认一个都不选。", "Contents are not confirmed byte for byte; none is selected by default."),
                systemImage: "questionmark.square.dashed",
                reviewTitle: L10n.text("查看", "Review"), onReview: { review(.candidates) }, art: .tileCompare))
        }
        tiles.append(CareStudioTileModel(
            id: "similarPhotos", module: .clutter,
            title: L10n.text("相似照片", "Similar Photos"),
            valueCaption: L10n.text("连拍和相近的照片", "Bursts and look-alike photos"),
            detail: L10n.text("只读对照，逐张由你决定留哪张。", "Read-only comparison; you decide which to keep, one by one."),
            systemImage: "photo.on.rectangle",
            reviewTitle: L10n.text("查看", "Review"), onReview: { review(.similarImage) }, art: .similarPhotos))
        tiles.append(largeOldTile)
        tiles.append(downloadsTile)
        tiles.append(chatFilesTile)
        return tiles
    }

    /// The manager on one of the duplicates scan's result types.
    private func review(_ filter: DuplicateResultFilter) {
        largeOld.withdrawManagerRequest()
        downloads.withdrawManagerRequest()
        onReview(filter)
    }

    /// D221 补: the manager on Large & Old Files. `CareStudioClutterManager`
    /// takes the request when it appears and tells its page.
    private func reviewLargeOld() {
        downloads.withdrawManagerRequest()
        largeOld.requestManager()
        onReview(.all)
    }

    /// D226: the manager on Downloads, the same way.
    private func reviewDownloads() {
        largeOld.withdrawManagerRequest()
        downloads.requestManager()
        onReview(.all)
    }

    /// D221 补: the size and count the manager's category shows. Nothing is
    /// selected there by default, so the tile offers only Review.
    private var largeOldTile: CareStudioTileModel {
        let rows = largeOld.rows
        let caption: String
        var value: String?
        var detail: String?
        if !largeOld.hasList {
            caption = L10n.text("体积较大、很久没打开的文件", "Big files you have not opened in a while")
            detail = L10n.text("点“查看”后可以扫描大型文件，扫描只读取。", "Review offers a large-file scan, which only reads.")
        } else if rows.isEmpty {
            caption = L10n.text("大型文件清单里没有要整理的文件", "The large-file list has nothing to sort out")
        } else {
            value = ByteFormat.storageString(largeOld.totalBytes)
            caption = L10n.text("\(ByteFormat.count(rows.count)) 个大型文件，可按打开时间筛选",
                                "\(L10n.items(rows.count)) to narrow by when last opened")
            detail = L10n.text("默认一个都不选，移走前逐个审阅。", "None is selected by default; each is reviewed before it moves.")
        }
        return CareStudioTileModel(
            id: "largeOld", module: .clutter, title: IgnoreCategory.largeAndOld.title,
            value: value, valueCaption: caption, detail: detail,
            systemImage: "doc.badge.clock",
            reviewTitle: L10n.text("查看", "Review"), onReview: reviewLargeOld, art: .migration)
    }

    /// D226: the size and count the manager's Downloads category shows.
    /// Nothing is selected there by default, so the tile offers only Review.
    private var downloadsTile: CareStudioTileModel {
        let rows = downloads.rows
        let caption: String
        var value: String?
        var detail: String?
        if !downloads.hasRead {
            caption = downloads.isReading
                ? L10n.text("正在读取“下载”文件夹…", "Reading the Downloads folder…")
                : L10n.text("“下载”文件夹里安装包以外的项目", "What is in Downloads besides installers")
            detail = L10n.text("按下载来源分组；读取时不会打开文件。", "Grouped by where each came from; reading opens no file.")
        } else if rows.isEmpty {
            caption = L10n.text("“下载”里没有安装包以外的项目", "Downloads has nothing besides installers")
        } else {
            value = ByteFormat.storageString(downloads.totalBytes)
            caption = L10n.text("\(ByteFormat.count(rows.count)) 个项目，按下载来源分组",
                                "\(L10n.items(rows.count)), grouped by where they came from")
            detail = L10n.text("默认一个都不选，移走前逐个审阅。", "None is selected by default; each is reviewed before it moves.")
        }
        return CareStudioTileModel(
            id: "downloads", module: .clutter, title: IgnoreCategory.downloads.title,
            value: value, valueCaption: caption, detail: detail,
            systemImage: "arrow.down.circle",
            reviewTitle: L10n.text("查看", "Review"), onReview: reviewDownloads, art: .tileOtherSources)
    }

    /// Chat files are only listed here from their own page's last reading;
    /// the page reads them (with Full Disk Access) when it is opened.
    private var chatFilesTile: CareStudioTileModel {
        if let summary = chatFiles.summary, summary.fileCount > 0 {
            return CareStudioTileModel(
                id: "chatFiles", module: .clutter,
                title: ReviewFilter.chatFiles.title,
                value: ByteFormat.storageString(summary.totalBytes),
                valueCaption: L10n.text("\(ByteFormat.count(summary.fileCount)) 个文件，来自 \(ByteFormat.count(summary.appCount)) 个聊天软件",
                                        "\(ByteFormat.count(summary.fileCount)) files from \(ByteFormat.count(summary.appCount)) chat apps"),
                systemImage: "bubble.left.and.bubble.right",
                iconPaths: chatFiles.apps.compactMap(\.iconPath),
                reviewTitle: L10n.text("查看", "Review"), onReview: { store.showFilter(.chatFiles) }, art: .chatFiles)
        }
        return CareStudioTileModel(
            id: "chatFiles", module: .clutter,
            title: ReviewFilter.chatFiles.title,
            valueCaption: L10n.text("微信、QQ 等收到的图片、视频和文件", "Pictures, videos and files received in WeChat, QQ and others"),
            systemImage: "bubble.left.and.bubble.right",
            reviewTitle: L10n.text("查看", "Review"), onReview: { store.showFilter(.chatFiles) }, art: .chatFiles)
    }
}

/// D154 batch 3B: CleanMyMac's My Clutter manager — the duplicates review in
/// the light panel: result types on the left with their group counts, the
/// groups and copies on the right (the same rows, keep and select rules as
/// the D67 list), and the footer that counts the selection beside “Move to
/// Trash”. Quarantine, Merge into Clones and the scan details are in More.
/// D221: Large & Old Files follows the result types; picking it shows
/// `CareStudioLargeOldManager` with the same category column. D226:
/// Downloads is the last category and shows `CareStudioDownloadsManager`.
struct CareStudioClutterManager: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var workspace: DuplicateFilesStore
    let allItems: [StorageItem]
    let groups: [DuplicateDisplayGroup]
    let filter: DuplicateResultFilter
    let details: AnyView
    var onUseSystemPhotoLibrary: (() -> Void)? = nil
    let onFilter: (DuplicateResultFilter) -> Void
    let onBack: () -> Void
    /// D221: Large & Old Files is shown; without `onLargeOld` (the classic
    /// review and its tests) the category is not offered.
    var showsLargeOld = false
    var onLargeOld: (() -> Void)? = nil
    /// D226: Downloads is shown; without `onDownloads` it is not offered.
    var showsDownloads = false
    var onDownloads: (() -> Void)? = nil
    @State private var showingDetails = false

    private var selected: [StorageItem] { workspace.selectedItems(from: allItems) }
    private var selectedBytes: Int64 { FileLightfieldPresentation.sum(selected.map(\.sizeBytes)) }
    private var isSimilar: Bool { filter == .similarImage }
    private var isBusy: Bool {
        store.duplicateCleanupProgress != nil || store.isDuplicateCleanupConfirmationPresented
            || store.isDuplicateRestoreConfirmationPresented || store.isRestoringRecordedOperation
    }

    var body: some View {
        if showsDownloadsCategory {
            CareStudioDownloadsManager(store: store, categories: AnyView(categoryColumn), onBack: onBack)
                .onAppear {
                    // D226: opened from the results page's tile.
                    if ToolboxStores.of(store).downloads.takeManagerRequest() { onDownloads?() }
                }
        } else if showsLargeOldCategory {
            CareStudioLargeOldManager(store: store, categories: AnyView(categoryColumn), onBack: onBack)
                .onAppear {
                    // D221 补: opened from the results page's tile.
                    if ToolboxStores.of(store).largeOldFiles.takeManagerRequest() { onLargeOld?() }
                }
        } else {
            duplicatesManager
        }
    }

    /// D221: Large & Old Files shows when the page says so, or when the
    /// results page's tile asked for it and the manager has not taken the
    /// request yet.
    var showsLargeOldCategory: Bool {
        guard onLargeOld != nil, !showsDownloadsCategory else { return false }
        return showsLargeOld || ToolboxStores.of(store).largeOldFiles.isManagerRequested
    }

    /// D226: Downloads, the same way.
    var showsDownloadsCategory: Bool {
        guard onDownloads != nil else { return false }
        return showsDownloads || ToolboxStores.of(store).downloads.isManagerRequested
    }

    private var duplicatesManager: some View {
        CareStudioManagerChrome(
            module: .clutter,
            title: L10n.text("杂乱文件管理器", "My Clutter Manager"),
            query: $workspace.searchText,
            searchPrompt: L10n.text("搜索名称或路径", "Search Name or Path"),
            sortTitle: workspace.resultSort.title,
            sortOptions: DuplicateResultSort.allCases.map { (id: $0.id, title: $0.title) },
            onSort: { id in workspace.resultSort = DuplicateResultSort(rawValue: id) ?? workspace.resultSort },
            categoryWidth: 220,
            selectionSummary: status,
            primaryTitle: L10n.text("移到废纸篓", "Move to Trash"),
            primaryEnabled: !isSimilar && !selected.isEmpty && !isBusy,
            onPrimary: { store.requestVerifiedDuplicateCleanup(disposition: .trash, workspace: workspace) },
            onBack: onBack,
            categories: { categoryColumn },
            content: { list },
            footerDetail: { footerDetail })
        .sheet(isPresented: $showingDetails) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("扫描与操作详情", "Scan and Operation Details")).font(.system(size: 24, weight: .semibold))
                    details
                    if let error = workspace.errorMessage { Text(error).font(.system(size: 15)) }
                    Button(L10n.text("返回", "Back")) { showingDetails = false }
                }.padding(24)
            }.frame(width: 680, height: 440)
        }
    }

    private var status: String {
        if let progress = store.duplicateCleanupProgress {
            return L10n.text("已处理 \(ByteFormat.count(progress.processedItemCount))/\(ByteFormat.count(progress.totalItemCount))",
                             "Processed \(ByteFormat.count(progress.processedItemCount))/\(ByteFormat.count(progress.totalItemCount))")
        }
        if isSimilar { return L10n.text("相似照片需逐张确认", "Similar photos are confirmed one by one") }
        return FileAnalysisTrashPresentation.selectionSummary(count: selected.count, bytes: selectedBytes)
    }

    /// The result types, CleanMyMac's category column, each with its groups.
    private var categoryColumn: some View {
        let counts = Dictionary(uniqueKeysWithValues: DuplicateResultFilter.allCases.map { kind in
            (kind, DuplicateFilesPresenter.groups(from: allItems, filter: kind, sort: .reclaimable).count)
        })
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(DuplicateResultFilter.allCases) { kind in
                    if kind == .all || kind == .similarImage || (counts[kind] ?? 0) > 0 || kind == filter {
                        CareStudioManagerCategoryRow(module: .clutter, title: kind.title, systemImage: Self.symbol(kind),
                                                     detail: "\(counts[kind] ?? 0)",
                                                     isSelected: !showsLargeOldCategory && !showsDownloadsCategory && filter == kind,
                                                     art: Self.art(kind)) {
                            onFilter(kind)
                        }
                    }
                }
                if let onLargeOld {
                    CareStudioLargeOldCategoryRow(largeOld: ToolboxStores.of(store).largeOldFiles,
                                                  isSelected: showsLargeOldCategory, action: onLargeOld)
                }
                if let onDownloads {
                    CareStudioDownloadsCategoryRow(downloads: ToolboxStores.of(store).downloads,
                                                   isSelected: showsDownloadsCategory, action: onDownloads)
                }
            }
            .padding(10)
        }
#if DEBUG
        .layoutProbe("careStudio.manager.clutter.categories")
#endif
    }

    /// D166: the category objects of the clutter manager.
    static func art(_ kind: DuplicateResultFilter) -> GeneratedArt {
        switch kind {
        case .all: .clutter
        case .exact: .duplicates
        case .similarImage: .similarPhotos
        case .sameName, .sameSize, .sameType, .candidates: .tileCompare
        }
    }

    static func symbol(_ kind: DuplicateResultFilter) -> String {
        switch kind {
        case .all: "square.stack.3d.up"
        case .exact: "doc.on.doc"
        case .sameName: "textformat"
        case .sameSize: "ruler"
        case .sameType: "doc.richtext"
        case .similarImage: "photo.on.rectangle"
        case .candidates: "questionmark.square.dashed"
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(filter.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(isSimilar
                     ? L10n.text("视觉相近的照片，默认一张都不选；逐张决定留哪张。", "Look-alike photos, none selected by default; decide one by one.")
                     : L10n.text("每组至少留一份；只有完整 SHA-256 确认相同的副本才能清理。",
                                 "At least one copy of each group stays; only copies confirmed by a full SHA-256 can be cleaned."))
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if let refusal = store.duplicateCleanupReport?.startRefusal {
                refusalNote(refusal)
            }
            if groups.isEmpty {
                CareStudioManagerEmptyState(
                    title: workspace.searchText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? L10n.text("这一类没有找到文件", "Nothing Was Found Here")
                        : L10n.text("没有匹配的结果", "No Matching Results"))
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(.vertical) {
                    DuplicateLightfieldBody(groups: groups, isSimilarPhotos: isSimilar,
                        selectedIDs: workspace.selectedItemIDs, isBusy: isBusy,
                        onSelected: { selected, item in workspace.setSelected(selected, item: item, allItems: allItems) },
                        onReveal: { store.reveal($0.path) }, onCopyPath: { store.copyPath($0.path) },
                        onIgnore: workspace.canIgnore && !isBusy ? { workspace.ignore([$0], feedback: store.ignoreFeedback) } : nil)
#if DEBUG
                        .layoutProbe("careStudio.manager.document")
#endif
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                // The D67 rows draw their own light-field lines on the light panel.
                .environment(\.careStudioSurface, false)
#if DEBUG
                .layoutProbe("lightfield.results.scrollViewport")
#endif
            }
        }
    }

    /// D214: the last Move to Trash never started — why, that nothing moved
    /// and the selection is kept — until it is closed or another run reports.
    private func refusalNote(_ refusal: CleanFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(CleanStartRefusalPresentation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.primary)
                Text(CleanStartRefusalPresentation.message(refusal))
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: store.dismissVerifiedDuplicateCleanupReport) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .foregroundStyle(CareStudioManagerInk.secondary)
            .accessibilityLabel(L10n.text("关闭", "Close"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
#if DEBUG
        .layoutProbe("careStudio.manager.clutter.refusal")
#endif
    }

    private var footerDetail: some View {
        HStack(spacing: 10) {
            Menu(L10n.text("更多", "More")) {
                Button(L10n.text("移到隔离区（推荐）", "Move to Quarantine (Recommended)")) {
                    store.requestVerifiedDuplicateCleanup(disposition: .quarantine, workspace: workspace)
                }
                .disabled(isSimilar || selected.isEmpty || isBusy)
                Button(L10n.text("取消选择", "Clear Selection"), action: workspace.clearSelection)
                Button(L10n.text("扫描与操作详情", "Scan and Operation Details")) { showingDetails = true }
                if isSimilar, let onUseSystemPhotoLibrary {
                    Button(L10n.text("改用系统照片图库", "Use the System Photo Library"), action: onUseSystemPhotoLibrary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(CareStudioManagerInk.accent)
            if !isSimilar {
                DuplicateCloneMergeOffer(action: ToolboxStores.of(store).cloneMerge, groups: workspace.exactGroups)
            }
            if store.duplicateCleanupProgress != nil {
                Button(L10n.text("取消剩余项目", "Cancel Remaining"), action: store.cancelVerifiedDuplicateCleanupExecution)
                    .buttonStyle(CareStudioRowButtonStyle())
            }
        }
        .font(.system(size: 12, weight: .semibold))
    }
}
