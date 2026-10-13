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
    /// Final v11 JSON and its atomic temporary copy share one byte budget.
    static let maximumV11ResultBytes = 1_048_576

    static let defaultStorageURL: URL = {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("benchmark-v7-history.json", isDirectory: false)
    }()

    private let storageURL: URL
    private let fileManager: FileManager
    private let dataWriter: @Sendable (Data, URL) throws -> Void
    private let derivedCacheURL: URL
    private let derivedDataWriter: @Sendable (Data, URL) throws -> Void
    private var status: BenchmarkV7HistoryLoadStatus = .missing

    init(
        storageURL: URL = BenchmarkV7HistoryRepository.defaultStorageURL,
        fileManager: FileManager = .default,
        dataWriter: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic])
        },
        derivedDataWriter: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) {
        self.storageURL = storageURL.standardizedFileURL
        self.fileManager = fileManager
        self.dataWriter = dataWriter
        derivedCacheURL = storageURL.deletingLastPathComponent().appendingPathComponent("benchmark-v11-derived.json")
        self.derivedDataWriter = derivedDataWriter
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
        let results = try v11BudgetedResults(sorted(existing + [result]), changedRecord: result)
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
            try write(v11BudgetedResults(sorted(existing), changedRecord: result))
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

    func loadDerivedCache() throws -> MSeriesV11DerivedCache? {
        guard fileManager.fileExists(atPath: derivedCacheURL.path) else { return nil }
        let values = try derivedCacheURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumFileBytes else { throw HistoryError.corrupt }
        return try JSONDecoder().decode(MSeriesV11DerivedCache.self, from: Data(contentsOf: derivedCacheURL))
    }

    /// No history writes, and no actor suspension between reading, computing and atomic commit.
    /// A failure before/during the atomic writer preserves both the old cache and raw history.
    @discardableResult
    func recalculate(reference: MSeriesReferenceV11.Loaded) throws -> MSeriesV11DerivedCache {
        guard reference.reference != nil else { throw HistoryError.invalidReference }
        let history = try read() ?? []
        let previous = try loadDerivedCache()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entries = try history.map { result -> MSeriesV11DerivedCache.Entry in
            let rawHash = try result.mSeriesV11?.rawPayloadSHA256 ?? MSeriesV11Digest.sha256(encoder.encode(result))
            let key = MSeriesV11DerivedCache.key(sessionID: result.session.id, rawSHA256: rawHash, reference: reference.identity)
            let scores: MSeriesV11Scores
            if let core = result.mSeries {
                scores = MSeriesScoringV11.evaluate(metrics: MSeriesScoringV11.inputs(core: core, envelope: result.mSeriesV11),
                    reference: reference, extensionHash: result.mSeriesV11?.extensionContractHash ?? "",
                    mode: result.mSeriesV11?.mode ?? "standard")
            } else {
                scores = .init(componentScores: [:], labels: ["system": .init(status: .incomparable, reasonCodes: ["missingV11Inputs"])],
                    referenceIdentity: reference.identity, scoreStatus: "partial")
            }
            return .init(key: key, sessionID: result.session.id, rawPayloadSHA256: rawHash,
                originalCompletedAt: result.completedAt, originalReference: result.mSeriesV11?.referenceIdentity, scores: scores)
        }
        if let previous, previous.referenceIdentity == reference.identity, previous.entries == entries { return previous }
        var snapshots = previous?.previousSnapshots ?? []
        for entry in previous?.entries ?? [] where !snapshots.contains(where: { $0.key == entry.key }) { snapshots.append(entry) }
        let cache = MSeriesV11DerivedCache(referenceIdentity: reference.identity, entries: entries, previousSnapshots: snapshots)
        let bytes = try encoder.encode(cache)
        guard bytes.count <= Self.maximumFileBytes,
              try JSONDecoder().decode(MSeriesV11DerivedCache.self, from: bytes) == cache else { throw HistoryError.invalidResult }
        let directory = derivedCacheURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw HistoryError.invalidDirectory }
        let stagedURL = directory.appendingPathComponent("benchmark-v11-derived-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: stagedURL) }
        try derivedDataWriter(bytes, stagedURL)
        guard try Data(contentsOf: stagedURL) == bytes else { throw HistoryError.invalidResult }
        // The injected writer only sees our owned staging path, never the live cache.
        // Foundation's atomic final write either replaces the cache completely or keeps it.
        try bytes.write(to: derivedCacheURL, options: [.atomic])
        return cache
    }

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

    /// The existing JSON repository rewrites its entire history atomically.
    /// Account those real bytes before writing; do not trim old records to fit.
    private func v11BudgetedResults(_ results: [BenchmarkV7Result], changedRecord: BenchmarkV7Result) throws -> [BenchmarkV7Result] {
        let results = try privacySafeResults(results)
        guard changedRecord.mSeriesV11 != nil else { return results }
        guard let id = changedRecord.recordID, let index = results.firstIndex(where: { $0.recordID == id }) else {
            throw HistoryError.invalidResult
        }
        let changedRecord = results[index]
        guard var envelope = changedRecord.mSeriesV11 else { throw HistoryError.invalidResult }
        var staged = results
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for _ in 0..<5 {
            let bytes = try encoder.encode(staged)
            guard bytes.count <= Self.maximumV11ResultBytes else { throw HistoryError.invalidResult }
            let metadata = UInt64(bytes.count) * 2
            let total = (changedRecord.mSeries?.writtenBytes ?? 0) + metadata
            guard metadata <= UInt64(Self.maximumV11ResultBytes) * 2, total <= MSeriesProtocol.maximumWrittenBytes else { throw HistoryError.invalidResult }
            if envelope.metadataWrittenBytes == metadata && envelope.writtenBytes == total { return staged }
            envelope.metadataWrittenBytes = metadata
            envelope.writtenBytes = total
            staged[index] = changedRecord.replacingV11Envelope(envelope)
        }
        throw HistoryError.invalidResult
    }

    /// Covers save, replacement and deletion rewrites, including untouched old
    /// records. Reading never modifies a legacy file or its original digest.
    private func privacySafeResults(_ results: [BenchmarkV7Result]) throws -> [BenchmarkV7Result] {
        try results.map { record in
            guard let envelope = record.mSeriesV11,
                  envelope.telemetry.contains(where: { $0.helperBootID != nil }) else { return record }
            let sealed = try MSeriesV11RawPayload.seal(core: record.mSeries, envelope: envelope)
            return record.replacingV11Envelope(sealed)
        }
    }

    private func write(_ results: [BenchmarkV7Result]) throws {
        let results = try privacySafeResults(results)
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
        case invalidReference
    }
}
