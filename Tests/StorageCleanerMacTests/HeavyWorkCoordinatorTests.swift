import Foundation
import XCTest
@testable import StorageCleanerMac

final class HeavyWorkCoordinatorTests: XCTestCase {
    func testAcquireWhenIdleReturnsLeaseAndPublishesActiveOwner() async throws {
        let coordinator = HeavyWorkCoordinator()

        let lease = try await coordinator.acquire(owner: .mainScan)

        let activeOwner = await coordinator.activeOwner
        XCTAssertEqual(lease.owner, .mainScan)
        XCTAssertEqual(activeOwner, .mainScan)
    }

    func testAcquireFailsFastWhenAnotherOwnerIsActive() async throws {
        let coordinator = HeavyWorkCoordinator()
        _ = try await coordinator.acquire(owner: .mainScan)

        await assertAcquire(
            coordinator,
            owner: .duplicateScan,
            throws: .busy(activeOwner: .mainScan)
        )
    }

    func testAcquireRejectsReentrancyFromSameOwner() async throws {
        let coordinator = HeavyWorkCoordinator()
        _ = try await coordinator.acquire(owner: .cleanup)

        await assertAcquire(
            coordinator,
            owner: .cleanup,
            throws: .busy(activeOwner: .cleanup)
        )
    }

    func testMatchingLeaseReleaseMakesCoordinatorIdle() async throws {
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .restore)

        await coordinator.release(lease)

