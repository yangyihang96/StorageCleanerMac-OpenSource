import Darwin
import Foundation

typealias DiskScanProgressHandler = @Sendable (DiskScanProgress) -> Void

enum ScanProgressKind: Equatable, Sendable {
    case determinate
    case indeterminate
}

private func storagePathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
    let left = PathSafety.normalizedPath(lhs)
    let right = PathSafety.normalizedPath(rhs)
    return left == right
        || left.hasPrefix(right + "/")
        || right.hasPrefix(left + "/")
}

private func storagePathDepth(_ path: String) -> Int {
    PathSafety.normalizedPath(path).split(separator: "/").count
}

struct DiskScanProgress: Equatable, Sendable {
    struct GroupSummary: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let itemCount: Int
        let bytes: Int64
        let risk: CleanupRisk
        let state: CleanupScanRuleState
        let currentPath: String?

        init(
            id: String,
            title: String,
            itemCount: Int,
            bytes: Int64,
            risk: CleanupRisk = .informational,
            state: CleanupScanRuleState = .pending,
            currentPath: String? = nil
        ) {
            self.id = id
            self.title = title
            self.itemCount = itemCount
            self.bytes = bytes
            self.risk = risk
            self.state = state
            self.currentPath = currentPath
        }
    }

    let currentGroupTitle: String
    /// 正在扫描的具体位置（清理 V2 扫描时提供）。
    var currentPath: String? = nil
    let completedGroupCount: Int
    let totalGroupCount: Int
    let currentGroupCompletedItemCount: Int
    let currentGroupTotalItemCount: Int
    let discoveredItemCount: Int
    let discoveredBytes: Int64
    let groups: [GroupSummary]
    let progressKind: ScanProgressKind

    init(
        currentGroupTitle: String,
        completedGroupCount: Int,
        totalGroupCount: Int,
        currentGroupCompletedItemCount: Int = 0,
        currentGroupTotalItemCount: Int = 0,
        groups: [StorageGroup],
        progressKind: ScanProgressKind = .determinate
    ) {
        self.currentGroupTitle = currentGroupTitle
        self.completedGroupCount = min(max(0, completedGroupCount), max(1, totalGroupCount))
        self.totalGroupCount = max(1, totalGroupCount)
        self.currentGroupCompletedItemCount = min(
            max(0, currentGroupCompletedItemCount),
            max(0, currentGroupTotalItemCount)
        )
        self.currentGroupTotalItemCount = max(0, currentGroupTotalItemCount)

        let discoveredEntries = groups
            .flatMap { $0.entries }
            .filter { !$0.denied }
            .sorted {
                let leftDepth = storagePathDepth($0.path)
                let rightDepth = storagePathDepth($1.path)
                if leftDepth == rightDepth {
                    return $0.sizeBytes > $1.sizeBytes
                }
                return leftDepth < rightDepth
            }
        var coveredPaths = [String]()
        var discoveredItemCount = 0
        var discoveredBytes: Int64 = 0
        self.groups = groups.map { group in
            let entries = group.entries.filter { !$0.denied }
            return GroupSummary(
                id: group.id,
                title: group.title,
                itemCount: entries.count,
                bytes: entries.reduce(0) { $0 + max(0, $1.sizeBytes) },
                state: entries.isEmpty ? .clean : .found
            )
        }
        for entry in discoveredEntries {
            guard !coveredPaths.contains(where: { storagePathsOverlap($0, entry.path) }) else {
                continue
            }
            coveredPaths.append(entry.path)
            discoveredItemCount += 1
            discoveredBytes += max(0, entry.sizeBytes)
        }
        self.discoveredItemCount = discoveredItemCount
        self.discoveredBytes = discoveredBytes
        self.progressKind = progressKind
    }

    init(cleanupProgress: CleanupScanProgress) {
        currentGroupTitle = cleanupProgress.currentRuleTitle
        currentPath = cleanupProgress.currentPath
        completedGroupCount = cleanupProgress.completedRuleCount
        totalGroupCount = max(1, cleanupProgress.totalRuleCount)
        currentGroupCompletedItemCount = min(
            max(0, cleanupProgress.currentRuleCompletedItemCount),
            max(0, cleanupProgress.currentRuleTotalItemCount)
        )
        currentGroupTotalItemCount = max(0, cleanupProgress.currentRuleTotalItemCount)
        discoveredItemCount = cleanupProgress.discoveredItemCount
        discoveredBytes = cleanupProgress.discoveredBytes
        progressKind = cleanupProgress.phase == .preparing ? .indeterminate : .determinate
        groups = cleanupProgress.groups.map {
            GroupSummary(
                id: $0.id,
                title: $0.title,
                itemCount: $0.itemCount,
                bytes: $0.bytes,
                risk: $0.risk,
                state: $0.state,
                currentPath: $0.currentPath
            )
        }
    }

    var fractionCompleted: Double {
        let currentGroupFraction = currentGroupTotalItemCount > 0
            ? Double(currentGroupCompletedItemCount) / Double(currentGroupTotalItemCount)
            : 0
        return min(
            1,
            (Double(completedGroupCount) + currentGroupFraction) / Double(totalGroupCount)
        )
    }

    static func starting(mode: ScanMode) -> DiskScanProgress {
        DiskScanProgress(
            currentGroupTitle: L10n.text("准备扫描范围", "Preparing scan scope"),
            completedGroupCount: 0,
            totalGroupCount: DiskScanner.plannedPrimaryGroupIDs(for: mode).count
                + DiskScanner.plannedSupplementaryGroupIDs(for: mode).count,
            groups: [],
            progressKind: .indeterminate
        )
    }
}

enum StorageMapAnalysisError: LocalizedError {
    case outsideAllowedScope
    case symbolicLinkPath
    case unavailable
    case notDirectory
    case unreadable

    var errorDescription: String? {
        switch self {
        case .outsideAllowedScope:
            L10n.text("只能继续分析用户目录中的项目", "Only items inside the user folder can be explored")
        case .symbolicLinkPath:
            L10n.text("不能沿符号链接继续分析", "Symbolic links cannot be explored")
        case .unavailable:
            L10n.text("这个项目已经不存在或当前不可用", "This item no longer exists or is unavailable")
        case .notDirectory:
            L10n.text("这个项目不是可展开的文件夹", "This item is not an expandable folder")
        case .unreadable:
            L10n.text("无法读取这个文件夹；请检查权限或稍后重试", "This folder could not be read; check access and try again")
        }
    }
}

struct DiskScanner {
    struct KnownDeveloperArtifactPath: Sendable {
        let name: String
        let path: String
        let minimumBytes: Int64
    }

    private final class DirectoryReadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[URL], Error>?

        func set(_ result: Result<[URL], Error>) {
            lock.lock()
            value = result
            lock.unlock()
        }

        func get() -> Result<[URL], Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class TreeSizeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var accumulatedBytes: Int64 = 0

        func update(_ bytes: Int64) {
            lock.lock()
            accumulatedBytes = bytes
            lock.unlock()
        }

