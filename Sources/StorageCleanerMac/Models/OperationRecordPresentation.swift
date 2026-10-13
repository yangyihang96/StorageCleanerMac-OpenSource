import Foundation

/// Operation History wording that depends on what a receipt records (N18):
/// which operation it was, and plain status for receipts that only exist so
/// temporary files are cleaned up after a crash.
enum OperationRecordPresentation {
    /// Whether the restore banner belongs to this visit of Operation History:
    /// the result already present when the page opened is not shown again.
    enum RecoveryBaseline: Equatable {
        case notCaptured
        case captured(CleanupRecoveryReport?)
    }

    private static let migrationStagingRuleID = "migration.staging.v1"
    private static let benchmarkFixtureRuleID = "benchmark.fixture.v1"

    /// Receipts of temporary files (a copy's staging folder, benchmark
    /// fixtures). They never move a user's file and have nothing to restore.
    static func isTemporaryResource(_ rulesVersion: String) -> Bool {
        rulesVersion == migrationStagingRuleID || rulesVersion == benchmarkFixtureRuleID
    }

    static func title(rulesVersion: String, subject: String?, itemCount: Int = 1) -> String {
        if rulesVersion == FileAnalysisTrashService.ruleID {
            // D46: "File Analysis · <first item> (and N more)".
            guard let subject else { return L10n.text("文件分析 · 移到废纸篓", "File Analysis · Moved to Trash") }
            let name = L10n.text("文件分析", "File Analysis") + " · " + subject
            return itemCount > 1
                ? name + L10n.text(" 等 \(itemCount) 项", " and \(itemCount - 1) more")
                : name
        }
        if rulesVersion == ExternalDriveMigrationService.originalRuleID {
            return L10n.text("文件搬家", "File Move") + " · "
                + (subject ?? L10n.text("原件移到废纸篓", "Original Moved to Trash"))
        }
        if rulesVersion == migrationStagingRuleID {
            return L10n.text("文件搬家 · 复制用的临时文件", "File Move · Temporary Copy Files")
        }
        if let subject { return subject }
        if rulesVersion.hasPrefix("uninstall.") { return L10n.text("卸载与关联清理", "Uninstall and Related Cleanup") }
        if rulesVersion.hasPrefix("benchmark.") { return L10n.text("跑分测试资源", "Benchmark Test Resources") }
        return L10n.text("文件清理", "File Cleanup")
    }

    /// Status line for a temporary-files receipt in place of the generic
    /// "No files moved · Moved 0 · Kept 1"; nil for every other receipt.
    static func temporaryResourceStatus(rulesVersion: String, outcome: CleanReportOutcome) -> String? {
        guard isTemporaryResource(rulesVersion) else { return nil }
        return outcome == .completed
            ? L10n.text("已自动清理，无需处理", "Removed automatically; nothing to do")
            : L10n.text("未能自动清理，需要核实", "Not removed automatically; needs checking")
    }

    static func temporaryItemLabel(_ outcome: CleanItemOutcome) -> String {
        if case .skipped(.itemMissing) = outcome {
            return L10n.text("临时文件已清理", "Temporary files removed")
        }
        return L10n.text("临时文件未能清理，需要核实", "Temporary files not removed; needs checking")
    }

    /// Temporary-files receipts moved nothing of the user's, so there is no
    /// "Restore" and no "originally moved" size for them.
    static func offersRestore(rulesVersion: String) -> Bool {
        !isTemporaryResource(rulesVersion)
    }

    /// D46: Operation History restores only from the user's Trash. An item
    /// File Analysis moved on an external volume is in that volume's Trash
    /// and is put back in Finder.
    static func isInUserTrash(_ receipt: CleanupMoveReceipt, userTrashPath: String) -> Bool {
        receipt.disposition != .trash
            || PathSafety.isContained(receipt.resultingItemURL.path, in: userTrashPath, resolvingSymlinks: false)
    }

    static var otherTrashLabel: String {
        L10n.text("在该卷的废纸篓中 · 请在访达中放回", "In that volume's Trash · put it back in Finder")
    }

    static func visibleRecovery(
        current: CleanupRecoveryReport?,
        baseline: RecoveryBaseline
    ) -> CleanupRecoveryReport? {
        guard case .captured(let earlier) = baseline, let current, current != earlier else { return nil }
        return current
    }
}
