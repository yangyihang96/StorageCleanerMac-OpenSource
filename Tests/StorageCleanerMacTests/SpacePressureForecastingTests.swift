import XCTest
@testable import StorageCleanerMac

final class SpacePressureForecastingTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let gib = Double(1_073_741_824)
    private let totalBytes: Int64 = 512 * 1_073_741_824

    func testStorageForecastResistsOneDayCleanupOutlier() throws {
        let samples = storageSamples(dayOffsets: [0, 3, 6, 9, 12, 15, 18]) { dayOffset in
            let baseline = 180 * self.gib - Double(dayOffset) * self.gib
            return baseline + (dayOffset == 9 ? 20 * self.gib : 0)
        }

        let forecast = try XCTUnwrap(SpacePressureForecasting.evaluate(
            samples: samples,
            referenceDate: samples.last!.recordedAt
        ))

        XCTAssertEqual(forecast.dailyAvailableByteSlope, -gib, accuracy: 1)
        XCTAssertGreaterThanOrEqual(forecast.sampleCount, 7)
        XCTAssertEqual(forecast.spanDays, 18)
        XCTAssertGreaterThan(forecast.daysUntilPressure, 0)
        XCTAssertLessThanOrEqual(forecast.earliestDaysUntilPressure!, forecast.daysUntilPressure)
        XCTAssertGreaterThanOrEqual(forecast.latestDaysUntilPressure!, forecast.daysUntilPressure)
    }

    func testStorageForecastRequiresSevenDatesAcrossFourteenDays() {
        let sixSamples = storageSamples(dayOffsets: [0, 3, 6, 9, 12, 15]) {
            180 * self.gib - Double($0) * self.gib
        }
        let shortSpan = storageSamples(dayOffsets: [0, 2, 4, 6, 8, 10, 12]) {
            180 * self.gib - Double($0) * self.gib
        }

        XCTAssertNil(evaluateAtLatest(sixSamples))
        XCTAssertNil(evaluateAtLatest(shortSpan))
    }

    func testStorageForecastRejectsCapacityIdentityDriftAndMissingImportantUsage() {
        var drifted = storageSamples(dayOffsets: [0, 3, 6, 9, 12, 15, 18]) {
            180 * self.gib - Double($0) * self.gib
        }
        drifted[3] = StoragePressureSample(
            recordedAt: drifted[3].recordedAt,
            totalBytes: Int64(Double(totalBytes) * 0.90),
            availableForImportantUsageBytes: drifted[3].availableForImportantUsageBytes
        )
        var missing = storageSamples(dayOffsets: [0, 3, 6, 9, 12, 15, 18]) {
            180 * self.gib - Double($0) * self.gib
        }
        missing[2] = StoragePressureSample(
            recordedAt: missing[2].recordedAt,
            totalBytes: totalBytes,
            availableForImportantUsageBytes: nil
        )

        XCTAssertNil(evaluateAtLatest(drifted))
        XCTAssertNil(evaluateAtLatest(missing))
    }

    func testStorageForecastRejectsWeakOrInconsistentDecline() {
        let tooSlow = storageSamples(dayOffsets: [0, 3, 6, 9, 12, 15, 18]) {
            180 * self.gib - Double($0) * 32 * 1_048_576
        }
        let alternating = storageSamples(dayOffsets: [0, 3, 6, 9, 12, 15, 18]) {
            $0.isMultiple(of: 6) ? 170 * self.gib : 190 * self.gib
        }

        XCTAssertNil(evaluateAtLatest(tooSlow))
        XCTAssertNil(evaluateAtLatest(alternating))
    }

    func testStorageForecastReturnsZeroWhenAlreadyUnderPressure() throws {
        let samples = storageSamples(dayOffsets: [0, 3, 6, 9, 12, 15, 18]) {
            70 * self.gib - Double($0) * self.gib
        }

        let forecast = try XCTUnwrap(SpacePressureForecasting.evaluate(
            samples: samples,
            referenceDate: samples.last!.recordedAt
        ))

        XCTAssertEqual(forecast.daysUntilPressure, 0)
        XCTAssertEqual(forecast.earliestDaysUntilPressure, 0)
        XCTAssertEqual(forecast.latestDaysUntilPressure, 0)
        XCTAssertEqual(forecast.pressureLineBytes, Int64(Double(totalBytes) * 0.15))
    }

    func testStorageForecastRejectsInvalidByteRangesAndNonFiniteDates() {
        var samples = storageSamples(dayOffsets: [0, 3, 6, 9, 12, 15, 18]) {
            180 * self.gib - Double($0) * self.gib
        }
        samples[0] = StoragePressureSample(
            recordedAt: Date(timeIntervalSinceReferenceDate: .infinity),
            totalBytes: totalBytes,
            availableForImportantUsageBytes: totalBytes + 1
        )

        XCTAssertNil(evaluateAtLatest(samples))
    }

    func testStorageForecastExcludesFutureSamplesAndRejectsStaleEvidence() throws {
        let samples = storageSamples(dayOffsets: [0, 3, 6, 9, 12, 15, 18]) {
            180 * self.gib - Double($0) * self.gib
        }
        let referenceDate = try XCTUnwrap(samples.last?.recordedAt)
        let future = StoragePressureSample(
            recordedAt: referenceDate.addingTimeInterval(day),
            totalBytes: totalBytes,
            availableForImportantUsageBytes: 1
        )

        let fresh = try XCTUnwrap(SpacePressureForecasting.evaluate(
            samples: samples + [future],
            referenceDate: referenceDate
        ))
        XCTAssertEqual(fresh.sampleCount, samples.count)
        XCTAssertEqual(fresh.dailyAvailableByteSlope, -gib, accuracy: 1)
        XCTAssertEqual(fresh.evaluatedAt, referenceDate)

        XCTAssertNotNil(SpacePressureForecasting.evaluate(
            samples: samples,
            referenceDate: referenceDate.addingTimeInterval(36 * 3_600)
        ))
        XCTAssertNil(SpacePressureForecasting.evaluate(
            samples: samples,
            referenceDate: referenceDate.addingTimeInterval(36 * 3_600 + 1)
        ))
    }

    private func evaluateAtLatest(
        _ samples: [StoragePressureSample]
    ) -> StoragePressureForecast? {
        let validDates = samples
            .filter { $0.recordedAt.timeIntervalSinceReferenceDate.isFinite }
            .map(\.recordedAt)
        guard let latest = validDates.max() else { return nil }
        return SpacePressureForecasting.evaluate(
            samples: samples,
            referenceDate: latest
        )
    }

    private func storageSamples(
        dayOffsets: [Int],
        available: (Int) -> Double
    ) -> [StoragePressureSample] {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return dayOffsets.map { offset in
            StoragePressureSample(
                recordedAt: start.addingTimeInterval(Double(offset) * day),
                totalBytes: totalBytes,
                availableForImportantUsageBytes: Int64(available(offset).rounded())
            )
        }
    }
}