        var currentBytes: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return accumulatedBytes
        }
    }

    private enum DirectoryReadError: Error {
        case timedOut
    }

    private struct ScanTarget: Sendable {
        let key: String
        let title: String
        let path: String
        let minimumBytes: Int64
        let limit: Int
    }

    private struct StorageMapBucket {
        let title: String
        let path: String
        let isDirectory: Bool
        let isPhysicalDirectory: Bool
        let kind: String
        var contentCategory: StorageMapContentCategory
        var sizeBytes: Int64 = 0
        var childCount = 0
        var isComplete = true
    }

    private struct StorageMapTreeMeasurement {
        let sizeBytes: Int64
        let childCount: Int
        let inspectedItemCount: Int
        let isComplete: Bool
        let contentProfile: StorageMapContentProfile
    }

    private struct StorageMapMutableDirectory {
        let path: String
        let parentID: Int?
        var directBytes: Int64 = 0
        var immediateChildCount = 0
        var descendantItemCount = 0
        var isComplete = true
        var contentProfile = StorageMapContentProfile()
        var categoryOverride: StorageMapContentCategory? = nil
    }

    private struct StorageMapHardLinkOccurrence {
        let path: String
        let parentID: Int
        let measuredBytes: Int64
        let contentCategory: StorageMapContentCategory
    }

    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let excludedPaths: [String]
    private let directorySizeTimeout: TimeInterval = 0.8
    private let directoryReadTimeout: TimeInterval = 1
    private let scanMode: ScanMode
    private let progressHandler: DiskScanProgressHandler?
    private let largeFileRootOverrides: [String]?

    init(
        excludedPaths: [String] = ScanExclusionService.excludedPaths(),
        scanMode: ScanMode = .fallback,
        progressHandler: DiskScanProgressHandler? = nil,
        largeFileRoots: [String]? = nil
    ) {
        self.excludedPaths = excludedPaths
        self.scanMode = scanMode
        self.progressHandler = progressHandler
        largeFileRootOverrides = largeFileRoots
    }

    static func itemsForDuplicateEntries(_ entries: [DirectoryEntry]) -> [StorageItem] {
        StorageClassifier.classify(
            groups: [
                StorageGroup(
                    id: "duplicate_files",
                    title: L10n.text("疑似重复文件", "Possible Duplicates"),
                    entries: entries
                )
            ]
        )
    }

    static func itemsForDuplicateGroups(_ groups: [DuplicateFileGroup]) -> [StorageItem] {
        let entries = groups.flatMap(\.files)
        let metadataByPath = Dictionary(
            uniqueKeysWithValues: groups.flatMap { group in
                group.files.map { entry in
                    (
                        PathSafety.normalizedPath(entry.path),
                        (
                            group.id,
                            group.matchKind.rawValue,
                            group.relationship.rawValue,
                            group.estimatedPhysicalReclaimableBytes
                        )
                    )
                }
            }
        )
        return itemsForDuplicateEntries(entries).map { item in
            let metadata = metadataByPath[PathSafety.normalizedPath(item.path)]
            return StorageItem(
                id: item.id,
                title: item.title,
                path: item.path,
                sourceID: item.sourceID,
                groupTitle: item.groupTitle,
                sizeBytes: item.sizeBytes,
                tier: item.tier,
                kind: item.kind,
                reason: item.reason,
                recommendation: item.recommendation,
                risk: item.risk,
                requiresClose: item.requiresClose,
                trashPaths: item.trashPaths,
                openPath: item.openPath,
                isDirectory: item.isDirectory,
                duplicateGroupID: metadata?.0,
                duplicateMatchKind: metadata?.1,
                duplicateRelationship: metadata?.2,
                duplicatePhysicalReclaimableBytes: metadata?.3,
                status: item.status
            )
        }
    }

    static func plannedPrimaryGroupIDs(for mode: ScanMode) -> [String] {
        mode.primaryGroupIDs
    }

    static func plannedSupplementaryGroupIDs(for mode: ScanMode) -> [String] {
        mode.supplementaryGroupIDs
    }

    static func plannedLargeFileRoots(for mode: ScanMode, homePath: String = PathSafety.homePath) -> [String] {
        ["\(homePath)/Downloads", "\(homePath)/Desktop", "\(homePath)/Documents"]
    }

    static func storageMapScanTargets() -> [StorageMapScanTarget] {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        let internalName = (try? rootURL.resourceValues(forKeys: [.volumeNameKey]))?
            .volumeName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let homeURL = fileManager.homeDirectoryForCurrentUser

        var targets = [
            StorageMapScanTarget(
                // Scan the logical APFS volume-group view. Top-level firmlinks
                // such as Applications, Users, Library, and private then match
                // the hierarchy users see in Finder and Tencent Lemon.
                path: "/",
                title: internalName?.nonEmpty ?? L10n.text("Macintosh HD", "Macintosh HD"),
                kind: .internalVolume
            ),
            StorageMapScanTarget(
                path: homeURL.path,
                title: L10n.text("个人目录", "Home Folder"),
                kind: .homeDirectory
            ),
        ]

        let volumeKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey,
        ]
        let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeKeys),
            options: [.skipHiddenVolumes]
        ) ?? []
        for volumeURL in mountedVolumes {
            guard let values = try? volumeURL.resourceValues(forKeys: volumeKeys),
                  values.volumeIsLocal != false,
                  values.volumeIsInternal == false,
                  values.volumeIsBrowsable != false else { continue }
            let title = values.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
                ?? volumeURL.lastPathComponent.nonEmpty
                ?? L10n.text("外接硬盘", "External Drive")
            targets.append(StorageMapScanTarget(
                path: volumeURL.path,
                title: title,
                kind: .externalVolume
            ))
        }

        var seen = Set<String>()
        return targets.filter { seen.insert($0.id).inserted }
    }

    static func shouldSkipLogicalDataMirror(
        path: String,
        rootPath: String,
        targetKind: StorageMapScanTarget.Kind
    ) -> Bool {
        guard targetKind == .internalVolume, rootPath == "/" else { return false }
        return path == "/System/Volumes/Data"
            || path.hasPrefix("/System/Volumes/Data/")
    }

    static func storageMapPath(_ path: String, isWithinRoot rootPath: String) -> Bool {
        if path == rootPath { return true }
        if rootPath == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(rootPath + "/")
    }

    /// Normalizes `.` and `..` without resolving macOS firmlinks. Foundation's
    /// standard path APIs intentionally rewrite `/private/var` to `/var`, which
    /// is correct for file access but wrong for the logical hierarchy displayed
    /// by a disk-space analyzer.
    static func storageMapLogicalPath(_ rawPath: String) -> String {
        let absolute = rawPath.hasPrefix("/")
        var components = [Substring]()
        for component in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        if absolute { return joined.isEmpty ? "/" : "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    static func storageMapParentPath(_ path: String) -> String {
        let logicalPath = storageMapLogicalPath(path)
        guard logicalPath != "/" else { return "/" }
        guard let separator = logicalPath.lastIndex(of: "/") else { return "." }
        return separator == logicalPath.startIndex
            ? "/"
            : String(logicalPath[..<separator])
    }

    static func storageMapEnumeratedPath(
        itemName: String,
        level: Int,
        rootPath: String,
        pathsByLevel: inout [String]
    ) -> String {
        let boundedLevel = max(1, level)
        let parentLevel = boundedLevel - 1
        let parentPath = parentLevel < pathsByLevel.count
            ? pathsByLevel[parentLevel]
            : rootPath
        // `standardizedFileURL` rewrites macOS firmlink paths such as
        // `/private/var` back to `/var`. The storage map needs the logical
        // hierarchy shown by Finder and peer disk analyzers, so compose the
        // display/index path from the enumerator depth without resolving it.
        let path = parentPath == "/"
            ? "/" + itemName
            : parentPath + "/" + itemName
        if pathsByLevel.count > boundedLevel {
            pathsByLevel[boundedLevel] = path
            pathsByLevel.removeSubrange((boundedLevel + 1)..<pathsByLevel.count)
        } else {
            while pathsByLevel.count < boundedLevel {
                pathsByLevel.append(parentPath)
            }
            pathsByLevel.append(path)
        }
        return path
    }

    static func storageMapPreferredSize(
        logicalSize: Int?,
        allocatedSize: Int?,
        path: String
    ) -> Int? {
        let isApplicationBundleContent = path.hasPrefix("/Applications/")
            && path.range(of: ".app/", options: .caseInsensitive) != nil
        return isApplicationBundleContent
            ? logicalSize ?? allocatedSize
            : allocatedSize ?? logicalSize
    }

    /// Builds one immutable directory index for the selected volume or folder.
    /// Every later drill-down reuses this index, so changing levels never starts
    /// another recursive tree-size scan. The walk is read-only, remains off the
    /// main actor, does not follow symbolic links, and de-duplicates hard links.
    func storageMapAnalysis(
        target: StorageMapScanTarget,
        progressHandler: (@Sendable (StorageMapScanProgress) -> Void)? = nil
    ) throws -> StorageMapAnalysisResult {
        let startedAt = Date()
        let rootPath = PathSafety.lexicalPath(target.path)
        guard PathSafety.normalizedPath(rootPath) == rootPath else {
            throw StorageMapAnalysisError.symbolicLinkPath
        }
        guard !isExcluded(rootPath) else {
            throw StorageMapAnalysisError.unreadable
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory) else {
            throw StorageMapAnalysisError.unavailable
        }
        guard isDirectory.boolValue else {
            throw StorageMapAnalysisError.notDirectory
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let rootKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .volumeIdentifierKey,
        ]
        guard let rootValues = try? rootURL.resourceValues(forKeys: rootKeys),
              rootValues.isDirectory == true else {
            throw StorageMapAnalysisError.unreadable
        }
        guard rootValues.isSymbolicLink != true else {
            throw StorageMapAnalysisError.symbolicLinkPath
        }
        let rootVolumeIdentifier = rootValues.volumeIdentifier.map { String(describing: $0) }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .volumeIdentifierKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let lexicalExclusionRoots = excludedPaths.map(PathSafety.lexicalPath)
        let isStorageMapExcluded: (String) -> Bool = { path in
            lexicalExclusionRoots.contains { excluded in
                path == excluded || path.hasPrefix(excluded + "/")
            }
        }

        var directories = [
            StorageMapMutableDirectory(path: rootPath, parentID: nil)
        ]
        var directoryIDByPath = [rootPath: 0]
        var childrenByDirectory = [rootPath: [StorageMapIndexedEntry]()]
        var blockedDirectoryPaths = Set<String>()
        var duplicateFilePaths = Set<String>()
        var hardLinkOccurrences = [FileIdentity: [StorageMapHardLinkOccurrence]]()
        var enumeratorErrorPaths = [String]()
        var omittedItemCount = 0
        var inspectedItemCount = 0
        var runningMeasuredBytes: Int64 = 0
        var lastProgressDate = Date.distantPast
        var enumeratedPathsByLevel = [rootPath]

        func appendEntry(
            _ entry: StorageMapIndexedEntry,
            parentPath: String,
            parentID: Int
        ) {
            childrenByDirectory[parentPath, default: []].append(entry)
            directories[parentID].immediateChildCount += 1
        }

        func createDirectory(
            path: String,
            parentID: Int,
            isComplete: Bool,
            categoryOverride: StorageMapContentCategory? = nil
        ) -> Int {
            if let existing = directoryIDByPath[path] {
                if !isComplete { directories[existing].isComplete = false }
                if let categoryOverride {
                    directories[existing].categoryOverride = categoryOverride
                }
                return existing
            }
            let id = directories.count
            directoryIDByPath[path] = id
            directories.append(StorageMapMutableDirectory(
                path: path,
                parentID: parentID,
                isComplete: isComplete,
                categoryOverride: categoryOverride
            ))
            childrenByDirectory[path] = []
            return id
        }

        func markIncomplete(path: String) {
            if let id = directoryIDByPath[path] {
                directories[id].isComplete = false
                return
            }
            let parentPath = Self.storageMapParentPath(path)
            if let parentID = directoryIDByPath[parentPath] {
                directories[parentID].isComplete = false
            } else {
                directories[0].isComplete = false
            }
        }

        func hardLinkIdentity(at url: URL) -> (identity: FileIdentity?, succeeded: Bool) {
            var metadata = stat()
            let status = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.lstat(path, &metadata)
            }
            guard status == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
                return (nil, false)
            }
            guard metadata.st_nlink > 1 else { return (nil, true) }
            return (
                FileIdentity(
                    deviceID: UInt64(bitPattern: Int64(metadata.st_dev)),
                    inode: UInt64(metadata.st_ino),
                    entryKind: .regularFile,
                    creationTimeNanoseconds: nil
                ),
                true
            )
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { url, _ in
                enumeratorErrorPaths.append(PathSafety.lexicalPath(url.path))
                return true
            }
        ) else {
            throw StorageMapAnalysisError.unreadable
        }

        while let itemURL = autoreleasepool(invoking: {
            enumerator.nextObject() as? URL
        }) {
            try autoreleasepool {
            if Task.isCancelled { throw CancellationError() }
            inspectedItemCount += 1

            let itemPath = Self.storageMapEnumeratedPath(
                itemName: itemURL.lastPathComponent,
                level: enumerator.level,
                rootPath: rootPath,
                pathsByLevel: &enumeratedPathsByLevel
            )
            guard Self.storageMapPath(itemPath, isWithinRoot: rootPath) else {
                omittedItemCount += 1
                return
            }
            let parentPath = Self.storageMapParentPath(itemPath)
            guard let parentID = directoryIDByPath[parentPath] else {
                omittedItemCount += 1
                markIncomplete(path: parentPath)
                return
            }

            let values: URLResourceValues
            do {
                values = try itemURL.resourceValues(forKeys: resourceKeys)
            } catch {
                appendEntry(
                    StorageMapIndexedEntry(
                        name: itemURL.lastPathComponent,
                        kind: "unavailable",
                        sizeBytes: nil,
                        isDirectory: false,
                        canDescend: false,
                        isEstimated: true
                    ),
                    parentPath: parentPath,
                    parentID: parentID
                )
                directories[parentID].descendantItemCount += 1
                directories[parentID].isComplete = false
                omittedItemCount += 1
                return
            }

            let physicalDirectory = values.isDirectory == true
            let symbolicLink = values.isSymbolicLink == true
            let package = physicalDirectory && values.isPackage == true
            let cloudPlaceholder = values.isUbiquitousItem == true
                && values.ubiquitousItemDownloadingStatus != .current

            if Self.shouldSkipLogicalDataMirror(
                path: itemPath,
                rootPath: rootPath,
                targetKind: target.kind
            ) {
                if physicalDirectory { enumerator.skipDescendants() }
                return
            }

            if let rootVolumeIdentifier,
               let itemVolumeIdentifier = values.volumeIdentifier.map({ String(describing: $0) }),
               itemVolumeIdentifier != rootVolumeIdentifier {
                if physicalDirectory { enumerator.skipDescendants() }
                return
            }

            if symbolicLink {
                let bytes = Int64(max(
                    0,
                    values.fileAllocatedSize ?? 0
                ))
                let contentCategory = StorageMapContentCategory.system
                appendEntry(
                    StorageMapIndexedEntry(
                        name: itemURL.lastPathComponent,
                        kind: "alias",
                        sizeBytes: bytes,
                        isDirectory: false,
                        canDescend: false,
                        isEstimated: false
                    ),
                    parentPath: parentPath,
                    parentID: parentID
                )
                directories[parentID].directBytes += bytes
                directories[parentID].contentProfile.add(
                    bytes: bytes,
                    to: contentCategory
                )
                directories[parentID].descendantItemCount += 1
                runningMeasuredBytes += bytes
                if physicalDirectory { enumerator.skipDescendants() }
            } else if isStorageMapExcluded(itemPath) {
                appendEntry(
                    StorageMapIndexedEntry(
                        name: itemURL.lastPathComponent,
                        kind: physicalDirectory ? "folder" : "excluded",
                        sizeBytes: nil,
                        isDirectory: physicalDirectory,
                        canDescend: false,
                        isEstimated: true
                    ),
                    parentPath: parentPath,
                    parentID: parentID
                )
                if physicalDirectory {
                    _ = createDirectory(
                        path: itemPath,
                        parentID: parentID,
                        isComplete: false
                    )
                    blockedDirectoryPaths.insert(itemPath)
                    enumerator.skipDescendants()
                } else {
                    directories[parentID].descendantItemCount += 1
                    directories[parentID].isComplete = false
                }
                omittedItemCount += 1
            } else if physicalDirectory {
                let canDescend = !package && !cloudPlaceholder
                let packageCategory = package
                    ? StorageMapContentCategory.classify(
                        name: itemURL.lastPathComponent,
                        kind: "package",
                        isDirectory: true
                    )
                    : nil
                appendEntry(
                    StorageMapIndexedEntry(
                        name: itemURL.lastPathComponent,
                        kind: package ? "package" : "folder",
                        sizeBytes: nil,
                        isDirectory: true,
                        canDescend: canDescend,
                        isEstimated: cloudPlaceholder
                    ),
                    parentPath: parentPath,
                    parentID: parentID
                )
                _ = createDirectory(
                    path: itemPath,
                    parentID: parentID,
                    isComplete: !cloudPlaceholder,
                    categoryOverride: packageCategory
                )
                if package {
                    blockedDirectoryPaths.insert(itemPath)
                }
                if cloudPlaceholder {
                    blockedDirectoryPaths.insert(itemPath)
                    omittedItemCount += 1
                    enumerator.skipDescendants()
                }
            } else {
                let measuredSize = Self.storageMapPreferredSize(
                    logicalSize: values.fileSize,
                    allocatedSize: values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize,
                    path: itemPath
                )
                let bytes = Int64(max(0, measuredSize ?? 0))
                let kind = itemURL.pathExtension.lowercased().nonEmpty ?? "file"
                let contentCategory = StorageMapContentCategory.classify(
                    name: itemURL.lastPathComponent,
                    kind: kind,
                    isDirectory: false
                )
                appendEntry(
                    StorageMapIndexedEntry(
                        name: itemURL.lastPathComponent,
                        kind: kind,
                        sizeBytes: measuredSize.map { Int64(max(0, $0)) },
                        isDirectory: false,
                        canDescend: false,
                        isEstimated: measuredSize == nil || cloudPlaceholder
                    ),
                    parentPath: parentPath,
                    parentID: parentID
                )
                directories[parentID].descendantItemCount += 1
                if measuredSize == nil {
                    directories[parentID].isComplete = false
                    omittedItemCount += 1
                }

                let hardLink = hardLinkIdentity(at: itemURL)
                if !hardLink.succeeded {
                    directories[parentID].isComplete = false
                }
                if let identity = hardLink.identity {
                    let isFirstOccurrence = hardLinkOccurrences[identity]?.isEmpty ?? true
                    hardLinkOccurrences[identity, default: []].append(
                        StorageMapHardLinkOccurrence(
                            path: itemPath,
                            parentID: parentID,
                            measuredBytes: bytes,
                            contentCategory: contentCategory
                        )
                    )
                    if isFirstOccurrence { runningMeasuredBytes += bytes }
                } else {
                    directories[parentID].directBytes += bytes
                    directories[parentID].contentProfile.add(
                        bytes: bytes,
                        to: contentCategory
                    )
                    runningMeasuredBytes += bytes
                }
            }

            let now = Date()
            if inspectedItemCount == 1
                || inspectedItemCount.isMultiple(of: 512)
                || now.timeIntervalSince(lastProgressDate) >= 0.12 {
                lastProgressDate = now
                progressHandler?(StorageMapScanProgress(
                    currentPath: itemPath,
                    inspectedItemCount: inspectedItemCount,
                    measuredBytes: runningMeasuredBytes
                ))
            }
            }
        }

        for errorPath in enumeratorErrorPaths {
            omittedItemCount += 1
            let normalizedErrorPath = PathSafety.lexicalPath(errorPath)
            markIncomplete(path: normalizedErrorPath)
            if directoryIDByPath[normalizedErrorPath] != nil {
                blockedDirectoryPaths.insert(normalizedErrorPath)
            }
        }
        if Task.isCancelled { throw CancellationError() }

        for occurrences in hardLinkOccurrences.values {
            guard let canonical = occurrences.min(by: {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }) else { continue }
            let canonicalBytes = occurrences.reduce(canonical.measuredBytes) {
                max($0, $1.measuredBytes)
            }
            directories[canonical.parentID].directBytes += canonicalBytes
            directories[canonical.parentID].contentProfile.add(
                bytes: canonicalBytes,
                to: canonical.contentCategory
            )
            for occurrence in occurrences where occurrence.path != canonical.path {
                duplicateFilePaths.insert(occurrence.path)
            }
        }

        for directoryID in directories.indices.reversed() {
            guard let parentID = directories[directoryID].parentID else { continue }
            let child = directories[directoryID]
            directories[parentID].directBytes += child.directBytes
            let childProfile = child.categoryOverride.map {
                StorageMapContentProfile(category: $0, bytes: child.directBytes)
            } ?? child.contentProfile
            directories[parentID].contentProfile.merge(childProfile)
            directories[parentID].descendantItemCount += child.descendantItemCount + 1
            if !child.isComplete {
                directories[parentID].isComplete = false
            }
        }

        let directoryAggregates = Dictionary(uniqueKeysWithValues: directories.map { directory in
            let contentProfile = directory.categoryOverride.map {
                StorageMapContentProfile(category: $0, bytes: directory.directBytes)
            } ?? directory.contentProfile
            return (
                directory.path,
                StorageMapDirectoryAggregate(
                    sizeBytes: directory.directBytes,
                    immediateChildCount: directory.immediateChildCount,
                    descendantItemCount: directory.descendantItemCount,
                    isComplete: directory.isComplete,
                    contentProfile: contentProfile
                )
            )
        })
        let index = StorageMapAnalysisIndex(
            rootPath: rootPath,
            rootVolumeIdentifier: rootVolumeIdentifier,
            directories: directoryAggregates,
            childrenByDirectory: childrenByDirectory,
            blockedDirectoryPaths: blockedDirectoryPaths,
            duplicateFilePaths: duplicateFilePaths
        )
        let rootSnapshot = try storageMapSnapshot(
            at: rootPath,
            using: index,
            titleOverride: target.title
        )
        let capacity = StorageCapacityService.snapshot(path: rootPath)
        let elapsed = Date().timeIntervalSince(startedAt)
        progressHandler?(StorageMapScanProgress(
            currentPath: rootPath,
            inspectedItemCount: inspectedItemCount,
            measuredBytes: rootSnapshot.measuredBytes
        ))
        return StorageMapAnalysisResult(
            target: target,
            volumeTotalBytes: capacity?.totalBytes ?? 0,
            // Match Finder and peer disk analyzers: this user-facing value may
            // include capacity macOS can reclaim for important usage. Cleanup
            // preflight continues to use the stricter filesystem-free value.
            volumeAvailableBytes: capacity?.userAvailableBytes ?? 0,
            inspectedItemCount: inspectedItemCount,
            omittedItemCount: omittedItemCount,
            scanSeconds: elapsed,
            index: index,
            rootSnapshot: rootSnapshot
        )
    }

    /// Resolves a level entirely from the captured index. No file-system read,
    /// size query, or recursive walk occurs while the user navigates.
    func storageMapSnapshot(
        at rawPath: String,
        using index: StorageMapAnalysisIndex,
        titleOverride: String? = nil,
        limit: Int = .max
    ) throws -> StorageMapDirectorySnapshot {
        let rootPath = Self.storageMapLogicalPath(index.rootPath)
        let logicalPath = Self.storageMapLogicalPath(rawPath)
        // Paths produced by this index must keep their logical firmlink
        // hierarchy. A caller may still pass the equivalent physical spelling
        // for a separately selected folder (for example `/private/tmp` for an
        // index rooted at `/tmp`), so fall back only when no logical key exists.
        let path = index.directories[logicalPath] != nil
            ? logicalPath
            : PathSafety.lexicalPath(rawPath)
        guard Self.storageMapPath(path, isWithinRoot: rootPath) else {
            throw StorageMapAnalysisError.outsideAllowedScope
        }
        guard let aggregate = index.directories[path] else {
            throw StorageMapAnalysisError.unavailable
        }
        guard !index.blockedDirectoryPaths.contains(path) || path == rootPath else {
            throw StorageMapAnalysisError.unreadable
        }

        let indexedEntries = index.childrenByDirectory[path] ?? []
        var entries = indexedEntries.map { indexed -> StorageTreemapEntry in
            let childPath = (path as NSString).appendingPathComponent(indexed.name)
            let childAggregate = indexed.isDirectory
                ? index.directories[childPath]
                : nil
            let isDuplicate = index.duplicateFilePaths.contains(childPath)
            let sizeBytes = indexed.isDirectory
                ? (childAggregate?.sizeBytes ?? 0)
                : isDuplicate
                    ? 0
                    : (indexed.sizeBytes ?? 0)
            let canDescend = indexed.isDirectory
                && indexed.canDescend
                && !index.blockedDirectoryPaths.contains(childPath)
                && childAggregate != nil
            return StorageTreemapEntry(
                id: childPath,
                title: indexed.name,
                path: childPath,
                sizeBytes: sizeBytes,
                kind: indexed.kind,
                isDirectory: indexed.isDirectory,
                canDescend: canDescend,
                childCount: indexed.isDirectory
                    ? childAggregate?.immediateChildCount
                    : nil,
                isEstimated: indexed.isEstimated
                    || indexed.sizeBytes == nil && !indexed.isDirectory
                    || indexed.isDirectory && childAggregate?.isComplete != true,
                contentCategory: indexed.isDirectory
                    ? childAggregate?.dominantContentCategory
                        ?? StorageMapContentCategory.classify(
                            name: indexed.name,
                            kind: indexed.kind,
                            isDirectory: true
                        )
                    : StorageMapContentCategory.classify(
                        name: indexed.name,
                        kind: indexed.kind,
                        isDirectory: false
                    )
            )
        }
        entries.sort { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        let boundedLimit = max(1, limit)
        let visibleEntries = Array(entries.prefix(boundedLimit))
        return StorageMapDirectorySnapshot(
            path: path,
            title: titleOverride?.nonEmpty
                ?? URL(fileURLWithPath: path, isDirectory: true).lastPathComponent.nonEmpty
                ?? path,
            entries: visibleEntries,
            measuredBytes: aggregate.sizeBytes,
            referenceBytes: aggregate.sizeBytes,
            referenceIsEstimated: !aggregate.isComplete,
            inspectedItemCount: aggregate.descendantItemCount,
            omittedEntryCount: max(0, entries.count - visibleEntries.count),
            isComplete: aggregate.isComplete
        )
    }
    /// Continues the existing large-file analysis for one selected directory.
    /// The implementation performs one bounded tree walk and attributes file
    /// sizes to immediate children, avoiding a separate recursive scan per row.
    /// It is read-only, never follows symbolic links, and reports partial values
    /// as lower bounds when the deadline, exclusions, permissions, or cloud
    /// placeholders prevent a complete measurement.
    func storageMapSnapshot(
        at rawPath: String,
        limit: Int = 80,
        maxScanSeconds: TimeInterval = 8
    ) throws -> StorageMapDirectorySnapshot {
        let scanBudget = maxScanSeconds.isFinite
            ? min(20, max(0.5, maxScanSeconds))
            : 8
        let rootPath = PathSafety.lexicalPath(rawPath)
        let isAllowedScope = (
            PathSafety.isLexicallyInsideHome(rootPath)
                && PathSafety.isInsideHome(rootPath)
        ) || PathSafety.isInsideTemporaryRoots(rootPath)
        guard isAllowedScope else {
            throw StorageMapAnalysisError.outsideAllowedScope
        }
        guard PathSafety.normalizedPath(rootPath) == rootPath else {
            throw StorageMapAnalysisError.symbolicLinkPath
        }
        guard !isExcluded(rootPath) else {
            throw StorageMapAnalysisError.unreadable
        }
        let lexicalExclusionRoots = excludedPaths.map(PathSafety.lexicalPath)
        let isStorageMapExcluded: (String) -> Bool = { path in
            lexicalExclusionRoots.contains { excluded in
                path == excluded || path.hasPrefix(excluded + "/")
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory) else {
            throw StorageMapAnalysisError.unavailable
        }
        guard isDirectory.boolValue else {
            throw StorageMapAnalysisError.notDirectory
        }

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let immediateURLs: [URL]
        do {
            immediateURLs = try directoryContents(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isPackageKey,
                ],
                options: [],
                timeout: min(2, scanBudget)
            )
        } catch {
            throw StorageMapAnalysisError.unreadable
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        var buckets = [StorageMapBucket]()
        var omittedForPolicyCount = 0
        var inspectedItemCount = 0
        for childURL in immediateURLs.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }) {
            if Task.isCancelled { throw CancellationError() }
            inspectedItemCount += 1
            let childPath = PathSafety.lexicalPath(childURL.path)
            guard Self.storageMapPath(childPath, isWithinRoot: rootPath) else {
                omittedForPolicyCount += 1
                continue
            }
            if isStorageMapExcluded(childPath) {
                omittedForPolicyCount += 1
                continue
            }

            guard let values = try? childURL.resourceValues(forKeys: resourceKeys) else {
                omittedForPolicyCount += 1
                continue
            }
            if values.isSymbolicLink == true {
                omittedForPolicyCount += 1
                continue
            }

            let physicalDirectory = values.isDirectory == true
            let package = physicalDirectory && values.isPackage == true
            let navigableDirectory = physicalDirectory && !package
            let title = childURL.lastPathComponent.nonEmpty ?? childPath
            let isCloudPlaceholder = values.isUbiquitousItem == true
                && values.ubiquitousItemDownloadingStatus != .current
            let immediateFileBytes = physicalDirectory
                ? 0
                : Int64(max(
                    0,
                    Self.storageMapPreferredSize(
                        logicalSize: values.fileSize,
                        allocatedSize: values.totalFileAllocatedSize
                            ?? values.fileAllocatedSize,
                        path: childPath
                    ) ?? 0
                ))
            let kind = package
                ? "package"
                : navigableDirectory
                    ? "folder"
                    : (childURL.pathExtension.lowercased().nonEmpty ?? "file")
            buckets.append(StorageMapBucket(
                title: title,
                path: childPath,
                isDirectory: navigableDirectory,
                isPhysicalDirectory: physicalDirectory,
                kind: kind,
                contentCategory: StorageMapContentCategory.classify(
                    name: title,
                    kind: kind,
                    isDirectory: physicalDirectory
                ),
                sizeBytes: immediateFileBytes,
                isComplete: !isCloudPlaceholder
            ))
        }

        // Measure each immediate directory independently and sequentially. A shared
        // depth-first walk can consume the entire budget inside the first large
        // child, leaving every later tile at 0 B. Dividing the remaining time by
        // the remaining directory count keeps I/O bounded while giving each child
        // a fair opportunity to contribute a truthful lower-bound measurement.
        let deadline = Date().addingTimeInterval(scanBudget)
        var remainingDirectoryCount = buckets.reduce(0) { partial, bucket in
            partial + (bucket.isPhysicalDirectory && bucket.isComplete ? 1 : 0)
        }
        for index in buckets.indices where buckets[index].isPhysicalDirectory {
            if Task.isCancelled { throw CancellationError() }
            guard buckets[index].isComplete else { continue }

            let remainingSeconds = max(0, deadline.timeIntervalSinceNow)
            let childBudget = remainingDirectoryCount > 0
                ? remainingSeconds / Double(remainingDirectoryCount)
                : 0
            remainingDirectoryCount = max(0, remainingDirectoryCount - 1)
            let measurement = try storageMapTreeMeasurement(
                at: URL(fileURLWithPath: buckets[index].path, isDirectory: true),
                maxScanSeconds: childBudget,
                excluded: isStorageMapExcluded
            )
            buckets[index].sizeBytes = measurement.sizeBytes
            buckets[index].childCount = measurement.childCount
            buckets[index].isComplete = measurement.isComplete
            if buckets[index].kind != "package" {
                buckets[index].contentCategory = measurement.contentProfile.dominantCategory
            }
            inspectedItemCount += measurement.inspectedItemCount
        }

        let isComplete = omittedForPolicyCount == 0 && buckets.allSatisfy(\.isComplete)
        let sortedBuckets = buckets.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        let boundedLimit = min(max(1, limit), 200)
        let entries = sortedBuckets.prefix(boundedLimit).map { bucket in
            StorageTreemapEntry(
                id: PathSafety.normalizedPath(bucket.path),
                title: bucket.title,
                path: bucket.path,
                sizeBytes: bucket.sizeBytes,
                kind: bucket.kind,
                isDirectory: bucket.isDirectory,
                childCount: bucket.isDirectory ? bucket.childCount : nil,
                isEstimated: !isComplete || !bucket.isComplete,
                contentCategory: bucket.contentCategory
            )
        }

        return StorageMapDirectorySnapshot(
            path: rootPath,
            title: rootURL.lastPathComponent.nonEmpty ?? rootPath,
            entries: entries,
            measuredBytes: sortedBuckets.reduce(0) { $0 + max(0, $1.sizeBytes) },
            inspectedItemCount: inspectedItemCount,
            omittedEntryCount: omittedForPolicyCount + max(0, sortedBuckets.count - entries.count),
            isComplete: isComplete
        )
    }

    private func storageMapTreeMeasurement(
        at rootURL: URL,
        maxScanSeconds: TimeInterval,
        excluded isStorageMapExcluded: (String) -> Bool
    ) throws -> StorageMapTreeMeasurement {
        guard maxScanSeconds > 0 else {
            return StorageMapTreeMeasurement(
                sizeBytes: 0,
                childCount: 0,
                inspectedItemCount: 0,
                isComplete: false,
                contentProfile: StorageMapContentProfile()
            )
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        var readHadErrors = false
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                readHadErrors = true
                return true
            }
        ) else {
            return StorageMapTreeMeasurement(
                sizeBytes: 0,
                childCount: 0,
                inspectedItemCount: 0,
                isComplete: false,
                contentProfile: StorageMapContentProfile()
            )
        }

        let rootPath = PathSafety.lexicalPath(rootURL.path)
        let deadline = Date().addingTimeInterval(maxScanSeconds)
        var sizeBytes: Int64 = 0
        var childCount = 0
        var inspectedItemCount = 0
        var reachedLimit = false
        var omittedForPolicy = false
        var contentProfile = StorageMapContentProfile()
        var enumeratedPathsByLevel = [rootPath]
        while let itemURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            if Date() >= deadline {
                reachedLimit = true
                break
            }
            inspectedItemCount += 1
            let itemPath = Self.storageMapEnumeratedPath(
                itemName: itemURL.lastPathComponent,
                level: enumerator.level,
                rootPath: rootPath,
                pathsByLevel: &enumeratedPathsByLevel
            )
            guard Self.storageMapPath(itemPath, isWithinRoot: rootPath) else {
                readHadErrors = true
                if (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isStorageMapExcluded(itemPath) {
                omittedForPolicy = true
                if (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let relativePath = rootPath == "/"
                ? String(itemPath.dropFirst())
                : String(itemPath.dropFirst(rootPath.count + 1))
            let relativeComponents = relativePath.split(separator: "/")

            let values: URLResourceValues
            do {
                values = try itemURL.resourceValues(forKeys: Set(keys))
            } catch {
                readHadErrors = true
                continue
            }
            if values.isSymbolicLink == true {
                omittedForPolicy = true
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                readHadErrors = true
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            if relativeComponents.count == 1 {
                childCount += 1
            }
            if values.isRegularFile == true {
                let bytes = Self.storageMapPreferredSize(
                    logicalSize: values.fileSize,
                    allocatedSize: values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize,
                    path: itemPath
                ) ?? 0
                let measuredBytes = Int64(max(0, bytes))
                sizeBytes += measuredBytes
                contentProfile.add(
                    bytes: measuredBytes,
                    to: StorageMapContentCategory.classify(
                        name: itemURL.lastPathComponent,
                        kind: itemURL.pathExtension.lowercased().nonEmpty ?? "file",
                        isDirectory: false
                    )
                )
            }
        }

        return StorageMapTreeMeasurement(
            sizeBytes: sizeBytes,
            childCount: childCount,
            inspectedItemCount: inspectedItemCount,
            isComplete: !reachedLimit && !readHadErrors && !omittedForPolicy,
            contentProfile: contentProfile
        )
    }

    func scan() throws -> ScanResult {
        let started = Date()
        let deadline = started.addingTimeInterval(scanMode.maxScanSeconds)
        let system = systemSnapshot()

        var groups = [StorageGroup]()
        for target in scanTargets {
            guard Date() < deadline else { break }
            reportProgress(currentGroupTitle: target.title, groups: groups)
            let entries = isExcluded(target.path)
                ? []
                : target.key == "applications"
                ? scanApplications(at: target.path, minimumBytes: target.minimumBytes, limit: target.limit, deadline: deadline)
                : scanChildren(at: target.path, minimumBytes: target.minimumBytes, limit: target.limit, deadline: deadline)
            groups.append(StorageGroup(id: target.key, title: target.title, entries: entries))
            reportProgress(currentGroupTitle: target.title, groups: groups)
        }

        appendSupplementaryGroupIfModeAllows(
            &groups,
            id: "browser_caches",
            title: L10n.text("浏览器缓存", "Browser Cache"),
            deadline: deadline
        ) {
            scanKnownPaths(browserCachePaths, minimumBytes: 20 * 1024 * 1024, limit: modeAdjustedLimit(40), deadline: deadline)
        }

        appendSupplementaryGroupIfModeAllows(
            &groups,
            id: "privacy_traces",
            title: L10n.text("隐私痕迹", "Privacy Traces"),
            deadline: deadline
        ) {
            scanKnownPaths(privacyTracePaths, minimumBytes: 256 * 1024, limit: modeAdjustedLimit(60), deadline: deadline)
        }

        appendSupplementaryGroupIfModeAllows(
            &groups,
            id: "mail_attachments",
            title: L10n.text("邮件附件", "Mail Attachments"),
            deadline: deadline
        ) {
            scanKnownPaths(mailAttachmentPaths, minimumBytes: 10 * 1024 * 1024, limit: modeAdjustedLimit(20), deadline: deadline)
        }

        let scansCodexArtifacts = [
            "codex_intermediates",
            "codex_runtime_records",
            "codex_installers"
        ].contains { scanMode.includesSupplementaryGroup($0) }
        if scansCodexArtifacts, Date() < deadline {
            reportProgress(
                currentGroupTitle: L10n.text("开发工具文件", "Developer Tool Files"),
                groups: groups
            )
        }
        let codexArtifactScan = scansCodexArtifacts && Date() < deadline
            ? CodexArtifactScanner(
                configuration: .live(excludedPaths: excludedPaths)
            ).scan(deadline: deadline)
            : .empty

        appendSupplementaryGroupIfModeAllows(
            &groups,
            id: "codex_intermediates",
            title: L10n.text("Codex 临时文件", "Codex Temporary Files"),
            deadline: deadline
        ) {
            codexArtifactScan.intermediateEntries
        }

        appendSupplementaryGroupIfModeAllows(
            &groups,
            id: "codex_runtime_records",
            title: L10n.text(
                "开发工具截图、日志与运行记录",
                "Developer Tool Screenshots, Logs & Runtime Records"
            ),
            deadline: deadline
        ) {
            deduplicatedEntries(
                codexArtifactScan.runtimeRecordEntries
                    + scanKnownDeveloperArtifactPaths(Self.knownAgentLogPaths, deadline: deadline),
                limit: modeAdjustedLimit(180)
            )
        }

        appendSupplementaryGroupIfModeAllows(
            &groups,
            id: "codex_installers",
            title: L10n.text("Codex 安装包与构建产物", "Codex Installers & Build Output"),
            deadline: deadline
        ) {
            codexArtifactScan.installerEntries
        }

        appendSupplementaryGroupIfModeAllows(
            &groups,
            id: "large_files",
            title: L10n.text("大型文件", "Large Files"),
            deadline: deadline
        ) {
            scanLargeFiles(deadline: deadline)
        }

        appendSupplementaryGroupIfModeAllows(
            &groups,
            id: "duplicate_files",
            title: L10n.text("疑似重复文件", "Possible Duplicates"),
            deadline: deadline
        ) {
            scanDuplicateFiles(deadline: deadline)
        }

        appendSupplementaryGroupIfModeAllows(
            &groups,
            id: "dev_caches",
            title: L10n.text("开发缓存", "Developer Cache"),
            deadline: deadline
        ) {
            scanDevCaches(deadline: deadline)
        }

        ensureExpectedGroupsExist(&groups)
        reportProgress(
            currentGroupTitle: L10n.text("整理扫描结果", "Organizing scan results"),
            groups: groups
        )

        let denied = groups.flatMap { group in
            group.entries.filter(\.denied).map(\.path)
        }

        let scanWasLimited = Date() >= deadline || codexArtifactScan.wasLimited
        let items = StorageClassifier.classify(groups: groups)
        let finishedAt = Date()

        return ScanResult(
            generatedAt: finishedAt,
            scanSeconds: finishedAt.timeIntervalSince(started),
            scanMode: scanMode,
            scanWasLimited: scanWasLimited,
            system: system,
            groups: groups,
            items: items,
            deniedPaths: denied
        )
    }

    private func appendSupplementaryGroupIfModeAllows(
        _ groups: inout [StorageGroup],
        id: String,
        title: String,
        deadline: Date,
        entries: () -> [DirectoryEntry]
    ) {
        guard scanMode.includesSupplementaryGroup(id) else { return }

        reportProgress(currentGroupTitle: title, groups: groups)
        groups.append(
            StorageGroup(
                id: id,
                title: title,
                entries: Date() < deadline ? entries() : []
            )
        )
        reportProgress(currentGroupTitle: title, groups: groups)
    }

    private func reportProgress(
        currentGroupTitle: String,
        groups: [StorageGroup]
    ) {
        guard let progressHandler else { return }
        progressHandler(
            DiskScanProgress(
                currentGroupTitle: currentGroupTitle,
                completedGroupCount: groups.count,
                totalGroupCount: Self.plannedPrimaryGroupIDs(for: scanMode).count
                    + Self.plannedSupplementaryGroupIDs(for: scanMode).count,
                groups: groups
            )
        )
    }

    private func ensureExpectedGroupsExist(_ groups: inout [StorageGroup]) {
        let expectedGroups = allScanTargets.map { ($0.key, $0.title) } + [
            ("browser_caches", L10n.text("浏览器缓存", "Browser Cache")),
            ("privacy_traces", L10n.text("隐私痕迹", "Privacy Traces")),
            ("mail_attachments", L10n.text("邮件附件", "Mail Attachments")),
            ("codex_intermediates", L10n.text("Codex 临时文件", "Codex Temporary Files")),
            (
                "codex_runtime_records",
                L10n.text(
                    "开发工具截图、日志与运行记录",
                    "Developer Tool Screenshots, Logs & Runtime Records"
                )
            ),
            ("codex_installers", L10n.text("Codex 安装包与构建产物", "Codex Installers & Build Output")),
            ("large_files", L10n.text("大型文件", "Large Files")),
            ("duplicate_files", L10n.text("疑似重复文件", "Possible Duplicates")),
            ("dev_caches", L10n.text("开发缓存", "Developer Cache"))
        ]

        let existingIDs = Set(groups.map(\.id))
        for group in expectedGroups where !existingIDs.contains(group.0) {
            groups.append(StorageGroup(id: group.0, title: group.1, entries: []))
        }
    }

    private var scanTargets: [ScanTarget] {
        allScanTargets.filter { scanMode.includesPrimaryGroup($0.key) }
    }

    private var allScanTargets: [ScanTarget] {
        [
            ScanTarget(key: "caches", title: L10n.text("应用缓存", "App Cache"), path: "\(home)/Library/Caches", minimumBytes: 50 * 1024 * 1024, limit: 60),
            ScanTarget(key: "logs", title: L10n.text("日志文件", "Logs"), path: "\(home)/Library/Logs", minimumBytes: 20 * 1024 * 1024, limit: 40),
            ScanTarget(key: "downloads", title: L10n.text("下载项目", "Downloads"), path: "\(home)/Downloads", minimumBytes: 100 * 1024 * 1024, limit: 60),
            ScanTarget(key: "trash_bins", title: L10n.text("废纸篓", "Trash Bins"), path: "\(home)/.Trash", minimumBytes: 10 * 1024 * 1024, limit: 80),
            ScanTarget(key: "applications", title: L10n.text("应用程序", "Applications"), path: "/Applications", minimumBytes: 100 * 1024 * 1024, limit: 60),
            ScanTarget(key: "app_support", title: L10n.text("应用支持数据", "Application Support"), path: "\(home)/Library/Application Support", minimumBytes: 250 * 1024 * 1024, limit: 80),
            ScanTarget(key: "containers", title: L10n.text("应用容器", "App Containers"), path: "\(home)/Library/Containers", minimumBytes: 250 * 1024 * 1024, limit: 80),
            ScanTarget(key: "group_containers", title: L10n.text("群组容器", "Group Containers"), path: "\(home)/Library/Group Containers", minimumBytes: 250 * 1024 * 1024, limit: 80)
        ]
    }

    private var browserCachePaths: [(name: String, path: String)] {
        [
            (L10n.text("Safari 缓存", "Safari Cache"), "~/Library/Caches/com.apple.Safari"),
            (L10n.text("Chrome 缓存", "Chrome Cache"), "~/Library/Caches/Google/Chrome"),
            (L10n.text("Chrome 用户缓存", "Chrome User Cache"), "~/Library/Application Support/Google/Chrome/Default/Cache"),
            (L10n.text("Edge 缓存", "Edge Cache"), "~/Library/Caches/Microsoft Edge"),
            (L10n.text("Edge 用户缓存", "Edge User Cache"), "~/Library/Application Support/Microsoft Edge/Default/Cache"),
            (L10n.text("Firefox 缓存", "Firefox Cache"), "~/Library/Caches/Firefox"),
            (L10n.text("Firefox Profiles 缓存", "Firefox Profiles Cache"), "~/Library/Caches/Mozilla/Firefox")
        ]
    }

    private var privacyTracePaths: [(name: String, path: String)] {
        [
            (L10n.text("Safari 浏览历史", "Safari History"), "~/Library/Safari/History.db"),
            (L10n.text("Safari 下载记录", "Safari Downloads"), "~/Library/Safari/Downloads.plist"),
            (L10n.text("Chrome 浏览历史", "Chrome History"), "~/Library/Application Support/Google/Chrome/Default/History"),
            (L10n.text("Chrome Cookie 数据", "Chrome Cookies"), "~/Library/Application Support/Google/Chrome/Default/Network/Cookies"),
            (L10n.text("Edge 浏览历史", "Edge History"), "~/Library/Application Support/Microsoft Edge/Default/History"),
            (L10n.text("Edge Cookie 数据", "Edge Cookies"), "~/Library/Application Support/Microsoft Edge/Default/Network/Cookies"),
            (L10n.text("Firefox 配置资料", "Firefox Profiles"), "~/Library/Application Support/Firefox/Profiles")
        ]
    }

    private var mailAttachmentPaths: [(name: String, path: String)] {
        [
            (L10n.text("邮件下载附件", "Mail Downloads"), "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
            (L10n.text("旧版邮件下载附件", "Legacy Mail Downloads"), "~/Library/Mail Downloads")
        ]
    }

    static var knownRegenerableAgentPaths: [KnownDeveloperArtifactPath] {
        knownAgentPaths(policy: .regenerable)
    }

    static var knownAgentLogPaths: [KnownDeveloperArtifactPath] {
        knownAgentPaths(policy: .reviewOnly) + [
            KnownDeveloperArtifactPath(
                name: L10n.text("OpenClaw 系统临时日志", "OpenClaw System Temporary Logs"),
                path: "/tmp/openclaw",
                minimumBytes: 256 * 1024
            )
        ]
    }

    private static func knownAgentPaths(
        policy: DeveloperArtifactCleanupPolicy
    ) -> [KnownDeveloperArtifactPath] {
        DeveloperToolArtifactCatalog.definitions
            .filter { $0.policy == policy }
            .flatMap { definition in
                definition.candidateNames.map { candidateName in
                    KnownDeveloperArtifactPath(
                        name: "\(definition.tool.displayName) \(definition.kind.displayName)",
                        path: "~/\(definition.rootPath)/\(candidateName)",
                        minimumBytes: definition.minimumBytes
                    )
                }
            }
    }

    private func scanDevCaches(deadline: Date) -> [DirectoryEntry] {
        let paths = [
            KnownDeveloperArtifactPath(name: L10n.text("pip 缓存", "pip Cache"), path: "~/Library/Caches/pip", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("uv 缓存", "uv Cache"), path: "~/Library/Caches/uv", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("通用开发缓存", "General Developer Cache"), path: "~/.cache", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("Cargo 缓存", "Cargo Cache"), path: "~/.cargo", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("npm 缓存", "npm Cache"), path: "~/.npm", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("pnpm Store", "pnpm Store"), path: "~/.pnpm-store", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("Gradle 缓存", "Gradle Cache"), path: "~/.gradle", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("Maven 缓存", "Maven Cache"), path: "~/.m2", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("Xcode DerivedData", "Xcode DerivedData"), path: "~/Library/Developer/Xcode/DerivedData", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("模拟器数据", "Simulator Data"), path: "~/Library/Developer/CoreSimulator", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("iOS 设备支持", "iOS Device Support"), path: "~/Library/Developer/Xcode/iOS DeviceSupport", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("pnpm 缓存", "pnpm Cache"), path: "~/Library/pnpm", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("Go 构建缓存", "Go Build Cache"), path: "~/go/pkg", minimumBytes: 50 * 1024 * 1024),
            KnownDeveloperArtifactPath(name: L10n.text("Docker 缓存", "Docker Cache"), path: "~/.docker", minimumBytes: 50 * 1024 * 1024)
        ] + Self.knownRegenerableAgentPaths

        let knownEntries = scanKnownDeveloperArtifactPaths(paths, deadline: deadline)

        return deduplicatedDevCacheEntries(
            knownEntries + scanDevelopmentIntermediates(deadline: deadline)
        )
    }

    private func scanDevelopmentIntermediates(deadline: Date) -> [DirectoryEntry] {
        var entries = [DirectoryEntry]()
        var pending = developmentIntermediateRoots.compactMap { rawPath -> (url: URL, depth: Int)? in
            let path = expandHome(rawPath)
            guard fileManager.fileExists(atPath: path), !isExcluded(path) else { return nil }
            return (URL(fileURLWithPath: path, isDirectory: true), 0)
        }

        var visited = 0
        while !pending.isEmpty, Date() < deadline, visited < 420 {
            let current = pending.removeFirst()
            visited += 1

            if isDevelopmentIntermediateDirectory(current.url) {
                if let entry = developmentIntermediateEntry(for: current.url) {
                    entries.append(entry)
                }
                continue
            }

            if shouldSkipDevelopmentIntermediateTraversal(current.url) || current.depth >= 4 {
                continue
            }

            guard let children = try? directoryContents(
                at: current.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants],
                timeout: 0.35
            ) else {
                continue
            }

            for child in children where Date() < deadline {
                guard !isExcluded(child.path) else { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

                if child.lastPathComponent == "node_modules" {
                    let cacheURL = child.appendingPathComponent(".cache", isDirectory: true)
                    if let entry = developmentIntermediateEntry(for: cacheURL) {
                        entries.append(entry)
                    }
                    continue
                }

                pending.append((child, current.depth + 1))
            }
        }

        return entries
    }

    private var developmentIntermediateRoots: [String] {
        [
            "~/Developer",
            "~/Projects",
            "~/Code",
            "~/Workspace",
            "~/Documents/好玩的",
            "~/Documents/工作",
            "~/Documents/New project"
        ]
    }

    private func isDevelopmentIntermediateDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let parentName = url.deletingLastPathComponent().lastPathComponent
        let directNames: Set<String> = [
            ".build",
            ".swiftpm",
            ".codebase-memory",
            ".pytest_cache",
            ".mypy_cache",
            ".ruff_cache",
            ".parcel-cache",
            ".turbo",
            ".gradle",
            ".dart_tool",
            "DerivedData"
        ]

        return directNames.contains(name) || (name == "cache" && [".next", "node_modules"].contains(parentName))
    }

    private func developmentIntermediateEntry(for url: URL) -> DirectoryEntry? {
        guard fileManager.fileExists(atPath: url.path), let bytes = treeSizeBytes(url.path), bytes >= 20 * 1024 * 1024 else {
            return nil
        }

        let parentName = url.deletingLastPathComponent().lastPathComponent
        let name = parentName.isEmpty
            ? url.lastPathComponent
            : "\(parentName)/\(url.lastPathComponent)"

        return DirectoryEntry(
            name: name,
            path: url.path,
            sizeBytes: bytes,
            isDirectory: true
        )
    }

    private func shouldSkipDevelopmentIntermediateTraversal(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let skippedNames = [
            ".git",
            ".hg",
            ".svn",
            ".Trash",
            "Applications",
            "Library",
            "Movies",
            "Music",
            "Pictures",
            "Pods",
            "Carthage",
            "vendor",
            "release",
            "dist"
        ]

        return skippedNames.contains(name) || name.hasSuffix(".app")
    }

    private func deduplicatedDevCacheEntries(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
        deduplicatedEntries(entries, limit: modeAdjustedLimit(90))
    }

    private func deduplicatedEntries(_ entries: [DirectoryEntry], limit: Int) -> [DirectoryEntry] {
        var seen = Set<String>()
        var deduplicated = [DirectoryEntry]()

        for entry in entries.sorted(by: { $0.sizeBytes > $1.sizeBytes }) {
            let normalized = PathSafety.normalizedPath(entry.path)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            deduplicated.append(entry)
        }

        return Array(deduplicated.prefix(limit))
    }

    private func scanKnownDeveloperArtifactPaths(
        _ paths: [KnownDeveloperArtifactPath],
        deadline: Date
    ) -> [DirectoryEntry] {
        paths.compactMap { entry -> DirectoryEntry? in
            guard Date() < deadline else { return nil }
            let path = expandHome(entry.path)
            guard !ScanExclusionService.intersectsExcludedTree(
                path,
                excludedPaths: excludedPaths
            ) else {
                return nil
            }

            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let bytes = sizeBytes(path),
                  bytes >= entry.minimumBytes else {
                return nil
            }

            return DirectoryEntry(
                name: entry.name,
                path: path,
                sizeBytes: bytes,
                isDirectory: true
            )
        }
    }

    private func scanKnownPaths(
        _ paths: [(name: String, path: String)],
        minimumBytes: Int64,
        limit: Int,
        deadline: Date
    ) -> [DirectoryEntry] {
        let entries = paths.compactMap { entry -> DirectoryEntry? in
            guard Date() < deadline else { return nil }
            let path = expandHome(entry.path)
            guard !isExcluded(path) else { return nil }
            guard fileManager.fileExists(atPath: path), let bytes = sizeBytes(path), bytes >= minimumBytes else {
                return nil
            }

            return DirectoryEntry(
                name: entry.name,
                path: path,
                sizeBytes: bytes
            )
        }

        return Array(entries.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit))
    }

    private func scanLargeFiles(deadline: Date) -> [DirectoryEntry] {
        var entries = [DirectoryEntry]()
        for root in largeFileRoots {
            guard Date() < deadline else { break }
            guard !isExcluded(root) else { continue }
            entries.append(
                contentsOf: scanChildren(
                    at: root,
                    minimumBytes: scanMode.largeFileMinimumBytes,
                    limit: modeAdjustedLimit(40),
                    deadline: deadline
                )
            )
        }

        return Array(entries.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(scanMode.largeFileResultLimit))
    }

    private var largeFileRoots: [String] {
        largeFileRootOverrides ?? Self.plannedLargeFileRoots(for: scanMode, homePath: home)
    }

    private func modeAdjustedLimit(_ limit: Int) -> Int {
        max(1, Int((Double(limit) * scanMode.knownPathLimitMultiplier).rounded(.up)))
    }

    private func scanDuplicateFiles(deadline: Date) -> [DirectoryEntry] {
        // Duplicate enumeration can trigger slow File Provider reads. Keep the
        // main scan responsive; run duplicate search as a dedicated flow.
        []
    }

    private func scanChildren(at path: String, minimumBytes: Int64, limit: Int, deadline: Date) -> [DirectoryEntry] {
        guard Date() < deadline else { return [] }
        guard fileManager.fileExists(atPath: path), !isExcluded(path) else { return [] }

        do {
            let urls = try directoryContents(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants],
                timeout: directoryReadTimeout
            )

            var entries = [DirectoryEntry]()
            var measuredCount = 0
            for url in urls {
                guard Date() < deadline else { break }
                if shouldSkipChild(url, parentPath: path) || isExcluded(url.path) {
                    continue
                }

                if measuredCount >= scanMode.maxChildrenPerDirectory {
                    break
                }

                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    continue
                }

                measuredCount += 1
                guard let bytes = treeSizeBytes(url.path), bytes >= minimumBytes else {
                    continue
                }

                entries.append(
                    DirectoryEntry(
                        name: url.lastPathComponent,
                        path: url.path,
                        sizeBytes: bytes,
                        isDirectory: values?.isDirectory == true
                    )
                )
            }

            return Array(entries.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit))
        } catch DirectoryReadError.timedOut {
            return []
        } catch {
            return [
                DirectoryEntry(
                    name: L10n.text("(permission denied)", "(permission denied)"),
                    path: path,
                    sizeBytes: 0,
                    denied: true
                )
            ]
        }
    }

    private func scanApplications(at path: String, minimumBytes: Int64, limit: Int, deadline: Date) -> [DirectoryEntry] {
        guard Date() < deadline else { return [] }
        guard fileManager.fileExists(atPath: path), !isExcluded(path) else { return [] }

        do {
            let urls = try directoryContents(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                timeout: directoryReadTimeout
            )

            var entries = [DirectoryEntry]()
            var measuredCount = 0
            for url in urls where url.pathExtension == "app" {
                guard Date() < deadline else { break }
                if isExcluded(url.path) {
                    continue
                }

                if measuredCount >= scanMode.maxChildrenPerDirectory {
                    break
                }

                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    continue
                }

                measuredCount += 1
                guard let bytes = treeSizeBytes(url.path), bytes >= minimumBytes else {
                    continue
                }

                entries.append(
                    DirectoryEntry(
                        name: url.lastPathComponent,
                        path: url.path,
                        sizeBytes: bytes,
                        isDirectory: values?.isDirectory == true
                    )
                )
            }

            return Array(entries.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit))
        } catch DirectoryReadError.timedOut {
            return []
        } catch {
            return [
                DirectoryEntry(
                    name: L10n.text("(permission denied)", "(permission denied)"),
                    path: path,
                    sizeBytes: 0,
                    denied: true
                )
            ]
        }
    }

    private func shouldSkipChild(_ url: URL, parentPath: String) -> Bool {
        let parent = PathSafety.normalizedPath(parentPath)
        let name = url.lastPathComponent
        let lowercasedName = name.lowercased()

        if parent == PathSafety.normalizedPath(home) {
            let skippedHomeChildren = [
                "Library",
                "Music",
                "Pictures",
                "Movies"
            ]
            return skippedHomeChildren.contains(name)
        }

        if parent == PathSafety.normalizedPath("\(home)/Library/CloudStorage") {
            return true
        }

        if parent == PathSafety.normalizedPath("\(home)/Library/Containers") {
            return lowercasedName.hasPrefix("com.apple.")
        }

        if parent == PathSafety.normalizedPath("\(home)/Library/Caches") {
            return lowercasedName.hasPrefix("com.apple.")
        }

        if parent == PathSafety.normalizedPath("\(home)/Library/Group Containers") {
            return lowercasedName.hasPrefix("group.com.apple.")
        }

        if parent == PathSafety.normalizedPath("\(home)/Library/Application Support") {
            if ["music", "itunescloud", "ilifemediabrowser"].contains(lowercasedName) {
                return true
            }
            if lowercasedName.contains("icloud")
                || lowercasedName.contains("onedrive")
                || lowercasedName.contains("cloudstorage") {
                return true
            }
            return lowercasedName.hasPrefix("com.apple.")
        }

        return false
    }

    private func directoryContents(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        options: FileManager.DirectoryEnumerationOptions,
        timeout: TimeInterval
    ) throws -> [URL] {
        let box = DirectoryReadBox()
        let path = url.path
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: keys,
                    options: options
                )
                box.set(.success(urls))
            } catch {
                box.set(.failure(error))
            }
            finished.signal()
        }

        guard finished.wait(timeout: .now() + timeout) == .success,
              let result = box.get() else {
            throw DirectoryReadError.timedOut
        }

        return try result.get()
    }

    private func isExcluded(_ path: String) -> Bool {
        ScanExclusionService.isExcluded(path, excludedPaths: excludedPaths)
    }

    /// Sizes a tree natively instead of spawning `/usr/bin/du` per item. The
    /// walk runs on a worker with the same hang protection as directory reads,
    /// publishes its running total, and returns the partial sum as a lower
    /// bound when a very large tree exceeds the measuring budget — the old
    /// `du` timeout dropped exactly the largest items from the results.
    private func treeSizeBytes(_ path: String) -> Int64? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else {
            return allocatedFileSizeBytes(URL(fileURLWithPath: path))
        }

        let box = TreeSizeBox()
        let finished = DispatchSemaphore(value: 0)
        let budget = directorySizeTimeout
        let rootPath = path

        DispatchQueue.global(qos: .utility).async {
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
            ]
            let deadline = Date().addingTimeInterval(budget)
            var total: Int64 = 0
            var itemCount = 0
            if let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: rootPath),
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in true }
            ) {
                for case let itemURL as URL in enumerator {
                    itemCount += 1
                    if itemCount % 512 == 0 {
                        box.update(total)
                        if Date() >= deadline { break }
                    }
                    guard let values = try? itemURL.resourceValues(forKeys: keys),
                          values.isRegularFile == true else { continue }
                    total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                }
            }
            box.update(total)
            finished.signal()
        }

        _ = finished.wait(timeout: .now() + budget + 0.3)
        return box.currentBytes
    }

    private func allocatedFileSizeBytes(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
        ])
        guard let bytes = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize else {
            return nil
        }
        return Int64(bytes)
    }

    private func sizeBytes(_ path: String) -> Int64? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return treeSizeBytes(path)
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }


    private func systemSnapshot() -> SystemSnapshot {
        let attributes = (try? fileManager.attributesOfFileSystem(forPath: "/")) ?? [:]
        let total = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let used = max(0, total - free)

        let osName = "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
        let build = (try? Shell.capture("/usr/bin/sw_vers", ["-buildVersion"], timeout: 1).trimmed) ?? ""
        let machine = (try? Shell.capture("/usr/bin/uname", ["-m"], timeout: 1).trimmed) ?? ""
        let cpu = (try? Shell.capture("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"], timeout: 1).trimmed) ?? ""
        let arch = cpu.isEmpty ? machine : "\(machine) / \(cpu)"
        let diskInfo = (try? Shell.capture("/usr/sbin/diskutil", ["info", "/"], timeout: 2)) ?? ""

        return SystemSnapshot(
            osName: osName,
            build: build,
            arch: arch,
            user: NSUserName(),
            home: home,
            filesystem: value(after: "File System Personality:", in: diskInfo) ?? "APFS",
            purgeable: value(after: "Purgeable Space:", in: diskInfo) ?? "",
            diskName: "Macintosh HD",
            diskTotalBytes: total,
            diskUsedBytes: used,
            diskFreeBytes: free
        )
    }

    private func value(after prefix: String, in text: String) -> String? {
        text.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
            .map { line in
                String(line)
                    .replacingOccurrences(of: prefix, with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    private func expandHome(_ path: String) -> String {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst())
        }
        return path
    }
}

