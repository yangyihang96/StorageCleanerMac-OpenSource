import Foundation

/// D154: the totals on My Activity (CleanMyMac's "Local Storage Cleaned"),
/// read from the receipt journal that Operation History lists. Only what a
/// receipt records is counted: bytes moved to a recoverable place, bytes an
/// emptied Trash freed, items moved. Temporary-file receipts (a copy's
/// staging folder, benchmark fixtures) are not the user's files and are left
/// out. Byte totals are never estimated. D187's separate time estimate
/// consumes successful-operation evidence without altering these totals.
struct MyActivitySummary: Equatable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case systemJunk
        case personalFiles
        case applications
    }

    var since: Date?
    var operationCount = 0
    var movedItemCount = 0
    var movedBytes: Int64 = 0
    var freedBytes: Int64 = 0
    var recoverableCount = 0
    var monthMovedBytes: Int64 = 0
    var monthOperationCount = 0
    var bytesByCategory: [Category: Int64] = [:]
    var recent: [CleanupReportIndex] = []
    /// More receipts exist than were read (the totals cover the newest ones).
    var isTruncated = false
    var unreadableCount = 0
    var timeSavingsRecords: [MyActivityTimeSavings.Record] = []
    /// Recorded size of recoverable Trash entries whose identity still matches.
    var recoverableTrashBytes: Int64 = 0

    static let pageSize = 100
    static let maximumPages = 30
    static let recentCount = 6
    /// Avoid walking an entire large cleanup's receipts on a dashboard visit.
    /// Recommendations describe the verified subset as a lower bound.
    static let maximumTrashIdentityReads = 1_000

    static func category(for rulesVersion: String) -> Category {
        if rulesVersion.hasPrefix("uninstall.") { return .applications }
        if rulesVersion == FileAnalysisTrashService.ruleID
            || rulesVersion == ExternalDriveMigrationService.originalRuleID
            || rulesVersion == VerifiedDuplicateCleanPlanBuilder.rulesVersion
            || rulesVersion == VerifiedDuplicateCleanPlanBuilder.ruleID {
            return .personalFiles
        }
        return .systemJunk
    }

    /// Reads the journal newest first; call it off the main thread.
    static func load(journal: CleanupReportJournal, now: Date = Date(), calendar: Calendar = .current,
                     fileSystem: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()) -> MyActivitySummary {
        var summary = MyActivitySummary()
        var cursor: CleanupReportIndex.Cursor?
        var countedTrashPaths = Set<String>()
        var remainingTrashReads = maximumTrashIdentityReads
        for page in 0..<maximumPages {
            guard let loaded = try? CleanReportStore.summaryPage(after: cursor, limit: pageSize, journal: journal) else {
                summary.unreadableCount += 1
                break
            }
            summary.unreadableCount += loaded.unreadableEntries.count
            for report in loaded.reports {
                guard !OperationRecordPresentation.isTemporaryResource(report.rulesVersion) else { continue }
                summary.add(report, now: now, calendar: calendar)
                let detail: CleanReport?
                if (report.recoverableCount > 0 && remainingTrashReads > 0) || report.rulesVersion.hasPrefix("uninstall.") {
                    detail = try? journal.read(planID: report.planID)
                } else { detail = nil }
                if let record = MyActivityTimeSavings.receiptRecord(report, detail: detail) {
                    summary.timeSavingsRecords.append(record)
                }
                if let detail {
                    for item in detail.items {
                        guard remainingTrashReads > 0 else { break }
                        guard case .moved(let receipt) = item.outcome, receipt.isRestorable,
                              receipt.disposition == .trash,
                              !detail.recoveryBlocksRetry(of: receipt.originalPath),
                              !countedTrashPaths.contains(receipt.resultingItemURL.path) else { continue }
                        remainingTrashReads -= 1
                        guard let current = try? fileSystem.snapshot(at: receipt.resultingItemURL),
                              current.identity == receipt.movedIdentity else { continue }
                        countedTrashPaths.insert(receipt.resultingItemURL.path)
                        summary.recoverableTrashBytes = CleanupByteCount.adding(max(0, item.estimatedBytes),
                                                                               to: summary.recoverableTrashBytes)
                    }
                }
            }
            cursor = loaded.next
            if cursor == nil { break }
            if page == maximumPages - 1 { summary.isTruncated = true }
        }
        return summary
    }

    mutating func add(_ report: CleanupReportIndex, now: Date, calendar: Calendar) {
        guard !OperationRecordPresentation.isTemporaryResource(report.rulesVersion) else { return }
        operationCount += 1
        if recent.count < Self.recentCount { recent.append(report) }
        if since.map({ report.startedAt < $0 }) ?? true { since = report.startedAt }
        let moved = max(0, report.summary.movedToRecoverableLocationBytes)
        movedBytes = CleanupByteCount.adding(moved, to: movedBytes)
        freedBytes = CleanupByteCount.adding(max(0, report.summary.permanentlyFreedBytes), to: freedBytes)
        movedItemCount += max(0, report.summary.movedItemCount)
        recoverableCount += max(0, report.recoverableCount)
        let category = Self.category(for: report.rulesVersion)
        bytesByCategory[category] = CleanupByteCount.adding(moved, to: bytesByCategory[category] ?? 0)
        if calendar.isDate(report.startedAt, equalTo: now, toGranularity: .month) {
            monthMovedBytes = CleanupByteCount.adding(moved, to: monthMovedBytes)
            monthOperationCount += 1
        }
    }
}
