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

enum BenchmarkV7HistoryError: Error, Equatable {
    case corrupt
    case invalidDirectory
    case invalidResult
    case duplicateRecordID
    case originalRecordMissing
    case invalidReference
    /// The store already holds `maximumRecordCount` records. Older evidence
    /// is never trimmed to make room; the person deletes records explicitly.
    case capacityReached
}

/// v7–v11 benchmark history (D95): one immutable JSON file per record in
/// `<name>-records/`, plus `index.json`, the single commit point of every
/// change. The v7 schema still lives beside, rather than inside, the
/// immutable v2–v6 history, and a corrupt store blocks writes so old evidence
/// is never silently replaced by a new benchmark result.
///
/// The original single `benchmark-v7-history.json` was rewritten whole on
/// every save, so a v11 run's write ledger grew with the history and every
/// save failed once the file passed 1 MiB. A save now writes only its own
/// record and the small index, and the v11 ledger counts exactly those bytes.
/// A single-file history is imported by the first write, in that write's
/// commit; the file is removed only after the index that contains all of its
/// records is committed. Reading never modifies either layout.
actor BenchmarkV7HistoryRepository: BenchmarkV7HistoryPersisting {
    static let maximumFileBytes = 8 * 1_024 * 1_024
    /// SPEC §5.3: one final v11 record ≤ 1 MiB; the record, the index commit
    /// and their atomic temporary copies ≤ 2 MiB together.
    static let maximumV11ResultBytes = 1_048_576
    /// Explicit capacity of the store. A save at capacity is refused with
    /// `capacityReached`, never made room for by dropping older records.
    static let maximumRecordCount = 1_000
    static let maximumIndexBytes = 1_048_576
    static let indexSchema = "benchmark-v7-history-index-v1"

    static let defaultStorageURL: URL = {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("benchmark-v7-history.json", isDirectory: false)
    }()

    /// The record store that replaces the single file at `storageURL`.
    static func recordStoreURL(forStorageURL storageURL: URL) -> URL {
        let file = storageURL.standardizedFileURL
        return file.deletingLastPathComponent().appendingPathComponent(
            "\(file.deletingPathExtension().lastPathComponent)-records",
            isDirectory: true
        )
    }

    static func indexURL(forStorageURL storageURL: URL) -> URL {
        recordStoreURL(forStorageURL: storageURL).appendingPathComponent("index.json", isDirectory: false)
    }

    private let storageURL: URL
    private let storeURL: URL
    private let indexURL: URL
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
        storeURL = Self.recordStoreURL(forStorageURL: storageURL)
        indexURL = Self.indexURL(forStorageURL: storageURL)
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
        // A v11 record must carry its own identity for its write ledger.
        if result.mSeriesV11 != nil, result.recordID == nil { throw HistoryError.invalidResult }
        let snapshot = try readSnapshot()
        let existing = snapshot.records ?? []
        if let recordID = result.recordID,
           existing.contains(where: { $0.recordID == recordID }) {
            throw HistoryError.duplicateRecordID
        }
        guard existing.count < Self.maximumRecordCount else { throw HistoryError.capacityReached }
        var plan = try writePlan(from: snapshot)
        let staged = try stagedRecord(result, in: plan, replacing: nil)
        plan.add(staged)
        try execute(plan)
        status = .loaded
    }

    func replace(recordID: UUID, with result: BenchmarkV7Result) async throws {
        guard result.isPersistable else { throw HistoryError.invalidResult }
        let snapshot = try readSnapshot()
        guard let existing = snapshot.records,
              existing.contains(where: { $0.recordID == recordID }) else {
            throw HistoryError.originalRecordMissing
        }
        if let replacementID = result.recordID,
           replacementID != recordID,
           existing.contains(where: { $0.recordID == replacementID }) {
            throw HistoryError.duplicateRecordID
        }
        if result.mSeriesV11 != nil, result.recordID == nil { throw HistoryError.invalidResult }

        do {
            var plan = try writePlan(from: snapshot)
            guard let position = plan.records.firstIndex(where: { $0.recordID == recordID }) else {
                throw HistoryError.originalRecordMissing
            }
            let staged = try stagedRecord(result, in: plan, replacing: position)
            plan.replace(at: position, with: staged)
            try execute(plan)
            status = .loaded
        } catch {
            status = .failed
            throw error
        }
    }

    func delete(recordID: UUID) async throws -> Bool {
        let snapshot = try readSnapshot()
        guard let existing = snapshot.records else {
            status = .missing
            return false
        }
        guard existing.contains(where: { $0.recordID == recordID }) else {
            status = .loaded
            return false
        }

        var plan = try writePlan(from: snapshot)
        guard let position = plan.records.firstIndex(where: { $0.recordID == recordID }) else {
            throw HistoryError.originalRecordMissing
        }
        plan.remove(at: position)
        try execute(plan)
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

    // MARK: - Reading

    private struct StoreIndex: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var file: String
            var bytes: Int
            var sha256: String
        }

        var schema: String
        var entries: [Entry]
        /// Digest of the last single-file history imported into this store.
        /// A copy left behind by a failed removal is never imported twice.
        var importedLegacySHA256: String?
    }

    private struct LegacyHistory {
        let sha256: String
        let records: [BenchmarkV7Result]
    }

    /// The committed store, and a single-file history not yet imported.
    private struct Snapshot {
        var index: StoreIndex?
        var stored: [BenchmarkV7Result]
        var pendingLegacy: LegacyHistory?

        var records: [BenchmarkV7Result]? {
            guard index != nil || pendingLegacy != nil else { return nil }
            var known = Set(stored.map(BenchmarkV7HistoryRepository.identity))
            return stored + (pendingLegacy?.records ?? []).filter {
                known.insert(BenchmarkV7HistoryRepository.identity($0)).inserted
            }
        }
    }

    private func read() throws -> [BenchmarkV7Result]? {
        try readSnapshot().records
    }

    private func readSnapshot() throws -> Snapshot {
        let index = try readIndex()
        let stored = try index?.entries.map { try readRecord($0) } ?? []
        var pending: LegacyHistory?
        if let data = try readLegacyData() {
            let digest = MSeriesV11Digest.sha256(data)
            if digest != index?.importedLegacySHA256 {
                pending = LegacyHistory(sha256: digest, records: try decodeLegacy(data))
            }
        }
        return Snapshot(index: index, stored: stored, pendingLegacy: pending)
    }

    private func readLegacyData() throws -> Data? {
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
        return data
    }

    private func decodeLegacy(_ data: Data) throws -> [BenchmarkV7Result] {
        do {
            let results = try JSONDecoder().decode([BenchmarkV7Result].self, from: data)
            guard results.allSatisfy(\.isPersistable) else { throw HistoryError.corrupt }
            return results
        } catch {
            throw HistoryError.corrupt
        }
    }

    private func readIndex() throws -> StoreIndex? {
        guard fileManager.fileExists(atPath: indexURL.path) else { return nil }
        try requireDirectory(storeURL, failure: .corrupt)
        let data = try readStoreFile(indexURL, maximumBytes: Self.maximumIndexBytes)
        guard let index = try? JSONDecoder().decode(StoreIndex.self, from: data),
              index.schema == Self.indexSchema,
              Set(index.entries.map(\.file)).count == index.entries.count,
              index.entries.allSatisfy({
                  Self.isRecordFileName($0.file) && MSeriesV11Digest.isSHA256($0.sha256)
                      && (0...Self.maximumFileBytes).contains($0.bytes)
              }),
              index.importedLegacySHA256.map(MSeriesV11Digest.isSHA256) ?? true else {
            throw HistoryError.corrupt
        }
        return index
    }

    private func readRecord(_ entry: StoreIndex.Entry) throws -> BenchmarkV7Result {
        let data = try readStoreFile(storeURL.appendingPathComponent(entry.file, isDirectory: false),
                                     maximumBytes: Self.maximumFileBytes)
        guard data.count == entry.bytes, MSeriesV11Digest.sha256(data) == entry.sha256,
              let record = try? JSONDecoder().decode(BenchmarkV7Result.self, from: data),
              record.isPersistable else {
            throw HistoryError.corrupt
        }
        return record
    }

    /// A committed index names only regular, non-linked files inside the store.
    private func readStoreFile(_ url: URL, maximumBytes: Int) throws -> Data {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumBytes else {
            throw HistoryError.corrupt
        }
        return data
    }

    private func requireDirectory(_ url: URL, failure: HistoryError) throws {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { throw failure }
    }

    private static func isRecordFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { return false }
        return name == "\(id.uuidString).json"
    }

    private static func identity(_ record: BenchmarkV7Result) -> String {
        if let recordID = record.recordID { return "record:\(recordID.uuidString)" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return "content:" + ((try? encoder.encode(record)).map(MSeriesV11Digest.sha256) ?? UUID().uuidString)
    }

    // MARK: - Writing

    private struct StagedRecord {
        let record: BenchmarkV7Result
        let entry: StoreIndex.Entry
        let data: Data
    }

    /// The next committed state: every file it adds is written and verified
    /// first, then one atomic index replacement makes the change visible.
    private struct WritePlan {
        var index: StoreIndex
        var records: [BenchmarkV7Result]
        var pendingFiles: [String: Data] = [:]
        var supersededFiles: [String] = []

        mutating func add(_ staged: StagedRecord) {
            index.entries.append(staged.entry)
            records.append(staged.record)
            pendingFiles[staged.entry.file] = staged.data
        }

        mutating func replace(at position: Int, with staged: StagedRecord) {
            retire(index.entries[position].file)
            index.entries[position] = staged.entry
            records[position] = staged.record
            pendingFiles[staged.entry.file] = staged.data
        }

        mutating func remove(at position: Int) {
            retire(index.entries[position].file)
            index.entries.remove(at: position)
            records.remove(at: position)
        }

        private mutating func retire(_ file: String) {
            if pendingFiles.removeValue(forKey: file) == nil { supersededFiles.append(file) }
        }
    }

    /// Starts from the committed store and, when a single-file history has
    /// not been imported yet, adds its records in this same commit. As with
    /// every rewrite of that file before (helper-interval fix1), imported
    /// records are stored without helper boot identifiers.
    private func writePlan(from snapshot: Snapshot) throws -> WritePlan {
        var plan = WritePlan(
            index: snapshot.index ?? StoreIndex(schema: Self.indexSchema, entries: [], importedLegacySHA256: nil),
            records: snapshot.stored
        )
        if let legacy = snapshot.pendingLegacy {
            var known = Set(snapshot.stored.map(Self.identity))
            let imported = legacy.records.filter { known.insert(Self.identity($0)).inserted }
            for record in try privacySafeResults(imported) {
                let data = try Self.encode(record)
                guard data.count <= Self.maximumFileBytes else { throw HistoryError.invalidResult }
                plan.add(StagedRecord(record: record, entry: .init(file: Self.newRecordFileName(), bytes: data.count,
                    sha256: MSeriesV11Digest.sha256(data)), data: data))
            }
            plan.index.importedLegacySHA256 = legacy.sha256
        }
        return plan
    }

    /// v11 records account the bytes of their own commit: the record file and
    /// the index, each with its atomic temporary copy. Older records are no
    /// longer rewritten, so they no longer count against a new result.
    private func stagedRecord(_ result: BenchmarkV7Result, in plan: WritePlan, replacing position: Int?) throws -> StagedRecord {
        guard var staged = try privacySafeResults([result]).first else { throw HistoryError.invalidResult }
        let file = Self.newRecordFileName()
        for _ in 0..<8 {
            let data = try Self.encode(staged)
            guard data.count <= Self.maximumFileBytes else { throw HistoryError.invalidResult }
            let entry = StoreIndex.Entry(file: file, bytes: data.count, sha256: MSeriesV11Digest.sha256(data))
            guard var envelope = staged.mSeriesV11 else { return StagedRecord(record: staged, entry: entry, data: data) }
            var index = plan.index
            if let position { index.entries[position] = entry } else { index.entries.append(entry) }
            let indexBytes = try Self.encode(index).count
            guard data.count <= Self.maximumV11ResultBytes else { throw HistoryError.invalidResult }
            let metadata = UInt64(data.count + indexBytes) * 2
            let total = (staged.mSeries?.writtenBytes ?? 0) + metadata
            guard metadata <= UInt64(Self.maximumV11ResultBytes) * 2,
                  total <= MSeriesProtocol.maximumWrittenBytes else { throw HistoryError.invalidResult }
            if envelope.metadataWrittenBytes == metadata && envelope.writtenBytes == total {
                return StagedRecord(record: staged, entry: entry, data: data)
            }
            envelope.metadataWrittenBytes = metadata
            envelope.writtenBytes = total
            staged = staged.replacingV11Envelope(envelope)
        }
        throw HistoryError.invalidResult
    }

    /// Writes and verifies new record files, then replaces the index in one
    /// rename. Until that rename nothing visible changes; a failure removes
    /// only the files this call wrote. Superseded files and an imported
    /// single-file history are removed after the commit.
    private func execute(_ plan: WritePlan) throws {
        let parent = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try requireDirectory(parent, failure: .invalidDirectory)
        try fileManager.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try requireDirectory(storeURL, failure: .invalidDirectory)

        let indexData = try Self.encode(plan.index)
        guard indexData.count <= Self.maximumIndexBytes else { throw HistoryError.invalidResult }
        let stagedIndexURL = storeURL.appendingPathComponent("index-\(UUID().uuidString).tmp", isDirectory: false)
        var written: [URL] = []
        do {
            for (file, data) in plan.pendingFiles {
                let url = storeURL.appendingPathComponent(file, isDirectory: false)
                written.append(url)
                try dataWriter(data, url)
                guard try Data(contentsOf: url) == data else { throw HistoryError.invalidResult }
            }
            written.append(stagedIndexURL)
            try dataWriter(indexData, stagedIndexURL)
            guard try Data(contentsOf: stagedIndexURL) == indexData else { throw HistoryError.invalidResult }
            guard rename(stagedIndexURL.path, indexURL.path) == 0 else { throw HistoryError.invalidResult }
        } catch {
            for url in written { try? fileManager.removeItem(at: url) }
            throw error
        }
        for file in plan.supersededFiles {
            try? fileManager.removeItem(at: storeURL.appendingPathComponent(file, isDirectory: false))
        }
        if let imported = plan.index.importedLegacySHA256,
           let legacy = try? readLegacyData(), MSeriesV11Digest.sha256(legacy) == imported {
            try? fileManager.removeItem(at: storageURL)
        }
    }

    /// Covers save, replacement and import writes. Reading never modifies a
    /// legacy file or its original digest.
    private func privacySafeResults(_ results: [BenchmarkV7Result]) throws -> [BenchmarkV7Result] {
        try results.map { record in
            guard let envelope = record.mSeriesV11,
                  envelope.telemetry.contains(where: { $0.helperBootID != nil }) else { return record }
            let sealed = try MSeriesV11RawPayload.seal(core: record.mSeries, envelope: envelope)
            return record.replacingV11Envelope(sealed)
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func newRecordFileName() -> String { "\(UUID().uuidString).json" }

    /// History records are immutable evidence. The record count is the
    /// explicit capacity boundary; it must reject a new write rather than
    /// silently discarding older, otherwise valid sessions.
    private func sorted(_ results: [BenchmarkV7Result]) -> [BenchmarkV7Result] {
        results.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
    }

    private typealias HistoryError = BenchmarkV7HistoryError
}
