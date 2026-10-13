import Foundation

enum HomebrewAutomaticUpdateSafety {
    /// Homebrew's outdated result also admits tuple/latest casks. The installed
    /// package and, where present, every application identity are read back.
    static func batchTargetVersion(metadata: HomebrewPackageMetadata, installedVersion: ApplicationVersion) -> ApplicationVersion? {
        guard metadata.hasOutdatedEvidence, let version = metadata.currentVersion?.trimmed.nonEmpty else { return nil }
        return strictlyNewerCurrentVersion(metadata: metadata, installedVersion: installedVersion)
            ?? ApplicationVersion(marketing: version)
    }

    /// Returns a concrete Homebrew target only when the cask/formula reports a
    /// real, strictly newer version. Symbolic targets such as `:latest`, empty
    /// values, and versions containing punctuation outside the normal version
    /// alphabet are intentionally rejected.
    static func strictlyNewerCurrentVersion(
        metadata: HomebrewPackageMetadata,
        installedVersion: ApplicationVersion
    ) -> ApplicationVersion? {
        guard metadata.isOutdated,
              let rawCurrent = metadata.currentVersion?.trimmed.nonEmpty,
              !containsSymbolicLatest(installedVersion.preferred),
              !metadata.installedVersions.contains(where: containsSymbolicLatest),
              let currentProjection = strictComparableVersionProjection(rawCurrent),
              let installedProjection = strictComparableVersionProjection(
                  installedVersion.preferred
              ),
              metadata.installedVersions.contains(where: { rawInstalled in
                  guard let metadataProjection = strictComparableVersionProjection(
                      rawInstalled
                  ) else {
                      return false
                  }
                  return ApplicationVersion.compare(
                      metadataProjection,
                      installedProjection
                  ) == .orderedSame
              })
        else {
            return nil
        }

        let target = ApplicationVersion(marketing: currentProjection)
        guard !target.preferred.isEmpty,
              ApplicationVersion.compare(
                  target.preferred,
                  installedProjection
              ) == .orderedDescending else {
            return nil
        }
        return target
    }

    /// Homebrew cask versions are CSV tuples in the general case. Automatic
    /// updates may erase a second field only when it is narrowly recognizable
    /// as an artifact digest; numeric build tuples and all other ambiguous CSV
    /// forms remain manual.
    static func strictComparableVersionProjection(_ rawValue: String) -> String? {
        let value = rawValue.trimmed
        guard !value.isEmpty else { return nil }
        let components = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map(String.init)
        if components.count == 1 {
            return isConcreteVersion(components[0]) ? components[0] : nil
        }
        guard components.count == 2,
              let version = components.first,
              let digest = components.last,
              !version.isEmpty,
              isConcreteVersion(version),
              (7...128).contains(digest.unicodeScalars.count),
              digest.unicodeScalars.allSatisfy({ hexadecimalDigits.contains($0) }),
              digest.unicodeScalars.contains(where: { hexadecimalLetters.contains($0) }) else {
            return nil
        }
        return version
    }

    /// Keeps a raw Homebrew CSV tuple available for manual presentation only
    /// when both the reported and installed values are structurally safe. This
    /// does not claim that the tuple can be ordered for automatic execution.
    static func reportedManualVersion(
        metadata: HomebrewPackageMetadata,
        installedVersion: ApplicationVersion
    ) -> ApplicationVersion? {
        guard metadata.isOutdated,
              let rawCurrent = metadata.currentVersion?.trimmed.nonEmpty,
              !containsSymbolicLatest(installedVersion.preferred),
              !metadata.installedVersions.contains(where: containsSymbolicLatest),
              safeManualVersionComponents(rawCurrent) != nil,
              let installedBase = safeManualVersionComponents(
                  installedVersion.preferred
              )?.first,
              metadata.installedVersions.contains(where: { rawInstalled in
                  guard let metadataBase = safeManualVersionComponents(rawInstalled)?.first else {
                      return false
                  }
                  return ApplicationVersion.compare(
                      metadataBase,
                      installedBase
                  ) == .orderedSame
              }) else {
            return nil
        }
        return ApplicationVersion(marketing: rawCurrent)
    }

