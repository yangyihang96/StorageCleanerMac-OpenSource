import SwiftUI

/// D154: CleanMyMac 5.7.2's My Tools — single-purpose tools as cards on the
/// module gradient, a search field, and Favorites above Other Tools. Ours
/// lists the pages that are not a module's first page (the tools CleanMyMac
/// does not have, and our single flows), so every page stays one click from
/// the sidebar. Report §4 item 20 (`1比1对照-20261023/cmm/09`): three cards a
/// row, no module on a card, "New" on this version's tools until they are
/// opened here, and no title over the cards until one is saved.
struct CareStudioMyToolsPage: View {
    @ObservedObject var store: ScanStore
    @AppStorage(MyToolsCatalog.favoritesDefaultsKey) private var favoritesRaw = ""
    @AppStorage(MyToolsCatalog.triedDefaultsKey) private var triedRaw = ""
    @State private var query = ""

    private var favorites: Set<String> { MyToolsCatalog.ids(from: favoritesRaw) }
    private var tried: Set<String> { MyToolsCatalog.ids(from: triedRaw) }

    var body: some View {
        CareStudioHubFrame(module: .myTools) {
            CareStudioHubScroll {
                VStack(alignment: .leading, spacing: 22) {
                    CareStudioHubHeader(title: CareStudioModule.myTools.title,
                                        subtitle: CareStudioModule.myTools.subtitle) {
                        CareStudioSearchField(text: $query, prompt: L10n.text("搜索工具", "Search..."))
                    }
                    content
                }
                .padding(.horizontal, CareStudioMetrics.pageInset)
                .padding(.top, 24)
                .padding(.bottom, 36)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = MyToolsCatalog.ordered(tried: tried)
        if needle.isEmpty {
            ForEach(Array(MyToolsCatalog.sections(tools, favorites: favorites).enumerated()), id: \.offset) { _, part in
                if let title = part.title {
                    section(title, tools: part.tools)
                } else {
                    grid(part.tools)
                }
            }
        } else {
            let found = tools.filter { $0.matches(needle) }
            if found.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(CareStudioInk.tertiary)
                    Text(L10n.text("没有符合搜索的工具。", "No tools match your search."))
                        .font(.system(size: 14))
                        .foregroundStyle(CareStudioInk.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                section(L10n.text("找到 \(ByteFormat.count(found.count)) 个工具", "\(ByteFormat.count(found.count)) results found"), tools: found)
            }
        }
    }

    private func section(_ title: String, tools: [MyToolsCatalog.Tool]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CareStudioSectionTitle(title: title)
            grid(tools)
        }
    }

    /// Three equal columns at every width (CleanMyMac, `cmm/09`); the cards
    /// of a row take the tallest one's height, and the grid its own height.
    private func grid(_ tools: [MyToolsCatalog.Tool]) -> some View {
        let spacing = CareStudioMetrics.tileSpacing
        return Grid(alignment: .topLeading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Array(MyToolsCatalog.rows(of: tools).enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { tool in
                        CareStudioToolCard(tool: tool, isFavorite: favorites.contains(tool.id),
                                           isNew: MyToolsCatalog.showsNewTag(tool, tried: tried),
                                           onToggleFavorite: { toggleFavorite(tool.id) },
                                           onOpen: { open(tool) })
                    }
                    ForEach(row.count..<MyToolsCatalog.columns, id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toggleFavorite(_ id: String) {
        var set = favorites
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        favoritesRaw = MyToolsCatalog.encode(set)
    }

    private func open(_ tool: MyToolsCatalog.Tool) {
        if MyToolsCatalog.showsNewTag(tool, tried: tried) {
            triedRaw = MyToolsCatalog.encode(tried.union([tool.id]))
        }
        Task { @MainActor in
            switch tool.destination {
            case .route(let route):
                if route == .duplicates { store.duplicateFilesWorkspace.resultFilter = .all }
                store.navigationState.select(route)
            case .similarPhotos:
                store.duplicateFilesWorkspace.resultFilter = .similarImage
                store.navigationState.select(.duplicates)
            }
        }
    }
}

/// One tool, as CleanMyMac's cards (report §4 item 20, `cmm/09`): its mark,
/// name and what it does, and Open at the foot; no module. "New" sits on the
/// corner of a new tool. Save / Saved shows while the pointer is on the card
/// (CleanMyMac's card tracks the pointer for that control); the context menu
/// and the Open button's accessibility action save a tool too.
struct CareStudioToolCard: View {
    let tool: MyToolsCatalog.Tool
    let isFavorite: Bool
    var isNew = false
    let onToggleFavorite: () -> Void
    let onOpen: () -> Void
    @State private var isHovered = false

    /// CleanMyMac's card is 240 pt tall; ours grows with a longer text.
    static let minimumHeight: CGFloat = 232

    private var favoriteAction: String {
        isFavorite ? L10n.text("取消收藏", "Remove from Favorites") : L10n.text("收藏", "Save to Favorites")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                // Our own tools keep their picture's colour; the single flows
                // of a CleanMyMac module take the module's.
                CareStudioFamilyMark(family: tool.family == .myTools ? nil : tool.family, art: tool.art, side: 46)
                Spacer(minLength: 0)
                favoriteButton
                    .opacity(isHovered ? 1 : 0)
            }
            Text(tool.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CareStudioInk.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Text(tool.detail)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(CareStudioInk.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Spacer(minLength: 18)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                CareStudioToolOpenButton(title: L10n.text("打开", "Open"), action: onOpen)
                    .accessibilityLabel(L10n.text("打开\(tool.title)", "Open \(tool.title)"))
                    .accessibilityAction(named: favoriteAction, onToggleFavorite)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: Self.minimumHeight, maxHeight: .infinity, alignment: .topLeading)
        .careStudioCard(isHovered: isHovered)
        .overlay(alignment: .topLeading) {
            if isNew {
                CareStudioNewTag()
                    .offset(x: -7, y: -7)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contextMenu {
            Button(favoriteAction, action: onToggleFavorite)
        }
        .accessibilityElement(children: .contain)
#if DEBUG
        .layoutProbe("careStudio.tool.\(tool.id)")
#endif
    }

    /// CleanMyMac's Save / Saved: a star and a word.
    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            HStack(spacing: 4) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isFavorite ? CareStudioInk.badgeAttention : CareStudioInk.secondary)
                Text(isFavorite ? L10n.text("已收藏", "Saved") : L10n.text("收藏", "Save"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CareStudioInk.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(CareStudioRowButtonStyle())
        .help(favoriteAction)
        .accessibilityLabel(favoriteAction)
        .accessibilityValue(isFavorite ? L10n.text("已收藏", "Saved") : "")
    }
}

/// CleanMyMac's Open / Scan on a tool card: a white rounded rectangle (the
/// results' Review is a capsule), in the filled pill's colours.
struct CareStudioToolOpenButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .foregroundStyle(CareStudioInk.inverse)
        }
        .buttonStyle(CareStudioToolOpenStyle())
    }
}

private struct CareStudioToolOpenStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .background(shape.fill(CareStudioInk.primary.opacity(configuration.isPressed ? 0.82 : 0.96)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

/// CleanMyMac's "New" (report §4 item 20, `cmm/09`): white type on a magenta
/// capsule, on the corner of a new tool's card and of My Tools' mark in the
/// sidebar.
struct CareStudioNewTag: View {
    var body: some View {
        Text(L10n.text("新", "New"))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule(style: .continuous).fill(CareStudioInk.newTag))
            .fixedSize()
            .accessibilityLabel(L10n.text("新工具", "New tool"))
    }
}

/// The tools on My Tools, in CleanMyMac's spirit: one card per page that is
/// not a module's first page.
enum MyToolsCatalog {
    static let favoritesDefaultsKey = "myTools.favorites.v1"
    /// Report §4 item 20: the new tools opened from My Tools (CleanMyMac keeps
    /// "New" on a new tool until it is tried).
    static let triedDefaultsKey = "myTools.tried.v1"
    /// Three cards a row (CleanMyMac, `cmm/09`).
    static let columns = 3

    enum Destination: Equatable {
        case route(ReviewFilter)
        case similarPhotos
    }

    struct Tool: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let keywords: [String]
        let family: CareStudioFamily
        let art: GeneratedArt
        let destination: Destination
        /// New in this version (2.0.1: D160–D162).
        var isNew = false

        func matches(_ needle: String) -> Bool {
            let lowered = needle.lowercased()
            return ([title, detail, family.title] + keywords).contains { $0.lowercased().contains(lowered) }
        }
    }

    static var tools: [Tool] {
        [
            Tool(id: "benchmark", title: ReviewFilter.performance.title,
                 detail: L10n.text("测 CPU、图形、媒体和持续性能，和自己的历史及社区成绩对比。",
                                   "Measure CPU, graphics, media and sustained performance, against your history and the community."),
                 keywords: ["benchmark", "跑分", "性能", "cpu", "gpu"], family: .myTools, art: .benchmark,
                 destination: .route(.performance)),
            Tool(id: "health", title: ReviewFilter.healthHub.title,
                 detail: L10n.text("检查磁盘、电池、备份与系统安全设置，给出健康评分。",
                                   "Check disk, battery, backups and security settings, with a health score."),
                 keywords: ["health", "健康", "磁盘", "电池", "安全", "smart"], family: .myTools, art: .health,
                 destination: .route(.healthHub)),
            Tool(id: "energy", title: ReviewFilter.energy.title,
                 detail: L10n.text("看哪些应用和进程最耗电，以及芯片的功率和温度。",
                                   "See which apps and processes use the most energy, and the chip's power and temperature."),
                 keywords: ["energy", "能耗", "电量", "功率", "battery"], family: .myTools, art: .energy,
                 destination: .route(.energy)),
            Tool(id: "migration", title: ReviewFilter.migration.title,
                 detail: L10n.text("把大文件或应用复制到外接硬盘并校验，确认后才把原件移到废纸篓。",
                                   "Copy large files or apps to an external drive and verify them; originals go to Trash only after you confirm."),
                 keywords: ["migration", "搬家", "外接", "移动", "external"], family: .myTools, art: .migration,
                 destination: .route(.migration)),
            Tool(id: "developerJunk", title: CareStudioModule.devTools.title,
                 detail: L10n.text("构建产物、包管理器和 AI 工具的缓存，源码和会话不动。",
                                   "Build products and caches of package managers and AI tools; sources and sessions stay put."),
                 keywords: ["xcode", "developer", "开发", "缓存", "ai", "npm", "cache"], family: .cleanup, art: .devCaches,
                 destination: .route(.devCaches)),
            Tool(id: "memory", title: ReviewFilter.memory.title,
                 detail: L10n.text("看内存压力和占用最多的应用，释放可回收的内存。",
                                   "See memory pressure and the apps using the most, and free up reclaimable memory."),
                 keywords: ["memory", "ram", "内存", "释放"], family: .performance, art: .memory,
                 destination: .route(.memory)),
            Tool(id: "loginItems", title: ReviewFilter.startup.title,
                 detail: L10n.text("登录时打开的应用和在后台运行的项目，可停用，也可撤销。",
                                   "Apps that open at login and items running in the background; turn them off or undo."),
                 keywords: ["login", "startup", "登录项", "后台", "launch agent"], family: .performance, art: .startup,
                 destination: .route(.startup)),
            Tool(id: "maintenance", title: ReviewFilter.maintenance.title,
                 detail: L10n.text("查看系统维护任务的状态，按需重建邮件索引、刷新“打开方式”等。",
                                   "See the state of system maintenance tasks and run the ones you need, such as reindexing Mail."),
                 keywords: ["maintenance", "维护", "邮件", "索引", "launch services", "打开方式"], family: .performance,
                 art: .maintenance, destination: .route(.maintenance), isNew: true),
            Tool(id: "uninstaller", title: L10n.text("卸载程序", "Uninstaller"),
                 detail: L10n.text("连同找到的相关文件一起卸载应用，全部移到废纸篓、可以恢复。",
                                   "Uninstall apps together with the related files found; everything goes to Trash and can be restored."),
                 keywords: ["uninstall", "卸载", "app", "残留", "leftovers"], family: .applications, art: .uninstall,
                 destination: .route(.uninstall)),
            Tool(id: "updater", title: ReviewFilter.updater.title,
                 detail: L10n.text("检查来自可信来源的应用更新，逐项或全部更新。",
                                   "Check app updates from trusted sources and update one or all."),
                 keywords: ["update", "更新", "app store", "sparkle", "homebrew"], family: .applications, art: .updater,
                 destination: .route(.updater)),
            Tool(id: "extensions", title: ReviewFilter.extensions.title,
                 detail: L10n.text("应用扩展、插件和输入法等加载项，可移到废纸篓、可以恢复。",
                                   "App extensions, plug-ins, input methods and other add-ons; move them to the Trash and restore them."),
                 keywords: ["extension", "扩展", "插件", "plugin", "输入法", "safari"], family: .applications,
                 art: .extensions, destination: .route(.extensions), isNew: true),
            Tool(id: "privacy", title: ReviewFilter.privacy.title,
                 detail: L10n.text("浏览记录、Cookie 和站点数据，先备份再删除，可以恢复。",
                                   "Browsing history, cookies and site data; backed up before deletion and restorable."),
                 keywords: ["privacy", "隐私", "浏览器", "cookie", "safari", "chrome"], family: .protection, art: .privacy,
                 destination: .route(.privacy)),
            Tool(id: "duplicates", title: ReviewFilter.duplicates.title,
                 detail: L10n.text("按内容找出完全相同的文件，每组至少留一份。",
                                   "Find files with identical contents; at least one copy of each stays."),
                 keywords: ["duplicate", "重复", "副本"], family: .clutter, art: .duplicates,
                 destination: .route(.duplicates)),
            Tool(id: "chatFiles", title: ReviewFilter.chatFiles.title,
                 detail: L10n.text("微信、QQ 等聊天软件收到的图片、视频和文件，按应用和时间查看。",
                                   "Pictures, videos and files received in chat apps such as WeChat and QQ, by app and age."),
                 keywords: ["chat", "聊天", "微信", "wechat", "qq", "企业微信"], family: .clutter,
                 art: .chatFiles, destination: .route(.chatFiles), isNew: true),
            Tool(id: "similarPhotos", title: L10n.text("相似照片", "Similar Photos"),
                 detail: L10n.text("只读对照视觉相似的照片，逐张人工确认。",
                                   "Read-only comparison of visually similar photos, confirmed one by one."),
                 keywords: ["photo", "照片", "相似", "similar", "image"], family: .clutter, art: .similarPhotos,
                 destination: .similarPhotos)
        ]
    }

    /// The tools wearing "New" first, then the rest in the catalog's order
    /// (CleanMyMac puts its badged tools first).
    static func ordered(tried: Set<String>) -> [Tool] {
        let all = tools
        return all.filter { showsNewTag($0, tried: tried) } + all.filter { !showsNewTag($0, tried: tried) }
    }

    /// "New" until the tool is opened from My Tools.
    static func showsNewTag(_ tool: Tool, tried: Set<String>) -> Bool {
        tool.isNew && !tried.contains(tool.id)
    }

    /// My Tools in the sidebar wears "New" while a new tool is untried.
    static func hasUntriedNewTool(tried: Set<String>) -> Bool {
        tools.contains { showsNewTag($0, tried: tried) }
    }

    struct Section: Equatable {
        /// None over the cards until a tool is saved (CleanMyMac).
        let title: String?
        let tools: [Tool]
    }

    /// Favorites above Other Tools once a tool is saved; before that, the
    /// cards without a title.
    static func sections(_ tools: [Tool], favorites: Set<String>) -> [Section] {
        let saved = tools.filter { favorites.contains($0.id) }
        let others = tools.filter { !favorites.contains($0.id) }
        guard !saved.isEmpty else { return [Section(title: nil, tools: others)] }
        return [Section(title: L10n.text("收藏", "Favorites"), tools: saved)]
            + (others.isEmpty ? [] : [Section(title: L10n.text("其他工具", "Other Tools"), tools: others)])
    }

    static func rows(of tools: [Tool]) -> [[Tool]] {
        stride(from: 0, to: tools.count, by: columns).map { Array(tools[$0..<min($0 + columns, tools.count)]) }
    }

    /// The saved and the tried tools, kept as comma-separated ids.
    static func ids(from raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }
}
