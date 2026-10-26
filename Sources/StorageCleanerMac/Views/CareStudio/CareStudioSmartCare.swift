import SwiftUI

/// D168: how each Smart Care module looks — its studio module and colour,
/// its picture (the module's own, as on the sidebar) and the page "Review"
/// opens.
extension SmartCareModule {
    var studioModule: CareStudioModule {
        switch self {
        case .cleanup: .cleanup
        case .protection: .protection
        case .performance: .startup
        case .applications: .updater
        case .clutter: .clutter
        }
    }

    var art: GeneratedArt { studioModule.family.art }

    var landingSymbol: String {
        switch self {
        case .cleanup: "trash.fill"
        case .protection: "hand.raised.fill"
        case .performance: "gauge.with.dots.needle.67percent"
        case .applications: "arrow.down.app.fill"
        case .clutter: "doc.on.doc.fill"
        }
    }

    var scanningLine: String {
        switch self {
        case .cleanup: L10n.text("正在查找垃圾…", "Looking for junk…")
        case .protection: L10n.text("正在读取浏览记录…", "Reading browsing records…")
        case .performance: L10n.text("正在检查维护任务和登录项…", "Checking maintenance tasks and login items…")
        case .applications: L10n.text("正在检查应用更新…", "Checking for app updates…")
        case .clutter: L10n.text("正在查找重复文件…", "Looking for duplicate files…")
        }
    }
}

/// What one card says, read from its module (so a review that changes the
/// selection shows at once). Report §4 item 14: CleanMyMac's result in one
/// large line and what it is for, "73 GB of junk" / "to clean" (`cmm/14`;
/// was a value with a caption, "11.6 GB" / "垃圾 · 可清理").
struct SmartCareCardSummary: Equatable {
    var headline: String
    var subtitle: String? = nil
    /// Run would do something for it (D168: cleanup with ticked items).
    var isRunnable = false
    /// The card offers Review: not when nothing was found (CleanMyMac's
    /// "No vital updates" has none) or the module is off.
    var reviews = true

    /// The two as one line (`headline · subtitle`).
    var line: String { [headline, subtitle].compactMap { $0 }.joined(separator: " · ") }
}

@MainActor
enum SmartCareSummaries {
    static func summary(for module: SmartCareModule, state: SmartCareCardState,
                        store: ScanStore, privacy: BrowserPrivacyStore?) -> SmartCareCardSummary {
        switch state {
        case .off: return SmartCareCardSummary(headline: L10n.text("已关闭", "Off"), reviews: false)
        case .waiting: return SmartCareCardSummary(headline: L10n.text("正在等待…", "Waiting…"), reviews: false)
        case .scanning: return SmartCareCardSummary(headline: module.scanningLine, reviews: false)
        case .skipped(let reason): return SmartCareCardSummary(headline: reason)
        case .failed(let message): return SmartCareCardSummary(headline: message)
        case .stopped: return SmartCareCardSummary(headline: L10n.text("已停止", "Stopped"))
        case .done: return found(module, store: store, privacy: privacy)
        }
    }

    /// Nothing found: CleanMyMac's "No vital updates" / "to install".
    private static func nothing(_ headline: String, _ subtitle: String) -> SmartCareCardSummary {
        SmartCareCardSummary(headline: headline, subtitle: subtitle, reviews: false)
    }

