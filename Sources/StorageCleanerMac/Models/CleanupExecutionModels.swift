import Foundation

struct CleanPlanID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum CleanupDisposition: String, Codable, CaseIterable, Sendable {
    case trash
    case quarantine
}

struct CleanPlanItem: Identifiable, Sendable {
    let id: UUID
    let candidateID: ScanCandidateID
    let ruleID: String
    let ruleSelectionPolicyVersion: Int
    let sourceURL: URL
    let allowedRootURL: URL
    let expectedSnapshot: FileSnapshot
    let action: CleanupRuleAction
    let riskLevel: CleanupRisk
    let executionEligibility: CleanupExecutionEligibility
    let measurementCompleteness: MeasurementCompleteness
    let requiredClosedBundleIDs: [String]
    let reasonCode: String
    let reasonCodes: [String]
    let explicitUserSelection: Bool
    let verifiedDuplicateEvidence: VerifiedDuplicateEvidence?
    let protectedRetainedCopies: [VerifiedDuplicateRetainedCopy]
    var latestContentModificationTimeNanoseconds: Int64? = nil
    var developerInactivityThresholdDays: Int? = nil
    var developerScanReferenceDate: Date? = nil

    var sourceRuleID: String { ruleID }
    var fileIdentity: FileIdentity { expectedSnapshot.identity }
    var estimatedSizeBytes: Int64 {
        max(0, expectedSnapshot.allocatedSizeBytes
            ?? expectedSnapshot.logicalSizeBytes)
    }
}

struct VerifiedDuplicateRetainedCopy: Hashable, Sendable {
    let url: URL
    let expectedSnapshot: FileSnapshot
}

struct VerifiedDuplicateEvidence: Hashable, Sendable {
    static let digestByteCount = 32

    let groupID: String
    let digest: Data
    let contentSizeBytes: Int64
    let retainedCopies: [VerifiedDuplicateRetainedCopy]
}

struct VerifiedDuplicatePlanRequest: Sendable {
    let sourceURL: URL
    let allowedRootURL: URL
    let expectedSnapshot: FileSnapshot
    let groupID: String
    let digest: Data
    let retainedCopies: [VerifiedDuplicateRetainedCopy]
}

struct VerifiedDuplicatePlanBundle: Sendable {
    let plan: CleanPlan
    let sessionID: ScanSessionID
    let activeRules: CleanupRuleSet
}

struct CleanPlan: Identifiable, Sendable {
    let id: CleanPlanID
    let sessionID: ScanSessionID
    let rulesVersion: String
    let createdAt: Date
    let scanWasPartial: Bool
    let disposition: CleanupDisposition
    let items: [CleanPlanItem]
    let estimatedMovableBytes: Int64

    var reviewItems: [CleanPlanItem] {
        items.filter { $0.riskLevel == .reviewOnly }
    }

    var reviewItemBytes: Int64 {
        CleanupByteCount.sum(reviewItems.map(\.estimatedSizeBytes))
    }

    var protectedItems: [CleanPlanItem] {
        items.filter { $0.riskLevel == .protected }
    }

    var protectedItemBytes: Int64 {
        CleanupByteCount.sum(protectedItems.map(\.estimatedSizeBytes))
    }

    fileprivate init(
        id: CleanPlanID,
        sessionID: ScanSessionID,
        rulesVersion: String,
        createdAt: Date,
        scanWasPartial: Bool,
        disposition: CleanupDisposition,
        items: [CleanPlanItem],
        estimatedMovableBytes: Int64
    ) {
        self.id = id
        self.sessionID = sessionID
        self.rulesVersion = rulesVersion
        self.createdAt = createdAt
        self.scanWasPartial = scanWasPartial
        self.disposition = disposition
        self.items = items
        self.estimatedMovableBytes = estimatedMovableBytes
    }
}

