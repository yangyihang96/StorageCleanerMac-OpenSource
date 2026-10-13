import XCTest
@testable import StorageCleanerMac

final class OperationFileLockTests: XCTestCase {
    func testKernelLockExcludesAnotherProcessAndReleasesOnClose() throws {
        let f = try RecordedCleanupRecoveryTests.Fixture(); defer { f.remove() }
        let directory = f.journal.directory
        var held: OperationFileLock? = try OperationFileLock(directory: directory, name: "fixture.lock")
        func child() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", "open(my $f, '+<', $ARGV[0]) or exit 9; flock($f, 6) or exit 42; exit 0;", directory.appendingPathComponent("fixture.lock").path]
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        XCTAssertEqual(try child(), 42)
        withExtendedLifetime(held) {}
        held = nil
        XCTAssertEqual(try child(), 0)
    }

    func testRejectsSymlinkAndHardLinkLocks() throws {
        let f = try RecordedCleanupRecoveryTests.Fixture(); defer { f.remove() }
        let target = f.journal.directory.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let symlink = f.journal.directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertThrowsError(try OperationFileLock(directory: f.journal.directory, name: "symlink"))
        try FileManager.default.linkItem(at: target, to: f.journal.directory.appendingPathComponent("hardlink"))
        XCTAssertThrowsError(try OperationFileLock(directory: f.journal.directory, name: "hardlink"))
    }

    func testStaleSequenceRejectedWithoutChangingDurableEvidence() throws {
        let f = try RecordedCleanupRecoveryTests.Fixture(); defer { f.remove() }
        let url = f.journal.reportURL(for: f.report.planID)
        let first = try f.journal.readWithEvents(url)
        var newer = first.entry.report
        newer.recoveryAttempts = [.init(completedAt: Date(), items: [.init(id: UUID(),
            originalPath: newer.items[0].sourcePath, outcome: .restored)], attemptID: UUID())]
        let sequence = try f.journal.checkpointVersioned(newer, expectedIdentities: [:], expectedSequence: first.sequence)
        XCTAssertEqual(sequence, first.sequence + 1)
        let bytes = try Data(contentsOf: CleanupJournalEvents.eventURL(for: url))
        XCTAssertThrowsError(try f.journal.checkpointVersioned(first.entry.report, expectedIdentities: [:], expectedSequence: first.sequence)) {
            guard case CleanupReportJournal.Failure.staleRevision = $0 else { return XCTFail("Expected stale revision, got \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: CleanupJournalEvents.eventURL(for: url)), bytes)
        XCTAssertEqual(try f.journal.read(url).report.recoveryAttempts?.last?.restoredCount, 1)
    }

    func testConcurrentWritersOnlyOneCommitsObservedRevision() throws {
        let f = try RecordedCleanupRecoveryTests.Fixture(); defer { f.remove() }
        let journal = f.journal
        let url = journal.reportURL(for: f.report.planID)
        let initial = try journal.readWithEvents(url)
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                _ = try journal.checkpointVersioned(initial.entry.report, expectedIdentities: [:],
                    expectedSequence: initial.sequence)
                results.add(success: true)
            } catch { results.add(success: false) }
        }
        XCTAssertEqual(results.successes, 1)
        let replay = try journal.readWithEvents(url)
        XCTAssertEqual(replay.sequence, initial.sequence + 1)
        XCTAssertFalse(replay.damagedSuffix)
        XCTAssertEqual(replay.entry.report.items, initial.entry.report.items)
    }

    private final class Results: @unchecked Sendable {
        let lock = NSLock()
        private var count = 0
        var successes: Int { lock.withLock { count } }
        func add(success: Bool) { lock.withLock { if success { count += 1 } } }
    }

    func testOperationLockSurvivesLeaseReleaseUntilQuarantinedWorkerEnds() async throws {
        let f = try RecordedCleanupRecoveryTests.Fixture(); defer { f.remove() }
        let first = HeavyWorkCoordinator(operationLockDirectory: f.journal.directory)
        let second = HeavyWorkCoordinator(operationLockDirectory: f.journal.directory)
        let lease = try await first.acquire(owner: .cleanup)
        let quarantine = try await first.beginCleanupQuarantine(lease)
        await first.release(lease)
        do { _ = try await second.acquire(owner: .restore); XCTFail("Quarantined worker must retain lock") }
        catch OperationFileLock.Failure.busy {} // expected
        await first.clearCleanupQuarantine(quarantine)
        let next = try await second.acquire(owner: .restore)
        await second.release(next)
    }
}
