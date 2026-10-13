import Darwin
import Foundation

/// All operations on one service share this directory identity. Parent aliases
/// such as /var are allowed; the configured root's final component is never a link.
final class BrowserPrivacyRecoveryRoot: @unchecked Sendable {
    private let originalURL: URL
    private let lock = NSLock()
    private var opened: Directory?

    init(url: URL) { originalURL = url.standardizedFileURL }

    func verified(createIfMissing: Bool = false) throws -> Directory {
        try lock.withLock {
            if let opened {
                try opened.validate()
                return opened
            }
            var status = stat()
            if lstat(originalURL.path, &status) != 0 {
                guard errno == ENOENT, createIfMissing else { throw BrowserPrivacyBackupStorageFailure() }
                do {
                    try FileManager.default.createDirectory(at: originalURL, withIntermediateDirectories: true)
                } catch { throw BrowserPrivacyBackupStorageFailure() }
            }
            let directory = try Directory(originalURL: originalURL)
            opened = directory
            return directory
        }
    }

    final class Directory: @unchecked Sendable {
        let url: URL
        let descriptor: Int32
        let device: dev_t
        private let inode: ino_t
        private let originalURL: URL

        fileprivate init(originalURL: URL) throws {
            var before = stat()
            guard lstat(originalURL.path, &before) == 0 else { throw BrowserPrivacyBackupStorageFailure() }
            guard before.st_mode & S_IFMT != S_IFLNK else {
                throw BrowserPrivacyBackupStorageFailure(rootIsSymbolicLink: true)
            }
            let descriptor = Darwin.open(originalURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw BrowserPrivacyBackupStorageFailure() }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid(), status.st_dev == before.st_dev, status.st_ino == before.st_ino else {
                Darwin.close(descriptor)
                throw BrowserPrivacyBackupStorageFailure()
            }
            let canonical = originalURL.resolvingSymlinksInPath().standardizedFileURL
            do {
                try Self.validatePath(originalURL, device: status.st_dev, inode: status.st_ino)
                try Self.validatePath(canonical, device: status.st_dev, inode: status.st_ino)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            self.originalURL = originalURL
            self.url = canonical
            self.descriptor = descriptor
            device = status.st_dev
            inode = status.st_ino
            // The retained descriptor also prevents inode reuse while this
            // service or a source lease still refers to the original root.
        }

        func validate() throws {
            for path in [originalURL, url] {
                try Self.validatePath(path, device: device, inode: inode)
            }
        }

        private static func validatePath(_ path: URL, device: dev_t, inode: ino_t) throws {
            var status = stat()
            guard lstat(path.path, &status) == 0 else { throw BrowserPrivacyBackupStorageFailure() }
            guard status.st_mode & S_IFMT != S_IFLNK else {
                throw BrowserPrivacyBackupStorageFailure(rootIsSymbolicLink: true)
            }
            guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(),
                  status.st_dev == device, status.st_ino == inode else {
                throw BrowserPrivacyBackupStorageFailure()
            }
        }

        var isPrivate: Bool {
            var status = stat()
            return fstat(descriptor, &status) == 0 && status.st_mode & (S_IRWXG | S_IRWXO) == 0
        }

        func makePrivate() throws {
            try validate()
            guard fchmod(descriptor, S_IRWXU) == 0 else { throw BrowserPrivacyBackupStorageFailure() }
            try validate()
        }

        deinit { Darwin.close(descriptor) }
    }
}
