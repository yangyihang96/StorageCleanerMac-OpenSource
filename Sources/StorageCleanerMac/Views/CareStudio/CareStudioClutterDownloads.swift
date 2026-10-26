import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// D226: Downloads in the clutter manager (CleanMyMac's downloads category,
/// our wording): what is at the top of the Downloads folder apart from
/// installers, grouped by where it came from, none checked at first, and a
/// review before the checked items move to the Trash. The line at the bottom
/// leads to Applications → Installers, where installers are listed.
struct CareStudioDownloadsManager: View {
    let store: ScanStore
    @ObservedObject private var downloads: DownloadsStore
    private let categories: AnyView
    private let onBack: () -> Void

    init(store: ScanStore, categories: AnyView, onBack: @escaping () -> Void) {
        self.store = store
        _downloads = ObservedObject(wrappedValue: ToolboxStores.of(store).downloads)
        self.categories = categories
        self.onBack = onBack
    }

    var body: some View {
        let groups = downloads.groups
        CareStudioManagerChrome(
            module: .clutter,
            title: L10n.text("杂乱文件管理器", "My Clutter Manager"),
            query: $downloads.searchText,
            searchPrompt: L10n.text("搜索名称、路径或来源", "Search Name, Path or Source"),
            sortTitle: downloads.sort.title,
            sortOptions: DownloadSort.allCases.map { (id: $0.id, title: $0.title) },
            onSort: { id in downloads.sort = DownloadSort(rawValue: id) ?? downloads.sort },
            categoryWidth: 220,
            selectionSummary: status,
            primaryTitle: L10n.text("移到废纸篓…", "Move to Trash…"),
            primaryEnabled: !downloads.selectedRows.isEmpty && downloads.canEdit,
            onPrimary: downloads.requestTrashReview,
            onBack: onBack,
            categories: { categories },
            content: { CareStudioDownloadsList(store: store, downloads: downloads, groups: groups) },
            footerDetail: { footerDetail(groups.flatMap(\.rows)) })
        .sheet(isPresented: Binding(get: { downloads.trashPlan != nil },
                                    set: { if !$0 { downloads.cancelReview() } })) {
            if let plan = downloads.trashPlan {
                ClutterTrashReviewSheet(
                    review: plan.review,
                    detail: L10n.text("只移动标为可移动的项目；每一项移动前会再核对一次，文件夹会和读取时逐层比对，有变化的会跳过。",
                                      "Only items marked as ready move; each is checked again just before it moves, a folder all the way down, and changed items are skipped."),
                    notice: downloads.notice, isMoving: downloads.isMoving,
                    onCancel: downloads.cancelReview, onConfirm: downloads.confirmTrash)
#if DEBUG
                    .layoutProbe("careStudio.manager.clutter.downloads.review")
#endif
            }
        }
        // Opened from the category column before any clutter scan read it.
        .onAppear { downloads.refresh(after: nil) }
    }

    private var status: String {
        if downloads.isMoving { return L10n.text("正在移到废纸篓…", "Moving to the Trash…") }
        if downloads.isPreparingReview { return L10n.text("正在核对选中的项目…", "Checking the selected items…") }
        return FileAnalysisTrashPresentation.selectionSummary(count: downloads.selectedRows.count, bytes: downloads.selectedBytes)
    }

    private func footerDetail(_ shown: [DownloadRow]) -> some View {
        Menu(L10n.text("更多", "More")) {
            Button(L10n.text("选择显示的 \(ByteFormat.count(shown.count)) 个项目", "Select the \(L10n.items(shown.count)) Shown")) {
                downloads.selectAll(shown)
            }
            .disabled(shown.isEmpty || !downloads.canEdit)
            Button(L10n.text("取消选择", "Clear Selection"), action: downloads.clearSelection)
                .disabled(downloads.selectedIDs.isEmpty || !downloads.canEdit)
            Divider()
            Button(L10n.text("重新读取“下载”文件夹", "Read the Downloads Folder Again"), action: downloads.read)
                .disabled(downloads.isReading || !downloads.canEdit)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(CareStudioManagerInk.accent)
        .font(.system(size: 12, weight: .semibold))
    }
}

/// The category row, counting the items it would show.
struct CareStudioDownloadsCategoryRow: View {
    @ObservedObject var downloads: DownloadsStore
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        CareStudioManagerCategoryRow(module: .clutter, title: IgnoreCategory.downloads.title,
                                     systemImage: "arrow.down.circle",
                                     detail: downloads.hasRead ? "\(downloads.rows.count)" : nil,
                                     isSelected: isSelected, art: .tileOtherSources, action: action)
    }
}

