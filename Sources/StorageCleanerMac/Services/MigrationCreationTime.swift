import Darwin
import Foundation

/// Only birth-time fidelity is informational. It is not authority for content
/// verification or removing an original. All writes still target the copy.
struct MigrationCreationTime: Sendable {
    var write: @Sendable (URL, GuardedFileCopy.Timestamp) -> Int32 = { url, timestamp in
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var value = timestamp.value
        return url.path.withCString {
            setattrlist($0, &attributes, &value, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
        }
    }
    var precision: @Sendable (URL) -> Int = { Self.nanosecondQuantum(at: $0) }

    static func matches(_ requested: GuardedFileCopy.Timestamp, _ stored: GuardedFileCopy.Timestamp,
                        quantum: Int) -> Bool {
        // FAT keeps birth times in 2-second units, so compare whole quanta of
        // the total time rather than nanoseconds within an equal second.
        let unit = Int64(max(1, min(2_000_000_000, quantum)))
        func quanta(_ time: GuardedFileCopy.Timestamp) -> Int64 {
            let total = Int64(time.seconds) * 1_000_000_000 + Int64(time.nanoseconds)
            return total >= 0 ? total / unit : (total - unit + 1) / unit
        }
        return quanta(requested) == quanta(stored)
    }

    /// Query the actual cached mount type, not a UI label or the source volume.
    /// The reviewed HFS/FSKit exFAT drivers expose birth times to seconds; FAT
    /// (msdos) measured at 2-second granularity.
    /// Unknown drivers retain exact comparison and an informational readback.
    private static func nanosecondQuantum(at url: URL) -> Int {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0, count < 65_536 else { return 1 }
        var mounts = Array(repeating: statfs(), count: Int(count) + 8)
        let bytes = Int32(mounts.count * MemoryLayout<statfs>.stride)
        let found = mounts.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, bytes, MNT_NOWAIT)
        }
        guard found > 0 else { return 1 }
        let path = GuardedFileContentReader.systemAliasPath(url.path)
        var bestLength = -1
        var quantum = 1
        for index in 0..<min(Int(found), mounts.count) {
            let mount = withUnsafeBytes(of: &mounts[index].f_mntonname) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard (mount == "/" || path == mount || path.hasPrefix(mount + "/")), mount.count > bestLength else { continue }
            let type = withUnsafeBytes(of: &mounts[index].f_fstypename) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self).lowercased()
            }
            bestLength = mount.count
            quantum = type == "msdos" ? 2_000_000_000 : ["hfs", "exfat"].contains(type) ? 1_000_000_000 : 1
        }
        return quantum
    }
}
