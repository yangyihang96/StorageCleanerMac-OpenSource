import Foundation

/// D100 G1: what cleaning an item frees once the Trash is emptied. It is less
/// than the item's allocated size when files inside share blocks with clones
/// or a local snapshot holds them. Sharing is read per file only while
/// cleanup items are measured; the whole-disk scan does not read it.
///
/// Review A-R1: a full clone's reference count says how many files share its
/// data, not whether a partial clone or a snapshot elsewhere still holds
/// some of the blocks; no read-only call says that. So blocks shared with
/// clones never count as freed, even when every full clone is inside, and
/// one copy of such a group is kept apart as possibly freed.
struct CleanupReclaimableEstimate: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case sharedWithClones
        case heldBySnapshot
    }

    /// Bytes shared with clones, wherever the clones are.
    let cloneSharedBytes: Int64
    /// Bytes a local snapshot holds until it expires.
    let snapshotHeldBytes: Int64
    /// Allocated bytes of files whose sharing could not be read. They count
    /// as freed, so the estimate is high by at most this much.
    let unknownBytes: Int64
    /// One copy of each group of full clones that lies wholly inside the
    /// item. It is freed too unless a partial clone or a snapshot elsewhere
    /// holds the blocks, which cannot be read; part of `cloneSharedBytes`.
    var wholeCloneGroupBytes: Int64 = 0
    /// Review A-R2: groups of full clones with members outside the item, so
    /// a selection that holds every member can count one copy. At most
    /// `CleanupCloneGroupShare.retainedLimit`, largest first; one left out
    /// only makes a selection's possible amount smaller.
    var cloneGroupsReachingOutside: [CleanupCloneGroupShare] = []

    var retainedBytes: Int64 { CleanupByteCount.adding(cloneSharedBytes, to: snapshotHeldBytes) }

    func reclaimableBytes(ofAllocated allocated: Int64) -> Int64 {
        max(0, allocated - min(max(0, allocated), retainedBytes))
    }

    /// The larger of the two causes, or nil when nothing is retained.
    var reason: Reason? {
        guard retainedBytes > 0 else { return nil }
        return cloneSharedBytes >= snapshotHeldBytes ? .sharedWithClones : .heldBySnapshot
    }

    /// "Noticeably" (plan G1 step 4): at least 1 MB and a tenth of the size.
    /// D178: 1 MB written and counted in decimal, as Finder does (was 1 MiB).
    static func isNoticeable(_ bytes: Int64, of size: Int64) -> Bool {
        bytes >= 1_000_000 && bytes >= size / 10
    }

    /// D104 G1: the estimate for one regular file listed outside a cleanup
    /// scan (a large file, a file to move to the Trash), with `allocatedBytes`
    /// its listed size. Nil when the volume reports no sharing. Clone IDs are
    /// per volume, so files matched with each other need their `deviceID`.
    static func file(_ reading: FileStorageSharing.Reading, allocatedBytes: Int64,
                     deviceID: UInt64 = 0) -> CleanupReclaimableEstimate? {
        guard reading != .notReported else { return nil }
        var tally = CleanupReclaimableTally()
        tally.record(reading, allocatedBytes: allocatedBytes, deviceID: deviceID)
        return tally.estimate
    }
}

/// Files that are full clones of each other share one clone ID per volume;
/// the reference count is how many files share it.
struct CleanupCloneGroupKey: Hashable, Sendable {
    let deviceID: UInt64
    let cloneID: UInt64
}

/// A group of full clones as seen inside an item or a selection.
struct CleanupCloneGroupShare: Equatable, Sendable {
    /// Groups kept per item for selections; the rest are left out.
    static let retainedLimit = 1_024

    let key: CleanupCloneGroupKey
    /// Members counted; the scan counts each file once (hard links included).
    var members: Int
    var referenceCount: Int
    /// One copy of the shared data.
    var sharedBytes: Int64

    var isWhole: Bool { members >= referenceCount }

    mutating func merge(_ other: CleanupCloneGroupShare) {
        members += other.members
        referenceCount = max(referenceCount, other.referenceCount)
        sharedBytes = max(sharedBytes, other.sharedBytes)
    }
}

/// D100 G1: tallies an item's files while it is measured, merged upward the
/// same way as its sizes.
struct CleanupReclaimableTally: Equatable, Sendable {
    typealias CloneKey = CleanupCloneGroupKey
    typealias CloneGroup = CleanupCloneGroupShare

    private(set) var cloneSharedBytes: Int64 = 0
    private(set) var snapshotHeldBytes: Int64 = 0
    private(set) var unknownBytes: Int64 = 0
    /// Full clones seen inside the item.
    private(set) var cloneGroups: [CloneKey: CloneGroup] = [:]

    /// Records one regular file, counted once (hard links are already
    /// deduplicated by the walk) with `allocatedBytes` in the item's size.
    mutating func record(_ reading: FileStorageSharing.Reading, allocatedBytes: Int64, deviceID: UInt64) {
        switch reading {
        case .notReported:
            return
        case .unknown:
            unknownBytes = CleanupByteCount.adding(max(0, allocatedBytes), to: unknownBytes)
        case let .known(sharing):
            // Never retain more than the file adds to the item's size.
            let shared = min(sharing.sharedBytes, max(0, allocatedBytes))
            guard shared > 0 else { return }
            guard sharing.sharesWithClones else {
                snapshotHeldBytes = CleanupByteCount.adding(shared, to: snapshotHeldBytes)
                return
            }
            cloneSharedBytes = CleanupByteCount.adding(shared, to: cloneSharedBytes)
            guard sharing.cloneReferenceCount > 1 else { return }
            let key = CloneKey(deviceID: deviceID, cloneID: sharing.cloneID)
            let member = CloneGroup(key: key, members: 1, referenceCount: sharing.cloneReferenceCount,
                                    sharedBytes: shared)
            cloneGroups[key, default: CloneGroup(key: key, members: 0, referenceCount: 0, sharedBytes: 0)]
                .merge(member)
        }
    }

