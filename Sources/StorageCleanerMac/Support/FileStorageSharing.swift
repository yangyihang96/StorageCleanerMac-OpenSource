import Darwin
import Foundation

/// D100 G1: how much of a file deleting it frees at once. Blocks the file
/// shares with an APFS clone, or that a local snapshot holds, stay on disk.
/// Read-only: one `getattrlist` call with public attributes (sys/attr.h),
/// without following links; the file is not opened.
struct FileStorageSharing: Equatable, Sendable {
    /// Data bytes deleting the file frees at once (ATTR_CMNEXT_PRIVATESIZE).
    let privateBytes: Int64
    /// Data bytes allocated to the file (ATTR_FILE_DATAALLOCSIZE). Measured
    /// on the same fork as the private size, unlike the total allocated size.
    let allocatedDataBytes: Int64
    /// Full clones of one another report the same ID (ATTR_CMNEXT_CLONEID).
    let cloneID: UInt64
    /// Full clones of this data, the file itself included; a `cp -c` pair
    /// reports 2 each (ATTR_CMNEXT_CLONE_REFCNT).
    let cloneReferenceCount: Int
    /// EF_MAY_SHARE_BLOCKS: the file was cloned at some point.
    let mayShareBlocks: Bool

    /// Data bytes that stay on disk when the file is deleted.
    var sharedBytes: Int64 { max(0, allocatedDataBytes - privateBytes) }

    /// Shared bytes belong to clones; without any clone, a local snapshot
    /// holds them.
    var sharesWithClones: Bool { cloneReferenceCount > 1 || mayShareBlocks }

    enum Reading: Equatable, Sendable {
        /// The volume reports no private size (it is not APFS, so it has no
        /// clones or local snapshots), or the file holds no data of its own.
        case notReported
        /// The call failed, or the file is compressed: its data is in the
        /// resource fork, which the private size does not describe.
        case unknown
        case known(FileStorageSharing)
    }

    private static let commonAttributes = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
    private static let fileAttributes = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATAALLOCSIZE)
    /// With FSOPT_ATTR_CMN_EXTENDED the fork group carries ATTR_CMNEXT_*.
    private static let extendedAttributes = attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_PRIVATESIZE)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_CLONEID)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_EXT_FLAGS)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_CLONE_REFCNT)
    /// Length, returned set, flags, data allocation, private size, clone ID,
    /// extended flags and clone count: 64 bytes on macOS 27.
    static let replyCapacity = 96

    static func read(at url: URL) -> Reading {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .unknown }
            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.commonattr = commonAttributes
            request.fileattr = fileAttributes
            request.forkattr = extendedAttributes
            return withUnsafeTemporaryAllocation(byteCount: replyCapacity, alignment: 8) { reply in
                let options = UInt32(truncatingIfNeeded: FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
                guard getattrlist(path, &request, reply.baseAddress, reply.count, options) == 0 else {
                    return .unknown
                }
                return parse(UnsafeRawBufferPointer(reply))
            }
        }
    }

    /// Reads a reply laid out as getattrlist(2) describes: its length, the
    /// attribute groups actually returned, then each returned value in group
    /// and bit order, every value starting on a 4-byte boundary.
    static func parse(_ reply: UnsafeRawBufferPointer) -> Reading {
        let header = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
        guard reply.count >= header else { return .unknown }
        let length = min(Int(reply.loadUnaligned(as: UInt32.self)), reply.count)
        guard length >= header else { return .unknown }
        let returned = reply.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: attribute_set_t.self)
        var offset = header

        func value<Value: FixedWidthInteger>(_ type: Value.Type, in group: attrgroup_t, bit: Int32) -> Value? {
            guard group & attrgroup_t(truncatingIfNeeded: bit) != 0 else { return nil }
            let size = MemoryLayout<Value>.size
            guard offset + size <= length else { return nil }
            defer { offset += (size + 3) & ~3 }
            return reply.loadUnaligned(fromByteOffset: offset, as: Value.self)
        }

        let flags = value(UInt32.self, in: returned.commonattr, bit: ATTR_CMN_FLAGS)
        let allocated = value(Int64.self, in: returned.fileattr, bit: ATTR_FILE_DATAALLOCSIZE)
        guard returned.forkattr & attrgroup_t(truncatingIfNeeded: ATTR_CMNEXT_PRIVATESIZE) != 0 else {
            return .notReported
        }
        let privateBytes = value(Int64.self, in: returned.forkattr, bit: ATTR_CMNEXT_PRIVATESIZE)
        let cloneID = value(UInt64.self, in: returned.forkattr, bit: ATTR_CMNEXT_CLONEID)
        let extendedFlags = value(UInt64.self, in: returned.forkattr, bit: ATTR_CMNEXT_EXT_FLAGS)
        let cloneCount = value(UInt32.self, in: returned.forkattr, bit: ATTR_CMNEXT_CLONE_REFCNT)
        guard let flags, let allocated, let privateBytes, let cloneID, let extendedFlags, let cloneCount,
              allocated >= 0, privateBytes >= 0 else {
            return .unknown
        }
        if flags & UInt32(truncatingIfNeeded: SF_DATALESS) != 0 { return .notReported }
        if flags & UInt32(truncatingIfNeeded: UF_COMPRESSED) != 0 { return .unknown }
        return .known(FileStorageSharing(
            privateBytes: privateBytes,
            allocatedDataBytes: allocated,
            cloneID: cloneID,
            cloneReferenceCount: Int(cloneCount),
            mayShareBlocks: extendedFlags & UInt64(truncatingIfNeeded: EF_MAY_SHARE_BLOCKS) != 0
        ))
    }
}
