import Foundation

/// Why the records of one profile were, or were not, deleted. Callers and
/// tests use the stable case; the interface shows the localized detail.
enum BrowserPrivacyProcessingReason: String, CaseIterable, Equatable, Sendable {
    case deletedAndVerified
    case cancelled
    case providerUnavailable
    /// These records cannot be deleted directly; see
    /// `BrowserPrivacyDirectDeletionBlocker` for the specific cause.
    case manualOnly
    case browserProcessUnknown
    case selectionNotTrusted
    case browserRunning
    case databaseBusy
    case permissionDenied
    case schemaUnsupported
    case databaseDamaged
    case databaseTooLarge
    case timedOut
    case databaseUnavailable
    case databaseChanged
    case recordMissing
    case recordChanged
    case verificationFailed
    case committedButUnverified
    case syncedRecords
    case inconsistentData
    case pendingWrites
    case restoredFromBackup
    case restoreUnconfirmed
    /// The backup that must exist before any write could not be made.
    case backupFailed
    /// The configured backup location is a link, not the app's own directory.
    case backupLocationUnsafe
    /// The backup folder could not be excluded from Time Machine.
    case backupExclusionFailed
    /// An error nobody planned for, after the backup existed: whether the
    /// database changed is not known, so the backup is kept.
    case unexpectedError
    /// An error nobody planned for, before anything was written.
    case unexpectedErrorBeforeChanges

    func detail(browserName: String) -> String {
        let texts = localizedTexts(browserName: browserName)
        return L10n.text(texts.chinese, texts.english)
    }

