import Foundation

enum BenchmarkV7HistoryLoadStatus: Equatable, Sendable {
    case missing
    case loaded
    case corrupt
    case failed
}

protocol BenchmarkV7HistoryPersisting: Sendable {
    func load() async -> [BenchmarkV7Result]
    func save(_ result: BenchmarkV7Result) async throws
    /// Replaces one immutable record with one new record in a single commit.
    /// Implementations must not expose an intermediate deletion if the write
    /// fails.
    func replace(recordID: UUID, with result: BenchmarkV7Result) async throws
    /// Removes exactly one persisted evidence record. The record identity is
    /// intentionally distinct from a benchmark session ID because a cancelled
    /// or failed record may share that session with another history item.
    func delete(recordID: UUID) async throws -> Bool
    func loadStatus() async -> BenchmarkV7HistoryLoadStatus
}

/// The v7 JSON schema lives beside, rather than inside, the immutable v2-v6
/// history. A corrupt existing file blocks writes so old evidence is never
/// silently replaced by a new benchmark result.
actor BenchmarkV7HistoryRepository: BenchmarkV7HistoryPersisting {
    static let maximumFileBytes = 8 * 1_024 * 1_024

    static let defaultStorageURL: URL = {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("benchmark-v7-history.json", isDirectory: false)
    }()

    private let storageURL: URL
    private let fileManager: FileManager
    private let dataWriter: @Sendable (Data, URL) throws -> Void
    private var status: BenchmarkV7HistoryLoadStatus = .missing

    init(
        storageURL: URL = BenchmarkV7HistoryRepository.defaultStorageURL,
        fileManager: FileManager = .default,
        dataWriter: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) {
        self.storageURL = storageURL.standardizedFileURL
        self.fileManager = fileManager
        self.dataWriter = dataWriter
    }

    func load() async -> [BenchmarkV7Result] {
        do {
            let results = try read()
            status = results == nil ? .missing : .loaded
            return sorted(results ?? [])
        } catch HistoryError.corrupt {
            status = .corrupt
            return []
        } catch {
            status = .failed
            return []
        }
    }

    func save(_ result: BenchmarkV7Result) async throws {
        guard result.isPersistable else { throw HistoryError.invalidResult }
        let existing = try read() ?? []
        if let recordID = result.recordID,
           existing.contains(where: { $0.recordID == recordID }) {
            throw HistoryError.duplicateRecordID
        }
        let results = sorted(existing + [result])
        try write(results)
        status = .loaded
    }

    func replace(recordID: UUID, with result: BenchmarkV7Result) async throws {
        guard result.isPersistable else { throw HistoryError.invalidResult }
        guard var existing = try read(),
              let index = existing.firstIndex(where: { $0.recordID == recordID }) else {
            throw HistoryError.originalRecordMissing
        }
        if let replacementID = result.recordID,
           replacementID != recordID,
           existing.contains(where: { $0.recordID == replacementID }) {
            throw HistoryError.duplicateRecordID
        }

        existing[index] = result
        do {
            try write(sorted(existing))
            status = .loaded
        } catch {
            status = .failed
            throw error
        }
    }

    func delete(recordID: UUID) async throws -> Bool {
        guard var existing = try read() else {
            status = .missing
            return false
        }
        guard let index = existing.firstIndex(where: { $0.recordID == recordID }) else {
            status = .loaded
            return false
        }

        existing.remove(at: index)
        try write(sorted(existing))
        status = .loaded
        return true
    }

    func loadStatus() async -> BenchmarkV7HistoryLoadStatus { status }

    private func read() throws -> [BenchmarkV7Result]? {
        guard fileManager.fileExists(atPath: storageURL.path) else { return nil }
        let values = try storageURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= Self.maximumFileBytes else {
            throw HistoryError.corrupt
        }
        let data = try Data(contentsOf: storageURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumFileBytes else { throw HistoryError.corrupt }
        do {
            let results = try JSONDecoder().decode([BenchmarkV7Result].self, from: data)
            guard results.allSatisfy(\.isPersistable) else { throw HistoryError.corrupt }
            return results
        } catch {
            throw HistoryError.corrupt
        }
    }

    private func write(_ results: [BenchmarkV7Result]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HistoryError.invalidDirectory
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(results)
        guard data.count <= Self.maximumFileBytes else { throw HistoryError.invalidResult }
        try dataWriter(data, storageURL)
    }

    /// History records are immutable evidence. The file-size ceiling is the
    /// explicit capacity boundary; it must reject a new write rather than
    /// silently discarding older, otherwise valid sessions.
    private func sorted(_ results: [BenchmarkV7Result]) -> [BenchmarkV7Result] {
        results.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
    }

    private enum HistoryError: Error {
        case corrupt
        case invalidDirectory
        case invalidResult
        case duplicateRecordID
        case originalRecordMissing
    }
}
