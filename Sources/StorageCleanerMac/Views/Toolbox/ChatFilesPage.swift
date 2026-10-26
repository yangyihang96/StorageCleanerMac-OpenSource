import AppKit
import SwiftUI

/// D-FP3: the Chat Files category of My Clutter (Tencent Lemon's chat file
/// cleanup and move, in the studio review layout). Months are listed per
/// app, account and kind; nothing is selected by default, and the page
/// says what removing chat files does to the chats themselves.
extension ChatApp {
    /// The chat app's own icon, when it is installed.
    @MainActor var iconPath: String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.path
    }
}

struct ChatFilesPage: View {
    @ObservedObject var store: ChatFilesStore
    let module: CareStudioModule
    let onBack: () -> Void

    @State private var currentApp: ChatApp?
    @State private var query = ""
    @State private var sort: ToolboxSort = .date
    @State private var confirmsTrash = false
    @State private var showsCopySheet = false

    var body: some View {
        Group {
            switch store.phase {
            case .needsFullDiskAccess:
                accessPage
            case .idle where store.inventory == nil, .scanning where store.inventory == nil:
                CareStudioRunningPage(
                    module: module,
                    title: L10n.text("正在统计聊天文件…", "Counting Chat Files…"),
                    detail: L10n.text("只看文件夹和大小，不读聊天内容", "Folders and sizes only; no chat content is read"),
                    onStop: {
                        store.cancel()
                        onBack()
                    }
                )
            default:
                panel
            }
        }
        .onAppear {
            if store.inventory == nil, !store.isBusy { store.scan() }
        }
    }

    private var accessPage: some View {
        CareStudioLandingPage(
            module: module,
            art: .statePermission,
            title: L10n.text("聊天文件", "Chat Files"),
            subtitle: L10n.text("微信、QQ、企业微信把收到的图片、视频和文件放在各自受保护的文件夹里。给本应用“完全磁盘访问权限”后才能统计，否则 macOS 会逐个询问。",
                                "WeChat, QQ and WeCom keep received pictures, videos and files in their own protected folders. Give this app Full Disk Access to count them; otherwise macOS asks for each app."),
            actionTitle: L10n.text("打开设置", "Open Settings"),
            action: store.openFullDiskAccessSettings
        ) {
            ToolboxLinkButton(title: L10n.text("已经打开了，重新检查", "Done; check again"), systemImage: "arrow.clockwise") {
                store.scan()
            }
        }
    }

    // MARK: Panel

    private var shownApp: ChatApp? {
        if let currentApp, store.apps.contains(currentApp) { return currentApp }
        return store.apps.first
    }

