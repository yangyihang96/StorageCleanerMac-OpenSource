import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D100 G1: reclaimable space leaves out blocks shared with clones or held by
/// a local snapshot. Clone fixtures are made with clonefile(2) (what `cp -c`
/// uses) in a temporary folder; nothing outside it is read or changed.
final class FileStorageSharingTests: XCTestCase {
    private static let mebibyte = 1 << 20

    // MARK: Reader on real APFS clones

    func testPlainCloneAndPartlyRewrittenCloneReportTheirPrivateBytes() throws {
        let root = try makeRoot()
        let plain = root.appendingPathComponent("plain.bin")
        let original = root.appendingPathComponent("original.bin")
        let clone = root.appendingPathComponent("clone.bin")
        let rewritten = root.appendingPathComponent("rewritten.bin")
        try writeRandom(4 * Self.mebibyte, to: plain)
        try writeRandom(4 * Self.mebibyte, to: original)
        try makeClone(of: original, at: clone)
        try makeClone(of: original, at: rewritten)
        try rewrite(Self.mebibyte, at: Self.mebibyte, in: rewritten)

        let plainSharing = try known(plain)
        XCTAssertEqual(plainSharing.allocatedDataBytes, Int64(4 * Self.mebibyte))
        XCTAssertEqual(plainSharing.privateBytes, plainSharing.allocatedDataBytes)
        XCTAssertEqual(plainSharing.sharedBytes, 0)
        XCTAssertEqual(plainSharing.cloneReferenceCount, 1)

        // A full clone pair: nothing private, one clone ID, two references.
        let originalSharing = try known(original)
        let cloneSharing = try known(clone)
        XCTAssertEqual(originalSharing.privateBytes, 0)
        XCTAssertEqual(cloneSharing.privateBytes, 0)
        XCTAssertEqual(cloneSharing.sharedBytes, Int64(4 * Self.mebibyte))
        XCTAssertEqual(originalSharing.cloneID, cloneSharing.cloneID)
        XCTAssertEqual(originalSharing.cloneReferenceCount, 2)
        XCTAssertEqual(cloneSharing.cloneReferenceCount, 2)
        XCTAssertTrue(cloneSharing.sharesWithClones)

        // A rewritten clone owns only the rewritten blocks and leaves the group.
        let rewrittenSharing = try known(rewritten)
        XCTAssertEqual(rewrittenSharing.privateBytes, Int64(Self.mebibyte))
        XCTAssertGreaterThan(rewrittenSharing.privateBytes, 0)
        XCTAssertLessThan(rewrittenSharing.privateBytes, rewrittenSharing.allocatedDataBytes)
        XCTAssertNotEqual(rewrittenSharing.cloneID, originalSharing.cloneID)
        XCTAssertTrue(rewrittenSharing.mayShareBlocks)
        XCTAssertTrue(rewrittenSharing.sharesWithClones)
    }

    func testAMissingFileIsUnknown() throws {
        let root = try makeRoot()
        XCTAssertEqual(FileStorageSharing.read(at: root.appendingPathComponent("missing")), .unknown)
    }

    // MARK: Reply layout

    func testReplyFieldsAreReadInGroupAndBitOrder() {
        let reading = parse(reply(flags: 0, allocated: 8_192, privateBytes: 4_096,
                                                     cloneID: 77, extendedFlags: 0x41, cloneCount: 3))
        XCTAssertEqual(reading, .known(FileStorageSharing(
            privateBytes: 4_096, allocatedDataBytes: 8_192, cloneID: 77, cloneReferenceCount: 3, mayShareBlocks: true)))
    }