    /// Both languages, so a test can check each without switching the app language.
    func localizedTexts(browserName: String) -> (chinese: String, english: String) {
        switch self {
        case .deletedAndVerified:
            (
                "所选访问记录已删除，并经重新读取确认不再存在。",
                "The selected visits were deleted, and a fresh read confirmed they are gone."
            )
        case .cancelled:
            (
                "处理已取消，这个配置文件没有保留任何改动。",
                "Processing was cancelled; no change to this profile was kept."
            )
        case .providerUnavailable:
            (
                "扫描时使用的浏览器支持已不可用，没有修改数据库。请重新扫描。",
                "The browser support used for the scan is no longer available. Nothing was changed; scan again."
            )
        case .manualOnly:
            (
                "这些记录不能由本应用直接删除，请在 \(browserName) 内删除。",
                "These records cannot be deleted directly by this app. Delete them in \(browserName)."
            )
        case .browserProcessUnknown:
            (
                "无法可靠判断 \(browserName) 是否正在运行，没有修改数据库。",
                "Whether \(browserName) is running cannot be determined reliably, so nothing was changed."
            )
        case .selectionNotTrusted:
            (
                "所选记录不属于同一个经过校验的数据库，没有修改数据库。请重新扫描后再试。",
                "The selected records do not belong to one verified database. Nothing was changed; scan again and retry."
            )
        case .browserRunning:
            (
                "\(browserName) 正在运行。请正常退出 \(browserName) 后重试。",
                "\(browserName) is still running. Quit \(browserName) normally, then try again."
            )
        case .databaseBusy:
            (
                "历史数据库正被占用（\(browserName) 或其他程序仍持有锁），没有提交任何修改。请退出浏览器后重试。",
                "The history database is busy (\(browserName) or another process still holds a lock). Nothing was committed; quit the browser and try again."
            )
        case .permissionDenied:
            (
                "当前权限无法写入这个历史数据库，没有删除任何记录。",
                "The history database is not writable with the current permission. Nothing was deleted."
            )
        case .schemaUnsupported:
            (
                "此版本的数据库结构不受支持，没有修改数据库。请在 \(browserName) 内删除。",
                "This version of the database schema is not supported. Nothing was changed; delete these in \(browserName)."
            )
        case .databaseDamaged:
            (
                "历史数据库已损坏或无法识别，没有删除任何记录。",
                "The history database is corrupt or not recognizable. Nothing was deleted."
            )
        case .databaseTooLarge:
            (
                "历史数据库超过安全处理上限，没有尝试删除。",
                "The history database exceeds the safe processing limit. No deletion was attempted."
            )
        case .timedOut:
            (
                "操作超时，未完成的修改已全部撤销。",
                "The operation timed out and the unfinished change was rolled back."
            )
        case .databaseUnavailable:
            (
                "历史数据库不可用或已被替换，没有删除任何记录。",
                "The history database is unavailable or was replaced. Nothing was deleted."
            )
        case .databaseChanged:
            (
                "扫描之后，数据库文件或它所在的路径发生了变化，没有删除任何记录。请重新扫描。",
                "The database file or its path changed after the scan. Nothing was deleted; scan again."
            )
        case .recordMissing:
            (
                "至少一条所选访问记录已不存在（可能已被浏览器清理）。这个配置文件的修改已全部撤销，请重新扫描。",
                "At least one selected visit no longer exists. The change to this profile was rolled back; scan again."
            )
        case .recordChanged:
            (
                "所选记录在扫描之后被浏览器改动或替换。这个配置文件的修改已全部撤销，请重新扫描。",
                "A selected record was changed or reused after the scan. The change to this profile was rolled back; scan again."
            )
        case .verificationFailed:
            (
                "删除后的检查未能确认数据库处于预期状态。修改已全部撤销，没有删除任何记录。",
                "The check after deletion could not confirm the expected database state. The change was rolled back; nothing was deleted."
            )
        case .committedButUnverified:
            (
                "修改已写入数据库，但最后一次只读复核没有通过。请重新扫描确认结果。",
                "The change was committed, but the final read-only check did not pass. Scan again to confirm the result."
            )
        case .syncedRecords:
            (
                "所选记录已同步到浏览器账号。只在这台 Mac 上删除会留下云端和其他设备上的副本，请在 \(browserName) 内删除。",
                "The selected records are synced with the browser account. Deleting them only on this Mac would leave the copies in the account and on other devices; delete them in \(browserName)."
            )
        case .inconsistentData:
            (
                "数据库里相互关联的记录互相矛盾，无法保证删除后数据一致，没有修改数据库。请在 \(browserName) 内删除。",
                "Related rows in the database contradict each other, so a consistent deletion cannot be guaranteed. Nothing was changed; delete these in \(browserName)."
            )
        case .pendingWrites:
            (
                "数据库有未合并的写入。请打开 \(browserName) 并正常退出后重试，也可以在浏览器内删除。",
                "The database has writes that are not merged yet. Open \(browserName), quit it normally and try again, or delete these in the browser."
            )
        case .restoredFromBackup:
            (
                "数据库未能确认撤销，已用删除前的备份恢复。没有删除任何记录。",
                "The rollback could not be confirmed, so the database was restored from the backup taken before deletion. Nothing was deleted."
            )
        case .restoreUnconfirmed:
            (
                "数据库的撤销和自动恢复都未能确认。请停止处理，在删除前的备份到期前（\(BrowserPrivacyBackupRetention.days) 天内）重新扫描核对，需要时在“最近的删除”里恢复。",
                "Neither the rollback nor the automatic restore could be confirmed. Stop processing, scan again before the backup taken before deletion expires (within \(BrowserPrivacyBackupRetention.days) days) and restore it from Recent Deletions if needed."
            )
        case .backupFailed:
            (
                "删除前没能备份 \(browserName) 的历史数据库，所以没有删除任何记录。",
                "The history database of \(browserName) could not be backed up first, so nothing was deleted."
            )
        case .backupLocationUnsafe:
            (
                "备份位置是一个链接，无法安全保存浏览记录备份。没有创建备份，也没有删除任何记录。",
                "The backup location is a symbolic link and cannot safely hold a history backup. No backup was created and nothing was deleted."
            )
        case .backupExclusionFailed:
            (
                "无法把浏览记录备份文件夹排除在时间机器之外。为避免备份长期保留，没有备份，也没有删除任何记录。",
                "The history backup folder could not be excluded from Time Machine. To avoid keeping the backup longer than intended, no backup was made and nothing was deleted."
            )
        case .unexpectedError:
            (
                "处理时出现未预期的错误，无法确认这个配置文件的数据库是否有改动。请在删除前的备份到期前（\(BrowserPrivacyBackupRetention.days) 天内）重新扫描核对，需要时在“最近的删除”里恢复。",
                "An unexpected error stopped processing, so it is not known whether this profile's database changed. Scan again before the backup taken before deletion expires (within \(BrowserPrivacyBackupRetention.days) days) and restore it from Recent Deletions if needed."
            )
        case .unexpectedErrorBeforeChanges:
            (
                "处理时出现未预期的错误，发生在写入数据库之前，没有删除任何记录。",
                "An unexpected error stopped processing before anything was written, so nothing was deleted."
            )
        }
    }
}