    private static let concreteVersionCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: ".-_+"))
    private static let hexadecimalDigits = CharacterSet(
        charactersIn: "0123456789abcdefABCDEF"
    )
    private static let hexadecimalLetters = CharacterSet(
        charactersIn: "abcdefABCDEF"
    )

    private static func isConcreteVersion(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix(":")
            && !isSymbolicLatest(value)
            && value.unicodeScalars.allSatisfy(concreteVersionCharacters.contains)
            && value.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
    }

    private static func isSymbolicLatest(_ value: String) -> Bool {
        HomebrewSymbolicVersion.isLatest(value)
    }

    private static func containsSymbolicLatest(_ value: String) -> Bool {
        value.split(separator: ",", omittingEmptySubsequences: false)
            .contains { isSymbolicLatest(String($0)) }
    }

    private static func safeManualVersionComponents(_ rawValue: String) -> [String]? {
        let value = rawValue.trimmed
        guard !value.isEmpty else { return nil }
        let components = value.split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard (1...5).contains(components.count),
              let first = components.first,
              isConcreteVersion(first),
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component == component.trimmed
                      && component.unicodeScalars.allSatisfy(
                          concreteVersionCharacters.contains
                      )
                      && component.unicodeScalars.contains(where: {
                          CharacterSet.alphanumerics.contains($0)
                      })
              }) else {
            return nil
        }
        return components
    }

    static func hasExactCaskArtifactPath(
        application: InstalledApplication,
        metadata: HomebrewPackageMetadata
    ) -> Bool {
        guard metadata.kind == .cask,
              application.sourceEvidence.contains("homebrew-match:exact-artifact-path")
        else {
            return false
        }
        let applicationPaths = Set([
            ApplicationPathNormalizer.comparisonKey(for: application.bundleURL),
            ApplicationPathNormalizer.comparisonKey(for: application.bundleURL.resolvingSymlinksInPath()),
        ])
        let artifactPaths = Set(metadata.appBundlePaths.flatMap { path -> [String] in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return [
                ApplicationPathNormalizer.comparisonKey(for: url),
                ApplicationPathNormalizer.comparisonKey(for: url.resolvingSymlinksInPath()),
            ]
        })
        return !applicationPaths.isDisjoint(with: artifactPaths)
    }

    static func hasVerifiedCaskSigningIdentity(_ application: InstalledApplication) -> Bool {
        guard application.sourceEvidence.contains("valid-code-signature"),
              application.identity.isCompleteForAutomaticUpdates,
              let codeIdentifier = application.codeSigningIdentifier?.trimmed.nonEmpty
        else {
            return false
        }
        return codeIdentifier == application.bundleIdentifier
    }
}

enum HomebrewUpdateRecipeBuilder {
    static let allowedEnvironmentKeys = HomebrewCommandEnvironment.allowedKeys

    static func arguments(for application: InstalledApplication) -> [String]? {
        guard application.updateProvider == .homebrew else { return nil }
        guard let metadata = application.homebrewMetadata else {
            guard let token = application.caskToken?.trimmed.nonEmpty,
                  HomebrewPackageTokenPolicy.isValid(token) else { return nil }
            return ["upgrade", "--cask", token]
        }
        guard HomebrewPackageTokenPolicy.isValid(metadata.token) else { return nil }
        switch metadata.kind {
        case .cask:
            guard application.caskToken == nil || application.caskToken == metadata.token else {
                return nil
            }
            return ["upgrade", "--cask"] + (metadata.effectiveOutdatedProvenance == .greedy ? ["--greedy"] : []) + [metadata.token]
        case .formula:
            return ["upgrade", metadata.token]
        }
    }

    static func copyCommand(for application: InstalledApplication) -> String? {
        guard let arguments = arguments(for: application) else { return nil }
        return (["brew"] + arguments).joined(separator: " ")
    }

