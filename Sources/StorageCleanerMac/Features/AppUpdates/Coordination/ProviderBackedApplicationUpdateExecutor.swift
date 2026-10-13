import Foundation

/// Uses the executor's injected fresh signature/metadata reader for the same
/// artifact baseline and readback. Production defaults still perform strict
/// Security validation; tests cannot accidentally fall through to host code.
private struct ExecutorArtifactRechecker: InstalledApplicationRechecking {
    let reader: ApplicationMetadataReader
    let runningState: @Sendable () async -> ApplicationRunningStateSnapshot
    func snapshot(at url: URL) async throws -> InstalledApplicationRecheckSnapshot? {
        guard let application = await reader.read(applicationURL: url, runningState: await runningState()) else { return nil }
        let valid = application.sourceEvidence.contains("valid-code-signature")
        return .init(application: application, signature: .init(isValid: valid,
            codeSigningIdentifier: application.codeSigningIdentifier, teamIdentifier: application.signingTeamIdentifier,
            designatedRequirement: nil, certificateCommonNames: [], status: valid ? 0 : -1))
    }
}

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
final class ProviderBackedApplicationUpdateExecutor: ApplicationUpdateBatchExecuting, @unchecked Sendable {
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
    private let runtime: ApplicationUpdateBatchRuntime
    private let processSafety: AppUpdateInstallationProcessSafety
    private let batchAuthorization: any AppUpdateBatchAuthorizing
    private let brewBatchInstaller: HomebrewBatchInstaller
    private var authorizationFailure: String?
    private var batchSessionID: UUID?
    private let activeLock = NSLock()
    private var activeUpdates = [String: ActiveUpdate]()

    private enum StagingOutcome: Sendable {
        case staged(String)
        case failed(String, String)
    }

