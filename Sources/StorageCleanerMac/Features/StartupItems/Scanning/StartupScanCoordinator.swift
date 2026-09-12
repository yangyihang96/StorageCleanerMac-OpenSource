import Foundation

struct StartupScanCoordinator: Sendable {
    private let primaryScanners: [any StartupItemScanning]
    private let secondaryScannerFactory: @Sendable (StartupScanContext) -> [any StartupItemScanning]
    private let attributionResolver: StartupAttributionResolver
    private let deduplicator: StartupItemDeduplicator
    private let merger: StartupItemMerger
    private let pathValidator: StartupPathValidator
    private let signatureVerifier: StartupCodeSignatureVerifier
    private let managementCapability: StartupItemsDomain.StartupManagementCapability?

    init(
        primaryScanners: [any StartupItemScanning]? = nil,
        secondaryScannerFactory: (@Sendable (StartupScanContext) -> [any StartupItemScanning])? = nil,
        attributionResolver: StartupAttributionResolver = StartupAttributionResolver(),
        deduplicator: StartupItemDeduplicator = StartupItemDeduplicator(),
        merger: StartupItemMerger = StartupItemMerger(),
        pathValidator: StartupPathValidator = StartupPathValidator(),
        signatureVerifier: StartupCodeSignatureVerifier = StartupCodeSignatureVerifier(),
        managementCapability: StartupItemsDomain.StartupManagementCapability? = nil
    ) {
        self.primaryScanners = primaryScanners ?? [
            LoginItemScanner(),
            LaunchdPlistScanner(location: .userLaunchAgents),
            LaunchdPlistScanner(location: .globalLaunchAgents),
            LaunchdPlistScanner(location: .systemLaunchAgents),
            LaunchdPlistScanner(location: .launchDaemons),
            LaunchdPlistScanner(location: .systemLaunchDaemons),
            BackgroundTaskManagementScanner(),
        ]
        self.secondaryScannerFactory = secondaryScannerFactory ?? { _ in
            [
                ServiceManagementScanner(),
                EmbeddedServiceScanner(),
                LaunchdRuntimeScanner(),
                PrivilegedHelperScanner(),
                OrphanedItemScanner(),
            ]
        }
        self.attributionResolver = attributionResolver
        self.deduplicator = deduplicator
        self.merger = merger
        self.pathValidator = pathValidator
        self.signatureVerifier = signatureVerifier
        self.managementCapability = managementCapability
    }

    func scan(
        context initialContext: StartupScanContext = StartupScanContext(),
        progress: StartupScanProgressHandler? = nil
    ) async throws -> StartupScanResult {
        try Task.checkCancellation()
        await progress?(StartupScanProgress(phase: .loginItems, discoveredCount: 0, message: L10n.text("正在扫描登录项", "Scanning login items")))
        async let indexTask = InstalledApplicationIndex.build(directories: initialContext.applicationDirectories)
        let primaryBatches = try await scanAll(primaryScanners, context: initialContext)
        try Task.checkCancellation()
        let primaryCount = primaryBatches.flatMap(\.candidates).count
        await progress?(StartupScanProgress(phase: .backgroundTasks, discoveredCount: primaryCount, message: L10n.text("正在扫描后台任务", "Scanning background tasks")))
        await progress?(StartupScanProgress(phase: .launchd, discoveredCount: primaryCount, message: L10n.text("正在读取 LaunchAgent 与 LaunchDaemon", "Reading LaunchAgents and LaunchDaemons")))
        let baseIndex = await indexTask
        try Task.checkCancellation()
        let primaryEvidence = primaryBatches.flatMap(\.candidates)
        let primaryIndex = await baseIndex.enrichingSigningIdentities(
            referencedBy: primaryEvidence
        )
        let primaryCandidates = primaryEvidence
            .map { attributionResolver.resolve($0, using: primaryIndex) }
        await progress?(StartupScanProgress(phase: .attribution, discoveredCount: primaryCandidates.count, message: L10n.text("正在匹配所属应用", "Matching parent applications")))

        var secondaryContext = initialContext
        secondaryContext.seedCandidates = primaryCandidates
        await progress?(StartupScanProgress(phase: .runtime, discoveredCount: primaryCandidates.count, message: L10n.text("正在检查运行状态", "Checking runtime state")))
        let secondaryBatches = try await scanAll(secondaryScannerFactory(secondaryContext), context: secondaryContext)
        try Task.checkCancellation()
        var allCandidates = primaryCandidates + secondaryBatches.flatMap(\.candidates)
        let index = await primaryIndex.enrichingSigningIdentities(referencedBy: allCandidates)
        allCandidates = allCandidates.map { attributionResolver.resolve($0, using: index) }
        await progress?(StartupScanProgress(phase: .signatures, discoveredCount: allCandidates.count, message: L10n.text("正在检查代码签名", "Checking code signatures")))
        allCandidates = await inspectSecurity(allCandidates)
        try Task.checkCancellation()
        let capabilityResolver = StartupItemsDomain.StartupCapabilityResolver(
            platform: managementCapability ?? .currentApplication(),
            currentUserID: initialContext.currentUserID,
            homeDirectory: initialContext.homeDirectory
        )
        allCandidates = allCandidates.map { candidate in
            var resolved = candidate
            resolved.actionCapability = capabilityResolver.capability(for: candidate)
            switch capabilityResolver.destination(for: candidate) {
            case .directlyManageable: resolved.state.management = .directlyManageable
            case .systemSettingsLoginItems: resolved.state.management = .manageableInSystemSettings
            case .administratorHelperUnavailable: resolved.state.management = .requiresAdministrator
            case .managedByOrganization: resolved.state.management = .managedByOrganization
            case .systemProtected: resolved.state.management = .systemProtected
            case .readOnly: resolved.state.management = .readOnly
            }
            return resolved
        }
        await progress?(StartupScanProgress(phase: .orphanDetection, discoveredCount: allCandidates.count, message: L10n.text("正在识别残留项目", "Identifying orphaned items")))
        let visibleCandidates = allCandidates.filter { candidate in
            if candidate.source == .embeddedService,
               candidate.state.registration == .notRegistered { return false }
            if candidate.source == .serviceManagement,
               candidate.state.registration == .notRegistered { return false }
            return true
        }
        let deduplicated = deduplicator.deduplicate(visibleCandidates)
        let items = merger.merge(deduplicated)
        let batches = primaryBatches + secondaryBatches
        let managedItemCoverageAvailable = initialContext.includeBackgroundTaskDiagnostic
            && batches.contains {
                $0.source == .backgroundTaskDiagnostic && $0.errorDescription == nil
            }
        let coverage = coverageReport(
            batches: batches,
            rawEvidenceCount: allCandidates.count,
            beforeDeduplication: visibleCandidates.count,
            candidates: deduplicated,
            items: items,
            managedItemCoverageAvailable: managedItemCoverageAvailable
        )
        await progress?(StartupScanProgress(phase: .completed, discoveredCount: deduplicated.count, message: L10n.text("扫描完成", "Scan complete")))
        return StartupScanResult(candidates: deduplicated, items: items, coverage: coverage)
    }

