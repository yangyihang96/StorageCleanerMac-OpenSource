import Darwin
import XCTest
@testable import StorageCleanerMac

final class MigrationVerificationReuseTests: XCTestCase {
    func testHandlingOriginalReusesCopyProofAcrossBothReceiptChecks() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let copied = try fixture.migrate()
        let proof = try XCTUnwrap(copied.contentVerification)
        let probe = ContentReadProbe()
        let reader = GuardedFileContentReader(priority: .userInitiated, willRead: { _ in probe.recordRead() })
        let trash = fixture.root.appendingPathComponent("simulated-trash.bin")
        let moved = try ExternalDriveMigrationService.moveOriginalToTrash(fixture.item,
            verifiedCopyAt: copied.destinationURL, on: fixture.volume, trustedVolumes: [fixture.volume],
            trashOperation: { url in try FileManager.default.moveItem(at: url, to: trash); return trash },
            journal: CleanupReportJournal(directory: fixture.root.appendingPathComponent("journal")),
            contentVerification: proof, contentReader: reader)
        XCTAssertTrue(moved.didMoveSourceToTrash)
        XCTAssertTrue(moved.canRestoreFromHistory)
        XCTAssertEqual(probe.reads, 0, "Unchanged content must not be hashed three more times")
        XCTAssertEqual(try Data(contentsOf: trash), fixture.contents)
    }

    func testMissingProofHashesEachFileOnceAndReusesItDuringJournalValidation() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let copied = try fixture.migrate()
        let probe = ContentReadProbe()
        let reader = GuardedFileContentReader(willRead: { _ in probe.recordRead() })
        let trash = fixture.root.appendingPathComponent("simulated-trash.bin")
        let moved = try ExternalDriveMigrationService.moveOriginalToTrash(fixture.item,
            verifiedCopyAt: copied.destinationURL, on: fixture.volume, trustedVolumes: [fixture.volume],
            trashOperation: { url in try FileManager.default.moveItem(at: url, to: trash); return trash },
            journal: CleanupReportJournal(directory: fixture.root.appendingPathComponent("journal")), contentReader: reader)
        XCTAssertTrue(moved.canRestoreFromHistory)
        XCTAssertEqual(probe.reads, 2)
    }

    func testReceiptCheckpointMutationInvalidatesTheReusedProofEvenIfSizeAndMtimeAreRestored() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let copied = try fixture.migrate()
        let proof = try XCTUnwrap(copied.contentVerification)
        var status = stat()
        XCTAssertEqual(lstat(copied.destinationURL.path, &status), 0)
        let times = [status.st_atimespec, status.st_mtimespec]
        let probe = ContentReadProbe()
        XCTAssertThrowsError(try ExternalDriveMigrationService.moveOriginalToTrash(fixture.item,
            verifiedCopyAt: copied.destinationURL, on: fixture.volume, trustedVolumes: [fixture.volume],
            trashOperation: { _ in XCTFail("Changed copy must never move the original"); return nil },
            persist: { _, _ in
                try Data(repeating: 0x59, count: fixture.contents.count).write(to: copied.destinationURL)
                let restored = times.withUnsafeBufferPointer {
                    utimensat(AT_FDCWD, copied.destinationURL.path, $0.baseAddress, AT_SYMLINK_NOFOLLOW)
                }
                XCTAssertEqual(restored, 0)
            }, contentVerification: proof,
            contentReader: .init(willRead: { _ in probe.recordRead() }))) {
            XCTAssertEqual($0 as? ExternalDriveMigrationError, .copyVerificationFailed)
        }
        XCTAssertGreaterThan(probe.reads, 0, "A changed ctime invalidates the saved digest")
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testCancellationAfterMoveStartsStillRecordsTheCompletedMove() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let copied = try fixture.migrate()
        let trash = fixture.root.appendingPathComponent("simulated-trash.bin")
        let result = try await Task.detached {
            try ExternalDriveMigrationService.moveOriginalToTrash(fixture.item,
                verifiedCopyAt: copied.destinationURL, on: fixture.volume, trustedVolumes: [fixture.volume],
                trashOperation: { url in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try FileManager.default.moveItem(at: url, to: trash)
                    return trash
                }, journal: CleanupReportJournal(directory: fixture.root.appendingPathComponent("journal")),
                contentVerification: copied.contentVerification)
        }.value
        XCTAssertTrue(result.didMoveSourceToTrash)
        XCTAssertTrue(result.canRestoreFromHistory)
        XCTAssertEqual(result.report?.summary.unverifiedMoveCount, 0)
    }
}
