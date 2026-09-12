import Foundation

enum OfficialProviderType: String, Codable, CaseIterable, Sendable {
    case system
    case appStore
    case homebrew
    case sparkle
    case vendorAPI
    case officialManifest
    case officialWebsite
    case officialGitHubRelease
    case applicationInternalUpdater
    case manual
    case unknown
}

enum SourceTrustLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case rejected
    case unverified
    case candidate
    case userConfirmed
    case providerVerified
    case registryVerified
    case verified

    private var rank: Int {
        switch self {
        case .rejected: 0
        case .unverified: 1
        case .candidate: 2
        case .userConfirmed: 3
        case .providerVerified: 4
        case .registryVerified: 5
        case .verified: 6
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    var permitsAutomaticDownload: Bool {
        self == .verified || self == .registryVerified || self == .providerVerified
    }
}

enum SourceVerificationMethod: String, Codable, CaseIterable, Sendable {
    case systemPath
    case appStoreReceipt
    case homebrewMetadata
    case sparkleConfiguration
    case signedRegistry
    case vendorManifest
    case userConfirmation
    case candidateSearch
    case none
}

enum WebsiteUpdateCapability: String, Codable, CaseIterable, Sendable {
    case automatic
    case assistedInstaller
    case manualWebsite
    case sourceConfirmation

    var permitsAutomaticInstallation: Bool {
        self == .automatic
    }
}

enum OfficialGitHubRepositoryPolicy {
    static let assetDownloadHosts: Set<String> = [
        "github.com",
        "release-assets.githubusercontent.com",
    ]

    static func isValid(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy(allowed.contains)
        }
    }
}

struct OfficialUpdateSource: Codable, Hashable, Sendable {
    let applicationIdentity: ApplicationIdentity
    let providerType: OfficialProviderType
    let developerName: String?
    let homepageURL: URL?
    let updatePageURL: URL?
    let releaseFeedURL: URL?
    let directDownloadURL: URL?
    let allowedHosts: Set<String>
    let expectedBundleIdentifier: String
    let expectedTeamIdentifier: String?
    let expectedDesignatedRequirement: String?
    let verificationMethod: SourceVerificationMethod
    let trustLevel: SourceTrustLevel
    let lastVerifiedAt: Date?
    let capability: WebsiteUpdateCapability
    let expectedPackageExtensions: Set<String>
    let officialGitHubRepository: String?

    var displayHost: String? {
        updatePageURL?.host
            ?? homepageURL?.host
            ?? releaseFeedURL?.host
            ?? directDownloadURL?.host
    }

    var canAutomaticallyDownload: Bool {
        trustLevel.permitsAutomaticDownload
            && capability != .sourceConfirmation
            && (directDownloadURL != nil || usesDynamicGitHubReleaseAsset)
    }

    var canAutomaticallyInstall: Bool {
        canAutomaticallyDownload && capability.permitsAutomaticInstallation
    }

    var usesDynamicGitHubReleaseAsset: Bool {
        guard providerType == .officialGitHubRelease,
              directDownloadURL == nil,
              expectedPackageExtensions == [OfficialPackageType.diskImage.rawValue],
              let repository = officialGitHubRepository?.trimmed.nonEmpty,
              OfficialGitHubRepositoryPolicy.isValid(repository) else {
            return false
        }
        let normalizedHosts = Set(allowedHosts.compactMap {
            try? AllowedHostValidator.normalizedHost($0)
        })
        return OfficialGitHubRepositoryPolicy.assetDownloadHosts.isSubset(of: normalizedHosts)
    }
}

struct OfficialSourceRegistryEntry: Codable, Hashable, Sendable {
    let bundleIdentifier: String
    let signingTeamIdentifier: String?
    let codeSigningIdentifier: String?
    let developerName: String
    let homepageURL: URL
    let updatePageURL: URL?
    let releaseFeedURL: URL?
    let directDownloadURL: URL?
    let allowedHosts: Set<String>
    let expectedDesignatedRequirement: String?
    let providerType: OfficialProviderType
    let capability: WebsiteUpdateCapability
    let expectedPackageExtensions: Set<String>
    let officialGitHubRepository: String?
    let lastVerifiedAt: Date

    func matches(_ application: InstalledApplication) -> Bool {
        guard bundleIdentifier == application.bundleIdentifier,
              application.sourceEvidence.contains("valid-code-signature") else { return false }
        if let expectedTeam = signingTeamIdentifier?.trimmed.nonEmpty {
            guard application.signingTeamIdentifier == expectedTeam else { return false }
        }
        if let expectedSigningIdentifier = codeSigningIdentifier?.trimmed.nonEmpty {
            guard application.codeSigningIdentifier == expectedSigningIdentifier else { return false }
        }
        return signingTeamIdentifier?.trimmed.nonEmpty != nil
            || codeSigningIdentifier?.trimmed.nonEmpty != nil
            || expectedDesignatedRequirement?.trimmed.nonEmpty != nil
    }

    func source(for application: InstalledApplication) -> OfficialUpdateSource {
        OfficialUpdateSource(
            applicationIdentity: application.identity,
            providerType: providerType,
            developerName: developerName,
            homepageURL: homepageURL,
            updatePageURL: updatePageURL,
            releaseFeedURL: releaseFeedURL,
            directDownloadURL: directDownloadURL,
            allowedHosts: allowedHosts,
            expectedBundleIdentifier: bundleIdentifier,
            expectedTeamIdentifier: signingTeamIdentifier,
            expectedDesignatedRequirement: expectedDesignatedRequirement,
            verificationMethod: .signedRegistry,
            trustLevel: .registryVerified,
            lastVerifiedAt: lastVerifiedAt,
            capability: capability,
            expectedPackageExtensions: expectedPackageExtensions,
            officialGitHubRepository: officialGitHubRepository
        )
    }
}

struct OfficialSourceRegistryPayload: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let sequence: Int
    let issuedAt: Date
    let expiresAt: Date
    let keyID: String
    let entries: [OfficialSourceRegistryEntry]
}

struct SignedOfficialSourceRegistry: Codable, Hashable, Sendable {
    let payload: Data
    let signature: Data
    let keyID: String
}

struct OfficialSourceRegistrySnapshot: Codable, Hashable, Sendable {
    let payload: OfficialSourceRegistryPayload
    let verifiedAt: Date
    let isExpired: Bool
}
