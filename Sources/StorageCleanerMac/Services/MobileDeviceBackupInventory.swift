import Darwin
import Foundation

/// D116 G11：iPhone、iPad 备份的只读盘点。只列出默认位置下的备份文件夹，
/// 读每个备份里 Status.plist、Manifest.plist（缺信息时再读 Info.plist）中的
/// 设备名、系统版本、备份时间和是否加密，并按已分配空间统计大小。不打开其他
/// 备份文件、不跟随符号链接、不删除也不移动任何东西：备份可能是设备数据唯一
/// 的副本，删除交给访达的“管理备份”。读取默认位置需要完全磁盘访问权限。
struct MobileDeviceBackup: Identifiable, Equatable, Sendable {
    /// 备份文件夹名（通常是设备标识），只作内部标识，界面不显示。
    let id: String
    /// 备份文件夹的位置，用于“在访达中显示”。
    let location: String
    let deviceName: String?
    /// 例如 “18.1”；读不到或格式不对时为 nil。
    let systemVersion: String?
    let backupDate: Date?
    /// nil 表示读不到。
    let isEncrypted: Bool?
    /// Status.plist 记录上次备份没有完成。
    let isUnfinished: Bool
    /// 这个备份全部文件的本地占用；与其他备份硬链接共用的文件按完整大小算进每个备份。
    let bytes: Int64
    /// 其中与其他备份硬链接共用的部分；合计只算一次。
    let sharedBytes: Int64
    let fileCount: Int
    /// 有文件夹读不了、层级过深被跳过或盘点中途停止：大小是下限。
    let isIncomplete: Bool
}

enum MobileDeviceBackupFolderState: Equatable, Sendable {
    case absent
    case readable
    /// 备份文件夹本身是符号链接（例如指向外置盘）：不跟随，未读取。
    case symbolicLink(destination: String?)
    /// 家目录以下的某一层上级是符号链接：不跟随，未读取。
    case linkedAncestor(path: String, destination: String?)
    /// 列不出内容：通常是还没有给本 App 完全磁盘访问权限。
    case unreadable
}

struct MobileDeviceBackupInventory: Equatable, Sendable {
    let rootPath: String
    let rootState: MobileDeviceBackupFolderState
    let backups: [MobileDeviceBackup]
    /// 所有备份的本地占用合计，硬链接共用的文件只计一次。
    let totalBytes: Int64
    /// 遇到并跳过的符号链接（不跟随，也不计入大小）。
    let skippedSymbolicLinkCount: Int
    let unreadableFolderCount: Int
    let skippedDeepFolderCount: Int
    /// 达到条目上限或被取消：之后的内容都没有读。
    let stoppedEarly: Bool

    var isIncomplete: Bool { stoppedEarly || unreadableFolderCount > 0 || skippedDeepFolderCount > 0 }
}

struct MobileDeviceBackupInventoryScanner: Sendable {
    static let relativeRootPath = "Library/Application Support/MobileSync/Backup"

    let homePath: String
    /// 单次盘点最多处理的文件夹和条目数，防止异常目录拖住界面。
    var entryLimit = 2_000_000
    /// 新备份是两层（<备份>/<两位十六进制>/<文件>），旧备份是一层；超过这个层级的只跳过那一棵子树。
    var maximumDepth = 16
    /// Status.plist、Manifest.plist 最多读取的字节数。
    var plistByteLimit = 8 << 20
    /// Info.plist 可能带应用图标，上限放宽；只在前两个文件缺信息时才读。
    var infoPlistByteLimit = 32 << 20
    var isCancelled: @Sendable () -> Bool = { Task.isCancelled }

    init(homePath: String = PathSafety.homePath) {
        self.homePath = homePath
    }

    var rootPath: String {
        (homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath) + "/" + Self.relativeRootPath
    }