enum CleanPlanBuildError: Error, Equatable, LocalizedError {
    case cancelledSession
    case rulesChanged
    case emptySelection
    case staleSelection
    case invalidCandidate
    case duplicatePath
    case duplicateIdentity

    var errorDescription: String? {
        switch self {
        case .cancelledSession:
            L10n.text("已取消的扫描不能生成清理计划", "A cancelled scan cannot create a cleanup plan")
        case .rulesChanged:
            L10n.text("清理规则已变化，请重新扫描", "Cleanup rules changed; scan again")
        case .emptySelection:
            L10n.text("没有可执行的选中项目", "No executable items are selected")
        case .staleSelection:
            L10n.text("选择不属于当前扫描，请重新选择", "The selection does not belong to this scan")
        case .invalidCandidate:
            L10n.text("选择中包含不安全或已失效的项目", "The selection contains an unsafe or invalid item")
        case .duplicatePath, .duplicateIdentity:
            L10n.text("计划中发现重复项目，已拒绝执行", "Duplicate items were found in the plan")
        }
    }
}

enum VerifiedDuplicatePlanBuildError: Error, Equatable, LocalizedError {
    case emptySelection
    case invalidEvidence
    case noRetainedCopy
    case selectedCopyCannotBeRetained
    case duplicatePath
    case duplicateIdentity
    case targetOutsideUserHome

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            L10n.text("没有选中要安全处理的重复副本", "No duplicate copy is selected for safe handling")
        case .noRetainedCopy, .selectedCopyCannotBeRetained:
            L10n.text("每组必须至少保留一份未选中的完整副本", "Every group must retain at least one complete unselected copy")
        case .invalidEvidence:
            L10n.text("重复文件证据无效，请重新扫描", "Duplicate-file evidence is invalid; scan again")
        case .duplicatePath, .duplicateIdentity:
            L10n.text("重复文件计划包含重复路径或硬链接，已拒绝执行", "The duplicate plan contains a repeated path or hard link and was rejected")
        case .targetOutsideUserHome:
            L10n.text("当前安全处理仅支持用户目录内的副本", "Safe handling currently supports copies inside the user home folder only")
        }
    }
}

enum VerifiedDuplicateCleanPlanBuilder {
    static let ruleID = "verified-duplicate-review-v1"
    static let rulesVersion = "verified-duplicate-plan-v1"
    static let selectionPolicyVersion = 1