private struct CareStudioDownloadsList: View {
    let store: ScanStore
    @ObservedObject var downloads: DownloadsStore
    let groups: [DownloadGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(IgnoreCategory.downloads.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.text("“下载”文件夹里除安装包以外的项目，按下载来源分组；默认一个都不选，移走前逐个审阅。",
                               "What is in the Downloads folder besides installers, grouped by where it came from; none is selected by default and each is reviewed before it moves."))
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if let notice = downloads.notice {
                noticeRow(notice)
            }
            content
                .frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(CareStudioManagerInk.separator).frame(height: 1)
            installersLink
        }
    }

    @ViewBuilder
    private var content: some View {
        if !downloads.hasRead {
            VStack(spacing: 12) {
                if let error = downloads.readError, !downloads.isReading {
                    CareStudioManagerEmptyState(art: .tileOtherSources,
                                                title: L10n.text("没能读取“下载”文件夹", "The Downloads Folder Could Not Be Read"),
                                                detail: error)
                    CareStudioPillButton(title: L10n.text("再试一次", "Try Again"), filled: true, action: downloads.read)
                } else {
                    CareStudioManagerEmptyState(
                        art: .tileOtherSources,
                        title: downloads.isReading
                            ? L10n.text("正在读取“下载”文件夹…", "Reading the Downloads folder…")
                            : L10n.text("还没有读取“下载”文件夹", "The Downloads Folder Has Not Been Read"),
                        detail: L10n.text("只读取名称、大小和下载来源记录，不会打开或移动任何文件。",
                                          "Only names, sizes and download records are read; nothing is opened or moved."))
                    if downloads.isReading {
                        ProgressView().controlSize(.small)
                    } else {
                        CareStudioPillButton(title: L10n.text("读取“下载”文件夹", "Read the Downloads Folder"), filled: true,
                                             action: downloads.read)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
        } else if groups.isEmpty {
            CareStudioManagerEmptyState(title: emptyTitle)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        CareStudioDownloadGroupHeader(group: group, selectedIDs: downloads.selectedIDs, canEdit: downloads.canEdit,
                                                      onToggle: { downloads.toggle(group) })
                        ForEach(group.rows) { row in
                            CareStudioDownloadRow(row: row, isSelected: downloads.selectedIDs.contains(row.id), canEdit: downloads.canEdit,
                                                  onToggle: { downloads.setSelected(!downloads.selectedIDs.contains(row.id), row: row) },
                                                  onReveal: { store.reveal(row.path) },
                                                  onCopyPath: { store.copyPath(row.path) },
                                                  onIgnore: { downloads.ignore([row], feedback: store.ignoreFeedback) })
                            Rectangle().fill(CareStudioManagerInk.separator).frame(height: 1).padding(.leading, 52)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
#if DEBUG
            .layoutProbe("careStudio.manager.clutter.downloads")
#endif
        }
    }

    private var emptyTitle: String {
        downloads.searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? L10n.text("“下载”里没有安装包以外的项目", "Downloads Has Nothing Besides Installers")
            : L10n.text("没有匹配的结果", "No Matching Results")
    }

    /// D226: installers are listed in one place, Applications → Installers;
    /// this line takes you there.
    private var installersLink: some View {
        Button {
            DownloadsPresentation.showInstallers(in: store)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(L10n.text("安装包（dmg、pkg、iso 等）统一在“应用管理 → 安装文件”里查看",
                               "Installers (dmg, pkg, iso and others) are listed under Applications → Installers"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(CareStudioManagerInk.accent)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(CareStudioRowButtonStyle())
        .accessibilityLabel(L10n.text("前往应用管理的安装文件", "Go to Installers in Applications"))
#if DEBUG
        .layoutProbe("careStudio.manager.clutter.downloads.installers")
#endif
    }

    private func noticeRow(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.accent)
                .accessibilityHidden(true)
            Text(notice)
                .font(.system(size: 12))
                .foregroundStyle(CareStudioManagerInk.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: downloads.dismissNotice) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .foregroundStyle(CareStudioManagerInk.secondary)
            .accessibilityLabel(L10n.text("关闭", "Close"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// One source: a tick for the whole group, where the items came from, and
/// how many there are and their size.
private struct CareStudioDownloadGroupHeader: View {
    let group: DownloadGroup
    let selectedIDs: Set<String>
    let canEdit: Bool
    let onToggle: () -> Void

    private var state: TriStateSelection {
        let chosen = group.rows.filter { selectedIDs.contains($0.id) }.count
        if chosen == 0 { return .unchecked }
        return chosen == group.rows.count ? .checked : .mixed
    }

    var body: some View {
        HStack(spacing: 12) {
            CareStudioTriTick(state: state, isEnabled: canEdit, action: onToggle)
                .accessibilityLabel(group.source.title)
            CareStudioGlyph(module: .clutter, systemImage: group.source.systemImage, side: 24)
                .accessibilityHidden(true)
            Text(group.source.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(verbatim: "\(L10n.items(group.rows.count)) · \(ByteFormat.storageString(group.bytes))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(CareStudioManagerInk.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 40)
        .background(CareStudioManagerInk.separator.opacity(0.35))
        .accessibilityElement(children: .contain)
    }
}

/// One item: tick, kind, name, what it is and when it last changed, size,
/// and a way into Finder.
private struct CareStudioDownloadRow: View {
    let row: DownloadRow
    let isSelected: Bool
    let canEdit: Bool
    let onToggle: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onIgnore: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            CareStudioTriTick(state: isSelected ? .checked : .unchecked, isEnabled: canEdit, action: onToggle)
                .accessibilityLabel(row.name)
            CareStudioGlyph(module: .clutter, systemImage: DownloadsPresentation.symbol(row), side: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: DownloadsPresentation.detail(row))
                    .font(.system(size: 11))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.storageString(row.bytes))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(CareStudioManagerInk.secondary)
                .frame(minWidth: 62, alignment: .trailing)
            Button(action: onReveal) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.accent)
                    .frame(width: 20, height: 28)
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .help(L10n.text("在访达中显示", "Show in Finder"))
        }
        .padding(.leading, 28)
        .padding(.trailing, 16)
        .frame(minHeight: 50)
        .background(isHovered ? Color.black.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(row.path)
        .contextMenu {
            Button(L10n.text("在访达中显示", "Show in Finder"), action: onReveal)
            // D207 (CleanMyMac's Add to Ignore List); the note that follows offers Put Back.
            Button(IgnoreListMenu.title(count: 1), action: onIgnore)
                .disabled(!canEdit)
            Button(L10n.text("复制路径", "Copy Path"), action: onCopyPath)
        }
    }
}

extension DownloadsPresentation {
    /// D226: the line at the bottom of Downloads opens Applications on its
    /// Installers category (the landing page first when the apps were never
    /// read).
    @MainActor
    static func showInstallers(in store: ScanStore) {
        ApplicationsManagerModel.of(store).review(.installers)
        store.showFilter(.uninstall)
    }

    /// The row's symbol: a folder, or the kind its name says.
    static func symbol(_ row: DownloadRow) -> String {
        if row.isDirectory, row.kind != "package" { return LargeFileKind.folder.systemImage }
        guard let type = UTType(filenameExtension: (row.name as NSString).pathExtension) else { return LargeFileKind.other.systemImage }
        if type.conforms(to: .archive) { return LargeFileKind.archive.systemImage }
        if type.conforms(to: .movie) { return LargeFileKind.video.systemImage }
        if type.conforms(to: .image) { return LargeFileKind.image.systemImage }
        if type.conforms(to: .audio) { return LargeFileKind.audio.systemImage }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) { return LargeFileKind.document.systemImage }
        return LargeFileKind.other.systemImage
    }
}
