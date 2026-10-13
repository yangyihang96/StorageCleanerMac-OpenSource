import Foundation
import XCTest
@testable import StorageCleanerMac

// These shared helpers are also compiled by SwiftPM's Release test target.
enum HeavyWorkObservationTestWait {
    @MainActor
    static func until(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}

@MainActor
final class HeavyWorkActivityStoreTests: XCTestCase {
    func testEveryOwnerPublishesCompletionWithoutPageRefresh() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        for owner in HeavyWorkCoordinator.Owner.allCases {
            let gate = StartupSleepGate()
            let task = Task {
                try await coordinator.withLease(owner: owner) { _ in try await gate.sleep(1) }
            }
            try await StartupTestWait.until { await gate.delays.count == 1 }
            let acquired = await HeavyWorkObservationTestWait.until { activity.activeOwner == owner }
            XCTAssertTrue(acquired, "acquisition must publish \(owner) without a page task")
            XCTAssertEqual(activity.activeOwner, owner)
            XCTAssertNotNil(activity.conflictMessage)
            XCTAssertNotNil(activity.navigationDestination)
            await gate.release()
            try await task.value
            let completed = await HeavyWorkObservationTestWait.until { activity.activeOwner == nil }
            XCTAssertTrue(completed, "the real \(owner) completion must clear the store")
            XCTAssertNil(activity.activeOwner, "no stale owner after \(owner) has released its lease")
            XCTAssertNil(activity.conflictMessage)
            XCTAssertNil(activity.navigationDestination)
        }
    }

    func testCleanupQuarantineRemainsBusyUntilRealClearThenPublishesIdle() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let lease = try await coordinator.acquire(owner: .benchmark)
        let acquired = await HeavyWorkObservationTestWait.until { activity.activeOwner == .benchmark }
        XCTAssertTrue(acquired)
        let quarantine = try await coordinator.beginCleanupQuarantine(lease)
        await coordinator.release(lease)
        let quarantinedState = await coordinator.ownerState
        XCTAssertEqual(quarantinedState.owner, .benchmark)
        XCTAssertEqual(activity.activeOwner, .benchmark, "releasing the lease cannot hide live cleanup")
        await coordinator.clearCleanupQuarantine(quarantine)
        let completed = await HeavyWorkObservationTestWait.until { activity.activeOwner == nil }
        XCTAssertTrue(completed)
        XCTAssertNil(activity.activeOwner)
        XCTAssertNil(activity.conflictMessage)
        XCTAssertNil(activity.navigationDestination)
    }

    func testStoreCreatedDuringExistingLeaseObservesSnapshotAndLaterRelease() async throws {
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .benchmark)
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let acquired = await HeavyWorkObservationTestWait.until { activity.activeOwner == .benchmark }
        XCTAssertTrue(acquired, "atomic registration includes the already-active lease")
        XCTAssertEqual(activity.activeOwner, .benchmark)
        await coordinator.release(lease)
        let completed = await HeavyWorkObservationTestWait.until { activity.activeOwner == nil }
        XCTAssertTrue(completed)
        XCTAssertNil(activity.activeOwner)
    }

    func testCancelledAndThrowingOperationsPublishIdleThroughLeaseDefer() async throws {
        for cancelled in [false, true] {
            let coordinator = HeavyWorkCoordinator()
            let activity = HeavyWorkActivityStore(coordinator: coordinator)
            let gate = StartupSleepGate()
            let task = Task {
                try await coordinator.withLease(owner: .mainScan) { _ in
                    try await gate.sleep(1)
                    throw HeavyWorkObservationFixtureFailure.expected
                }
            }
            try await StartupTestWait.until { await gate.delays.count == 1 }
            let acquired = await HeavyWorkObservationTestWait.until { activity.activeOwner == .mainScan }
            XCTAssertTrue(acquired)
            if cancelled { task.cancel() }
            await gate.release()
            do { try await task.value; XCTFail("controlled operation must fail") }
            catch is CancellationError { XCTAssertTrue(cancelled) }
            catch HeavyWorkObservationFixtureFailure.expected { XCTAssertFalse(cancelled) }
            catch { XCTFail("Unexpected error: \(error)") }
            let completed = await HeavyWorkObservationTestWait.until { activity.activeOwner == nil }
            XCTAssertTrue(completed)
            XCTAssertNil(activity.activeOwner)
            XCTAssertNil(activity.conflictMessage)
        }
    }

    func testObservationDoesNotRetainReleasedStore() async throws {
        let coordinator = HeavyWorkCoordinator()
        var activity: HeavyWorkActivityStore? = HeavyWorkActivityStore(coordinator: coordinator)
        weak var weakActivity = activity
        let lease = try await coordinator.acquire(owner: .benchmark)
        let acquired = await HeavyWorkObservationTestWait.until { activity?.activeOwner == .benchmark }
        XCTAssertTrue(acquired)
        activity = nil
        XCTAssertNil(weakActivity, "the lifetime task must not retain its owning store")
        await coordinator.release(lease)
        let owner = await coordinator.activeOwner
        XCTAssertNil(owner)
    }

    func testLateConflictAfterRealReleaseCannotLeaveStaleOwner() async throws {
        let coordinator = HeavyWorkCoordinator()
        let activity = HeavyWorkActivityStore(coordinator: coordinator)
        let lease = try await coordinator.acquire(owner: .benchmark)
        let acquired = await HeavyWorkObservationTestWait.until { activity.activeOwner == .benchmark }
        XCTAssertTrue(acquired)
        await coordinator.release(lease)
        let idle = await HeavyWorkObservationTestWait.until { activity.activeOwner == nil }
        XCTAssertTrue(idle)
        activity.reportConflict(activeOwner: .benchmark)
        XCTAssertEqual(activity.activeOwner, .benchmark, "the conflict initially retains its UI context")
        let reconciled = await HeavyWorkObservationTestWait.until { activity.activeOwner == nil }
        XCTAssertTrue(reconciled, "a delayed busy error cannot resurrect an ended lease")
        XCTAssertNil(activity.activeOwner)
        XCTAssertNil(activity.conflictMessage)
        XCTAssertNil(activity.navigationDestination)
    }
}

private enum HeavyWorkObservationFixtureFailure: Error { case expected }
