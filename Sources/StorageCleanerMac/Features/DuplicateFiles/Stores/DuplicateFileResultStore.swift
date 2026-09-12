import Darwin
import Foundation

enum DuplicateFileResultStoreError: Error, Equatable {
    case invalidData
    case unsafeStoragePath
    case invalidResult
    case tooManyItems
}

/// Persists the last verified duplicate scan without persisting destructive
/// selection state. The cache is only a display snapshot: every available
/// source is revalidated before it is exposed again.
struct DuplicateFileResultStore: Sendable {
    static let schemaVersion = 1
    static let maximumDataBytes = 16 * 1024 * 1024
    static let maximumItemCount = 10_000
    static let maximumRootCount = 256
    static let maximumSkippedPathCount = 100_000

    let fileURL: URL

    init(fileURL: URL = Self.defaultURL) {
        self.fileURL = fileURL
    }

    struct StoredResult: Sendable {
        let configuration: DuplicateFileScanner.Configuration
        let items: [StorageItem]
        let coverage: DuplicateFileScanCoverage
        let progress: DuplicateFileScanProgress
        let outcome: DuplicateFileScanOutcome
        let lastScanAt: Date
        let scanSeconds: TimeInterval?
    }

    func load(
        configuration: DuplicateFileScanner.Configuration,
        now: Date = Date()
    ) -> StoredResult? {
        guard let data = readData(),
              data.count <= Self.maximumDataBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == Self.schemaVersion,
              envelope.configuration == configuration,
              envelope.items.count <= Self.maximumItemCount,
              envelope.outcome != .cancelled,
              envelope.savedAt.timeIntervalSince(now).isFinite,
              envelope.lastScanAt.timeIntervalSinceReferenceDate.isFinite,
              envelope.scanSeconds.map({ $0.isFinite && $0 >= 0 && $0 <= 24 * 60 * 60 }) ?? true,
              envelope.progress.phase == .finished,
              Self.validateCoverage(envelope.coverage, configuration: configuration),
              Self.validateItems(envelope.items, configuration: configuration) else {
            return nil
        }

        return StoredResult(
            configuration: envelope.configuration,
            items: envelope.items.map(\.storageItem),
            coverage: envelope.coverage,
            progress: envelope.progress,
            outcome: envelope.outcome,
            lastScanAt: envelope.lastScanAt,
            scanSeconds: envelope.scanSeconds
        )
    }

