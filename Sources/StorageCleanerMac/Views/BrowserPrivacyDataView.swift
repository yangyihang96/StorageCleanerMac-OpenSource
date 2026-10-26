import SwiftUI

struct BrowserPrivacyDataView: View {
    @StateObject private var store: BrowserPrivacyDataStore
    @StateObject private var recovery = BrowserPrivacyRecoveryStore()
    @State private var confirming = false
    @State private var showingRecords = false
    @State private var filter = ""
    /// D154 batch 3F: the data type the manager panel shows, and its sheet
    /// of kept sites.
    @State private var currentType: BrowserPrivacyDataType = .cookies
    @State private var showingKeptSites = false
    @Environment(\.careStudioClassicResults) private var usesClassicPages
    var onWorkingChange: (Bool) -> Void = { _ in }
    var onShowHistory: () -> Void = {}

    init(store: BrowserPrivacyDataStore? = nil, onWorkingChange: @escaping (Bool) -> Void = { _ in },
         onShowHistory: @escaping () -> Void = {}) {
        _store = StateObject(wrappedValue: store ?? BrowserPrivacyDataStore())
        self.onWorkingChange = onWorkingChange
        self.onShowHistory = onShowHistory
    }

    private var confirmationTitle: String {
        if store.selected.contains(where: { $0.contract.type == .cookies || $0.contract.type == .sessions }) {
            return L10n.text("将退出这些网站的登录", "You will be signed out of these websites")
        }
        return L10n.text("备份并删除：", "Back up and delete: ") + Set(store.selected.map { $0.contract.type.title }).sorted().joined(separator: "、")
    }
    private var deleteSelectedTitle: String { L10n.text("删除所选", "Delete Selected") }
    /// Rows matching the filter by site, label, browser or profile name.
    private func visibleGroups(_ type: BrowserPrivacyDataType) -> [BrowserPrivacyDataGroup] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return store.groups.filter { group in
            group.contract.type == type && (query.isEmpty || [group.label, group.site ?? "", group.profile.displayName, group.profile.browser.displayName]
                .contains { $0.lowercased().contains(query) })
        }
    }
    var body: some View {
        Group {
            if usesClassicPages { classicPage } else { managerPage }
        }
        .onChange(of: store.isWorking) { _, working in onWorkingChange(working) }
        .confirmationDialog(confirmationTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(L10n.text("备份并删除所选", "Back Up and Delete Selected"), role: .destructive) {
                Task { await store.deleteSelected() }
            }
        } message: {
            Text(BrowserPrivacyDataConfirmation.message(store.selected))
        }
        .sheet(isPresented: $showingRecords) {
            BrowserPrivacyRecentDeletionsView(recoveryStore: recovery, isBusy: store.isWorking, onRescan: { Task { await store.scan() } })
        }
        .sheet(isPresented: $showingKeptSites) { keptSitesSheet }
    }

    /// The D91 page, kept for the classic layout.
    private var classicPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Actions stay visible above a list that can hold thousands of sites.
            HStack {
                Button(L10n.text("读取数据类型", "Read Data Types")) { Task { await store.scan() } }
                Button(deleteSelectedTitle) { confirming = true }
                    .disabled(store.selected.isEmpty)
                Button(L10n.text("操作记录／最近的删除", "Operation Records / Recent Deletions")) { showingRecords = true }
                if store.isWorking { ProgressView().controlSize(.small) }
                if !store.selected.isEmpty { Text(L10n.text("已选 \(ByteFormat.count(store.selected.count)) 项", "\(ByteFormat.count(store.selected.count)) selected")).font(AppTypography.caption) }
                Spacer()
                TextField(L10n.text("按网站或个人资料筛选", "Filter by site or profile"), text: $filter)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            .disabled(store.isWorking)
            .padding([.horizontal, .top]).padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(L10n.text("Cookie 与其他浏览器数据", "Cookies and Other Browser Data")).font(.headline)
                        Spacer()
                        Button(L10n.text("返回浏览记录", "Back to History"), action: onShowHistory)
                            .disabled(store.isWorking)
                    }
                    Text(L10n.text("只显示域名、条数和表单字段类别；所有项目默认不选。先正常退出浏览器，不会强制退出。", "Only domains, counts and form-field categories are shown. Nothing is selected by default. Quit browsers normally; they will not be forced to quit."))
                    Text(L10n.text("Safari Cookie：受系统保护，目前不提供读取值或删除。", "Safari cookies: protected by the system; reading values and deletion are unavailable."))
                    ForEach(store.messages, id: \.self) { Text($0) }
                    Text(L10n.text("保留站点会保护其子域，以及对该站点生效的父域 Cookie（例如保留 mail.google.com 也保护 .google.com）。", "Keeping a site protects its subdomains and applicable parent-domain cookies (keeping mail.google.com also protects .google.com)."))
                    if !store.keepingSites.isEmpty {
                        Text(L10n.text("保留这些站点", "Keep These Sites")).font(.headline)
                        ForEach(store.keepingSites.sorted(), id: \.self) { site in
                            HStack {
                                Text(site)
                                Button(L10n.text("移出保留列表", "Remove from Keep List")) { store.unkeep(site) }
                                    .disabled(store.isWorking)
                            }
                        }
                    }
                    ForEach(BrowserPrivacyDataType.allCases, id: \.self) { type in
                        Text(type.title).font(.headline)
                        Text(type.limitation).font(AppTypography.caption)
                        ForEach(store.availability.filter { $0.type == type }) { item in
                            Text(item.browser + " · " + item.type.title + ": " + item.reason).font(AppTypography.caption)
                        }
                        ForEach(visibleGroups(type)) { group in
                            HStack {
                                Toggle(isOn: Binding(get: { store.selection.contains(group.id) }, set: { selected in
                                    if selected && store.canSelect(group) { store.selection.insert(group.id) }
                                    else { store.selection.remove(group.id) }
                                })) {
                                    HStack(spacing: 10) {
                                        // The browser's own icon (D154 batch 3E).
                                        CachedAppIconView(path: group.profile.browser.iconPath ?? "", size: 24) {
                                            Image(systemName: "globe").frame(width: 24, height: 24)
                                        }
                                        VStack(alignment: .leading) {
                                            Text(group.profile.browser.displayName + " · " + group.profile.displayName)
                                            Text(group.label + " · " + L10n.text("\(ByteFormat.count(group.count)) 条", "\(ByteFormat.count(group.count)) records"))
                                            if !group.writable { Text(group.unavailableReason) }
                                        }
                                    }
                                }.disabled(store.isWorking || !store.canSelect(group))
                                if let site = group.site {
                                    Button(L10n.text("保留此站点", "Keep This Site")) { store.keep(site) }
                                        .disabled(store.isWorking || store.keepingSites.contains(site))
                                }
                            }
                        }
                    }
                }.padding()
            }
        }
    }
}

