import AppKit
import SwiftUI

struct ProjectArtifactEntryButton: View {
    let coordinator: HeavyWorkCoordinator
    @State private var presented = false
    var body: some View {
        Button(L10n.text("项目产物 · 选择文件夹", "Project Artifacts · Choose Folders")) { presented = true }
            .sheet(isPresented: $presented) { ProjectArtifactView(coordinator: coordinator) }
    }
}

/// Owns its scoped session, but uses the shared heavy-work lane, plan builder,
/// executor and durable operation history. No ScanStore mutation is needed.
@MainActor
private final class ProjectArtifactController: ObservableObject {
    @Published var result: ProjectArtifactScanResult?
    @Published var selection = CleanupSelection()
    @Published var status = "请选择项目所在文件夹；不会默认扫描家目录"
    @Published var busy = false
    @Published var plan: CleanPlan?
    @Published var preflight: CleanPreflightReport?
    @Published var report: CleanReport?
    private var task: Task<Void, Never>?
    @Published private(set) var roots: [URL] = []
    private var scoped: [URL] = []
    private var closing = false
    private let panelCoordinator = AppOpenPanelCoordinator()
    private let coordinator: HeavyWorkCoordinator
    private let executor: SafeCleanupExecutor

    init(coordinator: HeavyWorkCoordinator) {
        self.coordinator = coordinator
        executor = SafeCleanupExecutor(coordinator: coordinator, persistReport: { report, identities in
            try CleanupReportJournal.live.checkpoint(report, expectedIdentities: identities)
        })
    }
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "选择扫描文件夹"
        panelCoordinator.present(panel, attachedTo: AppOpenPanelCoordinator.preferredHostWindow()) { [weak self] response in
            guard let self, response == .OK, !self.closing else { return }
            self.releaseAccess()
            self.roots = panel.urls
            _ = FolderAccessGrantService.saveAccess(for: self.roots)
            self.scoped = self.roots.filter { $0.startAccessingSecurityScopedResource() }
            self.scan()
        }
    }
    func scan() {
        guard !busy else { return }
        selection = CleanupSelection(); result = nil; report = nil; plan = nil; preflight = nil
        busy = true; status = "只读识别项目产物…"
        let roots = roots, coordinator = coordinator
        let ignoreList = IgnoreListStore.shared.snapshot()
        let excludedURLs = ignoreList.paths(for: .other).map { URL(fileURLWithPath: $0) }
        task = Task {
            defer { busy = false; task = nil; if closing { releaseAccess() } }
            do {
                let result = try await coordinator.withLease(owner: .mainScan) { _ in
                    try await ProjectArtifactScanner(excludedURLs: excludedURLs, ignoreList: ignoreList).scan(roots: roots)
                }
                self.result = result
                status = IgnoreListSnapshot.appendingSummary(result.session.metrics.ignoredItemCount, to: result.limited ? "扫描不完整；已确认产物可审阅选择，活动时间不完整的项目不参与 N 天选择" : "发现 \(ByteFormat.count(result.rows.count)) 项；默认不预选")
            } catch is CancellationError { status = "扫描已取消" }
            catch { status = "扫描失败：\(error.localizedDescription)" }
        }
    }
    func selectInactive(days: Int) {
        guard let result else { return }
        selection.setCandidates(result.inactiveIDs(days: days), selected: true, in: result.session)
    }
    func prepare() {
        guard let result, !busy else { return }
        busy = true
        task = Task {
            defer { busy = false; task = nil; if closing { releaseAccess() } }
            do {
                let plan = try CleanPlanBuilder.makePlan(session: result.session, selection: selection, activeRules: result.rules, disposition: .trash)
                let preflight = await executor.preflight(plan: plan, context: context(result: result, approved: nil))
                self.plan = plan; self.preflight = preflight
                status = preflight.isConfirmable ? "请审阅重建条件后确认移到废纸篓" : "执行前复查未通过，请重新扫描"
            } catch { status = "无法生成计划：\(error.localizedDescription)" }
        }
    }
    func execute() {
        guard let result, let plan, let preflight, preflight.isConfirmable, !busy else { return }
        let approved = Set(preflight.items.filter { $0.status == .ready }.map(\.planItemID))
        busy = true
        task = Task {
            defer { busy = false; task = nil; if closing { releaseAccess() } }
            let report = await executor.execute(plan: plan, context: context(result: result, approved: approved), progress: { _ in })
            self.report = report; self.plan = nil; self.preflight = nil; self.selection = CleanupSelection()
            self.result = nil // Consumed plan cannot be selected again; rescan explicitly.
            status = "已移入废纸篓 \(ByteFormat.count(report.summary.movedItemCount)) 项；跳过 \(ByteFormat.count(report.summary.skippedItemCount)) 项；失败 \(ByteFormat.count(report.summary.failedItemCount)) 项。恢复见操作记录；移入废纸篓不代表空间已释放。"
        }
    }
    func cancel() { task?.cancel() }
    func close() { closing = true; panelCoordinator.cancel(); cancel(); if !busy { releaseAccess() } }
    private func releaseAccess() { scoped.forEach { $0.stopAccessingSecurityScopedResource() }; scoped = [] }
    private func context(result: ProjectArtifactScanResult, approved: Set<UUID>?) -> CleanupExecutionContext {
        .init(featureConfiguration: .productDefault, activeSessionID: result.session.id, activeRules: result.rules,
              userHomeURL: FileManager.default.homeDirectoryForCurrentUser, excludedURLs: ScanExclusionService.excludedPaths().map { URL(fileURLWithPath: $0) }, approvedPlanItemIDs: approved)
    }
}

