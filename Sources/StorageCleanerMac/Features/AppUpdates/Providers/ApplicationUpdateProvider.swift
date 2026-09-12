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
            OfficialWebsiteUpdateProvider(),
            // Vendor updaters (Keystone, Squirrel) rank below every source
            // this app can verify itself, but above the unconfirmed fallback:
            // an app that maintains itself deserves an in-app guidance path,
            // not the "source unconfirmed" dead end.
            VendorUpdaterProvider(),
            ManualUpdateProvider(),
        ]
    }

    func provider(for application: InstalledApplication) async -> any ApplicationUpdateProvider {
        if SystemApplicationPolicy.isSystemManaged(application) {
            return SystemManagedProvider()
        }
        for provider in providers where await provider.canHandle(application) {
            // A signed/registry-verified installer is stronger evidence than a
            // generic Sparkle declaration.  Sparkle only proves that the app
            // exposes an in-app updater; if the same bundle is also bound to a
            // verified external DMG, prefer the provider that can complete the
            // identity/signature/version verification in this process.
            if provider.identifier == .sparkle,
               let officialProvider = providers.first(where: {
                   $0.identifier == .officialWebsite
               }),
               await officialProvider.canHandle(application),
               let officialSource = try? await officialProvider.inspect(application),
               officialSource.providerIdentifier == .officialWebsite,
               officialSource.canAutomaticallyUpdate {
                return officialProvider
            }
            guard provider.identifier == .homebrew,
                  let metadata = application.homebrewMetadata,
                  let homebrewSource = try? await provider.inspect(application),
                  let officialProvider = providers.first(where: {
                      $0.identifier == .officialWebsite
                  }),
                  await officialProvider.canHandle(application),
                  let officialSource = try? await officialProvider.inspect(application),
                  officialSource.providerIdentifier == .officialWebsite,
                  officialSource.canAutomaticallyUpdate else {
                return provider
            }
            // Homebrew's `auto_updates` flag means the cask normally owns its
            // updater. If a separately verified official DMG is available,
            // prefer that stronger identity-bound path (CC Switch/draw.io).
            // Ordinary strict Homebrew casks keep their existing priority.
            guard metadata.autoUpdates || !homebrewSource.canAutomaticallyUpdate else {
                return provider
            }
            // A Homebrew cask that delegates updates upstream must not hide a
            // separately verified official DMG capable of the full safe path.
            return officialProvider
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
            if provider.identifier == .macAppStore {
                let isAutomatic = sourceInfo.canAutomaticallyUpdate
                    && check.status == .automaticallyUpdatable
                classified.updateCapability = isAutomatic ? .automatic : .appStoreManaged
                classified.canAutomaticallyUpdate = isAutomatic
                classified.requiresUserInteraction = !isAutomatic
                applySourcePresentation(to: &classified)
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
        case .sparkle: return .inApplication
        case .officialWebsite:
            return sourceInfo.canAutomaticallyUpdate ? .automatic : .websiteGuided
        case .vendorUpdater: return .inApplication
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
            application.canAutomaticallyUpdate = false
            application.updateCapability = .inApplication
        case .vendorUpdater:
            application.installationSource = .vendor
            application.sourceDisplayName = L10n.text("厂商更新器", "Vendor Updater")
            application.canAutomaticallyUpdate = false
            application.updateCapability = .inApplication
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
