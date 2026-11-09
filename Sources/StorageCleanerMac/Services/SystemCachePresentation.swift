import FileOperationShared
import Foundation

extension SystemCacheID {
    var title: String {
        switch self {
        case .coreSymbolication: L10n.text("系统符号缓存", "System Symbol Cache")
        case .iconServices: L10n.text("图标缓存", "Icon Cache")
        }
    }
    var explanation: String {
        switch self {
        case .coreSymbolication:
            L10n.text("系统会自动重建符号缓存。删除后不能撤销。", "The system rebuilds symbol caches automatically. Deletion cannot be undone.")
        case .iconServices:
            L10n.text("系统会自动重建图标缓存。删除后不能撤销；可能需要重启或重新登录，图标才恢复正常。",
                      "The system rebuilds icon caches automatically. Deletion cannot be undone; icons may need a restart or signing in again to return to normal.")
        }
    }
}

struct SystemCacheClearPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    let items: [SystemCacheInventoryItem]
    var directories: [SystemCacheDirectoryIdentity] { items.compactMap(\.identity) }
    var facts: OperationConfirmationFacts {
        let bytes = CleanupByteCount.sum(items.compactMap(\.allocatedBytes))
        return OperationConfirmationFacts(surface: .safeCleanup, actions: [.permanentDeletion],
            items: items.map { .init(id: $0.cache.rawValue, title: $0.cache.title, path: nil,
                                     bytes: $0.allocatedBytes, detail: $0.cache.explanation) },
            localBytes: bytes, bytesAreLowerBound: items.contains { $0.failure != nil },
            permanentDeletionBytes: bytes, recovery: [.notRecoverable], permission: .notRequired,
            objectWarnings: [L10n.text("需要管理员密码。只清除所选缓存文件夹里的内容，系统会自动重建。",
                                      "Requires an administrator password. Only the contents of the selected cache folders are cleared; the system rebuilds them.")])
    }
}

enum SystemCachePresentation {
    static func bytes(_ inventory: SystemCacheInventoryReply?) -> Int64 {
        CleanupByteCount.sum(inventory?.items.compactMap(\.allocatedBytes) ?? [])
    }
    static func isSelectable(_ item: SystemCacheInventoryItem) -> Bool {
        item.identity != nil && item.allocatedBytes != nil
    }
    static func result(_ reply: SystemCacheClearReply) -> String {
        let count = ByteFormat.count(reply.items.reduce(0) { $0 + $1.deletedEntries })
        let bytes = ByteFormat.storageString(CleanupByteCount.sum(reply.items.map(\.freedBytes)))
        let skipped = ByteFormat.count(reply.items.reduce(0) { $0 + $1.skippedEntries })
        let summary = L10n.text("已删除 \(count) 项系统缓存，约腾出 \(bytes)。",
                                "Deleted \(count) system cache entries, freeing approximately \(bytes).")
        let partial = reply.items.contains { $0.failure != nil || $0.skippedEntries > 0 }
            ? L10n.text("跳过 \(skipped) 项，部分缓存未清除。", "Skipped \(skipped) entries; some caches were not cleared.") : ""
        return [summary, partial, L10n.text("系统仍占用的已删除文件，要等其关闭后才释放空间。",
            "Space held by deleted files still open in the system is released when they close.")]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// D249 (G batch): every system-cache clear leaves a receipt in
/// `CleanupReports`, so Operation History shows each run — what was cleared,
/// how many entries, how much space — not only the sheet's last message.
/// The deletion is permanent: the receipt never offers Restore.
enum SystemCacheClearReceipt {
    static let ruleID = "system-caches.clear.v1"

    /// nil when nothing can have been deleted (authorization not given, the
    /// helper refused before committing). A commit whose reply never came
    /// back is recorded as “may be partly deleted”.
    static func report(plan: SystemCacheClearPlan, reply: SystemCacheClearReply?, outcomeUnknown: Bool,
                       startedAt: Date, completedAt: Date) -> CleanReport? {
        guard outcomeUnknown || !(reply?.items.isEmpty ?? true) else { return nil }
        let items: [CleanReportItem] = plan.items.compactMap { planned in
            guard let identity = planned.identity else { return nil }
            let path = planned.cache.directoryPath
            let outcome: CleanItemOutcome
            var entries: Int?
            if let result = reply?.items.first(where: { $0.cache == planned.cache }) {
                entries = result.deletedEntries
                if let failure = result.failure {
                    outcome = .failed(CleanFailure(code: result.deletedEntries > 0 ? .deletionOutcomeUnknown : .unexpected,
                                                   detailCode: failure))
                } else {
                    outcome = .deleted(CleanupDeletionReceipt(
                        originalPath: path,
                        deletedIdentity: FileIdentity(deviceID: identity.device, inode: identity.inode,
                                                      entryKind: .directory, creationTimeNanoseconds: nil),
                        deletedAt: completedAt))
                }
            } else {
                outcome = .failed(CleanFailure(code: .deletionOutcomeUnknown, detailCode: "connection-interrupted"))
            }
            return CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: ruleID, sourcePath: path,
                                   estimatedBytes: planned.allocatedBytes ?? 0, outcome: outcome,
                                   deletedEntryCount: entries)
        }
        let deleted = items.filter { if case .deleted = $0.outcome { true } else { false } }.count
        let failed = items.count - deleted
        let freed = CleanupByteCount.sum(reply?.items.map(\.freedBytes) ?? [])
        return CleanReport(
            id: UUID(), planID: CleanPlanID(rawValue: plan.id), sessionID: ScanSessionID(),
            rulesVersion: ruleID, disposition: .trash, scanWasPartial: false,
            startedAt: startedAt, completedAt: completedAt,
            outcome: failed == 0 ? .completed : (deleted > 0 ? .partiallyCompleted : .failed),
            items: items,
            summary: CleanReportSummary(
                requestedItemCount: items.count, movedItemCount: 0, skippedItemCount: 0,
                failedItemCount: failed, notProcessedItemCount: 0, unverifiedMoveCount: 0,
                plannedBytes: CleanupByteCount.sum(plan.items.compactMap(\.allocatedBytes)),
                movedToRecoverableLocationBytes: 0, reclaimableAfterEmptyingTrashBytes: nil,
                permanentlyFreedBytes: freed, availableSpaceDeltaBytes: nil, deletedItemCount: deleted))
    }

    static var historyTitle: String { L10n.text("系统缓存 · 永久清除", "System Caches · Permanently Cleared") }

    /// The folder stays; its contents are gone for good.
    static func itemLabel(_ item: CleanReportItem) -> String {
        let entries = item.deletedEntryCount.map {
            L10n.text("\(ByteFormat.count($0)) 项内容", "\(ByteFormat.count($0)) entries")
        }
        switch item.outcome {
        case .deleted:
            return [L10n.text("已永久清除", "Permanently cleared"), entries, L10n.text("不可恢复", "not recoverable")]
                .compactMap { $0 }.joined(separator: " · ")
        case .failed(let failure) where failure.code == .deletionOutcomeUnknown:
            return [L10n.text("清除未完成，部分内容可能已删除", "Clearing did not finish; some content may be gone"), entries]
                .compactMap { $0 }.joined(separator: " · ")
        default:
            return L10n.text("未清除", "Not cleared")
        }
    }

    static func freedLabel(_ summary: CleanReportSummary) -> String {
        L10n.text("永久释放：约 ", "Permanently freed: about ") + ByteFormat.storageString(summary.permanentlyFreedBytes)
            + L10n.text("（不可恢复）", " (not recoverable)")
    }
}