    static func makePlan(
        requests: [VerifiedDuplicatePlanRequest],
        disposition: CleanupDisposition,
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) throws -> VerifiedDuplicatePlanBundle {
        guard !requests.isEmpty else { throw VerifiedDuplicatePlanBuildError.emptySelection }

        let homePath = PathSafety.lexicalPath(userHomeURL.path)
        let selectedPaths = Set(requests.map { PathSafety.lexicalPath($0.sourceURL.path) })
        let selectedIdentities = Set(requests.map(\.expectedSnapshot.identity))
        guard selectedPaths.count == requests.count else {
            throw VerifiedDuplicatePlanBuildError.duplicatePath
        }
        guard selectedIdentities.count == requests.count else {
            throw VerifiedDuplicatePlanBuildError.duplicateIdentity
        }

        var planItems = [CleanPlanItem]()
        for request in requests.sorted(by: {
            PathSafety.lexicalPath($0.sourceURL.path)
                .localizedStandardCompare(PathSafety.lexicalPath($1.sourceURL.path)) == .orderedAscending
        }) {
            let sourcePath = PathSafety.lexicalPath(request.sourceURL.path)
            let rootPath = PathSafety.lexicalPath(request.allowedRootURL.path)
            guard request.sourceURL.isFileURL,
                  request.allowedRootURL.isFileURL,
                  sourcePath != rootPath,
                  PathSafety.lexicalPath(request.expectedSnapshot.standardizedPath) == sourcePath,
                  PathSafety.isContained(sourcePath, in: rootPath, resolvingSymlinks: false),
                  PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: false),
                  request.expectedSnapshot.identity.entryKind == .regularFile,
                  request.expectedSnapshot.logicalSizeBytes > 0,
                  request.expectedSnapshot.isWritableVolume,
                  !request.expectedSnapshot.isCloudPlaceholder,
                  !request.expectedSnapshot.hasSymbolicLinkComponent else {
                throw VerifiedDuplicatePlanBuildError.targetOutsideUserHome
            }
            guard !request.groupID.trimmed.isEmpty,
                  request.digest.count == VerifiedDuplicateEvidence.digestByteCount,
                  !request.retainedCopies.isEmpty else {
                throw request.retainedCopies.isEmpty
                    ? VerifiedDuplicatePlanBuildError.noRetainedCopy
                    : VerifiedDuplicatePlanBuildError.invalidEvidence
            }

            var retainedPaths = Set<String>()
            var retainedIdentities = Set<FileIdentity>()
            for retained in request.retainedCopies {
                let retainedPath = PathSafety.lexicalPath(retained.url.path)
                guard retained.url.isFileURL,
                      retainedPath == PathSafety.lexicalPath(retained.expectedSnapshot.standardizedPath),
                      retained.expectedSnapshot.identity.entryKind == .regularFile,
                      retained.expectedSnapshot.logicalSizeBytes == request.expectedSnapshot.logicalSizeBytes,
                      !retained.expectedSnapshot.hasSymbolicLinkComponent,
                      !retained.expectedSnapshot.isCloudPlaceholder else {
                    throw VerifiedDuplicatePlanBuildError.invalidEvidence
                }
                guard !selectedPaths.contains(retainedPath),
                      !selectedIdentities.contains(retained.expectedSnapshot.identity) else {
                    throw VerifiedDuplicatePlanBuildError.selectedCopyCannotBeRetained
                }
                guard retainedPaths.insert(retainedPath).inserted else {
                    throw VerifiedDuplicatePlanBuildError.duplicatePath
                }
                guard retainedIdentities.insert(retained.expectedSnapshot.identity).inserted else {
                    throw VerifiedDuplicatePlanBuildError.duplicateIdentity
                }
            }

            planItems.append(CleanPlanItem(
                id: UUID(),
                candidateID: ScanCandidateID(),
                ruleID: ruleID,
                ruleSelectionPolicyVersion: selectionPolicyVersion,
                sourceURL: URL(fileURLWithPath: sourcePath),
                allowedRootURL: URL(fileURLWithPath: rootPath, isDirectory: true),
                expectedSnapshot: request.expectedSnapshot,
                action: .moveToTrash,
                riskLevel: .reviewOnly,
                executionEligibility: .eligibleAfterReview,
                measurementCompleteness: .complete,
                requiredClosedBundleIDs: [],
                reasonCode: "verified-duplicate-content-match",
                reasonCodes: ["verified-duplicate-content-match"],
                explicitUserSelection: true,
                verifiedDuplicateEvidence: VerifiedDuplicateEvidence(
                    groupID: request.groupID,
                    digest: request.digest,
                    contentSizeBytes: request.expectedSnapshot.logicalSizeBytes,
                    retainedCopies: request.retainedCopies
                ),
                protectedRetainedCopies: []
            ))
        }