    static func make(
        application: InstalledApplication,
        executableURL: URL,
        environment: [String: String]
    ) -> ApplicationUpdateExecutionRecipe? {
        guard let arguments = arguments(for: application),
              let metadata = application.homebrewMetadata,
              metadata.hasOutdatedEvidence,
              HomebrewPackageTokenPolicy.isValid(metadata.token),
              !metadata.isPinned,
              !metadata.isDisabled,
              !metadata.isDeprecated,
              !application.isReadOnly,
              let targetVersion = HomebrewAutomaticUpdateSafety.batchTargetVersion(
                  metadata: metadata,
                  installedVersion: application.installedVersion
              ),
              application.availableVersion == targetVersion else {
            return nil
        }
        var verificationSteps: [ApplicationUpdateVerificationStep] = [
            .trustedExecutable,
            .installedVersion,
        ]
        if metadata.kind == .cask && !metadata.appBundlePaths.isEmpty {
            verificationSteps.append(contentsOf: [
                .codeSignature,
                .bundleIdentifier,
                .teamIdentifier,
            ])
        }
        let applicationsToQuit = application.requiresApplicationQuit || application.isRunning
            ? [application.bundleIdentifier]
            : []
        return ApplicationUpdateExecutionRecipe(
            applicationID: application.id,
            displayName: application.displayName,
            currentVersion: application.installedVersion,
            targetVersion: application.availableVersion,
            sourceProvider: .homebrew,
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: nil,
            environmentAllowlist: HomebrewCommandEnvironment.allowlist(
                executableURL: executableURL,
                environment: environment
            ),
            requiresAdministrator: application.requiresAdministratorAuthorization,
            applicationsToQuit: applicationsToQuit,
            downloadURL: nil,
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedVersion: application.availableVersion,
            checksumSHA256: nil,
            verificationSteps: verificationSteps,
            rollbackPlan: .unavailable(
                reason: L10n.text(
                    "Homebrew 不提供可验证的自动回滚；失败会保留真实错误并继续其他项目。",
                    "Homebrew does not provide a verifiable automatic rollback; failures are reported and the remaining items continue."
                )
            )
        )
    }

    static func isValid(
        _ recipe: ApplicationUpdateExecutionRecipe,
        for preparedUpdate: PreparedApplicationUpdate
    ) -> Bool {
        guard recipe.applicationID == preparedUpdate.applicationID,
              recipe.sourceProvider == .homebrew,
              recipe.currentVersion == preparedUpdate.originalVersion,
              recipe.targetVersion == preparedUpdate.targetVersion,
              recipe.expectedBundleIdentifier == preparedUpdate.originalIdentity.bundleIdentifier,
              recipe.expectedTeamIdentifier == preparedUpdate.originalIdentity.signingTeamIdentifier,
              recipe.expectedVersion == preparedUpdate.targetVersion,
              validatedInvocation(arguments: recipe.arguments) != nil,
              Set(recipe.environmentAllowlist.keys).isSubset(of: allowedEnvironmentKeys),
              recipe.environmentAllowlist["HOME"]?.trimmed.nonEmpty != nil,
              recipe.environmentAllowlist["PATH"]?.trimmed.nonEmpty != nil,
              recipe.environmentAllowlist["TMPDIR"]?.trimmed.nonEmpty != nil,
              recipe.environmentAllowlist["HOMEBREW_NO_AUTO_UPDATE"] == "1",
              recipe.environmentAllowlist["HOMEBREW_NO_ANALYTICS"] == "1",
              recipe.environmentAllowlist["HOMEBREW_NO_INSTALL_CLEANUP"] == "1",
              recipe.environmentAllowlist["NONINTERACTIVE"] == "1"
        else {
            return false
        }
        return true
    }

