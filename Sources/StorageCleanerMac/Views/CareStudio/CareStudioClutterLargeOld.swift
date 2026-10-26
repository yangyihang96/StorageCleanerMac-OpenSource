import AppKit
import SwiftUI

/// D221: Large & Old Files in the clutter manager (CleanMyMac's fourth My
/// Clutter category, our wording): the large-file list's files, narrowed by
/// kind, size and when each was last opened, none checked at first, and a
/// review before the checked ones move to the Trash.
struct CareStudioLargeOldManager: View {
    let store: ScanStore
    @ObservedObject private var largeOld: LargeOldFilesStore
    @ObservedObject private var largeFiles: LargeFilesStore
    private let categories: AnyView
    private let onBack: () -> Void

    init(store: ScanStore, categories: AnyView, onBack: @escaping () -> Void) {
        self.store = store
        let largeOld = ToolboxStores.of(store).largeOldFiles
        _largeOld = ObservedObject(wrappedValue: largeOld)
        _largeFiles = ObservedObject(wrappedValue: largeOld.largeFiles)
        self.categories = categories
        self.onBack = onBack
    }

    var body: some View {
        let shown = largeOld.visibleRows
        CareStudioManagerChrome(
            module: .clutter,
            title: L10n.text("杂乱文件管理器", "My Clutter Manager"),
            query: $largeOld.searchText,
            searchPrompt: L10n.text("搜索名称或路径", "Search Name or Path"),
            sortTitle: largeOld.sort.title,
            sortOptions: LargeOldFileSort.allCases.map { (id: $0.id, title: $0.title) },
            onSort: { id in largeOld.sort = LargeOldFileSort(rawValue: id) ?? largeOld.sort },
            categoryWidth: 220,
            selectionSummary: status,
            primaryTitle: L10n.text("移到废纸篓…", "Move to Trash…"),
            primaryEnabled: !largeOld.selectedIDs.isEmpty && largeOld.canEdit,
            onPrimary: largeOld.requestTrashReview,
            onBack: onBack,
            categories: { categories },
            content: { CareStudioLargeOldList(store: store, largeOld: largeOld, largeFiles: largeFiles, shown: shown) },
            footerDetail: { footerDetail(shown) })
        .sheet(isPresented: Binding(get: { largeOld.trashPlan != nil },
                                    set: { if !$0 { largeOld.cancelReview() } })) {
            if let plan = largeOld.trashPlan {
                LargeOldFilesReviewSheet(largeOld: largeOld, plan: plan)
            }
        }
    }

    private var status: String {
        if largeOld.isMoving { return L10n.text("正在移到废纸篓…", "Moving to the Trash…") }
        if largeOld.isPreparingReview { return L10n.text("正在核对选中的文件…", "Checking the selected files…") }
        return FileAnalysisTrashPresentation.selectionSummary(count: largeOld.selectedIDs.count, bytes: largeOld.selectedBytes)
    }

    private func footerDetail(_ shown: [LargeOldFileRow]) -> some View {
        Menu(L10n.text("更多", "More")) {
            Button(L10n.text("选择显示的 \(ByteFormat.count(shown.count)) 个文件", "Select the \(L10n.items(shown.count)) Shown")) {
                largeOld.selectAll(shown)
            }
            .disabled(shown.isEmpty || !largeOld.canEdit)
            Button(L10n.text("取消选择", "Clear Selection"), action: largeOld.clearSelection)
                .disabled(largeOld.selectedIDs.isEmpty || !largeOld.canEdit)
            Button(L10n.text("清除筛选", "Clear Filters"), action: largeOld.clearFilters)
                .disabled(largeOld.filters.isEmpty)
            Divider()
            Button(L10n.text("重新扫描大型文件", "Scan Large Files Again"), action: largeFiles.startScan)
                .disabled(!largeFiles.canScan || !largeOld.canEdit)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(CareStudioManagerInk.accent)
        .font(.system(size: 12, weight: .semibold))
    }
}

/// The category row, counting the files it would show.
struct CareStudioLargeOldCategoryRow: View {
    @ObservedObject private var largeOld: LargeOldFilesStore
    @ObservedObject private var largeFiles: LargeFilesStore
    private let isSelected: Bool
    private let action: () -> Void

