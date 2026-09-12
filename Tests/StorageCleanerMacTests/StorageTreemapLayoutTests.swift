import CoreGraphics
import Foundation
import XCTest
@testable import StorageCleanerMac

final class StorageTreemapLayoutTests: XCTestCase {
    func testSunburstHitTestingMatchesAngularAndRadialGeometry() throws {
        let entries = [75, 25].enumerated().map { index, bytes in
            StorageTreemapEntry(id: "\(index)", title: "\(index)", path: "/\(index)", sizeBytes: Int64(bytes), kind: "file", isDirectory: false)
        }
        let segments = StorageSunburstLayout.segments(entries: entries) { _ in [] }
        let center = CGPoint(x: 200, y: 150)
        func hit(_ x: Double, _ y: Double) -> String? {
            StorageSunburstLayout.segment(at: CGPoint(x: center.x + x, y: center.y + y), center: center, radius: 100, in: segments)?.entry.id
        }
        XCTAssertEqual(hit(40, 0), "0")
        XCTAssertEqual(hit(-30, -20), "1")
        XCTAssertNil(hit(0, 0))
        XCTAssertNil(hit(60, 0))
        XCTAssertNil(hit(40, .nan))
        XCTAssertNil(StorageSunburstLayout.segment(at: center, center: center, radius: 0, in: segments))
        let first = try XCTUnwrap(segments.first)
        let child = StorageSunburstLayout.Segment(entry: entries[0], depth: 1, start: first.start, end: first.end, share: first.share)
        XCTAssertFalse(first.contains(CGPoint(x: 260, y: 150), center: center, radius: 100))
        XCTAssertTrue(child.contains(CGPoint(x: 260, y: 150), center: center, radius: 100))
    }

    func testIndexedDirectoryKeepsAllRowsBeyondLegacyDisplayCaps() throws {
        let children = (0..<600).map { index in
            StorageMapIndexedEntry(name: "file-\(index)", kind: "file", sizeBytes: 1, isDirectory: false, canDescend: false, isEstimated: false)
        }
        let index = StorageMapAnalysisIndex(
            rootPath: "/tmp", rootVolumeIdentifier: nil,
            directories: ["/tmp": StorageMapDirectoryAggregate(sizeBytes: 600, immediateChildCount: 600, descendantItemCount: 600, isComplete: true)],
            childrenByDirectory: ["/tmp": children], blockedDirectoryPaths: [], duplicateFilePaths: []
        )
        let scanner = DiskScanner(excludedPaths: [])
        let snapshot = try scanner.storageMapSnapshot(at: "/tmp", using: index)
        XCTAssertEqual(StorageTreemapPresentation.visibleEntries(from: snapshot).count, 600)
        XCTAssertEqual(StorageTreemapPresentation.filteredEntries(from: snapshot.entries).count, 600)
        XCTAssertEqual(snapshot.omittedEntryCount, 0)
        XCTAssertEqual(try scanner.storageMapSnapshot(at: "/tmp", using: index, limit: 20).entries.count, 20)
        XCTAssertEqual(StorageTreemapPresentation.mapLayoutEntries(from: snapshot.entries, measuredBytes: 600, referenceBytes: 600, limit: 30).reduce(0) { $0 + $1.sizeBytes }, 600)
    }

    func testDirectoryListSearchAndTypeFiltersKeepZeroBytesAndSnapshotIntact() {
        let entries = [
            StorageTreemapEntry(id: "folder", title: "Projects", path: "/root/Projects", sizeBytes: 100, kind: "folder", isDirectory: true),
            StorageTreemapEntry(id: "file", title: "Report.PDF", path: "/root/Documents/Report.PDF", sizeBytes: 20, kind: "pdf", isDirectory: false),
            StorageTreemapEntry(id: "zero", title: "Empty.txt", path: "/root/Empty.txt", sizeBytes: 0, kind: "txt", isDirectory: false),
        ]
        let snapshot = StorageMapDirectorySnapshot(
            path: "/root", title: "Root", entries: entries,
            measuredBytes: 120, referenceBytes: 150, inspectedItemCount: 3,
            omittedEntryCount: 0, isComplete: false
        )
        let original = snapshot
        XCTAssertEqual(StorageTreemapPresentation.filteredEntries(from: snapshot.entries, query: "  report.pdf  ").map(\.id), ["file"])
        XCTAssertEqual(StorageTreemapPresentation.filteredEntries(from: snapshot.entries, query: "DOCUMENTS").map(\.id), ["file"])
        XCTAssertTrue(StorageTreemapPresentation.filteredEntries(from: snapshot.entries, query: "absent").isEmpty)
        XCTAssertEqual(StorageTreemapPresentation.filteredEntries(from: snapshot.entries, filter: .directories).map(\.id), ["folder"])
        XCTAssertEqual(StorageTreemapPresentation.filteredEntries(from: snapshot.entries, filter: .files).map(\.id), ["file", "zero"])
        XCTAssertEqual(StorageTreemapPresentation.filteredEntries(from: snapshot.entries, sort: .sizeAscending).first?.sizeBytes, 0)
        XCTAssertEqual(snapshot, original)
        XCTAssertEqual(StorageTreemapPresentation.mapLayoutEntries(
            from: snapshot.entries, measuredBytes: snapshot.measuredBytes,
            referenceBytes: snapshot.referenceBytes
        ).reduce(0) { $0 + $1.sizeBytes }, 150)
    }

