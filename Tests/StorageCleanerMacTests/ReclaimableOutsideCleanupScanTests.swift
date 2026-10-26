import Foundation
import XCTest
@testable import StorageCleanerMac

/// D104 G1: what emptying the Trash frees, for items listed outside a cleanup
/// scan: the large-file list, the File Analysis review and its confirmation,
/// and the selection note the project-artifact page shares with the scan.
/// Sharing comes from fake readers; the one fixture tree is a private temp
/// folder, and nothing is moved, deleted or sent anywhere.
final class ReclaimableOutsideCleanupScanTests: XCTestCase {
    private static let mib: Int64 = 1 << 20

    private static func clone(private bytes: Int64, of allocated: Int64, cloneID: UInt64 = 9,
                              references: Int = 2) -> FileStorageSharing.Reading {
        .known(FileStorageSharing(privateBytes: bytes, allocatedDataBytes: allocated, cloneID: cloneID,
                                  cloneReferenceCount: references, mayShareBlocks: true))
    }

    private static func unshared(_ allocated: Int64) -> FileStorageSharing.Reading {
        .known(FileStorageSharing(privateBytes: allocated, allocatedDataBytes: allocated, cloneID: 0,
                                  cloneReferenceCount: 1, mayShareBlocks: false))
    }

    // MARK: - Large-file list

    /// Each listed file is read once after the list is made, folders never;
    /// a test list put in place clears what an earlier scan read.
    @MainActor
    func testTheLargeFileListReadsEachListedFileOnceAndNoFolder() async throws {
        let coordinator = HeavyWorkCoordinator()
        let reads = PathLog()
        let plain = Self.item("/Fixture/plain.mov", bytes: 40 * Self.mib)
        let cloned = Self.item("/Fixture/cloned.mov", bytes: 40 * Self.mib)
        let unread = Self.item("/Fixture/elsewhere.iso", bytes: 40 * Self.mib)
        let folder = Self.item("/Fixture/Folder", bytes: 80 * Self.mib, isDirectory: true)
        let clonedPath = cloned.path, plainPath = plain.path
        let clonedReading = Self.clone(private: 4 * Self.mib, of: 40 * Self.mib)
        let plainReading = Self.unshared(40 * Self.mib)
        let store = LargeFilesStore(
            coordinator: coordinator, activityStore: HeavyWorkActivityStore(coordinator: coordinator),
            defaults: TestPreferenceDomain.make(for: self),
            listingScanOperation: { _, _ in LargeFileScanOutcome(items: [plain, cloned, unread, folder], summary: nil) },
            storageMapTargets: [],
            storageSharing: { path in
                reads.append(path)
                switch path {
                case clonedPath: return clonedReading
                case plainPath: return plainReading
                default: return .notReported
                }
            })
        store.startScan()
        try await waitUntil { store.phase == .finished }

        XCTAssertEqual(reads.paths.sorted(), [cloned.path, unread.path, plain.path].sorted())
        XCTAssertEqual(Set(store.reclaimableEstimates.keys), [plain.id, cloned.id],
                       "No estimate for a folder or a volume that reports no sharing")
        let clone = try XCTUnwrap(store.reclaimableEstimates[cloned.id])
        XCTAssertEqual(clone.reclaimableBytes(ofAllocated: cloned.sizeBytes), 4 * Self.mib)
        // D178: no format to pass; every page writes decimal sizes.
        let note = try XCTUnwrap(CleanupCandidateRowHint.reclaimable(clone, ofSize: cloned.sizeBytes))
        XCTAssertTrue(note.text.contains(ByteFormat.storageString(4 * Self.mib)), note.text)
        XCTAssertNil(CleanupCandidateRowHint.reclaimable(store.reclaimableEstimates[plain.id], ofSize: plain.sizeBytes),
                     "A file that shares nothing gets no note")

        store.replaceItemsForTesting([plain])
        XCTAssertEqual(store.reclaimableEstimates, [:])
    }

    // MARK: - File Analysis review

    /// Only a ready file without other hard links is read; a folder, a file
    /// with another link and an item that cannot move are not. The file's
    /// own volume goes with its estimate.
    func testTheTrashReviewReadsReadyFilesWithoutOtherLinksOnly() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try FileManager.default.linkItem(at: fixture.url("Media/photo.jpg"), to: fixture.url("Media/photo-link.jpg"))
        let analysis = try fixture.analyze()
        try FileManager.default.removeItem(at: fixture.url("gone.bin"))
        let environment = fixture.environment()
        let policy = FileAnalysisTrashService.policy(for: analysis, environment: environment)
        let bigZip = fixture.url("big.zip").path
        var reads: [String] = []
        let review = FileAnalysisTrashService.review(
            try ["big.zip", "Docs", "Media/photo.jpg", "gone.bin"].map { try fixture.selection($0, in: analysis.index) },
            index: analysis.index, policy: policy, environment: environment, externalVolumeName: nil,
            storageSharing: { path in
                reads.append(path)
                return path == bigZip ? Self.clone(private: 0, of: 1 << 40, cloneID: 41) : .notReported
            })