    init(
        runtime: ApplicationUpdateBatchRuntime = .system,
        processSafety: AppUpdateInstallationProcessSafety = .init(),
        batchAuthorization: any AppUpdateBatchAuthorizing = AppUpdateBatchAuthorization.shared,
        brewBatchInstaller: HomebrewBatchInstaller? = nil,
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
        self.runtime = runtime
        self.processSafety = processSafety
        self.batchAuthorization = batchAuthorization
        self.brewBatchInstaller = brewBatchInstaller ?? HomebrewBatchInstaller(rechecker: ExecutorArtifactRechecker(reader: metadataReader, runningState: runningStateProvider), runtime: runtime, processSafety: processSafety)
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

    func beginBatch(applications: [InstalledApplication], sessionID: UUID) async {
        let needsPreparation = activeLock.withLock {
            guard batchSessionID != sessionID else { return false }
            batchSessionID = sessionID; authorizationFailure = nil
            return true
        }
        guard needsPreparation else { return }
        do {
            // Same lease as uninstall/restore: lifecycle refresh cannot boot out
            // their worker while an operation or cleanup quarantine is active.
            try await heavyWorkCoordinator.withLease(owner: .appUpdates) { _ in
                try await self.batchAuthorization.prepare(applications: applications, sessionID: sessionID)
            }
        }
        catch { activeLock.withLock { authorizationFailure = error.localizedDescription } }
    }

    func prepareRecoveryEvidence(application: InstalledApplication, task: ApplicationUpdateTask,
        relatedApplications: [InstalledApplication]) async throws -> ApplicationUpdateRecoveryEvidence? {
        if task.providerIdentifier == .homebrew {
            return try await brewBatchInstaller.recoveryEvidence(for: application, relatedApplications: relatedApplications)
        }
        return .init(applicationPath: application.path, homebrewMetadata: nil,
            artifacts: [.init(path: application.path, originalIdentity: task.originalIdentity, originalVersion: task.originalVersion,
                wasRunning: await runtime.isRunning(application.bundleURL) || application.isRunning)])
    }

    func endBatch(sessionID: UUID) async {
        guard activeLock.withLock({ batchSessionID == sessionID }) else { return }
        await batchAuthorization.finish()
        activeLock.withLock { batchSessionID = nil; authorizationFailure = nil }
    }

    func executeHomebrewBatch(applications: [InstalledApplication], tasks: [ApplicationUpdateTask],
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async -> [ApplicationUpdateInstallResult] {
        var eligible = [InstalledApplication]()
        var rejected = [ApplicationUpdateInstallResult]()
        for app in applications {
            if app.requiresAdministratorAuthorization || app.homebrewMetadata?.needsAdministrator == true,
                let failure = activeLock.withLock({ authorizationFailure }) {
                rejected.append(.init(applicationID: app.id, state: .skipped, observedVersion: nil, detail: failure))
                continue
            }
            guard let task = tasks.first(where: { $0.applicationID == app.id }), task.originalIdentity == app.identity,
                  task.originalVersion == app.installedVersion, task.targetVersion == app.availableVersion,
                  app.canJoinAutomaticUpdateBatch else {
                rejected.append(.init(applicationID: app.id, state: .failed, observedVersion: nil, detail: ProviderBackedUpdateExecutorError.applicationNoLongerEligible.localizedDescription))
                continue
            }
            do { try verifyAvailableDiskSpace(for: app); eligible.append(app) }
            catch { rejected.append(.init(applicationID: app.id, state: .failed, observedVersion: nil, detail: error.localizedDescription)) }
        }
        var selected = eligible
        var installer = brewBatchInstaller
        do {
            installer.frozenExecutable = try await batchAuthorization.homebrewExecutable()
            installer.revokeAuthorization = { try await self.batchAuthorization.revokeHomebrewAuthorization() }
        } catch {
            return rejected + selected.map { .init(applicationID: $0.id, state: .failed, observedVersion: nil, detail: error.localizedDescription) }
        }
        if selected.contains(where: { $0.requiresAdministratorAuthorization || $0.homebrewMetadata?.needsAdministrator == true }) {
            do { installer.administratorEnvironment = try await batchAuthorization.homebrewEnvironment() }
            catch {
                let needsApproval: (InstalledApplication) -> Bool = { $0.requiresAdministratorAuthorization || $0.homebrewMetadata?.needsAdministrator == true }
                rejected += selected.filter(needsApproval).map { .init(applicationID: $0.id, state: .skipped, observedVersion: nil, detail: error.localizedDescription) }
                selected.removeAll(where: needsApproval)
            }
        }
        let preparedInstaller = installer
        let selectedApplications = selected
        let evidenceByID = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in task.recoveryEvidence.map { (task.applicationID, $0) } })
        do {
            let results = try await heavyWorkCoordinator.withLease(owner: .appUpdates) { _ in
                await preparedInstaller.install(applications: selectedApplications, recoveryEvidenceByID: evidenceByID, progress: progress)
            }
            return rejected + results
        } catch {
            return rejected + selected.map { .init(applicationID: $0.id, state: .failed, observedVersion: nil, detail: error.localizedDescription) }
        }
    }

