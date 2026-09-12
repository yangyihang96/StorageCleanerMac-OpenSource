import Darwin
import Foundation

enum CleanupRuleSetLoader {
    static func loadBundled() throws -> CleanupRuleSet {
        let bundledURL = Bundle.main.url(
            forResource: "CleanupRules.v2",
            withExtension: "json"
        )
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/CleanupRules.v2.json")
        let url = bundledURL ?? sourceURL
        let bundledRuleSet = try JSONDecoder().decode(
            CleanupRuleSet.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
        let ruleSet = CleanupRuleSet(
            schemaVersion: bundledRuleSet.schemaVersion,
            rulesVersion: bundledRuleSet.rulesVersion,
            rules: DeveloperToolArtifactCatalog.cleanupRules
                + CleanupCoverageCatalog.cleanupRules
                + bundledRuleSet.rules
        )
        try CleanupRuleValidator.validate(ruleSet)
        return ruleSet
    }
}

enum CleanupRuleValidator {
    private static let maximumDepth = 32
    private static let maximumAgeDays = 3_650
    private static let maximumBytes: Int64 = 1_000_000_000_000_000
    private static let safeRoots = [
        "Library/Caches",
        "Library/Developer/Xcode/DerivedData",
        "Library/Developer/Xcode/iOS DeviceSupport",
        ".cache",
        ".npm",
        ".pnpm-store",
        ".gradle",
        ".m2",
        ".cargo",
        "Library/pnpm",
        "go/pkg"
    ]
    private static let forbiddenAutomaticRoots = [
        "Library",
        "Applications",
        "Desktop",
        "Documents",
        "Downloads",
        "Movies",
        "Music",
        "Pictures",
        "Library/Mobile Documents",
        "Library/CloudStorage"
    ]

    static func validate(_ ruleSet: CleanupRuleSet) throws {
        guard ruleSet.schemaVersion == 2 else {
            throw CleanupRuleValidationError.unsupportedSchema(ruleSet.schemaVersion)
        }
        guard !ruleSet.rulesVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !ruleSet.rules.isEmpty else {
            throw CleanupRuleValidationError.invalidRulesVersion
        }

        var ruleIDs = Set<String>()
        var automaticRules = [CleanupRule]()
        for rule in ruleSet.rules {
            guard !rule.id.isEmpty, ruleIDs.insert(rule.id).inserted else {
                throw CleanupRuleValidationError.duplicateRuleID(rule.id)
            }
            guard validRoot(rule.root),
                  rule.exclude.relativePrefixes.allSatisfy(validRelativePath),
                  rule.include.extensions.allSatisfy(validExtension),
                  rule.exclude.extensions.allSatisfy(validExtension) else {
                throw CleanupRuleValidationError.invalidRelativePath(ruleID: rule.id)
            }
            guard validNameMatcher(rule.include.nameMatcher) else {
                throw CleanupRuleValidationError.invalidNameMatcher(ruleID: rule.id)
            }
            guard (rule.developerTool == nil) == (rule.developerArtifactKind == nil) else {
                throw CleanupRuleValidationError.invalidDeveloperArtifactMetadata(ruleID: rule.id)
            }
            if let ownerDisplayName = rule.ownerDisplayName {
                guard rule.developerTool == nil,
                      ownerDisplayName.count <= 80,
                      !ownerDisplayName.isEmpty,
                      ownerDisplayName == ownerDisplayName.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ) else {
                    throw CleanupRuleValidationError.invalidAttributionMetadata(
                        ruleID: rule.id
                    )
                }
            }
            guard rule.maximumDepth >= 0,
                  rule.maximumDepth <= maximumDepth,
                  rule.minimumAgeDays >= 0,
                  rule.minimumAgeDays <= maximumAgeDays,
                  rule.minimumBytes >= 0,
                  rule.minimumBytes <= maximumBytes,
                  rule.selectionPolicyVersion > 0 else {
                throw CleanupRuleValidationError.invalidLimit(ruleID: rule.id)
            }
            guard Set(rule.requiredClosedBundleIDs).count == rule.requiredClosedBundleIDs.count,
                  rule.requiredClosedBundleIDs.allSatisfy(validBundleIdentifier),
                  rule.effectiveIncludedBundleIdentifiers.allSatisfy(validBundleIdentifier) else {
                throw CleanupRuleValidationError.invalidBundleIdentifier(ruleID: rule.id)
            }
            if rule.effectiveCandidateScope == .root {
                guard rule.root.kind == .homeRelative,
                      rule.include.entryKinds.contains(.directory),
                      rule.include.extensions.isEmpty,
                      rule.include.nameMatcher.mode == .any,
                      rule.include.nameMatcher.values.isEmpty,
                      rule.exclude.relativePrefixes.isEmpty,
                      rule.exclude.extensions.isEmpty else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }
            if rule.effectiveCandidateScope == .descendantAggregate {
                guard rule.root.kind == .homeRelative,
                      rule.action == .revealOnly,
                      rule.risk == .reviewOnly,
                      rule.recommendation == .advisoryOnly,
                      rule.defaultSelection == .forbidden,
                      rule.executionEligibility == .advisoryOnly,
                      rule.measurementRequirement == .bestEffort,
                      !rule.allowsManualSelection,
                      rule.include.entryKinds == [.directory],
                      rule.include.extensions.isEmpty,
                      rule.include.nameMatcher.mode == .exact,
                      !rule.include.nameMatcher.values.isEmpty,
                      CleanupCoverageCatalog.permitsDescendantAggregateRule(rule) else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }
            if rule.root.kind == .applicationsDirectory {
                let validInformationalApplicationsRule = rule.risk == .informational
                    && rule.recommendation == .advisoryOnly
                    && rule.defaultSelection == .forbidden
                    && rule.executionEligibility == .advisoryOnly
                    && rule.measurementRequirement == .bestEffort
                    && rule.action == .revealOnly
                    && !rule.allowsManualSelection
                    && rule.cloudPolicy == .metadataOnly
                    && rule.include.entryKinds == [.directory]
                    && rule.include.extensions.isEmpty
                    && rule.include.nameMatcher.mode == .any
                    && rule.include.nameMatcher.values.isEmpty
                    && rule.maximumDepth == maximumDepth
                    && rule.effectiveIncludedBundleIdentifiers.isEmpty
                    && !rule.effectiveRequiresDuplicateBundleIdentifier
                let validProtectedApplicationsRule = rule.risk == .protected
                    && rule.recommendation != .advisoryOnly
                    && rule.defaultSelection == .unselected
                    && rule.executionEligibility == .eligibleAfterProtectedReview
                    && rule.measurementRequirement == .complete
                    && rule.action == .moveToTrashAfterProtectedReview
                    && rule.allowsManualSelection
                    && rule.cloudPolicy == .metadataOnly
                    && rule.include.entryKinds == [.directory]
                    && rule.include.extensions == ["app"]
                    && rule.include.nameMatcher.mode == .any
                    && rule.include.nameMatcher.values.isEmpty
                    && rule.maximumDepth == 0
                    && (rule.effectiveRequiresDuplicateBundleIdentifier
                        == rule.effectiveIncludedBundleIdentifiers.isEmpty)
                guard validInformationalApplicationsRule || validProtectedApplicationsRule else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }

            let automatic = rule.action == .moveToTrash
            let reviewed = rule.action == .moveToTrashAfterReview
            let protectedReviewed = rule.action == .moveToTrashAfterProtectedReview
            if automatic, rule.root.kind != .homeRelative {
                throw CleanupRuleValidationError.forbiddenRoot(ruleID: rule.id)
            }
            if automatic,
               forbiddenAutomaticRoots.contains(where: {
                   rule.root.path == $0 || $0.hasPrefix(rule.root.path + "/")
               }) {
                throw CleanupRuleValidationError.forbiddenRoot(ruleID: rule.id)
            }
            if automatic,
               !safeRoots.contains(where: {
                   rule.root.path == $0 || rule.root.path.hasPrefix($0 + "/")
               }),
               !DeveloperToolArtifactCatalog.permitsAutomaticRule(rule),
               !CleanupCoverageCatalog.permitsAutomaticRule(rule) {
                throw CleanupRuleValidationError.forbiddenRoot(ruleID: rule.id)
            }
            if automatic {
                guard !automaticRules.contains(where: {
                    pathsOverlap($0.root.path, rule.root.path)
                        && !haveDisjointExactNames($0, rule)
                }) else {
                    throw CleanupRuleValidationError.forbiddenRoot(ruleID: rule.id)
                }
                automaticRules.append(rule)
            }

            let validSafeAction = automatic
                && rule.risk == .safe
                && rule.executionEligibility == .eligible
                && rule.measurementRequirement == .complete
                && rule.allowsManualSelection
            let validReviewedAction = reviewed
                && rule.root.kind == .homeRelative
                && rule.risk == .reviewOnly
                && rule.recommendation != .advisoryOnly
                && rule.defaultSelection == .unselected
                && rule.executionEligibility == .eligibleAfterReview
                && rule.measurementRequirement == .complete
                && rule.allowsManualSelection
            let validProtectedReviewedAction = protectedReviewed
                && rule.root.kind == .applicationsDirectory
                && rule.effectiveCandidateScope == .immediateChildren
                && rule.risk == .protected
                && rule.recommendation == .notRecommended
                && rule.defaultSelection == .unselected
                && rule.executionEligibility == .eligibleAfterProtectedReview
                && rule.measurementRequirement == .complete
                && rule.allowsManualSelection
            let validRevealAction = rule.action == .revealOnly
                && rule.risk != .safe
                && rule.recommendation == .advisoryOnly
                && rule.defaultSelection == .forbidden
                && rule.executionEligibility == .advisoryOnly
                && rule.measurementRequirement == .bestEffort
                && !rule.allowsManualSelection
            guard validSafeAction || validReviewedAction
                || validProtectedReviewedAction || validRevealAction else {
                throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
            }
            if rule.defaultSelection == .selected {
                guard rule.risk == .safe,
                      rule.recommendation == .recommended,
                      rule.executionEligibility == .eligible else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }
            if rule.recommendation == .optional || rule.recommendation == .notRecommended {
                guard rule.defaultSelection != .selected else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }
            if validSafeAction {
                guard rule.defaultSelection != .forbidden,
                      rule.recommendation != .advisoryOnly else {
                    throw CleanupRuleValidationError.unsafeActionRiskCombination(ruleID: rule.id)
                }
            }
        }
    }