enum StorageClassifier {
    private struct Candidate {
        let entry: DirectoryEntry
        let group: StorageGroup
        let priority: Int
    }

    static func classify(groups: [StorageGroup]) -> [StorageItem] {
        let candidates = groups.flatMap { group in
            group.entries.map {
                Candidate(entry: $0, group: group, priority: priority(for: group.id))
            }
        }
        .sorted {
            if $0.priority == $1.priority {
                return $0.entry.sizeBytes > $1.entry.sizeBytes
            }
            return $0.priority > $1.priority
        }

        var seenPaths = Set<String>()
        var classifiedPaths = [String]()
        var items = [StorageItem]()

        for candidate in candidates {
            let entry = candidate.entry
            guard !entry.denied else { continue }

            let normalized = PathSafety.normalizedPath(entry.path)
            guard !seenPaths.contains(normalized),
                  !isBroadDuplicate(entry: entry, groupID: candidate.group.id) else {
                continue
            }

            let item = item(from: entry, group: candidate.group)
            guard !item.canMoveToTrash
                || !classifiedPaths.contains(where: { storagePathsOverlap($0, normalized) }) else {
                continue
            }

            seenPaths.insert(normalized)
            classifiedPaths.append(normalized)
            items.append(item)
        }

        return items.sorted {
            if $0.tier.sortRank == $1.tier.sortRank {
                return $0.sizeBytes > $1.sizeBytes
            }
            return $0.tier.sortRank < $1.tier.sortRank
        }
    }

