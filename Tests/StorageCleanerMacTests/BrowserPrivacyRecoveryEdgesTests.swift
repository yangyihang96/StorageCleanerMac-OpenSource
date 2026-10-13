import Darwin
import Foundation
import XCTest
@testable import StorageCleanerMac

/// N12: all databases, clocks, exclusion writers and interleavings are fixtures.
/// No preferences, browser installations or system backup settings are used.
@MainActor
final class BrowserPrivacyRecoveryEdgesTests: XCTestCase {
    func testRestoreSourceIsProtectedDuringCopyAndBeforeTheRestoredMarker() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture, maximumBackups: 2)
        let source = try await backup(fixture, service: service, outcome: .deleted)
        try setCreatedAt(Date().addingTimeInterval(-5 * 86_400), backup: source)
        _ = try await backup(fixture, service: service, outcome: .deleted)
        let entry = try XCTUnwrap(service.entries().first { $0.id == source.id })
        // Make the actual destination different from the source.
        try fixture.execute("DELETE FROM visits WHERE id = 21")
        let beforeCopy = RecoveryPause()
        let afterCopy = RecoveryPause()
        let double = PausingRecoveryService(base: service, beforeCopy: beforeCopy, afterCopy: afterCopy)
        let processor = fixture.processor(backupService: double)
        let store = BrowserPrivacyRecoveryStore(
            service: service, processor: processor,
            installedApplications: [try XCTUnwrap(fixture.installedApplication)]
        )
        let restoration = Task {
            await store.restore(entry)
            // Also wake entry waiters if a regression returns before reaching
            // either pause, so counterproofs fail assertions instead of hanging.
            await beforeCopy.resume()
            await afterCopy.resume()
        }
        // A failed assertion must not strand the task in a continuation.
        defer { Task { await beforeCopy.resume(); await afterCopy.resume() } }

        await beforeCopy.waitUntilEntered()
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 21"), 0)
        let maintenance = makeService(fixture, maximumBackups: 2) // independent instance
        let future = entry.expiresAt.addingTimeInterval(1)
        let loop = BrowserPrivacyRecoveryPurgeLoop(
            service: maintenance, now: { future }, sleep: { _ in throw CancellationError() }
        )
        await loop.run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.databaseURL.path), "expiry must honor the active lease")
        XCTAssertFalse(maintenance.remove(backupID: source.id), "explicit removal shares the same lease")

        await beforeCopy.resume()
        await afterCopy.waitUntilEntered()
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 21"), 1, "copy has completed")
        XCTAssertNil(try XCTUnwrap(service.entries().first { $0.id == source.id }).restoredAt)
        await loop.run() // exact window after copy, before finishRestoring
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.databaseURL.path))
        await afterCopy.resume()
        await restoration.value

        XCTAssertTrue(try XCTUnwrap(store.lastResult).succeeded)
        XCTAssertNotNil(try XCTUnwrap(store.entries.first { $0.id == source.id }).restoredAt)
        XCTAssertEqual(service.purgeExpired(), 0)
        XCTAssertTrue(service.entries().contains { $0.id == source.id })
    }

    func testFailedFinalMarkerKeepsTheSourceOutOfTheCountLimitButStillExpires() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture, maximumBackups: 1)
        let source = try await backup(fixture, service: service, outcome: .deleted)
        try setCreatedAt(Date().addingTimeInterval(-86_400), backup: source)
        let entry = try XCTUnwrap(service.entries().first)
        try fixture.execute("DELETE FROM visits WHERE id = 21")
        let double = PausingRecoveryService(base: service, failFinalMarker: true)

        let result = await fixture.processor(backupService: double).restore(
            entry, installedApplications: [try XCTUnwrap(fixture.installedApplication)]
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.historyMayHaveChanged)
        XCTAssertNotNil(result.undoBackupID)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 21"), 1)
        XCTAssertNil(try XCTUnwrap(service.entries().first { $0.id == source.id }).restoredAt)
        XCTAssertEqual(try metadata(source)["restorePending"] as? Bool, true)
        XCTAssertEqual(makeService(fixture, maximumBackups: 1).purgeExpired(), 0)
        XCTAssertTrue(service.entries().contains { $0.id == source.id }, "the persistent marker survives lease release")
        service.purgeExpired(now: entry.expiresAt.addingTimeInterval(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.databaseURL.path), "a failed marker does not extend D26")
    }

    func testPruningRechecksAVictimRestoredBetweenSelectionAndLeaseAcquisition() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let base = makeService(fixture, maximumBackups: 1)
        let source = try await backup(fixture, service: base, outcome: .deleted)
        try setCreatedAt(Date().addingTimeInterval(-86_400), backup: source)
        _ = try await backup(fixture, service: base, outcome: .deleted, sparing: [source.id])
        let hookErrors = RecoveryObservations()
        let racing = makeService(fixture, maximumBackups: 1, beforeRemovalHook: { id in
            guard id == source.id else { return }
            do {
                let lease = try base.beginRestoring(source)
                defer { withExtendedLifetime(lease) {} }
                try base.finishRestoring(source)
            } catch {
                hookErrors.recordFailure()
            }
        })

        XCTAssertEqual(racing.purgeExpired(), 0)
        XCTAssertEqual(hookErrors.failureCount, 0)
        XCTAssertNotNil(try XCTUnwrap(base.entries().first { $0.id == source.id }).restoredAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.databaseURL.path), "a stale victim list is not permission to delete")
    }

    func testCleanupWinningBeforeTheRestoreLeaseNeverWritesTheDestination() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture)
        let source = try await backup(fixture, service: service, outcome: .deleted)
        let entry = try XCTUnwrap(service.entries().first)
        let before = try fixture.tableState()
        XCTAssertTrue(service.remove(backupID: source.id))

        let result = await fixture.processor(backupService: service).restore(
            entry, installedApplications: [try XCTUnwrap(fixture.installedApplication)]
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.historyMayHaveChanged)
        XCTAssertEqual(try fixture.tableState(), before)
        XCTAssertTrue(service.entries().isEmpty, "no undo backup is started without the source lease")
    }

    func testRestoreDuringDeletionAfterLeaseUnlinkNeverWritesTheDestination() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture)
        let source = try await backup(fixture, service: service, outcome: .deleted)
        let survivor = try await backup(fixture, service: service, outcome: .deleted)
        let entry = try XCTUnwrap(service.entries().first { $0.id == source.id })
        try fixture.execute("DELETE FROM visits WHERE id = 21")
        let before = try fixture.tableState()
        let pause = RecoveryDeletionPause()
        let deleting = makeService(fixture, removeTombstone: { directory in
            try FileManager.default.removeItem(at: directory.appendingPathComponent(SQLiteSnapshotService.leaseFileName))
            pause.pause(at: directory) // data and metadata still exist, lease path does not
            try FileManager.default.removeItem(at: directory)
        })
        let removal = Task.detached {
            let removed = deleting.remove(backupID: source.id)
            pause.removalFinished()
            return removed
        }
        defer { pause.resume() }
        let deletionDirectory = await pause.waitUntilEntered()
        let tombstone = try XCTUnwrap(deletionDirectory, "deletion must reach the lease-unlink interleaving")

        XCTAssertTrue(tombstone.lastPathComponent.hasPrefix(BrowserPrivacyRecoveryLease.tombstonePrefix))
        XCTAssertEqual(tombstone.deletingLastPathComponent().resolvingSymlinksInPath(), fixture.recoveryRoot.resolvingSymlinksInPath())
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.databaseURL.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.appendingPathComponent("History.backup.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.appendingPathComponent("metadata.json").path))
        XCTAssertEqual(service.entries().map(\.id), [survivor.id], "a tombstone is never restorable or listed")
        // The namespace lock must have been released before recursive deletion.
        let otherLease = try service.beginRestoring(survivor)
        otherLease?.release()

        let result = await fixture.processor(backupService: service).restore(
            entry, installedApplications: [try XCTUnwrap(fixture.installedApplication)]
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.historyMayHaveChanged)
        XCTAssertNil(result.undoBackupID, "the source lease fails before saving any undo state")
        XCTAssertEqual(try fixture.tableState(), before)
        XCTAssertEqual(service.entries().map(\.id), [survivor.id])
        XCTAssertThrowsError(try BrowserPrivacyRecoveryLease.acquire(in: tombstone))
        let retiredBackup = BrowserPrivacyRecoveryBackup(
            id: source.id, databaseURL: tombstone.appendingPathComponent("History.backup.sqlite"),
            sha256: source.sha256, createdAt: source.createdAt
        )
        XCTAssertThrowsError(try service.beginRestoring(retiredBackup))
        do {
            try await service.restore(
                retiredBackup,
                destination: SQLiteSnapshotSource(databaseURL: fixture.profile.historyDatabaseURL, trustedParentURL: fixture.profile.sourceTrustedParentURL),
                schema: BrowserPrivacySQLiteWriteAdapter.chromiumProduction.schema,
                deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
            )
            XCTFail("even the low-level restore rejects a tombstone path")
        } catch {
            XCTAssertEqual(error as? SQLitePersistentBackupFailure, .sourceRead(.unavailable))
        }
        XCTAssertEqual(try fixture.tableState(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.appendingPathComponent(SQLiteSnapshotService.leaseFileName).path), "no second lease is created in the deleting directory")
        pause.resume()
        let removed = await removal.value
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
    }

    func testMaintenanceFinishesInterruptedTombstonesWithoutFollowingLinks() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture)
        let source = try await backup(fixture, service: service, outcome: .deleted)
        let interrupted = makeService(fixture, removeTombstone: { directory in
            try FileManager.default.removeItem(at: directory.appendingPathComponent(SQLiteSnapshotService.leaseFileName))
            throw RemovalDoubleFailure()
        })
        XCTAssertFalse(interrupted.remove(backupID: source.id), "failure leaves only an irrecoverable tombstone")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path)
        let name = try XCTUnwrap(names.first { $0.hasPrefix(BrowserPrivacyRecoveryLease.tombstonePrefix) })
        let tombstone = fixture.recoveryRoot.appendingPathComponent(name, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.appendingPathComponent("History.backup.sqlite").path))
        XCTAssertTrue(service.entries().isEmpty)
        XCTAssertNil(service.earliestExpiry(), "tombstones do not reenter the seven-day schedule")
        XCTAssertThrowsError(try service.beginRestoring(source))
        XCTAssertThrowsError(try BrowserPrivacyRecoveryLease.acquire(in: tombstone))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.appendingPathComponent(SQLiteSnapshotService.leaseFileName).path))

        let outside = fixture.root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outside)
        let link = fixture.recoveryRoot.appendingPathComponent(BrowserPrivacyRecoveryLease.tombstonePrefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let foreign = fixture.recoveryRoot.appendingPathComponent(BrowserPrivacyRecoveryLease.tombstonePrefix + "not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)

        let maintenance = makeService(fixture) // a new service, as after restart
        XCTAssertEqual(maintenance.purgeExpired(), 1, "interrupted deletion is finished without waiting seven days")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertTrue(maintenance.entries().isEmpty)
        XCTAssertEqual(maintenance.purgeExpired(), 0)
    }

    func testLegacyBackupsStayVisibleAfterRestoringAndKeepTheirOriginalExpiry() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture)
        let createdAt = Date().addingTimeInterval(-5 * 86_400)
        let expiry = BrowserPrivacyBackupRetention.expiry(ofBackupCreatedAt: createdAt)
        var legacy: [BrowserPrivacyRecoveryBackup] = []
        for _ in 0 ..< 2 {
            let item = try await backup(fixture, service: service, outcome: nil)
            item.writingLease?.release()
            var description = try metadata(item)
            description["version"] = 1
            description["createdAt"] = createdAt.timeIntervalSinceReferenceDate
            description.removeValue(forKey: "continuousCreatedAt")
            description.removeValue(forKey: "bootSessionIdentifier")
            try writeMetadata(description, in: item.databaseURL.deletingLastPathComponent())
            // A real old-format directory can also predate lease files.
            try FileManager.default.removeItem(at: item.databaseURL.deletingLastPathComponent().appendingPathComponent(SQLiteSnapshotService.leaseFileName))
            legacy.append(item)
        }
        for (index, item) in legacy.enumerated() {
            let entry = try XCTUnwrap(service.entries().first { $0.id == item.id })
            XCTAssertNil(entry.summary)
            try fixture.execute("DELETE FROM visits WHERE id = 21")
            let result = await fixture.processor(backupService: service).restore(
                entry, installedApplications: [try XCTUnwrap(fixture.installedApplication)]
            )
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 21"), 1)
            let refreshed = try XCTUnwrap(makeService(fixture).entries().first { $0.id == item.id })
            XCTAssertNotNil(refreshed.restoredAt)
            XCTAssertNil(refreshed.summary)
            XCTAssertEqual(refreshed.createdAt, createdAt)
            XCTAssertEqual(refreshed.expiresAt, expiry)
            let description = try metadata(item)
            XCTAssertEqual(description["version"] as? Int, 3)
            XCTAssertNil(description["continuousCreatedAt"], "restoring cannot invent a creation clock")
            XCTAssertNil(description["bootSessionIdentifier"])
            XCTAssertEqual(service.purgeExpired(now: expiry.addingTimeInterval(-0.001)), 0)
            if index == 0 {
                XCTAssertTrue(service.remove(backupID: item.id), "the refreshed old backup can be manually deleted")
                XCTAssertFalse(service.entries().contains { $0.id == item.id })
            } else {
                XCTAssertEqual(service.purgeExpired(now: expiry), 1, "restoration never restarts the original seven days")
                XCTAssertFalse(FileManager.default.fileExists(atPath: item.databaseURL.path))
            }
        }
    }

    func testCountPruningDoesNotReadContentAtOrBelowTwelveCandidates() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let reads = RecoveryCountDigestReader()
        let service = makeService(fixture, countDigestReader: reads)
        var confirmed: [BrowserPrivacyRecoveryBackup] = []
        for _ in 0 ..< BrowserPrivacyBackupRetention.maximumCount {
            confirmed.append(try await backup(fixture, service: service, outcome: .deleted))
            XCTAssertTrue(reads.urls.isEmpty, "annotation below/at twelve never hashes count candidates")
            XCTAssertEqual(service.purgeExpired(), 0)
            XCTAssertTrue(reads.urls.isEmpty, "refresh maintenance below/at twelve is metadata-only")
        }
        _ = try await backup(fixture, service: service, outcome: .unverified)
        let unfinished = try await backup(fixture, service: service, outcome: nil)
        unfinished.writingLease?.release()
        let restored = try await backup(fixture, service: service, outcome: .deleted, sparing: Set(confirmed.map(\.id)))
        let lease = try service.beginRestoring(restored)
        try service.finishRestoring(restored)
        lease?.release()
        XCTAssertEqual(service.purgeExpired(), 0)
        XCTAssertEqual(Set(confirmed.map(\.id)), Set(service.entries().filter { $0.summary?.outcome == .deleted && $0.restoredAt == nil }.map(\.id)))
        XCTAssertTrue(reads.urls.isEmpty, "more directories do not imply more eligible count candidates")
    }

    func testOverLimitPruningHashesOnlyEligibleCandidatesAndRechecksTheVictim() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let setup = makeService(fixture)
        let now = Date()
        var confirmed: [BrowserPrivacyRecoveryBackup] = []
        for index in 0 ... BrowserPrivacyBackupRetention.maximumCount {
            let item = try await backup(fixture, service: setup, outcome: .deleted, sparing: Set(confirmed.map(\.id)))
            try setCreatedAt(now.addingTimeInterval(TimeInterval(index - 100)), backup: item)
            confirmed.append(item)
        }
        var excluded: [BrowserPrivacyRecoveryBackup] = []
        excluded.append(try await backup(fixture, service: setup, outcome: .unverified, sparing: Set(confirmed.map(\.id))))
        let pending = try await backup(fixture, service: setup, outcome: .deleted, sparing: Set(confirmed.map(\.id)))
        let pendingLease = try setup.beginRestoring(pending)
        pendingLease?.release()
        excluded.append(pending)
        let restored = try await backup(fixture, service: setup, outcome: .deleted, sparing: Set(confirmed.map(\.id)))
        let restoredLease = try setup.beginRestoring(restored)
        try setup.finishRestoring(restored)
        restoredLease?.release()
        excluded.append(restored)
        let unfinished = try await backup(fixture, service: setup, outcome: nil)
        unfinished.writingLease?.release()
        excluded.append(unfinished)
        let incomplete = try await backup(fixture, service: setup, outcome: .deleted, sparing: Set(confirmed.map(\.id)))
        var description = try metadata(incomplete)
        description.removeValue(forKey: "profileDisplayName")
        try writeMetadata(description, in: incomplete.databaseURL.deletingLastPathComponent())
        excluded.append(incomplete)
        let spared = try await backup(fixture, service: setup, outcome: .deleted, sparing: Set(confirmed.map(\.id)))
        excluded.append(spared)

        let reads = RecoveryCountDigestReader()
        let pruning = makeService(fixture, countDigestReader: reads)
        XCTAssertEqual(pruning.purgeExpired(sparing: [spared.id]), 1)
        XCTAssertEqual(Set(reads.urls), Set(confirmed.map(\.databaseURL)))
        for (index, item) in confirmed.enumerated() {
            XCTAssertEqual(reads.urls.filter { $0 == item.databaseURL }.count, index == 0 ? 2 : 1, "only the victim gets a second, locked verification")
        }
        XCTAssertTrue(excluded.allSatisfy { !reads.urls.contains($0.databaseURL) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: confirmed[0].databaseURL.path))
        XCTAssertTrue(confirmed.dropFirst().allSatisfy { FileManager.default.fileExists(atPath: $0.databaseURL.path) })
        let readCount = reads.urls.count
        XCTAssertEqual(pruning.purgeExpired(sparing: [spared.id]), 0)
        XCTAssertEqual(reads.urls.count, readCount, "after pruning to twelve, subsequent maintenance reads no content")
    }

    func testCountPruningRejectsContentChangedBetweenSelectionAndTheLockedRecheck() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let setup = makeService(fixture, maximumBackups: 1)
        let oldest = try await backup(fixture, service: setup, outcome: .deleted)
        try setCreatedAt(Date().addingTimeInterval(-86_400), backup: oldest)
        let newest = try await backup(fixture, service: setup, outcome: .deleted, sparing: [oldest.id])
        let reads = RecoveryCountDigestReader()
        let hookErrors = RecoveryObservations()
        let pruning = makeService(fixture, maximumBackups: 1, beforeRemovalHook: { id in
            guard id == oldest.id else { return }
            do { try Data("changed after candidate selection".utf8).write(to: oldest.databaseURL) }
            catch { hookErrors.recordFailure() }
        }, countDigestReader: reads)

        XCTAssertEqual(pruning.purgeExpired(), 0)
        XCTAssertEqual(hookErrors.failureCount, 0)
        XCTAssertEqual(reads.urls.filter { $0 == oldest.databaseURL }.count, 2)
        XCTAssertEqual(reads.urls.filter { $0 == newest.databaseURL }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldest.databaseURL.path), "a stale content check cannot authorize deletion")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.databaseURL.path))
    }

    func testUnverifiedBackupsDoNotDisplaceAnyOfTwelveConfirmedBackupsAndStillExpire() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture)
        XCTAssertEqual(BrowserPrivacyBackupRetention.maximumCount, 12)
        let uncertain = try await backup(fixture, service: service, outcome: .unverified)
        let now = Date()
        try setCreatedAt(now.addingTimeInterval(-6 * 86_400), backup: uncertain)
        var confirmed: [BrowserPrivacyRecoveryBackup] = []
        for index in 0 ..< BrowserPrivacyBackupRetention.maximumCount {
            let item = try await backup(fixture, service: service, outcome: .deleted)
            try setCreatedAt(now.addingTimeInterval(TimeInterval(index - 100)), backup: item)
            confirmed.append(item)
        }
        XCTAssertEqual(Set(service.entries().map(\.id)), Set(confirmed.map(\.id) + [uncertain.id]))
        let newest = try await backup(fixture, service: service, outcome: .deleted)
        XCTAssertEqual(Set(service.entries().map(\.id)), Set(confirmed.dropFirst().map(\.id) + [newest.id, uncertain.id]))
        service.purgeExpired(now: uncertain.createdAt.addingTimeInterval(2 * 86_400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: uncertain.databaseURL.path))
        XCTAssertEqual(service.entries().count, 12, "unverified still follows seven-day expiry")
    }

    func testIncompleteOrDigestMismatchedBackupsCannotDisplaceACompleteBackup() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture, maximumBackups: 1)
        let kept = try await backup(fixture, service: service, outcome: .deleted)
        try setCreatedAt(Date().addingTimeInterval(-86_400), backup: kept)
        for mutation in ["missing", "corrupt", "symlink", "digest", "summary"] {
            let item = try await backup(fixture, service: service, outcome: nil)
            let directory = item.databaseURL.deletingLastPathComponent()
            switch mutation {
            case "missing": try FileManager.default.removeItem(at: item.databaseURL)
            case "corrupt": try Data("not the saved database".utf8).write(to: item.databaseURL)
            case "symlink":
                try FileManager.default.removeItem(at: item.databaseURL)
                try FileManager.default.createSymbolicLink(at: item.databaseURL, withDestinationURL: kept.databaseURL)
            default: break
            }
            await service.annotate(item, summary: summary(.deleted), sparing: [kept.id])
            var description = try metadata(item)
            if mutation == "digest" { description["sha256"] = "not-a-digest" }
            if mutation == "summary" { description.removeValue(forKey: "browserDisplayName") }
            try writeMetadata(description, in: directory)
            XCTAssertEqual(service.purgeExpired(), 0, mutation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.databaseURL.path), mutation)
        }
    }

    func testUnfinishedVisibilityUsesContinuousElapsedTimeAndIgnoresWallJumps() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let clock = RecoveryClockDouble(seconds: 1_000)
        let service = makeService(fixture, clock: clock)
        let item = try await backup(fixture, service: service, outcome: nil)
        item.writingLease?.release() // interrupted operation with no final outcome
        clock.set(seconds: 1_119.999)
        XCTAssertTrue(service.entries(now: item.createdAt.addingTimeInterval(3_600)).isEmpty)
        clock.set(seconds: 1_120)
        XCTAssertTrue(service.entries().isEmpty, "the two-minute boundary stays hidden")
        clock.set(seconds: 999)
        XCTAssertTrue(service.entries().isEmpty, "a reading that went backwards cannot establish elapsed time")
        clock.set(seconds: 1_120.001)
        XCTAssertEqual(service.entries(now: item.createdAt.addingTimeInterval(-3_600)).map(\.id), [item.id])
        // Includes sleep, just like the existing ContinuousClock purge timer.
        clock.set(seconds: 4_600)
        XCTAssertEqual(makeService(fixture, clock: clock).entries().map(\.id), [item.id])
    }

    func testAnActiveBackupStaysHiddenWhenSleepPassesTheTwoMinuteAllowance() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let clock = RecoveryClockDouble(seconds: 1_000)
        let service = makeService(fixture, clock: clock)
        let item = try await backup(fixture, service: service, outcome: nil)
        clock.set(seconds: 4_600) // one hour of sleep on the continuous clock
        XCTAssertTrue(makeService(fixture, clock: clock).entries(now: item.createdAt.addingTimeInterval(3_600)).isEmpty)
        XCTAssertFalse(service.remove(backupID: item.id))
        await service.annotate(item, summary: summary(.deleted))
        XCTAssertEqual(service.entries().map(\.id), [item.id], "finishing the operation makes the backup visible immediately")
    }

    func testFinishedBackupIsVisibleImmediatelyWithoutWaitingForTheClock() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let clock = RecoveryClockDouble(seconds: 1_000)
        let service = makeService(fixture, clock: clock)
        let item = try await backup(fixture, service: service, outcome: .deleted)
        clock.set(seconds: 0)
        XCTAssertEqual(service.entries().map(\.id), [item.id])
    }

    func testProductionClockUsesTheContinuousCounterAndABootIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Features/BrowserPrivacy/Support/BrowserPrivacyRecoveryClock.swift"
        ), encoding: .utf8)
        // The behavior tests inject seconds. This contract locks down which
        // platform counter supplies those seconds without sampling the Mac.
        XCTAssertTrue(source.contains("Double(mach_continuous_time())"))
        XCTAssertTrue(source.contains("mach_timebase_info(&timebase)"))
        XCTAssertTrue(source.contains("sysctlbyname(\"kern.bootsessionuuid\""))
        XCTAssertFalse(source.contains("Double(mach_absolute_time())"))
        XCTAssertFalse(source.contains("DispatchTime.now()"))
    }

    func testOldBootAndLegacyUnfinishedBackupsAreNotMistakenForAnActiveOperation() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let clock = RecoveryClockDouble(seconds: 1_000)
        let service = makeService(fixture, clock: clock)
        let item = try await backup(fixture, service: service, outcome: nil)
        item.writingLease?.release()
        clock.set(seconds: 1, boot: "another-boot")
        XCTAssertEqual(service.entries().map(\.id), [item.id])
        var description = try metadata(item)
        description["version"] = 1
        description.removeValue(forKey: "continuousCreatedAt")
        description.removeValue(forKey: "bootSessionIdentifier")
        try writeMetadata(description, in: item.databaseURL.deletingLastPathComponent())
        XCTAssertEqual(service.entries().map(\.id), [item.id])
    }

    func testUnavailableContinuousClockNeverFallsBackToWallTime() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = BrowserPrivacyRecoveryBackupService(
            rootURL: fixture.recoveryRoot,
            snapshotService: SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot),
            continuousNow: { nil }, excludeFromTimeMachine: { _ in }
        )
        let item = try await backup(fixture, service: service, outcome: nil)
        XCTAssertTrue(service.entries(now: item.createdAt.addingTimeInterval(3_600)).isEmpty)
        await service.annotate(item, summary: summary(.deleted))
        XCTAssertEqual(service.entries().map(\.id), [item.id])
    }

    func testExclusionFailureCreatesNoBackupAndDeletionExplainsWhyNothingChanged() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let before = try fixture.tableState()
        let calls = RecoveryObservations()
        let service = BrowserPrivacyRecoveryBackupService(
            rootURL: fixture.recoveryRoot,
            snapshotService: SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot),
            continuousNow: { BrowserPrivacyRecoveryClockReading(seconds: 1_000, bootSessionIdentifier: "test-boot") },
            excludeFromTimeMachine: { url in
                calls.recordExclusion(url)
                throw ExclusionDoubleFailure()
            }
        )
        do {
            _ = try await backup(fixture, service: service, outcome: nil)
            XCTFail("the failed exclusion must stop the backup")
        } catch let failure as BrowserPrivacyBackupStorageFailure {
            XCTAssertTrue(failure.timeMachineExclusionFailed)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.snapshotRoot.path), [], "no snapshot copy was attempted")

        let result = await fixture.processor(backupService: service).process(
            records: try await fixture.selectedRecords(visitIDs: [21])
        )
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.outcome, .failed)
        XCTAssertEqual(entry.reason, .backupExclusionFailed)
        XCTAssertNil(entry.recoveryBackupID)
        XCTAssertEqual(try fixture.tableState(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path), [])
        XCTAssertEqual(calls.exclusions.count, 2)
        XCTAssertTrue(calls.exclusions.allSatisfy { $0 == fixture.recoveryRoot.resolvingSymlinksInPath().standardizedFileURL })
        let text = BrowserPrivacyProcessingReason.backupExclusionFailed.localizedTexts(browserName: "Google Chrome")
        XCTAssertTrue(text.chinese.contains("时间机器"))
        XCTAssertTrue(text.chinese.contains("没有备份，也没有删除任何记录"))
        XCTAssertTrue(text.english.contains("excluded from Time Machine"))
        XCTAssertTrue(text.english.contains("no backup was made and nothing was deleted"))
    }

    func testMaintenanceUsesTheInjectedExclusionWriterForALegacyRoot() throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        try FileManager.default.createDirectory(at: fixture.recoveryRoot, withIntermediateDirectories: true)
        let calls = RecoveryObservations()
        let service = BrowserPrivacyRecoveryBackupService(
            rootURL: fixture.recoveryRoot,
            snapshotService: SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot),
            continuousNow: { nil }, excludeFromTimeMachine: { calls.recordExclusion($0) }
        )
        XCTAssertEqual(service.purgeExpired(), 0)
        XCTAssertEqual(calls.exclusions, [fixture.recoveryRoot.resolvingSymlinksInPath().standardizedFileURL])
    }

    func testRestoreRootNamespaceFailuresDoNotBlameTheBrowserOrSource() async throws {
        for invalidLockFile in [false, true] {
            let fixture = try ChromiumV70HistoryFixture(mode: .production)
            let service = makeService(fixture)
            let source = try await backup(fixture, service: service, outcome: .deleted)
            let entry = try XCTUnwrap(service.entries().first)
            try fixture.execute("DELETE FROM visits WHERE id = 21")
            let before = try fixture.tableState()
            let originalMetadata = try Data(contentsOf: source.databaseURL.deletingLastPathComponent().appendingPathComponent("metadata.json"))
            let namespace = fixture.recoveryRoot.appendingPathComponent(".recovery-namespace.lease")
            var descriptor: Int32 = -1
            defer {
                if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
            }
            if invalidLockFile {
                try FileManager.default.removeItem(at: namespace)
                try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: false)
            } else {
                descriptor = Darwin.open(namespace.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            }

            let result = await fixture.processor(backupService: service).restore(
                entry, installedApplications: [try XCTUnwrap(fixture.installedApplication)]
            )

            XCTAssertEqual(result.reason, .currentStateNotSaved, result.detail)
            XCTAssertFalse(result.historyMayHaveChanged)
            XCTAssertNil(result.undoBackupID)
            XCTAssertEqual(try fixture.tableState(), before)
            XCTAssertEqual(service.entries().map(\.id), [source.id], "no undo backup was started")
            XCTAssertEqual(try Data(contentsOf: source.databaseURL.deletingLastPathComponent().appendingPathComponent("metadata.json")), originalMetadata)
        }
    }

    func testMissingReplacedAndBusySourcesKeepTheirOwnRestoreReasons() async throws {
        for fault in ["missing", "replaced", "busy"] {
            let fixture = try ChromiumV70HistoryFixture(mode: .production)
            let service = makeService(fixture)
            let source = try await backup(fixture, service: service, outcome: .deleted)
            let entry = try XCTUnwrap(service.entries().first)
            try fixture.execute("DELETE FROM visits WHERE id = 21")
            let before = try fixture.tableState()
            let directory = source.databaseURL.deletingLastPathComponent()
            var lease: BrowserPrivacyRecoveryLease?
            defer { lease?.release() }
            if fault == "busy" {
                lease = try BrowserPrivacyRecoveryLease.acquire(in: directory)
            } else {
                XCTAssertTrue(service.remove(backupID: source.id))
                if fault == "replaced" {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                }
            }
            let namesBefore = try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path)

            let result = await fixture.processor(backupService: service).restore(
                entry, installedApplications: [try XCTUnwrap(fixture.installedApplication)]
            )

            XCTAssertEqual(result.reason, fault == "busy" ? .backupInUse : .backupUnavailable, fault)
            XCTAssertFalse(result.historyMayHaveChanged, fault)
            XCTAssertNil(result.undoBackupID, fault)
            XCTAssertEqual(try fixture.tableState(), before, fault)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path)), Set(namesBefore), "no undo backup for \(fault) source")
        }
    }

    func testTombstoneWriteFailureIsStorageFailureAndKeepsTheSource() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture)
        let source = try await backup(fixture, service: service, outcome: .deleted)
        let directory = source.databaseURL.deletingLastPathComponent()
        let lease = try BrowserPrivacyRecoveryLease.acquire(in: directory)
        defer { lease.release() }
        // Only the fixture's directory is made read-only. The existing lease
        // files remain writable, so this fails at rename, not at taking a lock.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.recoveryRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.recoveryRoot.path) }

        XCTAssertThrowsError(try lease.moveToTombstone(in: directory)) { error in
            XCTAssertEqual(error as? BrowserPrivacyBackupStorageFailure, BrowserPrivacyBackupStorageFailure())
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.databaseURL.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path).contains {
            $0.hasPrefix(BrowserPrivacyRecoveryLease.tombstonePrefix)
        })
    }

    func testPersistentBackupIOFailuresDistinguishRecoveryStorageSourceAndLiveDatabase() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let snapshot = SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot)
        let database = SQLiteSnapshotSource(databaseURL: fixture.profile.historyDatabaseURL, trustedParentURL: fixture.profile.sourceTrustedParentURL)
        let schema = BrowserPrivacySQLiteWriteAdapter.chromiumProduction.schema
        let before = try fixture.tableState()
        let occupied = fixture.root.appendingPathComponent("OccupiedBackupDestination")
        try Data("keep".utf8).write(to: occupied)
        for destination in [occupied, occupied.appendingPathComponent("History.backup.sqlite")] {
            do {
                try await snapshot.createPersistentBackup(
                    source: database, schema: schema, destinationURL: destination,
                    busyRetrySeconds: 0.2, deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
                )
                XCTFail("a blocked backup destination must fail")
            } catch {
                XCTAssertEqual(error as? SQLitePersistentBackupFailure, .destinationWrite)
            }
        }
        XCTAssertEqual(try Data(contentsOf: occupied), Data("keep".utf8))
        do {
            try await snapshot.restorePersistentBackup(
                backupURL: fixture.root.appendingPathComponent("MissingBackup"), destination: database,
                schema: schema, busyRetrySeconds: 0.2, deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
            )
            XCTFail("a missing source must fail")
        } catch {
            XCTAssertEqual(error as? SQLitePersistentBackupFailure, .sourceRead(.unavailable))
        }
        do {
            try await snapshot.restorePersistentBackup(
                backupURL: database.databaseURL,
                destination: SQLiteSnapshotSource(databaseURL: fixture.root.appendingPathComponent("MissingHistory"), trustedParentURL: fixture.root),
                schema: schema, busyRetrySeconds: 0.2, deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
            )
            XCTFail("a missing live database must fail")
        } catch {
            XCTAssertEqual(error as? SQLiteSnapshotFailure, .unavailable, "the destination error must not be wrapped as a source error")
        }
        XCTAssertEqual(try fixture.tableState(), before)
    }

    func testRestoreFailureMappingUsesTheFailingStage() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture)
        let source = try await backup(fixture, service: service, outcome: .deleted)
        let entry = try XCTUnwrap(service.entries().first)
        try fixture.execute("DELETE FROM visits WHERE id = 21")
        let before = try fixture.tableState()
        let cases: [(RecoveryFailureStage, any Error, BrowserPrivacyRestoreReason)] = [
            (.begin, BrowserPrivacyBackupStorageFailure(), .currentStateNotSaved),
            (.begin, SQLiteSnapshotFailure.permissionDenied, .backupUnavailable),
            (.begin, SQLiteSnapshotFailure.timedOut, .timedOut),
            (.begin, SQLiteSnapshotFailure.cancelled, .cancelled),
            (.backup, BrowserPrivacyBackupStorageFailure(), .currentStateNotSaved),
            (.backup, SQLitePersistentBackupFailure.destinationWrite, .currentStateNotSaved),
            (.copy, SQLitePersistentBackupFailure.sourceRead(.unavailable), .backupUnavailable),
            (.copy, SQLitePersistentBackupFailure.sourceRead(.permissionDenied), .backupUnavailable),
            (.copy, SQLitePersistentBackupFailure.sourceRead(.busy), .backupInUse),
            (.copy, SQLitePersistentBackupFailure.sourceRead(.sizeLimitExceeded), .backupTooLarge),
            (.copy, SQLiteSnapshotFailure.unavailable, .databaseChanged),
            (.copy, SQLiteSnapshotFailure.permissionDenied, .permissionDenied),
            (.copy, SQLiteSnapshotFailure.busy, .databaseBusy),
            (.copy, SQLiteSnapshotFailure.corrupt, .failed),
            (.copy, SQLiteSnapshotFailure.timedOut, .timedOut),
            (.copy, SQLiteSnapshotFailure.cancelled, .cancelled),
        ]
        for (stage, failure, expected) in cases {
            let double = RecoveryStageFailingService(base: service, stage: stage, failure: failure)
            let result = await fixture.processor(backupService: double).restore(
                entry, installedApplications: [try XCTUnwrap(fixture.installedApplication)]
            )

            XCTAssertEqual(result.reason, expected, "\(stage): \(failure)")
            XCTAssertFalse(result.historyMayHaveChanged)
            XCTAssertNil(result.undoBackupID)
            XCTAssertEqual(try fixture.tableState(), before)
            XCTAssertEqual(service.entries().map(\.id), [source.id], "unused undo state is discarded")
        }
    }

    func testFinalMarkerFailureReportsAnUnrecordedResultAndKeepsUndo() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture)
        let source = try await backup(fixture, service: service, outcome: .deleted)
        let entry = try XCTUnwrap(service.entries().first)
        try fixture.execute("DELETE FROM visits WHERE id = 21")
        let double = PausingRecoveryService(base: service, failFinalMarker: true)

        let result = await fixture.processor(backupService: double).restore(
            entry, installedApplications: [try XCTUnwrap(fixture.installedApplication)]
        )

        XCTAssertEqual(result.reason, .restoreResultNotSaved, result.detail)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.historyMayHaveChanged)
        let undoID = try XCTUnwrap(result.undoBackupID)
        XCTAssertEqual(service.entries().first { $0.id == undoID }?.summary?.outcome, .savedBeforeRestore)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 21"), 1)
        XCTAssertEqual(try metadata(source)["restorePending"] as? Bool, true)
        XCTAssertNil(service.entries().first { $0.id == source.id }?.restoredAt)
    }

    func testPersistentRemovalFailureStaysVisibleAndRetriesByOriginalIDAfterRestart() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let fault = RecoveryRemovalFault()
        let service = makeService(fixture, removeTombstone: { try fault.remove($0) })
        let source = try await backup(fixture, service: service, outcome: .deleted)
        let store = BrowserPrivacyRecoveryStore(service: service, processor: fixture.processor(backupService: service))
        await store.refresh()

        let first = await store.remove(backupID: source.id)
        XCTAssertFalse(first)
        XCTAssertTrue(store.entries.isEmpty, "retired data never reenters the restore list")
        XCTAssertEqual(store.failedRemovalID, source.id)
        XCTAssertEqual(store.pendingRemovalIDs, [source.id])
        XCTAssertEqual(store.unlistedRemovalIDs, [source.id])
        let retired = try XCTUnwrap(fault.lastDirectory)
        XCTAssertTrue(retired.lastPathComponent.hasPrefix(BrowserPrivacyRecoveryLease.tombstonePrefix + source.id.uuidString + "-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retired.appendingPathComponent("History.backup.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.appendingPathComponent("metadata.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.appendingPathComponent(SQLiteSnapshotService.leaseFileName).path))
        store.clearResult()
        XCTAssertEqual(store.unlistedRemovalIDs, [source.id], "dismissed restore results do not dismiss pending cleanup")

        let second = await store.remove(backupID: source.id)
        XCTAssertFalse(second, "an absent live path is not evidence that retired data is gone")
        XCTAssertEqual(store.failedRemovalID, source.id)
        XCTAssertEqual(store.pendingRemovalIDs, [source.id])
        let restartedService = makeService(fixture, removeTombstone: { try fault.remove($0) })
        let restarted = BrowserPrivacyRecoveryStore(service: restartedService)
        await restarted.refresh()
        XCTAssertTrue(restarted.entries.isEmpty)
        XCTAssertEqual(restarted.unlistedRemovalIDs, [source.id], "the on-disk name survives loss of the store and metadata")

        fault.allowRemoval()
        let retried = await restarted.remove(backupID: source.id)
        XCTAssertTrue(retried)
        XCTAssertTrue(restarted.pendingRemovalIDs.isEmpty)
        XCTAssertTrue(restarted.unlistedRemovalIDs.isEmpty)
        XCTAssertNil(restarted.failedRemovalID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
        await store.refresh()
        XCTAssertTrue(store.pendingRemovalIDs.isEmpty)
        XCTAssertNil(store.failedRemovalID, "maintenance/readback also clears a resolved failure")

        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: project.appendingPathComponent("Sources/StorageCleanerMac/Views/BrowserPrivacyRecentDeletionsView.swift"), encoding: .utf8)
        let pending = try XCTUnwrap(view.range(of: "if !recoveryStore.unlistedRemovalIDs.isEmpty"))
        let entries = try XCTUnwrap(view.range(of: "if recoveryStore.entries.isEmpty"))
        XCTAssertLessThan(pending.lowerBound, entries.lowerBound, "pending cleanup renders outside restorable rows, including an empty list")
        XCTAssertTrue(view.contains("BrowserPrivacyRecoveryText.pendingRemoval"))
        XCTAssertTrue(view.contains("await recoveryStore.retryPendingRemovals()"))
    }

    func testLegacyTombstoneWithoutMetadataCannotMakeAnIDRetryClaimSuccess() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let fault = RecoveryRemovalFault()
        let service = makeService(fixture, removeTombstone: { try fault.remove($0) })
        let source = try await backup(fixture, service: service, outcome: .deleted)
        XCTAssertFalse(service.remove(backupID: source.id))
        let legacyID = UUID()
        let legacy = fixture.recoveryRoot.appendingPathComponent(BrowserPrivacyRecoveryLease.tombstonePrefix + legacyID.uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: XCTUnwrap(fault.lastDirectory), to: legacy)

        XCTAssertFalse(service.remove(backupID: source.id))
        XCTAssertFalse(service.isRemoved(backupID: source.id))
        XCTAssertEqual(service.pendingRemovalIDs(), [legacyID])
        XCTAssertTrue(service.entries().isEmpty)
        fault.allowRemoval()
        XCTAssertTrue(service.remove(backupID: source.id))
        XCTAssertEqual(service.pendingRemovalIDs(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testRemovalReadbackRejectsACallbackThatLeavesTheDataInPlace() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let service = makeService(fixture, removeTombstone: { _ in })
        let source = try await backup(fixture, service: service, outcome: .deleted)

        XCTAssertFalse(service.remove(backupID: source.id))
        XCTAssertFalse(service.remove(backupID: source.id))
        XCTAssertFalse(service.isRemoved(backupID: source.id))
        XCTAssertEqual(service.pendingRemovalIDs(), [source.id])
        XCTAssertTrue(service.entries().isEmpty)
        XCTAssertTrue(makeService(fixture).remove(backupID: source.id))
        XCTAssertTrue(service.isRemoved(backupID: source.id))
    }

    func testLinkedRecoveryRootFailsBeforeReadingSourceOrCreatingBackup() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let selected = try await fixture.selectedRecords(visitIDs: [21])
        let before = try fixture.tableState()
        let snapshotNamesBefore = try FileManager.default.contentsOfDirectory(atPath: fixture.snapshotRoot.path).sorted()
        let target = fixture.root.appendingPathComponent("LinkedRecoveryTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        let sentinel = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: fixture.recoveryRoot, withDestinationURL: target)
        let calls = RecoveryObservations()
        let service = BrowserPrivacyRecoveryBackupService(
            rootURL: fixture.recoveryRoot,
            snapshotService: SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot),
            excludeFromTimeMachine: { calls.recordExclusion($0) }
        )
        do {
            // This source cannot be read. The root must be rejected first,
            // before SQLite gets a chance to report a source failure.
            _ = try await service.backup(
                source: SQLiteSnapshotSource(databaseURL: fixture.root.appendingPathComponent("MissingHistory"), trustedParentURL: fixture.root),
                schema: BrowserPrivacySQLiteWriteAdapter.chromiumProduction.schema,
                browserID: fixture.profile.browser.id, profileID: fixture.profile.id,
                deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
            )
            XCTFail("a linked root is never a backup destination")
        } catch {
            XCTAssertEqual(error as? BrowserPrivacyBackupStorageFailure, BrowserPrivacyBackupStorageFailure(rootIsSymbolicLink: true))
        }
        let result = await fixture.processor(backupService: service).process(records: selected)
        XCTAssertEqual(result.entries.first?.reason, .backupLocationUnsafe)
        XCTAssertEqual(result.entries.first?.outcome, .failed)
        XCTAssertNil(result.entries.first?.recoveryBackupID)
        XCTAssertEqual(try fixture.tableState(), before)
        XCTAssertTrue(calls.exclusions.isEmpty, "the link target is not even marked for exclusion")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["keep.txt"])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.snapshotRoot.path).sorted(), snapshotNamesBefore)
        XCTAssertTrue(service.entries().isEmpty)
        XCTAssertNil(service.earliestExpiry())
        XCTAssertNil(service.pendingRemovalIDs(), "an unsafe root is unknown, not an empty cleanup queue")
        XCTAssertFalse(service.remove(backupID: UUID()))
        XCTAssertEqual(service.purgeExpired(), 0)
        let text = BrowserPrivacyProcessingReason.backupLocationUnsafe.localizedTexts(browserName: "Google Chrome")
        XCTAssertTrue(text.chinese.contains("备份位置是一个链接"))
        XCTAssertTrue(text.chinese.contains("没有创建备份"))
        XCTAssertTrue(text.english.contains("symbolic link"))
    }

    func testReplacingTheVerifiedRootFailsClosedAcrossEveryEntryPoint() async throws {
        for replacementIsLink in [false, true] {
            let fixture = try ChromiumV70HistoryFixture(mode: .production)
            let service = makeService(fixture)
            let source = try await backup(fixture, service: service, outcome: .deleted)
            let before = try fixture.tableState()
            let moved = fixture.root.appendingPathComponent("OriginalRecovery", isDirectory: true)
            try FileManager.default.moveItem(at: fixture.recoveryRoot, to: moved)
            if replacementIsLink {
                try FileManager.default.createSymbolicLink(at: fixture.recoveryRoot, withDestinationURL: moved)
            } else {
                try FileManager.default.createDirectory(at: fixture.recoveryRoot, withIntermediateDirectories: false)
            }
            XCTAssertTrue(service.entries().isEmpty)
            XCTAssertNil(service.earliestExpiry())
            XCTAssertNil(service.pendingRemovalIDs())
            XCTAssertEqual(service.purgeExpired(now: Date().addingTimeInterval(30 * 86_400)), 0)
            XCTAssertFalse(service.remove(backupID: source.id))
            XCTAssertFalse(service.isRemoved(backupID: source.id))
            XCTAssertThrowsError(try service.beginRestoring(source))
            XCTAssertThrowsError(try service.finishRestoring(source))
            do {
                _ = try await backup(fixture, service: service, outcome: .deleted)
                XCTFail("the service must not adopt a replacement root")
            } catch { XCTAssertNotNil(error as? BrowserPrivacyBackupStorageFailure) }
            do {
                try await service.restore(
                    source,
                    destination: SQLiteSnapshotSource(databaseURL: fixture.profile.historyDatabaseURL, trustedParentURL: fixture.profile.sourceTrustedParentURL),
                    schema: BrowserPrivacySQLiteWriteAdapter.chromiumProduction.schema,
                    deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
                )
                XCTFail("a changed root is not a source of a restore")
            } catch { XCTAssertEqual(error as? SQLitePersistentBackupFailure, .sourceRead(.unavailable)) }
            XCTAssertEqual(try fixture.tableState(), before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(source.id.uuidString).appendingPathComponent("History.backup.sqlite").path))
        }
    }

    func testRootReplacementDuringPreparationCannotCreateABackup() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let original = fixture.recoveryRoot
        let moved = fixture.root.appendingPathComponent("MovedDuringPreparation", isDirectory: true)
        let service = BrowserPrivacyRecoveryBackupService(
            rootURL: original,
            snapshotService: SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot),
            excludeFromTimeMachine: { _ in
                try FileManager.default.moveItem(at: original, to: moved)
                try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            }
        )
        do {
            _ = try await backup(fixture, service: service, outcome: .deleted)
            XCTFail("revalidate the pinned root after preparation callbacks")
        } catch {
            XCTAssertEqual(error as? BrowserPrivacyBackupStorageFailure, BrowserPrivacyBackupStorageFailure(rootIsSymbolicLink: true))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.snapshotRoot.path).isEmpty)
    }

    func testAParentAliasUsesOneCanonicalRootForTheWholeBackupLifecycle() async throws {
        let fixture = try ChromiumV70HistoryFixture(mode: .production)
        let parent = fixture.root.appendingPathComponent("RecoveryParent", isDirectory: true)
        let alias = fixture.root.appendingPathComponent("ParentAlias", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        let root = alias.appendingPathComponent("Recovery", isDirectory: true)
        let service = BrowserPrivacyRecoveryBackupService(
            rootURL: root, snapshotService: SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot),
            excludeFromTimeMachine: { _ in }
        )
        let source = try await backup(fixture, service: service, outcome: .deleted)
        let entry = try XCTUnwrap(service.entries().first)
        XCTAssertEqual(source.databaseURL.deletingLastPathComponent().deletingLastPathComponent(), root.resolvingSymlinksInPath().standardizedFileURL)
        try fixture.execute("DELETE FROM visits WHERE id = 21")
        let result = await fixture.processor(backupService: service).restore(
            entry, installedApplications: [try XCTUnwrap(fixture.installedApplication)]
        )
        XCTAssertTrue(result.succeeded, result.detail)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM visits WHERE id = 21"), 1)
        XCTAssertNotNil(service.entries().first { $0.id == source.id }?.restoredAt)
        XCTAssertTrue(service.remove(backupID: source.id))
        XCTAssertEqual(service.purgeExpired(now: Date().addingTimeInterval(8 * 86_400)), 1)
        XCTAssertTrue(service.entries().isEmpty)
        XCTAssertEqual(service.pendingRemovalIDs(), [])
    }

    private func makeService(
        _ fixture: ChromiumV70HistoryFixture,
        maximumBackups: Int = BrowserPrivacyBackupRetention.maximumCount,
        clock: RecoveryClockDouble = RecoveryClockDouble(seconds: 1_000),
        beforeRemovalHook: (@Sendable (UUID) -> Void)? = nil,
        countDigestReader: any CleanupContentDigestReading = FoundationCleanupContentDigestReader(),
        removeTombstone: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> BrowserPrivacyRecoveryBackupService {
        BrowserPrivacyRecoveryBackupService(
            rootURL: fixture.recoveryRoot,
            snapshotService: SQLiteSnapshotService(temporaryRoot: fixture.snapshotRoot),
            maximumBackups: maximumBackups, continuousNow: { clock.reading },
            excludeFromTimeMachine: { _ in }, beforeRemovalHook: beforeRemovalHook,
            countDigestReader: countDigestReader, removeTombstone: removeTombstone
        )
    }

    private func backup(
        _ fixture: ChromiumV70HistoryFixture,
        service: BrowserPrivacyRecoveryBackupService,
        outcome: BrowserPrivacyRecoveryOutcome?, sparing: Set<UUID> = []
    ) async throws -> BrowserPrivacyRecoveryBackup {
        let item = try await service.backup(
            source: SQLiteSnapshotSource(databaseURL: fixture.profile.historyDatabaseURL, trustedParentURL: fixture.profile.sourceTrustedParentURL),
            schema: BrowserPrivacySQLiteWriteAdapter.chromiumProduction.schema,
            browserID: fixture.profile.browser.id, profileID: fixture.profile.id,
            deadlineNanoseconds: MonotonicClock.now &+ 5_000_000_000
        )
        if let outcome { await service.annotate(item, summary: summary(outcome), sparing: sparing) }
        return item
    }

    private func summary(_ outcome: BrowserPrivacyRecoveryOutcome) -> BrowserPrivacyRecoverySummary {
        .init(browserDisplayName: "Google Chrome", profileDisplayName: "Default", visitCount: 1, pageCount: 1, outcome: outcome)
    }

    private func metadata(_ backup: BrowserPrivacyRecoveryBackup) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: backup.databaseURL.deletingLastPathComponent().appendingPathComponent("metadata.json"))) as? [String: Any])
    }

    private func writeMetadata(_ metadata: [String: Any], in directory: URL) throws {
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func setCreatedAt(_ date: Date, backup: BrowserPrivacyRecoveryBackup) throws {
        var description = try metadata(backup)
        description["createdAt"] = date.timeIntervalSinceReferenceDate
        try writeMetadata(description, in: backup.databaseURL.deletingLastPathComponent())
    }
}

