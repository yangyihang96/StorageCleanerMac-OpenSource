import AppKit
import QuickLook
import SwiftUI

struct DuplicateFilesLightfieldView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var store: ScanStore
    @ObservedObject var workspace: DuplicateFilesStore
    let groups: [DuplicateDisplayGroup]
    let allGroups: [DuplicateDisplayGroup]
    let allItems: [StorageItem]
    let isSimilarPhotos: Bool
    let title: String
    @Binding var resultFilter: DuplicateResultFilter
    var details: AnyView? = nil
    /// Similar-photos route only: switches the source to the system Photos library.
    var onUseSystemPhotoLibrary: (() -> Void)? = nil
    @State private var showingDetails = false
    private var selected: [StorageItem] { workspace.selectedItems(from: allItems) }
    private var confirmedGroups: [DuplicateDisplayGroup] { allGroups.filter(\.isContentConfirmed) }
    private var logicalBytes: Int64 { FileLightfieldPresentation.sum(confirmedGroups.map(\.logicalDuplicateBytes)) }
    private var physicalBytes: Int64? {
        guard !confirmedGroups.isEmpty, confirmedGroups.allSatisfy({ $0.physicalReclaimableBytes != nil }) else { return nil }
        return FileLightfieldPresentation.sum(confirmedGroups.compactMap(\.physicalReclaimableBytes))
    }
    private var isBusy: Bool {
        store.duplicateCleanupProgress != nil || store.isDuplicateCleanupConfirmationPresented
            || store.isDuplicateRestoreConfirmationPresented || store.isRestoringRecordedOperation
    }
    var body: some View {
        let amount = FileLightfieldPresentation.amount(logicalBytes)
        let candidates = groups.flatMap(\.items)
        FeatureLightfieldPage(module: .duplicates, phase: .result, title: title,
            status: resultStatus, safety: isSimilarPhotos
                ? L10n.text("相似候选需人工确认 · 默认不选删除", "Review similar candidates · No deletion selected by default")
                : L10n.text("每组至少保留一份 · 物理释放待确认", "Keep at least one copy per group · Physical savings unconfirmed"),
            actionTitle: L10n.text("移到废纸篓 · ", "Move to Trash · ") + ByteFormat.storageString(isSimilarPhotos ? 0 : FileLightfieldPresentation.sum(selected.map(\.sizeBytes))),
            actionEnabled: !isSimilarPhotos && !selected.isEmpty && !isBusy,
            showsArtwork: false, artwork: isSimilarPhotos ? .similarPhotos : nil,
            statusActionTitle: L10n.text("重新扫描", "Scan Again"), statusActionEnabled: workspace.canScan && !isBusy, statusAction: store.scanDuplicateFiles,
            action: { store.requestVerifiedDuplicateCleanup(disposition: .trash, workspace: workspace) }) {
            LightfieldFileResults(summary: LightfieldSummary(module: .duplicates,
                label: isSimilarPhotos ? L10n.text("待审阅相似候选", "Similar Candidates to Review") : L10n.text("逻辑重复数据", "Logical Duplicate Data"),
                value: isSimilarPhotos ? String(groups.count) : amount.0, unit: isSimilarPhotos ? L10n.text("组", "groups") : amount.1,
                secondary: isSimilarPhotos
                    ? [.init(id: "count", label: L10n.text("候选照片", "Candidate Photos"), value: String(candidates.count)),
                        .init(id: "bytes", label: L10n.text("候选总量", "Candidate Size"), value: ByteFormat.storageString(FileLightfieldPresentation.sum(candidates.map(\.sizeBytes))))]
                    : [.init(id: "count", label: L10n.text("内容确认的组", "Confirmed Groups"), value: String(confirmedGroups.count)),
                        .init(id: "physical", label: L10n.text("物理可释放", "Physical Savings"), value: physicalBytes.map { ByteFormat.storageString($0) } ?? L10n.text("待确认", "Unconfirmed"))],
                artwork: isSimilarPhotos ? .similarPhotos : nil)) {
                VStack(spacing: 0) {
                    toolbar
                    FeatureOptionsScrollView(probePrefix: "lightfield.duplicates.list", balancesContent: false,
                        usesLightfield: true, fadesResults: true) {
                        DuplicateLightfieldBody(groups: groups, isSimilarPhotos: isSimilarPhotos,
                            selectedIDs: workspace.selectedItemIDs, isBusy: isBusy,
                            onSelected: { selected, item in workspace.setSelected(selected, item: item, allItems: allItems) },
                            onReveal: { store.reveal($0.path) }, onCopyPath: { store.copyPath($0.path) })
                    }
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("扫描与操作详情", "Scan and Operation Details")).font(.system(size: 24, weight: .semibold))
                    if let details { details }
                    if let error = workspace.errorMessage { Text(error).font(.system(size: 15)) }
                    Button(L10n.text("返回", "Back")) { showingDetails = false }.buttonStyle(FeatureLightfieldRowButtonStyle())
                }.padding(24)
            }.frame(width: 680, height: 440)
        }
    }
    private var resultStatus: String {
        if let progress = store.duplicateCleanupProgress {
            return L10n.text("已处理 \(progress.processedItemCount)/\(progress.totalItemCount) · 移动 \(progress.movedItemCount) · 失败 \(progress.failedItemCount)",
                "Processed \(progress.processedItemCount)/\(progress.totalItemCount) · Moved \(progress.movedItemCount) · Failed \(progress.failedItemCount)")
        }
        if let error = workspace.errorMessage { return error }
        if isSimilarPhotos { return L10n.text("图像指纹相近 · 需要人工确认", "Similar image fingerprints · Manual review required") }
        return FileAnalysisTrashPresentation.selectionSummary(count: selected.count, bytes: FileLightfieldPresentation.sum(selected.map(\.sizeBytes)))
    }
    private var toolbar: some View {
        HStack(spacing: 16) {
            TextField(L10n.text("搜索名称或路径", "Search Name or Path"), text: $workspace.searchText)
                .textFieldStyle(.plain).font(.system(size: 13))
            if !isSimilarPhotos {
                Menu {
                    Picker(L10n.text("结果", "Results"), selection: $resultFilter) {
                        ForEach(DuplicateResultFilter.allCases) { Text($0.title).tag($0) }
                    }
                    Picker(L10n.text("排序", "Sort"), selection: $workspace.resultSort) {
                        ForEach(DuplicateResultSort.allCases) { Text($0.title).tag($0) }
                    }
                    ForEach(DuplicateFileCandidateGroup.Rule.selectableCases) { rule in
                        Button(rule.title) { workspace.setCandidateRule(rule, enabled: !workspace.isCandidateRuleEnabled(rule)) }
                    }
                    Button(L10n.text("取消选择", "Clear Selection"), action: workspace.clearSelection)
                    Button(L10n.text("移到隔离区（推荐）", "Move to Quarantine (Recommended)")) {
                        store.requestVerifiedDuplicateCleanup(disposition: .quarantine, workspace: workspace)
                    }.disabled(selected.isEmpty || isBusy)
                } label: { Text(L10n.text("筛选与操作", "Filters and Actions")) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if store.duplicateCleanupProgress != nil {
                Button(L10n.text("取消剩余项目", "Cancel Remaining"), action: store.cancelVerifiedDuplicateCleanupExecution)
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).fixedSize()
            }
            if isSimilarPhotos, let onUseSystemPhotoLibrary {
                Button(L10n.text("系统照片图库", "System Photo Library"), action: onUseSystemPhotoLibrary)
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).fixedSize().disabled(isBusy)
            }
            Button(L10n.text("详情", "Details")) { showingDetails = true }.buttonStyle(FeatureLightfieldRowButtonStyle()).fixedSize()
        }.font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
            .frame(height: 42).overlay(alignment: .top) { FeatureLightfieldHairline() }
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }
}

