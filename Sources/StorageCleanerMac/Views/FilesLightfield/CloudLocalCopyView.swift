import SwiftUI

/// D90: a separate selection/review flow; Trash selection is never reused.
struct CloudLocalCopySheet: View {
    @Environment(\.colorScheme) private var scheme
    let entries: [StorageTreemapEntry]
    let coordinator: HeavyWorkCoordinator
    let onClose: () -> Void
    var provider: any CloudLocalCopyProvider = NativeCloudLocalCopyProvider()
    @State private var states: [CloudLocalCopyState] = []
    @State private var selection = Set<String>()
    @State private var loading = true
    @State private var confirming = false
    @State private var running = false
    @State private var cancelling = false
    @State private var outcome: CloudCopyOutcome?
    @State private var operation: Task<Void, Never>?

    private var chosen: [CloudLocalCopyState] { states.filter { selection.contains($0.path) } }
    private var estimated: Int64 { chosen.reduce(0) { $0 + $1.allocatedBytes } }
    private var files: [StorageTreemapEntry] { entries.filter { $0.role == .content && !$0.isDirectory } }
    private var placeholders: Int { files.filter(\.isCloudOnly).count }
    private var candidates: [String] { CloudLocalCopyService.reviewCandidates(entries) }
    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("释放本地副本（不删除云端）", "Release Local Copies (Keep Cloud Files)"))
                .font(.system(size: 24, weight: .semibold))
            Text(L10n.text("需要时打开即可重新下载，需网络。不会删除文件、移到废纸篓或修改内容。",
                           "Open when needed to download again; a network connection is required. Files are never deleted, moved to Trash or edited."))
                .font(.system(size: 13)).foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true)
            if let outcome {
                Text(L10n.text("本地占用实测减少（逐文件分配大小）：", "Measured local usage reduction (per-file allocated size): ") + ByteFormat.storageString(outcome.releasedBytes))
                    .font(.system(size: 15, weight: .semibold))
                Text(L10n.text("原分析索引尚未刷新；请重新分析查看最新容量。", "The analysis index has not refreshed; analyze again for current sizes."))
                    .font(.system(size: 13)).foregroundStyle(palette.fg2)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(outcome.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.system(size: 15))
                                    .lineLimit(1).truncationMode(.middle).help(item.path)
                                Text(item.status.title + (item.releasedBytes > 0 ? " · " + ByteFormat.storageString(item.releasedBytes) : ""))
                                    .font(.system(size: 13)).foregroundStyle(palette.fg2)
                                if let detail = item.detail {
                                    Text(detail).font(.system(size: 13)).foregroundStyle(palette.fg2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
                        }
                    }
                }
            } else {
                Text(L10n.text("本目录 \(files.count) 个文件，已跳过 \(placeholders) 个云端占位；最多检查 \(CloudLocalCopyService.reviewLimit) 项，单批最多 \(CloudLocalCopyService.batchLimit) 项。文件夹请进入后逐个文件选择。",
                               "\(files.count) files in this folder, \(placeholders) cloud placeholders skipped; checks up to \(CloudLocalCopyService.reviewLimit), releases up to \(CloudLocalCopyService.batchLimit) per batch. Enter folders to select individual files."))
                    .font(.system(size: 13)).foregroundStyle(palette.fg2).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("已选 \(chosen.count) 项 · 预计本地占用减少 ", "\(chosen.count) selected · Estimated local usage reduction ") + ByteFormat.storageString(estimated))
                    .font(.system(size: 15, weight: .semibold))
                if confirming {
                    Text(L10n.text("请确认以下对象与提供商。执行前会逐项复查状态。", "Confirm these files and providers. Each state will be checked again before release."))
                        .font(.system(size: 13)).foregroundStyle(palette.fg2)
                }
                if loading {
                    Text(L10n.text("正在读取云同步元数据…", "Reading cloud sync metadata…")).font(.system(size: 15))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(confirming ? chosen : states) { state in row(state, palette: palette) }
                        }
                    }
                    if states.isEmpty {
                        Text(L10n.text("本目录没有可检查的文件", "No files to check in this folder")).font(.system(size: 13)).foregroundStyle(palette.fg2)
                    }
                }
            }
            if running {
                Text(cancelling ? L10n.text("正在取消；已发出的请求仍会完成回读…", "Cancelling; an accepted request will still finish readback…")
                     : L10n.text("正在逐项复查、释放和回读…", "Checking, releasing and reading back each item…"))
                    .font(.system(size: 13)).foregroundStyle(palette.fg2)
            }
            HStack {
                if running {
                    Button(L10n.text("取消后续项目", "Cancel Remaining")) { cancelling = true; operation?.cancel() }
                        .disabled(cancelling)
                } else if outcome == nil {
                    if confirming {
                        Button(L10n.text("返回选择", "Back to Selection")) { confirming = false }
                        Button(L10n.text("确认释放本地副本", "Confirm Release of Local Copies"), action: release)
                            .disabled(chosen.isEmpty)
                    } else {
                        Button(L10n.text("检查所选项目", "Review Selected Files")) { confirming = true }
                            .disabled(loading || chosen.isEmpty)
                    }
                }
                Spacer()
                Button(L10n.text("关闭", "Close"), action: onClose).disabled(running)
            }.buttonStyle(FeatureLightfieldRowButtonStyle())
        }.padding(24).frame(width: 720, height: 540)
        .foregroundStyle(palette.fg)
        .interactiveDismissDisabled(running)
        .task {
            let read = await CloudLocalCopyService.readStates(candidates, provider: provider)
            guard !Task.isCancelled else { return }
            states = read; loading = false
        }
        .onDisappear { operation?.cancel() }
    }

    private func row(_ state: CloudLocalCopyState, palette: FeatureLightfieldPalette) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if !confirming {
                Toggle("", isOn: Binding(get: { selection.contains(state.path) }, set: { enabled in
                    if enabled, state.block == nil, selection.count < CloudLocalCopyService.batchLimit { selection.insert(state.path) }
                    else if !enabled { selection.remove(state.path) }
                }))
                .labelsHidden().toggleStyle(.checkbox)
                .accessibilityLabel(URL(fileURLWithPath: state.path).lastPathComponent)
                .disabled(state.block != nil || running || (!selection.contains(state.path) && selection.count >= CloudLocalCopyService.batchLimit))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: state.path).lastPathComponent).font(.system(size: 15))
                    .lineLimit(1).truncationMode(.middle).help(state.path)
                Text(state.provider.title + " · " + ByteFormat.storageString(state.allocatedBytes))
                    .font(.system(size: 13)).foregroundStyle(palette.fg2)
                if let block = state.block {
                    Text(block.title).font(.system(size: 13)).foregroundStyle(palette.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 8)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
    }

    private func release() {
        guard !running, confirming, !chosen.isEmpty else { return }
        let selected = chosen
        let service = CloudLocalCopyService(provider: provider, coordinator: coordinator)
        running = true
        operation = Task {
            let result = await service.release(selected)
            outcome = result; running = false; operation = nil
        }
    }
}
