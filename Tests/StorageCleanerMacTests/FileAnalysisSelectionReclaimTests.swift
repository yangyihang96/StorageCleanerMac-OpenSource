import Foundation
import os
import XCTest
@testable import StorageCleanerMac

final class FileAnalysisSelectionReclaimTests: XCTestCase {
    private func selection(_ name: String, bytes: Int64 = 100, directory: Bool = false) -> FileAnalysisTrashSelection {
        .init(path: "/Fixture/Home/" + name, title: name, isDirectory: directory,
              kind: directory ? "folder" : "file", bytes: bytes, itemCount: nil)
    }

    private func clone(privateBytes: Int64 = 20, device: UInt64 = 1) -> (FileAnalysisSelectionReclaim.Metadata, FileStorageSharing.Reading) {
        (.init(isRegularFile: true, linkCount: 1, deviceID: device),
         .known(.init(privateBytes: privateBytes, allocatedDataBytes: 100, cloneID: 7,
                      cloneReferenceCount: 2, mayShareBlocks: true)))
    }

    func testPlainFileCountsAllListedBytes() throws {
        let reading = FileStorageSharing.Reading.known(.init(privateBytes: 100, allocatedDataBytes: 100,
            cloneID: 0, cloneReferenceCount: 1, mayShareBlocks: false))
        let result = try XCTUnwrap(FileAnalysisSelectionReclaim.calculate([selection("plain")],
            metadata: { _ in .init(isRegularFile: true, linkCount: 1, deviceID: 1) }, sharing: { _ in reading }))
        XCTAssertEqual(result.freedBytes, 100)
        XCTAssertEqual(result.possibleCloneBytes, 0)
    }

    func testOneCloneExcludesSharedBlocksAndFullPairCountsOnePossibleCopy() throws {
        let (metadata, reading) = clone()
        func calculate(_ selections: [FileAnalysisTrashSelection]) throws -> CleanupSelectionReclaimable {
            try XCTUnwrap(FileAnalysisSelectionReclaim.calculate(selections, metadata: { _ in metadata }, sharing: { _ in reading }))
        }
        let one = try calculate([selection("a")])
        XCTAssertEqual(one.freedBytes, 20)
        XCTAssertEqual(one.possibleCloneBytes, 0)
        let pair = try calculate([selection("a"), selection("b")])
        XCTAssertEqual(pair.freedBytes, 40)
        XCTAssertEqual(pair.possibleCloneBytes, 80)
    }

