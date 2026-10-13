import Darwin
import Foundation

/// Uses the same per-directory `.lease` / flock convention as SQLite snapshots.
/// All service instances see the lock; no process-wide registry is needed.
final class BrowserPrivacyRecoveryLease: @unchecked Sendable {
    static let tombstonePrefix = ".deleting-"
    private static let namespaceLeaseFileName = ".recovery-namespace.lease"
    // The descriptor is closed exactly once, including when a copied backup
    // handle finishes on a different executor. Every access uses this lock.
    private let lock = NSLock()
    private var descriptor: Int32?
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private let root: BrowserPrivacyRecoveryRoot.Directory

    private init(descriptor: Int32, directoryStatus: stat, root: BrowserPrivacyRecoveryRoot.Directory) {
        self.descriptor = descriptor
        directoryDevice = directoryStatus.st_dev
        directoryInode = directoryStatus.st_ino
        self.root = root
    }

    /// A read-only probe for unfinished-list visibility. Malformed leases
    /// fail closed; a folder from before leases existed is not active.
    static func isInUse(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(SQLiteSnapshotService.leaseFileName)
        let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return errno != ENOENT }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_nlink == 1,
              (status.st_mode & 0o777) == (S_IRUSR | S_IWUSR),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    static func acquire(
        in directory: URL, root verifiedRoot: BrowserPrivacyRecoveryRoot.Directory? = nil
    ) throws -> BrowserPrivacyRecoveryLease {
        // Only live UUID directories are leaseable, never hidden tombstones.
        guard UUID(uuidString: directory.lastPathComponent) != nil else {
            throw SQLiteSnapshotFailure.unavailable
        }
        let root = try verifiedRoot ?? BrowserPrivacyRecoveryRoot(url: directory.deletingLastPathComponent()).verified()
        guard directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == root.url else {
            throw SQLiteSnapshotFailure.unavailable
        }
        return try withNamespaceLock(in: root) {
            try acquireInLiveDirectory(root.url.appendingPathComponent(directory.lastPathComponent), root: root)
        }
    }

    private static func acquireInLiveDirectory(
        _ directory: URL, root: BrowserPrivacyRecoveryRoot.Directory
    ) throws -> BrowserPrivacyRecoveryLease {
        let directoryDescriptor = openat(root.descriptor, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw SQLiteSnapshotFailure.unavailable }
        defer { Darwin.close(directoryDescriptor) }
        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == geteuid() else { throw SQLiteSnapshotFailure.permissionDenied }

        // The namespace lock also covers legacy directories that need their
        // first lease. A deleter cannot rename this directory between opening
        // its descriptor and creating the lease through that descriptor.
        let descriptor = try lockedDescriptor(in: directoryDescriptor, name: SQLiteSnapshotService.leaseFileName)
        var currentStatus = stat()
        guard lstat(directory.path, &currentStatus) == 0,
              currentStatus.st_dev == directoryStatus.st_dev,
              currentStatus.st_ino == directoryStatus.st_ino else {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw SQLiteSnapshotFailure.unavailable
        }
        return BrowserPrivacyRecoveryLease(descriptor: descriptor, directoryStatus: directoryStatus, root: root)
    }

    /// Called with the source lease still held. Rename is within the recovery
    /// root, so removal never exposes an unlocked, partially deleted live path.
    func moveToTombstone(in directory: URL) throws -> URL {
        try lock.withLock {
            guard descriptor != nil else { throw SQLiteSnapshotFailure.unavailable }
            guard let backupID = UUID(uuidString: directory.lastPathComponent),
                  directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == root.url else {
                throw SQLiteSnapshotFailure.unavailable
            }
            return try Self.withNamespaceLock(in: root) {
                var status = stat()
                guard lstat(directory.path, &status) == 0,
                      status.st_mode & S_IFMT == S_IFDIR,
                      status.st_dev == directoryDevice, status.st_ino == directoryInode else {
                    throw SQLiteSnapshotFailure.unavailable
                }
                let tombstone = root.url.appendingPathComponent(
                    Self.tombstonePrefix + backupID.uuidString + "-" + UUID().uuidString, isDirectory: true
                )
                guard renameat(root.descriptor, directory.lastPathComponent, root.descriptor, tombstone.lastPathComponent) == 0 else {
                    // A failure to write the tombstone name belongs to the
                    // recovery root, unless the source itself disappeared.
                    var currentStatus = stat()
                    guard lstat(directory.path, &currentStatus) == 0,
                          currentStatus.st_dev == directoryDevice,
                          currentStatus.st_ino == directoryInode else {
                        throw SQLiteSnapshotFailure.unavailable
                    }
                    throw BrowserPrivacyBackupStorageFailure()
                }
                return tombstone
            }
        }
    }

    /// This root-level file is never removed by backup cleanup. Its lock is
    /// held only while opening/creating a child lease or renaming a child,
    /// never while copying a database or recursively removing a tombstone.
    private static func withNamespaceLock<Result>(
        in root: BrowserPrivacyRecoveryRoot.Directory, _ body: () throws -> Result
    ) throws -> Result {
        try root.validate()
        let namespaceDescriptor: Int32
        do {
            namespaceDescriptor = try lockedDescriptor(in: root.descriptor, name: namespaceLeaseFileName)
        } catch {
            throw BrowserPrivacyBackupStorageFailure()
        }
        defer {
            flock(namespaceDescriptor, LOCK_UN)
            Darwin.close(namespaceDescriptor)
        }
        try root.validate()
        let result = try body()
        try root.validate()
        return result
    }

    private static func lockedDescriptor(in directoryDescriptor: Int32, name: String) throws -> Int32 {
        let descriptor = openat(directoryDescriptor, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SQLiteSnapshotFailure.permissionDenied }
        var leaseStatus = stat()
        guard fstat(descriptor, &leaseStatus) == 0,
              leaseStatus.st_mode & S_IFMT == S_IFREG,
              leaseStatus.st_uid == geteuid(),
              leaseStatus.st_nlink == 1,
              (leaseStatus.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else {
            Darwin.close(descriptor)
            throw SQLiteSnapshotFailure.permissionDenied
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw SQLiteSnapshotFailure.busy
        }
        return descriptor
    }

    func release() {
        lock.withLock {
            guard let descriptor else { return }
            self.descriptor = nil
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    deinit { release() }
}
