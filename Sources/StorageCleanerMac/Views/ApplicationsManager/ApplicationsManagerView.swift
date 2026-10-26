import AppKit
import SwiftUI

/// The uninstall page after the inventory scan: CleanMyMac's Applications
/// data manager (result tiles, categories, every related item selected with
/// its app, the running-app step, removal with receipts, completion and log)
/// inside this app's D67 result skeleton: summary, toolbar, the approved
/// column header and lazily laid-out rows in the shared results viewport.
/// CleanMyMac's sidebar is the toolbar's category menu here. Every action goes
/// through `ApplicationsManagerModel`; this view never quits apps or moves
/// files itself.
struct ApplicationsManagerView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var model: ApplicationsManagerModel
    @ObservedObject private var reminders = AppLifecycleReminderCenter.shared
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
#endif
    @Environment(\.colorScheme) private var scheme
    @State private var showsLog = false
    @State private var showsHistory = false

    init(store: ScanStore) {
        self.store = store
        model = ApplicationsManagerModel.of(store)
    }

    private var palette: FeatureLightfieldPalette { FeatureLightfieldPalette.resolve(scheme) }

    /// Inert presentation fixtures list the inventory without reading disks.
    private var readsDisk: Bool {
#if DEBUG
        !isFixture
#else
        true
#endif
    }

    var body: some View {
        // D154: CleanMyMac's Applications pages on the module gradient —
        // result tiles, the light Applications Manager, removing, done.
        Group {
            switch model.phase {
            case .finished:
                CareStudioApplicationsCompletion(model: model, showLog: { showsLog = true })
            case .removing(let current, let index, let total):
                CareStudioApplicationsRemoving(current: current, index: index, total: total,
                                               leftovers: model.category == .leftovers || model.category == .installers)
            default:
                if model.showsOverview {
                    CareStudioApplicationsOverview(model: model, store: store, showHistory: { showsHistory = true })
                } else {
                    manager
                }
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .onAppear {
            model.load(inventory: manageableApps, readsDisk: readsDisk)
            takeTrashedApplications(reminders.pendingTrashedUninstall)
            // A Finder request can arrive before this page is on screen.
            takeFinderRequest()
        }
        .onChange(of: store.installedApps.map(\.id)) { _, _ in model.load(inventory: manageableApps, readsDisk: readsDisk) }
        .onReceive(reminders.$pendingTrashedUninstall) { takeTrashedApplications($0) }
        .onChange(of: store.pendingUninstallApp?.id) { _, _ in takeFinderRequest() }
        .sheet(isPresented: terminatorBinding) { ApplicationTerminatorSheet(model: model) }
        .sheet(isPresented: $showsLog) { ApplicationsLogSheet(outcomes: model.outcomes) }
        .sheet(isPresented: $showsHistory) {
            ReversibleOperationsView(store: store, resumeUninstall: { store.prepareResidualUninstall($0) })
        }
        .sheet(isPresented: residualReviewBinding) {
            if let app = store.pendingUninstallApp { UninstallPreviewSheet(store: store, app: app) }
        }
        .alert(L10n.text("卸载存储清理助手？", "Uninstall Storage Cleaner?"),
               isPresented: selfRemovalBinding) {
            Button(L10n.text("不卸载", "Don't Uninstall"), role: .cancel) { model.confirmSelfRemoval(false) }
            Button(L10n.text("卸载", "Uninstall"), role: .destructive) { model.confirmSelfRemoval(true) }
        } message: {
            // D154: our own wording (D123/D141 keep CleanMyMac's sentences out).
            Text(L10n.text("你正在用的就是存储清理助手。卸载会先退出它，再把它和它的文件移到废纸篓。",
                           "This is the app you are using. Uninstalling quits it first, then moves it and its files to the Trash."))
        }
    }

    /// The one eligibility rule the uninstall page has always used: apps this
    /// app can move to the Trash (in Applications or the home folder).
    private var manageableApps: [InstalledAppItem] {
        store.installedApps.filter(\.canMoveToTrash)
    }

    private var statusText: String {
        let summary = model.selectionSummary
        if summary.applications + summary.items > 0 {
            return model.footerTitle + " · " + ByteFormat.storageString(summary.bytes)
        }
        let base = model.category == .otherLocations
            ? L10n.text("找到 \(ByteFormat.count(model.otherApplications.groups.count)) 组其他位置的应用",
                        "\(ByteFormat.count(model.otherApplications.groups.count)) application groups in other locations")
            : L10n.text("找到 \(ByteFormat.count(model.entries.count)) 个应用", "\(ByteFormat.count(model.entries.count)) apps found")
        let ignored = model.category == .otherLocations ? model.otherApplications.ignoredCount : model.ignoredTotal
        let detail = IgnoreListSnapshot.appendingSummary(ignored, to: base)
        return model.isLoadingResources ? detail + L10n.text(" · 正在读取关联文件", " · Reading related files") : detail
    }

    // MARK: Hand-offs

    private func takeTrashedApplications(_ apps: [TrashedApplication]) {
        guard !apps.isEmpty else { return }
        reminders.pendingTrashedUninstall = []
        model.beginTrashedApplications(apps)
    }

    /// Finder's “Uninstall with …” lands as a single-app request: the app is
    /// selected with everything it found (CleanMyMac `UninstallAppFlowCoordinator`).
    /// Resuming from Operation History keeps its own review sheet.
    private func takeFinderRequest() {
        guard let app = store.pendingUninstallApp, store.residualUninstallReport == nil else { return }
        store.cancelUninstall()
        guard let entry = model.entries.first(where: { $0.item.path == app.path }) else { return }
        model.showsOverview = false
        model.category = .all
        model.searchText = ""
        if model.selectionState(of: entry) != .all { model.toggle(entry) }
        model.expanded.insert(entry.id)
    }

    private var terminatorBinding: Binding<Bool> {
        Binding(get: { model.phase == .terminating }, set: { shown in if !shown { model.cancelTermination() } })
    }

    private var selfRemovalBinding: Binding<Bool> {
        Binding(get: { model.phase == .confirmingSelfRemoval }, set: { shown in if !shown { model.confirmSelfRemoval(false) } })
    }

    private var residualReviewBinding: Binding<Bool> {
        Binding(get: { store.pendingUninstallApp != nil && store.residualUninstallReport != nil },
                set: { shown in if !shown && !store.isUninstallingApp { store.cancelUninstall() } })
    }

    // MARK: Manager

    /// CleanMyMac's Applications Manager: categories on the left, the apps
    /// (or leftovers, installers, plug-ins) with the approved column header,
    /// and the footer that counts the selection beside the one action.
    private var manager: some View {
        // The visible list is filtered and sorted once per render.
        let entries = model.visibleEntries
        return CareStudioManagerChrome(
            module: .applications,
            title: L10n.text("应用管理器", "Applications Manager"),
            query: $model.searchText,
            searchPrompt: L10n.text("搜索应用名称或标识", "Search App Name or Identifier"),
            sortTitle: model.sortMode.title,
            sortOptions: ApplicationSortMode.allCases.map { (id: $0.id, title: $0.title) },
            onSort: { id in model.sortMode = ApplicationSortMode(rawValue: id) ?? model.sortMode },
            categoryWidth: 220,
            selectionSummary: statusText,
            primaryTitle: model.primaryActionTitle,
            primaryEnabled: model.phase == .browsing && model.hasSelection && !store.isUninstallingApp,
            onPrimary: { model.requestRemoval() },
            onBack: { model.showsOverview = true },
            categories: { categoryColumn },
            content: { managerList(entries) },
            footerDetail: { managerFooterDetail })
    }

    /// CleanMyMac's sidebar groups, in its order, with each category's count;
    /// stores and vendors are listed when they have apps.
    private var categoryColumn: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                categoryRow(.all)
                categoryRow(.unused)
                categoryRow(.suspicious)
                categoryRow(.selected)
                categorySection(L10n.text("商店", "Stores"), ApplicationStore.allCases.map { .store($0) })
                categorySection(L10n.text("提供商", "Vendors"), ApplicationVendor.allCases.map { .vendor($0) })
                categorySection(L10n.text("插件", "Plugins"), [.audioPlugins], keepsEmpty: true)
                categorySection(L10n.text("其他", "Other"), [.otherLocations, .thirtyTwoBit, .leftovers, .installers], keepsEmpty: true)
            }
            .padding(10)
        }