        let sessionID = ScanSessionID()
        let rules = sentinelRuleSet()
        guard (try? CleanupRuleValidator.validate(rules)) != nil else {
            throw VerifiedDuplicatePlanBuildError.invalidEvidence
        }
        let plan = CleanPlan(
            id: CleanPlanID(),
            sessionID: sessionID,
            rulesVersion: rules.rulesVersion,
            createdAt: now,
            scanWasPartial: false,
            disposition: disposition,
            items: planItems,
            estimatedMovableBytes: CleanupByteCount.sum(planItems.map(\.expectedSnapshot.logicalSizeBytes))
        )
        return VerifiedDuplicatePlanBundle(plan: plan, sessionID: sessionID, activeRules: rules)
    }

    private static func sentinelRuleSet() -> CleanupRuleSet {
        CleanupRuleSet(
            schemaVersion: 2,
            rulesVersion: rulesVersion,
            rules: [
                CleanupRule(
                    id: ruleID,
                    selectionPolicyVersion: selectionPolicyVersion,
                    categoryID: "verified-duplicates",
                    categoryTitleKey: "verified-duplicates",
                    titleKey: "verified-duplicates",
                    root: CleanupRuleRoot(kind: .homeRelative, path: "Documents"),
                    maximumDepth: 0,
                    minimumAgeDays: 0,
                    minimumBytes: 0,
                    include: CleanupRuleMatch(
                        entryKinds: [.regularFile],
                        extensions: [],
                        nameMatcher: CleanupNameMatcher(mode: .any, values: [])
                    ),
                    exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
                    cloudPolicy: .skipPlaceholder,
                    risk: .reviewOnly,
                    recommendation: .advisoryOnly,
                    defaultSelection: .forbidden,
                    executionEligibility: .advisoryOnly,
                    measurementRequirement: .bestEffort,
                    allowsManualSelection: false,
                    action: .revealOnly,
                    requiredClosedBundleIDs: [],
                    reasonKey: "verified-duplicate-content-match"
                )
            ]
        )
    }
}

