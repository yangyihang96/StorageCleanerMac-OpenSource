import Foundation

enum ProviderBackedUpdateExecutorError: LocalizedError, Sendable, Equatable {
    case providerMismatch
    case applicationNoLongerEligible
    case applicationMissing
    case applicationIdentityChanged
    case applicationVersionChanged
    case versionDidNotChange
    case replacementRecoveryFailed(String)
    case targetVersionNotReached(expected: ApplicationVersion, observed: ApplicationVersion)
    case diskSpaceCheckUnavailable(path: String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64, path: String)

    var errorDescription: String? {
        switch self {
        case .providerMismatch:
            return L10n.text("更新 Provider 与计划不一致。", "The update provider does not match the plan.")
        case .applicationNoLongerEligible:
            return L10n.text(
                "应用当前已不再符合安全自动更新条件。",
                "The application no longer meets the verified automatic-update requirements."
            )
        case .applicationMissing:
            return L10n.text("无法在磁盘上找到应用。", "The application could not be found on disk.")
        case .applicationIdentityChanged:
            return L10n.text("应用身份或签名已改变。", "The application's identity or signing developer changed.")
        case .applicationVersionChanged:
            return L10n.text(
                "应用的磁盘版本已在执行前改变，已阻止这次更新。",
                "The on-disk version changed before execution, so this update was blocked."
            )
        case .versionDidNotChange:
            return L10n.text("命令已完成，但磁盘上的版本未发生变化。", "The command completed, but the on-disk version did not change.")
        case let .replacementRecoveryFailed(detail):
            return L10n.text(
                "上一次官网应用替换未通过安全恢复：\(detail)",
                "The interrupted official application replacement failed safe recovery: \(detail)"
            )
        case let .targetVersionNotReached(expected, observed):
            return L10n.text(
                "磁盘版本 \(observed.display) 未达到计划目标 \(expected.display)。",
                "The on-disk version \(observed.display) did not reach the planned target \(expected.display)."
            )
        case let .diskSpaceCheckUnavailable(path):
            return L10n.text(
                "无法确认更新所需磁盘空间：\(path)",
                "Available disk space could not be confirmed at: \(path)"
            )
        case let .insufficientDiskSpace(requiredBytes, availableBytes, path):
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return L10n.text(
                "磁盘空间不足（需要至少 \(required)，可用 \(available)）：\(path)",
                "Not enough disk space (at least \(required) required, \(available) available): \(path)"
            )
        }
    }
}

struct ApplicationUpdateDiskSpacePolicy: Hashable, Sendable {
    static let standard = Self(
        minimumUnknownDownloadHeadroomBytes: 1_073_741_824,
        knownDownloadMultiplier: 3
    )

    let minimumUnknownDownloadHeadroomBytes: Int64
    let knownDownloadMultiplier: Int64

    func requiredBytes(for application: InstalledApplication) -> Int64 {
        guard let downloadSize = application.downloadSize, downloadSize > 0 else {
            // ponytail: Homebrew exposes no stable per-item byte estimate; keep
            // this floor injectable and replace it when the provider supplies one.
            return minimumUnknownDownloadHeadroomBytes
        }
        guard knownDownloadMultiplier > 0,
              downloadSize <= Int64.max / knownDownloadMultiplier else {
            return Int64.max
        }
        return max(
            minimumUnknownDownloadHeadroomBytes,
            downloadSize * knownDownloadMultiplier
        )
    }
}

/// Executes only providers admitted by `ApplicationUpdatePlanBuilder`, then
/// independently reconciles the on-disk identity and version before success.
final class ProviderBackedApplicationUpdateExecutor: ApplicationUpdateExecuting, @unchecked Sendable {
    private struct ActiveUpdate {
        let application: InstalledApplication
        let provider: any ApplicationUpdateProvider
    }

    private let providerRegistry: ApplicationUpdateProviderRegistry
    private let metadataReader: ApplicationMetadataReader
    private let homebrewScanner: HomebrewInventoryScanner
    private let heavyWorkCoordinator: HeavyWorkCoordinator
    private let runningStateProvider: @Sendable () async -> ApplicationRunningStateSnapshot
    private let diskSpacePolicy: ApplicationUpdateDiskSpacePolicy
    private let availableDiskCapacity: @Sendable (URL) throws -> Int64?
    private let replacementTransactionURL: URL
    private let replacementIdentityVerifier: OfficialApplicationReplacement.IdentityVerifier
    private let activeLock = NSLock()
    private var activeUpdates = [String: ActiveUpdate]()

