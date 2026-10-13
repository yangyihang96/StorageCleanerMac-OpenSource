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
    static let cloudOnlyExampleLimit = 20

    private static let defaultUserRoots = [
        "~/Downloads",
        "~/Desktop",
        "~/Documents",
        "~/Movies",
        "~/Music",
        "~/Pictures"
    ]

    /// Also File Analysis's system locations (D46).
    static let protectedWholeComputerRoots = [
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

    /// N17: the user's added folders and volumes lead `roots` and are walked
    /// first with this quota of their own, before the default folders get
    /// the configuration's main quota. Optional so configurations and resume
    /// indexes written before it still decode and compare equal.
    struct SelectedRootsPass: Codable, Hashable, Sendable {
        var rootCount: Int
        var maxFilesScanned: Int
        var maxDirectoriesScanned: Int
        var maxScanSeconds: TimeInterval
    }

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
        var selectedRootsPass: SelectedRootsPass?

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
            ),
            selectedRootsPass: SelectedRootsPass? = nil
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
            self.selectedRootsPass = selectedRootsPass
        }

        /// Limits shared by the User Files scope and by the added locations,
        /// which get the same quota again as a pass of their own (N17).
        private static let userFilesFileLimit = 8_000
        private static let userFilesDirectoryLimit = 900
        private static let userFilesSeconds: TimeInterval = 10
        private static let wholeComputerFileLimit = 250_000
        private static let wholeComputerDirectoryLimit = 30_000
        private static let wholeComputerSeconds: TimeInterval = 30

        /// Number of leading roots walked first by the selected-locations pass.
        var selectedRootCount: Int {
            guard let selectedRootsPass else { return 0 }
            return min(max(0, selectedRootsPass.rootCount), roots.count)
        }

        /// N17: only the folders and volumes the user added. With nothing
        /// added the configuration has no roots and the store refuses to scan.
        static func selectedLocations(
            customRoots: [String],
            externalVolumeRoots: [String],
            excludedPaths: [String] = ScanExclusionService.excludedPaths(),
            candidateRules: Set<DuplicateFileCandidateGroup.Rule> = Set(
                DuplicateFileCandidateGroup.Rule.selectableCases
            )
        ) -> Configuration {
            Configuration(
                scope: .selectedLocations,
                roots: mergedRoots(customRoots + externalVolumeRoots),
                excludedPaths: excludedPaths,
                minimumBytes: 0,
                maxFilesScanned: userFilesFileLimit,
                maxDirectoriesScanned: userFilesDirectoryLimit,
                maxDepth: 5,
                maxResults: 120,
                maxScanSeconds: userFilesSeconds,
                directoryReadTimeout: 0.5,
                candidateRules: candidateRules
            )
        }

        /// Added locations come first with a quota of their own, so the six
        /// default folders cannot use it up (N17). A default folder that an
        /// added location contains is left to that location; an added folder
        /// inside a default folder is walked first and skipped by the default
        /// walk, so its files are counted once.
        static func userFiles(
            customRoots: [String] = [],
            externalVolumeRoots: [String] = [],
            excludedPaths: [String] = ScanExclusionService.excludedPaths(),
            candidateRules: Set<DuplicateFileCandidateGroup.Rule> = Set(
                DuplicateFileCandidateGroup.Rule.selectableCases
            )
        ) -> Configuration {
            let selected = mergedRoots(customRoots + externalVolumeRoots)
            let defaults = roots(mergedRoots(defaultUserRoots), outside: selected)
            return Configuration(
                roots: selected + defaults,
                excludedPaths: excludedPaths,
                minimumBytes: 0,
                maxFilesScanned: userFilesFileLimit,
                maxDirectoriesScanned: userFilesDirectoryLimit,
                maxDepth: 5,
                maxResults: 120,
                maxScanSeconds: userFilesSeconds,
                directoryReadTimeout: 0.5,
                candidateRules: candidateRules,
                selectedRootsPass: selected.isEmpty ? nil : SelectedRootsPass(
                    rootCount: selected.count,
                    maxFilesScanned: userFilesFileLimit,
                    maxDirectoriesScanned: userFilesDirectoryLimit,
                    maxScanSeconds: userFilesSeconds
                )
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
            let split = DuplicateFileScanner.safeWholeComputerRoots(
                userDataRoot: userDataRoot,
                customRoots: customRoots,
                externalVolumeRoots: externalVolumeRoots,
                mountedVolumes: mountedVolumes
            )
            let roots = split.selected + split.defaults
            return Configuration(
                scope: .wholeComputer,
                roots: roots,
                excludedPaths: mergedRoots(
                    excludedPaths
                        + DuplicateFileScanner.protectedWholeComputerRoots
                        + DuplicateFileScanner.protectedVolumeSubpaths(for: roots)
                ),
                minimumBytes: 0,
                maxFilesScanned: wholeComputerFileLimit,
                maxDirectoriesScanned: wholeComputerDirectoryLimit,
                maxDepth: 12,
                maxResults: 200,
                maxScanSeconds: wholeComputerSeconds,
                directoryReadTimeout: 0.5,
                candidateRules: candidateRules,
                selectedRootsPass: split.selected.isEmpty ? nil : SelectedRootsPass(
                    rootCount: split.selected.count,
                    maxFilesScanned: wholeComputerFileLimit,
                    maxDirectoriesScanned: wholeComputerDirectoryLimit,
                    maxScanSeconds: wholeComputerSeconds
                )
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

        /// Candidates that are not the same as, or inside, any selected root.
        fileprivate static func roots(_ candidates: [String], outside selected: [String]) -> [String] {
            let selectedPaths = selected.map(PathSafety.normalizedPath)
            return candidates.filter { candidate in
                let path = PathSafety.normalizedPath(candidate)
                return !selectedPaths.contains { isSameOrNested(path, in: $0) }
            }
        }

        fileprivate static func isSameOrNested(_ candidate: String, in parent: String) -> Bool {
            candidate == parent || parent == "/" || candidate.hasPrefix(parent + "/")
        }
    }

    /// Added locations under `/Volumes` or inside the user data root lead the
    /// scope (N17); other added paths stay out of this scope as before.
    private static func safeWholeComputerRoots(
        userDataRoot: String,
        customRoots: [String],
        externalVolumeRoots: [String],
        mountedVolumes: [MountedVolumeMetadata]?
    ) -> (selected: [String], defaults: [String]) {
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
        let selected = Configuration.mergedRoots((customRoots + externalVolumeRoots).filter {
            let normalized = PathSafety.normalizedPath($0)
            let isVolumePath = normalized.hasPrefix("/Volumes/")
            let isUserDataPath = Configuration.isSameOrNested(normalized, in: safeUserRoot)
            return (isVolumePath || isUserDataPath) && specialPathSkipReason(normalized) == nil
        })
        let automaticLocalDataRoots = autoLocalDataVolumeRoots(
            mountedVolumes ?? mountedVolumeMetadata()
        )
        let defaults = Configuration.roots(
            Configuration.mergedRoots([safeUserRoot] + automaticLocalDataRoots),
            outside: selected
        )
        return (selected, defaults)
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
        case unresponsive
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
        /// N17: a discovery pass also stops at its own deadline. Whatever the
        /// selected-locations pass leaves unused stays in the overall budget
        /// for confirming its duplicates after the default folders.
        private var passDeadlineUptime: TimeInterval?

        init(seconds: TimeInterval) {
            deadlineUptime = ProcessInfo.processInfo.systemUptime + seconds
        }

        func beginPass(seconds: TimeInterval) {
            passDeadlineUptime = min(deadlineUptime, ProcessInfo.processInfo.systemUptime + seconds)
        }

        func endPass() {
            passDeadlineUptime = nil
        }

        func waitUntilRunnable(_ control: DuplicateFileScanControl) -> Bool {
            let wait = control.waitUntilRunnable()
            deadlineUptime += wait.pausedDuration
            passDeadlineUptime = passDeadlineUptime.map { $0 + wait.pausedDuration }
            return wait.shouldContinue
        }

        var remainingSeconds: TimeInterval {
            max(0, min(deadlineUptime, passDeadlineUptime ?? deadlineUptime) - ProcessInfo.processInfo.systemUptime)
        }

        var hasTimeRemaining: Bool {
            let now = ProcessInfo.processInfo.systemUptime
            return now < deadlineUptime && passDeadlineUptime.map { now < $0 } ?? true
        }
    }

    private struct PendingDirectory: Codable, Hashable, Sendable {
        let path: String
        let depth: Int
        let rootIndex: Int

        var url: URL { URL(fileURLWithPath: path) }
    }

    /// One discovery pass's place in its breadth-first walk. `directories`
    /// keeps every queued folder; `directories[directoryIndex - 1]` is the
    /// folder whose `remainingEntries` are still to be examined.
    private struct DiscoveryQueue: Equatable {
        var directories: [PendingDirectory] = []
        var directoryIndex = 0
        var remainingEntries: [String]?

        var isExhausted: Bool {
            remainingEntries == nil && directoryIndex >= directories.count
        }
    }

    /// N17: with added locations the walk runs as two passes, each with its
    /// own quota: first the added locations, then the default roots.
    private struct DiscoveryPass {
        let rootIndices: Range<Int>
        let fileBudget: Int
        let directoryBudget: Int
        /// nil for a single-pass scan, which keeps only the overall deadline.
        let seconds: TimeInterval?
    }

    private enum DiscoveryStop {
        case finished
        case cancelled
        case timedOut
        case fileLimit
        case directoryLimit
    }

    private static func discoveryPasses(for configuration: Configuration) -> [DiscoveryPass] {
        let selectedCount = configuration.selectedRootCount
        guard selectedCount > 0, let selected = configuration.selectedRootsPass else {
            return [DiscoveryPass(
                rootIndices: 0..<configuration.roots.count,
                fileBudget: configuration.maxFilesScanned,
                directoryBudget: configuration.maxDirectoriesScanned,
                seconds: nil
            )]
        }
        return [
            DiscoveryPass(
                rootIndices: 0..<selectedCount,
                fileBudget: selected.maxFilesScanned,
                directoryBudget: selected.maxDirectoriesScanned,
                seconds: max(0, selected.maxScanSeconds)
            ),
            DiscoveryPass(
                rootIndices: selectedCount..<configuration.roots.count,
                fileBudget: configuration.maxFilesScanned,
                directoryBudget: configuration.maxDirectoriesScanned,
                seconds: max(0, configuration.maxScanSeconds)
            ),
        ]
    }

    private static func totalScanSeconds(for configuration: Configuration) -> TimeInterval {
        guard configuration.selectedRootCount > 0,
              let selected = configuration.selectedRootsPass else {
            return configuration.maxScanSeconds
        }
        return configuration.maxScanSeconds + max(0, selected.maxScanSeconds)
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

    private struct QuickFingerprint: Hashable, Sendable {
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
        var readUnresponsive = false
    }

    private struct RootCoverageBuilder: Codable {
        let rootPath: String
        var status: DuplicateFileScanRootCoverage.Status = .skipped
        var skipReason: DuplicateFileScanSkipReason?
        var scannedDirectories = 0
        var scannedFiles = 0
        var scannedBytes: Int64 = 0
        var skippedPaths = [DuplicateFileScanSkippedPath]()
        // Optional so resume indexes written before these fields still decode.
        var cloudOnlyFiles: Int?
        var cloudOnlyBytes: Int64?

        mutating func recordSkip(path: String, reason: DuplicateFileScanSkipReason) {
            let skipped = DuplicateFileScanSkippedPath(path: path, reason: reason)
            if skippedPaths.last != skipped {
                skippedPaths.append(skipped)
            }
        }

        /// Counts every cloud-only file but keeps only a few example paths, so
        /// an optimized-storage home folder cannot bloat the saved result.
        mutating func recordCloudOnly(path: String, bytes: Int64) {
            let count = (cloudOnlyFiles ?? 0) + 1
            cloudOnlyFiles = count
            cloudOnlyBytes = (cloudOnlyBytes ?? 0) + max(0, bytes)
            if count <= DuplicateFileScanner.cloudOnlyExampleLimit {
                recordSkip(path: path, reason: .cloudPlaceholder)
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
                skippedPaths: skippedPaths,
                cloudOnlyFiles: cloudOnlyFiles,
                cloudOnlyBytes: cloudOnlyBytes
            )
        }
    }

    private struct ResumeIndex: Codable {
        let version: Int
        let updatedAt: Date
        let configuration: Configuration
        /// The default-roots pass, or the only pass.
        let directories: [PendingDirectory]
        let directoryIndex: Int
        let remainingDirectoryEntries: [String]?
        let candidates: [FileCandidate]
        let coverageBuilders: [RootCoverageBuilder]
        let progress: DuplicateFileScanProgress
        /// N17: the selected-locations pass keeps its own place. Absent for a
        /// single-pass scan, so those indexes keep their earlier format.
        let selectedDirectories: [PendingDirectory]?
        let selectedDirectoryIndex: Int?
        let selectedRemainingDirectoryEntries: [String]?
    }

    private struct ResumedState {
        let queues: [DiscoveryQueue]
        let candidates: [FileCandidate]
        let coverageBuilders: [RootCoverageBuilder]
        let progress: DuplicateFileScanProgress
    }

    private static func encodedResumeIndex(
        configuration: Configuration,
        queues: [DiscoveryQueue],
        candidates: [FileCandidate],
        coverageBuilders: [RootCoverageBuilder],
        progress: DuplicateFileScanProgress
    ) -> Data? {
        guard let last = queues.last else { return nil }
        let selected = queues.count > 1 ? queues.first : nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(
            ResumeIndex(
                version: resumeIndexVersion,
                updatedAt: Date(),
                configuration: configuration,
                directories: last.directories,
                directoryIndex: last.directoryIndex,
                remainingDirectoryEntries: last.remainingEntries,
                candidates: candidates,
                coverageBuilders: coverageBuilders,
                progress: progress,
                selectedDirectories: selected?.directories,
                selectedDirectoryIndex: selected?.directoryIndex,
                selectedRemainingDirectoryEntries: selected?.remainingEntries
            )
        ), data.count <= maximumResumeDataBytes else {
            return nil
        }
        return data
    }

    private static func validatedResumeIndex(
        from data: Data,
        configuration: Configuration
    ) -> ResumedState? {
        let passes = discoveryPasses(for: configuration)
        let directoryBudgets = passes.reduce(0) { $0 + max(0, $1.directoryBudget) }
        let fileBudgets = passes.reduce(0) { $0 + max(0, $1.fileBudget) }
        guard !data.isEmpty,
              data.count <= maximumResumeDataBytes,
              let index = try? JSONDecoder().decode(ResumeIndex.self, from: data),
              index.version == resumeIndexVersion,
              index.configuration == configuration,
              index.coverageBuilders.count == configuration.roots.count,
              index.progress.scannedDirectories >= 0,
              index.progress.scannedDirectories <= Int.max - directoryBudgets,
              index.progress.scannedFiles >= 0,
              index.progress.scannedFiles <= Int.max - fileBudgets,
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

        let mainQueue = DiscoveryQueue(
            directories: index.directories,
            directoryIndex: index.directoryIndex,
            remainingEntries: index.remainingDirectoryEntries
        )
        let queues: [DiscoveryQueue]
        if passes.count > 1 {
            guard let selectedDirectories = index.selectedDirectories,
                  let selectedDirectoryIndex = index.selectedDirectoryIndex else {
                return nil
            }
            queues = [
                DiscoveryQueue(
                    directories: selectedDirectories,
                    directoryIndex: selectedDirectoryIndex,
                    remainingEntries: index.selectedRemainingDirectoryEntries
                ),
                mainQueue,
            ]
        } else {
            guard index.selectedDirectories == nil,
                  index.selectedDirectoryIndex == nil,
                  index.selectedRemainingDirectoryEntries == nil else {
                return nil
            }
            queues = [mainQueue]
        }
        // Each pass may only hold folders below its own roots.
        guard queues.reduce(0, { $0 + $1.directories.count }) <= 1_000_000,
              zip(queues, passes).allSatisfy({ queue, pass in
                  queue.directoryIndex >= 0
                      && queue.directoryIndex <= queue.directories.count
                      && queue.directories.allSatisfy { directory in
                          pass.rootIndices.contains(directory.rootIndex)
                              && directory.depth >= 0
                              && directory.depth <= configuration.maxDepth
                              && PathSafety.isContained(
                                  directory.path,
                                  in: roots[directory.rootIndex],
                                  resolvingSymlinks: false
                              )
                      }
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
        for queue in queues {
            guard let remainingEntries = queue.remainingEntries else { continue }
            guard queue.directoryIndex > 0,
                  !remainingEntries.isEmpty,
                  remainingEntries.count <= 1_000_000 else {
                return nil
            }
            let currentDirectory = queue.directories[queue.directoryIndex - 1]
            let currentDirectoryPath = PathSafety.lexicalPath(currentDirectory.path)
            let queuedDirectoryPaths = Set(queue.directories.map(\.path))
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
        return ResumedState(
            queues: queues,
            candidates: index.candidates,
            coverageBuilders: index.coverageBuilders,
            progress: index.progress
        )
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
        progress progressHandler: ProgressHandler? = nil,
        isCloudPlaceholder: (String) -> Bool = DuplicateFileScanner.isCloudPlaceholder,
        contentReader: GuardedFileContentReader = GuardedFileContentReader()
    ) -> DuplicateFileScanReport {
        // Reading a cloud-only placeholder makes macOS download it inside
        // read(), where neither Cancel nor the time budget can interrupt, and
        // a read-only scan must not fill the disk. This synchronous scan stays
        // on one thread, so refuse that download for the thread and restore
        // the previous policy for whatever task reuses it next.
        let restoreMaterialization = refuseDatalessMaterializationOnThisThread()
        defer { restoreMaterialization() }
        let fileManager = FileManager.default
        let passes = discoveryPasses(for: configuration)
        let timeBudget = ActiveScanTimeBudget(seconds: totalScanSeconds(for: configuration))
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
        var queues = resumed?.queues ?? passes.map { _ in DiscoveryQueue() }
        var candidates = resumed?.candidates ?? []
        var lastResumeIndexData = resumed == nil ? nil : resumeIndexData
        var reachedTimeLimit = false
        var reachedFileLimit = false
        var reachedDirectoryLimit = false
        var cancelled = false

        func publishResumeCheckpointIfNeeded(directoryIndex: Int, force: Bool = false) {
            guard force
                    || directoryIndex.isMultiple(of: resumeCheckpointDirectoryCadence) else {
                return
            }
            guard let data = encodedResumeIndex(
                configuration: configuration,
                queues: queues,
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
                let passIndex = passes.firstIndex { $0.rootIndices.contains(index) } ?? passes.count - 1
                queues[passIndex].directories.append(
                    PendingDirectory(path: rootPath, depth: 0, rootIndex: index)
                )
            }
            if !cancelled, !reachedTimeLimit {
                publishResumeCheckpointIfNeeded(directoryIndex: 0, force: true)
            }
        }

        /// Walks one pass breadth-first until its queue is empty or it reaches
        /// its own file, folder or time limit. Except for Cancel, the queue is
        /// left consistent so a later checkpoint still resumes this pass.
        func discover(_ passIndex: Int, skippingSubtrees skippedSubtrees: [String]) -> DiscoveryStop {
            let fileBudget = max(0, passes[passIndex].fileBudget)
            let directoryBudget = max(0, passes[passIndex].directoryBudget)
            let runStartScannedFiles = progress.scannedFiles
            let runStartScannedDirectories = progress.scannedDirectories

            while !queues[passIndex].isExhausted {
                if progress.scannedFiles - runStartScannedFiles >= fileBudget {
                    return .fileLimit
                }
                if progress.scannedDirectories - runStartScannedDirectories >= directoryBudget {
                    return .directoryLimit
                }

                let isResumingDirectory = queues[passIndex].remainingEntries != nil
                let directory: PendingDirectory
                if isResumingDirectory {
                    directory = queues[passIndex].directories[queues[passIndex].directoryIndex - 1]
                } else {
                    directory = queues[passIndex].directories[queues[passIndex].directoryIndex]
                    queues[passIndex].directoryIndex += 1
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
                    return .cancelled
                case .timedOut:
                    if !isResumingDirectory {
                        queues[passIndex].directoryIndex -= 1
                    }
                    return .timedOut
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
                    queues[passIndex].remainingEntries = nil
                    publishResumeCheckpointIfNeeded(directoryIndex: queues[passIndex].directoryIndex)
                    continue
                }

                let urls: [URL]
                if let remainingEntries = queues[passIndex].remainingEntries {
                    urls = remainingEntries.map { URL(fileURLWithPath: $0) }
                    queues[passIndex].remainingEntries = nil
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
                        publishResumeCheckpointIfNeeded(directoryIndex: queues[passIndex].directoryIndex)
                        continue
                    }
                }

                for (entryIndex, url) in urls.enumerated() {
                    if progress.scannedFiles - runStartScannedFiles >= fileBudget {
                        queues[passIndex].remainingEntries = Array(urls[entryIndex...]).map {
                            PathSafety.lexicalPath($0.path)
                        }
                        return .fileLimit
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
                        return .cancelled
                    case .timedOut:
                        queues[passIndex].remainingEntries = Array(urls[entryIndex...]).map {
                            PathSafety.lexicalPath($0.path)
                        }
                        return .timedOut
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
                        if skippedSubtrees.contains(where: { Configuration.isSameOrNested(path, in: $0) }) {
                            // N17: an added location inside this root. The
                            // selected pass walks it; walking it here again
                            // would count every file in it twice.
                        } else if values.isPackage == true || isKnownPackage(url) {
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
                            queues[passIndex].directories.append(
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
                    if isCloudPlaceholder(path) {
                        coverageBuilders[directory.rootIndex].recordCloudOnly(path: path, bytes: snapshot.sizeBytes)
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
                publishResumeCheckpointIfNeeded(directoryIndex: queues[passIndex].directoryIndex)
            }
            return .finished
        }

        var passStops = [DiscoveryStop?](repeating: nil, count: passes.count)
        for passIndex in passes.indices where !cancelled {
            if let seconds = passes[passIndex].seconds {
                timeBudget.beginPass(seconds: seconds)
            }
            // Added locations the first pass accepted belong to it, also
            // where they sit inside a default root.
            let skippedSubtrees = passIndex == 0 ? [] : queues[0].directories
                .filter { $0.depth == 0 }
                .map { PathSafety.normalizedPath($0.path) }
            let stop = discover(passIndex, skippingSubtrees: skippedSubtrees)
            timeBudget.endPass()
            passStops[passIndex] = stop
            switch stop {
            case .finished: break
            case .cancelled: cancelled = true
            case .timedOut: reachedTimeLimit = true
            case .fileLimit: reachedFileLimit = true
            case .directoryLimit: reachedDirectoryLimit = true
            }
            if passes.count > 1, !cancelled {
                // The next pass checkpoints too; record where this one stopped.
                publishResumeCheckpointIfNeeded(directoryIndex: queues[passIndex].directoryIndex, force: true)
            }
        }

        for passIndex in passes.indices {
            let unfinishedRootReason: DuplicateFileScanSkipReason?
            switch passStops[passIndex] {
            case nil: unfinishedRootReason = cancelled ? .cancelled : nil
            case .finished?: unfinishedRootReason = nil
            case .cancelled?: unfinishedRootReason = .cancelled
            case .timedOut?: unfinishedRootReason = .timeLimit
            case .fileLimit?: unfinishedRootReason = .fileLimit
            case .directoryLimit?: unfinishedRootReason = .directoryLimit
            }
            guard let unfinishedRootReason else { continue }
            for index in passes[passIndex].rootIndices
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
            && queues.allSatisfy(\.isExhausted)
        if discoveryComplete {
            progress.estimatedTotalDirectories = progress.scannedDirectories
            progress.estimatedTotalFiles = progress.scannedFiles
            progress.estimatedTotalBytes = progress.scannedBytes
            publishResumeCheckpointIfNeeded(directoryIndex: 0, force: true)
        }
        if reachedFileLimit || reachedDirectoryLimit {
            publishResumeCheckpointIfNeeded(directoryIndex: 0, force: true)
        }

        // Candidates carried over from a resume index, or evicted to the cloud
        // since discovery, would otherwise fail to read and vanish silently.
        candidates.removeAll { candidate in
            guard isCloudPlaceholder(candidate.path) else { return false }
            let owner = coverageBuilders.indices
                .filter {
                    candidate.path == coverageBuilders[$0].rootPath
                        || candidate.path.hasPrefix(coverageBuilders[$0].rootPath + "/")
                }
                .max { coverageBuilders[$0].rootPath.count < coverageBuilders[$1].rootPath.count }
            if let owner {
                coverageBuilders[owner].recordCloudOnly(path: candidate.path, bytes: candidate.sizeBytes)
            }
            return true
        }

        var confirmation = ConfirmationResult(groups: [], cancelled: false, timedOut: false)
        // One pass ends at the overall deadline. With two, a pass deadline
        // leaves the added locations' unused time for confirming duplicates.
        let mayConfirm = passes.count > 1 ? timeBudget.hasTimeRemaining : !reachedTimeLimit
        if !cancelled && mayConfirm {
            confirmation = confirmedGroups(
                from: candidates,
                timeBudget: timeBudget,
                control: control,
                progress: &progress,
                handler: progressHandler,
                contentReader: contentReader
            )
            cancelled = confirmation.cancelled
            reachedTimeLimit = reachedTimeLimit || confirmation.timedOut
        }

        // N17: results under an added location come first, so the result cap
        // cannot drop them in favour of larger matches in default folders.
        let selectedRoots = configuration.roots
            .prefix(configuration.selectedRootCount)
            .map(PathSafety.normalizedPath)
        func touchesSelectedRoot(_ files: [DirectoryEntry]) -> Bool {
            files.contains { file in
                selectedRoots.contains { Configuration.isSameOrNested(file.path, in: $0) }
            }
        }
        let allExactGroups = selectedFirst(
            confirmation.groups,
            sameRun: { _, _ in true },
            isSelected: { touchesSelectedRoot($0.files) }
        )
        var readUnresponsive = confirmation.readUnresponsive
        let allCandidates = selectedFirst(
            manualCandidates(
                from: candidates,
                exactGroups: allExactGroups,
                rules: configuration.candidateRules,
                timeBudget: timeBudget,
                control: control,
                contentReader: contentReader,
                readTimedOut: &reachedTimeLimit,
                readUnresponsive: &readUnresponsive
            ),
            sameRun: { $0.rule == $1.rule },
            isSelected: { touchesSelectedRoot($0.files) }
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
            reachedResultLimit: reachedResultLimit,
            contentReadUnresponsive: readUnresponsive ? true : nil
        )
        let incompleteSkipReasons: Set<DuplicateFileScanSkipReason> = [
            .permissionDenied, .timedOut, .unreadable, .cloudPlaceholder
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

    /// Stable partition inside each run of neighbouring groups that belong
    /// together (the same candidate rule): selected groups move to the front
    /// of their run, everything else keeps its order.
    private static func selectedFirst<Group>(
        _ groups: [Group],
        sameRun: (Group, Group) -> Bool,
        isSelected: (Group) -> Bool
    ) -> [Group] {
        var result = [Group]()
        result.reserveCapacity(groups.count)
        var run = [Group]()
        func flush() {
            result += run.filter(isSelected)
            result += run.filter { !isSelected($0) }
            run.removeAll(keepingCapacity: true)
        }
        for group in groups {
            if let last = run.last, !sameRun(last, group) {
                flush()
            }
            run.append(group)
        }
        flush()
        return result
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
        handler: ProgressHandler?,
        contentReader: GuardedFileContentReader
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
                        control: control,
                        contentReader: contentReader
                    )
                    quickCandidates.append(QuickCandidate(candidate: candidate, fingerprint: fingerprint))
                } catch FileReadError.cancelled {
                    return ConfirmationResult(groups: matches, cancelled: true, timedOut: false)
                } catch FileReadError.unresponsive {
                    return ConfirmationResult(groups: matches, cancelled: false, timedOut: true, readUnresponsive: true)
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
                            control: control,
                            contentReader: contentReader
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
                    } catch FileReadError.unresponsive {
                        return ConfirmationResult(groups: matches, cancelled: false, timedOut: true, readUnresponsive: true)
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
        control: DuplicateFileScanControl,
        contentReader: GuardedFileContentReader,
        readTimedOut: inout Bool,
        readUnresponsive: inout Bool
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
                control: control,
                contentReader: contentReader,
                readTimedOut: &readTimedOut,
                readUnresponsive: &readUnresponsive
            )
            : []
        return (metadataGroups + imageGroups).sorted {
            if $0.rule != $1.rule {
                // The dedicated Similar Photos route shares this result cap.
                // Reserve its visible candidates before broad metadata matches.
                if $0.rule == .similarImage { return true }
                if $1.rule == .similarImage { return false }
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

    private static let imageCandidateExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    private static func similarImageCandidates(
        from candidates: [FileCandidate],
        exactRepresentativeByPath: [String: String],
        timeBudget: ActiveScanTimeBudget,
        control: DuplicateFileScanControl,
        contentReader: GuardedFileContentReader,
        readTimedOut: inout Bool,
        readUnresponsive: inout Bool
    ) -> [DuplicateFileCandidateGroup] {
        var seenIdentities = Set<FileIdentity>()
        let reviewCandidates = candidates
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .filter { imageCandidateExtensions.contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }
            .filter { seenIdentities.insert($0.snapshot.identity).inserted }
            .filter { candidate in
                exactRepresentativeByPath[candidate.path].map { $0 == candidate.path } ?? true
            }

        var analyzed: [(file: FileCandidate, signature: ImageSimilaritySignature)] = []
        for candidate in reviewCandidates {
            do {
                try checkFileRead(control: control, timeBudget: timeBudget)
                guard let signature = try imageSimilaritySignature(for: candidate, timeBudget: timeBudget, control: control, contentReader: contentReader) else { continue }
                analyzed.append((candidate, signature))
            } catch FileReadError.cancelled {
                break
            } catch FileReadError.unresponsive {
                readUnresponsive = true
                readTimedOut = true
                break
            } catch FileReadError.deadlineReached {
                readTimedOut = true
                break
            } catch {
                continue
            }
        }

        var remaining = [Bool](repeating: true, count: analyzed.count)
        var groups: [DuplicateFileCandidateGroup] = []
        for seedIndex in analyzed.indices where remaining[seedIndex] {
            do {
                try checkFileRead(control: control, timeBudget: timeBudget)
            } catch {
                break
            }
            remaining[seedIndex] = false
            var matches: [Int] = []
            for candidateIndex in analyzed.indices where remaining[candidateIndex] {
                if candidateIndex.isMultiple(of: 128) {
                    do {
                        try checkFileRead(control: control, timeBudget: timeBudget)
                    } catch {
                        return groups
                    }
                }
                if ImageSimilarity.score(
                    analyzed[seedIndex].signature,
                    analyzed[candidateIndex].signature
                ) != nil {
                    matches.append(candidateIndex)
                }
            }
            guard !matches.isEmpty else { continue }
            for index in matches {
                remaining[index] = false
            }
            let seedPathHash = SHA256.hash(
                data: Data(analyzed[seedIndex].file.path.utf8)
            ).prefix(8).map { String(format: "%02x", $0) }.joined()
            groups.append(DuplicateFileCandidateGroup(
                id: "candidate|similarImage|\(seedPathHash)|\(analyzed[seedIndex].signature.stableID)",
                files: ([seedIndex] + matches).map { directoryEntry(analyzed[$0].file) },
                rule: .similarImage
            ))
        }
        return groups
    }

    private static func imageSimilaritySignature(
        for candidate: FileCandidate,
        timeBudget: ActiveScanTimeBudget,
        control: DuplicateFileScanControl,
        contentReader: GuardedFileContentReader
    ) throws -> ImageSimilaritySignature? {
        try withValidatedFile(candidate, timeBudget: timeBudget, control: control, contentReader: contentReader) { handle, readControl in
            let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(handle.fileDescriptor)")
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(descriptorURL as CFURL, sourceOptions) else {
                return nil
            }
            try readControl.check()
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
            return ImageSimilarity.signature(from: image)
        }
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
        control: DuplicateFileScanControl,
        contentReader: GuardedFileContentReader
    ) throws -> QuickFingerprint {
        try withValidatedFile(candidate, timeBudget: timeBudget, control: control, contentReader: contentReader) { handle, readControl in
            let count = Int(min(Int64(quickReadBytes), candidate.sizeBytes))
            try handle.seek(toOffset: 0)
            let head = try readExactly(count, from: handle)
            try readControl.check()
            try handle.seek(toOffset: UInt64(candidate.sizeBytes - Int64(count)))
            let tail = try readExactly(count, from: handle)
            return QuickFingerprint(head: head, tail: tail)
        }
    }

    private static func sha256(
        for candidate: FileCandidate,
        timeBudget: ActiveScanTimeBudget,
        control: DuplicateFileScanControl,
        contentReader: GuardedFileContentReader,
        onBytes: (Int) -> Void
    ) throws -> Data {
        var reader = contentReader
        let cancelled = { control.isCancelled }
        do {
            try checkFileRead(control: control, timeBudget: timeBudget)
            reader.timeout = min(contentReader.timeout, timeBudget.remainingSeconds)
            let file = try reader.open(URL(fileURLWithPath: candidate.path), isCancelled: cancelled)
            let snapshot = file.snapshot
            guard snapshot.device == Int32(truncatingIfNeeded: candidate.snapshot.identity.device),
                  snapshot.inode == candidate.snapshot.identity.inode,
                  snapshot.size == candidate.snapshot.sizeBytes,
                  snapshot.modifiedSeconds == candidate.snapshot.modificationSeconds,
                  snapshot.modifiedNanoseconds == candidate.snapshot.modificationNanoseconds,
                  snapshot.changedSeconds == candidate.snapshot.changeSeconds,
                  snapshot.changedNanoseconds == candidate.snapshot.changeNanoseconds else {
                throw FileReadError.invalidOrChanged
            }
            var hasher = SHA256()
            var bytesRead: Int64 = 0
            while true {
                try checkFileRead(control: control, timeBudget: timeBudget)
                reader.timeout = min(contentReader.timeout, timeBudget.remainingSeconds)
                let data = try reader.readChunk(file, count: hashReadBytes, isCancelled: cancelled)
                if data.isEmpty { break }
                bytesRead += Int64(data.count)
                hasher.update(data: data)
                onBytes(data.count)
            }
            guard bytesRead == candidate.sizeBytes else { throw FileReadError.truncated }
            return Data(hasher.finalize())
        } catch is CancellationError {
            throw FileReadError.cancelled
        } catch FileContentReadError.timedOut, FileContentReadError.busy {
            throw timeBudget.hasTimeRemaining ? FileReadError.unresponsive : FileReadError.deadlineReached
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
            sizeBytes: candidate.sizeBytes,
            modifiedAt: Date(timeIntervalSince1970: Double(candidate.snapshot.modificationSeconds)
                + Double(candidate.snapshot.modificationNanoseconds) / 1_000_000_000)
        )
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count > 0 else { return Data() }
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw FileReadError.truncated
        }
        return data
    }

    private static func withValidatedFile<Value: Sendable>(
        _ candidate: FileCandidate,
        timeBudget: ActiveScanTimeBudget,
        control: DuplicateFileScanControl,
        contentReader: GuardedFileContentReader,
        operation: @escaping @Sendable (FileHandle, FileContentReadPool.Control) throws -> Value
    ) throws -> Value {
        try checkFileRead(control: control, timeBudget: timeBudget)
        var reader = contentReader
        reader.timeout = min(contentReader.timeout, timeBudget.remainingSeconds)
        do {
            return try reader.withFile(URL(fileURLWithPath: candidate.path), isCancelled: { control.isCancelled }) { file, readControl in
                guard fileSnapshot(fileDescriptor: file.handle.fileDescriptor) == candidate.snapshot else {
                    throw FileReadError.invalidOrChanged
                }
                try readControl.check()
                let value = try operation(file.handle, readControl)
                guard fileSnapshot(fileDescriptor: file.handle.fileDescriptor) == candidate.snapshot,
                      fileSnapshot(atPath: candidate.path) == candidate.snapshot else {
                    throw FileReadError.invalidOrChanged
                }
                return value
            }
        } catch is CancellationError {
            throw FileReadError.cancelled
        } catch FileContentReadError.timedOut, FileContentReadError.busy {
            throw timeBudget.hasTimeRemaining ? FileReadError.unresponsive : FileReadError.deadlineReached
        }
    }

    // Compatibility entry points for 2c callers/tests. The implementation now
    // lives with the other content readers, not in a second parallel policy.
    static func refuseDatalessMaterializationOnThisThread() -> () -> Void {
        (try? FileContentReadGuard.refuseMaterializationOnThisThread()) ?? {}
    }

    static func isCloudPlaceholder(_ path: String) -> Bool {
        FileContentReadGuard.isCloudPlaceholder(path)
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
            // A cloud-only folder fails fast instead of downloading its listing.
            let restoreMaterialization = refuseDatalessMaterializationOnThisThread()
            defer { restoreMaterialization() }
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
        if UninstallErrorEvidence.chain(error).contains(where: {
            $0.domain == NSPOSIXErrorDomain && $0.code == Int(EDEADLK)
        }) {
            return .cloudPlaceholder
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
