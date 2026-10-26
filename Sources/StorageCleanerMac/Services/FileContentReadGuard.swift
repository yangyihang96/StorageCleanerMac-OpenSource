import Darwin
import Foundation

enum FileContentReadError: Error, LocalizedError, Equatable, Sendable {
    case cloudOnly
    case downloading
    case timedOut
    case copyTimedOut
    case writingTimedOut
    case busy
    case protectionUnavailable
    case changed
    case invalidPath
    case unsupportedType
    case tooDeep
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .cloudOnly:
            L10n.text("仅在云端，未读取内容；请先在访达中下载，或跳过此项。",
                      "Only in the cloud; content was not read. Download it in Finder first, or skip this item.")
        case .downloading:
            L10n.text("正在下载，未读取内容；请等待下载完成后重试，或跳过此项。",
                      "Downloading; content was not read. Wait for the download to finish and retry, or skip this item.")
        case .timedOut:
            L10n.text("读取文件超时，已停止等待；请检查磁盘或网络连接后重试。",
                      "Reading the file timed out and waiting stopped. Check the disk or network connection and retry.")
        case .copyTimedOut:
            L10n.text("复制长时间无进展，已停止等待。请检查来源和目标磁盘。",
                      "Copying stalled. Waiting stopped. Check the source and destination disks.")
        case .writingTimedOut:
            L10n.text("目标磁盘写入长时间无响应，已停止等待。请检查目标磁盘。",
                      "Writing to the destination stalled. Waiting stopped. Check the destination disk.")
        case .busy:
            L10n.text("仍有文件读取未响应，已跳过；请检查磁盘或网络连接后重试。",
                      "Some file reads are still unresponsive; this item was skipped. Check the disk or network connection and retry.")
        case .protectionUnavailable:
            L10n.text("无法确认读取不会触发云端下载，已跳过此项。",
                      "A read without triggering a cloud download could not be assured; this item was skipped.")
        case .changed:
            L10n.text("文件在读取期间已变化，请重新扫描。", "The file changed while being read. Scan again.")
        case .invalidPath:
            L10n.text("路径无效或包含不受支持的链接，未读取内容。", "The path is invalid or contains an unsupported link; content was not read.")
        case .unsupportedType:
            L10n.text("包含管道、设备或其他不支持复制的特殊文件，已停止。", "A pipe, device, or other unsupported special file was found. Copying stopped.")
        case .tooDeep:
            L10n.text("文件夹嵌套层级过深，无法安全处理。", "The folder nesting is too deep to process safely.")
        case .fileTooLarge:
            L10n.text("文件或附带资源超过目标磁盘支持的大小。", "The file or its attached resources exceed the size supported by the destination disk.")
        }
    }

    /// Do not expose untranslated POSIX/Cocoa diagnostics in user notices.
    static func userMessage(for error: any Error) -> String {
        if let known = error as? FileContentReadError { return known.localizedDescription }
        // Another task holds the lease: not a permission or disk problem (malware removal, 10-24).
        if let lease = error as? HeavyWorkCoordinator.Error { return lease.localizedDescription }
        if let known = error as? ExternalDriveMigrationError { return known.localizedDescription }
        let outer = error as NSError
        let system = (outer.userInfo[NSUnderlyingErrorKey] as? NSError) ?? outer
        if system.domain == NSPOSIXErrorDomain {
            switch Int32(system.code) {
            case EACCES, EPERM:
                return L10n.text("没有足够权限处理此项目，请在访达中检查权限或锁定状态。", "This item cannot be processed with the current permissions. Check its permissions or locked state in Finder.")
            case ENOSPC, EDQUOT:
                return ExternalDriveMigrationError.insufficientSpace.localizedDescription
            case EROFS, ENODEV, ENXIO, EIO, ENOTCONN, ETIMEDOUT:
                return L10n.text("磁盘或网络无响应、已断开或只读，请检查连接后重试。", "The disk or network is unresponsive, disconnected, or read-only. Check the connection and retry.")
            case ENOTSUP:
                return L10n.text("目标磁盘不支持此文件操作，请选择其他磁盘。", "The destination disk does not support this file operation. Choose another disk.")
            case EFBIG: return FileContentReadError.fileTooLarge.localizedDescription
            case ELOOP: return FileContentReadError.invalidPath.localizedDescription
            case ENOENT:
                return L10n.text("文件或目标文件夹已不存在，请检查来源和目标。", "A file or destination folder is missing. Check the source and destination.")
            case EDEADLK: return FileContentReadError.cloudOnly.localizedDescription
            case EEXIST: return ExternalDriveMigrationError.destinationExists.localizedDescription
            default: break
            }
        }
        return L10n.text("无法完成文件操作，请检查访问权限和磁盘连接后重试。", "The file operation could not be completed. Check access permissions and the disk connection, then retry.")
    }
}

