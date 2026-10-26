import AppKit
import SwiftUI

/// The light review panel over the gradient (CleanMyMac "Cleanup Manager",
/// `截图/cmm-08`–`cmm-10`): groups, then the rules of a group, then the rows
/// of a rule with ticks; the footer counts the selection and cleans it
/// through the existing plan and confirmation (D93).
struct CareStudioJunkManager: View {
    @ObservedObject var store: ScanStore
    let module: CareStudioModule
    let session: ScanSession
    let summaries: [CareJunkGroupSummary]
    var focus: CareJunkGroup?
    var onShowClassicList: (() -> Void)? = nil
    let onBack: () -> Void

    @State private var chromeID = UUID()
    @State private var selectedGroupID: String?
    @State private var selectedSubgroupID: String?
    @State private var query = ""
    @State private var sort: CareStudioManagerSort = .size
    @State private var showsSystemCaches = false

    private var currentGroup: CareJunkGroupSummary? {
        summaries.first { $0.id == selectedGroupID } ?? summaries.first
    }

    private var currentSubgroup: CareJunkSubgroup? {
        guard let group = currentGroup else { return nil }
        return group.subgroups.first { $0.id == selectedSubgroupID } ?? group.subgroups.first
    }

    private var scopeIDs: Set<ScanCandidateID> { Set(summaries.flatMap(\.candidates).map(\.id)) }

    private var selectedInScope: [ScanCandidate] {
        summaries.flatMap(\.candidates).filter { store.cleanupSelection.selectedCandidateIDs.contains($0.id) }
    }