    func testHardLinkedFilesCountFullSizeWithoutReadingSharing() throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let result = try XCTUnwrap(FileAnalysisSelectionReclaim.calculate([selection("hard")],
            metadata: { _ in .init(isRegularFile: true, linkCount: 3, deviceID: 1) },
            sharing: { _ in reads.withLock { $0 += 1 }; return .unknown }))
        XCTAssertEqual(result.freedBytes, 100)
        XCTAssertEqual(result.possibleCloneBytes, 0)
        XCTAssertEqual(reads.withLock { $0 }, 0)
    }

    func testFoldersDoNotReadEitherMetadataOrSharing() throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let result = try XCTUnwrap(FileAnalysisSelectionReclaim.calculate([selection("folder", directory: true)],
            metadata: { _ in reads.withLock { $0 += 1 }; return nil },
            sharing: { _ in reads.withLock { $0 += 1 }; return .unknown }))
        XCTAssertEqual(result.freedBytes, 100)
        XCTAssertEqual(result.possibleCloneBytes, 0)
        XCTAssertEqual(reads.withLock { $0 }, 0)
    }

    func testUnknownAndNotReportedCountFullSizeWithTheSameReviewEstimates() throws {
        let metadata = clone().0
        for reading in [FileStorageSharing.Reading.unknown, .notReported] {
            let item = selection("unknown")
            let estimate = FileAnalysisSelectionReclaim.estimate(for: item, metadata: { _ in metadata }, sharing: { _ in reading })
            XCTAssertEqual(estimate, CleanupReclaimableEstimate.file(reading, allocatedBytes: 100, deviceID: 1))
            let result = try XCTUnwrap(FileAnalysisSelectionReclaim.calculate([item], metadata: { _ in metadata }, sharing: { _ in reading }))
            XCTAssertEqual(result.freedBytes, 100)
            XCTAssertEqual(result.possibleCloneBytes, 0)
        }
    }

    func testMissingOrNonregularMetadataDoesNotReadSharing() throws {
        for status in [FileAnalysisSelectionReclaim.Metadata?.none, .some(.init(isRegularFile: false, linkCount: 1, deviceID: 1))] {
            let result = try XCTUnwrap(FileAnalysisSelectionReclaim.calculate([selection("missing")], metadata: { _ in status },
                sharing: { _ in XCTFail("Only a regular file can have sharing read"); return .unknown }))
            XCTAssertEqual(result.freedBytes, 100)
            XCTAssertEqual(result.possibleCloneBytes, 0)
        }
    }

    func testMatchingCloneIDsOnDifferentVolumesDoNotMakeAFullGroup() throws {
        let reading = clone().1
        let result = try XCTUnwrap(FileAnalysisSelectionReclaim.calculate([selection("a"), selection("b")],
            metadata: { path in .init(isRegularFile: true, linkCount: 1, deviceID: path.hasSuffix("a") ? 1 : 2) },
            sharing: { _ in reading }))
        XCTAssertEqual(result.freedBytes, 40)
        XCTAssertEqual(result.possibleCloneBytes, 0)
    }

    func testSnapshotHeldBlocksAreExcludedWithoutPossibleClones() throws {
        let reading = FileStorageSharing.Reading.known(.init(privateBytes: 30, allocatedDataBytes: 100,
            cloneID: 0, cloneReferenceCount: 1, mayShareBlocks: false))
        let result = try XCTUnwrap(FileAnalysisSelectionReclaim.calculate([selection("snapshot")],
            metadata: { _ in .init(isRegularFile: true, linkCount: 1, deviceID: 1) }, sharing: { _ in reading }))
        XCTAssertEqual(result.freedBytes, 30)
        XCTAssertEqual(result.possibleCloneBytes, 0)
    }

    func testEachEstimateAndTotalMatchAnAllReadyD46Review() throws {
        let selections = [selection("a"), selection("b"), selection("hard"), selection("folder", directory: true),
                          selection("unknown"), selection("notReported"), selection("otherVolume")]
        let cloneReading = clone().1
        let metadata: FileAnalysisSelectionReclaim.MetadataReader = { path in
            .init(isRegularFile: true, linkCount: path.hasSuffix("hard") ? 2 : 1,
                  deviceID: path.hasSuffix("otherVolume") ? 2 : 1)
        }
        let sharing: FileAnalysisSelectionReclaim.SharingReader = { path in
            path.hasSuffix("unknown") ? .unknown : path.hasSuffix("notReported") ? .notReported : cloneReading
        }
        // review's lstat/readiness checks are deliberately outside this pure
        // test. Build ready items using its unchanged G1 formula and identity.
        let items = selections.map { item -> FileAnalysisTrashReviewItem in
            let device: UInt64 = item.title == "otherVolume" ? 2 : 1
            let otherLinks = item.title == "hard"
            let expected = item.isDirectory || otherLinks ? nil : CleanupReclaimableEstimate.file(
                sharing(item.path), allocatedBytes: item.bytes, deviceID: device)
            XCTAssertEqual(FileAnalysisSelectionReclaim.estimate(for: item, metadata: metadata, sharing: sharing), expected, item.title)
            return .init(selection: item, status: .ready(.init(deviceID: device, inode: 1,
                entryKind: item.isDirectory ? .directory : .regularFile, creationTimeNanoseconds: 1)),
                externalVolumeName: nil, hasOtherHardLinks: otherLinks, reclaimableEstimate: expected)
        }
        let review = FileAnalysisTrashReview(items: items)
        XCTAssertEqual(review.readyItems.count, selections.count)
        let result = try XCTUnwrap(FileAnalysisSelectionReclaim.calculate(selections, metadata: metadata, sharing: sharing))
        XCTAssertEqual(result, review.reclaimable)
        XCTAssertEqual(result.freedBytes, 460)
        XCTAssertEqual(result.possibleCloneBytes, 80)
        for item in review.items {
            let single = try XCTUnwrap(FileAnalysisSelectionReclaim.calculate([item.selection], metadata: metadata, sharing: sharing))
            XCTAssertEqual(single, FileAnalysisTrashReview(items: [item]).reclaimable)
        }
    }

    func testCancellationStopsBeforeTheNextRead() {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let result = FileAnalysisSelectionReclaim.calculate([selection("a"), selection("b")],
            metadata: { _ in reads.withLock { $0 += 1 }; return nil }, sharing: { _ in .unknown },
            isCancelled: { reads.withLock { $0 > 0 } })
        XCTAssertNil(result)
        XCTAssertEqual(reads.withLock { $0 }, 1)
    }

    @MainActor func testThreeRapidSelectionChangesOnlyComputeTheFinalSelection() async throws {
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let (store, result) = try await store { path in
            XCTAssertFalse(Thread.isMainThread)
            reads.withLock { $0.append(path) }
            return .init(isRegularFile: true, linkCount: 1, deviceID: 1)
        }
        let a = try XCTUnwrap(result.rootSnapshot.entries.first { $0.title == "a" })
        let b = try XCTUnwrap(result.rootSnapshot.entries.first { $0.title == "b" })
        store.toggleTrashSelection(a)
        store.toggleTrashSelection(a)
        store.toggleTrashSelection(b)
        XCTAssertTrue(store.isEstimatingSelectionReclaim)
        try await wait { !store.isEstimatingSelectionReclaim }
        XCTAssertEqual(reads.withLock { $0 }, [b.path])
        XCTAssertEqual(store.selectionReclaim?.freedBytes, b.sizeBytes)
        store.clearTrashSelection()
        XCTAssertNil(store.selectionReclaim)
        XCTAssertFalse(store.isEstimatingSelectionReclaim)
    }

    @MainActor func testCancelledReadCannotReplaceANewerSelection() async throws {
        let began = expectation(description: "old metadata read began")
        let finished = expectation(description: "old metadata read ended")
        let gate = DispatchSemaphore(value: 0)
        let (store, result) = try await store { path in
            if path.hasSuffix("/a") { began.fulfill(); gate.wait(); finished.fulfill() }
            return .init(isRegularFile: true, linkCount: 1, deviceID: 1)
        }
        let a = try XCTUnwrap(result.rootSnapshot.entries.first { $0.title == "a" })
        let b = try XCTUnwrap(result.rootSnapshot.entries.first { $0.title == "b" })
        store.toggleTrashSelection(a)
        await fulfillment(of: [began], timeout: 2)
        store.toggleTrashSelection(a)
        store.toggleTrashSelection(b)
        try await wait { store.selectionReclaim?.freedBytes == b.sizeBytes }
        gate.signal()
        await fulfillment(of: [finished], timeout: 2)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.selectionReclaim?.freedBytes, b.sizeBytes)
        XCTAssertFalse(store.isEstimatingSelectionReclaim)
    }

    @MainActor private func store(metadata: @escaping FileAnalysisSelectionReclaim.MetadataReader) async throws -> (LargeFilesStore, StorageMapAnalysisResult) {
        let coordinator = HeavyWorkCoordinator()
        var environment = FileAnalysisTrashEnvironment(journal: .init(directory: URL(fileURLWithPath: "/Fixture/Receipts")),
            moveToTrash: { _ in throw CancellationError() }, metadata: UnreadableSelectionFileSystem(), homePath: "/Fixture/Home",
            appDataPath: "/Fixture/AppData", excludedPaths: { [] }, isCloudFolder: { _ in false },
            isReadOnlyVolume: { _ in false }, userTrashPath: "/Fixture/Trash")
        environment.protectedLinkTargets = { _, _ in [] }
        let store = LargeFilesStore(coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self), storageMapTargets: [], trashEnvironment: environment,
            storageSharing: { _ in .notReported }, selectionMetadata: metadata)
        let index = SpaceMapMemoryIndex.make(rootPath: "/Fixture/Home", children: [.file("a", 100), .file("b", 200)])
        let snapshot = try DiskScanner(excludedPaths: []).storageMapSnapshot(at: index.rootPath, using: index)
        let result = StorageMapAnalysisResult(target: .init(path: index.rootPath, title: "~", kind: .homeDirectory),
            volumeTotalBytes: 1_000, volumeAvailableBytes: 500, inspectedItemCount: 2, omittedItemCount: 0,
            scanSeconds: 1, index: index, rootSnapshot: snapshot)
        store.replaceStorageAnalysisForTesting(result)
        await store.trashProtectionCompletionForTesting()?.value
        try await wait { store.trashSelectionState(for: snapshot.entries[0]) == .available }
        return (store, result)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Selection estimate did not settle")
    }
}

private struct UnreadableSelectionFileSystem: ReadOnlyFileSystem {
    func snapshot(at url: URL) throws -> FileSnapshot { throw CleanupFileSystemError.vanished }
    func children(of directory: URL) throws -> [URL] { [] }
    func symbolicLinkDestination(of url: URL) throws -> String { throw CleanupFileSystemError.vanished }
}
