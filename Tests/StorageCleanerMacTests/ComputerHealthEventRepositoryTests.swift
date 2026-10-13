import Foundation
import XCTest
@testable import StorageCleanerMac

final class ComputerHealthEventRepositoryTests: XCTestCase {
    private func storageURL() throws -> URL {
        try TestFileSystem.makeHome(for: self).appendingPathComponent("health-events.json")
    }

    func testFirstCheckAndUnchangedStateDoNotCreateEvents() async throws {
        let repository = ComputerHealthEventRepository(storageURL: try storageURL())
        let first = try await repository.record(ComputerHealthSecurityFixture.snapshot())
        let unchanged = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 1,
            availableBytes: 190 * 1_073_741_824, securityEvidence: "changed evidence"))
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(unchanged.isEmpty)
    }

    func testChangedSecurityAndSMARTStoreTimeDirectionAndSummary() async throws {
        let repository = ComputerHealthEventRepository(storageURL: try storageURL())
        _ = try await repository.record(ComputerHealthSecurityFixture.snapshot(securityState: .disabled))
        let events = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 1,
            securityState: .enabled, smart: .failing))
        XCTAssertEqual(events.count, 5)
        let fileVault = try XCTUnwrap(events.first { $0.check == .fileVault })
        XCTAssertEqual(fileVault.oldState, .disabled)
        XCTAssertEqual(fileVault.newState, .enabled)
        XCTAssertEqual(fileVault.recordedAt, ComputerHealthSecurityFixture.date.addingTimeInterval(1))
        XCTAssertFalse(fileVault.evidenceSummary.isEmpty)
        let disk = try XCTUnwrap(events.first { $0.check == .disk })
        XCTAssertEqual(disk.oldState, .normal)
        XCTAssertEqual(disk.newState, .warning)
        // Same level and wording as the result row (warning symbol, “故障警告”).
        XCTAssertEqual(HealthRecentChangesView.status(for: disk.newState), .warning)
        XCTAssertEqual(disk.newState.title(for: .disk), L10n.text("故障警告", "Failure warning"))
        XCTAssertEqual(disk.evidence, .status)
    }

    func testLastBaselineAndEventsSurviveRepositoryRecreationWithoutDuplicateChanges() async throws {
        let url = try storageURL()
        let first = ComputerHealthEventRepository(storageURL: url)
        _ = try await first.record(ComputerHealthSecurityFixture.snapshot())
        let expected = try await first.record(ComputerHealthSecurityFixture.snapshot(offset: 1, securityState: .disabled))
        let second = ComputerHealthEventRepository(storageURL: url)
        let loaded = try await second.load()
        let unchanged = try await second.record(ComputerHealthSecurityFixture.snapshot(offset: 2, securityState: .disabled))
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(unchanged, expected)
    }

    func testRollsAtTwoHundredNewestChangesIncludingChangesWithinOneDay() async throws {
        let url = try storageURL()
        let repository = ComputerHealthEventRepository(storageURL: url)
        _ = try await repository.record(ComputerHealthSecurityFixture.snapshot())
        var latest: [ComputerHealthChangeEvent] = []
        for index in 1...55 {
            latest = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: Double(index),
                securityState: index.isMultiple(of: 2) ? .enabled : .disabled))
        }
        XCTAssertEqual(latest.count, 200)
        XCTAssertEqual(latest.first?.recordedAt, ComputerHealthSecurityFixture.date.addingTimeInterval(55))
        XCTAssertEqual(latest.last?.recordedAt, ComputerHealthSecurityFixture.date.addingTimeInterval(6))
        let loaded = try await ComputerHealthEventRepository(storageURL: url).load()
        XCTAssertEqual(loaded, latest)
    }

    func testStorageRootsAreIsolatedAndOnlyStructuredEvidenceIsPersisted() async throws {
        let firstURL = try storageURL()
        let secondURL = try storageURL()
        let first = ComputerHealthEventRepository(storageURL: firstURL)
        let second = ComputerHealthEventRepository(storageURL: secondURL)
        _ = try await first.record(ComputerHealthSecurityFixture.snapshot())
        _ = try await first.record(ComputerHealthSecurityFixture.snapshot(offset: 1, smart: .failing))
        let isolated = try await second.record(ComputerHealthSecurityFixture.snapshot(offset: 2))
        XCTAssertTrue(isolated.isEmpty)
        let text = try String(contentsOf: firstURL, encoding: .utf8)
        XCTAssertFalse(text.contains("private-volume"))
        XCTAssertFalse(text.contains("private-backup"))
        XCTAssertFalse(text.contains("csrutil"))
        XCTAssertNotEqual(firstURL, ComputerHealthEventRepository.defaultStorageURL)
    }

    /// Review P2-2 (replaces the earlier “unknown/unreadable are distinct
    /// changes” assertions): indeterminate reads neither log nor replace the
    /// last determinate state, so load/timeout noise cannot fill the log.
    func testUnknownAndUnreadableNeverLogAndDoNotReplaceTheDeterminateBaseline() async throws {
        let repository = ComputerHealthEventRepository(storageURL: try storageURL())
        _ = try await repository.record(ComputerHealthSecurityFixture.snapshot())
        for (offset, state) in [(1.0, SystemProtectionState.unreadable), (2, .unknown), (3, .unreadable), (4, .enabled)] {
            let events = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: offset, securityState: state))
            XCTAssertTrue(events.isEmpty, "\(state)")
        }
        _ = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 5, securityState: .unreadable))
        let changed = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 6, securityState: .disabled))
        XCTAssertEqual(changed.count, 4)
        XCTAssertTrue(changed.allSatisfy { $0.oldState == .enabled && $0.newState == .disabled })
        let unreadableFirst = ComputerHealthEventRepository(storageURL: try storageURL())
        _ = try await unreadableFirst.record(ComputerHealthSecurityFixture.snapshot(securityState: .unreadable))
        let baseline = try await unreadableFirst.record(ComputerHealthSecurityFixture.snapshot(offset: 1, securityState: .enabled))
        XCTAssertTrue(baseline.isEmpty, "The first determinate read only establishes the baseline")
    }

    @MainActor
    func testLegacyTextJournalStillDecodesAndStructuredEvidenceFollowsTheDisplayLanguage() async throws {
        let url = try storageURL()
        let legacy = #"{"checkedAt":0,"events":[{"check":"firewall","evidenceSummary":"旧版证据","id":"00000000-0000-0000-0000-0000000000B1","newState":"disabled","oldState":"enabled","recordedAt":-1}],"previous":[{"check":"firewall","evidenceSummary":"旧版基线","state":"disabled"}],"version":1}"#
        try Data(legacy.utf8).write(to: url)
        let repository = ComputerHealthEventRepository(storageURL: url)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.first?.evidence, .legacy("旧版证据"))
        let events = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 10, securityState: .enabled))
        let firewall = try XCTUnwrap(events.first { $0.check == .firewall && $0.newState == .enabled })
        XCTAssertEqual(firewall.evidence, .security(.systemQuery))
        XCTAssertEqual(events.last?.evidenceSummary, "旧版证据")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("系统查询"))
        XCTAssertFalse(text.contains("Confirmed"))
        let reloaded = try await repository.load()
        let stored = try XCTUnwrap(reloaded.first { $0.check == .firewall && $0.newState == .enabled })
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            XCTAssertEqual(stored.evidenceSummary,
                language == .zhHans ? "系统查询确认（socketfilterfw --getglobalstate）"
                    : "Confirmed by socketfilterfw --getglobalstate")
            XCTAssertEqual(reloaded.last?.evidenceSummary, "旧版证据")
        }
    }

    func testStaleCompletionAndMissingCheckDoNotRollBaselineBack() async throws {
        let repository = ComputerHealthEventRepository(storageURL: try storageURL())
        _ = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 2))
        let stale = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 1, securityState: .disabled))
        let missing = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 3, securityState: nil))
        let next = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 4))
        XCTAssertTrue(stale.isEmpty)
        XCTAssertTrue(missing.isEmpty)
        XCTAssertTrue(next.isEmpty)
    }

    func testCancelledRecordDoesNotWriteOrAdvanceBaseline() async throws {
        let url = try storageURL()
        let repository = ComputerHealthEventRepository(storageURL: url)
        let task = Task {
            withUnsafeCurrentTask { task -> Void in task?.cancel() }
            return try await repository.record(ComputerHealthSecurityFixture.snapshot())
        }
        do { _ = try await task.value; XCTFail("Cancelled record must throw") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let first = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 1, securityState: .disabled))
        XCTAssertTrue(first.isEmpty)
    }

    /// Review P2-3 (replaces “corrupt journal fails without writing”): the
    /// original bytes are kept as `.corrupt-<time>` and a baseline restarts.
    func testCorruptOrUnknownVersionJournalIsKeptAsideAndBaselineRestarts() async throws {
        for invalid in [Data("corrupt-journal".utf8), Data(#"{"version":9,"previous":[],"events":[]}"#.utf8)] {
            let url = try storageURL()
            try invalid.write(to: url)
            let repository = ComputerHealthEventRepository(storageURL: url)
            let recording = try await repository.recordChanges(ComputerHealthSecurityFixture.snapshot())
            XCTAssertTrue(recording.recoveredUnrecognizedJournal)
            XCTAssertTrue(recording.events.isEmpty)
            let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            let backups = siblings.filter { $0.hasPrefix(url.lastPathComponent + ".corrupt-") }
            XCTAssertEqual(backups.count, 1)
            let backup = url.deletingLastPathComponent().appendingPathComponent(try XCTUnwrap(backups.first))
            XCTAssertEqual(try Data(contentsOf: backup), invalid, "The original journal is never overwritten")
            XCTAssertNotEqual(try Data(contentsOf: url), invalid)
            let next = try await repository.recordChanges(ComputerHealthSecurityFixture.snapshot(offset: 1, securityState: .disabled))
            XCTAssertFalse(next.recoveredUnrecognizedJournal)
            XCTAssertEqual(next.events.count, 4)
        }
    }

    func testRepeatedCorruptionNeverOverwritesAnEarlierBackup() async throws {
        let url = try storageURL()
        let repository = ComputerHealthEventRepository(storageURL: url)
        let originals = [Data("first-corrupt-journal".utf8), Data("second-corrupt-journal".utf8)]
        var firstBackup: URL?
        for (index, original) in originals.enumerated() {
            try original.write(to: url)
            let recording = try await repository.recordChanges(ComputerHealthSecurityFixture.snapshot(offset: Double(index)))
            XCTAssertTrue(recording.recoveredUnrecognizedJournal)
            let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt-") }
            XCTAssertEqual(backups.count, index + 1)
            let bytes = try backups.map { try Data(contentsOf: $0) }
            XCTAssertTrue(bytes.contains(original))
            if let firstBackup {
                XCTAssertEqual(try Data(contentsOf: firstBackup), originals[0])
            } else {
                firstBackup = try XCTUnwrap(backups.first)
            }
        }
    }

    func testEvidenceIsBoundedAndAllExistingChecksCanEmitChanges() async throws {
        let repository = ComputerHealthEventRepository(storageURL: try storageURL())
        _ = try await repository.record(ComputerHealthSecurityFixture.snapshot())
        let events = try await repository.record(ComputerHealthSecurityFixture.snapshot(offset: 1,
            securityState: .disabled, availableBytes: 190 * 1_073_741_824,
            securityEvidence: String(repeating: "evidence ", count: 500),
            stabilityStatus: .attention, backupStatus: .attention, capacityStatus: .attention,
            batteryEvidence: .failed(reason: .unavailable, checkedAt: ComputerHealthSecurityFixture.date)))
        // Battery notApplicable → unreadable is indeterminate and not logged (review P2-2).
        XCTAssertEqual(Set(events.map(\.check)), [.systemIntegrityProtection, .fileVault, .gatekeeper, .firewall,
            .stability, .backup, .capacity])
        XCTAssertTrue(events.allSatisfy { $0.evidenceSummary.count <= 256 })
    }

    func testUnreadableJournalPathDoesNotOverwriteBlockingFile() async throws {
        let home = try TestFileSystem.makeHome(for: self)
        let blocker = home.appendingPathComponent("blocked-directory")
        try Data("fixture".utf8).write(to: blocker)
        let repository = ComputerHealthEventRepository(storageURL: blocker.appendingPathComponent("health-events.json"))
        do { _ = try await repository.record(ComputerHealthSecurityFixture.snapshot()); XCTFail("A file cannot be a journal directory") }
        catch { XCTAssertNotEqual((error as NSError).code, 0) }
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "fixture")
    }
}