struct ProjectArtifactView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: ProjectArtifactController
    @State private var days = 30
    @State private var reviewed = false
    init(coordinator: HeavyWorkCoordinator) { _controller = StateObject(wrappedValue: ProjectArtifactController(coordinator: coordinator)) }
    /// Display-only rows are not measured; a zero lower bound would read as empty.
    static func sizeText(_ row: ProjectArtifactRow) -> String {
        guard row.blockedReason != nil else { return ByteFormat.storageString(row.candidate.estimatedSizeBytes) }
        return row.candidate.estimatedSizeBytes == 0 ? "未测量" : ByteFormat.storageString(row.candidate.estimatedSizeBytes) + "（本轮量到的下限）"
    }
    /// D104 G1: what the selected artifacts free once the Trash is emptied,
    /// when clones or a local snapshot keep a noticeable part of them.
    static func reclaimableNote(_ selected: [ScanCandidate]) -> String {
        let bytes = CleanupByteCount.sum(selected.map(\.estimatedSizeBytes))
        return CleanupSelectionReclaimable(candidates: selected).note(ofSelected: bytes).map { " · " + $0 } ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("项目产物").font(AppDesignTokens.TypeScale.pageTitleCompact)
            Text(controller.status).font(AppDesignTokens.TypeScale.body)
            if !controller.roots.isEmpty {
                Text("扫描范围：" + controller.roots.map(\.path).joined(separator: "、")).font(AppDesignTokens.TypeScale.secondary).textSelection(.enabled)
            }
            HStack {
                Button("选择文件夹") { controller.choose() }.disabled(controller.busy || controller.plan != nil)
                Button("重新扫描") { controller.scan() }.disabled(controller.busy || controller.result == nil)
                Stepper("最近 \(days) 天未修改的项目", value: $days, in: 1...3650)
                Button("一键选择") { controller.selectInactive(days: days) }.disabled(controller.busy || controller.result == nil || controller.plan != nil)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let result = controller.result {
                        ForEach(result.scopeWarnings, id: \.self) { Text($0).font(AppDesignTokens.TypeScale.secondary) }
                        ForEach(result.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(isOn: Binding(get: { controller.selection.selectedCandidateIDs.contains(row.id) }, set: {
                                    controller.selection.setCandidate(row.id, selected: $0, in: result.session)
                                })) {
                                    Text("\(row.project.lastPathComponent) · \(row.requirement.relativeArtifact) · \(Self.sizeText(row))")
                                }.disabled(!row.candidate.isSelectable || controller.busy || controller.plan != nil)
                                Text(row.candidate.snapshot.allocatedSizeBytes == nil ? "逻辑大小；本地占用不可用" : "本地占用").font(AppDesignTokens.TypeScale.secondary)
                                if let reclaimable = CleanupCandidateRowHint.reclaimable(for: row.candidate) {
                                    Label(reclaimable.text, systemImage: reclaimable.systemImage).font(AppDesignTokens.TypeScale.secondary)
                                }
                                Text(row.project.path).font(AppDesignTokens.TypeScale.secondary).textSelection(.enabled)
                                Text("项目最后修改：\(row.projectModifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")").font(AppDesignTokens.TypeScale.secondary)
                                Text(row.blockedReason ?? "清单 \(row.requirement.manifest) 确认；产物可重新生成，默认不预选").font(AppDesignTokens.TypeScale.secondary)
                                Text(row.requirement.lockEvidence ?? "锁文件状态未确认").font(AppDesignTokens.TypeScale.secondary)
                                if controller.plan != nil && controller.selection.selectedCandidateIDs.contains(row.id) {
                                    Text("重建：在此项目目录执行 \(row.requirement.rebuildCommand)").font(AppDesignTokens.TypeScale.body).textSelection(.enabled)
                                    Link("再生性依据", destination: URL(string: row.requirement.evidenceURL)!).font(AppDesignTokens.TypeScale.secondary)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            Text("大小优先显示本地占用；不可用时标明逻辑大小。不可读或受保护项仅显示已量到的下限。硬链接按身份去重；与 APFS 克隆共享或被本地快照占用的部分，清空废纸篓后也不会释放，明显时在行内注明预计释放量。").font(AppDesignTokens.TypeScale.secondary)
            if let plan = controller.plan, let preflight = controller.preflight {
                Text("动作：移到废纸篓 · \(ByteFormat.count(plan.items.count)) 项 · \(ByteFormat.storageString(plan.estimatedMovableBytes))\(Self.reclaimableNote(controller.result?.session.candidates.filter { controller.selection.selectedCandidateIDs.contains($0.id) } ?? []))；复查就绪 \(ByteFormat.count(preflight.readyCount)) 项，跳过 \(ByteFormat.count(preflight.skippedCount)) 项。可从操作记录恢复。")
                Toggle("已核对重建命令、联网/权限条件及产物内本地改动，并停止相关 node、cargo、python/虚拟环境等进程（无法可靠检测）", isOn: $reviewed)
                HStack {
                    Button("返回选择") { controller.plan = nil; controller.preflight = nil; reviewed = false }.disabled(controller.busy)
                    Button("确认移到废纸篓") { controller.execute(); reviewed = false }.disabled(!reviewed || !preflight.isConfirmable || controller.busy)
                }
            } else {
                Button("审阅清理计划") { reviewed = false; controller.prepare() }.disabled(controller.selection.selectedCandidateIDs.isEmpty || controller.busy)
            }
            HStack {
                if controller.busy { Button("取消操作") { controller.cancel() } }
                Spacer()
                Button("关闭") { controller.close(); dismiss() }.disabled(controller.busy)
            }
        }.padding(20).frame(minWidth: 760, minHeight: 580)
            .onDisappear { controller.close() }
    }
}
