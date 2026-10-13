import SwiftUI

/// What "Recent Deletions" says about one recovery backup. The texts name
/// the browser, the profile and counts only; a backup's metadata holds no
/// address or title.
enum BrowserPrivacyRecoveryText {
    static func browserName(for entry: BrowserPrivacyRecoveryEntry) -> String {
        entry.summary?.browserDisplayName
            ?? BrowserPrivacyProviderRegistry().provider(id: entry.browserID)?.descriptor.displayName
            ?? entry.browserID
    }

    /// "Browser · profile", or the browser alone for a backup without a summary.
    static func title(for entry: BrowserPrivacyRecoveryEntry) -> String {
        guard let profile = entry.summary?.profileDisplayName, !profile.isEmpty else {
            return browserName(for: entry)
        }
        return "\(browserName(for: entry)) · \(profile)"
    }

    static func time(for entry: BrowserPrivacyRecoveryEntry) -> String {
        BrowserPrivacyDateFormatter.string(entry.createdAt)
    }

    /// What the deletion behind this backup did. Unknown stays unknown.
    static func summary(for entry: BrowserPrivacyRecoveryEntry) -> String {
        guard let summary = entry.summary else {
            return L10n.text(
                "未记录删除了多少条（可能由旧版本创建，或处理时中断）",
                "The number of deleted records was not recorded (created by an earlier version, or processing was interrupted)"
            )
        }
        let counts: String = {
            if let contract = entry.dataContract {
                guard let count = summary.visitCount else {
                    return contract.type.title + " · " + L10n.text("条数未确认", "Record count unconfirmed")
                }
                return contract.type.title + " · " + L10n.text("\(count) 条记录", "\(count) records")
            }
            guard let visits = summary.visitCount else {
                return L10n.text("所选访问", "the selected visits")
            }
            guard let pages = summary.pageCount else {
                return BrowserPrivacyCountText.visits(visits)
            }
            return L10n.text(
                "\(BrowserPrivacyCountText.visits(visits))（\(BrowserPrivacyCountText.pages(pages))）",
                "\(BrowserPrivacyCountText.visits(visits)) (\(BrowserPrivacyCountText.pages(pages)))"
            )
        }()
        switch summary.outcome {
        case .deleted:
            return L10n.text("删除了 \(counts)", "Deleted \(counts)")
        case .unverified:
            return L10n.text(
                "删除了 \(counts)，但最后一次复核未通过",
                "Deleted \(counts), but the final check did not pass"
            )
        case .restoredAfterFailure:
            return L10n.text(
                "删除未完成，当时已用这份备份自动恢复",
                "The deletion did not complete; this backup was restored automatically at the time"
            )
        case .restoreUnconfirmed:
            return L10n.text(
                "删除结果未能确认，请在这份备份到期前重新扫描核对，需要时用它恢复",
                "The result of the deletion could not be confirmed; scan again before this backup expires and restore it if needed"
            )
        case .savedBeforeRestore:
            return L10n.text(
                "恢复备份之前自动保存的状态，用它可以撤销那次恢复",
                "The state saved automatically before a restore; use it to undo that restore"
            )
        case .unexpectedError:
            return L10n.text(
                "处理时出现未预期的错误，不知道 \(counts) 是否已删除；请在这份备份到期前重新扫描核对",
                "An unexpected error stopped processing; it is not known whether \(counts) were deleted. Scan again to check before this backup expires"
            )
        }
    }

    /// When the backup is removed automatically (D26).
    static func expiryNote(for entry: BrowserPrivacyRecoveryEntry) -> String {
        let time = BrowserPrivacyDateFormatter.string(entry.expiresAt)
        return L10n.text("\(time) 自动删除", "Removed automatically on \(time)")
    }

    static func restoredNote(for entry: BrowserPrivacyRecoveryEntry) -> String? {
        entry.restoredAt.map {
            let time = BrowserPrivacyDateFormatter.string($0)
            return L10n.text("已于 \(time) 恢复过", "Restored on \(time)")
        }
    }

