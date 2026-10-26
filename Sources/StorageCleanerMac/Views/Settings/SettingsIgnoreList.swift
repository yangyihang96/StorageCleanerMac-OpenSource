import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsIgnoreListModel: ObservableObject {
    @Published var category: IgnoreCategory = .systemJunk
    @Published private(set) var entries: [IgnoreListEntry] = []
    @Published private(set) var notice: String?
    let store: IgnoreListStore
    private var observation: AnyCancellable?
    init(store: IgnoreListStore) {
        self.store = store
        refresh()
        observation = NotificationCenter.default.publisher(for: IgnoreListStore.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
    }
    var visibleEntries: [IgnoreListEntry] { entries.filter { $0.category == category } }
    func refresh() {
        entries = store.snapshot().entries
        if let message = store.takeNotice() { notice = message }
    }
    func add(_ targets: [IgnoreListTarget], names: [String: String] = [:]) {
        let count = store.add(targets, category: category, displayNames: names)
        notice = count > 0
            ? L10n.text("已添加 \(ByteFormat.count(count)) 项，下次扫描起生效。", "Added \(count) items. Applies from the next scan.")
            : L10n.text("没有新增项目，请检查是否已在列表中。", "No items were added. Check whether they are already listed.")
        refresh()
    }
    func remove(_ ids: Set<String>) { _ = store.remove(ids: ids); refresh() }
    func undoLastAdd() { _ = store.undoLastAdd(); refresh() }
}

/// D210: the ignore list page's sizes. Every category shows at once
/// (the list no longer scrolls on its own) and entry rows share one height.
/// The page needs room for all the categories, or for its header and three
/// whole entries; a shorter window scrolls the whole page
/// (`SettingsCategory.minimumContentHeight`) instead of squeezing either.
enum SettingsIgnoreListMetrics {
    static let categoryWidth: CGFloat = 152
    static let columnSpacing: CGFloat = 20
    static let categoryRowHeight: CGFloat = 20
    static let groupTitleHeight: CGFloat = 16
    static let groupGap: CGFloat = 4
    static let entryRowHeight: CGFloat = 52
    /// Entries that always show whole.
    static let visibleEntries = 3
    /// The most the header takes: the title with + and −, the next-scan line
    /// and a two-line notice.
    static let headerHeight: CGFloat = 76
    static let headerGap: CGFloat = 8
    /// The categories that open the five module groups (D207).
    static let groupStarts: [IgnoreCategory] = [.systemJunk, .malware, .uninstaller, .duplicates, .other]

    static var categoriesHeight: CGFloat {
        let groups = CGFloat(groupStarts.count)
        return groups * groupTitleHeight + CGFloat(IgnoreCategory.allCases.count) * categoryRowHeight
            + (groups - 1) * groupGap
    }

    static var minimumHeight: CGFloat {
        max(categoriesHeight, headerHeight + headerGap + CGFloat(visibleEntries) * entryRowHeight)
    }
}

/// D210: the entry list's selection, as a table has it: a click picks
/// one row, ⌘ adds or drops a row, ⇧ takes the rows from the last one clicked.
struct SettingsIgnoreListSelection: Equatable {
    var ids: Set<String> = []
    var anchor: String?

    mutating func click(_ id: String, in order: [String], command: Bool, shift: Bool) {
        if shift, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = Set(order[min(from, to)...max(from, to)])
            ids = command ? ids.union(range) : range
            return
        }
        if command {
            if ids.remove(id) == nil { ids.insert(id) }
        } else {
            ids = [id]
        }
        anchor = id
    }

    /// ↑ and ↓ move a single selection.
    mutating func step(by offset: Int, in order: [String]) {
        guard !order.isEmpty else { return }
        let current = anchor.flatMap { order.firstIndex(of: $0) }
        let next = current.map { min(max(0, $0 + offset), order.count - 1) } ?? (offset < 0 ? order.count - 1 : 0)
        ids = [order[next]]
        anchor = order[next]
    }
}

