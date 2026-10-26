import XCTest
@testable import StorageCleanerMac

final class MyActivityHealthTests: XCTestCase {
    private let now = MyActivityD187Fixtures.now
    private func evaluate(_ snapshot: ComputerHealthSnapshot?) -> MyActivityHealth {
        MyActivityHealth.evaluate(snapshot, now: now)
    }

    func testNoSnapshotDoesNotInventAHealthGrade() {
        let result = evaluate(nil)
        XCTAssertNil(result.grade)
        XCTAssertNil(result.checkedAt)
        XCTAssertTrue(result.reasons.isEmpty)
    }

    func testCompleteHealthyDesktopNeedsNoBattery() {
        let result = evaluate(ComputerHealthSecurityFixture.snapshot())
        XCTAssertEqual(result.grade, .good)
        XCTAssertTrue(result.reasons.isEmpty)
    }

    func testSMARTFailureIndependentlyRequiresAction() {
        let result = evaluate(ComputerHealthSecurityFixture.snapshot(smart: .failing))
        XCTAssertEqual(result.grade, .problem)
        XCTAssertEqual(result.reasons, [.diskFailure])
        let warning = DiskHealthSnapshot(availability: .available, status: .attention, smartStatus: .verified,
            isTRIMEnabled: nil, fileSystem: "APFS", summaryText: nil, checkedAt: now)
        XCTAssertEqual(evaluate(MyActivityD187Fixtures.health(disk: warning)).reasons, [.diskWarning])
    }

    func testFreeSpaceThresholdsExcludePurgeableSpace() {
        let thresholds: [(Int64, MyActivityHealth.Grade)] = [(0, .problem), (49, .problem), (50, .attention),
                                                          (99, .attention), (100, .good), (500, .good)]
        for (free, expected) in thresholds {
            let capacity = CapacityTrendSnapshot(availability: .available, status: .healthy,
                totalBytes: 1_000, availableBytes: free, availableForImportantUsageBytes: 900,
                sevenDayDeltaBytes: nil, recordedAt: now)
            XCTAssertEqual(evaluate(MyActivityD187Fixtures.health(capacity: capacity)).grade, expected, "free=\(free)")
        }
    }

    func testCapacityWarningDoesNotClaimLessThanTenPercentFree() {
        let result = evaluate(ComputerHealthSecurityFixture.snapshot(capacityStatus: .attention))
        XCTAssertEqual(result.reasons, [.capacityWarning])
        XCTAssertEqual(result.grade, .attention)
    }

    func testBatteryServiceAndWarningAreIndependent() {
        XCTAssertEqual(evaluate(MyActivityD187Fixtures.health(battery: MyActivityD187Fixtures.battery(condition: .serviceRecommended))).grade, .problem)
        XCTAssertEqual(evaluate(MyActivityD187Fixtures.health(battery: MyActivityD187Fixtures.battery(status: .attention))).reasons, [.batteryWarning])
        XCTAssertEqual(evaluate(MyActivityD187Fixtures.health(battery: MyActivityD187Fixtures.battery(status: .actionRequired))).grade, .problem)
        XCTAssertEqual(evaluate(MyActivityD187Fixtures.health(battery: MyActivityD187Fixtures.battery())).grade, .good)
    }

    func testEachDisabledProtectionControlHasAConcreteReason() {
        for check in SystemProtectionCheck.healthChecks {
            let security = SystemProtectionSnapshot(findings: SystemProtectionCheck.healthChecks.map {
                SystemProtectionFinding(check: $0, state: $0 == check ? .disabled : .enabled)
            }, checkedAt: now)
            let result = evaluate(MyActivityD187Fixtures.health(security: security))
            XCTAssertEqual(result.reasons, [.protectionDisabled(check)])
            XCTAssertEqual(result.grade, [.gatekeeper, .systemIntegrityProtection].contains(check) ? .problem : .attention)
        }
    }