enum CleanPlanBuilder {
    static func makePlan(
        session: ScanSession,
        selection: CleanupSelection,
        activeRules: CleanupRuleSet,
        disposition: CleanupDisposition,
        now: Date = Date()
    ) throws -> CleanPlan {
        guard session.outcome != .cancelled else {
            throw CleanPlanBuildError.cancelledSession
        }
        guard session.rulesVersion == activeRules.rulesVersion else {
            throw CleanPlanBuildError.rulesChanged
        }
        let selectedIDs = selection.selectedCandidateIDs
        guard !selectedIDs.isEmpty else {
            throw CleanPlanBuildError.emptySelection
        }
        guard Set(session.candidates.map(\.id)).count == session.candidates.count else {
            throw CleanPlanBuildError.invalidCandidate
        }
        guard Set(activeRules.rules.map(\.id)).count == activeRules.rules.count,
              (try? CleanupRuleValidator.validate(activeRules)) != nil else {
            throw CleanPlanBuildError.rulesChanged
        }

        let candidatesByID = Dictionary(
            uniqueKeysWithValues: session.candidates.map { ($0.id, $0) }
        )
        guard selectedIDs.allSatisfy({ candidatesByID[$0] != nil }) else {
            throw CleanPlanBuildError.staleSelection
        }
        let rulesByID = Dictionary(
            uniqueKeysWithValues: activeRules.rules.map { ($0.id, $0) }
        )

        var seenPaths = Set<String>()
        var seenIdentities = Set<FileIdentity>()
        var items = [CleanPlanItem]()
        let selectedCandidates = selectedIDs.compactMap { candidatesByID[$0] }.sorted {
            PathSafety.lexicalPath($0.sourceURL.path)
                .localizedStandardCompare(PathSafety.lexicalPath($1.sourceURL.path))
                == .orderedAscending
        }
        for candidate in selectedCandidates {
            guard candidate.sessionID == session.id,
                  candidate.isSelectable,
                  candidate.measurementCompleteness.isComplete,
                  !candidate.snapshot.hasSymbolicLinkComponent,
                  candidate.snapshot.identity.entryKind != .symbolicLink,
                  candidate.snapshot.isWritableVolume,
                  !candidate.snapshot.isCloudPlaceholder,
                  let rule = rulesByID[candidate.ruleID],
                  rule.allowsManualSelection,
                  rule.measurementRequirement == .complete,
                  rule.selectionPolicyVersion == candidate.ruleSelectionPolicyVersion,
                  rule.requiredClosedBundleIDs == candidate.requiredClosedBundleIDs else {
                throw CleanPlanBuildError.invalidCandidate
            }

            let developerDecision = DeveloperCleanupAgePolicy.decision(
                for: rule,
                latestModificationTimeNanoseconds:
                    candidate.latestContentModificationTimeNanoseconds,
                measurementCompleteness: candidate.measurementCompleteness,
                referenceDate: session.startedAt,
                thresholdDays: session.developerInactivityThresholdDays
            )
            let candidateMatchesPolicy: Bool
            if let developerDecision {
                let requiredEvidence = DeveloperCleanupAgePolicy.evidenceCodes(
                    for: developerDecision,
                    latestModificationTimeNanoseconds:
                        candidate.latestContentModificationTimeNanoseconds,
                    thresholdDays: session.developerInactivityThresholdDays
                )
                candidateMatchesPolicy = candidate.risk == developerDecision.risk
                    && candidate.recommendation.level == developerDecision.recommendation
                    && candidate.recommendation.reasonCode == developerDecision.reasonCode
                    && candidate.defaultSelection == developerDecision.defaultSelection
                    && candidate.executionEligibility
                        == developerDecision.executionEligibility
                    && candidate.isManuallySelectable
                        == developerDecision.allowsManualSelection
                    && candidate.action == developerDecision.action
                    && requiredEvidence.allSatisfy(
                        candidate.recommendation.evidenceCodes.contains
                    )
            } else {
                candidateMatchesPolicy = rule.risk == candidate.risk
                    && rule.recommendation == candidate.recommendation.level
                    && rule.defaultSelection == candidate.defaultSelection
                    && rule.executionEligibility == candidate.executionEligibility
                    && rule.action == candidate.action
                    && rule.reasonKey == candidate.recommendation.reasonCode
                    && rule.allowsManualSelection == candidate.isManuallySelectable
            }
            guard candidateMatchesPolicy else {
                throw CleanPlanBuildError.invalidCandidate
            }

            let retainedCopies = protectedRetainedCopies(
                candidate: candidate,
                selectedIDs: selectedIDs,
                session: session
            )
            let isSafeItem = candidate.risk == .safe
                && candidate.action == .moveToTrash
                && candidate.executionEligibility == .eligible
                && (developerDecision?.risk == .safe
                    || (developerDecision == nil
                        && rule.risk == .safe
                        && rule.action == .moveToTrash
                        && rule.executionEligibility == .eligible))
            let isReviewedItem = candidate.risk == .reviewOnly
                && candidate.action == .moveToTrashAfterReview
                && candidate.executionEligibility == .eligibleAfterReview
                && (developerDecision?.risk == .reviewOnly
                    || (developerDecision == nil
                        && rule.risk == .reviewOnly
                        && rule.action == .moveToTrashAfterReview
                        && rule.executionEligibility == .eligibleAfterReview))
                && selection.isExplicitlySelected(candidate.id)
            let isProtectedApplication = candidate.risk == .protected
                && candidate.action == .moveToTrashAfterProtectedReview
                && candidate.executionEligibility == .eligibleAfterProtectedReview
                && rule.risk == .protected
                && rule.action == .moveToTrashAfterProtectedReview
                && rule.executionEligibility == .eligibleAfterProtectedReview
                && disposition == .trash
                && isApprovedProtectedApplication(candidate, rule: rule)
                && selection.isExplicitlySelected(candidate.id)
                && (!rule.effectiveRequiresDuplicateBundleIdentifier
                    || !retainedCopies.isEmpty)
            let isProtectedDeveloperItem = candidate.risk == .protected
                && candidate.action == .moveToTrashAfterProtectedReview
                && candidate.executionEligibility == .eligibleAfterProtectedReview
                && developerDecision?.risk == .protected
                && disposition == .trash
                && selection.isExplicitlySelected(candidate.id)
            guard isSafeItem || isReviewedItem
                || isProtectedApplication || isProtectedDeveloperItem else {
                throw CleanPlanBuildError.invalidCandidate
            }

            let sourcePath = PathSafety.lexicalPath(candidate.sourceURL.path)
            let rootPath = PathSafety.lexicalPath(candidate.allowedRootURL.path)
            guard candidate.sourceURL.isFileURL,
                  candidate.allowedRootURL.isFileURL,
                  PathSafety.lexicalPath(candidate.snapshot.standardizedPath) == sourcePath,
                  sourcePath != rootPath,
                  PathSafety.isContained(sourcePath, in: rootPath, resolvingSymlinks: false),
                  matchesRuleRoot(
                      sourcePath: sourcePath,
                      allowedRootPath: rootPath,
                      rule: rule
                  ) else {
                throw CleanPlanBuildError.invalidCandidate
            }
            guard seenPaths.insert(sourcePath).inserted else {
                throw CleanPlanBuildError.duplicatePath
            }
            guard seenIdentities.insert(candidate.snapshot.identity).inserted else {
                throw CleanPlanBuildError.duplicateIdentity
            }

            items.append(CleanPlanItem(
                id: UUID(),
                candidateID: candidate.id,
                ruleID: candidate.ruleID,
                ruleSelectionPolicyVersion: candidate.ruleSelectionPolicyVersion,
                sourceURL: URL(fileURLWithPath: sourcePath),
                allowedRootURL: URL(fileURLWithPath: rootPath),
                expectedSnapshot: candidate.snapshot,
                action: candidate.action,
                riskLevel: candidate.risk,
                executionEligibility: candidate.executionEligibility,
                measurementCompleteness: candidate.measurementCompleteness,
                requiredClosedBundleIDs: candidate.requiredClosedBundleIDs,
                reasonCode: candidate.recommendation.reasonCode,
                reasonCodes: [candidate.recommendation.reasonCode]
                    + candidate.recommendation.evidenceCodes,
                explicitUserSelection: selection.isExplicitlySelected(candidate.id),
                verifiedDuplicateEvidence: nil,
                protectedRetainedCopies: retainedCopies,
                latestContentModificationTimeNanoseconds:
                    candidate.latestContentModificationTimeNanoseconds,
                developerInactivityThresholdDays: developerDecision == nil
                    ? nil
                    : session.developerInactivityThresholdDays,
                developerScanReferenceDate: developerDecision == nil
                    ? nil
                    : session.startedAt
            ))
        }

        guard !items.isEmpty else {
            throw CleanPlanBuildError.emptySelection
        }
        return CleanPlan(
            id: CleanPlanID(),
            sessionID: session.id,
            rulesVersion: session.rulesVersion,
            createdAt: now,
            scanWasPartial: session.outcome == .partial,
            disposition: disposition,
            items: items,
            estimatedMovableBytes: CleanupByteCount.sum(
                items.map(\.estimatedSizeBytes)
            )
        )
    }

