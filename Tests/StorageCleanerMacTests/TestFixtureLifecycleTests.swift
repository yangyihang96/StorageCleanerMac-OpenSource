import Foundation
import XCTest
@testable import StorageCleanerMac

final class TestFixtureLifecycleTests: XCTestCase {
    private enum CreationFailure: Error { case afterFirstDirectory }

    func testDataHomeCreationFailureRemovesPartialRootAndThrows() throws {
        var created: [URL] = []
        XCTAssertThrowsError(try TestFileSystem.makeHome(for: self, createDirectory: { directory in
            if !created.isEmpty { throw CreationFailure.afterFirstDirectory }
            created.append(directory)
            try TestFileSystem.createDirectory(at: directory)
        })) { XCTAssertTrue($0 is CreationFailure) }
        let root = try XCTUnwrap(created.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOperationHomeCreationFailureRemovesPartialRootAndThrows() throws {
        var created: [URL] = []
        XCTAssertThrowsError(try TestFileSystem.makeOperationHome(for: self, purpose: "failed-initialization", createDirectory: { directory in
            if !created.isEmpty { throw CreationFailure.afterFirstDirectory }
            created.append(directory)
            try TestFileSystem.createDirectory(at: directory)
        })) { XCTAssertTrue($0 is CreationFailure) }
        let home = try XCTUnwrap(created.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.deletingLastPathComponent().path))
    }

    func testThrowingFixtureInitializationPreservesTheOriginalErrorAndRemovesItsRoot() throws {
        let root = TestFileSystem.uniqueRoot("FailedFixture")
        defer { TestFileSystem.remove(root) }
        XCTAssertThrowsError(try TestFileSystem.initialize(root: root) { () throws -> Void in
            try TestFileSystem.createDirectory(at: root.appendingPathComponent("created-first"))
            throw CreationFailure.afterFirstDirectory
        }) { XCTAssertTrue($0 is CreationFailure) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDeletionFailureIsAnXCTestFailureAndDoesNotPretendTheRootIsGone() throws {
        let root = try TestFileSystem.makeHome(for: self)
        XCTExpectFailure("清理错误必须报告给 XCTest，不能静默吞掉") {
            TestFileSystem.remove(root, removeItem: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        TestFileSystem.remove(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        TestFileSystem.remove(root) // 已不存在的自身根允许重复清理。
    }
}