    init(largeOld: LargeOldFilesStore, isSelected: Bool, action: @escaping () -> Void) {
        _largeOld = ObservedObject(wrappedValue: largeOld)
        _largeFiles = ObservedObject(wrappedValue: largeOld.largeFiles)
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        CareStudioManagerCategoryRow(module: .clutter, title: IgnoreCategory.largeAndOld.title,
                                     systemImage: "doc.badge.clock",
                                     detail: largeOld.hasList ? "\(largeOld.rows.count)" : nil,
                                     isSelected: isSelected, art: .migration, action: action)
    }
}

private struct CareStudioLargeOldList: View {
    let store: ScanStore
    @ObservedObject var largeOld: LargeOldFilesStore
    @ObservedObject var largeFiles: LargeFilesStore
    let shown: [LargeOldFileRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(IgnoreCategory.largeAndOld.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.text("体积较大、很久没打开的文件；默认一个都不选，移走前逐个审阅。",
                               "Big files you have not opened in a while; none is selected by default and each is reviewed before it moves."))
                    .font(.system(size: 12))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if largeOld.hasList {
                filterBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            if let notice = largeOld.notice {
                noticeRow(notice)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if !largeOld.hasList {
            VStack(spacing: 12) {
                CareStudioManagerEmptyState(
                    art: .migration,
                    title: largeFiles.isScanning
                        ? L10n.text("正在扫描大型文件…", "Scanning for large files…")
                        : L10n.text("还没有大型文件清单", "No Large-File List Yet"),
                    detail: L10n.text("这里列出“文件搬家”大文件扫描找到的文件。扫描只读取，不会移动任何文件。",
                                      "This lists the files the File Migration large-file scan finds. The scan only reads; nothing is moved."))
                if largeFiles.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    CareStudioPillButton(title: L10n.text("扫描大型文件", "Scan Large Files"), filled: true, action: largeFiles.startScan)
                        .disabled(!largeFiles.canScan)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
        } else if shown.isEmpty {
            CareStudioManagerEmptyState(title: emptyTitle)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { row in
                        CareStudioLargeOldRow(row: row, isSelected: largeOld.selectedIDs.contains(row.id), canEdit: largeOld.canEdit,
                                              onToggle: { largeOld.setSelected(!largeOld.selectedIDs.contains(row.id), row: row) },
                                              onReveal: { store.reveal(row.path) },
                                              onCopyPath: { store.copyPath(row.path) },
                                              onIgnore: { largeOld.ignore([row], feedback: store.ignoreFeedback) })
                        Rectangle().fill(CareStudioManagerInk.separator).frame(height: 1).padding(.leading, 16)
                    }
                }
                .padding(.bottom, 12)
            }
#if DEBUG
            .layoutProbe("careStudio.manager.clutter.largeOld")
#endif
        }
    }

    private var emptyTitle: String {
        if !largeOld.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return L10n.text("没有匹配的结果", "No Matching Results")
        }
        if !largeOld.filters.isEmpty {
            return L10n.text("没有符合筛选条件的文件", "No Files Match the Filters")
        }
        return L10n.text("这一类没有找到文件", "Nothing Was Found Here")
    }

    // MARK: Filters

    /// The three filters in a row, or one under another when the panel is
    /// narrow.
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                filterMenus
                clearFiltersButton
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                filterMenus
                clearFiltersButton
            }
        }
        .font(.system(size: 12, weight: .semibold))
#if DEBUG
        .layoutProbe("careStudio.manager.clutter.largeOld.filters")