// MARK: - D154 batch 3F: the Cookies and Other Data manager

extension BrowserPrivacyDataView {
    /// CleanMyMac's privacy items in the light panel: the data types on the
    /// left with their counts (a type's tick selects what can be deleted
    /// there), the browser rows of the current type on the right with their
    /// icons, and the selection with one pink action below. Reading is
    /// started here, nothing is selected by default, and deletion still goes
    /// through the backup confirmation and Recent Deletions.
    private var managerPage: some View {
        ToolboxManagerPanel(
            module: .protection,
            title: BrowserPrivacyWorkspaceView.dataTypesTitle,
            query: $filter,
            searchPrompt: L10n.text("按网站或个人资料筛选", "Filter by site or profile"),
            sortOptions: [],
            sort: .constant(.name),
            categoryWidth: 236,
            onBack: { if !store.isWorking { onShowHistory() } }
        ) {
            typeColumn
        } rows: {
            groupColumn
        } footer: {
            ToolboxFooter(
                selectedCount: store.selected.count,
                actionTitle: L10n.text("删除", "Remove"),
                actionEnabled: !store.selected.isEmpty && !store.isWorking,
                action: { confirming = true }
            ) {
                Menu(L10n.text("更多", "More")) {
                    Button(hasRead ? L10n.text("重新读取", "Read Again") : L10n.text("读取", "Read")) {
                        Task { await store.scan() }
                    }
                    Button(L10n.text("保留的站点…", "Kept Sites…")) { showingKeptSites = true }
                    Button(L10n.text("最近的删除", "Recent Deletions")) { showingRecords = true }
                    Button(L10n.text("取消选择", "Clear Selection")) { store.selection = [] }
                        .disabled(store.selection.isEmpty)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.accent)
                .disabled(store.isWorking)
            }
        }
    }

    /// Something has been read (rows, limits or messages).
    private var hasRead: Bool {
        !store.groups.isEmpty || !store.availability.isEmpty || !store.messages.isEmpty
    }

    private var typeColumn: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(BrowserPrivacyDataType.allCases, id: \.self) { type in
                    let groups = store.groups.filter { $0.contract.type == type }
                    let selectable = groups.filter { store.canSelect($0) }
                    ToolboxCategoryRow(
                        module: .protection,
                        title: type.title,
                        detail: hasRead
                            ? L10n.text("\(groups.reduce(0) { $0 + $1.count }) 条", "\(groups.reduce(0) { $0 + $1.count }) records")
                            : L10n.text("未读取", "Not read"),
                        systemImage: "tray.full",
                        art: type.studioArt,
                        isCurrent: currentType == type,
                        tick: selectable.isEmpty ? nil : tick(for: selectable),
                        tickEnabled: !store.isWorking,
                        onSelect: { currentType = type },
                        onToggle: {
                            let ids = Set(selectable.map(\.id))
                            if ids.isSubset(of: store.selection) { store.selection.subtract(ids) }
                            else { store.selection.formUnion(ids) }
                        })
                }
            }
            .padding(10)
        }
#if DEBUG
        .layoutProbe("careStudio.manager.dataTypes.categories")
