import Foundation

typealias SmartScanHealthOperation = @Sendable () async throws -> ComputerHealthSnapshot?

/// Executes selected read-only phases. It never changes cleanup eligibility,
/// preselection, confirmation, execution or recovery policies.
enum SmartScanReadOperation {
    static func run(request: CleanupScanRequest, scopes: Set<SmartScanScope>,
        rulesVersion: String, fileRuleCount: Int, cleanup: @escaping CleanupScanOperation,
        health: @escaping SmartScanHealthOperation,
        progress: @escaping @Sendable (CleanupScanProgress) async -> Void
    ) async throws -> ScanSession {
        try Task.checkCancellation()
        let startedAt = Date()
        let scansFiles = scopes.contains(.cleanupCandidates) || scopes.contains(.filesToReview)
        var session: ScanSession
        if scansFiles {
            session = try await cleanup(request) { value in
                let total = value.totalRuleCount + (scopes.contains(.health) ? 1 : 0)
                await progress(CleanupScanProgress(phase: value.phase,
                    currentRuleID: value.currentRuleID, currentRuleTitle: value.currentRuleTitle,
                    currentPath: value.currentPath,
                    currentRuleCompletedItemCount: value.currentRuleCompletedItemCount,
                    currentRuleTotalItemCount: value.currentRuleTotalItemCount,
                    completedRuleCount: value.completedRuleCount, totalRuleCount: total,
                    discoveredItemCount: value.discoveredItemCount, discoveredBytes: value.discoveredBytes,
                    groups: value.groups))
            }
        } else {
            session = ScanSession(id: ScanSessionID(), rulesVersion: rulesVersion,
                startedAt: startedAt, completedAt: Date(), outcome: .complete,
                categories: [], issues: [], permissions: [],
                metrics: ScanMetrics(visitedEntryCount: 0, candidateCount: 0,
                    deduplicatedIdentityCount: 0, estimatedCandidateBytes: 0, duration: 0),
                includedCategoryIDs: [], includedRuleIDs: [])
        }
        guard session.outcome != .cancelled, !Task.isCancelled else {
            return session.withSmartScan(scopes: scopes, health: nil, outcome: .cancelled)
        }
        guard scopes.contains(.health) else {
            return session.withSmartScan(scopes: scopes, health: nil)
        }
        let completed = scansFiles ? fileRuleCount : 0
        await progress(CleanupScanProgress(phase: .enumerating,
            currentRuleID: "smart.health", currentRuleTitle: SmartScanScope.health.title,
            completedRuleCount: completed, totalRuleCount: completed + 1,
            discoveredItemCount: session.metrics.candidateCount,
            discoveredBytes: session.metrics.estimatedCandidateBytes,
            groups: session.categories.flatMap { category in
                category.subcategories.map { group in
                    CleanupScanProgress.GroupSummary(id: group.id, title: group.title,
                        itemCount: group.candidates.count,
                        bytes: group.candidates.reduce(Int64(0)) { $0 + $1.snapshot.logicalSizeBytes },
                        risk: group.risk, state: group.candidates.isEmpty ? .clean : .found)
                }
            } + [CleanupScanProgress.GroupSummary(id: "smart.health", title: SmartScanScope.health.title,
                itemCount: 0, bytes: 0, state: .scanning)]))
        do {
            let snapshot = try await health()
            guard !Task.isCancelled else {
                return session.withSmartScan(scopes: scopes, health: nil, outcome: .cancelled)
            }
            return session.withSmartScan(scopes: scopes, health: snapshot)
        } catch is CancellationError {
            return session.withSmartScan(scopes: scopes, health: nil, outcome: .cancelled)
        } catch {
            // A health read is not a skipped file rule or a safety boundary.
            // Preserve the file outcome and issues, including real file limits.
            return session.withSmartScan(scopes: scopes, health: nil, healthStatus: .failed)
        }
    }
}

extension ScanSession {
    func withSmartScan(scopes: Set<SmartScanScope>, health: ComputerHealthSnapshot?,
        outcome: ScanOutcome? = nil, healthStatus: SmartScanHealthStatus? = nil
    ) -> ScanSession {
        let status: SmartScanHealthStatus
        if let healthStatus { status = healthStatus }
        else if !scopes.contains(.health) { status = .notRequested }
        else if (outcome ?? self.outcome) == .cancelled { status = .cancelled }
        else { status = health == nil ? .unavailable : .completed }
        return ScanSession(id: id, rulesVersion: rulesVersion, startedAt: startedAt,
            completedAt: health == nil ? completedAt : Date(), outcome: outcome ?? self.outcome, categories: categories,
            issues: issues, permissions: permissions, metrics: metrics,
            system: system, developerInactivityThresholdDays: developerInactivityThresholdDays,
            includedCategoryIDs: includedCategoryIDs, includedRuleIDs: includedRuleIDs,
            smartScanScopes: scopes, smartScanHealthSnapshot: health, smartScanHealthStatus: status,
            rulesProvenance: rulesProvenance)
    }
}
