import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class IndependentBatchBReviewTests: XCTestCase {
    func testUnreadableDeviceSetIsUnknownRatherThanAbsent() throws {
        let home = try TestFileSystem.makeHome(for: self)
        let parent = home.appendingPathComponent("Blocked Parent", isDirectory: true)
        let deviceSet = parent.appendingPathComponent("XCTestDevices", isDirectory: true)
        let device = deviceSet.appendingPathComponent("11111111-2222-4333-8444-555555555555", isDirectory: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let runtimeID = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
        let plist = try PropertyListSerialization.data(fromPropertyList: ["runtime": runtimeID], format: .xml, options: 0)
        try plist.write(to: device.appendingPathComponent("device.plist"))
        let reader = FoundationSimulatorDeviceSetReader()
        XCTAssertEqual(reader.runtimeIdentifiers(inSetAt: deviceSet), [runtimeID])

        let observed: Set<String>?
        do {
            XCTAssertEqual(chmod(parent.path, mode_t(0o000)), 0)
            defer { XCTAssertEqual(chmod(parent.path, mode_t(0o700)), 0) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: deviceSet.path), "The fixture must exercise inaccessible-parent lookup")
            observed = reader.runtimeIdentifiers(inSetAt: deviceSet)
        }
        let inventory = SimulatorInventory(devices: [], runtimes: [SimulatorRuntime(
            identifier: "22222222-3333-4444-8555-666666666666", runtimeIdentifier: runtimeID,
            version: "18.0", build: "22A3351", state: "Ready", isDeletable: true, bytes: 4096
        )], otherDeviceSetRuntimes: observed)
        let offered = SimulatorCleanupPolicy.items(in: inventory)
        print("REVIEW_B_UNREADABLE_SET unknown=\(observed == nil) offeredRuntimes=\(offered.count)")
        XCTAssertNil(observed, "Cannot read the device set is not proof that it does not exist")
        XCTAssertTrue(offered.isEmpty, "A runtime used by an unreadable device set must not be offered for deletion")
    }

    func testUnreadableTrashReadbackDoesNotReportDeletion() async throws {
        let home = try TestFileSystem.makeOperationHome(for: self)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let file = trash.appendingPathComponent("retained.bin")
        try Data(repeating: 1, count: 4096).write(to: file)
        let frozen = try XCTUnwrap(CleanupService.freezeTrash(at: trash))
        let result: FrozenTrashEmptyResult
        do {
            defer { XCTAssertEqual(chmod(trash.path, mode_t(0o700)), 0) }
            result = await CleanupService.emptyFrozenTrash(frozen, deleter: ReadbackDeniedDeleter())
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The fake deleter must leave the fixture intact")
        print("REVIEW_B_TRASH_READBACK deleted=\(result.deletedCount) failed=\(result.failedCount) retained=true")
        XCTAssertEqual(result.deletedCount, 0, "A failed identity read is not proof that an entry is gone")
        XCTAssertEqual(result.deletedBytes, 0)
        XCTAssertEqual(result.failedCount, 1)
    }

    @MainActor
    func testKeptTrashItemsRemainInTheScanResult() async throws {
        let item = StorageItem(
            id: "retained-trash", title: "Trash fixture", path: "/nonexistent-fixture/.Trash",
            sourceID: "trash_bins", groupTitle: "Trash", sizeBytes: 4096, tier: .green,
            kind: "folder", reason: "fixture", recommendation: "fixture", risk: "fixture",
            requiresClose: "", trashPaths: [], openPath: "/nonexistent-fixture/.Trash", status: .available
        )
        for outcome in [FrozenTrashEmptyResult(skippedCount: 1), FrozenTrashEmptyResult(failedCount: 1)] {
            let store = try ScanStore.makeForTests(for: self,
                scanHeavyWorkOperations: TestOperationFactory(for: self).scanOperations(emptyTrash: { _ in outcome }),
                cleanupFeatureConfiguration: .legacy)
            store.result = ScanResult(
                generatedAt: Date(), scanSeconds: 0.01,
                system: SystemSnapshot(osName: "macOS", build: "fixture", arch: "arm64", user: "fixture",
                    home: "/nonexistent-fixture", filesystem: "APFS", purgeable: "", diskName: "Fixture",
                    diskTotalBytes: 16384, diskUsedBytes: 8192, diskFreeBytes: 8192),
                groups: [], items: [item], deniedPaths: [])
            store.pendingEmptyTrash = FrozenTrash.testFixture(names: ["retained.bin"])
            store.confirmEmptyTrash(acknowledgesPermanentDeletion: true, acknowledgesTrashContentsReviewed: true)
            let deadline = ContinuousClock.now + .seconds(5)
            while store.isEmptyingTrash && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(store.isEmptyingTrash)
            let retainsTrash = store.result?.items.contains { $0.sourceID == "trash_bins" } == true
            print("REVIEW_B_TRASH_RESULT skipped=\(outcome.skippedCount) failed=\(outcome.failedCount) retainsTrash=\(retainsTrash)")
            XCTAssertTrue(retainsTrash, "No item was deleted, so the scan must not show an empty Trash")
        }
    }
}

private struct ReadbackDeniedDeleter: CleanupPermanentDeleting {
    func removeTrashEntry(_ deletion: CleanupTrashEntryDeletion) async throws {
        // Simulate a successful backend response followed by loss of readback access.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: deletion.trashURL.path)
    }
}
