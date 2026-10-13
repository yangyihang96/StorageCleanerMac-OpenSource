import FanControlShared
import Foundation
import XCTest

final class MacMiniLockRetryTests: XCTestCase {
    func testBusyLockUsesBoundedBackoffAndSucceedsWhenReleased() {
        var attempts = 0
        var waits: [TimeInterval] = []
        XCTAssertTrue(MacMiniLockRetry.acquire(tryAcquire: { attempts += 1; return attempts == 3 },
            pause: { waits.append($0) }))
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(waits, [0.05, 0.10])
    }

    func testPermanentContentionStopsAfterSixAttempts() {
        var attempts = 0
        var waits: [TimeInterval] = []
        XCTAssertFalse(MacMiniLockRetry.acquire(tryAcquire: { attempts += 1; return false }, pause: { waits.append($0) }))
        XCTAssertEqual(attempts, 6)
        XCTAssertEqual(waits, [0.05, 0.10, 0.20, 0.40, 0.80])
        XCTAssertEqual(waits.reduce(0, +), 1.55, accuracy: 0.0001)
    }

    func testDeferredBootstrapRetainsWorkAndLoadsOnlyAfterAcquisition() {
        var available = false
        var loads = 0
        var releases = 0
        let intent = MacMiniPersistedState(mode: .whenOnAC, ownsSleepDisabled: true)
        let bootstrap = MacMiniDeferredBootstrap<MacMiniPersistedState>(acquire: { available },
            release: { releases += 1 }, load: { loads += 1; return intent })
        XCTAssertNil(bootstrap.retry())
        XCTAssertTrue(bootstrap.isPending)
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(releases, 0)
        available = true
        XCTAssertEqual(bootstrap.retry(), intent)
        XCTAssertFalse(bootstrap.isPending)
        XCTAssertEqual(bootstrap.retry(), intent)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(releases, 1)
    }
    func testDeferredBootstrapRechecksAnInitiallyUnknownBindingOnceVerified() {
        var bindingKnown = false
        var loads = 0
        let bootstrap = MacMiniDeferredBootstrap<MacMiniPersistedState>(acquire: { true }, release: {}, load: {
            loads += 1
            return .init(mode: bindingKnown ? .off : .whenOnAC, ownsSleepDisabled: true)
        })
        XCTAssertEqual(bootstrap.retry()?.mode, .whenOnAC)
        bindingKnown = true
        XCTAssertEqual(bootstrap.retry(reloadWhen: { _ in true })?.mode, .off)
        XCTAssertEqual(loads, 2)
        XCTAssertTrue(bootstrap.retry()?.ownsSleepDisabled == true)
        XCTAssertEqual(loads, 2)
    }

}