    private static func validNameMatcher(_ matcher: CleanupNameMatcher) -> Bool {
        let values = matcher.values
        let normalizedValues = values.map(\.precomposedStringWithCanonicalMapping)
        guard Set(normalizedValues).count == normalizedValues.count,
              values.allSatisfy({ value in
                  !value.isEmpty
                      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                      && !value.contains("/")
                      && !value.contains("\0")
                      && !value.contains("*")
                      && !value.contains("?")
                      && !value.contains("[")
                      && !value.contains("]")
              }) else { return false }
        switch matcher.mode {
        case .any:
            return values.isEmpty
        case .exact, .prefix:
            return !values.isEmpty
        }
    }

    private static func haveDisjointExactNames(
        _ lhs: CleanupRule,
        _ rhs: CleanupRule
    ) -> Bool {
        guard lhs.effectiveCandidateScope == .immediateChildren,
              rhs.effectiveCandidateScope == .immediateChildren,
              lhs.include.nameMatcher.mode == .exact,
              rhs.include.nameMatcher.mode == .exact else { return false }
        let lhsPaths = lhs.include.nameMatcher.values.map {
            "\(lhs.root.path)/\($0.precomposedStringWithCanonicalMapping)"
        }
        let rhsPaths = rhs.include.nameMatcher.values.map {
            "\(rhs.root.path)/\($0.precomposedStringWithCanonicalMapping)"
        }
        return lhsPaths.allSatisfy { lhsPath in
            rhsPaths.allSatisfy { !pathsOverlap(lhsPath, $0) }
        }
    }

    private static func validRoot(_ root: CleanupRuleRoot) -> Bool {
        switch root.kind {
        case .homeRelative:
            validRelativePath(root.path)
        case .applicationsDirectory:
            root.path == "/Applications"
        }
    }

    private static func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("//"),
              !path.contains("\0"),
              !path.contains("~"),
              !path.contains("$"),
              !path.contains("*"),
              !path.contains("?"),
              !path.contains("["),
              !path.contains("]") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private static func validExtension(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.lowercased()
            && !value.hasPrefix(".")
            && !value.contains("/")
    }

    private static func validBundleIdentifier(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return components.count >= 2
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && components.allSatisfy {
                !$0.isEmpty && String($0).unicodeScalars.allSatisfy(allowed.contains)
            }
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
}

enum CleanupFileSystemError: Error, Sendable {
    case permissionDenied
    case vanished
    case unreadable
}

protocol ReadOnlyFileSystem: Sendable {
    func snapshot(at url: URL) throws -> FileSnapshot
    func aggregateSnapshot(at url: URL) throws -> FileSnapshot
    func children(of directory: URL) throws -> [URL]
}

extension ReadOnlyFileSystem {
    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        try snapshot(at: url)
    }
}

struct FoundationReadOnlyFileSystem: ReadOnlyFileSystem {
    func snapshot(at url: URL) throws -> FileSnapshot {
        let status = try fileStatus(at: url)
        let kind = entryKind(for: status)

        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .volumeIdentifierKey,
            .volumeIsReadOnlyKey
        ]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            let nsError = error as NSError
            switch nsError.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                throw CleanupFileSystemError.permissionDenied
            case NSFileNoSuchFileError:
                throw CleanupFileSystemError.vanished
            default:
                throw CleanupFileSystemError.unreadable
            }
        }
        let logicalSize = kind == .regularFile
            ? Int64(max(0, values.fileSize ?? Int(status.st_size)))
            : 0
        let allocatedSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        let modificationNanoseconds = values.contentModificationDate.map(nanoseconds)
        let volumeIdentifier = values.volumeIdentifier
            .map { String(describing: $0) }
            ?? String(status.st_dev)
        let isCloudItem = values.isUbiquitousItem == true
        let isCloudPlaceholder = isCloudItem
            && values.ubiquitousItemDownloadingStatus != .current
        var fileSystemStatus = statfs()
        let fileSystemStatusResult = url.withUnsafeFileSystemRepresentation { path in
            statfs(path, &fileSystemStatus)
        }
        let isReadOnlyVolume = fileSystemStatusResult == 0
            ? (fileSystemStatus.f_flags & UInt32(MNT_RDONLY)) != 0
                || values.volumeIsReadOnly == true
            : values.volumeIsReadOnly ?? true

        return FileSnapshot(
            identity: FileIdentity(
                deviceID: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                entryKind: kind,
                creationTimeNanoseconds: timespecNanoseconds(status.st_birthtimespec)
            ),
            standardizedPath: PathSafety.lexicalPath(url.path),
            volumeIdentifier: volumeIdentifier,
            logicalSizeBytes: logicalSize,
            allocatedSizeBytes: allocatedSize.map { Int64(max(0, $0)) },
            modificationTimeNanoseconds: modificationNanoseconds,
            isWritableVolume: !isReadOnlyVolume,
            isCloudItem: isCloudItem,
            isCloudPlaceholder: isCloudPlaceholder,
            hasSymbolicLinkComponent: PathSafety.containsSymbolicLinkComponent(in: url.path)
        )
    }

    func aggregateSnapshot(at url: URL) throws -> FileSnapshot {
        let status = try fileStatus(at: url)
        let kind = entryKind(for: status)
        let allocated = max(Int64(0), Int64(status.st_blocks)) * 512
        return FileSnapshot(
            identity: FileIdentity(
                deviceID: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                entryKind: kind,
                creationTimeNanoseconds: timespecNanoseconds(status.st_birthtimespec)
            ),
            standardizedPath: PathSafety.lexicalPath(url.path),
            volumeIdentifier: String(status.st_dev),
            logicalSizeBytes: kind == .regularFile ? max(0, Int64(status.st_size)) : 0,
            allocatedSizeBytes: allocated,
            modificationTimeNanoseconds: timespecNanoseconds(status.st_mtimespec),
            isWritableVolume: true,
            isCloudItem: false,
            isCloudPlaceholder: false,
            hasSymbolicLinkComponent: kind == .symbolicLink
        )
    }

    func children(of directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            let cocoaError = error as NSError
            if cocoaError.code == NSFileReadNoPermissionError {
                throw CleanupFileSystemError.permissionDenied
            }
            if cocoaError.code == NSFileNoSuchFileError {
                throw CleanupFileSystemError.vanished
            }
            throw CleanupFileSystemError.unreadable
        }
    }

    private func nanoseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    private func fileStatus(at url: URL) throws -> stat {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            switch errno {
            case EACCES, EPERM:
                throw CleanupFileSystemError.permissionDenied
            case ENOENT:
                throw CleanupFileSystemError.vanished
            default:
                throw CleanupFileSystemError.unreadable
            }
        }
        return status
    }

    private func entryKind(for status: stat) -> FileEntryKind {
        switch status.st_mode & S_IFMT {
        case S_IFREG:
            .regularFile
        case S_IFDIR:
            .directory
        case S_IFLNK:
            .symbolicLink
        default:
            .other
        }
    }

    private func timespecNanoseconds(_ value: timespec) -> Int64? {
        guard value.tv_sec > 0 else { return nil }
        return Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
    }
}

typealias CleanupScanProgressHandler = @Sendable (CleanupScanProgress) async -> Void
typealias CleanupScanOperation = @Sendable (
    CleanupScanRequest,
    @escaping CleanupScanProgressHandler
) async throws -> ScanSession

private struct CleanupScanDeadlineExceeded: Error {}

private struct CleanupAggregateMeasurement {
    var logicalSizeBytes: Int64
    var allocatedSizeBytes: Int64?
    var completeness: MeasurementCompleteness
    var latestModificationTimeNanoseconds: Int64? = nil

    mutating func add(_ child: CleanupAggregateMeasurement) {
        logicalSizeBytes = CleanupByteCount.adding(
            child.logicalSizeBytes,
            to: logicalSizeBytes
        )
        if let current = allocatedSizeBytes,
           let childAllocated = child.allocatedSizeBytes {
            allocatedSizeBytes = CleanupByteCount.adding(childAllocated, to: current)
        } else {
            allocatedSizeBytes = nil
        }
        if let childLatest = child.latestModificationTimeNanoseconds {
            latestModificationTimeNanoseconds = max(
                latestModificationTimeNanoseconds ?? childLatest,
                childLatest
            )
        }
        merge(child.completeness)
    }

    mutating func markLowerBound(_ reason: CleanupMeasurementIssue) {
        guard completeness.isComplete else { return }
        completeness = .lowerBound(reason: reason)
    }

    private mutating func merge(_ child: MeasurementCompleteness) {
        guard !child.isComplete else { return }
        switch child {
        case .complete:
            break
        case let .lowerBound(reason), let .failed(reason):
            markLowerBound(reason)
        }
    }
}

private struct CleanupDescendantDiscovery {
    let candidateURLs: [URL]
    let visitedEntryCount: Int
    let visitedDirectoryPaths: Set<String>
    let issues: [ScanIssue]

    var measurementCompleteness: MeasurementCompleteness {
        for issue in issues {
            switch issue.kind {
            case .permissionDenied:
                return .lowerBound(reason: .permissionDenied)
            case .symbolicLinkSkipped:
                return .lowerBound(reason: .symbolicLinkSkipped)
            case .cloudPlaceholderSkipped:
                return .lowerBound(reason: .excludedDescendant)
            case .vanished, .unreadable, .metadataUnavailable,
                 .volumeUnavailable, .outsideAllowedRoot, .timedOut:
                return .lowerBound(reason: .unreadableDescendant)
            case .hardLinkDeduplicated:
                continue
            }
        }
        return .complete
    }
}

