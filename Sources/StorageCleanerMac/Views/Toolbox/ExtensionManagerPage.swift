import AppKit
import SwiftUI

/// D-FP1: the Extensions manager (Mac Sai's Extensions module in the studio
/// review layout). Bundles of the user's own Library can be moved to the
/// Trash and put back from Operation History; everything else is listed
/// with where it is managed. The page lists on first appearance.
struct ExtensionManagerPage: View {
    @ObservedObject var store: ExtensionManagerStore
    let module: CareStudioModule
    let onBack: () -> Void

    @State private var currentKind: ExtensionKind?
    @State private var query = ""
    @State private var sort: ToolboxSort = .size
    @State private var confirmsRemoval = false

    var body: some View {
        Group {
            if store.inventory == nil {
                CareStudioRunningPage(
                    module: module,
                    title: L10n.text("正在查找扩展…", "Finding Extensions…"),
                    detail: L10n.text("只读取，不改动任何文件", "Reading only; nothing is changed"),
                    onStop: {
                        store.cancel()
                        onBack()
                    }
                )
            } else {
                panel
            }
        }
        .onAppear {
            if store.inventory == nil, !store.isBusy { store.scan() }
        }
    }

    // MARK: Panel

    private var kinds: [ExtensionKind] { store.visibleKinds }

    private var shownKind: ExtensionKind? {
        if let currentKind, kinds.contains(currentKind) { return currentKind }
        return kinds.first
    }

