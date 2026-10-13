import SwiftUI

/// Presentation-only grouping/selection; every copy still opens the original
/// single-item confirmation. No queue or migration executor is added here.
struct FileMigrationLightfieldView: View {
    @Environment(\.colorScheme) private var scheme
    let entries: [LightfieldMigrationEntry]
    let volumes: [ExternalStorageVolume]
    @Binding var destinationID: String
    let sourceRoot: String?
    let completions: [String: ExternalMigrationCompletion]
    var busyID: String? = nil
    var refreshing = false
    var notice: String? = nil
    var activity: String? = nil
    var now = Date()
    let onRefresh: () -> Void
    let onRescan: () -> Void
    let onCancel: () -> Void
    let onCopy: (ExternalMigrationItem) -> Void
    let onOriginal: (ExternalMigrationItem, ExternalMigrationCompletion) -> Void
    let onReveal: (ExternalMigrationItem) -> Void
    var canTrash: (ExternalMigrationItem) -> Bool = { _ in false }
    var onTrash: (ExternalMigrationItem) -> Void = { _ in }
    /// D85：大文件门槛与截断说明（“仅显示前 N 项”等）；nil 时不占行。
    var listingNote: String? = nil
    /// D84：测量超时、大小只是本轮量到的下限的项目。
    var lowerBoundIDs: Set<String> = []
    @State private var selectedIDs: Set<String> = []
    @State private var grouping = 0
    @State private var collapsed: Set<String> = []
    @State private var query = ""
    @State private var showingReview = false
    @State private var reviewedEntry: ExternalMigrationItem?
    private var destination: ExternalStorageVolume? { volumes.first { $0.id == destinationID } }
    private var visibleEntries: [LightfieldMigrationEntry] {
        entries.filter { query.isEmpty || $0.item.title.localizedCaseInsensitiveContains(query) || $0.item.sourceURL.path.localizedCaseInsensitiveContains(query) }
    }
    private var groups: [LightfieldMigrationGroup] {
        LightfieldMigrationPresentation.groups(visibleEntries, by: .init(rawValue: grouping) ?? .type, root: sourceRoot, now: now)
    }
    var body: some View {
        let selection = LightfieldMigrationSelection.make(entries: entries,
            completedIDs: Set(completions.keys), selectedIDs: selectedIDs)
        let destinationSupportsSelection = !selection.entries.contains { $0.item.kind == .application }
            || destination?.supportsApplications == true
        let amount = FileLightfieldPresentation.amount(FileLightfieldPresentation.sum(entries.map { $0.item.sizeBytes }))
        FeatureLightfieldPage(module: .migration, phase: .result, title: ReviewFilter.migration.sidebarTitle,
            status: activity ?? notice ?? FileAnalysisTrashPresentation.selectionSummary(count: selection.entries.count, bytes: selection.bytes),
            safety: L10n.text("先复制并校验 · 原件处理单独确认", "Copy and verify · Confirm original handling separately"),
            actionTitle: L10n.text("复制到\(destination?.name ?? "—")并校验 · \(ByteFormat.storageString(selection.bytes))",
                "Copy to \(destination?.name ?? "—") and Verify · \(ByteFormat.storageString(selection.bytes))"),
            actionEnabled: !selection.entries.isEmpty && destination != nil && destinationSupportsSelection && busyID == nil,
            showsArtwork: false, statusActionTitle: activity == nil ? L10n.text("重新扫描", "Scan Again") : L10n.text("取消", "Cancel"),
            statusAction: activity == nil ? onRescan : onCancel, action: { showingReview = true }) {
            LightfieldFileResults(summary: LightfieldSummary(module: .migration,
                label: L10n.text("可搬移文件总量", "Movable Size"), value: amount.0, unit: amount.1,
                secondary: [.init(id: "count", label: L10n.text("可搬移项目", "Movable Items"), value: String(entries.count)),
                    .init(id: "free", label: L10n.text("目标盘可用", "Destination Free"), value: destination.map { ByteFormat.storageString($0.availableBytes) } ?? "—")])) {
                VStack(spacing: 0) {
                    destinationRow.frame(height: 52)
                    if let listingNote {
                        Text(listingNote).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                            .help(listingNote + "\n" + LargeFileThreshold.unitHelp)
                            .accessibilityLabel(listingNote)
                            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
                            .lightfieldComponentProbe("lightfield.migration.listingNote")
                    }
                    groupingRow(eligibleIDs: selection.eligibleIDs)
                    columnHeader(eligibleIDs: selection.eligibleIDs).frame(height: 26)
                    FeatureOptionsScrollView(probePrefix: "lightfield.migration.list", balancesContent: false,
                        usesLightfield: true, fadesResults: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(groups) { group in
                                groupHeader(group, eligibleIDs: selection.eligibleIDs)
                                if !collapsed.contains(collapseKey(group.id)) {
                                    ForEach(group.entries) { entry in row(entry, eligibleIDs: selection.eligibleIDs) }
                                }
                            }
                            if visibleEntries.isEmpty {
                                Text(entries.isEmpty ? L10n.text("尚无可安全搬移的文件", "No safely movable files yet")
                                    : L10n.text("没有匹配的可搬移项目", "No matching movable items"))
                                    .font(.system(size: 15)).frame(height: 52)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: selection.eligibleIDs) { _, ids in selectedIDs.formIntersection(ids) }
        .sheet(isPresented: $showingReview, onDismiss: {
            if let reviewedEntry { onCopy(reviewedEntry); self.reviewedEntry = nil }
        }) {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.text("审阅复制计划", "Review Copy Plan")).font(.system(size: 24, weight: .semibold))
                Text(L10n.text("逐项确认复制并校验；每份原件的处理另行确认。", "Confirm and verify each copy; original handling is confirmed separately."))
                    .font(.system(size: 13))
                ScrollView {
                    VStack(spacing: 0) { ForEach(selection.entries) { entry in
                        HStack(spacing: 16) {
                            LightfieldPathText(path: entry.item.sourceURL.path).frame(maxWidth: .infinity, alignment: .leading)
                            Text(ByteFormat.storageString(entry.item.sizeBytes)).font(.system(size: 13)).monospacedDigit()
                            Button(L10n.text("确认此项", "Review Item")) { reviewedEntry = entry.item; showingReview = false }
                                .buttonStyle(FeatureLightfieldRowButtonStyle()).fixedSize()
                        }.frame(height: 52).overlay(alignment: .bottom) { FeatureLightfieldHairline() }
                    } }
                }
                Button(L10n.text("返回", "Back")) { showingReview = false }.buttonStyle(FeatureLightfieldRowButtonStyle())
            }.padding(24).frame(width: 700, height: 460)
        }
    }
    private var destinationRow: some View {
        HStack(spacing: 16) {
            LightfieldOptionIconView(icon: .migrationDestinationDrive)
            Menu {
                ForEach(volumes) { volume in Button(volume.name) { destinationID = volume.id } }
            } label: {
                Text(destination?.name ?? L10n.text("未连接目标盘", "No Destination Drive"))
                    .font(.system(size: 15)).lineLimit(1).truncationMode(.middle).help(destination?.url.path ?? "")
            }.menuStyle(.borderlessButton).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(busyID != nil || volumes.isEmpty)
            VStack(alignment: .leading, spacing: 5) {
                Text(destination.map { L10n.text("可用 ", "Free ") + ByteFormat.storageString($0.availableBytes) + " · " + $0.fileSystem } ?? "—")
                    .font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok
                LightfieldDataBar(progress: destination.flatMap { $0.totalBytes > 0 ? Double($0.availableBytes) / Double($0.totalBytes) : nil },
                    module: .migration, style: .share, accessibilityLabel: L10n.text("目标盘可用比例", "Destination Free Share"))
            }.frame(maxWidth: .infinity)
            Button(L10n.text("刷新硬盘", "Refresh Drives"), action: onRefresh)
                .buttonStyle(FeatureLightfieldRowButtonStyle()).font(.system(size: 13)).fixedSize()
                .disabled(refreshing || busyID != nil)
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
            .overlay(alignment: .top) { FeatureLightfieldHairline() }
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }
    private func groupingRow(eligibleIDs: Set<String>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { segments; Spacer(minLength: 0); quickSelect(eligibleIDs: eligibleIDs) }
            VStack(alignment: .leading, spacing: 0) { segments; quickSelect(eligibleIDs: eligibleIDs).frame(height: 32) }
        }.overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }
    private var segments: some View {
        LightfieldTextSegments(titles: LightfieldMigrationGrouping.allCases.map(\.title), selection: $grouping, module: .migration)
            .frame(height: 42)
    }
    private func quickSelect(eligibleIDs: Set<String>) -> some View {
        Button(L10n.text("选择一年以上未修改的大文件", "Select Large Files Unmodified for a Year")) {
            selectedIDs = LightfieldMigrationPresentation.oldLargeIDs(entries, now: now).intersection(eligibleIDs)
        }.buttonStyle(FeatureLightfieldRowButtonStyle()).font(.system(size: 13))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .disabled(busyID != nil || !entries.contains { $0.modifiedAt != nil })
            .help(L10n.text("只选择修改时间已知、至少 1 GB 且一年以上未修改的项目；未知时间不参与。", "Only known modification dates, at least 1 GB, unmodified for a year; unknown dates are excluded."))
    }
    private func columnHeader(eligibleIDs: Set<String>) -> some View {
        HStack(spacing: 16) {
            selectionButton(ids: Set(visibleEntries.map(\.id)).intersection(eligibleIDs), title: L10n.text("选择可见文件", "Select Visible Files"))
            TextField(L10n.text("搜索名称或路径", "Search Name or Path"), text: $query)
                .textFieldStyle(.plain).font(.system(size: 13))
            Text(L10n.text("修改时间 · 大小", "Modified · Size")).font(.system(size: 13)).lineLimit(1)
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }
    /// D84：大文件清单按本地占用测量；超时的项目只是本轮量到的下限。
    private func sizeHelp(_ entry: LightfieldMigrationEntry) -> String {
        let basis: StorageCapacityBasis = lowerBoundIDs.contains(entry.id) ? .measuredLowerBound : .allocated
        return L10n.text("口径：", "Basis: ") + basis.title
    }
    private func collapseKey(_ id: String) -> String { "\(grouping):" + id }
    private func groupHeader(_ group: LightfieldMigrationGroup, eligibleIDs: Set<String>) -> some View {
        let ids = Set(group.entries.map(\.id)).intersection(eligibleIDs)
        return LightfieldFileGroupHeader(title: group.title,
            metadata: L10n.text("\(group.entries.count) 个 · ", "\(group.entries.count) items · ") + ByteFormat.storageString(group.bytes),
            icon: group.icon, module: .migration,
            selection: LightfieldSelectionCheck.state(ids: ids, selected: selectedIDs), selectionEnabled: !ids.isEmpty && busyID == nil,
            onSelect: { toggleGroup(ids) }, expanded: Binding(get: { !collapsed.contains(collapseKey(group.id)) }, set: {
                if $0 { collapsed.remove(collapseKey(group.id)) } else { collapsed.insert(collapseKey(group.id)) }
            }), probeID: "lightfield.migration.group." + group.id)
    }
    private func selectionButton(ids: Set<String>, title: String) -> some View {
        let state = LightfieldSelectionCheck.state(ids: ids, selected: selectedIDs)
        return Button { toggleGroup(ids) } label: { LightfieldSelectionCheck(state: state, module: .migration) }
            .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(ids.isEmpty || busyID != nil)
            .accessibilityLabel(title).accessibilityValue(LightfieldSelectionCheck.value(state))
    }
    private func toggleGroup(_ ids: Set<String>) {
        if ids.isSubset(of: selectedIDs) { selectedIDs.subtract(ids) } else { selectedIDs.formUnion(ids) }
    }
    private func row(_ entry: LightfieldMigrationEntry, eligibleIDs: Set<String>) -> some View {
        let completion = completions[entry.id]
        let path = completion?.displayPath(original: entry.item.sourceURL.path) ?? entry.item.sourceURL.path
        return LightfieldMigrationColumns {
            selectionButton(ids: eligibleIDs.contains(entry.id) ? [entry.id] : [], title: L10n.text("选择：", "Select: ") + entry.item.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .lightfieldComponentProbe("lightfield.migration.select." + entry.id)
            Group {
                if entry.item.kind == .application {
                    LightfieldAppIcon(path: entry.item.sourceURL.path, size: .medium, accessibilityName: entry.item.title)
                } else {
                    LightfieldOptionIconView(icon: entry.icon).scaleEffect(24 / LightfieldOptionIcon.pointSize)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.title).font(.system(size: 15)).lineLimit(1).truncationMode(.middle).help(entry.item.title)
                LightfieldPathText(path: path)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .lightfieldComponentProbe("lightfield.migration.name." + entry.id)
            Text(entry.modifiedAt.map { $0.formatted(date: .numeric, time: .omitted) } ?? L10n.text("未知", "Unknown"))
                .font(.system(size: 13)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5) // lightfield-scale-ok
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(ByteFormat.storageString(entry.item.sizeBytes)).font(.system(size: 15)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing) // lightfield-scale-ok
                .help(sizeHelp(entry))
            Menu {
                Button(L10n.text("在访达中显示", "Show in Finder")) { onReveal(entry.item) }
                if let completion {
                    Button(L10n.text("查看已校验副本", "Reveal Verified Copy")) { ExternalDriveMigrationService.reveal(completion.destinationURL) }
                    Text(completion.isMovedAway ? L10n.text("已迁移", "Migrated") : L10n.text("已复制", "Copied"))
                    switch completion.returnedOriginal {
                    case .restored?: Text(L10n.text("已恢复到原处，请重新扫描", "Back in its place; scan again"))
                    case .replaced?: Text(L10n.text("原处已有其他文件，请重新扫描", "Another file is in its place; scan again"))
                    case nil: EmptyView()
                    }
                    if !completion.didMoveSourceToTrash && entry.item.kind != .application {
                        Button(L10n.text("处理原件", "Handle Original")) { onOriginal(entry.item, completion) }.disabled(busyID != nil)
                    }
                } else {
                    Button(L10n.text("复制并验证", "Copy and Verify")) { onCopy(entry.item) }
                        .disabled(busyID != nil || destination == nil || entry.item.kind == .application && destination?.supportsApplications != true)
                }
                if canTrash(entry.item), completion == nil {
                    Button(L10n.text("移到废纸篓", "Move to Trash"), role: .destructive) { onTrash(entry.item) }.disabled(busyID != nil)
                }
            } label: { Text(L10n.text("操作", "Actions")).font(.system(size: 13)).lineLimit(1) }
                .menuStyle(.borderlessButton).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.text("文件操作：", "File actions: ") + entry.item.title)
                .lightfieldComponentProbe("lightfield.migration.actions." + entry.id)
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            .lightfieldComponentProbe("lightfield.migration.row." + entry.id)
    }
}