    private static func matchesRuleRoot(
        sourcePath: String,
        allowedRootPath: String,
        rule: CleanupRule
    ) -> Bool {
        switch rule.root.kind {
        case .applicationsDirectory:
            return rule.effectiveCandidateScope == .immediateChildren
                && allowedRootPath == "/Applications"
                && PathSafety.lexicalPath(
                    URL(fileURLWithPath: sourcePath).deletingLastPathComponent().path
                ) == allowedRootPath
                && URL(fileURLWithPath: sourcePath).pathExtension.lowercased() == "app"
                && (rule.effectiveRequiresDuplicateBundleIdentifier
                    || !rule.effectiveIncludedBundleIdentifiers.isEmpty)
        case .homeRelative:
            let comparedPath: String
            if rule.effectiveCandidateScope == .root {
                guard allowedRootPath == PathSafety.lexicalPath(
                    URL(fileURLWithPath: sourcePath).deletingLastPathComponent().path
                ) else { return false }
                comparedPath = sourcePath
            } else {
                comparedPath = allowedRootPath
            }
            let pathComponents = URL(fileURLWithPath: comparedPath).pathComponents
            let ruleComponents = rule.root.path.split(separator: "/").map(String.init)
            return pathComponents.count >= ruleComponents.count
                && Array(pathComponents.suffix(ruleComponents.count)) == ruleComponents
        }
    }

