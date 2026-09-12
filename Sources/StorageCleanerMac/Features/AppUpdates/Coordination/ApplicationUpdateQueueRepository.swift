import Foundation

protocol ApplicationUpdateQueuePersisting: Sendable {
    func load() async throws -> ApplicationUpdateQueueSnapshot?
    func save(_ snapshot: ApplicationUpdateQueueSnapshot) async throws
    func clear() async throws
}

enum ApplicationUpdateQueueRepositoryError: LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case invalidParentDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported application update queue schema: \(version)"
        case let .invalidParentDirectory(path):
            return "Application update queue parent is not a directory: \(path)"
        }
    }
}

actor ApplicationUpdateQueueRepository: ApplicationUpdateQueuePersisting {
    static let currentSchemaVersion = 2

    let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let snapshot = try decoder.decode(ApplicationUpdateQueueSnapshot.self, from: data)
        guard snapshot.schemaVersion == Self.currentSchemaVersion else {
            throw ApplicationUpdateQueueRepositoryError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
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
