import XCTest
@testable import StorageCleanerMac

final class ScanFreshnessServiceTests: XCTestCase {
    func testRecentScanIsFresh() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let generatedAt = referenceDate.addingTimeInterval(-30 * 60)

        let summary = ScanFreshnessService.summary(generatedAt: generatedAt, referenceDate: referenceDate)

        XCTAssertEqual(summary.level, .fresh)
        XCTAssertFalse(summary.shouldRescan)
        XCTAssertEqual(summary.ageSeconds, 30 * 60)
    }

    func testTwoHourOldScanIsAging() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let generatedAt = referenceDate.addingTimeInterval(-2 * 60 * 60)

        let summary = ScanFreshnessService.summary(generatedAt: generatedAt, referenceDate: referenceDate)

        XCTAssertEqual(summary.level, .aging)
        XCTAssertTrue(summary.shouldRescan)
    }

    func testDayOldScanIsStale() {
        let referenceDate = Date(timeIntervalSince1970: 100_000)
        let generatedAt = referenceDate.addingTimeInterval(-24 * 60 * 60)

        let summary = ScanFreshnessService.summary(generatedAt: generatedAt, referenceDate: referenceDate)

        XCTAssertEqual(summary.level, .stale)
        XCTAssertTrue(summary.shouldRescan)
    }
}
