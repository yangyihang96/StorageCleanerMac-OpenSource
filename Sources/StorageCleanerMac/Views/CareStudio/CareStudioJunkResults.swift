import AppKit
import SwiftUI

/// Junk results (CleanMyMac Cleanup results `截图/cmm-07`, Smart Care
/// results `cmm-12`): one headline with the total, "Review All Junk", and a
/// bento of group tiles. Smart Scan adds a tick per tile and the round
/// "Clean" button; Safe Cleanup and Developer Junk clean per tile. Every
/// clean goes through the existing plan and confirmation (D93).
struct CareStudioJunkResultsPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore
    let module: CareStudioModule
    let filter: ReviewFilter
    let session: ScanSession
    /// Opens the tiered classic list (kept for its filters and dry run).
    var onShowClassicList: (() -> Void)? = nil
    @State private var managerFocus: CareJunkGroup?
    @State private var showsManager = false
    @State private var showsHealth = false
    @State private var showsSystemCaches = false
    @State private var showsAppThinning = false
    @StateObject private var appThinning = UniversalBinaryViewModel()

    private var hasAppThinningTile: Bool { filter != .devCaches && session.smartScanScopes != [.health] }

    private var hasSystemCacheTile: Bool { filter != .devCaches && store.systemCacheInventory != nil }

    private var summaries: [CareJunkGroupSummary] {
        CareJunkGrouping.summaries(for: session, filter: filter)
    }

    private var scopeIDs: Set<ScanCandidateID> {
        Set(summaries.flatMap(\.candidates).map(\.id))
    }

    private var selectedInScope: [ScanCandidate] {
        summaries.flatMap(\.candidates).filter { store.cleanupSelection.selectedCandidateIDs.contains($0.id) }
    }

    private var hasHealthTile: Bool {
        module == .smartScan && (session.smartScanScopes?.contains(.health) ?? false)
    }

    var body: some View {
        Group {
            if showsManager {
                CareStudioJunkManager(store: store, module: module, session: session,
                                      summaries: summaries, focus: managerFocus,
                                      onShowClassicList: onShowClassicList,
                                      onBack: { withAnimation(CareStudioMotion.animation(0.2, reduceMotion: reduceMotion)) { showsManager = false } })
                    .transition(.opacity)
            } else {
                // Item 12: Start Over in the title bar, Scan Again gone (CleanMyMac
                // scans again from the landing page).
                CareStudioPageFrame(module: module,
                                    titleBar: .startOver(CareStudioStartOver(activity: store.heavyWorkActivityStore,
                                                                             isEnabled: store.canEditV2CleanupSelection,
                                                                             action: store.startOverV2Results)),
                                    footnote: hasSystemCacheTile
                                        ? L10n.text("普通垃圾移入废纸篓 · 系统缓存单独确认后永久删除",
                                                     "Junk moves to Trash · System caches are permanently deleted after a separate confirmation")
                                        : L10n.text("清理前逐项确认 · 文件移入废纸篓可恢复",
                                                        "Every item is confirmed · Files move to the Trash")) {
                    content
                } action: {
                    if module == .smartScan, !summaries.isEmpty {
                        CareStudioActionButton(
                            module: module,
                            title: L10n.text("清理", "Clean"),
                            accessibilityHint: L10n.text("清理所有勾选的项目，执行前会再次确认",
                                                         "Cleans every ticked item after one more confirmation"),
                            action: cleanAllSelected)
                            .disabled(!canClean(selectedInScope))
                    }
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showsHealth) {
            CareStudioHealthSheet(session: session) { showsHealth = false }
        }
        .sheet(isPresented: $showsSystemCaches) {
            CareStudioSystemCaches(store: store) { showsSystemCaches = false }
        }
        .careStudioOwnerQuitDialog(store: store)
        .sheet(isPresented: $showsAppThinning) {
            CareStudioAppThinning(model: appThinning, store: store) { showsAppThinning = false }
        }
        .task(id: session.id) {
            if hasAppThinningTile { await appThinning.scan(coordinator: store.heavyWorkCoordinator) }
        }
        .careStudioRefreshesRunningOwners(store: store)
#if DEBUG
        .layoutProbe("careStudio.results.\(module.rawValue)")
#endif
    }

    private var content: some View {
        GeometryReader { proxy in
            // D141 revision (live check 2026-10-20): a short page keeps the
            // header tight so three rows of tiles fit above the round button
            // in a 1280 x 681 window.
            let compact = proxy.size.height < 560
            VStack(spacing: 0) {
                // Item 12: the Start Over row went to the title bar; the
                // headline keeps its place (the row was 26 pt plus padding).
                Text(headline)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(CareStudioInk.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 32)
                    .padding(.top, compact ? 38 : 56)
                    .accessibilityAddTraits(.isHeader)
#if DEBUG
                    .layoutProbe("careStudio.results.headline")
#endif
                if !summaries.isEmpty {
                    CareStudioPillButton(title: module == .smartScan
                                         ? L10n.text("查看全部项目", "Review All Items")
                                         : L10n.text("查看全部垃圾", "Review All Junk")) {
                        managerFocus = nil
                        withAnimation(CareStudioMotion.animation(0.2, reduceMotion: reduceMotion)) { showsManager = true }
                    }
                    .padding(.top, compact ? 8 : 12)
                }
                notices
                    .padding(.horizontal, 32)
                    .padding(.top, compact ? 6 : 10)
                if summaries.isEmpty && !hasHealthTile && !hasSystemCacheTile && !hasAppThinningTile {
                    emptyState
                        .frame(maxHeight: .infinity)
                } else {
                    CareStudioTileGrid(tiles: tiles)
                        .padding(.horizontal, CareStudioMetrics.pageInset)
                        .padding(.top, compact ? 10 : 18)
                        .padding(.bottom, compact ? 6 : 12)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    private var headline: String {
        if hasAppThinningTile, let inventory = appThinning.inventory, !inventory.apps.isEmpty, summaries.isEmpty {
            return L10n.text("另有 \(ByteFormat.storageString(inventory.savedBytes)) 应用代码可瘦身，需要你审阅。",
                "Review \(ByteFormat.storageString(inventory.savedBytes)) of app code available for thinning.")
        }
        if session.smartScanScopes == [.health] {
            return L10n.text("健康检查已完成：", "Your health check is ready:")
        }
        if summaries.isEmpty && !hasSystemCacheTile {
            return hasHealthTile
                ? L10n.text("没有发现可清理的垃圾，健康检查已完成：", "No junk found. Your health check is ready:")
                : L10n.text("很干净，没有发现可清理的垃圾。", "All clean — no junk was found.")
        }
        if module == .smartScan {
            return L10n.text("清理任务已准备好，看看发现了什么：", "Your tasks are ready. Here is what we found:")
        }
        return Self.cleanupHeadline(summaries, systemCacheBytes: hasSystemCacheTile
                                    ? SystemCachePresentation.bytes(store.systemCacheInventory) : 0)
    }

    /// D141 revision (live check 2026-10-20): the headline counted the files
    /// to review as junk, while the tiles below showed only what is
    /// recommended, so the numbers never added up. Junk is every group but
    /// the files to review, which are named on their own; each tile shows its
    /// whole group.
    static func cleanupHeadline(_ summaries: [CareJunkGroupSummary], systemCacheBytes: Int64 = 0) -> String {
        let junk = CleanupByteCount.sum(summaries.filter { $0.group != .filesToReview }.map(\.totalBytes) + [systemCacheBytes])
        let review = CleanupByteCount.sum(summaries.filter { $0.group == .filesToReview }.map(\.totalBytes))
        let junkText = ByteFormat.storageString(junk)
        let reviewText = ByteFormat.storageString(review)
        if review == 0 {
            return L10n.text("你的 Mac 上有 \(junkText) 垃圾文件。",
                             "There are \(junkText) of junk files on your Mac.")
        }
        if junk == 0 {
            return L10n.text("没有发现垃圾文件，另有 \(reviewText) 待确认文件。",
                             "No junk files found; \(reviewText) of files need your review.")
        }
        return L10n.text("你的 Mac 上有 \(junkText) 垃圾文件，另有 \(reviewText) 待确认文件。",
                         "There are \(junkText) of junk files on your Mac, plus \(reviewText) of files to review.")
    }

    /// D179: why the results may be incomplete, as `coverageLimits` finds it;
    /// nil when nothing really limited the scan. Rows held back on purpose
    /// (D19) and files gone during the scan no longer read as an unfinished
    /// scan (was "扫描没有全部完成（超时或部分位置无法读取）" for any partial outcome).
    nonisolated static func coverageNotice(_ limits: ScanCoverageLimits) -> String? {
        guard limits.isLimited else { return nil }
        var reasons = [String]()
        if limits.reachedTimeLimit {
            reasons.append(L10n.text("扫描到了时间上限，剩下的位置没有扫",
                                     "the scan reached its time limit before the remaining places"))
        }
        if limits.deniedLocationCount > 0 {
            reasons.append(L10n.text("\(ByteFormat.count(limits.deniedLocationCount)) 个位置没有读取权限",
                                     "\(ByteFormat.count(limits.deniedLocationCount)) place(s) without read permission"))
        }
        if limits.unreadableLocationCount > 0 {
            reasons.append(L10n.text("\(ByteFormat.count(limits.unreadableLocationCount)) 个位置无法读取",
                                     "\(ByteFormat.count(limits.unreadableLocationCount)) place(s) could not be read"))
        }
        if limits.partlyMeasuredCount > 0 {
            reasons.append(L10n.text("\(ByteFormat.count(limits.partlyMeasuredCount)) 项只量出了部分大小",
                                     "\(ByteFormat.count(limits.partlyMeasuredCount)) item(s) only partly measured"))
        }
        if limits.truncatedCandidateCount > 0 {
            reasons.append(L10n.text("另有 \(ByteFormat.count(limits.truncatedCandidateCount)) 个较小的项目没有列出",
                                     "\(ByteFormat.count(limits.truncatedCandidateCount)) smaller item(s) not listed"))
        }
        if limits.otherSkippedCount > 0 {
            reasons.append(L10n.text("\(ByteFormat.count(limits.otherSkippedCount)) 个项目因信息不全或不在允许范围内跳过",
                                     "\(ByteFormat.count(limits.otherSkippedCount)) item(s) skipped for missing details or outside their folder"))
        }
        if reasons.isEmpty {
            reasons.append(L10n.text("扫描没有全部完成", "the scan did not finish everywhere"))
        }
        return L10n.text("结果可能不完整：\(reasons.joined(separator: "；"))。",
                         "Results may be incomplete: \(reasons.joined(separator: "; ")).")
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 6) {
            if let coverage = Self.coverageNotice(session.coverageLimits) {
                CareStudioNotice(systemImage: "exclamationmark.triangle.fill", text: coverage)
            }
            if let notice = store.accessReturnNotice, notice.sessionID == session.id {
                CareStudioNotice(systemImage: "lock.open.fill",
                                 text: L10n.text("完全磁盘访问权限已变化，重新扫描可以看到更多位置。",
                                                 "Full Disk Access changed; scan again to include more places."),
                                 actionTitle: L10n.text("重新扫描", "Scan Again")) {
                    store.rescanAfterAccessReturn()
                }
            }
            if filter == .devCaches,
               session.developerInactivityThresholdDays != store.developerInactivityThresholdDays {
                CareStudioNotice(systemImage: "calendar.badge.clock",
                                 text: L10n.text("这些结果按 \(session.developerInactivityThresholdDays) 天活动阈值分级；重新扫描后使用新设置。",
                                                 "These results use a \(session.developerInactivityThresholdDays)-day threshold; scan again to apply the new one."),
                                 actionTitle: L10n.text("重新扫描", "Scan Again")) {
                    store.startScanRespectingAccessGuide()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            CareStudioArt(module: module, side: 180, showsSuccess: true)
            Text(L10n.text("继续保持，需要时再来扫描。", "Keep it up — scan again any time."))
                .font(.system(size: 14))
                .foregroundStyle(CareStudioInk.secondary)
        }
    }

    private var tiles: [CareStudioTileModel] {
        var models = summaries.map { summary -> CareStudioTileModel in
            let selected = summary.selectedBytes(in: store.cleanupSelection)
            let selectedCount = summary.selectedCount(in: store.cleanupSelection)
            let ids = Set(summary.candidates.map(\.id))
            let selectable = summary.selectableIDs
            let tick: TriStateSelection? = module == .smartScan && !selectable.isEmpty
                ? store.cleanupSelection.state(for: selectable) : nil
            return CareStudioTileModel(
                id: summary.id,
                module: module,
                title: module == .smartScan
                    ? summary.group.title
                    : summary.group.tileTitle(bytes: summary.totalBytes),
                value: module == .smartScan
                    ? (selectedCount > 0 ? ByteFormat.storageString(selected) : (summary.isReviewOnly
                        ? L10n.text("\(ByteFormat.count(summary.candidates.count)) 项", "\(ByteFormat.count(summary.candidates.count)) items")
                        : ByteFormat.storageString(summary.recommendedBytes)))
                    : nil,
                valueCaption: module == .smartScan
                    ? (selectedCount > 0 ? L10n.text("将清理", "to clean")
                       : (summary.isReviewOnly ? L10n.text("需要你确认", "need your review") : L10n.text("可以清理", "can be cleaned")))
                    : nil,
                detail: summary.group.summary,
                note: module == .smartScan || selectedCount == 0 || selected == summary.totalBytes
                    ? nil
                    : L10n.text("已选 \(ByteFormat.count(selectedCount)) 项 · \(ByteFormat.storageString(selected))",
                                "\(ByteFormat.count(selectedCount)) selected · \(ByteFormat.storageString(selected))"),
                systemImage: summary.group.systemImage,
                iconPaths: Self.iconPaths(for: summary),
                subgroupSymbols: summary.subgroups.prefix(3).map(Self.symbol(for:)),
                tick: tick,
                onTick: tick == nil ? nil : { toggleTile(summary) },
                reviewTitle: L10n.text("查看", "Review"),
                onReview: {
                    managerFocus = summary.group
                    withAnimation(CareStudioMotion.animation(0.2, reduceMotion: reduceMotion)) { showsManager = true }
                },
                cleanTitle: module != .smartScan && selectedCount > 0 ? L10n.text("清理", "Clean") : nil,
                cleanEnabled: store.canRequestV2Cleanup,
                onClean: { store.requestV2Cleanup(disposition: .trash, candidateIDs: ids) },
                art: summary.group.tileArt)
        }
        if hasHealthTile {
            models.append(CareStudioHealthTile.model(for: session, module: module) { showsHealth = true })
        }
        if hasSystemCacheTile {
            models.append(CareStudioTileModel(
                id: "systemCaches", module: module,
                title: L10n.text("系统缓存", "System Caches"),
                value: ByteFormat.storageString(SystemCachePresentation.bytes(store.systemCacheInventory)),
                detail: L10n.text("系统会自动重建 · 永久删除前需确认", "Rebuilt by the system · Confirm before permanent deletion"),
                note: store.systemCacheInventory?.items.contains(where: { $0.failure != nil }) == true
                    ? L10n.text("部分缓存未能完整计量", "Some caches could not be fully measured") : nil,
                systemImage: "internaldrive.fill", reviewTitle: L10n.text("查看", "Review"),
                onReview: { showsSystemCaches = true }))
        }
        if hasAppThinningTile {
            models.append(CareStudioTileModel(
                id: "applicationThinning", module: module,
                title: L10n.text("应用瘦身", "App Thinning"),
                value: appThinning.inventory.map { ByteFormat.storageString($0.savedBytes) }
                    ?? L10n.text("待检查", "Not checked"),
                valueCaption: L10n.text("需审阅 · 默认不选", "Review required · Not selected"),
                detail: L10n.text("去掉其他芯片的代码 · 会改动应用，原包进废纸篓", "Remove code for other chips · Changes apps; originals go to Trash"),
                systemImage: "cpu", reviewTitle: L10n.text("审阅", "Review"),
                onReview: { showsAppThinning = true }, reviewTint: .yellow))
        }
        return models
    }

    private func toggleTile(_ summary: CareJunkGroupSummary) {
        let selectable = summary.selectableIDs
        guard store.canEditV2CleanupSelection, !selectable.isEmpty else { return }
        switch store.cleanupSelection.state(for: selectable) {
        case .unchecked:
            // Ticking a tile selects what D47 recommends, never yellow or red.
            store.setCleanupCandidates(summary.recommendedIDs, selected: true)
        case .checked, .mixed:
            store.setCleanupCandidates(selectable, selected: false)
        }
    }

    private func canClean(_ selected: [ScanCandidate]) -> Bool {
        !selected.isEmpty && store.canRequestV2Cleanup
    }

    private func cleanAllSelected() {
        guard canClean(selectedInScope) else { return }
        store.requestV2Cleanup(disposition: .trash, candidateIDs: scopeIDs)
    }

    /// App icons for a tile: the owners of the largest items (CleanMyMac
    /// shows the biggest AI app on the AI Clutter tile).
    static func iconPaths(for summary: CareJunkGroupSummary) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for candidate in summary.candidates.sorted(by: { $0.estimatedSizeBytes > $1.estimatedSizeBytes }) {
            for bundleID in candidate.ownerBundleIdentifiers {
                guard !seen.contains(bundleID),
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
                seen.insert(bundleID)
                paths.append(url.path)
                if paths.count == 3 { return paths }
            }
        }
        return paths
    }

    static func symbol(for subgroup: CareJunkSubgroup) -> String {
        let id = subgroup.id.lowercased()
        if id.contains("log") || id.contains("diagnostic") { return "doc.text.fill" }
        if id.contains("browser") { return "safari.fill" }
        if id.contains("trash") { return "trash.fill" }
        if id.contains("mail") { return "envelope.fill" }
        if id.contains("download") { return "arrow.down.circle.fill" }
        if id.contains("xcode") || id.contains("derived") { return "hammer.fill" }
        if id.contains("temporary") || id.contains("tmp") { return "clock.arrow.circlepath" }
        return "internaldrive.fill"
    }
}

/// D166: a junk subcategory's mark in the manager — the D67 option icons
/// for caches, logs, temporary files and downloads, the D166 objects for
/// trash, mail and developer junk, the round symbol otherwise.
struct CareStudioJunkSubgroupMark: View {
    let module: CareStudioModule
    let subgroup: CareJunkSubgroup
    var side: CGFloat = 30

    enum Mark: Equatable {
        case option(LightfieldOptionIcon)
        case art(GeneratedArt)
        case symbol(String)
    }

    static func mark(for subgroup: CareJunkSubgroup) -> Mark {
        let id = subgroup.id.lowercased()
        if id.contains("trash") { return .art(.tileTrash) }
        if id.contains("mail") { return .art(.tileMail) }
        if id.contains("xcode") || id.contains("derived") { return .art(.tileDevJunk) }
        if id.contains("log") || id.contains("diagnostic") { return .option(.cleanupLogs) }
        if id.contains("download") { return .option(.cleanupDownloadRemnants) }
        if id.contains("temporary") || id.contains("tmp") { return .option(.cleanupTemporaryFiles) }
        if id.contains("cache") { return .option(.cleanupSystemCache) }
        return .symbol(CareStudioJunkResultsPage.symbol(for: subgroup))
    }

    var body: some View {
        switch Self.mark(for: subgroup) {
        case .option(let icon):
            LightfieldOptionIconView(icon: icon, pointSize: side).frame(width: side, height: side)
        case .art(let art):
            FeatureLightfieldArtwork(art: art, variant: .header)
                .hueRotation(module.family.hueRotation(for: art))
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        case .symbol(let symbol):
            CareStudioGlyph(module: module, systemImage: symbol, side: side)
        }
    }
}

/// A one-line notice on the gradient.
struct CareStudioNotice: View {
    let systemImage: String
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Spacer(minLength: 6)
                CareStudioPillButton(title: actionTitle, compact: true, action: action)
            }
        }
        .foregroundStyle(CareStudioInk.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(CareStudioInk.panelFill))
        .frame(maxWidth: 680)
    }
}

// MARK: - Tiles

struct CareStudioTileModel: Identifiable {
    let id: String
    let module: CareStudioModule
    let title: String
    var value: String? = nil
    var valueCaption: String? = nil
    var detail: String? = nil
    var note: String? = nil
    var systemImage: String
    var iconPaths: [String] = []
    /// A system-provided installed app icon (D185 cloud providers).
    var appIcon: NSImage? = nil
    var subgroupSymbols: [String] = []
    var tick: TriStateSelection? = nil
    var onTick: (() -> Void)? = nil
    var reviewTitle: String
    var onReview: () -> Void
    var cleanTitle: String? = nil
    var cleanEnabled = true
    var onClean: (() -> Void)? = nil
    /// D154: a 3D picture for the tile (CleanMyMac puts a large object on
    /// each card): in the middle of a large tile, in the corner of a small
    /// one. Without it the tile keeps its round symbol.
    var art: GeneratedArt? = nil
    var reviewTint: Color? = nil
}

/// CleanMyMac's bento: with three or more tiles the first is a tall tile
/// on the left and the others fill two columns on the right.
struct CareStudioTileGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureDisablesLayoutAnimations) private var disablesAnimations
    let tiles: [CareStudioTileModel]
    /// D154: set once when the grid appears; each tile follows with its own
    /// delay. Kept here, not per tile, so a tile rebuilt while the grid lays
    /// out (scrolling or not) still arrives.
    @State private var arrived = false

    var body: some View {
        GeometryReader { proxy in
            let frames = Self.frames(count: tiles.count, in: proxy.size)
            let height = Self.contentHeight(of: frames)
            if height > proxy.size.height + 0.5 {
                // D141 revision (live check 2026-10-20): in a short window the
                // tiles scroll in their own area instead of running under the
                // round button below it.
                ScrollView(.vertical) {
                    tileStack(frames)
                        .frame(width: proxy.size.width, height: height, alignment: .topLeading)
                }
#if DEBUG
                .layoutProbe("careStudio.tiles.scroll")
#endif
            } else {
                tileStack(frames)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .onAppear { if !still { arrived = true } }
#if DEBUG
        .layoutProbe("careStudio.tiles")
#endif
    }

    private func tileStack(_ frames: [CGRect]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                if index < frames.count {
                    CareStudioTile(model: tile, isLarge: tiles.count <= 2 || index == 0,
                                   glyphSide: Self.glyphSide(for: frames[index].size),
                                   counted: arrived || still, countDelay: CareStudioMotion.tileDelay(index))
                        .frame(width: frames[index].width, height: frames[index].height)
                        .modifier(CareStudioTileArrival(index: index, arrived: arrived || still))
                        .offset(x: frames[index].minX, y: frames[index].minY)
                }
            }
        }
    }

    private var still: Bool { reduceMotion || disablesAnimations }

    /// The height the tiles take; more than the grid's height means it scrolls.
    static func contentHeight(of frames: [CGRect]) -> CGFloat {
        frames.map(\.maxY).max() ?? 0
    }

    /// A small tile's title, value, caption and buttons with their padding.
    static let minimumRowHeight: CGFloat = 104
    /// A large tile's title, four lines of description, marks and value at
    /// its narrowest (201 pt in a 473 pt window).
    static let minimumLargeHeight: CGFloat = 270

    /// CleanMyMac's large cards carry their category marks at roughly a
    /// quarter of the card's shorter side (`截图/cmm-07`).
    static func glyphSide(for size: CGSize) -> CGFloat {
        min(88, max(52, min(size.width, size.height) * 0.26))
    }

    static func frames(count: Int, in size: CGSize) -> [CGRect] {
        guard count > 0, size.width > 0, size.height > 0 else { return [] }
        let gap = CareStudioMetrics.tileSpacing
        let maxRowHeight: CGFloat = 176
        // One or two groups get tall tiles with their description and marks,
        // so a small result does not leave a half-empty page.
        let tallHeight = max(minimumLargeHeight, min(size.height, 300))
        if count == 1 {
            return [CGRect(x: 0, y: 0, width: size.width, height: tallHeight)]
        }
        if count == 2 {
            let width = (size.width - gap) / 2
            let height = tallHeight
            return [CGRect(x: 0, y: 0, width: width, height: height),
                    CGRect(x: width + gap, y: 0, width: width, height: height)]
        }
        let rest = count - 1
        let rows = Int(ceil(Double(rest) / 2))
        // The tall left tile spans the rows; with one row they grow to its minimum.
        let rowHeight = max(minimumRowHeight,
                            min(maxRowHeight, (size.height - CGFloat(rows - 1) * gap) / CGFloat(rows)),
                            (minimumLargeHeight - CGFloat(rows - 1) * gap) / CGFloat(rows))
        let leftWidth = (size.width - 2 * gap) / 3
        let rightX = leftWidth + gap
        let rightWidth = size.width - rightX
        let cellWidth = (rightWidth - gap) / 2
        var frames = [CGRect(x: 0, y: 0, width: leftWidth,
                             height: CGFloat(rows) * rowHeight + CGFloat(rows - 1) * gap)]
        for index in 0..<rest {
            let row = index / 2, column = index % 2
            let y = CGFloat(row) * (rowHeight + gap)
            let isLastAlone = index == rest - 1 && rest % 2 == 1
            frames.append(isLastAlone
                ? CGRect(x: rightX, y: y, width: rightWidth, height: rowHeight)
                : CGRect(x: rightX + CGFloat(column) * (cellWidth + gap), y: y, width: cellWidth, height: rowHeight))
        }
        return frames
    }
}