struct DuplicateLightfieldBody: View {
    @Environment(\.colorScheme) private var scheme
    let groups: [DuplicateDisplayGroup]
    let isSimilarPhotos: Bool
    let selectedIDs: Set<String>
    var modifiedAt: [String: Date] = [:]
    var isBusy = false
    let onSelected: (Bool, StorageItem) -> Void
    let onReveal: (StorageItem) -> Void
    let onCopyPath: (StorageItem) -> Void
    @State private var keepers: [String: String] = [:]
    @State private var collapsed: Set<String> = []
    @State private var reviewIDs: Set<String> = []
    var body: some View {
        let presentation = DuplicateLightfieldPresentation.make(groups: groups, selectedIDs: selectedIDs,
            preferredKeepers: keepers, modifiedAt: modifiedAt)
        LazyVStack(alignment: .leading, spacing: 0) {
            if !isSimilarPhotos {
                HStack {
                    Text(L10n.text("完整 SHA-256 已确认的副本可清理", "Only full SHA-256 confirmed copies can be cleaned"))
                    Spacer(minLength: 0)
                    Button(L10n.text("自动选择：保留最新", "Auto Select: Keep Newest")) { selectKeepingNewest(presentation) }
                        .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(isBusy || !presentation.canKeepNewest)
                        .lightfieldComponentProbe("lightfield.duplicates.auto-select")
                        .help(L10n.text("所有副本均需有已确认的修改时间；时间未知时不自动选择。", "Every copy needs a confirmed modification date; unknown dates prevent automatic selection."))
                }.font(.system(size: 13)).lineLimit(1).frame(height: 40)
            }
            ForEach(groups) { group in
                LightfieldFileGroupHeader(title: group.title, metadata: metadata(group),
                    icon: isSimilarPhotos ? .duplicatesPhotos : group.items.first.map { FileLightfieldPresentation.chart(entry($0)).icon } ?? .fileanalysisOther,
                    module: .duplicates, expanded: Binding(get: { !collapsed.contains(group.id) }, set: {
                        if $0 { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                    }), height: 52, probeID: "lightfield.duplicates.group." + group.id)
                if !collapsed.contains(group.id) {
                    if group.candidateRule == .similarImage {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], alignment: .leading, spacing: 16) {
                            ForEach(group.items) { item in
                                LightfieldSimilarPhotoTile(item: item, kept: presentation.keeperIDsByGroup[group.id] == item.id,
                                    marked: reviewIDs.contains(item.id), isBusy: isBusy,
                                    onMark: { if reviewIDs.contains(item.id) { reviewIDs.remove(item.id) } else { reviewIDs.insert(item.id) } },
                                    onKeep: { keepers[group.id] = item.id; reviewIDs.remove(item.id) }, onReveal: { onReveal(item) })
                            }
                        }.padding(.vertical, 12)
                    } else {
                        ForEach(group.items) { item in
                            LightfieldDuplicateRow(item: item, kept: presentation.keeperIDsByGroup[group.id] == item.id,
                                selected: selectedIDs.contains(item.id), isConfirmed: group.isContentConfirmed,
                                modifiedAt: presentation.modifiedAtByItemID[item.id], isBusy: isBusy,
                                onToggle: { onSelected(!selectedIDs.contains(item.id), item) },
                                onKeep: { onSelected(false, item); keepers[group.id] = item.id },
                                onReveal: { onReveal(item) }, onCopyPath: { onCopyPath(item) })
                        }
                    }
                }
            }
            if groups.isEmpty {
                Text(L10n.text("没有匹配的结果", "No Matching Results")).font(.system(size: 15)).frame(height: 52)
            }
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
    }
    private func entry(_ item: StorageItem) -> StorageTreemapEntry {
        .init(id: item.id, title: item.title, path: item.path, sizeBytes: item.sizeBytes, kind: item.kind, isDirectory: item.isDirectory)
    }
    private func metadata(_ group: DuplicateDisplayGroup) -> String {
        let count = L10n.text("\(group.items.count) 份 · ", "\(group.items.count) copies · ")
        if group.isContentConfirmed {
            return count + L10n.text("逻辑重复 ", "Logical duplicates ") + ByteFormat.storageString(group.logicalDuplicateBytes)
        }
        return count + L10n.text("人工候选 · ", "Review candidates · ") + ByteFormat.storageString(FileLightfieldPresentation.sum(group.items.map(\.sizeBytes)))
    }
    private func selectKeepingNewest(_ presentation: DuplicateLightfieldPresentation) {
        guard presentation.canKeepNewest, !isBusy else { return }
        for group in groups where group.isContentConfirmed {
            guard let first = presentation.newestItemsByGroup[group.id] else { continue }
            onSelected(false, first); keepers[group.id] = first.id
            for item in group.items where item.status == .available && item.id != first.id { onSelected(true, item) }
        }
    }
}