    private static func found(_ module: SmartCareModule, store: ScanStore,
                              privacy: BrowserPrivacyStore?) -> SmartCareCardSummary {
        switch module {
        case .cleanup:
            guard let session = store.cleanupScanSession else {
                return SmartCareCardSummary(headline: L10n.text("没有结果", "No result"))
            }
            let summaries = CareJunkGrouping.summaries(for: session, filter: .overview)
            let junk = CleanupByteCount.sum(summaries.filter { $0.group != .filesToReview }.map(\.totalBytes)
                                            + [SystemCachePresentation.bytes(store.systemCacheInventory)])
            let review = CleanupByteCount.sum(summaries.filter { $0.group == .filesToReview }.map(\.totalBytes))
            let ticked = summaries.flatMap(\.candidates).contains {
                store.cleanupSelection.selectedCandidateIDs.contains($0.id)
            }
            if junk > 0 {
                let bytes = ByteFormat.storageString(junk)
                return SmartCareCardSummary(headline: L10n.text("\(bytes) 垃圾", "\(bytes) of junk"),
                                            subtitle: L10n.text("可清理", "to clean"),
                                            isRunnable: ticked && store.canRequestV2Cleanup)
            }
            if review > 0 {
                let bytes = ByteFormat.storageString(review)
                return SmartCareCardSummary(headline: L10n.text("\(bytes) 待确认文件", "\(bytes) of files"),
                                            subtitle: L10n.text("待查看", "to review"),
                                            isRunnable: ticked && store.canRequestV2Cleanup)
            }
            return nothing(L10n.text("没有垃圾", "No junk"), L10n.text("不用清理", "to clean"))
        case .protection:
            guard let privacy else { return SmartCareCardSummary(headline: L10n.text("没有结果", "No result")) }
            if privacy.state == .permissionDenied {
                return SmartCareCardSummary(headline: L10n.text("需要完全磁盘访问权限", "Needs Full Disk Access"))
            }
            let count = privacy.records.count
            return count > 0
                ? SmartCareCardSummary(
                    headline: L10n.text("\(ByteFormat.count(count)) 条浏览记录",
                                        L10n.englishCount(count, "browsing record", "browsing records")),
                    subtitle: L10n.text("待查看", "to review"))
                : nothing(L10n.text("没有浏览记录", "No browsing records"), L10n.text("不用清理", "to clean"))
        case .performance:
            let maintenance = ToolboxStores.of(store).maintenance
            let tasks = maintenance.summary.recommendedCount
            let reading = StartupReadPresentation(coverage: store.startupCoverage)
            let startup = StartupItemsPresentation.make(items: store.startupDomainItems, query: "", category: .all,
                                                       status: .all, source: .all, includeAppleSystem: false,
                                                       sort: .recommended, includeTechnicalDetails: false)
            let background = startup.count(for: .background)
            let backgroundTitle = reading.backgroundTitle(count: background)
            guard reading.isAvailable else {
                return SmartCareCardSummary(headline: background > 0 ? backgroundTitle : reading.unreadLoginTitle,
                    subtitle: background > 0 ? reading.unreadLoginTitle + " · " + reading.unreadReason : reading.unreadReason,
                    isRunnable: tasks > 0 && !maintenance.selectedTasks.isEmpty && !maintenance.isRunning)
            }
            if tasks > 0 {
                return SmartCareCardSummary(
                    headline: L10n.text("\(ByteFormat.count(tasks)) 个维护任务", L10n.englishCount(tasks, "task", "tasks")),
                    subtitle: background > 0 ? L10n.text("可运行", "to run") + " · " + backgroundTitle : L10n.text("可运行", "to run"),
                    isRunnable: !maintenance.selectedTasks.isEmpty && !maintenance.isRunning)
            }
            let logins = startup.count(for: .loginItems)
            return logins > 0
                ? SmartCareCardSummary(
                    headline: L10n.text("\(ByteFormat.count(logins)) 个登录项", L10n.englishCount(logins, "login item", "login items")),
                    subtitle: background > 0 ? L10n.text("待查看", "to review") + " · " + backgroundTitle : L10n.text("待查看", "to review"))
                : background > 0 ? SmartCareCardSummary(headline: backgroundTitle, subtitle: L10n.text("待查看", "to review"))
                    : nothing(L10n.text("没有维护任务", "No tasks"), L10n.text("不用运行", "to run"))
        case .applications:
            guard let count = store.availableAppUpdateCount else {
                return SmartCareCardSummary(headline: L10n.text("没有读到更新", "No update result"))
            }
            return count > 0
                ? SmartCareCardSummary(
                    headline: L10n.text("\(ByteFormat.count(count)) 个更新", L10n.englishCount(count, "update", "updates")),
                    subtitle: L10n.text("可安装", "to install"))
                : nothing(L10n.text("没有更新", "No updates"), L10n.text("不用安装", "to install"))
        case .clutter:
            let groups = store.duplicateFilesWorkspace.exactGroups.count
            return groups > 0
                ? SmartCareCardSummary(
                    headline: L10n.text("\(ByteFormat.count(groups)) 组重复文件",
                                        L10n.englishCount(groups, "group of duplicates", "groups of duplicates")),
                    subtitle: L10n.text("待查看", "to review"))
                : nothing(L10n.text("没有重复文件", "No duplicates"), L10n.text("不用处理", "to review"))
        }
    }
}