    private static func protectedRetainedCopies(
        candidate: ScanCandidate,
        selectedIDs: Set<ScanCandidateID>,
        session: ScanSession
    ) -> [VerifiedDuplicateRetainedCopy] {
        guard let groupCode = candidate.recommendation.evidenceCodes.first(where: {
            $0.hasPrefix("duplicate-bundle-group:")
        }) else { return [] }
        return session.candidates.compactMap {
            guard $0.id != candidate.id,
                  !selectedIDs.contains($0.id),
                  $0.recommendation.evidenceCodes.contains(groupCode) else { return nil }
            return VerifiedDuplicateRetainedCopy(
                url: $0.sourceURL,
                expectedSnapshot: $0.snapshot
            )
        }
    }

    private static func isApprovedProtectedApplication(
        _ candidate: ScanCandidate,
        rule: CleanupRule
    ) -> Bool {
        if rule.effectiveRequiresDuplicateBundleIdentifier {
            return candidate.recommendation.evidenceCodes.contains(
                "duplicate-bundle-identifier"
            ) && !candidate.recommendation.evidenceCodes.filter {
                $0.hasPrefix("duplicate-bundle-group:")
            }.isEmpty
        }
        let prefix = "application-bundle-identifier:"
        guard let evidence = candidate.recommendation.evidenceCodes.first(where: {
            $0.hasPrefix(prefix)
        }) else { return false }
        return rule.effectiveIncludedBundleIdentifiers.contains(
            String(evidence.dropFirst(prefix.count))
        )
    }
}

enum CleanSkipReason: String, Codable, Sendable {
    case preflightNotApproved
    case itemMissing
    case identityChanged
    case entryKindChanged
    case pathOutsideAllowedRoot
    case symbolicLinkDetected
    case volumeChanged
    case volumeUnavailable
    case volumeReadOnly
    case permissionChanged
    case excludedByUser
    case cloudStateChanged
    case relatedAppStillRunning
    case rulesChanged
    case measurementIncomplete
    case duplicateEvidenceInvalid
    case duplicateRetainedCopyChanged
    case duplicateContentChanged
    case candidateBecameActive
}

enum CleanPreflightItemStatus: Equatable, Sendable {
    case ready
    case skipped(CleanSkipReason)
}

struct CleanPreflightItem: Identifiable, Equatable, Sendable {
    var id: UUID { planItemID }
    let planItemID: UUID
    let status: CleanPreflightItemStatus
}

struct CleanPreflightReport: Equatable, Sendable {
    let planID: CleanPlanID
    let checkedAt: Date
    let items: [CleanPreflightItem]
    let failure: CleanFailure?

    var readyCount: Int {
        items.filter { $0.status == .ready }.count
    }

    var skippedCount: Int {
        items.count - readyCount
    }

    var isConfirmable: Bool {
        failure == nil && readyCount > 0
    }
}

enum CleanupMoveVerification: String, Codable, Sendable {
    case identityVerified
    case destinationMetadataUnavailable
    case identityMismatch
}

struct CleanupMoveReceipt: Codable, Equatable, Sendable {
    let originalPath: String
    let resultingItemURL: URL
    let disposition: CleanupDisposition
    let movedIdentity: FileIdentity?
    let verification: CleanupMoveVerification
    let movedAt: Date

    var isRestorable: Bool {
        movedIdentity != nil && verification == .identityVerified
    }
}

