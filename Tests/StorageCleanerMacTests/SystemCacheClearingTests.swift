import Darwin
import Foundation
import XCTest
@testable import FileOperationShared

final class SystemCacheClearingTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = TestFileSystem.uniqueRoot("D182")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Foundation preserves the /var alias on this macOS; the production
        // walker correctly refuses it. Supply the fixture's physical path.
        guard let physical = realpath(root.path, nil) else { throw POSIXError(.EIO) }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical))
    }
    private func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    private func file(_ url: URL, count: Int = 8_192) throws { try Data(repeating: 42, count: count).write(to: url) }
    private func status(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
        return info
    }
    private func clear(_ root: URL, limits: SystemCacheClearing.Limits = .init(),
                       beforeOpen: ((Int32, [CChar]) -> Void)? = nil) throws -> SystemCacheRemovalResult {
        let info = try status(root)
        return SystemCacheClearing.removeContents(ofDirectoryAt: root.path,
            expectedDevice: UInt64(bitPattern: Int64(info.st_dev)), expectedInode: UInt64(info.st_ino),
            limits: limits, beforeOpenDirectory: beforeOpen)
    }
    func testOnlyChildrenAreDeletedAndTheirAllocatedBlocksAreCounted() throws {
        let root = try fixture()
        let cache = root.appendingPathComponent("cache"); try directory(cache)
        let sub = cache.appendingPathComponent("sub"); try directory(sub)
        let first = cache.appendingPathComponent("first"); try file(first)
        let second = sub.appendingPathComponent("second"); try file(second, count: 32_768)
        let bytes = try [sub, first, second].reduce(Int64(0)) { $0 + Int64(try status($1).st_blocks) * 512 }
        let identity = try status(cache)
        let inventory = SystemCacheClearing.inventory(.coreSymbolication, at: cache.path)
        XCTAssertEqual(inventory.entryCount, 3); XCTAssertEqual(inventory.allocatedBytes, bytes)
        let result = try clear(cache)
        XCTAssertNil(result.failure); XCTAssertEqual(result.deletedEntries, 3)
        XCTAssertEqual(result.skippedEntries, 0); XCTAssertEqual(result.freedBytes, bytes)
        XCTAssertEqual(try status(cache).st_ino, identity.st_ino)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }
    func testLinksToFilesAndDirectoriesOutsideCacheAreUnlinkedWithoutFollowing() throws {
        let root = try fixture()
        let cache = root.appendingPathComponent("cache"); try directory(cache)
        let outside = root.appendingPathComponent("outside"); try directory(outside)
        let kept = outside.appendingPathComponent("kept"); try file(kept)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("dirLink"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("fileLink"), withDestinationURL: kept)
        try FileManager.default.createSymbolicLink(atPath: cache.appendingPathComponent("dangling").path, withDestinationPath: "missing")
        let result = try clear(cache)
        XCTAssertNil(result.failure); XCTAssertEqual(result.deletedEntries, 3)
        XCTAssertEqual(try status(kept).st_size, 8_192)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }
    func testAnySymbolicLinkInTargetDirectoryPathRefusesTheWholeOperation() throws {
        let root = try fixture()
        let real = root.appendingPathComponent("real/cache"); try directory(real)
        try file(real.appendingPathComponent("kept"))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("real"))
        let info = try status(real)
        let result = SystemCacheClearing.removeContents(ofDirectoryAt: alias.appendingPathComponent("cache").path,
            expectedDevice: UInt64(bitPattern: Int64(info.st_dev)), expectedInode: UInt64(info.st_ino))
        XCTAssertEqual(result.failure, SystemCacheFailure.directoryUnavailable.rawValue)
        XCTAssertEqual(result.deletedEntries, 0)
        XCTAssertEqual(try status(real.appendingPathComponent("kept")).st_size, 8_192)
        let inventory = SystemCacheClearing.inventory(.coreSymbolication, at: alias.appendingPathComponent("cache").path)
        XCTAssertNil(inventory.allocatedBytes); XCTAssertNil(inventory.device)
    }
    func testIdentityMismatchLeavesEveryChildUntouched() throws {
        let root = try fixture(); try file(root.appendingPathComponent("kept"))
        let info = try status(root)
        for (dev, ino) in [(UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino) + 1),
                           (UInt64(bitPattern: Int64(info.st_dev)) + 1, UInt64(info.st_ino))] {
            let result = SystemCacheClearing.removeContents(ofDirectoryAt: root.path, expectedDevice: dev, expectedInode: ino)
            XCTAssertEqual(result.failure, SystemCacheFailure.identityChanged.rawValue)
            XCTAssertEqual(result.deletedEntries, 0); XCTAssertEqual(result.freedBytes, 0)
        }
        XCTAssertEqual(try status(root.appendingPathComponent("kept")).st_size, 8_192)
    }
    func testDirectoryReplacedByLinkAfterItsStatIsNeverEntered() throws {
        let root = try fixture()
        let cache = root.appendingPathComponent("cache"); try directory(cache)
        let child = cache.appendingPathComponent("child"); try directory(child)
        try file(child.appendingPathComponent("inside"))
        let outside = root.appendingPathComponent("outside"); try directory(outside)
        try file(outside.appendingPathComponent("kept"))
        let renamed = root.appendingPathComponent("renamed")
        var changed = false
        let result = try clear(cache) { _, _ in
            guard !changed else { return }; changed = true
            do {
                try FileManager.default.moveItem(at: child, to: renamed)
                try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
            } catch { XCTFail("race fixture failed: \(error)") }
        }
        XCTAssertTrue(changed); XCTAssertEqual(result.deletedEntries, 0)
        XCTAssertGreaterThan(result.skippedEntries, 0)
        XCTAssertEqual(try status(outside.appendingPathComponent("kept")).st_size, 8_192)
        XCTAssertEqual(try status(renamed.appendingPathComponent("inside")).st_size, 8_192)
    }
    func testDepthLimitSkipsSubtreeAndStillClearsIndependentSiblings() throws {
        let root = try fixture(); try directory(root.appendingPathComponent("one/two/three"))
        try file(root.appendingPathComponent("one/two/three/kept"))
        try file(root.appendingPathComponent("sibling"))
        let result = try clear(root, limits: .init(depth: 1))
        XCTAssertEqual(result.failure, SystemCacheFailure.depthLimit.rawValue)
        XCTAssertGreaterThan(result.skippedEntries, 0); XCTAssertEqual(result.deletedEntries, 1)
        XCTAssertEqual(try status(root.appendingPathComponent("one/two/three/kept")).st_size, 8_192)
    }
    func testInventoryLimitsReturnMeasuredPartAndReason() throws {
        let root = try fixture()
        for name in ["one", "two", "three"] { try file(root.appendingPathComponent(name)) }
        let partial = SystemCacheClearing.inventory(.coreSymbolication, at: root.path, limits: .init(entries: 1))
        XCTAssertEqual(partial.entryCount, 1); XCTAssertGreaterThan(try XCTUnwrap(partial.allocatedBytes), 0)
        XCTAssertEqual(partial.failure, SystemCacheFailure.entryLimit.rawValue)
        let timeout = SystemCacheClearing.inventory(.coreSymbolication, at: root.path, limits: .init(seconds: 0))
        XCTAssertEqual(timeout.entryCount, 0); XCTAssertEqual(timeout.failure, SystemCacheFailure.timeLimit.rawValue)
        XCTAssertNotNil(timeout.identity)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
    }
    func testHardDepthLimitIsSixtyFourEvenWhenCallerAsksForMore() throws {
        let root = try fixture()
        var deepest = root
        for _ in 0..<66 { deepest.appendPathComponent("d") }
        try directory(deepest); try file(deepest.appendingPathComponent("kept"))
        try file(root.appendingPathComponent("sibling"))
        let result = try clear(root, limits: .init(depth: 1_000))
        XCTAssertEqual(result.failure, SystemCacheFailure.depthLimit.rawValue)
        XCTAssertEqual(result.deletedEntries, 1); XCTAssertGreaterThan(result.skippedEntries, 0)
        XCTAssertEqual(try status(deepest.appendingPathComponent("kept")).st_size, 8_192)
    }
    func testFailedChildDoesNotPreventDeletingAnotherChild() throws {
        let root = try fixture(); let kept = root.appendingPathComponent("locked")
        try file(kept); try file(root.appendingPathComponent("ordinary"))
        XCTAssertEqual(chflags(kept.path, UInt32(UF_IMMUTABLE)), 0)
        defer { XCTAssertEqual(chflags(kept.path, 0), 0) }
        let result = try clear(root)
        XCTAssertEqual(result.deletedEntries, 1); XCTAssertEqual(result.skippedEntries, 1)
        XCTAssertEqual(try status(kept).st_size, 8_192)
    }
    func testAllSiblingNamesAreRemovedAcrossDirectoryReadBatches() throws {
        let root = try fixture()
        for index in 0..<400 {
            try file(root.appendingPathComponent(String(repeating: "entry", count: 12) + String(index)), count: 0)
        }
        let result = try clear(root)
        XCTAssertNil(result.failure); XCTAssertEqual(result.deletedEntries, 400)
        XCTAssertEqual(result.skippedEntries, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