/// D168: Smart Care scanning; Stop ends the module that is scanning and
/// skips the rest. Report §4 item 15 (CleanMyMac, `1比1对照-20261023/cmm/11`–`13`):
/// the page is the results' five cards filling in, the one scanning grown
/// (`SmartCareScanningCollage`), and the round button shows how many parts
/// ended. Was: the running page's picture and title with a row of five
/// small cards under it.
struct SmartCareScanningPage: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var smartCare: SmartCareCoordinator
    let privacy: BrowserPrivacyStore?
    @State private var confirmsStop = false

    private var current: SmartCareModule? {
        if case .scanning(let module) = smartCare.stage { return module }
        return nil
    }

    private var finishedCount: Int {
        SmartCareModule.allCases.filter { smartCare.selection.contains($0) }
            .filter { ![.waiting, .scanning].contains(smartCare.card($0)) }.count
    }

    var body: some View {
        let total = max(1, smartCare.selection.count)
        CareStudioPageFrame(module: .smartScan, isWorking: true,
                            footnote: L10n.text("只读扫描 · 不会删除任何文件", "Read-only scan · Nothing is removed")) {
            SmartCareScanningCollage(store: store, smartCare: smartCare, privacy: privacy)
                .padding(.horizontal, CareStudioMetrics.pageInset)
                .padding(.top, 18)
        } action: {
            CareStudioActionButton(module: .smartScan, title: L10n.text("停止", "Stop"),
                                   progress: .fraction(Double(finishedCount) / Double(total)),
                                   action: { confirmsStop = true })
                .disabled(current == nil)
        }
        .confirmationDialog(L10n.text("停止扫描？", "Stop Scanning?"), isPresented: $confirmsStop,
                            titleVisibility: .visible) {
            Button(L10n.text("继续扫描", "Continue Scanning"), role: .cancel) {}
            Button(L10n.text("停止", "Stop"), role: .destructive, action: smartCare.stop)
        } message: {
            Text(L10n.text("已扫描完的模块保留结果，其余的不再扫描。",
                           "Modules already scanned keep their results; the rest are skipped."))
        }
    }
}

/// Item 15: the five cards while Smart Care scans, three above and two below
/// as on the results. The card scanning grows in its row and its row grows
/// in the page (CleanMyMac: 392 pt against 169 pt, 599 pt against 210 pt in
/// its 1200 × 720 window); the others give way, and each one that is done
/// shows its result. A short window scrolls the cards in their own area, as
/// the results do.
struct SmartCareScanningCollage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    @ObservedObject var smartCare: SmartCareCoordinator
    let privacy: BrowserPrivacyStore?

    private var current: SmartCareModule? {
        if case .scanning(let module) = smartCare.stage { return module }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let modules = SmartCareModule.allCases
            let index = current.flatMap { modules.firstIndex(of: $0) }
            let room = CGSize(width: proxy.size.width, height: max(proxy.size.height, Self.minimumHeight))
            let frames = Self.frames(count: modules.count, current: index, in: room)
            if room.height > proxy.size.height + 0.5 {
                ScrollView(.vertical) {
                    cards(modules, frames).frame(width: room.width, height: room.height, alignment: .topLeading)
                }
#if DEBUG
                .layoutProbe("careStudio.tiles.scroll")
#endif
            } else {
                cards(modules, frames).frame(width: room.width, height: room.height, alignment: .topLeading)
            }
        }
