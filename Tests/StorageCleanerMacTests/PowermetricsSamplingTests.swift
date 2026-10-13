@testable import FanControlShared
import Foundation
import XCTest

final class PowermetricsSamplingTests: XCTestCase {
    func testUnauthorizedCallerCannotConsumeThrottleOrLaunch() async {
        let clock = Clock()
        let sampler = PowermetricsSamplingCoordinator(now: { clock.time }) {
            clock.recordStart(); return .failure(.commandFailed)
        }
        let denied = await sampler.request(authorized: false)
        XCTAssertEqual(denied, .failure(.unauthorized))
        XCTAssertEqual(clock.starts, 0)
        let accepted = await sampler.request(authorized: true)
        XCTAssertEqual(accepted, .failure(.commandFailed))
        XCTAssertEqual(clock.starts, 1)
    }

    func testGlobalTwoSecondThrottleIncludesFailedSamplesAndClockRegression() async {
        let clock = Clock()
        let sampler = PowermetricsSamplingCoordinator(now: { clock.time }) {
            clock.recordStart(); return .failure(.commandFailed)
        }
        _ = await sampler.request(authorized: true)
        for time in [1.999, -1, Double.nan] {
            clock.time = time
            let result = await sampler.request(authorized: true)
            XCTAssertEqual(result, .failure(.throttled))
        }
        clock.time = 2
        _ = await sampler.request(authorized: true)
        XCTAssertEqual(clock.starts, 2)
        XCTAssertEqual(PowermetricsSamplingCoordinator.minimumInterval, 2)
    }

    func testConcurrentRequestsShareOneFlightAndBoundWaiters() async {
        let gate = Gate()
        let sampler = PowermetricsSamplingCoordinator { await gate.run() }
        let tasks = (0..<32).map { _ in Task { await sampler.request(authorized: true) } }
        for _ in 0..<10_000 {
            if await sampler.pendingRequestCount == 32, await gate.isWaiting { break }
            await Task.yield()
        }
        let count = await sampler.pendingRequestCount
        guard count == 32 else {
            await gate.finish(.failure(.timedOut))
            for task in tasks { _ = await task.value }
            return XCTFail("concurrent requests did not all reach the gate")
        }
        // The 33rd request must be refused immediately. Run it detached so a
        // regression that lets it join the flight fails instead of hanging.
        let overflowTask = Task { await sampler.request(authorized: true) }
        let overflowDone = Flag()
        Task { _ = await overflowTask.value; await overflowDone.set() }
        for _ in 0..<10_000 {
            if await overflowDone.value { break }
            await Task.yield()
        }
        let refusedWhileInFlight = await overflowDone.value
        let starts = await gate.starts
        XCTAssertEqual(starts, 1)
        await gate.finish(.failure(.timedOut))
        XCTAssertTrue(refusedWhileInFlight, "the overflow request waited for the flight")
        let overflow = await overflowTask.value
        XCTAssertEqual(overflow, .failure(.busy))
        for task in tasks {
            let result = await task.value
            XCTAssertEqual(result, .failure(.timedOut))
        }
        let drained = await sampler.pendingRequestCount
        XCTAssertEqual(drained, 0)
    }

    func testTimeoutKillsEvenAChildThatNeverExitsAtFiveSeconds() {
        var time = 0.0, killed = 0, reads = 0
        let result = PowermetricsExecutionPolicy.collect(startedAt: 0, now: { time }, read: {
            reads += 1
            return .init(stdout: Data(), stderr: Data(), reachedEOF: false, exitStatus: nil)
        }, kill: { killed += 1 }, pause: { time += 0.25 })
        XCTAssertEqual(result, .failure(.timedOut))
        XCTAssertEqual(time, 5)
        XCTAssertEqual(killed, 1)
        XCTAssertEqual(reads, 20)
        XCTAssertEqual(PowermetricsExecutionPolicy.timeoutSeconds, 5)
    }

    func testOutputBudgetCountsBothPipesAndDropsOversizedResult() {
        for stderrFlood in [false, true] {
            var time = 0.0, killed = 0
            let chunk = Data(repeating: 65, count: 256 * 1_024)
            let result = PowermetricsExecutionPolicy.collect(startedAt: 0, now: { time }, read: {
                .init(stdout: stderrFlood ? Data() : chunk, stderr: stderrFlood ? chunk : Data(),
                      reachedEOF: false, exitStatus: nil)
            }, kill: { killed += 1 }, pause: { time += 0.01 })
            XCTAssertEqual(result, .failure(.outputTooLarge))
            XCTAssertEqual(killed, 1)
            XCTAssertLessThan(time, 0.03)
        }
        var killed = 0
        let result = PowermetricsExecutionPolicy.collect(startedAt: 0, now: { 0 }, read: {
            .init(stdout: Data(repeating: 0, count: 512 * 1_024), stderr: Data([0]), reachedEOF: true, exitStatus: 0)
        }, kill: { killed += 1 }, pause: {})
        XCTAssertEqual(result, .failure(.outputTooLarge))
        XCTAssertEqual(killed, 1)
    }

    func testNonzeroExitAndReadFailureNeverReturnRawOutput() {
        let result = PowermetricsExecutionPolicy.collect(startedAt: 0, now: { 0 }, read: {
            .init(stdout: Data("PRIVATE".utf8), stderr: Data("PRIVATE_ERROR".utf8), reachedEOF: true, exitStatus: 1)
        }, kill: { XCTFail("the child already exited") }, pause: {})
        XCTAssertEqual(result, .failure(.commandFailed))
        var killed = 0
        let failedRead = PowermetricsExecutionPolicy.collect(startedAt: 0, now: { 0 }, read: {
            throw PowermetricsFailure.commandFailed
        }, kill: { killed += 1 }, pause: {})
        XCTAssertEqual(failedRead, .failure(.commandFailed))
        XCTAssertEqual(killed, 1)
    }

    func testSuccessfulExecutionWaitsForPipeEOFAndReturnsOnlyTheDTO() throws {
        let data = try PropertyListSerialization.data(fromPropertyList:
            ["elapsed_ns": 1_000_000_000, "processor": ["cpu_power": 12]], format: .xml, options: 0)
        var readCount = 0
        let result = PowermetricsExecutionPolicy.collect(startedAt: 0, now: { 0 }, read: {
            readCount += 1
            return .init(stdout: readCount == 1 ? data : Data(), stderr: Data(),
                         reachedEOF: readCount == 2, exitStatus: 0)
        }, kill: { XCTFail("successful execution must not be killed") }, pause: {})
        guard case .sample(let sample) = result else { return XCTFail("missing parsed reply") }
        XCTAssertEqual(sample.cpuMilliwatts, 12)
        XCTAssertEqual(readCount, 2)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        private var count = 0
        var time: Double {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
        var starts: Int { lock.withLock { count } }
        func recordStart() { lock.withLock { count += 1 } }
    }
    private actor Flag {
        private(set) var value = false
        func set() { value = true }
    }
    private actor Gate {
        var starts = 0
        private var continuation: CheckedContinuation<PowermetricsResult, Never>?
        private var earlyResult: PowermetricsResult?
        var isWaiting: Bool { continuation != nil }
        func run() async -> PowermetricsResult {
            starts += 1
            if let earlyResult { return earlyResult }
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ result: PowermetricsResult) {
            earlyResult = result
            continuation?.resume(returning: result)
            continuation = nil
        }
    }
}
