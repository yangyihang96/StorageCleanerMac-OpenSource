import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D46: File Analysis can move items to the Trash. The analysis records a
/// change stamp per item, so a move can tell the item is still the one the
/// analysis saw, and after a move the index drops the item and every folder
/// above it shrinks, without another analysis. The oracle for the index is a
/// fresh analysis of the same tree with the item really gone.
///
/// Fixtures live in a hidden folder under the home folder and are removed
/// afterwards; nothing here moves anything to the Trash.
final class StorageMapIndexEditingTests: XCTestCase {
    // MARK: - Change stamps

    func testTheStampFitsInWhatWasPaddingSoTheIndexDoesNotGrow() {
        XCTAssertEqual(MemoryLayout<StorageMapIndexedEntry>.stride, 48)
    }

    func testTheAnalysisRecordsAStampForEveryFileAndFolderButNotForLinks() throws {
        let tree = try EditingTree()
        defer { tree.remove() }
        let index = try tree.analyze().index

        var checked = 0
        for (directory, children) in index.childrenByDirectory {
            for child in children {
                let path = StorageMapAnalysisIndex.childPath(child.name, in: directory)
                if child.kind == "alias" {
                    XCTAssertEqual(child.changeStamp, 0, path)
                    continue
                }
                XCTAssertNotEqual(child.changeStamp, 0, path)
                XCTAssertEqual(DiskScanner.storageMapChangeStamp(atPath: path), child.changeStamp, path)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 8)

        // Every walk mode records the same stamps (the index is compared whole).
        let scanner = DiskScanner(excludedPaths: [])
        let reference = try scanner.storageMapAnalysis(target: tree.target, options: .reference)
        XCTAssertEqual(reference.index, index)
    }

    func testAFileStampChangesWithItsContentOrIdentityAndAFolderStampIgnoresFinderBookkeeping() throws {
        let tree = try EditingTree()
        defer { tree.remove() }
        func stamp(_ relative: String) throws -> UInt32 {
            try XCTUnwrap(DiskScanner.storageMapChangeStamp(atPath: tree.url(relative).path))
        }

        let notes = try stamp("Docs/notes.txt")
        var times = [timespec(tv_sec: 1_000_000, tv_nsec: 0), timespec(tv_sec: 1_000_000, tv_nsec: 0)]
        XCTAssertEqual(utimensat(AT_FDCWD, tree.url("Docs/notes.txt").path, &times, 0), 0)
        XCTAssertNotEqual(try stamp("Docs/notes.txt"), notes, "Modified (same size, new time)")

        let report = try stamp("Docs/report.pdf")
        let bytes = try Data(contentsOf: tree.url("Docs/report.pdf"))
        try FileManager.default.removeItem(at: tree.url("Docs/report.pdf"))
        try bytes.write(to: tree.url("Docs/report.pdf"))
        XCTAssertNotEqual(try stamp("Docs/report.pdf"), report, "Replaced by another file with the same bytes")

        let docs = try stamp("Docs")
        try Data("finder".utf8).write(to: tree.url("Docs/.DS_Store"), options: .atomic)
        XCTAssertEqual(try stamp("Docs"), docs, "Finder saving .DS_Store does not change the folder's stamp")

        let media = try stamp("Media")
        try FileManager.default.moveItem(at: tree.url("Media"), to: tree.url("Media Old"))
        try FileManager.default.createDirectory(at: tree.url("Media"), withIntermediateDirectories: false)
        XCTAssertNotEqual(try stamp("Media"), media, "Another folder under the same name")
    }

    /// A file File Provider reports in the cloud and not downloaded reads as
    /// cloud-only in the map (D46: "only in the cloud" cannot be checked).
    func testACloudPlaceholderReadsAsCloudOnly() throws {
        let tree = try EditingTree()
        defer { tree.remove() }
        let placeholder = tree.url("big.zip").path
        let options = DiskScanner.StorageMapAnalysisOptions(
            concurrency: 1, ubiquityLookup: .everyItem,
            cloudState: .custom { url in
                DiskScanner.StorageMapCloudState(isUbiquitous: url.path == placeholder, isCurrent: url.path != placeholder)
            }
        )
        let analysis = try DiskScanner(excludedPaths: []).storageMapAnalysis(target: tree.target, options: options)

        XCTAssertEqual(analysis.index.indexedEntry(at: placeholder)?.isCloudOnly, true)
        XCTAssertEqual(analysis.index.indexedEntry(at: tree.url("Docs/report.pdf").path)?.isCloudOnly, false)
        XCTAssertEqual(analysis.index.indexedEntry(at: tree.url("Docs").path)?.isCloudOnly, false)
        let entries = analysis.rootSnapshot.entries
        XCTAssertEqual(entries.first { $0.path == placeholder }?.isCloudOnly, true)
        XCTAssertEqual(entries.first { $0.title == "Media" }?.isCloudOnly, false)
    }

    // MARK: - Moving an item out of the index

    func testMovingAFileOutMatchesAFreshAnalysisWithoutIt() throws {
        let tree = try EditingTree()
        defer { tree.remove() }
        var analysis = try tree.analyze()
        let before = analysis
        let path = tree.url("Docs/Nested/deep.bin").path
        let deepBytes = try tree.allocatedBytes("Docs/Nested/deep.bin")

        let removed = try XCTUnwrap(analysis.removeItem(at: path))

        XCTAssertEqual(removed.bytes, deepBytes)
        XCTAssertEqual(removed.itemCount, 1)
        for folder in ["Docs/Nested", "Docs", ""] {
            let key = folder.isEmpty ? tree.root.path : tree.url(folder).path
            XCTAssertEqual(analysis.index.directories[key]?.sizeBytes,
                           (before.index.directories[key]?.sizeBytes ?? 0) - deepBytes, folder)
            XCTAssertEqual(analysis.index.directories[key]?.descendantItemCount,
                           (before.index.directories[key]?.descendantItemCount ?? 0) - 1, folder)
        }
        XCTAssertNil(analysis.index.indexedEntry(at: path))
        XCTAssertEqual(analysis.inspectedItemCount, before.inspectedItemCount - 1)

        try FileManager.default.removeItem(atPath: path)
        let fresh = try tree.analyze()
        XCTAssertEqual(Normalized(analysis.index), Normalized(fresh.index))
        XCTAssertEqual(analysis.inspectedItemCount, fresh.inspectedItemCount)
    }

    func testMovingAFolderOutTakesEverythingUnderItAndMatchesAFreshAnalysis() throws {
        let tree = try EditingTree()
        defer { tree.remove() }
        var analysis = try tree.analyze()
        let before = analysis
        let docs = tree.url("Docs").path
        let docsAggregate = try XCTUnwrap(before.index.directories[docs])

        let removed = try XCTUnwrap(analysis.removeItem(at: docs))

        XCTAssertEqual(removed.bytes, docsAggregate.sizeBytes)
        XCTAssertEqual(removed.itemCount, docsAggregate.descendantItemCount + 1)
        XCTAssertEqual(Set(removed.directories.keys), [docs, docs + "/Nested"])
        XCTAssertTrue(analysis.index.directories.keys.allSatisfy { !($0 == docs || $0.hasPrefix(docs + "/")) })
        XCTAssertTrue(analysis.index.childrenByDirectory.keys.allSatisfy { !($0 == docs || $0.hasPrefix(docs + "/")) })
        XCTAssertEqual(analysis.index.directories[tree.root.path]?.contentProfile.bytes(for: .document),
                       (before.index.directories[tree.root.path]?.contentProfile.bytes(for: .document) ?? 0)
                        - docsAggregate.contentProfile.bytes(for: .document))

        try FileManager.default.removeItem(atPath: docs)
        let fresh = try tree.analyze()
        XCTAssertEqual(Normalized(analysis.index), Normalized(fresh.index))
        XCTAssertEqual(analysis.inspectedItemCount, fresh.inspectedItemCount)
    }

    func testPuttingAnItemBackRestoresTheIndexExactly() throws {
        let tree = try EditingTree()
        defer { tree.remove() }
        let original = try tree.analyze()
        var analysis = original
        let removedFolder = try XCTUnwrap(analysis.removeItem(at: tree.url("Docs").path))
        let removedFile = try XCTUnwrap(analysis.removeItem(at: tree.url("big.zip").path))

        XCTAssertTrue(analysis.reinsert(removedFile))
        XCTAssertTrue(analysis.reinsert(removedFolder))

        XCTAssertEqual(analysis.index, original.index, "Same entries in the same order, same sizes and counts")
        XCTAssertEqual(analysis.inspectedItemCount, original.inspectedItemCount)
        XCTAssertFalse(analysis.reinsert(removedFile), "Already back: its name is taken")
    }

    func testAHardLinkCountedAtItsOtherPathFreesNothingInTheMap() throws {
        let tree = try EditingTree()
        defer { tree.remove() }
        var analysis = try tree.analyze()
        let media = tree.url("Media").path
        let duplicate = try XCTUnwrap(analysis.index.duplicateFilePaths.first { $0.hasPrefix(media + "/") })
        let mediaBytes = analysis.index.directories[media]?.sizeBytes

        let removed = try XCTUnwrap(analysis.removeItem(at: duplicate))

        XCTAssertEqual(removed.bytes, 0)
        XCTAssertEqual(analysis.index.directories[media]?.sizeBytes, mediaBytes)
        XCTAssertEqual(analysis.index.directories[media]?.immediateChildCount, 1)
        XCTAssertFalse(analysis.index.duplicateFilePaths.contains(duplicate))
    }

    func testTheRootAndTheInsideOfAPackageAreNeverTakenOut() throws {
        let tree = try EditingTree()
        defer { tree.remove() }
        var analysis = try tree.analyze()
        let before = analysis

        XCTAssertNil(analysis.removeItem(at: tree.root.path))
        XCTAssertNil(analysis.removeItem(at: tree.url("Tool.app/Contents/Info.plist").path))
        XCTAssertNil(analysis.removeItem(at: tree.url("Tool.app/Contents").path))
        XCTAssertNil(analysis.removeItem(at: tree.url("missing.bin").path))
        XCTAssertNil(analysis.removeItem(at: "/private/tmp/elsewhere"))
        XCTAssertEqual(analysis, before)
    }

    // MARK: - Helpers

    /// The index with each folder's children sorted by name, since a fresh
    /// walk may list a folder in another order.
    private struct Normalized: Equatable {
        let rootPath: String
        let directories: [String: StorageMapDirectoryAggregate]
        let children: [String: [StorageMapIndexedEntry]]
        let blocked: Set<String>
        let duplicates: Set<String>

        init(_ index: StorageMapAnalysisIndex) {
            rootPath = index.rootPath
            directories = index.directories
            children = index.childrenByDirectory.mapValues { $0.sorted { $0.name < $1.name } }
            blocked = index.blockedDirectoryPaths
            duplicates = index.duplicateFilePaths
        }
    }
}

/// A small tree in a temporary home: documents in
/// nested folders, a hard-linked photo, an app-like package, an archive and a
/// symbolic link.
struct EditingTree {
    let root: URL