#if DEBUG
        .layoutProbe("careStudio.manager.applications.categories")
#endif
    }

    @ViewBuilder
    private func categorySection(_ title: String, _ categories: [ApplicationCategory], keepsEmpty: Bool = false) -> some View {
        let shown = keepsEmpty ? categories : categories.filter { model.count(in: $0) > 0 || model.category == $0 }
        if !shown.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(shown) { categoryRow($0) }
        }
    }

    private func categoryRow(_ category: ApplicationCategory) -> some View {
        CareStudioManagerCategoryRow(module: .applications, title: category.title, systemImage: category.studioSymbol,
                                     detail: "\(model.count(in: category))", isSelected: model.category == category,
                                     art: category.studioArt) {
            model.showsOverview = false
            model.category = category
        }
        .help(category.help)
    }

    private func managerList(_ entries: [ApplicationEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.category.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(model.category.help)
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if !model.trashedApplications.isEmpty && model.category == .leftovers {
                trashedBanner.padding(.horizontal, 16)
            }
            // The column header stays above the list, as CleanMyMac's does;
            // the scroll document holds only the rows, so the lazy stack's
            // estimate for unseen rows is the rows' own height.
            LightfieldApplicationListHeader(kind: .uninstall)
                .padding(.horizontal, 12)
            ScrollView(.vertical) {
                rows(entries)
#if DEBUG
                    .layoutProbe("careStudio.manager.document")
#endif
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
#if DEBUG
            .layoutProbe("lightfield.results.scrollViewport")
#endif
        }
    }

    private var managerFooterDetail: some View {
        HStack(spacing: 10) {
            Menu(L10n.text("更多", "More")) {
                Button(L10n.text("重新扫描", "Rescan")) {
                    store.refreshInstalledApps()
                    if readsDisk {
                        model.scanLeftoversAndInstallers()
                        model.refreshOtherApplications()
                    }
                }
                .disabled(!store.canRefreshInstalledApps)
                Button(L10n.text("扫描结果概览", "Scan Results")) { model.showsOverview = true }
                Button(L10n.text("卸载记录", "Uninstall History")) { showsHistory = true }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(CareStudioManagerInk.accent)
            if model.isLoadingResources || model.isScanningLeftovers || model.isScanningOtherApplications {
                ProgressView().controlSize(.small)
                    .help(L10n.text("正在读取关联文件", "Reading related files"))
            }
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private var trashedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash").foregroundStyle(palette.fg3)
            Text(L10n.text("这些应用已在废纸篓中，下面是它们留下的文件，确认后一并移入废纸篓。",
                           "These apps are already in the Trash; below is what they left behind, moved to the Trash on confirmation."))
                .font(.system(size: 12))
                .foregroundStyle(palette.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rows(_ entries: [ApplicationEntry]) -> some View {
        switch model.category {
        case .otherLocations:
            if model.visibleOtherApplications.isEmpty { emptyState } else {
                otherApplicationRows(model.visibleOtherApplications)
            }
        case .leftovers:
            if model.leftovers.isEmpty { emptyState } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.leftovers.enumerated()), id: \.element.id) { index, group in
                        LeftoverGroupRow(model: model, group: group, index: index)
                    }
                }
            }
        case .installers:
            if model.installers.isEmpty { emptyState } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.installers.enumerated()), id: \.element.id) { index, file in
                        InstallerFileRow(file: file, index: index, selection: $model.installerSelection)
                    }
                }
            }
        case .audioPlugins:
            if model.audioPlugins.isEmpty { emptyState } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.audioPlugins.enumerated()), id: \.element.id) { index, file in
                        InstallerFileRow(file: file, index: index, selection: $model.pluginSelection)
                    }
                }
            }
        default:
            if entries.isEmpty {
                if model.category != .selected || !model.visibleOtherApplications.contains(where: {
                    $0.copies.contains { model.otherApplicationSelection.contains($0.path) }
                }) { emptyState }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        ApplicationEntryRows(model: model, entry: entry, index: index,
                            copyPath: { store.copyPath($0.path) }, reveal: { store.reveal($0.path) })
                    }
                }
                .disabled(store.isUninstallingApp || store.isRestoringRecordedOperation)
            }
            if model.category == .selected {
                otherApplicationRows(model.visibleOtherApplications.filter {
                    $0.copies.contains { model.otherApplicationSelection.contains($0.path) }
                })
            }
        }
    }

    private func otherApplicationRows(_ groups: [OtherApplicationGroup]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                OtherApplicationGroupRows(model: model, group: group, index: index,
                    copyPath: { store.copyPath($0) }, reveal: { store.reveal($0) })
            }
        }
        .disabled(store.isUninstallingApp || store.isRestoringRecordedOperation)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.category == .otherLocations {
                CareStudioManagerEmptyState(title: model.isScanningOtherApplications
                    ? L10n.text("正在查找其他位置的应用…", "Looking for applications in other locations…")
                    : model.otherApplications.unavailableReason ?? model.category.emptyDescription)
            } else if model.isScanningLeftovers && (model.category == .leftovers || model.category == .installers) {
                Text(L10n.text("正在查找残留…", "Looking for leftovers…"))
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.text("后台仍在查找以前卸载的应用留下的文件，找到后会列在这里。",
                               "Files left by apps uninstalled earlier are still being looked for; they appear here when found."))
                    .font(.system(size: 12)).foregroundStyle(palette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // D166: nothing suspicious is an all-clear; other empty
                // categories show the empty box.
                CareStudioManagerEmptyState(art: model.category == .suspicious ? .stateAllClear : .stateEmpty,
                                            title: model.category.emptyDescription)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
    }
}

