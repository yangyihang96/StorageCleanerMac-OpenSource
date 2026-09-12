import Foundation
@testable import StorageCleanerMac

enum AppUpdateTestFixtures {
    static let scanDate = Date(timeIntervalSince1970: 1_789_000_000)

    static func application(
        id: String = UUID().uuidString,
        name: String = "Example",
        bundleIdentifier: String = "com.example.app",
        path: String = "/Applications/Example.app",
        version: String = "1.0",
        build: String = "100",
        availableVersion: String? = nil,
        signingTeamIdentifier: String? = "TEAM123",
        codeSigningIdentifier: String? = nil,
        installationSource: ApplicationInstallationSource = .standardDirectory,
        provider: ApplicationUpdateProviderIdentifier = .manual,
        status: ApplicationUpdateStatus = .latestVersionUnknown,
        sourceEvidence: [String] = [],
        officialSource: OfficialUpdateSource? = nil,
        homebrewMetadata: HomebrewPackageMetadata? = nil,
        isSystem: Bool = false,
        isRunning: Bool = false,
        isReadOnly: Bool = false,
        canAutomaticallyUpdate: Bool = false,
        requiresUserInteraction: Bool = true,
        requiresApplicationQuit: Bool = false,
        requiresAdministratorAuthorization: Bool = false,
        lastScanDate: Date = scanDate
    ) -> InstalledApplication {
        InstalledApplication(
            id: id,
            displayName: name,
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            executableURL: URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("Contents/MacOS/Example"),
            installedVersion: ApplicationVersion(marketing: version, build: build),
            buildNumber: build,
            signingTeamIdentifier: signingTeamIdentifier,
            codeSigningIdentifier: codeSigningIdentifier ?? bundleIdentifier,
            installationSource: installationSource,
            updateProvider: provider,
            architectures: ["arm64"],
            minimumSystemVersion: "14.0",
            isSystemApplication: isSystem,
            isRunning: isRunning,
            isOnExternalVolume: false,
            isReadOnly: isReadOnly,
            lastScanDate: lastScanDate,
            availableVersion: availableVersion.map { ApplicationVersion(marketing: $0) },
            updateStatus: status,
            requiresUserInteraction: requiresUserInteraction,
            requiresApplicationQuit: requiresApplicationQuit,
            requiresAdministratorAuthorization: requiresAdministratorAuthorization,
            canAutomaticallyUpdate: canAutomaticallyUpdate,
            sourceDisplayName: provider.rawValue,
            sourceEvidence: sourceEvidence,
            officialSource: officialSource,
            homebrewMetadata: homebrewMetadata,
            feedURL: provider == .sparkle ? "https://updates.example.com/appcast.xml" : nil,
            caskToken: homebrewMetadata?.kind == .cask ? homebrewMetadata?.token : nil,
            modifiedAt: lastScanDate
        )
    }

    static func homebrewMetadata(
        token: String = "example",
        kind: HomebrewPackageKind = .cask,
        installedVersions: [String] = ["1.0"],
        currentVersion: String? = "2.0",
        isOutdated: Bool = true,
        outdatedProvenance: HomebrewOutdatedProvenance = .plain,
        isPinned: Bool = false,
        isDisabled: Bool = false,
        isDeprecated: Bool = false,
        autoUpdates: Bool = false,
        requiresManualInstaller: Bool = false,
        appBundlePaths: [String] = ["/Applications/Example.app"]
    ) -> HomebrewPackageMetadata {
        HomebrewPackageMetadata(
            token: token,
            kind: kind,
            homepageURL: URL(string: "https://example.com"),
            installedVersions: installedVersions,
            currentVersion: currentVersion,
            isOutdated: isOutdated,
            outdatedProvenance: outdatedProvenance,
            isPinned: isPinned,
            isDisabled: isDisabled,
            isDeprecated: isDeprecated,
            autoUpdates: autoUpdates,
            requiresManualInstaller: requiresManualInstaller,
            appBundlePaths: appBundlePaths
        )
    }

    static func strictHomebrewApplication(
        id: String = UUID().uuidString,
        token: String = "example",
        path: String = "/Applications/Example.app",
        isRunning: Bool = false,
        requiresAuthorization: Bool = false
    ) -> InstalledApplication {
        application(
            id: id,
            name: token,
            bundleIdentifier: "com.example.\(token)",
            path: path,
            availableVersion: "2.0",
            installationSource: .homebrewCask,
            provider: .homebrew,
            status: .automaticallyUpdatable,
            sourceEvidence: [
                "homebrew-cli-json-v2",
                "homebrew-match:exact-artifact-path",
                "valid-code-signature",
            ],
            homebrewMetadata: homebrewMetadata(
                token: token,
                appBundlePaths: [path]
            ),
            isRunning: isRunning,
            canAutomaticallyUpdate: true,
            requiresUserInteraction: false,
            requiresApplicationQuit: isRunning,
            requiresAdministratorAuthorization: requiresAuthorization
        )
    }
}
