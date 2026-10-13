import Foundation
import XCTest
@testable import StorageCleanerMac

extension ScanStore {
    /// One deadline covers all producers, physical reads and queued refreshes.
    /// Unstructured observers are deliberate: a task group would join a stuck
    /// non-cancellable gate even after its timeout child won.
    @discardableResult
    func waitForOperationReportTasksForTesting(
        cancelPending: Bool = false,
        timeout: Duration = .seconds(30),
        file: StaticString = #filePath, line: UInt = #line
    ) async -> [String] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let producers = operationReportProducersForTesting
        var pending = await TestOperationReportJoin.wait(producers, cancelPending: cancelPending, deadline: deadline)
        if !pending.isEmpty {
            let workers = operationReportWorkersForTesting
            if cancelPending { workers.forEach { $0.task.cancel() } }
            pending += workers.map(\.name)
        } else {
            while !operationReportWorkersForTesting.isEmpty {
                pending = await TestOperationReportJoin.wait(
                    operationReportWorkersForTesting, cancelPending: cancelPending, deadline: deadline)
                if !pending.isEmpty { break }
            }
        }
        if !pending.isEmpty {
            pending = Array(Set(pending)).sorted()
            XCTFail("后台任务收尾超时或等待被取消；未结束：\(pending.joined(separator: ", "))", file: file, line: line)
        }
        return pending
    }
}

@MainActor
enum TestOperationReportJoin {
    private final class Observation {
        var pending: Set<String>
        init(_ names: [String]) { pending = Set(names) }
    }

    static func wait(
        _ tasks: [(name: String, task: Task<Void, Never>)],
        cancelPending: Bool, deadline: ContinuousClock.Instant
    ) async -> [String] {
        let observation = Observation(tasks.map(\.name))
        let observers = tasks.map { name, task in
            if cancelPending { task.cancel() }
            return Task { @MainActor in
                await task.value
                observation.pending.remove(name)
            }
        }
        defer { observers.forEach { $0.cancel() } }
        let clock = ContinuousClock()
        while !observation.pending.isEmpty {
            guard clock.now < deadline else { return observation.pending.sorted() }
            do { try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(10)))) }
            catch { return observation.pending.sorted() }
        }
        return []
    }
}
