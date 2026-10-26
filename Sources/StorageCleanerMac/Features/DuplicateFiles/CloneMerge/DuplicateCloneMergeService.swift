import Darwin
import Foundation

/// D-FP4: which copy of a duplicate group to keep, as a suggestion the
/// person can change (Mac Sai's rule, widened): a name that does not look
/// like a copy, not in Downloads, the Desktop or the Trash, the shallowest
/// path, then the oldest.
enum DuplicateKeeperSuggestion {
    struct Ranked: Equatable, Sendable {
        let path: String
        let reasons: [Reason]
    }

    enum Reason: String, Equatable, Sendable {
        case originalName, regularPlace, shallowest, oldest

        var title: String {
            switch self {
            case .originalName: L10n.text("名字不像副本", "Name does not look like a copy")
            case .regularPlace: L10n.text("不在下载、桌面或废纸篓", "Not in Downloads, Desktop or Trash")
            case .shallowest: L10n.text("路径最浅", "Shallowest path")
            case .oldest: L10n.text("创建最早", "Created first")
            }
        }
    }

    /// "Report copy", "Report 副本 2", "Report (1)", "Report-2".
    static func looksLikeCopy(_ fileName: String) -> Bool {
        let base = (fileName as NSString).deletingPathExtension
        let patterns = [
            #"(?i)\s(copy|副本|拷贝)(\s\d+)?$"#,
            #"\s?\(\d+\)$"#,
            #"(?<=\D)[-_]\d{1,2}$"#,
            #"(?i)^(copy of|副本 - )"#,
        ]
        return patterns.contains { base.range(of: $0, options: .regularExpression) != nil }
    }

    static func isInTransientPlace(_ path: String, homePath: String) -> Bool {
        let lowered = path.lowercased()
        let home = homePath.lowercased()
        return [home + "/downloads/", home + "/desktop/", home + "/.trash/", "/private/tmp/", "/tmp/"]
            .contains { lowered.hasPrefix($0) }
            || lowered.contains("/.trashes/")
    }

    /// Best first. `creation` gives each path's creation date (nil when unknown).
    static func rank(_ paths: [String], homePath: String = PathSafety.lexicalHomePath,
                     creation: (String) -> Date? = Self.creationDate) -> [Ranked] {
        struct Key { let path: String; let copyName: Bool; let transient: Bool; let depth: Int; let created: Date }
        let keys = paths.map { path in
            Key(path: path, copyName: looksLikeCopy((path as NSString).lastPathComponent),
                transient: isInTransientPlace(path, homePath: homePath),
                depth: path.split(separator: "/").count, created: creation(path) ?? .distantFuture)
        }
        let sorted = keys.sorted { a, b in
            if a.copyName != b.copyName { return !a.copyName }
            if a.transient != b.transient { return !a.transient }
            if a.depth != b.depth { return a.depth < b.depth }
            if a.created != b.created { return a.created < b.created }
            return a.path < b.path
        }
        guard let best = sorted.first else { return [] }
        return sorted.enumerated().map { index, key in
            guard index == 0 else { return Ranked(path: key.path, reasons: []) }
            var reasons: [Reason] = []
            if !best.copyName && keys.contains(where: \.copyName) { reasons.append(.originalName) }
            if !best.transient && keys.contains(where: \.transient) { reasons.append(.regularPlace) }
            if keys.allSatisfy({ $0.depth >= best.depth }) && keys.contains(where: { $0.depth > best.depth }) {
                reasons.append(.shallowest)
            }
            if keys.allSatisfy({ $0.created >= best.created }) && keys.contains(where: { $0.created > best.created }) {
                reasons.append(.oldest)
            }
            return Ranked(path: key.path, reasons: reasons)
        }
    }

    static func keeper(for group: DuplicateFileGroup, homePath: String = PathSafety.lexicalHomePath) -> String? {
        rank(group.files.map(\.path), homePath: homePath).first?.path
    }