private struct ExclusionDoubleFailure: Error {}
private struct RemovalDoubleFailure: Error {}

private final class RecoveryRemovalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    private var directory: URL?
    var lastDirectory: URL? { lock.withLock { directory } }
    func allowRemoval() { lock.withLock { failing = false } }
    func remove(_ url: URL) throws {
        let fail = lock.withLock { directory = url; return failing }
        if fail {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(SQLiteSnapshotService.leaseFileName))
            try? FileManager.default.removeItem(at: url.appendingPathComponent("metadata.json"))
            throw RemovalDoubleFailure()
        }
        try FileManager.default.removeItem(at: url)
    }
}

private final class RecoveryCountDigestReader: CleanupContentDigestReading, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []
    var urls: [URL] { lock.withLock { recordedURLs } }
    func sha256(at url: URL) throws -> Data {
        lock.withLock { recordedURLs.append(url.resolvingSymlinksInPath().standardizedFileURL) }
        return try FoundationCleanupContentDigestReader().sha256(at: url)
    }
}

/// Blocks only the detached deletion worker; the test's main actor can restore
/// at the exact unlink/data-removal boundary without sleeps or real data.
private final class RecoveryDeletionPause: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var enteredDirectory: URL?
    private var entryWaiter: CheckedContinuation<URL?, Never>?
    private var released = false
    private var finished = false

    func pause(at directory: URL) {
        let shouldWait = lock.withLock {
            enteredDirectory = directory
            entryWaiter?.resume(returning: directory)
            entryWaiter = nil
            return !released
        }
        if shouldWait { gate.wait() }
    }

    func waitUntilEntered() async -> URL? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let enteredDirectory { continuation.resume(returning: enteredDirectory) }
                else if finished { continuation.resume(returning: nil) }
                else { entryWaiter = continuation }
            }
        }
    }

    func removalFinished() {
        lock.withLock {
            finished = true
            entryWaiter?.resume(returning: enteredDirectory)
            entryWaiter = nil
        }
    }

    func resume() {
        lock.withLock {
            guard !released else { return }
            released = true
            gate.signal()
        }
    }
}

