import Darwin
import Foundation

/// Owns a private staging directory before a copy can leave partial output.
/// The caller must validate the selected volume and its parent path first.
struct MigrationStagingDirectory: Sendable {
    let url: URL
    private let identity: TrashItemIdentity

    init(parentURL: URL, fileManager: FileManager = .default) throws {
        guard parentURL.isFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = parentURL.appendingPathComponent(
            ".storagecleaner-\(UUID().uuidString).partial", isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        self.url = directory
        guard let identity = TrashItemIdentity.capture(at: directory) else { throw CleanupMoveError.unsafeQuarantineRoot }
        self.identity = identity
    }

    /// Throws if the volume is gone or cleanup fails; never searches by prefix
    /// or removes any sibling directory.
    func remove() throws {
        guard TrashItemIdentity.capture(at: url) == identity,
              !PathSafety.containsSymbolicLinkComponent(in: url.path) else { throw CleanupMoveError.unsafeQuarantineRoot }
        try Self.removeOwnedTree(at: url, expectedIdentity: identity)
    }

    /// Only for the caller's private, never-published output. A copied 0555
    /// directory or uchg item must not strand staging. Never follow links.
    static func removeOwnedTree(at url: URL, expectedIdentity: TrashItemIdentity? = nil) throws {
        guard let identity = expectedIdentity ?? TrashItemIdentity.capture(at: url) else { return }
        let parent = url.deletingLastPathComponent()
        guard !PathSafety.containsSymbolicLinkComponent(in: parent.path) else { throw CleanupMoveError.unsafeQuarantineRoot }
        let descriptor = parent.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        try removeChild(url.lastPathComponent, from: descriptor, expectedIdentity: identity)
    }

    private static func removeChild(_ name: String, from parent: Int32, expectedIdentity: TrashItemIdentity? = nil) throws {
        var before = stat()
        guard name.withCString({ fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        if let expectedIdentity {
            guard UInt64(bitPattern: Int64(before.st_dev)) == expectedIdentity.deviceID,
                  UInt64(before.st_ino) == expectedIdentity.fileID,
                  UInt16(before.st_mode & mode_t(S_IFMT)) == expectedIdentity.objectType,
                  Int64(before.st_birthtimespec.tv_sec) == expectedIdentity.birthTimeSeconds,
                  Int64(before.st_birthtimespec.tv_nsec) == expectedIdentity.birthTimeNanoseconds else {
                throw CleanupMoveError.unsafeQuarantineRoot
            }
        }
        let kind = before.st_mode & mode_t(S_IFMT)
        if kind != mode_t(S_IFLNK) {
            let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (kind == mode_t(S_IFDIR) ? O_DIRECTORY : 0)
            let descriptor = name.withCString { openat(parent, $0, flags) }
            guard descriptor >= 0 else { throw posixError() }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, before.st_dev == opened.st_dev, before.st_ino == opened.st_ino,
                  opened.st_uid == geteuid() else {
                throw CleanupMoveError.unsafeQuarantineRoot
            }
            let blocking = opened.st_flags & GuardedFileCopy.renameBlockingFlags
            if blocking != 0 {
                // Never change flags through a hard link to another owned tree.
                guard kind == mode_t(S_IFDIR) || opened.st_nlink == 1 else { throw CleanupMoveError.unsafeQuarantineRoot }
                guard fchflags(descriptor, opened.st_flags & ~GuardedFileCopy.renameBlockingFlags) == 0 else { throw posixError() }
            }
            try removeDeletionDenials(from: descriptor, status: opened)
            if kind == mode_t(S_IFDIR) {
                guard fchmod(descriptor, (opened.st_mode & 0o7777) | 0o700) == 0 else { throw posixError() }
                let duplicate = dup(descriptor)
                guard duplicate >= 0 else { throw posixError() }
                guard let directory = fdopendir(duplicate) else { close(duplicate); throw posixError() }
                var children: [String] = []
                var readError: POSIXError?
                while true {
                    errno = 0
                    guard let entry = readdir(directory) else {
                        if errno != 0 { readError = posixError() }
                        break
                    }
                    let child = withUnsafeBytes(of: &entry.pointee.d_name) {
                        String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
                    }
                    if child != ".", child != ".." { children.append(child) }
                }
                closedir(directory)
                if let readError { throw readError }
                for child in children { try removeChild(child, from: descriptor) }
            }
        }
        var current = stat()
        guard name.withCString({ fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
              before.st_dev == current.st_dev, before.st_ino == current.st_ino,
              name.withCString({ unlinkat(parent, $0, kind == mode_t(S_IFDIR) ? AT_REMOVEDIR : 0) }) == 0 else {
            throw posixError()
        }
    }

    /// The caller owns this never-published tree. Preserve unrelated ACL entries
    /// and never modify an inode shared by a hard link outside the tree.
    private static func removeDeletionDenials(from descriptor: Int32, status: stat) throws {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if [ENOENT, ENOTSUP, EINVAL].contains(errno) { return }
            throw posixError()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var changed = false
        var entry: acl_entry_t?
        var cursor = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, cursor, &entry) == 0 {
            cursor = ACL_NEXT_ENTRY.rawValue
            guard let entry else { throw POSIXError(.EIO) }
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0,
                  acl_get_permset(entry, &permissions) == 0, let permissions else { throw posixError() }
            if tag == ACL_EXTENDED_DENY,
               acl_get_perm_np(permissions, ACL_DELETE) == 1 || acl_get_perm_np(permissions, ACL_DELETE_CHILD) == 1 {
                guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) || status.st_nlink == 1 else {
                    throw CleanupMoveError.unsafeQuarantineRoot
                }
                guard acl_delete_entry(acl, entry) == 0 else { throw posixError() }
                changed = true
                // Deletion invalidates the iterator. Start again in this ACL.
                cursor = ACL_FIRST_ENTRY.rawValue
            }
        }
        if changed, acl_set_fd(descriptor, acl) != 0 { throw posixError() }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