    static func creationDate(_ path: String) -> Date? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(status.st_birthtimespec.tv_sec)
                    + Double(status.st_birthtimespec.tv_nsec) / 1_000_000_000)
    }
}

/// Why a copy is not merged.
enum CloneMergeSkipReason: String, Equatable, Sendable {
    case outsideHome, protectedLocation, missing, notRegularFile, locked, cloudItem, executable
    case hardLinked, notOwned, differentVolume, volumeCannotClone, alreadyShared, parentNotWritable
    case sizeDiffers, recentlyModified, inUse, contentDiffers, changed, keeperUnavailable

    var title: String {
        switch self {
        case .outsideHome: L10n.text("不在你的个人文件夹里", "Not in your home folder")
        case .protectedLocation: L10n.text("在受保护的位置", "In a protected location")
        case .missing: L10n.text("文件已不在", "The file is gone")
        case .notRegularFile: L10n.text("不是普通文件", "Not a regular file")
        case .locked: L10n.text("文件已锁定或带有系统标记", "Locked or carries system flags")
        case .cloudItem: L10n.text("iCloud 里的文件不合并，以免重新上传", "iCloud files are not merged, to avoid uploading them again")
        case .executable: L10n.text("可执行文件不合并", "Executables are not merged")
        case .hardLinked: L10n.text("有硬链接，替换会断开其他链接", "Hard-linked; replacing it would break the other links")
        case .notOwned: L10n.text("文件属于其他用户", "Owned by another user")
        case .differentVolume: L10n.text("和保留的那份不在同一块磁盘", "Not on the same disk as the kept copy")
        case .volumeCannotClone: L10n.text("这块磁盘不支持 APFS 克隆", "This disk does not support APFS clones")
        case .alreadyShared: L10n.text("已经和保留的那份共用空间", "Already shares space with the kept copy")
        case .parentNotWritable: L10n.text("所在文件夹不可写", "Its folder cannot be written")
        case .sizeDiffers: L10n.text("大小和保留的那份不同", "Size differs from the kept copy")
        case .recentlyModified: L10n.text("刚刚改动过，可能还在写入", "Changed moments ago and may still be written")
        case .inUse: L10n.text("正被应用打开", "Open in an app")
        case .contentDiffers: L10n.text("内容和扫描时不同，没有合并", "Content no longer matches the scan; not merged")
        case .changed: L10n.text("扫描后有变化，没有合并", "Changed since the scan; not merged")
        case .keeperUnavailable: L10n.text("保留的那份不可用", "The kept copy is unavailable")
        }
    }
}

struct CloneMergeCandidate: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let groupID: String
    let keeperPath: String
    /// What moving the replaced data to the Trash and emptying it frees.
    let reclaimableBytes: Int64
    let skip: CloneMergeSkipReason?
    let identity: FileIdentity?

    var isReady: Bool { skip == nil }
}

struct CloneMergePreview: Equatable, Sendable {
    let candidates: [CloneMergeCandidate]
    /// Groups refused as a whole (no SHA-256 evidence, keeper unusable).
    let refusedGroups: [String: CloneMergeSkipReason]

    var ready: [CloneMergeCandidate] { candidates.filter(\.isReady) }
    var reclaimableBytes: Int64 { ready.reduce(0) { $0 + $1.reclaimableBytes } }
}

struct CloneMergeOutcome: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let path: String
        let note: String?
    }

    var merged: [Row] = []
    var skipped: [Row] = []
    var failed: [Row] = []
    /// Freed once the replaced data is emptied from the Trash.
    var reclaimableBytes: Int64 = 0
    /// Replaced data that could not be moved to the Trash; it stays beside
    /// the file under a "before merging" name.
    var leftovers: [String] = []
    var receiptWritten = true

    var title: String {
        merged.isEmpty
            ? L10n.text("没有合并任何副本", "No copies were merged")
            : L10n.text("已把 \(ByteFormat.count(merged.count)) 个副本合并为克隆", "Merged \(ByteFormat.count(merged.count)) copies into clones")
    }
}