actor ReadOnlyCleanupScanner {
    private static let maximumCandidatesPerRule = 40
    private static let installedApplicationsRuleID = "applications.installed-apps"
    private let fileSystem: any ReadOnlyFileSystem
    private let ruleSet: CleanupRuleSet
    private let applicationsURL: URL

    init(
        fileSystem: any ReadOnlyFileSystem,
        ruleSet: CleanupRuleSet,
        applicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) throws {
        try CleanupRuleValidator.validate(ruleSet)
        self.fileSystem = fileSystem
        self.ruleSet = ruleSet
        self.applicationsURL = applicationsURL
    }

    func scan(
        request: CleanupScanRequest,
        progress: @escaping CleanupScanProgressHandler
    ) async throws -> ScanSession {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(request.maximumDuration)
        let sessionID = ScanSessionID()
        let homePath = PathSafety.lexicalPath(request.userHomeURL.path)
        let excludedPaths = request.excludedURLs.map {
            PathSafety.lexicalPath($0.path)
        }
        var issues = [ScanIssue]()
        var permissions = [CleanupPermissionReport]()
        var visitedEntryCount = 0
        var visitedDirectoryPaths = Set<String>()
        var deduplicatedIdentityCount = 0
        var truncatedCandidateCount = 0
        var seenIdentityKeys = Set<String>()
        var completedSubcategories = [CleanupScanSubcategory]()
        var skippedRuleIDs = Set<String>()
        var failedRuleIDs = Set<String>()
        var outcome = ScanOutcome.complete
        var protectedApplicationCandidates = [String: [ScanCandidate]]()

        await progress(progressSnapshot(
            phase: .preparing,
            currentRuleTitle: L10n.text("准备扫描范围", "Preparing scan scope"),
            completedSubcategories: completedSubcategories,
            skippedRuleIDs: skippedRuleIDs,
            failedRuleIDs: failedRuleIDs
        ))

        for rule in ruleSet.rules {
            if Task.isCancelled {
                outcome = .cancelled
                break
            }
            if Date() >= deadline {
                issues.append(ScanIssue(ruleID: nil, path: nil, kind: .timedOut))
                outcome = .partial
                break
            }

            let ruleTitle = CleanupRuleCopy.title(for: rule)
            let rootURL = rootURL(for: rule, request: request)
            let rootPath = PathSafety.lexicalPath(rootURL.path)
            await progress(progressSnapshot(
                phase: .enumerating,
                currentRuleID: rule.id,
                currentRuleTitle: ruleTitle,
                currentPath: rootPath,
                completedSubcategories: completedSubcategories,
                skippedRuleIDs: skippedRuleIDs,
                failedRuleIDs: failedRuleIDs
            ))
            guard isAllowedRoot(
                rule: rule,
                rootPath: rootPath,
                homePath: homePath
            ) else {
                issues.append(ScanIssue(
                    ruleID: rule.id,
                    path: rootPath,
                    kind: .outsideAllowedRoot
                ))
                outcome = .partial
                failedRuleIDs.insert(rule.id)
                completedSubcategories.append(subcategory(rule: rule, candidates: []))
                await progress(progressSnapshot(
                    phase: .enumerating,
                    currentRuleTitle: ruleTitle,
                    completedSubcategories: completedSubcategories,
                    skippedRuleIDs: skippedRuleIDs,
                    failedRuleIDs: failedRuleIDs
                ))
                continue
            }

            if rule.root.kind == .applicationsDirectory,
               rule.risk == .protected {
                completedSubcategories.append(subcategory(
                    rule: rule,
                    candidates: protectedApplicationCandidates[rule.id] ?? []
                ))
                await progress(progressSnapshot(
                    phase: .enumerating,
                    currentRuleTitle: ruleTitle,
                    completedSubcategories: completedSubcategories,
                    skippedRuleIDs: skippedRuleIDs,
                    failedRuleIDs: failedRuleIDs
                ))
                continue
            }

            var ruleCandidates = [ScanCandidate]()
            var reachedDeadline = false
            do {
                let rootSnapshot = try fileSystem.snapshot(at: rootURL)
                visitedDirectoryPaths.insert(rootSnapshot.standardizedPath)
                guard rootSnapshot.identity.entryKind == .directory,
                      !rootSnapshot.hasSymbolicLinkComponent else {
                    permissions.append(CleanupPermissionReport(
                        ruleID: rule.id,
                        path: rootPath,
                        status: .unreadable
                    ))
                    issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: rootPath,
                        kind: .symbolicLinkSkipped
                    ))
                    outcome = .partial
                    failedRuleIDs.insert(rule.id)
                    completedSubcategories.append(subcategory(rule: rule, candidates: []))
                    continue
                }
                guard PathSafety.isContained(
                    rootSnapshot.standardizedPath,
                    in: rootPath,
                    resolvingSymlinks: true
                ) else {
                    permissions.append(CleanupPermissionReport(
                        ruleID: rule.id,
                        path: rootPath,
                        status: .unreadable
                    ))
                    issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: rootPath,
                        kind: .outsideAllowedRoot
                    ))
                    outcome = .partial
                    failedRuleIDs.insert(rule.id)
                    completedSubcategories.append(subcategory(rule: rule, candidates: []))
                    continue
                }
                permissions.append(CleanupPermissionReport(
                    ruleID: rule.id,
                    path: rootPath,
                    status: .readable
                ))

                let candidateURLs: [URL]
                var descendantDiscoveryCompleteness = MeasurementCompleteness.complete
                switch rule.effectiveCandidateScope {
                case .root:
                    candidateURLs = [rootURL]
                case .immediateChildren:
                    candidateURLs = try fileSystem.children(of: rootURL).sorted(by: {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                    })
                case .descendantAggregate:
                    let discovery = try descendantCandidateURLs(
                        rootURL: rootURL,
                        rootPath: rootPath,
                        rule: rule,
                        excludedPaths: excludedPaths,
                        deadline: deadline,
                        referenceDate: startedAt
                    )
                    candidateURLs = discovery.candidateURLs
                    visitedEntryCount += discovery.visitedEntryCount
                    visitedDirectoryPaths.formUnion(
                        discovery.visitedDirectoryPaths
                    )
                    issues.append(contentsOf: discovery.issues)
                    descendantDiscoveryCompleteness = discovery.measurementCompleteness
                    if !descendantDiscoveryCompleteness.isComplete {
                        outcome = .partial
                    }
                }
                for (candidateIndex, childURL) in candidateURLs.enumerated() {
                    try checkDeadline(deadline)
                    if candidateIndex.isMultiple(of: 8) {
                        await progress(progressSnapshot(
                            phase: .enumerating,
                            currentRuleID: rule.id,
                            currentRuleTitle: ruleTitle,
                            currentPath: PathSafety.lexicalPath(childURL.path),
                            currentRuleCompletedItemCount: candidateIndex,
                            currentRuleTotalItemCount: candidateURLs.count,
                            completedSubcategories: completedSubcategories,
                            skippedRuleIDs: skippedRuleIDs,
                            failedRuleIDs: failedRuleIDs
                        ))
                    }
                    if isExcluded(childURL.path, by: excludedPaths) {
                        continue
                    }

                    do {
                        var snapshot = try fileSystem.snapshot(at: childURL)
                        if rule.effectiveCandidateScope != .descendantAggregate {
                            visitedEntryCount += 1
                            if snapshot.identity.entryKind == .directory {
                                visitedDirectoryPaths.insert(snapshot.standardizedPath)
                            }
                        }
                        guard PathSafety.isContained(
                            snapshot.standardizedPath,
                            in: rootPath,
                            resolvingSymlinks: false
                        ) else {
                            issues.append(ScanIssue(
                                ruleID: rule.id,
                                path: snapshot.standardizedPath,
                                kind: .outsideAllowedRoot
                            ))
                            outcome = .partial
                            continue
                        }
                        guard snapshot.identity.entryKind != .symbolicLink,
                              !snapshot.hasSymbolicLinkComponent else {
                            issues.append(ScanIssue(
                                ruleID: rule.id,
                                path: snapshot.standardizedPath,
                                kind: .symbolicLinkSkipped
                            ))
                            continue
                        }
                        guard PathSafety.isContained(
                            snapshot.standardizedPath,
                            in: rootPath,
                            resolvingSymlinks: true
                        ) else {
                            issues.append(ScanIssue(
                                ruleID: rule.id,
                                path: snapshot.standardizedPath,
                                kind: .outsideAllowedRoot
                            ))
                            outcome = .partial
                            continue
                        }
                        guard !rule.action.movesToTrash || snapshot.isWritableVolume else {
                            issues.append(ScanIssue(
                                ruleID: rule.id,
                                path: snapshot.standardizedPath,
                                kind: .volumeUnavailable
                            ))
                            outcome = .partial
                            continue
                        }
                        if shouldSkipCloudItem(snapshot, policy: rule.cloudPolicy) {
                            issues.append(ScanIssue(
                                ruleID: rule.id,
                                path: snapshot.standardizedPath,
                                kind: .cloudPlaceholderSkipped
                            ))
                            continue
                        }
                        if !DeveloperCleanupAgePolicy.applies(to: rule),
                           rule.minimumAgeDays > 0,
                           snapshot.modificationTimeNanoseconds == nil {
                            issues.append(ScanIssue(
                                ruleID: rule.id,
                                path: snapshot.standardizedPath,
                                kind: .metadataUnavailable
                            ))
                            outcome = .partial
                            continue
                        }
                        guard matches(
                            snapshot: snapshot,
                            url: childURL,
                            rule: rule,
                            referenceDate: startedAt
                        ) else {
                            continue
                        }
                        let identityKey = snapshot.identity.deduplicationKey
                        guard !seenIdentityKeys.contains(identityKey) else {
                            deduplicatedIdentityCount += 1
                            issues.append(ScanIssue(
                                ruleID: rule.id,
                                path: snapshot.standardizedPath,
                                kind: .hardLinkDeduplicated
                            ))
                            continue
                        }

                        let aggregate = try aggregateSize(
                            snapshot: snapshot,
                            url: childURL,
                            depth: 0,
                            maximumDepth: rule.maximumDepth,
                            ruleID: rule.id,
                            allowedRootPath: rootPath,
                            excludedPaths: excludedPaths,
                            seenIdentityKeys: &seenIdentityKeys,
                            issues: &issues,
                            visitedEntryCount: &visitedEntryCount,
                            visitedDirectoryPaths: &visitedDirectoryPaths,
                            deduplicatedIdentityCount: &deduplicatedIdentityCount,
                            deadline: deadline
                        )
                        let estimatedSize = aggregate.allocatedSizeBytes
                            ?? aggregate.logicalSizeBytes
                        guard estimatedSize >= rule.minimumBytes else {
                            continue
                        }
                        snapshot = snapshotWithSizes(
                            snapshot,
                            logical: aggregate.logicalSizeBytes,
                            allocated: aggregate.allocatedSizeBytes
                        )
                        ruleCandidates.append(candidate(
                            sessionID: sessionID,
                            rule: rule,
                            rootURL: rootURL,
                            sourceURL: childURL,
                            snapshot: snapshot,
                            measurementCompleteness: aggregate.completeness,
                            latestContentModificationTimeNanoseconds:
                                aggregate.latestModificationTimeNanoseconds,
                            developerInactivityThresholdDays:
                                request.developerInactivityThresholdDays,
                            referenceDate: startedAt
                        ))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch is CleanupScanDeadlineExceeded {
                        throw CleanupScanDeadlineExceeded()
                    } catch {
                        issues.append(ScanIssue(
                            ruleID: rule.id,
                            path: childURL.path,
                            kind: issueKind(for: error)
                        ))
                        outcome = .partial
                    }
                }
                if rule.effectiveCandidateScope == .descendantAggregate {
                    ruleCandidates = aggregateDescendantCandidates(
                        sessionID: sessionID,
                        rule: rule,
                        rootURL: rootURL,
                        rootSnapshot: rootSnapshot,
                        candidates: ruleCandidates,
                        discoveryCompleteness: descendantDiscoveryCompleteness
                    )
                }
            } catch is CancellationError {
                outcome = .cancelled
                skippedRuleIDs.insert(rule.id)
            } catch is CleanupScanDeadlineExceeded {
                issues.append(ScanIssue(ruleID: rule.id, path: rootPath, kind: .timedOut))
                outcome = .partial
                reachedDeadline = true
                failedRuleIDs.insert(rule.id)
            } catch {
                let status = permissionStatus(for: error)
                permissions.removeAll { $0.ruleID == rule.id }
                permissions.append(CleanupPermissionReport(
                    ruleID: rule.id,
                    path: rootPath,
                    status: status
                ))
                if isMissing(error) {
                    skippedRuleIDs.insert(rule.id)
                } else {
                    failedRuleIDs.insert(rule.id)
                    issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: rootPath,
                        kind: issueKind(for: error)
                    ))
                    outcome = .partial
                }
            }

            if rule.id == Self.installedApplicationsRuleID {
                let sortedCandidates = ruleCandidates.sorted(by: candidateSort)
                let cappedCandidates = Array(sortedCandidates.prefix(Self.maximumCandidatesPerRule))
                truncatedCandidateCount += max(0, sortedCandidates.count - cappedCandidates.count)
                let duplicateGroups = duplicateApplicationGroups(in: ruleCandidates)
                var protectedPaths = Set<String>()
                for protectedRule in ruleSet.rules where
                    protectedRule.root.kind == .applicationsDirectory
                        && protectedRule.risk == .protected {
                    let candidates = cappedCandidates.compactMap { candidate -> ScanCandidate? in
                        let path = candidate.snapshot.standardizedPath
                        let bundleID = Bundle(url: candidate.sourceURL)?.bundleIdentifier
                        var evidenceCodes = [String]()
                        if protectedRule.effectiveRequiresDuplicateBundleIdentifier {
                            guard let groupID = duplicateGroups[path] else { return nil }
                            evidenceCodes = [
                                "duplicate-bundle-identifier",
                                "duplicate-bundle-group:\(groupID)",
                            ]
                        } else {
                            guard let bundleID,
                                  protectedRule.effectiveIncludedBundleIdentifiers.contains(bundleID) else {
                                return nil
                            }
                            evidenceCodes = [
                                "approved-application-bundle-identifier",
                                "application-bundle-identifier:\(bundleID)",
                            ]
                        }
                        protectedPaths.insert(path)
                        return self.candidate(
                            sessionID: sessionID,
                            rule: protectedRule,
                            rootURL: rootURL,
                            sourceURL: candidate.sourceURL,
                            snapshot: candidate.snapshot,
                            measurementCompleteness: candidate.measurementCompleteness,
                            evidenceCodes: evidenceCodes
                        )
                    }
                    protectedApplicationCandidates[protectedRule.id] = candidates
                }
                ruleCandidates = cappedCandidates.filter {
                    !protectedPaths.contains($0.snapshot.standardizedPath)
                }
            }

            let sortedCandidates = ruleCandidates.sorted(by: candidateSort)
            let retainedCandidates = Array(sortedCandidates.prefix(Self.maximumCandidatesPerRule))
            if rule.id != Self.installedApplicationsRuleID {
                truncatedCandidateCount += max(0, sortedCandidates.count - retainedCandidates.count)
            }
            completedSubcategories.append(subcategory(
                rule: rule,
                candidates: retainedCandidates
            ))
            await progress(progressSnapshot(
                phase: .enumerating,
                currentRuleTitle: ruleTitle,
                completedSubcategories: completedSubcategories,
                skippedRuleIDs: skippedRuleIDs,
                failedRuleIDs: failedRuleIDs
            ))
            if outcome == .cancelled || reachedDeadline {
                break
            }
        }

        await progress(progressSnapshot(
            phase: .finalizing,
            currentRuleTitle: L10n.text("整理扫描结果", "Finalizing results"),
            completedSubcategories: completedSubcategories,
            skippedRuleIDs: skippedRuleIDs,
            failedRuleIDs: failedRuleIDs
        ))

        let categories = categories(from: completedSubcategories)
        let candidates = categories.flatMap(\.candidates)
        if outcome != .cancelled,
           candidates.contains(where: { !$0.measurementCompleteness.isComplete }) {
            outcome = .partial
        }
        if outcome != .cancelled,
           issues.contains(where: { issue in
               switch issue.kind {
               case .permissionDenied, .vanished, .unreadable,
                    .metadataUnavailable, .volumeUnavailable, .outsideAllowedRoot,
                    .timedOut:
                   return true
               case .symbolicLinkSkipped, .hardLinkDeduplicated,
                    .cloudPlaceholderSkipped:
                   return false
               }
           }) {
            outcome = .partial
        }
        return ScanSession(
            id: sessionID,
            rulesVersion: ruleSet.rulesVersion,
            startedAt: startedAt,
            completedAt: Date(),
            outcome: outcome,
            categories: categories,
            issues: issues,
            permissions: permissions,
            metrics: ScanMetrics(
                visitedEntryCount: visitedEntryCount,
                visitedDirectoryCount: visitedDirectoryPaths.count,
                candidateCount: candidates.count,
                deduplicatedIdentityCount: deduplicatedIdentityCount,
                estimatedCandidateBytes: CleanupByteCount.sum(
                    candidates.map(\.estimatedSizeBytes)
                ),
                completeMeasurementCandidateCount: candidates.filter {
                    $0.measurementCompleteness.isComplete
                }.count,
                lowerBoundMeasurementCandidateCount: candidates.filter {
                    $0.measurementCompleteness.isLowerBound
                }.count,
                failedMeasurementCandidateCount: candidates.filter {
                    $0.measurementCompleteness.isFailed
                }.count,
                permissionFailureCount: issues.filter {
                    $0.kind == .permissionDenied || $0.kind == .unreadable
                }.count,
                cloudSkippedCount: issues.filter {
                    $0.kind == .cloudPlaceholderSkipped
                }.count,
                timedOutRuleCount: Set(issues.compactMap {
                    $0.kind == .timedOut ? $0.ruleID : nil
                }).count,
                truncatedCandidateCount: truncatedCandidateCount,
                duration: Date().timeIntervalSince(startedAt)
            ),
            system: systemSnapshot(homeURL: request.userHomeURL),
            developerInactivityThresholdDays: request.developerInactivityThresholdDays,
            includedCategoryIDs: request.includedCategoryIDs,
            includedRuleIDs: request.includedRuleIDs
        )
    }

    private func descendantCandidateURLs(
        rootURL: URL,
        rootPath: String,
        rule: CleanupRule,
        excludedPaths: [String],
        deadline: Date,
        referenceDate: Date
    ) throws -> CleanupDescendantDiscovery {
        var pending = try fileSystem.children(of: rootURL)
            .sorted(by: {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent
                ) == .orderedDescending
            })
            .map { (url: $0, depth: 1) }
        var candidateURLs = [URL]()
        var visitedEntryCount = 0
        var visitedDirectoryPaths = Set<String>()
        var issues = [ScanIssue]()

        while let current = pending.popLast() {
            try checkDeadline(deadline)
            let currentPath = PathSafety.lexicalPath(current.url.path)
            if isExcluded(currentPath, by: excludedPaths) {
                continue
            }

            do {
                let snapshot = try fileSystem.snapshot(at: current.url)
                visitedEntryCount += 1
                if snapshot.identity.entryKind == .directory {
                    visitedDirectoryPaths.insert(snapshot.standardizedPath)
                }
                guard PathSafety.isContained(
                    snapshot.standardizedPath,
                    in: rootPath,
                    resolvingSymlinks: false
                ) else {
                    issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: snapshot.standardizedPath,
                        kind: .outsideAllowedRoot
                    ))
                    continue
                }
                guard snapshot.identity.entryKind != .symbolicLink,
                      !snapshot.hasSymbolicLinkComponent else {
                    issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: snapshot.standardizedPath,
                        kind: .symbolicLinkSkipped
                    ))
                    continue
                }
                guard PathSafety.isContained(
                    snapshot.standardizedPath,
                    in: rootPath,
                    resolvingSymlinks: true
                ) else {
                    issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: snapshot.standardizedPath,
                        kind: .outsideAllowedRoot
                    ))
                    continue
                }
                if shouldSkipCloudItem(snapshot, policy: rule.cloudPolicy) {
                    issues.append(ScanIssue(
                        ruleID: rule.id,
                        path: snapshot.standardizedPath,
                        kind: .cloudPlaceholderSkipped
                    ))
                    continue
                }
                if matches(
                    snapshot: snapshot,
                    url: current.url,
                    rule: rule,
                    referenceDate: referenceDate
                ) {
                    candidateURLs.append(current.url)
                    continue
                }
                guard snapshot.identity.entryKind == .directory,
                      current.depth < rule.maximumDepth else {
                    continue
                }
                let children = try fileSystem.children(of: current.url)
                    .sorted(by: {
                        $0.lastPathComponent.localizedStandardCompare(
                            $1.lastPathComponent
                        ) == .orderedDescending
                    })
                pending.append(contentsOf: children.map {
                    (url: $0, depth: current.depth + 1)
                })
            } catch is CancellationError {
                throw CancellationError()
            } catch is CleanupScanDeadlineExceeded {
                throw CleanupScanDeadlineExceeded()
            } catch {
                issues.append(ScanIssue(
                    ruleID: rule.id,
                    path: currentPath,
                    kind: issueKind(for: error)
                ))
            }
        }

        return CleanupDescendantDiscovery(
            candidateURLs: candidateURLs,
            visitedEntryCount: visitedEntryCount,
            visitedDirectoryPaths: visitedDirectoryPaths,
            issues: issues
        )
    }

    private func aggregateDescendantCandidates(
        sessionID: ScanSessionID,
        rule: CleanupRule,
        rootURL: URL,
        rootSnapshot: FileSnapshot,
        candidates: [ScanCandidate],
        discoveryCompleteness: MeasurementCompleteness
    ) -> [ScanCandidate] {
        guard !candidates.isEmpty else { return [] }
        var aggregate = CleanupAggregateMeasurement(
            logicalSizeBytes: 0,
            allocatedSizeBytes: 0,
            completeness: .complete
        )
        if !discoveryCompleteness.isComplete {
            switch discoveryCompleteness {
            case .complete:
                break
            case let .lowerBound(reason), let .failed(reason):
                aggregate.markLowerBound(reason)
            }
        }
        for candidate in candidates {
            aggregate.add(CleanupAggregateMeasurement(
                logicalSizeBytes: candidate.snapshot.logicalSizeBytes,
                allocatedSizeBytes: candidate.snapshot.allocatedSizeBytes,
                completeness: candidate.measurementCompleteness,
                latestModificationTimeNanoseconds:
                    candidate.latestContentModificationTimeNanoseconds
            ))
        }
        let aggregateSnapshot = snapshotWithSizes(
            rootSnapshot,
            logical: aggregate.logicalSizeBytes,
            allocated: aggregate.allocatedSizeBytes
        )
        return [candidate(
            sessionID: sessionID,
            rule: rule,
            rootURL: rootURL,
            sourceURL: rootURL,
            snapshot: aggregateSnapshot,
            measurementCompleteness: aggregate.completeness,
            evidenceCodes: [
                "read-only-descendant-aggregate",
                "matched-descendant-count:\(candidates.count)",
            ],
            latestContentModificationTimeNanoseconds:
                aggregate.latestModificationTimeNanoseconds
        )]
    }

    private func rootURL(for rule: CleanupRule, request: CleanupScanRequest) -> URL {
        switch rule.root.kind {
        case .homeRelative:
            request.userHomeURL.appendingPathComponent(rule.root.path, isDirectory: true)
        case .applicationsDirectory:
            applicationsURL
        }
    }

    private func isAllowedRoot(
        rule: CleanupRule,
        rootPath: String,
        homePath: String
    ) -> Bool {
        switch rule.root.kind {
        case .homeRelative:
            PathSafety.isContained(rootPath, in: homePath, resolvingSymlinks: false)
        case .applicationsDirectory:
            rule.root.path == "/Applications"
                && rootPath == PathSafety.lexicalPath(applicationsURL.path)
                && (rule.action == .revealOnly
                    || rule.action == .moveToTrashAfterProtectedReview)
        }
    }

    private func checkDeadline(_ deadline: Date) throws {
        try Task.checkCancellation()
        if Date() >= deadline {
            throw CleanupScanDeadlineExceeded()
        }
    }

    private func candidateSort(_ lhs: ScanCandidate, _ rhs: ScanCandidate) -> Bool {
        if lhs.estimatedSizeBytes == rhs.estimatedSizeBytes {
            return lhs.snapshot.standardizedPath.localizedStandardCompare(
                rhs.snapshot.standardizedPath
            ) == .orderedAscending
        }
        return lhs.estimatedSizeBytes > rhs.estimatedSizeBytes
    }

    private func systemSnapshot(homeURL: URL) -> SystemSnapshot {
        let attributes = (try? FileManager.default.attributesOfFileSystem(forPath: "/")) ?? [:]
        let total = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey])