    static func validatedInvocation(
        arguments: [String]
    ) -> (kind: HomebrewPackageKind, token: String)? {
        if arguments.count == 2,
           arguments[0] == "upgrade",
           HomebrewPackageTokenPolicy.isValid(arguments[1]) {
            return (.formula, arguments[1])
        }
        if arguments.count == 4, arguments[0] == "upgrade", arguments[1] == "--cask",
           arguments[2] == "--greedy", HomebrewPackageTokenPolicy.isValid(arguments[3]) {
            return (.cask, arguments[3])
        }
        if arguments.count == 3,
           arguments[0] == "upgrade",
           arguments[1] == "--cask",
           HomebrewPackageTokenPolicy.isValid(arguments[2]) {
            return (.cask, arguments[2])
        }
        return nil
    }
}

final class HomebrewProvider: ApplicationUpdateProvider, @unchecked Sendable {
    let identifier = ApplicationUpdateProviderIdentifier.homebrew

    private let activeUpdatesLock = NSLock()
    private var activeUpdates = [String: HomebrewCommandCancellation]()
    private var preparedApplications = [String: InstalledApplication]()
    private let applicationRechecker: any InstalledApplicationRechecking
    private let installedFormulaVersionProvider: @Sendable (String) async throws -> ApplicationVersion?
    private let homebrewExecutableProvider: @Sendable () -> URL?
    private let environmentProvider: @Sendable () -> [String: String]
    private let commandCapture: @Sendable (
        URL,
        [String],
        [String: String],
        HomebrewCommandCancellation
    ) throws -> String

    init(
        applicationRechecker: any InstalledApplicationRechecking = VerifiedInstalledApplicationRechecker(),
        installedFormulaVersionProvider: @escaping @Sendable (String) async throws -> ApplicationVersion? = { token in
            try await HomebrewInventoryScanner().installedFormulaVersion(token: token)
        },
        homebrewExecutableProvider: @escaping @Sendable () -> URL? = {
            HomebrewInventoryScanner().locateHomebrewExecutable()
        },
        environmentProvider: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        commandCapture: @escaping @Sendable (
            URL,
            [String],
            [String: String],
            HomebrewCommandCancellation
        ) throws -> String = { executableURL, arguments, environment, cancellation in
            try Shell.captureCancellable(
                executableURL.path,
                arguments,
                environment: environment,
                timeout: 15 * 60,
                outputByteLimit: 2 * 1_024 * 1_024,
                cancellationCheck: { cancellation.isCancelled }
            )
        }
    ) {
        self.applicationRechecker = applicationRechecker
        self.installedFormulaVersionProvider = installedFormulaVersionProvider
        self.homebrewExecutableProvider = homebrewExecutableProvider
        self.environmentProvider = environmentProvider
        self.commandCapture = commandCapture
    }

    func canHandle(_ application: InstalledApplication) async -> Bool {
        application.homebrewMetadata != nil
    }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        guard let metadata = application.homebrewMetadata else {
            throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
        }
        let isAutomaticallyEligible = isAutomaticallyEligible(application)
        return ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: [
                "homebrew-cli-json-v2",
                "homebrew-kind:\(metadata.kind.rawValue)",
            ],
            requiresUserInteraction: !isAutomaticallyEligible,
            canAutomaticallyUpdate: isAutomaticallyEligible
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        guard let metadata = application.homebrewMetadata else {
            throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
        }
        guard metadata.isOutdated else {
            return ApplicationUpdateCheckResult(
                status: .upToDate,
                availableVersion: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                warning: nil
            )
        }

        guard let targetVersion = HomebrewAutomaticUpdateSafety.batchTargetVersion(
            metadata: metadata,
            installedVersion: application.installedVersion
        ) else {
            let reportedVersion = HomebrewAutomaticUpdateSafety.reportedManualVersion(
                metadata: metadata,
                installedVersion: application.installedVersion
            )
            return ApplicationUpdateCheckResult(
                status: reportedVersion == nil ? .latestVersionUnknown : .updateAvailable,
                availableVersion: reportedVersion,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                warning: L10n.text(
                    "Homebrew 返回的目标版本无法与当前版本严格比较。",
                    "Homebrew returned a target version that cannot be strictly compared with the installed version."
                )
            )
        }