private final class RecoveryClockDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval
    private var boot = "test-boot"
    init(seconds: TimeInterval) { self.seconds = seconds }
    var reading: BrowserPrivacyRecoveryClockReading {
        lock.withLock { .init(seconds: seconds, bootSessionIdentifier: boot) }
    }
    func set(seconds: TimeInterval, boot: String = "test-boot") {
        lock.withLock { self.seconds = seconds; self.boot = boot }
    }
}

private final class RecoveryObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedExclusions: [URL] = []
    private var failures = 0
    var exclusions: [URL] { lock.withLock { recordedExclusions } }
    var failureCount: Int { lock.withLock { failures } }
    func recordExclusion(_ url: URL) { lock.withLock { recordedExclusions.append(url) } }
    func recordFailure() { lock.withLock { failures += 1 } }
}

private actor RecoveryPause {
    private var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async {
        guard !entered, !released else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func resume() {
        released = true
        entryWaiter?.resume()
        entryWaiter = nil
        waiter?.resume()
        waiter = nil
    }
}

private enum RecoveryFailureStage: Sendable { case begin, backup, copy }

private struct RecoveryStageFailingService: BrowserPrivacyDatabaseBackingUp {
    let base: BrowserPrivacyRecoveryBackupService
    let stage: RecoveryFailureStage
    let failure: any Error
    func beginRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws -> BrowserPrivacyRecoveryLease? {
        if stage == .begin { throw failure }
        return try base.beginRestoring(backup)
    }
    func finishRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws { try base.finishRestoring(backup) }
    func backup(source: SQLiteSnapshotSource, schema: SQLiteSchemaAllowlist, browserID: String, profileID: String, deadlineNanoseconds: UInt64) async throws -> BrowserPrivacyRecoveryBackup {
        if stage == .backup { throw failure }
        return try await base.backup(source: source, schema: schema, browserID: browserID, profileID: profileID, deadlineNanoseconds: deadlineNanoseconds)
    }
    func restore(_ backup: BrowserPrivacyRecoveryBackup, destination: SQLiteSnapshotSource, schema: SQLiteSchemaAllowlist, deadlineNanoseconds: UInt64) async throws {
        if stage == .copy { throw failure }
        try await base.restore(backup, destination: destination, schema: schema, deadlineNanoseconds: deadlineNanoseconds)
    }
    func annotate(_ backup: BrowserPrivacyRecoveryBackup, summary: BrowserPrivacyRecoverySummary, sparing: Set<UUID>) async {
        await base.annotate(backup, summary: summary, sparing: sparing)
    }
    func discard(_ backup: BrowserPrivacyRecoveryBackup) async { await base.discard(backup) }
}

private struct PausingRecoveryService: BrowserPrivacyDatabaseBackingUp {
    let base: BrowserPrivacyRecoveryBackupService
    var beforeCopy: RecoveryPause? = nil
    var afterCopy: RecoveryPause? = nil
    var failFinalMarker = false
    func beginRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws -> BrowserPrivacyRecoveryLease? {
        try base.beginRestoring(backup)
    }
    func finishRestoring(_ backup: BrowserPrivacyRecoveryBackup) throws {
        if failFinalMarker { throw SQLiteSnapshotFailure.permissionDenied }
        try base.finishRestoring(backup)
    }
    func backup(source: SQLiteSnapshotSource, schema: SQLiteSchemaAllowlist, browserID: String, profileID: String, deadlineNanoseconds: UInt64) async throws -> BrowserPrivacyRecoveryBackup {
        try await base.backup(source: source, schema: schema, browserID: browserID, profileID: profileID, deadlineNanoseconds: deadlineNanoseconds)
    }
    func restore(_ backup: BrowserPrivacyRecoveryBackup, destination: SQLiteSnapshotSource, schema: SQLiteSchemaAllowlist, deadlineNanoseconds: UInt64) async throws {
        await beforeCopy?.pause()
        try await base.restore(backup, destination: destination, schema: schema, deadlineNanoseconds: deadlineNanoseconds)
        await afterCopy?.pause()
    }
    func annotate(_ backup: BrowserPrivacyRecoveryBackup, summary: BrowserPrivacyRecoverySummary, sparing: Set<UUID>) async {
        await base.annotate(backup, summary: summary, sparing: sparing)
    }
    func discard(_ backup: BrowserPrivacyRecoveryBackup) async { await base.discard(backup) }
}