    mutating func add(_ other: CleanupReclaimableTally) {
        cloneSharedBytes = CleanupByteCount.adding(other.cloneSharedBytes, to: cloneSharedBytes)
        snapshotHeldBytes = CleanupByteCount.adding(other.snapshotHeldBytes, to: snapshotHeldBytes)
        unknownBytes = CleanupByteCount.adding(other.unknownBytes, to: unknownBytes)
        cloneGroups.merge(other.cloneGroups) { mine, theirs in
            var merged = mine
            merged.merge(theirs)
            return merged
        }
    }

    /// Blocks shared with clones count as kept (review A-R1); a whole group
    /// of full clones is kept apart as possibly freed once. Partial clones
    /// are not matched with each other, so the estimate errs low there.
    var estimate: CleanupReclaimableEstimate {
        let whole = cloneGroups.values.filter(\.isWhole)
            .reduce(Int64(0)) { CleanupByteCount.adding($1.sharedBytes, to: $0) }
        let reachingOutside = cloneGroups.values.filter { !$0.isWhole }
            .sorted { ($0.sharedBytes, $1.key.deviceID, $1.key.cloneID) > ($1.sharedBytes, $0.key.deviceID, $0.key.cloneID) }
            .prefix(CloneGroup.retainedLimit)
        return CleanupReclaimableEstimate(
            cloneSharedBytes: cloneSharedBytes,
            snapshotHeldBytes: snapshotHeldBytes,
            unknownBytes: unknownBytes,
            wholeCloneGroupBytes: min(whole, cloneSharedBytes),
            cloneGroupsReachingOutside: Array(reachingOutside)
        )
    }
}

/// Review A-R2: what a selection frees once the Trash is emptied. Items are
/// added as they are; groups of full clones are matched across them, by
/// volume and clone ID, so a group whose every member is selected counts
/// one copy, as possibly freed (review A-R1). One member alone counts none.
struct CleanupSelectionReclaimable: Equatable, Sendable {
    /// The items' sizes less blocks shared with clones or held by a snapshot.
    let freedBytes: Int64
    /// One copy of each group of full clones wholly inside the selection;
    /// freed too unless a partial clone or a snapshot elsewhere holds it.
    let possibleCloneBytes: Int64

    init(candidates: some Sequence<ScanCandidate>) {
        self.init(items: candidates.lazy.map { (size: $0.estimatedSizeBytes, estimate: $0.reclaimableEstimate) })
    }

    /// D104 G1: the same for items listed outside a cleanup scan, each with
    /// its size and estimate; an item without one counts its whole size.
    init(items: some Sequence<(size: Int64, estimate: CleanupReclaimableEstimate?)>) {
        var size: Int64 = 0
        var freed: Int64 = 0
        var whole: Int64 = 0
        var groups: [CleanupCloneGroupKey: CleanupCloneGroupShare] = [:]
        for item in items {
            size = CleanupByteCount.adding(item.size, to: size)
            freed = CleanupByteCount.adding(
                item.estimate?.reclaimableBytes(ofAllocated: item.size) ?? item.size, to: freed)
            guard let estimate = item.estimate else { continue }
            whole = CleanupByteCount.adding(estimate.wholeCloneGroupBytes, to: whole)
            for group in estimate.cloneGroupsReachingOutside {
                groups[group.key, default: CleanupCloneGroupShare(key: group.key, members: 0, referenceCount: 0,
                                                                  sharedBytes: 0)]
                    .merge(group)
            }
        }
        freedBytes = freed
        let possible = groups.values.filter(\.isWhole)
            .reduce(whole) { CleanupByteCount.adding($1.sharedBytes, to: $0) }
        possibleCloneBytes = min(possible, max(0, size - freed))
    }

    /// What a selection of `selectedBytes` frees once the Trash is emptied,
    /// with what whole clone groups may add; nil unless that is noticeably
    /// less than `selectedBytes`. D104: shared by the scan results and the
    /// project-artifact page.
    func note(ofSelected selectedBytes: Int64) -> String? {
        let kept = selectedBytes - freedBytes
        guard CleanupReclaimableEstimate.isNoticeable(kept, of: selectedBytes) else { return nil }
        let possible = CleanupReclaimableEstimate.isNoticeable(possibleCloneBytes, of: kept)
            ? L10n.text(
                "，所选完整克隆另可能释放 \(ByteFormat.storageString(possibleCloneBytes))",
                ", plus up to \(ByteFormat.storageString(possibleCloneBytes)) from clones selected together"
            )
            : ""
        return L10n.text(
            "清空废纸篓后预计释放 \(ByteFormat.storageString(freedBytes))\(possible)",
            "about \(ByteFormat.storageString(freedBytes)) freed after emptying the Trash\(possible)"
        )
    }
}
