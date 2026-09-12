import SwiftUI

enum ItemListSelectionResolver {
    static func resolvedSelectionID(
        currentSelectionID: String?,
        visibleItemIDs: [String]
    ) -> String? {
        if let currentSelectionID, visibleItemIDs.contains(currentSelectionID) {
            return currentSelectionID
        }
        return visibleItemIDs.first
    }
}

enum ItemListKeyboardSelectionDirection: Equatable {
    case previous
    case next
}

enum ItemListKeyboardSelectionResolver {
    static func resolvedSelectionID(
        currentSelectionID: String?,
        visibleItemIDs: [String],
        direction: ItemListKeyboardSelectionDirection
    ) -> String? {
        guard !visibleItemIDs.isEmpty else { return nil }

        guard let currentSelectionID,
              let currentIndex = visibleItemIDs.firstIndex(of: currentSelectionID) else {
            return direction == .next ? visibleItemIDs.first : visibleItemIDs.last
        }

        let offset = direction == .next ? 1 : -1
        let nextIndex = min(max(currentIndex + offset, 0), visibleItemIDs.count - 1)
        return visibleItemIDs[nextIndex]
    }
}

enum ItemListResponsiveLayout {
    static let minimumListWidth: CGFloat = 360
    static let preferredListWidth: CGFloat = 430
    static let minimumDetailWidth: CGFloat = 300
    static let dividerWidth: CGFloat = 1

    enum Mode: Equatable {
        case sideBySide(listWidth: CGFloat, detailWidth: CGFloat)
        case stacked
    }

    static func mode(availableWidth: CGFloat) -> Mode {
        guard availableWidth.isFinite else { return .stacked }

        let availableWidth = max(0, availableWidth)
        let maximumListWidth = availableWidth - dividerWidth - minimumDetailWidth
        guard maximumListWidth >= minimumListWidth else { return .stacked }

        let listWidth = min(
            max(availableWidth * 0.46, minimumListWidth),
            min(preferredListWidth, maximumListWidth)
        )
        let detailWidth = availableWidth - dividerWidth - listWidth
        return .sideBySide(listWidth: listWidth, detailWidth: detailWidth)
    }
}

