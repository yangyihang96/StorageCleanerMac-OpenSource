import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

final class StorageMapD192Tests: XCTestCase {
    func testWhereNeededUsesFlagsForFilesFoldersAndCloudLocationsWithoutQueries() throws {
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let paths = ["Plain/file", "Library/Mobile Documents/current",
                     "Library/CloudStorage/OneDrive/downloaded-but-stale", "Desktop/local", "Documents/local",
                     "Library/CloudStorage/OneDrive/cloud-file", "CloudFolder/never-enumerated"]
        for path in paths {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8192).write(to: url)
        }
        let placeholders = Set([home.appendingPathComponent("Library/CloudStorage/OneDrive/cloud-file").path,
                                home.appendingPathComponent("CloudFolder").path])
        let target = StorageMapScanTarget(path: home.path, title: "D192", kind: .homeDirectory)
        for concurrency in [1, 4] {
            let queries = D192CloudQueries()
            let options = DiskScanner.StorageMapAnalysisOptions(
                concurrency: concurrency, ubiquityLookup: .whereNeeded,
                cloudState: .custom { queries.read($0) },
                fileStatus: { url in
                    guard var status = DiskScanner.storageMapFileStatus(at: url) else { return nil }
                    // Foundation enumerates /private/var while the temporary
                    // fixture URL resolves to /var. Compare the same aliases.
                    if placeholders.contains(url.resolvingSymlinksInPath().path) {
                        status.st_flags |= UInt32(SF_DATALESS)
                        queries.recordDataless(url.lastPathComponent)
                    }
                    return status
                })
            let analysis = try DiskScanner(excludedPaths: [])
                .storageMapAnalysis(target: target, options: options)
            XCTAssertEqual(queries.count, 0, "No FileProvider calls, even at the root or in cloud locations")
            XCTAssertEqual(queries.datalessNames, ["cloud-file", "CloudFolder"])
            let file = try XCTUnwrap(analysis.index.indexedEntry(at: home.appendingPathComponent(
                "Library/CloudStorage/OneDrive/cloud-file").path))
            XCTAssertTrue(file.isCloudOnly)
            XCTAssertEqual(file.sizeBytes, 0, "D192: 旧值使用分配大小；占位文件不计本机空间")
            let folder = try XCTUnwrap(analysis.index.indexedEntry(at: home.appendingPathComponent("CloudFolder").path))
            XCTAssertTrue(folder.isCloudOnly)
            XCTAssertFalse(folder.canDescend)
            XCTAssertNil(analysis.index.indexedEntry(at: home.appendingPathComponent("CloudFolder/never-enumerated").path))
            for path in paths.dropLast(2) {
                let row = try XCTUnwrap(analysis.index.indexedEntry(at: home.appendingPathComponent(path).path))
                XCTAssertFalse(row.isCloudOnly, path)
                XCTAssertGreaterThan(row.sizeBytes ?? 0, 0, path)
            }
            let allocatedLocalBytes = try paths.dropLast(2).reduce(Int64(0)) { total, path in
                let values = try home.appendingPathComponent(path).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                return total + Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
            XCTAssertEqual(analysis.rootSnapshot.measuredBytes, allocatedLocalBytes)
        }
    }

    func testDatalessSelectedRootIsNotEnumerated() throws {
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let root = home.appendingPathComponent("Placeholder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("never"))
        let queries = D192CloudQueries()
        let options = DiskScanner.StorageMapAnalysisOptions(
            concurrency: 1, ubiquityLookup: .whereNeeded, cloudState: .custom { queries.read($0) },
            fileStatus: { url in
                guard var status = DiskScanner.storageMapFileStatus(at: url) else { return nil }
                if url.path == root.path { status.st_flags |= UInt32(SF_DATALESS) }
                return status
            })
        let result = try DiskScanner(excludedPaths: []).storageMapAnalysis(
            target: StorageMapScanTarget(path: root.path, title: "Placeholder", kind: .homeDirectory), options: options)
        XCTAssertEqual(result.inspectedItemCount, 0)
        XCTAssertTrue(result.rootSnapshot.entries.isEmpty)
        XCTAssertEqual(queries.count, 0)
    }

    func testEveryItemKeepsFileProviderSemanticsForDownloadedButNonCurrentFile() throws {
        let home = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        let file = home.appendingPathComponent("stale")
        try Data(repeating: 1, count: 8192).write(to: file)
        let target = StorageMapScanTarget(path: home.path, title: "D192", kind: .homeDirectory)
        let queries = D192CloudQueries()
        let scanner = DiskScanner(excludedPaths: [])
        let reference = try scanner.storageMapAnalysis(target: target, options: .init(
            concurrency: 1, ubiquityLookup: .everyItem, cloudState: .custom { queries.read($0) }))
        let queried = queries.count
        XCTAssertGreaterThan(queried, 0)
        XCTAssertEqual(reference.index.indexedEntry(at: file.path)?.isCloudOnly, true)
        let actual = try scanner.storageMapAnalysis(target: target, options: .init(
            concurrency: 1, ubiquityLookup: .whereNeeded, cloudState: .custom { queries.read($0) }))
        XCTAssertEqual(queries.count, queried)
        XCTAssertEqual(actual.index.indexedEntry(at: file.path)?.isCloudOnly, false)
        XCTAssertGreaterThan(actual.index.indexedEntry(at: file.path)?.sizeBytes ?? 0, 0)
    }
}

private final class D192CloudQueries: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var flaggedNames = Set<String>()
    var count: Int { lock.withLock { calls } }
    var datalessNames: Set<String> { lock.withLock { flaggedNames } }
    func recordDataless(_ name: String) { lock.withLock { _ = flaggedNames.insert(name) } }
    func read(_ url: URL) -> DiskScanner.StorageMapCloudState {
        lock.withLock { calls += 1 }
        return .init(isUbiquitous: true, isCurrent: false)
    }
}
