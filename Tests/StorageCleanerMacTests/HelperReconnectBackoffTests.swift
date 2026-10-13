import XCTest
@testable import StorageCleanerMac

final class HelperReconnectBackoffTests: XCTestCase {
    func testManualGateHasNoResetAndRejectsInvalidOrEarlierTime() {
        var manual = HelperManualReconnectCooldown()
        XCTAssertFalse(manual.admit(at: .nan))
        XCTAssertTrue(manual.admit(at: 100))
        for time in [99, 100, 109.999] {
            XCTAssertFalse(manual.admit(at: time))
        }
        XCTAssertEqual(manual.remainingSeconds(at: 109.999), 1)
        XCTAssertEqual(manual.remainingSeconds(at: 110), 0)
        XCTAssertTrue(manual.admit(at: 110))
        XCTAssertEqual(manual.nextAttemptAt, 120)
    }

    func testExponentialDelayJitterAndFiveMinuteCap() {
        for jitter in [0.0, 0.5, 1.0] {
            var backoff = HelperReconnectBackoff()
            var time = 0.0
            for index in 0..<20 {
                XCTAssertTrue(backoff.permitsAttempt(at: time))
                backoff.recordFailure(at: time, jitter: jitter)
                let delay = backoff.remainingDelay(at: time)
                XCTAssertEqual(delay, min(300, min(300, pow(2, Double(min(index, 9)))) * (0.8 + 0.4 * jitter)), accuracy: 0.00001)
                XCTAssertGreaterThanOrEqual(delay, 0.8)
                XCTAssertLessThanOrEqual(delay, 300)
                XCTAssertFalse(backoff.permitsAttempt(at: time + delay - 0.001))
                time += delay
            }
        }
    }

    func testTenMinuteAttemptBoundHoldsForEveryJitterExtreme() {
        for jitter in [0.0, 0.5, 1.0] {
            var backoff = HelperReconnectBackoff()
            var attempts = 0
            for tick in 0...24_000 {
                let time = Double(tick) / 40
                if backoff.permitsAttempt(at: time) {
                    attempts += 1
                    backoff.recordFailure(at: time, jitter: jitter)
                }
            }
            XCTAssertGreaterThan(attempts, 1)
            XCTAssertLessThanOrEqual(attempts, 15)
        }
    }

    func testResetClearsDeadlineAndSuccessRestartsAtFirstDelay() {
        var backoff = HelperReconnectBackoff()
        for _ in 0..<20 { backoff.recordFailure(at: 100, jitter: 0.5) }
        XCTAssertEqual(backoff.remainingDelay(at: 100), 300)
        backoff.reset()
        XCTAssertTrue(backoff.permitsAttempt(at: 100))
        XCTAssertEqual(backoff.failureCount, 0)
        backoff.recordFailure(at: 100, jitter: 0.5)
        XCTAssertEqual(backoff.remainingDelay(at: 100), 1)
    }

    func testNonFiniteClockCannotOpenAdmissionAndJitterIsClamped() {
        var backoff = HelperReconnectBackoff()
        XCTAssertFalse(backoff.permitsAttempt(at: .nan))
        XCTAssertFalse(backoff.permitsAttempt(at: .infinity))
        for jitter in [-100.0, 100, .nan, .infinity] {
            backoff.reset()
            backoff.recordFailure(at: 10, jitter: jitter)
            XCTAssertTrue(backoff.remainingDelay(at: 10).isFinite)
            XCTAssertGreaterThanOrEqual(backoff.remainingDelay(at: 10), 0.8)
            XCTAssertLessThanOrEqual(backoff.remainingDelay(at: 10), 1.2)
        }
    }
}
