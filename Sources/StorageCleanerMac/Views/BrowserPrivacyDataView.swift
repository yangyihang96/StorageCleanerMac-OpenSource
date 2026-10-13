import SwiftUI

struct BrowserPrivacyDataView: View {
    @StateObject private var store = BrowserPrivacyDataStore()
    @StateObject private var recovery = BrowserPrivacyRecoveryStore()
    @State private var confirming = false
    @State private var showingRecords = false
    @State private var filter = ""
    var onWorkingChange: (Bool) -> Void = { _ in }
    var onShowHistory: () -> Void = {}
    private var confirmationTitle: String {
        if store.selected.contains(where: { $0.contract.type == .cookies || $0.contract.type == .sessions }) {
            return L10n.text("将退出这些网站的登录", "You will be signed out of these websites")
        }
        return L10n.text("备份并删除：", "Back up and delete: ") + Set(store.selected.map { $0.contract.type.title }).sorted().joined(separator: "、")
    }
    /// Rows matching the filter by site, label, browser or profile name.
    private func visibleGroups(_ type: BrowserPrivacyDataType) -> [BrowserPrivacyDataGroup] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return store.groups.filter { group in
            group.contract.type == type && (query.isEmpty || [group.label, group.site ?? "", group.profile.displayName, group.profile.browser.displayName]
                .contains { $0.lowercased().contains(query) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Actions stay visible above a list that can hold thousands of sites.
            HStack {
                Button(L10n.text("读取数据类型", "Read Data Types")) { Task { await store.scan() } }
                Button(L10n.text("删除所选", "Delete Selected")) { confirming = true }
                    .disabled(store.selected.isEmpty)
                Button(L10n.text("操作记录／最近的删除", "Operation Records / Recent Deletions")) { showingRecords = true }
                if store.isWorking { ProgressView().controlSize(.small) }
                if !store.selected.isEmpty { Text(L10n.text("已选 \(store.selected.count) 项", "\(store.selected.count) selected")).font(AppTypography.caption) }
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
                                    VStack(alignment: .leading) {
                                        Text(group.profile.browser.displayName + " · " + group.profile.displayName)
                                        Text(group.label + " · " + L10n.text("\(group.count) 条", "\(group.count) records"))
                                        if !group.writable { Text(group.unavailableReason) }
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
    }
}