#if DEBUG
        .layoutProbe("careStudio.tiles")
#endif
    }

    private func cards(_ modules: [SmartCareModule], _ frames: [CGRect]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(modules.enumerated()), id: \.element) { index, module in
                if index < frames.count {
                    card(module)
                        .frame(width: frames[index].width, height: frames[index].height)
                        .offset(x: frames[index].minX, y: frames[index].minY)
                }
            }
        }
        .animation(AppMotion.resolved(.standard, reduceMotion: reduceMotion), value: current)
    }

    @ViewBuilder
    private func card(_ module: SmartCareModule) -> some View {
        let state = smartCare.card(module)
        switch state {
        case .scanning:
            SmartCareScanningCard(module: module, detail: detail(module))
        case .waiting, .off:
            SmartCareWaitingCard(module: module, isOff: state == .off)
        case .done, .skipped, .failed, .stopped:
            SmartCareResultCard(model: SmartCareResultCardModel(
                module: module,
                summary: SmartCareSummaries.summary(for: module, state: state, store: store, privacy: privacy)))
        }
    }

    /// Where the scan is: the junk scan's path, otherwise what the part reads.
    private func detail(_ module: SmartCareModule) -> String {
        if module == .cleanup, let path = store.mainScanProgress?.currentPath, !path.isEmpty { return path }
        return module.scope
    }

    /// The least the two rows need before the cards scroll.
    static let minimumHeight: CGFloat = 380

    /// The cards' frames: three in the first row and the rest in the second;
    /// the row with the card scanning takes 70 % of the height, and in it
    /// that card takes 58 % of the width beside two cards and 67 % beside
    /// one. Without a card scanning the rows and the cards share evenly.
    static func frames(count: Int, current: Int?, in size: CGSize) -> [CGRect] {
        guard count > 0, size.width > 0, size.height > 0 else { return [] }
        let gap = CareStudioMetrics.tileSpacing
        let rows = [Array(0..<min(3, count)), Array(min(3, count)..<count)].filter { !$0.isEmpty }
        let currentRow = current.flatMap { current in rows.firstIndex { $0.contains(current) } }
        let height = size.height - CGFloat(rows.count - 1) * gap
        var frames = Array(repeating: CGRect.zero, count: count)
        var y: CGFloat = 0
        for (row, members) in rows.enumerated() {
            let rowHeight = rows.count == 2 && currentRow != nil
                ? height * (row == currentRow ? 0.7 : 0.3)
                : height / CGFloat(rows.count)
            let width = size.width - CGFloat(members.count - 1) * gap
            let share: CGFloat = members.count == 3 ? 0.58 : 0.67
            var x: CGFloat = 0
            for member in members {
                let cardWidth: CGFloat
                if let current, members.contains(current), members.count > 1 {
                    cardWidth = member == current ? width * share : width * (1 - share) / CGFloat(members.count - 1)
                } else {
                    cardWidth = width / CGFloat(members.count)
                }
                frames[member] = CGRect(x: x, y: y, width: cardWidth, height: rowHeight)
                x += cardWidth + gap
            }
            y += rowHeight + gap
        }
        return frames
    }
}

