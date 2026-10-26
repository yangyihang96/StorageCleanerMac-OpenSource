import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// D154 batch 3G: CleanMyMac's Space Lens as the Space Map result — Back and
/// the path above, the disk usage bar, the list of the current folder on the
/// left (apps with their own icons) and the bubble map beside it, Remove as
/// the round button. It shows the completed index only (no new walk); the
/// selection rules, the review sheet, the notes and the inventories are the
/// D70 page's, which `FileAnalysisLightfieldView` keeps and attaches.
struct CareStudioSpaceLensPage: View {
    let result: StorageMapAnalysisResult
    let navigation: [StorageMapDirectorySnapshot]
    let types: [LightfieldChartItem]
    let largest: [StorageTreemapEntry]
    let fileCount: Int
    @Binding var surface: Int
    @Binding var mapStyle: SpaceMapViewStyle
    @Binding var mapColorMode: SpaceMapColorMode
    var dataVersion: UInt64 = 0
    var isBusy = false
    var browseFailed = false
    var checkedPaths: Set<String> = []
    let selectionState: (StorageTreemapEntry) -> FileAnalysisTrashSelectionState
    var selectedBytes: Int64 = 0
    var selectionReclaim: CleanupSelectionReclaimable? = nil
    var isEstimatingReclaim = false
    /// The selection, a notice or the last outcome, as the D70 status line.
    let status: String
    let canReview: Bool
    let onReview: () -> Void
    let onToggle: (StorageTreemapEntry) -> Void
    let onOpen: (StorageTreemapEntry) -> Void
    let onBreadcrumb: (Int) -> Void
    var onOpenFromRoot: (StorageTreemapEntry) -> Void = { _ in }
    var onForward: (() -> Void)? = nil
    var notice: String? = nil
    var onRetry: (() -> Void)? = nil
    var onChangeScope: (() -> Void)? = nil
    var onDetails: (() -> Void)? = nil
    var onCapacityNotes: (() -> Void)? = nil
    var onLocalModels: (() -> Void)? = nil
    var onDeviceBackups: (() -> Void)? = nil
    var onCloudCopies: (() -> Void)? = nil
    var onReveal: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @State private var quickLookURL: URL?
    @State private var highlightedID: String?
    @State private var highlightedType: String?
    @State private var mapLevels = 3
    @State private var mapFullWidth = false
    @State private var filterText = ""
    @FocusState private var filterFocused: Bool
    @StateObject private var treemapSource = SpaceMapTreemapSource()

    private struct PurposeRequest: Hashable {
        let version: UInt64
        let blocks: Bool
        let worth: Bool
    }

    private var showsBlocks: Bool { surface == 0 && mapStyle == .blocks }

