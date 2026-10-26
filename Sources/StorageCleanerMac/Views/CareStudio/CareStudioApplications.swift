import AppKit
import SwiftUI

/// D154: the Applications module on the studio pages, following CleanMyMac
/// 5.7.2's flow (D151's logic is unchanged): landing → reading the apps →
/// result tiles → Applications Manager → removing → done. Every action keeps
/// D151's rules: everything moves to the Trash with a receipt per app.

/// Landing and reading page of the module.
struct CareStudioApplicationsStart: View {
    @ObservedObject var store: ScanStore

    var body: some View {
        if store.isLoadingInstalledApps {
            CareStudioRunningPage(
                module: .applications,
                detail: L10n.text("正在读取 /Applications 和 ~/Applications 里的应用", "Reading apps in /Applications and ~/Applications"),
                headlineValue: store.installedApps.isEmpty ? nil
                    : L10n.text("已找到 \(ByteFormat.count(store.installedApps.count)) 个应用", "\(ByteFormat.count(store.installedApps.count)) apps found"),
                canStop: false,
                footnote: L10n.text("只读扫描 · 卸载前逐项确认", "Read-only scan · Every uninstall is confirmed"),
                onStop: {})
        } else {
            CareStudioLandingPage(
                module: .applications,
                bullets: [
                    CareStudioBullet(id: "uninstaller", title: L10n.text("卸载程序", "Uninstaller"), systemImage: "trash",
                                     hint: L10n.text("应用连同它的支持文件、缓存和登录项", "Apps with their support files, caches and login items")),
                    CareStudioBullet(id: "updater", title: L10n.text("应用更新", "Updater"), systemImage: "arrow.triangle.2.circlepath",
                                     hint: L10n.text("来自可信来源的新版本", "New versions from trusted sources")),
                    CareStudioBullet(id: "leftovers", title: L10n.text("残留清理", "Leftovers"), systemImage: "sparkles",
                                     hint: L10n.text("以前卸载剩下的文件和安装包", "What earlier uninstalls left, and installers"))
                ],
                footnote: L10n.text("只读扫描 · 全部移到废纸篓、可以恢复", "Read-only scan · Everything goes to the Trash and can be restored"),
                actionTitle: L10n.text("扫描", "Scan"),
                actionEnabled: store.canRefreshInstalledApps,
                actionHint: L10n.text("读取这台 Mac 上的应用和它们的相关文件", "Reads the apps on this Mac and their related files"),
                action: { store.applicationsScanCoordinator.start(store: store) })
        }
    }
}

/// The result tiles (CleanMyMac's Applications results): one tile per
/// finding with its action and Review, and "Manage My Applications".
struct CareStudioApplicationsOverview: View {
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
#else
    /// Release builds have no presentation fixtures (the key is DEBUG-only).
    private let isFixture = false
#endif
    @ObservedObject var model: ApplicationsManagerModel
    @ObservedObject var store: ScanStore
    /// D154 batch 2: the D160 extensions inventory, read with the apps.
    @ObservedObject private var applicationsScan: ApplicationsScanCoordinator
    @ObservedObject private var extensions: ExtensionManagerStore
    let showHistory: () -> Void
    @State private var systemUpdates: [SystemSoftwareUpdate] = []

    init(model: ApplicationsManagerModel, store: ScanStore, showHistory: @escaping () -> Void) {
        self.model = model
        self.store = store
        self.showHistory = showHistory
        _applicationsScan = ObservedObject(wrappedValue: store.applicationsScanCoordinator)
        _extensions = ObservedObject(wrappedValue: ToolboxStores.of(store).extensions)
    }