    /// Shown before a restore; it must say what is lost and what comes back.
    static func restoreWarning(for entry: BrowserPrivacyRecoveryEntry) -> String {
        let browser = browserName(for: entry)
        let target = title(for: entry)
        let time = time(for: entry)
            if entry.rowBackup, let contract = entry.dataContract {
            return L10n.text("仅补回这次删除的 \(contract.type.title) 行；保留之后新增或修改的记录，冲突行跳过。不会恢复其他表。请先正常退出 \(browser)。同步可能再次回填记录，Cookie 分区与过期规则可能使登录无法恢复。", "Only rows deleted by this operation are added back. Later additions and changes are kept; conflicting rows are skipped. Other tables are not restored. Quit \(browser) normally first. Sync may refill records; cookie partitioning and expiry may prevent login restoration.")
        }
        if let contract = entry.dataContract {
            return L10n.text("将恢复 \(target) 的 \(contract.type.title) 整个数据库至 \(time)。之后新增的数据会丢失，之后删除的数据会重现；同库其他类型的数据也会一并恢复。下载文件不受影响。恢复前会保存当前状态，可撤销恢复；请先正常退出 \(browser)。", "Restore the entire \(contract.type.title) database of \(target) to \(time). Later additions will be lost and later deletions will reappear; other data types in the same database will also be restored. Downloaded files are unaffected. The current state is saved first so the restore can be undone. Quit \(browser) normally first.")
        }
        if entry.summary?.outcome == .savedBeforeRestore {
            return L10n.text(
                "将把 \(target) 的历史数据库恢复到 \(time) 那次恢复之前的状态，也就是撤销那次恢复。会丢弃之后新增的浏览记录和下载列表，之后删除的记录也会重新出现。恢复前会先自动备份当前状态。请先退出 \(browser)；书签、密码和 Cookie 不受影响。",
                "This puts the history database of \(target) back to the state before the restore at \(time), which undoes that restore. Browsing history and download-list entries added since then will be lost, and records deleted since then will reappear. The current state is backed up first. Quit \(browser) first; bookmarks, passwords and cookies are not affected."
            )
        }
        return L10n.text(
            "将把 \(target) 的历史数据库恢复到 \(time) 那次删除之前。会丢弃这次删除之后新增的浏览记录和下载列表，之后删除的记录也会重新出现。恢复前会先自动备份当前状态，可在“最近的删除”里撤销这次恢复。请先退出 \(browser)；书签、密码和 Cookie 不受影响。",
            "This puts the history database of \(target) back to the state before the deletion at \(time). Browsing history and download-list entries added after that deletion will be lost. Records deleted after it will reappear. The current state is backed up first, so the restore can be undone in Recent Deletions. Quit \(browser) first; bookmarks, passwords and cookies are not affected."
        )
    }

    /// What a deletion leaves behind, shown in the confirmation and the report.
    static var retentionNotice: String {
        let days = BrowserPrivacyBackupRetention.days
        return L10n.text(
            "被删除的页面仍保存在删除前的备份里，\(days) 天后自动删除；确认无误后可在“最近的删除”里立即删除备份。",
            "The backup taken before deletion still contains the deleted pages; it is removed automatically after \(days) days, and you can delete it right away in Recent Deletions once you have checked the result."
        )
    }

