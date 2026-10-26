import Foundation
import XCTest
@testable import StorageCleanerMac

/// Reads the D95 per-record benchmark history from disk directly, so tests
/// check the files themselves rather than the repository under test.
enum BenchmarkV7HistoryStoreProbe {
    struct Index: Decodable, Equatable {
        struct Entry: Decodable, Equatable {
            let file: String
            let bytes: Int
            let sha256: String
        }

        let schema: String
        let entries: [Entry]
        let importedLegacySHA256: String?
    }

    static func storeURL(for storageURL: URL) -> URL {
        BenchmarkV7HistoryRepository.recordStoreURL(forStorageURL: storageURL)
    }

    /// Every file of one history: the single-file layout and the record
    /// store, keyed by their path relative to the history's directory.
    static func files(for storageURL: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: storageURL.path) {
            files[storageURL.lastPathComponent] = try Data(contentsOf: storageURL)
        }
        let store = storeURL(for: storageURL)
        if fileManager.fileExists(atPath: store.path) {
            for name in try fileManager.contentsOfDirectory(atPath: store.path) {
                files[store.lastPathComponent + "/" + name] = try Data(contentsOf: store.appendingPathComponent(name))
            }
        }
        return files
    }

    static func indexData(for storageURL: URL) throws -> Data {
        try Data(contentsOf: BenchmarkV7HistoryRepository.indexURL(forStorageURL: storageURL))
    }

    static func index(for storageURL: URL) throws -> Index {
        try JSONDecoder().decode(Index.self, from: indexData(for: storageURL))
    }

    /// The committed record files, in index order.
    static func recordData(for storageURL: URL) throws -> [Data] {
        let store = storeURL(for: storageURL)
        return try index(for: storageURL).entries.map { try Data(contentsOf: store.appendingPathComponent($0.file)) }
    }

    static func records(for storageURL: URL) throws -> [BenchmarkV7Result] {
        try recordData(for: storageURL).map { try JSONDecoder().decode(BenchmarkV7Result.self, from: $0) }
    }

    /// The committed file of the record with `recordID`.
    static func recordData(for storageURL: URL, recordID: UUID?) throws -> Data {
        let match = try recordData(for: storageURL).first {
            try JSONDecoder().decode(BenchmarkV7Result.self, from: $0).recordID == recordID
        }
        return try XCTUnwrap(match, "no committed file for record \(String(describing: recordID))")
    }

    /// Bytes one v11 save commits: its record file and the index.
    static func commitBytes(for storageURL: URL, recordID: UUID?) throws -> Int {
        try recordData(for: storageURL, recordID: recordID).count + indexData(for: storageURL).count
    }
}