    private var panel: some View {
        ToolboxManagerPanel(
            module: module,
            title: L10n.text("聊天文件", "Chat Files"),
            query: $query,
            searchPrompt: L10n.text("搜索月份或账号", "Search month or account"),
            sortOptions: [.date, .size],
            sort: $sort,
            categoryWidth: 230,
            onBack: onBack
        ) {
            appColumn
        } rows: {
            rowColumn
        } footer: {
            ToolboxFooter(
                selectedCount: store.selectedRows.count,
                selectedBytes: store.selectedBytes,
                actionTitle: L10n.text("移到废纸篓", "Move to Trash"),
                actionEnabled: !store.selectedRows.isEmpty && store.phase == .ready,
                action: { confirmsTrash = true }
            ) {
                Menu {
                    Button(L10n.text("选择 \(store.cutoffDays) 天前的", "Select Older Than \(store.cutoffDays) Days")) {
                        store.setSelected(store.rows(for: shownApp).filter(\.isOlderThanCutoff), selected: true)
                    }
                    if !store.verifiedCopies.isEmpty {
                        Button(L10n.text("选择已复制并核对的原件", "Select Originals Already Copied")) {
                            store.selectVerifiedOriginals()
                        }
                    }
                    Button(L10n.text("全部不选", "Deselect All")) {
                        store.setSelected(store.inventory?.rows ?? [], selected: false)
                    }
                } label: {
                    Text(L10n.text("选择", "Selection")).font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.isBusy)
            }
        }
        .confirmationDialog(L10n.text("把选中的聊天文件移到废纸篓？", "Move the Selected Chat Files to the Trash?"),
                            isPresented: $confirmsTrash, titleVisibility: .visible) {
            Button(L10n.text("移到废纸篓", "Move to Trash"), role: .destructive) { store.moveSelectedToTrash() }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("先退出对应的聊天软件。移走后，聊天里这些图片、视频和文件会显示为已失效或需要重新下载（过期的就下载不了）；可以在“操作记录”里放回。",
                           "Quit the chat app first. Afterwards these pictures, videos and files show as expired or need downloading again in the chats (expired ones cannot be downloaded); you can put them back from Operation History."))
        }
        .sheet(isPresented: $showsCopySheet) {
            ChatFilesCopySheet(store: store, onClose: { showsCopySheet = false })
        }
    }

    private var appColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let summary = store.summary {
                    Text(L10n.text("共 \(ByteFormat.storageString(summary.totalBytes))，其中 \(store.cutoffDays) 天前的 \(ByteFormat.storageString(summary.olderBytes))",
                                   "\(ByteFormat.storageString(summary.totalBytes)) in all, \(ByteFormat.storageString(summary.olderBytes)) older than \(store.cutoffDays) days"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                }
                ForEach(store.apps) { app in
                    let rows = store.inventory?.rows(for: app) ?? []
                    ToolboxCategoryRow(
                        module: module,
                        title: app.title,
                        detail: ByteFormat.storageString(rows.reduce(0) { $0 + $1.bytes }) + " · "
                            + L10n.text("\(rows.reduce(0) { $0 + $1.fileCount }) 个文件", "\(rows.reduce(0) { $0 + $1.fileCount }) files"),
                        systemImage: "bubble.left.and.bubble.right",
                        appIconPath: app.iconPath,
                        isCurrent: query.isEmpty && app == shownApp,
                        tick: store.selectionState(for: rows),
                        tickEnabled: !store.isBusy,
                        onSelect: {
                            currentApp = app
                            query = ""
                        },
                        onToggle: {
                            // An app's tick selects only what is older than the cutoff.
                            let older = rows.filter(\.isOlderThanCutoff)
                            store.setSelected(store.selectionState(for: rows) == .unchecked ? older : rows,
                                              selected: store.selectionState(for: rows) == .unchecked)
                        }
                    )
                }
            }
            .padding(10)
        }
    }

    private var rowColumn: some View {
        let rows = sorted(filteredRows)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                notices
                ToolboxSectionHeader(
                    title: shownApp?.title ?? L10n.text("聊天文件", "Chat Files"),
                    summary: L10n.text("收到的图片、视频和文件，按账号和月份列出。默认不选；需要的请先在聊天里另存。",
                                       "Received pictures, videos and files, by account and month. Nothing is selected by default; save what you need from the chat first.")
                ) {
                    ToolboxFilterMenu(title: L10n.text("类型：", "Kind: "),
                                                         valueTitle: store.kindFilter?.title ?? L10n.text("全部", "All")) {
                        Button(L10n.text("全部", "All")) { store.kindFilter = nil }
                        ForEach(ChatMediaKind.allCases) { kind in Button(kind.title) { store.kindFilter = kind } }
                    }
                    ToolboxFilterMenu(title: L10n.text("时间：", "Age: "),
                                                                 valueTitle: store.ageFilter.title(days: store.cutoffDays)) {
                        ForEach(ChatFilesStore.AgeFilter.allCases) { filter in
                            Button(filter.title(days: store.cutoffDays)) { store.ageFilter = filter }
                        }
                    }
                    ToolboxLinkButton(title: L10n.text("复制到外置盘…", "Copy to Another Drive…"), systemImage: "externaldrive",
                                      isEnabled: store.selectedRows.contains { $0.kind.canBeCopiedElsewhere } && store.phase == .ready) {
                        store.refreshVolumes()
                        showsCopySheet = true
                    }
                }
                ForEach(rows) { row(for: $0) }
                if store.apps.isEmpty {
                    CareStudioManagerEmptyState(title: L10n.text("没有找到微信、QQ 或企业微信的文件",
                                                                 "No WeChat, QQ or WeCom Files Were Found"))
                } else if rows.isEmpty {
                    CareStudioManagerEmptyState(title: L10n.text("这里没有符合筛选条件的文件", "Nothing Here Matches the Filters"))
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var filteredRows: [ChatFilesRow] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return store.rows(for: shownApp) }
        return store.rows(for: nil).filter {
            ($0.month ?? "").contains(needle) || $0.account.localizedCaseInsensitiveContains(needle)
                || $0.app.title.localizedCaseInsensitiveContains(needle)
        }
    }

    private func sorted(_ rows: [ChatFilesRow]) -> [ChatFilesRow] {
        switch sort {
        case .size: rows.sorted { $0.bytes > $1.bytes }
        case .date, .name: rows
        }
    }

    @ViewBuilder
    private var notices: some View {
        if case .working(let title) = store.phase {
            ToolboxNotice(tone: .info, title: title)
        }
        if let outcome = store.trashOutcome {
            ToolboxNotice(
                tone: outcome.movedRowIDs.isEmpty ? .warning : .success,
                title: outcome.movedRowIDs.isEmpty
                    ? L10n.text("没有移动任何文件", "Nothing was moved")
                    : L10n.text("已把 \(ByteFormat.count(outcome.movedRowIDs.count)) 个月份的文件移到废纸篓 · \(ByteFormat.storageString(outcome.movedBytes))",
                                "Moved \(ByteFormat.count(outcome.movedRowIDs.count)) months of files to the Trash · \(ByteFormat.storageString(outcome.movedBytes))"),
                lines: outcome.keptNotes + (outcome.receiptWritten ? [] : [L10n.text("操作记录没有写完整，请在“操作记录”里核实。",
                                                                                 "The record was not fully written; check Operation History.")]),
                onDismiss: store.dismissNotices,
                showsStateArt: true
            )
        }
        if let message = store.errorMessage {
            ToolboxNotice(tone: .warning, title: message, onDismiss: store.dismissNotices)
        }
    }

    private func row(for row: ChatFilesRow) -> some View {
        var badges: [ToolboxBadge] = []
        if row.isOlderThanCutoff { badges.append(.init(text: L10n.text("\(store.cutoffDays) 天前", "Over \(store.cutoffDays) days"), tone: .accent)) }
        if store.verifiedCopies[row.id] != nil { badges.append(.init(text: L10n.text("已复制并核对", "Copied and checked"), tone: .neutral)) }
        let detail = [row.app.title, row.accountLabel, L10n.text("\(ByteFormat.count(row.fileCount)) 个文件", "\(ByteFormat.count(row.fileCount)) files")]
            .joined(separator: " · ")
        return ToolboxItemRow(
            title: row.title,
            badges: badges,
            detail: detail,
            value: ToolboxText.size(row.bytes, lowerBound: row.sizeIsLowerBound),
            tick: store.isSelected(row) ? .checked : .unchecked,
            tickEnabled: !store.isBusy,
            help: row.folders.prefix(3).map(\.path).joined(separator: "\n"),
            onToggle: { store.toggle(row) },
            onReveal: { store.reveal(row) },
            copyPath: row.folders.first?.path
        ) {
            CareStudioGlyph(module: module, systemImage: row.kind.systemImage, side: 28)
        }
    }
}