    private enum StagingOutcome: Sendable {
        case staged(String)
        case failed(String, String)
    }

    init(
        providerRegistry: ApplicationUpdateProviderRegistry = ApplicationUpdateProviderRegistry(),
        metadataReader: ApplicationMetadataReader = ApplicationMetadataReader(),
        homebrewScanner: HomebrewInventoryScanner = HomebrewInventoryScanner(),
        heavyWorkCoordinator: HeavyWorkCoordinator,
        runningStateProvider: @escaping @Sendable () async -> ApplicationRunningStateSnapshot = {
            ApplicationRunningStateSnapshot.capture()
        },
        diskSpacePolicy: ApplicationUpdateDiskSpacePolicy = .standard,
        availableDiskCapacity: @escaping @Sendable (URL) throws -> Int64? = { url in
            var existingURL = url.standardizedFileURL
            while !FileManager.default.fileExists(atPath: existingURL.path), existingURL.path != "/" {
                existingURL.deleteLastPathComponent()
            }
            let attributes = try FileManager.default.attributesOfFileSystem(
                forPath: existingURL.path
            )
            return (attributes[.systemFreeSize] as? NSNumber)?.int64Value
        },
        replacementTransactionURL: URL = OfficialApplicationReplacementTransactionLocation.defaultURL,
        replacementIdentityVerifier: @escaping OfficialApplicationReplacement.IdentityVerifier = OfficialApplicationReplacement.defaultIdentityVerifier
    ) {
        self.providerRegistry = providerRegistry
        self.metadataReader = metadataReader
        self.homebrewScanner = homebrewScanner
        self.heavyWorkCoordinator = heavyWorkCoordinator
        self.runningStateProvider = runningStateProvider
        self.diskSpacePolicy = diskSpacePolicy
        self.availableDiskCapacity = availableDiskCapacity
        self.replacementTransactionURL = replacementTransactionURL.standardizedFileURL
        self.replacementIdentityVerifier = replacementIdentityVerifier
    }

    func execute(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        // A persisted task is only an intent. Re-read only this selected item
        // immediately before executing; the complete inventory is deliberately
        // not rescanned until the whole queue has reached terminal states.
        let currentApplication: InstalledApplication
        do {
            guard ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(application) else {
                throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible
            }
            guard Self.matches(application.identity, expected: task.originalIdentity) else {
                throw ProviderBackedUpdateExecutorError.applicationIdentityChanged
            }
            currentApplication = try await preflight(application: application, task: task)
            var eligibilityApplication = currentApplication
            eligibilityApplication.isRunning = false
            eligibilityApplication.requiresApplicationQuit = false
            guard ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(eligibilityApplication) else {
                throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible
            }
            if currentApplication.isRunning {
                return ApplicationUpdateInstallResult(
                    applicationID: application.id,
                    state: .waitingForQuit,
                    observedVersion: nil,
                    detail: L10n.text(
                        "应用已在加入队列后启动；退出后将重新验证并继续。",
                        "The app started after it was queued; quit it to re-verify and continue."
                    )
                )
            }
            try verifyAvailableDiskSpace(for: currentApplication)
        } catch {
            await discardActiveStagedUpdate(for: application.id)
            throw error
        }
        let provider = await providerRegistry.provider(for: currentApplication)
        guard provider.identifier == task.providerIdentifier else {
            await discardActiveStagedUpdate(for: application.id)
            throw ProviderBackedUpdateExecutorError.providerMismatch
        }

        activeLock.withLock {
            activeUpdates[application.id] = ActiveUpdate(application: currentApplication, provider: provider)
        }
        defer {
            _ = activeLock.withLock { activeUpdates.removeValue(forKey: application.id) }
        }

        do {
            return try await heavyWorkCoordinator.withLease(owner: .appUpdates) { _ in
                let prepared: PreparedApplicationUpdate
                if let stagingProvider = provider as? any ApplicationUpdateStagingProvider,
                   let stagedPrepared = stagingProvider.stagedPreparedUpdate(
                       for: currentApplication.id
                   ) {
                    prepared = stagedPrepared
                } else {
                    prepared = try await provider.prepareUpdate(currentApplication)
                }
                guard Self.matches(prepared.originalIdentity, expected: task.originalIdentity) else {
                    throw ProviderBackedUpdateExecutorError.applicationIdentityChanged
                }
                let (progressStream, progressContinuation) = AsyncStream.makeStream(
                    of: ApplicationUpdateProgressEvent.self
                )
                let progressDelivery = Task {
                    for await event in progressStream {
                        await progress(event)
                    }
                }
                let providerResult: ApplicationUpdateInstallResult
                do {
                    providerResult = try await provider.install(prepared) { event in
                        progressContinuation.yield(event)
                    }
                    progressContinuation.finish()
                    await progressDelivery.value
                } catch {
                    progressContinuation.finish()
                    await progressDelivery.value
                    throw error
                }
                guard providerResult.state == .needsReconciliation
                        || providerResult.state == .completed else {
                    return providerResult
                }
                let observed = try await self.observedVersion(
                    for: currentApplication,
                    baselineVersion: task.originalVersion,
                    targetVersion: task.targetVersion,
                    expectedIdentity: task.originalIdentity
                )
                return ApplicationUpdateInstallResult(
                    applicationID: application.id,
                    state: .completed,
                    observedVersion: observed,
                    detail: L10n.text("已验证磁盘上的新版本。", "The new on-disk version was verified.")
                )
            }
        } catch {
            if let stagingProvider = provider as? any ApplicationUpdateStagingProvider {
                await stagingProvider.discardStagedUpdate(for: application.id)
            }
            throw error
        }
    }

