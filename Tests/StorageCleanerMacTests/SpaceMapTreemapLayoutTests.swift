import Foundation
import XCTest
@testable import StorageCleanerMac

final class SpaceMapTreemapLayoutTests: XCTestCase {
    private let area = CGRect(x: 10, y: 20, width: 600, height: 400)

    func testSquarifyFillsAreaWithoutOverlapOrCrossingBoundsAndPreservesInputOrder() {
        let values = [2.0, 6, 1, 6, 4, 3, 2]
        let frames = SpaceMapTreemapLayout.squarify(values, in: area)
        XCTAssertEqual(frames.count, values.count)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.width * $1.height }, area.width * area.height, accuracy: 0.99)
        for index in frames.indices {
            let frame = frames[index]
            XCTAssertTrue(area.contains(frame))
            XCTAssertEqual(frame.width * frame.height / (area.width * area.height),
                           values[index] / values.reduce(0, +), accuracy: 0.000_001)
            for other in frames.indices where other > index {
                let overlap = frame.intersection(frames[other])
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.000_001)
            }
        }
    }

    func testSquarifyAspectRatiosStayAtMostFour() {
        let frames = SpaceMapTreemapLayout.squarify([6, 6, 4, 3, 2, 2, 1], in: area)
        for frame in frames {
            XCTAssertLessThanOrEqual(max(frame.width / frame.height, frame.height / frame.width), 4)
        }
    }

    func testSquarifyHandlesDegenerateAndNonfiniteInput() {
        XCTAssertEqual(SpaceMapTreemapLayout.squarify([], in: area), [])
        XCTAssertEqual(SpaceMapTreemapLayout.squarify([0, 0, -1], in: area), [.zero, .zero, .zero])
        for rect in [CGRect.zero, CGRect(x: 0, y: 0, width: 0, height: 40),
                     CGRect(x: 0, y: 0, width: 40, height: 0), CGRect.null] {
            XCTAssertEqual(SpaceMapTreemapLayout.squarify([1, 2], in: rect), [.zero, .zero])
        }
        let frames = SpaceMapTreemapLayout.squarify([1, .nan, 0, -1, .infinity, 2], in: area)
        for index in [1, 2, 3, 4] { XCTAssertEqual(frames[index], .zero) }
        XCTAssertEqual(frames[5].width * frames[5].height / (frames[0].width * frames[0].height), 2, accuracy: 0.000_001)
    }

    func testFiniteValuesWhoseSumOverflowsStillFillTheArea() {
        let frames = SpaceMapTreemapLayout.squarify([Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude], in: area)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.width * $1.height }, 240_000, accuracy: 0.99)
        XCTAssertEqual(frames[0].width * frames[0].height, 120_000, accuracy: 0.99)
    }

    func testParentsPrecedeChildrenInDepthFirstOrderAndContainThem() {
        let big = entry("big", bytes: 150, directory: true)
        let inside = entry("big/inside", bytes: 100)
        let also = entry("big/also", bytes: 50)
        let small = entry("small", bytes: 10)
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: [big, small], in: area, options: .init(), children: { _ in [inside, also] })
        XCTAssertEqual(paths(tiles), [big.path, inside.path, also.path, small.path])
        XCTAssertEqual(tiles.map(\.depth), [0, 1, 1, 0])
        for child in tiles[1...2] { XCTAssertTrue(tiles[0].frame.contains(child.frame)) }
    }

    func testDepthOneAndDepthClamping() {
        XCTAssertEqual(SpaceMapTreemapLayout.Options().maxDepth, 3)
        XCTAssertEqual(SpaceMapTreemapLayout.Options(maxDepth: -10).maxDepth, 1)
        XCTAssertEqual(SpaceMapTreemapLayout.Options(maxDepth: 10).maxDepth, 6)
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: [entry("big", bytes: 100, directory: true)],
                                               in: area, options: .init(maxDepth: 1), children: { _ in
            XCTFail("Depth one must not request children")
            return []
        })
        XCTAssertEqual(tiles.count, 1)
        XCTAssertNil(tiles[0].header)
    }

    func testSubdividedDirectoriesKeepHeadersAboveEveryDescendant() throws {
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: [entry("big", bytes: 100, directory: true)],
                                               in: area, options: .init(), children: { path in
            path.hasSuffix("big") ? [self.entry("big/nested", bytes: 100, directory: true)]
                : [self.entry("big/nested/leaf", bytes: 100)]
        })
        XCTAssertEqual(tiles.count, 3)
        for (index, expectedHeight) in [(0, CGFloat(20)), (1, CGFloat(15))] {
            let tile = tiles[index]
            let header = try XCTUnwrap(tile.header)
            XCTAssertEqual(header.minY, tile.frame.minY)
            XCTAssertEqual(header.height, expectedHeight)
            XCTAssertEqual(header.width, tile.frame.width)
            for child in tiles.dropFirst(index + 1) {
                XCTAssertGreaterThanOrEqual(child.frame.minY, header.maxY)
            }
            XCTAssertEqual(SpaceMapTreemapLayout.hitTest(tiles, at: center(header)), tile)
        }
        XCTAssertNil(tiles.last?.header)
    }

    func testInsufficientHeaderSpaceKeepsDirectoryWhole() {
        let root = [entry("big", bytes: 100, directory: true)]
        for (rect, options) in [
            (area, SpaceMapTreemapLayout.Options(minimumTileSide: 150, headerHeight: 400)),
            (CGRect(x: 0, y: 0, width: 43, height: 400), .init(outerPadding: 0)),
            (CGRect(x: 0, y: 0, width: 100, height: 34), .init(outerPadding: 0))
        ] {
            let tiles = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: root, in: rect, options: options, children: { _ in
                XCTFail("A closed directory must not request children")
                return []
            })
            XCTAssertEqual(tiles.count, 1)
            XCTAssertNil(tiles.first?.header)
        }
    }

    func testFilesHaveNoHeaders() {
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: [entry("solo", bytes: 10)], in: area,
                                               options: .init(), children: { _ in XCTFail("File"); return [] })
        XCTAssertEqual(tiles.count, 1)
        XCTAssertNil(tiles[0].header)
    }

    func testDrawingADeepDirectoryPreservesAbsoluteIndexedPaths() {
        let entries = [entry("outer/inner/a", bytes: 10), entry("outer/inner/b", bytes: 5)]
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/analysis/outer/inner", rootEntries: entries, in: area, options: .init(), children: { _ in [] })
        XCTAssertEqual(paths(tiles), entries.map(\.path))
        XCTAssertTrue(paths(tiles).allSatisfy { $0.hasPrefix("/analysis/outer/inner/") })
        XCTAssertTrue(tiles.allSatisfy { $0.depth == 0 })
    }

    func testTailMergesIntoExactlyOneOthersTileWithItsParentAndBytes() throws {
        let entries = (0..<10).map { entry("f\($0)", bytes: Int64(10 - $0)) }
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/selected/current", rootEntries: entries, in: area,
                                               options: .init(maximumChildren: 4), children: { _ in [] })
        XCTAssertEqual(tiles.count, 5)
        let others = tiles.filter { if case .others = $0.kind { true } else { false } }
        XCTAssertEqual(others.count, 1)
        let tile = try XCTUnwrap(others.first)
        XCTAssertEqual(tile.kind, .others(parentPath: "/selected/current", count: 6, bytes: 21))
        XCTAssertNil(tile.header)
    }

    func testTailBytesSaturateWhenMergedIntoOthers() throws {
        let bytes = Int64.max / 2 + 1
        let entries = [entry("largest", bytes: .max), entry("a", bytes: bytes), entry("b", bytes: bytes)]
        let tiles = SpaceMapTreemapLayout.layout(
            rootPath: "/analysis", rootEntries: entries, in: area,
            options: .init(maximumChildren: 1), children: { _ in [] }
        )
        XCTAssertEqual(tiles.count, 2)
        let others = try XCTUnwrap(tiles.first { if case .others = $0.kind { true } else { false } })
        XCTAssertEqual(others.kind, .others(parentPath: "/analysis", count: 2, bytes: .max))
        XCTAssertEqual(paths(tiles), ["/analysis/largest"])
    }

    func testRemainderOnlyRootUsesTheNormalizedCallerPathForOthers() throws {
        let entries = [entry("measured", bytes: 100, role: .measuredRemainder),
                       entry("unmeasured", bytes: 50, role: .unmeasuredRemainder)]
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/selected/./previous/../current/", rootEntries: entries,
                                               in: area, options: .init(maximumChildren: 0), children: { _ in
            XCTFail("Remainder tiles must not request children")
            return []
        })
        XCTAssertEqual(tiles.count, 1)
        let tile = try XCTUnwrap(tiles.first)
        XCTAssertEqual(tile.kind, .others(parentPath: "/selected/current", count: 2, bytes: 150))
        XCTAssertEqual(tile.depth, 0)
        XCTAssertNil(tile.header)
    }

    func testNestedOthersUsesTheDirectoryPath() {
        let parent = entry("nested", bytes: 55, directory: true)
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: [parent], in: area,
                                               options: .init(maximumChildren: 4), children: { _ in
            (0..<10).map { self.entry("nested/f\($0)", bytes: Int64(10 - $0)) }
        })
        XCTAssertTrue(tiles.contains { $0.kind == .others(parentPath: parent.path, count: 6, bytes: 21) })
    }

    func testHitTestingFindsDeepestTileAndRejectsOutsidePoints() throws {
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: [entry("big", bytes: 100, directory: true)],
                                               in: area, options: .init(), children: { _ in [self.entry("big/leaf", bytes: 100)] })
        let leaf = try XCTUnwrap(tiles.last)
        XCTAssertEqual(SpaceMapTreemapLayout.hitTest(tiles, at: center(leaf.frame)), leaf)
        XCTAssertEqual(leaf.depth, 1)
        XCTAssertNil(SpaceMapTreemapLayout.hitTest(tiles, at: CGPoint(x: -50, y: -50)))
        XCTAssertNil(SpaceMapTreemapLayout.hitTest([], at: .zero))
    }

    func testFilteredLayoutUsesOnlyMatchedBytesAndShowsWholeMatchingSubtrees() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("src", [.file("big_test.rs", 300), .file("other.rs", 700)]),
            .file("unit_test.txt", 100), .file("huge.iso", 5_000)
        ])
        let scanner = DiskScanner(excludedPaths: [])
        let filter = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: "test"))
        let root = try scanner.storageMapSnapshot(at: "/analysis", using: index)
        let tiles = SpaceMapTreemapLayout.layout(rootPath: root.path, rootEntries: root.entries, in: area,
                                               options: .init(padding: 0, outerPadding: 0), children: {
            (try? scanner.storageMapSnapshot(at: $0, using: index))?.entries ?? []
        }, filter: filter)
        XCTAssertEqual(Set(paths(tiles)), ["/analysis/src", "/analysis/src/big_test.rs", "/analysis/unit_test.txt"])
        let src = try XCTUnwrap(tiles.first { paths([$0]) == ["/analysis/src"] })
        let unit = try XCTUnwrap(tiles.first { paths([$0]) == ["/analysis/unit_test.txt"] })
        XCTAssertEqual((src.frame.width * src.frame.height) / (unit.frame.width * unit.frame.height), 3, accuracy: 0.05)

        let whole = try XCTUnwrap(SpaceMapTreemapFilter.filter(index: index, basePath: "/analysis", keyword: "src"))
        let wholeTiles = SpaceMapTreemapLayout.layout(rootPath: root.path, rootEntries: root.entries, in: area, options: .init(), children: {
            (try? scanner.storageMapSnapshot(at: $0, using: index))?.entries ?? []
        }, filter: whole)
        XCTAssertEqual(Set(paths(wholeTiles)), ["/analysis/src", "/analysis/src/big_test.rs", "/analysis/src/other.rs"])
    }

    func testBlockedCloudPackageAndRemainderTilesNeverSubdivide() {
        let entries = [
            entry("blocked", bytes: 100, directory: true, canDescend: false),
            entry("package", bytes: 100, directory: true, kind: "package"),
            entry("cloud", bytes: 100, directory: true, cloud: true),
            entry("measured", bytes: 100, directory: true, role: .measuredRemainder),
            entry("unmeasured", bytes: 100, directory: true, role: .unmeasuredRemainder)
        ]
        let tiles = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: entries, in: area, options: .init(), children: { _ in
            XCTFail("Terminal tiles must not request children")
            return []
        })
        XCTAssertEqual(tiles.count, entries.count)
        XCTAssertTrue(tiles.allSatisfy { $0.header == nil && $0.depth == 0 })
    }

    func testEqualSizeOrderingAndRepeatedLayoutsAreDeterministic() {
        let entries = ["z", "a", "m"].map { entry($0, bytes: 10) }
        let first = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: entries, in: area, options: .init(), children: { _ in [] })
        let second = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: entries, in: area, options: .init(), children: { _ in [] })
        XCTAssertEqual(first, second)
        XCTAssertEqual(paths(first), entries.map(\.path))
    }

    func testTinyInsetsAndEmptyChildrenDoNotProducePhantomTilesOrHeaders() {
        let entry = entry("empty", bytes: 10, directory: true)
        let tiny = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: [entry], in: CGRect(x: 0, y: 0, width: 10, height: 10),
                                              options: .init(), children: { _ in [] })
        XCTAssertTrue(tiny.isEmpty)
        let empty = SpaceMapTreemapLayout.layout(rootPath: "/analysis", rootEntries: [entry], in: area, options: .init(), children: { _ in [] })
        XCTAssertEqual(empty.count, 1)
        XCTAssertNil(empty[0].header)
    }

    private func entry(_ relativePath: String, bytes: Int64, directory: Bool = false,
                       canDescend: Bool? = nil, kind: String = "file",
                       role: StorageTreemapEntryRole = .content, cloud: Bool = false) -> StorageTreemapEntry {
        let path = "/analysis/" + relativePath
        return StorageTreemapEntry(id: path, title: (relativePath as NSString).lastPathComponent,
                                   path: path, sizeBytes: bytes, kind: kind, isDirectory: directory,
                                   canDescend: canDescend, role: role, isCloudOnly: cloud)
    }

    private func paths(_ tiles: [SpaceMapTreemapLayout.Tile]) -> [String] {
        tiles.compactMap { if case let .entry(entry) = $0.kind { entry.path } else { nil } }
    }

    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}
