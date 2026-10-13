import Foundation

protocol ApplicationUpdateProvider: Sendable {
    var identifier: ApplicationUpdateProviderIdentifier { get }

    func canHandle(_ application: InstalledApplication) async -> Bool
    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo
    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult
    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate
    func install(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult
    func cancelUpdate(for application: InstalledApplication) async
}

protocol ApplicationUpdateStagingProvider: ApplicationUpdateProvider {
    func stage(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws

    func stagedPreparedUpdate(for applicationID: String) -> PreparedApplicationUpdate?
    func discardStagedUpdate(for applicationID: String) async
}

extension ApplicationUpdateProvider {
    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
    }

    func install(
        _ preparedUpdate: PreparedApplicationUpdate,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void
    ) async throws -> ApplicationUpdateInstallResult {
        throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
    }

    func cancelUpdate(for application: InstalledApplication) async {}
}

struct ApplicationUpdateProviderRegistry: Sendable {
    private let providers: [any ApplicationUpdateProvider]

    init(providers: [any ApplicationUpdateProvider]? = nil) {
        self.providers = providers ?? [
            SystemManagedProvider(),
            MacAppStoreProvider(),
            HomebrewProvider(),
            SparkleProvider(),
            VendorUpdaterProvider(),
            OfficialWebsiteUpdateProvider(),
            ManualUpdateProvider(),
        ]
    }

    func provider(for application: InstalledApplication) async -> any ApplicationUpdateProvider {
        if SystemApplicationPolicy.isSystemManaged(application) {
            return SystemManagedProvider()
        }
        for provider in providers where await provider.canHandle(application) {
            // Prefer a verified installer only when Sparkle cannot execute.
            if provider.identifier == .sparkle,
               (try? await provider.inspect(application))?.canAutomaticallyUpdate != true,
               let official = providers.first(where: { $0.identifier == .officialWebsite }),
               await official.canHandle(application), (try? await official.inspect(application))?.canAutomaticallyUpdate == true { return official }
            // Homebrew owns all its packages, including self-updating casks.
            return provider
        }
        return ManualUpdateProvider()
    }

    func classify(_ application: InstalledApplication) async -> InstalledApplication {
        var classified = application
        let provider = await provider(for: application)
        classified.primaryUpdateProvider = provider.identifier
        classified.sourceResolutionState = .resolving
        classified.versionCheckState = .notChecked
        classified.updateCapability = .unavailable

        let sourceInfo: ApplicationUpdateSourceInfo
        do {
            sourceInfo = try await provider.inspect(application)
            guard sourceInfo.providerIdentifier == provider.identifier else {
                throw ApplicationScanningError.providerUnsupported(
                    "provider-identity-mismatch:\(provider.identifier.rawValue)"
                )
            }
            classified.sourceResolutionState = sourceResolutionState(
                for: provider.identifier,
                application: classified
            )
            classified.sourceEvidence = Array(
                Set(classified.sourceEvidence + sourceInfo.evidence)
            ).sorted()
            classified.requiresUserInteraction = sourceInfo.requiresUserInteraction
            classified.updateCapability = capability(
                for: provider.identifier,
                application: classified,
                sourceInfo: sourceInfo
            )
            classified.canAutomaticallyUpdate = classified.updateCapability == .automatic
            applySourcePresentation(to: &classified)
        } catch is CancellationError {
            classified.sourceResolutionState = .unresolved
            classified.updateStatus = .cancelled
            classified.updateError = nil
            return classified
        } catch {
            classified.sourceResolutionState = .failed
            classified.versionCheckState = .notChecked
            classified.updateStatus = .failed
            classified.updateError = error.localizedDescription
            classified.canAutomaticallyUpdate = false
            classified.requiresUserInteraction = true
            applySourcePresentation(to: &classified)
            return classified
        }

        classified.versionCheckState = .checking
        do {
            let check = try await provider.checkForUpdate(classified)
            classified.availableVersion = check.availableVersion
            classified.releaseDate = check.releaseDate
            classified.releaseNotes = check.releaseNotes
            classified.downloadSize = check.downloadSize
            classified.appStoreProductURL = check.appStoreProductURL
            classified.updateStatus = check.status
            classified.updateError = check.warning
            classified.versionCheckState = versionCheckState(for: check)
            if provider.identifier == .vendorUpdater, sourceInfo.canAutomaticallyUpdate,
               check.status == .automaticallyUpdatable, classified.sourceEvidence.contains("vendor-official-cli") {
                // A vendor CLI can check and install without publishing a target
                // version. Do not fabricate one; completion still needs readback.
                classified.versionCheckState = .updateAvailable
            }
            if provider.identifier == .macAppStore {
                let isAutomatic = sourceInfo.canAutomaticallyUpdate
                    && check.status == .automaticallyUpdatable
                classified.updateCapability = isAutomatic ? .automatic : .appStoreManaged
                classified.canAutomaticallyUpdate = isAutomatic
                classified.requiresUserInteraction = !isAutomatic
                applySourcePresentation(to: &classified)
            }
            if classified.canAutomaticallyUpdate {
                classified.requiresApplicationQuit = classified.isRunning && classified.packageKind == .graphicalApplication
                classified.requiresAdministratorAuthorization = classified.homebrewMetadata?.needsAdministrator == true
                    || provider.identifier == .macAppStore
                    || (classified.packageKind == .graphicalApplication && [.sparkle, .officialWebsite].contains(provider.identifier)
                        && !FileManager.default.isWritableFile(atPath: classified.bundleURL.deletingLastPathComponent().path))
            }
            if classified.canAutomaticallyUpdate, classified.requiresAdministratorAuthorization,
               [.sparkle, .officialWebsite].contains(provider.identifier),
               !AppUpdateProtectedReplacementPolicy.accepts(classified) {
                classified.canAutomaticallyUpdate = false
                classified.updateCapability = .inApplication
                classified.updateError = L10n.text("辅助程序仅支持 /Applications 顶层应用，请打开应用内更新", "The helper supports only top-level /Applications apps; open in-app updates")
            }
            if [.sparkle, .vendorUpdater].contains(provider.identifier), check.status != .automaticallyUpdatable {
                classified.canAutomaticallyUpdate = false
                classified.updateCapability = .inApplication
                classified.requiresUserInteraction = true
            }
        } catch is CancellationError {
            classified.versionCheckState = .notChecked
            classified.updateStatus = .cancelled
            classified.updateError = nil
        } catch {
            // Remote version failure does not invalidate a verified source.
            classified.versionCheckState = .failed
            classified.updateStatus = .failed
            classified.updateError = error.localizedDescription
            if [.sparkle, .vendorUpdater].contains(provider.identifier) {
                classified.canAutomaticallyUpdate = false
                classified.updateCapability = .inApplication
                classified.requiresUserInteraction = true
            }
        }
        return classified
    }