    private var panel: some View {
        ToolboxManagerPanel(
            module: module,
            title: L10n.text("扩展", "Extensions"),
            query: $query,
            searchPrompt: L10n.text("搜索扩展", "Search extensions"),
            sortOptions: [.size, .name],
            sort: $sort,
            onBack: onBack
        ) {
            categoryColumn
        } rows: {
            rowColumn
        } footer: {
            ToolboxFooter(
                selectedCount: store.selectedItems.count,
                selectedBytes: store.selectedBytes,
                actionTitle: L10n.text("移到废纸篓", "Move to Trash"),
                actionEnabled: !store.selectedItems.isEmpty && store.phase == .ready,
                action: { confirmsRemoval = true }
            ) {
                Menu {
                    Button(L10n.text("选择系统已不再加载的", "Select Those No Longer Loaded")) { store.selectObsolete() }
                    Button(L10n.text("全部不选", "Deselect All")) {
                        store.setSelected(store.inventory?.items ?? [], selected: false)
                    }
                } label: {
                    Text(L10n.text("选择", "Selection")).font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.isBusy)
            }
        }
        .confirmationDialog(
            L10n.text("把 \(ByteFormat.count(store.selectedItems.count)) 个扩展移到废纸篓？",
                      "Move \(ByteFormat.count(store.selectedItems.count)) Extensions to the Trash?"),
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button(L10n.text("移到废纸篓", "Move to Trash"), role: .destructive) { store.removeSelected() }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    private var removalMessage: String {
        var lines = [L10n.text("它们会从你的“资源库”移到废纸篓，可以在“操作记录”里放回。",
                               "They move from your Library to the Trash; you can put them back from Operation History.")]
        if store.selectedItems.contains(where: { $0.kind == .preferencePane }) {
            lines.append(L10n.text("移除偏好设置面板前请先退出“系统设置”。",
                                   "Quit System Settings before removing a preference pane."))
        }
        if store.selectedItems.contains(where: { $0.kind == .audioPlugin }) {
            lines.append(L10n.text("请先退出正在使用这些插件的音频软件。",
                                   "Quit any audio app using these plug-ins first."))
        }
        return lines.joined(separator: "\n")
    }

    private var categoryColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let summary = store.summary {
                    Text(L10n.text("共 \(ByteFormat.count(summary.itemCount)) 个，可移除 \(ByteFormat.count(summary.movableCount)) 个",
                                   "\(ByteFormat.count(summary.itemCount)) found, \(ByteFormat.count(summary.movableCount)) removable"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                }
                ForEach(kinds) { kind in
                    let items = store.items(of: kind)
                    let movable = items.filter(\.management.isMovable)
                    ToolboxCategoryRow(
                        module: module,
                        title: kind.title,
                        detail: ToolboxText.countAndSize(items.count, bytes: items.reduce(0) { $0 + $1.bytes }),
                        systemImage: kind.systemImage,
                        art: kind.art,
                        isCurrent: query.isEmpty && kind == shownKind,
                        tick: movable.isEmpty ? nil : store.selectionState(for: movable),
                        tickEnabled: !store.isBusy,
                        onSelect: {
                            currentKind = kind
                            query = ""
                        },
                        onToggle: {
                            store.setSelected(movable, selected: store.selectionState(for: movable) == .unchecked)
                        }
                    )
                }
                if let inventory = store.inventory, inventory.hiddenAppleExtensionCount > 0 {
                    Text(L10n.text("另有 \(ByteFormat.count(inventory.hiddenAppleExtensionCount)) 个 Apple 自带的扩展未列出",
                                   "\(ByteFormat.count(inventory.hiddenAppleExtensionCount)) Apple extensions are not listed"))
                        .font(.system(size: 11))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
            }
            .padding(10)
        }
    }

    private var rowColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                notices
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchRows
                } else if let kind = shownKind {
                    sectionHeader(for: kind)
                    let items = store.items(of: kind)
                    if items.isEmpty {
                        emptyLine(kind)
                    }
                    ForEach(sorted(items)) { row(for: $0) }
                } else {
                    CareStudioManagerEmptyState(title: L10n.text("没有找到第三方扩展", "No Third-Party Extensions Found"))
                }
            }
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let outcome = store.outcome {
            ToolboxNotice(
                tone: outcome.removed.isEmpty ? .warning : .success,
                title: outcome.title + (outcome.removedBytes > 0 ? " · " + ByteFormat.storageString(outcome.removedBytes) : ""),
                lines: (outcome.removed.isEmpty ? [] : [L10n.text("可以在“操作记录”里放回。",
                                                                  "You can put them back from Operation History.")])
                    + (outcome.receiptWritten ? [] : [L10n.text("操作记录没有写完整，请在“操作记录”里核实。",
                                                                "The record was not fully written; check Operation History.")])
                    + (outcome.kept + outcome.failed).map { "\($0.name)：\($0.note ?? "")" },
                onDismiss: store.dismissOutcome,
                showsStateArt: true
            )
        }
        if let message = store.errorMessage {
            ToolboxNotice(tone: .warning, title: message, onDismiss: store.dismissError)
        }
        if store.phase == .removing {
            ToolboxNotice(tone: .info, title: L10n.text("正在移到废纸篓…", "Moving to the Trash…"))
        }
    }

    private func sectionHeader(for kind: ExtensionKind) -> some View {
        let obsolete = store.items(of: kind).filter { $0.obsolescence != nil && $0.management.isMovable }
        return ToolboxSectionHeader(title: kind.title, summary: kind.summary) {
            switch kind {
            case .appExtension:
                ToolboxLinkButton(title: L10n.text("在系统设置中管理", "Manage in System Settings"),
                                  systemImage: "gearshape", action: store.openExtensionSettings)
            case .kernelExtension:
                ToolboxLinkButton(title: L10n.text("打开“隐私与安全性”", "Open Privacy & Security"),
                                  systemImage: "lock.shield", action: store.openSecuritySettings)
            default:
                if !obsolete.isEmpty {
                    ToolboxLinkButton(title: L10n.text("选择已不再加载的 \(ByteFormat.count(obsolete.count)) 项",
                                                       "Select \(ByteFormat.count(obsolete.count)) No Longer Loaded"),
                                      isEnabled: !store.isBusy) {
                        store.setSelected(obsolete, selected: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func emptyLine(_ kind: ExtensionKind) -> some View {
        if (kind == .appExtension || kind == .safariExtension), store.inventory?.pluginKitAvailable == false {
            CareStudioManagerEmptyState(art: .stateError,
                                        title: L10n.text("读取系统的扩展列表失败", "The System's Extension List Could Not Be Read"),
                                        detail: L10n.text("这一类暂时无法列出。", "This kind cannot be listed now."))
        } else {
            CareStudioManagerEmptyState(title: L10n.text("这一类没有找到扩展", "No Extensions of This Kind"))
        }
    }

    private var searchRows: some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matches = sorted((store.inventory?.items ?? []).filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.path.localizedCaseInsensitiveContains(needle)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(needle) ?? false)
                || ($0.parentName?.localizedCaseInsensitiveContains(needle) ?? false)
        })
        return Group {
            Text(L10n.text("找到 \(ByteFormat.count(matches.count)) 项", "\(ByteFormat.count(matches.count)) found"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CareStudioManagerInk.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            ForEach(matches) { row(for: $0, showsKind: true) }
        }
    }

    private func sorted(_ items: [ExtensionItem]) -> [ExtensionItem] {
        switch sort {
        case .name:
            items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size, .date:
            items.sorted(by: ExtensionInventoryScanner.listOrder)
        }
    }

    private func row(for item: ExtensionItem, showsKind: Bool = false) -> some View {
        let movable = item.management.isMovable && item.identity != nil
        var badges: [ToolboxBadge] = []
        if let obsolescence = item.obsolescence { badges.append(.init(text: obsolescence.title, tone: .accent)) }
        if item.election == .disabled { badges.append(.init(text: ExtensionElection.disabled.title)) }
        switch item.signing {
        case .unsigned: badges.append(.init(text: ExtensionSigning.unsigned.title, tone: .warning))
        case .invalid: badges.append(.init(text: ExtensionSigning.invalid.title, tone: .danger))
        default: break
        }
        let detail = showsKind ? item.kind.title + " · " + item.detail : item.detail
        let help = [item.obsolescence?.explanation, item.management.note, item.path]
            .compactMap { $0 }.joined(separator: "\n")
        let revealPath = item.kind == .appExtension || item.kind == .safariExtension ? item.parentPath : item.path
        return ToolboxItemRow(
            title: item.name,
            badges: badges,
            detail: detail,
            value: ToolboxText.size(item.bytes, lowerBound: item.sizeIsLowerBound),
            tick: movable ? (store.isSelected(item) ? .checked : .unchecked) : nil,
            tickEnabled: store.canSelect(item),
            lockedReason: item.management.note,
            help: help,
            onToggle: { store.toggle(item) },
            onReveal: revealPath.map { path in { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } },
            copyPath: item.path
        ) {
            icon(for: item)
        }
    }

    @ViewBuilder
    private func icon(for item: ExtensionItem) -> some View {
        let path = (item.kind == .appExtension || item.kind == .safariExtension) ? item.parentPath : item.path
        if let path {
            CachedAppIconView(path: path, size: 30) { glyph(item.kind) }
        } else {
            glyph(item.kind)
        }
    }

    private func glyph(_ kind: ExtensionKind) -> some View {
        CareStudioGlyph(module: module, systemImage: kind.systemImage, side: 28)
    }
}

extension ExtensionKind {
    /// D154 batch 3Q: the kind's object in the left column, as each category
    /// in CleanMyMac's managers carries one (`图位清单-工具面板左栏`; four
    /// made for it, D166③).
    var art: GeneratedArt {
        switch self {
        case .preferencePane: .tileGeneral
        case .internetPlugin: .tileOtherSources
        case .quickLookGenerator: .tileQuickLook
        case .spotlightImporter: .tileReview
        case .screenSaver: .tileScreenSaver
        case .audioPlugin: .tileAudio
        case .kernelExtension: .tileProcesses
        case .safariExtension: .tileBrowsers
        case .appExtension: .tileAppExtension
        }
    }
}
