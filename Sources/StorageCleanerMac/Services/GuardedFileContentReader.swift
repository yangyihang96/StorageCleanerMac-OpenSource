import CryptoKit
import Darwin
import Foundation

struct GuardedFileContentReader: Sendable {
    var guardPolicy = FileContentReadGuard()
    var pool = FileContentReadPool.shared
    var timeout: TimeInterval = 15
    var priority: FileContentReadPool.Priority = .utility
    /// Runs after the cloud check, on the read worker. Tests can block here
    /// without touching iCloud, a provider directory or a real network volume.
    var willRead: @Sendable (URL) throws -> Void = { _ in }

    final class OpenFile: @unchecked Sendable {
        let url: URL
        let handle: FileHandle
        let snapshot: Snapshot
        // Exactly one sequential reader owns this handle. If a read times out,
        // its closure keeps the handle alive; no other thread closes/reuses it.
        init(url: URL, descriptor: Int32, snapshot: Snapshot) {
            self.url = url
            self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            self.snapshot = snapshot
        }
        deinit { try? handle.close() }
    }

    struct Snapshot: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) throws {
            if status.st_flags & UInt32(SF_DATALESS) != 0 { throw FileContentReadError.cloudOnly }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw FileContentReadError.unsupportedType
            }
            device = Int32(status.st_dev)
            inode = UInt64(status.st_ino)
            size = Int64(status.st_size)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    func checkAvailability(_ url: URL, isDirectory: Bool = false,
                           isCancelled: () -> Bool = { Task.isCancelled }) throws {
        try pool.read(at: url, timeout: timeout, priority: priority, isCancelled: isCancelled) { control in
            try guardPolicy.check(url, isDirectory: isDirectory)
            try control.check()
        }
    }

    func open(_ url: URL, isCancelled: () -> Bool = { Task.isCancelled }) throws -> OpenFile {
        try pool.read(at: url, timeout: timeout, priority: priority, isCancelled: isCancelled) { _ in try openOnWorker(url) }
    }

    func withFile<Value: Sendable>(
        _ url: URL, isCancelled: () -> Bool = { Task.isCancelled },
        _ operation: @escaping @Sendable (OpenFile, FileContentReadPool.Control) throws -> Value
    ) throws -> Value {
        try pool.read(at: url, timeout: timeout, priority: priority, isCancelled: isCancelled) { control in
            let file = try openOnWorker(url)
            try control.check()
            try willRead(url)
            try control.check()
            let value = try operation(file, control)
            try validate(file)
            return value
        }
    }

    func readChunk(_ file: OpenFile, count: Int = 1_048_576,
                   isCancelled: () -> Bool = { Task.isCancelled }) throws -> Data {
        try pool.read(at: file.url, timeout: timeout, priority: priority, isCancelled: isCancelled) { control in
            try guardPolicy.check(file.url)
            try validate(file)
            try willRead(file.url)
            try control.check()
            let data = try file.handle.read(upToCount: count) ?? Data()
            try validate(file)
            return data
        }
    }

    func sha256(_ url: URL, isCancelled: () -> Bool = { Task.isCancelled }) throws -> Data {
        try digestWithSnapshot(url, isCancelled: isCancelled).digest
    }

    func digestWithSnapshot(_ url: URL, isCancelled: () -> Bool = { Task.isCancelled }) throws -> (digest: Data, snapshot: Snapshot) {
        // Bound each read, not the total duration of a multi-gigabyte file.
        // Progressing large copies remain supported on slower external disks.
        let file = try open(url, isCancelled: isCancelled)
        var hasher = SHA256()
        var bytes: Int64 = 0
        while bytes < file.snapshot.size {
            let count = Int(min(1_048_576, file.snapshot.size - bytes))
            let data = try readChunk(file, count: count, isCancelled: isCancelled)
            guard !data.isEmpty else { throw FileContentReadError.changed }
            bytes += Int64(data.count)
            hasher.update(data: data)
        }
        if isCancelled() { throw CancellationError() }
        guard bytes == file.snapshot.size else { throw FileContentReadError.changed }
        return (Data(hasher.finalize()), file.snapshot)
    }

    private func openOnWorker(_ url: URL) throws -> OpenFile {
        try guardPolicy.check(url)
        // Reuse the preview's component-by-component no-follow walk. Checking
        // only O_NOFOLLOW on the leaf would allow a swapped parent symlink.
        let parts = Self.systemAliasPath(url.path).split(separator: "/")
        guard url.isFileURL, url.path.hasPrefix("/"), let name = parts.last,
              !parts.contains(where: { $0 == "." || $0 == ".." }) else {
            throw FileContentReadError.invalidPath
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Self.posixError() }
        defer { Darwin.close(directory) }
        for part in parts.dropLast() {
            let next = part.withCString { Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard next >= 0 else { throw Self.posixError() }
            Darwin.close(directory)
            directory = next
        }
        let descriptor = name.withCString { Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw Self.posixError() }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw Self.posixError() }
            let file = OpenFile(url: url, descriptor: descriptor, snapshot: try Snapshot(status))
            return file
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func validate(_ file: OpenFile) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(file.handle.fileDescriptor, &descriptorStatus) == 0,
              file.url.path.withCString({ lstat($0, &pathStatus) }) == 0 else { throw Self.posixError() }
        guard try Snapshot(descriptorStatus) == file.snapshot,
              try Snapshot(pathStatus) == file.snapshot else { throw FileContentReadError.changed }
    }

    /// macOS's system-owned /var and /tmp aliases are used by Foundation's
    /// temporaryDirectory. Resolve only those exact aliases, never user links.
    static func systemAliasPath(
        _ path: String,
        linkDestination: (String) throws -> String = {
            try FileManager.default.destinationOfSymbolicLink(atPath: $0)
        }
    ) -> String {
        for name in ["var", "tmp"] where path.hasPrefix("/" + name + "/") {
            let alias = "/" + name
            let target = "/private/" + name
            // readlink returns the stored spelling. macOS normally stores
            // "private/var", relative to /, rather than "/private/var".
            // Do not standardize/resolve the result through Foundation: it
            // can strip /private again and put the alias back in the walk.
            guard let destination = try? linkDestination(alias) else { return path }
            if destination == target || destination == "private/" + name {
                return target + path.dropFirst(alias.count)
            }
        }
        return path
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