    func stageDownloads(
        applications: [InstalledApplication],
        tasks: [ApplicationUpdateTask],
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async -> ApplicationUpdateStagingReport {
        let applicationsByID = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
        let items = tasks.compactMap { task -> (ApplicationUpdateTask, InstalledApplication)? in
            guard task.providerIdentifier == .officialWebsite,
                  let application = applicationsByID[task.applicationID] else {
                return nil
            }
            return (task, application)
        }
        guard !items.isEmpty else { return ApplicationUpdateStagingReport() }

        var report = ApplicationUpdateStagingReport()
        do {
            report = try await heavyWorkCoordinator.withLease(owner: .appUpdates) { _ in
                var stagedIDs = Set<String>()
                var failures = [String: String]()
                // Two-item batches provide bounded overlap without a semaphore
                // or an unbounded task group. Install never runs in this phase.
                // ponytail: capacity is checked per item; shared-volume
                // reservation needs an explicit lease before batch summing.
                let batchSize = 2
                for start in stride(from: 0, to: items.count, by: batchSize) {
                    try Task.checkCancellation()
                    let end = min(start + batchSize, items.count)
                    let batch = Array(items[start..<end])
                    let outcomes = await withTaskGroup(of: StagingOutcome.self) { group in
                        for (task, application) in batch {
                            group.addTask {
                                await self.stageOne(
                                    application: application,
                                    task: task,
                                    progress: progress
                                )
                            }
                        }
                        var collected = [StagingOutcome]()
                        for await outcome in group {
                            collected.append(outcome)
                        }
                        return collected
                    }
                    for outcome in outcomes {
                        switch outcome {
                        case let .staged(applicationID):
                            stagedIDs.insert(applicationID)
                        case let .failed(applicationID, detail):
                            failures[applicationID] = detail
                        }
                    }
                    try Task.checkCancellation()
                }
                return ApplicationUpdateStagingReport(
                    stagedApplicationIDs: stagedIDs,
                    failedApplicationDetails: failures
                )
            }
        } catch is CancellationError {
            await discardStagedDownloads()
        } catch {
            var failures = [String: String]()
            for (_, application) in items {
                failures[application.id] = error.localizedDescription
            }
            report = ApplicationUpdateStagingReport(failedApplicationDetails: failures)
            await discardStagedDownloads()
        }
        return report
    }

    func discardStagedDownloads() async {
        let active = activeLock.withLock { Array(activeUpdates.values) }
        for activeUpdate in active {
            if let stagingProvider = activeUpdate.provider as? any ApplicationUpdateStagingProvider {
                await stagingProvider.discardStagedUpdate(for: activeUpdate.application.id)
            }
        }
        activeLock.withLock {
            activeUpdates = activeUpdates.filter { _, active in
                !(active.provider is any ApplicationUpdateStagingProvider)
            }
        }
    }

    func cancel(applicationID: String) async {
        let active = activeLock.withLock { activeUpdates[applicationID] }
        guard let active else { return }
        await active.provider.cancelUpdate(for: active.application)
    }

    private func stageOne(
        application: InstalledApplication,
        task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void
    ) async -> StagingOutcome {
        guard application.updateProvider == task.providerIdentifier else {
            return .failed(
                application.id,
                ProviderBackedUpdateExecutorError.providerMismatch.localizedDescription
            )
        }
        let provider = await providerRegistry.provider(for: application)
        guard provider.identifier == task.providerIdentifier,
              provider.identifier == .officialWebsite,
              let stagingProvider = provider as? any ApplicationUpdateStagingProvider else {
            return .failed(
                application.id,
                "The verified official website staging provider is unavailable."
            )
        }
        do {
            // Staging is a side-effecting download path. Re-read the same
            // on-disk identity/version and apply the automatic-plan gate
            // before asking the provider to prepare or stage anything.
            let currentApplication = try await preflight(application: application, task: task)
            var eligibilityApplication = currentApplication
            // A running app is a waitable quit condition, not a reason to
            // download unsafe data; all other automatic-update gates remain.
            eligibilityApplication.isRunning = false
            eligibilityApplication.requiresApplicationQuit = false
            guard ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(
                eligibilityApplication
            ) else {
                throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible
            }
            try verifyAvailableDiskSpace(for: currentApplication)

            await discardActiveStagedUpdate(for: application.id)
            activeLock.withLock {
                activeUpdates[application.id] = ActiveUpdate(
                    application: currentApplication,
                    provider: provider
                )
            }
            let prepared = try await provider.prepareUpdate(currentApplication)
            guard prepared.originalIdentity == task.originalIdentity,
                  prepared.originalVersion == task.originalVersion,
                  prepared.targetVersion == task.targetVersion else {
                throw ProviderBackedUpdateExecutorError.applicationIdentityChanged
            }
            let (progressStream, progressContinuation) = AsyncStream.makeStream(
                of: ApplicationUpdateProgressEvent.self
            )
            let progressDelivery = Task {
                for await event in progressStream {
                    await progress(event)
                }
            }
            do {
                try await stagingProvider.stage(prepared) { event in
                    progressContinuation.yield(event)
                }
                progressContinuation.finish()
                await progressDelivery.value
            } catch {
                progressContinuation.finish()
                await progressDelivery.value
                throw error
            }
            return .staged(application.id)
        } catch is CancellationError {
            await stagingProvider.discardStagedUpdate(for: application.id)
            _ = activeLock.withLock { activeUpdates.removeValue(forKey: application.id) }
            return .failed(application.id, "Staging was cancelled.")
        } catch {
            await stagingProvider.discardStagedUpdate(for: application.id)
            _ = activeLock.withLock { activeUpdates.removeValue(forKey: application.id) }
            return .failed(application.id, error.localizedDescription)
        }
    }

    private func discardActiveStagedUpdate(for applicationID: String) async {
        let stagingProvider = activeLock.withLock { () -> (any ApplicationUpdateStagingProvider)? in
            guard let active = activeUpdates[applicationID],
                  let provider = active.provider as? any ApplicationUpdateStagingProvider else {
                return nil
            }
            activeUpdates.removeValue(forKey: applicationID)
            return provider
        }
        await stagingProvider?.discardStagedUpdate(for: applicationID)
    }

    func reconcile(
        task: ApplicationUpdateTask,
        application: InstalledApplication?
    ) async throws -> ApplicationUpdateInstallResult {
        var application = application
        if task.providerIdentifier == .officialWebsite {
            guard let targetVersion = task.targetVersion,
                  !targetVersion.preferred.isEmpty else {
                throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible
            }
            do {
                let store = OfficialApplicationReplacementTransactionStore(
                    fileURL: replacementTransactionURL
                )
                let pending = try store.load()
                let destinationURL = pending?.destinationURL ?? application?.bundleURL
                guard let destinationURL else {
                    throw ProviderBackedUpdateExecutorError.applicationMissing
                }
                if pending != nil {
                    _ = try OfficialApplicationReplacement.reconcilePending(
                        transactionURL: replacementTransactionURL,
                        expectedDestinationURL: application?.bundleURL,
                        expectedIdentity: task.originalIdentity,
                        expectedOriginalVersion: task.originalVersion,
                        expectedTargetVersion: targetVersion,
                        identityVerifier: replacementIdentityVerifier
                    )
                }
                if application == nil {
                    let runningState = await runningStateProvider()
                    guard var reread = await metadataReader.read(
                        applicationURL: destinationURL,
                        runningState: runningState
                    ) else {
                        throw ProviderBackedUpdateExecutorError.applicationMissing
                    }
                    // MetadataReader intentionally reports only on-disk facts;
                    // restore the frozen provider membership for this task.
                    reread.updateProvider = task.providerIdentifier
                    guard reread.id == task.applicationID else {
                        throw ProviderBackedUpdateExecutorError.applicationIdentityChanged
                    }
                    application = reread
                }
            } catch let error as ProviderBackedUpdateExecutorError {
                throw error
            } catch {
                throw ProviderBackedUpdateExecutorError.replacementRecoveryFailed(
                    String(describing: error)
                )
            }
        }
        guard let application else { throw ProviderBackedUpdateExecutorError.applicationMissing }
        guard application.updateProvider == task.providerIdentifier else {
            throw ProviderBackedUpdateExecutorError.providerMismatch
        }
        guard Self.matches(application.identity, expected: task.originalIdentity) else {
            throw ProviderBackedUpdateExecutorError.applicationIdentityChanged
        }
        let observed = try await observedVersion(
            for: application,
            baselineVersion: task.originalVersion,
            targetVersion: task.targetVersion,
            expectedIdentity: task.originalIdentity
        )
        return ApplicationUpdateInstallResult(
            applicationID: application.id,
            state: .completed,
            observedVersion: observed,
            detail: L10n.text("已重新读取磁盘版本。", "The on-disk version was read again.")
        )
    }

    private func preflight(
        application: InstalledApplication,
        task: ApplicationUpdateTask
    ) async throws -> InstalledApplication {
        if application.updateProvider == .homebrew,
           let metadata = application.homebrewMetadata,
           metadata.kind == .formula {
            guard let observedVersion = try await homebrewScanner.installedFormulaVersion(
                token: metadata.token
            ) else {
                throw ProviderBackedUpdateExecutorError.applicationMissing
            }
            guard observedVersion == task.originalVersion else {
                throw ProviderBackedUpdateExecutorError.applicationVersionChanged
            }
            return application
        }

        let runningState = await runningStateProvider()
        guard let observed = await metadataReader.read(
            applicationURL: application.bundleURL,
            runningState: runningState
        ) else {
            throw ProviderBackedUpdateExecutorError.applicationMissing
        }
        guard observed.sourceEvidence.contains("valid-code-signature"),
              Self.matches(observed.identity, expected: task.originalIdentity) else {
            throw ProviderBackedUpdateExecutorError.applicationIdentityChanged
        }
        guard observed.installedVersion == task.originalVersion else {
            throw ProviderBackedUpdateExecutorError.applicationVersionChanged
        }

        // Keep the click-time provider evidence and target version immutable,
        // while replacing the fields that can change locally between queueing
        // and execution.
        var refreshed = application
        refreshed.executableURL = observed.executableURL
        refreshed.architectures = observed.architectures
        refreshed.minimumSystemVersion = observed.minimumSystemVersion
        refreshed.isRunning = observed.isRunning
        refreshed.isReadOnly = observed.isReadOnly
        refreshed.modifiedAt = observed.modifiedAt
        refreshed.lastScanDate = observed.lastScanDate
        return refreshed
    }

    private func observedVersion(
        for application: InstalledApplication,
        baselineVersion: ApplicationVersion,
        targetVersion: ApplicationVersion?,
        expectedIdentity: ApplicationIdentity
    ) async throws -> ApplicationVersion {
        if application.updateProvider == .homebrew,
           let metadata = application.homebrewMetadata {
            if metadata.kind == .formula {
                guard let observed = try await homebrewScanner.installedFormulaVersion(
                    token: metadata.token
                ) else {
                    throw ProviderBackedUpdateExecutorError.applicationMissing
                }
                guard observed != baselineVersion else {
                    throw ProviderBackedUpdateExecutorError.versionDidNotChange
                }
                return try Self.validatedObservedVersion(observed, targetVersion: targetVersion)
            }

            let candidateURLs = metadata.appBundlePaths.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } + [application.bundleURL]
            var lastError: ProviderBackedUpdateExecutorError = .applicationMissing
            var seen = Set<String>()
            for url in candidateURLs where seen.insert(url.standardizedFileURL.path).inserted {
                do {
                    let observed = try await readVerifiedApplication(
                        at: url,
                        baselineVersion: baselineVersion,
                        expectedIdentity: expectedIdentity
                    )
                    return try Self.validatedObservedVersion(
                        observed.installedVersion,
                        targetVersion: targetVersion
                    )
                } catch let error as ProviderBackedUpdateExecutorError {
                    if error == .applicationIdentityChanged
                        || (error == .versionDidNotChange && lastError == .applicationMissing) {
                        lastError = error
                    }
                }
            }
            throw lastError
        }

        let observed = try await readVerifiedApplication(
            at: application.bundleURL,
            baselineVersion: baselineVersion,
            expectedIdentity: expectedIdentity
        )
        return try Self.validatedObservedVersion(
            observed.installedVersion,
            targetVersion: targetVersion
        )
    }