struct ItemListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var store: ScanStore
    let filter: ReviewFilter
    @State private var searchText = ""
    @State private var scopeFilter: ItemScopeFilter = .all
    @State private var sortMode: ItemSortMode = .sizeDescending
    @FocusState private var focusedItemID: String?

    private var rawItems: [StorageItem] {
        store.items(for: filter)
    }

    private var items: [StorageItem] {
        ItemListPresenter.visibleItems(
            from: rawItems,
            query: searchText,
            scopeFilter: scopeFilter,
            sortMode: sortMode
        )
    }

    private var metrics: ItemListMetrics {
        ItemListPresenter.metrics(rawItems: rawItems, visibleItems: items)
    }

    private var availableScopes: [ItemScopeFilter] {
        ItemListPresenter.availableScopes(for: rawItems)
    }

    private var hasStatusMetrics: Bool {
        filter != .green
            && (metrics.cleanableCount > 0 || metrics.reviewCount > 0 || metrics.carefulCount > 0)
    }

    private var statusMetricItems: [ItemListStatusMetric] {
        var result = [ItemListStatusMetric]()
        if metrics.cleanableCount > 0 {
            result.append(
                ItemListStatusMetric(
                    id: "cleanable",
                    title: L10n.text("可安全清理", "Safe to Clean"),
                    value: "\(metrics.cleanableCount)",
                    systemImage: "checkmark",
                    tint: AppDesignTokens.Palette.success
                )
            )
        }
        if metrics.reviewCount > 0 {
            result.append(
                ItemListStatusMetric(
                    id: "review",
                    title: L10n.text("需确认", "Needs Review"),
                    value: "\(metrics.reviewCount)",
                    systemImage: "questionmark",
                    tint: AppDesignTokens.Palette.warning
                )
            )
        }
        if metrics.carefulCount > 0 {
            result.append(
                ItemListStatusMetric(
                    id: "careful",
                    title: L10n.text("谨慎处理", "Handle Carefully"),
                    value: "\(metrics.carefulCount)",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: AppDesignTokens.Palette.destructive
                )
            )
        }
        return result
    }

    private var shouldShowCleanupRecord: Bool {
        store.cleanupHistorySummary.totalCount > 0
            || rawItems.contains { $0.status == .movedToTrash }
    }

    private var defaultScopeFilter: ItemScopeFilter {
        filter == .green ? .cleanable : .all
    }

    private var visibleItemIDs: [String] {
        items.map(\.id)
    }

    var body: some View {
        let currentItems = items
        let currentSelectionID = ItemListSelectionResolver.resolvedSelectionID(
            currentSelectionID: store.selectedItemID,
            visibleItemIDs: currentItems.map(\.id)
        )
        let currentSelectedItem = currentSelectionID.flatMap { selectedID in
            currentItems.first { $0.id == selectedID }
        }

        return GeometryReader { geometry in
            Group {
                if currentItems.isEmpty {
                    listPane(
                        currentItems: currentItems,
                        currentSelectionID: currentSelectionID
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch ItemListResponsiveLayout.mode(availableWidth: geometry.size.width) {
                    case let .sideBySide(listWidth, detailWidth):
                        HStack(spacing: 0) {
                            listPane(
                                currentItems: currentItems,
                                currentSelectionID: currentSelectionID
                            )
                            .frame(width: listWidth)
                            .frame(maxHeight: .infinity)
                            .clipped()

                            Divider()
                                .frame(width: ItemListResponsiveLayout.dividerWidth)

                            detailPane(currentSelectedItem: currentSelectedItem)
                                .frame(width: detailWidth)
                                .frame(maxHeight: .infinity)
                                .clipped()
                        }
                    case .stacked:
                        VStack(spacing: 0) {
                            listPane(
                                currentItems: currentItems,
                                currentSelectionID: currentSelectionID
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()

                            Divider()

                            detailPane(currentSelectedItem: currentSelectedItem)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                        }
                    }
                }
            }
        }
        .onAppear {
            applyPreferredScopeIfNeeded()
            refreshSelectionIfNeeded()
        }
        .onChange(of: filter) { _, _ in
            searchText = ""
            scopeFilter = preferredScopeForCurrentFilter()
            sortMode = .sizeDescending
        }
        .onChange(of: store.preferredItemScopeFilter) { _, _ in
            applyPreferredScopeIfNeeded()
        }
        .onChange(of: searchText) { _, _ in
            refreshSelectionIfNeeded()
        }
        .onChange(of: scopeFilter) { _, _ in
            refreshSelectionIfNeeded()
        }
        .onChange(of: sortMode) { _, _ in
            refreshSelectionIfNeeded()
        }
        .onChange(of: visibleItemIDs) { _, _ in
            refreshSelectionIfNeeded()
        }
    }

    private func listPane(
        currentItems: [StorageItem],
        currentSelectionID: String?
    ) -> some View {
        VStack(spacing: 0) {
            listHeader
            if currentItems.isEmpty {
                EmptyItemsView(filter: filter, message: emptyMessage)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(currentItems) { item in
                            Button {
                                store.selectedItemID = item.id
                                focusedItemID = item.id
                            } label: {
                                ItemRow(
                                    item: item,
                                    isSelected: currentSelectionID == item.id,
                                    isFocused: focusedItemID == item.id
                                )
                            }
                            .buttonStyle(ResponsivePlainButtonStyle())
                            .contentShape(Rectangle())
                            .focused($focusedItemID, equals: item.id)
                            .onMoveCommand(perform: moveSelection)
                            .transition(AppMotionTokens.listTransition(reduceMotion: reduceMotion))
                            .accessibilityLabel(item.title)
                            .accessibilityValue(
                                itemAccessibilityValue(
                                    item,
                                    isSelected: currentSelectionID == item.id
                                )
                            )
                            .accessibilityAddTraits(
                                currentSelectionID == item.id ? .isSelected : []
                            )
                        }
                    }
                    .animation(
                        AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                        value: scopeFilter
                    )
                    .animation(
                        AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                        value: sortMode
                    )
                    .animation(
                        AppMotionTokens.resolved(AppMotionTokens.stateChange, reduceMotion: reduceMotion),
                        value: rawItems.map(\.id)
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(listPaneFill)
#if DEBUG
        .layoutProbe(LayoutProbeID.itemListPane)
#endif
    }

    private func detailPane(currentSelectedItem: StorageItem?) -> some View {
        ZStack {
            Group {
                if let item = currentSelectedItem {
                    ItemDetailView(store: store, item: item)
                } else {
                    EmptyItemsView(filter: filter, message: emptyMessage)
                }
            }
            .id(currentSelectedItem?.id ?? "empty-selection")
            .transition(AppMotionTokens.pageTransition(reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            AppMotionTokens.resolved(AppMotionTokens.navigation, reduceMotion: reduceMotion),
            value: currentSelectedItem?.id
        )
#if DEBUG
        .layoutProbe(LayoutProbeID.itemDetailPane)
#endif
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: filter.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(filter.accentColor)
                    .frame(width: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        filter == .green
                            ? L10n.text("可清理项目", "Cleanable Items")
                            : filter.title
                    )
                        .font(AppDesignTokens.Typography.pageTitle)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L10n.itemBytes(metrics.visibleCount, ByteFormat.string(metrics.visibleBytes)))
                        .font(AppDesignTokens.Typography.pageSubtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if filter == .green && store.canRequestGreenTrash {
                    Button {
                        store.requestTrashAllGreen()
                    } label: {
                        Label(
                            L10n.text("选择清理项目", "Choose Cleanup Items"),
                            systemImage: "checkmark.square"
                        )
                    }
                    .appButtonChrome(.primary)
                    .controlSize(.regular)
                }
            }

            if hasStatusMetrics {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(statusMetricItems) { metric in
                            ItemListMetricPill(metric: metric)
                        }
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)
                        ],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(statusMetricItems) { metric in
                            ItemListMetricPill(metric: metric)
                        }
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    TaskSearchField(
                        placeholder: L10n.text("搜索名称或路径", "Search Name or Path"),
                        text: $searchText,
                        tint: filter.accentColor
                    )
                    filterAndSortControls
                }

                VStack(alignment: .leading, spacing: 8) {
                    TaskSearchField(
                        placeholder: L10n.text("搜索名称或路径", "Search Name or Path"),
                        text: $searchText,
                        tint: filter.accentColor
                    )
                    filterAndSortControls
                }
            }
            .controlSize(.regular)
            .font(AppDesignTokens.Typography.metadata)

            if filter == .green && shouldShowCleanupRecord {
                Divider()
                greenCleanupRecordStrip
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, AppDesignTokens.Spacing.medium)
        .background(headerFill)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var listPaneFill: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
        return AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.026))
    }

    private var headerFill: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
        return AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.065 : 0.038))
    }

    private var greenCleanupRecordStrip: some View {
        let summary = store.cleanupHistorySummary
        let movedCount = rawItems.filter { $0.status == .movedToTrash }.count

        return HStack(alignment: .center, spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(filter.accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("清理记录", "Cleanup History"))
                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                    .fixedSize(horizontal: false, vertical: true)
                Text(cleanupRecordDetail(summary: summary, movedCount: movedCount))
                    .font(AppDesignTokens.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Menu {
                if let latest = summary.latest {
                    Button {
                        store.copyCleanupHistoryEntry(latest)
                    } label: {
                        Label(
                            L10n.text("复制最近记录", "Copy Latest Record"),
                            systemImage: "doc.on.doc"
                        )
                    }
                }

                if store.canRestoreLatestCleanup {
                    Button {
                        store.requestRestoreLatestCleanup()
                    } label: {
                        Label(
                            L10n.text("撤销最近清理", "Undo Latest Cleanup"),
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                }

                Button {
                    store.openTrashFolder()
                } label: {
                    Label(
                        L10n.text("查看废纸篓", "Review Trash"),
                        systemImage: "trash"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(L10n.text("清理记录操作", "Cleanup History Actions"))
            .help(L10n.text("复制记录、撤销或查看废纸篓", "Copy, undo, or review Trash"))
            .appButtonChrome(.secondary)
            .controlSize(.small)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    private func cleanupRecordDetail(summary: CleanupHistorySummary, movedCount: Int) -> String {
        if let latest = summary.latest {
            let latestText = latest.date.formatted(date: .abbreviated, time: .shortened)
            return L10n.text(
                "最近 \(latest.itemCount) 项 · \(ByteFormat.string(latest.totalBytes)) · \(latestText)",
                "Latest: \(latest.itemCount) item(s) · \(ByteFormat.string(latest.totalBytes)) · \(latestText)"
            )
        }
        if movedCount > 0 {
            return L10n.text(
                "\(movedCount) 项已移入废纸篓，清空前仍可恢复。",
                "\(movedCount) item(s) moved to Trash and recoverable until emptied."
            )
        }
        return L10n.text(
            "清理后会在这里保留可复核记录。",
            "Cleanup records will remain available here."
        )
    }

    private var filterAndSortControls: some View {
        HStack(spacing: 7) {
            Menu {
                Picker(L10n.text("范围", "Scope"), selection: $scopeFilter) {
                    ForEach(availableScopes) { scope in
                        Label(scope.title, systemImage: scope.systemImage)
                            .tag(scope)
                    }
                }
            } label: {
                Label(scopeFilter.title, systemImage: scopeFilter.systemImage)
            }
            .appButtonChrome(.secondary)
            .help(L10n.text("筛选显示范围", "Filter Scope"))

            Menu {
                Picker(L10n.text("排序", "Sort"), selection: $sortMode) {
                    ForEach(ItemSortMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
            } label: {
                Label(sortMode.title, systemImage: sortMode.systemImage)
                    .labelStyle(.titleAndIcon)
            }
            .appButtonChrome(.secondary)
            .fixedSize()
            .help(L10n.text("更改排序", "Change Sort"))

            if scopeFilter != defaultScopeFilter || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AppIconButton(
                    title: L10n.text("重置搜索和筛选", "Reset Search and Filters"),
                    systemImage: "xmark",
                    kind: .toolbar
                ) {
                    searchText = ""
                    scopeFilter = defaultScopeFilter
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var emptyMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.text("没有匹配项目", "No matching items")
        }
        if scopeFilter != .all {
            return L10n.text("当前范围没有项目", "No items in this scope")
        }
        if filter == .duplicates {
            return L10n.text("到重复文件页扫描", "Scan in Duplicates")
        }
        return L10n.noItems(filterTitle: filter.title)
    }

    private func refreshSelectionIfNeeded() {
        let resolvedSelectionID = ItemListSelectionResolver.resolvedSelectionID(
            currentSelectionID: store.selectedItemID,
            visibleItemIDs: visibleItemIDs
        )
        if store.selectedItemID != resolvedSelectionID {
            store.selectedItemID = resolvedSelectionID
        }
        if let focusedItemID, !visibleItemIDs.contains(focusedItemID) {
            self.focusedItemID = resolvedSelectionID
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let keyboardDirection: ItemListKeyboardSelectionDirection
        switch direction {
        case .up:
            keyboardDirection = .previous
        case .down:
            keyboardDirection = .next
        default:
            return
        }

        guard let resolvedSelectionID = ItemListKeyboardSelectionResolver.resolvedSelectionID(
            currentSelectionID: store.selectedItemID,
            visibleItemIDs: visibleItemIDs,
            direction: keyboardDirection
        ) else {
            return
        }
        store.selectedItemID = resolvedSelectionID
        focusedItemID = resolvedSelectionID
    }

    private func itemAccessibilityValue(_ item: StorageItem, isSelected: Bool) -> String {
        let size = ByteFormat.string(item.sizeBytes)
        var details = [item.kind, size, item.path]
        if item.status == .movedToTrash {
            details.append(L10n.text("已移入废纸篓", "Moved to Trash"))
        }
        if isSelected {
            details.append(L10n.text("已选择", "Selected"))
        }
        return details.joined(separator: L10n.text("，", ", "))
    }

    private func preferredScopeForCurrentFilter() -> ItemScopeFilter {
        guard filter == .green else { return .all }
        return store.preferredItemScopeFilter ?? .cleanable
    }

    private func applyPreferredScopeIfNeeded() {
        guard filter == .green else { return }
        scopeFilter = preferredScopeForCurrentFilter()
        store.preferredItemScopeFilter = nil
        refreshSelectionIfNeeded()
    }
}

private struct ItemRow: View {
    let item: StorageItem
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.tier.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.title3.weight(.semibold))
                .foregroundStyle(item.tier.color)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title)
                        .font(AppDesignTokens.Typography.cardTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.status == .movedToTrash {
                        Label(L10n.text("已移除", "Removed"), systemImage: "checkmark")
                            .font(AppDesignTokens.Typography.compactLabel)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text(item.kind)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(item.tier.color)

                    Text(item.path)
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Text(ByteFormat.string(item.sizeBytes))
                .font(AppDesignTokens.Typography.metadata)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(isSelected ? item.tier.color : Color.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .appSelectableRowSurface(
            isSelected: isSelected,
            isFocused: isFocused
        )
    }
}

private struct ItemListStatusMetric: Identifiable {
    let id: String
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
}

private struct ItemListMetricPill: View {
    let metric: ItemListStatusMetric

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: metric.systemImage)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .foregroundStyle(metric.tint)
                .accessibilityHidden(true)
            Text(metric.value)
                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                .monospacedDigit()
                .appNumericTransition(value: metric.value)
            Text(metric.title)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(metric.value)
    }
}

private struct EmptyItemsView: View {
    let filter: ReviewFilter
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filter.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(filter.accentColor)
                .accessibilityHidden(true)
            Text(message)
                .font(AppDesignTokens.Typography.inlineTitle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension ItemScopeFilter {
    var tint: Color {
        switch self {
        case .all: AppDesignTokens.Palette.storage
        case .cleanable: AppDesignTokens.Palette.success
        case .needsReview: AppDesignTokens.Palette.warning
        case .careful: AppDesignTokens.Palette.destructive
        case .removed: .secondary
        }
    }
}
