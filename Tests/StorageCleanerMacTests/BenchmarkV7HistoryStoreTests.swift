import Foundation
import XCTest
@testable import StorageCleanerMac

/// D95: the v7–v11 benchmark history keeps one immutable file per record and
/// an index, so a large history no longer blocks new v11 results.
final class BenchmarkV7HistoryStoreTests: XCTestCase {
    /// The 2026-10-13 failure: with a single-file history above 1 MiB, every
    /// new v11 save was refused. Uses only the repository's original API so it
    /// also runs against the single-file implementation (and fails there).
    func testV11ResultSavesWhenSingleFileHistoryIsAboveOneMiB() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("benchmark-v7-history.json")
        let legacy = Self.legacyHistory(count: 12, paddingEach: 130_000)
        let original = try JSONEncoder().encode(legacy)
        XCTAssertGreaterThan(original.count, 1_048_576)
        try original.write(to: url)
        let repository = BenchmarkV7HistoryRepository(storageURL: url)
        let incoming = try Self.v11Result()
        try await repository.save(incoming)
        let loaded = await repository.load()
        XCTAssertEqual(loaded.count, 13)
        XCTAssertEqual(Set(loaded.compactMap(\.recordID)), Set((legacy + [incoming]).compactMap(\.recordID)))
        let saved = try XCTUnwrap(loaded.first { $0.recordID == incoming.recordID })
        XCTAssertTrue(saved.isPersistable)
        XCTAssertLessThanOrEqual(try XCTUnwrap(saved.mSeriesV11?.metadataWrittenBytes), 2 * 1_048_576)
        XCTAssertEqual(saved.mSeriesV11?.rawPayloadSHA256, incoming.mSeriesV11?.rawPayloadSHA256)
        for record in legacy {
            XCTAssertEqual(loaded.first { $0.recordID == record.recordID }, record, "older evidence is kept unchanged")
        }
        let status = await repository.loadStatus()
        XCTAssertEqual(status, .loaded)
    }

    func testFirstWriteImportsTheSingleFileInItsCommitAndRemovesItAfterwards() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("benchmark-v7-history.json")
        let legacy = Self.legacyHistory(count: 3, paddingEach: 1_000)
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: url)
        let repository = BenchmarkV7HistoryRepository(storageURL: url)

        // Reading never migrates or changes the single file.
        let read = await repository.load()
        XCTAssertEqual(Set(read.compactMap(\.recordID)), Set(legacy.compactMap(\.recordID)))
        XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.files(for: url), [url.lastPathComponent: original])

        let incoming = try Self.v11Result()
        try await repository.save(incoming)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "removed only after the import commit")
        let index = try BenchmarkV7HistoryStoreProbe.index(for: url)
        XCTAssertEqual(index.schema, BenchmarkV7HistoryRepository.indexSchema)
        XCTAssertEqual(index.importedLegacySHA256, MSeriesV11Digest.sha256(original))
        XCTAssertEqual(index.entries.count, 4)
        let stored = try BenchmarkV7HistoryStoreProbe.records(for: url)
        XCTAssertEqual(Array(stored.prefix(3)), legacy, "imported in their original order, unchanged")
        XCTAssertEqual(stored.last?.recordID, incoming.recordID)
        // One file per record plus the index; no temporary file is left.
        let files = try BenchmarkV7HistoryStoreProbe.files(for: url).keys.sorted()
        XCTAssertEqual(files.count, 5)
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".json") })

        // A copy of the single file left by an interrupted removal is the
        // already imported history: it is neither shown twice nor imported again.
        try original.write(to: url)
        let again = await repository.load()
        XCTAssertEqual(again.count, 4)
        try await repository.save(try Self.v11Result())
        XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.index(for: url).entries.count, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedImportCommitLeavesTheSingleFileAndNoStoreRecords() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("benchmark-v7-history.json")
        let legacy = Self.legacyHistory(count: 3, paddingEach: 1_000)
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: url)
        for failingWrite in 1...5 {
            let counter = HistoryWriteCounter()
            let repository = BenchmarkV7HistoryRepository(storageURL: url, dataWriter: { data, target in
                counter.writes += 1
                if counter.writes == failingWrite { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: target, options: [.atomic])
            })
            do {
                try await repository.save(try Self.v11Result())
                XCTFail("write \(failingWrite) must fail the save")
            } catch {}
            XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.files(for: url), [url.lastPathComponent: original],
                "write \(failingWrite): nothing but the untouched single file remains")
            let loaded = await BenchmarkV7HistoryRepository(storageURL: url).load()
            XCTAssertEqual(Set(loaded.compactMap(\.recordID)), Set(legacy.compactMap(\.recordID)))
        }
    }

    /// After a downgrade the older app writes a new single-file history; the
    /// next write of this version imports it beside the existing store.
    func testSingleFileWrittenAfterImportIsMergedWithoutDuplicates() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("benchmark-v7-history.json")
        let first = Self.legacyHistory(count: 2, paddingEach: 100)
        try JSONEncoder().encode(first).write(to: url)
        let repository = BenchmarkV7HistoryRepository(storageURL: url)
        try await repository.save(try Self.v11Result())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let downgraded = Self.legacyHistory(count: 1, paddingEach: 100)
        try JSONEncoder().encode(first.prefix(1) + downgraded).write(to: url)
        let merged = await repository.load()
        XCTAssertEqual(merged.count, 4, "the repeated record is shown once")
        try await repository.save(try Self.v11Result())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let stored = try BenchmarkV7HistoryStoreProbe.records(for: url)
        XCTAssertEqual(stored.count, 5)
        XCTAssertEqual(Set(stored.compactMap(\.recordID)).count, 5)
        XCTAssertTrue(stored.contains(downgraded[0]))
    }

    func testSaveAtCapacityIsRefusedUntilARecordIsDeleted() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("benchmark-v7-history.json")
        let limit = BenchmarkV7HistoryRepository.maximumRecordCount
        XCTAssertEqual(limit, 1_000)
        let records = Self.legacyHistory(count: limit, paddingEach: 0)
        try Self.writeStore(records, for: url)
        let repository = BenchmarkV7HistoryRepository(storageURL: url)
        let loaded = await repository.load()
        XCTAssertEqual(loaded.count, limit)
        let before = try BenchmarkV7HistoryStoreProbe.files(for: url)
        let incoming = try Self.v11Result()
        do {
            try await repository.save(incoming)
            XCTFail("a full history must refuse the save")
        } catch let error as BenchmarkV7HistoryError {
            XCTAssertEqual(error, .capacityReached)
        }
        XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.files(for: url), before, "no older record is dropped to make room")
        let deleted = try await repository.delete(recordID: XCTUnwrap(records[0].recordID))
        XCTAssertTrue(deleted)
        try await repository.save(incoming)
        let after = await repository.load()
        XCTAssertEqual(after.count, limit)
        XCTAssertTrue(after.contains { $0.recordID == incoming.recordID })
        XCTAssertFalse(after.contains { $0.recordID == records[0].recordID })
    }

    func testDamagedStoreBlocksWritesAndIsReportedCorrupt() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        for damage in ["record bytes", "index json", "missing record", "linked record"] {
            let url = root.appendingPathComponent("damaged-\(damage.replacingOccurrences(of: " ", with: "-")).json")
            let repository = BenchmarkV7HistoryRepository(storageURL: url)
            try await repository.save(try Self.v11Result())
            try await repository.save(try Self.v11Result())
            let store = BenchmarkV7HistoryStoreProbe.storeURL(for: url)
            let entry = try XCTUnwrap(BenchmarkV7HistoryStoreProbe.index(for: url).entries.first)
            let recordURL = store.appendingPathComponent(entry.file)
            switch damage {
            case "record bytes":
                var data = try Data(contentsOf: recordURL)
                data[data.index(before: data.endIndex)] = UInt8(ascii: " ")
                try data.write(to: recordURL)
            case "index json":
                try Data("{".utf8).write(to: BenchmarkV7HistoryRepository.indexURL(forStorageURL: url))
            case "missing record":
                try FileManager.default.removeItem(at: recordURL)
            default:
                let moved = root.appendingPathComponent("moved-\(entry.file)")
                try FileManager.default.moveItem(at: recordURL, to: moved)
                try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: moved)
            }
            let before = try BenchmarkV7HistoryStoreProbe.files(for: url)
            let fresh = BenchmarkV7HistoryRepository(storageURL: url)
            let loaded = await fresh.load()
            XCTAssertEqual(loaded, [], damage)
            let status = await fresh.loadStatus()
            XCTAssertEqual(status, .corrupt, damage)
            do {
                try await fresh.save(try Self.v11Result())
                XCTFail("\(damage): a damaged store must refuse writes")
            } catch let error as BenchmarkV7HistoryError {
                XCTAssertEqual(error, .corrupt, damage)
            }
            XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.files(for: url), before, damage)
        }
    }

    func testReplaceAndDeleteRewriteOnlyTheIndexAndTheChangedRecord() async throws {
        let root = try TestFileSystem.makeHome(for: self)
        let url = root.appendingPathComponent("benchmark-v7-history.json")
        let repository = BenchmarkV7HistoryRepository(storageURL: url)
        let kept = Self.legacyHistory(count: 1, paddingEach: 10)[0]
        let original = try Self.v11Result()
        try await repository.save(kept)
        try await repository.save(original)
        let keptBytes = try BenchmarkV7HistoryStoreProbe.recordData(for: url, recordID: kept.recordID)
        let replacement = try Self.v11Result()
        try await repository.replace(recordID: XCTUnwrap(original.recordID), with: replacement)
        XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.recordData(for: url, recordID: kept.recordID), keptBytes)
        var stored = try BenchmarkV7HistoryStoreProbe.records(for: url)
        XCTAssertEqual(stored.map(\.recordID), [kept.recordID, replacement.recordID], "a replacement keeps its position")
        let commit = try BenchmarkV7HistoryStoreProbe.commitBytes(for: url, recordID: replacement.recordID)
        XCTAssertEqual(stored.last?.mSeriesV11?.metadataWrittenBytes, UInt64(commit * 2))
        XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.files(for: url).count, 3, "the replaced record's file is removed")

        let deleted = try await repository.delete(recordID: XCTUnwrap(replacement.recordID))
        XCTAssertTrue(deleted)
        stored = try BenchmarkV7HistoryStoreProbe.records(for: url)
        XCTAssertEqual(stored, [kept])
        XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.files(for: url).count, 2)
        XCTAssertEqual(try BenchmarkV7HistoryStoreProbe.recordData(for: url, recordID: kept.recordID), keptBytes)
    }

    // MARK: - Fixtures

    static func legacyHistory(count: Int, paddingEach: Int) -> [BenchmarkV7Result] {
        let template = MSeriesV11TestFixtures.result()
        return (0..<count).map { index in
            BenchmarkV7Result(recordID: UUID(), mSeries: template.mSeries, session: template.session,
                preflight: template.preflight, versions: template.versions, metrics: [], coreScore: nil,
                runtimeWarnings: paddingEach > 0 ? [String(repeating: "x", count: paddingEach)] : [],
                completedAt: template.completedAt.map { $0.addingTimeInterval(TimeInterval(-index)) }, failure: nil)
        }
    }

    static func v11Result() throws -> BenchmarkV7Result {
        var envelope = MSeriesV11Result(sessionID: UUID(), extensionContractHash: MSeriesV11Protocol.contractHash,
            rawPayloadSHA256: "", mode: "pressure10m")
        envelope.metadataWrittenBytes = 0
        envelope.writtenBytes = 0
        let sealed = try MSeriesV11RawPayload.seal(core: nil, envelope: envelope)
        let preflight = MSeriesV11TestFixtures.result().preflight
        let result = BenchmarkV7Result(mSeriesV11: sealed,
            session: .init(id: sealed.sessionID, plan: MSeriesV11Protocol.plan(mode: "pressure10m"),
                storageTarget: preflight.storageTarget),
            preflight: preflight, versions: MSeriesV11Protocol.versions(mode: "pressure10m"), metrics: [], coreScore: nil,
            completedAt: Date(), failure: nil)
        XCTAssertTrue(result.isPersistable)
        return result
    }

    /// Writes a committed store directly, as a long-used installation has it.
    static func writeStore(_ records: [BenchmarkV7Result], for storageURL: URL) throws {
        let store = BenchmarkV7HistoryStoreProbe.storeURL(for: storageURL)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var entries: [[String: Any]] = []
        for record in records {
            let data = try encoder.encode(record)
            let file = "\(UUID().uuidString).json"
            try data.write(to: store.appendingPathComponent(file))
            entries.append(["file": file, "bytes": data.count, "sha256": MSeriesV11Digest.sha256(data)])
        }
        let index: [String: Any] = ["schema": BenchmarkV7HistoryRepository.indexSchema, "entries": entries]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
            .write(to: BenchmarkV7HistoryRepository.indexURL(forStorageURL: storageURL))
    }
}

/// Counts the repository's injected writes (one actor-isolated caller).
private final class HistoryWriteCounter: @unchecked Sendable {
    var writes = 0
}
