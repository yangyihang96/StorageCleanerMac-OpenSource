import SwiftUI

struct ReversibleOperationsView: View {
    @ObservedObject var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRestore: CleanReport?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            HStack {
                Text(L10n.text("可恢复操作", "Recoverable Operations"))
                    .font(AppDesignTokens.Typography.sectionTitle)
                Spacer()
                Button(L10n.text("刷新", "Refresh")) { store.refreshOperationReports() }
                Button(L10n.text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.text("已移入废纸篓不等于已释放空间。恢复会重新检查文件身份，遇到同名文件时保留双方。",
                           "Moving to Trash does not free space. Restore rechecks identity and preserves both files when a name conflicts."))
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            if let warning = store.operationReportWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(AppDesignTokens.Palette.warning)
            }
            if let recovery = store.operationRecoveryResult {
                Text(L10n.text("已恢复 \(recovery.restoredCount) 项；以下保留每项结果。",
                               "Restored \(recovery.restoredCount) item(s); individual results are retained below."))
                ForEach(recovery.items) { item in
                    HStack {
                        Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                        Spacer()
                        Text(recoveryLabel(item.outcome))
                    }.font(AppDesignTokens.Typography.metadata)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                    if store.operationReports.isEmpty {
                        Text(L10n.text("暂无操作回执", "No operation receipts"))
                    }
                    ForEach(store.operationReports) { report in
                        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                            HStack {
                                Text(report.startedAt, style: .date)
                                Text(report.startedAt, style: .time)
                                Spacer()
                                Button(L10n.text("恢复", "Restore")) { selectedRestore = report }
                                    .disabled(report.restorableReceipts.isEmpty || store.isRestoringRecordedOperation)
                            }.font(AppDesignTokens.Typography.compactLabelEmphasis)
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
                            Text(L10n.text("已移至可恢复位置：", "Moved to recoverable location: ")
                                 + ByteFormat.string(report.summary.movedToRecoverableLocationBytes))
                                .font(AppDesignTokens.Typography.metadata)
                            if report.persistenceFailure != nil {
                                Text(L10n.text("回执写入曾失败，未确认的项目不会自动重试。",
                                               "Receipt writing failed. Unconfirmed items are never retried automatically."))
                                    .font(AppDesignTokens.Typography.metadata).foregroundStyle(AppDesignTokens.Palette.warning)
                            }
                        }
                        .padding(AppDesignTokens.Layout.compactPadding)
                        .glassPanel(cornerRadius: AppDesignTokens.Layout.rowRadius,
                                    tint: AppDesignTokens.Palette.information, prominence: .quiet)
                    }
                }
            }
        }
        .padding(AppDesignTokens.Layout.pagePadding)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 420, idealHeight: 600)
        .task { store.refreshOperationReports() }
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

    private func stagingLabel(_ outcome: CleanItemOutcome) -> String {
        if case .skipped(.itemMissing) = outcome {
            return L10n.text("临时资源已清理", "Temporary resources removed")
        }
        return L10n.text("临时资源待清理／待核实", "Temporary resources pending cleanup or verification")
    }

    private func itemLabel(_ item: CleanReportItem, report: CleanReport) -> String {
        if let latest = (report.recoveryAttempts ?? []).flatMap(\.items).last(where: { $0.originalPath == item.sourcePath }) {
            return recoveryLabel(latest.outcome)
        }
        return ["migration.staging.v1", "benchmark.fixture.v1"].contains(item.ruleID)
            ? stagingLabel(item.outcome) : outcomeLabel(item.outcome)
    }

    private func outcomeLabel(_ outcome: CleanItemOutcome) -> String {
        switch outcome {
        case .moved(let receipt):
            return receipt.isRestorable ? L10n.text("已移走 · 可恢复", "Moved · recoverable") :
                L10n.text("已移走 · 身份待核实", "Moved · identity unverified")
        case .notProcessed: return L10n.text("未执行", "Not executed")
        case .skipped(let reason): return L10n.text("已跳过：", "Skipped: ") + reason.rawValue
        case .failed(let failure):
            if failure.code == .moveOutcomeUnknown { return L10n.text("结果待核实", "Outcome unverified") }
            return L10n.text("失败：", "Failed: ") + failure.code.rawValue
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
