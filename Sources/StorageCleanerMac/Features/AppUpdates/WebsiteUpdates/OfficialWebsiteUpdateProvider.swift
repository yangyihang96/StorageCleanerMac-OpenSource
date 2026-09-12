import Foundation

final class OfficialWebsiteUpdateProvider: ApplicationUpdateStagingProvider, @unchecked Sendable {
    let identifier = ApplicationUpdateProviderIdentifier.officialWebsite
    private let releaseChecker: OfficialReleaseChecker
    private let downloadResolver: OfficialDownloadResolver
    private let installer: OfficialApplicationUpdateInstaller
    private let preparedLock = NSLock()
    private var preparedContexts = [String: OfficialApplicationUpdateContext]()
    private var preparedUpdates = [String: PreparedApplicationUpdate]()
    private var stagedUpdates = [String: OfficialApplicationUpdateStage]()

    init(
        releaseChecker: OfficialReleaseChecker = OfficialReleaseChecker(),
        downloadResolver: OfficialDownloadResolver = OfficialDownloadResolver(),
        installer: OfficialApplicationUpdateInstaller = OfficialApplicationUpdateInstaller()
    ) {
        self.releaseChecker = releaseChecker
        self.downloadResolver = downloadResolver
        self.installer = installer
    }

    func canHandle(_ application: InstalledApplication) async -> Bool {
        guard let source = application.officialSource else { return false }
        switch source.providerType {
        case .system, .appStore, .homebrew, .sparkle:
            return false
        case .vendorAPI, .officialManifest, .officialWebsite,
             .officialGitHubRelease, .applicationInternalUpdater, .manual, .unknown:
            return true
        }
    }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        guard let source = application.officialSource else {
            throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
        }
        let canAutomaticallyUpdate = OfficialApplicationUpdateInstaller
            .supportsAutomaticInstallation(application: application, source: source)
        return ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: [
                "official-source:\(source.verificationMethod.rawValue)",
                "official-trust:\(source.trustLevel.rawValue)",
                "official-capability:\(source.capability.rawValue)",
            ],
            requiresUserInteraction: !canAutomaticallyUpdate,
            canAutomaticallyUpdate: canAutomaticallyUpdate
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        guard let source = application.officialSource else {
            throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
        }

        if !source.trustLevel.permitsAutomaticDownload {
            let status: ApplicationUpdateStatus = switch source.trustLevel {
            case .candidate, .unverified, .rejected:
                .sourceUnconfirmed
            case .userConfirmed:
                // The page may be opened, but no trusted release adapter has
                // established that an update actually exists.
                .latestVersionUnknown
            case .providerVerified, .registryVerified, .verified:
                .latestVersionUnknown
            }
            return ApplicationUpdateCheckResult(
                status: status,
                availableVersion: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                warning: source.trustLevel == .userConfirmed
                    ? L10n.text("用户确认的来源仅允许打开网页。", "User-confirmed sources may only be opened in a browser.")
                    : L10n.text("官方来源待确认。", "Official source confirmation is required.")
            )
        }

