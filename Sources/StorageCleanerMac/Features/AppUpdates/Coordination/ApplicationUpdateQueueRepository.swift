import Foundation

protocol ApplicationUpdateQueuePersisting: Sendable {
    func load() async throws -> ApplicationUpdateQueueSnapshot?
    func save(_ snapshot: ApplicationUpdateQueueSnapshot) async throws
    func clear() async throws
    func recoveryIssue() async throws -> ApplicationUpdateQueueRecoveryIssue?
    func acknowledgeRecoveryIssue() async throws
}

extension ApplicationUpdateQueuePersisting {
    func recoveryIssue() async throws -> ApplicationUpdateQueueRecoveryIssue? { nil }
    func acknowledgeRecoveryIssue() async throws {}
}

struct ApplicationUpdateQueueRecoveryIssue: Codable, Hashable, Sendable {
    let archivedPath: String
    let archivedAt: Date
    let reason: String
    var archiveWasCreated: Bool?
    var detail: String {
        (archiveWasCreated == true
            ? L10n.text("更新记录无法读取，原文件已原样归档。", "The update queue could not be read and was archived unchanged.")
            : L10n.text("更新记录无法读取，原始数据仍保留。", "The update queue could not be read; the original data is retained."))
            + L10n.text("确认没有正在进行的更新前，Homebrew 更新全部隔离。保留位置：", "All Homebrew updates remain quarantined until you confirm no update is in progress. Retained at: ") + archivedPath + "\n" + reason
    }
}

struct ApplicationUpdateRecoveryStatus: Sendable {
    var tasks: [ApplicationUpdateTask] = []
    var queueIssue: ApplicationUpdateQueueRecoveryIssue?
    var isEmpty: Bool { tasks.isEmpty && queueIssue == nil }
}

enum ApplicationUpdateQueueRepositoryError: LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case invalidParentDirectory(String)
    case recoveryRequired(ApplicationUpdateQueueRecoveryIssue)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported application update queue schema: \(version)"
        case let .invalidParentDirectory(path):
            return "Application update queue parent is not a directory: \(path)"
        case let .recoveryRequired(issue): return issue.detail
        }
    }
}

actor ApplicationUpdateQueueRepository: ApplicationUpdateQueuePersisting {
    static let currentSchemaVersion = 2

    let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedRecoveryIssue: ApplicationUpdateQueueRecoveryIssue?
    private var recoveryMarkerURL: URL { fileURL.appendingPathExtension("recovery.json") }

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func load() throws -> ApplicationUpdateQueueSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let snapshot = try decoder.decode(ApplicationUpdateQueueSnapshot.self, from: data)
            guard snapshot.schemaVersion == Self.currentSchemaVersion else {
                throw ApplicationUpdateQueueRepositoryError.unsupportedSchema(snapshot.schemaVersion)
            }
            return snapshot
        } catch {
            let date = Date()
            let stamp = String(Int64(date.timeIntervalSince1970 * 1000))
            let archive = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".unreadable-" + stamp + "-" + UUID().uuidString)
            var issue = ApplicationUpdateQueueRecoveryIssue(archivedPath: archive.path, archivedAt: date,
                reason: AppUpdateErrorRedaction.text(error.localizedDescription), archiveWasCreated: false)
            // Persist quarantine before the same-directory rename: a crash must
            // never turn a missing active queue into permission to reinstall.
            cachedRecoveryIssue = issue
            try encoder.encode(issue).write(to: recoveryMarkerURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryMarkerURL.path)
            try FileManager.default.moveItem(at: fileURL, to: archive)
            issue.archiveWasCreated = true
            cachedRecoveryIssue = issue
            try encoder.encode(issue).write(to: recoveryMarkerURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryMarkerURL.path)
            throw ApplicationUpdateQueueRepositoryError.recoveryRequired(issue)
        }
    }

    func recoveryIssue() throws -> ApplicationUpdateQueueRecoveryIssue? {
        if let cachedRecoveryIssue { return cachedRecoveryIssue }
        guard FileManager.default.fileExists(atPath: recoveryMarkerURL.path) else { return nil }
        do { cachedRecoveryIssue = try decoder.decode(ApplicationUpdateQueueRecoveryIssue.self, from: Data(contentsOf: recoveryMarkerURL)) }
        catch {
            // An unreadable marker is itself evidence of an unconfirmed queue;
            // do not silently discard it or unblock the provider after restart.
            cachedRecoveryIssue = .init(archivedPath: recoveryMarkerURL.path, archivedAt: Date(),
                reason: L10n.text("恢复确认记录也无法读取：", "The recovery confirmation record is also unreadable: ") + AppUpdateErrorRedaction.text(error.localizedDescription))
        }
        return cachedRecoveryIssue
    }

    func acknowledgeRecoveryIssue() throws {
        guard try recoveryIssue() != nil else { return }
        // Only this App's quarantine marker is cleared. The original archive
        // remains byte-for-byte intact for review and recovery.
        if FileManager.default.fileExists(atPath: recoveryMarkerURL.path) {
            let archive = recoveryMarkerURL.appendingPathExtension("acknowledged-" + String(Int64(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString)
            try FileManager.default.moveItem(at: recoveryMarkerURL, to: archive)
        }
        cachedRecoveryIssue = nil
    }

    func loadSnapshot() throws -> ApplicationUpdateQueueSnapshot? {
        try load()
    }

    func save(_ snapshot: ApplicationUpdateQueueSnapshot) throws {
        guard snapshot.schemaVersion == Self.currentSchemaVersion else {
            throw ApplicationUpdateQueueRepositoryError.unsupportedSchema(snapshot.schemaVersion)
        }

        let parent = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ApplicationUpdateQueueRepositoryError.invalidParentDirectory(parent.path)
            }
        } else {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func saveSnapshot(_ snapshot: ApplicationUpdateQueueSnapshot) throws {
        try save(snapshot)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func removeSnapshot() throws {
        try clear()
    }
}