#endif
    }

    private func tick(for groups: [BrowserPrivacyDataGroup]) -> TriStateSelection {
        let chosen = groups.filter { store.selection.contains($0.id) }.count
        return chosen == 0 ? .unchecked : (chosen == groups.count ? .checked : .mixed)
    }

    private var groupColumn: some View {
        let groups = visibleGroups(currentType)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ToolboxSectionHeader(title: currentType.title, summary: currentType.limitation) { EmptyView() }
                if store.isWorking {
                    ToolboxNotice(tone: .info, title: L10n.text("正在读取…", "Reading…"))
                }
                ForEach(store.messages, id: \.self) { message in
                    ToolboxNotice(tone: .info, title: message)
                }
                ForEach(store.availability.filter { $0.type == currentType }) { item in
                    Text(item.browser + " · " + item.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 3)
                }
                if !hasRead && !store.isWorking {
                    CareStudioManagerEmptyState(
                        art: currentType.studioArt, title: L10n.text("还没有读取", "Not Read Yet"),
                        detail: L10n.text("读取各浏览器的 Cookie、站点存储、下载记录和表单自动填充，只显示域名和条数，默认一个都不选。",
                                          "Reads each browser's cookies, site storage, download records and form autofill; only domains and counts are shown, and nothing is selected by default."))
                    ToolboxLinkButton(title: L10n.text("读取", "Read"), systemImage: "arrow.clockwise") {
                        Task { await store.scan() }
                    }
                    .frame(maxWidth: .infinity)
                } else if hasRead && groups.isEmpty {
                    CareStudioManagerEmptyState(title: L10n.text("这一类没有可显示的项目", "Nothing to Show Here"))
                }
                ForEach(groups) { group in dataRow(group) }
            }
            .padding(.bottom, 10)
        }
#if DEBUG
        .layoutProbe("careStudio.manager.dataTypes.list")
#endif
    }

    /// One browser profile's rows of a type: its icon, the site (or list),
    /// the browser and profile, the count; a lock when it cannot be deleted
    /// here or its site is kept; Keep for a site.
    private func dataRow(_ group: BrowserPrivacyDataGroup) -> some View {
        let kept = group.isProtected(by: store.keepingSites)
        var badges: [ToolboxBadge] = []
        if kept { badges.append(.init(text: L10n.text("已保留", "Kept"), tone: .accent)) }
        return HStack(spacing: 0) {
            ToolboxItemRow(
                title: group.label,
                badges: badges,
                detail: group.profile.browser.displayName + " · " + group.profile.displayName,
                value: L10n.text("\(ByteFormat.count(group.count)) 条", "\(ByteFormat.count(group.count)) records"),
                tick: store.canSelect(group) ? (store.selection.contains(group.id) ? .checked : .unchecked) : nil,
                tickEnabled: !store.isWorking,
                lockedReason: kept ? L10n.text("这个站点在保留列表里", "This site is on the keep list") : group.unavailableReason,
                onToggle: {
                    if store.selection.contains(group.id) { store.selection.remove(group.id) }
                    else if store.canSelect(group) { store.selection.insert(group.id) }
                }
            ) {
                CachedAppIconView(path: group.profile.browser.iconPath ?? "", size: 28) {
                    CareStudioGlyph(module: .protection, systemImage: "globe", side: 28)
                }
            }
            if let site = group.site, !kept {
                ToolboxLinkButton(title: L10n.text("保留", "Keep"), isEnabled: !store.isWorking) { store.keep(site) }
                    .help(L10n.text("保留此站点：它的子域和对它生效的父域 Cookie 都不会被选中。",
                                    "Keep this site: its subdomains and the parent-domain cookies that apply to it are never selected."))
                    .padding(.trailing, 16)
            }
        }
    }

    private var keptSitesSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("保留的站点", "Kept Sites")).font(.system(size: 17, weight: .semibold))
            Text(L10n.text("保留站点会保护其子域，以及对该站点生效的父域 Cookie（例如保留 mail.google.com 也保护 .google.com）。",
                           "Keeping a site protects its subdomains and applicable parent-domain cookies (keeping mail.google.com also protects .google.com)."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.keepingSites.isEmpty {
                Text(L10n.text("还没有保留的站点。", "No sites are kept yet."))
                    .font(.system(size: 12))
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.keepingSites.sorted(), id: \.self) { site in
                            HStack {
                                Text(site).font(.system(size: 13))
                                Spacer()
                                Button(L10n.text("移出保留列表", "Remove from Keep List")) { store.unkeep(site) }
                                    .disabled(store.isWorking)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            HStack {
                Spacer()
                Button(L10n.text("完成", "Done")) { showingKeptSites = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

extension BrowserPrivacyDataType {
    /// D166: each type's object in the manager's left column.
    var studioArt: GeneratedArt {
        switch self {
        case .cookies: .tileCookies
        case .siteStorage: .tileBrowsers
        case .downloads: .tileDownloaded
        case .autofill: .tileReview
        case .sessions: .tileHistory
        }
    }
}