// MARK: - Rows

/// The disclosure at a row's trailing edge; the row's size column keeps
/// room for it, so the two never overlap.
private struct RowDisclosure: View {
    let expanded: Bool
    let name: String
    let toggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeatureLightfieldRowButtonStyle())
        .accessibilityLabel(expanded ? L10n.text("收起 \(name) 的相关项目", "Collapse \(name)'s items")
                                     : L10n.text("展开 \(name) 的相关项目", "Expand \(name)'s items"))
        .help(expanded ? L10n.text("收起相关项目", "Hide related items") : L10n.text("显示相关项目", "Show related items"))
    }
}

private struct ApplicationEntryRows: View {
    @ObservedObject var model: ApplicationsManagerModel
    let entry: ApplicationEntry
    let index: Int
    let copyPath: (InstalledAppItem) -> Void
    let reveal: (InstalledAppItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ignoreListFeedback) private var ignoreListFeedback

    private var probe: String { "lightfield.uninstall.item.\(index)" }
    private var state: ApplicationsManagerModel.SelectionState { model.selectionState(of: entry) }
    private var isExpanded: Bool { model.expanded.contains(entry.id) }
    private var size: String { ByteFormat.storageString(entry.totalBytes) }

    private var stateText: String {
        switch state {
        case .all: L10n.text("已选择", "Selected")
        case .partial: L10n.text("部分选择", "Partially selected")
        case .none: L10n.text("未选择", "Not selected")
        }
    }