    var target: StorageMapScanTarget {
        StorageMapScanTarget(path: root.path, title: "Editing Fixture", kind: .homeDirectory)
    }

    init() throws {
        let fileManager = FileManager.default
        root = TestFileSystem.uniqueOperationRoot("IndexEditing")
        do {
            for folder in ["Docs/Nested", "Media", "Tool.app/Contents"] {
                try fileManager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for (path, bytes) in [
                ("Docs/report.pdf", 8_192), ("Docs/notes.txt", 100), ("Docs/Nested/deep.bin", 16_384),
                ("Media/photo.jpg", 65_536), ("Tool.app/Contents/Info.plist", 1_024), ("big.zip", 32_768),
            ] {
                try Data(repeating: 0x5A, count: bytes).write(to: root.appendingPathComponent(path))
            }
            try fileManager.linkItem(at: root.appendingPathComponent("Media/photo.jpg"),
                                     to: root.appendingPathComponent("Media/linked-photo.jpg"))
            try fileManager.createSymbolicLink(at: root.appendingPathComponent("link"),
                                               withDestinationURL: root.appendingPathComponent("Docs"))
        } catch {
            TestFileSystem.remove(root)
            throw error
        }
    }

    func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    func analyze() throws -> StorageMapAnalysisResult {
        try DiskScanner(excludedPaths: []).storageMapAnalysis(target: target)
    }

    func allocatedBytes(_ relative: String) throws -> Int64 {
        let values = try url(relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    func remove() {
        TestFileSystem.remove(root)
    }
}
