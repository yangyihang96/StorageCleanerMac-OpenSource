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
    @Environment(\.colorScheme) private var scheme
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
    var onUndo: (() -> Void)?

    @State private var query = ""
    @State private var showsSearch = false
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
        onOpenSystemSettings: (() -> Void)? = nil,
        onUndo: (() -> Void)? = nil
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
        self.onUndo = onUndo
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

        FeatureLightfieldPage(module: .startup, phase: .result,
            title: L10n.text("登录项与后台任务", "Login Items & Background Tasks"),
            status: isLoading && items.isEmpty ? (progress?.title ?? L10n.text("正在读取启动项", "Reading Startup Items"))
                : L10n.text("已读取 \(presentation.summary.total) 项 · 可直接管理 \(presentation.summary.manageable) 项",
                    "\(presentation.summary.total) read · \(presentation.summary.manageable) directly manageable"),
            safety: L10n.text("受保护项目仅查看 · 管理前核对来源", "Protected items are read-only · Verify sources before changes"),
            actionTitle: isLoading ? L10n.text("取消读取", "Cancel Reading") : L10n.text("重新检查登录项", "Check Login Items Again"),
            actionEnabled: !isPerformingOperation, showsArtwork: false,
            action: { if isLoading { onCancel() } else { onRefresh() } }) {
            ScrollViewReader { scroll in
                LightfieldResultContent(listHeader: AnyView(tableHeader(presentation))) {
                    LightfieldSummary(module: .startup, label: L10n.text("已读取的登录项与后台任务", "Login items and background tasks read"),
                        value: isLoading && items.isEmpty ? "—" : "\(presentation.summary.total)", unit: L10n.text("项", "items"),
                        note: L10n.text("· \(presentation.summary.manageable) 项可直接管理", "· \(presentation.summary.manageable) directly manageable"))
                } rows: {
                    ForEach(presentation.visibleItems) { item in
                        StartupItemRow(item: item,
                            isPending: activeOperationCandidateID.map { candidateID in
                                item.components.contains(where: { $0.id == candidateID })
                            } ?? false,
                            isPerformingOperation: isPerformingOperation || isLoading,
                            onEnable: presentation.allowsStartupMutationActions ? onEnable : nil,
                            onDisable: presentation.allowsStartupMutationActions ? onDisable : nil,
                            onStop: presentation.allowsStartupMutationActions ? onStop : nil,
                            onReveal: onReveal, onOpenParentApplication: onOpenParentApplication, onCopyText: onCopyText,
                            onOpenSystemSettings: presentation.allowsStartupMutationActions ? onOpenSystemSettings : nil,
                            onInspect: { inspectedItem = item })
                            .background(selectedItemID == item.id ? FeatureLightfieldPalette.resolve(scheme).hoverColor : .clear)
                            .onTapGesture { selectedItemID = item.id }
                            .id(item.id)
                            .lightfieldResultRowBoundary()
                            .lightfieldComponentProbe("startup.row." + item.id)
                    }
                }
                .onChange(of: selectedItemID) { _, id in
                    if let id { scroll.scrollTo(id) }
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
            showsSearch = true
            isSearchFocused = true
        }
        .focusable()
        .onKeyPress(.downArrow) {
            guard !isSearchFocused else { return .ignored }
            moveSelection(1, in: presentation); return .handled
        }
        .onKeyPress(.upArrow) {
            guard !isSearchFocused else { return .ignored }
            moveSelection(-1, in: presentation); return .handled
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

    private func tableHeader(_ presentation: StartupItemsPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
                    resultControls(presentation)
                    if showsSearch || !query.isEmpty { searchField.padding(.vertical, 8) }
                    FeatureLightfieldHairline()
                    if presentation.visibleItems.isEmpty {
                        Text(isLoading ? (progress?.title ?? L10n.text("正在读取启动项", "Reading Startup Items"))
                            : L10n.text("没有符合当前筛选条件的项目", "No Items Match These Filters"))
                            .font(.system(size: 15)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    }
        }
    }

    private var categoryIndex: Binding<Int> {
        Binding(get: { primaryCategories.firstIndex(of: effectiveCategory) ?? 0 },
            set: { category = primaryCategories[min(max(0, $0), primaryCategories.count - 1)] })
    }

    private func resultControls(_ presentation: StartupItemsPresentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                categoryControl
                Spacer(minLength: 0)
                Text(L10n.text("\(presentation.visibleItems.count) / \(presentation.summary.total) 项", "Showing \(presentation.visibleItems.count) of \(presentation.summary.total)"))
                    .font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                    .lineLimit(1)
                advancedFiltersMenu
                coverageAction
                if let onUndo {
                    Button(L10n.text("撤销", "Undo"), action: onUndo).buttonStyle(FeatureLightfieldRowButtonStyle())
                        .disabled(isPerformingOperation || isLoading)
                }
            }.frame(minWidth: 560)
            VStack(alignment: .leading, spacing: 8) {
                categoryControl
                HStack {
                    advancedFiltersMenu; coverageAction
                    if let onUndo {
                        Button(L10n.text("撤销", "Undo"), action: onUndo).buttonStyle(FeatureLightfieldRowButtonStyle())
                            .disabled(isPerformingOperation || isLoading)
                    }
                }
            }
        }
    }

    private var categoryControl: some View {
        LightfieldTextSegments(titles: primaryCategories.map(\.title), selection: categoryIndex, module: .startup)
            .accessibilityLabel(L10n.text("启动项分类", "Startup item category"))
    }

    private var searchField: some View {
        TextField(L10n.text("搜索启动项", "Search startup items"), text: $query)
            .textFieldStyle(.plain).font(.system(size: 15))
            .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
            .focused($isSearchFocused)
            .accessibilityLabel(L10n.text("搜索启动项", "Search startup items"))
    }

    private var advancedFiltersMenu: some View {
        Menu {
            Toggle(L10n.text("显示搜索", "Show Search"), isOn: $showsSearch)
            Picker(L10n.text("状态", "Status"), selection: $status) {
                ForEach(StartupItemsStatusFilter.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.text("来源", "Source"), selection: $source) {
                ForEach(StartupItemsSourceFilter.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.text("排序", "Sort"), selection: $sort) {
                ForEach(StartupItemsSortOrder.allCases) { Text($0.title).tag($0) }
            }
            Toggle(L10n.text("显示技术明细", "Show Technical Details"), isOn: $showsTechnicalDetails)
            if showsTechnicalDetails {
                Toggle(L10n.text("显示 Apple 系统项目", "Show Apple System Items"), isOn: $includeAppleSystem)
            }
        } label: { Text(L10n.text("筛选", "Filters")).font(.system(size: 13)) }
        .menuStyle(.borderlessButton)
        .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
        .accessibilityLabel(L10n.text("筛选与显示", "Filter and Display"))

    }

    private func moveSelection(_ direction: Int, in presentation: StartupItemsPresentation) {
        let ids = presentation.visibleItems.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selectedItemID.flatMap { ids.firstIndex(of: $0) }
        selectedItemID = ids[min(ids.count - 1, max(0, (current ?? (direction > 0 ? -1 : ids.count)) + direction))]
    }

    private func selectedItem(in presentation: StartupItemsPresentation) -> StartupItemsDomain.Item? {
        guard let selectedItemID else { return nil }
        return presentation.visibleItems.first { $0.id == selectedItemID }
    }

}

struct StartupItemRow: View {
    @Environment(\.colorScheme) private var scheme
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                identity
                StartupItemStatusLabel(item: item).frame(width: 150, alignment: .leading)
                actions.frame(width: 130, alignment: .trailing)
            }.frame(minWidth: 650, minHeight: 52)
            HStack(spacing: 12) {
                identity
                VStack(alignment: .trailing, spacing: 4) {
                    StartupItemStatusLabel(item: item)
                    actions
                }.frame(width: 144)
            }.frame(minHeight: 76)
        }
        .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onInspect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(item.displayStatus)
        .accessibilityAction { onInspect() }
    }

    private var identity: some View {
        HStack(spacing: 16) {
            LightfieldAppIcon(path: item.applicationIconPath, size: .medium)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.system(size: 15, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(item.displayName)
                    .lightfieldComponentProbe("startup.name." + item.id)
                Text(compactPurpose(item.resolvedPurpose.value))
                    .font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                    .lineLimit(1).truncationMode(.middle).help(item.resolvedPurpose.value)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
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
                    .accessibilityLabel(L10n.text("允许以后启动 · \(item.displayName)", "Allow future launches · \(item.displayName)"))
                    // A native switch insists on numeric AXValue. Publish the
                    // management status and the same gated action to VoiceOver.
                    .accessibilityRepresentation {
                        Button(L10n.text("允许以后启动 · \(item.displayName)", "Allow future launches · \(item.displayName)")) {
                            requestEnablement(!isEnabled)
                        }
                        .disabled(isPending || isPerformingOperation)
                        .accessibilityValue(item.displayStatus)
                        .accessibilityHint(toggleHelp)
                    }
                    .frame(width: 42)
                } else if canOpenSystemSettings {
                    Button(L10n.text("仅系统设置", "System Settings")) {
                        onOpenSystemSettings?()
                    }.buttonStyle(FeatureLightfieldRowButtonStyle())
                        .font(.system(size: 13)).lineLimit(1)
                        .help(L10n.text("在系统设置中管理", "Manage in System Settings"))
                } else {
                    Text(L10n.text("仅查看", "Read-only")).font(.system(size: 13))
                        .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
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
                    Text(L10n.text("更多", "More")).font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .help(L10n.text("更多操作", "More Actions"))
                .accessibilityLabel(L10n.text("更多操作", "More Actions"))
            }
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
    @Environment(\.colorScheme) private var scheme
    let item: StartupItemsDomain.Item

    var body: some View {
        HStack(spacing: 10) {
            LightfieldStatusGlyph(status: item.metadataPillStatus, symbol: statusSymbol, color: statusTint)
            Text(shortStatus).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
        }.foregroundStyle(statusTint)
        .accessibilityElement(children: .ignore)
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
        let palette = FeatureLightfieldPalette.resolve(scheme)
        if item.requiresAdministrator || item.hasConfigurationIssue { return palette.warningColor }
        if item.isSystemSettingsOnly || item.isReadOnly { return palette.fg3 }
        switch item.state.process {
        case .running: return FeatureLightfieldStatus.normal.color(palette)
        case .failed: return palette.warningColor
        case .waiting, .stopped, .unknown: return palette.fg3
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