    func testCompressedDatalessShortAndIncompleteRepliesAreNotTrusted() {
        // Compressed data lives in the resource fork; the private size says nothing about it.
        XCTAssertEqual(parse(reply(flags: bits(UF_COMPRESSED))), .unknown)
        XCTAssertEqual(parse(reply(flags: bits(SF_DATALESS))), .notReported)
        XCTAssertEqual(parse(reply(omitting: bits(ATTR_CMNEXT_PRIVATESIZE))), .notReported)
        XCTAssertEqual(parse(reply(omitting: bits(ATTR_CMNEXT_CLONE_REFCNT))), .unknown)
        XCTAssertEqual(parse(reply(privateBytes: -1)), .unknown)
        var truncated = reply()
        truncated.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(40).littleEndian, Array.init))
        XCTAssertEqual(parse(truncated), .unknown)
        XCTAssertEqual(parse(Array(reply().prefix(20))), .unknown)
    }

    // MARK: Tally

    /// Review A-R1: blocks shared with clones count as kept, even for a group
    /// of full clones wholly inside; one copy of that group is kept apart as
    /// possibly freed. A group reaching outside is kept for selections.
    func testCloneSharedBlocksCountAsKeptAndAWholeGroupAsPossiblyFreedOnce() {
        let size = Int64(8 * Self.mebibyte)
        var both = CleanupReclaimableTally()
        both.record(clone(id: 1, count: 2, size: size), allocatedBytes: size, deviceID: 9)
        both.record(clone(id: 1, count: 2, size: size), allocatedBytes: size, deviceID: 9)
        XCTAssertEqual(both.estimate.reclaimableBytes(ofAllocated: 2 * size), 0)
        XCTAssertEqual(both.estimate.wholeCloneGroupBytes, size)
        XCTAssertEqual(both.estimate.cloneGroupsReachingOutside, [])
        XCTAssertEqual(both.estimate.reason, .sharedWithClones)

        var one = CleanupReclaimableTally()
        one.record(clone(id: 1, count: 2, size: size), allocatedBytes: size, deviceID: 9)
        XCTAssertEqual(one.estimate.reclaimableBytes(ofAllocated: size), 0)
        XCTAssertEqual(one.estimate.wholeCloneGroupBytes, 0)
        XCTAssertEqual(one.estimate.cloneGroupsReachingOutside, [
            CleanupCloneGroupShare(key: CleanupCloneGroupKey(deviceID: 9, cloneID: 1), members: 1,
                                   referenceCount: 2, sharedBytes: size),
        ])

        var twoOfThree = CleanupReclaimableTally()
        twoOfThree.record(clone(id: 5, count: 3, size: size), allocatedBytes: size, deviceID: 9)
        twoOfThree.record(clone(id: 5, count: 3, size: size), allocatedBytes: size, deviceID: 9)
        XCTAssertEqual(twoOfThree.estimate.reclaimableBytes(ofAllocated: 2 * size), 0)
        XCTAssertEqual(twoOfThree.estimate.wholeCloneGroupBytes, 0)
        XCTAssertEqual(twoOfThree.estimate.cloneGroupsReachingOutside.map(\.members), [2])

        // Folders merge upward: two halves of one group make it whole.
        var left = CleanupReclaimableTally()
        var right = CleanupReclaimableTally()
        left.record(clone(id: 1, count: 2, size: size), allocatedBytes: size, deviceID: 9)
        right.record(clone(id: 1, count: 2, size: size), allocatedBytes: size, deviceID: 9)
        var parent = CleanupReclaimableTally()
        parent.add(left)
        parent.add(right)
        XCTAssertEqual(parent.estimate, both.estimate)

        // Clone IDs are per volume.
        var twoVolumes = CleanupReclaimableTally()
        twoVolumes.record(clone(id: 1, count: 2, size: size), allocatedBytes: size, deviceID: 9)
        twoVolumes.record(clone(id: 1, count: 2, size: size), allocatedBytes: size, deviceID: 10)
        XCTAssertEqual(twoVolumes.estimate.reclaimableBytes(ofAllocated: 2 * size), 0)
        XCTAssertEqual(twoVolumes.estimate.wholeCloneGroupBytes, 0)
        XCTAssertEqual(Set(twoVolumes.estimate.cloneGroupsReachingOutside.map(\.key.deviceID)), [9, 10])
    }

    /// Review A-R2: a selection counts one copy of a group only when every
    /// member is selected, matched by volume and clone ID across items.
    func testASelectionCountsOneCopyOfAGroupOnlyWhenEveryMemberIsSelected() {
        let size = Int64(4 * Self.mebibyte)
        func member(of id: UInt64, count: Int = 2, deviceID: UInt64 = 9) -> ScanCandidate {
            var tally = CleanupReclaimableTally()
            tally.record(clone(id: id, count: count, size: size), allocatedBytes: size, deviceID: deviceID)
            return makeCandidate(size: size, estimate: tally.estimate)
        }
        func selection(_ candidates: [ScanCandidate]) -> (freed: Int64, possible: Int64) {
            let selection = CleanupSelectionReclaimable(candidates: candidates)
            return (selection.freedBytes, selection.possibleCloneBytes)
        }
        let left = member(of: 1)
        let right = member(of: 1)
        XCTAssertTrue(selection([left]) == (0, 0), "one member alone frees nothing while its clone stays")
        XCTAssertTrue(selection([left, right]) == (0, size))
        XCTAssertTrue(selection([left, member(of: 1, deviceID: 10)]) == (0, 0), "another volume, another group")

        let threes = [member(of: 7, count: 3), member(of: 7, count: 3), member(of: 7, count: 3)]
        XCTAssertTrue(selection(Array(threes.prefix(2))) == (0, 0))
        XCTAssertTrue(selection(threes) == (0, size))

        // A whole group inside one item counts once, alone or with others.
        var pair = CleanupReclaimableTally()
        pair.record(clone(id: 3, count: 2, size: size), allocatedBytes: size, deviceID: 9)
        pair.record(clone(id: 3, count: 2, size: size), allocatedBytes: size, deviceID: 9)
        let pairItem = makeCandidate(size: 2 * size, estimate: pair.estimate)
        XCTAssertTrue(selection([pairItem]) == (0, size))
        XCTAssertTrue(selection([pairItem, left, right]) == (0, 2 * size))

        // Items without sharing add their size; snapshot-held blocks stay kept.
        let plain = makeCandidate(size: size, estimate: nil)
        let held = makeCandidate(size: size, estimate: CleanupReclaimableEstimate(
            cloneSharedBytes: 0, snapshotHeldBytes: size / 2, unknownBytes: 0))
        XCTAssertTrue(selection([plain, held, left, right]) == (size + size / 2, size))
        XCTAssertTrue(selection([]) == (0, 0))
    }

    /// An item keeps the largest groups reaching outside, up to the limit;
    /// a group left out only makes a selection's possible amount smaller.
    func testAnItemKeepsTheLargestGroupsReachingOutsideUpToTheLimit() {
        let limit = CleanupCloneGroupShare.retainedLimit
        var tally = CleanupReclaimableTally()
        for index in 0..<(limit + 3) {
            tally.record(clone(id: UInt64(index), count: 2, size: Int64(index + 1) * 4_096),
                         allocatedBytes: Int64(index + 1) * 4_096, deviceID: 9)
        }
        let estimate = tally.estimate
        XCTAssertEqual(estimate.cloneGroupsReachingOutside.count, limit)
        XCTAssertEqual(estimate.cloneGroupsReachingOutside.first?.key.cloneID, UInt64(limit + 2))
        XCTAssertEqual(Set(estimate.cloneGroupsReachingOutside.map(\.key.cloneID)),
                       Set((3..<(limit + 3)).map(UInt64.init)))
        XCTAssertEqual(estimate.cloneSharedBytes, (1...(limit + 3)).reduce(Int64(0)) { $0 + Int64($1) * 4_096 },
                       "every shared block still counts as kept")
    }

    func testSnapshotUnknownAndUnreportedFilesAreKeptApart() {
        let size = Int64(4 * Self.mebibyte)
        var tally = CleanupReclaimableTally()
        // Shared without any clone: a local snapshot holds the blocks.
        tally.record(.known(FileStorageSharing(privateBytes: size / 4, allocatedDataBytes: size, cloneID: 3,
                                               cloneReferenceCount: 1, mayShareBlocks: false)),
                     allocatedBytes: size, deviceID: 9)
        tally.record(.unknown, allocatedBytes: size, deviceID: 9)
        tally.record(.notReported, allocatedBytes: size, deviceID: 9)
        let estimate = tally.estimate
        XCTAssertEqual(estimate.snapshotHeldBytes, size * 3 / 4)
        XCTAssertEqual(estimate.cloneSharedBytes, 0)
        XCTAssertEqual(estimate.unknownBytes, size)
        XCTAssertEqual(estimate.reason, .heldBySnapshot)
        XCTAssertEqual(estimate.reclaimableBytes(ofAllocated: 3 * size), 3 * size - size * 3 / 4)

        // A file never retains more than it adds to the item's size.
        var capped = CleanupReclaimableTally()
        capped.record(clone(id: 1, count: 2, size: size), allocatedBytes: 4_096, deviceID: 9)
        XCTAssertEqual(capped.estimate.cloneSharedBytes, 4_096)
    }

    // MARK: Scanner

    func testScanEstimatesWhatEachCacheFolderFrees() async throws {
        let home = try makeRoot().appendingPathComponent("Home")
        let caches = home.appendingPathComponent("Library/Caches")
        let size = 2 * Self.mebibyte
        // Both copies of a clone pair inside one folder; one copy whose twin
        // is outside the cache folder; a folder with no clones.
        try writeRandom(size, to: caches.appendingPathComponent("Both/a.bin"))
        try makeClone(of: caches.appendingPathComponent("Both/a.bin"), at: caches.appendingPathComponent("Both/b.bin"))
        try writeRandom(size, to: home.appendingPathComponent("Project/.venv/lib.bin"))
        try makeClone(of: home.appendingPathComponent("Project/.venv/lib.bin"),
                      at: caches.appendingPathComponent("Shared/lib.bin"))
        try writeRandom(size, to: caches.appendingPathComponent("Plain/data.bin"))

        let session = try await scan(home: home, fileSystem: SharingFileSystem())
        let both = try candidate("Both", in: session)
        let shared = try candidate("Shared", in: session)
        let plain = try candidate("Plain", in: session)
        XCTAssertEqual(both.estimatedSizeBytes, Int64(2 * size))
        // Review A-R1: the pair's copy is possible, not certain.
        XCTAssertEqual(both.reclaimableSizeBytes, 0)
        XCTAssertEqual(both.reclaimableEstimate?.wholeCloneGroupBytes, Int64(size))
        XCTAssertEqual(CleanupSelectionReclaimable(candidates: [both]).possibleCloneBytes, Int64(size))
        XCTAssertEqual(shared.estimatedSizeBytes, Int64(size))
        XCTAssertEqual(shared.reclaimableSizeBytes, 0)
        XCTAssertEqual(CleanupSelectionReclaimable(candidates: [shared]).possibleCloneBytes, 0)
        XCTAssertEqual(plain.reclaimableSizeBytes, plain.estimatedSizeBytes)
        XCTAssertNil(CleanupCandidateRowHint.reclaimable(for: plain))
        withLanguage(.zhHans) {
            // D178: decimal, as Finder writes sizes (was `ByteFormat.string`, binary).
            XCTAssertEqual(CleanupCandidateRowHint.reclaimable(for: shared)?.text,
                           "清空废纸篓后预计释放 \(ByteFormat.storageString(0))；其余与其他文件共享存储（克隆）")
            XCTAssertEqual(CleanupCandidateRowHint.reclaimable(for: both)?.text,
                           "清空废纸篓后预计释放 \(ByteFormat.storageString(0))；其余与其他文件共享存储（克隆），其中 \(ByteFormat.storageString(Int64(size))) 的克隆都在本项内，别处没有共享时也会释放")
            XCTAssertEqual(CleanupCandidateRowHint.reclaimable(for: both)?.systemImage, "square.on.square")
        }

        // A file system that cannot read sharing keeps the old size and says so.
        let unread = try await scan(home: home, fileSystem: SharingFileSystem(override: .unknown))
        let unreadShared = try candidate("Shared", in: unread)
        XCTAssertEqual(unreadShared.reclaimableSizeBytes, unreadShared.estimatedSizeBytes)
        withLanguage(.zhHans) {
            XCTAssertEqual(CleanupCandidateRowHint.reclaimable(for: unreadShared)?.text,
                           "部分文件无法读取是否与其他文件共享存储，可释放空间可能高估")
        }
        // Volumes that report nothing (not APFS) show no hint at all.
        let unreported = try await scan(home: home, fileSystem: SharingFileSystem(override: .notReported))
        XCTAssertNil(CleanupCandidateRowHint.reclaimable(for: try candidate("Shared", in: unreported)))
    }

    /// Review A-R1 evidence: a full pair reads the same whether or not a
    /// partial clone outside still shares its blocks, so the scan cannot
    /// tell the two apart and both get the same cautious estimate.
    func testAFullPairReadsTheSameWithOrWithoutAPartialCloneOutside() async throws {
        let home = try makeRoot().appendingPathComponent("Home")
        let caches = home.appendingPathComponent("Library/Caches")
        let size = 4 * Self.mebibyte
        try writeRandom(size, to: caches.appendingPathComponent("Isolated/a.bin"))
        try makeClone(of: caches.appendingPathComponent("Isolated/a.bin"),
                      at: caches.appendingPathComponent("Isolated/b.bin"))
        try writeRandom(size, to: caches.appendingPathComponent("Pair/a.bin"))
        try makeClone(of: caches.appendingPathComponent("Pair/a.bin"), at: caches.appendingPathComponent("Pair/b.bin"))
        let outside = home.appendingPathComponent("Project/partial.bin")
        try makeClone(of: caches.appendingPathComponent("Pair/a.bin"), at: outside)
        try rewrite(Self.mebibyte, at: Self.mebibyte, in: outside)
        XCTAssertEqual(try known(outside).sharedBytes, Int64(3 * Self.mebibyte))

        for name in ["a.bin", "b.bin"] {
            let isolated = try known(caches.appendingPathComponent("Isolated/\(name)"))
            let paired = try known(caches.appendingPathComponent("Pair/\(name)"))
            XCTAssertEqual(isolated.privateBytes, paired.privateBytes, name)
            XCTAssertEqual(isolated.allocatedDataBytes, paired.allocatedDataBytes, name)
            XCTAssertEqual(isolated.cloneReferenceCount, paired.cloneReferenceCount, name)
            XCTAssertEqual(isolated.mayShareBlocks, paired.mayShareBlocks, name)
        }
        let session = try await scan(home: home, fileSystem: SharingFileSystem())
        for name in ["Isolated", "Pair"] {
            let item = try candidate(name, in: session)
            XCTAssertEqual(item.reclaimableSizeBytes, 0, name)
            XCTAssertEqual(item.reclaimableEstimate?.wholeCloneGroupBytes, Int64(size), name)
        }
    }

    func testIndependentReviewPartialCloneOutsideCandidateKeepsSharedBlocks() async throws {
        let home = try makeRoot().appendingPathComponent("Home")
        let cache = home.appendingPathComponent("Library/Caches/Pair")
        let a = cache.appendingPathComponent("a.bin")
        let b = cache.appendingPathComponent("b.bin")
        let outside = home.appendingPathComponent("Project/partial.bin")
        let size = 4 * Self.mebibyte
        try writeRandom(size, to: a)
        try makeClone(of: a, at: b)
        try makeClone(of: a, at: outside)
        try rewrite(Self.mebibyte, at: Self.mebibyte, in: outside)
        let first = try known(a)
        let second = try known(b)
        let partial = try known(outside)
        XCTAssertEqual(first.cloneID, second.cloneID)
        XCTAssertEqual(first.cloneReferenceCount, 2)
        XCTAssertNotEqual(first.cloneID, partial.cloneID)
        XCTAssertEqual(partial.sharedBytes, Int64(3 * Self.mebibyte))
        let session = try await scan(home: home, fileSystem: SharingFileSystem())
        let pair = try candidate("Pair", in: session)
        print("REVIEW_PARTIAL_OUTSIDE reported=\(pair.reclaimableSizeBytes) stillSharedOutside=\(partial.sharedBytes) expectedMaximum=\(Self.mebibyte)")
        XCTAssertLessThanOrEqual(pair.reclaimableSizeBytes, Int64(Self.mebibyte),
                                "A partial clone outside the candidate still owns three quarters of the blocks")
    }

    func testIndependentReviewSelectionOfTwoCloneCandidatesFreesOneCopy() async throws {
        let home = try makeRoot().appendingPathComponent("Home")
        let caches = home.appendingPathComponent("Library/Caches")
        let a = caches.appendingPathComponent("Left/a.bin")
        let b = caches.appendingPathComponent("Right/b.bin")
        let size = 4 * Self.mebibyte
        try writeRandom(size, to: a)
        try makeClone(of: a, at: b)
        let first = try known(a)
        XCTAssertEqual(first.cloneReferenceCount, 2)
        XCTAssertEqual(first.cloneID, try known(b).cloneID)
        let session = try await scan(home: home, fileSystem: SharingFileSystem())
        let selected = [try candidate("Left", in: session), try candidate("Right", in: session)]
        // Review fix A-R2: CleanupScanViews.selectedReclaimable now reduces the
        // selection with CleanupSelectionReclaimable, which matches full clones
        // across items; after A-R1 the copy is possibly freed, so it is apart.
        let selection = CleanupSelectionReclaimable(candidates: selected)
        let total = CleanupByteCount.adding(selection.possibleCloneBytes, to: selection.freedBytes)
        print("REVIEW_CROSS_CANDIDATE reported=\(total) expected=\(size)")
        XCTAssertEqual(total, Int64(size), "Selecting every full clone must account for one copy across candidates")
        XCTAssertEqual(selection.freedBytes, 0, "A-R1: the copy is not certain")
        XCTAssertEqual(selection.possibleCloneBytes, Int64(size))
        XCTAssertEqual(CleanupSelectionReclaimable(candidates: [selected[0]]).possibleCloneBytes, 0,
                       "One member alone frees nothing while its clone stays")
    }

    /// The selection header reduces the selected rows with the selection
    /// estimate, not row by row.
    func testTheSelectionHeaderMatchesClonesAcrossTheSelectedRows() throws {
        let compact = try XCTUnwrap(
            try SwiftSourceScanning.compactSourceCode()["Sources/StorageCleanerMac/Views/CleanupScanViews.swift"])
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "CleanupSelectionReclaimable(candidates:", in: compact), 1)
        XCTAssertTrue(compact.contains(
            "returnCleanupSelectionReclaimable(candidates:store.cleanupSelection.selectedCandidates(in:session).filter{candidateIDs.contains($0.id)})"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "reclaimableSizeBytes", in: compact), 0)
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "letreclaimable=selectedReclaimable", in: compact), 1)
    }

    func testRowHintNamesTheSnapshotAndFlagsAnOverestimate() {
        let size = Int64(10 * Self.mebibyte)
        let held = makeCandidate(size: size, estimate: CleanupReclaimableEstimate(
            cloneSharedBytes: 0, snapshotHeldBytes: 6 * Int64(Self.mebibyte), unknownBytes: 2 * Int64(Self.mebibyte)))
        let small = makeCandidate(size: size, estimate: CleanupReclaimableEstimate(
            cloneSharedBytes: 512 * 1_024, snapshotHeldBytes: 0, unknownBytes: 512 * 1_024))
        withLanguage(.zhHans) {
            // D178: decimal (was `ByteFormat.string`, binary: "4.0 MiB").
            XCTAssertEqual(CleanupCandidateRowHint.reclaimable(for: held)?.text,
                           "清空废纸篓后预计释放 \(ByteFormat.storageString(4 * Int64(Self.mebibyte)))（可能高估）；其余被本地快照占用，快照过期后释放")
            XCTAssertEqual(CleanupRuleExplanation.lightfieldDetail(
                rebuildCost: "重建慢", reclaimable: "预计释放少", ownerStatus: nil, ownership: "X", path: "/p"),
                "重建慢 · 预计释放少 · 属于 X · /p")
        }
        // "Noticeably" less takes both 1 MiB and a tenth of the size.
        XCTAssertNil(CleanupCandidateRowHint.reclaimable(for: small))
        XCTAssertNil(CleanupCandidateRowHint.reclaimable(for: makeCandidate(
            size: 2 * Int64(Self.mebibyte),
            estimate: CleanupReclaimableEstimate(cloneSharedBytes: 768 * 1_024, snapshotHeldBytes: 0, unknownBytes: 0))))
        XCTAssertNil(CleanupCandidateRowHint.reclaimable(for: makeCandidate(
            size: 100 * Int64(Self.mebibyte),
            estimate: CleanupReclaimableEstimate(cloneSharedBytes: 5 * Int64(Self.mebibyte), snapshotHeldBytes: 0,
                                                 unknownBytes: 5 * Int64(Self.mebibyte)))))
        XCTAssertNil(CleanupCandidateRowHint.reclaimable(for: makeCandidate(size: size, estimate: nil)))
    }

    // MARK: Helpers

    private func known(_ url: URL) throws -> FileStorageSharing {
        guard case let .known(sharing) = FileStorageSharing.read(at: url) else {
            throw XCTSkip("The temporary volume does not report APFS sharing: \(url.path)")
        }
        return sharing
    }

    private func clone(id: UInt64, count: Int, size: Int64) -> FileStorageSharing.Reading {
        .known(FileStorageSharing(privateBytes: 0, allocatedDataBytes: size, cloneID: id,
                                  cloneReferenceCount: count, mayShareBlocks: true))
    }

    private func reply(
        flags: UInt32 = 0, allocated: Int64 = 4_096, privateBytes: Int64 = 4_096, cloneID: UInt64 = 1,
        extendedFlags: UInt64 = 0, cloneCount: UInt32 = 1, omitting omitted: UInt32 = 0
    ) -> [UInt8] {
        let fork = (bits(ATTR_CMNEXT_PRIVATESIZE) | bits(ATTR_CMNEXT_CLONEID) | bits(ATTR_CMNEXT_EXT_FLAGS)
            | bits(ATTR_CMNEXT_CLONE_REFCNT)) & ~omitted
        var body = [UInt8]()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { body.append(contentsOf: $0) }
        }
        append(flags)
        append(allocated)
        if fork & bits(ATTR_CMNEXT_PRIVATESIZE) != 0 { append(privateBytes) }
        if fork & bits(ATTR_CMNEXT_CLONEID) != 0 { append(cloneID) }
        if fork & bits(ATTR_CMNEXT_EXT_FLAGS) != 0 { append(extendedFlags) }
        if fork & bits(ATTR_CMNEXT_CLONE_REFCNT) != 0 { append(cloneCount) }
        var bytes = [UInt8]()
        func put<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        put(UInt32(24 + body.count))
        put(bits(ATTR_CMN_RETURNED_ATTRS) | bits(ATTR_CMN_FLAGS))
        put(UInt32(0))
        put(UInt32(0))
        put(bits(ATTR_FILE_DATAALLOCSIZE))
        put(fork)
        return bytes + body
    }

    private func parse(_ bytes: [UInt8]) -> FileStorageSharing.Reading {
        bytes.withUnsafeBytes { FileStorageSharing.parse($0) }
    }

    private func bits<Value: BinaryInteger>(_ value: Value) -> UInt32 {
        UInt32(truncatingIfNeeded: value)
    }

    private func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        let preferences = TestVolatilePreferences()
        preferences.set(defaults.string(forKey: L10n.languageDefaultsKey) ?? language.rawValue,
            forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
        try body()
    }

    private func makeRoot() throws -> URL {
        let root = TestFileSystem.uniqueRoot("StorageSharing")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeRandom(_ count: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        try data.write(to: url)
    }

    private func makeClone(of source: URL, at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw XCTSkip("clonefile is not supported here (errno \(errno))")
        }
    }

    private func rewrite(_ count: Int, at offset: Int, in url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func scan(home: URL, fileSystem: SharingFileSystem) async throws -> ScanSession {
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: fileSystem,
            ruleSet: CleanupRuleSet(schemaVersion: 2, rulesVersion: "fixture.1", rules: [cacheRule()])
        )
        return try await scanner.scan(request: CleanupScanRequest(userHomeURL: home)) { _ in }
    }

    private func candidate(_ name: String, in session: ScanSession) throws -> ScanCandidate {
        try XCTUnwrap(session.categories.flatMap(\.candidates).first { $0.sourceURL.lastPathComponent == name },
                      name)
    }

    private func cacheRule() -> CleanupRule {
        CleanupRule(
            id: "system.cache", selectionPolicyVersion: 1, categoryID: "system",
            categoryTitleKey: "cleanup.category.system", titleKey: "cleanup.rule.userCaches.title",
            root: CleanupRuleRoot(kind: .homeRelative, path: "Library/Caches"), candidateScope: nil,
            maximumDepth: 4, minimumAgeDays: 0, minimumBytes: 1,
            include: CleanupRuleMatch(entryKinds: [.regularFile, .directory], extensions: [],
                                      nameMatcher: CleanupNameMatcher(mode: .any, values: [])),
            exclude: CleanupRuleExclusion(relativePrefixes: [], extensions: []),
            cloudPolicy: .skipPlaceholder, risk: .safe, recommendation: .recommended,
            defaultSelection: .selected, executionEligibility: .eligible, measurementRequirement: .complete,
            allowsManualSelection: true, action: .moveToTrash, requiredClosedBundleIDs: [],
            reasonKey: "cleanup.rule.userCaches.reason"
        )
    }

    private func makeCandidate(size: Int64, estimate: CleanupReclaimableEstimate?) -> ScanCandidate {
        let url = URL(fileURLWithPath: "/Fixture/cache-\(UUID().uuidString)")
        let snapshot = FileSnapshot(
            identity: FileIdentity(deviceID: 9, inode: 3, entryKind: .directory, creationTimeNanoseconds: 1),
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
}

/// The real file system under a temporary folder, whose path goes through
/// /var -> /private/var; sharing can be replaced to exercise fallbacks.
private struct SharingFileSystem: ReadOnlyFileSystem {
    var override: FileStorageSharing.Reading?

    func snapshot(at url: URL) throws -> FileSnapshot {
        try unlinked(FoundationReadOnlyFileSystem().snapshot(at: url))
    }

    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        try unlinked(FoundationReadOnlyFileSystem().aggregateSnapshot(at: url))
    }

    func children(of directory: URL) throws -> [URL] {
        try FoundationReadOnlyFileSystem().children(of: directory)
    }

    func storageSharing(at url: URL) -> FileStorageSharing.Reading {
        override ?? FoundationReadOnlyFileSystem().storageSharing(at: url)
    }

    private func unlinked(_ snapshot: FileSnapshot) -> FileSnapshot {
        FileSnapshot(
            identity: snapshot.identity, standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier, logicalSizeBytes: snapshot.logicalSizeBytes,
            allocatedSizeBytes: snapshot.allocatedSizeBytes,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume, isCloudItem: snapshot.isCloudItem,
            isCloudPlaceholder: snapshot.isCloudPlaceholder, hasSymbolicLinkComponent: false
        )
    }
}
