import XCTest
@testable import StorageCleanerMac

final class RobustTrendStatisticsTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func testTheilSenReturnsExactDailySlopeForLinearSamples() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let samples = (0..<5).map { index in
            RobustTrendSample(
                recordedAt: start.addingTimeInterval(Double(index) * day),
                value: 100 - Double(index) * 2
            )
        }

        let estimate = try XCTUnwrap(RobustTrendStatistics.theilSen(samples: samples))

        XCTAssertEqual(estimate.slopePerDay, -2, accuracy: 0.000_001)
        XCTAssertEqual(estimate.slopeMAD, 0, accuracy: 0.000_001)
        XCTAssertEqual(estimate.residualMAD, 0, accuracy: 0.000_001)
        XCTAssertEqual(estimate.negativePairFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(estimate.sampleCount, 5)
        XCTAssertEqual(estimate.spanDays, 4)
    }

    func testTheilSenResistsOneLargeMiddleOutlier() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let samples = (0..<9).map { index in
            RobustTrendSample(
                recordedAt: start.addingTimeInterval(Double(index) * day),
                value: 500 - Double(index) * 10 + (index == 4 ? 120 : 0)
            )
        }

        let estimate = try XCTUnwrap(RobustTrendStatistics.theilSen(samples: samples))

        XCTAssertEqual(estimate.slopePerDay, -10, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(estimate.negativePairFraction, 0.75)
    }

    func testDistinctUTCDaysKeepLatestFiniteSample() {
        let utcDay = Date(timeIntervalSince1970: 1_790_035_200)
        let samples = [
            RobustTrendSample(recordedAt: utcDay.addingTimeInterval(600), value: 10),
            RobustTrendSample(recordedAt: utcDay.addingTimeInterval(3_600), value: 12),
            RobustTrendSample(recordedAt: utcDay.addingTimeInterval(day + 600), value: 20),
            RobustTrendSample(recordedAt: utcDay.addingTimeInterval(2 * day), value: .nan),
            RobustTrendSample(recordedAt: Date(timeIntervalSinceReferenceDate: .infinity), value: 30)
        ]

        let distinct = RobustTrendStatistics.distinctDailySamples(samples)

        XCTAssertEqual(distinct.count, 2)
        XCTAssertEqual(distinct[0].value, 12)
        XCTAssertEqual(distinct[1].value, 20)
    }

    func testDuplicateOnlyOrZeroSpanSamplesDoNotProduceEstimate() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)

        XCTAssertNil(RobustTrendStatistics.theilSen(samples: []))
        XCTAssertNil(RobustTrendStatistics.theilSen(samples: [
            RobustTrendSample(recordedAt: date, value: 1),
            RobustTrendSample(recordedAt: date.addingTimeInterval(60), value: 2)
        ]))
    }

    func testMedianAndMADRejectNonFiniteInput() throws {
        XCTAssertNil(RobustTrendStatistics.median([1, .nan, 2]))
        XCTAssertEqual(RobustTrendStatistics.median([1, 2, 8, 9]), 5.0)
        XCTAssertEqual(
            try XCTUnwrap(
                RobustTrendStatistics.medianAbsoluteDeviation([1, 2, 2, 2, 9])
            ),
            0,
            accuracy: 0.000_001
        )
    }
}
