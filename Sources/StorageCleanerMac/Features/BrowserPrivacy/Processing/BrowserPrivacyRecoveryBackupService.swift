import CryptoKit
import Darwin
import Foundation

struct BrowserPrivacyRecoveryBackup: Equatable, Sendable {
    let id: UUID
    let databaseURL: URL
    let sha256: Data
    let createdAt: Date
}

protocol BrowserPrivacyDatabaseBackingUp: Sendable {
    func backup(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        browserID: String,
        profileID: String,
        deadlineNanoseconds: UInt64
    ) async throws -> BrowserPrivacyRecoveryBackup
    func restore(
        _ backup: BrowserPrivacyRecoveryBackup,
        destination: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        deadlineNanoseconds: UInt64
    ) async throws
}

extension BrowserPrivacyDatabaseBackingUp {
    func restore(
        _ backup: BrowserPrivacyRecoveryBackup,
        destination: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        deadlineNanoseconds: UInt64
    ) async throws {
        throw SQLiteSnapshotFailure.unavailable
    }
}

struct BrowserPrivacyRecoveryBackupService: BrowserPrivacyDatabaseBackingUp, Sendable {
    private struct Metadata: Codable {
        let version: Int
        let backupID: UUID
        let browserID: String
        let profileFingerprint: String
        let createdAt: Date
        let sha256: String
    }

    static var defaultRootURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("BrowserPrivacyRecovery", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private let rootURL: URL
    private let snapshotService: SQLiteSnapshotService
    private let maximumBackups: Int

    init(
        rootURL: URL = Self.defaultRootURL,
        snapshotService: SQLiteSnapshotService = SQLiteSnapshotService(),
        maximumBackups: Int = 12
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.snapshotService = snapshotService
        self.maximumBackups = min(max(maximumBackups, 1), 64)
    }

    func backup(
        source: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        browserID: String,
        profileID: String,
        deadlineNanoseconds: UInt64
    ) async throws -> BrowserPrivacyRecoveryBackup {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        try Self.requirePrivateDirectory(canonicalRoot, create: false)
        let id = UUID()
        let directory = canonicalRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try Self.requirePrivateDirectory(directory, create: true)
        let databaseURL = directory.appendingPathComponent("History.backup.sqlite")
        let createdAt = Date()

        do {
            try await snapshotService.createPersistentBackup(
                source: source,
                schema: schema,
                destinationURL: databaseURL,
                busyRetrySeconds: 2,
                deadlineNanoseconds: deadlineNanoseconds
            )
            let digest = try FoundationCleanupContentDigestReader().sha256(at: databaseURL)
            let metadata = Metadata(
                version: 1,
                backupID: id,
                browserID: browserID,
                profileFingerprint: Self.sha256Hex(Data(profileID.utf8)),
                createdAt: createdAt,
                sha256: digest.map { String(format: "%02x", $0) }.joined()
            )
            let metadataURL = directory.appendingPathComponent("metadata.json")
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
            guard chmod(metadataURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw SQLiteSnapshotFailure.permissionDenied
            }
            Self.prune(rootURL: canonicalRoot, keeping: maximumBackups)
            return BrowserPrivacyRecoveryBackup(
                id: id,
                databaseURL: databaseURL,
                sha256: digest,
                createdAt: createdAt
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func restore(
        _ backup: BrowserPrivacyRecoveryBackup,
        destination: SQLiteSnapshotSource,
        schema: SQLiteSchemaAllowlist,
        deadlineNanoseconds: UInt64
    ) async throws {
        guard try FoundationCleanupContentDigestReader().sha256(at: backup.databaseURL)
            == backup.sha256 else {
            throw SQLiteSnapshotFailure.corrupt
        }
        try await snapshotService.restorePersistentBackup(
            backupURL: backup.databaseURL,
            destination: destination,
            schema: schema,
            busyRetrySeconds: 2,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    private static func requirePrivateDirectory(_ url: URL, create: Bool) throws {
        if create {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw SQLiteSnapshotFailure.permissionDenied
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw SQLiteSnapshotFailure.permissionDenied
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func prune(rootURL: URL, keeping maximum: Int) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        let owned = entries.compactMap { entry -> (URL, Date)? in
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: [
                      .creationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
                  ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return (entry, values.creationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        for (url, _) in owned.dropFirst(maximum) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
