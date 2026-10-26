import Foundation
import os
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SpaceMapTreemapSourceTests: XCTestCase {
    private func input() throws -> SpaceMapTreemapSource.Input {
        let index = SpaceMapMemoryIndex.make(children: [.directory("folder", [.file("clip.mov", 100)]), .file("readme.txt", 20)])
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
        return .init(snapshot: snapshot, index: index)
    }

    func testRootsContainBothMeasuredAndUnmeasuredRemainders() throws {
        let input = try input()
        let snapshot = StorageMapDirectorySnapshot(path: input.snapshot.path, title: "root", entries: input.snapshot.entries,
            measuredBytes: 150, referenceBytes: 200, inspectedItemCount: 3, omittedEntryCount: 1, isComplete: false)
        let roots = SpaceMapTreemapSource.Input(snapshot: snapshot, index: input.index).roots
        XCTAssertEqual(roots.first(where: { $0.role == .measuredRemainder })?.sizeBytes, 30)
        XCTAssertEqual(roots.first(where: { $0.role == .unmeasuredRemainder })?.sizeBytes, 50)
        XCTAssertEqual(roots.reduce(0) { $0 + $1.sizeBytes }, 200)
    }

    func testChildrenUseScannerSnapshotsAndTerminalDirectoriesDoNotExpand() throws {
        let index = SpaceMapMemoryIndex.make(children: [
            .directory("normal", [.file("visible", 40)]), .directory("blocked", [.file("hidden", 20)]),
            .directory("bundle", [.file("internal", 30)])], blocked: ["/analysis/blocked"], packages: ["/analysis/bundle"])
        let scanner = DiskScanner(excludedPaths: [])
        let snapshot = try scanner.storageMapSnapshot(at: index.rootPath, using: index)
        let input = SpaceMapTreemapSource.Input(snapshot: snapshot, index: index)
        XCTAssertEqual(input.children(at: "/analysis/normal"), try scanner.storageMapSnapshot(at: "/analysis/normal", using: index).entries)
        let cloud = StorageTreemapEntry(id: "cloud", title: "cloud", path: "/analysis/cloud", sizeBytes: 50,
                                        kind: "folder", isDirectory: true, childCount: 1, isCloudOnly: true)
        let cloudSnapshot = StorageMapDirectorySnapshot(path: snapshot.path, title: "root", entries: snapshot.entries + [cloud],
            measuredBytes: 140, inspectedItemCount: 6, omittedEntryCount: 0, isComplete: true)
        let tiles = SpaceMapTreemapSource.computeLayout(.init(snapshot: cloudSnapshot, index: index),
            .init(path: "/analysis", size: CGSize(width: 900, height: 600), levels: 3, version: 1))
        let paths = tiles.compactMap { tile -> String? in if case let .entry(entry) = tile.kind { entry.path } else { nil } }
        XCTAssertTrue(paths.contains("/analysis/normal/visible"))
        XCTAssertFalse(paths.contains("/analysis/blocked/hidden"))
        XCTAssertFalse(paths.contains("/analysis/bundle/internal"))
        XCTAssertFalse(tiles.contains { $0.depth > 0 && SpaceMapTreemapViewState.parentPath($0) == cloud.path })
    }

    func testKeyIncludesPathRoundedSizeLevelsAndVersion() {
        typealias Key = SpaceMapTreemapSource.Key
        let key = Key(path: "/a", size: CGSize(width: 600.1, height: 400.1), levels: 3, version: 1)
        XCTAssertEqual(key, Key(path: "/a", size: CGSize(width: 600.2, height: 400.2), levels: 3, version: 1))
        XCTAssertNotEqual(key, Key(path: "/b", size: key.size, levels: 3, version: 1))
        XCTAssertNotEqual(key, Key(path: "/a", size: CGSize(width: 601, height: 400), levels: 3, version: 1))
        XCTAssertNotEqual(key, Key(path: "/a", size: key.size, levels: 4, version: 1))
        XCTAssertNotEqual(key, Key(path: "/a", size: key.size, levels: 3, version: 2))
    }

    func testCacheHitDoesNotRecomputeAndKeepsOnlyEightRecentLayouts() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let source = SpaceMapTreemapSource { _, _ in count.withLock { $0 += 1 }; return [] }
        let input = try input()
        let key = SpaceMapTreemapSource.Key(path: input.snapshot.path, size: CGSize(width: 600, height: 400), levels: 3, version: 1)
        _ = await source.layout(input, key: key)
        _ = await source.layout(input, key: key)
        XCTAssertEqual(count.withLock { $0 }, 1)
        for version in UInt64(2)...10 {
            _ = await source.layout(input, key: .init(path: input.snapshot.path, size: key.size, levels: 3, version: version))
        }
        XCTAssertEqual(source.cachedLayoutCount, 8)
        _ = await source.layout(input, key: key)
        XCTAssertEqual(count.withLock { $0 }, 11)
    }

    func testCancellationDoesNotPublishOrCacheACompletedWorkerResult() async throws {
        let began = expectation(description: "detached layout began")
        let gate = DispatchSemaphore(value: 0)
        let source = SpaceMapTreemapSource { _, _ in began.fulfill(); gate.wait(); return [] }
        let input = try input()
        let task = Task { await source.layout(input, key: .init(path: input.snapshot.path, size: CGSize(width: 600, height: 400), levels: 3, version: 1)) }
        await fulfillment(of: [began], timeout: 2)
        task.cancel()
        gate.signal()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(source.cachedLayoutCount, 0)
    }

    func testClassificationIsReusedUntilTheAnalysisVersionChanges() async throws {
        let input = try input()
        let source = SpaceMapTreemapSource()
        await source.classify(index: input.index, version: 1, homePath: "/analysis")
        XCTAssertNotNil(source.purposeMap)
        // A cancelled request cannot replace the cached classification.
        let task = Task { await source.classify(index: input.index, version: 2, homePath: "/analysis") }
        task.cancel()
        await task.value
        await source.classify(index: input.index, version: 1, homePath: "/analysis")
        XCTAssertNotNil(source.purposeMap)
    }

    func testMapStyleUsesOnlyTheInjectedPreferenceDomain() {
        let defaults = TestPreferenceDomain.make(for: self)
        func store() -> LargeFilesStore {
            let coordinator = HeavyWorkCoordinator()
            return LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
                                   defaults: defaults, storageMapTargets: [])
        }
        let first = store()
        XCTAssertEqual(first.storageMapStyle, .bubbles)
        first.storageMapStyle = .blocks
        XCTAssertEqual(defaults.string(forKey: "storage-map.view-style"), "blocks")
        XCTAssertEqual(store().storageMapStyle, .blocks)
        defaults.set("invalid", forKey: "storage-map.view-style")
        XCTAssertEqual(store().storageMapStyle, .bubbles)
    }
}

