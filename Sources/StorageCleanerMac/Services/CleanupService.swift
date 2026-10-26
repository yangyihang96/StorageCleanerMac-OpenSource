import AppKit
import Darwin
import Foundation
import ServiceManagement

enum CleanupServiceError: LocalizedError {
    case notAllowed(String)
    case outsideAllowedRoots(String)
    case missingPath(String)
    case invalidTrashLocation(String)

    var errorDescription: String? {
        switch self {
        case let .notAllowed(path):
            L10n.text("这个路径不在清理白名单里：\(path)", "This path is not in the cleanup allowlist: \(path)")
        case let .outsideAllowedRoots(path):
            L10n.text("路径超出允许范围：\(path)", "Path is outside the allowed locations: \(path)")
        case let .missingPath(path):
            L10n.text("路径已经不存在：\(path)", "Path no longer exists: \(path)")
        case let .invalidTrashLocation(path):
            L10n.text("只允许清空当前用户废纸篓：\(path)", "Only the current user's Trash can be emptied: \(path)")
        }
    }
}

struct TrashSummary: Equatable, Sendable {
    let itemCount: Int
    let totalBytes: Int64

    static let empty = TrashSummary(itemCount: 0, totalBytes: 0)

    var isEmpty: Bool {
        itemCount == 0
    }
}

/// D101 L5: the Trash as it was when the person asked to empty it. The
/// confirmation shows this list's count and size, and only these entries are
/// deleted; anything put in the Trash afterwards stays.
struct FrozenTrash: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// The entry's own name directly inside the Trash.
        let name: String
        let identity: FileIdentity
        let allocatedBytes: Int64
    }

    let trashURL: URL
    let trashIdentity: FileIdentity
    let entries: [Entry]

    var summary: TrashSummary {
        TrashSummary(
            itemCount: entries.count,
            totalBytes: entries.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        )
    }
}

/// D101 L5: what emptying a frozen Trash did, entry by entry.
struct FrozenTrashEmptyResult: Equatable, Sendable {
    /// Deleted and gone afterwards; bytes are the frozen sizes.
    var deletedCount = 0
    var deletedBytes: Int64 = 0
    /// Refused before anything was deleted: the entry, or the Trash folder,
    /// is not the one frozen.
    var skippedCount = 0
    /// The deletion failed, the entry is still there afterwards, or reading
    /// it back failed, so it is not known to be gone.
    var failedCount = 0
    /// The deleted entries' names, in frozen order: the scan result drops
    /// only these (B-R3).
    var deletedNames: [String] = []
}

struct TrashItemIdentity: Codable, Equatable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let objectType: UInt16
    let birthTimeSeconds: Int64
    let birthTimeNanoseconds: Int64

    static func capture(at url: URL) -> TrashItemIdentity? {
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0 else { return nil }

        return TrashItemIdentity(
            deviceID: UInt64(bitPattern: Int64(metadata.st_dev)),
            fileID: UInt64(metadata.st_ino),
            objectType: UInt16(metadata.st_mode & S_IFMT),
            birthTimeSeconds: Int64(metadata.st_birthtimespec.tv_sec),
            birthTimeNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec)
        )
    }
}

struct TrashMoveRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let originalPath: String
    let resultingItemURL: URL
    let itemIdentity: TrashItemIdentity?
    let movedAt: Date

    init(
        id: UUID = UUID(),
        originalPath: String,
        resultingItemURL: URL,
        movedAt: Date = Date()
    ) {
        self.id = id
        self.originalPath = originalPath
        self.resultingItemURL = resultingItemURL.standardizedFileURL
        itemIdentity = TrashItemIdentity.capture(at: self.resultingItemURL)
        self.movedAt = movedAt
    }

    init(
        id: UUID = UUID(),
        originalPath: String,
        resultingItemURL: URL,
        itemIdentity: TrashItemIdentity?,
        movedAt: Date = Date()
    ) {
        self.id = id
        self.originalPath = originalPath
        self.resultingItemURL = resultingItemURL.standardizedFileURL
        self.itemIdentity = itemIdentity
        self.movedAt = movedAt
    }
}