/// The 2c lstat / per-thread policy, shared by every N6 reader. Never calls
/// startDownloadingUbiquitousItem, evictUbiquitousItem or a content coordinator.
struct FileContentReadGuard: Sendable {
    var isPlaceholder: @Sendable (String) -> Bool = Self.isCloudPlaceholder
    var cloudState: @Sendable (URL) throws -> FileContentReadError? = Self.downloadingState
    var needsCloudState: @Sendable (URL, Bool) -> Bool = { url, directory in
        DiskScanner.storageMapNeedsCloudState(
            // The analysis walker probes directories to propagate cloud state.
            // A content reader already has a full path: apply its path rules
            // without that unconditional directory probe (D51④).
            isDirectory: false, isSymbolicLink: false,
            parentIsUbiquitous: false, isDataless: false,
            path: directory ? url.path + "/" : url.path,
            homePath: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    func check(_ url: URL, isDirectory: Bool = false) throws {
        if isPlaceholder(url.path) { throw FileContentReadError.cloudOnly }
        // D51(4): do not query File Provider for ordinary local files.
        if needsCloudState(url, isDirectory), let reason = try cloudState(url) { throw reason }
    }

    /// Bundle signature validation can read any regular file below the bundle.
    /// Inspect flags first, without following links or enumerating placeholders.
    func checkTree(_ url: URL, control: FileContentReadPool.Control, depth: Int = 0) throws {
        try control.check()
        guard depth < 128 else { throw FileContentReadError.tooDeep }
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let kind = status.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFLNK) { return }
        guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG) else { throw FileContentReadError.unsupportedType }
        let directory = kind == mode_t(S_IFDIR)
        try check(url, isDirectory: directory)
        if directory {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try checkTree(child, control: control, depth: depth + 1)
            }
        }
    }

    static func isCloudPlaceholder(_ path: String) -> Bool {
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else { return false }
        return metadata.st_flags & UInt32(SF_DATALESS) != 0
    }

    static func downloadingState(_ url: URL) throws -> FileContentReadError? {
        // A fresh URL avoids an earlier resource-value cache at write recheck.
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey
        ])
        if values.ubiquitousItemIsDownloading == true { return .downloading }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return .cloudOnly
        }
        return nil
    }

    /// Must be set and restored on the *same synchronous worker thread*.
    /// A failure is closed for N6 readers; 2c's compatibility shim may ignore it.
    static func refuseMaterializationOnThisThread() throws -> () -> Void {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        guard previous >= 0,
              setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw FileContentReadError.protectionUnavailable
        }
        return { _ = setiopolicy_np(type, IOPOL_SCOPE_THREAD, previous) }
    }
}

/// A blocked kernel read cannot be interrupted safely by closing its fd on a
/// different thread. Bound the wait and the number of lingering readers instead.
/// ONLY read-only closures belong here: a late worker must never write, publish a
/// migration, or remove an original. Its fd stays owned until its syscall returns.
final class FileContentReadPool: @unchecked Sendable {
    static let shared = FileContentReadPool(maximumReaders: 4)
    enum Priority: Equatable, Sendable { case utility, userInitiated }
    private let maximumReaders: Int
    private let volumeKey: @Sendable (URL) -> String
    private let laneLock = NSLock()
    // All dictionary access is locked; semaphores outlive abandoned workers.
    private var lanes: [String: DispatchSemaphore] = [:]

