import XCTest
@testable import StorageCleanerMac

/// Only service identities and names survive a pass; events stay live.
final class HIDTemperatureMetadataCacheTests: XCTestCase {
    func testStableGraphParsesEachNameOnceAndReadsEveryEventEveryPass() throws {
        let driver = CountingHIDTemperatureDriver()
        driver.graph = [1, 2]
        driver.names = [1: "SoC MTR Temp", 2: "PMU tdie1"]
        driver.values = [1: 45, 2: 40]
        let cache = HIDTemperatureMetadataCache(driver: driver)
        XCTAssertEqual(try XCTUnwrap(cache.readings()).map(\.value), [45, 40])
        driver.values = [1: 65, 2: 50]
        XCTAssertEqual(try XCTUnwrap(cache.readings()).map(\.value), [65, 50])
        XCTAssertEqual(driver.discoveryCalls, 2, "graph discovery is never skipped")
        XCTAssertEqual(driver.identityCalls, 4)
        XCTAssertEqual(driver.nameCalls, [1: 1, 2: 1], "four property parses become two")
        XCTAssertEqual(driver.eventCalls, [1: 2, 2: 2], "all four dynamic events are retained")
    }

    func testGraphOrderChangeKeepsNamesButUsesFreshCurrentServiceOrder() throws {
        let driver = CountingHIDTemperatureDriver()
        driver.graph = [1, 2]
        driver.names = [1: "CPU tdie", 2: "GPU tdie"]
        driver.values = [1: 45, 2: 55]
        let cache = HIDTemperatureMetadataCache(driver: driver)
        _ = cache.readings()
        driver.graph = [2, 1]
        driver.values = [1: 46, 2: 56]
        let readings = try XCTUnwrap(cache.readings())
        XCTAssertEqual(readings.map(\.name), ["GPU tdie", "CPU tdie"])
        XCTAssertEqual(readings.map(\.value), [56, 46])
        XCTAssertEqual(readings.map(\.ordinal), [2, 1])
        XCTAssertEqual(driver.nameCalls, [1: 1, 2: 1])
        XCTAssertEqual(driver.eventCalls, [1: 2, 2: 2])
    }

    func testSameCountGraphReplacementInvalidatesAllNamesAndStopsReadingRemovedService() throws {
        let driver = CountingHIDTemperatureDriver()
        driver.graph = [1, 2]
        driver.names = [1: "old CPU tdie", 2: "old GPU tdie"]
        driver.values = [1: 45, 2: 55]
        let cache = HIDTemperatureMetadataCache(driver: driver)
        _ = cache.readings()
        driver.graph = [1, 3]
        driver.names = [1: "new CPU tdie", 3: "new GPU tdie"]
        driver.values = [1: 46, 3: 56]
        XCTAssertEqual(try XCTUnwrap(cache.readings()).map(\.name), ["new CPU tdie", "new GPU tdie"])
        XCTAssertEqual(driver.nameCalls, [1: 2, 2: 1, 3: 1], "surviving names also expire on graph change")
        XCTAssertEqual(driver.eventCalls, [1: 2, 2: 1, 3: 1], "removed handles never supply another sample")
    }

    func testGraphAdditionAndRemovalBothInvalidateNames() throws {
        let driver = CountingHIDTemperatureDriver()
        driver.graph = [1]
        driver.names = [1: "CPU tdie", 2: "GPU tdie"]
        driver.values = [1: 45, 2: 55]
        let cache = HIDTemperatureMetadataCache(driver: driver)
        _ = cache.readings()
        driver.graph = [1, 2]
        XCTAssertEqual(try XCTUnwrap(cache.readings()).count, 2)
        driver.graph = [1]
        XCTAssertEqual(try XCTUnwrap(cache.readings()).count, 1)
        XCTAssertEqual(driver.nameCalls, [1: 3, 2: 1])
        XCTAssertEqual(driver.discoveryCalls, 3)
        XCTAssertEqual(driver.eventCalls, [1: 3, 2: 1])
    }