    private var lastOpenedText: String {
        guard let date = entry.item.lastUsedAt else { return L10n.text("从未打开", "Never opened") }
        return L10n.text("上次打开 ", "Last opened ") + date.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { model.toggle(entry) } label: {
                LightfieldListRow(kind: .uninstall, probeID: probe) {
                    HStack(spacing: 16) {
                        FeatureLightfieldCheck(selected: state == .all, module: .uninstall, mixed: state == .partial)
                        LightfieldAppIcon(path: entry.item.path, size: .medium)
                            .lightfieldComponentProbe(probe + ".icon")
                    }
                } name: {
                    LightfieldApplicationName(title: entry.item.name, version: entry.item.versionDisplay, probeID: probe)
                } detail: {
                    LightfieldPathText(path: entry.item.path)
                        .lightfieldComponentProbe(probe + ".path")
                } trailing: {
                    HStack(spacing: 4) {
                        Text(size).font(.system(size: 15)).monospacedDigit()
                            .lineLimit(1).truncationMode(.middle).help(size)
                            .lightfieldComponentProbe("lightfield.value." + entry.item.name)
                        Color.clear.frame(width: 20, height: 20)
                    }
                }
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .accessibilityLabel(entry.item.name + " · " + entry.item.path + " · " + size)
            .accessibilityValue(stateText)
            .accessibilityHint(L10n.text("版本 \(entry.item.versionDisplay) · \(lastOpenedText) · 按下勾选或取消它和找到的全部项目",
                                         "Version \(entry.item.versionDisplay) · \(lastOpenedText) · Press to select it with everything found, or clear it"))
            .overlay(alignment: .trailing) {
                RowDisclosure(expanded: isExpanded, name: entry.item.name, toggle: toggleExpansion)
                    .padding(.trailing, 6)
                    .disabled(entry.resources == nil)
            }
            .help(entry.classification.suspiciousReason ?? lastOpenedText)
            .contextMenu {
                Button(isExpanded ? L10n.text("收起相关项目", "Hide Related Items") : L10n.text("显示相关项目", "Show Related Items"),
                       action: toggleExpansion)
                    .disabled(entry.resources == nil)
                Button(L10n.text("复制路径", "Copy Path")) { copyPath(entry.item) }
                Button(L10n.text("在访达中显示", "Show in Finder")) { reveal(entry.item) }
                // D207 (CleanMyMac's Add to Ignore List): out of the uninstall and unused lists.
                if let ignoreListFeedback {
                    Button(IgnoreListMenu.title(count: 1)) { model.ignoreApplications([entry.id], feedback: ignoreListFeedback) }
                        .disabled(!model.canIgnore)
                }
            }
            .lightfieldRowEntrance(index)
            .lightfieldComponentProbe("lightfield.uninstall.row.\(index)")
            if isExpanded, let resources = entry.resources {
                ResourceGroupsList(resources: resources,
                                   isSelected: { model.isSelected($0, in: entry) },
                                   toggle: { model.toggle($0, in: entry) },
                                   toggleGroup: { model.toggle(group: $0, in: entry) })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .id(entry.id)
    }

    private func toggleExpansion() {
        withAnimation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.row, reduceMotion: reduceMotion)) {
            if isExpanded { model.expanded.remove(entry.id) } else { model.expanded.insert(entry.id) }
        }
    }
}

