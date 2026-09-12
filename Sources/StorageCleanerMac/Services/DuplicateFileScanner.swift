import AppleArchive
import CryptoKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import System

struct DuplicateFileScanner {
    typealias ProgressHandler = @Sendable (DuplicateFileScanProgress) -> Void
    typealias ResumeIndexHandler = @Sendable (Data?) -> Void

    /// A small test seam for the mounted-volume policy. Production callers
    /// leave this nil and the values come directly from FileManager.
    struct MountedVolumeMetadata: Hashable, Sendable {
        let url: URL
        let isLocal: Bool?
        let isBrowsable: Bool?
        let isReadOnly: Bool?
        let isInternal: Bool?
        let name: String?

        init(
            url: URL,
            isLocal: Bool?,
            isBrowsable: Bool?,
            isReadOnly: Bool?,
            isInternal: Bool?,
            name: String? = nil
        ) {
            self.url = url
            self.isLocal = isLocal
            self.isBrowsable = isBrowsable
            self.isReadOnly = isReadOnly
            self.isInternal = isInternal
            self.name = name
        }
    }

    private static let quickReadBytes = 64 * 1024
    private static let hashReadBytes = 1024 * 1024
    private static let resumeIndexVersion = 1
    private static let resumeCheckpointDirectoryCadence = 16
    private static let maximumResumeAge: TimeInterval = 24 * 60 * 60
    private static let maximumResumeDataBytes = DuplicateFileResumeIndexStore.maximumDataBytes
    private static let defaultUserRoots = [
        "~/Downloads",
        "~/Desktop",
        "~/Documents",
        "~/Movies",
        "~/Music",
        "~/Pictures"
    ]

    private static let protectedWholeComputerRoots = [
        "/Applications",
        "/System",
        "/Library",
        "/private",
        "/usr",
        "/bin",
        "/sbin",
        "/opt",
        "/cores",
        "/System/Volumes/Data/Applications",
        "/System/Volumes/Data/Library",
        "/System/Volumes/Data/private",
        "/System/Volumes/Data/usr",
        "/System/Volumes/Data/opt",
        "/System/Volumes/Data/cores",
        "/System/Volumes/Preboot",
        "/System/Volumes/Recovery",
        "/System/Volumes/VM",
        "/System/Volumes/Update",
        "/System/Volumes/xarts",
        "/System/Volumes/iSCPreboot"
    ]

    private static let protectedWholeComputerTopLevelNames: [String] =
        protectedWholeComputerRoots.compactMap { root in
            let components = root.split(separator: "/")
            return components.count == 1 ? String(components[0]) : nil
        }

    private static let systemVolumeNames: Set<String> = [
        "recovery",
        "preboot",
        "vm",
        "update",
        "xarts",
        "hardware",
        "iscpreboot",
        "time machine backups",
        "com.apple.timemachine",
        "backups.backupdb"
    ]

    private static let mountedVolumeResourceKeys: [URLResourceKey] = [
        .volumeIsLocalKey,
        .volumeIsBrowsableKey,
        .volumeIsReadOnlyKey,
        .volumeIsInternalKey,
        .volumeNameKey
    ]

    struct Configuration: Codable, Hashable, Sendable {
        var scope: DuplicateFileScanScope
        var roots: [String]
        var excludedPaths: [String]
        var minimumBytes: Int64
        var maxFilesScanned: Int
        var maxDirectoriesScanned: Int
        var maxDepth: Int
        var maxResults: Int
        var maxScanSeconds: TimeInterval
        var directoryReadTimeout: TimeInterval
        var candidateRules: Set<DuplicateFileCandidateGroup.Rule>

        init(
            scope: DuplicateFileScanScope = .userFiles,
            roots: [String],
            excludedPaths: [String],
            minimumBytes: Int64 = 0,
            maxFilesScanned: Int = 3_000,
            maxDirectoriesScanned: Int = 650,
            maxDepth: Int = 4,
            maxResults: Int = 80,
            maxScanSeconds: TimeInterval = 4,
            directoryReadTimeout: TimeInterval = 0.45,
            candidateRules: Set<DuplicateFileCandidateGroup.Rule> = Set(
                DuplicateFileCandidateGroup.Rule.selectableCases
            )
        ) {
            self.scope = scope
            self.roots = roots
            self.excludedPaths = excludedPaths
            self.minimumBytes = minimumBytes
            self.maxFilesScanned = maxFilesScanned
            self.maxDirectoriesScanned = maxDirectoriesScanned
            self.maxDepth = maxDepth
            self.maxResults = maxResults
            self.maxScanSeconds = maxScanSeconds
            self.directoryReadTimeout = directoryReadTimeout
            self.candidateRules = candidateRules.intersection(
                DuplicateFileCandidateGroup.Rule.selectableCases
            )
        }

        static func userFiles(
            customRoots: [String] = [],
            externalVolumeRoots: [String] = [],
            excludedPaths: [String] = ScanExclusionService.excludedPaths(),
            candidateRules: Set<DuplicateFileCandidateGroup.Rule> = Set(
                DuplicateFileCandidateGroup.Rule.selectableCases
            )
        ) -> Configuration {
            Configuration(
                roots: mergedRoots(defaultUserRoots + customRoots + externalVolumeRoots),
                excludedPaths: excludedPaths,
                minimumBytes: 0,
                maxFilesScanned: 8_000,
                maxDirectoriesScanned: 900,
                maxDepth: 5,
                maxResults: 120,
                maxScanSeconds: 10,
                directoryReadTimeout: 0.5,
                candidateRules: candidateRules
            )
        }

        static func wholeComputer(
            userDataRoot: String = FileManager.default.homeDirectoryForCurrentUser
                .deletingLastPathComponent().path,
            customRoots: [String] = [],
            externalVolumeRoots: [String] = [],
            excludedPaths: [String] = ScanExclusionService.excludedPaths(),
            candidateRules: Set<DuplicateFileCandidateGroup.Rule> = Set(
                DuplicateFileCandidateGroup.Rule.selectableCases
            ),
            mountedVolumes: [MountedVolumeMetadata]? = nil
        ) -> Configuration {
            let roots = DuplicateFileScanner.safeWholeComputerRoots(
                userDataRoot: userDataRoot,
                customRoots: customRoots,
                externalVolumeRoots: externalVolumeRoots,
                mountedVolumes: mountedVolumes
            )
            return Configuration(
                scope: .wholeComputer,
                roots: roots,
                excludedPaths: mergedRoots(
                    excludedPaths
                        + DuplicateFileScanner.protectedWholeComputerRoots
                        + DuplicateFileScanner.protectedVolumeSubpaths(for: roots)
                ),
                minimumBytes: 0,
                maxFilesScanned: 250_000,
                maxDirectoriesScanned: 30_000,
                maxDepth: 12,
                maxResults: 200,
                maxScanSeconds: 30,
                directoryReadTimeout: 0.5,
                candidateRules: candidateRules
            )
        }

        fileprivate static func mergedRoots(_ roots: [String]) -> [String] {
            var merged = [String]()
            for root in roots {
                let normalized = PathSafety.normalizedPath(root)
                guard !merged.contains(where: { existing in
                    let existingPath = PathSafety.normalizedPath(existing)
                    return isSameOrNested(normalized, in: existingPath)
                }) else {
                    continue
                }
                merged.removeAll { existing in
                    let existingPath = PathSafety.normalizedPath(existing)
                    return isSameOrNested(existingPath, in: normalized)
                }
                merged.append(root)
            }
            return merged
        }

