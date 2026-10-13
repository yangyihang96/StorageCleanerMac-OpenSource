import Foundation

/// Current presentation derived from the original receipt and its append-only
/// recovery evidence. Historical move counts are never rewritten after restore.
struct OperationResultPresentation: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case processing, draining, completed, partial, failed, cancelled, needsVerification
        case partiallyRestored, restored, retained, recoveryFailed
    }
    let state: State
    let movedCount: Int
    let restoredCount: Int
    let keptCount: Int
    let failedCount: Int
    let notRunCount: Int
    let remainingMovedBytes: Int64
    /// D23: Trash entries permanently deleted. Missing in older index entries.
    var deletedCount: Int? = nil

    init(report: CleanReport, processing: Bool = false, draining: Bool = false) {
        let restoredPaths = Set((report.recoveryAttempts ?? []).flatMap(\.items)
            .filter { $0.outcome == .restored }.map(\.originalPath))
        var moved = 0, restored = 0, kept = 0, failed = 0, notRun = 0, deleted = 0
        var bytes: Int64 = 0
        var uncertain = report.persistenceFailure != nil
        for item in report.items {
            switch item.outcome {
            case .moved(let receipt):
                moved += 1
                if restoredPaths.contains(item.sourcePath) { restored += 1 }
                else {
                    bytes += max(0, item.estimatedBytes)
                    uncertain = uncertain || !receipt.isRestorable
                }
            case .skipped: kept += 1
            case .notProcessed: notRun += 1
            case .failed(let failure):
                failed += 1
                uncertain = uncertain || failure.code == .moveOutcomeUnknown
                    || failure.code == .deletionOutcomeUnknown
            case .deleted: deleted += 1
            }
        }
        uncertain = uncertain || (report.recoveryAttempts ?? []).contains {
            $0.persistenceFailure != nil || $0.items.contains {
                $0.outcome == .outcomeUnknown && !restoredPaths.contains($0.originalPath)
            }
        }
        movedCount = moved; restoredCount = restored; keptCount = kept
        failedCount = failed; notRunCount = notRun; remainingMovedBytes = bytes
        deletedCount = deleted
        if draining { state = .draining }
        else if processing { state = .processing }
        else if uncertain { state = .needsVerification }
        else if restored > 0 { state = restored == moved ? .restored : .partiallyRestored }
        else if !(report.recoveryAttempts ?? []).isEmpty { state = .recoveryFailed }
        else if report.outcome == .cancelled { state = .cancelled }
        else if failed + notRun > 0 { state = moved + deleted > 0 ? .partial : .failed }
        else if moved + deleted > 0 { state = kept > 0 ? .partial : .completed }
        else { state = .retained }
    }

    var title: String {
        switch state {
        case .processing: L10n.text("正在处理", "Processing")
        case .draining: L10n.text("正在收尾", "Finishing cancellation")
        case .completed: L10n.text("处理完成", "Completed")
        case .partial: L10n.text("部分完成", "Partially completed")
        case .failed: L10n.text("未完成", "Not completed")
        case .cancelled: L10n.text("已取消", "Cancelled")
        case .needsVerification: L10n.text("结果待核实", "Results need verification")
        case .partiallyRestored: L10n.text("部分恢复", "Partially restored")
        case .restored: L10n.text("已全部恢复", "All moved items restored")
        case .recoveryFailed: L10n.text("恢复未完成", "Recovery not completed")
        case .retained: L10n.text("未移走文件", "No files moved")
        }
    }

    var summary: String {
        // Receipts cover confirmed items only. Unselected candidates are shown
        // separately by the preview; a zero here must not claim none were kept.
        var parts = [restoredCount > 0
            ? L10n.text("已恢复 \(restoredCount) / \(movedCount)", "Restored \(restoredCount) / \(movedCount)")
            : L10n.text("已移走 \(movedCount)", "Moved \(movedCount)")]
        if let deletedCount, deletedCount > 0 {
            parts.append(L10n.text("已永久删除 \(deletedCount)", "Permanently deleted \(deletedCount)"))
        }
        if keptCount > 0 { parts.append(L10n.text("已保留 \(keptCount)", "Kept \(keptCount)")) }
        if failedCount > 0 {
            parts.append(restoredCount > 0
                ? L10n.text("原操作失败 \(failedCount)", "Original failures \(failedCount)")
                : L10n.text("失败 \(failedCount)", "Failed \(failedCount)"))
        }
        if notRunCount > 0 { parts.append(L10n.text("未执行 \(notRunCount)", "Not run \(notRunCount)")) }
        return parts.joined(separator: " · ")
    }

    var systemImage: String {
        switch state {
        case .processing, .draining: "hourglass"
        case .completed, .restored: "checkmark.circle"
        case .retained, .cancelled: "minus.circle"
        default: "exclamationmark.circle"
        }
    }
}