/// An app's items grouped as CleanMyMac groups them, each group and item
/// with its own checkbox, on the list's own columns.
private struct ResourceGroupsList: View {
    let resources: [ApplicationResource]
    let isSelected: (ApplicationResource) -> Bool
    let toggle: (ApplicationResource) -> Void
    let toggleGroup: (ApplicationResourceGroup) -> Void
    /// D215: leftover files go on the ignore list one by one, as their group does.
    var ignore: ((ApplicationResource) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        VStack(spacing: 0) {
            ForEach(ApplicationResourceGroup.allCases) { group in
                let items = resources.filter { $0.group == group }
                if !items.isEmpty {
                    let removable = items.filter(\.isRemovable)
                    let selectedCount = removable.filter(isSelected).count
                    LightfieldApplicationColumns(kind: .uninstall, rowHeight: 32) {
                        FeatureLightfieldCheck(selected: !removable.isEmpty && selectedCount == removable.count,
                                               module: .uninstall,
                                               mixed: selectedCount > 0 && selectedCount < removable.count,
                                               accessibilityLabel: group.title,
                                               action: removable.isEmpty ? nil : { toggleGroup(group) })
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        HStack(spacing: 6) {
                            Image(systemName: group.systemImage).foregroundStyle(palette.fg3).frame(width: 16)
                            Text(group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(ByteFormat.count(items.count)).font(.system(size: 12)).foregroundStyle(palette.fg3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                        Text(ByteFormat.storageString(items.reduce(0) { $0 + $1.sizeBytes }))
                            .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(palette.fg2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 24)
                    }
                    ForEach(items) { resource in
                        ResourceRow(resource: resource, selected: isSelected(resource),
                                    toggle: { toggle(resource) },
                                    ignore: ignore.map { ignore in { ignore(resource) } })
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(palette.hoverColor)
        .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }
}

private struct ResourceRow: View {
    let resource: ApplicationResource
    let selected: Bool
    let toggle: () -> Void
    var ignore: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        LightfieldApplicationColumns(kind: .uninstall, rowHeight: 32) {
            FeatureLightfieldCheck(selected: selected, module: .uninstall,
                                   accessibilityLabel: resource.displayName,
                                   action: resource.isRemovable ? toggle : nil)
                .opacity(resource.isRemovable ? 1 : 0.45)
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 5) {
                Text(resource.displayName).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                if !resource.isRemovable {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(palette.fg3)
                }
                if resource.domain == .system {
                    Text(L10n.text("系统位置", "System"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.fg2)
                }
            }
            .padding(.leading, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(resource.note ?? resource.evidence.title)
            LightfieldPathText(path: resource.path)
            HStack(spacing: 4) {
                if case .dockTile = resource.kind {
                    Spacer(minLength: 0)
                } else {
                    Text(ByteFormat.storageString(resource.sizeBytes))
                        .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(palette.fg2).lineLimit(1)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resource.path)])
                    } label: {
                        Image(systemName: "magnifyingglass").frame(width: 20, height: 20)
                    }
                    .buttonStyle(FeatureLightfieldRowButtonStyle())
                    .help(L10n.text("在访达中显示", "Reveal in Finder"))
                    .accessibilityLabel(L10n.text("在访达中显示 \(resource.displayName)", "Reveal \(resource.displayName) in Finder"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // D215 (CleanMyMac's Add “X” to Ignore List on a single leftover).
        .contextMenu {
            if let ignore {
                Button(IgnoreListMenu.title(count: 1), action: ignore)
            }
        }
    }
}

private struct LeftoverGroupRow: View {
    @ObservedObject var model: ApplicationsManagerModel
    let group: LeftoverGroup
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ignoreListFeedback) private var ignoreListFeedback

    var body: some View {
        let ids = Set(group.resources.map(\.id))
        let selectedCount = ids.intersection(model.leftoverSelection).count
        let expanded = model.expanded.contains(group.id)
        let size = ByteFormat.storageString(group.totalBytes)
        let probe = "lightfield.uninstall.leftover.\(index)"
        VStack(spacing: 0) {
            Button {
                if selectedCount == ids.count { model.leftoverSelection.subtract(ids) } else { model.leftoverSelection.formUnion(ids) }
            } label: {
                LightfieldListRow(kind: .uninstall, probeID: probe) {
                    HStack(spacing: 16) {
                        FeatureLightfieldCheck(selected: selectedCount == ids.count, module: .uninstall,
                                               mixed: selectedCount > 0 && selectedCount < ids.count)
                        Image(systemName: "app.dashed").font(.system(size: 20))
                            .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                            .frame(width: 24, height: 24)
                    }
                } name: {
                    LightfieldApplicationName(title: group.displayName, version: group.bundleIdentifier, probeID: probe)
                } detail: {
                    Text(L10n.text("\(ByteFormat.count(group.resources.count)) 项残留", "\(ByteFormat.count(group.resources.count)) leftover items"))
                        .font(.system(size: 12.5)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } trailing: {
                    HStack(spacing: 4) {
                        Text(size).font(.system(size: 15)).monospacedDigit().lineLimit(1).help(size)
                        Color.clear.frame(width: 20, height: 20)
                    }
                }
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .accessibilityLabel(group.displayName + " · " + group.bundleIdentifier + " · " + size)
            .accessibilityValue(selectedCount == ids.count ? L10n.text("已选择", "Selected")
                                : (selectedCount == 0 ? L10n.text("未选择", "Not selected") : L10n.text("部分选择", "Partially selected")))
            .overlay(alignment: .trailing) {
                RowDisclosure(expanded: expanded, name: group.displayName) {
                    withAnimation(FeatureLightfieldMotion.animation(FeatureLightfieldMotion.row, reduceMotion: reduceMotion)) {
                        if expanded { model.expanded.remove(group.id) } else { model.expanded.insert(group.id) }
                    }
                }
                .padding(.trailing, 6)
            }
            // D207 (CleanMyMac's Ignore N Items): the leftovers by path, as the leftover scan reads them.
            .contextMenu {
                if let ignoreListFeedback {
                    Button(IgnoreListMenu.title(count: group.resources.count)) {
                        model.ignoreLeftovers(ids, feedback: ignoreListFeedback)
                    }
                    .disabled(!model.canIgnore)
                }
            }
            .lightfieldRowEntrance(index)
            if expanded {
                ResourceGroupsList(resources: group.resources,
                                   isSelected: { model.leftoverSelection.contains($0.id) },
                                   toggle: { resource in
                                       if model.leftoverSelection.contains(resource.id) { model.leftoverSelection.remove(resource.id) }
                                       else { model.leftoverSelection.insert(resource.id) }
                                   },
                                   toggleGroup: { kind in
                                       let groupIDs = Set(group.resources.filter { $0.group == kind }.map(\.id))
                                       if groupIDs.isSubset(of: model.leftoverSelection) { model.leftoverSelection.subtract(groupIDs) }
                                       else { model.leftoverSelection.formUnion(groupIDs) }
                                   },
                                   // D215: one file by its path; the rest of the group stays, and
                                   // a group whose last file goes leaves with it.
                                   ignore: ignoreListFeedback.flatMap { feedback in
                                       model.canIgnore ? { resource in model.ignoreLeftovers([resource.id], feedback: feedback) } : nil
                                   })
            }
        }
        .id(group.id)
    }
}

private struct InstallerFileRow: View {
    let file: InstallerFile
    let index: Int
    @Binding var selection: Set<String>

    var body: some View {
        let selected = selection.contains(file.id)
        let size = ByteFormat.storageString(file.resource.sizeBytes)
        let probe = "lightfield.uninstall.installer.\(index)"
        Button {
            guard file.resource.isRemovable else { return }
            if selected { selection.remove(file.id) } else { selection.insert(file.id) }
        } label: {
            LightfieldListRow(kind: .uninstall, probeID: probe) {
                HStack(spacing: 16) {
                    FeatureLightfieldCheck(selected: selected, module: .uninstall)
                    LightfieldAppIcon(path: file.resource.path, size: .medium)
                }
            } name: {
                LightfieldApplicationName(title: file.resource.displayName,
                                          version: file.matchedApplication.map { L10n.text("已安装 \($0)", "\($0) is installed") },
                                          probeID: probe)
            } detail: {
                LightfieldPathText(path: file.resource.path)
            } trailing: {
                HStack(spacing: 4) {
                    Text(size).font(.system(size: 15)).monospacedDigit().lineLimit(1).help(size)
                    Color.clear.frame(width: 20, height: 20)
                }
            }
        }
        .buttonStyle(FeatureLightfieldRowButtonStyle())
        .accessibilityLabel(file.resource.displayName + " · " + file.resource.path + " · " + size)
        .accessibilityValue(selected ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not selected"))
        .overlay(alignment: .trailing) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.resource.path)])
            } label: {
                Image(systemName: "magnifyingglass").frame(width: 20, height: 20)
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .help(L10n.text("在访达中显示", "Reveal in Finder"))
            .accessibilityLabel(L10n.text("在访达中显示 \(file.resource.displayName)", "Reveal \(file.resource.displayName) in Finder"))
            .padding(.trailing, 6)
        }
        .lightfieldRowEntrance(index)
    }
}
