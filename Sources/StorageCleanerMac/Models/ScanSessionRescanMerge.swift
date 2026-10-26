import Foundation

/// D104 G5: a scan's results completed by scanning only the locations that
/// became readable after access was granted. The rescan runs as part of the
/// same session (the scanner takes the session's identifier), so the rows
/// from both share one session, one selection and one plan.
extension ScanSession {
    /// The rules whose roots this session could not read and that are now
    /// readable at `paths`.
    func deniedRuleIDs(at paths: [String]) -> Set<String> {
        Set(permissions.filter { $0.status == .permissionDenied && paths.contains($0.path) }.map(\.ruleID))
    }

    /// This session with the rules in `requestedRuleIDs` replaced by what
    /// `rescan` found for them. Only rules the rescan reported on are
    /// replaced; a rule it did not reach keeps its old report, so its
    /// location still counts as not read. Nil when nothing can be merged: a
    /// cancelled rescan, one that belongs to another session or ran with
    /// other rules (version or fingerprint, D82), or one that reported on
    /// none of the requested rules.
    ///
    /// Rows already listed keep their place: a rescanned row that is the same
    /// file as one of them, or lies inside or contains one, is not listed
    /// again and counts as deduplicated, as when two rules of one scan reach
    /// the same files. Hard links between files inside a rescanned row and
    /// files inside a listed row cannot be matched without reading the listed
    /// rows again; a full rescan matches them.
    func mergingRescan(_ rescan: ScanSession, ofRules requestedRuleIDs: Set<String>) -> ScanSession? {
        let listedRuleIDs = Set(categories.flatMap(\.subcategories).map(\.id))
        let rescanned = requestedRuleIDs
            .intersection(rescan.permissions.map(\.ruleID))
            .intersection(listedRuleIDs)
        guard rescan.id == id, rescan.outcome != .cancelled, !rescanned.isEmpty,
              rescan.rulesVersion == rulesVersion,
              rulesProvenance == nil || rescan.rulesProvenance == rulesProvenance else { return nil }

        var claims = ScanRowClaims(categories.flatMap(\.subcategories)
            .filter { !rescanned.contains($0.id) }
            .flatMap(\.candidates))
        var deduplicated = [ScanIssue]()
        let found = Dictionary(
            rescan.categories.flatMap(\.subcategories)
                .filter { rescanned.contains($0.id) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let mergedCategories = categories.map { category in
            CleanupScanCategory(
                id: category.id,
                title: category.title,
                subcategories: category.subcategories.map { subcategory in
                    guard rescanned.contains(subcategory.id) else { return subcategory }
                    let group = found[subcategory.id] ?? CleanupScanSubcategory(
                        id: subcategory.id,
                        title: subcategory.title,
                        risk: subcategory.risk,
                        recommendation: subcategory.recommendation,
                        reason: subcategory.reason,
                        candidates: []
                    )
                    return CleanupScanSubcategory(
                        id: group.id,
                        title: group.title,
                        risk: group.risk,
                        recommendation: group.recommendation,
                        reason: group.reason,
                        candidates: group.candidates.filter { candidate in
                            guard claims.claim(candidate) else {
                                deduplicated.append(ScanIssue(
                                    ruleID: candidate.ruleID,
                                    path: candidate.snapshot.standardizedPath,
                                    kind: .hardLinkDeduplicated
                                ))
                                return false
                            }
                            return true
                        }
                    )
                }
            )
        }

        let reports = Dictionary(grouping: rescan.permissions.filter { rescanned.contains($0.ruleID) }, by: \.ruleID)
        var replacedReports = Set<String>()
        let mergedPermissions = permissions.flatMap { report -> [CleanupPermissionReport] in
            guard rescanned.contains(report.ruleID) else { return [report] }
            guard replacedReports.insert(report.ruleID).inserted else { return [] }
            return reports[report.ruleID] ?? []
        }
        let mergedIssues = issues.filter { issue in issue.ruleID.map { !rescanned.contains($0) } ?? true }
            + rescan.issues.filter { issue in issue.ruleID.map(rescanned.contains) ?? true }
            + deduplicated
        let candidates = mergedCategories.flatMap(\.candidates)
        let limited = mergedIssues.contains { $0.kind.limitsScanCoverage }
            || mergedPermissions.contains { $0.status == .permissionDenied || $0.status == .unreadable }
            || candidates.contains { !$0.measurementCompleteness.isComplete }

        var ignoredPathsByRule = metrics.ignoredPathsByRule.filter { !rescanned.contains($0.key) }
        for (rule, paths) in rescan.metrics.ignoredPathsByRule where rescanned.contains(rule) {
            ignoredPathsByRule[rule] = paths
        }
        let ignoredCount = Set(ignoredPathsByRule.values.flatMap { $0 }).count

        return ScanSession(
            id: id,
            rulesVersion: rulesVersion,
            startedAt: startedAt,
            completedAt: rescan.completedAt,
            outcome: outcome == .cancelled ? .cancelled : limited ? .partial : .complete,
            categories: mergedCategories,
            issues: mergedIssues,
            permissions: mergedPermissions,
            metrics: ScanMetrics(
                ignoredItemCount: ignoredCount,
                ignoredPathsByRule: ignoredPathsByRule,
                visitedEntryCount: metrics.visitedEntryCount + rescan.metrics.visitedEntryCount,
                visitedDirectoryCount: metrics.visitedDirectoryCount + rescan.metrics.visitedDirectoryCount,
                candidateCount: candidates.count,
                deduplicatedIdentityCount: metrics.deduplicatedIdentityCount
                    + rescan.metrics.deduplicatedIdentityCount + deduplicated.count,
                estimatedCandidateBytes: CleanupByteCount.sum(candidates.map(\.estimatedSizeBytes)),
                completeMeasurementCandidateCount: candidates.filter { $0.measurementCompleteness.isComplete }.count,
                lowerBoundMeasurementCandidateCount: candidates.filter { $0.measurementCompleteness.isLowerBound }.count,
                failedMeasurementCandidateCount: candidates.filter { $0.measurementCompleteness.isFailed }.count,
                permissionFailureCount: mergedIssues.filter {
                    $0.kind == .permissionDenied || $0.kind == .unreadable
                }.count,
                cloudSkippedCount: mergedIssues.filter { $0.kind == .cloudPlaceholderSkipped }.count,
                timedOutRuleCount: Set(mergedIssues.compactMap { $0.kind == .timedOut ? $0.ruleID : nil }).count,
                truncatedCandidateCount: metrics.truncatedCandidateCount + rescan.metrics.truncatedCandidateCount,
                duration: metrics.duration + rescan.metrics.duration,
                notActionableCandidateCount: metrics.notActionableCandidateCount
                    + rescan.metrics.notActionableCandidateCount,
                excludedPathCandidateCount: metrics.excludedPathCandidateCount
                    + rescan.metrics.excludedPathCandidateCount,
                protectedDataCandidateCount: metrics.protectedDataCandidateCount
                    + rescan.metrics.protectedDataCandidateCount
            ),
            system: rescan.system ?? system,
            developerInactivityThresholdDays: developerInactivityThresholdDays,
            includedCategoryIDs: includedCategoryIDs,
            includedRuleIDs: includedRuleIDs,
            smartScanScopes: smartScanScopes,
            smartScanHealthSnapshot: smartScanHealthSnapshot,
            smartScanHealthStatus: smartScanHealthStatus,
            rulesProvenance: rulesProvenance ?? rescan.rulesProvenance
        )
    }
}

extension CleanupSelection {
    /// D104 G5: the selection once a rescan added rows to `previous`. What
    /// was selected or cleared stays so; only the added rows take the
    /// default selection (D47), as after a full scan.
    func addingDefaults(forRowsAddedTo previous: ScanSession, in merged: ScanSession) -> CleanupSelection {
        let mergedIDs = Set(merged.candidates.map(\.id))
        let addedIDs = mergedIDs.subtracting(previous.candidates.map(\.id))
        return CleanupSelection(
            selectedCandidateIDs: selectedCandidateIDs.intersection(mergedIDs)
                .union(CleanupSelection.defaults(in: merged).selectedCandidateIDs.intersection(addedIDs)),
            explicitlySelectedCandidateIDs: explicitlySelectedCandidateIDs
        )
    }
}

/// The files that listed rows account for, by identity and by path, so a
/// rescanned row inside, around or equal to one is not listed twice.
private struct ScanRowClaims {
    private var identities = Set<String>()
    private var paths = Set<String>()
    /// The same paths in byte order, for finding a claimed path inside another.
    private var orderedPaths = [String]()

    init(_ candidates: [ScanCandidate]) {
        for candidate in candidates {
            insert(candidate)
        }
    }

    /// Claims `candidate` unless a claimed row is the same file, contains it
    /// or lies inside it.
    mutating func claim(_ candidate: ScanCandidate) -> Bool {
        let path = candidate.snapshot.standardizedPath
        guard !identities.contains(candidate.snapshot.identity.deduplicationKey),
              !isAtOrInsideClaimedPath(path),
              !hasClaimedPath(inside: path) else { return false }
        insert(candidate)
        return true
    }

    private func isAtOrInsideClaimedPath(_ path: String) -> Bool {
        var current = path
        while true {
            if paths.contains(current) { return true }
            guard let slash = current.lastIndex(of: "/"), slash != current.startIndex else {
                return current != "/" && paths.contains("/")
            }
            current = String(current[..<slash])
        }
    }

    private func hasClaimedPath(inside path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let index = insertionIndex(of: prefix)
        return index < orderedPaths.count && orderedPaths[index].utf8.starts(with: prefix.utf8)
    }

    private mutating func insert(_ candidate: ScanCandidate) {
        identities.insert(candidate.snapshot.identity.deduplicationKey)
        let path = candidate.snapshot.standardizedPath
        guard paths.insert(path).inserted else { return }
        orderedPaths.insert(path, at: insertionIndex(of: path))
    }

    private func insertionIndex(of path: String) -> Int {
        var low = 0
        var high = orderedPaths.count
        while low < high {
            let middle = (low + high) / 2
            if orderedPaths[middle].utf8.lexicographicallyPrecedes(path.utf8) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

extension ScanIssueKind {
    /// Whether an issue of this kind leaves the scan's results incomplete
    /// (`ScanOutcome.partial`). Skipped links, deduplicated files and cloud
    /// placeholders are expected and do not.
    var limitsScanCoverage: Bool {
        switch self {
        case .permissionDenied, .vanished, .unreadable,
             .metadataUnavailable, .volumeUnavailable, .outsideAllowedRoot,
             .timedOut, .candidateNotActionable, .candidateContainsExcludedPath,
             .candidateContainsProtectedData:
            true
        case .symbolicLinkSkipped, .hardLinkDeduplicated,
             .cloudPlaceholderSkipped:
            false
        }
    }
}