#if arch(arm64)
        let architecture = "arm64"
#elseif arch(x86_64)
        let architecture = "x86_64"
#else
        let architecture = "unknown"
#endif

        return SystemSnapshot(
            osName: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            build: "",
            arch: architecture,
            user: NSUserName(),
            home: PathSafety.lexicalPath(homeURL.path),
            filesystem: "APFS",
            purgeable: "",
            diskName: volume?.volumeName ?? "Macintosh HD",
            diskTotalBytes: total,
            diskUsedBytes: max(0, total - free),
            diskFreeBytes: max(0, free)
        )
    }

    private func aggregateSize(
        snapshot: FileSnapshot,
        url: URL,
        depth: Int,
        maximumDepth: Int,
        ruleID: String,
        allowedRootPath: String,
        excludedPaths: [String],
        seenIdentityKeys: inout Set<String>,
        issues: inout [ScanIssue],
        visitedEntryCount: inout Int,
        visitedDirectoryPaths: inout Set<String>,
        deduplicatedIdentityCount: inout Int,
        deadline: Date
    ) throws -> CleanupAggregateMeasurement {
        try checkDeadline(deadline)
        guard PathSafety.isContained(
            snapshot.standardizedPath,
            in: allowedRootPath,
            resolvingSymlinks: false
        ), PathSafety.isContained(
            snapshot.standardizedPath,
            in: allowedRootPath,
            resolvingSymlinks: true
        ) else {
            issues.append(ScanIssue(
                ruleID: ruleID,
                path: snapshot.standardizedPath,
                kind: .outsideAllowedRoot
            ))
            return CleanupAggregateMeasurement(
                logicalSizeBytes: 0,
                allocatedSizeBytes: 0,
                completeness: .lowerBound(reason: .unknown),
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }
        let identityKey = snapshot.identity.deduplicationKey
        guard seenIdentityKeys.insert(identityKey).inserted else {
            deduplicatedIdentityCount += 1
            issues.append(ScanIssue(
                ruleID: ruleID,
                path: snapshot.standardizedPath,
                kind: .hardLinkDeduplicated
            ))
            return CleanupAggregateMeasurement(
                logicalSizeBytes: 0,
                allocatedSizeBytes: 0,
                completeness: .complete,
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }
        guard snapshot.identity.entryKind == .directory else {
            let logical = snapshot.logicalSizeBytes > 0
                ? snapshot.logicalSizeBytes
                : snapshot.allocatedSizeBytes ?? 0
            return CleanupAggregateMeasurement(
                logicalSizeBytes: logical,
                allocatedSizeBytes: snapshot.allocatedSizeBytes,
                completeness: .complete,
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }
        guard depth < maximumDepth else {
            return CleanupAggregateMeasurement(
                logicalSizeBytes: max(0, snapshot.logicalSizeBytes),
                allocatedSizeBytes: snapshot.allocatedSizeBytes,
                completeness: .lowerBound(reason: .depthLimitReached),
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }

        let childURLs: [URL]
        do {
            childURLs = try fileSystem.children(of: url)
        } catch {
            issues.append(ScanIssue(
                ruleID: ruleID,
                path: snapshot.standardizedPath,
                kind: issueKind(for: error)
            ))
            return CleanupAggregateMeasurement(
                logicalSizeBytes: 0,
                allocatedSizeBytes: nil,
                completeness: .failed(reason: measurementIssue(for: error)),
                latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
            )
        }

        var measurement = CleanupAggregateMeasurement(
            logicalSizeBytes: 0,
            allocatedSizeBytes: 0,
            completeness: .complete,
            latestModificationTimeNanoseconds: snapshot.modificationTimeNanoseconds
        )
        for childURL in childURLs {
            try checkDeadline(deadline)
            if isExcluded(childURL.path, by: excludedPaths) {
                measurement.markLowerBound(.excludedDescendant)
                continue
            }
            do {
                let child = try fileSystem.aggregateSnapshot(at: childURL)
                visitedEntryCount += 1
                if child.identity.entryKind == .directory {
                    visitedDirectoryPaths.insert(child.standardizedPath)
                }
                guard child.identity.entryKind != .symbolicLink,
                      !child.hasSymbolicLinkComponent else {
                    issues.append(ScanIssue(
                        ruleID: ruleID,
                        path: child.standardizedPath,
                        kind: .symbolicLinkSkipped
                    ))
                    measurement.markLowerBound(.symbolicLinkSkipped)
                    continue
                }
                let childSize = try aggregateSize(
                    snapshot: child,
                    url: childURL,
                    depth: depth + 1,
                    maximumDepth: maximumDepth,
                    ruleID: ruleID,
                    allowedRootPath: allowedRootPath,
                    excludedPaths: excludedPaths,
                    seenIdentityKeys: &seenIdentityKeys,
                    issues: &issues,
                    visitedEntryCount: &visitedEntryCount,
                    visitedDirectoryPaths: &visitedDirectoryPaths,
                    deduplicatedIdentityCount: &deduplicatedIdentityCount,
                    deadline: deadline
                )
                measurement.add(childSize)
            } catch is CancellationError {
                throw CancellationError()
            } catch is CleanupScanDeadlineExceeded {
                throw CleanupScanDeadlineExceeded()
            } catch {
                issues.append(ScanIssue(
                    ruleID: ruleID,
                    path: childURL.path,
                    kind: issueKind(for: error)
                ))
                measurement.markLowerBound(measurementIssue(for: error))
            }
        }
        return measurement
    }

    private func matches(
        snapshot: FileSnapshot,
        url: URL,
        rule: CleanupRule,
        referenceDate: Date
    ) -> Bool {
        guard rule.include.entryKinds.contains(snapshot.identity.entryKind) else {
            return false
        }
        let fileExtension = url.pathExtension.lowercased()
        if !rule.include.extensions.isEmpty,
           !rule.include.extensions.contains(fileExtension) {
            return false
        }
        if !matchesName(url.lastPathComponent, matcher: rule.include.nameMatcher) {
            return false
        }
        if rule.exclude.extensions.contains(fileExtension) {
            return false
        }
        let relativePath = url.lastPathComponent
        if rule.exclude.relativePrefixes.contains(where: {
            relativePath == $0 || relativePath.hasPrefix($0 + "/")
        }) {
            return false
        }
        guard !DeveloperCleanupAgePolicy.applies(to: rule),
              rule.minimumAgeDays > 0 else {
            return true
        }
        guard let modified = snapshot.modificationTimeNanoseconds else { return false }
        let age = referenceDate.timeIntervalSince1970
            - Double(modified) / 1_000_000_000
        return age >= Double(rule.minimumAgeDays) * 86_400
    }

    private func matchesName(
        _ name: String,
        matcher: CleanupNameMatcher
    ) -> Bool {
        let normalizedName = name.precomposedStringWithCanonicalMapping
        switch matcher.mode {
        case .any:
            return true
        case .exact:
            return matcher.values.contains {
                normalizedName == $0.precomposedStringWithCanonicalMapping
            }
        case .prefix:
            return matcher.values.contains {
                normalizedName.hasPrefix($0.precomposedStringWithCanonicalMapping)
            }
        }
    }

    private func isExcluded(_ path: String, by excludedPaths: [String]) -> Bool {
        excludedPaths.contains {
            PathSafety.isContained(path, in: $0, resolvingSymlinks: false)
        }
    }

    private func shouldSkipCloudItem(
        _ snapshot: FileSnapshot,
        policy: CleanupCloudPolicy
    ) -> Bool {
        switch policy {
        case .metadataOnly:
            false
        case .skipPlaceholder:
            snapshot.isCloudPlaceholder
        case .excludeCloudRoots:
            snapshot.isCloudItem
        }
    }

    private func candidate(
        sessionID: ScanSessionID,
        rule: CleanupRule,
        rootURL: URL,
        sourceURL: URL,
        snapshot: FileSnapshot,
        measurementCompleteness: MeasurementCompleteness = .complete,
        evidenceCodes: [String] = [],
        latestContentModificationTimeNanoseconds: Int64? = nil,
        developerInactivityThresholdDays: Int = DeveloperCleanupAgePolicy.defaultThresholdDays,
        referenceDate: Date = Date()
    ) -> ScanCandidate {
        let developerDecision = DeveloperCleanupAgePolicy.decision(
            for: rule,
            latestModificationTimeNanoseconds: latestContentModificationTimeNanoseconds,
            measurementCompleteness: measurementCompleteness,
            referenceDate: referenceDate,
            thresholdDays: developerInactivityThresholdDays
        )
        let reasonCode = developerDecision?.reasonCode ?? rule.reasonKey
        let reason = developerDecision.map {
            DeveloperCleanupAgePolicy.reason(
                for: $0,
                latestModificationTimeNanoseconds: latestContentModificationTimeNanoseconds,
                referenceDate: referenceDate,
                thresholdDays: developerInactivityThresholdDays
            )
        } ?? CleanupRuleCopy.text(for: rule.reasonKey)
        let developerEvidence = developerDecision.map {
            DeveloperCleanupAgePolicy.evidenceCodes(
                for: $0,
                latestModificationTimeNanoseconds:
                    latestContentModificationTimeNanoseconds,
                thresholdDays: developerInactivityThresholdDays
            )
        } ?? []
        return ScanCandidate(
            id: ScanCandidateID(stableKey: [
                rule.id,
                String(rule.selectionPolicyVersion),
                snapshot.standardizedPath,
                snapshot.volumeIdentifier,
                snapshot.identity.deduplicationKey,
                String(snapshot.identity.creationTimeNanoseconds ?? 0),
            ].joined(separator: "\u{0}")),
            sessionID: sessionID,
            ruleID: rule.id,
            ruleSelectionPolicyVersion: rule.selectionPolicyVersion,
            categoryID: rule.categoryID,
            categoryTitle: CleanupRuleCopy.text(for: rule.categoryTitleKey),
            subcategoryTitle: CleanupRuleCopy.title(for: rule),
            sourceURL: sourceURL,
            allowedRootURL: rule.effectiveCandidateScope == .root
                ? rootURL.deletingLastPathComponent()
                : rootURL,
            snapshot: snapshot,
            risk: developerDecision?.risk ?? rule.risk,
            recommendation: CleanupRecommendation(
                level: developerDecision?.recommendation ?? rule.recommendation,
                reasonCode: reasonCode,
                evidenceCodes: [
                    "storage-analyzer-macos-policy",
                    "bundled-rule",
                    "read-only-metadata",
                ] + developerEvidence + evidenceCodes
            ),
            defaultSelection: developerDecision?.defaultSelection ?? rule.defaultSelection,
            executionEligibility: developerDecision?.executionEligibility
                ?? rule.executionEligibility,
            measurementCompleteness: measurementCompleteness,
            isManuallySelectable: developerDecision?.allowsManualSelection
                ?? rule.allowsManualSelection,
            action: developerDecision?.action ?? rule.action,
            requiredClosedBundleIDs: rule.requiredClosedBundleIDs,
            reason: reason,
            latestContentModificationTimeNanoseconds:
                latestContentModificationTimeNanoseconds,
            developerTool: rule.developerTool,
            developerArtifactKind: rule.developerArtifactKind
        )
    }

    private func duplicateApplicationGroups(
        in candidates: [ScanCandidate]
    ) -> [String: String] {
        var candidatesByBundleID = [String: [ScanCandidate]]()
        for candidate in candidates where candidate.sourceURL.pathExtension.lowercased() == "app" {
            guard let bundleID = Bundle(url: candidate.sourceURL)?.bundleIdentifier,
                  !bundleID.isEmpty else { continue }
            candidatesByBundleID[bundleID, default: []].append(candidate)
        }
        return candidatesByBundleID.reduce(into: [:]) { result, entry in
            guard entry.value.count > 1 else { return }
            let groupID = ScanCandidateID(stableKey: entry.key).rawValue.uuidString
            entry.value.forEach { result[$0.snapshot.standardizedPath] = groupID }
        }
    }

    private func subcategory(
        rule: CleanupRule,
        candidates: [ScanCandidate]
    ) -> CleanupScanSubcategory {
        let representative = candidates.first
        return CleanupScanSubcategory(
            id: rule.id,
            title: CleanupRuleCopy.title(for: rule),
            risk: representative?.risk ?? rule.risk,
            recommendation: representative?.recommendation.level ?? rule.recommendation,
            reason: representative?.reason ?? CleanupRuleCopy.text(for: rule.reasonKey),
            candidates: candidates
        )
    }

    private func categories(
        from subcategories: [CleanupScanSubcategory]
    ) -> [CleanupScanCategory] {
        var categoryOrder = [String]()
        var titles = [String: String]()
        var grouped = [String: [CleanupScanSubcategory]]()
        for subcategory in subcategories {
            guard let rule = ruleSet.rules.first(where: { $0.id == subcategory.id }) else {
                continue
            }
            if grouped[rule.categoryID] == nil {
                categoryOrder.append(rule.categoryID)
            }
            titles[rule.categoryID] = CleanupRuleCopy.text(for: rule.categoryTitleKey)
            grouped[rule.categoryID, default: []].append(subcategory)
        }
        return categoryOrder.map {
            CleanupScanCategory(
                id: $0,
                title: titles[$0] ?? $0,
                subcategories: grouped[$0] ?? []
            )
        }
    }

    private func progressSnapshot(
        phase: CleanupScanPhase,
        currentRuleID: String? = nil,
        currentRuleTitle: String,
        currentPath: String? = nil,
        currentRuleCompletedItemCount: Int = 0,
        currentRuleTotalItemCount: Int = 0,
        completedSubcategories: [CleanupScanSubcategory],
        skippedRuleIDs: Set<String> = [],
        failedRuleIDs: Set<String> = []
    ) -> CleanupScanProgress {
        let completedByID = Dictionary(
            uniqueKeysWithValues: completedSubcategories.map { ($0.id, $0) }
        )
        return CleanupScanProgress(
            phase: phase,
            currentRuleID: currentRuleID,
            currentRuleTitle: currentRuleTitle,
            currentPath: currentPath,
            currentRuleCompletedItemCount: currentRuleCompletedItemCount,
            currentRuleTotalItemCount: currentRuleTotalItemCount,
            completedRuleCount: completedSubcategories.count,
            totalRuleCount: ruleSet.rules.count,
            discoveredItemCount: completedSubcategories.reduce(0) {
                $0 + $1.candidates.count
            },
            discoveredBytes: CleanupByteCount.sum(
                completedSubcategories.map(\.discoveredBytes)
            ),
            groups: ruleSet.rules.map { rule in
                let subcategory = completedByID[rule.id]
                let state: CleanupScanRuleState
                if failedRuleIDs.contains(rule.id) {
                    state = .failed
                } else if skippedRuleIDs.contains(rule.id) {
                    state = .skipped
                } else if rule.id == currentRuleID, phase == .enumerating {
                    state = .scanning
                } else if let subcategory {
                    state = subcategory.candidates.isEmpty ? .clean : .found
                } else if phase == .finalizing {
                    state = .skipped
                } else {
                    state = .pending
                }
                return CleanupScanProgress.GroupSummary(
                    id: rule.id,
                    title: CleanupRuleCopy.title(for: rule),
                    itemCount: subcategory?.candidates.count ?? 0,
                    bytes: subcategory?.discoveredBytes ?? 0,
                    risk: subcategory?.risk ?? rule.risk,
                    state: state,
                    currentPath: rule.id == currentRuleID ? currentPath : nil
                )
            }
        )
    }

    private func snapshotWithSizes(
        _ snapshot: FileSnapshot,
        logical: Int64,
        allocated: Int64?
    ) -> FileSnapshot {
        FileSnapshot(
            identity: snapshot.identity,
            standardizedPath: snapshot.standardizedPath,
            volumeIdentifier: snapshot.volumeIdentifier,
            logicalSizeBytes: logical,
            allocatedSizeBytes: allocated,
            modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
            isWritableVolume: snapshot.isWritableVolume,
            isCloudItem: snapshot.isCloudItem,
            isCloudPlaceholder: snapshot.isCloudPlaceholder,
            hasSymbolicLinkComponent: snapshot.hasSymbolicLinkComponent
        )
    }

    private func permissionStatus(for error: Error) -> CleanupPermissionStatus {
        guard let fileSystemError = error as? CleanupFileSystemError else {
            return .unreadable
        }
        switch fileSystemError {
        case .permissionDenied:
            return .permissionDenied
        case .vanished:
            return .missing
        case .unreadable:
            return .unreadable
        }
    }

    private func isMissing(_ error: Error) -> Bool {
        guard let fileSystemError = error as? CleanupFileSystemError else {
            return false
        }
        if case .vanished = fileSystemError {
            return true
        }
        return false
    }

    private func issueKind(for error: Error) -> ScanIssueKind {
        if error is CleanupScanDeadlineExceeded {
            return .timedOut
        }
        guard let fileSystemError = error as? CleanupFileSystemError else {
            return .metadataUnavailable
        }
        switch fileSystemError {
        case .permissionDenied:
            return .permissionDenied
        case .vanished:
            return .vanished
        case .unreadable:
            return .unreadable
        }
    }

    private func measurementIssue(for error: Error) -> CleanupMeasurementIssue {
        guard let fileSystemError = error as? CleanupFileSystemError else {
            return .unknown
        }
        switch fileSystemError {
        case .permissionDenied:
            return .permissionDenied
        case .vanished, .unreadable:
            return .unreadableDescendant
        }
    }
}

enum CleanupRuleCopy {
    static func title(for rule: CleanupRule) -> String {
        if let ownerDisplayName = rule.ownerDisplayName {
            return "\(ownerDisplayName) · \(text(for: rule.titleKey))"
        }
        if let tool = rule.developerTool,
           let kind = rule.developerArtifactKind {
            return "\(tool.displayName) · \(kind.displayName)"
        }
        return text(for: rule.titleKey)
    }

    static func text(for key: String) -> String {
        switch key {
        case "cleanup.category.system":
            L10n.text("系统与应用缓存", "System & App Caches")
        case "cleanup.category.browserCaches":
            L10n.text("浏览器缓存", "Browser Caches")
        case "cleanup.category.applicationCaches":
            L10n.text("应用缓存", "Application Caches")
        case "cleanup.category.mail":
            L10n.text("邮件附件", "Mail Attachments")
        case "cleanup.category.trash":
            L10n.text("废纸篓", "Trash")
        case "cleanup.category.developer":
            L10n.text("开发工具与残留", "Developer Tools & Artifacts")
        case "cleanup.category.downloads":
            L10n.text("下载项目", "Downloads")
        case "cleanup.category.applications":
            L10n.text("已安装应用", "Installed Applications")
        case "cleanup.category.userData":
            L10n.text("应用数据", "Application Data")
        case "cleanup.category.personalFiles":
            L10n.text("个人文件", "Personal Files")
        case "cleanup.rule.userCaches.title":
            L10n.text("用户缓存", "User Caches")
        case "cleanup.rule.userCaches.reason":
            L10n.text(
                "缓存通常可以重建，但其中可能有正在使用或由系统管理的内容；这里只显示归属和体积，不会直接加入清理计划。",
                "Caches are usually rebuildable, but some may be active or system-managed; this only shows ownership and size and does not add them directly to a cleanup plan."
            )
        case "cleanup.rule.browserCache.title":
            L10n.text("浏览器缓存", "Browser Cache")
        case "cleanup.rule.applicationCache.title":
            L10n.text("应用缓存", "Application Cache")
        case "cleanup.rule.developerCache.title":
            L10n.text("开发缓存", "Developer Cache")
        case "cleanup.reason.knownRegenerableCache":
            L10n.text(
                "该目录位于应用的缓存范围并已精确匹配所属软件；关闭软件后可手动清理，首次重新打开或加载内容可能更慢。",
                "This exact cache path is attributed to its owning app. After quitting the app, it can be cleaned manually; the first launch or content load may be slower."
            )
        case "cleanup.rule.mailDownloads.title":
            L10n.text("下载的邮件附件", "Downloaded Mail Attachments")
        case "cleanup.rule.mailLibraryAttachments.title":
            L10n.text("邮件库附件", "Mail Library Attachments")
        case "cleanup.reason.mailAttachments":
            L10n.text(
                "附件与邮件记录关联；这里只读统计和定位，不会直接修改 Mail 数据库或删除附件。请优先在邮件应用中管理。",
                "Attachments are linked to mail records. This scan only measures and reveals them; it does not modify the Mail database or delete attachments. Manage them in Mail first."
            )
        case "cleanup.rule.systemManagedCache.title":
            L10n.text("系统管理缓存", "System-Managed Cache")
        case "cleanup.reason.systemManagedCache":
            L10n.text(
                "该缓存由 macOS 服务持续管理；这里只读统计和定位，不会把系统状态目录直接加入清理计划。",
                "This cache is continuously managed by macOS services. It is measured and revealed only, and is not added directly to a cleanup plan."
            )
        case "cleanup.rule.diagnosticLogs.title":
            L10n.text("诊断日志", "Diagnostic Logs")
        case "cleanup.reason.diagnosticLogs":
            L10n.text(
                "系统诊断记录可能仍用于问题排查；这里只读统计和定位，不会直接删除。",
                "System diagnostics may still be needed for troubleshooting. They are measured and revealed only, not deleted directly."
            )
        case "cleanup.rule.applicationLogs.title":
            L10n.text("应用日志", "Application Logs")
        case "cleanup.reason.applicationLogs":
            L10n.text(
                "应用日志可能包含仍需排查的问题线索；这里只读统计并标明所属软件。",
                "Application logs may contain useful troubleshooting evidence. They are measured read-only and attributed to their app."
            )
        case "cleanup.rule.userTrash.title":
            L10n.text("个人废纸篓", "User Trash")
        case "cleanup.reason.userTrash":
            L10n.text(
                "这里只读统计废纸篓占用；清空属于不可恢复操作，请使用专门的废纸篓确认流程。",
                "This only measures Trash usage. Emptying Trash is irreversible and must use the dedicated confirmation flow."
            )
        case "cleanup.rule.userLogs.title":
            L10n.text("用户日志", "User Logs")
        case "cleanup.rule.userLogs.reason":
            L10n.text(
                "日志可能用于故障排查；确认不再需要后可手动选择。",
                "Logs may be needed for troubleshooting; select them manually only after review."
            )
        case "cleanup.rule.xcodeDerivedData.title":
            L10n.text("Xcode Derived Data", "Xcode Derived Data")
        case "cleanup.rule.xcodeDerivedData.reason":
            L10n.text(
                "Xcode 可重新生成构建派生数据；删除后首次构建会更慢。",
                "Xcode can rebuild derived data; the next build may take longer."
            )
        case "cleanup.rule.xcodeDeviceSupport.title":
            L10n.text("Xcode 设备支持文件", "Xcode Device Support")
        case "cleanup.rule.xcodeDeviceSupport.reason":
            L10n.text(
                "Xcode 可按需重新下载设备支持文件；清理前请退出 Xcode。",
                "Xcode can download device support again; quit Xcode before cleanup."
            )
        case "cleanup.rule.dotCache.title":
            L10n.text("通用开发缓存", "General Developer Cache")
        case "cleanup.rule.npmCache.title":
            L10n.text("npm 缓存", "npm Cache")
        case "cleanup.rule.npxCache.title":
            L10n.text("npm 临时执行缓存（_npx）", "npm Temporary Execution Cache (_npx)")
        case "cleanup.rule.npmContentCache.title":
            L10n.text("npm 内容缓存（_cacache）", "npm Content Cache (_cacache)")
        case "cleanup.rule.homebrewCache.title":
            L10n.text("Homebrew 下载缓存", "Homebrew Download Cache")
        case "cleanup.rule.uvCache.title":
            L10n.text("uv 包缓存", "uv Package Cache")
        case "cleanup.rule.pnpmStore.title":
            L10n.text("pnpm 内容缓存", "pnpm Content Cache")
        case "cleanup.rule.gradleCache.title":
            L10n.text("Gradle 缓存", "Gradle Cache")
        case "cleanup.rule.mavenCache.title":
            L10n.text("Maven 本地仓库", "Maven Local Repository")
        case "cleanup.rule.cargoRegistry.title":
            L10n.text("Cargo Registry 缓存", "Cargo Registry Cache")
        case "cleanup.rule.cargoGit.title":
            L10n.text("Cargo Git 缓存", "Cargo Git Cache")
        case "cleanup.rule.libraryPnpmStore.title":
            L10n.text("pnpm 用户仓库", "pnpm User Store")
        case "cleanup.rule.goModuleCache.title":
            L10n.text("Go 模块缓存", "Go Module Cache")
        case "cleanup.reason.regenerableDeveloperCache":
            L10n.text(
                "开发工具可重新下载或生成这些缓存；清理后下一次构建可能更慢。",
                "Developer tools can download or rebuild this cache; the next build may be slower."
            )
        case "cleanup.reason.developerToolLogs":
            L10n.text(
                "日志可能仍用于排查问题，因此只标明来源并提供 Finder 定位，不会自动加入清理计划。",
                "Logs may still be needed for troubleshooting, so their source is identified and they can be revealed in Finder, but they are not added to a cleanup plan automatically."
            )
        case "cleanup.reason.developerToolState":
            L10n.text(
                "这里可能包含 Agent 会话、检查点或用户产物；只读取文件系统元数据并提供 Finder 定位，不会加入清理计划。",
                "This may contain agent sessions, checkpoints, or user artifacts. Only file-system metadata is read, and it can be revealed in Finder but never added to a cleanup plan."
            )
        case "cleanup.rule.developerToolArtifact.title":
            L10n.text("开发工具残留", "Developer Tool Artifact")
        case "cleanup.rule.coreSimulator.title":
            L10n.text("CoreSimulator 数据", "CoreSimulator Data")
        case "cleanup.rule.coreSimulator.reason":
            L10n.text(
                "模拟器目录可能包含应用测试状态；请先退出 Xcode 与模拟器，并确认这些状态不再需要。",
                "Simulator data may include app test state; quit Xcode and Simulator, then confirm that state is no longer needed."
            )
        case "cleanup.rule.dockerData.title":
            L10n.text("Docker 数据", "Docker Data")
        case "cleanup.rule.dockerData.reason":
            L10n.text(
                "其中可能包含镜像、卷和开发环境状态，应优先使用 Docker 自带管理工具。",
                "This may contain images, volumes, and environment state; use Docker's own management tools."
            )
        case "cleanup.rule.downloadInstallers.title":
            L10n.text("下载的安装包", "Downloaded Installers")
        case "cleanup.rule.downloadInstallers.reason":
            L10n.text(
                "安装包可能是唯一的离线副本；确认应用已安装且不再需要重新安装后再手动选择。",
                "An installer may be the only offline copy; select it manually only after confirming the app is installed and no reinstall copy is needed."
            )
        case "cleanup.rule.downloadLargeItems.title":
            L10n.text("下载目录大项目", "Large Download Items")
        case "cleanup.rule.downloadLargeItems.reason":
            L10n.text(
                "下载内容可能是个人文件或仍在使用的资料；核对后可手动选择。",
                "Downloads may be personal or still needed; select them manually only after review."
            )
        case "cleanup.rule.installedApps.title":
            L10n.text("大型已安装应用", "Large Installed Applications")
        case "cleanup.rule.installedApps.reason":
            L10n.text(
                "不要直接删除应用包或关联数据；请使用应用卸载器或系统提供的卸载入口。",
                "Do not directly delete app bundles or related data; use the app's uninstaller or a system uninstall flow."
            )
        case "cleanup.rule.duplicateInstalledApps.title":
            L10n.text("重复安装的应用", "Duplicate Installed Applications")
        case "cleanup.rule.duplicateInstalledApps.reason":
            L10n.text(
                "检测到相同 Bundle ID 的多个应用；核对版本、用途和备份后，可在额外确认下移入废纸篓。",
                "Multiple apps share the same Bundle ID. After checking versions, purpose, and backups, you may move one to Trash with extra confirmation."
            )
        case "cleanup.rule.largeCreativeApps.title":
            L10n.text("大型视频与创作应用", "Large Video & Creative Apps")
        case "cleanup.rule.largeCreativeApps.reason":
            L10n.text(
                "应用本体不是缓存；确认不再使用并完成备份后，才可逐项移入废纸篓。",
                "App bundles are not caches. Move an app to Trash only after confirming it is unused and required data is backed up."
            )
        case "cleanup.rule.picturesLibrary.title":
            L10n.text("Pictures 图片库", "Pictures Library")
        case "cleanup.rule.picturesLibrary.reason":
            L10n.text(
                "照片与素材可能是唯一副本；请先确认备份，再使用照片应用或 Finder 审查。",
                "Photos and media may be the only copies. Verify backups before reviewing them in Photos or Finder."
            )
        case "cleanup.rule.wechat.title":
            L10n.text("微信沙盒数据", "WeChat Sandbox Data")
        case "cleanup.rule.wechat.reason":
            L10n.text(
                "其中混合聊天记录、媒体和数据库，应优先使用微信内置存储管理。",
                "This mixes chat history, media, and databases; use WeChat's storage manager first."
            )
        case "cleanup.rule.chrome.title":
            L10n.text("Google Chrome 用户数据", "Google Chrome User Data")
        case "cleanup.rule.chrome.reason":
            L10n.text(
                "其中包含 Profile、历史、Cookie、扩展和设置，应优先使用 Chrome 内置清理。",
                "This contains profiles, history, cookies, extensions, and settings; use Chrome's built-in cleanup first."
            )
        case "cleanup.rule.codexSessions.title":
            L10n.text("Codex 会话历史", "Codex Session History")
        case "cleanup.rule.codexSessions.reason":
            L10n.text(
                "这是本地会话和运行记录，不是临时缓存；请先确认保留需求。",
                "This is local session and run history, not temporary cache; confirm retention needs first."
            )
        case "cleanup.rule.egoLite.title":
            L10n.text("ego lite 应用数据与本地模型", "ego lite Data & Local Models")
        case "cleanup.rule.egoLite.reason":
            L10n.text(
                "该目录同时包含本地模型与 Profile，应优先使用应用内管理入口。",
                "This directory mixes local models and profiles; use the app's management controls first."
            )
        case "cleanup.rule.crossover.title":
            L10n.text("CrossOver Bottles 与运行时", "CrossOver Bottles & Runtime")
        case "cleanup.rule.crossover.reason":
            L10n.text(
                "Bottles 可能包含应用、存档和配置，应使用 CrossOver 内置 Bottle 管理。",
                "Bottles may contain apps, saves, and settings; use CrossOver's Bottle manager."
            )
        case "cleanup.rule.applicationSupport.title":
            L10n.text("Application Support", "Application Support")
        case "cleanup.rule.containers.title":
            L10n.text("应用容器", "App Containers")
        case "cleanup.rule.groupContainers.title":
            L10n.text("共享应用容器", "Shared App Containers")
        case "cleanup.reason.manualAppData":
            L10n.text(
                "可能包含登录状态、数据库、下载内容或应用设置；请先确认所属应用和备份。",
                "This may contain sign-in state, databases, downloads, or settings; confirm ownership and backups first."
            )
        case "cleanup.rule.desktopLargeItems.title":
            L10n.text("桌面大项目", "Large Desktop Items")
        case "cleanup.rule.documentsLargeItems.title":
            L10n.text("文稿大项目", "Large Document Items")
        case "cleanup.rule.moviesLargeItems.title":
            L10n.text("影片大项目", "Large Movie Items")
        case "cleanup.rule.musicLargeItems.title":
            L10n.text("音乐大项目", "Large Music Items")
        case "cleanup.rule.picturesLargeItems.title":
            L10n.text("图片大项目", "Large Picture Items")
        case "cleanup.reason.personalData":
            L10n.text(
                "这是个人内容；确认已备份且不再需要后才可手动选择。",
                "This is personal content; select it manually only after confirming a backup and that it is no longer needed."
            )
        default:
            key
        }
    }
}

enum CleanupScanOperations {
    static let live: CleanupScanOperation = { request, progress in
        let loadedRuleSet = try CleanupRuleSetLoader.loadBundled()
        let ruleSet = scopedRuleSet(
            loadedRuleSet,
            includedCategoryIDs: request.includedCategoryIDs,
            includedRuleIDs: request.includedRuleIDs
        )
        let scanner = try ReadOnlyCleanupScanner(
            fileSystem: FoundationReadOnlyFileSystem(),
            ruleSet: ruleSet
        )
        return try await scanner.scan(request: request, progress: progress)
    }

    static func scopedRuleSet(
        _ ruleSet: CleanupRuleSet,
        includedCategoryIDs: Set<String>?,
        includedRuleIDs: Set<String>? = nil
    ) -> CleanupRuleSet {
        guard includedCategoryIDs != nil || includedRuleIDs != nil else { return ruleSet }
        return CleanupRuleSet(
            schemaVersion: ruleSet.schemaVersion,
            rulesVersion: ruleSet.rulesVersion,
            rules: ruleSet.rules.filter { rule in
                (includedCategoryIDs?.contains(rule.categoryID) ?? true)
                    && (includedRuleIDs?.contains(rule.id) ?? true)
            }
        )
    }
}
