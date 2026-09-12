import XCTest
@testable import StorageCleanerMac

final class BatteryWearTrendAnalysisTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func testBatteryTrendRequiresEightPointsAcrossFortyFiveDays() {
        XCTAssertNil(evaluateAtLatest(batterySamples(
            count: 7,
            spanDays: 60,
            lossPer90Days: 2
        )))
        XCTAssertNil(evaluateAtLatest(batterySamples(
            count: 8,
            spanDays: 40,
            lossPer90Days: 2
        )))
        XCTAssertNotNil(evaluateAtLatest(batterySamples(
            count: 8,
            spanDays: 45,
            lossPer90Days: 2
        )))
    }

    func testBatteryTrendClassifiesStableObserveAndFastDeclineOnlyWithConfidence() throws {
        let stable = try XCTUnwrap(evaluateAtLatest(batterySamples(
            count: 16,
            spanDays: 90,
            lossPer90Days: 0.8
        )))
        let observe = try XCTUnwrap(evaluateAtLatest(batterySamples(
            count: 16,
            spanDays: 90,
            lossPer90Days: 2
        )))
        let fast = try XCTUnwrap(evaluateAtLatest(batterySamples(
            count: 16,
            spanDays: 90,
            lossPer90Days: 4
        )))
        let lowConfidenceFast = try XCTUnwrap(evaluateAtLatest(batterySamples(
            count: 8,
            spanDays: 45,
            lossPer90Days: 4,
            noise: [0, 0.2, -0.2]
        )))

        XCTAssertEqual(stable.classification, .stable)
        XCTAssertEqual(observe.classification, .observe)
        XCTAssertEqual(fast.classification, .decliningQuickly)
        XCTAssertGreaterThanOrEqual(fast.confidence, 70)
        XCTAssertEqual(lowConfidenceFast.classification, .observe)
        XCTAssertLessThan(lowConfidenceFast.confidence, 70)
    }

    func testBatteryTrendRejectsNoisyCapacityEvidence() {
        let samples = batterySamples(
            count: 12,
            spanDays: 70,
            lossPer90Days: 2,
            noise: [-4, 4]
        )

        XCTAssertNil(evaluateAtLatest(samples))
    }

    func testBatteryTrendComputesCycleNormalizedLossWhenCyclesAdvance() throws {
        let samples = batterySamples(
            count: 16,
            spanDays: 90,
            lossPer90Days: 3,
            cycleStep: 10
        )

        let trend = try XCTUnwrap(evaluateAtLatest(samples))

        XCTAssertEqual(trend.lossPer90Days, 3, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(trend.lossPer100Cycles), 2, accuracy: 0.05)
    }

    func testBatteryTrendOmitsCycleRateForStagnantOrResetCounter() throws {
        let stagnant = batterySamples(
            count: 16,
            spanDays: 90,
            lossPer90Days: 2,
            cycleStep: 0
        )
        var reset = batterySamples(
            count: 16,
            spanDays: 90,
            lossPer90Days: 2,
            cycleStep: 10
        )
        reset[8] = BatteryWearSample(
            recordedAt: reset[8].recordedAt,
            maximumCapacityPercent: reset[8].maximumCapacityPercent,
            cycleCount: 3
        )

        XCTAssertNil(try XCTUnwrap(evaluateAtLatest(stagnant)).lossPer100Cycles)
        XCTAssertNil(try XCTUnwrap(evaluateAtLatest(reset)).lossPer100Cycles)
    }

    func testBatteryTrendUsesLatestFiniteSamplePerUTCDay() throws {
        var samples = batterySamples(
            count: 8,
            spanDays: 49,
            lossPer90Days: 2
        )
        let duplicate = BatteryWearSample(
            recordedAt: samples[3].recordedAt.addingTimeInterval(3_600),
            maximumCapacityPercent: samples[3].maximumCapacityPercent,
            cycleCount: samples[3].cycleCount
        )
        samples.append(duplicate)
        samples.append(BatteryWearSample(
            recordedAt: Date(timeIntervalSinceReferenceDate: .infinity),
            maximumCapacityPercent: .nan,
            cycleCount: -1
        ))

        let trend = try XCTUnwrap(evaluateAtLatest(samples))

        XCTAssertEqual(trend.sampleCount, 8)
        XCTAssertEqual(trend.spanDays, 49)
        XCTAssertFalse(trend.lossPer90Days.isNaN)
        XCTAssertFalse(trend.capacityMAD.isNaN)
    }

    func testBatteryTrendReportsObservedRatesWithoutLifetimePrediction() throws {
        let trend = try XCTUnwrap(evaluateAtLatest(batterySamples(
            count: 16,
            spanDays: 90,
            lossPer90Days: 2
        )))

        XCTAssertGreaterThanOrEqual(trend.lossPer90Days, 0)
        XCTAssertFalse(String(describing: trend).localizedCaseInsensitiveContains("remaining life"))
        XCTAssertFalse(String(describing: trend).localizedCaseInsensitiveContains("death date"))
    }

    func testBatteryTrendDoesNotCallOneTimeCapacityCalibrationAQuickDecline() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let samples = (0..<16).map { index in
            BatteryWearSample(
                recordedAt: start.addingTimeInterval(Double(index * 6) * day),
                maximumCapacityPercent: index < 8 ? 100 : 96,
                cycleCount: 100 + index * 4
            )
        }

        let trend = try XCTUnwrap(evaluateAtLatest(samples))

        XCTAssertGreaterThanOrEqual(trend.lossPer90Days, 3)
        XCTAssertLessThan(trend.confidence, 70)
        XCTAssertEqual(trend.classification, .observe)

        let linear = try XCTUnwrap(evaluateAtLatest(batterySamples(
            count: 16,
            spanDays: 90,
            lossPer90Days: 4
        )))
        XCTAssertGreaterThanOrEqual(linear.confidence, 70)
        XCTAssertEqual(linear.classification, .decliningQuickly)
    }

    func testBatteryTrendRequiresConservativeSlopeToRemainQuick() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let capacities = [97, 97, 97, 96, 98, 93, 97, 94, 94, 92, 94, 92, 91, 88, 93, 88]
        let samples = capacities.enumerated().map { index, capacity in
            BatteryWearSample(
                recordedAt: start.addingTimeInterval(Double(index * 6) * day),
                maximumCapacityPercent: Double(capacity),
                cycleCount: 100 + index * 4
            )
        }

        let trend = try XCTUnwrap(evaluateAtLatest(samples))

        XCTAssertGreaterThanOrEqual(trend.lossPer90Days, 3)
        XCTAssertEqual(trend.classification, .observe)
    }

    func testBatteryTrendExcludesFutureSamplesAndRejectsStaleEvidence() throws {
        let samples = batterySamples(
            count: 16,
            spanDays: 90,
            lossPer90Days: 2
        )
        let referenceDate = try XCTUnwrap(samples.last?.recordedAt)
        let future = BatteryWearSample(
            recordedAt: referenceDate.addingTimeInterval(day),
            maximumCapacityPercent: 70,
            cycleCount: 999
        )

        let fresh = try XCTUnwrap(BatteryWearTrendAnalysis.evaluate(
            samples: samples + [future],
            referenceDate: referenceDate
        ))
        XCTAssertEqual(fresh.sampleCount, samples.count)
        XCTAssertEqual(fresh.evaluatedAt, referenceDate)

        XCTAssertNotNil(BatteryWearTrendAnalysis.evaluate(
            samples: samples,
            referenceDate: referenceDate.addingTimeInterval(36 * 3_600)
        ))
        XCTAssertNil(BatteryWearTrendAnalysis.evaluate(
            samples: samples,
            referenceDate: referenceDate.addingTimeInterval(36 * 3_600 + 1)
        ))
    }

    private func evaluateAtLatest(
        _ samples: [BatteryWearSample]
    ) -> BatteryWearTrend? {
        let validDates = samples
            .filter {
                $0.recordedAt.timeIntervalSinceReferenceDate.isFinite
                    && $0.maximumCapacityPercent.isFinite
            }
            .map(\.recordedAt)
        guard let latest = validDates.max() else { return nil }
        return BatteryWearTrendAnalysis.evaluate(
            samples: samples,
            referenceDate: latest
        )
    }

    private func batterySamples(
        count: Int,
        spanDays: Int,
        lossPer90Days: Double,
        noise: [Double] = [0],
        cycleStep: Int = 4
    ) -> [BatteryWearSample] {
        precondition(count >= 2)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return (0..<count).map { index in
            let offset = Double(spanDays) * Double(index) / Double(count - 1)
            let capacity = 98 - (lossPer90Days / 90) * offset + noise[index % noise.count]
            return BatteryWearSample(
                recordedAt: start.addingTimeInterval(offset * day),
                maximumCapacityPercent: capacity,
                cycleCount: 100 + index * cycleStep
            )
        }
    }
}
