import SwiftUI

/// D-FP3: the "Merge into Clones" button for the duplicates manager and the
/// sheet that says, before anything happens, what will merge, what will not
/// and why, and how much space comes back once the Trash is emptied.
struct DuplicateCloneMergeButton: View {
    @ObservedObject var action: DuplicateCloneMergeAction
    @State private var showsSheet = false

    var body: some View {
        ToolboxLinkButton(title: title, systemImage: "square.on.square.dashed",
                          isEnabled: !action.groups.isEmpty && !action.isMerging) {
            action.preparePreview()
            showsSheet = true
        }
        .help(L10n.text("每个副本留在原处、内容不变，只是和保留的那份共用磁盘空间",
                        "Each copy stays where it is, unchanged, but shares disk space with the kept copy"))
        .sheet(isPresented: $showsSheet) {
            DuplicateCloneMergeSheet(action: action, onClose: {
                showsSheet = false
                if action.phase == .finished { action.reset() }
            })
        }
#if DEBUG
        .layoutProbe("cloneMerge.button")
#endif
    }

    private var title: String {
        if case .merging(let progress) = action.phase {
            return L10n.text("正在合并 \(progress.processed)/\(progress.total)…", "Merging \(progress.processed)/\(progress.total)…")
        }
        return L10n.text("合并为克隆…", "Merge into Clones…")
    }
}

struct DuplicateCloneMergeSheet: View {
    @ObservedObject var action: DuplicateCloneMergeAction
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("把重复文件合并为 APFS 克隆", "Merge Duplicates into APFS Clones"))
                .font(.system(size: 17, weight: .semibold))
            Text(L10n.text("每个副本都留在原处，名字、内容、标签、权限和日期都不变，只是和保留的那份共用同一份磁盘空间；以后改动其中一份，另一份不受影响。被换下的原数据会移到废纸篓，可以在“操作记录”里放回。",
                           "Every copy stays where it is with the same name, content, tags, permissions and dates; it just shares disk space with the kept copy, and changing one later leaves the other alone. The replaced data goes to the Trash and can be put back from Operation History."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
            HStack {
                Spacer()
                switch action.phase {
                case .ready:
                    Button(L10n.text("取消", "Cancel"), action: onClose).keyboardShortcut(.cancelAction)
                    Button(L10n.text("合并 \(action.preview?.ready.count ?? 0) 个副本", "Merge \(action.preview?.ready.count ?? 0) Copies")) {
                        action.merge()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!action.canMerge)
                case .finished, .idle:
                    Button(L10n.text("完成", "Done"), action: onClose).keyboardShortcut(.defaultAction)
                case .previewing, .merging:
                    Button(L10n.text("取消", "Cancel"), action: onClose).disabled(action.isMerging)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
#if DEBUG
        .layoutProbe("cloneMerge.sheet")
#endif
    }

    @ViewBuilder
    private var content: some View {
        switch action.phase {
        case .idle, .previewing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在检查哪些副本可以合并…", "Checking which copies can merge…")).font(.system(size: 12))
            }
        case .ready:
            if let preview = action.preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("可以合并 \(ByteFormat.count(preview.ready.count)) 个副本，清倒废纸篓后约回收 \(ByteFormat.storageString(preview.reclaimableBytes))。",
                                   "\(ByteFormat.count(preview.ready.count)) copies can merge; about \(ByteFormat.storageString(preview.reclaimableBytes)) comes back once the Trash is emptied."))
                        .font(.system(size: 13, weight: .medium))
                    ForEach(action.skipSummary, id: \.reason) { item in
                        Text(L10n.text("\(ByteFormat.count(item.count)) 个不合并：\(item.reason.title)", "\(ByteFormat.count(item.count)) not merged: \(item.reason.title)"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.text("合并前会再次核对每个副本的内容（SHA-256），正在被应用打开或刚改动过的会跳过。",
                                   "Each copy's content is checked again (SHA-256) right before it merges; copies open in an app or just changed are skipped."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message = action.errorMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(CareStudioManagerInk.warning)
            }
        case .merging(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total)))
                Text(progress.currentName.map { L10n.text("正在合并：\($0)", "Merging: \($0)") }
                     ?? L10n.text("正在把换下的数据移到废纸篓…", "Moving the replaced data to the Trash…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .finished:
            if let outcome = action.outcome {
                VStack(alignment: .leading, spacing: 6) {
                    Text(outcome.title + (outcome.reclaimableBytes > 0
                         ? L10n.text("，清倒废纸篓后回收约 \(ByteFormat.storageString(outcome.reclaimableBytes))。",
                                     "; about \(ByteFormat.storageString(outcome.reclaimableBytes)) comes back once the Trash is emptied.")
                         : "。"))
                        .font(.system(size: 13, weight: .medium))
                    if !outcome.skipped.isEmpty {
                        Text(L10n.text("\(ByteFormat.count(outcome.skipped.count)) 个没有合并，保持原样。", "\(ByteFormat.count(outcome.skipped.count)) were not merged and are unchanged."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !outcome.failed.isEmpty {
                        Text(L10n.text("\(ByteFormat.count(outcome.failed.count)) 个合并失败，文件保持原样。", "\(ByteFormat.count(outcome.failed.count)) failed and are unchanged."))
                            .font(.system(size: 12)).foregroundStyle(CareStudioManagerInk.warning)
                    }
                    if !outcome.leftovers.isEmpty {
                        Text(L10n.text("\(ByteFormat.count(outcome.leftovers.count)) 份换下的数据没能移到废纸篓，留在原文件旁边，名字带“合并前的副本”。",
                                       "\(ByteFormat.count(outcome.leftovers.count)) pieces of replaced data could not go to the Trash and stay beside their files, named “before merging”."))
                            .font(.system(size: 12)).foregroundStyle(CareStudioManagerInk.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !outcome.receiptWritten {
                        Text(L10n.text("操作记录没有写完整，请在“操作记录”里核实。", "The record was not fully written; check Operation History."))
                            .font(.system(size: 12)).foregroundStyle(CareStudioManagerInk.warning)
                    }
                }
            }
        }
    }
}