/// Chooses a drive and copies the selected videos and files there, each
/// file checked; the originals stay until the person moves them.
struct ChatFilesCopySheet: View {
    @ObservedObject var store: ChatFilesStore
    let onClose: () -> Void
    @State private var volumeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("复制到外置盘", "Copy to Another Drive")).font(.system(size: 17, weight: .semibold))
            Text(L10n.text("只复制视频和文件；图片是聊天软件自己的格式，复制到别处打不开。每个文件复制后都会读回来逐字节核对（SHA-256）。原件保持不动，核对通过后，可以在列表里选“已复制并核对的原件”再移到废纸篓。",
                           "Only videos and files are copied; pictures are in the chat app's own format and cannot be opened elsewhere. Each file is read back and compared (SHA-256). The originals stay; once checked, choose “Originals Already Copied” in the list and move them to the Trash."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.volumes.isEmpty {
                Text(L10n.text("没有找到可写入的外置盘。", "No writable external drive was found."))
                    .font(.system(size: 12))
            } else {
                Picker(L10n.text("外置盘", "Drive"), selection: $volumeID) {
                    ForEach(store.volumes) { volume in
                        Text("\(volume.name)（\(ByteFormat.storageString(volume.availableBytes))）").tag(String?.some(volume.id))
                    }
                }
            }
            if case .working(let title) = store.phase {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(title).font(.system(size: 12)) }
            }
            if let outcome = store.copyOutcome {
                Text(L10n.text("核对通过 \(ByteFormat.count(outcome.verified.count)) 项 · \(ByteFormat.storageString(outcome.copiedBytes))；没有完成 \(ByteFormat.count(outcome.failed.count)) 项",
                               "\(ByteFormat.count(outcome.verified.count)) checked · \(ByteFormat.storageString(outcome.copiedBytes)); \(ByteFormat.count(outcome.failed.count)) not done"))
                    .font(.system(size: 12, weight: .medium))
                ForEach(Array(Set(outcome.failed.values)).sorted(), id: \.self) { reason in
                    Text(reason).font(.system(size: 11)).foregroundStyle(CareStudioManagerInk.warning)
                }
            }
            HStack {
                Spacer()
                Button(L10n.text("关闭", "Close"), action: onClose).keyboardShortcut(.cancelAction)
                Button(L10n.text("开始复制", "Copy")) {
                    if let volume = store.volumes.first(where: { $0.id == volumeID }) { store.copySelected(to: volume) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(volumeID == nil || store.phase != .ready)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { volumeID = volumeID ?? store.volumes.first?.id }
        .onChange(of: store.volumes) { _, volumes in volumeID = volumeID ?? volumes.first?.id }
    }
}