    private static func validatedObservedVersion(
        _ observed: ApplicationVersion,
        targetVersion: ApplicationVersion?
    ) throws -> ApplicationVersion {
        guard let targetVersion, !targetVersion.preferred.isEmpty else {
            throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible
        }
        guard observed >= targetVersion else {
            throw ProviderBackedUpdateExecutorError.targetVersionNotReached(
                expected: targetVersion,
                observed: observed
            )
        }
        return observed
    }

    private func verifyAvailableDiskSpace(for application: InstalledApplication) throws {
        let requiredBytes = diskSpacePolicy.requiredBytes(for: application)
        let locations = [
            FileManager.default.temporaryDirectory,
            application.bundleURL.deletingLastPathComponent(),
        ]
        var checkedPaths = Set<String>()
        for location in locations {
            let path = location.standardizedFileURL.path
            guard checkedPaths.insert(path).inserted else { continue }
            guard let availableBytes = try availableDiskCapacity(location) else {
                throw ProviderBackedUpdateExecutorError.diskSpaceCheckUnavailable(path: path)
            }
            guard availableBytes >= requiredBytes else {
                throw ProviderBackedUpdateExecutorError.insufficientDiskSpace(
                    requiredBytes: requiredBytes,
                    availableBytes: availableBytes,
                    path: path
                )
            }
        }
    }

