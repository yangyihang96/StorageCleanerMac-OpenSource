import SwiftUI

struct AppUpdateRecoveryPanel: View {
    @Environment(\.moduleTheme) private var theme
    @ObservedObject var store: ScanStore
    @State private var status = ApplicationUpdateRecoveryStatus()
    @State private var isWorking = false
    @State private var message: String?
    @State private var isConfirmingDamagedQueue = false
    @State private var recoveryApplicationID: String?
    @State private var isConfirmingRecovery = false

    private var recoveryExplanation: String {
        L10n.text("会检查是否还有安装在进行，并根据结果完成、恢复先前更新留下的备份或解除锁定", "Checks whether installation is still in progress and, depending on the result, completes the update, restores a backup left by an earlier update, or releases the lock")
    }

    private struct RefreshKey: Hashable {
        let queueUpdatedAt: Date?
        let phase: AppUpdatePresentationPhase
        let scanWarnings: [String]
    }

    var body: some View {
        Group {
            if !status.isEmpty || message != nil {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.compact) {
                    if let issue = status.queueIssue {
                        Text(issue.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .textSelection(.enabled)
                        AppButton(title: L10n.text("我已确认没有正在进行的更新", "I confirm no update is in progress"),
                            systemImage: "checkmark.shield", kind: .secondary, isDisabled: isWorking,
                            action: { isConfirmingDamagedQueue = true })
                    }
                    ForEach(status.tasks) { task in
                        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.compact) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name(for: task)).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.primaryText)
                                Text(task.detail ?? L10n.text("上次安装待核验，仍保持隔离", "The previous installation needs verification and remains quarantined"))
                                    .font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                                if task.providerIdentifier == .homebrew && task.recoveryEvidence?.homebrewMetadata == nil {
                                    Text(L10n.text("旧记录缺少包范围；Homebrew 的其他应用和工具也暂时隔离。核验并恢复后可重新授权更新。", "This legacy record lacks package scope. Other Homebrew applications and tools are quarantined too. Verify and recover it before authorizing another update."))
                                        .font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                                }
                            }
                            Spacer(minLength: AppDesignTokens.Spacing.compact)
                            AppButton(title: L10n.text("核验并恢复", "Verify and Recover"), systemImage: "checkmark.shield",
                                kind: .secondary, isDisabled: isWorking, action: {
                                    recoveryApplicationID = task.applicationID
                                    isConfirmingRecovery = true
                                })
                        }
                    }
                    if !status.tasks.isEmpty {
                        Text(recoveryExplanation).font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                    }
                    if let message { Text(message).font(.system(size: 11)).foregroundStyle(theme.secondaryText) }
                }
                .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
                .padding(.vertical, AppDesignTokens.Spacing.compact)
            }
        }
        .task(id: RefreshKey(queueUpdatedAt: store.appUpdateQueueSnapshot?.updatedAt,
            phase: store.appUpdatePresentationState.phase, scanWarnings: store.appUpdateScanWarnings)) {
                status = await store.appUpdateRecoveryStatus()
            }
        .confirmationDialog(L10n.text("确认没有正在进行的更新", "Confirm no update is in progress"), isPresented: $isConfirmingDamagedQueue,
            titleVisibility: .visible) {
            Button(L10n.text("我已确认没有正在进行的更新", "I confirm no update is in progress")) { acknowledge() }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("原始归档文件会保留。确认后解除未知旧记录对 Homebrew 的隔离；仍可核验的未决项目继续保留。", "The original archive will be retained. Confirmation releases Homebrew quarantine from the unreadable record; any valid unresolved tasks remain preserved."))
        }
        .confirmationDialog(L10n.text("核验并恢复", "Verify and Recover"), isPresented: $isConfirmingRecovery,
            titleVisibility: .visible) {
            Button(L10n.text("确认核验并恢复", "Confirm Verify and Recover")) {
                if let id = recoveryApplicationID { verify(id) }
                recoveryApplicationID = nil
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) { recoveryApplicationID = nil }
        } message: {
            Text(recoveryExplanation + L10n.text("。确认后可能恢复应用，并清理已核验的暂存或备份。", ". Confirmation may restore an application and clean up verified staging or backups."))
        }
    }

    private func name(for task: ApplicationUpdateTask) -> String {
        store.appUpdates.first(where: { $0.id == task.applicationID })?.displayName
            ?? (task.originalIdentity.bundleIdentifier.isEmpty ? task.applicationID : task.originalIdentity.bundleIdentifier)
    }

    private func verify(_ id: String) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do { try await store.verifyAndReleaseAppUpdate(applicationID: id); message = L10n.text("核验并恢复已结束，请查看项目状态", "Verify and Recover finished; review the item status") }
            catch { message = AppUpdateErrorRedaction.text(error.localizedDescription) }
            status = await store.appUpdateRecoveryStatus()
        }
    }

    private func acknowledge() {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do { try await store.acknowledgeDamagedAppUpdateQueue(); message = L10n.text("已确认并解除未知记录隔离；原始归档仍保留", "Unknown-record quarantine released after confirmation; the original archive is retained") }
            catch { message = AppUpdateErrorRedaction.text(error.localizedDescription) }
            status = await store.appUpdateRecoveryStatus()
        }
    }
}
