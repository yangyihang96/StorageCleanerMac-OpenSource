import Foundation

/// One execution per package, with every affected application participating in
/// quit/readback/reopen. Administrator and ordinary packages never share a call.
struct HomebrewBatchInstaller: Sendable {
    var executable: @Sendable () -> URL? = { HomebrewInventoryScanner().locateHomebrewExecutable() }
    var command: any HomebrewCommandRunning = AppUpdateCommandRunner()
    var rechecker: any InstalledApplicationRechecking = VerifiedInstalledApplicationRechecker()
    var runtime: ApplicationUpdateBatchRuntime = .system
    var processSafety = AppUpdateInstallationProcessSafety()
    var environment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    var administratorEnvironment: [String: String] = [:]
    var frozenExecutable: AppUpdateExecutableIdentity?
    var captureExecutable: @Sendable (URL) throws -> AppUpdateExecutableIdentity = AppUpdateExecutableIdentity.capture
    var revokeAuthorization: @Sendable () async throws -> Void = {}
    /// No symbolic-version success is inferred from a string. A provider may
    /// inject receipt/artifact evidence correlated with this exact invocation.
    var symbolicVersionEvidence: @Sendable (HomebrewPackageMetadata) async throws -> Bool = { _ in false }

    func recoveryEvidence(for application: InstalledApplication, relatedApplications: [InstalledApplication] = []) async throws -> ApplicationUpdateRecoveryEvidence {
        guard let metadata = application.homebrewMetadata else { throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible }
        let packageApps = relatedApplications.filter { $0.homebrewMetadata?.kind == metadata.kind && $0.homebrewMetadata?.token == metadata.token }
        var paths = Set(([application] + packageApps).flatMap { $0.homebrewMetadata?.appBundlePaths ?? [] })
        paths.formUnion(packageApps.filter { !$0.homebrewMetadata!.appBundlePaths.isEmpty || ($0.packageKind == .graphicalApplication && $0.bundleURL.pathExtension == "app") }.map(\.path))
        if !paths.isEmpty || (application.packageKind == .graphicalApplication && application.bundleURL.pathExtension == "app") { paths.insert(application.path) }
        var artifacts = [ApplicationUpdateArtifactEvidence]()
        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard let before = try await rechecker.snapshot(at: url) else { throw ProviderBackedUpdateExecutorError.applicationMissing }
            artifacts.append(.init(path: path, originalIdentity: before.application.identity, originalVersion: before.application.installedVersion,
                wasRunning: await runtime.isRunning(url)))
        }
        return .init(applicationPath: application.path, homebrewMetadata: metadata, artifacts: artifacts,
            packageVersionsBefore: metadata.installedVersions.joined(separator: " "))
    }

    private struct Before: Sendable {
        let apps: [InstalledApplication]
        let metadata: HomebrewPackageMetadata
        let versions: String
        let identities: [String: ApplicationIdentity]
        let appVersions: [String: ApplicationVersion]
        let wasRunning: Set<URL>
    }
    func install(applications: [InstalledApplication], recoveryEvidenceByID: [String: ApplicationUpdateRecoveryEvidence] = [:], progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async -> [ApplicationUpdateInstallResult] {
        guard let brew = frozenExecutable?.url ?? executable() else { return applications.map { result($0, state: .failed, detail: L10n.text("未找到受信任的 Homebrew", "Trusted Homebrew unavailable")) } }
        let frozen: AppUpdateExecutableIdentity
        do { frozen = try frozenExecutable ?? captureExecutable(brew) }
        catch { return applications.map { result($0, state: .failed, detail: error.localizedDescription) } }
        var prepared = self; prepared.frozenExecutable = frozen
        return await prepared.installFrozen(applications: applications, recoveryEvidenceByID: recoveryEvidenceByID, brew: brew, frozen: frozen, progress: progress)
    }
    private func installFrozen(applications: [InstalledApplication], recoveryEvidenceByID: [String: ApplicationUpdateRecoveryEvidence], brew: URL, frozen: AppUpdateExecutableIdentity,
        progress: @Sendable @escaping (ApplicationUpdateProgressEvent) async -> Void) async -> [ApplicationUpdateInstallResult] {
        let env = HomebrewCommandEnvironment.allowlist(executableURL: brew, environment: environment())
        let packages = Dictionary(grouping: applications) { ($0.homebrewMetadata?.kind.rawValue ?? "") + ":" + ($0.homebrewMetadata?.token ?? $0.id) }
        var ready = [Before](); var results = [ApplicationUpdateInstallResult]()
        let orderedKeys = applications.map { ($0.homebrewMetadata?.kind.rawValue ?? "") + ":" + ($0.homebrewMetadata?.token ?? $0.id) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for key in orderedKeys {
            let apps = packages[key]!
            var running = Set<URL>()
            do {
                try Task.checkCancellation()
                guard let metadata = apps.first?.homebrewMetadata, apps.allSatisfy({ app in
                    app.homebrewMetadata?.token == metadata.token && app.homebrewMetadata?.hasOutdatedEvidence == true
                        && !app.isReadOnly && !metadata.isPinned && !metadata.isDisabled && !metadata.isDeprecated
                }), HomebrewPackageTokenPolicy.isValid(metadata.token) else { throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible }
                let admin = metadata.needsAdministrator || apps.contains(where: \.requiresAdministratorAuthorization)
                guard !admin || administratorEnvironment["SUDO_ASKPASS"] != nil else {
                    results += apps.map { result($0, state: .skipped, detail: AppUpdateAuthorizationError.declined.localizedDescription) }; continue
                }
                var paths = Set(apps.flatMap { $0.homebrewMetadata?.appBundlePaths ?? [] })
                paths.formUnion(apps.filter { !($0.homebrewMetadata?.appBundlePaths.isEmpty ?? true) || ($0.packageKind == .graphicalApplication && $0.bundleURL.pathExtension == "app") }.map { $0.path })
                var identities = [String: ApplicationIdentity](); var versions = [String: ApplicationVersion]()
                var refused = false
                for path in paths.sorted() {
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    guard let before = try await rechecker.snapshot(at: url) else { throw ProviderBackedUpdateExecutorError.applicationMissing }
                    for evidence in apps.compactMap({ recoveryEvidenceByID[$0.id] }) {
                        guard let original = evidence.artifacts.first(where: { $0.path == path }), original.originalIdentity == before.application.identity,
                            original.originalVersion == before.application.installedVersion else { throw ProviderBackedUpdateExecutorError.applicationVersionChanged }
                    }
                    identities[path] = before.application.identity; versions[path] = before.application.installedVersion
                    let lifecycle = try await runtime.stop(url)
                    let originallyRunning = apps.contains { recoveryEvidenceByID[$0.id]?.artifacts.contains(where: { $0.path == path && $0.wasRunning }) == true }
                    if (lifecycle.wasRunning || originallyRunning) && lifecycle.stopped { running.insert(url) }
                    if !lifecycle.stopped { refused = true; break }
                }
                if refused {
                    let detail = L10n.text("应用未退出，已跳过整个 Homebrew 包", "Application did not quit; entire Homebrew package skipped") + (await reopen(running))
                    results += apps.map { result($0, state: .skipped, detail: detail) }; continue
                }
                let packageVersions = try await installedVersions(metadata, brew: brew, env: env)
                guard Set(packageVersions.split(separator: " ").map(String.init)) == Set(metadata.installedVersions) else { throw ProviderBackedUpdateExecutorError.applicationVersionChanged }
                for app in apps {
                    if let identity = identities[app.path], identity != app.identity { throw ProviderBackedUpdateExecutorError.applicationIdentityChanged }
                    if let version = versions[app.path], version != app.installedVersion { throw ProviderBackedUpdateExecutorError.applicationVersionChanged }
                }
                ready.append(.init(apps: apps, metadata: metadata, versions: packageVersions, identities: identities, appVersions: versions, wasRunning: running))
            } catch {
                let detail = AppUpdateErrorRedaction.text(error.localizedDescription) + (await reopen(running))
                results += apps.map { result($0, state: Task.isCancelled ? .cancelled : .failed, detail: detail) }
            }
        }
        for kind in [HomebrewPackageKind.formula, .cask] {
            for admin in [false, true] {
                let proposed = ready.filter { $0.metadata.kind == kind && ($0.metadata.needsAdministrator || $0.apps.contains(where: \.requiresAdministratorAuthorization)) == admin }
                var group = [Before]()
                for item in proposed {
                    if await anyRunning(item.identities.keys) {
                        let detail = L10n.text("应用在执行前重新运行，已跳过整个 Homebrew 包", "An application relaunched before execution; entire package skipped") + (await reopen(item.wasRunning))
                        results += item.apps.map { result($0, state: .skipped, detail: detail) }
                    } else { group.append(item) }
                }
                guard !group.isEmpty else { continue }
                let commandEnv = admin ? env.merging(administratorEnvironment) { _, new in new } : env
                for app in group.flatMap(\.apps) { await progress(.init(applicationID: app.id, state: .installing, fraction: nil, detail: L10n.text("Homebrew 正在批量更新", "Homebrew batch is updating"))) }
                var commandFailure: (any Error)?
                do {
                    try Task.checkCancellation()
                    try await upgrade(brew: brew, frozen: frozen, metadata: group.map(\.metadata), environment: commandEnv, admin: admin)
                } catch { commandFailure = error }
                for item in group {
                    var completion = commandCompletion(commandFailure)
                    do {
                        if let failure = commandFailure as? AppUpdateAuthorizationError { throw failure }
                        let lateSystemCancellation = Task.isCancelled && commandFailure as? AppUpdateCommandError != .cancelled
                        if (commandFailure as? AppUpdateCommandError)?.isUnconfirmedStop == true || lateSystemCancellation {
                            let evidence = await readOnlyEvidence(item, brew: brew, env: env)
                            results += item.apps.map { result($0, state: .needsReconciliation, detail: AppUpdateCommandError.needsReconciliation.localizedDescription + evidence,
                                recoveryEvidence: recoveryEvidence(item, application: $0, completion: completion)) }
                            continue
                        }
                        if commandFailure as? AppUpdateCommandError == .cancelled || Task.isCancelled { throw AppUpdateCommandError.cancelled }
                        var observed: [String: ApplicationVersion]
                        do { observed = try await verify(item, brew: brew, env: env) }
                        catch {
                            // Symbolic latest is never retried merely because its
                            // list string stayed unchanged. Other tokens continue.
                            guard commandFailure != nil, group.count > 1,
                                completion.permitsRetry,
                                (commandFailure as? AppUpdateCommandError)?.normalExitCode.map({ $0 != 0 }) == true,
                                error as? ProviderBackedUpdateExecutorError == .versionDidNotChange,
                                !Task.isCancelled, !HomebrewSymbolicVersion.isLatest(item.metadata.currentVersion),
                                !item.metadata.installedVersions.contains(where: HomebrewSymbolicVersion.isLatest),
                                try await installedVersions(item.metadata, brew: brew, env: env) == item.versions,
                                !(await anyRunning(item.identities.keys)) else { throw error }
                            completion = .stopped
                            do { try await upgrade(brew: brew, frozen: frozen, metadata: [item.metadata], environment: commandEnv, admin: admin) }
                            catch {
                                completion = commandCompletion(error)
                                guard (error as? AppUpdateCommandError)?.isNormalExit == true else { throw error }
                            }
                            observed = try await verify(item, brew: brew, env: env)
                        }
                        var stillFinishing = false
                        if completion.knownProcessesAlive {
                            if try await processSafety.waitForKnownProcesses(&completion, homebrewPrefixes: [item.metadata.prefixPath].compactMap { $0 }) {
                                completion.knownProcessesAlive = false
                                // The installer can roll back after an earlier
                                // target snapshot. Re-read the entire package.
                                observed = try await verify(item, brew: brew, env: env)
                            } else { stillFinishing = true }
                        }
                        var recovered = recoveryEvidence(item, application: item.apps[0], completion: completion)
                        var reopeningDetail = ""
                        if !stillFinishing { (recovered, reopeningDetail) = await recovered.reopening(using: runtime) }
                        let detail = L10n.text("已核验 Homebrew 新版本", "New Homebrew version verified")
                            + (stillFinishing ? L10n.text("；安装程序仍在收尾，稍后再打开。仍保持隔离，可用“核验并恢复”。", "; the installer is still finishing; open the app later. Quarantine remains; use Verify and Recover.") : reopeningDetail)
                        for app in item.apps {
                            await progress(.init(applicationID: app.id, state: .verifying, fraction: nil, detail: detail))
                            var evidence = recoveryEvidence(item, application: app, completion: completion); evidence.reopenOutcomes = recovered.reopenOutcomes
                            results.append(result(app, state: .completed, version: observed[app.id], detail: detail, recoveryEvidence: evidence, installationIsolated: stillFinishing))
                        }
                    } catch {
                        let uncertain = error as? AppUpdateCommandError == .needsReconciliation
                            || !completion.permitsRetry
                            || !(error is ProviderBackedUpdateExecutorError || (error as NSError).domain == "Homebrew.UpdateIdentity" || error is AppUpdateAuthorizationError || (error as? AppUpdateCommandError)?.isNormalExit == true || error as? AppUpdateCommandError == .cancelled)
                        let state: ApplicationUpdateTaskState = uncertain ? .needsReconciliation : ((Task.isCancelled || error as? AppUpdateCommandError == .cancelled) ? .cancelled : .failed)
                        let evidence = commandFailure.map { "\nHomebrew: " + AppUpdateErrorRedaction.text($0.localizedDescription) } ?? ""
                        results += item.apps.map { result($0, state: state, detail: AppUpdateErrorRedaction.text(error.localizedDescription) + evidence,
                            confirmedStopped: error as? AppUpdateCommandError == .cancelled, recoveryEvidence: recoveryEvidence(item, application: $0, completion: completion)) }
                    }
                }
            }
        }
        return results
    }
    private func upgrade(brew: URL, frozen: AppUpdateExecutableIdentity, metadata: [HomebrewPackageMetadata], environment: [String: String], admin: Bool) async throws {
        guard try captureExecutable(brew) == frozen else { throw AppUpdateAuthorizationError.sourceChanged(brew.path) }
        var failure: (any Error)?
        do { _ = try await command.run(executableURL: brew, arguments: arguments(metadata), environment: environment, timeout: 30 * 60) }
        catch { failure = error }
        if admin {
            do { try await revokeAuthorization() }
            catch { throw AppUpdateCommandError.needsReconciliation }
        }
        if let failure { throw failure }
    }
    func reconcile(application: InstalledApplication?, task: ApplicationUpdateTask, reopenWhenVerified: Bool = true) async throws -> ApplicationUpdateInstallResult {
        guard let brew = executable(), let metadata = task.recoveryEvidence?.homebrewMetadata ?? application?.homebrewMetadata,
            HomebrewPackageTokenPolicy.isValid(metadata.token) else { throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible }
        var reader = self
        reader.frozenExecutable = try captureExecutable(brew)
        let env = HomebrewCommandEnvironment.allowlist(executableURL: brew, environment: environment())
        let evidence: ApplicationUpdateRecoveryEvidence
        if let frozen = task.recoveryEvidence {
            guard Set(metadata.appBundlePaths).isSubset(of: Set(frozen.artifacts.map(\.path))) else { throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible }
            evidence = frozen
        } else {
            // Legacy GUI casks lack all artifact baselines. A shorter, freshly
            // scanned list is not a substitute for the missing frozen evidence.
            guard metadata.appBundlePaths.isEmpty, application?.packageKind != .graphicalApplication else { throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible }
            evidence = .init(applicationPath: application?.path ?? "", homebrewMetadata: metadata, artifacts: [], packageVersionsBefore: task.originalVersion.preferred)
        }
        let observed: [String: ApplicationVersion]
        do {
            observed = try await reader.verify(metadata: metadata, versionsBefore: evidence.packageVersionsBefore ?? task.originalVersion.preferred,
                artifacts: evidence.artifacts, selections: [.init(id: task.applicationID, path: evidence.applicationPath, target: task.targetVersion)], brew: brew, env: env)
        } catch AppUpdateCommandError.needsReconciliation {
            return .init(applicationID: task.applicationID, state: .needsReconciliation, observedVersion: nil,
                detail: AppUpdateCommandError.needsReconciliation.localizedDescription, recoveryEvidence: evidence)
        }
        let (reopened, detail) = reopenWhenVerified ? await evidence.reopening(using: runtime) : (evidence, "")
        return .init(applicationID: task.applicationID, state: .completed, observedVersion: observed[task.applicationID],
            detail: L10n.text("已核验 Homebrew 整包版本与身份", "Homebrew package versions and identities verified") + detail,
            recoveryEvidence: reopened)
    }
    private func recoveryEvidence(_ before: Before, application: InstalledApplication, completion: AppUpdateCommandCompletionEvidence? = nil) -> ApplicationUpdateRecoveryEvidence {
        .init(applicationPath: application.path, homebrewMetadata: before.metadata, artifacts: before.identities.keys.sorted().map { path in
            .init(path: path, originalIdentity: before.identities[path]!, originalVersion: before.appVersions[path]!,
                wasRunning: before.wasRunning.contains(URL(fileURLWithPath: path, isDirectory: true)))
        }, commandCompletion: completion, packageVersionsBefore: before.versions)
    }
    private func commandCompletion(_ error: (any Error)?) -> AppUpdateCommandCompletionEvidence {
        if let error = error as? AppUpdateCommandError {
            if error == .cancelled { return .stopped }
            return error.completionEvidence ?? .init(trackingComplete: false, knownProcessesAlive: false, processes: [])
        }
        if error == nil || error is AppUpdateAuthorizationError { return .stopped }
        return .init(trackingComplete: false, knownProcessesAlive: false, processes: [])
    }
    private func readOnlyEvidence(_ before: Before, brew: URL, env: [String: String]) async -> String {
        // A cancelled installation task cannot cancel this bounded, read-only
        // readback. It never starts an installer or automatically retries.
        await Task.detached(priority: .utility) {
            do {
                let versions = try await installedVersions(before.metadata, brew: brew, env: env)
                var evidence = [before.metadata.token + ": " + versions]
                for path in before.identities.keys.sorted() {
                    if let disk = try await rechecker.snapshot(at: URL(fileURLWithPath: path, isDirectory: true)) {
                        evidence.append(path + " · " + disk.application.installedVersion.preferred + " · Team ID: " + (disk.signature.teamIdentifier ?? "nil"))
                    } else { evidence.append(path + L10n.text(" · 应用不存在", " · application missing")) }
                }
                return "\n" + evidence.joined(separator: "\n")
            } catch { return "\n" + L10n.text("版本核验失败：", "Version verification failed: ") + AppUpdateErrorRedaction.text(error.localizedDescription) }
        }.value
    }
    private func arguments(_ metadata: [HomebrewPackageMetadata]) -> [String] {
        let kind = metadata[0].kind
        var args = ["upgrade", "--" + kind.rawValue]
        if kind == .cask && metadata.contains(where: { $0.effectiveOutdatedProvenance == .greedy }) { args.append("--greedy") }
        return args + metadata.map(\.token)
    }
    private func anyRunning<S: Sequence>(_ paths: S) async -> Bool where S.Element == String {
        for path in paths { if await runtime.isRunning(URL(fileURLWithPath: path, isDirectory: true)) { return true } }
        return false
    }
    private func reopen(_ urls: Set<URL>) async -> String {
        var details = [String]()
        for url in urls.sorted(by: { $0.path < $1.path }) {
            do { try await runtime.reopen(url); details.append(L10n.text("已重开：", "Reopened: ") + url.path) }
            catch { details.append(L10n.text("重开失败：", "Reopen failed: ") + url.path + " · " + AppUpdateErrorRedaction.text(error.localizedDescription)) }
        }
        return details.isEmpty ? "" : "\n" + details.joined(separator: "\n")
    }
    private func installedVersions(_ metadata: HomebrewPackageMetadata, brew: URL, env: [String: String]) async throws -> String {
        if let frozenExecutable, try captureExecutable(brew) != frozenExecutable { throw AppUpdateAuthorizationError.sourceChanged(brew.path) }
        let data = try await command.run(executableURL: brew, arguments: ["list", "--versions", "--" + metadata.kind.rawValue, metadata.token], environment: env, timeout: 30)
        let fields = String(decoding: data, as: UTF8.self).trimmed.split(whereSeparator: \.isWhitespace)
        guard fields.first == Substring(metadata.token), fields.count >= 2 else { throw ProviderBackedUpdateExecutorError.applicationMissing }
        return fields.dropFirst().joined(separator: " ")
    }
    private struct VerificationSelection: Sendable {
        let id: String
        let path: String
        let target: ApplicationVersion?
    }
    private func verify(_ before: Before, brew: URL, env: [String: String]) async throws -> [String: ApplicationVersion] {
        try await verify(metadata: before.metadata, versionsBefore: before.versions,
            artifacts: recoveryEvidence(before, application: before.apps[0]).artifacts,
            selections: before.apps.map { .init(id: $0.id, path: $0.path, target: $0.availableVersion) }, brew: brew, env: env)
    }
    private func verify(metadata: HomebrewPackageMetadata, versionsBefore: String, artifacts: [ApplicationUpdateArtifactEvidence],
        selections: [VerificationSelection], brew: URL, env: [String: String]) async throws -> [String: ApplicationVersion] {
        let versions = try await installedVersions(metadata, brew: brew, env: env)
        var disk = [String: ApplicationVersion]()
        for artifact in artifacts {
            let path = artifact.path; let identity = artifact.originalIdentity
            guard let after = try await rechecker.snapshot(at: URL(fileURLWithPath: path, isDirectory: true)) else { throw ProviderBackedUpdateExecutorError.applicationMissing }
            guard identity.signingTeamIdentifier?.isEmpty == false, after.signature.isValid,
                after.application.identity.bundleIdentifier == identity.bundleIdentifier,
                after.signature.teamIdentifier == identity.signingTeamIdentifier,
                after.application.signingTeamIdentifier == identity.signingTeamIdentifier else {
                throw NSError(domain: "Homebrew.UpdateIdentity", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("更新后开发者身份不一致，已标记失败", "Developer identity changed after update; marked failed")
                    + "\n\(path)\nTeam ID: \(identity.signingTeamIdentifier ?? "nil") → \(after.signature.teamIdentifier ?? "nil")"])
            }
            guard artifact.originalVersion < after.application.installedVersion else { throw ProviderBackedUpdateExecutorError.versionDidNotChange }
            disk[path] = after.application.installedVersion
        }
        if artifacts.isEmpty && (HomebrewSymbolicVersion.isLatest(metadata.currentVersion) || metadata.installedVersions.contains(where: HomebrewSymbolicVersion.isLatest)) {
            guard try await symbolicVersionEvidence(metadata) else { throw AppUpdateCommandError.needsReconciliation }
        } else if artifacts.isEmpty && versions == versionsBefore { throw ProviderBackedUpdateExecutorError.versionDidNotChange }
        var result = [String: ApplicationVersion]()
        for selection in selections {
            let observed = disk[selection.path] ?? ApplicationVersion(marketing: versions.split(separator: " ").last.map(String.init) ?? "")
            if let target = selection.target, let projected = HomebrewAutomaticUpdateSafety.strictComparableVersionProjection(target.preferred),
                observed < ApplicationVersion(marketing: projected) { throw ProviderBackedUpdateExecutorError.targetVersionNotReached(expected: target, observed: observed) }
            result[selection.id] = observed
        }
        return result
    }
    private func result(_ app: InstalledApplication, state: ApplicationUpdateTaskState, version: ApplicationVersion? = nil, detail: String, confirmedStopped: Bool = false, recoveryEvidence: ApplicationUpdateRecoveryEvidence? = nil, installationIsolated: Bool = false) -> ApplicationUpdateInstallResult {
        .init(applicationID: app.id, state: state, observedVersion: version, detail: detail, confirmedStopped: confirmedStopped, recoveryEvidence: recoveryEvidence, installationIsolated: installationIsolated)
    }
}
