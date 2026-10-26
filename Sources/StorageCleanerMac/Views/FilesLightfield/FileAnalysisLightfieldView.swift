import AppKit
import QuickLook
import SwiftUI

struct FileAnalysisLightfieldView: View {
    @Environment(\.moduleTheme) private var theme
    /// D154 batch 3G: the studio shows the Space Lens page; the classic
    /// layout keeps this D70 page.
    @Environment(\.careStudioClassicResults) private var usesClassicPages
    @ObservedObject var workspace: LargeFilesStore
    @State private var surface = 0
    @State private var showingScopes = false
    @State private var showingDetails = false
    @State private var showingCapacityNotes = false
    @State private var showingLocalModels = false
    @State private var showingDeviceBackups = false
    @State private var showingCloudCopies = false
    @State private var types: [LightfieldChartItem] = []
    @State private var largest: [StorageTreemapEntry] = []
    @State private var indexedFileCount = 0

    var body: some View {
        if let result = workspace.storageAnalysis {
            page(result)
            .popover(isPresented: $showingScopes) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(workspace.storageMapTargets) { target in
                        Button(target.title) {
                            showingScopes = false
                            workspace.selectedStorageMapTargetID = target.id
                            workspace.startStorageAnalysis()
                        }.buttonStyle(FeatureLightfieldRowButtonStyle()).frame(height: 52)
                            .disabled(!workspace.canStartStorageAnalysis)
                    }
                }.padding(20)
            }
            .sheet(isPresented: Binding(get: {
                workspace.trashReview != nil && (workspace.trashPhase == .reviewing || workspace.trashPhase == .moving)
            }, set: { if !$0 { workspace.cancelTrashReview() } })) {
                if let review = workspace.trashReview {
                    FileAnalysisTrashReviewSheet(workspace: workspace, review: review)
                        .environment(\.locale, L10n.locale).environment(\.moduleTheme, theme)
                }
            }
            .sheet(isPresented: $showingDetails) { operationDetails }
            .sheet(isPresented: $showingCapacityNotes) {
                StorageCapacityNotesSheet(onClose: { showingCapacityNotes = false })
                    .environment(\.locale, L10n.locale).environment(\.moduleTheme, theme)
            }
            .sheet(isPresented: $showingCloudCopies) {
                CloudLocalCopySheet(entries: StorageTreemapPresentation.visibleEntries(from: workspace.storageMapNavigation.last ?? result.rootSnapshot),
                    coordinator: workspace.cloudLocalCopyCoordinator, onClose: { showingCloudCopies = false })
                    .environment(\.locale, L10n.locale).environment(\.moduleTheme, theme)
            }
            .sheet(isPresented: $showingLocalModels) {
                LocalModelInventorySheet(onClose: { showingLocalModels = false })
                    .environment(\.locale, L10n.locale).environment(\.moduleTheme, theme)
            }
            .sheet(isPresented: $showingDeviceBackups) {
                MobileDeviceBackupInventorySheet(onClose: { showingDeviceBackups = false })
                    .environment(\.locale, L10n.locale).environment(\.moduleTheme, theme)
            }
            .task(id: "\(result.target.id)|\(result.scanSeconds)|\(result.inspectedItemCount)|\(result.rootSnapshot.measuredBytes)") {
                // Presentation aggregation uses the completed immutable index, never a new walk.
                let index = result.index
                let values = await Task.detached(priority: .utility) {
                    (FileLightfieldPresentation.largest(index), FileLightfieldPresentation.fileCount(index))
                }.value
                guard !Task.isCancelled else { return }
                largest = values.0; indexedFileCount = values.1
                types = FileLightfieldPresentation.types(result)
            }
        }
    }
    @ViewBuilder private func page(_ result: StorageMapAnalysisResult) -> some View {
        if usesClassicPages {
            resultPage(result)
        } else {
            CareStudioSpaceLensPage(result: result, navigation: workspace.storageMapNavigation,
                types: types, largest: largest, fileCount: indexedFileCount, surface: $surface,
                mapStyle: $workspace.storageMapStyle, mapColorMode: $workspace.storageMapColorMode,
                dataVersion: workspace.storageMapDataVersion,
                isBusy: workspace.trashPhase != .idle || workspace.storageMapBrowsePhase.isLoading,
                browseFailed: browseFailed,
                checkedPaths: Set(workspace.trashSelections.map(\.path)),
                selectionState: workspace.trashSelectionState, selectedBytes: workspace.selectedTrashBytes,
                selectionReclaim: workspace.selectionReclaim, isEstimatingReclaim: workspace.isEstimatingSelectionReclaim,
                status: status, canReview: workspace.canReviewTrash, onReview: workspace.requestTrashReview,
                onToggle: workspace.toggleTrashSelection,
                onOpen: { workspace.openStorageMapDirectory($0) },
                onBreadcrumb: { workspace.showStorageMapSnapshot(at: $0) },
                onOpenFromRoot: { workspace.openStorageMapDirectory($0, fromLevel: 0) },
                onForward: workspace.showNextStorageMapLevel,
                notice: browseNotice,
                onRetry: browseFailed ? { workspace.retryStorageMapBrowse() } : nil,
                onChangeScope: workspace.canStartStorageAnalysis ? { showingScopes = true } : nil,
                onDetails: { showingDetails = true },
                onCapacityNotes: { showingCapacityNotes = true },
                onLocalModels: { showingLocalModels = true },
                onDeviceBackups: { showingDeviceBackups = true },
                onCloudCopies: { showingCloudCopies = true },
                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) })
        }
    }
    private func resultPage(_ result: StorageMapAnalysisResult) -> some View {
        let amount = FileLightfieldPresentation.amount(result.rootSnapshot.measuredBytes)
        return FeatureLightfieldPage(module: .largeFiles, phase: .result, title: ReviewFilter.largeFiles.sidebarTitle,
                status: status, safety: L10n.text("目录索引 · 移到废纸篓前确认", "Directory index · Confirm before moving to Trash"),
                actionTitle: L10n.text("移到废纸篓 · 已选 \(ByteFormat.count(workspace.trashSelections.count))", "Move to Trash · \(ByteFormat.count(workspace.trashSelections.count)) selected"),
                actionEnabled: workspace.canReviewTrash, showsArtwork: false,
                statusActionTitle: L10n.text("更换范围", "Change Scope"), statusActionEnabled: workspace.canStartStorageAnalysis, statusAction: { showingScopes = true },
                action: workspace.requestTrashReview) {
                LightfieldFileResults(summary: LightfieldSummary(module: .largeFiles,
                    label: StorageCapacityPresentation.summaryLabel(isComplete: result.rootSnapshot.isComplete, path: result.rootSnapshot.path), value: amount.0, unit: amount.1,
                    secondary: [.init(id: "count", label: L10n.text("已索引文件", "Indexed Files"), value: String(indexedFileCount)),
                        .init(id: "free", label: L10n.text("磁盘可用", "Available Space"), value: ByteFormat.storageString(result.volumeAvailableBytes))]),
                    compactBodyHeight: 640) {
                    FileAnalysisLightfieldBody(result: result, navigation: workspace.storageMapNavigation,
                        types: types, largest: largest, fileCount: indexedFileCount, surface: $surface,
                        isBusy: workspace.trashPhase != .idle || workspace.storageMapBrowsePhase.isLoading,
                        selectionState: workspace.trashSelectionState,
                        onToggle: workspace.toggleTrashSelection,
                        onOpen: { workspace.openStorageMapDirectory($0) },
                        onBreadcrumb: { workspace.showStorageMapSnapshot(at: $0) },
                        notice: browseNotice,
                        onRetry: browseFailed ? { workspace.retryStorageMapBrowse() } : nil,
                        onDetails: { showingDetails = true },
                        onCapacityNotes: { showingCapacityNotes = true },
                        onLocalModels: { showingLocalModels = true },
                        onDeviceBackups: { showingDeviceBackups = true },
                        onCloudCopies: { showingCloudCopies = true },
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) })
                }
            }
    }
    private var status: String {
        let selection = FileAnalysisTrashPresentation.selectionSummary(count: workspace.trashSelections.count, bytes: workspace.selectedTrashBytes)
        if let notice = workspace.trashNotice { return notice }
        if let notice = workspace.trashRefinementNotice { return notice }
        if let outcome = workspace.trashOutcome {
            if outcome.receiptUnavailable { return L10n.text("无法写入操作记录；没有移动任何项目", "Operation History unavailable; nothing moved") }
            if outcome.receiptIncomplete { return FileAnalysisTrashPresentation.receiptIncompleteNote }
            // D84：移到废纸篓的容量只写“已移到废纸篓”，并注明清空后才释放。
            return StorageCapacityPresentation.movedToTrashSummary(count: outcome.movedPaths.count, bytes: outcome.movedBytes)
                + " · " + selection
        }
        if workspace.trashPutBackCount > 0 { return L10n.text("已恢复 \(ByteFormat.count(workspace.trashPutBackCount)) 项 · ", "Restored \(ByteFormat.count(workspace.trashPutBackCount)) items · ") + selection }
        return selection
    }
    private var browseNotice: String? {
        if case let .failed(_, _, _, _, message) = workspace.storageMapBrowsePhase { return message }
        if workspace.storageMapBrowsePhase.isLoading { return L10n.text("正在读取目录…", "Reading folder…") }
        return nil
    }
    private var browseFailed: Bool {
        if case .failed = workspace.storageMapBrowsePhase { return true }
        return false
    }
    private var operationDetails: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("选择与操作详情", "Selection and Operation Details")).font(.system(size: 24, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(status)
                    if let detail = workspace.trashNoticeDetail { Text(detail) }
                    if let outcome = workspace.trashOutcome {
                        // D93: the shared four-group result with reasons per item.
                        OperationCompletionTallyView(tally: OperationCompletionTally(fileAnalysis: outcome),
                                                     showsReceiptNote: false)
                        if outcome.receiptIncomplete { Text(FileAnalysisTrashPresentation.receiptIncompleteNote) }
                        else if !outcome.movedPaths.isEmpty {
                            Text(outcome.externalVolumeNames.isEmpty ? FileAnalysisTrashPresentation.trashFootnote
                                : FileAnalysisTrashPresentation.otherTrashNote(volumes: outcome.externalVolumeNames))
                        }
                        if outcome.notRestorableHereCount > 0 {
                            Text(L10n.text("\(ByteFormat.count(outcome.notRestorableHereCount)) 项的结果需要核实，请刷新操作记录。",
                                "Refresh Operation History to verify \(ByteFormat.count(outcome.notRestorableHereCount)) items."))
                        }
                        ForEach(outcome.skipped) { item in Text(item.title + " · " + item.reason).help(item.path) }
                    }
                }.font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 20) {
                Button(L10n.text("清除选择", "Clear Selection"), action: workspace.clearTrashSelection)
                    .disabled(workspace.trashPhase != .idle || workspace.trashSelections.isEmpty)
                Button(L10n.text("关闭提示", "Dismiss Notice"), action: workspace.dismissTrashOutcome)
                    .disabled(workspace.trashPhase != .idle)
                Spacer()
                Button(L10n.text("返回", "Back")) { showingDetails = false }
            }.buttonStyle(FeatureLightfieldRowButtonStyle())
        }.padding(24).frame(width: 640, height: 400)
    }
}