        private static func isSameOrNested(_ candidate: String, in parent: String) -> Bool {
            candidate == parent || parent == "/" || candidate.hasPrefix(parent + "/")
        }
    }

    private static func safeWholeComputerRoots(
        userDataRoot: String,
        customRoots: [String],
        externalVolumeRoots: [String],
        mountedVolumes: [MountedVolumeMetadata]?
    ) -> [String] {
        let normalizedUserRoot = PathSafety.normalizedPath(userDataRoot)
        let protected = protectedWholeComputerRoots.map(PathSafety.normalizedPath)
        let safeUserRoot = normalizedUserRoot != "/"
            && !protected.contains(where: {
                normalizedUserRoot == $0 || normalizedUserRoot.hasPrefix($0 + "/")
            })
            ? normalizedUserRoot
            : PathSafety.normalizedPath(
                FileManager.default.homeDirectoryForCurrentUser.deletingLastPathComponent().path
            )
        let allowedExternalRoots = (customRoots + externalVolumeRoots).filter {
            let normalized = PathSafety.normalizedPath($0)
            return normalized.hasPrefix("/Volumes/")
                && specialPathSkipReason(normalized) == nil
        }
        let automaticLocalDataRoots = autoLocalDataVolumeRoots(
            mountedVolumes ?? mountedVolumeMetadata()
        )
        return Configuration.mergedRoots(
            [safeUserRoot] + automaticLocalDataRoots + allowedExternalRoots
        )
    }