    func testUnavailableGraphClearsMetadataEvenWhenSameIdentitiesReturn() throws {
        let driver = CountingHIDTemperatureDriver()
        driver.graph = [1]
        driver.names = [1: "old CPU tdie"]
        driver.values = [1: 45]
        let cache = HIDTemperatureMetadataCache(driver: driver)
        _ = cache.readings()
        driver.graph = nil
        XCTAssertNil(cache.readings())
        driver.graph = [1]
        driver.names = [1: "new CPU tdie"]
        driver.values = [1: 65]
        let readings = try XCTUnwrap(cache.readings())
        XCTAssertEqual(readings.map(\.name), ["new CPU tdie"])
        XCTAssertEqual(readings.map(\.value), [65])
        XCTAssertEqual(readings.map(\.ordinal), [2])
        XCTAssertEqual(driver.discoveryCalls, 3)
        XCTAssertEqual(driver.nameCalls[1], 2)
        XCTAssertEqual(driver.eventCalls[1], 2)
    }

    func testTemporaryMissingNameIsRetriedAndThenCached() throws {
        let driver = CountingHIDTemperatureDriver()
        driver.graph = [1]
        driver.values = [1: 45]
        let cache = HIDTemperatureMetadataCache(driver: driver)
        XCTAssertEqual(try XCTUnwrap(cache.readings()).first?.name, "")
        driver.names = [1: "CPU tdie"]
        XCTAssertEqual(try XCTUnwrap(cache.readings()).first?.name, "CPU tdie")
        _ = cache.readings()
        XCTAssertEqual(driver.nameCalls[1], 2, "a failed property copy is not a cached name")
        XCTAssertEqual(driver.eventCalls[1], 3)
    }

    func testUnreadableOrInvalidEventNeverReplaysEarlierTemperature() throws {
        let driver = CountingHIDTemperatureDriver()
        driver.graph = [1]
        driver.names = [1: "CPU tdie"]
        driver.values = [1: 45]
        let cache = HIDTemperatureMetadataCache(driver: driver)
        XCTAssertEqual(try XCTUnwrap(cache.readings()).map(\.value), [45])
        driver.values = [:]
        XCTAssertTrue(try XCTUnwrap(cache.readings()).isEmpty)
        driver.values = [1: .nan]
        XCTAssertTrue(try XCTUnwrap(cache.readings()).isEmpty)
        driver.values = [1: 70]
        XCTAssertEqual(try XCTUnwrap(cache.readings()).map(\.value), [70])
        XCTAssertEqual(driver.nameCalls[1], 1)
        XCTAssertEqual(driver.eventCalls[1], 4)
    }

    func testEmptyGraphDropsAllOldServicesAndReadsNothingUntilNewGraph() throws {
        let driver = CountingHIDTemperatureDriver()
        driver.graph = [1]
        driver.names = [1: "CPU tdie"]
        driver.values = [1: 45]
        let cache = HIDTemperatureMetadataCache(driver: driver)
        _ = cache.readings()
        driver.graph = []
        XCTAssertTrue(try XCTUnwrap(cache.readings()).isEmpty)
        XCTAssertEqual(driver.eventCalls[1], 1)
        driver.graph = [1]
        driver.names = [1: "resumed CPU tdie"]
        XCTAssertEqual(try XCTUnwrap(cache.readings()).first?.name, "resumed CPU tdie")
        XCTAssertEqual(driver.nameCalls[1], 2)
    }
}

// Release-visible, injected and never reaches native HID symbols.
private final class CountingHIDTemperatureDriver: HIDTemperatureReadingDriver {
    var graph: [Int]? = []
    var names: [Int: String] = [:]
    var values: [Int: Double] = [:]
    private(set) var discoveryCalls = 0
    private(set) var identityCalls = 0
    private(set) var nameCalls: [Int: Int] = [:]
    private(set) var eventCalls: [Int: Int] = [:]

    func services() -> [Int]? { discoveryCalls += 1; return graph }
    func identity(of service: Int) -> Int { identityCalls += 1; return service }
    func name(of service: Int) -> String? { nameCalls[service, default: 0] += 1; return names[service] }
    func temperature(of service: Int) -> Double? { eventCalls[service, default: 0] += 1; return values[service] }
}