    private struct ScanBatch: Sendable {
        let source: StartupItemsDomain.ScanSource
        let identifier: String
        let candidates: [StartupItemsDomain.Candidate]
        let errorDescription: String?
    }

    private func scanAll(
        _ scanners: [any StartupItemScanning],
        context: StartupScanContext
    ) async throws -> [ScanBatch] {
        try await withThrowingTaskGroup(of: ScanBatch.self, returning: [ScanBatch].self) { group in
            for scanner in scanners {
                group.addTask {
                    do {
                        let candidates = try await scanner.scan(context: context)
                        return ScanBatch(
                            source: scanner.source,
                            identifier: scanner.coverageIdentifier,
                            candidates: candidates,
                            errorDescription: nil
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return ScanBatch(
                            source: scanner.source,
                            identifier: scanner.coverageIdentifier,
                            candidates: [],
                            errorDescription: error.localizedDescription
                        )
                    }
                }
            }
            var result = [ScanBatch]()
            for try await batch in group { result.append(batch) }
            return result.sorted { $0.identifier < $1.identifier }
        }
    }

    private func inspectSecurity(
        _ candidates: [StartupItemsDomain.Candidate]
    ) async -> [StartupItemsDomain.Candidate] {
        var result = [StartupItemsDomain.Candidate]()
        result.reserveCapacity(candidates.count)
        for var candidate in candidates {
            if Task.isCancelled { break }
            if let plistURL = candidate.plistURL {
                let plistInspection = pathValidator.inspect(plistURL)
                // A launchd plist is data, not an executable. Keep its path
                // safety findings without incorrectly flagging every valid
                // plist as a non-executable launch target.
                candidate.diagnosticEvidence.append(contentsOf:
                    plistInspection.warnings.filter { $0 != "target-not-executable" }
                )
            }
            guard let executableURL = candidate.executableURL else {
                result.append(candidate)
                continue
            }
            let path = pathValidator.inspect(executableURL)
            candidate.diagnosticEvidence.append(contentsOf: path.warnings)
            if path.exists, candidate.scope != .system {
                let signature = await signatureVerifier.inspect(executableURL)
                if signature.isValid {
                    candidate.diagnosticEvidence.append("valid-code-signature")
                    if StartupItemsDomain.Candidate.isAppleSystemDesignatedRequirement(
                        signature.designatedRequirement
                    ) {
                        candidate.diagnosticEvidence.append("apple-system-signature")
                    }
                } else if signature.isSigned {
                    candidate.diagnosticEvidence.append("signature-invalid")
                } else {
                    candidate.diagnosticEvidence.append("unsigned-executable")
                }
                let applicationURL = candidate.attribution?.applicationURL ?? candidate.applicationURL
                let applicationSignature: StartupSignatureInspection?
                if let applicationURL, applicationURL.standardizedFileURL != executableURL.standardizedFileURL {
                    applicationSignature = await signatureVerifier.inspect(applicationURL)
                    if applicationSignature?.isValid == true {
                        candidate.diagnosticEvidence.append("valid-parent-application-signature")
                    } else {
                        candidate.diagnosticEvidence.append("parent-application-signature-unverified")
                    }
                    if let helperTeam = signature.teamIdentifier,
                       let applicationTeam = applicationSignature?.teamIdentifier,
                       helperTeam != applicationTeam {
                        candidate.diagnosticEvidence.append("team-identifier-mismatch")
                    } else if let helperTeam = signature.teamIdentifier,
                              let applicationTeam = applicationSignature?.teamIdentifier,
                              helperTeam == applicationTeam {
                        candidate.diagnosticEvidence.append("parent-helper-team-identifier-match")
                    } else if signature.teamIdentifier == nil,
                              applicationSignature?.teamIdentifier != nil {
                        candidate.diagnosticEvidence.append("helper-team-identifier-missing")
                    }
                    if let helperRequirement = signature.designatedRequirement?.trimmed.nonEmpty,
                       let applicationRequirement = applicationSignature?.designatedRequirement?.trimmed.nonEmpty,
                       helperRequirement == applicationRequirement {
                        candidate.diagnosticEvidence.append("parent-helper-designated-requirement-match")
                    }
                } else {
                    applicationSignature = signature
                }
                if var attribution = candidate.attribution {
                    attribution.teamIdentifier = attribution.teamIdentifier
                        ?? applicationSignature?.teamIdentifier
                        ?? signature.teamIdentifier
                    attribution.designatedRequirement = attribution.designatedRequirement
                        ?? applicationSignature?.designatedRequirement
                        ?? signature.designatedRequirement
                    candidate.attribution = attribution
                }
            }
            result.append(candidate)
        }
        return result
    }

    private func coverageReport(
        batches: [ScanBatch],
        rawEvidenceCount: Int,
        beforeDeduplication: Int,
        candidates: [StartupItemsDomain.Candidate],
        items: [StartupItemsDomain.Item],
        managedItemCoverageAvailable: Bool
    ) -> StartupCoverageReport {
        let managedItemCount = candidates.filter { $0.kind == .managedItem }.count
        let systemProtectedItems = items.filter(Self.isConfirmedSystemProtected)
        let thirdPartyItems = items.filter { !Self.isConfirmedSystemProtected($0) }
        return StartupCoverageReport(
            sources: batches.map {
                StartupSourceCoverage(
                    source: $0.source,
                    identifier: $0.identifier,
                    discoveredCount: $0.candidates.count,
                    errorDescription: $0.errorDescription
                )
            },
            countsBySource: Dictionary(grouping: candidates, by: \.source).mapValues(\.count),
            countsByKind: Dictionary(grouping: candidates, by: \.kind).mapValues(\.count),
            rawEvidenceCount: rawEvidenceCount,
            filteredEvidenceCount: max(0, rawEvidenceCount - beforeDeduplication),
            discoveredBeforeDeduplication: beforeDeduplication,
            candidatesAfterDeduplication: candidates.count,
            groupedItemCount: items.count,
            attributedItemCount: thirdPartyItems.filter {
                ($0.attribution?.confidence ?? .unknown) >= .medium
            }.count,
            systemProtectedItemCount: systemProtectedItems.count,
            unattributedThirdPartyCount: thirdPartyItems.filter {
                ($0.attribution?.confidence ?? .unknown) < .medium
            }.count,
            openAtLoginCount: candidates.filter {
                $0.kind == .openAtLogin || $0.kind == .loginItem
            }.count,
            runningCount: candidates.filter {
                if case .running = $0.state.process { return true }
                return false
            }.count,
            appleSystemCount: candidates.filter {
                $0.isVerifiedAppleSystem
            }.count,
            managedItemCount: managedItemCoverageAvailable ? managedItemCount : nil,
            managedItemCoverageAvailable: managedItemCoverageAvailable,
            directlyManageableCount: candidates.filter {
                $0.actionCapability.canEnableDirectly || $0.actionCapability.canDisableDirectly
            }.count,
            systemSettingsOnlyCount: candidates.filter {
                $0.actionCapability.canOpenSystemSettings
                    && !$0.actionCapability.requiresAdministrator
                    && !$0.actionCapability.canEnableDirectly
                    && !$0.actionCapability.canDisableDirectly
            }.count,
            administratorRequiredCount: candidates.filter(\.actionCapability.requiresAdministrator).count,
            orphanedCount: candidates.filter { $0.kind == .orphanedItem }.count
        )
    }

    private static func isConfirmedSystemProtected(
        _ item: StartupItemsDomain.Item
    ) -> Bool {
        item.components.contains { component in
            component.isVerifiedAppleSystem
                || component.state.management == .systemProtected
        }
    }
}