#if DEBUG
@MainActor
final class SpaceMapTreemapDataVersionTests: XCTestCase {
    private func analysis() throws -> StorageMapAnalysisResult {
        let base = SpaceMapMemoryIndex.make(rootPath: "/Fixture/Home", children: [.file("clip.mov", 100), .file("keep.txt", 20)])
        // The layout fixture omits type totals; store edits need the same
        // complete profile and root title a real analysis would produce.
        var directories = base.directories
        var profile = StorageMapContentProfile(category: .video, bytes: 100)
        profile.add(bytes: 20, to: .document)
        directories[base.rootPath]?.contentProfile = profile
        let index = StorageMapAnalysisIndex(rootPath: base.rootPath, rootVolumeIdentifier: nil, directories: directories,
            childrenByDirectory: base.childrenByDirectory, blockedDirectoryPaths: [], duplicateFilePaths: [])
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index, titleOverride: "Fixture")
        return .init(target: .init(path: index.rootPath, title: "Fixture", kind: .homeDirectory),
            volumeTotalBytes: 1_000, volumeAvailableBytes: 500, inspectedItemCount: 2,
            omittedItemCount: 0, scanSeconds: 1, index: index, rootSnapshot: snapshot)
    }

    private func store(metadata: MemoryTrashFileSystem) -> LargeFilesStore {
        let coordinator = HeavyWorkCoordinator()
        var environment = FileAnalysisTrashEnvironment(
            journal: .init(directory: URL(fileURLWithPath: "/Fixture/Receipts")),
            moveToTrash: { source in try metadata.move(source, to: URL(fileURLWithPath: "/Fixture/Trash/" + source.lastPathComponent)) },
            metadata: metadata, homePath: "/Fixture", appDataPath: "/Fixture/AppData", excludedPaths: { [] },
            isCloudFolder: { _ in false }, isReadOnlyVolume: { _ in false }, userTrashPath: "/Fixture/Trash")
        environment.protectedLinkTargets = { _, _ in [] }
        return LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self), storageMapTargets: [], trashEnvironment: environment)
    }

    func testReplacingAnalysisIncrementsTheVersionEveryTime() throws {
        let store = store(metadata: MemoryTrashFileSystem())
        let analysis = try analysis()
        let initial = store.storageMapDataVersion
        store.replaceStorageAnalysisForTesting(analysis)
        XCTAssertEqual(store.storageMapDataVersion, initial + 1)
        store.replaceStorageAnalysisForTesting(analysis)
        XCTAssertEqual(store.storageMapDataVersion, initial + 2, "Even equal analyses invalidate cached layouts")
    }

    /// D46's live review/check uses lstat and its service persists a journal.
    /// Keep the recording and store's real completion/restore paths, with all
    /// metadata, moves and checkpoints in memory instead of creating files.
    func testRecordedMoveAndIdentityMatchedRestoreChangeTheVersion() throws {
        let metadata = MemoryTrashFileSystem()
        let store = store(metadata: metadata)
        let original = try analysis()
        store.replaceStorageAnalysisForTesting(original)
        let entry = try XCTUnwrap(original.rootSnapshot.entries.first { $0.title == "clip.mov" })
        let source = URL(fileURLWithPath: entry.path)
        let identity = FileIdentity(deviceID: 1, inode: 7, entryKind: .regularFile, creationTimeNanoseconds: 1)
        metadata.insert(path: entry.path, bytes: entry.sizeBytes, identity: identity)
        let beforeMove = store.storageMapDataVersion
        var checkpoints: [CleanReport] = []
        let report = RecordedTrashOperation.run(items: [.init(path: entry.path, bytes: entry.sizeBytes, identity: identity)],
            ruleID: FileAnalysisTrashService.ruleID, validate: { _ in },
            move: { source in try metadata.move(source, to: URL(fileURLWithPath: "/Fixture/Trash/clip.mov")) },
            metadata: metadata, persist: { report, _ in checkpoints.append(report) })
        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertGreaterThan(checkpoints.count, 1)
        let receipt = try XCTUnwrap(report.restorableReceipts.first)
        XCTAssertEqual(receipt.movedIdentity, identity)
        XCTAssertThrowsError(try metadata.snapshot(at: source))
        store.finishTrashForTesting(.init(report: report, movedPaths: [entry.path], movedBytes: entry.sizeBytes,
            skipped: [], notRestorableHereCount: 0, externalVolumeNames: [], receiptUnavailable: false, cancelled: false))
        XCTAssertGreaterThan(store.storageMapDataVersion, beforeMove)
        XCTAssertNil(store.storageAnalysis?.index.indexedEntry(at: entry.path))
        XCTAssertEqual(store.currentStorageMapSnapshot?.measuredBytes, original.rootSnapshot.measuredBytes - entry.sizeBytes)

        let beforeRestore = store.storageMapDataVersion
        _ = try metadata.move(receipt.resultingItemURL, to: source)
        store.operationHistoryDidRestore([receipt])
        XCTAssertGreaterThan(store.storageMapDataVersion, beforeRestore)
        XCTAssertEqual(store.storageAnalysis?.index, original.index)
        XCTAssertEqual(store.currentStorageMapSnapshot, original.rootSnapshot)
        XCTAssertEqual(store.trashPutBackCount, 1)
    }

    private final class MemoryTrashFileSystem: ReadOnlyFileSystem {
        private let entries = OSAllocatedUnfairLock(initialState: [String: FileSnapshot]())

        func insert(path: String, bytes: Int64, identity: FileIdentity) {
            entries.withLock { values in
                values[path] = FileSnapshot(identity: identity, standardizedPath: path, volumeIdentifier: "fixture",
                    logicalSizeBytes: bytes, allocatedSizeBytes: bytes, modificationTimeNanoseconds: 1,
                    isWritableVolume: true, isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false)
            }
        }

        func snapshot(at url: URL) throws -> FileSnapshot {
            try entries.withLock { values in
                guard let snapshot = values[url.path] else { throw CleanupFileSystemError.vanished }
                return snapshot
            }
        }

        func move(_ source: URL, to destination: URL) throws -> URL {
            try entries.withLock { values in
                guard let snapshot = values.removeValue(forKey: source.path) else { throw CleanupFileSystemError.vanished }
                values[destination.path] = FileSnapshot(identity: snapshot.identity, standardizedPath: destination.path,
                    volumeIdentifier: snapshot.volumeIdentifier, logicalSizeBytes: snapshot.logicalSizeBytes,
                    allocatedSizeBytes: snapshot.allocatedSizeBytes, modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
                    isWritableVolume: true, isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false)
                return destination
            }
        }

        func children(of directory: URL) throws -> [URL] { [] }
        func symbolicLinkDestination(of url: URL) throws -> String { throw CleanupFileSystemError.vanished }
    }
}
#endif