    private static func priority(for groupID: String) -> Int {
        switch groupID {
        case "codex_intermediates": 98
        case "codex_runtime_records", "codex_installers": 97
        case "browser_caches": 95
        case "dev_caches": 90
        case "logs": 86
        case "downloads", "trash_bins": 80
        case "mail_attachments", "large_files", "duplicate_files", "privacy_traces": 75
        case "caches": 70
        case "containers", "group_containers", "app_support": 70
        case "applications": 60
        case "library": 40
        case "home": 20
        default: 10
        }
    }

    private static func isBroadDuplicate(entry: DirectoryEntry, groupID: String) -> Bool {
        if groupID == "home", entry.name == "Library" {
            return true
        }

        if groupID == "library" {
            let covered = ["Application Support", "Caches", "Containers", "Group Containers", "Developer"]
            return covered.contains(entry.name)
        }

        return false
    }

    private static func item(from entry: DirectoryEntry, group: StorageGroup) -> StorageItem {
        let decision = decision(for: entry, groupID: group.id)
        let title = displayTitle(for: entry)

        return StorageItem(
            id: PathSafety.normalizedPath(entry.path),
            title: title,
            path: entry.path,
            sourceID: group.id,
            groupTitle: group.title,
            sizeBytes: entry.sizeBytes,
            tier: decision.tier,
            kind: decision.kind,
            reason: decision.reason,
            recommendation: decision.recommendation,
            risk: decision.risk,
            requiresClose: decision.requiresClose,
            trashPaths: decision.trashPaths ? [entry.path] : [],
            openPath: entry.path,
            isDirectory: entry.isDirectory,
            status: .available
        )
    }

