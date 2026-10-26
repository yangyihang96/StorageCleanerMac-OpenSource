import Foundation
import XCTest
@testable import StorageCleanerMac

final class SpaceMapTreemapFilterTests: XCTestCase {
    func testWholeMatchesAndPartialAncestorsCountSpaceOnce() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("src", [.file("App", 10), .file("notes", 30)]),
            .directory("apps", [.file("apple", 100), .file("x", 7)]),
            .file("readme", 1)
        ])
        let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: " APP "))
        XCTAssertEqual(result.keyword, "APP")
        XCTAssertEqual(result.topLevelMatchCount, 2)
        XCTAssertEqual(result.matchedBytes, 117)
        XCTAssertEqual(result.matchedItems, 4)
        XCTAssertEqual(result.keep(forPath: "/analysis/apps"), .whole)
        XCTAssertEqual(result.keep(forPath: "/analysis/apps/x"), .whole)
        XCTAssertEqual(result.keep(forPath: "/analysis/apps/unrecorded/child"), .whole)
        XCTAssertEqual(result.keep(forPath: "/analysis/src"), .partial(bytes: 10, items: 1))
        XCTAssertEqual(result.keep(forPath: "/analysis"), .partial(bytes: 117, items: 4))
        XCTAssertNil(result.keep(forPath: "/analysis/src/notes"))
        XCTAssertNil(result.keep(forPath: "/analysis/readme"))
        XCTAssertNil(result.keepByPath["/analysis/apps/apple"], "A whole subtree is implicit")
    }

    func testNamesIgnoreCaseAndDiacriticsAndSupportChineseAndJapanese() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .file("Café.TXT", 7), .file("Cafe\u{301}-notes", 11),
            .file("旅行照片.jpg", 13), .file("日本語の資料.pdf", 17)
        ])
        let cafe = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: "cAFE"))
        XCTAssertEqual(cafe.topLevelMatchCount, 2)
        XCTAssertEqual(cafe.matchedBytes, 18)
        for (keyword, bytes) in [("照片", Int64(13)), ("資料", Int64(17))] {
            let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: keyword))
            XCTAssertEqual(result.topLevelMatchCount, 1)
            XCTAssertEqual(result.matchedBytes, bytes)
        }
    }

    func testSearchBelowRootLeavesOtherBranchesWholeWithComponentBoundaries() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("src", [.file("main.swift", 10), .file("notes", 20)]),
            .directory("src2", [.file("notes", 30)])
        ])
        let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(
            index: index, basePath: "/analysis/src/./", keyword: "main"
        ))
        XCTAssertEqual(result.basePath, "/analysis/src")
        XCTAssertEqual(result.keep(forPath: "/analysis/src2/notes"), .whole)
        XCTAssertEqual(result.keep(forPath: "/elsewhere"), .whole)
        XCTAssertEqual(result.keep(forPath: "/analysis"), .whole)
        XCTAssertEqual(result.keep(forPath: "/analysis/src"), .partial(bytes: 10, items: 1))
        XCTAssertNil(result.keep(forPath: "/analysis/src/notes"))
    }

    func testEmptyKeywordIsNilAndNoMatchesIsAnEmptyResult() throws {
        let index = SpaceMapMemoryIndex.make(children: [.file("readme", 1)])
        for keyword in ["", " \n\t "] {
            XCTAssertNil(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: keyword))
        }
        let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: "missing"))
        XCTAssertTrue(result.keepByPath.isEmpty)
        XCTAssertEqual(result.topLevelMatchCount, 0)
        XCTAssertEqual(result.matchedBytes, 0)
        XCTAssertEqual(result.matchedItems, 0)
        XCTAssertEqual(result.keep(forPath: "/analysis"), .partial(bytes: 0, items: 0))
        XCTAssertNil(result.keep(forPath: "/analysis/readme"))
    }

    func testDuplicateHardLinksMatchButContributeZeroBytesLikeSnapshots() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .file("match-original", 5),
            .directory("folder", [.file("match-duplicate", 9_999)])
        ], duplicates: ["/analysis/folder/match-duplicate"])
        let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: "match"))
        XCTAssertEqual(result.topLevelMatchCount, 2)
        XCTAssertEqual(result.matchedBytes, 5)
        XCTAssertEqual(result.matchedItems, 2)
        XCTAssertEqual(result.keep(forPath: "/analysis/folder"), .partial(bytes: 0, items: 1))
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: "/analysis/folder", using: index)
        XCTAssertEqual(snapshot.entries.first?.sizeBytes, 0)
    }

    func testMatchedBytesSaturateForWholeMatchesAndPartialAncestors() throws {
        let bytes = Int64.max / 2 + 1
        let cases: [[SpaceMapMemoryNode]] = [
            [.file("match-a", bytes), .file("match-b", bytes)],
            [.directory("left", [.file("match-a", bytes)]),
             .directory("right", [.file("match-b", bytes)])]
        ]
        for children in cases {
            let index = SpaceMapMemoryIndex.make(children: children)
            XCTAssertEqual(index.directories[index.rootPath]?.sizeBytes, Int64.max)
            let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(
                index: index, basePath: index.rootPath, keyword: "match"
            ))
            XCTAssertEqual(result.matchedBytes, Int64.max)
            XCTAssertEqual(result.matchedItems, 2)
            XCTAssertEqual(result.topLevelMatchCount, 2)
            XCTAssertEqual(result.keep(forPath: index.rootPath), .partial(bytes: .max, items: 2))
            if index.directories["/analysis/left"] != nil {
                XCTAssertEqual(result.keep(forPath: "/analysis/left"), .partial(bytes: bytes, items: 1))
                XCTAssertEqual(result.keep(forPath: "/analysis/right"), .partial(bytes: bytes, items: 1))
            }
        }
    }

    func testMatchedItemCountsSaturateForDirectoriesAndPartialAncestors() throws {
        let matches: [SpaceMapMemoryNode] = [.directory("match-a", [.file("a", 1)]),
                                             .directory("match-b", [.file("b", 1)])]
        for nested in [false, true] {
            let original = SpaceMapMemoryIndex.make(children: nested ? [.directory("branch", matches)] : matches)
            let parent = nested ? "/analysis/branch" : "/analysis"
            var directories = original.directories
            directories[parent + "/match-a"]?.descendantItemCount = .max
            directories[parent + "/match-b"]?.descendantItemCount = .max - 1
            let index = StorageMapAnalysisIndex(
                rootPath: original.rootPath, rootVolumeIdentifier: nil, directories: directories,
                childrenByDirectory: original.childrenByDirectory, blockedDirectoryPaths: [], duplicateFilePaths: []
            )
            let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(
                index: index, basePath: index.rootPath, keyword: "match"
            ))
            XCTAssertEqual(result.matchedItems, Int.max)
            XCTAssertEqual(result.matchedBytes, 2)
            XCTAssertEqual(result.topLevelMatchCount, 2)
            XCTAssertEqual(result.keep(forPath: parent), .partial(bytes: 2, items: .max))
        }
    }

    func testBlockedDirectoriesAreNotSearched() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("blocked", [.file("needle", 100)]), .file("needle.txt", 10)
        ], blocked: ["/analysis/blocked"])
        let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: "needle"))
        XCTAssertEqual(result.topLevelMatchCount, 1)
        XCTAssertEqual(result.matchedBytes, 10)
        XCTAssertNil(result.keep(forPath: "/analysis/blocked"))
    }

    func testSearchAtSlashRootKeepsOnlyMatchesInsideIt() throws {
        let index = SpaceMapMemoryIndex.make(rootPath: "/", children: [.file("yes", 1), .file("no", 2)])
        let result = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: "/", keyword: "yes"))
        XCTAssertEqual(result.keep(forPath: "/yes"), .whole)
        XCTAssertNil(result.keep(forPath: "/no"))
        XCTAssertEqual(result.keep(forPath: "/"), .partial(bytes: 1, items: 1))
    }

    func testCancellationBeforeAndDuringLargeSearchReturnsNil() {
        let index = SpaceMapMemoryIndex.make(children: (0..<2_050).map { .file("file-\($0)", 1) })
        XCTAssertNil(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: "file", isCancelled: { true }))
        var checks = 0
        let result = SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: "file") {
            checks += 1
            return checks == 2
        }
        XCTAssertNil(result)
        XCTAssertEqual(checks, 2, "The search checks cancellation by its 1,024th item")
    }
}

