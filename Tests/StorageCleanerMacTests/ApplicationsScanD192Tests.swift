import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class ApplicationsScanD192Tests: XCTestCase {
    func testLandingScanFinishesInventoryBeforeReadOnlyUpdateCheck() async throws {
        let scanner = D192ApplicationsInventory()
        let store = try ScanStore.makeForTests(for: self, applicationInventoryScanner: scanner)
        var order: [String] = []
        let operation = try XCTUnwrap(store.applicationsScanCoordinator.start(store: store,
            readInstalledApps: {
                order.append("inventory-start")
                await Task.yield()
                XCTAssertFalse(store.isLoadingAppUpdates)
                order.append("inventory-end")
            }, isOnline: {
                order.append("network")
                XCTAssertEqual(order, ["inventory-start", "inventory-end", "network"])
                return true
            }))
        XCTAssertFalse(store.applicationsScanCoordinator.showsUpdateTile)
        await operation.value
        XCTAssertTrue(store.applicationsScanCoordinator.showsUpdateTile)
        await finished(store)
        let calls = await scanner.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.availableAppUpdateCount, 1)
        XCTAssertFalse(store.isRunningOneClickUpdate)
        XCTAssertNotEqual(store.appUpdatePresentationState.phase, .updating)
    }

    func testOfflineScanDoesNotCheckAndHidesAnEarlierUpdateTile() async throws {
        let scanner = D192ApplicationsInventory()
        let store = try ScanStore.makeForTests(for: self, applicationInventoryScanner: scanner)
        store.checkAppUpdatesForSmartCare()
        await finished(store)
        XCTAssertEqual(store.availableAppUpdateCount, 1)
        let operation = try XCTUnwrap(store.applicationsScanCoordinator.start(store: store,
            readInstalledApps: {}, isOnline: { false }))
        await operation.value
        let calls = await scanner.calls
        XCTAssertEqual(calls, 1, "The offline scan never invokes any update provider")
        XCTAssertFalse(store.isLoadingAppUpdates)
        XCTAssertFalse(store.applicationsScanCoordinator.showsUpdateTile, "An old result is not this scan's result")
        XCTAssertFalse(store.applicationsScanCoordinator.permitsUpdateTile(lastScannedAt: store.appUpdatesLastScannedAt))
        store.checkAppUpdatesForSmartCare()
        await finished(store)
        XCTAssertTrue(store.applicationsScanCoordinator.permitsUpdateTile(lastScannedAt: store.appUpdatesLastScannedAt),
            "A later explicit update check can publish a fresh tile")
    }

    func testBusyLeaseSkipsUpdateCheckWithoutTakingAnotherLease() async throws {
        let scanner = D192ApplicationsInventory()
        let coordinator = HeavyWorkCoordinator()
        let store = try ScanStore.makeForTests(for: self, heavyWorkCoordinator: coordinator,
            applicationInventoryScanner: scanner)
        let lease = try await coordinator.acquire(owner: .benchmark)
        let operation = store.applicationsScanCoordinator.start(store: store, readInstalledApps: {}, isOnline: { true })
        await operation?.value
        let owner = await coordinator.activeOwner
        await coordinator.release(lease)
        XCTAssertEqual(owner, .benchmark)
        let calls = await scanner.calls
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(store.isLoadingAppUpdates)
        XCTAssertFalse(store.applicationsScanCoordinator.showsUpdateTile)
    }

    private func finished(_ store: ScanStore) async {
        let deadline = Date().addingTimeInterval(10)
        while store.isLoadingAppUpdates, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isLoadingAppUpdates, "The injected read-only check finished")
    }
}

private actor D192ApplicationsInventory: ApplicationInventoryScanning {
    private(set) var calls = 0
    func scan(
        configuration: ApplicationScanConfiguration,
        onProgress: @escaping @Sendable (ApplicationScanProgress) async -> Void,
        onApplications: @escaping @Sendable ([InstalledApplication]) async -> Void
    ) async throws -> [InstalledApplication] {
        calls += 1
        let apps = [AppUpdateTestFixtures.strictHomebrewApplication(id: "confirmed")]
        await onApplications(apps)
        return apps
    }
}
