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
    /// D214: the run never started (`CleanReport.startRefusal`); its items
    /// count as not run. Missing in older index entries.
    var startRefusal: CleanFailure? = nil

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
        startRefusal = report.startRefusal
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
        if startRefusal != nil { return CleanStartRefusalPresentation.title }
        return switch state {
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
            ? L10n.text("已恢复 \(ByteFormat.count(restoredCount)) / \(ByteFormat.count(movedCount))", "Restored \(ByteFormat.count(restoredCount)) / \(ByteFormat.count(movedCount))")
            : L10n.text("已移走 \(ByteFormat.count(movedCount))", "Moved \(ByteFormat.count(movedCount))")]
        if let deletedCount, deletedCount > 0 {
            parts.append(L10n.text("已永久删除 \(ByteFormat.count(deletedCount))", "Permanently deleted \(ByteFormat.count(deletedCount))"))
        }
        if keptCount > 0 { parts.append(L10n.text("已保留 \(ByteFormat.count(keptCount))", "Kept \(ByteFormat.count(keptCount))")) }
        if failedCount > 0 {
            parts.append(restoredCount > 0
                ? L10n.text("原操作失败 \(ByteFormat.count(failedCount))", "Original failures \(ByteFormat.count(failedCount))")
                : L10n.text("失败 \(ByteFormat.count(failedCount))", "Failed \(ByteFormat.count(failedCount))"))
        }
        if notRunCount > 0 { parts.append(L10n.text("未执行 \(ByteFormat.count(notRunCount))", "Not run \(ByteFormat.count(notRunCount))")) }
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

/// D214: a cleanup that never started is told as such — “Could Not Start”,
/// why, and that nothing moved — never as failures. The words follow D205's
/// Applications page.
enum CleanStartRefusalPresentation {
    static var title: String { L10n.text("没能开始", "Could Not Start") }
    static var nothingMoved: String { L10n.text("没有移动任何文件", "Nothing was moved") }

    /// The reason, then that nothing moved and the selection is kept.
    static func message(_ refusal: CleanFailure) -> String {
        reason(refusal) + L10n.text("没有移动任何文件，选中的项目都还在。", " Nothing was moved, and your selection is kept.")
    }

    static func reason(_ refusal: CleanFailure) -> String {
        switch refusal.code {
        case .coordinatorBusy:
            if let detail = refusal.detailCode, detail.hasPrefix(leaseBusyPrefix),
               let owner = HeavyWorkCoordinator.Owner.allCases.first(where: {
                   key(for: $0) == detail.dropFirst(leaseBusyPrefix.count)
               }) {
                return HeavyWorkActivityStore.conflictMessage(activeOwner: owner)
            }
            switch refusal.detailCode {
            case "instance-busy": return OperationFileLock.Failure.busy.localizedDescription
            case "lock-unsafe": return OperationFileLock.Failure.unsafePath.localizedDescription
            default:
                return L10n.text("另一项任务正在进行，请等待它结束后再试。", "Another task is running. Wait for it to finish, then try again.")
            }
        case .featureDisabled:
            return L10n.text("安全清理没有启用。", "Safe cleanup is not enabled.")
        case .planIntegrityFailed:
            return L10n.text("这份清理计划已失效（扫描结果或规则有变化，或已经执行过），请重新扫描后再试。",
                             "This cleanup plan is no longer valid (the scan results or rules changed, or it already ran). Scan again, then try again.")
        case .persistenceFailed:
            return L10n.text("无法写入操作记录，为安全起见没有开始。", "The operation record could not be written, so nothing was started.")
        default:
            return CleanFailurePresentation.title(refusal) + L10n.text("。", ".")
        }
    }

    /// The executor's refusal when the work lease cannot be taken, with what
    /// held it, for `reason`.
    static func leaseRefusal(_ error: any Error) -> CleanFailure {
        let detail: String? = switch error {
        case HeavyWorkCoordinator.Error.busy(let owner): leaseBusyPrefix + key(for: owner)
        case OperationFileLock.Failure.busy: "instance-busy"
        case OperationFileLock.Failure.unsafePath: "lock-unsafe"
        default: nil
        }
        return CleanFailure(code: .coordinatorBusy, detailCode: detail)
    }

    private static let leaseBusyPrefix = "lease-busy:"

    /// Stable receipt keys for the lease's owners.
    private static func key(for owner: HeavyWorkCoordinator.Owner) -> String {
        switch owner {
        case .mainScan: "mainScan"
        case .largeFilesScan: "largeFilesScan"
        case .duplicateScan: "duplicateScan"
        case .cleanup: "cleanup"
        case .restore: "restore"
        case .emptyTrash: "emptyTrash"
        case .memoryOptimization: "memoryOptimization"
        case .appUpdates: "appUpdates"
        case .networkTest: "networkTest"
        case .benchmark: "benchmark"
        case .cloudLocalCopy: "cloudLocalCopy"
        }
    }
}