struct TrashRestoreFailureDetail: Equatable, Sendable {
    let record: TrashMoveRecord
    let reason: String
}

struct TrashRestoreSummary: Equatable, Sendable {
    let restored: [TrashMoveRecord]
    let conflicts: [TrashMoveRecord]
    let missing: [TrashMoveRecord]
    let failed: [TrashRestoreFailureDetail]

    static let empty = TrashRestoreSummary(
        restored: [],
        conflicts: [],
        missing: [],
        failed: []
    )

    var restoredCount: Int { restored.count }
    var conflictCount: Int { conflicts.count }
    var missingCount: Int { missing.count }
    var failedCount: Int { failed.count }
}

struct PartialTrashOperationError: LocalizedError, Sendable {
    let report: CleanReport
    var errorDescription: String? {
        L10n.text("清理未全部完成：已移动 \(ByteFormat.count(report.summary.movedItemCount)) 条路径，请在可恢复操作中查看逐项结果。",
                  "Cleanup was not fully completed: \(ByteFormat.count(report.summary.movedItemCount)) paths moved. Review individual results in Recoverable Operations.")
    }
}

extension CleanReport {
    /// Convert verified receipts without re-capturing a potentially replaced
    /// Trash entry under the same pathname.
    var legacyTrashRecords: [TrashMoveRecord] {
        restorableReceipts.compactMap { receipt in
            guard let identity = receipt.movedIdentity,
                  let birth = identity.creationTimeNanoseconds else { return nil }
            let kind: UInt16
            switch identity.entryKind {
            case .regularFile: kind = UInt16(S_IFREG)
            case .directory: kind = UInt16(S_IFDIR)
            default: return nil
            }
            return TrashMoveRecord(originalPath: receipt.originalPath, resultingItemURL: receipt.resultingItemURL,
                itemIdentity: TrashItemIdentity(deviceID: identity.deviceID, fileID: identity.inode,
                    objectType: kind, birthTimeSeconds: birth / 1_000_000_000,
                    birthTimeNanoseconds: birth % 1_000_000_000), movedAt: receipt.movedAt)
        }
    }
}

enum CleanupService {
    enum SystemSettingsDestination {
        case storage
        case loginItems
        case fullDiskAccess
        case filesAndFolders
        case appManagement
        case privacySecurity
        case gatekeeper
        case fileVault
        case firewall
    }

    static func userTrashURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// D101 L5: records the Trash folder and each entry with the identity the
    /// permanent deleter compares, read without following links. Nil when
    /// there is no Trash folder.
    static func freezeTrash(
        at trashURL: URL = userTrashURL(),
        fileManager: FileManager = .default
    ) throws -> FrozenTrash? {
        try validateTrashURL(trashURL)
        guard let trashIdentity = try FoundationCleanupPermanentDeleter.identity(at: trashURL) else {
            return nil
        }
        // The deleter refuses a Trash reached through a link; so does the freeze.
        guard trashIdentity.entryKind == .directory,
              !PathSafety.containsSymbolicLinkComponent(in: trashURL.path, fileManager: fileManager) else {
            throw CleanupServiceError.invalidTrashLocation(trashURL.path)
        }
        let entries = try trashContents(at: trashURL, fileManager: fileManager).compactMap { url -> FrozenTrash.Entry? in
            // An entry that is gone or unreadable now is not frozen, so it is never deleted.
            guard let identity = try? FoundationCleanupPermanentDeleter.identity(at: url) else { return nil }
            return FrozenTrash.Entry(
                name: url.lastPathComponent,
                identity: identity,
                // Only a real folder is walked; a link's target is never measured.
                allocatedBytes: identity.entryKind == .directory
                    ? allocatedSize(of: url, fileManager: fileManager)
                    : resourceAllocatedSize(url)
            )
        }
        // A Trash folder swapped while it was listed is not the one frozen.
        guard try FoundationCleanupPermanentDeleter.identity(at: trashURL) == trashIdentity else {
            throw CleanupServiceError.invalidTrashLocation(trashURL.path)
        }
        return FrozenTrash(trashURL: trashURL, trashIdentity: trashIdentity, entries: entries)
    }

