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
    // D234: every string on this sheet goes through L10n (review P2-9).
    @Published var status = L10n.text("请选择项目所在文件夹；不会默认扫描家目录", "Choose the folders that hold your projects; your home folder is never scanned by default.")
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
        panel.prompt = L10n.text("选择扫描文件夹", "Choose Folders to Scan")
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
        busy = true; status = L10n.text("只读识别项目产物…", "Finding project artifacts (read-only)…")
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
                status = IgnoreListSnapshot.appendingSummary(result.session.metrics.ignoredItemCount, to: result.limited
                    ? L10n.text("扫描不完整；已确认产物可审阅选择，活动时间不完整的项目不参与 N 天选择",
                                "The scan is incomplete; confirmed artifacts can be reviewed, but projects without complete activity times are left out of the N-day selection.")
                    : L10n.text("发现 \(ByteFormat.count(result.rows.count)) 项；默认不预选",
                                "\(L10n.items(result.rows.count)) found; none selected by default."))
            } catch is CancellationError { status = L10n.text("扫描已取消", "Scan canceled.") }
            catch { status = L10n.text("扫描失败：\(error.localizedDescription)", "Scan failed: \(error.localizedDescription)") }
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
                status = preflight.isConfirmable
                    ? L10n.text("请审阅重建条件后确认移到废纸篓", "Review the rebuild conditions, then confirm moving to Trash.")
                    : L10n.text("执行前复查未通过，请重新扫描", "The check before moving did not pass; scan again.")
            } catch { status = L10n.text("无法生成计划：\(error.localizedDescription)", "Could not make a plan: \(error.localizedDescription)") }
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
            status = L10n.text("已移入废纸篓 \(ByteFormat.count(report.summary.movedItemCount)) 项；跳过 \(ByteFormat.count(report.summary.skippedItemCount)) 项；失败 \(ByteFormat.count(report.summary.failedItemCount)) 项。恢复见操作记录；移入废纸篓不代表空间已释放。",
                "Moved to Trash: \(ByteFormat.count(report.summary.movedItemCount)); skipped: \(ByteFormat.count(report.summary.skippedItemCount)); failed: \(ByteFormat.count(report.summary.failedItemCount)). Restore from Operation History; moving to Trash does not free the space yet.")
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
        return row.candidate.estimatedSizeBytes == 0 ? L10n.text("未测量", "Not measured")
            : ByteFormat.storageString(row.candidate.estimatedSizeBytes) + L10n.text("（本轮量到的下限）", " (lower bound measured this run)")
    }
    /// D104 G1: what the selected artifacts free once the Trash is emptied,
    /// when clones or a local snapshot keep a noticeable part of them.
    static func reclaimableNote(_ selected: [ScanCandidate]) -> String {
        let bytes = CleanupByteCount.sum(selected.map(\.estimatedSizeBytes))
        return CleanupSelectionReclaimable(candidates: selected).note(ofSelected: bytes).map { " · " + $0 } ?? ""
    }
    private func planSummary(_ plan: CleanPlan, _ preflight: CleanPreflightReport) -> String {
        let selected = controller.result?.session.candidates.filter { controller.selection.selectedCandidateIDs.contains($0.id) } ?? []
        let size = ByteFormat.storageString(plan.estimatedMovableBytes) + Self.reclaimableNote(selected)
        return L10n.text(
            "动作：移到废纸篓 · \(ByteFormat.count(plan.items.count)) 项 · \(size)；复查就绪 \(ByteFormat.count(preflight.readyCount)) 项，跳过 \(ByteFormat.count(preflight.skippedCount)) 项。可从操作记录恢复。",
            "Action: Move to Trash · \(L10n.items(plan.items.count)) · \(size); ready after the check: \(ByteFormat.count(preflight.readyCount)), skipped: \(ByteFormat.count(preflight.skippedCount)). Restore from Operation History.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("项目产物", "Project Artifacts")).font(AppDesignTokens.TypeScale.pageTitleCompact)
            Text(controller.status).font(AppDesignTokens.TypeScale.body)
            if !controller.roots.isEmpty {
                Text(L10n.text("扫描范围：", "Scope: ") + controller.roots.map(\.path).joined(separator: L10n.text("、", ", "))).font(AppDesignTokens.TypeScale.secondary).textSelection(.enabled)
            }
            HStack {
                Button(L10n.text("选择文件夹", "Choose Folders")) { controller.choose() }.disabled(controller.busy || controller.plan != nil)
                Button(L10n.text("重新扫描", "Scan Again")) { controller.scan() }.disabled(controller.busy || controller.result == nil)
                Stepper(L10n.text("最近 \(days) 天未修改的项目", days == 1 ? "Projects unchanged for 1 day" : "Projects unchanged for \(days) days"), value: $days, in: 1...3650)
                Button(L10n.text("一键选择", "Select These")) { controller.selectInactive(days: days) }.disabled(controller.busy || controller.result == nil || controller.plan != nil)
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
                                Text(row.candidate.snapshot.allocatedSizeBytes == nil
                                     ? L10n.text("逻辑大小；本地占用不可用", "Logical size; local allocation unavailable")
                                     : L10n.text("本地占用", "Local allocation")).font(AppDesignTokens.TypeScale.secondary)
                                if let reclaimable = CleanupCandidateRowHint.reclaimable(for: row.candidate) {
                                    Label(reclaimable.text, systemImage: reclaimable.systemImage).font(AppDesignTokens.TypeScale.secondary)
                                }
                                Text(row.project.path).font(AppDesignTokens.TypeScale.secondary).textSelection(.enabled)
                                Text(L10n.text("项目最后修改：", "Project last modified: ")
                                     + (row.projectModifiedAt?.appFormatted(date: .abbreviated, time: .shortened) ?? L10n.text("未知", "Unknown"))).font(AppDesignTokens.TypeScale.secondary)
                                Text(row.blockedReason ?? L10n.text("清单 \(row.requirement.manifest) 确认；产物可重新生成，默认不预选",
                                                                    "Confirmed by \(row.requirement.manifest); the artifact can be rebuilt; not selected by default")).font(AppDesignTokens.TypeScale.secondary)
                                Text(row.requirement.lockEvidence ?? L10n.text("锁文件状态未确认", "Lock file state not confirmed")).font(AppDesignTokens.TypeScale.secondary)
                                if controller.plan != nil && controller.selection.selectedCandidateIDs.contains(row.id) {
                                    Text(L10n.text("重建：在此项目目录执行 \(row.requirement.rebuildCommand)", "Rebuild: run \(row.requirement.rebuildCommand) in this project folder")).font(AppDesignTokens.TypeScale.body).textSelection(.enabled)
                                    Link(L10n.text("再生性依据", "Why It Can Be Rebuilt"), destination: URL(string: row.requirement.evidenceURL)!).font(AppDesignTokens.TypeScale.secondary)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            Text(L10n.text("大小优先显示本地占用；不可用时标明逻辑大小。不可读或受保护项仅显示已量到的下限。硬链接按身份去重；与 APFS 克隆共享或被本地快照占用的部分，清空废纸篓后也不会释放，明显时在行内注明预计释放量。",
                            "Sizes show local allocation first and say when only the logical size is known. Unreadable or protected items show the lower bound measured. Hard links count once; space shared with APFS clones or held by a local snapshot is not freed when the Trash is emptied, and rows note the expected amount when that is noticeable.")).font(AppDesignTokens.TypeScale.secondary)
            if let plan = controller.plan, let preflight = controller.preflight {
                Text(planSummary(plan, preflight))
                Toggle(L10n.text("已核对重建命令、联网/权限条件及产物内本地改动，并停止相关 node、cargo、python/虚拟环境等进程（无法可靠检测）",
                                  "I checked the rebuild commands, network and permission needs and local changes inside the artifacts, and stopped related node, cargo, Python or virtual-environment processes (these cannot be detected reliably)"), isOn: $reviewed)
                HStack {
                    Button(L10n.text("返回选择", "Back to Selection")) { controller.plan = nil; controller.preflight = nil; reviewed = false }.disabled(controller.busy)
                    Button(L10n.text("确认移到废纸篓", "Move to Trash")) { controller.execute(); reviewed = false }.disabled(!reviewed || !preflight.isConfirmable || controller.busy)
                }
            } else {
                Button(L10n.text("审阅清理计划", "Review Cleanup Plan")) { reviewed = false; controller.prepare() }.disabled(controller.selection.selectedCandidateIDs.isEmpty || controller.busy)
            }
            HStack {
                if controller.busy { Button(L10n.text("取消操作", "Cancel")) { controller.cancel() } }
                Spacer()
                Button(L10n.text("关闭", "Close")) { controller.close(); dismiss() }.disabled(controller.busy)
            }
        }.padding(20).frame(minWidth: 760, minHeight: 580)
            .onDisappear { controller.close() }
    }
}