struct CloneMergeProgress: Equatable, Sendable {
    let processed: Int
    let total: Int
    let currentName: String?
}

struct CloneMergeEnvironment: Sendable {
    var homePath: String = PathSafety.lexicalHomePath
    var userID: uid_t = getuid()
    var now: @Sendable () -> Date = { Date() }
    var recentModificationWindow: TimeInterval = 120
    var volumeSupportsCloning: @Sendable (String) -> Bool = { path in
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
            .volumeSupportsFileCloning ?? false
    }
    var isUbiquitous: @Sendable (String) -> Bool = { path in
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }
    var sharing: @Sendable (String) -> FileStorageSharing.Reading = { FileStorageSharing.read(at: URL(fileURLWithPath: $0)) }
    var isOpenByAnotherProcess: @Sendable (String) -> Bool = { OpenFileProbe.isOpen($0) }
    var digest: @Sendable (String) throws -> Data = { try GuardedFileContentReader().sha256(URL(fileURLWithPath: $0)) }
    var moveToTrash: @Sendable (URL) throws -> URL = { source in
        var target: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &target)
        guard let target = target as URL? else { throw CleanupMoveError.invalidResult }
        return target
    }
    var metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()
    var persist: @Sendable (CleanReport, [String: FileIdentity]) throws -> Void = {
        try CleanupReportJournal.live.checkpoint($0, expectedIdentities: $1)
    }
}

/// Processes with a file open, for the same user (libproc).
enum OpenFileProbe {
    static func isOpen(_ path: String) -> Bool {
        var pids = [Int32](repeating: 0, count: 512)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
                              buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return false }
        let me = getpid()
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).contains { $0 > 0 && $0 != me }
    }
}

/// D-FP3: merges verified duplicates into APFS clones (Mac Sai's idea, our
/// safety chain). Only groups proven identical by SHA-256 are offered; each
/// copy is hashed again right before it is replaced, given its own
/// metadata, swapped in atomically, and the replaced data goes to the Trash
/// through a recorded operation, so it can be put back. Nothing is deleted.
enum DuplicateCloneMergeService {
    static let ruleID = "duplicates.clone-merge.v1"

    static func preview(groups: [DuplicateFileGroup], keepers: [String: String] = [:],
                        environment: CloneMergeEnvironment = .init()) -> CloneMergePreview {
        var candidates: [CloneMergeCandidate] = []
        var refused: [String: CloneMergeSkipReason] = [:]
        for group in groups {
            guard group.matchKind == .logicalContentSHA256, digest(of: group) != nil else {
                refused[group.id] = .contentDiffers
                continue
            }
            guard let keeper = keepers[group.id] ?? DuplicateKeeperSuggestion.keeper(for: group, homePath: environment.homePath),
                  group.files.contains(where: { $0.path == keeper }),
                  let keeperStatus = status(keeper), isRegular(keeperStatus),
                  keeperStatus.st_flags & UInt32(SF_DATALESS) == 0 else {
                refused[group.id] = .keeperUnavailable
                continue
            }
            for file in group.files where file.path != keeper {
                candidates.append(candidate(file.path, group: group, keeper: keeper, keeperStatus: keeperStatus,
                                            environment: environment))
            }
        }
        return CloneMergePreview(candidates: candidates, refusedGroups: refused)
    }

    static func digest(of group: DuplicateFileGroup) -> Data? {
        guard let data = Data(base64Encoded: group.id), data.count == VerifiedDuplicateEvidence.digestByteCount else { return nil }
        return data
    }

