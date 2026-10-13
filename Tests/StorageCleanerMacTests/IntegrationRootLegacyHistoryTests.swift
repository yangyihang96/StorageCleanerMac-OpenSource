import Foundation
import XCTest
@testable import StorageCleanerMac

final class IntegrationRootLegacyHistoryTests: XCTestCase {
    func testIntegrationRootRequiresQABundleAndCachesChild() {
        let fileManager = FileManager.default
        let caches = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches").path
        let valid = caches + "/StorageCleanerIntegration-unit"
        let qa = "com.local.StorageCleanerMac.integration"
        XCTAssertEqual(
            AppDataDirectories.integrationRoot(fileManager: fileManager, bundleIdentifier: qa,
                environment: ["STORAGE_CLEANER_INTEGRATION_ROOT": valid])?.path,
            valid)
        XCTAssertNil(AppDataDirectories.integrationRoot(fileManager: fileManager,
            bundleIdentifier: "com.local.StorageCleanerMac.beta",
            environment: ["STORAGE_CLEANER_INTEGRATION_ROOT": valid]))
        XCTAssertNil(AppDataDirectories.integrationRoot(fileManager: fileManager, bundleIdentifier: qa,
            environment: ["STORAGE_CLEANER_INTEGRATION_ROOT": caches + "/Other"]))
        XCTAssertNil(AppDataDirectories.integrationRoot(fileManager: fileManager, bundleIdentifier: qa,
            environment: [:]))
    }

    func testIsolatedQARootNeverImportsLegacyHistory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricHistory-\(UUID().uuidString).json")
        let isolated = MetricHistoryStore.live(url: url, usesIntegrationRoot: true)
        XCTAssertNil(isolated.legacyMetricURL)
        XCTAssertNil(isolated.legacyPowerURL)
        let installed = MetricHistoryStore.live(url: url, usesIntegrationRoot: false)
        XCTAssertEqual(installed.legacyMetricURL?.lastPathComponent, "MetricHistory-v1.json")
        XCTAssertEqual(installed.legacyPowerURL?.lastPathComponent, "MenuBarPowerHistory.json")
    }
}
