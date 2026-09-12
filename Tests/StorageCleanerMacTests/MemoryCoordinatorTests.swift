import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class MemoryCoordinatorTests: XCTestCase {
    func testSuccessfulPlanVerifiesExitMeasuresActualChangeAndIsSingleUse() async throws {
        let before = makeSnapshot(appBytes: 2_000, availableBytes: 4_000)
        let after = makeSnapshot(appBytes: 500, availableBytes: 5_200)
        let probe = FakeMemoryProbe(snapshots: [after])
        let process = makeProcess(id: 101, bytes: 1_500)
        let applications = FakeMemoryApplicationController(
            statuses: [process.id: [.ready, .ready, .targetExited]]
        )
        let coordinator = MemoryCoordinator(
            probe: probe,
            applications: applications,
            clock: ImmediateMemoryClock(),
            pollInterval: .milliseconds(1),
            gracefulQuitTimeout: .milliseconds(2)
        )

        let plan = try coordinator.makePlan(processes: [process], snapshot: before)
        let result = try await coordinator.execute(planID: plan.id, before: before)

        XCTAssertEqual(result.completion, .completed)
        XCTAssertEqual(result.targetResults.map(\.outcome), [.gracefulQuitSucceeded])
        XCTAssertEqual(result.observedApplicationMemoryDeltaBytes, 1_500)
        XCTAssertEqual(result.observedAvailableMemoryDeltaBytes, 1_200)
        XCTAssertEqual(applications.gracefulRequests, [process.id])
        XCTAssertTrue(applications.forceRequests.isEmpty)

        do {
            _ = try await coordinator.execute(planID: plan.id, before: before)
            XCTFail("A consumed plan must not execute twice")
        } catch let error as MemoryOptimizationCoordinatorError {
            XCTAssertEqual(error, .planAlreadyConsumed)
        }
    }

    func testIdentityChangeFailsPreflightWithoutSendingQuitRequest() async throws {
        let snapshot = makeSnapshot()
        let process = makeProcess(id: 102)
        let applications = FakeMemoryApplicationController(
            statuses: [process.id: [.ready, .identityChanged]]
        )
        let coordinator = MemoryCoordinator(
            probe: FakeMemoryProbe(snapshots: [snapshot]),
            applications: applications,
            clock: ImmediateMemoryClock()
        )

        let plan = try coordinator.makePlan(processes: [process], snapshot: snapshot)
        let result = try await coordinator.execute(planID: plan.id, before: snapshot)

        XCTAssertEqual(result.completion, .partial)
        XCTAssertEqual(result.targetResults.map(\.outcome), [.identityChanged])
        XCTAssertTrue(applications.gracefulRequests.isEmpty)
    }

    func testGracefulTimeoutNeverEscalatesToForceQuit() async throws {
        let snapshot = makeSnapshot()
        let process = makeProcess(id: 103)
        let applications = FakeMemoryApplicationController(
            statuses: [process.id: [.ready, .ready, .ready, .ready]]
        )
        let coordinator = MemoryCoordinator(
            probe: FakeMemoryProbe(snapshots: [snapshot]),
            applications: applications,
            clock: ImmediateMemoryClock(),
            pollInterval: .milliseconds(1),
            gracefulQuitTimeout: .milliseconds(2)
        )

        let plan = try coordinator.makePlan(processes: [process], snapshot: snapshot)
        let result = try await coordinator.execute(planID: plan.id, before: snapshot)

        XCTAssertEqual(result.targetResults.map(\.outcome), [.timedOut])
        XCTAssertEqual(applications.gracefulRequests, [process.id])
        XCTAssertTrue(applications.forceRequests.isEmpty)
    }

    func testForceQuitRequiresIndependentApproval() async throws {
        let snapshot = makeSnapshot()
        let process = makeProcess(id: 104)
        let applications = FakeMemoryApplicationController(
            statuses: [process.id: [.ready, .ready, .targetExited]]
        )
        let coordinator = MemoryCoordinator(
            probe: FakeMemoryProbe(snapshots: [snapshot]),
            applications: applications,
            clock: ImmediateMemoryClock()
        )
        let graceful = try coordinator.makePlan(processes: [process], snapshot: snapshot)
        let forcePlan = try coordinator.requestForceQuitPlan(planID: graceful.id)

        do {
            _ = try await coordinator.execute(planID: forcePlan.id, before: snapshot)
        } catch let error as MemoryOptimizationCoordinatorError {
            XCTAssertEqual(error, .forceQuitRequiresIndependentApproval)
        }
        XCTAssertTrue(applications.forceRequests.isEmpty)

        let result = try await coordinator.execute(
            planID: forcePlan.id,
            before: snapshot,
            forceQuitApproved: true
        )
        XCTAssertEqual(result.targetResults.map(\.outcome), [.forceQuitSucceeded])
        XCTAssertEqual(applications.forceRequests, [process.id])
    }

    func testCancellationStopsRemainingTargetsAndSkipsVerification() async throws {
        let snapshot = makeSnapshot()
        let first = makeProcess(id: 105)
        let second = makeProcess(id: 106)
        let applications = FakeMemoryApplicationController(statuses: [
            first.id: [.ready, .ready, .ready, .ready],
            second.id: [.ready, .ready],
        ])
        let coordinator = MemoryCoordinator(
            probe: FakeMemoryProbe(snapshots: [snapshot]),
            applications: applications,
            clock: DelayedMemoryClock(),
            pollInterval: .milliseconds(5),
            gracefulQuitTimeout: .milliseconds(20)
        )
        let plan = try coordinator.makePlan(processes: [first, second], snapshot: snapshot)

        let task = Task {
            try await coordinator.execute(planID: plan.id, before: snapshot)
        }
        try await Task.sleep(for: .milliseconds(2))
        coordinator.cancel()
        let result = try await task.value

        XCTAssertEqual(result.completion, .cancelled)
        XCTAssertEqual(applications.gracefulRequests, [first.id])
        XCTAssertFalse(applications.gracefulRequests.contains(second.id))
        XCTAssertNil(result.snapshotAfter)
    }

    func testUnavailableVerificationIsReportedInsteadOfZero() async throws {
        let before = makeSnapshot()
        let unavailable = makeSnapshot(quality: .unavailable)
        let process = makeProcess(id: 107)
        let applications = FakeMemoryApplicationController(
            statuses: [process.id: [.ready, .ready, .targetExited]]
        )
        let coordinator = MemoryCoordinator(
            probe: FakeMemoryProbe(snapshots: [unavailable]),
            applications: applications,
            clock: ImmediateMemoryClock()
        )

        let plan = try coordinator.makePlan(processes: [process], snapshot: before)
        let result = try await coordinator.execute(planID: plan.id, before: before)

        XCTAssertEqual(result.completion, .verificationFailed)
        XCTAssertNil(result.snapshotAfter)
        XCTAssertNil(result.pressureAfter)
    }

    func testPermissionRevocationAndRejectedRequestProducePartialResult() async throws {
        let snapshot = makeSnapshot()
        let rejected = makeProcess(id: 108)
        let revoked = makeProcess(id: 109)
        let applications = FakeMemoryApplicationController(
            statuses: [
                rejected.id: [.ready, .ready],
                revoked.id: [.ready, .permissionDenied],
            ],
            gracefulAcceptance: [rejected.id: false]
        )
        let coordinator = MemoryCoordinator(
            probe: FakeMemoryProbe(snapshots: [snapshot]),
            applications: applications,
            clock: ImmediateMemoryClock()
        )

        let plan = try coordinator.makePlan(
            processes: [rejected, revoked],
            snapshot: snapshot
        )
        let result = try await coordinator.execute(planID: plan.id, before: snapshot)

        XCTAssertEqual(result.completion, .partial)
        XCTAssertEqual(
            result.targetResults.map(\.outcome),
            [.requestRejected, .verificationUnavailable]
        )
        XCTAssertEqual(applications.gracefulRequests, [rejected.id])
    }

    private func makeProcess(id: Int32, bytes: Int64 = 700) -> MemoryProcess {
        let appPath = "/Applications/Example\(id).app"
        return MemoryProcess(
            id: id,
            name: "Example \(id)",
            path: "\(appPath)/Contents/MacOS/Example",
            iconPath: appPath,
            bundlePath: appPath,
            residentBytes: bytes,
            percent: 1,
            canQuit: true,
            bundleIdentifier: "com.example.\(id)",
            launchDate: Date(timeIntervalSince1970: TimeInterval(id)),
            userIdentifier: UInt32(getuid()),
            capturedAt: Date(timeIntervalSince1970: 1_000),
            dataSource: .procPIDRUsage,
            availability: .available
        )
    }

    private func makeSnapshot(
        appBytes: UInt64 = 2_000,
        availableBytes: UInt64 = 4_000,
        quality: MeasurementQuality = .complete
    ) -> MemorySnapshot {
        let measurements = MemoryMeasurements(
            pressure: .available(.normal),
            physicalBytes: .available(8_000),
            availableBytes: .available(availableBytes),
            appBytes: .available(appBytes),
            wiredBytes: .available(1_000),
            compressedBytes: .available(500),
            cachedBytes: .available(1_000),
            swapUsedBytes: .available(0),
            swapInRate: .available(0),
            swapOutRate: .available(0)
        )
        return MemorySnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            physicalBytes: 8_000,
            freeBytes: Int64(clamping: availableBytes),
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 0,
            purgeableBytes: 0,
            wiredBytes: 1_000,
            compressedBytes: 500,
            swapUsedBytes: 0,
            pressureFreePercentage: 50,
            pressureSummary: "Pressure headroom 50%",
            topProcesses: [],
            measurements: measurements,
            quality: quality
        )
    }
}