        let activeOwner = await coordinator.activeOwner
        XCTAssertNil(activeOwner)
    }

    func testRepeatedForgedAndExpiredLeaseReleaseCannotReleaseCurrentLease() async throws {
        let coordinator = HeavyWorkCoordinator()
        let expiredLease = try await coordinator.acquire(owner: .mainScan)
        await coordinator.release(expiredLease)
        await coordinator.release(expiredLease)

        let currentLease = try await coordinator.acquire(owner: .emptyTrash)
        let forgedTokenLease = HeavyWorkCoordinator.Lease(
            token: UUID(),
            owner: .emptyTrash
        )
        let forgedOwnerLease = HeavyWorkCoordinator.Lease(
            token: currentLease.token,
            owner: .cleanup
        )

        await coordinator.release(expiredLease)
        await coordinator.release(forgedTokenLease)
        await coordinator.release(forgedOwnerLease)

        let activeOwner = await coordinator.activeOwner
        XCTAssertEqual(activeOwner, .emptyTrash)

        await coordinator.release(currentLease)
        let ownerAfterValidRelease = await coordinator.activeOwner
        XCTAssertNil(ownerAfterValidRelease)
    }

    func testRequireValidAcceptsOnlyMatchingTokenLeaseOwnerAndExpectedOwner() async throws {
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .networkTest)

        try await coordinator.requireValid(lease, owner: .networkTest)

        let wrongToken = HeavyWorkCoordinator.Lease(
            token: UUID(),
            owner: .networkTest
        )
        await assertRequireValid(
            coordinator,
            lease: wrongToken,
            owner: .networkTest,
            throws: .invalidLease(expectedOwner: .networkTest)
        )

        let wrongLeaseOwner = HeavyWorkCoordinator.Lease(
            token: lease.token,
            owner: .memoryOptimization
        )
        await assertRequireValid(
            coordinator,
            lease: wrongLeaseOwner,
            owner: .networkTest,
            throws: .invalidLease(expectedOwner: .networkTest)
        )

        await assertRequireValid(
            coordinator,
            lease: lease,
            owner: .benchmark,
            throws: .invalidLease(expectedOwner: .benchmark)
        )
    }

    func testRequireValidRejectsExpiredLeaseBeforeAndAfterSameOwnerReacquires() async throws {
        let coordinator = HeavyWorkCoordinator()
        let expiredLease = try await coordinator.acquire(owner: .restore)
        await coordinator.release(expiredLease)

        await assertRequireValid(
            coordinator,
            lease: expiredLease,
            owner: .restore,
            throws: .invalidLease(expectedOwner: .restore)
        )

        let currentLease = try await coordinator.acquire(owner: .restore)
        XCTAssertNotEqual(currentLease.token, expiredLease.token)

        await assertRequireValid(
            coordinator,
            lease: expiredLease,
            owner: .restore,
            throws: .invalidLease(expectedOwner: .restore)
        )
        try await coordinator.requireValid(currentLease, owner: .restore)

        let activeOwner = await coordinator.activeOwner
        XCTAssertEqual(activeOwner, .restore)
        await coordinator.release(currentLease)
    }

    func testWithLeaseReturnsGenericValueAndReleasesAfterSuccess() async throws {
        let coordinator = HeavyWorkCoordinator()

        let result = try await coordinator.withLease(owner: .benchmark) { lease in
            try await coordinator.requireValid(lease, owner: .benchmark)
            return "benchmark-complete"
        }

        XCTAssertEqual(result, "benchmark-complete")
        let activeOwner = await coordinator.activeOwner
        XCTAssertNil(activeOwner)
    }

    func testWithLeaseReleasesWhenOperationThrows() async throws {
        let coordinator = HeavyWorkCoordinator()

        do {
            let _: Void = try await coordinator.withLease(owner: .appUpdates) { _ in
                throw OperationFailure.expected
            }
            XCTFail("Expected operation to throw")
        } catch let error as OperationFailure {
            XCTAssertEqual(error, .expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let activeOwner = await coordinator.activeOwner
        XCTAssertNil(activeOwner)
    }

    func testWithLeaseReleasesAfterOperationCancellation() async throws {
        let coordinator = HeavyWorkCoordinator()
        let gate = CancellationGate()
        let task = Task {
            try await coordinator.withLease(owner: .memoryOptimization) { _ in
                try await gate.waitUntilOpened()
            }
        }

        await gate.waitUntilStarted()
        let ownerWhileRunning = await coordinator.activeOwner
        XCTAssertEqual(ownerWhileRunning, .memoryOptimization)

        task.cancel()
        await gate.waitUntilCancellationObserved()

        let ownerBeforeOperationExit = await coordinator.activeOwner
        XCTAssertEqual(ownerBeforeOperationExit, .memoryOptimization)
        await assertAcquire(
            coordinator,
            owner: .benchmark,
            throws: .busy(activeOwner: .memoryOptimization)
        )

        await gate.open()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let ownerAfterCancellation = await coordinator.activeOwner
        XCTAssertNil(ownerAfterCancellation)
    }

    func testCleanupQuarantineSurvivesLeaseReleaseAndBlocksUntilExactClear() async throws {
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .appUpdates)
        let quarantine = try await coordinator.beginCleanupQuarantine(lease)

        await coordinator.release(lease)

        let ownerAfterLeaseRelease = await coordinator.activeOwner
        XCTAssertEqual(ownerAfterLeaseRelease, .appUpdates)
        await assertAcquire(
            coordinator,
            owner: .benchmark,
            throws: .busy(activeOwner: .appUpdates)
        )

        let forgedQuarantine = HeavyWorkCoordinator.CleanupQuarantine(
            token: UUID(),
            owner: .appUpdates
        )
        await coordinator.clearCleanupQuarantine(forgedQuarantine)
        let ownerAfterForgedClear = await coordinator.activeOwner
        XCTAssertEqual(ownerAfterForgedClear, .appUpdates)

        await coordinator.clearCleanupQuarantine(quarantine)
        let ownerAfterVerifiedClear = await coordinator.activeOwner
        XCTAssertNil(ownerAfterVerifiedClear)

        let nextLease = try await coordinator.acquire(owner: .benchmark)
        await coordinator.release(nextLease)
    }

    func testBenchmarkTerminationWaitIncludesCleanupQuarantine() async throws {
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .benchmark)
        let quarantine = try await coordinator.beginCleanupQuarantine(lease)
        await coordinator.release(lease)
        let completion = AsyncBooleanRecorder()

        let waitTask = Task {
            let finished = await coordinator.waitUntilOwnerInactive(
                .benchmark,
                pollInterval: .milliseconds(1)
            )
            await completion.set(finished)
            return finished
        }
        try await Task.sleep(for: .milliseconds(20))
        let completedBeforeClear = await completion.value()
        XCTAssertFalse(completedBeforeClear)

        await coordinator.clearCleanupQuarantine(quarantine)

        let waitFinished = await waitTask.value
        let recordedCompletion = await completion.value()
        XCTAssertTrue(waitFinished)
        XCTAssertTrue(recordedCompletion)
    }

    func testBenchmarkTerminationWaitIsCancellableAndLeavesQuarantineOwned()
        async throws {
        let coordinator = HeavyWorkCoordinator()
        let lease = try await coordinator.acquire(owner: .benchmark)
        let quarantine = try await coordinator.beginCleanupQuarantine(lease)
        await coordinator.release(lease)
        let waitTask = Task {
            await coordinator.waitUntilOwnerInactive(
                .benchmark,
                pollInterval: .milliseconds(1)
            )
        }

        try await Task.sleep(for: .milliseconds(10))
        waitTask.cancel()

        let waitFinished = await waitTask.value
        let activeOwner = await coordinator.activeOwner
        XCTAssertFalse(waitFinished)
        XCTAssertEqual(activeOwner, .benchmark)
        await coordinator.clearCleanupQuarantine(quarantine)
    }

    private func assertAcquire(
        _ coordinator: HeavyWorkCoordinator,
        owner: HeavyWorkCoordinator.Owner,
        throws expectedError: HeavyWorkCoordinator.Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await coordinator.acquire(owner: owner)
            XCTFail("Expected acquire to throw", file: file, line: line)
        } catch let error as HeavyWorkCoordinator.Error {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertRequireValid(
        _ coordinator: HeavyWorkCoordinator,
        lease: HeavyWorkCoordinator.Lease,
        owner: HeavyWorkCoordinator.Owner,
        throws expectedError: HeavyWorkCoordinator.Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await coordinator.requireValid(lease, owner: owner)
            XCTFail("Expected validation to throw", file: file, line: line)
        } catch let error as HeavyWorkCoordinator.Error {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private enum OperationFailure: Error, Equatable {
    case expected
}

private actor AsyncBooleanRecorder {
    private var storedValue = false

    func set(_ value: Bool) {
        storedValue = value
    }

    func value() -> Bool { storedValue }
}

private actor CancellationGate {
    private var started = false
    private var cancellationObserved = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func waitUntilOpened() async throws {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operationContinuation = continuation
            }
        } onCancel: {
            Task { await self.recordCancellationObserved() }
        }
        try Task.checkCancellation()
    }

    private func recordCancellationObserved() {
        cancellationObserved = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func open() {
        operationContinuation?.resume()
        operationContinuation = nil
    }
}
