import Foundation
import XCTest
@testable import StorageCleanerMac

final class ResidualFileEvidenceScannerTests: XCTestCase {
    func testReportsOnlyUnmatchedExactBundleIDNamesAndDoesNotAlterFiles() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let unmatched = caches.appendingPathComponent("com.example.removed", isDirectory: true)
        let installed = caches.appendingPathComponent("com.example.active", isDirectory: true)
        let installedHelper = caches.appendingPathComponent("com.example.active.helper", isDirectory: true)
        let apple = caches.appendingPathComponent("com.apple.system", isDirectory: true)
        let ambiguous = caches.appendingPathComponent("example-app", isDirectory: true)
        for path in [unmatched, installed, installedHelper, apple, ambiguous] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let privatePayload = Data("keep this file".utf8)
        let payloadURL = unmatched.appendingPathComponent("data.bin")
        try privatePayload.write(to: payloadURL)

        let result = ResidualFileEvidenceScanner.scan(
            homeDirectory: home,
            installedBundleIdentifiers: ["com.example.active"]
        )

        XCTAssertEqual(result.candidates.map(\.bundleIdentifier), ["com.example.removed"])
        XCTAssertEqual(
            result.candidates.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
            [unmatched.resolvingSymlinksInPath().path]
        )
        XCTAssertEqual(try Data(contentsOf: payloadURL), privatePayload)
        XCTAssertFalse(result.reachedLimit)
        XCTAssertFalse(result.cancelled)
    }

    func testSymlinkedRootAndEntryAreNeverFollowed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let outside = try makeHome()
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideFile = outside.appendingPathComponent("com.example.outside")
        try Data("outside".utf8).write(to: outsideFile)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: caches.appendingPathComponent("com.example.link"),
            withDestinationURL: outsideFile
        )
        let logs = home.appendingPathComponent("Library/Logs")
        try FileManager.default.removeItem(at: logs)
        try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: outside)

        let result = ResidualFileEvidenceScanner.scan(
            homeDirectory: home,
            installedBundleIdentifiers: []
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertGreaterThanOrEqual(result.unreadableRootCount, 1)
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside".utf8))
    }

    func testLimitIsReportedInsteadOfClaimingCompleteCoverage() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(
            at: caches.appendingPathComponent("com.example.one"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: caches.appendingPathComponent("com.example.two"),
            withIntermediateDirectories: true
        )

        let result = ResidualFileEvidenceScanner.scan(
            homeDirectory: home,
            installedBundleIdentifiers: [],
            maximumEntries: 1
        )

        XCTAssertTrue(result.reachedLimit)
        XCTAssertEqual(result.inspectedEntryCount, 1)
        XCTAssertEqual(result.candidates.count, 1)
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResidualFileEvidence-\(UUID().uuidString)", isDirectory: true)
        for path in ["Library/Caches", "Library/Logs", "Library/Saved Application State", "Library/HTTPStorages"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return home
    }
}
