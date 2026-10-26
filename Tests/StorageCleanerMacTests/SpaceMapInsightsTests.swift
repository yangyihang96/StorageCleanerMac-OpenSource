import Foundation
import XCTest
@testable import StorageCleanerMac

final class SpaceMapInsightsTests: XCTestCase {
    private let mib: Int64 = 1_024 * 1_024

    func testSmallDirectoriesAndFilesDoNotAppearAndThresholdIsInclusive() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("cache", [.file("data", 63 * mib)]),
            .directory("Caches", [.file("data", 64 * mib)]), .file("huge.iso", 1_000 * mib),
            .directory("Documents", [.file("personal", 200 * mib)])
        ])
        let found = try findings(index)
        XCTAssertEqual(found, [SpaceMapInsight(path: "/analysis/Caches", bytes: 64 * mib, finding: .reclaimable(.regenerableCache))])
    }

    func testNestedReclaimableDirectoriesOnlyReportTheOutermost() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory(".cache", [.directory("Caches", [.directory("DerivedData", [.file("data", 100 * mib)])]),
                                   .directory("worktrees", [.directory("one", [.file("data", 100 * mib)])])])
        ])
        let found = try findings(index)
        XCTAssertEqual(found, [SpaceMapInsight(path: "/analysis/.cache", bytes: 200 * mib, finding: .reclaimable(.regenerableCache))])
    }

    func testBothWorktreeNamesCountOnlyChildDirectoriesAndStopDescending() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("worktrees", [.directory("one", [.directory("cache", [.file("data", 70 * mib)])]),
                                      .directory("two", [.file("data", 70 * mib)]), .file("note", 1)]),
            .directory("sc-worktrees", [.directory("one", [.file("data", 80 * mib)])]),
            .directory(".agents", [.directory("worktrees", [.file("note", 100 * mib)])])
        ])
        let found = try findings(index)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].path, "/analysis/worktrees")
        XCTAssertEqual(found[0].finding, .worktrees(count: 2))
        XCTAssertEqual(found[1].path, "/analysis/sc-worktrees")
        XCTAssertEqual(found[1].finding, .worktrees(count: 1))
        for left in found {
            for right in found where left.path != right.path {
                XCTAssertFalse(right.path.hasPrefix(left.path + "/"))
            }
        }
    }

    func testResultsSortByBytesAndRespectLimitWithDeterministicTies() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("tmp", [.file("data", 80 * mib)]),
            .directory("cache", [.file("data", 200 * mib)]),
            .directory(".Trash", [.file("data", 100 * mib)]),
            .directory("Caches", [.file("data", 100 * mib)])
        ])
        XCTAssertEqual(try findings(index, limit: 3).map(\.path), ["/analysis/cache", "/analysis/.Trash", "/analysis/Caches"])
        XCTAssertEqual(try findings(index, limit: 0), [])
        XCTAssertEqual(try findings(index, limit: -1), [])
    }

    func testByteCountsExcludeDuplicateHardLinksJustLikeSnapshots() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("cache", [.file("real", 65 * mib), .file("duplicate", 500 * mib)])
        ], duplicates: ["/analysis/cache/duplicate"])
        let found = try findings(index)
        XCTAssertEqual(found.first?.bytes, 65 * mib)
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: "/analysis", using: index)
        XCTAssertEqual(found.first?.bytes, snapshot.entries.first?.sizeBytes)
    }

    func testReclaimableAnalysisRootIsExcludedAndEligibleOutermostChildrenInheritItsReason() throws {
        let index = SpaceMapMemoryIndex.make(rootPath: "/home/tester/.cache", children: [
            .directory("compiler", [.directory("nested", [.file("data", 100 * mib)])]),
            .directory("thumbnails", [.file("data", 64 * mib)]),
            .directory("small", [.file("data", 63 * mib)]), .file("loose", 200 * mib)
        ])
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/home/tester"))
        XCTAssertEqual(purposes.reclaimReason(atPath: index.rootPath), .regenerableCache)
        let found = try XCTUnwrap(SpaceMapInsights.worthALook(index: index, purposes: purposes))
        XCTAssertFalse(found.contains { $0.path == index.rootPath })
        XCTAssertEqual(found, [
            SpaceMapInsight(path: "/home/tester/.cache/compiler", bytes: 100 * mib, finding: .reclaimable(.regenerableCache)),
            SpaceMapInsight(path: "/home/tester/.cache/thumbnails", bytes: 64 * mib, finding: .reclaimable(.regenerableCache))
        ])
    }

    func testNonreclaimableAnalysisRootStillFindsEligibleNestedDirectories() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("project", [.directory("Caches", [.file("data", 100 * mib)])]),
            .directory("Documents", [.file("personal", 200 * mib)]),
            .directory("cache", [.file("data", 63 * mib)])
        ])
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis"))
        XCTAssertNil(purposes.reclaimReason(atPath: index.rootPath))
        let found = try findings(index)
        XCTAssertEqual(found, [
            SpaceMapInsight(path: "/analysis/project/Caches", bytes: 100 * mib, finding: .reclaimable(.regenerableCache))
        ])
    }

    func testCancellationBeforeAndDuringTraversalReturnsNil() throws {
        let index = SpaceMapMemoryIndex.make(children: (0..<2_050).map { .directory("unknown-\($0)", [.file("data", 1)]) })
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis"))
        XCTAssertNil(SpaceMapInsights.worthALook(index: index, purposes: purposes, isCancelled: { true }))
        var checks = 0
        let found = SpaceMapInsights.worthALook(index: index, purposes: purposes, minimumBytes: 1) {
            checks += 1
            return checks == 2
        }
        XCTAssertNil(found)
        XCTAssertEqual(checks, 2)
    }

    func testSyntheticTwoHundredThousandItemBenchmarkWithoutTimingAssertions() throws {
        // 2,000 directories + 198,000 files = exactly 200,000 indexed items.
        let nodes: [SpaceMapMemoryNode] = (0..<2_000).map { directory in
            .directory("project-\(directory)", (0..<99).map { .file("file-\($0)", 1_024 * 1_024) })
        }
        let index = SpaceMapMemoryIndex.make(children: nodes)
        XCTAssertEqual(index.directories[index.rootPath]?.descendantItemCount, 200_000)
        let scanner = DiskScanner(excludedPaths: [])
        let clock = ContinuousClock()
        var start = clock.now
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis"))
        let classifyTime = start.duration(to: clock.now)
        start = clock.now
        let root = try scanner.storageMapSnapshot(at: index.rootPath, using: index)
        let tiles = SpaceMapTreemapLayout.layout(rootPath: root.path, rootEntries: root.entries, in: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
                                               options: .init(), children: {
            (try? scanner.storageMapSnapshot(at: $0, using: index))?.entries ?? []
        })
        let layoutTime = start.duration(to: clock.now)
        start = clock.now
        let found = try XCTUnwrap(SpaceMapInsights.worthALook(index: index, purposes: purposes))
        let insightsTime = start.duration(to: clock.now)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(found.isEmpty)
        print("SpaceMap 200000-item Debug benchmark: classify=\(classifyTime), layout(including snapshots)=\(layoutTime), insights=\(insightsTime)")
    }

    private func findings(_ index: StorageMapAnalysisIndex, limit: Int = 6) throws -> [SpaceMapInsight] {
        let purposes = try XCTUnwrap(SpaceMapPurposeClassifier.classify(index: index, homePath: "/analysis"))
        return try XCTUnwrap(SpaceMapInsights.worthALook(index: index, purposes: purposes, limit: limit))
    }
}
