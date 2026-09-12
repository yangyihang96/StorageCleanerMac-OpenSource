import Foundation

struct BenchmarkUncheckedError: Error, @unchecked Sendable {
    let value: any Error

    init(_ value: any Error) {
        self.value = value
    }
}

struct BenchmarkLateOperation<Value: Sendable>: Sendable {
    fileprivate let task: Task<Result<Value, BenchmarkUncheckedError>, Never>

    func result() async -> Result<Value, BenchmarkUncheckedError> {
        await task.value
    }

    func wait() async {
        _ = await task.value
    }

    var handle: BenchmarkLateOperationHandle {
        BenchmarkLateOperationHandle { await wait() }
    }
}

struct BenchmarkLateOperationHandle: Sendable {
    private let waitOperation: @Sendable () async -> Void

    init(waitOperation: @escaping @Sendable () async -> Void) {
        self.waitOperation = waitOperation
    }

    func wait() async {
        await waitOperation()
    }
}

enum BenchmarkTimedOperationOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(BenchmarkUncheckedError)
    case timedOut(BenchmarkLateOperation<Value>)
    case cancelled(BenchmarkLateOperation<Value>)
    case timerFailure(BenchmarkLateOperation<Value>)
}

enum BenchmarkTimedOperation {
    static func run<Value: Sendable>(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        operation: @escaping @Sendable () async throws -> Value
    ) async -> BenchmarkTimedOperationOutcome<Value> {
        guard timeout > .zero else {
            let task = Task<Result<Value, BenchmarkUncheckedError>, Never> {
                .failure(BenchmarkUncheckedError(
                    BenchmarkTimedOperationError.invalidTimeout
                ))
            }
            return .timerFailure(BenchmarkLateOperation(task: task))
        }

        let race = BenchmarkOperationRace<Value>()
        let operationTask = Task<Result<Value, BenchmarkUncheckedError>, Never> {
            do {
                let value = try await operation()
                race.resolve(.success(value))
                return .success(value)
            } catch {
                let failure = BenchmarkUncheckedError(error)
                race.resolve(.failure(failure))
                return .failure(failure)
            }
        }
        let lateOperation = BenchmarkLateOperation(task: operationTask)
        let timeoutTask = Task<Void, Never> {
            do {
                try await sleep(timeout)
                try Task.checkCancellation()
                race.resolve(.timedOut(lateOperation))
            } catch is CancellationError {
                return
            } catch {
                race.resolve(.timerFailure(lateOperation))
            }
        }

        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            race.resolve(.cancelled(lateOperation))
        }

        switch outcome {
        case .success, .failure:
            timeoutTask.cancel()
        case .timedOut, .cancelled, .timerFailure:
            operationTask.cancel()
            timeoutTask.cancel()
        }
        return outcome
    }

}

private enum BenchmarkTimedOperationError: Error {
    case invalidTimeout
}

private final class BenchmarkOperationRace<Value: Sendable>: @unchecked Sendable {
    typealias Outcome = BenchmarkTimedOperationOutcome<Value>

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ proposedOutcome: Outcome) {
        let continuation: CheckedContinuation<Outcome, Never>?
        lock.lock()
        if outcome == nil {
            outcome = proposedOutcome
            continuation = waiter
            waiter = nil
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: proposedOutcome)
    }
}