    private static func decision(
        for entry: DirectoryEntry,
        groupID: String
    ) -> (tier: StorageTier, kind: String, reason: String, recommendation: String, risk: String, requiresClose: String, trashPaths: Bool) {
        switch groupID {
        case "browser_caches":
            return (
                .green,
                L10n.text("浏览器缓存", "Browser Cache"),
                L10n.text("浏览器缓存可重新生成，通常不包含长期文档。", "Browser cache can be regenerated and usually does not contain long-term documents."),
                L10n.text("关闭对应浏览器后移到废纸篓；下次打开页面时会重新缓存。", "Close the related browser, then move it to Trash. Pages will cache again as needed."),
                L10n.text("部分网页首次加载会变慢，少数站点可能需要重新载入。", "Some webpages may load slower the first time, and a few sites may need to reload."),
                L10n.text("Safari、Chrome、Edge、Firefox", "Safari, Chrome, Edge, Firefox"),
                true
            )
        case "logs":
            return (
                .yellow,
                L10n.text("日志文件", "Logs"),
                L10n.text("应用写入的历史日志通常只用于排查问题。", "Historical app logs are usually only needed for troubleshooting."),
                L10n.text("确认没有正在排查的应用问题后移到废纸篓。", "Move them to Trash after confirming you are not troubleshooting that app."),
                L10n.text("删除后旧日志不可用于回溯问题。", "Old logs will no longer be available for troubleshooting."),
                L10n.text("对应应用", "Related app"),
                false
            )
        case "privacy_traces":
            return (
                .yellow,
                L10n.text("隐私痕迹", "Privacy Trace"),
                L10n.text("浏览历史、下载记录、Cookie 或浏览器配置可能包含登录状态和偏好。", "History, downloads, cookies, or browser profiles can include sign-in state and preferences."),
                L10n.text("在对应浏览器内检查并清除；这里仅定位来源，不提供直接删除。", "Review and clear inside the related browser. This app only locates the source and does not delete it directly."),
                L10n.text("直接删除可能导致网站退出登录或浏览器配置损坏。", "Deleting directly may sign you out of websites or damage browser profiles."),
                L10n.text("对应浏览器", "Related browser"),
                false
            )
        case "mail_attachments":
            return (
                .yellow,
                L10n.text("邮件附件", "Mail Attachments"),
                L10n.text("邮件下载附件可能仍需要保留，且可能和邮件记录关联。", "Mail downloads may still be needed and can be tied to mail records."),
                L10n.text("在访达或邮件应用里人工检查后再处理。", "Review in Finder or Mail before removing anything."),
                L10n.text("可能包含合同、收据或唯一副本。", "It may contain contracts, receipts, or the only copy of a file."),
                L10n.text("邮件", "Mail"),
                false
            )
        case "large_files":
            if isInstallerOrArchive(entry.path) {
                return (
                    .yellow,
                    L10n.text("大型安装包", "Large Installer"),
                    L10n.text("大型安装包或压缩包通常是下载后留下的文件。", "Large installers or archives are often leftovers after download or installation."),
                    L10n.text("确认不再需要重新安装或解压后移到废纸篓。", "Move it to Trash after confirming you no longer need to reinstall or extract it."),
                    L10n.text("如果这是唯一备份，删除前应另存。", "If this is your only copy, keep another copy first."),
                    L10n.text("无", "None"),
                    false
                )
            }
            return (
                .yellow,
                L10n.text("大型文件", "Large File"),
                L10n.text("桌面、文稿、下载中的大型文件需要按内容确认。", "Large files in Desktop, Documents, and Downloads need content review."),
                L10n.text("在访达打开后按项目、日期或文件类型整理。", "Open in Finder and organize by project, date, or file type."),
                L10n.text("可能是项目素材、导出文件或唯一副本。", "It may be project media, exports, or the only copy."),
                L10n.text("无", "None"),
                false
            )
        case "duplicate_files":
            return (
                .yellow,
                L10n.text("疑似重复文件", "Possible Duplicate"),
                L10n.text("文件名和大小都相同，可能是重复下载、导出或拷贝。", "The file name and size match another item, so it may be a repeated download, export, or copy."),
                L10n.text("在访达中逐个打开确认内容；本工具不会自动删除重复文件。", "Open each item in Finder and confirm the content. This app does not delete duplicate files automatically."),
                L10n.text("相同名称和大小不一定代表内容完全相同，直接删除可能丢失唯一版本。", "Same name and size does not always guarantee identical content, and direct deletion may lose the only useful version."),
                L10n.text("无", "None"),
                false
            )
        case "trash_bins":
            return (
                .yellow,
                L10n.text("废纸篓内容", "Trash Bin Content"),
                L10n.text("废纸篓里的项目会继续占用磁盘空间，但清空后通常不可恢复。", "Items in Trash still use disk space, but emptying Trash is usually not reversible."),
                L10n.text("打开废纸篓确认内容后，可在本软件二次确认清空，或继续使用访达处理。", "Open Trash to review contents, then confirm emptying in this app or continue in Finder."),
                L10n.text("清空废纸篓是永久删除，不能作为缓存清理批量处理。", "Emptying Trash is permanent and is not treated as batch cache cleanup."),
                L10n.text("无", "None"),
                false
            )
        case "codex_intermediates":
            return (
                .green,
                L10n.text("Codex 运行中间文件", "Codex Runtime Intermediates"),
                L10n.text("这是 Codex 在插件同步、工具执行或构建期间生成的临时区，不包含会话、记忆或配置目录。", "This is a temporary area created while Codex syncs plugins, runs tools, or builds. It does not include sessions, memories, or configuration directories."),
                L10n.text("完全退出 Codex 并结束相关终端任务后移到废纸篓；下次需要时会重新生成。", "Quit Codex completely and stop related terminal jobs before moving it to Trash. It will be regenerated when needed."),
                L10n.text("下次启动可能需要重新同步插件或准备工具，首次运行会稍慢。", "The next launch may need to resync plugins or prepare tools, so the first run can be slower."),
                L10n.text("Codex、相关终端任务", "Codex and related terminal jobs"),
                true
            )
        case "codex_runtime_records":
            return (
                .yellow,
                L10n.text("开发工具截图、日志与运行记录", "Developer Tool Screenshots, Logs & Runtime Records"),
                L10n.text("这里包含 Codex、Claude Code、Cursor、Gemini CLI、OpenCode、WorkBuddy、Windsurf、Continue、Cline、Roo Code、GitHub Copilot、OpenClaw 或浏览器自动化生成的截图、日志和运行记录，其中部分可能是仍需保留的任务结果或调试证据。", "This includes screenshots, logs, and runtime records generated by Codex, Claude Code, Cursor, Gemini CLI, OpenCode, WorkBuddy, Windsurf, Continue, Cline, Roo Code, GitHub Copilot, OpenClaw, or browser automation. Some may still be useful task results or debugging evidence."),
                L10n.text("在访达中打开并按项目、日期确认；只删除已经交付或不再需要的记录。", "Open it in Finder and review by project and date. Remove only records that have already been delivered or are no longer needed."),
                L10n.text("日志可能包含调试上下文；自动删除还可能丢失唯一截图或任务证据。", "Logs may contain debugging context, and automatic removal could also lose the only screenshot or task evidence."),
                L10n.text("无；如文件仍在生成，请先关闭对应的 AI 开发工具或浏览器自动化", "None; close the corresponding AI developer tool or browser automation first if files are still being generated"),
                false
            )
        case "codex_installers":
            return (
                .yellow,
                L10n.text("Codex 安装包与构建产物", "Codex Installers & Build Output"),
                L10n.text("这些 DMG、ZIP、PKG 或构建应用可能是历史中间产物，也可能是当前版本、正式发布物或唯一安装副本。", "These DMG, ZIP, PKG, or built apps may be historical intermediates, but they may also be the current release, a formal artifact, or the only installer copy."),
                L10n.text("在访达中核对版本、校验文件和发布记录后再处理；本工具不会直接删除。", "Review versions, checksums, and release records in Finder before taking action. This tool does not delete them directly."),
                L10n.text("仅按文件名或所在目录判断可能误删当前发布包。", "Judging only by file name or folder could remove the current release package."),
                L10n.text("构建、打包、Sparkle 更新验证任务", "Build, packaging, and Sparkle update-verification jobs"),
                false
            )
        case "dev_caches":
            return (
                .green,
                L10n.text("开发缓存", "Developer Cache"),
                L10n.text("Codex、Claude Code、Cursor、Gemini CLI、OpenCode、WorkBuddy、Windsurf、Continue、Cline、Roo Code、GitHub Copilot、OpenClaw、构建工具、包管理器或模拟器产生的明确缓存与临时文件，可重新生成。", "Explicit caches and temporary files created by Codex, Claude Code, Cursor, Gemini CLI, OpenCode, WorkBuddy, Windsurf, Continue, Cline, Roo Code, GitHub Copilot, OpenClaw, build tools, package managers, or simulators can be regenerated."),
                L10n.text("关闭对应的 AI 开发工具、Xcode、模拟器和相关终端任务后移到废纸篓；下次运行会重新生成需要的内容。", "Close the corresponding AI developer tool, Xcode, Simulator, and related terminal jobs, then move it to Trash. The next run will recreate what it needs."),
                L10n.text("首次重新打开项目、插件或重新构建可能变慢。", "Opening projects, plugins, or rebuilding may be slower the first time."),
                L10n.text("Codex、Claude Code、Cursor、Gemini CLI、OpenCode、WorkBuddy、Windsurf、Continue、Cline、Roo Code、GitHub Copilot、OpenClaw、Xcode、模拟器、终端构建任务", "Codex, Claude Code, Cursor, Gemini CLI, OpenCode, WorkBuddy, Windsurf, Continue, Cline, Roo Code, GitHub Copilot, OpenClaw, Xcode, Simulator, terminal build tasks"),
                true
            )
        case "caches":
            return (
                .green,
                L10n.text("应用缓存", "App Cache"),
                L10n.text("应用运行产生的缓存，一般不包含长期用户资料。", "Cache created while apps run. It usually does not contain long-term user data."),
                L10n.text("关闭对应应用后移到废纸篓；应用下次启动会按需重建缓存。", "Close the related app, then move it to Trash. The app will rebuild cache as needed."),
                L10n.text("少数应用首次打开会重新登录或重新索引。", "Some apps may sign in again or rebuild indexes on first launch."),
                L10n.text("对应应用", "Related app"),
                true
            )
        case "downloads":
            if isInstallerOrArchive(entry.path) {
                return (
                    .yellow,
                    L10n.text("安装包残留", "Installer Leftover"),
                    L10n.text("下载目录里的安装包或压缩包，通常是已完成安装后的残留。", "Installers or archives in Downloads are often leftover after installation."),
                    L10n.text("确认不再需要重新安装后移到废纸篓。", "Move it to Trash after confirming you no longer need to reinstall from it."),
                    L10n.text("如果这是唯一备份，删除前应另存。", "If this is your only copy, keep another copy first."),
                    L10n.text("无", "None"),
                    false
                )
            }
            return (
                .yellow,
                L10n.text("下载内容", "Downloads"),
                L10n.text("下载目录通常混有文档、素材、安装包和临时文件。", "Downloads often mixes documents, media assets, installers, and temporary files."),
                L10n.text("在访达打开后按文件内容人工筛选；不要直接清空整个目录。", "Open in Finder and review by content. Do not clear the entire folder directly."),
                L10n.text("可能包含仍需要的收据、素材或压缩包。", "It may contain receipts, assets, or archives you still need."),
                L10n.text("无", "None"),
                false
            )
        case "containers", "group_containers":
            return (
                .yellow,
                L10n.text("应用沙盒数据", "App Sandbox Data"),
                L10n.text("沙盒容器可能包含设置、聊天记录、离线内容或数据库。", "Sandbox containers may include settings, messages, offline content, or databases."),
                L10n.text("在访达打开确认内容；优先使用应用内清理入口。", "Open in Finder to review. Prefer cleanup controls inside the app."),
                L10n.text("直接删除可能导致应用数据丢失或账号状态异常。", "Deleting directly may lose app data or break account state."),
                L10n.text("对应应用", "Related app"),
                false
            )
        case "app_support":
            return (
                .yellow,
                L10n.text("应用支持数据", "Application Support Data"),
                L10n.text("这里经常存放浏览器 Profile、聊天记录、索引库和本地数据库。", "This often stores browser profiles, chat logs, indexes, and local databases."),
                L10n.text("在访达打开确认来源；浏览器、微信、照片类数据优先走应用内管理。", "Open in Finder to confirm the source. For browsers, chat, and photo data, prefer in-app management."),
                L10n.text("直接删除可能丢用户资料、历史记录或本地工作区。", "Deleting directly may remove user data, history, or local workspaces."),
                L10n.text("对应应用", "Related app"),
                false
            )
        case "applications":
            if entry.sizeBytes >= 1_000_000_000 {
                return (
                    .red,
                    L10n.text("应用文件", "Application"),
                    L10n.text("大型应用占用明显，但不适合由清理工具直接删除。", "Large apps use noticeable space, but a cleaner should not delete them directly."),
                    L10n.text("在访达定位后，按应用自带卸载器、启动台或系统方式卸载。", "Reveal it in Finder, then uninstall using the app uninstaller, Launchpad, or system method."),
                    L10n.text("直接删 .app 可能留下插件、驱动或授权组件。", "Deleting the .app directly may leave plugins, drivers, or license components behind."),
                    L10n.text("应用本身", "The app itself"),
                    false
                )
            }
            return (
                .other,
                L10n.text("普通应用", "App"),
                L10n.text("应用文件属于正常占用。", "The app itself is normal storage usage."),
                L10n.text("只有明确不用时再通过系统方式卸载。", "Only uninstall through system methods when you are sure you no longer need it."),
                L10n.text("不建议为了释放少量空间手工删除。", "Manual deletion for a small amount of space is not recommended."),
                L10n.text("应用本身", "The app itself"),
                false
            )
        case "home":
            if ["Downloads", "Movies", "Pictures", "Documents", "Desktop"].contains(entry.name) {
                return (
                    .yellow,
                    L10n.text("用户文件", "User Files"),
                    L10n.text("用户目录里的大型文件夹需要按内容判断。", "Large folders in your home directory need content-level review."),
                    L10n.text("在访达打开后按项目、日期或文件类型整理；云端同步目录优先使用释放本地副本。", "Open in Finder and organize by project, date, or file type. For synced folders, prefer freeing local copies."),
                    L10n.text("可能包含唯一副本或云端同步文件。", "It may contain the only copy of files or cloud-synced files."),
                    L10n.text("无", "None"),
                    false
                )
            }
            return otherDecision()
        default:
            return otherDecision()
        }
    }

    private static func otherDecision() -> (tier: StorageTier, kind: String, reason: String, recommendation: String, risk: String, requiresClose: String, trashPaths: Bool) {
        (
            .other,
            L10n.text("普通占用", "General Storage"),
            L10n.text("未归入可直接清理的决策项。", "This is not classified as directly cleanable."),
            L10n.text("仅作为排行参考；需要结合内容来源再处理。", "Use this as a size reference and review the source before acting."),
            L10n.text("不建议批量删除。", "Bulk deletion is not recommended."),
            L10n.text("无", "None"),
            false
        )
    }

    private static func isInstallerOrArchive(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["dmg", "pkg", "mpkg", "zip", "rar", "7z", "tar", "gz", "xz"].contains(ext)
    }

    private static func displayTitle(for entry: DirectoryEntry) -> String {
        if entry.name.hasSuffix(".app") {
            return String(entry.name.dropLast(4))
        }
        return entry.name
    }
}