        return ApplicationUpdateCheckResult(
            status: isAutomaticallyEligible(application) ? .automaticallyUpdatable : .updateAvailable,
            availableVersion: targetVersion,
            releaseDate: nil,
            releaseNotes: nil,
            downloadSize: nil,
            warning: ineligibilityReason(application)
        )
    }

    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        guard let metadata = application.homebrewMetadata,
              metadata.hasOutdatedEvidence,
              application.canAutomaticallyUpdate,
              isAutomaticallyEligible(application),
              let executableURL = homebrewExecutableProvider(),
              let recipe = HomebrewUpdateRecipeBuilder.make(
                application: application,
                executableURL: executableURL,
                environment: environmentProvider()
              )
        else {
            throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
        }
        guard !application.isRunning else {
            throw ApplicationScanningError.providerUnsupported("homebrew-waiting-for-quit")
        }
        let prepared = PreparedApplicationUpdate(
            applicationID: application.id,
            providerIdentifier: identifier,
            originalIdentity: application.identity,
            originalVersion: application.installedVersion,
            targetVersion: application.availableVersion,
            providerPayload: [:],
            executionRecipe: recipe
        )
        activeUpdatesLock.withLock { preparedApplications[application.id] = application }
        return prepared
    }

    func install(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        guard preparedUpdate.providerIdentifier == identifier,
              let recipe = preparedUpdate.executionRecipe,
              HomebrewUpdateRecipeBuilder.isValid(recipe, for: preparedUpdate),
              let application = activeUpdatesLock.withLock({ preparedApplications[preparedUpdate.applicationID] }),
              application.identity == preparedUpdate.originalIdentity,
              application.installedVersion == preparedUpdate.originalVersion,
              application.availableVersion == preparedUpdate.targetVersion,
              let currentlyTrustedExecutable = homebrewExecutableProvider(),
              ApplicationPathNormalizer.comparisonKey(for: currentlyTrustedExecutable)
                == ApplicationPathNormalizer.comparisonKey(for: recipe.executableURL)
        else {
            throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
        }
        defer {
            _ = activeUpdatesLock.withLock { preparedApplications.removeValue(forKey: preparedUpdate.applicationID) }
        }

        // A display scan (even a signed one) is not authority to execute.
        // Re-open this actual target after preparation and immediately before
        // launching brew, including the formula branch's current CLI inventory.
        _ = try await verifyActualTarget(application, prepared: preparedUpdate, afterInstall: false)
        try Task.checkCancellation()

        let cancellation = HomebrewCommandCancellation()
        activeUpdatesLock.withLock {
            activeUpdates[preparedUpdate.applicationID] = cancellation
        }
        defer {
            _ = activeUpdatesLock.withLock {
                activeUpdates.removeValue(forKey: preparedUpdate.applicationID)
            }
        }

        progress(
            ApplicationUpdateProgressEvent(
                applicationID: preparedUpdate.applicationID,
                state: .installing,
                fraction: nil,
                detail: L10n.text("Homebrew 正在更新", "Homebrew is updating")
            )
        )

        let output = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try self.commandCapture(
                    recipe.executableURL,
                    recipe.arguments,
                    recipe.environmentAllowlist,
                    cancellation
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }

        try Task.checkCancellation()
        _ = try await verifyActualTarget(application, prepared: preparedUpdate, afterInstall: true)
        progress(
            ApplicationUpdateProgressEvent(
                applicationID: preparedUpdate.applicationID,
                state: .verifying,
                fraction: nil,
                detail: L10n.text("正在重新读取磁盘版本", "Re-reading the on-disk version")
            )
        )
        let detail = output.trimmed.nonEmpty
            ?? L10n.text("Homebrew 命令已完成，等待磁盘版本验证。", "Homebrew completed; on-disk version verification is pending.")
        return ApplicationUpdateInstallResult(
            applicationID: preparedUpdate.applicationID,
            state: .needsReconciliation,
            observedVersion: nil,
            detail: detail
        )
    }

    func cancelUpdate(for application: InstalledApplication) async {
        let cancellation = activeUpdatesLock.withLock {
            activeUpdates[application.id]
        }
        cancellation?.cancel()
        _ = activeUpdatesLock.withLock { preparedApplications.removeValue(forKey: application.id) }
    }

    private func verifyActualTarget(
        _ application: InstalledApplication,
        prepared: PreparedApplicationUpdate,
        afterInstall: Bool
    ) async throws -> ApplicationVersion {
        guard let metadata = application.homebrewMetadata else {
            throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible
        }
        let version: ApplicationVersion
        if metadata.kind == .formula {
            guard let current = try await installedFormulaVersionProvider(metadata.token) else {
                throw ProviderBackedUpdateExecutorError.applicationMissing
            }
            version = current
        } else {
            guard let snapshot = try await applicationRechecker.snapshot(at: application.bundleURL) else {
                throw ProviderBackedUpdateExecutorError.applicationMissing
            }
            let current = snapshot.application
            guard snapshot.signature.isValid,
                  current.sourceEvidence.contains("valid-code-signature"),
                  current.bundleURL.standardizedFileURL == application.bundleURL.standardizedFileURL,
                  current.identity == prepared.originalIdentity,
                  snapshot.signature.teamIdentifier == prepared.originalIdentity.signingTeamIdentifier,
                  snapshot.signature.codeSigningIdentifier == prepared.originalIdentity.codeSigningIdentifier else {
                throw ProviderBackedUpdateExecutorError.applicationIdentityChanged
            }
            guard !current.isRunning else {
                throw ApplicationScanningError.providerUnsupported("homebrew-waiting-for-quit")
            }
            guard !current.isReadOnly else {
                throw ProviderBackedUpdateExecutorError.applicationNoLongerEligible
            }
            version = current.installedVersion
        }
        if afterInstall {
            guard version != prepared.originalVersion else {
                throw ProviderBackedUpdateExecutorError.versionDidNotChange
            }
            guard let target = prepared.targetVersion, version >= target else {
                throw ProviderBackedUpdateExecutorError.applicationVersionChanged
            }
        } else if version != prepared.originalVersion {
            throw ProviderBackedUpdateExecutorError.applicationVersionChanged
        }
        return version
    }

    private func isAutomaticallyEligible(_ application: InstalledApplication) -> Bool {
        guard let metadata = application.homebrewMetadata,
              homebrewExecutableProvider() != nil,
              HomebrewPackageTokenPolicy.isValid(metadata.token),
              metadata.hasOutdatedEvidence,
              metadata.currentVersion?.trimmed.nonEmpty != nil,
              !metadata.isPinned,
              !metadata.isDisabled,
              !metadata.isDeprecated,
              !application.isReadOnly
        else {
            return false
        }
        guard HomebrewAutomaticUpdateSafety.batchTargetVersion(
            metadata: metadata,
            installedVersion: application.installedVersion
        ) != nil else {
            return false
        }
        return true
    }

    private func ineligibilityReason(_ application: InstalledApplication) -> String? {
        guard let metadata = application.homebrewMetadata else { return nil }
        if homebrewExecutableProvider() == nil {
            return L10n.text(
                "未找到受信任的 Homebrew，可保留命令供高级用户手动处理。",
                "A trusted Homebrew installation was not found; the command remains available as an advanced fallback."
            )
        }
        if !metadata.hasOutdatedEvidence {
            return L10n.text("没有经过核实的 Homebrew 过期清单。", "No verified Homebrew outdated inventory.")
        }
        if metadata.isPinned {
            return L10n.text("Homebrew 项目已固定版本，已排除自动更新。", "The Homebrew item is pinned.")
        }
        if metadata.isDisabled {
            return L10n.text("Homebrew 项目已禁用。", "The Homebrew item is disabled.")
        }
        if metadata.isDeprecated {
            return L10n.text("Homebrew 项目已弃用。", "The Homebrew item is deprecated.")
        }
        if application.isReadOnly {
            return L10n.text("应用位于只读卷。", "The application is on a read-only volume.")
        }
        return nil
    }
}