    /// Backups of the same browser profile taken after `entry`, oldest first.
    static func laterBackups(
        than entry: BrowserPrivacyRecoveryEntry,
        in entries: [BrowserPrivacyRecoveryEntry]
    ) -> [BrowserPrivacyRecoveryEntry] {
        entries
            .filter {
                $0.id != entry.id
                    && $0.browserID == entry.browserID
                    && $0.profileFingerprint == entry.profileFingerprint
                    && ($0.dataContract?.relativePath ?? "History") == (entry.dataContract?.relativePath ?? "History")
                    && $0.createdAt > entry.createdAt
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The extra warning before restoring a backup that is not the newest
    /// one of its profile: everything done after it is undone as well.
    static func olderBackupWarning(
        for entry: BrowserPrivacyRecoveryEntry,
        laterBackups: [BrowserPrivacyRecoveryEntry]
    ) -> String? {
        guard let latest = laterBackups.last else { return nil }
        let count = laterBackups.count
        let latestTime = BrowserPrivacyDateFormatter.string(latest.createdAt)
        if entry.rowBackup {
            return L10n.text("这份备份之后还有 \(count) 份同库备份（最近一份在 \(latestTime)）。补回行可能带回后续删除的记录；不会覆盖较新的冲突行，也不会撤销其他表。", "There are \(count) later backups of the same database (latest: \(latestTime)). Adding rows back may reintroduce records deleted later; newer conflicting rows and other tables are kept.")
        }
        return L10n.text(
            "这不是这个配置文件最近的一份备份：在它之后还有 \(count) 份（最近一份在 \(latestTime)）。恢复它会把之后的删除和恢复都一起撤销，之后删除的记录都会重新出现。",
            "This is not the newest backup of this profile: \(count) more were taken after it (the latest at \(latestTime)). Restoring it undoes every later deletion and restore as well, and every record deleted after it will reappear."
        )
    }

    /// Shown before a backup is removed. Nil `createdAt` means the deletion
    /// that was just reported.
    static func removalWarning(createdAt: Date?) -> String {
        let deletion = createdAt.map {
            L10n.text(
                "\(BrowserPrivacyDateFormatter.string($0)) 那次删除",
                "the deletion at \(BrowserPrivacyDateFormatter.string($0))"
            )
        } ?? L10n.text("这次删除", "this deletion")
        return L10n.text(
            "删除这份备份后，\(deletion)将无法再撤销。备份是本应用保存的整个历史数据库副本，会直接删除，不会移到废纸篓（放进废纸篓等于继续保留被删除的页面）。",
            "After this backup is removed, \(deletion) can no longer be undone. The backup is this app's own copy of the whole history database, so it is deleted directly and not moved to the Trash, where the deleted pages would live on."
        )
    }

    static func removalWarning(for entry: BrowserPrivacyRecoveryEntry) -> String {
        if entry.rowBackup {
            return L10n.text("删除此备份后，所删行将无法从此操作记录补回。备份只含这次处理的表内行，将直接删除，不移至废纸篓。", "After this backup is removed, its deleted rows cannot be added back from this operation record. It contains only rows from the processed table and is deleted directly, without moving to Trash.")
        }
        guard entry.summary?.outcome == .savedBeforeRestore else {
            return removalWarning(createdAt: entry.createdAt)
        }
        let time = time(for: entry)
        return L10n.text(
            "删除这份备份后，\(time) 那次恢复将无法再撤销。备份是本应用保存的整个历史数据库副本，会直接删除，不会移到废纸篓。",
            "After this backup is removed, the restore at \(time) can no longer be undone. The backup is this app's own copy of the whole history database, so it is deleted directly and not moved to the Trash."
        )
    }

    /// Shown under a row whose backup could not be deleted.
    static var removalFailure: String {
        L10n.text(
            "没能删除这份备份，请稍后再试。",
            "This backup could not be deleted. Try again later."
        )
    }

    static var pendingRemoval: String {
        L10n.text(
            "部分备份尚未清除，仍可能含有被删除的页面。这些副本已不能恢复，请重试删除。",
            "Some backup data still needs to be removed and may contain the deleted pages. These copies can no longer be restored. Retry deletion."
        )
    }
}

/// The "Recent Deletions" popover: one row per recovery backup with a
/// restore and a remove action. Both ask again inside the popover and state
/// what is lost.
struct BrowserPrivacyRecentDeletionsView: View {
    private enum PendingAction: Equatable {
        case restore(UUID)
        /// The second question before restoring a backup that is not the
        /// newest of its profile.
        case restoreOlder(UUID)
        case remove(UUID)
    }

    @ObservedObject var recoveryStore: BrowserPrivacyRecoveryStore
    /// True while the page is scanning or deleting.
    let isBusy: Bool
    let onRescan: () -> Void

    @State private var pendingAction: PendingAction?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Text(L10n.text("最近的删除", "Recent Deletions"))
                .font(AppTypography.sectionTitle)
            Text(L10n.text(
                "删除前备份：浏览记录为整库备份（含已删页面），Cookie 与 Chromium 表单自动填充只备份所删行，其他数据类型备份所在数据库；仅本地保存、不上传且不进入时间机器；\(BrowserPrivacyBackupRetention.days) 天后删除，浏览记录与其他数据各自最多 \(BrowserPrivacyBackupRetention.maximumCount) 份（已恢复和待核实的不计）；可提前删除",
                "Backup before deletion: history as a full database backup (including deleted pages); cookies and Chromium form autofill back up only the deleted rows, other data types back up their database; local only, no upload or Time Machine; removed after \(BrowserPrivacyBackupRetention.days) days, up to \(BrowserPrivacyBackupRetention.maximumCount) copies each for history and for other data (restored and unconfirmed excluded); may be deleted earlier"
            ))
            .font(AppTypography.caption)
            .foregroundStyle(AppDesignTokens.Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Cleanup failures survive the removal of a restorable row.
            if !recoveryStore.unlistedRemovalIDs.isEmpty {
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    Label(
                        recoveryStore.pendingRemovalIDs.isEmpty
                            ? BrowserPrivacyRecoveryText.removalFailure
                            : BrowserPrivacyRecoveryText.pendingRemoval,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(AppTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("重试删除", "Retry Deletion")) {
                        Task { await recoveryStore.retryPendingRemovals() }
                    }
                    .appButtonChrome(.destructive)
                    .disabled(isBusy || recoveryStore.isWorking)
                }
            }

            if recoveryStore.entries.isEmpty {
                Text(L10n.text("没有可恢复的备份。", "There are no backups to restore."))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                        ForEach(recoveryStore.entries) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            if let result = recoveryStore.lastResult {
                HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
                    Group {
                        if result.succeeded {
                            Text(result.detail)
                        } else {
                            Label(result.detail, systemImage: "exclamationmark.triangle.fill")
                        }
                    }
                    .font(AppTypography.caption)
                    .foregroundStyle(result.succeeded
                        ? AppDesignTokens.Palette.success
                        : AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if result.succeeded {
                        Button(L10n.text("重新扫描", "Scan Again")) {
                            recoveryStore.clearResult()
                            onRescan()
                        }
                        .appButtonChrome(.secondary)
                        .disabled(isBusy)
                    }
                }
            }
        }
        .padding(AppDesignTokens.Spacing.medium)
        .frame(width: 460)
        .task { await recoveryStore.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("最近的删除", "Recent Deletions"))
    }

    @ViewBuilder
    private func row(_ entry: BrowserPrivacyRecoveryEntry) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
            HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(BrowserPrivacyRecoveryText.title(for: entry))
                        .font(AppTypography.metadata.weight(.semibold))
                    Text("\(BrowserPrivacyRecoveryText.time(for: entry)) · \(BrowserPrivacyRecoveryText.summary(for: entry))")
                        .font(AppTypography.caption.monospacedDigit())
                        .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(BrowserPrivacyRecoveryText.expiryNote(for: entry))
                        .font(AppTypography.caption.monospacedDigit())
                        .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                    if let note = BrowserPrivacyRecoveryText.restoredNote(for: entry) {
                        Text(note)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                    }
                }
                Spacer(minLength: AppDesignTokens.Spacing.small)
                Button(L10n.text("恢复…", "Restore…")) {
                    recoveryStore.clearResult()
                    pendingAction = .restore(entry.id)
                }
                .appButtonChrome(.secondary)
                .disabled(isBusy || recoveryStore.isWorking || !entry.canRestore)
                .help(entry.canRestore ? L10n.text("恢复这份备份", "Restore This Backup") : L10n.text("此格式暂不支持安全恢复", "This format has no safe restore adapter"))
                Button {
                    recoveryStore.clearResult()
                    pendingAction = .remove(entry.id)
                } label: {
                    Image(systemName: "trash")
                }
                .appButtonChrome(.icon)
                .disabled(isBusy || recoveryStore.isWorking)
                .help(L10n.text("删除这份备份", "Delete This Backup"))
                .accessibilityLabel(L10n.text("删除这份备份", "Delete This Backup"))
            }