    var body: some View {
        // Item 12: Start Over in the title bar goes back to the landing page,
        // whose Scan reads the apps again (was Scan Again here); Uninstall
        // History moves to the right of this row.
        CareStudioPageFrame(module: .applications,
                            titleBar: .startOver(CareStudioStartOver(activity: store.heavyWorkActivityStore,
                                                                     isEnabled: store.canRefreshInstalledApps,
                                                                     action: {
                                                                         model.startOver()
                                                                         store.startOverInstalledApps()
                                                                     })),
                            footnote: L10n.text("移到废纸篓 · 可在“操作记录”恢复", "Moves to the Trash · Restorable from Operation History")) {
            GeometryReader { proxy in
                let compact = proxy.size.height < 560
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Spacer()
                        if model.isLoadingResources || model.isScanningLeftovers {
                            CareStudioSpinningArc(diameter: 12, lineWidth: 1.6)
                                .help(L10n.text("正在后台读取相关文件", "Reading related files in the background"))
                        }
                        CareStudioPillButton(title: L10n.text("卸载记录", "Uninstall History"),
                                             systemImage: "clock.arrow.circlepath", compact: true, action: showHistory)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, compact ? 8 : 12)
                    Text(L10n.text("这台 Mac 上有 \(ByteFormat.count(model.entries.count)) 个应用。", "There are \(ByteFormat.count(model.entries.count)) apps on this Mac."))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(CareStudioInk.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, compact ? 4 : 18)
                        .accessibilityAddTraits(.isHeader)
                    CareStudioPillButton(title: L10n.text("管理我的应用", "Manage My Applications")) { model.review(.all) }
                        .padding(.top, compact ? 8 : 12)
                    CareStudioTileGrid(tiles: tiles)
                        .padding(.horizontal, CareStudioMetrics.pageInset)
                        .padding(.top, compact ? 10 : 18)
                        .padding(.bottom, compact ? 6 : 12)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        } action: {
            EmptyView()
        }
        .task {
            // The extensions list is a read-only `pluginkit` listing (D160),
            // read once with the apps, as CleanMyMac lists them in its results.
            if !isFixture, extensions.inventory == nil, !extensions.isBusy { extensions.scan() }
            systemUpdates = await Task.detached(priority: .utility) { SystemSoftwareUpdateStatus.recommendedUpdates() }.value
        }
#if DEBUG
        .layoutProbe("careStudio.results.applications")
#endif
    }

    /// The updater's last count of available updates.
    private var availableUpdateCount: Int? { store.availableAppUpdateCount }

    private var browsing: Bool { model.phase == .browsing }