/// The card scanning (`cmm/11`–`13`): its module's colour rising from the
/// bottom, what the part does in large type, its picture, and where it is.
struct SmartCareScanningCard: View {
    let module: SmartCareModule
    let detail: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
        let glow = CareStudioPalette.color(module.studioModule.palette.actionGlow)
        GeometryReader { proxy in
            let side = max(48, min(220, proxy.size.height * 0.46, proxy.size.width * 0.5))
            VStack(spacing: 0) {
                Text(module.scanningLine)
                    .font(.system(size: proxy.size.height < 240 ? 22 : 30, weight: .medium))
                    .foregroundStyle(CareStudioInk.primary)
                    .lineLimit(1)
                    .padding(.horizontal, CareStudioMetrics.tilePadding)
                    .padding(.top, CareStudioMetrics.tilePadding)
                Spacer(minLength: 6)
                FeatureLightfieldArtwork(art: module.art, variant: .landing)
                    .hueRotation(module.studioModule.family.hueRotation(for: module.art))
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: side, height: side)
                    .shadow(color: CareStudioPalette.color(module.studioModule.palette.deep, opacity: 0.45), radius: 14, y: 8)
                Spacer(minLength: 6)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(CareStudioInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, CareStudioMetrics.tilePadding)
                    .padding(.bottom, CareStudioMetrics.tilePadding)
                    .help(detail)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(shape.fill(LinearGradient(colors: [glow.opacity(0.10), glow.opacity(0.55)],
                                              startPoint: .top, endPoint: .bottom)))
        .overlay(shape.strokeBorder(CareStudioInk.hairline, lineWidth: 1))
        .clipShape(shape)
        .accessibilityElement(children: .combine)
#if DEBUG
        .layoutProbe("careStudio.tile.\(module.rawValue)")
#endif
    }
}

/// A card waiting its turn, or a part that is off: its name and its picture,
/// large and faint (`cmm/11`).
struct SmartCareWaitingCard: View {
    let module: SmartCareModule
    let isOff: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height) * 0.72
            ZStack(alignment: .topLeading) {
                shape.fill(LinearGradient(colors: [CareStudioInk.tileFill, CareStudioInk.tileFill.opacity(0.6)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                FeatureLightfieldArtwork(art: module.art, variant: .landing)
                    .hueRotation(module.studioModule.family.hueRotation(for: module.art))
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: side, height: side)
                    .opacity(isOff ? 0.2 : 0.45)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.5 + side * 0.28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(CareStudioInk.primary)
                        .lineLimit(1)
                    if isOff {
                        Text(L10n.text("已关闭", "Off"))
                            .font(.system(size: 13))
                            .foregroundStyle(CareStudioInk.secondary)
                    }
                }
                .padding(CareStudioMetrics.tilePadding)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(CareStudioInk.hairline, lineWidth: 1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOff ? L10n.text("已关闭", "Off") : L10n.text("正在等待", "Waiting"))
#if DEBUG
        .layoutProbe("careStudio.tile.\(module.rawValue)")
#endif
    }
}

