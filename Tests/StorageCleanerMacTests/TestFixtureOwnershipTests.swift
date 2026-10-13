import Foundation
import XCTest
@testable import StorageCleanerMac

final class TestFixtureOwnershipTests: XCTestCase {
    func testRealHomeTrashAndUnregisteredUUIDRootsAreRejectedBeforeAnyWrite() throws {
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertThrowsError(try TestFileSystem.requireOwned(realHome, for: self, operation: true))
        XCTAssertThrowsError(try TestFileSystem.requireOwned(realHome.appendingPathComponent(".Trash"), for: self, operation: true))
        XCTAssertThrowsError(try TestFileSystem.requireOwned(CleanupReportJournal(directory: realHome.appendingPathComponent("receipts")), for: self))
        let unowned = TestFileSystem.uniqueOperationRoot("ownership-unregistered")
        XCTAssertThrowsError(try TestFileSystem.requireOwned(unowned, for: self, operation: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unowned.path))
    }

    @MainActor
    func testFactoryRejectsAnUnownedDataOverride() throws {
        let unowned = TestFileSystem.uniqueRoot("UnownedData")
        XCTAssertThrowsError(try ScanStore.makeForTests(for: self, dataDirectory: unowned))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unowned.path))
    }

    func testOwnedRootsAllowUncreatedLeavesAndRejectSymlinkEscapes() throws {
        let data = try TestFileSystem.makeHome(for: self)
        let home = try TestFileSystem.makeOperationHome(for: self, purpose: "ownership")
        let outside = try TestFileSystem.makeOperationHome(for: self, purpose: "ownership-outside")
        XCTAssertEqual(try TestFileSystem.requireOwnedData(data.appendingPathComponent("future.json"), for: self), data.appendingPathComponent("future.json"))
        XCTAssertEqual(try TestFileSystem.requireOwned(CleanupReportJournal(directory: home.appendingPathComponent("receipts")), for: self).directory, home.appendingPathComponent("receipts"))
        XCTAssertThrowsError(try TestFileSystem.requireOwnedData(home, for: self))
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try TestFileSystem.requireOwned(link.appendingPathComponent("future.json"), for: self, operation: true))
    }
}
