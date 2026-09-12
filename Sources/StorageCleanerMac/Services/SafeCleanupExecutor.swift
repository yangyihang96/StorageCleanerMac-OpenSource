import AppKit
import CryptoKit
import Darwin
import Foundation

struct CleanupExecutionContext: Sendable {
    let featureConfiguration: CleanupFeatureConfiguration
    let activeSessionID: ScanSessionID
    let activeRules: CleanupRuleSet
    let userHomeURL: URL
    let excludedURLs: [URL]
    let approvedPlanItemIDs: Set<UUID>?
}

protocol CleanupMoving: Sendable {
    func moveToTrash(_ url: URL) async throws -> URL
    func moveToQuarantine(_ url: URL, planID: CleanPlanID, itemID: UUID) async throws -> URL
}

protocol CleanupVolumeChecking: Sendable {
    func isAvailable(volumeIdentifier: String) async -> Bool
}

protocol CleanupRunningApplicationChecking: Sendable {
    func isRunning(bundleIdentifier: String) async -> Bool
    func isRunning(applicationURL: URL) async -> Bool
}

extension CleanupRunningApplicationChecking {
    func isRunning(applicationURL _: URL) async -> Bool { false }
}

protocol CleanupCapacityReading: Sendable {
    func availableCapacity(at url: URL) async -> Int64?
}

protocol CleanupContentDigestReading: Sendable {
    func sha256(at url: URL) throws -> Data
}

struct FoundationCleanupContentDigestReader: CleanupContentDigestReading {
    private static let chunkSize = 1024 * 1024

    func sha256(at url: URL) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw CleanupFileSystemError.vanished }
            if errno == EACCES || errno == EPERM { throw CleanupFileSystemError.permissionDenied }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }
}

enum CleanupMoveError: Error {
    case invalidResult
    case unsafeQuarantineRoot
    case destinationExists
    case crossVolume
}

private struct DeveloperActivityProbeError: Error {
    let reason: CleanSkipReason
}

struct FoundationCleanupMover: CleanupMoving {
    let quarantineRootURL: URL
    let userHomeURL: URL

    init(
        quarantineRootURL: URL = CleanupQuarantineLocation.defaultURL,
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.quarantineRootURL = quarantineRootURL
        self.userHomeURL = userHomeURL
    }

    func moveToTrash(_ url: URL) async throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL = resultingURL as URL?, resultingURL.isFileURL else {
            throw CleanupMoveError.invalidResult
        }
        return resultingURL.standardizedFileURL
    }

    func moveToQuarantine(
        _ url: URL,
        planID: CleanPlanID,
        itemID: UUID
    ) async throws -> URL {
        let homePath = PathSafety.lexicalPath(userHomeURL.path)
        let rootPath = PathSafety.lexicalPath(quarantineRootURL.path)
        guard rootPath != homePath,
              PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: false) else {
            throw CleanupMoveError.unsafeQuarantineRoot
        }

        try FileManager.default.createDirectory(
            at: quarantineRootURL,
            withIntermediateDirectories: true
        )
        guard !PathSafety.containsSymbolicLinkComponent(in: rootPath),
              PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: true) else {
            throw CleanupMoveError.unsafeQuarantineRoot
        }

        let planDirectory = quarantineRootURL
            .appendingPathComponent(planID.rawValue.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: planDirectory,
            withIntermediateDirectories: true
        )
        guard !PathSafety.containsSymbolicLinkComponent(in: planDirectory.path),
              PathSafety.isContained(
                planDirectory.path,
                in: rootPath,
                resolvingSymlinks: true
              ) else {
            throw CleanupMoveError.unsafeQuarantineRoot
        }

        let destinationName = itemID.uuidString
        let destinationURL = planDirectory.appendingPathComponent(destinationName)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw CleanupMoveError.destinationExists
        }

        let directoryDescriptor = open(
            planDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw CleanupMoveError.unsafeQuarantineRoot
        }
        defer { close(directoryDescriptor) }

        let result = url.withUnsafeFileSystemRepresentation { sourcePath in
            destinationName.withCString { destinationPath in
                renameat(AT_FDCWD, sourcePath, directoryDescriptor, destinationPath)
            }
        }
        guard result == 0 else {
            if errno == EXDEV {
                throw CleanupMoveError.crossVolume
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destinationURL
    }
}

enum CleanupQuarantineLocation {
    static var defaultURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("CleanupQuarantine", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}

struct FoundationCleanupVolumeChecker: CleanupVolumeChecking {
    func isAvailable(volumeIdentifier: String) async -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: []
        ) ?? []
        return volumes.contains {
            let identifier = try? $0.resourceValues(forKeys: keys).volumeIdentifier
            return identifier.map { String(describing: $0) } == volumeIdentifier
        }
    }
}

struct FoundationCleanupRunningApplicationChecker: CleanupRunningApplicationChecking {
    func isRunning(bundleIdentifier: String) async -> Bool {
        await MainActor.run {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty
        }
    }

