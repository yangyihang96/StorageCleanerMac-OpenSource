import XCTest
@testable import StorageCleanerMac

final class BenchmarkStatisticsTests: XCTestCase {
    func testOddAndEvenMedian() throws {
        XCTAssertEqual(
            try BenchmarkStatistics.summarize([9, 1, 5]).median,
            5,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try BenchmarkStatistics.summarize([4, 1, 3, 2]).median,
            2.5,
            accuracy: 1e-12
        )
    }

    func testMedianAbsoluteDeviationAndRelativeMAD() throws {
        let summary = try BenchmarkStatistics.summarize([1, 2, 3, 4])

        XCTAssertEqual(summary.medianAbsoluteDeviation, 1, accuracy: 1e-12)
        XCTAssertEqual(
            summary.relativeMedianAbsoluteDeviation,
            1.4826 / 2.5,
            accuracy: 1e-12
        )
    }

    func testPercentilesUseLinearInterpolation() throws {
        let summary = try BenchmarkStatistics.summarize([1, 2, 3, 4])

        XCTAssertEqual(summary.p50, 2.5, accuracy: 1e-12)
        XCTAssertEqual(summary.p95, 3.85, accuracy: 1e-12)
        XCTAssertEqual(summary.p99, 3.97, accuracy: 1e-12)
        XCTAssertEqual(
            try BenchmarkStatistics.percentile(0, samples: [1, 2, 3, 4]),
            1,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            try BenchmarkStatistics.percentile(1, samples: [1, 2, 3, 4]),
            4,
            accuracy: 1e-12
        )
    }

    func testConfidenceBoundaries() throws {
        let twoPercentDeviation = 100 * 0.02 / 1.4826
        let fivePercentDeviation = 100 * 0.05 / 1.4826

        XCTAssertEqual(
            try BenchmarkStatistics.summarize([
                100 - twoPercentDeviation,
                100,
                100 + twoPercentDeviation,
            ]).confidence,
            .a
        )
        XCTAssertEqual(
            try BenchmarkStatistics.summarize([
                100 - (twoPercentDeviation * 1.001),
                100,
                100 + (twoPercentDeviation * 1.001),
            ]).confidence,
            .b
        )
        XCTAssertEqual(
            try BenchmarkStatistics.summarize([
                100 - fivePercentDeviation,
                100,
                100 + fivePercentDeviation,
            ]).confidence,
            .b
        )
        XCTAssertEqual(
            try BenchmarkStatistics.summarize([
                100 - (fivePercentDeviation * 1.001),
                100,
                100 + (fivePercentDeviation * 1.001),
            ]).confidence,
            .c
        )
    }

    func testEmptyAndInvalidSamplesAreRejected() {
        XCTAssertThrowsError(try BenchmarkStatistics.summarize([])) {
            XCTAssertEqual($0 as? BenchmarkStatisticsError, .emptySamples)
        }
        for samples in [
            [Double.nan],
            [Double.infinity],
            [0],
            [-1],
            [1, 2, -Double.infinity],
        ] {
            XCTAssertThrowsError(try BenchmarkStatistics.summarize(samples)) {
                XCTAssertEqual($0 as? BenchmarkStatisticsError, .invalidSample)
            }
        }
    }

    func testInvalidPercentilesAreRejected() {
        for percentile in [Double.nan, -.infinity, -0.01, 1.01, .infinity] {
            XCTAssertThrowsError(
                try BenchmarkStatistics.percentile(percentile, samples: [1, 2, 3])
            ) {
                XCTAssertEqual($0 as? BenchmarkStatisticsError, .invalidPercentile)
            }
        }
    }

    func testMeasurementDerivesStatisticsWithoutChangingFrozenMedianOrCV() throws {
        let measurement = BenchmarkComponentMeasurement(
            component: .memory,
            unit: .decimalGigabytesPerSecond,
            samples: [99, 100, 101].map {
                BenchmarkComponentSample(value: Double($0), elapsedSeconds: 1, checksum: 42)
            }
        )
        let summary = try XCTUnwrap(measurement.statistics)

        XCTAssertEqual(measurement.medianValue, 100, accuracy: 1e-12)
        XCTAssertEqual(measurement.coefficientOfVariation, 0.01, accuracy: 1e-12)
        XCTAssertEqual(summary.median, 100, accuracy: 1e-12)
        XCTAssertEqual(summary.medianAbsoluteDeviation, 1, accuracy: 1e-12)
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.confidence, .a)
    }
}
