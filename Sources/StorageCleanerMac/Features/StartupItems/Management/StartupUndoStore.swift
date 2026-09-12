import Foundation

extension StartupItemsDomain {
    struct StartupUndoStateSnapshot: Codable, Equatable, Sendable {
        let enablement: EnablementState
        let load: LoadState
        let processKind: String
        let processValue: Int32?

        init(state: State) {
            enablement = state.enablement
            load = state.load
            switch state.process {
            case let .running(pid):
                processKind = "running"
                processValue = pid
            case .stopped:
                processKind = "stopped"
                processValue = nil
            case .waiting:
                processKind = "waiting"
                processValue = nil
            case let .failed(exitCode):
                processKind = "failed"
                processValue = exitCode
            case .unknown:
                processKind = "unknown"
                processValue = nil
            }
        }

        var shouldBeLoaded: Bool {
            if load == .loaded || load == .onDemand { return true }
            return processKind == "running" || processKind == "waiting"
        }
    }

    struct StartupUndoRecord: Identifiable, Codable, Equatable, Sendable {
        static let defaultRetentionPeriod: TimeInterval = 90 * 24 * 60 * 60

        let id: UUID
        let createdAt: Date
        let itemID: String
        let label: String
        let plistURL: URL
        let userID: uid_t
        let inverseOperation: StartupOperationKind
        let previousState: StartupUndoStateSnapshot
        let plistContentDigest: String?
        let identityBinding: StartupOperationIdentityBinding?

        init(
            id: UUID,
            createdAt: Date,
            itemID: String,
            label: String,
            plistURL: URL,
            userID: uid_t,
            inverseOperation: StartupOperationKind,
            previousState: StartupUndoStateSnapshot,
            plistContentDigest: String? = nil,
            identityBinding: StartupOperationIdentityBinding? = nil
        ) {
            self.id = id
            self.createdAt = createdAt
            self.itemID = itemID
            self.label = label
            self.plistURL = plistURL
            self.userID = userID
            self.inverseOperation = inverseOperation
            self.previousState = previousState
            self.plistContentDigest = plistContentDigest
            self.identityBinding = identityBinding
        }
    }

    protocol StartupUndoStoring: Sendable {
        func append(_ record: StartupUndoRecord) async throws
        func record(id: UUID) async throws -> StartupUndoRecord?
        func allRecords() async throws -> [StartupUndoRecord]
        func remove(id: UUID) async throws
    }

    actor FileStartupUndoStore: StartupUndoStoring {
        private struct Envelope: Codable {
            let schemaVersion: Int
            var records: [StartupUndoRecord]
        }

        private let fileURL: URL
        private let fileManager: FileManager
        private let retentionPeriod: TimeInterval
        private var cached: Envelope?

        init(
            fileURL: URL,
            fileManager: FileManager = .default,
            retentionPeriod: TimeInterval = StartupUndoRecord.defaultRetentionPeriod
        ) {
            self.fileURL = fileURL
            self.fileManager = fileManager
            self.retentionPeriod = max(24 * 60 * 60, retentionPeriod)
        }

        static func defaultStore(fileManager: FileManager = .default) -> FileStartupUndoStore {
            return FileStartupUndoStore(
                fileURL: AppDataDirectories.applicationSupportRoot(fileManager: fileManager)
                    .appendingPathComponent("startup-undo-v1.json")
            )
        }

        func append(_ record: StartupUndoRecord) throws {
            var envelope = try load()
            envelope.records.removeAll { $0.id == record.id }
            envelope.records.append(record)
            envelope.records = pruned(envelope.records)
            try persist(envelope)
        }

        func record(id: UUID) throws -> StartupUndoRecord? {
            try load().records.first { $0.id == id }
        }

        func allRecords() throws -> [StartupUndoRecord] {
            try load().records.sorted { $0.createdAt > $1.createdAt }
        }

        func remove(id: UUID) throws {
            var envelope = try load()
            envelope.records.removeAll { $0.id == id }
            try persist(envelope)
        }

        private func load() throws -> Envelope {
            if let cached { return cached }
            guard fileManager.fileExists(atPath: fileURL.path) else {
                let envelope = Envelope(schemaVersion: 1, records: [])
                cached = envelope
                return envelope
            }
            do {
                let data = try Data(contentsOf: fileURL)
                var envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.schemaVersion == 1 else {
                    throw StartupManagementError.persistenceFailed("unsupported-schema")
                }
                envelope.records = pruned(envelope.records)
                cached = envelope
                return envelope
            } catch let error as StartupManagementError {
                throw error
            } catch {
                throw StartupManagementError.persistenceFailed(String(describing: error))
            }
        }

        private func persist(_ envelope: Envelope) throws {
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: fileURL.deletingLastPathComponent().path
                )
                let data = try JSONEncoder().encode(envelope)
                try data.write(to: fileURL, options: [.atomic])
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
                cached = envelope
            } catch {
                throw StartupManagementError.persistenceFailed(String(describing: error))
            }
        }

        private func pruned(_ records: [StartupUndoRecord]) -> [StartupUndoRecord] {
            let cutoff = Date().addingTimeInterval(-retentionPeriod)
            return records
                .filter { $0.createdAt >= cutoff }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(100)
                .map { $0 }
        }
    }
}
