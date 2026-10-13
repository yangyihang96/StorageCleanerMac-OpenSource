import Foundation

/// "Restore latest cleanup" keeps its own history from before the receipt
/// journal. Moves made through that path since then also have journal
/// receipts, so those records restore through the journal: identity checks,
/// intents and Operation History stay authoritative. Only records with no
/// matching receipt use the old path, which still refuses replaced items.
enum LegacyCleanupRestore {
    /// The journal rule the legacy single-item and bulk Trash paths write.
    static let legacyRulesVersion = "cleanup.legacy-paths.v1"

    struct Match: Sendable {
        let report: CleanReport
        /// Lexical original paths to restore; other receipts in the same
        /// report were not confirmed by the user and are left in Trash.
        let originalPaths: Set<String>
    }

    struct Plan: Sendable {
        let matches: [Match]
        /// Records with no receipt of the same file: written before the
        /// journal existed, or describing a file that was replaced since.
        let unmatched: [TrashMoveRecord]
        /// Records whose receipt was already restored, or whose last restore
        /// is awaiting verification. They are never restored a second time.
        let settled: [(record: TrashMoveRecord, outcome: CleanupRecoveryItemOutcome)]
    }

    /// The same file, not just the same name: a later cleanup can put a
    /// different item at the same original path and Trash name.
    static func describesSameFile(_ record: TrashMoveRecord, _ receipt: CleanupMoveReceipt) -> Bool {
        guard PathSafety.lexicalPath(record.originalPath) == PathSafety.lexicalPath(receipt.originalPath),
              record.resultingItemURL.standardizedFileURL.path == receipt.resultingItemURL.standardizedFileURL.path,
              let recorded = record.itemIdentity, let moved = receipt.movedIdentity,
              let birth = moved.creationTimeNanoseconds else { return false }
        return recorded.deviceID == moved.deviceID && recorded.fileID == moved.inode
            && recorded.birthTimeSeconds * 1_000_000_000 + recorded.birthTimeNanoseconds == birth
    }

    static func plan(for records: [TrashMoveRecord], reports: [CleanReport]) -> Plan {
        let legacyReports = reports.filter { $0.rulesVersion == legacyRulesVersion && $0.disposition == .trash }
        var matchedPaths: [CleanPlanID: (report: CleanReport, paths: Set<String>)] = [:]
        var order: [CleanPlanID] = []
        var unmatched: [TrashMoveRecord] = []
        var settled: [(record: TrashMoveRecord, outcome: CleanupRecoveryItemOutcome)] = []
        for record in records {
            let candidates = legacyReports.compactMap { report -> (CleanReport, CleanupMoveReceipt)? in
                for item in report.items {
                    if case .moved(let receipt) = item.outcome, describesSameFile(record, receipt) {
                        return (report, receipt)
                    }
                }
                return nil
            }
            // The receipt the record was made from carries the same move time;
            // otherwise the newest move of this file is the one still in Trash.
            guard let (report, _) = candidates.first(where: { $0.1.movedAt == record.movedAt })
                ?? candidates.max(by: { $0.1.movedAt < $1.1.movedAt }) else {
                unmatched.append(record)
                continue
            }
            let path = PathSafety.lexicalPath(record.originalPath)
            if report.restorableReceipts.contains(where: { PathSafety.lexicalPath($0.originalPath) == path }) {
                if matchedPaths[report.planID] == nil { order.append(report.planID) }
                matchedPaths[report.planID, default: (report, [])].paths.insert(path)
            } else {
                let last = (report.recoveryAttempts ?? []).flatMap(\.items)
                    .last { PathSafety.lexicalPath($0.originalPath) == path }?.outcome
                settled.append((record, last ?? .failed))
            }
        }
        let matches = order.compactMap { id in matchedPaths[id].map { Match(report: $0.report, originalPaths: $0.paths) } }
        return Plan(matches: matches, unmatched: unmatched, settled: settled)
    }

    static func summary(
        records: [TrashMoveRecord],
        plan: Plan,
        recoveries: [CleanupRecoveryReport],
        legacy: TrashRestoreSummary?
    ) -> TrashRestoreSummary {
        var outcomes: [String: CleanupRecoveryItemOutcome] = [:]
        for item in recoveries.flatMap(\.items) { outcomes[PathSafety.lexicalPath(item.originalPath)] = item.outcome }
        let unmatchedIDs = Set(plan.unmatched.map(\.id))
        let settled = Dictionary(plan.settled.map { ($0.record.id, $0.outcome) }, uniquingKeysWith: { first, _ in first })
        var restored = legacy?.restored ?? []
        var conflicts = legacy?.conflicts ?? []
        var missing = legacy?.missing ?? []
        var failed = legacy?.failed ?? []
        for record in records where !unmatchedIDs.contains(record.id) {
            if let previous = settled[record.id] {
                if previous == .restored { missing.append(record) } // already back; not in Trash
                else { failed.append(.init(record: record, reason: reason(for: previous))) }
                continue
            }
            switch outcomes[PathSafety.lexicalPath(record.originalPath)] ?? .notProcessed {
            case .restored: restored.append(record)
            case .missing: missing.append(record)
            case .conflict: conflicts.append(record)
            case let other: failed.append(.init(record: record, reason: reason(for: other)))
            }
        }
        return TrashRestoreSummary(restored: restored, conflicts: conflicts, missing: missing, failed: failed)
    }

    private static func reason(for outcome: CleanupRecoveryItemOutcome) -> String {
        switch outcome {
        case .outcomeUnknown:
            L10n.text("恢复结果待核实，请在操作记录中查看", "The restore result needs verification; see Operation History")
        case .identityChanged:
            L10n.text("废纸篓中的项目已变化，未恢复", "The item in Trash changed and was not restored")
        case .unsafePath:
            L10n.text("路径不在安全恢复范围内，未恢复", "The path is outside the safe restore area and was not restored")
        case .notProcessed:
            L10n.text("未处理，项目仍在废纸篓", "Not processed; the item is still in Trash")
        case .restored, .missing, .conflict, .failed:
            L10n.text("恢复失败，项目仍在废纸篓", "Restore failed; the item is still in Trash")
        }
    }
}

/// Shown instead of an internal error name when the journal cannot be read.
struct OperationJournalUnavailableError: LocalizedError {
    var errorDescription: String? {
        L10n.text("无法读取操作记录，未恢复任何文件。", "Operation History could not be read. Nothing was restored.")
    }
}
