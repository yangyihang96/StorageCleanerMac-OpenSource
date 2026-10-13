#if DEBUG
import Foundation

/// Value-only additions to the D67 capture factory. Paths are lexical fixture
/// addresses; callbacks in the capture factory are inert and hit testing is off.
enum FeatureLightfieldApplicationsFixture {
    static let referenceArgument = "--debug-feature-applications-reference"
    static let stressArgument = "--debug-feature-applications-stress"

    static let uninstallApps: [InstalledAppItem] = [
        ("Xcode 27 Beta", "27.0 Beta", "/Applications/Lightfield Xcode Fixture.app", Int64(21_400_000_000)),
        ("Google Chrome", "140.0.7339.82", "/Applications/Lightfield Chrome Fixture.app", 7_900_000_000),
        ("ChatGPT", "1.2026.260", "/Applications/Lightfield ChatGPT Fixture.app", 5_600_000_000),
        ("Zoom", "6.5.2", "/Applications/Lightfield Zoom Fixture.app", 4_800_000_000),
        ("Obsidian", "1.9.12", "/Applications/Lightfield Fixture/设计与开发工具/代码与文档协作/Obsidian.app", 1_100_000_000)
    ].enumerated().map { index, row in
        InstalledAppItem(id: "lightfield-reference-\(index)", name: row.0,
            bundleIdentifier: "invalid.example.lightfield.reference.\(index)", path: row.2,
            version: row.1, build: row.1, category: "", appDescription: "", sizeBytes: row.3,
            source: "fixture", modifiedAt: nil, relatedPaths: [], relatedItems: [], status: .installed)
    }

    static let updateApplications: [InstalledApplication] = {
        var apps = DebugAppUpdatePresentationFixture.applications
        for index in 0..<4 {
            let current = apps[index].installedVersion.preferred
            apps[index].updateProvider = .homebrew
            apps[index].installationSource = .homebrewCask
            apps[index].updateStatus = .automaticallyUpdatable
            apps[index].updateCapability = .automatic
            apps[index].sourceResolutionState = .resolved
            apps[index].versionCheckState = .updateAvailable
            apps[index].canAutomaticallyUpdate = true
            apps[index].requiresUserInteraction = false
            apps[index].signingTeamIdentifier = "DEBUGTEAM1"
            apps[index].codeSigningIdentifier = apps[index].bundleIdentifier
            apps[index].sourceEvidence = ["homebrew-match:exact-artifact-path", "valid-code-signature", "homebrew-cli-json-v2"]
            apps[index].caskToken = apps[index].id
            apps[index].homebrewMetadata = HomebrewPackageMetadata(token: apps[index].id, kind: .cask,
                homepageURL: nil, installedVersions: [current], currentVersion: apps[index].availableVersion?.preferred,
                isOutdated: true, outdatedProvenance: .plain, isPinned: false, isDisabled: false,
                isDeprecated: false, autoUpdates: false, requiresManualInstaller: false,
                appBundlePaths: [apps[index].path])
        }
        apps[2].isRunning = true
        apps[2].requiresApplicationQuit = true
        apps[3].requiresAdministratorAuthorization = true
        apps[4].updateProvider = .sparkle
        apps[4].installationSource = .sparkle
        apps[4].updateCapability = .inApplication
        apps[4].updateStatus = .applicationUpdateRequired
        apps[4].sourceEvidence = ["sparkle-framework", "sparkle-feed"]
        return apps
    }()

    static func updateSummary(stress: Bool = false) -> AppScanSummary {
        var apps = updateApplications
        if stress {
            for index in apps.indices {
                apps[index].displayName = String(repeating: "很长的应用名称", count: 12) + " \(index)"
                apps[index].installedVersion = ApplicationVersion(marketing: "1." + String(repeating: "1234567890", count: 8))
                apps[index].availableVersion = ApplicationVersion(marketing: "2." + String(repeating: "9876543210", count: 8))
            }
        }
        return AppScanSummary(sessionID: DebugAppUpdatePresentationFixture.sessionID,
            generatedAt: DebugAppUpdatePresentationFixture.referenceDate, applications: apps)
    }
}
#endif
