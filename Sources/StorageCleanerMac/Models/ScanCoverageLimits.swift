import Foundation

/// D179: what really kept a junk scan from reading everything.
/// `ScanOutcome.partial` also counts what the rules hold back on purpose (D19:
/// rows that cannot be selected, hold an excluded path or protected data),
/// files that went away while the scan ran and sizes short only by skipped
/// links. On this Mac every scan was "partial" that way (10-23: six scans of
/// 14–42 s, nothing denied, all marked limited), so the results page said the
/// scan had not finished "(time limit or unreadable places)", the score took
/// the scan-completeness penalty and the last scan always asked for a rescan.
/// Those three read this instead; the outcome itself is unchanged (D104 G5).
/// A complete outcome reports only what the old rule did: the time limit and
/// the per-rule cap.
struct ScanCoverageLimits: Equatable, Sendable {
    var reachedTimeLimit = false
    /// Rule roots or entries the scan was not allowed to read.
    var deniedLocationCount = 0
    /// Rule roots or entries that could not be read, such as a root behind a
    /// symbolic link.
    var unreadableLocationCount = 0
    /// Rows whose size is only a lower bound, or failed, for a reason other
    /// than skipped links or excluded paths.
    var partlyMeasuredCount = 0
    /// Rows left out by the per-rule cap.
    var truncatedCandidateCount = 0
    /// Entries skipped for missing metadata, an unavailable volume or a path
    /// outside the rule's root.
    var otherSkippedCount = 0
    /// A cancelled scan, or a partial one that none of the above explains.
    var unexplained = false

    var isLimited: Bool { deniedLocationCount > 0 || isLimitedBeyondPermissions }

    /// Everything but denied folders, which the score and the reminders count
    /// on their own (`deniedCount`, `permissionLimited`).
    var isLimitedBeyondPermissions: Bool {
        reachedTimeLimit || unreadableLocationCount > 0 || partlyMeasuredCount > 0
            || truncatedCandidateCount > 0 || otherSkippedCount > 0 || unexplained
    }
}

extension ScanSession {
    var coverageLimits: ScanCoverageLimits {
        var limits = ScanCoverageLimits()
        limits.reachedTimeLimit = metrics.timedOutRuleCount > 0
            || (outcome != .complete && issues.contains { $0.kind == .timedOut })
        limits.truncatedCandidateCount = metrics.truncatedCandidateCount
        guard outcome != .complete else { return limits }

        func locations(_ status: CleanupPermissionStatus, _ kind: ScanIssueKind) -> Int {
            Set(permissions.filter { $0.status == status }.map(\.path)
                + issues.filter { $0.kind == kind }.map { $0.path ?? $0.ruleID ?? "" }).count
        }
        limits.deniedLocationCount = locations(.permissionDenied, .permissionDenied)
        limits.unreadableLocationCount = locations(.unreadable, .unreadable)
        limits.partlyMeasuredCount = candidates.filter { $0.measurementCompleteness.limitsCoverage }.count
        limits.otherSkippedCount = issues.filter {
            $0.kind == .metadataUnavailable || $0.kind == .volumeUnavailable || $0.kind == .outsideAllowedRoot
        }.count
        let explained = limits.isLimited
            || issues.contains { $0.kind.isDeliberateSkip }
            || candidates.contains { !$0.measurementCompleteness.isComplete }
        limits.unexplained = outcome == .cancelled || !explained
        return limits
    }
}

extension MeasurementCompleteness {
    /// D179: short for a reason other than skipped links or excluded paths.
    var limitsCoverage: Bool {
        switch self {
        case .complete, .lowerBound(.symbolicLinkSkipped), .lowerBound(.excludedDescendant):
            false
        case .lowerBound, .failed:
            true
        }
    }
}

extension ScanIssueKind {
    /// D179: held back on purpose (D19), skipped as designed, or gone before
    /// it could be read. Still `limitsScanCoverage` where D104 G5 says so.
    var isDeliberateSkip: Bool {
        switch self {
        case .candidateNotActionable, .candidateContainsExcludedPath, .candidateContainsProtectedData,
             .vanished, .symbolicLinkSkipped, .hardLinkDeduplicated, .cloudPlaceholderSkipped:
            true
        case .permissionDenied, .unreadable, .metadataUnavailable, .volumeUnavailable,
             .outsideAllowedRoot, .timedOut:
            false
        }
    }
}
