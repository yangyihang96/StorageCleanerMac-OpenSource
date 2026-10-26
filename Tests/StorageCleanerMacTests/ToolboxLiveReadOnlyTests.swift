import Foundation
import XCTest
@testable import StorageCleanerMac

/// D-FP1–D-FP6: opt-in read-only checks of the new tool scanners on this
/// Mac. They print counts and timings only (no names or paths) and never
/// move, change or open a file.
final class ToolboxLiveReadOnlyTests: XCTestCase {
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["STORAGE_CLEANER_RUN_LIVE_TOOLBOX_SCAN"] == "1" else {
            throw XCTSkip("Set STORAGE_CLEANER_RUN_LIVE_TOOLBOX_SCAN=1 for the explicit local read-only audit.")
        }
    }

    func testLiveExtensionInventory() async throws {
        try requireOptIn()
        let started = Date()
        let inventory = await ExtensionInventoryScanner().scan()
        let elapsed = Date().timeIntervalSince(started)
        for kind in ExtensionKind.allCases {
            let items = inventory.items(of: kind)
            let movable = items.filter(\.management.isMovable).count
            print("LIVE_EXTENSIONS \(kind.rawValue) count=\(items.count) movable=\(movable) "
                  + "bytes=\(items.reduce(0) { $0 + $1.bytes }) obsolete=\(items.filter { $0.obsolescence != nil }.count)")
        }
        print("LIVE_EXTENSIONS hiddenApple=\(inventory.hiddenAppleExtensionCount) "
              + "pluginKit=\(inventory.pluginKitAvailable) seconds=\(String(format: "%.2f", elapsed))")
        XCTAssertTrue(inventory.pluginKitAvailable)
        XCTAssertLessThan(elapsed, 30)
    }

    func testLiveMaintenanceStatuses() async throws {
        try requireOptIn()
        let started = Date()
        let statuses = await SystemMaintenanceProbe().statuses()
        for id in SystemMaintenanceTaskID.allCases {
            let status = try XCTUnwrap(statuses[id])
            print("LIVE_MAINTENANCE \(id.rawValue) mode=\(status.mode) recommended=\(status.isRecommended) "
                  + "blocked=\(status.blocker != nil) fda=\(status.needsFullDiskAccess) lines=\(status.lines.count)")
        }
        print("LIVE_MAINTENANCE seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
    }
}