    private var tiles: [CareStudioTileModel] {
        var tiles: [CareStudioTileModel] = []
        if store.isLoadingAppUpdates {
            tiles.append(CareStudioTileModel(
                id: "updates", module: .applications,
                title: L10n.text("正在检查更新…", "Checking for updates…"),
                note: L10n.text("正在从可信来源检查新版本，完成后会在这里显示。",
                                "Checking trusted sources for new versions; results will appear here."),
                systemImage: "arrow.triangle.2.circlepath",
                reviewTitle: L10n.text("查看", "Review"), onReview: { store.showFilter(.updater) }, art: .tileAppUpdates))
        } else if applicationsScan.permitsUpdateTile(lastScannedAt: store.appUpdatesLastScannedAt),
                  let updates = availableUpdateCount, updates > 0 {
            tiles.append(CareStudioTileModel(
                id: "updates", module: .applications,
                title: L10n.text("应用更新", "App Updates"),
                value: ByteFormat.count(updates),
                valueCaption: L10n.text("个应用有新版本", updates == 1 ? "app has a new version" : "apps have a new version"),
                detail: L10n.text("新版本通常带来修复和更好的兼容性；更新前会先确认来源和签名。",
                                  "New versions usually bring fixes and better compatibility; the source and signature are checked first."),
                systemImage: "arrow.triangle.2.circlepath",
                reviewTitle: L10n.text("查看", "Review"), onReview: { store.showFilter(.updater) },
                cleanTitle: L10n.text("更新", "Update"), cleanEnabled: browsing, onClean: { store.showFilter(.updater) },
                art: .tileAppUpdates))
        }
        if !model.unusedEntries.isEmpty {
            tiles.append(CareStudioTileModel(
                id: "unused", module: .applications,
                title: L10n.text("长期未用的应用", "Unused Applications"),
                value: ByteFormat.count(model.unusedEntries.count),
                valueCaption: L10n.text("个应用超过半年没有打开", "apps not opened for over six months"),
                detail: L10n.text("半年多没打开过的应用。确实用不到的，可以连同相关文件一起卸载。",
                                  "Apps not opened for more than six months. If you don't need them, uninstall them with their files."),
                systemImage: "hourglass",
                reviewTitle: L10n.text("查看", "Review"), onReview: { model.review(.unused) },
                cleanTitle: L10n.text("卸载", "Uninstall"), cleanEnabled: browsing, onClean: { model.runTile(.unused) }, art: .tileUnused))
        }
        if model.isScanningLeftovers {
            tiles.append(CareStudioTileModel(
                id: "leftovers", module: .applications,
                title: L10n.text("正在查找残留…", "Looking for leftovers…"),
                note: L10n.text("后台仍在查找以前卸载的应用留下的文件，稍候会出现在这里。",
                                "Files left by apps uninstalled earlier are still being looked for in the background."),
                systemImage: "sparkles",
                reviewTitle: L10n.text("查看", "Review"), onReview: { model.review(.leftovers) }, art: .tileLeftovers))
        } else if !model.leftovers.isEmpty {
            tiles.append(CareStudioTileModel(
                id: "leftovers", module: .applications,
                title: L10n.text("应用残留", "App Leftovers"),
                value: ByteFormat.storageString(model.leftoverBytes),
                valueCaption: L10n.text("\(ByteFormat.count(model.leftovers.count)) 个已卸载的应用留下的文件", "left by \(ByteFormat.count(model.leftovers.count)) removed apps"),
                systemImage: "sparkles",
                reviewTitle: L10n.text("查看", "Review"), onReview: { model.review(.leftovers) },
                cleanTitle: L10n.text("移除", "Remove"), cleanEnabled: browsing, onClean: { model.runTile(.leftovers) }, art: .tileLeftovers))
        }
        if !model.installers.isEmpty {
            tiles.append(CareStudioTileModel(
                id: "installers", module: .applications,
                title: L10n.text("安装文件", "Installers"),
                value: ByteFormat.storageString(model.installerBytes),
                valueCaption: L10n.text("\(ByteFormat.count(model.installers.count)) 个磁盘映像和安装包", "\(ByteFormat.count(model.installers.count)) disk images and installers"),
                systemImage: "shippingbox",
                reviewTitle: L10n.text("查看", "Review"), onReview: { model.review(.installers) },
                // Report §4 item 13 (`cmm2/01`): Remove only when some
                // installers are preselected; with none, CleanMyMac shows
                // Review alone, and Remove had nothing to remove.
                cleanTitle: model.installers.contains(where: \.preselected) ? L10n.text("移除", "Remove") : nil,
                cleanEnabled: browsing, onClean: { model.runTile(.installers) }, art: .tileInstallers))
        }
        if !model.thirtyTwoBitEntries.isEmpty {
            tiles.append(CareStudioTileModel(
                id: "thirtyTwoBit", module: .applications,
                title: L10n.text("无法运行的旧应用", "Unsupported Applications"),
                value: ByteFormat.count(model.thirtyTwoBitEntries.count),
                valueCaption: L10n.text("个只有 32 位版本的应用", "32-bit-only apps"),
                detail: L10n.text("这台 Mac 运行不了只有 32 位的应用，留着只占空间。",
                                  "This Mac cannot run 32-bit-only apps; they only take up space."),
                systemImage: "exclamationmark.triangle",
                reviewTitle: L10n.text("查看", "Review"), onReview: { model.review(.thirtyTwoBit) },
                cleanTitle: L10n.text("卸载", "Uninstall"), cleanEnabled: browsing, onClean: { model.runTile(.thirtyTwoBit) }, art: .tileLegacyApps))
        }
        if !systemUpdates.isEmpty {
            tiles.append(CareStudioTileModel(
                id: "macOS", module: .applications,
                title: L10n.text("macOS 有更新", "macOS Update Available"),
                valueCaption: L10n.text("在“系统设置”里查看和安装", "Review and install in System Settings"),
                systemImage: "gearshape.arrow.triangle.2.circlepath",
                reviewTitle: L10n.text("查看更新", "View Update"),
                onReview: { NSWorkspace.shared.open(SystemSoftwareUpdateStatus.settingsURL) }, art: .tileSystemUpdate))
        }
        if let summary = extensions.summary, summary.itemCount > 0 {
            tiles.append(CareStudioTileModel(
                id: "extensions", module: .applications,
                title: L10n.text("扩展", "Extensions"),
                value: ByteFormat.count(summary.itemCount),
                valueCaption: summary.obsoleteCount > 0
                    ? L10n.text("个扩展和加载项，\(ByteFormat.count(summary.obsoleteCount)) 个已失效",
                                "extensions and add-ons, \(ByteFormat.count(summary.obsoleteCount)) no longer working")
                    : L10n.text("个应用扩展、插件和加载项", "app extensions, plug-ins and add-ons"),
                detail: L10n.text("输入法、浏览器扩展、快速查看插件等。不用的可以移到废纸篓，能放回。",
                                  "Input methods, browser extensions, Quick Look plug-ins and more. Move the ones you don't use to the Trash; you can put them back."),
                systemImage: "puzzlepiece.extension",
                reviewTitle: L10n.text("查看", "Review"), onReview: { store.showFilter(.extensions) }, art: .extensions))
        } else if extensions.isBusy && extensions.inventory == nil {
            tiles.append(CareStudioTileModel(
                id: "extensions", module: .applications,
                title: L10n.text("正在读取扩展…", "Reading extensions…"),
                note: L10n.text("应用扩展、插件和加载项读完后会出现在这里。",
                                "App extensions, plug-ins and add-ons appear here when read."),
                systemImage: "puzzlepiece.extension",
                reviewTitle: L10n.text("查看", "Review"), onReview: { store.showFilter(.extensions) }, art: .extensions))
        }
        tiles.append(CareStudioTileModel(
            id: "review", module: .applications,
            title: L10n.text("挑出用不到的应用", "Apps You May Not Need"),
            value: ByteFormat.count(model.entries.count),
            valueCaption: L10n.text("个应用，按大小或上次打开时间排列", "apps, by size or last opened"),
            systemImage: "square.grid.2x2",
            reviewTitle: L10n.text("查看", "Review"), onReview: { model.review(.all) }, art: .tilePickApps))
        return tiles
    }
}

