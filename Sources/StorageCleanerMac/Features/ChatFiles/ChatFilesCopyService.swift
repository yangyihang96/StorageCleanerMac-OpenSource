import Darwin
import Foundation

struct ChatFilesCopyOutcome: Equatable, Sendable {
    /// Rows whose every file was copied and read back identical, with
    /// where the copies are.
    var verified: [String: String] = [:]
    var failed: [String: String] = [:]
    var copiedBytes: Int64 = 0
}

/// D-FP3: copies videos and files to another drive (Lemon's "file move"),
/// each file read back and compared by SHA-256. The originals stay; only
/// rows whose copy was verified can then go to the Trash, in a separate
/// step the person confirms (as the existing File Move does).
enum ChatFilesCopyService {
    static let folderName = "StorageCleaner Migration"

    static func destination(for row: ChatFilesRow, on volume: URL) -> URL {
        volume.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(L10n.text("聊天文件", "Chat Files"), isDirectory: true)
            .appendingPathComponent(row.app.title, isDirectory: true)
            .appendingPathComponent(row.accountLabel.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
            .appendingPathComponent(row.kind.title, isDirectory: true)
            .appendingPathComponent(row.month ?? L10n.text("未分月份", "Undated"), isDirectory: true)
    }

    static func execute(_ rows: [ChatFilesRow], to volume: URL, availableBytes: Int64,
                        environment: ChatFilesEnvironment = .init(),
                        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) -> ChatFilesCopyOutcome {
        var outcome = ChatFilesCopyOutcome()
        let copyable = rows.filter(\.kind.canBeCopiedElsewhere)
        for row in rows where !row.kind.canBeCopiedElsewhere {
            outcome.failed[row.id] = L10n.text("图片是聊天软件自己的格式，复制到别处打不开，没有复制",
                                               "Pictures are in the chat app's own format and cannot be opened elsewhere; not copied")
        }
        let needed = copyable.reduce(0) { $0 + $1.bytes }
        guard needed + 200 * 1_024 * 1_024 <= availableBytes else {
            for row in copyable { outcome.failed[row.id] = L10n.text("外置盘空间不够", "Not enough space on the drive") }
            return outcome
        }
        for (index, row) in copyable.enumerated() {
            progress(index, copyable.count)
            if Task.isCancelled {
                outcome.failed[row.id] = L10n.text("已停止", "Stopped")
                continue
            }
            let target = destination(for: row, on: volume)
            do {
                var bytes: Int64 = 0
                for folder in row.folders {
                    bytes += try copyTree(URL(fileURLWithPath: folder.path),
                                          into: target.appendingPathComponent(URL(fileURLWithPath: folder.path).lastPathComponent),
                                          environment: environment)
                }
                outcome.copiedBytes += bytes
                outcome.verified[row.id] = target.path
            } catch {
                outcome.failed[row.id] = L10n.text("复制或核对没有通过，原件保持不动（\(error.localizedDescription)）",
                                                   "The copy or its check failed; the originals are untouched (\(error.localizedDescription))")
            }
        }
        progress(copyable.count, copyable.count)
        return outcome
    }

    /// Copies one file or folder; every regular file is flushed to the
    /// drive and compared by SHA-256 with its original. Links are skipped.
    static func copyTree(_ source: URL, into target: URL, environment: ChatFilesEnvironment) throws -> Int64 {
        var status = stat()
        guard lstat(source.path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        switch status.st_mode & S_IFMT {
        case S_IFREG:
            try copyFile(source, to: target, environment: environment)
            return Int64(status.st_size)
        case S_IFDIR:
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var total: Int64 = 0
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                total += try copyTree(child, into: target.appendingPathComponent(child.lastPathComponent), environment: environment)
            }
            return total
        default:
            return 0
        }
    }

    static func copyFile(_ source: URL, to target: URL, environment: ChatFilesEnvironment) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let descriptor = open(target.path, O_RDONLY | O_CLOEXEC)
        if descriptor >= 0 {
            _ = fcntl(descriptor, F_FULLFSYNC)
            close(descriptor)
        }
        guard try environment.digest(source) == environment.digest(target) else {
            try? FileManager.default.removeItem(at: target)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