enum CleanFailureCode: String, Codable, Sendable {
    case persistenceFailed
    case moveOutcomeUnknown
    case trashMoveRejected
    case trashMoveFailed
    case quarantineMoveFailed
    case metadataReadFailed
    case planIntegrityFailed
    case featureDisabled
    case coordinatorBusy
    case unexpected
}

struct CleanFailure: Codable, Equatable, Sendable {
    let code: CleanFailureCode
    let detailCode: String?
}

enum CleanItemOutcome: Codable, Equatable, Sendable {
    case moved(CleanupMoveReceipt)
    case skipped(CleanSkipReason)
    case failed(CleanFailure)
    case notProcessed
}

struct CleanReportItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let planItemID: UUID
    let ruleID: String
    let sourcePath: String
    let estimatedBytes: Int64
    let outcome: CleanItemOutcome
}

enum CleanReportOutcome: String, Codable, Sendable {
    case completed
    case partiallyCompleted
    case cancelled
    case failed
}

struct CleanReportSummary: Codable, Equatable, Sendable {
    let requestedItemCount: Int
    let movedItemCount: Int
    let skippedItemCount: Int
    let failedItemCount: Int
    let notProcessedItemCount: Int
    let unverifiedMoveCount: Int
    let plannedBytes: Int64
    let movedToRecoverableLocationBytes: Int64
    let reclaimableAfterEmptyingTrashBytes: Int64?
    let permanentlyFreedBytes: Int64
    let availableSpaceDeltaBytes: Int64?
}

struct CleanReport: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let planID: CleanPlanID
    let sessionID: ScanSessionID
    let rulesVersion: String
    let disposition: CleanupDisposition
    let scanWasPartial: Bool
    let startedAt: Date
    let completedAt: Date
    var outcome: CleanReportOutcome
    let items: [CleanReportItem]
    let summary: CleanReportSummary
    var persistenceFailure: String? = nil
    /// Restore attempts stay with the original receipt; successful rows are never erased.
    var recoveryAttempts: [CleanupRecoveryReport]? = nil

    var restorableReceipts: [CleanupMoveReceipt] {
        items.compactMap {
            guard case let .moved(receipt) = $0.outcome, receipt.isRestorable,
                  !recoveryBlocksRetry(of: receipt.originalPath) else {
                return nil
            }
            return receipt
        }
    }

    func recoveryBlocksRetry(of path: String) -> Bool {
        (recoveryAttempts ?? []).flatMap(\.items).contains {
            $0.originalPath == path && ($0.outcome == .restored || $0.outcome == .outcomeUnknown)
        }
    }
}

struct CleanupExecutionProgress: Equatable, Sendable {
    let planID: CleanPlanID
    let processedItemCount: Int
    let totalItemCount: Int
    let movedItemCount: Int
    let skippedItemCount: Int
    let failedItemCount: Int
    let currentRuleID: String?
}

enum CleanupWorkflowState: Equatable, Sendable {
    case idle
    case results(sessionID: ScanSessionID)
    case buildingPlan(sessionID: ScanSessionID)
    case preflighting(planID: CleanPlanID)
    case awaitingConfirmation(planID: CleanPlanID)
    case executing(planID: CleanPlanID, progress: CleanupExecutionProgress)
    case cancellingExecution(planID: CleanPlanID)
    case completed(reportID: UUID)
    case failed
}

enum CleanupRecoveryItemOutcome: String, Codable, Sendable {
    case notProcessed
    case outcomeUnknown
    case restored
    case conflict
    case missing
    case identityChanged
    case unsafePath
    case failed
}

struct CleanupRecoveryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let originalPath: String
    let outcome: CleanupRecoveryItemOutcome
}

struct CleanupRecoveryReport: Codable, Equatable, Sendable {
    let completedAt: Date
    let items: [CleanupRecoveryItem]
    var attemptID: UUID? = nil
    var persistenceFailure: String? = nil

    var restoredCount: Int {
        items.filter { $0.outcome == .restored }.count
    }
}
