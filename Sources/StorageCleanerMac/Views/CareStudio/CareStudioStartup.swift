import AppKit
import SwiftUI

/// D143: Login Items & Background Tasks in the CleanMyMac Performance
/// layout (`截图/cmm-14`–`cmm-17`): landing, reading, result tiles and the
/// light manager. Management stays ours: switches that disable and enable
/// with undo (Tencent Lemon's per-item switches) instead of CleanMyMac's
/// one-way Remove; protected, managed and unattributed items stay read-only.
struct CareStudioStartupLanding: View {
    let items: [StartupItemsDomain.Item]
    let canRefresh: Bool
    let onStart: () -> Void

    var body: some View {
        CareStudioLandingPage(
            module: .startup,
            bullets: [
                CareStudioBullet(id: "startup.login", title: L10n.text("登录时打开的应用", "Apps That Open at Login"),
                                 systemImage: "power"),
                CareStudioBullet(id: "startup.background", title: L10n.text("后台项目", "Background Items"),
                                 systemImage: "gearshape.2.fill"),
                CareStudioBullet(id: "startup.attention", title: L10n.text("失效与需要关注的项目", "Broken & Attention Items"),
                                 systemImage: "exclamationmark.triangle.fill")
            ],
            status: items.isEmpty ? nil
                : L10n.text("上次读取到 \(ByteFormat.count(items.count)) 项，重新扫描可看到当前状态。",
                            "\(ByteFormat.count(items.count)) items last time; scan again for the current state."),
            footnote: L10n.text("只读检查 · 更改前逐项确认并保留撤销记录",
                                "Read-only check · Changes are confirmed and can be undone"),
            actionTitle: L10n.text("扫描", "Scan"),
            actionEnabled: canRefresh,
            action: onStart)
    }
}

struct CareStudioStartupRunning: View {
    let title: String
    let discoveredCount: Int
    let onCancel: () -> Void

    var body: some View {
        CareStudioRunningPage(
            module: .startup,
            title: CareStudioModule.startup.scanningTitle,
            detail: title,
            headlineValue: L10n.text("已发现 \(ByteFormat.count(discoveredCount)) 项", "\(ByteFormat.count(discoveredCount)) found"),
            progress: .indeterminate,
            footnote: L10n.text("只读检查 · 不会更改任何启动项", "Read-only check · Nothing is changed"),
            onStop: onCancel)
    }
}

/// The callbacks the startup console already wires (enable, disable, stop,
/// reveal, open app, copy, settings, undo).
struct CareStudioStartupActions {
    var onRefresh: () -> Void
    var onEnable: ((StartupItemsDomain.Candidate) -> Void)?
    var onDisable: ((StartupItemsDomain.Candidate) -> Void)?
    var onStop: ((StartupItemsDomain.Candidate) -> Void)?
    var onReveal: ((StartupItemsDomain.Item) -> Void)?
    var onOpenParentApplication: ((StartupItemsDomain.Item) -> Void)?
    var onCopyText: ((String) -> Void)?
    var onOpenSystemSettings: (() -> Void)?
    var onUndo: (() -> Void)?
    /// Report §4 item 12: the title bar's Start Over (back to the landing page).
    var onStartOver: (() -> Void)? = nil
    /// The exclusive work Start Over waits for: maintenance tasks run from
    /// this page hold the cleanup lease (item 13).
    var startOverActivity: HeavyWorkActivityStore? = nil
}

