import Foundation
import XCTest
@testable import StorageCleanerMac

final class InvokedMigrationMoveTests: XCTestCase {
    func testCancellationInFinalMetadataCheckStillInvokesProductionMoveAndRecordsIt() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let copied = try fixture.migrate()
        let trash = fixture.root.appendingPathComponent("simulated-trash.bin")
        let metadata = CancellingSnapshots(source: fixture.file, cancelOnCall: 5)
        let moved = try await Task.detached {
            try ExternalDriveMigrationService.moveOriginalToTrash(fixture.item,
                verifiedCopyAt: copied.destinationURL, on: fixture.volume, trustedVolumes: [fixture.volume],
                trashOperation: { url in
                    XCTAssertTrue(Task.isCancelled, "Cancellation must occur before the production move closure starts")
                    try FileManager.default.moveItem(at: url, to: trash)
                    return trash
                }, journal: CleanupReportJournal(directory: fixture.root.appendingPathComponent("journal")),
                contentVerification: copied.contentVerification, metadata: metadata)
        }.value
        XCTAssertEqual(metadata.callsAtCancellation, 5)
        XCTAssertTrue(moved.didMoveSourceToTrash)
        XCTAssertTrue(moved.canRestoreFromHistory)
        XCTAssertEqual(moved.report?.summary.unverifiedMoveCount, 0)
        XCTAssertEqual(try Data(contentsOf: trash), fixture.contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    /// Production captures identity once, then validates its source snapshot
    /// and RecordedTrashOperation's identity twice (1 + 2 + 2). Call five is
    /// after its last cancellation check, just before invokedMove becomes true.
    private final class CancellingSnapshots: ReadOnlyFileSystem, @unchecked Sendable {
        private let source: URL
        private let cancelOnCall: Int
        private let base = FoundationReadOnlyFileSystem()
        private let lock = NSLock()
        private var sourceCalls = 0
        private var cancelledAt = 0
        var callsAtCancellation: Int { lock.withLock { cancelledAt } }
        init(source: URL, cancelOnCall: Int) { self.source = source; self.cancelOnCall = cancelOnCall }
        func snapshot(at url: URL) throws -> FileSnapshot {
            if url == source {
                let shouldCancel = lock.withLock {
                    sourceCalls += 1
                    if sourceCalls == cancelOnCall { cancelledAt = sourceCalls; return true }
                    return false
                }
                if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return try base.snapshot(at: url)
        }
        func aggregateSnapshot(at url: URL) throws -> FileSnapshot { try base.aggregateSnapshot(at: url) }
        func children(of directory: URL) throws -> [URL] { try base.children(of: directory) }
        func symbolicLinkDestination(of url: URL) throws -> String { try base.symbolicLinkDestination(of: url) }
    }
}