/// D210: CleanMyMac's Ignore List page — the categories on the left,
/// all of them at once under their module groups, and the chosen category's
/// entries on the right, each row whole, with + and − beside the category's
/// name so they stay in sight. Text only on the page (D64/B6); the tab
/// carries the picture.
struct SettingsIgnoreListPage: View {
    private typealias Metrics = SettingsIgnoreListMetrics
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: SettingsIgnoreListModel
    @Binding var selection: Set<String>
    var canAdd = true
    let add: () -> Void
    @State private var anchor: String?
    @FocusState private var listHasFocus: Bool

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        HStack(alignment: .top, spacing: Metrics.columnSpacing) {
            categories(palette)
            VStack(alignment: .leading, spacing: Metrics.headerGap) {
                header(palette)
                entries(palette)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.fg, palette.fg2, palette.fg3)
    }

    private var selectedIDs: Set<String> {
        selection.intersection(model.visibleEntries.map(\.id))
    }

    private func categories(_ palette: FeatureLightfieldPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(IgnoreCategory.allCases) { category in
                if let group = Metrics.groupStarts.firstIndex(of: category) {
                    Text(category.group)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.fg2)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .bottomLeading)
                        .frame(height: Metrics.groupTitleHeight, alignment: .bottomLeading)
                        .padding(.top, group == 0 ? 0 : Metrics.groupGap)
                        .accessibilityAddTraits(.isHeader)
                }
                categoryRow(category, palette)
            }
        }
        .frame(width: Metrics.categoryWidth, alignment: .topLeading)
        .lightfieldComponentProbe("settings.ignoreList.categories")
    }

    private func categoryRow(_ category: IgnoreCategory, _ palette: FeatureLightfieldPalette) -> some View {
        let isSelected = model.category == category
        return Button {
            model.category = category
            selection = []
            anchor = nil
        } label: {
            Text(category.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(palette.fg)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Metrics.categoryRowHeight)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(FeatureLightfieldPalette.accent(.overview).opacity(scheme == .dark ? 0.20 : 0.16))
                    }
                }
        }
        .buttonStyle(FeatureLightfieldRowButtonStyle())
        .help(category.title)
        .accessibilityValue(isSelected ? L10n.text("已选择", "Selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .lightfieldComponentProbe("settings.ignoreList.category." + category.rawValue)
    }

    private func header(_ palette: FeatureLightfieldPalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.category.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button(action: add) { SettingsIgnoreListGlyph(systemName: "plus") }
                    .buttonStyle(FeatureLightfieldRowButtonStyle())
                    .accessibilityLabel(L10n.text("添加忽略项", "Add ignored items"))
                    .disabled(!canAdd)
                    .lightfieldComponentProbe("settings.ignoreList.add")
                Button(action: removeSelected) { SettingsIgnoreListGlyph(systemName: "minus") }
                    .buttonStyle(FeatureLightfieldRowButtonStyle())
                    .accessibilityLabel(L10n.text("移除所选忽略项", "Remove selected ignored items"))
                    .disabled(selectedIDs.isEmpty)
                    .lightfieldComponentProbe("settings.ignoreList.remove")
            }
            Text(L10n.text("下次扫描起生效", "Applies from the next scan"))
                .font(.system(size: 12))
                .foregroundStyle(palette.fg2)
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.fg2)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(notice)
            }
        }
        .lightfieldComponentProbe("settings.ignoreList.header")
    }

    @ViewBuilder
    private func entries(_ palette: FeatureLightfieldPalette) -> some View {
        let entries = model.visibleEntries
        Group {
            if entries.isEmpty {
                Text(L10n.text("此类别暂无忽略项。添加后从下次扫描起生效。", "No ignored items in this category. Add items to apply from the next scan."))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.fg2)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                entryRow(entry, palette)
                                    .id(entry.id)
                                    .lightfieldComponentProbe("settings.ignoreList.entry.\(index)")
                            }
                        }
                    }
                    .focusable()
                    .focused($listHasFocus)
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        let order = entries.map(\.id)
                        var state = SettingsIgnoreListSelection(ids: selection, anchor: anchor)
                        switch direction {
                        case .up: state.step(by: -1, in: order)
                        case .down: state.step(by: 1, in: order)
                        default: return
                        }
                        selection = state.ids
                        anchor = state.anchor
                        if let anchor = state.anchor { proxy.scrollTo(anchor) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { FeatureLightfieldHairline() }
        .lightfieldComponentProbe("settings.ignoreList.entries")
    }

    private func entryRow(_ entry: IgnoreListEntry, _ palette: FeatureLightfieldPalette) -> some View {
        let isSelected = selection.contains(entry.id)
        var meta = entry.addedAt.formatted(.dateTime.year().month().day().hour().minute())
        if let identifier = entry.target.bundleIdentifier, !identifier.isEmpty {
            meta = identifier + " · " + meta
        }
        return Button { select(entry) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.fg)
                Text(entry.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.fg2)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.fg3)
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.entryRowHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(FeatureLightfieldPalette.accent(.overview).opacity(scheme == .dark ? 0.20 : 0.16))
                }
            }
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
        }
        .buttonStyle(FeatureLightfieldRowButtonStyle())
        .help(entry.detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ entry: IgnoreListEntry) {
        let flags = NSEvent.modifierFlags
        var state = SettingsIgnoreListSelection(ids: selection, anchor: anchor)
        state.click(entry.id, in: model.visibleEntries.map(\.id),
                    command: flags.contains(.command), shift: flags.contains(.shift))
        selection = state.ids
        anchor = state.anchor
        listHasFocus = true
    }

    private func removeSelected() {
        model.remove(selectedIDs)
        selection = []
        anchor = nil
    }
}