/// Why a restore from Recent Deletions did or did not happen. Restoring
/// has its own wording and never borrows the deletion texts.
enum BrowserPrivacyRestoreReason: String, CaseIterable, Equatable, Sendable {
    case restored
    case browserRunning
    case profileLockUnverifiable
    case pendingWrites
    case databaseBusy
    case permissionDenied
    case backupUnavailable
    case backupInUse
    case backupTooLarge
    case profileUnavailable
    case unsupportedDataFormat
    case databaseChanged
    case timedOut
    case cancelled
    /// The current state could not be backed up first, so the restore,
    /// which could not have been undone, was not started.
    case currentStateNotSaved
    case restoreResultNotSaved
    case failed

    func localizedTexts(browserName: String) -> (chinese: String, english: String) {
        switch self {
        case .unsupportedDataFormat:
            ("此数据备份格式不支持安全恢复，没有写入。旧 Cookie／表单整库备份不能覆盖恢复。", "This data backup format has no safe restore adapter; nothing was written. Legacy whole-database cookie/form backups cannot overwrite current data.")
        case .restored:
            (
                "已把 \(browserName) 的浏览记录恢复到这份备份的状态。恢复前的状态已另存为一份备份，需要时可在“最近的删除”里用它撤销这次恢复。请重新扫描查看。",
                "The browsing history of \(browserName) was restored to the state in this backup. The state before the restore was saved as another backup; use it in Recent Deletions to undo the restore. Scan again to see the result."
            )
        case .profileLockUnverifiable:
            ("无法核实浏览器配置锁，恢复未开始；请检查配置文件权限。", "The profile lock could not be verified; restore did not start. Check profile permissions.")
        case .browserRunning:
            (
                "\(browserName) 正在运行，没有恢复。请正常退出 \(browserName) 后再恢复。",
                "\(browserName) is still running, so nothing was restored. Quit \(browserName) normally, then restore again."
            )
        case .pendingWrites:
            (
                "\(browserName) 的历史数据库有未合并的写入，没有恢复。请打开 \(browserName) 并正常退出后再恢复。",
                "The history database of \(browserName) has writes that are not merged yet, so nothing was restored. Open \(browserName), quit it normally, then restore again."
            )
        case .databaseBusy:
            (
                "\(browserName) 的历史数据库正被占用，恢复没有完成。请退出 \(browserName) 后重试。",
                "The history database of \(browserName) is busy, so the restore did not complete. Quit \(browserName) and try again."
            )
        case .permissionDenied:
            (
                "当前权限无法写入 \(browserName) 的历史数据库，恢复没有完成。",
                "The history database of \(browserName) is not writable with the current permission, so the restore did not complete."
            )
        case .backupUnavailable:
            (
                "这份备份无法读取、已缺失或损坏，无法用来恢复。",
                "This backup is unreadable, missing or damaged and cannot be used to restore."
            )
        case .backupInUse:
            (
                "这份备份正在使用，暂时无法用来恢复。请稍后重试。",
                "This backup is in use and cannot be restored right now. Try again shortly."
            )
        case .backupTooLarge:
            (
                "这份备份超过了安全处理上限，没有用它恢复。",
                "This backup exceeds the safe processing limit, so it was not used to restore."
            )
        case .profileUnavailable:
            (
                "找不到这份备份对应的浏览器配置文件（浏览器或配置文件可能已被移除），没有恢复。",
                "The browser profile this backup belongs to could not be found (the browser or the profile may have been removed), so nothing was restored."
            )
        case .databaseChanged:
            (
                "\(browserName) 的历史数据库无法访问，或在恢复过程中被替换，恢复没有完成。",
                "The history database of \(browserName) could not be reached or was replaced during the restore, so it did not complete."
            )
        case .timedOut:
            (
                "恢复超时，没有完成。",
                "The restore timed out and did not complete."
            )
        case .cancelled:
            (
                "恢复已取消。",
                "The restore was cancelled."
            )
        case .currentStateNotSaved:
            (
                "没能先保存 \(browserName) 当前的浏览记录。为了让恢复可以撤销，没有开始恢复。",
                "The current browsing history of \(browserName) could not be saved first. So that the restore can be undone, it was not started."
            )
        case .restoreResultNotSaved:
            (
                "已写回 \(browserName) 的浏览记录，但没能保存这份备份的恢复结果，无法确认恢复完整完成。",
                "The browsing history of \(browserName) was written back, but the backup's restore result could not be saved, so the restore could not be fully confirmed."
            )
        case .failed:
            (
                "恢复时出现未预期的错误，没有完成。",
                "An unexpected error stopped the restore."
            )
        }
    }
}

