import Foundation

/// Resolves presentation and trust metadata for an already-discovered app.
/// Provider selection remains authoritative for how an update is executed.
struct OfficialUpdateSourceResolver: Sendable {
    private let registry: OfficialSourceRegistry
    private let remoteRefresher: RemoteOfficialSourceRegistryRefresher

    init(
        registry: OfficialSourceRegistry = OfficialSourceRegistry(),
        remoteRefresher: RemoteOfficialSourceRegistryRefresher = RemoteOfficialSourceRegistryRefresher()
    ) {
        self.registry = registry
        self.remoteRefresher = remoteRefresher
    }

    func refreshSources() async -> String? {
        await registry.reloadUserConfirmations()
        return await remoteRefresher.refresh(registry: registry)
    }

    func resolve(_ application: InstalledApplication) async -> OfficialUpdateSource? {
        if let registered = await registry.source(for: application) {
            return registered
        }
        if let homebrew = homebrewSource(for: application) {
            return homebrew
        }
        if let sparkle = sparkleSource(for: application) {
            return sparkle
        }
        return nil
    }

    private func homebrewSource(for application: InstalledApplication) -> OfficialUpdateSource? {
        guard let metadata = application.homebrewMetadata,
              let homepage = metadata.homepageURL,
              homepage.scheme?.lowercased() == "https",
              let host = homepage.host?.lowercased(),
              (try? AllowedHostValidator().validate(homepage, allowedHosts: [host])) != nil
        else {
            return nil
        }

        return OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .homebrew,
            developerName: nil,
            homepageURL: homepage,
            updatePageURL: homepage,
            releaseFeedURL: nil,
            directDownloadURL: nil,
            allowedHosts: [host],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .homebrewMetadata,
            trustLevel: .providerVerified,
            lastVerifiedAt: application.lastScanDate,
            capability: .manualWebsite,
            expectedPackageExtensions: [],
            officialGitHubRepository: nil
        )
    }

    private func sparkleSource(for application: InstalledApplication) -> OfficialUpdateSource? {
        guard let rawFeed = application.feedURL?.trimmed.nonEmpty,
              let feedURL = URL(string: rawFeed),
              feedURL.scheme?.lowercased() == "https",
              let host = feedURL.host?.lowercased(),
              (try? AllowedHostValidator().validate(feedURL, allowedHosts: [host])) != nil
        else {
            return nil
        }

        return OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: .sparkle,
            developerName: nil,
            homepageURL: nil,
            updatePageURL: nil,
            releaseFeedURL: feedURL,
            directDownloadURL: nil,
            allowedHosts: [host],
            expectedBundleIdentifier: application.bundleIdentifier,
            expectedTeamIdentifier: application.signingTeamIdentifier,
            expectedDesignatedRequirement: nil,
            verificationMethod: .sparkleConfiguration,
            // An HTTPS SUFeedURL proves only that the app declares an updater.
            // It does not prove the appcast or its enclosure signature.
            trustLevel: .unverified,
            lastVerifiedAt: application.lastScanDate,
            capability: .manualWebsite,
            expectedPackageExtensions: [],
            officialGitHubRepository: nil
        )
    }
}