/// The + and − glyphs: a 24 pt target on a faint plate, dimmed while the
/// button is unavailable.
private struct SettingsIgnoreListGlyph: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    let systemName: String

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.fg)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(palette.fg.opacity(0.07)))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
    }
}

extension SettingsView {
    var ignoreListSettings: some View {
        SettingsIgnoreListPage(model: ignoreListModel, selection: $ignoreSelection,
                               canAdd: !exclusionPanelCoordinator.isPresenting) { addIgnoreListItems() }
            .onAppear { ignoreSelection = []; ignoreListModel.refresh() }
            .onChange(of: ignoreListModel.category) { _, _ in ignoreSelection = [] }
            .sheet(isPresented: $showsIgnoreApplicationPicker) { ignoreApplicationPicker }
    }

    func addIgnoreListItems() {
        if ignoreListModel.category.isApplication {
            showsIgnoreApplicationPicker = true
            if scanStore?.installedApps.isEmpty == true { scanStore?.refreshInstalledApps() }
            return
        }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要忽略的文件或文件夹", "Choose files or folders to ignore")
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.resolvesAliases = true
        let category = ignoreListModel.category
        exclusionPanelCoordinator.present(panel, attachedTo: AppOpenPanelCoordinator.preferredHostWindow()) { response in
            guard response == .OK else { return }
            ignoreListModel.category = category
            ignoreListModel.add(panel.urls.map { IgnoreListTarget(path: $0.path) })
        }
    }

    var ignoreApplicationPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("选择已安装的应用", "Choose installed applications")).font(.system(size: 18, weight: .semibold))
            if scanStore?.isLoadingInstalledApps == true { ProgressView() }
            List(selection: $ignoreApplicationSelection) {
                ForEach(scanStore?.installedApps ?? []) { app in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.system(size: 13))
                        Text(app.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.tag(app.id)
                }
            }
            if scanStore == nil {
                Text(L10n.text("请先从主窗口扫描已安装应用，再打开设置。", "Scan installed applications from the main window, then reopen Settings."))
            }
            HStack {
                Button(L10n.text("取消", "Cancel")) { showsIgnoreApplicationPicker = false }
                Spacer()
                Button(L10n.text("添加", "Add")) {
                    let apps = (scanStore?.installedApps ?? []).filter { ignoreApplicationSelection.contains($0.id) }
                    ignoreListModel.add(apps.map { .application(bundleIdentifier: $0.bundleIdentifier, path: $0.path) },
                        names: Dictionary(apps.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first }))
                    ignoreApplicationSelection = []; showsIgnoreApplicationPicker = false
                }.disabled(ignoreApplicationSelection.isEmpty)
            }
        }.padding(20).frame(width: 520, height: 400)
    }
}