    func save(
        configuration: DuplicateFileScanner.Configuration,
        items: [StorageItem],
        coverage: DuplicateFileScanCoverage,
        progress: DuplicateFileScanProgress,
        outcome: DuplicateFileScanOutcome,
        lastScanAt: Date,
        scanSeconds: TimeInterval?
    ) throws {
        guard outcome != .cancelled,
              progress.phase == .finished,
              items.count <= Self.maximumItemCount,
              lastScanAt.timeIntervalSinceReferenceDate.isFinite,
              scanSeconds.map({ $0.isFinite && $0 >= 0 && $0 <= 24 * 60 * 60 }) ?? true,
              Self.validateCoverage(coverage, configuration: configuration) else {
            throw DuplicateFileResultStoreError.invalidResult
        }

        let persistedItems = try items.map {
            try PersistedItem(item: $0, configuration: configuration)
        }
        guard Self.validateItems(persistedItems, configuration: configuration) else {
            throw DuplicateFileResultStoreError.invalidResult
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelope = Envelope(
            schemaVersion: Self.schemaVersion,
            savedAt: Date(),
            configuration: configuration,
            items: persistedItems,
            coverage: coverage,
            progress: progress,
            outcome: outcome,
            lastScanAt: lastScanAt,
            scanSeconds: scanSeconds
        )
        let data = try encoder.encode(envelope)
        guard !data.isEmpty, data.count <= Self.maximumDataBytes else {
            throw DuplicateFileResultStoreError.invalidData
        }

        let directory = fileURL.deletingLastPathComponent()
        try ensureSafeDirectory(directory)
        if FileManager.default.fileExists(atPath: fileURL.path), safeRegularFileStatus() == nil {
            throw DuplicateFileResultStoreError.unsafeStoragePath
        }

        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        guard safeRegularFileStatus() != nil else {
            throw DuplicateFileResultStoreError.unsafeStoragePath
        }
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let configuration: DuplicateFileScanner.Configuration
        let items: [PersistedItem]
        let coverage: DuplicateFileScanCoverage
        let progress: DuplicateFileScanProgress
        let outcome: DuplicateFileScanOutcome
        let lastScanAt: Date
        let scanSeconds: TimeInterval?
    }

    private struct PersistedItem: Codable, Sendable {
        let id: String
        let title: String
        let path: String
        let sourceID: String
        let groupTitle: String
        let sizeBytes: Int64
        let tier: StorageTier
        let kind: String
        let reason: String
        let recommendation: String
        let risk: String
        let requiresClose: String
        let trashPaths: [String]
        let openPath: String
        let isDirectory: Bool
        let duplicateGroupID: String?
        let duplicateMatchKind: String?
        let duplicateRelationship: String?
        let duplicatePhysicalReclaimableBytes: Int64?
        let status: ItemStatus
        let fileSnapshot: FileSnapshot?

        init(
            item: StorageItem,
            configuration: DuplicateFileScanner.Configuration
        ) throws {
            id = item.id
            title = item.title
            path = item.path
            sourceID = item.sourceID
            groupTitle = item.groupTitle
            sizeBytes = item.sizeBytes
            tier = item.tier
            kind = item.kind
            reason = item.reason
            recommendation = item.recommendation
            risk = item.risk
            requiresClose = item.requiresClose
            trashPaths = item.trashPaths
            openPath = item.openPath
            isDirectory = item.isDirectory
            duplicateGroupID = item.duplicateGroupID
            duplicateMatchKind = item.duplicateMatchKind
            duplicateRelationship = item.duplicateRelationship
            duplicatePhysicalReclaimableBytes = item.duplicatePhysicalReclaimableBytes
            status = item.status

            guard Self.isContainedPath(item.path, configuration: configuration),
                  Self.isContainedPath(item.openPath, configuration: configuration),
                  item.openPath == item.path,
                  item.trashPaths.allSatisfy({ Self.isContainedPath($0, configuration: configuration) }),
                  !item.isDirectory,
                  item.sizeBytes >= 0 else {
                throw DuplicateFileResultStoreError.invalidResult
            }

            switch item.status {
            case .available:
                guard !PathSafety.containsSymbolicLinkComponent(in: item.path) else {
                    throw DuplicateFileResultStoreError.invalidResult
                }
                fileSnapshot = try FileSnapshot.capture(at: item.path)
                guard fileSnapshot?.sizeBytes == item.sizeBytes else {
                    throw DuplicateFileResultStoreError.invalidResult
                }
            case .movedToTrash:
                // A verified move intentionally makes the original path absent.
                // Keep the terminal display state, but never make it actionable.
                fileSnapshot = nil
            }
        }

        var storageItem: StorageItem {
            StorageItem(
                id: id,
                title: title,
                path: path,
                sourceID: sourceID,
                groupTitle: groupTitle,
                sizeBytes: sizeBytes,
                tier: tier,
                kind: kind,
                reason: reason,
                recommendation: recommendation,
                risk: risk,
                requiresClose: requiresClose,
                trashPaths: trashPaths,
                openPath: openPath,
                isDirectory: isDirectory,
                duplicateGroupID: duplicateGroupID,
                duplicateMatchKind: duplicateMatchKind,
                duplicateRelationship: duplicateRelationship,
                duplicatePhysicalReclaimableBytes: duplicatePhysicalReclaimableBytes,
                status: status
            )
        }

        fileprivate static func isContainedPath(
            _ path: String,
            configuration: DuplicateFileScanner.Configuration
        ) -> Bool {
            guard path.hasPrefix("/"),
                  path == PathSafety.lexicalPath(path),
                  path.count <= 4_096,
                  configuration.roots.contains(where: {
                      PathSafety.isContained(path, in: $0, resolvingSymlinks: false)
                  }) else {
                return false
            }
            return true
        }
    }

    private struct FileSnapshot: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let sizeBytes: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        static func capture(at path: String) throws -> Self {
            var metadata = stat()
            guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_size >= 0,
                  !PathSafety.containsSymbolicLinkComponent(in: path) else {
                throw DuplicateFileResultStoreError.invalidResult
            }
            return Self(
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino),
                sizeBytes: Int64(metadata.st_size),
                modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
                changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
            )
        }

