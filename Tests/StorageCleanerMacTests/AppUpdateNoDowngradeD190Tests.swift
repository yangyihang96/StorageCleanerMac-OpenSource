import XCTest
@testable import StorageCleanerMac

/// D190 (1:1 comparison round 2, 10-23): "Update All" offered Epic Games
/// Launcher 20.3.5 → 20.3.3 and reinstalls of already-current Claude, OrbStack
/// and Surfshark, because Homebrew's record of a self-updating cask was stale
/// and the batch target fell back to Homebrew's raw version. The Applications
/// tile also said 82 updates against the updater's 65.
final class AppUpdateNoDowngradeD190Tests: XCTestCase {
    private typealias Safety = HomebrewAutomaticUpdateSafety

    private func cask(installed: [String], current: String, provenance: HomebrewOutdatedProvenance = .greedy) -> HomebrewPackageMetadata {
        AppUpdateTestFixtures.homebrewMetadata(token: "example", kind: .cask, installedVersions: installed,
                                               currentVersion: current, outdatedProvenance: provenance, autoUpdates: true)
    }

    private func formula(installed: [String], current: String) -> HomebrewPackageMetadata {
        AppUpdateTestFixtures.homebrewMetadata(token: "example", kind: .formula, installedVersions: installed,
                                               currentVersion: current, appBundlePaths: [])
    }

    func testSelfUpdatedCaskNewerThanHomebrewIsNeitherATargetNorAnUpdate() async throws {
        // Epic Games Launcher: Caskroom 20.1.0, cask 20.3.3, bundle 20.3.5.
        let metadata = cask(installed: ["20.1.0"], current: "20.3.3")
        let installed = ApplicationVersion(marketing: "20.3.5")
        XCTAssertTrue(Safety.targetIsNotNewer(metadata: metadata, installedVersion: installed))
        XCTAssertNil(Safety.batchTargetVersion(metadata: metadata, installedVersion: installed))

        let application = AppUpdateTestFixtures.application(
            version: "20.3.5", installationSource: .homebrewCask, provider: .homebrew,
            status: .discovered, homebrewMetadata: metadata)
        let check = try await HomebrewProvider(homebrewExecutableProvider: { URL(fileURLWithPath: "/fake/brew") })
            .checkForUpdate(application)
        XCTAssertEqual(check.status, .upToDate)
        XCTAssertNil(check.availableVersion)
        XCTAssertNotNil(check.warning)
    }

    func testSameVersionCaskTuplesAreNotReinstalled() {
        // Claude (digest tuple), OrbStack and Surfshark (numeric build tuples).
        for (bundle, build, current) in [("3.1623.0", "3.1623.0", "3.1623.0,e751f9d5249da803676835a68a9b15463ec5b1d7"),
                                         ("2.2.4", "21120", "2.2.4,21120"), ("4.30.2", "4650", "4.30.2,4650")] {
            let metadata = cask(installed: ["1.0"], current: current)
            let installed = ApplicationVersion(marketing: bundle, build: build)
            XCTAssertTrue(Safety.targetIsNotNewer(metadata: metadata, installedVersion: installed), current)
            XCTAssertNil(Safety.batchTargetVersion(metadata: metadata, installedVersion: installed), current)
        }
        // The same version with a higher numeric build is a real update.
        let newerBuild = cask(installed: ["1.2.3,100"], current: "1.2.3,200")
        XCTAssertFalse(Safety.targetIsNotNewer(metadata: newerBuild,
                                               installedVersion: ApplicationVersion(marketing: "1.2.3", build: "100")))
    }