    func isRunning(applicationURL: URL) async -> Bool {
        let targetPath = applicationURL.standardizedFileURL.path
        return await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { application in
                application.bundleURL?.standardizedFileURL.path == targetPath
            }
        }
    }
}

struct FoundationCleanupCapacityReader: CleanupCapacityReading {
    func availableCapacity(at url: URL) async -> Int64? {
        try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }
}

actor SafeCleanupExecutor {
    private let metadataReader: any ReadOnlyFileSystem
    private let contentDigestReader: any CleanupContentDigestReading
    private let mover: any CleanupMoving
    private let volumeChecker: any CleanupVolumeChecking
    private let runningApplicationChecker: any CleanupRunningApplicationChecking
    private let capacityReader: any CleanupCapacityReading
    private let coordinator: HeavyWorkCoordinator
    private var consumedPlanIDs = Set<CleanPlanID>()

    init(
        metadataReader: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem(),
        contentDigestReader: any CleanupContentDigestReading = FoundationCleanupContentDigestReader(),
        mover: any CleanupMoving = FoundationCleanupMover(),
        volumeChecker: any CleanupVolumeChecking = FoundationCleanupVolumeChecker(),
        runningApplicationChecker: any CleanupRunningApplicationChecking =
            FoundationCleanupRunningApplicationChecker(),
        capacityReader: any CleanupCapacityReading = FoundationCleanupCapacityReader(),
        coordinator: HeavyWorkCoordinator
    ) {
        self.metadataReader = metadataReader
        self.contentDigestReader = contentDigestReader
        self.mover = mover
        self.volumeChecker = volumeChecker
        self.runningApplicationChecker = runningApplicationChecker
        self.capacityReader = capacityReader
        self.coordinator = coordinator
    }

    func preflight(
        plan: CleanPlan,
        context: CleanupExecutionContext
    ) async -> CleanPreflightReport {
        if context.featureConfiguration.mode != .v2Full {
            return CleanPreflightReport(
                planID: plan.id,
                checkedAt: Date(),
                items: [],
                failure: CleanFailure(code: .featureDisabled, detailCode: nil)
            )
        }
        guard !consumedPlanIDs.contains(plan.id),
              plan.sessionID == context.activeSessionID,
              plan.rulesVersion == context.activeRules.rulesVersion else {
            return CleanPreflightReport(
                planID: plan.id,
                checkedAt: Date(),
                items: [],
                failure: CleanFailure(code: .planIntegrityFailed, detailCode: nil)
            )
        }

        var results = [CleanPreflightItem]()
        for item in plan.items {
            let reason = await skipReason(for: item, context: context)
            results.append(CleanPreflightItem(
                planItemID: item.id,
                status: reason.map(CleanPreflightItemStatus.skipped) ?? .ready
            ))
        }
        return CleanPreflightReport(
            planID: plan.id,
            checkedAt: Date(),
            items: results,
            failure: nil
        )
    }

    func execute(
        plan: CleanPlan,
        context: CleanupExecutionContext,
        progress: @escaping @Sendable (CleanupExecutionProgress) async -> Void
    ) async -> CleanReport {
        let startedAt = Date()
        guard context.featureConfiguration.mode == .v2Full else {
            return terminalFailureReport(
                plan: plan,
                startedAt: startedAt,
                code: .featureDisabled
            )
        }
        guard plan.sessionID == context.activeSessionID,
              plan.rulesVersion == context.activeRules.rulesVersion,
              !consumedPlanIDs.contains(plan.id) else {
            return terminalFailureReport(
                plan: plan,
                startedAt: startedAt,
                code: .planIntegrityFailed
            )
        }
        let planItemIDs = Set(plan.items.map(\.id))
        guard let approvedPlanItemIDs = context.approvedPlanItemIDs,
              !approvedPlanItemIDs.isEmpty,
              approvedPlanItemIDs.isSubset(of: planItemIDs) else {
            return terminalFailureReport(
                plan: plan,
                startedAt: startedAt,
                code: .planIntegrityFailed
            )
        }

        consumedPlanIDs.insert(plan.id)
        let lease: HeavyWorkCoordinator.Lease
        do {
            lease = try await coordinator.acquire(owner: .cleanup)
        } catch {
            return terminalFailureReport(
                plan: plan,
                startedAt: startedAt,
                code: .coordinatorBusy
            )
        }
        let capacityBefore = await capacityReader.availableCapacity(at: context.userHomeURL)
        var reportItems = [CleanReportItem]()
        var cancelled = false

        await progress(progressSnapshot(plan: plan, items: reportItems, currentRuleID: nil))
        for (index, item) in plan.items.enumerated() {
            if Task.isCancelled {
                cancelled = true
                reportItems.append(contentsOf: plan.items[index...].map {
                    reportItem(for: $0, outcome: .notProcessed)
                })
                break
            }

            do {
                try await coordinator.requireValid(lease, owner: .cleanup)
            } catch {
                reportItems.append(reportItem(
                    for: item,
                    outcome: .failed(CleanFailure(
                        code: .planIntegrityFailed,
                        detailCode: "invalid-lease"
                    ))
                ))
                reportItems.append(contentsOf: plan.items.dropFirst(index + 1).map {
                    reportItem(for: $0, outcome: .notProcessed)
                })
                break
            }

            if let reason = await skipReason(for: item, context: context) {
                reportItems.append(reportItem(for: item, outcome: .skipped(reason)))
                await progress(progressSnapshot(
                    plan: plan,
                    items: reportItems,
                    currentRuleID: item.ruleID
                ))
                continue
            }

            // The second read is deliberately adjacent to the system move.
            // The public Trash API is path based, so this narrows but cannot
            // eliminate the same-user replacement window.
            if let reason = await skipReason(for: item, context: context) {
                reportItems.append(reportItem(for: item, outcome: .skipped(reason)))
                await progress(progressSnapshot(
                    plan: plan,
                    items: reportItems,
                    currentRuleID: item.ruleID
                ))
                continue
            }

            do {
                let resultingURL: URL
                switch plan.disposition {
                case .trash:
                    resultingURL = try await mover.moveToTrash(item.sourceURL)
                case .quarantine:
                    resultingURL = try await mover.moveToQuarantine(
                        item.sourceURL,
                        planID: plan.id,
                        itemID: item.id
                    )
                }

                let movedSnapshot = try? metadataReader.snapshot(at: resultingURL)
                let verification: CleanupMoveVerification
                if let movedSnapshot {
                    verification = movedSnapshot.identity == item.expectedSnapshot.identity
                        ? .identityVerified
                        : .identityMismatch
                } else {
                    verification = .destinationMetadataUnavailable
                }
                let receipt = CleanupMoveReceipt(
                    originalPath: item.expectedSnapshot.standardizedPath,
                    resultingItemURL: resultingURL.standardizedFileURL,
                    disposition: plan.disposition,
                    movedIdentity: movedSnapshot?.identity,
                    verification: verification,
                    movedAt: Date()
                )
                reportItems.append(reportItem(for: item, outcome: .moved(receipt)))
            } catch {
                reportItems.append(reportItem(
                    for: item,
                    outcome: .failed(cleanFailure(for: error, disposition: plan.disposition))
                ))
            }
            await progress(progressSnapshot(
                plan: plan,
                items: reportItems,
                currentRuleID: item.ruleID
            ))
        }

        let capacityAfter = await capacityReader.availableCapacity(at: context.userHomeURL)
        let report = makeReport(
            plan: plan,
            startedAt: startedAt,
            items: reportItems,
            cancelled: cancelled,
            availableSpaceDeltaBytes: capacityDelta(before: capacityBefore, after: capacityAfter)
        )
        await coordinator.release(lease)
        return report
    }

    private func skipReason(
        for item: CleanPlanItem,
        context: CleanupExecutionContext
    ) async -> CleanSkipReason? {
        if let approvedPlanItemIDs = context.approvedPlanItemIDs,
           !approvedPlanItemIDs.contains(item.id) {
            return .preflightNotApproved
        }
        guard item.measurementCompleteness.isComplete else {
            return .measurementIncomplete
        }
        if let evidence = item.verifiedDuplicateEvidence {
            return verifiedDuplicateSkipReason(
                for: item,
                evidence: evidence,
                context: context
            )
        }
        guard item.action.movesToTrash,
              let rule = context.activeRules.rules.first(where: { $0.id == item.ruleID }),
              rule.measurementRequirement == .complete,
              rule.allowsManualSelection,
              rule.selectionPolicyVersion == item.ruleSelectionPolicyVersion,
              rule.requiredClosedBundleIDs == item.requiredClosedBundleIDs,
              !item.reasonCodes.isEmpty,
              item.reasonCodes.contains(item.reasonCode) else {
            return .rulesChanged
        }
        let developerDecision: DeveloperCleanupAgeDecision?
        if let thresholdDays = item.developerInactivityThresholdDays,
           let referenceDate = item.developerScanReferenceDate {
            developerDecision = DeveloperCleanupAgePolicy.decision(
                for: rule,
                latestModificationTimeNanoseconds:
                    item.latestContentModificationTimeNanoseconds,
                measurementCompleteness: item.measurementCompleteness,
                referenceDate: referenceDate,
                thresholdDays: thresholdDays
            )
        } else {
            developerDecision = nil
        }
        let matchesStaticRule = developerDecision == nil
            && rule.risk == item.riskLevel
            && rule.action == item.action
            && rule.executionEligibility == item.executionEligibility
            && rule.reasonKey == item.reasonCode
        let matchesDeveloperPolicy: Bool
        if let developerDecision,
           let thresholdDays = item.developerInactivityThresholdDays {
            let requiredEvidence = DeveloperCleanupAgePolicy.evidenceCodes(
                for: developerDecision,
                latestModificationTimeNanoseconds:
                    item.latestContentModificationTimeNanoseconds,
                thresholdDays: thresholdDays
            )
            matchesDeveloperPolicy = item.riskLevel == developerDecision.risk
                && item.action == developerDecision.action
                && item.executionEligibility == developerDecision.executionEligibility
                && item.reasonCode == developerDecision.reasonCode
                && requiredEvidence.allSatisfy(item.reasonCodes.contains)
        } else {
            matchesDeveloperPolicy = false
        }
        guard matchesStaticRule || matchesDeveloperPolicy else {
            return .rulesChanged
        }
        let isSafeItem = item.riskLevel == .safe
            && item.action == .moveToTrash
            && item.executionEligibility == .eligible
            && (developerDecision?.risk == .safe || matchesStaticRule)
        let isReviewedItem = item.riskLevel == .reviewOnly
            && item.action == .moveToTrashAfterReview
            && item.executionEligibility == .eligibleAfterReview
            && (developerDecision?.risk == .reviewOnly || matchesStaticRule)
            && item.explicitUserSelection
        let isProtectedApplication = item.riskLevel == .protected
            && item.action == .moveToTrashAfterProtectedReview
            && item.executionEligibility == .eligibleAfterProtectedReview
            && rule.risk == .protected
            && isApprovedProtectedApplication(item, rule: rule)
            && item.explicitUserSelection
        let isProtectedDeveloperItem = item.riskLevel == .protected
            && item.action == .moveToTrashAfterProtectedReview
            && item.executionEligibility == .eligibleAfterProtectedReview
            && developerDecision?.risk == .protected
            && item.explicitUserSelection
        guard isSafeItem || isReviewedItem
            || isProtectedApplication || isProtectedDeveloperItem else {
            return .rulesChanged
        }

        let sourcePath = PathSafety.lexicalPath(item.sourceURL.path)
        let rootPath = PathSafety.lexicalPath(item.allowedRootURL.path)
        let homePath = PathSafety.lexicalPath(context.userHomeURL.path)
        let isApprovedApplicationsRoot = isProtectedApplication
            && rule.root.kind == .applicationsDirectory
            && rule.effectiveCandidateScope == .immediateChildren
            && rootPath == "/Applications"
            && PathSafety.lexicalPath(
                item.sourceURL.deletingLastPathComponent().path
            ) == rootPath
            && item.sourceURL.pathExtension.lowercased() == "app"
            && isApprovedProtectedApplication(item, rule: rule)
        guard item.sourceURL.isFileURL,
              item.allowedRootURL.isFileURL,
              sourcePath != rootPath,
              PathSafety.isContained(sourcePath, in: rootPath, resolvingSymlinks: false),
              isApprovedApplicationsRoot
                || PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: false) else {
            return .pathOutsideAllowedRoot
        }

        let excludedPaths = context.excludedURLs.map {
            PathSafety.lexicalPath($0.path)
        }
        if ScanExclusionService.intersectsExcludedTree(
            sourcePath,
            excludedPaths: excludedPaths
        ) {
            return .excludedByUser
        }

        let current: FileSnapshot
        do {
            current = try metadataReader.snapshot(at: item.sourceURL)
        } catch CleanupFileSystemError.permissionDenied {
            return .permissionChanged
        } catch CleanupFileSystemError.vanished {
            return await volumeChecker.isAvailable(
                volumeIdentifier: item.expectedSnapshot.volumeIdentifier
            ) ? .itemMissing : .volumeUnavailable
        } catch {
            return .permissionChanged
        }

        guard current.identity.entryKind != .symbolicLink,
              !current.hasSymbolicLinkComponent else {
            return .symbolicLinkDetected
        }
        guard PathSafety.isContained(
            current.standardizedPath,
            in: rootPath,
            resolvingSymlinks: true
        ), isApprovedApplicationsRoot || PathSafety.isContained(
            current.standardizedPath,
            in: homePath,
            resolvingSymlinks: true
        ) else {
            return .pathOutsideAllowedRoot
        }
        guard current.identity.entryKind == item.expectedSnapshot.identity.entryKind else {
            return .entryKindChanged
        }
        guard current.identity == item.expectedSnapshot.identity else {
            return .identityChanged
        }
        guard current.volumeIdentifier == item.expectedSnapshot.volumeIdentifier else {
            return .volumeChanged
        }
        guard current.isWritableVolume else {
            return .volumeReadOnly
        }
        guard !current.isCloudPlaceholder,
              current.isCloudItem == item.expectedSnapshot.isCloudItem else {
            return .cloudStateChanged
        }
        for bundleIdentifier in item.requiredClosedBundleIDs {
            if await runningApplicationChecker.isRunning(bundleIdentifier: bundleIdentifier) {
                return .relatedAppStillRunning
            }
        }
        if developerDecision != nil,
           let reason = developerActivitySkipReason(
               for: item,
               rule: rule,
               current: current,
               rootPath: rootPath,
               homePath: homePath
           ) {
            return reason
        }
        if isProtectedApplication {
            if await runningApplicationChecker.isRunning(applicationURL: item.sourceURL) {
                return .relatedAppStillRunning
            }
            if rule.effectiveRequiresDuplicateBundleIdentifier {
                guard !item.protectedRetainedCopies.isEmpty else {
                    return .duplicateEvidenceInvalid
                }
                for retained in item.protectedRetainedCopies {
                    guard let current = try? metadataReader.snapshot(at: retained.url),
                          matchesProtectedRetainedSnapshot(
                              current,
                              expected: retained.expectedSnapshot
                          ),
                          current.identity != item.expectedSnapshot.identity,
                          current.identity.entryKind == .directory,
                          retained.url.pathExtension.lowercased() == "app",
                          retained.url.deletingLastPathComponent().standardizedFileURL.path
                            == item.allowedRootURL.standardizedFileURL.path else {
                        return .duplicateRetainedCopyChanged
                    }
                }
            }
        }
        return nil
    }

    private func developerActivitySkipReason(
        for item: CleanPlanItem,
        rule: CleanupRule,
        current: FileSnapshot,
        rootPath: String,
        homePath: String
    ) -> CleanSkipReason? {
        guard let expectedLatest = item.latestContentModificationTimeNanoseconds,
              item.developerInactivityThresholdDays != nil,
              item.developerScanReferenceDate != nil,
              DeveloperCleanupAgePolicy.applies(to: rule) else {
            return .rulesChanged
        }
        var seenIdentities = Set<String>()
        do {
            let latest = try latestModificationTime(
                at: item.sourceURL,
                snapshot: current,
                depth: 0,
                maximumDepth: rule.maximumDepth,
                rootPath: rootPath,
                homePath: homePath,
                seenIdentities: &seenIdentities
            )
            return latest == expectedLatest ? nil : .candidateBecameActive
        } catch let error as DeveloperActivityProbeError {
            return error.reason
        } catch CleanupFileSystemError.permissionDenied {
            return .permissionChanged
        } catch CleanupFileSystemError.vanished {
            return .candidateBecameActive
        } catch {
            return .permissionChanged
        }
    }

    private func latestModificationTime(
        at url: URL,
        snapshot: FileSnapshot,
        depth: Int,
        maximumDepth: Int,
        rootPath: String,
        homePath: String,
        seenIdentities: inout Set<String>
    ) throws -> Int64? {
        guard snapshot.identity.entryKind != .symbolicLink,
              !snapshot.hasSymbolicLinkComponent else {
            throw DeveloperActivityProbeError(reason: .symbolicLinkDetected)
        }
        guard PathSafety.isContained(
            snapshot.standardizedPath,
            in: rootPath,
            resolvingSymlinks: true
        ), PathSafety.isContained(
            snapshot.standardizedPath,
            in: homePath,
            resolvingSymlinks: true
        ) else {
            throw DeveloperActivityProbeError(reason: .pathOutsideAllowedRoot)
        }
        guard seenIdentities.insert(snapshot.identity.deduplicationKey).inserted else {
            return snapshot.modificationTimeNanoseconds
        }
        guard snapshot.identity.entryKind == .directory else {
            return snapshot.modificationTimeNanoseconds
        }
        guard depth < maximumDepth else {
            throw DeveloperActivityProbeError(reason: .measurementIncomplete)
        }

        var latest = snapshot.modificationTimeNanoseconds
        for childURL in try metadataReader.children(of: url) {
            let child = try metadataReader.aggregateSnapshot(at: childURL)
            if let childLatest = try latestModificationTime(
                at: childURL,
                snapshot: child,
                depth: depth + 1,
                maximumDepth: maximumDepth,
                rootPath: rootPath,
                homePath: homePath,
                seenIdentities: &seenIdentities
            ) {
                latest = max(latest ?? childLatest, childLatest)
            }
        }
        return latest
    }

    private func isApprovedProtectedApplication(
        _ item: CleanPlanItem,
        rule: CleanupRule
    ) -> Bool {
        if rule.effectiveRequiresDuplicateBundleIdentifier {
            return item.reasonCodes.contains("duplicate-bundle-identifier")
        }
        guard let bundleID = Bundle(url: item.sourceURL)?.bundleIdentifier else {
            return false
        }
        return rule.effectiveIncludedBundleIdentifiers.contains(bundleID)
            && item.reasonCodes.contains("application-bundle-identifier:\(bundleID)")
    }

    private func matchesProtectedRetainedSnapshot(
        _ current: FileSnapshot,
        expected: FileSnapshot
    ) -> Bool {
        current.identity == expected.identity
            && current.standardizedPath == expected.standardizedPath
            && current.volumeIdentifier == expected.volumeIdentifier
            && current.modificationTimeNanoseconds == expected.modificationTimeNanoseconds
            && current.isWritableVolume == expected.isWritableVolume
            && current.isCloudItem == expected.isCloudItem
            && current.isCloudPlaceholder == expected.isCloudPlaceholder
            && current.hasSymbolicLinkComponent == expected.hasSymbolicLinkComponent
    }


    private func verifiedDuplicateSkipReason(
        for item: CleanPlanItem,
        evidence: VerifiedDuplicateEvidence,
        context: CleanupExecutionContext
    ) -> CleanSkipReason? {
        let sentinelRule = context.activeRules.rules.first {
            $0.id == VerifiedDuplicateCleanPlanBuilder.ruleID
        }
        guard item.action == .moveToTrash,
              item.executionEligibility == .eligibleAfterReview,
              context.activeRules.rulesVersion == VerifiedDuplicateCleanPlanBuilder.rulesVersion,
              item.ruleID == VerifiedDuplicateCleanPlanBuilder.ruleID,
              item.ruleSelectionPolicyVersion == VerifiedDuplicateCleanPlanBuilder.selectionPolicyVersion,
              item.requiredClosedBundleIDs.isEmpty,
              sentinelRule?.selectionPolicyVersion == item.ruleSelectionPolicyVersion,
              sentinelRule?.risk == .reviewOnly,
              sentinelRule?.action == .revealOnly,
              sentinelRule?.allowsManualSelection == false,
              evidence.digest.count == VerifiedDuplicateEvidence.digestByteCount,
              evidence.contentSizeBytes == item.expectedSnapshot.logicalSizeBytes,
              !evidence.retainedCopies.isEmpty else {
            return .duplicateEvidenceInvalid
        }

        let sourcePath = PathSafety.lexicalPath(item.sourceURL.path)
        let rootPath = PathSafety.lexicalPath(item.allowedRootURL.path)
        let homePath = PathSafety.lexicalPath(context.userHomeURL.path)
        guard item.sourceURL.isFileURL,
              item.allowedRootURL.isFileURL,
              sourcePath != rootPath,
              PathSafety.isContained(sourcePath, in: rootPath, resolvingSymlinks: false),
              PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: false) else {
            return .pathOutsideAllowedRoot
        }
        let excludedPaths = context.excludedURLs.map { PathSafety.lexicalPath($0.path) }
        if ScanExclusionService.intersectsExcludedTree(sourcePath, excludedPaths: excludedPaths) {
            return .excludedByUser
        }

        guard let sourceSnapshot = try? metadataReader.snapshot(at: item.sourceURL) else {
            return .itemMissing
        }
        if let reason = verifiedSourceSnapshotSkipReason(
            current: sourceSnapshot,
            expected: item.expectedSnapshot,
            rootPath: rootPath,
            homePath: homePath
        ) {
            return reason
        }
        guard (try? contentDigestReader.sha256(at: item.sourceURL)) == evidence.digest else {
            return .duplicateContentChanged
        }
        guard (try? metadataReader.snapshot(at: item.sourceURL)) == item.expectedSnapshot else {
            return .identityChanged
        }

        var retainedPaths = Set<String>()
        var retainedIdentities = Set<FileIdentity>()
        for retained in evidence.retainedCopies {
            let retainedPath = PathSafety.lexicalPath(retained.url.path)
            guard retained.url.isFileURL,
                  retainedPath == PathSafety.lexicalPath(retained.expectedSnapshot.standardizedPath),
                  retainedPath != sourcePath,
                  retained.expectedSnapshot.identity != item.expectedSnapshot.identity,
                  retained.expectedSnapshot.logicalSizeBytes == evidence.contentSizeBytes,
                  retainedPaths.insert(retainedPath).inserted,
                  retainedIdentities.insert(retained.expectedSnapshot.identity).inserted else {
                return .duplicateEvidenceInvalid
            }
            guard let current = try? metadataReader.snapshot(at: retained.url),
                  current == retained.expectedSnapshot,
                  current.identity.entryKind == .regularFile,
                  !current.hasSymbolicLinkComponent,
                  !current.isCloudPlaceholder else {
                return .duplicateRetainedCopyChanged
            }
            guard (try? contentDigestReader.sha256(at: retained.url)) == evidence.digest else {
                return .duplicateContentChanged
            }
            guard (try? metadataReader.snapshot(at: retained.url)) == retained.expectedSnapshot else {
                return .duplicateRetainedCopyChanged
            }
        }
        return nil
    }

    private func verifiedSourceSnapshotSkipReason(
        current: FileSnapshot,
        expected: FileSnapshot,
        rootPath: String,
        homePath: String
    ) -> CleanSkipReason? {
        guard current.identity.entryKind != .symbolicLink,
              !current.hasSymbolicLinkComponent else {
            return .symbolicLinkDetected
        }
        guard PathSafety.isContained(current.standardizedPath, in: rootPath, resolvingSymlinks: true),
              PathSafety.isContained(current.standardizedPath, in: homePath, resolvingSymlinks: true) else {
            return .pathOutsideAllowedRoot
        }
        guard current.identity.entryKind == expected.identity.entryKind else {
            return .entryKindChanged
        }
        guard current.identity == expected.identity else { return .identityChanged }
        guard current.volumeIdentifier == expected.volumeIdentifier else { return .volumeChanged }
        guard current.isWritableVolume else { return .volumeReadOnly }
        guard !current.isCloudPlaceholder,
              current.isCloudItem == expected.isCloudItem else {
            return .cloudStateChanged
        }
        guard current.logicalSizeBytes == expected.logicalSizeBytes,
              current.modificationTimeNanoseconds == expected.modificationTimeNanoseconds else {
            return .duplicateContentChanged
        }
        return nil
    }

    private func reportItem(
        for item: CleanPlanItem,
        outcome: CleanItemOutcome
    ) -> CleanReportItem {
        CleanReportItem(
            id: UUID(),
            planItemID: item.id,
            ruleID: item.ruleID,
            sourcePath: item.expectedSnapshot.standardizedPath,
            estimatedBytes: item.estimatedSizeBytes,
            outcome: outcome
        )
    }

    private func progressSnapshot(
        plan: CleanPlan,
        items: [CleanReportItem],
        currentRuleID: String?
    ) -> CleanupExecutionProgress {
        CleanupExecutionProgress(
            planID: plan.id,
            processedItemCount: items.filter {
                if case .notProcessed = $0.outcome { return false }
                return true
            }.count,
            totalItemCount: plan.items.count,
            movedItemCount: items.filter {
                if case .moved = $0.outcome { return true }
                return false
            }.count,
            skippedItemCount: items.filter {
                if case .skipped = $0.outcome { return true }
                return false
            }.count,
            failedItemCount: items.filter {
                if case .failed = $0.outcome { return true }
                return false
            }.count,
            currentRuleID: currentRuleID
        )
    }

    private func cleanFailure(
        for error: Error,
        disposition: CleanupDisposition
    ) -> CleanFailure {
        let nsError = error as NSError
        let detailCode: String?
        switch nsError.code {
        case NSFileWriteNoPermissionError, Int(EACCES), Int(EPERM):
            detailCode = "permission-denied"
        case NSFileNoSuchFileError, Int(ENOENT):
            detailCode = "volume-or-item-unavailable"
        case Int(EXDEV):
            detailCode = "cross-volume"
        default:
            detailCode = nil
        }
        return CleanFailure(
            code: disposition == .trash ? .trashMoveFailed : .quarantineMoveFailed,
            detailCode: detailCode
        )
    }

    private func terminalFailureReport(
        plan: CleanPlan,
        startedAt: Date,
        code: CleanFailureCode
    ) -> CleanReport {
        let items = plan.items.map {
            reportItem(
                for: $0,
                outcome: .failed(CleanFailure(code: code, detailCode: nil))
            )
        }
        return makeReport(
            plan: plan,
            startedAt: startedAt,
            items: items,
            cancelled: false,
            availableSpaceDeltaBytes: nil
        )
    }

    private func makeReport(
        plan: CleanPlan,
        startedAt: Date,
        items: [CleanReportItem],
        cancelled: Bool,
        availableSpaceDeltaBytes: Int64?
    ) -> CleanReport {
        let moved = items.compactMap { item -> CleanupMoveReceipt? in
            guard case let .moved(receipt) = item.outcome else { return nil }
            return receipt
        }
        let skipped = items.filter {
            if case .skipped = $0.outcome { return true }
            return false
        }.count
        let failed = items.filter {
            if case .failed = $0.outcome { return true }
            return false
        }.count
        let notProcessed = items.filter {
            if case .notProcessed = $0.outcome { return true }
            return false
        }.count
        let movedBytes = CleanupByteCount.sum(items.compactMap {
            if case .moved = $0.outcome { return $0.estimatedBytes }
            return nil
        })
        let movedPlanItemIDs = Set(items.compactMap { item -> UUID? in
            guard case .moved = item.outcome else { return nil }
            return item.planItemID
        })
        let hasMovedDuplicateWithUnknownPhysicalSavings = plan.items.contains {
            movedPlanItemIDs.contains($0.id) && $0.verifiedDuplicateEvidence != nil
        }
        let reclaimableAfterEmptyingTrashBytes: Int64? = plan.disposition == .trash
            ? (hasMovedDuplicateWithUnknownPhysicalSavings ? nil : movedBytes)
            : 0
        let unverified = moved.filter { !$0.isRestorable }.count
        let outcome: CleanReportOutcome
        if cancelled || notProcessed > 0 {
            outcome = .cancelled
        } else if moved.isEmpty && failed > 0 {
            outcome = .failed
        } else if skipped > 0 || failed > 0 || unverified > 0 {
            outcome = .partiallyCompleted
        } else {
            outcome = .completed
        }

        return CleanReport(
            id: UUID(),
            planID: plan.id,
            sessionID: plan.sessionID,
            rulesVersion: plan.rulesVersion,
            disposition: plan.disposition,
            scanWasPartial: plan.scanWasPartial,
            startedAt: startedAt,
            completedAt: Date(),
            outcome: outcome,
            items: items,
            summary: CleanReportSummary(
                requestedItemCount: plan.items.count,
                movedItemCount: moved.count,
                skippedItemCount: skipped,
                failedItemCount: failed,
                notProcessedItemCount: notProcessed,
                unverifiedMoveCount: unverified,
                plannedBytes: plan.estimatedMovableBytes,
                movedToRecoverableLocationBytes: movedBytes,
                reclaimableAfterEmptyingTrashBytes: reclaimableAfterEmptyingTrashBytes,
                permanentlyFreedBytes: 0,
                availableSpaceDeltaBytes: availableSpaceDeltaBytes
            )
        )
    }

    private func capacityDelta(before: Int64?, after: Int64?) -> Int64? {
        guard let before, let after else { return nil }
        return after - before
    }
}