        let releaseOutcome: OfficialReleaseCheckOutcome
        do {
            releaseOutcome = try await releaseChecker.check(application, source: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ApplicationUpdateCheckResult(
                status: .latestVersionUnknown,
                availableVersion: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                warning: L10n.text(
                    "暂时无法从官网确认最新版本：\(error.localizedDescription)",
                    "The latest website version could not be confirmed: \(error.localizedDescription)"
                )
            )
        }

        switch releaseOutcome {
        case let .updateAvailable(release):
            let download = try? downloadResolver.resolve(for: application, release: release)
            let isAutomatic = OfficialApplicationUpdateInstaller.supportsAutomaticInstallation(
                application: application,
                source: source
            ) && download.map {
                OfficialApplicationUpdateInstaller.supportsAutomaticPackageType($0.packageType)
            } == true
                && download?.permitsAutomaticInstallation == true
            let status: ApplicationUpdateStatus = isAutomatic
                ? .automaticallyUpdatable
                : source.capability == .sourceConfirmation
                    ? .sourceUnconfirmed
                    : .websiteUpdateRequired
            return ApplicationUpdateCheckResult(
                status: status,
                availableVersion: release.version,
                releaseDate: release.releaseDate,
                releaseNotes: release.releaseNotes,
                downloadSize: release.downloadSize,
                warning: !isAutomatic
                    && (source.capability == .automatic || source.capability == .assistedInstaller)
                    ? L10n.text(
                        "已验证官网和版本，但此安装包类型仍需在官方页面完成更新。",
                        "The official source and version are verified, but this package type must still be updated on the official page."
                    )
                    : nil
            )
        case .upToDate:
            return ApplicationUpdateCheckResult(
                status: .upToDate,
                availableVersion: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                warning: nil
            )
        case let .latestVersionUnknown(warning):
            return ApplicationUpdateCheckResult(
                status: source.capability == .sourceConfirmation ? .sourceUnconfirmed : .latestVersionUnknown,
                availableVersion: nil,
                releaseDate: nil,
                releaseNotes: nil,
                downloadSize: nil,
                warning: warning
            )
        }
    }

    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        let outcome = try await releaseChecker.check(application)
        guard case let .updateAvailable(release) = outcome else {
            throw ApplicationScanningError.providerUnsupported("official-website-no-update")
        }
        let download = try downloadResolver.resolve(for: application, release: release)
        guard OfficialApplicationUpdateInstaller.supportsAutomaticInstallation(
            application: application,
            source: download.source
        ), OfficialApplicationUpdateInstaller.supportsAutomaticPackageType(download.packageType),
           download.permitsAutomaticInstallation else {
            throw OfficialApplicationUpdateInstallerError.unsupportedPackage
        }
        let prepared = PreparedApplicationUpdate(
            applicationID: application.id,
            providerIdentifier: identifier,
            originalIdentity: application.identity,
            originalVersion: application.installedVersion,
            targetVersion: release.version,
            providerPayload: [
                "downloadURL": download.remoteURL.absoluteString,
                "packageType": download.packageType.rawValue,
                "trustLevel": download.source.trustLevel.rawValue,
                "automaticInstallation": String(download.permitsAutomaticInstallation),
            ]
        )
        preparedLock.withLock {
            preparedContexts[application.id] = OfficialApplicationUpdateContext(
                application: application,
                source: download.source,
                download: download
            )
            preparedUpdates[application.id] = prepared
        }
        return prepared
    }

    func stage(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws {
        guard preparedUpdate.providerIdentifier == identifier,
              let context = preparedLock.withLock({ preparedContexts[preparedUpdate.applicationID] }),
              context.application.identity == preparedUpdate.originalIdentity,
              context.application.installedVersion == preparedUpdate.originalVersion,
              preparedUpdatesMatch(preparedUpdate, context: context) else {
            throw ApplicationScanningError.providerUnsupported("official-website-prepared-context-invalid")
        }
        let staged = try await installer.stage(
            context: context,
            targetVersion: preparedUpdate.targetVersion,
            progress: progress
        )
        preparedLock.withLock {
            stagedUpdates[preparedUpdate.applicationID] = staged
        }
    }

    func stagedPreparedUpdate(for applicationID: String) -> PreparedApplicationUpdate? {
        preparedLock.withLock { preparedUpdates[applicationID] }
    }

    func discardStagedUpdate(for applicationID: String) async {
        let staged = preparedLock.withLock {
            stagedUpdates.removeValue(forKey: applicationID)
        }
        if let staged {
            installer.cleanup(staged)
        }
        preparedLock.withLock {
            preparedContexts.removeValue(forKey: applicationID)
            preparedUpdates.removeValue(forKey: applicationID)
        }
    }

    func install(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        guard preparedUpdate.providerIdentifier == identifier,
              let context = preparedLock.withLock({ preparedContexts[preparedUpdate.applicationID] }),
              context.application.identity == preparedUpdate.originalIdentity,
              context.application.installedVersion == preparedUpdate.originalVersion,
              preparedUpdatesMatch(preparedUpdate, context: context) else {
            throw ApplicationScanningError.providerUnsupported("official-website-prepared-context-invalid")
        }
        let staged = preparedLock.withLock { stagedUpdates[preparedUpdate.applicationID] }
        defer {
            preparedLock.withLock {
                preparedContexts.removeValue(forKey: preparedUpdate.applicationID)
                preparedUpdates.removeValue(forKey: preparedUpdate.applicationID)
                stagedUpdates.removeValue(forKey: preparedUpdate.applicationID)
            }
        }
        if let staged {
            return try await installer.install(
                staged: staged,
                context: context,
                targetVersion: preparedUpdate.targetVersion,
                progress: progress
            )
        }
        return try await installer.install(
            context: context,
            targetVersion: preparedUpdate.targetVersion,
            progress: progress
        )
    }

    func cancelUpdate(for application: InstalledApplication) async {
        await discardStagedUpdate(for: application.id)
    }

    private func preparedUpdatesMatch(
        _ preparedUpdate: PreparedApplicationUpdate,
        context: OfficialApplicationUpdateContext
    ) -> Bool {
        preparedUpdate.providerPayload["downloadURL"] == context.download.remoteURL.absoluteString
            && preparedUpdate.providerPayload["packageType"] == context.download.packageType.rawValue
            && OfficialApplicationUpdateInstaller.supportsAutomaticPackageType(
                context.download.packageType
            )
            && preparedUpdate.providerPayload["automaticInstallation"] == "true"
    }
}
