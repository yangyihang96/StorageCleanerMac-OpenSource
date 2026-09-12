import Foundation

enum DuplicateFileStorageRelationship: String, Codable, Hashable, Sendable {
    case independent
    case apfsClone
    case hardLink
    case unknown

    var title: String {
        switch self {
        case .independent:
            L10n.text("独立数据", "Independent data")
        case .apfsClone:
            L10n.text("APFS clone", "APFS clone")
        case .hardLink:
            L10n.text("硬链接", "Hard link")
        case .unknown:
            L10n.text("关系未知", "Relationship unknown")
        }
    }

    var explanation: String {
        switch self {
        case .independent:
            L10n.text("AppleArchive 未报告 clone 或硬链接簇。", "AppleArchive reported no clone or hard-link cluster.")
        case .apfsClone:
            L10n.text("AppleArchive CLC 已确认这些文件属于同一 APFS clone 簇；物理释放空间仍须删除后确认。", "AppleArchive CLC confirms one APFS clone cluster; physical reclaimable space must be confirmed after deletion.")
        case .hardLink:
            L10n.text("AppleArchive HLC 已确认硬链接关系；同一 inode 已按扫描规则去重。", "AppleArchive HLC confirms a hard-link relationship; the shared inode is already deduplicated by the scanner.")
        case .unknown:
            L10n.text("无法从公开 AppleArchive CLC/HLC 证据确认文件关系。", "Public AppleArchive CLC/HLC evidence could not confirm the file relationship.")
        }
    }
}

struct DuplicateFileGroup: Identifiable, Hashable, Sendable {
    enum MatchKind: String, Hashable, Sendable {
        case logicalContentSHA256
    }

    let id: String
    let files: [DirectoryEntry]
    let contentSizeBytes: Int64
    let matchKind: MatchKind
    let relationship: DuplicateFileStorageRelationship

    // Physical block savings stay unknown even when CLC proves a clone relation.
    let estimatedPhysicalReclaimableBytes: Int64?

    init(
        id: String,
        files: [DirectoryEntry],
        contentSizeBytes: Int64,
        matchKind: MatchKind,
        relationship: DuplicateFileStorageRelationship = .unknown,
        estimatedPhysicalReclaimableBytes: Int64?
    ) {
        self.id = id
        self.files = files
        self.contentSizeBytes = contentSizeBytes
        self.matchKind = matchKind
        self.relationship = relationship
        self.estimatedPhysicalReclaimableBytes = estimatedPhysicalReclaimableBytes
    }
}

struct DuplicateFileCandidateGroup: Identifiable, Hashable, Sendable {
    enum Rule: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
        case sameName
        case sameSize
        case sameType
        case similarImage
        /// Retained only so an in-memory result created by older 1.9.9 code
        /// remains renderable while the app is running. New scans never emit it.
        case sameNameSizeAndType

        var id: String { rawValue }

        static let selectableCases: [Self] = [.sameName, .sameSize, .sameType, .similarImage]

        var title: String {
            switch self {
            case .sameName:
                L10n.text("同名", "Same Name")
            case .sameSize:
                L10n.text("同大小", "Same Size")
            case .sameType:
                L10n.text("同类型", "Same Type")
            case .similarImage:
                L10n.text("相似图片", "Similar Images")
            case .sameNameSizeAndType:
                L10n.text("名称、大小和类型相同", "Same Name, Size, and Type")
            }
        }

        var explanation: String {
            switch self {
            case .sameName:
                L10n.text("文件名称相同，但内容尚未确认相同。", "File names match, but content identity is not confirmed.")
            case .sameSize:
                L10n.text("文件大小相同，但内容尚未确认相同。", "File sizes match, but content identity is not confirmed.")
            case .sameType:
                L10n.text("文件类型相同，但内容尚未确认相同。", "File types match, but content identity is not confirmed.")
            case .similarImage:
                L10n.text(
                    "本地图像指纹相近，只作为相似候选，需要人工确认。",
                    "Local image fingerprints are similar. This is a review candidate and requires manual confirmation."
                )
            case .sameNameSizeAndType:
                L10n.text("名称、大小和类型相同，但内容尚未确认相同。", "Name, size, and type match, but content identity is not confirmed.")
            }
        }
    }

    let id: String
    let files: [DirectoryEntry]
    let rule: Rule
}

