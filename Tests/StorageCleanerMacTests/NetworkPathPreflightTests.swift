import Dispatch
import Foundation
import XCTest
@testable import StorageCleanerMac

final class NetworkPathPreflightTests: XCTestCase {
    func testPreflightDistinguishesOfflineExpensiveAndConstrained() async throws {
        let offline = try await probe(status: .unsatisfied)
        let expensive = try await probe(status: .satisfied, expensive: true)
        let constrained = try await probe(status: .satisfied, constrained: true)
        let ready = try await probe(status: .satisfied, interfaces: [.wifi])

        XCTAssertEqual(offline, .offline)
        XCTAssertEqual(expensive, .warning(.expensive))
        XCTAssertEqual(constrained, .warning(.constrained))
        XCTAssertEqual(ready, .ready(interface: .wifi))
    }

    func testOfflineThenExpensiveTakePriorityOverOtherPathProperties() async throws {
        let offline = try await probe(
            status: .unsatisfied,
            expensive: true,
            constrained: true,
            interfaces: [.wifi]
        )
        let expensive = try await probe(
            status: .satisfied,
            expensive: true,
            constrained: true,
            interfaces: [.wifi]
        )

        XCTAssertEqual(offline, .offline)
        XCTAssertEqual(expensive, .warning(.expensive))
    }

    func testReadyPathMapsInterfacesWithoutRetainingNetworkAddresses() async throws {
        let wired = try await probe(status: .satisfied, interfaces: [.wired])
        let cellular = try await probe(status: .satisfied, interfaces: [.cellular])
        let other = try await probe(status: .satisfied, interfaces: [])
        let prioritized = try await probe(
            status: .satisfied,
            interfaces: [.cellular, .wired, .wifi]
        )

        XCTAssertEqual(wired, .ready(interface: .wired))
        XCTAssertEqual(cellular, .ready(interface: .cellular))
        XCTAssertEqual(other, .ready(interface: .other))
        XCTAssertEqual(prioritized, .ready(interface: .wifi))
    }

    func testFirstPathWinsAndSourceIsCancelledExactlyOnce() async throws {
        let source = FakeNetworkPathSource(updates: [
            .init(status: .satisfied, interfaces: [.wifi]),
            .init(status: .unsatisfied, interfaces: [])
        ])
        let preflight = NetworkPathPreflight(sourceFactory: { source })

        let result = try await preflight.probe()

        XCTAssertEqual(result, .ready(interface: .wifi))
        await waitUntil { source.deliveredUpdateCount == 2 }
        XCTAssertEqual(source.cancelCount, 1)
        XCTAssertEqual(source.startCount, 1)
    }

    func testTaskCancellationCancelsSourceAndLatePathCannotResumeAgain() async {
        let source = FakeNetworkPathSource()
        let preflight = NetworkPathPreflight(sourceFactory: { source })
        let task = Task { try await preflight.probe() }
        await waitUntil { source.hasStarted }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        source.emitIgnoringCancellation(.init(status: .satisfied, interfaces: [.wifi]))
        await waitUntil { source.deliveredUpdateCount == 1 }
        XCTAssertEqual(source.cancelCount, 1)
    }

    func testAlreadyCancelledTaskCancelsWithoutStartingMonitor() async {
        let source = FakeNetworkPathSource()
        let preflight = NetworkPathPreflight(sourceFactory: { source })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preflight.probe()
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(source.cancelCount, 1)
        XCTAssertEqual(source.startCount, 0)
    }

    func testCancellationWhileSourceStartIsBlockedCannotLeaveSourceActive() async {
        let source = BlockingStartNetworkPathSource()
        let preflight = NetworkPathPreflight(sourceFactory: { source })
        let task = Task { try await preflight.probe() }
        await waitUntil { source.hasEnteredStart }

        task.cancel()
        source.releaseStart()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await waitUntil { source.cancelCount == 1 }
        XCTAssertFalse(source.isActive)
        XCTAssertFalse(source.hasUpdateHandler)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.cancelCount, 1)
    }

    private func probe(
        status: NetworkPathSnapshot.Status,
        expensive: Bool = false,
        constrained: Bool = false,
        interfaces: Set<NetworkPathInterface> = [.wifi]
    ) async throws -> NetworkPathPreflightResult {
        let source = FakeNetworkPathSource(updates: [
            .init(
                status: status,
                isExpensive: expensive,
                isConstrained: constrained,
                interfaces: interfaces
            )
        ])
        return try await NetworkPathPreflight(sourceFactory: { source }).probe()
    }

    private func waitUntil(
        attempts: Int = 1_000,
        _ predicate: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<attempts {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous fake source state")
    }
}

private final class BlockingStartNetworkPathSource: NetworkPathSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private let startGate = DispatchSemaphore(value: 0)
    private var enteredStart = false
    private var active = false
    private var starts = 0
    private var cancellations = 0
    private var updateHandler: (@Sendable (NetworkPathSnapshot) -> Void)?

    var hasEnteredStart: Bool { withLock { enteredStart } }
    var isActive: Bool { withLock { active } }
    var hasUpdateHandler: Bool { withLock { updateHandler != nil } }
    var startCount: Int { withLock { starts } }
    var cancelCount: Int { withLock { cancellations } }

    func start(
        queue _: DispatchQueue,
        updateHandler: @escaping @Sendable (NetworkPathSnapshot) -> Void
    ) {
        withLock {
            enteredStart = true
            starts += 1
        }
        startGate.wait()
        withLock {
            active = true
            self.updateHandler = updateHandler
        }
    }

    func cancel() {
        withLock {
            cancellations += 1
            active = false
            updateHandler = nil
        }
    }

    func releaseStart() {
        startGate.signal()
    }

    @discardableResult
    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class FakeNetworkPathSource: NetworkPathSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private let initialUpdates: [NetworkPathSnapshot]
    private var updateHandler: (@Sendable (NetworkPathSnapshot) -> Void)?
    private var callbackQueue: DispatchQueue?
    private var starts = 0
    private var cancellations = 0
    private var deliveries = 0

    init(updates: [NetworkPathSnapshot] = []) {
        initialUpdates = updates
    }

    var hasStarted: Bool { withLock { starts > 0 } }
    var startCount: Int { withLock { starts } }
    var cancelCount: Int { withLock { cancellations } }
    var deliveredUpdateCount: Int { withLock { deliveries } }

    func start(
        queue: DispatchQueue,
        updateHandler: @escaping @Sendable (NetworkPathSnapshot) -> Void
    ) {
        withLock {
            starts += 1
            callbackQueue = queue
            self.updateHandler = updateHandler
        }
        for update in initialUpdates {
            emitIgnoringCancellation(update)
        }
    }

    func cancel() {
        withLock { cancellations += 1 }
    }

    func emitIgnoringCancellation(_ update: NetworkPathSnapshot) {
        let callback: (DispatchQueue, @Sendable (NetworkPathSnapshot) -> Void)? = withLock {
            guard let callbackQueue, let updateHandler else { return nil }
            return (callbackQueue, updateHandler)
        }
        callback?.0.async { [weak self] in
            self?.withLock { self?.deliveries += 1 }
            callback?.1(update)
        }
    }

    @discardableResult
    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
