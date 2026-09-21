import SwiftUI

struct StartupItemsScanProgress: Equatable, Sendable {
    let title: String
    let discoveredCount: Int

    init(title: String, discoveredCount: Int) {
        self.title = title
        self.discoveredCount = max(0, discoveredCount)
    }
}

/// Window-scoped actions let Command-R and Command-F target this console only
/// while it owns focus, instead of stealing the app-wide storage scan shortcut.
struct StartupItemsKeyboardActions {
    let refresh: @MainActor () -> Void
    let focusSearch: @MainActor () -> Void
}

private struct StartupItemsKeyboardActionsKey: FocusedValueKey {
    typealias Value = StartupItemsKeyboardActions
}

extension FocusedValues {
    var startupItemsKeyboardActions: StartupItemsKeyboardActions? {
        get { self[StartupItemsKeyboardActionsKey.self] }
        set { self[StartupItemsKeyboardActionsKey.self] = newValue }
    }
}

/// A value-driven management console for normalized startup-item snapshots.
/// It does not read files, execute commands, or decide capabilities itself.
struct StartupItemsDashboardView: View {
    @Environment(\.moduleTheme) private var theme
    let items: [StartupItemsDomain.Item]
    let isLoading: Bool
    let progress: StartupItemsScanProgress?
    let activeOperationCandidateID: String?
    let isPerformingOperation: Bool
    let coverageAction: AnyView

    let onRefresh: () -> Void
    let onCancel: () -> Void
    var onEnable: ((StartupItemsDomain.Candidate) -> Void)?
    var onDisable: ((StartupItemsDomain.Candidate) -> Void)?
    var onStop: ((StartupItemsDomain.Candidate) -> Void)?
    var onReveal: ((StartupItemsDomain.Item) -> Void)?
    var onOpenParentApplication: ((StartupItemsDomain.Item) -> Void)?
    var onCopyText: ((String) -> Void)?
    var onOpenSystemSettings: (() -> Void)?

    @State private var query = ""
    @AppStorage("startupItems.category.v1") private var category: StartupItemsCategory = .all
    @AppStorage("startupItems.status.v1") private var status: StartupItemsStatusFilter = .all
    @AppStorage("startupItems.source.v1") private var source: StartupItemsSourceFilter = .all
    @AppStorage("startupItems.sort.v1") private var sort: StartupItemsSortOrder = .recommended
    @State private var showsTechnicalDetails = false
    @AppStorage("startupItems.includeAppleSystem.v1") private var includeAppleSystem = false
    @State private var selectedItemID: String?
    @State private var inspectedItem: StartupItemsDomain.Item?
    @FocusState private var isSearchFocused: Bool

    private var primaryCategories: [StartupItemsCategory] {
        [.all, .loginItems, .background]
    }

    private var effectiveCategory: StartupItemsCategory {
        primaryCategories.contains(category) ? category : .all
    }

    private var primaryCategoryBinding: Binding<StartupItemsCategory> {
        Binding(
            get: { effectiveCategory },
            set: { category = $0 }
        )
    }

    init(
        items: [StartupItemsDomain.Item],
        isLoading: Bool,
        progress: StartupItemsScanProgress?,
        activeOperationCandidateID: String? = nil,
        isPerformingOperation: Bool = false,
        coverageAction: AnyView,
        onRefresh: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onEnable: ((StartupItemsDomain.Candidate) -> Void)? = nil,
        onDisable: ((StartupItemsDomain.Candidate) -> Void)? = nil,
        onStop: ((StartupItemsDomain.Candidate) -> Void)? = nil,
        onReveal: ((StartupItemsDomain.Item) -> Void)? = nil,
        onOpenParentApplication: ((StartupItemsDomain.Item) -> Void)? = nil,
        onCopyText: ((String) -> Void)? = nil,
        onOpenSystemSettings: (() -> Void)? = nil
    ) {
        self.items = items
        self.isLoading = isLoading
        self.progress = progress
        self.activeOperationCandidateID = activeOperationCandidateID
        self.isPerformingOperation = isPerformingOperation
        self.coverageAction = coverageAction
        self.onRefresh = onRefresh
        self.onCancel = onCancel
        self.onEnable = onEnable
        self.onDisable = onDisable
        self.onStop = onStop
        self.onReveal = onReveal
        self.onOpenParentApplication = onOpenParentApplication
        self.onCopyText = onCopyText
        self.onOpenSystemSettings = onOpenSystemSettings
    }