struct LightfieldDuplicateRow: View {
    @Environment(\.colorScheme) private var scheme
    let item: StorageItem
    let kept: Bool
    let selected: Bool
    let isConfirmed: Bool
    var modifiedAt: Date? = nil
    let isBusy: Bool
    let onToggle: () -> Void
    let onKeep: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    @State private var quickLookURL: URL?
    var body: some View {
        LightfieldMigrationColumns {
            Button(action: onToggle) { FeatureLightfieldCheck(selected: selected, module: .duplicates) }
                .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(isBusy || kept || !isConfirmed || item.status != .available)
                .accessibilityLabel(L10n.text("选择副本：", "Select copy: ") + item.path)
                .accessibilityValue(kept ? L10n.text("保留此份", "Keep this copy") : selected ? L10n.text("已选", "Selected") : L10n.text("未选", "Not selected"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .lightfieldComponentProbe("lightfield.duplicates.select." + item.id)
            LightfieldStatusGlyph(status: isConfirmed ? .normal : .locked).frame(maxWidth: .infinity, maxHeight: .infinity)
            LightfieldPathText(path: item.path).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .lightfieldComponentProbe("lightfield.duplicates.path." + item.id)
            Text(modifiedAt.map { $0.formatted(date: .numeric, time: .omitted) } ?? L10n.text("未知", "Unknown"))
                .font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(ByteFormat.storageString(item.sizeBytes)).font(.system(size: 13)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing) // lightfield-scale-ok
            Menu {
                Button(L10n.text("改为保留此份", "Keep This Copy"), action: onKeep).disabled(isBusy || item.status != .available)
                Button(L10n.text("预览原件", "Quick Look")) { quickLookURL = URL(fileURLWithPath: item.path) }.disabled(item.status != .available)
                Button(L10n.text("在访达中显示", "Show in Finder"), action: onReveal)
                Button(L10n.text("复制路径", "Copy Path"), action: onCopyPath)
            } label: { Text(kept ? L10n.text("保留此份", "Kept") : L10n.text("操作", "Actions")).font(.system(size: 13)).lineLimit(1) }
                .menuStyle(.borderlessButton).frame(maxWidth: .infinity, maxHeight: .infinity)
                .lightfieldComponentProbe("lightfield.duplicates.actions." + item.id)
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            .quickLookPreview($quickLookURL).lightfieldComponentProbe("lightfield.duplicates.row." + item.id)
    }
}

struct LightfieldSimilarPhotoTile: View {
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
#endif
    @Environment(\.colorScheme) private var scheme
    let item: StorageItem
    let kept: Bool
    let marked: Bool
    let isBusy: Bool
    let onMark: () -> Void
    let onKeep: () -> Void
    let onReveal: () -> Void
    @State private var thumbnail: NSImage?
    @State private var unavailableReason: String?
    @State private var quickLookURL: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
                } else {
                    Text(unavailableReason ?? L10n.text("预览未提供", "Preview Unavailable"))
                        .font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button(action: onMark) { FeatureLightfieldCheck(selected: marked, module: .duplicates) }
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(kept || isBusy)
                    .padding(10).accessibilityLabel(L10n.text("比对标记：", "Review mark: ") + item.title)
                    .accessibilityValue(marked ? L10n.text("已标记比对", "Marked for review") : L10n.text("未标记", "Not marked"))
                    .accessibilityHint(L10n.text("仅为人工比对标记，不选择删除", "Manual review mark only; does not select deletion"))
                    .lightfieldComponentProbe("lightfield.photos.mark." + item.id)
            }.frame(height: 102).lightfieldComponentProbe("lightfield.photos.preview." + item.id)
            HStack(spacing: 8) {
                Text(item.title).font(.system(size: 15)).lineLimit(1).truncationMode(.middle).help(item.title)
                Spacer(minLength: 0)
                Text(ByteFormat.storageString(item.sizeBytes)).font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok
            }
            LightfieldPathText(path: item.path)
            HStack(spacing: 12) {
                Button(kept ? L10n.text("建议保留", "Suggested Keep") : L10n.text("改为建议保留", "Suggest Keeping"), action: onKeep)
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(isBusy || item.status != .available)
                    .accessibilityValue(kept ? L10n.text("建议保留", "Suggested Keep") : L10n.text("未指定", "Not suggested"))
                Menu {
                    Button(L10n.text("预览原件", "Quick Look")) { quickLookURL = URL(fileURLWithPath: item.path) }
                    Button(L10n.text("在访达中显示", "Show in Finder"), action: onReveal)
                } label: { Text(L10n.text("查看", "View")) }.menuStyle(.borderlessButton).disabled(item.status != .available)
            }.font(.system(size: 13)).lineLimit(1)
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
            .quickLookPreview($quickLookURL).lightfieldComponentProbe("lightfield.photos.tile." + item.id)
            .task(id: item.id) {
#if DEBUG
                guard !isFixture else { return }
#endif
                guard item.status == .available else { return }
                let loaded = await SimilarImagePreviewCache.shared.loadedIcon(for: item.path)
                guard !Task.isCancelled else { return }
                thumbnail = loaded.image; unavailableReason = loaded.unavailableReason
            }
    }
}