/// CleanMyMac's removing page: the picture works, the title says what is
/// being removed, the ring follows the apps.
struct CareStudioApplicationsRemoving: View {
    let current: String
    let index: Int
    let total: Int
    let leftovers: Bool

    var body: some View {
        CareStudioRunningPage(
            module: .applications,
            title: leftovers ? L10n.text("正在移除残留文件…", "Removing leftovers…")
                             : L10n.text("正在卸载应用…", "Uninstalling applications…"),
            detail: current,
            headlineValue: L10n.text("第 \(ByteFormat.count(min(index + 1, total))) 个，共 \(ByteFormat.count(total)) 个", "\(ByteFormat.count(min(index + 1, total))) of \(ByteFormat.count(total))"),
            progress: .fraction(total > 0 ? Double(index) / Double(total) : 0),
            canStop: false,
            footnote: L10n.text("移到废纸篓 · 每个应用一份回执", "Moves to the Trash · One receipt per app"),
            onStop: {})
    }
}

/// CleanMyMac's done page: the picture turns to the success mark, the
/// title and what moved, then "Applications Log" and "Manage More Items".
struct CareStudioApplicationsCompletion: View {
    @ObservedObject var model: ApplicationsManagerModel
    let showLog: () -> Void

    var body: some View {
        CareStudioPageFrame(module: .applications, footnote: model.completionFootnote) {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    CareStudioArt(module: .applications, side: max(96, min(220, proxy.size.height * 0.36)),
                                  showsSuccess: model.completionSucceeded)
                    Text(model.completionTitle)
                        .font(.system(size: CareStudioMetrics.runningTitleSize, weight: .regular))
                        .foregroundStyle(CareStudioInk.primary)
                        .padding(.top, 16)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.completionDescription)
                        .font(.system(size: 15))
                        .foregroundStyle(CareStudioInk.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                        .padding(.top, 8)
                    HStack(spacing: 10) {
                        // A removal that did not start ran nothing: no log; Back keeps the selection.
                        if model.startFailure == nil {
                            CareStudioPillButton(title: L10n.text("应用日志", "Applications Log"), systemImage: "doc.text", action: showLog)
                        }
                        CareStudioPillButton(title: model.startFailure == nil ? L10n.text("管理更多项目", "Manage More Items")
                                                                              : L10n.text("返回", "Back"),
                                             filled: true) { model.returnToBrowsing() }
                    }
                    .padding(.top, 18)
                    Spacer(minLength: 8)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } action: {
            EmptyView()
        }
        .onAppear {
            if model.completionSucceeded, model.outcomes.contains(where: { $0.removedCount > 0 }) {
                AppLifecycleSounds.playEmptyTrash()
            }
        }
#if DEBUG
        .layoutProbe("careStudio.done.applications")
#endif
    }
}

extension ApplicationCategory {
    /// D166: the manager's category objects.
    var studioArt: GeneratedArt {
        switch self {
        case .all: .applications
        case .unused: .tileUnused
        case .suspicious: .tileAttention
        case .selected: .tileCount
        case .store(.appStore): .tileAppStore
        case .store: .tileOtherSources
        case .vendor: .tileVendors
        case .audioPlugins: .extensions
        case .thirtyTwoBit: .tileLegacyApps
        case .leftovers: .tileLeftovers
        case .installers: .tileInstallers
        case .otherLocations: .tileOtherSources
        }
    }

    /// The category's icon in the manager's left column.
    var studioSymbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .unused: "hourglass"
        case .suspicious: "exclamationmark.shield"
        case .selected: "checkmark.circle"
        case .store: "bag"
        case .vendor: "building.2"
        case .audioPlugins: "waveform"
        case .thirtyTwoBit: "exclamationmark.triangle"
        case .leftovers: "sparkles"
        case .installers: "shippingbox"
        case .otherLocations: "folder"
        }
    }
}

extension ScanStore {
    /// The updater's last count of available updates; the Applications
    /// results and Smart Care's card (D168) read the same number.
    /// D190: only confirmed newer versions (was every catalog row, or the sum
    /// of the four categories, which also counted in-app updaters with an
    /// unknown latest version: 10-23 the tile said 82 against the updater's 65).
    var availableAppUpdateCount: Int? {
        switch appUpdatePresentationState {
        case .managing(let catalog): return catalog.confirmedUpdateCount
        case .scanSummary(let summary): return summary.confirmedUpdateCount
        case .idle(let summary?): return summary.confirmedUpdateCount
        default: return nil
        }
    }
}
