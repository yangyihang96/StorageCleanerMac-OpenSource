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

enum CleanupService {
    enum SystemSettingsDestination {
        case storage
        case loginItems
        case fullDiskAccess
        case filesAndFolders
    }

    static func userTrashURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
    }

    static func trashSummary(
        at trashURL: URL = userTrashURL(),
        fileManager: FileManager = .default
    ) throws -> TrashSummary {
        try validateTrashURL(trashURL)
        let contents = try trashContents(at: trashURL, fileManager: fileManager)
        return summary(for: contents, fileManager: fileManager)
    }

    static func emptyUserTrash(
        at trashURL: URL = userTrashURL(),
        fileManager: FileManager = .default
    ) throws -> TrashSummary {
        try validateTrashURL(trashURL)
        guard fileManager.fileExists(atPath: trashURL.path) else {
            return .empty
        }

        let contents = try trashContents(at: trashURL, fileManager: fileManager)
        let removedSummary = summary(for: contents, fileManager: fileManager)

        for url in contents {
            try fileManager.removeItem(at: url)
        }

        return removedSummary
    }

    @discardableResult
    static func moveToTrash(
        _ item: StorageItem,
        allowedPaths: Set<String>,
        excludedPaths: [String] = ScanExclusionService.excludedPaths()
    ) throws -> [TrashMoveRecord] {
        try moveToTrash(
            item,
            allowedPaths: allowedPaths,
            excludedPaths: excludedPaths
        ) { originalURL in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(
                at: originalURL,
                resultingItemURL: &resultingURL
            )
            return resultingURL as URL?
        }
    }

    @discardableResult
    static func moveToTrash(
        _ item: StorageItem,
        allowedPaths: Set<String>,
        excludedPaths: [String],
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

            guard PathSafety.isLexicallyInsideHome(path) else {
                throw CleanupServiceError.outsideAllowedRoots(rawPath)
            }

            guard FileManager.default.fileExists(atPath: path) else {
                throw CleanupServiceError.missingPath(rawPath)
            }

            guard !PathSafety.containsSymbolicLinkComponent(in: path) else {
                throw CleanupServiceError.notAllowed(rawPath)
            }

            guard PathSafety.isInsideHome(path) else {
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

    private static func summary(for urls: [URL], fileManager: FileManager) -> TrashSummary {
        TrashSummary(
            itemCount: urls.count,
            totalBytes: urls.reduce(Int64(0)) { total, url in
                total + allocatedSize(of: url, fileManager: fileManager)
            }
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