        XCTAssertEqual(reads, [bigZip])
        let item = try XCTUnwrap(review.items.first { $0.selection.path == bigZip })
        let estimate = try XCTUnwrap(item.reclaimableEstimate)
        XCTAssertEqual(estimate.cloneSharedBytes, item.selection.bytes, "Never more than the file's own size")
        var metadata = stat()
        XCTAssertEqual(lstat(bigZip, &metadata), 0)
        XCTAssertEqual(estimate.cloneGroupsReachingOutside.map(\.key),
                       [CleanupCloneGroupKey(deviceID: UInt64(metadata.st_dev), cloneID: 41)])
        for name in ["Docs", "Media/photo.jpg", "gone.bin"] {
            XCTAssertNil(review.items.first { $0.selection.path == fixture.url(name).path }?.reclaimableEstimate, name)
        }
        XCTAssertTrue(try XCTUnwrap(review.items.first { $0.selection.path == fixture.url("Media/photo.jpg").path })
            .hasOtherHardLinks)
    }

    /// The confirmation says what emptying the Trash frees only when clones
    /// or a snapshot keep a noticeable part; a selection holding every member
    /// of a clone group adds what it may free; folders say they count whole;
    /// another hard link keeps "at most"; otherwise the wording is unchanged.
    func testTheConfirmationSaysWhatEmptyingTheTrashFreesWhenItIsNoticeablyLess() {
        withLanguage(.zhHans) {
            let format = { (bytes: Int64) in ByteFormat.storageString(bytes) }
            let first = Self.reviewItem("a.mov", bytes: 40 * Self.mib, device: 3,
                                        sharing: Self.clone(private: 4 * Self.mib, of: 40 * Self.mib))
            let second = Self.reviewItem("b.mov", bytes: 40 * Self.mib, device: 3,
                                         sharing: Self.clone(private: 4 * Self.mib, of: 40 * Self.mib))
            let pair = OperationConfirmationFacts.fileAnalysis(FileAnalysisTrashReview(items: [first, second]),
                                                               permission: .verified)
            XCTAssertEqual(pair.trashReclaimable, OperationConfirmationFacts.TrashReclaimable(
                bytes: 8 * Self.mib, possibleCloneBytes: 36 * Self.mib, countsFoldersWhole: false))
            XCTAssertTrue(pair.value(for: .capacity).contains(
                "其中 \(format(80 * Self.mib)) 移到废纸篓；清空废纸篓后预计释放 \(format(8 * Self.mib))，"
                + "所选完整克隆另可能释放 \(format(36 * Self.mib))；与 APFS 克隆共享或被本地快照占用的部分不释放"),
                pair.value(for: .capacity))
            XCTAssertEqual(pair.items.map(\.detail), [
                "清空废纸篓后预计释放 \(format(4 * Self.mib))；其余与其他文件共享存储（克隆）",
                "清空废纸篓后预计释放 \(format(4 * Self.mib))；其余与其他文件共享存储（克隆）",
            ])

            // The same clone ID on another volume is another group.
            let elsewhere = Self.reviewItem("b.mov", bytes: 40 * Self.mib, device: 4,
                                            sharing: Self.clone(private: 4 * Self.mib, of: 40 * Self.mib))
            XCTAssertEqual(OperationConfirmationFacts.fileAnalysisReclaimable(
                FileAnalysisTrashReview(items: [first, elsewhere]))?.possibleCloneBytes, 0)

            let folder = FileAnalysisTrashReviewItem(
                selection: FileAnalysisTrashSelection(path: "/Fixture/Folder", title: "Folder", isDirectory: true,
                                                      kind: "folder", bytes: 2 * Self.mib, itemCount: 3),
                status: .ready(Self.identity(9)), externalVolumeName: nil)
            let withFolder = OperationConfirmationFacts.fileAnalysis(
                FileAnalysisTrashReview(items: [first, folder]), permission: .verified)
            XCTAssertEqual(withFolder.trashReclaimable?.countsFoldersWhole, true)
            XCTAssertEqual(withFolder.trashReclaimable?.bytes, 6 * Self.mib)
            XCTAssertTrue(withFolder.value(for: .capacity).hasSuffix("；文件夹按完整大小计"),
                          withFolder.value(for: .capacity))

            var linked = second
            linked.hasOtherHardLinks = true
            linked.reclaimableEstimate = nil
            let upperBound = OperationConfirmationFacts.fileAnalysis(
                FileAnalysisTrashReview(items: [first, linked]), permission: .verified)
            XCTAssertNil(upperBound.trashReclaimable)
            XCTAssertTrue(upperBound.value(for: .capacity).contains("最多释放"), upperBound.value(for: .capacity))

            let little = Self.reviewItem("c.mov", bytes: 40 * Self.mib, device: 3,
                                         sharing: Self.clone(private: 40 * Self.mib - 512 * 1_024, of: 40 * Self.mib))
            let plain = OperationConfirmationFacts.fileAnalysis(FileAnalysisTrashReview(items: [little]),
                                                                permission: .verified)
            XCTAssertNil(plain.trashReclaimable, "Under 1 MB kept is not noticeable")
            XCTAssertTrue(plain.value(for: .capacity).contains(
                "其中 \(format(40 * Self.mib)) 移到废纸篓，清空废纸篓后才释放"), plain.value(for: .capacity))
            XCTAssertEqual(plain.items.map(\.detail), [nil])
        }
        withLanguage(.english) {
            let item = Self.reviewItem("a.mov", bytes: 40 * Self.mib, device: 3,
                                       sharing: Self.clone(private: 4 * Self.mib, of: 40 * Self.mib))
            let facts = OperationConfirmationFacts.fileAnalysis(FileAnalysisTrashReview(items: [item]), permission: .verified)
            XCTAssertTrue(facts.value(for: .capacity).contains(
                "emptying it frees about \(ByteFormat.storageString(4 * Self.mib)); blocks shared with APFS clones "
                + "or held by a local snapshot stay"), facts.value(for: .capacity))
        }
    }

    // MARK: - Shared pieces

    /// D178: a row's note writes sizes in decimal units on every page, "3 MB"
    /// (was in the page's byte format: binary "2.9 MiB" unless the page
    /// passed the decimal one; renamed from testARowNoteUsesThePagesByteFormat).
    func testARowNoteWritesDecimalSizes() {
        let estimate = CleanupReclaimableEstimate.file(Self.clone(private: 3_000_000, of: 40_000_000),
                                                       allocatedBytes: 40_000_000)
        let note = CleanupCandidateRowHint.reclaimable(estimate, ofSize: 40_000_000)
        XCTAssertTrue(note?.text.contains(ByteFormat.storageString(3_000_000)) == true, note?.text ?? "nil")
        XCTAssertFalse(note?.text.contains("MiB") ?? true, note?.text ?? "nil")
        XCTAssertNil(CleanupReclaimableEstimate.file(.notReported, allocatedBytes: 40_000_000))
    }

    /// Items listed outside a scan match clone groups across one another the
    /// way scan candidates do: every member listed counts one copy as
    /// possibly freed; one member alone counts none; an item without an
    /// estimate counts its whole size.
    func testWholeCloneGroupsAreMatchedAcrossListedItems() {
        let member = CleanupReclaimableEstimate.file(Self.clone(private: 0, of: 10 * Self.mib),
                                                     allocatedBytes: 10 * Self.mib, deviceID: 1)
        let both = CleanupSelectionReclaimable(items: [(size: 10 * Self.mib, estimate: member),
                                                       (size: 10 * Self.mib, estimate: member)])
        XCTAssertEqual(both.freedBytes, 0)
        XCTAssertEqual(both.possibleCloneBytes, 10 * Self.mib)
        let one = CleanupSelectionReclaimable(items: [(size: 10 * Self.mib, estimate: member),
                                                      (size: 5 * Self.mib, estimate: nil)])
        XCTAssertEqual(one.freedBytes, 5 * Self.mib)
        XCTAssertEqual(one.possibleCloneBytes, 0)
    }

    /// The selection note shared by the scan results and the project-artifact
    /// move confirmation says what emptying the Trash frees, adds what whole
    /// clone groups selected together may free, and is left out unless the
    /// kept part is noticeable.
    @MainActor
    func testTheSelectionNoteSaysWhatEmptyingTheTrashFreesWhenItIsNoticeablyLess() {
        let shared = Self.candidate(size: 40 * Self.mib, estimate: CleanupReclaimableEstimate.file(
            Self.clone(private: 4 * Self.mib, of: 40 * Self.mib), allocatedBytes: 40 * Self.mib, deviceID: 1))
        let member = CleanupReclaimableEstimate.file(Self.clone(private: 0, of: 10 * Self.mib, cloneID: 5),
                                                     allocatedBytes: 10 * Self.mib, deviceID: 1)
        let clones = [Self.candidate(size: 10 * Self.mib, estimate: member),
                      Self.candidate(size: 10 * Self.mib, estimate: member)]
        let little = Self.candidate(size: 40 * Self.mib, estimate: CleanupReclaimableEstimate.file(
            Self.clone(private: 40 * Self.mib - 512 * 1_024, of: 40 * Self.mib), allocatedBytes: 40 * Self.mib))
        withLanguage(.zhHans) {
            // D178: decimal (was `ByteFormat.string`, binary: "4.0 MiB", "0 B", "10.0 MiB").
            XCTAssertEqual(ProjectArtifactView.reclaimableNote([shared]),
                           " · 清空废纸篓后预计释放 \(ByteFormat.storageString(4 * Self.mib))")
            XCTAssertEqual(ProjectArtifactView.reclaimableNote(clones),
                           " · 清空废纸篓后预计释放 \(ByteFormat.storageString(0))，"
                           + "所选完整克隆另可能释放 \(ByteFormat.storageString(10 * Self.mib))")
            XCTAssertEqual(ProjectArtifactView.reclaimableNote([little]), "", "Under 1 MB kept is not noticeable")
            XCTAssertEqual(ProjectArtifactView.reclaimableNote([]), "")
        }
        withLanguage(.english) {
            // D178: decimal (was `ByteFormat.string`, binary).
            XCTAssertEqual(CleanupSelectionReclaimable(candidates: clones).note(ofSelected: 20 * Self.mib),
                           "about \(ByteFormat.storageString(0)) freed after emptying the Trash, "
                           + "plus up to \(ByteFormat.storageString(10 * Self.mib)) from clones selected together")
            XCTAssertNil(CleanupSelectionReclaimable(candidates: [little]).note(ofSelected: 40 * Self.mib))
        }
    }

    // MARK: - Helpers

    private static func candidate(size: Int64, estimate: CleanupReclaimableEstimate?) -> ScanCandidate {
        let url = URL(fileURLWithPath: "/Fixture/artifact-\(UUID().uuidString)")
        let snapshot = FileSnapshot(
            identity: FileIdentity(deviceID: 1, inode: 3, entryKind: .directory, creationTimeNanoseconds: 1),
            standardizedPath: url.path, volumeIdentifier: "fixture", logicalSizeBytes: size,
            allocatedSizeBytes: size, modificationTimeNanoseconds: 1, isWritableVolume: true,
            isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false)
        var candidate = ScanCandidate(id: ScanCandidateID(), sessionID: ScanSessionID(), ruleID: "g1.fixture",
            ruleSelectionPolicyVersion: 1, categoryID: "system", categoryTitle: "g1", subcategoryTitle: "g1",
            sourceURL: url, allowedRootURL: url.deletingLastPathComponent(), snapshot: snapshot, risk: .safe,
            recommendation: CleanupRecommendation(level: .recommended, reasonCode: "g1", evidenceCodes: []),
            defaultSelection: .selected, executionEligibility: .eligible, measurementCompleteness: .complete,
            isManuallySelectable: true, action: .moveToTrash, requiredClosedBundleIDs: [], reason: "G1 fixture")
        candidate.reclaimableEstimate = estimate
        return candidate
    }

    private static func item(_ path: String, bytes: Int64, isDirectory: Bool = false) -> StorageItem {
        StorageItem(id: path, title: (path as NSString).lastPathComponent, path: path, groupTitle: "Fixture",
                    sizeBytes: bytes, tier: .yellow, kind: isDirectory ? "folder" : "file", reason: "Fixture",
                    recommendation: "Fixture", risk: "Fixture", requiresClose: "None", trashPaths: [path],
                    openPath: path, isDirectory: isDirectory, status: .available)
    }

    private static func identity(_ inode: UInt64, device: UInt64 = 3) -> FileIdentity {
        FileIdentity(deviceID: device, inode: inode, entryKind: .regularFile, creationTimeNanoseconds: 1)
    }

    /// A ready file the way the review makes it, with its volume's estimate.
    private static func reviewItem(_ name: String, bytes: Int64, device: UInt64,
                                   sharing: FileStorageSharing.Reading) -> FileAnalysisTrashReviewItem {
        FileAnalysisTrashReviewItem(
            selection: FileAnalysisTrashSelection(path: "/Fixture/\(name)", title: name, isDirectory: false,
                                                  kind: "file", bytes: bytes, itemCount: nil),
            status: .ready(identity(UInt64(name.utf8.count), device: device)), externalVolumeName: nil,
            reclaimableEstimate: CleanupReclaimableEstimate.file(sharing, allocatedBytes: bytes, deviceID: device))
    }

    private func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let preferences = TestVolatilePreferences()
        preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
        try body()
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private final class PathLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ path: String) { lock.withLock { values.append(path) } }
        var paths: [String] { lock.withLock { values } }
    }
}
