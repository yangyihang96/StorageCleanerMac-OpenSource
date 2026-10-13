import Darwin
import Foundation
import XCTest
@testable import FanControlShared
@testable import StorageCleanerMac

final class HelperUpgradeLedgerTests: XCTestCase {
    private func fixture() throws -> (URL, HelperUpgradeLedger) {
        let directory = try TestFileSystem.makeHome(for: self).resolvingSymlinksInPath()
        return (directory, ledger(directory))
    }
    private func ledger(_ directory: URL) -> HelperUpgradeLedger {
        HelperUpgradeLedger(directory: directory, filename: "test.handoff", owner: geteuid(), wallClock: { 1_000_000 })
    }
    private func version(_ text: String) -> HelperSignedBuildVersion { HelperSignedBuildVersion(text)! }

    @discardableResult
    private func writeRecord(_ data: Data, in root: URL, modifiedAt time: TimeInterval) throws -> URL {
        let path = root.appendingPathComponent("test.handoff")
        try data.write(to: path)
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: path.path)
        return path
    }

    private func recordData(version: String, uptime: TimeInterval) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["highestYieldedBuild": version, "yieldedAtUptime": uptime])
    }

    func testDedupAndTenMinuteCooldownSurviveNewInstances() throws {
        let (root, first) = try fixture()
        XCTAssertTrue(first.permits(target: version("21"), running: version("20"), at: 1_000))
        XCTAssertTrue(first.commitIfPermitted(target: version("21"), running: version("20"), at: 1_000, validate: { true }))
        let restarted = ledger(root)
        XCTAssertFalse(restarted.permits(target: version("21"), running: version("20"), at: 10_000), "A target is yielded to at most once")
        XCTAssertFalse(restarted.permits(target: version("20"), running: version("21"), at: 10_000))
        XCTAssertFalse(restarted.permits(target: version("22"), running: version("20"), at: 1_599.999))
        XCTAssertTrue(restarted.commitIfPermitted(target: version("22"), running: version("20"), at: 1_600, validate: { true }))
        XCTAssertFalse(ledger(root).permits(target: version("21"), running: version("22"), at: 10_000))
        XCTAssertFalse(ledger(root).permits(target: version("23"), running: version("20"), at: 2_199.999))
        XCTAssertTrue(ledger(root).permits(target: version("23"), running: version("20"), at: 2_200))
        var status = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent("test.handoff").path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertEqual(status.st_uid, geteuid())
    }

    func testFailedOrThrowingRevalidationDoesNotConsumeVersion() throws {
        let (root, first) = try fixture()
        enum Failed: Error { case image }
        XCTAssertFalse(first.commitIfPermitted(target: version("21"), running: version("20"), at: 1_000, validate: { false }))
        XCTAssertFalse(first.commitIfPermitted(target: version("21"), running: version("20"), at: 1_000, validate: { throw Failed.image }))
        XCTAssertTrue(ledger(root).commitIfPermitted(target: version("21"), running: version("20"), at: 1_000, validate: { true }))
    }

    func testFileLockAllowsOnlyOneConcurrentReservation() throws {
        let (root, first) = try fixture()
        var winners = 0
        XCTAssertTrue(first.commitIfPermitted(target: version("21"), running: version("20"), at: 1_000, validate: {
            let nested = ledger(root).commitIfPermitted(target: version("21"), running: version("20"), at: 1_000, validate: { winners += 1; return true })
            XCTAssertFalse(nested, "The second open sees the first process's flock")
            winners += 1
            return true
        }))
        XCTAssertEqual(winners, 1)
    }

    func testCooldownDenialDoesNotEvenInspectAnImage() throws {
        let (_, first) = try fixture()
        XCTAssertTrue(first.commitIfPermitted(target: version("21"), running: version("20"), at: 1_000, validate: { true }))
        var validations = 0
        XCTAssertFalse(first.commitIfPermitted(target: version("22"), running: version("20"), at: 1_001, validate: { validations += 1; return true }))
        XCTAssertEqual(validations, 0)
        for time in [Double.nan, .infinity, -1, 900] {
            XCTAssertFalse(first.permits(target: version("22"), running: version("20"), at: time))
        }
    }

    func testSymlinkHardlinkAndLoosePermissionsFailClosed() throws {
        let (root, first) = try fixture()
        let path = root.appendingPathComponent("test.handoff")
        let victim = root.appendingPathComponent("untouched")
        let original = Data("original".utf8)
        try original.write(to: victim)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: victim)
        XCTAssertFalse(first.commitIfPermitted(target: version("21"), running: version("20"), at: 1_000, validate: { true }))
        XCTAssertEqual(try Data(contentsOf: victim), original)
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(link(victim.path, path.path), 0)
        XCTAssertEqual(chmod(victim.path, 0o600), 0)
        XCTAssertFalse(first.permits(target: version("21"), running: version("20"), at: 1_000))
        try FileManager.default.removeItem(at: path)
        XCTAssertTrue(first.permits(target: version("21"), running: version("20"), at: 1_000))
        XCTAssertEqual(chmod(path.path, 0o644), 0)
        XCTAssertFalse(first.permits(target: version("21"), running: version("20"), at: 1_000))
    }

    func testMalformedOversizedAndClearedStateRecoverOnlyAfterMtimeCooldown() throws {
        let (root, first) = try fixture()
        XCTAssertTrue(first.permits(target: version("21"), running: version("20"), at: 1_000))
        for content in [Data("broken".utf8), Data(repeating: 1, count: 1_025), Data(), Data("{}".utf8)] {
            let path = try writeRecord(content, in: root, modifiedAt: 999_800)
            var before = stat(), after = stat()
            XCTAssertEqual(lstat(path.path, &before), 0)
            var validations = 0
            XCTAssertFalse(first.commitIfPermitted(target: version("21"), running: version("20"), at: 1_000,
                                                  validate: { validations += 1; return true }))
            XCTAssertEqual(validations, 0)
            let repaired = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            XCTAssertNil(repaired["highestYieldedBuild"], "Repair must not consume the candidate")
            XCTAssertEqual(repaired["yieldedAtUptime"] as? Double, 800)
            XCTAssertEqual(lstat(path.path, &after), 0)
            XCTAssertEqual(after.st_ino, before.st_ino, "Retain the inode and its flock")
            XCTAssertEqual(after.st_mode & 0o777, 0o600)
            XCTAssertFalse(ledger(root).permits(target: version("21"), running: version("20"), at: 1_399.999))
            XCTAssertTrue(ledger(root).commitIfPermitted(target: version("21"), running: version("20"), at: 1_400, validate: { true }),
                          "Repair mtime must not restart cooldown on every read")
        }
    }

    func testExtremeVersionIsDiscardedButRetainsItsLaterRecordTime() throws {
        let (root, first) = try fixture()
        try writeRecord(recordData(version: "18446744073709551615", uptime: 950), in: root, modifiedAt: 999_800)
        XCTAssertFalse(first.permits(target: version("21"), running: version("20"), at: 1_000))
        XCTAssertFalse(ledger(root).permits(target: version("21"), running: version("20"), at: 1_549.999))
        XCTAssertTrue(ledger(root).commitIfPermitted(target: version("21"), running: version("20"), at: 1_550, validate: { true }))
        XCTAssertFalse(ledger(root).permits(target: version("21"), running: version("20"), at: 10_000))
    }

    func testCredibleHigherVersionWithinRunningOrCandidateBuildIsNotDiscarded() throws {
        let (root, first) = try fixture()
        let original = try recordData(version: "30", uptime: 100)
        let path = try writeRecord(original, in: root, modifiedAt: 990_000)
        XCTAssertFalse(first.permits(target: version("21"), running: version("30"), at: 1_000))
        XCTAssertEqual(try Data(contentsOf: path), original, "A history at the running version is credible")
        XCTAssertFalse(first.permits(target: version("30"), running: version("20"), at: 1_000))
        XCTAssertEqual(try Data(contentsOf: path), original, "A history at the candidate version retains dedup")
        XCTAssertTrue(first.permits(target: version("31"), running: version("20"), at: 1_000))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testMalformedVersionKeepsReadableTimestampAndRecoveryKeepsRecentMtime() throws {
        let (root, first) = try fixture()
        for text in ["not-a-version", "18446744073709551616"] {
            try writeRecord(recordData(version: text, uptime: 950), in: root, modifiedAt: 990_000)
            XCTAssertFalse(first.permits(target: version("21"), running: version("20"), at: 1_000))
            XCTAssertFalse(ledger(root).permits(target: version("21"), running: version("20"), at: 1_549.999))
            XCTAssertTrue(ledger(root).permits(target: version("21"), running: version("20"), at: 1_550))
        }
        try writeRecord(recordData(version: "999", uptime: 100), in: root, modifiedAt: 999_950)
        XCTAssertFalse(first.permits(target: version("21"), running: version("20"), at: 1_000))
        XCTAssertFalse(ledger(root).permits(target: version("21"), running: version("20"), at: 1_549.999))
        XCTAssertTrue(ledger(root).permits(target: version("21"), running: version("20"), at: 1_550))
    }

    func testFutureDamagedTimeGetsOneFullCooldownAndCannotRefuseForever() throws {
        let (root, first) = try fixture()
        for time in [950.0, 1_000_000_000] {
            try writeRecord(recordData(version: "999", uptime: time), in: root, modifiedAt: 1_000_100)
            XCTAssertFalse(first.permits(target: version("21"), running: version("20"), at: 1_000))
            XCTAssertFalse(ledger(root).permits(target: version("21"), running: version("20"), at: 1_599.999))
            XCTAssertTrue(ledger(root).permits(target: version("21"), running: version("20"), at: 1_600))
        }
    }

    func testUntrustedParentAndOwnerNeverRepairDamagedContents() throws {
        let (root, first) = try fixture()
        let content = Data("broken".utf8)
        let path = try writeRecord(content, in: root, modifiedAt: 990_000)
        let wrongOwner = HelperUpgradeLedger(directory: root, filename: "other.handoff", owner: geteuid() + 1)
        XCTAssertFalse(wrongOwner.permits(target: version("21"), running: version("20"), at: 1_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("other.handoff").path))
        XCTAssertEqual(chmod(root.path, 0o722), 0)
        XCTAssertFalse(first.permits(target: version("21"), running: version("20"), at: 1_000))
        XCTAssertEqual(try Data(contentsOf: path), content)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(chmod(path.path, 0o644), 0)
        XCTAssertFalse(first.permits(target: version("21"), running: version("20"), at: 1_000))
        XCTAssertEqual(try Data(contentsOf: path), content)
        XCTAssertEqual(chmod(path.path, 0o600), 0)
    }
}