enum DuplicateFileScanScope: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case userFiles
    case wholeComputer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userFiles: L10n.text("用户文件", "User Files")
        case .wholeComputer: L10n.text("用户数据区", "User Data Areas")
        }
    }

    /// The scope is intentionally narrower than a whole-disk walk. Keep this
    /// copy next to the enum so the landing page and the coverage report use
    /// the same, auditable boundary.
    var coverageDescription: String {
        switch self {
        case .userFiles:
            return L10n.text(
                "只扫描常用用户文件夹和你明确选择的位置；只处理有权限读取的常规文件。隐藏文件、未选择的卷及其余位置不在本次范围。",
                "Scans common user folders and locations you explicitly select; only readable regular files are considered. Hidden files, unselected volumes, and other locations are out of scope."
            )
        case .wholeComputer:
            return L10n.text(
                "扫描可读用户数据区，并自动纳入已挂载的本地可浏览数据卷；也可额外选择外接卷。只处理有权限读取的常规文件。自动发现会排除网络卷、不可浏览卷和只读系统容器；隐藏文件、系统保护目录、应用包、缓存挂载、伪文件系统和 Time Machine 会跳过。",
                "Scans readable user data areas and automatically includes mounted local browsable data volumes; only readable regular files are considered. Automatic discovery excludes network volumes, non-browsable volumes, and read-only system containers; hidden files, system-protected folders, app bundles, cache mounts, pseudo-filesystems, and Time Machine locations are skipped."
            )
        }
    }
}

enum DuplicateFileScanOutcome: String, Codable, Hashable, Sendable {
    case complete
    case partial
    case cancelled
}

enum DuplicateFileScanPhase: String, Codable, Hashable, Sendable {
    case discovering
    case fingerprinting
    case hashing
    case paused
    case finished
}

struct DuplicateFileScanProgress: Codable, Hashable, Sendable {
    var phase: DuplicateFileScanPhase
    var currentPath: String?
    var scannedDirectories: Int
    var scannedFiles: Int
    var scannedBytes: Int64
    var hashedFiles: Int
    var hashedBytes: Int64
    var estimatedTotalDirectories: Int?
    var estimatedTotalFiles: Int?
    var estimatedTotalBytes: Int64?

    static let initial = DuplicateFileScanProgress(
        phase: .discovering,
        currentPath: nil,
        scannedDirectories: 0,
        scannedFiles: 0,
        scannedBytes: 0,
        hashedFiles: 0,
        hashedBytes: 0,
        estimatedTotalDirectories: nil,
        estimatedTotalFiles: nil,
        estimatedTotalBytes: nil
    )
}

enum DuplicateFileScanSkipReason: String, Codable, Hashable, Sendable {
    case excluded
    case missing
    case notDirectory
    case symbolicLink
    case package
    case pseudoFilesystem
    case timeMachine
    case permissionDenied
    case timedOut
    case unreadable
    case policyExcluded
    case depthLimit
    case timeLimit
    case fileLimit
    case directoryLimit
    case cancelled
}

struct DuplicateFileScanSkippedPath: Codable, Hashable, Sendable {
    let path: String
    let reason: DuplicateFileScanSkipReason
}

struct DuplicateFileScanRootCoverage: Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case scanned
        case skipped
    }

    let rootPath: String
    let status: Status
    let skipReason: DuplicateFileScanSkipReason?
    let scannedDirectories: Int
    let scannedFiles: Int
    let scannedBytes: Int64
    let skippedPaths: [DuplicateFileScanSkippedPath]
}

struct DuplicateFileScanCoverage: Codable, Hashable, Sendable {
    let roots: [DuplicateFileScanRootCoverage]
    let reachedTimeLimit: Bool
    let reachedFileLimit: Bool
    let reachedDirectoryLimit: Bool
    let reachedResultLimit: Bool
}

struct DuplicateFileScanReport: Hashable, Sendable {
    let exactGroups: [DuplicateFileGroup]
    let candidates: [DuplicateFileCandidateGroup]
    let coverage: DuplicateFileScanCoverage
    let progress: DuplicateFileScanProgress
    let outcome: DuplicateFileScanOutcome
}

final class DuplicateFileScanControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func pause() {
        condition.lock()
        if !cancelled {
            paused = true
        }
        condition.unlock()
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilRunnable() -> (shouldContinue: Bool, pausedDuration: TimeInterval) {
        condition.lock()
        let pauseStartedAt = paused ? ProcessInfo.processInfo.systemUptime : nil
        while paused && !cancelled {
            condition.wait()
        }
        let shouldContinue = !cancelled
        let pausedDuration = pauseStartedAt.map {
            ProcessInfo.processInfo.systemUptime - $0
        } ?? 0
        condition.unlock()
        return (shouldContinue, pausedDuration)
    }
}