    static func candidate(_ path: String, group: DuplicateFileGroup, keeper: String, keeperStatus: stat,
                          environment: CloneMergeEnvironment) -> CloneMergeCandidate {
        let lexical = PathSafety.lexicalPath(path)
        func make(_ skip: CloneMergeSkipReason?, bytes: Int64 = 0, identity: FileIdentity? = nil) -> CloneMergeCandidate {
            CloneMergeCandidate(path: lexical, groupID: group.id, keeperPath: keeper, reclaimableBytes: bytes,
                                skip: skip, identity: identity)
        }
        guard PathSafety.isContained(lexical, in: environment.homePath, resolvingSymlinks: false) else { return make(.outsideHome) }
        guard !ProtectedLocations.protects(path: lexical, homePath: environment.homePath) else { return make(.protectedLocation) }
        guard let copy = status(lexical) else { return make(.missing) }
        guard isRegular(copy) else { return make(.notRegularFile) }
        if copy.st_flags & UInt32(SF_DATALESS) != 0 || environment.isUbiquitous(lexical) { return make(.cloudItem) }
        if copy.st_flags & APFSCloneReplacement.refusedUserFlags != 0 || copy.st_flags & UInt32(SF_SETTABLE) != 0 {
            return make(.locked)
        }
        if copy.st_mode & 0o111 != 0 { return make(.executable) }
        if copy.st_nlink > 1 { return make(.hardLinked) }
        if copy.st_uid != environment.userID { return make(.notOwned) }
        guard copy.st_dev == keeperStatus.st_dev else { return make(.differentVolume) }
        guard environment.volumeSupportsCloning(lexical) else { return make(.volumeCannotClone) }
        if copy.st_ino == keeperStatus.st_ino { return make(.alreadyShared) }
        guard copy.st_size == keeperStatus.st_size else { return make(.sizeDiffers) }
        let directory = (lexical as NSString).deletingLastPathComponent
        guard access(directory, W_OK) == 0, !PathSafety.containsSymbolicLinkComponent(in: directory) else {
            return make(.parentNotWritable)
        }
        let modified = Date(timeIntervalSince1970: Double(copy.st_mtimespec.tv_sec))
        if environment.now().timeIntervalSince(modified) < environment.recentModificationWindow { return make(.recentlyModified) }
        let bytes: Int64
        switch environment.sharing(lexical) {
        case .known(let sharing):
            if case .known(let kept) = environment.sharing(keeper), kept.cloneID != 0, kept.cloneID == sharing.cloneID {
                return make(.alreadyShared)
            }
            guard sharing.privateBytes > 0 else { return make(.alreadyShared) }
            bytes = sharing.privateBytes
        case .notReported, .unknown:
            bytes = Int64(copy.st_blocks) * 512
        }
        let identity = try? environment.metadata.snapshot(at: URL(fileURLWithPath: lexical)).identity
        guard identity != nil else { return make(.missing) }
        return make(nil, bytes: bytes, identity: identity)
    }

