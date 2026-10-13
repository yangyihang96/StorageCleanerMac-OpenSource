import Foundation
import XCTest
@testable import StorageCleanerMac

@MainActor
final class OperationReportTaskLifecycleTests: XCTestCase {
    func testJoinWaitsForPhysicalReadAndQueuedRefresh() async throws {
        let gate = ReceiptReadGate()
        let store = try ScanStore.makeForTests(for: self, interruptedOperationReconciler: { gate.run() })
        addTeardownBlock { @MainActor [weak store] in
            gate.openAll()
            await store?.waitForOperationReportTasksForTesting(cancelPending: true)
        }
        store.refreshOperationReports(reconcile: true)
        try await waitUntil { gate.calls == 1 }
        store.refreshOperationReports(reconcile: true)
        let observation = JoinObservation()
        let waiter = Task { @MainActor in
            observation.started = true
            await store.waitForOperationReportTasksForTesting()
            observation.finished = true
        }
        addTeardownBlock { @MainActor [weak store] in
            gate.openAll()
            await store?.waitForOperationReportTasksForTesting(cancelPending: true)
            await waiter.value
        }
        try await waitUntil { observation.started }
        XCTAssertFalse(observation.finished, "物理读取阻塞时收尾不能返回")
        gate.open(1)
        try await waitUntil { gate.calls == 2 }
        XCTAssertTrue(store.isLoadingOperationReports)
        XCTAssertFalse(observation.finished, "排队刷新仍读回执时收尾不能返回")
        gate.open(2)
        await waiter.value
        XCTAssertTrue(observation.finished)
        XCTAssertFalse(store.isLoadingOperationReports)
        XCTAssertEqual(gate.calls, 2)
    }

    func testCancellationStillJoinsPhysicalReadBeforeFixtureRemoval() async throws {
        let gate = ReceiptReadGate()
        let store = try ScanStore.makeForTests(for: self, interruptedOperationReconciler: { gate.run() })
        addTeardownBlock { @MainActor [weak store] in
            gate.openAll()
            await store?.waitForOperationReportTasksForTesting(cancelPending: true)
        }
        store.refreshOperationReports(reconcile: true)
        try await waitUntil { gate.calls == 1 }
        let observation = JoinObservation()
        let waiter = Task { @MainActor in
            observation.started = true
            await store.waitForOperationReportTasksForTesting(cancelPending: true)
            observation.finished = true
        }
        addTeardownBlock { @MainActor [weak store] in
            gate.openAll()
            await store?.waitForOperationReportTasksForTesting(cancelPending: true)
            await waiter.value
        }
        try await waitUntil { observation.started }
        XCTAssertFalse(observation.finished, "cancel 不等于 detached 读取已经退出")
        XCTAssertTrue(store.isLoadingOperationReports)
        gate.openAll()
        await waiter.value
        XCTAssertTrue(observation.finished)
        XCTAssertFalse(store.isLoadingOperationReports)
    }

    func testStuckPhysicalReadTimesOutAndReportsItsWorkerWithoutHanging() async throws {
        let gate = ReceiptReadGate()
        let store = try ScanStore.makeForTests(for: self, interruptedOperationReconciler: { gate.run() })
        addTeardownBlock { @MainActor [weak store] in
            gate.openAll()
            await store?.waitForOperationReportTasksForTesting(cancelPending: true)
        }
        store.refreshOperationReports(reconcile: true)
        try await waitUntil { gate.calls == 1 }
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("后台任务收尾超时") }
        XCTExpectFailure("不响应取消的物理读取必须按时报告失败", options: options)
        let clock = ContinuousClock()
        let start = clock.now
        let pending = await store.waitForOperationReportTasksForTesting(cancelPending: true, timeout: .milliseconds(100))
        XCTAssertFalse(pending.isEmpty)
        XCTAssertTrue(pending.contains { $0.hasPrefix("operationReportTasks[") })
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2), "100 ms 收尾超时不能挂住整个进程")
        XCTAssertTrue(store.isLoadingOperationReports, "超时不能冒充物理读取已完成")
        gate.openAll()
        let remaining = await store.waitForOperationReportTasksForTesting()
        XCTAssertEqual(remaining, [])
        XCTAssertFalse(store.isLoadingOperationReports)
    }

    func testFactoryTeardownKeepsStoreAliveUntilItsJoin() async throws {
        weak var observed: ScanStore?
        var store: ScanStore? = try ScanStore.makeForTests(for: self)
        await store?.waitForOperationReportTasksForTesting()
        observed = store
        store = nil
        XCTAssertNotNil(observed, "工厂必须持有 store，取消并等待任务后才允许夹具删除")
    }

    private struct Timeout: Error {}
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { XCTFail("等待任务阶段超时"); throw Timeout() }
            await Task.yield()
        }
    }
}

@MainActor
private final class JoinObservation {
    var started = false
    var finished = false
}

/// Blocks only the detached worker; the main actor keeps observing and can open
/// the gate on every failure/timeout path. No sleeps or deletion retries.
private final class ReceiptReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0
    private var released: Set<Int> = []
    private var allOpen = false
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    func run() -> Set<CleanupReportJournal.ReconcileIssue> {
        condition.lock()
        defer { condition.unlock() }
        count += 1
        let stage = count
        while !allOpen && !released.contains(stage) { condition.wait() }
        return []
    }
    func open(_ stage: Int) { condition.lock(); defer { condition.unlock() }; released.insert(stage); condition.broadcast() }
    func openAll() { condition.lock(); defer { condition.unlock() }; allOpen = true; condition.broadcast() }
}