    private static func mountedVolumeMetadata() -> [MountedVolumeMetadata] {
        let fileManager = FileManager.default
        let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: mountedVolumeResourceKeys,
            options: [.skipHiddenVolumes]
        ) ?? []
        let keys = Set(mountedVolumeResourceKeys)
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return MountedVolumeMetadata(
                url: url,
                isLocal: values.volumeIsLocal,
                isBrowsable: values.volumeIsBrowsable,
                isReadOnly: values.volumeIsReadOnly,
                isInternal: values.volumeIsInternal,
                name: values.volumeName
            )
        }
    }

    private static func autoLocalDataVolumeRoots(
        _ volumes: [MountedVolumeMetadata]
    ) -> [String] {
        Configuration.mergedRoots(volumes.compactMap { volume in
            guard volume.url.isFileURL,
                  volume.url.path.hasPrefix("/"),
                  volume.isLocal == true,
                  volume.isBrowsable == true else {
                return nil
            }

            let path = PathSafety.normalizedPath(volume.url.path)
            guard path.hasPrefix("/Volumes/"),
                  path != "/Volumes",
                  !isProtectedWholeComputerPath(path),
                  !isSystemVolume(path: path, name: volume.name) else {
                return nil
            }

            // Read-only internal mounts are the sealed/system-container class;
            // ordinary local data volumes may still be read-only and remain
            // safe for this scanner's read-only traversal.
            guard !(volume.isReadOnly == true && volume.isInternal != false) else {
                return nil
            }
            return path
        })
    }

    private static func protectedVolumeSubpaths(for roots: [String]) -> [String] {
        roots.flatMap { root in
            let normalized = PathSafety.normalizedPath(root)
            guard normalized.hasPrefix("/Volumes/") else { return [String]() }
            return protectedWholeComputerTopLevelNames.map {
                "\(normalized)/\($0)"
            }
        }
    }

    private static func isProtectedWholeComputerPath(_ path: String) -> Bool {
        let normalized = PathSafety.normalizedPath(path)
        return protectedWholeComputerRoots.contains {
            let root = PathSafety.normalizedPath($0)
            return normalized == root || normalized.hasPrefix(root + "/")
        }
    }

    private static func isSystemVolume(path: String, name: String?) -> Bool {
        let normalized = PathSafety.normalizedPath(path)
        let lastComponent = URL(fileURLWithPath: normalized).lastPathComponent.lowercased()
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return systemVolumeNames.contains(lastComponent)
            || normalizedName.map(systemVolumeNames.contains) == true
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

    private enum DirectoryReadError: Error {
        case timedOut
    }

    private enum FileReadError: Error {
        case cancelled
        case deadlineReached
        case invalidOrChanged
        case truncated
    }

    private enum CheckpointResult {
        case proceed
        case cancelled
        case timedOut
    }

    private final class ActiveScanTimeBudget {
        private var deadlineUptime: TimeInterval

        init(seconds: TimeInterval) {
            deadlineUptime = ProcessInfo.processInfo.systemUptime + seconds
        }

        func waitUntilRunnable(_ control: DuplicateFileScanControl) -> Bool {
            let wait = control.waitUntilRunnable()
            deadlineUptime += wait.pausedDuration
            return wait.shouldContinue
        }

        var hasTimeRemaining: Bool {
            ProcessInfo.processInfo.systemUptime < deadlineUptime
        }
    }

    private struct PendingDirectory: Codable, Hashable, Sendable {
        let path: String
        let depth: Int
        let rootIndex: Int

        var url: URL { URL(fileURLWithPath: path) }
    }

    private struct FileIdentity: Codable, Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct FileSnapshot: Codable, Equatable, Sendable {
        let identity: FileIdentity
        let sizeBytes: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    private struct FileCandidate: Codable, Sendable {
        let name: String
        let path: String
        let snapshot: FileSnapshot

        var sizeBytes: Int64 { snapshot.sizeBytes }
    }

    private struct QuickFingerprint: Hashable {
        let head: Data
        let tail: Data
    }

    private struct QuickCandidate {
        let candidate: FileCandidate
        let fingerprint: QuickFingerprint
    }

    private struct HashedCandidate {
        let candidate: FileCandidate
        let digest: Data
    }

    private struct CloneClusterEvidence {
        let path: String
        let cloneClusterID: UInt64?
        let hardLinkClusterID: UInt64?
    }

    private final class CloneClusterProbe: ArchiveStreamProtocol {
        var entries = [CloneClusterEvidence]()

        func writeHeader(_ header: ArchiveHeader) throws {
            var cloneClusterID: UInt64?
            var hardLinkClusterID: UInt64?
            for field in header {
                guard case let .uint(key, value) = field else { continue }
                switch key.description {
                case "CLC": cloneClusterID = value
                case "HLC": hardLinkClusterID = value
                default: break
                }
            }
            guard let path = header.entryPath?.string else { return }
            entries.append(
                CloneClusterEvidence(
                    path: path,
                    cloneClusterID: cloneClusterID,
                    hardLinkClusterID: hardLinkClusterID
                )
            )
        }

        func writeBlob(key: ArchiveHeader.FieldKey, from: UnsafeRawBufferPointer) throws {}
        func readHeader() throws -> ArchiveHeader? { nil }
        func readBlob(key: ArchiveHeader.FieldKey, into: UnsafeMutableRawBufferPointer) throws {}
        func cancel() {}
        func close() throws {}
    }

    private struct ConfirmationResult {
        var groups: [DuplicateFileGroup]
        var cancelled: Bool
        var timedOut: Bool
    }

    private struct RootCoverageBuilder: Codable {
        let rootPath: String
        var status: DuplicateFileScanRootCoverage.Status = .skipped
        var skipReason: DuplicateFileScanSkipReason?
        var scannedDirectories = 0
        var scannedFiles = 0
        var scannedBytes: Int64 = 0
        var skippedPaths = [DuplicateFileScanSkippedPath]()

        mutating func recordSkip(path: String, reason: DuplicateFileScanSkipReason) {
            let skipped = DuplicateFileScanSkippedPath(path: path, reason: reason)
            if skippedPaths.last != skipped {
                skippedPaths.append(skipped)
            }
        }

        var coverage: DuplicateFileScanRootCoverage {
            DuplicateFileScanRootCoverage(
                rootPath: rootPath,
                status: status,
                skipReason: skipReason,
                scannedDirectories: scannedDirectories,
                scannedFiles: scannedFiles,
                scannedBytes: scannedBytes,
                skippedPaths: skippedPaths
            )
        }
    }

    private struct ResumeIndex: Codable {
        let version: Int
        let updatedAt: Date
        let configuration: Configuration
        let directories: [PendingDirectory]
        let directoryIndex: Int
        let remainingDirectoryEntries: [String]?
        let candidates: [FileCandidate]
        let coverageBuilders: [RootCoverageBuilder]
        let progress: DuplicateFileScanProgress
    }

    private static func encodedResumeIndex(
        configuration: Configuration,
        directories: [PendingDirectory],
        directoryIndex: Int,
        remainingDirectoryEntries: [String]?,
        candidates: [FileCandidate],
        coverageBuilders: [RootCoverageBuilder],
        progress: DuplicateFileScanProgress
    ) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(
            ResumeIndex(
                version: resumeIndexVersion,
                updatedAt: Date(),
                configuration: configuration,
                directories: directories,
                directoryIndex: directoryIndex,
                remainingDirectoryEntries: remainingDirectoryEntries,
                candidates: candidates,
                coverageBuilders: coverageBuilders,
                progress: progress
            )
        ), data.count <= maximumResumeDataBytes else {
            return nil
        }
        return data
    }

    private static func validatedResumeIndex(
        from data: Data,
        configuration: Configuration
    ) -> ResumeIndex? {
        guard !data.isEmpty,
              data.count <= maximumResumeDataBytes,
              let index = try? JSONDecoder().decode(ResumeIndex.self, from: data),
              index.version == resumeIndexVersion,
              index.configuration == configuration,
              index.directoryIndex >= 0,
              index.directoryIndex <= index.directories.count,
              index.coverageBuilders.count == configuration.roots.count,
              index.progress.scannedDirectories >= 0,
              index.progress.scannedDirectories
                  <= Int.max - max(0, configuration.maxDirectoriesScanned),
              index.progress.scannedFiles >= 0,
              index.progress.scannedFiles <= Int.max - max(0, configuration.maxFilesScanned),
              index.progress.scannedBytes >= 0,
              index.progress.hashedFiles >= 0,
              index.progress.hashedBytes >= 0 else {
            return nil
        }
        let age = Date().timeIntervalSince(index.updatedAt)
        guard age >= -300, age <= maximumResumeAge else { return nil }

        // Keep roots lexical while validating/resuming so an explicitly selected
        // symlink root is rejected instead of silently traversing its target.
        let roots = configuration.roots.map(PathSafety.lexicalPath)
        guard zip(index.coverageBuilders, roots).allSatisfy({ builder, root in
            builder.rootPath == root
                && builder.scannedDirectories >= 0
                && builder.scannedFiles >= 0
                && builder.scannedBytes >= 0
                && builder.skippedPaths.allSatisfy {
                    PathSafety.isContained($0.path, in: root, resolvingSymlinks: false)
                }
        }) else {
            return nil
        }
        guard index.directories.count <= 1_000_000,
              index.directories.allSatisfy({ directory in
                  directory.rootIndex >= 0
                      && directory.rootIndex < roots.count
                      && directory.depth >= 0
                      && directory.depth <= configuration.maxDepth
                      && PathSafety.isContained(
                          directory.path,
                          in: roots[directory.rootIndex],
                          resolvingSymlinks: false
                      )
              }) else {
            return nil
        }
        var candidatePaths = Set<String>()
        guard index.candidates.count <= index.progress.scannedFiles,
              index.candidates.allSatisfy({ candidate in
                  candidate.snapshot.sizeBytes >= configuration.minimumBytes
                      && candidatePaths.insert(candidate.path).inserted
                      && roots.contains(where: {
                          PathSafety.isContained(
                              candidate.path,
                              in: $0,
                              resolvingSymlinks: false
                          )
                      })
              }) else {
            return nil
        }
        if let remainingEntries = index.remainingDirectoryEntries {
            guard index.directoryIndex > 0,
                  !remainingEntries.isEmpty,
                  remainingEntries.count <= 1_000_000 else {
                return nil
            }
            let currentDirectory = index.directories[index.directoryIndex - 1]
            let currentDirectoryPath = PathSafety.lexicalPath(currentDirectory.path)
            let queuedDirectoryPaths = Set(index.directories.map(\.path))
            var remainingPaths = Set<String>()
            guard remainingEntries.allSatisfy({ path in
                let lexical = PathSafety.lexicalPath(path)
                let parent = PathSafety.lexicalPath(
                    URL(fileURLWithPath: lexical).deletingLastPathComponent().path
                )
                return path == lexical
                    && parent == currentDirectoryPath
                    && remainingPaths.insert(path).inserted
                    && !candidatePaths.contains(path)
                    && !queuedDirectoryPaths.contains(path)
            }) else {
                return nil
            }
        }
        return index
    }

    static func scan(configuration: Configuration) -> [DirectoryEntry] {
        scanGroups(configuration: configuration).flatMap(\.files)
    }

    static func scanGroups(configuration: Configuration) -> [DuplicateFileGroup] {
        scanReport(configuration: configuration).exactGroups
    }

    static func scanReport(
        configuration: Configuration,
        control: DuplicateFileScanControl = DuplicateFileScanControl(),
        progress progressHandler: ProgressHandler? = nil
    ) -> DuplicateFileScanReport {
        scanReport(
            configuration: configuration,
            resumeIndexData: nil,
            control: control,
            resumeIndex: nil,
            progress: progressHandler
        )
    }

    static func scanReport(
        configuration: Configuration,
        resumeIndexData: Data?,
        control: DuplicateFileScanControl = DuplicateFileScanControl(),
        resumeIndex resumeIndexHandler: ResumeIndexHandler? = nil,
        progress progressHandler: ProgressHandler? = nil
    ) -> DuplicateFileScanReport {
        let fileManager = FileManager.default
        let timeBudget = ActiveScanTimeBudget(seconds: configuration.maxScanSeconds)
        let resumed = resumeIndexData.flatMap {
            validatedResumeIndex(from: $0, configuration: configuration)
        }
        if resumeIndexData != nil, resumed == nil {
            resumeIndexHandler?(nil)
        }
        var progress = resumed?.progress ?? .initial
        progress.phase = .discovering
        progress.currentPath = nil
        progress.estimatedTotalDirectories = nil
        progress.estimatedTotalFiles = nil
        progress.estimatedTotalBytes = nil
        var coverageBuilders = resumed?.coverageBuilders ?? configuration.roots.map {
            // Expand `~` but preserve symlink components for rootSkipReason.
            RootCoverageBuilder(rootPath: PathSafety.lexicalPath($0))
        }
        var directories = resumed?.directories ?? []
        var directoryIndex = resumed?.directoryIndex ?? 0
        var remainingDirectoryEntries = resumed?.remainingDirectoryEntries
        var candidates = resumed?.candidates ?? []
        var lastResumeIndexData = resumed == nil ? nil : resumeIndexData
        let runStartScannedFiles = progress.scannedFiles
        let runStartScannedDirectories = progress.scannedDirectories
        let fileBudget = max(0, configuration.maxFilesScanned)
        let directoryBudget = max(0, configuration.maxDirectoriesScanned)
        var reachedTimeLimit = false
        var reachedFileLimit = false
        var reachedDirectoryLimit = false
        var cancelled = false

        func publishResumeCheckpointIfNeeded(force: Bool = false) {
            guard force
                    || directoryIndex.isMultiple(of: resumeCheckpointDirectoryCadence) else {
                return
            }
            guard let data = encodedResumeIndex(
                configuration: configuration,
                directories: directories,
                directoryIndex: directoryIndex,
                remainingDirectoryEntries: remainingDirectoryEntries,
                candidates: candidates,
                coverageBuilders: coverageBuilders,
                progress: progress
            ) else {
                return
            }
            lastResumeIndexData = data
            resumeIndexHandler?(data)
        }

        publish(&progress, phase: .discovering, path: nil, handler: progressHandler)

        if resumed == nil {
            for index in coverageBuilders.indices {
                let rootPath = coverageBuilders[index].rootPath
                switch checkpoint(
                    control: control,
                    timeBudget: timeBudget,
                    progress: &progress,
                    phase: .discovering,
                    path: rootPath,
                    handler: progressHandler
                ) {
                case .cancelled:
                    cancelled = true
                    coverageBuilders[index].skipReason = .cancelled
                    continue
                case .timedOut:
                    reachedTimeLimit = true
                    coverageBuilders[index].skipReason = .timeLimit
                    continue
                case .proceed:
                    break
                }

                if let reason = rootSkipReason(
                    rootPath,
                    excludedPaths: configuration.excludedPaths,
                    fileManager: fileManager
                ) {
                    coverageBuilders[index].skipReason = reason
                    continue
                }

                coverageBuilders[index].status = .scanned
                directories.append(PendingDirectory(path: rootPath, depth: 0, rootIndex: index))
            }
            if !cancelled, !reachedTimeLimit {
                publishResumeCheckpointIfNeeded(force: true)
            }
        }

        traversal: while remainingDirectoryEntries != nil || directoryIndex < directories.count {
            if progress.scannedFiles - runStartScannedFiles >= fileBudget {
                reachedFileLimit = true
                break
            }
            if progress.scannedDirectories - runStartScannedDirectories >= directoryBudget {
                reachedDirectoryLimit = true
                break
            }

            let isResumingDirectory = remainingDirectoryEntries != nil
            let directory: PendingDirectory
            if isResumingDirectory {
                directory = directories[directoryIndex - 1]
            } else {
                directory = directories[directoryIndex]
                directoryIndex += 1
            }
            let directoryPath = PathSafety.normalizedPath(directory.path)

            switch checkpoint(
                control: control,
                timeBudget: timeBudget,
                progress: &progress,
                phase: .discovering,
                path: directoryPath,
                handler: progressHandler
            ) {
            case .cancelled:
                cancelled = true
                break traversal
            case .timedOut:
                reachedTimeLimit = true
                break traversal
            case .proceed:
                break
            }

            if let reason = directorySkipReason(
                directory.url,
                path: directoryPath,
                excludedPaths: configuration.excludedPaths
            ) {
                if directory.depth == 0 {
                    coverageBuilders[directory.rootIndex].status = .skipped
                    coverageBuilders[directory.rootIndex].skipReason = reason
                } else {
                    coverageBuilders[directory.rootIndex].recordSkip(path: directoryPath, reason: reason)
                }
                remainingDirectoryEntries = nil
                publishResumeCheckpointIfNeeded()
                continue
            }

            let urls: [URL]
            if let remainingEntries = remainingDirectoryEntries {
                urls = remainingEntries.map { URL(fileURLWithPath: $0) }
                remainingDirectoryEntries = nil
            } else {
                progress.scannedDirectories += 1
                coverageBuilders[directory.rootIndex].scannedDirectories += 1
                publish(
                    &progress,
                    phase: .discovering,
                    path: directoryPath,
                    handler: progressHandler
                )
                do {
                    urls = try directoryContents(
                        at: directory.url,
                        includingPropertiesForKeys: [
                            .isDirectoryKey,
                            .isRegularFileKey,
                            .isSymbolicLinkKey,
                            .isPackageKey
                        ],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                        timeout: configuration.directoryReadTimeout
                    )
                } catch {
                    let reason = skipReason(for: error)
                    if directory.depth == 0 {
                        coverageBuilders[directory.rootIndex].status = .skipped
                        coverageBuilders[directory.rootIndex].skipReason = reason
                    } else {
                        coverageBuilders[directory.rootIndex].recordSkip(
                            path: directoryPath,
                            reason: reason
                        )
                    }
                    publishResumeCheckpointIfNeeded()
                    continue
                }
            }

            for (entryIndex, url) in urls.enumerated() {
                if progress.scannedFiles - runStartScannedFiles >= fileBudget {
                    remainingDirectoryEntries = Array(urls[entryIndex...]).map {
                        PathSafety.lexicalPath($0.path)
                    }
                    reachedFileLimit = true
                    break traversal
                }

                let path = PathSafety.normalizedPath(url.path)
                switch checkpoint(
                    control: control,
                    timeBudget: timeBudget,
                    progress: &progress,
                    phase: .discovering,
                    path: path,
                    handler: progressHandler
                ) {
                case .cancelled:
                    cancelled = true
                    break traversal
                case .timedOut:
                    reachedTimeLimit = true
                    break traversal
                case .proceed:
                    break
                }

                if ScanExclusionService.isExcluded(path, excludedPaths: configuration.excludedPaths) {
                    coverageBuilders[directory.rootIndex].recordSkip(path: path, reason: .excluded)
                    continue
                }
                if let reason = specialPathSkipReason(path) {
                    coverageBuilders[directory.rootIndex].recordSkip(path: path, reason: reason)
                    continue
                }

                let values: URLResourceValues
                do {
                    values = try url.resourceValues(
                        forKeys: [
                            .isDirectoryKey,
                            .isRegularFileKey,
                            .isSymbolicLinkKey,
                            .isPackageKey
                        ]
                    )
                } catch {
                    coverageBuilders[directory.rootIndex].recordSkip(
                        path: path,
                        reason: skipReason(for: error)
                    )
                    continue
                }

                if values.isSymbolicLink == true {
                    coverageBuilders[directory.rootIndex].recordSkip(path: path, reason: .symbolicLink)
                    continue
                }

                if values.isDirectory == true {
                    if values.isPackage == true || isKnownPackage(url) {
                        coverageBuilders[directory.rootIndex].recordSkip(path: path, reason: .package)
                    } else if shouldSkipDirectory(url)
                                || shouldSkipWholeComputerDirectory(
                                    url,
                                    parentDepth: directory.depth,
                                    scope: configuration.scope
                                ) {
                        coverageBuilders[directory.rootIndex].recordSkip(path: path, reason: .policyExcluded)
                    } else if Darwin.access(path, R_OK | X_OK) != 0 {
                        coverageBuilders[directory.rootIndex].recordSkip(path: path, reason: .permissionDenied)
                    } else if directory.depth >= configuration.maxDepth {
                        coverageBuilders[directory.rootIndex].recordSkip(path: path, reason: .depthLimit)
                    } else {
                        directories.append(
                            PendingDirectory(
                                path: path,
                                depth: directory.depth + 1,
                                rootIndex: directory.rootIndex
                            )
                        )
                    }
                    continue
                }

                guard values.isRegularFile == true else {
                    continue
                }
                guard Darwin.access(path, R_OK) == 0 else {
                    coverageBuilders[directory.rootIndex].recordSkip(
                        path: path,
                        reason: .permissionDenied
                    )
                    continue
                }
                guard
                      let snapshot = fileSnapshot(atPath: path) else {
                    continue
                }

                progress.scannedFiles += 1
                progress.scannedBytes += snapshot.sizeBytes
                coverageBuilders[directory.rootIndex].scannedFiles += 1
                coverageBuilders[directory.rootIndex].scannedBytes += snapshot.sizeBytes
                publish(&progress, phase: .discovering, path: path, handler: progressHandler)

                if snapshot.sizeBytes >= configuration.minimumBytes {
                    candidates.append(
                        FileCandidate(name: url.lastPathComponent, path: path, snapshot: snapshot)
                    )
                }
            }
            publishResumeCheckpointIfNeeded()
        }

        let unfinishedRootReason: DuplicateFileScanSkipReason? = if cancelled {
            .cancelled
        } else if reachedTimeLimit {
            .timeLimit
        } else if reachedDirectoryLimit {
            .directoryLimit
        } else if reachedFileLimit {
            .fileLimit
        } else {
            nil
        }
        if let unfinishedRootReason {
            for index in coverageBuilders.indices
            where coverageBuilders[index].scannedDirectories == 0
                && coverageBuilders[index].skipReason == nil {
                coverageBuilders[index].status = .skipped
                coverageBuilders[index].skipReason = unfinishedRootReason
            }
        }

        let discoveryComplete = !cancelled
            && !reachedTimeLimit
            && !reachedFileLimit
            && !reachedDirectoryLimit
            && directoryIndex >= directories.count
        if discoveryComplete {
            progress.estimatedTotalDirectories = progress.scannedDirectories
            progress.estimatedTotalFiles = progress.scannedFiles
            progress.estimatedTotalBytes = progress.scannedBytes
            publishResumeCheckpointIfNeeded(force: true)
        }
        if reachedFileLimit || reachedDirectoryLimit {
            publishResumeCheckpointIfNeeded(force: true)
        }

        var confirmation = ConfirmationResult(groups: [], cancelled: false, timedOut: false)
        if !cancelled && !reachedTimeLimit {
            confirmation = confirmedGroups(
                from: candidates,
                timeBudget: timeBudget,
                control: control,
                progress: &progress,
                handler: progressHandler
            )
            cancelled = confirmation.cancelled
            reachedTimeLimit = reachedTimeLimit || confirmation.timedOut
        }

        let allExactGroups = confirmation.groups
        let allCandidates = manualCandidates(
            from: candidates,
            exactGroups: allExactGroups,
            rules: configuration.candidateRules,
            timeBudget: timeBudget,
            control: control
        )
        cancelled = cancelled || control.isCancelled
        reachedTimeLimit = reachedTimeLimit || !timeBudget.hasTimeRemaining
        let exactLimit = limitedExactGroups(allExactGroups, maxResults: configuration.maxResults)
        let exactFileCount = exactLimit.groups.reduce(0) { $0 + $1.files.count }
        let candidateLimit = limitedCandidateGroups(
            allCandidates,
            maxResults: max(0, configuration.maxResults - exactFileCount)
        )
        let reachedResultLimit = exactLimit.reachedLimit || candidateLimit.reachedLimit

        progress.phase = .finished
        progress.currentPath = nil
        progressHandler?(progress)

        let rootCoverage = coverageBuilders.map(\.coverage)
        let coverage = DuplicateFileScanCoverage(
            roots: rootCoverage,
            reachedTimeLimit: reachedTimeLimit,
            reachedFileLimit: reachedFileLimit,
            reachedDirectoryLimit: reachedDirectoryLimit,
            reachedResultLimit: reachedResultLimit
        )
        let incompleteSkipReasons: Set<DuplicateFileScanSkipReason> = [
            .permissionDenied, .timedOut, .unreadable
        ]
        let hasIncompleteSkippedPath = rootCoverage.contains { root in
            root.skippedPaths.contains { incompleteSkipReasons.contains($0.reason) }
        }
        let isPartial = reachedTimeLimit
            || reachedFileLimit
            || reachedDirectoryLimit
            || reachedResultLimit
            || hasIncompleteSkippedPath
            || rootCoverage.contains(where: { $0.status == .skipped })

        if cancelled || reachedTimeLimit || reachedFileLimit || reachedDirectoryLimit {
            if let lastResumeIndexData {
                resumeIndexHandler?(lastResumeIndexData)
            }
        } else {
            resumeIndexHandler?(nil)
        }

        return DuplicateFileScanReport(
            exactGroups: exactLimit.groups,
            candidates: candidateLimit.groups,
            coverage: coverage,
            progress: progress,
            outcome: cancelled ? .cancelled : (isPartial ? .partial : .complete)
        )
    }

    private static func storageRelationship(
        for candidates: [FileCandidate]
    ) -> DuplicateFileStorageRelationship {
        guard candidates.count > 1,
              let evidenceByPath = cloneClusterEvidence(for: candidates),
              evidenceByPath.count == candidates.count else {
            return .unknown
        }
        let evidence = candidates.compactMap({ evidenceByPath[$0.path] })
        guard evidence.count == candidates.count else {
            return .unknown
        }

        let cloneIDs = evidence.compactMap(\.cloneClusterID)
        if cloneIDs.count == evidence.count {
            return Set(cloneIDs).count == 1 ? .apfsClone : .unknown
        }

        let hardLinkIDs = evidence.compactMap(\.hardLinkClusterID)
        if hardLinkIDs.count == evidence.count {
            return Set(hardLinkIDs).count == 1 ? .hardLink : .unknown
        }

        return cloneIDs.isEmpty && hardLinkIDs.isEmpty ? .independent : .unknown
    }

    private static func cloneClusterEvidence(
        for candidates: [FileCandidate]
    ) -> [String: CloneClusterEvidence]? {
        // AppleArchive exposes CLC/HLC while encoding a path list; no stat
        // size or allocation heuristic is used to infer shared blocks.
        guard let keySet = ArchiveHeader.FieldKeySet("CLC,HLC,PAT,TYP") else {
            return nil
        }

        let groupedByParent = Dictionary(grouping: candidates) { candidate in
            PathSafety.lexicalPath(
                URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path
            )
        }
        var evidenceByPath = [String: CloneClusterEvidence]()

        for (parentPath, parentCandidates) in groupedByParent {
            let targetNames = Set(parentCandidates.map { URL(fileURLWithPath: $0.path).lastPathComponent })
            let probe = CloneClusterProbe()
            let filter: ArchiveHeader.EntryFilter = { message, path, _ in
                guard message == .searchExclude else { return .ok }
                return targetNames.contains(path.string) ? .ok : .skip
            }

            do {
                try ArchiveStream.withStream(wrapping: probe) { stream in
                    try stream.writeDirectoryContents(
                        archiveFrom: FilePath(parentPath),
                        keySet: keySet,
                        selectUsing: filter
                    )
                }
            } catch {
                return nil
            }

            for evidence in probe.entries where targetNames.contains(evidence.path) {
                guard let candidate = parentCandidates.first(where: {
                    URL(fileURLWithPath: $0.path).lastPathComponent == evidence.path
                }) else {
                    continue
                }
                guard fileSnapshot(atPath: candidate.path) == candidate.snapshot else {
                    return nil
                }
                evidenceByPath[candidate.path] = evidence
            }
        }

        return evidenceByPath
    }

    private static func confirmedGroups(
        from candidates: [FileCandidate],
        timeBudget: ActiveScanTimeBudget,
        control: DuplicateFileScanControl,
        progress: inout DuplicateFileScanProgress,
        handler: ProgressHandler?
    ) -> ConfirmationResult {
        var matches = [DuplicateFileGroup]()

        for sameSize in Dictionary(grouping: candidates, by: \.sizeBytes).values where sameSize.count > 1 {
            var seenIdentities = Set<FileIdentity>()
            let uniqueFiles = sameSize
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .filter { seenIdentities.insert($0.snapshot.identity).inserted }
            guard uniqueFiles.count > 1 else { continue }

            var quickCandidates = [QuickCandidate]()
            for candidate in uniqueFiles {
                switch checkpoint(
                    control: control,
                    timeBudget: timeBudget,
                    progress: &progress,
                    phase: .fingerprinting,
                    path: candidate.path,
                    handler: handler
                ) {
                case .cancelled:
                    return ConfirmationResult(groups: matches, cancelled: true, timedOut: false)
                case .timedOut:
                    return ConfirmationResult(groups: matches, cancelled: false, timedOut: true)
                case .proceed:
                    break
                }

                do {
                    let fingerprint = try quickFingerprint(
                        for: candidate,
                        timeBudget: timeBudget,
                        control: control
                    )
                    quickCandidates.append(QuickCandidate(candidate: candidate, fingerprint: fingerprint))
                } catch FileReadError.cancelled {
                    return ConfirmationResult(groups: matches, cancelled: true, timedOut: false)
                } catch FileReadError.deadlineReached {
                    return ConfirmationResult(groups: matches, cancelled: false, timedOut: true)
                } catch {
                    continue
                }
            }

            for sameQuickBytes in Dictionary(grouping: quickCandidates, by: \.fingerprint).values
            where sameQuickBytes.count > 1 {
                var hashedCandidates = [HashedCandidate]()

                for quickCandidate in sameQuickBytes {
                    let candidate = quickCandidate.candidate
                    switch checkpoint(
                        control: control,
                        timeBudget: timeBudget,
                        progress: &progress,
                        phase: .hashing,
                        path: candidate.path,
                        handler: handler
                    ) {
                    case .cancelled:
                        return ConfirmationResult(groups: matches, cancelled: true, timedOut: false)
                    case .timedOut:
                        return ConfirmationResult(groups: matches, cancelled: false, timedOut: true)
                    case .proceed:
                        break
                    }

                    do {
                        let digest = try sha256(
                            for: candidate,
                            timeBudget: timeBudget,
                            control: control
                        ) { byteCount in
                            progress.hashedBytes += Int64(byteCount)
                            publish(
                                &progress,
                                phase: .hashing,
                                path: candidate.path,
                                handler: handler
                            )
                        }
                        progress.hashedFiles += 1
                        publish(&progress, phase: .hashing, path: candidate.path, handler: handler)
                        hashedCandidates.append(HashedCandidate(candidate: candidate, digest: digest))
                    } catch FileReadError.cancelled {
                        return ConfirmationResult(groups: matches, cancelled: true, timedOut: false)
                    } catch FileReadError.deadlineReached {
                        return ConfirmationResult(groups: matches, cancelled: false, timedOut: true)
                    } catch {
                        continue
                    }
                }

                for sameDigest in Dictionary(grouping: hashedCandidates, by: \.digest).values
                where sameDigest.count > 1 {
                    let stableCandidates = sameDigest
                        .map(\.candidate)
                        .filter { fileSnapshot(atPath: $0.path) == $0.snapshot }
                    guard stableCandidates.count > 1,
                          let digest = sameDigest.first?.digest,
                          let sizeBytes = stableCandidates.first?.sizeBytes else {
                        continue
                    }

                    matches.append(
                        DuplicateFileGroup(
                            id: digest.base64EncodedString(),
                            files: stableCandidates.map(directoryEntry),
                            contentSizeBytes: sizeBytes,
                            matchKind: .logicalContentSHA256,
                            relationship: storageRelationship(for: stableCandidates),
                            estimatedPhysicalReclaimableBytes: nil
                        )
                    )
                }
            }
        }

        return ConfirmationResult(
            groups: matches.sorted {
                if $0.contentSizeBytes == $1.contentSizeBytes {
                    return ($0.files.first?.path ?? "").localizedStandardCompare(
                        $1.files.first?.path ?? ""
                    ) == .orderedAscending
                }
                return $0.contentSizeBytes > $1.contentSizeBytes
            },
            cancelled: false,
            timedOut: false
        )
    }

    private static func manualCandidates(
        from candidates: [FileCandidate],
        exactGroups: [DuplicateFileGroup],
        rules: Set<DuplicateFileCandidateGroup.Rule>,
        timeBudget: ActiveScanTimeBudget,
        control: DuplicateFileScanControl
    ) -> [DuplicateFileCandidateGroup] {
        let exactRepresentativeByPath = Dictionary(
            uniqueKeysWithValues: exactGroups.flatMap { group -> [(String, String)] in
                guard let representative = group.files
                    .map(\.path)
                    .min(by: { $0.localizedStandardCompare($1) == .orderedAscending }) else {
                    return []
                }
                return group.files.map { ($0.path, representative) }
            }
        )
        let metadataGroups = DuplicateFileCandidateGroup.Rule.selectableCases
            .filter { $0 != .similarImage && rules.contains($0) }
            .flatMap { rule -> [DuplicateFileCandidateGroup] in
                Dictionary(grouping: candidates) { candidate in
                    candidateKey(candidate, rule: rule)
                }
                .compactMap { key, groupedCandidates in
                    guard let key else { return nil }
                    var seenIdentities = Set<FileIdentity>()
                    let uniqueFiles = groupedCandidates
                        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                        .filter { seenIdentities.insert($0.snapshot.identity).inserted }
                    let reviewFiles = uniqueFiles.filter { candidate in
                        exactRepresentativeByPath[candidate.path].map {
                            $0 == candidate.path
                        } ?? true
                    }
                    guard reviewFiles.count > 1 else { return nil }

                    return DuplicateFileCandidateGroup(
                        id: "candidate|\(rule.rawValue)|\(key)",
                        files: reviewFiles.map(directoryEntry),
                        rule: rule
                    )
                }
            }
        let imageGroups = rules.contains(.similarImage)
            ? similarImageCandidates(
                from: candidates,
                exactRepresentativeByPath: exactRepresentativeByPath,
                timeBudget: timeBudget,
                control: control
            )
            : []
        return (metadataGroups + imageGroups).sorted {
            if $0.rule != $1.rule {
                return $0.rule.rawValue < $1.rule.rawValue
            }
            if $0.files.first?.sizeBytes == $1.files.first?.sizeBytes {
                return ($0.files.first?.path ?? "").localizedStandardCompare(
                    $1.files.first?.path ?? ""
                ) == .orderedAscending
            }
            return ($0.files.first?.sizeBytes ?? 0) > ($1.files.first?.sizeBytes ?? 0)
        }
    }

    private static func candidateKey(
        _ candidate: FileCandidate,
        rule: DuplicateFileCandidateGroup.Rule
    ) -> String? {
        let url = URL(fileURLWithPath: candidate.name)
        switch rule {
        case .sameName:
            return candidate.name.precomposedStringWithCanonicalMapping.lowercased()
        case .sameSize:
            return String(candidate.sizeBytes)
        case .sameType:
            return url.pathExtension.lowercased().nonEmpty
        case .similarImage:
            return nil
        case .sameNameSizeAndType:
            return nil
        }
    }

    private struct ImageSimilaritySignature: Hashable {
        let differenceHash: UInt64
        let aspectRatioBucket: Int
        let redBucket: UInt8
        let greenBucket: UInt8
        let blueBucket: UInt8

        var stableID: String {
            [
                String(differenceHash, radix: 16),
                String(aspectRatioBucket),
                String(redBucket),
                String(greenBucket),
                String(blueBucket),
            ].joined(separator: "-")
        }
    }

    private static let imageCandidateExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    private static func similarImageCandidates(
        from candidates: [FileCandidate],
        exactRepresentativeByPath: [String: String],
        timeBudget: ActiveScanTimeBudget,
        control: DuplicateFileScanControl
    ) -> [DuplicateFileCandidateGroup] {
        var seenIdentities = Set<FileIdentity>()
        let reviewCandidates = candidates
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .filter { imageCandidateExtensions.contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
            .filter { seenIdentities.insert($0.snapshot.identity).inserted }
            .filter { candidate in
                exactRepresentativeByPath[candidate.path].map { $0 == candidate.path } ?? true
            }

        var signatures: [ImageSimilaritySignature: [FileCandidate]] = [:]
        for candidate in reviewCandidates {
            do {
                try checkFileRead(control: control, timeBudget: timeBudget)
                guard let signature = try imageSimilaritySignature(for: candidate) else { continue }
                signatures[signature, default: []].append(candidate)
            } catch FileReadError.cancelled, FileReadError.deadlineReached {
                break
            } catch {
                continue
            }
        }

        return signatures.compactMap { signature, groupedCandidates in
            guard groupedCandidates.count > 1 else { return nil }
            return DuplicateFileCandidateGroup(
                id: "candidate|similarImage|\(signature.stableID)",
                files: groupedCandidates.map(directoryEntry),
                rule: .similarImage
            )
        }
    }

    private static func imageSimilaritySignature(
        for candidate: FileCandidate
    ) throws -> ImageSimilaritySignature? {
        try withValidatedFile(candidate) { handle in
            let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(handle.fileDescriptor)")
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(descriptorURL as CFURL, sourceOptions) else {
                return nil
            }
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceShouldCacheImmediately: false,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
                  image.width > 0,
                  image.height > 0 else {
                return nil
            }
            return imageSimilaritySignature(from: image)
        }
    }

    private static func imageSimilaritySignature(
        from image: CGImage
    ) -> ImageSimilaritySignature? {
        let width = 9
        let height = 8
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * bytesPerPixel,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var differenceHash: UInt64 = 0
        var redTotal = 0
        var greenTotal = 0
        var blueTotal = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                redTotal += Int(pixels[offset])
                greenTotal += Int(pixels[offset + 1])
                blueTotal += Int(pixels[offset + 2])
                guard x < width - 1 else { continue }
                let nextOffset = offset + bytesPerPixel
                let currentLuma = 299 * Int(pixels[offset])
                    + 587 * Int(pixels[offset + 1])
                    + 114 * Int(pixels[offset + 2])
                let nextLuma = 299 * Int(pixels[nextOffset])
                    + 587 * Int(pixels[nextOffset + 1])
                    + 114 * Int(pixels[nextOffset + 2])
                if currentLuma > nextLuma {
                    differenceHash |= UInt64(1) << UInt64(y * (width - 1) + x)
                }
            }
        }

        let pixelCount = width * height
        return ImageSimilaritySignature(
            differenceHash: differenceHash,
            aspectRatioBucket: Int((Double(image.width) / Double(image.height) * 32).rounded()),
            redBucket: UInt8((redTotal / pixelCount) / 16),
            greenBucket: UInt8((greenTotal / pixelCount) / 16),
            blueBucket: UInt8((blueTotal / pixelCount) / 16)
        )
    }

    private static func limitedExactGroups(
        _ groups: [DuplicateFileGroup],
        maxResults: Int
    ) -> (groups: [DuplicateFileGroup], reachedLimit: Bool) {
        var remainingFiles = max(0, maxResults)
        var limited = [DuplicateFileGroup]()
        var includedFiles = 0
        let totalFiles = groups.reduce(0) { $0 + $1.files.count }

        for group in groups where remainingFiles >= 2 {
            let files = Array(group.files.prefix(remainingFiles))
            guard files.count > 1 else { continue }
            limited.append(
                DuplicateFileGroup(
                    id: group.id,
                    files: files,
                    contentSizeBytes: group.contentSizeBytes,
                    matchKind: group.matchKind,
                    relationship: group.relationship,
                    estimatedPhysicalReclaimableBytes: nil
                )
            )
            includedFiles += files.count
            remainingFiles -= files.count
        }
        return (limited, includedFiles < totalFiles)
    }

    private static func limitedCandidateGroups(
        _ groups: [DuplicateFileCandidateGroup],
        maxResults: Int
    ) -> (groups: [DuplicateFileCandidateGroup], reachedLimit: Bool) {
        var remainingFiles = max(0, maxResults)
        var limited = [DuplicateFileCandidateGroup]()
        var includedFiles = 0
        let totalFiles = groups.reduce(0) { $0 + $1.files.count }

        for group in groups where remainingFiles >= 2 {
            let files = Array(group.files.prefix(remainingFiles))
            guard files.count > 1 else { continue }
            limited.append(
                DuplicateFileCandidateGroup(id: group.id, files: files, rule: group.rule)
            )
            includedFiles += files.count
            remainingFiles -= files.count
        }
        return (limited, includedFiles < totalFiles)
    }

    private static func quickFingerprint(
        for candidate: FileCandidate,
        timeBudget: ActiveScanTimeBudget,
        control: DuplicateFileScanControl
    ) throws -> QuickFingerprint {
        try withValidatedFile(candidate) { handle in
            try checkFileRead(control: control, timeBudget: timeBudget)
            let count = Int(min(Int64(quickReadBytes), candidate.sizeBytes))
            try handle.seek(toOffset: 0)
            let head = try readExactly(count, from: handle)
            try checkFileRead(control: control, timeBudget: timeBudget)
            try handle.seek(toOffset: UInt64(candidate.sizeBytes - Int64(count)))
            let tail = try readExactly(count, from: handle)
            try checkFileRead(control: control, timeBudget: timeBudget)
            return QuickFingerprint(head: head, tail: tail)
        }
    }

    private static func sha256(
        for candidate: FileCandidate,
        timeBudget: ActiveScanTimeBudget,
        control: DuplicateFileScanControl,
        onBytes: (Int) -> Void
    ) throws -> Data {
        try withValidatedFile(candidate) { handle in
            var hasher = SHA256()
            var bytesRead: Int64 = 0
            try handle.seek(toOffset: 0)

            while true {
                try checkFileRead(control: control, timeBudget: timeBudget)
                guard let data = try handle.read(upToCount: hashReadBytes), !data.isEmpty else {
                    break
                }
                bytesRead += Int64(data.count)
                hasher.update(data: data)
                onBytes(data.count)
            }

            guard bytesRead == candidate.sizeBytes else { throw FileReadError.truncated }
            return Data(hasher.finalize())
        }
    }

    private static func checkFileRead(
        control: DuplicateFileScanControl,
        timeBudget: ActiveScanTimeBudget
    ) throws {
        guard timeBudget.waitUntilRunnable(control) else { throw FileReadError.cancelled }
        guard timeBudget.hasTimeRemaining else { throw FileReadError.deadlineReached }
    }

    private static func checkpoint(
        control: DuplicateFileScanControl,
        timeBudget: ActiveScanTimeBudget,
        progress: inout DuplicateFileScanProgress,
        phase: DuplicateFileScanPhase,
        path: String?,
        handler: ProgressHandler?
    ) -> CheckpointResult {
        if control.isPaused {
            publish(&progress, phase: .paused, path: path, handler: handler)
        }
        guard timeBudget.waitUntilRunnable(control) else { return .cancelled }
        guard timeBudget.hasTimeRemaining else { return .timedOut }
        publish(&progress, phase: phase, path: path, handler: handler)
        return .proceed
    }

    private static func publish(
        _ progress: inout DuplicateFileScanProgress,
        phase: DuplicateFileScanPhase,
        path: String?,
        handler: ProgressHandler?
    ) {
        progress.phase = phase
        progress.currentPath = path
        handler?(progress)
    }

    private static func directoryEntry(_ candidate: FileCandidate) -> DirectoryEntry {
        DirectoryEntry(
            name: candidate.name,
            path: candidate.path,
            sizeBytes: candidate.sizeBytes
        )
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count > 0 else { return Data() }
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw FileReadError.truncated
        }
        return data
    }

    private static func withValidatedFile<Value>(
        _ candidate: FileCandidate,
        operation: (FileHandle) throws -> Value
    ) throws -> Value {
        let descriptor = candidate.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw FileReadError.invalidOrChanged }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        guard fileSnapshot(fileDescriptor: descriptor) == candidate.snapshot else {
            throw FileReadError.invalidOrChanged
        }
        let value = try operation(handle)
        guard fileSnapshot(fileDescriptor: descriptor) == candidate.snapshot,
              fileSnapshot(atPath: candidate.path) == candidate.snapshot else {
            throw FileReadError.invalidOrChanged
        }
        return value
    }

    private static func fileSnapshot(atPath path: String) -> FileSnapshot? {
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else { return nil }
        return fileSnapshot(from: metadata)
    }

    private static func fileSnapshot(fileDescriptor: Int32) -> FileSnapshot? {
        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0 else { return nil }
        return fileSnapshot(from: metadata)
    }

    private static func fileSnapshot(from metadata: stat) -> FileSnapshot? {
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            return nil
        }

        return FileSnapshot(
            identity: FileIdentity(
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino)
            ),
            sizeBytes: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private static func rootSkipReason(
        _ path: String,
        excludedPaths: [String],
        fileManager: FileManager
    ) -> DuplicateFileScanSkipReason? {
        if ScanExclusionService.isExcluded(path, excludedPaths: excludedPaths) {
            return .excluded
        }
        if let reason = specialPathSkipReason(path) {
            return reason
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else { return .notDirectory }

        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            return Darwin.errno == EACCES || Darwin.errno == EPERM ? .permissionDenied : .unreadable
        }
        guard (metadata.st_mode & S_IFMT) != S_IFLNK else { return .symbolicLink }

        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        ) else {
            return Darwin.access(path, R_OK | X_OK) == 0 ? .unreadable : .permissionDenied
        }
        if values.isSymbolicLink == true { return .symbolicLink }
        if values.isPackage == true || isKnownPackage(url) { return .package }
        if Darwin.access(path, R_OK | X_OK) != 0 { return .permissionDenied }
        return nil
    }

    private static func directorySkipReason(
        _ url: URL,
        path: String,
        excludedPaths: [String]
    ) -> DuplicateFileScanSkipReason? {
        if ScanExclusionService.isExcluded(path, excludedPaths: excludedPaths) {
            return .excluded
        }
        if let reason = specialPathSkipReason(path) {
            return reason
        }
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        ) else {
            return Darwin.access(path, R_OK | X_OK) == 0 ? .unreadable : .permissionDenied
        }
        if values.isSymbolicLink == true { return .symbolicLink }
        if values.isPackage == true || isKnownPackage(url) { return .package }
        if values.isDirectory != true { return .notDirectory }
        if Darwin.access(path, R_OK | X_OK) != 0 { return .permissionDenied }
        return nil
    }

    private static func specialPathSkipReason(_ path: String) -> DuplicateFileScanSkipReason? {
        let normalized = path.lowercased()
        let pseudoRoots = ["/dev", "/proc", "/sys", "/private/var/run"]
        if pseudoRoots.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) {
            return .pseudoFilesystem
        }
        let components = normalized.split(separator: "/")
        if components.contains("backups.backupdb")
            || components.contains(".timemachine")
            || components.contains(where: { $0.hasSuffix(".backup") }) {
            return .timeMachine
        }
        if components.contains(where: { $0 == "cache" || $0 == "caches" || $0 == ".cache" }) {
            return .policyExcluded
        }
        if shouldSkipPathBeforeResourceLookup(normalized) {
            return .policyExcluded
        }
        return nil
    }

    private static func isKnownPackage(_ url: URL) -> Bool {
        [
            "app", "bundle", "framework", "plugin", "kext",
            "photoslibrary", "musiclibrary", "imovielibrary"
        ].contains(url.pathExtension.lowercased())
    }

    private static func shouldSkipDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "node_modules"
            || name == ".git"
            || name.hasPrefix(".")
            || name == "library"
            || name.contains("cloudstorage")
            || name.contains("onedrive")
            || name.contains("icloud")
    }

    private static func shouldSkipWholeComputerDirectory(
        _ url: URL,
        parentDepth: Int,
        scope: DuplicateFileScanScope
    ) -> Bool {
        guard scope == .wholeComputer, parentDepth == 0 else { return false }
        return [
            "applications", "system", "library", "private", "usr", "bin", "sbin", "opt", "cores"
        ].contains(url.lastPathComponent.lowercased())
    }

    private static func directoryContents(
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
                box.set(
                    .success(
                        try FileManager.default.contentsOfDirectory(
                            at: URL(fileURLWithPath: path),
                            includingPropertiesForKeys: keys,
                            options: options
                        )
                    )
                )
            } catch {
                box.set(.failure(error))
            }
            finished.signal()
        }

        guard finished.wait(timeout: .now() + max(0, timeout)) == .success,
              let result = box.get() else {
            throw DirectoryReadError.timedOut
        }
        return try result.get()
    }

    private static func skipReason(for error: Error) -> DuplicateFileScanSkipReason {
        if error is DirectoryReadError {
            return .timedOut
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain
            && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM)) {
            return .permissionDenied
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
            return .permissionDenied
        }
        return .unreadable
    }

    private static func shouldSkipPathBeforeResourceLookup(_ path: String) -> Bool {
        let lowercasedPath = path.lowercased()
        return lowercasedPath.contains("/library/cloudstorage/")
            || lowercasedPath.contains("/node_modules/")
            || lowercasedPath.contains("/.git/")
            || lowercasedPath.contains("/deriveddata/")
            || lowercasedPath.contains("/coresimulator/")
            || lowercasedPath.contains(".photoslibrary/")
            || lowercasedPath.contains("/onedrive")
            || lowercasedPath.contains("/icloud")
    }
}