    func testDirectoryListSortUsesNaturalNamesAndStablePathTies() {
        let entries = [
            StorageTreemapEntry(id: "b", title: "Report", path: "/b/Report", sizeBytes: 20, kind: "file", isDirectory: false),
            StorageTreemapEntry(id: "10", title: "File10", path: "/File10", sizeBytes: 5, kind: "file", isDirectory: false),
            StorageTreemapEntry(id: "a", title: "Report", path: "/a/Report", sizeBytes: 20, kind: "file", isDirectory: false),
            StorageTreemapEntry(id: "2", title: "File2", path: "/File2", sizeBytes: 40, kind: "file", isDirectory: false),
        ]
        XCTAssertEqual(StorageTreemapPresentation.filteredEntries(from: entries, sort: .sizeDescending).map(\.id), ["2", "a", "b", "10"])
        XCTAssertEqual(StorageTreemapPresentation.filteredEntries(from: entries, sort: .sizeAscending).map(\.id), ["10", "a", "b", "2"])
        XCTAssertEqual(StorageTreemapPresentation.filteredEntries(from: entries, sort: .nameAscending).map(\.id), ["2", "10", "a", "b"])
        for sort in StorageMapEntrySort.allCases {
            XCTAssertEqual(
                StorageTreemapPresentation.filteredEntries(from: entries, sort: sort),
                StorageTreemapPresentation.filteredEntries(from: Array(entries.reversed()), sort: sort)
            )
        }
    }

    func testNavigationLevelResolvesAncestorSelectionAndKeepsDeepSectorFallback() {
        func folder(_ path: String) -> StorageTreemapEntry {
            StorageTreemapEntry(id: path, title: URL(fileURLWithPath: path).lastPathComponent,
                path: path, sizeBytes: 10, kind: "folder", isDirectory: true)
        }
        func snapshot(_ path: String, _ entries: [StorageTreemapEntry]) -> StorageMapDirectorySnapshot {
            StorageMapDirectorySnapshot(path: path, title: path, entries: entries,
                measuredBytes: 30, inspectedItemCount: entries.count,
                omittedEntryCount: 0, isComplete: true)
        }
        let sibling = folder("/B")
        let currentChild = folder("/A/Child/Leaf")
        let deeperSector = folder("/A/Child/Leaf/Deeper")
        let navigation = [
            snapshot("/", [folder("/A"), sibling]),
            snapshot("/A", [folder("/A/Child")]),
            snapshot("/A/Child", [currentChild]),
        ]
        XCTAssertEqual(StorageTreemapPresentation.navigationLevel(for: sibling, in: navigation, fallback: 2), 0)
        XCTAssertEqual(StorageTreemapPresentation.navigationLevel(for: currentChild, in: navigation, fallback: 2), 2)
        XCTAssertEqual(StorageTreemapPresentation.navigationLevel(for: deeperSector, in: navigation, fallback: 2), 2)
        let unmatchedPath = StorageTreemapEntry(id: sibling.id, title: "Other", path: "/Other",
            sizeBytes: 10, kind: "folder", isDirectory: true)
        XCTAssertEqual(StorageTreemapPresentation.navigationLevel(for: unmatchedPath, in: navigation, fallback: 2), 2)
    }

