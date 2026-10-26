import Foundation
import XCTest
@testable import StorageCleanerMac

final class AppUpdateD192Tests: XCTestCase {
    func testConfirmedCountsAgreeAndEveryBatchMemberBelongsToThatSet() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        var apps: [InstalledApplication] = []
        for (id, provider, evidence) in [
            ("app-store", ApplicationUpdateProviderIdentifier.macAppStore, ["verified-app-store-receipt"]),
            ("sparkle", .sparkle, ["sparkle-framework", "sparkle-feed"])
        ] {
            let path = try bundle(id, in: home)
            apps.append(AppUpdateTestFixtures.application(id: id, path: path, availableVersion: "2.0",
                provider: provider, status: .updateAvailable, sourceEvidence: evidence))
        }
        apps.append(try formula("revision", installed: "4.0.0", target: "4.0.0_1", home: home))
        // Homebrew reports stable=4.0.0 even when only the formula revision changed.
        apps.append(try formula("stable-revision", installed: "4.0.0", target: "4.0.0", home: home))
        apps.append(try formula("openssl@3", installed: "3.6.5", target: "3.5.9", home: home))
        var duplicate = AppUpdateTestFixtures.strictHomebrewApplication(id: "duplicate",
            path: try bundle("duplicate", in: home), requiresAuthorization: true)
        duplicate.isDuplicate = true
        duplicate.duplicateLocations = [URL(fileURLWithPath: try bundle("copy", in: home))]
        apps.append(duplicate)
        var system = AppUpdateTestFixtures.strictHomebrewApplication(id: "system", path: try bundle("system", in: home))
        system.isSystemApplication = true
        apps.append(system)
        apps.append(AppUpdateTestFixtures.application(id: "failed-in-app", path: try bundle("unknown", in: home),
            provider: .sparkle, status: .failed, sourceEvidence: ["sparkle-framework"]))
        for (name, installed, build, target) in [
            ("Epic", "20.3.5", "20.3.5", "20.3.3"),
            ("Claude", "3.1623.0", "3.1623.0", "3.1623.0,digest"),
            ("OrbStack", "2.2.4", "21120", "2.2.4,21120"),
            ("Surfshark", "4.30.2", "4650", "4.30.2,4650")
        ] {
            let path = try bundle(name, in: home)
            let metadata = AppUpdateTestFixtures.homebrewMetadata(token: name.lowercased(), installedVersions: ["1.0"],
                currentVersion: target, outdatedProvenance: .greedy, autoUpdates: true, appBundlePaths: [path])
            var app = AppUpdateTestFixtures.application(id: name, path: path, version: installed, build: build,
                installationSource: .homebrewCask, provider: .homebrew, status: .discovered,
                sourceEvidence: ["homebrew-cli-json-v2"], homebrewMetadata: metadata)
            let check = try await HomebrewProvider(homebrewExecutableProvider: { nil }).checkForUpdate(app)
            XCTAssertEqual(check.status, .upToDate, name)
            app.updateStatus = check.status
            app.availableVersion = check.availableVersion
            app.updateError = check.warning
            apps.append(app)
        }
        let summary = AppScanSummary(sessionID: UUID(), applications: apps)
        let catalog = AppUpdateCatalogSnapshot(summary: summary)
        let page = AppUpdateLightfieldPresentation(summary: summary)
        let persisted = LastAppScanSummary(summary: summary)
        let confirmedIDs = Set(apps.filter(\.hasConfirmedPresentableUpdate).map(\.id))
        XCTAssertEqual(confirmedIDs, ["app-store", "sparkle", "revision", "stable-revision"])
        XCTAssertEqual(summary.confirmedUpdateCount, 4)
        XCTAssertEqual(catalog.confirmedUpdateCount, summary.confirmedUpdateCount)
        XCTAssertEqual(persisted.confirmedUpdateCount, summary.confirmedUpdateCount)
        XCTAssertEqual(page.confirmedUpdateCount, summary.confirmedUpdateCount)
        XCTAssertEqual(Set(page.entries.map(\.id)), confirmedIDs)
        let batchIDs = Set(ApplicationUpdatePlanBuilder().build(applications: apps).batchApplicationIDs)
        XCTAssertTrue(batchIDs.isSubset(of: confirmedIDs))
        XCTAssertEqual(batchIDs, ["revision", "stable-revision"])
        XCTAssertEqual(AppUpdateBatchPresentation(applications: apps).count, batchIDs.count)
        XCTAssertFalse(duplicate.canJoinAutomaticUpdateBatch)
        XCTAssertFalse(system.canJoinAutomaticUpdatePlan)
        let unknown = try XCTUnwrap(catalog.entries.first { $0.id == "failed-in-app" })
        XCTAssertFalse(unknown.isUpdateAvailable, "D192: 旧值 true（failed 枚举不等于确认更高版本）")
    }

    func testFourDuplicateAuthorizationEntriesCannotBypassTheConfirmedCount() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let apps = try (0..<4).map { index -> InstalledApplication in
            var app = AppUpdateTestFixtures.strictHomebrewApplication(id: "duplicate-\(index)",
                path: try bundle("duplicate-\(index)", in: home), requiresAuthorization: true)
            app.isDuplicate = true
            return app
        }
        XCTAssertEqual(AppScanSummary(sessionID: UUID(), applications: apps).confirmedUpdateCount, 0)
        XCTAssertEqual(ApplicationUpdatePlanBuilder().build(applications: apps).batchCount, 0,
            "D192: 旧值 4，授权分支绕过重复副本检查")
        XCTAssertEqual(AppUpdateBatchPresentation(applications: apps).count, 0)
        XCTAssertTrue(apps.allSatisfy { !$0.canJoinAutomaticUpdatePlan && !$0.canJoinAutomaticUpdateBatch })
    }

    func testLowerFormulaTargetStaysVisibleAsManualWithD190Explanation() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        var app = try formula("openssl@3", installed: "3.6.5", target: "3.5.9", home: home)
        let check = try await HomebrewProvider(homebrewExecutableProvider: { nil }).checkForUpdate(app)
        app.updateStatus = check.status
        app.availableVersion = check.availableVersion
        app.updateError = check.warning
        let summary = AppScanSummary(sessionID: UUID(), applications: [app])
        let catalog = AppUpdateCatalogSnapshot(summary: summary)
        let row = try XCTUnwrap(catalog.entries(matching: .manual).first)
        XCTAssertEqual(row.id, "openssl@3")
        XCTAssertTrue(row.application.updateError?.contains("brew upgrade") == true)
        XCTAssertFalse(row.isUpdateAvailable)
        XCTAssertEqual(summary.confirmedUpdateCount, 0)
        XCTAssertTrue(AppUpdateLightfieldPresentation(summary: summary).entries.isEmpty)
        XCTAssertFalse(app.canJoinAutomaticUpdatePlan)
        XCTAssertFalse(app.canJoinAutomaticUpdateBatch)
        XCTAssertEqual(AppUpdateBatchPresentation(applications: [app]).count, 0)
    }

    private func bundle(_ name: String, in home: URL) throws -> String {
        let url = home.appendingPathComponent("Applications/\(name).app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func formula(_ token: String, installed: String, target: String, home: URL) throws -> InstalledApplication {
        let url = home.appendingPathComponent("Cellar/\(token)/\(installed)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return AppUpdateTestFixtures.application(id: token, name: token, bundleIdentifier: "homebrew.formula.\(token)",
            path: url.path, version: installed, availableVersion: target, installationSource: .homebrewFormula,
            provider: .homebrew, status: .updateAvailable, sourceEvidence: ["homebrew-cli-json-v2"],
            homebrewMetadata: AppUpdateTestFixtures.homebrewMetadata(token: token, kind: .formula,
                installedVersions: [installed], currentVersion: target, appBundlePaths: []),
            canAutomaticallyUpdate: true, requiresUserInteraction: false)
    }
}