    func testOlderCaskStillUpdatesToHomebrewsVersion() {
        // Stats: Caskroom 3.0.17, bundle 3.0.20, cask 3.0.22 (plain outdated).
        let metadata = cask(installed: ["3.0.17"], current: "3.0.22", provenance: .plain)
        let installed = ApplicationVersion(marketing: "3.0.20")
        XCTAssertFalse(Safety.targetIsNotNewer(metadata: metadata, installedVersion: installed))
        XCTAssertEqual(Safety.batchTargetVersion(metadata: metadata, installedVersion: installed),
                       ApplicationVersion(marketing: "3.0.22"))
        // A newer build tuple and a `latest` cask keep Homebrew's verdict (D78).
        XCTAssertNotNil(Safety.batchTargetVersion(metadata: cask(installed: ["2.2.1,20628"], current: "2.2.5,21200"),
                                                  installedVersion: ApplicationVersion(marketing: "2.2.4")))
        XCTAssertFalse(Safety.targetIsNotNewer(metadata: cask(installed: ["latest"], current: "latest"),
                                               installedVersion: ApplicationVersion(marketing: "5.1")))
    }

    func testFormulaRevisionBumpStaysAndALowerVersionLineIsLeftToTerminal() async throws {
        // ada-url 4.0.0 → 4.0.0_1 (Homebrew's `versions.stable` has no revision).
        let revision = formula(installed: ["4.0.0"], current: "4.0.0")
        XCTAssertFalse(Safety.targetIsNotNewer(metadata: revision, installedVersion: ApplicationVersion(marketing: "4.0.0")))
        XCTAssertNotNil(Safety.batchTargetVersion(metadata: revision, installedVersion: ApplicationVersion(marketing: "4.0.0")))
        // libimobiledevice 1.4.0_1 → 1.4.0_2.
        XCTAssertNotNil(Safety.batchTargetVersion(metadata: formula(installed: ["1.4.0", "1.4.0_1"], current: "1.4.0"),
                                                  installedVersion: ApplicationVersion(marketing: "1.4.0_1")))

        // openssl@3 3.6.5 → 3.5.9 (Homebrew changed the version line).
        let lower = formula(installed: ["3.6.4", "3.6.5"], current: "3.5.9")
        let installed = ApplicationVersion(marketing: "3.6.5")
        XCTAssertTrue(Safety.targetIsNotNewer(metadata: lower, installedVersion: installed))
        XCTAssertNil(Safety.batchTargetVersion(metadata: lower, installedVersion: installed))
        let application = AppUpdateTestFixtures.application(
            version: "3.6.5", installationSource: .homebrewFormula, provider: .homebrew,
            status: .discovered, homebrewMetadata: lower)
        let check = try await HomebrewProvider(homebrewExecutableProvider: { URL(fileURLWithPath: "/fake/brew") })
            .checkForUpdate(application)
        XCTAssertEqual(check.status, .updateAvailable)
        XCTAssertEqual(check.availableVersion, ApplicationVersion(marketing: "3.5.9"))
        XCTAssertNotNil(check.warning)
        var checked = application
        checked.updateStatus = check.status
        checked.availableVersion = check.availableVersion
        XCTAssertFalse(checked.canJoinAutomaticUpdateBatch)
    }

    func testUpdateCountsOnlyConfirmedNewerVersions() {
        let confirmed = AppUpdateTestFixtures.strictHomebrewApplication(token: "stats")
        let inApplication = AppUpdateTestFixtures.application(
            name: "Bartender", bundleIdentifier: "com.example.bartender", path: "/Applications/Bartender.app",
            provider: .sparkle, status: .latestVersionUnknown, sourceEvidence: ["sparkle-framework"])
        let summary = AppScanSummary(sessionID: UUID(), applications: [confirmed, inApplication])
        XCTAssertEqual(summary.confirmedUpdateCount, 1)
        XCTAssertEqual(AppUpdateCatalogSnapshot(summary: summary).confirmedUpdateCount, 1)
        XCTAssertEqual(LastAppScanSummary(summary: summary).confirmedUpdateCount, 1)
    }

    func testEveryApplicationsPageReadsTheOneUpdateCount() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let classic = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/ApplicationsManager/ApplicationsOverviewView.swift"), encoding: .utf8)
        XCTAssertTrue(classic.contains("private var availableUpdateCount: Int? { store.availableAppUpdateCount }"))
        let shared = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/CareStudio/CareStudioApplications.swift"), encoding: .utf8)
        XCTAssertFalse(shared.contains("last.manualCount"))
        XCTAssertTrue(shared.contains("summary.confirmedUpdateCount"))
    }
}