struct CareStudioStartupResultsPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [StartupItemsDomain.Item]
    let activeOperationCandidateID: String?
    let isPerformingOperation: Bool
    let coverageAction: AnyView
    let actions: CareStudioStartupActions
    var onShowClassicList: (() -> Void)? = nil
    /// D154 batch 2: tiles of the module's other tools (Maintenance, D161),
    /// shown first, as CleanMyMac's Performance results list them.
    var leadingTiles: [CareStudioTileModel] = []
    var coverage: StartupCoverageReport = .empty
    @State private var managerCategory: StartupItemsCategory?
    @State private var showsManager = false

    private var presentation: StartupItemsPresentation {
        StartupItemsPresentation.make(items: items, query: "", category: .all, status: .all, source: .all,
                                      includeAppleSystem: false, sort: .recommended, includeTechnicalDetails: false)
    }

    var body: some View {
        Group {
            if showsManager {
                CareStudioStartupManager(items: items, initialCategory: managerCategory ?? .all,
                                         activeOperationCandidateID: activeOperationCandidateID,
                                         isPerformingOperation: isPerformingOperation,
                                         coverageAction: coverageAction, actions: actions,
                                         onShowClassicList: onShowClassicList,
                                         onBack: { withAnimation(CareStudioMotion.animation(0.2, reduceMotion: reduceMotion)) { showsManager = false } })
                    .transition(.opacity)
            } else {
                // Item 12: Start Over in the title bar (was Scan Again on the page).
                CareStudioPageFrame(module: .startup,
                                    titleBar: actions.onStartOver.map { startOver in
                                        .startOver(CareStudioStartOver(activity: actions.startOverActivity,
                                                                       isEnabled: !isPerformingOperation, action: startOver))
                                    } ?? .title,
                                    footnote: L10n.text("停用前逐项确认 · 可随时撤销", "Each change is confirmed · Undo any time")) {
                    content
                } action: {
                    EmptyView()
                }
                .transition(.opacity)
            }
        }
#if DEBUG
        .layoutProbe("careStudio.startup.results")
#endif
    }

    private var content: some View {
        let summary = presentation
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                if let onUndo = actions.onUndo {
                    CareStudioPillButton(title: L10n.text("撤销上次更改", "Undo Last Change"),
                                         systemImage: "arrow.uturn.backward", compact: true, action: onUndo)
                }
            }
            // Keeps the height of the pills, so the headline keeps its place.
            .frame(height: 26)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            Text(L10n.text("查看推荐的调整，或逐项管理启动项：", "Apply recommendations or manage items one by one:"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(CareStudioInk.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 14)
            CareStudioPillButton(title: L10n.text("查看全部项目", "View All Items")) {
                managerCategory = .all
                withAnimation(CareStudioMotion.animation(0.2, reduceMotion: reduceMotion)) { showsManager = true }
            }
            .padding(.top, 12)
            CareStudioTileGrid(tiles: tiles(summary))
                .padding(.horizontal, CareStudioMetrics.pageInset)
                .padding(.top, 22)
                .padding(.bottom, 16)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func tiles(_ summary: StartupItemsPresentation) -> [CareStudioTileModel] {
        let reading = StartupReadPresentation(coverage: coverage)
        let loginItems = summary.allItems.filter { $0.consoleCategory == .loginItems }
        // Item 13's evidence showed "You Have 1 Login Items": one is singular.
        let login = summary.count(for: .loginItems)
        let background = summary.count(for: .background)
        let updates = summary.count(for: .updatesAndSync)
        func open(_ category: StartupItemsCategory) -> () -> Void {
            {
                managerCategory = category
                withAnimation(CareStudioMotion.animation(0.2, reduceMotion: reduceMotion)) { showsManager = true }
            }
        }
        var tiles = leadingTiles + [
            CareStudioTileModel(
                id: "login", module: .startup,
                title: reading.loginTitle(count: login),
                detail: reading.loginDetail,
                systemImage: "power",
                iconPaths: loginItems.compactMap(\.applicationIconPath).prefix(3).map { $0 },
                subgroupSymbols: ["power", "person.crop.circle.fill", "macwindow"],
                reviewTitle: L10n.text("查看", "Review"), onReview: open(.loginItems), art: .tileLoginItems),
            CareStudioTileModel(
                id: "background", module: .startup,
                title: reading.backgroundTitle(count: background),
                detail: reading.backgroundDetail,
                systemImage: "gearshape.2.fill",
                reviewTitle: L10n.text("查看", "Review"), onReview: open(.background), art: .tileBackground),
            CareStudioTileModel(
                id: "updates", module: .startup,
                title: L10n.text("\(ByteFormat.count(updates)) 个更新与同步项",
                                 updates == 1 ? "1 Update & Sync Item" : "\(ByteFormat.count(updates)) Update & Sync Items"),
                systemImage: "arrow.triangle.2.circlepath",
                reviewTitle: L10n.text("查看", "Review"), onReview: open(.updatesAndSync), art: .tileSync)
        ]
        if summary.count(for: .attention) > 0 {
            tiles.append(CareStudioTileModel(
                id: "attention", module: .startup,
                title: L10n.text("\(summary.count(for: .attention)) 个需要关注", "\(summary.count(for: .attention)) Need Attention"),
                detail: L10n.text("失效、找不到程序或归属不明的启动项。", "Broken items, missing programs or unknown owners."),
                systemImage: "exclamationmark.triangle.fill",
                reviewTitle: L10n.text("查看", "Review"), onReview: open(.attention), art: .tileAttention))
        }
        return tiles
    }
}

/// The light manager (CleanMyMac "Performance Manager"): categories on the
/// left, items on the right with a switch for what can be managed directly.
struct CareStudioStartupManager: View {
    let items: [StartupItemsDomain.Item]
    let initialCategory: StartupItemsCategory
    let activeOperationCandidateID: String?
    let isPerformingOperation: Bool
    let coverageAction: AnyView
    let actions: CareStudioStartupActions
    var onShowClassicList: (() -> Void)? = nil
    let onBack: () -> Void

    @State private var category: StartupItemsCategory?
    @State private var chromeID = UUID()
    @State private var query = ""
    @State private var sort: StartupItemsSortOrder = .recommended

    private var current: StartupItemsCategory { category ?? initialCategory }

    private var presentation: StartupItemsPresentation {
        StartupItemsPresentation.make(items: items, query: query, category: current, status: .all, source: .all,
                                      includeAppleSystem: false, sort: sort, includeTechnicalDetails: false)
    }

    var body: some View {
        ZStack {
            CareStudioBackdrop(module: .startup, reportsWindowSize: true)
            VStack(spacing: 0) {
                header
                Rectangle().fill(CareStudioManagerInk.separator).frame(height: 1)
                HStack(spacing: 0) {
                    categoryColumn.frame(width: 196)
                    Rectangle().fill(CareStudioManagerInk.separator).frame(width: 1)
                    itemColumn
                }
                footer
            }
            .background(RoundedRectangle(cornerRadius: CareStudioMetrics.managerCorner, style: .continuous)
                .fill(CareStudioManagerInk.panel))
            .clipShape(RoundedRectangle(cornerRadius: CareStudioMetrics.managerCorner, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .padding(CareStudioMetrics.managerInset)
            .environment(\.colorScheme, .light)
        }
        .onAppear { CareStudioCanvas.shared.claim(chromeID, animating: false, label: "startupManager") }
        .onDisappear { CareStudioCanvas.shared.release(chromeID) }
        .onExitCommand(perform: onBack)
#if DEBUG
        .layoutProbe("careStudio.startup.manager")
#endif
    }

    private var header: some View {
        ZStack {
            Text(L10n.text("启动项管理", "Startup Manager"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.primary)
            HStack(spacing: 12) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text(L10n.text("返回", "Back")).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(CareStudioManagerInk.accent)
                }
                .buttonStyle(CareStudioRowButtonStyle())
                .keyboardShortcut(.cancelAction)
                Spacer()
                if let onUndo = actions.onUndo {
                    Button(L10n.text("撤销", "Undo"), action: onUndo)
                        .buttonStyle(CareStudioRowButtonStyle())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.accent)
                }
                if let onShowClassicList {
                    Button(L10n.text("经典列表", "Classic List"), action: onShowClassicList)
                        .buttonStyle(CareStudioRowButtonStyle())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.accent)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.accent)
                    TextField(L10n.text("搜索启动项", "Search items"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 140)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(CareStudioManagerInk.field))
                Menu {
                    ForEach(StartupItemsSortOrder.allCases) { option in
                        Button(option.title) { sort = option }
                    }
                } label: {
                    // One concatenated Text: a borderless menu shows only the
                    // first view of a stacked label.
                    (Text(L10n.text("排序：", "Sort by: ")).foregroundStyle(CareStudioManagerInk.primary)
                        + Text(sort.title).foregroundStyle(CareStudioManagerInk.accent))
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var categoryColumn: some View {
        let counts = StartupItemsPresentation.make(items: items, query: "", category: .all, status: .all, source: .all,
                                                   includeAppleSystem: false, sort: .recommended, includeTechnicalDetails: false)
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(StartupItemsCategory.allCases) { option in
                    let isCurrent = option == current
                    Button { category = option } label: {
                        HStack(spacing: 10) {
                            // D166: CleanMyMac's coloured category objects.
                            FeatureLightfieldArtwork(art: Self.art(for: option), variant: .header)
                                .hueRotation(CareStudioFamily.performance.hueRotation(for: Self.art(for: option)))
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                            Text(option.title)
                                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                            Spacer()
                            Text("\(counts.count(for: option))")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(CareStudioManagerInk.secondary)
                        }
                        .foregroundStyle(CareStudioManagerInk.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isCurrent ? CareStudioManagerInk.selection : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CareStudioRowButtonStyle())
                }
            }
            .padding(10)
        }
    }

    /// D166: the object of each category.
    static func art(for category: StartupItemsCategory) -> GeneratedArt {
        switch category {
        case .all: .performance
        case .loginItems: .tileLoginItems
        case .background, .otherBackground: .tileBackground
        case .updatesAndSync: .tileSync
        case .attention: .tileAttention
        }
    }

    private var itemColumn: some View {
        let visible = presentation.visibleItems
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.title).font(.system(size: 15, weight: .semibold))
                    Text(Self.explanation(for: current))
                        .font(.system(size: 12))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(CareStudioManagerInk.primary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                if visible.isEmpty {
                    CareStudioManagerEmptyState(title: L10n.text("没有符合条件的项目", "No Items Match"))
                }
                ForEach(visible) { item in
                    CareStudioStartupRow(item: item,
                                         isBusy: isPerformingOperation && item.components.contains { $0.id == activeOperationCandidateID },
                                         allowsMutation: presentation.allowsStartupMutationActions && !isPerformingOperation,
                                         actions: actions)
                        .id(item.id)
                }
            }
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        let summary = presentation.summary
        return ZStack {
            Text(L10n.text("\(ByteFormat.count(summary.manageable)) 项可直接管理 · \(ByteFormat.count(summary.systemSettingsOnly)) 项需在系统设置中处理",
                           "\(ByteFormat.count(summary.manageable)) manageable here · \(ByteFormat.count(summary.systemSettingsOnly)) in System Settings"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.primary)
            HStack(spacing: 10) {
                coverageAction
                Spacer()
                if let onOpenSystemSettings = actions.onOpenSystemSettings {
                    Button(action: onOpenSystemSettings) {
                        Text(L10n.text("打开系统设置", "Open System Settings"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .background(Capsule().fill(CareStudioManagerInk.accent))
                    }
                    .buttonStyle(CareStudioRowButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(CareStudioManagerInk.footer)
    }

    static func explanation(for category: StartupItemsCategory) -> String {
        switch category {
        case .all:
            L10n.text("登录时打开的应用和在后台运行的项目。Apple 系统项默认不列出。",
                      "Apps that open at login and items that run in the background. Apple system items are hidden.")
        case .loginItems:
            L10n.text("每次登录时自动打开的应用。不需要它们时，Mac 不必为此花费资源。",
                      "Apps that open every time you log in. Your Mac needn't spend resources on ones you don't use.")
        case .background:
            L10n.text("用户代理、共享代理和守护进程目录中的启动文件，每个文件单独列出。停用可能影响相关应用功能。",
                      "Startup files in the user-agent, shared-agent and daemon directories, listed individually. Disabling one may affect its app.")
        case .otherBackground:
            L10n.text("系统登记、应用内服务、运行中任务和失效残留等组件，不计入后台项目数。",
                      "System registrations, embedded services, runtime jobs and leftover components. These do not count toward Background Items.")
        case .updatesAndSync:
            L10n.text("负责检查更新或同步数据的后台项目。停用后需要手动更新或同步。",
                      "Background items that check for updates or sync data. Turned off, you update or sync by hand.")
        case .attention:
            L10n.text("失效、找不到程序、签名异常或归属不明的项目。只能查看或在系统设置中处理。",
                      "Broken items, missing programs, invalid signatures or unknown owners. View them or handle them in System Settings.")
        }
    }
}

/// One startup item: icon, name, who made it and what it is, its state, and
/// a switch when this app may change it directly.
struct CareStudioStartupRow: View {
    let item: StartupItemsDomain.Item
    let isBusy: Bool
    let allowsMutation: Bool
    let actions: CareStudioStartupActions
    @State private var isHovered = false

    private var switchCandidate: StartupItemsDomain.Candidate? {
        item.components.first { $0.actionCapability.canDisableDirectly || $0.actionCapability.canEnableDirectly }
    }

    private var isEnabled: Bool {
        guard let candidate = switchCandidate else { return item.state.enablement != .disabled }
        return candidate.state.enablement != .disabled
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .lineLimit(1)
                if item.components.count == 1, let component = item.components.first,
                   component.isCountedBackgroundPlist, let path = component.plistURL?.path {
                    Text(path).font(.system(size: 11))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .lineLimit(1).truncationMode(.middle).help(path)
                }
                Text([item.developerDisplayName, item.kind.title, item.runningSummaryText]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(item.displayStatus)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(item.needsAttention ? CareStudioManagerInk.warning : CareStudioManagerInk.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill((item.needsAttention ? CareStudioManagerInk.warning : Color.black).opacity(0.07)))
                .help(item.statusDetailText ?? item.managementExplanation)
            control
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .background(isHovered ? Color.black.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(item.managementExplanation)
        .contextMenu {
            if let onReveal = actions.onReveal, item.components.contains(where: { $0.actionCapability.canRevealInFinder }) {
                Button(L10n.text("在访达中显示", "Show in Finder")) { onReveal(item) }
            }
            if let onOpen = actions.onOpenParentApplication, item.components.contains(where: { $0.actionCapability.canOpenParentApp }) {
                Button(L10n.text("打开所属应用", "Open Parent App")) { onOpen(item) }
            }
            if let onStop = actions.onStop, allowsMutation,
               let candidate = item.components.first(where: { $0.actionCapability.canStopCurrentSession }) {
                Button(L10n.text("停止本次运行", "Stop for This Session")) { onStop(candidate) }
            }
            if let onCopy = actions.onCopyText {
                Button(L10n.text("拷贝名称", "Copy Name")) { onCopy(item.displayName) }
            }
        }
#if DEBUG
        .layoutProbe("careStudio.startup.row")
#endif
    }

    @ViewBuilder
    private var icon: some View {
        if let path = item.applicationIconPath {
            CachedAppIconView(path: path, size: 30) { fallbackIcon }
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: item.fallbackSystemImage)
            .font(.system(size: 18))
            .foregroundStyle(CareStudioManagerInk.secondary)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.05)))
    }

    @ViewBuilder
    private var control: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else if let candidate = switchCandidate, allowsMutation {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if newValue { actions.onEnable?(candidate) } else { actions.onDisable?(candidate) }
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(CareStudioManagerInk.accent)
                .labelsHidden()
                .accessibilityLabel(item.displayName)
        } else if item.isSystemSettingsOnly, let open = actions.onOpenSystemSettings {
            Button(L10n.text("系统设置", "Settings"), action: open)
                .buttonStyle(CareStudioRowButtonStyle())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.accent)
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(CareStudioManagerInk.secondary)
                .help(L10n.text("受保护或归属不明，只能查看", "Protected or unattributed; view only"))
        }
    }
}