            if recoveryStore.failedRemovalID == entry.id {
                Label(BrowserPrivacyRecoveryText.removalFailure, systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if pendingAction == .restore(entry.id) {
                let laterBackups = BrowserPrivacyRecoveryText.laterBackups(
                    than: entry,
                    in: recoveryStore.entries
                )
                if laterBackups.isEmpty {
                    confirmation(
                        message: BrowserPrivacyRecoveryText.restoreWarning(for: entry),
                        confirmTitle: restoreTitle(for: entry)
                    ) {
                        await recoveryStore.restore(entry)
                    }
                } else {
                    confirmation(
                        message: BrowserPrivacyRecoveryText.restoreWarning(for: entry),
                        confirmTitle: L10n.text("继续…", "Continue…"),
                        isDestructive: false
                    ) {
                        pendingAction = .restoreOlder(entry.id)
                    }
                }
            } else if pendingAction == .restoreOlder(entry.id),
                      let warning = BrowserPrivacyRecoveryText.olderBackupWarning(
                          for: entry,
                          laterBackups: BrowserPrivacyRecoveryText.laterBackups(
                              than: entry,
                              in: recoveryStore.entries
                          )
                      ) {
                confirmation(
                    message: warning,
                    confirmTitle: L10n.text("仍要恢复这份较早的备份", "Restore This Older Backup Anyway")
                ) {
                    await recoveryStore.restore(entry)
                }
            } else if pendingAction == .remove(entry.id) {
                confirmation(
                    message: BrowserPrivacyRecoveryText.removalWarning(for: entry),
                    confirmTitle: L10n.text("删除备份", "Delete Backup")
                ) {
                    await recoveryStore.remove(entry)
                }
            }
        }
    }

    private func restoreTitle(for entry: BrowserPrivacyRecoveryEntry) -> String {
        entry.summary?.outcome == .savedBeforeRestore
            ? L10n.text("撤销那次恢复", "Undo That Restore")
            : L10n.text("恢复到删除之前", "Restore to Before the Deletion")
    }

    private func confirmation(
        message: String,
        confirmTitle: String,
        isDestructive: Bool = true,
        action: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(AppTypography.caption)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Spacer(minLength: 0)
                Button(L10n.text("取消", "Cancel")) {
                    pendingAction = nil
                }
                .appButtonChrome(.secondary)
                Button(confirmTitle) {
                    pendingAction = nil
                    Task { await action() }
                }
                .appButtonChrome(isDestructive ? .destructive : .secondary)
                .disabled(isBusy || recoveryStore.isWorking)
            }
        }
        .padding(AppDesignTokens.Spacing.small)
        .background(
            AppDesignTokens.Palette.warning.opacity(0.10),
            in: RoundedRectangle(cornerRadius: AppDesignTokens.Radius.glassControl, style: .continuous)
        )
    }
}
