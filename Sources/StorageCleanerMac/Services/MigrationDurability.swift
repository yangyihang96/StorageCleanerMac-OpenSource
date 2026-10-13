import Darwin
import Foundation

/// Descriptor-relative, no-follow target traversal. fsync each inode and its
/// namespace, then drain the one destination device. A driver that explicitly
/// lacks F_FULLFSYNC gets an observable fsync-only capability result.
struct MigrationDurability: Sendable {
    var flushOperation: @Sendable (Int32, Bool) throws -> Void = { descriptor, _ in
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    var fullSyncOperation: @Sendable (Int32) throws -> Void = { descriptor in
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    var pathInspectionOperation: @Sendable (URL) -> Bool = {
        PathSafety.containsSymbolicLinkComponent(in: $0.path)
    }
    // Only durability has this budget. A blocked syscall remains cancellable
    // by its caller and cleanup still waits for the worker to return.
    var timeout: TimeInterval? = nil

    struct Capability: Sendable {
        let device: Int32
        let fullSync: Bool
        var information: [String] { fullSync ? [] : [MigrationDurability.fallbackInformation] }
    }

    static var fallbackInformation: String {
        L10n.text("该磁盘仅支持系统同步，无法确认设备缓存已刷新。",
                  "This drive supports filesystem sync only. Its device cache flush could not be confirmed.")
    }

    func timeBudget(bytes: Int64, minimum: TimeInterval) -> TimeInterval {
        timeout ?? max(minimum, min(3_600, 60 + Double(max(0, bytes)) / 1_048_576))
    }

    /// Probe a regular inode in the private staging directory before copying.
    /// EIO/permissions/disconnection are errors, never capability downgrades.
    func probe(_ root: URL, progress: () throws -> Void) throws -> Capability {
        let parent = try openParent(root)
        defer { close(parent) }
        let directory = try openChild(root.lastPathComponent, parent: parent, device: nil)
        defer { close(directory) }
        var status = stat()
        guard fstat(directory, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == geteuid() else { throw FileContentReadError.invalidPath }
        let name = ".durability-probe-" + UUID().uuidString
        let descriptor = name.withCString { openat(directory, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor); _ = name.withCString { unlinkat(directory, $0, 0) } }
        try progress()
        try flushOperation(descriptor, false)
        try progress()
        let supported = try deviceBarrier(descriptor)
        try progress()
        guard name.withCString({ unlinkat(directory, $0, 0) }) == 0 else { throw posixError() }
        try flushOperation(directory, true)
        try checkChild(root.lastPathComponent, parent: parent, descriptor: directory)
        return Capability(device: Int32(status.st_dev), fullSync: supported)
    }

    func synchronize(_ root: URL, entries: [GuardedFileCopy.Entry], volumeRoot: URL?, contents: Bool,
                     capability: Capability? = nil, progress: () throws -> Void) throws -> [String] {
        let parent = try openParent(root)
        defer { close(parent) }
        let descriptor = try openChild(root.lastPathComponent, parent: parent, device: nil)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        if let capability, capability.device != Int32(status.st_dev) { throw FileContentReadError.changed }
        // A migrated tree must stay on its selected device. Reject introduced
        // mounts; do not walk or flush an unrelated device inside it.
        var barrier = dup(descriptor)
        guard barrier >= 0 else { throw posixError() }
        defer { close(barrier) }
        var barrierIsDirectory = status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        try walk(descriptor, device: Int32(status.st_dev), contents: contents && !entries.isEmpty,
                 depth: 0, barrier: &barrier, barrierIsDirectory: &barrierIsDirectory, progress: progress)
        if let volumeRoot { try syncParents(parent, root: root, volumeRoot: volumeRoot, device: Int32(status.st_dev), progress: progress) }
        try progress()
        let supported: Bool
        if capability?.fullSync == false { supported = false }
        else { supported = try deviceBarrier(barrier) }
        try progress()
        try checkChild(root.lastPathComponent, parent: parent, descriptor: descriptor)
        return supported ? [] : [Self.fallbackInformation]
    }

    private func walk(_ descriptor: Int32, device: Int32, contents: Bool, depth: Int,
                      barrier: inout Int32, barrierIsDirectory: inout Bool,
                      progress: () throws -> Void) throws {
        try progress()
        guard depth < 128 else { throw FileContentReadError.tooDeep }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        let directory = status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        if directory, contents {
            let duplicate = dup(descriptor)
            guard duplicate >= 0 else { throw posixError() }
            guard let stream = fdopendir(duplicate) else { close(duplicate); throw posixError() }
            defer { closedir(stream) }
            while true {
                try progress()
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw posixError() }
                    break
                }
                let name = withUnsafeBytes(of: &entry.pointee.d_name) {
                    String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                var childStatus = stat()
                guard name.withCString({ fstatat(descriptor, $0, &childStatus, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw posixError() }
                if childStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { continue }
                let child = try openChild(name, parent: descriptor, device: device)
                defer { close(child) }
                try walk(child, device: device, contents: true, depth: depth + 1,
                         barrier: &barrier, barrierIsDirectory: &barrierIsDirectory, progress: progress)
                try checkChild(name, parent: descriptor, descriptor: child)
            }
        }
        if !directory, barrierIsDirectory {
            let duplicate = dup(descriptor)
            guard duplicate >= 0 else { throw posixError() }
            close(barrier); barrier = duplicate; barrierIsDirectory = false
        }
        try flushOperation(descriptor, directory)
        try progress()
    }

    private func syncParents(_ start: Int32, root: URL, volumeRoot: URL, device: Int32,
                             progress: () throws -> Void) throws {
        let limit = volumeRoot.standardizedFileURL
        var path = root.deletingLastPathComponent().standardizedFileURL
        guard path == limit || path.path.hasPrefix(limit.path + "/") else { throw FileContentReadError.invalidPath }
        var current = dup(start)
        guard current >= 0 else { throw posixError() }
        defer { close(current) }
        while true {
            try progress()
            try flushOperation(current, true)
            try progress()
            if path == limit {
                var expected = stat()
                var opened = stat()
                guard limit.path.withCString({ lstat($0, &expected) }) == 0, fstat(current, &opened) == 0,
                      expected.st_dev == opened.st_dev, expected.st_ino == opened.st_ino else { throw FileContentReadError.changed }
                break
            }
            let next = try openChild("..", parent: current, device: device)
            close(current); current = next
            path.deleteLastPathComponent()
        }
    }

    private func openParent(_ root: URL) throws -> Int32 {
        guard root.isFileURL, !pathInspectionOperation(root.deletingLastPathComponent()) else {
            throw FileContentReadError.invalidPath
        }
        let descriptor = root.deletingLastPathComponent().path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    private func openChild(_ name: String, parent: Int32, device: Int32?) throws -> Int32 {
        var before = stat()
        guard name.withCString({ fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw posixError() }
        let directory = before.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        guard directory || before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw FileContentReadError.unsupportedType }
        if let device, Int32(before.st_dev) != device { throw FileContentReadError.invalidPath }
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        }
        guard descriptor >= 0 else { throw posixError() }
        do {
            try checkChild(name, parent: parent, descriptor: descriptor)
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == before.st_dev,
                  opened.st_ino == before.st_ino else { throw FileContentReadError.changed }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func checkChild(_ name: String, parent: Int32, descriptor: Int32) throws {
        var named = stat()
        var opened = stat()
        guard name.withCString({ fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              fstat(descriptor, &opened) == 0, named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            throw FileContentReadError.changed
        }
    }

    private func deviceBarrier(_ descriptor: Int32) throws -> Bool {
        do { try fullSyncOperation(descriptor); return true }
        catch let error as POSIXError where [.ENOTSUP, .ENOSYS, .EINVAL].contains(error.code) { return false }
    }
    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