actor CleanupRecoveryService {
    private let metadataReader: any ReadOnlyFileSystem

    init(metadataReader: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()) {
        self.metadataReader = metadataReader
    }

    func restore(
        receipts: [CleanupMoveReceipt],
        userHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashURL: URL = CleanupService.userTrashURL(),
        quarantineRootURL: URL = CleanupQuarantineLocation.defaultURL
    ) async -> CleanupRecoveryReport {
        var results = [CleanupRecoveryItem]()
        for receipt in receipts {
            if Task.isCancelled {
                break
            }
            results.append(await restoreOne(
                receipt,
                userHomeURL: userHomeURL,
                trashURL: trashURL,
                quarantineRootURL: quarantineRootURL
            ))
        }
        return CleanupRecoveryReport(completedAt: Date(), items: results)
    }

    private func restoreOne(
        _ receipt: CleanupMoveReceipt,
        userHomeURL: URL,
        trashURL: URL,
        quarantineRootURL: URL
    ) async -> CleanupRecoveryItem {
        let fallback = CleanupRecoveryItem(
            id: UUID(),
            originalPath: receipt.originalPath,
            outcome: .failed
        )
        guard receipt.isRestorable, let movedIdentity = receipt.movedIdentity else {
            return fallback
        }

        let sourceURL = receipt.resultingItemURL.standardizedFileURL
        let destinationURL = URL(fileURLWithPath: receipt.originalPath).standardizedFileURL
        let homePath = PathSafety.lexicalPath(userHomeURL.path)
        let sourceRoot = receipt.disposition == .trash ? trashURL : quarantineRootURL
        let sourceRootPath = PathSafety.lexicalPath(sourceRoot.path)
        guard sourceURL.isFileURL,
              destinationURL.isFileURL,
              PathSafety.isContained(
                sourceURL.path,
                in: sourceRootPath,
                resolvingSymlinks: false
              ),
              PathSafety.isContained(
                destinationURL.path,
                in: homePath,
                resolvingSymlinks: false
              ),
              !PathSafety.isContained(
                destinationURL.path,
                in: sourceRootPath,
                resolvingSymlinks: false
              ) else {
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .unsafePath
            )
        }

        let sourceSnapshot: FileSnapshot
        do {
            sourceSnapshot = try metadataReader.snapshot(at: sourceURL)
        } catch CleanupFileSystemError.vanished {
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .missing
            )
        } catch {
            return fallback
        }
        guard !sourceSnapshot.hasSymbolicLinkComponent,
              sourceSnapshot.identity == movedIdentity else {
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .identityChanged
            )
        }

        do {
            _ = try metadataReader.snapshot(at: destinationURL)
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .conflict
            )
        } catch CleanupFileSystemError.vanished {
            // Expected: restore never overwrites an existing destination.
        } catch {
            return fallback
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        guard let parent = try? metadataReader.snapshot(at: parentURL),
              parent.identity.entryKind == .directory,
              !parent.hasSymbolicLinkComponent,
              PathSafety.isContained(
                parent.standardizedPath,
                in: homePath,
                resolvingSymlinks: true
              ) else {
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .unsafePath
            )
        }

        do {
            let immediateSource = try metadataReader.snapshot(at: sourceURL)
            guard !immediateSource.hasSymbolicLinkComponent,
                  immediateSource.identity == movedIdentity else {
                return CleanupRecoveryItem(
                    id: UUID(),
                    originalPath: receipt.originalPath,
                    outcome: .identityChanged
                )
            }
            do {
                _ = try metadataReader.snapshot(at: destinationURL)
                return CleanupRecoveryItem(
                    id: UUID(),
                    originalPath: receipt.originalPath,
                    outcome: .conflict
                )
            } catch CleanupFileSystemError.vanished {
                // Expected immediately before the non-overwriting move.
            }
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            let restored = try metadataReader.snapshot(at: destinationURL)
            guard restored.identity == movedIdentity else {
                return CleanupRecoveryItem(
                    id: UUID(),
                    originalPath: receipt.originalPath,
                    outcome: .identityChanged
                )
            }
            return CleanupRecoveryItem(
                id: UUID(),
                originalPath: receipt.originalPath,
                outcome: .restored
            )
        } catch {
            return fallback
        }
    }
}
