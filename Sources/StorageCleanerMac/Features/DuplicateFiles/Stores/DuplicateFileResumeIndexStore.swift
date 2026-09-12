import Darwin
import Foundation

enum DuplicateFileResumeIndexStoreError: Error {
    case invalidData
    case unsafeStoragePath
}

struct DuplicateFileResumeIndexStore: Sendable {
    static let maximumDataBytes = 32 * 1024 * 1024

    let fileURL: URL

    init(fileURL: URL = Self.defaultURL) {
        self.fileURL = fileURL
    }

    func load() -> Data? {
        guard let before = safeRegularFileStatus(),
              before.st_size >= 0,
              before.st_size <= Self.maximumDataBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= Self.maximumDataBytes,
              let after = safeRegularFileStatus(),
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size else {
            return nil
        }
        return data
    }

    func save(_ data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumDataBytes else {
            throw DuplicateFileResumeIndexStoreError.invalidData
        }

        let directory = fileURL.deletingLastPathComponent()
        try ensureSafeDirectory(directory)
        if FileManager.default.fileExists(atPath: fileURL.path), safeRegularFileStatus() == nil {
            throw DuplicateFileResumeIndexStoreError.unsafeStoragePath
        }

        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard safeRegularFileStatus() != nil else {
            throw DuplicateFileResumeIndexStoreError.unsafeStoragePath
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private static var defaultURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("DuplicateFiles", isDirectory: true)
            .appendingPathComponent("resume-index.json", isDirectory: false)
    }

    private func ensureSafeDirectory(_ directory: URL) throws {
        var status = stat()
        if directory.path.withCString({ Darwin.lstat($0, &status) }) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == geteuid() else {
                throw DuplicateFileResumeIndexStoreError.unsafeStoragePath
            }
        } else {
            guard errno == ENOENT else {
                throw DuplicateFileResumeIndexStoreError.unsafeStoragePath
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func safeRegularFileStatus() -> stat? {
        var status = stat()
        guard fileURL.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            return nil
        }
        return status
    }
}
