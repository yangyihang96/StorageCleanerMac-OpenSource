import Darwin
import Foundation

/// D-FP3: everything about a file besides its data that a person or an app
/// can see: permissions, owner, Finder flags, extended attributes (tags,
/// Finder info, quarantine), the ACL and the four dates.
struct FileMetadataCapture: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mode: mode_t
    let uid: uid_t
    let gid: gid_t
    let flags: UInt32
    let linkCount: nlink_t
    let creation: timespec
    let modification: timespec
    let access: timespec
    let added: timespec?
    let xattrs: [String: Data]
    let acl: String?

    static func == (a: Self, b: Self) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size && a.mode == b.mode
            && a.uid == b.uid && a.gid == b.gid && a.flags == b.flags && a.linkCount == b.linkCount
            && equal(a.creation, b.creation) && equal(a.modification, b.modification)
            && equal(a.access, b.access) && optionalEqual(a.added, b.added)
            && a.xattrs == b.xattrs && a.acl == b.acl
    }

    static func equal(_ a: timespec, _ b: timespec) -> Bool { a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec }

    /// The same file with the same content and metadata; reading it (the
    /// access date) does not count as a change.
    func isUnchanged(from other: Self) -> Bool {
        device == other.device && inode == other.inode && size == other.size && mode == other.mode
            && uid == other.uid && gid == other.gid && flags == other.flags && linkCount == other.linkCount
            && Self.equal(creation, other.creation) && Self.equal(modification, other.modification)
            && xattrs == other.xattrs && acl == other.acl
    }

    private static func optionalEqual(_ a: timespec?, _ b: timespec?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?): equal(a, b)
        default: false
        }
    }
}

enum APFSCloneReplacementError: Error, Equatable {
    case posix(String, Int32)
    case metadataMismatch(String)
    case changedBeforeSwap
    case swapUnverified

    var detailCode: String {
        switch self {
        case .posix(let call, let code): "\(call)-\(code)"
        case .metadataMismatch(let what): "metadata-\(what)"
        case .changedBeforeSwap: "changed-before-swap"
        case .swapUnverified: "swap-unverified"
        }
    }
}