    func testSunburstUsesBytesAndKeepsChildrenWithinTheirParent() throws {
        func entry(_ id: String, _ bytes: Int64, directory: Bool = false) -> StorageTreemapEntry {
            StorageTreemapEntry(id: id, title: id, path: "/" + id, sizeBytes: bytes, kind: directory ? "folder" : "file", isDirectory: directory)
        }
        let segments = StorageSunburstLayout.segments(entries: [entry("a", 75, directory: true), entry("b", 25), entry("zero", 0)]) { _ in
            [entry("a/one", 50), entry("a/two", 25)]
        }
        XCTAssertEqual(segments.count, 4)
        let parent = try XCTUnwrap(segments.first { $0.entry.id == "a" })
        XCTAssertEqual(parent.end - parent.start, 1.5 * .pi, accuracy: 0.000001)
        let children = segments.filter { $0.depth == 1 }
        XCTAssertEqual(children.map(\.share), [0.5, 0.25])
        XCTAssertEqual(children.first?.start, parent.start)
        XCTAssertEqual(children.last?.end, parent.end)
        XCTAssertTrue(children.allSatisfy { $0.start >= parent.start && $0.end <= parent.end })
        XCTAssertTrue(StorageSunburstLayout.segments(entries: [entry("empty", 0)]) { _ in [] }.isEmpty)
    }

    func testInternalStorageMapUsesLogicalMacintoshHDViewWithoutDataMirror() throws {
        let target = try XCTUnwrap(
            DiskScanner.storageMapScanTargets().first { $0.kind == .internalVolume }
        )

        XCTAssertEqual(target.path, "/")
        XCTAssertTrue(DiskScanner.shouldSkipLogicalDataMirror(
            path: "/System/Volumes/Data",
            rootPath: target.path,
            targetKind: target.kind
        ))
        XCTAssertTrue(DiskScanner.shouldSkipLogicalDataMirror(
            path: "/System/Volumes/Data/Applications",
            rootPath: target.path,
            targetKind: target.kind
        ))
        XCTAssertFalse(DiskScanner.shouldSkipLogicalDataMirror(
            path: "/Applications",
            rootPath: target.path,
            targetKind: target.kind
        ))
        XCTAssertTrue(DiskScanner.storageMapPath("/Applications", isWithinRoot: "/"))
        XCTAssertTrue(DiskScanner.storageMapPath("/tmp/project", isWithinRoot: "/tmp"))
        XCTAssertFalse(DiskScanner.storageMapPath("/tmp-other", isWithinRoot: "/tmp"))
        XCTAssertEqual(
            DiskScanner.storageMapLogicalPath("/private/var/../tmp/cache"),
            "/private/tmp/cache"
        )
        XCTAssertEqual(
            DiskScanner.storageMapParentPath("/private/var/db"),
            "/private/var"
        )

        var pathsByLevel = ["/"]
        XCTAssertEqual(DiskScanner.storageMapEnumeratedPath(
            itemName: "private",
            level: 1,
            rootPath: "/",
            pathsByLevel: &pathsByLevel
        ), "/private")
        XCTAssertEqual(DiskScanner.storageMapEnumeratedPath(
            itemName: "var",
            level: 2,
            rootPath: "/",
            pathsByLevel: &pathsByLevel
        ), "/private/var")
        XCTAssertEqual(DiskScanner.storageMapEnumeratedPath(
            itemName: "Users",
            level: 1,
            rootPath: "/",
            pathsByLevel: &pathsByLevel
        ), "/Users")
    }

    func testStorageMapUsesLogicalSizeOnlyInsideApplicationBundles() {
        let logicalSize = 8_000_000
        let allocatedSize = 4_096

        XCTAssertEqual(
            DiskScanner.storageMapPreferredSize(
                logicalSize: logicalSize,
                allocatedSize: allocatedSize,
                path: "/Applications/Example.app/Contents/MacOS/Example"
            ),
            logicalSize
        )
        XCTAssertEqual(
            DiskScanner.storageMapPreferredSize(
                logicalSize: logicalSize,
                allocatedSize: allocatedSize,
                path: "/Users/test/Library/Mobile Documents/sparse.data"
            ),
            allocatedSize
        )
    }

