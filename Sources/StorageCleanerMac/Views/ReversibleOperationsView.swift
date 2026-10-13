import SwiftUI

struct ReversibleOperationsView: View {
    @ObservedObject var store: ScanStore
    var resumeUninstall: ((CleanReport) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRestore: CleanReport?
    @State private var expandedPlan: CleanPlanID?
    /// P2-6: receipts whose moved item is no longer where it was moved (for
    /// example after the Trash was emptied), per opened receipt.
    @State private var departedReceiptPaths: [CleanPlanID: Set<String>] = [:]
    /// N18: a restore result left from before this page opened is not shown.
    @State private var recoveryBaseline = OperationRecordPresentation.RecoveryBaseline.notCaptured

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack {
                Text(L10n.text("操作记录", "Operation History"))
                    .font(AppDesignTokens.Typography.sectionTitle)
                Spacer()
                Button(L10n.text("刷新", "Refresh")) { store.refreshOperationReports(reconcile: true) }
                Button(L10n.text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.text("清空废纸篓后才释放空间；恢复前核验身份，同名冲突不覆盖。",
                           "Space is released after emptying Trash; restore verifies identity and never overwrites name conflicts."))
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            if let warning = store.operationReportWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(AppDesignTokens.Palette.warning)
            }
            if let notice = store.operationReconcileNotice {
                HStack(alignment: .firstTextBaseline) {
                    Label(notice.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                    if notice == .trashNotReadable {
                        Spacer(minLength: 8)
                        Button(L10n.text("打开系统设置", "Open System Settings")) { _ = CleanupService.openFullDiskAccessSettings() }
                            .appButtonChrome(.tertiary)
                    }
                }.font(AppDesignTokens.Typography.metadata)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                    if let recovery = OperationRecordPresentation.visibleRecovery(
                        current: store.operationRecoveryResult, baseline: recoveryBaseline
                    ) {
                        Text(recovery.resultMessage)
                        ForEach(recovery.items) { item in
                            HStack {
                                Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                                Spacer()
                                Text(recoveryLabel(item.outcome))
                            }.font(AppDesignTokens.Typography.metadata)
                        }
                    }
                    if store.operationReports.isEmpty && !store.isLoadingOperationReports {
                        Text(L10n.text("暂无操作回执", "No operation receipts"))
                    }
                    ForEach(store.operationReports) { summary in
                        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                            Text(OperationRecordPresentation.title(rulesVersion: summary.rulesVersion, subject: summary.subject,
                                                                   itemCount: summary.summary.requestedItemCount))
                                .font(AppDesignTokens.Typography.compactLabelEmphasis)
                                .lineLimit(2)
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let status = OperationRecordPresentation.temporaryResourceStatus(
                                        rulesVersion: summary.rulesVersion, outcome: summary.outcome
                                    ) {
                                        // A copy's staging folder or a benchmark fixture:
                                        // nothing of the user's moved, nothing to restore.
                                        Label(status, systemImage: summary.outcome == .completed
                                              ? "checkmark.circle" : "exclamationmark.circle")
                                    } else if let result = summary.presentation {
                                        Label(result.title, systemImage: result.systemImage)
                                        Text(result.summary).foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 4) {
                                        Text(summary.startedAt, style: .date)
                                        Text(summary.startedAt, style: .time)
                                    }.foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button(expandedPlan == summary.planID ? L10n.text("收起", "Collapse") : L10n.text("详情", "Details")) {
                                    if expandedPlan == summary.planID {
                                        expandedPlan = nil
                                        store.closeOperationReportDetail()
                                    } else {
                                        expandedPlan = summary.planID
                                        store.loadOperationReportDetail(summary.planID)
                                    }
                                }.appButtonChrome(.tertiary)
                            }.font(AppDesignTokens.Typography.metadata)
                            if summary.needsVerification {
                                Label(L10n.text("部分结果需要核实", "Some results need verification"), systemImage: "exclamationmark.triangle")
                                    .font(AppDesignTokens.Typography.metadata).foregroundStyle(AppDesignTokens.Palette.warning)
                            }
                            if expandedPlan == summary.planID {
                                let offersRestore = OperationRecordPresentation.offersRestore(rulesVersion: summary.rulesVersion)
                                if offersRestore {
                                    Text(L10n.text("原操作移走：", "Originally moved: ")
                                         + ByteFormat.string(summary.summary.movedToRecoverableLocationBytes))
                                        .font(AppDesignTokens.Typography.metadata)
                                }
                                if let report = store.operationReportDetail, report.planID == summary.planID {
                                    if let resumeUninstall, AppUninstallService.canInspectResiduals(report) {
                                        Button(L10n.text("检查残留文件", "Check Leftover Files")) {
                                            resumeUninstall(report); dismiss()
                                        }.disabled(store.isRestoringRecordedOperation || store.isUninstallingApp)
                                    }
                                    if offersRestore {
                                        Button(L10n.text("恢复", "Restore")) { selectedRestore = report }
                                            .disabled(store.isRestoringRecordedOperation
                                                || nothingLeftToRestore(in: report))
                                    }
                            ForEach(report.items) { item in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(fileURLWithPath: item.sourcePath).lastPathComponent)
                                        Text(item.sourcePath).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Spacer(minLength: 12)
                                    Text(itemLabel(item, report: report)).foregroundStyle(.secondary)
                                }.font(AppDesignTokens.Typography.metadata)
                            }
                            ForEach(Array((report.recoveryAttempts ?? []).enumerated()), id: \.offset) { _, attempt in
                                HStack {
                                    Text(L10n.text("恢复记录", "Restore attempt"))
                                    Text(attempt.completedAt, style: .time)
                                    Spacer()
                                    Text(L10n.text("已恢复 \(attempt.restoredCount) 项", "\(attempt.restoredCount) restored"))
                                }.font(AppDesignTokens.Typography.metadata)
                                if attempt.persistenceFailure != nil {
                                    Text(L10n.text("恢复日志未完全写入，需要核实。", "Restore log is incomplete; verification is required."))
                                        .font(AppDesignTokens.Typography.metadata).foregroundStyle(AppDesignTokens.Palette.warning)
                                }
                            }
                            if report.persistenceFailure != nil {
                                Text(L10n.text("回执写入曾失败，未确认的项目不会自动重试。",
                                               "Receipt writing failed. Unconfirmed items are never retried automatically."))
                                    .font(AppDesignTokens.Typography.metadata).foregroundStyle(AppDesignTokens.Palette.warning)
                            }
                                } else {
                                    ProgressView(L10n.text("正在读取回执", "Loading receipt"))
                                }
                            }
                        }
                        .padding(AppDesignTokens.Layout.compactPadding)
                        .glassPanel(cornerRadius: AppDesignTokens.Layout.rowRadius,
                                    tint: AppDesignTokens.Palette.information, prominence: .quiet)
                    }
                    if store.isLoadingOperationReports { ProgressView() }
                    if store.hasMoreOperationReports {
                        Button(L10n.text("加载更多", "Load more")) { store.refreshOperationReports(loadMore: true) }
                            .disabled(store.isLoadingOperationReports)
                    }
                }
            }
        }
        .padding(AppDesignTokens.Layout.pagePadding)
        .frame(minWidth: 400, idealWidth: 760, minHeight: 420, idealHeight: 600)
        .background(AppAppearanceColors.panel)
        .onAppear {
            if recoveryBaseline == .notCaptured {
                recoveryBaseline = .captured(store.operationRecoveryResult)
            }
        }
        .task { store.refreshOperationReports(reconcile: true) }
        .task(id: store.operationReportDetail?.planID) {
            guard let report = store.operationReportDetail else { return }
            let departed = await Task.detached(priority: .utility) {
                CleanupReceiptAvailability.departedOriginalPaths(in: report)
            }.value
            departedReceiptPaths[report.planID] = departed
        }
        .onDisappear { store.closeOperationReportDetail() }
        .confirmationDialog(L10n.text("恢复所选操作？", "Restore this operation?"), isPresented: Binding(
            get: { selectedRestore != nil }, set: { if !$0 { selectedRestore = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.text("恢复已核实的文件", "Restore verified files")) {
                if let selectedRestore { store.restoreRecordedOperation(selectedRestore) }
                selectedRestore = nil
            }
        } message: {
            Text(L10n.text("仅恢复身份核实的回执。原位置已存在文件时跳过，不覆盖。",
                           "Only verified receipts can be restored. Existing destinations are skipped, never overwritten."))
        }
    }

    /// P2-6: no receipt is left that can still be restored. D46: nor one
    /// in another volume's Trash, which is put back in Finder.
    private func nothingLeftToRestore(in report: CleanReport) -> Bool {
        let inOtherTrash = report.restorableReceipts
            .filter { !OperationRecordPresentation.isInUserTrash($0, userTrashPath: userTrashPath) }
            .map(\.originalPath)
        let departed = (departedReceiptPaths[report.planID] ?? []).union(inOtherTrash)
        return report.restorableReceipts.allSatisfy { departed.contains($0.originalPath) }
    }

    private var userTrashPath: String { PathSafety.lexicalPath(CleanupService.userTrashURL().path) }

    private func itemLabel(_ item: CleanReportItem, report: CleanReport) -> String {
        if let latest = (report.recoveryAttempts ?? []).flatMap(\.items).last(where: { $0.originalPath == item.sourcePath }) {
            return recoveryLabel(latest.outcome)
        }
        return OperationRecordPresentation.isTemporaryResource(item.ruleID)
            ? OperationRecordPresentation.temporaryItemLabel(item.outcome)
            : outcomeLabel(item.outcome, departed: departedReceiptPaths[report.planID] ?? [])
    }

    private func outcomeLabel(_ outcome: CleanItemOutcome, departed: Set<String>) -> String {
        switch outcome {
        case .moved(let receipt):
            if departed.contains(receipt.originalPath) {
                return receipt.disposition == .trash
                    ? L10n.text("已不在废纸篓 · 无法在此恢复", "No longer in Trash · cannot be restored here")
                    : L10n.text("已不在隔离区 · 无法在此恢复", "No longer in quarantine · cannot be restored here")
            }
            if receipt.isRestorable, !OperationRecordPresentation.isInUserTrash(receipt, userTrashPath: userTrashPath) {
                return OperationRecordPresentation.otherTrashLabel
            }
            return receipt.isRestorable ? L10n.text("已移走 · 可恢复", "Moved · recoverable") :
                L10n.text("已移走 · 身份待核实", "Moved · identity unverified")
        case .notProcessed: return L10n.text("未执行", "Not executed")
        case .deleted: return L10n.text("已从废纸篓永久删除 · 不可恢复", "Permanently deleted from Trash · not recoverable")
        // Localized reasons only; internal enum names never appear as a status.
        case .skipped(let reason): return CleanSkipReasonPresentation.recordLabel(reason)
        case .failed(let failure):
            if failure.code == .moveOutcomeUnknown { return L10n.text("结果待核实", "Outcome unverified") }
            if failure.code == .deletionOutcomeUnknown {
                return L10n.text("永久删除未完成，部分内容可能已删除", "Permanent deletion did not finish; some content may be gone")
            }
            // A refusal recorded before the move (identity changed, app running,
            // lease lost…) gets its own reason instead of one generic text.
            if let reason = UninstallFailureReason(failure), let label = UninstallPresentation.recordLabel(reason) {
                return label
            }
            return L10n.text("失败：", "Failed: ") + CleanFailurePresentation.title(failure)
        }
    }

    private func recoveryLabel(_ outcome: CleanupRecoveryItemOutcome) -> String {
        switch outcome {
        case .notProcessed: L10n.text("恢复未执行", "Restore not executed")
        case .outcomeUnknown: L10n.text("恢复结果待核实", "Restore outcome unverified")
        case .restored: L10n.text("已恢复", "Restored")
        case .conflict: L10n.text("同名冲突，未覆盖", "Name conflict; not overwritten")
        case .missing: L10n.text("恢复来源不存在", "Recovery source missing")
        case .identityChanged: L10n.text("身份已变化", "Identity changed")
        case .unsafePath: L10n.text("路径检查未通过", "Path check failed")
        case .failed: L10n.text("恢复失败", "Restore failed")
        }
    }
}