    func testStabilityThresholdAndKernelEvents() {
        let fixtures: [(StabilitySummary, MyActivityHealth.Grade)] = [
            (MyActivityD187Fixtures.stability(crashes: 4), .good),
            (MyActivityD187Fixtures.stability(crashes: 3, hangs: 2), .attention),
            (MyActivityD187Fixtures.stability(hangs: 5), .attention),
            (MyActivityD187Fixtures.stability(crashes: 10), .problem),
            (MyActivityD187Fixtures.stability(panics: 1), .problem),
            (MyActivityD187Fixtures.stability(restarts: 1), .problem)
        ]
        for (stability, expected) in fixtures {
            XCTAssertEqual(evaluate(MyActivityD187Fixtures.health(stability: stability)).grade, expected)
        }
        XCTAssertEqual(evaluate(ComputerHealthSecurityFixture.snapshot(stabilityStatus: .attention)).reasons, [.stability])
        XCTAssertEqual(evaluate(ComputerHealthSecurityFixture.snapshot(stabilityStatus: .actionRequired)).reasons, [.severeStability])
    }

    func testBackupWarningAndUnconfiguredDestination() {
        XCTAssertEqual(evaluate(ComputerHealthSecurityFixture.snapshot(backupStatus: .attention)).reasons, [.backup])
        let backup = TimeMachineSnapshot(availability: .available, status: .healthy, destinationState: .unconfigured,
            isRunning: false, latestLocalSnapshot: nil, latestCompleteBackup: nil,
            completeBackupAvailability: .unavailable, summaryText: nil, checkedAt: now)
        XCTAssertEqual(evaluate(MyActivityD187Fixtures.health(backup: backup)).grade, .attention)
    }

    func testMissingEvidenceNeverBecomesGood() {
        XCTAssertEqual(evaluate(ComputerHealthSecurityFixture.snapshot(securityState: nil)).reasons, [.incomplete])
        let failed = MyActivityD187Fixtures.health(battery: .failed(reason: .permissionDenied, checkedAt: now))
        XCTAssertEqual(evaluate(failed).grade, .attention)
        let capacity = CapacityTrendSnapshot(availability: .unavailable, status: .healthy, totalBytes: nil,
            availableBytes: nil, availableForImportantUsageBytes: nil, sevenDayDeltaBytes: nil, recordedAt: now)
        XCTAssertEqual(evaluate(MyActivityD187Fixtures.health(capacity: capacity)).reasons, [.incomplete])
    }

    func testUnreadableDiskCannotReuseAFailureFlagAsCurrentEvidence() {
        let disk = DiskHealthSnapshot(availability: .permissionDenied, status: .actionRequired,
            smartStatus: .failing, isTRIMEnabled: nil, fileSystem: nil, summaryText: nil, checkedAt: now)
        let result = evaluate(MyActivityD187Fixtures.health(disk: disk))
        XCTAssertEqual(result.grade, .attention)
        XCTAssertEqual(result.reasons, [.incomplete])
    }

    func testSevenDayBoundaryAndFutureClock() {
        let snapshot = ComputerHealthSecurityFixture.snapshot()
        XCTAssertEqual(MyActivityHealth.evaluate(snapshot, now: now.addingTimeInterval(7 * 86_400)).grade, .good)
        XCTAssertEqual(MyActivityHealth.evaluate(snapshot, now: now.addingTimeInterval(7 * 86_400 + 1)).reasons, [.stale])
        XCTAssertEqual(MyActivityHealth.evaluate(snapshot, now: now.addingTimeInterval(-1)).reasons, [.stale])
    }

    func testMultipleReasonsKeepTheStrongestGradeWithoutDuplicateReasons() {
        let base = ComputerHealthSecurityFixture.snapshot(smart: .failing, availableBytes: 1, backupStatus: .attention)
        let result = evaluate(MyActivityD187Fixtures.health(base: base, battery: MyActivityD187Fixtures.battery(condition: .serviceRecommended)))
        XCTAssertEqual(result.grade, .problem)
        XCTAssertEqual(result.reasons, [.diskFailure, .criticalSpace, .backup, .batteryService])
    }

    func testLatestSnapshotUsesTheNewestExistingSource() {
        let older = ComputerHealthSecurityFixture.snapshot(offset: -1)
        let newer = ComputerHealthSecurityFixture.snapshot()
        XCTAssertEqual(MyActivityHealth.latest(older, newer), newer)
        XCTAssertEqual(MyActivityHealth.latest(newer, older), newer)
        XCTAssertEqual(MyActivityHealth.latest(nil, older), older)
        XCTAssertNil(MyActivityHealth.latest(nil, nil))
    }
}