/// D-FP3: replaces one file with an APFS clone of another without changing
/// what it looks like. The clone is made beside the copy under a hidden
/// name, given the copy's metadata, checked, and swapped in with
/// `renamex_np(RENAME_SWAP)`, so the path never points at nothing and never
/// at partial data. The copy's own data ends up at the hidden name, which
/// the caller renames and moves to the Trash.
enum APFSCloneReplacement {
    /// User flags copied as they are. A locked or append-only file, or one
    /// with system flags, is not replaced (the caller skips it).
    static let copiedFlags = UInt32(UF_NODUMP) | UInt32(UF_HIDDEN)
    static let refusedUserFlags = UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND) | UInt32(UF_DATAVAULT)
    /// Flags the replacement may differ in without anyone noticing:
    /// compression follows the kept copy's data, tracking is the system's.
    static let ignoredFlags = UInt32(UF_COMPRESSED) | UInt32(UF_TRACKED)
    /// Attributes macOS keeps itself and does not let an app write; they
    /// follow the data and no one sees them. Executables are never merged,
    /// so the provenance of code is never in question.
    static let systemManagedAttributes: Set<String> = ["com.apple.provenance"]

    // MARK: Reading

    static func capture(_ path: String) throws -> FileMetadataCapture {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw APFSCloneReplacementError.posix("lstat", errno) }
        return FileMetadataCapture(
            device: status.st_dev, inode: status.st_ino, size: status.st_size, mode: status.st_mode,
            uid: status.st_uid, gid: status.st_gid, flags: status.st_flags, linkCount: status.st_nlink,
            creation: status.st_birthtimespec, modification: status.st_mtimespec, access: status.st_atimespec,
            added: addedTime(path),
            xattrs: try extendedAttributes(path).filter { !systemManagedAttributes.contains($0.key) },
            acl: aclText(path)
        )
    }

    static func extendedAttributes(_ path: String) throws -> [String: Data] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw APFSCloneReplacementError.posix("listxattr", errno) }
        guard size > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &names, size, XATTR_NOFOLLOW)
        guard read >= 0 else { throw APFSCloneReplacementError.posix("listxattr", errno) }
        var result: [String: Data] = [:]
        for name in names.prefix(read).split(separator: 0).map({ String(cString: Array($0) + [0]) }) {
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { throw APFSCloneReplacementError.posix("getxattr", errno) }
            var value = Data(count: length)
            let got = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
            guard got >= 0 else { throw APFSCloneReplacementError.posix("getxattr", errno) }
            result[name] = value.prefix(got)
        }
        return result
    }

    static func aclText(_ path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        let value = String(cString: text)
        return value.isEmpty ? nil : value
    }

    static func addedTime(_ path: String) -> timespec? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        return withUnsafeTemporaryAllocation(byteCount: 64, alignment: 8) { reply -> timespec? in
            guard getattrlist(path, &request, reply.baseAddress, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else {
                return nil
            }
            let length = reply.load(as: UInt32.self)
            guard length >= UInt32(MemoryLayout<UInt32>.size + MemoryLayout<timespec>.size) else { return nil }
            return reply.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: timespec.self)
        }
    }

    // MARK: Replacing

    /// Clones `keeper` beside `target`, copies `target`'s metadata onto the
    /// clone, swaps them, and returns the hidden path now holding the old
    /// data of `target`. On any failure before the swap the clone is removed
    /// and `target` is untouched.
    static func replace(target: String, withCloneOf keeper: String, expected: FileMetadataCapture) throws -> String {
        let directory = (target as NSString).deletingLastPathComponent
        let hidden = (directory as NSString).appendingPathComponent(".\(UUID().uuidString).sc-clone-merge")
        guard clonefile(keeper, hidden, UInt32(CLONE_NOFOLLOW) | UInt32(CLONE_NOOWNERCOPY)) == 0 else {
            throw APFSCloneReplacementError.posix("clonefile", errno)
        }
        var swapped = false
        defer { if !swapped { unlink(hidden) } }

        try apply(expected, to: hidden)
        let applied = try capture(hidden)
        try verify(applied, matches: expected)

        // The copy must be exactly as it was when it was checked.
        let current = try capture(target)
        guard current.isUnchanged(from: expected) else { throw APFSCloneReplacementError.changedBeforeSwap }

        guard renamex_np(hidden, target, UInt32(RENAME_SWAP)) == 0 else {
            throw APFSCloneReplacementError.posix("renamex_np", errno)
        }
        swapped = true
        var atTarget = stat(), atHidden = stat()
        guard lstat(target, &atTarget) == 0, lstat(hidden, &atHidden) == 0,
              atTarget.st_ino == applied.inode, atHidden.st_ino == expected.inode else {
            throw APFSCloneReplacementError.swapUnverified
        }
        // A rename can touch the dates; set them once more on the new file.
        try setTimes(target, expected)
        return hidden
    }

    static func apply(_ metadata: FileMetadataCapture, to path: String) throws {
        // Extended attributes: exactly the target's, none of the kept copy's.
        for name in try extendedAttributes(path).keys
        where metadata.xattrs[name] == nil && !systemManagedAttributes.contains(name) {
            guard removexattr(path, name, XATTR_NOFOLLOW) == 0 else {
                throw APFSCloneReplacementError.posix("removexattr", errno)
            }
        }
        for (name, value) in metadata.xattrs {
            let result = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
            guard result == 0 else { throw APFSCloneReplacementError.posix("setxattr", errno) }
        }
        // ACL: the target's, or none.
        let acl = metadata.acl.flatMap { acl_from_text($0) } ?? acl_init(0)
        guard let acl else { throw APFSCloneReplacementError.posix("acl", errno) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw APFSCloneReplacementError.posix("acl_set_link_np", errno)
        }
        guard lchown(path, metadata.uid, metadata.gid) == 0 else { throw APFSCloneReplacementError.posix("lchown", errno) }
        guard lchmod(path, metadata.mode & 0o7777) == 0 else { throw APFSCloneReplacementError.posix("lchmod", errno) }
        var status = stat()
        guard lstat(path, &status) == 0 else { throw APFSCloneReplacementError.posix("lstat", errno) }
        let flags = (status.st_flags & ~copiedFlags) | (metadata.flags & copiedFlags)
        guard lchflags(path, flags) == 0 else { throw APFSCloneReplacementError.posix("lchflags", errno) }
        try setTimes(path, metadata)
    }

    static func setTimes(_ path: String, _ metadata: FileMetadataCapture) throws {
        func set(_ times: [timespec], _ common: attrgroup_t) -> Int32 {
            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.commonattr = common
            var values = times
            return values.withUnsafeMutableBytes { buffer in
                setattrlist(path, &request, buffer.baseAddress, buffer.count, UInt32(FSOPT_NOFOLLOW))
            }
        }
        let common = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME)
        let times = [metadata.creation, metadata.modification, metadata.access]
        guard set(times, common) == 0 else { throw APFSCloneReplacementError.posix("setattrlist", errno) }
        // "Date Added" is kept where the file system lets it be set.
        if let added = metadata.added {
            _ = set([added], attrgroup_t(ATTR_CMN_ADDEDTIME))
        }
    }

    /// The clone must look like the target in everything but its inode.
    static func verify(_ applied: FileMetadataCapture, matches expected: FileMetadataCapture) throws {
        guard applied.size == expected.size else { throw APFSCloneReplacementError.metadataMismatch("size") }
        guard applied.mode & 0o7777 == expected.mode & 0o7777 else { throw APFSCloneReplacementError.metadataMismatch("mode") }
        guard applied.uid == expected.uid, applied.gid == expected.gid else {
            throw APFSCloneReplacementError.metadataMismatch("owner")
        }
        let visible = ~ignoredFlags
        guard applied.flags & visible == expected.flags & visible else { throw APFSCloneReplacementError.metadataMismatch("flags") }
        guard applied.xattrs == expected.xattrs else { throw APFSCloneReplacementError.metadataMismatch("xattrs") }
        guard applied.acl == expected.acl else { throw APFSCloneReplacementError.metadataMismatch("acl") }
        guard FileMetadataCapture.equal(applied.creation, expected.creation),
              FileMetadataCapture.equal(applied.modification, expected.modification) else {
            throw APFSCloneReplacementError.metadataMismatch("dates")
        }
    }
}