        func matches(path: String) -> Bool {
            guard let current = try? Self.capture(at: path) else { return false }
            return current == self
        }
    }

    private static func validateItems(
        _ items: [PersistedItem],
        configuration: DuplicateFileScanner.Configuration
    ) -> Bool {
        guard items.count <= maximumItemCount else { return false }
        var ids = Set<String>()
        return items.allSatisfy { item in
            guard !item.id.isEmpty,
                  ids.insert(item.id).inserted,
                  item.sizeBytes >= 0,
                  !item.isDirectory,
                  PersistedItem.isContainedPath(item.path, configuration: configuration),
                  item.openPath == item.path,
                  PersistedItem.isContainedPath(item.openPath, configuration: configuration),
                  item.trashPaths.allSatisfy({ PersistedItem.isContainedPath($0, configuration: configuration) }) else {
                return false
            }
            switch item.status {
            case .available:
                guard !PathSafety.containsSymbolicLinkComponent(in: item.path) else { return false }
                guard let snapshot = item.fileSnapshot,
                      snapshot.sizeBytes == item.sizeBytes else { return false }
                return snapshot.matches(path: item.path)
            case .movedToTrash:
                return true
            }
        }
    }

    private static func validateCoverage(
        _ coverage: DuplicateFileScanCoverage,
        configuration: DuplicateFileScanner.Configuration
    ) -> Bool {
        guard coverage.roots.count <= maximumRootCount,
              coverage.roots.count == configuration.roots.count else {
            return false
        }
        let expectedRoots = configuration.roots.map(PathSafety.lexicalPath)
        let observedRoots = coverage.roots.map { PathSafety.lexicalPath($0.rootPath) }
        guard Set(expectedRoots) == Set(observedRoots) else { return false }

        return coverage.roots.allSatisfy { root in
            guard root.rootPath == PathSafety.lexicalPath(root.rootPath),
                  root.scannedDirectories >= 0,
                  root.scannedFiles >= 0,
                  root.scannedBytes >= 0,
                  root.skippedPaths.count <= maximumSkippedPathCount else {
                return false
            }
            return root.skippedPaths.allSatisfy { skipped in
                skipped.path == PathSafety.lexicalPath(skipped.path)
                    && PathSafety.isContained(
                        skipped.path,
                        in: root.rootPath,
                        resolvingSymlinks: false
                    )
            }
        }
    }

    private func readData() -> Data? {
        guard let directoryStatus = safeDirectoryStatus(),
              directoryStatus.st_size >= 0,
              let before = safeRegularFileStatus(),
              before.st_size >= 0,
              before.st_size <= Self.maximumDataBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= Self.maximumDataBytes,
              let after = safeRegularFileStatus(),
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size else {
            return nil
        }
        return data
    }

    private static var defaultURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("DuplicateFiles", isDirectory: true)
            .appendingPathComponent("result.json", isDirectory: false)
    }

    private func ensureSafeDirectory(_ directory: URL) throws {
        var status = stat()
        if directory.path.withCString({ Darwin.lstat($0, &status) }) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o077 == 0 else {
                throw DuplicateFileResultStoreError.unsafeStoragePath
            }
        } else {
            guard errno == ENOENT else {
                throw DuplicateFileResultStoreError.unsafeStoragePath
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func safeDirectoryStatus() -> stat? {
        var status = stat()
        guard fileURL.deletingLastPathComponent().path.withCString({
            Darwin.lstat($0, &status)
        }) == 0,
        (status.st_mode & S_IFMT) == S_IFDIR,
        status.st_uid == geteuid(),
        status.st_mode & 0o077 == 0 else {
            return nil
        }
        return status
    }

    private func safeRegularFileStatus() -> stat? {
        var status = stat()
        guard fileURL.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & 0o077 == 0 else {
            return nil
        }
        return status
    }
}