    init(maximumReaders: Int, volumeKey: @escaping @Sendable (URL) -> String = FileContentReadPool.mountedVolumeKey) {
        self.maximumReaders = max(1, maximumReaders)
        self.volumeKey = volumeKey
    }

    func volumeIdentity(for url: URL) -> String { volumeKey(url) }

    /// A worker must hold this permit until all of its syscalls/cleanup return.
    /// Copy workers use a separate source/destination-pair key; they never put
    /// writes in read(), nor can a stalled destination consume local read slots.
    func reserveSlot(for key: String) throws -> DispatchSemaphore {
        let slots = laneLock.withLock {
            if let lane = lanes[key] { return lane }
            let lane = DispatchSemaphore(value: maximumReaders)
            lanes[key] = lane
            return lane
        }
        guard slots.wait(timeout: .now()) == .success else { throw FileContentReadError.busy }
        return slots
    }

    /// MNT_NOWAIT reads the kernel's cached mount table, never stat() on a
    /// possibly stalled server. Use a private buffer, not getmntinfo's globals.
    static func mountedVolumeKey(_ url: URL) -> String {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0, count < 65_536 else { return "/" }
        var mounts = Array(repeating: statfs(), count: Int(count) + 8)
        let bytes = Int32(mounts.count * MemoryLayout<statfs>.stride)
        let found = mounts.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, bytes, MNT_NOWAIT) }
        guard found > 0 else { return "/" }
        let path = GuardedFileContentReader.systemAliasPath(url.path)
        var best = "/"
        var key = "/"
        for var mount in mounts.prefix(min(Int(found), mounts.count)) {
            let rawName = withUnsafeBytes(of: &mount.f_mntonname) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let name = GuardedFileContentReader.systemAliasPath(rawName)
            if name.count >= best.count, name == "/" || path == name || path.hasPrefix(name + "/") {
                best = name
                // A replacement disk at the same mount point gets new slots.
                key = name + "#" + withUnsafeBytes(of: &mount.f_fsid) { Data($0).base64EncodedString() }
            }
        }
        return key
    }

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func cancel() { lock.withLock { stopped = true } }
        var isCancelled: Bool { lock.withLock { stopped } }
        func check() throws {
            if isCancelled { throw CancellationError() }
        }
    }

    private final class Completion<Value: Sendable>: @unchecked Sendable {
        let lock = NSLock()
        let completed = DispatchSemaphore(value: 0)
        var result: Result<Value, Error>?
        var abandoned = false
        func finish(_ value: Result<Value, Error>) {
            lock.withLock { if !abandoned { result = value } }
            completed.signal()
        }
        func take() -> Result<Value, Error>? { lock.withLock { result } }
        func abandon() { lock.withLock { abandoned = true; result = nil } }
    }

    func read<Value: Sendable>(
        at url: URL = URL(fileURLWithPath: "/"),
        timeout: TimeInterval = 15,
        priority: Priority = .utility,
        isCancelled: () -> Bool = { Task.isCancelled },
        _ operation: @escaping @Sendable (Control) throws -> Value
    ) throws -> Value {
        if isCancelled() { throw CancellationError() }
        let slots = try reserveSlot(for: volumeIdentity(for: url))
        let completion = Completion<Value>()
        let control = Control()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        DispatchQueue.global(qos: priority == .userInitiated ? .userInitiated : .utility).async { [slots] in
            let result = Result {
                try control.check()
                let restore = try FileContentReadGuard.refuseMaterializationOnThisThread()
                defer { restore() }
                let value = try operation(control)
                try control.check()
                return value
            }
            slots.signal()
            completion.finish(result)
        }
        // This synchronous API runs on existing scan/cleanup/preview workers,
        // never the UI actor. Cancellation is checked on the calling task, not
        // on a GCD thread (where Task.isCancelled would always be false).
        while true {
            if isCancelled() {
                control.cancel(); completion.abandon()
                throw CancellationError()
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                control.cancel(); completion.abandon()
                throw FileContentReadError.timedOut
            }
            if let result = completion.take() { return try result.get() }
            _ = completion.completed.wait(timeout: .now() + 0.01)
        }
    }
}