#endif
    }

    @ViewBuilder
    private var filterMenus: some View {
        filterMenu(L10n.text("类型", "Kind"), chosen: LargeOldFileType.allCases.filter(largeOld.filters.types.contains).map(\.title)) {
            ForEach(LargeOldFileType.allCases) { type in
                Toggle(isOn: Binding(get: { largeOld.filters.types.contains(type) }, set: { _ in largeOld.toggle(type) })) {
                    Text(verbatim: "\(type.title)  \(ByteFormat.count(largeOld.count(type)))")
                }
            }
        }
        filterMenu(L10n.text("大小", "Size"), chosen: LargeOldFileSize.allCases.filter(largeOld.filters.sizes.contains).map(\.title)) {
            ForEach(LargeOldFileSize.allCases) { size in
                Toggle(isOn: Binding(get: { largeOld.filters.sizes.contains(size) }, set: { _ in largeOld.toggle(size) })) {
                    Text(L10n.text("\(size.title)（\(size.range)）  \(ByteFormat.count(largeOld.count(size)))",
                                   "\(size.title) (\(size.range))  \(ByteFormat.count(largeOld.count(size)))"))
                }
            }
        }
        filterMenu(L10n.text("上次打开", "Last Opened"), chosen: LargeOldFileAge.allCases.filter(largeOld.filters.ages.contains).map(\.title)) {
            ForEach(LargeOldFileAge.allCases) { age in
                Toggle(isOn: Binding(get: { largeOld.filters.ages.contains(age) }, set: { _ in largeOld.toggle(age) })) {
                    Text(verbatim: "\(age.title)  \(ByteFormat.count(largeOld.count(age)))")
                }
            }
            Divider()
            Text(largeOld.isReadingDates
                 ? L10n.text("正在读取上次打开时间…", "Reading when files were last opened…")
                 : L10n.text("没有打开记录的文件按修改时间算", "Files never opened count by their modification date"))
        }
    }

    @ViewBuilder
    private var clearFiltersButton: some View {
        if !largeOld.filters.isEmpty {
            Button(L10n.text("清除筛选", "Clear Filters"), action: largeOld.clearFilters)
                .buttonStyle(CareStudioRowButtonStyle())
                .foregroundStyle(CareStudioManagerInk.accent)
        }
    }

    private func filterMenu<Items: View>(_ title: String, chosen: [String], @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Text(chosen.isEmpty ? L10n.text("\(title)：全部", "\(title): All")
                 : L10n.text("\(title)：\(chosen.joined(separator: "、"))", "\(title): \(chosen.joined(separator: ", "))"))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(chosen.isEmpty ? CareStudioManagerInk.secondary : CareStudioManagerInk.accent)
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
            Button(action: largeOld.dismissNotice) {
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

/// One file: tick, kind, name, when it was last opened (or that it never
/// was, with its modification date), size, and a way into Finder.
private struct CareStudioLargeOldRow: View {
    let row: LargeOldFileRow
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
                .accessibilityLabel(row.item.title)
            CareStudioGlyph(module: .clutter, systemImage: row.type.systemImage, side: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(LargeOldFilesPresentation.dateText(row)) · \((row.path as NSString).abbreviatingWithTildeInPath)")
                    .font(.system(size: 11))
                    .foregroundStyle(row.dateIsLastOpened ? CareStudioManagerInk.secondary : CareStudioManagerInk.warning)
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
        .padding(.horizontal, 16)
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
            // D225 补: “复制路径”, as everywhere in the app (this row said “拷贝路径”).
            Button(L10n.text("复制路径", "Copy Path"), action: onCopyPath)
        }
    }
}

/// D221 (D46, D93): Large & Old Files' review before the checked files move.
struct LargeOldFilesReviewSheet: View {
    @ObservedObject var largeOld: LargeOldFilesStore
    let plan: LargeOldFilesTrashPlan

    var body: some View {
        ClutterTrashReviewSheet(
            review: plan.review,
            detail: L10n.text("只移动标为可移动的文件；每个文件移动前会再核对一次，有变化的会跳过。",
                              "Only files marked as ready move; each is checked again just before it moves, and changed files are skipped."),
            notice: largeOld.notice, isMoving: largeOld.isMoving,
            onCancel: largeOld.cancelReview, onConfirm: largeOld.confirmTrash)
#if DEBUG
            .layoutProbe("careStudio.manager.clutter.largeOld.review")
#endif
    }
}

/// D221, D226 (D46, D93): every checked item with whether it can move and
/// why not, the six confirmation facts, and the move itself. Return never
/// moves anything.
struct ClutterTrashReviewSheet: View {
    let review: FileAnalysisTrashReview
    let detail: String
    let notice: String?
    let isMoving: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var permission: OperationPermissionCoverage = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("审阅后移到废纸篓", "Review Before Moving to the Trash"))
                    .font(.system(size: 20, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OperationConfirmationFactsView(facts: .fileAnalysis(review, permission: permission), showsItemList: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(review.items) { item in
                        reviewRow(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            Text(FileAnalysisTrashPresentation.trashFootnote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.text("取消", "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isMoving)
                Spacer()
                if isMoving { ProgressView().controlSize(.small) }
                Button(L10n.text("移到废纸篓", "Move to Trash"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(review.readyItems.isEmpty || isMoving)
            }
        }
        .padding(24)
        .frame(width: 600)
        .interactiveDismissDisabled(isMoving)
        .task { permission = .from(ScanReadinessService.fullDiskAccessState()) }
    }

    private func reviewRow(_ item: FileAnalysisTrashReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(item.selection.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(ByteFormat.storageString(item.selection.bytes))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(item.selection.path)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if case .blocked(let block) = item.status {
                Text(FileAnalysisTrashPresentation.reviewBlockNote(block, applications: review.unknownRunningApplicationNames))
                    .font(.system(size: 11))
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if item.hasOtherHardLinks {
                Text(FileAnalysisTrashPresentation.otherHardLinksNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
