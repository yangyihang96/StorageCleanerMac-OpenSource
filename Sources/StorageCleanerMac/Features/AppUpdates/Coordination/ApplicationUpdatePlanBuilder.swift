import Foundation

enum ApplicationUpdatePlanDisposition: Hashable, Sendable {
    case automatic
    case requiresQuit
    case requiresAuthorization
    case appStore
    case website
    case manual
    case skipped
}

struct ApplicationUpdatePlanBuilder: Sendable {
    func build(
        applications: [InstalledApplication],
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> ApplicationUpdatePlan {
        build(from: applications, id: id, createdAt: createdAt)
    }

    func build(
        from applications: [InstalledApplication],
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> ApplicationUpdatePlan {
        var automatic: [String] = []
        var requiresQuit: [String] = []
        var requiresAuthorization: [String] = []
        var appStore: [String] = []
        var website: [String] = []
        var manual: [String] = []
        var skipped: [String] = []
        var seen: Set<String> = []

        for application in applications where seen.insert(application.id).inserted {
            switch Self.destination(for: application) {
            case .automatic:
                automatic.append(application.id)
            case .requiresQuit:
                requiresQuit.append(application.id)
            case .requiresAuthorization:
                requiresAuthorization.append(application.id)
            case .appStore:
                appStore.append(application.id)
            case .website:
                website.append(application.id)
            case .manual:
                manual.append(application.id)
            case .skipped:
                skipped.append(application.id)
            }
        }

        return ApplicationUpdatePlan(
            id: id,
            createdAt: createdAt,
            automaticApplicationIDs: automatic,
            requiresQuitApplicationIDs: requiresQuit,
            requiresAuthorizationApplicationIDs: requiresAuthorization,
            appStoreApplicationIDs: appStore,
            websiteApplicationIDs: website,
            manualApplicationIDs: manual,
            skippedApplicationIDs: skipped
        )
    }

    static func isEligibleForAutomaticUpdate(_ application: InstalledApplication) -> Bool {
        isEligibleForAutomaticUpdate(
            application,
            hostBundleIdentifier: Bundle.main.bundleIdentifier,
            hostBundleURL: Bundle.main.bundleURL
        )
    }

    static func isEligibleForAutomaticUpdate(
        _ application: InstalledApplication,
        hostBundleIdentifier: String?,
        hostBundleURL: URL
    ) -> Bool {
        let hostIdentifier = hostBundleIdentifier?.trimmed ?? ""
        guard hasConfirmedUpdateEvidence(application),
              (hostIdentifier.isEmpty || application.bundleIdentifier != hostIdentifier),
              ApplicationPathNormalizer.comparisonKey(for: application.bundleURL)
                != ApplicationPathNormalizer.comparisonKey(for: hostBundleURL),
              !application.isDuplicate,
              !application.requiresUserInteraction,
              !application.requiresApplicationQuit,
              !application.requiresAdministratorAuthorization,
              !application.isRunning
        else {
            return false
        }
        return isPreciseHomebrewCandidate(application)
            || isPreciseOfficialWebsiteCandidate(application)
    }

    private static func isEligibleForAutomaticUpdateAfterNormalQuit(
        _ application: InstalledApplication
    ) -> Bool {
        var stoppedApplication = application
        stoppedApplication.isRunning = false
        stoppedApplication.requiresApplicationQuit = false
        return isEligibleForAutomaticUpdate(stoppedApplication)
    }

    static func destination(
        for application: InstalledApplication
    ) -> ApplicationUpdatePlanDisposition {
        if SystemApplicationPolicy.isSystemManaged(application)
            || application.updateProvider == .systemManaged
            || application.updateCapability == .systemManaged {
            return .skipped
        }
        guard hasConfirmedUpdateEvidence(application) else {
            return .skipped
        }

        switch application.updateProvider {
        case .systemManaged:
            return .skipped
        case .macAppStore:
            return .appStore
        case .officialWebsite:
            guard hasActionableUpdate(application) else { return .skipped }
            guard isPreciseOfficialWebsiteCandidate(application) else { return .website }
            if application.requiresAdministratorAuthorization { return .requiresAuthorization }
            if application.requiresApplicationQuit || application.isRunning {
                return isEligibleForAutomaticUpdateAfterNormalQuit(application)
                    ? .requiresQuit
                    : .website
            }
            return isEligibleForAutomaticUpdate(application) ? .automatic : .website
        case .manual:
            return application.officialSource == nil ? .manual : .website
        case .sparkle, .vendorUpdater:
            // External Sparkle and vendor adapters are intentionally excluded until
            // their executor can prove identity, signature and on-disk version change.
            return .manual
        case .homebrew:
            guard hasActionableUpdate(application) else { return .skipped }
            guard isPreciseHomebrewCandidate(application) else { return .manual }
            if application.requiresUserInteraction { return .manual }
            if application.requiresAdministratorAuthorization {
                return .requiresAuthorization
            }
            if application.requiresApplicationQuit || application.isRunning {
                return isEligibleForAutomaticUpdateAfterNormalQuit(application)
                    ? .requiresQuit
                    : .manual
            }
            if isEligibleForAutomaticUpdate(application) {
                return .automatic
            }
            return .manual
        }
    }

    private static func hasActionableUpdate(_ application: InstalledApplication) -> Bool {
        switch application.updateStatus {
        case .updateAvailable, .automaticallyUpdatable, .officialInstallerAvailable,
             .websiteUpdateRequired, .applicationUpdateRequired, .queued, .failed:
            return true
        case .discovered, .identifyingSource, .checking, .upToDate,
             .appStoreManaged, .systemManaged, .sourceUnconfirmed,
             .latestVersionUnknown, .downloading, .waitingForQuit,
             .waitingForAuthorization, .installing, .verifying, .completed,
             .skipped, .cancelled, .ignored:
            return false
        }
    }

    private static func hasConfirmedUpdateEvidence(_ application: InstalledApplication) -> Bool {
        application.effectiveSourceResolutionState == .resolved
            && application.effectiveVersionCheckState == .updateAvailable
            && application.availableVersion.map { application.installedVersion < $0 } == true
    }

    private static func isPreciseHomebrewCandidate(_ application: InstalledApplication) -> Bool {
        guard application.updateProvider == .homebrew,
              application.updateCapability == .automatic,
              application.canAutomaticallyUpdate,
              !application.isReadOnly,
              let metadata = application.homebrewMetadata,
              HomebrewPackageTokenPolicy.isValid(metadata.token),
              metadata.hasPlainOutdatedEvidence,
              !metadata.isPinned,
              !metadata.isDisabled,
              !metadata.isDeprecated,
              !metadata.requiresManualInstaller,
              let targetVersion = HomebrewAutomaticUpdateSafety.strictlyNewerCurrentVersion(
                  metadata: metadata,
                  installedVersion: application.installedVersion
              ),
              application.availableVersion == targetVersion
        else {
            return false
        }

        if metadata.kind == .cask, let token = application.caskToken {
            guard HomebrewPackageTokenPolicy.isValid(token), token == metadata.token else {
                return false
            }
        }

        if metadata.kind == .cask {
            guard HomebrewAutomaticUpdateSafety.hasExactCaskArtifactPath(
                application: application,
                metadata: metadata
            ), HomebrewAutomaticUpdateSafety.hasVerifiedCaskSigningIdentity(application) else {
                return false
            }
        }

        switch application.updateStatus {
        case .updateAvailable, .automaticallyUpdatable, .queued, .failed:
            return true
        case .discovered, .identifyingSource, .checking, .upToDate,
             .officialInstallerAvailable, .websiteUpdateRequired,
             .applicationUpdateRequired, .appStoreManaged, .systemManaged,
             .sourceUnconfirmed, .latestVersionUnknown, .downloading,
             .waitingForQuit, .waitingForAuthorization, .installing,
             .verifying, .completed, .skipped, .cancelled, .ignored:
            return false
        }
    }

    private static func isPreciseOfficialWebsiteCandidate(
        _ application: InstalledApplication
    ) -> Bool {
        guard application.updateProvider == .officialWebsite,
              application.updateCapability == .automatic,
              application.canAutomaticallyUpdate,
              !application.isReadOnly,
              let source = application.officialSource,
              OfficialApplicationUpdateInstaller.supportsAutomaticInstallation(
                application: application,
                source: source
              ),
              let availableVersion = application.availableVersion,
              isStrictlyNewer(availableVersion, than: application.installedVersion)
        else {
            return false
        }
        switch application.updateStatus {
        case .updateAvailable, .automaticallyUpdatable, .queued, .failed:
            return true
        case .discovered, .identifyingSource, .checking, .upToDate,
             .officialInstallerAvailable, .websiteUpdateRequired,
             .applicationUpdateRequired, .appStoreManaged, .systemManaged,
             .sourceUnconfirmed, .latestVersionUnknown, .downloading,
             .waitingForQuit, .waitingForAuthorization, .installing,
             .verifying, .completed, .skipped, .cancelled, .ignored:
            return false
        }
    }

    private static func isStrictlyNewer(
        _ candidate: ApplicationVersion,
        than installed: ApplicationVersion
    ) -> Bool {
        let marketingOrder = ApplicationVersion.compare(candidate.marketing, installed.marketing)
        if marketingOrder == .orderedDescending { return true }
        if marketingOrder == .orderedAscending { return false }
        return ApplicationVersion.compare(candidate.build, installed.build) == .orderedDescending
    }
}