/// Shared pure-memory fixtures for this batch. No filesystem or production
/// debug helpers are involved; aggregates use the snapshot's duplicate policy.
indirect enum SpaceMapMemoryNode: Sendable {
    case file(String, Int64)
    case directory(String, [SpaceMapMemoryNode])
}

enum SpaceMapMemoryIndex {
    static func make(
        rootPath: String = "/analysis",
        children: [SpaceMapMemoryNode],
        blocked: Set<String> = [],
        duplicates: Set<String> = [],
        packages: Set<String> = []
    ) -> StorageMapAnalysisIndex {
        var directories: [String: StorageMapDirectoryAggregate] = [:]
        var entriesByDirectory: [String: [StorageMapIndexedEntry]] = [:]
        func add(_ nodes: [SpaceMapMemoryNode], at path: String) -> StorageMapDirectoryAggregate {
            var aggregate = StorageMapDirectoryAggregate()
            var entries: [StorageMapIndexedEntry] = []
            for node in nodes {
                switch node {
                case let .file(name, bytes):
                    let childPath = StorageMapAnalysisIndex.childPath(name, in: path)
                    aggregate.sizeBytes = saturatingAdd(aggregate.sizeBytes, duplicates.contains(childPath) ? 0 : bytes)
                    aggregate.descendantItemCount = saturatingAdd(aggregate.descendantItemCount, 1)
                    entries.append(.init(name: name, kind: "file", sizeBytes: bytes,
                                         isDirectory: false, canDescend: false, isEstimated: false))
                case let .directory(name, children):
                    let childPath = StorageMapAnalysisIndex.childPath(name, in: path)
                    let child = add(children, at: childPath)
                    aggregate.sizeBytes = saturatingAdd(aggregate.sizeBytes, child.sizeBytes)
                    aggregate.descendantItemCount = saturatingAdd(
                        aggregate.descendantItemCount, saturatingAdd(1, child.descendantItemCount)
                    )
                    let isPackage = packages.contains(childPath)
                    entries.append(.init(name: name, kind: isPackage ? "package" : "folder", sizeBytes: nil,
                                         isDirectory: true, canDescend: !isPackage, isEstimated: false))
                }
            }
            aggregate.immediateChildCount = entries.count
            directories[path] = aggregate
            entriesByDirectory[path] = entries
            return aggregate
        }
        _ = add(children, at: rootPath)
        return StorageMapAnalysisIndex(rootPath: rootPath, rootVolumeIdentifier: nil,
                                       directories: directories, childrenByDirectory: entriesByDirectory,
                                       blockedDirectoryPaths: blocked, duplicateFilePaths: duplicates)
    }

    private static func saturatingAdd<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