    func testStorageMapSnapshotKeepsPrivateFirmlinkHierarchyDrillable() throws {
        let aggregate = StorageMapDirectoryAggregate(
            sizeBytes: 42,
            immediateChildCount: 1,
            descendantItemCount: 2,
            isComplete: true
        )
        let leaf = StorageMapDirectoryAggregate(
            sizeBytes: 42,
            immediateChildCount: 0,
            descendantItemCount: 1,
            isComplete: true
        )
        let index = StorageMapAnalysisIndex(
            rootPath: "/",
            rootVolumeIdentifier: nil,
            directories: [
                "/": aggregate,
                "/private": aggregate,
                "/private/var": leaf,
            ],
            childrenByDirectory: [
                "/": [StorageMapIndexedEntry(
                    name: "private",
                    kind: "folder",
                    sizeBytes: nil,
                    isDirectory: true,
                    canDescend: true,
                    isEstimated: false
                )],
                "/private": [StorageMapIndexedEntry(
                    name: "var",
                    kind: "folder",
                    sizeBytes: nil,
                    isDirectory: true,
                    canDescend: true,
                    isEstimated: false
                )],
                "/private/var": [StorageMapIndexedEntry(
                    name: "db.sqlite",
                    kind: "sqlite",
                    sizeBytes: 42,
                    isDirectory: false,
                    canDescend: false,
                    isEstimated: false
                )],
            ],
            blockedDirectoryPaths: [],
            duplicateFilePaths: []
        )

        let scanner = DiskScanner(excludedPaths: [])
        let privateSnapshot = try scanner.storageMapSnapshot(at: "/private", using: index)
        XCTAssertEqual(privateSnapshot.entries.first?.path, "/private/var")
        XCTAssertTrue(privateSnapshot.entries.first?.canDescend == true)

        let varSnapshot = try scanner.storageMapSnapshot(at: "/private/var", using: index)
        XCTAssertEqual(varSnapshot.entries.first?.path, "/private/var/db.sqlite")
    }