    static func execute(
        _ preview: CloneMergePreview,
        groups: [DuplicateFileGroup],
        environment: CloneMergeEnvironment = .init(),
        beforeEachMerge: @escaping @Sendable () async throws -> Void = {},
        progress: @escaping @Sendable (CloneMergeProgress) -> Void = { _ in }
    ) async -> CloneMergeOutcome {
        var outcome = CloneMergeOutcome()
        let digests = Dictionary(uniqueKeysWithValues: groups.compactMap { group in digest(of: group).map { (group.id, $0) } })
        let byGroup = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var verifiedKeepers: [String: Bool] = [:]
        var trashItems: [RecordedTrashOperation.Item] = []
        let ready = preview.ready
        for (index, candidate) in ready.enumerated() {
            progress(CloneMergeProgress(processed: index, total: ready.count,
                                        currentName: (candidate.path as NSString).lastPathComponent))
            do { try await beforeEachMerge() } catch {
                outcome.skipped.append(.init(path: candidate.path, note: L10n.text("已停止", "Stopped")))
                continue
            }
            if Task.isCancelled {
                outcome.skipped.append(.init(path: candidate.path, note: L10n.text("已停止", "Stopped")))
                continue
            }
            // Everything checked in the preview is checked again now.
            guard let group = byGroup[candidate.groupID], let digest = digests[candidate.groupID],
                  let keeperStatus = status(candidate.keeperPath) else {
                outcome.skipped.append(.init(path: candidate.path, note: CloneMergeSkipReason.keeperUnavailable.title))
                continue
            }
            let fresh = Self.candidate(candidate.path, group: group, keeper: candidate.keeperPath,
                                       keeperStatus: keeperStatus, environment: environment)
            if let skip = fresh.skip {
                outcome.skipped.append(.init(path: candidate.path, note: skip.title))
                continue
            }
            guard fresh.identity == candidate.identity else {
                outcome.skipped.append(.init(path: candidate.path, note: CloneMergeSkipReason.changed.title))
                continue
            }
            if verifiedKeepers[candidate.keeperPath] == nil {
                verifiedKeepers[candidate.keeperPath] = (try? environment.digest(candidate.keeperPath)) == digest
            }
            guard verifiedKeepers[candidate.keeperPath] == true else {
                outcome.skipped.append(.init(path: candidate.path, note: CloneMergeSkipReason.keeperUnavailable.title))
                continue
            }
            guard (try? environment.digest(candidate.path)) == digest else {
                outcome.skipped.append(.init(path: candidate.path, note: CloneMergeSkipReason.contentDiffers.title))
                continue
            }
            guard !environment.isOpenByAnotherProcess(candidate.path) else {
                outcome.skipped.append(.init(path: candidate.path, note: CloneMergeSkipReason.inUse.title))
                continue
            }
            do {
                let expected = try APFSCloneReplacement.capture(candidate.path)
                let hidden = try APFSCloneReplacement.replace(target: candidate.path, withCloneOf: candidate.keeperPath,
                                                              expected: expected)
                let replaced = visibleName(for: candidate.path, hidden: hidden)
                outcome.merged.append(.init(path: candidate.path, note: nil))
                trashItems.append(RecordedTrashOperation.Item(
                    path: replaced, bytes: candidate.reclaimableBytes, identity: candidate.identity,
                    allowedRestoreRoot: URL(fileURLWithPath: candidate.path).deletingLastPathComponent()))
            } catch let error as APFSCloneReplacementError {
                if error == .changedBeforeSwap {
                    outcome.skipped.append(.init(path: candidate.path, note: CloneMergeSkipReason.changed.title))
                } else {
                    outcome.failed.append(.init(path: candidate.path, note: L10n.text(
                        "没有合并（\(error.detailCode)），文件保持原样", "Not merged (\(error.detailCode)); the file is unchanged")))
                }
            } catch {
                outcome.failed.append(.init(path: candidate.path, note: error.localizedDescription))
            }
        }
        for skipped in preview.candidates where !skipped.isReady {
            outcome.skipped.append(.init(path: skipped.path, note: skipped.skip?.title))
        }
        progress(CloneMergeProgress(processed: ready.count, total: ready.count, currentName: nil))

        guard !trashItems.isEmpty else { return outcome }
        let report = await RecordedTrashOperation.runAsync(
            items: trashItems, ruleID: ruleID,
            validate: { _ in },
            move: { try environment.moveToTrash($0) },
            metadata: environment.metadata,
            persist: environment.persist
        )
        outcome.receiptWritten = report.persistenceFailure == nil
        for row in report.items {
            if case .moved = row.outcome {
                outcome.reclaimableBytes += max(0, row.estimatedBytes)
            } else {
                outcome.leftovers.append(row.sourcePath)
            }
        }
        return outcome
    }

    /// The replaced data gets a name a person recognises before it goes to
    /// the Trash ("Report（合并前的副本）.pdf"), so putting it back is clear.
    static func visibleName(for path: String, hidden: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let suffix = L10n.text("（合并前的副本）", " (before merging)")
        for attempt in 1...50 {
            let numbered = attempt == 1 ? base + suffix : base + suffix + " \(attempt)"
            let candidate = (directory as NSString).appendingPathComponent(ext.isEmpty ? numbered : numbered + "." + ext)
            if renamex_np(hidden, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
            if errno != EEXIST { break }
        }
        return hidden
    }

    private static func status(_ path: String) -> stat? {
        var status = stat()
        return lstat(path, &status) == 0 ? status : nil
    }

    private static func isRegular(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFREG }
}