private actor FakeMemoryProbe: MemoryProbing {
    private var snapshots: [MemorySnapshot]

    init(snapshots: [MemorySnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot(includeProcesses: Bool) -> MemorySnapshot {
        _ = includeProcesses
        if snapshots.count > 1 {
            return snapshots.removeFirst()
        }
        return snapshots[0]
    }
}

@MainActor
private final class FakeMemoryApplicationController: MemoryApplicationControlling {
    private var statuses: [Int32: [MemoryPreflightStatus]]
    private let gracefulAcceptance: [Int32: Bool]
    var gracefulRequests: [Int32] = []
    var forceRequests: [Int32] = []

    init(
        statuses: [Int32: [MemoryPreflightStatus]],
        gracefulAcceptance: [Int32: Bool] = [:]
    ) {
        self.statuses = statuses
        self.gracefulAcceptance = gracefulAcceptance
    }

    func preflight(_ target: MemoryOptimizationTarget) -> MemoryPreflightStatus {
        let pid = target.identity.processIdentifier
        guard var values = statuses[pid], !values.isEmpty else { return .targetExited }
        let value = values.removeFirst()
        statuses[pid] = values
        return value
    }

    func requestGracefulQuit(_ target: MemoryOptimizationTarget) -> Bool {
        let processIdentifier = target.identity.processIdentifier
        gracefulRequests.append(processIdentifier)
        return gracefulAcceptance[processIdentifier] ?? true
    }

    func requestForceQuit(_ target: MemoryOptimizationTarget) -> Bool {
        forceRequests.append(target.identity.processIdentifier)
        return true
    }
}

private struct ImmediateMemoryClock: MemoryExecutionClock {
    func sleep(for duration: Duration) async throws {
        _ = duration
        try Task.checkCancellation()
    }
}

private struct DelayedMemoryClock: MemoryExecutionClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