    private func readVerifiedApplication(
        at url: URL,
        baselineVersion: ApplicationVersion,
        expectedIdentity: ApplicationIdentity
    ) async throws -> InstalledApplication {
        let runningState = await runningStateProvider()
        guard let observed = await metadataReader.read(
            applicationURL: url,
            runningState: runningState
        ) else {
            throw ProviderBackedUpdateExecutorError.applicationMissing
        }
        guard observed.sourceEvidence.contains("valid-code-signature"),
              Self.matches(observed.identity, expected: expectedIdentity) else {
            throw ProviderBackedUpdateExecutorError.applicationIdentityChanged
        }
        guard observed.installedVersion != baselineVersion else {
            throw ProviderBackedUpdateExecutorError.versionDidNotChange
        }
        return observed
    }

    private static func matches(
        _ observed: ApplicationIdentity,
        expected: ApplicationIdentity
    ) -> Bool {
        guard !expected.bundleIdentifier.trimmed.isEmpty,
              observed.bundleIdentifier == expected.bundleIdentifier else {
            return false
        }
        if let expectedTeam = expected.signingTeamIdentifier?.trimmed.nonEmpty,
           observed.signingTeamIdentifier != expectedTeam {
            return false
        }
        if let expectedIdentifier = expected.codeSigningIdentifier?.trimmed.nonEmpty,
           observed.codeSigningIdentifier != expectedIdentifier {
            return false
        }
        return true
    }
}

enum ApplicationUpdateQueueLocation {
    static var defaultURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("AppUpdates", isDirectory: true)
            .appendingPathComponent("queue-v2.json", isDirectory: false)
    }
}