    func testContentCategoryClassificationIsStableAndSemantic() {
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "Portrait.HEIC", kind: "heic", isDirectory: false),
            .image
        )
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "Movie.mov", kind: "mov", isDirectory: false),
            .video
        )
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "StorageCleaner.app", kind: "package", isDirectory: true),
            .application
        )
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "Photos Library.photoslibrary", kind: "package", isDirectory: true),
            .image
        )
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "Workspace.xcworkspace", kind: "package", isDirectory: true),
            .developer
        )
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "main.swift", kind: "swift", isDirectory: false),
            .developer
        )
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "CMakeLists.txt", kind: "txt", isDirectory: false),
            .developer
        )
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "records.sqlite", kind: "sqlite", isDirectory: false),
            .data
        )
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "backup.zip", kind: "zip", isDirectory: false),
            .archive
        )
        XCTAssertEqual(
            StorageMapContentCategory.classify(name: "PHOTO.heic", kind: "file", isDirectory: false),
            .image,
            "Classification must not depend on filename casing or the item's list position"
        )
    }

    func testDirectoryColorCategoryComesFromItsDominantDescendantBytes() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("storage-map-category-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let media = root.appendingPathComponent("Media", isDirectory: true)
        let nested = media.appendingPathComponent("Nested", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(repeating: 0xA1, count: 64 * 1_024)
            .write(to: nested.appendingPathComponent("photo.jpg"))
        try Data(repeating: 0xB2, count: 4 * 1_024)
            .write(to: media.appendingPathComponent("notes.pdf"))
        try Data(repeating: 0xC3, count: 48 * 1_024)
            .write(to: project.appendingPathComponent("main.swift"))
        try Data(repeating: 0xD4, count: 4 * 1_024)
            .write(to: project.appendingPathComponent("fixtures.json"))

        let result = try DiskScanner(excludedPaths: []).storageMapAnalysis(
            target: StorageMapScanTarget(
                path: root.path,
                title: "Category Fixture",
                kind: .homeDirectory
            )
        )

        let mediaEntry = try XCTUnwrap(result.rootSnapshot.entries.first { $0.title == "Media" })
        let projectEntry = try XCTUnwrap(result.rootSnapshot.entries.first { $0.title == "Project" })
        XCTAssertEqual(mediaEntry.contentCategory, .image)
        XCTAssertEqual(projectEntry.contentCategory, .developer)
        XCTAssertEqual(
            result.index.directories[PathSafety.lexicalPath(media.path)]?.dominantContentCategory,
            .image
        )

        let nestedSnapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(
            at: nested.path,
            using: result.index
        )
        XCTAssertEqual(nestedSnapshot.entries.first?.contentCategory, .image)
    }

    func testFramesStayInsideBoundsAndNeverOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 320)
        let frames = StorageTreemapLayoutEngine.frames(
            weights: [90, 50, 30, 18, 12, 8, 5],
            in: bounds,
            spacing: 0
        )

        XCTAssertEqual(frames.count, 7)
        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(bounds.contains(frame))
        }

        for leftIndex in frames.indices {
            for rightIndex in frames.indices where rightIndex > leftIndex {
                let intersection = frames[leftIndex].intersection(frames[rightIndex])
                XCTAssertLessThanOrEqual(intersection.width * intersection.height, 0.000_001)
            }
        }
    }

    func testWorkspaceLayoutKeepsTheListReadableAndGivesFullscreenSpaceToTheMap() {
        XCTAssertFalse(StorageMapWorkspaceLayout.showsEntryList(availableWidth: 719))
        XCTAssertTrue(StorageMapWorkspaceLayout.showsEntryList(availableWidth: 720))
        XCTAssertEqual(
            StorageMapWorkspaceLayout.entryListWidth(availableWidth: 720),
            StorageMapWorkspaceLayout.minimumEntryListWidth
        )
        XCTAssertEqual(
            StorageMapWorkspaceLayout.entryListWidth(availableWidth: 1_000),
            340,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StorageMapWorkspaceLayout.entryListWidth(availableWidth: 2_000),
            StorageMapWorkspaceLayout.maximumEntryListWidth
        )
        XCTAssertEqual(StorageMapWorkspaceLayout.columnWidth, 304)
    }

    func testAreaRemainsProportionalToWeightsWithoutSpacing() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 400)
        let weights = [6.0, 3.0, 1.0]
        let frames = StorageTreemapLayoutEngine.frames(weights: weights, in: bounds, spacing: 0)
        let totalArea = bounds.width * bounds.height

        for index in weights.indices {
            let area = frames[index].width * frames[index].height
            XCTAssertEqual(area / totalArea, weights[index] / 10, accuracy: 0.000_001)
        }
    }

    func testObservedFolderWeightsPreserveTheKnownParentRemainder() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 600)
        let weights: [Int64] = [
            149_900_000, 88_200_000, 61_100_000, 24_800_000, 8_500_000,
            6_600_000, 4_700_000, 3_300_000, 2_000_000, 1_800_000,
        ]
        let entries = weights.enumerated().map { index, weight in
            StorageTreemapEntry(
                id: "folder-\(index)",
                title: "Folder \(index)",
                path: "/tmp/folder-\(index)",
                sizeBytes: weight,
                kind: "folder",
                isDirectory: true,
                isEstimated: true
            )
        }
        let measuredBytes: Int64 = 358_100_000
        let referenceBytes: Int64 = 3_800_000_000
        let layoutEntries = StorageTreemapPresentation.mapLayoutEntries(
            from: entries,
            measuredBytes: measuredBytes,
            referenceBytes: referenceBytes
        )
        let frames = StorageTreemapLayoutEngine.frames(
            weights: layoutEntries.map { Double($0.sizeBytes) },
            in: bounds,
            spacing: 0
        )
        let totalArea = bounds.width * bounds.height
        let expectedShare = Double(weights[0]) / Double(referenceBytes)
        let renderedShare = (frames[0].width * frames[0].height) / totalArea

        XCTAssertEqual(renderedShare, expectedShare, accuracy: 0.000_001)
        XCTAssertLessThan(renderedShare, 0.05, "A partial child scan must not inflate a folder to its share of only the measured subtotal")
        XCTAssertEqual(layoutEntries.last?.role, .unmeasuredRemainder)
        XCTAssertEqual(layoutEntries.last?.sizeBytes, referenceBytes - measuredBytes)
        let unmeasuredArea = (frames.last?.width ?? 0) * (frames.last?.height ?? 0)
        XCTAssertEqual(
            unmeasuredArea / totalArea,
            Double(referenceBytes - measuredBytes) / Double(referenceBytes),
            accuracy: 0.000_001
        )
    }

    func testPresentationKeepsLargestPositiveItemsInStableOrder() {
        let items = [
            makeItem(title: "B", bytes: 20),
            makeItem(title: "A", bytes: 20),
            makeItem(title: "Small", bytes: 2),
            makeItem(title: "Zero", bytes: 0),
            makeItem(title: "Largest", bytes: 40),
        ]

        let entries = StorageTreemapPresentation.entries(from: items, limit: 3)

        XCTAssertEqual(entries.map(\.title), ["Largest", "A", "B"])
        XCTAssertEqual(entries.map(\.sizeBytes), [40, 20, 20])
    }

    func testPresentationPreservesDirectoryNavigationIdentity() {
        let folder = makeItem(title: "Projects", bytes: 40, isDirectory: true)

        let entry = StorageTreemapPresentation.entries(from: [folder]).first

        XCTAssertEqual(entry?.path, folder.path)
        XCTAssertEqual(entry?.isDirectory, true)
        XCTAssertEqual(entry?.isEstimated, false)
    }

    func testDiskScannerBuildsOneLevelSnapshotWithoutFollowingSymlinks() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("storage-map-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8_192)
            .write(to: folder.appendingPathComponent("child.bin"))
        try Data(repeating: 0x2C, count: 4_096)
            .write(to: root.appendingPathComponent("note.dat"))

        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(
            at: root.path,
            maxScanSeconds: 2
        )

        XCTAssertEqual(snapshot.title, root.lastPathComponent)
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(Set(snapshot.entries.map(\.title)), ["Folder", "note.dat"])
        XCTAssertEqual(snapshot.entries.first { $0.title == "Folder" }?.isDirectory, true)
        XCTAssertEqual(snapshot.entries.first { $0.title == "Folder" }?.childCount, 1)
        XCTAssertGreaterThan(snapshot.measuredBytes, 0)

        let link = root.appendingPathComponent("Folder Link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: folder)
        let withLink = try DiskScanner(excludedPaths: []).storageMapSnapshot(
            at: root.path,
            maxScanSeconds: 2
        )
        XCTAssertFalse(withLink.entries.contains { $0.title == "Folder Link" })
        XCTAssertFalse(withLink.isComplete)
        XCTAssertTrue(withLink.entries.allSatisfy(\.isEstimated))
    }

    func testStorageMapAnalysisBuildsReusableExactDirectoryIndex() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("storage-map-index-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let archive = projects.appendingPathComponent("Archive", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 8_192)
            .write(to: archive.appendingPathComponent("old.bin"))
        try Data(repeating: 0x22, count: 4_096)
            .write(to: downloads.appendingPathComponent("new.bin"))
        try Data(repeating: 0x33, count: 2_048)
            .write(to: root.appendingPathComponent("note.dat"))

        let target = StorageMapScanTarget(
            path: root.path,
            title: "Fixture Disk",
            kind: .homeDirectory
        )
        let result = try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target)

        XCTAssertTrue(result.rootSnapshot.isComplete)
        XCTAssertEqual(result.rootSnapshot.title, target.title)
        XCTAssertEqual(result.rootSnapshot.unmeasuredBytes, 0)
        XCTAssertGreaterThan(result.rootSnapshot.measuredBytes, 0)
        XCTAssertEqual(
            result.rootSnapshot.measuredBytes,
            result.index.directories[result.index.rootPath]?.sizeBytes
        )
        XCTAssertEqual(
            result.rootSnapshot.entries.first { $0.title == "Projects" }?.sizeBytes,
            result.index.directories[PathSafety.lexicalPath(projects.path)]?.sizeBytes
        )

        let projectsSnapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(
            at: projects.path,
            using: result.index
        )
        XCTAssertTrue(projectsSnapshot.isComplete)
        XCTAssertEqual(projectsSnapshot.unmeasuredBytes, 0)
        XCTAssertEqual(projectsSnapshot.entries.map(\.title), ["Archive"])
        XCTAssertEqual(
            projectsSnapshot.entries.first?.sizeBytes,
            result.index.directories[PathSafety.lexicalPath(archive.path)]?.sizeBytes
        )
    }

    func testStorageMapAnalysisAssignsHardLinkBytesToStableCanonicalPathOnce() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("storage-map-hardlink-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let alpha = root.appendingPathComponent("A", isDirectory: true)
        let beta = root.appendingPathComponent("B", isDirectory: true)
        try fileManager.createDirectory(at: alpha, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: beta, withIntermediateDirectories: true)
        let original = beta.appendingPathComponent("original.bin")
        let link = alpha.appendingPathComponent("link.bin")
        try Data(repeating: 0x7D, count: 16_384).write(to: original)
        try fileManager.linkItem(at: original, to: link)

        let result = try DiskScanner(excludedPaths: []).storageMapAnalysis(
            target: StorageMapScanTarget(
                path: root.path,
                title: "Hard Link Fixture",
                kind: .homeDirectory
            )
        )
        let alphaBytes = result.rootSnapshot.entries.first { $0.title == "A" }?.sizeBytes ?? -1
        let betaBytes = result.rootSnapshot.entries.first { $0.title == "B" }?.sizeBytes ?? -1

        XCTAssertGreaterThan(alphaBytes, 0)
        XCTAssertEqual(betaBytes, 0)
        XCTAssertEqual(result.rootSnapshot.measuredBytes, alphaBytes + betaBytes)
        XCTAssertTrue(result.index.duplicateFilePaths.contains(PathSafety.lexicalPath(original.path)))
    }

    @MainActor
    func testLargeFilesStoreDrillsDownAndReusesCachedDirectorySnapshot() async {
        let calls = StorageMapBrowseCallCounter()
        let nestedEntry = StorageTreemapEntry(
            id: "/tmp/Projects/Build", title: "Build", path: "/tmp/Projects/Build", sizeBytes: 42, kind: "folder", isDirectory: true
        )
        let nestedSnapshot = StorageMapDirectorySnapshot(
            path: nestedEntry.path, title: nestedEntry.title, entries: [], measuredBytes: 42,
            inspectedItemCount: 0, omittedEntryCount: 0, isComplete: true
        )
        let entry = StorageTreemapEntry(
            id: "/tmp/Projects",
            title: "Projects",
            path: "/tmp/Projects",
            sizeBytes: 42,
            kind: "folder",
            isDirectory: true
        )
        let snapshot = StorageMapDirectorySnapshot(
            path: entry.path,
            title: entry.title,
            entries: [],
            measuredBytes: 0,
            referenceBytes: entry.sizeBytes,
            referenceIsEstimated: false,
            inspectedItemCount: 0,
            omittedEntryCount: 0,
            isComplete: true
        )
        let rootSnapshot = StorageMapDirectorySnapshot(
            path: "/tmp",
            title: "tmp",
            entries: [entry],
            measuredBytes: entry.sizeBytes,
            inspectedItemCount: 1,
            omittedEntryCount: 0,
            isComplete: true
        )
        let analysis = StorageMapAnalysisResult(
            target: StorageMapScanTarget(
                path: "/tmp",
                title: "tmp",
                kind: .homeDirectory
            ),
            volumeTotalBytes: 100,
            volumeAvailableBytes: 58,
            inspectedItemCount: 1,
            omittedItemCount: 0,
            scanSeconds: 0.1,
            index: StorageMapAnalysisIndex(
                rootPath: "/tmp",
                rootVolumeIdentifier: nil,
                directories: [
                    "/tmp": StorageMapDirectoryAggregate(
                        sizeBytes: 42,
                        immediateChildCount: 1,
                        descendantItemCount: 1,
                        isComplete: true
                    ),
                    entry.path: StorageMapDirectoryAggregate(
                        sizeBytes: 42,
                        immediateChildCount: 1,
                        descendantItemCount: 1,
                        isComplete: true
                    ),
                    nestedEntry.path: StorageMapDirectoryAggregate(sizeBytes: 42, immediateChildCount: 0, descendantItemCount: 0, isComplete: true),
                ],
                childrenByDirectory: [
                    "/tmp": [
                        StorageMapIndexedEntry(
                            name: "Projects",
                            kind: "folder",
                            sizeBytes: nil,
                            isDirectory: true,
                            canDescend: true,
                            isEstimated: false
                        )
                    ],
                    entry.path: [StorageMapIndexedEntry(name: "Build", kind: "folder", sizeBytes: nil, isDirectory: true, canDescend: true, isEstimated: false)],
                    nestedEntry.path: [],
                ],
                blockedDirectoryPaths: [],
                duplicateFilePaths: []
            ),
            rootSnapshot: rootSnapshot
        )
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let suite = "storage-map-store-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LargeFilesStore(
            coordinator: coordinator,
            activityStore: activity,
            defaults: defaults,
            scanOperation: { _ in [] },
            directoryBrowseOperation: { path, _ in
                await calls.record(path)
                return path == nestedEntry.path ? nestedSnapshot : snapshot
            }
        )

        store.replaceStorageAnalysisForTesting(analysis)
        store.openStorageMapDirectory(entry, fromLevel: 0)
        for _ in 0..<100 where store.storageMapBrowsePhase.isLoading {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.storageMapNavigation, [rootSnapshot, snapshot])
        XCTAssertEqual(store.currentStorageMapSnapshot?.referenceBytes, entry.sizeBytes)
        let firstCallCount = await calls.count
        XCTAssertEqual(firstCallCount, 1)

        store.showPreviousStorageMapLevel()
        XCTAssertEqual(store.storageMapNavigation, [rootSnapshot])
        XCTAssertEqual(store.storageMapForwardNavigation, [snapshot])
        store.showNextStorageMapLevel()
        XCTAssertEqual(store.storageMapNavigation, [rootSnapshot, snapshot])
        store.showPreviousStorageMapLevel()
        store.openStorageMapDirectory(entry, fromLevel: 0)

        XCTAssertEqual(store.storageMapNavigation, [rootSnapshot, snapshot])
        let cachedCallCount = await calls.count
        XCTAssertEqual(cachedCallCount, 1)

        store.showStorageMapRoot()
        store.openStorageMapDirectory(nestedEntry, fromLevel: 0)
        for _ in 0..<100 where store.storageMapBrowsePhase.isLoading {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.storageMapNavigation.map(\.path), [rootSnapshot.path, entry.path, nestedEntry.path])
        let deepCallCount = await calls.count
        XCTAssertEqual(deepCallCount, 2, "Intermediate parents must come from the index, without an extra browse")
        store.showPreviousStorageMapLevel()
        XCTAssertEqual(store.currentStorageMapSnapshot?.path, entry.path)
        XCTAssertEqual(store.currentStorageMapSnapshot?.entries.map(\.id), [nestedEntry.id])
    }

    func testMapLayoutSeparatesMeasuredOverflowFromUnmeasuredSpace() {
        let entries = (0..<4).map { index in
            StorageTreemapEntry(
                id: "item-\(index)",
                title: "Item \(index)",
                path: "/tmp/item-\(index)",
                sizeBytes: Int64((4 - index) * 10),
                kind: "file",
                isDirectory: false
            )
        }

        let layoutEntries = StorageTreemapPresentation.mapLayoutEntries(
            from: entries,
            measuredBytes: 100,
            referenceBytes: 160,
            limit: 2
        )

        XCTAssertEqual(layoutEntries.map(\.role), [
            .content,
            .content,
            .measuredRemainder,
            .unmeasuredRemainder,
        ])
        XCTAssertEqual(layoutEntries.map(\.sizeBytes), [40, 30, 30, 60])
        XCTAssertEqual(layoutEntries.reduce(0) { $0 + $1.sizeBytes }, 160)
    }

    func testEstimatedSizeLabelClearlyReportsLowerBound() {
        let entry = StorageTreemapEntry(
            id: "estimated",
            title: "Estimated",
            path: "/tmp/estimated",
            sizeBytes: 1_024,
            kind: "folder",
            isDirectory: true,
            isEstimated: true
        )

        XCTAssertTrue(StorageTreemapPresentation.displaySize(for: entry).contains(L10n.text("至少", "At least")))
    }

    func testStorageMapFairlyMeasuresMoreThanTheFirstDirectory() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("storage-map-fairness-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let first = root.appendingPathComponent("A-heavy", isDirectory: true)
        let second = root.appendingPathComponent("B-small", isDirectory: true)
        try fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: second, withIntermediateDirectories: true)
        for index in 0..<2_000 {
            try Data(repeating: 0x4A, count: 128)
                .write(to: first.appendingPathComponent("item-\(index).bin"))
        }
        try Data(repeating: 0x7B, count: 4_096)
            .write(to: second.appendingPathComponent("important.bin"))

        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(
            at: root.path,
            maxScanSeconds: 0.5
        )

        XCTAssertGreaterThan(
            snapshot.entries.first { $0.title == "B-small" }?.sizeBytes ?? 0,
            0,
            "A bounded scan must give later siblings a measurement opportunity"
        )
    }

    func testInvalidWeightsDoNotCreateInvalidFrames() {
        let frames = StorageTreemapLayoutEngine.frames(
            weights: [10, 0, -.infinity, .nan],
            in: CGRect(x: 0, y: 0, width: 200, height: 100),
            spacing: 4
        )

        XCTAssertGreaterThan(frames[0].width, 0)
        XCTAssertEqual(frames[1], .zero)
        XCTAssertEqual(frames[2], .zero)
        XCTAssertEqual(frames[3], .zero)
    }

    private func makeItem(
        title: String,
        bytes: Int64,
        isDirectory: Bool = false
    ) -> StorageItem {
        let path = "/tmp/\(title)"
        return StorageItem(
            id: path,
            title: title,
            path: path,
            groupTitle: "Test",
            sizeBytes: bytes,
            tier: .yellow,
            kind: "document",
            reason: "Test",
            recommendation: "Review",
            risk: "Review",
            requiresClose: "",
            trashPaths: [],
            openPath: path,
            isDirectory: isDirectory,
            status: .available
        )
    }
}

private actor StorageMapBrowseCallCounter {
    private(set) var count = 0
    private(set) var paths: [String] = []

    func record(_ path: String) {
        count += 1
        paths.append(path)
    }
}