/// The result of restoring a backup from Recent Deletions.
struct BrowserPrivacyRestoreResult: Equatable, Sendable {
    let reason: BrowserPrivacyRestoreReason
    /// The backup of the state just before this restore; restoring it undoes
    /// the restore. Nil when nothing was changed.
    let undoBackupID: UUID?
    /// False when the history database is known to be unchanged.
    let historyMayHaveChanged: Bool
    let detail: String

    var succeeded: Bool { reason == .restored }

    init(
        reason: BrowserPrivacyRestoreReason,
        browserName: String?,
        undoBackupID: UUID? = nil,
        historyMayHaveChanged: Bool = false,
        dataType: BrowserPrivacyDataType? = nil,
        rowRestore: Bool = false
    ) {
        self.reason = reason
        self.undoBackupID = undoBackupID
        self.historyMayHaveChanged = historyMayHaveChanged
        let texts = reason.localizedTexts(
            browserName: browserName ?? L10n.text("浏览器", "the browser")
        )
        var detail = L10n.text(texts.chinese, texts.english)
        if reason != .restored {
            detail += " " + {
                guard historyMayHaveChanged else {
                    return L10n.text("浏览记录没有改动。", "The browsing history was not changed.")
                }
                return undoBackupID == nil
                    ? L10n.text(
                        "浏览记录可能已改动，请重新扫描核对。",
                        "The browsing history may have changed; scan again to check."
                    )
                    : L10n.text(
                        "浏览记录可能已部分改动；恢复前的状态已另存为备份，可在“最近的删除”里用它撤销。",
                        "The browsing history may have changed in part; the state before the restore was saved as a backup that undoes it in Recent Deletions."
                    )
            }()
        }
        if let dataType {
            detail = reason == .restored
                ? (rowRestore ? L10n.text("已补回可恢复的行并完成回读，之后新增或冲突的记录保留；同步、过期或 Cookie 分区可能影响结果。", "Recoverable rows were added and read back. Later additions and conflicting records were kept; sync, expiry and cookie partitioning may affect the result.") : L10n.text("已回读确认恢复 \(dataType.title)，恢复前状态已另存，可从操作记录撤销。", "Restore of \(dataType.title) was confirmed by readback. The previous state was saved and can be restored from operation records."))
                : detail.replacingOccurrences(of: "浏览记录", with: dataType.title + "记录")
                    .replacingOccurrences(of: "历史数据库", with: dataType.title + "数据库")
                    .replacingOccurrences(of: "browsing history", with: dataType.title + " records")
                    .replacingOccurrences(of: "history database", with: dataType.title + " database")
        }
        self.detail = detail
    }
}

