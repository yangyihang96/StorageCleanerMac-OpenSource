import XCTest
@testable import StorageCleanerMac

final class HealthConfidenceScoringTests: XCTestCase {
    func testFreshnessUsesSeventyTwoHourHalfLifeAndThirtyDayCutoff() {
        XCTAssertEqual(HealthConfidenceScoring.freshness(ageHours: 72), 0.5, accuracy: 0.0001)
        XCTAssertEqual(HealthConfidenceScoring.freshness(ageHours: -2), 1, accuracy: 0.0001)
        XCTAssertEqual(HealthConfidenceScoring.freshness(ageHours: 720), pow(0.5, 10), accuracy: 0.000001)
        XCTAssertEqual(HealthConfidenceScoring.freshness(ageHours: 721), 0)
        XCTAssertEqual(HealthConfidenceScoring.freshness(ageHours: .nan), 0)
    }

    func testConsistencyRequiresFiveSameModelScores() {
        XCTAssertEqual(HealthConfidenceScoring.consistency(scores: [80, 81, 82, 83]), 0)
        XCTAssertEqual(HealthConfidenceScoring.consistency(scores: [80, 80, 80, 80, 80]), 1)
        XCTAssertEqual(HealthConfidenceScoring.consistency(scores: [0, 15, 30, 45, 60]), 0)
    }

    func testWeightedFreshnessExcludesNotApplicableFactor() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let components = [
            component(.diskReliability, availability: .available, date: now),
            component(
                .capacity,
                availability: .available,
                date: now.addingTimeInterval(-72 * 3_600)
            ),
            component(.battery, availability: .notApplicable, date: .distantPast)
        ]

        let freshness = HealthConfidenceScoring.weightedFreshness(
            components: components,
            referenceDate: now
        )

        XCTAssertEqual(freshness, (35 * 1 + 15 * 0.5) / 50, accuracy: 0.0001)
    }

    func testHistorySpanUsesDistinctUTCDaysAndCurrentModelOnly() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let history = [
            historyEntry(date: now, score: 90, modelVersion: "computer-health-v1"),
            historyEntry(date: now.addingTimeInterval(-3_600), score: 91, modelVersion: "computer-health-v1"),
            historyEntry(date: now.addingTimeInterval(-86_400), score: 92, modelVersion: "computer-health-v1"),
            historyEntry(date: now.addingTimeInterval(-2 * 86_400), score: 93, modelVersion: "old-model")
        ]

        XCTAssertEqual(
            HealthConfidenceScoring.historySpan(
                history: history,
                modelVersion: "computer-health-v1"
            ),
            2.0 / 30,
            accuracy: 0.0001
        )
    }

    func testEvaluationCombinesCoverageFreshnessHistoryAndMAD() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let components = HealthFactor.allCases.map {
            component($0, availability: .available, date: now)
        }
        let history = (0..<30).map { index in
            historyEntry(
                date: now.addingTimeInterval(-Double(index) * 86_400),
                score: 90,
                modelVersion: ComputerHealthEvaluation.currentModelVersion
            )
        }

        let confidence = HealthConfidenceScoring.evaluate(
            coverage: 1,
            components: components,
            history: history,
            referenceDate: now
        )

        XCTAssertEqual(confidence.value, 100)
        XCTAssertEqual(confidence.level, .high)
        XCTAssertEqual(confidence.modelVersion, "health-confidence-v1")
    }

    func testNoHistoryProducesNoSpanOrConsistencyCredit() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let confidence = HealthConfidenceScoring.evaluate(
            coverage: 1,
            components: HealthFactor.allCases.map {
                component($0, availability: .available, date: now)
            },
            history: [],
            referenceDate: now
        )

        XCTAssertEqual(confidence.value, 75)
        XCTAssertEqual(confidence.level, .medium)
    }

    func testInvalidCoverageAndZeroApplicableFreshnessStayFinite() {
        let confidence = HealthConfidenceScoring.evaluate(
            coverage: .infinity,
            components: [
                component(.battery, availability: .notApplicable, date: .distantPast)
            ],
            history: [],
            referenceDate: Date(timeIntervalSince1970: 1_790_000_000)
        )

        XCTAssertEqual(confidence.value, 0)
        XCTAssertEqual(confidence.level, .low)
    }

    private func component(
        _ factor: HealthFactor,
        availability: HealthEvidenceAvailability,
        date: Date
    ) -> HealthComponentEvaluation {
        HealthComponentEvaluation(
            factor: factor,
            availability: availability,
            score: availability == .notApplicable ? nil : 100,
            evaluatedAt: date,
            modelVersion: ComputerHealthEvaluation.currentModelVersion
        )
    }

    private func historyEntry(
        date: Date,
        score: Double?,
        modelVersion: String
    ) -> ComputerHealthHistoryEntry {
        ComputerHealthHistoryEntry(
            recordedAt: date,
            evaluation: ComputerHealthEvaluation(
                score: score,
                status: score == nil ? .dataInsufficient : .healthy,
                coverage: score == nil ? 0 : 1,
                confidence: HealthConfidence(
                    value: 80,
                    level: .high,
                    modelVersion: "health-confidence-v1"
                ),
                components: [],
                evaluatedAt: date,
                modelVersion: modelVersion
            )
        )
    }
}
