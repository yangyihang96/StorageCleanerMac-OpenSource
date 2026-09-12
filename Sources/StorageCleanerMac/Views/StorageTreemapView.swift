import AppKit
import QuickLook
import SwiftUI

struct LargeFileStorageMap: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var workspace: LargeFilesStore
    let displayMode: StorageAnalysisDisplayMode

    @State private var selectedEntryID: String?
    @State private var selectedMapEntry: StorageTreemapEntry?
    @State private var quickLookURL: URL?
    @State private var hoveredSegmentID: String?
    @State private var hoveredMapEntry: StorageTreemapEntry?
    @State private var searchQuery = ""
    @State private var entryFilter = StorageMapEntryFilter.all
    @State private var entrySort = StorageMapEntrySort.sizeDescending
    @State private var compactShowsMap = false
    @State private var sunburstSegments: [StorageSunburstLayout.Segment] = []
    @FocusState private var isMapFocused: Bool

    private var currentSnapshot: StorageMapDirectorySnapshot? {
        workspace.currentStorageMapSnapshot
    }

    private var entries: [StorageTreemapEntry] {
        currentSnapshot.map {
            StorageTreemapPresentation.visibleEntries(from: $0)
        } ?? []
    }

    private var mapEntries: [StorageTreemapEntry] {
        guard let currentSnapshot else { return [] }
        return StorageTreemapPresentation.mapLayoutEntries(
            from: entries,
            measuredBytes: currentSnapshot.measuredBytes,
            referenceBytes: currentSnapshot.referenceBytes,
            limit: 30
        )
    }

    private var filteredEntries: [StorageTreemapEntry] {
        StorageTreemapPresentation.filteredEntries(
            from: entries, query: searchQuery, filter: entryFilter, sort: entrySort
        )
    }

    private var hasListFilter: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entryFilter != .all
    }

    private var selectedEntry: StorageTreemapEntry? {
        entries.first { $0.id == selectedEntryID } ?? selectedMapEntry
    }

    private var visibleCategories: [StorageMapContentCategory] {
        let present = Set(
            entries
                .filter { $0.sizeBytes > 0 }
                .map(\.contentCategory)
        )
        return StorageMapContentCategory.allCases.filter(present.contains)
    }

    private var currentLevelIndex: Int {
        max(0, workspace.storageMapNavigation.count - 1)
    }

    private var revealPath: String? {
        selectedEntry?.path ?? currentSnapshot?.path
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            listControls
            Divider()

            Group {
                switch displayMode {
                case .visualMap, .sunburstMap:
                    visualBrowser
                case .columnBrowser:
                    columnBrowser
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)

            Divider()
            statusBar
                .padding(.horizontal, AppDesignTokens.Spacing.medium)
                .padding(.vertical, AppDesignTokens.Spacing.small)
                .background(Color.primary.opacity(0.025))

            if case let .failed(_, _, _, _, message) = workspace.storageMapBrowsePhase {
                browseFailure(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: workspace.storageMapNavigation.map(\.path)) { _, _ in
            selectedEntryID = nil
            selectedMapEntry = nil
            hoveredSegmentID = nil
            hoveredMapEntry = nil
            searchQuery = ""
            entryFilter = .all
        }
        .onChange(of: currentSnapshot, initial: true) { _, _ in
            sunburstSegments = workspace.storageMapSunburstSegments
        }
        .animation(
            AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
            value: workspace.storageMapNavigation.map(\.path)
        )
        .quickLookPreview($quickLookURL)
    }

    private var navigationBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                navigationButtons
                breadcrumbBar
                selectedItemActions
            }
            currentLocationIdentity
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, AppDesignTokens.Spacing.small)
        .background(Color.primary.opacity(0.025))
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            AppIconButton(
                title: L10n.text("返回上一级", "Back"),
                systemImage: "chevron.left",
                kind: .toolbar
            ) {
                workspace.showPreviousStorageMapLevel()
            }
            .disabled(
                workspace.storageMapNavigation.count <= 1
                    || workspace.storageMapBrowsePhase.isLoading
            )

            AppIconButton(
                title: L10n.text("前进", "Forward"),
                systemImage: "chevron.right",
                kind: .toolbar
            ) {
                workspace.showNextStorageMapLevel()
            }
            .disabled(
                workspace.storageMapForwardNavigation.isEmpty
                    || workspace.storageMapBrowsePhase.isLoading
            )
        }
    }

    private var selectedItemActions: some View {
        HStack(spacing: 2) {
            if let selectedEntry, selectedEntry.canDescend {
                AppIconButton(
                    title: L10n.text("打开文件夹", "Open Folder"),
                    systemImage: "folder.badge.plus",
                    kind: .toolbar
                ) {
                    activate(selectedEntry, fromLevel: currentLevelIndex)
                }
                .disabled(workspace.storageMapBrowsePhase.isLoading)
            }
            if let selectedEntry, !selectedEntry.isDirectory, !selectedEntry.path.isEmpty {
                AppIconButton(
                    title: L10n.text("快速预览", "Quick Look"),
                    systemImage: "eye",
                    kind: .toolbar
                ) {
                    quickLookURL = URL(fileURLWithPath: selectedEntry.path)
                }
            }

            if let revealPath {
                AppIconButton(
                    title: L10n.text("在访达中显示", "Show in Finder"),
                    systemImage: "folder",
                    kind: .toolbar
                ) {
                    revealInFinder(path: revealPath)
                }
                AppIconButton(
                    title: L10n.text("复制路径", "Copy Path"),
                    systemImage: "doc.on.doc",
                    kind: .toolbar
                ) {
                    copyPath(revealPath)
                }
            }
        }
    }

    private var currentLocationIdentity: some View {
        HStack(spacing: 7) {
            Image(systemName: selectedEntry == nil ? "folder" : "checkmark.circle")
                .foregroundStyle(AppDesignTokens.Palette.storage)
                .accessibilityHidden(true)
            selectedPathView(selectedEntry?.path ?? currentSnapshot?.path ?? "")
            if let selectedEntry {
                Text(StorageTreemapPresentation.displaySize(for: selectedEntry))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                if hasListFilter, !filteredEntries.contains(where: { $0.id == selectedEntry.id }) {
                    Text(L10n.text("筛选外的选择", "Selection outside filter"))
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .help(L10n.text("选择已保留；清除筛选可在列表中显示", "Selection is kept; clear filters to show it in the list"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private func selectedPathView(_ path: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(path)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityLabel(selectedEntry == nil
            ? L10n.text("当前路径", "Current Path")
            : L10n.text("所选路径", "Selected Path"))
        .accessibilityValue(path)
    }

    private var listControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                listSearchField
                    .frame(minWidth: 150, maxWidth: 360)
                listFilterMenu
                listSortMenu
                listMatchCount
                Spacer(minLength: 0)
                if hasListFilter { clearListFilterButton }
            }
            VStack(alignment: .leading, spacing: 6) {
                listSearchField
                HStack(spacing: 9) {
                    listFilterMenu
                    listSortMenu
                    Spacer(minLength: 0)
                    listMatchCount
                    if hasListFilter { clearListFilterButton }
                }
            }
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, 7)
    }

    private var listSearchField: some View {
        TaskSearchField(
            placeholder: L10n.text("搜索当前层名称或路径", "Search this folder by name or path"),
            text: $searchQuery,
            tint: AppDesignTokens.Palette.storage
        )
        .accessibilityLabel(L10n.text("搜索当前层", "Search Current Folder"))
    }

    private var listFilterMenu: some View {
        Menu {
            Picker(L10n.text("类型", "Type"), selection: $entryFilter) {
                ForEach(StorageMapEntryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
        } label: {
            Label(entryFilter.title, systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.text("当前层类型筛选", "Current Folder Type Filter"))
    }

    private var listSortMenu: some View {
        Menu {
            Picker(L10n.text("排序", "Sort"), selection: $entrySort) {
                ForEach(StorageMapEntrySort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
        } label: {
            Label(entrySort.title, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.text("当前层排序", "Current Folder Sort"))
    }

    private var listMatchCount: some View {
        Text(L10n.text("\(filteredEntries.count) / \(entries.count) 项", "\(filteredEntries.count) / \(entries.count) items"))
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
            .accessibilityLabel(L10n.text("匹配 \(filteredEntries.count) 项，共 \(entries.count) 项", "\(filteredEntries.count) matches out of \(entries.count) items"))
    }

    private var clearListFilterButton: some View {
        Button(L10n.text("清除", "Clear")) {
            searchQuery = ""
            entryFilter = .all
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .accessibilityLabel(L10n.text("清除当前层筛选", "Clear Current Folder Filters"))
    }

    private var currentLocationMetrics: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            if workspace.storageMapBrowsePhase.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("正在打开下一层", "Opening Next Level"))
            }

            if let selectedEntry {
                Label(
                    StorageTreemapPresentation.displaySize(for: selectedEntry),
                    systemImage: selectedEntry.isDirectory ? "folder" : selectedEntry.contentCategory.systemImage
                )
                .monospacedDigit()

                if let childCount = selectedEntry.childCount {
                    Label(L10n.items(childCount), systemImage: "doc.on.doc")
                } else {
                    Label(
                        selectedEntry.contentCategory.title,
                        systemImage: selectedEntry.contentCategory.systemImage
                    )
                }
            } else if let snapshot = currentSnapshot {
                Label(StorageTreemapPresentation.displaySize(for: summaryEntry(snapshot)), systemImage: "internaldrive")
                    .monospacedDigit()
                Label(L10n.items(snapshot.entries.count), systemImage: "doc.on.doc")
            }
        }
        .font(AppDesignTokens.Typography.compactLabel)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var breadcrumbBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(
                        Array(workspace.storageMapNavigation.enumerated()),
                        id: \.element.path
                    ) { index, snapshot in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        Button {
                            workspace.showStorageMapSnapshot(at: index)
                        } label: {
                            Label(
                                snapshot.title,
                                systemImage: index == 0 ? "internaldrive.fill" : "folder.fill"
                            )
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(
                                index == workspace.storageMapNavigation.count - 1
                                    ? AppDesignTokens.Palette.storage.opacity(0.12)
                                    : Color.clear,
                                in: Capsule()
                            )
                        }
                        .buttonStyle(ResponsivePlainButtonStyle())
                        .disabled(workspace.storageMapBrowsePhase.isLoading)
                        .id(snapshot.path)
                    }
                }
                .font(AppDesignTokens.Typography.compactLabel)
            }
            .onAppear {
                scrollBreadcrumbToCurrent(using: proxy)
            }
            .onChange(of: workspace.storageMapNavigation.last?.path) { _, _ in
                scrollBreadcrumbToCurrent(using: proxy)
            }
            .accessibilityLabel(L10n.text("当前位置", "Current Location"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollBreadcrumbToCurrent(using proxy: ScrollViewProxy) {
        guard let path = workspace.storageMapNavigation.last?.path else { return }
        if reduceMotion {
            proxy.scrollTo(path, anchor: .trailing)
        } else {
            withAnimation(AppMotionTokens.stateChange) {
                proxy.scrollTo(path, anchor: .trailing)
            }
        }
    }

    private var visualBrowser: some View {
        GeometryReader { proxy in
            if StorageMapWorkspaceLayout.showsEntryList(availableWidth: proxy.size.width) {
                HStack(alignment: .top, spacing: 0) {
                    currentEntryList
                        .frame(width: StorageMapWorkspaceLayout.entryListWidth(
                            availableWidth: proxy.size.width
                        ))
                    Divider()
                    mapPane
                }
            } else {
                // The adjacent Columns mode remains available; compact maps
                // also retain the complete list without stacking clipped panes.
                VStack(spacing: 0) {
                    Picker(L10n.text("浏览区域", "Browser Pane"), selection: $compactShowsMap) {
                        Text(L10n.text("列表", "List")).tag(false)
                        Text(L10n.text("容量图", "Usage Map")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    if compactShowsMap {
                        mapPane
                    } else {
                        currentEntryList
                    }
                }
            }
        }
    }

    private var currentEntryList: some View {
        Group {
            if filteredEntries.isEmpty, !workspace.storageMapBrowsePhase.isLoading {
                VStack(spacing: 10) {
                    storageMapEmptyState(
                        title: entries.isEmpty
                            ? L10n.text("这一层没有项目", "This Folder Is Empty")
                            : L10n.text("没有匹配的项目", "No Matching Items"),
                        systemImage: entries.isEmpty ? "folder" : "magnifyingglass"
                    )
                    if hasListFilter {
                        clearListFilterButton
                            .padding(.bottom, 16)
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredEntries) { entry in
                                StorageMapEntryRow(
                                    entry: entry,
                                    referenceBytes: currentSnapshot?.referenceBytes ?? 0,
                                    isSelected: selectedEntryID == entry.id,
                                    onSelect: { select(entry) },
                                    onActivate: {
                                        activate(entry, fromLevel: currentLevelIndex)
                                    },
                                    onReveal: { revealInFinder(path: entry.path) },
                                    onPreview: { quickLookURL = URL(fileURLWithPath: entry.path) },
                                    onCopyPath: { copyPath(entry.path) }
                                )
                                .id(entry.id)
                            }
                        }
                            .padding(4)
                    }
                    .onChange(of: selectedEntryID) { _, id in
                        if let id, filteredEntries.contains(where: { $0.id == id }) {
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .background(Color.primary.opacity(0.016))
    }

    private var mapPane: some View {
        VStack(spacing: 0) {
            mapHeader
            Divider()
            if displayMode == .sunburstMap {
                mapCanvas
            } else {
                rectangularMapCanvas
            }
            if !visibleCategories.isEmpty {
                Divider()
                categoryLegend
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mapHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppDesignTokens.Spacing.medium) {
                mapHeaderIdentity
                    .layoutPriority(1)
                Spacer(minLength: AppDesignTokens.Spacing.medium)
                mapHeaderSize
            }

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                mapHeaderIdentity
                mapHeaderSize
            }
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, AppDesignTokens.Spacing.small)
    }

    private var mapHeaderIdentity: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: mapHeaderIcon)
                .foregroundStyle(mapHeaderTint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(currentSnapshot?.title
                    ?? L10n.text("磁盘空间", "Disk Space"))
                    .font(AppDesignTokens.Typography.inlineTitle)
                    .lineLimit(1)
                    .help(currentSnapshot?.path ?? "")
                Text(hasListFilter
                    ? L10n.text("图中仍显示完整目录", "Map shows the entire folder")
                    : mapHeaderDetail)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var mapHeaderSize: some View {
        if let snapshot = currentSnapshot {
            Label(
                StorageTreemapPresentation.displaySize(for: summaryEntry(snapshot)),
                systemImage: "internaldrive"
            )
            .font(AppDesignTokens.Typography.compactLabel)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var mapHeaderIcon: String {
        "folder.fill"
    }

    private var mapHeaderTint: Color {
        AppDesignTokens.Palette.storage
    }

    private var mapHeaderDetail: String {
        return L10n.text(
            "文件夹 \(directoryCount) · 文件 \(fileCount)",
            "\(directoryCount) folders · \(fileCount) files"
        )
    }

    private var categoryLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppDesignTokens.Spacing.medium) {
                ForEach(visibleCategories, id: \.self) { category in
                    StorageMapCategoryLegendItem(category: category)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.vertical, AppDesignTokens.Spacing.tight)
        .background(Color.primary.opacity(0.018))
        .accessibilityLabel(L10n.text("文件类型颜色图例", "File Type Color Legend"))
    }

    private var rectangularMapCanvas: some View {
        GeometryReader { proxy in
            let plottedEntries = mapEntries
            let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 8, dy: 8)
            let frames = StorageTreemapLayoutEngine.frames(
                weights: plottedEntries.map { Double($0.sizeBytes) },
                in: bounds,
                spacing: 4
            )
            let referenceBytes = max(1, plottedEntries.reduce(0.0) { $0 + Double(max(0, $1.sizeBytes)) })
            ZStack(alignment: .topLeading) {
                Color.primary.opacity(0.012)
                ForEach(Array(plottedEntries.enumerated()), id: \.element.id) { index, entry in
                    StorageTreemapTile(
                        entry: entry,
                        frame: frames[index],
                        tint: tint(for: entry),
                        measuredShare: Double(entry.sizeBytes) / referenceBytes,
                        isSelected: selectedEntryID == entry.id,
                        isHovered: hoveredMapEntry?.id == entry.id,
                        onSelect: { select(entry) },
                        onActivate: { activate(entry, fromLevel: currentLevelIndex) },
                        onPreview: { quickLookURL = URL(fileURLWithPath: entry.path) },
                        onReveal: { revealInFinder(path: entry.path) },
                        onCopyPath: { copyPath(entry.path) },
                        onHover: { hovering in
                            if hovering { hoveredMapEntry = entry }
                            else if hoveredMapEntry?.id == entry.id { hoveredMapEntry = nil }
                        }
                    )
                    .disabled(workspace.storageMapBrowsePhase.isLoading)
                }
                if plottedEntries.isEmpty, !workspace.storageMapBrowsePhase.isLoading {
                    storageMapEmptyState(
                        title: L10n.text("没有可绘制的容量；仍可浏览列表", "No Measurable Usage; Browse the List"),
                        systemImage: "square.grid.2x2"
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("按已记录字节绘制的矩形容量图", "Rectangular Usage Map by Recorded Bytes"))
            .accessibilityValue(mapSelectionAccessibilityValue)
            .overlay {
                if case let .loading(_, title, _, _) = workspace.storageMapBrowsePhase {
                    loadingOverlay(title: title)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if let hoveredMapEntry {
                Text("\(hoveredMapEntry.title) · \(StorageTreemapPresentation.displaySize(for: hoveredMapEntry))")
                    .font(AppDesignTokens.Typography.metadata)
                    .lineLimit(1)
                    .padding(6)
                    .background(AppDesignTokens.Palette.contentBackground, in: RoundedRectangle(cornerRadius: 5))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var mapCanvas: some View {
        GeometryReader { proxy in
            let radius = max(0, min(proxy.size.width, proxy.size.height) / 2 - 14)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let hovered = sunburstSegments.first { $0.id == hoveredSegmentID }
            ZStack {
                Color.primary.opacity(0.018)
                ForEach(sunburstSegments) { segment in
                    let shape = StorageSunburstSector(
                        start: segment.start, end: segment.end,
                        innerRadius: radius * segment.innerRadiusFraction,
                        outerRadius: radius * segment.outerRadiusFraction
                    )
                    shape
                        .fill(tint(for: segment.entry).gradient)
                        .overlay(shape.stroke(Color.black.opacity(0.4), lineWidth: 1.5))
                        .overlay(shape.stroke(
                            selectedEntryID == segment.entry.id ? Color.primary :
                                hoveredSegmentID == segment.id ? Color.primary.opacity(0.6) : .clear,
                            lineWidth: selectedEntryID == segment.entry.id ? 3 : 2
                        ))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 4) {
                    Image(systemName: hovered?.entry.canDescend == false ? "doc" : "folder.fill")
                        .foregroundStyle(AppDesignTokens.Palette.storage)
                    Text(hovered?.entry.title ?? selectedEntry?.title ?? currentSnapshot?.title ?? "")
                        .font(AppDesignTokens.Typography.compactLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if radius >= 150 {
                    Text(hovered.map { StorageTreemapPresentation.displaySize(for: $0.entry) }
                        ?? selectedEntry.map { StorageTreemapPresentation.displaySize(for: $0) }
                        ?? currentSnapshot.map { StorageTreemapPresentation.displaySize(for: summaryEntry($0)) } ?? "")
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let hovered {
                        Text(String(format: "%.1f%%", hovered.share * 100))
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    }
                }
                .multilineTextAlignment(.center)
                .frame(width: radius * 0.48)
                .position(center)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                if sunburstSegments.isEmpty, !workspace.storageMapBrowsePhase.isLoading {
                    storageMapEmptyState(
                        title: L10n.text("没有可绘制的空间占用", "No Measurable Usage"),
                        systemImage: "chart.pie"
                    )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    hoveredSegmentID = StorageSunburstLayout.segment(
                        at: point, center: center, radius: radius, in: sunburstSegments
                    )?.id
                case .ended:
                    hoveredSegmentID = nil
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                guard !workspace.storageMapBrowsePhase.isLoading,
                      let segment = StorageSunburstLayout.segment(
                        at: point, center: center, radius: radius, in: sunburstSegments
                      ) else { return }
                activate(segment.entry, fromLevel: currentLevelIndex)
            }
            .onTapGesture(coordinateSpace: .local) { point in
                guard !workspace.storageMapBrowsePhase.isLoading,
                      let segment = StorageSunburstLayout.segment(
                        at: point, center: center, radius: radius, in: sunburstSegments
                      ) else { return }
                select(segment.entry)
                isMapFocused = true
            }
            .focusable()
            .focused($isMapFocused)
            .onKeyPress(.leftArrow) { moveMapSelection(by: -1) }
            .onKeyPress(.upArrow) { moveMapSelection(by: -1) }
            .onKeyPress(.rightArrow) { moveMapSelection(by: 1) }
            .onKeyPress(.downArrow) { moveMapSelection(by: 1) }
            .onKeyPress(.return) {
                guard let selectedEntry, !workspace.storageMapBrowsePhase.isLoading else { return .ignored }
                activate(selectedEntry, fromLevel: currentLevelIndex)
                return .handled
            }
            .onKeyPress(.space) {
                guard let selectedEntry, !selectedEntry.isDirectory, !selectedEntry.path.isEmpty else { return .ignored }
                quickLookURL = URL(fileURLWithPath: selectedEntry.path)
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("按目录与字节数绘制的旭日图", "Directory sunburst by measured bytes"))
            .accessibilityValue(mapSelectionAccessibilityValue)
            .accessibilityHint(L10n.text(
                "单击选择，双击打开；方向键选择，回车打开，空格预览文件。百分比以当前目录总容量为分母。",
                "Click to select, double-click to open. Arrow keys select, Return opens, and Space previews files. Percentages use the current directory total."
            ))
            .accessibilityChildren {
                ForEach(sunburstSegments) { segment in
                    if segment.entry.role == .content {
                        Button {
                            activate(segment.entry, fromLevel: currentLevelIndex)
                        } label: {
                            Text(segment.entry.title)
                        }
                        .accessibilityValue("\(StorageTreemapPresentation.displaySize(for: segment.entry)) · \(String(format: "%.1f%%", segment.share * 100))")
                        .accessibilityAddTraits(selectedEntryID == segment.entry.id ? .isSelected : [])
                        .accessibilityAction(named: Text(L10n.text("选择", "Select"))) {
                            guard !workspace.storageMapBrowsePhase.isLoading else { return }
                            select(segment.entry)
                            isMapFocused = true
                        }
                        .accessibilityHint(mapEntryAccessibilityHint(segment.entry))
                        .disabled(workspace.storageMapBrowsePhase.isLoading)
                    } else {
                        Text("\(segment.entry.title) · \(StorageTreemapPresentation.displaySize(for: segment.entry))")
                    }
                }
            }
            .overlay {
                if case let .loading(_, title, _, _) = workspace.storageMapBrowsePhase {
                    loadingOverlay(title: title)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
    }

    private var mapSelectionAccessibilityValue: String {
        guard let selectedEntry else {
            return L10n.text("未选择目录或文件", "No folder or file selected")
        }
        return "\(selectedEntry.title) · \(StorageTreemapPresentation.displaySize(for: selectedEntry)) · \(selectedEntry.path)"
    }

    private func mapEntryAccessibilityHint(_ entry: StorageTreemapEntry) -> String {
        if entry.canDescend {
            return L10n.text("打开文件夹；也可使用选择动作查看此项", "Open folder; use the Select action to inspect this item")
        }
        if !entry.isDirectory, !entry.path.isEmpty {
            return L10n.text("预览文件；也可使用选择动作查看此项", "Preview file; use the Select action to inspect this item")
        }
        return L10n.text("可选择并查看已测容量，无法继续打开", "Select to inspect measured size; this item cannot be opened")
    }

    private func moveMapSelection(by offset: Int) -> KeyPress.Result {
        guard !workspace.storageMapBrowsePhase.isLoading else { return .ignored }
        let entries = sunburstSegments.map(\.entry).filter { $0.role == .content }
        guard !entries.isEmpty else { return .ignored }
        let current = entries.firstIndex { $0.id == selectedEntryID }
        let next = current.map { min(max(0, $0 + offset), entries.count - 1) }
            ?? (offset > 0 ? 0 : entries.count - 1)
        select(entries[next])
        return .handled
    }

    private var columnBrowser: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(
                        Array(workspace.storageMapNavigation.enumerated()),
                        id: \.element.path
                    ) { index, snapshot in
                        StorageMapColumn(
                            snapshot: snapshot,
                            entries: index == currentLevelIndex
                                ? filteredEntries
                                : StorageTreemapPresentation.visibleEntries(from: snapshot),
                            selectedPath: selectedPath(inColumnAt: index),
                            onSelect: select,
                            onActivate: { entry in
                                activate(entry, fromLevel: index)
                            },
                            onReveal: revealInFinder,
                            onPreview: { entry in quickLookURL = URL(fileURLWithPath: entry.path) },
                            onCopyPath: copyPath
                        )
                        .frame(width: StorageMapWorkspaceLayout.columnWidth)
                        .id(snapshot.path)

                        if index < workspace.storageMapNavigation.count - 1 {
                            Divider()
                        }
                    }

                    if workspace.storageMapBrowsePhase.isLoading {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(L10n.text("正在打开下一层…", "Opening Next Level…"))
                                .font(AppDesignTokens.Typography.secondary)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 240)
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 1, maxHeight: .infinity, alignment: .leading)
            }
            .onAppear {
                scrollColumnBrowserToCurrent(using: proxy)
            }
            .onChange(of: workspace.storageMapNavigation.last?.path) { _, _ in
                scrollColumnBrowserToCurrent(using: proxy)
            }
            .background(Color.primary.opacity(0.012))
        }
    }

    private func scrollColumnBrowserToCurrent(using proxy: ScrollViewProxy) {
        guard let path = workspace.storageMapNavigation.last?.path else { return }
        if reduceMotion {
            proxy.scrollTo(path, anchor: .trailing)
        } else {
            withAnimation(AppMotionTokens.stateChange) {
                proxy.scrollTo(path, anchor: .trailing)
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if let snapshot = currentSnapshot {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
                    storageMapStatusIdentity(snapshot)
                        .layoutPriority(1)
                    Spacer(minLength: AppDesignTokens.Spacing.small)
                    storageMapIndexDuration
                }

                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
                    storageMapStatusIdentity(snapshot)
                    storageMapIndexDuration
                }
            }
        }
    }

    private func storageMapStatusIdentity(_ snapshot: StorageMapDirectorySnapshot) -> some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: snapshot.isComplete
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(snapshot.isComplete
                    ? AppDesignTokens.Palette.success
                    : AppDesignTokens.Palette.warning)
            Text(storageMapStatusText(snapshot))
                .font(AppDesignTokens.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var storageMapIndexDuration: some View {
        if let analysis = workspace.storageAnalysis {
            Text(String(format: L10n.text("索引 %.1f 秒", "Indexed in %.1f sec"), analysis.scanSeconds))
                .font(AppDesignTokens.Typography.metadata)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func browseFailure(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppDesignTokens.Palette.warning)
            Text(message)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.text("重试", "Retry")) {
                workspace.retryStorageMapBrowse()
            }
            .appButtonChrome(.secondary)
        }
        .padding(.horizontal, AppDesignTokens.Spacing.medium)
        .padding(.bottom, AppDesignTokens.Spacing.small)
    }

    private func loadingOverlay(title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(L10n.text("正在打开“\(title)”…", "Opening “\(title)”…"))
                .font(AppDesignTokens.Typography.inlineTitle)
            Text(L10n.text(
                "正在读取当前一层，目录大小直接复用已完成的索引",
                "Reading this level; folder sizes come from the completed index"
            ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.text("取消", "Cancel")) {
                workspace.cancelStorageMapBrowse()
            }
            .appButtonChrome(.secondary)
        }
        .padding(AppDesignTokens.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }

    private func storageMapEmptyState(title: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppDesignTokens.Spacing.large)
    }

    private var directoryCount: Int {
        entries.filter(\.isDirectory).count
    }

    private var fileCount: Int {
        entries.count - directoryCount
    }

    private func summaryEntry(_ snapshot: StorageMapDirectorySnapshot) -> StorageTreemapEntry {
        StorageTreemapEntry(
            id: snapshot.path,
            title: snapshot.title,
            path: snapshot.path,
            sizeBytes: snapshot.referenceBytes,
            kind: "folder",
            isDirectory: true,
            childCount: snapshot.entries.count,
            isEstimated: snapshot.referenceIsEstimated
        )
    }

    private func selectedPath(inColumnAt index: Int) -> String? {
        if let selectedEntryID,
           workspace.storageMapNavigation[index].entries.contains(where: { $0.id == selectedEntryID }) {
            return selectedEntryID
        }
        if workspace.storageMapNavigation.indices.contains(index + 1) {
            return workspace.storageMapNavigation[index + 1].path
        }
        return index == currentLevelIndex ? selectedEntryID : nil
    }

    private func select(_ entry: StorageTreemapEntry) {
        guard entry.role == .content else { return }
        selectedEntryID = entry.id
        selectedMapEntry = entry
    }

    private func activate(_ entry: StorageTreemapEntry, fromLevel level: Int) {
        guard entry.role == .content, !workspace.storageMapBrowsePhase.isLoading else { return }
        select(entry)
        if entry.canDescend {
            workspace.openStorageMapDirectory(entry, fromLevel: StorageTreemapPresentation.navigationLevel(
                for: entry,
                in: workspace.storageMapNavigation,
                fallback: level
            ))
        } else if !entry.isDirectory, !entry.path.isEmpty {
            quickLookURL = URL(fileURLWithPath: entry.path)
        }
    }

    private func revealInFinder(path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyPath(_ path: String) {
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func storageMapStatusText(_ snapshot: StorageMapDirectorySnapshot) -> String {
        if snapshot.isComplete {
            if snapshot.omittedEntryCount > 0 {
                return L10n.text(
                    "目录索引已完成；当前显示 \(snapshot.entries.count) 项，另有 \(snapshot.omittedEntryCount) 项未列出",
                    "Directory index complete; showing \(snapshot.entries.count) items, with \(snapshot.omittedEntryCount) more not listed"
                )
            }
            return L10n.text(
                "目录索引已完成；切换层级只读取当前一层，不会重新递归扫描",
                "Directory index complete; changing levels reads only the current folder"
            )
        }
        let omitted = workspace.storageAnalysis?.omittedItemCount ?? snapshot.omittedEntryCount
        return L10n.text(
            "已索引所有可访问项目；另有 \(omitted) 项受权限、排除设置或云端状态限制，容量按至少占用显示",
            "All accessible items were indexed; \(omitted) were limited by access, exclusions, or cloud state"
        )
    }

    private func tint(for entry: StorageTreemapEntry) -> Color {
        switch entry.role {
        case .measuredRemainder:
            return AppDesignTokens.Palette.StorageCategory.measuredRemainder
        case .unmeasuredRemainder:
            return AppDesignTokens.Palette.StorageCategory.unmeasuredRemainder
        case .content:
            return StorageMapCategoryAppearance.tint(for: entry.contentCategory)
        }
    }
}

private enum StorageMapCategoryAppearance {
    static func tint(for category: StorageMapContentCategory) -> Color {
        switch category {
        case .application: AppDesignTokens.Palette.StorageCategory.application
        case .image: AppDesignTokens.Palette.StorageCategory.image
        case .video: AppDesignTokens.Palette.StorageCategory.video
        case .audio: AppDesignTokens.Palette.StorageCategory.audio
        case .document: AppDesignTokens.Palette.StorageCategory.document
        case .archive: AppDesignTokens.Palette.StorageCategory.archive
        case .developer: AppDesignTokens.Palette.StorageCategory.developer
        case .data: AppDesignTokens.Palette.StorageCategory.data
        case .system: AppDesignTokens.Palette.StorageCategory.system
        case .other: AppDesignTokens.Palette.StorageCategory.other
        }
    }
}

private struct StorageMapCategoryLegendItem: View {
    let category: StorageMapContentCategory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(StorageMapCategoryAppearance.tint(for: category))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(category.title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(AppDesignTokens.Typography.metadata.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StorageMapColumn: View {
    let snapshot: StorageMapDirectorySnapshot
    let entries: [StorageTreemapEntry]
    let selectedPath: String?
    let onSelect: (StorageTreemapEntry) -> Void
    let onActivate: (StorageTreemapEntry) -> Void
    let onReveal: (String) -> Void
    let onPreview: (StorageTreemapEntry) -> Void
    let onCopyPath: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
                Label {
                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.tight) {
                        Text(snapshot.title)
                            .font(AppDesignTokens.Typography.compactLabel.weight(.semibold))
                            .lineLimit(1)
                            .help(snapshot.path)
                        Text(L10n.items(snapshot.entries.count))
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(AppDesignTokens.Palette.storage)
                }
                .layoutPriority(1)

                Spacer(minLength: AppDesignTokens.Spacing.small)

                Text(snapshot.referenceIsEstimated
                    ? L10n.text("至少 \(ByteFormat.storageString(snapshot.referenceBytes))", "At least \(ByteFormat.storageString(snapshot.referenceBytes))")
                    : ByteFormat.storageString(snapshot.referenceBytes))
                    .font(AppDesignTokens.Typography.metadata)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.025))

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    if entries.isEmpty {
                        Text(L10n.text("没有可显示的项目", "No Items to Display"))
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(entries) { entry in
                        StorageMapEntryRow(
                            entry: entry,
                            referenceBytes: snapshot.referenceBytes,
                            isSelected: selectedPath.map(PathSafety.normalizedPath)
                                == PathSafety.normalizedPath(entry.path),
                            onSelect: { onSelect(entry) },
                            onActivate: { onActivate(entry) },
                            onReveal: { onReveal(entry.path) },
                            onPreview: { onPreview(entry) },
                            onCopyPath: { onCopyPath(entry.path) }
                        )
                    }
                }
                .padding(6)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct StorageTreemapTile: View {
    let entry: StorageTreemapEntry
    let frame: CGRect
    let tint: Color
    let measuredShare: Double
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onHover: (Bool) -> Void

    private var shareText: String {
        guard measuredShare.isFinite, measuredShare > 0 else { return "0%" }
        if measuredShare < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", measuredShare * 100)
    }

    private var tileIcon: String {
        switch entry.role {
        case .content:
            if entry.kind == "package" { return entry.contentCategory.systemImage }
            return entry.isDirectory ? "folder.fill" : entry.contentCategory.systemImage
        case .measuredRemainder:
            return "square.stack.3d.up.fill"
        case .unmeasuredRemainder:
            return "exclamationmark.triangle.fill"
        }
    }

    private var showsTileTitle: Bool {
        frame.width >= 58 && frame.height >= 36
    }

    private var tileSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.12 : isHovered ? 0.075 : 0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(isSelected ? 0.12 : 0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isSelected ? tint : Color.primary.opacity(isHovered ? 0.28 : 0.12), lineWidth: isSelected ? 2 : 1)
                }

            if showsTileTitle {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: frame.height >= 90 ? 6 : 3) {
                        if frame.width >= 82, frame.height >= 64 {
                            Image(systemName: tileIcon)
                                .font(frame.height >= 120 ? .system(size: 30) : .body)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(tint)
                        }
                        Text(entry.title)
                            .font(AppDesignTokens.Typography.compactLabel.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if frame.width >= 92, frame.height >= 58 {
                            Text(StorageTreemapPresentation.displaySize(for: entry))
                                .font(AppDesignTokens.Typography.metadata)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(entry.title)
                        .font(AppDesignTokens.Typography.compactLabel.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: tileIcon)
                        .font(.body)
                        .foregroundStyle(tint)
                }
                .padding(7)
            } else if frame.width >= 34, frame.height >= 28 {
                Image(systemName: tileIcon)
                    .font(.body)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .clipped()
    }

    @ViewBuilder
    var body: some View {
        Group {
            if entry.role == .content {
                Button(action: onSelect) {
                    tileSurface
                }
                .buttonStyle(ResponsivePlainButtonStyle())
                .simultaneousGesture(TapGesture(count: 2).onEnded(onActivate))
                .onKeyPress(.return) {
                    onActivate()
                    return .handled
                }
                .onKeyPress(.space) {
                    guard !entry.isDirectory, !entry.path.isEmpty else { return .ignored }
                    onPreview()
                    return .handled
                }
                .accessibilityAction(named: Text(L10n.text("打开", "Open")), onActivate)
                .contextMenu {
                    if entry.canDescend {
                        Button(L10n.text("打开文件夹", "Open Folder"), action: onActivate)
                    } else if !entry.isDirectory, !entry.path.isEmpty {
                        Button(L10n.text("快速预览", "Quick Look"), action: onPreview)
                    }
                    Button(L10n.text("在访达中显示", "Show in Finder"), action: onReveal)
                    Button(L10n.text("复制路径", "Copy Path"), action: onCopyPath)
                }
            } else {
                tileSurface
                    .accessibilityElement(children: .ignore)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .onHover(perform: onHover)
        .help(entry.role == .content
            ? "\(entry.path)\n\(StorageTreemapPresentation.displaySize(for: entry)) · \(shareText) · " + L10n.text("占本层已记录容量；受限目录容量为下限", "of recorded folder bytes; restricted totals are lower bounds")
            : "\(entry.title) · \(StorageTreemapPresentation.displaySize(for: entry))\n" + L10n.text("汇总区域，不能直接打开；具体已测项目可在完整列表中查看", "Summary region; cannot be opened. Browse individual measured items in the complete list"))
        .accessibilityLabel("\(entry.title)，\(entry.contentCategory.title)，\(StorageTreemapPresentation.displaySize(for: entry))，\(shareText)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(entry.role != .content
            ? L10n.text("容量汇总，不能打开", "Usage summary; cannot be opened")
            : entry.canDescend
                ? L10n.text("单击选择；双击、回车或打开动作进入目录", "Click to select; double-click, Return, or Open enters the folder")
                : entry.isDirectory
                    ? L10n.text("可查看已记录容量，无法打开此目录", "Inspect recorded usage; this folder cannot be opened")
                    : L10n.text("单击选择；空格快速预览文件", "Click to select; Space previews the file"))
    }
}

private struct StorageMapEntryRow: View {
    let entry: StorageTreemapEntry
    let referenceBytes: Int64
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onReveal: () -> Void
    let onPreview: () -> Void
    let onCopyPath: () -> Void

    private var recordedShare: Double? {
        guard referenceBytes > 0 else { return nil }
        return min(1, max(0, Double(entry.sizeBytes) / Double(referenceBytes)))
    }

    private var shareText: String {
        guard let recordedShare else { return "—" }
        if recordedShare > 0, recordedShare < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", recordedShare * 100)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: entry.kind == "package"
                    ? entry.contentCategory.systemImage
                    : entry.isDirectory ? "folder.fill" : entry.contentCategory.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20)
                    .foregroundStyle(StorageMapCategoryAppearance.tint(for: entry.contentCategory))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(AppDesignTokens.Typography.compactLabel.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(entrySecondaryMetadata)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(StorageTreemapPresentation.displaySize(for: entry))
                            .font(AppDesignTokens.Typography.metadata)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                        HStack(spacing: 5) {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.07))
                                    Capsule()
                                        .fill(StorageMapCategoryAppearance.tint(for: entry.contentCategory).opacity(0.8))
                                        .frame(width: proxy.size.width * (recordedShare ?? 0))
                                }
                            }
                            .frame(width: 42, height: 3)
                            .accessibilityHidden(true)
                            Text(shareText)
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                    if entry.canDescend {
                        Image(systemName: "chevron.right")
                            .font(AppDesignTokens.Typography.metadata.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .contentShape(Rectangle())
            .frame(height: 48, alignment: .leading)
            .padding(.horizontal, 9)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                        ? AppDesignTokens.Palette.storage.opacity(0.16)
                        : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? AppDesignTokens.Palette.storage.opacity(0.52)
                            : Color.clear,
                        lineWidth: 1
                    )
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(AppDesignTokens.Palette.storage)
                        .frame(width: 3, height: 24)
                        .padding(.leading, 2)
                }
            }
        }
        .buttonStyle(ResponsivePlainButtonStyle())
        .simultaneousGesture(TapGesture(count: 2).onEnded(onActivate))
        .onKeyPress(.return) {
            onActivate()
            return .handled
        }
        .onKeyPress(.space) {
            guard !entry.isDirectory, !entry.path.isEmpty else { return .ignored }
            onPreview()
            return .handled
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: L10n.text("打开", "Open"), onActivate)
        .accessibilityHint(entry.canDescend
            ? L10n.text("单击选择，双击或回车打开下一层", "Click to select; double-click or press Return to open the next level")
            : L10n.text("选择文件并查看详细信息", "Select the file for details"))
        .contextMenu {
            if entry.canDescend {
                Button(L10n.text("打开文件夹", "Open Folder"), action: onActivate)
            } else if !entry.isDirectory, !entry.path.isEmpty {
                Button(L10n.text("快速预览", "Quick Look"), action: onPreview)
            }
            Button(action: onReveal) {
                Label(L10n.text("在访达中显示", "Show in Finder"), systemImage: "folder")
            }
            Button(L10n.text("复制路径", "Copy Path"), action: onCopyPath)
        }
        .help("\(entry.path)\n\(StorageTreemapPresentation.displaySize(for: entry)) · \(shareText) · " + L10n.text(
            "占本层已记录容量；受限目录容量为下限，不代表完整磁盘比例",
            "of this folder’s recorded bytes; restricted totals are lower bounds, not a share of the complete disk"
        ))
        .accessibilityValue("\(entry.path) · \(StorageTreemapPresentation.displaySize(for: entry)) · \(shareText)")
    }

    private var entrySecondaryMetadata: String {
        var components = [entry.contentCategory.title]
        if let childCount = entry.childCount {
            components.append(L10n.items(childCount))
        }
        return components.joined(separator: " · ")
    }
}

private struct StorageSunburstSector: Shape {
    let start: Double
    let end: Double
    let innerRadius: Double
    let outerRadius: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}