    func scan() -> MobileDeviceBackupInventory {
        let root = rootPath
        var context = Context(limit: entryLimit, isCancelled: isCancelled)
        let state: MobileDeviceBackupFolderState
        switch LocalModelInventoryScanner(homePath: homePath).rootState(root).state {
        case .absent: state = .absent
        case let .symbolicLink(destination): state = .symbolicLink(destination: destination)
        case let .linkedAncestor(path, destination): state = .linkedAncestor(path: path, destination: destination)
        case .unreadable, .sameAs: state = .unreadable
        case .scanned: state = .readable
        }
        guard state == .readable, context.consume() else {
            return Self.inventory(root: root, state: state, walks: [], context: context)
        }
        guard let names = context.list(root) else {
            return Self.inventory(root: root, state: .unreadable, walks: [], context: context)
        }

        var walks = [(backup: Pending, walk: Walk)]()
        for name in names.sorted() where !name.hasPrefix(".") {
            guard context.consume() else { break }
            let folder = root + "/" + name
            guard let status = Self.lstatus(folder) else { continue }
            if Self.kind(status) == S_IFLNK {
                context.skippedSymbolicLinks += 1
                continue
            }
            guard Self.kind(status) == S_IFDIR else { continue }
            let metadata = readMetadata(in: folder)
            let measured = walk(folder, context: &context)
            walks.append((Pending(id: name, location: folder, metadata: metadata), measured))
            if context.isStopped { break }
        }
        return Self.inventory(root: root, state: .readable, walks: walks, context: context)
    }

    // MARK: - Metadata

    struct Metadata: Equatable, Sendable {
        var deviceName: String?
        var systemVersion: String?
        var backupDate: Date?
        var isEncrypted: Bool?
        var isUnfinished = false
    }

    /// 只取界面要显示的几项；序列号、电话号码、设备标识等其他内容读到也不保留。
    func readMetadata(in folder: String) -> Metadata {
        var metadata = Metadata()
        if let status = propertyList(at: folder + "/Status.plist", byteLimit: plistByteLimit) {
            metadata.backupDate = status["Date"] as? Date
            if let snapshot = status["SnapshotState"] as? String { metadata.isUnfinished = snapshot != "finished" }
        }
        if let manifest = propertyList(at: folder + "/Manifest.plist", byteLimit: plistByteLimit) {
            metadata.isEncrypted = manifest["IsEncrypted"] as? Bool
            metadata.backupDate = metadata.backupDate ?? manifest["Date"] as? Date
            if let lockdown = manifest["Lockdown"] as? [String: Any] {
                metadata.deviceName = Self.displayName(lockdown["DeviceName"])
                metadata.systemVersion = Self.systemVersion(lockdown["ProductVersion"])
            }
        }
        if metadata.deviceName == nil || metadata.systemVersion == nil || metadata.backupDate == nil,
           let info = propertyList(at: folder + "/Info.plist", byteLimit: infoPlistByteLimit) {
            metadata.deviceName = metadata.deviceName
                ?? Self.displayName(info["Device Name"]) ?? Self.displayName(info["Display Name"])
            metadata.systemVersion = metadata.systemVersion ?? Self.systemVersion(info["Product Version"])
            metadata.backupDate = metadata.backupDate ?? info["Last Backup Date"] as? Date
        }
        return metadata
    }

