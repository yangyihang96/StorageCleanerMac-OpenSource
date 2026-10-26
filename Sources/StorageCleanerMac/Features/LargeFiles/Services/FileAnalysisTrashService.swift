import AppKit
import Darwin
import FileOperationShared
import Foundation

/// Everything a File Analysis move to the Trash touches (D46), so tests run
/// on fixtures: an isolated receipt journal and a fixture "Trash".
struct FileAnalysisTrashEnvironment: Sendable {
    /// Where receipts go. The app uses the live journal; a test names its own.
    let journal: CleanupReportJournal
    /// Moves one item to the Trash and returns where it went.
    let moveToTrash: @Sendable (URL) throws -> URL
    let metadata: any ReadOnlyFileSystem
    let homePath: String
    let appDataPath: String
    let excludedPaths: @Sendable () -> [String]
    /// File Provider keeps this folder (iCloud Desktop and Documents).
    let isCloudFolder: @Sendable (URL) -> Bool
    let isReadOnlyVolume: @Sendable (URL) -> Bool
    /// The user's Trash on the startup disk. Operation History restores
    /// only from here; an external volume's Trash is restored in Finder.
    let userTrashPath: String
    /// How the walk that compares a folder with the analysis runs.
    var verificationOptions: DiskScanner.StorageMapAnalysisOptions = .standard
    /// D54 ③: the bundles of the apps running now (read on the main actor),
    /// and where every mounted file system is attached.
    var runningApplicationPaths: @MainActor @Sendable () -> [String] = { [] }
    var mountPointPaths: @Sendable () -> [String] = { [] }
    /// 夹具默认不转移；生产用 Security 框架的只读路径还原。
    var originalRunningApplicationURL: @Sendable (URL) -> URL? = { $0 }
    /// 可注入等待器，使超时测试不依赖机器速度；生产等待十秒。
    var waitForRefinementTimeout: @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(10))
    }
    /// r2-fa-followups P1-1：经由符号链接到达的 D54 位置。读个人目录的
    /// “资源库”，store 在主线程以外调用；夹具传入自己的个人目录。
    var protectedLinkTargets: @Sendable (_ homePath: String, _ appDataPath: String) -> [FileAnalysisProtectedLocation] = {
        FileAnalysisProtectedLinkResolver.locations(homePath: $0, appDataPath: $1)
    }

    static var live: FileAnalysisTrashEnvironment {
        var environment = FileAnalysisTrashEnvironment(
            journal: .live,
            moveToTrash: { source in
                var target: NSURL?
                try FileManager.default.trashItem(at: source, resultingItemURL: &target)
                guard let target = target as URL? else { throw CleanupMoveError.invalidResult }
                return target
            },
            metadata: FoundationReadOnlyFileSystem(),
            homePath: PathSafety.lexicalHomePath,
            appDataPath: PathSafety.lexicalPath(AppDataDirectories.applicationSupportRoot.path),
            excludedPaths: { ScanExclusionService.excludedPaths() },
            isCloudFolder: { url in
                (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            },
            isReadOnlyVolume: { url in
                (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
            },
            userTrashPath: PathSafety.lexicalPath(CleanupService.userTrashURL().path)
        )
        environment.runningApplicationPaths = {
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path }
        }
        environment.originalRunningApplicationURL = { FileAnalysisRunningApplicationResolver.originalURL(for: $0) }
        environment.mountPointPaths = { FileAnalysisTrashEnvironment.currentMountPoints() }
        return environment
    }

    /// The running apps' bundles and, for a translocated app, where it really
    /// is. P2-2: an app is unknown only when it runs from a translocation
    /// mount and its original path cannot be restored; any other app is
    /// matched by its own path, even when its bundle is gone.
    @MainActor
    func runningApplicationState() -> FileAnalysisRunningApplicationState {
        var paths: Set<String> = []
        var unknown: [String] = []
        for path in runningApplicationPaths() {
            paths.insert(path)
            if let original = originalRunningApplicationURL(URL(fileURLWithPath: path)), original.isFileURL,
               !original.path.isEmpty {
                paths.insert(original.standardizedFileURL.path)
            } else if FileAnalysisRunningApplicationResolver.isInTranslocationMount(path) {
                unknown.append(FileAnalysisRunningApplicationResolver.applicationName(forBundlePath: path))
            }
        }
        return FileAnalysisRunningApplicationState(paths: paths.sorted(),
                                                   unknownApplicationNames: Array(Set(unknown)).sorted())
    }

    /// Where every mounted file system is attached now.
    static func currentMountPoints() -> [String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        defer { free(buffer) }
        return (0..<Int(count)).map { index in
            withUnsafePointer(to: buffer[index].f_mntonname) { name in
                name.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
        }
    }
}

/// D46: File Analysis moves checked items to the Trash after a review.
/// Each item is checked against what the analysis recorded in the review and
/// again right before it moves: same item (device, inode, birth time), same
/// size and modification time for a file, and for a folder the same entries
/// with the same sizes and stamps all the way down. Anything else is skipped
/// and explained. The move goes through the one receipt journal
/// (`RecordedTrashOperation`): without a durable intent nothing moves, and
/// Operation History can put the items back.
enum FileAnalysisTrashService {
    static let ruleID = "file-analysis.trash.v1"

    /// D101 G4-2: every flag that blocks a move, owner's and system's alike.
    private static let lockFlags = FileProtectionFlags.all

    // MARK: - Rules for one analysis

    /// The rules the page can draw the moment an analysis ends, with no file
    /// system read beyond the exclusions and the mount table: the D54
    /// locations reached through links are not known yet (r2-fa-followups
    /// P1-1), nor iCloud or the volume (review P2-12); what depends on them
    /// reads "checking". The store adds the running apps (main actor) and
    /// finds the rest off the main thread.
    static func startingPolicy(
        for analysis: StorageMapAnalysisResult,
        environment: FileAnalysisTrashEnvironment
    ) -> FileAnalysisTrashPolicy {
        FileAnalysisTrashPolicy(
            rootPath: analysis.index.rootPath,
            targetKind: analysis.target.kind,
            homePath: environment.homePath,
            appDataPath: environment.appDataPath,
            excludedPaths: environment.excludedPaths(),
            mountPointPaths: environment.mountPointPaths(),
            isRefined: false,
            awaitsProtectedLinkTargets: true
        )
    }

    /// What reading the file system adds: the D54 locations reached through
    /// links (P1-1) and which packages named `….app` are not apps (P2-1).
    /// Never call it on the main thread.
    static func protection(
        for index: StorageMapAnalysisIndex,
        policy: FileAnalysisTrashPolicy,
        environment: FileAnalysisTrashEnvironment
    ) -> FileAnalysisTrashProtection {
        FileAnalysisTrashProtection(
            linkTargets: environment.protectedLinkTargets(environment.homePath, environment.appDataPath),
            nonApplicationBundlePaths: nonApplicationBundlePaths(in: index, policy: policy)
        )
    }

    /// P2-1: of the packages named `….app` that a row can show (not inside
    /// another package, not a cloud placeholder) and that the rules would
    /// otherwise call an app, those with no executable under the CFBundle naming rules.
    static func nonApplicationBundlePaths(
        in index: StorageMapAnalysisIndex,
        policy: FileAnalysisTrashPolicy,
        isApplication: (String) -> Bool = FileAnalysisApplicationBundleProbe.isApplication(atPath:)
    ) -> Set<String> {
        var paths: Set<String> = []
        for path in index.blockedDirectoryPaths
        where (path as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            guard !insidePackage(path, index: index),
                  let entry = index.indexedEntry(at: path), entry.isDirectory, !entry.isEstimated,
                  policy.block(path: path, name: entry.name, kind: entry.kind, isDirectory: true,
                               isEstimated: false) == .applicationBundle,
                  !isApplication(path) else { continue }
            paths.insert(path)
        }
        return paths
    }

    /// A folder above `path`, below the analyzed root, that the map does not
    /// open (a package or a cloud placeholder).
    private static func insidePackage(_ path: String, index: StorageMapAnalysisIndex) -> Bool {
        var parent = DiskScanner.storageMapParentPath(path)
        while parent != index.rootPath, DiskScanner.storageMapPath(parent, isWithinRoot: index.rootPath) {
            if index.blockedDirectoryPaths.contains(parent) { return true }
            parent = DiskScanner.storageMapParentPath(parent)
        }
        return false
    }

    /// Installs what `protection` found. A policy that no longer waits for it
    /// (it ran out of time) keeps its answer: a late result is not taken.
    static func applyingProtection(
        _ protection: FileAnalysisTrashProtection,
        to policy: FileAnalysisTrashPolicy
    ) -> FileAnalysisTrashPolicy {
        guard policy.awaitsProtectedLinkTargets else { return policy }
        var policy = policy
        policy.protectedLinkTargets = protection.linkTargets
        policy.nonApplicationBundlePaths = protection.nonApplicationBundlePaths
        policy.awaitsProtectedLinkTargets = false
        return policy
    }

    /// The starting rules with what reading the file system adds, in one go
    /// (tests, and any caller already off the main thread); iCloud and the
    /// volume are still to be asked.
    static func basicPolicy(
        for analysis: StorageMapAnalysisResult,
        environment: FileAnalysisTrashEnvironment
    ) -> FileAnalysisTrashPolicy {
        let starting = startingPolicy(for: analysis, environment: environment)
        return applyingProtection(protection(for: analysis.index, policy: starting, environment: environment),
                                  to: starting)
    }

    /// The same rules plus what needs the file system: whether iCloud keeps
    /// Desktop and Documents, and whether an external volume is read-only.
    static func policy(
        for analysis: StorageMapAnalysisResult,
        environment: FileAnalysisTrashEnvironment
    ) -> FileAnalysisTrashPolicy {
        refined(basicPolicy(for: analysis, environment: environment), environment: environment)
    }

    /// Adds to `basic` what needs the file system.
    static func refined(
        _ basic: FileAnalysisTrashPolicy,
        environment: FileAnalysisTrashEnvironment
    ) -> FileAnalysisTrashPolicy {
        var policy = basic
        if policy.targetKind == .externalVolume {
            policy.isReadOnlyVolume = environment.isReadOnlyVolume(URL(fileURLWithPath: policy.rootPath))
        } else {
            policy.cloudSyncedFolders = ["Desktop", "Documents"]
                .map { environment.homePath + "/" + $0 }
                .filter { environment.isCloudFolder(URL(fileURLWithPath: $0, isDirectory: true)) }
        }
        policy.pendingRefinementPaths = []
        return policy
    }

    /// 每个位置单独询问，File Provider 卡住时其他位置仍可完成。
    static func refinementAnswer(for path: String, policy: FileAnalysisTrashPolicy,
                                 environment: FileAnalysisTrashEnvironment) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return policy.targetKind == .externalVolume
            ? environment.isReadOnlyVolume(url) : environment.isCloudFolder(url)
    }

    static func applyingRefinementAnswer(_ answer: Bool, for path: String,
                                        to policy: FileAnalysisTrashPolicy) -> FileAnalysisTrashPolicy {
        var policy = policy
        guard policy.pendingRefinementPaths.remove(path) != nil else { return policy }
        if policy.targetKind == .externalVolume {
            policy.isReadOnlyVolume = answer
        } else if answer {
            policy.cloudSyncedFolders.append(path)
        }
        return policy
    }

    /// What was not known in time stays unavailable: the unanswered
    /// locations (review P2-12) and, when the links were still being looked
    /// for, every item (P1-1).
    static func refinementTimedOut(_ policy: FileAnalysisTrashPolicy) -> FileAnalysisTrashPolicy {
        var policy = policy
        policy.failedRefinementPaths.formUnion(policy.pendingRefinementPaths)
        policy.pendingRefinementPaths = []
        if policy.awaitsProtectedLinkTargets {
            policy.awaitsProtectedLinkTargets = false
            policy.protectedLinkTargetsUnknown = true
        }
        return policy
    }

    /// Whether the policy blocks an indexed item, with its folder's
    /// completeness standing in for "estimated".
    static func block(
        for path: String,
        entry: StorageMapIndexedEntry,
        index: StorageMapAnalysisIndex,
        policy: FileAnalysisTrashPolicy
    ) -> FileAnalysisTrashBlock? {
        let isEstimated = entry.isDirectory
            ? entry.isEstimated || index.directories[path]?.isComplete != true
            : entry.isEstimated || entry.sizeBytes == nil
        return policy.block(path: path, name: entry.name, kind: entry.kind,
                            isDirectory: entry.isDirectory, isEstimated: isEstimated,
                            isCloudOnly: entry.isCloudOnly)
    }

    /// 返回勾选中现已被规则阻止的项目，供更新规则时取消勾选。
    static func selectionBlocks(_ selections: [FileAnalysisTrashSelection], index: StorageMapAnalysisIndex,
                                policy: FileAnalysisTrashPolicy) -> [String: FileAnalysisTrashBlock] {
        var blocks: [String: FileAnalysisTrashBlock] = [:]
        for selection in selections {
            guard let entry = index.indexedEntry(at: selection.path),
                  let block = block(for: selection.path, entry: entry, index: index, policy: policy) else { continue }
            blocks[selection.path] = block
        }
        return blocks
    }

    // MARK: - Review

    static func review(
        _ selections: [FileAnalysisTrashSelection],
        index: StorageMapAnalysisIndex,
        policy: FileAnalysisTrashPolicy,
        environment: FileAnalysisTrashEnvironment,
        externalVolumeName: String?,
        storageSharing: (String) -> FileStorageSharing.Reading = { FileStorageSharing.read(at: URL(fileURLWithPath: $0)) }
    ) -> FileAnalysisTrashReview {
        FileAnalysisTrashReview(items: selections.map { selection in
            let status: FileAnalysisTrashReviewItem.Status
            var otherLinks = false
            var estimate: CleanupReclaimableEstimate?
            switch check(selection, index: index, policy: policy, environment: environment) {
            case .success(let identity):
                status = .ready(identity)
                otherLinks = !selection.isDirectory && hasOtherHardLinks(selection.path)
                // D104 G1: read-only metadata of the file itself; its volume
                // keeps clones on different volumes apart in the review total.
                if !selection.isDirectory, !otherLinks {
                    estimate = CleanupReclaimableEstimate.file(storageSharing(selection.path),
                                                               allocatedBytes: selection.bytes,
                                                               deviceID: identity.deviceID)
                }
            case .failure(let block):
                status = .blocked(block)
            }
            return FileAnalysisTrashReviewItem(selection: selection, status: status,
                                               externalVolumeName: externalVolumeName,
                                               hasOtherHardLinks: otherLinks,
                                               reclaimableEstimate: estimate)
        }, unknownRunningApplicationNames: policy.unknownRunningApplicationNames)
    }

    /// D54 ④: a regular file that another hard link still holds, so moving
    /// this path may free no space.
    static func hasOtherHardLinks(_ path: String) -> Bool {
        var status = stat()
        guard Darwin.lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return false }
        return status.st_nlink > 1
    }

    /// The item now, compared with what the analysis recorded: the item's
    /// identity on success, or what stops it. Mount points are read again
    /// here; the caller passes the running apps as last read.
    static func check(
        _ selection: FileAnalysisTrashSelection,
        index: StorageMapAnalysisIndex,
        policy: FileAnalysisTrashPolicy,
        environment: FileAnalysisTrashEnvironment
    ) -> Result<FileIdentity, FileAnalysisTrashBlock> {
        let path = selection.path
        guard let entry = index.indexedEntry(at: path) else { return .failure(.changedSinceAnalysis) }
        var policy = policy
        if entry.isDirectory { policy.mountPointPaths = environment.mountPointPaths() }
        if let block = block(for: path, entry: entry, index: index, policy: policy) { return .failure(block) }
        guard entry.changeStamp != 0 else { return .failure(.unreadable) }
        var status = stat()
        guard Darwin.lstat(path, &status) == 0 else { return .failure(errno == ENOENT ? .missing : .unreadable) }
        let type = status.st_mode & S_IFMT
        if type == S_IFLNK { return .failure(.symbolicLink) }
        guard (type == S_IFDIR) == entry.isDirectory,
              DiskScanner.storageMapChangeStamp(status) == entry.changeStamp else {
            return .failure(.changedSinceAnalysis)
        }
        if status.st_flags & lockFlags != 0 { return .failure(.locked) }
        let snapshot: FileSnapshot
        do {
            snapshot = try environment.metadata.snapshot(at: URL(fileURLWithPath: path))
        } catch CleanupFileSystemError.vanished {
            return .failure(.missing)
        } catch {
            return .failure(.unreadable)
        }
        if snapshot.hasSymbolicLinkComponent { return .failure(.changedSinceAnalysis) }
        if snapshot.isCloudItem { return .failure(snapshot.isCloudPlaceholder ? .cloudOnly : .cloudStorage) }
        if !snapshot.isWritableVolume { return .failure(.readOnlyVolume) }
        if !entry.isDirectory {
            let values = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            let size = DiskScanner.storageMapPreferredSize(
                logicalSize: values?.fileSize,
                allocatedSize: values?.totalFileAllocatedSize ?? values?.fileAllocatedSize,
                path: path
            )
            guard let size, Int64(max(0, size)) == entry.sizeBytes else { return .failure(.changedSinceAnalysis) }
        }
        return .success(snapshot.identity)
    }

    /// Walks the folder again and compares it with the analysis: the same
    /// folders, and in each the same entries with the same kind, size and
    /// stamp. `.DS_Store` is not compared (Finder rewrites it whenever a
    /// window shows the folder). Returns nil when nothing changed.
    static func verifyFolder(
        at path: String,
        index: StorageMapAnalysisIndex,
        targetKind: StorageMapScanTarget.Kind,
        excludedPaths: [String],
        options: DiskScanner.StorageMapAnalysisOptions,
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> FileAnalysisTrashBlock? {
        let walk: StorageMapAnalysisResult
        var handler: (@Sendable (StorageMapScanProgress) -> Void)?
        if let progress {
            handler = { @Sendable update in progress(update.inspectedItemCount) }
        }
        do {
            walk = try DiskScanner(excludedPaths: excludedPaths).storageMapAnalysis(
                target: StorageMapScanTarget(path: path, title: (path as NSString).lastPathComponent, kind: targetKind),
                options: options,
                progressHandler: handler
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }
        guard walk.index.rootPath == path else { return .changedSinceAnalysis }
        guard walk.index.directories[path]?.isComplete == true else { return .incompleteMeasurement }
        var expected: [String] = []
        var pending = [path]
        while let directory = pending.popLast() {
            expected.append(directory)
            for child in index.childrenByDirectory[directory] ?? [] where child.isDirectory {
                pending.append(StorageMapAnalysisIndex.childPath(child.name, in: directory))
            }
        }
        guard Set(expected) == Set(walk.index.childrenByDirectory.keys) else { return .changedSinceAnalysis }
        for directory in expected
        where comparable(index.childrenByDirectory[directory]) != comparable(walk.index.childrenByDirectory[directory]) {
            return .changedSinceAnalysis
        }
        return nil
    }

    private static func comparable(_ entries: [StorageMapIndexedEntry]?) -> [String: StorageMapIndexedEntry] {
        Dictionary(
            (entries ?? []).filter { $0.name != ".DS_Store" }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Move

    /// Moves the review's ready items, checking each again right before it
    /// moves. `beforeEachMove` holds the caller's lease check; `progress`
    /// may be called from any thread.
    static func execute(
        _ items: [FileAnalysisTrashReviewItem],
        index: StorageMapAnalysisIndex,
        policy: FileAnalysisTrashPolicy,
        environment: FileAnalysisTrashEnvironment,
        beforeEachMove: @escaping @Sendable () async throws -> Void = {},
        progress: @escaping @Sendable (FileAnalysisTrashProgress) -> Void = { _ in }
    ) async -> FileAnalysisTrashOutcome {
        var ready: [(selection: FileAnalysisTrashSelection, identity: FileIdentity)] = []
        var volumeNames: [String] = []
        for item in items {
            guard case .ready(let identity) = item.status else { continue }
            ready.append((item.selection, identity))
            if let name = item.externalVolumeName, !volumeNames.contains(name) { volumeNames.append(name) }
        }
        let selections = Dictionary(ready.map { ($0.selection.path, $0.selection) }, uniquingKeysWith: { first, _ in first })
        // What each skipped item's reason says (P2-2: naming the apps).
        let reasons = LockedValue([String: String]())
        let verified = LockedValue(Set<String>())
        let processed = LockedValue(0)
        let excludedPaths = environment.excludedPaths()
        let total = ready.count
        progress(FileAnalysisTrashProgress(processed: 0, total: total))

        let report = await RecordedTrashOperation.runAsync(
            items: ready.map { selection, identity in
                RecordedTrashOperation.Item(
                    path: selection.path,
                    bytes: max(0, selection.bytes),
                    identity: identity,
                    allowedRestoreRoot: URL(fileURLWithPath: selection.path).deletingLastPathComponent()
                )
            },
            ruleID: ruleID,
            validate: { item in
                try await beforeEachMove()
                guard let selection = selections[item.path] else {
                    throw RecordedTrashOperation.Skip(reason: .preflightNotApproved)
                }
                // D54 ③: the apps running right now, for a folder.
                var current = policy
                if selection.isDirectory {
                    let running = await environment.runningApplicationState()
                    current.runningApplicationPaths = running.paths
                    current.unknownRunningApplicationNames = running.unknownApplicationNames
                }
                let unknownApplications = current.unknownRunningApplicationNames
                func skip(_ block: FileAnalysisTrashBlock, as reason: CleanSkipReason? = nil) -> RecordedTrashOperation.Skip {
                    reasons.withValue { $0[item.path] = block.explanation(naming: unknownApplications) }
                    return RecordedTrashOperation.Skip(reason: reason ?? block.skipReason)
                }
                switch check(selection, index: index, policy: current, environment: environment) {
                case .failure(let block):
                    throw skip(block)
                case .success(let identity):
                    guard identity == item.identity else { throw skip(.changedSinceAnalysis, as: .identityChanged) }
                }
                guard selection.isDirectory, !verified.withValue({ $0.contains(item.path) }) else { return }
                let done = processed.withValue { $0 }
                progress(FileAnalysisTrashProgress(processed: done, total: total, verifyingTitle: selection.title))
                if let block = try verifyFolder(
                    at: item.path, index: index, targetKind: policy.targetKind, excludedPaths: excludedPaths,
                    options: environment.verificationOptions,
                    progress: { count in
                        progress(FileAnalysisTrashProgress(processed: done, total: total,
                                                           verifyingTitle: selection.title, verifiedItemCount: count))
                    }
                ) {
                    throw skip(block)
                }
                verified.withValue { _ = $0.insert(item.path) }
            },
            move: { url in try environment.moveToTrash(url) },
            metadata: environment.metadata,
            persist: { report, identities in
                try environment.journal.checkpoint(report, expectedIdentities: identities)
            },
            progress: { report in
                let done = report.items.filter {
                    if case .notProcessed = $0.outcome { return false }
                    if case .failed(let failure) = $0.outcome, failure.detailCode == "move-in-flight" { return false }
                    return true
                }.count
                processed.withValue { $0 = done }
                progress(FileAnalysisTrashProgress(processed: done, total: total))
            }
        )
        var result = outcome(of: report, selections: selections, reasons: reasons.withValue { $0 },
                             environment: environment, volumeNames: volumeNames)
        // D93 P1-2: the completion page says "at most" for hard-linked files.
        result.otherHardLinkPaths = Set(items.filter { $0.isReady && $0.hasOtherHardLinks }.map(\.selection.path))
        return result
    }

    private static func outcome(
        of report: CleanReport,
        selections: [String: FileAnalysisTrashSelection],
        reasons: [String: String],
        environment: FileAnalysisTrashEnvironment,
        volumeNames: [String]
    ) -> FileAnalysisTrashOutcome {
        var moved: [String] = []
        var movedBytes: Int64 = 0
        var skipped: [FileAnalysisTrashOutcome.Skipped] = []
        var notRestorableHere = 0
        let cancelled = report.outcome == .cancelled
        // Review P2-2: a receipt write failed, so the run stopped there.
        let receiptStopped = report.persistenceFailure != nil
        func title(_ path: String) -> String {
            selections[path]?.title ?? (path as NSString).lastPathComponent
        }
        for row in report.items {
            switch row.outcome {
            case .moved(let receipt):
                moved.append(row.sourcePath)
                movedBytes += max(0, row.estimatedBytes)
                if !receipt.isRestorable || !PathSafety.isContained(
                    receipt.resultingItemURL.path, in: environment.userTrashPath, resolvingSymlinks: false
                ) {
                    notRestorableHere += 1
                }
            case .skipped(let reason):
                skipped.append(.init(path: row.sourcePath, title: title(row.sourcePath),
                                     reason: reasons[row.sourcePath] ?? CleanSkipReasonPresentation.title(reason)))
            case .failed(let failure):
                var status = stat()
                if failure.code == .moveOutcomeUnknown, Darwin.lstat(row.sourcePath, &status) != 0, errno == ENOENT {
                    // Gone from its place but not confirmed in the Trash: the
                    // receipt says "needs verification"; the map drops it.
                    moved.append(row.sourcePath)
                    movedBytes += max(0, row.estimatedBytes)
                    notRestorableHere += 1
                } else {
                    skipped.append(.init(path: row.sourcePath, title: title(row.sourcePath),
                                         reason: CleanFailurePresentation.title(failure)))
                }
            case .notProcessed:
                let reason: String
                if cancelled {
                    reason = L10n.text("已停止，未处理", "Stopped; not processed")
                } else if receiptStopped {
                    reason = L10n.text("操作记录写入失败，已停下，未处理",
                                       "Stopped because Operation History could not be written; not processed")
                } else {
                    reason = L10n.text("未处理", "Not processed")
                }
                skipped.append(.init(path: row.sourcePath, title: title(row.sourcePath), reason: reason))
            case .deleted:
                break
            }
        }
        let receiptUnavailable = report.persistenceFailure == "intent-write-failed" && moved.isEmpty
        return FileAnalysisTrashOutcome(
            report: report,
            movedPaths: moved,
            movedBytes: movedBytes,
            skipped: skipped,
            notRestorableHereCount: notRestorableHere,
            externalVolumeNames: volumeNames,
            receiptUnavailable: receiptUnavailable,
            cancelled: cancelled,
            receiptIncomplete: receiptStopped && !receiptUnavailable
        )
    }
}

/// A value shared by the closures of one move.
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