    private func capability(
        for provider: ApplicationUpdateProviderIdentifier,
        application: InstalledApplication,
        sourceInfo: ApplicationUpdateSourceInfo
    ) -> UpdateCapability {
        switch provider {
        case .systemManaged: return .systemManaged
        case .macAppStore:
            return sourceInfo.canAutomaticallyUpdate ? .automatic : .appStoreManaged
        case .homebrew: return sourceInfo.canAutomaticallyUpdate ? .automatic : .manual
        case .sparkle: return sourceInfo.canAutomaticallyUpdate ? .automatic : .inApplication
        case .officialWebsite:
            return sourceInfo.canAutomaticallyUpdate ? .automatic : .websiteGuided
        case .vendorUpdater: return sourceInfo.canAutomaticallyUpdate ? .automatic : .inApplication
        case .manual: return application.officialSource == nil ? .unavailable : .websiteGuided
        }
    }

    private func sourceResolutionState(
        for provider: ApplicationUpdateProviderIdentifier,
        application: InstalledApplication
    ) -> SourceResolutionState {
        guard provider == .officialWebsite else {
            return provider == .manual ? .needsConfirmation : .resolved
        }
        switch application.officialSource?.trustLevel {
        case .verified, .registryVerified, .providerVerified, .userConfirmed:
            return .resolved
        case .candidate, .unverified, .none:
            return .needsConfirmation
        case .rejected:
            return .failed
        }
    }

    private func versionCheckState(
        for check: ApplicationUpdateCheckResult
    ) -> VersionCheckState {
        switch check.status {
        case .upToDate, .completed:
            .upToDate
        case .updateAvailable, .automaticallyUpdatable, .officialInstallerAvailable,
             .websiteUpdateRequired, .applicationUpdateRequired, .queued,
             .downloading, .waitingForQuit, .waitingForAuthorization, .installing,
             .verifying:
            check.availableVersion == nil ? .unavailable : .updateAvailable
        case .latestVersionUnknown, .sourceUnconfirmed, .appStoreManaged, .systemManaged,
             .skipped, .ignored:
            .unavailable
        case .failed:
            .failed
        case .discovered, .identifyingSource, .checking, .cancelled:
            .notChecked
        }
    }

    private func applySourcePresentation(to application: inout InstalledApplication) {
        switch application.updateProvider {
        case .systemManaged:
            application.installationSource = .system
            application.sourceDisplayName = "macOS"
            application.isSystemApplication = true
            application.requiresUserInteraction = false
            application.requiresApplicationQuit = false
            application.canAutomaticallyUpdate = false
            application.updateCapability = .systemManaged
        case .macAppStore:
            application.installationSource = .appStore
            application.sourceDisplayName = "App Store"
        case .homebrew:
            application.installationSource = application.homebrewMetadata?.kind == .formula
                ? .homebrewFormula
                : .homebrewCask
            application.sourceDisplayName = "Homebrew"
            application.caskToken = application.homebrewMetadata?.kind == .cask
                ? application.homebrewMetadata?.token
                : nil
            application.requiresApplicationQuit = application.isRunning
                && application.packageKind == .graphicalApplication
        case .sparkle:
            application.installationSource = .sparkle
            application.sourceDisplayName = "Sparkle"

        case .vendorUpdater:
            application.installationSource = .vendor
            application.sourceDisplayName = L10n.text("厂商更新器", "Vendor Updater")

        case .officialWebsite:
            application.installationSource = .officialWebsite
            application.sourceDisplayName = application.officialSource?.displayHost
                ?? L10n.text("官方网站", "Official Website")
            application.updateCapability = application.canAutomaticallyUpdate
                ? .automatic
                : .websiteGuided
        case .manual:
            if application.installationSource == .unknown {
                application.sourceDisplayName = L10n.text("来源待确认", "Source Unconfirmed")
            }
            application.canAutomaticallyUpdate = false
        }
    }
}