struct CareStudioTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: CareStudioTileModel
    var isLarge = false
    /// The middle category mark of a large tile; its neighbours are smaller.
    var glyphSide: CGFloat = 58
    /// D154 batch 3P: the value counts up when the grid's tiles arrive.
    var counted = true
    var countDelay: Double = 0
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                .fill(LinearGradient(colors: [isHovered ? CareStudioInk.tileFillHover : CareStudioInk.tileFill,
                                              (isHovered ? CareStudioInk.tileFillHover : CareStudioInk.tileFill).opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                        .strokeBorder(model.reviewTint ?? CareStudioInk.hairline, lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    if let tick = model.tick, let onTick = model.onTick {
                        Button(action: onTick) { CareStudioTick(state: tick) }
                            .buttonStyle(CareStudioRowButtonStyle())
                            .accessibilityLabel(model.title)
                            .accessibilityValue(tick == .unchecked ? L10n.text("未选择", "Not selected")
                                                : (tick == .mixed ? L10n.text("部分选择", "Partly selected")
                                                   : L10n.text("已选择", "Selected")))
                    }
                    Text(model.title)
                        .font(.system(size: model.value == nil ? 17 : 14, weight: .semibold))
                        .foregroundStyle(CareStudioInk.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 46)
                }
                if isLarge, let detail = model.detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(CareStudioInk.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isLarge, let art = model.art {
                    // D154: the large tile's picture (CleanMyMac's bento
                    // centrepiece) takes what the text leaves, up to its size.
                    tileArt(art, maxSide: min(150, max(72, glyphSide * 1.7)))
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                    if isLarge, !model.subgroupSymbols.isEmpty {
                        HStack(spacing: 16) {
                            ForEach(Array(model.subgroupSymbols.enumerated()), id: \.offset) { index, symbol in
                                CareStudioGlyph(module: model.module, systemImage: symbol,
                                                side: index == 1 || model.subgroupSymbols.count == 1
                                                    ? glyphSide : (glyphSide * 0.55).rounded())
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                        Spacer(minLength: 0)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let value = model.value {
                            CareStudioCountingText(value, counted: counted, delay: countDelay)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(CareStudioInk.primary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        if let caption = model.valueCaption {
                            Text(caption).font(.system(size: 12)).foregroundStyle(CareStudioInk.secondary)
                        }
                        if let note = model.note {
                            Text(note).font(.system(size: 11)).foregroundStyle(CareStudioInk.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    CareStudioPillButton(title: model.reviewTitle, compact: true, action: model.onReview)
                    if let cleanTitle = model.cleanTitle, let onClean = model.onClean {
                        CareStudioPillButton(title: cleanTitle, filled: true, compact: true, action: onClean)
                            .disabled(!model.cleanEnabled)
                    }
                }
            }
            .padding(CareStudioMetrics.tilePadding)
            iconCorner
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .contentShape(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
#if DEBUG
        .layoutProbe("careStudio.tile.\(model.id)")
#endif
    }

    @ViewBuilder
    private var iconCorner: some View {
        Group {
            if let icon = model.appIcon, !isLarge {
                Image(nsImage: icon).resizable().scaledToFit()
                    .frame(width: 38, height: 38).accessibilityHidden(true)
            } else if let path = model.iconPaths.first, !isLarge {
                CachedAppIconView(path: path, size: 38) {
                    CareStudioGlyph(module: model.module, systemImage: model.systemImage, side: 38)
                }
            } else if !isLarge, let art = model.art {
                tileArt(art, maxSide: 52)
                    .frame(width: 52, height: 52)
            } else if !isLarge {
                CareStudioGlyph(module: model.module, systemImage: model.systemImage, side: 38)
            }
        }
        // D154: the corner object leans in a little under the pointer.
        .scaleEffect(isHovered && !reduceMotion ? 1.08 : 1)
        .rotationEffect(.degrees(isHovered && !reduceMotion ? -5 : 0))
        .animation(reduceMotion ? nil : CareStudioMotion.tileArrival, value: isHovered)
    }

    /// The tile's picture in its module colour, with the module's shadow;
    /// square, no larger than `maxSide`, smaller when the tile is short.
    private func tileArt(_ art: GeneratedArt, maxSide: CGFloat) -> some View {
        FeatureLightfieldArtwork(art: art, variant: maxSide > 96 ? .landing : .header)
            .hueRotation(model.module.family == .myTools ? .zero : model.module.family.hueRotation(for: art))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: maxSide, maxHeight: maxSide)
            .shadow(color: CareStudioPalette.color(model.module.palette.deep, opacity: 0.45), radius: 10, y: 6)
#if DEBUG
            .layoutProbe("careStudio.tile.\(model.id).art")
#endif
    }
}

/// A glossy round mark in the module colour.
struct CareStudioGlyph: View {
    let module: CareStudioModule
    let systemImage: String
    var side: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [CareStudioPalette.color(module.palette.action[0]),
                                              CareStudioPalette.color(module.palette.action[1])],
                                     startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
            Circle()
                .fill(LinearGradient(colors: [Color.white.opacity(0.32), .clear],
                                     startPoint: .top, endPoint: .center))
                .padding(2)
            Image(systemName: systemImage)
                .font(.system(size: side * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        .shadow(color: CareStudioPalette.color(module.palette.deep, opacity: 0.4), radius: 6, y: 3)
        .accessibilityHidden(true)
    }
}

/// The white tick of a Smart Scan tile.
struct CareStudioTick: View {
    let state: TriStateSelection

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(state == .unchecked ? Color.clear : CareStudioInk.primary)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(CareStudioInk.secondary, lineWidth: 1.2)
            if state != .unchecked {
                Image(systemName: state == .mixed ? "minus" : "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(CareStudioInk.inverse)
            }
        }
        .frame(width: 17, height: 17)
        .contentShape(Rectangle())
    }
}

// MARK: - Shared behaviour

extension View {
    /// "正常退出并清理" from a row asks first, as the old result page did (A2).
    func careStudioOwnerQuitDialog(store: ScanStore) -> some View {
        confirmationDialog(
            L10n.text("正常退出这些应用？", "Quit These Apps Normally?"),
            isPresented: Binding(
                get: {
                    guard let request = store.cleanupOwnerQuitRequest else { return false }
                    return !request.isFromConfirmation
                },
                set: { if !$0 { store.cancelQuitCleanupOwners() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("正常退出并清理", "Quit Normally and Clean")) {
                store.quitOwnersAndRecheckCleanup()
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                store.cancelQuitCleanupOwners()
            }
        } message: {
            Text(CleanupOwnerQuitPresentation.message(for: store.cleanupOwnerQuitRequest))
        }
    }

    /// Rows follow apps opening and quitting while results are shown (A2).
    func careStudioRefreshesRunningOwners(store: ScanStore) -> some View {
        self
            .task { await store.refreshCleanupOwnerRunningState() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification)) { _ in
                Task { await store.refreshCleanupOwnerRunningState() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didLaunchApplicationNotification)) { _ in
                Task { await store.refreshCleanupOwnerRunningState() }
            }
    }
}

// MARK: - Health tile (Smart Scan)

enum CareStudioHealthTile {
    static func model(for session: ScanSession, module: CareStudioModule,
                      onReview: @escaping () -> Void) -> CareStudioTileModel {
        let status = session.smartScanHealthStatus
        let value: String
        let caption: String
        if session.smartScanHealthSnapshot != nil {
            value = L10n.text("已检查", "Checked")
            caption = L10n.text("磁盘、容量、电池与安全设置", "Disk, space, battery and security")
        } else {
            value = L10n.text("不可用", "Unavailable")
            caption = status?.title ?? L10n.text("健康信息不可用", "Health information unavailable")
        }
        return CareStudioTileModel(
            id: "health", module: module,
            title: L10n.text("健康状态", "Health"),
            value: value, valueCaption: caption,
            systemImage: "heart.text.square.fill",
            reviewTitle: L10n.text("查看", "Review"), onReview: onReview, art: .health)
    }
}

/// The measured health evidence of a Smart Scan, shown on a light sheet.
struct CareStudioHealthSheet: View {
    let session: ScanSession
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("健康状态", "Health")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L10n.text("完成", "Done"), action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                SmartScanHealthResultsView(snapshot: session.smartScanHealthSnapshot,
                                           status: session.smartScanHealthStatus)
                    .padding(18)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
    }
}

/// D154: CleanMyMac's result tiles come in one after another, each rising a
/// little as it fades in. Reduce Motion (and still test captures) shows them
/// at once.
struct CareStudioTileArrival: ViewModifier {
    let index: Int
    let arrived: Bool

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 14)
            .animation(CareStudioMotion.tileArrival.delay(CareStudioMotion.tileDelay(index)), value: arrived)
    }
}