    /// D101 L5: permanently deletes only the frozen entries, each relative to
    /// the frozen Trash folder (D23's deleter). An entry or a Trash folder
    /// that changed after the freeze is refused and counted as skipped.
    static func emptyFrozenTrash(
        _ frozen: FrozenTrash,
        deleter: any CleanupPermanentDeleting
    ) async -> FrozenTrashEmptyResult {
        var result = FrozenTrashEmptyResult()
        for entry in frozen.entries {
            do {
                try await deleter.removeTrashEntry(CleanupTrashEntryDeletion(
                    trashURL: frozen.trashURL,
                    trashIdentity: frozen.trashIdentity,
                    entryName: entry.name,
                    entryIdentity: entry.identity
                ))
            } catch is CleanupTrashDeletionRefusal {
                result.skippedCount += 1
                continue
            } catch {
                result.failedCount += 1
                continue
            }
            // As in D23: deleted only once the frozen entry is seen to be gone.
            // B-R2: a readback that fails (EACCES, EIO) shows neither.
            let entryURL = frozen.trashURL.appendingPathComponent(entry.name)
            do {
                if try FoundationCleanupPermanentDeleter.identity(at: entryURL) == entry.identity {
                    result.failedCount += 1
                } else {
                    result.deletedCount += 1
                    result.deletedBytes += entry.allocatedBytes
                    result.deletedNames.append(entry.name)
                }
            } catch {
                result.failedCount += 1
            }
        }
        return result
    }

