import Foundation
import XCTest
@testable import StorageCleanerMac

final class NetworkExperienceScoringTests: XCTestCase {
    func testStableConnectionScoresAtLeastEighty() throws {
        let score = NetworkExperienceScoring.evaluate(.init(
            downloadMbps: 250,
            uploadMbps: 50,
            idleLatencyMS: 20,
            loadedLatencyP95MS: 50,
            jitterMS: 5,
            responsivenessRPM: 1_000
        ))

        XCTAssertEqual(try XCTUnwrap(score.value), 100)
        XCTAssertEqual(score.grade, .stable)
        XCTAssertEqual(score.completeness, 1, accuracy: 0.000_001)
        XCTAssertTrue(score.missingMetrics.isEmpty)
        XCTAssertEqual(score.modelVersion, "network-experience-v1")
    }

    func testBadAnchorsAndZeroRemainFiniteCongestedMeasurements() throws {
        let atBadAnchors = NetworkExperienceScoring.evaluate(.init(
            downloadMbps: 5,
            uploadMbps: 1,
            idleLatencyMS: 150,
            loadedLatencyP95MS: 500,
            jitterMS: 80,
            responsivenessRPM: 100
        ))
        let zeroThroughput = NetworkExperienceScoring.evaluate(.init(
            downloadMbps: 0,
            uploadMbps: 0,
            idleLatencyMS: 150,
            loadedLatencyP95MS: 500,
            jitterMS: 80,
            responsivenessRPM: 0
        ))

        XCTAssertEqual(try XCTUnwrap(atBadAnchors.value), 0)
        XCTAssertEqual(atBadAnchors.grade, .congested)
        XCTAssertEqual(try XCTUnwrap(zeroThroughput.value), 0)
        XCTAssertEqual(zeroThroughput.grade, .congested)
        XCTAssertTrue(zeroThroughput.missingMetrics.isEmpty)
    }

    func testGradeBoundariesUsePublishedIntegerScore() throws {
        let stable = NetworkExperienceScoring.evaluate(input(normalizedScore: 80))
        let average = NetworkExperienceScoring.evaluate(input(normalizedScore: 55))
        let congested = NetworkExperienceScoring.evaluate(input(normalizedScore: 54))

        XCTAssertEqual(try XCTUnwrap(stable.value), 80)
        XCTAssertEqual(stable.grade, .stable)
        XCTAssertEqual(try XCTUnwrap(average.value), 55)
        XCTAssertEqual(average.grade, .average)
        XCTAssertEqual(try XCTUnwrap(congested.value), 54)
        XCTAssertEqual(congested.grade, .congested)
    }

    func testMissingOptionalMetricsReweightsOnlyAvailableMeasurements() throws {
        let score = NetworkExperienceScoring.evaluate(.init(
            downloadMbps: 250,
            uploadMbps: 50,
            idleLatencyMS: 20,
            loadedLatencyP95MS: nil,
            jitterMS: nil,
            responsivenessRPM: nil
        ))

        XCTAssertEqual(try XCTUnwrap(score.value), 100)
        XCTAssertEqual(score.grade, .stable)
        XCTAssertEqual(score.completeness, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            score.missingMetrics,
            ["loadedLatencyP95MS", "jitterMS", "responsivenessRPM"]
        )
    }

    func testOptionalReweightingUsesDocumentedMetricWeights() throws {
        let score = NetworkExperienceScoring.evaluate(.init(
            downloadMbps: 250,
            uploadMbps: 50,
            idleLatencyMS: 20,
            loadedLatencyP95MS: nil,
            jitterMS: 80,
            responsivenessRPM: 100
        ))

        // Available weighted points are 25 + 15 + 20 out of an available
        // weight of 80. A fixed denominator of 100 would incorrectly yield 60.
        XCTAssertEqual(try XCTUnwrap(score.value), 75)
        XCTAssertEqual(score.grade, .average)
        XCTAssertEqual(score.completeness, 5.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(score.missingMetrics, ["loadedLatencyP95MS"])
    }

    func testMissingCoreMetricSuppressesTotal() {
        let score = NetworkExperienceScoring.evaluate(.init(
            downloadMbps: 50,
            uploadMbps: nil,
            idleLatencyMS: 30,
            loadedLatencyP95MS: nil,
            jitterMS: nil,
            responsivenessRPM: nil
        ))

        XCTAssertNil(score.value)
        XCTAssertEqual(score.grade, .dataInsufficient)
        XCTAssertEqual(score.completeness, 2.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(
            score.missingMetrics,
            ["uploadMbps", "loadedLatencyP95MS", "jitterMS", "responsivenessRPM"]
        )
        XCTAssertEqual(score.modelVersion, "network-experience-v1")
    }

    func testNegativeAndNonFiniteInputsAreExactMissingMetrics() {
        let score = NetworkExperienceScoring.evaluate(.init(
            downloadMbps: -.infinity,
            uploadMbps: -1,
            idleLatencyMS: .nan,
            loadedLatencyP95MS: .infinity,
            jitterMS: -0.1,
            responsivenessRPM: -.infinity
        ))

        XCTAssertNil(score.value)
        XCTAssertEqual(score.grade, .dataInsufficient)
        XCTAssertEqual(score.completeness, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            score.missingMetrics,
            [
                "downloadMbps",
                "uploadMbps",
                "idleLatencyMS",
                "loadedLatencyP95MS",
                "jitterMS",
                "responsivenessRPM"
            ]
        )
    }

    func testInvalidOptionalInputsCannotPropagateNonFiniteScore() throws {
        let score = NetworkExperienceScoring.evaluate(.init(
            downloadMbps: 250,
            uploadMbps: 50,
            idleLatencyMS: 20,
            loadedLatencyP95MS: .nan,
            jitterMS: .infinity,
            responsivenessRPM: -1
        ))

        let value = try XCTUnwrap(score.value)
        XCTAssertEqual(value, 100)
        XCTAssertEqual(score.grade, .stable)
        XCTAssertEqual(score.completeness, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            score.missingMetrics,
            ["loadedLatencyP95MS", "jitterMS", "responsivenessRPM"]
        )
    }

    func testScoreCodableRoundTripPreservesEvidence() throws {
        let score = NetworkExperienceScoring.evaluate(.init(
            downloadMbps: 25,
            uploadMbps: 10,
            idleLatencyMS: 45,
            loadedLatencyP95MS: nil,
            jitterMS: 12,
            responsivenessRPM: 420
        ))

        let data = try JSONEncoder().encode(score)
        XCTAssertEqual(try JSONDecoder().decode(NetworkExperienceScore.self, from: data), score)
    }

    private func input(normalizedScore: Double) -> NetworkExperienceInput {
        let fraction = normalizedScore / 100
        return NetworkExperienceInput(
            downloadMbps: 5 * pow(250.0 / 5.0, fraction),
            uploadMbps: pow(50, fraction),
            idleLatencyMS: 150 - (150 - 20) * fraction,
            loadedLatencyP95MS: 500 - (500 - 50) * fraction,
            jitterMS: 80 - (80 - 5) * fraction,
            responsivenessRPM: 100 * pow(1_000.0 / 100.0, fraction)
        )
    }
}