    func execute(application: InstalledApplication, task: ApplicationUpdateTask,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async throws -> ApplicationUpdateInstallResult {
        if application.requiresAdministratorAuthorization, let failure = activeLock.withLock({ authorizationFailure }) {
            return .init(applicationID: application.id, state: .skipped, observedVersion: nil, detail: failure)
        }
        var eligibility = application
        eligibility.isRunning = false; eligibility.requiresApplicationQuit = false; eligibility.requiresAdministratorAuthorization = false
        guard ApplicationUpdatePlanBuilder.isEligibleForAutomaticUpdate(eligibility) else { throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible }
        var evidence: ApplicationUpdateRecoveryEvidence?
        if let frozen = task.recoveryEvidence { evidence = frozen }
        else { evidence = try await prepareRecoveryEvidence(application: application, task: task, relatedApplications: [application]) }
        let stopped = try await runtime.stop(application)
        guard stopped.stopped else {
            return .init(applicationID: application.id, state: .skipped, observedVersion: nil, detail: L10n.text("应用未退出", "Application did not quit"))
        }
        var ready = application
        ready.isRunning = false
        ready.requiresApplicationQuit = false
        ready.requiresAdministratorAuthorization = false
        let result: ApplicationUpdateInstallResult
        do { result = try await executeStopped(application: ready, task: task, progress: progress) }
        catch let commandError as AppUpdateCommandError where commandError.isNormalExit {
            var completion = commandError.completionEvidence ?? .stopped
            evidence?.commandCompletion = completion
            do {
                var observed = try await observedVersion(for: ready, baselineVersion: task.originalVersion,
                    targetVersion: task.targetVersion, expectedIdentity: task.originalIdentity)
                if completion.knownProcessesAlive {
                    let stopped = try await processSafety.waitForKnownProcesses(&completion)
                    evidence?.commandCompletion = completion
                    guard stopped else {
                        return .init(applicationID: application.id, state: .completed, observedVersion: observed,
                            detail: L10n.text("安装程序仍在收尾，稍后再打开。仍保持隔离，可用“核验并恢复”。", "The installer is still finishing; open the app later. Quarantine remains; use Verify and Recover."),
                            recoveryEvidence: evidence, installationIsolated: true)
                    }
                    completion.knownProcessesAlive = false
                    evidence?.commandCompletion = completion
                    observed = try await observedVersion(for: ready, baselineVersion: task.originalVersion,
                        targetVersion: task.targetVersion, expectedIdentity: task.originalIdentity)
                }
                let (reopened, reopeningDetail) = await ApplicationUpdateRecoveryEvidence.reopening(evidence, using: runtime)
                return .init(applicationID: application.id, state: .completed, observedVersion: observed,
                    detail: L10n.text("主命令正常退出，已核验新版本", "Normal command exit; new version verified") + reopeningDetail, recoveryEvidence: reopened)
            } catch {
                evidence?.commandCompletion = completion
                return .init(applicationID: application.id, state: completion.permitsRetry && error is ProviderBackedUpdateExecutorError ? .failed : .needsReconciliation, observedVersion: nil,
                    detail: commandError.localizedDescription + "\n" + AppUpdateErrorRedaction.text(error.localizedDescription),
                    recoveryEvidence: evidence)
            }
        }
        catch let commandError as AppUpdateCommandError where commandError.isUnconfirmedStop {
            evidence?.commandCompletion = commandError.completionEvidence
            return .init(applicationID: application.id, state: .needsReconciliation, observedVersion: nil, detail: AppUpdateCommandError.needsReconciliation.localizedDescription, recoveryEvidence: evidence)
        }
        catch let AppUpdateCommandError.recoveryRequired(paths) {
            return .init(applicationID: application.id, state: .needsReconciliation, observedVersion: nil, detail: AppUpdateCommandError.recoveryRequired(paths).localizedDescription, recoveryEvidence: evidence)
        }
        catch let OfficialApplicationUpdateInstallerError.rollbackFailed(paths) {
            return .init(applicationID: application.id, state: .needsReconciliation, observedVersion: nil, detail: AppUpdateCommandError.recoveryRequired(paths).localizedDescription, recoveryEvidence: evidence)
        }
        catch let error as AppUpdateAuthorizationError {
            return .init(applicationID: application.id, state: .skipped, observedVersion: nil, detail: error.localizedDescription)
        }
        catch AppUpdateCommandError.cancelled {
            return .init(applicationID: application.id, state: .cancelled, observedVersion: nil, detail: AppUpdateCommandError.cancelled.localizedDescription, confirmedStopped: true)
        }
        if result.state == .completed, let evidence {
            let (reopened, detail) = await evidence.reopening(using: runtime)
            var completed = result; completed.recoveryEvidence = reopened
            return .init(applicationID: result.applicationID, state: result.state, observedVersion: result.observedVersion,
                detail: result.detail + detail, recoveryEvidence: completed.recoveryEvidence)
        }
        var recorded = result; recorded.recoveryEvidence = evidence
        return recorded
    }

    private func executeStopped(
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
                let observed: ApplicationVersion
                do {
                    observed = try await self.observedVersion(for: currentApplication, baselineVersion: task.originalVersion,
                        targetVersion: task.targetVersion, expectedIdentity: task.originalIdentity)
                } catch ProviderBackedUpdateExecutorError.versionDidNotChange where currentApplication.updateProvider == .vendorUpdater && task.targetVersion == nil {
                    return .init(applicationID: application.id, state: .skipped, observedVersion: nil,
                        detail: L10n.text("厂商更新器未发现更高版本", "The vendor updater did not find a newer version"))
                }
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
        await batchAuthorization.finish()
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
        try await reconcile(task: task, application: application, transactionRecoveryConfirmed: false)
    }

    private func reconcile(task: ApplicationUpdateTask, application: InstalledApplication?,
        transactionRecoveryConfirmed: Bool) async throws -> ApplicationUpdateInstallResult {
        var task = task
        let status = inspectProcesses(&task)
        guard status == .stopped else { return pendingRecovery(task, detail: status.detail) }
        if task.providerIdentifier == .homebrew {
            var result = try await brewBatchInstaller.reconcile(application: application, task: task, reopenWhenVerified: false)
            guard result.state == .completed else { return result }
            let afterRead = inspectProcesses(&task)
            guard afterRead == .stopped else { return pendingRecovery(task, detail: afterRead.detail) }
            result.recoveryEvidence?.commandCompletion = task.recoveryEvidence?.commandCompletion
            let (reopened, detail) = await ApplicationUpdateRecoveryEvidence.reopening(result.recoveryEvidence, using: runtime)
            return .init(applicationID: result.applicationID, state: .completed, observedVersion: result.observedVersion,
                detail: result.detail + detail, recoveryEvidence: reopened)
        }
        var application = application
        if [.officialWebsite, .sparkle].contains(task.providerIdentifier) {
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
                    // Automatic queue restoration/status refresh must not move
                    // bundles or remove recovery material. Only the UI's
                    // confirmed Verify and Recover action enters this branch.
                    guard transactionRecoveryConfirmed else {
                        return pendingRecovery(task, detail: L10n.text("先前更新留下应用替换事务，请点击“核验并恢复”并确认后处理。", "An earlier update left an application replacement transaction. Choose Verify and Recover, then confirm to proceed."))
                    }
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
        // A legacy intent may carry process identities only (empty path).
        if application == nil, let evidence = task.recoveryEvidence, !evidence.applicationPath.isEmpty {
            let running = await runningStateProvider()
            if var disk = await metadataReader.read(applicationURL: URL(fileURLWithPath: evidence.applicationPath), runningState: running) {
                disk.updateProvider = task.providerIdentifier; application = disk
            }
        }
        guard let application else { throw ProviderBackedUpdateExecutorError.applicationMissing }
        if let evidence = task.recoveryEvidence, !evidence.applicationPath.isEmpty,
            ApplicationPathNormalizer.comparisonKey(for: application.bundleURL) != ApplicationPathNormalizer.comparisonKey(for: URL(fileURLWithPath: evidence.applicationPath)) {
            throw ProviderBackedUpdateExecutorError.applicationIdentityChanged
        }
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
        let afterRead = inspectProcesses(&task)
        guard afterRead == .stopped else { return pendingRecovery(task, detail: afterRead.detail) }
        let (reopened, detail) = await ApplicationUpdateRecoveryEvidence.reopening(task.recoveryEvidence, using: runtime)
        return ApplicationUpdateInstallResult(
            applicationID: application.id,
            state: .completed,
            observedVersion: observed,
            detail: L10n.text("已重新读取磁盘版本。", "The on-disk version was read again.") + detail,
            recoveryEvidence: reopened
        )
    }

    /// Called by the user-confirmed recovery action, never by automatic refresh.
    func verifyAndRelease(task: ApplicationUpdateTask, application: InstalledApplication?) async throws -> ApplicationUpdateInstallResult {
        var task = task
        let status = inspectProcesses(&task)
        guard status == .stopped else { return pendingRecovery(task, detail: status.detail) }
        do {
            let result = try await reconcile(task: task, application: application, transactionRecoveryConfirmed: true)
            task.recoveryEvidence = result.recoveryEvidence ?? task.recoveryEvidence
            if result.state == .completed { return result }
            let afterRead = inspectProcesses(&task)
            guard afterRead == .stopped else { return pendingRecovery(task, detail: afterRead.detail) }
            return .init(applicationID: task.applicationID, state: .failed, observedVersion: nil,
                detail: L10n.text("已确认安装进程结束，但无法证实达到原计划目标；已解除隔离，可重新授权更新。", "Installation processes have stopped, but the frozen target could not be verified. Quarantine released; authorize an update again.") + "\n" + result.detail,
                confirmedStopped: true, recoveryEvidence: result.recoveryEvidence ?? task.recoveryEvidence)
        } catch {
            if error is CancellationError || Task.isCancelled {
                return pendingRecovery(task, detail: L10n.text("核验已取消，继续隔离", "Verification cancelled; quarantine remains"))
            }
            if case ProviderBackedUpdateExecutorError.replacementRecoveryFailed = error {
                return pendingRecovery(task, detail: AppUpdateErrorRedaction.text(error.localizedDescription))
            }
            let afterRead = inspectProcesses(&task)
            guard afterRead == .stopped else { return pendingRecovery(task, detail: afterRead.detail) }
            return .init(applicationID: task.applicationID, state: .failed, observedVersion: nil,
                detail: L10n.text("已确认安装进程结束；未升版或旧记录无法证明原计划，已解除隔离，可重新授权更新。", "Installation processes have stopped. No upgrade or insufficient legacy evidence; quarantine released. Authorize an update again.") + "\n" + AppUpdateErrorRedaction.text(error.localizedDescription),
                confirmedStopped: true, recoveryEvidence: task.recoveryEvidence)
        }
    }

    private func inspectProcesses(_ task: inout ApplicationUpdateTask) -> AppUpdateInstallationProcessStatus {
        var completion = task.recoveryEvidence?.commandCompletion ?? .stopped
        let prefixes = [task.recoveryEvidence?.homebrewMetadata?.prefixPath].compactMap { $0 }
        let status = processSafety.releaseStatus(&completion, homebrewPrefixes: prefixes)
        // A legacy intent has no package/path baseline. Preserve that absence
        // (and provider-wide quarantine), but retain newly observed installer
        // descendants so the next session cannot forget a reparented child.
        if task.recoveryEvidence == nil, !completion.processes.isEmpty {
            task.recoveryEvidence = .init(applicationPath: "", homebrewMetadata: nil, artifacts: [],
                commandCompletion: completion)
        }
        task.recoveryEvidence?.commandCompletion = completion
        return status
    }

    private func pendingRecovery(_ task: ApplicationUpdateTask, detail: String) -> ApplicationUpdateInstallResult {
        .init(applicationID: task.applicationID, state: .needsReconciliation, observedVersion: nil,
            detail: detail, recoveryEvidence: task.recoveryEvidence)
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

            // A newer duplicate artifact is not proof that the selected target
            // was updated. Reconcile the exact path that passed preflight.
            let observed = try await readVerifiedApplication(
                at: application.bundleURL,
                baselineVersion: baselineVersion,
                expectedIdentity: expectedIdentity
            )
            return try Self.validatedObservedVersion(observed.installedVersion, targetVersion: targetVersion)
        }

        let observed = try await readVerifiedApplication(
            at: application.bundleURL,
            baselineVersion: baselineVersion,
            expectedIdentity: expectedIdentity
        )
        if application.updateProvider == .vendorUpdater && targetVersion == nil {
            guard SparkleAutomaticUpdateAdapter.isNewer(observed.installedVersion, than: baselineVersion) else {
                throw ProviderBackedUpdateExecutorError.versionDidNotChange
            }
            return observed.installedVersion
        }
        return try Self.validatedObservedVersion(observed.installedVersion, targetVersion: targetVersion)
    }

    private static func validatedObservedVersion(
        _ observed: ApplicationVersion,
        targetVersion: ApplicationVersion?
    ) throws -> ApplicationVersion {
        guard let targetVersion, !targetVersion.preferred.isEmpty else {
            throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible
        }
        guard observed.reaches(targetVersion) else {
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