    var body: some View {
        ZStack {
            CareStudioBackdrop(module: module, reportsWindowSize: true)
            VStack(spacing: 0) {
                header
                Rectangle().fill(CareStudioManagerInk.separator).frame(height: 1)
                HStack(spacing: 0) {
                    groupColumn.frame(width: 196)
                    Rectangle().fill(CareStudioManagerInk.separator).frame(width: 1)
                    if query.isEmpty {
                        subgroupColumn.frame(width: 248)
                        Rectangle().fill(CareStudioManagerInk.separator).frame(width: 1)
                        itemColumn
                    } else {
                        searchColumn
                    }
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
        .onAppear {
            CareStudioCanvas.shared.claim(chromeID, animating: false, label: "manager")
            if let focus { selectedGroupID = focus.rawValue }
        }
        .onDisappear { CareStudioCanvas.shared.release(chromeID) }
        .careStudioOwnerQuitDialog(store: store)
        .careStudioRefreshesRunningOwners(store: store)
        .onExitCommand(perform: onBack)
        .sheet(isPresented: $showsSystemCaches) {
            CareStudioSystemCaches(store: store) { showsSystemCaches = false }
        }
#if DEBUG
        .layoutProbe("careStudio.manager")
#endif
    }

    // MARK: Header and footer

    private var header: some View {
        CareStudioManagerHeaderLayout {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(L10n.text("返回", "Back")).font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(CareStudioManagerInk.accent)
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .keyboardShortcut(.cancelAction)
            CareStudioManagerTitle(title: L10n.text("清理管理", "Cleanup Manager"))
            HStack(spacing: 12) {
                if module != .devTools, store.systemCacheInventory != nil {
                    Button(L10n.text("系统缓存", "System Caches")) { showsSystemCaches = true }
                        .buttonStyle(CareStudioRowButtonStyle())
                }
                if let onShowClassicList {
                    Button(L10n.text("经典列表", "Classic List"), action: onShowClassicList)
                        .buttonStyle(CareStudioRowButtonStyle())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.accent)
                        .help(L10n.text("按绿、黄、红分级的详细列表，含筛选和试运行",
                                        "The detailed list by green, yellow and red, with filters and a dry run"))
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.accent)
                    TextField(L10n.text("搜索已发现的项目", "Search found items"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 150)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(CareStudioManagerInk.field))
                Menu {
                    ForEach(CareStudioManagerSort.allCases) { option in
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

    private var footer: some View {
        let selected = selectedInScope
        let bytes = CleanupByteCount.sum(selected.map(\.estimatedSizeBytes))
        return ZStack {
            HStack(spacing: 8) {
                Text(selected.isEmpty
                     ? L10n.text("未选择项目", "No Items Selected")
                     : L10n.text("已选 \(ByteFormat.count(selected.count)) 项", "\(ByteFormat.count(selected.count)) Selected"))
                    .font(.system(size: 13, weight: .semibold))
                Rectangle().fill(CareStudioManagerInk.separator).frame(width: 1, height: 14)
                Text(ByteFormat.storageString(bytes))
                    .font(.system(size: 13))
                    .monospacedDigit()
            }
            .foregroundStyle(CareStudioManagerInk.primary)
#if DEBUG
            .layoutProbe("careStudio.manager.total")
#endif
            HStack {
                Menu {
                    Button(L10n.text("选择推荐项目", "Select Recommended")) { store.selectRecommendedCleanupCandidates() }
                    Button(L10n.text("恢复默认选择", "Restore Default Selection")) { store.restoreDefaultCleanupSelection() }
                    Button(L10n.text("全部不选", "Deselect All")) {
                        store.setCleanupCandidates(Array(scopeIDs), selected: false)
                    }
                } label: {
                    Text(L10n.text("选择", "Selection")).font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!store.canEditV2CleanupSelection)
                Spacer()
                Button {
                    store.requestV2Cleanup(disposition: .trash, candidateIDs: scopeIDs)
                } label: {
                    Text(L10n.text("清理", "Clean Up"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(Capsule().fill(CareStudioManagerInk.accent
                            .opacity(selected.isEmpty || !store.canRequestV2Cleanup ? 0.35 : 1)))
                }
                .buttonStyle(CareStudioRowButtonStyle())
                .disabled(selected.isEmpty || !store.canRequestV2Cleanup)
#if DEBUG
                .layoutProbe("careStudio.manager.clean")
#endif
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(CareStudioManagerInk.footer)
    }

    // MARK: Columns

    /// Report §4 item 18 (CleanMyMac's Cleanup Manager, `cmm/16`): the groups
    /// by name only (was: each with a tick). What is selected is ticked in the
    /// item column, its Select menu and the footer's.
    private var groupColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(summaries) { summary in
                    let isCurrent = summary.id == currentGroup?.id
                    Button {
                        selectedGroupID = summary.id
                        selectedSubgroupID = nil
                    } label: {
                        HStack {
                            Text(summary.group.title)
                                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(CareStudioManagerInk.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isCurrent ? CareStudioManagerInk.selection : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CareStudioRowButtonStyle())
                    .accessibilityValue(Self.selectionText(store.cleanupSelection.state(for: summary.selectableIDs)))
                }
            }
            .padding(10)
        }
    }

    /// The size selected in a subgroup, for its tag.
    private func selectedBytes(in subgroup: CareJunkSubgroup) -> Int64 {
        Self.selectedBytes(in: subgroup, selected: store.cleanupSelection.selectedCandidateIDs)
    }

    static func selectedBytes(in subgroup: CareJunkSubgroup, selected: Set<ScanCandidateID>) -> Int64 {
        CleanupByteCount.sum(subgroup.candidates.filter { selected.contains($0.id) }.map(\.estimatedSizeBytes))
    }

    static func selectionText(_ state: TriStateSelection) -> String {
        switch state {
        case .unchecked: L10n.text("未选择", "Not selected")
        case .checked: L10n.text("已选择", "Selected")
        case .mixed: L10n.text("部分选择", "Partly selected")
        }
    }

    private var subgroupColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let group = currentGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.group.title).font(.system(size: 15, weight: .semibold))
                        Text(group.group.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(CareStudioManagerInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    ForEach(group.subgroups) { subgroup in
                        let isCurrent = subgroup.id == currentSubgroup?.id
                        Button {
                            selectedSubgroupID = subgroup.id
                        } label: {
                            HStack(spacing: 10) {
                                CareStudioJunkSubgroupMark(module: module, subgroup: subgroup, side: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(subgroup.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(CareStudioManagerInk.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(ByteFormat.storageString(subgroup.bytes))
                                            .monospacedDigit()
                                        CareStudioRiskTag(risk: subgroup.risk)
                                    }
                                    .font(.system(size: 11))
                                    .foregroundStyle(CareStudioManagerInk.secondary)
                                }
                                Spacer(minLength: 4)
                                // Item 18: CleanMyMac's pink tag of what is
                                // selected here (was: a tick).
                                let selected = selectedBytes(in: subgroup)
                                if selected > 0 { CareStudioSelectedSizeTag(bytes: selected) }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 52)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isCurrent ? CareStudioManagerInk.selection : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CareStudioRowButtonStyle())
                        .accessibilityValue(Self.selectionText(store.cleanupSelection.state(for: subgroup.selectableIDs)))
                        // D207 (CleanMyMac's Ignore N Items): the whole subgroup at once.
                        .contextMenu {
                            Button(IgnoreListMenu.title(count: subgroup.candidates.count)) {
                                store.ignoreCleanupCandidates(subgroup.candidates.map(\.id))
                            }
                            .disabled(!store.canIgnoreCleanupCandidates)
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var itemColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let subgroup = currentSubgroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(subgroup.title).font(.system(size: 15, weight: .semibold))
                        if !subgroup.reason.isEmpty {
                            Text(subgroup.reason)
                                .font(.system(size: 12))
                                .foregroundStyle(CareStudioManagerInk.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        selectMenu(for: subgroup)
                            .padding(.top, 4)
                    }
                    .foregroundStyle(CareStudioManagerInk.primary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    ForEach(sorted(subgroup.candidates)) { candidate in
                        CareStudioCandidateRow(store: store, session: session, candidate: candidate,
                                               cleanupScopeIDs: scopeIDs)
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private var searchColumn: some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matches = sorted(summaries.flatMap(\.candidates).filter {
            $0.sourceURL.lastPathComponent.localizedCaseInsensitiveContains(needle)
                || $0.snapshot.standardizedPath.localizedCaseInsensitiveContains(needle)
                || $0.subcategoryTitle.localizedCaseInsensitiveContains(needle)
                || $0.applicationOwnershipText.localizedCaseInsensitiveContains(needle)
        })
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("找到 \(ByteFormat.count(matches.count)) 项", "\(ByteFormat.count(matches.count)) found"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                if matches.isEmpty {
                    CareStudioManagerEmptyState(title: L10n.text("没有匹配的项目", "No Matching Items"))
                }
                ForEach(matches) { candidate in
                    CareStudioCandidateRow(store: store, session: session, candidate: candidate,
                                           cleanupScopeIDs: scopeIDs, showsRuleTitle: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func selectMenu(for subgroup: CareJunkSubgroup) -> some View {
        let state = store.cleanupSelection.state(for: subgroup.selectableIDs)
        let title: String = switch state {
        case .unchecked: L10n.text("不选", "None")
        case .checked: L10n.text("全部", "All")
        case .mixed: L10n.text("部分", "Some")
        }
        return Menu {
            Button(L10n.text("推荐项目", "Recommended")) {
                store.setCleanupCandidates(subgroup.selectableIDs, selected: false)
                store.setCleanupCandidates(subgroup.candidates.filter(\.isPreselectedByDefault).map(\.id), selected: true)
            }
            Button(L10n.text("全部", "All")) { store.setCleanupCandidates(subgroup.selectableIDs, selected: true) }
            Button(L10n.text("不选", "None")) { store.setCleanupCandidates(subgroup.selectableIDs, selected: false) }
        } label: {
            // One concatenated Text: a borderless menu shows only the
            // first view of a stacked label.
            (Text(L10n.text("选择：", "Select: ")).foregroundStyle(CareStudioManagerInk.primary)
                + Text(title).foregroundStyle(CareStudioManagerInk.accent))
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(subgroup.selectableIDs.isEmpty || !store.canEditV2CleanupSelection)
    }

    private func sorted(_ candidates: [ScanCandidate]) -> [ScanCandidate] {
        switch sort {
        case .size:
            candidates.sorted { $0.estimatedSizeBytes > $1.estimatedSizeBytes }
        case .name:
            candidates.sorted {
                CareStudioCandidateRow.title(for: $0)
                    .localizedStandardCompare(CareStudioCandidateRow.title(for: $1)) == .orderedAscending
            }
        }
    }
}

enum CareStudioManagerSort: String, CaseIterable, Identifiable {
    case size, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .size: L10n.text("大小", "Size")
        case .name: L10n.text("名称", "Name")
        }
    }
}

/// Colours of the light review panel (CleanMyMac keeps it light and pink
/// in every module).
enum CareStudioManagerInk {
    static let panel = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)
    static let footer = Color(.sRGB, red: 0.965, green: 0.962, blue: 0.975, opacity: 1)
    static let field = Color.black.opacity(0.05)
    static let separator = Color.black.opacity(0.08)
    static let primary = Color(.sRGB, red: 0.10, green: 0.09, blue: 0.13, opacity: 1)
    static let secondary = Color(.sRGB, red: 0.42, green: 0.41, blue: 0.47, opacity: 1)
    static let accent = Color(.sRGB, red: 0.82, green: 0.17, blue: 0.62, opacity: 1)
    static let selection = Color(.sRGB, red: 0.91, green: 0.85, blue: 0.98, opacity: 1)
    static let warning = Color(.sRGB, red: 0.85, green: 0.47, blue: 0.0, opacity: 1)
    static let danger = Color(.sRGB, red: 0.84, green: 0.20, blue: 0.24, opacity: 1)
}

/// Report §4 item 18 (CleanMyMac's Cleanup Manager, `cmm/16`): the size
/// selected in a subgroup, white on the panel's pink.
struct CareStudioSelectedSizeTag: View {
    let bytes: Int64

    var body: some View {
        Text(ByteFormat.storageString(bytes))
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CareStudioManagerInk.accent))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A pink checkbox with a mixed state.
struct CareStudioTriTick: View {
    let state: TriStateSelection
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(state == .unchecked ? Color.white : CareStudioManagerInk.accent)
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(state == .unchecked ? CareStudioManagerInk.accent.opacity(0.7) : .clear, lineWidth: 1.2)
                if state != .unchecked {
                    Image(systemName: state == .mixed ? "minus" : "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 15, height: 15)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(CareStudioRowButtonStyle())
        .disabled(!isEnabled)
        .accessibilityValue(state == .unchecked ? L10n.text("未选择", "Not selected")
                            : (state == .mixed ? L10n.text("部分选择", "Partly selected") : L10n.text("已选择", "Selected")))
    }
}

struct CareStudioRiskTag: View {
    let risk: CleanupRisk

    var body: some View {
        switch risk {
        case .safe:
            EmptyView()
        case .reviewOnly:
            tag(L10n.text("需判断", "Review"), CareStudioManagerInk.warning)
        case .protected:
            tag(L10n.text("高风险", "High Risk"), CareStudioManagerInk.danger)
        case .informational:
            EmptyView()
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// One found item (CleanMyMac detail row): tick, icon, name, the smart
/// mark, size and a way into Finder. Running owners and the row hints of the
/// old result page (rebuild cost, shared storage, ownership) stay visible.
struct CareStudioCandidateRow: View {
    @ObservedObject var store: ScanStore
    let session: ScanSession
    let candidate: ScanCandidate
    let cleanupScopeIDs: Set<ScanCandidateID>
    var showsRuleTitle = false
    @State private var isHovered = false

    nonisolated static func title(for candidate: ScanCandidate) -> String {
        if candidate.ruleID == "mail.library-attachment-folders" {
            return MailAttachmentPresentation.mailboxName(for: candidate.sourceURL)
        }
        if candidate.ruleID == "trash.icloud-drive" {
            return L10n.text("iCloud 云盘废纸篓", "iCloud Drive Trash")
        }
        // D181: a Trash row names its drive, never the folder (".Trash", "501").
        if candidate.action == .emptyTrash {
            if let volume = VolumeTrashLocator.volumeName(ofTrashPath: PathSafety.lexicalPath(candidate.sourceURL.path)) {
                return L10n.text("“\(volume)”上的废纸篓", "Trash on “\(volume)”")
            }
            return L10n.text("废纸篓", "Trash")
        }
        if let owner = candidate.ruleOwnerDisplayName, !owner.isEmpty,
           candidate.sourceURL.lastPathComponent.hasPrefix("com.") || candidate.sourceURL.lastPathComponent.contains(".") == false {
            return owner
        }
        return candidate.sourceURL.lastPathComponent
    }

    private var isSelected: Bool { store.cleanupSelection.selectedCandidateIDs.contains(candidate.id) }

    private var canSelect: Bool {
        candidate.isSelectable
            && session.outcome != .cancelled
            && store.canEditV2CleanupSelection
            && !DuplicateApplicationRetentionPolicy.isProtected(candidate)
    }

    private var ownerOptions: CleanupOwnerQuitService.Options {
        candidate.isOwnerRunning ? store.cleanupOwnerQuitOptions(for: candidate) : .init()
    }

    private var canQuitOwnerAndClean: Bool {
        isSelected && canSelect && candidate.isOwnerRunning
            && candidate.ownerResolution != .applicationBundle
            && !ownerOptions.quittable.isEmpty
    }

    private var detail: String {
        CleanupRuleExplanation.lightfieldDetail(
            rebuildCost: CleanupCandidateRowHint.rebuildCost(for: candidate)?.text,
            reclaimable: CleanupCandidateRowHint.reclaimable(for: candidate)?.text,
            ownerStatus: nil,
            ownership: candidate.ruleExplanation.ownership,
            path: candidate.snapshot.standardizedPath)
    }

    var body: some View {
        HStack(spacing: 12) {
            CareStudioTriTick(state: isSelected ? .checked : .unchecked, isEnabled: canSelect) {
                store.setCleanupCandidate(candidate.id, selected: !isSelected)
            }
            .accessibilityLabel(Self.title(for: candidate))
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.title(for: candidate))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if candidate.isOwnerRunning {
                        Text(L10n.text("正在运行", "Running"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CareStudioManagerInk.warning)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(CareStudioManagerInk.warning.opacity(0.12)))
                    }
                    CareStudioRiskTag(risk: candidate.risk)
                }
                Text(showsRuleTitle ? "\(candidate.subcategoryTitle) · \(detail)" : detail)
                    .font(.system(size: 11))
                    .foregroundStyle(CareStudioManagerInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if candidate.isPreselectedByDefault {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CareStudioManagerInk.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(CareStudioManagerInk.accent.opacity(0.10)))
                    .help(candidate.preselectionExplanationText)
                    .accessibilityLabel(L10n.text("推荐清理", "Recommended"))
            }
            Text(CleanupMeasurementPresentation.value(candidate))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(CareStudioManagerInk.secondary)
                .frame(minWidth: 62, alignment: .trailing)
            Button {
                store.revealCleanupCandidate(candidate)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CareStudioManagerInk.accent)
                    .frame(width: 20, height: 28)
            }
            .buttonStyle(CareStudioRowButtonStyle())
            .help(L10n.text("在访达中显示", "Show in Finder"))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .background(isHovered ? Color.black.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help([candidate.reason, candidate.ruleExplanation.summary].filter { !$0.isEmpty }.joined(separator: " · "))
        .contextMenu {
            Button(L10n.text("在访达中显示", "Show in Finder")) { store.revealCleanupCandidate(candidate) }
            // D207 (CleanMyMac's Add to Ignore List).
            Button(IgnoreListMenu.title(count: 1)) { store.ignoreCleanupCandidates([candidate.id]) }
                .disabled(!store.canIgnoreCleanupCandidates)
            if canQuitOwnerAndClean {
                Button(L10n.text("正常退出并清理", "Quit Normally and Clean")) {
                    store.requestQuitCleanupOwners(for: [candidate.id], cleanupScope: cleanupScopeIDs)
                }
            }
            Button(L10n.text("复制路径", "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(candidate.snapshot.standardizedPath, forType: .string)
            }
        }
#if DEBUG
        .layoutProbe("careStudio.manager.row")
#endif
    }

    @ViewBuilder
    private var icon: some View {
        if let bundleID = candidate.ownerBundleIdentifiers.first,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            CachedAppIconView(path: url.path, size: 30) { folderIcon }
        } else {
            folderIcon
        }
    }

    private var folderIcon: some View {
        Image(systemName: candidate.snapshot.identity.entryKind == .directory ? "folder.fill" : "doc.fill")
            .font(.system(size: 22))
            .foregroundStyle(Color(.sRGB, red: 0.33, green: 0.68, blue: 0.96, opacity: 1))
            .frame(width: 30, height: 30)
    }
}