    var body: some View {
        let presentation = StartupItemsPresentation.make(
            items: items,
            query: query,
            category: effectiveCategory,
            status: status,
            source: source,
            includeAppleSystem: showsTechnicalDetails && includeAppleSystem,
            sort: sort,
            includeTechnicalDetails: showsTechnicalDetails
        )

        ManagementListPage(
            title: L10n.text("登录项与后台任务", "Login Items & Background Tasks"),
            subtitle: ReviewFilter.startup.pageSubtitle,
            systemImage: AppSymbols.Navigation.loginItems
        ) {
            coverageAction
            headerAction
        } controls: {
            EmptyView()
        } content: {
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        overview(presentation)
                        controls(presentation)
                        content(presentation)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if geometry.size.width >= 940, let image = GoldenLandingAsset.startup.image {
                        GoldenLandingArtwork(image: image)
                            .frame(width: min(360, geometry.size.width - 660))
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .onChange(of: presentation.visibleItems.map(\.id)) { _, ids in
            if let selectedItemID, !ids.contains(selectedItemID) {
                self.selectedItemID = nil
            }
        }
        .sheet(item: $inspectedItem) { item in
            StartupItemInspectorView(
                item: item,
                onEnable: presentation.allowsStartupMutationActions ? onEnable : nil,
                onDisable: presentation.allowsStartupMutationActions ? onDisable : nil,
                onStop: presentation.allowsStartupMutationActions ? onStop : nil,
                onReveal: onReveal,
                onOpenParentApplication: onOpenParentApplication,
                onCopyText: onCopyText,
                onOpenSystemSettings: presentation.allowsStartupMutationActions
                    ? onOpenSystemSettings
                    : nil
            )
        }
        .onChange(of: items.map(\.id)) { _, ids in
            let validIDs = Set(ids)
            guard let selectedItemID, !validIDs.contains(selectedItemID) else { return }
            self.selectedItemID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageCleanerFocusStartupItemsSearch)) { _ in
            isSearchFocused = true
        }
        .onKeyPress(.return) {
            guard !isSearchFocused,
                  let item = selectedItem(in: presentation) else { return .ignored }
            inspectedItem = item
            return .handled
        }
        .onKeyPress(.space) {
            guard !isSearchFocused,
                  let item = selectedItem(in: presentation) else { return .ignored }
            inspectedItem = item
            return .handled
        }
    }

    private var headerAction: some View {
        GlassToolbarButton(
            title: isLoading
                ? L10n.text("取消读取", "Cancel Reading")
                : L10n.text("刷新启动项", "Refresh Startup Items"),
            systemImage: isLoading ? "xmark" : AppSymbols.Action.refresh,
            isLoading: false
        ) {
            if isLoading {
                onCancel()
            } else {
                onRefresh()
            }
        }
        .help(isLoading
            ? L10n.text("取消当前读取", "Cancel the current read")
            : L10n.text("重新读取登录项与后台任务", "Reread login items and background tasks"))
    }

    private func overview(_ presentation: StartupItemsPresentation) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            if isLoading && !presentation.visibleItems.isEmpty {
                scanStatus
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppDesignTokens.Spacing.large) {
                    summaryMetrics(presentation)
                }

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), alignment: .leading),
                        count: 2
                    ),
                    alignment: .leading,
                    spacing: AppDesignTokens.Spacing.small
                ) {
                    summaryMetrics(presentation)
                }
            }
        }
    }

    private var scanStatus: some View {
        RuntimeInlineStatus(
            title: progress?.title ?? L10n.text("正在扫描登录项", "Scanning Login Items"),
            detail: L10n.text("已发现 \(progress?.discoveredCount ?? items.count) 项", "\(progress?.discoveredCount ?? items.count) items found")
        )
    }

    @ViewBuilder
    private func summaryMetrics(_ presentation: StartupItemsPresentation) -> some View {
        startupMetric(
            title: L10n.text("全部项目", "All Items"),
            value: "\(presentation.summary.total)",
            systemImage: "square.stack.3d.up.fill",
            tint: theme.accent
        )
        startupMetric(
            title: L10n.text("登录时打开", "Open at Login"),
            value: "\(presentation.summary.openAtLogin)",
            systemImage: "person.crop.circle.badge.checkmark",
            tint: AppDesignTokens.Palette.information
        )
        startupMetric(
            title: L10n.text("后台任务", "Background Tasks"),
            value: "\(presentation.summary.background)",
            systemImage: "gearshape.2.fill",
            tint: AppDesignTokens.Palette.tertiary
        )
        startupMetric(
            title: L10n.text("可直接管理", "Directly Manageable"),
            value: "\(presentation.summary.manageable)",
            systemImage: "switch.2",
            tint: AppDesignTokens.Palette.success
        )
    }

    private func startupMetric(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(isLoading && items.isEmpty ? "—" : value)
                    .font(.system(size: 21, weight: .semibold))
                    .monospacedDigit()
                Text(title).font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func controls(_ presentation: StartupItemsPresentation) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppDesignTokens.Spacing.small) {
                    categoryControl(presentation)
                        .frame(width: 350)
                    searchControls
                        .frame(minWidth: 260)
                }
                .frame(minWidth: 620)

                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    categoryControl(presentation)
                        .frame(maxWidth: .infinity)
                    searchControls
                }
            }
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Picker(L10n.text("状态", "Status"), selection: $status) {
                    ForEach(StartupItemsStatusFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                Picker(L10n.text("来源", "Source"), selection: $source) {
                    ForEach(StartupItemsSourceFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                Picker(L10n.text("排序", "Sort"), selection: $sort) {
                    ForEach(StartupItemsSortOrder.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func categoryControl(_ presentation: StartupItemsPresentation) -> some View {
        GlassSegmentedControl(
            selection: primaryCategoryBinding,
            options: primaryCategories,
            title: { category in
                let count = isLoading && items.isEmpty ? "—" : String(presentation.count(for: category))
                return "\(category.title) \(count)"
            }
        )
        .accessibilityLabel(L10n.text("启动项分类", "Startup item category"))
    }

    private var searchControls: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            searchField
            advancedFiltersMenu
        }
    }

    private var searchField: some View {
        TaskSearchField(
            placeholder: L10n.text("搜索启动项", "Search startup items"),
            text: $query,
            tint: theme.accent,
            focus: $isSearchFocused
        )
        .accessibilityLabel(L10n.text("搜索启动项", "Search startup items"))
    }

    private var advancedFiltersMenu: some View {
        Menu {
            Toggle(
                L10n.text("显示技术明细", "Show Technical Details"),
                isOn: $showsTechnicalDetails
            )

            if showsTechnicalDetails {
                Divider()
                Toggle(isOn: $includeAppleSystem) {
                    Label(
                        L10n.text("显示 Apple 系统项目", "Show Apple System Items"),
                        systemImage: "apple.logo"
                    )
                }
            }
        } label: {
            glassMenuIcon(systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .help(L10n.text(
            "显示技术明细与 Apple 系统项目",
            "Show technical details and Apple system items"
        ))
        .accessibilityLabel(L10n.text("筛选与显示", "Filter and Display"))
    }

    @ViewBuilder
    private func content(_ presentation: StartupItemsPresentation) -> some View {
        if presentation.visibleItems.isEmpty, !isLoading {
            AppEmptyState(
                title: query.trimmed.isEmpty
                    ? L10n.text("没有符合当前筛选条件的项目", "No Items Match These Filters")
                    : L10n.text("没有搜索结果", "No Search Results"),
                detail: query.trimmed.isEmpty
                    ? L10n.text(
                        "调整分类或筛选条件。",
                        "Choose another category or filter."
                    )
                    : L10n.text("尝试搜索应用名称、开发者或用途。", "Search by application, developer, or purpose."),
                systemImage: AppSymbols.Navigation.loginItems,
                density: .inline
            )
        } else if presentation.visibleItems.isEmpty {
            AppEmptyState(
                title: progress?.title ?? L10n.text("正在扫描启动项目", "Scanning Startup Items"),
                detail: L10n.text(
                    "已发现 \(progress?.discoveredCount ?? items.count) 个项目，正在补全状态与归属。",
                    "\(progress?.discoveredCount ?? items.count) items found; resolving state and attribution."
                ),
                systemImage: AppSymbols.Navigation.loginItems,
                density: .inline,
                isLoading: true
            )
        } else {
            VStack(spacing: 0) {
                HStack(spacing: AppDesignTokens.Spacing.medium) {
                    Text(L10n.text("名称", "Name"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.text("来源", "Source"))
                        .frame(width: 110, alignment: .leading)
                    Text(L10n.text("状态", "Status"))
                        .frame(width: 132, alignment: .leading)
                    Text(L10n.text("操作", "Actions"))
                        .frame(width: 90, alignment: .trailing)
                }
                .font(AppTypography.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider()
                List(selection: $selectedItemID) {
                    ForEach(presentation.visibleItems) { item in
                        StartupItemRow(
                            item: item,
                            isPending: activeOperationCandidateID.map { candidateID in
                                item.components.contains(where: { $0.id == candidateID })
                            } ?? false,
                            isPerformingOperation: isPerformingOperation || isLoading,
                            onEnable: presentation.allowsStartupMutationActions ? onEnable : nil,
                            onDisable: presentation.allowsStartupMutationActions ? onDisable : nil,
                            onStop: presentation.allowsStartupMutationActions ? onStop : nil,
                            onReveal: onReveal,
                            onOpenParentApplication: onOpenParentApplication,
                            onCopyText: onCopyText,
                            onOpenSystemSettings: presentation.allowsStartupMutationActions
                                ? onOpenSystemSettings
                                : nil,
                            onInspect: { inspectedItem = item }
                        )
                        .tag(item.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 52)
                .scrollContentBackground(.hidden)
                .listRowSeparatorTint(Color.primary.opacity(0.10))
                .accessibilityLabel(L10n.text("登录项与后台任务列表", "Login items and background tasks list"))

                Divider()
                HStack {
                    Text(L10n.text(
                        "显示 \(presentation.visibleItems.count) 项，共 \(presentation.summary.total) 项",
                        "Showing \(presentation.visibleItems.count) of \(presentation.summary.total) items"
                    ))
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if let item = selectedItem(in: presentation) {
                        Text(item.managementExplanation)
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func glassMenuIcon(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(AppTypography.toolbar)
            .foregroundStyle(theme.primaryText)
            .frame(
                width: AppControlSizes.iconHitRegion,
                height: AppControlSizes.iconHitRegion
            )
            .background(
                RoundedRectangle(cornerRadius: AppDesignTokens.Radius.glassControl, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppDesignTokens.Radius.glassControl, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }

    private func selectedItem(in presentation: StartupItemsPresentation) -> StartupItemsDomain.Item? {
        guard let selectedItemID else { return nil }
        return presentation.visibleItems.first { $0.id == selectedItemID }
    }

}

private struct StartupItemRow: View {
    let item: StartupItemsDomain.Item
    let isPending: Bool
    let isPerformingOperation: Bool
    let onEnable: ((StartupItemsDomain.Candidate) -> Void)?
    let onDisable: ((StartupItemsDomain.Candidate) -> Void)?
    let onStop: ((StartupItemsDomain.Candidate) -> Void)?
    let onReveal: ((StartupItemsDomain.Item) -> Void)?
    let onOpenParentApplication: ((StartupItemsDomain.Item) -> Void)?
    let onCopyText: ((String) -> Void)?
    let onOpenSystemSettings: (() -> Void)?
    let onInspect: () -> Void

    private var directCandidate: StartupItemsDomain.Candidate? {
        startupActionCandidate(in: item, onEnable: onEnable, onDisable: onDisable)
    }

    private var isEnabled: Bool {
        guard let directCandidate else { return false }
        return directCandidate.state.enablement != .disabled
            && directCandidate.state.enablement != .temporarilyStopped
    }

    private var canReveal: Bool {
        onReveal != nil && item.components.contains { $0.actionCapability.canRevealInFinder }
    }

    private var canOpenParentApplication: Bool {
        onOpenParentApplication != nil
            && item.actionCapability.canOpenParentApp
            && item.components.contains { $0.actionCapability.canOpenParentApp }
    }

    private var canOpenSystemSettings: Bool {
        onOpenSystemSettings != nil && item.isSystemSettingsOnly
    }

    var body: some View {
        HStack(spacing: AppDesignTokens.Spacing.medium) {
            CachedAppIconView(path: item.applicationIconPath ?? "", size: 34) {
                AppSymbolIcon(
                    systemImage: item.fallbackSystemImage,
                    role: .inline,
                    tint: AppDesignTokens.Palette.secondaryText,
                    isDecorative: true
                )
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(AppTypography.body.weight(.semibold))
                    .lineLimit(1)
                    .help(item.displayName)
                Text(compactPurpose(item.resolvedPurpose.value))
                    .font(AppTypography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(item.resolvedPurpose.value)
            }

            Spacer(minLength: AppDesignTokens.Spacing.medium)

            Text(Array(Set(item.components.map { $0.source.title })).sorted().joined(separator: " / "))
                .font(AppTypography.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            StartupItemStatusLabel(item: item)
                .frame(width: 132, alignment: .leading)

            HStack(spacing: 6) {
                if isPending && isPerformingOperation {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20)
                        .accessibilityLabel(L10n.text("正在验证启动项操作", "Verifying startup item operation"))
                } else if directCandidate != nil {
                    Toggle(
                        L10n.text("允许以后启动", "Allow future launches"),
                        isOn: enablementBinding
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(isPending || isPerformingOperation)
                    .help(toggleHelp)
                    .accessibilityLabel(L10n.text("允许以后启动", "Allow future launches"))
                    .accessibilityValue(item.displayStatus)
                    .frame(width: 42)
                } else if canOpenSystemSettings {
                    AppIconButton(
                        title: L10n.text("在系统设置中管理", "Manage in System Settings"),
                        systemImage: "gearshape",
                        kind: .toolbar
                    ) {
                        onOpenSystemSettings?()
                    }
                }

                Menu {
                    Button(L10n.text("查看详情", "Show Details"), action: onInspect)

                    if canReveal {
                        Button(L10n.text("在 Finder 中显示", "Reveal in Finder")) {
                            onReveal?(item)
                        }
                    }

                    if let onCopyText,
                       let label = item.components.compactMap(\.label).first?.trimmed.nonEmpty {
                        Button(L10n.text("复制 Label", "Copy Label")) {
                            onCopyText(label)
                        }
                    }
                    if let onCopyText,
                       let path = item.components.compactMap({ $0.plistURL?.path ?? $0.executableURL?.path }).first {
                        Button(L10n.text("复制路径", "Copy Path")) {
                            onCopyText(path)
                        }
                    }

                    Divider()

                    if canOpenParentApplication {
                        Button(L10n.text("打开父应用", "Open Parent App")) {
                            onOpenParentApplication?(item)
                        }
                    }
                    if let candidate = directCandidate,
                       candidate.actionCapability.canStopCurrentSession,
                       onStop != nil {
                        Button(L10n.text("停止当前进程", "Stop Current Process")) {
                            onStop?(candidate)
                        }
                        .disabled(isPending || isPerformingOperation)
                    }
                    if canOpenSystemSettings {
                        Button(L10n.text("在系统设置中管理", "Manage in System Settings")) {
                            onOpenSystemSettings?()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: AppControlSizes.iconHitRegion, height: AppControlSizes.iconHitRegion)
                }
                .menuStyle(.borderlessButton)
                .help(L10n.text("更多操作", "More Actions"))
                .accessibilityLabel(L10n.text("更多操作", "More Actions"))
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onInspect)
        .accessibilityElement(children: .contain)
    }

    private var toggleHelp: String {
        L10n.text(
            "停用时，已载入或正在运行的进程会立即停止，并阻止以后载入；启用时可能立即重新载入。",
            "Disabling immediately stops a loaded or running process and prevents future loads; enabling may load it immediately."
        )
    }

    private var enablementBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { shouldEnable in
                requestEnablement(shouldEnable)
            }
        )
    }

    private func requestEnablement(_ shouldEnable: Bool) {
        guard let directCandidate else { return }
        if shouldEnable {
            onEnable?(directCandidate)
        } else {
            onDisable?(directCandidate)
        }
    }

    private func compactPurpose(_ value: String) -> String {
        let withSeparator = L10n.text("；具体用途尚未确认", "; specific purpose is not yet confirmed")
        let standalone = L10n.text("具体用途尚未确认", "Specific purpose is not yet confirmed")
        var compact = value
        compact = compact.replacingOccurrences(of: withSeparator, with: "")
        compact = compact.replacingOccurrences(of: standalone, with: "")
        let trimmed = compact.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? L10n.text("用途未确认", "Purpose unknown")
            : trimmed
    }
}

private struct StartupItemStatusLabel: View {
    let item: StartupItemsDomain.Item

    var body: some View {
        MetadataPill(
            text: shortStatus,
            systemImage: statusSymbol,
            tint: statusTint
        )
        .help(statusHelp)
        .accessibilityLabel(item.displayStatus)
    }

    private var shortStatus: String {
        item.displayStatus.split(separator: "·", maxSplits: 1).first
            .map { String($0).trimmed } ?? item.displayStatus
    }

    private var statusSymbol: String {
        if item.requiresAdministrator { return "lock.fill" }
        if item.hasConfigurationIssue { return "exclamationmark.triangle.fill" }
        if item.isSystemSettingsOnly { return "gearshape" }
        if item.isReadOnly { return "lock" }
        switch item.state.process {
        case .running: return "play.circle.fill"
        case .waiting: return "clock.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return item.state.enablement == .disabled
            ? "pause.circle.fill"
            : "stop.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusTint: Color {
        if item.requiresAdministrator || item.hasConfigurationIssue {
            return AppDesignTokens.Palette.warning
        }
        if item.isSystemSettingsOnly || item.isReadOnly {
            return AppDesignTokens.Palette.secondaryText
        }
        switch item.state.process {
        case .running: return AppDesignTokens.Palette.success
        case .waiting: return AppDesignTokens.Palette.information
        case .failed: return AppDesignTokens.Palette.warning
        case .stopped, .unknown: return AppDesignTokens.Palette.secondaryText
        }
    }

    private var statusHelp: String {
        if item.requiresAdministrator {
            return L10n.text("需要管理员权限", "Administrator Permission Required")
        }
        if item.isSystemSettingsOnly {
            return L10n.text("在系统设置中管理", "Manage in System Settings")
        }
        if item.isReadOnly {
            return L10n.text("只读系统项目", "Read-only System Item")
        }
        return item.displayStatus
    }
}

func startupActionCandidate(
    in item: StartupItemsDomain.Item,
    onEnable: ((StartupItemsDomain.Candidate) -> Void)?,
    onDisable: ((StartupItemsDomain.Candidate) -> Void)?,
    includesAdministratorRequests: Bool = false
) -> StartupItemsDomain.Candidate? {
    let candidates = startupActionCandidates(
        in: item,
        onEnable: onEnable,
        onDisable: onDisable,
        includesAdministratorRequests: includesAdministratorRequests
    )
    return candidates.count == 1 ? candidates[0] : nil
}

func startupActionCandidates(
    in item: StartupItemsDomain.Item,
    onEnable: ((StartupItemsDomain.Candidate) -> Void)?,
    onDisable: ((StartupItemsDomain.Candidate) -> Void)?,
    includesAdministratorRequests: Bool = false
) -> [StartupItemsDomain.Candidate] {
    item.components.filter { candidate in
        let isDirectlyManageable = candidate.state.management == .directlyManageable
        let isAdministratorRequest = includesAdministratorRequests
            && candidate.state.management == .requiresAdministrator
            && candidate.actionCapability.requiresAdministrator
        guard isDirectlyManageable || isAdministratorRequest else { return false }
        switch candidate.state.enablement {
        case .disabled, .temporarilyStopped:
            return candidate.actionCapability.canEnableDirectly && onEnable != nil
        case .enabled:
            return candidate.actionCapability.canDisableDirectly && onDisable != nil
        case .unknown:
            return false
        }
    }
}