    private var snapshot: StorageMapDirectorySnapshot { navigation.last ?? result.rootSnapshot }
    private var keyword: String { filterText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var activeFilter: SpaceMapTreemapFilter.Result? {
        showsBlocks ? treemapSource.activeFilter(version: dataVersion, path: snapshot.path, keyword: keyword) : nil
    }
    private var entries: [StorageTreemapEntry] {
        if surface == 2 { return largest }
        if surface == 3 { return treemapSource.worthVersion == dataVersion ? treemapSource.worthRows.map(\.entry) : [] }
        return SpaceLensWorthALook.filteredEntries(StorageTreemapPresentation.visibleEntries(from: snapshot), filter: activeFilter)
    }
    private var chartItems: [LightfieldChartItem] {
        surface == 1 ? types : entries.filter { $0.sizeBytes > 0 }.map(Self.bubble)
    }

    /// D154 batch 3N: CleanMyMac puts the item's icon in its bubble — the app's
    /// own, a folder's or the kind of file's, as in the list.
    static func bubble(_ entry: StorageTreemapEntry) -> LightfieldChartItem {
        var item = FileLightfieldPresentation.chart(entry)
        item.picture = LightfieldChartPicture(path: entry.path, isDirectory: entry.isDirectory)
        return item
    }

    var body: some View {
        CareStudioPageFrame(module: .spaceMap,
                            footnote: L10n.text("目录索引 · 移到废纸篓前确认", "Directory index · Confirm before moving to Trash")) {
            GeometryReader { proxy in
                let wide = proxy.size.width >= 680
                VStack(alignment: .leading, spacing: 12) {
                    header(showsFilter: wide && showsBlocks)
                    usage
                    HStack(alignment: .top, spacing: 20) {
                        if !wide || !mapFullWidth || !showsBlocks {
                            listPanel
                                .frame(width: wide ? min(400, proxy.size.width * 0.44) : nil)
                                .frame(maxWidth: wide ? nil : .infinity)
                        }
                        if wide {
                            mapPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CareStudioInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
#if DEBUG
                        .layoutProbe("careStudio.spaceLens.status")
#endif
                }
                .padding(.horizontal, CareStudioMetrics.pageInset)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .onChange(of: wide) { _, value in if !value { mapFullWidth = false; clearFilter() } }
                .task(id: PurposeRequest(version: dataVersion, blocks: wide && showsBlocks, worth: surface == 3)) {
                    let home = result.target.kind == .homeDirectory ? result.index.rootPath : NSHomeDirectory()
                    if surface == 3 {
                        await treemapSource.findWorthALook(index: result.index, version: dataVersion, homePath: home)
                    } else if wide && showsBlocks {
                        await treemapSource.classify(index: result.index, version: dataVersion, homePath: home)
                    }
                }
                .task(id: SpaceMapTreemapSource.FilterKey(version: dataVersion, path: snapshot.path,
                                                         keyword: wide && showsBlocks ? keyword : "")) {
                    await treemapSource.filter(index: result.index,
                        key: .init(version: dataVersion, path: snapshot.path, keyword: wide && showsBlocks ? keyword : ""))
                }
            }
        } action: {
            CareStudioActionButton(module: .spaceMap, title: L10n.text("移除", "Remove"),
                                   accessibilityHint: L10n.text("先打开审阅，确认后才移到废纸篓", "Opens the review first; nothing moves until you confirm"),
                                   action: onReview)
                .disabled(!canReview)
        }
        .onChange(of: surface) { _, _ in highlightedID = nil; mapFullWidth = false; clearFilter() }
        .onChange(of: mapStyle) { _, value in if value != .blocks { mapFullWidth = false; clearFilter() } }
        .onChange(of: snapshot.path) { _, _ in highlightedID = nil }
        .quickLookPreview($quickLookURL)
#if DEBUG
        .layoutProbe("careStudio.spaceLens")
#endif
    }

    // MARK: Header

    /// Back, the path (each folder goes back to it) and the notes and
    /// inventories under More.
    private func header(showsFilter: Bool) -> some View {
        HStack(spacing: 10) {
            Button { onBreadcrumb(max(0, navigation.count - 2)) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CareStudioInk.primary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(CareStudioInk.pillFill))
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .disabled(isBusy || surface != 0 || navigation.count < 2)
            .help(L10n.text("返回上一层", "Back"))
            .accessibilityLabel(L10n.text("返回上一层", "Back"))
            HStack(spacing: 4) {
                ForEach(Array(pathLevels.enumerated()), id: \.offset) { position, level in
                    if position > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CareStudioInk.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button(level.snapshot.title) { onBreadcrumb(level.index) }
                        .buttonStyle(CareStudioRowButtonStyle())
                        .font(.system(size: position == pathLevels.count - 1 ? 17 : 13,
                                      weight: position == pathLevels.count - 1 ? .semibold : .medium))
                        .foregroundStyle(position == pathLevels.count - 1 ? CareStudioInk.primary : CareStudioInk.secondary)
                        .lineLimit(1)
                        .disabled(isBusy || surface != 0)
                        .help(level.snapshot.path)
                }
            }
            .layoutPriority(-1)
            .truncationMode(.middle)
#if DEBUG
            .layoutProbe("careStudio.spaceLens.path")
#endif
            Spacer(minLength: 8)
            if let notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(notice)
            }
            if let onRetry {
                CareStudioPillButton(title: L10n.text("重试", "Retry"), compact: true, action: onRetry)
                    .disabled(isBusy)
            }
            if showsFilter {
                CareStudioSearchField(text: $filterText, prompt: L10n.text("按名称筛选", "Filter by Name"), width: 200)
                    .focused($filterFocused)
                    .onExitCommand { clearFilter() }
                    .accessibilityLabel(L10n.text("按名称筛选", "Filter by Name"))
#if DEBUG
                    .layoutProbe("careStudio.spaceLens.filter")
#endif
            }
            moreMenu
        }
        .frame(height: 32)
    }

    /// The current folder and up to two above it; deeper paths start with
    /// the scan's root and the folders in between are reached with Back.
    private var pathLevels: [(index: Int, snapshot: StorageMapDirectorySnapshot)] {
        let levels = surface == 0 ? navigation : [result.rootSnapshot]
        let indexed = Array(levels.enumerated()).map { (index: $0.offset, snapshot: $0.element) }
        guard indexed.count > 3 else { return indexed }
        return [indexed[0]] + indexed.suffix(2)
    }

    private var moreMenu: some View {
        Menu {
            if let onChangeScope {
                Button(L10n.text("更换范围…", "Change Scope…"), action: onChangeScope)
            }
            if let onCapacityNotes {
                Button(L10n.text("容量口径", "Size Basis"), action: onCapacityNotes)
            }
            if let onLocalModels {
                Button(L10n.text("本地 AI 模型", "Local AI Models"), action: onLocalModels)
            }
            if let onDeviceBackups {
                Button(L10n.text("设备备份", "Device Backups"), action: onDeviceBackups)
            }
            if let onCloudCopies {
                Button(L10n.text("云文件本地副本", "Cloud Local Copies"), action: onCloudCopies)
                    .disabled(isBusy)
            }
            if let onDetails {
                Divider()
                Button(L10n.text("选择与操作详情", "Selection and Operation Details"), action: onDetails)
            }
        } label: {
            Text(L10n.text("更多", "More"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CareStudioInk.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
#if DEBUG
        .layoutProbe("careStudio.spaceLens.more")
#endif
    }

    // MARK: Usage

    /// "Used of total" with the selection marked inside the used part, as
    /// CleanMyMac's top bar; the folder's own size and basis below it.
    private var usage: some View {
        let total = max(1, result.volumeTotalBytes)
        let used = min(1, Double(result.usedVolumeBytes) / Double(total))
        let selected = min(used, Double(selectedBytes) / Double(total))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(L10n.text("已用 \(ByteFormat.storageString(result.usedVolumeBytes)) / 共 \(ByteFormat.storageString(result.volumeTotalBytes))",
                               "\(ByteFormat.storageString(result.usedVolumeBytes)) of \(ByteFormat.storageString(result.volumeTotalBytes)) used"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CareStudioInk.primary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                legend(color: Color.white.opacity(0.25),
                       title: L10n.text("可用 ", "Free ") + ByteFormat.storageString(result.volumeAvailableBytes))
            }
            Group {
                if selectedBytes > 0 {
                    legend(color: .white, title: FileAnalysisSelectionReclaim.title(
                        selectedBytes: selectedBytes, reclaim: selectionReclaim, estimating: isEstimatingReclaim))
                } else {
                    Text(L10n.text("勾选项目后，这里显示清空废纸篓后约可释放的空间",
                                   "Select items to see the estimated space freed after emptying the Trash"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CareStudioInk.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .help(FileAnalysisSelectionReclaim.help(reclaim: selectionReclaim))
            .frame(height: 14, alignment: .leading)
#if DEBUG
            .layoutProbe("careStudio.spaceLens.reclaim")
#endif
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule()
                        .fill(LinearGradient(colors: [CareStudioPalette.color(CareStudioModule.spaceMap.palette.action[0]),
                                                      CareStudioPalette.color(CareStudioModule.spaceMap.palette.action[1])],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: bar.size.width * used)
                    if selected > 0 {
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: max(4, bar.size.width * selected))
                            .offset(x: bar.size.width * (used - selected))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityElement()
            .accessibilityLabel(L10n.text("磁盘用量", "Disk Usage"))
            .accessibilityValue(String(format: "%.0f%%", used * 100))
            Text(snapshot.title + " · " + ByteFormat.storageString(snapshot.measuredBytes) + " · "
                 + StorageCapacityPresentation.snapshotNote(isComplete: snapshot.isComplete, path: snapshot.path))
                .font(.system(size: 11))
                .foregroundStyle(CareStudioInk.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
#if DEBUG
        .layoutProbe("careStudio.spaceLens.usage")
#endif
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CareStudioInk.secondary)
                .monospacedDigit()
        }
    }

    // MARK: List

    private var listPanel: some View {
        VStack(spacing: 0) {
            sidebarSegments
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
            Rectangle().fill(CareStudioInk.hairline).frame(height: 1)
            if surface == 1 {
                LightfieldDonutChart(items: types, centerValue: ByteFormat.storageString(result.rootSnapshot.measuredBytes),
                                     centerLabel: L10n.text("\(ByteFormat.count(fileCount)) 个文件",
                                                            "\(ByteFormat.count(fileCount)) files"),
                                     selectedID: highlightedType, onSelect: toggleType)
                    .padding(12)
                    .frame(maxHeight: .infinity)
            } else if surface == 3 && (treemapSource.isFinding || treemapSource.worthVersion != dataVersion) {
                Text(SpaceLensWorthALook.findingTitle)
                    .font(.system(size: 13)).foregroundStyle(CareStudioInk.secondary)
                    .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if entries.isEmpty {
                // CleanMyMac's "too empty to visualize": an empty folder says so.
                VStack(spacing: 10) {
                    CareStudioFamilyMark(family: nil, art: .stateEmpty, side: 64)
                    Text(surface == 3 ? SpaceLensWorthALook.emptyTitle : activeFilter.map { SpaceLensWorthALook.emptyFilterTitle($0.keyword) }
                         ?? L10n.text("这一层没有可显示的项目", "Nothing to Show Here"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CareStudioInk.primary)
                    Text(surface == 3 ? SpaceLensWorthALook.emptyDescription : activeFilter == nil
                         ? L10n.text("这个文件夹里没有已索引的项目。", "This folder has no indexed items.") : "")
                        .font(.system(size: 12))
                        .foregroundStyle(CareStudioInk.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
#if DEBUG
                .layoutProbe("careStudio.spaceLens.empty")
#endif
            } else {
                ScrollViewReader { scroll in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in row(entry).id(entry.id) }
                            if let purgeable = SpaceLensPurgeable.bytes(result: result, surface: surface,
                                                                        snapshot: snapshot,
                                                                        filtered: activeFilter != nil) {
                                // D193②: an identity of its own in the lazy list (the 11th
                                // test build read it as part of the last folder's row).
                                purgeableRow(purgeable).id("spaceLens.purgeable")
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: highlightedID) { _, id in
                        if let id { scroll.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
            .fill(CareStudioInk.panelFill))
        .overlay(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
            .strokeBorder(CareStudioInk.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous))
#if DEBUG
        .layoutProbe("careStudio.spaceLens.list")
        .background { if surface == 3 { Color.clear.layoutProbe("careStudio.spaceLens.worth") } }
#endif
    }

    /// Keep the original spacing while it fits; only the smallest sidebars
    /// need tighter gaps or two rows to keep every title complete.
    private var sidebarSegments: some View {
        let titles = [L10n.text("目录", "Folders"), L10n.text("文件类型", "File Types"),
                      L10n.text("最大的文件", "Largest Files"), L10n.text("值得一看", "Worth a Look")]
        return ViewThatFits(in: .horizontal) {
            LightfieldTextSegments(titles: titles, selection: $surface, module: .largeFiles, spacing: 26)
                .fixedSize(horizontal: true, vertical: false).frame(height: 34)
            LightfieldTextSegments(titles: titles, selection: $surface, module: .largeFiles, spacing: 20)
                .fixedSize(horizontal: true, vertical: false).frame(height: 34)
            LightfieldTextSegments(titles: titles, selection: $surface, module: .largeFiles, spacing: 14)
                .fixedSize(horizontal: true, vertical: false).frame(height: 34)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<2) { row in
                    LightfieldTextSegments(titles: Array(titles[(row * 2)..<(row * 2 + 2)]),
                        selection: Binding(get: { surface - row * 2 }, set: { surface = $0 + row * 2 }),
                        module: .largeFiles, spacing: 14).frame(height: 34)
                }
            }
        }
    }

    /// One item: its tick (or lock), its icon (an app's own), name and share
    /// (or path, for the largest files), size; folders open, files toggle.
    private func row(_ entry: StorageTreemapEntry) -> some View {
        let type = LightfieldFileCategory.category(entry.contentCategory)
        let state = selectionState(entry)
        let measured = surface == 3 ? result.rootSnapshot.measuredBytes : snapshot.measuredBytes
        let share = measured > 0 ? Double(entry.sizeBytes) / Double(measured) : 0
        return HStack(spacing: 10) {
            LightfieldAnalysisCheckbox(state: state, title: entry.title, isBusy: isBusy) { onToggle(entry) }
#if DEBUG
                .layoutProbe("careStudio.spaceLens.check." + entry.id)
#endif
            CachedAppIconView(path: entry.path.hasSuffix(".app") ? entry.path : "", size: 26) {
                Image(nsImage: SpaceLensKindIcon.image(isDirectory: entry.isDirectory, path: entry.path))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            }
            Button { openOrSelect(entry) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CareStudioInk.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if surface == 2 || surface == 3 {
                        Text(surface == 3 ? treemapSource.worthRows.first(where: { $0.id == entry.id })?.subtitle ?? "" : entry.path)
                            .font(.system(size: 11))
                            .foregroundStyle(CareStudioInk.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        LightfieldDataBar(progress: share, module: .largeFiles, style: .share,
                                          color: FeatureLightfieldPalette.fileType(type),
                                          accessibilityLabel: entry.title + L10n.text("占比", " share"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .disabled(isBusy)
            .help(entry.path)
            .accessibilityLabel(entry.title + " · " + entry.path)
            .accessibilityHint(entry.canDescend ? L10n.text("进入目录", "Open folder")
                               : FileAnalysisTrashPresentation.checkboxHelp(state: state))
#if DEBUG
            .layoutProbe("careStudio.spaceLens.open." + entry.id)
#endif
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.storageString(entry.sizeBytes))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CareStudioInk.primary)
                Text(entry.isEstimated ? L10n.text("估算", "Estimated") : String(format: "%.1f%%", share * 100))
                    .font(.system(size: 11))
                    .foregroundStyle(CareStudioInk.tertiary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: 70, alignment: .trailing)
            .help(StorageCapacityPresentation.rowHelp(entry))
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CareStudioInk.tertiary)
                .opacity(entry.canDescend && surface != 2 ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(highlightedID == entry.id ? Color.white.opacity(0.08) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(CareStudioInk.hairline).frame(height: 1) }
        .onHover { highlightedID = $0 ? entry.id : nil }
        .contextMenu {
            Button(L10n.text("快速查看", "Quick Look")) { quickLookURL = URL(fileURLWithPath: entry.path) }
            Button(L10n.text("在访达中显示", "Show in Finder")) { onReveal(entry.path) }
            Button(L10n.text("复制路径", "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
        }
#if DEBUG
        .layoutProbe("careStudio.spaceLens.row." + entry.id)
#endif
    }

    /// D193② (CleanMyMac's Purgeable Space node): listed on its own at the
    /// top of a disk, not selectable and not a folder; macOS manages it.
    private func purgeableRow(_ bytes: Int64) -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 20, height: 20) // where the other rows' checkbox is
            // macOS frees it over time by itself (a recycle mark would read
            // as something to clean).
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CareStudioInk.secondary)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(SpaceLensPurgeable.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CareStudioInk.primary)
                    .lineLimit(1)
                Text(SpaceLensPurgeable.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(CareStudioInk.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(ByteFormat.storageString(bytes))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CareStudioInk.primary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 70, alignment: .trailing)
            // Keeps the size where the other rows put theirs.
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        // One element of its own, named and sized: combined from its texts,
        // the 11th test build read it as part of the row above ("0 bytes
        // 0.0% Purgeable Space… 126.68 GB", help "/var").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpaceLensPurgeable.title)
        .accessibilityValue(ByteFormat.storageString(bytes))
        .accessibilityHint(SpaceLensPurgeable.detail)
        .accessibilityIdentifier("careStudio.spaceLens.purgeable")
        .help(SpaceLensPurgeable.detail)
#if DEBUG
        .layoutProbe("careStudio.spaceLens.purgeable")
#endif
    }

    // MARK: Bubbles

    private var mapPanel: some View {
        VStack(spacing: 0) {
            if surface == 0 {
                mapControls
#if DEBUG
                .layoutProbe("careStudio.spaceLens.mapStyle")
#endif
            } else {
                Color.clear.frame(height: 34)
            }
            Color.clear.frame(height: 1)
            if showsBlocks {
                SpaceMapTreemapView(result: result, snapshot: snapshot, navigation: navigation,
                    dataVersion: dataVersion, source: treemapSource, levels: $mapLevels, isBusy: isBusy, browseFailed: browseFailed,
                    highlightedID: highlightedID, checkedPaths: checkedPaths, selectionState: selectionState, onHighlight: { highlightedID = $0 },
                    onOpen: onOpen, onToggle: onToggle, onBreadcrumb: onBreadcrumb, onForward: onForward,
                    onQuickLook: { quickLookURL = URL(fileURLWithPath: $0) }, onReveal: onReveal,
                    filter: activeFilter, filterKeyword: keyword, colorMode: mapColorMode,
                    onFocusFilter: { filterFocused = true })
                    .background(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                        .fill(CareStudioInk.panelFill))
                    .overlay(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous)
                        .strokeBorder(CareStudioInk.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: CareStudioMetrics.tileCorner, style: .continuous))
#if DEBUG
                    .layoutProbe("careStudio.spaceLens.blocks")
#endif
                mapLegend
            } else {
                bubbles
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func styleControl(spacing: CGFloat) -> some View {
        LightfieldTextSegments(titles: [L10n.text("气泡", "Bubbles"), L10n.text("方块", "Blocks")],
            selection: Binding(get: { mapStyle == .bubbles ? 0 : 1 }, set: { mapStyle = $0 == 0 ? .bubbles : .blocks }),
            module: .largeFiles, spacing: spacing)
            .fixedSize(horizontal: true, vertical: false).frame(height: 34)
    }

    private func colorControl(spacing: CGFloat) -> some View {
        LightfieldTextSegments(titles: [L10n.text("类型", "Type"), L10n.text("用途", "Purpose")],
            selection: Binding(get: { mapColorMode == .type ? 0 : 1 }, set: { mapColorMode = $0 == 0 ? .type : .purpose }),
            module: .largeFiles, spacing: spacing)
            .fixedSize(horizontal: true, vertical: false).frame(height: 34)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("着色方式", "Color by"))
#if DEBUG
            .layoutProbe("careStudio.spaceLens.colorMode")
#endif
    }

    private var depthControl: some View {
        HStack(spacing: 8) {
            Button { mapLevels = max(1, mapLevels - 1) } label: { Image(systemName: "minus") }
                .disabled(mapLevels <= 1).help(L10n.text("减少层数", "Fewer levels"))
            Text(L10n.text("\(mapLevels) 层", "\(mapLevels) Levels"))
                .font(.system(size: 11, weight: .medium)).monospacedDigit().fixedSize()
            Button { mapLevels = min(6, mapLevels + 1) } label: { Image(systemName: "plus") }
                .disabled(mapLevels >= 6).help(L10n.text("增加层数", "More levels"))
            Button { mapFullWidth.toggle() } label: {
                Image(systemName: mapFullWidth ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 24, height: 28)
            }
            .help(mapFullWidth ? L10n.text("显示列表", "Show List") : L10n.text("全宽显示", "Full Width"))
            .accessibilityLabel(mapFullWidth ? L10n.text("显示列表", "Show List") : L10n.text("全宽显示", "Full Width"))
        }.fixedSize()
#if DEBUG
        .layoutProbe("careStudio.spaceLens.depth")
#endif
    }

    private func mapControlsRow(spacing: CGFloat) -> some View {
        HStack(spacing: 0) {
            styleControl(spacing: spacing)
            if showsBlocks {
                controlSeparator
#if DEBUG
                    .layoutProbe("careStudio.spaceLens.controlSeparator.style")
#endif
                colorControl(spacing: spacing)
                if activeFilter != nil { matchCount.padding(.leading, 12) }
                controlSeparator
#if DEBUG
                    .layoutProbe("careStudio.spaceLens.controlSeparator.depth")
#endif
                depthControl
            }
        }
    }

    private var controlSeparator: some View {
        Rectangle().fill(CareStudioInk.hairline).frame(width: 1, height: 16)
            .padding(.horizontal, 10)
            .accessibilityHidden(true)
    }

    private var mapControls: some View {
        ViewThatFits(in: .horizontal) {
            mapControlsRow(spacing: 26)
            mapControlsRow(spacing: 20)
            mapControlsRow(spacing: 14)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) { styleControl(spacing: 14); matchCount }
                if showsBlocks { HStack { colorControl(spacing: 14); Spacer(minLength: 0); depthControl } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(CareStudioRowButtonStyle()).foregroundStyle(CareStudioInk.primary)
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var matchCount: some View {
        if let activeFilter {
            Text(SpaceLensWorthALook.matchesTitle(activeFilter))
                .font(.system(size: 11)).foregroundStyle(CareStudioInk.secondary).lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
#if DEBUG
                .layoutProbe("careStudio.spaceLens.matches")
#endif
        }
    }

    private var mapLegend: some View {
        // Both grids reserve space so changing colours cannot resize the map.
        ZStack(alignment: .topLeading) {
            mapLegendGrid(mode: .type)
            mapLegendGrid(mode: .purpose)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .fixedSize(horizontal: false, vertical: true)
#if DEBUG
        .layoutProbe("careStudio.spaceLens.legend")
#endif
    }

    private func mapLegendGrid(mode: SpaceMapColorMode) -> some View {
        let active = mode == mapColorMode
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], alignment: .leading, spacing: 6) {
            ForEach(SpaceMapTreemapPainter.legendItems(mode: mode)) { item in
                let content = legend(color: item.fill.color(dark: colorScheme == .dark), title: item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if active {
                    content.help(item.help)
#if DEBUG
                        .layoutProbe("careStudio.spaceLens.legend.\(item.id)")
#endif
                } else {
                    content
                }
            }
        }
        .opacity(active ? 1 : 0)
        .allowsHitTesting(active)
        .accessibilityHidden(!active)
    }

    private var bubbles: some View {
        LightfieldBubbleChart(items: chartItems, onHighlight: { highlightedID = $0 }, onDrillDown: { id in
            if surface == 1 { toggleType(id) }
            else if let entry = entries.first(where: { $0.id == id }) { openOrSelect(entry) }
        }, highlightedID: highlightedID,
            emphasizedIDs: surface == 1 ? highlightedType.map { Set([$0]) } : nil)
#if DEBUG
            .layoutProbe("careStudio.spaceLens.bubbles")
#endif
    }

    private func openOrSelect(_ entry: StorageTreemapEntry) {
        guard !isBusy else { return }
        if surface == 3 { onOpenFromRoot(entry); surface = 0; return }
        if entry.canDescend { onOpen(entry) } else { onToggle(entry) }
    }

    private func clearFilter() { filterText = ""; filterFocused = false }

    private func toggleType(_ id: String) { highlightedType = highlightedType == id ? nil : id }
}

/// Finder's icon for a kind of item — a folder, or a file by its extension —
/// read once per kind (nothing is read from the item itself); an app shows
/// its own icon through `CachedAppIconView`.
@MainActor
enum SpaceLensKindIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(isDirectory: Bool, path: String) -> NSImage {
        let key = isDirectory ? "/folder" : (path as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