/// Why a scanned record has no direct-deletion locator. It is recorded at
/// scan time so the interface can say what the user can actually do.
enum BrowserPrivacyDirectDeletionBlocker: String, CaseIterable, Equatable, Hashable, Sendable {
    /// This browser family has no verified write plan.
    case browserNotSupported
    case databaseNotWritable
    /// The installed application, its signature or the profile location
    /// could not be tied to this database.
    case applicationNotVerified
    case pathNotTrusted
    case schemaNotSupported
    /// The browser's sync service knows this visit; deleting only the local
    /// row would leave its copies in the account and on other devices.
    case syncedWithAccount
    /// The row has no usable address or visit time to bind a deletion to.
    case recordIncomplete

    func detail(browserName: String, engine: BrowserPrivacyEngine) -> String {
        let texts = localizedTexts(browserName: browserName, engine: engine)
        return L10n.text(texts.chinese, texts.english)
    }

    func localizedTexts(
        browserName: String,
        engine: BrowserPrivacyEngine
    ) -> (chinese: String, english: String) {
        switch self {
        case .browserNotSupported:
            switch engine {
            case .safari:
                (
                    "本应用目前不直接修改 Safari 的历史数据库（它的访问计数和派生索引的更新规则尚未验证）。请在 \(browserName) 内删除。",
                    "This app does not modify Safari's history database directly yet (the update rules for its visit counters and derived indexes are not verified). Delete these in \(browserName)."
                )
            case .firefox:
                (
                    "本应用目前不直接修改 Firefox 系列浏览器的历史数据库（它的访问计数和排序权重的更新规则尚未验证）。请在 \(browserName) 内删除。",
                    "This app does not modify the history database of Firefox-family browsers directly yet (the update rules for its visit counters and ranking weights are not verified). Delete these in \(browserName)."
                )
            case .chromium:
                (
                    "本应用尚未验证 \(browserName) 的历史数据库，不会直接修改。请在浏览器内删除。",
                    "This app has not verified the history database of \(browserName) and will not modify it directly. Delete these in the browser."
                )
            }
        case .databaseNotWritable:
            (
                "当前用户不能写入 \(browserName) 的历史数据库，不会直接修改。请在浏览器内删除。",
                "The current user cannot write to the history database of \(browserName), so it is not modified directly. Delete these in the browser."
            )
        case .applicationNotVerified:
            (
                "未能确认 \(browserName) 的安装位置和签名，无法确定这个数据库的归属，不会直接修改。请在浏览器内删除。",
                "The install location and signature of \(browserName) could not be confirmed, so this database cannot be tied to it and is not modified directly. Delete these in the browser."
            )
        case .pathNotTrusted:
            (
                "这个数据库的路径未通过安全校验（例如经过符号链接），不会直接修改。请在 \(browserName) 内删除。",
                "The path of this database did not pass the safety check (for example it goes through a symbolic link), so it is not modified directly. Delete these in \(browserName)."
            )
        case .schemaNotSupported:
            (
                "此版本的数据库结构不受支持，不会直接修改。请在 \(browserName) 内删除。",
                "This version of the database schema is not supported, so it is not modified directly. Delete these in \(browserName)."
            )
        case .syncedWithAccount:
            (
                "这条记录已同步到浏览器账号。只在这台 Mac 上删除会留下云端和其他设备上的副本，请在 \(browserName) 内删除。",
                "This record is synced with the browser account. Deleting it only on this Mac would leave the copies in the account and on other devices; delete it in \(browserName)."
            )
        case .recordIncomplete:
            (
                "这条记录缺少可用的网址或访问时间，无法精确定位，不会直接修改。请在 \(browserName) 内删除。",
                "This record has no usable address or visit time, so it cannot be located exactly and is not modified directly. Delete it in \(browserName)."
            )
        }
    }

    /// The text for a record that cannot be deleted directly. Safari- and
    /// Firefox-family browsers never have a write plan, so that cause holds
    /// even when the scan did not record one; otherwise the generic manual
    /// reason is used rather than guessing.
    static func manualDetail(
        recorded blocker: Self?,
        browserName: String,
        engine: BrowserPrivacyEngine
    ) -> String {
        if let blocker = blocker ?? (engine == .chromium ? nil : .browserNotSupported) {
            return blocker.detail(browserName: browserName, engine: engine)
        }
        return BrowserPrivacyProcessingReason.manualOnly.detail(browserName: browserName)
    }
}