    private func propertyList(at path: String, byteLimit: Int) -> [String: Any]? {
        guard let data = LocalModelInventoryScanner.readRegularFile(at: path, byteLimit: byteLimit) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// 去掉控制字符和首尾空白，最多 80 个字符。
    static func displayName(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let cleaned = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > 80 ? String(cleaned.prefix(80)) + "…" : cleaned
    }

    /// 只接受 “18”、“18.1”、“17.6.1” 这样的 ASCII 数字版本号。
    static func systemVersion(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 16 else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }) else { return nil }
        return text
    }

    // MARK: - Walking

    private struct Pending {
        let id: String
        let location: String
        let metadata: Metadata
    }

    private struct Walk {
        var bytes: Int64 = 0
        var fileCount = 0
        /// 有多个链接的文件（每个备份只记一次），用来找出与其他备份共用的部分。
        var linked = [LocalModelInventoryScanner.FileKey: Int64]()
        var isIncomplete = false
    }

    /// 只走真实文件夹，不跟随符号链接；只统计普通文件。
    private func walk(_ folder: String, context: inout Context) -> Walk {
        var result = Walk()
        var stack: [(path: String, depth: Int)] = [(folder, 0)]
        while let current = stack.popLast() {
            guard context.consume() else {
                result.isIncomplete = true
                return result
            }
            guard let names = context.list(current.path) else {
                result.isIncomplete = true
                continue
            }
            for name in names {
                guard context.consume() else {
                    result.isIncomplete = true
                    return result
                }
                let path = current.path + "/" + name
                guard let status = Self.lstatus(path) else { continue }
                switch Self.kind(status) {
                case S_IFLNK:
                    context.skippedSymbolicLinks += 1
                case S_IFDIR:
                    if current.depth + 1 < maximumDepth {
                        stack.append((path, current.depth + 1))
                    } else {
                        context.skippedDeepFolders += 1
                        result.isIncomplete = true
                    }
                case S_IFREG:
                    let bytes = Self.allocatedBytes(status)
                    if status.st_nlink > 1 {
                        let key = LocalModelInventoryScanner.FileKey(status)
                        // 同一个文件在这个备份里出现两次（硬链接）：只算一次。
                        guard result.linked[key] == nil else { continue }
                        result.linked[key] = bytes
                    }
                    result.bytes = Self.add(result.bytes, bytes)
                    result.fileCount += 1
                default:
                    continue
                }
            }
        }
        return result
    }

    private static func inventory(
        root: String,
        state: MobileDeviceBackupFolderState,
        walks: [(backup: Pending, walk: Walk)],
        context: Context
    ) -> MobileDeviceBackupInventory {
        var owners = [LocalModelInventoryScanner.FileKey: (bytes: Int64, backups: [Int])]()
        for (index, item) in walks.enumerated() {
            for (key, bytes) in item.walk.linked {
                owners[key, default: (bytes, [])].backups.append(index)
            }
        }
        var shared = Array(repeating: Int64(0), count: walks.count)
        var duplicated: Int64 = 0
        for owner in owners.values where owner.backups.count > 1 {
            for index in owner.backups { shared[index] = add(shared[index], owner.bytes) }
            for _ in 1..<owner.backups.count { duplicated = add(duplicated, owner.bytes) }
        }
        let listed = walks.reduce(Int64(0)) { add($0, $1.walk.bytes) }
        let backups = walks.enumerated().map { index, item in
            MobileDeviceBackup(
                id: item.backup.id,
                location: item.backup.location,
                deviceName: item.backup.metadata.deviceName,
                systemVersion: item.backup.metadata.systemVersion,
                backupDate: item.backup.metadata.backupDate,
                isEncrypted: item.backup.metadata.isEncrypted,
                isUnfinished: item.backup.metadata.isUnfinished,
                bytes: item.walk.bytes,
                sharedBytes: shared[index],
                fileCount: item.walk.fileCount,
                isIncomplete: item.walk.isIncomplete
            )
        }
        return MobileDeviceBackupInventory(
            rootPath: root,
            rootState: state,
            backups: backups.sorted(by: sortsBefore),
            totalBytes: max(0, listed - duplicated),
            skippedSymbolicLinkCount: context.skippedSymbolicLinks,
            unreadableFolderCount: context.unreadableFolders,
            skippedDeepFolderCount: context.skippedDeepFolders,
            stoppedEarly: context.isStopped
        )
    }

    /// 大的在前；一样大时新的在前，再按文件夹名。
    private static func sortsBefore(_ lhs: MobileDeviceBackup, _ rhs: MobileDeviceBackup) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        switch (lhs.backupDate, rhs.backupDate) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.id < rhs.id
        }
    }

    // MARK: - Helpers

    private struct Context {
        let limit: Int
        let isCancelled: @Sendable () -> Bool
        var used = 0
        /// 达到条目上限或被取消；只由 `consume()` 设置。
        private(set) var isStopped = false
        var skippedSymbolicLinks = 0
        var skippedDeepFolders = 0
        var unreadableFolders = 0

        init(limit: Int, isCancelled: @escaping @Sendable () -> Bool) {
            self.limit = limit
            self.isCancelled = isCancelled
        }

        mutating func consume() -> Bool {
            guard !isStopped else { return false }
            if used >= limit || isCancelled() {
                isStopped = true
                return false
            }
            used += 1
            return true
        }

        /// 列出文件夹内容；列不出时记下（结果不完整）并返回 nil。
        mutating func list(_ path: String) -> [String]? {
            do {
                return try FileManager.default.contentsOfDirectory(atPath: path)
            } catch {
                unreadableFolders += 1
                return nil
            }
        }
    }

    private static func lstatus(_ path: String) -> stat? {
        var status = stat()
        return Darwin.lstat(path, &status) == 0 ? status : nil
    }

    private static func kind(_ status: stat) -> mode_t { status.st_mode & S_IFMT }

    /// 本地占用：已分配的块（与空间分析口径一致）。
    private static func allocatedBytes(_ status: stat) -> Int64 {
        max(0, Int64(status.st_blocks) * 512)
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(max(0, rhs))
        return result.overflow ? .max : result.partialValue
    }
}