/// D168: Smart Care results — CleanMyMac's five cards, three above and two
/// below (report §4 item 14, `cmm/14`; was cleanup on the left and the other
/// four beside it). Ticked cards take part in Run; a card that found
/// something opens its module to review. Cleanup's review is its manager,
/// here, so a changed selection is what Run cleans.
struct SmartCareResultsPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    @ObservedObject var smartCare: SmartCareCoordinator
    let privacy: BrowserPrivacyStore?
    @State private var runsCleanup = true
    @State private var runsMaintenance = true
    @State private var confirmsMaintenance = false
    @State private var showsJunkManager = false

    private var junkSummaries: [CareJunkGroupSummary] {
        guard let session = store.cleanupScanSession else { return [] }
        return CareJunkGrouping.summaries(for: session, filter: .overview)
    }

    private func summary(_ module: SmartCareModule) -> SmartCareCardSummary {
        SmartCareSummaries.summary(for: module, state: smartCare.card(module), store: store, privacy: privacy)
    }

    private var cleanupRuns: Bool {
        runsCleanup && smartCare.card(.cleanup) == .done && summary(.cleanup).isRunnable
    }

    private var maintenanceRuns: Bool {
        runsMaintenance && smartCare.card(.performance) == .done && summary(.performance).isRunnable
    }

    var body: some View {
        Group {
            if showsJunkManager, let session = store.cleanupScanSession {
                CareStudioJunkManager(store: store, module: .cleanup, session: session,
                                      summaries: junkSummaries, focus: nil,
                                      onBack: { withAnimation(CareStudioMotion.animation(0.2, reduceMotion: reduceMotion)) { showsJunkManager = false } })
                    .transition(.opacity)
            } else {
                // Item 12: Start Over sits in the title bar (was a pill above the title).
                CareStudioPageFrame(module: .smartScan,
                                    titleBar: .startOver(CareStudioStartOver(activity: store.heavyWorkActivityStore,
                                                                             isEnabled: !smartCare.isRunning,
                                                                             action: startOver)),
                                    footnote: L10n.text("清理前逐项确认 · 文件移入废纸篓可恢复",
                                                        "Every item is confirmed · Files move to the Trash")) {
                    content
                } action: {
                    CareStudioActionButton(
                        module: .smartScan, title: L10n.text("运行", "Run"),
                        accessibilityHint: L10n.text("清理勾选的垃圾、运行勾选的维护任务，执行前都会再确认",
                                                     "Cleans the ticked junk and runs the ticked maintenance tasks, each after a confirmation"),
                        action: run)
                        .disabled(!(cleanupRuns || maintenanceRuns) || smartCare.isRunning)
                        .keyboardShortcut(.defaultAction)
                }
                .transition(.opacity)
            }
        }
        .maintenanceRunConfirmation(ToolboxStores.of(store).maintenance, isPresented: $confirmsMaintenance) {
            // Batch 3M: the tasks confirmed now are the ones that run.
            smartCare.run(cleanup: cleanupRuns, maintenanceTasks: ToolboxStores.of(store).maintenance.selectedTasks)
        }
        .careStudioOwnerQuitDialog(store: store)
        .careStudioRefreshesRunningOwners(store: store)
#if DEBUG
        .layoutProbe("smartCare.results")
#endif
    }

    /// Item 14: the title centred over the cards, as the module results'
    /// headlines are (was 26 pt light, on the left).
    private var content: some View {
        VStack(spacing: 18) {
            Text(L10n.text("扫描好了，看看发现了什么：", "The scan is done. Here is what we found:"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(CareStudioInk.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
#if DEBUG
                .layoutProbe("smartCare.results.title")
#endif
            SmartCareResultsGrid(cards: SmartCareModule.allCases.map(card))
        }
        .padding(.horizontal, CareStudioMetrics.pageInset)
        .padding(.top, 18)
    }

    private func card(_ module: SmartCareModule) -> SmartCareResultCardModel {
        let summary = summary(module)
        let ticks = module.takesPartInRun && summary.isRunnable && smartCare.card(module) == .done
        let ticked = module == .cleanup ? runsCleanup : runsMaintenance
        return SmartCareResultCardModel(
            module: module, summary: summary,
            tick: ticks ? (ticked ? .checked : .unchecked) : nil,
            onTick: ticks ? { if module == .cleanup { runsCleanup.toggle() } else { runsMaintenance.toggle() } } : nil,
            onReview: summary.reviews ? { review(module) } : nil)
    }

    /// D202: Review shows Smart Care's own result; the module pages it opens
    /// show it only for this Review, with the sidebar on Smart Care.
    private func review(_ module: SmartCareModule) {
        switch module {
        case .cleanup:
            guard store.cleanupScanSession != nil else { return store.showFilter(.green) }
            withAnimation(CareStudioMotion.animation(0.2, reduceMotion: reduceMotion)) { showsJunkManager = true }
        case .performance:
            store.showSmartCareReview(ToolboxStores.of(store).maintenance.summary.recommendedCount > 0
                                      ? .maintenance : .startup, part: .performance)
        case .protection: store.showSmartCareReview(.privacy, part: .protection)
        case .applications: store.showSmartCareReview(.updater, part: .applications)
        case .clutter: store.showSmartCareReview(.duplicates, part: .clutter)
        }
    }

    /// D168: Run asks the maintenance page's question first, then cleans
    /// the ticked junk through its plan and confirmation sheet, then runs the
    /// tasks; nothing starts before the user has answered both.
    private func run() {
        guard !smartCare.isRunning else { return }
        if maintenanceRuns {
            confirmsMaintenance = true
        } else if cleanupRuns {
            smartCare.run(cleanup: true, maintenanceTasks: [])
        }
    }

    /// D202: clears Smart Care's own results only.
    private func startOver() {
        smartCare.reset()
        store.clearSmartCareResults(privacy: privacy)
    }
}

/// One of Smart Care's result cards (report §4 item 14).
struct SmartCareResultCardModel: Identifiable {
    let module: SmartCareModule
    let summary: SmartCareCardSummary
    var tick: TriStateSelection? = nil
    var onTick: (() -> Void)? = nil
    /// Review, where the card has something to look at.
    var onReview: (() -> Void)? = nil

    var id: String { module.rawValue }
}

/// Report §4 item 14 (CleanMyMac's Smart Care results, `1比1对照-20261023/cmm/14`):
/// three cards above and the other two, wider, below, every row as tall —
/// 229 pt in CleanMyMac's 720 pt window. In a short window the cards scroll
/// in their own area above the round button, as the module results do.
struct SmartCareResultsGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let cards: [SmartCareResultCardModel]
    /// Set once when the grid appears; each card follows with its own delay.
    @State private var arrived = false

    var body: some View {
        GeometryReader { proxy in
            let frames = Self.frames(count: cards.count, in: proxy.size)
            let height = CareStudioTileGrid.contentHeight(of: frames)
            if height > proxy.size.height + 0.5 {
                ScrollView(.vertical) {
                    cardStack(frames)
                        .frame(width: proxy.size.width, height: height, alignment: .topLeading)
                }
#if DEBUG
                .layoutProbe("careStudio.tiles.scroll")
#endif
            } else {
                cardStack(frames)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .onAppear { if !still { arrived = true } }
#if DEBUG
        .layoutProbe("careStudio.tiles")
#endif
    }

    private var still: Bool { reduceMotion || disablesAnimations }

    private func cardStack(_ frames: [CGRect]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if index < frames.count {
                    SmartCareResultCard(model: card, counted: arrived || still,
                                        countDelay: CareStudioMotion.tileDelay(index))
                        .frame(width: frames[index].width, height: frames[index].height)
                        .modifier(CareStudioTileArrival(index: index, arrived: arrived || still))
                        .offset(x: frames[index].minX, y: frames[index].minY)
                }
            }
        }
    }

    /// CleanMyMac's row; and the least a card needs for its name, two lines
    /// of result, what it is for and Review.
    static let maximumRowHeight: CGFloat = 232
    static let minimumRowHeight: CGFloat = 168

    /// The first three cards in a row, the others in a second row.
    static func frames(count: Int, in size: CGSize) -> [CGRect] {
        guard count > 0, size.width > 0, size.height > 0 else { return [] }
        let gap = CareStudioMetrics.tileSpacing
        let rows = [min(3, count), count - min(3, count)].filter { $0 > 0 }
        let rowHeight = min(maximumRowHeight, max(minimumRowHeight,
                                                  (size.height - CGFloat(rows.count - 1) * gap) / CGFloat(rows.count)))
        var frames: [CGRect] = []
        for (row, columns) in rows.enumerated() {
            let width = (size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            for column in 0..<columns {
                frames.append(CGRect(x: CGFloat(column) * (width + gap), y: CGFloat(row) * (rowHeight + gap),
                                     width: width, height: rowHeight))
            }
        }
        return frames
    }
}

/// A Smart Care result card: the module's name (with Run's tick) at the
/// top, its picture coming in at the top-right corner, the result in one
/// large line with what it is for, and Review.
struct SmartCareResultCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: SmartCareResultCardModel
    /// The result counts up when the grid's cards arrive (D154 batch 3P).
    var counted = true
    var countDelay: Double = 0
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                shape.fill(LinearGradient(colors: [fill, fill.opacity(0.6)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                picture(in: proxy.size)
                VStack(alignment: .leading, spacing: 0) {
                    titleRow
                    Spacer(minLength: 8)
                    resultRow
                }
                .padding(CareStudioMetrics.tilePadding)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(CareStudioInk.hairline, lineWidth: 1) }
        }
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.module.title)
#if DEBUG
        .layoutProbe("careStudio.tile.\(model.id)")
#endif
    }

    private var fill: Color { isHovered ? CareStudioInk.tileFillHover : CareStudioInk.tileFill }

    private var titleRow: some View {
        HStack(spacing: 8) {
            if let tick = model.tick, let onTick = model.onTick {
                Button(action: onTick) { CareStudioTick(state: tick) }
                    .buttonStyle(CareStudioRowButtonStyle())
                    .accessibilityLabel(model.module.title)
                    .accessibilityValue(tick == .unchecked ? L10n.text("未选择", "Not selected")
                                        : L10n.text("已选择", "Selected"))
            }
            Text(model.module.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(CareStudioInk.primary)
                .lineLimit(1)
        }
    }

    private var resultRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                CareStudioCountingText(model.summary.headline, counted: counted, delay: countDelay)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(CareStudioInk.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = model.summary.subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(CareStudioInk.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let onReview = model.onReview {
                CareStudioPillButton(title: L10n.text("查看", "Review"), compact: true, action: onReview)
            }
        }
    }

    /// CleanMyMac's picture comes in at the top-right corner and the card's
    /// edges cut it (`cmm/14`).
    private func picture(in size: CGSize) -> some View {
        let side = min(size.height * 0.64, size.width * 0.44)
        let art = model.module.art
        let family = model.module.studioModule.family
        return FeatureLightfieldArtwork(art: art, variant: .landing)
            .hueRotation(family == .myTools ? .zero : family.hueRotation(for: art))
            .aspectRatio(1, contentMode: .fit)
            .frame(width: side, height: side)
            .shadow(color: CareStudioPalette.color(model.module.studioModule.palette.deep, opacity: 0.45),
                    radius: 12, y: 8)
            .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
            .rotationEffect(.degrees(isHovered && !reduceMotion ? -3 : 0))
            .animation(reduceMotion ? nil : CareStudioMotion.tileArrival, value: isHovered)
            .position(x: size.width - side * 0.32, y: side * 0.38)
            .accessibilityHidden(true)
    }
}

/// D168, batch 3L: Run's maintenance part, after the junk was cleaned (or
/// alone). The tasks run one at a time and cannot be stopped halfway.
struct SmartCareMaintenanceRunningPage: View {
    @ObservedObject var maintenance: SystemMaintenanceStore

    var body: some View {
        CareStudioRunningPage(
            module: .startup,
            title: L10n.text("正在运行维护任务…", "Running maintenance tasks…"),
            detail: maintenance.runningTask?.title ?? L10n.text("正在准备…", "Preparing…"),
            progress: .indeterminate,
            actionTitle: L10n.text("运行中", "Running"),
            canStop: false,
            footnote: L10n.text("一次运行一个任务", "One task at a time"),
            onStop: {})
    }
}

/// One line per card Run carried out, apart from the cleanup report.
@MainActor
enum SmartCareRunLines {
    static func lines(_ smartCare: SmartCareCoordinator) -> [String] {
        var lines: [String] = []
        if case .failed(let message) = smartCare.runOutcomes[.cleanup] {
            lines.append(L10n.text("清理：没有完成（\(message)）", "Cleanup: did not finish (\(message))"))
        }
        if smartCare.runOutcomes[.cleanup] == .stopped, smartCare.plannedRun.contains(.performance) {
            lines.append(L10n.text("性能：没有运行（清理已停止）", "Performance: not run (the cleanup was stopped)"))
        }
        switch smartCare.runOutcomes[.performance] {
        case .done:
            lines.append(L10n.text("性能：维护任务已运行完", "Performance: the maintenance tasks have run"))
        case .failed(let message):
            lines.append(L10n.text("性能：维护任务没有运行完（\(message)）",
                                   "Performance: the maintenance tasks did not finish (\(message))"))
        case .cancelled, .stopped, nil:
            break
        }
        return lines
    }

    static func hasFailure(_ smartCare: SmartCareCoordinator) -> Bool {
        smartCare.runOutcomes.values.contains { if case .failed = $0 { true } else { false } }
    }
}