/// Value-only body shared by production, inert screenshots and native AX tests.
struct FileAnalysisLightfieldBody: View {
    @Environment(\.colorScheme) private var scheme
    let result: StorageMapAnalysisResult
    let navigation: [StorageMapDirectorySnapshot]
    let types: [LightfieldChartItem]
    let largest: [StorageTreemapEntry]
    let fileCount: Int
    @Binding var surface: Int
    var isBusy = false
    let selectionState: (StorageTreemapEntry) -> FileAnalysisTrashSelectionState
    let onToggle: (StorageTreemapEntry) -> Void
    let onOpen: (StorageTreemapEntry) -> Void
    let onBreadcrumb: (Int) -> Void
    var notice: String? = nil
    var onRetry: (() -> Void)? = nil
    var onDetails: (() -> Void)? = nil
    /// D84：容量口径说明。
    var onCapacityNotes: (() -> Void)? = nil
    /// D86：本地 AI 模型只读盘点。
    var onLocalModels: (() -> Void)? = nil
    /// D116 G11：iPhone、iPad 备份只读盘点。
    var onDeviceBackups: (() -> Void)? = nil
    var onCloudCopies: (() -> Void)? = nil
    var onReveal: (String) -> Void = { _ in }
    @State private var quickLookURL: URL?
    @State private var highlightedID: String?
    @State private var highlightedType: String?
    private var snapshot: StorageMapDirectorySnapshot { navigation.last ?? result.rootSnapshot }
    private var entries: [StorageTreemapEntry] {
        surface == 2 ? largest : StorageTreemapPresentation.visibleEntries(from: snapshot)
    }
    private var chartItems: [LightfieldChartItem] {
        surface == 1 ? types : entries.filter { $0.sizeBytes > 0 }.map(FileLightfieldPresentation.chart)
    }
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                breadcrumbs.frame(height: 30)
                if proxy.size.width < 700 {
                    VStack(spacing: 24) {
                        leftColumn.frame(height: 268)
                        bubbles.frame(height: 268)
                    }
                } else {
                    HStack(spacing: 24) {
                        leftColumn.frame(width: min(344, proxy.size.width * 0.42))
                        bubbles.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(height: 268)
                }
            }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
        }
        .onChange(of: surface) { _, _ in highlightedID = nil }
        .onChange(of: snapshot.path) { _, _ in highlightedID = nil }
        .onChange(of: entries.map(\.id)) { _, ids in
            if let highlightedID, !ids.contains(highlightedID) { self.highlightedID = nil }
        }
        .quickLookPreview($quickLookURL)
    }
    private var breadcrumbs: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array((surface == 0 ? navigation : [result.rootSnapshot]).enumerated()), id: \.offset) { index, level in
                        if index > 0 { FeatureLightfieldDisclosureChevron(expanded: false) }
                        Button(level.title) { onBreadcrumb(index) }
                            .buttonStyle(FeatureLightfieldRowButtonStyle())
                            .disabled(isBusy).help(level.path)
                            .accessibilityLabel(L10n.text("返回目录：", "Return to folder: ") + level.title)
                            .lightfieldComponentProbe("lightfield.analysis.breadcrumb.\(index)")
                    }
                }
            }.scrollIndicators(.hidden)
            Text(notice ?? (surface == 1 ? L10n.text("点击类型高亮", "Select a type to highlight")
                : StorageCapacityPresentation.snapshotNote(isComplete: snapshot.isComplete, path: snapshot.path)))
                .lineLimit(1).truncationMode(.middle).help(notice ?? "")
                .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
            if let onRetry {
                Button(L10n.text("重试", "Retry"), action: onRetry)
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(isBusy)
            }
            if let onCapacityNotes {
                Button(L10n.text("容量口径", "Size Basis"), action: onCapacityNotes).buttonStyle(FeatureLightfieldRowButtonStyle())
                    .help(L10n.text("本地占用、下限与云端占位的区别", "Local usage, lower bounds and cloud placeholders"))
                    .lightfieldComponentProbe("lightfield.analysis.capacityNotes")
            }
            if let onLocalModels {
                Button(L10n.text("本地 AI 模型", "Local AI Models"), action: onLocalModels).buttonStyle(FeatureLightfieldRowButtonStyle())
                    .help(L10n.text("只读盘点 Ollama 与 LM Studio 模型占用", "Read-only inventory of Ollama and LM Studio models"))
                    .lightfieldComponentProbe("lightfield.analysis.localModels")
            }
            if let onDeviceBackups {
                Button(L10n.text("设备备份", "Device Backups"), action: onDeviceBackups).buttonStyle(FeatureLightfieldRowButtonStyle())
                    .help(L10n.text("只读查看 iPhone、iPad 备份的占用（需要完全磁盘访问权限）",
                                    "Read-only view of iPhone and iPad backups (needs Full Disk Access)"))
                    .lightfieldComponentProbe("lightfield.analysis.deviceBackups")
            }
            if let onCloudCopies {
                Button(L10n.text("云文件本地副本", "Cloud Local Copies"), action: onCloudCopies)
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(isBusy)
                    .help(L10n.text("检查同步状态，确认后释放本地副本（不删除云端）", "Check sync state and confirm release of local copies (keep cloud files)"))
            }
            if let onDetails {
                Button(L10n.text("详情", "Details"), action: onDetails).buttonStyle(FeatureLightfieldRowButtonStyle())
            }
        }.font(.system(size: 13)).overlay(alignment: .top) { FeatureLightfieldHairline() }
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }
    private var leftColumn: some View {
        VStack(spacing: 0) {
            LightfieldTextSegments(titles: [L10n.text("目录", "Folders"), L10n.text("文件类型", "File Types"),
                L10n.text("最大的文件", "Largest Files")], selection: $surface, module: .largeFiles)
                .frame(height: 34).frame(maxWidth: .infinity, alignment: .leading)
            if surface == 1 {
                LightfieldDonutChart(items: types, centerValue: ByteFormat.storageString(result.rootSnapshot.measuredBytes),
                    centerLabel: L10n.text("\(ByteFormat.count(fileCount)) 个文件", "\(ByteFormat.count(fileCount)) files"), selectedID: highlightedType,
                    onSelect: toggleType)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    FeatureOptionsScrollView(probePrefix: "lightfield.analysis.list", balancesContent: false,
                        usesLightfield: true, fadesResults: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in entryRow(entry).id(entry.id) }
                        }
                    }.onChange(of: highlightedID) { _, id in
                        if let id { scroll.scrollTo(id) }
                    }
                }
            }
            capacity.frame(height: 38)
        }.lightfieldComponentProbe("lightfield.analysis.left")
    }
    private var bubbles: some View {
        LightfieldBubbleChart(items: chartItems, onHighlight: { highlightedID = $0 }, onDrillDown: { id in
            if surface == 1 { toggleType(id) }
            else if let entry = entries.first(where: { $0.id == id }) { openOrSelect(entry) }
        }, highlightedID: highlightedID,
            emphasizedIDs: surface == 1 ? highlightedType.map { Set([$0]) } : nil)
            .lightfieldComponentProbe("lightfield.analysis.bubbles")
    }
    private var capacity: some View {
        VStack(spacing: 5) {
            HStack {
                Text(L10n.text("已用 ", "Used ") + ByteFormat.storageString(result.usedVolumeBytes))
                Spacer(minLength: 0)
                Text(L10n.text("可用 ", "Free ") + ByteFormat.storageString(result.volumeAvailableBytes))
            }.font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok
            LightfieldDataBar(progress: result.volumeTotalBytes > 0 ? Double(result.usedVolumeBytes) / Double(result.volumeTotalBytes) : nil,
                module: .largeFiles, style: .share, accessibilityLabel: L10n.text("磁盘用量", "Disk Usage"))
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
            .overlay(alignment: .top) { FeatureLightfieldHairline() }
    }
    private func entryRow(_ entry: StorageTreemapEntry) -> some View {
        let type = LightfieldFileCategory.category(entry.contentCategory)
        let state = selectionState(entry)
        let share = snapshot.measuredBytes > 0 ? Double(entry.sizeBytes) / Double(snapshot.measuredBytes) : 0
        return HStack(spacing: 8) {
            LightfieldAnalysisCheckbox(state: state, title: entry.title, isBusy: isBusy) { onToggle(entry) }
            LightfieldOptionIconView(icon: entry.isDirectory ? .migrationSourceFolder : type.icon)
                .scaleEffect(24 / LightfieldOptionIcon.pointSize).frame(width: 24, height: 24)
            Button { openOrSelect(entry) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(FeatureLightfieldPalette.fileType(type)).frame(width: 6, height: 6)
                        Text(entry.title).font(.system(size: 15)).lineLimit(1).truncationMode(.middle)
                    }
                    if surface == 2 { LightfieldPathText(path: entry.path) }
                    else { LightfieldDataBar(progress: share, module: .largeFiles, style: .share, color: FeatureLightfieldPalette.fileType(type),
                        accessibilityLabel: entry.title + L10n.text("占比", " share")) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(isBusy).help(entry.path)
                .accessibilityLabel(entry.title + " · " + entry.path)
                .accessibilityHint(entry.canDescend ? L10n.text("进入目录", "Open folder") : FileAnalysisTrashPresentation.checkboxHelp(state: state))
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteFormat.storageString(entry.sizeBytes)).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok
                Text(entry.isEstimated ? L10n.text("估算", "Estimated") : String(format: "%.1f%%", share * 100))
                    .font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                    .lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok
            }.monospacedDigit().frame(width: 64).help(StorageCapacityPresentation.rowHelp(entry))
        }.frame(height: 52).background(highlightedID == entry.id ? FeatureLightfieldPalette.resolve(scheme).hoverColor : .clear)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            .onHover { highlightedID = $0 ? entry.id : nil }
            .contextMenu {
                Button(L10n.text("快速查看", "Quick Look")) { quickLookURL = URL(fileURLWithPath: entry.path) }
                Button(L10n.text("在访达中显示", "Show in Finder")) { onReveal(entry.path) }
                Button(L10n.text("复制路径", "Copy Path")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.path, forType: .string)
                }
            }
            .lightfieldComponentProbe("lightfield.analysis.row." + entry.id)
    }
    private func openOrSelect(_ entry: StorageTreemapEntry) {
        guard !isBusy else { return }
        if entry.canDescend { onOpen(entry) } else { onToggle(entry) }
    }
    private func toggleType(_ id: String) { highlightedType = highlightedType == id ? nil : id }
}

struct LightfieldAnalysisCheckbox: View {
    @Environment(\.colorScheme) private var scheme
    let state: FileAnalysisTrashSelectionState
    let title: String
    let isBusy: Bool
    let onToggle: () -> Void
    var body: some View {
        Button(action: onToggle) {
            Group {
                switch state {
                case .available: FeatureLightfieldCheck(selected: false, module: .largeFiles)
                case .selected, .includedInSelection: FeatureLightfieldCheck(selected: true, module: .largeFiles)
                case .blocked: LightfieldStatusGlyph(status: .locked)
                case .checking: Text("…").foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg3)
                }
            }.frame(width: 20, height: 20)
        }.buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(isBusy)
            .accessibilityLabel(L10n.text("移到废纸篓：", "Move to Trash: ") + title)
            .accessibilityValue(FileAnalysisTrashPresentation.checkboxHelp(state: state))
            .help(FileAnalysisTrashPresentation.checkboxHelp(state: state))
    }
}
