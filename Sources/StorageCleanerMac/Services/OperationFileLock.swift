import Darwin
import Foundation

/// Advisory lock shared by cooperating app processes. Never unlink a lock file:
/// replacing its inode would allow two simultaneous owners. Kernel close on
/// process exit releases the lock, including after a crash.
final class OperationFileLock: @unchecked Sendable {
    enum Failure: LocalizedError {
        case busy, unsafePath
        var errorDescription: String? {
            switch self {
            case .busy: L10n.text("另一个软件实例正在处理任务，请等待它结束。", "Another app instance is processing an operation. Wait for it to finish.")
            case .unsafePath: L10n.text("操作锁的安全检查未通过，未开始处理。", "Operation lock validation failed. No operation was started.")
            }
        }
    }
    private let descriptor: Int32

    static func systemAliasResolvedPath(_ path: String) throws -> String {
        for root in ["/var", "/tmp"] where path.hasPrefix(root + "/") {
            var info = stat()
            guard lstat(root, &info) == 0, info.st_uid == 0,
                  info.st_mode & S_IFMT == S_IFLNK else { throw Failure.unsafePath }
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: root)
            guard destination == "private" + root || destination == "/private" + root else { throw Failure.unsafePath }
            return "/private" + path
        }
        return path
    }

    init(directory: URL, name: String, wait: Bool = false) throws {
        let lexical = PathSafety.lexicalPath(directory.path)
        let storagePath = try Self.systemAliasResolvedPath(lexical)
        guard directory.isFileURL, directory.path == lexical || directory.path == storagePath,
              !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw Failure.unsafePath }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.unsafePath }
        defer { close(parent) }
        for component in storagePath.split(separator: "/").map(String.init) {
            var next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                guard mkdirat(parent, component, 0o700) == 0 || errno == EEXIST else { throw Failure.unsafePath }
                next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw Failure.unsafePath }
            close(parent); parent = next
        }
        var directoryInfo = stat()
        guard fstat(parent, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o022 == 0 else { throw Failure.unsafePath }
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(fd); throw Failure.unsafePath
        }
        // Synchronous UI callers fail closed instead of waiting on another
        // process. Production workers may wait without blocking the main thread.
        let options = LOCK_EX | ((wait && !Thread.isMainThread) ? 0 : LOCK_NB)
        while flock(fd, options) != 0 {
            if errno == EINTR { continue }
            let code = errno
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { throw Failure.busy }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