    @discardableResult
    static func moveToTrash(
        _ item: StorageItem,
        allowedPaths: Set<String>,
        excludedPaths: [String] = ScanExclusionService.excludedPaths(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [TrashMoveRecord] {
        // Reject ineligible requests before even registering an operation.
        guard item.canMoveToTrash else { throw CleanupServiceError.notAllowed(item.path) }
        let allowed = Set(allowedPaths.map(PathSafety.lexicalPath))
        for raw in item.trashPaths {
            let path = PathSafety.lexicalPath(raw)
            guard !raw.split(separator: "/").contains(".."), allowed.contains(path),
                  !ScanExclusionService.intersectsExcludedTree(path, excludedPaths: excludedPaths) else {
                throw CleanupServiceError.notAllowed(raw)
            }
            guard PathSafety.isLexicallyInsideHome(path, homeDirectory: homeDirectory) else { throw CleanupServiceError.outsideAllowedRoots(raw) }
            guard !PathSafety.containsSymbolicLinkComponent(in: path) else { throw CleanupServiceError.notAllowed(raw) }
        }
        let report = moveToTrashRecorded(item, allowedPaths: allowedPaths, excludedPaths: excludedPaths, homeDirectory: homeDirectory) { originalURL in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(
                at: originalURL,
                resultingItemURL: &resultingURL
            )
            guard let target = resultingURL as URL? else { throw CleanupMoveError.invalidResult }
            return target
        }
        guard report.outcome == .completed else { throw PartialTrashOperationError(report: report) }
        return report.legacyTrashRecords
    }

    static func moveToTrashRecorded(
        _ item: StorageItem, allowedPaths: Set<String>, excludedPaths: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashItemOperation: (URL) throws -> URL,
        persist: (CleanReport, [String: FileIdentity]) throws -> Void = {
            try CleanupReportJournal.live.checkpoint($0, expectedIdentities: $1)
        }
    ) -> CleanReport {
        let reader = FoundationReadOnlyFileSystem()
        let allowed = Set(allowedPaths.map(PathSafety.lexicalPath))
        let paths = item.trashPaths.isEmpty ? [item.path] : item.trashPaths
        let entries = paths.map { raw in
            let path = PathSafety.lexicalPath(raw)
            let snapshot = try? reader.snapshot(at: URL(fileURLWithPath: path))
            return RecordedTrashOperation.Item(path: path, bytes: snapshot?.logicalSizeBytes ?? 0,
                identity: snapshot?.identity)
        }
        return RecordedTrashOperation.run(items: entries, ruleID: "cleanup.legacy-paths.v1", validate: { entry in
            let path = entry.path
            guard item.canMoveToTrash, path == PathSafety.lexicalPath(path), allowed.contains(path),
                  !paths.contains(where: { $0.split(separator: "/").contains("..") }),
                  !ScanExclusionService.intersectsExcludedTree(path, excludedPaths: excludedPaths),
                  PathSafety.isLexicallyInsideHome(path, homeDirectory: homeDirectory), PathSafety.isInsideHome(path, homeDirectory: homeDirectory),
                  !PathSafety.containsSymbolicLinkComponent(in: path) else {
                throw CleanupServiceError.notAllowed(path)
            }
        }, move: trashItemOperation, metadata: reader, persist: persist)
    }

    @discardableResult
    static func moveToTrash(
        _ item: StorageItem,
        allowedPaths: Set<String>,
        excludedPaths: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashItemOperation: (URL) throws -> URL?
    ) throws -> [TrashMoveRecord] {
        guard item.canMoveToTrash else {
            throw CleanupServiceError.notAllowed(item.path)
        }

        let lexicalAllowedPaths = Set(allowedPaths.map(PathSafety.lexicalPath))
        var moveRecords = [TrashMoveRecord]()
        for rawPath in item.trashPaths {
            let path = PathSafety.lexicalPath(rawPath)

            guard lexicalAllowedPaths.contains(path),
                  !ScanExclusionService.intersectsExcludedTree(path, excludedPaths: excludedPaths) else {
                throw CleanupServiceError.notAllowed(rawPath)
            }

            guard PathSafety.isLexicallyInsideHome(path, homeDirectory: homeDirectory) else {
                throw CleanupServiceError.outsideAllowedRoots(rawPath)
            }

            guard FileManager.default.fileExists(atPath: path) else {
                throw CleanupServiceError.missingPath(rawPath)
            }

            guard !PathSafety.containsSymbolicLinkComponent(in: path) else {
                throw CleanupServiceError.notAllowed(rawPath)
            }

            guard PathSafety.isInsideHome(path, homeDirectory: homeDirectory) else {
                throw CleanupServiceError.outsideAllowedRoots(rawPath)
            }

            guard !PathSafety.containsSymbolicLinkComponent(in: path) else {
                throw CleanupServiceError.notAllowed(rawPath)
            }

            let originalURL = URL(fileURLWithPath: path)
            let resultingItemURL = try trashItemOperation(originalURL)

            // Foundation normally returns the final Trash URL. If it does not,
            // the move still succeeded, so never guess a potentially renamed path.
            if let resultingItemURL, resultingItemURL.isFileURL {
                let record = TrashMoveRecord(
                    originalPath: path,
                    resultingItemURL: resultingItemURL.standardizedFileURL
                )
                // A path alone is not sufficient for safe undo because a
                // different item can later reuse the same Trash name.
                if record.itemIdentity != nil {
                    moveRecords.append(record)
                }
            }
        }

        return moveRecords
    }

    static func restoreFromTrash(
        _ records: [TrashMoveRecord],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> TrashRestoreSummary {
        guard !records.isEmpty else { return .empty }

        let homeRoot = homeDirectory.standardizedFileURL
        let trashRoot = (trashURL ?? userTrashURL(homeDirectory: homeRoot)).standardizedFileURL

        guard trashRoot.lastPathComponent == ".Trash",
              isURL(trashRoot, strictlyInside: homeRoot) else {
            let reason = L10n.text(
                "恢复记录的废纸篓位置无效",
                "The Trash location in the restore record is invalid"
            )
            return TrashRestoreSummary(
                restored: [],
                conflicts: [],
                missing: [],
                failed: records.map { TrashRestoreFailureDetail(record: $0, reason: reason) }
            )
        }

        var restored = [TrashMoveRecord]()
        var conflicts = [TrashMoveRecord]()
        var missing = [TrashMoveRecord]()
        var failed = [TrashRestoreFailureDetail]()
        var seenRecordIDs = Set<UUID>()

        for record in records {
            guard seenRecordIDs.insert(record.id).inserted else {
                failed.append(
                    TrashRestoreFailureDetail(
                        record: record,
                        reason: L10n.text("恢复记录重复", "Duplicate restore record")
                    )
                )
                continue
            }

            guard record.originalPath.hasPrefix("/"),
                  record.resultingItemURL.isFileURL else {
                failed.append(
                    TrashRestoreFailureDetail(
                        record: record,
                        reason: L10n.text("恢复记录不是有效的本地路径", "The restore record is not a valid local path")
                    )
                )
                continue
            }

            let sourceURL = record.resultingItemURL.standardizedFileURL
            let destinationURL = URL(fileURLWithPath: record.originalPath).standardizedFileURL

            guard isURL(sourceURL, strictlyInside: trashRoot) else {
                failed.append(
                    TrashRestoreFailureDetail(
                        record: record,
                        reason: L10n.text("记录的来源不在当前用户废纸篓中", "The recorded source is not in the current user's Trash")
                    )
                )
                continue
            }

            guard isURL(destinationURL, strictlyInside: homeRoot),
                  !isURL(destinationURL, insideOrEqualTo: trashRoot) else {
                failed.append(
                    TrashRestoreFailureDetail(
                        record: record,
                        reason: L10n.text("原路径超出安全恢复范围", "The original path is outside the safe restore area")
                    )
                )
                continue
            }

            guard fileManager.fileExists(atPath: sourceURL.path) else {
                missing.append(record)
                continue
            }

            guard !PathSafety.containsSymbolicLinkComponent(in: sourceURL.path, fileManager: fileManager),
                  isURL(
                    sourceURL.resolvingSymlinksInPath(),
                    strictlyInside: trashRoot.resolvingSymlinksInPath()
                  ) else {
                failed.append(
                    TrashRestoreFailureDetail(
                        record: record,
                        reason: L10n.text("废纸篓来源路径不安全", "The Trash source path is unsafe")
                    )
                )
                continue
            }

            guard let recordedIdentity = record.itemIdentity else {
                failed.append(
                    TrashRestoreFailureDetail(
                        record: record,
                        reason: L10n.text(
                            "恢复记录缺少可验证的文件身份",
                            "The restore record has no verifiable file identity"
                        )
                    )
                )
                continue
            }

            guard TrashItemIdentity.capture(at: sourceURL) == recordedIdentity else {
                failed.append(
                    TrashRestoreFailureDetail(
                        record: record,
                        reason: L10n.text(
                            "废纸篓中的项目已被替换，已拒绝恢复",
                            "The item in Trash was replaced, so restore was refused"
                        )
                    )
                )
                continue
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                conflicts.append(record)
                continue
            }

            let destinationParent = destinationURL.deletingLastPathComponent().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: destinationParent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !PathSafety.containsSymbolicLinkComponent(in: destinationParent.path, fileManager: fileManager),
                  isURL(
                    destinationParent.resolvingSymlinksInPath(),
                    insideOrEqualTo: homeRoot.resolvingSymlinksInPath()
                  ) else {
                failed.append(
                    TrashRestoreFailureDetail(
                        record: record,
                        reason: L10n.text("原路径的上级文件夹不存在或不安全", "The original parent folder is missing or unsafe")
                    )
                )
                continue
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                restored.append(record)
            } catch {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    conflicts.append(record)
                } else if !fileManager.fileExists(atPath: sourceURL.path) {
                    missing.append(record)
                } else {
                    failed.append(
                        TrashRestoreFailureDetail(
                            record: record,
                            reason: error.localizedDescription
                        )
                    )
                }
            }
        }

        return TrashRestoreSummary(
            restored: restored,
            conflicts: conflicts,
            missing: missing,
            failed: failed
        )
    }

    private static func isURL(_ candidate: URL, strictlyInside root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath != rootPath && candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isURL(_ candidate: URL, insideOrEqualTo root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func reveal(_ path: String) throws {
        let normalized = PathSafety.normalizedPath(path)

        guard isAllowedRevealPath(normalized) else {
            throw CleanupServiceError.outsideAllowedRoots(path)
        }

        guard FileManager.default.fileExists(atPath: normalized) else {
            throw CleanupServiceError.missingPath(path)
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: normalized)])
    }

    static func isAllowedRevealPath(_ path: String) -> Bool {
        let normalized = PathSafety.normalizedPath(path)
        return PathSafety.isInsideHome(normalized)
            || PathSafety.isInsideApplications(normalized)
            || PathSafety.isInsideTemporaryRoots(normalized)
    }

    @discardableResult
    static func openStorageSettings() -> Bool {
        openSystemSettings(.storage)
    }

    @discardableResult
    static func openLoginItemsSettings() -> Bool {
        SMAppService.openSystemSettingsLoginItems()
        return true
    }

    @discardableResult
    static func openFullDiskAccessSettings() -> Bool {
        openSystemSettings(.fullDiskAccess)
    }

    @discardableResult
    static func openFilesAndFoldersSettings() -> Bool {
        openSystemSettings(.filesAndFolders)
    }

    static func systemSettingsURL(for destination: SystemSettingsDestination) -> URL? {
        systemSettingsURLs(for: destination).first
    }

    static func openAppManagementSettings() -> Bool {
        openSystemSettings(.appManagement)
    }

    @discardableResult
    static func openSecuritySettings(for check: SystemProtectionCheck) -> Bool {
        switch check {
        case .fileVault: openSystemSettings(.fileVault)
        case .firewall: openSystemSettings(.firewall)
        case .gatekeeper: openSystemSettings(.gatekeeper)
        case .systemIntegrityProtection, .xProtectInstallation: openSystemSettings(.privacySecurity)
        }
    }

    static func systemSettingsURLs(for destination: SystemSettingsDestination) -> [URL] {
        let rawValues: [String]
        switch destination {
        case .storage:
            rawValues = [
                "x-apple.systempreferences:com.apple.settings.Storage",
                "x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension?storage"
            ]
        case .loginItems:
            rawValues = [
                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings"
            ]
        case .fullDiskAccess:
            rawValues = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
            ]
        case .filesAndFolders:
            rawValues = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders"
            ]
        case .appManagement:
            rawValues = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"
            ]
        case .privacySecurity:
            rawValues = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
                "x-apple.systempreferences:com.apple.preference.security?General"
            ]
        case .gatekeeper:
            rawValues = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security",
                "x-apple.systempreferences:com.apple.preference.security?General"
            ]
        case .fileVault:
            rawValues = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault",
                "x-apple.systempreferences:com.apple.preference.security?FDE"
            ]
        case .firewall:
            rawValues = [
                "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
                "x-apple.systempreferences:com.apple.preference.security?Firewall"
            ]
        }
        return rawValues.compactMap(URL.init(string:))
    }

    private static func openSystemSettings(_ destination: SystemSettingsDestination) -> Bool {
        for url in systemSettingsURLs(for: destination) where NSWorkspace.shared.open(url) {
            return true
        }

        let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: settingsApp.path)
            && NSWorkspace.shared.open(settingsApp)
    }

    private static func validateTrashURL(_ trashURL: URL) throws {
        let standardized = trashURL.standardizedFileURL
        guard standardized.lastPathComponent == ".Trash" else {
            throw CleanupServiceError.invalidTrashLocation(trashURL.path)
        }
    }

    private static func trashContents(
        at trashURL: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: trashURL.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ],
            options: []
        )
    }

    private static func allocatedSize(of url: URL, fileManager: FileManager) -> Int64 {
        var total = resourceAllocatedSize(url)

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ],
            options: []
        ) else {
            return total
        }

        for case let childURL as URL in enumerator {
            total += resourceAllocatedSize(childURL)
        }

        return total
    }

    private static func resourceAllocatedSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]) else {
            return 0
        }

        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
